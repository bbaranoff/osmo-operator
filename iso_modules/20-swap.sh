#!/bin/bash
# iso_modules/20-swap.sh - a swap for the time of the build, then removed
# Sourced by build-iso.sh in numeric order (before 21-docker-build, the first
# heavy step). Not meant to run on its own.
#
# The build (docker images, rootfs, squashfs) needs far more memory than a
# small machine has, and a secured bench has NO swap: when the memory is full
# the machine dies (2026-11-26, a build on the bench: no shutdown, nothing
# written). This module puts a swap FILE on a real disk for the time of the
# build and removes it at the end (cleanup trap of 22-wan-table.sh), or at the
# next build if the machine died first.
#
# ENCRYPTED WITH A KEY THAT DIES WITH THE BUILD: the file goes through a loop
# device and plain dm-crypt keyed from /dev/urandom - the key is only in the
# kernel's memory. What the build swaps out (and whatever else the memory
# held: passphrases being typed, keys...) is unreadable on the disk as soon
# as the swap is closed or the power goes: same perimeter as the RAM. Without
# cryptsetup, on a secured bench, no swap at all (never a swap in clear there).
#
# Where: OSMO_ISO_SWAP_DIR, else the work directory's parent (OSMO_ISO_WORK,
# default /var/tmp) if it is on a disk, else /home if it is on a disk (secured
# bench opened « Persistant »). Never on tmpfs/overlay (that would be RAM).
# Size: OSMO_ISO_SWAP_GB (default: the RAM, at least 8), reduced to keep
# 30 GB free for the build itself. OSMO_ISO_SWAP_GB=0: no swap.

ISO_SWAP_FICHIER=""; ISO_SWAP_BOUCLE=""; ISO_SWAP_MAPPE=""

# a directory on a real disk (not RAM)? prints nothing when it is not
iso_swap_disque() {
    local d="$1" fs
    [ -d "$d" ] && [ -w "$d" ] || return 1
    fs="$(findmnt -no FSTYPE -T "$d" 2>/dev/null)" || return 1
    case "$fs" in
        ""|tmpfs|ramfs|overlay|squashfs|iso9660|zram|devtmpfs|fuse*) return 1 ;;
    esac
}

iso_swap_retirer() {
    [ -n "$ISO_SWAP_FICHIER" ] || return 0
    local dev="${ISO_SWAP_MAPPE:+/dev/mapper/$ISO_SWAP_MAPPE}"
    dev="${dev:-${ISO_SWAP_BOUCLE:-$ISO_SWAP_FICHIER}}"
    swapoff "$dev" 2>/dev/null || true
    [ -n "$ISO_SWAP_MAPPE" ] && cryptsetup close "$ISO_SWAP_MAPPE" 2>/dev/null || true
    [ -n "$ISO_SWAP_BOUCLE" ] && losetup -d "$ISO_SWAP_BOUCLE" 2>/dev/null || true
    rm -f "$ISO_SWAP_FICHIER"
    ISO_SWAP_FICHIER=""
}

# what a build killed before its end left (reboot, crash): its key is gone,
# the file is noise - removed if nothing uses it any more
iso_swap_restes() {
    local f
    for f in "$1"/.osmo-iso-swap-*; do
        [ -f "$f" ] || continue
        losetup -j "$f" 2>/dev/null | grep -q . && continue
        swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$f" && continue
        rm -f "$f" && echo -e "  ${YELLOW}swap d un build interrompu retire : $f${NC}"
    done
}

