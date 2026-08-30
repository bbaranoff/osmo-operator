#!/bin/bash
# osmo-start.sh - Demarrage sequence du Core Osmocom
#
# Ordre de dependance :
#   STP (4239) → HLR (4258) → MGW (4243)
#                    ↓
#               MSC (4254) → BSC (4242)
#                    ↓
#          GGSN (4260) → SGSN (4245) → PCU (4239 bts)
#
# Chaque service attend le VTY du precedent avant de demarrer.
# BTS-TRX et SIP-connector sont geres par run.sh (dependent de fake_trx / Asterisk).
#
# Appele par : run.sh (etape 3)

set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

OPERATOR_ID="${OPERATOR_ID:-1}"

# ── Helper : attendre qu'un port TCP soit ouvert ──────────────────────────────
wait_port() {
    local host="$1" port="$2" label="$3" timeout="${4:-30}"
    local elapsed=0
    echo -ne "  Attente ${label} (${host}:${port})"
    while ! bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ── Helper : demarrer un service et verifier ──────────────────────────────────
start_svc() {
    local svc="$1" vty_port="$2" label="$3" timeout="${4:-30}"

    echo -e "  ${CYAN}${label}${NC}"
    # ── reset-failed AVANT start ────────────────────────────────────────────
    # systemd abandonne un service apres StartLimitBurst redemarrages (compteur
    # a 10 sur osmo-bsc). Une config refusee suffit a l'y amener en dix
    # secondes. Ensuite - et c'est le piege - REPARER LA CONFIG NE SUFFIT PLUS :
    # "systemctl start" rend "start request repeated too quickly" et le service
    # reste mort, sans que rien ne le relie a l'erreur d'origine. C'est ce qui
    # a laisse le BSC de l'operateur 1 eteint alors que son fichier etait
    # redevenu valide. On efface donc le compteur a chaque lancement : ce script
    # EST le geste de demarrage, il ne doit pas heriter des echecs d'hier.
    systemctl reset-failed "$svc" 2>/dev/null || true
    systemctl start "$svc" || {
        echo -e "    ${RED}✗ systemctl start ${svc} echoue${NC}"
        journalctl -u "$svc" -n 20 --no-pager >&2
        return 1
    }

    if [ -n "$vty_port" ]; then
        wait_port 127.0.0.1 "$vty_port" "$label VTY" "$timeout" || {
            echo -e "    ${YELLOW}[WARN] VTY :${vty_port} non accessible apres ${timeout}s${NC}" >&2
            journalctl -u "$svc" -n 10 --no-pager >&2
            return 1
        }
    fi
}

# ══════════════════════════════════════════════════════════════════════════════

echo -e "${GREEN}=== Core Osmocom - Op${OPERATOR_ID} ===${NC}"
echo ""

# ── 1. Reseau TUN (APN0 pour GGSN) ───────────────────────────────────────────
echo -e "${CYAN}[1/4] Interface TUN${NC}"
if ip link show apn0 > /dev/null 2>&1; then
    ip link del dev apn0
fi
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set dev apn0 up
echo -e "  ${GREEN}✓${NC} apn0 up"

# ── 2. Signalisation (STP → HLR → MGW) ───────────────────────────────────────
#
# STP doit etre pret en premier : tout le SS7 passe par lui.
# HLR doit etre pret avant MSC : MSC se connecte au HLR au demarrage.
# MGW doit etre pret avant MSC : MSC ouvre un MGCP vers MGW.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}[2/4] Signalisation (STP → HLR → MGW)${NC}"

start_svc osmo-stp  4239 "OsmoSTP"  30 || true
start_svc osmo-hlr  4258 "OsmoHLR"  30 || {
    echo -e "  ${RED}[ERR] HLR indispensable pour MSC - abandon${NC}"
    exit 1
}
start_svc osmo-mgw  4243 "OsmoMGW"  20 || true

# ── 3. Core Network (MSC → BSC) ──────────────────────────────────────────────
#
# MSC doit etre pret avant BSC : BSC se connecte au MSC via A-interface.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}[3/4] Core Network (MSC → BSC)${NC}"

start_svc osmo-msc  4254 "OsmoMSC"  30 || true
start_svc osmo-bsc  4242 "OsmoBSC"  30 || true

# ── 4. Data (GGSN → SGSN → PCU) ──────────────────────────────────────────────
echo ""
echo -e "${CYAN}[4/4] Data (GGSN → SGSN → PCU)${NC}"

start_svc osmo-ggsn 4260 "OsmoGGSN" 20 || true
start_svc osmo-sgsn 4245 "OsmoSGSN" 20 || true
start_svc osmo-pcu  ""   "OsmoPCU"  0  || true
start_svc osmo-sip-connector  ""   "OsmoSIPConnector"  0  || true
sleep 0.5
chmod 777 /tmp/pcu_bts 2>/dev/null || true

# NOTE : osmo-bts-trx et osmo-sip-connector sont intentionnellement
# absents ici. run.sh les demarre dans l'ordre correct :
#   fake_trx → wait_udp 5700 → osmo-bts-trx  (evite la race condition TRX)
#   Asterisk → osmo-sip-connector             (evite le MNCC connect avant SIP UP)

# ── Resume ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=== Verification ===${NC}"
SERVICES="osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu"
MORTS=""
for svc in $SERVICES; do
    if systemctl is-active --quiet "$svc"; then
        echo -e "  ${GREEN}✓${NC} ${svc}"
    else
        echo -e "  ${RED}✗${NC} ${svc}"
        MORTS="${MORTS} ${svc}"
    fi
done

echo ""
# Chaque start_svc porte un "|| true" : c'est voulu, un GGSN absent ne doit pas
# emporter le reste. Mais la ligne finale disait "Core Osmocom pret" meme avec
# osmo-msc et osmo-bsc en croix juste au-dessus - et c'est cette ligne-la qu'on
# lit. Un coeur sans MSC ne fait pas d'attachement : autant le dire ici plutot
# que de le decouvrir une heure plus tard dans "show bts".
if [ -n "$MORTS" ]; then
    echo -e "${RED}Coeur INCOMPLET -${NC}${MORTS}"
    for svc in $MORTS; do
        echo -e "  ${CYAN}journalctl -u ${svc} -n 30${NC}   ou   ${CYAN}tail -30 /var/log/osmocom/${svc}.log${NC}"
    done
    case "$MORTS" in
        *osmo-msc*|*osmo-bsc*)
            echo -e "  ${YELLOW}Sans MSC ni BSC, aucun mobile ne peut s'attacher.${NC}"
            echo -e "  ${YELLOW}Cause frequente : la config est refusee a la lecture. La ligne fautive${NC}"
            echo -e "  ${YELLOW}est nommee par :${NC} ${CYAN}osmo-msc -c /etc/osmocom/osmo-msc.cfg 2>&1 | grep -A2 'Error occurred'${NC}" ;;
    esac
else
    echo -e "${GREEN}Core Osmocom pret. BTS et SIP connector geres par run.sh.${NC}"
fi
