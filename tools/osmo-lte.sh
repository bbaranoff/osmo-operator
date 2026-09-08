#!/bin/bash
# =============================================================================
# osmo-lte.sh - LA 4G DU BANC : srsEPC, srsENB et srsUE sur la radio ZeroMQ,
# lances DANS L ORDRE ET DANS LES TEMPS.
#
# [2026-09-07] POURQUOI UN LANCEUR, alors que trois lignes de commande
# suffisent. Parce que les trois lignes ont deux pieges, et qu on est tombe
# dans les deux le meme jour :
#
#   1. « fail_on_disconnect=true » sur l eNB. C est l argument de la doc, et il
#      fait ce qu il dit : quand l eNB ne recoit AUCUN echantillon de l UE
#      pendant 2000 ms (ZMQ_TIMEOUT_MS, rf_zmq_imp_trx.h), sa radio S ARRETE.
#      Le processus reste, le S1 vers l EPC reste, mais plus rien ne sort sur
#      ZeroMQ - on l a mesure : une centaine d octets par sens, la poignee de
#      main ZMTP et rien d autre. Un srsUE lance UNE MINUTE apres l eNB trouve
#      donc une radio morte : « Attaching UE... » et jamais « Found Cell ».
#      Ici l UE part une demi-seconde apres l eNB.
#
#   2. Le SIB3. sib.conf programme les SIB emis par « si_mapping_info » ; en
#      y mettant [ 7 ] (le SIB7, la liste GERAN du CSFB) A LA PLACE de [ 3 ],
#      on a retire le SIB3. Or srsUE ne juge une cellule « convenable » QUE
#      s il a le SIB3 (srsue rrc.cc, cell_selection_criteria : has_sib3()) :
#      « Failed to configure serving cell », T3410 expire, cinq essais, rien.
#      Il faut [ 3, 7 ] - on le verifie avant de lancer.
#
# La 2G du banc n est pas touchee : ce lanceur ne connait que les trois srs*.
# Les fichiers de configuration sont ceux de srsRAN (~/.config/srsran de root,
# ou OSMO_SRSRAN_DIR) ; on ne les recopie pas, on les lit.
#
#   osmo-lte start      EPC, puis eNB, puis UE (refuse si l un tourne deja)
#   osmo-lte stop       arrete les trois (y compris ceux lances a la main)
#   osmo-lte restart    stop puis start
#   osmo-lte status     processus, S1, debit ZeroMQ, adresse de l UE
#   osmo-lte log        les trois journaux, en direct
# =============================================================================
set -u

SRS_DIR="${OSMO_SRSRAN_DIR:-/root/.config/srsran}"
NETNS="${OSMO_LTE_NETNS:-ue1}"
ZMQ_ENB="${OSMO_ZMQ_PORT:-2000}"
ZMQ_UE="${OSMO_ZMQ_PORT_UE:-2001}"
SRATE="${OSMO_LTE_SRATE:-23.04e6}"
LOGDIR="${OSMO_LTE_LOGDIR:-/tmp}"
BUILD="${OSMO_SRSRAN_BUILD:-/opt/LTE/srsRAN_4G/build}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

_root() { [ "$(id -u)" -eq 0 ] && return 0; _err "il faut root (netns, tun, SCTP) : sudo $0 $*"; return 1; }

# Le binaire installe d abord, la compilation locale sinon.
_bin() {
    local n="$1"
    command -v "$n" 2>/dev/null && return 0
    for f in "$BUILD/srs$n/src/$n" "$BUILD/$n/src/$n"; do [ -x "$f" ] && { echo "$f"; return 0; }; done
    return 1
}

# Le SIB3 doit etre programme (piege n° 2 de l entete).
_verifier_sib() {
    local sib="$SRS_DIR/sib.conf"
    [ -f "$sib" ] || { _warn "pas de $sib : srsENB prendra ses valeurs par defaut"; return 0; }
    local map
    map="$(grep -oE 'si_mapping_info\s*=\s*\[[^]]*\]' "$sib" | head -1)"
    if [ -n "$map" ] && ! printf '%s' "$map" | grep -qE '\[\s*(3|[0-9]+\s*,\s*)*3(\s*,|\s*\])'; then
        _err "sib.conf : « $map » ne programme pas le SIB3 - srsUE ne s attachera jamais (il faut [ 3, 7 ])"
        return 1
    fi
    _ok "sib.conf : $map"
}

lte_tourne() { pgrep -x "$1" >/dev/null 2>&1; }

