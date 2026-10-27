# =============================================================================
#  checks/_mode.sh - single docker/native detection rule shared by all
#                    checks/ scripts.
#  Library: SOURCE it; running it directly only prints what it detects.
# =============================================================================
#
#  THE TWO WORLDS
#  -------------
#    docker - one osmo-operator-N container per operator on the gsm-inter
#             network (172.20.0.0/24); the SS7 hub is the osmo-inter-stp
#             container (172.20.0.10); everything is reached via "docker exec".
#    native - ISO, VM or bare metal: a single operator (unless netns topology),
#             everything runs here, VTYs on 127.0.0.1, configs in /etc/osmocom,
#             daemons are systemd units or plain processes.
#
#  VTY PORTS are the SAME in both worlds - only the host changes:
#      osmo-stp 4239 · osmo-msc 4254 · osmo-bsc 4242 · osmo-hlr 4258
#      osmo-sgsn 4245 · osmo-ggsn 4260 · osmo-mgw 4243 · mobile/BB 4247
#
#  CONTRACT
#  --------
#   • defines ONLY functions and ": =" variables; prints nothing, sets no
#     colors, counts no PASS/FAIL: each check keeps its own ok/fail/warn/skip,
#     output format and exit code;
#   • probes return 0 = true, non-0 = false;
#   • can be sourced twice without side effects (OSMO_MODE_LIB_LOADED guard);
#   • no "grep -aq" at the end of a pipeline and no "awk ... exit" mid-pipe:
#     under "set -o pipefail" both return 141;
#   • compatible with "set -euo pipefail" in the caller.
#
#  osmo_mode() VS detect_runtime_env() IN start-native.sh
#  -----------------------------------------------------
#  They answer different questions and must not be merged:
#    detect_runtime_env()  "where am I running?"            -> docker | vm | bare
#        Decides the ADDRESSING PLAN (docker: inter-STP 172.20.0.10, IP already
#        set; VM/ISO: inter-STP is another machine, address from DHCP).
#    osmo_mode()           "how do I REACH the nodes from here?" -> docker | native
#        Decides between "docker exec" and running locally.
#  Inside a repository container the first returns "docker" and the second
#  "native": "docker exec" to oneself makes no sense, even with the socket
#  mounted. The shared convention is "--docker" / "--native", which
#  start-native.sh passes to network/setup-wan-mesh.sh and osmo_mode_force()
#  accepts.
#
#  NAMING A NODE - <op>
#  --------------------
#  All execution functions take an <op> as first argument, one of:
#      3                    the operator number (canonical form)
#      osmo-operator-3      the label (as returned by osmo_ops/osmo_node)
#      hub | osmo-inter-stp the SS7 hub
#  In docker this is the container name; in native it is this machine, with
#  an "ip netns exec osmo-opN" prefix if and only if that namespace exists
#  (native multi-operator topology, run_modules/12-netns.sh).
#  The osmo-operator-N label is KEPT in native mode: checks/vty-debug-dump.sh
#  writes "container=osmo-operator-N" and checks/operator_summary.sh parses
#  it. It is a correlation key, not a queryable object.
#
#  SOURCING (same block everywhere; works from the repository and from /opt):
#      _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#      for _c in "$_here/_mode.sh" /opt/GSM/osmo-operator/checks/_mode.sh; do
#          [ -r "$_c" ] && { . "$_c"; break; }
#      done
#      command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }
#
#  Env: OSMO_MODE (force docker|native), OSMO_REPO, OSMO_NATIVE_ROOT, OSMO_BACKBONE_NET,
#       OSMO_NETNS_PREFIX, OSMO_MULTI_CONF, OSMO_HUB_M3UA_PORT,
#       OSMO_VTY_OPEN / OSMO_VTY_READ / OSMO_VTY_Q / OSMO_VTY_KILL.
# =============================================================================

[ -n "${OSMO_MODE_LIB_LOADED:-}" ] && return 0
OSMO_MODE_LIB_LOADED=1

# Repository root (this file is in checks/); used to find globals.conf.
# Can be overridden for tests.
_osmo_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OSMO_REPO:=$(dirname "$_osmo_lib_here")}"
unset _osmo_lib_here

# Inter-operator backbone addressing. Same value in both worlds: docker uses
# "--network gsm-inter --ip", native multi-operator recreates it in netns
# (BACKBONE_NET, run_modules/12-netns.sh).
: "${OSMO_BACKBONE_NET:=172.20.0}"
: "${OSMO_NETNS_PREFIX:=${NETNS_PREFIX:-osmo-op}}"

