# =============================================================================
#  56-trx-ipc - osmo-trx-ipc : le transceiver vu par la BTS
# =============================================================================
#
#  ROLE        Se connecte au socket maitre de calypso-ipc-device et expose
#              l'interface TRXD (UDP 5700-5702) vers osmo-bts-trx.
#              Legacy : run.sh.legacy L1969-1980.
#
#  CE QUE LE LEGACY NE FAISAIT PAS  Rien. Aucune verification, pas meme un
#  WARN : "si calypso-ipc-device n'est pas demarre, osmo-trx-ipc exit
#  immediatement (greeting_req sans reponse) - c'est OK en transition, sa
#  fenetre tmux reste" (commentaire L1971-1973). Autrement dit, la panne la
#  plus frequente de la chaine radio etait invisible depuis le lancement.
#
#  PREREQUIS   calypso-ipc-device pret (socket maitre), binaire + cfg presents.
#  SUCCES      Processus vivant ET au moins un port UDP du bloc TRXD binde.
#              POURQUOI CE CRITERE : le greeting echoue tue le processus en
#              une fraction de seconde ; les sockets TRXD, elles, ne sont
#              ouvertes qu'une fois le device accepte. "Vivant" seul ne
#              prouverait rien (il peut mourir juste apres), "port ouvert"
#              seul non plus (un residu du run precedent) - les deux ensemble
#              signifient : ce processus-ci sert reellement la BTS.
#
#  CONVENTION DE PORTS : osmo-bts-trx parle en local sur 5800+ et vise le
#  transceiver sur 5700+ (base-port remote par defaut). Le transceiver binde
#  donc 5700 (clock), 5701 (controle canal 0), 5702 (donnees canal 0). On
#  accepte l'un des trois : la repartition exacte depend de la version.
#
#  JOURNAL     $OSMO_TRX_IPC_LOG (defaut $LOG_DIR/osmo-trx-ipc.log)
# -----------------------------------------------------------------------------

MOD_REGISTER trx-ipc "Transceiver osmo-trx-ipc"
MOD_REQUIRED[trx-ipc]=0
MOD_DEPS[trx-ipc]="ipc-device"
MOD_PROFILES[trx-ipc]="calypso hybrid"
MOD_TIMEOUT[trx-ipc]=20
MOD_ENABLED_IF[trx-ipc]='[ "${CALYPSO_SKIP_TRX_IPC:-0}" != "1" ]'

: "${OSMO_TRX_IPC:=}"
: "${OSMO_TRX_IPC_CFG:=}"
: "${OSMO_TRX_IPC_LOG:=${LOG_DIR:-/tmp/calypso/logs}/osmo-trx-ipc.log}"
: "${TRX_BASE_PORT:=5700}"

_trxipc_trxd_up() {
    modb_have_udp "$TRX_BASE_PORT" \
        || modb_have_udp $(( TRX_BASE_PORT + 1 )) \
        || modb_have_udp $(( TRX_BASE_PORT + 2 ))
}

mod_trx_ipc_check() {
    # Resolution du binaire - lecture seule, aucun effet de bord.
    if [ -z "$OSMO_TRX_IPC" ] || [ ! -x "$OSMO_TRX_IPC" ]; then
        if command -v osmo-trx-ipc >/dev/null 2>&1; then
            OSMO_TRX_IPC="$(command -v osmo-trx-ipc)"
        elif [ -x "${OSMO_TRX:-${GSM_ROOT}/osmo-trx}/Transceiver52M/osmo-trx-ipc" ]; then
            OSMO_TRX_IPC="${OSMO_TRX:-${GSM_ROOT}/osmo-trx}/Transceiver52M/osmo-trx-ipc"
        fi
    fi
    [ -n "$OSMO_TRX_IPC" ] && [ -x "$OSMO_TRX_IPC" ] || {
        mod_hint "installez osmo-trx (cible ipc) ou posez OSMO_TRX_IPC=<chemin> ; CALYPSO_SKIP_TRX_IPC=1 pour vous en passer"
        mod_fail "osmo-trx-ipc introuvable"
        return $MOD_RC_FAIL
    }

    # Resolution de la cfg. La cfg VERSIONNEE du depot d'abord : celle de
    # /etc/osmocom declarait chan 0 ET chan 1, alors que le Calypso n'a qu'un
    # canal - osmo-trx-ipc sort alors sur "DDEV chan num mismatch" (L1058-1062).
    if [ -z "$OSMO_TRX_IPC_CFG" ] || [ ! -r "$OSMO_TRX_IPC_CFG" ]; then
        local c
        for c in "${QEMU_CFGS:-${QEMU_TREE:-${QEMU_TREE}}/cfgs}/osmo-trx-ipc.cfg" \
                 "${OSMOCOM_CFG:-/etc/osmocom}/osmo-trx-ipc.cfg"; do
            [ -r "$c" ] && { OSMO_TRX_IPC_CFG="$c"; break; }
        done
    fi
    [ -n "$OSMO_TRX_IPC_CFG" ] && [ -r "$OSMO_TRX_IPC_CFG" ] || {
        mod_hint "attendu : cfgs/osmo-trx-ipc.cfg (un seul "chan 0") ; posez OSMO_TRX_IPC_CFG=<chemin>"
        mod_fail "configuration d'osmo-trx-ipc introuvable"
        return $MOD_RC_FAIL
    }

    # Le socket maitre doit exister : sans lui, le greeting echoue et le
    # processus meurt aussitot. Deux situations a ne PAS confondre :
    #   - le device est desactive (CALYPSO_SKIP_IPC_DEVICE=1) : personne ne
    #     creera jamais ce socket, on refuse tout de suite ;
    #   - le device est actif : il vient de demarrer (c'est notre dependance
    #     declaree, donc sa barriere est passee) - ou bien on est en --dry-run,
    #     ou il n'a ete que simule. Dans les deux cas, echouer ici serait faux :
    #     on note, et c'est la barriere qui tranchera sur du reel.
    if [ ! -S "${IPC_MSOCK_PATH:-/tmp/ipc_sock0}" ]; then
        if [ "${CALYPSO_SKIP_IPC_DEVICE:-0}" = "1" ]; then
            mod_hint "retirez CALYPSO_SKIP_IPC_DEVICE=1, ou fournissez un autre producteur du socket via IPC_MSOCK_PATH"
            mod_fail "socket maitre IPC absent (${IPC_MSOCK_PATH:-/tmp/ipc_sock0}) et calypso-ipc-device est desactive : personne ne le creera"
            return $MOD_RC_FAIL
        fi
        mod_say "socket maitre ${IPC_MSOCK_PATH:-/tmp/ipc_sock0} pas encore present - verification reportee a la barriere"
    fi
    mod_say "binaire=$OSMO_TRX_IPC cfg=$OSMO_TRX_IPC_CFG"
    mod_ok
}

