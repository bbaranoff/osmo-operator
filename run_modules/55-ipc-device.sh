# =============================================================================
#  55-ipc-device - pont calypso-ipc-device (QEMU UDP ⇄ memoire partagee IPC)
# =============================================================================
#
#  ROLE        Lance le pont entre l'I/Q de QEMU (UDP 6702) et la memoire
#              partagee attendue par osmo-trx-ipc. Legacy : L1939-1967.
#              Fork d'ipc-driver-test ou le wrapper UHD est remplace par :
#              DL = cs16 shm → UDP vers QEMU ; UL = recv UDP → shm.
#
#  ORDRE       Ce device DOIT demarrer AVANT osmo-trx-ipc : c'est LUI qui cree
#              le socket maitre Unix ($IPC_MSOCK_PATH) auquel osmo-trx-ipc se
#              connecte. Inverse, osmo-trx-ipc sort immediatement sur un
#              greeting sans reponse - panne classique et illisible.
#
#  PREREQUIS   QEMU demarre ; binaire calypso-ipc-device compile.
#  SUCCES      Le socket maitre existe ET le processus est toujours vivant.
#  JOURNAL     $IPC_DEVICE_LOG (defaut $LOG_DIR/calypso-ipc-device.log)
#
#  ECART ASSUME AVEC LE LEGACY : binaire absent = ECHEC, pas un simple WARN.
#  Le legacy affichait "[TODO] pas encore implemente" puis continuait ; la
#  chaine radio etait alors morte sans que la moindre etape ne le dise.
# -----------------------------------------------------------------------------

MOD_REGISTER ipc-device "Pont I/Q calypso-ipc-device"
MOD_REQUIRED[ipc-device]=0
MOD_DEPS[ipc-device]="qemu"
MOD_PROFILES[ipc-device]="calypso hybrid"
MOD_TIMEOUT[ipc-device]=20      # legacy : 30 tentatives × 0,5 s (L1952)
MOD_ENABLED_IF[ipc-device]='[ "${CALYPSO_SKIP_IPC_DEVICE:-0}" != "1" ]'

: "${CALYPSO_IPC_DEVICE:=${QEMU_TOOLS:-${QEMU_TREE:-${QEMU_TREE}}/tools}/calypso-ipc-device/calypso-ipc-device}"
: "${IPC_SOCK_DIR:=/tmp}"
: "${IPC_MSOCK_PATH:=$IPC_SOCK_DIR/ipc_sock0}"
: "${IPC_DEVICE_LOG:=${LOG_DIR:-/tmp/calypso/logs}/calypso-ipc-device.log}"
# Parametres du pont, repris tels quels du legacy (L1950). Idiome `:=` : une
# valeur posee en ligne de commande ou par environment/ gagne toujours.
: "${CALYPSO_IPC_RELAY:=0}"
: "${CALYPSO_TRX_IQ_HOST:=127.0.0.1}"
: "${CALYPSO_TRX_IQ_RX_PORT:=5810}"
: "${CALYPSO_TRX_IQ_TX_PORT:=5811}"
: "${CALYPSO_RELAY_FIFOS:=/tmp/iq_fft.fifo:/tmp/iq_grgsm.fifo:/tmp/iq_record.fifo:/tmp/iq_asciifft.fifo}"

mod_ipc_device_check() {
    [ -x "$CALYPSO_IPC_DEVICE" ] || {
        mod_hint "compilez-le : make -C ${QEMU_TREE:-.}/tools/calypso-ipc-device - ou CALYPSO_SKIP_IPC_DEVICE=1 pour vous en passer"
        mod_fail "calypso-ipc-device introuvable ou non executable : $CALYPSO_IPC_DEVICE"
        return $MOD_RC_FAIL
    }
    [ -d "$IPC_SOCK_DIR" ] || {
        mod_fail "repertoire de socket inexistant : $IPC_SOCK_DIR"
        return $MOD_RC_FAIL
    }
    mod_ok
}

mod_ipc_device_status() { have_proc "calypso-ipc-device"; }

mod_ipc_device_start() {
    mkdir -p "${RUN_DIR:-/tmp/calypso}" "$(dirname "$IPC_DEVICE_LOG")" 2>/dev/null || true
    : > "$IPC_DEVICE_LOG" 2>/dev/null || true
    export CALYPSO_IPC_RELAY CALYPSO_TRX_IQ_HOST CALYPSO_TRX_IQ_RX_PORT \
           CALYPSO_TRX_IQ_TX_PORT CALYPSO_RELAY_FIFOS
    mod_say "relay=$CALYPSO_IPC_RELAY iq=$CALYPSO_TRX_IQ_HOST rx=$CALYPSO_TRX_IQ_RX_PORT tx=$CALYPSO_TRX_IQ_TX_PORT"
    mod_say "socket maitre attendu : $IPC_MSOCK_PATH"

    "$CALYPSO_IPC_DEVICE" -u "$IPC_SOCK_DIR" -n 0 >>"$IPC_DEVICE_LOG" 2>&1 &
    printf '%s\n' "$!" > "${RUN_DIR:-/tmp/calypso}/ipc-device.pid"
    mod_ok
}

# BARRIERE - remplace le `sleep 0.5` × 30 du legacy (L1954), qui se contentait
# d'un WARN si la socket manquait. Deux conditions, dans cet ordre :
#   1. le socket maitre est cree (c'est le contrat vis-a-vis d'osmo-trx-ipc) ;
#   2. le processus est TOUJOURS vivant - un device qui cree sa socket puis
#      meurt sur un bind UDP deja pris laisse un fichier socket trompeur,
#      exactement le faux positif corrige dans 40-qemu.
mod_ipc_device_wait() {
    local pidf="${RUN_DIR:-/tmp/calypso}/ipc-device.pid" pid
    if ! wait_until "${MOD_TIMEOUT[ipc-device]}" "socket maitre IPC ($IPC_MSOCK_PATH)" \
            have_unix "$IPC_MSOCK_PATH"; then
        modb_tail "$IPC_DEVICE_LOG" 20
        mod_hint "un ancien device peut encore tenir $IPC_MSOCK_PATH : ./run.sh --stop puis relancez"
        mod_fail "calypso-ipc-device n'a pas cree $IPC_MSOCK_PATH en ${MOD_TIMEOUT[ipc-device]}s"
        return $MOD_RC_FAIL
    fi
    pid="$(cat "$pidf" 2>/dev/null || echo 0)"
    if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
        modb_tail "$IPC_DEVICE_LOG" 20
        mod_hint "verifiez que les ports UDP $CALYPSO_TRX_IQ_RX_PORT/$CALYPSO_TRX_IQ_TX_PORT sont libres"
        mod_fail "calypso-ipc-device a cree sa socket puis s'est arrete"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_ipc_device_stop() {
    local pidf="${RUN_DIR:-/tmp/calypso}/ipc-device.pid" pid
    pid="$(cat "$pidf" 2>/dev/null || echo 0)"
    [ "$pid" != 0 ] && kill "$pid" 2>/dev/null
    pkill -f "calypso-ipc-device" 2>/dev/null
    # Le socket maitre ne disparait pas tout seul : laisse en place, il ferait
    # croire au run suivant que le device est deja la.
    rm -f "$pidf" "$IPC_MSOCK_PATH" "${IPC_MSOCK_PATH}_0"
    return 0
}
