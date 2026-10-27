#!/bin/bash
# iso_modules/20-stockage-docker.sh - keep Docker storage off overlayfs
# Sourced by build-iso.sh in numeric order (after 20-hote: docker is
# installed). Not meant to run on its own.
#
# When the host is itself a container (root on `overlay`), the docker/containerd
# overlayfs snapshotter mounts an overlay ON an overlay, which the kernel
# refuses. The build then fails at the first `RUN --mount=type=cache` with:
#   failed to solve: mount source: "overlay" ... err: invalid argument
# Fix: put /var/lib/docker and /var/lib/containerd on a loop-mounted ext4
# (sparse file). Idempotent; does nothing if storage is already fine.
# Env: OSMO_ISO_NO_DOCKER_FIX=1 disables it; OSMO_ISO_DOCKER_LOOP_GB sets the
# size in GB (default 10).
iso_docker_storage_fix() {
    command -v docker >/dev/null 2>&1 || return 0
    [ "${OSMO_ISO_NO_DOCKER_FIX:-0}" = 1 ] && return 0
    # A pull alone (--skip-build) does not need nested overlays.
    local fs; fs="$(findmnt -no FSTYPE -T /var/lib/containerd 2>/dev/null || stat -f -c %T /var/lib/containerd 2>/dev/null)"
    [ "$fs" = overlay ] || return 0
    [ "$(id -u)" = 0 ] || { echo -e "${YELLOW}! /var/lib/containerd est sur overlay : le build docker echouera (relancer en root)${NC}" >&2; return 0; }

    local img=/var/lib/docker-loop.img base=/var/lib/dockerdata gb="${OSMO_ISO_DOCKER_LOOP_GB:-10}"
    echo -e "  ${CYAN}stockage docker sur overlay : bascule sur un ext4 en boucle (${gb} Go, $img)${NC}"
    if [ -n "$(docker ps -q 2>/dev/null)" ]; then
        echo -e "${RED}des conteneurs tournent : arretez-les avant (le correctif redemarre docker)${NC}" >&2
        return 1
    fi
    systemctl stop docker docker.socket containerd || return 1
    mkdir -p "$base"
    if [ ! -f "$img" ]; then
        truncate -s "${gb}G" "$img" && mkfs.ext4 -q -F "$img" || return 1
    fi
    mountpoint -q "$base" || mount -o loop "$img" "$base" || return 1
    mkdir -p "$base/docker" "$base/containerd"
    mountpoint -q /var/lib/docker     || mount --bind "$base/docker" /var/lib/docker || return 1
    mountpoint -q /var/lib/containerd || mount --bind "$base/containerd" /var/lib/containerd || return 1
    if ! grep -q docker-loop /etc/fstab 2>/dev/null; then
        printf '%s\n' "$img $base ext4 loop 0 0" \
            "$base/docker /var/lib/docker none bind 0 0" \
            "$base/containerd /var/lib/containerd none bind 0 0" >> /etc/fstab
    fi
    systemctl start containerd docker || return 1
    sleep 3
    echo -e "  ${GREEN}✓${NC} docker stocke sur $(findmnt -no FSTYPE -T /var/lib/containerd)"
}
iso_docker_storage_fix || { echo -e "${RED}Correctif du stockage docker echoue (voir plus haut)${NC}" >&2; exit 1; }

# End of module: always return 0 (see 20-hote.sh).
true
