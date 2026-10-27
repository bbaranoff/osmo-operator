#!/bin/bash
# gnome-extensions-install.sh - GNOME Shell extensions enabled by default.
#
#     tools/gnome-extensions-install.sh            on the machine (/), as root
#     tools/gnome-extensions-install.sh $ROOTFS    in the ISO rootfs
#                                                  (iso_modules/85-extensions-gnome.sh)
#
# EasyScreenCast (GPL-3, extensions.gnome.org no. 690): a top bar menu for the
# GNOME screen recorder (sound, webcam, area, timer). No package: the zip of
# version 53 (GNOME 46 to 48) is downloaded, checked against its sha256 and
# installed for all accounts in /usr/share/gnome-shell/extensions.
# The browser bridge chrome-gnome-shell (gnome-browser-connector) is an apt
# package: it is in the desktop list (iso_modules/80-chroot.sh).
#
# "Enabled by default" = enabled-extensions in a schema override, in the bare
# section AND :ubuntu (the ubuntu session reads that one first - same reason
# as the wallpaper and the dock in 80-chroot.sh). An account that already has
# its own list (gsettings set ...) keeps it: the override is only a default.
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
