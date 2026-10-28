#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-wan-mesh.sh - N-node WAN, routed by DIALING CODE
#
# Generalises network/setup-wan-interop.sh (which only knows 2 servers):
# here the topology is a TABLE of nodes (network/wan-nodes.sh), each with its
# dialing code, and EVERYTHING is generated in a single pass - so it can be
# rerun and works for 2 nodes as well as for 12.
#
#   Dial <target_code><number>  →  that number, on the target node.
#   The code is stripped on the WAY OUT: the receiving node gets the bare
#   number, the one its HLR and its dialplan already know.
#
# What this script configures, on THIS node:
#   • iptables: SIP/RTP/SMS ingress from each peer (docker DNAT, native REDIRECT)
#   • firewall: opening of the same ports (network/firewall-wan.sh, idempotent)
#   • Asterisk: rtp.conf, PJSIP trunks to each remote (node, operator),
#               [wan_out]/[wan_in] dialplan + per-code entries
#   • SMS     : sms-routing.conf - one remote operator per (node, operator),
#               with code stripping (cf. scripts/sms-interop-relay.py)
#
# Usage:
#   sudo network/setup-wan-mesh.sh --nodes "1:1.2.3.4:33 2:5.6.7.8:44" --id 1 [--ops 2]
#   sudo network/setup-wan-mesh.sh --config /etc/osmo-wan.conf
#   options: --native | --docker (default: auto)  --no-restart  --dry-run
#
# Run on EACH node, with the SAME table and its own --id.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/wan-nodes.sh"

MODE=""
# --op-is-node: local operator i IS node i, not an operator of node --id. This
# is the case when each container carries its own address and its own dialing
# code: without this notion a single peer set would be computed for the whole
# machine and every container would get the same view - one of them even
# routing to itself.
OP_IS_NODE=0            # docker | native
NO_RESTART=0
CONFIG_ONLY=0
DRY=0
CONF=""
CHAIN="OSMO_WAN_MESH"

SIP_WAN_BASE=5080
RTP_WAN_BASE=20000
RTP_PER_OP=500
SMS_RELAY_BASE=7890
CONTAINER_PREFIX="osmo-operator-"
# Root prefix, native mode only: lets a test tree (NATIVE_ROOT=/tmp/essai) be
# targeted instead of the machine's /etc. Empty in production.
NATIVE_ROOT="${NATIVE_ROOT:-}"

wan_sip_port()  { echo $(( SIP_WAN_BASE + ($1 - 1) * 2 )); }
wan_rtp_start() { echo $(( RTP_WAN_BASE + ($1 - 1) * RTP_PER_OP )); }
wan_rtp_end()   { echo $(( RTP_WAN_BASE + $1 * RTP_PER_OP - 1 )); }
wan_sms_port()  { echo $(( SMS_RELAY_BASE + $1 - 1 )); }
op_backbone_ip(){ echo "172.20.0.$((10 + $1))"; }
op_container()  { echo "${CONTAINER_PREFIX}$1"; }

# A peer whose address is on the backbone is reached INSIDE the bridge: the
# traffic does not cross the host's nat table there (br_netfilter is not
# loaded), so the ports PUBLISHED on the host - 5080/5082 for SIP, 7891 for the
# second operator's SMS relay - answer nobody. Toward such a peer the target
# must be what the container really listens on: 5060 and the relay's base port.
peer_is_backbone() { case "$1" in 172.20.0.*) return 0 ;; *) return 1 ;; esac; }

# On which port to reach operator j of node r.
#
# The 5080/5082/... plan exists ONLY to multiplex several operators behind a
# single address: a docker host republishing its containers' ports, or a
# native node setting REDIRECTs to 5060. A node carrying ONLY ONE operator has
# nothing to multiplex - its Asterisk listens directly on 5060.
#
# "Is the address on the docker backbone" is not the right discriminant: a
# NATIVE VM off the backbone with a single operator also listens on 5060 only:
#     192.168.1.2:5060  -> SIP/2.0 401 Unauthorized
#     192.168.1.2:5080  -> no answer
# (It would answer on 5080 if the mesh had run there - it sets the REDIRECTs -
#  but that cannot be assumed from here.) The operator count of the remote
#  node is the discriminant.
peer_sip_port() {          # $1 = remote node id, $2 = operator
    if [ "$(node_nops "$1")" -eq 1 ]; then echo 5060; else wan_sip_port "$2"; fi
}
peer_sms_port() {          # $1 = remote node id, $2 = operator
    if [ "$(node_nops "$1")" -eq 1 ]; then echo "$SMS_RELAY_BASE"; else wan_sms_port "$2"; fi
}

# The address the TABLE announces for us is not always the one the packet
# carries on arrival: behind a router the table gives the public address and
# the host only ever sees its private one. A "-d" on an address absent from
# the machine then matches NOTHING and the WAN dies silently - the case of two
# servers behind their home routers. The destination is therefore only
# restricted when the address really is ours.
addr_is_local() {
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"
}

