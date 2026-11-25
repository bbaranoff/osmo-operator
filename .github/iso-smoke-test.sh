#!/bin/bash
# iso-smoke-test.sh ISO... - boot test of the live ISOs, headless, in QEMU.
#
# For each ISO: its kernel and initrd (/boot/vmlinuz, /boot/initrd.img, the
# files the GRUB menu boots - iso_modules/90-iso.sh) are taken out with
# xorriso, then QEMU boots them with the ISO as CD-ROM, so live-boot finds and
# mounts the real squashfs. The serial console is watched until systemd reports
# the multi-user (or graphical) target, or a login prompt shows. GRUB itself is
# not exercised (it needs a screen); everything after it is.
#
# A failure (timeout, kernel panic, QEMU gone) makes the script exit 1: the
# workflow does not publish. Serial logs: $OSMO_SMOKE_LOGS/<image>.serial.log.
#
# Environment:
#   OSMO_SMOKE_TIMEOUT  seconds per ISO (default 300; tripled without KVM)
#   OSMO_SMOKE_MEM      MB of RAM for the VM (default 4096)
#   OSMO_SMOKE_LOGS     log directory (default smoke-logs)
set -uo pipefail

TIMEOUT="${OSMO_SMOKE_TIMEOUT:-300}"
MEM="${OSMO_SMOKE_MEM:-4096}"
LOGS="${OSMO_SMOKE_LOGS:-smoke-logs}"
OK_RE='Reached target .*(Multi-User System|Graphical Interface)|login: '
KO_RE='Kernel panic|Unable to find a medium containing a live file system|end Kernel panic|BusyBox v[0-9.]+ .*built-in shell'

[ "$#" -gt 0 ] || { echo "usage : $0 ISO..." >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 absent" >&2; exit 2; }
# Kernel and initrd come out with xorriso; without it (root only), the ISO is
# mounted read-only instead.
if ! command -v xorriso >/dev/null && [ "$(id -u)" != 0 ]; then
    echo "xorriso absent (ou lancer en root : montage en lecture seule)" >&2; exit 2
fi
extraire() {   # $1 = ISO (file or block device), $2 = destination directory
    if command -v xorriso >/dev/null; then
        xorriso -osirrox on -indev "$1" \
            -extract /boot/vmlinuz "$2/vmlinuz" -extract /boot/initrd.img "$2/initrd.img" >/dev/null 2>&1
        return
    fi
    local m="$2/mnt" opt=ro rc=0
    mkdir -p "$m"; [ -f "$1" ] && opt=ro,loop
    mount -t iso9660 -o "$opt" "$1" "$m" 2>/dev/null || return 1
    cp "$m/boot/vmlinuz" "$m/boot/initrd.img" "$2/" || rc=1
    umount "$m"; return "$rc"
}
mkdir -p "$LOGS"

if [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
else
    ACCEL=(-machine accel=tcg)
    TIMEOUT=$((TIMEOUT * 3))
    echo "pas de KVM : emulation TCG, delai porte a ${TIMEOUT} s par image"
fi

echec=0
for iso in "$@"; do
    nom="$(basename "$iso")"; nom="${nom%.iso}"
    log="$LOGS/$nom.serial.log"; : > "$log"
    tmp="$(mktemp -d)"
    echo "== $nom : demarrage ($iso)"
    if ! extraire "$iso" "$tmp"; then
        echo "::error::$nom : /boot/vmlinuz ou /boot/initrd.img introuvable dans l'ISO"
        echec=1; rm -rf "$tmp"; continue
    fi
    qemu-system-x86_64 "${ACCEL[@]}" -m "$MEM" -smp 2 \
        -drive "file=$iso,media=cdrom,readonly=on,if=ide" \
        -kernel "$tmp/vmlinuz" -initrd "$tmp/initrd.img" \
        -append "boot=live console=ttyS0,115200n8 systemd.show_status=1" \
        -display none -monitor none -serial "file:$log" \
        -nic none -no-reboot &
    qpid=$!
    t0=$SECONDS verdict=""
    while [ -z "$verdict" ]; do
        if grep -Eq "$OK_RE" "$log" 2>/dev/null; then verdict=ok
        elif grep -Eq "$KO_RE" "$log" 2>/dev/null; then verdict="echec au demarrage"
        elif ! kill -0 "$qpid" 2>/dev/null; then verdict="QEMU s'est arrete"
        elif [ $((SECONDS - t0)) -ge "$TIMEOUT" ]; then verdict="delai de ${TIMEOUT} s depasse"
        else sleep 5; fi
    done
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
    rm -rf "$tmp"
    if [ "$verdict" = ok ]; then
        echo "   ok en $((SECONDS - t0)) s : $(grep -Eo "$OK_RE" "$log" | head -1)"
    else
        echo "::error::$nom : $verdict (journal serie : $log)"
        tail -30 "$log" | sed 's/^/   | /'
        echec=1
    fi
done
exit "$echec"
