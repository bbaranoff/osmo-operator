#!/bin/bash
# =============================================================================
# start-multi.sh - LE BANC MULTI-OPERATEUR : natif + docker, relies en SS7
#
#   op 1  NATIF   deja en place (start-direct.sh)   PC 1.1.2
#   op 2  DOCKER  conteneur                          PC 1.2.2   172.20.0.12
#   op 3  DOCKER  conteneur                          PC 1.3.2   172.20.0.13
#   hub   DOCKER  inter-STP                          PC 0.0.0   172.20.0.10
#                                                    M3UA/SCTP 2908
#
# CE SCRIPT NE REIMPLEMENTE RIEN. start.sh sait deja lancer des operateurs en
# conteneur, poser le hub (--hub-ip) et DECLARER un operateur sans lui lancer de
# conteneur (--operator IP:PREFIXE) - ce dernier point est exactement le cas du
# natif, qui tourne deja et qu on veut seulement raccorder. Refaire ce travail
# ici donnerait une seconde formule a maintenir, et le depot montre deja ou cela
# mene : start.sh et lib/gabarits.sh portent les MEMES fonctions en double.
# start-multi.sh se contente donc de trois choses : verifier, traduire la
# topologie en options, et deleguer.
#
# LA TOPOLOGIE VIENT DE addition.sh, pas d ici : /etc/osmocom/osmo-multi.conf.
# Un seul endroit la calcule.
#
# Usage :
#   sudo ./start-multi.sh              monte le banc multi-operateur
#   sudo ./start-multi.sh --status     etat des conteneurs et du hub
#   sudo ./start-multi.sh --stop       arrete les conteneurs (le natif reste)
#   sudo ./start-multi.sh --dry-run    affiche la commande sans la lancer
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
ACTION="start"
for a in "$@"; do
    case "$a" in
        --status)  ACTION="status" ;;
        --stop)    ACTION="stop" ;;
        --dry-run) ACTION="dry" ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    esac
done

# ── LANCE PAR UNE ICONE : TERMINAL ET PRIVILEGES ────────────────────────────
# [2026-08-31] Sans ce preambule, l antenne bleue du bureau ne faisait RIEN de
# visible. Le .desktop est en Terminal=false ; le script exigeait root et
# ecrivait son refus sur stdout, c est-a-dire nulle part. Un double-clic
# lancait donc bien le script, qui sortait aussitot sur "Root requis" sans une
# fenetre ni un message : l icone paraissait morte, alors qu elle marchait.
# launch.sh avait deja ce traitement ; celui-ci ne l avait pas.
#
# On teste la presence d un TTY, pas $DISPLAY : c est la difference reelle
# entre "lance a la main" et "lance par une icone".
# ⚠️ SEULEMENT pour le LANCEMENT. --status, --dry-run et --help sont des
# lectures : les rejouer dans un terminal graphique ouvrirait une fenetre a
# chaque appel depuis un script ou un pipe - et leur sortie n irait pas a
# l appelant, qui n obtiendrait RIEN. Constate en les testant d ici.
_multi_readonly=0
case " $* " in
    *" --status "*|*" --dry-run "*|*" -h "*|*" --help "*) _multi_readonly=1 ;;
esac

if [ "$_multi_readonly" = "0" ] && [ ! -t 0 ] && [ "${OSMO_MULTI_TERM:-0}" != "1" ]; then
    export OSMO_MULTI_TERM=1
    for _t in gnome-terminal xfce4-terminal konsole xterm; do
        command -v "$_t" >/dev/null 2>&1 || continue
        case "$_t" in
            gnome-terminal) exec "$_t" --title="osmo-operator multi-operateur" -- "$0" "$@" ;;
            *)              exec "$_t" -T "osmo-operator multi-operateur" -e "$0" "$@" ;;
        esac
    done
fi

