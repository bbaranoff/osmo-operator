#!/usr/bin/env bash
# =============================================================================
#  scripts/audio-chain.sh - closes the local audio chain once pulse is up
# =============================================================================
#  Three links of the audio chain are installed here, in order, idempotently:
#
#   1. /etc/asound.conf. Without it the ALSA PCMs `gsm_out` / `gsm_in` that
#      `mobile` opens do not exist, so the TCH voice never reaches gsm_audio.
#   2. the `gsm_mic` sink. configs/asound.conf points `pcm.gsm_in` at
#      `gsm_mic.monitor`: without this sink, gapk_io fails to open the capture
#      and gives up both directions (gapk_io.c) → call established, totally
#      silent.
#   3. the `module-loopback` gsm_audio.monitor → sound card. gsm_audio is a
#      null-sink: without a consumer the downlink voice is dropped by
#      construction (ALSA output SUSPENDED, pcm0p/sub0/status = "closed").
#
#  Usage: audio-chain.sh [timeout_s]   (default 30)
#  Disabled by AUDIO=0; the loopback alone by AUDIO_LOCAL_LOOPBACK=0.
#  Loopback latency: LOOPBACK_LATENCY_MSEC (default 20).
#  Always exit 0 - audio must never prevent the stack from coming up.
# -----------------------------------------------------------------------------
set -uo pipefail

# --reinit: unload the echo canceller, the loops and osmo_rec, then reinstall
# the chain (lib/audio.sh, reinit_audio). The remaining arguments are unchanged
# (PulseAudio wait delay, 30 s by default).
REINIT=0
if [ "${1:-}" = "--reinit" ]; then REINIT=1; shift; fi
# --appel debut|fin: the heavy chain (echo canceller, loops, osmo_rec) only
# during a call. Called by gapk-start.sh (auto mode) on « Endpoint actif » /
# « Endpoint disparu ». AUDIO_PENDANT_APPEL=0: the chain stays installed
# permanently.
APPEL=""
if [ "${1:-}" = "--appel" ]; then APPEL="${2:-}"; shift 2 2>/dev/null || shift; fi

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HERE
: "${PULSE_SOCK:=/var/run/pulse/native}"
export PULSE_SERVER="unix:${PULSE_SOCK}"

# shellcheck source=../lib/audio.sh
. "${HERE}/lib/audio.sh"

[ "${AUDIO:-1}" = "1" ] || { echo "[audio] desactive (AUDIO=0)"; exit 0; }

# ── 1. The ALSA mapping, before everything else ──────────────────────────────
# `mobile` opens gsm_out/gsm_in: if /etc/asound.conf is missing, it hits
# "Unknown PCM gsm_out" and nothing ever reaches gsm_audio.
if [ -f "${HERE}/configs/asound.conf" ] \
   && ! cmp -s "${HERE}/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
    if cp -f "${HERE}/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        echo "[audio] /etc/asound.conf deploye (PCM gsm_out/gsm_in)"
    else
        echo "[audio] /etc/asound.conf NON deploye (droits ?)" >&2
    fi
fi

# ── 2. Wait for the daemon ───────────────────────────────────────────────────
deadline="${1:-30}"
while [ "$deadline" -gt 0 ] && ! pactl info >/dev/null 2>&1; do
    sleep 1
    deadline=$(( deadline - 1 ))
done
if ! pactl info >/dev/null 2>&1; then
    echo "[audio] PulseAudio injoignable @ ${PULSE_SOCK} - chaine non fermee" >&2
    exit 0
fi

# ── 2 bis. Wait for a hardware output, not only the daemon ───────────────────
# On a freshly installed disk the daemon answers before the snd_hda_* modules
# have finished loading, so module-udev-detect has not yet declared any ALSA
# sink. module-udev-detect catches cards arriving later, but
# ensure_local_loopback runs only once: if it runs too early, the loopback is
# never installed. It therefore gets the same window as the daemon. Non-blocking
# beyond that: without any card (a bench without sound, a VM without audio
# device) we carry on - the null-sinks are enough for gapk_io, only the local
# listening is missing.
hw_deadline="${1:-30}"
while [ "$hw_deadline" -gt 0 ] \
      && ! pactl list short sinks 2>/dev/null | grep -q 'module-alsa-card'; do
    sleep 1
    hw_deadline=$(( hw_deadline - 1 ))
done

# ── 3. Both null-sinks, then the loopback ────────────────────────────────────
# load_gsm_sinks() loops over GSM_SINKS = gsm_audio + gsm_mic: this covers a
# system.pa that would declare only one of them.
[ "$REINIT" = 1 ] && reinit_audio
load_gsm_sinks
for s in gsm_audio gsm_mic; do
    if pactl list short sinks 2>/dev/null | grep -qw "$s"; then
        echo "[audio] sink $s present"
    else
        echo "[audio] sink $s MANQUANT - gapk_io va abandonner les deux sens" >&2
    fi
done

# The echo canceller first: the operator's speakers are osmo_hp_ec from boot,
# as with the VM (lib/audio.sh, speaker assignment). Without a VM the direct
# loopback follows; with one it is removed.
alleger_audio
if [ "${AUDIO_PENDANT_APPEL:-0}" = "1" ] && ! pmos_vm_audio_present; then
    case "$APPEL" in
    debut) ;;                                  # the chain is installed below
    fin)   reinit_audio; echo "[audio] fin d appel : chaine retiree"; exit 0 ;;
    *)     # at start / at boot: a fresh bench has no call in progress; the
           # first « Endpoint actif » of gapk-auto will install the chain.
           reinit_audio
           echo "[audio] chaine posee a la demande, au premier appel (AUDIO_PENDANT_APPEL=0 pour la garder)"
           exit 0 ;;
    esac
fi
ensure_echo_cancel
ensure_local_loopback
ensure_local_mic
ensure_record_mix
exit 0
