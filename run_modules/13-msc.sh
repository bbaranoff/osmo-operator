# =============================================================================
#  13-msc - OsmoMSC, le commutateur du service circuit (CS)
# =============================================================================
#  ROLE      VLR + commutation CS : rattachements, SMS, appels. Il est client
#            GSUP du HLR, client MGCP du MGW, et ASP M3UA du STP - les trois
#            doivent etre la AVANT lui, d'ou MOD_DEPS.
#  PREREQUIS binaires et conf osmo-msc ; STP/HLR/MGW prets.
#  SUCCES    VTY en ecoute (4254) ET association SCTP ETABLIE depuis le port
#            local de l'ASP declare dans la conf (le lien M3UA vers le STP est
#            reellement monte, pas seulement configure) ET socket MNCC en
#            ecoute si "mncc external" est configure ET aucun redemarrage.
#  JOURNAL   journalctl -u osmo-msc    (sans systemd : $LOG_DIR/osmo-msc.log)
#
#  NOTE la socket MNCC (/tmp/msc_mncc) n'est PAS visible avec [ -S ] : le
#  service tourne avec un /tmp prive. On la sonde donc via ss -xl, qui la voit.
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER msc "Coeur - OsmoMSC (commutation CS)"
MOD_REQUIRED[msc]=1
MOD_DEPS[msc]="stp hlr mgw"
MOD_PROFILES[msc]="calypso faketrx hybrid core"
MOD_JOURNAL[msc]="osmo-msc"
MOD_TIMEOUT[msc]=40
MOD_ENABLED_IF[msc]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${MSC_UNIT:=osmo-msc}"
: "${MSC_VTY_PORT:=4254}"

_msc_cfg()      { core_cfg osmo-msc; }
# "asp <nom> <port distant> <port local> m3ua" → le port local identifie
# l'association SCTP cote MSC.
_msc_asp_port() { core_cfg_field "$(_msc_cfg)" '^[[:space:]]*asp[[:space:]]+.*[[:space:]]m3ua[[:space:]]*$' 4 ""; }
_msc_mncc()     { core_cfg_field "$(_msc_cfg)" '^[[:space:]]*mncc[[:space:]]+external[[:space:]]' 3 ""; }

mod_msc_check() {
    core_bin osmo-msc >/dev/null || { mod_fail "binaire osmo-msc introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_msc_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-msc.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_msc_cfg)"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_msc_status() { core_unit_active "$MSC_UNIT" || core_vty_listen "$MSC_VTY_PORT"; }

mod_msc_start() {
    core_svc_start "$MSC_UNIT" "$(core_bin osmo-msc)" -c "$(_msc_cfg)" \
        || { mod_fail "systemctl start $MSC_UNIT a echoue"
             mod_hint "journalctl -u $MSC_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - un MSC "actif" dont l'ASP n'est jamais passe ACTIVE ne verra
# jamais le BSC : le rattachement echouerait sans que rien ne le signale. Le
# critere est l'association SCTP etablie, sondee passivement (ss --sctp).
mod_msc_wait() {
    local to="${MOD_TIMEOUT[msc]}" asp mncc
    asp="$(_msc_asp_port)"; mncc="$(_msc_mncc)"

    if ! wait_until "$to" "VTY OsmoMSC ($MSC_VTY_PORT)" core_vty_listen "$MSC_VTY_PORT"; then
        mod_hint "journalctl -u $MSC_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if [ -n "$asp" ]; then
        if ! wait_until "$to" "lien M3UA vers le STP (SCTP local :$asp)" core_sctp_estab "$asp"; then
            mod_hint "STP joignable ? ss -an --sctp | grep $asp ; verifiez "asp ... m3ua" dans $(_msc_cfg)"
            return $MOD_RC_FAIL
        fi
    else
        mod_say "aucun ASP m3ua dans $(_msc_cfg) - barriere SS7 non applicable"
    fi
    if [ -n "$mncc" ]; then
        if ! wait_until "$to" "socket MNCC ($mncc)" core_unix_listen "$mncc"; then
            mod_hint ""mncc external $mncc" configure mais la socket n'apparait pas : ss -xl | grep msc_mncc"
            return $MOD_RC_FAIL
        fi
    fi
    if core_restarted_since "$MSC_UNIT"; then
        mod_hint "journalctl -u $MSC_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoMSC a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_msc_stop() { core_svc_stop "$MSC_UNIT" "osmo-msc -c"; }
