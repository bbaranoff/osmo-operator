#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-payload-ism.sh — le PAYLOAD des SMS par radio ISM, le reste par IP
#
# Complement de --wan : la signalisation (MSISDN, IMSI, SC-address, SS7, SIP)
# passe deja par IP entre les deux noeuds ; ce script branche la liaison RADIO
# en bande ISM qui portera le SEUL texte des SMS, et ecrit la section [payload]
# de sms-routing.conf que lit scripts/sms-interop-relay.py (via ism_payload.py).
#
# A lancer sur CHAQUE noeud (avec --wan en place). Choisis le backend selon ta
# radio :
#
#   serial  — un module ISM en UART (LoRa, RFM69, CC1101, HC-12...) sur /dev/tty*.
#             Le plus simple materiellement. Le debit est pose ici par stty.
#               sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600
#
#   exec    — un pipeline SDR que TU fournis (HackRF/LimeSDR/USRP + GNU Radio,
#             rtl_433 en reception, etc.). Deux commandes : TX lit une trame sur
#             son stdin et l'emet ; RX ecrit les trames recues sur son stdout.
#               sudo ./network/setup-payload-ism.sh --exec \
#                    --tx-cmd '/opt/GSM/ism/ism_tx.sh' --rx-cmd '/opt/GSM/ism/ism_rx.sh'
#             Des gabarits de ism_tx.sh / ism_rx.sh sont deposes dans /opt/GSM/ism
#             avec --exemples (ne transmettent rien tant que tu ne les remplis pas).
#
#   fifo    — deux tubes nommes, si tu branches ta radio autrement (socat...).
#               sudo ./network/setup-payload-ism.sh --fifo --tx /tmp/ism_tx --rx /tmp/ism_rx
#
#   loopback— tout en memoire, pour ESSAYER la chaine SMS sans radio (un noeud).
#               sudo ./network/setup-payload-ism.sh --loopback
#
# Options communes : --conf FICHIER (defaut : les sms-routing.conf trouves),
# --recv-timeout SECONDES (attente du payload radio avant echec, defaut 30),
# --selftest (lance l'autotest de ism_payload.py et sort), --off (retire [payload]).
#
# RAPPEL REGLEMENTAIRE : n'emets que sur une bande et une puissance autorisees
# chez toi (ISM 433/868 MHz en Europe, 902-928 MHz en region 2, 2,4 GHz), ou en
# cage/charge. C'est ta responsabilite d'operateur du banc.
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

# ── les sms-routing.conf a modifier ──────────────────────────────────────────
# Natif : /etc/osmocom/sms-routing.conf. Docker : celui de chaque container.
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

# Ecrit la section [payload] dans un fichier (chemin local ou docker:<container>).
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

# ── autotest ─────────────────────────────────────────────────────────────────
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

# ── retrait ──────────────────────────────────────────────────────────────────
if [ "$DO_OFF" = 1 ]; then
    echo -e "${CYAN}Retrait du payload ISM (retour au texte par IP)${NC}"
    while read -r t; do [ -n "$t" ] && write_block "$t" ""; done < <(confs)
    exit 0
fi

[ -n "$LINK" ] || { echo -e "${RED}choisis un backend : --serial /dev/tty* | --exec | --fifo | --loopback${NC}" >&2; exit 2; }

# ── gabarits SDR pour le backend exec ────────────────────────────────────────
if [ "$DO_EXAMPLES" = 1 ] || { [ "$LINK" = exec ] && [ -z "$TXCMD" ] && [ -z "$RXCMD" ]; }; then
    mkdir -p /opt/GSM/ism
    if [ ! -f /opt/GSM/ism/ism_tx.sh ]; then
        cat > /opt/GSM/ism/ism_tx.sh <<'TX'
#!/bin/bash
# ism_tx.sh — EMET une trame (lue sur stdin) en bande ISM. GABARIT : a remplir.
# La trame est une ligne JSON {"t":jeton,"p":hex,"c":crc}. Emets-la telle quelle
# (modulation FSK/LoRa/OOK au choix) sur ta frequence ISM autorisee.
# Exemples de chaine possible :
#   - module LoRa/UART : cat > /dev/ttyUSB0
#   - SDR GNU Radio    : passer la ligne a un flowgraph (gr-paquet) via un FIFO
# Tant que ce fichier n'emet rien, le payload ISM ne traverse pas : remplis-le.
cat >/dev/null   # <- REMPLACER : ici on jette la trame
TX
        chmod +x /opt/GSM/ism/ism_tx.sh
    fi
    if [ ! -f /opt/GSM/ism/ism_rx.sh ]; then
        cat > /opt/GSM/ism/ism_rx.sh <<'RX'
#!/bin/bash
# ism_rx.sh — RECOIT en bande ISM et ecrit chaque trame recue (une ligne JSON)
# sur stdout. GABARIT : a remplir. Demodule ta radio et recrache les lignes.
# Exemples :
#   - module LoRa/UART : exec cat /dev/ttyUSB0
#   - SDR              : lire la sortie d'un flowgraph (gr-paquet)
# Tant que ce fichier ne lit rien, aucun payload n'arrive : remplis-le.
exec sleep infinity   # <- REMPLACER : ici on ne recoit jamais
RX
        chmod +x /opt/GSM/ism/ism_rx.sh
    fi
    say "gabarits SDR : /opt/GSM/ism/ism_tx.sh et ism_rx.sh (a remplir avant d'emettre)"
    [ -z "$TXCMD" ] && TXCMD="/opt/GSM/ism/ism_tx.sh"
    [ -z "$RXCMD" ] && RXCMD="/opt/GSM/ism/ism_rx.sh"
fi

# ── serie : poser le debit (le backend lit/ecrit ensuite en brut) ─────────────
if [ "$LINK" = serial ]; then
    [ -e "$DEV" ] || warn "$DEV absent pour l'instant (branche le module ISM)"
    if [ -e "$DEV" ]; then
        stty -F "$DEV" "$BAUD" cs8 -cstopb -parenb -echo raw 2>/dev/null \
            && say "serie $DEV a $BAUD bauds, mode brut" \
            || warn "stty sur $DEV a echoue (droits ? module absent ?)"
    fi
fi

# ── composer la section [payload] ────────────────────────────────────────────
BLOCK="# ── PAYLOAD ISM ───────────────────────────────────────────────────────────
# Ecrit par network/setup-payload-ism.sh. Le texte des SMS part par radio ISM,
# la signalisation reste sur IP (cf. wiki/Payload-ISM.md).
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
