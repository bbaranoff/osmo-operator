#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# set_stp_ip.sh - gives THIS VM its SS7 address on the bridged network
#
# One ISO, two roles. The script first asks WHICH role, then the addresses,
# because they differ on each side:
#
#   inter-STP (hub)      its bridge IP, plus the IP of every osmo-operator-N
#   osmo-operator-N      its bridge IP, plus the IP of the inter-STP
#
#   osmo-operator-1  192.168.1.11 ─┐
#   osmo-operator-2  192.168.1.12 ─┼─ M3UA/SCTP 2908 ─► inter-STP 192.168.1.10
#   osmo-operator-3  192.168.1.13 ─┘                     PC 0.0.0
#
# Bridged, not host-only: the image's configs target 192.168.56.1 (VirtualBox
# host-only) or 172.20.0.10 (docker network); neither exists when the VMs are
# bridged on the LAN (192.168.1.X), so the ASPs must be re-addressed.
#
# What the script writes
#   hub       /etc/osmocom/osmo-stp-interop.cfg   local-ip = its bridge IP
#             /etc/osmo-wan.conf                  the operator table
#             /etc/osmo-role                      OSMO_ROLE=interstp
#   operator  /etc/osmocom/osmo-stp.cfg           local-ip = its own
#                                                 remote-ip = the hub's
#             /etc/osmocom/osmo-{msc,bsc}.cfg     WAN-plan point codes
#             /etc/osmo-wan.conf, /etc/osmo-role
#
# Idempotent: re-running with other addresses replaces them, nothing to clean up.
# Environment: CONF_DIR (default /etc/osmocom), ROLE_FILE (default /etc/osmo-role)
#
# Usage:
#   sudo ./set_stp_ip.sh                        menu: role, then addresses
#   sudo ./set_stp_ip.sh --inter --ip 192.168.1.10 --ips "192.168.1.11 192.168.1.12"
#   sudo ./set_stp_ip.sh --operator --node 1 --ip 192.168.1.11 --hub-ip 192.168.1.10
#   sudo ./set_stp_ip.sh --show                 current state, changes nothing
#
#   --inter | --operator   role (otherwise: asked)
#   --ip ADDRESS           bridge IP of THIS machine
#   --ips "a b c"          hub: operator IPs, in order
#   --hub-ip ADDRESS       operator: IP of the inter-STP
#   --node N               operator: its node number (1-9)
#   --op K                 HOW MANY operators (PLMN) this node carries (default 1)
#   --op-index K           WHICH of those operators is this node's, in the point
#                          code 1.<node><op>.<role> (1-9, not above --op; default 1)
#   --iface NAME           interface to put the address on (default: detected)
#   --port N               M3UA port (default 2908)
#   --conf-dir DIR         configuration directory (default /etc/osmocom)
#   --no-ip                leave the network configuration alone
#   --defaut               the bench configuration without any question: role
#                          deduced, bridge IP deduced, hub 172.20.0.10, node read
#                          from /etc/osmo-role or the WAN table.
#   --restart              restart the stack after rewriting
#   --dry-run              show what would be written
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
ROLE_FILE="${ROLE_FILE:-/etc/osmo-role}"
INTEROP_CFG="${CONF_DIR}/osmo-stp-interop.cfg"

# wan_detect_local_ip, _wan_ask, the WAN table and its validation live in
# network/wan-nodes.sh, shared with the launchers (same interface, same table).
# shellcheck source=network/wan-nodes.sh
. "$HERE/network/wan-nodes.sh"

