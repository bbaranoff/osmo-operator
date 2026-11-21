#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# run-dsp.sh - starts the single operator (frozen configs) in DSP mode.
# ─────────────────────────────────────────────────────────────────────────────
# Each Osmocom component is started AS AN APPLICATION (the binary in the
# foreground, sent to the background here), NOT as a systemd service. Each one
# reads its config from /etc/osmocom (installed by the Dockerfile / install.sh)
# and writes its log to $LOG_DIR.
#
# Order (SS7/A-interface dependencies):
#   osmo-stp            SS7 core (M3UA) - everyone connects to it
#   osmo-hlr            subscriber database (+ provisioning of subscriber 1 below)
#   osmo-mgw            media gateway
#   osmo-msc            talks to STP + HLR + MGW
#   osmo-bsc            talks to STP + MGW, carries the BTS OML
#   osmo-bts-trx        the air-side BTS (TRXD 5700-5702)
#   osmo-pcu/sgsn/ggsn/sip-connector   the rest of the stack (best effort)
# then the DSP chain (c54x_exe/run.sh MODE=dsp PONT=1):
#   c54x_exe --arm  ->  qosmo (ARM+L1)  ->  osmocon  ->  mobile  ->  pont_dsp.py
#
#   ./run-dsp.sh            start everything
#   ./run-dsp.sh --stop     stop everything
#   ./run-dsp.sh --logs     follow the core logs
# ─────────────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSM_ROOT="${GSM_ROOT:-/opt/GSM}"
CFG_DIR="${OSMOCOM_CFG:-/etc/osmocom}"
LOG_DIR="${LOG_DIR:-/run/osmo-minioperator/logs}"
C54X="${C54X:-$GSM_ROOT/c54x_exe}"

# Single-operator plan (must match the frozen configs/: op=1, node=1).
IMSI="${IMSI:-001010001000001}"
MSISDN="${MSISDN:-100101}"
KI_HEX="${KI_HEX:-00112233445566778899aabbccdd0101}"
HLR_VTY_IP="${HLR_VTY_IP:-127.0.0.1}"
HLR_VTY_PORT="${HLR_VTY_PORT:-4258}"

# Setup (what start.sh used to do): directories, Osmocom configs in
# /etc/osmocom if missing (a config already in place is not overwritten).
# /var/log/osmocom: the configs have "log file /var/log/osmocom/*.log".
install -d "$LOG_DIR" /etc/osmocom /var/log/osmocom /var/lib/osmocom /root/.osmocom/bb
cp -n "$HERE/configs/"*.cfg /etc/osmocom/ 2>/dev/null || true
# mobile.cfg goes to the mobile's default path (/root/.osmocom/bb), not /etc/osmocom.
cp "$HERE/configs/mobile.cfg" /root/.osmocom/bb/mobile.cfg
PIDS="$LOG_DIR/pids"
PULSE_LOCAL=/tmp/pulse/native

say() { printf '\033[1m[run-dsp]\033[0m %s\n' "$*"; }

# ── Stop: back to the state of a fresh container ─────────────────────────────
# A restart must start over as after a "docker rm": processes killed (TERM
# then KILL), shared state in /dev/shm, /tmp sockets and databases erased. A
# leftover read back at the next start (dedicated channel, Kc, ROM rings...)
# keeps the mobile from locking on. The logs are kept for analysis.
MOTIFS_PILE=( "^/usr/bin/osmo-" "^/usr/sbin/asterisk" "c54x_exe --arm" "qemu-system-arm -M calypso"
              "osmocon -m romload" "^/usr/local/bin/mobile" "pont/pont_dsp[.]py" "pont[.]vsp_audio"
              "gdb-telnet[.]py" "--device=gsm_" "socket=$PULSE_LOCAL" )
