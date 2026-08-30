# =============================================================================
#  63-osmo-bts-virtual - la BTS cote Um virtuel (variante "virtual" d'osmo-bts)
# =============================================================================
#
#  ROLE
#    Meme fonction que 62-osmo-bts-trx - porter l'Abis vers le BSC - mais sans
#    aucune couche physique : l'interface Um est remplacee par deux groupes
#    multicast UDP, sur lesquels virtphy publie et souscrit.
#
#        mobile <--L1CTL--> virtphy <--multicast UDP--> osmo-bts-virtual <--OML/RSL--> osmo-bsc
#
#    Ni transceiver, ni trxcon : c'est TOUTE la difference avec la chaine TRXD.
#
#  PREREQUIS
#    PHY_MODE=virtphy (sinon le module est desactive), $BTS_VIRTUAL_CFG lisible,
#    et EXCLUSION avec osmo-bts-trx : les deux variantes partagent la VTY 4241 et
#    l'unit-id IPA, elles ne peuvent pas coexister.
#
#  CRITERE DE SUCCES (barriere)
#    1. la VTY $BTS_VTY_PORT repond ;
#    2. le processus tient $BTS_STAB_SECS secondes sans motif fatal.
#    Meme forme que pour la variante TRXD, avec d'autres motifs : ici il n'y a
#    pas d'horloge de transceiver a perdre, mais un socket multicast a ouvrir.
#
#  JOURNAL     $LOG_DIR/osmo-bts-virtual.log
#
#  ORDRE       avant virtphy - c'est la BTS qui publie sur le groupe multicast.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER osmo-bts-virtual "BTS virtuelle (osmo-bts-virtual)"
MOD_REQUIRED[osmo-bts-virtual]=1
MOD_PROFILES[osmo-bts-virtual]="faketrx"
MOD_ENABLED_IF[osmo-bts-virtual]='[ "${PHY_MODE:-faketrx}" = "virtphy" ]'
MOD_JOURNAL[osmo-bts-virtual]="osmo-bts-virtual"
MOD_TIMEOUT[osmo-bts-virtual]=45

: "${BTS_VIRTUAL_BIN:=osmo-bts-virtual}"
: "${BTS_VIRTUAL_CFG:=${OSMOCOM_CFG:-/etc/osmocom}/osmo-bts-virtual.cfg}"
: "${BTS_STAB_SECS:=8}"
: "${BTS_VIRT_FATAL_RE:=BTS_SHUTDOWN|Shutting down|Failed to connect|Cannot connect|Unable to open|Could not join}"
MOD_LOG[osmo-bts-virtual]="${LOG_DIR}/osmo-bts-virtual.log"

mod_osmo_bts_virtual_check() {
    command -v "$BTS_VIRTUAL_BIN" >/dev/null 2>&1 || [ -x "$BTS_VIRTUAL_BIN" ] || {
        mod_fail "binaire introuvable : $BTS_VIRTUAL_BIN"
        mod_hint "installez osmo-bts (variante virtual), ou posez BTS_VIRTUAL_BIN"
        return $MOD_RC_FAIL; }
    [ -r "$BTS_VIRTUAL_CFG" ] || {
        mod_fail "configuration illisible : $BTS_VIRTUAL_CFG"
        mod_hint "posez BTS_VIRTUAL_CFG, ou deployez /etc/osmocom/osmo-bts-virtual.cfg"
        return $MOD_RC_FAIL; }

    if pgrep -x osmo-bts-trx >/dev/null 2>&1; then
        mod_fail "osmo-bts-trx tourne deja (VTY $BTS_VTY_PORT occupee)"
        mod_hint "les deux BTS sont exclusives : ./run.sh --stop, ou PHY_MODE=faketrx"
        return $MOD_RC_FAIL
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet osmo-bts-trx 2>/dev/null; then
        mod_fail "l'unite systemd osmo-bts-trx est active - elle tient la VTY $BTS_VTY_PORT"
        mod_hint "systemctl stop osmo-bts-trx"
        return $MOD_RC_FAIL
    fi

    # Le plan multicast, pour le journal : virtphy doit viser les memes groupes.
    local bg bp mg mp
    bg="$(radio_cfg_val "$BTS_VIRTUAL_CFG" "virtual-um bts-mcast-group")"
    bp="$(radio_cfg_val "$BTS_VIRTUAL_CFG" "virtual-um bts-mcast-port")"
    mg="$(radio_cfg_val "$BTS_VIRTUAL_CFG" "virtual-um ms-mcast-group")"
    mp="$(radio_cfg_val "$BTS_VIRTUAL_CFG" "virtual-um ms-mcast-port")"
    mod_say "multicast BTS -> ${bg:-239.193.23.1}:${bp:-23001} · MS -> ${mg:-239.193.23.2}:${mp:-23002} (defauts si vide)"
    mod_ok
}

mod_osmo_bts_virtual_status() { pgrep -x osmo-bts-virtual >/dev/null 2>&1; }

mod_osmo_bts_virtual_start() {
    radio_dirs
    local log; log="$(radio_log osmo-bts-virtual)"
    mod_say "commande : $BTS_VIRTUAL_BIN -c $BTS_VIRTUAL_CFG"
    mod_say "journal  : $log"
    "$BTS_VIRTUAL_BIN" -c "$BTS_VIRTUAL_CFG" >>"$log" 2>&1 &
    radio_save_pid osmo-bts-virtual $!
    mod_ok
}

# BARRIERE - VTY puis fenetre de stabilite.
mod_osmo_bts_virtual_wait() {
    local log; log="$(radio_log osmo-bts-virtual)"

    wait_until "${MOD_TIMEOUT[osmo-bts-virtual]}" "VTY du BTS virtuel ($BTS_VTY_PORT)" \
        have_port "$BTS_VTY_PORT" || {
            mod_hint "fin de $log ; VTY deja prise par osmo-bts-trx ? ss -tlnp | grep :$BTS_VTY_PORT"
            return $MOD_RC_FAIL; }

    radio_stable osmo-bts-virtual "$log" "$BTS_STAB_SECS" "$BTS_VIRT_FATAL_RE" || {
        mod_hint "multicast indisponible ? verifiez que l'interface de bouclage porte une route multicast (ip route show table local)"
        return $MOD_RC_FAIL; }
    mod_ok
}

mod_osmo_bts_virtual_stop() {
    radio_kill osmo-bts-virtual "osmo-bts-virtual -c"
    pkill -x osmo-bts-virtual 2>/dev/null
    return 0
}