# Meme raison pour root : une lecture n a pas a demander de mot de passe.
if [ "$_multi_readonly" = "0" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
                exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
                     OSMO_MULTI_TERM="${OSMO_MULTI_TERM:-0}" "$0" "$@"
            fi
            command -v sudo >/dev/null 2>&1 && exec sudo -E "$0" "$@"
        fi
fi

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - banc MULTI-OPERATEUR (SS7)         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── PREFLIGHT ───────────────────────────────────────────────────────────────
# Docker N EST PAS dans l ISO (voir addition.sh) : son absence est le cas
# NORMAL au premier lancement, pas une panne. On le dit comme tel, et on
# renvoie vers le supplement plutot que de laisser docker repondre
# "command not found" - message qui n indique nulle part quoi faire.
manque() {
    echo -e "  ${RED}✗ $1${NC}"
    echo -e "    ${CYAN}→ sudo ${DIR}/addition.sh${NC}  (ou l icone ${BOLD}Supplements${NC} du bureau)"
    exit 1
}
command -v docker >/dev/null 2>&1 || manque "docker n est pas installe"
docker info >/dev/null 2>&1        || manque "le demon docker ne repond pas"

if [ ! -f "$MULTI_CONF" ]; then
    manque "topologie absente : $MULTI_CONF"
fi
# shellcheck disable=SC1090
. "$MULTI_CONF"

: "${MULTI_HUB_IP:=172.20.0.10}"
: "${MULTI_M3UA_PORT:=2908}"
: "${MULTI_OPS:=}"
: "${MULTI_IMAGE:=osmocom-run}"

# ── ETAT ────────────────────────────────────────────────────────────────────
etat() {
    local spec idx mode ip pc
    echo -e "  ${BOLD}Topologie${NC} ($MULTI_CONF)"
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip pc _rctx <<< "$spec"
        printf '    op %-2s %-7s %-13s PC %-8s ' "$idx" "$mode" "${ip:-(hote)}" "$pc"
        if [ "$mode" = "native" ]; then
            if pgrep -x osmo-bsc >/dev/null 2>&1 || systemctl is-active --quiet asterisk 2>/dev/null \
               || pgrep -f 'asterisk' >/dev/null 2>&1; then
                echo -e "${GREEN}actif${NC}"
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        else
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "osmo-operator-${idx}"; then
                echo -e "${GREEN}actif${NC}"
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        fi
    done
    printf '    hub  %-7s %-13s PC %-8s ' "docker" "$MULTI_HUB_IP" "${MULTI_HUB_PC:-0.0.0}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${MULTI_HUB_NAME:-osmo-inter-stp}"; then
        echo -e "${GREEN}actif${NC}"
    else
        echo -e "${YELLOW}arrete${NC}"
    fi
}

case "$ACTION" in
  status) etat; exit 0 ;;
  stop)
        for spec in $MULTI_OPS; do
            IFS=: read -r idx mode _ <<< "$spec"
            [ "$mode" = "docker" ] || continue
            docker rm -f "osmo-operator-${idx}" >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓${NC} osmo-operator-${idx} arrete"
        done
        docker rm -f "${MULTI_HUB_NAME:-osmo-inter-stp}" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} hub arrete"
        echo -e "  ${CYAN}i${NC} l operateur NATIF n est pas touche - ${BOLD}sudo ${DIR}/start-direct.sh stop${NC} pour lui."
        exit 0 ;;
esac

# ── L IMAGE ─────────────────────────────────────────────────────────────────
# NOM DE L IMAGE : osmocom-run, PAS "osmo-operator".
# build.sh produit osmocom-nitb (Dockerfile, ~11 Go) puis Dockerfile.run en
# derive osmocom-run, et c est CELLE-LA que start.sh lance - verifie sur le
# banc : `docker inspect osmo-operator-1 --format {{.Config.Image}}` rend
# osmocom-run. Chercher "osmo-operator" (le nom du DEPOT, pas de l image)
# rendait la sonde toujours negative : "image absente" en permanence, et une
# recompilation Osmocom de 40 minutes relancee pour rien a chaque passage.
docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1 \
    || manque "image '$MULTI_IMAGE' absente"

# ── LE RACCORD DU NATIF AU HUB ──────────────────────────────────────────────
# [2026-08-31] RESOLU, dans start.sh, au lancement du hub.
# /etc/osmocom/osmo-stp.cfg (natif) declare
#       asp asp-to-inter 2908 2910 m3ua
#        remote-ip 127.0.0.1
# et rien n ecoutait sur 127.0.0.1:2908 : le hub vit dans le conteneur et ne
# publiait aucun port. Le hub publie desormais 2908 en SCTP sur la boucle
# locale (docker run -p 127.0.0.1:2908:2908/sctp), ce qui rend le remote-ip du
# natif exact sans toucher a une seule config regeneree.
# Verifie sur le banc : docker port -> "2908/sctp -> 127.0.0.1:2908",
# ss -an -> "sctp LISTEN 127.0.0.1:2908", docker-proxy -proto sctp actif.
#
# L autre voie - repointer l ASP natif sur 172.20.0.10 / local-ip 172.20.0.1 -
# a ete ecartee : ces deux adresses n existent que tant que le bridge docker
# est monte, et disparaissent avec les conteneurs.
#
# Le second defaut du meme bloc, lui, etait dans la config : local-ip valait
# 172.20.0.11, l adresse du PREMIER CONTENEUR, inbindable sur l hote. Corrige
# dans generate_configs.sh (apply_native_post_patches), qui ne couvrait pas
# osmo-stp.cfg.

