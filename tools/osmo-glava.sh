#!/bin/bash
# osmo-glava - start the NCS Spectrum visualizer (GLava) on the desktop.
#
# Installed by tools/glava-build.sh in /usr/local/bin, started by the user
# service glava.service (systemctl --user stop|start glava). One GLava NCS per
# user.
#
# The window is a square of 26 % of the screen height, placed above the city
# of the wallpaper (gsm-lab-ville.jpg): x = 49 %, y = 21 %. On 2560x1600 that
# is 420 px at (1250, 330). Computed here from the primary screen rather than
# fixed in rc.glsl: the same ISO runs on different screens.
#
# MICROPHONE AND SPEAKERS. GLava reads only ONE PulseAudio source. One is built
# for it: a null sink "osmo_glava", into which two module-loopback copy the
# monitor of the default output (what the speakers play) and the default
# source (the microphone - on the bench, osmo_mic_ec, the echo-cancelled
# microphone). GLava listens to osmo_glava.monitor. The microphone goes ONLY
# into this null sink, never to the speakers: no feedback. The default devices
# are read at startup (login).
# The guard only targets the NCS instance (-r setgeometry...): another instance
# (glava -m bars, for example) does not prevent it from starting.
#
MIX=osmo_glava
# --retirer-mix: called when the service stops (ExecStopPost of glava.service),
# removes the two loopbacks then the null sink (in that order: the sink takes
# its loopbacks with it, a second removal would fail).
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
        # The speakers = the monitor of the HARDWARE output. @DEFAULT_MONITOR@
        # is not enough: at login the default sink may be osmo_hp_ec (the bench
        # echo cancellation, 8 kHz mono, GSM voice only) and GLava would see
        # neither the browser nor anything else. The ALSA sink receives
        # everything, osmo_hp_ec included (its master).
        hp=$(pactl get-default-sink 2>/dev/null)
        case "$hp" in alsa_output.*|bluez_sink.*) ;;
            *) hp=$(pactl list short sinks 2>/dev/null | awk '$2 ~ /^(alsa_output|bluez_sink)\./ {print $2; exit}') ;;
        esac
        hp=${hp:+$hp.monitor}
        pactl load-module module-loopback source="${hp:-@DEFAULT_MONITOR@}" sink=$MIX \
            source_dont_move=true sink_dont_move=true latency_msec=30 >/dev/null
        pactl load-module module-loopback source=@DEFAULT_SOURCE@ sink=$MIX \
            source_dont_move=true sink_dont_move=true latency_msec=30 >/dev/null
    fi
    SOURCE=(-r "setsource \"$MIX.monitor\"")
else
    SOURCE=()
fi

# THE BOTTOM BAND: a second instance, bars module, over the whole free width
# (right of the dock: _NET_WORKAREA) and 8.75 % of the height (140 px on 1600),
# stuck to the bottom edge. Same source as the circle.
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
