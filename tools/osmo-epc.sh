#!/bin/bash
# =============================================================================
# osmo-epc.sh - LE COEUR 4G DU BANC : Open5GS (EPC), en remplacement de srsepc.
#
# [2026-09-07] srsepc etait un coeur de demonstration : mono-UE, sans vraie
# gestion de session et sans interface SGs. Open5GS apporte un EPC complet,
# et surtout le SGs vers OsmoMSC qui permet le CSFB (voix et SMS depuis le
# LTE). Plan d adressage : les UE sont en 10.45.0.0/16 sur ogstun (PAS le
# 172.17.0.0/24 de srsepc, qui recouvrait docker0).
#
# [2026-09-08] OPEN5GS VIT DANS /opt/LTE, PAS DANS /root. Il avait ete compile
# dans /root/open5gs/install : un coeur de reseau dans le home de root n est
# ni dans l ISO, ni dans un .deb, ni relisible par le compte de session. Le
# prefixe est maintenant /opt/LTE/open5gs/install (le Dockerfile, le .deb
# osmo-build-open5gs et tools/osmo-lte-install.sh le posent la) ; l ancien
# chemin reste accepte, en dernier recours, pour une machine pas encore
# migree. Les configs FONT PARTIE DU DEPOT : configs/open5gs/*.yaml, posees
# par osmo-lte-install.sh dans $PREFIX/etc/open5gs.
#
#   osmo-epc start        mongod, ogstun + NAT, puis les demons dans l ordre
#   osmo-epc stop         arrete les demons (ogstun reste)
#   osmo-epc restart
#   osmo-epc status       un etat par demon, ogstun, SGs
#   osmo-epc subscribers  pose les abonnes du depot (configs/open5gs/
#                         subscribers.json) dans MongoDB s ils n y sont pas
#   osmo-epc log [nom]    le journal d un demon (mme par defaut), en direct
#
# Variables : OPEN5GS_PREFIX, SRS_WAN (interface de sortie du NAT ; par defaut
# celle de la route par defaut), OPEN5GS_UESUBNET, OPEN5GS_TUNADDR.
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
# Le prefixe : la variable, sinon /opt/LTE, sinon l ancien /root.
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
# L interface de sortie du NAT : SRS_WAN, sinon celle de la route par defaut.
# (Elle etait ecrite en dur - enxa0cec8a98b06 - : une autre machine n a pas
# cette carte-la.)
WAN="${SRS_WAN:-$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
# Ordre de demarrage : le NRF (les SBI du SMF le cherchent), le HSS avant le
# MME (Diameter), les plans usager avant les plans controle qui s y rattachent.
DAEMONS="open5gs-nrfd open5gs-hssd open5gs-sgwcd open5gs-sgwud open5gs-smfd open5gs-upfd open5gs-pcrfd open5gs-mmed"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }
_root() { [ "$(id -u)" -eq 0 ] && return 0; _err "il faut root (tun, NAT, mongod) : sudo $0 $*"; return 1; }

[ -x "$BIN/open5gs-mmed" ] || { _err "Open5GS introuvable ($BIN/open5gs-mmed) - « osmo-lte-install --build » ou dpkg -i osmo-build-open5gs"; [ "${1:-}" = status ] || exit 1; }

# [2026-09-08] MONGOD D ABORD. Le HSS et le PCRF lisent les abonnes dans
# MongoDB et MEURENT a l initialisation s il ne tourne pas (« Failed to
# connect to server [mongodb://localhost/open5gs] ») : le MME repond alors
# 3002 sur S6a et rejette tout attach (EMM cause 15). Le service peut etre
# « disabled » : on le lance ici, a chaque fois.
_mongod() {
    systemctl is-active --quiet mongod && return 0
    if systemctl start mongod 2>/dev/null; then
        _ok "mongod demarre"; sleep 2
    else
        _err "mongod ne demarre pas (HSS et PCRF ne tiendront pas) : apt install mongodb-org"
        return 1
    fi
}

# Les abonnes du depot, poses s ils manquent. Le champ slice[].session[].smf
# (127.0.0.200, valeur par defaut du WebUI) est RETIRE : il a priorite sur
# gtpc.client.smf de mme.yaml, le SGW-C envoyait le Create Session vers
# 127.0.0.200, personne ne repondait, GTP Timeout, RRC Release.
epc_subscribers() {
    _root subscribers || return 1
    _mongod || return 1
    local dump="$REPO/configs/open5gs/dump/open5gs" j="$REPO/configs/open5gs/subscribers.json" n
    command -v mongosh >/dev/null 2>&1 || { _warn "mongosh absent : abonnes non poses"; return 0; }
    n="$(mongosh --quiet open5gs --eval 'print(db.subscribers.countDocuments())' 2>/dev/null | tail -1)"
    # Base vide et un mongodump dans le depot (configs/open5gs/dump : abonnes,
    # comptes du WebUI, sessions) : on restaure TOUT, tel quel (BSON : les
    # Long du sqn et les ObjectId restent ce qu ils sont).
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
}

epc_start() {
    _root start || return 1
    _mongod || true
    epc_subscribers >/dev/null 2>&1 || true
    mkdir -p "$LOG"
    setup_tun
    local d
    for d in $DAEMONS; do
        if pgrep -x "$d" >/dev/null; then _ok "$d deja en cours"; continue; fi
        # -D : demon. La config est celle de $ETC (le prefixe), posee depuis
        # le depot par osmo-lte-install.sh.
        if "$BIN/$d" -D -c "$ETC/${d#open5gs-}.yaml" 2>/dev/null; then :; else
            "$BIN/$d" -D >/dev/null 2>&1
        fi && _ok "$d demarre" || _err "ECHEC $d (voir $LOG/${d#open5gs-}.log)"
        sleep 0.5
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
