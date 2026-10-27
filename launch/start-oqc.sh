#!/bin/bash
# =============================================================================
#  launch/start-oqc.sh - start qosmo-grgsm from osmo-operator
# =============================================================================
#
#  "oqc" = qosmo-grgsm, the Calypso emulation (ARM7 + TMS320C54x DSP).
#  This is a shortcut from osmo-operator: it locates the repository and hands
#  over to its run.sh. All launch logic lives there, in run_modules/.
#
#      ./launch/start-oqc.sh                  calypso profile (default)
#      ./launch/start-oqc.sh --list           show the plan, start nothing
#      ./launch/start-oqc.sh --dry-run        run without side effects
#      ./launch/start-oqc.sh --status         state of each step
#      ./launch/start-oqc.sh --stop           stop, in reverse order
#      ./launch/start-oqc.sh --check-paths    check the machine's dependencies
#
#  CALYPSO_* variables given as a prefix are passed through to QEMU:
#      CALYPSO_MODE=native ./launch/start-oqc.sh
#
#  Repository location: OQC_ROOT, otherwise ../qosmo-grgsm,
#  $GSM_ROOT/qosmo-grgsm (default /opt/GSM) and ~/qosmo-grgsm are tried.
#      OQC_ROOT=~/src/qosmo-grgsm ./launch/start-oqc.sh
#
#  Not to be confused with start-native.sh, which orchestrates the WHOLE stack
#  (Osmocom core + radio) and whose "qemu" mode also ends up here.
# -----------------------------------------------------------------------------
set -euo pipefail

_find_oqc() {
    [ -n "${OQC_ROOT:-}" ] && { printf '%s\n' "$OQC_ROOT"; return 0; }
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # launch/ -> repository root
    local c
    for c in "$here/../qosmo-grgsm" \
             "${GSM_ROOT:-/opt/GSM}/qosmo-grgsm" \
             "$HOME/qosmo-grgsm"; do
        [ -x "$c/run.sh" ] && { (cd "$c" && pwd); return 0; }
    done
    return 1
}

if ! OQC="$(_find_oqc)"; then
    cat >&2 <<'ERR'
qosmo-grgsm introuvable.

Cherche dans : ../qosmo-grgsm, $GSM_ROOT/qosmo-grgsm, ~/qosmo-grgsm

Indiquez son emplacement :
    OQC_ROOT=/chemin/vers/qosmo-grgsm ./launch/start-oqc.sh
ou recuperez-le :
    git clone https://github.com/bbaranoff/qosmo-grgsm qosmo-grgsm
ERR
    exit 2
fi

exec "$OQC/run.sh" "$@"