iso_swap_poser() {
    local go="${OSMO_ISO_SWAP_GB:-}" ram_go dir libre_go deja_go nom dev banc=0
    [ "$go" = 0 ] && return 0
    [ "$(id -u)" = 0 ] || return 0
    # a pass re-executed by --all: the parent's swap is already there
    [ -n "${OSMO_ISO_SWAP_ACTIF:-}" ] && return 0
    mountpoint -q /var/lib/osmo-diffs 2>/dev/null && banc=1

    ram_go=$(( ( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) + 1048575 ) / 1048576 ))
    [ -n "$go" ] || { go=$ram_go; [ "$go" -ge 8 ] || go=8; }

    if [ -n "${OSMO_ISO_SWAP_DIR:-}" ]; then
        dir="$OSMO_ISO_SWAP_DIR"
        iso_swap_disque "$dir" || { echo -e "${RED}OSMO_ISO_SWAP_DIR=$dir n est pas sur un disque (ou pas inscriptible) : pas de swap${NC}" >&2; return 0; }
    elif iso_swap_disque "${OSMO_ISO_WORK:-/var/tmp}"; then dir="${OSMO_ISO_WORK:-/var/tmp}"
    elif iso_swap_disque /home; then dir=/home
    else
        echo -e "${YELLOW}pas de disque inscriptible pour un swap (tout est en RAM) : build sans swap${NC}"
        return 0
    fi
    iso_swap_restes "$dir"

    # the swap already there counts
    deja_go=$(( $(awk '/^SwapTotal:/ {print $2}' /proc/meminfo) / 1048576 ))
    if [ "$deja_go" -ge "$go" ]; then
        echo -e "  ${GREEN}✓${NC} swap deja present : ${deja_go} Go"; return 0
    fi
    go=$(( go - deja_go ))
    libre_go=$(( $(df -Pk "$dir" | awk 'NR==2 {print $4}') / 1048576 ))
    [ "$go" -le $(( libre_go - 30 )) ] || go=$(( libre_go - 30 ))
    if [ "$go" -lt 2 ]; then
        echo -e "${YELLOW}pas la place pour un swap dans $dir (${libre_go} Go libres, 30 gardes pour le build)${NC}"
        return 0
    fi
    if ! command -v cryptsetup >/dev/null 2>&1 && [ "$banc" = 1 ]; then
        echo -e "${YELLOW}poste securise sans cryptsetup : pas de swap (jamais en clair ici)${NC}"
        return 0
    fi

    ISO_SWAP_FICHIER="$dir/.osmo-iso-swap-$$"
    if ! fallocate -l "${go}G" "$ISO_SWAP_FICHIER" 2>/dev/null; then
        rm -f "$ISO_SWAP_FICHIER"; ISO_SWAP_FICHIER=""
        echo -e "${YELLOW}swap : fichier de ${go} Go impossible dans $dir (fallocate) : build sans swap${NC}"
        return 0
    fi
    chmod 0600 "$ISO_SWAP_FICHIER"
    if command -v cryptsetup >/dev/null 2>&1; then
        nom="osmo-iso-swap-$$"
        ISO_SWAP_BOUCLE="$(losetup --direct-io=on -f --show "$ISO_SWAP_FICHIER" 2>/dev/null \
                           || losetup -f --show "$ISO_SWAP_FICHIER")" || { iso_swap_retirer; return 0; }
        cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
            --key-file /dev/urandom "$ISO_SWAP_BOUCLE" "$nom" || { iso_swap_retirer; return 0; }
        ISO_SWAP_MAPPE="$nom"; dev="/dev/mapper/$nom"
    else
        dev="$ISO_SWAP_FICHIER"           # ordinary machine without cryptsetup
    fi
    if mkswap -q "$dev" >/dev/null && swapon -p 10 "$dev"; then
        export OSMO_ISO_SWAP_ACTIF=1
        echo -e "  ${GREEN}✓${NC} swap du build : ${CYAN}${go} Go${NC} dans $dir${ISO_SWAP_MAPPE:+, chiffre (cle aleatoire perdue a la fin)} - retire a la fin"
    else
        echo -e "${YELLOW}swap : activation impossible : build sans swap${NC}"
        iso_swap_retirer
    fi
    return 0
}

iso_swap_poser
# 22-wan-table.sh sets the cleanup trap: until then, the swap goes away with us
trap iso_swap_retirer EXIT

# End of module: always return 0 (see 20-hote.sh).
true
