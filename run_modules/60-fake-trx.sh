# =============================================================================
#  60-fake-trx - transceiver simule (osmocom-bb / trx_toolkit / fake_trx.py)
# =============================================================================
#
#  ROLE
#    Remplace modem + RF par un commutateur de bursts en UDP. Il relie les deux
#    cotes de la liaison, chacun sur son "base port" (+1 CTRL, +2 DATA) :
#
#        osmo-bts-trx  <--TRXD $TRX_BASE_PORT-->  fake_trx  <--TRXD $BB_BASE_PORT-->  trxcon
#
#    C'est le PHY du profil "faketrx". En PHY_MODE=virtphy il n'existe pas :
#    la chaine passe par le multicast d'osmo-bts-virtual.
#
#  PREREQUIS
#    python3 et $FAKETRX_PY (par defaut osmocom-bb/src/target/trx_toolkit).
#    Les deux plages de ports UDP libres.
#
#  CRITERE DE SUCCES (barriere)
#    Le processus vit ET a ouvert un socket UDP de CHAQUE cote. Le PID seul ne
#    prouve rien : un python qui echoue au bind meurt une seconde plus tard, et
#    le BTS resterait indefiniment en "No clock since TRX" sans qu'on sache
#    pourquoi.
#
#  JOURNAL     $LOG_DIR/fake-trx.log
#
#  ORDRE
#    AVANT osmo-bts-trx et trxcon - tous deux se connectent a lui. L'ancien
#    lancement demarrait le BTS d'abord en comptant sur ses tentatives repetees ;
#    ca marche, mais alors la barriere du BTS ne peut plus rien affirmer.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER fake-trx "Transceiver simule (fake_trx)"
MOD_REQUIRED[fake-trx]=1
MOD_PROFILES[fake-trx]="faketrx"
MOD_ENABLED_IF[fake-trx]='[ "${PHY_MODE:-faketrx}" != "virtphy" ] && [ "${RADIO_TRANSCEIVER:-fake}" != "osmo-trx" ]'
MOD_TIMEOUT[fake-trx]=30

: "${FAKETRX_PY:=${OSMOCOM_BB:-${GSM_ROOT}/osmocom-bb}/src/target/trx_toolkit/fake_trx.py}"
: "${FAKETRX_PYTHON:=python3}"
MOD_LOG[fake-trx]="${LOG_DIR}/fake-trx.log"

mod_fake_trx_check() {
    command -v "$FAKETRX_PYTHON" >/dev/null 2>&1 || {
        mod_fail "interpreteur introuvable : $FAKETRX_PYTHON"
        mod_hint "posez FAKETRX_PYTHON=/chemin/vers/python3"
        return $MOD_RC_FAIL; }
    [ -r "$FAKETRX_PY" ] || {
        mod_fail "fake_trx.py introuvable : $FAKETRX_PY"
        mod_hint "reglez OSMOCOM_BB dans environment/paths.env, ou FAKETRX_PY directement"
        return $MOD_RC_FAIL; }

    # Un port tenu par quelqu'un d'autre : le dire MAINTENANT, pas dans trente
    # secondes sous la forme d'un BTS sans horloge.
    local p
    for p in "$TRX_BASE_PORT" "$BB_BASE_PORT"; do
        if radio_foreign_holder "$p" "fake_trx.py"; then
            mod_fail "port UDP $p deja tenu par un autre transceiver"
            mod_hint "ss -uanp | grep :$p - puis arretez-le, ou decalez TRX_BASE_PORT/BB_BASE_PORT"
            return $MOD_RC_FAIL
        fi
    done
    mod_ok
}

mod_fake_trx_status() { have_proc "fake_trx.py"; }

mod_fake_trx_start() {
    radio_dirs
    local log; log="$(radio_log fake-trx)"
    local cmd=("$FAKETRX_PYTHON" "$FAKETRX_PY"
               -b "$TRX_BIND_IP" -R "$TRX_BTS_IP" -r "$TRX_BB_IP"
               -P "$TRX_BASE_PORT" -p "$BB_BASE_PORT")

    # Mobiles supplementaires : un transceiver de plus par MS, groupes par huit
    # sur des IP de bouclage distinctes (convention du lancement historique).
    local ms g
    for ((ms=2; ms<=N_MS; ms++)); do
        g=$(( (ms-1)/8 + 1 ))
        cmd+=( --trx "ue${ms}@127.0.0.${g}:$(radio_bb_port "$ms")" )
    done

    mod_say "commande : ${cmd[*]}"
    mod_say "journal  : $log"
    "${cmd[@]}" >>"$log" 2>&1 &
    radio_save_pid fake-trx $!
    mod_ok
}

# BARRIERE - "lance" n'est pas "ecoute".
mod_fake_trx_wait() {
    local t="${MOD_TIMEOUT[fake-trx]}"
    wait_until "$t" "sockets TRXD cote BTS ($TRX_BASE_PORT..+2)" \
        radio_udp_range "$TRX_BASE_PORT" || {
            mod_hint "regardez $(radio_log fake-trx) : bind refuse, ou fake_trx a quitte"
            return $MOD_RC_FAIL; }
    wait_until "$t" "sockets TRXD cote bande de base ($BB_BASE_PORT..+2)" \
        radio_udp_range "$BB_BASE_PORT" || return $MOD_RC_FAIL
    radio_alive fake-trx || {
        mod_fail "fake_trx a ouvert ses sockets puis s'est arrete"
        mod_hint "fin de $(radio_log fake-trx)"
        return $MOD_RC_FAIL; }
    mod_ok
}

mod_fake_trx_stop() { radio_kill fake-trx "fake_trx.py"; }
