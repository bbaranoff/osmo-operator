#!/usr/bin/env bash
# =============================================================================
# network/osmo-ip-plan.sh - WHICH INTERFACE CARRIES THE NODE'S PRIVATE ADDRESSES
# =============================================================================
#
# WHAT IT DOES
# ------------
# The node's private addresses (192.168.<node+1>.1 and .10) are installed as
# /32 on the ONE interface that provides Internet access, i.e. the one the
# default route goes through:
#
#   1. a pattern such as [Match] Name=en* eth* would give the addresses to
#      EVERY matching card, two cards ending up with the same /32;
#   2. the pattern says NOTHING about which card really carries the network:
#      on a VM with several interfaces, "en*" matches the NAT as well as the
#      bridge, and the address could land on a card that leads nowhere while
#      the one holding the default route does not have it. A peer aiming at
#      192.168.2.10 would then find nobody although "ip addr" shows the address.
#
# "The card that has the default route" is a RUNTIME property, not a
# configuration one, which systemd-networkd cannot express. Hence this script,
# called at boot and at every link change.
#
# THE FALLBACK, AND WHY IT EXISTS
# -------------------------------
# When NO card provides Internet access - VM without network, cable unplugged,
# silent DHCP - there is no sensible place for a segment address. Instead of
# installing it nowhere, 127.0.0.66/32 goes on the loopback. Configurations
# that name a private address then ALWAYS find something local and reachable,
# the daemons start, and the bench runs self-contained instead of failing at
# bind on a missing address.
#
# DOCKER OR NATIVE
# ----------------
# The address plan differs on the two sides, and mistaking one for the other
# gives daemons that bind to addresses that do not exist here:
#   docker  the container has its address on the bridge before the daemons
#           start, and the backbone is 172.20.0.x. Nothing is touched:
#           docker does the addressing.
#   native  the address comes from DHCP, may be missing at start-up, and the
#           node's private segment is 192.168.<node+1>.x.
# "docker" = an image OF THIS REPOSITORY: OSMO_IMAGE=1 (set by the Dockerfile),
# or as a fallback /.dockerenv AND /etc/docker-entrypoint-cmd. Any other
# container (bare ubuntu:24.04) is addressed like a native machine (see
# detect_runtime_env).
#
# Usage:   osmo-ip-plan.sh [--apply|--show] [--node N]
# -----------------------------------------------------------------------------
set -uo pipefail

ACTION=apply
NODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  ACTION=apply ;;
        --show)   ACTION=show ;;
        --node)   NODE="${2:-}"; shift ;;
        --node=*) NODE="${1#*=}" ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

LOOPBACK_FALLBACK="${OSMO_PRIV_FALLBACK:-127.0.0.66}"

# ── docker or native ────────────────────────────────────────────────────────
# "docker" means HERE: an image of THIS repository, whose network is set up by
# start-docker.sh / compose (backbone 172.20.0.x). The Dockerfile sets
# ENV OSMO_IMAGE=1; as a fallback (variable lost under sudo, or in a systemd
# unit that does not inherit the container environment), the pair
# /.dockerenv + /etc/docker-entrypoint-cmd written by scripts/entrypoint.sh.
# /.dockerenv alone or the cgroup are not enough: a bare ubuntu:24.04 (the
# disposable container of the installation notebook) would pass for "docker",
# nobody would install 192.168.2.10 there, and osmo-ggsn / osmo-sgsn would
# refuse to start. Any other container is treated as a native machine.
detect_runtime_env() {
    if [ "${OSMO_IMAGE:-0}" = 1 ]; then echo docker; return; fi
    if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then echo docker; return; fi
    echo native
}

# ── the node ────────────────────────────────────────────────────────────────
resolve_node() {
    local n="${NODE:-${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}}"
    [ -n "$n" ] || n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
                        /etc/osmo-role 2>/dev/null)"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' /etc/osmocom/radio-plan.env 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}

