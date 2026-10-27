#!/bin/bash
# vty-debug-dump.sh - Dump every Osmocom VTY of each operator and of the inter-STP
#
# Walks every Osmocom VTY of each operator AND of the inter-STP, enables the
# DEBUG log level, runs the relevant "show" commands and consolidates
# everything into one log file.
#
# TWO WORLDS, automatic detection (checks/_mode.sh):
#   docker: one osmo-operator-N container per operator, the SS7 hub is the
#           osmo-inter-stp container; VTYs are queried through "docker exec".
#   native: ISO, VM or bare machine - a single operator (unless netns
#           topology), VTYs reached by telnet on 127.0.0.1. What exists only
#           under docker (the inter-STP container) is EXPLICITLY SKIPPED: a
#           dump inventing an absent hub would read as an SS7 outage.
#
# The "container=osmo-operator-N" label is written in the dump IN BOTH MODES:
# checks/operator_summary.sh anchors all its extractions on it
# (grep -A20 "container=..."). In native mode it is a display name, a
# correlation key, not a queryable object.
#
# VTYs covered per operator:
#   OsmoSTP          4239
#   OsmoHLR          4258
#   OsmoMGW          4243
#   OsmoMSC          4254
#   OsmoBSC          4242
#   OsmoBTS          4241
#   OsmoPCU          4240
#   OsmoSGSN         4245
#   OsmoGGSN         4260
#   OsmoSIP-conn     4255
#
# Inter-STP (SS7 hub) VTY:
#   OsmoSTP (hub)    4239 (or the port bound in /etc/osmocom/osmo-stp-interop.cfg)
#
# Usage:
#   sudo ./checks/vty-debug-dump.sh [--out /path/log.txt] [--docker|--native]
# Environment: OUTFILE (default /tmp/vty-debug-dump.txt), OSMO_MODE=docker|native.

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Saved BEFORE sourcing: the library writes into OSMO_MODE (memoisation), so
# afterwards it cannot be told whether the value came from the environment.
MODE_ENV="${OSMO_MODE:-}"

# ── Common docker/native library ─────────────────────────────────────────────
# Looked up RELATIVE to the script (BASH_SOURCE): the repo and the ISO do not
# share the same root, and the ISO ships checks/ as a whole, so _mode.sh is
# always next to this file.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo-operator/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Options ──────────────────────────────────────────────────────────────────
# --out is accepted AT ANY POSITION: operator_summary.sh --live runs
# "./vty-debug-dump.sh --out /tmp/vty-live-$$.txt" and must keep working even
# when preceded by --native.
OUTFILE="${OUTFILE:-/tmp/vty-debug-dump.txt}"
MODE_FORCED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ -n "${2:-}" ] || { echo "--out attend un chemin" >&2; exit 1; }
            OUTFILE="$2"; shift 2 ;;
        --out=*)
            OUTFILE="${1#*=}"; shift ;;
        --docker|--native|--mode=*)
            osmo_mode_force "$1" || { echo "mode inconnu : $1" >&2; exit 1; }
            MODE_FORCED=1; shift ;;
        -h|--help)
            echo "Usage : sudo ./vty-debug-dump.sh [--out /chemin/log.txt] [--docker|--native]"
            echo "  --docker  force le mode conteneurs (docker exec)"
            echo "  --native  force le mode natif (VTY locaux sur 127.0.0.1)"
            echo "  sans option : detection automatique"
            exit 0 ;;
        *)
            echo "option inconnue : $1" >&2
            echo "Usage : sudo ./vty-debug-dump.sh [--out /chemin/log.txt] [--docker|--native]" >&2
            exit 1 ;;
    esac
done

INTER_STP_CONTAINER="$(osmo_node hub)"   # "osmo-inter-stp" in both modes

# ── VTY tables: two sets (operator / inter-stp) ──────────────────────────────
declare -A OP_VTY_NAME OP_VTY_SHOW
declare -A ISTP_VTY_NAME ISTP_VTY_SHOW

register_op_vty() {
    local port="$1" name="$2" show_cmds="$3"
    OP_VTY_NAME[$port]="$name"
    OP_VTY_SHOW[$port]="$show_cmds"
}

register_istp_vty() {
    local port="$1" name="$2" show_cmds="$3"
    ISTP_VTY_NAME[$port]="$name"
    ISTP_VTY_SHOW[$port]="$show_cmds"
}

# ── Operator show commands ───────────────────────────────────────────────────

register_op_vty 4239 "OsmoSTP" "\
show cs7 instance 0 users|\
show cs7 instance 0 as all|\
show cs7 instance 0 asp|\
show cs7 instance 0 route|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show cs7 instance 0 sccp timers|\
show logging level|\
show talloc-context all brief"

