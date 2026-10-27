#!/bin/bash
# =============================================================================
#  osmo-op - WHICH OPERATOR THE SCREEN IS LOOKING AT
# =============================================================================
#  The bench desktop has ONE panel (tools/osmo-panel.py) and ONE Conky
#  (tools/conky-osmo-status.sh), but a multi bench carries three operators
#  plus the hub. The choice lives in a single file, /run/osmo-fft/operator,
#  which both read at every refresh:
#
#      OP=2  MODE=docker  IP=172.20.0.12  NAME=osmo-operator-2
#      DASH=http://172.20.0.12:8080
#
#  This script is what WRITES it, and the only definition of "the operator
#  list" - the panel and the Conky refer to it, they do not recompute it.
#
#      osmo-op                 the current operator
#      osmo-op --list          the operators and their state
#      osmo-op --list-vue      the VISIBLE stops (what is running) and their state
#      osmo-op --next / --prev the next / previous operator  (the arrows)
#      osmo-op --set N         operator N
#
#  STOPPED OPERATORS COUNT TOO. The screen must be able to look at a stopped
#  operator: that is precisely when it is needed (to see why it did not
#  start). The state (active / stopped) is shown, not filtered; --list-vue
#  only keeps what is running, for the arrow cycle.
#
#  NO INVENTED OPERATORS, however. Without /etc/osmocom/osmo-multi.conf -
#  so on a single-operator bench - the list returns the native one only,
#  and the panel hides its arrows: there is nowhere to go. The arrows only
#  appear when the topology really declares several operators.
#  The hub (index "hub") and the 4G (index "lte") are extra stops after the
#  2G operators: no number, no FFT, their own view in the Conky.
# =============================================================================
set -u
RUN="${OSMO_FFT_DIR:-/run/osmo-fft}"
OP_FILE="$RUN/operator"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
DASH_PORT="${DASH_PORT:-8080}"
HUB_NAME="${MULTI_HUB_NAME:-osmo-inter-stp}"
M3UA_PORT="${MULTI_M3UA_PORT:-2908}"

