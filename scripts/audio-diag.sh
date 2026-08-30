#!/bin/bash
# audio-diag.sh - Diagnostic audio complet dans le container
# Usage : docker exec -ti osmo-operator-1 bash /etc/osmocom/audio-diag.sh
#
# Verifie toute la chaine : /dev/snd → ALSA → PulseAudio → mobile l1phy

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  Diagnostic audio - container $(hostname)${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${NC}"
echo ""

# ── 1. /dev/snd ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1/7] /dev/snd${NC}"
if [ -d /dev/snd ]; then
    ok "/dev/snd present"
    ls -la /dev/snd/ 2>/dev/null | sed 's/^/       /'
else
    fail "/dev/snd ABSENT - le container n'a pas --device /dev/snd"
    echo "       Fix: ajouter --device /dev/snd au docker run"
fi
echo ""

# ── 2. ALSA ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}[2/7] ALSA${NC}"
if command -v aplay >/dev/null 2>&1; then
    ok "aplay disponible"
    echo "       Cartes:"
    cat /proc/asound/cards 2>/dev/null | sed 's/^/       /' || fail "pas de /proc/asound/cards"
    echo ""
    echo "       Devices playback:"
    aplay -l 2>/dev/null | grep "^card" | sed 's/^/       /' || warn "aucun device playback"
    echo ""
    echo "       Devices capture:"
    arecord -l 2>/dev/null | grep "^card" | sed 's/^/       /' || warn "aucun device capture"
else
    fail "aplay non installe"
fi
echo ""

# ── 3. PulseAudio ────────────────────────────────────────────────────────────
echo -e "${BOLD}[3/7] PulseAudio${NC}"
if [ -n "${PULSE_SERVER:-}" ]; then
    ok "PULSE_SERVER=${PULSE_SERVER}"
    # Tester la connexion
    if command -v pactl >/dev/null 2>&1; then
        if pactl info >/dev/null 2>&1; then
            ok "PulseAudio accessible"
            pactl info 2>/dev/null | grep -E "Server|Default Sink|Default Source" | sed 's/^/       /'
        else
            fail "PulseAudio inaccessible (socket monte mais serveur non joignable)"
        fi
    else
        warn "pactl non installe - impossible de verifier PulseAudio"
        echo "       Le socket est monte mais on ne peut pas tester sans pactl"
        if [ -S "${PULSE_SERVER#unix:}" ] 2>/dev/null; then
            ok "Socket PulseAudio existe : ${PULSE_SERVER#unix:}"
        else
            fail "Socket PulseAudio introuvable"
        fi
    fi
else
    warn "PULSE_SERVER non defini"
    echo "       Sans PulseAudio, ALSA utilise directement hw:X,Y"
    echo "       Sur un desktop Linux moderne, le son passe par PulseAudio/PipeWire"
fi
echo ""

# ── 4. Variables ALSA ────────────────────────────────────────────────────────
echo -e "${BOLD}[4/7] Variables d'environnement${NC}"
echo "       ALSA_CARD     = ${ALSA_CARD:-<non defini>}"
echo "       GAPK_ALSA_DEV = ${GAPK_ALSA_DEV:-<non defini>}"
echo "       ALSA_OUTPUT   = ${ALSA_OUTPUT:-<non defini>}"
echo "       ALSA_INPUT    = ${ALSA_INPUT:-<non defini>}"
echo "       PULSE_SERVER  = ${PULSE_SERVER:-<non defini>}"
echo ""

# ── 5. mobile.cfg tch-voice ──────────────────────────────────────────────────
echo -e "${BOLD}[5/7] mobile.cfg tch-voice${NC}"
for cfg in /root/.osmocom/bb/mobile_group*.cfg /root/.osmocom/bb/mobile.cfg; do
    [ -f "$cfg" ] || continue
    echo "       ${cfg}:"
    if grep -q "io-handler l1phy" "$cfg" 2>/dev/null; then
        ok "io-handler l1phy"
        grep -E "alsa-(output|input)-dev" "$cfg" 2>/dev/null | sed 's/^/       /'
    elif grep -q "io-handler gapk" "$cfg" 2>/dev/null; then
        warn "io-handler gapk (audio via osmo-gapk, pas ALSA direct)"
    else
        warn "pas de bloc tch-voice - pas d'audio MS"
    fi
    break
done
echo ""

# ── 6. Test ALSA rapide ─────────────────────────────────────────────────────
echo -e "${BOLD}[6/7] Test ALSA (bip 440Hz 0.2s)${NC}"
if [ -d /dev/snd ]; then
    if command -v speaker-test >/dev/null 2>&1; then
        echo "       Tentative speaker-test (2 secondes max)..."
        timeout 2 speaker-test -t sine -f 440 -l 1 -P 1 2>&1 | head -5 | sed 's/^/       /' || warn "speaker-test echoue"
    elif command -v aplay >/dev/null 2>&1; then
        # Generer un bip court
        python3 -c "
import struct, sys
rate=8000; dur=0.2; freq=440
samples = [int(32767 * __import__('math').sin(2*3.14159*freq*t/rate)) for t in range(int(rate*dur))]
header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36+len(samples)*2, b'WAVE', b'fmt ', 16, 1, 1, rate, rate*2, 2, 16, b'data', len(samples)*2)
sys.stdout.buffer.write(header + struct.pack('<%dh'%len(samples), *samples))
" 2>/dev/null | aplay -q 2>/dev/null && ok "Bip joue sur ALSA" || warn "aplay a echoue"
    fi
