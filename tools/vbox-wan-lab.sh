#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# tools/vbox-wan-lab.sh - N VirtualBox machines, one WAN node each
#
# Sets up a complete WAN on a single machine: N VMs (1 to 9, 3 by default)
# boot the SAME osmo-operator ISO, on a shared internal network, and each one
# recognises itself as the node whose IP is its own. From an MS of VM 2,
# dialing <code of VM 1> + the number reaches an MS of VM 1.
#
# WHY A SINGLE ISO FOR N VMs
# The node number is NOT frozen in the image: the table is, and
# wan_nodes_detect_self compares the local IPs to that table at boot.
# One image per VM would cost N one-hour builds for a single conf line.
#
# VirtualBox's DHCP is what makes the IP predictable: a fixed address per
# (VM, NIC), so the ISO always finds the same node number. Without it, a VM
# would change identity with each lease.
#
# Usage:
#   tools/vbox-wan-lab.sh check                 # is the host ready? (run first)
#   tools/vbox-wan-lab.sh create   [--nodes 3] [--iso path.iso] [--build-iso]
#   tools/vbox-wan-lab.sh start | stop | status | destroy
#   tools/vbox-wan-lab.sh usb                   # plugged devices + filters
#   tools/vbox-wan-lab.sh usb --vm 2 --add 0bda:2838:RTL-SDR
#   tools/vbox-wan-lab.sh table                 # prints the table without creating anything
#
# create options:
#   --nodes N        number of VMs/nodes, 1 to 9 (default 3)
#   --iso FILE       ISO to boot (default: the most recent in the repo)
#   --build-iso      builds the ISO with the table already inside (sudo, long)
#   --subnet PREFIX  /24 prefix of the segment (default 192.168.56 - the only
#                    range VirtualBox accepts as host-only without configuration)
#   --ram MB         memory per VM (default 4096)
#   --cpus N         vCPU per VM (default 2)
#   --indicatifs "11 22 33"   dialing codes, one per node (default 11 22 33 ...)
#   --no-nat         removes the 2nd adapter (NAT) - no Internet access in the VMs
#
# Hardware passed to the VMs (everything enabled by default):
#   --no-usb         no USB controller at all
#   --usb-filter vid:pid[:name]  captures this device (repeatable, added to the
#                    known list: RTL-SDR, HackRF, bladeRF, LimeSDR, USRP B2xx,
#                    Calypso FT232/CP210x/PL2303/CH340 cables...)
#   --no-audio       no sound card (the GSM audio chain needs one)
#   --audio-driver X pulse | alsa | none (default: detected)
#   --no-vrde        no RDP remote console
#   --share PATH     shared folder (requires the guest additions in the ISO)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=network/wan-nodes.sh
. "$DIR/network/wan-nodes.sh"

NODES=3
# 192.168.56: the range VirtualBox allows out of the box in host-only
# (/etc/vbox/networks.conf is required for any other). It is also used for the
# internal network, where nothing imposes it, so that both modes look alike -
# switching from one to the other must not change the node addresses.
SUBNET="192.168.56"
RAM=4096
CPUS=2
ISO=""
BUILD_ISO=0
WITH_NAT=1
INDS=""
NETNAME="osmowan"
VM_PREFIX="osmo-wan-"

# intnet  : the VMs talk to each other, the host SEES NOTHING of the segment.
# hostonly: the host has a leg on it - essential when the host is itself a
#           WAN node (start-docker.sh --virtualbox). VirtualBox then only
#           allows 192.168.56.0/21, unless /etc/vbox/networks.conf.
# Node number carried by the HOST itself (empty = none, the N nodes are VMs).
# Once set, the segment must be host-only: the host needs a leg on it to talk
# to its peers.
# SS7 hub ISO. Given → one more VM, at ${SUBNET}.1, which ONLY routes M3UA
# between the nodes. Absent → no inter-node SS7, only voice and SMS.
INTERSTP_ISO=""
INTERSTP_VM="osmo-wan-interstp"
HOST_NODE=""
NET_MODE="intnet"
HOSTONLY_IF=""
WITH_USB=1
WITH_AUDIO=1
WITH_VRDE=1
AUDIO_DRIVER=""
SHARE=""
EXTRA_FILTERS=()
USB_VM=""
USB_ADD=""
FIX=0

