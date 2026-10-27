#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/set-node-id.sh - gives THIS machine its SS7 node identity
#
# A single ISO for every node: the number is chosen at start-up, not at build
# time. This script rewrites what designates the node in the Osmocom configs,
# i.e. its POINT CODES and its routing contexts.
#
#   local plan (one machine)   1.<op>.<role>          op×100 + {10,20,30,50}
#   WAN plan   (N machines)    1.<node><op>.<role>     node×1000 + op×100 + ...
#
# Why the local plan cannot stay: the formula gives the same result on every
# machine. Three nodes attached to the same inter-STP would all present
# 1.11.2. A point code is an ADDRESS - two devices sharing one is not a name
# clash, it is wrong routing, and the hub has no way to notice.
#
# Three files carry this identity, and they must agree:
#   osmo-stp.cfg   its own PC, its routing-key, its ASP towards the hub
#   osmo-msc.cfg   its PC, its routing-key, and the PC of the BSC it calls
#   osmo-bsc.cfg   its PC, its routing-key, and the PC of the MSC it calls
# Missing one gives a core that starts and calls that do not complete.
#
# Idempotent: it reads the current state and replaces it. --node 2 after
# --node 1 works, there is no state to clean between the two.
#
# Usage:
#   sudo network/set-node-id.sh --node 3 [--op 1] [--hub-ip 192.168.1.49]
#   sudo network/set-node-id.sh --show          current state, changes nothing
#   sudo network/set-node-id.sh --node 3 --local   local plan (cancels the WAN plan)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# wan_detect_local_ip lives there: the same address selection rule as the one
# start-docker.sh and start-native.sh apply, so that both always designate
# the same card.
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/wan-nodes.sh"

NODE=""
OP=1
HUB_IP=""
MODE=""            # docker | native - the addressing differs
LOCAL_IP=""        # source address of the ASP; "auto" = detected
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
SHOW=0
LOCAL_PLAN=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --node)     NODE="${2:-}"; shift ;;
        --node=*)   NODE="${1#*=}" ;;
        --op)       OP="${2:-1}"; shift ;;
        --op=*)     OP="${1#*=}" ;;
        --local-ip)   LOCAL_IP="${2:-}"; shift ;;
        --local-ip=*) LOCAL_IP="${1#*=}" ;;
        --hub-ip)   HUB_IP="${2:-}"; shift ;;
        --hub-ip=*) HUB_IP="${1#*=}" ;;
        --conf-dir)   CONF_DIR="${2:-}"; shift ;;
        --conf-dir=*) CONF_DIR="${1#*=}" ;;
        --mode)     MODE="${2:-}"; shift ;;
        --mode=*)   MODE="${1#*=}" ;;
        --docker)   MODE="docker" ;;
        --native)   MODE="native" ;;
        --show)     SHOW=1 ;;
        --local)    LOCAL_PLAN=1 ;;
        --dry-run)  DRY=1 ;;
        -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

STP="$CONF_DIR/osmo-stp.cfg"
MSC="$CONF_DIR/osmo-msc.cfg"
BSC="$CONF_DIR/osmo-bsc.cfg"

# ── Reading the identity in place ───────────────────────────────────────────
# The first point-code of a file is THE DAEMON'S; the following ones, inside
# an "sccp-address" block, designate its peers. This distinction structures
# the whole rewrite.
own_pc() { awk '/^cs7 instance/{c=1} c && /^ *point-code /{print $2; exit}' "$1" 2>/dev/null; }

show_state() {
    local f n
    printf '  %-16s %-10s %-12s %-16s %s\n' FICHIER "POINT CODE" "ROUTING-KEY" "ASP INTER-STP" "SOURCE"
    for f in "$STP" "$MSC" "$BSC"; do
        [ -r "$f" ] || { printf '  %-16s %s\n' "$(basename "$f")" "absent"; continue; }
        local pc rk asp
        pc="$(own_pc "$f")"
        rk="$(awk '/^ *routing-key /{print $2; exit}' "$f")"
        asp="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$f")"
        local src
        src="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$f")"
        printf '  %-16s %-10s %-12s %-16s %s\n' "$(basename "$f")" "${pc:--}" "${rk:--}" "${asp:--}" "${src:--}"
    done
}

