#!/bin/bash
# osmo-patches-apply.sh - apply patches/*.patch on the trees under $GSM_ROOT.
#
# Idempotent: a patch already present (git apply -R --check) is skipped, a
# patch that does not apply is reported, never fatal. Used by the native
# install (install_modules/40-patches.sh), the ISO (iso_modules/70-scripts.sh,
# on the rootfs), update.sh (catch-up on an installed machine) and the
# --calypso-fw supplement (tools/osmo-firmwares-install.sh).
#
#   osmo-patches-apply.sh [GSM_ROOT]        default: /opt/GSM
#   OSMO_PATCHES_ONLY=osmocom-bb            only handle the patches of this tree
#   OSMO_PATCHES_QUIET=1                    only print applications and failures
#
# Exit code: 0 if nothing failed, 1 if at least one patch does not apply.
set -u
GSM_ROOT="${1:-${GSM_ROOT:-/opt/GSM}}"
REPO="${REPO:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
: "${GREEN:=}"; : "${YELLOW:=}"; : "${RED:=}"; : "${NC:=}"

# tree targeted by a patch, from its prefix
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
