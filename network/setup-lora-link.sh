#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-lora-link.sh — le LIEN radio LoRa en interface IP (tnc0)
#
# Le module est un Heltec LoRa32 v3 (SX1262) sous firmware RNode, en mode TNC :
# il parle KISS sur l'USB (CP210x, 115200 bauds). tncattach l'attache comme
# interface réseau tnc0, nœud 1 = 10.200.0.1/24, nœud 2 = 10.200.0.2/24.
# L'aiguilleur (setup-lora-payload.sh, posé par start.sh --lora) route ensuite
# le payload (RTP, relais SMS) par cette interface.
#
#   sudo ./network/setup-lora-link.sh up --node 1|2 [--port /dev/ttyUSB0]
#   sudo ./network/setup-lora-link.sh --off          # retire tnc0 (tue tncattach)
#        ./network/setup-lora-link.sh --status       # interface, route, compteurs
#        ./network/setup-lora-link.sh --info [--port DEV]
#                                                    # paramètres radio (rnodeconf -i,
#                                                    # le port doit être libre)
# Variables (surchargables) :
#   LORA_PORT    port série ; sinon premier CP210x / CH9102 / CH340 de
#                /dev/serial/by-id, sinon /dev/ttyUSB0
#   LORA_DEV     tnc0        LORA_NET  10.200.0      LORA_BAUD  115200
#   LORA_MTU     (vide = défaut de tncattach) ; IPv6 est filtré (--noipv6) pour
#                ne pas brûler de temps d'antenne en ICMPv6/mDNS.
#
# Paramètres radio du module vérifié : 868,0 MHz, BW 500 kHz, SF7, CR5, 17 dBm,
# 21,88 kbit/s sur l'air (rnodeconf -i). Ils se changent avec rnodeconf, pas ici.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

LORA_DEV="${LORA_DEV:-tnc0}"
LORA_NET="${LORA_NET:-10.200.0}"
LORA_BAUD="${LORA_BAUD:-115200}"
LORA_MTU="${LORA_MTU:-}"
NODE=""; PORT="${LORA_PORT:-}"; ACTION=""

C_G='\033[0;32m'; C_C='\033[0;36m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_0='\033[0m'
msg(){ echo -e "$@"; }
need_root(){ [ "$(id -u)" = 0 ] || { msg "${C_R}À lancer en root (sudo).${C_0}"; exit 1; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        up|--up)            ACTION=up ;;
        off|--off|down)     ACTION=off ;;
        status|--status)    ACTION=status ;;
        info|--info)        ACTION=info ;;
        --node)   NODE="${2:-}"; shift ;;
        --node=*) NODE="${1#*=}" ;;
        --port)   PORT="${2:-}"; shift ;;
        --port=*) PORT="${1#*=}" ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) msg "${C_R}option inconnue : $1${C_0} (--help)"; exit 2 ;;
    esac
    shift
done
[ -n "$ACTION" ] || { msg "Usage: $0 up --node 1|2 [--port DEV] | --off | --status | --info"; exit 2; }