# ── COMBIEN DE CONTENEURS ───────────────────────────────────────────────────
# Ceux marques "docker" dans la table, pas un compte fige : la topologie est
# la seule source.
N_DOCKER=0
for spec in $MULTI_OPS; do
    IFS=: read -r idx mode _ <<< "$spec"
    [ "$mode" = "docker" ] && N_DOCKER=$((N_DOCKER + 1))
done
[ "$N_DOCKER" -ge 1 ] || { echo -e "  ${RED}✗ aucun operateur docker dans la topologie${NC}"; exit 1; }

# OPERATOR_COUNT_HINT : start.sh l utilise pour NE PAS reposer la question du
# nombre de conteneurs (voir start_bridge_mode). Sans elle, le script s arrete
# sur une boite de dialogue - fatal pour un lancement par icone.
# [2026-08-31] PAS DE --wan ICI, ET C EST LE POINT IMPORTANT.
# La premiere version passait --wan --wan-id --hub-ip --operator. Resultat
# mesure : le check de fin cherchait le hub en 192.168.1.49 et l operateur
# portait le point code 1.23.2, alors que la topologie dit 172.20.0.10 et
# 1.2.2. --wan est la machinerie MULTI-MACHINE : il lit/ecrit
# /etc/osmo-wan.conf (qui n existe meme pas ici), renumerote les point codes en
# 1.<noeud><op>.<role> et attend un hub a une adresse routable entre machines.
# Sur UNE machine, c est l inverse qu on veut - et c est deja le defaut :
# checks/wan_ss7_check.sh le dit noir sur blanc, "sans WAN l ASP de chaque
# operateur pointe sur 172.20.0.10", le hub local, avec un catch-all
# "route 0.0.0 0.0.0 → as-inter". Il n y a donc rien a demander a start.sh
# au-dela du nombre de conteneurs.
#
# OPERATOR_COUNT_HINT : start.sh l utilise pour NE PAS reposer la question du
# nombre de conteneurs (voir start_bridge_mode). Sans elle, le script s arrete
# sur une boite de dialogue - fatal pour un lancement par icone.
# OSMO_QUICK=1 : reutiliser le cache docker. Sans elle start.sh partait en
# "Build : normal (--no-cache)", soit une recompilation Osmocom complete de ~40
# minutes A CHAQUE lancement du multi-operateur - alors que l image est deja la
# (addition.sh s en charge, et le prealable plus haut le verifie).
# OSMO_NONINTERACTIVE=1 : les boites whiptail de start.sh rendent leur valeur
# par defaut au lieu d attendre. Sans elle, le lancement s arretait sur
# « Nombre d'operateurs (1-36) » - un dialogue que personne ne voit quand on a
# clique sur une icone, et le banc paraissait mort.
# --operators : le drapeau EXPLICITE de start.sh (l.2552), et non la seule
# variable d environnement. start.sh remettait OPERATOR_COUNT_HINT a vide des
# sa ligne 70 - corrige depuis, mais l argument reste la voie sure : il est
# analyse apres, il prime, et il documente l intention dans la ligne de
# commande qu on affiche.
CMD=(env "OSMO_QUICK=1" "OSMO_NONINTERACTIVE=1"
     "$DIR/start.sh" virtual --operators "$N_DOCKER")

echo -e "  ${BOLD}Topologie${NC} : op1 natif + ${N_DOCKER} conteneur(s) + hub ${MULTI_HUB_IP}"
echo -e "  ${CYAN}→${NC} ${CMD[*]}"
echo

if [ "$ACTION" = "dry" ]; then
    echo -e "  ${YELLOW}--dry-run : rien n a ete lance.${NC}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── SE PLACER DANS LE DEPOT AVANT D APPELER start.sh ────────────────────────
# [2026-08-31] start.sh appelle ses aides en chemin RELATIF - ligne 2595 :
#     ./helpers/prepare_host.sh
# Lance depuis ailleurs (une icone du bureau demarre dans $HOME), il sortait
# donc sur
#     start.sh: line 2595: ./helpers/prepare_host.sh: No such file or directory
# et abandonnait AVANT de creer le moindre conteneur. Le bilan affichait
# ensuite "conteneur absent" trois fois, ce qui faisait chercher un probleme
# de docker alors que le script n avait jamais atteint le docker run.
cd "$DIR" || { echo -e "${RED}Impossible d entrer dans $DIR${NC}"; exit 1; }

