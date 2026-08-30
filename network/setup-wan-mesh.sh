#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-wan-mesh.sh - WAN a N noeuds, route par INDICATIF
#
# Generalise network/setup-wan-interop.sh (qui ne connait que 2 serveurs) :
# ici la topologie est une TABLE de noeuds (network/wan-nodes.sh), chacun avec
# son indicatif, et TOUT est genere en un seul passage - donc relancable et
# valable pour 2 noeuds comme pour 12.
#
#   Composer <indicatif_cible><numero>  →  ce numero, sur le noeud cible.
#   L'indicatif est retire a la SORTIE : le noeud d'arrivee recoit le numero nu,
#   celui que son HLR et son dialplan connaissent deja.
#
# Ce que ce script configure, sur CE noeud :
#   • iptables : entree SIP/RTP/SMS depuis chaque pair (DNAT docker, REDIRECT natif)
#   • firewall : ouverture des memes ports (network/firewall-wan.sh, idempotent)
#   • Asterisk : rtp.conf, trunks PJSIP vers chaque (noeud, operateur) distant,
#                dialplan [wan_out]/[wan_in] + entrees par indicatif
#   • SMS      : sms-routing.conf - un operateur distant par (noeud, operateur),
#                avec strip de l'indicatif (cf. scripts/sms-interop-relay.py)
#
# Usage :
#   sudo network/setup-wan-mesh.sh --nodes "1:1.2.3.4:33 2:5.6.7.8:44" --id 1 [--ops 2]
#   sudo network/setup-wan-mesh.sh --config /etc/osmo-wan.conf
#   options : --native | --docker (defaut : auto)  --no-restart  --dry-run
#
# A lancer sur CHAQUE noeud, avec la MEME table et son propre --id.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/wan-nodes.sh"

MODE=""
# --op-is-node : l'operateur local i EST le noeud i, et non un operateur du
# noeud --id. C'est le cas quand chaque conteneur porte sa propre adresse et
# son propre indicatif : sans cette notion, un seul jeu de pairs etait calcule
# pour toute la machine, et tous les conteneurs recevaient la meme vue - l'un
# d'eux se retrouvait meme a se router vers lui-meme.
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
# Prefixe de racine, mode natif seulement : permet de viser un arbre de test
# (NATIVE_ROOT=/tmp/essai) au lieu du /etc de la machine. Vide en production.
NATIVE_ROOT="${NATIVE_ROOT:-}"

wan_sip_port()  { echo $(( SIP_WAN_BASE + ($1 - 1) * 2 )); }
wan_rtp_start() { echo $(( RTP_WAN_BASE + ($1 - 1) * RTP_PER_OP )); }
wan_rtp_end()   { echo $(( RTP_WAN_BASE + $1 * RTP_PER_OP - 1 )); }
wan_sms_port()  { echo $(( SMS_RELAY_BASE + $1 - 1 )); }
op_backbone_ip(){ echo "172.20.0.$((10 + $1))"; }
op_container()  { echo "${CONTAINER_PREFIX}$1"; }

# Un pair dont l'adresse est celle du backbone est joint DANS le bridge : le
# trafic n'y traverse pas la table nat de l'hote (br_netfilter n'est pas
# charge), donc les ports PUBLIES sur l'hote - 5080/5082 pour SIP, 7891 pour le
# relais SMS du second operateur - ne repondent a personne. Les contacts et les
# routes visaient ces ports-la : le qualify restait KO et les SMS partaient dans
# le vide. Vers un tel pair il faut viser ce que le conteneur ecoute vraiment,
# 5060 et le port de base du relais.
peer_is_backbone() { case "$1" in 172.20.0.*) return 0 ;; *) return 1 ;; esac; }

