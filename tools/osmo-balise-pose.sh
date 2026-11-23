#!/bin/bash
# tools/osmo-balise-pose.sh - installs osmo-balise (the mast beacon that
# follows the bench, tools/osmo-balise.py) in a system tree.
#
#   osmo-balise-pose.sh [RACINE]     RACINE: / (default) or an ISO rootfs
#
# Used by iso_modules/85-installeur-bureau.sh (rootfs), install_modules/
# 80-bureau.sh (native) and update.sh. It puts:
#   /usr/share/backgrounds/osmo-balise/soir.png    configs/osmo-balise-soir.png
#   /usr/share/backgrounds/osmo-balise/jour.png    configs/osmo-balise-jour.png
#   /usr/share/backgrounds/osmo-balise/<hash>/     the 4 variants, built HERE
#                    (numpy + Pillow on this machine, ~15 s) so a session
#                    never has to build them
#   /usr/local/bin/osmo-balise                     -> tools/osmo-balise.py
#   /etc/xdg/autostart/osmo-balise.desktop         « osmo-balise suivre » in
#                    every GNOME session (a ~/.config/autostart file with the
#                    same name overrides it, XDG rule: no double daemon)
# The default wallpaper (the DAY picture) is set by the callers' gschema
# override. Never fatal: without numpy here, the session builds the variants
# in ~/.local/share the first time.
set -u
RACINE="${1:-/}"; RACINE="${RACINE%/}"
REPO="${OSMO_REPO:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SYS=/usr/share/backgrounds/osmo-balise
DST="$RACINE$SYS"

for f in soir jour; do
    [ -f "$REPO/configs/osmo-balise-$f.png" ] || { echo "osmo-balise : configs/osmo-balise-$f.png absent - rien a poser" >&2; exit 0; }
done
install -d "$DST"
install -m644 "$REPO/configs/osmo-balise-soir.png" "$DST/soir.png"
install -m644 "$REPO/configs/osmo-balise-jour.png" "$DST/jour.png"

# The variants: written straight into the target, no personal config touched.
if python3 -c 'import numpy, PIL' 2>/dev/null; then
    OSMO_BALISE_CONF=- OSMO_BALISE_SORTIE="$DST" \
        python3 "$REPO/tools/osmo-balise.py" generer "$DST/soir.png" "$DST/jour.png" >/dev/null \
        && echo "osmo-balise : variantes dans $SYS" \
        || echo "osmo-balise : variantes non construites (la session les fera)" >&2
else
    echo "osmo-balise : numpy/Pillow absents ici - variantes construites a la premiere session" >&2
fi
chmod -R a+rX "$DST" 2>/dev/null || true

install -d "$RACINE/usr/local/bin" "$RACINE/etc/xdg/autostart"
# the link names the tree as seen from the TARGET (an ISO rootfs: /opt/GSM/...)
ln -sfn "${OSMO_BALISE_LIEN:-/opt/GSM/osmo-operator/tools/osmo-balise.py}" "$RACINE/usr/local/bin/osmo-balise"
cat > "$RACINE/etc/xdg/autostart/osmo-balise.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=osmo-balise
Comment=La balise du mat suit le banc (fond d'ecran jour / soir)
Exec=/usr/local/bin/osmo-balise suivre
OnlyShowIn=GNOME;Unity;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
NoDisplay=true
EOF
chmod 644 "$RACINE/etc/xdg/autostart/osmo-balise.desktop"
echo "osmo-balise : pose dans ${RACINE:-/} (fond de repos : $SYS/jour.png)"
