# =============================================================================
#  12-mgw - OsmoMGW, la passerelle media (MGCP / RTP)
# =============================================================================
#  ROLE      commute les flux RTP de la voix. Le MSC et le BSC lui ouvrent
#            chacun une session MGCP ; le MSC refuse d'etablir un appel si le
#            MGW ne repond pas (d'ou son demarrage AVANT le MSC).
#  PREREQUIS binaire osmo-mgw ; $OSMOCOM_CFG/osmo-mgw.cfg ; l'adresse de bind
#            MGCP doit etre portee localement.
#  SUCCES    VTY en ecoute (4243) ET socket MGCP UDP en ecoute sur l'adresse et
#            le port lus dans la conf (127.0.0.1:2427 par defaut) ET aucun
#            redemarrage depuis le lancement.
#  JOURNAL   journalctl -u osmo-mgw    (sans systemd : $LOG_DIR/osmo-mgw.log)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER mgw "Coeur - OsmoMGW (media MGCP/RTP)"
MOD_REQUIRED[mgw]=1
MOD_PROFILES[mgw]="calypso faketrx hybrid core"
MOD_JOURNAL[mgw]="osmo-mgw"
MOD_TIMEOUT[mgw]=25
MOD_ENABLED_IF[mgw]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${MGW_UNIT:=osmo-mgw}"
: "${MGW_VTY_PORT:=4243}"

_mgw_cfg()  { core_cfg osmo-mgw; }
_mgw_ip()   { core_cfg_field "$(_mgw_cfg)" '^[[:space:]]*bind[[:space:]]+ip[[:space:]]'   3 127.0.0.1; }
_mgw_port() { core_cfg_field "$(_mgw_cfg)" '^[[:space:]]*bind[[:space:]]+port[[:space:]]' 3 2427; }

mod_mgw_check() {
    core_bin osmo-mgw >/dev/null || { mod_fail "binaire osmo-mgw introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_mgw_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-mgw.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_mgw_cfg)"; return $MOD_RC_FAIL; }
    core_ip_local "$(_mgw_ip)" || {
        mod_hint "corrigez "mgcp / bind ip" dans $(_mgw_cfg), ou ajoutez l'adresse a une interface"
        mod_fail "adresse MGCP $(_mgw_ip) portee par aucune interface"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_mgw_status() { core_unit_active "$MGW_UNIT" || core_vty_listen "$MGW_VTY_PORT"; }

mod_mgw_start() {
    core_svc_start "$MGW_UNIT" "$(core_bin osmo-mgw)" -s -c "$(_mgw_cfg)" \
        || { mod_fail "systemctl start $MGW_UNIT a echoue"
             mod_hint "journalctl -u $MGW_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - le VTY ne dit rien du plan media : c'est la socket MGCP qui montre
# que le MGW acceptera les CRCX du MSC et du BSC.
mod_mgw_wait() {
    local to="${MOD_TIMEOUT[mgw]}" ip port
    ip="$(_mgw_ip)"; port="$(_mgw_port)"

    if ! wait_until "$to" "VTY OsmoMGW ($MGW_VTY_PORT)" core_vty_listen "$MGW_VTY_PORT"; then
        mod_hint "journalctl -u $MGW_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "MGCP UDP ($ip:$port)" core_udp_listen "$port" "$ip"; then
        mod_hint "port $port deja pris ? ss -lun | grep $port"
        return $MOD_RC_FAIL
    fi
    if core_restarted_since "$MGW_UNIT"; then
        mod_hint "journalctl -u $MGW_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoMGW a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_mgw_stop() { core_svc_stop "$MGW_UNIT" "osmo-mgw -s -c"; }
