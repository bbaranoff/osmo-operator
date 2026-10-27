#!/bin/bash
# =============================================================================
# osmo-epc.sh - THE BENCH 4G CORE: Open5GS (EPC).
#
# Open5GS provides a complete EPC, and above all the SGs interface to OsmoMSC
# that allows CSFB (voice and SMS from LTE). Addressing plan: the UEs are in
# 10.45.0.0/16 on ogstun (NOT 172.17.0.0/24, which overlaps docker0).
#
# OPEN5GS LIVES IN /opt/LTE. The prefix is /opt/LTE/open5gs/install (the
# Dockerfile, the osmo-build-open5gs .deb and tools/osmo-lte-install.sh put it
# there); the old /root/open5gs/install path is still accepted, as a last
# resort, for a machine not yet migrated. The configs ARE PART OF THE
# REPOSITORY: configs/open5gs/*.yaml, installed by osmo-lte-install.sh in
# $PREFIX/etc/open5gs.
#
#   osmo-epc start        mongod, ogstun + NAT, then the daemons in order
#   osmo-epc stop         stops the daemons (ogstun stays)
#   osmo-epc restart
#   osmo-epc status       one state per daemon, ogstun, SGs
#   osmo-epc subscribers  loads the repository subscribers (configs/open5gs/
#                         subscribers.json) into MongoDB if they are missing
#   osmo-epc log [name]   the log of a daemon (mme by default), live
#
# Variables: OPEN5GS_PREFIX, SRS_WAN (NAT output interface; by default the
# one of the default route), OPEN5GS_UESUBNET, OPEN5GS_TUNADDR.
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
# The prefix: the variable, else /opt/LTE, else the old /root.
_prefix() {
    local p
    for p in "${OPEN5GS_PREFIX:-}" /opt/LTE/open5gs/install /root/open5gs/install; do
        [ -n "$p" ] && [ -x "$p/bin/open5gs-mmed" ] && { echo "$p"; return 0; }
    done
    echo "${OPEN5GS_PREFIX:-/opt/LTE/open5gs/install}"
}
PREFIX="$(_prefix)"
BIN="$PREFIX/bin"
ETC="$PREFIX/etc/open5gs"
LOG="$PREFIX/var/log/open5gs"
UESUBNET="${OPEN5GS_UESUBNET:-10.45.0.0/16}"
TUNADDR="${OPEN5GS_TUNADDR:-10.45.0.1/16}"
# The NAT output interface: SRS_WAN, else the one of the default route
# (not hard-coded: another machine does not have the same card).
WAN="${SRS_WAN:-$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
# Start order: the NRF (the SMF SBIs look for it), the HSS before the MME
# (Diameter), the user planes before the control planes attached to them.
DAEMONS="open5gs-nrfd open5gs-hssd open5gs-sgwcd open5gs-sgwud open5gs-smfd open5gs-upfd open5gs-pcrfd open5gs-mmed"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }
_root() { [ "$(id -u)" -eq 0 ] && return 0; _err "il faut root (tun, NAT, mongod) : sudo $0 $*"; return 1; }

[ -x "$BIN/open5gs-mmed" ] || { _err "Open5GS introuvable ($BIN/open5gs-mmed) - « osmo-lte-install --build » ou dpkg -i osmo-build-open5gs"; [ "${1:-}" = status ] || exit 1; }

# MONGOD FIRST. The HSS and the PCRF read the subscribers in MongoDB and DIE
# at initialisation if it is not running ("Failed to connect to server
# [mongodb://localhost/open5gs]"): the MME then answers 3002 on S6a and
# rejects every attach (EMM cause 15). The service may be "disabled": it is
# started here, every time.
_mongod() {
    systemctl is-active --quiet mongod && return 0
    if systemctl start mongod 2>/dev/null; then
        _ok "mongod demarre"; sleep 2
    else
        _err "mongod ne demarre pas (HSS et PCRF ne tiendront pas) : apt install mongodb-org"
        return 1
    fi
}

