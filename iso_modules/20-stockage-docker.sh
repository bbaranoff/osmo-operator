#!/bin/bash
# iso_modules/20-stockage-docker.sh - keep Docker storage off overlayfs
# Sourced by build-iso.sh in numeric order (after 20-hote: docker is
# installed). Not meant to run on its own.
#
# When the host is itself a container or a live system (root on `overlay`),
# the docker/containerd overlayfs snapshotter mounts an overlay ON an overlay,
# which the kernel refuses:
#   failed to solve: mount source: "overlay" ... err: invalid argument
# The fix lives in packaging/docker-storage.sh, shared with build.sh and the
# image's osmo-docker-storage.service (installed by 83-espace-ram.sh).
# Env: OSMO_ISO_NO_DOCKER_FIX=1 disables it; OSMO_DOCKER_STORAGE_DIR,
# OSMO_DOCKER_TMPFS_SIZE, OSMO_ISO_DOCKER_LOOP_GB: see that script.
if command -v docker >/dev/null 2>&1; then
    bash "$DIR/packaging/docker-storage.sh" \
        || { echo -e "${RED}Correctif du stockage docker echoue (voir plus haut)${NC}" >&2; exit 1; }
fi

# End of module: always return 0 (see 20-hote.sh).
true
