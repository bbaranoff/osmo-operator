#!/bin/bash
# =============================================================================
# start-interstp.sh - lance le NOEUD INTER-STP : le hub SS7 commun au WAN
# =============================================================================
#
# Dans un lab a une seule machine, l'inter-STP est un conteneur parmi d'autres,
# a 172.20.0.10, et il ne dessert que les operateurs de CETTE machine. Des qu'on
# repartit les operateurs sur plusieurs noeuds, il devient ce qu'il est vraiment :
# un equipement a part, avec sa propre adresse, auquel tous les noeuds
# s'attachent. C'est lui - et lui seul - qui fait traverser le SS7 au WAN.
#
#   noeud 1 (1.11.2) ─┐
#   noeud 2 (1.21.2) ─┼─ M3UA/SCTP 2908 ─► inter-STP 192.168.1.49    PC 0.0.0
#   noeud 3 (1.31.2) ─┘
#
# LE PLAN DE POINT CODES, ET POURQUOI IL CHANGE
# Sur une machine isolee, chaque operateur N porte 1.N.2 - et cette formule se
# recalcule a l'identique partout. Trois noeuds attaches au meme hub y
# presenteraient donc trois fois le meme point code. Un point code est une
# ADRESSE : deux equipements qui partagent la leur, ce n'est pas un conflit de
# nom, c'est du routage faux. Le plan WAN encode donc le noeud dedans :
#
#     PC   = 1.<noeud><op>.<role>     role 1=MSC 2=STP 3=BSC
#     RCTX = noeud*1000 + op*100 + 50
#
# Usage :
#   sudo ./start-interstp.sh [--nodes 3] [--ops 1] [--ip 192.168.1.49]
#   sudo ./start-interstp.sh --status | --stop
#
#   --nodes N     nombre de noeuds desservis (1-9, defaut : lu dans /etc/osmo-wan.conf)
#   --ops K       operateurs par noeud (1-9, defaut 1)
#   --ip ADRESSE  adresse du hub ; posee sur l'interface si elle manque
#   --iface NOM   interface ou poser l'adresse (defaut : detectee)
#   --port N      port M3UA (defaut 2908)
#   --menu        pose les questions meme si une table existe deja
#   --defaut      applique la table du banc, en ignorant celle deja posee
#   --ips "a b c" les IP des noeuds operateurs, dans l'ordre (sans question)
#   --no-ip       ne touche pas a la configuration reseau
#   --foreground  reste au premier plan (journal a l'ecran)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
CFG="${CONF_DIR}/osmo-stp-interop.cfg"
LOG="${LOG:-/var/log/osmocom/osmo-stp-interop.log}"
PIDFILE="/run/osmo-interstp.pid"

NODES=""
OPS=1
MENU=0
USE_DEFAULTS=0
IPS=""
# Le hub du banc, en acces par pont. L'ancien defaut (192.168.56.1, host-only
# VirtualBox) n'existe sur aucun segment des que les VM sont pontees : le hub
# s'y liait sans que personne ne puisse l'atteindre.
HUB_IP="192.168.1.49"
# ── La table du banc, defaut de tous les prompts ────────────────────────────
# Les conteneurs d'abord, dans l'ordre de leur nom, puis les machines distantes.
# C'est le meme ordre que start.sh et build-iso.sh : une table lue ici doit
# ressembler a celle qu'ils ecrivent, sinon les point codes d'un cote ne
# correspondent plus aux AS declares de l'autre.
#   noeud 1  172.20.0.11  osmo-operator-1  (conteneur)
#   noeud 2  172.20.0.12  osmo-operator-2  (conteneur)
#   noeud 3  192.168.1.2  la VM
WAN_NODES_DEFAULT="1:172.20.0.11:11 2:172.20.0.12:22 3:192.168.1.2:33"

