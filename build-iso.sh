#!/bin/bash
# build-iso.sh - Genere une ISO bootable en utilisant build.sh et start.sh
# Aucun docker build direct dans ce script, tout passe par les scripts existants.
set -euo pipefail

# Couleurs definies AVANT tout : sous `set -u`, la premiere ligne coloree d'un
# script qui les declare plus bas echoue sur "variable sans liaison" - et le
# message ne parle ni de couleurs ni de l'endroit fautif.
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

VERSION="${OSMO_ISO_VERSION:-main}"
OUTPUT="osmo_egprs-${VERSION}.iso"
# Repertoire de travail SUR DISQUE (pas /tmp, souvent un tmpfs en RAM -> "No
# space left on device" car le rootfs est volumineux). Overridable via OSMO_ISO_WORK.
WORK="${OSMO_ISO_WORK:-/var/tmp}/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS_V2"
DIR="$(cd "$(dirname "$0")" && pwd)"

NO_CACHE=""
# ── WAN : jamais par defaut. Avec --wan, l'ISO EST un noeud du WAN ───────────
# La table est figee dans /etc/osmo-wan.conf de l'image ; au demarrage
# start-direct.sh la voit (WAN_AUTO=1) et l'applique sans qu'on repasse --wan.
#
# UNE SEULE ISO pour les N machines : chacune se reconnait a son IP dans la
# table (wan_nodes_detect_self). --wan-id ne sert qu'a forcer un noeud quand
# l'IP ne suffit pas (DHCP non fixe, NAT).
ISO_WAN=0
ISO_WAN_NODES=""
ISO_WAN_ID=""
ISO_WAN_OPS=1

# ── ROLE DE L'IMAGE ──────────────────────────────────────────────────────────
# Une seule chaine de construction, deux produits :
#
#   --role operator --node N   →  osmo-operator-N.iso
#       Un noeud du WAN : coeur GSM complet, ses point codes a lui, son ASP
#       attache au hub. C'est l'image historique, plus l'identite de noeud.
#
#   --role interstp            →  interstp.iso
#       Le hub SS7 : PC 0.0.0, aucun operateur, il ne fait QUE router du M3UA
#       entre les noeuds. C'est ce qui manquait pour que le SS7 traverse le WAN.
#
# Sans --role, rien ne change : on produit l'ISO d'avant, sous son nom d'avant.
ISO_ROLE=""
ISO_ROLE_GIVEN=0
ISO_NODE=""
# ── VARIANTE LITE ───────────────────────────────────────────────────────────
#   --lite  →  osmo-operator-lite.iso
# Le meme noeud, construit depuis l'image d'execution elaguee (Dockerfile.lite)
# au lieu de l'image de construction : les ateliers de compilation de /opt/GSM -
# gnuradio, gr-gsm, libosmo*, osmo-*, les objets de qemu - ne partent pas dans
# le squashfs. Ce qui TOURNE est identique, aux fichiers pres qui n'ont servi
# qu'a compiler. Les trois depots, eux, restent entiers : c'est la regle de
# cette image, pas une exception (voir Dockerfile.lite).
ISO_LITE=0
# ── VARIANTE DESKTOP ────────────────────────────────────────────────────────
#   --desktop  →  osmo-operator-desktop.iso
# La meme image, plus un bureau GNOME (ubuntu-desktop-minimal), wireshark en
# fenetre et linphone-desktop. Elle existe pour ce qui ne se pilote pas au VTY :
# lire une capture GSMTAP dans wireshark plutot qu en tshark, passer un appel
# SIP a la main sur le coeur qu on vient de demarrer, ouvrir les outils Qt de
# gr-gsm (grgsm_livemon). Le rootfs grossit d environ 2,5 Go : c est pourquoi
# c est une VARIANTE, et non un ajout aux images existantes.
ISO_DESKTOP=0
# ── --all : TOUTES les images en une passe ──────────────────────────────────
# Sans argument, le script construit deja les trois images historiques (hub,
# noeud, noeud lite). --all y ajoute la desktop : c est la seule facon de tout
# sortir d un coup, sans avoir a relancer une quatrieme fois a la main. Il ne
# change rien au comportement par defaut - la desktop pese ~2,5 Go de plus et
# n a pas a s imposer a qui ne l a pas demandee.
ISO_ALL=0
# Defaut : le hub du banc, en acces par pont. Le host-only VirtualBox
# (192.168.56.1) reste possible, mais via --hub-ip : il n'existe sur aucun
# segment quand les VM sont pontees.
ISO_HUB_IP="192.168.1.49"
ISO_SUBNET="192.168.56"
# ── Table WAN par defaut : le banc ──────────────────────────────────────────
# Format : <noeud>:<IP>:<indicatif>
#   noeud 1  172.20.0.11  osmo-operator-1  indicatif 11   (conteneur)
#   noeud 2  172.20.0.12  osmo-operator-2  indicatif 22   (conteneur)
#   noeud 3  192.168.1.2  la VM            indicatif 33
#   hub      192.168.1.49                                  (hors table)
# Elle sert quand --wan-nodes n'est pas donne. Sans defaut, une construction
# sans terminal - la CI - s'arretait a l'etape 7b sur une question que personne
# ne lisait : "pas de terminal : renseignez WAN_NODES / WAN_NODE_ID / WAN_OPS".
ISO_WAN_NODES_DEFAULT="1:172.20.0.11:11 2:172.20.0.12:22 3:192.168.1.2:33"
OUTPUT_SET=0
for arg in "$@"; do case "$arg" in
    --output=*)     OUTPUT="${arg#*=}"; OUTPUT_SET=1 ;;
    --no-cache)     NO_CACHE="--no-cache" ;;
    --wan)          ISO_WAN=1 ;;
    --wan-nodes=*)  ISO_WAN=1; ISO_WAN_NODES="${arg#*=}" ;;
    --wan-id=*)     ISO_WAN=1; ISO_WAN_ID="${arg#*=}" ;;
    --wan-ops=*)    ISO_WAN=1; ISO_WAN_OPS="${arg#*=}" ;;
    --role=*)       ISO_ROLE="${arg#*=}"; ISO_ROLE_GIVEN=1 ;;
    --node=*)       ISO_NODE="${arg#*=}" ;;
    --hub-ip=*)     ISO_HUB_IP="${arg#*=}" ;;
    --subnet=*)     ISO_SUBNET="${arg#*=}" ;;
    --kb=*)         OSMO_ISO_KB="${arg#*=}" ;;
    --lite)         ISO_LITE=1 ;;
    --desktop)      ISO_DESKTOP=1 ;;
    --all)          ISO_ALL=1 ;;
esac; done

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# LES QUESTIONS : toutes ici, une seule fois, avant que quoi que ce soit ne parte
# ══════════════════════════════════════════════════════════════════════════════
# Une question posee au milieu d'une construction d'une heure attend un humain
# qui, lui, est parti. Et posee dans l'IMAGE - au premier boot - elle bloque
# chaque machine qui demarre, alors que la reponse est la meme pour toutes.
#
# Tout ce qui se demande se demande donc ICI :
#   - avant la construction, pour ne jamais interrompre une passe en cours ;
#   - une seule fois, meme quand on produit les DEUX images : la reponse part
#     dans l'environnement (export), et les passes filles en heritent ;
#   - jamais en CI : sans terminal, on prend le defaut au lieu d'attendre un
#     EOF qui, sous set -e, ferait echouer la construction.
#
# --kb=XX ou OSMO_ISO_KB=XX court-circuitent la question.
ISO_KB_DEFAULT="fr"
if [ -z "${OSMO_ISO_KB:-}" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}══ Clavier de l'image ══${NC}"
        echo "  1) fr   2) us   3) de   4) es   5) it"
        echo "  6) pt   7) gb   8) be   9) ch   0) autre"
        read -rp "  Choix [1] : " _kb_choice || _kb_choice=""
        case "${_kb_choice:-1}" in
            1|"") OSMO_ISO_KB="fr" ;;
            2) OSMO_ISO_KB="us" ;;  3) OSMO_ISO_KB="de" ;;
            4) OSMO_ISO_KB="es" ;;  5) OSMO_ISO_KB="it" ;;
            6) OSMO_ISO_KB="pt" ;;  7) OSMO_ISO_KB="gb" ;;
            8) OSMO_ISO_KB="be" ;;  9) OSMO_ISO_KB="ch" ;;
            0) read -rp "  Layout (fr, us, ru, ar...) : " OSMO_ISO_KB || OSMO_ISO_KB=""
               OSMO_ISO_KB="${OSMO_ISO_KB:-$ISO_KB_DEFAULT}" ;;
            *) OSMO_ISO_KB="$ISO_KB_DEFAULT" ;;
        esac
    else
        OSMO_ISO_KB="$ISO_KB_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : clavier ${OSMO_ISO_KB} (--kb=XX pour changer)${NC}"
    fi
fi
export OSMO_ISO_KB
echo -e "  ${GREEN}✓${NC} clavier de l'image : ${CYAN}${OSMO_ISO_KB}${NC}"

# ── Sans argument : LES DEUX images ─────────────────────────────────────────
# Un WAN a besoin de deux choses differentes - un hub SS7 et des noeuds - et
# rien ne dit laquelle on veut quand on ne precise rien. On produit donc les
# deux, par deux passes completes.
#
# UNE SEULE image d'operateur suffit pour les neuf noeuds : le numero se choisit
# au demarrage (`start-direct.sh --node N`), qui reecrit les point codes. C'est
# la raison pour laquelle on ne fabrique pas osmo-operator-1..9.
#
if [ "$ISO_ALL" = "1" ] || { [ "$ISO_ROLE_GIVEN" = "0" ] && [ "$OUTPUT_SET" = "0" ] \
   && [ -z "$ISO_NODE" ] && [ "$ISO_LITE" = "0" ] && [ "$ISO_DESKTOP" = "0" ]; }; then
    # --all ajoute la desktop aux trois images historiques. Sans lui (aucun
    # role demande), on garde exactement les trois d'avant.
    _N="QUATRE"   # [2026-08-29] --all par defaut : les QUATRE images, desktop incluse
    echo -e "${CYAN}${BOLD}══ Construction des ${_N} images ══${NC}"
    echo -e "  1. ${CYAN}interstp.iso${NC}               le hub SS7 (PC 0.0.0)"
    echo -e "  2. ${CYAN}osmo-operator.iso${NC}          un noeud - son numero se choisit au demarrage :"
    echo -e "     ${CYAN}./start-direct.sh --node N${NC}   (N de 1 a 9)"
    echo -e "  3. ${CYAN}osmo-operator-lite.iso${NC}     le meme noeud, sans les ateliers de compilation"
    echo -e "  4. ${CYAN}osmo-operator-desktop.iso${NC}  le meme noeud, avec GNOME, wireshark et linphone"
    echo ""

    # --all et --desktop RETIRES des arguments repasses aux passes filles.
    # Les laisser ferait rentrer chaque passe dans ce meme bloc : une recursion
    # sans fond, qui ne produirait jamais la moindre ISO.
    SUB_ARGS=()
    for _a in "$@"; do
        case "$_a" in --all|--desktop) ;; *) SUB_ARGS+=("$_a") ;; esac
    done
    set -- "${SUB_ARGS[@]+"${SUB_ARGS[@]}"}"

    # L'ordre n'est pas cosmetique. Le hub d'abord : il ne depend ni de build.sh
    # ni de l'image osmocom-run, un echec de son cote se voit en minutes. Les
    # variantes du noeud en DERNIER : elles se greffent sur l'image osmocom-run
    # que la passe operateur vient de construire, donc elles ne coutent que
    # l'elagage (lite), l'ajout du bureau (desktop) et l'assemblage.
    "$0" --role=interstp "$@" || { echo -e "${RED}Echec de interstp.iso${NC}" >&2; exit 1; }
    "$0" --role=operator --output=osmo-operator.iso "$@" \
        || { echo -e "${RED}Echec de osmo-operator.iso${NC}" >&2; exit 1; }
    # --no-cache RETIRE pour les passes greffees, et lui seul. Il vaut pour la
    # construction des images docker ; ces passes ne construisent rien, elles
    # reprennent osmocom-run que la passe precedente vient de produire. Le leur
    # repasser relancerait build.sh et build_run_image depuis zero : deux heures
    # de compilation pour aboutir a la meme image, puis a la meme coupe.
    GRAFT_ARGS=(); for _a in "$@"; do [ "$_a" = "--no-cache" ] || GRAFT_ARGS+=("$_a"); done
    "$0" --role=operator --lite --output=osmo-operator-lite.iso "${GRAFT_ARGS[@]+"${GRAFT_ARGS[@]}"}" \
        || { echo -e "${RED}Echec de osmo-operator-lite.iso${NC}" >&2; exit 1; }
    _ISOS=("$(pwd)/interstp.iso" "$(pwd)/osmo-operator.iso" "$(pwd)/osmo-operator-lite.iso")
    # [2026-08-29] --all par defaut : la desktop est TOUJOURS construite.
    "$0" --role=operator --desktop --output=osmo-operator-desktop.iso "${GRAFT_ARGS[@]+"${GRAFT_ARGS[@]}"}" \
        || { echo -e "${RED}Echec de osmo-operator-desktop.iso${NC}" >&2; exit 1; }
    _ISOS+=("$(pwd)/osmo-operator-desktop.iso")
    echo -e "${GREEN}${BOLD}═══ Les ${_N} images sont pretes ═══${NC}"
    ls -lh "${_ISOS[@]}" 2>/dev/null | sed 's/^/  /'
    exit 0
fi

case "${ISO_ROLE:-operator}" in
    interstp)
        ISO_ROLE="interstp"
        [ "$OUTPUT_SET" = "1" ] || OUTPUT="interstp.iso"
        # Le hub n'a pas d'atelier a elaguer : son image (Dockerfile.stp) ne
        # porte que osmo-stp et quatre bibliotheques. --lite n'y veut rien dire,
        # et l'accepter en silence produirait une "lite" identique a l'autre.
        [ "$ISO_LITE" = "1" ] && { echo "--lite ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # Meme raison pour le bureau : le hub tourne sans ecran, en salle
        # machine ou en VM sans console graphique. Un GNOME dessus, c'est 2,5 Go
        # et une pile X de plus sur la seule image qui n'affiche jamais rien.
        [ "$ISO_DESKTOP" = "1" ] && { echo "--desktop ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # Le hub dessert N noeuds : sans table WAN on ne sait pas combien.
        ISO_WAN=1 ;;
    operator|"")
        ISO_ROLE="operator"
        if [ -n "$ISO_NODE" ]; then
            [[ "$ISO_NODE" =~ ^[1-9]$ ]] || { echo "--node : 1 a 9" >&2; exit 2; }
            if [ "$OUTPUT_SET" = "0" ]; then
                _sfx=""
                [ "$ISO_LITE" = "1" ]    && _sfx="${_sfx}-lite"
                [ "$ISO_DESKTOP" = "1" ] && _sfx="${_sfx}-desktop"
                OUTPUT="osmo-operator-${ISO_NODE}${_sfx}.iso"
            fi
            ISO_WAN_ID="${ISO_WAN_ID:-$ISO_NODE}"
            ISO_WAN=1
        elif [ "$ISO_LITE" = "1" ] || [ "$ISO_DESKTOP" = "1" ]; then
            if [ "$OUTPUT_SET" = "0" ]; then
                _sfx=""
                [ "$ISO_LITE" = "1" ]    && _sfx="${_sfx}-lite"
                [ "$ISO_DESKTOP" = "1" ] && _sfx="${_sfx}-desktop"
                OUTPUT="osmo-operator${_sfx}.iso"
            fi
        fi ;;
    *) echo "--role inconnu : $ISO_ROLE (operator|interstp)" >&2; exit 2 ;;
esac
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac

# ── La table WAN : arretee ICI, pas au milieu de la construction ────────────
# --role=interstp implique le WAN (le hub doit savoir combien de noeuds il
# dessert). L'etape 7b la demandait alors interactivement, une heure apres le
# lancement : de quoi bloquer une construction que l'on croyait autonome, et
# faire echouer la CI, qui n'a pas de terminal pour repondre.
#
# On la fige donc maintenant, avec la table du banc pour defaut. --wan-nodes
# reste prioritaire et n'est pas touche.
# Avec terminal on DEMANDE - un banc n'a pas toujours les adresses du notre.
# Sans terminal (CI, cron) on prend le defaut : rester bloque sur une lecture
# que personne ne verra ne ferait qu'echouer plus tard, et plus obscurement.
if [ "$ISO_WAN" = "1" ] && [ -z "$ISO_WAN_NODES" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}== Table WAN de l'image ==${NC}"
        echo -e "  Format : ${CYAN}<noeud>:<IP>:<indicatif>${NC}, separes par des espaces."
        echo -e "  Entree vide = le banc : ${CYAN}${ISO_WAN_NODES_DEFAULT}${NC}"
        read -rp "  Noeuds : " _wan_in || _wan_in=""
        ISO_WAN_NODES="${_wan_in:-$ISO_WAN_NODES_DEFAULT}"
        if [ "$ISO_ROLE" = "interstp" ]; then
            read -rp "  IP du hub [${ISO_HUB_IP}] : " _hub_in || _hub_in=""
            ISO_HUB_IP="${_hub_in:-$ISO_HUB_IP}"
        fi
    else
        ISO_WAN_NODES="$ISO_WAN_NODES_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : table WAN par defaut${NC}"
    fi
    echo -e "  ${GREEN}✓${NC} WAN : ${CYAN}${ISO_WAN_NODES}${NC}   hub ${CYAN}${ISO_HUB_IP}${NC}"
fi

# Propage --no-cache aux deux builds Docker : build.sh (image osmocom-nitb) et
# build_run_image (image osmocom-run, via DOCKER_NO_CACHE).
export DOCKER_NO_CACHE="$NO_CACHE"