register_op_vty 4258 "OsmoHLR" "\
show subscriber all|\
show subscriber count|\
show gsup-connections|\
show logging level|\
show talloc-context all brief"

register_op_vty 4243 "OsmoMGW" "\
show mgcp stats|\
show mgcp active|\
show mgcp endpoint Name trunk-0|\
show logging level|\
show talloc-context all brief"

register_op_vty 4254 "OsmoMSC" "\
show network|\
show subscriber all|\
show subscriber count|\
show transaction all|\
show call-legs|\
show connection|\
show sgs-connections|\
show cs7 instance 0 users|\
show cs7 instance 0 asp|\
show cs7 instance 0 as all|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4242 "OsmoBSC" "\
show network|\
show bts all|\
show bts 0|\
show trx 0 0|\
show timeslot all|\
show lchan all|\
show lchan summary|\
show paging all|\
show paging-group all|\
show conns|\
show cs7 instance 0 users|\
show cs7 instance 0 asp|\
show cs7 instance 0 as all|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4241 "OsmoBTS" "\
show bts 0|\
show trx 0 0|\
show ts all|\
show lchan all|\
show lchan summary|\
show phy 0 inst all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4240 "OsmoPCU" "\
show bts all|\
show tbf all|\
show ms all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4245 "OsmoSGSN" "\
show sgsn|\
show mm-context all|\
show pdp-context all|\
show subscriber cache|\
show ns|\
show ns stats|\
show ns entities|\
show bssgp|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4260 "OsmoGGSN" "\
show ggsn|\
show pdp-context all|\
show apn all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4255 "OsmoSIPconn" "\
show logging level|\
show talloc-context all brief"

OP_VTY_PORTS=(4239 4258 4243 4254 4242 4241 4240 4245 4260 4255)

# ── Inter-STP show commands - sweep of instances 0..9 ────────────────────────
# The inter-STP hub may have N CS7 instances (one per operator link).

ISTP_SHOW_CMDS="show cs7 instance 0 users|\
show cs7 instance 0 as all|\
show cs7 instance 0 as all active|\
show cs7 instance 0 asp|\
show cs7 instance 0 route|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show cs7 instance 0 sccp timers|\
show cs7 instance 1 users|\
show cs7 instance 1 as all|\
show cs7 instance 1 asp|\
show cs7 instance 1 route|\
show cs7 instance 1 sccp users|\
show cs7 instance 1 sccp connections|\
show cs7 instance 2 users|\
show cs7 instance 2 as all|\
show cs7 instance 2 asp|\
show cs7 instance 2 route|\
show cs7 instance 2 sccp users|\
show cs7 instance 2 sccp connections|\
show cs7 instance 3 users|\
show cs7 instance 3 as all|\
show cs7 instance 3 asp|\
show cs7 instance 3 route|\
show cs7 instance 4 as all|\
show cs7 instance 4 asp|\
show cs7 instance 4 route|\
show cs7 instance 5 as all|\
show cs7 instance 5 asp|\
show cs7 instance 5 route|\
show cs7 instance 6 as all|\
show cs7 instance 6 asp|\
show cs7 instance 6 route|\
show cs7 instance 7 as all|\
show cs7 instance 7 asp|\
show cs7 instance 7 route|\
show cs7 instance 8 as all|\
show cs7 instance 8 asp|\
show cs7 instance 8 route|\
show cs7 instance 9 as all|\
show cs7 instance 9 asp|\
show cs7 instance 9 route|\
show logging level|\
show stats|\
show talloc-context all brief"

# The hub may have been moved off port 4239 (co-located with the operator
# STP, see start-interstp.sh): read its VTY port from its config. In docker
# the hub stays on 4239 (queried through docker exec) and the host file is
# absent: sed returns nothing and 4239 is kept.
ISTP_HUB_VTY=4239
_hubp="$(sed -n 's/^ *bind 127\.0\.0\.1 \([0-9]*\)$/\1/p' /etc/osmocom/osmo-stp-interop.cfg 2>/dev/null | head -1)"
[ -n "$_hubp" ] && ISTP_HUB_VTY="$_hubp"
register_istp_vty "$ISTP_HUB_VTY" "OsmoSTP-hub" "$ISTP_SHOW_CMDS"

ISTP_VTY_PORTS=("$ISTP_HUB_VTY")

