#!/bin/bash
# =============================================================================
#  build.sh - prepare l hote et construit l image osmocom-nitb
# =============================================================================
#
#  [2026-09-03] TROIS CHANGEMENTS, LIES :
#
#  1. apt-fast partout. packaging/apt-fast-install.sh pose apt-fast (aria2) et
#     les reglages apt communs, sur l hote comme dans les images et le rootfs
#     de l ISO. Un seul installeur, une seule facon de parler a apt.
#
#  2. docker compose v2 (+ buildx) est une DEPENDANCE, pas une option : il est
#     installe avec docker, et c est lui qui construit les images
#     (compose.yaml : services nitb, run, lite, stp). `docker build` reste le
#     repli si compose manque.
#
#  3. LE CACHE .deb SUR L HOTE. Chaque dossier compile dans l image sort en
#     paquet (.deb) - packaging/osmo-deb.sh. Ces paquets vivent dans
#         /var/cache/osmo-debs          (OSMO_DEB_CACHE pour deplacer)
#     Avant le build, on les recopie dans .deb-cache/ (le contexte docker) ;
#     l image les pose par dpkg au lieu de recompiler. Apres le build, on
#     ramene ce que l image a produit dans le cache de l hote. Le premier
#     build compile tout ; les suivants ne compilent que ce qui manque.
#     --no-cache : OSMO_DEB_REFRESH=1, tout est recompile et le cache reecrit.
#
#  Usage : sudo ./build.sh [--no-cache] [--lite] [--stp]
# =============================================================================
set -euo pipefail

# Contexte de build : le repertoire de CE script, pas le cwd de l appelant.
# Le lanceur .desktop passe par pkexec, qui demarre dans /root : sans ce cd,
# "docker build ." cherche /root/Dockerfile et echoue.
cd "$(dirname "$(readlink -f "$0")")"
DIR="$(pwd)"
# /usr/local/sbin DANS le PATH : apt-fast-install pose apt-fast la (comme le
# Dockerfile). Un root dont le PATH ne le contient pas (shell perso, sans sudo)
# voyait "[apt-fast] pret : /usr/local/sbin/apt-fast" puis "apt-fast: command
# not found" a la ligne suivante.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# 0. Parsing des arguments
NO_CACHE=""
LITE=0
STP=0
for arg in "$@"; do
    case "$arg" in
        --no-cache) NO_CACHE="--no-cache" ;;
        --lite)     LITE=1 ;;
        --stp)      STP=1 ;;
        -h|--help)
            echo "Usage: sudo $0 [--no-cache] [--lite] [--stp]"
            echo "  --no-cache   Reconstruction complete : cache docker ignore, paquets .deb recompiles"
            echo "               et le cache /var/cache/osmo-debs reecrit."
            echo "  --lite       Construit EN PLUS osmocom-nitb:lite : la meme pile, sans les"
            echo "               arbres de sources de /opt/GSM (~4 Go sur 11). Voir Dockerfile.lite."
            echo "  --stp        Construit EN PLUS osmocom-stp (Dockerfile.stp), le hub SS7 seul."
            echo ""
            echo "  OSMO_DEB_CACHE=/chemin   cache des .deb compiles (defaut /var/cache/osmo-debs)"
            exit 0
            ;;
        *) echo -e "${YELLOW}[WARN] Argument inconnu ignore : $arg${NC}" ;;
    esac
done

# 1. Verification des privileges ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit etre lance en tant que root (sudo).${NC}"
   exit 1
fi

echo "--- Preparation complete de l'hote (SDR & Docker) ---"
export DEBIAN_FRONTEND=noninteractive

# 2. apt-fast sur l hote : le meme installeur que dans les images
echo "[*] apt-fast (packaging/apt-fast-install.sh)..."
bash "$DIR/packaging/apt-fast-install.sh" || echo -e "${YELLOW}[WARN] apt-fast non installe - apt-get${NC}"
command -v apt-fast >/dev/null 2>&1 || apt-fast() { apt-get "$@"; }
apt-fast update -qq || true

# 3. Docker, docker compose v2 et buildx : TOUJOURS dans les dependances.
#    (Avant, compose n etait pose qu avec docker, quand docker manquait : un
#    hote qui avait deja docker.io ne l obtenait jamais.)
echo "[*] Docker + docker compose v2 + buildx..."
apt-fast install -y --no-install-recommends docker.io docker-compose-v2 docker-buildx \
    || apt-fast install -y --no-install-recommends docker.io docker-compose-v2 \
    || { echo -e "${RED}[ERREUR] docker / docker-compose-v2 non installables.${NC}"; exit 1; }