# The repository subscribers, loaded if missing. The field slice[].session[].smf
# (127.0.0.200, WebUI default value) is REMOVED: it takes precedence over
# gtpc.client.smf of mme.yaml and the SGW-C would send the Create Session to
# 127.0.0.200, where nobody answers (GTP Timeout, RRC Release).
epc_subscribers() {
    _root subscribers || return 1
    _mongod || return 1
    local dump="$REPO/configs/open5gs/dump/open5gs" j="$REPO/configs/open5gs/subscribers.json" n
    command -v mongosh >/dev/null 2>&1 || { _warn "mongosh absent : abonnes non poses"; return 0; }
    n="$(mongosh --quiet open5gs --eval 'print(db.subscribers.countDocuments())' 2>/dev/null | tail -1)"
    # Empty database and a mongodump in the repository (configs/open5gs/dump:
    # subscribers, WebUI accounts, sessions): restore EVERYTHING as is (BSON:
    # the sqn Longs and the ObjectIds stay what they are).
    if [ "${n:-0}" = "0" ] && [ -f "$dump/subscribers.bson" ] && command -v mongorestore >/dev/null 2>&1; then
        mongorestore --quiet --db open5gs "$dump" >/dev/null 2>&1 \
            && _ok "base open5gs restauree depuis le depot (mongodump)" \
            || _warn "mongorestore a echoue - on essaie le JSON"
    fi
    [ -s "$j" ] || return 0
    mongosh --quiet open5gs --eval "
        const subs = JSON.parse(require('fs').readFileSync('$j', 'utf8'));
        let n = 0;
        for (const s of subs) {
            // JSON.stringify d un Long donne {high, low, unsigned} : on le refait Long.
            if (s.security && s.security.sqn && typeof s.security.sqn === 'object')
                s.security.sqn = Long.fromBits(s.security.sqn.low, s.security.sqn.high);
            delete s.mme_timestamp;
            if (db.subscribers.countDocuments({ imsi: s.imsi }) === 0) { db.subscribers.insertOne(s); n++; }
        }
        db.subscribers.updateMany({ 'slice.session.smf': { \$exists: true } }, { \$unset: { 'slice.$[].session.$[].smf': '' } });
        print('abonnes en base : ' + db.subscribers.countDocuments() + ' (' + n + ' ajoute(s) depuis le depot)');
    " 2>&1 | sed 's/^/  /'
}

setup_tun() {
    if ! ip link show ogstun >/dev/null 2>&1; then
        ip tuntap add name ogstun mode tun && _ok "ogstun cree"
    fi
    ip addr replace "$TUNADDR" dev ogstun
    ip link set ogstun up
    sysctl -q -w net.ipv4.ip_forward=1
    if [ -n "$WAN" ]; then
        iptables -t nat -C POSTROUTING -s "$UESUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$UESUBNET" -o "$WAN" -j MASQUERADE
        _ok "ogstun $TUNADDR, NAT $UESUBNET -> $WAN"
    else
        _warn "ogstun $TUNADDR, pas de route par defaut : pas de NAT (SRS_WAN=<iface>)"
    fi
    setup_forward
}

# THE FORWARD, WITHOUT WHICH THE NAT IS USELESS. Docker sets a DROP FORWARD
# policy on the host: a packet from the UE (10.45.0.2, via ogstun) to the
# Internet would be NATed then dropped, without refusal or trace (seen from
# the pmOS phone: PPP up, address assigned, gateway ping OK, nothing beyond).
# Same mechanism as start-docker.sh for the WAN: DOCKER-USER is consulted
# before docker's rules and docker does not rewrite it; everything entering
# or leaving through ogstun is allowed there. Replayed at every "osmo-epc
# start" (hence every "osmo-lte start"), and by osmo-pmos-qemu at every VM
# launch.
setup_forward() {
    local spec
    iptables -N DOCKER-USER 2>/dev/null || true
    for spec in "-i ogstun" "-o ogstun"; do
        # shellcheck disable=SC2086
        iptables -C DOCKER-USER $spec -j ACCEPT 2>/dev/null \
            || iptables -I DOCKER-USER 1 $spec -j ACCEPT 2>/dev/null \
            || { _warn "FORWARD ($spec) : iptables refuse - la data des UE n ira pas plus loin que l hote"; return 0; }
    done
    # The DOCKER-USER rules only matter if FORWARD goes through them: docker
    # does that (-A FORWARD -j DOCKER-USER); without docker, skip the step.
    iptables -C FORWARD -j DOCKER-USER 2>/dev/null || iptables -I FORWARD 1 -j DOCKER-USER 2>/dev/null || true
    _ok "FORWARD ogstun <-> $WAN autorise (DOCKER-USER)"
}

