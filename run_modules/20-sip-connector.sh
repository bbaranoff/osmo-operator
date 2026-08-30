# =============================================================================
#  13-sip_connector - OsmoSIP, le commutateur du service circuit (CS)
# =============================================================================
#  ROLE      VLR + commutation CS : rattachements, SMS, appels. Il est client
#            GSUP du HLR, client MGCP du MGW, et ASP M3UA du STP - les trois
#            doivent etre la AVANT lui, d'ou MOD_DEPS.
#  PREREQUIS binaires et conf osmo-sip_connector ; STP/HLR/MGW prets.
#  SUCCES    VTY en ecoute (4254) ET association SCTP ETABLIE depuis le port
#            local de l'ASP declare dans la conf (le lien M3UA vers le STP est
#            reellement monte, pas seulement configure) ET socket MNCC en
#            ecoute si "mncc external" est configure ET aucun redemarrage.
#  JOURNAL   journalctl -u osmo-sip_connector    (sans systemd : $LOG_DIR/osmo-sip_connector.log)
#
#  NOTE la socket MNCC (/tmp/sip_connector_mncc) n'est PAS visible avec [ -S ] : le
#  service tourne avec un /tmp prive. On la sonde donc via ss -xl, qui la voit.
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER sip_connector "Coeur - OsmoSIP (commutation CS)"
MOD_REQUIRED[sip_connector]=1
MOD_DEPS[sip_connector]="stp hlr mgw"
MOD_PROFILES[sip_connector]="calypso faketrx hybrid core"
MOD_JOURNAL[sip_connector]="osmo-sip_connector"
MOD_TIMEOUT[sip_connector]=40
MOD_ENABLED_IF[sip_connector]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${SIP_UNIT:=osmo-sip_connector}"
: "${SIP_VTY_PORT:=4254}"

_sip_connector_cfg()      { core_cfg osmo-sip_connector; }
# "asp <nom> <port distant> <port local> m3ua" → le port local identifie
# l'association SCTP cote SIP.
_sip_connector_asp_port() { core_cfg_field "$(_sip_connector_cfg)" '^[[:space:]]*asp[[:space:]]+.*[[:space:]]m3ua[[:space:]]*$' 4 ""; }
_sip_connector_mncc()     { core_cfg_field "$(_sip_connector_cfg)" '^[[:space:]]*mncc[[:space:]]+external[[:space:]]' 3 ""; }

mod_sip_connector_check() {
    core_bin osmo-sip_connector >/dev/null || { mod_fail "binaire osmo-sip_connector introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_sip_connector_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-sip_connector.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_sip_connector_cfg)"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_sip_connector_status() { core_unit_active "$SIP_UNIT" || core_vty_listen "$SIP_VTY_PORT"; }

mod_sip_connector_start() {
    core_svc_start "$SIP_UNIT" "$(core_bin osmo-sip_connector)" -c "$(_sip_connector_cfg)" \
        || { mod_fail "systemctl start $SIP_UNIT a echoue"
             mod_hint "journalctl -u $SIP_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - un SIP "actif" dont l'ASP n'est jamais passe ACTIVE ne verra
# jamais le BSC : le rattachement echouerait sans que rien ne le signale. Le
# critere est l'association SCTP etablie, sondee passivement (ss --sctp).
mod_sip_connector_wait() {
    local to="${MOD_TIMEOUT[sip_connector]}" asp mncc
    asp="$(_sip_connector_asp_port)"; mncc="$(_sip_connector_mncc)"

    if ! wait_until "$to" "VTY OsmoSIP ($SIP_VTY_PORT)" core_vty_listen "$SIP_VTY_PORT"; then
        mod_hint "journalctl -u $SIP_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if [ -n "$asp" ]; then
        if ! wait_until "$to" "lien M3UA vers le STP (SCTP local :$asp)" core_sctp_estab "$asp"; then
            mod_hint "STP joignable ? ss -an --sctp | grep $asp ; verifiez "asp ... m3ua" dans $(_sip_connector_cfg)"
            return $MOD_RC_FAIL
        fi
    else
        mod_say "aucun ASP m3ua dans $(_sip_connector_cfg) - barriere SS7 non applicable"
    fi
    if [ -n "$mncc" ]; then
        if ! wait_until "$to" "socket MNCC ($mncc)" core_unix_listen "$mncc"; then
            mod_hint ""mncc external $mncc" configure mais la socket n'apparait pas : ss -xl | grep sip_connector_mncc"
            return $MOD_RC_FAIL
        fi
    fi
    if core_restarted_since "$SIP_UNIT"; then
        mod_hint "journalctl -u $SIP_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoSIP a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_sip_connector_stop() { core_svc_stop "$SIP_UNIT" "osmo-sip_connector -c"; }
