# =============================================================================
#  01-profil - profil d'emulation et propagation des reglages      (module PUR)
# =============================================================================
#
#  ROLE
#      Ne lance rien, ne cree rien. Verifie que environment/load.env a produit
#      une configuration COHERENTE, et surtout qu'elle franchit la frontiere de
#      processus : c'est par l'environnement exporte, et par rien d'autre, que
#      les CALYPSO_* atteignent QEMU. Un `set -a` oublie dans run.sh ne se
#      verrait nulle part - le modele demarrerait avec ses defauts, et le
#      manifeste imprime contredirait la ligne de commande sans que personne
#      ne le remarque.
#
#  PREREQUIS
#      run.sh a source environment/load.env sous `set -a` AVANT de sourcer les
#      modules (run.sh:75-80). Aucun autre module.
#
#  CRITERE DE SUCCES
#      1. CALYPSO_MODE vaut un des profils declares par modes.env ;
#      2. les variables structurantes sont non vides (GSM_ROOT, QEMU_TREE,
#         QEMU_BIN, RUN_DIR, LOG_DIR) ;
#      3. aucun melange de profils (bequilles "natif aide" allumees alors que
#         le profil demande est shunt_legit, ou l'inverse) ;
#      4. BARRIERE - un processus ENFANT reel voit CALYPSO_MODE et QEMU_BIN dans
#         son environnement. C'est le seul critere qui prouve l'export.
#
#  JOURNAL
#      $LOG_DIR/mod/profil.log : manifeste des variables retenues, a comparer au
#      manifeste imprime par le modele (grep calypso-manifest sur qemu.log).
#      La verite est le manifeste de QEMU, jamais la ligne de commande.
# -----------------------------------------------------------------------------
MOD_REGISTER profil "Profil d'emulation et propagation"
MOD_REQUIRED[profil]=1
MOD_PURE[profil]=1
MOD_PROFILES[profil]="calypso faketrx hybrid core"
MOD_TIMEOUT[profil]=10

# Profils connus - doit rester aligne sur le `case` de environment/modes.env.
: "${CONFIG_MODES_CONNUS:=shunt_legit native native_helped}"

mod_profil_check() {
    local m="${CALYPSO_MODE:-}" connu=0 x

    if [ -z "$m" ]; then
        mod_hint "environment/load.env n'a pas ete source : lancez ./launch/start-oqc.sh, pas les modules a la main"
        mod_fail "CALYPSO_MODE non defini - la configuration n'a pas ete chargee"
        return $MOD_RC_FAIL
    fi
    for x in $CONFIG_MODES_CONNUS; do [ "$x" = "$m" ] && connu=1; done
    if [ $connu -eq 0 ]; then
        mod_hint "profils disponibles : $CONFIG_MODES_CONNUS (voir environment/modes.env)"
        mod_fail "CALYPSO_MODE inconnu : "$m" - aucun profil n'a ete applique"
        return $MOD_RC_FAIL
    fi

    local manquantes=""
    for x in GSM_ROOT QEMU_TREE QEMU_BIN RUN_DIR LOG_DIR; do
        [ -n "${!x:-}" ] || manquantes="$manquantes $x"
    done
    if [ -n "$manquantes" ]; then
        mod_hint "ces variables sont posees par environment/paths.env - verifiez qu'il est lisible"
        mod_fail "configuration incomplete :$manquantes"
        return $MOD_RC_FAIL
    fi

    # Melange de profils. modes.env n'utilise que `:=` : une variable heritee de
    # l'environnement de l'appelant survit au profil et le contredit en silence.
    if [ "$m" = "shunt_legit" ] && [ "${CALYPSO_NATIVE_HELPED:-0}" = 1 ]; then
        mod_hint "unset CALYPSO_NATIVE_HELPED, ou passez CALYPSO_MODE=native_helped"
        mod_fail "profils melanges : CALYPSO_MODE=shunt_legit mais CALYPSO_NATIVE_HELPED=1"
        return $MOD_RC_FAIL
    fi
    if [ "$m" != "shunt_legit" ] && [ "${CALYPSO_SHUNT_LEGIT:-0}" = 1 ]; then
        mod_hint "unset CALYPSO_SHUNT_LEGIT, ou repassez en CALYPSO_MODE=shunt_legit"
        mod_fail "profils melanges : CALYPSO_MODE=$m mais CALYPSO_SHUNT_LEGIT=1"
        return $MOD_RC_FAIL
    fi

    # Signale, pas fatal : le binaire peut legitimement venir d'un arbre voisin
    # (paths.env retombe sur $GSM_ROOT/osmo-qemu-calypso/build s'il n'y a pas de build local).
    case "${QEMU_BIN:-}" in
        "${QEMU_TREE:-}"/*) : ;;
        *) mod_say "ATTENTION : QEMU_BIN ($QEMU_BIN) n'appartient pas a QEMU_TREE ($QEMU_TREE)" ;;
    esac
    mod_ok
}

# Module pur : il n'y a rien a "demarrer", donc jamais "deja demarre".
mod_profil_status() { return $MOD_RC_FAIL; }

# Aucun effet de bord : on ne fait qu'ecrire le manifeste dans le journal du
# module (run.sh redirige la sortie ; les modules n'ecrivent pas sur la console).
mod_profil_start() {
    mod_say "profil        : ${CALYPSO_MODE}"
    mod_say "arbre         : ${QEMU_TREE}"
    mod_say "binaire QEMU  : ${QEMU_BIN}"
    mod_say "execution     : ${RUN_DIR}"
    mod_say "journaux      : ${LOG_DIR}"
    mod_say "--- CALYPSO_* exportes (le modele ne verra que ceux-la) ---"
    env | grep '^CALYPSO_' | sort
    mod_ok
}

# Un enfant voit-il la configuration ? `bash -c` n'herite que des variables
# EXPORTEES : c'est exactement ce que verra QEMU.
_profil_enfant_voit() {
    local out
    out="$(bash -c 'printf "%s|%s" "${CALYPSO_MODE:-}" "${QEMU_BIN:-}"' 2>/dev/null)"
    case "$out" in
        ''|"|"*|*"|") return 1 ;;
    esac
    return 0
}

mod_profil_wait() {
    if ! wait_until "${MOD_TIMEOUT[profil]}" "configuration exportee" _profil_enfant_voit; then
        mod_hint "run.sh doit sourcer load.env sous "set -a" (run.sh:75-80) : sans export, QEMU demarre avec ses defauts"
        mod_fail "la configuration n'atteint pas les processus enfants"
        return $MOD_RC_FAIL
    fi
    mod_ok
}
