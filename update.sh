#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# update.sh - l'animation SMS de l'ouverture de session. Rien d'autre.
#
# [2026-08-27] Ce fichier ne faisait pas ce que son nom dit : il posait un
# osmo-sync.sh qui, a CHAQUE demarrage, effacait puis reclonait osmo_egprs et
# osmo-egprs-web depuis GitHub, resynchronisait qemu-src, installait socat a
# coups d'apt, et rearmait un declencheur sur la console. Trois consequences :
#
#   - ce qui tournait sur la machine n'etait plus ce que l'ISO portait, mais ce
#     que GitHub avait ce matin-la ;
#   - sans reseau au demarrage, les arbres effaces ne revenaient pas ;
#   - un paquet reinstalle a chaque boot, c'est un boot qui depend du reseau.
#
# Tout cela appartient a la CONSTRUCTION, pas au demarrage : c'est build-iso.sh
# qui embarque desormais les trois depots AVEC leur .git (et qemu-src avec son
# build/ compile), installe socat/nc/tcpdump/git dans le rootfs, et pose le
# service du dashboard. Une machine qui demarre n'a plus rien a aller chercher.
#
# Ce qu'il reste ici est ce qui ne pouvait pas etre fait a la construction :
# l'animation, qui a besoin d'un terminal et de quelqu'un devant.
#
# Usage :
#   sudo ./update.sh            joue l'animation
#   sudo ./update.sh --quiet    ne joue rien (sortie silencieuse, code 0)
#
# Sur l'ISO, /etc/profile.d/99-osmo-sms.sh l'appelle une fois par demarrage,
# apres le choix du clavier (ordre alphabetique de /etc/profile.d).
# ══════════════════════════════════════════════════════════════════════════════
set -u

case "${1:-}" in
    --quiet) exit 0 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Sur un tty seulement : les sequences de curseur (\033[?25l) ecrites dans un
# fichier de log le rendent illisible, et l'attente ne sert plus personne.
[ -t 1 ] || exit 0

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
    printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
    sleep 0.12
done
for ((p=0; p<=20; p++)); do
    printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
    sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"