if [ "$SHOW" = "1" ]; then
    [ -n "$MODE" ] || { [ -f /.dockerenv ] && MODE=docker || MODE=native; }
    echo -e "${BOLD}Identite SS7 de cette machine${NC}  (mode ${CYAN}${MODE}${NC})"
    show_state
    exit 0
fi

[[ "$NODE" =~ ^[1-9]$ ]] || { echo -e "${RED}--node : un chiffre de 1 a 9${NC}" >&2; exit 2; }
[[ "$OP"   =~ ^[1-9]$ ]] || { echo -e "${RED}--op : un chiffre de 1 a 9${NC}" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis (ecriture dans ${CONF_DIR}).${NC}" >&2; exit 1; }

for f in "$STP" "$MSC" "$BSC"; do
    [ -w "$f" ] || { echo -e "${RED}$f introuvable ou non modifiable${NC}" >&2; exit 1; }
done

# ── The new plan ────────────────────────────────────────────────────────────
if [ "$LOCAL_PLAN" = "1" ]; then
    MID="$OP"                       # 1.<op>.<role> - plan of an isolated machine
    RBASE=$(( OP * 100 ))
else
    MID="${NODE}${OP}"              # 1.<node><op>.<role> - WAN plan
    RBASE=$(( NODE * 1000 + OP * 100 ))
fi
PC_MSC="1.${MID}.1"; PC_STP="1.${MID}.2"; PC_BSC="1.${MID}.3"
RCTX_MSC=$(( RBASE + 10 )); RCTX_STP=$(( RBASE + 20 ))
RCTX_BSC=$(( RBASE + 30 )); RCTX_INTER=$(( RBASE + 50 ))

# ── DOCKER OR VM: two address plans, and the default of one is wrong in the
# other ────────────────────────────────────────────────────────────────────
#   docker: the hub is the osmo-inter-stp container, 172.20.0.10, on the
#           gsm-inter network. The node already has its IP when osmo-stp starts.
#   VM/ISO: the hub is a separate machine, on the LAN in bridged mode. The
#           node's address comes from DHCP and is not necessarily up at
#           start-up.
# A wrong default gives an ASP that never attaches, and the log only says
# "connection refused" - without telling that the target address exists
# nowhere on that network.
#
# The VirtualBox host-only address (192.168.56.1) is WRONG as soon as the VMs
# are bridged: the address exists on no segment, and the ASP aims at it
# without ever reaching anything. The address is therefore ASKED instead of
# guessed, with the bench hub as default. An EMPTY answer is accepted when it
# is not known yet: in that case the remote-ip already present in the file is
# left untouched - better to write nothing than to write a wrong address.
#
if [ -z "$MODE" ]; then
    if [ -f /.dockerenv ]; then MODE="docker"; else MODE="native"; fi
fi

: "${HUB_IP_DEFAULT:=172.20.0.10}"    # the bench hub: osmo-inter-stp, docker backbone

if [ -z "$HUB_IP" ]; then
    if [ -r /etc/osmo-role ]; then
        HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role)"
    fi
fi
if [ -z "$HUB_IP" ]; then
    case "$MODE" in
        docker) HUB_IP="${INTER_STP_IP:-172.20.0.10}" ;;
        *)
            # Interactive: ask. Otherwise (ISO, service, CI) take the bench
            # default - a non-interactive script cannot answer, and blocking
            # on a read would only fail later.
            if [ -t 0 ] && [ "$DRY" != "1" ] && command -v _wan_ask >/dev/null 2>&1; then
                HUB_IP="$(_wan_ask "Inter-STP" \
                    "IP de l'inter-STP (vide si inconnue) :" "$HUB_IP_DEFAULT")" || exit 1
            else
                HUB_IP="$HUB_IP_DEFAULT"
            fi ;;
    esac
fi

# Empty is accepted: the remote-ip is not rewritten. The rest (point codes,
# routing-keys, local-ip) keeps its meaning and is applied anyway.
SET_HUB_IP=1
if [ -z "$HUB_IP" ]; then
    SET_HUB_IP=0
    echo -e "  ${YELLOW}Inter-STP inconnu : remote-ip laisse tel quel dans les fichiers.${NC}"
    echo -e "  ${YELLOW}Renseignez-le plus tard : --hub-ip ADRESSE, ou set_stp_ip.sh${NC}"