stop_all() {
    say "stopping everything (fresh container state)"
    [ -x "$C54X/run.sh" ] && MODE=dsp "$C54X/run.sh" --stop >/dev/null 2>&1 || true
    if [ -f "$PIDS" ]; then
        tac "$PIDS" | while read -r pid name; do kill "$pid" 2>/dev/null; done
        rm -f "$PIDS"
    fi
    asterisk -rx "core stop now" >/dev/null 2>&1 || true
    local m
    for m in "${MOTIFS_PILE[@]}"; do pkill -f -- "$m" 2>/dev/null; done
    # Give TERM some time (up to 5 s), then KILL whatever is left.
    for _ in $(seq 1 10); do
        pgrep -f -- "$(IFS='|'; echo "${MOTIFS_PILE[*]}")" >/dev/null 2>&1 || break
        sleep 0.5
    done
    for m in "${MOTIFS_PILE[@]}"; do pkill -9 -f -- "$m" 2>/dev/null; done
    # /dev/shm (pont.log and the PulseAudio pulse-shm-* segments are not touched)
    rm -f /dev/shm/calypso_* /dev/shm/pont_tch_dl* /dev/shm/daram_* \
          /dev/shm/apm_trace /dev/shm/tsp_trace /dev/shm/qemu-asm.fifo
    # sockets: L1CTL, SAP, data, DSP, QEMU monitor, MNCC, PCU, local PulseAudio.
    # IQ panel FIFOs (pont/record.py) and QEMU console logs: recreated when needed.
    rm -f /tmp/osmocom_l2* /tmp/osmocom_sap* /tmp/ms_data* /tmp/calypso_*.sock \
          /tmp/qemu-monitor-*.sock /tmp/msc_mncc /tmp/pcu_bts "$PULSE_LOCAL" \
          /tmp/calypso_flow.txt /tmp/qemu-fw-console.log /tmp/iq_fft.fifo /tmp/iq_fft_ms.fifo
    # PulseAudio modules loaded by audio_pulse into the host server: the
    # gsm_audio / gsm_mic null-sinks and their loopbacks stay loaded after the
    # processes stop and pile up at each restart. Unload those whose argument
    # names gsm_audio or gsm_mic (sinks AND loopbacks), leave the rest alone.
    if pactl info >/dev/null 2>&1; then
        pactl list short modules 2>/dev/null \
            | awk '/gsm_audio|gsm_mic/ {print $1}' \
            | while read -r id; do pactl unload-module "$id" >/dev/null 2>&1; done
    fi
    # HLR and SMS databases: in the container only. Natively /var/lib/osmocom
    # may belong to another stack (osmo-operator): leave it alone.
    [ "${OSMO_IMAGE:-0}" = 1 ] && rm -f /var/lib/osmocom/hlr.db* /var/lib/osmocom/sms.db*
    local reste; reste="$(for m in "${MOTIFS_PILE[@]}"; do pgrep -f -- "$m"; done | sort -u | tr '\n' ' ')"
    [ -n "${reste// /}" ] && say "  WARNING: processes still alive: $reste" || true
}

