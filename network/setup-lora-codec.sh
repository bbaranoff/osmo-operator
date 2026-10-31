#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-lora-codec.sh — profil voix : full-rate par défaut, half-rate
# avec start.sh --hr
#
#   --on   half-rate : BSC codec-support fr hr, canaux voix TCH/F -> TCH/H,
#          mobiles "codec half-speed prefer"  => GSM-HR 5,6 kbit/s
#          (osmo-msc garde default-codec tch-h hr : rien à y changer)
#          + jambe SIP par le transcodeur HR <-> FR (tools/osmo-hr-transcodeur.py,
#          127.0.0.1:5062) : osmo-sip-connector "remote ... 5062", Asterisk
#          [gsm_msc] contact=sip:127.0.0.1:5062. Asterisk ne connaît pas le
#          GSM-HR (488 Not Acceptable Here) ; start.sh --hr lance le transcodeur.
#   --off  full-rate : BSC codec-support fr, canaux voix TCH/F, mobiles
#          "codec full-speed prefer", jambe SIP directe 5061 <-> 5060 —
#          l'inverse exact
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
SIPC_CFGS=("$HERE/configs/osmo-sip-connector.cfg" "${OSMOCOM_CFG:-/etc/osmocom}/osmo-sip-connector.cfg")
PJSIP_CFGS=("$HERE/configs/pjsip.conf" "${ASTERISK_CFG:-/etc/asterisk}/pjsip.conf")

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
    for f in "${SIPC_CFGS[@]}"; do
        [ -f "$f" ] && sed -i 's/^\(  remote [^ ]*\) 5060$/\1 5062/' "$f"
    done
    for f in "${PJSIP_CFGS[@]}"; do
        [ -f "$f" ] && sed -i 's|^contact=sip:127\.0\.0\.1:5061$|contact=sip:127.0.0.1:5062|' "$f"
    done
    echo "[lora-codec] half-rate (GSM-HR) actif, jambe SIP par le transcodeur (:5062)"
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
    for f in "${SIPC_CFGS[@]}"; do
        [ -f "$f" ] && sed -i 's/^\(  remote [^ ]*\) 5062$/\1 5060/' "$f"
    done
    for f in "${PJSIP_CFGS[@]}"; do
        [ -f "$f" ] && sed -i 's|^contact=sip:127\.0\.0\.1:5062$|contact=sip:127.0.0.1:5061|' "$f"
    done
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
    for f in "${SIPC_CFGS[@]}" "${PJSIP_CFGS[@]}"; do
        [ -f "$f" ] || continue
        echo "── $f"
        grep -nE '^  remote |^contact=sip:127\.0\.0\.1:506' "$f"
    done
}

case "${1:-}" in
    --on|on)         on ;;
    --off|off)       off ;;
    --status|status) status ;;
    *) echo "Usage: $0 --on|--off|--status"; exit 2 ;;
esac
