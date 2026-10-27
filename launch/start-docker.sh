#!/bin/bash
# start-docker.sh - host launcher for the multi-operator Osmocom GSM stack (Docker)
#
# Usage: sudo ./launch/start-docker.sh [quick|normal] [WAN options] [qemu|virtual|hw|stop]
#   qemu     PoC: one operator, QEMU Calypso radio
#   virtual  N operators in containers, linked by SS7 over a docker bridge
#   hw       net-host mode: one operator, physical SDR
#   stop     remove all osmo-*/egprs containers and WAN iptables chains
#   quick    build the run image with the docker cache (default)
#   normal   rebuild the run image with --no-cache
# WAN options (--wan, --wan-nodes, --hub-ip, --operator, ...): see --help.
#
# Environment:
#   OSMO_REPO_DIR        repository root (when this file is sourced from a copy)
#   IMAGE_RUN/IMAGE_STP  images for operators / SS7 hub
#   OSMO_QUICK=0         force a --no-cache rebuild;  OSMO_NO_BUILD=1 skip the build
#   OSMO_NONINTERACTIVE=1  answer every whiptail dialog with its default
#   OP_ID_BASE=N         first operator number used by containers (lower ones are native)
#   OPERATOR_COUNT_HINT  number of operators (same as --operators)
#   HANDOFF_MODE         radio mode handed to start-native.sh (qemu | faketrx-qemu)
#   OSMO_NO_ATTACH=1, OSMO_NO_TERM=1, OSMO_SKIP_CHECKS=1, BRIDGE_NO_PROCESS=1,
#   OSMO_DOCKER_ROUTED=1, OSMO_PORT_OFFSET=N  (see the corresponding sections)
set -eu
# Repository root. OSMO_REPO_DIR first: build-iso.sh (iso_modules/30-image-configs.sh)
# sources a COPY of this file from $WORK, where BASH_SOURCE would point to /var/tmp.
START_REPO="${OSMO_REPO_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"

# ── This is the HOST launcher: refuse to run inside the container ──
# start-docker.sh drives docker (build, networks, docker run, volumes); start-native.sh
# runs INSIDE the container. Stop before touching anything and name the right script.
# Both /.dockerenv and /etc/docker-entrypoint-cmd (created by scripts/entrypoint.sh)
# are required: /.dockerenv alone is true in any container.
if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then
    printf '\033[1;31mVous etes dans le docker ! Utilisez start-native.sh\033[0m\n' >&2
    printf '\n  \033[0;36m/opt/GSM/osmo-operator/start-native.sh\033[0m   (ou ./start-native.sh depuis le depot)\n' >&2
    printf '\n  start-docker.sh est le lanceur de l'"'"'HOTE : il construit l'"'"'image, cree les\n' >&2
    printf '  reseaux et fait le "docker run". Rien de tout ca n'"'"'a de sens ici.\n' >&2
    exit 1
fi

DEBUG=
if [[ -n "$DEBUG" ]]; then
    set -x
    PS4='[DEBUG] + ${BASH_SOURCE}:${LINENO}: '
    echo "=== MODE DEBUG ACTIVE ==="
fi

IMAGE_BASE="osmocom-nitb"
# Overridable from the environment: start-nitb.sh re-runs this script with
# IMAGE_RUN=osmocom-nitb. Do not hard-code it.
IMAGE_RUN="${IMAGE_RUN:-osmocom-run}"

INTER_NET="gsm-inter"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

# WAN node hosting the SS7 hub. Exactly ONE node may do so: two hubs make two
# separate SS7 networks, silently.
WAN_HUB_NODE="${WAN_HUB_NODE:-1}"
# --hub-ip: the inter-STP is designated by its ADDRESS, not a node number, so a
# dedicated hub machine (no operator) does not need an entry in the WAN table.
WAN_HUB_IP="${WAN_HUB_IP:-}"
# --node-per-op: each container is a NODE, not an operator of this machine.
# Only use it when containers have externally reachable addresses (backbone routed
# to the LAN); otherwise other nodes cannot reach them.
WAN_NODE_PER_OP="${WAN_NODE_PER_OP:-0}"
# --operator IP:PREFIX: declare a WAN operator wherever it runs. Node numbers
# follow the declaration order (alternative to --wan-nodes "id:ip:ind").
OPERATOR_DECLS=()
# Inherited from the environment; --operators N (parsed later) takes precedence.
OPERATOR_COUNT_HINT="${OPERATOR_COUNT_HINT:-}"
# --host: address of THIS machine as seen by the VMs (their route to the backbone).
# Derived from the default interface; set it when the guess is wrong (several
# interfaces, address just changed).
HOST_LAN_IP=""
IMAGE_STP="${IMAGE_STP:-osmocom-stp}"
INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── SMS Routing ────────────────────────────────────────────────────────────────
SMS_ROUTING_SCRIPT="$START_REPO/scripts/sms-routing-setup.sh"
if [ -f "$SMS_ROUTING_SCRIPT" ]; then
    source "$SMS_ROUTING_SCRIPT"
fi
SMS_ROUTING_DIR=""

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
# Two mutually exclusive WAN mechanisms, neither enabled by default:
#
#   WAN_ENABLED (legacy, no option, whiptail question): TWO servers, single
#     prefix 66, network/setup-wan-interop.sh.
#
#   WAN_MESH (--wan): N nodes (1 to 9), ONE PREFIX PER NODE,
#     network/setup-wan-mesh.sh. Use it beyond two servers: the legacy script
#     rewrites its config block on each call, so only the last peer survives.
WAN_MESH=0
# --virtualbox: the WAN peers are VirtualBox VMs on THIS machine, which is itself a
# node. See network/setup-vbox-interco.sh.
VBOX_INTERCO=0
VBOX_NODES=""
VBOX_HOST_NODE=1
BUILD_STP=0
# shellcheck source=network/wan-nodes.sh
. "$START_REPO/network/wan-nodes.sh"

WAN_ENABLED="false"
WAN_LOCAL_IP=""
WAN_REMOTE_IP=""
WAN_N_REMOTE=""
WAN_PREFIX="66"
WAN_SIP_BASE=5080
WAN_RTP_BASE=20000
WAN_RTP_PER_OP=500
PHY_MODE="faketrx"   # faketrx | virtphy
# Choices handed to start-native.sh INSIDE the container (NO_MENU=1), to avoid
# whiptail menus over docker exec -ti. Decided on the HOST.
# HANDOFF_MODE_FROM_ENV records whether the caller imposed the mode, so that --wan
# can switch to hybrid without overriding an explicit HANDOFF_MODE=...
HANDOFF_MODE_FROM_ENV="${HANDOFF_MODE:+1}"
HANDOFF_MODE="${HANDOFF_MODE:-qemu}"  # qemu | faketrx-qemu (combined)
HANDOFF_QEMU_CHOICE="${HANDOFF_QEMU_CHOICE:-full-grgsm}"

# ── Helpers ────────────────────────────────────────────────────────────────────
# ── The two address plans of an operator ───────────────────────────────────
# backbone  172.20.0.<10+op>  segment shared by ALL operators and the inter-STP
#                             (.10). SS7 goes through it; network/setup-docker-lan-route.sh
#                             makes it reachable from the VM LAN.
# private   192.168.<op+1>.x  one segment per operator: its BTS, PCU, GGSN.
#                             Not reachable from outside.
#
# <op+1> because the lab LAN is 192.168.1.0/24 (VMs, SS7 hub at .49): operator 1
# on 192.168.1.0/24 would collide with it. Operators start at 192.168.2.0/24.
# ── First container rank ───────────────────────────────────────────────────
# OP_ID_BASE=2 starts containers at operator 2, leaving 1 to a NATIVE operator on
# the host (two equipments with the same point code would mean wrong routing).
# Everything derives from the index: container name (osmo-operator-N), backbone
# (172.20.0.<10+N>), point code (1.N.2), RCTX, private segment (192.168.<N+1>.0/24)
# and published ports.
OP_ID_BASE="${OP_ID_BASE:-1}"
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
# ── Private segment index: node or operator, depending on the host ────────
# 192.168.<index+1>.x, where index is:
#
#   DOCKER   a host carries N operator containers, each in its own netns; they
#            differ by OPERATOR number (the node is shared). index = operator.
#   VM/NATIVE the machine IS the node and carries one operator. index = node.
#
# The decision lives here once; lib/gabarits.sh and this script both inherit it.
_osmo_priv_index() {
    local op="${1:-1}"
    # The orchestrator is not inside the containers it creates: the detection below
    # would take the VM/native branch on the host and give every operator the same
    # segment (docker then refuses the overlapping network). start_bridge_mode sets
    # OSMO_PRIV_BY_OP=1 to mean "provisioning per operator".
    [ "${OSMO_PRIV_BY_OP:-0}" = "1" ] && { printf '%s' "$op"; return; }
    # Same detection as start-native.sh: /.dockerenv + /etc/docker-entrypoint-cmd
    # identifies a container of THIS repo; the cgroup is a fallback for any container.
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        printf '%s' "$op"; return
    fi
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
                        "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' "${OSMOCOM_CFG:-/etc/osmocom}/radio-plan.env" 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
op_private_ip()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).10"; }
op_private_gw()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).1"; }
op_private_net()  { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).0/24"; }
op_container()    { echo "osmo-operator-$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }

# ── PLMN: MCC is the COUNTRY, i.e. the NODE; MNC is the operator ────────────
# The node is what --node passes to start-native.sh. With --node-per-op each
# container is its own node (own country) and MNC is 01; otherwise containers are
# N operators of the same country.
op_plmn_node()  { if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then echo $(( ${WAN_NODE_ID:-1} + $1 - 1 )); else echo "${WAN_NODE_ID:-1}"; fi; }
op_plmn_index() { if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then echo 1; else echo "$1"; fi; }
# printf '%03d' of an empty/zero value gives "000", which osmo-msc rejects
# ("network country code 000") and then restart-loops. A zero node number is a
# bug, not an MCC: clamp it and warn once.
_plmn_borne() {  # $1 = value, $2 = floor, $3 = what
    case "$1" in
        ''|*[!0-9]*) echo "  ATTENTION : $3 illisible ('$1') - ramene a $2" >&2; echo "$2" ;;
        *) if [ "$1" -lt "$2" ]; then echo "  ATTENTION : $3 vaut $1 - ramene a $2" >&2; echo "$2"; else echo "$1"; fi ;;
    esac
}
op_mcc()        { printf '%03d' "$(_plmn_borne "$(op_plmn_node "$1")" 1 "numero de noeud (MCC)")"; }
op_mnc()        { printf '%02d' "$(_plmn_borne "$(op_plmn_index "$1")" 1 "rang d'operateur (MNC)")"; }

# Names without spaces: osmo-msc's VTY "short name" takes a single word.
# ── Lab data sets: data/*.txt ──────────────────────────────────────────────
# Operator names, countries, people and addresses live in data/, one per line,
# editable without touching the code. They are SHUFFLED at load time (the random
# draw) and then fixed for the whole run.
OSMO_DATA_DIR="${OSMO_DATA_DIR:-$START_REPO/data}"

# $1 = name of the array to fill, $2 = file, rest = fallback values.
# The repo may be incomplete (an ISO does not always ship data/).
_load_pool() {
    local -n __out=$1
    local __file=$2; shift 2
    __out=()
    if [ -r "$__file" ]; then
        if command -v shuf >/dev/null 2>&1; then
            mapfile -t __out < <(grep -vE '^[[:space:]]*(#|$)' "$__file" | shuf)
        else
            mapfile -t __out < <(grep -vE '^[[:space:]]*(#|$)' "$__file")
        fi
    fi
    [ "${#__out[@]}" -gt 0 ] || __out=("$@")
}
declare -a POOL_OP POOL_PAYS POOL_NOMS POOL_ADR
_load_pool POOL_OP   "$OSMO_DATA_DIR/op.txt"        OsmoOP1 OsmoOP2 OsmoOP3
_load_pool POOL_PAYS "$OSMO_DATA_DIR/pays.txt"      Syldavie Bordurie Poldevie
_load_pool POOL_NOMS "$OSMO_DATA_DIR/noms.txt"      "Jean Dupont" "Marie Martin"
_load_pool POOL_ADR  "$OSMO_DATA_DIR/adresses.txt"  "rue des Ondes Courtes, Fontaine-sur-Onde"

op_default_name() { echo "${POOL_OP[$(( ($1 - 1) % ${#POOL_OP[@]} ))]}"; }
op_country()      { local n; n=$(op_plmn_node "$1"); echo "${POOL_PAYS[$(( (n - 1) % ${#POOL_PAYS[@]} ))]}"; }

# WAN helpers
wan_sip_port()    { echo $(( WAN_SIP_BASE + ($1 - 1) * 2 )); }
wan_rtp_start()   { echo $(( WAN_RTP_BASE + ($1 - 1) * WAN_RTP_PER_OP )); }
wan_rtp_end()     { echo $(( WAN_RTP_BASE + $1 * WAN_RTP_PER_OP - 1 )); }

wan_sms_port()    { echo $(( 7890 + $1 - 1 )); }
# A WAN is active (legacy OR mesh): "must the WAN ports be opened?".
wan_active()      { [ "$WAN_ENABLED" = "true" ] || [ "${WAN_MESH:-0}" = "1" ]; }

# Linphone helpers - SIP/RTP ports of the containers.
# No SIP/RTP port is published for containers: they sit on a routable bridge and
# are reached directly at their own address on the nominal port. These functions
# return the NOMINAL values (generate_configs.sh uses them to write configs).
# OSMO_PORT_OFFSET=N re-enables an offset if needed.
PORT_OFFSET="${OSMO_PORT_OFFSET:-0}"
# RTP follows the same rule: nominal range, 200 ports per operator.
linphone_sip_port()  { echo $(( 5060  + ${PORT_OFFSET:-0}      + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + $1 * 200 - 1 )); }

# Global - detected before the operator loop
HOST_IP="127.0.0.1"
ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
HOST_AUDIO_RELAY=""
WSLG_TCP_PORT="${WSLG_TCP_PORT:-4713}"

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Osmocom GSM/EGPRS Virtual Network            ║"
    echo "║        Multi-Operator SS7 + osmo-gapk Audio          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Whiptail helpers ────────────────────────────────────────────────────────
WT_BACKTITLE="Osmocom GSM/EGPRS Virtual Network"
WT_WIDTH=72

check_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        echo -e "${RED}whiptail introuvable.${NC} Installez-le :" >&2
        echo -e "  ${CYAN}apt-get install -y whiptail${NC}  (Debian/Ubuntu)" >&2
        echo -e "  ${CYAN}dnf install -y newt${NC}          (Fedora/RHEL)" >&2
        exit 1
    fi
}

