# =============================================================================
#  11-hlr - OsmoHLR, le registre des abonnes (GSUP)
# =============================================================================
#  ROLE      detient les IMSI, les cles Ki et les MSISDN. Le MSC et le SGSN s'y
#            connectent en GSUP au demarrage ; sans HLR, aucun rattachement
#            (Location Update) n'aboutit. C'est le seul service que l'ancien
#            osmo-start.sh considerait comme fatal (osmo-start.sh:84-87).
#  PREREQUIS binaire osmo-hlr ; $OSMOCOM_CFG/osmo-hlr.cfg ; repertoire de la
#            base sqlite accessible en ecriture (/var/lib/osmocom).
#  SUCCES    VTY en ecoute (4258) ET port GSUP en ecoute sur l'adresse declaree
#            dans la conf ("gsup / bind ip", 127.0.0.2:4222 par defaut) ET
#            aucun redemarrage depuis le lancement.
#  JOURNAL   journalctl -u osmo-hlr    (sans systemd : $LOG_DIR/osmo-hlr.log)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER hlr "Coeur - OsmoHLR (registre GSUP)"
MOD_REQUIRED[hlr]=1
MOD_PROFILES[hlr]="calypso faketrx hybrid core"
MOD_JOURNAL[hlr]="osmo-hlr"
MOD_TIMEOUT[hlr]=30
MOD_ENABLED_IF[hlr]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${HLR_UNIT:=osmo-hlr}"
: "${HLR_VTY_PORT:=4258}"
: "${HLR_GSUP_PORT:=4222}"
: "${HLR_DB:=/var/lib/osmocom/hlr.db}"

_hlr_cfg()     { core_cfg osmo-hlr; }
_hlr_gsup_ip() { core_cfg_field "$(_hlr_cfg)" '^[[:space:]]*bind[[:space:]]+ip[[:space:]]' 3 127.0.0.2; }

mod_hlr_check() {
    core_bin osmo-hlr >/dev/null || {
        mod_fail "binaire osmo-hlr introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_hlr_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-hlr.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_hlr_cfg)"; return $MOD_RC_FAIL; }
    local dbdir; dbdir="$(dirname "$HLR_DB")"
    [ -d "$dbdir" ] || {
        mod_hint "mkdir -p $dbdir && chown osmocom:osmocom $dbdir"
        mod_fail "repertoire de base absent : $dbdir"; return $MOD_RC_FAIL; }
    core_ip_local "$(_hlr_gsup_ip)" || {
        mod_hint "ip addr add $(_hlr_gsup_ip)/24 dev lo, ou changez "gsup / bind ip" dans $(_hlr_cfg)"
        mod_fail "adresse GSUP $(_hlr_gsup_ip) portee par aucune interface"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_hlr_status() { core_unit_active "$HLR_UNIT" || core_vty_listen "$HLR_VTY_PORT"; }

mod_hlr_start() {
    core_svc_start "$HLR_UNIT" "$(core_bin osmo-hlr)" -c "$(_hlr_cfg)" -l "$HLR_DB" \
        || { mod_fail "systemctl start $HLR_UNIT a echoue"
             mod_hint "journalctl -u $HLR_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - le VTY monte avant que la base soit ouverte ; c'est le port GSUP
# qui prouve que le HLR peut reellement servir MSC et SGSN.
mod_hlr_wait() {
    local to="${MOD_TIMEOUT[hlr]}" gip; gip="$(_hlr_gsup_ip)"

    if ! wait_until "$to" "VTY OsmoHLR ($HLR_VTY_PORT)" core_vty_listen "$HLR_VTY_PORT"; then
        mod_hint "journalctl -u $HLR_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "GSUP ($gip:$HLR_GSUP_PORT)" core_tcp_listen "$HLR_GSUP_PORT" "$gip"; then
        mod_hint "base verrouillee ou illisible ? ls -l $HLR_DB ; journalctl -u $HLR_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if core_restarted_since "$HLR_UNIT"; then
        mod_hint "journalctl -u $HLR_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoHLR a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_hlr_stop() { core_svc_stop "$HLR_UNIT" "osmo-hlr -c"; }
