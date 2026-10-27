#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# launch/osmo-launch.sh - osmo-operator orchestrator (lab + web dashboard).
# Installed in the ISO as /opt/osmo-launch.sh (symlink /usr/local/bin/osmo-launch).
#
# Usage:
#   sudo /opt/osmo-launch.sh           # start everything (interactive)
#   sudo /opt/osmo-launch.sh --auto    # start with defaults (2 operators, 8 MS)
#   sudo /opt/osmo-launch.sh stop      # stop everything (native + lab + web)
#   sudo /opt/osmo-launch.sh restart   # stop then start
#   sudo /opt/osmo-launch.sh status    # service status
#   sudo /opt/osmo-launch.sh web-only  # start the dashboard only
#
# Environment variables:
#   OSMO_BANC_SERVICE  systemd unit of the native operator (default osmo-banc.service)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

LAB_DIR="/opt/GSM/osmo-operator"
WEB_DIR="/opt/GSM/osmo-egprs-web"
WEB_SERVICE="osmo-egprs-web"
LOG_DIR="/var/log/osmocom"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

mkdir -p "$LOG_DIR"

# ══════════════════════════════════════════════════════════════════════════════
banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  osmo-operator - GSM/EGPRS Multi-PLMN + Web Dashboard          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
wait_docker() {
    echo -ne "  Docker daemon"
    local i=0
    while ! docker info &>/dev/null; do
        sleep 1; echo -n "."; i=$((i+1))
        [ $i -ge 30 ] && { echo -e " ${RED}TIMEOUT${NC}"; return 1; }
    done
    echo -e " ${GREEN}OK${NC}"
}

