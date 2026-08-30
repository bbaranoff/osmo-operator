# =============================================================================
#  66-mobile - le mobile Osmocom (couches 2 et 3, layer23)
# =============================================================================
#
#  ROLE
#    Le dernier maillon : la pile L2/L3 du telephone. Il ne connait qu'une seule
#    chose de tout ce qui precede - une socket L1CTL - et se moque de savoir qui
#    la sert :
#
#        osmocon (firmware Calypso sous QEMU)  ┐
#        trxcon  (chaine TRXD)                 ├─> socket L1CTL ─> mobile ─> VTY 4247
#        virtphy (chaine multicast)            ┘
#
#    Dans le profil "faketrx" ce producteur est trxcon ou virtphy selon
#    PHY_MODE : les deux sont declares en prerequis, et le moteur traite celui
#    qui est desactive comme satisfait.
#
#  PERIMETRE - NE PAS CONFONDRE AVEC 70-l2
#    70-l2.sh lance le client de couche 2 de la chaine de l'emulateur (profils
#    calypso/hybrid), derriere osmocon. Celui-ci est le mobile du profil
#    "faketrx". Les deux se disputeraient la VTY 4247 : ils ne partagent
#    aucun profil.
#
#  PREREQUIS
#    $MOBILE_CFG lisible. Le module en EXTRAIT la socket L1CTL (`layer2-socket`)
#    et le port VTY (`line vty` / `bind`) plutot que de les supposer : c'est la
#    conf qui fait foi, et c'est la qu'est l'erreur classique - osmocon expose
#    /tmp/osmocom_l2 (sans suffixe), trxcon et virtphy exposent
#    /tmp/osmocom_l2_<n>. Une conf qui vise la mauvaise reste muette pour
#    toujours.
#
#  CRITERE DE SUCCES (barriere)
#    Le processus vit ET sa VTY repond. La VTY n'est pas decorative : elle
#    n'ouvre qu'apres l'initialisation complete de la pile, donc elle distingue
#    "lance" de "pret a recevoir des commandes". La suite (selection de
#    cellule, LU) n'est PAS un critere de demarrage : elle depend du reseau,
#    pas de ce module.
#
#  JOURNAL     $LOG_DIR/mobile.log
#
#  ORDRE       en dernier - apres trxcon ou virtphy.
# -----------------------------------------------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER mobile "Mobile Osmocom (layer23)"
MOD_REQUIRED[mobile]=1
MOD_PROFILES[mobile]="faketrx"
MOD_TIMEOUT[mobile]=60

# DEPENDANCE CROISEE : la socket L1CTL vient de trxcon OU de virtphy selon
# PHY_MODE. On declare les deux ; celui qui est desactive compte comme satisfait.
MOD_DEPS[mobile]="trxcon virtphy"

: "${MOBILE_BIN:=mobile}"
: "${MOBILE_CFG:=${OSMOCOM_HOME:-$HOME/.osmocom}/bb/mobile_group1.cfg}"
: "${MOBILE_L1CTL_TIMEOUT:=60}"
# Categories de trace du mobile (separateur ":", pas ",").
: "${MOBILE_DEBUG:=DCS:DNB:DPLMN:DRR:DMM:DSIM:DCC:DMNCC:DSS:DLSMS:DPAG:DSUM:DSAP:DMOB:DPRIM}"
MOD_LOG[mobile]="${LOG_DIR}/mobile.log"

# --- ce que dit la conf, pas ce qu'on suppose --------------------------------
_mobile_l2_sock() { radio_cfg_val "$MOBILE_CFG" "layer2-socket"; }
_mobile_vty_port() {
    awk '/^[[:space:]]*line vty/{v=1; next}
         v && /^[[:space:]]*bind[[:space:]]/{print $3; exit}' "$MOBILE_CFG" 2>/dev/null
}
# Sockets L1CTL reellement presentes - sert a rendre l'echec actionnable.
_mobile_sockets_present() {
    local s found=""
    for s in "$L2_SOCK_BASE" "$L2_SOCK_BASE"_*; do
        [ -S "$s" ] && found="$found $s"
    done
    printf '%s' "${found:- aucune}"
}

