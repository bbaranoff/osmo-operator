#!/bin/bash
# =============================================================================
# start-interstp.sh - start the INTER-STP node: the SS7 hub shared over the WAN
# =============================================================================
#
# On a single machine the inter-STP is one container among others (172.20.0.10)
# serving only that machine's operators. When operators are spread over several
# nodes it becomes a separate device with its own address to which every node
# attaches; it alone carries SS7 across the WAN. Nodes reach it over
# M3UA/SCTP (port 2908 by default, see --port).
#
#   node 1 (1.11.2) ─┐
#   node 2 (1.21.2) ─┼─ M3UA/SCTP 2908 ─► inter-STP 192.168.1.49    PC 0.0.0
#   node 3 (1.31.2) ─┘
#
# POINT CODE PLAN
# On an isolated machine operator N uses 1.N.2, computed identically on every
# machine, so nodes sharing a hub would present duplicate point codes (wrong
# routing). The WAN plan therefore encodes the node number:
#
#     PC   = 1.<node><op>.<role>     role 1=MSC 2=STP 3=BSC
#     RCTX = node*1000 + op*100 + 50
#
# -h / --help prints this header.
#
# Usage:
#   sudo ./launch/start-interstp.sh [--nodes 3] [--ops 1] [--ip 192.168.1.49]
#   sudo ./launch/start-interstp.sh --status | --stop
#
#   --nodes N     number of nodes served (1-9, default: read from /etc/osmo-wan.conf)
#   --ops K       operators per node (1-9, default 1)
#   --ip ADDRESS  hub address; added to the interface if missing
#   --iface NAME  interface to put the address on (default: auto-detected)
#   --port N      M3UA port (default 2908)
#   --menu        ask the questions even if a table already exists
#   --defaut      apply the default lab table, ignoring the one already stored
#   --ips "a b c" operator node IPs, in order (no questions);
#                 "id:ip" keeps the node number (table 1,3 -> nodes 1 and 3)
#   --no-save     do not rewrite /etc/osmo-wan.conf (used by start-native.sh)
#   --no-ip       do not touch the network configuration
#   --foreground  stay in the foreground (log on screen)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Repository root (this script lives in launch/).
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
CFG="${CONF_DIR}/osmo-stp-interop.cfg"
LOG="${LOG:-/var/log/osmocom/osmo-stp-interop.log}"
PIDFILE="/run/osmo-interstp.pid"

NODES=""
OPS=1
MENU=0
USE_DEFAULTS=0
IPS=""
SAVE_TABLE=1
# Default hub: the osmo-inter-stp container on the docker backbone
# (INTER_STP_IP in start-docker.sh).
HUB_IP="172.20.0.10"
# ── Default lab table, default for all prompts ──────────────────────────────
# Must match the table written by build-iso.sh, otherwise point codes on one
# side no longer match the AS declared on the other.
#   node 1  192.168.1.123  the VM              prefix 11
#   node 2  172.20.0.12  osmo-operator-2    prefix 22   (container)
#   node 3  172.20.0.13  osmo-operator-3    prefix 33   (container)
#   hub     172.20.0.10  osmo-inter-stp
# MSISDN = <node>00<op><ms> (100101 = node 1, op 1, MS 1).
WAN_NODES_DEFAULT="1:192.168.1.123:11 2:172.20.0.12:22 3:172.20.0.13:33"

