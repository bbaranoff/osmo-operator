#!/bin/bash
# =============================================================================
# network/set_ip_vm.sh - makes a VM able to reach the docker containers
#
# The problem in one line: the ISO sets docker-plan addresses on the NIC
# (172.20.0.1/24, 172.20.0.11/24, 172.20.1.10/24), meant for a single machine
# running everything. On a bench where the containers live on a separate
# HOST, these addresses lie:
#
#   1. the /24 pretends 172.20.0.0/24 is on the local link. The VM ARPs for
#      it on the LAN instead of routing it, and
#          ip route add 172.20.0.0/24 via <host>
#      is refused with "RTNETLINK answers: File exists".
#   2. 172.20.0.11 is the address of the FIRST operator CONTAINER. The VM
#      answers itself: the most confusing failure of all, since everything
#      "works" locally and nothing ever reaches the container.
#
# This script removes what lies, keeps what serves, and installs the route.
# Everything is derived at run time - interface, present addresses, networks -
# nothing is hard-coded: the same command applies to the three bench VMs.
#
# WHAT IT DOES NOT DO: break a running stack. An address a daemon listens on
# is reported and KEPT, unless --force. An incomplete routing beats an
# osmo-stp that no longer restarts.
#
# Usage:
#   sudo network/set_ip_vm.sh --via 192.168.1.101      the host carrying docker
#   sudo network/set_ip_vm.sh                          --via asked, or re-read
#   sudo network/set_ip_vm.sh --status                 status, changes nothing
#   sudo network/set_ip_vm.sh --undo                   removes the route
#
#   --via ADDRESS      docker host (router towards the backbone)
#   --docker-net CIDR  container backbone (default 172.20.0.0/24)
#   --iface NAME       interface (default: the one of the default route)
#   --keep ADDRESS     address NOT to remove (repeatable)
#   --force            removes even the addresses a daemon listens on
#   --hub-ip ADDRESS   writes the inter-STP to aim at in osmo-stp.cfg, lifts
#                      the ASP's shutdown, then aligns the source on the route
#                      that leads there. Without it, only the source is aligned.
#   --no-stp           does not touch osmo-stp.cfg (ASP source)
#   --defaut           applies the bench configuration without asking.
#                      The docker host is NOT assumed: it is searched on the
#                      network read from the interface - the only machine that
#                      can reach the container backbone. --via fixes it.
#   --persist          replayed at boot (systemd unit)
#   --dry-run          shows, does not apply
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOCKER_NET="172.20.0.0/24"
VIA=""
IFACE=""
FORCE=0
NO_STP=0
# --hub-ip: the inter-STP this ASP must aim at. Without it, the source is only
# ALIGNED on the remote-ip already written - worthless when that remote-ip is
# still the template default (127.0.0.1): it would validate a configuration
# that will never reach anyone. With it, the destination is WRITTEN, then the
# source that leads there.
HUB_IP=""
USE_DEFAULTS=0
# ── The bench configuration, in a word ──────────────────────────────────────
# --defaut applies what holds on all our VMs without asking: the host carrying
# docker, the container backbone, and persistence at boot (the live system
# has none, the route would be lost at reboot).
# Each value can still be overridden: --defaut --via X wins over the default.
DEFAULT_VIA=""                  # discovered: see discover_docker_host()
DEFAULT_DOCKER_NET="172.20.0.0/24"
DRY=0
PERSIST=0
ACTION="apply"
KEEP=()
STATE=/etc/osmo-docker-host          # remembers --via, so it is typed only once

while [ $# -gt 0 ]; do
    case "$1" in
        --via)          VIA="${2:-}"; shift ;;
        --via=*)        VIA="${1#*=}" ;;
        --docker-net)   DOCKER_NET="${2:-}"; shift ;;
        --docker-net=*) DOCKER_NET="${1#*=}" ;;
        --iface)        IFACE="${2:-}"; shift ;;
        --iface=*)      IFACE="${1#*=}" ;;
        --keep)         KEEP+=("${2:-}"); shift ;;
        --keep=*)       KEEP+=("${1#*=}") ;;
        --force)        FORCE=1 ;;
        --hub-ip)       HUB_IP="${2:-}"; shift ;;
        --hub-ip=*)     HUB_IP="${1#*=}" ;;
        --no-stp)       NO_STP=1 ;;
        --defaut|--default) USE_DEFAULTS=1 ;;
        --persist)      PERSIST=1 ;;
        --dry-run)      DRY=1 ;;
        --status)       ACTION="status" ;;
        --undo)         ACTION="undo" ;;
        -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

run() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }

# ── Finding the docker host, without naming it ──────────────────────────────
# A hard-coded address does not survive the bench: the host switching from
# ethernet to wifi changes its address, and every VM would route towards a
# machine that no longer exists - "connect failed" everywhere, with no
# configuration having changed.
#
# It is therefore searched by what it DOES, not by its name: the only machine
# on the LAN that can reach the container backbone. For each live machine the
# route is installed on trial and the first container is probed; the one that
# answers is the host. The route is removed when the trial fails - nothing
# remains of an unsuccessful attempt.
discover_docker_host() {
    local prefix probe live c saved
    # This function INSTALLS routes to find the right one, without going
    # through run(): under --dry-run it is skipped, so the routing table of
    # the machine stays untouched, as the mode promises.
    if [ "$DRY" = 1 ]; then
        echo -e "    [dry-run] decouverte sautee : elle pose des routes a l'essai - donnez --via" >&2
        return 1
    fi
    # Without root, "ip route replace" would fail silently for every
    # candidate: the loop would run to the end, VIA would come out empty and
    # --defaut would exit on "--via manquant" - a message naming the wrong
    # cause. The general root check comes later, too late for this one.
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "    decouverte impossible sans root (elle pose des routes a l'essai) - donnez --via" >&2
        return 1
    fi
    # The network is read from the interface, never assumed.
    [ -n "$LAN_IP" ] || return 1
    prefix="${LAN_IP%.*}"
    probe="$(echo "$DOCKER_NET" | cut -d. -f1-3).11"   # the first container

    echo -e "  ${CYAN}Recherche de l'hote docker sur ${prefix}.0/24...${NC}" >&2
    # 1. who is alive? (in parallel, one second in total)
    live="$(for c in $(seq 1 254); do
                [ "${prefix}.${c}" = "$LAN_IP" ] && continue
                ping -c1 -W1 "${prefix}.${c}" >/dev/null 2>&1 && echo "${prefix}.${c}" &
            done; wait)"
    [ -n "$live" ] || return 1

    # 2. which one routes to the containers?
    saved="$(ip -4 route show "$DOCKER_NET" 2>/dev/null | head -1)"
    for c in $live; do
        ip route replace "$DOCKER_NET" via "$c" 2>/dev/null || continue
        if ping -c1 -W1 "$probe" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} hote docker : ${CYAN}${c}${NC} (il joint ${probe})" >&2
            printf '%s' "$c"; return 0
        fi
    done
    # nothing found: restore what was there
    ip route del "$DOCKER_NET" 2>/dev/null || true
    [ -n "$saved" ] && ip route add $saved 2>/dev/null || true
    return 1
}

# ── The interface: the one carrying the default route ───────────────────────
[ -n "$IFACE" ] || IFACE="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')"
[ -n "$IFACE" ] || { echo -e "${RED}Aucune interface par defaut - precisez --iface${NC}" >&2; exit 1; }

# ── The machine's address ON THE LAN ────────────────────────────────────────
# Taken from the default route, not from the address list: the ISO also sets
# the private plan (192.168.<n>.1/32 and .10/32), so a simple "the first one
# that is not 172.20" would pick 192.168.2.1 - a local address, on no segment -
# and the host discovery would sweep the wrong network. The source of the
# default route is, by construction, the one that goes out.
LAN_IP="$(ip route show default 2>/dev/null | awk '/^default/{print $9; exit}')"
[ -n "$LAN_IP" ] || LAN_IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
          | awk '$0 !~ /\/32/ {print $4}' | cut -d/ -f1 | grep -vE '^172\.20\.' | head -1)"

# ── --defaut: the bench table, without asking ───────────────────────────────
# This block comes AFTER the interface and LAN address are read, and must stay
# there: discover_docker_host sweeps the network read from the interface.
# Placed earlier, LAN_IP would not exist yet and set -u would kill the
# substitution's subshell - the search would never start, VIA would stay
# empty, and --defaut would exit on "--via manquant" (code 2) although its
# role is precisely to have nothing to ask.
if [ "$USE_DEFAULTS" = "1" ]; then
    [ -n "$VIA" ] || VIA="$(awk -F= '/^OSMO_DOCKER_HOST=/{print $2}' "$STATE" 2>/dev/null | tr -d ' \r')"
    [ -n "$VIA" ] || VIA="$(discover_docker_host || true)"
    [ "$DOCKER_NET" = "172.20.0.0/24" ] && DOCKER_NET="$DEFAULT_DOCKER_NET"
    PERSIST=1
    echo -e "${CYAN}  --defaut : hote docker ${VIA}, backbone ${DOCKER_NET}, rejoue au boot${NC}"