# ── THE card that provides Internet access ──────────────────────────────────
# "ip route get" answers what the KERNEL would really do: the only answer that
# does not guess. A public address is tried first, then the default gateway -
# a bench cut off from the Internet usually keeps its default route.
uplink_dev() {
    local d
    d="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    [ -n "$d" ] || d="$(ip route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    # lo provides nothing: a default route through it means there is none.
    [ "$d" = "lo" ] && d=""
    printf '%s' "$d"
}

# ── WHAT THE CONFIGS REQUIRE, NOT WHAT IS ASSUMED ───────────────────────────
# The private plan (192.168.<node+1>.x) is a convention; what matters is the
# address each daemon will REALLY try to bind. It is written in /etc/osmocom
# and may come from another generator than ours:
# qosmo-grgsm/run_modules/08-gabarits.sh passes op_private_ip() to
# apply_config_templates, hence 192.168.2.10, while the ISO's native recipe
# passes 127.0.0.2. Two truths, and each daemon follows its own:
#     osmo-ggsn: "gtp bind-ip 192.168.2.10" -> bind on a missing address
#     osmo-sgsn: "listen 192.168.2.10 23000" -> same
# The addresses are therefore EXTRACTED from the files instead of recomputed:
# the machine ends up carrying what its configs ask for, whoever wrote them.
#
# NOT taken: "ip dns 0/1" (servers announced to the subscriber), "remote-ip",
# "ggsn 0 remote-ip" name REMOTE addresses. Installing them locally would make
# the machine answer in place of the peer.
addrs_des_configs() {
    local d="${OSMOCOM_CFG:-/etc/osmocom}"
    [ -d "$d" ] || return 0
    {
        sed -n 's/^[[:space:]]*gtp[[:space:]]\+bind-ip[[:space:]]\+\([0-9.]*\).*/\1/p'  "$d"/osmo-ggsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\([0-9.]*\).*/\1/p' "$d"/osmo-sgsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9.]*\)[[:space:]]\+[0-9]*.*/\1/p' "$d"/osmo-sgsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*local-addr[[:space:]]\+\([0-9.]*\).*/\1/p'                 "$d"/osmo-upf.cfg  2>/dev/null
    } | sort -u | while read -r a; do
        case "$a" in
            ''|0.0.0.0|127.*) continue ;;      # already there, or "all cards"
        esac
        printf '%s\n' "$a"
    done
}

RUNTIME="$(detect_runtime_env)"
NODE="$(resolve_node)"
PRIV_BASE=$(( NODE + 1 ))
PRIV_GW="192.168.${PRIV_BASE}.1"
PRIV_IP="192.168.${PRIV_BASE}.10"
DEV="$(uplink_dev)"

if [ "$ACTION" = show ] || [ "${OSMO_IP_PLAN_VERBOSE:-1}" = 1 ]; then
    printf 'osmo-ip-plan : runtime=%s noeud=%s prive=%s,%s carte=%s\n' \
        "$RUNTIME" "$NODE" "$PRIV_GW" "$PRIV_IP" "${DEV:-aucune}"
fi
[ "$ACTION" = show ] && exit 0

# ── DOCKER: nothing is touched ──────────────────────────────────────────────
if [ "$RUNTIME" = docker ]; then
    echo "osmo-ip-plan : conteneur - l'adressage appartient a docker, rien a poser"
    exit 0
fi

# ── The addresses are first removed from EVERYWHERE ─────────────────────────
# Without this clean-up, changing card (cable unplugged, Wi-Fi taking over)
# would leave the old address on the old card: two interfaces claiming the
# same /32, with the kernel choosing the source by order of appearance, not
# by route.
for a in "$PRIV_GW" "$PRIV_IP" "$LOOPBACK_FALLBACK"; do
    while read -r ifn; do
        [ -n "$ifn" ] || continue
        ip addr del "${a}/32" dev "$ifn" 2>/dev/null || true
    done < <(ip -o -4 addr show 2>/dev/null | awk -v a="$a" '$4 ~ "^"a"/" {print $2}')
done

# The union of the node plan and of what the configs ask for. Duplicates are
# dropped by the sort; "ip addr add" of an address already set has no effect.
BESOINS="$(printf '%s\n%s\n%s\n' "$PRIV_GW" "$PRIV_IP" "$(addrs_des_configs)" | sed '/^$/d' | sort -u)"

if [ -n "$DEV" ]; then
    _pose=""
    for a in $BESOINS; do
        # Already carried by some card: left alone. Installing the address
        # elsewhere would give two interfaces on the same /32.
        if ip -o -4 addr show 2>/dev/null | awk '{print $4}' | grep -qx "${a}/32\|${a}/[0-9]*"; then
            continue
        fi
        ip -o -4 addr show 2>/dev/null | awk -F'[ /]+' '{print $4}' | grep -qx "$a" && continue
        ip addr add "${a}/32" dev "$DEV" 2>/dev/null && _pose="$_pose $a"
    done
    if [ -n "$_pose" ]; then
        echo "osmo-ip-plan :${_pose} pose(s) en /32 sur ${DEV} (carte qui fournit Internet)"
    else
        echo "osmo-ip-plan : rien a poser, tout est deja la (${DEV})"
    fi
else
    # ── FALLBACK: the loopback ──────────────────────────────────────────────
    # No card leads anywhere. Installing 192.168.x on a random interface would
    # give an address that is present and unreachable - the worst of both
    # worlds, because everything looks in place. A loopback address is honest:
    # local, reachable, and it claims nothing.
    # On lo, a missing address prevents a daemon from starting just as on a
    # card: what the configs ask for is installed there TOO, not only the
    # fallback. The bench then runs self-contained, complete.

    ip addr add "${LOOPBACK_FALLBACK}/32" dev lo 2>/dev/null || true
    for a in $BESOINS; do
        ip -o -4 addr show 2>/dev/null | awk -F'[ /]+' '{print $4}' | grep -qx "$a" && continue
        ip addr add "${a}/32" dev lo 2>/dev/null || true
    done
    echo "osmo-ip-plan : aucune carte ne fournit Internet - ${LOOPBACK_FALLBACK}/32 + $(echo $BESOINS) sur lo"
fi
exit 0
