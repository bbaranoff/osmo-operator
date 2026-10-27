#!/bin/bash
# =============================================================================
# start.sh - native launcher: prepares the Calypso environment, then runs run.sh
# (start-native.sh is a symlink to this file)
# =============================================================================
#
# Usage:
#   ./start.sh [options]            native launcher (startup_scripts/*.sh)
#   ./start.sh --docker [options]   hands over to launch/start-docker.sh
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
_args=(); _docker=0
for _a in "$@"; do
    if [ "$_a" = --docker ]; then _docker=1; else _args+=("$_a"); fi
done
if [ "$_docker" = 1 ]; then
    exec bash "$HERE/launch/start-docker.sh" "${_args[@]+"${_args[@]}"}"
fi
unset _args _docker _a

# ── Native launcher: startup_scripts/*.sh, sourced in order (same shell, same variables) ──
for _f in "$HERE"/startup_scripts/*.sh; do
    . "$_f"
done
unset _f
