#!/bin/bash
# build-iso.sh - Genere une ISO bootable en utilisant build.sh et start.sh
# Aucun docker build direct dans ce script, tout passe par les scripts existants.
#
#  Usage : sudo ./build-iso.sh [options]
#    (sans option)        les quatre images amd64 : interstp, operator, lite, desktop
#    --role=operator|interstp   --node=N   --lite   --desktop   --all
#    --arm                image SD arm64 pour Raspberry Pi 4, base Armbian 24.04
#                         (osmo-operator-<...>-rpi4.img) ; --lite accepte,
#                         --desktop et --all refuses. Voir iso_modules/00-options.sh.
#    --banc --multi       active osmo-banc.service / osmo-multi.service au boot
#                         de l'image. Par defaut les deux unites sont POSEES mais
#                         NON activees : la machine demarre sur son bureau, et
#                         c'est l'operateur qui lance son banc (icone, launch.sh,
#                         systemctl start osmo-banc). Equivalents en variables :
#                         OSMO_ISO_BANC=1 / OSMO_ISO_MULTI=1.
#    --version=24.04|22.04   --kb=fr   --output=fichier   --no-cache
#    --skip-build[=image:tag]   pas de build : pull bastienbaranoff/norf_gsm:latest
#                         depuis Docker Hub, tague osmocom-nitb:latest, et continue
#    --wan --wan-nodes=... --wan-id=N --wan-ops=N --hub-ip=IP
set -euo pipefail

# Couleurs definies AVANT tout : sous `set -u`, la premiere ligne coloree d'un
# script qui les declare plus bas echoue sur "variable sans liaison" - et le
# message ne parle ni de couleurs ni de l'endroit fautif.
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

VERSION="${OSMO_ISO_VERSION:-main}"
OUTPUT="osmo-operator-${VERSION}.iso"
# Repertoire de travail SUR DISQUE (pas /tmp, souvent un tmpfs en RAM -> "No
# space left on device" car le rootfs est volumineux). Overridable via OSMO_ISO_WORK.
WORK="${OSMO_ISO_WORK:-/var/tmp}/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS_V2"
DIR="$(cd "$(dirname "$0")" && pwd)"
# /usr/local/sbin DANS le PATH : apt-fast-install pose apt-fast la, sur l hote
# comme dans le rootfs. Le chroot plus bas herite de ce PATH (env ... bash -c) :
# sans lui, "[apt-fast] pret : /usr/local/sbin/apt-fast" etait suivi de
# "bash: line 202: apt-fast: command not found" dans le chroot.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"


# ── LES ETAPES SONT DANS iso_modules/ ────────────────────────────────────────
# [2026-09-04] Ce script faisait 5 100 lignes d un seul tenant. Chaque etape
# vit maintenant dans iso_modules/NN-<slug>.sh, source ICI, dans l ordre des
# numeros, dans CE shell : les variables, les fonctions et le trap restent
# globaux, exactement comme avant le decoupage. Un module qui n a rien a
# faire (une variante, une architecture) fait `return` en tete.
# ATTENTION : `. fichier` rend le statut de la derniere commande du fichier,
# et set -e est actif. Chaque module se termine donc par `true` - sans quoi
# un module finissant par un test faux ("[ ... ] && { ... }", le test root de
# 00-options quand on EST root) arretait le script en silence, statut 1.
MODDIR="$DIR/iso_modules"
[ -d "$MODDIR" ] || { echo -e "${RED}iso_modules/ introuvable a cote de $0${NC}" >&2; exit 2; }
shopt -s nullglob; _ISO_MODS=("$MODDIR"/[0-9][0-9]-*.sh); shopt -u nullglob
[ "${#_ISO_MODS[@]}" -gt 0 ] || { echo -e "${RED}iso_modules/ est vide${NC}" >&2; exit 2; }
for _m in "${_ISO_MODS[@]}"; do . "$_m"; done
