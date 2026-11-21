#!/bin/bash
# =============================================================================
#  build.sh - prepare the host and build the osmocom-nitb image
# =============================================================================
#
#  Usage: sudo ./build.sh [--no-cache] [--lite] [--stp] [--build-run] [--fast] [--arch=arm64|--arm]
#         (-h describes every option)
#
#  - apt-fast everywhere: packaging/apt-fast-install.sh installs apt-fast
#    (aria2) and the common apt settings on the host, in the images and in the
#    ISO rootfs.
#  - docker compose v2 (+ buildx) is a dependency: it builds the images
#    (compose.yaml: services nitb, run, lite, stp). `docker build` is the
#    fallback when compose is missing.
#  - .deb cache on the host: every tree compiled in the image is packaged as a
#    .deb (packaging/osmo-deb.sh) and stored in
#        /var/cache/osmo-debs          (OSMO_DEB_CACHE to relocate)
#    Before the build they are copied into .deb-cache/ (the docker context) and
#    the image installs them with dpkg instead of recompiling; after the build
#    the packages produced by the image are copied back to the host cache.
#    The first build compiles everything, later ones only what is missing.
#    --no-cache sets OSMO_DEB_REFRESH=1: everything is recompiled and the
#    cache rewritten.
#
#  Env: OSMO_DEB_CACHE, OSMO_UBUNTU_MIRROR, OSMO_HOST_MIRROR (0|1|force),
#       OSMO_HOST_DOCKER (0 = never ask apt for docker), BUILDKIT_PROGRESS.
# =============================================================================
set -euo pipefail

# Build context: the directory of THIS script, not the caller's cwd (the
# .desktop launcher goes through pkexec, which starts in /root).
cd "$(dirname "$(readlink -f "$0")")"
DIR="$(pwd)"
# /usr/local/sbin in PATH: apt-fast-install puts apt-fast there (as the
# Dockerfile does); a root shell without it in PATH would not find apt-fast.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# 0. Argument parsing
NO_CACHE=""
LITE=0
STP=0
BUILD_RUN=0
FAST=0
OSMO_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
for arg in "$@"; do
    case "$arg" in
        --no-cache) NO_CACHE="--no-cache" ;;
        --lite)     LITE=1 ;;
        --stp)      STP=1 ;;
        --build-run) BUILD_RUN=1 ;;
        --fast)     FAST=1 ;;
        --arch=*)   OSMO_ARCH="${arg#*=}" ;;
        --arm)      OSMO_ARCH=arm64 ;;
        -h|--help)
            echo "Usage: sudo $0 [--no-cache] [--lite] [--stp] [--build-run] [--fast] [--arch=arm64|--arm]"
            echo "  --fast       Build rapide d osmocom-nitb : ce que osmo-minioperator prend en .deb"
            echo "               n est pas compile. Pile Osmocom = paquets officiels Osmocom (OBS"
            echo "               latest, SANS les patches osmo-trx +ipc et bts/hlr/msc +rand) ;"
            echo "               qosmo, c54x_exe (sans ROM), grgsm_exe, gnuradio + gr-gsm, firmware ="
            echo "               nos .deb de la release osmo-operator debs-2026-11-21 (SHA-256"
            echo "               verifies, mis dans le cache .deb). amd64 seulement."
            echo "  --arch=arm64 Construit les images pour arm64 (Raspberry Pi 4) sur cet hote,"
            echo "               par docker buildx --platform linux/arm64 sous qemu-user-static."
            echo "               Images taguees :arm64 (osmocom-nitb:arm64...). LENT au premier"
            echo "               build (emulation) ; le cache .deb rend les suivants courts."
            echo "               Pose aussi sur l hote tout ce que la chaine arm64 demande :"
            echo "               qemu-user-static, binfmt-support, docker-buildx, debootstrap,"
            echo "               mtools, dosfstools, e2fsprogs, kpartx... (build-iso.sh --arm,"
            echo "               armbian/build-armbian.sh)."
            echo "  --no-cache   Reconstruction complete : cache docker ignore, paquets .deb recompiles"
            echo "               et le cache /var/cache/osmo-debs reecrit."
            echo "  --lite       Construit EN PLUS osmocom-nitb:lite : la meme pile, sans les"
            echo "               arbres de sources de /opt/GSM (~4 Go sur 11). Voir Dockerfile.lite."
            echo "  --stp        Construit EN PLUS osmocom-stp (Dockerfile.stp), le hub SS7 seul."
            echo "  --build-run  Construit SEULEMENT osmocom-run (Dockerfile.run) sur l image"
            echo "               osmocom-nitb deja presente, puis s arrete : ni preparation de"
            echo "               l hote, ni rebuild de la base. QEMU_CACHE_BUST force les git pull."
            echo ""
            echo "  OSMO_DEB_CACHE=/chemin   cache des .deb compiles (defaut /var/cache/osmo-debs)"
            exit 0
            ;;
        *) echo -e "${YELLOW}[WARN] Argument inconnu ignore : $arg${NC}" ;;
    esac
