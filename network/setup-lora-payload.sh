#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-lora-payload.sh — "aiguilleur" payload LoRa / signalisation IP
#
# Sépare les plans du lien inter-nœuds :
#   • SIGNALISATION  (SS7 M3UA/SCTP 2905, SIP 5080+)  -> wg0  (pair 10.99.0.2)
#   • PAYLOAD APPEL  (RTP média, UDP 20000-20999)     -> tnc0 (pair 10.200.0.2, LoRa)
#   • PAYLOAD SMS    (relais SMS, TCP 7890)           -> tnc0 (pair 10.200.0.2, LoRa)
#   • DATA MS        (pool APN 176.16.32.0/24)        -> tnc0  [optionnel, LORA_MS=1]
#
# Les applis continuent de viser le pair wg0 (10.99.0.2) : l'aiguilleur marque les
# flux "payload" (iptables mangle, fwmark 0x10), les bascule dans une table de
# routage dédiée (default via le pair LoRa, dev tnc0) et DNAT la destination vers
# le pair LoRa — aucune config applicative à changer. Le nœud d'en face lance le
# même script (miroir) pour accepter le payload arrivant par tnc0.
#
#   sudo ./network/setup-lora-payload.sh            # up (pose l'aiguilleur)
#   sudo ./network/setup-lora-payload.sh --status   # état + compteurs
#   sudo ./network/setup-lora-payload.sh --off      # dépose tout (nettoie toutes les règles osmo-lora)
#
# Variables (surchargables) :
#   WAN_PEER=10.99.0.2    pair signalisation (wg0)
#   LORA_PEER=10.200.0.2  pair payload (tnc0)
#   LORA_DEV=tnc0         interface radio
#   N_OPS=2               nb d'opérateurs (fixe la plage RTP)
#   LORA_MS=0             1 = router aussi la data MS (176.16.32.0/24) sur LoRa
#
# ⚠ Débit LoRa : quelques kbit/s, MTU 500. Le relais SMS passe sans souci ; la
#   data MS aussi (lente). La voix RTP ne passe en temps réel qu'avec un codec
#   très bas débit — à utiliser pour valider le CHEMIN, pas une HD voice.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

# Pairs mémorisés à la pose : --off / --status retrouvent les mêmes (nœud 1 ou 2)
STATE=/run/osmo-lora-aiguilleur.env
if [ -z "${WAN_PEER:-}${LORA_PEER:-}" ] && [ -r "$STATE" ]; then
    . "$STATE"
fi

WAN_PEER="${WAN_PEER:-10.99.0.2}"
LORA_PEER="${LORA_PEER:-10.200.0.2}"
LORA_DEV="${LORA_DEV:-tnc0}"
N_OPS="${N_OPS:-2}"
LORA_MS="${LORA_MS:-0}"
MS_POOL="${MS_POOL:-176.16.32.0/24}"

# Doit coller à network/firewall-wan.sh / setup-wan-interop.sh
RTP_WAN_BASE="${RTP_WAN_BASE:-20000}"
RTP_PER_OP="${RTP_PER_OP:-500}"
SMS_RELAY_PORT="${SMS_RELAY_PORT:-7890}"
RTP_START=$RTP_WAN_BASE
RTP_END=$(( RTP_WAN_BASE + N_OPS * RTP_PER_OP - 1 ))

TABLE=200                 # table de routage dédiée LoRa
TABLE_NAME=lora
MARK=0x10                 # fwmark "payload LoRa"
RULE_PREF=10000
CHAIN=LORA_AIGUILLEUR

