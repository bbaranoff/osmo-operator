#!/bin/bash
# iso_modules/00-options.sh - command-line options, Ubuntu suite, root check
# Sourced by build-iso.sh in numeric order (same shell, variables and
# functions); not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (that is how --arm skips a step).
# Options: see iso_usage below (build-iso.sh --help).

NO_CACHE=""
# ── WAN: off by default. With --wan the ISO IS a WAN node ───────────────────
# The table is frozen into /etc/osmo-wan.conf in the image; at boot
# start-native.sh sees it (WAN_AUTO=1) and applies it.
#
# ONE ISO for all N machines: each one recognises itself by its IP in the
# table (wan_nodes_detect_self). --wan-id only forces a node when the IP is not
# enough (dynamic DHCP, NAT).
ISO_WAN=0
ISO_WAN_NODES=""
ISO_WAN_ID=""
ISO_WAN_OPS=1

# ── IMAGE ROLE ─────────────────────────────────────────────────────────────
# One build chain, two products:
#
#   --role operator --node N   →  osmo-operator-N.iso
#       A WAN node: full GSM core, its own point codes, its ASP attached to
#       the hub.
#
#   --role interstp            →  interstp.iso
#       The SS7 hub: PC 0.0.0, no operator, it ONLY routes M3UA between nodes.
#
# Without --role the default operator ISO is produced under its default name.
ISO_ROLE=""
ISO_ROLE_GIVEN=0
ISO_NODE=""
# ── LITE VARIANT ───────────────────────────────────────────────────────────
#   --lite  →  osmo-operator-lite.iso
# Same node, built from the pruned runtime image (Dockerfile.lite) instead of
# the build image: the /opt/GSM build trees (gnuradio, gr-gsm, libosmo*,
# osmo-*, qemu objects) are left out of the squashfs. What RUNS is identical.
# The three repositories stay complete (see Dockerfile.lite).
ISO_LITE=0
# ── DESKTOP VARIANT ────────────────────────────────────────────────────────
#   --desktop  →  osmo-operator-desktop.iso
# Same image plus a GNOME desktop (ubuntu-desktop-minimal), GUI wireshark and
# linphone-desktop, for what is not driven from the VTY: reading GSMTAP
# captures in wireshark, placing SIP calls by hand, gr-gsm Qt tools
# (grgsm_livemon). Adds about 2.5 GB to the rootfs, hence a separate variant.
ISO_DESKTOP=0
# --arm: boards for armbian/build-armbian.sh (--board=)
ISO_ARM_BOARD="${OSMO_ISO_BOARD:-all}"
# ── --all: ALL images in one pass ─────────────────────────────────────────
# Without arguments the script builds hub, node and lite node; --all adds the
# desktop image (~2.5 GB larger, so not built by default).
ISO_ALL=0
# ── PULL IS THE DEFAULT (amd64) ────────────────────────────────────────────
# The image is PULLED; build.sh only runs if no published image fits (see
# iso_docker_build in 21-docker-build.sh, which tries references in order).
#
# amd64 ONLY: nothing is published for arm64, so an --arm pass always builds.
# An explicit --skip-build is honoured on both architectures.
#
# --skip-build[=REF] makes the pull MANDATORY (no build.sh fallback, a failure
# is an error) and, with =REF, forces the reference instead of deriving it
# from the repository fingerprint.
ISO_SKIP_BUILD="${OSMO_ISO_SKIP_BUILD:-1}"
# Given on the command line, or only the default? Decides what happens when
# the pull fails: requested -> fatal; default -> fall back to a local build.
ISO_SKIP_BUILD_GIVEN=0
# FIRST image tried: the Docker Hub image, tagged osmocom-nitb. It does NOT
# track the commit (iso_docker_build says so before using it); GHCR
# (fingerprint, then :latest) comes next.
ISO_PULL_IMAGE="${OSMO_ISO_PULL_IMAGE:-bastienbaranoff/norf_gsm:latest}"
# --build-docker: the OPPOSITE of --skip-build, and it wins, wherever the
# --skip-build comes from (CI, a leftover OSMO_ISO_PULL_IMAGE, an alias). The
# image is built locally by build.sh. Env equivalent: OSMO_ISO_BUILD_DOCKER=1.
ISO_FORCE_BUILD="${OSMO_ISO_BUILD_DOCKER:-0}"
# --without-debs: NO .deb is shipped in the image. By default step 7c
# (71-debs-banc.sh) builds the bench packages (osmo-operator, bridge,
# qemu-calypso, calypso-firmware) into the rootfs's /var/cache/osmo-debs so an
# installed machine can rebuild the bench without docker or git. This option
# drops them and forces ISO_EMBED_DEBS=0 so the docker build packages (step 5)
# are not kept either: they are still used to install the stack in the rootfs.
# Env equivalent: OSMO_ISO_WITHOUT_DEBS=1.
ISO_WITH_DEBS=1
[ "${OSMO_ISO_WITHOUT_DEBS:-0}" = "1" ] && ISO_WITH_DEBS=0