done

# --fast: amd64 only (the release .debs are amd64).
if [[ "$FAST" -eq 1 ]]; then
    case "$OSMO_ARCH" in
        amd64|x86_64) ;;
        *) echo -e "${RED}[ERREUR] --fast : les .deb de la release sont amd64 seulement (arch : $OSMO_ARCH)${NC}"
           exit 1 ;;
    esac
fi
export OSMO_FAST="$FAST"

# --build-run: only the update layer (Dockerfile.run), on top of the local
# osmocom-nitb image: nothing to prepare on the host.
if [[ "$BUILD_RUN" -eq 1 ]]; then
    if ! docker image inspect osmocom-nitb >/dev/null 2>&1; then
        echo -e "${RED}[ERREUR] image osmocom-nitb absente : lancer d abord sudo $0${NC}"
        exit 1
    fi
    echo "--- Lancement du build de l'image osmocom-run ---"
    if docker build $NO_CACHE --build-arg QEMU_CACHE_BUST=$(date +%s) \
           -f "$DIR/Dockerfile.run" -t osmocom-run "$DIR"; then
        echo -e "${GREEN}[OK] Image osmocom-run construite.${NC}"
        exit 0
    fi
    echo -e "${RED}[ERREUR] Le build de l'image osmocom-run a echoue.${NC}"
    exit 1
fi

# 1. Root privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit etre lance en tant que root (sudo).${NC}"
   exit 1
fi

echo "--- Preparation complete de l'hote (SDR & Docker) ---"
export DEBIAN_FRONTEND=noninteractive

# 2. apt-fast on the host: the same installer as in the images
echo "[*] apt-fast (packaging/apt-fast-install.sh)..."
bash "$DIR/packaging/apt-fast-install.sh" || echo -e "${YELLOW}[WARN] apt-fast non installe - apt-get${NC}"
command -v apt-fast >/dev/null 2>&1 || apt-fast() { apt-get "$@"; }

