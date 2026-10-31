#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-lora-codec.sh — profil voix half-rate pour le mode --lora
#
#   --on   half-rate : BSC codec-support fr hr, canaux voix TCH/F -> TCH/H,
#          mobile "codec half-speed prefer"  => GSM-HR 5,6 kbit/s
#          (osmo-msc garde default-codec tch-h hr : rien à y changer)
#   --off  ancienne config (full-rate) : l'inverse exact
#   --status
#
# Patche les gabarits (configs/) ET les configs installées (/etc/osmocom), pour
# que le mode soit le même avec ou sans --regen. Idempotent dans les deux sens.
# Appelé par start.sh : --lora => --on ; sans --lora => --off.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRS=("$HERE/configs" "${OSMOCOM_CFG:-/etc/osmocom}")

on(){
    local d
    for d in "${DIRS[@]}"; do
        [ -f "$d/osmo-bsc.cfg" ] && sed -i \
            -e 's/^\(  codec-support fr\)$/\1 hr/' \
            -e 's#^\(    phys_chan_config \)TCH/F$#\1TCH/H#' "$d/osmo-bsc.cfg"
        [ -f "$d/mobile.cfg" ] && sed -i \
            -e 's/^ codec full-speed prefer$/ codec half-speed prefer/' \
            -e 's/^ codec half-speed$/ codec full-speed/' "$d/mobile.cfg"
    done
    echo "[lora-codec] half-rate (GSM-HR) actif"
}

off(){
    local d
    for d in "${DIRS[@]}"; do
        [ -f "$d/osmo-bsc.cfg" ] && sed -i \
            -e 's/^\(  codec-support fr\) hr$/\1/' \
            -e 's#^\(    phys_chan_config \)TCH/H$#\1TCH/F#' "$d/osmo-bsc.cfg"
        [ -f "$d/mobile.cfg" ] && sed -i \
            -e 's/^ codec half-speed prefer$/ codec full-speed prefer/' \
            -e 's/^ codec full-speed$/ codec half-speed/' "$d/mobile.cfg"
    done
    echo "[lora-codec] ancienne config (full-rate)"
}

status(){
    local d
    for d in "${DIRS[@]}"; do
        echo "── $d"
        grep -nE 'codec-support|phys_chan_config TCH' "$d/osmo-bsc.cfg" 2>/dev/null
        grep -nE '^ codec (full|half)-speed' "$d/mobile.cfg" 2>/dev/null
    done
}

case "${1:-}" in
    --on|on)         on ;;
    --off|off)       off ;;
    --status|status) status ;;
    *) echo "Usage: $0 --on|--off|--status"; exit 2 ;;
esac