ROLE=""
SELF_IP=""
HUB_IP=""
IPS=""
NODE=""
OPS=1
# --op COUNTS the operators carried by this node (it sizes the firewall, the
# hub's "as" blocks and the WAN table); --op-index says WHICH one is this node's.
OP_INDEX=1
IFACE=""
PORT=2908
SET_IP=1
RESTART=0
# ── The bench configuration without any question (--defaut) ─────────────────
# Every answer is deduced from what the machine already knows about itself:
#   role      interstp if its address IS the hub's, operator otherwise;
#   its IP    the bridge one, detected;
#   the hub   172.20.0.10 (osmo-inter-stp, docker backbone);
#   the node  /etc/osmo-role, then the WAN table, then 1.
# Every value stays overridable: --defaut --node 3 wins over the deduction.
USE_DEFAULTS=0
DEFAULT_HUB_IP="172.20.0.10"
DRY=0
SHOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --inter|--interstp|--hub)  ROLE="interstp" ;;
        --operator|--op-node)      ROLE="operator" ;;
        --role)     ROLE="${2:-}"; shift ;;
        --role=*)   ROLE="${1#*=}" ;;
        --ip)       SELF_IP="${2:-}"; shift ;;
        --ip=*)     SELF_IP="${1#*=}" ;;
        --hub-ip)   HUB_IP="${2:-}"; shift ;;
        --hub-ip=*) HUB_IP="${1#*=}" ;;
        --ips)      IPS="${2:-}"; shift ;;
        --ips=*)    IPS="${1#*=}" ;;
        --node)     NODE="${2:-}"; shift ;;
        --node=*)   NODE="${1#*=}" ;;
        --op)       OPS="${2:-1}"; shift ;;
        --op=*)     OPS="${1#*=}" ;;
        --ops)      OPS="${2:-1}"; shift ;;
        --ops=*)    OPS="${1#*=}" ;;
        --op-index)   OP_INDEX="${2:-1}"; shift ;;
        --op-index=*) OP_INDEX="${1#*=}" ;;
        --iface)    IFACE="${2:-}"; shift ;;
        --iface=*)  IFACE="${1#*=}" ;;
        --port)     PORT="${2:-2908}"; shift ;;
        --port=*)   PORT="${1#*=}" ;;
        --conf-dir)   CONF_DIR="${2:-}"; INTEROP_CFG="${CONF_DIR}/osmo-stp-interop.cfg"; shift ;;
        --conf-dir=*) CONF_DIR="${1#*=}"; INTEROP_CFG="${CONF_DIR}/osmo-stp-interop.cfg" ;;
        --defaut|--default) USE_DEFAULTS=1 ;;
        --no-ip)    SET_IP=0 ;;
        --restart)  RESTART=1 ;;
        --dry-run)  DRY=1 ;;
        --show)     SHOW=1 ;;
        -h|--help)  sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   set_stp_ip.sh - adressage SS7 sur le reseau en pont            ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    for o in ${ip//./ }; do [ "$o" -le 255 ] || return 1; done
    return 0
}

need_ipv4() {  # $1=value  $2=what it is
    is_ipv4 "$1" || { echo -e "${RED}$2 : '$1' n'est pas une IPv4${NC}" >&2; exit 2; }
}

# ── This VM's bridge address ─────────────────────────────────────────────────
# wan_detect_local_ip prefers the VirtualBox host-only range (192.168.56-63),
# right for the bench but not here: a bridged VM sits on the host's LAN. Look
# first for a private LAN address that is neither the VirtualBox NAT (10.0.2.x),
# a docker alias (172.20.x) nor host-only; fall back to wan_detect_local_ip
# only when none is found.
bridge_ip() {
    local addrs a
    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    for a in $addrs; do
        case "$a" in
            192.168.5[6-9].*|192.168.6[0-3].*) ;;   # host-only: not the bridge
            192.168.*) printf '%s' "$a"; return 0 ;;
        esac
    done
    for a in $addrs; do
        case "$a" in
            10.0.2.*|172.20.*|127.*|169.254.*) ;;
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf '%s' "$a"; return 0 ;;
        esac
    done
    wan_detect_local_ip 2>/dev/null || return 1
}

# The interface that already carries this /24 is the one on the target segment;
# otherwise the first global interface.
iface_for() {  # $1=ip
    local ip="$1" f
    f="$(ip -4 -o addr show scope global 2>/dev/null \
         | awk -v pfx="${ip%.*}." '$4 ~ "^"pfx {print $2; exit}')"
    [ -z "$f" ] && f="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
    printf '%s' "$f"
}

