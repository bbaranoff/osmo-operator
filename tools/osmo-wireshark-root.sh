#!/bin/bash
# osmo-wireshark-root - Wireshark en root sur le banc : LTE, SCTP et GSM d un coup.
#
# [2026-09-08] UNE SEULE ICONE, ET ELLE ECOUTE DEJA LE BON TRAFIC. Wireshark
# ouvert « a la main » demandait de choisir l interface, puis de taper le
# filtre, puis de relancer en root parce que la capture etait refusee
# (wireshark-common/install-setuid est a false, expres). Ici :
#   - root par pkexec, donc l INVITE DE MOT DE PASSE GRAPHIQUE de l agent
#     polkit de GNOME (--disable-internal-agent interdit l agent texte) ;
#     xhost autorise root a ouvrir sa fenetre sur l affichage X11 de la
#     session, QT_QPA_PLATFORM=xcb la force par X meme sous Wayland ;
#   - capture immediate (-k) sur toutes les interfaces (-i any : la boucle
#     locale ou vit tout le coeur, plus le reseau ou partent GSMTAP et
#     l Abis d un vrai BTS) avec le filtre BPF du banc :
#       SCTP en entier   M3UA d osmo-stp (2905), SGs (29118), S1AP (36412),
#                        Diameter s il passe en SCTP - la signalisation A, Lb, S1 ;
#       GSM              GSMTAP udp 4729 (l air, et les logs osmocom en gsmtap),
#                        Abis/IPA tcp 3002-3003, Gb udp 23000-23001 (osmo-pcu),
#                        GTP udp 2123/2152 (sgsn <-> ggsn), MGCP udp 2427-2428,
#                        SIP 5060-5061, RTP d osmo-mgw (4002-16001) et
#                        d asterisk (30000-30199) ;
#       LTE              S1AP par le SCTP, GTP-C/U udp 2123/2152 (mme, sgwc,
#                        smf, upf), PFCP udp 8805, Diameter tcp 3868 (S6a, Gx),
#                        SBI http tcp 7777 (nrf <-> smf).
#     Hors filtre, exprès : les VTY (tcp 42xx), le ZeroMQ radio de srsRAN
#     (tcp 2000/2001 : des echantillons IQ, des Mo par seconde), Prometheus.
#   - avec des arguments (un .pcap ouvert depuis le bureau, ou les options que
#     passe launch.sh), on ne touche a rien : ils sont transmis tels quels.
# /usr/local/bin/wireshark est un lien vers ce script : « wireshark » au
# clavier comme a l icone, c est celui-ci. Le vrai binaire reste /usr/bin.
# OSMO_WS_FILTRE et OSMO_WS_IFACE pour changer le filtre ou l interface.
set -u
WS=/usr/bin/wireshark
[ -x "$WS" ] || { command -v zenity >/dev/null 2>&1 && \
    zenity --error --text="Wireshark introuvable (apt install wireshark)" 2>/dev/null; exit 1; }

FILTRE="${OSMO_WS_FILTRE:-sctp\
 or udp port 4729 or tcp port 3002 or tcp port 3003 or udp port 23000 or udp port 23001\
 or udp port 2123 or udp port 2152 or udp port 2427 or udp port 2428\
 or port 5060 or port 5061 or udp portrange 4002-16001 or udp portrange 30000-30199\
 or udp port 8805 or tcp port 3868 or tcp port 7777}"
IFACE="${OSMO_WS_IFACE:-any}"

[ $# -eq 0 ] && set -- -i "$IFACE" -k -f "$FILTRE"

[ "$(id -u)" -eq 0 ] && exec "$WS" "$@"

command -v xhost >/dev/null 2>&1 && xhost +SI:localuser:root >/dev/null 2>&1
if command -v pkexec >/dev/null 2>&1; then
    exec pkexec --disable-internal-agent env \
        DISPLAY="${DISPLAY:-:0}" \
        XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
        QT_QPA_PLATFORM=xcb \
        "$WS" "$@"
fi
exec sudo -E "$WS" "$@"
