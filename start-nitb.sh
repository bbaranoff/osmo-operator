#!/bin/bash
# start-nitb.sh - meme lanceur que start.sh, mais sur l'image osmocom-nitb.
#
# POURQUOI UN WRAPPER ET PAS UNE COPIE. start.sh fait 1 300 lignes (reseaux,
# generation de configs, SS7 inter-operateurs, ports, audio). Le dupliquer
# creerait une 2e copie qui divergerait - le depot en a deja paye le prix
# ailleurs (4 copies de si_bridge.py, 3 de gapk-start.sh, toutes divergentes).
# Ici il n'y a qu'UNE variable qui change : l'image.
#
# CE QUI A ETE VERIFIE AVANT D'ECRIRE CE SCRIPT (12/08/2026) :
#   - les deux images n'ont PAS le meme entrypoint :
#       osmocom-run  -> /scripts/entrypoint.sh
#       osmocom-nitb -> /etc/osmocom/entrypoint.sh
#   - start.sh monte le dossier de config genere SUR /etc/osmocom, donc il
#     MASQUE l'entrypoint de l'image nitb. Ce n'est pas un probleme : le
#     dossier genere contient bien un entrypoint.sh (copie de scripts/
#     entrypoint.sh, le meme fichier que /scripts/entrypoint.sh dans l'image
#     run - 1988 o, identique). C'est la condition qui rend ce wrapper viable :
#     SI scripts/entrypoint.sh disparaissait du dossier genere, l'image nitb
#     demarrerait sans entrypoint alors que l'image run continuerait de
#     marcher. Le controle ci-dessous le verifie a chaque lancement.
#
# USAGE : identique a start.sh, tous les arguments sont transmis tels quels.
#   ./start-nitb.sh [args de start.sh...]
#
# REVENIR A L'IMAGE RUN : lancer ./start.sh directement.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NITB="${IMAGE_NITB:-osmocom-nitb}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── 1. L'image doit EXISTER : on ne la construit pas ici ──────────────────────
# start.sh a un check_image() qui, si l'image nommee par IMAGE_RUN est absente,
# lance build_run_image() -> `docker build -f Dockerfile.run -t "$IMAGE_RUN" .`.
# Avec IMAGE_RUN=osmocom-nitb, cela ECRASERAIT osmocom-nitb par une image
# construite depuis Dockerfile.run. On barre la route en verifiant d'abord.
if ! docker image inspect "$IMAGE_NITB" >/dev/null 2>&1; then
    echo -e "${RED}Image '${IMAGE_NITB}' introuvable.${NC}"
    echo -e "Ce script ne la construit pas volontairement : le build integre de"
    echo -e "start.sh utilise ${YELLOW}Dockerfile.run${NC} et ecraserait l'image nitb."
    echo -e "Construire d'abord, depuis ${CYAN}${HERE}${NC} :"
    echo -e "  ${CYAN}docker build -f Dockerfile -t ${IMAGE_NITB} .${NC}"
    exit 1
fi

# ── 2. L'entrypoint doit survivre au montage de /etc/osmocom ──────────────────
# On teste la PRESENCE, pas le bit d'execution : dans le depot le fichier est en
# 644, et c'est normal. Le bit +x est pose EN AVAL, aux deux endroits qui en ont
# besoin - generate_configs.sh l.204-205 (`cp scripts/*` puis `chmod +x` dans le
# dossier genere, celui qui est monte sur /etc/osmocom) et Dockerfile.run l.75
# (`chmod +x /scripts/*.sh` dans l'image). Tester `-x` ici refusait donc de
# demarrer sur un depot parfaitement sain.
if [ ! -s "${HERE}/scripts/entrypoint.sh" ]; then
    echo -e "${RED}scripts/entrypoint.sh absent ou vide.${NC}"
    echo -e "L'image ${IMAGE_NITB} a son entrypoint dans /etc/osmocom, que start.sh"
    echo -e "recouvre par le dossier de config genere. Sans ce fichier, le"
    echo -e "conteneur demarrerait sans entrypoint - alors que l'image"
    echo -e "osmocom-run, elle, continuerait de marcher (son entrypoint est dans"
    echo -e "/scripts). Panne asymetrique et illisible : on refuse avant."
    exit 1
fi

echo -e "${GREEN}Lanceur nitb${NC} : image = ${CYAN}${IMAGE_NITB}${NC} (au lieu d'osmocom-run)"
echo -e "  entrypoint attendu dans le conteneur : /etc/osmocom/entrypoint.sh (monte)"

# ── 3. Delegation ─────────────────────────────────────────────────────────────
# start.sh lit IMAGE_RUN avec l'idiome `:=` : la valeur posee ici gagne.
export IMAGE_RUN="$IMAGE_NITB"
cd "$HERE"
exec ./start.sh "$@"
