#!/bin/bash
# =============================================================================
# network/setup-docker-lan-route.sh - les conteneurs docker vus du LAN, ROUTES
#
# Les operateurs docker vivent sur le backbone 172.20.0.0/24 (osmo-operator-1 en
# .11, -2 en .12, -3 en .13 ; l'inter-STP en .10). Les VM VirtualBox, elles, sont
# en acces par pont sur 192.168.1.0/24 avec le hub SS7 en .49. Les deux mondes
# s'ignorent : rien ne dit au LAN ou trouver 172.20.0.0/24.
#
# CE SCRIPT EN FAIT UN SEUL RESEAU, PAR ROUTAGE
# L'hote porte les deux (192.168.1.101 cote LAN, 172.20.0.1 cote docker) : il lui
# suffit de router. Pas de macvlan, pas de renumerotation, pas de publication de
# ports - les conteneurs gardent leurs adresses, et les VM les joignent telles
# quelles.
#
# POURQUOI PAS SIMPLEMENT -p (publication de ports)
# Une publication NAT presente TOUS les conteneurs sous l'IP de l'hote. Or
# l'inter-STP identifie ses ASP par leur adresse source ("match=" dans les blocs
# type=identify) : trois operateurs derriere une seule IP sont indiscernables, et
# le hub rattache leurs associations au mauvais AS - ou les refuse. Le routage,
# lui, preserve l'adresse d'origine.
#
# LES TROIS CHOSES A FAIRE, ET POURQUOI CHACUNE
#   1. ip_forward       sans lui l'hote ne route rien, il ne fait que recevoir.
#   2. pas de masquage vers le LAN
#                       docker MASQUERADE tout ce qui sort du bridge vers
#                       l'exterieur. Le hub verrait alors 192.168.1.101 partout,
#                       au lieu de 172.20.0.11/12/13 - exactement ce que le
#                       paragraphe ci-dessus dit d'eviter. On insere donc un
#                       RETURN avant la regle de docker, pour la seule
#                       destination 192.168.1.0/24.
#   3. FORWARD autorise docker pose un FORWARD par defaut a DROP. La chaine
#                       DOCKER-USER est faite pour ca : elle est consultee AVANT
#                       les regles de docker, et il ne la reecrit pas.
#
# COTE VM, une route a ajouter (le script l'affiche, et la pose si --push) :
#     ip route add 172.20.0.0/24 via <IP de l hote>
#
# Usage :
#   sudo network/setup-docker-lan-route.sh              applique sur l'hote
#   sudo network/setup-docker-lan-route.sh --push "192.168.1.2 192.168.1.49"
#                                                       + pose la route sur ces VM
#   sudo network/setup-docker-lan-route.sh --status     etat, sans rien changer
#   sudo network/setup-docker-lan-route.sh --undo       retire ce que le script a pose
#
#   --docker-net CIDR   reseau des conteneurs (defaut 172.20.0.0/24)
#   --lan CIDR          reseau du LAN         (defaut : deduit de l'interface)
#   --iface NOM         interface LAN         (defaut : celle de la route par defaut)
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

# ── Ou sommes-nous ? ────────────────────────────────────────────────────────
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

# ── 1. Le routage ───────────────────────────────────────────────────────────
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -qw net.ipv4.ip_forward=1 && echo -e "  ${GREEN}✓${NC} ip_forward active"
else
    echo -e "  ${GREEN}✓${NC} ip_forward deja actif"
fi

# ── 2. Ne PAS masquer vers le LAN ───────────────────────────────────────────
# -I : en TETE de POSTROUTING, donc avant le MASQUERADE que docker y a mis. Un
# RETURN rend la main a la chaine appelante sans masquer : le paquet garde son
# adresse source 172.20.0.x, et le hub SS7 reconnait l'operateur qui l'emet.
if iptables -t nat -C POSTROUTING -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} non-masquage deja en place"
else
    iptables -t nat -I POSTROUTING 1 -s "$DOCKER_NET" -d "$LAN_NET" -j RETURN \
        && echo -e "  ${GREEN}✓${NC} ${DOCKER_NET} -> ${LAN_NET} : adresse source preservee"
fi

# ── 3. Autoriser le FORWARD dans les deux sens ──────────────────────────────
# DOCKER-USER est consultee avant les regles de docker, et docker ne la reecrit
# pas : c'est le seul endroit ou une regle survit a un redemarrage du daemon.
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

# ── 4. La route, cote VM ────────────────────────────────────────────────────
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