cleanup() { umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT


# ── Paquets hote requis pour fabriquer l'ISO (squashfs, grub, xorriso...) ──
# Installes ici plutot que dans le workflow CI : `sudo ./build-iso.sh` suffit
# sur une machine Debian/Ubuntu vierge, sans etape "Install host tools" externe.
# shim-signed / grub-efi-amd64-signed / dosfstools : la chaine Secure Boot.
# Voir "Etape 9" plus bas - sans eux l'ISO ne demarre pas sur une machine dont
# le Secure Boot est actif, et le firmware ne dit qu'une erreur de certificat.
ISO_HOST_PKGS="squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools debootstrap git isolinux shim-signed grub-efi-amd64-signed"
if command -v apt-get &>/dev/null; then
    echo -e "${GREEN}[0/9] Installation des paquets hote (apt)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    # Options passees EN LIGNE, pas via /etc/apt : on est sur la machine de
    # l'utilisateur, pas dans un rootfs jetable. On allege ce qui est telecharge
    # (traductions) sans toucher aux garanties d'ecriture de son dpkg.
    HOST_APT_FAST="-o Acquire::Languages=none -o Acquire::Retries=3 -o Acquire::http::Pipeline-Depth=5"
    apt-get update -qq $HOST_APT_FAST || true
    # isolinux est optionnel (isohybrid) : on n'echoue pas s'il manque.
    apt-get install -y $HOST_APT_FAST --no-install-recommends $ISO_HOST_PKGS \
        || apt-get install -y $HOST_APT_FAST --no-install-recommends \
           squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools debootstrap git
else
    echo -e "${YELLOW}apt-get absent : verification seule des outils hote.${NC}"
fi

# Docker n'est pas auto-installe ici (paquet docker-ce hors apt standard).
for t in docker mksquashfs xorriso grub-mkrescue debootstrap git; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo_egprs ISO builder (via build.sh + start.sh) ══${NC}"

# ── Etape 1 : Executer build.sh pour preparer l'hote et construire osmocom-nitb ──
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${GREEN}[1/9] Role inter-STP : build.sh SAUTE${NC}"
    echo -e "  ${CYAN}Le hub route du M3UA. Ni HLR, ni MSC, ni BSC, ni radio, ni Asterisk :${NC}"
    echo -e "  ${CYAN}rien de ce que construit build.sh ne le concerne.${NC}"
else
echo -e "${GREEN}[1/9] Execution de build.sh...${NC}"
if [ -f "$DIR/build.sh" ]; then
    bash "$DIR/build.sh" $NO_CACHE
else
    echo -e "${YELLOW}build.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
    docker build $NO_CACHE -t osmocom-nitb "$DIR"
fi
echo -e "  ${GREEN}✓${NC} image osmocom-nitb prete"
fi

load_start_lib() {
    local src="$DIR/start.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # La lib vit dans $WORK, pas dans le depot : sans ca, la resolution par
    # BASH_SOURCE de start.sh chercherait generate_configs.sh a cote de la copie.
    export OSMO_REPO_DIR="$DIR"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Etape 2 : Construire l'image osmocom-run via start.sh ─────────────────────
# load_start_lib est necessaire dans TOUS les cas : c'est lui qui apporte
# apply_config_templates. C'est build_run_image - deux heures de compilation de
# la pile complete - que le hub n'a aucune raison de payer.
load_start_lib
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${GREEN}[2/9] Construction de l'image ${CYAN}osmocom-stp${NC}${GREEN} (Dockerfile.stp)...${NC}"
    echo -e "  ${CYAN}osmo-stp + libosmocore + libosmo-netif + libosmo-sigtran. Rien d'autre.${NC}"
    docker build $NO_CACHE -f "$DIR/Dockerfile.stp" -t osmocom-stp "$DIR" \
        || { echo -e "${RED}Echec de la construction d'osmocom-stp${NC}"; exit 1; }
    echo -e "  ${GREEN}✓${NC} osmocom-stp construite ($(docker image inspect osmocom-stp --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f Mo", $1/1048576}'))"
else
    echo -e "${GREEN}[2/9] Construction de l'image osmocom-run via start.sh...${NC}"
    build_run_image
    echo -e "  ${GREEN}✓${NC} osmocom-run construite"

    # ── La variante lite : on elague l'image d'EXECUTION, pas celle de build ──
    # Dockerfile.lite est ecrit pour partir de n'importe quelle base (ARG BASE).
    # On le branche sur osmocom-run - celle qui porte les configs et que l'ISO
    # copie - et non sur osmocom-nitb comme le fait "build.sh --lite" : elaguer
    # l'etage du dessous obligerait a refaire build_run_image par-dessus, soit
    # deux heures pour le meme resultat.
    # Pas de docker build a partir de zero ici : l'image est deja la, il ne
    # reste que la coupe et l'aplatissement - quelques minutes.
    if [ "$ISO_LITE" = "1" ]; then
        echo -e "${GREEN}[2-lite/9] Elagage vers ${CYAN}osmocom-run:lite${NC}${GREEN} (Dockerfile.lite)...${NC}"
        docker build $NO_CACHE -f "$DIR/Dockerfile.lite" --build-arg BASE=osmocom-run \
            -t osmocom-run:lite "$DIR" \
            || { echo -e "${RED}Echec de l'elagage (Dockerfile.lite)${NC}"; exit 1; }
        _full=$(docker image inspect osmocom-run      --format '{{.Size}}' 2>/dev/null || echo 0)
        _lite=$(docker image inspect osmocom-run:lite --format '{{.Size}}' 2>/dev/null || echo 0)
        echo -e "  ${GREEN}✓${NC} osmocom-run:lite $(awk -v a="$_full" -v b="$_lite" \
            'BEGIN{printf "%.1f Go -> %.1f Go", a/1073741824, b/1073741824}')"
    fi
fi

echo -e "${GREEN}[2b/9] Preparation de l'image source de l'ISO...${NC}"

ISO_N_MS=2
ISO_OP_ID=1         # operateur unique de l'ISO (PLMN 001-01)
ENCRYPTION="a5 1"   # A5/1 par defaut dans l'ISO -- la valeur suit enfin le commentaire

# L'ISO tourne en NATIF, sans bridge docker. Les 172.20.0.x existaient quand
# meme : 20-dhcp.network (plus bas) les alias sur le NIC par defaut. Mais faire
# ecouter le coeur dessus le rend tributaire de ce NIC - s'il est absent (VM
# sans carte), nomme hors de "en* eth*", ou simplement pas encore configure
# par systemd-networkd quand osmo-ggsn demarre, le bind echoue. La boucle
# locale, elle, est toujours la et prete avant tout service.
# Concerne : osmo-ggsn (gtp bind-ip), osmo-sgsn (ggsn remote-ip), osmo-upf
# (local-addr), osmo-bsc (gprs nsvc remote ip) et le log gsmtap, que l'on
# ramene ainsi sur 127.0.0.1 ou tshark capte deja.
# 127.0.0.2 et non .1 : c'est deja l'adresse que le bloc de patch plus bas
# impose aux MEMES services (gtp local-ip, gsup remote-ip, listen 23000, HLR
# remote-ip). Tant que __CONTAINER_IP__ valait 127.0.0.1, la substitution du
# gabarit et le patch qui la suit divergeaient - le GGSN pouvait annoncer une
# adresse et ecouter sur l'autre. C'est aussi ce qui remplace les 172.20.1.x
# d'avant : une adresse de boucle locale existe toujours, une adresse de NIC
# peut manquer au moment ou le service demarre.
HOST_IP="127.0.0.2"        # ip1 : __CONTAINER_IP__ - ggsn/sgsn/upf/bsc-nsvc
GATEWAY_IP="127.0.0.1"     # gw  : __GATEWAY_IP__  - log gsmtap + dns 0 du ggsn

# ── Le segment prive de ce noeud : 192.168.<noeud+1>.x ──────────────────────
# Meme plan que le cote docker (start.sh : op_private_*), pour qu'une VM et un
# conteneur du meme rang se decrivent pareil. Le +1 laisse 192.168.1.0/24 au
# LAN du banc - un noeud qui s'y poserait entrerait en collision avec les VM et
# le hub SS7.
#
# Ces adresses REMPLACENT les 172.20.x heritees du plan docker. Elles ne
# revendiquent rien (/32) : le but n'est pas de creer un segment - une VM n'a
# pas de BTS derriere une carte - mais de donner un point d'attache stable aux
# configurations qui nomment encore une adresse privee.
ISO_PRIV_BASE=$(( ${ISO_NODE:-1} + 1 ))
ISO_PRIV_GW="192.168.${ISO_PRIV_BASE}.1"
ISO_PRIV_IP="192.168.${ISO_PRIV_BASE}.10"

ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
PHY_MODE="${PHY_MODE:-faketrx}"
# __INTER_STP_IP__ : ASP vers le STP d'un autre operateur. Inerte ici - l'ISO
# n'a qu'un operateur et passe inter_stp_shutdown=shutdown a apply_config_
# templates - mais on ne laisse pas une IP docker morte dans les configs.
INTER_STP_IP="127.0.0.1"   # ip2 : inter-operateur (ASP shutdown sur l'ISO)

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  Inter-STP  : ${CYAN}${INTER_STP_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"
echo -e "  PHY        : ${CYAN}${PHY_MODE}${NC}"

TEMP_CONFIG="$(mktemp -d)"

# ── Point codes et rattachement SS7 ──────────────────────────────────────────
# Hors WAN : le plan historique, 1.<op>.<role>, et l'ASP inter-STP coupe -
# l'ISO n'a qu'un operateur, il n'a personne a qui parler en SS7.
#
# Avec --node N : le noeud entre DANS le point code, 1.<noeud><op>.<role>.
# Sans ca, trois ISO attachees au meme hub y presenteraient trois fois 1.11.2.
# Un point code est une adresse : deux equipements avec la meme, ce n'est pas
# un conflit de nom, c'est du routage faux - et silencieux.
ISO_PC_MSC="1.1.1"; ISO_PC_STP="1.1.2"; ISO_PC_BSC="1.1.3"
ISO_INTER_SHUT="shutdown"
ISO_INTER_IP="$INTER_STP_IP"
if [ -n "$ISO_NODE" ]; then
    ISO_PC_MSC="1.${ISO_NODE}${ISO_OP_ID}.1"
    ISO_PC_STP="1.${ISO_NODE}${ISO_OP_ID}.2"
    ISO_PC_BSC="1.${ISO_NODE}${ISO_OP_ID}.3"
    ISO_INTER_IP="$ISO_HUB_IP"
    ISO_INTER_SHUT="no shutdown"
    # RCTX unique lui aussi : le hub identifie chaque AS par son routing context.
    export RCTX_INTER_OVERRIDE=$(( ISO_NODE * 1000 + ISO_OP_ID * 100 + 50 ))
    # local-ip de l'ASP laissee a 0.0.0.0 : l'adresse du noeud vient du DHCP et
    # n'est pas forcement montee quand osmo-stp demarre. Se lier a une adresse
    # absente echoue au lancement, sans rapport visible avec le reseau.
    export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
    echo -e "  Noeud WAN  : ${CYAN}${ISO_NODE}${NC}  PC ${CYAN}${ISO_PC_STP}${NC}  hub ${CYAN}${ISO_HUB_IP}${NC}  rctx ${RCTX_INTER_OVERRIDE}"
fi

apply_config_templates "$TEMP_CONFIG" \
    "$HOST_IP" "$GATEWAY_IP" \
    "1" "$ISO_PC_MSC" "$ISO_PC_STP" "$ISO_PC_BSC" \
    "001" "01" "OsmoGSM" \
    "$ISO_INTER_IP" "$ISO_INTER_SHUT" "1"

# ── Role inter-STP : la config du hub, pour N noeuds ────────────────────────
if [ "$ISO_ROLE" = "interstp" ]; then
    _hub_nodes=3
    if [ -n "$ISO_WAN_NODES" ]; then
        _hub_nodes=$(printf '%s' "${ISO_WAN_NODES//,/ }" | wc -w)
    fi
    bash "$DIR/helpers/create_interop.sh" --wan "$_hub_nodes" "${ISO_WAN_OPS:-1}" \
        "$TEMP_CONFIG/osmocom/osmo-stp-interop.cfg" || exit 1
    echo -e "  ${GREEN}✓${NC} hub SS7 pour ${CYAN}${_hub_nodes}${NC} noeud(s) × ${ISO_WAN_OPS:-1} operateur(s)"
fi

# ── Les retouches NATIVES ────────────────────────────────────────────────────
# APRES apply_config_templates, et non avant : celui-ci ecrase systematiquement
# sms-routing.conf, osmo-sgsn.cfg et osmo-msc.cfg avec ce que disent les
# gabarits - c'est-a-dire le plan DOCKER.
#
# Cette recette vivait ICI, en deux morceaux (le sms-routing juste apres la
# substitution, les sed du SGSN et du MSC trois cents lignes plus bas), et
# NULLE PART ailleurs. Une ISO en sortait juste ; une machine qui regenerait
# ses configs ensuite - ./start-direct.sh --regen - en sortait fausse, sans
# qu'un seul message ne le dise. Elle est desormais dans generate_configs.sh,
# une fois, et les deux chemins l'appellent (voir apply_native_post_patches).
# La table WAN telle que cette ISO l'embarquera : c'est elle qui donne a
# sms-routing.conf l'adresse de CHAQUE noeud. Sans elle (ISO d'un banc isole),
# le generateur n'ecrit que notre propre entree.
ISO_WAN_TMP=""
if [ -n "$ISO_WAN_NODES" ]; then
    ISO_WAN_TMP="$(mktemp)"
    printf 'WAN_NODES="%s"\n' "$ISO_WAN_NODES" > "$ISO_WAN_TMP"
fi
apply_native_post_patches "$TEMP_CONFIG" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}"
echo -e "  ${GREEN}✓${NC} retouches natives : sms-routing (${CYAN}${ISO_N_MS}${NC} route(s) MS), SGSN, MSC vers ${CYAN}${HOST_IP}${NC}"

if [ "$ISO_ROLE" = "interstp" ]; then
    ISO_RUN_IMAGE="osmocom-stp-iso"
    ISO_SRC_IMAGE="osmocom-stp"
elif [ "$ISO_LITE" = "1" ]; then
    # Meme chaine, meme configs : seule la SOURCE change. Tout ce qui suit -
    # docker cp des binaires, des libs, de /opt/GSM - travaille donc sur l'image
    # elaguee sans avoir a le savoir.
    ISO_RUN_IMAGE="osmocom-run-lite-iso"
    ISO_SRC_IMAGE="osmocom-run:lite"
else
    ISO_RUN_IMAGE="osmocom-run-iso-net-host"
    ISO_SRC_IMAGE="osmocom-run"
fi
TMP_CID="$(docker create "$ISO_SRC_IMAGE" /bin/sh)"

# Le hub ne porte AUCUN operateur : lui pousser le jeu complet, c'est embarquer
# un osmo-stp.cfg de point-code 1.1.2 avec local-ip 172.20.0.11 a cote du
# osmo-stp-interop.cfg qui, lui, fait autorite. Deux configurations STP dans le
# meme /etc/osmocom, l'une morte mais plausible : on relance la mauvaise, le hub
# se presente au WAN avec le point-code d'un operateur, et le routage M3UA part
# sur une adresse du plan docker que la VM n'a jamais eue.
# On ne copie donc que la config du hub - et pas par lien symbolique : le pgrep
# de start-interstp.sh discrimine sur le NOM du fichier de conf passe a osmo-stp.
# On retire donc la config STP d'operateur - et elle seule. Ne pousser que
# osmo-stp-interop.cfg privait aussi le hub de run.sh, status.sh, check.sh et
# entrypoint.sh, que /etc/osmocom est le seul a fournir (l'image osmocom-stp
# part d'ubuntu:22.04 nu) : le chmod de l'etape 5 s'arretait alors sur un
# fichier absent et la construction du hub - donc ./build-iso.sh sans
# argument, qui commence par lui - echouait apres une heure de travail.
if [ "$ISO_ROLE" = "interstp" ]; then
    rm -f "$TEMP_CONFIG/osmocom/osmo-stp.cfg"
fi
docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
# Le hub n'a pas d'Asterisk : lui pousser des configs SIP n'aurait pas de sens,
# et l'image n'a meme pas /etc/asterisk.
[ "$ISO_ROLE" = "interstp" ] || \
    docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prete"

# ── Etape 3 : (SUPPRIME) - ISO NATIF : on n'embarque PAS l'image Docker ────
# L'image osmocom-run ne sert plus que de SOURCE de build (docker cp des binaires
# et configs vers le rootfs a l'etape 6). On ne la save plus dans l'ISO : pas de
# docker au runtime, pas de tar.gz de plusieurs Go embarque.

# ── Etape 4 : Bootstrap rootfs minimal ─────────────────────────────────────
# ── Cache des .deb (accelere les rebuilds) ─────────────────────────────────
# ISO_DEB_CACHE=<dir absolu> : cache PERSISTANT que debootstrap reutilise
# (--cache-dir) au lieu de re-telecharger la base a chaque build (les lignes
# "I: Retrieving / I: Validating"). Vide ou --no-cache -> pas de cache.
ISO_DEB_CACHE="${ISO_DEB_CACHE:-$HOME/.cache/osmo-iso-debs}"
DEBOOTSTRAP_CACHE_OPT=""
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    mkdir -p "$ISO_DEB_CACHE/debootstrap"
    DEBOOTSTRAP_CACHE_OPT="--cache-dir=$ISO_DEB_CACHE/debootstrap"
    echo -e "  ${GREEN}cache .deb debootstrap : $ISO_DEB_CACHE/debootstrap${NC}"
fi
echo -e "${GREEN}[4/9] debootstrap jammy (minimal)...${NC}"
debootstrap $DEBOOTSTRAP_CACHE_OPT --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
    jammy "$ROOTFS" http://archive.ubuntu.com/ubuntu
echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"

# ── Etape 5 : Injection des binaires et libs depuis l'image osmocom-run ───
echo -e "${GREEN}[5/9] Injection stack Osmocom...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
docker cp "$CID:/usr/local/bin/." "$ROOTFS/usr/local/bin/"  2>/dev/null||true
docker cp "$CID:/usr/local/lib/." "$ROOTFS/usr/local/lib/"  2>/dev/null||true
docker cp "$CID:/usr/local/include/." "$ROOTFS/usr/local/include/" 2>/dev/null||true
docker cp "$CID:/opt/GSM"             "$ROOTFS/opt/GSM"     2>/dev/null||true
# venv python (gr-gsm + bridges) attendu par /opt/GSM/qemu-src/start-clean.sh
docker cp "$CID:/root/.env"           "$ROOTFS/root/"       2>/dev/null||true
docker cp "$CID:/etc/osmocom/."       "$ROOTFS/etc/osmocom/" 2>/dev/null||true
docker cp "$CID:/etc/asterisk/."      "$ROOTFS/etc/asterisk/" 2>/dev/null||true
for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
    docker cp "$CID:/lib/systemd/system/${svc}.service" "$ROOTFS/lib/systemd/system/" 2>/dev/null||true
done
docker rm "$CID" &>/dev/null
echo -e "  ${GREEN}✓${NC} binaires + libs + configs injectes"

# ── osmo_egprs : ARBRE a jour depuis GitHub, AVEC son .git ─────────────────
# La copie docker cp ci-dessus peut etre perimee ; on avance la branche main du
# depot (start-direct.sh, run.sh, scripts/, configs/, build-iso.sh...) dans l'ISO.
EGPRS_BRANCH="${OSMO_EGPRS_BRANCH:-main}"
EGPRS_REPO="${OSMO_EGPRS_REPO:-https://github.com/bbaranoff/osmo_egprs}"
echo -e "${GREEN}[5a/9] Mise a jour osmo_egprs en place (branche ${EGPRS_BRANCH}, .git conserve)...${NC}"
# [2026-08-27] Le tarball est abandonne. Il donnait un arbre NU : on effacait
# /opt/GSM/osmo_egprs, on deballait le tar.gz, on supprimait les .git*. Trois
# consequences, toutes vues sur l'ISO :
#   - sans .git, update.sh n'a pas le choix au demarrage : il ne peut pas faire
#     "git fetch", il EFFACE et RECLONE (wipe=1) - a chaque boot, et sans reseau
#     il ne reste rien ;
#   - tout ce qui avait ete pose dans l'arbre a la construction disparaissait au
#     premier demarrage ;
#   - impossible, sur la machine, de savoir sur quel commit on tourne.
# On met donc l'arbre a jour EN PLACE, par git, en gardant .git. Le depot vient
# de l'image ($CID:/opt/GSM, il a son .git) ; on ne le remplace pas, on avance
# le HEAD - et seulement si c'est une avance directe (--ff-only) : un arbre de
# l'image avec des commits locaux n'est pas ecrase en silence, il est signale.
EGPRS_TREE="$ROOTFS/opt/GSM/osmo_egprs"
if [ -d "$EGPRS_TREE/.git" ]; then
    if git -C "$EGPRS_TREE" fetch --depth 1 origin "$EGPRS_BRANCH" >/dev/null 2>&1 \
       && git -C "$EGPRS_TREE" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} osmo_egprs a jour en place (${EGPRS_BRANCH}, .git conserve) - $(git -C "$EGPRS_TREE" log -1 --format='%h %s')"
    else
        echo -e "  ${YELLOW}⚠${NC} osmo_egprs : mise a jour impossible (reseau ? commits locaux ?) - arbre de l'image conserve" >&2
    fi
elif [ -d "$EGPRS_TREE" ]; then
    # Arbre sans depot : on ne l'efface pas, on lui rend son .git, sur place.
    if git -C "$EGPRS_TREE" init -q 2>/dev/null \
       && git -C "$EGPRS_TREE" remote add origin "$EGPRS_REPO" 2>/dev/null \
       && git -C "$EGPRS_TREE" fetch --depth 1 origin "$EGPRS_BRANCH" >/dev/null 2>&1 \
       && git -C "$EGPRS_TREE" checkout -q -B "$EGPRS_BRANCH" FETCH_HEAD 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} osmo_egprs : depot reconstitue sur l'arbre existant (${EGPRS_BRANCH})"
    else
        echo -e "  ${YELLOW}⚠${NC} osmo_egprs : depot non reconstitue - arbre de l'image conserve tel quel" >&2
    fi
else
    mkdir -p "$ROOTFS/opt/GSM"
    if git clone --depth 1 -b "$EGPRS_BRANCH" "$EGPRS_REPO" "$EGPRS_TREE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} osmo_egprs clone (${EGPRS_BRANCH}, .git conserve)"
    else
        echo -e "  ${RED}✗${NC} osmo_egprs absent de l'image ET clone impossible" >&2
    fi
fi

# ── Feed HLR : aligner N_MS sur le nombre de MS embarques ────────────────────
# run_modules/21-abonnes-hlr.sh retombe sur ": "${N_MS:=1}"" : sans ce fichier
# un SEUL abonne etait provisionne alors que l'ISO en declare ISO_N_MS, et les
# MS suivants se voyaient refuser le rattachement ("IMSI unknown in HLR") -
# panne lue a tort comme un defaut radio.
#
# PAS dans /opt/GSM/osmo_egprs/environment : ce fichier n'est pas dans git. Il y
# a survecu au demarrage tant que personne ne mettait le depot a jour, et pas une
# minute de plus - a l'epoque osmo-update.service effacait et reclonait l'arbre
# a chaque boot (wipe=1), aujourd'hui "osmo-update" fait un git fetch, dont le
# reset --hard emporte de la meme facon ce qui n'est pas suivi. N_MS retombait
# a 1, MS#2 restait inconnu du HLR, et start-direct.sh le lancait quand meme.
# /opt/GSM/qemu-src/environment, lui, n'a jamais existe : ce depot-la nomme son
# repertoire "environnement".
# /etc/osmocom n'appartient a aucun depot : ce qui y est ecrit reste.
mkdir -p "$ROOTFS/etc/osmocom"
cat > "$ROOTFS/etc/osmocom/coeur.env" <<COEUR
# coeur.env - genere par build-iso.sh. Aligne le nombre d'abonnes provisionnes
# dans le HLR sur le nombre de MS embarques par l'ISO (ISO_N_MS).
: "\${N_MS:=$ISO_N_MS}"
: "\${OPERATOR_ID:=1}"
COEUR
echo -e "  ${GREEN}✓${NC} coeur.env : ${CYAN}N_MS=${ISO_N_MS}${NC} (/etc/osmocom)"


# ── qemu-src : arbre ELAGUE + binaire installe ──────────────────────────────
# Deux choses distinctes, et l'ISO a besoin des DEUX :
#   - l'arbre qemu-src (run.sh, run_modules/, environnement/) :
#     c'est LUI le mode qemu de start-direct.sh. Il reste dans l'image, prive de
#     .git et de build/ (voir plus bas).
#   - le binaire qemu-system-arm, installe dans /usr/local/bin, et relie depuis
#     l'arbre sous le nom que paths.env cherche (build/qemu-system-arm).
QEMU_BUILD_LOCAL="${OSMO_QEMU_BUILD:-${OSMO_QEMU_SRC:-/opt/GSM/qemu-src}/build}"
echo -e "${GREEN}[5b/9] Installation QEMU (artefacts seuls, depuis ${QEMU_BUILD_LOCAL})...${NC}"
# L'elagage est HORS de la condition, et l'absence du binaire est FATALE. Avant,
# les deux etaient dans la branche "binaire present" : sur une machine ou QEMU
# n'avait pas ete recompile - le cas courant - on tombait dans le repli, qui se
# contentait d'un avertissement jaune, et l'arbre venu du docker cp
# ($CID:/opt/GSM) partait tel quel dans le squashfs, build/ compris : 1,7 Go
# dans une ISO qui tient en RAM. Le message passait inapercu au milieu d'une
# heure de construction, et la taille de l'ISO etait le seul indice.
# Echouer ici coute une relance ; ne pas echouer coute une ISO inutilisable
# (sans qemu-system-arm, MS#1 ne demarre pas) et deux fois plus lourde.
# ── qemu-src : l'arbre part ENTIER, .git et build/ compris ─────────────────
# [2026-08-27] L'effacement pur ("rm -rf $ROOTFS/opt/GSM/qemu-src") reglait le
# poids, mais retirait de l'image le depot dont run.sh, run_modules/ et
# environnement/ SONT le mode qemu : l'ISO ne savait plus emuler le Calypso par
# elle-meme et dependait, a CHAQUE demarrage, d'un reclone GitHub par
# osmo-update.service. Pas de reseau au boot = pas de MS. Et l'arbre reclone
# arrivait sans build/, donc sans QEMU_BIN : la pile s'arretait au premier
# module alors que le binaire etait la, dans le PATH.
#
# On ne retire donc plus RIEN de cet arbre :
#   - .git (96 Mo) : c'est lui qui fait la difference entre une mise a jour
#     incrementale (git fetch) et un reclone complet. Sans .git, update.sh
#     n'avait pas le choix : il effacait et reclonait a chaque demarrage.
#   - build/ (1,5 Go d'objets) : il porte le qemu-system-arm COMPILE, celui que
#     environnement/paths.env cherche sous $QEMU_TREE/build/qemu-system-arm.
#     L'arbre embarque est donc utilisable tel quel, sans reseau et sans lien.
#
# Ce que ca coute : ~1,6 Go de plus dans le squashfs (moins une fois compresse).
# A surveiller si l'ISO doit tenir en RAM (toram).
QSRC="$ROOTFS/opt/GSM/qemu-src"
if [ -d "$QSRC" ]; then
    echo -e "  ${GREEN}✓${NC} qemu-src conserve ENTIER ($(du -sh "$QSRC" | cut -f1), .git + build/ compris)"
else
    # L'image ne l'avait pas : on prend l'arbre de l'hote, entier lui aussi.
    QSRC_HOST="${OSMO_QEMU_SRC:-/opt/GSM/qemu-src}"
    if [ -d "$QSRC_HOST" ]; then
        mkdir -p "$ROOTFS/opt/GSM"
        cp -a "$QSRC_HOST" "$QSRC"
        echo -e "  ${GREEN}✓${NC} qemu-src repris de l'hote ${CYAN}${QSRC_HOST}${NC} ($(du -sh "$QSRC" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} qemu-src introuvable (ni image, ni hote) - l'ISO n'aura pas le mode qemu" >&2
    fi
fi

# ── Firmware Calypso : /opt/GSM/firmware, et rien d'autre ───────────────────
# [2026-08-28] Il y avait ici un bloc qui remplacait $QSRC/target/firmware par
# un lien vers /opt/GSM/firmware. Il reparait une coquille vide laissee dans
# l'arbre qemu-src, sur laquelle la premiere branche de
# environnement/paths.env tombait, d'ou :
#
#   [FAIL] FIRMWARE_ELF (/opt/GSM/qemu-src/target/firmware/board/compal_e88/layer1.highram.elf)
#
# La cause a ete traitee a sa source : paths.env (et local.env) du depot qemu
# ne connaissent plus qu'un seul chemin, $GSM_ROOT/firmware. Il n'y a donc plus
# de coquille a reparer, et poser le lien reintroduirait justement le deuxieme
# arbre qu'on vient de supprimer. Constate sur le banc 192.168.1.7 : ce lien
# n'existait meme pas sur l'ISO gravee, et le run chargeait deja
# /opt/GSM/firmware/board/compal_e88/layer1.highram.elf sans lui.
#
# Reste ce qui a de la valeur : verifier que le firmware EST dans le rootfs.
# Sans lui, l'ISO demarre et le MS ne part pas.
FW_ELF="board/compal_e88/layer1.highram.elf"
if [ -e "$ROOTFS/opt/GSM/firmware/$FW_ELF" ]; then
    echo -e "  ${GREEN}✓${NC} firmware : ${CYAN}/opt/GSM/firmware/${FW_ELF}${NC} (source unique ; FIRMWARE_ELF resolu)"
else
    echo -e "  ${YELLOW}!${NC} /opt/GSM/firmware/${FW_ELF} absent du rootfs - FIRMWARE_ELF restera non resolu" >&2
fi

# ── Datadir QEMU : le lien que reclame la RELOCALISATION ────────────────────
# [2026-08-28] Diagnostique en direct sur un banc lite (192.168.1.7), ou la
# sequence mourait sur :
#
#   [FAIL] Emulator serial PTY (QEMU (pid ...) s'est arrete avant d'allouer son PTY)
#   qemu-system-arm: could not read keymap file: 'en-us'
#
# Le bloc "Keymaps QEMU" plus bas copie bien les keymaps - dans
# /usr/local/share/qemu/keymaps. Or QEMU ne les y cherche JAMAIS, et le fichier
# etait present en trois exemplaires sur la machine pendant que QEMU jurait ne
# pas le trouver.
#
# La raison tient a get_relocated_path() : QEMU ne prend PAS son
# CONFIG_QEMU_FIRMWAREPATH tel quel. Il en deduit un chemin RELATIF a son
# bindir de compilation, puis l'applique au repertoire ou le binaire se trouve
# REELLEMENT. Ici :
#
#   compile avec   prefix=/opt/GSM/qemu-install   (donc bin/ et share/qemu/ y sont)
#   execute depuis /opt/GSM/qemu-src/build/qemu-system-arm   (run.sh -> QEMU_BIN)
#   QEMU cherche   /opt/GSM/qemu-src/share/qemu   <- n'existait pas
#
# Le prefix compile n'est alors plus jamais consulte. Mesure faite sur le banc,
# meme binaire, meme machine :
#
#   sans lien : "could not read keymap file: 'en-us'"   rc=1  (QEMU meurt)
#   avec lien : aucune erreur                           rc=124 (tue par timeout,
#                                                        donc il tournait)
#
# Le lien <exec_dir>/../share/qemu est le SEUL qui repare : l'autre candidat de
# QEMU, <exec_dir>/pc-bios, a ete teste sur le banc et laisse l'erreur intacte.
QINST="$ROOTFS/opt/GSM/qemu-install/share/qemu"
if [ -d "$QSRC" ] && [ -d "$QINST/keymaps" ]; then
    if [ -e "$QSRC/share/qemu/keymaps/en-us" ]; then
        echo -e "  ${GREEN}✓${NC} datadir QEMU : ${CYAN}/opt/GSM/qemu-src/share/qemu${NC} deja resolu"
    else
        mkdir -p "$QSRC/share"
        rm -rf "$QSRC/share/qemu"
        ln -sfn /opt/GSM/qemu-install/share/qemu "$QSRC/share/qemu"
        echo -e "  ${GREEN}✓${NC} datadir QEMU : ${CYAN}/opt/GSM/qemu-src/share/qemu${NC} -> /opt/GSM/qemu-install/share/qemu (keymap 'en-us' resolu)"
    fi
elif [ -d "$QSRC" ] && [ "$ISO_ROLE" != "interstp" ]; then
    echo -e "  ${YELLOW}!${NC} /opt/GSM/qemu-install/share/qemu/keymaps absent - QEMU mourra sur 'could not read keymap file'" >&2
fi

# Le binaire vient peut-etre DEJA de l'image : "docker cp $CID:/usr/local/bin/."
# (plus haut) copie /usr/local/bin/qemu-system-arm dans le rootfs, et c'est
# exactement celui que le conteneur utilise pour emuler le Calypso. Exiger en
# plus un build sur l'HOTE faisait echouer la construction sur une machine ou
# QEMU n'a jamais ete recompile - le cas courant - alors que l'ISO aurait ete
# parfaitement utilisable. On ne garde le caractere fatal que pour le vrai
# probleme : aucun binaire, ni sur l'hote, ni dans l'image.
#
# Le pc-bios n'est pas necessaire ici : dans l'image, ni /usr/local/share/qemu
# ni /usr/local/share/qemu-firmware n'existent, et la machine Calypso demarre
# sans fichier de firmware QEMU (elle charge sa propre ROM). Les recopier
# couterait 303 Mo dans une ISO qui tient en RAM.
ROOTFS_QEMU="$ROOTFS/usr/local/bin/qemu-system-arm"
if [ ! -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ] \
   && [ ! -x "$ROOTFS_QEMU" ] && [ "$ISO_ROLE" != "interstp" ]; then
    echo -e "${RED}${BOLD}[5b/9] qemu-system-arm introuvable${NC}" >&2
    echo -e "  ${YELLOW}Ni build local : ${QEMU_BUILD_LOCAL}/qemu-system-arm${NC}" >&2
    echo -e "  ${YELLOW}Ni binaire venu de l'image : ${ROOTFS_QEMU}${NC}" >&2
    echo -e "  ${YELLOW}L'image d'operateur emule le Calypso : sans ce binaire elle n'a pas de MS.${NC}" >&2
    echo -e "  ${YELLOW}Trois issues : compiler qemu-src, pointer OSMO_QEMU_BUILD sur un build${NC}" >&2
    echo -e "  ${YELLOW}existant, ou reconstruire l'image docker qui, elle, porte le binaire.${NC}" >&2
    exit 1
fi
if [ ! -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ] && [ -x "$ROOTFS_QEMU" ]; then
    strip --strip-unneeded "$ROOTFS_QEMU" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} qemu-system-arm repris de l'image ($(du -h "$ROOTFS_QEMU" | cut -f1)), pas de build hote necessaire"
