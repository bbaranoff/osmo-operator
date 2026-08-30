# =============================================================================
#  62-osmo-bts-trx - la BTS cote TRXD (variante "trx" d'osmo-bts)
# =============================================================================
#
#  ROLE
#    Termine la couche 1 du cote reseau et porte l'Abis (OML + RSL) vers le BSC :
#
#        transceiver <--TRXD--> osmo-bts-trx <--OML/RSL (IPA 3002/3003)--> osmo-bsc
#
#    Le transceiver en face est fake_trx (defaut) ou osmo-trx, selon
#    RADIO_TRANSCEIVER - d'ou la double dependance declaree plus bas.
#
#  PERIMETRE - NE PAS CONFONDRE AVEC 60-bts
#    60-bts.sh est la BTS de la chaine de l'emulateur (profils calypso/hybrid).
#    Celle-ci est la BTS du profil "faketrx". Les deux sont exclusives : meme
#    VTY 4241, meme unit-id IPA - le check ci-dessous refuse de demarrer si
#    l'autre tourne deja.
#
#  PREREQUIS
#    - un transceiver qui ecoute deja sur $TRX_BASE_PORT ;
#    - $BTS_TRX_CFG lisible, et son `osmotrx base-port remote` coherent avec ce
#      port : une incoherence ici produit exactement le symptome le plus couteux
#      du projet - un BTS qui demarre, ouvre sa VTY, et meurt trente secondes
#      plus tard sur "No clock since TRX" sans que personne ne fasse le lien ;
#    - EXCLUSION : osmo-bts-virtual ne doit pas tourner (meme port VTY 4241) ;
#    - EXCLUSION : l'unite systemd osmo-bts-trx ne doit pas etre active, sinon
#      deux BTS se disputent le meme unit-id IPA.
#
#  CRITERE DE SUCCES (barriere) - en deux temps, positif puis negatif
#    1. la VTY $BTS_VTY_PORT repond   -> le processus est alle au bout de son init ;
#    2. il TIENT $BTS_STAB_SECS secondes sans imprimer de motif fatal.
#    Le second point est celui qui compte : c'est la reprise de la fenetre de
#    stabilite deja eprouvee dans l'ancien lancement hybride.
#
#  JOURNAL     $LOG_DIR/osmo-bts-trx.log  (+ journal systemd si l'unite existe)
#
#  ORDRE       apres le transceiver, avant trxcon et le mobile.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER osmo-bts-trx "BTS radio (osmo-bts-trx)"
MOD_REQUIRED[osmo-bts-trx]=1
MOD_PROFILES[osmo-bts-trx]="faketrx"
MOD_ENABLED_IF[osmo-bts-trx]='[ "${PHY_MODE:-faketrx}" != "virtphy" ]'
MOD_JOURNAL[osmo-bts-trx]="osmo-bts-trx"
MOD_TIMEOUT[osmo-bts-trx]=45

# DEPENDANCE CROISEE : le transceiver est fake-trx OU osmo-trx, jamais les deux.
# On declare les deux - le moteur considere un prerequis "ignore" comme
# satisfait, donc celui qui est desactive par RADIO_TRANSCEIVER ne bloque rien.
MOD_DEPS[osmo-bts-trx]="fake-trx osmo-trx"

: "${BTS_TRX_BIN:=osmo-bts-trx}"
: "${BTS_TRX_CFG:=${OSMOCOM_CFG:-/etc/osmocom}/osmo-bts-trx.cfg}"
: "${BTS_STAB_SECS:=8}"
: "${BTS_FATAL_RE:=No clock since TRX|BTS_SHUTDOWN|Shutting down|Failed to connect|Cannot connect}"
MOD_LOG[osmo-bts-trx]="${LOG_DIR}/osmo-bts-trx.log"

