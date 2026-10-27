#!/bin/bash
# network/node-conf.sh - A NODE'S CARD, produced by the run, read by the other
# ISOs: "mynode<N>.conf".
#
#   node 1:  ./start-native.sh              -> writes /etc/osmocom/mynode1.conf
#            ./start-native.sh --gen-conf   -> the same card, without starting
#   node 2:  ./start-native.sh --wan mynode1.conf [mynode3.conf ...]
#            -> WAN table = this node + the cards, then the usual meshing
#               (network/setup-wan-mesh.sh: SIP trunks, dialplan, SMS routes)
#
# A "node" is an ISO: its native operator, its multi-operator containers and
# its inter-STP. The WAN links several ISOs. The card says everything another
# node must know to reach it: SS7 identity, public address, prefix, number of
# operators (hence SIP/SMS ports), numbering plan. It is written in shell
# KEY=value format, like /etc/osmo-wan.conf, so it can be read with `.` and
# by eye.
#
# This library is SOURCED (start-native.sh, start-multi.sh). It assumes
# network/wan-nodes.sh is already loaded (WAN_IP/WAN_IND/WAN_NOPS/WAN_NODE_LIST,
# wan_default_ind, wan_detect_local_ip).
: "${OSMOCOM_CFG:=/etc/osmocom}"
NODE_CONF_DIR="${NODE_CONF_DIR:-$OSMOCOM_CFG}"

node_conf_path() { printf '%s/mynode%s.conf' "$NODE_CONF_DIR" "${1:-1}"; }

# How many operators THIS node carries: the native one + the RUNNING
# osmo-operator-N containers (start-multi.sh). The topology written by
# addition.sh exists even without multi started; what matters for the mesh's
# SIP/SMS ports is what answers. OSMO_NODE_NOPS forces the value.
node_conf_nops() {
    local n=1 c
    if [ -n "${OSMO_NODE_NOPS:-}" ]; then printf '%s' "$OSMO_NODE_NOPS"; return 0; fi
    if command -v docker >/dev/null 2>&1; then
        c="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^osmo-operator-[0-9]*$')"
        n=$(( 1 + ${c:-0} ))
    fi
    printf '%s' "$n"
}

