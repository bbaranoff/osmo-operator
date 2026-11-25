#!/bin/bash
# packaging/docker-storage.sh - keep Docker/containerd storage off overlayfs.
#
# The docker/containerd overlayfs snapshotter mounts an overlay whose upperdir
# lives under /var/lib/containerd (or /var/lib/docker). When that directory is
# itself on overlayfs, the kernel refuses (no overlay upper on overlay) and the
# first BuildKit step fails with:
#   failed to solve: mount source: "overlay" ... err: invalid argument
# Two cases hit this:
#   - the live ISO: / is overlay(squashfs + tmpfs) (live-boot);
#   - a host that is itself a container (root on overlay).
# Fix: put /var/lib/docker and /var/lib/containerd on a filesystem that can
# carry an overlay upper:
#   - OSMO_DOCKER_STORAGE_DIR=<dir> on a real disk (ext4, xfs...) when given;
#   - a tmpfs when the overlay root is already in RAM (live system): the data
#     is in RAM either way, a tmpfs avoids the double cost of a loop file;
#   - otherwise a sparse ext4 loop file (/var/lib/docker-loop.img).
#
# Used by build.sh (before the build), iso_modules/20-stockage-docker.sh (ISO
# build host) and, in the image, by osmo-docker-storage.service (--boot, before
# containerd and docker start). Idempotent: does nothing when storage is fine.
#
# Env: OSMO_NO_DOCKER_FIX=1 (or OSMO_ISO_NO_DOCKER_FIX=1) disables it;
#      OSMO_DOCKER_STORAGE_DIR=<dir> real-disk directory to use;
#      OSMO_DOCKER_TMPFS_SIZE tmpfs size (default 50%);
#      OSMO_DOCKER_LOOP_GB (or OSMO_ISO_DOCKER_LOOP_GB) loop size in GB (default 40).
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

BOOT=0
[ "${1:-}" = --boot ] && BOOT=1

[ "${OSMO_NO_DOCKER_FIX:-${OSMO_ISO_NO_DOCKER_FIX:-0}}" = 1 ] && exit 0

fstype() { findmnt -no FSTYPE -T "$1" 2>/dev/null | head -1; }

mkdir -p /var/lib/docker /var/lib/containerd 2>/dev/null || true
if [ "$(fstype /var/lib/containerd)" != overlay ] && [ "$(fstype /var/lib/docker)" != overlay ]; then
    exit 0
fi
if [ "$(id -u)" != 0 ]; then
    echo -e "${YELLOW}! /var/lib/containerd est sur overlay : le build docker echouera (relancer en root)${NC}" >&2
    exit 0
fi

# Upper layer of the overlay root: tmpfs = live system in RAM.
root_upper_fs() {
    local up
    up="$(findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | sed -n 's/^upperdir=//p' | head -1)"
    [ -n "$up" ] && fstype "$up"
}

base=/var/lib/dockerdata
mode=""
if [ -n "${OSMO_DOCKER_STORAGE_DIR:-}" ]; then
    mode=dir; base="$OSMO_DOCKER_STORAGE_DIR"
    mkdir -p "$base" || exit 1
    if [ "$(fstype "$base")" = overlay ]; then
        echo -e "${RED}OSMO_DOCKER_STORAGE_DIR=$base est lui aussi sur overlay${NC}" >&2; exit 1
    fi
elif [ "$(root_upper_fs)" = tmpfs ]; then
    mode=tmpfs
else
    mode=loop
fi

running_stack=0
if [ "$BOOT" = 0 ]; then
    if [ -n "$(docker ps -q 2>/dev/null)" ]; then
        echo -e "${RED}des conteneurs tournent : arretez-les avant (le correctif redemarre docker)${NC}" >&2
        exit 1
    fi
    systemctl is-active -q docker containerd 2>/dev/null && running_stack=1
    systemctl stop docker.socket docker containerd 2>/dev/null || true
fi

case "$mode" in
    dir)   desc="repertoire $base ($(fstype "$base"))" ;;
    tmpfs) desc="tmpfs (${OSMO_DOCKER_TMPFS_SIZE:-50%} de la RAM, systeme live)" ;;
    loop)  desc="ext4 en boucle (${OSMO_DOCKER_LOOP_GB:-${OSMO_ISO_DOCKER_LOOP_GB:-40}} Go, /var/lib/docker-loop.img)" ;;
esac
echo -e "  ${CYAN}stockage docker sur overlay : bascule sur ${desc}${NC}"

mkdir -p "$base" || exit 1
case "$mode" in
    tmpfs)
        mountpoint -q "$base" || mount -t tmpfs -o "mode=0711,size=${OSMO_DOCKER_TMPFS_SIZE:-50%}" osmo-docker "$base" || exit 1 ;;
    loop)
        img=/var/lib/docker-loop.img
        if [ ! -f "$img" ]; then
            truncate -s "${OSMO_DOCKER_LOOP_GB:-${OSMO_ISO_DOCKER_LOOP_GB:-40}}G" "$img" \
                && mkfs.ext4 -q -F "$img" || exit 1
        fi
        mountpoint -q "$base" || mount -o loop "$img" "$base" || exit 1 ;;
esac

# Bring what is already there (images of the squashfs, a pulled base image)
# into the new storage, once, then bind it over the overlay directories.
for d in docker containerd; do
    if [ ! -d "$base/$d" ]; then
        mkdir -p "$base/$d"
        cp -a "/var/lib/$d/." "$base/$d/" 2>/dev/null || true
    fi
    if [ "$(fstype "/var/lib/$d")" = overlay ]; then
        mount --bind "$base/$d" "/var/lib/$d" || exit 1
    fi
done

# Persistent host (container, loop or disk directory): remount at boot through
# fstab. The live system and the tmpfs case go through the boot unit instead.
if [ "$BOOT" = 0 ] && [ "$mode" != tmpfs ] && ! grep -q 'osmo-docker-storage' /etc/fstab 2>/dev/null; then
    {
        echo "# osmo-docker-storage (packaging/docker-storage.sh)"
        [ "$mode" = loop ] && echo "/var/lib/docker-loop.img $base ext4 loop 0 0"
        echo "$base/docker /var/lib/docker none bind 0 0"
        echo "$base/containerd /var/lib/containerd none bind 0 0"
    } >> /etc/fstab
fi

if [ "$BOOT" = 0 ]; then
    systemctl start containerd docker 2>/dev/null || systemctl start docker || exit 1
    for _ in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
echo -e "  ${GREEN}✓${NC} docker stocke sur $(fstype /var/lib/containerd)"
exit 0