# Root prefix, native mode only: points at a test tree
# (OSMO_NATIVE_ROOT=/tmp/test) instead of the machine's /etc. Empty in
# production. Same role as NATIVE_ROOT in network/setup-wan-mesh.sh.
: "${OSMO_NATIVE_ROOT:=}"

# Per-node cache of the available VTY client, to avoid running "command -v nc"
# for every VTY command. "-g" keeps it global even when the library is sourced
# from inside a function.
declare -gA _OSMO_VTY_TOOL 2>/dev/null || declare -A _OSMO_VTY_TOOL

# =============================================================================
#  1. MODE
# =============================================================================

# osmo_in_container - are we running INSIDE a container of THIS repository?
# /.dockerenv alone is true in any container; also require
# /etc/docker-entrypoint-cmd, created by scripts/entrypoint.sh (same pair as
# start-docker.sh and start-native.sh).
osmo_in_container() {
    [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]
}

# Detection, from the most explicit to the most inferred.
_osmo_mode_detect() {
    # Inside a repository container we ARE the node: "docker exec" to oneself
    # makes no sense, even if the docker socket is mounted (dashboard container).
    if osmo_in_container; then printf 'native\n'; return 0; fi

    # OSMO_NATIVE=1 is set by the ISO (services/osmo-egprs-web.service).
    if [ "${OSMO_NATIVE:-}" = "1" ]; then printf 'native\n'; return 0; fi

    # Repository rule (also in wan_ss7_check.sh and setup-wan-mesh.sh): rely on a
    # RUNNING operator container, not on the docker binary being present.
    # Capture the list BEFORE filtering: "docker ps | grep -aq" returns 141 under pipefail.
    if command -v docker >/dev/null 2>&1; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        if grep -ax 'osmo-operator-1' >/dev/null 2>&1 <<<"$names"; then
            printf 'docker\n'; return 0
        fi
    fi
    printf 'native\n'
}

# osmo_mode - prints "docker" or "native". Cached in OSMO_MODE, which also
# acts as input: "OSMO_MODE=native ./checks/global_check.sh" forces it.
osmo_mode() {
    case "${OSMO_MODE:-}" in
        docker|native) : ;;
        *) OSMO_MODE="$(_osmo_mode_detect)" ;;
    esac
    printf '%s\n' "$OSMO_MODE"
}

osmo_is_docker() { [ "$(osmo_mode)" = docker ]; }
osmo_is_native() { [ "$(osmo_mode)" = native ]; }

# osmo_mode_force <docker|native|--docker|--native|--mode=X>
# Drop into each script's option "case" loop: explicit always wins over
# detection. Returns 2 for an argument that is not a mode.
osmo_mode_force() {
    local m="${1:-}"
    case "$m" in
        --mode=*) m="${m#*=}" ;;
        --docker) m=docker ;;
        --native) m=native ;;
    esac
    case "$m" in
        docker|native) OSMO_MODE="$m"; return 0 ;;
        *) return 2 ;;
    esac
}

# =============================================================================
#  2. INVENTORY
# =============================================================================

# Reads a key from globals.conf ("N_OPERATORS=3") with awk directly:
# no pipe, hence no pipefail trap.
_osmo_globals() {
    local k="${1:-}" f v
    for f in "${OSMO_GLOBALS:-}" "$OSMO_REPO/globals.conf" \
             /opt/GSM/osmo-operator/globals.conf ./globals.conf; do
        [ -n "$f" ] && [ -r "$f" ] || continue
        v="$(awk -F= -v k="$k" '$1 == k { gsub(/[" \r\t]/, "", $2); if ($2 != "") print $2 }' "$f" | tail -1)"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

# osmo_ops - IDs of the present operators, one per line, sorted.
#   multi  : the operators declared in the multi-operator topology (below).
#   docker : the running osmo-operator-N containers.
#   native : $OSMO_OP_IDS (set by services/osmo-egprs-web.service), then the
#            osmo-opN netns (native multi-operator), then N_OPERATORS from
#            globals.conf, else 1.
#
# ══ MULTI-OPERATOR TOPOLOGY ══════════════════════════════════════════════════
# A multi-operator bench can be MIXED (e.g. op 1 native on the host, op 2 and 3
# and the hub in containers), so mode, IP and point code are per operator.
# /etc/osmocom/osmo-multi.conf, written by addition.sh, is authoritative:
#   MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:1.2.2:250 ..."
#   MULTI_HUB_IP=172.20.0.10  MULTI_HUB_NAME=osmo-inter-stp
# When absent, the global detection above applies.
OSMO_MULTI_CONF="${OSMO_MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
_OSMO_MULTI_LOADED=""

