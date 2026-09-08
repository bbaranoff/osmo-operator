#!/bin/bash
# osmo-wireshark-root - Wireshark en root sur le banc : 2G, 4G et le telephone
# (signalisation, appel, SMS, data) d un coup.
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
#     l Abis d un vrai BTS) avec le filtre BPF du banc (-f, ce qui est
#     ENREGISTRE) :
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
#   - un FILTRE D AFFICHAGE (-Y, ce qui est MONTRE : tout reste dans la
#     capture, on l enleve d un clic dans la barre) qui ne garde que le
#     reseau 2G / 4G et la signalisation du telephone :
#       2G   GSMTAP (Um : RR, MM, CC, SMS, GMM/SM du telephone), LAPDm,
#            Abis RSL/OML, A (SCTP/M3UA/SCCP/BSSAP/BSSMAP/DTAP), GSUP
#            (osmo-hlr), Gb (NS/BSSGP/LLC/SNDCP), GTP, MGCP, SMPP ;
#       4G   S1AP + NAS-EPS (EMM/ESM), GTPv2 (S11), GTP-U, PFCP, Diameter
#            (S6a, Gx), SBI HTTP/2, SGs (CSFB et SMS over SGs), et LTE RRC /
#            MAC / RLC / PDCP quand on ouvre un pcap de srsRAN ;
#       appel   DTAP CC, MGCP, SIP, RTP / RTCP / DTMF (rtpevent) ;
#       SMS     gsm_sms partout ou il passe (DTAP, SGs, NAS), SMPP.
#     Sans le bruit qui noie tout ca : SACK / HEARTBEAT du SCTP, BEAT du
#     M3UA, Device-Watchdog du Diameter, Echo GTP / GTPv2, Heartbeat PFCP,
#     et sur l air les System Information et les Measurement Report.
#   - des BOUTONS DE FILTRE dans la barre de Wireshark (Banc, 2G, 4G, Appel,
#     SMS, Data, Attach) pour ne voir qu une chose : poses dans le profil de
#     root (~root/.config/wireshark/dfilter_buttons) s il n y en a pas deja.
#   - avec des arguments (un .pcap ouvert depuis le bureau, ou les options que
#     passe launch.sh), on ne touche a rien : ils sont transmis tels quels.
# /usr/local/bin/wireshark est un lien vers ce script : « wireshark » au
# clavier comme a l icone, c est celui-ci. Le vrai binaire reste /usr/bin.
# OSMO_WS_FILTRE (BPF), OSMO_WS_DFILTRE (affichage ; vide = tout montrer) et
# OSMO_WS_IFACE pour changer le filtre, l affichage ou l interface.
set -u
WS=/usr/bin/wireshark
[ -x "$WS" ] || { command -v zenity >/dev/null 2>&1 && \
    zenity --error --text="Wireshark introuvable (apt install wireshark)" 2>/dev/null; exit 1; }

# Ce qui est enregistre (BPF).
FILTRE="${OSMO_WS_FILTRE:-sctp\
 or udp port 4729 or tcp port 3002 or tcp port 3003 or udp port 23000 or udp port 23001\
 or udp port 2123 or udp port 2152 or udp port 2427 or udp port 2428\
 or port 5060 or port 5061 or udp portrange 4002-16001 or udp portrange 30000-30199\
 or udp port 8805 or tcp port 3868 or tcp port 7777}"
IFACE="${OSMO_WS_IFACE:-any}"

# Ce qui est montre (filtre d affichage Wireshark). Les parentheses : d abord
# les protocoles du banc, puis, retranche, le bruit des battements de coeur.
D_PROTOS="sctp || m3ua || sccp || bssap || gsm_a.bssmap || gsm_a.dtap || gsm_a.rr || gsm_a.ccch || gsm_a.sacch || gsm_a.gm || gsm_sms || gsm_map || tcap || gsup || sgsap || smpp\
 || gsmtap || lapdm || gsm_abis_rsl || gsm_abis_oml\
 || gprs-ns || bssgp || llcgprs || sndcp || gtp || gtpv2 || pfcp\
 || s1ap || nas-eps || lte_rrc || mac-lte || rlc-lte || pdcp-lte || diameter || http2\
 || mgcp || sip || rtp || rtcp || rtpevent"
