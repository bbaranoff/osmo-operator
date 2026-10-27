#!/bin/bash
# armbian/build-armbian.sh - build an arm64 SD image with the official Armbian framework
#                            (github.com/armbian/build) and install the osmo-operator stack on it.
#
# Armbian builds the kernel, BSP, u-boot/firmware, rootfs and image; this script only adds the
# stack through Armbian's userpatches mechanism:
#     userpatches/customize-image.sh   runs inside the image chroot (under qemu-user on an x86 host)
#     userpatches/overlay/             mounted at /tmp/overlay inside that chroot
#
# The stack comes from the project's arm64 Docker image (Dockerfile, build.sh --arch=arm64:
# osmocom-nitb:arm64, or the published base ghcr.io/<repo>/osmocom-nitb:base-arm64-<hash>), the same
# content iso_modules/50-injection-image.sh uses for the ISO: build .debs (osmo-build-*), /usr/local,
# /opt/GSM, /etc/osmocom, systemd units. It is exported into the overlay with docker cp.
# What an x86 host cannot produce (toast, qosmo launcher, c54x_exe/grgsm_exe, bench .debs) is
# compiled inside the chroot by customize-image.sh.
#
# Usage:
#   sudo ./build-armbian.sh                       rpi4b, branch current, noble: clone, overlay, compile
#   sudo ./build-armbian.sh --prepare             everything except compile.sh (check userpatches/, overlay)
#   sudo ./build-armbian.sh --no-stack            plain Armbian (no overlay, no customize)
#   sudo ./build-armbian.sh --board=orangepi5 --branch=edge --release=noble
#   sudo ./build-armbian.sh --image=osmocom-nitb:arm64      Docker image providing the stack
#
# Options:
#   --board=              one board, a comma-separated list, or a group:
#                           rpi4   rpi4b (Raspberry Pi 4)
#                           opi5   all Armbian Orange Pi 5 boards: orangepi5, orangepi5b, orangepi5-plus,
#                                  orangepi5pro, orangepi5-max, orangepi5-ultra
#                           all    rpi4 + opi5
#                         One image per board, built sequentially from the same overlay. Kernel branch
#                         is chosen per board: --branch if offered (KERNEL_TARGET in
#                         config/boards/<board>.*), else current, else the board's first branch.
#                         Community boards (.csc) are built with EXPERT=yes.
#   --desktop             GNOME desktop (DESKTOP_ENVIRONMENT=gnome, DESKTOP_TIER=minimal, via
#                         armbian/configng) + the bench desktop (wallpaper, Conky, panel, icons, c123)
#   --banc / --multi      enable osmo-banc.service / osmo-multi.service at boot
#   --build-image         if no arm64 stack Docker image exists, build it (build.sh --arch=arm64)
#                         instead of failing
#   --armbian-dir=PATH    armbian/build clone                [/opt/GSM/armbian-build]
#   --update              git pull the clone before building
#   --install-deps        apt install qemu-user-static binfmt-support if aarch64 cannot be emulated
#   --dry-run             print what would be done
#
# Env: ARMBIAN_DIR, ARMBIAN_GIT, OSMO_DEB_CACHE (/var/cache/osmo-debs), OSMO_ARM_GLAVA=1.
# Host requirements: docker (compile.sh containerizes itself on non-Ubuntu/x86 hosts), git, and
# aarch64 emulation (qemu-user-static + binfmt) so the chroot runs on x86 (not needed on arm64).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