ensure_ip() {  # $1=ip - adds it when missing
    local ip="$1" dev
    [ "$SET_IP" = "1" ] || { echo -e "  ${YELLOW}-${NC} --no-ip : reseau inchange"; return 0; }
    if ip -4 addr show 2>/dev/null | grep -q "inet ${ip}/"; then
        echo -e "  ${GREEN}✓${NC} ${CYAN}${ip}${NC} deja presente sur cette machine"
        return 0
    fi
    dev="${IFACE:-$(iface_for "$ip")}"
    if [ "$DRY" = "1" ]; then
        echo -e "  [dry-run] ip addr add ${ip}/24 dev ${dev:-?}"; return 0
    fi
    if [ -n "$dev" ] && ip addr add "${ip}/24" dev "$dev" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${CYAN}${ip}/24${NC} posee sur ${dev}"
    else
        echo -e "  ${YELLOW}⚠${NC} impossible de poser ${ip} (interface ${dev:-?})"
        echo -e "     Tant qu'elle manque, aucun ASP ne peut s'attacher."
    fi
}

write_role() {  # $1=role  $2=hub-ip  $3=node (empty for the hub)
    if [ "$DRY" = "1" ]; then
        echo -e "  [dry-run] ${ROLE_FILE} : OSMO_ROLE=$1 OSMO_HUB_IP=$2 ${3:+OSMO_WAN_NODE=$3}"
        return 0
    fi
    {
        printf '# %s - genere par set_stp_ip.sh\n' "$ROLE_FILE"
        printf 'OSMO_ROLE=%s\n' "$1"
        [ -n "${3:-}" ] && printf 'OSMO_WAN_NODE=%s\n' "$3"
        printf 'OSMO_HUB_IP=%s\n' "$2"
    } > "$ROLE_FILE"
    echo -e "  ${GREEN}✓${NC} ${CYAN}${ROLE_FILE}${NC}"
}

role_of_file() { awk -F= '/^OSMO_ROLE=/{gsub(/[ \r\t]/,"",$2); print $2}' "$ROLE_FILE" 2>/dev/null | tail -1; }
hub_of_file()  { awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2); print $2}' "$ROLE_FILE" 2>/dev/null | tail -1; }
node_of_file() { awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2); print $2}' "$ROLE_FILE" 2>/dev/null | tail -1; }

# ══════════════════════════════════════════════════════════════════════════════
# --show: what this machine currently believes it is
# ══════════════════════════════════════════════════════════════════════════════
if [ "$SHOW" = "1" ]; then
    banner
    r="$(role_of_file)"; h="$(hub_of_file)"; n="$(node_of_file)"
    echo -e "  ${BOLD}Role${NC}      : ${CYAN}${r:-inconnu}${NC}${n:+   noeud ${CYAN}${n}${NC}}"
    echo -e "  ${BOLD}IP de pont${NC}: ${CYAN}$(bridge_ip || echo '-')${NC}"
    echo -e "  ${BOLD}Inter-STP${NC} : ${CYAN}${h:--}${NC}"
    echo ""
    if [ -r "$INTEROP_CFG" ]; then
        echo -e "  ${BOLD}$(basename "$INTEROP_CFG")${NC}"
        awk '/^ *listen m3ua/{f=1} f&&/^ *(local-ip|listen)/{print "    "$0} f&&/^!/{f=0}' "$INTEROP_CFG"
    fi
    for f in "$CONF_DIR/osmo-stp.cfg" "$CONF_DIR/osmo-msc.cfg" "$CONF_DIR/osmo-bsc.cfg"; do
        [ -r "$f" ] || continue
        pc="$(awk '/^cs7 instance/{c=1} c && /^ *point-code /{print $2; exit}' "$f")"
        lo="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$f")"
        re="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$f")"
        printf '  %-16s PC %-10s local-ip %-16s remote-ip %s\n' \
            "$(basename "$f")" "${pc:--}" "${lo:--}" "${re:--}"
    done
    echo ""
    [ -r "$WAN_CONF_FILE" ] && { echo -e "  ${BOLD}${WAN_CONF_FILE}${NC}"; sed 's/^/    /' "$WAN_CONF_FILE"; }
    exit 0
fi