epc_start() {
    _root start || return 1
    _mongod || true
    epc_subscribers >/dev/null 2>&1 || true
    mkdir -p "$LOG"
    setup_tun
    local d y
    for d in $DAEMONS; do
        if pgrep -x "$d" >/dev/null; then _ok "$d deja en cours"; continue; fi
        # -D: daemon. The config is the one of $ETC (the prefix), installed
        # from the repository by osmo-lte-install.sh. open5gs-nrfd reads
        # nrf.yaml, not nrfd.yaml: -c must point to the right file, otherwise
        # the fallback without -c (the path compiled into the binary) would
        # start it and a different OPEN5GS_PREFIX would never read its configs.
        # stdout ALSO goes to /dev/null: -D does not detach the descriptors,
        # the daemon would keep the "osmo-epc start | sed" pipe of osmo-lte.sh
        # open and sed would never see its end.
        y="${d#open5gs-}"; y="$ETC/${y%d}.yaml"
        if "$BIN/$d" -D -c "$y" >/dev/null 2>&1; then :; else
            "$BIN/$d" -D >/dev/null 2>&1
        fi || _err "ECHEC $d (voir $LOG/$(basename "$y" .yaml).log)"
        sleep 0.5
        # "started" IS NOT ENOUGH: -D returns before the daemon has read its
        # config. An MME without freeDiameter/mme.conf (see configs/open5gs/
        # freeDiameter/mme.conf) reports started and then dies at once - the S1
        # does not listen, srsUE receives ConnectionReject, and nobody says
        # why. So check that it is STILL there; otherwise replay it for 3 s in
        # the foreground to report the reason (its FATAL / ERROR lines).
        if pgrep -x "$d" >/dev/null; then _ok "$d demarre"
        else
            _err "$d est mort a l init :"
            timeout 3 "$BIN/$d" -c "$y" 2>&1 | grep -aE 'FATAL|ERROR' | grep -v backtrace | head -3 | sed 's/^/      /'
        fi
    done
    sleep 1
    ss -np 2>/dev/null | grep -q 29118 && _ok "SGs : association vers OsmoMSC etablie" \
        || _warn "SGs : pas encore d association (osmo-msc lance ?)"
}

epc_stop() {
    _root stop || return 1
    local d n=0
    for d in $DAEMONS; do pgrep -x "$d" >/dev/null && { pkill -TERM -x "$d"; n=$((n + 1)); }; done
    sleep 1
    for d in $DAEMONS; do pgrep -x "$d" >/dev/null && pkill -KILL -x "$d"; done
    [ "$n" -gt 0 ] && _ok "$n demon(s) Open5GS arrete(s)" || _ok "rien ne tournait"
}

epc_status() {
    echo -e "\033[1mOpen5GS - le coeur 4G du banc\033[0m  ($PREFIX)"
    local d
    for d in $DAEMONS; do
        pgrep -x "$d" >/dev/null && _ok "$d" || _warn "$d : arrete"
    done
    systemctl is-active --quiet mongod && _ok "mongod actif" || _warn "mongod arrete"
    ip -br addr show ogstun 2>/dev/null | sed 's/^/  /' || _warn "ogstun absent"
    ss -San 2>/dev/null | grep -q "ESTAB.*:36412" && _ok "S1 : un eNB est associe" || _warn "S1 : aucun eNB"
}

case "${1:-status}" in
    start)       epc_start ;;
    stop)        epc_stop ;;
    restart)     epc_stop; sleep 1; epc_start ;;
    status)      epc_status ;;
    subscribers) epc_subscribers ;;
    log)         exec tail -F "$LOG/${2:-mme}.log" ;;
    *) sed -n '/^#   osmo-epc start/,/^#   osmo-epc log/p' "$0" | sed 's/^# \{0,2\}//'; exit 2 ;;
esac