BOARD=rpi4b; BRANCH=current; RELEASE=noble
ARMBIAN_DIR="${ARMBIAN_DIR:-/opt/GSM/armbian-build}"
ARMBIAN_GIT="${ARMBIAN_GIT:-https://github.com/armbian/build}"
IMAGE=""; PREPARE=0; NO_STACK=0; UPDATE=0; INSTALL_DEPS=0; DRY=0
DESKTOP=0; BANC=0; MULTI=0; BUILD_IMAGE=0; BRANCH_GIVEN=0
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
for arg in "$@"; do
    case "$arg" in
        --board=*)       BOARD="${arg#*=}" ;;
        --branch=*)      BRANCH="${arg#*=}"; BRANCH_GIVEN=1 ;;
        --desktop)       DESKTOP=1 ;;
        --banc)          BANC=1 ;;
        --multi)         MULTI=1 ;;
        --build-image)   BUILD_IMAGE=1 ;;
        --release=*)     RELEASE="${arg#*=}" ;;
        --image=*)       IMAGE="${arg#*=}" ;;
        --armbian-dir=*) ARMBIAN_DIR="${arg#*=}" ;;
        --prepare)       PREPARE=1 ;;
        --no-stack)      NO_STACK=1 ;;
        --update)        UPDATE=1 ;;
        --install-deps)  INSTALL_DEPS=1 ;;
        --dry-run)       DRY=1 ;;
        -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
        *) echo "option inconnue : $arg" >&2; sed -n '2,46p' "$0" >&2; exit 2 ;;
    esac
done
say()  { printf '\033[1;32m[armbian]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[armbian] !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[armbian] ECHEC\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  + $*"; else "$@"; fi; }

# ── 1. Host checks ───────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || [ "$DRY" = 1 ] || die "a lancer en root (compile.sh d Armbian l exige) : sudo $0 $*"
command -v git >/dev/null    || die "git absent"
command -v docker >/dev/null || warn "docker absent : compile.sh ne pourra pas se conteneuriser (il faut alors un hote Ubuntu avec ses dependances)"
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "$HOST_ARCH" != arm64 ] && [ "$NO_STACK" = 0 ]; then
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        if [ "$INSTALL_DEPS" = 1 ]; then
            say "emulation aarch64 absente : apt install qemu-user-static binfmt-support"
            run apt-get install -y qemu-user-static binfmt-support
        elif [ "$DRY" = 1 ] || [ "$PREPARE" = 1 ]; then
            warn "pas d emulation aarch64 sur cet hote $HOST_ARCH : avant compile.sh, sudo $REPO/build.sh --arm (pose tous les paquets hote) ou --install-deps"
        else
            die "pas d emulation aarch64 sur cet hote $HOST_ARCH (/proc/sys/fs/binfmt_misc/qemu-aarch64 absent) : customize-image.sh ne pourrait pas tourner dans le chroot arm64. sudo $REPO/build.sh --arm pose tous les paquets hote (ou --install-deps)"
        fi
    fi
fi
OPI5_BOARDS="orangepi5 orangepi5b orangepi5-plus orangepi5pro orangepi5-max orangepi5-ultra"
BOARDS=""
for b in ${BOARD//,/ }; do
    case "$b" in
        rpi4|rpi4b) BOARDS="$BOARDS rpi4b" ;;
        opi5|orangepi5-all) BOARDS="$BOARDS $OPI5_BOARDS" ;;
        all)        BOARDS="$BOARDS rpi4b $OPI5_BOARDS" ;;
        *)          BOARDS="$BOARDS $b" ;;
    esac
done
BOARDS=$(echo $BOARDS | tr ' ' '\n' | awk '!vu[$0]++' | tr '\n' ' ')
say "hote $HOST_ARCH ($(nproc) coeurs) ; cartes : $BOARDS; RELEASE=$RELEASE ; bureau=$([ "$DESKTOP" = 1 ] && echo gnome || echo non) ; clone $ARMBIAN_DIR"

# ── 2. Armbian framework ─────────────────────────────────────────────────────
if [ ! -f "$ARMBIAN_DIR/compile.sh" ]; then
    say "clone de $ARMBIAN_GIT (branche main, depth 1) -> $ARMBIAN_DIR"
    run git clone --depth 1 --branch main "$ARMBIAN_GIT" "$ARMBIAN_DIR"