# Number of operators carried by a REMOTE node. The local count does not say:
# with one node per container it is 2 and would build a trunk to a
# non-existent operator, a _<code>2XXXX pattern and an SMS route nobody
# serves. WAN_NOPS comes from the table.
#
# When the table has no 4th field, the fallback is the general case. A fixed
# fallback of 1 would drop operator 2 from every CLASSIC setup
# ("--wan-nodes 1:a:11 2:b:22 --ops 2", where each node carries both
# operators) - trunk missing, inter-node calls dead for it. The fallback is 1
# only where it is true by construction: --op-is-node, one operator per node.
# Otherwise the original assumption holds: the peers are set up like us.
node_nops() {
    local n="${WAN_NOPS[$1]:-}"
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        if [ "${OP_IS_NODE:-0}" = "1" ]; then n=1; else n="${N_OPS:-1}"; fi
    fi
    echo "$n"
}

# ── `pipefail` + `grep -q` trap ──────────────────────────────────────────────
# `grep -q` exits on the FIRST match; the pipeline producer then gets SIGPIPE
# and dies with 141, and under `set -o pipefail` 141 is what the pipeline
# returns. Result: "found" reads as "not found", intermittently - depending on
# whether the output fit in the pipe buffer. The whole input is therefore read
# and the output discarded.
qgrep() { grep "$@" >/dev/null; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)   WAN_NODES="${2:-}"; shift ;;
        --nodes=*) WAN_NODES="${1#*=}" ;;
        --id)      WAN_NODE_ID="${2:-}"; shift ;;
        --id=*)    WAN_NODE_ID="${1#*=}" ;;
        --op-is-node) OP_IS_NODE=1 ;;
        --ops)     WAN_OPS="${2:-}"; shift ;;
        --ops=*)   WAN_OPS="${1#*=}" ;;
        --config)  CONF="${2:-}"; shift ;;
        --config=*) CONF="${1#*=}" ;;
        --native)  MODE="native" ;;
        --docker)  MODE="docker" ;;
        --no-restart) NO_RESTART=1 ;;
        --config-only) CONFIG_ONLY=1; NO_RESTART=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ── Node table ───────────────────────────────────────────────────────────────
# --config is both source and destination: it is only read if it already
# exists, and --nodes takes precedence (a new topology is being described).
if [ -n "${WAN_NODES:-}" ]; then
    wan_nodes_parse "$WAN_NODES" || exit 1
elif [ -n "$CONF" ]; then
    wan_nodes_load "$CONF" || { echo -e "${RED}config WAN illisible : $CONF${NC}" >&2; exit 1; }
elif [ -n "${WAN_NODES:-}" ]; then
    wan_nodes_parse "$WAN_NODES" || exit 1
elif wan_nodes_load "$WAN_CONF_FILE" 2>/dev/null; then
    :
else
    echo -e "${RED}Aucune table de noeuds : --nodes, --config ou $WAN_CONF_FILE${NC}" >&2
    exit 1
fi

# Explicit --id > config > auto-detection by local IP.
if [ "${WAN_NODE_ID:-0}" = "0" ] || [ -z "${WAN_NODE_ID:-}" ]; then
    wan_nodes_detect_self || {
        echo -e "${RED}Impossible de determiner le noeud local : passez --id N${NC}" >&2; exit 1; }
    echo -e "  ${CYAN}Noeud local detecte par son IP : ${WAN_NODE_ID}${NC}"
fi
wan_nodes_validate || exit 1

# ── Mode ─────────────────────────────────────────────────────────────────────
# The ISO has no docker; the lab host has one AND osmo-operator-* containers.
# The presence of the containers is trusted, not that of the binary.
if [ -z "$MODE" ]; then
    if command -v docker >/dev/null 2>&1 && \
       docker ps --format '{{.Names}}' 2>/dev/null | qgrep "^${CONTAINER_PREFIX}1$"; then
        MODE="docker"
    else
        MODE="native"
    fi
fi

if [ "$MODE" = "native" ]; then
    OP_IDS=( "${NATIVE_OP_ID:-${OPERATOR_ID:-1}}" )
else
    [ "${WAN_OPS:-1}" -ge 1 ] || WAN_OPS=1
    OP_IDS=(); for i in $(seq 1 "$WAN_OPS"); do OP_IDS+=("$i"); done
fi
N_OPS="${#OP_IDS[@]}"

LOCAL_IP="$(wan_local_ip)"
LOCAL_IND="$(wan_local_ind)"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   WAN mesh - routage par indicatif entre N noeuds osmo-operator     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Mode        : ${CYAN}${MODE}${NC}   Operateurs locaux : ${CYAN}${N_OPS}${NC} (${OP_IDS[*]})"
wan_nodes_summary
echo ""

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis (iptables + configs).${NC}" >&2; exit 1; }

REMOTES=()
for id in "${WAN_NODE_LIST[@]}"; do [ "$id" = "$WAN_NODE_ID" ] || REMOTES+=("$id"); done