if [ "$USE_DEFAULTS" = "1" ]; then
    [ -n "$HUB_IP" ]  || HUB_IP="$DEFAULT_HUB_IP"
    [ -n "$SELF_IP" ] || SELF_IP="$(bridge_ip || true)"
    if [ -z "$ROLE" ]; then
        if [ "$SELF_IP" = "$HUB_IP" ]; then ROLE="interstp"; else ROLE="operator"; fi
    fi
    if [ -z "$NODE" ] && [ "$ROLE" = "operator" ]; then
        NODE="$(node_of_file)"
        if [ -z "$NODE" ] && [ -r "$WAN_CONF_FILE" ]; then
            NODE="$(awk -F\" '/WAN_NODES=/{print $2}' "$WAN_CONF_FILE" 2>/dev/null \
                    | tr ' ' '\n' | awk -F: -v ip="$SELF_IP" '$2==ip{print $1; exit}')"
        fi
        [ -n "$NODE" ] || NODE=1
    fi
    if [ -z "$IPS" ] && [ "$ROLE" = "interstp" ] && [ -r "$WAN_CONF_FILE" ]; then
        IPS="$(awk -F\" '/WAN_NODES=/{print $2}' "$WAN_CONF_FILE" 2>/dev/null \
               | tr ' ' '\n' | awk -F: '{print $2}' | tr '\n' ' ')"
    fi
fi

banner
[ "$DRY" = "1" ] || [ "$(id -u)" -eq 0 ] \
    || { echo -e "${RED}Root requis (ecriture dans ${CONF_DIR} et sur l'interface).${NC}" >&2; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# 1. WHICH MACHINE IS THIS?
# ══════════════════════════════════════════════════════════════════════════════
# The role decides everything else: the hub listens and knows its operators, an
# operator attaches and only knows the hub.
if [ -z "$ROLE" ]; then
    def_role="$(role_of_file)"; [ -n "$def_role" ] || def_role="operator"
    if [ -t 0 ]; then
        echo -e "${BOLD}Role de cette machine${NC}"
        echo -e "    ${CYAN}1${NC}) inter-STP   - le hub SS7, PC 0.0.0, celui que tous appellent"
        echo -e "    ${CYAN}2${NC}) operateur   - osmo-operator-N, qui s'attache au hub"
        echo ""
        def_n=2; [ "$def_role" = "interstp" ] && def_n=1
        ans="$(_wan_ask "Role" "1 = inter-STP, 2 = operateur :" "$def_n")" || exit 1
        case "$ans" in
            1|inter|interstp|hub)   ROLE="interstp" ;;
            2|op|operator|operateur|operateur) ROLE="operator" ;;
            *) echo -e "${RED}reponse invalide : '$ans'${NC}" >&2; exit 2 ;;
        esac
    else
        ROLE="$def_role"
        echo -e "  ${YELLOW}Pas de terminal - role repris de ${ROLE_FILE} : ${ROLE}${NC}"
    fi
fi
case "$ROLE" in
    interstp|inter|hub) ROLE="interstp" ;;
    operator|op)        ROLE="operator" ;;
    *) echo -e "${RED}--role : interstp ou operator${NC}" >&2; exit 2 ;;
esac
[[ "$OPS" =~ ^[1-9]$ ]] || { echo -e "${RED}--op : un chiffre de 1 a 9${NC}" >&2; exit 2; }
[[ "$OP_INDEX" =~ ^[1-9]$ ]] || { echo -e "${RED}--op-index : un chiffre de 1 a 9${NC}" >&2; exit 2; }
# An index above the count names an operator this node does not carry: its
# point code would fall in a range nobody routes.
[ "$OP_INDEX" -le "$OPS" ] \
    || { echo -e "${RED}--op-index ${OP_INDEX} : ce noeud n'annonce que ${OPS} operateur(s) (--op)${NC}" >&2; exit 2; }