# Default address of node i, read from this table.
_default_node_ip() {
    printf '%s' "$WAN_NODES_DEFAULT" | tr ' ' '\n' \
        | awk -F: -v n="$1" '$1==n{print $2; exit}'
}
IFACE=""
PORT=2908
SET_IP=1
FOREGROUND=0
ACTION=start

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)      NODES="${2:-}"; shift ;;
        --nodes=*)    NODES="${1#*=}" ;;
        --ops)        OPS="${2:-1}"; shift ;;
        --ops=*)      OPS="${1#*=}" ;;
        --ip)         HUB_IP="${2:-}"; shift ;;
        --ip=*)       HUB_IP="${1#*=}" ;;
        --iface)      IFACE="${2:-}"; shift ;;
        --iface=*)    IFACE="${1#*=}" ;;
        --port)       PORT="${2:-2908}"; shift ;;
        --port=*)     PORT="${1#*=}" ;;
        --menu)       MENU=1 ;;
        --defaut|--default) USE_DEFAULTS=1 ;;
        --ips)        IPS="${2:-}"; shift ;;
        --ips=*)      IPS="${1#*=}" ;;
        --no-ip)      SET_IP=0 ;;
        --no-save)    SAVE_TABLE=0 ;;
        --foreground) FOREGROUND=1 ;;
        --status)     ACTION=status ;;
        --stop)       ACTION=stop ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   Inter-STP - hub SS7 du WAN osmo-operator   ·   PC 0.0.0           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

stp_pid() {
    if [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        cat "$PIDFILE"; return 0
    fi
    pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' | head -1
}

# Hub VTY port. 4239 is the node's local STP default, so on a machine that
# already runs osmo-stp the hub cannot use it. Read the port from the config
# (bind 127.0.0.1 N), else 4239.
vty_port() {
    local p
    p="$(sed -n 's/^ *bind 127\.0\.0\.1 \([0-9]*\)$/\1/p' "$CFG" 2>/dev/null | head -1)"
    echo "${p:-4239}"
}

# ── status ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    banner
    pid="$(stp_pid)"
    if [ -z "$pid" ]; then
        echo -e "  ${RED}✗${NC} inter-STP arrete"; exit 1
    fi
    echo -e "  ${GREEN}✓${NC} inter-STP actif (pid ${pid})"
    echo -e "  Ecoute : $(ss -lna 2>/dev/null | grep -E "[:.]${PORT}\b" | head -3 | tr -s ' ' | cut -d' ' -f1,5 | tr '\n' ' ')"
    echo ""
    # The VTY is the only reliable source for WHO is attached: an ASP may have
    # opened its SCTP association without ever reaching ASP-ACTIVE. An open port
    # only proves the hub is listening.
    VTY_PORT="$(vty_port)"
    if command -v nc >/dev/null 2>&1; then
        echo -e "  ${BOLD}ASP attaches :${NC}"
        # Pause between commands: the VTY does not read a whole block at once.
        { sleep 1; printf 'enable\n'; sleep 0.5; printf 'show cs7 instance 0 asp\n'; sleep 0.5
          printf 'show cs7 instance 0 as all\n'; sleep 0.5; printf 'exit\n'; sleep 1; } \
            | nc -q2 127.0.0.1 "$VTY_PORT" 2>/dev/null | tr -d '\r' | sed 's/^/    /' | grep -vE '^\s*$' | tail -30 \
            || echo -e "    ${YELLOW}VTY ${VTY_PORT} muet${NC}"
    else
        echo -e "  ${YELLOW}nc absent : ${CYAN}telnet 127.0.0.1 ${VTY_PORT}${NC} puis "show cs7 instance 0 asp""
    fi
    exit 0
fi

# ── stop ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    pid="$(stp_pid)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null; sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo -e "${GREEN}Inter-STP arrete.${NC}"
    else
        echo -e "${YELLOW}Inter-STP deja arrete.${NC}"
    fi
    exit 0
fi

banner
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }
command -v osmo-stp >/dev/null 2>&1 || {
    echo -e "${RED}osmo-stp introuvable.${NC} Ce noeud doit porter la pile Osmocom." >&2; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# Who are the nodes? - the menu
# ══════════════════════════════════════════════════════════════════════════════
# The hub does not need the IPs to ROUTE: it listens, ASPs connect to it
# (accept-asp-connections dynamic-permitted) and the point code decides the
# rest. It needs them for:
#   • opening its firewall to these addresses only;
#   • writing /etc/osmo-wan.conf, read by the nodes and the diagnostics;
#   • telling in --status WHO should be attached (otherwise a missing node
#     cannot be told apart from a node that does not exist).
# shellcheck source=network/wan-nodes.sh
. "$HERE/network/wan-nodes.sh"

ask_ips() {
    local n i ip def
    echo -e "${BOLD}Configuration du hub SS7${NC}"
    echo -e "  Saisissez les adresses des noeuds operateurs, dans l'ordre."
    echo ""
    n=$(_wan_ask "Inter-STP" "Nombre de noeuds operateurs (1-9) :" "${NODES:-3}") || exit 1
    [[ "$n" =~ ^[1-9]$ ]] || { echo -e "${RED}Nombre invalide : $n${NC}" >&2; exit 2; }

    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
    for i in $(seq 1 "$n"); do
        # Default: the lab table (the first nodes are containers on the docker
        # backbone, not on the hub's LAN segment).
        def="$(_default_node_ip "$i")"
        [ -n "$def" ] || def="${HUB_IP%.*}.$((10 + i))"
        ip=$(_wan_ask "Noeud $i/$n" "IP du noeud operateur $i :" "$def") || exit 1
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { echo -e "${RED}'$ip' n'est pas une IPv4${NC}" >&2; exit 2; }
        WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$n"; NODES="$n"
    # The hub carries no operator and is not a node of the table: record 0
    # (accepted by wan_nodes_validate) so it does not take a node's point code.
    WAN_NODE_ID=0
    WAN_OPS="$OPS"
}

# --defaut: use the lab table regardless of what is on the machine.
# Without it, a table already stored in /etc/osmo-wan.conf is reloaded as is,
# so after an addressing plan change the hub keeps stale addresses until
# --defaut or --menu is used.
if [ "$USE_DEFAULTS" = "1" ] && [ -z "$IPS" ]; then
    IPS="$(printf '%s' "$WAN_NODES_DEFAULT" | tr ' ' '\n' | awk -F: '{print $2}' | tr '\n' ' ')"
    [ -n "$NODES" ] || NODES="$(printf '%s' "$WAN_NODES_DEFAULT" | wc -w)"
    echo -e "  ${CYAN}--defaut : table du banc${NC} ${WAN_NODES_DEFAULT}"
fi

if [ -n "$IPS" ]; then
    # Scriptable form: --ips "10.0.0.11 10.0.0.12 10.0.0.13"
    # "id:ip" keeps the node number (non-contiguous tables such as 1,3 are
    # allowed by wan_nodes_validate). A bare IP: number = position.
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=(); i=0
    for tok in $IPS; do
        i=$((i+1))
        case "$tok" in *:*) id="${tok%%:*}"; ip="${tok#*:}" ;; *) id="$i"; ip="$tok" ;; esac
        [[ "$id" =~ ^[1-9]$ ]] || { echo -e "${RED}--ips : numero de noeud '$id' invalide (1-9)${NC}" >&2; exit 2; }
        WAN_IP[$id]="$ip"; WAN_IND[$id]="$(wan_default_ind "$id")"; WAN_NODE_LIST+=("$id")
    done
    WAN_NODE_COUNT="$i"; NODES="$i"; WAN_NODE_ID=0; WAN_OPS="$OPS"
