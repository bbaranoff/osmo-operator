#!/bin/bash
# build-iso.sh - build a bootable amd64 ISO or an arm64 SD image, through
# build.sh and start-docker.sh (no direct docker build in this script).
#
#  Usage: sudo ./build-iso.sh [options]
#    (no option)          the four amd64 images: interstp, operator, lite, desktop
#    --role=operator|interstp   --node=N   --lite   --desktop   --all
#    --arm                arm64 SD images via github.com/armbian/build
#                         (armbian/build-armbian.sh): Raspberry Pi 4 and the
#                         Orange Pi 5 family (5, 5B, 5 Plus, 5 Pro, 5 Max, 5 Ultra);
#                         --board=rpi4|opi5|all|<board>[,...] (default all),
#                         --desktop = GNOME + the bench desktop; --all and --lite
#                         are refused. See iso_modules/00-options.sh.
#    --banc --multi       enable osmo-banc.service / osmo-multi.service at boot
#                         of the image. By default both units are INSTALLED but
#                         NOT enabled: the machine boots to its desktop and the
#                         operator starts the bench (icon, launch.sh,
#                         systemctl start osmo-banc). Env equivalents:
#                         OSMO_ISO_BANC=1 / OSMO_ISO_MULTI=1.
#    --version=24.04|22.04   --kb=fr   --output=file   --no-cache
#    (default, amd64)     THE DOCKER IMAGE IS PULLED, NOT BUILT, and tagged
#                         osmocom-nitb. Tried in order: bastienbaranoff/norf_gsm:latest
#                         (Docker Hub), then ghcr.io/<repo>/osmocom-nitb:base-<fingerprint>,
#                         then the GHCR :latest. build.sh runs only if none
#                         answers. The fingerprint is the one of the workflows:
#                         when it matches, the published image was built from
#                         exactly this working tree; the two other references
#                         do not guarantee that, and the script says so before
#                         using them. On arm64 nothing is published: building
#                         remains the default.
#    --skip-build[=image:tag]   make the pull mandatory (no fallback to
#                         build.sh) and, with =image, force that reference
#                         instead of deriving it. An image already present
#                         locally is not pulled. Env: OSMO_ISO_SKIP_BUILD=0
#                         for the opposite - never pull.
#    --build-docker       the opposite, and it wins: the image is built by
#                         build.sh even if a --skip-build is set elsewhere.
#                         Env: OSMO_ISO_BUILD_DOCKER=1.
#    --without-debs       no .deb travels in the image: neither the bench
#                         packages (step 7c) nor those of the docker build.
#                         They are still used to install the stack in the
#                         rootfs but are not kept there. Env: OSMO_ISO_WITHOUT_DEBS=1.
#    --wan --wan-nodes=... --wan-id=N --wan-ops=N --hub-ip=IP
set -euo pipefail

# Colours are defined first: under `set -u`, a coloured message emitted before
# their definition would fail with "unbound variable".
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

VERSION="${OSMO_ISO_VERSION:-main}"
OUTPUT="osmo-operator-${VERSION}.iso"
# Work directory ON DISK (not /tmp, often a RAM tmpfs too small for the
# rootfs). Override with OSMO_ISO_WORK.
WORK="${OSMO_ISO_WORK:-/var/tmp}/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS_V2"
DIR="$(cd "$(dirname "$0")" && pwd)"
# /usr/local/sbin in PATH: apt-fast-install puts apt-fast there, on the host as
# in the rootfs; the chroot below inherits this PATH (env ... bash -c).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"


# ── Build steps live in iso_modules/ ─────────────────────────────────────────
# Each step is iso_modules/NN-<slug>.sh, sourced here in numeric order, in THIS
# shell: variables, functions and the trap stay global. A module that has
# nothing to do (another variant or architecture) returns at its top.
# Invariant: `. file` returns the status of the file's last command and set -e
# is active, so every module must end with `true`.
MODDIR="$DIR/iso_modules"
[ -d "$MODDIR" ] || { echo -e "${RED}iso_modules/ introuvable a cote de $0${NC}" >&2; exit 2; }
shopt -s nullglob; _ISO_MODS=("$MODDIR"/[0-9][0-9]-*.sh); shopt -u nullglob
[ "${#_ISO_MODS[@]}" -gt 0 ] || { echo -e "${RED}iso_modules/ est vide${NC}" >&2; exit 2; }
for _m in "${_ISO_MODS[@]}"; do . "$_m"; done