_osmo_multi_load() {
    [ -n "$_OSMO_MULTI_LOADED" ] && return "$_OSMO_MULTI_LOADED"
    _OSMO_MULTI_LOADED=1                      # 1 = no topology
    [ -r "$OSMO_MULTI_CONF" ] || return 1
    # shellcheck disable=SC1090
    . "$OSMO_MULTI_CONF" 2>/dev/null || return 1
    [ -n "${MULTI_OPS:-}" ] || return 1
    _OSMO_MULTI_LOADED=0
    return 0
}

# osmo_multi_active - rc 0 if a multi-operator topology is declared.
osmo_multi_active() { _osmo_multi_load; }

# osmo_op_mode <id> - "native" or "docker" FOR THIS OPERATOR.
# Without a topology, falls back to the global mode.
osmo_op_mode() {
    local want="${1:-}" spec idx mode
    if _osmo_multi_load; then
        for spec in $MULTI_OPS; do
            IFS=: read -r idx mode _ <<< "$spec"
            [ "$idx" = "$want" ] && { printf '%s\n' "$mode"; return 0; }
        done
    fi
    osmo_mode
}

# osmo_hub_pc - hub point code from the topology; empty otherwise.
osmo_hub_pc() {
    _osmo_multi_load || return 1
    [ -n "${MULTI_HUB_PC:-}" ] || return 1
    printf '%s\n' "$MULTI_HUB_PC"
}

# osmo_op_pc <id> - expected point code from the topology; empty otherwise.
osmo_op_pc() {
    local want="${1:-}" spec idx mode ip pc
    _osmo_multi_load || return 1
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip pc _ <<< "$spec"
        [ "$idx" = "$want" ] && { printf '%s\n' "$pc"; return 0; }
    done
    return 1
}

osmo_ops() {
    local ids=""
    # The declared topology overrides detection: it lists the EXPECTED operators,
    # so a stopped operator shows up as missing instead of disappearing.
    if _osmo_multi_load; then
        ids="$(tr ' ' '\n' <<<"$MULTI_OPS" | cut -d: -f1 | sed -n 's/^\([0-9][0-9]*\)$/\1/p')"
        [ -n "$ids" ] && { sort -n -u <<<"$ids" | sed '/^$/d'; return 0; }
    fi
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        ids="$(sed -n 's/^osmo-operator-\([0-9][0-9]*\)$/\1/p' <<<"$names")"
    else
        ids="$(tr ', ' '\n\n' <<<"${OSMO_OP_IDS:-}" | sed -n 's/^\([0-9][0-9]*\)$/\1/p')"
        if [ -z "$ids" ]; then
            ids="$(ip netns list 2>/dev/null | awk '{print $1}' \
                   | sed -n "s/^${OSMO_NETNS_PREFIX}\([0-9][0-9]*\)\$/\1/p")"
        fi
        if [ -z "$ids" ]; then
            local n; n="$(_osmo_globals N_OPERATORS || true)"
            case "$n" in ''|*[!0-9]*) n=1 ;; esac
            [ "$n" -ge 1 ] 2>/dev/null || n=1
            ids="$(seq 1 "$n")"
        fi
    fi
    [ -n "$ids" ] || return 0
    sort -n -u <<<"$ids" | sed '/^$/d'
}

# osmo_op_exists <id> - does the operator exist? (anchored match: "1" does
# not match osmo-operator-10)
osmo_op_exists() {
    local want="${1:-}" id
    case "$want" in ''|*[!0-9]*) return 2 ;; esac
    while read -r id; do
        [ "$id" = "$want" ] && return 0
    done <<<"$(osmo_ops)"
    return 1
}

# osmo_node <op> - node label: "osmo-operator-N" or "osmo-inter-stp".
# In docker this is the container name; in native it is a DISPLAY NAME that
# keeps banners and the dump's "container=" field identical.
osmo_node() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf 'osmo-inter-stp\n' ;;
        osmo-operator-*)    printf '%s\n' "$1" ;;
        [0-9]*)             printf 'osmo-operator-%s\n' "$1" ;;
        *)                  printf '%s\n' "${1:-}" ;;
    esac
}

# Operator number of an <op>; empty for the hub or unknown values.
_osmo_id() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf '' ;;
        osmo-operator-*)    printf '%s\n' "${1##*-}" ;;
        [0-9]*)             printf '%s\n' "$1" ;;
        *)                  printf '' ;;
    esac
}