mod_mobile_check() {
    command -v "$MOBILE_BIN" >/dev/null 2>&1 || [ -x "$MOBILE_BIN" ] || {
        mod_fail "binaire introuvable : $MOBILE_BIN"
        mod_hint "installez osmocom-bb (host/layer23), ou posez MOBILE_BIN"
        return $MOD_RC_FAIL; }
    [ -r "$MOBILE_CFG" ] || {
        mod_fail "configuration illisible : $MOBILE_CFG"
        mod_hint "posez MOBILE_CFG, ou deployez cfgs/mobile_group1.cfg dans ${OSMOCOM_HOME:-\$HOME/.osmocom}/bb/"
        return $MOD_RC_FAIL; }

    local s v; s="$(_mobile_l2_sock)"; v="$(_mobile_vty_port)"
    [ -n "$s" ] || {
        mod_fail "aucune directive "layer2-socket" dans $MOBILE_CFG"
        mod_hint "ajoutez "layer2-socket <chemin>" sous le bloc "ms 1""
        return $MOD_RC_FAIL; }
    # COHERENCE - l'erreur la plus couteuse de la chaine, attrapee AVANT le
    # lancement plutot qu'apres soixante secondes d'attente muette : la conf
    # nomme une socket que personne ne servira. On ne condamne que si elle
    # n'existe pas deja (quelqu'un d'autre peut legitimement la servir).
    local exp; exp="$(radio_l2_sock 1)"
    if [ "$s" != "$exp" ] && [ ! -S "$s" ]; then
        mod_fail "la conf vise $s, mais la couche 1 du profil expose $exp"
        mod_hint "corrigez "layer2-socket $exp" dans $MOBILE_CFG, ou posez L2_SOCK_BASE=${s%_*}"
        return $MOD_RC_FAIL
    fi

    mod_say "socket L1CTL attendue : $s"
    mod_say "VTY declaree : ${v:-$MOBILE_VTY_PORT (defaut, aucun "bind" dans la conf)}"
    mod_ok
}

mod_mobile_status() { pgrep -f "$MOBILE_BIN -c $MOBILE_CFG" >/dev/null 2>&1; }

# Le mobile doit attendre SA socket : la lancer avant, c'est un mobile qui sort
# en erreur "cannot connect" sans rien laisser d'exploitable. Cette attente est
# une synchronisation de demarrage, bornee, pas un `sleep`.
mod_mobile_start() {
    radio_dirs
    local log s; log="$(radio_log mobile)"; s="$(_mobile_l2_sock)"

    if ! wait_until "$MOBILE_L1CTL_TIMEOUT" "socket L1CTL $s" have_unix "$s"; then
        mod_fail "socket L1CTL jamais apparue : $s (presentes :$(_mobile_sockets_present) )"
        mod_hint "alignez "layer2-socket" de $MOBILE_CFG sur son producteur - osmocon expose ${L2_SOCK_BASE}, trxcon/virtphy exposent ${L2_SOCK_BASE}_<n>"
        return $MOD_RC_FAIL
    fi

    mod_say "commande : $MOBILE_BIN -c $MOBILE_CFG -d $MOBILE_DEBUG"
    mod_say "journal  : $log"
    "$MOBILE_BIN" -c "$MOBILE_CFG" -d "$MOBILE_DEBUG" >>"$log" 2>&1 &
    radio_save_pid mobile $!
    mod_ok
}

# BARRIERE - la VTY n'ouvre qu'une fois la pile initialisee.
mod_mobile_wait() {
    local log vty; log="$(radio_log mobile)"
    vty="$(_mobile_vty_port)"; [ -n "$vty" ] || vty="$MOBILE_VTY_PORT"

    wait_until "${MOD_TIMEOUT[mobile]}" "VTY du mobile ($vty)" have_port "$vty" || {
        mod_hint "fin de $log ; port deja pris par un autre mobile ? ss -tlnp | grep :$vty"
        return $MOD_RC_FAIL; }

    radio_alive mobile || {
        mod_fail "le mobile a ouvert sa VTY puis s'est arrete"
        mod_hint "fin de $log"
        return $MOD_RC_FAIL; }

    # Renseignement : la suite (cellule trouvee, LU) depend du reseau, elle ne
    # peut pas conditionner le demarrage de ce module.
    mod_say "pret - suivre la selection de cellule : telnet 127.0.0.1 $vty, puis "show ms""
    mod_ok
}

# Arret CIBLE : le motif inclut le fichier de conf. Un `pkill -f mobile` - six
# lettres sans ancrage, comme le faisait l'ancien teardown - emporte tout ce qui
# contient "mobile" dans sa ligne de commande, y compris ce qui n'est pas a
# nous.
mod_mobile_stop() {
    radio_kill mobile "$MOBILE_BIN -c $MOBILE_CFG"
    return 0
}
