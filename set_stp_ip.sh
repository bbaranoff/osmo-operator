#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# set_stp_ip.sh - donne a CETTE VM son adresse SS7 sur le reseau en pont
#
# Une seule ISO, deux roles. Le script demande d'abord LEQUEL, puis les
# adresses - parce que ce ne sont pas les memes des deux cotes :
#
#   inter-STP (hub)      son IP de pont, + l'IP de chaque osmo-operator-N
#   osmo-operator-N      son IP de pont, + l'IP de l'inter-STP
#
#   osmo-operator-1  192.168.1.11 ─┐
#   osmo-operator-2  192.168.1.12 ─┼─ M3UA/SCTP 2908 ─► inter-STP 192.168.1.10
#   osmo-operator-3  192.168.1.13 ─┘                     PC 0.0.0
#
# POURQUOI LE PONT ET PAS L'HOTE-SEUL
# Les configs de l'image visent 192.168.56.1 (host-only VirtualBox) ou
# 172.20.0.10 (reseau docker). Ni l'un ni l'autre n'existe quand les VM sont en
# "acces par pont" : elles sont sur le LAN, en 192.168.1.X. Un ASP qui vise
# une adresse absente du segment ne dit rien d'autre que "connection
# refused" cote noeud - le hub, lui, ne voit jamais personne arriver.
#
# CE QUE LE SCRIPT ECRIT
#   hub       /etc/osmocom/osmo-stp-interop.cfg   local-ip = son IP de pont
#             /etc/osmo-wan.conf                  la table des operateurs
#             /etc/osmo-role                      OSMO_ROLE=interstp
#   operateur /etc/osmocom/osmo-stp.cfg           local-ip = la sienne
#                                                 remote-ip = celle du hub
#             /etc/osmocom/osmo-{msc,bsc}.cfg     point codes du plan WAN
#             /etc/osmo-wan.conf, /etc/osmo-role
#
# Idempotent : relancer avec d'autres adresses les remplace, il n'y a pas
# d'etat a nettoyer entre deux passages.
#
# Usage :
#   sudo ./set_stp_ip.sh                        menu : role, puis adresses
#   sudo ./set_stp_ip.sh --inter --ip 192.168.1.10 --ips "192.168.1.11 192.168.1.12"
#   sudo ./set_stp_ip.sh --operator --node 1 --ip 192.168.1.11 --hub-ip 192.168.1.10
#   sudo ./set_stp_ip.sh --show                 etat actuel, sans rien modifier
#
#   --inter | --operator   role (sinon : demande)
#   --ip ADRESSE           IP de pont de CETTE machine
#   --ips "a b c"          hub : IP des operateurs, dans l'ordre
#   --hub-ip ADRESSE       operateur : IP de l'inter-STP
#   --node N               operateur : son numero de noeud (1-9)
#   --op K                 COMBIEN d'operateurs (PLMN) ce noeud porte (defaut 1)
#   --op-index K           LEQUEL de ces operateurs est celui de ce noeud, dans
#                          le point code 1.<noeud><op>.<role> (1 a 9, pas plus
#                          que --op ; defaut 1)
#   --iface NOM            interface ou poser l'adresse (defaut : detectee)
#   --port N               port M3UA (defaut 2908)
#   --no-ip                ne touche pas a la configuration reseau
#   --defaut               la configuration du banc, sans une question : role
#                          deduit, IP de pont deduite, hub 192.168.1.49, noeud
#                          lu dans /etc/osmo-role ou la table WAN.
#   --restart              relance la pile apres reecriture
#   --dry-run              montre ce qui serait ecrit
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
ROLE_FILE="${ROLE_FILE:-/etc/osmo-role}"
INTEROP_CFG="${CONF_DIR}/osmo-stp-interop.cfg"

# wan_detect_local_ip, _wan_ask, la table WAN et sa validation vivent ici. Les
# redefinir localement, c'est se garantir qu'un jour ce script et les lanceurs
# ne designeront plus la meme carte ni la meme table.
# shellcheck source=network/wan-nodes.sh
. "$HERE/network/wan-nodes.sh"

