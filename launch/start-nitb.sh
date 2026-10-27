#!/bin/bash
# start-nitb.sh - same launcher as start-docker.sh, but using the osmocom-nitb image.
#
# A thin wrapper rather than a copy: only the image differs (IMAGE_RUN),
# so start-docker.sh stays the single implementation.
#
# Constraint: the two images have different entrypoints:
#     osmocom-run  -> /scripts/entrypoint.sh
#     osmocom-nitb -> /etc/osmocom/entrypoint.sh
# start-docker.sh mounts the generated config directory ON /etc/osmocom,
# hiding the nitb image's entrypoint. This works only because the generated
# directory contains entrypoint.sh (copied from scripts/entrypoint.sh); the
# check below verifies it on every launch.
#
# Usage: same as start-docker.sh; all arguments are passed through.
#   ./launch/start-nitb.sh [start-docker.sh args...]
#
# Environment: IMAGE_NITB  image to run (default osmocom-nitb).
#
# To go back to the run image, call ./launch/start-docker.sh directly.

set -eu

# Repository root (this script lives in launch/).
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
IMAGE_NITB="${IMAGE_NITB:-osmocom-nitb}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── 1. The image must EXIST: it is not built here ──────────────────────────
# start-docker.sh's check_image() builds a missing IMAGE_RUN with
# `docker build -f Dockerfile.run -t "$IMAGE_RUN" .`, which with
# IMAGE_RUN=osmocom-nitb would OVERWRITE osmocom-nitb. Check first.
if ! docker image inspect "$IMAGE_NITB" >/dev/null 2>&1; then
    echo -e "${RED}Image '${IMAGE_NITB}' introuvable.${NC}"
    echo -e "Ce script ne la construit pas volontairement : le build integre de"
    echo -e "start-docker.sh utilise ${YELLOW}Dockerfile.run${NC} et ecraserait l'image nitb."
    echo -e "Construire d'abord, depuis ${CYAN}${HERE}${NC} :"
    echo -e "  ${CYAN}docker build -f Dockerfile --target osmocom-nitb -t ${IMAGE_NITB} .${NC}"
    exit 1
fi

# ── 2. The entrypoint must survive the /etc/osmocom mount ─────────────────
# Test PRESENCE, not the exec bit: the file is 644 in the repository; +x is
# set downstream by generate_configs.sh (in the generated, mounted directory)
# and by Dockerfile.run (`chmod +x /scripts/*.sh` in the image).
if [ ! -s "${HERE}/scripts/entrypoint.sh" ]; then
    echo -e "${RED}scripts/entrypoint.sh absent ou vide.${NC}"
    echo -e "L'image ${IMAGE_NITB} a son entrypoint dans /etc/osmocom, que start-docker.sh"
    echo -e "recouvre par le dossier de config genere. Sans ce fichier, le"
    echo -e "conteneur demarrerait sans entrypoint - alors que l'image"
    echo -e "osmocom-run, elle, continuerait de marcher (son entrypoint est dans"
    echo -e "/scripts). Panne asymetrique et illisible : on refuse avant."
    exit 1
fi

echo -e "${GREEN}Lanceur nitb${NC} : image = ${CYAN}${IMAGE_NITB}${NC} (au lieu d'osmocom-run)"
echo -e "  entrypoint attendu dans le conteneur : /etc/osmocom/entrypoint.sh (monte)"

# ── 3. Delegation ───────────────────────────────────────────────────────────
# start-docker.sh reads IMAGE_RUN with the `:=` idiom: the value set here wins.
export IMAGE_RUN="$IMAGE_NITB"
cd "$HERE"
exec ./launch/start-docker.sh "$@"
