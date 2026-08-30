#!/bin/bash
# pulse-gsm-setup.sh - Configure PulseAudio for osmo-gapk audio
#
# Chaine audio :
#   osmo-gapk → ALSA "gsm_out" → asound.conf(type pulse, device gsm_audio)
#              → PulseAudio null-sink "gsm_audio"
#              → gsm_audio.monitor → parec → WebSocket → navigateur
#
# Appele par run.sh avant le lancement d'OsmocomBB/gapk.
# Requiert : PULSE_SERVER defini + socket monte par start.sh

set -u

TAG="[pulse-gsm]"
TIMEOUT="${PULSE_TIMEOUT:-30}"
SINK_NAME="gsm_audio"
# [2026-08-08] Sink silencieux servant de MICRO aux mobiles. Sans lui, asound.conf
# fait retomber la capture sur la source par defaut (= gsm_audio.monitor), donc
# sur la sortie que les mobiles viennent d'ecrire : boucle audio fermee.
MIC_NAME="gsm_mic"
SINK_RATE=8000
SINK_CHANNELS=1
SINK_FORMAT="s16le"

log()  { echo "$TAG $*"; }
err()  { echo "$TAG ERROR: $*" >&2; }

# ── 1. Attente PulseAudio ────────────────────────────────────────────────────
wait_pulse() {
    local i=0
    while [ $i -lt "$TIMEOUT" ]; do
        if pactl info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

log "Attente connexion PulseAudio (${PULSE_SERVER:-non defini})..."

if ! wait_pulse; then
    err "PulseAudio injoignable apres ${TIMEOUT}s"
    err "Verifier que PULSE_SERVER est defini et le socket monte"
    exit 1
fi

log "PulseAudio connecte"

# ── 2. Creation du null-sink gsm_audio ───────────────────────────────────────
if pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
    log "Sink ${SINK_NAME} deja present"
else
    if pactl load-module module-null-sink \
        sink_name="$SINK_NAME" \
        format="$SINK_FORMAT" \
        rate="$SINK_RATE" \
        channels="$SINK_CHANNELS" \
        sink_properties=device.description=GSM_Audio >/dev/null 2>&1; then
        log "Sink ${SINK_NAME} cree (${SINK_FORMAT}/${SINK_RATE}Hz/${SINK_CHANNELS}ch)"
    else
        err "Echec creation sink ${SINK_NAME}"
        exit 1
    fi
fi

# ── 2bis. Sink silencieux "gsm_mic" (micro des mobiles, cf. asound.conf) ─────
if pactl list short sinks 2>/dev/null | grep -q "$MIC_NAME"; then
    log "Sink ${MIC_NAME} deja present"
else
    pactl load-module module-null-sink sink_name="$MIC_NAME" \
        format="$SINK_FORMAT" rate="$SINK_RATE" channels="$SINK_CHANNELS" \
        sink_properties=device.description=GSM_Mic >/dev/null \
        && log "Sink ${MIC_NAME} cree (micro silencieux)" \
        || err "Echec creation sink ${MIC_NAME}"
fi

# ── 3. Verification monitor ──────────────────────────────────────────────────
if pactl list short sources 2>/dev/null | grep -q "${SINK_NAME}.monitor"; then
    log "Source ${SINK_NAME}.monitor disponible"
else
    err "Source ${SINK_NAME}.monitor introuvable"
    exit 1
fi

# ── 4. Empecher la suspension automatique ────────────────────────────────────
# PulseAudio suspend les sinks inactifs → osmo-gapk ecrit dans le vide
# et il faut toggle les haut-parleurs sur l'hote pour reveiller le flux

pactl suspend-sink "$SINK_NAME" 0 2>/dev/null || true
pactl suspend-source "${SINK_NAME}.monitor" 0 2>/dev/null || true

# Desactiver module-suspend-on-idle s'il est charge
SUSPEND_IDX=$(pactl list short modules 2>/dev/null | awk '/module-suspend-on-idle/ {print $1; exit}')
if [ -n "$SUSPEND_IDX" ]; then
    pactl unload-module "$SUSPEND_IDX" 2>/dev/null && \
        log "module-suspend-on-idle desactive" || true
fi

log "Sink ${SINK_NAME} force actif (pas de suspend)"

log "Configuration audio prete"
# NOTE : pas de loopback gsm_audio → haut-parleurs.
# Ecoute via parec → WebSocket → navigateur uniquement.
# Sink maintenu actif par suspend-sink 0 + suppression module-suspend-on-idle (etape 4).
