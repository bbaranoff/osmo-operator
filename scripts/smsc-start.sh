#!/bin/bash
# smsc-start.sh - Lance le proto-smsc-daemon + le relay interop
# Fix: attente HLR GSUP robuste + verification socket sendmt avec retry

set -euo pipefail

OPERATOR_ID="${OPERATOR_ID:-1}"
HLR_IP="${HLR_IP:-127.0.0.2}"
SMSC_IPA_NAME="SMSC-OP${OPERATOR_ID}"
MO_LOG="/var/log/osmocom/mo-sms-op${OPERATOR_ID}.log"
SENDMT_SOCKET="/tmp/sendmt_socket"
ROUTING_CONF="/etc/osmocom/sms-routing.conf"
RELAY_PORT="${RELAY_PORT:-7890}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  SMS Gateway - Operateur ${OPERATOR_ID}                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  HLR        : ${CYAN}${HLR_IP}${NC}"
echo -e "  IPA name   : ${CYAN}${SMSC_IPA_NAME}${NC}"
echo -e "  MO log     : ${CYAN}${MO_LOG}${NC}"
echo -e "  MT socket  : ${CYAN}${SENDMT_SOCKET}${NC}"
echo -e "  Relay port : ${CYAN}${RELAY_PORT}${NC}"
echo -e "  Routing    : ${CYAN}${ROUTING_CONF}${NC}"

rm -f "$SENDMT_SOCKET"
mkdir -p /var/log/osmocom

# ── Attente HLR GSUP (port 4222) - robuste ──────────────────────────────────
echo -ne "${YELLOW}[SMSC] Attente OsmoHLR GSUP (4222)"
retries=60
while [ $retries -gt 0 ]; do
    if bash -c "echo >/dev/tcp/${HLR_IP}/4222" 2>/dev/null; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    # Fallback: verifier aussi via ss
    if ss -tln 2>/dev/null | grep -q ":4222 "; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    echo -n "."
    sleep 1
    retries=$(( retries - 1 ))
done
if [ $retries -eq 0 ]; then
    echo -e " ${RED}TIMEOUT - HLR non disponible${NC}"
    echo -e "${YELLOW}[SMSC] Tentative de demarrage quand meme...${NC}"
fi

sleep 3

# ── 1. proto-smsc-daemon (background) ────────────────────────────────────────
echo -e "${GREEN}[1/2] proto-smsc-daemon${NC}"

# Verifier que le binaire existe
if ! command -v proto-smsc-daemon >/dev/null 2>&1; then
    echo -e "  ${RED}proto-smsc-daemon introuvable dans PATH${NC}"
    echo -e "  ${YELLOW}SMS local uniquement via MSC VTY${NC}"
    # Lancer quand meme le relay pour les SMS entrants via TCP
else
    proto-smsc-daemon "$HLR_IP" "$SMSC_IPA_NAME" "$MO_LOG" "$SENDMT_SOCKET" &
    DAEMON_PID=$!
    echo -e "  PID: ${CYAN}${DAEMON_PID}${NC}"

    # Attente du socket sendmt avec timeout
    echo -ne "  Socket sendmt"
    for i in $(seq 1 30); do
        if [ -S "$SENDMT_SOCKET" ]; then
            echo -e " ${GREEN}✓${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
    if [ ! -S "$SENDMT_SOCKET" ]; then
        echo -e " ${YELLOW}non cree (les MT SMS ne fonctionneront pas)${NC}"
    fi
fi

# ── 2. Relay interop (background) ────────────────────────────────────────────
echo -e "${GREEN}[2/2] sms-interop-relay${NC}"

# Verifier que le script existe
RELAY_SCRIPT="/etc/osmocom/sms-interop-relay.py"
if [ ! -f "$RELAY_SCRIPT" ]; then
    echo -e "  ${RED}${RELAY_SCRIPT} introuvable${NC}"
    echo -e "  ${YELLOW}SMS inter-operateur desactive${NC}"
else
    # --node-id : la cle de routage de sms-routing.conf est le NOEUD, pas
    # l'operateur (MSISDN = <noeud>00<operateur><rang>). Sans elle, le relais
    # tient pour locaux les numeros des autres noeuds et n'emet jamais.
    python3 "$RELAY_SCRIPT" \
        --config "$ROUTING_CONF" \
        --port "$RELAY_PORT" \
        --mo-log "$MO_LOG" \
        --operator-id "$OPERATOR_ID" \
        --node-id "${OSMO_WAN_NODE:-${WAN_NODE_ID:-1}}" &
    RELAY_PID=$!
    echo -e "  PID: ${CYAN}${RELAY_PID}${NC}"

    # Verifier que le port TCP est en ecoute
    echo -ne "  Relay TCP ${RELAY_PORT}"
    for i in $(seq 1 15); do
        if ss -tlnp 2>/dev/null | grep -q ":${RELAY_PORT} "; then
            echo -e " ${GREEN}✓${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SMS Gateway actif - Op${OPERATOR_ID}${NC}"
echo -e "${GREEN}  MT local : send-mt-sms.sh <imsi> 'msg'${NC}"
echo -e "${GREEN}  MO log   : tail -f ${MO_LOG}${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"

cleanup() {
    echo -e "\n${YELLOW}[SMSC] Arret...${NC}"
    [ -n "${DAEMON_PID:-}" ] && kill $DAEMON_PID 2>/dev/null || true
    [ -n "${RELAY_PID:-}" ] && kill $RELAY_PID 2>/dev/null || true
    rm -f "$SENDMT_SOCKET"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Attendre fin d'un processus
if [ -n "${DAEMON_PID:-}" ] && [ -n "${RELAY_PID:-}" ]; then
    wait -n $DAEMON_PID $RELAY_PID 2>/dev/null || true
elif [ -n "${DAEMON_PID:-}" ]; then
    wait $DAEMON_PID 2>/dev/null || true
elif [ -n "${RELAY_PID:-}" ]; then
    wait $RELAY_PID 2>/dev/null || true
else
    # Aucun processus a attendre - juste dormir
    while true; do sleep 60; done
fi

echo -e "${YELLOW}[SMSC] Processus termine, arret...${NC}"
cleanup
