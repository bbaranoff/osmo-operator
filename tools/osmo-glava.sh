#!/bin/bash
# osmo-glava - lance le visualiseur NCS Spectrum (GLava) sur le bureau.
#
# Pose par tools/glava-build.sh dans /usr/local/bin, lance par
# /etc/xdg/autostart/osmo-glava.desktop. Un seul GLava par utilisateur.
#
# [2026-10-23] La fenetre est un carre de 26 % de la hauteur de l ecran, place
# au-dessus de la ville du fond (gsm-lab-ville.jpg) : x = 49 %, y = 21 %. Sur
# 2560x1600, c est 420 px en (1250, 330). Calcule ici d apres l ecran
# principal, plutot que fige dans rc.glsl : la meme ISO tourne sur des ecrans
# differents.
pgrep -u "$(id -u)" -x glava >/dev/null && exit 0
sleep "${OSMO_GLAVA_DELAI:-6}"      # comme conky : le bureau GNOME doit etre peint

ecran=$(xrandr --current 2>/dev/null | sed -n 's/.* connected primary \([0-9]*\)x\([0-9]*\)+.*/\1 \2/p' | head -1)
[ -n "$ecran" ] || ecran=$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\),.*/\1 \2/p' | head -1)
read -r W H <<< "${ecran:-1920 1080}"
cote=$(( H * 26 / 100 ))
exec glava -r "setgeometry $(( W * 49 / 100 )) $(( H * 21 / 100 )) $cote $cote" "$@"
