#!/bin/bash
# magnetite-c139.sh - FreeCalypso Magnetite (c139 target, hybrid-ui-vo config) in qosmo.
#
# The real TI/TCS211 firmware (rebuilt by fc-magnetite with the TMS470
# compiler under Wine) instead of the osmocom-bb layer1:
#   - 4 MiB flash image = Compal FreeCalypso bootloader in sector 0 +
#     fwimage.bin at 0x10000 (/opt/GSM/firmware/magnetite/c139-flash.img);
#   - qosmo boots at 0 in the flash (no -kernel), CALYPSO_LCD=c139 puts the
#     96x64 colour screen of the C139 on uWire CS0 (calypso_uwire.c);
#   - RVTMUX traces of the firmware on the modem UART (-serial 0 -> pty), read
#     with rvinterf (/opt/GSM/fc-host-tools); IrDA UART on the 2nd pty.
#
#   scripts/magnetite-c139.sh [start|stop|status|log|traces|fsio|shell|gtk]
#     QEMU=/opt/GSM/qosmo/build/qemu-system-arm  FLASH=.../c139-flash.img
#     FLASH_RESET=1: start again from the pristine image (FFS erased)
#     RVINTERF=0: do not start rvinterf (decoded RVTMUX traces in $RUNDIR/rvinterf.log,
#       socket $RUNDIR/rvinterf.sock for fc-shell / fc-fsio -s)
#     QEMU_DEBUG=1: -d ${QEMU_DEBUG_FLAGS:-guest_errors,unimp} in qemu-debug.log
#     QEMU_CPU=ti925t (default): ARMv4T like the Calypso ARM7TDMI. With arm946
#       (ARMv5) the TI Thumb trampolines (pop {pc} without bit 0) run in ARM
#       -> prefetch abort at the first one.
#     CALYPSO_LCD_DEBUG=1: LCD commands on stderr
set -u
RUNDIR="${RUNDIR:-/dev/shm/magnetite}"
QEMU="${QEMU:-/opt/GSM/qosmo/build/qemu-system-arm}"
FLASH_SRC="${FLASH:-/opt/GSM/firmware/magnetite/c139-flash.img}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cmd="${1:-start}"

vivant() { [ -f "$RUNDIR/qemu.pid" ] && kill -0 "$(cat "$RUNDIR/qemu.pid")" 2>/dev/null; }

