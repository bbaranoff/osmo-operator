#!/usr/bin/env bash
set -euo pipefail

SOURCE="gsm_audio.monitor"
ACTION="${1:-status}"
SINK="${2:-$(pactl get-default-sink)}"

find_loopback_ids() {
    pactl list short modules | \
        grep -F "module-loopback" | \
        grep -F "source=${SOURCE}" | \
        grep -F "sink=${SINK}" | \
        awk '{print $1}'
}

check_source() {
    pactl list short sources | grep -F "${SOURCE}" >/dev/null || {
        echo "[FAIL] source ${SOURCE} introuvable"
        exit 1
    }
}

enable_loopback() {
    check_source
    local ids
    ids="$(find_loopback_ids || true)"

    echo "[*] Source : $SOURCE"
    echo "[*] Sink   : $SINK"

    if [[ -n "${ids}" ]]; then
        echo "[OK] loopback deja present : ${ids}"
    else
        local mid
        mid="$(pactl load-module module-loopback source="${SOURCE}" sink="${SINK}" latency_msec=20)"
        echo "[OK] loopback charge, module id=${mid}"
    fi
}

disable_loopback() {
    local ids
    ids="$(find_loopback_ids || true)"

    echo "[*] Source : $SOURCE"
    echo "[*] Sink   : $SINK"

    if [[ -z "${ids}" ]]; then
        echo "[OK] aucun loopback a retirer"
        return 0
    fi

    while read -r id; do
        [[ -n "${id}" ]] || continue
        pactl unload-module "${id}"
        echo "[OK] loopback retire, module id=${id}"
    done <<< "${ids}"
}

status_loopback() {
    local ids
    ids="$(find_loopback_ids || true)"

    echo "[*] Source : $SOURCE"
    echo "[*] Sink   : $SINK"

    if [[ -n "${ids}" ]]; then
        echo "[OK] loopback actif : ${ids}"
    else
        echo "[INFO] aucun loopback actif"
    fi
}

case "${ACTION}" in
    enable)
        enable_loopback
        ;;
    disable)
        disable_loopback
        ;;
    status)
        status_loopback
        ;;
    *)
        echo "Usage: $0 {enable|disable|status} [sink]"
        exit 1
        ;;
esac