elif [ "$MENU" = "1" ] || { [ -z "$NODES" ] && [ ! -r "$WAN_CONF_FILE" ]; }; then
    if [ -t 0 ]; then
        ask_ips
    else
        echo -e "${YELLOW}Pas de terminal et pas de table : on part sur 3 noeuds sans adresses.${NC}"
        NODES=3
    fi
elif [ -z "$NODES" ] && [ -r "$WAN_CONF_FILE" ]; then
    wan_nodes_load "$WAN_CONF_FILE" 2>/dev/null || true
    NODES="${WAN_NODE_COUNT:-3}"
    OPS="${WAN_OPS:-$OPS}"
    echo -e "  Table lue dans ${CYAN}${WAN_CONF_FILE}${NC} : ${NODES} noeud(s)"
    echo -e "  ${CYAN}--menu${NC} pour la ressaisir."
fi

[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes : 1 a 9${NC}" >&2; exit 2; }
[[ "$OPS"   =~ ^[1-9]$ ]] || { echo -e "${RED}--ops : 1 a 9${NC}" >&2; exit 2; }

# Known table: persist it and open the firewall for these addresses.
if [ "${#WAN_NODE_LIST[@]}" -gt 0 ] && [ -n "${WAN_IP[${WAN_NODE_LIST[0]}]:-}" ]; then
    echo ""
    wan_nodes_summary 2>/dev/null || true
    # --no-save: called by start-native.sh, which has just written the table
    # (WAN_AUTO=1, node number, prefixes); rewriting it here with WAN_AUTO=0 /
    # node 0 would disable the WAN on the next boot.
    if [ "$SAVE_TABLE" = 1 ]; then
        WAN_AUTO=0 wan_nodes_save "$WAN_CONF_FILE" \
            && echo -e "  ${GREEN}✓${NC} table ecrite dans ${CYAN}${WAN_CONF_FILE}${NC}"
    else
        echo -e "  ${CYAN}--no-save${NC} : ${WAN_CONF_FILE} laisse tel quel"
    fi
    if [ -x "$HERE/network/firewall-wan.sh" ] || [ -r "$HERE/network/firewall-wan.sh" ]; then
        for i in "${WAN_NODE_LIST[@]}"; do
            bash "$HERE/network/firewall-wan.sh" "${WAN_IP[$i]}" "$OPS" >/dev/null 2>&1 || true
        done
        echo -e "  ${GREEN}✓${NC} pare-feu ouvert pour ${#WAN_NODE_LIST[@]} noeud(s)"
    fi
fi

# ── Hub address ───────────────────────────────────────────────────────────
# It is hard-coded in EVERY node's config: if it is missing at startup, all
# ASPs fail to attach and the only symptom is "connection refused" on the
# node side, never on the hub.
if [ "$SET_IP" = "1" ]; then
    if ip -4 addr show 2>/dev/null | grep -q "inet ${HUB_IP}/"; then
        echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}${NC} deja presente sur cette machine"
    else
        if [ -z "$IFACE" ]; then
            # The interface already carrying the same /24 is the WAN segment.
            IFACE="$(ip -4 -o addr show scope global 2>/dev/null \
                | awk -v pfx="${HUB_IP%.*}." '$4 ~ "^"pfx {print $2; exit}')"
            [ -z "$IFACE" ] && IFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
        fi
        if [ -n "$IFACE" ] && ip addr add "${HUB_IP}/24" dev "$IFACE" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}/24${NC} posee sur ${IFACE}"
        else
            echo -e "  ${YELLOW}⚠${NC} impossible de poser ${HUB_IP} (interface ${IFACE:-?})"
            echo -e "     Les noeuds ne pourront pas s'attacher tant qu'elle manque."
        fi
    fi
