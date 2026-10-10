# =============================================================================
#  install_modules/_lib/inst.sh - contrat des modules d'installation
# =============================================================================
#
#  Meme principe que run_modules/_lib/mod.sh, mais pour l'installation. La
#  difference tient a la nature des etapes : on n'y "demarre" rien, on
#  transforme la machine - donc on veut savoir, pour chacune, si elle est DEJA
#  faite (idempotence) et si elle a REUSSI (verification).
#
#  Quatre fonctions par module, `run` seule obligatoire :
#     inst_<p>_check    prerequis, LECTURE SEULE          0 ok · 1 manque · 4 sans objet
#     inst_<p>_done     deja installe ?                   0 oui · 1 non
#     inst_<p>_run      fait le travail                   0 ok · 1 echec · 3 deja fait
#     inst_<p>_verify   controle APRES coup               0 ok · 1 echec
#
#  `verify` est le pendant de la barriere `wait` cote execution : installer
#  n'est pas avoir installe. Un `apt-get` qui rend 0 mais laisse un binaire
#  absent doit etre vu ici, pas trois etapes plus loin.
# -----------------------------------------------------------------------------

readonly INST_RC_OK=0
readonly INST_RC_FAIL=1
readonly INST_RC_DONE=3
readonly INST_RC_NA=4

declare -a INST_ORDER=()
declare -A INST_DESC=()      # description affichee
declare -A INST_DEPS=()      # etapes prerequises
declare -A INST_REQUIRED=()  # 1 = un echec arrete tout
declare -A INST_ROOT=()      # 1 = exige les droits root
declare -A INST_TIMEOUT=()   # secondes, pour les etapes longues

INST_REGISTER() {
    local slug="$1" desc="$2"
    INST_ORDER+=("$slug")
    INST_DESC[$slug]="$desc"
    INST_DEPS[$slug]=""
    INST_REQUIRED[$slug]=1
    INST_ROOT[$slug]=1
    INST_TIMEOUT[$slug]=1800
}

inst_prefix() { printf 'inst_%s' "${1//-/_}"; }

# --- protocole de message (identique a run_modules) ---------------------------
_INST_REASON=""
_INST_HINT=""
inst_ok()   { _INST_REASON=""   ; return $INST_RC_OK; }
inst_fail() { _INST_REASON="$*" ; return $INST_RC_FAIL; }
inst_done() { _INST_REASON="$*" ; return $INST_RC_DONE; }
inst_na()   { _INST_REASON="$*" ; return $INST_RC_NA; }
inst_hint() { _INST_HINT="$*"; }
inst_say()  { printf '%s\n' "$*"; }

# --- sondes -------------------------------------------------------------------
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
have_dir()  { [ -d "$1" ]; }
have_file() { [ -f "$1" ]; }
have_pkg()  { dpkg -s "$1" >/dev/null 2>&1; }
have_repo() { [ -d "$1/.git" ]; }
