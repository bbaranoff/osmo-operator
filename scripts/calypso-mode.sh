#!/bin/bash
# =============================================================================
# scripts/calypso-mode.sh - who owns the Calypso (QEMU + TI ROM): voice or data.
# =============================================================================
#
# The Calypso layer 1 (osmocon, /tmp/osmocom_l2) accepts only one layer 2
# client. Two clients steal it from each other: each resets it (RESET FULL),
# the mobile loses the network (« No service ») and the modem does not attach.
#
#   voix   the osmocom-bb `mobile` (MS#1, VTY 4247): calls, SMS, USSD.
#   data   the osmocom-bb GPRS `modem` (IMSI of the mobile, 001010001000001):
#          GPRS attach, PDP context, tun_modem in the msgprs netns. The mobile
#          is stopped.
#
# Switching data -> voice restarts the mobile exactly as c54x_exe/run.sh had
# started it (command line, directory and log read from /proc before stopping
# it). Called by tools/osmo-phonesim-banc.py: ATD*99 from the phone -> data;
# call or SMS -> voice (a class B 2G: no data during voice). An incoming call
# cannot arrive in data mode: the mobile is not there to be paged.
#
# Usage: calypso-mode.sh data|voix|etat [--wait]
#   --wait   data: wait for the tun_modem address (PDP active, 240 s max)
#            voix: wait for the mobile in normal service (120 s max)
# State: /run/osmo-banc/calypso-mode (voix|data), mobile command line:
#        /run/osmo-banc/calypso-mobile.{cmd,cwd,log}
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETC="${OSMOCOM_CFG:-/etc/osmocom}"
SOCK="${CALYPSO_L2_SOCK:-/tmp/osmocom_l2}"
NETNS="${EGPRS_NETNS:-msgprs}"
ETAT=/run/osmo-banc
MODE_F="$ETAT/calypso-mode"
U_MODEM=osmo-modem-gprs
MOB_VTY="${OSMO_MOB_VTY_PORT:-4247}"
MODEM_BIN="$(command -v modem 2>/dev/null || echo /opt/GSM/osmocom-bb/src/host/layer23/src/modem/modem)"
mkdir -p "$ETAT"

log() { printf '[calypso-mode] %s\n' "$*"; }
mode_courant() { cat "$MODE_F" 2>/dev/null || echo voix; }