# ── Ubuntu mirror: measured, not assumed - for the image AND the host ────────
# packaging/apt-mirror.sh benchmarks a few mirrors:
#   - the fastest goes into the image as a build-arg (compose reads it from the
#     environment); OSMO_UBUNTU_MIRROR=http://... forces a mirror;
#   - if archive.ubuntu.com does NOT answer and the host apt sources point to
#     it, they are switched to the fastest mirror, with a backup (*.osmo-bak),
#     otherwise no host package (qemu-user-static, docker...) could be
#     installed. OSMO_HOST_MIRROR=0 forbids touching the host sources,
#     OSMO_HOST_MIRROR=force switches them even if archive answers (slowly).
echo "[*] Miroir Ubuntu (packaging/apt-mirror.sh)..."
_MLIST="$(bash "$DIR/packaging/apt-mirror.sh" --list noble 2>&1 | tee /dev/stderr | grep -E '^[0-9]+' || true)"
OSMO_UBUNTU_MIRROR="${OSMO_UBUNTU_MIRROR:-$(printf '%s\n' "$_MLIST" | head -1 | cut -f2)}"
OSMO_UBUNTU_MIRROR="${OSMO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
export OSMO_UBUNTU_MIRROR
echo -e "${GREEN}[OK] miroir : ${OSMO_UBUNTU_MIRROR}${NC}"
if { [ "${OSMO_HOST_MIRROR:-1}" = "force" ] || { [ "${OSMO_HOST_MIRROR:-1}" = "1" ] && ! printf '%s\n' "$_MLIST" | grep -q 'archive\.ubuntu\.com'; }; } \
   && [ "$OSMO_UBUNTU_MIRROR" != "http://archive.ubuntu.com/ubuntu" ]; then
    _switched=""
    for _f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$_f" ] || continue
        grep -qE '^(deb|deb-src|URIs:).*https?://(archive|[a-z]{2}\.archive|security)\.ubuntu\.com/ubuntu' "$_f" || continue
        cp -f "$_f" "$_f.osmo-bak"
        sed -i -E "s#https?://(archive|[a-z]{2}\.archive|security)\.ubuntu\.com/ubuntu/?#${OSMO_UBUNTU_MIRROR}#g" "$_f"
        _switched="$_switched $_f"
    done
    if [ -n "$_switched" ]; then
        echo -e "${YELLOW}[WARN] archive.ubuntu.com ne repond pas : sources apt de l hote basculees sur ${OSMO_UBUNTU_MIRROR}${NC}"
        echo -e "${YELLOW}       (sauvegarde en *.osmo-bak :${_switched} ; OSMO_HOST_MIRROR=0 pour ne pas y toucher)${NC}"
    fi
fi
apt-fast update -qq || true

# 3. Docker, docker compose v2 and buildx: always dependencies, but only what
#    is MISSING is installed - never docker.io when docker is already there
#    (docker-ce + containerd.io conflict with it). Both package namings are
#    accepted: docker-compose-v2 / docker-buildx (Ubuntu) and
#    docker-compose-plugin / docker-buildx-plugin (Docker repository).
#    OSMO_HOST_DOCKER=0: do not ask apt for anything docker-related (a GitHub
#    runner ships docker, compose v2 and buildx as moby-* packages).
echo "[*] Docker + docker compose v2 + buildx..."
if [ "${OSMO_HOST_DOCKER:-1}" = 0 ]; then
    echo -e "${GREEN}[OK] docker : installation sautee (OSMO_HOST_DOCKER=0) - $(docker --version 2>/dev/null || echo 'docker introuvable, la suite dira si c est un probleme')${NC}"
elif command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] docker deja installe ($(docker --version 2>/dev/null || echo version inconnue)) - pas touche${NC}"
    docker info >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
    docker compose version >/dev/null 2>&1 \
        || apt-fast install -y --no-install-recommends docker-compose-v2 \
        || apt-fast install -y --no-install-recommends docker-compose-plugin \
        || echo -e "${YELLOW}[WARN] docker present mais pas de compose v2 : compose.sh basculera sur docker build${NC}"
    docker buildx version >/dev/null 2>&1 \
        || apt-fast install -y --no-install-recommends docker-buildx \
        || apt-fast install -y --no-install-recommends docker-buildx-plugin \
        || echo -e "${YELLOW}[WARN] buildx absent : --arch=arm64 ne marchera pas sur cet hote${NC}"
else
    apt-fast install -y --no-install-recommends docker.io docker-compose-v2 docker-buildx \
        || apt-fast install -y --no-install-recommends docker.io docker-compose-v2 \
        || apt-fast install -y --no-install-recommends docker.io \
        || command -v docker >/dev/null 2>&1 \
        || { echo -e "${RED}[ERREUR] docker / docker-compose-v2 non installables.${NC}"; \
             echo -e "${RED}        (docker absent du PATH : $PATH)${NC}"; \
             echo -e "${RED}        OSMO_HOST_DOCKER=0 pour sauter cette etape si docker est pose autrement.${NC}"; exit 1; }