wait_operators() {
    local timeout="${1:-120}"
    echo -ne "  Containers operateurs"
    local i=0
    while [ "$(docker ps --filter 'name=osmo-operator-' --format '{{.Names}}' 2>/dev/null | wc -l)" -eq 0 ]; do
        sleep 2; echo -n "."; i=$((i+2))
        [ $i -ge "$timeout" ] && { echo -e " ${RED}TIMEOUT${NC}"; return 1; }
    done
    local n=$(docker ps --filter 'name=osmo-operator-' --format '{{.Names}}' | wc -l)
    echo -e " ${GREEN}${n} operateur(s) detectes${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
start_web() {
    echo -e "${GREEN}[web] Demarrage dashboard...${NC}"

    if [ -f "$WEB_DIR/server.js" ] && command -v node &>/dev/null; then
        # Native mode (local Node.js)
        systemctl restart "$WEB_SERVICE" 2>/dev/null && {
            echo -e "  ${GREEN}✓${NC} systemd: $WEB_SERVICE actif (port 8080)"
            return 0
        }
        # Fallback when the systemd service does not exist
        echo -e "  ${YELLOW}Service systemd absent, lancement direct...${NC}"
        cd "$WEB_DIR"
        node server.js --verbose >> "$LOG_DIR/web-dashboard.log" 2>&1 &
        echo $! > /var/run/osmo-egprs-web.pid
        echo -e "  ${GREEN}✓${NC} Dashboard lance (PID $(cat /var/run/osmo-egprs-web.pid))"

    elif [ -f "$WEB_DIR/Dockerfile" ] || [ -f "$WEB_DIR/start-web.sh" ]; then
        # Mode Docker
        if [ -f "$WEB_DIR/start-web.sh" ]; then
            bash "$WEB_DIR/start-web.sh"
        else
            docker rm -f osmo-egprs-web 2>/dev/null || true
            docker build -t osmo-egprs-web "$WEB_DIR"
            docker run -d \
                --name osmo-egprs-web \
                --network host \
                --cap-add=NET_RAW --cap-add=NET_ADMIN \
                -v /var/run/docker.sock:/var/run/docker.sock:ro \
                -e CONTAINER_PREFIX=osmo-operator- \
                --restart unless-stopped \
                osmo-egprs-web
        fi
        echo -e "  ${GREEN}✓${NC} Dashboard Docker lance (port 80)"
    else
        echo -e "  ${RED}✗${NC} Dashboard introuvable dans $WEB_DIR"
        return 1
    fi
}

stop_web() {
    echo -e "${YELLOW}[web] Arret dashboard...${NC}"
    systemctl stop "$WEB_SERVICE" 2>/dev/null || true
    [ -f /var/run/osmo-egprs-web.pid ] && {
        kill "$(cat /var/run/osmo-egprs-web.pid)" 2>/dev/null || true
        rm -f /var/run/osmo-egprs-web.pid
    }
    docker rm -f osmo-egprs-web 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Dashboard arrete"
}

# ══════════════════════════════════════════════════════════════════════════════
start_lab() {
    echo -e "${GREEN}[lab] Demarrage osmo-operator...${NC}"

    if [ ! -f "$LAB_DIR/launch/start-docker.sh" ]; then
        echo -e "  ${RED}✗${NC} $LAB_DIR/launch/start-docker.sh introuvable"
        return 1
    fi

    cd "$LAB_DIR"
    bash ./launch/start-docker.sh
}

# ── Native operator ────────────────────────────────────────────────────────
# The native operator runs in osmo-banc.service (start-native.sh, tmux session
# "calypso") and holds ports 5060 and 8080; `stop` must stop it as well as the
# containers (same as launch.sh --stop). The unit delegates to
# start-native.sh --stop. Native side first, then containers (clean shutdown order).
stop_natif() {
    local u="${OSMO_BANC_SERVICE:-osmo-banc.service}"
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0
    systemctl cat "$u" >/dev/null 2>&1 || return 0
    echo -e "${YELLOW}[natif] Arret ${u}...${NC}"
    timeout 200 systemctl stop "$u" >/dev/null 2>&1 || true
    # ExecStop does not run on a "failed" unit: the core, started by run.sh in
    # its own units, would stay up.
    systemctl stop osmo-egprs-web.service osmo-hlr.service >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓${NC} Natif arrete"
}

stop_lab() {
    echo -e "${YELLOW}[lab] Arret osmo-operator...${NC}"
    if [ -f "$LAB_DIR/launch/start-docker.sh" ]; then
        cd "$LAB_DIR"
        bash ./launch/start-docker.sh stop
    fi
    # Full cleanup in case start-docker.sh stop is not enough
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Lab arrete"
}

# ══════════════════════════════════════════════════════════════════════════════
show_status() {
    echo -e "${CYAN}${BOLD}── Etat des services ──${NC}"
    echo ""

    # Docker
    if docker info &>/dev/null; then
        echo -e "  Docker       : ${GREEN}●${NC} actif"
    else
        echo -e "  Docker       : ${RED}●${NC} arrete"
    fi

    # Containers
    local ops=$(docker ps --filter 'name=osmo-operator-' --format '{{.Names}}' 2>/dev/null | sort)
    local n_ops=$(echo "$ops" | grep -c . 2>/dev/null || echo 0)
    if [ "$n_ops" -gt 0 ]; then
        echo -e "  Operateurs   : ${GREEN}●${NC} ${n_ops} actif(s)"
        echo "$ops" | while read -r c; do
            echo -e "                 ${CYAN}└─${NC} $c"
        done
    else
        echo -e "  Operateurs   : ${RED}●${NC} aucun"
    fi

    # Inter-STP
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q osmo-inter-stp; then
        echo -e "  Inter-STP    : ${GREEN}●${NC} actif"
    else
        echo -e "  Inter-STP    : ${RED}●${NC} arrete"
    fi

    # Web dashboard
    if systemctl is-active --quiet "$WEB_SERVICE" 2>/dev/null; then
        echo -e "  Dashboard    : ${GREEN}●${NC} systemd (port 8080)"
    elif [ -f /var/run/osmo-egprs-web.pid ] && kill -0 "$(cat /var/run/osmo-egprs-web.pid 2>/dev/null)" 2>/dev/null; then
        echo -e "  Dashboard    : ${GREEN}●${NC} PID $(cat /var/run/osmo-egprs-web.pid) (port 8080)"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q osmo-egprs-web; then
        echo -e "  Dashboard    : ${GREEN}●${NC} Docker (port 80)"
    else
        echo -e "  Dashboard    : ${RED}●${NC} arrete"
    fi

    # IPs
    echo ""
    local host_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -n "$host_ip" ] && echo -e "  Host IP      : ${CYAN}${host_ip}${NC}"
    echo -e "  Dashboard    : ${CYAN}http://${host_ip:-localhost}:8080${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
do_start() {
    banner

    # 1. Docker
    echo -e "${GREEN}[1/3] Verification Docker...${NC}"
    systemctl start docker 2>/dev/null || true
    wait_docker || { echo -e "${RED}Docker necessaire.${NC}"; exit 1; }

    # 2. Lab
    echo ""
    echo -e "${GREEN}[2/3] Lab multi-operateurs...${NC}"
    start_lab

    # 3. Web (wait for the containers to be up)
    echo ""
    echo -e "${GREEN}[3/3] Dashboard web...${NC}"
    wait_operators 180 || true
    start_web || true

    # Summary
    echo ""
    show_status
    echo -e "${GREEN}${BOLD}Pret !${NC}"
}

do_auto() {
    banner
    echo -e "${YELLOW}Mode automatique (defauts)${NC}"
    echo ""

    systemctl start docker 2>/dev/null || true
    wait_docker || exit 1

    # Run start-docker.sh non-interactively by piping default answers to its prompts
    cd "$LAB_DIR"
    {
        echo "2"       # bridge mode
        echo "2"       # 2 operators
        echo "o"       # default values
        echo "8"       # 8 MS
        echo "N"       # no WAN
        echo "1"       # faketrx
        echo "0"       # A5/0
    } | bash ./launch/start-docker.sh

    wait_operators 180 || true
    start_web || true

    echo ""
    show_status
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
CMD="${1:-}"

case "$CMD" in
    stop)
        banner
        stop_web
        stop_natif
        stop_lab
        echo -e "\n${GREEN}Tout arrete.${NC}"
        ;;
    status)
        banner
        show_status
        ;;
    web-only)
        banner
        systemctl start docker 2>/dev/null || true
        wait_docker || exit 1
        start_web
        ;;
    --auto)
        do_auto
        ;;
    restart)
        banner
        stop_web
        stop_natif
        stop_lab
        sleep 3
        do_start
        ;;
    help|-h|--help)
        echo "Usage: $0 [commande]"
        echo ""
        echo "  (rien)    Lancement interactif (lab + web)"
        echo "  --auto    Lancement automatique (2 ops, 8 MS, defauts)"
        echo "  stop      Arrete tout (natif + lab + web + containers)"
        echo "  restart   Redemarre tout"
        echo "  status    Etat des services"
        echo "  web-only  Lance uniquement le dashboard web"
        echo "  help      Ce message"
        ;;
    *)
        do_start
        ;;
esac