# L'adresse par defaut du noeud i, lue dans cette table.
_default_node_ip() {
    printf '%s' "$WAN_NODES_DEFAULT" | tr ' ' '\n' \
        | awk -F: -v n="$1" '$1==n{print $2; exit}'
}
IFACE=""
PORT=2908
SET_IP=1
FOREGROUND=0
ACTION=start

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)      NODES="${2:-}"; shift ;;
        --nodes=*)    NODES="${1#*=}" ;;
        --ops)        OPS="${2:-1}"; shift ;;
        --ops=*)      OPS="${1#*=}" ;;
        --ip)         HUB_IP="${2:-}"; shift ;;
        --ip=*)       HUB_IP="${1#*=}" ;;
        --iface)      IFACE="${2:-}"; shift ;;
        --iface=*)    IFACE="${1#*=}" ;;
        --port)       PORT="${2:-2908}"; shift ;;
        --port=*)     PORT="${1#*=}" ;;
        --menu)       MENU=1 ;;
        --defaut|--default) USE_DEFAULTS=1 ;;
        --ips)        IPS="${2:-}"; shift ;;
        --ips=*)      IPS="${1#*=}" ;;
        --no-ip)      SET_IP=0 ;;
        --foreground) FOREGROUND=1 ;;
        --status)     ACTION=status ;;
        --stop)       ACTION=stop ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   Inter-STP - hub SS7 du WAN osmo_egprs   ·   PC 0.0.0           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

