#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-lora-codec.sh — profil voix : full-rate par défaut, half-rate
# avec start.sh --hr
#
#   --on   half-rate : BSC codec-support fr hr, canaux voix TCH/F -> TCH/H,
#          mobiles "codec half-speed prefer"  => GSM-HR 5,6 kbit/s
#          (osmo-msc garde default-codec tch-h hr : rien à y changer)
#   --off  full-rate : BSC codec-support fr, canaux voix TCH/F, mobiles
#          "codec full-speed prefer" — l'inverse exact
#   --status
#
# Patche, pour que le mode soit le même avec ou sans --regen :
#   - osmo-bsc.cfg : gabarit (configs/) ET installé (/etc/osmocom) ;
#   - les mobiles : gabarits (configs/, forks qosmo et c54x_exe) ET les cfg
#     installés que lisent réellement les mobiles (~/.osmocom/bb/*.cfg).
# Un fichier absent est ignoré. Idempotent dans les deux sens.
# Appelé par start.sh : --hr => --on ; sans --hr => --off (full-rate par défaut).
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GSM_ROOT="$(dirname "$HERE")"
DIRS=("$HERE/configs" "${OSMOCOM_CFG:-/etc/osmocom}")
BB_DIR="${MOBILE_BB_DIR:-/root/.osmocom/bb}"

# Toutes les configs de mobile qui portent une ligne " codec ...-speed".
mobile_cfgs(){
    local d f
    for d in "${DIRS[@]}"; do echo "$d/mobile.cfg"; done
    echo "${QEMU_TREE:-$GSM_ROOT/qosmo}/cfgs/mobile_group1.cfg"
    echo "$GSM_ROOT/c54x_exe/mobile_pont.cfg"
    for f in "$BB_DIR"/mobile*.cfg; do echo "$f"; done
}

on(){
    local d f
    for d in "${DIRS[@]}"; do
        [ -f "$d/osmo-bsc.cfg" ] && sed -i \
            -e 's/^\(  codec-support fr\)$/\1 hr/' \
            -e 's#^\(    phys_chan_config \)TCH/F$#\1TCH/H#' "$d/osmo-bsc.cfg"
    done
    while read -r f; do
        [ -f "$f" ] && sed -i \
            -e 's/^ codec full-speed prefer$/ codec half-speed prefer/' \
            -e 's/^ codec half-speed$/ codec full-speed/' "$f"
    done < <(mobile_cfgs)
    echo "[lora-codec] half-rate (GSM-HR) actif"
}

off(){
    local d f
    for d in "${DIRS[@]}"; do
        [ -f "$d/osmo-bsc.cfg" ] && sed -i \
            -e 's/^\(  codec-support fr\) hr$/\1/' \
            -e 's#^\(    phys_chan_config \)TCH/H$#\1TCH/F#' "$d/osmo-bsc.cfg"
    done
    while read -r f; do
        [ -f "$f" ] && sed -i \
            -e 's/^ codec half-speed prefer$/ codec full-speed prefer/' \
            -e 's/^ codec full-speed$/ codec half-speed/' "$f"
    done < <(mobile_cfgs)
    echo "[lora-codec] full-rate (défaut)"
}

status(){
    local d f
    for d in "${DIRS[@]}"; do
        [ -f "$d/osmo-bsc.cfg" ] || continue
        echo "── $d/osmo-bsc.cfg"
        grep -nE 'codec-support|phys_chan_config TCH' "$d/osmo-bsc.cfg"
    done
    while read -r f; do
        [ -f "$f" ] || continue
        echo "── $f"
        grep -nE '^ codec (full|half)-speed' "$f"
    done < <(mobile_cfgs)
}

case "${1:-}" in
    --on|on)         on ;;
    --off|off)       off ;;
    --status|status) status ;;
    *) echo "Usage: $0 --on|--off|--status"; exit 2 ;;
esac
