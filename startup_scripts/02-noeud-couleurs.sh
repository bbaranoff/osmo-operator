# 02-noeud-couleurs.sh - part of start.sh (node identity, hub address, colors)
# Sourced by start.sh in the main shell: same order, same variables.
NODE_ID_SRC=""
if [ -n "$NODE_ID" ]; then
    NODE_ID_SRC="option --node"
else
    _detected="$(detect_node_id || true)"
    NODE_ID="${_detected%%|*}"
    [ -n "$NODE_ID" ] && NODE_ID_SRC="${_detected#*|}"
    unset _detected
fi
# The hub address arrives by the SAME path as the node: start-docker.sh sets
# it in the container environment (OSMO_HUB_IP, and INTER_STP_IP for older
# scripts). A container started by docker exec -d has no terminal, so the hub
# question is skipped; without this fallback HUB_IP would stay empty up to the
# configs. The fallback sits here, after the option loop, so that --hub-ip
# keeps the last word.
[ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-${INTER_STP_IP:-}}"
# ── LAST FALLBACK: THE ADDRESS THE ASP ALREADY DIALS ─────────────────────────
# Without HUB_IP, network/set-node-id.sh falls back to the default WAN hub,
# 192.168.1.49, computes the source that routes to it and writes it as the
# ASP local-ip. On a single-machine bench, however, the hub lives in a
# container and the ASP dials 127.0.0.1:2908 - the SCTP port the hub publishes
# on the loopback: the source computed for 192.168.1.49 does not lead to the
# hub and the ASP stays ASP_DOWN, with only a timeout in the log.
#
# The config KNOWS where the hub is - it is its remote-ip. It is read rather
# than guessed: source and destination then come from the same place, and
# `ip route get` returns the right local leg.
# --hub-ip and OSMO_HUB_IP keep priority; this fallback only covers silence.
if [ -z "$HUB_IP" ] && [ -r "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" ]; then
    HUB_IP="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{a=1; next}
                   a && /^[[:space:]]*remote-ip[[:space:]]/{print $2; exit}' \
              "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
    # A config never regenerated (fresh install: template copied as is) carries
    # the MARKER __INTER_STP_IP__, not an address; set-node-id.sh --hub-ip would
    # refuse it. Only an IPv4 counts.
    [[ "$HUB_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || HUB_IP=""
    [ -n "$HUB_IP" ] && echo "  hub        deduit du remote-ip de l ASP : $HUB_IP" >&2
fi
# For the scripts that only know two worlds: docker, or everything else.
case "$RUNTIME_ENV" in docker) NODE_MODE=docker ;; *) NODE_MODE=native ;; esac

# --- display (same as run.sh) -------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_Z=$'\033[0m'
else
    TTY=0
    C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_CYAN=""; C_BOLD=""; C_Z=""
fi
# ── KILL THE BENCH PYTHONS, AND ONLY THEM ───────────────────────────────────
# No killall: only the python3 OF THE BENCH are killed, named one by one by
# their command line:
#   - fake_trx.py and the rest of the osmocom-bb trx_toolkit (virtual radio);
#   - pont/pont.py (the TRX-UDP bridge), pont/airmesh.py, pont/air.py,
#     pont/pont_dsp.py and the VSP audio bridge (pont.vsp_audio);
#   - the inter-operator SMS relay (scripts/smsc-start.sh);
#   - tools/osmo-ril-atmodem.py (the phone's AT modem);
#   - the gdb gateways of the Calypso instances (gdb-telnet.py).
# Any other python3 (desktop, pmbootstrap, a build next door) is left alone.
# CALYPSO_PY_BANC_EXTRA='pattern|pattern' adds patterns (ERE regex) without
# touching the script.
PY_BANC='fake_trx\.py|trx_toolkit/|pont/pont\.py|pont/airmesh\.py|sms-interop|osmo-ril-atmodem\.py|pont/air\.py|pont/pont_dsp\.py|pont\.vsp_audio|gdb-telnet\.py'
[ -n "${CALYPSO_PY_BANC_EXTRA:-}" ] && PY_BANC="$PY_BANC|$CALYPSO_PY_BANC_EXTRA"
killall_python() {
    local sig="${1:--TERM}" pid tue=0
    for pid in $(pgrep -x python3 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Eq "$PY_BANC" || continue
        kill "$sig" "$pid" 2>/dev/null && tue=1
    done
    [ "$tue" = 1 ]
}