# ── Non-interactive mode: dialogs answer themselves ────────────────────────
# Each wt_* opens a whiptail box and WAITS, which blocks when launched from a
# desktop icon, start-multi.sh or a script. In auto mode the default is used:
#   wt_input -> its default ($3), the pre-filled value;
#   wt_menu  -> the FIRST entry, where the cursor starts;
#   wt_yesno -> no, because boxes use --defaultno;
#   wt_msg   -> written to stderr instead of waiting for <Ok>.
# This is exactly what pressing Enter would give.
#
# Triggers: OSMO_NONINTERACTIVE=1 (set by start-multi.sh), or no TTY on stdin
# (icon, cron, pipe). On a terminal the questions are asked.
_wt_auto() { [ "${OSMO_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; }

wt_input() {
    if _wt_auto; then
        echo "[auto] $1 : ${3}" >&2
        printf '%s' "$3"; return 0
    fi
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" \
        --inputbox "$2" 10 "$WT_WIDTH" "$3" 3>&1 1>&2 2>&3
}

wt_yesno() {
    if _wt_auto; then echo "[auto] $1 : non" >&2; return 1; fi
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" \
        --defaultno --yesno "$2" 11 "$WT_WIDTH" 3>&1 1>&2 2>&3
}

wt_menu() {
    local title="$1" prompt="$2"; shift 2
    local nitems=$(( $# / 2 ))
    if _wt_auto; then
        echo "[auto] $title : ${1}" >&2
        printf '%s' "$1"; return 0
    fi
    whiptail --backtitle "$WT_BACKTITLE" --title "$title" \
        --menu "$prompt" 20 "$WT_WIDTH" "$nitems" "$@" 3>&1 1>&2 2>&3
}

wt_msg() {
    if _wt_auto; then echo "$1" >&2; return 0; fi
    whiptail --backtitle "$WT_BACKTITLE" --msgbox "$1" 10 "$WT_WIDTH"
}

# ── Host audio session: WHO and WHERE ──────────────────────────────────────
# The right user is found by the PRESENCE of their pulse socket (a live graphical
# session), not by name. Same logic as session_user() in wslg-audio-bridge.sh,
# extended to a scan of /run/user/*. The loopback script is network/loopback.sh.
session_pulse_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)" "${USER:-}"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    # Last resort: owner of the first pulse socket found. Covers `sudo -i`
    # (SUDO_USER lost) and sessions without logname (cron, service).
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    return 1
}

# The loopback script lives in the repo, not in a $HOME.
find_loopback_script() {
    local d c
    d="$START_REPO"
    for c in "$d/network/loopback.sh" "$d/loopback.sh"; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

enable_user_loopback() {
    local target_user target_uid target_runtime loopback_script
    target_user="$(session_pulse_user)" || {
        echo -e "  ${YELLOW}[audio] aucune session PulseAudio utilisateur - loopback ignore${NC}"
        return 0
    }
    loopback_script="$(find_loopback_script)" || {
        echo -e "  ${YELLOW}[audio] network/loopback.sh introuvable - loopback ignore${NC}"
        return 0
    }
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    echo -e "${GREEN}=== [audio] Loopback user session ===${NC}"
    echo -e "  user    : ${CYAN}${target_user}${NC}"
    echo -e "  runtime : ${CYAN}${target_runtime}${NC}"
    echo -e "  script  : ${CYAN}${loopback_script}${NC}"
    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" enable >/dev/null 2>&1 || {
            echo -e "  ${RED}[FAIL]${NC} enable loopback"
            return 1
        }
    echo -e "[ OK ]${NC} loopback active"
}

disable_user_loopback() {
    local target_user target_uid target_runtime loopback_script
    target_user="$(session_pulse_user)"       || return 0
    loopback_script="$(find_loopback_script)" || return 0
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" disable || true
}

build_alsa_args() {
    local alsa_args=""
    local src_asound="$START_REPO/configs/asound.conf"
    local host_asound="/tmp/osmocom-alsa/asound.conf"
    mkdir -p /tmp/osmocom-alsa
    # Docker creates a DIRECTORY when the source of a -v bind does not exist; a
    # leftover directory would make the mount on /etc/asound.conf (a file) fail with
    # "not a directory". Remove it before the copy.
    if [ -d "$host_asound" ]; then
        rm -rf "$host_asound"
    fi
    if [ -d /dev/snd ]; then
        alsa_args="${alsa_args} --device /dev/snd"
        if getent group audio >/dev/null 2>&1; then
            alsa_args="${alsa_args} --group-add $(getent group audio | cut -d: -f3)"
        fi
    fi
    local has_pulse="true"
    # ── The pulse socket must be MOUNTED, not just named ──────────────────────
    # PULSE_SERVER=unix:/run/pulse/native only works if the socket is mounted into
    # the container; otherwise gapk fails to init ALSA and calls are silent.
    # Mount the socket when it exists, else fall back to the TCP relay. The socket is
    # srwxrwxrwx and the unix module uses auth-anonymous=1, so the container's
    # osmocom user can connect.
    local _pa_sock=""
    for _s in /var/run/pulse/native /run/pulse/native "/run/user/$(id -u)/pulse/native"; do
        [ -S "$_s" ] && { _pa_sock="$_s"; break; }
    done
    if [ -n "$_pa_sock" ]; then
        alsa_args="${alsa_args} -v ${_pa_sock}:/run/pulse/native"
        alsa_args="${alsa_args} -e PULSE_SERVER=unix:/run/pulse/native"
    elif [ -n "${HOST_AUDIO_RELAY:-}" ]; then
        alsa_args="${alsa_args} -e PULSE_SERVER=${HOST_AUDIO_RELAY}"
    else
        # Neither socket nor relay: say so, otherwise a silent call is the only symptom.
        alsa_args="${alsa_args} -e PULSE_SERVER=tcp:${INTER_NET_GATEWAY:-172.20.0.1}:${WSLG_TCP_PORT:-4713}"
        echo -e "  ${YELLOW}Audio : aucun socket pulse trouve et relais non arme - repli TCP a l aveugle${NC}" >&2
    fi
    local asound_ok="false"
    if [ -f "$src_asound" ]; then
        if cp -f "$src_asound" "$host_asound" 2>/dev/null && [ -f "$host_asound" ]; then
            asound_ok="true"
        else
            echo -e "  ${YELLOW}Audio : copie de asound.conf vers ${host_asound} impossible${NC}" >&2
        fi
    fi
    if [ "$asound_ok" = "true" ]; then
        alsa_args="${alsa_args} -v ${host_asound}:/etc/asound.conf:rw"
        alsa_args="${alsa_args} -e ALSA_OUTPUT=gsm_out -e ALSA_INPUT=gsm_in"
        alsa_args="${alsa_args} -e ALSA_CARD=gsm_out -e GAPK_ALSA_DEV=gsm_out"
        if [ "$has_pulse" = "true" ]; then
            echo -e "  ${GREEN}Audio : PulseAudio + asound.conf${NC}" >&2
        else
            echo -e "  ${YELLOW}Audio : asound.conf sans PulseAudio${NC}" >&2
        fi
    else
        alsa_args="${alsa_args} -e ALSA_OUTPUT=default -e ALSA_INPUT=default"
        alsa_args="${alsa_args} -e ALSA_CARD=default -e GAPK_ALSA_DEV=default"
        echo -e "  ${YELLOW}Audio : configs/asound.conf absent, fallback default${NC}" >&2
    fi
    echo "$alsa_args"
}

# ── Host audio: expose the host pulse server over TCP ─────────────────────
ensure_host_audio_relay() {
    [ -n "${HOST_AUDIO_RELAY_DONE:-}" ] && return 0
    HOST_AUDIO_RELAY_DONE=1
    local bridge="$START_REPO/scripts/wslg-audio-bridge.sh"
    [ -x "$bridge" ] || { echo -e "  ${YELLOW}[host-audio] $bridge introuvable${NC}" >&2; return 0; }
    if "$bridge" host-relay; then
        # Check that the port actually answers: `host-relay` returns 0 as soon as the
        # module load is REQUESTED, not when pulseaudio accepts connections. gapk
        # initialises its I/O only ONCE: missing that window means a silent call.
        local _p=0 _i
        for _i in $(seq 1 30); do
            if (exec 3<>"/dev/tcp/${INTER_NET_GATEWAY}/${WSLG_TCP_PORT:-4713}") 2>/dev/null; then
                exec 3>&- 2>/dev/null; _p=1; break
            fi
            sleep 1
        done
        if [ "$_p" = "1" ]; then
            HOST_AUDIO_RELAY="tcp:${INTER_NET_GATEWAY}:${WSLG_TCP_PORT:-4713}"
            echo -e "  ${GREEN}[host-audio] relai pret → ${HOST_AUDIO_RELAY}${NC}"
        else
            HOST_AUDIO_RELAY=""
            echo -e "  ${RED}[host-audio] relai charge mais ${INTER_NET_GATEWAY}:${WSLG_TCP_PORT:-4713} NE REPOND PAS apres 30 s${NC}" >&2
            echo -e "  ${YELLOW}             → l audio du conteneur sera muet. Verifier :${NC}" >&2
            echo -e "  ${YELLOW}               pactl list modules | grep -A2 native-protocol-tcp${NC}" >&2
        fi
    else
        HOST_AUDIO_RELAY=""
        echo -e "  ${YELLOW}[host-audio] relai non ouvert - fallback carte locale dans le conteneur${NC}"
    fi

    # Uplink (microphone). The relay above only covers downlink (gsm_audio.monitor
    # -> host speakers). The mic comes from the browser, which captures the host's
    # DEFAULT source, possibly a ghost input producing only zeros. host-mic picks the
    # source by signal, not by name (see host_mic()). Non fatal.
    "$bridge" host-mic || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Build
# ══════════════════════════════════════════════════════════════════════════════
# QUICK by default, without asking: the docker cache is the everyday answer; a
# full Osmocom rebuild (~40 min) happens only on request:
#     ./launch/start-docker.sh normal ...        (positional argument)
#     OSMO_QUICK=0 ./launch/start-docker.sh ...  (environment variable)
QUICK="${OSMO_QUICK:-1}"
# Explicit even when not requested: this suppresses the build-mode dialog.
# Setting it to 0 would bring the question back on every non-interactive run.
QUICK_EXPLICIT=1

build_run_image() {
    # docker compose v2 (compose.yaml, service "run") when available - it carries
    # the build-args and image name - else plain docker build. Same result:
    # osmocom-run from Dockerfile.run, on top of osmocom-nitb.
    local _dir; _dir="${OSMO_REPO_DIR:-$START_REPO}"
    local _nc=""; [ "${QUICK:-0}" = "1" ] || _nc="--no-cache"
    if [ "${QUICK:-0}" = "1" ]; then
        echo -e "${GREEN}Build de l'image run...${NC} ${YELLOW}(quick - cache docker reutilise)${NC}"
    else
        echo -e "${GREEN}Build de l'image run...${NC} ${CYAN}(normal - --no-cache)${NC}"
    fi
    if docker compose version >/dev/null 2>&1 && [ -f "$_dir/compose.yaml" ]; then
        ( cd "$_dir" && QEMU_CACHE_BUST=$(date +%s) IMAGE_RUN="$IMAGE_RUN" \
          docker compose -f "$_dir/compose.yaml" build $_nc run )
    else
        docker build $_nc --build-arg QEMU_CACHE_BUST=$(date +%s) -f Dockerfile.run -t "$IMAGE_RUN" .
    fi
    echo -e "${GREEN}Image '$IMAGE_RUN' prete.${NC}"
}

check_image() {
    if ! docker image inspect "$IMAGE_RUN" &>/dev/null; then
        echo -e "${RED}Image '$IMAGE_RUN' introuvable - build en cours...${NC}"
        build_run_image
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Dynamic generation - pjsip interop trunks
# ══════════════════════════════════════════════════════════════════════════════
generate_pjsip_interop_trunks() {
    local op_id=$1
    local n_operators=$2
    # Operators below OP_ID_BASE are NATIVE (on the host): include them so that
    # containers also get a trunk to them.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        local remote_ip
        # A native operator runs on the host; seen from a container the host is the
        # docker bridge gateway (same address as the audio bridge and sms-routing.conf).
        # Note: match=172.20.0.1 does not capture Linphone REGISTERs arriving through the
        # same gateway, because pjsip.conf sets endpoint_identifier_order=username,ip,anonymous.
        if [ "$remote_op" -lt "${OP_ID_BASE:-1}" ]; then
            remote_ip="${INTER_NET_GATEWAY:-172.20.0.1}"
        else
            remote_ip=$(op_backbone_ip "$remote_op")
        fi
        cat <<EOF

[interop-identify-op${remote_op}]
type=identify
endpoint=interop_trunk_op${remote_op}
match=${remote_ip}

[interop_trunk_op${remote_op}]
type=endpoint
transport=transport-udp
context=interop_in
disallow=all
allow=gsm
allow=ulaw
aors=interop_trunk_op${remote_op}
direct_media=no
rtp_symmetric=yes
force_rport=yes
media_encryption=no

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}

generate_extensions_interop_out() {
    local op_id=$1
    local n_operators=$2
    # The prefix carries the NODE: MSISDN = <node>00<operator><rank>.
    local _pfx; _pfx="$(osmo_msisdn_pfx "$(osmo_node_id)")"
    cat <<'EOF'
[interop_out]

EOF
    # A single pattern: MSISDNs have six digits, <node>00<operator><rank>.
    # Operators below OP_ID_BASE are native and are included as well.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done

    # ── Softphones too, without prefix ─────────────────────────────────────────
    # Lets a Linphone in [internal] dial another operator's number directly instead
    # of going through the local MSC. _<pfx><op>XX is MORE SPECIFIC than _X., so
    # Asterisk picks it without touching the template's catch-all. Gosub(sub-record)
    # as for _9., so these calls are recorded too.
    printf '[internal]\n\n'
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== SIP -> INTER-OP Op${remote_op}: \${EXTEN} - CallerID: \${CALLERID(all)} ===)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Goto(interop_out,\${EXTEN},1)

EOF
    done
    # No _X. catch-all here: configs/extensions.conf already declares one in this
    # context; a duplicate would be rejected with warnings on every reload.
}

# ══════════════════════════════════════════════════════════════════════════════
# SMS routing fallback
# ══════════════════════════════════════════════════════════════════════════════
_generate_sms_routing_conf_fallback() {
    # 'local i' is required: this function is called (via apply_config_templates)
    # from the "for i in ..." loop that starts the operators; without local it
    # clobbers the caller's index and every following container gets the same ports.
    local i
    local op_id=$1 n_operators=$2
    printf '# sms-routing.conf - Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    # Operators below OP_ID_BASE are NATIVE (start-multi.sh sets OP_ID_BASE=2):
    # list them in [operators] and [routes], pointing to the docker bridge gateway,
    # which IS the host seen from a container (172.20.0.1).
    local _natif_gw="${INTER_NET_GATEWAY:-172.20.0.1}"
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do printf '%s = %s\n' "$i" "$_natif_gw"; done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"
    done
    printf '\n[routes]\n'
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done
    done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done  # exact MSISDNs <node>00<op><ms> - NO concatenation
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}

# ══════════════════════════════════════════════════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────
# Network configuration - delegated to ./generate_configs.sh
#
# generate_configs.sh creates globals.conf at the repo root if missing and never
# overwrites it afterwards. Reset to factory values: ./generate_configs.sh --force
# ─────────────────────────────────────────────────────────────────────────────
# OSMO_REPO_DIR lets the caller name the real repo root: build-iso.sh extracts
# this file as a library ($WORK/start.lib.sh) and sources it, so BASH_SOURCE would
# point to a copy in a work directory without generate_configs.sh.
_GC_SH="${OSMO_REPO_DIR:-$START_REPO}/generate_configs.sh"
"$_GC_SH" >/dev/null || true
. "$_GC_SH"


# ── Forced update of the three trees, BEFORE run.sh ─────────────────────────
# The repos are cloned and pulled in the Dockerfile, i.e. frozen at BUILD time.
# Refresh them at every start so a new container runs the current code.
#
# ORDER: call after `docker run` and BEFORE `docker exec ... run.sh`.
#
# `--ff-only`, NOT `reset --hard`: the container's qosmo repo may receive manual
# commits during a session; a divergence must stop and be visible, not be erased.
#
# qemu is REBUILT after the pull: updating the source without relinking changes
# nothing at runtime. To check a running binary: `stat -L /proc/<pid>/exe`.
#
# Non blocking (no network = continue) but LOUD: a failed pull must show up.
force_update_trees() {
    local c=$1
    echo -e "  ${GREEN}[*] Mise a jour forcee des depots (avant run.sh)...${NC}"
    for repo in /opt/GSM/qosmo /opt/GSM/osmo-operator /opt/GSM/osmo-egprs-web; do
        if ! docker exec "$c" test -d "$repo/.git" 2>/dev/null; then
            echo -e "    ${YELLOW}$repo : pas un depot git - ignore${NC}"
            continue
        fi
        local before after
        before=$(docker exec "$c" git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')
        if docker exec "$c" git -C "$repo" pull --ff-only 2>&1 | tail -2 | sed 's/^/    /'; then
            after=$(docker exec "$c" git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')
            if [ "$before" = "$after" ]; then
                echo -e "    ${CYAN}$repo${NC} : deja a jour ($after)"
            else
                echo -e "    ${GREEN}$repo${NC} : $before -> $after"
                # ── The web server already runs and node has already read its file ──
                # osmo-egprs-web.service starts at container boot, before this call, and node
                # reads server.js only once. Restart it ONLY if the pull actually changed something.
                if [ "$repo" = /opt/GSM/osmo-egprs-web ]; then
                    if docker exec "$c" systemctl restart osmo-egprs-web 2>/dev/null; then
                        echo -e "    ${GREEN}osmo-egprs-web.service relance${NC} (le dashboard charge le nouveau code)"
                    else
                        echo -e "    ${YELLOW}osmo-egprs-web.service : relance KO - le dashboard garde l'ancien code${NC}"
                    fi
                fi
            fi
        else
            echo -e "    ${RED}$repo : pull KO (divergence ou reseau) - le run part sur $before${NC}"
        fi
    done
    # Rebuild QEMU: without it the pull above does not change the running binary.
    # ninja only rebuilds what changed.
    echo -e "  ${GREEN}[*] Recompilation QEMU (ninja)...${NC}"
    if docker exec "$c" bash -c 'cd /opt/GSM/qosmo/build && ninja' >/dev/null 2>&1; then
        echo -e "    ${GREEN}qemu-system-arm relie${NC} ($(docker exec "$c" stat -L -c %y /opt/GSM/qosmo/build/qemu-system-arm 2>/dev/null | cut -c1-19))"
    else
        echo -e "    ${RED}ninja KO - le run utilisera le binaire de l'image${NC}"
        docker exec "$c" bash -c 'cd /opt/GSM/qosmo/build && ninja 2>&1 | tail -15' | sed 's/^/      /' || true
    fi
}

build_vol_args() {
    local tmpdir=$1
    local vol_args=""
    [ -d "$tmpdir/osmocom" ] && vol_args="$vol_args -v $tmpdir/osmocom:/etc/osmocom"
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/asterisk/$(basename "$f")"
    done
    if [ -f "$tmpdir/bb/mobile.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile.cfg:/root/.osmocom/bb/mobile.cfg"
    fi
    if [ -f "$tmpdir/bb/mobile_group1.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile_group1.cfg:/root/.osmocom/bb/mobile_group1.cfg"
    fi
    echo "$vol_args"
}

# ══════════════════════════════════════════════════════════════════════════════
# Host TUN
# ══════════════════════════════════════════════════════════════════════════════
prepare_host_tun() {
    echo -e "${GREEN}[*] Configuration TUN sur l'hote...${NC}"
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    if [ ! -c /dev/net/tun ]; then
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi
    ip link del apn0 2>/dev/null || true
    ip tuntap add dev apn0 mode tun
    ip addr add 176.16.32.0/24 dev apn0
    ip link set apn0 up
}

# ══════════════════════════════════════════════════════════════════════════════
# Inter-STP
# ══════════════════════════════════════════════════════════════════════════════
start_inter_stp() {
    local n_operators=$1
    local tmpdir
    tmpdir=$(mktemp -d)
    local inter_cfg="${tmpdir}/osmo-stp-interop.cfg"
    if [ "${WAN_MESH:-0}" = "1" ]; then
        # WAN plan: one AS per (node, operator) pair, point codes 1.<node><op>.<role>.
        # The hub must know ALL nodes, not only local operators; otherwise remote ASPs
        # attach to a non-existent AS and are rejected without explanation.
        echo -e "${GREEN}Generation config inter-STP WAN (${WAN_NODE_COUNT} noeuds × ${n_operators})...${NC}"
        bash ./helpers/create_interop.sh --wan "$WAN_NODE_COUNT" "$n_operators" "$inter_cfg" > /dev/null
    else
        echo -e "${GREEN}Generation config inter-STP (${n_operators} operateurs)...${NC}"
        bash ./helpers/create_interop.sh "$n_operators" "$inter_cfg" > /dev/null
    fi
    if [ ! -f "$inter_cfg" ]; then
        echo -e "${RED}Echec generation config inter-STP${NC}"; exit 1
    fi
    # The hub only routes M3UA: the osmocom-stp image (Dockerfile.stp) is enough and
    # much smaller than osmocom-run. It is not built here behind the caller's back:
    # if missing, the full image (which also contains osmo-stp) is used.
    local stp_image="$IMAGE_RUN"
    if [ "${BUILD_STP:-0}" = "1" ] && ! docker image inspect "$IMAGE_STP" >/dev/null 2>&1; then
        echo -e "  ${GREEN}Construction de ${IMAGE_STP} (Dockerfile.stp)...${NC}"
        docker build -f "$START_REPO/Dockerfile.stp" -t "$IMAGE_STP" "$START_REPO" \
            || echo -e "  ${YELLOW}⚠ echec - on restera sur ${IMAGE_RUN}${NC}"
    fi
    if docker image inspect "$IMAGE_STP" >/dev/null 2>&1; then
        stp_image="$IMAGE_STP"
        echo -e "  ${CYAN}image ${IMAGE_STP} (STP seul)${NC}"
    elif [ "${WAN_MESH:-0}" = "1" ]; then
        echo -e "  ${YELLOW}image ${IMAGE_STP} absente - on utilise ${IMAGE_RUN}.${NC}"
        echo -e "  ${CYAN}Pour la construire : docker build -f Dockerfile.stp -t ${IMAGE_STP} .${NC}"
    fi

    echo -e "${GREEN}Lancement inter-STP @ ${INTER_STP_IP}:2908 (PC 0.0.0)...${NC}"
    docker rm -f "$INTER_STP_CONTAINER" &>/dev/null || true
    # --restart, NOT --rm: with --rm a host reboot removes the hub instead of leaving
    # it stopped. The two are mutually exclusive in docker, and the "docker rm -f"
    # above already removes any leftover.
    # ── 2908 published on loopback: attachment point of the NATIVE operator ──
    # The native operator's osmo-stp.cfg declares `asp asp-to-inter 2908 2910 m3ua`
    # with remote-ip 127.0.0.1; the hub lives in a container, so the port must be
    # published on the host.
    # /sctp, NOT /tcp: M3UA runs over SCTP (docker supports publishing it).
    # Bound to 127.0.0.1, not 0.0.0.0: only the local native operator uses it; exposing
    # it would open the SS7 core to the LAN (checks/wan_ss7_check.sh flags a public
    # M3UA port as a defect). Pointing the native ASP at 172.20.0.10 instead is not
    # viable: that address only exists while the docker bridge is up.
    docker run -d \
        --restart unless-stopped \
        --name "$INTER_STP_CONTAINER" \
        --hostname "$INTER_STP_CONTAINER" \
        --network "$INTER_NET" \
        --ip "$INTER_STP_IP" \
        -p "127.0.0.1:2908:2908/sctp" \
        --cap-add NET_ADMIN \
        -v "${inter_cfg}:/etc/osmocom/osmo-stp-interop.cfg" \
        --entrypoint bash \
        "$stp_image" \
        -c "sleep infinity" > /dev/null
    # tmux if the image has it, otherwise a plain detached process.
    # osmocom-stp is the minimal "STP only" image and has no tmux. The barrier below
    # only reads /tmp/osmo-stp.log, which the detached process also writes.
    if docker exec "$INTER_STP_CONTAINER" sh -c 'command -v tmux >/dev/null 2>&1'; then
        docker exec "$INTER_STP_CONTAINER" \
            tmux new-session -d -s stp \
            "osmo-stp -c /etc/osmocom/osmo-stp-interop.cfg 2>&1 | tee /tmp/osmo-stp.log"
    else
        docker exec -d "$INTER_STP_CONTAINER" \
            sh -c 'exec osmo-stp -c /etc/osmocom/osmo-stp-interop.cfg > /tmp/osmo-stp.log 2>&1'
    fi
    echo -ne "${GREEN}[*] Attente demarrage inter-STP"
    local retries=25
    while [ $retries -gt 0 ]; do
        if docker exec "$INTER_STP_CONTAINER" \
            grep -qE "listening|m3ua.*[Ss]erver|bound" /tmp/osmo-stp.log 2>/dev/null; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$INTER_STP_CONTAINER" 2>/dev/null)" != "true" ]; then
            echo -e " ${RED}CRASH${NC}"
            docker logs "$INTER_STP_CONTAINER"
            exit 1
        fi
        echo -n "."
        sleep 1
        ((retries--)) || true
    done
    echo -e " ${YELLOW}(timeout log, on continue)${NC}"
}

wait_inter_stp_ready() {
    local n_operators=$1
    echo -ne "${GREEN}[*] Verification stabilisation inter-STP (routes SS7)${NC}"
    for i in {1..15}; do sleep 1; echo -n "."; done
    echo -e " ${GREEN}✓${NC}"
    return 0
}

wait_bb_vty() {
    local container="$1"
    local timeout=120
    local elapsed=0
    echo -ne "  Attente BB VTY 4247 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4247" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

wait_stp_vty() {
    local container="$1"
    local timeout=60
    local elapsed=0
    echo -ne "  Attente STP VTY 4239 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4239" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
setup_wan_interop() {
    local n_local=$1
    local n_remote=$2
    local script_path
    script_path="$START_REPO/network/setup-wan-interop.sh"
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[WAN] network/setup-wan-interop.sh introuvable${NC}"
        return 1
    fi
    chmod +x "$script_path"
    bash "$script_path" "$WAN_LOCAL_IP" "$WAN_REMOTE_IP" "$n_local" "$n_remote"
}

# ══════════════════════════════════════════════════════════════════════════════
# WAN mesh (--wan)
# ══════════════════════════════════════════════════════════════════════════════
# Fill the node table: non-interactively if WAN_NODES is already set (--wan-nodes
# or environment variable), otherwise by asking.
wan_mesh_configure() {
    local n_operators=$1
    WAN_OPS="$n_operators"

    # The WAN point code is 1.<node><op>.<role>: the middle field of the ITU 3-8-3
    # format is 8 bits (max 255). With 12 operators, node 9 would give "912", which
    # osmo-stp rejects with an unhelpful parse error. Stop here, naming the cause.
    if [ "$n_operators" -gt 9 ]; then
        echo -e "${RED}[WAN] ${n_operators} operateurs : le plan de point codes WAN${NC}" >&2
        echo -e "${RED}      (1.<noeud><op>.<role>) n'en admet que 9 par noeud.${NC}" >&2
        echo -e "${CYAN}      Repartissez-les sur plusieurs noeuds, ou lancez sans --wan.${NC}" >&2
        exit 1
    fi

    # --virtualbox: segment, VMs and table are created BEFORE everything else, then
    # read back like any table. The WAN code does not need to know its peers are VMs.
    if [ "${VBOX_INTERCO:-0}" = "1" ] && [ -z "${WAN_NODES:-}" ]; then
        local _vb=("$START_REPO/network/setup-vbox-interco.sh"
                   --host-node "$VBOX_HOST_NODE" --conf "$WAN_CONF_FILE")
        [ -n "${VBOX_NODES:-}" ] && _vb+=(--nodes "$VBOX_NODES")
        bash "${_vb[@]}" || { echo -e "${RED}[WAN] interconnexion VirtualBox echouee${NC}" >&2; exit 1; }
        wan_nodes_load "$WAN_CONF_FILE" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        WAN_NODE_ID="$VBOX_HOST_NODE"
    fi

    wan_menu_table

    if [ -n "${WAN_NODES:-}" ]; then
        wan_nodes_parse "$WAN_NODES" || exit 1
        if [ "${WAN_NODE_ID:-0}" = "0" ]; then
            # IP-based detection cannot work when the first nodes are CONTAINERS: their
            # addresses (172.20.0.11, .12) belong to the docker backbone, not to the host.
            # The host carries nodes without being one. Its number is that of its FIRST
            # container, i.e. 1 ("container i = node i"); --wan-id is only asked if the
            # table does not even contain that node.
            if wan_nodes_detect_self 2>/dev/null; then
                :
            elif [ -n "${WAN_IP[1]:-}" ]; then
                WAN_NODE_ID=1
                echo -e "  ${CYAN}[WAN] cette machine porte les conteneurs : noeud de base 1${NC}"
            else
                echo -e "${RED}[WAN] table vide ou sans noeud 1 : passez --wan-id N${NC}" >&2
                exit 1
            fi
        fi
        wan_nodes_validate || exit 1
    else
        # A table already present on this machine provides the defaults: relaunching
        # the lab proposes the existing values.
        wan_nodes_load "$WAN_CONF_FILE" 2>/dev/null || true
        wan_nodes_prompt || exit 1
    fi

    # ── What the WAN table does not say ────────────────────────────────────────
    # It gives nodes and addresses, but not where the SS7 hub is, nor whether this
    # machine's containers are its operators or separate nodes. Ask (or use the CLI
    # options) instead of falling back on defaults (local hub, containers = operators).
    wan_menu_complements

    WAN_ENABLED="false"  # excludes the legacy WAN
    WAN_LOCAL_IP="$(wan_local_ip)"
    echo ""
    wan_nodes_summary
    if [ -n "${WAN_HUB_IP:-}" ]; then
        echo -e "  inter-STP : ${CYAN}${WAN_HUB_IP}${NC}  (hors table : ce n'est pas un noeud)"
    else
        echo -e "  inter-STP : porte par le noeud ${CYAN}${WAN_HUB_NODE}${NC}"
    fi
    [ "${WAN_NODE_PER_OP:-0}" = "1" ] \
        && echo -e "  conteneurs: ${CYAN}un noeud chacun${NC}, a partir du noeud ${CYAN}${WAN_NODE_ID}${NC}"
    # Who runs HERE and who is only DECLARED: a declared node must already run
    # elsewhere, otherwise its subscribers appear in SMS tables and the dialplan with
    # nobody answering.
    for _nid in ${WAN_NODE_LIST[@]+"${WAN_NODE_LIST[@]}"}; do
        if [ "$_nid" = "${WAN_NODE_ID:-0}" ] || \
           { [ "${WAN_NODE_PER_OP:-0}" = "1" ] && [ "$_nid" -gt "${WAN_NODE_ID:-0}" ]; }; then
            printf '    noeud %-2s %-16s %s\n' "$_nid" "${WAN_IP[$_nid]}" "conteneur lance ici"
        else
            printf '    noeud %-2s %-16s %s\n' "$_nid" "${WAN_IP[$_nid]}" "declare (doit tourner ailleurs)"
        fi
    done
    echo ""
}

# ── Building the WAN table ─────────────────────────────────────────────────
# First the TOTAL number of operators, then how many run HERE as containers, then
# the others one by one. Containers take the first ranks (osmo-operator-1 is node
# 1, -2 node 2), so the container name gives its node number. Remote operators
# (an already running VM) take the next ranks: only their address and prefix are
# asked.
wan_menu_table() {
    command -v whiptail >/dev/null 2>&1 || return 0
    [ -t 0 ] || return 0
    [ -n "${WAN_NODES:-}" ] && return 0  # already given on the CLI
    [ "${#OPERATOR_DECLS[@]}" -gt 0 ] && return 0  # already declared with --operator

    local total cont k ip ind spec=""
    total=$(wt_input "WAN" "Nombre d'operateurs du WAN, tous sites confondus (1-9) :" "3") || return 0
    [[ "$total" =~ ^[1-9]$ ]] || { wt_msg "Nombre invalide : $total"; return 0; }

    cont=$(wt_input "WAN" "Combien tournent ICI, en conteneur ? (0-${total})" "$(( total > 1 ? total - 1 : total ))") || return 0
    [[ "$cont" =~ ^[0-9]$ ]] && [ "$cont" -le "$total" ] \
        || { wt_msg "Entre 0 et ${total}."; return 0; }

    # Containers: backbone address, prefix from the rank. Nothing to ask.
    for k in $(seq 1 "$cont"); do
        spec="${spec}${spec:+ }${k}:$(op_backbone_ip "$k"):$(( k * 11 ))"
    done
    # The others: only they need an answer.
    for k in $(seq $(( cont + 1 )) "$total"); do
        # Default: the lab VM, the only remote node of the current setup.
        _defip=""; [ "$k" = 3 ] && _defip="192.168.1.123"
        ip=$(wt_input "Operateur distant ${k}/${total}" \
             "Adresse du noeud ${k} (une VM, une autre machine) :" "$_defip") || return 0
        [ -n "$ip" ] || { wt_msg "Adresse vide : noeud ${k} ignore."; continue; }
        ind=$(wt_input "Operateur distant ${k}/${total}" \
              "Indicatif (prefixe d'appel) du noeud ${k} :" "$(( k * 11 ))") || return 0
        spec="${spec}${spec:+ }${k}:${ip}:${ind:-$(( k * 11 ))}"
    done

    WAN_NODES="$spec"
    OPERATOR_COUNT_HINT="$cont"
    WAN_NODE_ID="${WAN_NODE_ID:-1}"
    [ "$cont" -ge 1 ] && WAN_NODE_PER_OP=1 && WAN_NODE_PER_OP_GIVEN=1
    echo -e "  ${CYAN}Table WAN :${NC} $WAN_NODES"
}

# ── WAN questions not covered by the table ─────────────────────────────────
# Each is skipped when the matching CLI option was given: scripted runs stay
# silent, manual runs are guided. Without a terminal (CI, cron) defaults are kept.
wan_menu_complements() {
    command -v whiptail >/dev/null 2>&1 || return 0
    [ -t 0 ] || return 0

    if [ -z "${WAN_HUB_IP:-}" ] && [ "${WAN_HUB_NODE_GIVEN:-0}" != "1" ]; then
        local _c
        _c=$(wt_menu "Inter-STP" "Ou se trouve le hub SS7 (PC 0.0.0) ?" \
            "ip"    "sur une machine dediee, hors table (une VM par exemple)" \
            "ici"   "sur CETTE machine - un conteneur inter-STP sera lance" \
            "noeud" "sur un autre noeud de la table WAN") || return 0
        case "$_c" in
            ip)
                local _ip
                _ip=$(wt_input "Inter-STP" "Adresse du hub (ex: 192.168.1.49) :" "${WAN_HUB_IP:-}") || return 0
                if [ -n "$_ip" ]; then WAN_HUB_IP="$_ip"
                else wt_msg "Adresse vide : le hub restera local."; fi ;;
            noeud)
                local _n
                _n=$(wt_input "Inter-STP" "Numero du noeud qui porte le hub :" "${WAN_HUB_NODE:-1}") || return 0
                [ -n "$_n" ] && WAN_HUB_NODE="$_n" ;;
            *)  WAN_HUB_NODE="$WAN_NODE_ID" ;;
        esac
    fi

    if [ "${WAN_NODE_PER_OP_GIVEN:-0}" != "1" ]; then
        if wt_yesno "Conteneurs" \
"Chaque conteneur doit-il etre un NOEUD a part entiere ?

Oui : conteneur 1 -> noeud ${WAN_NODE_ID}, conteneur 2 -> noeud $((WAN_NODE_ID + 1))...
      (leurs adresses backbone doivent etre joignables des autres noeuds)
Non : ce sont les operateurs du noeud ${WAN_NODE_ID}."; then
            WAN_NODE_PER_OP=1
        fi
    fi
}

# Apply the table (Asterisk, iptables, SMS) once the containers are up.
wan_mesh_apply() {
    local n_operators=$1
    local script_path="$START_REPO/network/setup-wan-mesh.sh"
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[WAN] network/setup-wan-mesh.sh introuvable${NC}"; return 1
    fi
    # ── 4th table field: number of operators per node (WAN_NOPS) ───────────────
    # Written here, where the information is certain: with --op-is-node each node IS
    # a container and carries one operator; otherwise our node carries them all.
    # wan_nodes_spec writes the field only when it differs from 1, so a container
    # table keeps the 3-field form other readers (build-iso.sh, set_stp_ip.sh,
    # diagnostics) expect.
    local _k
    if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
        for _k in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
            WAN_NOPS[$(( ${WAN_NODE_ID:-1} + _k - 1 ))]=1
        done
    else
        WAN_NOPS[${WAN_NODE_ID:-1}]="$n_operators"
    fi

    if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
        # A SINGLE pass with --op-is-node: the script maps operator i to node i and
        # computes ITS peers. One pass per node would write into ALL containers each
        # time, the last one winning.
        bash "$script_path" --docker --op-is-node \
            --nodes "$(wan_nodes_spec)" --id 1 --ops "$n_operators" \
            || echo -e "${RED}[WAN] setup-wan-mesh.sh a echoue${NC}"
    else
        bash "$script_path" --docker \
            --nodes "$(wan_nodes_spec)" --id "$WAN_NODE_ID" --ops "$n_operators" \
            || echo -e "${RED}[WAN] setup-wan-mesh.sh a echoue${NC}"
    fi

}

# ── Preserving the source address of outgoing traffic ──────────────────────
# Docker masquerades everything leaving a bridge: seen from the LAN, all container
# associations come from the host. This does NOT prevent an ASP from joining its
# AS: the inter-STP uses "accept-asp-connections dynamic-permitted"
# (helpers/create_interop.sh) and matches by ROUTING CONTEXT, not source address.
# network/setup-docker-lan-route.sh manages the related POSTROUTING RETURN rule.
#
# Replayed here because docker RE-INSERTS its MASQUERADE rules at the head for
# each network created (one per operator), which would push a RETURN rule behind
# them while "iptables -L" still shows it.
reassert_docker_lan_return() {
    command -v iptables >/dev/null 2>&1 || return 0
    [ "$(id -u)" -eq 0 ] || return 0

    local lan_ip lan_net
    lan_ip="${HOST_LAN_IP:-}"
    [ -n "$lan_ip" ] || lan_ip="$(ip route show default 2>/dev/null | awk '/^default/{print $9; exit}')"
    [ -n "$lan_ip" ] || lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$lan_ip" ] || return 0
    lan_net="${lan_ip%.*}.0/24"

    # If LAN and backbone overlap, the rule would hit bridge-internal traffic:
    # do nothing rather than guess.
    [ "${lan_net%%/*}" = "${INTER_NET_SUBNET%%/*}" ] && return 0

    # ── The RETURN rule is REMOVED, not added ──────────────────────────────────
    # With source addresses preserved, the hub's SCTP INIT ACK is addressed to
    # 172.20.0.x, which the host must route and does not receive back: ASPs stay
    # down ("connect failed (-110)"). Masqueraded to the host's own address, the
    # reply comes back and conntrack hands it to the container.
    # Nothing is lost: the inter-STP distinguishes nodes by ROUTING CONTEXT (1150,
    # 2150, 3150), not by source address.
    # Remove the rule if a previous run left it.
    iptables -t nat -D POSTROUTING -s "$INTER_NET_SUBNET" -d "$lan_net" -j RETURN 2>/dev/null \
        && echo -e "  ${CYAN}[WAN] regle RETURN retiree : les noeuds sortent masques (l'inter-STP les apparie par routing context)${NC}" \
        || true

    # ── FORWARD, without which routing is useless ──────────────────────────────
    # Docker sets a default FORWARD DROP policy: a packet between the LAN and the
    # backbone is silently dropped. DOCKER-USER is evaluated BEFORE docker's rules
    # and docker does not rewrite it. network/setup-docker-lan-route.sh sets the same
    # two rules, but nothing calls it automatically; they are set here, where the
    # function is replayed after each network creation.
    iptables -N DOCKER-USER 2>/dev/null || true
    local _spec
    for _spec in "-s ${lan_net} -d ${INTER_NET_SUBNET}" "-s ${INTER_NET_SUBNET} -d ${lan_net}"; do
        # shellcheck disable=SC2086
        if iptables -C DOCKER-USER $_spec -j ACCEPT 2>/dev/null; then
            continue
        fi
        # shellcheck disable=SC2086
        if iptables -I DOCKER-USER 1 $_spec -j ACCEPT 2>/dev/null; then
            echo -e "  ${CYAN}[WAN] FORWARD autorise (${_spec})${NC}"
        fi
    done

    # ── Already established translations ──────────────────────────────────────
    # The rule only applies to new associations; masqueraded ones keep their
    # translation while they live. Flush those entries so the stacks reconnect.
    #
    # EXCEPT when docker 29 has set its DROP: its "ip raw" table drops, in
    # prerouting, any incoming packet to the backbone not arriving via the bridge.
    # An association restarting with its real source address would get no reply
    # (COOKIE_WAIT); flushing conntrack would cut ASPs that only work thanks to
    # masquerading.
    local _nft_drop=0
    if command -v nft >/dev/null 2>&1; then
        if nft list table ip raw 2>/dev/null \
           | grep -F "${INTER_NET_SUBNET%.*}." | grep -q 'drop'; then
            _nft_drop=1
        fi
    fi
    if [ "$_nft_drop" = "1" ]; then
        echo -e "  ${YELLOW}[WAN] DROP nft de docker actif sur ${INTER_NET_SUBNET} :${NC}"
        echo -e "  ${YELLOW}      purge conntrack SAUTEE (elle couperait les ASP attaches).${NC}"
        echo -e "  ${CYAN}      Backbone en mode routed pour le lever : OSMO_DOCKER_ROUTED=1${NC}"
    elif command -v conntrack >/dev/null 2>&1; then
        # LIMITED to the LAN destination. Without -d this would also flush
        # 172.20.0.x <-> 172.20.0.x flows, i.e. all intra-backbone SS7.
        local _purged
        _purged="$(conntrack -D -s "$INTER_NET_SUBNET" -d "$lan_net" 2>/dev/null | grep -c . || true)"
        echo -e "  ${CYAN}[WAN] ${_purged} traduction(s) heritee(s) effacee(s) vers ${lan_net}${NC}"
    else
        # The lab host case: report explicitly that translations were NOT flushed.
        echo -e "  ${YELLOW}[WAN] conntrack absent : les associations deja masquees gardent${NC}"
        echo -e "  ${YELLOW}      leur traduction jusqu'a leur reconnexion (apt install conntrack)${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# QEMU PoC - default entry of the first menu
# ══════════════════════════════════════════════════════════════════════════════
start_qemu_poc() {
    echo -e "${GREEN}PoC QEMU Calypso - bring-up minimal + qosmo-grgsm/run.sh...${NC}"
    QEMU_POC=1
    start_bridge_mode
}

# ══════════════════════════════════════════════════════════════════════════════
# Virtual mode (multi-operator SS7, formerly "bridge")
# ══════════════════════════════════════════════════════════════════════════════
start_bridge_mode() {
    # This mode CREATES the containers: the private segment derives from the
    # operator, not the node (see _osmo_priv_index).
    export OSMO_PRIV_BY_OP=1
    local n_operators
    declare -A OP_MCC OP_MNC OP_NAME OP_MS

    if [ "${QEMU_POC:-0}" = "1" ]; then
        # ── PoC QEMU ──────────────────────────────────────────────────────────
        n_operators=1
        # Same base as the loops: otherwise OP_ID_BASE=2 would look up OP_MCC[2]
        # while everything is set at [1].
        _b="${OP_ID_BASE:-1}"
        OP_MCC[$_b]="001"; OP_MNC[$_b]="01"; OP_NAME[$_b]="OsmoQEMU"; OP_MS[$_b]=2
        # Single-operator PoC: reference PLMN, the one of the repo's IMSIs. Not
        # derived from the node: no WAN here.
        WAN_ENABLED="false"
        # --wan is still valid in the QEMU PoC: one node = one operator.
        [ "${WAN_MESH:-0}" = "1" ] && wan_mesh_configure 1
        # BRIDGE_NO_PROCESS=0: radio and mobile start with the core (see
        # "Containers start the full stack" below).
        PHY_MODE="faketrx"; BRIDGE_NO_PROCESS="${BRIDGE_NO_PROCESS:-0}"; BRIDGE_QEMU=1
        ENCRYPTION="${ENCRYPTION:-a5 1}"
        echo -e "  ${CYAN}[PoC QEMU] 1 operateur · no-process + qosmo/run.sh · ${ENCRYPTION}${NC}"
    else
        # ── Interactive mode ────────────────────────────────────────────────────
        # Already answered in the WAN menu ("how many run HERE"): not asked again, two
        # diverging answers would make the table and container count disagree.
        if [ -n "${OPERATOR_COUNT_HINT:-}" ]; then
            n_operators="$OPERATOR_COUNT_HINT"
            echo -e "  ${CYAN}Conteneurs a lancer : ${n_operators} (--operators / menu WAN)${NC}"
        else
            # Default 3: the lab size (two containers and one VM). A node missing from the
            # table does not exist for anyone.
            n_operators=$(wt_input "Operateurs" "Nombre d'operateurs (1-36) :" "3") || exit 1
        fi
        n_operators=${n_operators:-2}
        if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 36 ]; then
            wt_msg "Nombre invalide (1-36)."; exit 1
        fi

        # ── The node plan is decided BEFORE the PLMN ────────────────────────────
        # It answers "is each container a separate node?" (WAN_NODE_PER_OP), and the
        # MCC is the node number, so the WAN questions must come before the operator
        # menu. They only depend on the operator count, known above.
        # ── WAN ──────────────────────────────────────────────────────────────
        if [ "${WAN_MESH:-0}" = "1" ]; then
            wan_mesh_configure "$n_operators"
        elif wt_yesno "WAN Interop" "Activer WAN vers un serveur distant (2 serveurs, prefixe 66) ?"; then
            WAN_ENABLED="true"
            local auto_ip=""
            auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
            [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
            local wan_local wan_remote wan_nremote wan_pfx
            wan_local=$(wt_input "WAN" "IP publique locale :" "$auto_ip") || exit 1
            WAN_LOCAL_IP="${wan_local:-$auto_ip}"
            [ -z "$WAN_LOCAL_IP" ] && WAN_ENABLED="false"
            if [ "$WAN_ENABLED" = "true" ]; then
                wan_remote=$(wt_input "WAN" "IP publique distante :" "") || exit 1
                WAN_REMOTE_IP="$wan_remote"
                [ -z "$WAN_REMOTE_IP" ] && WAN_ENABLED="false"
            fi
            if [ "$WAN_ENABLED" = "true" ]; then
                wan_nremote=$(wt_input "WAN" "Nb operateurs distants :" "$n_operators") || exit 1
                WAN_N_REMOTE="${wan_nremote:-$n_operators}"
                wan_pfx=$(wt_input "WAN" "Prefixe WAN :" "$WAN_PREFIX") || exit 1
                WAN_PREFIX="${wan_pfx:-$WAN_PREFIX}"
                echo -e "  ${GREEN}WAN: ${WAN_LOCAL_IP} ↔ ${WAN_REMOTE_IP} (local=${n_operators} remote=${WAN_N_REMOTE} prefix=${WAN_PREFIX})${NC}"
            fi
        fi

        local use_defaults="N"
        wt_yesno "Valeurs par defaut" "Valeurs par defaut pour tous (MCC=001/002/... MNC=01/02/...) ?" && use_defaults="O"

        local same_ms_all="N"
        if [ "$use_defaults" != "O" ]; then
            wt_yesno "MS" "Meme nombre de MS pour tous les operateurs ?" && same_ms_all="O"
        fi

        declare -A OP_MCC OP_MNC OP_NAME OP_MS

        if [ "$use_defaults" = "O" ]; then
            local common_ms
            common_ms=$(wt_input "MS" "MS par operateur (1-64) :" "8") || exit 1
            common_ms=${common_ms:-8}
            if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
            for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
                # One PLMN per operator, on BOTH components: 001/002/003 makes a PLMN
                # mismatch visible.
                OP_MCC[$i]=$(op_mcc "$i"); OP_MNC[$i]=$(op_mnc "$i")
                OP_NAME[$i]="$(op_default_name "$i")"; OP_MS[$i]=$common_ms
            done
        else
            if [ "$same_ms_all" = "O" ]; then
                local common_ms
                common_ms=$(wt_input "MS" "MS par operateur (1-64) :" "8") || exit 1
                common_ms=${common_ms:-8}
                if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
                for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
                    local mcc mnc name dmcc dmnc dname
                    dmcc=$(op_mcc "$i"); dmnc=$(op_mnc "$i"); dname="$(op_default_name "$i")"
                    mcc=$(wt_input "Operateur ${i}" "MCC (pays = noeud $(op_plmn_node "$i"), $(op_country "$i")) :" "$dmcc") || exit 1; OP_MCC[$i]=${mcc:-$dmcc}
                    mnc=$(wt_input "Operateur ${i}" "MNC :" "$dmnc") || exit 1; OP_MNC[$i]=${mnc:-$dmnc}
                    name=$(wt_input "Operateur ${i}" "Nom :" "$dname") || exit 1; OP_NAME[$i]=${name:-$dname}
                    OP_MS[$i]=$common_ms
                done
            else
                for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
                    local mcc mnc name n_ms dmcc dmnc dname
                    dmcc=$(op_mcc "$i"); dmnc=$(op_mnc "$i"); dname="$(op_default_name "$i")"
                    mcc=$(wt_input "Operateur ${i}" "MCC (pays = noeud $(op_plmn_node "$i"), $(op_country "$i")) :" "$dmcc") || exit 1; OP_MCC[$i]=${mcc:-$dmcc}
                    mnc=$(wt_input "Operateur ${i}" "MNC :" "$dmnc") || exit 1; OP_MNC[$i]=${mnc:-$dmnc}
                    name=$(wt_input "Operateur ${i}" "Nom :" "$dname") || exit 1; OP_NAME[$i]=${name:-$dname}
                    # Default 2, not 1: minimum for a MIXED radio (one faketrx and one QEMU
                    # Calypso, like the native operator).
                    n_ms=$(wt_input "Operateur ${i}" "Nombre de MS (1-64) :" "2") || exit 1; OP_MS[$i]=${n_ms:-2}
                    if ! [[ "${OP_MS[$i]}" =~ ^[0-9]+$ ]] || [ "${OP_MS[$i]}" -lt 1 ] || [ "${OP_MS[$i]}" -gt 64 ]; then OP_MS[$i]=1; fi
                done
            fi
        fi


        # ── RAN / Encryption ─────────────────────────────────────────────────
        # BRIDGE_NO_PROCESS=0: radio and mobile start with the core (see
        # "Containers start the full stack" below).
        PHY_MODE="faketrx"; BRIDGE_NO_PROCESS="${BRIDGE_NO_PROCESS:-0}"; BRIDGE_QEMU=1
        ENCRYPTION="${ENCRYPTION:-a5 1}"
        if [ -n "$HANDOFF_MODE_FROM_ENV" ]; then
            # The caller imposed the mode (HANDOFF_MODE in the environment): do not ask
            # again. Otherwise the menu (auto-answered with its first entry in
            # non-interactive mode) would override it.
            echo -e "  ${GREEN}[RAN] mode impose par l appelant : ${CYAN}${HANDOFF_MODE}${NC}"
        elif [ "${WAN_MESH:-0}" = "1" ]; then
            # A WAN node is a complete testbed: it needs a radio of BOTH types for an
            # inter-node call to be carried end to end. Hence hybrid by default (one faketrx +
            # one QEMU Calypso). Prefix with HANDOFF_MODE=... to change it.
            HANDOFF_MODE="faketrx-qemu"; HANDOFF_QEMU_CHOICE="faketrx-qemu"
            echo -e "  ${GREEN}[RAN] WAN → hybride par defaut : ${CYAN}1 faketrx + 1 QEMU Calypso${NC}"
        else
            choose_ran_host
        fi
    fi

    # ── Host IP detection ─────────────────────────────────────────────────
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    HOST_IP="${HOST_IP:-127.0.0.1}"
    REAL_UID=$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}")
    echo -e "${GREEN}IP hote : ${CYAN}${HOST_IP}${NC}  (Linphone)${NC}"
    echo ""

    # ── Where to reach the SS7 hub from here ─────────────────────────────────
    # The hub is UNIQUE for the whole WAN:
    #   this node hosts the hub  → containers reach it internally (172.20.0.10)
    #   another node hosts it    → they go out over the WAN, to ITS address
    WAN_STP_TARGET="$INTER_STP_IP"
    HUB_IS_LOCAL=1
    if [ -n "${WAN_HUB_IP:-}" ]; then
        # Hub given by address: it is not a node and nothing is started here
        # (dedicated inter-STP VM).
        WAN_STP_TARGET="$WAN_HUB_IP"; HUB_IS_LOCAL=0
    elif [ "${WAN_MESH:-0}" = "1" ] && [ "${WAN_NODE_ID}" != "${WAN_HUB_NODE}" ]; then
        WAN_STP_TARGET="${WAN_IP[$WAN_HUB_NODE]:-}"; HUB_IS_LOCAL=0
        if [ -z "$WAN_STP_TARGET" ]; then
            echo -e "${RED}[SS7] le noeud ${WAN_HUB_NODE} (hub) n'est pas dans la table WAN${NC}" >&2
            echo -e "${RED}      (ou designez-le par son adresse : --hub-ip ADRESSE)${NC}" >&2
            exit 1
        fi
    fi

    # ── Backbone network ──────────────────────────────────────────────────
    # OSMO_DOCKER_ROUTED=1: bridge in "routed" mode (docker >= 28). Docker then stops
    # masquerading backbone traffic and does not install the "ip raw" DROP that
    # discards incoming packets to 172.20.0.x not arriving via the bridge (which
    # leaves SCTP associations from the LAN in COOKIE_WAIT).
    # Optional and non fatal: docker < 28 rejects the option and the ordinary
    # (masqueraded) network is used.
    if docker network inspect "$INTER_NET" &>/dev/null; then
        echo -e "  ${CYAN}Reseau backbone ${INTER_NET} deja present${NC}"
    else
        if [ "${OSMO_DOCKER_ROUTED:-0}" = "1" ] \
           && docker network create --subnet="$INTER_NET_SUBNET" --gateway="$INTER_NET_GATEWAY" \
                -o com.docker.network.bridge.gateway_mode_ipv4=routed "$INTER_NET" &>/dev/null; then
            echo -e "  ${GREEN}✓ Reseau backbone ${INTER_NET} (${INTER_NET_SUBNET}) cree - mode routed${NC}"
        elif docker network create --subnet="$INTER_NET_SUBNET" --gateway="$INTER_NET_GATEWAY" "$INTER_NET" &>/dev/null; then
            [ "${OSMO_DOCKER_ROUTED:-0}" = "1" ] \
                && echo -e "  ${YELLOW}  (mode routed refuse par ce docker - reseau ordinaire)${NC}"
            echo -e "  ${GREEN}✓ Reseau backbone ${INTER_NET} (${INTER_NET_SUBNET}) cree${NC}"
        else
            echo -e "  ${RED}✗ Echec creation reseau backbone ${INTER_NET} (${INTER_NET_SUBNET})${NC}"; exit 1
        fi
    fi

    # ── SMS Routing ──────────────────────────────────────────────────────
    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate_all > /dev/null 2>&1; then
        local _ms_counts=()
        for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do _ms_counts+=("${OP_MS[$i]}"); done
        sms_routing_generate_all "$n_operators" "$SMS_ROUTING_DIR" "${_ms_counts[@]}"
        sms_routing_summary "$n_operators" "${_ms_counts[@]}"
    fi

    # ── Inter-STP ────────────────────────────────────────────────────────────
    if [ "$HUB_IS_LOCAL" = "1" ]; then
        start_inter_stp "$n_operators"
        wait_inter_stp_ready "$n_operators"
    else
        echo -e "${CYAN}[SS7] hub porte par le noeud ${WAN_HUB_NODE} (${WAN_STP_TARGET}) - pas de hub ici.${NC}"
        echo -e "${CYAN}      Les ASP de ce noeud s'y attacheront en M3UA/SCTP 2908.${NC}"
    fi

    # ── HLR subscribers ──────────────────────────────────────────────────
    local all_subscribers_file
    all_subscribers_file=$(mktemp)
    echo "# op_id:ms_idx:imsi:msisdn:ki" > "$all_subscribers_file"
    # ── Directory: a fake identity for each IMSI ────────────────────────────
    # Puts a name and address next to each subscriber. Names and streets are
    # FICTITIOUS, but the IMSI is exactly the one sent to the HLR below, from the
    # same loop and variable. Entries come from data/noms.txt and data/adresses.txt
    # (shuffled at load) and are taken IN ORDER, so no two subscribers share a name
    # until the file is exhausted.
    local ANNUAIRE_FILE="${OSMO_ANNUAIRE:-/var/tmp/osmo-annuaire.csv}"
    # ── SS7 directory: the same service one layer down ──────────────────────
    # Maps each POINT CODE to its machine, operator and hub. Produced by the SAME
    # loop as the configurations: a record of what was just written.
    local ANNUAIRE_SS7="${OSMO_ANNUAIRE_SS7:-/var/tmp/osmo-annuaire-ss7.csv}"
    printf 'noeud;operateur;pays;mcc;mnc;pc_msc;pc_stp;pc_bsc;rctx_msc;rctx_stp;rctx_bsc;rctx_inter;hub;as_inter;asp_inter;backbone;prive\n' \
        > "$ANNUAIRE_SS7"
    local _pick=0
    printf 'imsi;msisdn;operateur;pays;mcc;mnc;nom;adresse;ki\n' > "$ANNUAIRE_FILE"
    for op_id in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        local mcc="${OP_MCC[$op_id]}" mnc="${OP_MNC[$op_id]}" n_ms="${OP_MS[$op_id]}"
        local _pays; _pays="$(op_country "$op_id")"
        for ms_idx in $(seq 1 "$n_ms"); do
            local msin; msin=$(printf '%04d%06d' "${op_id}" "${ms_idx}")
            local imsi="${mcc}${mnc}${msin}"
            # Six-digit MSISDN: <node>00<operator><rank>, e.g. 100101, 100102, 200101.
            # The first digit carries the node, so routing can be read from the number and
            # subscriber numbers do not clash with dialplan services (100, 200, 500, 600, 700).
            local msisdn; msisdn=$(osmo_msisdn "$(osmo_node_id)" "$op_id" "$ms_idx")
            local ki; ki=$(printf '00112233445566778899aabbccdd%02x%02x' "${ms_idx}" "${op_id}")
            echo "${op_id}:${ms_idx}:${imsi}:${msisdn}:${ki}" >> "$all_subscribers_file"
            printf '%s;%s;%s;%s;%s;%s;%s;%s %s;%s\n' \
                "$imsi" "$msisdn" "${OP_NAME[$op_id]}" "$_pays" "$mcc" "$mnc" \
                "${POOL_NOMS[$(( _pick % ${#POOL_NOMS[@]} ))]}" \
                "$(( RANDOM % 97 + 1 ))" \
                "${POOL_ADR[$(( _pick % ${#POOL_ADR[@]} ))]}" \
                "$ki" >> "$ANNUAIRE_FILE"
            _pick=$(( _pick + 1 ))
        done
    done
    local total_subs; total_subs=$(( $(wc -l < "$all_subscribers_file") - 1 ))
    echo -e "${GREEN}Abonnes total : ${total_subs}${NC}"
    # Preview: first entries, then the path of the full file.
    awk -F';' 'NR==1 {next}
               NR<=9 {printf "  %-16s %-6s %-16s %-12s %-22s %s\n", $1,$2,$3,$4,$7,$8}
               END {if (NR>9) printf "  ... et %d autres\n", NR-9}' "$ANNUAIRE_FILE"
    echo -e "  ${CYAN}Annuaire complet : ${ANNUAIRE_FILE}${NC}  (aussi /etc/osmocom/annuaire.csv dans chaque conteneur)"
    echo ""

    # ── Clean slate for the operator series ────────────────────────────────
    # The "docker rm -f" below only targets the container of the SAME NAME. A leftover
    # from a previous run (more operators, interrupted series) keeps its published
    # ports and makes the next creation fail ("port is already allocated"). This
    # function RECREATES the whole series, so remove them first.
    local _stale
    _stale="$(docker ps -aq --filter "name=^osmo-operator-" 2>/dev/null)"
    if [ -n "$_stale" ]; then
        echo -e "  ${CYAN}Nettoyage : $(echo "$_stale" | wc -l) conteneur(s) operateur d'un lancement precedent${NC}"
        # shellcheck disable=SC2086
        docker rm -f $_stale >/dev/null 2>&1 || true
    fi

    # ── Sequential operator start ──────────────────────────────────────────
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        local container_name net_name subnet gateway container_ip inter_local_ip rctx_inter
        local n_groups last_group_ip

        container_name=$(op_container "$i")
        net_name="gsm-net-op${i}"
        subnet=$(op_private_net "$i")
        gateway=$(op_private_gw "$i")
        container_ip=$(op_private_ip "$i")
        inter_local_ip=$(op_backbone_ip "$i")
        rctx_inter=$(op_rctx_inter "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        last_group_ip="127.0.0.${n_groups}"

        echo -e "${CYAN}── Operateur ${i} : ${OP_NAME[$i]} ($(op_country "$i"), MCC=${OP_MCC[$i]} MNC=${OP_MNC[$i]}) ──${NC}"
        echo -e "  Backbone   : ${CYAN}${inter_local_ip}${NC}  Prive : ${CYAN}${container_ip}${NC}"
        local _node_i="$WAN_NODE_ID" _op_i="$i"
        if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
            _node_i=$(( WAN_NODE_ID + i - 1 ))
            _op_i=1
            # Node numbers are 1..9: beyond that the point code 1.<node><op>.<role>
            # leaves the ITU 3-8-3 format, no matching AS exists on the hub
            # (helpers/create_interop.sh supports 9 nodes), and network/set-node-id.sh and
            # start-native.sh reject it.
            if [ "$_node_i" -gt 9 ] || [ "$_node_i" -lt 1 ]; then
                echo -e "${RED}[WAN] --node-per-op : l'operateur ${i} tomberait sur le noeud ${_node_i}${NC}" >&2
                echo -e "${RED}      Les numeros de noeud vont de 1 a 9. Avec --wan-id ${WAN_NODE_ID},"' '"${NC}" >&2
                echo -e "${RED}      le maximum est $(( 10 - WAN_NODE_ID )) operateur(s) : baissez --wan-id,"' '"${NC}" >&2
                echo -e "${RED}      reduisez --operators, ou retirez --node-per-op.${NC}" >&2
                exit 1
            fi
        fi
        local _pc_mid="$i" _rctx_inter=""
        if [ "${WAN_MESH:-0}" = "1" ]; then
            _pc_mid="${_node_i}${_op_i}"
            _rctx_inter=$(( _node_i * 1000 + _op_i * 100 + 50 ))
        fi

        # The identity DISPLAYED is the one WRITTEN to the config.
        echo -e "  STP PC     : 1.${_pc_mid}.2  RCTX : ${_rctx_inter:-$rctx_inter}  MS : ${CYAN}${OP_MS[$i]}${NC}"

        # SS7 record of THIS operator, with the values written to its configuration
        # just below.
        printf '%s;%s;%s;%s;%s;1.%s.1;1.%s.2;1.%s.3;%s;%s;%s;%s;%s;as-n%sop%s;asp-n%sop%s;%s;%s\n' \
            "$_node_i" "${OP_NAME[$i]}" "$(op_country "$i")" \
            "${OP_MCC[$i]}" "${OP_MNC[$i]}" \
            "$_pc_mid" "$_pc_mid" "$_pc_mid" \
            "$(op_rctx_msc "$i")" "$(op_rctx_stp "$i")" "$(op_rctx_bsc "$i")" \
            "${_rctx_inter:-$rctx_inter}" "${WAN_STP_TARGET:-127.0.0.1}" \
            "$_node_i" "$_op_i" "$_node_i" "$_op_i" \
            "$inter_local_ip" "$container_ip" >> "$ANNUAIRE_SS7"

        if docker network inspect "$net_name" &>/dev/null; then
            echo -e "  Reseau     : ${CYAN}${net_name}${NC} (deja present)"
        elif docker network create --subnet="$subnet" --gateway="$gateway" "$net_name" &>/dev/null; then
            echo -e "  Reseau     : ${GREEN}✓ ${net_name} (${subnet}) cree${NC}"
        else
            echo -e "  ${RED}✗ Echec creation reseau ${net_name} (${subnet})${NC}"; exit 1
        fi

        # ── The no-masquerade rule, BEFORE the stack connects ──────────────────
        # A NAT decision is taken on the FIRST packet of an association and conntrack
        # keeps it for its lifetime. The rule is re-asserted after EACH network creation
        # (docker re-inserts its MASQUERADE at the head each time), hence before any
        # stack starts.
        reassert_docker_lan_return >/dev/null

        local tmpdir
        tmpdir=$(mktemp -d)
        # Point code plan. Without WAN: 1.<op>.<role>. With WAN the node number is
        # included, otherwise two machines present identical SS7 addresses to the hub.
        # Only RCTX_INTER is overridden: it is the only routing context the hub sees;
        # MSC and BSC contexts stay internal to the container.
        #
        # ONE NODE PER CONTAINER (--node-per-op)
        # By default the machine IS the node and its containers are its operators:
        # 1.<node><op>.<role>.
        #
        # When containers are reachable at THEIR own address (172.20.0.11, .12... routed
        # from the LAN) they are full nodes, like a VM. With --node-per-op, container i
        # becomes node (base + i - 1), carries operator 1 of that node, and its point
        # code is 1.<n>1.<role>.
        RCTX_INTER_OVERRIDE="$_rctx_inter" \
        apply_config_templates "$tmpdir" \
            "$container_ip" "$gateway" \
            "$i" "1.${_pc_mid}.1" "1.${_pc_mid}.2" "1.${_pc_mid}.3" \
            "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}" \
            "$WAN_STP_TARGET" "no shutdown" \
            "$n_operators"

        # The directory travels with the stack: IMSIs are read in logs inside the
        # container, not on the host.
        [ -f "$ANNUAIRE_FILE" ] && cp "$ANNUAIRE_FILE" "$tmpdir/osmocom/annuaire.csv"
        [ -f "$ANNUAIRE_SS7" ]   && cp "$ANNUAIRE_SS7"   "$tmpdir/osmocom/annuaire-ss7.csv"

        # ── Dialplan entries ───────────────────────────────────────────────
        # Asterisk cannot read CSV: write the same entries as one extension per MSISDN
        # in the sub-annuaire context (see configs/extensions.conf), so calls reach the
        # handset with a name.
        {
            printf '; annuaire.conf - genere par start-docker.sh, ne pas editer a la main.\n'
            printf '; Une fiche par abonne du banc. Le repli _X. est dans extensions.conf.\n'
            printf '[sub-annuaire]\n'
            awk -F';' 'NR>1 && $2 != "" {
                gsub(/[^A-Za-z0-9 ._-]/, "", $7); gsub(/[^A-Za-z0-9 ._-]/, "", $3)
                gsub(/[^A-Za-z0-9 ._-]/, "", $4); gsub(/[^A-Za-z0-9 .,_-]/, "", $8)
                printf "exten => %s,1,Set(CALLERID(name)=%s)\n", $2, $7
                printf " same => n,Set(ANNU_OP=%s)\n", $3
                printf " same => n,Set(ANNU_PAYS=%s)\n", $4
                printf " same => n,Set(ANNU_ADR=%s)\n", $8
                printf " same => n,Set(ANNU_IMSI=%s)\n", $1
                printf " same => n,Set(CDR(userfield)=%s / %s / %s)\n", $7, $3, $4
                printf " same => n,NoOp(=== ANNUAIRE %s = %s, %s (%s) ===)\n", $2, $7, $3, $4
                printf " same => n,Return()\n"
            }' "$ANNUAIRE_FILE"
        } > "$tmpdir/asterisk/annuaire.conf" 2>/dev/null || true

        local vol_args alsa_args
        vol_args=$(build_vol_args "$tmpdir")
        alsa_args=$(build_alsa_args)

        # The chown is REQUIRED: this directory is mounted on /var/log/osmocom and the
        # daemons run as osmocom (999:1000 in the image). Owned by root, osmo-hlr cannot
        # create its log file, fails to parse its config and restart-loops, and
        # osmo-start.sh / run.sh abort the whole pipeline.
        mkdir -p /tmp/osmocom-logs/op${i}
        chown 999:1000 /tmp/osmocom-logs/op${i} 2>/dev/null || true

        # ── Ports to expose ──────────────────────────────────────────────────
        local port_args=""

        # ── SIP/RTP: nothing published on the host ─────────────────────────
        # The native operator permanently holds 5060/udp (Asterisk) and 5061
        # (osmo-sip-connector). Containers are on a bridge routable from the host and
        # are reached directly at their own address on the nominal port, so no
        # publication (and no port conflict) is needed.
        local _cip; _cip="$(op_backbone_ip "$i")"
        echo -e "  Linphone   : ${CYAN}${_cip}:5060${NC}  RTP 30000-30199 (direct, sans publication)"

        # Plus WAN ports if enabled (legacy or mesh)
        if wan_active; then
            local sip_port rtp_start rtp_end sms_port
            sip_port=$(wan_sip_port "$i")
            rtp_start=$(wan_rtp_start "$i")
            rtp_end=$(wan_rtp_end "$i")
            port_args="${port_args} -p ${sip_port}:5060/udp -p ${sip_port}:5060/tcp -p ${rtp_start}-${rtp_end}:${rtp_start}-${rtp_end}/udp"
            echo -e "  WAN        : SIP ${sip_port} RTP ${rtp_start}-${rtp_end}"
            if [ "${WAN_MESH:-0}" = "1" ]; then
                # One SMS port PER operator: the remote relay must reach the container of the
                # RIGHT operator, since MT injection goes through that container's HLR. A single
                # port would deliver all SMS to the first operator ("MSISDN not found in HLR").
                sms_port=$(wan_sms_port "$i")
                port_args="${port_args} -p ${sms_port}:7890/tcp"
                echo -e "  WAN SMS    : ${sms_port} → relay 7890"
            fi
        fi

        docker rm -f "$container_name" 2>/dev/null || true
        ensure_host_audio_relay

        # --restart, NOT --rm: with --rm, operator containers would DISAPPEAR on reboot
        # together with their HLR database and anything not mounted from the host. The
        # "docker rm -f" above makes --rm unnecessary, and docker rejects --rm with --restart.
        #
        # OSMO_ROLE=operator: the container regenerates its configs when run.sh replays
        # apply_config_templates, and generate_configs.sh's SS7 identity fix-up silently
        # stops on an empty role (all containers would then use point code 1.1.2).
        # ── --security-opt apparmor=unconfined: required for systemd as PID 1 ──────
        # The entrypoint ends with `exec systemd`, which mounts its API filesystems; Ubuntu's
        # docker-default AppArmor profile forbids mounts regardless of capabilities
        # (CAP_SYS_ADMIN is not enough), and PID 1 exits with code 255:
        #     Failed to mount tmpfs (type tmpfs) on /run/lock ... Permission denied
        # systemd writes this to /dev/console, so it is NOT in `docker logs`; use
        # `docker run -t` to see it.
        # SYS_NICE: c54x_exe/run.sh runs the chain (DSP, QEMU, osmocon, mobile, bridge)
        # under `nice -n -10` (RT_NICE), which needs this capability.
        # shellcheck disable=SC2086
        docker run -d \
            --restart unless-stopped \
            --name "$container_name" \
            --hostname "$container_name" \
            --network "$INTER_NET" \
            --ip "$inter_local_ip" \
            --cap-add NET_ADMIN \
            --cap-add SYS_ADMIN \
            --cap-add NET_RAW \
            --cap-add SYS_NICE \
            --security-opt apparmor=unconfined \
            --ulimit rtprio=18 \
            --shm-size=8g \
            --cgroupns host \
            --device /dev/net/tun:/dev/net/tun \
            $alsa_args \
            $port_args \
            -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            -v /tmp/osmocom-logs/op${i}:/var/log/osmocom \
            --tmpfs /tmp:exec,rw,mode=1777,size=2g \
            --tmpfs /run:exec,size=64m \
            --tmpfs /run/lock \
            -e OPERATOR_ID="$i" \
            -e OSMO_ROLE=operator \
            -e N_MS="${OP_MS[$i]}" \
            -e CONTAINER_IP="$container_ip" \
            -e GATEWAY_IP="$gateway" \
            -e INTER_STP_IP="${WAN_STP_TARGET:-$INTER_STP_IP}" \
            -e OSMO_HUB_IP="${WAN_STP_TARGET:-$INTER_STP_IP}" \
            -e WAN_NODE_ID="${_node_i}" \
            -e OSMO_WAN_NODE="${_node_i}" \
            -e HOST_IP="${HOST_IP}" \
            -e SIP_HOST_PORT="5060" \
            -e PHY_MODE="${PHY_MODE}" \
            -e HOST_AUDIO_RELAY="${HOST_AUDIO_RELAY}" \
            $vol_args \
            "$IMAGE_RUN" \
            sleep infinity

        docker network connect --ip "$container_ip" "$net_name" "$container_name"

        # ── A dead operator does not take down the following ones ──────────────
        # Everything below talks to the container through `docker exec`, which fails on a
        # restarting container, and this script runs under `set -eu`. Check the container
        # really runs first; if not, report it (with the commands that show the real
        # cause, hidden from `docker logs`) and move on to the next operator.
        _st="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo absent)"
        if [ "$_st" != running ]; then
            _rc="$(docker inspect -f '{{.State.ExitCode}}' "$container_name" 2>/dev/null || echo '?')"
            echo -e "  ${RED}[!] ${container_name} n'est pas parti (etat: ${_st}, code: ${_rc}) - operateur SAUTE${NC}"
            echo -e "      ${YELLOW}systemd ecrit son erreur sur /dev/console : elle n'est PAS dans docker logs.${NC}"
            echo -e "      ${CYAN}docker logs ${container_name} | tail${NC}"
            echo -e "      ${CYAN}docker run --rm -t <memes drapeaux> ${IMAGE_RUN} sleep infinity${NC}   (pour la voir)"
            FAILED_OPS="${FAILED_OPS:-} ${container_name}"
            continue
        fi

        force_update_trees "$container_name"

        # ── Containers start the full stack ────────────────────────────────────
        # run.sh starts core (STP, HLR, MSC, BSC, MGW, GGSN, SGSN, PCU) and radio (PHY,
        # mobile, Asterisk, SMSC). It never attaches by itself: everything runs in tmux
        # and only the attach command is printed. The delegated QEMU pipeline honours
        # CALYPSO_NO_ATTACH=1.
        # BRIDGE_NO_PROCESS=1 ./launch/start-docker.sh starts the core only.
        local run_cmd="RUN_NO_PROCESS=${BRIDGE_NO_PROCESS:-0} CALYPSO_NO_ATTACH=1 /etc/osmocom/run.sh"
        echo -e "  ${GREEN}[*] Lancement run.sh...${NC}"
        # run.sh is started detached; its output goes to /var/log/osmocom/run.sh.log
        # (mounted on the host as /tmp/osmocom-logs/opN).
        # ONE start path per container: in QEMU mode each container's radio stack is
        # started later by start-native.sh. run.sh is still needed here: it brings up the
        # core, and the next step (waiting for HLR port 4258, then provisioning
        # subscribers) depends on its HLR. The HLR database survives the later restart.
        docker exec -d "$container_name" bash -c "mkdir -p /var/log/osmocom && { ${run_cmd}; } > /var/log/osmocom/run.sh.log 2>&1"

        # Wait for HLR
        echo -ne "  ${GREEN}[*] Attente HLR (4258)${NC}"
        local retry=0
        while ! docker exec "$container_name" bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
            sleep 2; echo -n "."; retry=$((retry + 1))
            if [ $retry -ge 45 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
        done
        echo -e " ${GREEN}✓${NC}"

        # ── Each HLR only holds its own subscribers ────────────────────────────
        # Copying all lab subscribers into every HLR would fake a roaming that does not
        # exist. Real roaming goes through SS7, not through a database copy.
        local _mine; _mine="$(awk -F: -v op="$i" '$1 == op' "$all_subscribers_file")"
        local _n_mine; _n_mine="$(printf '%s\n' "$_mine" | grep -c . || true)"
        echo -e "  ${GREEN}[*] Alimentation HLR Op${i} (${_n_mine} abonnes)...${NC}"

        # ── Remove subscribers that are no longer in the plan ──────────────────
        # hlr.db survives restarts, so a plan change leaves stale subscribers that keep
        # their MSISDN. osmo-hlr enforces MSISDN uniqueness, so the right subscriber
        # could not get its number ("cannot update MSISDN").
        local _garder; _garder="$(printf '%s\n' "$_mine" | cut -d: -f3 | paste -sd'|' -)"
        {
            echo "#!/bin/bash"
            echo "cat > /tmp/hlr_feed.vty << 'VTYCMDS'"
            echo "enable"
            if [ -n "$_garder" ]; then
                echo "__PURGE__${_garder}"
            fi
            while IFS=: read -r feed_op feed_ms feed_imsi feed_msisdn feed_ki; do
                [[ "$feed_op" =~ ^#.*$ ]] && continue
                echo "subscriber imsi ${feed_imsi} create"
                echo "subscriber imsi ${feed_imsi} update msisdn ${feed_msisdn}"
                echo "subscriber imsi ${feed_imsi} update aud2g comp128v1 ki ${feed_ki}"
            done <<< "$_mine"
            echo "end"
            echo "VTYCMDS"
        } | docker exec -i "$container_name" bash

        # Rejections are NOT counted: osmo-hlr prefixes ALL replies with '%', success
        # included, and "Subscriber already exists" is the NORMAL reply on a restart (the
        # lab is reprovisioned at each start).
        #
        # The only proof that a subscriber is served is its record: read the database
        # back. A subscriber without keys is worse than a missing one - osmo-msc finds it,
        # requests auth vectors, gets none, and rejects the mobile with a SIM-related cause.
        local _sans_cle
        # Purge: LIST with sqlite (the VTY has no filterable "show all") and DELETE
        # through the VTY - osmo-hlr keeps an in-memory cache that a direct SQL DELETE
        # would bypass.
        docker exec "$container_name" bash -c '
            garder="$(sed -n "s/^__PURGE__//p" /tmp/hlr_feed.vty)"
            sed -i "/^__PURGE__/d" /tmp/hlr_feed.vty
            if [ -n "$garder" ] && command -v sqlite3 >/dev/null 2>&1; then
                sqlite3 /var/lib/osmocom/hlr.db "select imsi from subscriber;" 2>/dev/null \
                  | grep -vE "^($garder)$" \
                  | sed "s|^|subscriber imsi |; s|$| delete|" >> /tmp/hlr_purge.vty
            fi
            if [ -s /tmp/hlr_purge.vty ]; then
                { echo enable; cat /tmp/hlr_purge.vty; } > /tmp/hlr_purge_full.vty
                if command -v nc >/dev/null 2>&1; then
                    (sleep 1; cat /tmp/hlr_purge_full.vty; sleep 2) | nc -q2 127.0.0.1 4258 2>/dev/null
                else
                    (sleep 1; cat /tmp/hlr_purge_full.vty; sleep 3) | telnet 127.0.0.1 4258 2>/dev/null
                fi
                echo "  purge : $(grep -c . /tmp/hlr_purge.vty) abonne(s) hors plan supprime(s)" >&2
            fi
            rm -f /tmp/hlr_purge.vty /tmp/hlr_purge_full.vty
            if command -v nc >/dev/null 2>&1; then
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 2) | nc -q2 127.0.0.1 4258 2>/dev/null
            else
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 3) | telnet 127.0.0.1 4258 2>/dev/null
            fi
            rm -f /tmp/hlr_feed.vty
        ' >/dev/null 2>&1 || true

        _sans_cle="$(docker exec "$container_name" bash -c '
            command -v sqlite3 >/dev/null 2>&1 || exit 0
            sqlite3 /var/lib/osmocom/hlr.db "
                select count(*) from subscriber s
                left join auc_2g a on a.subscriber_id = s.id
                where a.subscriber_id is null;" 2>/dev/null' 2>/dev/null)" || true

        if [ "${_sans_cle:-0}" -gt 0 ]; then
            echo -e "  ${RED}✗ HLR Op${i} : ${_sans_cle} abonne(s) SANS CLE - ils ne pourront pas s'authentifier${NC}"
            echo -e "    ${CYAN}docker exec ${container_name} sqlite3 /var/lib/osmocom/hlr.db \"select s.imsi from subscriber s left join auc_2g a on a.subscriber_id=s.id where a.subscriber_id is null;\"${NC}"
        else
            echo -e "  ${GREEN}✓ HLR Op${i} alimente (${_n_mine} abonnes, tous avec cle)${NC}"
        fi

        # Wait for the last group - skipped in no-process mode
        if [ "${BRIDGE_NO_PROCESS:-0}" = "1" ]; then
            echo -e "  ${YELLOW}[no-process] mobile non lance - attente 4247 sautee${NC}"
        else
            echo -ne "  ${GREEN}[*] Attente groupe (${last_group_ip}:4247)${NC}"
            retry=0
            while ! docker exec "$container_name" bash -c "echo >/dev/tcp/${last_group_ip}/4247" 2>/dev/null; do
                sleep 2; echo -n "."; retry=$((retry + 1))
                if [ $retry -ge 90 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
            done
            echo -e " ${GREEN}OK${NC}"
            sleep 3
        fi
        echo -e "  ${GREEN}✓${NC} ${container_name} pret"
        echo ""
    done

    rm -f "$all_subscribers_file"

    # ── Wait for SMS relays ────────────────────────────────────────────────
    if [ "${BRIDGE_NO_PROCESS:-0}" != "1" ] && declare -f sms_routing_wait_ready > /dev/null 2>&1; then
        for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
            sms_routing_wait_ready "$(op_container "$i")" 90 || true
        done
    fi

    # ── WAN ────────────────────────────────────────────────────────────────────
    if [ "${WAN_MESH:-0}" = "1" ]; then
        wan_mesh_apply "$n_operators"
    elif [ "$WAN_ENABLED" = "true" ]; then
        setup_wan_interop "$n_operators" "$WAN_N_REMOTE"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-operateurs demarree !${NC}"
    echo ""
    echo -e "  Inter-STP @ ${CYAN}${INTER_STP_IP}:2908${NC}  PC=0.0.0"
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        local rctx bb_ip n_groups
        rctx=$(op_rctx_inter "$i"); bb_ip=$(op_backbone_ip "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        echo -e "  Op${i} ${OP_NAME[$i]}  STP 1.${i}.2 @ ${bb_ip}  RCTX ${rctx}  [${OP_MS[$i]} MS]"
    done

    echo ""
    echo -e "  ${BOLD}Linphone (depuis l'hote) :${NC}"
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        local bb_ip; bb_ip=$(op_backbone_ip "$i")
        echo -e "    Op${i}: ${CYAN}${bb_ip}:5060${NC}"
    done
    echo -e "    linphone_A / tester → 100  |  linphone_B / testerB → 200"

    if [ "${WAN_MESH:-0}" = "1" ]; then
        echo ""
        echo -e "  ${BOLD}WAN mesh :${NC} noeud ${CYAN}${WAN_NODE_ID}${NC}/${WAN_NODE_COUNT} - indicatif ${CYAN}$(wan_local_ind)${NC}"
        for _r in "${WAN_NODE_LIST[@]}"; do
            [ "$_r" = "$WAN_NODE_ID" ] && continue
            echo -e "    ${CYAN}${WAN_IND[$_r]}${NC}10001 → MS 10001 op1 du noeud ${_r} (${WAN_IP[$_r]})"
        done
    elif [ "$WAN_ENABLED" = "true" ]; then
        echo ""
        echo -e "  ${BOLD}WAN :${NC} ${CYAN}${WAN_LOCAL_IP}${NC} (${n_operators} ops) ↔ ${CYAN}${WAN_REMOTE_IP}${NC} (${WAN_N_REMOTE} ops)  prefix=${WAN_PREFIX}"
    fi
    echo ""

    # ── Checks, right after the launch ─────────────────────────────────────
    #   ss7_check.sh        ASP, AS, routes, SSN - the layer that carries calls.
    #   operator_summary.sh what each operator ACTUALLY has: HLR/VLR subscribers,
    #                       BTS, PDP contexts. --live makes it generate its own dump;
    #                       without it, it would analyse a previous lab's dump.
    #
    # RELATIVE paths, like ./helpers/prepare_host.sh above: this script is run from
    # the repo root. Neither may fail the launch (|| true): the stack is up, its
    # state is only REPORTED.
    # OSMO_SKIP_CHECKS=1 skips them (start-multi.sh sets it and runs its own checks).
    if [ "${OSMO_SKIP_CHECKS:-0}" != "1" ]; then
        if [ -r ./checks/ss7_check.sh ]; then
            echo -e "${GREEN}${BOLD}── Check SS7 ──${NC}"
            bash ./checks/ss7_check.sh || true
            echo ""
        else
            echo -e "  ${YELLOW}checks/ss7_check.sh introuvable - check SS7 saute${NC}"
        fi
        if [ -r ./checks/operator_summary.sh ]; then
            echo -e "${GREEN}${BOLD}── Check operateurs ──${NC}"
            bash ./checks/operator_summary.sh --live || true
            echo ""
        else
            echo -e "  ${YELLOW}checks/operator_summary.sh introuvable - resume saute${NC}"
        fi
    fi

    # --virtualbox: the VMs are created earlier (setup-vbox-interco.sh) and started
    # here, once the hub and local operators are up - a node starting before the hub
    # gets its SCTP refused.
    if [ "${VBOX_INTERCO:-0}" = "1" ]; then
        local _lab="$START_REPO/tools/vbox-wan-lab.sh"
        if [ -x "$_lab" ] || [ -r "$_lab" ]; then
            echo ""
            echo -e "${GREEN}[*] Demarrage des VM du WAN...${NC}"
            bash "$_lab" start || echo -e "  ${YELLOW}⚠ demarrage des VM incomplet${NC}"
        fi
    fi

    # HERE and not earlier: docker re-inserts its MASQUERADE rules at the head of
    # POSTROUTING for EACH network created (one per operator). At this point all
    # networks exist.
    reassert_docker_lan_return

    # Address through which VMs must route to the containers. It changes with the
    # active interface (unplugged cable -> wifi answers with another address).
    local _hostip
    _hostip="${HOST_LAN_IP:-$(ip route show default 2>/dev/null | awk '/^default/{print $9; exit}')}"
    if [ -n "$_hostip" ] && [ "${WAN_MESH:-0}" = "1" ]; then
        echo -e "\n  ${BOLD}Cote VM${NC}, pour joindre les conteneurs :"
        echo -e "    ${CYAN}bash network/set_ip_vm.sh --via ${_hostip} --persist${NC}"
    fi

    echo -e "\n${GREEN}${BOLD}Stack prete !${NC}"

    # ── QEMU mode: handoff to start-native.sh ─────────────────────────────────
    if [ "${BRIDGE_QEMU:-0}" = "1" ]; then
        local _qemu_container; _qemu_container=$(op_container 1)
        echo -e "  ${CYAN}[*] run.sh calypso → ${_qemu_container} (terminal courant)${NC}"
        echo -e "  ${CYAN}[*] mode=${HANDOFF_MODE} pipeline=${HANDOFF_QEMU_CHOICE} chiffrement='${ENCRYPTION}' (choisis sur l'hote, NO_MENU)${NC}"

        # The start-native.sh run INSIDE the container must know its node: it re-checks
        # (and fixes) the SS7 identity before starting the stack. The arguments are built
        # per container by _node_args() below.

        local _wan_env=""
        if [ "${WAN_MESH:-0}" = "1" ]; then
            _wan_env="WAN_NODES='$(wan_nodes_spec)' WAN_NODE_ID='${WAN_NODE_ID}' WAN_OPS='${n_operators}'"
            echo -e "  ${CYAN}[*] WAN mesh transmis au conteneur (noeud ${WAN_NODE_ID}, indicatif $(wan_local_ind))${NC}"
        elif [ "$WAN_ENABLED" = "true" ]; then
            _wan_env="WAN_REMOTE_IP='${WAN_REMOTE_IP}' WAN_PREFIX='${WAN_PREFIX}' WAN_N_REMOTE='${WAN_N_REMOTE:-$n_operators}'"
            echo -e "  ${CYAN}[*] SMS inter-WAN → ${WAN_REMOTE_IP} (prefixe ${WAN_PREFIX})${NC}"
        fi

        # ── Radio stack launch ─────────────────────────────────────────────────
        # start-native.sh is run in each container to bring up the radio stack.
        #
        # Behaviour depends on the number of containers (see below):
        #   - one     : start, THEN attach to the "calypso" tmux session;
        #   - several : start each one detached, sequentially.

        # Node arguments of a container: its place in the WAN plan.
        _node_args() {  # $1 = container index
            # Operator rank is 1 only if EACH container is a node. Otherwise containers share
            # the node and differ by rank (set-node-id.sh would otherwise give container 2 the
            # identity of container 1). Same convention as the plan written above (_node_i / _op_i).
            local _n _op
            if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
                _n=$(( ${WAN_NODE_ID:-1} + $1 - 1 )); _op=1
            else
                _n="${WAN_NODE_ID:-1}"; _op="$1"
            fi
            # ALWAYS fall back to node 1 / operator 1 (also without WAN or with an empty
            # WAN_NODE_ID): start-native.sh needs a valid "--node N" or it exits, and a
            # single node IS node 1 (same as WAN_NODE_ID="${WAN_NODE_ID:-1}" above).
            [[ "$_n"  =~ ^[1-9]$ ]] || _n=1
            [[ "$_op" =~ ^[1-9]$ ]] || _op=1
            printf -- '--node %s --op %s' "$_n" "$_op"
            # The hub only makes sense in mesh mode; an empty `--hub-ip` would shift the
            # following arguments.
            [ "${WAN_MESH:-0}" = "1" ] && [ -n "${WAN_STP_TARGET:-}" ] && \
                printf -- ' --hub-ip %s' "$WAN_STP_TARGET"
            return 0
        }

        echo ""

        # start-native.sh command for a container: node identity + hub + WAN table.
        _hcmd() {  # $1 = container index -> prints the command
            local _na; _na="$(_node_args "$1")"
            # `unset PONT_PY`: the image (Dockerfile.run) pins it to pont.py (grgsm); in DSP
            # mode c54x_exe/run.sh would then start pont.py --dsp-port 6702 and no burst would
            # reach the DSP.
            local _cmd="cd /opt/GSM/osmo-operator && unset PONT_PY && NO_MENU=1"
            # CALYPSO_NO_ATTACH follows OSMO_NO_ATTACH: qosmo-grgsm/run.sh attaches to tmux
            # by default when it has a TTY (NO_ATTACH="${CALYPSO_NO_ATTACH:-0}"), and
            # `docker exec -t` provides one. The variable set on /etc/osmocom/run.sh above
            # does not cross this handoff.
            [ "${OSMO_NO_ATTACH:-0}" = "1" ] && _cmd="$_cmd CALYPSO_NO_ATTACH=1"
            _cmd="$_cmd MODE='${HANDOFF_MODE}' QEMU_CHOICE='${HANDOFF_QEMU_CHOICE}'"
            # The HOST's encryption, not a constant: the container's configs are already
            # written with it (OSMO_NO_REGEN=1 there), and 08-gabarits.sh refuses to start if
            # they differ. CALYPSO_BRIDGE is not forced: 05-run-sh.sh sets it to `none` in DSP
            # mode (c54x_exe/run.sh provides the bridge) and to `pont` in grgsm mode.
            _cmd="$_cmd ENCRYPTION='${ENCRYPTION}' CALYPSO_MODE=shunt_legit"
            [ -n "$_wan_env" ] && _cmd="$_cmd ${_wan_env}"
            _cmd="$_cmd ./start-native.sh ${_na} --force"
            printf '%s' "$_cmd"
        }

        local _c _ct _cmd
        if [ "$n_operators" -eq 1 ] && [ "${OSMO_NO_ATTACH:-0}" != "1" ]; then
            # ── One container: start, then attach ──────────────────────────────
            # ...unless OSMO_NO_ATTACH=1 (launch from an icon or a script such as
            # start-multi.sh, which must get control back for checks and summary). The
            # stack then stays up in its calypso session; attach manually when needed.
            # start-native.sh and run.sh output scrolls in the current terminal, then we
            # ATTACH to the container's "calypso" tmux session. Ctrl-b then d detaches
            # without stopping anything.
            _ct="$(op_container 1)"; _cmd="$(_hcmd 1)"
            echo -e "  ${BOLD}Lancement de la pile radio sur ${_ct} (terminal courant)...${NC}"
            echo ""
            docker exec -ti "$_ct" bash -c "$_cmd"
            echo ""
            echo -e "  ${BOLD}Attache a la session tmux ${CYAN}calypso${NC}${BOLD} de ${_ct}${NC}  ${CYAN}(Ctrl-b puis d pour se detacher)${NC}"
            echo ""
            docker exec -ti "$_ct" tmux attach -t calypso
        else
            # ── Several containers: detached ────────────────────────────────────
            # One terminal cannot attach to N tmux sessions.
            #
            # `docker exec -d`, not `-t`: a pty is closed by docker when the script returns
            # and the kernel sends SIGHUP to the foreground group, i.e. to every daemon the
            # run_modules started with `cmd &`. (The modules also use setsid, see
            # run_modules/_lib/radio.sh.) No pty, no hangup.
            #
            # Output goes, INSIDE the container, to /var/log/osmocom/start-direct.log
            # (mounted on the host as /tmp/osmocom-logs/opN). `wait_bb_vty` returns only once
            # the container's stack is online, so containers start one at a time.
            echo -e "  ${BOLD}${n_operators} conteneurs : lancement detache - journal ${CYAN}/var/log/osmocom/start-direct.log${NC}${BOLD} dans chaque conteneur.${NC}"
            echo ""
            for _c in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
                _ct="$(op_container "$_c")"; _cmd="$(_hcmd "$_c")"
                echo -e "  ${GREEN}────── ${_ct} ──────────────────────────────────${NC}"
                docker exec -d "$_ct" bash -c "mkdir -p /var/log/osmocom && { ${_cmd}; } > /var/log/osmocom/start-direct.log 2>&1"
                wait_bb_vty "$_ct" || echo -e "    ${RED}pile non prete - voir /var/log/osmocom/start-direct.log${NC}"
                echo ""
            done
            echo -e "  ${BOLD}Toutes les piles tournent.${NC} Pour en suivre une :"
            echo -e "    ${CYAN}docker exec -ti <conteneur> tmux attach -t calypso${NC}"
            echo -e "  ${CYAN}Ctrl-b puis d${NC} pour se detacher sans rien arreter."
            echo ""
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# net-host mode
# ══════════════════════════════════════════════════════════════════════════════
start_host_mode() {
    echo -e "${GREEN}Demarrage en mode net-host (1 operateur)...${NC}"
    local src_ip gw_ip
    gw_ip=$(ip route get 1 | awk '{print $3; exit}')
    src_ip=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$src_ip" ] && { echo -e "${RED}Impossible de detecter l'IP hote.${NC}"; exit 1; }
    HOST_IP="$src_ip"

    local n_ms
    n_ms=$(wt_input "net-host" "Nombre de MS :" "1") || exit 1
    n_ms=${n_ms:-1}

    prepare_host_tun
    docker rm -f egprs &>/dev/null || true

    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate > /dev/null 2>&1; then
        sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$n_ms"
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$src_ip" "$gw_ip" \
        "1" "1.1.1" "1.1.2" "1.1.3" \
        "001" "01" "OsmoGSM" \
        "127.0.0.1" "shutdown" "1"

    local vol_args alsa_args
    vol_args=$(build_vol_args "$tmpdir")
    alsa_args=$(build_alsa_args)

    ensure_host_audio_relay
    local nethost_relay=""
    [ -n "$HOST_AUDIO_RELAY" ] && nethost_relay="tcp:127.0.0.1:${WSLG_TCP_PORT}"

    # --rm KEPT here, unlike operator containers: this one runs run.sh (not "sleep
    # infinity") and stops when run.sh returns; --restart would loop on the HOST
    # network, competing with the gnome-terminal session opened right after. It also
    # depends on prepare_host_tun (apn0), gone after a reboot. Restart this mode
    # manually.
    # shellcheck disable=SC2086
    docker run -d --rm --name egprs --net host \
        --cap-add NET_ADMIN --cap-add SYS_ADMIN --cap-add NET_RAW --cap-add SYS_NICE \
        --security-opt apparmor=unconfined \
        --shm-size=8g \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        $alsa_args \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,rw,mode=1777,size=2g \
        -e CONTAINER_IP="$src_ip" -e GATEWAY_IP="$gw_ip" \
        -e OPERATOR_ID="1" -e N_MS="$n_ms" \
        -e INTER_STP_IP="127.0.0.1" \
        -e HOST_IP="${HOST_IP}" -e SIP_HOST_PORT="5060" \
        -e ALSA_OUTPUT="${ALSA_OUTPUT}" -e ALSA_INPUT="${ALSA_INPUT}" \
        -e HOST_AUDIO_RELAY="${nethost_relay}" \
        $vol_args \
        "$IMAGE_RUN" /root/run.sh

    wait_bb_vty "egprs"
    sleep 3

    local _du="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    local _duid; _duid=$(id -u "$_du" 2>/dev/null)
    local _disp="${DISPLAY:-:0}"
    local _xauth="${XAUTHORITY:-/home/$_du/.Xauthority}"
    local _hscript="/tmp/osmo-gnome-host.sh"
    cat > "$_hscript" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;net-host - egprs\007'
echo "=== net-host - egprs run.sh ==="
exec sudo docker exec -ti egprs /bin/bash -c "/root/run.sh; exec bash"
EOF
    chmod +x "$_hscript"
    # ── OSMO_NO_TERM=1: start the stack without a window ──────────────────
    # When launched by a systemd unit (osmo-multi.service, and the desktop icon using
    # it) there is no screen: run.sh is started detached in the container and
    # everything is in the container log (`docker logs egprs`).
    if [ "${OSMO_NO_TERM:-0}" = "1" ]; then
        echo -e "  ${CYAN}[*] run.sh dans egprs (OSMO_NO_TERM=1 : pas de terminal)${NC}"
        docker exec -d egprs /bin/bash -c "/root/run.sh > /var/log/osmocom/run.sh.log 2>&1"
        sleep 0.3
        return 0
    fi
    echo -e "  ${CYAN}[*] run.sh → gnome-terminal${NC}"
    sudo -u "$_du" \
        DISPLAY="$_disp" XAUTHORITY="$_xauth" \
        XDG_RUNTIME_DIR="/run/user/${_duid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_duid}/bus" \
        gnome-terminal -- bash "$_hscript" &
    sleep 0.3
}

# ══════════════════════════════════════════════════════════════════════════════
# Stop
# ══════════════════════════════════════════════════════════════════════════════
stop_all() {
    echo -e "${YELLOW}Arret de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    for _chain in OSMO_WAN_INTEROP OSMO_WAN_MESH; do
        iptables -t nat -D PREROUTING -j "$_chain" 2>/dev/null || true
        iptables -t nat -F "$_chain" 2>/dev/null || true
        iptables -t nat -X "$_chain" 2>/dev/null || true
    done
    echo -e "${GREEN}Arrete.${NC}"
    disable_user_loopback
}

# ══════════════════════════════════════════════════════════════════════════════
# Menus
# ══════════════════════════════════════════════════════════════════════════════
choose_build_mode() {
    [ "${QUICK_EXPLICIT:-0}" = "1" ] && return 0
    local choice
    choice=$(wt_menu "Build de l'image" "Comment (re)construire l'image run ?" \
        "quick"  "Quick - reutilise le cache docker (rapide)" \
        "normal" "Normal - docker build --no-cache (image a neuf)") \
        || { echo "Annule."; exit 1; }
    case "$choice" in
        quick)  QUICK=1 ;;
        normal) QUICK=0 ;;
    esac
}

choose_ran_host() {
    local r
    r=$(wt_menu "RAN - Pipeline QEMU Calypso" \
        "Pipeline radio (conteneur de l'operateur) :" \
        "full-grgsm"   "gr-gsm = le DSP (defaut, valide)" \
        "start-clean"  "Pipeline historique (start-clean.sh)" \
        "full"         "full radio + vrai c54x (WIP)" \
        "shunt"        "DSP shunt canned (bissection FBSB)" \
        "bare"         "QEMU + osmocon only" \
        "faketrx-qemu" "COMBINE : fake_trx vivant + Calypso QEMU" \
        "free"         "menu complet run.sh (--menu)") || exit 1

    if [ "$r" = "faketrx-qemu" ]; then
        HANDOFF_MODE="faketrx-qemu"; HANDOFF_QEMU_CHOICE="faketrx-qemu"
    else
        HANDOFF_MODE="qemu";         HANDOFF_QEMU_CHOICE="$r"
    fi

    local e
    e=$(wt_menu "Chiffrement A5" "Chiffrement :" \
        "1" "A5/1 - chiffrement legacy (defaut)" \
        "0" "A5/0 - pas de chiffrement" \
        "2" "A5/2 - (casse, usage test)") || exit 1
    case "$e" in 0) ENCRYPTION="a5 0" ;; 2) ENCRYPTION="a5 2" ;; *) ENCRYPTION="a5 1" ;; esac
    echo -e "  ${GREEN}[RAN] mode=${CYAN}${HANDOFF_MODE}${NC}${GREEN} pipeline=${CYAN}${HANDOFF_QEMU_CHOICE}${NC}${GREEN} chiffrement=${CYAN}${ENCRYPTION}${NC}"
}

choose_network_mode() {
    local choice
    choice=$(wt_menu "Que lancer ?" "Premier choix :" \
        "qemu"    "PoC QEMU Calypso - qosmo-grgsm/run.sh (defaut)" \
        "virtual" "Reseau VIRTUEL multi-operateurs SS7 (config niveau 2)" \
        "hw"      "SDR physique (net-host) - hw (in dev)") || { echo "Annule."; exit 1; }
    case "$choice" in
        qemu)    NETWORK_MODE="qemu" ;;
        virtual) NETWORK_MODE="bridge" ;;
        hw)      NETWORK_MODE="host" ;;
        *) echo -e "${RED}Choix invalide.${NC}"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
# ── Long options, extracted BEFORE the positional mode ─────────────────────
# The mode is in $1 (qemu|virtual|hw|stop) and the build in quick|normal; this
# pre-pass only removes the long options and keeps the original positionals.
usage_wan() {
    cat <<'USAGE'
Usage : sudo ./launch/start-docker.sh [quick|normal] [--wan ...] [qemu|virtual|hw|stop]

  --wan                   active le WAN a N noeuds (1 a 9) et pose les questions :
                            • nombre de noeuds
                            • IP publique de chaque noeud
                            • indicatif de chaque noeud (prefixe d'appel)
                            • numero du noeud construit par CE lancement
  --wan-nodes "1:IP:IND ..."  meme chose sans question (scriptable)
  --wan-id N              numero du noeud local (sinon deduit des IP locales)
  --wan-conf FICHIER      table a lire/ecrire (defaut /etc/osmo-wan.conf)

  --virtualbox[=N]        monte le WAN entre CETTE machine et des VM VirtualBox
                          (implique --wan). Cette machine devient un noeud, les
                          autres sont des VM sur un segment host-only.
  --vbox-node N           numero de noeud porte par cette machine (defaut 1)
  --hub-node N            noeud qui heberge l'inter-STP, le hub SS7 (defaut 1).
  --hub-ip ADRESSE        inter-STP a une adresse a lui, hors table WAN. Le hub
                          n'est alors PAS un noeud : aucun indicatif, aucun
                          abonne, et rien n'est lance localement.
  --node-per-op           chaque conteneur est un NOEUD (base = --wan-id) et non
                          un operateur de la machine : conteneur 1 -> noeud N,
                          conteneur 2 -> noeud N+1... Point codes 1.<n>1.<role>.
  --host ADRESSE          adresse de CETTE machine vue des VM (defaut : deduite
                          de la route par defaut). Recours quand la machine a
                          plusieurs cartes ou vient de changer d'adresse : c'est
                          par elle que les VM routent vers les conteneurs.
  --operator IP:PREFIXE   declare un operateur du WAN par son adresse et son
                          prefixe d'appel. Repetable ; l'ordre donne les numeros
                          de noeud. Il DECLARE seulement : aucun conteneur n'est
                          lance pour lui - c'est ainsi qu'une VM deja demarree
                          entre dans la table SMS et le dialplan. Les conteneurs
                          restent gouvernes par le nombre d'operateurs demande.
                            --operator 192.168.1.123:11   (la VM, deja lancee)
                            --operator 172.20.0.11:22   (un conteneur d'ici)
                          UN SEUL noeud du WAN doit le porter.
  --build-stp             construit l'image legere osmocom-stp (Dockerfile.stp)
                          pour le hub. Sans elle, le hub tourne sur l'image
                          complete, qui contient aussi osmo-stp.

  Sans --wan, rien ne change : aucun WAN n'est monte.
  Avec --wan, la radio passe en HYBRIDE par defaut (1 faketrx + 1 QEMU Calypso).

  Composer <indicatif><numero> joint ce numero sur le noeud correspondant.
    ex. noeud 1 = indicatif 11, noeud 2 = 22 → depuis 2, "1110001" appelle
    le MS 10001 de l'operateur 1 du noeud 1.
USAGE
}

_pos_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --wan)          WAN_MESH=1 ;;
        --wan=*)        WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-nodes)    WAN_MESH=1; WAN_NODES="${2:-}"; shift ;;
        --wan-nodes=*)  WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-id)       WAN_MESH=1; WAN_NODE_ID="${2:-}"; shift ;;
        --wan-id=*)     WAN_MESH=1; WAN_NODE_ID="${1#*=}" ;;
        --wan-conf)     WAN_CONF_FILE="${2:-}"; shift ;;
        --wan-conf=*)   WAN_CONF_FILE="${1#*=}" ;;
        --build-stp)      BUILD_STP=1 ;;
        --hub-node)       WAN_HUB_NODE="${2:-1}"; WAN_HUB_NODE_GIVEN=1; shift ;;
        # --hub-ip and --node-per-op IMPLY the WAN plan. Without WAN_MESH=1, _pc_mid
        # falls back to the LOCAL plan: point codes 1.1.2 / 1.2.2 and routing contexts
        # 150 / 250, identical on EVERY WAN machine. Two nodes on the same hub would then
        # share PC and context and, with the hub in traffic-mode override, the last ASP
        # attached would silently steal the first one's traffic.
        --hub-ip)         WAN_HUB_IP="${2:-}"; WAN_MESH=1; shift ;;
        --node-per-op)    WAN_NODE_PER_OP=1; WAN_NODE_PER_OP_GIVEN=1; WAN_MESH=1 ;;
        --host)           HOST_LAN_IP="${2:-}"; shift ;;
        --host=*)         HOST_LAN_IP="${1#*=}" ;;
        --operators)      OPERATOR_COUNT_HINT="${2:-}"; shift ;;
        --operators=*)    OPERATOR_COUNT_HINT="${1#*=}" ;;
        --operator)       OPERATOR_DECLS+=("${2:-}"); WAN_MESH=1; shift ;;
        --operator=*)     OPERATOR_DECLS+=("${1#*=}"); WAN_MESH=1 ;;
        --hub-ip=*)       WAN_HUB_IP="${1#*=}"; WAN_MESH=1 ;;
        --hub-node=*)     WAN_HUB_NODE="${1#*=}" ;;
        --virtualbox)     WAN_MESH=1; VBOX_INTERCO=1 ;;
        --virtualbox=*)   WAN_MESH=1; VBOX_INTERCO=1; VBOX_NODES="${1#*=}" ;;
        --vbox-node)      VBOX_HOST_NODE="${2:-1}"; shift ;;
        --vbox-node=*)    VBOX_HOST_NODE="${1#*=}" ;;
        -h|--help)      usage_wan; exit 0 ;;
        *)              _pos_args+=("$1") ;;
    esac
    shift
