#!/bin/bash
# =============================================================================
# network/setup-docker-lan-route.sh - the docker containers seen from the LAN, ROUTED
#
# The docker operators live on the 172.20.0.0/24 backbone (osmo-operator-1 at
# .11, -2 at .12, -3 at .13; the inter-STP at .10). The VirtualBox VMs are
# bridged on 192.168.1.0/24 with the SS7 hub at .49. The two worlds ignore
# each other: nothing tells the LAN where to find 172.20.0.0/24.
#
# THIS SCRIPT MAKES THEM ONE NETWORK, BY ROUTING
# The host carries both (192.168.1.101 LAN side, 172.20.0.1 docker side): it
# only has to route. No macvlan, no renumbering, no port publishing - the
# containers keep their addresses, and the VMs reach them as they are.
#
#
# WHY NOT SIMPLY -p (port publishing)
# A NAT publication presents ALL containers under the host's IP. But the
# inter-STP identifies its ASPs by their source address ("match=" in the
# type=identify blocks): three operators behind a single IP cannot be told
# apart, and the hub attaches their associations to the wrong AS - or refuses
# them. Routing preserves the original address.
#
# THE THREE THINGS TO DO, AND WHY EACH
#   1. ip_forward       without it the host routes nothing, it only receives.
#   2. no masquerading towards the LAN
#                       docker MASQUERADEs everything leaving the bridge for
#                       the outside. The hub would then see 192.168.1.101
#                       everywhere instead of 172.20.0.11/12/13 - exactly what
#                       the paragraph above says to avoid. A RETURN is inserted
#                       before docker's rule, for the single destination
#                       192.168.1.0/24.
#   3. FORWARD allowed  docker sets a default FORWARD policy of DROP. The
#                       DOCKER-USER chain is made for this: consulted BEFORE
#                       docker's rules, and docker does not rewrite it.
#
# VM SIDE, one route to add (the script prints it, and installs it with --push):
#     ip route add 172.20.0.0/24 via <host IP>
#
# Usage:
#   sudo network/setup-docker-lan-route.sh              apply on the host
#   sudo network/setup-docker-lan-route.sh --push "192.168.1.123 192.168.1.49"
#                                                       + install the route on these VMs
#   sudo network/setup-docker-lan-route.sh --status     status, changes nothing
#   sudo network/setup-docker-lan-route.sh --undo       removes what the script installed
#
#   --docker-net CIDR   container network (default 172.20.0.0/24)
#   --lan CIDR          LAN network        (default: derived from the interface)
#   --iface NAME        LAN interface      (default: the one of the default route)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOCKER_NET="172.20.0.0/24"
LAN_NET=""
IFACE=""
PUSH=""
ACTION="apply"

while [ $# -gt 0 ]; do
    case "$1" in
        --docker-net)   DOCKER_NET="${2:-}"; shift ;;
        --docker-net=*) DOCKER_NET="${1#*=}" ;;
        --lan)          LAN_NET="${2:-}"; shift ;;
        --lan=*)        LAN_NET="${1#*=}" ;;
        --iface)        IFACE="${2:-}"; shift ;;
        --iface=*)      IFACE="${1#*=}" ;;
        --push)         PUSH="${2:-}"; shift ;;
        --push=*)       PUSH="${1#*=}" ;;
        --status)       ACTION="status" ;;
        --undo)         ACTION="undo" ;;
        -h|--help)      sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

# ── Where are we? ───────────────────────────────────────────────────────────
[ -n "$IFACE" ] || IFACE="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')"
[ -n "$IFACE" ] || { echo -e "${RED}Aucune interface par defaut - precisez --iface${NC}" >&2; exit 1; }

HOST_IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
[ -n "$HOST_IP" ] || { echo -e "${RED}Pas d'adresse sur ${IFACE}${NC}" >&2; exit 1; }

if [ -z "$LAN_NET" ]; then
    CIDR="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    # 192.168.1.101/24 -> 192.168.1.0/24
    LAN_NET="$(python3 - "$CIDR" <<'PY' 2>/dev/null || true
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
    [ -n "$LAN_NET" ] || LAN_NET="${HOST_IP%.*}.0/24"
fi

echo -e "${CYAN}${BOLD}== Routage docker <-> LAN ==${NC}"
echo -e "  hote      : ${CYAN}${HOST_IP}${NC} sur ${CYAN}${IFACE}${NC}"
echo -e "  LAN       : ${CYAN}${LAN_NET}${NC}"
echo -e "  conteneurs: ${CYAN}${DOCKER_NET}${NC}"
echo ""

