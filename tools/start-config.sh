#!/bin/bash
# tools/start-config.sh - from the start .config (start.sh --configure) to start.sh
# =============================================================================
#   tools/start-config.sh --print [FILE]   the command line
#   tools/start-config.sh --args  [FILE]   NUL-separated: VAR=value... then --, then args
# FILE: default $START_CONFIG, else /etc/osmocom/start.config if writable,
# else <repo>/.start.config. Parsed, never sourced.
# Environment it sets for start.sh (read by startup_scripts/, run.sh, c54x_exe):
#   RUN_SKIP         run.sh modules left out (--skip)
#   FLOTTE_VIRTPHY / FLOTTE_FAKETRX   scripts/ms-flotte.sh
#   FIRMWARE_APP     an app alone on the ARM (c54x_exe/run.sh)
#   C123_WINDOW      tools/osmo-c123-gtk.py --modele <skin> once the bench is up
#   LORA_MODE, LORA_PTT
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
start_config_path() {
    if [ -n "${START_CONFIG:-}" ]; then echo "$START_CONFIG"
    elif [ -w /etc/osmocom ] || [ -f /etc/osmocom/start.config ]; then echo /etc/osmocom/start.config
    else echo "$REPO/.start.config"; fi
}
MODE="${1:---print}"; F="${2:-$(start_config_path)}"
[ "$MODE" = --path ] && { echo "$F"; exit 0; }
[ -r "$F" ] || { echo "start-config : $F absent (start.sh --configure)" >&2; exit 1; }