elif [ -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ]; then
    qpfx="$(sed -n 's/^prefix=//p' "$QEMU_BUILD_LOCAL/config-host.mak" 2>/dev/null)"
    qpfx="${qpfx:-/usr/local}"

    if DESTDIR="$ROOTFS" ninja -C "$QEMU_BUILD_LOCAL" install >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} qemu installe dans ${ROOTFS}${qpfx} (ninja install, pas de sources)"
    else
        # repli : binaire + firmwares/keymaps strictement necessaires
        install -Dm755 "$QEMU_BUILD_LOCAL/qemu-system-arm" "$ROOTFS$qpfx/bin/qemu-system-arm"
        install -d "$ROOTFS$qpfx/share/qemu"
        cp -a "$QEMU_BUILD_LOCAL/pc-bios/." "$ROOTFS$qpfx/share/qemu/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} qemu-system-arm + pc-bios copies dans ${ROOTFS}${qpfx} (repli manuel)"
    fi
    strip --strip-unneeded "$ROOTFS$qpfx/bin/qemu-system-arm" 2>/dev/null || true
else
    # Seul le hub arrive ici : il ne fait que router du M3UA, il n'a pas de MS a
    # emuler. Pour l'operateur, le test ci-dessus a deja arrete la construction.
    echo -e "  ${CYAN}Role inter-STP : pas de QEMU (aucun MS a emuler)${NC}"
fi
# ── QEMU_BIN dans l'arbre : le lien, SEULEMENT si le binaire n'y est pas ───
# environnement/paths.env du depot qemu resout QEMU_BIN a
# $QEMU_TREE/build/qemu-system-arm. L'arbre embarque le porte deja (build/ part
# entier) : dans ce cas on ne touche a RIEN - un "ln -sf" par-dessus remplacerait
# le binaire compile par un lien, c'est-a-dire l'effacerait.
# Le lien ne sert qu'au cas contraire (arbre venu d'ailleurs, build/ absent) :
# sans lui, run.sh s'arrete des le premier module -
#     [FAIL] Prerequisite checks (dépendances introuvables : QEMU_BIN)
# - alors que le binaire est la, dans /usr/local/bin.
# osmo-qemu-link.service (etape [6/9]) applique la meme regle a chaque demarrage.
if [ -d "$QSRC" ] && [ ! -e "$QSRC/build/qemu-system-arm" ]; then
    qbin=""
    for c in "$ROOTFS/usr/local/bin/qemu-system-arm" \
             "$ROOTFS${qpfx:-/usr/local}/bin/qemu-system-arm"; do
        [ -x "$c" ] && { qbin="${c#$ROOTFS}"; break; }
    done
    if [ -n "$qbin" ]; then
        mkdir -p "$QSRC/build"
        ln -sfn "$qbin" "$QSRC/build/qemu-system-arm"
        echo -e "  ${GREEN}✓${NC} QEMU_BIN : ${CYAN}/opt/GSM/qemu-src/build/qemu-system-arm${NC} -> ${CYAN}${qbin}${NC}"
    elif [ "$ISO_ROLE" != "interstp" ]; then
        echo -e "  ${YELLOW}!${NC} binaire QEMU introuvable dans le rootfs - QEMU_BIN restera non resolu" >&2
    fi
elif [ -e "$QSRC/build/qemu-system-arm" ]; then
    echo -e "  ${GREEN}✓${NC} QEMU_BIN : ${CYAN}/opt/GSM/qemu-src/build/qemu-system-arm${NC} (binaire compile de l'arbre)"
fi

# ── Keymaps QEMU : 917 ko qui decident si la machine demarre ────────────────
# [2026-08-27] Le commentaire du bloc d'installation ci-dessus dit vrai pour le
# pc-bios - 303 Mo
# de ROMs (bios.bin, edk2, efi-*.rom) que la machine Calypso n'ouvre jamais,
# elle charge la sienne. Il est FAUX pour les keymaps, qui ne sont pas du
# firmware : l'interface graphique les lit a l'initialisation, machine Calypso
# comprise. Sans $prefix/share/qemu/keymaps, qemu-system-arm ecrit
#     qemu-system-arm: could not read keymap file: 'en-us'
# et s'arrete AVANT le premier cycle. Vu de start-direct.sh, ca donne
#     [FAIL] Calypso emulator (QEMU) (started but never ready)
# c'est-a-dire une ISO sans MS - la panne exacte que le bloc precedent veut
# eviter. On copie donc les keymaps SEULES : 917 ko, pas 303 Mo.
if [ "$ISO_ROLE" != "interstp" ]; then
    if [ -d "$ROOTFS/usr/local/share/qemu/keymaps" ]; then
        echo -e "  ${GREEN}✓${NC} keymaps QEMU deja en place (${CYAN}/usr/local/share/qemu/keymaps${NC})"
    else
        qkm=""
        for c in "$QEMU_BUILD_LOCAL/pc-bios/keymaps" \
                 "$QSRC/pc-bios/keymaps" \
                 "$ROOTFS/opt/GSM/qemu-install/share/qemu/keymaps" \
                 "$ROOTFS/usr/share/qemu/keymaps" \
                 /usr/local/share/qemu/keymaps \
                 /usr/share/qemu/keymaps; do
            [ -d "$c" ] && { qkm="$c"; break; }
        done
        if [ -n "$qkm" ]; then
            mkdir -p "$ROOTFS/usr/local/share/qemu"
            cp -a "$qkm" "$ROOTFS/usr/local/share/qemu/"
            echo -e "  ${GREEN}✓${NC} keymaps QEMU ($(du -sh "$ROOTFS/usr/local/share/qemu/keymaps" | cut -f1)) copiees depuis ${CYAN}${qkm}${NC}"
        else
            # Pas fatal : le binaire peut avoir ete configure avec un autre
            # prefixe, ou une version future ne plus les lire. Mais c'est la
            # premiere chose a regarder si QEMU "demarre puis s'arrete".
            echo -e "  ${YELLOW}!${NC} keymaps QEMU introuvables - si QEMU s'arrete au demarrage," >&2
            echo -e "  ${YELLOW}  cherchez \"could not read keymap file\" dans logs/qemu.log${NC}" >&2
        fi
    fi
fi

echo -e "${GREEN}[5c/9] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5d/9] Patch configs ISO...${NC}"

# LA MEME recette que sur $TEMP_CONFIG, rejouee sur le rootfs. Elle est
# idempotente : ce qui est deja juste ne bouge pas. On la rejoue quand meme
# parce que /etc/osmocom du rootfs vient de l'IMAGE docker (docker cp a
# l'etape 5), pas de $TEMP_CONFIG - l'image peut porter des fichiers que la
# substitution n'a pas traverses.
apply_native_post_patches "$ROOTFS/etc" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}"

if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
else
    # Garde-fou : sous set -e, un run.sh absent tuait la construction tout au
    # bout de l'etape 5. Le fichier vient de l'image, pas du depot : s'il
    # manque, c'est l'image qu'il faut regarder, pas une heure de build qu'il
    # faut perdre.
    echo -e "  ${YELLOW}!${NC} /etc/osmocom/run.sh absent de l'image ${CYAN}${ISO_SRC_IMAGE}${NC}"
fi

echo -e "  ${GREEN}✓${NC} retouches natives rejouees sur le rootfs (SGSN, MSC, sms-routing, run.sh)"
mkdir -p "$ROOTFS/usr/bin"
cp -a "$ROOTFS/usr/local/bin/." "$ROOTFS/usr/bin/" 2>/dev/null || true

mkdir -p "$ROOTFS/root/.osmocom/bb"
if [ -f "$ROOTFS/opt/GSM/osmo_egprs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/GSM/osmo_egprs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/opt/GSM/osmo_egprs/configs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/GSM/osmo_egprs/configs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/etc/osmocom/mobile.cfg" ]; then
    cp "$ROOTFS/etc/osmocom/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
fi

# ── PAS D'UTILISATEUR osmocom : ROOT, ET RIEN D'AUTRE ───────────────────────
# L'image portait un compte "osmocom" force a l'UID 0 (usermod -o -u 0). Un
# compte qui EST root sans le dire coute plus qu'il ne rapporte :
#   - GDM refuse toute session pour l'uid 0, il fallait donc neutraliser la
#     regle PAM "user != root" pour qu'un autologin sur ce compte aboutisse ;
#   - deux noms pour le meme uid donnent deux HOME (/home/osmocom et /root) et
#     donc deux .osmocom/bb : les mobiles ecrits dans l'un, lus dans l'autre ;
#   - "ls -l" affiche tantot root tantot osmocom pour un meme proprietaire,
#     selon l'ordre de /etc/passwd - de quoi chercher longtemps un probleme de
#     droits qui n'existe pas.
# Cette image tourne en root, assume : on SUPPRIME le compte et on rend les
# unites systemd a root. Les .service viennent des paquets Osmocom amont, qui
# posent "User=osmocom / Group=osmocom" ; sans compte, ils echouent au
# demarrage sur "Failed to determine user credentials" - un demon qui ne part
# pas, et rien dans son propre journal pour le dire.
sed -i -e 's/^User=osmocom$/User=root/' -e 's/^Group=osmocom$/Group=root/' \
       "$ROOTFS/lib/systemd/system"/osmo-*.service \
       "$ROOTFS/etc/systemd/system"/osmo-*.service 2>/dev/null || true

chroot "$ROOTFS" userdel -r osmocom 2>/dev/null || true
chroot "$ROOTFS" groupdel osmocom  2>/dev/null || true
rm -rf "$ROOTFS/home/osmocom"
# /var/lib/osmocom (bases HLR, etats GTP) et /var/log/osmocom appartenaient au
# compte supprime : sans ce chown ils gardent un UID orphelin, et l'ecriture
# echoue des le premier demarrage ("Unable to create file").
chown -R 0:0 "$ROOTFS/root/.osmocom" "$ROOTFS/var/lib/osmocom" \
             "$ROOTFS/var/log/osmocom" 2>/dev/null || true

echo -e "  ${GREEN}✓${NC} compte osmocom supprime (tout tourne en root) + /usr/bin + mobile.cfg prets"

chmod +x "$ROOTFS/etc/osmocom/run.sh"

# ── Etape 6 : Injection du dashboard web ───────────────────────────────────
echo -e "${GREEN}[6/9] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/GSM/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
# main, PAS "test". La branche de travail du depot web partait dans toutes les
# ISO : une image gravee recevait ce qui n'etait pas encore relu, et deux ISO
# construites a deux semaines d'ecart n'embarquaient pas le meme dashboard sans
# qu'aucune option ne l'ait demande. OSMO_WEB_BRANCH=test reste possible, mais
# il faut le vouloir.
WEB_BRANCH="${OSMO_WEB_BRANCH:-main}"

mkdir -p "$WEB/web"
# Source AUTORITAIRE = le VRAI git bbaranoff/osmo-egprs-web (clone ci-dessous).
# La copie locale /opt/GSM/osmo-egprs-web n'est plus utilisee que comme override
# EXPLICITE : OSMO_WEB_LOCAL=/chemin ./build-iso.sh. Sinon -> git.
# Le patch natif plus bas est idempotent (skip si server.js est deja en mode natif).
LOCAL_WEB="${OSMO_WEB_LOCAL:-}"
if [ -n "$LOCAL_WEB" ] && [ -f "$LOCAL_WEB/server.js" ]; then
    cp "$LOCAL_WEB/server.js" "$WEB/server.js"
    [ -f "$LOCAL_WEB/package.json" ] && cp "$LOCAL_WEB/package.json" "$WEB/package.json"
    [ -d "$LOCAL_WEB/web" ]          && cp -r "$LOCAL_WEB/web/."     "$WEB/web/"
    [ -f "$LOCAL_WEB/start-web.sh" ] && cp "$LOCAL_WEB/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$LOCAL_WEB/Dockerfile" ]   && cp "$LOCAL_WEB/Dockerfile"   "$WEB/Dockerfile"
    # Le depot suit les fichiers : c'est lui qui evite le reclone au demarrage.
    [ -d "$LOCAL_WEB/.git" ]         && cp -a "$LOCAL_WEB/.git"     "$WEB/"
    echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis source LOCALE ($LOCAL_WEB)"
else
    WEB_TMP="$WORK/osmo-egprs-web"
    git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2 || true
    # [2026-08-27] Le clone entier part dans l'image, .git COMPRIS. Avant, on ne
    # prelevait que quelques fichiers : l'ISO recevait un dossier sans depot, et
    # update.sh, faute de .git, ne pouvait qu'EFFACER et RECLONER a chaque
    # demarrage (wipe=1) - sans reseau, plus de dashboard du tout.
    # cp -a : les fichiers deja poses par un override local ne sont pas effaces,
    # ils sont recouverts par ceux du depot.
    [ -d "$WEB_TMP/.git" ] && cp -a "$WEB_TMP/." "$WEB/"
    # Layout REEL du repo : server.js / package.json / web/ / start-web.sh a la
    # RACINE (fallback sous server/ pour un ancien layout).
    if   [ -f "$WEB_TMP/server.js" ];        then cp "$WEB_TMP/server.js"        "$WEB/server.js"
    elif [ -f "$WEB_TMP/server/server.js" ]; then cp "$WEB_TMP/server/server.js" "$WEB/server.js"; fi
    if   [ -f "$WEB_TMP/package.json" ];        then cp "$WEB_TMP/package.json"        "$WEB/package.json"
    elif [ -f "$WEB_TMP/server/package.json" ]; then cp "$WEB_TMP/server/package.json" "$WEB/package.json"; fi
    [ -d "$WEB_TMP/web" ]          && cp -r "$WEB_TMP/web/."     "$WEB/web/"
    [ -f "$WEB_TMP/start-web.sh" ] && cp "$WEB_TMP/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$WEB_TMP/Dockerfile" ]   && cp "$WEB_TMP/Dockerfile"   "$WEB/Dockerfile"
    if [ -f "$WEB/server.js" ]; then
        echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis le git ${CYAN}$WEB_REPO${NC} ($WEB_BRANCH)"
    else
        echo -e "  ${RED}✗ clone osmo-egprs-web sans server.js - dashboard incomplet${NC}"
    fi
fi

# Patch server.js : mode natif (no-docker). VTY en telnet direct sur 127.0.0.1
# (ou ip netns exec) au lieu de docker exec. Idempotent ; n'echoue pas le build.
if [ -f "$WEB/server.js" ] && command -v python3 >/dev/null 2>&1; then
python3 - "$WEB/server.js" <<'PYEOF' || echo -e "  ${YELLOW}[web] patch natif non applique (server.js amont a change ?)${NC}"
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'const NATIVE' in s:
    print('  [web] server.js deja en mode natif - skip'); sys.exit(0)
HELPERS = """
// ─── Native (no-docker) mode ─────────────────────────────────
const NATIVE        = (process.env.OSMO_NATIVE !== '0');
const OP_IDS        = (process.env.OSMO_OP_IDS || '1').split(',')
                        .map(function(s){ return parseInt(s, 10); })
                        .filter(function(n){ return !isNaN(n); });
const NETNS_PREFIX  = process.env.OSMO_NETNS_PREFIX || '';
function vtyProc(container, port, ip, id) {
  if (NATIVE) {
    if (NETNS_PREFIX) return { bin: 'ip', args: ['netns','exec', NETNS_PREFIX + id, 'telnet', ip, String(port)] };
    return { bin: 'telnet', args: [ip, String(port)] };
  }
  return { bin: 'docker', args: ['exec','-i', container, 'telnet', ip, String(port)] };
}
function shCmd(container, id, inner) {
  if (NATIVE) {
    if (NETNS_PREFIX) return 'ip netns exec ' + NETNS_PREFIX + id + ' bash -c "' + inner + '"';
    return 'bash -c "' + inner + '"';
  }
  return 'docker exec ' + container + ' bash -c "' + inner + '"';
}
"""
n = [0]
def sub(pat, rep, flags=0):
    global s
    s, c = re.subn(pat, rep, s, flags=flags); n[0]+=c; return c