fi

# ── Config du hub ────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR" "$(dirname "$LOG")"
if [ ! -x "$HERE/helpers/create_interop.sh" ] && [ ! -r "$HERE/helpers/create_interop.sh" ]; then
    echo -e "${RED}helpers/create_interop.sh introuvable${NC}" >&2; exit 1
fi
# Previous hub's VTY port, read BEFORE regeneration so the new hub reuses it
# (scanning for a free port while the old hub still runs would drift by 1
# on each restart).
VTY_PREC="$(sed -n 's/^ *bind 127\.0\.0\.1 \([0-9]*\)$/\1/p' "$CFG" 2>/dev/null | head -1)"
# --listen-ip: the hub binds to ITS address, not 0.0.0.0. Otherwise SCTP
# advertises every local address in its INIT, nodes try dead paths and the
# ASP flaps up and down.
WAN_NODE_IDS="${WAN_NODE_LIST[*]:-}" bash "$HERE/helpers/create_interop.sh" --listen-ip "$HUB_IP" \
     --wan "$NODES" "$OPS" "$CFG" || exit 1
[ "$PORT" = "2908" ] || sed -i "s/^ listen m3ua 2908/ listen m3ua ${PORT}/" "$CFG"
# Hub VTY: 4239 while free (the port read by checks/diag-interstp.sh and
# vty-debug-dump.sh; nothing else uses it on a dedicated hub). Otherwise the
# previous hub's port, else the first free one in 4300-4399 (vty_port reads
# it back from the config).
if ! grep -q '^ *bind 127\.0\.0\.1 [0-9]' "$CFG"; then
    VTY_PORT="${VTY_PORT:-}"
    hub_pid="$(stp_pid)"
    _port_pris() {  # taken by something other than the hub being replaced
        local who; who="$(ss -lntpH "( sport = :$1 )" 2>/dev/null)"
        [ -n "$who" ] && ! { [ -n "$hub_pid" ] && printf '%s' "$who" | grep -q "pid=$hub_pid,"; }
    }
    # Hub co-located with an operator STP: the operator takes VTY 4239 (its
    # default) when run.sh starts it, AFTER this hub. If the hub took 4239 now,
    # run.sh (run_modules/10-stp.sh, mod_stp_status checks core_vty_listen 4239)
    # would think OsmoSTP is already up and skip the operator STP, leaving the
    # MSC without an STP. So 4239 is reserved for the operator whenever an
    # operator osmo-stp.cfg is present here.
    _op_stp_4239=0
    if [ -r "$CONF_DIR/osmo-stp.cfg" ] && [ "$CONF_DIR/osmo-stp.cfg" != "$CFG" ] \
       && ! grep -q '^ *bind 127\.0\.0\.1 [0-9]' "$CONF_DIR/osmo-stp.cfg"; then
        _op_stp_4239=1
    fi
    if [ -z "$VTY_PORT" ]; then
        if [ "$_op_stp_4239" = 0 ] && ! _port_pris 4239; then VTY_PORT=4239
        elif [ -n "$VTY_PREC" ] && [ "$VTY_PREC" != 4239 ] && ! _port_pris "$VTY_PREC"; then VTY_PORT="$VTY_PREC"
        else
            for p in $(seq 4300 4399); do _port_pris "$p" || { VTY_PORT=$p; break; }; done
        fi
    fi
    [ "${VTY_PORT:-4239}" = 4239 ] || sed -i "s/^line vty$/line vty\n bind 127.0.0.1 ${VTY_PORT}/" "$CFG"