# ── Devices captured automatically ───────────────────────────────────────────
# Without a filter, VirtualBox leaves EVERYTHING to the host: plugging an SDR
# dongle while the VM runs does nothing at all, silently. One filter per model
# settles it once and for all - the device switches to the VM as soon as it is
# plugged, even hot.
#
# Indicative list: "vbox-wan-lab.sh usb" tells the TRUTH about what is plugged
# and under which vid:pid. Anything missing is added with
# --usb-filter vid:pid:name, without touching this file.
USB_KNOWN=(
    "0bda:2838:RTL-SDR (RTL2838)"
    "0bda:2832:RTL-SDR (RTL2832U)"
    "1d50:6089:HackRF One"
    "1d50:604b:HackRF Jawbreaker"
    "1d50:6066:bladeRF x40/x115"
    "2cf0:5250:bladeRF 2.0 micro"
    "1d50:6108:LimeSDR-USB"
    "2500:0020:USRP B200"
    "2500:0021:USRP B210"
    "2500:0022:USRP B2xx"
    "0403:6001:Cable FT232 (Calypso)"
    "10c4:ea60:Cable CP210x (Calypso)"
    "067b:2303:Cable PL2303 (Calypso)"
    "1a86:7523:Cable CH340 (Calypso)"
    "16c0:0762:Osmocom SIMtrace"
    "1d50:60e3:Osmocom SIMtrace2"
)

ACTION="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)       NODES="${2:-3}"; shift ;;
        --nodes=*)     NODES="${1#*=}" ;;
        --iso)         ISO="${2:-}"; shift ;;
        --iso=*)       ISO="${1#*=}" ;;
        --build-iso)   BUILD_ISO=1 ;;
        --subnet)      SUBNET="${2:-}"; shift ;;
        --subnet=*)    SUBNET="${1#*=}" ;;
        --ram)         RAM="${2:-}"; shift ;;
        --ram=*)       RAM="${1#*=}" ;;
        --cpus)        CPUS="${2:-}"; shift ;;
        --cpus=*)      CPUS="${1#*=}" ;;
        --indicatifs)  INDS="${2:-}"; shift ;;
        --indicatifs=*) INDS="${1#*=}" ;;
        --interstp-iso)   INTERSTP_ISO="${2:-}"; shift ;;
        --interstp-iso=*) INTERSTP_ISO="${1#*=}" ;;
        --no-nat)      WITH_NAT=0 ;;
        --net-mode)    NET_MODE="${2:-}"; shift ;;
        --net-mode=*)  NET_MODE="${1#*=}" ;;
        --hostonly)    NET_MODE="hostonly" ;;
        --host-node)   HOST_NODE="${2:-}"; NET_MODE="hostonly"; shift ;;
        --host-node=*) HOST_NODE="${1#*=}"; NET_MODE="hostonly" ;;
        --fix)         FIX=1 ;;
        --no-usb)      WITH_USB=0 ;;
        --no-audio)    WITH_AUDIO=0 ;;
        --no-vrde)     WITH_VRDE=0 ;;
        --audio-driver)   AUDIO_DRIVER="${2:-}"; shift ;;
        --audio-driver=*) AUDIO_DRIVER="${1#*=}" ;;
        --usb-filter)     EXTRA_FILTERS+=("${2:-}"); shift ;;
        --usb-filter=*)   EXTRA_FILTERS+=("${1#*=}") ;;
        --share)       SHARE="${2:-}"; shift ;;
        --share=*)     SHARE="${1#*=}" ;;
        --vm)          USB_VM="${2:-}"; shift ;;
        --vm=*)        USB_VM="${1#*=}" ;;
        --add)         USB_ADD="${2:-}"; shift ;;
        --add=*)       USB_ADD="${1#*=}" ;;
        --net)         NETNAME="${2:-}"; shift ;;
        --net=*)       NETNAME="${1#*=}" ;;
        -h|--help)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes doit valoir 1 a 9${NC}" >&2; exit 2; }

VBM="$(command -v VBoxManage || command -v vboxmanage || true)"
[ -n "$VBM" ] || { echo -e "${RED}VBoxManage introuvable - installez VirtualBox.${NC}" >&2; exit 1; }
vbm() { "$VBM" "$@" 2>&1 | grep -v 'vboxdrv\|vboxconfig\|recompile the kernel\|You will not be able\|available for the current kernel\|load. Please\|^$' || true; }

# ── `pipefail` + `grep -q` trap ──────────────────────────────────────────────
# `grep -q` exits at the FIRST match; the pipeline producer then gets SIGPIPE
# and dies with 141, and under `set -o pipefail` the pipeline returns 141.
# "Found" would read as "not found", intermittently - depending on whether the
# output fitted in the pipe buffer. So read the whole input, discard the output.
qgrep() { grep "$@" >/dev/null; }

# What the host can do - determined ONCE, used everywhere.
HAS_EXTPACK=0
"$VBM" list extpacks 2>/dev/null | qgrep 'Usable:.*true' && HAS_EXTPACK=1
if [ -z "$AUDIO_DRIVER" ]; then
    if pactl info >/dev/null 2>&1 || [ -S "/run/user/$(id -u)/pulse/native" ]; then AUDIO_DRIVER="pulse"
    elif [ -d /proc/asound ]; then AUDIO_DRIVER="alsa"
    else AUDIO_DRIVER="none"; fi
