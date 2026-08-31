#!/bin/bash
# =============================================================================
# addition.sh - LES SUPPLEMENTS QUI NE SONT PAS DANS L ISO
#
# Jumelle d update.sh, et lancee comme elle : une icone GTK sur le bureau
# (osmo-addition-anim), ou a la main.
#
# POURQUOI DOCKER N EST PAS DANS L IMAGE
# L ISO est un noeud NATIF : elle porte le banc complet sans conteneur, et
# n a donc besoin de docker pour rien. L y embarquer couterait ~500 Mo et le
# demon tournerait en permanence sur un banc qui ne s en sert pas - avec son
# bridge, ses regles iptables et sa MASQUERADE, au milieu d une machine dont
# tout l interet est de router du GSM a la main.
# Docker ne sert qu a UN scenario : le multi-operateur (start-multi.sh), ou les
# operateurs 2 et 3 et l inter-STP tournent en conteneurs a cote du natif.
# C est un supplement, il s installe comme tel - ici.
#
# Usage :
#   sudo ./addition.sh            fenetre GTK : un choix, "Docker container
#                                 and SS7 multioperator"
#   sudo ./addition.sh --multi    le meme, sans la fenetre
#   sudo ./addition.sh --docker   le moteur de conteneurs seul   (depannage)
#   sudo ./addition.sh --image    l image operateur seule, build.sh (depannage)
#   sudo ./addition.sh --status   dit seulement ce qui est present
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
# NOM DE L IMAGE : osmocom-run, PAS "osmo-operator".
# build.sh produit osmocom-nitb (Dockerfile, ~11 Go) puis Dockerfile.run en
# derive osmocom-run, et c est CELLE-LA que start.sh lance - verifie sur le
# banc : `docker inspect osmo-operator-1 --format {{.Config.Image}}` rend
# osmocom-run. Chercher "osmo-operator" (le nom du DEPOT, pas de l image)
# rendait la sonde toujours negative : "image absente" en permanence, et une
# recompilation Osmocom de 40 minutes relancee pour rien a chaque passage.
MULTI_IMAGE="${MULTI_IMAGE:-osmocom-run}"

DO_DOCKER=0; DO_IMAGE=0; DO_MULTI=0; STATUS_ONLY=0; ANY_FLAG=0
for a in "$@"; do
    case "$a" in
        --docker) DO_DOCKER=1; ANY_FLAG=1 ;;
        --image)  DO_IMAGE=1;  ANY_FLAG=1 ;;
        --multi)  DO_MULTI=1;  ANY_FLAG=1 ;;
        --all)    DO_DOCKER=1; DO_IMAGE=1; DO_MULTI=1; ANY_FLAG=1 ;;
        --status) STATUS_ONLY=1; ANY_FLAG=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    esac
done

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - supplements (hors ISO)             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

etat() {
    local ok_d=0 ok_r=0 ok_i=0 ok_m=0
    command -v docker >/dev/null 2>&1 && ok_d=1
    [ "$ok_d" = "1" ] && docker info >/dev/null 2>&1 && ok_r=1
    [ "$ok_r" = "1" ] && docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1 && ok_i=1
    [ -f "$MULTI_CONF" ] && ok_m=1
    [ "$ok_d" = "1" ] && echo -e "  docker installe      : ${GREEN}oui${NC}"      || echo -e "  docker installe      : ${YELLOW}non${NC}"
    [ "$ok_r" = "1" ] && echo -e "  demon actif          : ${GREEN}oui${NC}"      || echo -e "  demon actif          : ${YELLOW}non${NC}"
    [ "$ok_i" = "1" ] && echo -e "  image operateur      : ${GREEN}presente${NC}" || echo -e "  image operateur      : ${YELLOW}absente${NC}"
    [ "$ok_m" = "1" ] && echo -e "  topologie SS7        : ${GREEN}posee${NC}"    || echo -e "  topologie SS7        : ${YELLOW}absente${NC}"
}