case "$cmd" in
start)
    if vivant; then echo "deja lance (pid $(cat "$RUNDIR/qemu.pid"))"; exit 0; fi
    [ -x "$QEMU" ] || { echo "QEMU absent : $QEMU" >&2; exit 1; }
    [ -f "$FLASH_SRC" ] || { echo "image flash absente : $FLASH_SRC (voir doc/magnetite.md)" >&2; exit 1; }
    mkdir -p "$RUNDIR"
    # working copy: the firmware writes its FFS in the flash (0x3C0000, 3 x 64 KiB),
    # kept from one run to the next (IMEI, rfcap, config); FLASH_RESET=1 or a newer
    # source image (new build) replace it.
    if [ "${FLASH_RESET:-0}" != 0 ] || [ ! -f "$RUNDIR/flash.img" ] || [ "$FLASH_SRC" -nt "$RUNDIR/flash.img" ]; then
        cp "$FLASH_SRC" "$RUNDIR/flash.img" && echo "flash de travail (re)creee depuis $FLASH_SRC"
    fi
    dbg=()
    [ "${QEMU_DEBUG:-0}" != 0 ] && dbg=(-d "${QEMU_DEBUG_FLAGS:-guest_errors,unimp}" -D "$RUNDIR/qemu-debug.log")
    # QEMU_GDB=1: gdb stub on tcp::${QEMU_GDB_PORT:-1240} (gdb-multiarch, symbols: fwimage.map addresses)
    [ "${QEMU_GDB:-0}" != 0 ] && dbg+=(-gdb "tcp::${QEMU_GDB_PORT:-1240}")
    [ "${QEMU_GDB_WAIT:-0}" != 0 ] && dbg+=(-S)     # CPU halted at start, gdb does « continue »
    [ -n "${QEMU_TRACE:-}" ] && dbg+=(-trace "$QEMU_TRACE")   # e.g. QEMU_TRACE='pflash*' (in qemu.log)
    CALYPSO_PACER_RATTRAPAGE="${CALYPSO_PACER_RATTRAPAGE:-0}" \
    CALYPSO_LCD=c139 CALYPSO_LCD_SHM="${CALYPSO_LCD_SHM:-/dev/shm/calypso_lcd}" \
    CALYPSO_KEYS_SOCK="${CALYPSO_KEYS_SOCK:-/tmp/calypso_keys.sock}" \
    "$QEMU" -M calypso -cpu "${QEMU_CPU:-ti925t}" -display none -parallel none \
        -serial pty -serial pty -monitor "unix:$RUNDIR/monitor.sock,server,nowait" \
        -drive if=pflash,file="$RUNDIR/flash.img",format=raw "${dbg[@]}" \
        > "$RUNDIR/qemu.log" 2>&1 &
    echo $! > "$RUNDIR/qemu.pid"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        grep -q 'char device redirected' "$RUNDIR/qemu.log" 2>/dev/null && break; sleep 0.3
    done
    grep -o '/dev/pts/[0-9]*' "$RUNDIR/qemu.log" | head -1 > "$RUNDIR/modem.pty"
    grep -o '/dev/pts/[0-9]*' "$RUNDIR/qemu.log" | sed -n 2p > "$RUNDIR/irda.pty"
    RVINTERF_BIN="${RVINTERF_BIN:-/opt/GSM/fc-host-tools/rvinterf/lowlevel/rvinterf}"
    if [ "${RVINTERF:-1}" != 0 ] && [ -x "$RVINTERF_BIN" ] && [ -s "$RUNDIR/modem.pty" ]; then
        rm -f "$RUNDIR/rvinterf.sock"
        "$RVINTERF_BIN" -n -l "$RUNDIR/rvinterf.log" -s "$RUNDIR/rvinterf.sock" "$(cat "$RUNDIR/modem.pty")" \
            > "$RUNDIR/rvinterf.out" 2>&1 &
        echo $! > "$RUNDIR/rvinterf.pid"
    fi
    echo "qemu pid $(cat "$RUNDIR/qemu.pid")  UART modem (RVTMUX) $(cat "$RUNDIR/modem.pty")  IrDA $(cat "$RUNDIR/irda.pty")"
    echo "journal : $RUNDIR/qemu.log ; ecran : /usr/bin/python3 $HERE/tools/osmo-c123-gtk.py --modele c139"
    ;;
stop)
    vivant && kill "$(cat "$RUNDIR/qemu.pid")" && echo "arrete"
    [ -f "$RUNDIR/rvinterf.pid" ] && kill "$(cat "$RUNDIR/rvinterf.pid")" 2>/dev/null
    rm -f "$RUNDIR/qemu.pid" "$RUNDIR/rvinterf.pid"
    ;;
traces)
    tail -n "${2:-40}" "$RUNDIR/rvinterf.log"
    ;;
fsio|shell)
    # FreeCalypso fc-fsio / fc-shell on the rvinterf socket
    bin="/opt/GSM/fc-host-tools/rvinterf/$([ "$cmd" = fsio ] && echo etmsync/fc-fsio || echo asyncshell/fc-shell)"
    exec "$bin" -s "$RUNDIR/rvinterf.sock" "${@:2}"
    ;;
status)
    if vivant; then echo "en marche (pid $(cat "$RUNDIR/qemu.pid")), modem $(cat "$RUNDIR/modem.pty" 2>/dev/null)"; else echo "arrete"; fi
    ;;
log)
    tail -n "${2:-40}" "$RUNDIR/qemu.log"
    ;;
gtk)
    # explicit --lcd/--keys: without them the window takes the first live non-TRX instance
    # (rssi, instance 4) and shows its screen instead of Magnetite.
    exec /usr/bin/python3 "$HERE/tools/osmo-c123-gtk.py" --modele c139 \
        --lcd "${CALYPSO_LCD_SHM:-/dev/shm/calypso_lcd}" --keys "${CALYPSO_KEYS_SOCK:-/tmp/calypso_keys.sock}" "${@:2}"
    ;;
*)
    echo "usage : $0 start|stop|status|log|traces|fsio [cmd]|shell [cmd]|gtk" >&2; exit 2
    ;;
esac