done

# ── --operator: from the declaration to the WAN table ────────────────────
# "IP:PREFIX" is what the user sees; "id:ip:ind" is what the rest of the code
# expects. Converted here, once.
if [ "${#OPERATOR_DECLS[@]}" -gt 0 ]; then
    if [ -n "${WAN_NODES:-}" ]; then
        echo -e "\033[0;31m--operator et --wan-nodes sont exclusifs : choisissez l'un des deux.\033[0m" >&2
        exit 2
    fi
    # CONTAINERS FIRST, in order: osmo-operator-1 is node 1, -2 node 2... Their
    # address is the backbone one, their prefix the rank default. Operators declared
    # on the CLI take the following ranks.
    _n=0; _spec=""
    _ncont="${OPERATOR_COUNT_HINT:-0}"
    while [ "$_n" -lt "$_ncont" ]; do
        _n=$(( _n + 1 ))
        _spec="${_spec}${_spec:+ }${_n}:172.20.0.$(( 10 + _n )):$(( _n * 11 ))"
    done
    for _d in "${OPERATOR_DECLS[@]}"; do
        _ip="${_d%%:*}"; _ind="${_d##*:}"
        if [ -z "$_ip" ] || [ "$_ip" = "$_d" ] || [ -z "$_ind" ]; then
            echo -e "\033[0;31m--operator : attendu IP:PREFIXE (ex: 192.168.1.123:11), recu '$_d'\033[0m" >&2
            exit 2
        fi
        _n=$(( _n + 1 ))
        _spec="${_spec}${_spec:+ }${_n}:${_ip}:${_ind}"
    done
    WAN_NODES="$_spec"
    echo -e "\033[0;36m  Operateurs declares :\033[0m $WAN_NODES"