fi
USB_FILTER_COUNT=0

vm_name() { echo "${VM_PREFIX}$1"; }
node_ip()  { echo "${SUBNET}.$((10 + $1))"; }

# ── Node table ───────────────────────────────────────────────────────────────
build_table() {
    local i ind
    local -a ind_arr=()
    [ -n "$INDS" ] && read -r -a ind_arr <<< "$INDS"
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
    for i in $(seq 1 "$NODES"); do
        ind="${ind_arr[$((i-1))]:-$(wan_default_ind "$i")}"
        # An addressing plan without exception: node N → .1N, VM or host. The
        # host simply gets its own on the host-only interface instead of
        # receiving it through DHCP.
        WAN_IP[$i]="$(node_ip "$i")"
        WAN_IND[$i]="$ind"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$NODES"; WAN_NODE_ID="${HOST_NODE:-1}"
    wan_nodes_validate || exit 1
}

find_iso() {
    local latest
    latest="$(ls -t "$DIR"/osmo-operator-*.iso 2>/dev/null | head -1)"
    [ -n "$latest" ] && { echo "$latest"; return 0; }
    return 1
}

# ── Host-only network: the host takes a leg on the segment ──────────────────
# Needed as soon as the host is itself a WAN node. With an "internal" network
# the VMs talk to each other but the host sees NOTHING - a docker lab on the
# host could not reach its peers, silently.
setup_hostonly() {
    local existing
    existing="$("$VBM" list hostonlyifs 2>/dev/null | awk -F': *' '/^Name:/{print $2; exit}')"
    if [ -n "$existing" ]; then
        HOSTONLY_IF="$existing"
    else
        "$VBM" hostonlyif create >/dev/null 2>&1
        HOSTONLY_IF="$("$VBM" list hostonlyifs 2>/dev/null | awk -F': *' '/^Name:/{print $2; exit}')"
    fi
    [ -n "$HOSTONLY_IF" ] || { echo -e "${RED}creation de l'interface host-only impossible${NC}" >&2; return 1; }

    # The interface carries the host node address (.1N), not a separate one:
    # what the table announces is exactly what the peers will reach.
    local host_ip; host_ip="$(node_ip "${HOST_NODE:-1}")"
    if ! "$VBM" hostonlyif ipconfig "$HOSTONLY_IF" --ip "$host_ip" --netmask 255.255.255.0 >/dev/null 2>&1; then
        # VirtualBox refuses any range outside 192.168.56.0/21 as long as
        # /etc/vbox/networks.conf does not allow it. Explicit message:
        # otherwise only an "E_ACCESSDENIED" that points at nothing.
        echo -e "${RED}VirtualBox refuse ${host_ip} sur ${HOSTONLY_IF}.${NC}" >&2
        echo -e "  Les reseaux host-only sont limites a ${CYAN}192.168.56.0/21${NC} par defaut." >&2
        echo -e "  Soit : ${CYAN}--subnet 192.168.56${NC}" >&2
        echo -e "  Soit, pour autoriser votre plage :" >&2
        echo -e "    ${CYAN}echo '* ${SUBNET}.0/24' | sudo tee -a /etc/vbox/networks.conf${NC}" >&2
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} ${HOSTONLY_IF} @ ${CYAN}${host_ip}${NC} (l'hote sur le segment, noeud ${HOST_NODE:-1})"
}