declare -A K
while IFS= read -r l || [ -n "$l" ]; do
    if [[ "$l" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
        k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        [[ "$v" =~ ^\"(.*)\"$ ]] && v="${BASH_REMATCH[1]}"; K[$k]="$v"
    fi
done <"$F"
y() { [ "${K[$1]:-n}" = y ]; }
v() { echo "${K[$1]:-}"; }
A=(); E=()

if y LAUNCH_DOCKER; then
    A+=(--docker)
    y WAN && { if y WAN_TABLE; then A+=(--wan-nodes "$(v WAN_NODES)"); else A+=(--wan); fi
               [ "$(v WAN_ID)" != 0 ] && [ -n "$(v WAN_ID)" ] && A+=(--wan-id "$(v WAN_ID)")
               [ -n "$(v WAN_CONF)" ] && A+=(--wan-conf "$(v WAN_CONF)"); }
    [ -n "$(v HUB_IP)" ] && A+=(--hub-ip "$(v HUB_IP)")
    [ "$(v VIRTUALBOX)" != 0 ] && [ -n "$(v VIRTUALBOX)" ] && A+=("--virtualbox=$(v VIRTUALBOX)" --vbox-node "$(v VBOX_NODE)")
    [ "$(v OPERATORS)" != 0 ] && [ -n "$(v OPERATORS)" ] && A+=(--operators "$(v OPERATORS)")
else
    # layer 1
    if y L1_GRGSM; then A+=(--grgsm); else A+=(--dsp); y DSP_MULTITHREADING || A+=(--no-multithreading); fi
    y ISOLATION || A+=(--no-isolation)
    y ICOUNT_AUTO && A+=(--icount)
    y ICOUNT_CUSTOM && A+=("--icount=$(v ICOUNT_SPEC)")
    y ASSEMBLY_LOGS && A+=(--assembly-logs)
    [ -n "$(v QOSMO_LAUNCHER)" ] && A+=("--launcher=$(v QOSMO_LAUNCHER)")
    # BTS#0 and the phone
    if y BTS_CALYPSO_TRX; then
        A+=(--bts)
        y TS_1 && A+=(--ts 1); y TS_2 && A+=(--ts 2); y TS_2_1 && A+=(--ts 2/1)
        if y MS_AIR; then y FW_MAGNETITE && A+=(--ms-magnetite) || A+=(--ms); fi
    elif y L1_DSP; then
        A+=(--bts-classic); y FW_MAGNETITE && A+=(--ms-magnetite)
    fi
    [ -n "$(v FIRMWARE_APP)" ] && E+=("FIRMWARE_APP=$(v FIRMWARE_APP)")
    y L2_CCCH_SCAN && A+=(--ccch_scan); y L2_BCCH_SCAN && A+=(--bcch_scan); y L2_CELL_LOG && A+=(--cell_log)
    y VOC_GAPK && A+=(--gapk); y VOC_ROM && A+=(--vocoder-rom)
    y SIM_TEST && A+=(--no-sap); y SIM_SAP_AUTO && A+=(--sap)
    y SIM_SAP_PCSC && A+=(--sap=pcsc); y SIM_SAP_SIM && A+=(--sap=sim)
    if y C123_WINDOW; then
        sk=auto; y C123_SKIN_C123 && sk=c123; y C123_SKIN_C139 && sk=c139; E+=("C123_WINDOW=$sk")
    fi
    # side-car, more MS
    y SIDECAR || y LORA || A+=(--no-sidecar)
    y MODEM_GPRS && A+=(--gprs-modem)
    [ "$(v FLOTTE_FAKETRX)" -gt 0 ] 2>/dev/null && E+=("FLOTTE_FAKETRX=$(v FLOTTE_FAKETRX)")
    [ "$(v FLOTTE_VIRTPHY)" -gt 0 ] 2>/dev/null && E+=("FLOTTE_VIRTPHY=$(v FLOTTE_VIRTPHY)")
    # run.sh modules left out (visible, i.e. written, and not set)
    skip=()
    while IFS= read -r l; do
        [[ "$l" =~ ^#\ CONFIG_RUN_MOD_([A-Z0-9_]+)\ is\ not\ set$ ]] || continue
        m="${BASH_REMATCH[1],,}"; skip+=("${m//_/-}")
    done <"$F"
    [ "${#skip[@]}" -gt 0 ] && E+=("RUN_SKIP=$(IFS=,; echo "${skip[*]}")")
    # voice, LoRa
    y HR && A+=(--hr)
    if y LORA; then
        A+=(--lora "$(y LORA_NODE_2 && echo 2 || echo 1)")
        [ -n "$(v LORA_PORT)" ] && A+=("--lora-port=$(v LORA_PORT)")
        y LORA_MODE_IP && E+=(LORA_MODE=ip)
        y LORA_PTT_AUTO && E+=(LORA_PTT=auto)
    fi
    # node, WAN
    [ "$(v NODE)" != 0 ] && [ -n "$(v NODE)" ] && A+=(--node "$(v NODE)")
    [ "$(v OP)" != 1 ] && [ -n "$(v OP)" ] && A+=(--op "$(v OP)")
    [ -n "$(v HUB_IP)" ] && A+=(--hub-ip "$(v HUB_IP)")
    y INTERSTP_FORCE && A+=(--interstp); y INTERSTP_NO && A+=(--no-interstp)
    if y WAN; then
        if y WAN_TABLE; then A+=(--wan-nodes "$(v WAN_NODES)")
        elif y WAN_FILES; then for f in $(v WAN_FILE_LIST); do A+=(--wan "$f"); done
        else A+=(--wan); fi
        [ "$(v WAN_ID)" != 0 ] && [ -n "$(v WAN_ID)" ] && A+=(--wan-id "$(v WAN_ID)")
        [ -n "$(v WAN_CONF)" ] && A+=(--wan-conf "$(v WAN_CONF)")
        y WAN_REGEN && A+=(--regen-conf)
        y ISM_SECTION && A+=(--payload-ism)
        for b in serial exec fifo loopback; do y "ISM_${b^^}" && A+=("--payload-ism=$b"); done
        if y AIR_MESH; then [ "$(v AIR_MESH_PORT)" != 0 ] && A+=("--air-mesh=$(v AIR_MESH_PORT)") || A+=(--air-mesh); fi
    fi
    [ "$(v VIRTUALBOX)" != 0 ] && [ -n "$(v VIRTUALBOX)" ] && A+=("--virtualbox=$(v VIRTUALBOX)" --vbox-node "$(v VBOX_NODE)")
    # misc
    y REGEN && A+=(--regen); y FORCE && A+=(--force); y VERBOSE && A+=(--verbose)
    y NO_ATTACH && A+=(--no-attach); y DRY_RUN && A+=(--dry-run)
fi

case "$MODE" in
    --print) s=""; [ "${#E[@]}" -gt 0 ] && s="$(printf '%q ' "${E[@]}")"
             printf '%s./start.sh' "$s"; for x in "${A[@]}"; do printf ' %q' "$x"; done; echo ;;
    --args)  printf '%s\0' "${E[@]}" -- "${A[@]}" ;;
    *) echo "usage : $0 --print|--args|--path [FILE]" >&2; exit 2 ;;
esac
