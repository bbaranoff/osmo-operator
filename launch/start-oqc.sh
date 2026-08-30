#!/bin/bash
# =============================================================================
#  launch/start-oqc.sh - lance qemu-src depuis osmo_egprs
# =============================================================================
#
#  "oqc" = qemu-src, l'emulation Calypso (ARM7 + DSP TMS320C54x).
#  Ce fichier est le raccourci depuis osmo_egprs : il trouve le depot et lui
#  passe la main. Toute la logique de lancement vit la-bas, dans run_modules/.
#
#      ./launch/start-oqc.sh                  profil calypso (defaut)
#      ./launch/start-oqc.sh --list           le plan, sans rien lancer
#      ./launch/start-oqc.sh --dry-run        deroule sans effet de bord
#      ./launch/start-oqc.sh --status         ou en est chaque etape
#      ./launch/start-oqc.sh --stop           arrete, en ordre inverse
#      ./launch/start-oqc.sh --check-paths    verifie les dependances de la machine
#
#  Les variables CALYPSO_* passees en prefixe traversent jusqu'a QEMU :
#      CALYPSO_MODE=native ./launch/start-oqc.sh
#
#  Ou est le depot : OQC_ROOT, sinon les emplacements habituels sont essayes.
#      OQC_ROOT=~/src/qemu-src ./launch/start-oqc.sh
#
#  A ne pas confondre avec start-direct.sh, qui orchestre TOUTE la pile
#  (coeur Osmocom + radio) et dont le mode "qemu" aboutit egalement ici.
# -----------------------------------------------------------------------------
set -euo pipefail

_find_oqc() {
    [ -n "${OQC_ROOT:-}" ] && { printf '%s\n' "$OQC_ROOT"; return 0; }
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # launch/ -> racine du depot
    local c
    for c in "$here/../qemu-src" \
             "${GSM_ROOT:-/opt/GSM}/qemu-src" \
             "$HOME/qemu-src"; do
        [ -x "$c/run.sh" ] && { (cd "$c" && pwd); return 0; }
    done
    return 1
}

if ! OQC="$(_find_oqc)"; then
    cat >&2 <<'ERR'
qemu-src introuvable.

Cherche dans : ../qemu-src, $GSM_ROOT/qemu-src, ~/qemu-src

Indiquez son emplacement :
    OQC_ROOT=/chemin/vers/qemu-src ./launch/start-oqc.sh
ou recuperez-le :
    git clone https://github.com/bbaranoff/qemu qemu-src
ERR
    exit 2
fi

exec "$OQC/run.sh" "$@"