elif [ "$UPDATE" = 1 ]; then
    say "mise a jour du clone"
    run git -C "$ARMBIAN_DIR" pull --ff-only
fi
# board_file BOARD: Armbian board file (.conf supported, .csc community, .wip, ...)
board_file() {
    local e
    for e in conf csc wip tvb eos; do
        [ -f "$ARMBIAN_DIR/config/boards/$1.$e" ] && { echo "$ARMBIAN_DIR/config/boards/$1.$e"; return 0; }
    done
    return 1
}
# board_branch BOARD: --branch if the board offers it, else current, else its first branch
board_branch() {
    local f targets
    f=$(board_file "$1") || { echo "$BRANCH"; return; }
    targets=$(sed -n 's/^KERNEL_TARGET="\(.*\)".*/\1/p' "$f" | head -1)
    [ -n "$targets" ] || { echo "$BRANCH"; return; }
    case ",$targets," in
        *",$BRANCH,"*) echo "$BRANCH" ;;
        *",current,"*) [ "$BRANCH_GIVEN" = 1 ] && warn "$1 : pas de branche $BRANCH ($targets), current a la place" >&2; echo current ;;
        *) warn "$1 : pas de branche $BRANCH$([ "$BRANCH" = current ] || echo " ni current") ($targets), ${targets%%,*} a la place" >&2; echo "${targets%%,*}" ;;
    esac
}
if [ "$DRY" = 0 ]; then
    for b in $BOARDS; do
        board_file "$b" >/dev/null || die "carte inconnue d Armbian : $b (voir $ARMBIAN_DIR/config/boards/)"
    done
fi

# ── 3. userpatches: customization script and overlay ─────────────────────────
UP="$ARMBIAN_DIR/userpatches"
OV="$UP/overlay/osmo"
run install -d "$UP" "$OV"
if [ "$NO_STACK" = 1 ]; then
    say "--no-stack : pas de customize-image.sh (Armbian nue)"
    run rm -f "$UP/customize-image.sh"
else
    run install -m755 "$HERE/userpatches/customize-image.sh" "$UP/customize-image.sh"
    say "userpatches/customize-image.sh pose"
fi