DETECTED="$(bridge_ip || true)"
echo -e "${BOLD}Role :${NC} ${CYAN}${ROLE}${NC}${DETECTED:+    IP de pont detectee : ${CYAN}${DETECTED}${NC}}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# 2A. INTER-STP - its bridge IP, and those of the osmo-operator-N
# ══════════════════════════════════════════════════════════════════════════════
if [ "$ROLE" = "interstp" ]; then

    if [ -z "$SELF_IP" ]; then
        def="${DETECTED:-192.168.1.10}"
        SELF_IP="$(_wan_ask "Inter-STP" "IP de pont de CE hub :" "$def")" || exit 1
    fi
    need_ipv4 "$SELF_IP" "IP du hub"

    # Operator IPs. The hub does not need them to ROUTE (it listens, the ASPs
    # come to it, the point code decides the rest); it needs them to open its
    # firewall only to them, to write the table the nodes read, and so that
    # --status can say WHO is missing.
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=(); i=0
    if [ -n "$IPS" ]; then
        for ip in ${IPS//,/ }; do
            i=$((i+1)); need_ipv4 "$ip" "IP de l'operateur $i"
            WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
        done
    else
        old_n=0
        [ -r "$WAN_CONF_FILE" ] && { wan_nodes_load "$WAN_CONF_FILE" >/dev/null 2>&1 && old_n="$WAN_NODE_COUNT"; }
        declare -A old_ip=()
        for k in ${WAN_NODE_LIST[@]+"${WAN_NODE_LIST[@]}"}; do old_ip[$k]="${WAN_IP[$k]}"; done
        WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
        n="$(_wan_ask "Inter-STP" "Nombre d'osmo-operator (1-9) :" "$([ "$old_n" -ge 1 ] && echo "$old_n" || echo 3)")" || exit 1
        [[ "$n" =~ ^[1-9]$ ]] || { echo -e "${RED}nombre invalide : $n${NC}" >&2; exit 2; }
        for i in $(seq 1 "$n"); do
            # Default aligned with the bench plan: osmo-operator-N at .1N on
            # the hub's /24.
            def="${old_ip[$i]:-${SELF_IP%.*}.$((10 + i))}"
            ip="$(_wan_ask "osmo-operator-$i" "IP de pont de osmo-operator-$i :" "$def")" || exit 1
            need_ipv4 "$ip" "IP de osmo-operator-$i"
            WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
        done
    fi
    NODES="${#WAN_NODE_LIST[@]}"
    [ "$NODES" -ge 1 ] || { echo -e "${RED}aucun operateur saisi${NC}" >&2; exit 2; }
    # The hub carries no operator and is not a node of the table: node id 0
    # (accepted by wan_nodes_validate) rather than a number that would make it
    # look like a node and steal a point code.
    WAN_NODE_ID=0; WAN_NODE_COUNT="$NODES"; WAN_OPS="$OPS"
    wan_nodes_validate || exit 2

    echo ""
    echo -e "  Hub ${CYAN}${SELF_IP}:${PORT}${NC}   PC ${CYAN}0.0.0${NC}"
    for i in "${WAN_NODE_LIST[@]}"; do
        printf '    osmo-operator-%s  %-15s  STP %s  MSC %s  BSC %s\n' \
            "$i" "${WAN_IP[$i]}" "1.${i}1.2" "1.${i}1.1" "1.${i}1.3"
    done
    echo ""

    ensure_ip "$SELF_IP"

    # ── The hub's config ────────────────────────────────────────────────────
    # local-ip 0.0.0.0 would advertise every address of the machine in the SCTP
    # INIT (NAT 10.0.2.15 and 172.20.x aliases included): paths that lead
    # nowhere from the nodes. A single correct address is written instead.
    if [ "$DRY" = "1" ]; then
        echo -e "  [dry-run] ${INTEROP_CFG} : listen m3ua ${PORT} / local-ip ${SELF_IP}"
    else
        mkdir -p "$CONF_DIR"
        # Regenerated on every run, as start-interstp.sh does: the file is
        # fully derived from (NODES, OPS). A stale one would keep "as" blocks
        # for vanished nodes and none for new ones (an ASP without a matching
        # "as" is silently refused).
        bash "$HERE/helpers/create_interop.sh" --wan "$NODES" "$OPS" "$INTEROP_CFG" || exit 1
        tmp="$(mktemp)"
        awk -v hub="$SELF_IP" -v port="$PORT" '
            /^ *listen m3ua/ { sub(/listen m3ua .*/, "listen m3ua " port); in_l=1; print; next }
            in_l && /^ *local-ip / { sub(/local-ip .*/, "local-ip " hub); print; next }
            in_l && /^(!|[a-z])/ { in_l=0 }
            { print }
        ' "$INTEROP_CFG" > "$tmp"
        # cat rather than mv: on the ISO or in a container these files may be
        # mount points, where rename() fails.
        cat "$tmp" > "$INTEROP_CFG"; rm -f "$tmp"
        echo -e "  ${GREEN}✓${NC} $(basename "$INTEROP_CFG") - ecoute ${CYAN}${SELF_IP}:${PORT}${NC}"
    fi

    if [ "$DRY" = "1" ]; then
        echo -e "  [dry-run] ${WAN_CONF_FILE} : $(wan_nodes_spec)"
    else
        WAN_AUTO=0 wan_nodes_save "$WAN_CONF_FILE" \
            && echo -e "  ${GREEN}✓${NC} table ecrite dans ${CYAN}${WAN_CONF_FILE}${NC}"
        for i in "${WAN_NODE_LIST[@]}"; do
            bash "$HERE/network/firewall-wan.sh" "${WAN_IP[$i]}" "$OPS" >/dev/null 2>&1 || true
        done
        echo -e "  ${GREEN}✓${NC} pare-feu ouvert pour ${NODES} operateur(s)"
    fi
    write_role interstp "$SELF_IP" ""

    echo ""
    echo -e "  ${BOLD}Cote operateurs :${NC} sur chaque VM osmo-operator-N, lancer"
    echo -e "    ${CYAN}sudo ./set_stp_ip.sh --operator --node N --ip <son IP> --hub-ip ${SELF_IP}${NC}"

    if [ "$RESTART" = "1" ] && [ "$DRY" != "1" ]; then
        echo ""
        if [ -x "$HERE/launch/start-interstp.sh" ]; then
            "$HERE/launch/start-interstp.sh" --ip "$SELF_IP" --nodes "$NODES" --ops "$OPS" --port "$PORT" --no-ip
        else
            systemctl restart osmo-interstp 2>/dev/null \
                && echo -e "  ${GREEN}✓${NC} osmo-interstp relance" \
                || echo -e "  ${YELLOW}⚠${NC} relancez le hub a la main : ${CYAN}./launch/start-interstp.sh${NC}"
        fi
    else
        echo -e "  ${YELLOW}Le hub deja lance garde l'ancienne adresse :${NC} ${CYAN}./launch/start-interstp.sh${NC}"
    fi
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2B. OSMO-OPERATOR-N - its bridge IP, and the inter-STP's
# ══════════════════════════════════════════════════════════════════════════════
if [ -z "$NODE" ]; then
    def="$(node_of_file)"; [ -n "$def" ] || def=1
    NODE="$(_wan_ask "osmo-operator" "Numero de CE noeud operateur (1-9) :" "$def")" || exit 1
fi
[[ "$NODE" =~ ^[1-9]$ ]] || { echo -e "${RED}--node : un chiffre de 1 a 9${NC}" >&2; exit 2; }

if [ -z "$SELF_IP" ]; then
    def="${DETECTED:-192.168.1.$((10 + NODE))}"
    SELF_IP="$(_wan_ask "osmo-operator-$NODE" "IP de pont de CE noeud :" "$def")" || exit 1
fi
need_ipv4 "$SELF_IP" "IP de ce noeud"

if [ -z "$HUB_IP" ]; then
    def="$(hub_of_file)"
    # A hub in 172.20.x (docker plan) or 192.168.56.x (host-only) inherited
    # from the image does not exist on the bridge: never offer it as default.
    case "$def" in ""|172.20.*|192.168.5[6-9].*|192.168.6[0-3].*) def="${SELF_IP%.*}.10" ;; esac
    HUB_IP="$(_wan_ask "Inter-STP" "IP de pont de l'inter-STP :" "$def")" || exit 1
