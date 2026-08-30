# =============================================================================
#  10-stp - OsmoSTP, le point de transfert semaphore (SS7 / M3UA)
# =============================================================================
#  ROLE      tout le SS7 du coeur passe par lui : le MSC (PC 1.1.1) et le BSC
#            (PC 1.1.3) s'y raccordent comme ASP M3UA. Tant qu'il n'ecoute pas,
#            aucun des deux ne peut se parler - d'ou sa place en tete du bloc.
#  PREREQUIS binaire osmo-stp ; $OSMOCOM_CFG/osmo-stp.cfg ; support SCTP dans le
#            noyau (l'ecoute M3UA est du SCTP, pas du TCP).
#  SUCCES    VTY en ecoute (4239) ET socket M3UA SCTP en ecoute sur le port lu
#            dans la conf ("listen m3ua <port>") ET aucun redemarrage de
#            l'unite depuis notre lancement.
#  JOURNAL   journalctl -u osmo-stp    (sans systemd : $LOG_DIR/osmo-stp.log)
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER stp "Coeur - OsmoSTP (SS7/M3UA)"
MOD_REQUIRED[stp]=1
MOD_PROFILES[stp]="calypso faketrx hybrid core"
MOD_JOURNAL[stp]="osmo-stp"
MOD_TIMEOUT[stp]=25
# Echappatoire heritee de start-direct.sh : NO_OSMO_START=1 saute tout le coeur.
MOD_ENABLED_IF[stp]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${STP_UNIT:=osmo-stp}"
: "${STP_VTY_PORT:=4239}"

_stp_cfg()  { core_cfg osmo-stp; }
_stp_m3ua() { core_cfg_field "$(_stp_cfg)" '^[[:space:]]*listen[[:space:]]+m3ua[[:space:]]' 3 2905; }

mod_stp_check() {
    core_bin osmo-stp >/dev/null || {
        mod_hint "paquet osmo-stp absent - verifiez l'image, ou reglez OSMOCOM_CFG/PATH"
        mod_fail "binaire osmo-stp introuvable"; return $MOD_RC_FAIL; }
    [ -r "$(_stp_cfg)" ] || {
        mod_hint "deployez la configuration : cp configs/osmo-stp.cfg $OSMOCOM_CFG/"
        mod_fail "configuration illisible : $(_stp_cfg)"; return $MOD_RC_FAIL; }
    # Sans SCTP, osmo-stp demarre puis n'ecoute jamais : autant le dire ici.
    if [ ! -e /proc/net/sctp/snmp ] && ! lsmod 2>/dev/null | grep -q '^sctp'; then
        mod_hint "chargez le module cote hote : modprobe sctp (un conteneur ne peut pas le faire)"
        mod_fail "SCTP indisponible dans ce noyau - l'ecoute M3UA est impossible"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_stp_status() { core_unit_active "$STP_UNIT" || core_vty_listen "$STP_VTY_PORT"; }

mod_stp_start() {
    core_svc_start "$STP_UNIT" "$(core_bin osmo-stp)" -c "$(_stp_cfg)" \
        || { mod_fail "systemctl start $STP_UNIT a echoue"
             mod_hint "journalctl -u $STP_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - "actif" ne suffit pas : l'unite porte Restart=always, donc un STP
# qui meurt a l'init reapparait indefiniment sans jamais ouvrir son ecoute.
mod_stp_wait() {
    local to="${MOD_TIMEOUT[stp]}" m3ua; m3ua="$(_stp_m3ua)"

    if ! wait_until "$to" "VTY OsmoSTP ($STP_VTY_PORT)" core_vty_listen "$STP_VTY_PORT"; then
        mod_hint "journalctl -u $STP_UNIT -n 30 ; port $STP_VTY_PORT deja pris ?"
        return $MOD_RC_FAIL
    fi
    if ! wait_until "$to" "ecoute M3UA SCTP ($m3ua)" core_sctp_listen "$m3ua"; then
        mod_hint "verifiez "listen m3ua $m3ua" dans $(_stp_cfg) et le support SCTP (ss -ln --sctp)"
        return $MOD_RC_FAIL
    fi
    if core_restarted_since "$STP_UNIT"; then
        mod_hint "journalctl -u $STP_UNIT -n 50 : le service redemarre en boucle"
        mod_fail "OsmoSTP a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_stp_stop() { core_svc_stop "$STP_UNIT" "osmo-stp -c"; }