systemctl enable --now docker >/dev/null 2>&1 || true
HAVE_COMPOSE=0
docker compose version >/dev/null 2>&1 && HAVE_COMPOSE=1
[ "$HAVE_COMPOSE" = 1 ] && echo -e "${GREEN}[OK] $(docker compose version)${NC}" \
    || echo -e "${YELLOW}[WARN] docker compose absent - repli sur docker build${NC}"

# 4. Installation des dependances critiques sur l'hote
# SCTP est vital pour les protocoles de signalisation Osmocom
echo "[*] Installation de SCTP, TUN et D-Bus sur l'hote..."
apt-fast install -y lksctp-tools libsctp-dev dbus uml-utilities libusb-1.0-0-dev \
     wireshark linphone* gnome-terminal whiptail expect netcat-openbsd \
     telnet iproute2 pulseaudio-utils dpkg-dev zstd

# 4b. toast : le codec GSM 06.10 (quut.com), absent du paquet apt
# libgsm1 (apt) fournit la LIB mais pas le binaire toast/untoast/tcat. On le
# compile depuis les sources officielles, SOUS /opt/GSM, et on pose le binaire
# dans /usr/local/bin. Non fatal : sans reseau on continue le build.
echo "[*] Compilation de toast (codec GSM 06.10)..."
_GSM_VER=gsm-1.0.24
_GSM_DIR=gsm-1.0-pl24   # le tarball se decompresse SOUS ce nom
_GSM_URL="https://www.quut.com/gsm/${_GSM_VER}.tar.gz"
if command -v toast >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] toast deja present ($(command -v toast)).${NC}"
else
    apt-fast install -y --no-install-recommends build-essential wget >/dev/null 2>&1 || true
    mkdir -p /opt/GSM
    if ( cd /opt/GSM \
         && wget -qO "${_GSM_VER}.tar.gz" "$_GSM_URL" \
         && tar xzf "${_GSM_VER}.tar.gz" \
         && cd "$_GSM_DIR" \
         && { make >/dev/null 2>&1 || true; } \
         && { [ -x bin/toast ] || make toast >/dev/null 2>&1 || true; } \
         && [ -x bin/toast ] ); then
        for _b in toast untoast tcat; do
            [ -e "/opt/GSM/${_GSM_DIR}/bin/$_b" ] \
                && install -m755 "/opt/GSM/${_GSM_DIR}/bin/$_b" "/usr/local/bin/$_b"
        done
        echo -e "${GREEN}[OK] toast installe dans /usr/local/bin (sources : /opt/GSM/${_GSM_DIR}).${NC}"
    else
        echo -e "${YELLOW}[WARN] compilation de toast echouee (reseau ou outils ?) - on continue.${NC}"
    fi
fi

# 5. Chargement des modules noyau
echo "[*] Chargement des modules noyau (SCTP & TUN)..."
modprobe sctp
modprobe tun

# Verification du module SCTP (lecture directe de /proc/modules : pas de tube,
# donc pas de SIGPIPE/pipefail, et ancrage sur le nom de module exact)
if grep -q '^sctp ' /proc/modules; then
    echo -e "${GREEN}[OK] Module SCTP charge sur l'hote.${NC}"
else
    echo -e "${RED}[ERREUR] Impossible de charger SCTP.${NC}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. Le cache .deb : de l hote vers le contexte de build
# ══════════════════════════════════════════════════════════════════════════════
OSMO_DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
mkdir -p "$OSMO_DEB_CACHE" "$DIR/.deb-cache"
find "$DIR/.deb-cache" -maxdepth 1 -name '*.deb' -delete
OSMO_DEB_REFRESH=0
if [[ -n "$NO_CACHE" ]]; then
    OSMO_DEB_REFRESH=1
    echo "[*] Mode --no-cache actif : reconstruction complete, paquets .deb recompiles."
else
    cp -f "$OSMO_DEB_CACHE"/osmo-build-*.deb "$DIR/.deb-cache/" 2>/dev/null || true
    # find, pas "ls | wc" : sous pipefail, un ls sans resultat sortait en 2 et
    # set -e arretait le script ici, sans un mot, des le premier build.
    _n=$(find "$DIR/.deb-cache" -maxdepth 1 -name '*.deb' | wc -l)
    if [ "$_n" -gt 0 ]; then
        echo -e "${GREEN}[OK] cache .deb : ${_n} paquets repris de ${OSMO_DEB_CACHE} ($(du -sh "$DIR/.deb-cache" | cut -f1))${NC}"
    else
        echo "[*] cache .deb vide (${OSMO_DEB_CACHE}) : premier build, tout sera compile et mis en cache."
    fi