mod_osmo_bts_trx_check() {
    command -v "$BTS_TRX_BIN" >/dev/null 2>&1 || [ -x "$BTS_TRX_BIN" ] || {
        mod_fail "binaire introuvable : $BTS_TRX_BIN"
        mod_hint "installez osmo-bts, ou posez BTS_TRX_BIN=/chemin/vers/osmo-bts-trx"
        return $MOD_RC_FAIL; }
    [ -r "$BTS_TRX_CFG" ] || {
        mod_fail "configuration illisible : $BTS_TRX_CFG"
        mod_hint "posez BTS_TRX_CFG, ou deployez /etc/osmocom/osmo-bts-trx.cfg"
        return $MOD_RC_FAIL; }

    # Exclusion mutuelle avec la variante virtuelle : meme VTY, meme unit-id.
    if pgrep -x osmo-bts-virtual >/dev/null 2>&1; then
        mod_fail "osmo-bts-virtual tourne deja (VTY $BTS_VTY_PORT occupee)"
        mod_hint "les deux BTS sont exclusives : ./run.sh --stop, ou PHY_MODE=virtphy"
        return $MOD_RC_FAIL
    fi
    # Exclusion avec l'instance systemd, qui vole l'unit-id IPA.
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet osmo-bts-trx 2>/dev/null; then
        mod_fail "l'unite systemd osmo-bts-trx est deja active"
        mod_hint "systemctl stop osmo-bts-trx (deux BTS avec le meme unit-id se chassent l'une l'autre)"
        return $MOD_RC_FAIL
    fi

    # Coherence port : la conf dit vers quel transceiver le BTS va parler.
    local want; want="$(radio_cfg_val "$BTS_TRX_CFG" "osmotrx base-port remote")"
    [ -n "$want" ] || want=5700
    if [ "$want" != "$TRX_BASE_PORT" ]; then
        mod_fail "conf et plan d'adressage divergent : le BTS vise $want, le transceiver ecoute sur $TRX_BASE_PORT"
        mod_hint "alignez "osmotrx base-port remote" dans $BTS_TRX_CFG, ou posez TRX_BASE_PORT=$want"
        return $MOD_RC_FAIL
    fi
    # Le transceiver ecoute-t-il ? Diagnostic anticipe, pas un blocage : le BTS
    # sait attendre, mais autant le dire dans son journal.
    radio_udp_range "$TRX_BASE_PORT" \
        || mod_say "ATTENTION : aucun socket TRXD sur $TRX_BASE_PORT..+2 - le BTS restera sans horloge"
    mod_ok
}

mod_osmo_bts_trx_status() { pgrep -x osmo-bts-trx >/dev/null 2>&1; }

mod_osmo_bts_trx_start() {
    radio_dirs
    local log; log="$(radio_log osmo-bts-trx)"
    mod_say "commande : $BTS_TRX_BIN -c $BTS_TRX_CFG"
    mod_say "transceiver vise : $TRX_BASE_PORT"
    mod_say "journal  : $log"
    "$BTS_TRX_BIN" -c "$BTS_TRX_CFG" >>"$log" 2>&1 &
    radio_save_pid osmo-bts-trx $!
    mod_ok
}

# BARRIERE - VTY (positif) puis fenetre de stabilite (negatif).
mod_osmo_bts_trx_wait() {
    local log; log="$(radio_log osmo-bts-trx)"

    wait_until "${MOD_TIMEOUT[osmo-bts-trx]}" "VTY du BTS ($BTS_VTY_PORT)" \
        have_port "$BTS_VTY_PORT" || {
            mod_hint "fin de $log ; port VTY deja pris ? ss -tlnp | grep :$BTS_VTY_PORT"
            return $MOD_RC_FAIL; }

    radio_stable osmo-bts-trx "$log" "$BTS_STAB_SECS" "$BTS_FATAL_RE" || {
        mod_hint ""No clock since TRX" = le transceiver ne repond pas sur $TRX_BASE_PORT : verifiez fake-trx / osmo-trx"
        return $MOD_RC_FAIL; }

    # Renseignement : l'Abis est-il monte ? Utile au diagnostic "BTS vivante
    # mais BSC absent", sans en faire un critere (le BSC n'est pas toujours
    # dans le plan).
    if command -v ss >/dev/null 2>&1 && ss -tan 2>/dev/null | grep -qE 'ESTAB.*:(3002|3003)'; then
        mod_say "Abis etabli vers le BSC (OML/RSL)"
    else
        mod_say "pas de connexion Abis etablie (BSC absent du plan ?)"
    fi
    mod_ok
}

mod_osmo_bts_trx_stop() {
    command -v systemctl >/dev/null 2>&1 && systemctl stop osmo-bts-trx 2>/dev/null
    radio_kill osmo-bts-trx "osmo-bts-trx -c"
    pkill -x osmo-bts-trx 2>/dev/null
    return 0
}
