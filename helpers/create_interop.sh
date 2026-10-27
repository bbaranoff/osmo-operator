#!/bin/bash
# create_interop.sh - Generate the inter-STP configuration (central SS7 hub)
#
# Usage:
#   create_interop.sh [--listen-ip <ip>] <n_operators> [outfile]
#   create_interop.sh [--listen-ip <ip>] --wan <n_nodes> <ops_per_node> [outfile]
#
# Parameters (single-machine mode):
#   $1  n_operators   Number of operators (1..24)
#   $2  outfile       Output config file (default: osmo-stp-interop.cfg)
#
# Environment:
#   HUB_LISTEN_IP   Address the hub listens on (also --listen-ip). Empty or
#                   unset = 0.0.0.0 (single-machine setups). On a multi-homed
#                   host a single correct address is required: with 0.0.0.0
#                   SCTP announces every interface in its INIT and the peer ASP
#                   flaps on the unreachable ones.
#   OP_ID_BASE      Id of the first container operator (default 1). The AS
#                   list runs from 1 up to OP_ID_BASE + n_operators - 1 so the
#                   native operator (op1) is covered when containers start at 2.
#   WAN_NODE_IDS    WAN mode: node numbers, e.g. "1 3" (default 1..n_nodes).
#
# Point codes, ITU 3-8-3:
#   Inter-STP : 0.0.0
#   Op N STP  : 1.N.2    (cluster = N, 8 bits -> max 255, limited to 24)
#   Op N MSC  : 1.N.1
#   Op N BSC  : 1.N.3
#
# Static routes with exact mask 7.255.7 (14 bits):
#   1.N.1 -> as-opN  (MSC)
#   1.N.3 -> as-opN  (BSC)
#
# This file is REGENERATED at every hub start (launch/start-interstp.sh): any
# fix must go through its options/environment, not into the generated file.

set -e

# ── WAN mode ─────────────────────────────────────────────────────────────────
#   create_interop.sh --wan <n_nodes> <ops_per_node> <outfile>
#
# A point code is an ADDRESS: several nodes sharing one hub must not all be
# 1.1.2. The WAN plan encodes the node INSIDE the point code:
#   PC = 1.<node><op>.<role>     node 1 op 1 -> 1.11.2 ; node 3 op 2 -> 1.32.2
#   RCTX = node*1000 + op*100 + 50
# Readable (first digit is the node), unique, and the middle field of 3-8-3
# holds up to 9 nodes x 9 operators.

# ── Hub listen address ───────────────────────────────────────────────────────
HUB_LISTEN_IP="${HUB_LISTEN_IP:-0.0.0.0}"
_ci_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --listen-ip)   HUB_LISTEN_IP="${2:-0.0.0.0}"; shift 2 ;;
        --listen-ip=*) HUB_LISTEN_IP="${1#*=}"; shift ;;
        *)             _ci_args+=("$1"); shift ;;
    esac
done
[ "${#_ci_args[@]}" -gt 0 ] && set -- "${_ci_args[@]}"
[ -n "$HUB_LISTEN_IP" ] || HUB_LISTEN_IP="0.0.0.0"

WAN_MODE=0
if [ "${1:-}" = "--wan" ]; then
    WAN_MODE=1
    n_nodes="${2:-3}"
    ops_per_node="${3:-1}"
    outfile="${4:-osmo-stp-interop.cfg}"
    if ! [[ "$n_nodes" =~ ^[1-9]$ ]] || ! [[ "$ops_per_node" =~ ^[1-9]$ ]]; then
        echo "Erreur : --wan <1-9 noeuds> <1-9 operateurs>" >&2; exit 1
    fi
else
    n_operators="${1:-2}"
    outfile="${2:-osmo-stp-interop.cfg}"
    if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 24 ]; then
        echo "Erreur : n_operators doit etre 1..24" >&2
        exit 1
    fi
fi

# ── Header: logging, VTY, cs7 instance, M3UA listener ────────────────────────
cat > "$outfile" <<'EOFCONFIG'
!
! osmo-stp-interop.cfg - Configuration inter-STP centrale
!
! PC 0.0.0 : hub de routage SS7
!

log stderr
 logging filter all 1
 logging color 1
 logging print category-hex 0
 logging print category 1
 logging print extended-timestamp 1
 logging print level 1
 logging print file basename
 logging level lss7 info
 logging level lsccp info
 logging level lm3ua info
 logging level linp notice
!
stats interval 5
!
line vty
 no login
!
cs7 instance 0
 network-indicator international
 point-code 0.0.0
!
 xua rkm routing-key-allocation dynamic-permitted

 listen m3ua 2908
  accept-asp-connections dynamic-permitted
  local-ip __LISTEN_IP__
!
EOFCONFIG

# Quoted heredoc: the template is written verbatim, then substituted. The
# marker only exists in the header; the AS loops below do not use it.
sed -i "s|__LISTEN_IP__|${HUB_LISTEN_IP}|" "$outfile"

# ── Application servers (one per operator STP) ───────────────────────────────
if [ "$WAN_MODE" = "1" ]; then
    for n in ${WAN_NODE_IDS:-$(seq 1 "$n_nodes")}; do
        for o in $(seq 1 "$ops_per_node"); do
            rctx_inter=$(( n * 1000 + o * 100 + 50 ))
            pc_stp="1.${n}${o}.2"
            cat >> "$outfile" <<EOF

 as as-n${n}op${o} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
        done
    done
else
# From 1 up to the highest operator id, not "1..n_operators": n_operators
# counts the CONTAINERS, the native operator is op1 and containers may start
# at OP_ID_BASE=2.
for i in $(seq 1 "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
    rctx_inter=$(( i * 100 + 50 ))
    pc_stp="1.${i}.2"

    cat >> "$outfile" <<EOF

 as as-op${i} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
done
fi

# ── Route table (MSC and BSC of every operator) ──────────────────────────────
cat >> "$outfile" <<'EOFROUTES'

 route-table system
EOFROUTES

if [ "$WAN_MODE" = "1" ]; then
    for n in ${WAN_NODE_IDS:-$(seq 1 "$n_nodes")}; do
        for o in $(seq 1 "$ops_per_node"); do
            cat >> "$outfile" <<EOF
  update route 1.${n}${o}.1 7.255.7 linkset as-n${n}op${o}
  update route 1.${n}${o}.3 7.255.7 linkset as-n${n}op${o}
EOF
        done
    done
else
# Same range as the AS list above (1 .. OP_ID_BASE + n_operators - 1).
for i in $(seq 1 "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
    cat >> "$outfile" <<EOF
  update route 1.${i}.1 7.255.7 linkset as-op${i}
  update route 1.${i}.3 7.255.7 linkset as-op${i}
EOF
done
fi

cat >> "$outfile" <<'EOF'

!
EOF

# ── Summary ──────────────────────────────────────────────────────────────────
if [ "$WAN_MODE" = "1" ]; then
    echo "✓ Config inter-STP WAN generee : $outfile" >&2
    echo "  PC hub  : 0.0.0   Noeuds : $n_nodes × $ops_per_node operateur(s)" >&2
    echo "  PC noeuds : 1.<noeud><op>.<role>   RCTX : noeud*1000 + op*100 + 50" >&2
    echo "  Routes  : $(( n_nodes * ops_per_node * 2 )) (masque 7.255.7)" >&2
else
    echo "✓ Config inter-STP generee : $outfile" >&2
    echo "  PC hub     : 0.0.0   Operateurs : $n_operators" >&2
    echo "  Routes     : $((n_operators * 2)) (masque 7.255.7)" >&2
fi