sub(r"(const VTY_RETRY_DELAY = 2000;)", r"\1\n" + HELPERS.replace('\\','\\\\'))
sub(r"(function discoverOperators\(\) \{)", r"\1\n  if (NATIVE) return Promise.resolve(OP_IDS.slice());")
sub(r"var proc = spawn\('docker', \[\s*'exec', '-i', container, 'telnet', targetIp, String\(port\)\s*\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(container, port, targetIp, String(container).replace(PREFIX, ''));\n    var proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
sub(r"return execAsync\(\s*'docker inspect.*?\)\.then\(function\(running\) \{",
    "var runningProbe = NATIVE\n    ? execAsync(shCmd(container, id, 'ss -tln 2>/dev/null | grep -q :' + VTY_PORTS.bsc + ' && echo true || echo false'), 3000)\n    : execAsync('docker inspect -f \\'{{.State.Running}}\\' ' + container + ' 2>/dev/null', 3000);\n  return runningProbe.then(function(running) {", re.DOTALL)
sub(r"execAsync\(\s*'docker exec ' \+ container \+ ' bash -c \"ss -tlnp.*?', 3000\s*\)",
    "execAsync(\n        shCmd(container, id, 'ss -tlnp 2>/dev/null | grep :7890 | wc -l'), 3000\n      )", re.DOTALL)
sub(r"log\('VTY open: docker exec.*?\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(this.container, this.port, this.ip, this.opId);\n  log('VTY open: ' + vc.bin + ' ' + vc.args.join(' ') + ' (attempt ' + (this.retries + 1) + ')');\n\n  this.proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
open(p,'w',encoding='utf-8').write(s)
print('  [web] server.js patche mode natif (%d remplacements)' % n[0])
sys.exit(0 if n[0] >= 6 else 2)
PYEOF
fi

# ── Etape 7 : Injection des scripts projet et installation du lanceur start-direct.sh ──
echo -e "${GREEN}[7/9] Scripts projet et adaptation ISO...${NC}"
# ── UN SEUL ARBRE DU DEPOT : /opt/GSM/osmo_egprs ────────────────────────────
# Ici vivait la fabrication d'un SECOND arbre, /opt/GSM/osmo_egprs : une copie
# PARTIELLE du depot (une liste de fichiers nommes un a un, plus sept
# repertoires), sans .git, figee a la construction. L'ISO partait donc avec
# deux osmo_egprs :
#
#   /opt/GSM/osmo_egprs   l'arbre COMPLET, avec son .git, mis a jour a
#                         l'etape [5a/9] et par "osmo-update" ensuite ;
#   /opt/GSM/osmo_egprs       une copie partielle que plus rien ne mettait a jour.
#
# Et c'est le second que visaient les liens osmo-start-direct / osmo-start-lab,
# le message de login, l'alias osmo-lab et l'unite du hub SS7. Autrement dit :
# on mettait a jour un arbre, on en executait un autre. Tout ce qui a ete ajoute
# au depot depuis la derniere construction - un module, un script network/, une
# option - existait sur la machine et restait sans effet, parce que le lanceur
# lance n'etait pas celui qu'on venait de corriger.
#
# Le filet que la copie apportait - "un lanceur present meme sans reseau" - est
# conserve, mais AU MEME ENDROIT : si l'arbre complet n'a pas pu etre recupere,
# on le remplit depuis le depot de construction, et il n'y a toujours qu'un
# seul chemin.
P="$ROOTFS/opt/GSM/osmo_egprs"
if [ ! -x "$P/start-direct.sh" ]; then
    echo -e "  ${YELLOW}!${NC} /opt/GSM/osmo_egprs sans lanceur (image perimee, clone impossible)"
    echo -e "    -> remplissage depuis le depot de construction ${CYAN}${DIR}${NC}"
    mkdir -p "$P"
    # --exclude .git : on ne fabrique pas un faux depot. S'il en manquait un,
    # c'est que le reseau a manque ; osmo-update le reconstituera.
    tar -C "$DIR" --exclude=.git --exclude='*.iso' -cf - . | tar -C "$P" -xf -
    find "$P" -name "*.sh" -exec chmod +x {} \;
fi
if [ ! -x "$P/start-direct.sh" ]; then
    echo -e "  ${RED}✗${NC} start-direct.sh introuvable - l'ISO n'aura pas de lanceur" >&2
    exit 1
fi
ln -sf /opt/GSM/osmo_egprs/start-direct.sh "$ROOTFS/usr/local/bin/osmo-start-direct" 2>/dev/null || true
ln -sf /opt/GSM/osmo_egprs/start.sh        "$ROOTFS/usr/local/bin/osmo-start-lab"    2>/dev/null || true
[ -f "$DIR/launch/osmo-launch.sh" ] && cp "$DIR/launch/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"
echo -e "  ${GREEN}✓${NC} lanceurs -> ${CYAN}/opt/GSM/osmo_egprs${NC} (arbre unique, avec .git)"

# ── WAN : table des noeuds figee dans l'image ────────────────────────────────
if [ "$ISO_WAN" = "1" ]; then
    echo -e "${GREEN}[7b/9] WAN - table des noeuds embarquee...${NC}"
    # shellcheck source=network/wan-nodes.sh
    . "$DIR/network/wan-nodes.sh"
    WAN_OPS="$ISO_WAN_OPS"
    if [ -n "$ISO_WAN_NODES" ]; then
        wan_nodes_parse "$ISO_WAN_NODES" || exit 1
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
    else
        # Construction interactive : memes questions que ./start.sh --wan.
        # Le numero du noeud demande ici n'est qu'un defaut : chaque machine
        # qui demarre l'ISO se re-reconnait a son IP.
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
        wan_nodes_prompt || exit 1
    fi
    wan_nodes_validate || exit 1
    WAN_AUTO=1 WAN_CONF_FILE="$ROOTFS/etc/osmo-wan.conf" wan_nodes_save
    wan_nodes_summary
    echo -e "  ${GREEN}✓${NC} /etc/osmo-wan.conf fige dans l'ISO (WAN_AUTO=1)"
    echo -e "  ${CYAN}Au boot :${NC} start-direct.sh applique le WAN tout seul ;"
    echo -e "  ${CYAN}sans --wan a la construction, l'ISO n'a AUCUN WAN.${NC}"
else
    echo -e "  ${CYAN}[7b/9] WAN non embarque (--wan absent) - ISO autonome${NC}"
fi

# ── Etape 8 : (SUPPRIME) - ISO NATIF, plus de Docker au runtime ───────────
# L'ancien load-osmocom-image.service chargeait osmocom-run.tar.gz via 'docker
# load' au boot ; son ExecStartPre 'while ! docker info' bloquait indefiniment la
# file systemd en natif (docker jamais up) → boot fige. Le lab tourne desormais
# en natif (start-direct.sh) : pas d'image Docker a charger, pas de ce service.

# ── Etape 9 : Configuration chroot (paquets) ───────────────────────────────
# ── Ce que le chroot ne peut pas ecrire lui-meme ────────────────────────────
# Le script du chroot est passe a "bash -c" en QUOTES SIMPLES : rien n'y est
# substitue a l'ecriture, ce qui est voulu, mais une seule apostrophe dans le
# corps referme la chaine et tout ce qui suit change de sens. Les fichiers qui
# en contiennent - un heredoc quote, une commande shell imbriquee - s'ecrivent
# donc ICI, dans le rootfs, ou le quoting est normal. Le chroot ne fait plus que
# les activer.

# NetworkManager pilote le bureau ; ce qui appartient au coeur paquet ne lui
# appartient pas. Sans cette regle, NM reprend apn0 ou un tun du GGSN et coupe
# la session de donnees d'un abonne parce qu'il l'a jugee "non configuree".
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-osmo-networkd.conf" <<'NMCONF'
# Ecrit par build-iso.sh. NetworkManager gere les cartes physiques et le
# bureau ; les interfaces du coeur paquet restent a systemd-networkd et aux
# scripts du banc.
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:apn*;interface-name:tun*;interface-name:veth*;interface-name:docker*;interface-name:br-*;interface-name:osmo*
NMCONF

# Chromium : installe au PREMIER DEMARRAGE, depuis les .snap embarques quand ils
# sont la, depuis le magasin sinon. Voir la variante desktop du chroot.
#
# CHROMIUM ET PAS FIREFOX, et ce n'est pas une preference.
# Les deux ne sont disponibles qu'en snap sur jammy - le .deb "chromium-browser"
# comme le .deb "firefox" sont des paquets de TRANSITION qui appellent snapd.
# Mais sur ce banc, Firefox ne capte pas le micro et Chrome oui, constate des
# deux cotes : le tableau de bord a besoin de getUserMedia pour injecter la voix
# dans gsm_mic, et un navigateur qui ne capture pas rend cette fonction
# inutilisable. La cause de fond - PulseAudio en mode systeme, dont le socket
# n'est pas la ou un snap le cherche - est corrigee par osmo-pulse-link.sh plus
# bas, mais Chromium reste le navigateur qui fonctionne dans les deux cas.
if [ "$ISO_DESKTOP" = "1" ]; then
cat > "$ROOTFS/etc/systemd/system/osmo-chromium-snap.service" <<'CRSNAP'
[Unit]
Description=Installation de Chromium (snap) au premier demarrage
# snapd.seeded : snapd a fini de deballer ce que l'image portait deja. Partir
# avant, c'est installer par-dessus une graine encore en cours de montage.
After=snapd.seeded.service network-online.target
Wants=snapd.seeded.service
ConditionPathExists=!/var/lib/osmo-snaps/.installe

[Service]
Type=oneshot
RemainAfterExit=yes
# Poser ~1 Go de snaps prend des MINUTES sur un medium optique ou une cle lente.
# Le delai par defaut de systemd (90 s) tuait l'unite en pleine installation, et
# ne laissait derriere lui qu'un "chromium introuvable" sans rapport apparent.
TimeoutStartSec=infinity
# Hors ligne d'abord (les .snap embarques), le magasin ensuite : un banc sans
# Internet doit quand meme avoir son navigateur.
#
# L'ORDRE COMPTE. Un snap ne s'installe pas avant sa base : "snap install
# chromium.snap" sans core24 pose sort sur
#     cannot install snap "chromium": snap "core24" is required
# Le fichier "ordre", ecrit au build, porte la sequence exacte (snapd, la base,
# puis les fournisseurs de contenu, puis chromium).
#
# LES INTERFACES DE CONTENU decident si le navigateur DEMARRE, pas seulement
# s'il est joli : chromium 15x passe par gpu-2404 (mesa-2404) et gnome-46-2404
# via sa command-chain. Sans ces slots connectes, le lanceur du snap s'arrete
# avant meme d'ouvrir une fenetre. audio-record, elle, n'est jamais connectee
# d'office : sans elle le bac a sable refuse le micro et getUserMedia rend
# NotFoundError, sans qu'une seule ligne ne parle de confinement.
#
# Tout est journalise dans /var/log/osmo-chromium-snap.log : la version
# precedente envoyait stderr dans /dev/null, et une installation ratee etait
# indiscernable d'une installation absente.
ExecStart=/bin/bash -c 'cd /var/lib/osmo-snaps 2>/dev/null || exit 0; \
  exec >>/var/log/osmo-chromium-snap.log 2>&1; \
  echo "=== $(date -Is) installation des snaps ==="; \
  for a in *.assert; do [ -e "$a" ] && snap ack "$a"; done; \
  if [ -s ordre ]; then \
    while read -r s; do \
      [ -n "$s" ] || continue; \
      [ -s "$s.snap" ] || { echo "absent: $s.snap"; continue; }; \
      snap install "$s.snap" || echo "ECHEC hors ligne: $s"; \
    done < ordre; \
  fi; \
  snap list chromium >/dev/null 2>&1 || snap install chromium || true; \
  for i in gpu-2404 gnome-46-2404 gtk-3-themes icon-themes sound-themes \
           audio-record audio-playback camera removable-media; do \
    snap connect "chromium:$i" || true; \
  done; \
  snap list; \
  touch /var/lib/osmo-snaps/.installe'

[Install]
WantedBy=multi-user.target
CRSNAP
echo -e "  ${GREEN}✓${NC} osmo-chromium-snap.service (Chromium par snap, au premier boot)"
fi

echo -e "${GREEN}[8/9] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

# ISO_ROLE passe par l environnement : le script est en quotes simples, rien n y
# est substitue a l ecriture - c est voulu (aucune surprise d expansion), donc la
# seule facon de lui dire quelle image on construit est de le lui passer.
chroot "$ROOTFS" env ISO_ROLE="$ISO_ROLE" ISO_LITE="$ISO_LITE" \
                   ISO_DESKTOP="$ISO_DESKTOP" OSMO_ISO_KB="$OSMO_ISO_KB" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"

# ── apt/dpkg rapides ────────────────────────────────────────────────────────
# Ce rootfs est jetable : il est fabrique, empaquete en squashfs, puis efface.
# Les garanties de durabilite que dpkg paie a chaque fichier - un fsync par
# fichier deballe - n ont donc aucune valeur ici, et elles dominent le temps de
# construction. force-unsafe-io les coupe : c est le reglage qu utilisent les
# images Docker officielles, pour la meme raison.
#
# Le reste ne joue pas sur la durabilite mais sur ce qui est TELECHARGE :
#   Languages=none    supprime les traductions de descriptions (inutiles ici)
#   Pipeline-Depth    plusieurs requetes en vol au lieu d une a la fois
#   Retries           un miroir qui bronche ne fait plus echouer la construction
#                     entiere - ce chroot tourne sous set -e
mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/02-unsafe-io
cat > /etc/apt/apt.conf.d/99osmo-fast <<APTFAST
Acquire::Languages "none";
Acquire::Retries "3";
Acquire::http::Pipeline-Depth "5";
Dpkg::Use-Pty "0";
APTFAST

APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

cat > /etc/apt/sources.list <<SOURCES
deb http://archive.ubuntu.com/ubuntu jammy           main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates    main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security   main universe multiverse
SOURCES
apt-get update -qq

# ── UN SEUL apt-get install ────────────────────────────────────────────────
# [2026-08-27] Il y en avait cinq a la suite. apt resout, telecharge puis
# configure a CHAQUE appel : cinq resolutions de dependances, cinq lots de
# telechargement qui ne se recouvrent pas, et dpkg qui reconfigure ce que le lot
# suivant vient de tirer. Un seul appel resout une fois, telecharge en parallele
# et deballe dans un seul ordre - c est le poste le plus lourd du chroot.
#
# L ordre compte encore : cet appel reste JUSTE APRES apt-get update, avant le
# build-dep. Ce chroot tourne sous set -e ; un build-dep qui echoue ne doit pas
# emporter avec lui les outils sans lesquels l ISO sort muette :
#   nc       le VTY est la seule source de verite sur l etat SS7 : tout le
#            depot l interroge par "nc 127.0.0.1 4239". Sans nc, les checks ne
#            se plaignent pas - ils affichent un diagnostic VIDE, qui se lit
#            comme "rien n est attache" alors que tout va bien.
#   socat    le transport VTY que run_modules/_lib/core.sh prend EN PREMIER, et
#            sans lequel 21-abonnes-hlr.sh se rabat sur telnet - qui ne rend pas
#            la main sur EOF de stdin, donc pas de provisionnement HLR.
#   tcpdump  les captures GSMTAP/M3UA. Sans lui, une capture lancee en arriere
#            plan echoue en silence et le pcap reste vide.
#   git      les trois depots embarques gardent leur .git : c est par lui qu on
#            les met a jour, sur la machine, sans les recloner.
#
# Deux listes, parce que les deux images ne font pas le meme metier. Le hub
# inter-STP ne fait que router du M3UA : ni radio, ni QEMU, ni audio, ni PBX.
# Lui installer asterisk, pulseaudio et ffmpeg, c est du poids et des services
# en plus pour rien.
# ca-certificates EN TETE, et reinstalle explicitement plus bas. Le rootfs sort
# de debootstrap avec le paquet mais SANS son magasin a jour : /etc/ssl/certs
# n est peuple que par update-ca-certificates, que rien n appelait ici. Tout ce
# qui parle en TLS depuis l image echouait alors sur "certificate verify
# failed" - git clone https, curl, snap download, npm - et le message accuse le
# reseau, pas le magasin vide.
# LE NOYAU : 6.8 (HWE), PAS 5.15 (GA). linux-image-generic sur jammy est fige a
# la serie 5.15 ; le materiel recent (NIC, USB3, SDR branches en direct) y perd
# des pilotes que la serie 6.8 porte. linux-image-generic-hwe-22.04 est le noyau
# d activation materielle officiel de jammy (6.8.0-138, meme depot main, meme
# cle Canonical - donc toujours signe pour Secure Boot) et tire
# linux-modules-extra en dependance. La detection plus bas [ls vmlinuz-star,
# sort -V, tail -1] choisit automatiquement le 6.8 pour l ISO.
PKGS="ca-certificates openssl netcat-openbsd socat tcpdump git logrotate
      linux-image-generic-hwe-22.04 initramfs-tools
      live-boot live-boot-initramfs-tools
      libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev libc-ares2
      libgnutls30 libgnutls28-dev libmnl-dev libmnl0
      libortp-dev libdbi1 libdbd-sqlite3 sqlite3
      libfftw3-single3 libusb-1.0-0
      libgsm1 libasound2
      libsofia-sip-ua-glib3
      liburing2 libslirp0
      iproute2 iptables net-tools lksctp-tools
      tmux telnet expect whiptail
      lsb-release openssh-server sudo
      console-setup keyboard-configuration locales
      psmisc
      python3 python3-venv python3-scapy
      tshark wireshark-common"

if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    # Radio, emulation Calypso, audio, PBX : le noeud operateur seulement.
    PKGS="$PKGS
      libasound2-plugins pulseaudio pulseaudio-utils alsa-utils
      binutils-arm-none-eabi gdb-multiarch
      asterisk
      ffmpeg"

    # ── En-tetes de build QEMU : l ISO NORMALE SEULEMENT ────────────────────
    # L image normale embarque /opt/GSM/qemu-src avec son .git ET son build/ :
    # c est un atelier, on y developpe l emulation Calypso et on doit pouvoir
    # relancer "make -C build qemu-system-arm" sur la machine. Or les runtimes
    # seuls (liburing2, libslirp0, libpixman-1-0) ne suffisent pas : ninja
    # reclame le lien de developpement .so ET l en-tete.
    #
    # MESURE DU 2026-08-27, sur l ISO telle que construite jusqu ici :
    #   ninja: error: '/usr/lib/x86_64-linux-gnu/libpixman-1.so' missing
    #   include/block/aio.h:18: fatal error: liburing.h: No such file
    # -> la recompilation etait IMPOSSIBLE sur la machine, alors que tout
    # l atelier (sources, .git, build/ deja peuple) etait la pour ca.
    #
    # La LITE, elle, n est pas un atelier : elle part de Dockerfile.lite, qui
    # elague justement les chaines de compilation. Trois paquets -dev de plus
    # y seraient du poids sans usage - d ou le test sur ISO_LITE.
    if [ "${ISO_LITE:-0}" != "1" ]; then
        PKGS="$PKGS
      liburing-dev libslirp-dev libpixman-1-dev"
    fi
fi

apt-get install -y $APT_OPTS --no-install-recommends $PKGS

# deb-src + build-dep gnuradio : tire toutes les deps de GNU Radio (boost, fftw,
# gmp, log4cpp, volk...) dont depend le gnuradio/gr-gsm custom de /usr/local.
# Genere les lignes deb-src a partir des deb (tous composants), comme le Dockerfile.
# Le hub n a pas de gr-gsm : lui faire tirer ~80 Mo d index Sources et une
# cloture de build GNU Radio, c est quelques minutes de construction pour rien.
if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    sed -nE "s|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p" \
        /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list
    apt-get update -qq
    apt-get build-dep -y $APT_OPTS gnuradio || echo "WARN: apt build-dep gnuradio a echoue"
fi

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

# -- venv /root/.env : il doit EXISTER et porter tomli --------------------
# /root/.env est le venv que start-clean.sh (qemu-src) et le profil de root
# activent : le .bashrc pose plus bas fait
#     [ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
# Il arrive ici par un docker cp du CID vers /root/, suivi de || true : si
# l image de run ne le porte pas, ou si son bin/ pointe sur un interpreteur
# absent, le venv MANQUE et personne ne le dit -- le test du .bashrc echoue
# en silence et tout retombe sur le python3 systeme.
#
# python3 -m venv SANS --clear est REPARATEUR, pas destructeur : il recree
# bin/ et pyvenv.cfg, installe pip par ensurepip, et laisse
# lib/pythonX.Y/site-packages en place. On peut donc l appeler aussi bien
# sur le venv copie que sur un repertoire absent. C est aussi ce qui exige
# python3-venv dans PKGS : sans lui ensurepip n a pas ses roues, et la
# creation echoue.
#
# tomli : lecteur TOML entre dans la bibliotheque standard en 3.11 sous le
# nom tomllib, mais ABSENT de la 3.10 de jammy. Ce qui lit un TOML depuis
# le venv en depend donc explicitement.
python3 -m venv /root/.env
/root/.env/bin/python3 -m pip install -q --no-cache-dir --disable-pip-version-check tomli \
    || echo "WARN: pip a echoue pour tomli dans /root/.env"
if /root/.env/bin/python3 -c "import tomli" 2>/dev/null; then
    echo "  /root/.env : venv pret, tomli importable"
else
    echo "WARN: /root/.env sans tomli utilisable"
fi

# Docker NON installe dans le ISO (natif) : le lab tourne via start-direct.sh et le
# dashboard web via node natif. Le build sur le HOTE utilise le docker du HOTE pour
# extraire binaires/configs, mais le ISO final nembarque pas docker.

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/GSM/osmo-egprs-web/package.json ]; then
    cd /opt/GSM/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

# ── VARIANTE DESKTOP : bureau, wireshark en fenetre, linphone ──────────────
# Place ICI, et pas ailleurs : APRES le gros apt-get install (les deps communes
# sont deja la, apt ne les reresout pas), mais AVANT update-initramfs - le
# bureau tire plymouth et des modules qui doivent entrer dans l initrd - et
# avant le apt-get clean qui vide le cache.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo "  [desktop] ubuntu-desktop-minimal + wireshark + linphone-desktop"

    # AVEC les recommends, et c est tout le piege. ubuntu-desktop-minimal est un
    # metapaquet dont presque TOUT est en Recommends. Installe avec le
    # --no-install-recommends que le reste de ce chroot utilise, il tire
    # gnome-shell et a peu pres rien autour : ni gdm3, ni session, ni terminal.
    # On obtient un ecran noir au boot, pas un bureau - et le message
    # d installation, lui, dit "done".
    #
    # linphone (sans suffixe) est un paquet de TRANSITION vide sur jammy ; le
    # client graphique s appelle linphone-desktop. wireshark tire wireshark-qt.
    apt-get install -y $APT_OPTS \
        ubuntu-desktop-minimal wireshark linphone-desktop snapd \
        || echo "WARN: installation du bureau incomplete"

    # ── L INSTALLEUR : CALAMARES, ET POURQUOI PAS UBIQUITY ─────────────────
    # Ubiquity est l installeur d Ubuntu et il est dans jammy (22.04.15). Il ne
    # peut pas servir ici : il lit l etat du systeme live par CASPER, alors que
    # cette image demarre avec LIVE-BOOT, celui de Debian (voir la liste PKGS
    # plus haut : live-boot, live-boot-initramfs-tools, pas casper). Ubiquity ne
    # trouverait ni le squashfs ni le point de montage du medium, et sortirait
    # avant la premiere question - sans dire que la cause est l initramfs.
    #
    # Calamares ne suppose rien : on lui DIT ou est le squashfs. Sa
    # configuration vit dans le depot (installer/calamares/), elle est copiee
    # dans le rootfs HORS de ce chroot - ces fichiers sont pleins
    # d apostrophes, et ce script-ci est en quotes simples.
    #
    # Les dependances ne sont pas facultatives, chacune couvre une etape :
    #   squashfs-tools  unpackfs, qui deverse le systeme sur le disque
    #   dosfstools      la partition EFI, formatee en FAT
    #   efibootmgr      l entree de demarrage UEFI
    #   os-prober       les autres systemes, pour le menu GRUB
    #   qml-module-*    le diaporama pendant la copie
    # L echec de CETTE etape ne doit PAS etre avale. calamares tire une longue
    # chaine de dependances Qt/KDE ; si le miroir en manque une, apt sort en
    # erreur - et un "|| echo WARN" laissait alors construire une image DESKTOP
    # SANS installeur, exactement le "calamares marche pas" observe (ni binaire
    # ni /etc/calamares dans le squashfs livre). On installe, PUIS on verifie
    # que le binaire est bien la ; sinon on arrete le build.
    apt-get install -y $APT_OPTS \
        calamares squashfs-tools dosfstools efibootmgr os-prober \
        qml-module-qtquick2 qml-module-qtquick-layouts \
        qml-module-qtquick-window2 qml-module-qtquick-controls
    # On est DANS le chroot (ce bloc tourne sous "chroot ... bash -c") : le
    # binaire est donc a /usr/bin/calamares, pas sous $ROOTFS (variable absente
    # ici). set -e est actif ; l apt-get ci-dessus n a plus de "|| echo" donc un
    # echec avorte deja - ce test attrape le cas ou apt sort 0 mais sans poser le
    # binaire (paquet recommande saute, etc.).
    if [ ! -x /usr/bin/calamares ]; then
        echo "ERREUR: calamares absent du rootfs apres apt-get - build DESKTOP interrompu." >&2
        echo "        (dependance Qt/KDE manquante au miroir ? relancer avec un cache .deb)" >&2
        exit 1
    fi

    # ── CHROMIUM : LE SNAP, PAS LE DEB ─────────────────────────────────────
    # Sur jammy, "apt install chromium-browser" (comme "apt install firefox")
    # pose un paquet de TRANSITION vide dont le postinst appelle
    # "snap install ...". Dans un chroot, snapd ne tourne pas : le postinst
    # echoue, apt le signale a peine, et l image sort avec un binaire qui
    # n existe pas. On ne compte donc pas sur apt.
    #
    # On ne peut pas non plus "snap install" ici - meme raison. Ce qui marche
    # dans un chroot, c est TELECHARGER (snap download parle au magasin en
    # direct, il n a pas besoin du demon) et laisser l installation au premier
    # demarrage, quand snapd tourne pour de bon. Les .snap et leurs assertions
    # voyagent dans l image : l installation se fait alors HORS LIGNE, ce qui
    # compte pour un banc qui n a pas toujours Internet.
    # L unite qui les pose (osmo-chromium-snap.service) est ecrite HORS de ce
    # chroot : le script y est en quotes simples, une apostrophe de plus et
    # tout ce qui suit change de sens.
    apt-get purge -y firefox chromium-browser 2>/dev/null || true
    mkdir -p /var/lib/osmo-snaps
    _snap_ok=1

    # ── LES DEPENDANCES SE LISENT DANS LE SNAP, ELLES NE SE DEVINENT PAS ────
    # L ancienne liste etait ecrite en dur : gtk-common-themes, gnome-42-2204,
    # chromium. Elle etait FAUSSE, et l image sortait sans navigateur.
    # chromium 151 declare "base: core24" et reclame, par ses interfaces de
    # contenu, mesa-2404 (gpu-2404) et gnome-46-2404 - gnome-42-2204 est la
    # plateforme du monde core22, celle du chromium d AVANT : 557 Mo embarques
    # que rien ne monte. Sans core24 ni mesa-2404, "snap install chromium.snap"
    # echoue hors ligne, et le lanceur repond "chromium introuvable".
    #
    # On lit donc "base:" et les "default-provider:" DANS le .snap telecharge,
    # au lieu de les recopier : la prochaine bascule de base (core26...) se
    # fera toute seule. cups est volontairement ecarte - c est un fournisseur
    # d impression optionnel de 200 Mo, son absence ne bloque pas le demarrage.
    ( cd /var/lib/osmo-snaps && snap download chromium --basename=chromium ) \
        || { echo "  [desktop] WARN: snap download chromium a echoue"; _snap_ok=0; }

    #
    # Pas une seule apostrophe ici : ce bloc tourne dans un bash -c en quotes
    # simples (voir plus haut) - les programmes awk sont donc en guillemets,
    # avec \$2 echappe pour qu il arrive intact a awk.
    _base=""; _providers=""
    if [ -s /var/lib/osmo-snaps/chromium.snap ] && command -v unsquashfs >/dev/null; then
        unsquashfs -cat /var/lib/osmo-snaps/chromium.snap meta/snap.yaml \
            > /tmp/chromium-snap.yaml 2>/dev/null || true
        # || true : ce chroot tourne sous set -e, et grep qui ne retient rien
        # sort avec 1 - une liste vide ferait echouer la construction entiere.
        _base=$(awk "/^base:[[:space:]]/{print \$2; exit}" /tmp/chromium-snap.yaml) || true
        _providers=$(awk "/default-provider:[[:space:]]/{print \$2}" /tmp/chromium-snap.yaml \
                     | sort -u | grep -vx cups) || true
        rm -f /tmp/chromium-snap.yaml
    fi
    [ -n "$_base" ] || _base=core24
    [ -n "$_providers" ] || _providers="mesa-2404 gnome-46-2404 gtk-common-themes"
    echo "  [desktop] chromium : base=$_base, contenu=$(echo $_providers)"

    # snapd en tete : sur une base core2x, les snaps montent /snap/snapd et
    # refusent de demarrer sans lui.
    rm -f /var/lib/osmo-snaps/ordre; touch /var/lib/osmo-snaps/ordre
    for _sn in snapd "$_base" $_providers; do
        ( cd /var/lib/osmo-snaps && snap download "$_sn" --basename="$_sn" ) \
            && echo "$_sn" >> /var/lib/osmo-snaps/ordre \
            || { echo "  [desktop] WARN: snap download $_sn a echoue"; _snap_ok=0; }
    done
    # En dernier, et jamais en "[ ... ] && ..." : sous set -e, un test faux
    # en fin de bloc arreterait le chroot net.
    if [ -s /var/lib/osmo-snaps/chromium.snap ]; then
        echo chromium >> /var/lib/osmo-snaps/ordre
    fi
    systemctl enable osmo-chromium-snap 2>/dev/null || true
    if [ "$_snap_ok" = "1" ]; then
        echo "  [desktop] Chromium : snap embarque ($(du -sh /var/lib/osmo-snaps 2>/dev/null | cut -f1)), installe au premier boot"
    else
        echo "  [desktop] Chromium : snap NON embarque - installation depuis le magasin au premier boot (reseau requis)"
    fi

    systemctl set-default graphical.target

    # ── NetworkManager : ACTIF ──────────────────────────────────────────────
    # Il etait masque pour laisser systemd-networkd seul maitre des interfaces.
    # Le cout etait un bureau sans reseau utilisable a la main : pas de choix de
    # Wi-Fi, pas de VPN, pas de bascule d interface - il fallait editer un
    # .network et redemarrer un service pour changer de carte.
    #
    # Les deux cohabitent a condition que chacun sache ce qui ne lui appartient
    # pas. systemd-networkd garde les interfaces du banc (apn0, les tun/veth du
    # coeur paquet) ; NetworkManager prend les cartes physiques. La regle qui le
    # dit - /etc/NetworkManager/conf.d/10-osmo-networkd.conf - est ecrite HORS
    # de ce chroot, dont le script est en quotes simples. Sans elle, les deux se
    # disputent la meme carte et c est l adresse qui saute au milieu d une
    # session M3UA.
    systemctl unmask NetworkManager NetworkManager-wait-online 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true

    # ── Autologin ──────────────────────────────────────────────────────────
    # ROOT, directement : il n y a plus de compte "osmocom" (supprime plus
    # haut - c etait un alias d UID 0 qui se faisait passer pour un compte
    # ordinaire). GDM, lui, refuse toute session pour l uid 0, et la regle
    # n est pas dans gdm3.conf mais dans PAM :
    #     auth required pam_succeed_if.so user != root quiet_success
    # Sans la neutraliser, autologin ou pas, on retombe sur l ecran de connexion
    # et AUCUN mot de passe ne passe - y compris le bon.
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin 2>/dev/null || true
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<GDM
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 impose : sous VirtualBox/QEMU, la session Wayland de GNOME 42 tombe sur
# le pilote llvmpipe et rend un bureau inutilisable, quand elle demarre.
WaylandEnable=false
GDM

    # L assistant de premier demarrage (langue, comptes en ligne, sondage) se
    # rejoue a CHAQUE boot sur un live sans persistance : il faut le desarmer,
    # sinon il est la premiere - et longtemps la seule - chose a l ecran.
    rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop
    for h in /root; do
        mkdir -p "$h/.config" && echo yes > "$h/.config/gnome-initial-setup-done"
    done

    # Verrouillage d ecran et mise en veille : desarmes. Une image de banc reste
    # affichee pendant qu on regarde une capture ou un appel courir ; et sur un
    # live, l ecran verrouille se rouvre avec un mot de passe que personne n a
    # choisi. La disposition clavier suit celle demandee au build (--kb).
    # printf et pas un heredoc : les valeurs gschema portent des apostrophes, et
    # ce chroot tourne dans un bash -c en quotes simples - d ou les \047.
    printf "[org.gnome.desktop.session]\nidle-delay=uint32 0\n\n[org.gnome.desktop.screensaver]\nlock-enabled=false\nidle-activation-enabled=false\n\n[org.gnome.settings-daemon.plugins.power]\nsleep-inactive-ac-type=\047nothing\047\nsleep-inactive-battery-type=\047nothing\047\n\n[org.gnome.desktop.input-sources]\nsources=[(\047xkb\047,\047%s\047)]\n" \
        "${OSMO_ISO_KB:-fr}" > /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    # ── Fond d ecran GSM LAB ────────────────────────────────────────────
    # PNG 1920x1080 fige au build (configs/gsm-lab-wallpaper.png, rendu depuis
    # la page bbaranoff.github.io), pose comme fond GNOME par DEFAUT de session
    # (live sans persistance : il faut le defaut de schema, pas un reglage
    # utilisateur). zoom : l image est en 16:9, elle remplit sans deformer.
    _WP=/opt/GSM/osmo_egprs/configs/gsm-lab-wallpaper.png
    if [ -f "$_WP" ]; then
        install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-wallpaper.png
        printf "\n[org.gnome.desktop.background]\npicture-uri=\047file:///usr/share/backgrounds/gsm-lab-wallpaper.png\047\npicture-uri-dark=\047file:///usr/share/backgrounds/gsm-lab-wallpaper.png\047\npicture-options=\047zoom\047\nprimary-color=\047#0d1b2a\047\n" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        echo "  [desktop] fond d ecran GSM LAB pose"
    else
        echo "  [desktop] WARN: $_WP absent -- fond d ecran GNOME par defaut"
    fi
    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true

    echo "  [desktop] GNOME pret : autologin root, X11, NetworkManager actif, Chromium snap"
fi

# ── Les certificats, POUR DE BON ────────────────────────────────────────────
# Installer ca-certificates ne suffit pas : c est update-ca-certificates qui
# deballe /usr/share/ca-certificates/* dans /etc/ssl/certs et fabrique le
# ca-certificates.crt que lisent OpenSSL, curl, git et snap. Dans un chroot le
# postinst ne le fait pas toujours - et le rootfs sortait avec un magasin vide.
# --fresh : on repart du magasin du paquet plutot que d ajouter a un etat
# herite du debootstrap, dont on ne sait pas ce qu il contient.
apt-get install -y $APT_OPTS --reinstall ca-certificates >/dev/null 2>&1 || true
update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates || true
if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
    echo "  certificats : $(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt) autorites dans /etc/ssl/certs"
else
    echo "  WARN: /etc/ssl/certs/ca-certificates.crt vide - le TLS echouera dans l image"
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

# deb-src.list part avec le reste : les index Sources qu il fait telecharger
# pesent ~80 Mo, et sur un live en toram ils sont repris en RAM au premier
# "apt-get update" du boot. Ils n ont servi qu au build-dep gnuradio ci-dessus,
# qui est deja passe - et plus rien n installe de paquet au demarrage.
apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/apt/sources.list.d/deb-src.list
'

# ── Etape 8b : Reequilibrage sur build.sh - cloture de dependances ldd ────────
# L'image osmocom-run (produite par build.sh + Dockerfile) est l'environnement
# qui MARCHE. Au lieu de se fier aux versions apt du rootfs (skew -> crash
# logging libosmocore), on copie depuis le conteneur la cloture .so EXACTE de
# tous les binaires osmo + calypso-ipc-device, en ecrasant les libs apt. On
# exclut la famille glibc/loader (identique en jammy, ne pas clobber ld.so).
echo -e "${GREEN}[8b/9] Cloture de dependances COMPLETE depuis ${CYAN}${ISO_RUN_IMAGE}${NC}${GREEN} (toute l'install)...${NC}"
# On ldd TOUS les ELF (executables + toutes les .so) de l'install custom :
# /usr/local/bin (osmo), /opt/GSM (qemu, ipc-device, gr-gsm), /root/.env (venv
# python : bindings gnuradio/gr-gsm + leurs deps boost/log4cpp/volk/fftw...).
# => toutes les deps natives finissent dans l'ISO, plus de "import gsm" qui rate.
docker run --rm --entrypoint bash \
    -e OSMO_LDD_ROOTS="$([ "$ISO_ROLE" = "interstp" ] && echo "/usr/local/bin /usr/local/lib" || echo "/usr/local/bin /opt/GSM /root/.env")" \
    "$ISO_RUN_IMAGE" -c '
    set -e
    find ${OSMO_LDD_ROOTS:-/usr/local/bin /opt/GSM /root/.env} -type f \( -executable -o -name "*.so*" \) 2>/dev/null \
      | while read -r b; do ldd "$b" 2>/dev/null; done \
      | grep -oE "/[^ ]+\.so[^ ]*" | sort -u \
      | grep -vE "/(ld-linux[^/]*|ld|libc|libm|libpthread|libdl|librt|libresolv)\.so" \
      | while read -r f; do realpath "$f" 2>/dev/null; done | sort -u \
      | tar -czf - -T - 2>/dev/null
' > "$WORK/closure.tar.gz" || true
if [ -s "$WORK/closure.tar.gz" ]; then
    tar -xzf "$WORK/closure.tar.gz" -C "$ROOTFS" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} $(tar -tzf "$WORK/closure.tar.gz" 2>/dev/null | wc -l) libs injectees (Docker)"