else
    fail "Pas de /dev/snd - test impossible"
fi
echo ""

# ── 7. Processus audio ──────────────────────────────────────────────────────
echo -e "${BOLD}[7/7] Processus audio actifs${NC}"
if pgrep -fa "mobile.*mobile" >/dev/null 2>&1; then
    ok "Processus mobile actif"
    pgrep -fa "mobile" 2>/dev/null | head -3 | sed 's/^/       /'
else
    warn "Processus mobile non detecte (pas encore demarre ?)"
fi
if pgrep -fa "osmo-gapk" >/dev/null 2>&1; then
    ok "osmo-gapk actif"
    pgrep -fa "osmo-gapk" 2>/dev/null | head -3 | sed 's/^/       /'
else
    echo "       osmo-gapk non actif (normal si l1phy utilise)"
fi
echo ""

# ── Resume ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══ Resume ═══${NC}"
ISSUES=0

if [ ! -d /dev/snd ]; then
    fail "BLOQUANT: /dev/snd absent → pas d'audio possible"
    echo "       Fix: dans start.sh, verifier que --device /dev/snd est dans le docker run"
    ISSUES=$((ISSUES+1))
fi

if [ -z "${PULSE_SERVER:-}" ] && [ -d /dev/snd ]; then
    warn "PulseAudio non configure"
    echo "       Sur un desktop moderne, le device 'default' ALSA necessite PulseAudio"
    echo "       Fix 1: monter le socket PulseAudio dans le container :"
    echo "         -v /run/user/\$(id -u)/pulse/native:/run/user/1000/pulse/native"
    echo "         -e PULSE_SERVER=unix:/run/user/1000/pulse/native"
    echo "       Fix 2: utiliser un device ALSA direct (bypass PulseAudio) :"
    echo "         Trouver le device: aplay -l"
    echo "         Puis: ALSA_OUTPUT=hw:0,0 ALSA_INPUT=hw:0,0 dans start.sh"
    ISSUES=$((ISSUES+1))
fi

if [ -n "${PULSE_SERVER:-}" ]; then
    pulse_sock="${PULSE_SERVER#unix:}"
    if [ ! -S "$pulse_sock" ] 2>/dev/null; then
        fail "Socket PulseAudio monte mais fichier inexistant: $pulse_sock"
        echo "       Le socket PulseAudio de l'hote n'est pas accessible dans le container"
        echo "       Verifier le -v dans le docker run"
        ISSUES=$((ISSUES+1))
    fi
fi

if [ $ISSUES -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}Audio devrait fonctionner${NC}"
    echo "       Tester: depuis le VTY mobile → call 1 600"
    echo "       Le son sort sur les HP de l'hote via /dev/snd"
fi
echo ""