# ── THE LIST: "idx mode ip" per line ────────────────────────────────────────
# The topology first (MULTI_OPS of osmo-multi.conf, written by addition.sh);
# otherwise op 1 native + the next ones in docker, on the addressing plan of
# the hub (172.20.0.1<idx>, see start-multi.sh).
liste() {
    local specs="" idx mode ip
    if [ -r "$MULTI_CONF" ]; then
        specs="$(sed -nE 's/^MULTI_OPS="?([^"]*)"?.*/\1/p' "$MULTI_CONF" | head -1)"
    fi
    if [ -n "$specs" ]; then
        for s in $specs; do
            IFS=: read -r idx mode ip _ <<< "$s"
            [ -n "$idx" ] || continue
            echo "$idx ${mode:-docker} ${ip:-}"
        done
        # ── AND THE HUB, IN LAST POSITION ───────────────────────────────────
        # The inter-STP is the fourth stop, after op3, before coming back to
        # op1: it is the node queried when the SS7 goes wrong. Its "index" is
        # its name (hub) and not a digit: it does not number an operator, and
        # the panel renders it as an SS7 view (the matrix, the ASPs, its log)
        # instead of the I/Q spectrum - an M3UA hub has no radio.
        _hub_ip="$(sed -nE 's/^MULTI_HUB_IP=([^ #]*).*/\1/p' "$MULTI_CONF" | head -1)"
        echo "hub interstp ${_hub_ip:-172.20.0.10}"
    else
        # No topology: a single operator, the native one. Nothing to cycle.
        echo "1 native "
    fi
    # ── AND THE 4G, IF INSTALLED ON THIS MACHINE ────────────────────────────
    # The bench carries a complete 4G (tools/osmo-lte.sh: Open5GS, srsENB and
    # srsUE on ZeroMQ). It is the last stop - after the 2G operators and the
    # hub - and the Conky gives it its own view (the EPC core daemons, the
    # eNB, the UE, the S1, the cell). Its "index" is "lte", like the hub's is
    # "hub": it does not number a 2G operator. No container, no FFT:
    # everything is native on the host.
    lte_installee && echo "lte lte "
}

# Is the 4G installed here? The binaries, where tools/osmo-lte-install.sh puts
# them (or the local srsRAN build).
lte_installee() {
    [ -x /usr/local/bin/srsenb ] && return 0
    [ -x "${OPEN5GS_PREFIX:-/opt/LTE/open5gs/install}/bin/open5gs-mmed" ] && return 0
    [ -x "${OSMO_SRSRAN_BUILD:-/opt/LTE/srsRAN_4G/build}/srsenb/src/srsenb" ]
}

# actif IDX MODE [IP]: is the operator running?
#
# "STOPPED" must not mean "I AM NOT ALLOWED TO SEE". The Conky and the panel
# run under the SESSION account, not root, and that account is not necessarily
# in the `docker` group:
#     $ docker ps
#     permission denied while trying to connect to the docker API at
#     unix:///var/run/docker.sock
# `docker ps 2>/dev/null | grep -qx` would then return false and the screen
# would report op2 and op3 STOPPED while `docker ps` as root shows them "Up".
# A probe that confuses "absent" and "invisible" lies.
#
# The two cases are told apart: if docker does not answer US, fall back to a
# probe that needs no privilege - the operator dashboard, on its IP on the
# hub network. The account is added to the `docker` group elsewhere
# (installer/calamares/modules/users.conf, addition.sh); this fallback covers
# the already open session, where the group has not taken effect yet.
actif() {
    if [ "$2" = lte ]; then
        # The 4G is running as soon as the core or the radio runs (osmo-lte status).
        pgrep -x open5gs-mmed >/dev/null 2>&1 || pgrep -x srsenb >/dev/null 2>&1 \
            || pgrep -x srsue >/dev/null 2>&1
    elif [ "$2" = interstp ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${HUB_NAME}"
        else
            # Without docker access: the hub M3UA port, in SCTP - a TCP probe
            # would be silent there, hence `ss` rather than a /dev/tcp.
            ss -an 2>/dev/null | awk -v p=":${M3UA_PORT}" \
               '$1=="sctp" && index($5,p) {f=1} END{exit !f}'
        fi
    elif [ "$2" = native ]; then
        pgrep -x osmo-bsc >/dev/null 2>&1 || pgrep -x osmo-stp >/dev/null 2>&1
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "osmo-operator-$1"
    elif [ -n "${3:-}" ]; then
        timeout 1 bash -c "echo >/dev/tcp/$3/${DASH_PORT}" 2>/dev/null
    else
        return 1
    fi
}

courant() { sed -n 's/^OP=//p' "$OP_FILE" 2>/dev/null | head -1; }

ecrire() {
    local idx="$1" mode="$2" ip="$3"
    # ── THE DIRECTORY BELONGS TO THE BENCH, NOT TO WHOEVER COMES FIRST ──────
    # /run/osmo-fft is normally created by osmo-fft-snap.service
    # (RuntimeDirectory, 0775, group sudo): the panel and the probes run under
    # the SESSION account and must be able to write there. This `mkdir -p` may
    # create it BEFORE the unit, as root; the same permissions as the unit are
    # applied so that the session probes (osmo-ts-probe.py among them) can
    # write. In session (non root) the chgrp fails harmlessly, the directory
    # already belongs to the right account.
    if [ ! -d "$RUN" ]; then
        mkdir -p "$RUN" 2>/dev/null || true
        chmod 0775 "$RUN" 2>/dev/null || true
        chgrp sudo "$RUN" 2>/dev/null || true
    fi
    local nom="osmo-operator-$idx"
    [ "$mode" = interstp ] && nom="$HUB_NAME"
    [ "$mode" = lte ] && nom="osmo-lte"
    printf 'OP=%s\nMODE=%s\nIP=%s\nNAME=%s\nDASH=http://%s:%s\n' \
        "$idx" "$mode" "$ip" "$nom" "${ip:-127.0.0.1}" "$DASH_PORT" > "$OP_FILE.tmp" \
        && mv -f "$OP_FILE.tmp" "$OP_FILE"
}

# ── THE VISIBLE STOPS: WHAT REALLY RUNS ON THIS MACHINE ─────────────────────
# On a bench where only op1 is up, the cycle only shows what is running - a
# single `docker ps` tells it for the three. A stopped operator is therefore
# not reachable with the arrows; `osmo-op --set 2` still goes there, and
# `osmo-op --list` keeps showing ALL of them with their state - that is where
# "op2 arrete" is read.
#
# Two exceptions, which are not docker operators: the first stop (the native
# operator, THIS machine - its bench may be stopped without disappearing) and
# the 4G (installed here, running or not: that view is precisely the one that
# says how to start it).
liste_vue() {
    local premier=1 noms="" docker_ok=0
    if noms="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then docker_ok=1; fi
    while read -r idx mode ip; do
        if [ "$premier" = 1 ] || [ "$mode" = lte ]; then
            echo "$idx $mode $ip"
        elif [ "$docker_ok" = 0 ]; then
            # docker does not answer us (not in the group): we do NOT know,
            # and a probe that confuses "absent" and "invisible" lies. Keep
            # the stop rather than wrongly hiding it.
            echo "$idx $mode $ip"
        elif [ "$mode" = interstp ]; then
            printf '%s\n' "$noms" | grep -qx "$HUB_NAME" && echo "$idx $mode $ip"
        else
            printf '%s\n' "$noms" | grep -qx "osmo-operator-$idx" && echo "$idx $mode $ip"
        fi
        premier=0
    done < <(liste)
}

# shift +1 / -1 in the list, wrapping around.
decale() {
    local pas="$1" cur n i=0 sel=0
    cur="$(courant)"; cur="${cur:-1}"
    mapfile -t L < <(liste_vue)
    n="${#L[@]}"; [ "$n" -gt 0 ] || return 1
    for i in "${!L[@]}"; do
        [ "${L[$i]%% *}" = "$cur" ] && sel="$i"
    done
    sel=$(( (sel + pas + n) % n ))
    # shellcheck disable=SC2086
    set -- ${L[$sel]}
    ecrire "$1" "$2" "${3:-}"
    echo "op $1 (${2})"
}

case "${1:-}" in
    --list|-l)
        while read -r idx mode ip; do
            if actif "$idx" "$mode" "$ip"; then e="actif"; else e="arrete"; fi
            [ "$idx" = "$(courant)" ] && e="$e  <- ecran"
            printf '  op %-2s %-7s %-13s %s\n' "$idx" "$mode" "${ip:-(hote)}" "$e"
        done < <(liste) ;;
    --list-vue)
        # "idx mode ip etat" - THE list the Conky builds its selector on, so
        # that screen and arrows stop at the same places.
        while read -r idx mode ip; do
            if actif "$idx" "$mode" "$ip"; then e=actif; else e=arrete; fi
            # The IP may be empty (the host): a dash replaces it, otherwise the
            # line only has three fields and the reader takes the state for an
            # address.
            echo "$idx $mode ${ip:--} $e"
        done < <(liste_vue) ;;
    --next|-n) decale 1 ;;
    --prev|-p) decale -1 ;;
    --set|-s)
        [ $# -ge 2 ] || { echo "usage: $0 --set N" >&2; exit 2; }
        while read -r idx mode ip; do
            if [ "$idx" = "$2" ]; then ecrire "$idx" "$mode" "$ip"; echo "op $idx ($mode)"; exit 0; fi
        done < <(liste)
        echo "op $2 : absent de la topologie ($MULTI_CONF)" >&2; exit 1 ;;
    ""|--current|-c)
        [ -r "$OP_FILE" ] && cat "$OP_FILE" || echo "OP=1"$'\n'"MODE=native" ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