"${CMD[@]}"
rc=$?

# ── LE CHECK DE FIN ─────────────────────────────────────────────────────────
# start.sh peut rendre 0 alors que le SS7 n est pas monte : son code de retour
# dit que les conteneurs ont DEMARRE, pas que les ASP se sont associes. C est
# la distinction que le depot documente ailleurs sous le nom de sonde
# mensongere - un superviseur vivant au-dessus d un pont qui n a jamais
# transporte un echantillon. On verifie donc l etat REEL, apres coup.
verifier() {
    local ko=0 spec idx mode nom
    echo
    echo -e "  ${BOLD}── Verification ──${NC}"

    # 1. Les quatre elements sont-ils la ?
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode _ <<< "$spec"
        if [ "$mode" = "docker" ]; then
            nom="osmo-operator-${idx}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
                echo -e "    ${GREEN}✓${NC} conteneur ${nom}"
            else
                echo -e "    ${RED}✗${NC} conteneur ${nom} absent"; ko=1
            fi
        else
            if pgrep -f 'osmo-bsc|asterisk' >/dev/null 2>&1; then
                echo -e "    ${GREEN}✓${NC} operateur natif (op ${idx})"
            else
                echo -e "    ${RED}✗${NC} operateur natif arrete - ${CYAN}sudo ${DIR}/start-direct.sh${NC}"; ko=1
            fi
        fi
    done
    nom="${MULTI_HUB_NAME:-osmo-inter-stp}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
        echo -e "    ${GREEN}✓${NC} inter-STP ${nom}"
    else
        echo -e "    ${RED}✗${NC} inter-STP ${nom} absent"; ko=1
    fi

    # 2. Le point d entree M3UA du natif. On interroge `ss`, PAS /dev/tcp :
    #    M3UA roule sur SCTP, et une sonde TCP y est muette - la version
    #    precedente de ce check l avouait ("non concluant"), ce qui en faisait
    #    une ligne inutile. `ss -an` voit les sockets SCTP nommement.
    # awk par CHAMPS et pas un regex : `ss -an` aligne ses colonnes avec un
    # nombre d espaces VARIABLE selon la longueur des adresses, et un
    # "^sctp[[:space:]]+LISTEN.*" s y casse sans prevenir - teste, il ne
    # trouvait pas une ligne pourtant bien presente. $1/$2/$5 sont stables.
    if ss -an 2>/dev/null | awk -v p=":${MULTI_M3UA_PORT}" \
         '$1=="sctp" && $2=="LISTEN" && index($5,p)==length($5)-length(p)+1 {f=1} END{exit !f}'; then
        echo -e "    ${GREEN}✓${NC} M3UA en SCTP sur 127.0.0.1:${MULTI_M3UA_PORT} (l operateur natif peut s attacher)"
    else
        echo -e "    ${RED}✗${NC} rien n ecoute en SCTP sur le port ${MULTI_M3UA_PORT}"
        echo -e "      l ASP du natif (osmo-stp.cfg, remote-ip 127.0.0.1) ne trouvera personne"
        ko=1
    fi

    # 3. Le verificateur SS7 du depot, qui sait lire les ASP et les routes.
    if [ -x "$DIR/checks/ss7_check.sh" ]; then
        echo -e "    ${CYAN}→${NC} checks/ss7_check.sh"
        "$DIR/checks/ss7_check.sh" || ko=1
    else
        echo -e "    ${YELLOW}○${NC} checks/ss7_check.sh absent - verification SS7 sautee"
    fi

    echo
    if [ "$ko" = "0" ]; then
        echo -e "  ${GREEN}${BOLD}Banc multi-operateur OPERATIONNEL.${NC}"
    else
        echo -e "  ${RED}${BOLD}Le banc n est PAS complet${NC} - voir les lignes ✗ ci-dessus."
        echo -e "  ${CYAN}→${NC} etat detaille : ${BOLD}sudo $0 --status${NC}"
    fi
    return "$ko"
}

echo
etat
verifier || rc=1
# Ouverte par nos soins : on la retient, sinon le bilan disparait avec elle.
if [ "${OSMO_MULTI_TERM:-0}" = "1" ]; then
    echo
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