# Sur quel port joindre l'operateur j du noeud r.
#
# Le plan 5080/5082/... n'existe QUE pour multiplexer plusieurs operateurs
# derriere une seule adresse : c'est un hote docker qui republie les ports de
# ses conteneurs, ou un noeud natif qui pose des REDIRECT vers 5060. Un noeud
# qui ne porte QU'UN operateur n'a rien a multiplexer - son Asterisk ecoute
# directement sur 5060.
#
# Le discriminant etait "l'adresse est-elle sur le backbone docker". C'etait
# trop etroit : le noeud 3 du banc est une VM NATIVE, hors backbone, avec un
# seul operateur. On visait donc 192.168.1.2:5080, ou rien n'ecoute, et le
# trunk restait "Unavail" pendant que la VM repondait tranquillement sur 5060 :
#     192.168.1.2:5060  -> SIP/2.0 401 Unauthorized
#     192.168.1.2:5080  -> aucune reponse
# (Elle repondrait sur 5080 si le maillage y avait tourne - il pose les
#  REDIRECT - mais on ne peut pas en faire une hypothese depuis ici.)
peer_sip_port() {          # $1 = id du noeud distant, $2 = operateur
    if [ "$(node_nops "$1")" -eq 1 ]; then echo 5060; else wan_sip_port "$2"; fi
}
peer_sms_port() {          # $1 = id du noeud distant, $2 = operateur
    if [ "$(node_nops "$1")" -eq 1 ]; then echo "$SMS_RELAY_BASE"; else wan_sms_port "$2"; fi
}

# L'adresse que la TABLE annonce pour nous n'est pas toujours celle que porte le
# paquet a l'arrivee : derriere un routeur, la table donne l'adresse publique et
# l'hote ne voit jamais que sa privee. Un "-d" sur une adresse absente de la
# machine ne matche alors PLUS RIEN, et le WAN meurt en silence - le cas de
# l'en-tete de ce fichier, deux serveurs derriere leur box. On ne restreint donc
# la destination que si l'adresse est bien a nous.
addr_is_local() {
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"
}

# Nombre d'operateurs portes par un noeud DISTANT. Le compteur local ne le dit
# pas : avec un noeud par conteneur il vaut 2 et fabriquait un trunk vers un
# operateur inexistant, un pattern _<indicatif>2XXXX et une route SMS que
# personne ne sert. WAN_NOPS vient de la table.
#
# Aucun producteur n'ecrit encore le 4e champ : le repli est donc, aujourd'hui,
# le cas general. Un repli fixe a 1 aurait supprime l'operateur 2 de tout
# montage CLASSIQUE ("--wan-nodes 1:a:11 2:b:22 --ops 2", ou chaque noeud porte
# les deux operateurs) - trunk absent, appels inter-noeuds morts pour lui. On
# ne replie sur 1 que la ou c'est vrai par construction : --op-is-node, un
# operateur par noeud. Sinon on garde l'hypothese d'origine, les pairs sont
# montes comme nous.
node_nops() {
    local n="${WAN_NOPS[$1]:-}"
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        if [ "${OP_IS_NODE:-0}" = "1" ]; then n=1; else n="${N_OPS:-1}"; fi
    fi
    echo "$n"
}

# ── Piege `pipefail` + `grep -q` ─────────────────────────────────────────────
# `grep -q` sort des la PREMIERE correspondance ; le producteur du pipeline
# recoit alors SIGPIPE et meurt en 141, et sous `set -o pipefail` c'est 141 que
# le pipeline renvoie. Resultat : "trouve" se lit "pas trouve", de facon
# intermittente - selon que la sortie tenait ou non dans le tampon du tube.
# C'est exactement ce qui faisait dire a `check` que vboxdrv n'etait pas charge
# alors qu'il l'etait. On lit donc toute l'entree, et on jette la sortie.
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

# ── Table des noeuds ─────────────────────────────────────────────────────────
# --config sert a la fois de source et de destination : on ne le lit que s'il
# existe deja, et --nodes reste prioritaire (on decrit une nouvelle topologie).
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

# --id explicite > config > auto-detection par IP locale.
if [ "${WAN_NODE_ID:-0}" = "0" ] || [ -z "${WAN_NODE_ID:-}" ]; then
    wan_nodes_detect_self || {
        echo -e "${RED}Impossible de determiner le noeud local : passez --id N${NC}" >&2; exit 1; }
    echo -e "  ${CYAN}Noeud local detecte par son IP : ${WAN_NODE_ID}${NC}"
fi
wan_nodes_validate || exit 1

# ── Mode ─────────────────────────────────────────────────────────────────────
# L'ISO n'a pas de docker ; l'hote du lab en a un ET des containers osmo-operator-*.
# On ne se fie donc pas a la presence du binaire mais a celle des containers.
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
echo "║   WAN mesh - routage par indicatif entre N noeuds osmo_egprs     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Mode        : ${CYAN}${MODE}${NC}   Operateurs locaux : ${CYAN}${N_OPS}${NC} (${OP_IDS[*]})"
wan_nodes_summary
echo ""

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis (iptables + configs).${NC}" >&2; exit 1; }

