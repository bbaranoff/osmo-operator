#!/bin/bash
# magnetite-c139.sh - FreeCalypso Magnetite (cible c139, config hybrid-ui-vo) dans qosmo.
#
# [2026-10-21] Le vrai firmware TI/TCS211 (recompile par fc-magnetite avec le
# compilateur TMS470 sous Wine) a la place de la layer1 osmocom-bb :
#   - image flash 4 MiB = bootloader Compal FreeCalypso en secteur 0 +
#     fwimage.bin a 0x10000 (/opt/GSM/firmware/magnetite/c139-flash.img) ;
#   - qosmo demarre a 0 dans la flash (pas de -kernel), CALYPSO_LCD=c139 met
#     l'ecran couleur 96x64 du C139 sur uWire CS0 (calypso_uwire.c) ;
#   - traces RVTMUX du firmware sur l'UART modem (-serial 0 -> pty), a lire
#     avec rvinterf (/opt/GSM/fc-host-tools) ; UART IrDA sur le 2e pty.
#
#   scripts/magnetite-c139.sh [start|stop|status|log|traces|fsio|shell|gtk]
#     QEMU=/opt/GSM/qosmo/build/qemu-system-arm  FLASH=.../c139-flash.img
#     FLASH_RESET=1 : repartir de l'image neuve (FFS efface)
#     RVINTERF=0 : ne pas lancer rvinterf (traces RVTMUX decodees dans $RUNDIR/rvinterf.log,
#       socket $RUNDIR/rvinterf.sock pour fc-shell / fc-fsio -s)
#     QEMU_DEBUG=1 : -d ${QEMU_DEBUG_FLAGS:-guest_errors,unimp} dans qemu-debug.log
#     QEMU_CPU=ti925t (defaut) : ARMv4T comme l ARM7TDMI du Calypso. Avec arm946
#       (ARMv5) les trampolines Thumb de TI (pop {pc} sans bit 0) partent en ARM
#       -> prefetch abort a la premiere, vu le 21/10.
#     CALYPSO_LCD_DEBUG=1 : commandes LCD sur stderr
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
    # copie de travail : le firmware ecrit son FFS dans la flash (0x3C0000, 3 x 64 KiB),
    # gardee d'un lancement a l'autre (IMEI, rfcap, config) ; FLASH_RESET=1 ou une
    # image source plus recente (nouveau build) la remplacent.
    if [ "${FLASH_RESET:-0}" != 0 ] || [ ! -f "$RUNDIR/flash.img" ] || [ "$FLASH_SRC" -nt "$RUNDIR/flash.img" ]; then
        cp "$FLASH_SRC" "$RUNDIR/flash.img" && echo "flash de travail (re)creee depuis $FLASH_SRC"
    fi
    dbg=()
    [ "${QEMU_DEBUG:-0}" != 0 ] && dbg=(-d "${QEMU_DEBUG_FLAGS:-guest_errors,unimp}" -D "$RUNDIR/qemu-debug.log")
    # QEMU_GDB=1 : stub gdb sur tcp::${QEMU_GDB_PORT:-1240} (gdb-multiarch, symboles : adresses de fwimage.map)
    [ "${QEMU_GDB:-0}" != 0 ] && dbg+=(-gdb "tcp::${QEMU_GDB_PORT:-1240}")
    [ "${QEMU_GDB_WAIT:-0}" != 0 ] && dbg+=(-S)     # CPU gele au depart, gdb fait « continue »
    [ -n "${QEMU_TRACE:-}" ] && dbg+=(-trace "$QEMU_TRACE")   # ex. QEMU_TRACE='pflash*' (dans qemu.log)
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
    # fc-fsio / fc-shell de FreeCalypso sur le socket de rvinterf
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
    exec /usr/bin/python3 "$HERE/tools/osmo-c123-gtk.py" --modele c139 "${@:2}"
    ;;
*)
    echo "usage : $0 start|stop|status|log|traces|fsio [cmd]|shell [cmd]|gtk" >&2; exit 2
    ;;
esac