# The context of ONE operator: its node, its dialing code, its address and its
# peers. Without --op-is-node it does not change from one operator to the
# next (they share the machine's node); with it, each has its own.
mesh_set_context() {
    local op="$1" node id
    if [ "${OP_IS_NODE:-0}" = "1" ]; then node="$op"; else node="$WAN_NODE_ID"; fi
    MESH_NODE="$node"
    [ -n "${WAN_IND[$node]:-}" ] && LOCAL_IND="${WAN_IND[$node]}"
    [ -n "${WAN_IP[$node]:-}"  ] && LOCAL_IP="${WAN_IP[$node]}"
    REMOTES=()
    for id in "${WAN_NODE_LIST[@]}"; do [ "$id" = "$node" ] || REMOTES+=("$id"); done
}
mesh_set_context "${OP_IDS[0]}"
[ "${#REMOTES[@]}" -ge 1 ] || { echo -e "${RED}Aucun pair distant.${NC}" >&2; exit 1; }

# Union of the peers of ALL local operators. mesh_set_context recomputes
# REMOTES on every call: what does not depend on an operator - the firewall
# opening, the displayed counters - needs the peers of every operator, not
# only the LAST one's list.
ALL_REMOTES=(); _seen=""
for _i in "${OP_IDS[@]}"; do
    mesh_set_context "$_i"
    for _r in "${REMOTES[@]}"; do
        case " $_seen " in
            *" $_r "*) ;;
            *) _seen="$_seen $_r"; ALL_REMOTES+=("$_r") ;;
        esac
    done
done
mesh_set_context "${OP_IDS[0]}"