else
    echo -e "  ${YELLOW}cloture vide - on garde les libs apt${NC}"
fi

# Priorite /usr/local/lib (libosmo* custom) + purge de tout doublon systeme.
# NB: pas de `| grep` ici - sous set -euo pipefail un grep sans correspondance
# (cas normal: aucun doublon) renverrait 1 et tuerait le script avant l'ISO.
echo "/usr/local/lib" > "$ROOTFS/etc/ld.so.conf.d/00-osmocom-local.conf"
find "$ROOTFS/usr/lib" "$ROOTFS/lib" -maxdepth 4 -name 'libosmo*.so*' -delete 2>/dev/null || true
chroot "$ROOTFS" ldconfig 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} /usr/local/lib prioritaire + ldconfig"

# ── Configuration systeme ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
# ── Adresses heritees du plan docker, en /32 ────────────────────────────────
# Elles servent aux configs de l'image qui nomment encore 172.20.x (passerelle
# du backbone, cible gsmtap...) : sans elles, un demon qui s'y lie ne demarre
# pas. On les garde donc - mais sans revendiquer de reseau.
#
# POURQUOI /32 ET PLUS /24
# Un /24 fait croire a la machine que TOUT 172.20.0.0/24 est sur son lien. Elle
# l'ARP alors sur le LAN au lieu de le router. Sur un banc mixte VM + docker,
# les conteneurs de l'hote deviennent injoignables : "ip route add
# 172.20.0.0/24 via <hote>" est refuse d'un "File exists", et le trafic part
# dans le vide. Le /32 garde l'adresse locale sans fermer la porte au routage.
#
# 172.20.0.11 est RETIREE : c'est l'adresse du PREMIER CONTENEUR operateur. Une
# VM qui la porte se repond a elle-meme et ne joint jamais le conteneur - la
# panne la plus deroutante du lot, puisque tout repond en local.
#
# La route /16 disparait pour la meme raison : elle couvrait le plan docker
# entier et primait sur toute route plus fine vers l'hote.
#
# [2026-08-29] LES ADRESSES PRIVEES NE SONT PLUS ICI.
# Elles y etaient sous [Match] Name=en* eth*, donc posees sur TOUTE carte qui
# repond au motif - et le motif ne dit rien de celle qui porte reellement le
# reseau. Sur une VM a plusieurs interfaces, l'adresse se retrouvait sur le NAT
# pendant que le pont, lui, ne l'avait pas : un pair visait 192.168.2.10 sans
# trouver personne, alors que "ip addr" la montrait bien presente - ailleurs.
# systemd-networkd ne sait pas exprimer « la carte qui a la route par defaut » :
# c'est une propriete d'execution. C'est osmo-ip-plan.service qui les pose
# maintenant, avec repli sur la boucle locale quand aucune carte ne mene nulle
# part (voir network/osmo-ip-plan.sh).
EOF
# docker RETIRE de la liste : son service n'existe plus (ISO natif) et 'systemctl
# enable' valide tous les units d'abord → un seul manquant faisait AVORTER l'enable
# de systemd-networkd/resolved → enp3s0 sans IP au boot. On active chaque unit
# separement pour qu'un eventuel echec n'empeche pas les autres.
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null||true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>/dev/null||true

# ── Les adresses privees du noeud, posees a l'EXECUTION ─────────────────────
# Voir network/osmo-ip-plan.sh : il choisit la carte qui fournit reellement
# Internet, y pose 192.168.<noeud+1>.1 et .10, et retombe sur 127.0.0.66 sur lo
# quand aucune carte ne mene nulle part - de sorte que les configurations qui
# nomment une adresse privee trouvent TOUJOURS quelque chose de local, au lieu
# d'echouer au bind sur une adresse absente.
install -Dm755 "$DIR/network/osmo-ip-plan.sh" "$ROOTFS/usr/local/sbin/osmo-ip-plan.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-ip-plan.service" <<'IPPLAN'
[Unit]
Description=Adresses privees du noeud sur la carte qui fournit Internet
# APRES networkd-wait-online : avant, aucune route par defaut n'existe encore et
# le script conclurait "aucune carte" a chaque demarrage - le repli loopback
# serait la regle au lieu de l'exception.
After=network-online.target systemd-networkd.service
Wants=network-online.target
Before=osmo-egprs-web.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-ip-plan.sh --apply

[Install]
WantedBy=multi-user.target
IPPLAN
# Rejoue a chaque changement de lien : un cable rebranche, un Wi-Fi qui prend le
# relais, et la carte qui fournit Internet n'est plus la meme. Sans ca, les
# adresses restaient sur l'ancienne - presentes, et injoignables.
mkdir -p "$ROOTFS/etc/networkd-dispatcher/routable.d"
cat > "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan" <<'IPHOOK'
#!/bin/sh
exec /usr/local/sbin/osmo-ip-plan.sh --apply
IPHOOK
chmod +x "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan"
chroot "$ROOTFS" systemctl enable osmo-ip-plan 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-ip-plan : ${CYAN}192.168.$(( ${ISO_NODE:-1} + 1 )).1/.10${NC} sur la carte Internet, repli ${CYAN}127.0.0.66${NC}"

# live-boot ecrit /root/etc/network/interfaces dans la racine montee au boot.
# Sans ifupdown, /etc/network/ n'existe pas -> "/init: can't create
# /root/etc/network/interfaces: nonexistent directory". On cree le dossier + un
# interfaces minimal (loopback). systemd-networkd gere le reseau ; ce fichier
# n'est lu par personne (ifupdown absent), il satisfait juste le hook live-boot.
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# ── Animation SMS a l'ouverture de session ─────────────────────────────────
# [2026-08-27] Ce qui vivait ici : osmo-update.service, qui a CHAQUE demarrage
# telechargeait update.sh depuis GitHub et l'executait - lequel effacait puis
# reclonait osmo_egprs et osmo-egprs-web, resynchronisait qemu-src et installait
# socat a coups d'apt. Le contenu de la machine etait donc decide au boot par le
# reseau, et sans reseau il ne restait rien des arbres effaces.
#
# Tout cela se fait ICI, une fois, a la construction : les trois depots partent
# dans l'image AVEC leur .git (etapes [5a/9] et [5b/9]), qemu-src avec son
# build/ compile, les paquets sont installes dans le rootfs (etape 5), et le
# service du dashboard est pose plus bas. Du update.sh il ne reste que ce qui
# exige un terminal et quelqu'un devant : l'animation SMS.
#
# Elle est jouee par le PROFIL, pas par un service : un oneshot systemd tourne
# avant qu'un terminal existe, et sa sortie part dans un log que personne ne lit.
# /etc/profile.d est source dans l'ordre alphabetique - 01-osmo-disclaimer.sh
# d'abord, 99-osmo-sms.sh ensuite : l'utilisateur lit ce qu'il peut lancer, puis
# le SMS arrive. Et le fichier est ECRIT DANS L'IMAGE, donc present quand le
# shell developpe son "for i in /etc/profile.d/*.sh" : c'est precisement ce qui
# manquait a l'ancienne version, posee trop tard par un service, et qui
# l'obligeait a armer un declencheur separe sur /dev/tty1.
install -Dm755 "$DIR/update.sh" "$ROOTFS/usr/local/sbin/osmo-sms.sh"
cat > "$ROOTFS/etc/profile.d/99-osmo-sms.sh" <<'EOF'
# 99-osmo-sms.sh - pose par build-iso.sh. Joue l'arrivee d'un SMS, une fois par
# demarrage. Source APRES 01-keyboard-setup.sh (ordre alphabetique).
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac      # session interactive seulement
[ -x /usr/local/sbin/osmo-sms.sh ] || return 0
# /run est un tmpfs que le noyau recree vide a chaque demarrage : l'animation se
# rejoue a chaque boot, mais pas a chaque tty ni a chaque "su -".
[ -e /run/osmo-sms.done ] && return 0
: > /run/osmo-sms.done
/usr/local/sbin/osmo-sms.sh
EOF
chmod +x "$ROOTFS/etc/profile.d/99-osmo-sms.sh"
echo -e "  ${GREEN}✓${NC} animation SMS a l'ouverture de session (99-osmo-sms.sh)"

# ── /usr/local/bin/osmo-update : la mise a jour, EN PLACE, par git ─────────
# [2026-08-27] L'ancien mecanisme n'etait pas une mise a jour, c'etait un
# remplacement : effacer /opt/GSM/osmo_egprs et /opt/GSM/osmo-egprs-web, recloner
# depuis GitHub, a chaque demarrage. Il fallait un reseau pour demarrer, ce qui
# tournait n'etait jamais ce que l'ISO portait, et tout ce qui avait ete pose
# dans un arbre disparaissait au boot suivant.
#
# Les trois depots partent maintenant dans l'image AVEC leur .git : il y a donc
# un HEAD auquel se comparer, et la mise a jour redevient ce qu'elle doit etre -
# un fetch et une avance rapide. Rien n'est efface, rien n'est reclone, et une
# machine sans reseau garde exactement ce avec quoi elle a ete gravee.
cat > "$ROOTFS/usr/local/bin/osmo-update" <<'OSMOUPD'
#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# osmo-update - met a jour, en place, les depots embarques dans l'image.
#
#   osmo-update              les trois depots
#   osmo-update qemu-src     un seul (osmo_egprs | osmo-egprs-web | qemu-src)
#   osmo-update --check      dit ce qui est en retard, n'ecrit rien
#   osmo-update --quiet      sans couleurs ni fioritures (journal, cron)
#   osmo-update --boot       mode demarrage : --quiet, journalise, sort toujours 0
#
# Ce qu'il ne fait PAS, deliberement : effacer un arbre, recloner un depot,
# installer un paquet. Une machine qui demarre n'a rien a aller chercher.
# ══════════════════════════════════════════════════════════════════════════════
set -u

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
CHECK=0; QUIET=0; BOOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1 ;;
        --quiet)   QUIET=1 ;;
        --boot)    BOOT=1; QUIET=1 ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "option inconnue : $1" >&2; exit 2 ;;
        *)         break ;;
    esac
    shift
done
[ "$QUIET" = "1" ] && { G=''; Y=''; R=''; C=''; B=''; N=''; }

# Au demarrage personne ne lit l'ecran : la sortie part dans le journal, et le
# code de retour ne doit jamais retarder ni bloquer multi-user.target.
if [ "$BOOT" = "1" ]; then
    exec >>/var/log/osmo-update.log 2>&1
    echo "===== osmo-update (boot) $(date '+%F %T') ====="
fi

[ "$(id -u)" -eq 0 ] || { echo "Root requis." >&2; exit 1; }

# nom|chemin - les chemins que cherchent deja start-direct.sh, le dashboard et
# environnement/paths.env. En changer un ici ne deplacerait pas ceux qui les lisent.
REPOS="osmo_egprs|/opt/GSM/osmo_egprs
osmo-egprs-web|/opt/GSM/osmo-egprs-web
qemu-src|/opt/GSM/qemu-src"

WANT="${1:-}"
rc=0; web_moved=0

while IFS='|' read -r name dir; do
    [ -n "$name" ] || continue
    [ -z "$WANT" ] || [ "$WANT" = "$name" ] || continue
    found=1
    printf "  ${B}%-16s${N} ${C}%s${N}\n" "$name" "$dir"

    if [ ! -d "$dir" ]; then
        printf "    ${R}✗${N} absent - l'image ne le portait pas\n"; rc=1; continue
    fi
    if [ ! -d "$dir/.git" ]; then
        # On ne reclone pas par-dessus : ce serait effacer un arbre dont on ne
        # sait pas ce qu'il contient. On le dit, et on passe.
        printf "    ${Y}⚠${N} pas de depot (.git absent) - laisse tel quel\n"; rc=1; continue
    fi

    br="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" || br=""
    [ -n "$br" ] || br=main

    # Un depot livre en --depth 1 est GREFFE : son unique commit n'a pas de
    # parent, donc rien de ce que le serveur renvoie n'a d'ancetre commun avec
    # lui. Le refetcher en --depth 1 garde cette propriete (et le depot reste
    # leger) ; un depot complet, lui, se fetch complet - sinon on lui ferait
    # perdre l'ancestralite qui permet justement l'avance rapide.
    if git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        fetch_ok=$(git -C "$dir" fetch --depth 1 --quiet origin "$br" 2>/dev/null && echo 1)
    else
        fetch_ok=$(git -C "$dir" fetch --quiet origin "$br" 2>/dev/null && echo 1)
    fi
    if [ -z "${fetch_ok:-}" ]; then
        printf "    ${Y}⚠${N} fetch impossible (reseau ?) - copie locale conservee\n"; rc=1; continue
    fi

    local_h="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    remote_h="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null)"
    if [ "$local_h" = "$remote_h" ]; then
        printf "    ${G}✓${N} deja a jour - %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        continue
    fi
    if [ "$CHECK" = "1" ]; then
        printf "    ${Y}→${N} en retard : %s -> %s\n" "${local_h:0:7}" "${remote_h:0:7}"
        continue
    fi

    # Trois cas, et un seul refus. Le refus porte sur le TRAVAIL LOCAL, jamais
    # sur l'historique : c'est la difference avec l'ancien "rm -rf puis clone",
    # qui effacait sans distinguer.
    if git -C "$dir" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null \
       && git -C "$dir" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
        # 1. Avance rapide : on est en retard sur la meme branche.
        printf "    ${G}✓${N} %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        [ "$name" = "osmo-egprs-web" ] && web_moved=1
    elif [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        # 2. Pas d'ancetre commun (depot greffe par --depth 1) mais arbre propre :
        #    il n'y a rien a perdre, on aligne sur le serveur.
        if git -C "$dir" reset --hard FETCH_HEAD >/dev/null 2>&1; then
            printf "    ${G}✓${N} aligne sur origin/%s - %s\n" "$br" "$(git -C "$dir" log -1 --format='%h %s')"
            [ "$name" = "osmo-egprs-web" ] && web_moved=1
        else
            printf "    ${Y}⚠${N} alignement impossible - arbre inchange\n"; rc=1
        fi
    else
        # 3. Des fichiers ont ete modifies ici : on ne touche a rien, on le dit.
        printf "    ${Y}⚠${N} modifications locales - rien n'a ete ecrase\n"
        printf "       a la main : ${C}git -C %s status${N}\n" "$dir"
        rc=1
    fi
done <<REPOEOF
$REPOS
REPOEOF

if [ -z "${found:-}" ]; then
    echo "depot inconnu : $WANT  (osmo_egprs | osmo-egprs-web | qemu-src)" >&2
    exit 2
fi

# Le dashboard tourne en service : un depot avance ne change rien tant que le
# demon fait tourner l'ancien server.js.
if [ "$web_moved" = "1" ]; then
    [ -f /opt/GSM/osmo-egprs-web/package.json ] && \
        (cd /opt/GSM/osmo-egprs-web && npm install --production >/dev/null 2>&1 || true)
    systemctl try-restart osmo-egprs-web >/dev/null 2>&1 || true
    printf "  ${G}✓${N} dashboard relance\n"
fi

[ "$BOOT" = "1" ] && exit 0
exit $rc
OSMOUPD
chmod +x "$ROOTFS/usr/local/bin/osmo-update"

# Au demarrage : apres le reseau, sans le bloquer. Type=oneshot + un ExecStart
# qui sort toujours 0 en mode --boot : une machine hors ligne demarre pareil.
cat > "$ROOTFS/etc/systemd/system/osmo-update.service" <<'EOF'
[Unit]
Description=osmo_egprs - mise a jour des depots embarques (git, en place)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/osmo-update --boot
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-update 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-update (/usr/local/bin, + service au demarrage : git fetch, jamais de reclone)"

# ── QEMU_BIN apres le reclone : build/qemu-system-arm dans l'arbre qemu-src ──
# [2026-08-27] Deux decisions justes, prises separement, se contredisent :
#
# L'arbre qemu-src part maintenant entier - .git et build/ compris - donc
# QEMU_BIN est resolu des la gravure, et ce service n'a rien a faire. Il est la
# pour le seul cas ou l'arbre perdrait son build/ : quelqu'un qui le reclone a
# la main, ou qui remplace /opt/GSM/qemu-src par un checkout frais. Sans build/,
# environnement/paths.env resout QEMU_BIN a un chemin inexistant et la pile
# s'arrete des le premier module :
#     [FAIL] Prerequisite checks (dépendances introuvables : QEMU_BIN)
# — alors que le binaire est la, dans /usr/local/bin.
#
# On recree donc le seul chemin que paths.env cherche, apres le reclone. Un lien
# symbolique, pas une copie : le binaire fait ~30 Mo et l'ISO tient en RAM.
# "build/" est la premiere ligne du .gitignore de qemu : le "git clean -fd" des
# synchronisations suivantes (wipe=0, incremental) ne l'efface pas - seul un
# clone frais le ferait, et ce service repasse a chaque demarrage.
cat > "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh" <<'QLINK'
#!/bin/bash
# osmo-qemu-link.sh - rend QEMU_BIN resolvable apres le reclone de qemu-src.
# Voir build-iso.sh, etape [6/9], pour le pourquoi.
set -u
SRC="${OSMO_QEMU_BIN:-/usr/local/bin/qemu-system-arm}"
TREE="${OSMO_QEMU_SRC:-/opt/GSM/qemu-src}"
LNK="$TREE/build/qemu-system-arm"

# Pas de binaire (image inter-STP) ou pas d'arbre (reclone impossible, reseau
# coupe) : il n'y a rien a relier, et ce n'est pas ce service qui le dira.
[ -x "$SRC" ] || { echo "osmo-qemu-link: $SRC absent - rien a faire"; exit 0; }
[ -d "$TREE" ] || { echo "osmo-qemu-link: $TREE absent - rien a faire"; exit 0; }

# Un VRAI build compile sur place gagne toujours : on ne remplace qu'un lien
# (le notre) ou un chemin vide.
if [ -e "$LNK" ] && [ ! -L "$LNK" ]; then
    echo "osmo-qemu-link: $LNK est un vrai fichier - laisse tel quel"
    exit 0
fi

mkdir -p "$TREE/build"
ln -sfn "$SRC" "$LNK"
echo "osmo-qemu-link: $LNK -> $SRC"
QLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-qemu-link.service" <<'EOF'
[Unit]
Description=osmo_egprs - QEMU_BIN dans l'arbre qemu-src (build/qemu-system-arm)
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-qemu-link.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-qemu-link 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-qemu-link (QEMU_BIN relie apres le reclone de qemu-src)"


# ── Marqueur de role : ce que CETTE image est ───────────────────────────────
# Lu par start-direct.sh et par la banniere. Sans lui, deux ISO issues de la
# meme chaine sont indiscernables une fois demarrees - et on lance le mauvais
# script sur la mauvaise machine.
{
    printf '# /etc/osmo-role - genere par build-iso.sh\n'
    printf 'OSMO_ROLE=%s\n' "$ISO_ROLE"
    [ -n "$ISO_NODE" ] && printf 'OSMO_WAN_NODE=%s\n' "$ISO_NODE"
    # Pour la meme raison que le role : deux ISO issues de la meme chaine sont
    # indiscernables une fois demarrees. Celle-ci n'a pas les arbres de
    # compilation de /opt/GSM - autant que la machine puisse le dire elle-meme
    # quand quelque chose y sera cherche en vain.
    printf 'OSMO_LITE=%s\n' "$ISO_LITE"
    printf 'OSMO_HUB_IP=%s\n' "$ISO_HUB_IP"
} > "$ROOTFS/etc/osmo-role"

# ── /etc/os-release : l'image se nomme elle-meme ────────────────────────────
# [2026-08-27] Les trois ISO se presentaient toutes comme "Ubuntu 22.04 LTS".
# /etc/osmo-role dit deja ce que l'image est, mais lui ne s'affiche nulle part :
# la banniere de login, `hostnamectl`, les rapports de bug et le tableau de bord
# lisent os-release. Sur trois machines demarrees cote a cote, rien ne
# distinguait le hub d'un noeud, ni le noeud complet de sa variante elaguee.
#
# ON NE TOUCHE QU'AUX CHAMPS D'AFFICHAGE. ID, VERSION_ID, VERSION_CODENAME et
# UBUNTU_CODENAME restent ceux d'Ubuntu : apt, add-apt-repository et la moitie
# des scripts de paquets s'en servent pour choisir leurs depots. Renommer ID
# casserait l'image bien au-dela de sa banniere.
# VARIANT / VARIANT_ID sont les champs prevus par os-release(5) pour exactement
# cette distinction ; IMAGE_ID / IMAGE_VERSION, ceux prevus pour une image
# construite. On les remplit plutot que d'inventer des noms a nous.
case "$ISO_ROLE" in
    interstp) OS_NAME="osmo-operator interstp"; OS_VARIANT_ID="interstp" ;;
    *)        if [ "$ISO_LITE" = "1" ]; then
                  OS_NAME="osmo-operator-lite"; OS_VARIANT_ID="operator-lite"
              else
                  OS_NAME="osmo-operator";      OS_VARIANT_ID="operator"
              fi ;;
esac
# Le numero de noeud fait partie de l'identite quand il est fige dans l'image :
# c'est la seule chose qui distingue osmo-operator-1.iso de osmo-operator-2.iso.
OS_PRETTY="$OS_NAME"
[ -n "$ISO_NODE" ] && OS_PRETTY="$OS_NAME (noeud $ISO_NODE)"

# /etc/os-release est un lien vers ../usr/lib/os-release : on ecrit la cible et
# on laisse le lien tranquille - le remplacer par un fichier ferait diverger les
# deux chemins, que differents outils lisent indifferemment.
_osrel="$ROOTFS/usr/lib/os-release"
sed -i -e '/^NAME=/d' -e '/^PRETTY_NAME=/d' \
       -e '/^VARIANT=/d' -e '/^VARIANT_ID=/d' \
       -e '/^IMAGE_ID=/d' -e '/^IMAGE_VERSION=/d' \
       -e '/^HOME_URL=/d' -e '/^SUPPORT_URL=/d' -e '/^BUG_REPORT_URL=/d' \
       "$_osrel"
{
    printf 'NAME="%s"\n'          "$OS_NAME"
    printf 'PRETTY_NAME="%s"\n'   "$OS_PRETTY"
    printf 'VARIANT="%s"\n'       "$OS_PRETTY"
    printf 'VARIANT_ID="%s"\n'    "$OS_VARIANT_ID"
    printf 'IMAGE_ID="%s"\n'      "$OS_NAME"
    printf 'IMAGE_VERSION="%s"\n' "$LABEL"
    printf 'HOME_URL="https://github.com/bbaranoff/osmo_egprs"\n'
    printf 'SUPPORT_URL="https://github.com/bbaranoff/osmo_egprs"\n'
    printf 'BUG_REPORT_URL="https://github.com/bbaranoff/osmo_egprs/issues"\n'
} >> "$_osrel"
echo -e "  ${GREEN}✓${NC} os-release : ${CYAN}${OS_PRETTY}${NC}"

# ── Asterisk : UN SEUL proprietaire, et c'est run_modules/19-asterisk.sh ────
# [2026-08-27] Le paquet asterisk installe son unite `enabled` : systemd
# demarrait donc un Asterisk au boot, pendant que 19-asterisk.sh lancait le sien
# en direct. Deux proprietaires pour un seul /etc/asterisk et une seule socket
# /var/run/asterisk/asterisk.ctl - la console finissait par ne plus repondre a
# personne et la pile s'arretait sur "console Asterisk : toujours pas pret".
# Le module ecarte deja systemd a chaque demarrage ; on le fait AUSSI ici pour
# que le premier boot d'une ISO neuve parte propre, sans le coup de balai.
chroot "$ROOTFS" systemctl disable asterisk >/dev/null 2>&1 || true
echo -e "  ${GREEN}✓${NC} asterisk.service desactive - le PBX est lance par ${CYAN}19-asterisk.sh${NC}"

if [ "$ISO_ROLE" = "interstp" ]; then
    # Le hub, lui, DOIT demarrer seul : les noeuds s'attachent a lui au boot, et
    # un hub qu'il faut lancer a la main transforme un demarrage simultane en
    # course perdue d'avance.
    cat > "$ROOTFS/etc/systemd/system/osmo-interstp.service" <<EOF
[Unit]
Description=osmo_egprs inter-STP - hub SS7 du WAN (PC 0.0.0)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=forking
PIDFile=/run/osmo-interstp.pid
ExecStart=/opt/GSM/osmo_egprs/start-interstp.sh --ip ${ISO_HUB_IP}
ExecStop=/opt/GSM/osmo_egprs/start-interstp.sh --stop
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    chroot "$ROOTFS" systemctl enable osmo-interstp 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} osmo-interstp.service - hub lance au demarrage sur ${CYAN}${ISO_HUB_IP}${NC}"
fi