# ── Node inventory - docker or native ────────────────────────────────────────
MODE="$(osmo_mode)"
# An environment OSMO_MODE that is neither docker nor native is ignored by the
# library (it re-detects): it is therefore not reported as forced.
if   [ "$MODE_FORCED" -eq 1 ]; then MODE_SRC="force par option"
elif [ "$MODE_ENV" = docker ] || [ "$MODE_ENV" = native ]; then MODE_SRC="force par OSMO_MODE"
else MODE_SRC="detection automatique"
fi

# osmo_ops: osmo-operator-N containers in docker; OSMO_OP_IDS / netns /
# N_OPERATORS (else 1) in native. Already numerically sorted and deduplicated.
mapfile -t OPS < <(osmo_ops)
OP_CONTAINERS=()
for op in "${OPS[@]:-}"; do
    [ -n "$op" ] && OP_CONTAINERS+=("$(osmo_node "$op")")
done

# Inter-STP: present IF it can be queried FROM HERE.
#   docker: the osmo-inter-stp container is running.
#   native: this machine IS the hub (OSMO_ROLE=interstp, or an osmo-stp started
#           on osmo-stp-interop.cfg). If the hub is another machine, its VTY
#           listens only on ITS 127.0.0.1: nothing can be dumped from here and
#           this is stated - an empty "OsmoSTP-hub" block would read as a
#           dead hub.
HAS_INTER_STP=0
osmo_hub >/dev/null 2>&1 && HAS_INTER_STP=1

