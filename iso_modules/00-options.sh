#!/bin/bash
# iso_modules/00-options.sh - options de la ligne de commande, suite Ubuntu, root
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

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
# --skip-build : pas de docker build. On PULL l image publiee sur Docker Hub
# (bastienbaranoff/norf_gsm:latest, ou --skip-build=<image:tag>), on la tague
# osmocom-nitb:latest et la chaine continue exactement comme apres build.sh.
# Sert a la CI et a une machine qui n a ni le temps ni le cache .deb du build.
ISO_SKIP_BUILD=0
ISO_PULL_IMAGE="${OSMO_ISO_PULL_IMAGE:-bastienbaranoff/norf_gsm:latest}"
# --build-docker : l INVERSE de --skip-build, et il gagne. Sert quand quelque
# chose en amont pousse un --skip-build qu on ne veut pas ici : la CI qui tire
# l image de base depuis GHCR, un OSMO_ISO_PULL_IMAGE qui traine dans
# l environnement, un alias. Avec lui, l image est construite localement par
# build.sh, point. Equivalent en variable : OSMO_ISO_BUILD_DOCKER=1.
ISO_FORCE_BUILD="${OSMO_ISO_BUILD_DOCKER:-0}"
# --without-debs : aucune .deb NE VOYAGE dans l image. Par defaut l etape 7c
# (71-debs-banc.sh) fabrique les paquets du banc - osmo-operator, pont,
# qemu-calypso, calypso-firmware - et les range dans /var/cache/osmo-debs du
# rootfs, pour qu une machine installee puisse refaire le banc sans docker ni
# git. C est du poids mort pour qui n en fera jamais rien, et une ISO live tient
# en RAM. Cette option les supprime, et force ISO_EMBED_DEBS=0 pour que les
# paquets du build docker (etape 5) ne restent pas non plus : ils servent
# toujours a POSER la pile dans le rootfs, ils n y sejournent plus.
# Equivalent en variable : OSMO_ISO_WITHOUT_DEBS=1.
ISO_WITH_DEBS=1
[ "${OSMO_ISO_WITHOUT_DEBS:-0}" = "1" ] && ISO_WITH_DEBS=0

# ── ARCHITECTURE : amd64 (ISO PC) ou arm64 (image SD Raspberry Pi 4) ─────────
# --arm : la MEME pile, construite pour arm64 sur une base ARMBIAN 24.04 (le
# noyau bcm2711 et le BSP rpi4b d Armbian, depot apt.armbian.com), livree en
# IMAGE SD (.img : une partition FAT pour le firmware du Pi, une ext4
# persistante pour le systeme), pas en ISO live. Tout se fabrique sur l hote x86 : l image docker par buildx
# --platform linux/arm64 (qemu-user-static emule aarch64, c est LENT : comptez
# une dizaine d heures au premier build, le cache .deb rend les suivants
# courts), le rootfs par debootstrap --foreign puis chroot sous binfmt. Ni
# bureau (--desktop), ni installateur, ni passe --all sur cette cible.
ISO_ARCH=amd64
# Defaut : le hub du banc = le conteneur osmo-inter-stp, sur le backbone docker
# (INTER_STP_IP de start.sh). Les VM le joignent par la route LAN -> docker
# (network/setup-docker-lan-route.sh). Le host-only VirtualBox (192.168.56.1)
# reste possible, mais via --hub-ip.
ISO_HUB_IP="172.20.0.10"
# ── Table WAN par defaut : le banc ──────────────────────────────────────────
# [2026-09-03] Table remise a jour. Format : <noeud>:<IP>:<indicatif>
#   noeud 1  192.168.1.2  la VM (cette ISO)   indicatif 11
#   noeud 2  172.20.0.12  osmo-operator-2     indicatif 22   (conteneur)
#   noeud 3  172.20.0.13  osmo-operator-3     indicatif 33   (conteneur)
#   hub      172.20.0.10  osmo-inter-stp                     (hors table)
# Plan de numerotation : MSISDN = <noeud>00<op><ms> (100101 = noeud 1, op 1,
# MS 1 ; 200101 = noeud 2...) - voir osmo_msisdn dans generate_configs.sh.
# L indicatif (11, 22, 33) est le prefixe compose pour joindre un autre noeud.
# Elle sert quand --wan-nodes n'est pas donne. Sans defaut, une construction
# sans terminal - la CI - s'arretait a l'etape 7b sur une question que personne
# ne lisait : "pas de terminal : renseignez WAN_NODES / WAN_NODE_ID / WAN_OPS".
ISO_WAN_NODES_DEFAULT="1:192.168.1.2:11 2:172.20.0.12:22 3:172.20.0.13:33"