# osmo_hub - is an inter-STP queryable HERE? Prints its label if so.
#   docker : the osmo-inter-stp container is running.
#   native : this machine IS the hub - OSMO_ROLE=interstp in /etc/osmo-role
#            (set by build-iso.sh), or the start-interstp.sh probe.
# On a native operator node the hub is ANOTHER machine: rc 1, and
# osmo_hub_hint says what to do instead of reporting a fake "0 AS active".
osmo_hub() {
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        grep -ax 'osmo-inter-stp' >/dev/null 2>&1 <<<"$names" || return 1
        printf 'osmo-inter-stp\n'; return 0
    fi
    if [ -r /etc/osmo-role ] \
       && grep -aE '^OSMO_ROLE[[:space:]]*=[[:space:]]*interstp' /etc/osmo-role >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    if pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    return 1
}

# OSMO_HUB_M3UA_PORT - M3UA port of the inter-STP hub (helpers/create_interop.sh
# writes "listen m3ua 2908"). Operator STPs listen on 2905.
: "${OSMO_HUB_M3UA_PORT:=2908}"

# _osmo_hub_ip_probe - ask the operator nodes where their hub is. Sources,
# in order:
#   1. OSMO_HUB_IP, injected into each container by start-docker.sh (-e OSMO_HUB_IP)
#      when --hub-ip / --wan points to an inter-STP outside the docker backbone;
#   2. the "remote-ip" of asp asp-to-inter in /etc/osmocom/osmo-stp.cfg, valid
#      even without that environment (manually restarted container, ISO).
# Returns 1 without output if no node can answer.
_osmo_hub_ip_probe() {
    local op v=""
    for op in $(osmo_ops 2>/dev/null); do
        v="$(osmo_exec "$op" printenv OSMO_HUB_IP 2>/dev/null | tr -d "\r" | tail -1)"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
        v="$(osmo_exec "$op" cat /etc/osmocom/osmo-stp.cfg 2>/dev/null \
             | awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' | tr -d "\r")"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

# osmo_hub_ip - hub address. Nothing known -> rc 1.
#   docker + local hub    : the backbone, 172.20.0.10;
#   docker, no local hub  : the WAN address seen by the operators (--hub-ip);
#   native                : OSMO_HUB_IP from /etc/osmo-role, else the same node probe.
# Cached: the probe costs one "docker exec" per node and checks call this
# function several times per run.
_OSMO_HUB_IP_CACHE=""
osmo_hub_ip() {
    if [ -n "$_OSMO_HUB_IP_CACHE" ]; then
        [ "$_OSMO_HUB_IP_CACHE" = "-" ] && return 1
        printf '%s\n' "$_OSMO_HUB_IP_CACHE"; return 0
    fi
    local v=""
    # MULTI_HUB_IP is authoritative: on a mixed bench the global mode would give
    # the wrong address (loopback for a native operator while the hub is a container).
    if _osmo_multi_load && [ -n "${MULTI_HUB_IP:-}" ]; then
        _OSMO_HUB_IP_CACHE="$MULTI_HUB_IP"
        printf '%s\n' "$MULTI_HUB_IP"; return 0
    fi
    if [ "$(osmo_mode)" = docker ]; then
        if osmo_hub >/dev/null 2>&1; then
            printf '%s.10\n' "$OSMO_BACKBONE_NET"; return 0
        fi
    else
        [ -r /etc/osmo-role ] && \
            v="$(awk -F= '/^OSMO_HUB_IP=/ { gsub(/[ \r\t]/, "", $2); print $2 }' /etc/osmo-role 2>/dev/null | tail -1)"
    fi
    [ -n "$v" ] || v="$(_osmo_hub_ip_probe 2>/dev/null || true)"
    if [ -z "$v" ]; then _OSMO_HUB_IP_CACHE="-"; return 1; fi
    _OSMO_HUB_IP_CACHE="$v"
    printf '%s\n' "$v"
}

# osmo_hub_is_remote - rc 0 (and prints the IP) when a hub is CONFIGURED but
# lives ELSEWHERE: the WAN case (--hub-ip / --wan) or a native operator node.
# A docker backbone or loopback address without a hub container does not
# count: then the hub is not remote, it is absent.
osmo_hub_is_remote() {
    local ip
    osmo_hub >/dev/null 2>&1 && return 1
    ip="$(osmo_hub_ip 2>/dev/null)" || return 1
    [ -n "$ip" ] || return 1
    case "$ip" in
        "${OSMO_BACKBONE_NET}."*|127.*|localhost) return 1 ;;
    esac
    printf '%s\n' "$ip"
}

