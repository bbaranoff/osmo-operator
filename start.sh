#!/bin/bash
# =============================================================================
# start.sh - Prepare l'environnement Calypso puis lance run.sh
# =============================================================================
#
# Ce script ne demarre aucun demon.
#
# Il :
#   1. charge l'environnement ;
#   2. detecte le materiel / les binaires ;
#   3. choisit le mode (profil) ;
#   4. genere les fichiers mobile_*.cfg ;
#   5. exporte les variables necessaires ;
#   6. execute run.sh.
#
# Toute la logique GSM vit ensuite dans run.sh (et run_modules/).
#
# CHAINE DE CONFIGURATION - NE PAS LA CASSER
#     VAR=x ./start-native.sh   ← la ligne de commande gagne toujours
#       -> environment/load.env
#          -> paths / modes / domaines
#     puis exec run.sh avec le profil choisi.
# -----------------------------------------------------------------------------
set -uo pipefail

# ── [2026-08-14] GARDE "on doit etre dans Docker" RETIREE ───────────────────
# Elle exigeait /.dockerenv ET /etc/docker-entrypoint-cmd, et sortait en exit 1
# quand l'un manquait. Sur l'ISO il n'y a pas de Docker : les deux fichiers sont
# absents, la garde bloquait donc le seul lanceur utilisable la-bas. Retiree sur
# demande explicite - c'est le cas d'usage ISO qui prime.
#
# CE QU'ON PERD, et c'etait sa raison d'etre (constat du 12/08) : lance par
# erreur sur un HOTE qui a Docker, ce script repart sur un environnement a
# moitie construit - /opt/GSM/qosmo n'y existe pas, mais /tmp/osmo-nitb/logs,
# lui, se cree tout seul - et meurt sur un "run.sh introuvable" qui ne designe
# pas la vraie cause. Si ce symptome reapparait sur une machine avec Docker,
# c'est ca : la-bas le lanceur est ./launch/start-docker.sh (ou ./launch/start-nitb.sh), pas celui-ci.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ── Le reste du lanceur : startup_scripts/*.sh, sourcees dans l'ordre (meme shell, memes variables) ──
for _f in "$HERE"/startup_scripts/*.sh; do
    . "$_f"
done
unset _f
