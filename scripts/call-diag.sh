#!/bin/bash
# call-diag.sh - Diagnostic chemin d'appel MS → Asterisk echo test
# Usage: sudo docker exec -ti osmo-operator-1 bash /scripts/call-diag.sh
#
# Verifie chaque maillon : MSC → MNCC → osmo-sip-connector → Asterisk

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }

echo -e "${CYAN}${BOLD}═══ Diagnostic appel MS → Echo Test ═══${NC}"
echo ""

# ── 1. Services core ─────────────────────────────────────────────────────────
echo -e "${BOLD}[1/8] Services Osmocom${NC}"
for svc in osmo-msc osmo-bsc osmo-mgw osmo-stp osmo-hlr; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc actif"
    elif pgrep -f "$svc" >/dev/null 2>&1; then
        ok "$svc (process)"
    else
        fail "$svc INACTIF"
    fi
done
echo ""

# ── 2. MNCC socket ──────────────────────────────────────────────────────────
echo -e "${BOLD}[2/8] MNCC socket (/tmp/msc_mncc)${NC}"
if [ -S /tmp/msc_mncc ]; then
    ok "Socket MNCC existe"
    ls -la /tmp/msc_mncc | sed 's/^/       /'
else
    fail "Socket MNCC ABSENT - MSC ne cree pas le socket MNCC external"
    echo "       Verifier que osmo-msc.cfg contient : mncc external /tmp/msc_mncc"
fi
echo ""

# ── 3. osmo-sip-connector ───────────────────────────────────────────────────
echo -e "${BOLD}[3/8] osmo-sip-connector${NC}"
if pgrep -f "osmo-sip-connector" >/dev/null 2>&1; then
    ok "Processus actif"
    pgrep -fa "osmo-sip-connector" | head -1 | sed 's/^/       /'
    
    # Verifier qu'il ecoute bien sur 5061
    if ss -tlnp 2>/dev/null | grep -q ":5061 "; then
        ok "Ecoute sur :5061 (cote SIP)"
    else
        warn "Pas en ecoute sur :5061"
    fi
else
    fail "osmo-sip-connector NON LANCE"
    echo ""
    echo "       C'est le pont MNCC ↔ SIP. Sans lui, aucun appel ne passe."
    echo "       Fix: systemctl start osmo-sip-connector"
    echo "       Ou:  osmo-sip-connector -c /etc/osmocom/osmo-sip-connector.cfg &"
fi
echo ""

# ── 4. Asterisk ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4/8] Asterisk${NC}"
if pgrep -f "asterisk" >/dev/null 2>&1; then
    ok "Processus actif"
    
    if ss -ulnp 2>/dev/null | grep -q ":5060 "; then
        ok "Ecoute SIP sur :5060/udp"
    else
        fail "Pas en ecoute sur :5060/udp"
    fi
    
    # Verifier les endpoints PJSIP
    echo "       Endpoints PJSIP:"
    asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -E "Endpoint:|Contact:" | head -10 | sed 's/^/       /' || warn "Impossible de lister les endpoints"
    
    # Verifier que le dialplan a le 600
    echo ""
    echo "       Dialplan 600:"
    asterisk -rx "dialplan show 600@gsm_in" 2>/dev/null | head -10 | sed 's/^/       /' || warn "Extension 600 introuvable dans gsm_in"
else
    fail "Asterisk NON LANCE"
    echo "       Fix: asterisk -cvvv &"
fi
echo ""

# ── 5. osmo-sip-connector config ────────────────────────────────────────────
echo -e "${BOLD}[5/8] Config osmo-sip-connector${NC}"
SIP_CFG="/etc/osmocom/osmo-sip-connector.cfg"
if [ -f "$SIP_CFG" ]; then
    echo "       Contenu:"
    cat "$SIP_CFG" | sed 's/^/       /'
    
    remote_line=$(grep "remote" "$SIP_CFG" | head -1)
    echo ""
    if echo "$remote_line" | grep -q "5060"; then
        ok "Remote SIP pointe vers :5060"
    else
        warn "Remote SIP: $remote_line"
    fi
else
    fail "Config osmo-sip-connector introuvable"
fi
echo ""

# ── 6. MGW ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}[6/8] OsmoMGW (RTP)${NC}"
if bash -c "echo >/dev/tcp/127.0.0.1/4243" 2>/dev/null; then
    ok "VTY 4243 accessible"
    echo "       Endpoints:"
    (echo "show mgcp"; sleep 1) | telnet 127.0.0.1 4243 2>/dev/null \
        | grep -vE "^(Trying|Connected|Escape|Welcome|OsmoMGW)" \
        | head -15 | sed 's/^/       /' || true
else
    fail "VTY MGW 4243 inaccessible"
fi
echo ""

# ── 7. BTS-TRX ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[7/8] osmo-bts-trx${NC}"
if pgrep -f "osmo-bts-trx" >/dev/null 2>&1; then
    ok "Processus actif"
else
    if systemctl is-active --quiet osmo-bts-trx 2>/dev/null; then
        ok "Service actif"
    else
        fail "osmo-bts-trx INACTIF"
        echo "       Sans BTS, pas de canal radio → pas d'appel"
        echo "       Fix: systemctl start osmo-bts-trx"
    fi
fi
echo ""

# ── 8. Mobile registration ──────────────────────────────────────────────────
echo -e "${BOLD}[8/8] Enregistrement mobile (MSC VTY)${NC}"
MSC_OUT=$( (echo "enable"; echo "show subscriber all"; sleep 1; echo "exit") \
    | telnet 127.0.0.1 4254 2>/dev/null \
    | grep -vE "^(Trying|Connected|Escape|Welcome|OsmoMSC)" || true)

if echo "$MSC_OUT" | grep -qiE "IMSI|subscriber"; then
    ok "Abonnes enregistres sur le MSC:"
    echo "$MSC_OUT" | grep -iE "IMSI|MSISDN|LAC" | head -10 | sed 's/^/       /'
else
    warn "Aucun abonne enregistre sur le MSC"
    echo "       Les MS ne sont pas encore attaches au reseau"
    echo "       Verifier : dans le VTY mobile → show ms"
    echo "       L'etat doit etre 'NORMAL service'"
fi
echo ""

# ── Resume ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══ Chaine d'appel echo test ═══${NC}"
echo ""
echo "  mobile (call 1 600)"
echo "    ↓ TCH via fake_trx"
echo "  osmo-bts-trx → osmo-bsc → osmo-msc"
echo "    ↓ MNCC socket /tmp/msc_mncc"

if [ -S /tmp/msc_mncc ]; then
    echo -e "    ${GREEN}✓${NC} MNCC socket"
else
    echo -e "    ${RED}✗ MNCC socket MANQUANT${NC}"
fi

echo "  osmo-sip-connector (5061 → 5060)"
if pgrep -f "osmo-sip-connector" >/dev/null 2>&1; then
    echo -e "    ${GREEN}✓${NC} sip-connector"
else
    echo -e "    ${RED}✗ sip-connector MANQUANT ← PROBLEME PROBABLE${NC}"
fi

echo "  Asterisk (gsm_in context, exten 600 → Echo())"
if pgrep -f "asterisk" >/dev/null 2>&1; then
    echo -e "    ${GREEN}✓${NC} Asterisk"
else
    echo -e "    ${RED}✗ Asterisk MANQUANT${NC}"
fi

echo "    ↓ RTP via OsmoMGW"
echo "  osmo-bts-trx → fake_trx → trxcon → mobile"
echo "    ↓ l1phy decode TCH-FR"
echo "  ALSA → PulseAudio → HP"
echo ""