# Does the config file of a layer 2 client (mobile or modem) point at SOCK?
# Without « layer2-socket », osmocom-bb uses /tmp/osmocom_l2.
vise_sock() {
    local cfg="$1" s
    s="$(awk '$1=="layer2-socket"{print $2; exit}' "$cfg" 2>/dev/null)"
    [ "${s:-/tmp/osmocom_l2}" = "$SOCK" ]
}
# The PIDs of the `mobile` processes connected to SOCK
mobiles_sur_sock() {
    local p c
    for p in $(pgrep -x mobile); do
        c="$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | awk 'p{print; exit} $0=="-c"{p=1}')"
        [ -n "$c" ] || continue
        case "$c" in /*) ;; *) c="$(readlink "/proc/$p/cwd")/$c" ;; esac
        vise_sock "$c" && echo "$p"
    done
}
port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
vty() {
    { sleep 0.3; printf 'enable\n'; local c; for c in "$@"; do sleep 0.3; printf '%s\n' "$c"; done; sleep 0.6; } \
        | timeout 6 nc -q1 127.0.0.1 "$MOB_VTY" 2>/dev/null | tr -d '\r'
}

vers_data() {
    local p n=0
    for p in $(mobiles_sur_sock); do
        # The exact mobile command line, to restart it identically
        tr '\0' '\n' < "/proc/$p/cmdline" > "$ETAT/calypso-mobile.cmd"
        readlink "/proc/$p/cwd" > "$ETAT/calypso-mobile.cwd"
        readlink "/proc/$p/fd/1" > "$ETAT/calypso-mobile.log" 2>/dev/null || true
        # SIGTERM is not enough: the mobile attempts a clean IMSI detach, which
        # it does not complete on a contended layer 1. 3 s, then SIGKILL.
        kill "$p" 2>/dev/null
        local w; for w in 1 2 3 4 5 6; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null && log "mobile $p : SIGTERM ignore, SIGKILL"
        n=$((n+1)); log "mobile $p arrete (ligne gardee dans $ETAT/calypso-mobile.cmd)"
    done
    [ "$n" -gt 0 ] && sleep 1
    ip netns list 2>/dev/null | grep -qw "$NETNS" || ip netns add "$NETNS"
    local cfg="$ETC/modem-gprs-dsp.cfg"
    sed "s|layer2-socket .*|layer2-socket $SOCK|" "$HERE/configs/gprs/modem-gprs.cfg" > "$cfg"
    if ! systemctl is-active --quiet "$U_MODEM"; then
        systemctl reset-failed "$U_MODEM" >/dev/null 2>&1 || true
        systemd-run --quiet --unit="$U_MODEM" --collect -p KillMode=control-group -p CPUAffinity="${RT_CPUS:-0-15}" -p Nice=-10 \
            -p SyslogIdentifier="$U_MODEM" "$MODEM_BIN" -c "$cfg" \
            || { log "systemd-run $U_MODEM a echoue"; return 1; }
        log "modem GPRS lance sur $SOCK ($cfg)"
    fi
    echo data > "$MODE_F"
    if [ "$ATTENDRE" = 1 ]; then
        local t=0
        until ip netns exec "$NETNS" ip -4 -o addr show dev tun_modem 2>/dev/null | grep -q 'inet '; do
            [ $t -ge 240 ] && { log "pas de PDP apres 240 s (journalctl -u $U_MODEM)"; return 1; }
            sleep 2; t=$((t+2))
        done
        log "PDP actif en ${t}s : $(ip netns exec "$NETNS" ip -4 -o addr show dev tun_modem | awk '{print $4}')"
    fi
}

vers_voix() {
    if systemctl is-active --quiet "$U_MODEM"; then
        systemctl stop "$U_MODEM"; log "modem GPRS arrete"
    fi
    systemctl reset-failed "$U_MODEM" >/dev/null 2>&1 || true
    if [ -z "$(mobiles_sur_sock)" ]; then
        [ -s "$ETAT/calypso-mobile.cmd" ] || { log "aucune ligne de mobile gardee : relancer le banc (systemctl restart osmo-banc)"; echo voix > "$MODE_F"; return 1; }
        local -a cmd; mapfile -t cmd < "$ETAT/calypso-mobile.cmd"
        local cwd jrn
        cwd="$(cat "$ETAT/calypso-mobile.cwd" 2>/dev/null || echo /)"
        jrn="$(cat "$ETAT/calypso-mobile.log" 2>/dev/null)"
        case "$jrn" in /*) ;; *) jrn=/tmp/c54x-pont/mobile.log ;; esac
        # As c54x_exe/run.sh (step 4): chain priority, line-buffered output
        ( cd "$cwd" && exec setsid taskset -c "${RT_CPUS:-0-15}" nice -n -10 stdbuf -oL "${cmd[@]}" >> "$jrn" 2>&1 < /dev/null ) &
        log "mobile relance : ${cmd[*]} (journal $jrn)"
    fi
    echo voix > "$MODE_F"
    if [ "$ATTENDRE" = 1 ]; then
        local t=0
        until port_open "$MOB_VTY" && vty "show ms" | grep -q 'service is normal'; do
            [ $t -ge 120 ] && { log "mobile pas en service normal apres 120 s"; return 1; }
            sleep 2; t=$((t+2))
        done
        log "mobile en service normal en ${t}s (VTY $MOB_VTY)"
    fi
}

ACTION="${1:-etat}"; ATTENDRE=0
[ "${2:-}" = "--wait" ] && ATTENDRE=1
# No layer 1, no switch: with the bench stopped (or not in DSP mode), a
# restarted mobile or modem would die at once (« Failed to create unix domain
# socket /tmp/osmocom_l2 »). Say so instead of starting for nothing.
if [ "$ACTION" = data ] || [ "$ACTION" = voix ]; then
    if [ ! -S "$SOCK" ]; then
        log "pas de couche 1 ($SOCK absent) : le banc DSP ne tourne pas - systemctl start osmo-banc, puis relancer"
        exit 3
    fi
fi
case "$ACTION" in
    data) vers_data ;;
    voix) vers_voix ;;
    etat)
        echo "mode    : $(mode_courant)"
        echo "mobile  : $(mobiles_sur_sock | tr '\n' ' ')"
        echo "modem   : $(systemctl is-active "$U_MODEM" 2>/dev/null)"
        echo "PDP     : $(ip netns exec "$NETNS" ip -4 -o addr show dev tun_modem 2>/dev/null | awk '{print $4}')" ;;
    *) echo "usage : $0 data|voix|etat [--wait]" >&2; exit 2 ;;
esac
