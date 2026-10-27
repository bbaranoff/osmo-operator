#!/bin/bash
# =============================================================================
# osmo-wg.sh - THE WAN WIREGUARD TUNNEL (wiki/WAN.md §3) IN ONE COMMAND.
#
# The addressing plan is fixed (10.99.0.0/24):
#   10.99.0.1   the hub (co-located inter-STP), the only one that LISTENS (udp 51820)
#   10.99.0.N   the other nodes, which call the hub
# One command per node, and one line to copy on the hub per node added.
# The keys are generated HERE, on the machine: never in the ISO (every live
# system would share the same keys).
#
#   wg 1          (= wg 10.99.0.1)       this node becomes the hub
#   wg N HUB_IP[:PORT] HUB_PUB           this node becomes 10.99.0.N (N = 2..254)
#                                        and joins the hub; prints the
#                                        "wg peer ..." line to type on the hub
#   wg peer PUBLIC_KEY N                 (on the hub) accept this node
#   wg up | wg down                      bring the installed tunnel up / down
#   wg status | wg pub                   N or 10.99.0.N, either form anywhere
# "wg" is the function of /etc/profile.d/97-osmo-wg.sh: it routes these forms
# here, everything else (wg show, wg genkey...) goes to the real wg.
# =============================================================================
set -u

IF="${OSMO_WG_IF:-wg0}"
PORT="${OSMO_WG_PORT:-51820}"
NET=10.99.0
HUB="$NET.1"
DIR=/etc/wireguard
CONF="$DIR/$IF.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
_ok()  { echo -e "  ${GREEN}✓${NC} $*"; }
_say() { echo -e "  ${CYAN}→${NC} $*"; }
_err() { echo -e "  ${RED}✗${NC} $*" >&2; }

usage() { sed -n '13,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

case "${1:-}" in ""|-h|--help) usage 0 ;; esac
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 \
    || { _err "wireguard-tools absent : apt install wireguard-tools"; exit 1; }

# _ip_ok 10.99.0.N: N in 1..254
_ip_ok() {
    [[ "$1" =~ ^10\.99\.0\.([0-9]{1,3})$ ]] && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 254 ]
}

_cles() {
    install -d -m700 "$DIR"
    if [ ! -s "$DIR/$IF.priv" ]; then
        (umask 077; wg genkey > "$DIR/$IF.priv")
        _ok "cle privee generee ($DIR/$IF.priv)"
    fi
    wg pubkey < "$DIR/$IF.priv" > "$DIR/$IF.pub"
}

# SCTP (M3UA, SGs) goes through the tunnel: opened to the subnet, no more.
_parefeu() {
    iptables -C INPUT -i "$IF" -s "$NET.0/24" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -i "$IF" -s "$NET.0/24" -j ACCEPT
    if [ "${1:-}" = hub ]; then
        iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow in on "$IF" from "$NET.0/24" >/dev/null
        [ "${1:-}" = hub ] && ufw allow "$PORT/udp" >/dev/null
    fi
}

_monter() {
    systemctl enable "wg-quick@$IF" >/dev/null 2>&1
    systemctl restart "wg-quick@$IF" || { _err "wg-quick@$IF ne demarre pas : journalctl -u wg-quick@$IF"; exit 1; }
    _ok "$IF monte, et a chaque demarrage (wg-quick@$IF)"
}

_ecrire() {  # _ecrire <contenu> : remplace wg0.conf, l ancien garde en .bak
    [ -f "$CONF" ] && cp -a "$CONF" "$CONF.bak" && _say "ancien $CONF garde en $CONF.bak"
    systemctl stop "wg-quick@$IF" 2>/dev/null
    (umask 077; printf '%s\n' "$1" > "$CONF")
}

hub() {
    _cles
    # SaveConfig: the peers added by "wg peer" survive a restart
    _ecrire "[Interface]
Address    = $HUB/24
ListenPort = $PORT
PrivateKey = $(cat "$DIR/$IF.priv")
SaveConfig = true"
    _parefeu hub
    _monter
    echo
    _say "HUB $HUB pret. Sur chaque autre noeud :"
    echo "      wg N <IP publique de cette machine>:$PORT $(cat "$DIR/$IF.pub")      (N = 2..254 : 10.99.0.N)"
}

noeud() {
    local ip="$1" ep="$2" pub="$3"
    [[ "$ep" == *:* ]] || ep="$ep:$PORT"
    [[ "$pub" =~ ^[A-Za-z0-9+/]{42,43}=$ ]] || { _err "cle publique du hub invalide : $pub"; exit 1; }
    _cles
    _ecrire "[Interface]
Address    = $ip/24
PrivateKey = $(cat "$DIR/$IF.priv")

[Peer]
# the hub ($HUB)
PublicKey  = $pub
Endpoint   = $ep
AllowedIPs = $NET.0/24
PersistentKeepalive = 25"
    _parefeu
    _monter
    echo
    _say "NOEUD $ip pret. Sur le hub ($HUB), tapez :"
    echo "      wg peer $(cat "$DIR/$IF.pub") ${ip##*.}"
    _say "puis ici : ping -c3 $HUB"
}

peer() {
    local pub="$1" ip="$2"
    [ -f "$CONF" ] && grep -q "^Address *= *$HUB/" "$CONF" \
        || { _err "ce noeud n est pas le hub ($HUB) : « wg 1 » d abord"; exit 1; }
    wg show "$IF" >/dev/null 2>&1 || _monter
    wg set "$IF" peer "$pub" allowed-ips "$ip/32" || exit 1
    wg-quick save "$IF" >/dev/null 2>&1
    _ok "pair $ip accepte (et enregistre dans $CONF)"
}

# "wg 5" = "wg 10.99.0.5" (and "wg peer KEY 5")
_ip() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && echo "$NET.$1" || echo "$1"; }
case "${1:-}" in
    peer) [ $# -ge 3 ] && set -- "$1" "$2" "$(_ip "$3")" "${@:4}" ;;
    [0-9]*) set -- "$(_ip "$1")" "${@:2}" ;;
esac

case "${1:-}" in
    ""|-h|--help) usage 0 ;;
    up)     [ -f "$CONF" ] || { _err "pas de $CONF : wg 1 (hub) ou wg N ... (noeud)"; exit 1; }
            _monter; wg show "$IF" | sed -n '1,4p' ;;
    status) wg show "$IF" 2>/dev/null || _say "$IF absent" ;;
    down)   systemctl disable --now "wg-quick@$IF" && _ok "$IF arrete (et plus au demarrage)" ;;
    pub)    [ -s "$DIR/$IF.pub" ] && cat "$DIR/$IF.pub" || { _err "pas de cle : wg 1 (hub) ou wg N ... (noeud)"; exit 1; } ;;
    peer)
        [ $# -eq 3 ] && _ip_ok "$3" && [ "$3" != "$HUB" ] || usage
        peer "$2" "$3" ;;
    *)
        _ip_ok "$1" || usage
        if [ "$1" = "$HUB" ]; then
            [ $# -eq 1 ] || usage
            hub
        else
            [ $# -eq 3 ] || { _err "un noeud doit connaitre le hub : wg ${1##*.} HUB_IP[:PORT] CLE_PUBLIQUE_DU_HUB"; exit 1; }
            noeud "$1" "$2" "$3"
        fi ;;
esac