fi
need_ipv4 "$HUB_IP" "IP de l'inter-STP"

if [ "$SELF_IP" = "$HUB_IP" ]; then
    # Co-located hub: node 1 carries the inter-STP on its own address. Valid as
    # long as the hub LISTENS (port 2908) and the ASP leaves from another port
    # (2910): the node attaches to a neighbouring process, not to itself.
    # Refuse only when nobody listens at the hub.
    if pgrep -f 'osmo-stp -c /etc/osmocom/osmo-stp-interop\.cfg' >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠${NC} inter-STP co-localise sur ${SELF_IP} (hub en service) - ASP vers le voisin, pas vers soi"
    else
        echo -e "${RED}Ce noeud et l'inter-STP portent la meme adresse (${SELF_IP}).${NC}" >&2
        echo -e "${RED}Aucun inter-STP n'ecoute ici : lancez start-interstp.sh, ou corrigez l'adresse.${NC}" >&2
        exit 2
    fi
fi
if [ "${SELF_IP%.*}" != "${HUB_IP%.*}" ]; then
    echo -e "  ${YELLOW}⚠${NC} ${SELF_IP} et ${HUB_IP} ne sont pas sur le meme /24 -"
    echo -e "     il faudra une route entre les deux pour que l'ASP monte."
fi

