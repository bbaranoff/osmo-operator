#!/bin/bash
# =============================================================================
#  osmo-drivers - les pilotes graphiques (ubuntu-drivers) : etat, install, MAJ
# =============================================================================
#  Le pendant, sur le systeme qui tourne (live ou installe), de la page
#  "Pilotes graphiques" de l installeur : montre ce que ubuntu-drivers propose
#  pour CETTE machine, ce qui est deja installe, et laisse choisir - installer
#  le recommande, un pilote precis, ou mettre a jour ce qui est la.
#
#      sudo ./tools/osmo-drivers.sh            menu whiptail
#      sudo ./tools/osmo-drivers.sh --status   l etat seul, en texte
#      sudo ./tools/osmo-drivers.sh --install [pilote|recommended]
#      sudo ./tools/osmo-drivers.sh --update
# =============================================================================
set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || exec pkexec --disable-internal-agent "$0" "$@" 2>/dev/null || exec sudo "$0" "$@"

need() { command -v "$1" >/dev/null 2>&1; }
if ! need ubuntu-drivers; then
    echo -e "${YELLOW}ubuntu-drivers absent : installation de ubuntu-drivers-common...${NC}"
    apt-get update -qq && apt-get install -y --no-install-recommends ubuntu-drivers-common pciutils
fi

gpu()        { lspci -d 10de: 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ //; s/ (rev.*//'; }
reco()       { ubuntu-drivers devices 2>/dev/null | awk '/^driver *:/ && /recommended/{print $3; exit}'; }
avail()      { ubuntu-drivers list 2>/dev/null | awk '/^nvidia-driver-/{print $1}' | sed 's/,.*//' | sort -u; }
installed()  { dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}'; }
loaded()     { lsmod 2>/dev/null | awk '$1=="nvidia"||$1=="nouveau"{print $1}' | paste -sd, -; }

status_text() {
    local g r
    g="$(gpu)"; r="$(reco)"
    echo "Carte NVIDIA : ${g:-aucune (lspci vendor 10de)}"
    echo "Module charge : $(loaded)"
    echo "Recommande    : ${r:-aucun}"
    echo "Installe      : $(installed | paste -sd' ' -)"
    [ -z "$(installed)" ] && echo "                (aucun pilote proprietaire)"
    echo "Disponibles   :"
    local d st
    for d in $(avail); do
        st=""
        [ "$d" = "$r" ] && st="$st recommande"
        dpkg -s "$d" >/dev/null 2>&1 && st="$st installe"
        echo "   $d${st:+  [$st ]}"
    done
    [ -z "$(avail)" ] && echo "   (ubuntu-drivers ne propose rien : pas de carte, ou pas de reseau pour lire les depots)"
    if need nvidia-smi; then echo; nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/nvidia-smi : /'; fi
}

do_install() {
    local what="${1:-recommended}"
    if ! lspci -n 2>/dev/null | grep -qi 10de:; then
        echo -e "${RED}Aucune carte NVIDIA sur cette machine : rien a installer.${NC}"; return 1
    fi
    apt-get update -qq || { echo -e "${RED}Pas de reseau : les pilotes viennent des depots Ubuntu.${NC}"; return 1; }
    if [ "$what" = recommended ]; then
        echo -e "${CYAN}ubuntu-drivers install (pilote recommande)...${NC}"
        ubuntu-drivers install || { local r; r="$(reco)"; [ -n "$r" ] && apt-get install -y "$r"; }
    else
        echo -e "${CYAN}apt-get install $what...${NC}"
        apt-get install -y "$what"
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
    --install) do_install "${2:-recommended}"; exit $? ;;
    --update)  do_update; exit $? ;;
esac

need whiptail || { status_text; echo; echo "whiptail absent : --install [pilote|recommended] / --update"; exit 0; }
while :; do
    items=(status "Etat : carte, pilote charge, recommande, installes")
    items+=(recommended "Installer le pilote recommande (ubuntu-drivers install)")
    for d in $(avail); do
        st="installer"; dpkg -s "$d" >/dev/null 2>&1 && st="deja installe - reinstaller"
        [ "$d" = "$(reco)" ] && st="$st (recommande)"
        items+=("$d" "$st")
    done
    items+=(update "Mettre a jour les paquets NVIDIA installes")
    items+=(quit "Quitter")
    choice=$(whiptail --title "Pilotes graphiques - $(gpu | cut -c1-50)" \
        --menu "ubuntu-drivers sur cette machine ($(hostname)). Module charge : $(loaded)" 22 78 12 "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        status)      status_text | whiptail --title "Etat des pilotes" --textbox /dev/stdin 24 78 ;;
        recommended) do_install recommended; read -rp "Entree pour continuer..." _ ;;
        update)      do_update; read -rp "Entree pour continuer..." _ ;;
        quit|"")     exit 0 ;;
        *)           do_install "$choice"; read -rp "Entree pour continuer..." _ ;;
    esac
done