# osmo_hub_assoc [ip] [port] - how many local nodes have an ESTABLISHED SCTP
# association to the hub? The inter-STP link is M3UA over SCTP, so a TCP probe
# ("nc -z" on 2908) is refused even when the link is up. "ss --sctp" is used,
# run from inside the NODE (containers have their own network stack).
# Prints "established/total"; rc 0 if at least one, 1 if none, 2 if the probe
# is not possible (no ss, no --sctp support, no queryable node).
osmo_hub_assoc() {
    local ip="${1:-}" port="${2:-$OSMO_HUB_M3UA_PORT}" op out probed=0 n=0 tot=0 pat
    [ -n "$ip" ] || ip="$(osmo_hub_ip 2>/dev/null || true)"
    [ -n "$ip" ] || return 2
    pat="${ip//./\\.}:${port}"
    for op in $(osmo_ops 2>/dev/null); do
        tot=$((tot+1))
        out="$(osmo_exec "$op" ss -an --sctp 2>/dev/null || true)"
        [ -n "$out" ] || continue
        probed=1
        grep -aqE "ESTAB.*[[:space:]]${pat}([[:space:]]|$)" <<<"$out" && n=$((n+1))
    done
    [ "$probed" -eq 1 ] || return 2
    printf '%s/%s\n' "$n" "$tot"
    [ "$n" -gt 0 ]
}

# osmo_hub_hint - ready-made skip() message when the hub exists but is
# elsewhere. Osmocom VTYs listen only on 127.0.0.1 (no repository config sets
# "bind" under "line vty"), so the hub's AS/ASP state is NOT observable from
# an operator node.
osmo_hub_hint() {
    local ip
    ip="$(osmo_hub_ip 2>/dev/null || true)"
    if [ -n "$ip" ]; then
        printf 'hub distant %s : VTY 4239 non joignable depuis ce noeud - lancez ./launch/start-interstp.sh --status sur le hub\n' "$ip"
    else
        printf 'aucun inter-STP local, et aucune adresse de hub connue ici (OSMO_HUB_IP, --hub-ip) - hub non interrogeable\n'
    fi
}

# =============================================================================
#  3. EXECUTION ON A NODE
# =============================================================================

# Native-mode netns prefix. Empty for a single operator: the backbone and
# namespaces are only created when N_OPERATORS > 1.
_osmo_ns_cmd() {
    local id ns
    id="$(_osmo_id "${1:-}")"
    [ -n "$id" ] || return 0
    ns="${OSMO_NETNS_PREFIX}${id}"
    if [ -e "/run/netns/$ns" ] || [ -e "/var/run/netns/$ns" ]; then
        printf 'ip netns exec %s' "$ns"
    fi
}