fi
export OSMO_DEB_REFRESH

# Construit un service de compose.yaml (ou son equivalent docker build).
#   $1 = service (nitb|run|lite|stp)   $2 = image   $3 = Dockerfile   $4.. = build-args
compose_build() {
    local svc="$1" image="$2" dockerfile="$3"; shift 3
    if [ "$HAVE_COMPOSE" = 1 ]; then
        docker compose -f "$DIR/compose.yaml" build $NO_CACHE "$svc"
    else
        local args=(); local a; for a in "$@"; do args+=(--build-arg "$a"); done
        docker build $NO_CACHE "${args[@]+"${args[@]}"}" -f "$DIR/$dockerfile" -t "$image" "$DIR"
    fi
}

# Ramene dans le cache de l hote les paquets que l image vient de produire.
#   $1 = image
debs_from_image() {
    local image="$1" cid n
    cid="$(docker create "$image" /bin/true 2>/dev/null)" || return 0
    mkdir -p "$DIR/.deb-cache/out"
    docker cp "$cid:/var/cache/osmo-debs/." "$DIR/.deb-cache/out/" 2>/dev/null || true
    docker rm "$cid" >/dev/null 2>&1 || true
    n=$(find "$DIR/.deb-cache/out" -maxdepth 1 -name 'osmo-build-*.deb' | wc -l)
    if [ "$n" -gt 0 ]; then
        cp -f "$DIR/.deb-cache/out"/osmo-build-*.deb "$OSMO_DEB_CACHE/"
        echo -e "${GREEN}[OK] cache .deb : ${n} paquets dans ${OSMO_DEB_CACHE} ($(du -sh "$OSMO_DEB_CACHE" | cut -f1))${NC}"
    fi
    rm -rf "$DIR/.deb-cache/out"
}

# 7. Lancement du build Docker
echo "--- Lancement du build de l'image osmocom-nitb ---"
if compose_build nitb osmocom-nitb Dockerfile "OSMO_DEB_REFRESH=$OSMO_DEB_REFRESH"; then
    echo -e "${GREEN}[OK] Image osmocom-nitb construite avec succes.${NC}"
    debs_from_image osmocom-nitb
else
    echo -e "${RED}[ERREUR] Le build Docker a echoue.${NC}"
    exit 1
fi

# 8. Image lite : la meme pile, sans les arbres de sources
# osmocom-nitb embarque /opt/GSM - les arbres de construction de gnuradio,
# gr-gsm, qemu, libosmocore... 4 Go sur 11, qui ont servi a COMPILER et ne
# servent plus a rien ensuite : ce qui tourne vit dans /usr/local.
# Dockerfile.lite les retire et aplatit le resultat (voir son entete : effacer
# dans une couche de plus ne rend aucun espace).
if [[ "$LITE" -eq 1 ]]; then
    echo "--- Lancement du build de l'image osmocom-nitb:lite ---"
    if LITE_BASE=osmocom-nitb LITE_IMAGE=osmocom-nitb:lite \
       compose_build lite osmocom-nitb:lite Dockerfile.lite "BASE=osmocom-nitb"; then
        echo -e "${GREEN}[OK] Image osmocom-nitb:lite construite.${NC}"
        docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' \
            | grep -E '^\s+osmocom-nitb:(latest|lite)' || true
    else
        echo -e "${RED}[ERREUR] Le build de l'image lite a echoue.${NC}"
        exit 1
    fi
fi

# 9. Image STP : le hub SS7 seul (Dockerfile.stp), avec le meme cache .deb
if [[ "$STP" -eq 1 ]]; then
    echo "--- Lancement du build de l'image osmocom-stp ---"
    if compose_build stp osmocom-stp Dockerfile.stp "OSMO_DEB_REFRESH=$OSMO_DEB_REFRESH"; then
        echo -e "${GREEN}[OK] Image osmocom-stp construite.${NC}"
        debs_from_image osmocom-stp
    else
        echo -e "${RED}[ERREUR] Le build de l'image stp a echoue.${NC}"
        exit 1
    fi
fi

# Le contexte ne garde pas les paquets : ils sont dans le cache de l hote.
find "$DIR/.deb-cache" -maxdepth 1 -name '*.deb' -delete