echo ""
echo -e "  ${BOLD}osmo-operator-${NODE}${NC}   ${CYAN}${SELF_IP}${NC}  ──M3UA──►  inter-STP ${CYAN}${HUB_IP}:${PORT}${NC}"
# The <op> of the plan is the operator index, not the count.
echo -e "  STP ${CYAN}1.${NODE}${OP_INDEX}.2${NC}   MSC ${CYAN}1.${NODE}${OP_INDEX}.1${NC}   BSC ${CYAN}1.${NODE}${OP_INDEX}.3${NC}   (plan WAN 1.<noeud><op>.<role>)"
echo ""

ensure_ip "$SELF_IP"

# ── Point codes and ASP addresses ───────────────────────────────────────────
# set-node-id.sh is the only place that keeps the THREE files (osmo-stp,
# osmo-msc, osmo-bsc) consistent: own PC, routing key and the peer PC each one
# calls; hence the delegation rather than a second sed here. Its --op is an
# operator INDEX, not a count.
SNI_ARGS=(--node "$NODE" --op "$OP_INDEX" --native
          --local-ip "$SELF_IP" --hub-ip "$HUB_IP" --conf-dir "$CONF_DIR")
[ "$DRY" = "1" ] && SNI_ARGS+=(--dry-run)
bash "$HERE/network/set-node-id.sh" "${SNI_ARGS[@]}" || exit 1

# ── The WAN table ───────────────────────────────────────────────────────────
# Start from the existing one so the other nodes are kept: this script only
# knows THIS node and the hub.
WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
[ -r "$WAN_CONF_FILE" ] && wan_nodes_load "$WAN_CONF_FILE" >/dev/null 2>&1 || true
if [ -z "${WAN_IP[$NODE]:-}" ]; then
    WAN_NODE_LIST+=("$NODE")
    WAN_IND[$NODE]="$(wan_default_ind "$NODE")"
fi
WAN_IP[$NODE]="$SELF_IP"
[ -n "${WAN_IND[$NODE]:-}" ] || WAN_IND[$NODE]="$(wan_default_ind "$NODE")"
WAN_NODE_ID="$NODE"; WAN_NODE_COUNT="${#WAN_NODE_LIST[@]}"; WAN_OPS="$OPS"

if [ "$DRY" = "1" ]; then
    echo -e "  [dry-run] ${WAN_CONF_FILE} : $(wan_nodes_spec)  (ce noeud : ${NODE})"
else
    if wan_nodes_validate; then
        wan_nodes_save "$WAN_CONF_FILE" \
            && echo -e "  ${GREEN}✓${NC} ${CYAN}${WAN_CONF_FILE}${NC} - ce noeud : ${NODE}"
    else
        echo -e "  ${YELLOW}⚠${NC} table WAN incoherente, non reecrite - ${CYAN}${WAN_CONF_FILE}${NC} inchange"
    fi
    bash "$HERE/network/firewall-wan.sh" "$HUB_IP" "$OPS" >/dev/null 2>&1 || true
fi
write_role operator "$HUB_IP" "$NODE"

echo ""
if [ "$RESTART" = "1" ] && [ "$DRY" != "1" ]; then
    if [ -x "$HERE/start-native.sh" ]; then
        echo -e "  Relance de la pile..."
        "$HERE/start-native.sh" --node "$NODE" || true
    else
        echo -e "  ${YELLOW}⚠${NC} start-native.sh absent - relancez la pile a la main."
    fi
else
    echo -e "  ${YELLOW}Les demons deja lances gardent l'ancienne adresse :${NC} relancez la pile"
    echo -e "    ${CYAN}sudo ./start-native.sh --node ${NODE}${NC}"
fi
echo -e "  ${BOLD}Verifier l'attachement, cote hub :${NC} ${CYAN}./launch/start-interstp.sh --status${NC}"
