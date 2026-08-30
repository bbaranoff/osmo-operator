# =============================================================================
#  14-bsc - OsmoBSC, le controleur de station de base
# =============================================================================
#  ROLE      pilote les BTS (OML/RSL sur A-bis) et parle au MSC via l'interface
#            A (SCCP/M3UA). C'est lui qui ecoute les BTS : tant que ses ports
#            A-bis ne sont pas ouverts, aucune BTS - ni osmo-bts-trx, ni la
#            BTS emulee du Calypso - ne peut s'attacher.
#  PREREQUIS binaires et conf osmo-bsc ; STP et MSC prets ; MGW pret (le BSC
#            ouvre lui aussi une session MGCP).
#  SUCCES    VTY en ecoute (4242) ET les deux ecoutes A-bis IPA (OML 3002,
#            RSL 3003) ET association SCTP etablie depuis le port local de son
#            ASP (lien M3UA vers le STP monte) ET aucun redemarrage.
#  JOURNAL   journalctl -u osmo-bsc    (sans systemd : $LOG_DIR/osmo-bsc.log)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER bsc "Coeur - OsmoBSC (controleur BTS)"
MOD_REQUIRED[bsc]=1
MOD_DEPS[bsc]="stp mgw msc"
MOD_PROFILES[bsc]="calypso faketrx hybrid core"
MOD_JOURNAL[bsc]="osmo-bsc"
MOD_TIMEOUT[bsc]=40
MOD_ENABLED_IF[bsc]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${BSC_UNIT:=osmo-bsc}"
: "${BSC_VTY_PORT:=4242}"
# Ports A-bis du pilote e1_input "ipa" : fixes par le protocole IPA, pas par
# la conf (constate a l'execution : 0.0.0.0:3002 et 0.0.0.0:3003).
: "${BSC_OML_PORT:=3002}"
: "${BSC_RSL_PORT:=3003}"

_bsc_cfg()      { core_cfg osmo-bsc; }
_bsc_asp_port() { core_cfg_field "$(_bsc_cfg)" '^[[:space:]]*asp[[:space:]]+.*[[:space:]]m3ua[[:space:]]*$' 4 ""; }

mod_bsc_check() {
    core_bin osmo-bsc >/dev/null || { mod_fail "binaire osmo-bsc introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_bsc_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-bsc.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_bsc_cfg)"; return $MOD_RC_FAIL; }
    # Un marqueur de gabarit non substitue produirait un BSC qui demarre puis
    # meurt sur une ligne de conf invalide : autant le voir avant.
    if grep -qa '__[A-Z_]\+__' "$(_bsc_cfg)" 2>/dev/null; then
        mod_hint "la configuration contient encore des jetons de gabarit - regenerez-la"
        mod_fail "$(_bsc_cfg) : gabarit non substitue"; return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_bsc_status() { core_unit_active "$BSC_UNIT" || core_vty_listen "$BSC_VTY_PORT"; }

mod_bsc_start() {
    core_svc_start "$BSC_UNIT" "$(core_bin osmo-bsc)" -c "$(_bsc_cfg)" -s \
        || { mod_fail "systemctl start $BSC_UNIT a echoue"
             mod_hint "journalctl -u $BSC_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - c'est ici que l'ancien demarrage mentait le plus : le BSC etait
# lance, la BTS lancee juste apres, et personne ne verifiait que l'ecoute A-bis
# existait. Une BTS qui se connecte trop tot boucle en "OML link down" sans
# que rien ne l'indique.
mod_bsc_wait() {
    local to="${MOD_TIMEOUT[bsc]}" asp; asp="$(_bsc_asp_port)"

    if ! wait_until "$to" "VTY OsmoBSC ($BSC_VTY_PORT)" core_vty_listen "$BSC_VTY_PORT"; then
        mod_hint "journalctl -u $BSC_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "ecoute A-bis OML ($BSC_OML_PORT)" core_tcp_listen "$BSC_OML_PORT"; then
        mod_hint "port $BSC_OML_PORT deja pris par un autre BSC ? ss -ltn | grep $BSC_OML_PORT"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "ecoute A-bis RSL ($BSC_RSL_PORT)" core_tcp_listen "$BSC_RSL_PORT"; then
        mod_hint "port $BSC_RSL_PORT deja pris ? ss -ltn | grep $BSC_RSL_PORT"
        return $MOD_RC_FAIL
    fi
    if [ -n "$asp" ]; then
        if ! wait_until "$to" "lien M3UA vers le STP (SCTP local :$asp)" core_sctp_estab "$asp"; then
            mod_hint "STP joignable ? ss -an --sctp | grep $asp ; verifiez "asp ... m3ua" dans $(_bsc_cfg)"
            return $MOD_RC_FAIL
        fi
    else
        mod_say "aucun ASP m3ua dans $(_bsc_cfg) - barriere SS7 non applicable"
    fi
    if core_restarted_since "$BSC_UNIT"; then
        mod_hint "journalctl -u $BSC_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoBSC a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_bsc_stop() { core_svc_stop "$BSC_UNIT" "osmo-bsc -c"; }
