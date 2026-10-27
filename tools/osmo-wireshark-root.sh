#!/bin/bash
# osmo-wireshark-root - Wireshark as root on the bench: 2G, 4G and the phone
# (signalling, call, SMS, data) at once.
#
# ONE ICON, ALREADY LISTENING TO THE RIGHT TRAFFIC (wireshark-common/
# install-setuid is false on purpose, so capture needs root). Here:
#   - root through pkexec, hence the GRAPHICAL PASSWORD PROMPT of the GNOME
#     polkit agent (--disable-internal-agent forbids the text agent);
#     xhost lets root open its window on the X11 display of the session,
#     QT_QPA_PLATFORM=xcb forces it through X even under Wayland;
#   - immediate capture (-k) on all interfaces (-i any: the loopback where
#     the whole core lives, plus the network where GSMTAP and the Abis of a
#     real BTS go) with the bench BPF filter (-f, what is RECORDED):
#       whole SCTP      M3UA of osmo-stp (2905), SGs (29118), S1AP (36412),
#                       Diameter when it runs over SCTP - A, Lb, S1 signalling;
#       GSM             GSMTAP udp 4729 (the air, and the osmocom logs in gsmtap),
#                       Abis/IPA tcp 3002-3003, Gb udp 23000-23001 (osmo-pcu),
#                       GTP udp 2123/2152 (sgsn <-> ggsn), MGCP udp 2427-2428,
#                       SIP 5060-5061, RTP of osmo-mgw (4002-16001) and of
#                       asterisk (30000-30199);
#       LTE             S1AP through SCTP, GTP-C/U udp 2123/2152 (mme, sgwc,
#                       smf, upf), PFCP udp 8805, Diameter tcp 3868 (S6a, Gx),
#                       SBI http tcp 7777 (nrf <-> smf).
#     Left out on purpose: the VTYs (tcp 42xx), the srsRAN ZeroMQ radio
#     (tcp 2000/2001: IQ samples, MB per second), Prometheus.
#   - a DISPLAY FILTER (-Y, what is SHOWN: everything stays in the capture,
#     one click in the bar removes it) that only keeps the 2G / 4G network
#     and the phone signalling:
#       2G   GSMTAP (Um: RR, MM, CC, SMS, GMM/SM of the phone), LAPDm,
#            Abis RSL/OML, A (SCTP/M3UA/SCCP/BSSAP/BSSMAP/DTAP), GSUP
#            (osmo-hlr), Gb (NS/BSSGP/LLC/SNDCP), GTP, MGCP, SMPP;
#       4G   S1AP + NAS-EPS (EMM/ESM), GTPv2 (S11), GTP-U, PFCP, Diameter
#            (S6a, Gx), SBI HTTP/2, SGs (CSFB and SMS over SGs), and LTE RRC /
#            MAC / RLC / PDCP when opening an srsRAN pcap;
#       call    DTAP CC, MGCP, SIP, RTP / RTCP / DTMF (rtpevent);
#       SMS     gsm_sms wherever it goes (DTAP, SGs, NAS), SMPP.
#     Without the noise that drowns all this: SCTP SACK / HEARTBEAT, M3UA
#     BEAT, Diameter Device-Watchdog, GTP / GTPv2 Echo, PFCP Heartbeat, and
#     on the air the System Information and Measurement Report messages.
#   - FILTER BUTTONS in the Wireshark bar (Banc, 2G, 4G, Appel, SMS, Data,
#     Attach) to see only one thing: installed in root's profile
#     (~root/.config/wireshark/dfilter_buttons) if there are none yet.
#   - with arguments (a .pcap opened from the desktop, or the options passed
#     by launch.sh), nothing is touched: they are passed through unchanged.
# /usr/local/bin/wireshark is a link to this script: "wireshark" typed at the
# keyboard or from the icon is this one. The real binary stays in /usr/bin.
# OSMO_WS_FILTRE (BPF), OSMO_WS_DFILTRE (display; empty = show everything) and
# OSMO_WS_IFACE change the filter, the display or the interface.
set -u
WS=/usr/bin/wireshark
[ -x "$WS" ] || { command -v zenity >/dev/null 2>&1 && \
    zenity --error --text="Wireshark introuvable (apt install wireshark)" 2>/dev/null; exit 1; }

# What is recorded (BPF).
FILTRE="${OSMO_WS_FILTRE:-sctp\
 or udp port 4729 or tcp port 3002 or tcp port 3003 or udp port 23000 or udp port 23001\
 or udp port 2123 or udp port 2152 or udp port 2427 or udp port 2428\
 or port 5060 or port 5061 or udp portrange 4002-16001 or udp portrange 30000-30199\
 or udp port 8805 or tcp port 3868 or tcp port 7777}"
IFACE="${OSMO_WS_IFACE:-any}"

# What is shown (Wireshark display filter). The parentheses: first the bench
# protocols, then, subtracted, the heartbeat noise.
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

# The filter bar buttons, in root's profile (root is the one capturing). An
# existing file (the user made their own) is respected.
osmo_ws_boutons() {
    local f="${HOME:-/root}/.config/wireshark/dfilter_buttons"
    [ -e "$f" ] && return 0
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    cat > "$f" <<BTN
# Filter buttons of the osmo-operator bench (osmo-wireshark-root).
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

# Not root: re-run ourselves as root (to install the buttons in root's
# profile), then Wireshark.
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
