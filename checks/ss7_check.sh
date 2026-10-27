#!/bin/bash
# ss7_check.sh - SS7 check for the central inter-STP architecture
#
# Target architecture:
#   - a central inter-STP (hub)
#   - each operator has a local STP with a default route to the inter-STP
#   - dynamic routes learned through M3UA
#
# What is checked:
#   1. Inter-STP: active AS for each operator
#   2. Inter-STP: connected ASPs
#   3. Inter-STP: no PROHIB
#   4. Each operator: active ASP towards the inter-STP
#   5. Each operator: local routes (MSC/BSC) active
#   6. Each operator: default route (0.0.0/0) towards the inter-STP
#   7. Basic connectivity matrix
#
# DUAL MODE - docker AND native (ISO, VM, bare machine)
# All node detection and access logic lives in checks/_mode.sh; this script
# only calls its functions. The two worlds:
#   docker: one osmo-operator-N container per operator, hub = osmo-inter-stp
#           container; everything is reached through "docker exec".
#   native: a single operator (unless netns topology), VTYs on 127.0.0.1 of
#           THIS machine. The hub is EITHER this machine (OSMO_ROLE=interstp
#           in /etc/osmo-role) OR another WAN machine; in the latter case its
#           VTY is NOT observable from here (Osmocom VTYs listen on loopback
#           only). It is then reported as skipped rather than as a fabricated
#           "0 active AS" that would read as an outage.
#
# VTY PORTS are the same in both worlds (4239 STP, 4254 MSC, 4242 BSC,
# 4258 HLR): only the host changes, and _mode.sh takes care of it.
#
# Usage:
#   sudo ./checks/ss7_check.sh [--verbose] [--quick] [--docker|--native]
# Environment: OSMO_VTY_OPEN / OSMO_VTY_READ / OSMO_VTY_Q override the VTY
# timings (defaults 1 / 1.5 / 1).

set -u

# ── Common library (docker/native detection, VTY, inventory) ─────────────────
# Looked up RELATIVE to the script: the repo runs from a clone as well as from
# /opt/GSM/osmo-operator on the ISO, and checks/ is copied as a whole, so the
# library is always next to this file.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo-operator/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ────────────────────────────────────────────────────────────
VERBOSE=0
QUICK=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quick|-q)   QUICK=1 ;;
        # --docker / --native / --mode=X: force the world instead of detecting
        # it. osmo_mode_force returns 2 when the argument is not a mode, which
        # cannot happen here since the case pattern already filtered it.
        --docker|--native|--mode=*)
            osmo_mode_force "$arg" || { echo "mode inconnu : $arg" >&2; exit 1; } ;;
        -h|--help)
            echo "Usage : $0 [--verbose|-v] [--quick|-q] [--docker|--native]"
            echo "  --docker / --native : force le mode ; sans option, detection automatique."
            exit 0 ;;
    esac
done

INTER_STP="osmo-inter-stp"
PASS=0
FAIL=0
WARN=0
SKIP=0

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
skip() { echo -e "  ${YELLOW}-${NC} $*"; SKIP=$((SKIP+1)); }
info() { [[ $VERBOSE -eq 1 ]] && echo -e "    ${CYAN}│${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}$*${NC}"
    echo -e "$(printf '─%.0s' {1..60})"
}

# ── VTY function ─────────────────────────────────────────────────────────────
# Returns 1 without output when the VTY does not answer, otherwise the cleaned
# output. The dialogue itself (nc/telnet, docker exec or local, netns) is in
# osmo_vty; the timings below are this script's own - changing them changes
# the AMOUNT of output captured, hence the "grep -ac" counts further down.
: "${OSMO_VTY_OPEN:=1}"    # sleep before writing
: "${OSMO_VTY_READ:=1.5}"  # read sleep
: "${OSMO_VTY_Q:=1}"       # nc -q1

vty_cmd() {
    local node="$1"
    local port="$2"
    local cmd="$3"

    local raw_output
    raw_output=$(osmo_vty "$node" "$port" enable "$cmd" end) || return 1

    # Filter banner/prompt lines.
    printf '%s\n' "$raw_output" | osmo_vty_clean 'Free Software lives'
    return 0
}

# ── Quick VTY availability check ─────────────────────────────────────────────
vty_available() {
    osmo_vty_up "$1" "$2"
}

