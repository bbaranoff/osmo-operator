#!/bin/bash
# iso_modules/85-extensions-gnome.sh - extensions GNOME Shell actives par defaut
# Source par build-iso.sh, dans l ordre des numeros. `return` en tete = rien a faire.
#
# [2026-10-23] EasyScreenCast, pose et active pour tous les comptes par
# tools/gnome-extensions-install.sh (zip de extensions.gnome.org, sha256
# verifie). chrome-gnome-shell vient d apt (liste du bureau, 80-chroot.sh).
# Bureau seulement (--desktop), amd64. Un echec (reseau) n arrete pas le build.
if [ "${ISO_ARCH:-amd64}" = "arm64" ] || [ "${ISO_DESKTOP:-0}" != "1" ]; then return 0; fi

if _EXT_LOG=$("$DIR/tools/gnome-extensions-install.sh" "$ROOTFS" 2>&1); then
    echo -e "  ${GREEN}✓${NC} ${_EXT_LOG##*$'\n'}"
else
    echo -e "  ${YELLOW}!${NC} extensions GNOME non posees :\n$_EXT_LOG" | tail -4 >&2
fi