# ── VM hardware: USB, sound, clipboard, remote console ──────────────────────
# A lab node is a RADIO mock-up: without an SDR dongle passed to the VM and
# without a sound card, only a network core remains. That is why everything
# is enabled by default here, unlike an ordinary test VM.
apply_hardware() {
    local vm="$1" idx="$2" f vid pid name i

    # ── USB ──────────────────────────────────────────────────────────────────
    if [ "$WITH_USB" -eq 1 ]; then
        # xHCI (USB 3) requires the Extension Pack; without it fall back to
        # OHCI (USB 1.1), enough for a Calypso serial cable but NOT for an
        # SDR dongle - the throughput does not keep up and the capture drops
        # without a clear message.
        if [ "$HAS_EXTPACK" -eq 1 ]; then
            vbm modifyvm "$vm" --usb-xhci on
        else
            vbm modifyvm "$vm" --usb-ohci on
        fi
        i=0
        for f in "${USB_KNOWN[@]}" ${EXTRA_FILTERS[@]+"${EXTRA_FILTERS[@]}"}; do
            vid="${f%%:*}"; name="${f#*:}"; pid="${name%%:*}"; name="${name#*:}"
            [ "$name" = "$pid" ] && name="usb-${vid}-${pid}"
            vbm usbfilter add "$i" --target "$vm" --name "$name" \
                --vendorid "$vid" --productid "$pid" >/dev/null 2>&1 && i=$((i+1))
        done
        USB_FILTER_COUNT="$i"
    fi

    # ── Sound ────────────────────────────────────────────────────────────────
    # INPUT AND OUTPUT: the GSM audio chain (osmo-gapk) carries a call both
    # ways. A VM with output only gives a one-way call, which is very hard to
    # diagnose - it looks like a codec problem.
    if [ "$WITH_AUDIO" -eq 1 ]; then
        vbm modifyvm "$vm" --audio-driver "$AUDIO_DRIVER" --audio-controller hda \
            --audio-enabled on --audio-in on --audio-out on
    else
        vbm modifyvm "$vm" --audio-enabled off
    fi

    # ── Comfort: clipboard and drag-and-drop ────────────────────────────────
    vbm modifyvm "$vm" --clipboard-mode bidirectional --drag-and-drop bidirectional

    # ── Remote console ──────────────────────────────────────────────────────
    # The lab starts headless: without this, no way to see the console of a
    # VM that refuses to boot.
    if [ "$WITH_VRDE" -eq 1 ] && [ "$HAS_EXTPACK" -eq 1 ]; then
        vbm modifyvm "$vm" --vrde on --vrde-address 127.0.0.1 --vrde-port "$((3900 + idx))"
    fi

    # ── Shared folder ───────────────────────────────────────────────────────
    if [ -n "$SHARE" ]; then
        vbm sharedfolder add "$vm" --name osmo --hostpath "$SHARE" --automount
    fi
}

