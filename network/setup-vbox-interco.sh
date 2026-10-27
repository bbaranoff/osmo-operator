#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-vbox-interco.sh - WAN interconnection between THIS machine and
# VirtualBox VMs, on a single PC
#
# The osmo-operator WAN links machines by their public IP. To test it without
# renting N servers, the remote peers are replaced by VMs and the public link
# by a host-only segment: the model is the same, the addresses are local.
#
#
#   ┌─ this machine ─────────────┐        ┌─ VM osmo-wan-2 ─┐  ┌─ VM osmo-wan-3 ─┐
#   │ docker or native lab       │        │ ISO osmo-operator  │  │ ISO osmo-operator  │
#   │ node 1 · prefix 11         │        │ node 2 · 22     │  │ node 3 · 33     │
#   └──────────┬─────────────────┘        └────────┬────────┘  └────────┬────────┘
#              │ vboxnet0 192.168.56.11            │ .12                │ .13
#              └───────────────── host-only segment ───────────────────┘
#
# WHY HOST-ONLY AND NOT "INTERNAL NETWORK"
# An internal network links the VMs TO EACH OTHER and leaves the host out.
# Here the host is itself a node: without a leg on the segment its lab cannot
# reach its peers, and nothing reports it - the trunks simply stay
# "Unavailable". Host-only is the only mode where the host takes part.
#
# THE CONSTRAINT TO KNOW
# VirtualBox refuses any host-only range outside 192.168.56.0/21 as long as
# /etc/vbox/networks.conf does not allow it. Hence this default prefix.
#
# Usage:
#   sudo network/setup-vbox-interco.sh [--nodes N] [--host-node 1]
#                                      [--subnet 192.168.56] [--iso f.iso]
#                                      [--build-iso] [--no-vms] [--indicatifs "11 22"]
#
# Writes the table to /etc/osmo-wan.conf, ready for --wan.
# Called automatically by: start-docker.sh --virtualbox  /  start-native.sh --virtualbox
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$DIR/tools/vbox-wan-lab.sh"
# shellcheck source=network/wan-nodes.sh
. "$DIR/network/wan-nodes.sh"

NODES=""
HOST_NODE=1
SUBNET="192.168.56"
ISO=""
BUILD_ISO=0
NO_VMS=0
INDS=""
PASSTHRU=()

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)       NODES="${2:-}"; shift ;;
        --nodes=*)     NODES="${1#*=}" ;;
        --host-node)   HOST_NODE="${2:-}"; shift ;;
        --host-node=*) HOST_NODE="${1#*=}" ;;
        --subnet)      SUBNET="${2:-}"; shift ;;
        --subnet=*)    SUBNET="${1#*=}" ;;
        --iso)         ISO="${2:-}"; shift ;;
        --iso=*)       ISO="${1#*=}" ;;
        --build-iso)   BUILD_ISO=1 ;;
        --no-vms)      NO_VMS=1 ;;
        --indicatifs)  INDS="${2:-}"; shift ;;
        --indicatifs=*) INDS="${1#*=}" ;;
        --conf)        WAN_CONF_FILE="${2:-}"; shift ;;
        --conf=*)      WAN_CONF_FILE="${1#*=}" ;;
        -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PASSTHRU+=("$1") ;;   # passed as is to the lab (--ram, --usb-filter...)
    esac
    shift
done

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   Interconnexion WAN - cette machine + VM VirtualBox             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Guards ───────────────────────────────────────────────────────────────────
# Run INSIDE a VM, this script can do nothing useful and its error messages
# would not say so: VBoxManage is simply absent there.
if command -v systemd-detect-virt >/dev/null 2>&1; then
    # `|| echo none` would produce two lines when the command exits 1 (the
    # "no virtualisation" case): only the first is kept.
    _virt="$(systemd-detect-virt 2>/dev/null | head -1)" || true
    _virt="${_virt:-none}"
    case "$_virt" in
        oracle|kvm|qemu|vmware|microsoft)
            echo -e "${RED}Vous etes DANS une machine virtuelle (${_virt}).${NC}" >&2
            echo -e "  L'interconnexion VirtualBox se monte depuis l'HOTE." >&2
            echo -e "  Ici, le WAN se configure normalement : ${CYAN}./start-native.sh --wan${NC}" >&2
            exit 1 ;;
    esac
fi

VBM="$(command -v VBoxManage || command -v vboxmanage || true)"
if [ -z "$VBM" ]; then
    echo -e "${RED}VBoxManage introuvable - VirtualBox n'est pas installe.${NC}" >&2
    exit 1
