# =============================================================================
#  16-ggsn - OsmoGGSN, la sortie paquet (GTP)
# =============================================================================
#  ROLE      termine les tunnels GTP du SGSN et route le trafic de l'abonne
#            vers l'APN (interface TUN). Sans lui, pas de contexte PDP : la
#            data GPRS/EDGE ne s'etablit pas. Optionnel pour la voix et le SMS.
#  PREREQUIS binaire et conf osmo-ggsn ; l'interface TUN de l'APN ; l'adresse
#            "gtp bind-ip" doit etre portee par une interface locale.
#  SUCCES    VTY en ecoute (4260) ET les deux sockets GTP UDP en ecoute sur
#            l'adresse de bind (2123 controle, 2152 utilisateur) ET aucun
#            redemarrage depuis le lancement.
#  JOURNAL   journalctl -u osmo-ggsn   (sans systemd : $LOG_DIR/osmo-ggsn.log)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER ggsn "Coeur - OsmoGGSN (data GTP)"
MOD_REQUIRED[ggsn]=0
MOD_DEPS[ggsn]="apn0"
MOD_PROFILES[ggsn]="calypso faketrx hybrid core"
MOD_JOURNAL[ggsn]="osmo-ggsn"
MOD_TIMEOUT[ggsn]=25
MOD_ENABLED_IF[ggsn]='[ "${NO_OSMO_START:-0}" != 1 ] && [ "${CORE_GPRS:-1}" = 1 ]'

: "${GGSN_UNIT:=osmo-ggsn}"
: "${GGSN_VTY_PORT:=4260}"
: "${GGSN_GTPC_PORT:=2123}"
: "${GGSN_GTPU_PORT:=2152}"

_ggsn_cfg() { core_cfg osmo-ggsn; }
_ggsn_ip()  { core_cfg_field "$(_ggsn_cfg)" '^[[:space:]]*gtp[[:space:]]+bind-ip[[:space:]]' 3 ""; }

mod_ggsn_check() {
    core_bin osmo-ggsn >/dev/null || { mod_fail "binaire osmo-ggsn introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_ggsn_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-ggsn.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_ggsn_cfg)"; return $MOD_RC_FAIL; }
    local ip; ip="$(_ggsn_ip)"
    [ -n "$ip" ] || { mod_fail ""gtp bind-ip" absent de $(_ggsn_cfg)"; return $MOD_RC_FAIL; }
    core_ip_local "$ip" || {
        mod_hint "corrigez "gtp bind-ip" dans $(_ggsn_cfg) : aucune interface ne porte $ip"
        mod_fail "adresse GTP $ip introuvable localement - le GGSN refusera de demarrer"
        return $MOD_RC_FAIL; }
    mod_ok
}

mod_ggsn_status() { core_unit_active "$GGSN_UNIT" || core_vty_listen "$GGSN_VTY_PORT"; }

mod_ggsn_start() {
    core_svc_start "$GGSN_UNIT" "$(core_bin osmo-ggsn)" -c "$(_ggsn_cfg)" \
        || { mod_fail "systemctl start $GGSN_UNIT a echoue"
             mod_hint "journalctl -u $GGSN_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - le GGSN peut etre "actif" et n'avoir ouvert aucun tunnel s'il
# n'a pas pu se lier a son adresse GTP ou attacher son interface TUN.
mod_ggsn_wait() {
    local to="${MOD_TIMEOUT[ggsn]}" ip; ip="$(_ggsn_ip)"

    if ! wait_until "$to" "VTY OsmoGGSN ($GGSN_VTY_PORT)" core_vty_listen "$GGSN_VTY_PORT"; then
        mod_hint "journalctl -u $GGSN_UNIT -n 30"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "GTP-C ($ip:$GGSN_GTPC_PORT)" core_udp_listen "$GGSN_GTPC_PORT" "$ip"; then
        mod_hint "l'interface TUN de l'APN est-elle montee ? ip link show ${APN_DEV:-apn0}"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "GTP-U ($ip:$GGSN_GTPU_PORT)" core_udp_listen "$GGSN_GTPU_PORT" "$ip"; then
        mod_hint "port $GGSN_GTPU_PORT deja pris ? ss -lun | grep $GGSN_GTPU_PORT"
        return $MOD_RC_FAIL
    fi
    if core_restarted_since "$GGSN_UNIT"; then
        mod_hint "journalctl -u $GGSN_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoGGSN a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_ggsn_stop() { core_svc_stop "$GGSN_UNIT" "osmo-ggsn -c"; }