# ── World detection and inventory ────────────────────────────────────────────
MODE="$(osmo_mode)"

# Operators: osmo-operator-N containers in docker; in native mode OSMO_OP_IDS,
# then the osmo-opN netns, then N_OPERATORS from globals.conf, else 1.
mapfile -t OPS < <(osmo_ops)
N_OPS=${#OPS[@]}

# Hub: the osmo-inter-stp container in docker; in native mode this machine IF
# it holds the interstp role. On a native operator node the hub is elsewhere:
# osmo_hub returns 1 and osmo_hub_hint says what to run, and where.
HAS_INTER_STP=0
HUB_NODE="$INTER_STP"
if HUB_NODE="$(osmo_hub)"; then
    HAS_INTER_STP=1
else
    HUB_NODE="$INTER_STP"
fi

# HUB_REMOTE_IP - address of the hub when it does NOT run here: docker WAN
# (start-docker.sh --wan/--hub-ip injects OSMO_HUB_IP into the containers) or
# native operator node. Empty if the hub is local or no address is known.
HUB_REMOTE_IP="$(osmo_hub_is_remote 2>/dev/null || true)"

# HUB_EXPECTED - "a hub should exist" (not "I can query it"). A remote hub is
# expected as soon as an address is known (OSMO_HUB_IP from /etc/osmo-role in
# native, the --hub-ip address seen by the containers in docker WAN): the
# local STP's default route to it is verifiable from here even when the hub's
# internal state is not. In docker WITHOUT WAN both notions coincide: no
# container, no hub.
HUB_EXPECTED=$HAS_INTER_STP
if [ "$HUB_EXPECTED" -eq 0 ] && [ -n "$HUB_REMOTE_IP" ]; then
    HUB_EXPECTED=1
fi

# Expected number of AS/ASP on the hub. In docker it is the number of LOCAL
# operators, which are exactly those attaching to the hub. In native mode the
# hub serves REMOTE operators and no local inventory says how many: judge on
# presence, not on an invented total.
EXPECT_AS=0
[ "$MODE" = docker ] && EXPECT_AS=$N_OPS

if osmo_is_docker; then
    MODE_LABEL="docker (conteneurs osmo-operator-N)"
elif osmo_in_container; then
    MODE_LABEL="natif (dans le conteneur ${HOSTNAME:-?})"
else
    MODE_LABEL="natif (cette machine)"
fi

# Frame line: width computed in CHARACTERS (${#s}), not bytes - "printf %-58s"
# counts bytes and shifts by one per accented character.
boxline() {
    local s="$1" n
    n=$(( 58 - ${#s} )); [ "$n" -lt 0 ] && n=0
    echo -e "${CYAN}║${s}$(printf '%*s' "$n" '')║${NC}"
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
boxline "          SS7 Health Check - $(date '+%H:%M:%S')"
boxline "          mode : ${MODE_LABEL}"
if [ -n "$HUB_REMOTE_IP" ]; then
    boxline "          ${N_OPS} operateur(s)  inter-stp : distant ${HUB_REMOTE_IP}"
else
    boxline "          ${N_OPS} operateur(s)  inter-stp=${HAS_INTER_STP}"
fi
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

if [ "$N_OPS" -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ] && [ -z "$HUB_REMOTE_IP" ]; then
    if [ "$MODE" = docker ]; then
        echo -e "${RED}Aucun container trouve${NC}"
    else
        echo -e "${RED}Aucun operateur ni inter-STP sur cette machine${NC}"
    fi
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 1: Inter-STP (central hub)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ]; then
    # Point code read from the topology (osmo-multi.conf) when available;
    # the hub default is 0.0.0.
    banner "INTER-STP (hub SS7) - $(osmo_hub_pc 2>/dev/null || echo 0.0.0)"

    if ! vty_available "$HUB_NODE" 4239; then
        fail "VTY inter-STP (4239) inaccessible"
    else
        ok "VTY accessible"

        # Check that the inter-STP sees every operator as an AS
        as_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 as all")
        n_as_total=$(echo "$as_output" | grep -acE 'as-op[0-9]+' || true)
        n_as_active=$(echo "$as_output" | grep -acE 'AS_ACTIVE' || true)
        info "AS declares sur le hub : ${n_as_total}"

        if [ "$EXPECT_AS" -gt 0 ]; then
            if [ "$n_as_active" -eq "$EXPECT_AS" ]; then
                ok "AS : ${n_as_active}/${EXPECT_AS} actifs (tous)"
            elif [ "$n_as_active" -gt 0 ]; then
                warn "AS : ${n_as_active}/${EXPECT_AS} actifs"
            else
                fail "AS : aucun actif"
            fi
        elif [ "$n_as_active" -gt 0 ]; then
            # Native: operators are remote machines, the expected total is
            # not knowable from here.
            ok "AS : ${n_as_active} actif(s) (total attendu inconnu en natif)"
        else
            fail "AS : aucun actif"
        fi

        # Check connected ASPs
        asp_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 asp")
        n_asp_active=$(echo "$asp_output" | grep -acE 'ASP_ACTIVE' || true)

        if [ "$EXPECT_AS" -gt 0 ]; then
            if [ "$n_asp_active" -eq "$EXPECT_AS" ]; then
                ok "ASP : ${n_asp_active}/${EXPECT_AS} connectes (tous)"
            else
                warn "ASP : ${n_asp_active}/${EXPECT_AS} connectes"
            fi
        elif [ "$n_asp_active" -gt 0 ]; then
            ok "ASP : ${n_asp_active} connecte(s) (total attendu inconnu en natif)"
        else
            warn "ASP : aucun connecte"
        fi

        # Check the absence of PROHIB (blocked routes)
        route_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 route")
        n_prohib=$(echo "$route_output" | grep -aciE 'prohib' || true)

        if [ "$n_prohib" -eq 0 ]; then
            ok "Routes : aucun PROHIB"
        else
            fail "Routes : ${n_prohib} PROHIB detectees"
        fi
    fi
elif [ -n "$HUB_REMOTE_IP" ]; then
    # REMOTE hub (WAN): "container absent" would be wrong - the hub runs,
    # elsewhere. What is observable from here is the LINK to it.
    banner "INTER-STP (hub distant ${HUB_REMOTE_IP})"

    # The operator → hub link is M3UA over SCTP (osmo-stp.cfg: "asp
    # asp-to-inter 2908 2910 m3ua"). A TCP probe on 2908 would return
    # "Connection refused" on a perfectly established link: the SCTP
    # association, as seen from the nodes, is authoritative.
    hub_assoc="$(osmo_hub_assoc "$HUB_REMOTE_IP" 2>/dev/null)" && hub_rc=0 || hub_rc=$?
    case "$hub_rc" in
        0) ok "Lien M3UA/SCTP → ${HUB_REMOTE_IP}:${OSMO_HUB_M3UA_PORT} : ${hub_assoc} noeud(s) associe(s)" ;;
        1) fail "Aucune association SCTP vers ${HUB_REMOTE_IP}:${OSMO_HUB_M3UA_PORT} (${hub_assoc}) - hub arrete, filtre, ou ASP shutdown" ;;
        *) skip "Association SCTP vers ${HUB_REMOTE_IP} non sondable ici (ss --sctp absent des noeuds)" ;;
    esac

    # No false failure on the hub's INTERNAL state: its VTY listens only on
    # ITS loopback. The sentence comes from _mode.sh and names the real IP.
    skip "$(osmo_hub_hint)"
else
    banner "INTER-STP"
    if [ "$MODE" = docker ]; then
        skip "Container ${INTER_STP} absent"
    else
        # No false failure: the hub may be perfectly alive, but its VTY listens
        # only on ITS loopback. The sentence comes from _mode.sh and names the
        # hub's real IP when /etc/osmo-role gives it.
        skip "$(osmo_hub_hint)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 2: each operator
# ══════════════════════════════════════════════════════════════════════════════
for op in ${OPS[@]+"${OPS[@]}"}; do
    op_id="$op"
    # osmo_node keeps the "osmo-operator-N" label even in native mode: it is
    # the display name the other checks correlate on.
    container="$(osmo_node "$op")"
    # The label reflects the topology (osmo-multi.conf) when it exists: the
    # point code comes from the local plan, and a native operator is shown as
    # running on the host rather than as a container.
    _pc="$(osmo_op_pc "$op_id" 2>/dev/null || true)"
    if [ "$(osmo_op_mode "$op_id" 2>/dev/null)" = "native" ]; then
        _label="natif (hote)"
    else
        _label="$container"
    fi
    banner "OPERATEUR ${op_id} (${_label}) - STP ${_pc:-inconnu}"

    # ── Local STP (4239) ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}STP local :${NC}"
    if ! vty_available "$op" 4239; then
        fail "STP VTY (4239) inaccessible"
    else
        # Check the connection to the inter-STP
        as_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 as all")
        inter_state=$(echo "$as_out" | grep -aoP 'as-inter\s+\K(AS_\w+)' || echo "ABSENT")

        if [[ "$inter_state" == "AS_ACTIVE" ]]; then
            ok "as-inter → hub : ACTIVE"
        elif [[ "$inter_state" == "ABSENT" ]] && [ "$HUB_EXPECTED" -eq 1 ]; then
            fail "as-inter absent (pas de connexion au hub)"
        elif [[ "$inter_state" == "ABSENT" ]]; then
            skip "as-inter : ignore (aucun inter-STP connu depuis ce noeud)"
        else
            warn "as-inter : ${inter_state}"
        fi

        # Check local ASPs (MSC/BSC)
        asp_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 asp")
        n_asp_ok=$(echo "$asp_out" | grep -acE 'ASP_ACTIVE' || true)

        if [ "$n_asp_ok" -ge 2 ]; then
            ok "ASP locaux : au moins 2 actifs (MSC+BSC)"
        elif [ "$n_asp_ok" -eq 1 ]; then
            warn "ASP locaux : 1 seul actif (manque MSC ou BSC)"
        else
            fail "ASP locaux : aucun actif"
        fi

        # Check the default route to the inter-STP (key element). Verifiable
        # as soon as a hub is EXPECTED: the remote hub of a native lab shows up
        # in the local STP routing table even when its own VTY is out of reach.
        route_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 route")
        has_default=$(echo "$route_out" | grep -acE '0\.0\.0/0.*avail' || true)

        if [ "$has_default" -gt 0 ] && [ "$HUB_EXPECTED" -eq 1 ]; then
            ok "Route par defaut → inter-STP : presente et avail"
        elif [ "$HUB_EXPECTED" -eq 1 ]; then
            fail "Route par defaut → inter-STP absente ou non avail"
        elif [ "$MODE" != docker ]; then
            skip "Route par defaut → inter-STP : ignore (natif, aucun hub declare ici)"
        fi

        # Check the absence of PROHIB
        n_prohib=$(echo "$route_out" | grep -aciE 'prohib' || true)
        if [ "$n_prohib" -gt 0 ]; then
            fail "Routes PROHIB detectees : ${n_prohib}"
        fi

        # Count dynamic routes (information only)
        n_dyn=$(echo "$route_out" | grep -ac 'dyn' || true)
        info "Routes dynamiques apprises : ${n_dyn} (normal: devrait augmenter avec le nombre d'operateurs)"
    fi

    # In quick mode, move on to the next operator
    if [ "$QUICK" -eq 1 ]; then
        continue
    fi

    # ── MSC (4254) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}MSC :${NC}"
    if ! vty_available "$op" 4254; then
        fail "MSC VTY (4254) inaccessible"
    else
        msc_asp=$(vty_cmd "$op" 4254 "show cs7 instance 0 asp")
        msc_active=$(echo "$msc_asp" | grep -acE 'ASP_ACTIVE' || true)
        [ "$msc_active" -gt 0 ] && ok "MSC→STP : ASP_ACTIVE" || fail "MSC→STP : pas de ASP actif"

        # SCCP - osmo_qgrep rather than "grep -aq": at the end of a pipe,
        # grep -aq exits on the first match and kills the producer with
        # SIGPIPE (141 under pipefail).
        msc_sccp=$(vty_cmd "$op" 4254 "show cs7 instance 0 sccp users")
        echo "$msc_sccp" | osmo_qgrep -aE 'SSN 254' && ok "SCCP SSN 254 (MSC-A) enregistre" || fail "SCCP SSN 254 absent"
    fi

    # ── BSC (4242) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}BSC :${NC}"
    if ! vty_available "$op" 4242; then
        fail "BSC VTY (4242) inaccessible"
    else
        bsc_asp=$(vty_cmd "$op" 4242 "show cs7 instance 0 asp")
        bsc_active=$(echo "$bsc_asp" | grep -acE 'ASP_ACTIVE' || true)
        [ "$bsc_active" -gt 0 ] && ok "BSC→STP : ASP_ACTIVE" || fail "BSC→STP : pas de ASP actif"

        # SCCP
        bsc_sccp=$(vty_cmd "$op" 4242 "show cs7 instance 0 sccp users")
        echo "$bsc_sccp" | osmo_qgrep -aE 'SSN 254' && ok "SCCP SSN 254 (BSC) enregistre" || fail "SCCP SSN 254 absent"

        # BTS state (optional)
        bsc_bts=$(vty_cmd "$op" 4242 "show bts 0" 2>/dev/null || echo "")
        if echo "$bsc_bts" | osmo_qgrep -aE "Oper 'Enabled'.*Avail 'OK'"; then
            ok "BTS 0 : OK"
        fi
    fi

    # ── HLR (4258) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}HLR :${NC}"
    if ! vty_available "$op" 4258; then
        fail "HLR VTY (4258) inaccessible"
    else
        hlr_gsup=$(vty_cmd "$op" 4258 "show gsup-connections")
        vlr_conn=$(echo "$hlr_gsup" | grep -acE "VLR" || true)
        [ "$vlr_conn" -gt 0 ] && ok "GSUP : VLR connecte" || fail "GSUP : VLR absent"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 3: simple connectivity matrix
# ══════════════════════════════════════════════════════════════════════════════
# The matrix crosses the LOCAL operators with each other through the hub: it
# makes sense as soon as a hub is EXPECTED (local, or remote over WAN - op1↔op2
# traffic crosses it in both cases) and there is more than one operator here.
# On a single operator it would reduce to one "self" cell: it is reported as
# skipped, pointing to the check that looks between machines.
if [ "$HUB_EXPECTED" -eq 1 ] && [ "$N_OPS" -gt 1 ]; then
    if [ -n "$HUB_REMOTE_IP" ]; then
        banner "MATRICE DE CONNECTIVITE (via inter-STP distant ${HUB_REMOTE_IP})"
    else
        banner "MATRICE DE CONNECTIVITE (via inter-STP)"
    fi

    printf "  %-8s" ""
    for j in "${OPS[@]}"; do printf "  Op%-3s" "$j"; done
    echo ""

    for op in "${OPS[@]}"; do
        src_id="$op"
        printf "  Op%-5s" "${src_id}"

        # Only basic connectivity is tested: does the operator have a default route?
        route_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 route" 2>/dev/null || echo "")
        has_default=$(echo "$route_out" | grep -acE '0\.0\.0/0.*avail' || true)

        for j in "${OPS[@]}"; do
            if [ "$j" -eq "$src_id" ]; then
                printf "  ${CYAN}%-5s${NC}" "self"
            elif [ "$has_default" -gt 0 ]; then
                # With a default route, connectivity through the inter-STP is assumed
                printf "  ${GREEN}%-5s${NC}" "via"
            else
                printf "  ${RED}%-5s${NC}" "FAIL"
                FAIL=$((FAIL+1))
            fi
        done
        echo ""
    done
    echo ""
    echo "  Note: 'via' signifie que l'operateur a une route par defaut vers l'inter-STP"
    echo "  Les routes dynamiques specifiques sont apprises au fur et a mesure"
elif [ "$MODE" != docker ]; then
    banner "MATRICE DE CONNECTIVITE (via inter-STP)"
    skip "ignore (natif) : ${N_OPS} operateur(s) local(aux) - la connectivite entre operateurs passe par le WAN, voir checks/wan_ss7_check.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "$(printf '═%.0s' {1..60})"

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}SS7 OK${NC}  -  ${GREEN}${PASS} pass${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
elif [ "$FAIL" -le 3 ]; then
    echo -e "  ${YELLOW}${BOLD}SS7 DEGRADE${NC}  -  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
else
    echo -e "  ${RED}${BOLD}SS7 KO${NC}  -  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
fi
echo -e "$(printf '═%.0s' {1..60})"
echo ""

exit "$FAIL"
