#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-payload-ism.sh — the SMS PAYLOAD over ISM radio, the rest over IP
#
# Complement of --wan: the signalling (MSISDN, IMSI, SC-address, SS7, SIP)
# already goes over IP between the two nodes; this script connects the ISM-band
# RADIO link that will carry ONLY the SMS text, and writes the [payload] section
# of sms-routing.conf read by scripts/sms-interop-relay.py (via ism_payload.py).
#
# Run on EACH node (with --wan in place). Choose the backend according to the
# radio:
#
#   serial  — an ISM module over UART (LoRa, RFM69, CC1101, HC-12...) on /dev/tty*.
#             The simplest hardware-wise. The baud rate is set here by stty.
#               sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600
#
#   exec    — an SDR pipeline YOU provide (HackRF/LimeSDR/USRP + GNU Radio,
#             rtl_433 for reception, etc.). Two commands: TX reads a frame on
#             its stdin and transmits it; RX writes received frames on its stdout.
#               sudo ./network/setup-payload-ism.sh --exec \
#                    --tx-cmd '/opt/GSM/ism/ism_tx.sh' --rx-cmd '/opt/GSM/ism/ism_rx.sh'
#             Templates of ism_tx.sh / ism_rx.sh are placed in /opt/GSM/ism with
#             --exemples (they transmit nothing until filled in).
#
#   fifo    — two named pipes, if the radio is connected otherwise (socat...).
#               sudo ./network/setup-payload-ism.sh --fifo --tx /tmp/ism_tx --rx /tmp/ism_rx
#
#   loopback— all in memory, to TRY the SMS chain without radio (one node).
#               sudo ./network/setup-payload-ism.sh --loopback
#
# Common options: --conf FILE (default: the sms-routing.conf files found),
# --recv-timeout SECONDS (wait for the radio payload before failing, default 30),
# --selftest (runs the ism_payload.py self-test and exits), --off (removes [payload]).
#
# REGULATORY REMINDER: transmit only on a band and power allowed where you are
# (ISM 433/868 MHz in Europe, 902-928 MHz in region 2, 2.4 GHz), or into a
# cage/dummy load. This is your responsibility as bench operator.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LINK="" DEV="" BAUD="9600" TX="" RX="" TXCMD="" RXCMD=""
RECV_TIMEOUT="30" CONF="" DO_SELFTEST=0 DO_OFF=0 DO_EXAMPLES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --serial)   LINK=serial; DEV="${2:?--serial attend un /dev/tty*}"; shift ;;
        --baud)     BAUD="${2:?}"; shift ;;
        --exec)     LINK=exec ;;
        --fifo)     LINK=fifo ;;
        --loopback) LINK=loopback ;;
        --tx)       TX="${2:?}"; shift ;;
        --rx)       RX="${2:?}"; shift ;;
        --tx-cmd)   TXCMD="${2:?}"; shift ;;
        --rx-cmd)   RXCMD="${2:?}"; shift ;;
        --recv-timeout) RECV_TIMEOUT="${2:?}"; shift ;;
        --conf)     CONF="${2:?}"; shift ;;
        --selftest) DO_SELFTEST=1 ;;
        --exemples|--examples) DO_EXAMPLES=1 ;;
        --off)      DO_OFF=1 ;;
        -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

say() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*" >&2; }

# ── the sms-routing.conf files to modify ─────────────────────────────────────
# Native: /etc/osmocom/sms-routing.conf. Docker: the one of each container.
confs() {
    if [ -n "$CONF" ]; then printf '%s\n' "$CONF"; return; fi
    local found=0
    if [ -f /etc/osmocom/sms-routing.conf ]; then printf '%s\n' /etc/osmocom/sms-routing.conf; found=1; fi
    if command -v docker >/dev/null 2>&1; then
        for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep '^osmo-operator-' || true); do
            printf 'docker:%s\n' "$c"; found=1
        done
    fi
    [ "$found" = 1 ] || warn "aucun sms-routing.conf trouve (passe --conf)"
}