# ── create ───────────────────────────────────────────────────────────────────
do_create() {
    build_table
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    printf "║   Banc WAN VirtualBox - %d noeud(s), reseau interne "%-8s ║\n" "$NODES" "${NETNAME}""
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    wan_nodes_summary
    echo ""

    if [ "$BUILD_ISO" -eq 1 ]; then
        echo -e "${GREEN}[1/4] Construction de l'ISO avec la table embarquee...${NC}"
        echo -e "  ${CYAN}sudo $DIR/build-iso.sh --wan --wan-nodes \"$(wan_nodes_spec)\"${NC}"
        sudo "$DIR/build-iso.sh" --wan --wan-nodes "$(wan_nodes_spec)" \
            || { echo -e "${RED}build-iso.sh a echoue${NC}"; exit 1; }
        ISO="$(find_iso)" || { echo -e "${RED}ISO introuvable apres build${NC}"; exit 1; }
    elif [ -z "$ISO" ]; then
        ISO="$(find_iso)" || {
            echo -e "${RED}Aucune ISO. Passez --iso chemin.iso, ou --build-iso.${NC}" >&2; exit 1; }
        echo -e "${GREEN}[1/4] ISO : ${CYAN}${ISO}${NC}"
        echo -e "  ${YELLOW}Verifiez qu'elle a ete construite avec --wan et CETTE table,${NC}"
        echo -e "  ${YELLOW}sinon les VM demarreront sans WAN (start-native.sh --wan a la main).${NC}"
    else
        echo -e "${GREEN}[1/4] ISO : ${CYAN}${ISO}${NC}"
    fi
    [ -r "$ISO" ] || { echo -e "${RED}ISO illisible : $ISO${NC}" >&2; exit 1; }

    # ── Network + fixed-address DHCP ────────────────────────────────────────
    if [ "$NET_MODE" = "hostonly" ]; then
        echo -e "${GREEN}[2/4] Reseau host-only (l'hote est un noeud) + DHCP...${NC}"
        setup_hostonly || exit 1
        NETNAME="HostInterfaceNetworking-${HOSTONLY_IF}"
    else
        echo -e "${GREEN}[2/4] Reseau interne "${NETNAME}" + DHCP...${NC}"
    fi
    if "$VBM" list dhcpservers 2>/dev/null | qgrep "NetworkName:.*${NETNAME}"; then
        vbm dhcpserver modify --network="$NETNAME" \
            --server-ip="${SUBNET}.254" --netmask=255.255.255.0 \
            --lower-ip="${SUBNET}.100" --upper-ip="${SUBNET}.200" --enable
    else
        vbm dhcpserver add --network="$NETNAME" \
            --server-ip="${SUBNET}.254" --netmask=255.255.255.0 \
            --lower-ip="${SUBNET}.100" --upper-ip="${SUBNET}.200" --enable
    fi
    # The DHCP is at .254, NOT .1: .1 is reserved for the inter-STP, the SS7
    # hub shared by the nodes. All node configs name that address literally
    # - it cannot depend on a lease.
    echo -e "  ${GREEN}✓${NC} DHCP ${SUBNET}.254 · inter-STP reserve en ${CYAN}${SUBNET}.1${NC}"

    # ── VM ──────────────────────────────────────────────────────────────────
    echo -e "${GREEN}[3/4] Creation des ${NODES} VM...${NC}"
    for i in $(seq 1 "$NODES"); do
        if [ "$i" = "$HOST_NODE" ]; then
            echo -e "  ${CYAN}-${NC} noeud ${i} : c'est CETTE machine ($(node_ip "$i")), pas de VM"
            continue
        fi
        local vm; vm="$(vm_name "$i")"
        if "$VBM" list vms 2>/dev/null | qgrep "\"${vm}\""; then
            echo -e "  ${YELLOW}⚠${NC} ${vm} existe deja - ignoree (destroy pour repartir a neuf)"
            continue
        fi
        vbm createvm --name "$vm" --ostype Ubuntu_64 --register
        vbm modifyvm "$vm" --memory "$RAM" --cpus "$CPUS" --ioapic on \
            --boot1 dvd --boot2 disk --boot3 none --boot4 none \
            --graphicscontroller vmsvga --vram 64 \
            --rtc-use-utc on --paravirt-provider kvm \
            --nested-hw-virt on
        # NIC1 = the WAN. THIS card is the one the table addresses.
        if [ "$NET_MODE" = "hostonly" ]; then
            vbm modifyvm "$vm" --nic1 hostonly --host-only-adapter1 "$HOSTONLY_IF" --nictype1 virtio
        else
            vbm modifyvm "$vm" --nic1 intnet --intnet1 "$NETNAME" --nictype1 virtio
        fi
        apply_hardware "$vm" "$i"
        if [ "$WITH_NAT" -eq 1 ]; then
            # NIC2 = NAT: Internet egress (apt, osmo-update) and SSH forwarding
            # from the host. It carries NO WAN traffic - its 10.0.2.15 is not
            # in the table, so the node detection is not fooled.
            vbm modifyvm "$vm" --nic2 nat --nictype2 virtio
            vbm modifyvm "$vm" --natpf2 "ssh${i},tcp,127.0.0.1,$((2220 + i)),,22"
            # Dashboard and spectra of the lab, reachable from the host without
            # going through the WAN segment (which must stay clean).
            vbm modifyvm "$vm" --natpf2 "web${i},tcp,127.0.0.1,$((8080 + (i-1)*10)),,8080"
            vbm modifyvm "$vm" --natpf2 "fft${i},tcp,127.0.0.1,$((8081 + (i-1)*10)),,8081"
        fi
        vbm storagectl "$vm" --name IDE --add ide
        vbm storageattach "$vm" --storagectl IDE --port 0 --device 0 --type dvddrive --medium "$ISO"
        # Fixed address: it is what gives the node its IDENTITY.
        vbm dhcpserver modify --network="$NETNAME" --vm="$vm" --nic=1 \
            --fixed-address="$(node_ip "$i")" \
            || echo -e "  ${YELLOW}⚠${NC} adresse fixe refusee pour ${vm} - VirtualBox < 6.1 ?"
        echo -e "  ${GREEN}✓${NC} ${vm}  ${CYAN}$(node_ip "$i")${NC}  indicatif ${CYAN}${WAN_IND[$i]}${NC}$([ "$WITH_NAT" -eq 1 ] && echo "  ssh 127.0.0.1:$((2220 + i))")"
    done

    # ── Inter-STP VM: the SS7 hub, at the reserved .1 address ───────────────
    if [ -n "$INTERSTP_ISO" ]; then
        if "$VBM" list vms 2>/dev/null | qgrep "\"${INTERSTP_VM}\""; then
            echo -e "  ${YELLOW}⚠${NC} ${INTERSTP_VM} existe deja - ignoree"
        elif [ ! -r "$INTERSTP_ISO" ]; then
            echo -e "  ${RED}✗${NC} ISO inter-STP illisible : ${INTERSTP_ISO}"
        else
            vbm createvm --name "$INTERSTP_VM" --ostype Ubuntu_64 --register
            # The hub carries neither radio nor audio: it routes M3UA. So it
            # gets no sound, no USB, nor the 4 GB of a full node.
            vbm modifyvm "$INTERSTP_VM" --memory 1536 --cpus 1 --ioapic on \
                --boot1 dvd --boot2 disk --boot3 none --boot4 none \
                --graphicscontroller vmsvga --vram 16 --rtc-use-utc on \
                --paravirt-provider kvm --audio-enabled off
            if [ "$NET_MODE" = "hostonly" ]; then
                vbm modifyvm "$INTERSTP_VM" --nic1 hostonly --host-only-adapter1 "$HOSTONLY_IF" --nictype1 virtio
            else
                vbm modifyvm "$INTERSTP_VM" --nic1 intnet --intnet1 "$NETNAME" --nictype1 virtio
            fi
            [ "$WITH_NAT" -eq 1 ] && vbm modifyvm "$INTERSTP_VM" --nic2 nat --nictype2 virtio \
                --natpf2 "sshstp,tcp,127.0.0.1,2229,,22"
            vbm storagectl "$INTERSTP_VM" --name IDE --add ide
            vbm storageattach "$INTERSTP_VM" --storagectl IDE --port 0 --device 0 \
                --type dvddrive --medium "$INTERSTP_ISO"
            vbm dhcpserver modify --network="$NETNAME" --vm="$INTERSTP_VM" --nic=1 \
                --fixed-address="${SUBNET}.1" \
                || echo -e "  ${YELLOW}⚠${NC} adresse fixe refusee pour ${INTERSTP_VM}"
            echo -e "  ${GREEN}✓${NC} ${INTERSTP_VM}  ${CYAN}${SUBNET}.1${NC}  hub SS7 (PC 0.0.0)"
        fi
    fi

    echo -e "${GREEN}[4/4] Materiel passe aux VM :${NC}"
    if [ "$WITH_USB" -eq 1 ]; then
        echo -e "  USB        : ${CYAN}$([ "$HAS_EXTPACK" -eq 1 ] && echo 'xHCI (USB 3)' || echo 'OHCI (USB 1.1, sans Extension Pack)')${NC}, ${USB_FILTER_COUNT} filtre(s)"
        if ! id -nG "${SUDO_USER:-$USER}" 2>/dev/null | qgrep -w vboxusers; then
            echo -e "  ${YELLOW}⚠ ${SUDO_USER:-$USER} n'est pas dans le groupe vboxusers :${NC}"
            echo -e "    ${YELLOW}les peripheriques USB resteront a l'hote, sans message d'erreur.${NC}"
            echo -e "    ${CYAN}sudo usermod -aG vboxusers ${SUDO_USER:-$USER}${NC}  puis rouvrir la session"
        fi
    else
        echo -e "  USB        : ${YELLOW}desactive (--no-usb)${NC}"
    fi
    echo -e "  Son        : ${CYAN}${AUDIO_DRIVER}${NC} (entree + sortie)"
    [ "$WITH_VRDE" -eq 1 ] && [ "$HAS_EXTPACK" -eq 1 ] \
        && echo -e "  Console    : ${CYAN}RDP 127.0.0.1:390N${NC} (N = numero de noeud)"
    [ -n "$SHARE" ] && echo -e "  Partage    : ${CYAN}${SHARE}${NC} → /media/sf_osmo (additions invite requises)"
    echo ""
    if ! grep -q '^vboxdrv ' /proc/modules 2>/dev/null; then
        echo ""
        echo -e "  ${YELLOW}vboxdrv n'est pas charge : les VM sont creees mais ne demarreront pas.${NC}"
        echo -e "  ${CYAN}sudo /sbin/vboxconfig${NC}  (recompile le module pour le noyau courant)"
    fi
    do_hint
}