# osmo_exec <op> <argv...> - 1:1 replacement for "docker exec "$container" ...".
osmo_exec() {
    local op="${1:-}"; shift || return 2
    [ $# -ge 1 ] || return 2
    # Mode is decided per operator: on a mixed bench the native one is queried
    # locally while its neighbours go through docker exec.
    if [ "$(osmo_op_mode "$(_osmo_id "$op")")" = docker ]; then
        local c; c="$(osmo_node "$op")"
        [ -n "$c" ] || return 2
        docker exec "$c" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns must be word-split (ip netns exec X)
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# Same, but stdin is forwarded to the node ("docker exec -i").
# Internal: used for VTY dialogue, where the pipe feeds nc/telnet.
_osmo_exec_in() {
    local op="${1:-}"; shift || return 2
    if [ "$(osmo_op_mode "$(_osmo_id "$op")")" = docker ]; then
        docker exec -i "$(osmo_node "$op")" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# osmo_cat <op> <path> - contents of a file on the node (config, marker...).
osmo_cat() {
    local op="${1:-}" path="${2:-}"
    [ -n "$path" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        docker exec "$(osmo_node "$op")" cat "$path" 2>/dev/null
    else
        cat "${OSMO_NATIVE_ROOT}${path}" 2>/dev/null
    fi
}

# osmo_ast <op> <CLI command> - asterisk -rx, identical in both worlds.
osmo_ast() {
    local op="${1:-}" cli="${2:-}"
    [ -n "$cli" ] || return 2
    osmo_exec "$op" asterisk -rx "$cli" 2>/dev/null
}

# osmo_running <op> <daemon> - is this daemon running on this node?
#
# Native mode needs BOTH checks: on the ISO daemons are units
# (services/osmo-bts-trx.service...), but core_svc_start falls back to a
# detached process without systemd, where only pgrep answers.
#
# The "pgrep -f" fallback is needed because /proc/PID/comm is TRUNCATED to 15
# characters, so "pgrep -ax osmo-sip-connector" (18) never matches.
#
# Known limitation (native multi-operator): "ip netns exec" does not isolate
# PIDs, so the answer is per machine, not per operator.
osmo_running() {
    local op="${1:-}" name="${2:-}"
    [ -n "$name" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        osmo_exec "$op" pgrep -ax "$name" >/dev/null 2>&1 && return 0
        osmo_exec "$op" pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
        return $?
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" 2>/dev/null && return 0
    fi
    pgrep -ax "$name" >/dev/null 2>&1 && return 0
    pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
}

# osmo_sock <op> <path> - is a UNIX socket listening?
# ss is queried BEFORE the file test: under PrivateTmp, /tmp/msc_mncc exists
# but is invisible to "test -S" (run_modules/13-msc.sh).
# awk reads ALL its input (no mid-pipe "exit"): an early exit would kill ss
# with SIGPIPE and return 141 under pipefail.
osmo_sock() {
    local op="${1:-}" p="${2:-}" out
    [ -n "$p" ] || return 2
    out="$(osmo_exec "$op" ss -xlH 2>/dev/null || true)"
    awk -v w="$p" '{ for (i = 1; i <= NF; i++) if ($i == w) f = 1 } END { exit !f }' <<<"$out" && return 0
    osmo_exec "$op" test -S "$p" 2>/dev/null
}

# osmo_port <op> <port> [tcp|udp|sctp] - is this port listening on the node?
# Exact port match: ":7890" does not match 17890 or 78901.
osmo_port() {
    local op="${1:-}" port="${2:-}" proto="${3:-tcp}" out
    local -a opts
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    case "$proto" in
        tcp)  opts=(-H -ltn) ;;
        udp)  opts=(-H -lun) ;;
        sctp) opts=(-H -ln --sctp) ;;
        *)    return 2 ;;
    esac
    out="$(osmo_exec "$op" ss "${opts[@]}" 2>/dev/null || true)"
    # ss field 4 is the local "address:port" for tcp, udp and sctp.
    awk -v want="$port" '
        { a = $4
          if (a == "" || match(a, /:[0-9]+$/) == 0) next
          if (substr(a, RSTART + 1) == want) f = 1 }
        END { exit !f }' <<<"$out"
}

# osmo_host <op> - host to reach this node FROM HERE (SMS relay, SIP,
# M3UA...). NOT the VTY host, which is always 127.0.0.1 inside the node
# (handled by osmo_vty).
#   docker           : container IP on the backbone (172.20.0.1N, .10 = hub)
#   native + netns   : the same backbone, recreated in netns
#   native single-op : 127.0.0.1 - no gsm-inter bridge, no 172.20.0.0/24
#   native hub       : OSMO_HUB_IP from /etc/osmo-role, else 127.0.0.1
osmo_host() {
    local op="${1:-}" id
    case "$op" in
        hub|osmo-inter-stp)
            if [ "$(osmo_mode)" = docker ]; then
                printf '%s.10\n' "$OSMO_BACKBONE_NET"
            else
                local h; h="$(osmo_hub_ip 2>/dev/null || true)"
                printf '%s\n' "${h:-127.0.0.1}"
            fi
            return 0 ;;
    esac
    id="$(_osmo_id "$op")"
    if [ -n "$id" ] && { [ "$(osmo_mode)" = docker ] || [ -n "$(_osmo_ns_cmd "$op")" ]; }; then
        printf '%s.%s\n' "$OSMO_BACKBONE_NET" "$((10 + id))"
    else
        printf '127.0.0.1\n'
    fi
}

# =============================================================================
#  4. VTY
# =============================================================================

# Which VTY client does this node have? nc preferred, telnet as fallback.
# The ISO installs netcat-openbsd AND telnet but NOT socat (unlike core_vty_ask
# in run_modules/). The diagnostic is printed ONCE per node, on stderr.
_osmo_vty_tool() {
    local op="${1:-}" key tool
    key="$(osmo_node "$op")"
    tool="${_OSMO_VTY_TOOL[$key]:-}"
    if [ -z "$tool" ]; then
        if osmo_exec "$op" sh -c 'command -v nc' >/dev/null 2>&1; then
            tool=nc
        elif osmo_exec "$op" sh -c 'command -v telnet' >/dev/null 2>&1; then
            tool=telnet
        else
            tool=none
            printf 'checks/_mode.sh : aucun client VTY sur %s - installez netcat-openbsd ou telnet (apt-get install -y netcat-openbsd telnet)\n' \
                   "$key" >&2
        fi
        _OSMO_VTY_TOOL[$key]="$tool"
    fi
    [ "$tool" = none ] && return 1
    printf '%s\n' "$tool"
}

