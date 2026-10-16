#!/bin/bash
# =============================================================================
# network/apn-nat.sh - sortie Internet des telephones (APN internet, apn0)
#
# Le GGSN range les telephones dans 176.16.32.0/24 sur l'interface apn0. Sans
# NAT ni forward, leurs paquets (DNS compris) partent dans le vide : la policy
# FORWARD de l'hote est en DROP. Ce script pose, de facon idempotente :
#   - MASQUERADE 176.16.32.0/24 vers l'interface de sortie (carte qui route vers
#     Internet, detectee par la route par defaut) ;
#   - FORWARD apn0 <-> sortie, et le retour des connexions etablies.
#
#   network/apn-nat.sh          applique
#   network/apn-nat.sh --status etat, sans rien changer
# =============================================================================
set -u

SUBNET="${APN_SUBNET:-176.16.32.0/24}"
APN_IF="${APN_IF:-apn0}"
MODE=apply
[ "${1:-}" = "--status" ] && MODE=status

OUT_IF="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
if [ -z "$OUT_IF" ]; then
    echo "apn-nat : pas de route vers Internet - rien a faire"; exit 1
fi

ok() { printf '  %-58s %s\n' "$1" "$2"; }

check_or_add() {   # $1 = table (nat|filter), $2 = chaine, reste = regle
    local table="$1" chain="$2"; shift 2
    if iptables -w -t "$table" -C "$chain" "$@" 2>/dev/null; then
        ok "$table $chain $*" "deja present"
    elif [ "$MODE" = status ]; then
        ok "$table $chain $*" "ABSENT"
    else
        if iptables -w -t "$table" -I "$chain" "$@" 2>/dev/null; then
            ok "$table $chain $*" "ajoute"
        else
            ok "$table $chain $*" "ECHEC"; return 1
        fi
    fi
}

echo "apn-nat : $SUBNET via $APN_IF -> $OUT_IF"
rc=0
# [2026-10-16] sans forward, MASQUERADE et FORWARD ne servent a rien (repris du bloc
# « NAT du pool GGSN » de start-direct.sh, retire au profit de ce script).
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then ok "net.ipv4.ip_forward" "deja 1"
elif [ "$MODE" = status ]; then ok "net.ipv4.ip_forward" "0 (ABSENT)"
elif sysctl -qw net.ipv4.ip_forward=1 2>/dev/null; then ok "net.ipv4.ip_forward" "mis a 1"
else ok "net.ipv4.ip_forward" "ECHEC"; rc=1; fi
check_or_add nat POSTROUTING -s "$SUBNET" -o "$OUT_IF" -j MASQUERADE || rc=1
check_or_add filter FORWARD -i "$APN_IF" -o "$OUT_IF" -j ACCEPT || rc=1
check_or_add filter FORWARD -i "$OUT_IF" -o "$APN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT || rc=1
exit $rc