ROLE=""
SELF_IP=""
HUB_IP=""
IPS=""
NODE=""
OPS=1
# --op COMPTE les operateurs : il dimensionne le pare-feu, les blocs "as" du hub
# et la table WAN. Il ne dit pas LEQUEL est celui de ce noeud - et c'est pourtant
# lui qui partait en --op de set-node-id.sh, ou l'option est un INDICE. Avec
# --op 2 sur le noeud 3, l'ecran annoncait STP 1.31.2 pendant que les fichiers
# recevaient 1.32.2 et le routing context 3250 : l'ASP se presentait au hub sous
# une identite que sa table ne connait pas.
OP_INDEX=1
IFACE=""
PORT=2908
SET_IP=1
RESTART=0
# ── La configuration du banc, sans une question ─────────────────────────────
# --defaut repond a tout ce que ce script demande d'habitude, a partir de ce
# que la machine sait deja d'elle-meme :
#   role     interstp si son adresse EST celle du hub, operateur sinon ;
#   son IP   celle du pont, deduite ;
#   le hub   192.168.1.49 ;
#   le noeud /etc/osmo-role, puis la table WAN, puis 1.
# Chaque valeur reste surchargeable : --defaut --node 3 gagne sur la deduction.
USE_DEFAULTS=0
DEFAULT_HUB_IP="192.168.1.49"
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

need_ipv4() {  # $1=valeur  $2=ce que c'est
    is_ipv4 "$1" || { echo -e "${RED}$2 : '$1' n'est pas une IPv4${NC}" >&2; exit 2; }
}

# ── L'adresse de pont de cette VM ────────────────────────────────────────────
# wan_detect_local_ip privilegie le host-only VirtualBox (192.168.56-63), qui
# est le bon choix pour le banc mais pas ici : en acces par pont, la VM est sur
# le LAN de l'hote. On cherche donc d'abord une adresse de LAN privee qui ne
# soit ni le NAT VirtualBox (10.0.2.x), ni un alias du plan docker (172.20.x),
# ni le host-only - et on ne retombe sur wan_detect_local_ip qu'a defaut.
bridge_ip() {
    local addrs a
    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    for a in $addrs; do
        case "$a" in
            192.168.5[6-9].*|192.168.6[0-3].*) ;;   # host-only : pas le pont
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

# L'interface qui porte deja ce /24 : c'est celle du segment vise. A defaut, la
# premiere interface globale - poser l'adresse sur la mauvaise carte donne un
# ASP qui part par une route qui ne mene pas au pair.
iface_for() {  # $1=ip
    local ip="$1" f
    f="$(ip -4 -o addr show scope global 2>/dev/null \
         | awk -v pfx="${ip%.*}." '$4 ~ "^"pfx {print $2; exit}')"
    [ -z "$f" ] && f="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
    printf '%s' "$f"
}