fi
if ! grep -q '^vboxdrv ' /proc/modules 2>/dev/null; then
    echo -e "${RED}Le module vboxdrv n'est pas charge : aucune VM ne demarrera.${NC}" >&2
    echo -e "  ${CYAN}sudo /sbin/vboxconfig${NC}" >&2
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -i enabled >/dev/null; then
        echo -e "  ${YELLOW}Secure Boot actif : le module doit etre signe et sa cle enrolee (MOK).${NC}" >&2
    fi
    exit 1
fi
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis (interface reseau + /etc/osmo-wan.conf).${NC}" >&2; exit 1; }

# ── How many nodes ───────────────────────────────────────────────────────────
if [ -z "$NODES" ]; then
    if [ -t 0 ]; then
        # Same question as ./launch/start-docker.sh --wan, same bounds.
        NODES=$(_wan_ask "WAN VirtualBox" "Nombre de noeuds au total, cette machine comprise (1-9) :" "3") || exit 1
    else
        NODES=3
    fi
fi
[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes doit valoir 1 a 9${NC}" >&2; exit 2; }
[[ "$HOST_NODE" =~ ^[1-9]$ ]] && [ "$HOST_NODE" -le "$NODES" ] \
    || { echo -e "${RED}--host-node doit designer un noeud de 1 a ${NODES}${NC}" >&2; exit 2; }

# ── Allowed range? ───────────────────────────────────────────────────────────
if [ "$SUBNET" != "192.168.56" ] && ! grep -q "${SUBNET}" /etc/vbox/networks.conf 2>/dev/null; then
    echo -e "${YELLOW}Attention : VirtualBox n'autorise que 192.168.56.0/21 en host-only.${NC}"
    echo -e "  Pour ouvrir ${SUBNET}.0/24 : ${CYAN}echo '* ${SUBNET}.0/24' | sudo tee -a /etc/vbox/networks.conf${NC}"
    echo ""
fi

# ── Node table ───────────────────────────────────────────────────────────────
declare -a ind_arr=()
[ -n "$INDS" ] && read -r -a ind_arr <<< "$INDS"
WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
for i in $(seq 1 "$NODES"); do
    # Node N → .1N, no exception for the host: the table reads at a glance
    # and the node number shows in the address.
    WAN_IP[$i]="${SUBNET}.$((10 + i))"
    WAN_IND[$i]="${ind_arr[$((i-1))]:-$(wan_default_ind "$i")}"
    WAN_NODE_LIST+=("$i")
done
WAN_NODE_COUNT="$NODES"
WAN_NODE_ID="$HOST_NODE"
WAN_OPS="${WAN_OPS:-1}"
wan_nodes_validate || exit 1

echo -e "  Cette machine porte le ${BOLD}noeud ${HOST_NODE}${NC} ; les autres sont des VM."
wan_nodes_summary
echo ""

# ── The VM lab does the rest: host-only network, fixed DHCP, hardware ────────
if [ "$NO_VMS" -eq 1 ]; then
    echo -e "  ${YELLOW}--no-vms : ni reseau ni VM crees, seule la table est ecrite.${NC}"
else
    [ -x "$LAB" ] || { echo -e "${RED}tools/vbox-wan-lab.sh introuvable${NC}" >&2; exit 1; }
    lab_args=(create --nodes "$NODES" --host-node "$HOST_NODE" --subnet "$SUBNET"
              --indicatifs "$(for i in "${WAN_NODE_LIST[@]}"; do printf '%s ' "${WAN_IND[$i]}"; done)")
    [ -n "$ISO" ]          && lab_args+=(--iso "$ISO")
    [ "$BUILD_ISO" -eq 1 ] && lab_args+=(--build-iso)
    bash "$LAB" "${lab_args[@]}" ${PASSTHRU[@]+"${PASSTHRU[@]}"} || {
        echo -e "${RED}La creation du banc a echoue.${NC}" >&2; exit 1; }
fi

# ── Persisted table ──────────────────────────────────────────────────────────
# WAN_AUTO=0 on the host side: here start-docker.sh / start-native.sh decides
# when to bring up the WAN. The VM ISOs are built with WAN_AUTO=1.

WAN_AUTO=0 wan_nodes_save "$WAN_CONF_FILE"
echo -e "  ${GREEN}✓${NC} table ecrite dans ${CYAN}${WAN_CONF_FILE}${NC}"
echo ""
echo -e "  ${BOLD}Ensuite, sur cette machine :${NC}"
echo -e "    ${CYAN}sudo ./launch/start-docker.sh --wan${NC}          (le lab docker devient le noeud ${HOST_NODE})"
echo -e "    ${CYAN}tools/vbox-wan-lab.sh start${NC}    (demarre les VM)"
echo ""