fi

# The docker plan prefix, to recognise the addresses to remove:
# 172.20.0.0/24 -> "172.20." (the whole /16, since the ISO also sets 172.20.1.x)
DOCKER_PREFIX="$(echo "$DOCKER_NET" | cut -d. -f1-2)."

echo -e "${CYAN}${BOLD}== Adressage VM vers les conteneurs docker ==${NC}"
echo -e "  interface : ${CYAN}${IFACE}${NC}   adresse LAN : ${CYAN}${LAN_IP:-?}${NC}"
echo -e "  backbone  : ${CYAN}${DOCKER_NET}${NC}"

# ── What is lying around ────────────────────────────────────────────────────
mapfile -t STALE_ADDRS < <(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
    | awk '{print $4}' | grep "^${DOCKER_PREFIX}" || true)
mapfile -t STALE_ROUTES < <(ip -4 route show dev "$IFACE" 2>/dev/null \
    | awk '$1 ~ /^'"${DOCKER_PREFIX//./\\.}"'/ && /scope link/ {print $1}' || true)

# ── --status ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    echo ""
    if [ "${#STALE_ADDRS[@]}" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} aucune adresse ${DOCKER_PREFIX}x sur ${IFACE}"
    else
        echo -e "  ${YELLOW}adresses du plan docker encore posees :${NC}"
        for a in "${STALE_ADDRS[@]}"; do echo "    $a"; done
    fi
    cur="$(ip -4 route show "$DOCKER_NET" 2>/dev/null | head -1)"
    if echo "$cur" | grep -q " via "; then
        echo -e "  ${GREEN}✓${NC} route : ${cur}"
    elif [ -n "$cur" ]; then
        echo -e "  ${RED}✗${NC} route CONNECTEE (pas de via) : ${cur}"
        echo -e "     tant qu'elle existe, les conteneurs sont injoignables."
    else
        echo -e "  ${YELLOW}–${NC} aucune route vers ${DOCKER_NET}"
    fi
    exit 0
fi

[ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] \
    || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }

# ── --undo ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "undo" ]; then
    run ip route del "$DOCKER_NET" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route retiree" \
        || echo -e "  ${YELLOW}–${NC} pas de route a retirer"
    rm -f /etc/systemd/system/osmo-docker-route.service 2>/dev/null && \
        systemctl disable osmo-docker-route.service >/dev/null 2>&1
    exit 0
fi

# ── The docker host ─────────────────────────────────────────────────────────
# Remembered: typed only once per machine. Without a terminal and without a
# saved value, stop rather than invent a gateway.
[ -n "$VIA" ] || VIA="$(awk -F= '/^OSMO_DOCKER_HOST=/{print $2}' "$STATE" 2>/dev/null | tr -d ' \r')"
if [ -z "$VIA" ] && [ -t 0 ]; then
    def=""
    [ -n "$LAN_IP" ] && def="${LAN_IP%.*}.101"
    printf '  Adresse de l hote qui porte docker [%s] : ' "${def:-?}"
    read -r VIA || VIA=""
    [ -n "$VIA" ] || VIA="$def"
fi
if [ -z "$VIA" ]; then
    echo -e "  ${RED}✗ --via manquant : j'ignore par ou joindre ${DOCKER_NET}${NC}" >&2
    exit 2