stp_pid() {
    if [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        cat "$PIDFILE"; return 0
    fi
    pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' | head -1
}

# ── status ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    banner
    pid="$(stp_pid)"
    if [ -z "$pid" ]; then
        echo -e "  ${RED}✗${NC} inter-STP arrete"; exit 1
    fi
    echo -e "  ${GREEN}✓${NC} inter-STP actif (pid ${pid})"
    echo -e "  Ecoute : $(ss -lna 2>/dev/null | grep -E "[:.]${PORT}\b" | head -3 | tr -s ' ' | cut -d' ' -f1,5 | tr '\n' ' ')"
    echo ""
    # Le VTY est la seule source de verite sur QUI est attache : un ASP peut
    # avoir ouvert sa SCTP sans jamais passer ASP-ACTIVE, et rien d'autre ne le
    # montre. Le port ouvert, lui, ne prouve que l'ecoute.
    if command -v nc >/dev/null 2>&1; then
        echo -e "  ${BOLD}ASP attaches :${NC}"
        printf 'enable\nshow cs7 instance 0 asp\nshow cs7 instance 0 as all\nexit\n' \
            | nc -q2 127.0.0.1 4239 2>/dev/null | sed 's/^/    /' | grep -vE '^\s*$' | head -40 \
            || echo -e "    ${YELLOW}VTY 4239 muet${NC}"
    else
        echo -e "  ${YELLOW}nc absent : ${CYAN}telnet 127.0.0.1 4239${NC} puis "show cs7 instance 0 asp""
    fi
    exit 0
fi

# ── stop ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    pid="$(stp_pid)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null; sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo -e "${GREEN}Inter-STP arrete.${NC}"
    else
        echo -e "${YELLOW}Inter-STP deja arrete.${NC}"
    fi
    exit 0
fi

banner
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }
command -v osmo-stp >/dev/null 2>&1 || {
    echo -e "${RED}osmo-stp introuvable.${NC} Ce noeud doit porter la pile Osmocom." >&2; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# Qui sont les noeuds ? - le menu
# ══════════════════════════════════════════════════════════════════════════════
# Le hub n'a pas besoin des IP pour ROUTER : il ecoute, les ASP viennent a lui
# (accept-asp-connections dynamic-permitted) et c'est le point code qui decide
# du reste. Il en a besoin pour trois choses concretes :
#   • ouvrir son pare-feu a ces adresses et a elles seules ;
#   • ecrire /etc/osmo-wan.conf, la table que liront les noeuds et le diagnostic ;
#   • dire, dans --status, QUI devrait etre attache - sans cette liste, un noeud
#     absent est indiscernable d'un noeud qui n'existe pas.
# shellcheck source=network/wan-nodes.sh
. "$HERE/network/wan-nodes.sh"

ask_ips() {
    local n i ip def
    echo -e "${BOLD}Configuration du hub SS7${NC}"
    echo -e "  Saisissez les adresses des noeuds operateurs, dans l'ordre."
    echo ""
    n=$(_wan_ask "Inter-STP" "Nombre de noeuds operateurs (1-9) :" "${NODES:-3}") || exit 1
    [[ "$n" =~ ^[1-9]$ ]] || { echo -e "${RED}Nombre invalide : $n${NC}" >&2; exit 2; }

    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
    for i in $(seq 1 "$n"); do
        # Defaut : la table du banc. Le repli ".1N sur le segment du hub" ne
        # vaut plus rien depuis que les deux premiers noeuds sont des
        # conteneurs, sur le backbone docker et non sur le LAN.
        def="$(_default_node_ip "$i")"
        [ -n "$def" ] || def="${HUB_IP%.*}.$((10 + i))"
        ip=$(_wan_ask "Noeud $i/$n" "IP du noeud operateur $i :" "$def") || exit 1
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { echo -e "${RED}'$ip' n'est pas une IPv4${NC}" >&2; exit 2; }
        WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$n"; NODES="$n"
    # Le hub ne porte aucun operateur : il n'est pas un noeud de la table. On note
    # 0, que wan_nodes_validate accepte, plutot qu'un numero qui le ferait
    # ressembler a un noeud et lui volerait un point code.
    WAN_NODE_ID=0
    WAN_OPS="$OPS"
}

# --defaut : la table du banc, quoi qu'il y ait sur la machine.
# Sans cette option, une table deja posee dans /etc/osmo-wan.conf est rechargee
# telle quelle - c'est le bon comportement au quotidien, mais c'est aussi ce qui
# fait qu'un hub garde indefiniment des adresses perimees apres un changement de
# plan : le nouveau defaut du script n'est jamais consulte.
if [ "$USE_DEFAULTS" = "1" ] && [ -z "$IPS" ]; then
    IPS="$(printf '%s' "$WAN_NODES_DEFAULT" | tr ' ' '\n' | awk -F: '{print $2}' | tr '\n' ' ')"
    [ -n "$NODES" ] || NODES="$(printf '%s' "$WAN_NODES_DEFAULT" | wc -w)"
    echo -e "  ${CYAN}--defaut : table du banc${NC} ${WAN_NODES_DEFAULT}"
fi

if [ -n "$IPS" ]; then
    # Forme scriptable : --ips "10.0.0.11 10.0.0.12 10.0.0.13"
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=(); i=0
    for ip in $IPS; do
        i=$((i+1))
        WAN_IP[$i]="$ip"; WAN_IND[$i]="$(wan_default_ind "$i")"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$i"; NODES="$i"; WAN_NODE_ID=0; WAN_OPS="$OPS"
elif [ "$MENU" = "1" ] || { [ -z "$NODES" ] && [ ! -r "$WAN_CONF_FILE" ]; }; then
    if [ -t 0 ]; then
        ask_ips
    else
        echo -e "${YELLOW}Pas de terminal et pas de table : on part sur 3 noeuds sans adresses.${NC}"
        NODES=3
    fi
elif [ -z "$NODES" ] && [ -r "$WAN_CONF_FILE" ]; then
    wan_nodes_load "$WAN_CONF_FILE" 2>/dev/null || true
    NODES="${WAN_NODE_COUNT:-3}"
    OPS="${WAN_OPS:-$OPS}"
    echo -e "  Table lue dans ${CYAN}${WAN_CONF_FILE}${NC} : ${NODES} noeud(s)"
    echo -e "  ${CYAN}--menu${NC} pour la ressaisir."
fi

[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes : 1 a 9${NC}" >&2; exit 2; }
[[ "$OPS"   =~ ^[1-9]$ ]] || { echo -e "${RED}--ops : 1 a 9${NC}" >&2; exit 2; }

# Table connue : on la persiste et on ouvre le pare-feu pour ces adresses.
if [ "${#WAN_NODE_LIST[@]}" -gt 0 ] && [ -n "${WAN_IP[1]:-}" ]; then
    echo ""
    wan_nodes_summary 2>/dev/null || true
    WAN_AUTO=0 wan_nodes_save "$WAN_CONF_FILE" \
        && echo -e "  ${GREEN}✓${NC} table ecrite dans ${CYAN}${WAN_CONF_FILE}${NC}"
    if [ -x "$HERE/network/firewall-wan.sh" ] || [ -r "$HERE/network/firewall-wan.sh" ]; then
        for i in "${WAN_NODE_LIST[@]}"; do
            bash "$HERE/network/firewall-wan.sh" "${WAN_IP[$i]}" "$OPS" >/dev/null 2>&1 || true
        done
        echo -e "  ${GREEN}✓${NC} pare-feu ouvert pour ${#WAN_NODE_LIST[@]} noeud(s)"
    fi
fi

# ── L'adresse du hub ─────────────────────────────────────────────────────────
# Elle est ecrite en dur dans la config de CHAQUE noeud : si elle manque au
# demarrage, tous les ASP echouent a s'attacher et le seul symptome est un
# "connection refused" cote noeuds, jamais cote hub.
if [ "$SET_IP" = "1" ]; then
    if ip -4 addr show 2>/dev/null | grep -q "inet ${HUB_IP}/"; then
        echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}${NC} deja presente sur cette machine"
    else
        if [ -z "$IFACE" ]; then
            # L'interface qui porte deja le meme /24 : c'est le segment du WAN.
            IFACE="$(ip -4 -o addr show scope global 2>/dev/null \
                | awk -v pfx="${HUB_IP%.*}." '$4 ~ "^"pfx {print $2; exit}')"
            [ -z "$IFACE" ] && IFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
        fi
        if [ -n "$IFACE" ] && ip addr add "${HUB_IP}/24" dev "$IFACE" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}/24${NC} posee sur ${IFACE}"
        else
            echo -e "  ${YELLOW}⚠${NC} impossible de poser ${HUB_IP} (interface ${IFACE:-?})"
            echo -e "     Les noeuds ne pourront pas s'attacher tant qu'elle manque."
        fi
    fi
