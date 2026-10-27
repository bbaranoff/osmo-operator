#!/bin/bash
# =============================================================================
#  osmo-drivers - the NVIDIA graphics driver: status, installation, update
# =============================================================================
#  The counterpart, on the running system (live or installed), of the
#  "Graphics drivers" page of the installer: shows the card, the loaded module
#  and what is installed, and lets you install or update.
#
#  THE BENCH DRIVER IS FIXED: nvidia-driver-610, a named package:
#      sudo apt install nvidia-driver-610
#  ubuntu-drivers does not decide anything; it is only used, if present, to
#  inform (the list and the "recommended" shown by --status).
#  OSMO_NVIDIA_DRIVER selects another package.
#
#      sudo ./tools/osmo-drivers.sh            whiptail menu
#      sudo ./tools/osmo-drivers.sh --status   status only, as text
#      sudo ./tools/osmo-drivers.sh --install [driver]   (default: nvidia-driver-610)
#      sudo ./tools/osmo-drivers.sh --update
# =============================================================================
set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || exec pkexec --disable-internal-agent "$0" "$@" 2>/dev/null || exec sudo "$0" "$@"

need() { command -v "$1" >/dev/null 2>&1; }
# NVDRV: the driver this script installs. A package name, not a lookup.
NVDRV="${OSMO_NVIDIA_DRIVER:-nvidia-driver-610}"
# ubuntu-drivers is not a dependency: it is not installed for its own sake.
# If it is already there, --status uses it to show Ubuntu's "recommended" -
# for information, next to the driver the bench actually installs.

gpu()        { lspci -d 10de: 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ //; s/ (rev.*//'; }
reco()       { ubuntu-drivers devices 2>/dev/null | awk '/^driver *:/ && /recommended/{print $3; exit}'; }
avail()      { { echo "$NVDRV"; ubuntu-drivers list 2>/dev/null | awk '/^nvidia-driver-/{print $1}' | sed 's/,.*//'; } | sort -u; }
installed()  { dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}'; }
loaded()     { lsmod 2>/dev/null | awk '$1=="nvidia"||$1=="nouveau"{print $1}' | paste -sd, -; }

status_text() {
    local g r
    g="$(gpu)"; r="$(reco)"
    echo "Carte NVIDIA : ${g:-aucune (lspci vendor 10de)}"
    echo "Module charge : $(loaded)"
    echo "Pilote du banc: $NVDRV  ($(apt-cache policy "$NVDRV" 2>/dev/null | awk '/Candidate:|Candidat/{print $2; exit}'))"
    echo "Recommande Ubuntu : ${r:-inconnu (ubuntu-drivers absent ou pas de reseau)}"
    echo "Installe      : $(installed | paste -sd' ' -)"
    [ -z "$(installed)" ] && echo "                (aucun pilote proprietaire)"
    echo "Disponibles   :"
    local d st
    for d in $(avail); do
        st=""
        [ "$d" = "$NVDRV" ] && st="$st pilote du banc"
        [ "$d" = "$r" ] && st="$st recommande Ubuntu"
        dpkg -s "$d" >/dev/null 2>&1 && st="$st installe"
        echo "   $d${st:+  [$st ]}"
    done
    if need nvidia-smi; then echo; nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/nvidia-smi : /'; fi
}

do_install() {
    local what="${1:-$NVDRV}"
    [ "$what" = recommended ] && what="$NVDRV"   # ancien nom d option, meme resultat
    if ! lspci -n 2>/dev/null | grep -qi 10de:; then
        echo -e "${RED}Aucune carte NVIDIA sur cette machine : rien a installer.${NC}"; return 1
    fi
    apt-get update -qq || { echo -e "${RED}Pas de reseau : les pilotes viennent des depots Ubuntu.${NC}"; return 1; }
    echo -e "${CYAN}apt install $what...${NC}"
    if ! apt-get install -y "$what"; then
        echo -e "${RED}$what non installe.${NC} Il vit dans multiverse :"
        echo -e "   ${CYAN}sudo add-apt-repository multiverse && sudo apt install $what${NC}"
        return 1
    fi
    update-initramfs -u >/dev/null 2>&1 || true
    echo -e "${GREEN}Termine. Redemarrez pour charger le module nvidia.${NC}"
}

do_update() {
    local pk; pk="$(dpkg -l 'nvidia-*' 'libnvidia-*' 'linux-modules-nvidia-*' 2>/dev/null | awk '/^ii/{print $2}' | paste -sd' ' -)"
    [ -n "$pk" ] || { echo -e "${YELLOW}Aucun paquet NVIDIA installe : rien a mettre a jour (--install d abord).${NC}"; return 1; }
    apt-get update -qq || { echo -e "${RED}Pas de reseau.${NC}"; return 1; }
    echo -e "${CYAN}Mise a jour de : $pk${NC}"
    # shellcheck disable=SC2086
    apt-get install -y --only-upgrade $pk
    update-initramfs -u >/dev/null 2>&1 || true
    echo -e "${GREEN}Termine.${NC}"
}

case "${1:-}" in
    --status)  status_text; exit 0 ;;
    --install) do_install "${2:-$NVDRV}"; exit $? ;;
    --update)  do_update; exit $? ;;
esac

need whiptail || { status_text; echo; echo "whiptail absent : --install [pilote|recommended] / --update"; exit 0; }
while :; do
    items=(status "Etat : carte, module charge, pilote du banc, installes")
    for d in $(avail); do
        st="installer"; dpkg -s "$d" >/dev/null 2>&1 && st="deja installe - reinstaller"
        [ "$d" = "$NVDRV" ] && st="$st (pilote du banc)"
        items+=("$d" "$st")
    done
    items+=(update "Mettre a jour les paquets NVIDIA installes")
    items+=(quit "Quitter")
    choice=$(whiptail --title "Pilotes graphiques - $(gpu | cut -c1-50)" \
        --menu "Pilote du banc : $NVDRV. Machine : $(hostname). Module charge : $(loaded)" 22 78 12 "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        status)      status_text | whiptail --title "Etat des pilotes" --textbox /dev/stdin 24 78 ;;
        update)      do_update; read -rp "Entree pour continuer..." _ ;;
        quit|"")     exit 0 ;;
        *)           do_install "$choice"; read -rp "Entree pour continuer..." _ ;;
    esac
done