do_hint() {
    build_table
    echo ""
    echo -e "  ${BOLD}Demarrer :${NC} ${CYAN}$0 start${NC}"
    echo ""
    echo -e "  ${BOLD}Dans chaque VM (autologin root) :${NC}"
    echo -e "    ${CYAN}/opt/GSM/osmo-operator/start-native.sh${NC}"
    echo -e "    → la table WAN figee dans l'ISO est appliquee toute seule (WAN_AUTO=1)."
    echo -e "    → sans ISO --wan : ${CYAN}/opt/GSM/osmo-operator/start-native.sh --wan${NC}"
    echo ""
    echo -e "  ${BOLD}Appeler d'un noeud a l'autre :${NC}"
    local a b
    a="${WAN_NODE_LIST[0]}"; b="${WAN_NODE_LIST[$(( ${#WAN_NODE_LIST[@]} > 1 ? 1 : 0 ))]}"
    echo -e "    depuis un MS du noeud ${a} : ${CYAN}${WAN_IND[$b]}10001${NC} → MS 10001 du noeud ${b}"
    echo -e "    SMS : meme numerotation (${CYAN}${WAN_IND[$b]}10001${NC})"
    echo ""
    echo -e "  ${BOLD}Diagnostic dans une VM :${NC} ${CYAN}/opt/GSM/osmo-operator/checks/wan_ss7_check.sh${NC}"
    echo ""
}