# ── ARCHITECTURE: amd64 (PC ISO) or arm64 (SD images) ──────────────────────
# --arm: the SAME stack built for arm64 through the Armbian framework
# (armbian/build-armbian.sh, see below), delivered as SD images rather than a
# live ISO. Everything is built on the x86 host (aarch64 emulated by
# qemu-user-static: SLOW, around ten hours for the first build; the .deb cache
# makes later builds short). No installer and no --all on this target.
ISO_ARCH=amd64
# Default hub: the osmo-inter-stp container on the docker backbone
# (INTER_STP_IP in start-docker.sh). VMs reach it via the LAN -> docker route
# (network/setup-docker-lan-route.sh). VirtualBox host-only (192.168.56.1)
# remains possible via --hub-ip.
ISO_HUB_IP="172.20.0.10"
# ── Default WAN table: the bench ───────────────────────────────────────────
# Format: <node>:<IP>:<prefix>
#   node 1  192.168.1.123  the VM (this ISO)  prefix 11
#   node 2  172.20.0.12    osmo-operator-2    prefix 22   (container)
#   node 3  172.20.0.13    osmo-operator-3    prefix 33   (container)
#   hub     172.20.0.10    osmo-inter-stp                 (not in the table)
# Numbering plan: MSISDN = <node>00<op><ms> (100101 = node 1, op 1, MS 1;
# 200101 = node 2...) - see osmo_msisdn in generate_configs.sh. The prefix
# (11, 22, 33) is dialled to reach another node.
# Used when --wan-nodes is not given (lets non-interactive builds, e.g. CI,
# get past step 7b).
# The SAME table must be kept in start-interstp.sh (WAN_NODES_DEFAULT) and
# start-docker.sh, otherwise point codes no longer match the declared ASes.
ISO_WAN_NODES_DEFAULT="1:192.168.1.123:11 2:172.20.0.12:22 3:172.20.0.13:33"

# ── NO 2G STARTS AT BOOT ──────────────────────────────────────────────────
# osmo-multi.service and osmo-banc.service are installed but not enabled: a
# 2G bench is started by the operator, not as a boot side effect (once
# addition.sh writes /etc/osmocom/osmo-multi.conf, an enabled osmo-multi would
# bring up the whole multi-operator bench at boot).
#   systemctl start osmo-multi          one session (or the desktop icon)
#   systemctl enable --now osmo-multi   start it at every boot
# --multi (or OSMO_ISO_MULTI=1) at build time produces an image that enables
# it, like --banc for osmo-banc.
OSMO_ISO_MULTI="${OSMO_ISO_MULTI:-0}"
export OSMO_ISO_MULTI

OUTPUT_SET=0