mod_trx_ipc_status() { have_proc "osmo-trx-ipc"; }

mod_trx_ipc_start() {
    mkdir -p "${RUN_DIR:-/tmp/calypso}" "$(dirname "$OSMO_TRX_IPC_LOG")" 2>/dev/null || true
    : > "$OSMO_TRX_IPC_LOG" 2>/dev/null || true
    "$OSMO_TRX_IPC" -C "$OSMO_TRX_IPC_CFG" >>"$OSMO_TRX_IPC_LOG" 2>&1 &
    printf '%s\n' "$!" > "${RUN_DIR:-/tmp/calypso}/trx-ipc.pid"
    mod_ok
}

# BARRIERE NEUVE - le legacy n'en avait aucune.
mod_trx_ipc_wait() {
    local pid; pid="$(cat "${RUN_DIR:-/tmp/calypso}/trx-ipc.pid" 2>/dev/null || echo 0)"

    # Condition amont, verifiee sur du reel cette fois : sans socket maitre, le
    # greeting ne peut pas aboutir - autant nommer la vraie cause.
    if [ ! -S "${IPC_MSOCK_PATH:-/tmp/ipc_sock0}" ]; then
        modb_tail "$OSMO_TRX_IPC_LOG" 15
        mod_hint "lancez d'abord le device : ./run.sh --only ipc-device"
        mod_fail "socket maitre IPC absent (${IPC_MSOCK_PATH:-/tmp/ipc_sock0}) : osmo-trx-ipc ne peut pas faire son greeting"
        return $MOD_RC_FAIL
    fi

    if ! wait_until "${MOD_TIMEOUT[trx-ipc]}" "ports TRXD ${TRX_BASE_PORT}-$(( TRX_BASE_PORT + 2 ))" \
            _trxipc_trxd_up; then
        modb_tail "$OSMO_TRX_IPC_LOG" 25
        if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
            mod_hint "cause la plus frequente : greeting refuse par calypso-ipc-device (nombre de canaux, cfg a un seul "chan 0")"
            mod_fail "osmo-trx-ipc s'est arrete avant d'ouvrir l'interface TRXD"
        else
            mod_hint "detail : $OSMO_TRX_IPC_LOG"
            mod_fail "aucun port TRXD ouvert apres ${MOD_TIMEOUT[trx-ipc]}s"
        fi
        return $MOD_RC_FAIL
    fi

    if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
        modb_tail "$OSMO_TRX_IPC_LOG" 25
        mod_hint "un osmo-trx-ipc residuel tient peut-etre les ports : ./run.sh --stop"
        mod_fail "les ports TRXD sont ouverts mais PAS par ce processus (il est mort)"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_trx_ipc_stop() {
    local pidf="${RUN_DIR:-/tmp/calypso}/trx-ipc.pid" pid
    pid="$(cat "$pidf" 2>/dev/null || echo 0)"
    [ "$pid" != 0 ] && kill "$pid" 2>/dev/null
    pkill -f "osmo-trx-ipc" 2>/dev/null
    rm -f "$pidf"
    return 0
}