C_G='\033[0;32m'; C_C='\033[0;36m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_0='\033[0m'
msg(){ echo -e "$@"; }

need_root(){ [ "$(id -u)" = 0 ] || { msg "${C_R}À lancer en root (sudo).${C_0}"; exit 1; }; }

ensure_table_name(){
    # alias lisible dans ip route, best-effort
    local rt=/etc/iproute2/rt_tables
    [ -w "$rt" ] || return 0
    grep -qE "^[[:space:]]*$TABLE[[:space:]]+$TABLE_NAME$" "$rt" 2>/dev/null && return 0
    grep -qE "^[[:space:]]*$TABLE[[:space:]]" "$rt" 2>/dev/null && return 0
    echo "$TABLE	$TABLE_NAME" >> "$rt"
}

# ── classes de payload : mêmes règles pour les deux sens (ici= sortant) ──────
#   $1 = "-A" (les règles vivent dans $CHAIN, supprimée en bloc au nettoyage)
mark_rules(){
    local op="$1"
    # RTP (payload appel) vers le pair
    iptables -t mangle "$op" "$CHAIN" -p udp -d "$WAN_PEER" \
        --dport "${RTP_START}:${RTP_END}" -j MARK --set-mark "$MARK"
    # Relais SMS (payload SMS) vers le pair
    iptables -t mangle "$op" "$CHAIN" -p tcp -d "$WAN_PEER" \
        --dport "$SMS_RELAY_PORT" -j MARK --set-mark "$MARK"
    # Data MS (optionnel) : tout ce qui sort du pool APN
    if [ "$LORA_MS" = 1 ]; then
        iptables -t mangle "$op" "$CHAIN" -s "$MS_POOL" -j MARK --set-mark "$MARK"
    fi
}

# Toutes nos règles iptables portent ce commentaire : le nettoyage les retrouve
# quels que soient les pairs utilisés à la pose (nœud 1 ou 2, ancien état perdu).
TAG=osmo-lora
C=(-m comment --comment "$TAG")

# Supprime toutes les règles étiquetées $TAG (filter, nat, mangle) + la chaîne de
# marquage, la règle fwmark et la table LoRa. Ne touche à rien d'autre.
clean(){
    local t line
    for t in filter nat mangle; do
        iptables -t "$t" -S 2>/dev/null | grep -F -- "--comment $TAG" | sed 's/^-A /-D /' |
        while read -r line; do
            eval "iptables -t $t $line" 2>/dev/null || true
        done
    done
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN" 2>/dev/null || true
    while ip rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null; do :; done
    ip route flush table "$TABLE" 2>/dev/null || true
    ip route flush cache
}

up(){
    need_root
    ensure_table_name

    msg "${C_G}=== Aiguilleur LoRa : payload -> ${LORA_PEER} (${LORA_DEV}), reste -> ${WAN_PEER} (wg0) ===${C_0}"
    msg "  RTP ${RTP_START}-${RTP_END}/udp + SMS ${SMS_RELAY_PORT}/tcp$( [ "$LORA_MS" = 1 ] && echo " + data MS ${MS_POOL}") sur LoRa"

    # 0) repart d'une page blanche : pas d'empilement si on re-pose avec d'autres pairs
    clean

    # 1) routing policy : table dédiée -> défaut par le pair LoRa
    ip route replace default via "$LORA_PEER" dev "$LORA_DEV" table "$TABLE"
    ip rule add fwmark "$MARK" lookup "$TABLE" priority "$RULE_PREF"

    # 2) rp_filter laxiste : chemin asymétrique (aller LoRa / retour LoRa) toléré
    sysctl -q -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
    sysctl -q -w "net.ipv4.conf.${LORA_DEV}.rp_filter=2" 2>/dev/null || true

    # 3) mangle : chaîne de marquage (le mark suit toute la connexion, retour inclus)
    iptables -t mangle -N "$CHAIN"
    iptables -t mangle -A "$CHAIN" -j CONNMARK --restore-mark
    iptables -t mangle -A "$CHAIN" -m mark --mark "$MARK" -j RETURN
    mark_rules "-A"
    iptables -t mangle -A "$CHAIN" -m mark --mark "$MARK" -j CONNMARK --save-mark

    # accroche : OUTPUT (payload généré par l'hôte) + PREROUTING (payload forwardé : data MS, containers)
    iptables -t mangle -I OUTPUT     "${C[@]}" -j "$CHAIN"
    iptables -t mangle -I PREROUTING "${C[@]}" -j "$CHAIN"

    # 4) nat : la destination applicative est le pair wg0 -> on la réécrit vers le
    #    pair LoRa pour qu'elle soit routable sur tnc0, et on masque en sortie tnc0.
    iptables -t nat -A OUTPUT      "${C[@]}" -m mark --mark "$MARK" -d "$WAN_PEER" -j DNAT --to-destination "$LORA_PEER"
    iptables -t nat -A PREROUTING  "${C[@]}" -m mark --mark "$MARK" -d "$WAN_PEER" -j DNAT --to-destination "$LORA_PEER"
    iptables -t nat -A POSTROUTING "${C[@]}" -o "$LORA_DEV" -d "$LORA_PEER" -j MASQUERADE

    # 5) entrant : accepte le payload arrivant par LoRa (miroir du nœud d'en face)
    iptables -I INPUT "${C[@]}" -i "$LORA_DEV" -p udp --dport "${RTP_START}:${RTP_END}" -j ACCEPT
    iptables -I INPUT "${C[@]}" -i "$LORA_DEV" -p tcp --dport "$SMS_RELAY_PORT" -j ACCEPT

    ip route flush cache
    printf 'WAN_PEER=%s\nLORA_PEER=%s\nLORA_DEV=%s\nN_OPS=%s\nLORA_MS=%s\n' \
        "$WAN_PEER" "$LORA_PEER" "$LORA_DEV" "$N_OPS" "$LORA_MS" > "$STATE"
    msg "${C_G}✓ Aiguilleur posé.${C_0}  (état : $0 --status ; dépose : $0 --off)"
}

off(){
    need_root
    msg "${C_Y}=== Dépose de l'aiguilleur LoRa ===${C_0}"
    clean
    rm -f "$STATE"
    msg "${C_G}✓ Tout est revenu sur wg0.${C_0}"
}

status(){
    msg "${C_C}── Table de routage ${TABLE} (${TABLE_NAME}) ──${C_0}"; ip route show table "$TABLE" 2>/dev/null || echo "(vide)"
    msg "${C_C}── Règle fwmark ──${C_0}"; ip rule show | grep -E "fwmark|$TABLE" || echo "(aucune)"
    msg "${C_C}── Marquage mangle (${CHAIN}) ──${C_0}"; iptables -t mangle -L "$CHAIN" -n -v 2>/dev/null || echo "(chaîne absente)"
    msg "${C_C}── Règles iptables ${TAG} ──${C_0}"; for t in filter nat mangle; do iptables -t "$t" -S 2>/dev/null | grep -F -- "--comment $TAG" | sed "s/^/  [$t] /"; done
    msg "${C_C}── Pair LoRa ──${C_0}"; ip route get "$LORA_PEER" 2>/dev/null
}

case "${1:-up}" in
    up|"")        up ;;
    off|--off|down) off ;;
    status|--status) status ;;
    *) msg "Usage: $0 [up|--off|--status]"; exit 2 ;;
esac