# ── --help ─────────────────────────────────────────────────────────────────
# Handled BEFORE the root check (further down): asking for help does not
# require root. Bracketed values are the real defaults, read from the
# variables above.
iso_usage() {
    # The repository colours (BOLD='\033[1m'...) are meant for `echo -e`; a
    # heredoc through `cat` does not interpret them. $'...' (ANSI-C quoting)
    # produces the real escape byte at assignment time.
    local B=$'\033[1m' C=$'\033[36m' D=$'\033[2m' N=$'\033[0m'
    cat <<EOF
${B}build-iso.sh${N} - fabrique une ISO bootable (ou une image SD arm64) a partir
de l'image docker osmocom-nitb. Tout passe par build.sh et start-docker.sh.

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
  ${D}Par defaut, en amd64, l'image est TIREE et non construite, puis taguee
  osmocom-nitb. Dans l'ordre : l'image Docker Hub (bastienbaranoff/norf_gsm:latest),
  puis ghcr.io/<depot>/osmocom-nitb:base-<empreinte du depot>, puis le :latest
  de GHCR. Seule l'image d'empreinte correspond a l'arbre de travail ; pour les
  autres le script previent avant de s'en servir.
  Si aucune ne repond, build.sh prend le relais (1h23). En arm64 rien n'est
  publie : la compilation reste le defaut.${N}
  ${C}--skip-build[=IMAGE]${N}      le pull devient OBLIGATOIRE : pas de repli sur
                            build.sh, et =IMAGE impose la reference au lieu de
                            la deduire de l'empreinte. N'importe quel registre :
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
  ${C}--multi / --no-multi${N}      activer (ou non) osmo-multi.service au boot  ${D}[${OSMO_ISO_MULTI:-0}]${N}
  ${C}--kb=LANG${N}                 disposition clavier                          ${D}[${OSMO_ISO_KB:-fr}]${N}

${B}LA SIM${N}
  ${C}--softsim / --no-softsim${N}  softSIM (SIM via SAP, Ruby) dans /opt/GSM/softsim, pySim et
                            pcscd/CCID pour la carte d un lecteur HID Omnikey    ${D}[${OSMO_ISO_SOFTSIM:-1}]${N}

${B}LE LIEN ENTRE NOEUDS (WAN)${N}
  ${C}--wan${N}                     active la table WAN
  ${C}--wan-nodes=LISTE${N}         <noeud>:<IP>:<indicatif>, separes par des espaces
                            ${D}[${ISO_WAN_NODES_DEFAULT:-}]${N}
  ${C}--wan-id=N${N}                numero de CE noeud dans la table
  ${C}--wan-ops=N${N}               nombre d'operateurs sur ce noeud
  ${C}--hub-ip=IP${N}               adresse du hub SS7

${B}LA BASE${N}
  ${C}--version=22.04|24.04${N}     suite Ubuntu du rootfs                       ${D}[${ISO_UBUNTU:-24.04}]${N}
  --arm, --arch=arm64       images SD arm64 par github.com/armbian/build
                            (armbian/build-armbian.sh) : Raspberry Pi 4 et
                            toutes les Orange Pi 5. --desktop = GNOME + le
                            bureau du banc. Pas de --all ni de --lite. Le
                            premier build emule aarch64 : une dizaine d'heures.
  ${C}--board=LISTE${N}             cartes de --arm : rpi4, opi5, all, ou des noms
                            Armbian (orangepi5-max,rpi4b...)       ${D}[${ISO_ARM_BOARD:-all}]${N}
  ${C}--arch=amd64${N}              le defaut.

  ${C}-h, --help${N}                ceci.

${B}Equivalents en variables${N} (pour la CI, ou un environnement sans ligne de commande) :
  OSMO_ISO_BUILD_DOCKER=1   comme --build-docker
  OSMO_ISO_SKIP_BUILD=0     ne pas tirer d'image : construire, comme avant 09-2026
  OSMO_ISO_WITHOUT_DEBS=1   comme --without-debs
  OSMO_ISO_PULL_IMAGE=REF   l'image de --skip-build
  OSMO_ISO_BANC=1 / OSMO_ISO_MULTI=1 / OSMO_ISO_KB=fr / OSMO_ISO_VERSION=...
  OSMO_ISO_SOFTSIM=0        comme --no-softsim
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
    # Two-word form (`--version 24.04`): the loop is a `for` without shift, so
    # the flag remembers that the value comes on the next iteration and the
    # pattern below picks it up. These values mean nothing else on the command
    # line, so there is no collision.
    --version)      ISO_UBUNTU_NEXT=1 ;;
    22.04|24.04|jammy|noble)
                    if [ "${ISO_UBUNTU_NEXT:-0}" = 1 ]; then
                        ISO_UBUNTU="$arg"; ISO_UBUNTU_NEXT=0
                    fi ;;
    # ── 2G BENCH AT BOOT: NO, UNLESS EXPLICITLY REQUESTED ─────────────────────
    # osmo-banc.service and osmo-multi.service are INSTALLED in every image
    # (82-services.sh) but not ENABLED. --banc / --multi (or OSMO_ISO_BANC=1 /
    # OSMO_ISO_MULTI=1) enable them at boot, per image.
    --banc)         OSMO_ISO_BANC=1 ;;
    --no-banc)      OSMO_ISO_BANC=0 ;;
    --multi)        OSMO_ISO_MULTI=1 ;;
    --no-multi)     OSMO_ISO_MULTI=0 ;;
    --softsim)      OSMO_ISO_SOFTSIM=1 ;;
    --no-softsim)   OSMO_ISO_SOFTSIM=0 ;;
    --lite)         ISO_LITE=1 ;;
    --desktop)      ISO_DESKTOP=1 ;;
    --all)          ISO_ALL=1 ;;
    --skip-build)   ISO_SKIP_BUILD=1; ISO_SKIP_BUILD_GIVEN=1 ;;
    --skip-build=*) ISO_SKIP_BUILD=1; ISO_SKIP_BUILD_GIVEN=1; ISO_PULL_IMAGE="${arg#*=}"; ISO_PULL_IMAGE_GIVEN=1 ;;
    --build-docker) ISO_FORCE_BUILD=1 ;;
    --without-debs) ISO_WITH_DEBS=0 ;;
    --with-debs)    ISO_WITH_DEBS=1 ;;
    --arm|--arch=arm64) ISO_ARCH=arm64 ;;
    --board=*)      ISO_ARM_BOARD="${arg#*=}" ;;
    --arch=amd64)   ISO_ARCH=amd64 ;;
    --arch=*)       echo -e "${RED}--arch : amd64 ou arm64 (recu : ${arg#*=})${NC}" >&2; exit 2 ;;
