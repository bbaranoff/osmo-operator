#!/bin/bash
# osmo-glava - lance le visualiseur NCS Spectrum (GLava) sur le bureau.
#
# Pose par tools/glava-build.sh dans /usr/local/bin, lance par le service
# utilisateur glava.service (systemctl --user stop|start glava). Un seul
# GLava NCS par utilisateur.
#
# [2026-10-23] La fenetre est un carre de 26 % de la hauteur de l ecran, place
# au-dessus de la ville du fond (gsm-lab-ville.jpg) : x = 49 %, y = 21 %. Sur
# 2560x1600, c est 420 px en (1250, 330). Calcule ici d apres l ecran
# principal, plutot que fige dans rc.glsl : la meme ISO tourne sur des ecrans
# differents.
#
# [2026-10-24] LE MICRO ET LES HAUT-PARLEURS. GLava ne lit qu UNE source
# PulseAudio. On lui en fabrique une : un sink nul « osmo_glava », dans lequel
# deux module-loopback recopient le moniteur de la sortie par defaut (ce que
# jouent les haut-parleurs) et la source par defaut (le micro - sur le banc,
# osmo_mic_ec, le micro a annulation d echo). GLava ecoute osmo_glava.monitor.
# Le micro ne va QUE dans ce sink nul, jamais vers les haut-parleurs : pas de
# larsen. Les sources par defaut sont lues au lancement (connexion).
# Le garde ne vise que l instance NCS (-r setgeometry...) : une autre instance
# (glava -m bars, par exemple) ne l empeche pas de demarrer.
MIX=osmo_glava
# --retirer-mix : appele a l arret du service (ExecStopPost de glava.service),
# retire les deux boucles puis le sink nul (dans cet ordre : le sink emporte
# ses boucles, un second retrait echouerait).
if [ "${1:-}" = "--retirer-mix" ]; then
    pactl list short modules 2>/dev/null \
        | awk -v m="$MIX" '$0 ~ ("sink(_name)?=" m "([[:space:]]|$)") {print $1}' \
        | sort -rn | while read -r id; do pactl unload-module "$id"; done
    exit 0
fi
pgrep -u "$(id -u)" -f '^glava -r setgeometry' >/dev/null && exit 0
sleep "${OSMO_GLAVA_DELAI:-6}"      # comme conky : le bureau GNOME doit etre peint

if command -v pactl >/dev/null 2>&1; then
    if ! pactl list short sinks 2>/dev/null | grep -q "^[0-9]*[[:space:]]$MIX[[:space:]]"; then
        pactl load-module module-null-sink sink_name=$MIX \
            sink_properties=device.description=GLava-micro+HP >/dev/null
        pactl load-module module-loopback source=@DEFAULT_MONITOR@ sink=$MIX \
            source_dont_move=true sink_dont_move=true latency_msec=30 >/dev/null
        pactl load-module module-loopback source=@DEFAULT_SOURCE@ sink=$MIX \
            source_dont_move=true sink_dont_move=true latency_msec=30 >/dev/null
    fi
    SOURCE=(-r "setsource \"$MIX.monitor\"")
else
    SOURCE=()
fi

# [2026-10-24] LA BANDE DU BAS : une seconde instance, module bars, sur toute
# la largeur libre (a droite du dock : _NET_WORKAREA) et 8,75 % de la hauteur
# (140 px sur 1600), collee au bord bas. Meme source que le cercle.
lancer_barres() {   # W H
    pgrep -u "$(id -u)" -f '^glava -m bars' >/dev/null && return 0
    local zone x0 h
    zone=$(xprop -root _NET_WORKAREA 2>/dev/null | sed -n 's/.*= \([0-9]*\), .*/\1/p')
    x0=${zone:-0}
    h=$(( $2 * 875 / 10000 ))
    setsid -f glava -m bars -r "setgeometry $x0 $(( $2 - h )) $(( $1 - x0 )) $h" "${SOURCE[@]}" \
        >/dev/null 2>&1
}

ecran=$(xrandr --current 2>/dev/null | sed -n 's/.* connected primary \([0-9]*\)x\([0-9]*\)+.*/\1 \2/p' | head -1)
[ -n "$ecran" ] || ecran=$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\),.*/\1 \2/p' | head -1)
read -r W H <<< "${ecran:-1920 1080}"
cote=$(( H * 26 / 100 ))
lancer_barres "$W" "$H"
exec glava -r "setgeometry $(( W * 49 / 100 )) $(( H * 21 / 100 )) $cote $cote" "${SOURCE[@]}" "$@"