fi
if ! [[ "$VIA" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo -e "  ${RED}✗ '${VIA}' n'est pas une IPv4${NC}" >&2; exit 2
fi
echo -e "  hote docker : ${CYAN}${VIA}${NC}"

# ── This script is for the VMs. Not for the host carrying docker ────────────
# Run on the host, it would install a route towards ITSELF, overriding the
# connected route of the docker bridge: immediate "Destination Host
# Unreachable" towards its own containers - although they run fine.
#
# Two signs give it away, and one is enough:
#   - --via is a local address;
#   - a bridge already carries the container network.
#
# The two ways of "carrying" that network must not be confused:
#   a docker BRIDGE (br-xxxx, docker0)   -> this is the host, stop;
#   an ordinary card (enp0s3...)         -> these are precisely the stale ISO
#                                           aliases, and that is our job.
# Refusing both would block on the very VM this script is meant to repair.
#
_self=0
ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -qx "$VIA" && _self=1
_dev="$(ip -4 -o route show "$DOCKER_NET" 2>/dev/null | awk '/proto kernel/{print $3; exit}')"
_bridge=""
case "$_dev" in br-*|docker*|virbr*) _bridge="$_dev" ;; esac
if [ "$_self" = 1 ] || [ -n "$_bridge" ]; then
    echo ""
    echo -e "  ${RED}✗ Cette machine EST l'hote docker - rien a faire ici.${NC}" >&2
    [ "$_self" = 1 ] && echo -e "     ${VIA} est une de ses propres adresses." >&2
    [ -n "$_bridge" ] && echo -e "     ${DOCKER_NET} est deja porte par ${_bridge}." >&2
    echo -e "  ${YELLOW}Ce script se lance SUR LES VM${NC}, pour leur apprendre le chemin" >&2
    echo -e "  vers les conteneurs. Cote hote, c'est l'autre script :" >&2
    echo -e "     ${CYAN}sudo network/setup-docker-lan-route.sh --push \"<ip des VM>\"${NC}" >&2
    exit 2
fi
echo ""

# ── 1. Remove what lies ─────────────────────────────────────────────────────
# An address a daemon LISTENS on is not removed: deleting it would bring down
# the service bound to it, and the problem would become worse than the one
# being fixed.
for a in ${STALE_ADDRS[@]+"${STALE_ADDRS[@]}"}; do
    ip_only="${a%%/*}"
    skip=0
    for k in ${KEEP[@]+"${KEEP[@]}"}; do [ "$k" = "$ip_only" ] && skip=1; done
    if [ "$skip" = 1 ]; then
        echo -e "  ${CYAN}–${NC} ${a} conservee (--keep)"; continue
    fi
    if [ "$FORCE" != 1 ] && ss -Hlnp 2>/dev/null | grep -q "[^0-9]${ip_only}:"; then
        echo -e "  ${YELLOW}⚠${NC} ${a} CONSERVEE : un demon y ecoute"
        echo -e "     (relancez la pile puis --force, ou --keep pour l'assumer)"
        continue
    fi
    # An address a CONFIG names, even if nothing listens yet. That is the
    # idle case: the stack is stopped, no socket open, and yet osmo-ggsn.cfg
    # says "gtp bind-ip 172.20.1.10". Removing it gives, at the next start, a
    # service that refuses to start on an address "not found locally" - far
    # from this script.
    if [ "$FORCE" != 1 ]; then
        _ref="$(grep -rlF "$ip_only" /etc/osmocom /etc/asterisk 2>/dev/null | head -3)"
        if [ -n "$_ref" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${a} CONSERVEE : nommee dans une configuration"
            printf '     %s\n' $_ref
            echo -e "     (corrigez la config - 127.0.0.1 convient en natif - puis --force)"
            continue
        fi
    fi
    run ip addr del "$a" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} ${a} retiree" \
        || echo -e "  ${YELLOW}–${NC} ${a} deja absente"
done

for r in ${STALE_ROUTES[@]+"${STALE_ROUTES[@]}"}; do
    run ip route del "$r" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route connectee ${r} retiree"
done

# ── 2. Install the route ────────────────────────────────────────────────────
# 'replace' rather than 'add': idempotent, and it does not trip on a leftover.
if run ip route replace "$DOCKER_NET" via "$VIA" dev "$IFACE"; then
    echo -e "  ${GREEN}✓${NC} ${DOCKER_NET} via ${CYAN}${VIA}${NC}"
else
    echo -e "  ${RED}✗${NC} route refusee - une adresse du plan docker subsiste ?"
    echo -e "     ${CYAN}ip -4 addr show dev ${IFACE} | grep ${DOCKER_PREFIX}${NC}"
    exit 1
fi

# ── 2bis. The ASP must leave from the address that ROUTES ───────────────────
# Installing the route is not enough if osmo-stp binds to another address. A
# bench VM carries several - the bridge, and the ISO's private plan
# (192.168.<n>.1 and .10) - and auto-detection may pick a private one. The
# hub then cannot answer: the association never completes and the log only
# says "connect failed (-110)", a timeout, without naming the faulty source.
#
# The ASP source is therefore aligned on what the kernel will really use to
# reach the hub - the same rule as network/set-node-id.sh.
STP_CFG="${STP_CFG:-/etc/osmocom/osmo-stp.cfg}"
if [ "${NO_STP:-0}" != "1" ] && [ -w "$STP_CFG" ]; then
    # --hub-ip is authoritative; otherwise read what the file already declares.
    if [ -n "$HUB_IP" ]; then
        _hub="$HUB_IP"
        _cur_hub="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$STP_CFG")"
        if [ "$_cur_hub" != "$_hub" ]; then
            if [ "$DRY" = 1 ]; then
                echo -e "  [dry-run] ASP remote-ip ${_cur_hub:-?} -> ${_hub}"
            else
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *remote-ip \).*/\1${_hub}/" "$STP_CFG"
                # An ASP in shutdown does not attach, even well addressed: lift
                # it, otherwise the fix has no visible effect.
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *\)shutdown[[:space:]]*$/\1no shutdown/" "$STP_CFG"
                echo -e "  ${GREEN}✓${NC} ASP : hub ${CYAN}${_hub}${NC} (etait ${_cur_hub:-aucun})"
            fi
        fi
    else
        _hub="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$STP_CFG")"
    fi
    # A loopback remote-ip is not a hub: it is the template default, left by
    # a regeneration that erased the node identity. Aligning the source on it
    # would validate a dead configuration - "source deja correcte (127.0.0.1)"
    # on an ASP that will never reach anyone.
    case "$_hub" in
        127.*|0.0.0.0|"")
            echo -e "  ${YELLOW}⚠${NC} ASP : remote-ip=${_hub:-vide} - ce n'est pas un hub."
            echo -e "     L'identite SS7 n'a pas ete appliquee : ${CYAN}./start-native.sh --node N --hub-ip <hub>${NC}"
            _hub="" ;;
    esac
    if [ -n "$_hub" ]; then
        _src="$(ip route get "$_hub" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
        _cur="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$STP_CFG")"
        if [ -n "$_src" ] && [ "$_src" != "$_cur" ]; then
            if [ "$DRY" = 1 ]; then
                echo -e "  [dry-run] ASP local-ip ${_cur:-?} -> ${_src}"
            else
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *local-ip \).*/\1${_src}/" "$STP_CFG"
                echo -e "  ${GREEN}✓${NC} ASP : source ${CYAN}${_src}${NC} (etait ${_cur:-aucune}) vers le hub ${_hub}"
                if systemctl is-active osmo-stp >/dev/null 2>&1; then
                    systemctl restart osmo-stp \
                        && echo -e "  ${GREEN}✓${NC} osmo-stp relance pour prendre la nouvelle source"
                fi
            fi
        else
            echo -e "  ${GREEN}✓${NC} ASP : source deja correcte (${_cur:-aucune})"
        fi
    fi