fi

set -- ${_pos_args[@]+"${_pos_args[@]}"}

banner
[ "${1:-}" = "stop" ] && { stop_all; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis${NC}"; exit 1; }

case "${1:-}" in
    quick)  QUICK=1; QUICK_EXPLICIT=1; shift ;;
    normal) QUICK=0; QUICK_EXPLICIT=1; shift ;;
esac

docker rm -f $(docker ps -aq --filter "name=osmo-") 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=egprs") 2>/dev/null || true
docker network ls --filter "name=gsm-" -q | xargs -r docker network rm 2>/dev/null || true

# Mode selection
case "${1:-}" in
    qemu)    NETWORK_MODE="qemu" ;;
    virtual) NETWORK_MODE="bridge" ;;
    hw)      NETWORK_MODE="host" ;;
    "")
        if [ "${WAN_MESH:-0}" = "1" ]; then
            # --wan without a mode: a WAN runs on operators, so virtual mode; the build
            # menu (quick/normal) is still shown unless decided on the command line.
            NETWORK_MODE="bridge"
            [ "${QUICK_EXPLICIT:-0}" = "1" ] || { check_whiptail; choose_build_mode; }
        elif [ "${OSMO_MULTI:-0}" = "1" ]; then
            NETWORK_MODE="bridge"
        elif [ "${OSMO_MENU:-1}" = "0" ]; then
            NETWORK_MODE="qemu"
        else
            check_whiptail
            choose_build_mode
            choose_network_mode
        fi
        ;;
    *) echo -e "${RED}Mode inconnu : '$1' (attendu : qemu|virtual|hw|stop)${NC}"; exit 1 ;;
esac

[ "$NETWORK_MODE" = "bridge" ] && check_whiptail
echo -e "${GREEN}Mode : ${CYAN}${NETWORK_MODE}${NC}  ${GREEN}Build : ${CYAN}$([ "${QUICK:-0}" = "1" ] && echo "quick (cache)" || echo "normal (--no-cache)")${NC}"

./helpers/prepare_host.sh
# OSMO_NO_BUILD=1 (start-multi.sh): use the image as is. QEMU_CACHE_BUST breaks
# the cache on every build (git pull + qosmo/c54x_exe rebuild). check_image
# still builds it if missing.
[ "${OSMO_NO_BUILD:-0}" = 1 ] || build_run_image
check_image

case "$NETWORK_MODE" in
    qemu)   start_qemu_poc ;;
    host)   start_host_mode ;;
    bridge) start_bridge_mode ;;
esac