do_each() {  # $1 = vboxmanage command on each existing VM
    local i vm found=0
    # The hub first at start: a node coming up before it gets its SCTP
    # refused and does not necessarily retry.
    for i in interstp $(seq 1 9); do
        if [ "$i" = "interstp" ]; then vm="$INTERSTP_VM"; else vm="$(vm_name "$i")"; fi
        "$VBM" list vms 2>/dev/null | qgrep "\"${vm}\"" || continue
        found=1
        case "$1" in
            start)   vbm startvm "$vm" --type headless && echo -e "  ${GREEN}▶${NC} ${vm}" ;;
            stop)    vbm controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || true
                     echo -e "  ${YELLOW}■${NC} ${vm}" ;;
            destroy) vbm controlvm "$vm" poweroff >/dev/null 2>&1 || true
                     sleep 1
                     vbm unregistervm "$vm" --delete >/dev/null 2>&1 || true
                     echo -e "  ${RED}✗${NC} ${vm} supprimee" ;;
            status)
                    local st ip; st="$("$VBM" showvminfo "$vm" --machinereadable 2>/dev/null | awk -F'"' '/^VMState=/{print $2}')"
                    if [ "$i" = "interstp" ]; then ip="${SUBNET}.1 (hub SS7)"; else ip="$(node_ip "$i")"; fi
                    printf '  %-20s %-10s %s\n' "$vm" "${st:-?}" "$ip" ;;
        esac
    done
    [ "$found" = "1" ] || echo -e "  ${YELLOW}aucune VM ${VM_PREFIX}* - lancez "$0 create"${NC}"
}

# The REAL groups of an open session of $1: read /proc/<pid>/status of one of
# its processes. `id -nG` would not do - it queries the database, not the
# session, and would answer "yes" right after a usermod while nothing has
# changed for the programs already running.
session_has_group() {
    local user="$1" grp="$2" gid pid
    gid="$(getent group "$grp" | cut -d: -f3)"
    [ -n "$gid" ] || return 1
    for pid in $(pgrep -u "$user" 2>/dev/null | head -40); do
        [ -r "/proc/$pid/status" ] || continue
        awk -v g="$gid" '/^Groups:/ { for (i=2; i<=NF; i++) if ($i == g) { found=1 } }
                         END { exit !found }' "/proc/$pid/status" && return 0
    done
    return 1
}

# ── check: can the host run the bench? ──────────────────────────────────────
do_check() {
    local rc=0 u="${SUDO_USER:-$USER}"
    echo -e "${BOLD}Hote VirtualBox${NC}"
    printf '─%.0s' $(seq 1 60); echo ""

    echo -e "  ${GREEN}✓${NC} VBoxManage $("$VBM" --version 2>/dev/null | tail -1)"

    if grep -q '^vboxdrv ' /proc/modules 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} module vboxdrv charge"
    else
        echo -e "  ${RED}✗${NC} vboxdrv non charge - aucune VM ne demarrera"
        echo -e "     ${CYAN}sudo /sbin/vboxconfig${NC}"
        if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | qgrep -i enabled; then
            echo -e "     ${YELLOW}Secure Boot est actif : le module doit etre signe et sa cle enrolee (MOK).${NC}"
        fi
        rc=1
    fi

    if [ "$HAS_EXTPACK" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} Extension Pack - USB 2.0/3.0 et console RDP disponibles"
    else
        echo -e "  ${YELLOW}⚠${NC} pas d'Extension Pack : USB 1.1 seulement (insuffisant pour une cle SDR), pas de RDP"
    fi

    # Two distinct states, and that is the WHOLE difficulty of this point:
    #   • /etc/group may already contain the user...
    #   • ...while the current SESSION still runs with the old group list.
    #     Processes inherit their groups at login: `usermod` does not reach
    #     them retroactively. VirtualBox launched from that session still
    #     cannot open /dev/vboxusb - and the error shown speaks of a "busy"
    #     device, never of groups.
    # So look at BOTH: the database, and the real groups of a live process
    # of the user.
    if id -nG "$u" 2>/dev/null | qgrep -w vboxusers; then
        if session_has_group "$u" vboxusers; then
            echo -e "  ${GREEN}✓${NC} ${u} est dans vboxusers, et sa session l'a bien pris"
        else
            echo -e "  ${YELLOW}⚠${NC} ${u} est dans vboxusers, mais ${BOLD}sa session ouverte ne l'a pas encore${NC}"
            echo -e "     Les processus gardent les groupes recus au login."
            echo -e "     ${CYAN}Deconnectez-vous et reconnectez-vous${NC} (ou redemarrez) - puis relancez ce check."
            echo -e "     Pour tester tout de suite, sans quitter la session : ${CYAN}newgrp vboxusers${NC}"
            rc=1
        fi
    else
        echo -e "  ${RED}✗${NC} ${u} n'est PAS dans vboxusers - les filtres USB ne capteront rien"
        if [ "$FIX" -eq 1 ] && [ "$(id -u)" -eq 0 ]; then
            usermod -aG vboxusers "$u" && echo -e "     ${GREEN}✓ ajoute${NC} - deconnectez-vous et reconnectez-vous pour l'activer"
        else
            echo -e "     ${CYAN}sudo usermod -aG vboxusers ${u}${NC}  puis rouvrir la session"
            echo -e "     (ou relancez : ${CYAN}sudo $0 check --fix${NC})"
        fi
        rc=1
    fi

    echo -e "  ${GREEN}✓${NC} son : pilote ${CYAN}${AUDIO_DRIVER}${NC}"

    if find_iso >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ISO : $(find_iso)"
    else
        echo -e "  ${YELLOW}⚠${NC} aucune ISO dans le depot - ${CYAN}$0 create --build-iso${NC}"
    fi

    echo ""
    echo -e "${BOLD}Peripheriques USB branches${NC}"
    printf '─%.0s' $(seq 1 60); echo ""
    do_usb_list
    echo ""
    [ $rc -eq 0 ] && echo -e "  ${GREEN}Hote pret.${NC}" || echo -e "  ${YELLOW}Corrigez les points ci-dessus avant de creer le banc.${NC}"
    return $rc
}

