# =============================================================================
#  64-trxcon - la couche 1 du mobile, cote TRXD
# =============================================================================
#
#  ROLE
#    Ce que fait le firmware Calypso dans la chaine QEMU, trxcon le fait en
#    logiciel sur l'hote : il parle TRXD au transceiver d'un cote, et expose une
#    socket L1CTL au mobile de l'autre.
#
#        mobile <--L1CTL /tmp/osmocom_l2_N--> trxcon <--TRXD $BB_BASE_PORT--> fake_trx
#
#    Une instance par mobile ($N_MS), chacune avec son port bande de base
#    ($BB_BASE_PORT + 3·(n-1)) et sa socket.
#
#  PREREQUIS
#    Le transceiver ecoute deja (module fake-trx) : trxcon qui ne trouve
#    personne reste muet, il ne meurt pas - d'ou l'ordre impose.
#
#  CRITERE DE SUCCES (barriere)
#    Pour CHAQUE instance : le processus vit ET la socket L1CTL existe. C'est
#    precisement la socket que le mobile attend ; la voir apparaitre remplace le
#    "sleep 2" qui tenait lieu de synchronisation.
#
#  JOURNAL     $LOG_DIR/trxcon-<n>.log
#
#  ORDRE       apres fake-trx, avant mobile.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER trxcon "Couche 1 mobile (trxcon)"
MOD_REQUIRED[trxcon]=1
MOD_DEPS[trxcon]="fake-trx osmo-trx"
MOD_PROFILES[trxcon]="faketrx"
MOD_ENABLED_IF[trxcon]='[ "${PHY_MODE:-faketrx}" != "virtphy" ]'
MOD_TIMEOUT[trxcon]=30

: "${TRXCON_BIN:=trxcon}"
: "${TRXCON_FN_ADVANCE:=100}"     # -F : avance de trame, valeur du lancement eprouve
: "${TRXCON_EXTRA_ARGS:=}"
MOD_LOG[trxcon]="${LOG_DIR}/trxcon.log"

# IP de bouclage du groupe de huit auquel appartient le mobile n.
_trxcon_group_ip() { printf '127.0.0.%d\n' "$(( ($1 - 1) / 8 + 1 ))"; }

mod_trxcon_check() {
    command -v "$TRXCON_BIN" >/dev/null 2>&1 || [ -x "$TRXCON_BIN" ] || {
        mod_fail "binaire introuvable : $TRXCON_BIN"
        mod_hint "installez osmocom-bb (host/trxcon), ou posez TRXCON_BIN"
        return $MOD_RC_FAIL; }

    # Une socket laissee par un run precedent fait croire au mobile que la L1
    # est prete, alors que plus personne n'est derriere. On refuse de partir
    # sur cet etat ambigu - le stop du module les nettoie normalement.
    local n s
    for ((n=1; n<=N_MS; n++)); do
        s="$(radio_l2_sock "$n")"
        if [ -S "$s" ] && ! pgrep -f "$TRXCON_BIN.*$s" >/dev/null 2>&1; then
            mod_fail "socket L1CTL orpheline : $s (aucun trxcon derriere)"
            mod_hint "rm -f $s - ou ./run.sh --stop pour nettoyer proprement"
            return $MOD_RC_FAIL
        fi
    done
    mod_ok
}

mod_trxcon_status() { pgrep -x "$(basename "$TRXCON_BIN")" >/dev/null 2>&1; }

mod_trxcon_start() {
    radio_dirs
    local n s port gip log
    for ((n=1; n<=N_MS; n++)); do
        s="$(radio_l2_sock "$n")"
        port="$(radio_bb_port "$n")"
        gip="$(_trxcon_group_ip "$n")"
        log="$(radio_log "trxcon-$n")"
        mod_say "ms$n : TRXD $TRX_BIND_IP:$port (bind $gip) -> L1CTL $s ; journal $log"
        # shellcheck disable=SC2086
        "$TRXCON_BIN" -i "$TRX_BIND_IP" -b "$gip" -p "$port" -s "$s" \
                      -C 1 -F "$TRXCON_FN_ADVANCE" $TRXCON_EXTRA_ARGS \
                      >>"$log" 2>&1 &
        radio_save_pid "trxcon-$n" $!
    done
    mod_ok
}

# BARRIERE - une socket par instance, et l'instance encore vivante derriere.
mod_trxcon_wait() {
    local n s
    for ((n=1; n<=N_MS; n++)); do
        s="$(radio_l2_sock "$n")"
        wait_until "${MOD_TIMEOUT[trxcon]}" "socket L1CTL de ms$n ($s)" \
            have_unix "$s" || {
                mod_hint "fin de $(radio_log "trxcon-$n") : port bande de base deja pris, ou transceiver injoignable"
                return $MOD_RC_FAIL; }
        radio_alive "trxcon-$n" || {
            mod_fail "trxcon ms$n a cree sa socket puis s'est arrete"
            mod_hint "fin de $(radio_log "trxcon-$n")"
            return $MOD_RC_FAIL; }
    done
    mod_ok
}

mod_trxcon_stop() {
    local n s
    for ((n=1; n<=N_MS; n++)); do
        s="$(radio_l2_sock "$n")"
        radio_kill "trxcon-$n" "$TRXCON_BIN.*$s"
        rm -f "$s"
    done
    pkill -x "$(basename "$TRXCON_BIN")" 2>/dev/null
    return 0
}