# osmo_vty_up <op> <port> - does the VTY answer?
# In native mode the PASSIVE probe (ss) is tried first: it opens no VTY
# session. If it sees nothing (no ss, restricted /proc), fall back to the
# active probe - no false negatives.
osmo_vty_up() {
    local op="${1:-}" port="${2:-}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" != docker ] && command -v ss >/dev/null 2>&1; then
        osmo_port "$op" "$port" tcp && return 0
    fi
    osmo_exec "$op" bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null
}

# osmo_vty <op> <port> <command>... - sends the commands to the VTY and
# prints the RAW output (banner and prompt included; osmo_vty_clean filters).
#
# Returns 1 WITHOUT OUTPUT if the VTY does not answer or the node has neither
# nc nor telnet, so callers can tell "service silent" from "no answer to
# this command". The pre-check is osmo_vty_up (one TCP open/close).
#
# The caller supplies its own "enable" / "end": the library adds no command.
#
# TIMINGS ARE PARAMETERS (environment variables), because each script has its
# own and changing them changes the AMOUNT of captured output, hence the
# "grep -ac" counts:
#     OSMO_VTY_OPEN  delay before writing (0.5; ss7_check: 1)
#     OSMO_VTY_READ  read delay           (2  ; ss7_check: 1.5)
#     OSMO_VTY_Q     nc -q<N>             (1  ; vty-debug-dump: 2)
#     OSMO_VTY_KILL  hard timeout of the VTY client, seconds (8)
# The Osmocom VTY ignores input received before its telnet negotiation ends:
# these sleeps pace the DIALOGUE, they are not wait barriers.
osmo_vty() {
    local op="${1:-}" port="${2:-}"
    [ $# -ge 3 ] || return 2
    shift 2
    case "$port" in ''|*[!0-9]*) return 2 ;; esac

    osmo_vty_up "$op" "$port" || return 1

    local body="" c
    for c in "$@"; do body="${body}${c}"$'\n'; done

    local tool
    tool="$(_osmo_vty_tool "$op")" || return 1

    local open="${OSMO_VTY_OPEN:-0.5}" read_s="${OSMO_VTY_READ:-2}" q="${OSMO_VTY_Q:-1}"
    # The VTY client is always run under "timeout": operator docker images only
    # have telnet, which has no equivalent of nc's "-q" (EOF on stdin does not
    # hang up, and the Osmocom VTY does not close after "end"), so it would block
    # forever. The timeout runs INSIDE the node (docker exec ... timeout N telnet):
    # killing docker exec from here would leave telnet running in the container.
    local kill_after="${OSMO_VTY_KILL:-8}"

    # nc/telnet often exit before reading everything: the producer subshell
    # then gets SIGPIPE and the pipe returns 141. "|| true" keeps the function
    # usable under "set -euo pipefail".
    if [ "$tool" = nc ]; then
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" timeout "$kill_after" nc "-q${q}" 127.0.0.1 "$port" 2>/dev/null || true
    else
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" timeout "$kill_after" telnet 127.0.0.1 "$port" 2>/dev/null || true
    fi
    return 0
}

# osmo_vty_clean [extra pattern] - stdin->stdout filter removing banner, prompt
# and empty lines. The base pattern and the ORDER of filters match the
# scripts exactly: changing them would change their output.
# global_check.sh and ss7_check.sh also drop "Free Software lives", which
# vty-debug-dump.sh keeps - hence the optional argument:
#     osmo_vty_clean 'Free Software lives'
osmo_vty_clean() {
    local extra="${1:-}"
    local re="^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete|% Error|\
Connection closed)"
    [ -n "$extra" ] && re="${re%)}|${extra})"
    grep -avE "$re" | sed 's/\r//' | grep -av '^[[:space:]]*$' || true
}

# osmo_vty_interactive <op> <port> [host] - opens an INTERACTIVE VTY session
# (a human at the keyboard), whereas osmo_vty sends commands and returns output.
# 1:1 replacement for "docker exec -ti <container> telnet <ip> <port>".
# The host is a PARAMETER because Baseband groups listen on 127.0.0.1,
# 127.0.0.2... (tools/vty-menu.sh): the only VTY target in the repository
# other than 127.0.0.1.
osmo_vty_interactive() {
    local op="${1:-}" port="${2:-}" host="${3:-127.0.0.1}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" = docker ]; then
        docker exec -ti "$(osmo_node "$op")" telnet "$host" "$port"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns must be word-split (ip netns exec X)
    if [ -n "$ns" ]; then $ns telnet "$host" "$port"; else telnet "$host" "$port"; fi
}