fi

[ "$DRY" = 1 ] || printf 'OSMO_DOCKER_HOST=%s\n' "$VIA" > "$STATE" 2>/dev/null || true

# ── 3. At boot, on request ──────────────────────────────────────────────────
# A live system without persistence restarts from the ISO at every boot:
# without a unit, everything is to redo. It simply replays this idempotent script.
if [ "$PERSIST" = 1 ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ "$DRY" = 1 ]; then
        echo "    [dry-run] unite osmo-docker-route.service"
    else
        cat > /etc/systemd/system/osmo-docker-route.service <<EOF
[Unit]
Description=osmo-operator - route vers les conteneurs docker (${DOCKER_NET})
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${here}/set_ip_vm.sh --via ${VIA} --docker-net ${DOCKER_NET}
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable osmo-docker-route.service >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} rejoue au boot (osmo-docker-route.service)"
    fi
fi

# ── 4. The check that matters ───────────────────────────────────────────────

echo ""
first="$(echo "$DOCKER_NET" | cut -d. -f1-3).11"
echo -e "  ${BOLD}Verifier :${NC} ${CYAN}ip route get ${first}${NC}   doit indiquer via ${VIA}"
if [ "$DRY" != 1 ]; then
    got="$(ip route get "$first" 2>/dev/null | head -1)"
    if echo "$got" | grep -q "via ${VIA}"; then
        echo -e "  ${GREEN}✓${NC} ${got}"
    else
        echo -e "  ${YELLOW}⚠${NC} ${got:-aucune reponse}"
    fi
fi