REMOTES=()
for id in "${WAN_NODE_LIST[@]}"; do [ "$id" = "$WAN_NODE_ID" ] || REMOTES+=("$id"); done

# Le contexte d'UN operateur : son noeud, son indicatif, son adresse et ses
# pairs. Sans --op-is-node il ne change pas d'un operateur a l'autre (ils
# partagent le noeud de la machine) ; avec, chacun a le sien.
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

# Union des pairs de TOUS les operateurs locaux. mesh_set_context recalcule
# REMOTES a chaque appel : ce qui ne depend pas d'un operateur - l'ouverture du
# pare-feu, les compteurs affiches - lisait la liste du DERNIER operateur et
# oubliait les pairs des autres.
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

# ── Acces aux fichiers de conf, docker ou natif ──────────────────────────────
# On tire le fichier sur l'hote, on le transforme avec awk/sed LOCALEMENT, on le
# repousse. C'est ce qui permet au meme code de servir les deux modes - et ca
# evite les sed multi-niveaux echappes dans un `docker exec bash -c` (l'endroit
# ou network/setup-wan-interop.sh est le plus fragile).
ast_pull() {  # $1=op  $2=chemin  → stdout
    if [ "$MODE" = "docker" ]; then docker exec "$(op_container "$1")" cat "$2" 2>/dev/null || true
    else cat "${NATIVE_ROOT}$2" 2>/dev/null || true; fi
}
ast_push() {  # $1=op  $2=chemin  ← stdin
    if [ "$DRY" -eq 1 ]; then cat >/dev/null; echo "  [dry-run] ecriture $2 (op $1)"; return 0; fi
    if [ "$MODE" = "docker" ]; then docker exec -i "$(op_container "$1")" bash -c "cat > '$2'"
    else mkdir -p "$(dirname "${NATIVE_ROOT}$2")"; cat > "${NATIVE_ROOT}$2"; fi
}
ast_cli() {   # $1=op  $2=commande CLI asterisk
    if [ "$MODE" = "docker" ]; then docker exec "$(op_container "$1")" asterisk -rx "$2" 2>/dev/null || true
    else asterisk -rx "$2" 2>/dev/null || true; fi
}

BEGIN_MARK="; ─── OSMO WAN MESH BEGIN ───"
END_MARK="; ─── OSMO WAN MESH END ───"
SMS_BEGIN="# ─── OSMO WAN MESH BEGIN ───"
SMS_END="# ─── OSMO WAN MESH END ───"

# Retire nos blocs ET l'ancien bloc "WAN INTEROP" (genere par
# setup-wan-interop.sh, toujours ajoute en fin de fichier) : les deux decrivent
# le meme trafic, les laisser cohabiter ferait dependre le routage de l'ordre
# des patterns.
strip_generated() { sed -e '/OSMO WAN MESH BEGIN/,/OSMO WAN MESH END/d' -e '/; ══.*WAN INTEROP/,$d'; }