# The node's operator list: "idx:mode:pc_stp:rctx_inter[:ip]" - the native
# one first, then the running containers of /etc/osmocom/osmo-multi.conf.
# The point code plan is the WAN one: 1.<node><op>.2.
node_conf_ops() {
    local node="$1" op="$2" out="" spec idx mode ip running=""
    out="${op}:native:1.${node}${op}.2:$(( node * 1000 + op * 100 + 50 ))"
    if command -v docker >/dev/null 2>&1; then
        running="$(docker ps --format '{{.Names}}' 2>/dev/null)"
    fi
    if [ -r "$OSMOCOM_CFG/osmo-multi.conf" ]; then
        for spec in $(sed -n 's/^MULTI_OPS="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$OSMOCOM_CFG/osmo-multi.conf"); do
            IFS=: read -r idx mode ip _ _ <<< "$spec"
            [ "$mode" = docker ] || continue
            printf '%s\n' "$running" | grep -qx "osmo-operator-$idx" || continue
            out="$out ${idx}:docker:1.${node}${idx}.2:$(( node * 1000 + idx * 100 + 50 )):${ip}"
        done
    fi
    printf '%s' "$out"
}

# node_conf_write FILE NODE OP [HUB_IP]
# Writes the card. Public IP and prefix: the WAN table if it knows this node
# (wan_nodes_load done), otherwise local detection + default prefix derived
# from the node number (11, 22, 33...).
node_conf_write() {
    local out="$1" node="$2" op="${3:-1}" hub="${4:-}"
    local ip ind nops ops mcc mnc arfcn nms pfx sip sms
    [[ "$node" =~ ^[1-9]$ ]] || { echo "node_conf_write : noeud '$node' invalide (1-9)" >&2; return 1; }
    ip="${WAN_IP[$node]:-}"
    [ -n "$ip" ] || ip="$(wan_detect_local_ip 2>/dev/null)"
    [ -n "$ip" ] || ip="127.0.0.1"
    ind="${WAN_IND[$node]:-}"
    [ -n "$ind" ] || ind="$(wan_default_ind "$node")"
    nops="$(node_conf_nops)"
    ops="$(node_conf_ops "$node" "$op")"
    mcc="$(sed -n 's/^PLAN_MCC=//p' "$OSMOCOM_CFG/radio-plan.env" 2>/dev/null | tail -1)"
    mnc="$(sed -n 's/^PLAN_MNC=//p' "$OSMOCOM_CFG/radio-plan.env" 2>/dev/null | tail -1)"
    arfcn="$(sed -n 's/^PLAN_ARFCN=//p' "$OSMOCOM_CFG/radio-plan.env" 2>/dev/null | tail -1)"
    [ -n "$mcc" ] || mcc="$(awk '/^ *network country code /{print $4; exit}' "$OSMOCOM_CFG/osmo-msc.cfg" 2>/dev/null)"
    [ -n "$mnc" ] || mnc="$(awk '/^ *mobile network code /{print $4; exit}' "$OSMOCOM_CFG/osmo-msc.cfg" 2>/dev/null)"
    [ -n "$arfcn" ] || arfcn="$(awk '/^ *arfcn /{print $2; exit}' "$OSMOCOM_CFG/osmo-bsc.cfg" 2>/dev/null)"
    nms="${N_MS:-$(sed -n 's/^: "\${N_MS:=\([0-9]*\)}"/\1/p' "$OSMOCOM_CFG/coeur.env" 2>/dev/null | tail -1)}"
    nms="${nms:-2}"
    pfx="${node}00"
    # Ports as seen from outside, same formulas as setup-wan-mesh.sh:
    # a single operator -> 5060 / 7890; otherwise 5080+(j-1)*2 / 7890+j-1.
    if [ "$nops" = 1 ]; then sip=5060; sms=7890; else sip="5080+(j-1)*2"; sms="7890+j-1"; fi
    mkdir -p "$(dirname "$out")" || return 1
    cat > "$out.tmp" <<EOF
# mynode${node}.conf - card of node ${node}, written by start-native.sh on $(date '+%F %T')
# Copy it to another node and hand it over:  ./start-native.sh --wan $(basename "$out")
# Shell format (KEY=value). The OSMO_NODE_ID/IP/IND/NOPS fields are enough for
# the mesh (WAN table "id:ip:prefix:operators"); the rest documents the node.
OSMO_NODE_CONF_VERSION=1
OSMO_NODE_ID=${node}
OSMO_NODE_IP=${ip}
OSMO_NODE_IND=${ind}
OSMO_NODE_NOPS=${nops}
OSMO_NODE_HOSTNAME=$(hostname 2>/dev/null)
# operators: "idx:mode:pc_stp:rctx_inter[:backbone_ip]" (native, then running containers)
OSMO_NODE_OPS="${ops}"
OSMO_NODE_OP=${op}
OSMO_NODE_PC_MSC=1.${node}${op}.1
OSMO_NODE_PC_STP=1.${node}${op}.2
OSMO_NODE_PC_BSC=1.${node}${op}.3
OSMO_NODE_RCTX_INTER=$(( node * 1000 + op * 100 + 50 ))
OSMO_NODE_HUB_IP=${hub}
OSMO_NODE_HUB_PORT=2908
OSMO_NODE_MCC=${mcc}
OSMO_NODE_MNC=${mnc}
OSMO_NODE_ARFCN=${arfcn}
OSMO_NODE_N_MS=${nms}
# numbering: MSISDN = <node>00<op><ms>; from another node: <prefix><MSISDN>
OSMO_NODE_MSISDN_PFX=${pfx}
OSMO_NODE_SIP_PORT="${sip}"
OSMO_NODE_SMS_PORT="${sms}"
EOF
    mv -f "$out.tmp" "$out" && chmod 644 "$out"
}

# node_conf_import FILE: reads a card and puts its node in the WAN table
# (WAN_IP/WAN_IND/WAN_NOPS/WAN_NODE_LIST) - replaces the entry if it existed.
# Read with sed, not with `.`: a card from elsewhere executes nothing here.
node_conf_import() {
    local f="$1" id ip ind nops
    [ -r "$f" ] || { _wan_err "fiche introuvable : $f"; return 1; }
    id="$(sed -n 's/^OSMO_NODE_ID=//p' "$f" | tail -1 | tr -d '" ')"
    ip="$(sed -n 's/^OSMO_NODE_IP=//p' "$f" | tail -1 | tr -d '" ')"
    ind="$(sed -n 's/^OSMO_NODE_IND=//p' "$f" | tail -1 | tr -d '" ')"
    nops="$(sed -n 's/^OSMO_NODE_NOPS=//p' "$f" | tail -1 | tr -d '" ')"
    [[ "$id" =~ ^[1-9]$ ]] || { _wan_err "$f : OSMO_NODE_ID='$id' (attendu 1-9)"; return 1; }
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _wan_err "$f : OSMO_NODE_IP='$ip'"; return 1; }
    [[ "$ind" =~ ^[0-9]{2,4}$ ]] || ind="$(wan_default_ind "$id")"
    [[ "$nops" =~ ^[1-9][0-9]*$ ]] || nops=1
    if [ -z "${WAN_IP[$id]:-}" ]; then WAN_NODE_LIST+=("$id"); fi
    WAN_IP[$id]="$ip"; WAN_IND[$id]="$ind"; WAN_NOPS[$id]="$nops"
    WAN_NODE_COUNT=${#WAN_NODE_LIST[@]}
    printf '  %-4s noeud %s  %-15s indicatif %-4s %s operateur(s)  (%s)\n' "" "$id" "$ip" "$ind" "$nops" "$(basename "$f")"
    return 0
}

# node_conf_self NODE: makes sure THIS node is in the table (detected local
# address, default prefix, operators counted), without overwriting an entry
# the table already knows.

node_conf_self() {
    local id="$1" ip
    [ -n "${WAN_IP[$id]:-}" ] && { WAN_NOPS[$id]="$(node_conf_nops)"; return 0; }
    ip="$(wan_detect_local_ip 2>/dev/null)" || ip=""
    [ -n "$ip" ] || { _wan_err "aucune adresse locale detectee pour le noeud $id (--wan-nodes pour la donner)"; return 1; }
    WAN_IP[$id]="$ip"; WAN_IND[$id]="$(wan_default_ind "$id")"; WAN_NOPS[$id]="$(node_conf_nops)"
    WAN_NODE_LIST+=("$id"); WAN_NODE_COUNT=${#WAN_NODE_LIST[@]}
    printf '  %-4s noeud %s  %-15s indicatif %-4s %s operateur(s)  (ce noeud)\n' "" "$id" "$ip" "${WAN_IND[$id]}" "${WAN_NOPS[$id]}"
}
