# =============================================================================
#  22-smsc - passerelle SMS (proto-smsc-daemon + relay interop)
# =============================================================================
#  ROLE      porte les SMS : le daemon se connecte au HLR en GSUP sous le nom
#            IPA "SMSC-OP<n>" (declare dans osmo-hlr.cfg : "smsc entity /
#            smsc default-route") et expose la socket d'envoi MT ; le relay
#            python ecoute en TCP pour les SMS inter-operateurs.
#            Delegue a /etc/osmocom/smsc-start.sh - on ne reimplemente pas ce
#            qui marche, on l'encadre d'une barriere.
#  PREREQUIS proto-smsc-daemon ; smsc-start.sh ; HLR pret (GSUP) ;
#            /etc/osmocom/sms-routing.conf pour le relay.
#  SUCCES    socket d'envoi MT presente ET port TCP du relay en ecoute (ce
#            dernier seulement si le script du relay est installe).
#  JOURNAL   $LOG_DIR/smsc-op<n>.log ; journal des SMS MO recus :
#            /var/log/osmocom/mo-sms-op<n>.log  (chemin reel, different de
#            celui qu'annoncait start-direct.sh:493).
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER smsc "Coeur - passerelle SMS (proto-SMSC)"
MOD_REQUIRED[smsc]=0
MOD_DEPS[smsc]="hlr"
MOD_PROFILES[smsc]="calypso faketrx hybrid core"
MOD_TIMEOUT[smsc]=60
MOD_ENABLED_IF[smsc]='[ "${NO_OSMO_START:-0}" != 1 ] && [ "${CORE_SMS:-1}" = 1 ]'

: "${OPERATOR_ID:=1}"
: "${SMSC_SCRIPT:=/etc/osmocom/smsc-start.sh}"
: "${SMSC_RELAY_SCRIPT:=/etc/osmocom/sms-interop-relay.py}"
: "${SMSC_RELAY_PORT:=7890}"
: "${SMSC_SENDMT_SOCKET:=/tmp/sendmt_socket}"
: "${SMSC_HLR_IP:=127.0.0.2}"

mod_smsc_check() {
    command -v proto-smsc-daemon >/dev/null 2>&1 || {
        mod_hint "sans proto-smsc-daemon les SMS passent uniquement par le VTY du MSC ; CORE_SMS=0 pour ne plus l'essayer"
        mod_skip "proto-smsc-daemon absent"; return $MOD_RC_SKIP; }
    [ -x "$SMSC_SCRIPT" ] || {
        mod_hint "deployez les scripts : cp scripts/smsc-start.sh $OSMOCOM_CFG/"
        mod_fail "script de demarrage absent : $SMSC_SCRIPT"; return $MOD_RC_FAIL; }
    core_tcp_listen 4222 "$SMSC_HLR_IP" || {
        mod_hint "le HLR doit ecouter en GSUP : ./run.sh --only hlr"
        mod_fail "GSUP HLR ($SMSC_HLR_IP:4222) injoignable"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_smsc_status() { have_proc 'proto-smsc-daemon'; }

mod_smsc_start() {
    mkdir -p "$RUN_DIR" "$LOG_DIR" /var/log/osmocom 2>/dev/null || true
    # Purge ciblee d'un daemon residuel : deux instances se disputeraient la
    # meme socket MT et le meme nom IPA cote HLR.
    pkill -f 'proto-smsc-daemon' 2>/dev/null
    local log="$LOG_DIR/smsc-op${OPERATOR_ID}.log"
    mod_say "journal : $log ; SMS MO recus : /var/log/osmocom/mo-sms-op${OPERATOR_ID}.log"
    setsid env OPERATOR_ID="$OPERATOR_ID" HLR_IP="$SMSC_HLR_IP" RELAY_PORT="$SMSC_RELAY_PORT" \
        bash "$SMSC_SCRIPT" >"$log" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$RUN_DIR/smsc-op${OPERATOR_ID}.pid"
    mod_ok
}

# BARRIERE - smsc-start.sh attend lui-meme le HLR puis temporise : "lance" ne
# dit rien. Les deux criteres sont les deux points d'entree reellement utilises
# ensuite (envoi MT par la socket, SMS entrants par le relay).
mod_smsc_wait() {
    local to="${MOD_TIMEOUT[smsc]}"

    if ! wait_until "$to" "socket d'envoi MT ($SMSC_SENDMT_SOCKET)" core_unix_listen "$SMSC_SENDMT_SOCKET"; then
        mod_hint "voir $LOG_DIR/smsc-op${OPERATOR_ID}.log : le daemon n'a pas pu se connecter au HLR ($SMSC_HLR_IP:4222)"
        return $MOD_RC_FAIL
    fi
    if [ -f "$SMSC_RELAY_SCRIPT" ]; then
        if ! wait_until "$to" "relay SMS interop (TCP $SMSC_RELAY_PORT)" core_tcp_listen "$SMSC_RELAY_PORT"; then
            mod_hint "port $SMSC_RELAY_PORT deja pris, ou sms-routing.conf illisible : voir $LOG_DIR/smsc-op${OPERATOR_ID}.log"
            return $MOD_RC_FAIL
        fi
    else
        mod_say "$SMSC_RELAY_SCRIPT absent - pas de relay inter-operateurs, barriere non applicable"
    fi
    mod_ok
}

mod_smsc_stop() {
    local pf="$RUN_DIR/smsc-op${OPERATOR_ID}.pid"
    [ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
    pkill -f 'proto-smsc-daemon' 2>/dev/null
    pkill -f 'sms-interop-relay.py' 2>/dev/null
    rm -f "$SMSC_SENDMT_SOCKET" 2>/dev/null
    return 0
}