esac; done

# Resolved AFTER the loop so option order does not matter: --build-docker
# wins over --skip-build, wherever it comes from (command line or variable).
if [ "$ISO_FORCE_BUILD" = "1" ] && [ "$ISO_SKIP_BUILD" = "1" ]; then
    # Only warn if a --skip-build was actually requested (pull is the default).
    [ "$ISO_SKIP_BUILD_GIVEN" = "1" ] && \
        echo -e "${YELLOW}--build-docker : --skip-build ignore, l image sera construite localement${NC}"
    ISO_SKIP_BUILD=0
fi
# Without embedded .debs, the docker build's .debs do not stay in the rootfs
# either (50-injection-image.sh removes them unless ISO_EMBED_DEBS=1).
[ "$ISO_WITH_DEBS" = "0" ] && ISO_EMBED_DEBS=0
export ISO_FORCE_BUILD ISO_WITH_DEBS

# ── UBUNTU BASE: 22.04 (jammy) or 24.04 (noble) ───────────────────────────
# Single variable for the suite name (debootstrap and sources.list).
#
# Default 24.04 (noble): the ISO MUST use the same suite as the docker image
# it copies /usr/local and the /root/.env venv from (python 3.12, glibc 2.39,
# *t64 libraries); a jammy rootfs under a noble image would give a venv
# without interpreter and .so files with missing symbols. This is checked
# later against the source image's os-release. 22.04 is accepted for an image
# built on jammy.
: "${ISO_UBUNTU:=24.04}"
case "$ISO_UBUNTU" in
    22.04|jammy) ISO_UBUNTU=22.04; ISO_SUITE=jammy ;;
    24.04|noble) ISO_UBUNTU=24.04; ISO_SUITE=noble ;;
    *) echo -e "${RED}--version : 22.04 ou 24.04 (recu : $ISO_UBUNTU)${NC}" >&2; exit 2 ;;
