# =============================================================================
#  12-netns - topologie multi-operateur (netns + dorsale IP)
# =============================================================================
#
#  ROLE
#      Construire l'isolation reseau du mode multi-operateur : un espace de noms
#      par operateur (osmo-op<i>), relie a un pont commun (gsm-inter) par une
#      paire veth, chaque operateur portant une adresse sur la dorsale. C'est ce
#      qui permet a N coeurs identiques (memes ports VTY, memes IP privees) de
#      coexister et de se parler en SS7 via le STP d'interconnexion.
#
#      NE S'ACTIVE QUE SI N_OPERATORS > 1. En mono-operateur il n'y a rien a
#      isoler, et le module s'efface du plan (MOD_ENABLED_IF).
#
#      LIMITE CONNUE, SIGNALEE ET NON CONTOURNEE : dans un conteneur, /run/netns
#      n'est pas partageable meme avec CAP_SYS_ADMIN. Le module rend alors SKIP
#      avec la marche a suivre (lancer sur l'hote), au lieu d'echouer vingt
#      lignes plus loin sur une erreur d'`ip netns add` incomprehensible.
#      Ce que ce module N'ISOLE PAS : /tmp (sockets Unix) et $HOME/.osmocom -
#      partages entre operateurs. Les modules qui posent des sockets dans /tmp
#      doivent donc les prefixer eux-memes ; ce n'est pas du ressort du reseau.
#
#  PREREQUIS
#      reseau ; droits root ; commande `ip` avec le sous-systeme netns.
#
#  CRITERE DE SUCCES
#      BARRIERE - pour CHAQUE operateur : l'espace de noms existe, son interface
#      porte l'adresse de dorsale attendue, et une route vers la passerelle du
#      pont s'y resout (`ip netns exec ... ip route get`). Le pont lui-meme est UP
#      et porte son adresse. Sonde, avec plafond ; l'ancien code se contentait de
#      creer les liens sans jamais verifier qu'un paquet pouvait sortir.
#
#  JOURNAL
#      $LOG_DIR/mod/netns.log : plan d'adressage applique, operateur par operateur.
# -----------------------------------------------------------------------------
MOD_REGISTER netns "Topologie multi-operateur (netns)"
MOD_REQUIRED[netns]=1
MOD_DEPS[netns]="reseau"
MOD_PROFILES[netns]="calypso faketrx hybrid core"
MOD_TIMEOUT[netns]=30
MOD_ENABLED_IF[netns]='[ "${N_OPERATORS:-1}" -gt 1 ]'

# Plan d'adressage. Repris tel quel de l'ancien start-direct.sh pour que les
# gabarits de configuration existants restent valables.
: "${N_OPERATORS:=1}"
: "${BRIDGE:=gsm-inter}"
: "${BACKBONE_NET:=172.20.0}"          # dorsale : <net>.1 = pont, <net>.1<i> = operateur i
: "${NETNS_PREFIX:=osmo-op}"

_ns_nom()   { printf '%s%s' "$NETNS_PREFIX" "$1"; }
_ns_veth()  { printf 'vop%s' "$1"; }
_ns_peer()  { printf 'vop%sp' "$1"; }
_ns_ip()    { printf '%s.%s' "$BACKBONE_NET" "$(( 10 + $1 ))"; }
_ns_gw()    { printf '%s.1' "$BACKBONE_NET"; }

_ns_existe() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$(_ns_nom "$1")"; }

_ns_en_conteneur() {
    [ -f /.dockerenv ] && return 0
    grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null
}

mod_netns_check() {
    if _ns_en_conteneur; then
        mod_hint "lancez le multi-operateur depuis l'hote :  sudo N_OPERATORS=${N_OPERATORS} ./launch/start-oqc.sh"
        mod_skip "espaces de noms reseau indisponibles en conteneur (/run/netns non partageable)"
        return $MOD_RC_SKIP
    fi
    if [ "$(id -u)" != 0 ]; then
        mod_hint "relancez en root : la creation d'un netns et d'un pont exige CAP_NET_ADMIN"
        mod_fail "droits insuffisants pour creer les espaces de noms"
        return $MOD_RC_FAIL
    fi
    ip netns list >/dev/null 2>&1 || {
        mod_hint "apt-get install -y iproute2 ; verifiez que /var/run/netns est accessible"
        mod_fail ""ip netns" indisponible sur cette machine"
        return $MOD_RC_FAIL; }
    mod_ok
}

mod_netns_status() {
    local i
    ip link show "$BRIDGE" >/dev/null 2>&1 || return $MOD_RC_FAIL
    for i in $(seq 1 "$N_OPERATORS"); do
        _ns_existe "$i" || return $MOD_RC_FAIL
    done
    return $MOD_RC_OK
}

