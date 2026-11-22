# 13-flotte.sh - part of start.sh (extra MS and the phone window, after the stack)
# Sourced by start.sh in the main shell: same order, same variables.
#
# FLOTTE_VIRTPHY=N / FLOTTE_FAKETRX=M (start.sh --configure, "Side-car BTS#1 et
# MS supplementaires"): scripts/ms-flotte.sh, started IN THE BACKGROUND here,
# waits for the BSC and the HLR then adds the mobiles. FLOTTE_FAKETRX is
# exported for qosmo run_modules/58-sidecar-faketrx.sh (the extra --trx of
# fake_trx: its first MS is implicit). --stop stops them too.
# C123_WINDOW=auto|c123|c139: tools/osmo-c123-gtk.py once the emulated screen
# (/dev/shm/calypso_lcd) exists, if there is a display.
export FLOTTE_VIRTPHY="${FLOTTE_VIRTPHY:-0}" FLOTTE_FAKETRX="${FLOTTE_FAKETRX:-0}"
_fl_sudo=""; [ "$(id -u)" = 0 ] || _fl_sudo="sudo"
if [ "$ACTION" = stop ]; then
    $_fl_sudo bash "$HERE/scripts/ms-flotte.sh" stop >/dev/null 2>&1 || true
elif [ "$ACTION" = start ] && [ "$DRY" -eq 0 ]; then
    if [ "$FLOTTE_VIRTPHY" -gt 0 ] || [ "$FLOTTE_FAKETRX" -gt 0 ]; then
        mkdir -p /var/log/osmocom 2>/dev/null
        say_begin "MS supplementaires (virtphy $FLOTTE_VIRTPHY, faketrx $FLOTTE_FAKETRX)"
        $_fl_sudo setsid nohup env FLOTTE_VIRTPHY="$FLOTTE_VIRTPHY" FLOTTE_FAKETRX="$FLOTTE_FAKETRX" \
            bash "$HERE/scripts/ms-flotte.sh" start --wait 600 >>/var/log/osmocom/ms-flotte.log 2>&1 </dev/null &
        say_end " OK " "$C_OK" "MS supplementaires (virtphy $FLOTTE_VIRTPHY, faketrx $FLOTTE_FAKETRX)" \
            "en arriere-plan apres le coeur ; journal /var/log/osmocom/ms-flotte.log"
    fi
    if [ -n "${C123_WINDOW:-}" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        setsid nohup bash -c 'for i in $(seq 1 300); do [ -e /dev/shm/calypso_lcd ] && break; sleep 2; done
            exec /usr/bin/python3 "$1/tools/osmo-c123-gtk.py" --modele "$2"' _ "$HERE" "$C123_WINDOW" \
            >/tmp/osmo-c123-gtk.log 2>&1 </dev/null &
    fi
fi
unset _fl_sudo
