# =============================================================================
#  run_modules/_lib/mod.sh - bibliotheque du contrat de module
# =============================================================================
#
#  Source par run.sh AVANT les modules. Fournit :
#    - le registre declaratif (MOD_REGISTER + tableaux associatifs) ;
#    - les helpers de message (mod_ok / mod_fail / mod_skip / ...) ;
#    - les codes de retour normalises ;
#    - la barriere d'attente wait_until, qui remplace les `sleep` aveugles.
#
#  POURQUOI CE DECOUPAGE. L'ancien run.sh enchainait 20 lancements sans jamais
#  verifier qu'ils avaient abouti : un service absent ne se voyait nulle part, le
#  script continuait. Separer `start` (lancer) de `wait` (attendre un critere
#  OBSERVABLE) distingue "n'a pas demarre" de "demarre mais jamais pret" -
#  c'est le trou de diagnostic qu'on cherchait a combler.
# -----------------------------------------------------------------------------

# --- codes de retour, communs a toutes les fonctions de module ---------------
readonly MOD_RC_OK=0        # succes
readonly MOD_RC_FAIL=1      # echec
readonly MOD_RC_UNKNOWN=2   # indeterminable (status seulement)
readonly MOD_RC_ALREADY=3   # deja demarre
readonly MOD_RC_SKIP=4      # a ignorer legitimement

# --- registre declaratif ------------------------------------------------------
declare -a MOD_ORDER=()          # slugs, dans l'ordre de decouverte (= ordre des fichiers)
declare -A MOD_DESC=()           # description humaine, affichee a l'ecran
declare -A MOD_DEPS=()           # slugs prerequis, separes par des espaces
declare -A MOD_REQUIRED=()       # 1 = un echec arrete tout ; 0 = WARN et on continue
declare -A MOD_PROFILES=()       # profils qui incluent ce module
declare -A MOD_LOG=()            # chemin de log ("" = $LOGDIR/mod/<slug>.log)
declare -A MOD_JOURNAL=()        # unite systemd, pour afficher son journal en cas d'echec
declare -A MOD_PURE=()           # 1 = aucun effet de bord -> execute meme en --dry-run
declare -A MOD_ENABLED_IF=()     # expression shell, evaluee juste avant execution
declare -A MOD_TIMEOUT=()        # secondes, pour la barriere wait

# MOD_REGISTER <slug> <description>
# Pose les valeurs par defaut ; le module n'a a surcharger que ce qui differe.
MOD_REGISTER() {
    local slug="$1" desc="$2"
    MOD_ORDER+=("$slug")
    MOD_DESC[$slug]="$desc"
    MOD_DEPS[$slug]=""
    MOD_REQUIRED[$slug]=1
    MOD_PROFILES[$slug]="calypso"
    MOD_LOG[$slug]=""
    MOD_JOURNAL[$slug]=""
    MOD_PURE[$slug]=0
    MOD_ENABLED_IF[$slug]='true'
    MOD_TIMEOUT[$slug]=30
}

# Prefixe de fonction : slug avec les tirets remplaces par des underscores.
mod_prefix() { printf 'mod_%s' "${1//-/_}"; }

# --- protocole de message -----------------------------------------------------
# Les modules n'ecrivent JAMAIS sur la console : run.sh redirige leur sortie vers
# leur log. Pour parler a l'operateur, ils posent une raison via ces helpers.
_MOD_REASON=""
_MOD_HINT=""

mod_ok()      { _MOD_REASON=""   ; return $MOD_RC_OK; }
mod_fail()    { _MOD_REASON="$*" ; return $MOD_RC_FAIL; }
mod_already() { _MOD_REASON="$*" ; return $MOD_RC_ALREADY; }
mod_skip()    { _MOD_REASON="$*" ; return $MOD_RC_SKIP; }
mod_hint()    { _MOD_HINT="$*"; }
mod_say()     { printf '%s\n' "$*"; }   # va dans le log du module

# --- barriere d'attente -------------------------------------------------------
# wait_until <timeout_s> <description> <commande...>
# Sonde la commande jusqu'a ce qu'elle reussisse, ou echoue au bout du delai.
# Remplace les `sleep N` : on attend un CRITERE, pas une duree.
wait_until() {
    local timeout="$1" what="$2"; shift 2
    local deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        if "$@" >/dev/null 2>&1; then return $MOD_RC_OK; fi
        sleep 0.2
    done
    mod_fail "$what : toujours pas pret apres ${timeout}s"
}

# --- sondes reutilisables par les modules ------------------------------------
have_proc()  { pgrep -f "$1" >/dev/null 2>&1; }
have_port()  { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
have_unix()  { [ -S "$1" ]; }
log_has()    { [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; }
