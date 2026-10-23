#!/bin/bash
# gnome-extensions-install.sh - extensions GNOME Shell actives par defaut.
#
#     tools/gnome-extensions-install.sh            sur la machine (/), en root
#     tools/gnome-extensions-install.sh $ROOTFS    dans le rootfs de l ISO
#                                                  (iso_modules/85-extensions-gnome.sh)
#
# [2026-10-23] EasyScreenCast (GPL-3, extensions.gnome.org n° 690) : un menu
# dans la barre du haut pour l enregistreur d ecran de GNOME (son, webcam,
# zone, minuterie). Pas de paquet : le zip de la version 53 (GNOME 46 a 48)
# est telecharge, verifie par son sha256 et pose pour tous les comptes dans
# /usr/share/gnome-shell/extensions.
# Le pont navigateur chrome-gnome-shell (gnome-browser-connector) est un
# paquet apt : il est dans la liste du bureau (iso_modules/80-chroot.sh).
#
# « Active par defaut » = enabled-extensions dans un override de schema, en
# section nue ET :ubuntu (la session ubuntu lit celle-la d abord - meme raison
# que le fond et le dock dans 80-chroot.sh). Un compte qui a deja sa propre
# liste (gsettings set ...) la garde : l override n est qu un defaut.
set -euo pipefail

DEST="${1:-}"
ESC_UUID="EasyScreenCast@iacopodeenosee.gmail.com"
ESC_URL="https://extensions.gnome.org/download-extension/$ESC_UUID.shell-extension.zip?version_tag=63091"
ESC_SHA256="e0fce1b69cf05eb365fe3d4a3e8c627c6a93beffc18a042b7896249961bc6777"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/esc.zip" "$ESC_URL"
echo "$ESC_SHA256  $TMP/esc.zip" | sha256sum -c --quiet -

EXT="$DEST/usr/share/gnome-shell/extensions/$ESC_UUID"
rm -rf "$EXT"
install -d "$EXT"
python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/esc.zip" "$EXT"
chmod -R u=rwX,go=rX "$EXT"

SCH="$DEST/usr/share/glib-2.0/schemas"
printf "[org.gnome.shell]\nenabled-extensions=['%s']\n\n[org.gnome.shell:ubuntu]\nenabled-extensions=['%s']\n" \
    "$ESC_UUID" "$ESC_UUID" > "$SCH/99-osmo-extensions.gschema.override"
if [ -n "$DEST" ]; then chroot "$DEST" glib-compile-schemas /usr/share/glib-2.0/schemas; else glib-compile-schemas "$SCH"; fi
echo "EasyScreenCast v53 -> ${DEST:-/}usr/share/gnome-shell/extensions, active par defaut"
