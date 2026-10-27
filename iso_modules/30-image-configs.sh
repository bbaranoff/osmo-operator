#!/bin/bash
# iso_modules/30-image-configs.sh - step 1 (docker build) and 2 (configs via start-docker.sh)
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── Step 1: THE docker build (once; see iso_docker_build) ────────────────────
iso_docker_build "$ISO_ROLE"

# load_start_lib: extract the function library of launch/start-docker.sh
# (everything before its main code) into $WORK and source it. This provides
# apply_config_templates.
load_start_lib() {
    local src="$DIR/launch/start-docker.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # The lib lives in $WORK, not in the repo: without this, the BASH_SOURCE
    # resolution of start-docker.sh would look for generate_configs.sh next to the copy.
    export OSMO_REPO_DIR="$DIR"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Step 2: the start-docker.sh library (apply_config_templates) ─────────────
# A single docker image (step 1); the configs come from this repo and the lite
# pruning is done on the rootfs (step 8c).
load_start_lib
echo -e "${GREEN}[2/9] Image source : ${CYAN}$([ "$ISO_ROLE" = "interstp" ] && [ "${OSMO_ISO_ALL_RUN:-0}" != "1" ] && echo osmocom-stp || echo osmocom-nitb)${NC}"

echo -e "${GREEN}[2b/9] Preparation de l'image source de l'ISO...${NC}"

ISO_N_MS=2
ISO_OP_ID=1         # single operator in the ISO (PLMN 001-01)
ENCRYPTION="a5 1"   # A5/1 by default in the ISO

# The ISO runs NATIVELY, without a docker bridge. The core must not bind on
# the default NIC address: it may be absent (VM without a card), named outside
# "en* eth*", or not yet configured by systemd-networkd when osmo-ggsn starts.
# Affected: osmo-ggsn (gtp bind-ip), osmo-sgsn (ggsn remote-ip), osmo-upf
# (local-addr), osmo-bsc (gprs nsvc remote ip) and the gsmtap log.
ISO_PRIV_BASE=$(( ${ISO_NODE:-1} + 1 ))
ISO_PRIV_GW="192.168.${ISO_PRIV_BASE}.1"
ISO_PRIV_IP="192.168.${ISO_PRIV_BASE}.10"

# ── Base address: the private segment, plus loopback ─────────────────────────
# SGSN and GGSN both open the same GTP socket (2123/2152/3386): they MUST be
# on different addresses, otherwise the second one fails with "bind failed:
# Address already in use" and systemd restarts it in a loop (packet attach
# then hangs forever). The node plan gives exactly two addresses:
#     .10  ip1  the core: GGSN, NS/Gb of the SGSN, UPF, nsvc of the BSC
#     .1   private gw    the GTP endpoint of the SGSN, alone
# Both are set as /32 by network/osmo-ip-plan.sh before run.sh starts anything;
# its fallback puts them on `lo` when no card provides Internet, so they
# always exist.
HOST_IP="$ISO_PRIV_IP"     # ip1 : __CONTAINER_IP__ - ggsn/sgsn-NS/upf/bsc-nsvc
SGSN_GTP_IP="$ISO_PRIV_GW" # the SGSN GTP endpoint, distinct from the GGSN
GATEWAY_IP="127.0.0.1"     # gw  : __GATEWAY_IP__  - gsmtap log + dns 0 of the ggsn
# HLR and GSUP stay on loopback: a node-internal control plane that nobody
# calls from outside; osmo-hlr.cfg hard-codes "bind ip 127.0.0.2".
HLR_IP="127.0.0.2"

# ── The private segment of this node: 192.168.<node+1>.x ─────────────────────
# Same plan as the docker side (start-docker.sh: op_private_*), so that a VM
# and a container of the same rank describe themselves the same way. The +1
# leaves 192.168.1.0/24 to the bench LAN (VMs and SS7 hub).
# These addresses are /32: the goal is a stable attachment point for the
# configurations that still name a private address, not a real segment.
# __INTER_STP_IP__: ASP towards the STP of another operator. Inert here - the
# ISO has a single operator and passes inter_stp_shutdown=shutdown to
# apply_config_templates - but no dead docker IP is left in the configs.
INTER_STP_IP="127.0.0.1"   # ip2 : inter-operator (ASP shutdown on the ISO)

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  Inter-STP  : ${CYAN}${INTER_STP_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"

TEMP_CONFIG="$(mktemp -d)"

# ── Point codes and SS7 attachment ───────────────────────────────────────────
# Without WAN: the historical plan, 1.<op>.<role>, and the inter-STP ASP shut
# down (a single operator has nobody to talk to over SS7).
#
# With --node N: the node is part of the point code, 1.<node><op>.<role>.
# Otherwise three ISOs attached to the same hub would all present 1.11.2: a
# point code is an address, and duplicates mean silent wrong routing.
ISO_PC_MSC="1.1.1"; ISO_PC_STP="1.1.2"; ISO_PC_BSC="1.1.3"
ISO_INTER_SHUT="shutdown"
ISO_INTER_IP="$INTER_STP_IP"
if [ -n "$ISO_NODE" ]; then
    ISO_PC_MSC="1.${ISO_NODE}${ISO_OP_ID}.1"
    ISO_PC_STP="1.${ISO_NODE}${ISO_OP_ID}.2"
    ISO_PC_BSC="1.${ISO_NODE}${ISO_OP_ID}.3"
    ISO_INTER_IP="$ISO_HUB_IP"
    ISO_INTER_SHUT="no shutdown"
    # Unique RCTX too: the hub identifies each AS by its routing context.
    export RCTX_INTER_OVERRIDE=$(( ISO_NODE * 1000 + ISO_OP_ID * 100 + 50 ))
    # ASP local-ip left at 0.0.0.0: the node address comes from DHCP and is
    # not necessarily up when osmo-stp starts; binding to an absent address
    # fails at launch.
    export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
    echo -e "  Noeud WAN  : ${CYAN}${ISO_NODE}${NC}  PC ${CYAN}${ISO_PC_STP}${NC}  hub ${CYAN}${ISO_HUB_IP}${NC}  rctx ${RCTX_INTER_OVERRIDE}"
fi

apply_config_templates "$TEMP_CONFIG" \
    "$HOST_IP" "$GATEWAY_IP" \
    "1" "$ISO_PC_MSC" "$ISO_PC_STP" "$ISO_PC_BSC" \
    "001" "01" "OsmoGSM" \
    "$ISO_INTER_IP" "$ISO_INTER_SHUT" "1"

# ── Inter-STP role: the hub config, for N nodes ──────────────────────────────
if [ "$ISO_ROLE" = "interstp" ]; then
    _hub_nodes=3
    if [ -n "$ISO_WAN_NODES" ]; then
        _hub_nodes=$(printf '%s' "${ISO_WAN_NODES//,/ }" | wc -w)
    fi
    bash "$DIR/helpers/create_interop.sh" --wan "$_hub_nodes" "${ISO_WAN_OPS:-1}" \
        "$TEMP_CONFIG/osmocom/osmo-stp-interop.cfg" || exit 1
    echo -e "  ${GREEN}✓${NC} hub SS7 pour ${CYAN}${_hub_nodes}${NC} noeud(s) × ${ISO_WAN_OPS:-1} operateur(s)"
fi

# ── NATIVE post-patches ──────────────────────────────────────────────────────
# AFTER apply_config_templates, not before: it overwrites sms-routing.conf,
# osmo-sgsn.cfg and osmo-msc.cfg with the templates (i.e. the DOCKER plan).
# The recipe lives once in generate_configs.sh (apply_native_post_patches) and
# both paths (ISO build, ./start-native.sh --regen) call it.
# The WAN table as this ISO will embed it: it gives sms-routing.conf the
# address of EACH node. Without it (isolated bench ISO), the generator only
# writes our own entry.
ISO_WAN_TMP=""
if [ -n "$ISO_WAN_NODES" ]; then
    ISO_WAN_TMP="$(mktemp -p "$WORK")"
    printf 'WAN_NODES="%s"\n' "$ISO_WAN_NODES" > "$ISO_WAN_TMP"
fi
apply_native_post_patches "$TEMP_CONFIG" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}" "$SGSN_GTP_IP" "$HLR_IP"
echo -e "  ${GREEN}✓${NC} retouches natives : sms-routing (${CYAN}${ISO_N_MS}${NC} route(s) MS), GGSN/NS ${CYAN}${HOST_IP}${NC}, GTP SGSN ${CYAN}${SGSN_GTP_IP}${NC}, HLR ${CYAN}${HLR_IP}${NC}"


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
