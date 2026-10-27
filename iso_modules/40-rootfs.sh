#!/bin/bash
# iso_modules/40-rootfs.sh - step 4: debootstrap (or inherited rootfs)
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment:
#   ISO_DEB_CACHE=<abs dir>   persistent .deb cache reused by debootstrap
#                             (--cache-dir); empty or --no-cache -> no cache.
#   OSMO_ISO_ROOTFS_FROM=<dir> reuse the rootfs of a previous pass (--all).
#   OSMO_ISO_ROOTFS_MODE=move|copy  how to take it over (default: move).

# ── Step 4: bootstrap a minimal rootfs ───────────────────────────────────────
# ── .deb cache (speeds up rebuilds) ──────────────────────────────────────────
ISO_DEB_CACHE="${ISO_DEB_CACHE:-$HOME/.cache/osmo-iso-debs}"
DEBOOTSTRAP_CACHE_OPT=""
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    # The cache is PER ARCHITECTURE: an amd64 .deb and its arm64 counterpart
    # share the same file name except for the arch, and debootstrap does not
    # check the architecture of what it takes from the cache.
    _DBS_CACHE="$ISO_DEB_CACHE/debootstrap"
    [ "${ISO_ARCH:-amd64}" = "amd64" ] || _DBS_CACHE="$ISO_DEB_CACHE/debootstrap-$ISO_ARCH"
    mkdir -p "$_DBS_CACHE"
    DEBOOTSTRAP_CACHE_OPT="--cache-dir=$_DBS_CACHE"
    echo -e "  ${GREEN}cache .deb debootstrap : $_DBS_CACHE${NC}"
fi
# ── Rootfs INHERITED from a previous pass (--all: lite and desktop reuse the
# normal one) or debootstrap from scratch. An inherited rootfs is complete and
# configured: step 5 (injection) is skipped, the other steps replay - they
# write their files, apt only installs the delta.
OSMO_ISO_INHERITED=0
if [ -n "${OSMO_ISO_ROOTFS_FROM:-}" ]; then
    [ -d "$OSMO_ISO_ROOTFS_FROM" ] || { echo -e "${RED}Rootfs herite introuvable : ${OSMO_ISO_ROOTFS_FROM}${NC}" >&2; exit 1; }
    rmdir "$ROOTFS" 2>/dev/null || true
    case "${OSMO_ISO_ROOTFS_MODE:-move}" in
        copy)
            echo -e "${GREEN}[4/9] Rootfs repris (COPIE) de ${CYAN}${OSMO_ISO_ROOTFS_FROM}${NC}..."
            # --reflink=auto: instant on btrfs/xfs, plain copy elsewhere.
            cp -a --reflink=auto "$OSMO_ISO_ROOTFS_FROM" "$ROOTFS" ;;
        *)
            echo -e "${GREEN}[4/9] Rootfs repris (deplace) de ${CYAN}${OSMO_ISO_ROOTFS_FROM}${NC}..."
            mv "$OSMO_ISO_ROOTFS_FROM" "$ROOTFS" ;;
    esac
    OSMO_ISO_INHERITED=1
    echo -e "  ${GREEN}✓${NC} rootfs herite $(du -sh "$ROOTFS"|cut -f1) - debootstrap et injection sautes"
else
    # The debootstrap script for the suite: on a jammy host the package does
    # not know noble. All Ubuntu scripts are the same (gutsy): link it.
    _DBS=/usr/share/debootstrap/scripts
    if [ -d "$_DBS" ] && [ ! -e "$_DBS/$ISO_SUITE" ] && [ -e "$_DBS/gutsy" ]; then
        ln -s gutsy "$_DBS/$ISO_SUITE"
        echo -e "  ${YELLOW}debootstrap ne connaissait pas ${ISO_SUITE} : script gutsy lie${NC}"
    fi
    echo -e "${GREEN}[4/9] debootstrap $ISO_SUITE ($ISO_UBUNTU, ${ISO_ARCH}, minimal)...${NC}"
    # arm64 on an x86 host: --foreign only DOWNLOADS and UNPACKS (nothing is
    # executed); the second stage configures the packages in the chroot, where
    # qemu-aarch64-static (copied into the rootfs) runs the aarch64 binaries
    # via binfmt. On amd64 the flag is empty and debootstrap does it all at once.
    _DBS_FOREIGN=""
    if [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then _DBS_FOREIGN="--foreign"; fi
    # zstd: noble sets COMPRESS=zstd in initramfs.conf but minbase does not
    # install the binary; without it mkinitramfs falls back to gzip (bigger,
    # slower initrd). It must be there BEFORE the kernel, hence here.
    debootstrap $DEBOOTSTRAP_CACHE_OPT --arch="$ISO_ARCH" $_DBS_FOREIGN --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,zstd,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
        "$ISO_SUITE" "$ROOTFS" "$ISO_MIRROR"
    if [ -n "$_DBS_FOREIGN" ]; then
        install -m755 "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/qemu-aarch64-static"
        echo -e "  ${CYAN}debootstrap --second-stage (aarch64 sous qemu-user, plus lent)...${NC}"
        chroot "$ROOTFS" /debootstrap/debootstrap --second-stage >"$WORK/debootstrap-2nd.log" 2>&1 \
            || { echo -e "${RED}debootstrap --second-stage a echoue (voir $WORK/debootstrap-2nd.log)${NC}" >&2; tail -20 "$WORK/debootstrap-2nd.log" >&2; exit 1; }
    fi
    echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"
fi


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
