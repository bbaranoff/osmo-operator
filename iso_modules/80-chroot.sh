#!/bin/bash
# iso_modules/80-chroot.sh - step 8: configure the rootfs inside the chroot (apt, kernel, desktop).
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not runnable on its own. A `return` at the top of a module means "nothing to do"
# (this is how --arm skips a step).
# Environment: ROOTFS, DIR, ISO_ROLE, ISO_LITE, ISO_ARCH, ISO_MIRROR, ISO_SUITE,
# ISO_DESKTOP, ISO_DEB_CACHE, NO_CACHE, OSMO_ISO_KB, OSMO_ISO_SOFTSIM, OSMO_FF_HOME.

echo -e "${GREEN}[8/9] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
# ── Persistent apt cache for the chroot ─────────────────────────────────────
# The apt/apt-fast download directory is a bind mount of the host cache
# ISO_DEB_CACHE/apt-archives, reused by every pass and later builds. It is
# unmounted before the squashfs (no .deb files in the ISO), and the chroot skips
# "apt-get clean" while it is mounted (that would empty the host cache).
# --no-cache: no bind mount.
ISO_APT_CACHE_BOUND=0
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    mkdir -p "$ISO_DEB_CACHE/apt-archives/partial" "$ROOTFS/var/cache/apt/archives"
    if mount --bind "$ISO_DEB_CACHE/apt-archives" "$ROOTFS/var/cache/apt/archives"; then
        ISO_APT_CACHE_BOUND=1
        echo -e "  ${GREEN}cache apt du chroot : $ISO_DEB_CACHE/apt-archives ($(du -sh "$ISO_DEB_CACHE/apt-archives" | cut -f1), $(find "$ISO_DEB_CACHE/apt-archives" -maxdepth 1 -name '*.deb' | wc -l) paquets)${NC}"
    fi
fi
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
# The host resolv.conf gives apt DNS during the build only; it is replaced at
# the end by 81-cloture-systeme.sh (see its DNS block).
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

# Install the apt-fast installer (same as the Dockerfile) into the rootfs.
install -m755 "$DIR/packaging/apt-fast-install.sh" "$ROOTFS/usr/local/sbin/apt-fast-install"

# ── Step 8 runs INSIDE the chroot: iso_modules/80-chroot.d/NN-*.sh ─────────
# The fragments are copied into the rootfs, then sourced in numeric order by ONE
# bash (same variables from one fragment to the next, as when this was a single
# bash -c string), and removed afterwards. Settings come through the
# environment.
# LC_ALL=C.UTF-8: the host locale is not generated in the chroot and perl/debconf
# would warn "Setting locale failed" on every package. C.UTF-8 needs no locale-gen.
_CHROOT_D=/var/lib/osmo-build/chroot.d
rm -rf "${ROOTFS:?}$_CHROOT_D"; install -d "$ROOTFS$_CHROOT_D"
cp "$DIR"/iso_modules/80-chroot.d/[0-9][0-9]-*.sh "$ROOTFS$_CHROOT_D/"
chroot "$ROOTFS" env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                   LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE= \
                   ISO_ROLE="$ISO_ROLE" ISO_LITE="$ISO_LITE" ISO_APT_CACHE_BOUND="$ISO_APT_CACHE_BOUND" \
                   ISO_ARCH="$ISO_ARCH" ISO_MIRROR="$ISO_MIRROR" \
                   ISO_DESKTOP="$ISO_DESKTOP" OSMO_ISO_KB="$OSMO_ISO_KB" \
                   OSMO_ISO_SOFTSIM="${OSMO_ISO_SOFTSIM:-1}" bash -c '
set -e
for _osmo_frag in /var/lib/osmo-build/chroot.d/[0-9][0-9]-*.sh; do
    echo "  [chroot] ${_osmo_frag##*/}"
    . "$_osmo_frag"
done
'
rm -rf "${ROOTFS:?}$_CHROOT_D"


# End of module: sourcing returns the status of the LAST command and
# build-iso.sh runs under set -e, so always end with a true status.
true