fi

# ── SOURCE address of the ASP towards the hub ───────────────────────────────
# In docker it is left alone: the container has its address before the daemon
# starts, and an explicit source keeps SCTP from announcing several addresses
# (multi-homing) to a peer that expects only one.
#
# In a VM, the address actually detected on the VirtualBox segment is
# INJECTED rather than 0.0.0.0. The difference is not cosmetic: with 0.0.0.0,
# SCTP announces ALL local addresses in its INIT - including the 10.0.2.15 NAT
# and the 172.20.x aliases the ISO sets. The hub then tries to reach addresses
# that, seen from it, lead nowhere. A single correct address beats a
# multi-homing with three dead branches out of four.
#
# Falls back to 0.0.0.0 when no address is detectable - binding there beats
# binding to a missing address, which prevents osmo-stp from starting.
SET_LOCAL_IP=0
ASP_LOCAL_IP=""
if [ "$MODE" != "docker" ]; then
    SET_LOCAL_IP=1
    case "$LOCAL_IP" in
        "" | auto)
            # ── The address that ROUTES to the hub, before any heuristic ────
            # The kernel knows exactly which source it will use to reach the
            # hub: that is what "ip route get" answers. Any other method
            # guesses - and guesses wrong as soon as the machine carries
            # several private addresses. A bench VM has three (192.168.1.2 the
            # bridge, 192.168.2.1 and .2.10 the ISO's private plan): a
            # heuristic may pick 192.168.2.1, an address the hub cannot reach
            # back; the ASP would then go nowhere and the log would only say
            # "connect failed (-110)" - a timeout, with no hint about the
            # faulty source.
            if [ -n "$HUB_IP" ]; then
                ASP_LOCAL_IP="$(ip route get "$HUB_IP" 2>/dev/null \
                                | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
                [ -n "$ASP_LOCAL_IP" ] && LOCAL_IP_SRC="route vers le hub"
            fi
            if [ -n "$ASP_LOCAL_IP" ]; then
                :
            elif ! command -v wan_detect_local_ip >/dev/null 2>&1; then
                echo -e "${RED}wan_detect_local_ip introuvable - network/wan-nodes.sh non charge${NC}" >&2
                exit 1
            else
                ASP_LOCAL_IP="$(wan_detect_local_ip || true)"
            fi
            if [ -n "$ASP_LOCAL_IP" ]; then
                [ -n "${LOCAL_IP_SRC:-}" ] || LOCAL_IP_SRC="detectee sur le segment"
            else
                ASP_LOCAL_IP="0.0.0.0"
                LOCAL_IP_SRC="aucune adresse detectee - repli"
            fi ;;
        *)  ASP_LOCAL_IP="$LOCAL_IP"; LOCAL_IP_SRC="imposee par --local-ip" ;;
    esac
fi

echo -e "${BOLD}Noeud ${NODE} - operateur ${OP}${NC}   (mode ${CYAN}${MODE}${NC})"
echo -e "  STP ${CYAN}${PC_STP}${NC}   MSC ${CYAN}${PC_MSC}${NC}   BSC ${CYAN}${PC_BSC}${NC}"
echo -e "  routing-key : stp ${RCTX_STP} · msc ${RCTX_MSC} · bsc ${RCTX_BSC} · inter ${RCTX_INTER}"
if [ "$LOCAL_PLAN" = "1" ] && [ -z "$HUB_IP" ]; then
    echo -e "  ${YELLOW}plan LOCAL sans hub : point codes 1.<op>.<role>, ASP inchange${NC}"
else
    [ "$LOCAL_PLAN" = "1" ] && echo -e "  ${CYAN}plan LOCAL${NC} (point codes 1.<op>.<role>) avec hub sur cette machine"
    echo -e "  ASP inter-STP → ${CYAN}${HUB_IP}${NC}$([ "$SET_LOCAL_IP" = "1" ] && echo "  depuis ${CYAN}${ASP_LOCAL_IP}${NC} (${LOCAL_IP_SRC})" || echo "  (source inchangee)")"
fi
echo ""

