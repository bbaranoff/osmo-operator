#!/bin/bash
# =============================================================================
# osmo-telecom-boot.sh - apply the "no telecom service at boot" policy
#
# Installs services/80-osmo-operator.preset in
# <root>/usr/lib/systemd/system-preset/ then disables, among the units
# PRESENT, those targeted by this preset (systemctl --root for an ISO rootfs).
# Nothing is stopped: a running service keeps running until it is stopped, it
# simply no longer starts at boot.
#
#   tools/osmo-telecom-boot.sh                 this machine
#   tools/osmo-telecom-boot.sh --root DIR      a rootfs (ISO chroot)
#   tools/osmo-telecom-boot.sh --garder U...   units to leave enabled
#                                              (e.g. osmo-interstp for the
#                                              interstp role, osmo-banc if
#                                              OSMO_ISO_BANC=1)
#   tools/osmo-telecom-boot.sh --liste         only print what would be done
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PRESET="$DIR/services/80-osmo-operator.preset"
ROOT=""; LISTE=0; GARDER=()
while [ $# -gt 0 ]; do
    case "$1" in
        --root)   ROOT="${2%/}"; shift ;;
        --garder) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do GARDER+=("${1%.service}"); shift; done; continue ;;
        --liste)  LISTE=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    esac
    shift
done
[ -f "$PRESET" ] || { echo "preset introuvable : $PRESET" >&2; exit 1; }

# the "disable" patterns of the preset
mapfile -t MOTIFS < <(awk '$1 == "disable" {print $2}' "$PRESET")

# the units present on the target that match a pattern
unites=()
for d in "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" "$ROOT/usr/lib/systemd/system"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.service; do
        [ -e "$f" ] || continue
        u="$(basename "$f")"
        for m in "${MOTIFS[@]}"; do
            # shellcheck disable=SC2053
            [[ $u == $m ]] && { unites+=("$u"); break; }
        done
    done
done
mapfile -t unites < <(printf '%s\n' "${unites[@]}" | sort -u | grep -v '^$')

[ "$LISTE" = 1 ] || install -D -m644 "$PRESET" "$ROOT/usr/lib/systemd/system-preset/80-osmo-operator.preset"
sc=(systemctl); [ -n "$ROOT" ] && sc+=(--root="$ROOT")
n=0
for u in "${unites[@]}"; do
    for g in "${GARDER[@]}"; do [ "${u%.service}" = "$g" ] && continue 2; done
    if [ -n "$ROOT" ]; then
        # rootfs: enabled = a *.wants/ link to the unit (is-enabled is unreliable outside systemd)
        compgen -G "$ROOT/etc/systemd/system/*.wants/$u" >/dev/null || continue
        etat=enabled
    else
        etat="$("${sc[@]}" is-enabled "$u" 2>/dev/null)"
        case "$etat" in enabled|enabled-runtime|linked) ;; *) continue ;; esac
    fi
    if [ "$LISTE" = 1 ]; then echo "  desactiverait : $u ($etat)"; n=$((n + 1)); continue; fi
    if "${sc[@]}" disable "$u" >/dev/null 2>&1; then echo "  boot : $u desactive"; n=$((n + 1))
    else
        # chroot without systemd: remove the links ourselves (what disable does)
        find "$ROOT/etc/systemd/system" -path "*.wants/$u" -delete 2>/dev/null && echo "  boot : $u desactive (liens)" && n=$((n + 1))
    fi
done
[ "${#GARDER[@]}" -gt 0 ] && echo "  boot : gardes actives : ${GARDER[*]}"
if [ "$LISTE" = 1 ]; then echo "  politique telecom au boot : $n unite(s) a desactiver"
else echo "  politique telecom au boot : $n unite(s) desactivee(s), preset 80-osmo-operator.preset pose"; fi
exit 0