lte_start() {
    _root start || return 1
    local epc enb ue
    epc="$(_bin srsepc)" || { _err "srsepc introuvable"; return 1; }
    enb="$(_bin srsenb)" || { _err "srsenb introuvable"; return 1; }
    ue="$(_bin srsue)"   || { _err "srsue introuvable"; return 1; }
    for p in srsepc srsenb srsue; do
        lte_tourne "$p" && { _err "$p tourne deja (pid $(pgrep -x "$p" | head -1)) - « $0 restart » pour repartir propre"; return 1; }
    done
    _verifier_sib || return 1
    ip netns list 2>/dev/null | grep -qw "$NETNS" || { ip netns add "$NETNS" && _ok "espace reseau $NETNS cree"; }
    export HOME=/root                      # srs* lisent ~/.config/srsran : celui de root
    cd "$BUILD" 2>/dev/null || cd /        # .ctxt (le contexte NAS sauve) vit dans le cwd
    rm -f .ctxt                            # un vieux contexte fait echouer l attach apres un redemarrage d EPC

    setsid "$epc" --log.filename="$LOGDIR/osmo-lte-epc.log" >"$LOGDIR/osmo-lte-epc.console" 2>&1 </dev/null &
    for _ in $(seq 1 20); do ss -Sln 2>/dev/null | grep -q ":36412 " && break; sleep 0.25; done
    ss -Sln 2>/dev/null | grep -q ":36412 " && _ok "srsEPC : S1 en ecoute" || _warn "srsEPC : le S1 n ecoute pas encore"

    # L eNB, et l UE tout de suite derriere : voir le piege n° 1.
    setsid "$enb" --rf.device_name=zmq \
        --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:$ZMQ_ENB,rx_port=tcp://localhost:$ZMQ_UE,id=enb,base_srate=$SRATE" \
        --log.filename="$LOGDIR/osmo-lte-enb.log" >"$LOGDIR/osmo-lte-enb.console" 2>&1 </dev/null &
    sleep 0.5
    setsid "$ue" --rf.device_name=zmq \
        --rf.device_args="tx_port=tcp://*:$ZMQ_UE,rx_port=tcp://localhost:$ZMQ_ENB,id=ue,base_srate=$SRATE" \
        --gw.netns="$NETNS" --log.filename="$LOGDIR/osmo-lte-ue.log" >"$LOGDIR/osmo-lte-ue.console" 2>&1 </dev/null &
    _ok "srsENB puis srsUE lances (ZeroMQ $ZMQ_ENB/$ZMQ_UE, UE dans $NETNS)"

    _say "attente de l attach (30 s max)..."
    local i ip
    for i in $(seq 1 60); do
        ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
        [ -n "$ip" ] && break
        sleep 0.5
    done
    if [ -n "$ip" ]; then
        _ok "UE attache : $ip (tun_srsue dans $NETNS) en $((i / 2)) s"
    else
        _err "pas d attach en 30 s - voir $LOGDIR/osmo-lte-ue.console et « $0 status »"
        grep -E "Found|Attach|fail" "$LOGDIR/osmo-lte-ue.console" | tail -4 | sed 's/^/      /'
        return 1
    fi
}

lte_stop() {
    _root stop || return 1
    local p n=0
    for p in srsue srsenb srsepc; do
        if lte_tourne "$p"; then pkill -x "$p"; n=$((n + 1)); fi
    done
    sleep 2
    for p in srsue srsenb srsepc; do lte_tourne "$p" && pkill -9 -x "$p"; done
    [ "$n" -gt 0 ] && _ok "$n processus srs* arrete(s)" || _say "rien ne tournait"
    # Le S1 met un instant a se refermer cote SCTP ; l EPC suivant en a besoin.
    sleep 1
}

lte_status() {
    echo -e "\033[1msrsRAN sur ZeroMQ - la 4G du banc\033[0m"
    local p
    for p in srsepc srsenb srsue; do
        lte_tourne "$p" && _ok "$p : pid $(pgrep -x "$p" | head -1)" || _warn "$p : arrete"
    done
    ss -San 2>/dev/null | grep -q "ESTAB.*:36412" && _ok "S1 : eNB associe a l EPC" || _warn "S1 : pas d association eNB-EPC"
    # Les echantillons eNB -> UE partent de la douille locale :$ZMQ_ENB de
    # l eNB (bytes_sent) ; ce qu elle RECOIT n est que les requetes de l UE.
    local a b
    a="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
    if [ -n "$a" ]; then
        sleep 1
        b="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
        local ko=$(( (${b:-0} - a) / 1024 ))
        if [ "$ko" -gt 100 ]; then _ok "ZeroMQ : $ko Ko/s d echantillons eNB -> UE"
        else _warn "ZeroMQ : $ko Ko/s - la radio de l eNB est morte (fail_on_disconnect) : « $0 restart »"; fi
    else
        _warn "ZeroMQ : aucun lien eNB <-> UE"
    fi
    local ip
    ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
    [ -n "$ip" ] && _ok "UE : attache, $ip dans $NETNS" || _warn "UE : pas attache (pas de tun_srsue dans $NETNS)"
}

case "${1:-status}" in
    start)   lte_start ;;
    stop)    lte_stop ;;
    restart) lte_stop; lte_start ;;
    status)  lte_status ;;
    log)     exec tail -F "$LOGDIR"/osmo-lte-{epc,enb,ue}.console ;;
    *)       sed -n '/^#   osmo-lte start/,/^#   osmo-lte log/p' "$0" | sed 's/^# \{0,2\}//'; exit 2 ;;
esac