fi
systemctl enable --now docker >/dev/null 2>&1 || true
HAVE_COMPOSE=0
docker compose version >/dev/null 2>&1 && HAVE_COMPOSE=1
# BuildKit output stays the default (tty, folded). To read everything a step
# writes (a one-hour compilation, a silent apt):
#     BUILDKIT_PROGRESS=plain ./build.sh
# Applies to docker compose build AND docker build (and buildx).
export BUILDKIT_PROGRESS="${BUILDKIT_PROGRESS:-auto}"

# ── Target architecture: the host's, or another one through buildx ──────────
# --arch=arm64 on an x86 host: docker buildx build --platform linux/arm64, with
# qemu-user-static emulating aarch64 in the build containers. binfmt_misc must
# carry the F (fix-binary) flag, otherwise the container cannot find the
# emulator. Images are tagged :arm64 to coexist with the native ones. The .deb
# cache is already per architecture (osmo-deb names packages ..._arm64.deb).
HOST_ARCH="$(dpkg --print-architecture)"
BUILD_PLATFORM=""; IMG_TAG=""
if [ "$OSMO_ARCH" != "$HOST_ARCH" ]; then
    case "$OSMO_ARCH" in
        arm64) BUILD_PLATFORM=linux/arm64 ;;
        amd64) BUILD_PLATFORM=linux/amd64 ;;
        *) echo -e "${RED}[ERREUR] --arch : amd64 ou arm64 (recu : $OSMO_ARCH)${NC}"; exit 2 ;;
    esac
    IMG_TAG=":$OSMO_ARCH"
    # Everything the --arm chain needs on the host, installed once here: the
    # emulation (qemu-user-static, binfmt-support) and buildx for this image,
    # then the tools of build-iso.sh --arm (iso_modules/20-hote.sh,
    # ISO_HOST_PKGS_COMMON: debootstrap, mke2fs -d, mcopy, sfdisk, kpartx,
    # zstd, python3-pil...) and of armbian/build-armbian.sh (git, docker,
    # qemu-user for the customize-image.sh chroot).
    echo "[*] Paquets hote de la chaine ${OSMO_ARCH} : emulation, buildx, outils d image SD..."
    apt-fast install -y --no-install-recommends qemu-user-static binfmt-support docker-buildx \
        git debootstrap rsync wget curl ca-certificates gnupg zstd xz-utils cpio file gcc make \
        python3 python3-pil python3-yaml e2fsprogs fdisk util-linux dosfstools mtools kpartx \
        || apt-fast install -y --no-install-recommends qemu-user-static binfmt-support \
        || echo -e "${YELLOW}[WARN] qemu-user-static non installe (apt) - binfmt via docker ci-dessous${NC}"
    _bf="/proc/sys/fs/binfmt_misc/qemu-${OSMO_ARCH/arm64/aarch64}"
    _bf="${_bf/amd64/x86_64}"
    [ -e "$_bf" ] || update-binfmts --enable "$(basename "$_bf")" >/dev/null 2>&1 || true
    if ! { [ -e "$_bf" ] && grep -q '^flags:.*F' "$_bf"; }; then
        echo "[*] binfmt $(basename "$_bf") sans drapeau F : enregistrement via tonistiigi/binfmt..."
        docker run --privileged --rm tonistiigi/binfmt --install "${OSMO_ARCH}" >/dev/null 2>&1 || true
    fi
    if [ -e "$_bf" ] && grep -q '^flags:.*F' "$_bf"; then
        echo -e "${GREEN}[OK] emulation ${OSMO_ARCH} (binfmt fix-binary) - images taguees ${IMG_TAG}${NC}"
    else
        echo -e "${RED}[ERREUR] binfmt ${OSMO_ARCH} indisponible (qemu-user-static, binfmt-support)${NC}"; exit 1
    fi
    docker buildx version >/dev/null 2>&1 || { echo -e "${RED}[ERREUR] docker buildx requis pour --arch${NC}"; exit 1; }