# Lists the host devices and says which ones a bench filter would capture.
do_usb_list() {
    local out vid pid name known f kv kp
    out="$("$VBM" list usbhost 2>/dev/null)"
    if [ -z "$out" ]; then echo -e "  ${YELLOW}aucun peripherique USB visible${NC}"; return 0; fi
    echo "$out" | awk -v RS='' '{print}' | while IFS= read -r line; do :; done
    printf '%s\n' "$out" | awk '
        /^VendorId:/  { v=$0; sub(/.*0x/,"",v); sub(/ .*/,"",v); vid=v }
        /^ProductId:/ { p=$0; sub(/.*0x/,"",p); sub(/ .*/,"",p); pid=p }
        /^Product:/   { pr=$0; sub(/^Product: */,"",pr); prod=pr }
        /^Manufacturer:/ { m=$0; sub(/^Manufacturer: */,"",m); man=m }
        /^Current State:/ { st=$0; sub(/^Current State: */,"",st)
                            if (vid != "") printf "%s:%s|%s|%s|%s\n", vid, pid, man, prod, st
                            vid=""; pid=""; prod=""; man="" }
    ' | while IFS='|' read -r ids man prod st; do
        known=""
        for f in "${USB_KNOWN[@]}" ${EXTRA_FILTERS[@]+"${EXTRA_FILTERS[@]}"}; do
            kv="${f%%:*}"; kp="${f#*:}"; kp="${kp%%:*}"
            [ "${kv}:${kp}" = "$ids" ] && { known="${f#*:*:}"; break; }
        done
        if [ -n "$known" ]; then
            printf '  [0;32m✓[0m %-12s %-34s [0;36m→ capte (%s)[0m\n' "$ids" "${prod:-$man}" "$known"
        else
            printf '    %-12s %-34s %s\n' "$ids" "${prod:-$man}" "$st"
        fi
    done
    echo ""
    echo -e "  ${CYAN}Pour capter un peripherique absent de la liste :${NC}"
    echo -e "    $0 usb --vm 1 --add ${CYAN}vid:pid:nom${NC}"
}

do_usb() {
    if [ -n "$USB_ADD" ]; then
        [ -n "$USB_VM" ] || { echo -e "${RED}--add exige --vm N${NC}" >&2; exit 2; }
        local vm vid pid name idx
        vm="$(vm_name "$USB_VM")"
        "$VBM" list vms 2>/dev/null | qgrep "\"${vm}\"" || { echo -e "${RED}${vm} n'existe pas${NC}" >&2; exit 1; }
        vid="${USB_ADD%%:*}"; name="${USB_ADD#*:}"; pid="${name%%:*}"; name="${name#*:}"
        [ "$name" = "$pid" ] && name="usb-${vid}-${pid}"
        idx="$("$VBM" showvminfo "$vm" --machinereadable | grep -c '^USBFilterName')"
        vbm usbfilter add "$idx" --target "$vm" --name "$name" --vendorid "$vid" --productid "$pid"
        echo -e "  ${GREEN}✓${NC} ${vm} captera ${CYAN}${vid}:${pid}${NC} (${name})"
        echo -e "  ${CYAN}Actif au prochain demarrage de la VM, ou au prochain branchement.${NC}"
    else
        do_usb_list
    fi
}

case "$ACTION" in
    check)   do_check ;;
    usb)     do_usb ;;
    create)  do_create ;;
    start)   echo -e "${GREEN}Demarrage...${NC}"; do_each start ;;
    stop)    echo -e "${YELLOW}Arret...${NC}";    do_each stop ;;
    destroy) echo -e "${RED}Suppression...${NC}"; do_each destroy
             vbm dhcpserver remove --network="$NETNAME" >/dev/null 2>&1 || true ;;
    status)  echo -e "${BOLD}VM du banc WAN :${NC}"; do_each status ;;
    table)   build_table; wan_nodes_summary
             echo ""; echo "  --wan-nodes \"$(wan_nodes_spec)\"" ;;
    ""|-h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo -e "${RED}action inconnue : $ACTION${NC}" >&2; exit 2 ;;
esac