if [ ${#OP_CONTAINERS[@]} -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ]; then
    echo -e "${RED}Aucun container osmo-operator-N ni ${INTER_STP_CONTAINER} trouve.${NC}"
    if [ "$MODE" = docker ]; then
        echo -e "  Containers actifs : $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
    else
        echo -e "  Mode natif : aucun operateur declare (OSMO_OP_IDS, netns ${OSMO_NETNS_PREFIX}N, N_OPERATORS)."
    fi
    exit 1
fi

N_OPS=${#OP_CONTAINERS[@]}
# The mode is printed BEFORE anything else: a diagnostic that does not say
# which world it looked at is not usable.
echo -e "${CYAN}Mode : ${MODE} (${MODE_SRC})${NC}"
echo -e "${GREEN}=== VTY Debug Dump - ${N_OPS} operateur(s) + inter-stp=${HAS_INTER_STP} → ${OUTFILE} ===${NC}"
echo ""

# ── Clear / initialise the output file ───────────────────────────────────────
: > "$OUTFILE"
log() { echo -e "$*" | tee -a "$OUTFILE"; }
logsep() {
    local title="$1"
    log ""
    log "$(printf '═%.0s' {1..72})"
    log "  ${title}"
    log "$(printf '═%.0s' {1..72})"
}
logsubsep() {
    local title="$1"
    log ""
    log "  $(printf '─%.0s' {1..68})"
    log "  ${title}"
    log "  $(printf '─%.0s' {1..68})"
}

log "VTY DEBUG DUMP - $(date '+%Y-%m-%d %H:%M:%S')"
log "Mode       : ${MODE} (${MODE_SRC})"
log "Operateurs : ${N_OPS}   Containers : ${OP_CONTAINERS[*]:-aucun}"
if   [ "$HAS_INTER_STP" -eq 1 ]; then log "Inter-STP  : present"
elif [ "$MODE" = docker        ]; then log "Inter-STP  : absent"
else                                  log "Inter-STP  : ignore (natif) - $(osmo_hub_hint)"
fi

# ── Query one VTY on a node ──────────────────────────────────────────────────
# $1=<op> (operator number or "hub")  $2=port  $3=name  $4=show commands
# osmo_vty_up / osmo_vty handle the dialogue (docker exec, or local in native
# mode). The "container=" field of the dump keeps the node label.
query_vty() {
    local op="$1"
    local port="$2"
    local name="$3"
    local show_str="$4"
    local container
    container="$(osmo_node "$op")"

    # Quick connectivity test. In native mode the passive probe (ss) runs
    # first: it opens no VTY session.
    if ! osmo_vty_up "$op" "$port"; then
        echo -e "  ${YELLOW}[SKIP]${NC} ${name} (port ${port}) - non disponible"
        log "  [SKIP] ${name} port ${port} - non disponible"
        return 1
    fi

    echo -ne "  ${CYAN}${name}${NC} (${port}) ... "

    # Build the VTY script: switch to DEBUG, then the show commands, then end.
    local -a VTY_CMDS=(enable "logging level all debug" "logging filter all 1")
    IFS='|' read -ra SHOW_CMDS <<< "$show_str"
    for cmd in "${SHOW_CMDS[@]}"; do
        VTY_CMDS+=("$cmd")
    done
    VTY_CMDS+=(end)

    # Timings (nc -q2, 0.5 s before writing, 2 s of reading): these are large
    # command sets, and changing these values changes the AMOUNT of output
    # captured - hence the line count printed right after.
    local raw_output
    raw_output="$(OSMO_VTY_OPEN=0.5 OSMO_VTY_READ=2 OSMO_VTY_Q=2 \
                  osmo_vty "$op" "$port" "${VTY_CMDS[@]}" || true)"

    # Filter VTY banner/prompt. Without argument the "Free Software lives" line
    # is KEPT, unlike global_check.sh and ss7_check.sh.
    local clean_output
    clean_output="$(printf '%s\n' "$raw_output" | osmo_vty_clean)"

    local n_lines
    n_lines=$(echo "$clean_output" | wc -l)
    echo -e "${GREEN}${n_lines} lignes${NC}"

    {
        echo ""
        echo "  [${name}] port=${port}  container=${container}"
        echo "  Commandes show : $(echo "$show_str" | tr '|' ', ')"
        echo ""
        echo "$clean_output" | sed 's/^/    /'
    } >> "$OUTFILE"

    return 0
}

# ── Main loop: operator nodes ────────────────────────────────────────────────
TOTAL_OK=0
TOTAL_SKIP=0

for op in "${OPS[@]:-}"; do
    [ -n "$op" ] || continue
    container="$(osmo_node "$op")"
    logsep "Container : ${container}  -  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${container} ---${NC}"

    for port in "${OP_VTY_PORTS[@]}"; do
        logsubsep "${OP_VTY_NAME[$port]} (port ${port})"
        if query_vty "$op" "$port" \
                "${OP_VTY_NAME[$port]}" "${OP_VTY_SHOW[$port]}"; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
done

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ "$HAS_INTER_STP" -eq 1 ]; then
    logsep "Container : ${INTER_STP_CONTAINER} (hub SS7)  -  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${INTER_STP_CONTAINER} ---${NC}"

    for port in "${ISTP_VTY_PORTS[@]}"; do
        logsubsep "${ISTP_VTY_NAME[$port]} (port ${port})"
        if query_vty hub "$port" \
                "${ISTP_VTY_NAME[$port]}" "${ISTP_VTY_SHOW[$port]}"; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
elif [ "$MODE" = docker ]; then
    log ""
    log "  [INFO] Container ${INTER_STP_CONTAINER} absent - skipped"
else
    # Native without a local hub: neither OK nor failure, and no counter
    # touched - there is nothing to query here, it is not an outage.
    echo -e "  ${YELLOW}${INTER_STP_CONTAINER} - ignore (natif)${NC}"
    echo -e "  ${YELLOW}  $(osmo_hub_hint)${NC}"
    log ""
    log "  [INFO] ${INTER_STP_CONTAINER} - ignore (natif) : $(osmo_hub_hint)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
logsep "RESUME - $(date '+%Y-%m-%d %H:%M:%S')"
log "  Mode                  : ${MODE} (${MODE_SRC})"
log "  VTY interroges        : ${TOTAL_OK}"
log "  VTY non disponibles   : ${TOTAL_SKIP}"
log "  Operateurs            : ${N_OPS}"
if   [ "$HAS_INTER_STP" -eq 1 ]; then log "  Inter-STP             : oui"
elif [ "$MODE" = docker        ]; then log "  Inter-STP             : non"
else                                  log "  Inter-STP             : ignore (natif)"
fi
log "  Fichier               : ${OUTFILE}"
log "  Taille                : $(wc -c < "$OUTFILE") octets  /  $(wc -l < "$OUTFILE") lignes"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Dump complet → ${OUTFILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Consulter :${NC}  less ${OUTFILE}"
echo -e "  ${CYAN}Filtrer   :${NC}  grep -A5 'OsmoBSC' ${OUTFILE}"
echo -e "  ${CYAN}SS7 hub   :${NC}  grep -A10 'OsmoSTP-hub' ${OUTFILE}"
echo -e "  ${CYAN}Routes    :${NC}  grep -A20 'show cs7.*route' ${OUTFILE}"
echo -e "  ${CYAN}ASP etat  :${NC}  grep -iE 'asp|active|inactive|down' ${OUTFILE}"
echo -e "  ${CYAN}SCCP      :${NC}  grep -A10 'sccp' ${OUTFILE}"
echo -e "  ${CYAN}Erreurs   :${NC}  grep -iE 'error|fail|warn|prohib|timeout|refused' ${OUTFILE}"

# Local copy when run from the host
if [ -w "$(pwd)" ]; then
    cp "$OUTFILE" "$(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" 2>/dev/null && \
        echo -e "  ${CYAN}Copie locale :${NC} $(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" || true
fi