# Autologin root
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Service web dashboard
cat > "$ROOTFS/etc/systemd/system/osmo-egprs-web.service" <<'EOF'
[Unit]
Description=osmo_egprs Web Dashboard (native)
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/GSM/osmo-egprs-web
ExecStart=/usr/bin/node /opt/GSM/osmo-egprs-web/server.js --verbose
Restart=always
RestartSec=5
Environment=HTTP_PORT=8080
# Mode natif (start-direct.sh) : VTY en telnet direct sur 127.0.0.1, pas de docker.
# Pour le mode docker (start.sh + conteneurs), mettre OSMO_NATIVE=0.
Environment=OSMO_NATIVE=1
Environment=OSMO_OP_IDS=1
Environment=CONTAINER_PREFIX=osmo-operator-
[Install]
WantedBy=multi-user.target
EOF
# Le hub n'a ni VTY d'operateur a afficher ni radio a tracer : le tableau de
# bord n'aurait rien a montrer. On ne l'active pas.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# ── Audio : PulseAudio systeme (sink gsm_audio) au boot ────────────────────
# Chaine : osmo-gapk → ALSA gsm_out → sink null gsm_audio → monitor → loopback
# → carte. system.pa autorise l'acces anonyme + prepare le sink ; le service
# lance le demon au boot (ensure_pulse de start-direct.sh devient un no-op).
if [ -f "$ROOTFS/etc/pulse/system.pa" ]; then
    sed -i 's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' \
        "$ROOTFS/etc/pulse/system.pa"
    # [2026-08-14] gsm_mic MANQUAIT ICI. Seul gsm_audio etait declare, alors que
    # lib/audio.sh traite les deux sinks comme SOLIDAIRES (GSM_SINKS) et que
    # configs/asound.conf fait pointer `pcm.gsm_in` sur `gsm_mic.monitor`.
    # Consequence mesuree dans la VM : `pactl list short sources` sans gsm_mic
    # → gapk_io n'initialise pas la capture et ABANDONNE LES DEUX SENS
    #   (pq_alsa.c:168 "Couldn't init ALSA device 'gsm_in'" puis
    #    gapk_io.c:468 "Failed to initialize GAPK I/O")
    # → appel parfaitement etabli et TOTALEMENT MUET. Les deux sinks doivent
    # etre declares ensemble, ici, comme le dit deja lib/audio.sh.
    for _s in "gsm_audio:GSM_Audio" "gsm_mic:GSM_Mic"; do
        _n="${_s%%:*}"; _d="${_s##*:}"
        grep -q "sink_name=${_n}\b" "$ROOTFS/etc/pulse/system.pa" || \
            echo "load-module module-null-sink sink_name=${_n} format=s16le rate=8000 channels=1 sink_properties=device.description=${_d}" \
            >> "$ROOTFS/etc/pulse/system.pa"
    done
fi
# [2026-08-14] /etc/asound.conf N'ETAIT DEPLOYE NULLE PART sur l'ISO. Il l'est
# par ensure_pulse() de lib/audio.sh - mais lib/audio.sh n'est source par
# personne (son appelant annonce, run_modules/25-audio.sh, n'existe pas). Sans
# ce fichier les PCM `gsm_out`/`gsm_in` que `mobile` ouvre n'existent pas, donc
# la voix TCH n'atteint jamais gsm_audio. Verifie absent dans la VM au boot.
if [ -f "$DIR/configs/asound.conf" ]; then
    cp -f "$DIR/configs/asound.conf" "$ROOTFS/etc/asound.conf"
    echo -e "  ${GREEN}✓${NC} /etc/asound.conf (PCM gsm_out/gsm_in → sinks PulseAudio)"
fi
cat > "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh" <<'ACHAIN'
#!/bin/bash
# osmo-audio-chain.sh - ferme la chaine audio locale apres le demarrage de
# PulseAudio. Appele en ExecStartPost par osmo-pulse.service.
#   1. /etc/asound.conf present (PCM gsm_out/gsm_in)
#   2. les DEUX null-sinks gsm_audio + gsm_mic charges
#   3. le module-loopback gsm_audio.monitor → carte son
# Sans (2), gapk_io abandonne LES DEUX SENS ; sans (3), la voix descendante est
# jetee par le null-sink. Toujours exit 0 : l'audio ne doit jamais empecher la
# pile de monter. AUDIO=0 ou AUDIO_LOCAL_LOOPBACK=0 neutralisent.
set -u
for r in /opt/GSM/osmo_egprs /etc/osmocom/osmo_egprs; do
    [ -x "$r/scripts/audio-chain.sh" ] && exec "$r/scripts/audio-chain.sh" "${1:-30}"
done
exit 0
ACHAIN
chmod +x "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh"

cat > "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh" <<'PLINK'
#!/bin/sh
# osmo-pulse-link.sh - rend le PulseAudio SYSTEME visible des applications qui
# cherchent un socket par utilisateur, snaps compris.
#
# En mode systeme, PulseAudio n'ecoute que sur /run/pulse/native. Les clients,
# eux, regardent $XDG_RUNTIME_DIR/pulse/native (soit /run/user/<uid>/pulse) -
# et c'est ce chemin que snapd monte dans le bac a sable. Sans lui, un snap ne
# voit AUCUN peripherique : Firefox rendait « NotFoundError » sur le micro,
# pendant que pactl listait deux entrees en RUNNING.
#
# Toujours exit 0 : l'audio ne doit jamais empecher la pile de monter.
set -u
for d in /run/user/*; do
    [ -d "$d" ] || continue
    mkdir -p "$d/pulse" 2>/dev/null || continue
    ln -sfn /run/pulse/native "$d/pulse/native" 2>/dev/null || true
done
exit 0
PLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-pulse.service" <<'EOF'
[Unit]
Description=osmo_egprs PulseAudio system daemon (GSM audio)
After=sound.target
[Service]
Type=forking
ExecStart=/usr/bin/pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 --log-target=file:/var/log/osmocom/pulse-system.log
ExecStartPre=/bin/mkdir -p /var/log/osmocom /var/run/pulse
# ── LE SOCKET LA OU LES APPLICATIONS LE CHERCHENT ───────────────────────────
# PulseAudio tourne ici en mode SYSTEME : il n'ecoute que sur /run/pulse/native.
# Or une application cherche $XDG_RUNTIME_DIR/pulse/native, et c'est ce
# chemin-la - et lui seul - que snapd monte dans le bac a sable d'un snap.
# Chromium etant un snap (voir osmo-chromium-snap.service), il ne trouverait aucun
# serveur audio, enumerait ZERO entree, et getUserMedia rendait
# « NotFoundError — The object can not be found here ». Le diagnostic partait
# invariablement sur une permission micro refusee, alors que la machine a deux
# entrees bien reelles et que Chrome, non confine, capturait au meme instant.
# Un lien suffit ; il est pose par le demon lui-meme, donc il survit a un
# restart du service.
ExecStartPost=/usr/local/sbin/osmo-pulse-link.sh
# [2026-08-14] Sans ceci, gsm_audio (module-null-sink) n'a AUCUN consommateur :
# la voix descendante y est jetee par construction, la sortie ALSA reste
# SUSPENDED et l'appel est muet. Le loopback est le maillon qui manquait - il
# est pose ici, par le demon lui-meme, donc il survit a un restart du service.
# Non fatal (le script sort 0 quoi qu'il arrive) : l'audio ne doit jamais
# empecher la pile de monter. AUDIO_LOCAL_LOOPBACK=0 le neutralise.
# Passe par un wrapper /usr/local/sbin (meme patron que osmo-sms.sh) : une
# directive `ExecStartPost=/bin/sh -c "... \" ... \" ..."` avec guillemets
# imbriques est ACCEPTEE par `systemctl cat` mais rejetee par le parseur -
# `systemctl show -p ExecStartPost` revient alors VIDE et rien ne s'execute.
ExecStartPost=/usr/local/sbin/osmo-audio-chain.sh 30
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# Idem pour l'audio : le hub ne porte aucun appel, il route de la signalisation.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-pulse 2>/dev/null||true

# Modules noyau
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Variables d'environnement
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# bashrc pour root
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
# Active par defaut l'environnement python (gr-gsm + bridges) utilise par
# /opt/GSM/osmo_egprs/start-direct.sh. VIRTUAL_ENV_DISABLE_PROMPT pour garder le PS1.
export VIRTUAL_ENV_DISABLE_PROMPT=1
[ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
# coeur.env est pose dans /etc/osmocom pour survivre au reclone de boot, mais
# environment/load.env ne va le chercher QUE dans son propre repertoire : sorti
# de l'arbre, personne ne le lit. On le charge donc ici, ou les deux arbres en
# heritent - l'arbre fige /opt/GSM/osmo_egprs, qui n'embarque pas environment/, et
# l'arbre reclone /opt/GSM/osmo_egprs, ou il ne survivrait pas. set -a : sans
# export, la valeur ne franchirait pas le fork vers start-direct.sh. L'idiome
# ":=" du fichier laisse gagner N_MS=3 ./start-direct.sh.
if [ -f /etc/osmocom/coeur.env ]; then set -a; . /etc/osmocom/coeur.env; set +a; fi
alias faketrx='python3 /opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py'
# Trois annonces designaient trois arbres differents. Le MOTD et le message de
# login pointent /opt/GSM/osmo_egprs (l'arbre fige, present meme sans reseau) ;
# l'alias visait /opt/GSM/osmo_egprs (l'arbre reclone au demarrage). Les deux
# fonctionnent, mais un utilisateur qui suit l'un puis l'autre ne travaille pas
# au meme endroit. On prend le premier chemin qui existe, dans l'ordre ou ils
# sont les plus complets.
alias osmo-lab='cd /opt/GSM/osmo_egprs; ./start-direct.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/etc/osmocom/status.sh status'
export PATH="$HOME/.local/bin:$PATH"

### calypso-prompt ###
export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️ # '
### end calypso-prompt ###
BASH

# Message du jour - banniere couleur + boite alignee. Contenu de la boite en
# ASCII (pas de ←/e/• multi-octets) + padding printf => bords parfaitement
# alignes. Genere a chaud pour injecter les couleurs ANSI dans /etc/motd.
{
  B=$'\033[1;36m'; T=$'\033[1;37m'; G=$'\033[1;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
  W=58
  printf '\n%b' "$B"
  cat <<'LOGO'
    ___  ___ _ __ ___   ___    ___  __ _ _ __  _ __ ___
   / _ \/ __| '_ ` _ \ / _ \  / _ \/ _` | '_ \| '__/ __|
  | (_) \__ \ | | | | | (_) ||  __/ (_| | |_) | |  \__ \
   \___/|___/_| |_| |_|\___/  \___|\__, | .__/|_|  |___/
                                   |___/|_|
LOGO
  printf '%b' "$N"
  printf "${B}  ╔"; printf '═%.0s' $(seq 1 $W); printf "╗${N}\n"
  printf "${B}  ║${N} ${T}%-*s${N} ${B}║${N}\n" $((W-2)) "GSM / EGPRS  Multi-PLMN  Live System"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "SS7/SIGTRAN  -  Osmocom  -  Calypso/QEMU"
  printf "${B}  ╠"; printf '═%.0s' $(seq 1 $W); printf "╣${N}\n"
  # Le chemin annonce ici est celui de l'arbre FIGE, comme le message de login
  # et comme le lien osmo-start-direct. Il nommait /opt/GSM/osmo_egprs, que
  # osmo-update.service effacait et reclonait au demarrage : sans reseau au boot,
  # la premiere chose que lisait l'utilisateur designait un arbre qui pouvait ne
  # pas etre la. Le reclone a disparu, l'arbre fige reste - il ne depend de rien.
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "/opt/GSM/osmo_egprs/start-direct.sh"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "    -> lance le lab Calypso/QEMU (A5/1)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "Dashboard web  ->  http://<vm-ip>:8080"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "FFT spectres   ->  http://<vm-ip>:8081"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "Wiki / docs        ->  pl4y.store"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "ssh root@<vm-ip>   -> mot de passe : osmo"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "loadkeys fr   -> changer le clavier (apres boot)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "osmo-update   -> met a jour les depots (git en place)"
  printf "${B}  ╚"; printf '═%.0s' $(seq 1 $W); printf "╝${N}\n\n"
} > "$ROOTFS/etc/motd"

# Mot de passe root = "osmo" (autologin console + login SSH). On NE vide PAS le
# mot de passe (sinon sshd refuse le login root).
echo 'root:osmo' | chroot "$ROOTFS" chpasswd 2>/dev/null || true

# ── Espace writable du live : /dev/shm + /tmp, en POURCENTAGE de la RAM ─────
# Le live boote en 'toram' → racine = overlay tmpfs (RAM). Les gros writers de la
# stack sont les cfiles I/Q dans /dev/shm (FFT/record, plusieurs centaines de Mo)
# et /tmp. systemd applique ces entrees au boot.
#
# POURQUOI PLUS 2 Go EN DUR
# Ces caps ne reservent rien, mais ils AUTORISENT : 2 + 2 Go, sur une machine
# ou le squashfs occupe deja ~2,5 Go de RAM et ou la racine elle-meme est un
# tmpfs, c'est plus que ce dont dispose une VM de 8 Go. Deux writers un peu
# gourmands suffisaient alors a saturer la memoire - et le symptome n'est pas
# "tmpfs plein" mais une machine exsangue : "No space left on device" sur la
# racine, puis un sshd qui n'arrive meme plus a envoyer sa banniere.
#
# En pourcentage, le plafond suit la taille de la machine : 20 % + 15 % laissent
# toujours les deux tiers de la RAM au squashfs, a la racine et aux processus.
# Une VM a 16 Go y gagne autant qu'une VM a 8 Go cesse de se noyer.
# Idempotent + anti-doublon : on purge d'abord toute entree tmpfs /tmp ou /dev/shm
# preexistante (y compris la variante 'nosuid,nodev' sans size=) et l'ancien
# commentaire de bloc, PUIS on (re)ecrit le bloc canonique size en pourcentage. Garantit
# exactement une entree /tmp et une entree /dev/shm dans le fstab du squashfs.
touch "$ROOTFS/etc/fstab"
sed -i -E \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]/d' \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/dev\/shm[[:space:]]/d' \
    -e '/^# osmo_egprs live - espace writable/d' \
    "$ROOTFS/etc/fstab"
# /dev/shm : sizing via fstab (sans risque de doublon generateur).
cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
# osmo_egprs live - espace writable (cfiles I/Q FFT)
tmpfs   /dev/shm   tmpfs   defaults,nosuid,nodev,size=20%   0 0
FSTAB
# /tmp : PAS dans fstab. Une entree fstab /tmp entre en collision avec l'unite
# systemd tmp.mount -> "systemd-fstab-generator: tmp.mount already exists,
# Duplicate entry in /etc/fstab" (generateur en exit 1) ; et l'ancien update.sh
# la reinjectait au boot, ce qui obligeait a la retirer apres coup. On gere /tmp
# en natif systemd via un drop-in size=15% : une seule source, zero doublon -
# et plus rien, au demarrage, qui reecrive fstab.
mkdir -p "$ROOTFS/etc/systemd/system/tmp.mount.d"
cat > "$ROOTFS/etc/systemd/system/tmp.mount.d/size.conf" <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=15%
EOF
chroot "$ROOTFS" systemctl enable tmp.mount 2>/dev/null || true

# ── Ce qui remplit la RAM : les ECRITURES DE LA PILE ────────────────────────
# En 'toram' la racine est un overlay tmpfs : TOUT ce qui s'ecrit a l'execution
# reste en RAM, rien n'atteint un disque. Le squashfs y est deja recopie, /tmp
# et /dev/shm en reservent 2 Go chacun - le reste, quelques Go, est tout ce dont
# dispose la racine.
#
# Trois writers non bornes suffisaient a la remplir, et le symptome n'apparait
# qu'apres des heures : "No space left on device" sur une machine qui n'a
# pourtant aucun disque plein.
#   1. le journal systemd, sans plafond ;
#   2. /var/log/osmocom/*.log - la pile journalise en 'filter all 1', et mobile
#      tourne avec une vingtaine de categories de debug ;
#   3. les captures pcap GSMTAP, ecrites en continu et sans limite de taille.
# On les borne ici, dans l'image : un cap pose au build vaut pour toutes les VM,
# alors qu'un nettoyage manuel est a refaire apres chaque boot.

# 1. Journal : volatile (il est de toute facon perdu au reboot d'un live) et
#    plafonne. Sans RuntimeMaxUse, journald s'autorise 10 % de la RAM.
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
# osmo_egprs live : la racine est en RAM, le journal ne doit pas la manger.
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeKeepFree=256M
EOF

# 2. Logs Osmocom : rotation a la TAILLE, pas a la date - une pile bavarde
#    remplit en une heure ce qu'une rotation quotidienne ne verrait jamais.
#    copytruncate : les demons gardent leur descripteur ouvert ; sans lui la
#    rotation leur laisse un fichier supprime, et l'espace n'est pas rendu.
mkdir -p "$ROOTFS/etc/logrotate.d"
cat > "$ROOTFS/etc/logrotate.d/osmocom" <<'EOF'
/var/log/osmocom/*.log {
    size 32M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
# logrotate.timer ne passe qu'une fois par jour : trop tard pour un tmpfs.
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.service" <<'EOF'
[Unit]
Description=osmo_egprs - rotation des journaux Osmocom (racine en RAM)
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/osmocom --state /run/osmo-logrotate.state
EOF
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.timer" <<'EOF'
[Unit]
Description=osmo_egprs - rotation des journaux Osmocom toutes les 15 min
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
chroot "$ROOTFS" systemctl enable osmo-logrotate.timer 2>/dev/null || true

# 3. Captures pcap : purge de celles de plus d'une heure. La capture GSMTAP
#    tourne en continu ; elle sert a regarder ce qui vient de se passer, pas a
#    constituer un historique - qu'aucun live ne pourrait de toute facon garder.
mkdir -p "$ROOTFS/etc/tmpfiles.d"
cat > "$ROOTFS/etc/tmpfiles.d/osmo-captures.conf" <<'EOF'
# osmo_egprs : les captures vivent en RAM, on ne les garde pas plus d'une heure.
d /run/user/0/osmo-nitb/captures 0755 root root 1h
EOF

# 3bis. Le ring, plutot qu'un fichier qui gonfle
# Purger toutes les heures ne protege de rien : entre deux passages, UNE
# capture continue peut a elle seule remplir la RAM - et sur un lien charge,
# c'est l'affaire de quelques minutes, pas d'une nuit. Un fichier unique en -w
# croit sans limite ; -C <Mo> -W <n> lui substitue un ANNEAU de n fichiers qui
# se recyclent : la capture ne s'arrete jamais, l'empreinte reste bornee.
#
# Par un wrapper plutot qu'en corrigeant les appelants : la capture GSMTAP est
# lancee depuis le dashboard web (autre depot, clone au build) et depuis des
# outils qui ne vivent pas dans ce depot-ci. Un wrapper vaut pour tous, y
# compris ceux qu'on ajoutera. /usr/local/bin precede /usr/bin dans le PATH :
# l'appel "tcpdump" passe par lui sans que rien n'ait a etre reecrit.
#
# Il ne force rien quand l'appelant a deja choisi (-C ou -W presents), et sans
# -w il n'y a rien a borner.
cat > "$ROOTFS/usr/local/bin/tcpdump" <<'TCPDUMPEOF'
#!/bin/sh
# tcpdump - wrapper osmo_egprs : impose un anneau aux captures sur fichier.
#
# La racine du live est un tmpfs : une capture non bornee finit par remplir la
# RAM, et l'erreur ("No space left on device") tombe des heures plus tard, sur
# une machine qui n'a pourtant aucun disque plein.
#
# DEUX PIEGES, DEUX PARADES
#  -Z root : avec -C/-W, tcpdump cree les membres suivants de l'anneau APRES
#            avoir abandonne ses privileges (utilisateur "tcpdump"). Sans -Z il
#            echoue des le premier : "Permission denied" - et aucune capture.
#            Sans -C il ouvrait le fichier AVANT, d'ou un fonctionnement qui ne
#            cassait qu'en ajoutant l'anneau.
#  lien    : avec -C/-W, tcpdump n'ecrit pas le nom demande mais numerote les
#            membres (capture.pcap0, .pcap1...). Le nom exact n'existe jamais,
#            et l'appelant qui l'attend conclut a un echec. On maintient donc
#            <nom exact> -> membre courant : la barriere le suit, qui ouvre le
#            fichier lit la capture en cours, et rien n'a a etre reecrit.
#
# Reglable : OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump

has_w=0; has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Rien a borner, ou l'appelant a deja choisi son anneau : on s'efface.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Le veilleur du lien. Lance AVANT l'exec : apres, ce processus EST tcpdump.
# $$ reste le meme a travers l'exec, donc il suit exactement sa vie et s'arrete
# avec lui - aucun processus orphelin a nettoyer.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
TCPDUMPEOF
chmod +x "$ROOTFS/usr/local/bin/tcpdump"

# ── Purge complete a chaque relance ─────────────────────────────────────────
# Les caps ci-dessus empechent la derive PENDANT une session ; celui-ci repart
# d'une racine propre A CHAQUE DEMARRAGE. Sur un live c'est sans perte : ces
# fichiers ne survivraient pas au reboot de toute facon. Avec persistance, en
# revanche, ils s'accumuleraient d'un boot a l'autre jusqu'a remplir le medium -
# c'est precisement le cas ou la purge devient indispensable.
#
# Avant la pile (Before=osmo-*.service) : purger APRES le demarrage effacerait
# les journaux de la session en cours, et le premier incident serait invisible.
cat > "$ROOTFS/usr/local/sbin/osmo-purge.sh" <<'PURGEEOF'
#!/bin/bash
# osmo-purge.sh - repart d'une racine propre. Appele au boot par osmo-purge.service.
# Ne touche NI aux configs (/etc/osmocom), NI aux bases (HLR) : seulement ce qui
# se regenere - journaux, captures, fichiers de travail.
set -u

purge_dir() {   # $1=repertoire  $2=motif
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f -name "$2" -delete 2>/dev/null || true
}

# Journaux de la pile
purge_dir /var/log/osmocom '*.log'
purge_dir /var/log/osmocom '*.log.*'
purge_dir /var/log/osmocom '*.gz'

# Captures pcap (GSMTAP et autres)
rm -rf /run/user/0/osmo-nitb/captures/* 2>/dev/null || true
purge_dir /var/log/osmocom '*.pcap'
find /tmp /var/tmp -maxdepth 2 -type f -name '*.pcap*' -delete 2>/dev/null || true

# Fichiers de travail : I/Q FFT (plusieurs centaines de Mo piece)
find /dev/shm -maxdepth 1 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true
# Les MEMES fichiers HORS /dev/shm - ce sont eux qui ont rempli la RAM de la VM
# (4,6 Go mesures). Le mode pont ecrit /root/record.cfile et /root/record_ul.cfile
# en continu et empile /root/osmo-rec/*.cfile jusqu'a son propre plafond de 64 Go ;
# sur un live la racine EST un tmpfs, donc ce plafond n'en est pas un. Ne purger
# que /dev/shm laissait passer la totalite de ce qui se remplit vraiment.
find /root /tmp /var/tmp -maxdepth 2 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true

# Repertoire d'execution du live, recree par la pile au demarrage
rm -rf /run/user/0/osmo-nitb/logs/* 2>/dev/null || true

# Journal systemd volatile
command -v journalctl >/dev/null 2>&1 && journalctl --rotate --vacuum-time=1s >/dev/null 2>&1

exit 0
PURGEEOF
chmod +x "$ROOTFS/usr/local/sbin/osmo-purge.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-purge.service" <<'EOF'
[Unit]
Description=osmo_egprs - purge des journaux, captures et fichiers de travail
DefaultDependencies=no
After=local-fs.target
Before=osmo-stp.service osmo-interstp.service osmo-msc.service osmo-bsc.service
Before=osmo-egprs-web.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-purge.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-purge.service 2>/dev/null || true

# SSH : autorise le login root par mot de passe + active le service au boot.
if [ -f "$ROOTFS/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
        "$ROOTFS/etc/ssh/sshd_config"
    grep -q '^PermitRootLogin yes' "$ROOTFS/etc/ssh/sshd_config" || \
        echo 'PermitRootLogin yes' >> "$ROOTFS/etc/ssh/sshd_config"
fi
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# ── Clavier : fige DANS l'image, plus demande au premier boot ───────────────
# Le choix se fait au debut de cette construction (voir "LES QUESTIONS"). Ici on
# ne fait que l'ecrire. L'ancienne version posait la question dans
# /etc/profile.d au premier login : chaque machine du banc s'arretait alors sur
# un menu, et une VM demarree sans console attendait une reponse que personne
# n'allait donner.
cat > "$ROOTFS/etc/default/keyboard" <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${OSMO_ISO_KB}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
chroot "$ROOTFS" setupcon --force 2>/dev/null || true
chroot "$ROOTFS" dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

# Ce qui reste au login : le rappel, qui n'attend rien.
# La commande DEPEND du role : le hub n'a pas de coeur GSM a demarrer, et
# start-direct.sh y chercherait un BSC, un MSC, une BTS qui n'existent pas.
# Lui dicter start-direct.sh, c'est envoyer droit dans une erreur.
if [ "$ISO_ROLE" = "interstp" ]; then
    OSMO_START_HINT='Pour demarrer le hub SS7 : /opt/GSM/osmo_egprs/start-interstp.sh'
    OSMO_START_HINT2='  (etat des noeuds attaches : ./start-interstp.sh --status)'
else
    OSMO_START_HINT='Pour demarrer la stack : /opt/GSM/osmo_egprs/start-direct.sh --node N'
    OSMO_START_HINT2='  (N de 1 a 9 : il fixe les point codes 1.<N>1.x du noeud)'
fi
cat > "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh" <<KBSCRIPT
#!/bin/bash
[ "\$(id -u)" -ne 0 ] && return 0
[ -n "\${OSMO_DISCLAIMER_SHOWN:-}" ] && return 0
export OSMO_DISCLAIMER_SHOWN=1
echo ""
echo -e "  \033[1;33mDisclaimer\033[0m - banc d'essai GSM/SS7 Osmocom."
echo -e "  A n'utiliser que sur un reseau radio \033[1mISOLE\033[0m (cage/attenuateur) ou"
echo -e "  sur une bande sous licence : emettre sur le spectre public est illegal."
echo -e "  Aucun service Osmocom n'est lance automatiquement sur cette ISO."
echo -e "  \033[1;33m${OSMO_START_HINT}\033[0m"
echo -e "  \033[0;36m${OSMO_START_HINT2}\033[0m"
echo -e "  clavier : \033[1;32m\$(awk -F\\" '/^XKBLAYOUT/{print \$2}' /etc/default/keyboard 2>/dev/null)\033[0m  \033[0;36m(changer : osmo-keyboard)\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh"
rm -f "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"

# Le choix du clavier reste offert - mais QUAND ON LE DEMANDE. C'est le meme
# menu qu'avant ; ce qui change, c'est qu'il ne s'interpose plus entre le login
# et le shell : une VM sans console ne peut plus rester bloquee dessus.
cat > "$ROOTFS/usr/local/bin/osmo-keyboard" <<'KBCMD'
#!/bin/bash
# osmo-keyboard - change la disposition clavier du systeme, a la demande.
[ "$(id -u)" -ne 0 ] && { echo "Root requis."; exit 1; }

if [ -n "$1" ]; then
    KB_LAYOUT="$1"
else
    echo ""
    echo -e "\033[1;36m== Configuration clavier ==\033[0m"
    echo "  1) fr    2) us    3) de    4) es    5) it"
    echo "  6) pt    7) gb    8) be    9) ch    0) autre"
    echo ""
    read -rp "  Choix [1] : " KB_CHOICE
    case "${KB_CHOICE:-1}" in
        1|"") KB_LAYOUT="fr" ;;
        2) KB_LAYOUT="us" ;;  3) KB_LAYOUT="de" ;;
        4) KB_LAYOUT="es" ;;  5) KB_LAYOUT="it" ;;
        6) KB_LAYOUT="pt" ;;  7) KB_LAYOUT="gb" ;;
        8) KB_LAYOUT="be" ;;  9) KB_LAYOUT="ch" ;;
        0) read -rp "  Layout (fr, us, ru, ar...) : " KB_LAYOUT
           KB_LAYOUT="${KB_LAYOUT:-us}" ;;
        *) KB_LAYOUT="fr" ;;
    esac
fi

loadkeys "$KB_LAYOUT" 2>/dev/null || true
cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true
echo -e "  \033[1;32mClavier : ${KB_LAYOUT}\033[0m   (sans persistance, revient au reboot)"
KBCMD
chmod +x "$ROOTFS/usr/local/bin/osmo-keyboard"
# ══════════════════════════════════════════════════════════════════════════════
# Etape 8d : comptes, session, installeur - TOUT CE QUI PORTE DES APOSTROPHES
# ══════════════════════════════════════════════════════════════════════════════
# Ecrit ICI et pas dans le chroot de l etape 8 : ce chroot est un bash -c en
# QUOTES SIMPLES. Une apostrophe de plus et tout ce qui suit change de sens -
# et l erreur ne se voit qu au build suivant, sur une ligne sans rapport. Les
# configurations Calamares, les sudoers et les unites systemd en sont pleins.
# On ecrit donc dans "$ROOTFS" directement, avec le quoting normal du script.
echo -e "${GREEN}[8d/9] Comptes, session et installeur...${NC}"

# ── LE MODELE DE COMPTES ────────────────────────────────────────────────────
# root est le compte de TRAVAIL : le banc se pilote en root (start-direct.sh,
# les VTY, tcpdump, les netns), et tout le depot le suppose. La session s ouvre
# donc sur root, et les terminaux qu on y ouvre sont root sans rien demander.
#
# osmocom est un SECOND compte, non privilegie, sudoer - le bac a sable pour ce
# qui n a pas besoin des pleins pouvoirs : un navigateur, une session de bureau
# ordinaire. On y va EXPLICITEMENT (se deconnecter, le choisir dans GDM, ou
# "su - osmocom"), jamais par defaut.
#
# CE QUE CE N EST PLUS. Ce compte a longtemps ete un ALIAS D UID 0
# (usermod -o -u 0 osmocom) : un compte qui portait un nom d utilisateur
# ordinaire et les pleins pouvoirs, ce qui est le pire des deux mondes - on
# croit travailler sans privileges et on est root. C etait aussi la raison pour
# laquelle Chromium refusait de demarrer avec son bac a sable. Ici, osmocom est
# un vrai compte non privilegie, avec son propre UID.
chroot "$ROOTFS" bash -c "
set -u
id -u osmocom >/dev/null 2>&1 || useradd -m -s /bin/bash -c 'Compte osmocom (non privilegie)' osmocom
echo 'osmocom:osmo' | chpasswd
echo 'root:osmo'    | chpasswd
passwd -u root >/dev/null 2>&1 || true
for g in sudo adm dialout audio video plugdev netdev cdrom; do
    getent group \$g >/dev/null && usermod -aG \$g osmocom
done
" 2>/dev/null || echo -e "  ${YELLOW}!${NC} creation des comptes incomplete"
echo -e "  ${GREEN}✓${NC} comptes : ${CYAN}root${NC} (travail, mdp osmo) et ${CYAN}osmocom${NC} (non privilegie, sudoer, mdp osmo)"

# ── LA CONSOLE OUVRE SUR ROOT ───────────────────────────────────────────────
# Sur la cle live il n y a personne a authentifier : demander un mot de passe
# sur tty1 ne protege rien (qui tient le medium tient la machine) et empeche
# juste de travailler. --noclear garde a l ecran les messages du demarrage,
# qui sont souvent la seule trace d un module qui a echoue.
install -d "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/10-autologin-root.conf" <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTY
install -d "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin-root.conf" <<'GETTYS'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
GETTYS
echo -e "  ${GREEN}✓${NC} tty1 et console serie : ouverture automatique sur ${CYAN}root${NC}"

# ── LE BUREAU AUSSI ─────────────────────────────────────────────────────────
# L etape 8 pose deja AutomaticLogin=root dans /etc/gdm3/custom.conf. On le
# reecrit ici sans condition : cette etape tourne meme quand ISO_DESKTOP vaut 0
# (le fichier est alors sans effet, GDM n est pas installe), et surtout elle
# garantit que le reglage est le meme des deux cotes - la cle live et le
# systeme installe, ou c est shellprocess-osmo.conf qui l ecrit.
if [ -d "$ROOTFS/etc/gdm3" ] || [ "${ISO_DESKTOP:-0}" = "1" ]; then
    install -d "$ROOTFS/etc/gdm3"
    cat > "$ROOTFS/etc/gdm3/custom.conf" <<'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 impose : sous VirtualBox/QEMU, la session Wayland de GNOME 42 tombe sur
# le pilote llvmpipe et rend un bureau inutilisable, quand elle demarre.
WaylandEnable=false
GDMCONF
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        "$ROOTFS/etc/pam.d/gdm-password" "$ROOTFS/etc/pam.d/gdm-autologin" 2>/dev/null || true
    install -d "$ROOTFS/root/.config" "$ROOTFS/home/osmocom/.config"
    echo yes > "$ROOTFS/root/.config/gnome-initial-setup-done"
    echo yes > "$ROOTFS/home/osmocom/.config/gnome-initial-setup-done"
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} session graphique : ouverture automatique sur ${CYAN}root${NC} (osmocom au choix, apres deconnexion)"
fi

# ── L INSTALLEUR ────────────────────────────────────────────────────────────
# La configuration vit dans le depot (installer/calamares/) plutot qu en
# heredocs ici : elle est relisible, versionnee, et validable hors build
# (c est du YAML, "python3 -c import yaml" suffit a la verifier).
_CAL_SRC="$DIR/installer/calamares"
if [ "${ISO_DESKTOP:-0}" = "1" ] && [ -d "$_CAL_SRC" ]; then
    install -d "$ROOTFS/etc/calamares"
    cp -a "$_CAL_SRC/settings.conf" "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/modules"       "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/branding"      "$ROOTFS/etc/calamares/"

    # Les images de l habillage : on reprend le fond d ecran deja fige au build
    # plutot que d ajouter des binaires au depot. Calamares les met a l echelle.
    _WPI="$DIR/configs/gsm-lab-wallpaper.png"
    if [ -f "$_WPI" ]; then
        cp "$_WPI" "$ROOTFS/etc/calamares/branding/osmo/welcome.png"
        cp "$_WPI" "$ROOTFS/etc/calamares/branding/osmo/logo.png"
    else
        # Sans image, Calamares journalise une erreur par ecran. On retire les
        # trois cles plutot que de laisser pointer vers des fichiers absents.
        sed -i '/^images:/,/^slideshow:/{/productLogo\|productIcon\|productWelcome/d}' \
            "$ROOTFS/etc/calamares/branding/osmo/branding.desc"
    fi

    # ── LE LANCEUR ──────────────────────────────────────────────────────────
    # pkexec et non sudo : l installeur est lance depuis le bureau, ou il n y a
    # pas de terminal pour taper un mot de passe. La session tourne deja en
    # root, mais osmocom doit pouvoir lancer l installeur aussi - et c est la
    # que pkexec sert vraiment.
    cat > "$ROOTFS/usr/local/bin/osmo-install" <<'INSTALLER'
#!/bin/bash
# Lance l installeur du systeme. Sur la cle live uniquement.
set -u
if [ ! -r /etc/calamares/settings.conf ]; then
    echo "Calamares n est pas installe sur cette image (ISO_DESKTOP=0 ?)." >&2
    exit 1
fi
# Deja installe : /run/live/medium n existe que quand on a demarre sur le medium.
if [ ! -d /run/live/medium ]; then
    echo "Ce systeme ne tourne pas depuis une cle live - rien a installer." >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    exec pkexec --disable-internal-agent /usr/bin/calamares -d "$@"
fi
exec /usr/bin/calamares -d "$@"
INSTALLER
    chmod +x "$ROOTFS/usr/local/bin/osmo-install"

    cat > "$ROOTFS/usr/share/applications/osmo-install.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Installer osmo_egprs
Name[fr]=Installer osmo_egprs
Comment=Installer le banc GSM/EGPRS sur le disque
Comment[fr]=Installer le banc GSM/EGPRS sur le disque
Exec=/usr/local/bin/osmo-install
Icon=drive-harddisk
Terminal=false
Categories=System;
Keywords=install;installer;calamares;
DESKTOP

    # Sur le bureau de root, ou la session s ouvre : l icone est la premiere
    # chose qu on cherche sur une cle live, et c est celle qu on ne trouve
    # jamais quand elle n est que dans le menu des applications.
    for _h in "$ROOTFS/root" "$ROOTFS/home/osmocom"; do
        install -d "$_h/Bureau" "$_h/Desktop"
        cp "$ROOTFS/usr/share/applications/osmo-install.desktop" "$_h/Bureau/"  2>/dev/null || true
        cp "$ROOTFS/usr/share/applications/osmo-install.desktop" "$_h/Desktop/" 2>/dev/null || true
        chmod +x "$_h/Bureau/osmo-install.desktop" "$_h/Desktop/osmo-install.desktop" 2>/dev/null || true
    done
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true

    echo -e "  ${GREEN}✓${NC} installeur ${CYAN}Calamares${NC} : /usr/local/bin/osmo-install (+ icone sur le bureau)"
elif [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo -e "  ${YELLOW}!${NC} $_CAL_SRC absent - pas d installeur dans cette image"
fi

# ── LE LANCEUR GTK "UPDATE" -> update.sh DU DEPOT ───────────────────────────
# Independant de Calamares : c'est une icone de bureau qui rejoue update.sh, le
# fichier SUIVI dans le depot osmo_egprs (/opt/GSM/osmo_egprs/update.sh).
# update.sh est une animation de TERMINAL : sa premiere ligne utile est
# "[ -t 1 ] || exit 0", donc lance sans tty (depuis une icone GTK) il sort
# aussitot sans rien montrer. Le lanceur l'ouvre DONC dans un emulateur de
# terminal - gnome-terminal est tire par ubuntu-desktop-minimal - et laisse la
# fenetre ouverte a la fin pour qu'on lise le resultat.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    cat > "$ROOTFS/usr/local/bin/osmo-update-anim" <<'UPDGUI'
#!/bin/bash
# Rejoue l animation update.sh du depot osmo_egprs, dans une fenetre terminal.
set -u
SCRIPT=/opt/GSM/osmo_egprs/update.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="update.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
# read a la fin : sans lui, la fenetre se fermerait avant qu on lise la ligne
# "SMS delivered". -e pour la plupart des emulateurs, "--" pour gnome-terminal.
CMD="\"$SCRIPT\"; echo; read -n1 -rsp 'Termine - une touche pour fermer...'"
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="osmo_egprs update" -- bash -c "$CMD" ;;
        *)              exec "$term" -T "osmo_egprs update" -e bash -c "$CMD" ;;
    esac
done
# Aucun emulateur : dernier recours, on joue directement (utile en tty).
exec "$SCRIPT"
UPDGUI
    chmod +x "$ROOTFS/usr/local/bin/osmo-update-anim"

    cat > "$ROOTFS/usr/share/applications/osmo-update.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Update osmo_egprs
Name[fr]=Mise a jour osmo_egprs
Comment=Rejouer update.sh du depot osmo_egprs
Comment[fr]=Rejouer update.sh du depot osmo_egprs
Exec=/usr/local/bin/osmo-update-anim
Icon=system-software-update
Terminal=false
Categories=System;
Keywords=update;sms;osmo;
DESKTOP

    for _h in "$ROOTFS/root" "$ROOTFS/home/osmocom"; do
        install -d "$_h/Bureau" "$_h/Desktop"
        cp "$ROOTFS/usr/share/applications/osmo-update.desktop" "$_h/Bureau/"  2>/dev/null || true
        cp "$ROOTFS/usr/share/applications/osmo-update.desktop" "$_h/Desktop/" 2>/dev/null || true
        chmod +x "$_h/Bureau/osmo-update.desktop" "$_h/Desktop/osmo-update.desktop" 2>/dev/null || true
    done
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true

    echo -e "  ${GREEN}✓${NC} lanceur GTK ${CYAN}update${NC} : /usr/local/bin/osmo-update-anim (+ icone sur le bureau)"
fi

# ── L ERREUR DE SYNTAXE DE LA COPIE EN RAM ──────────────────────────────────
# L entree "en RAM" du menu passe "toram=filesystem.squashfs" : live-boot ne
# recopie alors QUE le squashfs, pas le medium entier. Le calcul de la taille du
# tmpfs est celui-ci, dans lib/live/boot/9990-toram-todisk.sh :
#
#     size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
#
# C est le SEUL expr de tout ce chemin, donc la seule chose qui puisse repondre
# "expr: syntax error" pendant la copie. Il suffit que le ls de l initramfs
# (busybox, pas coreutils) ne rende pas la taille en 5e champ - ou ne rende
# rien - pour qu expr recoive "expr / 1024 + 5000" et le dise.
#
# L erreur ne BLOQUE pas : size reste vide, le tmpfs est monte sans -o size et
# prend son defaut (la moitie de la RAM), ce qui suffit le plus souvent. D ou un
# banc qui demarre quand meme, avec un message rouge au passage - le genre de
# message qu on finit par ignorer, et qui masque le jour ou il compte.
#
# On remplace expr par l arithmetique du shell, avec le champ VALIDE avant
# usage et un repli explicite. "ls -lan" plutot que "ls -la" : le -n evite la
# resolution des noms d utilisateur, qui dans un initramfs sans /etc/passwd
# complet peut elargir la colonne et decaler les champs - c est le candidat le
# plus credible. Le patch precede update-initramfs, sinon il ne part pas dans
# l image ; d ou la regeneration explicite juste apres.
_LB_TORAM="$ROOTFS/lib/live/boot/9990-toram-todisk.sh"
if [ -f "$_LB_TORAM" ] && grep -q 'expr \$(ls -la \${MODULETORAMFILE}' "$_LB_TORAM"; then
    python3 - "$_LB_TORAM" <<'PYLB'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "\t\t\tsize=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )\n"
new = ("\t\t\t_lbsz=$(ls -lan \"${MODULETORAMFILE}\" 2>/dev/null | awk '{print $5}')\n"
       "\t\t\tcase \"${_lbsz}\" in ''|*[!0-9]*) _lbsz=0 ;; esac\n"
       "\t\t\tsize=$(( _lbsz / 1024 + 5000 ))\n")
sys.exit(0 if (open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1)) and old in s) else 0)
PYLB
    if grep -q '_lbsz' "$_LB_TORAM"; then
        _LB_K=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed "s|.*/vmlinuz-||")
        [ -n "$_LB_K" ] && chroot "$ROOTFS" update-initramfs -u -k "$_LB_K" >/dev/null 2>&1
        echo -e "  ${GREEN}✓${NC} live-boot : calcul de taille ${CYAN}toram${NC} fiabilise (plus d appel a expr)"
    else
        echo -e "  ${YELLOW}!${NC} live-boot : la ligne attendue n a pas ete trouvee - non modifie"
    fi