# Writes the [payload] section into a file (local path or docker:<container>).
write_block() {
    local target="$1" block="$2"
    local script="
        CONF=/etc/osmocom/sms-routing.conf
        sed -i '/# ── PAYLOAD ISM/,/# ── FIN PAYLOAD ISM/d' \"\$CONF\" 2>/dev/null || true
        sed -i '/^\\[payload\\]/,/^\\[/{/^\\[payload\\]/d; /^\\[/!d}' \"\$CONF\" 2>/dev/null || true
        printf '%s\n' \"\$BLOCK\" >> \"\$CONF\"
    "
    if [ "$DO_OFF" = 1 ]; then
        block=""
        script="
            CONF=/etc/osmocom/sms-routing.conf
            sed -i '/# ── PAYLOAD ISM/,/# ── FIN PAYLOAD ISM/d' \"\$CONF\" 2>/dev/null || true
        "
    fi
    case "$target" in
        docker:*)
            local c="${target#docker:}"
            docker exec -e BLOCK="$block" "$c" bash -c "$script" \
                && say "[$c] section [payload] ${DO_OFF:+retiree}${DO_OFF:-ecrite}" \
                || warn "[$c] echec d'ecriture"
            ;;
        *)
            local CONFP="$target"
            if [ "$DO_OFF" = 1 ]; then
                sed -i '/# ── PAYLOAD ISM/,/# ── FIN PAYLOAD ISM/d' "$CONFP" 2>/dev/null || true
                say "[$CONFP] section [payload] retiree"
            else
                sed -i '/# ── PAYLOAD ISM/,/# ── FIN PAYLOAD ISM/d' "$CONFP" 2>/dev/null || true
                printf '%s\n' "$block" >> "$CONFP"
                say "[$CONFP] section [payload] ecrite"
            fi
            ;;
    esac
}

# ── self-test ────────────────────────────────────────────────────────────────
if [ "$DO_SELFTEST" = 1 ]; then
    echo -e "${CYAN}Autotest de la liaison payload ISM${NC}"
    case "$LINK" in
        fifo)   python3 -I "$HERE/scripts/ism_payload.py" --selftest --link fifo \
                    --tx "${TX:-/tmp/osmo_ism_tx}" --rx "${RX:-/tmp/osmo_ism_rx}" ;;
        serial) python3 -I "$HERE/scripts/ism_payload.py" --selftest --link serial --serial "$DEV" ;;
        *)      python3 -I "$HERE/scripts/ism_payload.py" --selftest ;;
    esac
    exit $?
fi

# ── removal ──────────────────────────────────────────────────────────────────
if [ "$DO_OFF" = 1 ]; then
    echo -e "${CYAN}Retrait du payload ISM (retour au texte par IP)${NC}"
    while read -r t; do [ -n "$t" ] && write_block "$t" ""; done < <(confs)
    exit 0
fi

[ -n "$LINK" ] || { echo -e "${RED}choisis un backend : --serial /dev/tty* | --exec | --fifo | --loopback${NC}" >&2; exit 2; }

# ── SDR templates for the exec backend ───────────────────────────────────────
if [ "$DO_EXAMPLES" = 1 ] || { [ "$LINK" = exec ] && [ -z "$TXCMD" ] && [ -z "$RXCMD" ]; }; then
    mkdir -p /opt/GSM/ism
    if [ ! -f /opt/GSM/ism/ism_tx.sh ]; then
        cat > /opt/GSM/ism/ism_tx.sh <<'TX'