# osmo_vty_target <op> - "target" to hand to a non-bash VTY client that
# cannot source this library (tools/vty-connect.exp, written in expect).
# The mode is decided in bash (tools/vty-menu.sh) and passed as an ARGUMENT:
#     docker -> the container name, which becomes "docker exec -ti <name> telnet"
#     native -> "-", which becomes a direct "telnet"
# "-" rather than an empty string: an empty string is lost in an expect
# [lindex] as in a bash "$@", and "native" becomes indistinguishable from
# "missing argument".
osmo_vty_target() {
    if [ "$(osmo_mode)" = docker ]; then osmo_node "${1:-}"; else printf -- '-\n'; fi
}

# =============================================================================
#  5. CATEGORY A - CLEAN REFUSAL WHEN DOCKER IS MISSING
# =============================================================================
#
#  Some scripts inherently DRIVE docker (build an image, create a
#  172.20.N.0/24 network, start a container) and have no native equivalent;
#  the native counterparts are start-native.sh and start-interstp.sh.
#  On an ISO without docker these scripts must refuse cleanly and name the
#  alternative instead of failing with "docker: command not found".

# osmo_docker_ok - is docker REALLY usable from here?
# The binary is not enough (dev machines often have it without a running
# daemon), so the daemon is queried. No pipe: no pipefail trap.
osmo_docker_ok() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

# osmo_require_docker [alternative line...] - clean refusal, then exit 3.
# Returns 0 silently if docker is usable, so it can be called unconditionally
# at the top of a script.
#
# The message says WHAT IS MISSING, WHY this script needs it, and WHAT TO RUN
# instead, by exact name. Without alternatives given as arguments, the two
# repository ones are named.
#
# Output on stderr, exit code 3: distinct from 1 (execution failure) and 2
# (bad argument), so a caller can recognise "wrong world" without parsing text.
osmo_require_docker() {
    osmo_docker_ok && return 0
    {
        printf '\n%s\n\n' "Docker n'est pas utilisable sur cette machine."
        if command -v docker >/dev/null 2>&1; then
            printf '%s\n' "  Le binaire docker est la, mais le demon ne repond pas."
            printf '%s\n' "  → sudo systemctl start docker, puis relancer ce script."
        else
            printf '%s\n' "  La commande docker est absente - c'est le cas normal sur l'ISO,"
            printf '%s\n' "  en VM et sur une machine nue : la pile y est installee en dur."
        fi
        printf '\n%s\n' "Ce script pilote docker (images, reseaux, conteneurs). Il n'a pas"
        printf '%s\n' "d'equivalent natif a ecrire : l'equivalent EXISTE DEJA, et il a un nom."
        printf '%s\n\n' "Lancez plutot :"
        if [ $# -gt 0 ]; then
            local _l; for _l in "$@"; do printf '  %s\n' "$_l"; done
        else
            printf '  %s\n' "./start-native.sh     - la pile complete de CE noeud (un operateur)"
            printf '  %s\n' "./launch/start-interstp.sh   - le hub SS7 inter-operateurs"
        fi
        printf '\n%s\n' "Sur l'ISO ces deux-la sont deja dans le PATH : osmo-start-direct."
        printf '%s\n\n' "Pour verifier l'etat sans rien demarrer : ./checks/global_check.sh"
    } >&2
    exit 3
}

# =============================================================================
#  6. MISC
# =============================================================================

# osmo_qgrep <args...> - "grep -aq" without the pipefail trap.
# With "cmd | grep -aq pattern" grep exits on the FIRST match, the producer
# gets SIGPIPE and the pipe returns 141 under "set -o pipefail", so a match
# can intermittently read as no match. Here grep reads all input and its
# output is discarded. Same as qgrep() in network/setup-wan-mesh.sh.
osmo_qgrep() { grep "$@" >/dev/null; }

# =============================================================================
#  When executed instead of sourced: nothing destructive, just print what the
#  library detects. Serves as a quick self-test.
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'mode      : %s\n' "$(osmo_mode)"
    printf 'operateurs: %s\n' "$(osmo_ops | tr '\n' ' ')"
    if hub="$(osmo_hub)"; then
        printf 'inter-STP : %s (interrogeable ici)\n' "$hub"
    else
        printf 'inter-STP : %s\n' "$(osmo_hub_hint)"
    fi
    printf 'hote op.1 : %s\n' "$(osmo_host 1)"
    exit 0
fi