else
    echo -e "  ${GREEN}·${NC} live-boot : rien a corriger (absent, ou deja corrige)"
fi

# ── sssd : le service qui echoue au demarrage pour rien ─────────────────────
# ubuntu-desktop-minimal tire sssd (par gnome-online-accounts / realmd). Sur une
# machine qui n est dans AUCUN domaine - ce qui est le cas d un banc - sssd n a
# pas de fournisseur configure : il sort en erreur a chaque demarrage,
#     sssd.service: Failed with result exit-code
# et systemd le compte comme un service en echec. Rien ne casse : aucune session
# ne depend de lui ici. Mais "systemctl --failed" en garde la trace, et sur une
# machine ou l on diagnostique justement des pannes, un service rouge en
# permanence est un bruit qui coute cher - on finit par ne plus regarder la
# liste, et c est la qu on rate le vrai.
#
# On MASQUE plutot que de desinstaller : purger sssd emporterait des paquets du
# bureau par dependance inverse. Reversible en une commande, et la commande est
# ecrite ci-dessous pour qui voudrait joindre un domaine.
#     systemctl unmask sssd && systemctl enable --now sssd
for _s in sssd sssd-autofs sssd-nss sssd-pac sssd-pam sssd-ssh sssd-sudo; do
    chroot "$ROOTFS" systemctl mask "$_s" >/dev/null 2>&1 || true
done
echo -e "  ${GREEN}✓${NC} sssd masque (aucun domaine sur un banc) - ${CYAN}systemctl unmask sssd${NC} pour le rendre"

# ── CHROMIUM : LE BAC A SABLE EST LA REGLE, PAS L OPTION ────────────────────
# La session de cette image s ouvre en ROOT. Or Chromium refuse de demarrer en
# root avec son bac a sable actif :
#     Running as root without --no-sandbox is not supported
# La reponse habituelle - ajouter --no-sandbox - donne un navigateur SANS AUCUN
# confinement, lance par le compte le plus privilegie de la machine, sur un banc
# qui manipule des captures et des interfaces reseau. C est precisement ce qu il
# ne faut pas.
#
# Ce lanceur inverse la charge : le bac a sable est le comportement par defaut,
# depuis le CLI comme depuis le bureau, que l on soit root ou osmocom. La seule
# facon de s en passer est de le DEMANDER, en ecrivant --no-sandbox soi-meme.
#
# COMMENT. En root, on ne peut pas confiner Chromium sur place : sa protection
# par espaces de noms exige un UID non nul. On rebascule donc sur osmocom - le
# compte non privilegie de l image - avec runuser, ce qui rend le bac a sable
# utilisable. Sous osmocom (ou tout autre compte non root), Chromium se confine
# tout seul : on le lance tel quel.
#
# TROIS DETAILS SANS LESQUELS RIEN NE S AFFICHE :
#   - le serveur X appartient a root ; osmocom doit y etre autorise, d ou le
#     xhost +SI:localuser (autorisation nominative, pas un xhost + qui ouvrirait
#     l affichage a tout le monde) ;
#   - XAUTHORITY et DISPLAY/WAYLAND_DISPLAY doivent traverser runuser ;
#   - le profil doit etre dans un repertoire ou osmocom peut ecrire, jamais
#     /root/.config, sinon Chromium sort sur une erreur de permissions.
#
# Le lanceur est en /usr/local/bin, qui precede /snap/bin et /usr/bin dans le
# PATH par defaut : "chromium" et "chromium-browser" tapes a la main passent
# donc ici, et le .desktop du bureau est reecrit pour l utiliser aussi.
cat > "$ROOTFS/usr/local/bin/chromium" <<'CHROMIUM'
#!/bin/bash
# Chromium confine par defaut. Voir build-iso.sh, etape 8d.
set -u

REAL=""
for c in /snap/bin/chromium /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -x "$c" ] && { REAL="$c"; break; }
done
[ -n "$REAL" ] || { echo "chromium introuvable (le snap n est peut-etre pas encore installe)" >&2; exit 127; }

# Choix EXPLICITE de l appelant : on ne discute pas, on transmet tel quel.
for a in "$@"; do
    case "$a" in
        --no-sandbox|--disable-setuid-sandbox|--disable-namespace-sandbox)
            exec "$REAL" "$@" ;;
    esac
done

SANDBOX_USER="${OSMO_BROWSER_USER:-osmocom}"
PROFILE_ROOT=/var/lib/osmo-chromium

if [ "$(id -u)" -ne 0 ]; then
    # Deja non privilegie : Chromium se confine lui-meme, rien a faire.
    exec "$REAL" --user-data-dir="${HOME}/.config/osmo-chromium" "$@"
fi

id -u "$SANDBOX_USER" >/dev/null 2>&1 || {
    echo "Compte $SANDBOX_USER absent : impossible de confiner Chromium." >&2
    echo "Relancez avec --no-sandbox si vous acceptez de vous en passer." >&2
    exit 1
}

install -d -o "$SANDBOX_USER" -g "$SANDBOX_USER" -m 0700 "$PROFILE_ROOT/$SANDBOX_USER"

# Autorisation NOMINATIVE sur l affichage - pas un "xhost +".
[ -n "${DISPLAY:-}" ] && command -v xhost >/dev/null 2>&1 && \
    xhost "+SI:localuser:$SANDBOX_USER" >/dev/null 2>&1 || true

# LE COOKIE X, RECOPIE DANS UN FICHIER QUE osmocom PEUT LIRE.
# Sous GDM en autologin root, XAUTHORITY ne vaut PAS /root/.Xauthority mais
# /run/user/0/gdm/Xauthority : un fichier en 0600 root, dans un repertoire en
# 0700 root. Le passer tel quel a runuser transmet un chemin que osmocom ne
# peut ni ouvrir ni meme traverser. Le xhost nominatif ci-dessus suffit en
# principe - l extension LocalUser autorise par UID, sans cookie - mais il ne
# couvre pas les serveurs X ou elle est absente, et l echec se lit alors
# "Authorization required, but no authorization protocol specified", ce qui
# ne designe personne. Trois lignes de xauth ferment le sujet.
SB_XAUTH="$PROFILE_ROOT/$SANDBOX_USER/.Xauthority"
if [ -n "${DISPLAY:-}" ] && command -v xauth >/dev/null 2>&1; then
    rm -f "$SB_XAUTH"
    if xauth nextract - "$DISPLAY" 2>/dev/null \
         | XAUTHORITY="$SB_XAUTH" xauth nmerge - 2>/dev/null \
       && [ -s "$SB_XAUTH" ]; then
        chown "$SANDBOX_USER:$SANDBOX_USER" "$SB_XAUTH" 2>/dev/null || true
        chmod 0600 "$SB_XAUTH" 2>/dev/null || true
        XAUTHORITY="$SB_XAUTH"
    fi
fi

exec runuser -u "$SANDBOX_USER" -- env \
    DISPLAY="${DISPLAY:-}" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    XAUTHORITY="${XAUTHORITY:-/root/.Xauthority}" \
    XDG_RUNTIME_DIR="/run/user/$(id -u "$SANDBOX_USER")" \
    "$REAL" --user-data-dir="$PROFILE_ROOT/$SANDBOX_USER" "$@"
CHROMIUM
chmod +x "$ROOTFS/usr/local/bin/chromium"
ln -sf chromium "$ROOTFS/usr/local/bin/chromium-browser"

# XDG_RUNTIME_DIR d osmocom doit exister avant qu il ouvre quoi que ce soit :
# systemd le cree a l ouverture de session, or ici osmocom n en ouvre aucune.
install -d "$ROOTFS/etc/systemd/system"
cat > "$ROOTFS/etc/systemd/system/osmo-browser-runtime.service" <<'BRUNTIME'
[Unit]
Description=Repertoire d execution pour le Chromium confine (osmocom)
After=systemd-user-sessions.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'u=$(id -u osmocom 2>/dev/null) || exit 0; install -d -o osmocom -g osmocom -m 0700 /run/user/$u /var/lib/osmo-chromium/osmocom'

[Install]
WantedBy=multi-user.target
BRUNTIME
chroot "$ROOTFS" systemctl enable osmo-browser-runtime >/dev/null 2>&1 || true

# ── UN SEUL NOM DANS LE MENU : "Chromium" ───────────────────────────────────
# Le paquet et le snap posent des entrees nommees "chromium-browser" et
# "Chromium Web Browser", dont l Exec pointe directement sur le binaire - donc
# HORS du lanceur, donc sans bac a sable quand la session est root. Une icone
# qui contourne la regle est pire que pas d icone : on croit le confinement
# actif partout.
#
# On efface donc toutes ces entrees et on en ecrit UNE, qui appelle le lanceur.
# "chromium-browser" reste disponible en ligne de commande (lien symbolique
# vers le meme lanceur, pose plus haut) : les scripts qui l appellent par ce nom
# continuent de marcher, et ils sont confines eux aussi.
rm -f "$ROOTFS/usr/share/applications/chromium-browser.desktop" \
      "$ROOTFS/usr/share/applications/chromium.desktop" \
      "$ROOTFS/var/lib/snapd/desktop/applications/chromium_chromium.desktop" \
      "$ROOTFS/var/lib/snapd/desktop/applications/chromium_chromium-browser.desktop" 2>/dev/null || true
cat > "$ROOTFS/usr/share/applications/chromium.desktop" <<'CHRDESK'
[Desktop Entry]
Type=Application
Name=Chromium
GenericName=Navigateur web
Comment=Navigateur web, confine dans son bac a sable
Exec=/usr/local/bin/chromium %U
Icon=chromium
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
StartupWMClass=Chromium

[Desktop Action new-window]
Name=Nouvelle fenetre
Exec=/usr/local/bin/chromium

[Desktop Action new-private-window]
Name=Nouvelle fenetre de navigation privee
Exec=/usr/local/bin/chromium --incognito
CHRDESK

# Le snap repose ses propres .desktop a chaque installation ou mise a jour.
# Une unite les reecrit apres coup, sinon l entree hors bac a sable revient au
# premier "snap refresh" sans que rien ne le signale.
cat > "$ROOTFS/etc/systemd/system/osmo-chromium-desktop.service" <<'CHRFIX'
[Unit]
Description=Une seule entree Chromium dans le menu, et elle passe par le bac a sable
After=snapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'rm -f /var/lib/snapd/desktop/applications/chromium_*.desktop /usr/share/applications/chromium-browser.desktop 2>/dev/null; exit 0'

[Install]
WantedBy=multi-user.target
CHRFIX
chroot "$ROOTFS" systemctl enable osmo-chromium-desktop >/dev/null 2>&1 || true

# L alias de shell, pour les sessions interactives des deux comptes : taper
# "chromium-browser" ou "chromium" mene au lanceur meme si le PATH a ete
# reordonne par un profil.
cat > "$ROOTFS/etc/profile.d/98-osmo-chromium.sh" <<'CHRALIAS'
# Chromium confine : voir /usr/local/bin/chromium. --no-sandbox reste possible,
# il faut juste l ecrire.
alias chromium=/usr/local/bin/chromium
alias chromium-browser=/usr/local/bin/chromium
CHRALIAS
echo -e "  ${GREEN}✓${NC} Chromium : confine par defaut (root -> ${CYAN}osmocom${NC}) ; ${CYAN}--no-sandbox${NC} pour passer outre"


