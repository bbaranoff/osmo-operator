#!/bin/bash
# tools/make-docker-image.sh - build the osmocom-nitb docker image.
#
# Delegates to build.sh: apt-fast, docker compose v2 + buildx among the
# dependencies, .deb cache on the host (/var/cache/osmo-debs). All arguments
# are passed through unchanged.
#
#   sudo ./tools/make-docker-image.sh [--no-cache] [--lite] [--stp]
set -euo pipefail
exec bash "$(dirname "$(readlink -f "$0")")/../build.sh" "$@"