fi
echo ""

# ── Lancement ────────────────────────────────────────────────────────────────
if pid="$(stp_pid)" && [ -n "$pid" ]; then
    echo -e "  ${YELLOW}Un inter-STP tourne deja (pid ${pid}) - arret puis relance.${NC}"
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
fi

echo -e "  ${BOLD}Noeuds desservis :${NC} ${NODES} × ${OPS} operateur(s)"
for n in ${WAN_NODE_LIST[*]:-$(seq 1 "$NODES")}; do
    for o in $(seq 1 "$OPS"); do
        printf '    noeud %s op %s → STP %s  MSC %s  BSC %s  (rctx %s)\n' \
            "$n" "$o" "1.${n}${o}.2" "1.${n}${o}.1" "1.${n}${o}.3" "$(( n*1000 + o*100 + 50 ))"
    done
done
echo ""

if [ "$FOREGROUND" = "1" ]; then
    echo -e "  ${GREEN}osmo-stp au premier plan - Ctrl-C pour arreter${NC}"
    exec osmo-stp -c "$CFG"
fi

osmo-stp -c "$CFG" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo -e "  ${GREEN}✓ inter-STP lance${NC} - M3UA ${CYAN}${HUB_IP}:${PORT}${NC}, VTY $(vty_port)"
    echo -e "  Journal : ${CYAN}${LOG}${NC}"
    echo ""
    echo -e "  ${BOLD}Cote noeuds :${NC} leur osmo-stp doit viser ${CYAN}${HUB_IP}${NC}"
    echo -e "    ISO construite avec ${CYAN}--role operator --node N${NC} : deja fait."
    echo -e "  ${BOLD}Verifier qui est attache :${NC} ${CYAN}./launch/start-interstp.sh --status${NC}"
else
    echo -e "  ${RED}✗ osmo-stp n'a pas demarre${NC} - ${CYAN}tail -30 ${LOG}${NC}"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
    exit 1
fi