fi
IMG_NITB="osmocom-nitb${IMG_TAG}"
IMG_LITE="osmocom-nitb:lite${IMG_TAG:+-$OSMO_ARCH}"
IMG_STP="osmocom-stp${IMG_TAG}"
[ "$HAVE_COMPOSE" = 1 ] && echo -e "${GREEN}[OK] $(docker compose version)${NC}" \
    || echo -e "${YELLOW}[WARN] docker compose absent - repli sur docker build${NC}"

# 4. Critical host dependencies
# SCTP is required by the Osmocom signalling protocols
echo "[*] Installation de SCTP, TUN et D-Bus sur l'hote..."
apt-fast install -y lksctp-tools libsctp-dev dbus uml-utilities libusb-1.0-0-dev \
     wireshark linphone* gnome-terminal whiptail expect netcat-openbsd \
     telnet iproute2 pulseaudio-utils dpkg-dev zstd

# 4b. toast: the GSM 06.10 codec (quut.com), missing from apt
# libgsm1 (apt) ships the library but not the toast/untoast/tcat binaries.
# Built from the official sources under /opt/GSM, binaries installed in
# /usr/local/bin. Non-fatal: without network the build goes on.
echo "[*] Compilation de toast (codec GSM 06.10)..."
_GSM_VER=gsm-1.0.24
_GSM_DIR=gsm-1.0-pl24   # the tarball extracts under this name
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

# 5. Kernel modules
echo "[*] Chargement des modules noyau (SCTP & TUN)..."
modprobe sctp
modprobe tun

# SCTP module check (direct read of /proc/modules: no pipe, hence no
# SIGPIPE/pipefail, and anchored on the exact module name)
if grep -q '^sctp ' /proc/modules; then
    echo -e "${GREEN}[OK] Module SCTP charge sur l'hote.${NC}"
else
    echo -e "${RED}[ERREUR] Impossible de charger SCTP.${NC}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. The .deb cache: from the host to the build context
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
    # find, not "ls | wc": under pipefail an empty ls exits 2 and set -e would
    # stop the script silently on the first build.
    _n=$(find "$DIR/.deb-cache" -maxdepth 1 -name '*.deb' | wc -l)
    if [ "$_n" -gt 0 ]; then
        echo -e "${GREEN}[OK] cache .deb : ${_n} paquets repris de ${OSMO_DEB_CACHE} ($(du -sh "$DIR/.deb-cache" | cut -f1))${NC}"
    else
        echo "[*] cache .deb vide (${OSMO_DEB_CACHE}) : premier build, tout sera compile et mis en cache."
    fi
fi
export OSMO_DEB_REFRESH

