#!/bin/bash
# osmo-patches-apply.sh - applique patches/*.patch sur les arbres de $GSM_ROOT.
#
# Idempotent : un correctif deja present (git apply -R --check) est passe, un
# correctif qui ne s applique pas est signale, jamais fatal. Sert a l install
# native (install_modules/40-patches.sh), a l ISO (iso_modules/70-scripts.sh,
# sur le rootfs), a update.sh (rattrapage d une machine installee) et au
# supplement --calypso-fw (tools/osmo-firmwares-install.sh).
#
#   osmo-patches-apply.sh [GSM_ROOT]        defaut : /opt/GSM
#   OSMO_PATCHES_ONLY=osmocom-bb            ne traite que les correctifs de cet arbre
#   OSMO_PATCHES_QUIET=1                    n affiche que les applications et les echecs
#
# Code de retour : 0 si rien n a echoue, 1 si au moins un correctif ne s applique pas.
set -u
GSM_ROOT="${1:-${GSM_ROOT:-/opt/GSM}}"
REPO="${REPO:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
: "${GREEN:=}"; : "${YELLOW:=}"; : "${RED:=}"; : "${NC:=}"

# arbre vise par un correctif, d apres son prefixe
osmo_patch_target() {
    case "$(basename "$1")" in
        osmo-bts-*)               printf '%s\n' "$GSM_ROOT/osmo-bts" ;;
        osmo-msc-*)               printf '%s\n' "$GSM_ROOT/osmo-msc" ;;
        osmo-hlr-*)               printf '%s\n' "$GSM_ROOT/osmo-hlr" ;;
        osmo-trx-*)               printf '%s\n' "$GSM_ROOT/osmo-trx" ;;
        osmocom-bb-transceiver-*) printf '%s\n' "$GSM_ROOT/osmocom-bb-transceiver" ;;
        osmocom-bb-*)             printf '%s\n' "$GSM_ROOT/osmocom-bb" ;;
        grgsm-*)                  printf '%s\n' "$GSM_ROOT/gr-gsm" ;;
        qosmo-*)                  printf '%s\n' "$GSM_ROOT/qosmo" ;;
        c54x_exe-*)               printf '%s\n' "$GSM_ROOT/c54x_exe" ;;
        *)                        printf '' ;;
    esac
}

rc=0; n=0
for p in "$REPO"/patches/*.patch; do
    [ -f "$p" ] || continue
    t="$(osmo_patch_target "$p")"
    [ -n "$t" ] && [ -d "$t" ] || continue
    if [ -n "${OSMO_PATCHES_ONLY:-}" ] && [ "$(basename "$t")" != "$OSMO_PATCHES_ONLY" ]; then continue; fi
    if git -C "$t" apply -R --check "$p" 2>/dev/null; then
        [ "${OSMO_PATCHES_QUIET:-0}" = 1 ] || echo "  deja applique : $(basename "$p")"
    elif git -C "$t" apply --check "$p" 2>/dev/null && git -C "$t" apply "$p" 2>/dev/null; then
        echo -e "  ${GREEN}applique${NC} : $(basename "$p") -> $t"; n=$((n+1))
    else
        echo -e "  ${YELLOW}ne s applique pas${NC} : $(basename "$p") sur $t" >&2; rc=1
    fi
done
[ "${OSMO_PATCHES_QUIET:-0}" = 1 ] && [ $n = 0 ] || echo "  $n correctif(s) applique(s) ($GSM_ROOT)"
exit $rc