D_BRUIT="(sctp && !(sctp.chunk_type == 0) && sctp.chunk_type in {3, 4, 5})\
 || (m3ua.message_class == 3 && m3ua.message_type in {3, 6})\
 || diameter.cmd.code == 280\
 || gtp.message in {1, 2} || gtpv2.message_type in {1, 2} || pfcp.msg_type in {1, 2}\
 || gsm_a.dtap.msg_rr_type in {0x00, 0x02, 0x03, 0x05, 0x06, 0x07, 0x15, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e}"
DFILTRE="${OSMO_WS_DFILTRE-($D_PROTOS) && !($D_BRUIT)}"

# Les boutons de la barre de filtre, dans le profil de root (c est lui qui
# capture). Un fichier deja la (l utilisateur a fait les siens) est respecte.
osmo_ws_boutons() {
    local f="${HOME:-/root}/.config/wireshark/dfilter_buttons"
    [ -e "$f" ] && return 0
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    cat > "$f" <<BTN
# Boutons de filtre du banc osmo-operator (osmo-wireshark-root).
"TRUE","Banc","$DFILTRE","Reseau 2G + 4G et telephone, sans les battements de coeur"
"TRUE","2G","(gsmtap || lapdm || gsm_abis_rsl || gsm_abis_oml || bssap || gsm_a.bssmap || gsm_a.dtap || gsup || gprs-ns || bssgp || llcgprs || sndcp || mgcp || smpp) && !($D_BRUIT)","Um, Abis, A, Gb, GSUP, MGCP"
"TRUE","4G","(s1ap || nas-eps || gtpv2 || pfcp || diameter || http2 || sgsap || lte_rrc || mac-lte || pdcp-lte) && !($D_BRUIT)","S1, S11, Sx, S6a/Gx, SBI, SGs"
"TRUE","Appel","gsm_a.dtap.protocol_discriminator == 3 || mgcp || sip || rtpevent || sgsap || nas-eps.nas_msg_emm_type == 0x4c || gsm_a.bssmap.msgtype in {0x01, 0x02, 0x03, 0x20, 0x21, 0x22, 0x52}","CC (DTAP), MGCP, SIP, DTMF, CSFB (SGs, Extended Service Request), paging, assignation et liberation BSSMAP"
"TRUE","SMS","gsm_sms || gsm_a.dtap.protocol_discriminator == 9 || smpp || sgsap.msg_type in {0x07, 0x08}","SMS en DTAP, SGs, NAS et SMPP"
"TRUE","Data","gsm_a.gm || llcgprs || sndcp || bssgp || gprs-ns || gtp || gtpv2 || pfcp || nas-eps.nas_msg_esm_type || gsm_a.dtap.protocol_discriminator in {8, 10}","GMM/SM, Gb, GTP, PFCP, ESM"
"TRUE","Attach","gsm_a.dtap.protocol_discriminator == 5 || gsm_a.dtap.msg_gmm_type || nas-eps.nas_msg_emm_type || gsup || diameter.cmd.code in {316, 318} || gsm_a.bssmap.msgtype in {0x52, 0x57, 0x20}","MM, GMM, EMM, GSUP, S6a (ULR/AIR), Paging / Complete Layer 3 / Clear"
BTN
    return 0
}

if [ $# -eq 0 ]; then
    set -- -i "$IFACE" -k -f "$FILTRE"
    [ -n "$DFILTRE" ] && set -- "$@" -Y "$DFILTRE"
fi

if [ "$(id -u)" -eq 0 ]; then
    osmo_ws_boutons
    exec "$WS" "$@"
fi

# Pas root : on se relance nous-memes en root (pour poser les boutons dans le
# profil de root), puis Wireshark.
MOI="$(readlink -f "$0" 2>/dev/null || echo "$0")"
[ -x "$MOI" ] || MOI="$WS"
command -v xhost >/dev/null 2>&1 && xhost +SI:localuser:root >/dev/null 2>&1
if command -v pkexec >/dev/null 2>&1; then
    exec pkexec --disable-internal-agent env \
        DISPLAY="${DISPLAY:-:0}" \
        XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
        QT_QPA_PLATFORM=xcb \
        HOME=/root \
        "$MOI" "$@"
fi
exec sudo -E HOME=/root "$MOI" "$@"