# ── 4. Overlay: the stack, exported from the arm64 Docker image ──────────────
if [ "$NO_STACK" = 0 ]; then
    if [ -z "$IMAGE" ]; then
        if docker image inspect osmocom-nitb:arm64 >/dev/null 2>&1; then
            IMAGE=osmocom-nitb:arm64
        else
            KEY=$(cd "$REPO" && git ls-files -- Dockerfile packaging configs scripts services helpers opt-gsm tools patches | sort | xargs sha256sum | sha256sum | cut -c1-16)
            REMOTE=$(cd "$REPO" && git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')
            GHCR="ghcr.io/${REMOTE:-bbaranoff/osmo-operator}/osmocom-nitb:base-arm64-$KEY"
            if [ "$DRY" = 0 ] && docker pull --platform linux/arm64 "$GHCR" >/dev/null 2>&1; then
                IMAGE="$GHCR"
            elif [ "$DRY" = 1 ]; then
                warn "aucune image Docker arm64 de la pile en local ($GHCR non testee en dry-run) : il faudra d abord sudo $REPO/build.sh --arch=arm64"
                IMAGE="osmocom-nitb:arm64"
            elif [ "$BUILD_IMAGE" = 1 ]; then
                say "aucune image Docker arm64 de la pile : build.sh --arch=arm64 (emule sur un hote x86 : ~10 h au premier build)"
                bash "$REPO/build.sh" --arch=arm64 || die "build.sh --arch=arm64 a echoue"
                if docker image inspect osmocom-nitb:arm64 >/dev/null 2>&1; then IMAGE=osmocom-nitb:arm64; else IMAGE=osmocom-nitb; fi
            else
                die "aucune image Docker arm64 de la pile : ni osmocom-nitb:arm64 en local, ni $GHCR. Sur cet hote : sudo $REPO/build.sh --arch=arm64 (emule, ~10 h au premier build) ou --build-image, ou lancer docker-arm.yml sur GitHub (runner arm64 natif) puis relancer ici."
            fi
        fi
    fi
    if [ "$DRY" = 0 ]; then
        ARCH=$(docker image inspect --format '{{.Architecture}}' "$IMAGE" 2>/dev/null || echo "?")
        [ "$ARCH" = arm64 ] || die "l image $IMAGE est $ARCH, pas arm64"
    fi
    say "pile : image Docker $IMAGE -> overlay $OV"
    if [ "$DRY" = 1 ]; then
        echo "  + docker create/cp -> $OV/debs/ et $OV/rootfs/ (usr/local, opt/GSM, opt/node, root/.env, etc/osmocom, etc/asterisk, lib/systemd/system)"
    else
        rm -rf "$OV"; install -d "$OV/debs" "$OV/rootfs/usr" "$OV/rootfs/opt" "$OV/rootfs/root" "$OV/rootfs/etc" "$OV/rootfs/lib/systemd/system"
        CID=$(docker create --platform linux/arm64 "$IMAGE" /bin/true)
        trap 'docker rm "$CID" >/dev/null 2>&1 || true' EXIT
        # Build .debs for the target suite: host cache first, else those shipped in the image
        cp -f "$DEB_CACHE"/osmo-build-*"~${RELEASE}_arm64.deb" "$OV/debs/" 2>/dev/null || true
        if ! ls "$OV/debs"/*.deb >/dev/null 2>&1; then
            docker cp "$CID:/var/cache/osmo-debs/." "$OV/debs/" 2>/dev/null || true
            find "$OV/debs" -name '*.deb' ! -name "*~${RELEASE}_arm64.deb" -delete 2>/dev/null || true
        fi
        NDEBS=$(find "$OV/debs" -name '*.deb' | wc -l)
        # The overlay is a tree (rootfs/) copied as-is onto / by customize-image.sh: /usr/local,
        # /opt/GSM minus the trees the .debs already install (same list as 50-injection-image.sh),
        # /opt/node, root's environment, /etc/osmocom, /etc/asterisk, systemd units.
        docker cp "$CID:/usr/local" "$OV/rootfs/usr/"
        EXCL=()
        if [ "$NDEBS" -gt 0 ]; then
            for t in osmocom-bb qosmo c54x_exe grgsm_exe qemu-install firmware; do EXCL+=("--exclude=GSM/$t" "--exclude=GSM/$t/*"); done
        fi
        docker cp "$CID:/opt/GSM" - | tar -x -C "$OV/rootfs/opt" "${EXCL[@]+"${EXCL[@]}"}"
        docker cp "$CID:/opt/node" "$OV/rootfs/opt/" 2>/dev/null || true
        for d in .env .venv-qemu; do docker cp "$CID:/root/$d" "$OV/rootfs/root/" 2>/dev/null || true; done
        docker cp "$CID:/etc/osmocom" "$OV/rootfs/etc/" 2>/dev/null || true
        docker cp "$CID:/etc/asterisk" "$OV/rootfs/etc/" 2>/dev/null || true
        for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
            docker cp "$CID:/lib/systemd/system/$svc.service" "$OV/rootfs/lib/systemd/system/" 2>/dev/null || true
        done
        cp -f "$REPO"/services/*.service "$OV/rootfs/lib/systemd/system/" 2>/dev/null || true
        docker rm "$CID" >/dev/null; trap - EXIT
        # /opt/GSM/osmo-operator is taken from this working tree (tracked + untracked, no .git or
        # ignored files), as for the ISO, so local fixes not yet in a published image are included.
        rm -rf "$OV/rootfs/opt/GSM/osmo-operator"; install -d "$OV/rootfs/opt/GSM/osmo-operator"
        (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) \
            | tar -xf - -C "$OV/rootfs/opt/GSM/osmo-operator"
        # Panel/Conky watcher: the same script as the ISO, extracted from 85-installeur-bureau.sh
        sed -n "/<<'PANEL'$/,/^PANEL$/p" "$REPO/iso_modules/85-installeur-bureau.sh" | sed '1d;$d' > "$OV/osmo-desktop-panel"
        [ -s "$OV/osmo-desktop-panel" ] || warn "osmo-desktop-panel non extrait de iso_modules/85-installeur-bureau.sh : pas de Conky au login"
        printf 'IMAGE=%s\nRELEASE=%s\nBOARDS=%s\nDESKTOP=%s\nDATE=%s\nNDEBS=%s\n' "$IMAGE" "$RELEASE" "$BOARDS" "$DESKTOP" "$(date -Is)" "$NDEBS" > "$OV/SOURCE"
        say "overlay pret : $NDEBS .deb, $(du -sh "$OV" | cut -f1)"
    fi
fi

# Marker files read by customize-image.sh from the overlay (services enabled at boot)
if [ "$NO_STACK" = 0 ] && [ "$DRY" = 0 ]; then
    rm -f "$OV/OSMO_IMAGE_BANC" "$OV/OSMO_IMAGE_MULTI" "$OV/OSMO_ARM_GLAVA"
    [ "${OSMO_ARM_GLAVA:-0}" = 1 ] && : > "$OV/OSMO_ARM_GLAVA"
    [ "$BANC" = 1 ]  && : > "$OV/OSMO_IMAGE_BANC"
    [ "$MULTI" = 1 ] && : > "$OV/OSMO_IMAGE_MULTI"
fi

# ── 5. compile.sh, once per board ────────────────────────────────────────────
# The desktop comes from armbian/configng YAML, selected by DESKTOP_ENVIRONMENT + DESKTOP_TIER.
# GNOME minimal pulls gdm3, pulseaudio and Xorg, which Conky and c123 need.
if [ "$DESKTOP" = 1 ]; then
    DESK=(BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_TIER=minimal)
else
    DESK=(BUILD_DESKTOP=no)
fi
IMGS=()
for b in $BOARDS; do
    br=$(board_branch "$b")
    CMD=(./compile.sh build "BOARD=$b" "BRANCH=$br" "RELEASE=$RELEASE" BUILD_MINIMAL=no "${DESK[@]}" KERNEL_CONFIGURE=no COMPRESS_OUTPUTIMAGE=sha,img)
    case "$(board_file "$b" 2>/dev/null)" in *.conf|"") ;; *) CMD+=(EXPERT=yes) ;; esac
    if [ "$PREPARE" = 1 ] || [ "$DRY" = 1 ]; then
        echo "  + (cd $ARMBIAN_DIR && ${CMD[*]})"
        continue
    fi
    say "[$b] compile.sh (long : noyau + rootfs + customize sous qemu-user) : ${CMD[*]}"
    t0=$(date +%s)
    (cd "$ARMBIAN_DIR" && "${CMD[@]}") || die "[$b] compile.sh a echoue"
    IMG=$(find "$ARMBIAN_DIR/output/images" -maxdepth 1 -name '*.img' -newermt "@$t0" 2>/dev/null | head -1)
    [ -n "$IMG" ] || die "[$b] pas de nouvelle image dans $ARMBIAN_DIR/output/images/"
    IMGS+=("$IMG")
    say "[$b] image : $IMG  ($(du -h "$IMG" | cut -f1))"
done
if [ "$PREPARE" = 1 ]; then
    say "--prepare : fini. Pour construire : les commandes ci-dessus, en root"
    exit 0
fi
[ "$DRY" = 1 ] && exit 0
say "images :"; for i in "${IMGS[@]}"; do echo "    $i"; done
say "flash : sudo dd if=<image> of=/dev/sdX bs=4M status=progress conv=fsync   (comptes : root/osmo, osmocom/osmo)"