# ── Rewrite ─────────────────────────────────────────────────────────────────
# `own` = the daemon's point code (at cs7 instance level).
# `peer` = the one it declares in its sccp-address blocks.
# The distinction is made on the current block, not on the line number: a
# file that gains a directive does not shift the rewrite.
rewrite() {  # $1=file  $2=own  $3=peer  $4=rctx  $5=1 if inter-STP asp block
    local f="$1" own="$2" peer="$3" rctx="$4" do_asp="$5"
    local tmp; tmp="$(mktemp)"
    awk -v own="$own" -v peer="$peer" -v rctx="$rctx" -v do_asp="$do_asp" -v hub="$HUB_IP" \
        -v set_hub="$SET_HUB_IP" \
        -v set_local="$SET_LOCAL_IP" -v localip="${ASP_LOCAL_IP:-0.0.0.0}" '
        /^cs7 instance/            { in_cs7=1 }
        /^ *sccp-address /         { sccp=1 }
        /^ *(as|asp|listen|route-table|network-indicator|xua) / { sccp=0 }
        /^!/                       { sccp=0 }
        /^ *asp asp-to-inter/      { in_asp=1; print; next }
        in_asp && /^ *(as|listen|route-table|!)/ { in_asp=0 }

        in_asp && do_asp && set_hub && /^ *remote-ip /   { sub(/remote-ip .*/, "remote-ip " hub); print; next }
        # local-ip of the ASP: the SOURCE address of the SCTP towards the hub.
        # It is 127.0.0.1 in the image (everything local); left as is, the
        # connection would leave the loopback towards a segment address -
        # it would never complete, and the only symptom would be an ASP DOWN.
        # 0.0.0.0: the kernel picks the source according to the route.
        in_asp && do_asp && set_local && /^ *local-ip / { sub(/local-ip.*/, "local-ip " localip); print; next }
        in_asp && do_asp && /^ *shutdown[ \t]*$/ { sub(/shutdown/, "no shutdown"); print; next }

        /^ *point-code / {
            if (sccp && peer != "") { sub(/point-code .*/, "point-code " peer) }
            else if (in_cs7)        { sub(/point-code .*/, "point-code " own) }
            print; next
        }
        /^ *routing-key / { sub(/routing-key .*/, "routing-key " rctx " " own); print; next }
        { print }
    ' "$f" > "$tmp"

    if [ "$DRY" = "1" ]; then
        # diff returns 1 when the files differ: the normal case here, and
        # pipefail would abort the script at the first rewrite.
        echo "  [dry-run] $f"; { diff -u "$f" "$tmp" || true; } | sed -n '4,30p' | sed 's/^/    /'; rm -f "$tmp"
    else
        # cat rather than mv: on the ISO as in a container, these files may be
        # mount points, where rename() fails.
        cat "$tmp" > "$f"; rm -f "$tmp"
        echo -e "  ${GREEN}✓${NC} $(basename "$f")"
    fi
}

# ── THE POINT CODE PLAN AND THE HUB ARE TWO DIFFERENT THINGS ────────────────
# The multi-operator bench carries its inter-STP in a CONTAINER, on the same
# machine, reachable at 127.0.0.1:2908 (SCTP port published by
# start-docker.sh). Its point code plan is local - 1.<op>.<role> - AND there
# is a hub. The asp-to-inter block is therefore handled as soon as a hub is
# CONFIGURED, whatever the plan; otherwise `--local --hub-ip 127.0.0.1` would
# leave the template's local-ip, 172.20.0.11 - the FIRST CONTAINER's address,
# which does not exist on the host - and the ASP would stay ASP_DOWN with
# nothing but a timeout in the log.

_DO_ASP=0
[ -n "$HUB_IP" ] && _DO_ASP=1
[ "$LOCAL_PLAN" = "1" ] || _DO_ASP=1
rewrite "$STP" "$PC_STP" ""        "$RCTX_INTER" "$_DO_ASP"
rewrite "$MSC" "$PC_MSC" "$PC_BSC" "$RCTX_MSC"   0
rewrite "$BSC" "$PC_BSC" "$PC_MSC" "$RCTX_BSC"   0

if [ "$DRY" != "1" ]; then
    echo ""
    show_state
    echo ""
    echo -e "  ${YELLOW}Les demons deja lances gardent l'ancienne identite :${NC} relancez la pile."
fi