# ══════════════════════════════════════════════════════════════════════════════
# 6a. --fast: our prebuilt .debs, from the osmo-operator release
# ══════════════════════════════════════════════════════════════════════════════
# qosmo, grgsm_exe, gnuradio + gr-gsm (grgsm-venv), the Calypso firmware and
# c54x_exe WITHOUT the TI mask ROM (the Dockerfile fetches the ROM from
# freecalypso.org, as for a compiled c54x_exe). Downloaded once into the host
# cache, SHA-256 checked; a package already in the cache is not replaced (a
# local build wins). GitHub turns the "~" of the names into "." in the assets.
# The Osmocom stack itself comes from the OBS packages (Dockerfile, stage base).
FAST_TAG="debs-2026-11-21"
FAST_URL="https://github.com/bbaranoff/osmo-operator/releases/download/${FAST_TAG}"
FAST_DEBS=(
    # local name (in the cache)                          sha256
    "osmo-build-qosmo_0.git~noble_amd64.deb              750f0343e60e5f87957bdec6a973f7082b16202de0ce5d30ef773c1c20d49ba8"
    "osmo-build-grgsm-exe_0.git~noble_amd64.deb          aecfa7ae43c2ee91a76b9cbf40a7df702fed2b69ba3038c922088d33305e4bb4"
    "osmo-build-grgsm-venv_1.git~noble_amd64.deb         cb18fba52cf303c6a342f1ece5a08922f68c71fd232e52b6c43b2dd9bb7dc172"
    "osmo-build-calypso-firmware_0.git~noble_amd64.deb   23ac39b60c596acf374bb0e676c7583d010ad547bbe0286c50fdf0f9330d9d35"
    "fast/c54x-exe-norom_0.git~noble_amd64.deb           6807adcdded5e0bea9ee584e9e4054652beffec5db2c1ce74fc26b540ef65199"
)
rm -rf "$DIR/.deb-cache/fast"
if [[ "$FAST" -eq 1 ]]; then
    echo "[*] --fast : paquets .deb de la release ${FAST_TAG}..."
    mkdir -p "$OSMO_DEB_CACHE/fast" "$DIR/.deb-cache/fast"
    for _e in "${FAST_DEBS[@]}"; do
        read -r _f _sum <<<"$_e"
        _dst="$OSMO_DEB_CACHE/$_f"
        if [ ! -s "$_dst" ]; then
            _asset="$(basename "$_f" | tr '~' '.')"
            echo "    $_asset"
            curl -fL --progress-bar --retry 3 -o "$_dst.part" "$FAST_URL/$_asset" \
                && echo "$_sum  $_dst.part" | sha256sum -c --quiet - \
                && mv -f "$_dst.part" "$_dst" \
                || { rm -f "$_dst.part"; echo -e "${RED}[ERREUR] --fast : $_asset (telechargement ou SHA-256)${NC}"; exit 1; }
        fi
        cp -f "$_dst" "$DIR/.deb-cache/$_f"
    done
    echo -e "${GREEN}[OK] --fast : ${#FAST_DEBS[@]} paquets prets (${OSMO_DEB_CACHE})${NC}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6b. The FreeCalypso cache: official downloads, SHA256 checked, outside Git
# ══════════════════════════════════════════════════════════════════════════════
# .cache/freecalypso (ignored by Git) holds the files the Dockerfile takes from
# freecalypso.org (sms-coding-utils, the DSP ROM 3606 dump). They are downloaded
# once by tools/freecalypso-fetch.sh (with resume: the FTP caps at ~18 KB/s) and
# bind-mounted into the build (RUN --mount=type=bind): never copied into the
# image, never downloaded again on the next build. A file whose SHA256 does not
# match is deleted and the build stops here.
echo "[*] Cache FreeCalypso (.cache/freecalypso)..."
mkdir -p "$DIR/.cache/freecalypso"
if bash "$DIR/tools/freecalypso-fetch.sh" --cache "$DIR/.cache/freecalypso" \
        sms-coding-utils-latest.tar.bz2 dsp-rom-3606-dump.txt; then
    echo -e "${GREEN}[OK] cache FreeCalypso : fichiers presents et verifies (SHA256)${NC}"
elif ls "$DIR/.deb-cache"/osmo-build-sms-coding-utils_*.deb "$DIR/.deb-cache"/osmo-build-c54x-exe_*.deb >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARN] cache FreeCalypso incomplet, mais sms-coding-utils et c54x-exe sont dans le cache .deb : on continue${NC}"
else
    echo -e "${RED}[ERREUR] cache FreeCalypso : telechargement impossible ou SHA256 different (voir ci-dessus)${NC}"
    echo "          origines : ftp://ftp.freecalypso.org/pub/GSM/Calypso/ et https://www.freecalypso.org/pub/GSM/FreeCalypso/"
    exit 1
fi