# ── LE MULTI-OPERATEUR EST ACTIF PAR DEFAUT ─────────────────────────────────
# [2026-09-13] osmo-multi.service est desormais ACTIVE au boot des l'ISO, sans
# avoir a passer --multi. Ce que cela change, exactement : plus rien a faire
# apres addition.sh. L'unite est la, activee ; le jour ou l'operateur installe
# le supplement multi-operateur (docker, l'image, et la topologie
# /etc/osmocom/osmo-multi.conf qu'ecrit addition.sh), le banc multi repart a
# CHAQUE demarrage au lieu de demander un `systemctl enable` de plus.
# Ce que cela ne change pas : sans cette topologie, l'unite a une Condition qui
# la fait SAUTER - proprement, sans echec et sans message d'erreur au boot
# (cf. data/desktop/osmo-multi.desktop et launch.sh l.192). Activer par defaut
# ne demarre donc rien tant que le supplement n'est pas la : ca supprime un
# geste, ca n'en impose aucun.
# osmo-banc, lui, garde son defaut a 0 : un banc se demarre, c'est le geste de
# l'operateur (82-services.sh l.165).
# --no-multi (ou OSMO_ISO_MULTI=0) revient a l'ancien comportement.
OSMO_ISO_MULTI="${OSMO_ISO_MULTI:-1}"
export OSMO_ISO_MULTI

OUTPUT_SET=0

