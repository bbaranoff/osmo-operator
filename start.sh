#!/bin/bash
# =============================================================================
# start.sh - native launcher: prepares the Calypso environment, then runs run.sh
# (start-native.sh is a symlink to this file)
# =============================================================================
#
# Usage:
#   ./start.sh [options]            native launcher (startup_scripts/*.sh)
#   ./start.sh --docker [options]   hands over to launch/start-docker.sh
#   ./start.sh --lora 1|2 [options] payload LoRa + voix half-rate, nœud 1 ou 2
#                                   (sans numéro : déduit de l'adresse de tnc0)
#   VAR=x ./start.sh                environment overrides always win
#
# This script starts no daemon itself. It:
#   1. loads the environment (environment/load.env);
#   2. detects the hardware / binaries;
#   3. chooses the mode (profile);
#   4. generates the mobile_*.cfg files;
#   5. exports the required variables;
#   6. executes run.sh (RUN_SH, resolved in startup_scripts/05-run-sh.sh).
#
# All GSM logic then lives in run.sh (and run_modules/).
#
# Configuration chain (do not break it):
#     VAR=x ./start.sh              <- the command line always wins
#       -> environment/load.env
#          -> paths / modes / domains
#     then exec run.sh with the chosen profile.
#
# Known limitation: there is no "must run inside Docker" guard, because the ISO
# has no Docker. Run by mistake on a host with Docker, it dies with "run.sh not
# found": the launchers there are ./launch/start-docker.sh or
# ./launch/start-nitb.sh, not this one.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ── --docker: the bench in containers, through launch/start-docker.sh ────────
# `./start.sh --docker [args]` hands over to start-docker.sh with the other
# arguments untouched; the rest of this script (startup_scripts/) is the
# NATIVE launcher and is not read.
_args=(); _docker=0; _lora=0; _lora_node=""
while [ $# -gt 0 ]; do
    case "$1" in
        --docker) _docker=1 ;;
        --lora=*) _lora=1; _lora_node="${1#*=}" ;;
        --lora)   _lora=1                       # --lora [1|2]
                  case "${2:-}" in ""|-*) ;; *) _lora_node="$2"; shift ;; esac ;;
        *)        _args+=("$1") ;;
    esac
    shift
done
# startup_scripts/01-defauts-options.sh relit "$@" et refuse les options
# inconnues : on ne lui passe que ce qui ne nous est pas destiné.
set -- "${_args[@]+"${_args[@]}"}"

# ── --lora [1|2]: aiguilleur payload LoRa + voix half-rate ───────────────────
# Nœud 1 : local 10.99.0.1 / 10.200.0.1, pair .2 ; nœud 2 : l'inverse.
# Payload (RTP appel, relais SMS) -> tnc0 vers le pair LoRa, signalisation
# (SS7/SIP) -> wg0. Sans numéro, le nœud est déduit de l'adresse de tnc0.
# Sans --lora, on revient à l'ancienne config (full-rate, pas d'aiguilleur)
# si un --lora précédent l'a laissée.
_sudo=""; [ "$(id -u)" = 0 ] || _sudo="sudo"
if [ "$_lora" = 1 ]; then
    _tnc_ip="$(ip -4 -o addr show tnc0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    if [ -z "$_lora_node" ]; then
        case "$_tnc_ip" in 10.200.0.1) _lora_node=1 ;; 10.200.0.2) _lora_node=2 ;; esac
    fi
    case "$_lora_node" in
        1) _peer=2 ;;
        2) _peer=1 ;;
        *) echo "[start.sh] --lora : nœud inconnu '${_lora_node}' (tnc0=${_tnc_ip:-absente}) — utilise --lora 1 ou --lora 2" >&2
           exit 2 ;;
    esac
    if [ -n "$_tnc_ip" ] && [ "$_tnc_ip" != "10.200.0.$_lora_node" ]; then
        echo "[start.sh] attention : --lora $_lora_node mais tnc0 = $_tnc_ip (attendu 10.200.0.$_lora_node)" >&2
    fi
    echo "[start.sh] --lora $_lora_node : payload -> 10.200.0.$_peer (tnc0), signalisation -> 10.99.0.$_peer (wg0), voix half-rate"
    $_sudo env WAN_PEER="10.99.0.$_peer" LORA_PEER="10.200.0.$_peer" \
        bash "$HERE/network/setup-lora-payload.sh" up || echo "[start.sh] aiguilleur LoRa: echec (voir ci-dessus)"
    $_sudo bash "$HERE/network/setup-lora-codec.sh" --on || echo "[start.sh] codec half-rate: echec (voir ci-dessus)"
    unset _tnc_ip _peer
else
    if ip rule show 2>/dev/null | grep -q 'fwmark 0x10'; then
        $_sudo bash "$HERE/network/setup-lora-payload.sh" --off
    fi
    if grep -qs 'TCH/H$' "$HERE/configs/osmo-bsc.cfg" "${OSMOCOM_CFG:-/etc/osmocom}/osmo-bsc.cfg"; then
        $_sudo bash "$HERE/network/setup-lora-codec.sh" --off
    fi
fi
unset _sudo

if [ "$_docker" = 1 ]; then
    exec bash "$HERE/launch/start-docker.sh" "${_args[@]+"${_args[@]}"}"
fi
unset _args _docker _lora _lora_node

# ── Native launcher: startup_scripts/*.sh, sourced in order (same shell, same variables) ──
for _f in "$HERE"/startup_scripts/*.sh; do
    . "$_f"
done
unset _f
