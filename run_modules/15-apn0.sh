# =============================================================================
#  15-apn0 - interface TUN de l'APN paquet (prerequis du GGSN)
# =============================================================================
#  ROLE      porte le trafic utilisateur GPRS/EDGE : le GGSN y ecrit les
#            paquets decapsules du GTP-U. Reprise de l'etape [1/4] de
#            osmo-start.sh (osmo-start.sh:64-72), isolee ici parce que c'est un
#            prerequis SYSTEME, pas un service - et qu'elle echoue de facon
#            tres reconnaissable dans un conteneur non privilegie.
#  PREREQUIS /dev/net/tun present, commande ip, droits CAP_NET_ADMIN.
#  SUCCES    l'interface existe, elle est UP, et elle porte l'adresse demandee.
#  JOURNAL   $LOGDIR/mod/apn0.log (aucun service, donc aucun journal systemd)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER apn0 "Coeur - interface TUN de l'APN"
MOD_REQUIRED[apn0]=0
MOD_PROFILES[apn0]="calypso faketrx hybrid core"
MOD_TIMEOUT[apn0]=15
MOD_ENABLED_IF[apn0]='[ "${NO_OSMO_START:-0}" != 1 ] && [ "${CORE_GPRS:-1}" = 1 ]'

: "${APN_DEV:=apn0}"
: "${APN_ADDR:=176.16.32.0/24}"

# Critere = le drapeau ADMINISTRATIF "UP" dans <...>, pas "state UP" : une
# interface TUN reste NO-CARRIER / state DOWN tant qu'aucun processus n'a ouvert
# son descripteur - c'est le GGSN qui le fera, apres ce module (constate).
_apn_up()   { ip -o link show "$APN_DEV" 2>/dev/null | grep -qE '<[^>]*(^|<|,)UP(,|>)'; }
_apn_addr() { ip -o -4 addr show dev "$APN_DEV" 2>/dev/null | grep -q "${APN_ADDR%%/*}"; }

mod_apn0_check() {
    command -v ip >/dev/null 2>&1 || { mod_fail "commande ip absente (paquet iproute2)"; return $MOD_RC_FAIL; }
    [ -c /dev/net/tun ] || {
        mod_hint "conteneur sans TUN : ajoutez --device /dev/net/tun et --cap-add NET_ADMIN"
        mod_fail "/dev/net/tun absent - impossible de creer une interface TUN"
        return $MOD_RC_FAIL; }
    mod_ok
}

mod_apn0_status() { _apn_up && _apn_addr; }

mod_apn0_start() {
    ip link show "$APN_DEV" >/dev/null 2>&1 && ip link del dev "$APN_DEV" 2>/dev/null
    ip tuntap add dev "$APN_DEV" mode tun 2>&1 || {
        mod_hint "droits insuffisants : lancez le conteneur avec --cap-add NET_ADMIN"
        mod_fail "creation de $APN_DEV refusee"; return $MOD_RC_FAIL; }
    ip addr add "$APN_ADDR" dev "$APN_DEV" 2>&1
    ip link set dev "$APN_DEV" up 2>&1
    mod_ok
}

# BARRIERE - "ip tuntap add" peut reussir alors que l'adresse n'est pas posee
# (adresse deja prise ailleurs) : on exige l'etat UP ET l'adresse.
mod_apn0_wait() {
    if ! wait_until "${MOD_TIMEOUT[apn0]}" "interface $APN_DEV UP" _apn_up; then
        mod_hint "ip link show $APN_DEV"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "${MOD_TIMEOUT[apn0]}" "adresse $APN_ADDR sur $APN_DEV" _apn_addr; then
        mod_hint "adresse deja portee par une autre interface ? ip -4 addr | grep ${APN_ADDR%%/*}"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_apn0_stop() { ip link del dev "$APN_DEV" 2>/dev/null; return 0; }
