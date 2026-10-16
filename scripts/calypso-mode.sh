#!/bin/bash
# =============================================================================
# scripts/calypso-mode.sh - a qui est le Calypso (QEMU + ROM TI) : voix ou data.
# =============================================================================
#
# La couche 1 du Calypso (osmocon, /tmp/osmocom_l2) n accepte qu UN client de
# couche 2. Deux clients se la volent : chacun la remet a zero (RESET FULL),
# le mobile perd le reseau (« No service ») et le modem ne s attache pas.
#
#   voix   le `mobile` osmocom-bb (MS#1, VTY 4247) : appels, SMS, USSD.
#   data   le `modem` osmocom-bb GPRS (IMSI du mobile, 001010001000001) : attach GPRS,
#          contexte PDP, tun_modem dans le netns msgprs. Le mobile est arrete.
#
# Le passage data -> voix relance le mobile EXACTEMENT comme c54x_exe/run.sh
# l avait lance (ligne de commande, repertoire et journal releves dans /proc
# avant de l arreter). Appele par tools/osmo-phonesim-banc.py : ATD*99 du
# telephone -> data ; appel ou SMS -> voix (une 2G de classe B : pas de data
# pendant la voix). Un appel ENTRANT ne peut pas arriver en mode data : le
# mobile n est pas la pour etre pagine.
#
# Usage : calypso-mode.sh data|voix|etat [--wait]
#   --wait   data : attendre l adresse de tun_modem (PDP actif, 240 s max)
#            voix : attendre le mobile en service normal (120 s max)
# Etat : /run/osmo-banc/calypso-mode (voix|data), ligne du mobile :
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

# Le fichier de config d un client de couche 2 (mobile ou modem) vise-t-il SOCK ?
# Sans « layer2-socket », osmocom-bb prend /tmp/osmocom_l2.
vise_sock() {
    local cfg="$1" s
    s="$(awk '$1=="layer2-socket"{print $2; exit}' "$cfg" 2>/dev/null)"
    [ "${s:-/tmp/osmocom_l2}" = "$SOCK" ]
}
# Les PID des `mobile` branches sur SOCK
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
        # La ligne exacte du mobile, pour le relancer a l identique
        tr '\0' '\n' < "/proc/$p/cmdline" > "$ETAT/calypso-mobile.cmd"
        readlink "/proc/$p/cwd" > "$ETAT/calypso-mobile.cwd"
        readlink "/proc/$p/fd/1" > "$ETAT/calypso-mobile.log" 2>/dev/null || true
        # [2026-10-15] SIGTERM ne suffit pas : le mobile tente un detach IMSI
        # propre, qu il n acheve pas sur une couche 1 disputee (vu : mobile
        # vivant 2 min apres le SIGTERM, a cote du modem). 3 s, puis SIGKILL.
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
        # Comme c54x_exe/run.sh (etape 4) : priorite de la chaine, sortie ligne a ligne
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
# [2026-10-15] Pas de couche 1, pas de bascule : banc arrete (ou pas en DSP),
# le mobile ou le modem relance mourait aussitot (« Failed to create unix
# domain socket /tmp/osmocom_l2 »). On le dit au lieu de lancer pour rien.
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