[ "$STATUS_ONLY" = "1" ] && { etat; exit 0; }

# ── LE CHOIX ────────────────────────────────────────────────────────────────
# Lancee par l icone, cette fenetre est la SEULE interface : sans elle, un
# double-clic partait droit sur un apt-get de plusieurs centaines de Mo et une
# compilation Osmocom, sans rien demander.
#
# [2026-08-31] UN SEUL CHOIX, ET C EST VOULU.
# La liste a cocher en offrait trois - "multi-operateur SS7", "docker", "image
# operateur" - alors qu il n y a jamais eu qu un scenario : le multi-operateur,
# qui ENTRAINE les deux autres (l implication, juste en dessous, remettait
# DO_DOCKER=1 et DO_IMAGE=1 des que la premiere ligne etait cochee). Les deux
# dernieres cases n etaient donc decochables qu en apparence : les decocher ne
# changeait rien tant que la premiere restait cochee, et les cocher seules
# donnait un demi-supplement dont rien ne se sert - docker sans image, ou une
# image de 11 Go sans la topologie qui l emploie.
# Une fenetre qui propose des choix sans effet ment sur ce que fait le script.
# Une question, une reponse : on installe "Docker container and SS7
# multioperator", ou on ferme.
# Les drapeaux --docker / --image restent, eux, pour le depannage en console.
if [ "$ANY_FLAG" = "0" ]; then
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        zenity --question --width=560 \
            --title="osmo-operator - supplements" \
            --icon-name=system-software-install \
            --ok-label="Installer" --cancel-label="Fermer" \
            --text="<b>Docker container and SS7 multioperator</b>

Ce supplement n est PAS dans l ISO. Il installe :

  - docker (apt : docker.io) - le moteur de conteneurs
  - l image operateur, via <tt>/opt/GSM/osmo-operator/build.sh</tt>
     compilation Osmocom : <b>tres long</b>, plusieurs dizaines de minutes
  - la topologie SS7 : op1 natif + op2/op3 docker + inter-STP

Une connexion Internet est necessaire." \
            2>/dev/null || { echo "Annule."; exit 0; }
    fi
    # Console sans zenity, ou fenetre validee : c est le meme supplement.
    DO_MULTI=1
fi

# Le multi-operateur ENTRAINE ses dependances : sans moteur ni image, la
# topologie posee ne servirait a rien et start-multi.sh renverrait ici.
if [ "$DO_MULTI" = "1" ]; then DO_DOCKER=1; DO_IMAGE=1; fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── DOCKER ──────────────────────────────────────────────────────────────────
# docker.io des depots Ubuntu, PAS le script get.docker.com : celui-ci ajoute un
# depot tiers et remplace containerd, ce qui sur une image figee se paie au
# premier apt-get upgrade. La version des depots suffit : on ne fait tourner
# que nos propres conteneurs.
if [ "$DO_DOCKER" = "1" ]; then
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker deja installe ($(docker --version 2>/dev/null | head -1))"
    else
        echo -e "  ${CYAN}→${NC} installation de docker.io ..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || { echo -e "  ${RED}✗ apt-get update a echoue - pas de reseau ?${NC}"
                            echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
                            exit 1; }
        apt-get install -y docker.io || { echo -e "  ${RED}✗ installation de docker.io echouee${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} docker.io installe"
    fi
    systemctl enable --now docker 2>/dev/null || true
    # Le socket met un instant a repondre apres un premier demarrage : sans
    # cette attente, le `docker info` suivant echoue et l on croit
    # l installation ratee.
    for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} demon docker actif" \
        || { echo -e "  ${RED}✗ le demon docker ne repond pas${NC} - voir : systemctl status docker"; exit 1; }
fi