ensure_ip() {  # $1=ip - la pose si elle manque
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

write_role() {  # $1=role  $2=hub-ip  $3=node (vide pour le hub)
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
# --show : ce que cette machine croit etre, aujourd'hui
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
# 1. QUI EST CETTE MACHINE ?
# ══════════════════════════════════════════════════════════════════════════════
# Le role decide de tout le reste : le hub ecoute et connait ses operateurs, un
# operateur s'attache et ne connait que le hub. Se tromper ici produit une
# machine qui ecoute sans que personne l'appelle, ou qui appelle une adresse
# qui n'ecoute pas.
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
# Un indice au-dela du compteur designe un operateur que ce noeud ne porte pas :
# le point code partirait dans une plage dont personne n'a la route.
[ "$OP_INDEX" -le "$OPS" ] \
    || { echo -e "${RED}--op-index ${OP_INDEX} : ce noeud n'annonce que ${OPS} operateur(s) (--op)${NC}" >&2; exit 2; }

DETECTED="$(bridge_ip || true)"
echo -e "${BOLD}Role :${NC} ${CYAN}${ROLE}${NC}${DETECTED:+    IP de pont detectee : ${CYAN}${DETECTED}${NC}}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# 2A. INTER-STP - son IP de pont, et celles des osmo-operator-N
# ══════════════════════════════════════════════════════════════════════════════
if [ "$ROLE" = "interstp" ]; then

    if [ -z "$SELF_IP" ]; then
        def="${DETECTED:-192.168.1.10}"
        SELF_IP="$(_wan_ask "Inter-STP" "IP de pont de CE hub :" "$def")" || exit 1
    fi
    need_ipv4 "$SELF_IP" "IP du hub"

    # Les IP des operateurs. Le hub n'en a pas besoin pour ROUTER - il ecoute et
    # les ASP viennent a lui, c'est le point code qui decide du reste. Il en a
    # besoin pour n'ouvrir son pare-feu qu'a eux, pour ecrire la table que
    # liront les noeuds, et pour que --status puisse dire QUI manque : sans la
    # liste, un noeud absent est indiscernable d'un noeud qui n'existe pas.
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
            # Defaut aligne sur le plan du banc : osmo-operator-N a .1N sur le
            # meme /24 que le hub.
            def="${old_ip[$i]:-${SELF_IP%.*}.$((10 + i))}"
            ip="$(_wan_ask "osmo-operator-$i" "IP de pont de osmo-operator-$i :" "$def")" || exit 1
            need_ipv4 "$ip" "IP de osmo-operator-$i"
            WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
        done
    fi
    NODES="${#WAN_NODE_LIST[@]}"
    [ "$NODES" -ge 1 ] || { echo -e "${RED}aucun operateur saisi${NC}" >&2; exit 2; }
    # Le hub ne porte aucun operateur : il n'est pas un noeud de la table. On note
    # 0 - que wan_nodes_validate accepte - plutot qu'un numero qui le ferait
    # ressembler a un noeud et lui volerait un point code.
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

    # ── La config du hub ────────────────────────────────────────────────────
    # local-ip 0.0.0.0 marche, mais annonce dans l'INIT SCTP toutes les adresses
    # de la machine - NAT 10.0.2.15 et alias 172.20.x compris. Les noeuds tentent
    # alors des chemins qui, vus d'eux, ne menent nulle part. Une adresse unique
    # et juste vaut mieux qu'un multi-homing dont trois branches sur quatre sont
    # mortes.
    if [ "$DRY" = "1" ]; then
        echo -e "  [dry-run] ${INTEROP_CFG} : listen m3ua ${PORT} / local-ip ${SELF_IP}"
    else
        mkdir -p "$CONF_DIR"
        # Regeneree a chaque passage, comme le fait start-interstp.sh : ce
        # fichier est entierement derive de (NODES, OPS): le garder tel quel
        # apres un changement de nombre d'operateurs laisserait des blocs "as"
        # pour des noeuds disparus et aucun pour le nouveau - un ASP qui arrive
        # sans "as" correspondant est refuse, sans que rien ne le dise.
        bash "$HERE/helpers/create_interop.sh" --wan "$NODES" "$OPS" "$INTEROP_CFG" || exit 1
        tmp="$(mktemp)"
        awk -v hub="$SELF_IP" -v port="$PORT" '
            /^ *listen m3ua/ { sub(/listen m3ua .*/, "listen m3ua " port); in_l=1; print; next }
            in_l && /^ *local-ip / { sub(/local-ip .*/, "local-ip " hub); print; next }
            in_l && /^(!|[a-z])/ { in_l=0 }
            { print }
        ' "$INTEROP_CFG" > "$tmp"
        # cat plutot que mv : sur l'ISO comme dans un conteneur ces fichiers
        # peuvent etre des points de montage, et rename() y echoue.
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
        if [ -x "$HERE/start-interstp.sh" ]; then
            "$HERE/start-interstp.sh" --ip "$SELF_IP" --nodes "$NODES" --ops "$OPS" --port "$PORT" --no-ip
        else
            systemctl restart osmo-interstp 2>/dev/null \
                && echo -e "  ${GREEN}✓${NC} osmo-interstp relance" \
                || echo -e "  ${YELLOW}⚠${NC} relancez le hub a la main : ${CYAN}./start-interstp.sh${NC}"
        fi
    else
        echo -e "  ${YELLOW}Le hub deja lance garde l'ancienne adresse :${NC} ${CYAN}./start-interstp.sh${NC}"
    fi
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2B. OSMO-OPERATOR-N - son IP de pont, et celle de l'inter-STP
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
    # Un hub en 172.20.x (plan docker) ou 192.168.56.x (host-only) herite de
    # l'image n'existe pas sur le pont : le proposer comme defaut ferait
    # reconduire l'adresse meme qu'on est venu corriger.
    case "$def" in ""|172.20.*|192.168.5[6-9].*|192.168.6[0-3].*) def="${SELF_IP%.*}.10" ;; esac
    HUB_IP="$(_wan_ask "Inter-STP" "IP de pont de l'inter-STP :" "$def")" || exit 1
fi
need_ipv4 "$HUB_IP" "IP de l'inter-STP"

if [ "$SELF_IP" = "$HUB_IP" ]; then
    echo -e "${RED}Ce noeud et l'inter-STP portent la meme adresse (${SELF_IP}).${NC}" >&2
    echo -e "${RED}L'ASP s'attacherait a lui-meme - corrigez l'une des deux.${NC}" >&2
    exit 2
fi
if [ "${SELF_IP%.*}" != "${HUB_IP%.*}" ]; then
    echo -e "  ${YELLOW}⚠${NC} ${SELF_IP} et ${HUB_IP} ne sont pas sur le meme /24 -"
    echo -e "     il faudra une route entre les deux pour que l'ASP monte."
fi

echo ""
echo -e "  ${BOLD}osmo-operator-${NODE}${NC}   ${CYAN}${SELF_IP}${NC}  ──M3UA──►  inter-STP ${CYAN}${HUB_IP}:${PORT}${NC}"
# Le <op> du plan est l'indice, pas le compteur. Ces trois point codes portaient
# un 1 en dur : ils annoncaient 1.<noeud>1.x quoi qu'on demande, pendant que
# set-node-id.sh en ecrivait un autre dans les fichiers.
echo -e "  STP ${CYAN}1.${NODE}${OP_INDEX}.2${NC}   MSC ${CYAN}1.${NODE}${OP_INDEX}.1${NC}   BSC ${CYAN}1.${NODE}${OP_INDEX}.3${NC}   (plan WAN 1.<noeud><op>.<role>)"
echo ""

ensure_ip "$SELF_IP"

# ── Point codes et adresses de l'ASP ────────────────────────────────────────
# set-node-id.sh est le seul endroit qui sait tenir d'accord les TROIS fichiers
# (osmo-stp, osmo-msc, osmo-bsc) : son PC, son routing-key, et le PC du pair que
# chacun appelle. En rater un donne un coeur qui demarre et des appels qui
# n'aboutissent pas - d'ou la delegation plutot qu'un second sed ici.
# Son --op est un INDICE d'operateur, pas un nombre : lui passer le compteur
# revenait a lui demander le point code du DERNIER operateur du noeud.
SNI_ARGS=(--node "$NODE" --op "$OP_INDEX" --native
          --local-ip "$SELF_IP" --hub-ip "$HUB_IP" --conf-dir "$CONF_DIR")
[ "$DRY" = "1" ] && SNI_ARGS+=(--dry-run)
bash "$HERE/network/set-node-id.sh" "${SNI_ARGS[@]}" || exit 1

# ── La table WAN ────────────────────────────────────────────────────────────
# On repart de celle qui existe pour ne pas perdre les autres noeuds : ce script
# ne connait que CE noeud et le hub, il n'a rien a dire sur les voisins.
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
    if [ -x "$HERE/start-direct.sh" ]; then
        echo -e "  Relance de la pile..."
        "$HERE/start-direct.sh" --node "$NODE" || true
    else
        echo -e "  ${YELLOW}⚠${NC} start-direct.sh absent - relancez la pile a la main."
    fi
else
    echo -e "  ${YELLOW}Les demons deja lances gardent l'ancienne adresse :${NC} relancez la pile"
    echo -e "    ${CYAN}sudo ./start-direct.sh --node ${NODE}${NC}"
fi
echo -e "  ${BOLD}Verifier l'attachement, cote hub :${NC} ${CYAN}./start-interstp.sh --status${NC}"