# ── --help ──────────────────────────────────────────────────────────────────
# Place AVANT le test root (plus bas dans ce module) : demander l'aide ne
# demande pas d'etre root. Les valeurs entre crochets sont les defauts reels,
# lus dans les variables ci-dessus - pas une copie qui derivera.
iso_usage() {
    # ATTENTION : les couleurs du depot (BOLD='\033[1m'...) sont faites pour
    # `echo -e`. Un heredoc passe par `cat`, qui ne traduit rien : elles
    # sortaient telles quelles, "\033[1mbuild-iso.sh\033[0m" en toutes lettres.
    # $'...' (quoting ANSI-C) produit le vrai octet d'echappement des
    # l'affectation, et le heredoc n'a plus rien a traduire.
    local B=$'\033[1m' C=$'\033[36m' D=$'\033[2m' N=$'\033[0m'
    cat <<EOF
${B}build-iso.sh${N} - fabrique une ISO bootable (ou une image SD arm64) a partir
de l'image docker osmocom-nitb. Tout passe par build.sh et start.sh.

  ${B}Usage${N} : sudo ./build-iso.sh [options]
  Sans option : les quatre images amd64 - interstp, operator, lite, desktop.

${B}QUELLES IMAGES${N}
  ${C}--role=operator|interstp${N}  le noeud complet, ou le hub SS7 seul   ${D}[${ISO_ROLE:-operator}]${N}
  ${C}--lite${N}                    l'ISO allegee : sans les arbres de sources de /opt/GSM
  ${C}--desktop${N}                 l'ISO avec bureau GNOME et installateur (~2,5 Go de plus)
  ${C}--all${N}                     les quatre d'un coup (operator + lite + desktop + interstp)
  ${C}--node=N${N}                  numero du noeud dans le plan de numerotation    ${D}[${ISO_NODE:-1}]${N}
  ${C}--output=FICHIER${N}          nom du fichier de sortie                        ${D}[${OUTPUT:-osmo-operator-<version>.iso}]${N}

${B}L'IMAGE DOCKER SOURCE${N}
  ${C}--skip-build[=IMAGE]${N}      ne rien construire : prendre une image publiee et la
                            taguer osmocom-nitb. Docker Hub par defaut, mais
                            n'importe quel registre convient - GHCR compris :
                              --skip-build=ghcr.io/<depot>/osmocom-nitb:base-<empreinte>
                            Une image deja presente localement n'est pas retiree.
                            ${D}[${ISO_PULL_IMAGE:-bastienbaranoff/norf_gsm:latest}]${N}
  ${C}--build-docker${N}            l'inverse, et il gagne sur --skip-build d'ou qu'il
                            vienne : l'image est construite ici par build.sh.
  ${C}--no-cache${N}                tout recompiler : cache docker ignore, .deb refaits.
                            Sur un runner, c'est 1h23 - voir .github/workflows/.

${B}CE QUI VOYAGE DANS L'IMAGE${N}
  ${C}--without-debs${N}            aucun .deb embarque : ni les paquets du banc
                            (osmo-operator, pont, qemu-calypso, calypso-firmware),
                            ni ceux du build docker. Ils posent toujours la pile
                            dans le rootfs, ils n'y restent plus.
  ${C}--with-debs${N}               le defaut : les paquets du banc sont dans
                            /var/cache/osmo-debs de l'image, pour un
                            \`dpkg -i\` sans docker ni git.

${B}AU DEMARRAGE DE L'IMAGE${N}
  ${C}--banc / --no-banc${N}        activer (ou non) osmo-banc.service au boot   ${D}[${OSMO_ISO_BANC:-0}]${N}
  ${C}--multi / --no-multi${N}      activer (ou non) osmo-multi.service au boot  ${D}[${OSMO_ISO_MULTI:-1}]${N}
  ${C}--kb=LANG${N}                 disposition clavier                          ${D}[${OSMO_ISO_KB:-fr}]${N}

${B}LE LIEN ENTRE NOEUDS (WAN)${N}
  ${C}--wan${N}                     active la table WAN
  ${C}--wan-nodes=LISTE${N}         <noeud>:<IP>:<indicatif>, separes par des espaces
                            ${D}[${ISO_WAN_NODES_DEFAULT:-}]${N}
  ${C}--wan-id=N${N}                numero de CE noeud dans la table
  ${C}--wan-ops=N${N}               nombre d'operateurs sur ce noeud
  ${C}--hub-ip=IP${N}               adresse du hub SS7

${B}LA BASE${N}
  ${C}--version=22.04|24.04${N}     suite Ubuntu du rootfs                       ${D}[${ISO_UBUNTU:-24.04}]${N}
  --arm, --arch=arm64       image SD arm64 pour Raspberry Pi 4 (base Armbian).
                            Ni --desktop ni --all sur cette cible. Le premier
                            build emule aarch64 : comptez une dizaine d'heures.
  ${C}--arch=amd64${N}              le defaut.

  ${C}-h, --help${N}                ceci.

${B}Equivalents en variables${N} (pour la CI, ou un environnement sans ligne de commande) :
  OSMO_ISO_BUILD_DOCKER=1   comme --build-docker
  OSMO_ISO_WITHOUT_DEBS=1   comme --without-debs
  OSMO_ISO_PULL_IMAGE=REF   l'image de --skip-build
  OSMO_ISO_BANC=1 / OSMO_ISO_MULTI=1 / OSMO_ISO_KB=fr / OSMO_ISO_VERSION=...
  OSMO_ISO_WORK=/chemin     repertoire de travail (defaut /var/tmp, PAS /tmp qui
                            est souvent un tmpfs : le rootfs n'y tient pas)
  OSMO_DEB_CACHE=/chemin    cache des .deb de l'hote   ${D}[/var/cache/osmo-debs]${N}
EOF
}

for arg in "$@"; do case "$arg" in
    -h|--help)      iso_usage; exit 0 ;;
    --output=*)     OUTPUT="${arg#*=}"; OUTPUT_SET=1 ;;
    --no-cache)     NO_CACHE="--no-cache" ;;
    --wan)          ISO_WAN=1 ;;
    --wan-nodes=*)  ISO_WAN=1; ISO_WAN_NODES="${arg#*=}" ;;
    --wan-id=*)     ISO_WAN=1; ISO_WAN_ID="${arg#*=}" ;;
    --wan-ops=*)    ISO_WAN=1; ISO_WAN_OPS="${arg#*=}" ;;
    --role=*)       ISO_ROLE="${arg#*=}"; ISO_ROLE_GIVEN=1 ;;
    --node=*)       ISO_NODE="${arg#*=}" ;;
    --hub-ip=*)     ISO_HUB_IP="${arg#*=}" ;;
    --kb=*)         OSMO_ISO_KB="${arg#*=}" ;;
    --version=*)    ISO_UBUNTU="${arg#*=}" ;;
    # Forme en deux mots (`--version 24.04`) : la boucle est un `for` sans
    # shift, donc le drapeau memorise que la valeur arrive au tour suivant, et
    # le motif ci-dessous la ramasse. Ces valeurs ne signifient rien d autre
    # dans la ligne de commande : aucun risque de collision.
    --version)      ISO_UBUNTU_NEXT=1 ;;
    22.04|24.04|jammy|noble)
                    if [ "${ISO_UBUNTU_NEXT:-0}" = 1 ]; then
                        ISO_UBUNTU="$arg"; ISO_UBUNTU_NEXT=0
                    fi ;;
    # ── LE BANC AU BOOT : NON, SAUF DEMANDE EXPLICITE ────────────────────
    # osmo-banc.service et osmo-multi.service sont POSES dans toutes les images
    # (82-services.sh) mais plus ACTIVES : une machine fraichement installee
    # demarre sur son bureau, pas sur une pile radio qu'on n'a pas encore
    # configuree. --banc / --multi (ou OSMO_ISO_BANC=1 / OSMO_ISO_MULTI=1)
    # rendent l'activation au demarrage, image par image.
    --banc)         OSMO_ISO_BANC=1 ;;
    --no-banc)      OSMO_ISO_BANC=0 ;;
    --multi)        OSMO_ISO_MULTI=1 ;;
    --no-multi)     OSMO_ISO_MULTI=0 ;;
    --lite)         ISO_LITE=1 ;;
    --desktop)      ISO_DESKTOP=1 ;;
    --all)          ISO_ALL=1 ;;
    --skip-build)   ISO_SKIP_BUILD=1 ;;
    --skip-build=*) ISO_SKIP_BUILD=1; ISO_PULL_IMAGE="${arg#*=}" ;;
    --build-docker) ISO_FORCE_BUILD=1 ;;
    --without-debs) ISO_WITH_DEBS=0 ;;
    --with-debs)    ISO_WITH_DEBS=1 ;;
    --arm|--arch=arm64) ISO_ARCH=arm64 ;;
    --arch=amd64)   ISO_ARCH=amd64 ;;
    --arch=*)       echo -e "${RED}--arch : amd64 ou arm64 (recu : ${arg#*=})${NC}" >&2; exit 2 ;;
esac; done

# Arbitrage APRES la boucle, pour que l ordre des options sur la ligne de
# commande ne decide de rien : --build-docker l emporte sur --skip-build, d ou
# qu il vienne (ligne de commande ou variable).
if [ "$ISO_FORCE_BUILD" = "1" ] && [ "$ISO_SKIP_BUILD" = "1" ]; then
    echo -e "${YELLOW}--build-docker : --skip-build ignore, l image sera construite localement${NC}"
    ISO_SKIP_BUILD=0
fi
# Sans .deb embarquees, celles du build docker ne restent pas non plus dans le
# rootfs (50-injection-image.sh les efface sauf ISO_EMBED_DEBS=1).
[ "$ISO_WITH_DEBS" = "0" ] && ISO_EMBED_DEBS=0
export ISO_FORCE_BUILD ISO_WITH_DEBS

# ── BASE UBUNTU : 22.04 (jammy) ou 24.04 (noble) ──────────────────────────────
# Le nom de suite etait ecrit EN DUR a quatre endroits (debootstrap, les trois
# lignes de sources.list). Une seule variable maintenant, et un seul endroit ou
# la faire varier.
#
# Defaut 24.04 (noble) : c est la base du Dockerfile depuis le 2026-09-03, et
# l ISO DOIT partir de la meme suite que l image dont elle copie /usr/local et
# le venv /root/.env (python 3.12, glibc 2.39, bibliotheques *t64). Un rootfs
# jammy sous une image noble donnerait un venv sans interpreteur et des .so
# sans leurs symboles. La verification est faite plus bas, sur l os-release de
# l image source. 22.04 reste accepte pour une image construite sur jammy.
: "${ISO_UBUNTU:=24.04}"
case "$ISO_UBUNTU" in
    22.04|jammy) ISO_UBUNTU=22.04; ISO_SUITE=jammy ;;
    24.04|noble) ISO_UBUNTU=24.04; ISO_SUITE=noble ;;
    *) echo -e "${RED}--version : 22.04 ou 24.04 (recu : $ISO_UBUNTU)${NC}" >&2; exit 2 ;;
esac
export ISO_UBUNTU ISO_SUITE

# Ce qui decoule de l architecture : le miroir (arm64 n est PAS sur
# archive.ubuntu.com mais sur ports), le suffixe des images docker (les deux
# architectures cohabitent sur le meme hote sans s ecraser), le format de
# sortie. ISO_IMG_TAG s ajoute au nom des images : osmocom-nitb:arm64.
case "$ISO_ARCH" in
    amd64) ISO_MIRROR="$(bash "$DIR/packaging/apt-mirror.sh" "$ISO_SUITE" 2>/dev/null || echo http://archive.ubuntu.com/ubuntu)"; ISO_IMG_TAG="" ;;
    arm64) ISO_MIRROR="http://ports.ubuntu.com/ubuntu-ports"; ISO_IMG_TAG=":arm64" ;;
esac
export ISO_ARCH ISO_MIRROR ISO_IMG_TAG
if [ "$ISO_ARCH" = "arm64" ]; then
    [ "$ISO_DESKTOP" = "1" ] && { echo -e "${RED}--arm : pas de --desktop (GNOME, calamares, grub-efi-amd64 : rien de tout cela sur le Pi)${NC}" >&2; exit 2; }
    [ "$ISO_ALL" = "1" ]     && { echo -e "${RED}--arm : pas de --all - une image a la fois (--role=operator, --lite ou --role=interstp)${NC}" >&2; exit 2; }
    echo -e "  ${CYAN}cible : arm64 / Raspberry Pi 4, base Armbian ${ISO_UBUNTU} - image SD .img, miroir ${ISO_MIRROR}${NC}"
fi

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