tnc_ip(){ ip -4 -o addr show "$LORA_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
running(){ pgrep -x tncattach >/dev/null 2>&1; }

find_port(){
    [ -n "$PORT" ] && { echo "$PORT"; return; }
    local p
    for p in /dev/serial/by-id/*CP210* /dev/serial/by-id/*CH9102* /dev/serial/by-id/*CH340* \
             /dev/serial/by-id/*Silicon_Labs* /dev/ttyUSB0 /dev/ttyACM0; do
        [ -e "$p" ] && { readlink -f "$p"; return; }
    done
    return 1
}

rnodeconf_bin(){
    command -v rnodeconf 2>/dev/null && return
    [ -x /root/.env/bin/rnodeconf ] && { echo /root/.env/bin/rnodeconf; return; }
    return 1
}

up(){
    need_root
    case "$NODE" in
        1|2) ;;
        "")  case "$(tnc_ip)" in "$LORA_NET.1") NODE=1 ;; "$LORA_NET.2") NODE=2 ;;
             *) msg "${C_R}--node 1 ou 2 obligatoire (tnc0 absente).${C_0}"; exit 2 ;; esac ;;
        *)   msg "${C_R}--node : 1 ou 2, pas '$NODE'.${C_0}"; exit 2 ;;
    esac
    local want="$LORA_NET.$NODE" have; have="$(tnc_ip)"
    if running && [ "$have" = "$want" ]; then
        msg "${C_G}✓ $LORA_DEV déjà montée en $have/24 (tncattach pid $(pgrep -x tncattach | head -1)).${C_0}"
        return 0
    fi
    if running; then
        msg "${C_Y}tncattach tourne avec $LORA_DEV = ${have:-sans adresse}, attendu $want : on le relance.${C_0}"
        pkill -x tncattach; sleep 1
    fi
    local port; port="$(find_port)" || {
        msg "${C_R}Aucun port série trouvé (RNode / Heltec V3 branché ? lsusb : CP210x). LORA_PORT=/dev/ttyUSBn ou --port.${C_0}"
        exit 1; }
    [ -c "$port" ] || { msg "${C_R}$port n'est pas un port série.${C_0}"; exit 1; }
    command -v tncattach >/dev/null || { msg "${C_R}tncattach absent : install.sh (install_modules/50-build.sh) le compile, ou github.com/markqvist/tncattach.${C_0}"; exit 1; }
    msg "${C_G}=== Lien LoRa : $port ($LORA_BAUD) -> $LORA_DEV = $want/24 (nœud $NODE) ===${C_0}"
    local extra=(); [ -n "$LORA_MTU" ] && extra=(--mtu "$LORA_MTU")
    # Sortie du démon dans un journal, pas sur notre stdout : -d garde ses
    # descripteurs ouverts, et un appelant qui capture la sortie (tube, tmux,
    # start.sh) attendrait la fin du démon.
    local log=/run/osmo-lora-link.log
    tncattach "$port" "$LORA_BAUD" --ipv4 "$want/24" --noipv6 "${extra[@]}" -d >"$log" 2>&1 \
        || { cat "$log"; msg "${C_R}tncattach a échoué (port occupé ? module pas en mode TNC ? --info pour voir).${C_0}"; exit 1; }
    local i; for i in 1 2 3 4 5 6; do [ "$(tnc_ip)" = "$want" ] && break; sleep 0.5; done
    [ "$(tnc_ip)" = "$want" ] || { msg "${C_R}$LORA_DEV n'est pas montée après tncattach.${C_0}"; exit 1; }
    ip -br addr show "$LORA_DEV"
    ip route show dev "$LORA_DEV"
    msg "${C_G}✓ Lien LoRa prêt : pair $LORA_NET.$((3 - NODE)) par $LORA_DEV.${C_0}  (état : $0 --status ; retrait : $0 --off)"
}

off(){
    need_root
    if running; then
        pkill -x tncattach; sleep 1
        running && pkill -9 -x tncattach
        msg "${C_G}✓ $LORA_DEV retirée (tncattach arrêté).${C_0}"
    else
        msg "tncattach ne tournait pas ; $LORA_DEV : $(ip -br link show "$LORA_DEV" 2>/dev/null || echo absente)"
    fi
}

status(){
    msg "${C_C}── tncattach ──${C_0}"; pgrep -ax tncattach || echo "(arrêté)"
    msg "${C_C}── $LORA_DEV ──${C_0}"; ip -br addr show "$LORA_DEV" 2>/dev/null || echo "(absente)"
    ip route show dev "$LORA_DEV" 2>/dev/null
    msg "${C_C}── compteurs ──${C_0}"; ip -s link show "$LORA_DEV" 2>/dev/null | sed -n '/RX:/,$p' || true
    local port; port="$(find_port 2>/dev/null)" && msg "${C_C}── port ──${C_0} $port"
}

info(){
    running && { msg "${C_R}tncattach tient le port : $0 --off d'abord, puis --info, puis up.${C_0}"; exit 1; }
    local rc; rc="$(rnodeconf_bin)" || { msg "${C_R}rnodeconf absent (pip install rns, venv /root/.env).${C_0}"; exit 1; }
    local port; port="$(find_port)" || { msg "${C_R}Aucun port série trouvé.${C_0}"; exit 1; }
    exec "$rc" -i "$port"
}

case "$ACTION" in
    up) up ;; off) off ;; status) status ;; info) info ;;
esac