case "${1:-}" in
    --stop) stop_all; exit 0 ;;
    --logs) exec tail -n +1 -F "$LOG_DIR"/*.log ;;
    -h|--help) sed -n '4,24p' "$0"; exit 0 ;;
esac

# ── Start a component as an application ──────────────────────────────────────
# app <binary> <config-file> [args...]
: > "$PIDS"
app() {
    local bin="$1" cfg="$2"; shift 2
    local path; path="$(command -v "$bin" || true)"
    if [ -z "$path" ]; then say "  MISSING: $bin (skipped)"; return 0; fi
    if [ -n "$cfg" ] && [ ! -f "$CFG_DIR/$cfg" ]; then
        say "  config missing: $CFG_DIR/$cfg ($bin skipped)"; return 0
    fi
    local args=()
    [ -n "$cfg" ] && args+=(-c "$CFG_DIR/$cfg")
    # cwd /var/lib/osmocom: osmo-msc creates sms.db there (relative path).
    ( cd /var/lib/osmocom && exec "$path" "${args[@]}" "$@" ) >"$LOG_DIR/$bin.log" 2>&1 &
    local pid=$!
    echo "$pid $bin" >> "$PIDS"
    say "  start $bin ($pid)  cfg=${cfg:-none}"
    sleep 1
}

# ── Audio: PulseAudio for the VSP voice bridge (gsm_audio / gsm_mic) ────────
# Host PulseAudio reachable (socket mounted by docker-run.sh): use it and
# create gsm_audio / gsm_mic there if missing, wired to the default output
# and input. Otherwise: local server with no physical output, the voice
# flows (verif.sh measures it) but cannot be heard.
audio_pulse() {
    if ! pactl info >/dev/null 2>&1; then
        install -d "$(dirname "$PULSE_LOCAL")"
        PULSE_SERVER="unix:$PULSE_LOCAL" pactl info >/dev/null 2>&1 || pulseaudio -n --daemonize=yes --exit-idle-time=-1 --use-pid-file=no \
            --load="module-native-protocol-unix auth-anonymous=1 socket=$PULSE_LOCAL" >/dev/null 2>&1
        export PULSE_SERVER="unix:$PULSE_LOCAL"
        for _ in $(seq 1 20); do pactl info >/dev/null 2>&1 && break; sleep 0.25; done
        say "  no host PulseAudio: local server without sound (./docker-run.sh to hear it)"
    fi
    local reel=1; [ "${PULSE_SERVER:-}" = "unix:$PULSE_LOCAL" ] && reel=0
    local s
    for s in gsm_audio gsm_mic; do
        pactl list short sinks | awk '{print $2}' | grep -qx "$s" && continue
        pactl load-module module-null-sink sink_name="$s" format=s16le rate=8000 channels=1 >/dev/null
        if [ "$reel" = 1 ] && [ "$s" = gsm_audio ]; then
            pactl load-module module-loopback source=gsm_audio.monitor sink=@DEFAULT_SINK@ latency_msec=40 >/dev/null
        elif [ "$reel" = 1 ]; then
            pactl load-module module-loopback source=@DEFAULT_SOURCE@ sink=gsm_mic latency_msec=40 >/dev/null
        fi
    done
    echo "${PULSE_SERVER:-defaut}" > "$LOG_DIR/pulse_server"
    say "  audio: ${PULSE_SERVER:-default} ($([ "$reel" = 1 ] && echo "host PulseAudio" || echo "local, no sound"))"
}

say "configs: $CFG_DIR    logs: $LOG_DIR"

# Start clean: run.sh skips the steps whose process is already alive.
stop_all >/dev/null 2>&1
: > "$PIDS"

# Core, each one as an application (dependency order). osmo-bts-trx and
# osmo-pcu start AFTER the DSP chain: the bridge holds TRXC/TRXD (5700-5702).
app osmo-stp        osmo-stp.cfg
app osmo-hlr        osmo-hlr.cfg       --database /var/lib/osmocom/hlr.db
app osmo-mgw        osmo-mgw.cfg
app osmo-msc        osmo-msc.cfg
app osmo-bsc        osmo-bsc.cfg
app osmo-sgsn           osmo-sgsn.cfg
app osmo-ggsn           osmo-ggsn.cfg
# Asterisk (PBX: echo 600, announcement 700, Linphone 100/200), as an application
# (-f: no fork) under the package's asterisk user.
install -d /var/spool/asterisk/monitor /var/run/asterisk /usr/share/asterisk/moh
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk /var/lib/asterisk 2>/dev/null
app asterisk            ""  -f -g
app osmo-sip-connector  osmo-sip-connector.cfg

# ── Provisioning subscriber 1 in the HLR (through the VTY, not a service) ────
say "HLR provisioning: IMSI=$IMSI MSISDN=$MSISDN"
for _ in $(seq 1 20); do
    ss -ltnH 2>/dev/null | grep -q "$HLR_VTY_IP:$HLR_VTY_PORT " && break
    sleep 0.5
done
{
    sleep 1
    printf 'enable\r\n'
    printf 'subscriber imsi %s create\r\n' "$IMSI"
    printf 'subscriber imsi %s update msisdn %s\r\n' "$IMSI" "$MSISDN"
    printf 'subscriber imsi %s update aud2g comp128v1 ki %s\r\n' "$IMSI" "$KI_HEX"
    printf 'show subscriber imsi %s\r\n' "$IMSI"
    sleep 2
} | telnet "$HLR_VTY_IP" "$HLR_VTY_PORT" >"$LOG_DIR/hlr-provision.log" 2>&1
if grep -q "$KI_HEX" "$LOG_DIR/hlr-provision.log"; then
    say "  subscriber provisioned (Ki present)"
else
    say "  provisioning FAILED - see $LOG_DIR/hlr-provision.log"
fi

# ── The DSP chain ────────────────────────────────────────────────────────────
# c54x_exe/run.sh runs DSP + qosmo (ARM+L1) + osmocon + mobile + pont_dsp.py.
# PONT_PY points to this repo's pont/ package.
say "starting the DSP chain (MODE=dsp PONT=1)"
export MODE=dsp PONT=1
export PONT_PY="${PONT_PY:-$HERE/pont/pont_dsp.py}"
export OSMOCON="${OSMOCON:-$GSM_ROOT/osmocom-bb/src/host/osmocon/osmocon}"
export MOBILE="${MOBILE:-$(command -v mobile || echo /usr/local/bin/mobile)}"
export QOSMO="${QOSMO:-$GSM_ROOT/qosmo}"
# FROZEN mobile config (ARFCN 514, tch-voice already on io-handler l1phy). It is
# already in the target state, so do NOT force BANC_VOCODEUR=rom: the gapk->l1phy
# conversion of run.sh (config_vocodeur_rom) would need an "io-handler gapk"
# block and would fail on a file already set to l1phy. BANC_VOCODEUR stays "hote"
# (run.sh default = no conversion); the DSP's ROM vocoder is driven by
# CALYPSO_VSP=1 (modelled voice port).
export MOBILE_CFG="${MOBILE_CFG:-/root/.osmocom/bb/mobile.cfg}"
export BANC_VOCODEUR="${BANC_VOCODEUR:-hote}"
export CALYPSO_VSP="${CALYPSO_VSP:-1}"
# DSP settings of the osmo-operator launch (14-demarrage.sh): one TS0 burst per
# frame in FN order, DMA delivery, 120000 insn/frame: verified default
# (LU + DL/UL voice). Tunable with INSNS=.
export IQ="${IQ:-none}" INSNS="${INSNS:-120000}" LOCKSTEP="${LOCKSTEP:-1}"
export CALYPSO_RHEA_DMA_XFER="${CALYPSO_RHEA_DMA_XFER:-1}"
export CALYPSO_BSP_STREAM="${CALYPSO_BSP_STREAM:-1}"
# ROM vocoder and uplink speech, as in osmo-operator (14-demarrage.sh): without
# these C54x emulator flags, the ROM encodes the silence frame and the 600
# echo stays mute.
for _kv in CALYPSO_NORM_TC=0 CALYPSO_C54X_BCTC_NORM=1 PONT_UL_RAW_TCH=1 \
           CALYPSO_C54X_BCD_CARRY=1 CALYPSO_C54X_OVM_LOGIQUE=1 CALYPSO_MAC=1 \
           CALYPSO_C54X_BCD_TC=1 CALYPSO_C54X_BCTC_COMBO=1; do
    _k="${_kv%%=*}"; [ -n "${!_k+x}" ] || export "$_kv"
done
unset _kv _k
audio_pulse
"$C54X/run.sh" || { say "DSP chain FAILED"; exit 1; }

# ── BTS + PCU, once the bridge listens on TRXC 5701 ──────────────────────────
for _ in $(seq 1 30); do
    ss -uanH 2>/dev/null | grep -q '127.0.0.1:5701 ' && break
    sleep 0.5
done
app osmo-bts-trx    osmo-bts-trx.cfg
app osmo-pcu        osmo-pcu.cfg
say "ready. LU: grep -c 'LOCATION UPDATING ACCEPT' /tmp/c54x-pont/mobile.log"
