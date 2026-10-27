# =============================================================================
#  install_modules/_lib/inst.sh - contract of the installation modules
# =============================================================================
#
#  Same principle as qosmo/run_modules/_lib/mod.sh, but for installation.
#  The steps do not "start" anything, they transform the machine: for each
#  one we want to know whether it is ALREADY done (idempotence) and whether
#  it SUCCEEDED (verification).
#
#  Four functions per module, only `run` is mandatory:
#     inst_<p>_check    prerequisites, READ ONLY       0 ok · 1 missing · 4 not applicable
#     inst_<p>_done     already installed?             0 yes · 1 no
#     inst_<p>_run      does the work                  0 ok · 1 failure · 3 already done
#     inst_<p>_verify   check AFTER the fact           0 ok · 1 failure
#
#  `verify` is the counterpart of the `wait` barrier on the run side:
#  installing is not having installed. An `apt-get` that returns 0 but leaves
#  a binary missing must be caught here, not three steps later.
# -----------------------------------------------------------------------------

readonly INST_RC_OK=0
readonly INST_RC_FAIL=1
readonly INST_RC_DONE=3
readonly INST_RC_NA=4

declare -a INST_ORDER=()
declare -A INST_DESC=()      # displayed description
declare -A INST_DEPS=()      # prerequisite steps
declare -A INST_REQUIRED=()  # 1 = a failure stops everything
declare -A INST_ROOT=()      # 1 = requires root
declare -A INST_TIMEOUT=()   # seconds, for long steps

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

# --- message protocol (same as the run modules) -------------------------------
_INST_REASON=""
_INST_HINT=""
inst_ok()   { _INST_REASON=""   ; return $INST_RC_OK; }
inst_fail() { _INST_REASON="$*" ; return $INST_RC_FAIL; }
inst_done() { _INST_REASON="$*" ; return $INST_RC_DONE; }
inst_na()   { _INST_REASON="$*" ; return $INST_RC_NA; }
inst_hint() { _INST_HINT="$*"; }
inst_say()  { printf '%s\n' "$*"; }

# --- probes -------------------------------------------------------------------
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
have_dir()  { [ -d "$1" ]; }
have_file() { [ -f "$1" ]; }
have_pkg()  { dpkg -s "$1" >/dev/null 2>&1; }
have_repo() { [ -d "$1/.git" ]; }
