# =============================================================================
#  60-bts - osmo-bts-trx : la station de base
# =============================================================================
#
#  ROLE        Lance osmo-bts-trx sur la cfg TRX. Il parle TRXD au transceiver
#              (UDP 5700+ cote TRX, 5800+ cote BTS) et OML/RSL au BSC.
#              Legacy : run.sh.legacy L2002-2009 - trois lignes, aucune
#              verification : une BTS qui n'arrive pas a joindre le BSC ou le
#              transceiver mourait en silence, et le mobile ne voyait jamais de
#              cellule sans que rien ne l'explique.
#
#  PREREQUIS   Transceiver pret (module trx-ipc, ou saute si on s'en passe),
#              coeur Osmocom demarre (le BSC accepte l'OML), cfg lisible.
#
#  SUCCES      Processus vivant ET VTY de la BTS (4241) joignable.
#              POURQUOI CE CRITERE : osmo-bts-trx sort tout de suite sur une
#              cfg invalide (phy inconnue, unit-id refuse) ; le VTY n'ecoute
#              qu'apres l'initialisation complete des phy/trx. C'est observable
#              sans dependre d'une chaine de journal, donc robuste aux versions.
#
#  CE QU'ON N'A PAS PU FIGER : le marqueur d'etablissement RSL dans bts.log.
#  Aucun bts.log reel n'existe sur cette machine ; poser un `log_has` sur une
#  chaine devinee aurait produit un faux echec permanent. On observe donc le
#  RSL de facon INFORMATIVE (mod_say), sans en faire une condition.
#
#  JOURNAL     $BTS_LOG (defaut $LOG_DIR/bts.log)
#
#  ATTENTION   osmo-bts-trx est aussi une unite systemd sur cette image, et
#              $OSMOCOM_CFG/status.sh l'arrete (module core). Si une unite est
#              active, mod_bts_status la voit et le module est saute : il n'y
#              aura jamais deux BTS concurrentes.
# -----------------------------------------------------------------------------

MOD_REGISTER bts "Station de base osmo-bts-trx"
MOD_REQUIRED[bts]=0
MOD_DEPS[bts]="trx-ipc"
MOD_PROFILES[bts]="calypso hybrid"
MOD_TIMEOUT[bts]=30
MOD_ENABLED_IF[bts]='[ "${CALYPSO_SKIP_BTS:-0}" != "1" ]'

: "${OSMO_BTS_TRX:=}"
: "${BTS_CFG:=${OSMOCOM_CFG:-/etc/osmocom}/osmo-bts-trx.cfg}"
: "${BTS_LOG:=${LOG_DIR:-/tmp/calypso/logs}/bts.log}"
: "${OSMO_VTY_BTS:=4241}"

mod_bts_check() {
    if [ -z "$OSMO_BTS_TRX" ] || [ ! -x "$OSMO_BTS_TRX" ]; then
        OSMO_BTS_TRX="$(command -v osmo-bts-trx 2>/dev/null)"
    fi
    [ -n "$OSMO_BTS_TRX" ] && [ -x "$OSMO_BTS_TRX" ] || {
        mod_hint "installez osmo-bts (cible trx) ou posez OSMO_BTS_TRX=<chemin> ; CALYPSO_SKIP_BTS=1 pour vous en passer"
        mod_fail "osmo-bts-trx introuvable"
        return $MOD_RC_FAIL
    }
    [ -r "$BTS_CFG" ] || {
        mod_hint "attendu : <OSMOCOM_CFG>/osmo-bts-trx.cfg - ou posez BTS_CFG=<chemin>"
        mod_fail "configuration de la BTS illisible : $BTS_CFG"
        return $MOD_RC_FAIL
    }
    # Le BSC doit ecouter l'OML, sinon la BTS boucle sur des reconnexions.
    # Non bloquant : c'est une information utile, pas une raison de ne pas
    # lancer (la BTS retente toute seule des que le BSC arrive).
    have_port "${OSMO_VTY_BSC:-4242}" || mod_say "AVERTISSEMENT : le VTY du BSC (${OSMO_VTY_BSC:-4242}) ne repond pas - l'OML risque de boucler"
    mod_say "binaire=$OSMO_BTS_TRX cfg=$BTS_CFG"
    mod_ok
}

# -x : nom EXACT. `pgrep -f osmo-bts` attraperait osmo-bts-virtual ou une ligne
# de commande qui mentionne le binaire (un tail, un grep de l'operateur).
mod_bts_status() { pgrep -x osmo-bts-trx >/dev/null 2>&1; }

mod_bts_start() {
    mkdir -p "${RUN_DIR:-/tmp/calypso}" "$(dirname "$BTS_LOG")" 2>/dev/null || true
    : > "$BTS_LOG" 2>/dev/null || true
    "$OSMO_BTS_TRX" -c "$BTS_CFG" >>"$BTS_LOG" 2>&1 &
    printf '%s\n' "$!" > "${RUN_DIR:-/tmp/calypso}/bts.pid"
    mod_ok
}

# BARRIERE NEUVE - le legacy ne verifiait rien du tout.
mod_bts_wait() {
    local pid; pid="$(cat "${RUN_DIR:-/tmp/calypso}/bts.pid" 2>/dev/null || echo 0)"

    if ! wait_until "${MOD_TIMEOUT[bts]}" "VTY de la BTS ($OSMO_VTY_BTS)" have_port "$OSMO_VTY_BTS"; then
        modb_tail "$BTS_LOG" 25
        if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
            mod_hint "causes frequentes : phy/instance absente de $BTS_CFG, ou unit-id deja pris par une autre BTS"
            mod_fail "osmo-bts-trx s'est arrete pendant son initialisation"
        else
            mod_hint "detail : $BTS_LOG"
            mod_fail "osmo-bts-trx tourne mais n'expose pas son VTY apres ${MOD_TIMEOUT[bts]}s"
        fi
        return $MOD_RC_FAIL
    fi

    if [ "$pid" != 0 ] && ! kill -0 "$pid" 2>/dev/null; then
        modb_tail "$BTS_LOG" 25
        mod_hint "une BTS residuelle (unite systemd ?) tient le VTY : systemctl stop osmo-bts-trx"
        mod_fail "le VTY $OSMO_VTY_BTS repond, mais ce n'est PAS notre processus (il est mort)"
        return $MOD_RC_FAIL
    fi

    # Observation informative, jamais bloquante (cf. en-tete).
    if grep -qi 'rsl' "$BTS_LOG" 2>/dev/null; then
        mod_say "RSL mentionne dans $BTS_LOG (lien vers le BSC en cours d'etablissement)"
    else
        mod_say "aucune mention de RSL dans $BTS_LOG pour l'instant - surveillez l'OML cote BSC"
    fi
    mod_ok
}

mod_bts_stop() {
    local pidf="${RUN_DIR:-/tmp/calypso}/bts.pid" pid
    pid="$(cat "$pidf" 2>/dev/null || echo 0)"
    [ "$pid" != 0 ] && kill "$pid" 2>/dev/null
    pkill -x osmo-bts-trx 2>/dev/null
    rm -f "$pidf"
    return 0
}