# ── --status ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    printf '  %-34s %s\n' "ip_forward" "$([ "$fwd" = 1 ] && echo "1 (ok)" || echo "${fwd:-?} - le routage est inactif")"
    if iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN 2>/dev/null; then
        printf '  %-34s %s\n' "pas de masquage vers le LAN" "pose"
    else
        printf '  %-34s %s\n' "pas de masquage vers le LAN" "ABSENT - le hub verrait ${HOST_IP} partout"
    fi
    for spec in "-s ${LAN_NET} -d ${DOCKER_NET}" "-s ${DOCKER_NET} -d ${LAN_NET}"; do
        # shellcheck disable=SC2086
        if iptables -C DOCKER-USER $spec -j ACCEPT 2>/dev/null; then
            printf '  %-34s %s\n' "FORWARD ${spec}" "autorise"
        else
            printf '  %-34s %s\n' "FORWARD ${spec}" "ABSENT"
        fi
    done
    echo ""
    echo -e "  ${BOLD}Sur chaque VM :${NC} ip route add ${DOCKER_NET} via ${HOST_IP}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }

# ── --undo ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "undo" ]; then
    iptables -t nat -D POSTROUTING -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} regle de non-masquage retiree"
    iptables -D DOCKER-USER -s "$LAN_NET" -d "$DOCKER_NET" -j ACCEPT 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} FORWARD LAN -> docker retire"
    iptables -D DOCKER-USER -s "$DOCKER_NET" -d "$LAN_NET" -j ACCEPT 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} FORWARD docker -> LAN retire"
    echo -e "  ${YELLOW}ip_forward laisse tel quel : d'autres services peuvent en dependre.${NC}"
    exit 0
fi

# ── 1. Routing ──────────────────────────────────────────────────────────────
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -qw net.ipv4.ip_forward=1 && echo -e "  ${GREEN}✓${NC} ip_forward active"
else
    echo -e "  ${GREEN}✓${NC} ip_forward deja actif"
fi

# ── 2. Do NOT masquerade towards the LAN ────────────────────────────────────
# -I: at the HEAD of POSTROUTING, hence before the MASQUERADE docker put
# there. A RETURN hands back to the calling chain without masquerading: the
# packet keeps its 172.20.0.x source address, and the SS7 hub recognises the
# operator that sends it.
if iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} non-masquage deja en place"
else
    iptables -t nat -I POSTROUTING 1 -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN \
        && echo -e "  ${GREEN}✓${NC} ${DOCKER_NET} -> ${LAN_NET} : adresse source preservee"
fi

# ── 3. Allow FORWARD in both directions ─────────────────────────────────────
# DOCKER-USER is consulted before docker's rules, and docker does not rewrite
# it: the only place where a rule survives a daemon restart.
iptables -N DOCKER-USER 2>/dev/null || true
for spec in "-s ${LAN_NET} -d ${DOCKER_NET}" "-s ${DOCKER_NET} -d ${LAN_NET}"; do
    # shellcheck disable=SC2086
    if iptables -C DOCKER-USER $spec -j ACCEPT 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} FORWARD deja autorise (${spec})"
    else
        # shellcheck disable=SC2086
        iptables -I DOCKER-USER 1 $spec -j ACCEPT \
            && echo -e "  ${GREEN}✓${NC} FORWARD autorise (${spec})"
    fi
done

# ── 4. The route, VM side ───────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}Il reste UNE chose, sur chaque VM :${NC}"
echo -e "    ${CYAN}ip route add ${DOCKER_NET} via ${HOST_IP}${NC}"
echo -e "  Sans elle, la VM ne sait pas ou envoyer 172.20.0.x et le trafic part"
echo -e "  vers sa passerelle par defaut, qui le jette."

if [ -n "$PUSH" ]; then
    echo ""
    echo -e "  ${BOLD}Pose de la route sur les machines indiquees :${NC}"
    for vm in $PUSH; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 -o BatchMode=yes \
               "root@${vm}" "ip route replace ${DOCKER_NET} via ${HOST_IP}" 2>/dev/null; then
            echo -e "    ${GREEN}✓${NC} ${vm}"
        else
            echo -e "    ${YELLOW}⚠${NC} ${vm} injoignable - a poser a la main"
        fi
    done
fi

echo ""
echo -e "  ${BOLD}Verifier, depuis une VM :${NC} ${CYAN}ping 172.20.0.11${NC}  puis"
echo -e "  ${CYAN}checks/diag-interstp.sh${NC} cote hub - les ASP doivent apparaitre"
echo -e "  avec leur VRAIE adresse (172.20.0.11/.12/.13), pas celle de l'hote."
