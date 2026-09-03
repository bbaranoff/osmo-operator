#!/bin/bash
# tools/make-docker-image.sh - construit l image docker osmocom-nitb.
#
# [2026-09-03] Ce script etait une copie de build.sh, moins toast et --lite,
# et les deux divergeaient. Il delegue desormais a build.sh : apt-fast,
# docker compose v2 + buildx dans les dependances, cache .deb sur l hote
# (/var/cache/osmo-debs). Tous les arguments sont transmis tels quels.
#
#   sudo ./tools/make-docker-image.sh [--no-cache] [--lite] [--stp]
set -euo pipefail
exec bash "$(dirname "$(readlink -f "$0")")/../build.sh" "$@"
