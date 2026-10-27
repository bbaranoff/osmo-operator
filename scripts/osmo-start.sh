#!/bin/bash
# osmo-start.sh - sequenced start of the Osmocom core
#
# Dependency order:
#   STP (4239) → HLR (4258) → MGW (4243)
#                    ↓
#               MSC (4254) → BSC (4242)
#                    ↓
#          GGSN (4260) → SGSN (4245) → PCU (4239 bts)
#
# Each service waits for the VTY of the previous one before starting.
# BTS-TRX and SIP-connector are handled by run.sh (they depend on fake_trx / Asterisk).
#
# Called by: run.sh (step 3)

set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

OPERATOR_ID="${OPERATOR_ID:-1}"

# ── Helper: wait for a TCP port to be open ───────────────────────────────────
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

# ── Helper: start a service and check it ────────────────────────────────────
start_svc() {
    local svc="$1" vty_port="$2" label="$3" timeout="${4:-30}"

    echo -e "  ${CYAN}${label}${NC}"
    # ── reset-failed before start ───────────────────────────────────────────
    # systemd gives up on a service after StartLimitBurst restarts (10 on
    # osmo-bsc); a rejected config gets there in ten seconds. Afterwards fixing
    # the config is not enough: "systemctl start" answers "start request
    # repeated too quickly" and the service stays dead. The counter is therefore
    # cleared at each launch: this script is the start action, it must not
    # inherit earlier failures.
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

# ── 1. TUN network (APN0 for GGSN) ───────────────────────────────────────────
echo -e "${CYAN}[1/4] Interface TUN${NC}"
if ip link show apn0 > /dev/null 2>&1; then
    ip link del dev apn0
fi
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set dev apn0 up
echo -e "  ${GREEN}✓${NC} apn0 up"

# ── 2. Signalling (STP → HLR → MGW) ──────────────────────────────────────────
#
# STP must be ready first: all SS7 goes through it.
# HLR must be ready before MSC: MSC connects to the HLR at startup.
# MGW must be ready before MSC: MSC opens an MGCP connection to the MGW.
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
# MSC must be ready before BSC: BSC connects to the MSC over the A interface.
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

# NOTE: osmo-bts-trx and osmo-sip-connector are intentionally absent here.
# run.sh starts them in the right order:
#   fake_trx → wait_udp 5700 → osmo-bts-trx  (avoids the TRX race condition)
#   Asterisk → osmo-sip-connector             (avoids MNCC connect before SIP UP)

# ── Summary ───────────────────────────────────────────────────────────────────
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
# Each start_svc carries a "|| true": intended, a missing GGSN must not take
# the rest down. The final line must still reflect dead services: a core
# without MSC does no attach, so it is said here rather than discovered later
# in "show bts".
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