# ── IMAGE OPERATEUR ─────────────────────────────────────────────────────────
if [ "$DO_IMAGE" = "1" ]; then
    if docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} image operateur deja presente (${MULTI_IMAGE})"
    elif [ -x "$DIR/build.sh" ]; then
        echo -e "  ${CYAN}→${NC} construction de l image : ${BOLD}${DIR}/build.sh${NC}"
        echo -e "      compilation Osmocom - comptez plusieurs dizaines de minutes."
        "$DIR/build.sh" || { echo -e "  ${RED}✗ ${DIR}/build.sh a echoue${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} image operateur construite"
    else
        echo -e "  ${RED}✗ build.sh introuvable dans $DIR${NC}"; exit 1
    fi
fi

# ── TOPOLOGIE MULTI-OPERATEUR ───────────────────────────────────────────────
# Ecrite ICI, une fois, et relue par start-multi.sh. Elle n est pas recalculee
# des deux cotes : deux formules jumelles finissent toujours par diverger, et le
# depot en porte deja la trace (start.sh et lib/gabarits.sh tiennent les MEMES
# fonctions en double).
#
# LE PLAN SS7, tel que start-interstp.sh le definit :
#     PC   = 1.<noeud><op>.<role>      role 1=MSC 2=STP 3=BSC
#     RCTX = noeud*1000 + op*100 + 50
# Sur une seule machine le noeud vaut 1, donc PC = 1.<op>.<role>.
#
#   op 1  NATIF   - PC 1.1.2, celui de start-direct.sh, laisse tel quel
#   op 2  DOCKER  - PC 1.2.2, backbone 172.20.0.12
#   op 3  DOCKER  - PC 1.3.2, backbone 172.20.0.13
#
# ⚠️ LES CONTENEURS COMMENCENT A 2, ET CELA SE PILOTE.
# start.sh numerotait ses conteneurs 1..N en dur : avec --operators 2 il creait
# osmo-operator-1 en point code 1.1.2, celui du natif. Deux equipements a la
# meme adresse SS7 - "pas un conflit de nom, du routage faux"
# (checks/wan_ss7_check.sh). OP_ID_BASE=2 (start.sh) fait demarrer les
# conteneurs au rang 2 et laisse le 1 au natif ; nom, backbone, point code,
# RCTX, segment prive et ports publies en decoulent tous.
# Le natif joint le hub par la passerelle du bridge : l hote atteint
# 172.20.0.10 directement, sans NAT ni route a ajouter.
if [ "$DO_MULTI" = "1" ]; then
    install -d "$(dirname "$MULTI_CONF")"
    cat > "$MULTI_CONF" <<CONF
# osmo-multi.conf - topologie multi-operateur, ecrite par addition.sh.
# Relue par start-multi.sh. Ne pas editer a la main sans relire les deux.
MULTI_NODE=1
MULTI_HUB_NAME=osmo-inter-stp
MULTI_HUB_IP=172.20.0.10
MULTI_HUB_PC=0.0.0
MULTI_M3UA_PORT=2908
MULTI_NET_NAME=osmo-ss7
MULTI_NET_SUBNET=172.20.0.0/24
MULTI_NET_GW=172.20.0.1
MULTI_IMAGE=osmocom-run
# operateurs : "index:mode:backbone_ip:point_code:rctx"
MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:1.2.2:250 3:docker:172.20.0.13:1.3.2:350"
CONF
    echo -e "  ${GREEN}✓${NC} topologie SS7 ecrite : ${CYAN}${MULTI_CONF}${NC}"
    echo -e "      op1 ${BOLD}natif${NC} (1.1.2) + op2/op3 ${BOLD}docker${NC} (1.2.2 / 1.3.2) → hub 172.20.0.10"
fi

echo
etat
echo
[ "$DO_MULTI" = "1" ] && \
    echo -e "  ${CYAN}→${NC} lancer : ${BOLD}sudo $DIR/start-multi.sh${NC}  (ou l antenne bleue du bureau)"
exit 0