fi

# ── Config du hub ────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR" "$(dirname "$LOG")"
if [ ! -x "$HERE/helpers/create_interop.sh" ] && [ ! -r "$HERE/helpers/create_interop.sh" ]; then
    echo -e "${RED}helpers/create_interop.sh introuvable${NC}" >&2; exit 1
fi
# --listen-ip : le hub se lie a SON adresse, pas a 0.0.0.0. Sans elle, SCTP
# annonce toutes les adresses de la machine dans son INIT et les noeuds tentent
# des chemins morts - l'ASP monte puis retombe, en boucle.
bash "$HERE/helpers/create_interop.sh" --listen-ip "$HUB_IP" \
     --wan "$NODES" "$OPS" "$CFG" || exit 1
[ "$PORT" = "2908" ] || sed -i "s/^ listen m3ua 2908/ listen m3ua ${PORT}/" "$CFG"
echo ""

# ── Lancement ────────────────────────────────────────────────────────────────
if pid="$(stp_pid)" && [ -n "$pid" ]; then
    echo -e "  ${YELLOW}Un inter-STP tourne deja (pid ${pid}) - arret puis relance.${NC}"
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
fi

echo -e "  ${BOLD}Noeuds desservis :${NC} ${NODES} × ${OPS} operateur(s)"
for n in $(seq 1 "$NODES"); do
    for o in $(seq 1 "$OPS"); do
        printf '    noeud %s op %s → STP %s  MSC %s  BSC %s  (rctx %s)\n' \
            "$n" "$o" "1.${n}${o}.2" "1.${n}${o}.1" "1.${n}${o}.3" "$(( n*1000 + o*100 + 50 ))"
    done
done
echo ""

if [ "$FOREGROUND" = "1" ]; then
    echo -e "  ${GREEN}osmo-stp au premier plan - Ctrl-C pour arreter${NC}"
    exec osmo-stp -c "$CFG"
fi

osmo-stp -c "$CFG" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo -e "  ${GREEN}✓ inter-STP lance${NC} - M3UA ${CYAN}${HUB_IP}:${PORT}${NC}, VTY 4239"
    echo -e "  Journal : ${CYAN}${LOG}${NC}"
    echo ""
    echo -e "  ${BOLD}Cote noeuds :${NC} leur osmo-stp doit viser ${CYAN}${HUB_IP}${NC}"
    echo -e "    ISO construite avec ${CYAN}--role operator --node N${NC} : deja fait."
    echo -e "  ${BOLD}Verifier qui est attache :${NC} ${CYAN}./start-interstp.sh --status${NC}"
else
    echo -e "  ${RED}✗ osmo-stp n'a pas demarre${NC} - ${CYAN}tail -30 ${LOG}${NC}"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
    exit 1
fi
