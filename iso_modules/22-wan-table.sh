#!/bin/bash
# iso_modules/22-wan-table.sh - WAN node table, cleanup trap, required tools, WORK dirs
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── WAN table: fixed HERE, before the build starts ───────────────────────────
# --role=interstp implies the WAN (the hub must know how many nodes it serves).
# The table is fixed now, with the bench table as default, so that no question
# is asked in the middle of an hour-long (possibly CI, terminal-less) build.
# --wan-nodes="..." and --hub-ip=... take precedence; OSMO_ISO_WAN_ASK=1 asks
# interactively instead (requires a terminal).
if [ "$ISO_WAN" = "1" ] && [ -z "$ISO_WAN_NODES" ]; then
    if [ "${OSMO_ISO_WAN_ASK:-0}" = "1" ] && [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}== Table WAN de l'image ==${NC}"
        echo -e "  Format : ${CYAN}<noeud>:<IP>:<indicatif>${NC}, separes par des espaces."
        echo -e "  Entree vide = le banc : ${CYAN}${ISO_WAN_NODES_DEFAULT}${NC}"
        read -rp "  Noeuds : " _wan_in || _wan_in=""
        ISO_WAN_NODES="${_wan_in:-$ISO_WAN_NODES_DEFAULT}"
        if [ "$ISO_ROLE" = "interstp" ]; then
            read -rp "  IP du hub [${ISO_HUB_IP}] : " _hub_in || _hub_in=""
            ISO_HUB_IP="${_hub_in:-$ISO_HUB_IP}"
        fi
    else
        ISO_WAN_NODES="$ISO_WAN_NODES_DEFAULT"
    fi
    echo -e "  ${GREEN}✓${NC} WAN : ${CYAN}${ISO_WAN_NODES}${NC}   hub ${CYAN}${ISO_HUB_IP}${NC}  (defaut du banc ; --wan-nodes= / --hub-ip= pour changer)"
fi

# Propagate --no-cache to both Docker builds: build.sh (osmocom-nitb image) and
# build_run_image (osmocom-run image, via DOCKER_NO_CACHE).
export DOCKER_NO_CACHE="$NO_CACHE"


cleanup() { umount "$ROOTFS/var/cache/apt/archives" 2>/dev/null||true; umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT


# Host packages: once (see iso_host_packages, defined earlier).
iso_host_packages

# Docker is not auto-installed here (docker-ce is outside the standard apt repos).
_ISO_TOOLS="docker mksquashfs xorriso grub-mkrescue debootstrap git"
# qemu-aarch64-static is only required to EMULATE: on a host that is already
# aarch64 it is not needed. Same rule as 40-rootfs.sh, which decides on
# --foreign by comparing with the host architecture.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    _ISO_TOOLS="docker debootstrap git mke2fs mkfs.vfat mcopy sfdisk truncate"
    [ "$ISO_ARCH" = "$(dpkg --print-architecture 2>/dev/null || echo amd64)" ] \
        || _ISO_TOOLS="$_ISO_TOOLS qemu-aarch64-static"
fi
for t in $_ISO_TOOLS; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
iso_arm_binfmt
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo-operator ISO builder (via build.sh + start-docker.sh) ══${NC}"


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