esac
export ISO_UBUNTU ISO_SUITE

# Derived from the architecture: the mirror (arm64 is on ports, NOT
# archive.ubuntu.com), the docker image suffix (both architectures coexist on
# one host), the output format. ISO_IMG_TAG is appended to image names:
# osmocom-nitb:arm64.
case "$ISO_ARCH" in
    amd64) ISO_MIRROR="$(bash "$DIR/packaging/apt-mirror.sh" "$ISO_SUITE" 2>/dev/null || echo http://archive.ubuntu.com/ubuntu)"; ISO_IMG_TAG="" ;;
    arm64) ISO_MIRROR="http://ports.ubuntu.com/ubuntu-ports"; ISO_IMG_TAG=":arm64" ;;
esac
# The suffix only exists for coexistence: an arm64 image built on an x86
# host must not overwrite the native image of the same name. Same rule as
# build.sh, which only sets IMG_TAG when $OSMO_ARCH != $HOST_ARCH. On an
# aarch64 host there is no suffix (build.sh tags plain osmocom-nitb, which
# 31-image-source.sh must find).
[ "$ISO_ARCH" = "$(dpkg --print-architecture 2>/dev/null || echo amd64)" ] && ISO_IMG_TAG=""
export ISO_ARCH ISO_MIRROR ISO_IMG_TAG
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

# --arm GOES THROUGH THE ARMBIAN FRAMEWORK (github.com/armbian/build):
# armbian/build-armbian.sh builds kernel, BSP, u-boot/firmware, rootfs and
# image for each board, and installs the stack via
# userpatches/customize-image.sh. This script is replaced by
# build-armbian.sh here, before any step.
if [ "$ISO_ARCH" = "arm64" ]; then
    [ "$ISO_ALL" = "1" ]  && { echo -e "${RED}--arm : pas de --all (--board=all construit toutes les cartes)${NC}" >&2; exit 2; }
    [ "$ISO_LITE" = "1" ] && { echo -e "${RED}--arm : pas de --lite avec le framework Armbian${NC}" >&2; exit 2; }
    case "${ISO_ROLE:-operator}" in operator) ;; *) echo -e "${RED}--arm : --role=operator seulement (recu : $ISO_ROLE)${NC}" >&2; exit 2 ;; esac
    [ "$ISO_SUITE" = noble ] || { echo -e "${RED}--arm : noble (24.04) seulement - les .deb du build arm64 visent noble${NC}" >&2; exit 2; }
    [ "$OUTPUT_SET" = "1" ] && echo -e "${YELLOW}--arm : --output ignore, les images sortent dans le output/images/ d armbian/build${NC}"
    _ARM=("--board=${ISO_ARM_BOARD:-all}" "--release=$ISO_SUITE" --install-deps)  # 20-hote.sh (which installed qemu-user-static) is not reached
    [ "$ISO_DESKTOP" = "1" ]            && _ARM+=(--desktop)
    [ "${OSMO_ISO_BANC:-0}" = "1" ]     && _ARM+=(--banc)
    [ "${OSMO_ISO_MULTI:-0}" = "1" ]    && _ARM+=(--multi)
    # only the --skip-build=REF image: the default (norf_gsm:latest) is amd64
    [ "${ISO_PULL_IMAGE_GIVEN:-0}" = "1" ] && _ARM+=("--image=$ISO_PULL_IMAGE")
    # nothing is published for arm64 except GHCR base-arm64: without an explicit
    # --skip-build, the stack image is built if missing
    [ "$ISO_SKIP_BUILD_GIVEN" = "1" ] || _ARM+=(--build-image)
    [ "${OSMO_ISO_ARM_DRY:-0}" = "1" ]  && _ARM+=(--dry-run)  # show the compile.sh commands without running anything
    echo -e "  ${CYAN}cible : arm64, framework Armbian - armbian/build-armbian.sh ${_ARM[*]}${NC}"
    exec bash "$DIR/armbian/build-armbian.sh" "${_ARM[@]}"
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