# ══════════════════════════════════════════════════════════════════════════════
# [1/6] Verification des cibles
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[1/6] Verification des cibles Asterisk...${NC}"
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    if [ "$MODE" = "docker" ]; then
        docker ps --format '{{.Names}}' | qgrep "^$(op_container "$i")$" \
            || { echo -e "  ${RED}✗ $(op_container "$i") absent - lancez start.sh d'abord${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} $(op_container "$i")"
    else
        [ -d "${NATIVE_ROOT}/etc/asterisk" ] || { echo -e "  ${RED}✗ ${NATIVE_ROOT}/etc/asterisk absent${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} /etc/asterisk (natif, operateur ${i})"
    fi
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2/6] iptables - entree depuis chaque pair
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

# L'operateur local est la boucle EXTERIEURE : mesh_set_context recalcule
# REMOTES, et prise dans l'autre sens la boucle des pairs lisait la liste laissee
# par le dernier appel - une seule vue servait tous les operateurs, si bien que
# les pairs des autres n'avaient aucune regle et que les seules sources presentes
# dans la chaine etaient celles d'un seul operateur.
for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    lip="$LOCAL_IP"
    sip=$(wan_sip_port "$i"); rs=$(wan_rtp_start "$i"); re=$(wan_rtp_end "$i")
    sms=$(wan_sms_port "$i")
    # Le filtre de destination, calcule une fois par operateur local.
    _dfil=()
    if addr_is_local "$lip"; then _dfil=(-d "$lip")
    else echo -e "  ${YELLOW}! ${lip} (table) n'est pas une adresse de cette machine : DNAT non restreint en destination${NC}"; fi
    # ── LE SENS SORTANT : un port source PAR CONTENEUR ──────────────────────
    # Tous les conteneurs font tourner Asterisk sur le meme port, 5060. Vers un
    # pair du LAN ils sont masques derriere l'unique adresse de l'hote, et le
    # masquage leur a donne LE MEME port traduit :
    #     192.168.1.31.48057 > 192.168.1.2.5080   (venant de 172.20.0.11)
    #     192.168.1.31.48057 > 192.168.1.2.5080   (venant de 172.20.0.12)
    # Deux flux distincts, un seul tuple : les reponses du pair ne reviennent
    # qu'a l'un des deux, et le trunk de l'autre reste "Unavail" pour toujours.
    # Constate sur le banc, et invisible autrement - les deux conteneurs
    # emettent bien, seul le retour manque.
    #
    # On epingle donc un port source stable et distinct par operateur. Stable
    # aussi pour le pair : son identify voit toujours le meme couple
    # adresse/port pour un noeud donne, au lieu d'un port tire au hasard a
    # chaque expiration de conntrack.
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
        # Les entrees conntrack deja etablies ignorent la regle neuve : Asterisk
        # rafraichit son qualify toutes les 30 s, elles n'expirent jamais toutes
        # seules. On les efface, sinon le correctif ne prend qu'au prochain
        # redemarrage d'Asterisk - et l'on croit qu'il ne marche pas.
        if [ "$DRY" -eq 0 ] && command -v conntrack >/dev/null 2>&1; then
            conntrack -D -s "$(op_backbone_ip "$i")" -p udp >/dev/null 2>&1 || true
        fi
    fi

    for r in "${REMOTES[@]}"; do
        rip="${WAN_IP[$r]}"
        if [ "$MODE" = "docker" ]; then
            bb=$(op_backbone_ip "$i")
            # -d "$lip" : filtrer la seule source attrapait aussi ce que CE noeud
            # EMET vers le pair (meme source, meme port de destination). Le paquet
            # ne quittait jamais l'hote, il repartait vers notre propre conteneur
            # qui se repondait a lui-meme - le trunk affichait "Avail" alors que le
            # pair n'avait rien recu.
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p udp --dport "$sip" -j DNAT --to-destination "${bb}:5060"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p tcp --dport "$sip" -j DNAT --to-destination "${bb}:5060"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p udp --dport "${rs}:${re}" -j DNAT --to-destination "$bb"
            run iptables -t nat -A "$CHAIN" -s "$rip" ${_dfil[@]+"${_dfil[@]}"} -p tcp --dport "$sms" -j DNAT --to-destination "${bb}:${SMS_RELAY_BASE}"
        else
            # Natif : Asterisk et le relais ecoutent deja sur l'hote. Seule la
            # translation de port WAN → port de service est necessaire ; le RTP
            # arrive directement dans la plage posee par rtp.conf.
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
        # --ctstate DNAT : sans restriction, ce masquage prenait AUSSI les flux du
        # LAN simplement routes vers un conteneur ; celui-ci repondait alors a
        # l'hote et non au client, qui n'a jamais vu la reponse. On ne masque donc
        # que ce que notre propre DNAT a redirige. Restreindre plutot sur l'adresse
        # de l'hote ne matcherait rien : apres DNAT la source est celle du pair.
        # L'ancienne regle large est retiree d'abord - le garde -C teste la spec
        # exacte, sans cela les deux resteraient en place et la large gagnerait.
        iptables -t nat -D POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null || true
        if ! iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null; then
            # Sans le module conntrack d'iptables, le -A echoue et, sous set -e,
            # le script mourait ICI : chaine deja inseree dans PREROUTING et
            # regle large deja retiree, mais ni rtp.conf, ni pjsip, ni dialplan,
            # ni routes SMS. On repose alors la regle large en le disant - moins
            # precise, mais un maillage complet vaut mieux qu'un demi-maillage.
            iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null || {
                echo -e "  ${YELLOW}! -m conntrack indisponible : masquage large 172.20.0.0/24 (moins precis)${NC}"
                iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null \
                    || iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -j MASQUERADE || true
            }
        fi
    fi
fi

# Firewall INPUT - sans ca le DNAT redirige un trafic que l'INPUT jette.
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
# [3/6] rtp.conf - plage RTP WAN par operateur
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
# [4/6] PJSIP - un trunk par (noeud distant, operateur distant)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[4/6] PJSIP - trunks WAN...${NC}"

for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    pj="$(mktemp)"; ast_pull "$i" /etc/asterisk/pjsip.conf | strip_generated > "$pj"

    # external_media_address : l'IP que le SDP annonce a l'autre bout. Elle DOIT
    # etre l'IP publique de CE noeud. Le gabarit configs/pjsip.conf en pose deja
    # une (l'IP docker/hote) : on l'ECRASE, on ne se contente pas de l'ajouter
    # quand elle manque - sinon le WAN annonce une adresse privee et l'audio
    # part dans le vide alors que la signalisation, elle, passe. C'est ce que
    # fait network/setup-wan-interop.sh ("if ! qgrep external_media_address"),
    # et ca se voit seulement a l'oreille : appel decroche, silence.
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
            # UN identify par adresse distante : identify ne regarde que l'adresse
            # source, jamais le port. Un bloc par operateur distant en posait
            # plusieurs pour la MEME adresse, et l'appel entrant etait attribue a
            # l'un d'eux au hasard - donc parfois au mauvais contexte d'arrivee.
            cat <<EOF

; ── node ${r} (indicatif ${rind}) · ${rip} · ${rnops} operateur(s) ──
[wan-id-n${r}]
type=identify
endpoint=wan_n${r}_op1
match=${rip}
EOF
            for j in $(seq 1 "$rnops"); do
                rsip=$(peer_sip_port "$r" "$j")
                # Pair sur le backbone : le port publie sur l'hote n'est pas
                # traverse dans le bridge, c'est 5060 que le conteneur ecoute.

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
        # La passerelle du bridge une seule fois, hors de la boucle : le trafic
        # WAN entrant est masque par l'hote et arrive donc avec 172.20.0.1 pour
        # source. Repetee dans chaque bloc, elle donnait autant d'identify que de
        # couples (noeud, operateur) pour cette unique adresse.
        if [ "$MODE" = "docker" ]; then
            # Le trafic qui arrive masque en 172.20.0.1 est celui que l'hote a
            # route depuis le LAN : il ne peut donc venir QUE d'un pair hors du
            # backbone. Prendre REMOTES[0] attribuait ce trafic au premier pair
            # de la liste - souvent un conteneur voisin, qui n'arrive jamais
            # masque : on passait d'une attribution au hasard a une attribution
            # systematiquement fausse.
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
# [5/6] Dialplan - [wan_out] par indicatif, [wan_in], entrees gsm_in/internal
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[5/6] Dialplan - routage par indicatif...${NC}"

for i in "${OP_IDS[@]}"; do
    mesh_set_context "$i"
    ext="$(mktemp)"; ast_pull "$i" /etc/asterisk/extensions.conf | strip_generated > "$ext"

    # Softphones : tout endpoint avec "callerid=... <NNN>" devient joignable
    # par le WAN, sans coder aucun numero en dur.
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
            # Les operateurs du noeud DISTANT, pas les notres : compter les notres
            # produisait un _<indicatif>2XXXX vers un operateur que ce noeud-la
            # n'a pas - l'appel sortait et se perdait au lieu d'etre refuse ici.
            # Le numero compose : <indicatif du noeud> + le MSISDN a SIX chiffres.
            # Pour joindre l'operateur 1 du noeud 1 depuis ici : 11 100101.
            # Le MSISDN commence par le numero du noeud DISTANT (<noeud>00<op>
            # <rang>) : c'est "${r}00${j}" et non un "600" commun. Fige a 600,
            # le motif n'accrochait plus aucun numero du pair - l'appel tombait
            # dans le fourre-tout, Asterisk repondait "successful" a l'envoi SMS
            # et le message n'allait nulle part.
            # Un seul motif suffit, la longueur etant fixe.
            for j in $(seq 1 "$(node_nops "$r")"); do
                cat <<EOF
exten => _${rind}${r}00${j}XX,1,NoOp(=== WAN OUT node${r} op${j}: \${EXTEN} → ${WAN_IP[$r]} ===)
 same => n,Dial(PJSIP/\${EXTEN:${off}}@wan_n${r}_op${j},,rT)
 same => n,NoOp(WAN \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()
EOF
            done
            # L'operateur vise chez le pair, borne a ce qu'il porte reellement :
            # cette ligne prenait l'indice de l'operateur LOCAL. Vers un noeud
            # qui n'a qu'un operateur, elle appelait wan_n<r>_op2 - un endpoint
            # qui n'est plus declare depuis que les trunks suivent node_nops :
            # Asterisk journalise "endpoint not found" au lieu d'essayer.
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
        # L'indicatif a ete retire par le noeud appelant : ce qui arrive ici est
        # le MSISDN nu, six chiffres. Ce sont NOS numeros, donc ils commencent
        # par NOTRE numero de noeud : <WAN_NODE_ID>00<operateur><rang>.
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

    # Entrees : un prefixe par indicatif distant, injecte dans [gsm_in] (appels
    # venus du GSM) et [internal] (softphones SIP).
    entry="$(mktemp)"
    {
        echo "$BEGIN_MARK"
        for r in "${REMOTES[@]}"; do
            printf 'exten => _%s.,1,NoOp(=== indicatif %s → node %s ===)\n' "${WAN_IND[$r]}" "${WAN_IND[$r]}" "$r"
            printf ' same => n,Goto(wan_out,${EXTEN},1)\n'
        done
        # Notre PROPRE indicatif compose en entier : il doit aboutir ici, pas
        # tomber dans le vide. wan_out le retire et rend la main au routage local.
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
# [6/6] SMS - sms-routing.conf : un operateur distant par (noeud, operateur)
# ══════════════════════════════════════════════════════════════════════════════
# Le relais (scripts/sms-interop-relay.py) route par LONGEST-PREFIX sur le
# MSISDN compose. On lui donne donc les prefixes <indicatif><op>, la cible
# ip:port du relais distant, et le nombre de chiffres d'indicatif a RETIRER
# avant l'envoi : le HLR distant ne connait que le numero nu.
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
        echo "# Noeuds WAN distants. Cle = <w><node><op>, valeur = ip:port du relais."
        echo "[operators]"
        for r in "${REMOTES[@]}"; do
            rip="${WAN_IP[$r]}"
            for j in $(seq 1 "$(node_nops "$r")"); do
                # Vers un pair du backbone, le relais distant est joint dans le
                # bridge : son port publie sur l'hote (7891 pour l'operateur 2)
                # n'y mene pas, il ecoute le port de base.
                rsms="$(peer_sms_port "$r" "$j")"

                printf 'w%s%s = %s:%s\n' "$r" "$j" "$rip" "$rsms"
            done
        done
        echo ""
        # La cle de routage est le PREFIXE compose :
        # <indicatif><noeud distant>00<operateur>. Le "600" fixe qu'elle portait
        # ne correspondait plus a aucun numero depuis que le MSISDN commence par
        # le noeud : un SMS vers 11100101 ne matchait aucune route, le relais
        # rendait un succes et le message n'allait nulle part.
        # strip retire l'indicatif seul, ce qui laisse le MSISDN entier.
        echo "# <indicatif><noeud>00<op> → noeud distant ; strip = chiffres d'indicatif a retirer."
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

# ── Redemarrage Asterisk ─────────────────────────────────────────────────────
# Le transport PJSIP a change : un "reload" ne suffit pas. En natif au moment
# du bootstrap Asterisk n'est pas encore lance - on ne redemarre alors rien, la
# conf sera lue a son demarrage.
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

# ── Sauvegarde + resume ──────────────────────────────────────────────────────
if [ "$DRY" -eq 0 ]; then
    WAN_AUTO="${WAN_AUTO:-1}" wan_nodes_save "${CONF:-$WAN_CONF_FILE}"
fi

echo ""
echo -e "${GREEN}${BOLD}WAN mesh applique.${NC}"
echo ""
# Il faut composer l'indicatif du noeud SUIVI DU MSISDN entier, six chiffres :
# <noeud>00<operateur><rang>. Un exemple faux dans le resume final vaut une
# heure perdue a essayer un numero qui ne matche aucun motif - le resume a deja
# annonce "<indicatif>10001" puis "<indicatif>600101", deux plans revolus.
# LOCAL_IND et REMOTES gardent le contexte du DERNIER operateur boucle plus
# haut ; on repose donc le notre avant d'afficher, sinon la ligne annonce un
# indicatif qui n'est pas celui de ce noeud.
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