run() { if [ "$DRY" -eq 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

# ── Access to the conf files, docker or native ───────────────────────────────
# The file is pulled onto the host, transformed LOCALLY with awk/sed, and
# pushed back. This lets the same code serve both modes - and avoids
# multi-level escaped seds inside a `docker exec bash -c` (where
# network/setup-wan-interop.sh is most fragile).
ast_pull() {  # $1=op  $2=path  → stdout
    if [ "$MODE" = "docker" ]; then docker exec "$(op_container "$1")" cat "$2" 2>/dev/null || true
    else cat "${NATIVE_ROOT}$2" 2>/dev/null || true; fi
}
ast_push() {  # $1=op  $2=path  ← stdin
    if [ "$DRY" -eq 1 ]; then cat >/dev/null; echo "  [dry-run] ecriture $2 (op $1)"; return 0; fi
    if [ "$MODE" = "docker" ]; then docker exec -i "$(op_container "$1")" bash -c "cat > '$2'"
    else mkdir -p "$(dirname "${NATIVE_ROOT}$2")"; cat > "${NATIVE_ROOT}$2"; fi
}
ast_cli() {   # $1=op  $2=asterisk CLI command
    if [ "$MODE" = "docker" ]; then docker exec "$(op_container "$1")" asterisk -rx "$2" 2>/dev/null || true
    else asterisk -rx "$2" 2>/dev/null || true; fi
}

BEGIN_MARK="; ─── OSMO WAN MESH BEGIN ───"
END_MARK="; ─── OSMO WAN MESH END ───"
SMS_BEGIN="# ─── OSMO WAN MESH BEGIN ───"
SMS_END="# ─── OSMO WAN MESH END ───"

# Removes our blocks AND the "WAN INTEROP" block (generated by
# setup-wan-interop.sh, always appended at the end of the file): both describe
# the same traffic, letting them coexist would make the routing depend on the
# order of the patterns.
strip_generated() { sed -e '/OSMO WAN MESH BEGIN/,/OSMO WAN MESH END/d' -e '/; ══.*WAN INTEROP/,$d'; }

# ══════════════════════════════════════════════════════════════════════════════
# [1/6] Target check
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[1/6] Verification des cibles Asterisk...${NC}"
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    if [ "$MODE" = "docker" ]; then
        docker ps --format '{{.Names}}' | qgrep "^$(op_container "$i")$" \
            || { echo -e "  ${RED}✗ $(op_container "$i") absent - lancez start-docker.sh d'abord${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} $(op_container "$i")"
    else
        [ -d "${NATIVE_ROOT}/etc/asterisk" ] || { echo -e "  ${RED}✗ ${NATIVE_ROOT}/etc/asterisk absent${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} /etc/asterisk (natif, operateur ${i})"
    fi
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2/6] iptables - ingress from each peer
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[2/6] iptables - ouverture entrante depuis ${#ALL_REMOTES[@]} pair(s)...${NC}"
if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo -e "  ${YELLOW}--config-only : ni iptables ni firewall. Les ports WAN resteront fermes${NC}"
    echo -e "  ${YELLOW}tant que ce script n'aura pas ete relance sans --config-only.${NC}"
else
run sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ "$DRY" -eq 0 ]; then
    iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null || true
    iptables -t nat -F "$CHAIN" 2>/dev/null || true
    iptables -t nat -X "$CHAIN" 2>/dev/null || true
    iptables -t nat -N "$CHAIN"
fi

# The local operator is the OUTER loop: mesh_set_context recomputes REMOTES,
# and nested the other way round the peer loop would read the list left by
# the last call - a single view for every operator, leaving the other
# operators' peers without any rule in the chain.
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    lip="$LOCAL_IP"
    sip=$(wan_sip_port "$i"); rs=$(wan_rtp_start "$i"); re=$(wan_rtp_end "$i")
    sms=$(wan_sms_port "$i")
    # The destination filter, computed once per local operator.
    _dfil=()
    if addr_is_local "$lip"; then _dfil=(-d "$lip")
    else echo -e "  ${YELLOW}! ${lip} (table) n'est pas une adresse de cette machine : DNAT non restreint en destination${NC}"; fi
    # ── THE OUTGOING DIRECTION: one source port PER CONTAINER ───────────────
    # Every container runs Asterisk on the same port, 5060. Toward a LAN peer
    # they are masqueraded behind the host's single address, and the
    # masquerade may give them THE SAME translated port:
    #     192.168.1.31.48057 > 192.168.1.2.5080   (from 172.20.0.11)
    #     192.168.1.31.48057 > 192.168.1.2.5080   (from 172.20.0.12)
    # Two distinct flows, one tuple: the peer's replies only come back to one
    # of the two, and the other's trunk stays "Unavail" forever - both
    # containers do send, only the return is missing.
    #
    # A stable and distinct source port is therefore pinned per operator.
    # Stable for the peer too: its identify always sees the same address/port
    # pair for a given node, instead of a port drawn at random at every
    # conntrack expiry.
    if [ "$MODE" = "docker" ] && [ "${#REMOTES[@]}" -gt 0 ]; then
        _snat_port=$(( 5060 + i ))
        _lan_net="$(printf '%s' "$lip" | cut -d. -f1-3).0/24"
        for _pr in udp tcp; do
            run iptables -t nat -D POSTROUTING -s "$(op_backbone_ip "$i")" -p "$_pr" --sport 5060 \
                -d "$_lan_net" -j SNAT --to-source "${lip}:${_snat_port}" 2>/dev/null || true
            run iptables -t nat -I POSTROUTING 1 -s "$(op_backbone_ip "$i")" -p "$_pr" --sport 5060 \
                -d "$_lan_net" -j SNAT --to-source "${lip}:${_snat_port}"
        done
        echo -e "  ${CYAN}Op${i}${NC} sort en SIP depuis ${CYAN}${lip}:${_snat_port}${NC} (port source epingle)"
        # Already established conntrack entries ignore the new rule: Asterisk
        # refreshes its qualify every 30 s, so they never expire on their own.
        # They are flushed, otherwise the rule only takes effect at the next
        # Asterisk restart.
        if [ "$DRY" -eq 0 ] && command -v conntrack >/dev/null 2>&1; then
            conntrack -D -s "$(op_backbone_ip "$i")" -p udp >/dev/null 2>&1 || true
        fi
    fi

    for r in "${REMOTES[@]}"; do
        rip="${WAN_IP[$r]}"
        if [ "$MODE" = "docker" ]; then
            bb=$(op_backbone_ip "$i")
            # -d "$lip": filtering on the source alone would also catch what THIS
            # node SENDS to the peer (same source, same destination port). The
            # packet would never leave the host, it would go back to our own
            # container answering itself - the trunk showing "Avail" while the
            # peer received nothing.
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p udp --dport "$sip" -j DNAT --to-destination "${bb}:5060"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p tcp --dport "$sip" -j DNAT --to-destination "${bb}:5060"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p udp --dport "${rs}:${re}" -j DNAT --to-destination "$bb"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p tcp --dport "$sms" -j DNAT --to-destination "${bb}:${SMS_RELAY_BASE}"
        else
            # Native: Asterisk and the relay already listen on the host. Only the
            # WAN port → service port translation is needed; RTP arrives
            # directly in the range set by rtp.conf.
            run iptables -t nat -A "$CHAIN" -s "$rip" -p udp --dport "$sip" -j REDIRECT --to-ports 5060
            run iptables -t nat -A "$CHAIN" -s "$rip" -p tcp --dport "$sip" -j REDIRECT --to-ports 5060
            [ "$sms" = "$SMS_RELAY_BASE" ] || \
                run iptables -t nat -A "$CHAIN" -s "$rip" -p tcp --dport "$sms" -j REDIRECT --to-ports "$SMS_RELAY_BASE"
        fi
        echo -e "  ${CYAN}node ${r}${NC} ${rip} → Op${i} SIP/RTP/SMS acceptes"
    done
done

if [ "$DRY" -eq 0 ]; then
    iptables -t nat -I PREROUTING -j "$CHAIN"
    if [ "$MODE" = "docker" ]; then
        # --ctstate DNAT: without that restriction the masquerade would ALSO
        # catch LAN flows merely routed to a container, which would then answer
        # the host instead of the client. Only what our own DNAT redirected is
        # masqueraded. Restricting on the host address instead would match
        # nothing: after DNAT the source is the peer's.
        # The broad rule is removed first - the -C guard tests the exact spec,
        # otherwise both would stay in place and the broad one would win.
        iptables -t nat -D POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null || true
        if ! iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null; then
            # Without the iptables conntrack module the -A fails and, under
            # set -e, the script would die HERE: chain already inserted in
            # PREROUTING and broad rule already removed, but no rtp.conf, pjsip,
            # dialplan or SMS routes. The broad rule is then put back, with a
            # notice - less precise, but a full mesh beats half a mesh.
            iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null || {
                echo -e "  ${YELLOW}! -m conntrack indisponible : masquage large 172.20.0.0/24 (moins precis)${NC}"
                iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null \
                    || iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -j MASQUERADE || true
            }
        fi
    fi
fi

# Firewall INPUT - without it the DNAT redirects traffic that INPUT drops.
for r in "${ALL_REMOTES[@]}"; do
    if [ -f "$SCRIPT_DIR/firewall-wan.sh" ]; then
        run bash "$SCRIPT_DIR/firewall-wan.sh" "${WAN_IP[$r]}" "$N_OPS" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} firewall ouvert pour ${WAN_IP[$r]}" \
            || echo -e "  ${YELLOW}⚠${NC} firewall-wan.sh a echoue pour ${WAN_IP[$r]}"
    fi
done
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [3/6] rtp.conf - WAN RTP range per operator
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[3/6] rtp.conf...${NC}"
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    rs=$(wan_rtp_start "$i"); re=$(wan_rtp_end "$i")
    printf '[general]\nrtpstart=%s\nrtpend=%s\nstrictrtp=no\nicesupport=no\n' "$rs" "$re" \
        | ast_push "$i" /etc/asterisk/rtp.conf
    echo -e "  ${CYAN}Op${i}${NC} RTP ${rs}-${re}"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [4/6] PJSIP - one trunk per (remote node, remote operator)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[4/6] PJSIP - trunks WAN...${NC}"

for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    pj="$(mktemp)"; ast_pull "$i" /etc/asterisk/pjsip.conf | strip_generated > "$pj"

    # external_media_address: the IP the SDP announces to the other end. It
    # MUST be the public IP of THIS node. The configs/pjsip.conf template
    # already sets one (the docker/host IP): it is OVERWRITTEN, not merely
    # added when missing - otherwise the WAN announces a private address and
    # the audio goes nowhere while the signalling passes (call answered,
    # silence).
    awk -v ip="$LOCAL_IP" '
        /^\[/ { if (intr && !done) { emit(); done=1 } ; intr = ($0 == "[transport-udp]") ; print ; next }
        intr && /^external_(media|signaling)_address=/ { next }
        intr && /^local_net=/ { seen_net=1 ; print ; next }
        intr && /^[[:space:]]*$/ && !done { emit(); done=1; intr=0; print; next }
        { print }
        END { if (intr && !done) emit() }
        function emit() {
            print "external_media_address=" ip
            print "external_signaling_address=" ip
            if (!seen_net) { print "local_net=172.20.0.0/16"; print "local_net=127.0.0.0/8" }
        }
    ' "$pj" > "${pj}.new" && mv "${pj}.new" "$pj"

    {
        echo "$BEGIN_MARK"
        echo "; Trunks WAN - generes par network/setup-wan-mesh.sh"
        echo "; Noeud local ${WAN_NODE_ID} (${LOCAL_IP}, indicatif ${LOCAL_IND})"
        for r in "${REMOTES[@]}"; do
            rip="${WAN_IP[$r]}"; rind="${WAN_IND[$r]}"; rnops="$(node_nops "$r")"
            # ONE identify per remote address: identify only looks at the source
            # address, never the port. One block per remote operator would set
            # several for the SAME address, and the incoming call would be
            # assigned to one of them at random - sometimes the wrong context.
            cat <<EOF

; ── node ${r} (indicatif ${rind}) · ${rip} · ${rnops} operateur(s) ──
[wan-id-n${r}]
type=identify
endpoint=wan_n${r}_op1
match=${rip}
EOF
            for j in $(seq 1 "$rnops"); do
                rsip=$(peer_sip_port "$r" "$j")
                # Peer on the backbone: the port published on the host is not
                # crossed inside the bridge, the container listens on 5060.

                cat <<EOF

; ── node ${r} · operateur ${j} · ${rip}:${rsip} ──
[wan_n${r}_op${j}]
type=endpoint
transport=transport-udp
context=wan_in
disallow=all
allow=gsm
allow=ulaw
aors=wan_n${r}_op${j}
media_encryption=no
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
ice_support=no

[wan_n${r}_op${j}]
type=aor
contact=sip:${rip}:${rsip}
qualify_frequency=30
qualify_timeout=5.0
EOF
            done
        done
        # The bridge gateway once, outside the loop: incoming WAN traffic is
        # masqueraded by the host and thus arrives with 172.20.0.1 as source.
        # Repeated in each block it would give as many identify entries as
        # (node, operator) pairs for this single address.
        if [ "$MODE" = "docker" ]; then
            # Traffic arriving masqueraded as 172.20.0.1 is what the host routed
            # from the LAN: it can ONLY come from a peer off the backbone. The
            # first such peer is taken, not REMOTES[0] - often a neighbouring
            # container, which never arrives masqueraded.
            _gwr=""
            for _g in "${REMOTES[@]}"; do
                peer_is_backbone "${WAN_IP[$_g]}" || { _gwr="$_g"; break; }
            done
            if [ -n "$_gwr" ]; then
                cat <<EOF

; ── passerelle du bridge - trafic WAN masque par l'hote (noeud ${_gwr}) ──
[wan-id-gw]
type=identify
endpoint=wan_n${_gwr}_op1
match=172.20.0.1
EOF
            fi
        fi
        echo "$END_MARK"
    } >> "$pj"

    ast_push "$i" /etc/asterisk/pjsip.conf < "$pj"
    rm -f "$pj"
    ntrunk=0
    for r in "${REMOTES[@]}"; do ntrunk=$(( ntrunk + $(node_nops "$r") )); done
    echo -e "  ${CYAN}Op${i}${NC} ${ntrunk} trunk(s) WAN"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [5/6] Dialplan - [wan_out] per code, [wan_in], gsm_in/internal entries
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[5/6] Dialplan - routage par indicatif...${NC}"

for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    ext="$(mktemp)"; ast_pull "$i" /etc/asterisk/extensions.conf | strip_generated > "$ext"

    # Softphones: every endpoint with "callerid=... <NNN>" becomes reachable
    # over the WAN, without hardcoding any number.
    softphones=$(ast_pull "$i" /etc/asterisk/pjsip.conf | awk '
        /^\[/                 { s=$0; gsub(/[][]/,"",s); ep=s }
        /callerid=.*<[0-9]+>/ { n=$0; sub(/.*</,"",n); sub(/>.*/,"",n); print n":"ep }')

    body="$(mktemp)"
    {
        echo "$BEGIN_MARK"
        echo "; Dialplan WAN - network/setup-wan-mesh.sh"
        echo "; Composer <indicatif><numero> ; l'indicatif est retire a la sortie."
        for r in "${REMOTES[@]}"; do
            printf ';   %-4s → node %s (%s)\n' "${WAN_IND[$r]}" "$r" "${WAN_IP[$r]}"
        done
        echo ""
        echo "[wan_out]"
        for r in "${REMOTES[@]}"; do
            rind="${WAN_IND[$r]}"; off="${#rind}"
            echo ""
            echo "; ── node ${r} - indicatif ${rind} (strip ${off}) ───────────────────"
            # The operators of the REMOTE node, not ours: counting ours would
            # produce a _<code>2XXXX toward an operator that node does not have
            # - the call would leave and get lost instead of being refused here.
            # The dialed number: <node code> + the SIX-digit MSISDN.
            # To reach operator 1 of node 1 from here: 11 100101.
            # The MSISDN starts with the REMOTE node number (<node>00<op>
            # <rank>): it is "${r}00${j}", not a common "600".
            # A single pattern is enough, the length being fixed.
            for j in $(seq 1 "$(node_nops "$r")"); do
                cat <<EOF
exten => _${rind}${r}00${j}XX,1,NoOp(=== WAN OUT node${r} op${j}: \${EXTEN} → ${WAN_IP[$r]} ===)
 same => n,Dial(PJSIP/\${EXTEN:${off}}@wan_n${r}_op${j},,rT)
 same => n,NoOp(WAN \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()
EOF
            done
            # The operator targeted on the peer, bounded to what it really
            # carries: using the LOCAL operator index toward a node with a
            # single operator would call wan_n<r>_op2 - an endpoint that is not
            # declared since the trunks follow node_nops: Asterisk would log
            # "endpoint not found" instead of trying.
            _spop="$i"; [ "$_spop" -le "$(node_nops "$r")" ] || _spop=1
            for sp in $softphones; do
                sp_num="${sp%%:*}"
                cat <<EOF
exten => ${rind}${sp_num},1,NoOp(=== WAN OUT node${r} softphone ${sp_num} ===)
 same => n,Dial(PJSIP/${sp_num}@wan_n${r}_op${_spop},,rT)
 same => n,Congestion()
 same => n,Hangup()
EOF
            done
        done
        cat <<EOF

; Indicatif local (${LOCAL_IND}) compose depuis ce noeud : c'est chez nous.
; On retire l'indicatif et on repart dans le routage local plutot que de
; sortir sur le WAN pour revenir - un aller-retour qui, lui, ne raccroche pas.
exten => _${LOCAL_IND}X.,1,NoOp(=== WAN: indicatif local, routage interne \${EXTEN} ===)
 same => n,Goto(gsm_in,\${EXTEN:${#LOCAL_IND}},1)

exten => _X.,1,NoOp(=== WAN OUT: indicatif inconnu \${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()

; ── [wan_in] - ce qui ARRIVE des autres noeuds ────────────────────────────
; Le noeud emetteur a deja retire l'indicatif : on recoit le numero nu.
[wan_in]
EOF
        # The code was stripped by the calling node: what arrives here is the
        # bare six-digit MSISDN. These are OUR numbers, so they start with OUR
        # node number: <WAN_NODE_ID>00<operator><rank>.
        for j in "${OP_IDS[@]}"; do
                cat <<EOF
exten => _${WAN_NODE_ID}00${j}XX,1,NoOp(=== WAN IN → GSM Op${j}: \${EXTEN} ===)
 same => n,Set(CALLERID(all)=<\${CALLERID(num)}>)
 same => n,Gosub(sub-annuaire,\${CALLERID(num)},1)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Dial(PJSIP/\${EXTEN}@gsm_msc,,rT)
 same => n,Congestion()
 same => n,Hangup()
EOF
        done
        for sp in $softphones; do
            sp_num="${sp%%:*}"; sp_ep="${sp#*:}"
            cat <<EOF
exten => ${sp_num},1,NoOp(=== WAN IN → ${sp_ep} (${sp_num}) ===)
 same => n,Gosub(sub-record,s,1(${sp_num}))
 same => n,Dial(PJSIP/${sp_ep},,rT)
 same => n,Congestion()
 same => n,Hangup()
EOF
        done
        cat <<EOF

; Un pair qui n'aurait pas retire notre indicatif : on le retire ici.
exten => _${LOCAL_IND}X.,1,NoOp(=== WAN IN: indicatif local encore present ===)
 same => n,Goto(wan_in,\${EXTEN:${#LOCAL_IND}},1)

; Autre operateur de CE noeud : on repasse par le routage inter-operateur local.
exten => _X.,1,NoOp(=== WAN IN → routage local \${EXTEN} ===)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Goto(interop_out,\${EXTEN},1)

exten => 600,1,NoOp(=== WAN ECHO TEST ===)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Playback(demo-echodone)
 same => n,Hangup()
EOF
        echo "$END_MARK"
    } > "$body"

    # Entries: one prefix per remote code, injected into [gsm_in] (calls coming
    # from GSM) and [internal] (SIP softphones).
    entry="$(mktemp)"
    {
        echo "$BEGIN_MARK"
        for r in "${REMOTES[@]}"; do
            printf 'exten => _%s.,1,NoOp(=== indicatif %s → node %s ===)\n' "${WAN_IND[$r]}" "${WAN_IND[$r]}" "$r"
            printf ' same => n,Goto(wan_out,${EXTEN},1)\n'
        done
        # Our OWN code dialed in full: it must land here, not fall into the
        # void. wan_out strips it and hands back to the local routing.
        printf 'exten => _%s.,1,NoOp(=== indicatif local %s ===)\n' "$LOCAL_IND" "$LOCAL_IND"
        printf ' same => n,Goto(wan_out,${EXTEN},1)\n'
        echo "$END_MARK"
    } > "$entry"

    awk -v bf="$entry" '
        { print }
        $0 == "[gsm_in]" || $0 == "[internal]" {
            while ((getline l < bf) > 0) print l
            close(bf)
        }
    ' "$ext" > "${ext}.new" && mv "${ext}.new" "$ext"

    cat "$body" >> "$ext"
    ast_push "$i" /etc/asterisk/extensions.conf < "$ext"
    rm -f "$ext" "$body" "$entry"
    _inds=""; for r in "${REMOTES[@]}"; do _inds="${_inds}${_inds:+ }${WAN_IND[$r]}→node${r}"; done
    echo -e "  ${CYAN}Op${i}${NC} wan_out/wan_in · ${_inds}"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [6/6] SMS - sms-routing.conf: one remote operator per (node, operator)
# ══════════════════════════════════════════════════════════════════════════════
# The relay (scripts/sms-interop-relay.py) routes by LONGEST-PREFIX on the
# dialed MSISDN. It is given the <code><op> prefixes, the ip:port target of
# the remote relay, and the number of code digits to STRIP before sending:
# the remote HLR only knows the bare number.
echo -e "${GREEN}[6/6] Routage SMS WAN...${NC}"
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    conf="$(mktemp)"
    ast_pull "$i" /etc/osmocom/sms-routing.conf \
        | sed '/OSMO WAN MESH BEGIN/,/OSMO WAN MESH END/d' \
        | sed '/# ── WAN ROUTES/,/# ── FIN WAN/d' > "$conf"
    if [ ! -s "$conf" ]; then
        echo -e "  ${YELLOW}⚠${NC} Op${i} : sms-routing.conf absent - SMS WAN non configure"
        rm -f "$conf"; continue
    fi
    {
        echo ""
        echo "$SMS_BEGIN"
        echo "# Remote WAN nodes. Key = <w><node><op>, value = ip:port of the relay."
        echo "[operators]"
        for r in "${REMOTES[@]}"; do
            rip="${WAN_IP[$r]}"
            for j in $(seq 1 "$(node_nops "$r")"); do
                # Toward a backbone peer the remote relay is reached inside the
                # bridge: its port published on the host (7891 for operator 2)
                # does not lead there, it listens on the base port.
                rsms="$(peer_sms_port "$r" "$j")"

                printf 'w%s%s = %s:%s\n' "$r" "$j" "$rip" "$rsms"
            done
        done
        echo ""
        # The routing key is the dialed PREFIX:
        # <code><remote node>00<operator>, since the MSISDN starts with the
        # node number (an SMS to 11100101 must match a route).
        # strip removes the code only, which leaves the whole MSISDN.
        echo "# <code><node>00<op> → remote node; strip = code digits to remove."
        echo "[routes]"
        for r in "${REMOTES[@]}"; do
            for j in $(seq 1 "$(node_nops "$r")"); do
                printf '%s%s00%s = w%s%s strip=%s\n' "${WAN_IND[$r]}" "$r" "$j" "$r" "$j" "${#WAN_IND[$r]}"
            done
        done
        echo "$SMS_END"
    } >> "$conf"
    ast_push "$i" /etc/osmocom/sms-routing.conf < "$conf"
    rm -f "$conf"
    nsms=0
    for r in "${REMOTES[@]}"; do nsms=$(( nsms + $(node_nops "$r") )); done
    echo -e "  ${CYAN}Op${i}${NC} ${nsms} route(s) SMS WAN"
done
echo ""

# ── Asterisk restart ─────────────────────────────────────────────────────────
# The PJSIP transport changed: a "reload" is not enough. In native mode at
# bootstrap time Asterisk is not yet running - nothing is restarted then, the
# conf will be read at its start.
if [ "$NO_RESTART" -eq 1 ]; then
    echo -e "${YELLOW}--no-restart : Asterisk gardera l'ancienne conf jusqu'a son prochain demarrage.${NC}"
elif [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] redemarrage Asterisk"
else
    for i in "${OP_IDS[@]}"; do
        mesh_set_context "$i"
        if [ "$MODE" = "docker" ]; then
            docker exec "$(op_container "$i")" bash -c "
                asterisk -rx 'core stop now' 2>/dev/null || pkill asterisk 2>/dev/null || true
                sleep 2; pkill -9 asterisk 2>/dev/null || true; sleep 1
                asterisk -f & disown" 2>/dev/null || true
            echo -e "  ${CYAN}Op${i}${NC} Asterisk redemarre"
        else
            if asterisk -rx 'core show uptime' 2>/dev/null | qgrep -i uptime; then
                asterisk -rx 'core restart now' >/dev/null 2>&1 || true
                echo -e "  ${CYAN}Op${i}${NC} Asterisk redemarre"
            else
                echo -e "  ${CYAN}Op${i}${NC} Asterisk non lance - conf prete pour son demarrage"
            fi
        fi
    done
fi

# ── Save + summary ───────────────────────────────────────────────────────────
if [ "$DRY" -eq 0 ]; then
    # Default 0: applying a table once must not make it permanent.
    # Only an ISO built with --wan freezes WAN_AUTO=1 (iso_modules/70-scripts.sh).
    WAN_AUTO="${WAN_AUTO:-0}" wan_nodes_save "${CONF:-$WAN_CONF_FILE}"
fi

echo ""
echo -e "${GREEN}${BOLD}WAN mesh applique.${NC}"
echo ""
# The node code must be dialed FOLLOWED BY the whole six-digit MSISDN:
# <node>00<operator><rank>. The example in the final summary must match a
# real pattern.
# LOCAL_IND and REMOTES keep the context of the LAST operator looped above;
# ours is set again before displaying, otherwise the line would announce a
# code that is not this node's.
mesh_set_context "${OP_IDS[0]}"
echo -e "  ${BOLD}Depuis ce noeud (${WAN_NODE_ID}, indicatif ${LOCAL_IND}) :${NC}"
for r in "${REMOTES[@]}"; do
    for j in $(seq 1 "$(node_nops "$r")"); do
        echo -e "    ${CYAN}${WAN_IND[$r]}${NC}${r}00${j}01  → MS ${r}00${j}01 (op${j}) du noeud ${r} (${WAN_IP[$r]})"
    done
done
echo ""
echo -e "  ${BOLD}Ports WAN (identiques sur chaque noeud) :${NC}"
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    echo -e "    Op${i}: SIP ${CYAN}$(wan_sip_port "$i")${NC}/udp  RTP ${CYAN}$(wan_rtp_start "$i")-$(wan_rtp_end "$i")${NC}/udp  SMS ${CYAN}$(wan_sms_port "$i")${NC}/tcp"
done
echo ""
echo -e "  Table sauvegardee : ${CYAN}${CONF:-$WAN_CONF_FILE}${NC}"
echo -e "  Diagnostic SS7/WAN : ${CYAN}checks/wan_ss7_check.sh${NC}"
echo ""
