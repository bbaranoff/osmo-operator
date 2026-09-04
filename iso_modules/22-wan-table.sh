#!/bin/bash
# iso_modules/22-wan-table.sh - table WAN, cleanup/trap, outils requis, WORK
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── La table WAN : arretee ICI, pas au milieu de la construction ────────────
# --role=interstp implique le WAN (le hub doit savoir combien de noeuds il
# dessert). L'etape 7b la demandait alors interactivement, une heure apres le
# lancement : de quoi bloquer une construction que l'on croyait autonome, et
# faire echouer la CI, qui n'a pas de terminal pour repondre.
#
# On la fige donc maintenant, avec la table du banc pour defaut. --wan-nodes
# reste prioritaire et n'est pas touche.
# [2026-09-04] AUTOMATIQUE. La question etait posee a chaque passe fille (quatre
# fois pour --all), au milieu d une construction d une heure, pour une reponse
# qui est presque toujours le defaut. La table du banc et le hub s appliquent
# donc sans rien demander ; pour autre chose, --wan-nodes="..." et --hub-ip=...
# (ou OSMO_ISO_WAN_ASK=1 pour retrouver la question, avec un terminal).
if [ "$ISO_WAN" = "1" ] && [ -z "$ISO_WAN_NODES" ]; then
    if [ "${OSMO_ISO_WAN_ASK:-0}" = "1" ] && [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}== Table WAN de l'image ==${NC}"
        echo -e "  Format : ${CYAN}<noeud>:<IP>:<indicatif>${NC}, separes par des espaces."
        echo -e "  Entree vide = le banc : ${CYAN}${ISO_WAN_NODES_DEFAULT}${NC}"
        read -rp "  Noeuds : " _wan_in || _wan_in=""
        ISO_WAN_NODES="${_wan_in:-$ISO_WAN_NODES_DEFAULT}"
        if [ "$ISO_ROLE" = "interstp" ]; then
            read -rp "  IP du hub [${ISO_HUB_IP}] : " _hub_in || _hub_in=""
            ISO_HUB_IP="${_hub_in:-$ISO_HUB_IP}"
        fi
    else
        ISO_WAN_NODES="$ISO_WAN_NODES_DEFAULT"
    fi
    echo -e "  ${GREEN}✓${NC} WAN : ${CYAN}${ISO_WAN_NODES}${NC}   hub ${CYAN}${ISO_HUB_IP}${NC}  (defaut du banc ; --wan-nodes= / --hub-ip= pour changer)"
fi

# Propage --no-cache aux deux builds Docker : build.sh (image osmocom-nitb) et
# build_run_image (image osmocom-run, via DOCKER_NO_CACHE).
export DOCKER_NO_CACHE="$NO_CACHE"


cleanup() { umount "$ROOTFS/var/cache/apt/archives" 2>/dev/null||true; umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT


# Paquets hote : une fois (voir iso_host_packages, plus haut).
iso_host_packages

# Docker n'est pas auto-installe ici (paquet docker-ce hors apt standard).
_ISO_TOOLS="docker mksquashfs xorriso grub-mkrescue debootstrap git"
[ "${ISO_ARCH:-amd64}" = "arm64" ] && _ISO_TOOLS="docker debootstrap git qemu-aarch64-static mke2fs mkfs.vfat mcopy sfdisk truncate"
for t in $_ISO_TOOLS; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
iso_arm_binfmt
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo-operator ISO builder (via build.sh + start.sh) ══${NC}"


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