#!/bin/bash
# ism_tx.sh — TRANSMITS a frame (read on stdin) in the ISM band. TEMPLATE: to fill in.
# The frame is a JSON line {"t":token,"p":hex,"c":crc}. Transmit it as is
# (FSK/LoRa/OOK modulation, your choice) on your allowed ISM frequency.
# Possible chains:
#   - LoRa/UART module : cat > /dev/ttyUSB0
#   - GNU Radio SDR    : hand the line to a flowgraph (gr-paquet) through a FIFO
# As long as this file transmits nothing, the ISM payload does not go through.
cat >/dev/null   # <- REPLACE: the frame is dropped here
TX
        chmod +x /opt/GSM/ism/ism_tx.sh
    fi
    if [ ! -f /opt/GSM/ism/ism_rx.sh ]; then
        cat > /opt/GSM/ism/ism_rx.sh <<'RX'
#!/bin/bash
# ism_rx.sh — RECEIVES in the ISM band and writes each received frame (one JSON
# line) on stdout. TEMPLATE: to fill in. Demodulate your radio and emit the lines.
# Examples:
#   - LoRa/UART module : exec cat /dev/ttyUSB0
#   - SDR              : read the output of a flowgraph (gr-paquet)
# As long as this file reads nothing, no payload arrives.
exec sleep infinity   # <- REPLACE: nothing is ever received here
RX
        chmod +x /opt/GSM/ism/ism_rx.sh
    fi
    say "gabarits SDR : /opt/GSM/ism/ism_tx.sh et ism_rx.sh (a remplir avant d'emettre)"
    [ -z "$TXCMD" ] && TXCMD="/opt/GSM/ism/ism_tx.sh"
    [ -z "$RXCMD" ] && RXCMD="/opt/GSM/ism/ism_rx.sh"
fi

# ── serial: set the baud rate (the backend then reads/writes raw) ─────────────
if [ "$LINK" = serial ]; then
    [ -e "$DEV" ] || warn "$DEV absent pour l'instant (branche le module ISM)"
    if [ -e "$DEV" ]; then
        stty -F "$DEV" "$BAUD" cs8 -cstopb -parenb -echo raw 2>/dev/null \
            && say "serie $DEV a $BAUD bauds, mode brut" \
            || warn "stty sur $DEV a echoue (droits ? module absent ?)"
    fi
fi

# ── compose the [payload] section ────────────────────────────────────────────
BLOCK="# ── PAYLOAD ISM ───────────────────────────────────────────────────────────
# Written by network/setup-payload-ism.sh. The SMS text goes over ISM radio,
# the signalling stays on IP (see wiki/Payload-ISM.md).

[payload]
mode = ism
link = $LINK
recv_timeout = $RECV_TIMEOUT"
case "$LINK" in
    serial) BLOCK="$BLOCK
serial = $DEV" ;;
    fifo)   BLOCK="$BLOCK
tx = ${TX:-/tmp/osmo_ism_tx}
rx = ${RX:-/tmp/osmo_ism_rx}" ;;
    exec)   BLOCK="$BLOCK
tx_cmd = $TXCMD
rx_cmd = $RXCMD" ;;
esac
BLOCK="$BLOCK
# ── FIN PAYLOAD ISM ───────────────────────────────────────────────────────────"

echo -e "${CYAN}Payload ISM : backend ${LINK}${NC}"
while read -r t; do [ -n "$t" ] && write_block "$t" "$BLOCK"; done < <(confs)

echo
say "Fait. Relance le relais SMS pour qu'il prenne la liaison :"
echo "     - natif  : sudo systemctl restart osmo-smsc  (ou scripts/smsc-start.sh)"
echo "     - docker : sudo docker restart \$(docker ps --format '{{.Names}}' | grep osmo-operator-)"
echo "   ou simplement : ./start-native.sh --wan --payload-ism (il fait tout)."
if [ "$LINK" = exec ]; then
    warn "backend exec : remplis /opt/GSM/ism/ism_tx.sh et ism_rx.sh (ta radio)."
fi
warn "N'emets que sur une bande/puissance ISM autorisees chez toi, ou en charge/cage."
