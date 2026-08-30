#!/usr/bin/env bash
# =============================================================================
#  scripts/audio-chain.sh - ferme la chaine audio locale, une fois pulse debout
# =============================================================================
#  [2026-08-14] POURQUOI CE SCRIPT EXISTE.
#  Trois maillons de la chaine audio n'etaient poses par AUCUN chemin execute :
#
#   1. /etc/asound.conf - absent de la VM au boot. Sans lui les PCM ALSA
#      `gsm_out` / `gsm_in` que `mobile` ouvre n'existent pas, donc la voix TCH
#      n'atteint jamais gsm_audio. Il est bien deploye par ensure_pulse() de
#      lib/audio.sh... mais lib/audio.sh n'est source par PERSONNE (son appelant
#      annonce, run_modules/25-audio.sh, n'existe pas).
#   2. le sink `gsm_mic` - build-iso.sh n'ecrivait que `gsm_audio` dans
#      system.pa. Or configs/asound.conf fait pointer `pcm.gsm_in` sur
#      `gsm_mic.monitor` : sans ce sink, gapk_io echoue a ouvrir la capture et
#      ABANDONNE LES DEUX SENS (gapk_io.c:468) → appel etabli, TOTALEMENT muet.
#   3. le `module-loopback` gsm_audio.monitor → carte. gsm_audio est un
#      null-sink : sans consommateur la voix descendante est jetee par
#      construction (sortie ALSA SUSPENDED, pcm0p/sub0/status = "closed").
#
#  Ce script pose les trois, dans l'ordre, de facon idempotente.
#
#  Usage : audio-chain.sh [timeout_s]   (defaut 30)
#  Neutralise par AUDIO=0 ; le seul loopback l'est par AUDIO_LOCAL_LOOPBACK=0.
#  Latence du loopback : LOOPBACK_LATENCY_MSEC (defaut 20).
#  Toujours exit 0 - l'audio ne doit jamais empecher la pile de monter.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HERE
: "${PULSE_SOCK:=/var/run/pulse/native}"
export PULSE_SERVER="unix:${PULSE_SOCK}"

# shellcheck source=../lib/audio.sh
. "${HERE}/lib/audio.sh"

[ "${AUDIO:-1}" = "1" ] || { echo "[audio] desactive (AUDIO=0)"; exit 0; }

# ── 1. Le mapping ALSA, AVANT tout le reste ──────────────────────────────────
# `mobile` ouvre gsm_out/gsm_in : si /etc/asound.conf manque, il tombe sur
# "Unknown PCM gsm_out" et rien ne remonte jamais dans gsm_audio.
if [ -f "${HERE}/configs/asound.conf" ] \
   && ! cmp -s "${HERE}/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
    if cp -f "${HERE}/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        echo "[audio] /etc/asound.conf deploye (PCM gsm_out/gsm_in)"
    else
        echo "[audio] /etc/asound.conf NON deploye (droits ?)" >&2
    fi
fi

# ── 2. Attendre le demon ─────────────────────────────────────────────────────
deadline="${1:-30}"
while [ "$deadline" -gt 0 ] && ! pactl info >/dev/null 2>&1; do
    sleep 1
    deadline=$(( deadline - 1 ))
done
if ! pactl info >/dev/null 2>&1; then
    echo "[audio] PulseAudio injoignable @ ${PULSE_SOCK} - chaine non fermee" >&2
    exit 0
fi

# ── 3. Les DEUX null-sinks, puis le loopback ─────────────────────────────────
# load_gsm_sinks() boucle sur GSM_SINKS = gsm_audio + gsm_mic : c'est ce qui
# rattrape un system.pa qui n'en declarerait qu'un.
load_gsm_sinks
for s in gsm_audio gsm_mic; do
    if pactl list short sinks 2>/dev/null | grep -qw "$s"; then
        echo "[audio] sink $s present"
    else
        echo "[audio] sink $s MANQUANT - gapk_io va abandonner les deux sens" >&2
    fi
done

ensure_local_loopback
exit 0
