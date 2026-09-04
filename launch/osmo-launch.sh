#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# /opt/osmo-launch.sh - Orchestrateur osmo-operator (lab + web dashboard)
#
# Usage :
#   sudo /opt/osmo-launch.sh           # lance tout (interactif)
#   sudo /opt/osmo-launch.sh --auto    # lance avec les defauts (2 ops, 8 MS)
#   sudo /opt/osmo-launch.sh stop      # arrete tout
#   sudo /opt/osmo-launch.sh status    # etat des services
#   sudo /opt/osmo-launch.sh web-only  # lance uniquement le dashboard
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
        # Mode natif (Node.js local)
        systemctl restart "$WEB_SERVICE" 2>/dev/null && {
            echo -e "  ${GREEN}✓${NC} systemd: $WEB_SERVICE actif (port 8080)"
            return 0
        }
        # Fallback si le service systemd n'existe pas
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

    if [ ! -f "$LAB_DIR/start.sh" ]; then
        echo -e "  ${RED}✗${NC} $LAB_DIR/start.sh introuvable"
        return 1
    fi

    cd "$LAB_DIR"
    bash ./start.sh
}

# ── LE NATIF AUSSI ──────────────────────────────────────────────────────────
# [2026-09-04] `osmo-launch stop` promet « arrete tout » et balayait bien les
# conteneurs - mais pas l operateur NATIF, qui vit dans osmo-banc.service
# (start-direct.sh, session tmux « calypso »). On arretait donc la moitie du
# banc : le coeur natif (osmo-stp, hlr, msc, bsc, asterisk) restait debout, et
# c est LUI qui tient le 5060 et le 8080 que le lancement suivant reclame.
# Symetrique de launch.sh --stop, qui arrete desormais les deux cotes.
#
# D ABORD LE NATIF, ENSUITE LES CONTENEURS : l unite delegue a
# start-direct.sh --stop, qui demonte radio et coeur proprement ; le faire
# apres un `docker rm -f` ne changerait rien pour lui, mais l ordre inverse est
# celui de l arret propre et c est celui qu on garde partout.
stop_natif() {
    local u="${OSMO_BANC_SERVICE:-osmo-banc.service}"
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0
    systemctl cat "$u" >/dev/null 2>&1 || return 0
    echo -e "${YELLOW}[natif] Arret ${u}...${NC}"
    timeout 200 systemctl stop "$u" >/dev/null 2>&1 || true
    # ExecStop ne tourne pas sur une unite « failed » : le coeur, lance par
    # run.sh dans SES PROPRES unites, resterait alors debout.
    systemctl stop osmo-egprs-web.service osmo-hlr.service >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓${NC} Natif arrete"
}

stop_lab() {
    echo -e "${YELLOW}[lab] Arret osmo-operator...${NC}"
    if [ -f "$LAB_DIR/start.sh" ]; then
        cd "$LAB_DIR"
        bash ./start.sh stop
    fi
    # Nettoyage complet si start.sh stop ne suffit pas
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

    # 3. Web (attendre que les containers soient up)
    echo ""
    echo -e "${GREEN}[3/3] Dashboard web...${NC}"
    wait_operators 180 || true
    start_web || true

    # Resume
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

    # Lancer start.sh en mode non-interactif avec des defauts
    # On pipe les reponses au script interactif
    cd "$LAB_DIR"
    {
        echo "2"       # bridge mode
        echo "2"       # 2 operateurs
        echo "o"       # valeurs par defaut
        echo "8"       # 8 MS
        echo "N"       # pas de WAN
        echo "1"       # faketrx
        echo "0"       # A5/0
    } | bash ./start.sh

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
