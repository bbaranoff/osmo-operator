# =============================================================================
#  61-osmo-trx - transceiver reel (modem GMSK), alternative a fake_trx
# =============================================================================
#
#  ROLE
#    Le vrai modem, celui qui module et demodule au lieu de recopier des bursts.
#    Il remplace fake_trx a la meme place dans la chaine, et sert le meme TRXD
#    au BTS :
#
#        <source I/Q> --> osmo-trx --TRXD $TRX_BASE_PORT--> osmo-bts-trx
#
#    Source I/Q selon la variante du binaire : memoire partagee pour
#    osmo-trx-ipc (via calypso-ipc-device), carte SDR pour osmo-trx-uhd.
#
#  PERIMETRE - NE PAS CONFONDRE AVEC 56-trx-ipc
#    56-trx-ipc.sh est l'osmo-trx-ipc de la chaine de l'emulateur (profils
#    calypso/hybrid), avec sa dependance a ipc-device. Le module ci-dessous est
#    le transceiver du profil "faketrx" : il n'est active que si l'on demande
#    explicitement RADIO_TRANSCEIVER=osmo-trx, ce qui desactive alors fake-trx.
#    Les deux ne peuvent pas tourner ensemble - meme plage de ports TRXD.
#
#  PREREQUIS - DEPENDANCE CROISEE, LE PIEGE DE LA VARIANTE IPC
#    osmo-trx-ipc se CONNECTE au socket maitre ($IPC_MSOCK_PATH) cree par
#    calypso-ipc-device. Si le device n'est pas la, le handshake "greeting"
#    echoue et osmo-trx-ipc sort immediatement - sans que rien en aval ne le
#    signale. Le check l'exige donc explicitement, mais SEULEMENT pour cette
#    variante : une variante SDR n'a pas de socket maitre.
#
#  CRITERE DE SUCCES (barriere)
#    Le processus vit ET a ouvert ses sockets TRXD. Le premier point a lui seul
#    ne suffit pas - un echec de greeting laisse une trace, pas un service.
#
#  JOURNAL     $LOG_DIR/osmo-trx.log
#
#  ORDRE       apres la source I/Q (calypso-ipc-device pour la variante IPC),
#              avant osmo-bts-trx.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER osmo-trx "Transceiver osmo-trx (IPC)"
MOD_REQUIRED[osmo-trx]=1
MOD_PROFILES[osmo-trx]="faketrx"
MOD_TIMEOUT[osmo-trx]=30

# Socket maitre du device, exige par la seule variante IPC (voir le check).
: "${IPC_MSOCK_PATH:=/tmp/ipc_sock0}"
MOD_ENABLED_IF[osmo-trx]='[ "${PHY_MODE:-faketrx}" != "virtphy" ] && [ "${RADIO_TRANSCEIVER:-fake}" = "osmo-trx" ]'

: "${OSMO_TRX_BIN:=osmo-trx-ipc}"
: "${OSMO_TRX_CFG:=${QEMU_CFGS:-${OQC_ROOT}/cfgs}/osmo-trx-ipc.cfg}"
MOD_LOG[osmo-trx]="${LOG_DIR}/osmo-trx.log"

mod_osmo_trx_check() {
    command -v "$OSMO_TRX_BIN" >/dev/null 2>&1 || [ -x "$OSMO_TRX_BIN" ] || {
        mod_fail "binaire introuvable : $OSMO_TRX_BIN"
        mod_hint "installez osmo-trx, ou posez OSMO_TRX_BIN=/chemin/vers/osmo-trx-ipc"
        return $MOD_RC_FAIL; }
    [ -r "$OSMO_TRX_CFG" ] || {
        mod_fail "configuration illisible : $OSMO_TRX_CFG"
        mod_hint "posez OSMO_TRX_CFG, ou copiez cfgs/osmo-trx-ipc.cfg"
        return $MOD_RC_FAIL; }
    # Exigence propre a la variante IPC : sans socket maitre, le greeting
    # echoue et le processus sort - autant le dire ici plutot qu'au timeout.
    case "$OSMO_TRX_BIN" in
        *ipc*) [ -S "$IPC_MSOCK_PATH" ] || {
                   mod_fail "socket maitre IPC absent : $IPC_MSOCK_PATH"
                   mod_hint "demarrez calypso-ipc-device d'abord (il cree ce socket ; sans lui le greeting echoue)"
                   return $MOD_RC_FAIL; } ;;
    esac

    # Coherence conf <-> plan d'adressage : la valeur du fichier fait foi, elle
    # est ce que le BTS devra viser. On la relit ici pour que la barriere et le
    # module BTS parlent du meme port.
    local cfg_base; cfg_base="$(radio_cfg_val "$OSMO_TRX_CFG" "base-port")"
    [ -n "$cfg_base" ] && TRX_BASE_PORT="$cfg_base"

    if radio_foreign_holder "$TRX_BASE_PORT" "$OSMO_TRX_BIN"; then
        mod_fail "port TRXD $TRX_BASE_PORT deja tenu (fake_trx ? autre osmo-trx ?)"
        mod_hint "un seul transceiver a la fois : ss -uanp | grep :$TRX_BASE_PORT"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_osmo_trx_status() { have_proc "$OSMO_TRX_BIN"; }

mod_osmo_trx_start() {
    radio_dirs
    local log; log="$(radio_log osmo-trx)"
    mod_say "commande : $OSMO_TRX_BIN -C $OSMO_TRX_CFG"
    case "$OSMO_TRX_BIN" in *ipc*) mod_say "socket maitre : $IPC_MSOCK_PATH" ;; esac
    mod_say "journal  : $log"
    "$OSMO_TRX_BIN" -C "$OSMO_TRX_CFG" >>"$log" 2>&1 &
    radio_save_pid osmo-trx $!
    mod_ok
}

# BARRIERE - un greeting rate ne laisse qu'un journal, pas un service.
mod_osmo_trx_wait() {
    local log; log="$(radio_log osmo-trx)"
    local cfg_base; cfg_base="$(radio_cfg_val "$OSMO_TRX_CFG" "base-port")"
    [ -n "$cfg_base" ] && TRX_BASE_PORT="$cfg_base"

    wait_until "${MOD_TIMEOUT[osmo-trx]}" "sockets TRXD ($TRX_BASE_PORT..+2)" \
        radio_udp_range "$TRX_BASE_PORT" || {
            mod_hint "fin de $log : "greeting" sans reponse = calypso-ipc-device absent ou muet"
            return $MOD_RC_FAIL; }

    radio_alive osmo-trx || {
        mod_fail "osmo-trx s'est arrete apres avoir ouvert ses sockets"
        mod_hint "fin de $log"
        return $MOD_RC_FAIL; }

    # Renseignement, pas critere : la VTY est un confort de diagnostic, son
    # absence ne condamne pas un transceiver qui sert deja du TRXD.
    have_port "$OSMO_TRX_VTY_PORT" \
        && mod_say "VTY disponible sur 127.0.0.1:$OSMO_TRX_VTY_PORT" \
        || mod_say "VTY $OSMO_TRX_VTY_PORT non ouverte (sans consequence sur le TRXD)"
    mod_ok
}

mod_osmo_trx_stop() { radio_kill osmo-trx "$OSMO_TRX_BIN"; }