# Build one compose.yaml service (or its docker build equivalent).
#   $1 = service (nitb|run|lite|stp)   $2 = image   $3 = Dockerfile   $4.. = build-args
compose_build() {
    local svc="$1" image="$2" dockerfile="$3"; shift 3
    # Dockerfile (nitb) does not end with the osmocom-nitb stage: the `debs`
    # stage follows it and only exports the .deb cache for the CI, so without
    # --target docker would build that one. The other Dockerfiles have a single
    # useful target, already the last. compose.yaml carries the same target on
    # its nitb service for the compose branch below.
    local target=()
    [ "$svc" = nitb ] && target=(--target osmocom-nitb)
    if [ -n "$BUILD_PLATFORM" ]; then
        # Other architecture: buildx --platform, --load so the image lands in
        # the local docker (not only in the buildx cache).
        local args=(); local a; for a in "$@"; do args+=(--build-arg "$a"); done
        docker buildx build --platform "$BUILD_PLATFORM" --load $NO_CACHE \
            "${target[@]+"${target[@]}"}" \
            "${args[@]+"${args[@]}"}" -f "$DIR/$dockerfile" -t "$image" "$DIR"
    elif [ "$HAVE_COMPOSE" = 1 ]; then
        docker compose -f "$DIR/compose.yaml" build $NO_CACHE "$svc"
    else
        local args=(); local a; for a in "$@"; do args+=(--build-arg "$a"); done
        docker build $NO_CACHE "${target[@]+"${target[@]}"}" \
            "${args[@]+"${args[@]}"}" -f "$DIR/$dockerfile" -t "$image" "$DIR"
    fi
}

# Copy the packages the image just produced back into the host cache.
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

# 7. Docker build
echo "--- Lancement du build de l'image ${IMG_NITB} ---"
if compose_build nitb "$IMG_NITB" Dockerfile "OSMO_DEB_REFRESH=$OSMO_DEB_REFRESH" "OSMO_UBUNTU_MIRROR=$OSMO_UBUNTU_MIRROR" "OSMO_FAST=$OSMO_FAST"; then
    echo -e "${GREEN}[OK] Image ${IMG_NITB} construite avec succes.${NC}"
    debs_from_image "$IMG_NITB"
else
    echo -e "${RED}[ERREUR] Le build Docker a echoue.${NC}"
    exit 1
fi

# 8. lite image: the same stack without the source trees
# osmocom-nitb embeds /opt/GSM - the build trees of gnuradio, gr-gsm, qemu,
# libosmocore... (4 GB out of 11) which were only needed to compile; what runs
# lives in /usr/local. Dockerfile.lite removes them and flattens the result
# (see its header: deleting in one more layer frees nothing).
if [[ "$LITE" -eq 1 ]]; then
    echo "--- Lancement du build de l'image ${IMG_LITE} ---"
    if LITE_BASE="$IMG_NITB" LITE_IMAGE="$IMG_LITE" \
       compose_build lite "$IMG_LITE" Dockerfile.lite "BASE=$IMG_NITB"; then
        echo -e "${GREEN}[OK] Image ${IMG_LITE} construite.${NC}"
        docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' \
            | grep -E '^\s+osmocom-nitb:(latest|lite)' || true
    else
        echo -e "${RED}[ERREUR] Le build de l'image lite a echoue.${NC}"
        exit 1
    fi
fi

# 9. STP image: the SS7 hub alone (Dockerfile.stp), with the same .deb cache
if [[ "$STP" -eq 1 ]]; then
    echo "--- Lancement du build de l'image ${IMG_STP} ---"
    if compose_build stp "$IMG_STP" Dockerfile.stp "OSMO_DEB_REFRESH=$OSMO_DEB_REFRESH" "OSMO_UBUNTU_MIRROR=$OSMO_UBUNTU_MIRROR"; then
        echo -e "${GREEN}[OK] Image ${IMG_STP} construite.${NC}"
        debs_from_image "$IMG_STP"
    else
        echo -e "${RED}[ERREUR] Le build de l'image stp a echoue.${NC}"
        exit 1
    fi
fi

# The context does not keep the packages: they live in the host cache.
find "$DIR/.deb-cache" -maxdepth 1 -name '*.deb' -delete
rm -rf "$DIR/.deb-cache/fast"