# ── LA BANNIERE DES TERMINAUX ───────────────────────────────────────────────
# Ce que quelqu un cherche en ouvrant un terminal sur ce banc, c est la commande
# qui le demarre. Elle est dans le README, dans l aide de start-direct.sh, et
# nulle part la ou on la cherche. On la met donc sous les yeux, avec la meme
# animation SMS que l ouverture de session - c est la signature de l image, et
# elle dit en une seconde que la pile est bien celle-la.
#
# TROIS GARDES, ET AUCUNE N EST DECORATIVE :
#   $- == *i*   shell INTERACTIF seulement. Sans cette garde, la banniere part
#               aussi dans les shells non interactifs - et scp, rsync et git
#               over ssh lisent ce flux comme leur protocole : ils echouent sur
#               un "protocol error", loin de leur vraie cause.
#   [ -t 1 ]    un terminal, pas un fichier. Les sequences de curseur dans un
#               journal le rendent illisible.
#   OSMO_BANNER un shell dans un shell (tmux, un sudo -i, un make qui ouvre un
#               bash) ne la rejoue pas : une fois par terminal suffit.
cat > "$ROOTFS/usr/local/bin/osmo-banner" <<'BANNER'
#!/bin/bash
# Banniere d ouverture de terminal : animation SMS puis la commande du banc.
# Reprise telle quelle de update.sh, qui la joue a l ouverture de session.
set -u
[ -t 1 ] || exit 0

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
    printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
    sleep 0.12
done
for ((p=0; p<=20; p++)); do
    printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
    sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"

printf '\n'
printf '  \033[1;36mPour demarrer le banc :\033[0m\n'
printf '      \033[1;32mcd /opt/GSM/osmo_egprs && ./start-direct.sh\033[0m\n\n'
printf '  \033[2mcompte courant : \033[0m%s\033[2m   ·   osmocom (non privilegie, sudoer) : \033[0msu - osmocom\n' "$(id -un)"
printf '  \033[2mChromium est confine par defaut ; --no-sandbox pour passer outre.\033[0m\n'
if [ -d /run/live/medium ]; then
    printf '  \033[2mSysteme live : \033[0mosmo-install\033[2m pour l installer sur le disque.\033[0m\n'
fi
printf '\n'
BANNER
chmod +x "$ROOTFS/usr/local/bin/osmo-banner"

# Pose dans le .bashrc des DEUX comptes, et dans /etc/skel pour ceux que
# l installeur creera. On APPEND, sans jamais reecrire le fichier : le .bashrc
# d Ubuntu porte l invite, les couleurs et les alias, et l ecraser se paie a
# chaque ouverture de terminal ensuite.
for _h in "$ROOTFS/root" "$ROOTFS/home/osmocom" "$ROOTFS/etc/skel"; do
    install -d "$_h"
    [ -f "$_h/.bashrc" ] || cp "$ROOTFS/etc/skel/.bashrc" "$_h/.bashrc" 2>/dev/null || : > "$_h/.bashrc"
    grep -q 'osmo-banner' "$_h/.bashrc" 2>/dev/null || cat >> "$_h/.bashrc" <<'BASHRC'

# ── Banniere osmo_egprs ─────────────────────────────────────────────────────
# Interactif ET terminal ET pas deja jouee : voir /usr/local/bin/osmo-banner.
# Retirer ces trois lignes suffit a s en debarrasser.
if [[ $- == *i* ]] && [ -t 1 ] && [ -z "${OSMO_BANNER:-}" ] && [ -x /usr/local/bin/osmo-banner ]; then
    export OSMO_BANNER=1
    /usr/local/bin/osmo-banner
fi
BASHRC
done
chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} banniere de terminal : animation + ${CYAN}cd /opt/GSM/osmo_egprs && ./start-direct.sh${NC}"

umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminee"

# ── Creation du squashfs et de l'ISO ───────────────────────────────────────
echo -e "${GREEN}[9/9] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-*|sort -V|tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-*|sort -V|tail -1)
[ -z "$VMLINUZ" ]||[ -z "$INITRD" ] && { echo -e "${RED}Kernel absent${NC}"; exit 1; }
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

# ── Compression du squashfs : zstd, et non xz ────────────────────────────────
# Le noyau embarque est compile avec CONFIG_SQUASHFS_DECOMP_SINGLE=y : UN SEUL
# flux de decompression, serialise par un mutex. Ajouter des vCPU a la VM n'y
# change donc rien - c'est le seul chiffre qui compte quand l'ISO est lue a la
# demande, et c'est celui qu'on regarde le moins.
#
# Mesure faite sur ce depot, meme contenu (360 Mo de /usr/bin de l'ISO lite),
# decompression a UN thread :
#
#     -comp xz -Xbcj x86    92,0 Mo    3,82 s
#     -comp zstd -level 19 106,9 Mo    0,41 s
#
# 16 % d'ISO en plus contre 9x en vitesse de lecture. Sur une image qui vit en
# machine virtuelle, dont chaque fichier ouvert au demarrage coute une
# decompression de bloc de 1 Mo, l'arbitrage se tranche tout seul.
#
# Le repli sur xz n'est pas de la prudence decorative : mksquashfs n'a le zstd
# que depuis la 4.4, et il n'est compile que si la libzstd etait la. On SONDE
# donc l'outil au lieu de lire son numero de version - une compression d'essai
# repond juste, une comparaison de versions non.
_squash_zstd_ok() {
    local t rc
    t="$(mktemp -d)" || return 1
    : > "$t/probe"
    mksquashfs "$t" "$t.sqfs" -comp zstd -no-progress -noappend >/dev/null 2>&1
    rc=$?
    rm -rf "$t" "$t.sqfs"
    return $rc
}

if _squash_zstd_ok; then
    SQUASH_COMP=(-comp zstd -Xcompression-level 19)
    echo -e "  Compression: ${CYAN}zstd -19${NC} (lecture ~9x plus rapide que xz a un thread)"
else
    SQUASH_COMP=(-comp xz -Xbcj x86)
    echo -e "  Compression: ${YELLOW}xz${NC} (mksquashfs sans zstd - ISO plus petite, mais lente a lire)"
fi

mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    "${SQUASH_COMP[@]}" -b 1M \
    -e 'boot/vmlinuz-*' -e 'boot/initrd*' \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

cp "$VMLINUZ" "$ISOROOT/boot/vmlinuz"
cp "$INITRD"  "$ISOROOT/boot/initrd.img"

# ── Menu GRUB ────────────────────────────────────────────────────────────────
# Les chiffres de RAM annonces sont CALCULES sur le squashfs qui vient d'etre
# ecrit, pas recopies d'un ancien build. Les libelles en dur ("RAM ~6 Go")
# etaient faux des que l'image maigrissait, et une consigne fausse coute plus
# cher que pas de consigne : on dimensionne la VM sur elle.
SQ_MB=$(( $(stat -Lc%s "$ISOROOT/live/filesystem.squashfs") / 1048576 ))
# toram recopie le squashfs dans un tmpfs, puis le systeme tourne par-dessus :
# la taille du fichier, plus 2 Go pour le reste, arrondi au Go superieur.
RAM_TORAM_GB=$(( (SQ_MB + 2048 + 1023) / 1024 ))
SQ_GB=$(awk -v m="$SQ_MB" 'BEGIN{printf "%.1f", m/1024}')

cat > "$ISOROOT/boot/grub/grub.cfg" <<GRUB
# ATTENTION - ce fichier est GENERE par build-iso.sh. Le modifier dans l'ISO ne
# survit pas au build suivant.
#
# Sous VirtualBox, deux reglages evitent des minutes d'attente sur l'entree
# "en RAM" : attacher l'ISO au controleur SATA plutot qu'IDE, et cocher
# "Utiliser le cache E/S de l'hote" dessus.

set default=0
set timeout=5

# TROIS entrees, et le reste dans un sous-menu. Cinq lignes dont deux doublons
# "verbose", c est un menu ou l on cherche - alors que le choix reel n en compte
# que trois : lire depuis le medium, copier en RAM, ecrire sur le medium.
menuentry "osmo_egprs" {
    linux  /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}

# "toram" tout court ferait recopier a live-boot le MEDIUM ENTIER dans un tmpfs
# (lib/live/boot/9990-toram-todisk.sh) : le squashfs, mais AUSSI l initrd de
# 82 Mo, le vmlinuz et efi.img. Et comme rsync n est pas dans l initrd, la copie
# se fait par "cp -a", qui n affiche RIEN - avec "quiet" en plus, l ecran reste
# fige plusieurs minutes sans le moindre signe de vie, et on croit a un
# plantage. D ou "toram=filesystem.squashfs" (seul le squashfs est copie, et le
# tmpfs est dimensionne sur lui) et l absence de "quiet" ici : la copie se voit.
menuentry "osmo_egprs - en RAM (copie ${SQ_GB} Go - ${RAM_TORAM_GB} Go de RAM mini)" {
    linux  /boot/vmlinuz boot=live toram=filesystem.squashfs
    initrd /boot/initrd.img
}

# Sans persistance, la racine est un overlay tmpfs : tout ce qui s ecrit vit en
# RAM et meurt au reboot - configs SS7 posees a la main, base HLR, journaux.
# PAS de toram ici, et c est le point : avec toram le systeme est recopie en RAM
# et l overlay y reste, ce qui annulerait l interet.
#
# Il faut un volume ETIQUETE "persistence" portant un persistence.conf dont la
# seule ligne utile est "/ union" :
#   sudo mkfs.ext4 -L persistence /dev/sdX3
#   sudo mount /dev/sdX3 /mnt && echo "/ union" | sudo tee /mnt/persistence.conf
# En VM, un second disque suffit. Sans volume ainsi etiquete, cette entree
# demarre comme un live ordinaire : rien ne casse, rien n est garde.
menuentry "osmo_egprs - persistant (ecrit sur le medium)" {
    linux  /boot/vmlinuz boot=live persistence persistence-encryption=none quiet
    initrd /boot/initrd.img
}

# Les variantes verbose ne servent qu au diagnostic : elles sont les memes
# lignes de commande sans "quiet". Elles restent atteignables, mais elles ne
# tiennent plus la moitie du menu.
submenu "Options (demarrage verbeux)" {
    menuentry "osmo_egprs - verbose" {
        linux  /boot/vmlinuz boot=live
        initrd /boot/initrd.img
    }
    menuentry "osmo_egprs - persistant verbose" {
        linux  /boot/vmlinuz boot=live persistence persistence-encryption=none
        initrd /boot/initrd.img
    }
}
GRUB
echo -e "  ${GREEN}✓${NC} menu GRUB : defaut = lecture depuis le medium ; toram annonce ${CYAN}${RAM_TORAM_GB} Go${NC} de RAM"

# ── /.disk/info : LE FICHIER SANS LEQUEL L'ISO S'ARRETE SUR "grub>" EN UEFI ──
# Ce fichier vide d'apparence est ce que le GRUB signe d'Ubuntu CHERCHE pour se
# reperer. gcdx64.efi.signed porte un disque memoire dont la configuration est,
# mot pour mot :
#
#     if [ -z "$prefix" -o ! -e "$prefix" ]; then
#         if ! search --file --set=root /.disk/info; then
#             search --file --set=root /.disk/mini-info
#         fi
#         set prefix=($root)/boot/grub
#     fi
#     ... source $prefix/grub.cfg ... sinon source $cmdpath/grub.cfg
#
# Son prefixe compile vaut "/boot/grub" SANS peripherique : il se resout donc
# sur le disque d'ou le firmware a charge le binaire, c'est-a-dire la partition
# EFI (FAT) - qui ne contient pas /boot/grub. Le test "! -e $prefix" est vrai,
# et tout repose alors sur la recherche de /.disk/info. Ce fichier n'existait
# pas ici : la recherche echouait, $root restait sur la FAT, aucun grub.cfg
# n'etait trouve, et GRUB rendait la main sur son invite "grub>".
#
# POURQUOI CA MARCHAIT EN MACHINE VIRTUELLE. VirtualBox demarre en BIOS par
# defaut : c'est eltorito.img qui joue, construit ici avec -p /boot/grub sur
# le lecteur de boot, et il trouve sa configuration sans rien chercher. Le
# chemin UEFI - le seul qu'un portable recent emprunte - n'etait donc jamais
# exerce. La panne n'etait pas "sur ce portable", elle etait sur TOUT UEFI.
#
# Les ISO Ubuntu et Debian posent ce meme fichier, pour cette meme raison.
mkdir -p "$ISOROOT/.disk"
printf 'osmo_egprs %s - live amd64 (%s)\n' "$VERSION" "$LABEL" > "$ISOROOT/.disk/info"
cp "$ISOROOT/.disk/info" "$ISOROOT/.disk/mini-info"
echo -e "  ${GREEN}✓${NC} ${CYAN}/.disk/info${NC} pose : le GRUB signe retrouve le medium en UEFI"

# Les modules EFI, la ou $prefix les cherchera. Le menu genere plus haut n'use
# que de commandes deja compilees dans le binaire signe (set, menuentry, linux,
# initrd, submenu), mais grub-mkrescue les deposait, et leur absence transforme
# le moindre "insmod" tape a l'invite en echec incomprehensible. 3 Mo.
if [ -d /usr/lib/grub/x86_64-efi ]; then
    mkdir -p "$ISOROOT/boot/grub/x86_64-efi"
    cp -a /usr/lib/grub/x86_64-efi/*.mod /usr/lib/grub/x86_64-efi/*.lst \
          "$ISOROOT/boot/grub/x86_64-efi/" 2>/dev/null || true
    # ATTENTION : surtout PAS de grub.cfg dans ce repertoire. La configuration
    # embarquee ci-dessus teste "$prefix/x86_64-efi/grub.cfg" AVANT
    # "$prefix/grub.cfg" : un fichier ici detournerait le menu.
    rm -f "$ISOROOT/boot/grub/x86_64-efi/grub.cfg"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SECURE BOOT - pourquoi cette etape ne peut pas rester grub-mkrescue
# ══════════════════════════════════════════════════════════════════════════════
# grub-mkrescue CONSTRUIT son BOOTX64.EFI a la volee, a partir des modules de
# l'hote. Ce binaire n'est signe par personne. Sur une machine dont le Secure
# Boot est actif, le firmware refuse de le charger et n'affiche qu'une erreur de
# certificat - "Verification failed: (0x1A) Security Violation", ou pire un
# ecran qui retombe au menu de boot sans un mot. L'ISO etait donc inutilisable
# partout ou l'on ne peut pas desactiver Secure Boot dans le firmware, ce qui
# est le cas de la plupart des machines d'entreprise et de beaucoup de portables
# recents.
#
# LA CHAINE DE CONFIANCE, et pourquoi chaque maillon est celui-la :
#
#   firmware --(cle Microsoft)--> shimx64.efi.signed   paquet shim-signed
#            --(cle Canonical)--> gcdx64.efi.signed    paquet grub-efi-amd64-signed
#            --(cle Canonical)--> vmlinuz              linux-image-generic (deja signe)
#
# shim est le SEUL maillon signe par Microsoft, dont la cle est dans a peu pres
# tous les firmwares du marche. Il porte la cle Canonical et valide ce qu'il
# charge ensuite. On ne le fabrique pas : on copie celui du paquet.
#
# gcdx64 ET NON grubx64 - c'est le detail qui coute une soiree. Les deux sont
# signes par Canonical, mais leur PREFIXE compile differe :
#     grubx64.efi.signed  -> prefixe /EFI/ubuntu, cherche sa configuration sur
#                            la partition EFI ; sur une ISO elle n'y est pas, et
#                            GRUB tombe sur son invite "grub>" sans un message.
#     gcdx64.efi.signed   -> prefixe /boot/grub RELATIF AU MEDIUM DE BOOT, la
#                            variante faite pour l'optique. Il trouve donc
#                            $ISOROOT/boot/grub/grub.cfg, celui qu'on vient
#                            d'ecrire, sans stub ni duplication.
# On garde tout de meme un stub en /EFI/ubuntu/grub.cfg sur l'ESP : il ne sert
# que si le repli sur grubx64 s'est declenche, et il ne coute que 60 octets.
#
# CE QUE CETTE ETAPE NE FAIT PAS : signer quoi que ce soit. Aucune cle privee
# n'est manipulee, rien n'est a enroler par l'utilisateur (pas de MokManager a
# la premiere ouverture). On assemble des binaires deja signes par Microsoft et
# Canonical - c'est exactement ce que fait une ISO Ubuntu officielle.
#
# LE BIOS N'EST PAS ABANDONNE. L'image El Torito i386-pc est construite ici par
# grub-mkimage au format i386-pc-eltorito (celui qui embarque deja cdboot.img),
# et la MBR hybride par --grub2-mbr : une machine sans UEFI demarre comme avant.
#
# REPLI. Si un maillon manque sur l'hote (paquet non installe, architecture
# autre), on retombe sur grub-mkrescue - l'ISO d'avant, qui demarre partout SAUF
# en Secure Boot. On le DIT, en clair : une ISO non signee qui se presente comme
# signee, c'est une panne au premier deploiement.

SB_SHIM=""
for c in /usr/lib/shim/shimx64.efi.signed \
         /usr/lib/shim/shimx64.efi.signed.latest \
         /usr/lib/shim/shimx64.efi; do
    [ -f "$c" ] && { SB_SHIM="$c"; break; }
done
# gcdx64 d'abord (prefixe /boot/grub, fait pour l'optique), grubx64 en repli.
SB_GRUB="" ; SB_GRUB_KIND=""
for c in /usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed:gcd \
         /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed:grub; do
    [ -f "${c%:*}" ] && { SB_GRUB="${c%:*}"; SB_GRUB_KIND="${c##*:}"; break; }
done
SB_MM=""
for c in /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi; do
    [ -f "$c" ] && { SB_MM="$c"; break; }
done

# Le noyau doit l'etre aussi : shim valide GRUB, GRUB valide le noyau. Un
# vmlinuz non signe s'arrete sur "you need to load the kernel first" ou sur un
# refus de shim_lock, APRES le menu - donc la ou l'on ne soupconne plus l'ISO.
# Les noyaux Ubuntu "generic" le sont ; un noyau maison, non. On regarde la
# signature plutot que de faire confiance au nom du paquet.
SB_KERNEL_SIGNED=0
if command -v sbverify &>/dev/null; then
    sbverify --list "$ISOROOT/boot/vmlinuz" &>/dev/null && SB_KERNEL_SIGNED=1
elif grep -qa '~Module signature appended~\|sbat\|Canonical Ltd\. Secure Boot' "$ISOROOT/boot/vmlinuz" 2>/dev/null; then
    SB_KERNEL_SIGNED=1
fi

SECURE_BOOT_OK=0
if [ -n "$SB_SHIM" ] && [ -n "$SB_GRUB" ] && command -v mmd &>/dev/null; then
    echo -e "${GREEN}[9/9] ISO Secure Boot (shim + grub signes)...${NC}"
    echo -e "  shim : ${CYAN}${SB_SHIM}${NC}"
    echo -e "  grub : ${CYAN}${SB_GRUB}${NC} (${SB_GRUB_KIND})"

    # ── La partition systeme EFI ────────────────────────────────────────────
    # FAT16, et un PLANCHER DE 16 Mo. Le contenu ne pese que ~4 Mo (shim ~1 Mo,
    # grub signe ~2,3 Mo, MokManager ~0,9 Mo), mais FAT16 exige au moins 4085
    # clusters : mkfs.vfat refuse en dessous, avec
    #     mkfs.vfat: Attempting to create a too small or a too large filesystem
    # et l'etape entiere retombait alors en silence sur le repli non signe.
    # 16 Mo a 2 Ko par cluster (-s 4) font 8192 clusters - au large, et 16 Mo
    # sur une ISO de plusieurs Go ne se voient pas.
    SB_ESP="$WORK/efi.img"
    SB_KB=$(( ( $(stat -Lc%s "$SB_SHIM") + $(stat -Lc%s "$SB_GRUB") \
              + $( [ -n "$SB_MM" ] && stat -Lc%s "$SB_MM" || echo 0 ) ) / 1024 + 2048 ))
    [ "$SB_KB" -lt 16384 ] && SB_KB=16384
    rm -f "$SB_ESP"
    mkfs.vfat -F 16 -s 4 -n OSMOEFI -C "$SB_ESP" "$SB_KB" >/dev/null

    mmd   -i "$SB_ESP" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
    mcopy -i "$SB_ESP" "$SB_SHIM" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$SB_ESP" "$SB_GRUB" ::/EFI/BOOT/grubx64.efi
    [ -n "$SB_MM" ] && mcopy -i "$SB_ESP" "$SB_MM" ::/EFI/BOOT/mmx64.efi

    # Stub : DERNIER RECOURS de la configuration embarquee dans gcdx64 - elle
    # finit par "source $cmdpath/grub.cfg", et $cmdpath est le repertoire d'ou
    # le firmware a charge le binaire, donc /EFI/BOOT sur cette ESP. Il sert
    # aussi tel quel au repli grubx64 (prefixe /EFI/ubuntu).
    #
    # "search --set=root" ne touche PAS a la variable quand il echoue : on vise
    # donc une variable a nous, encore vide, pour pouvoir tester le resultat -
    # et on le DIT quand rien n'est trouve, plutot que de rendre la main a une
    # invite "grub>" que personne ne sait interpreter.
    cat > "$WORK/esp-grub.cfg" <<'ESPCFG'
search --no-floppy --file --set=osmodev /.disk/info
if [ -z "$osmodev" ]; then
    search --no-floppy --file --set=osmodev /boot/grub/grub.cfg
fi
if [ -n "$osmodev" ]; then
    set root=$osmodev
    set prefix=($osmodev)/boot/grub
    configfile ($osmodev)/boot/grub/grub.cfg
fi
echo "GRUB : ni /.disk/info ni /boot/grub/grub.cfg trouves sur les disques vus."
echo "Le medium n'est probablement pas lisible par le firmware a ce stade."
ESPCFG
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/ubuntu/grub.cfg
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/BOOT/grub.cfg

    # ── LE MEME ARBRE, AUSSI DANS L'ISO9660 ─────────────────────────────────
    # L'ESP appendue suffit a demarrer depuis un DVD ou une cle ecrite en mode
    # image (dd, Rufus en mode DD). Elle ne suffit PAS a la methode la plus
    # repandue sous Windows : formater la cle en FAT et y COPIER le contenu de
    # l'ISO. Cette copie ne voit que l'ISO9660, ou /EFI/BOOT n'existerait pas -
    # la cle ne demarre alors pas en UEFI, sans que rien n'explique pourquoi.
    # C'est exactement ce que xorriso previent :
    #     WARNING : EFI boot equipment is provided but no directory /EFI/BOOT
    #     WARNING : will emerge in the ISO filesystem.
    # Quelques Mo dupliques ; les ISO Ubuntu font de meme.
    mkdir -p "$ISOROOT/EFI/BOOT"
    cp "$SB_SHIM" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"
    cp "$SB_GRUB" "$ISOROOT/EFI/BOOT/grubx64.efi"
    [ -n "$SB_MM" ] && cp "$SB_MM" "$ISOROOT/EFI/BOOT/mmx64.efi"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/BOOT/grub.cfg"
    mkdir -p "$ISOROOT/EFI/ubuntu"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/ubuntu/grub.cfg"

    # ── L'amorce BIOS, construite ici puisqu'on n'appelle plus grub-mkrescue ──
    # i386-pc-eltorito embarque deja cdboot.img : cette image est directement
    # utilisable comme -eltorito-boot, pas de concatenation a faire.
    SB_BIOS="$WORK/eltorito.img"
    grub-mkimage -O i386-pc-eltorito -p /boot/grub -o "$SB_BIOS" \
        biosdisk iso9660 part_msdos part_gpt fat ext2 normal linux configfile \
        search search_label search_fs_uuid search_fs_file loopback gzio \
        all_video gfxterm videotest videoinfo test echo ls minicmd sleep \
        halt reboot chain 2>/dev/null

    if [ -s "$SB_BIOS" ]; then
        # -eltorito-alt-boot separe les deux entrees du catalogue : la premiere
        # (BIOS) et la seconde (UEFI). "--interval:appended_partition_2" designe
        # la partition qu'on ajoute juste apres, sans la copier deux fois dans
        # l'image.
        xorriso -as mkisofs -iso-level 3 \
            -volid "$LABEL" \
            -full-iso9660-filenames \
            -eltorito-boot boot/grub/eltorito.img \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                --eltorito-catalog boot/grub/boot.cat \
                --grub2-boot-info \
                --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
            -eltorito-alt-boot \
                -e --interval:appended_partition_2:all:: \
                -no-emul-boot \
            -append_partition 2 0xef "$SB_ESP" \
            -appended_part_as_gpt \
            -o "$OUTPUT" \
            -graft-points "$ISOROOT" "/boot/grub/eltorito.img=$SB_BIOS" \
            && SECURE_BOOT_OK=1
    fi

    if [ "$SECURE_BOOT_OK" = "1" ]; then
        if [ "$SB_KERNEL_SIGNED" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ISO signee Secure Boot : shim -> grub -> noyau, chaine complete"
        else
            echo -e "  ${YELLOW}⚠${NC}  shim et grub sont signes, mais la signature du NOYAU n'a pas"
            echo -e "     pu etre confirmee ($ISOROOT/boot/vmlinuz). Si le boot s'arrete APRES"
            echo -e "     le menu GRUB, c'est la : installez sbsigntool pour le verifier, ou"
            echo -e "     utilisez un noyau linux-image-generic non recompile."
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}  assemblage Secure Boot echoue - repli sur grub-mkrescue"
    fi
else
    echo -e "${YELLOW}[9/9] Secure Boot indisponible sur cet hote :${NC}"
    [ -z "$SB_SHIM" ] && echo -e "     shim absent  -> apt install ${CYAN}shim-signed${NC}"
    [ -z "$SB_GRUB" ] && echo -e "     grub signe absent -> apt install ${CYAN}grub-efi-amd64-signed${NC}"
    command -v mmd &>/dev/null || echo -e "     mtools absent -> apt install ${CYAN}mtools dosfstools${NC}"
fi

if [ "$SECURE_BOOT_OK" != "1" ]; then
# Repli : l'ancienne recette, mot pour mot. Elle produit une ISO qui demarre en
# BIOS et en UEFI sans Secure Boot - c'est ce qu'on avait avant, et c'est mieux
# que pas d'ISO du tout.
#
# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

    grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
        --product-name "osmo_egprs $VERSION" -- -volid "$LABEL"
    if command -v isohybrid &>/dev/null; then
        isohybrid --uefi "$OUTPUT"
    fi
    echo -e "  ${YELLOW}!${NC} ISO NON signee : elle ne demarrera pas si Secure Boot est actif."
    echo -e "    Desactivez-le dans le firmware, ou construisez sur un hote qui a"
    echo -e "    ${CYAN}shim-signed${NC} et ${CYAN}grub-efi-amd64-signed${NC}."
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Creation de l'ISO echouee - rien n'a ete ecrit${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}═══ ISO prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