mod_netns_start() {
    local i ns veth peer ip4 gw
    gw="$(_ns_gw)"

    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        ip link add "$BRIDGE" type bridge 2>/dev/null || {
            mod_hint "le module "bridge" du noyau est-il charge ?  modprobe bridge"
            mod_fail "creation du pont $BRIDGE impossible"
            return $MOD_RC_FAIL; }
        mod_say "pont cree : $BRIDGE"
    fi
    ip addr replace "${gw}/24" dev "$BRIDGE" 2>/dev/null
    ip link set "$BRIDGE" up 2>/dev/null || {
        mod_fail "le pont $BRIDGE refuse de passer UP"
        return $MOD_RC_FAIL; }

    for i in $(seq 1 "$N_OPERATORS"); do
        ns="$(_ns_nom "$i")"; veth="$(_ns_veth "$i")"; peer="$(_ns_peer "$i")"; ip4="$(_ns_ip "$i")"

        _ns_existe "$i" || ip netns add "$ns" 2>/dev/null || {
            mod_hint "un reste du run precedent ?  ip netns list ; ip netns del $ns"
            mod_fail "creation de l'espace de noms $ns impossible"
            return $MOD_RC_FAIL; }

        if ! ip link show "$veth" >/dev/null 2>&1 && ! ip netns exec "$ns" ip link show "$peer" >/dev/null 2>&1; then
            ip link add "$veth" type veth peer name "$peer" 2>/dev/null || {
                mod_fail "creation de la paire veth $veth/$peer impossible"
                return $MOD_RC_FAIL; }
        fi

        ip link set "$veth" master "$BRIDGE" 2>/dev/null
        ip link set "$veth" up 2>/dev/null
        ip link show "$peer" >/dev/null 2>&1 && ip link set "$peer" netns "$ns" 2>/dev/null

        ip netns exec "$ns" ip link set lo up 2>/dev/null
        ip netns exec "$ns" ip addr replace "${ip4}/24" dev "$peer" 2>/dev/null
        ip netns exec "$ns" ip link set "$peer" up 2>/dev/null
        ip netns exec "$ns" ip route replace default via "$gw" 2>/dev/null

        mod_say "operateur $i : $ns  $veth<->$peer  $ip4/24  passerelle $gw"
    done
    mod_ok
}

_ns_pont_pret() {
    ip link show "$BRIDGE" 2>/dev/null | grep -q 'state UP\|state UNKNOWN' &&
    ip -o -4 addr show dev "$BRIDGE" 2>/dev/null | grep -q "$(_ns_gw)/24"
}

_ns_op_pret() {   # $1 = index operateur
    local i="$1" ns peer ip4
    ns="$(_ns_nom "$i")"; peer="$(_ns_peer "$i")"; ip4="$(_ns_ip "$i")"
    ip netns exec "$ns" ip -o -4 addr show dev "$peer" 2>/dev/null | grep -q "${ip4}/24" || return 1
    ip netns exec "$ns" ip route get "$(_ns_gw)" >/dev/null 2>&1
}

mod_netns_wait() {
    local t="${MOD_TIMEOUT[netns]}" i

    wait_until "$t" "pont $BRIDGE" _ns_pont_pret || {
        mod_hint "ip -d link show $BRIDGE ; ip -4 addr show $BRIDGE"
        mod_fail "le pont $BRIDGE n'est pas actif ou n'a pas son adresse $(_ns_gw)/24"
        return $MOD_RC_FAIL; }

    for i in $(seq 1 "$N_OPERATORS"); do
        wait_until "$t" "operateur $i" _ns_op_pret "$i" || {
            mod_hint "ip netns exec $(_ns_nom "$i") ip -4 addr show ; ip netns exec $(_ns_nom "$i") ip route"
            mod_fail "operateur $i : $(_ns_nom "$i") sans adresse $(_ns_ip "$i")/24 ou sans route vers $(_ns_gw)"
            return $MOD_RC_FAIL; }
    done
    mod_say "$N_OPERATORS operateurs joignables sur la dorsale ${BACKBONE_NET}.0/24"
    mod_ok
}

# Demontage cible : uniquement ce que ce module a cree. Les processus encore
# dans un espace de noms l'empechent d'etre detruit - on les termine, eux et eux
# seuls (c'est une liste exacte, pas un motif de ligne de commande).
mod_netns_stop() {
    local i ns pids retires=0
    for i in $(seq 1 "${N_OPERATORS:-1}"); do
        _ns_existe "$i" || continue
        ns="$(_ns_nom "$i")"
        pids="$(ip netns pids "$ns" 2>/dev/null | tr '\n' ' ')"
        [ -n "${pids// /}" ] && kill $pids 2>/dev/null
        ip netns del "$ns" 2>/dev/null
        ip link del "$(_ns_veth "$i")" 2>/dev/null
        retires=$(( retires + 1 ))
    done
    # Le pont ne part QUE si l'on vient d'en retirer un operateur : un run
    # mono-operateur, ou une autre pile, peut legitimement porter le meme pont.
    # Detruire ce qu'on n'a pas cree est le defaut qu'on cherche a ne pas repeter.
    if [ "$retires" -gt 0 ] && ip link show "$BRIDGE" >/dev/null 2>&1; then
        ip link del "$BRIDGE" 2>/dev/null
    fi
    return 0
}
