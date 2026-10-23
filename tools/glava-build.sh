#!/bin/bash
# glava-build.sh - GLava + le module « NCS Spectrum », compiles et poses.
#
#     tools/glava-build.sh            sur la machine (/), en root
#     tools/glava-build.sh $ROOTFS    dans le rootfs de l ISO (iso_modules/85-glava.sh)
#
# [2026-10-23] Le visualiseur audio du bureau : le cercle « NCS Spectrum »
# (particules qui tournent autour d un disque, sur le son qui sort des
# haut-parleurs), pose en fond de bureau. Deux depots, figes a un commit :
#   - GLava (GPL-3) : pas de paquet dans noble, on le compile. Le module NCS a
#     besoin d un patch de glava/render.c (textures image pour les particules,
#     imageLoad/imageStore - OpenGL >= 4.2), fourni par le depot NCS ;
#   - NCS_Spectrum_GLava : ncs.glsl et ncs/ vont a cote des modules de GLava,
#     dans /etc/xdg/glava. Ce depot n a PAS de licence : il est clone au build,
#     pas copie dans le notre.
# rc.glsl (systeme) est regle comme le demande le README NCS : module ncs,
# OpenGL 4.5 / GLSL 450, setmirror (les deux canaux), fenetre de bureau sans
# bord ni clic. La position et la taille viennent de tools/osmo-glava.sh, qui
# les calcule d apres l ecran au lancement.
#
# Compilation sur l HOTE (meme Ubuntu que l image), installation par DESTDIR :
# pas de paquets -dev a installer puis retirer dans le rootfs.
set -euo pipefail

DEST="${1:-}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLAVA_REPO="${GLAVA_REPO:-https://gitlab.com/wild-turtles-publicly-release/glava/glava.git}"
GLAVA_COMMIT="${GLAVA_COMMIT:-e03a8a5b721f393dd7b80738a6ac5c9bccc8f050}"
NCS_REPO="${NCS_REPO:-https://github.com/Roonil/NCS_Spectrum_GLava.git}"
NCS_COMMIT="${NCS_COMMIT:-0984455086557584e53da12915e9dbd24255fed2}"

manque=""
for t in git meson ninja cc pkg-config patch; do
    command -v "$t" >/dev/null 2>&1 || manque="$manque $t"
done
for h in pulse/simple.h X11/Xlib.h X11/extensions/Xcomposite.h X11/extensions/Xrender.h X11/extensions/shape.h GL/gl.h; do
    [ -f "/usr/include/$h" ] || manque="$manque $h"
done
if [ -n "$manque" ]; then
    echo "glava-build : manque$manque" >&2
    echo "  apt-get install -y git meson ninja-build gcc pkg-config patch libpulse-dev libx11-dev libxext-dev libxrender-dev libxcomposite-dev libgl-dev" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
clone() {   # depot commit dossier
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
}
clone "$GLAVA_REPO" "$GLAVA_COMMIT" "$TMP/glava"
clone "$NCS_REPO" "$NCS_COMMIT" "$TMP/ncs"

patch -s -d "$TMP/glava" glava/render.c < "$TMP/ncs/imageOperations.patch"
# -Dobs=false : le greffon OBS demande libobs, sans usage ici
meson setup "$TMP/glava/build" "$TMP/glava" --prefix /usr -Dobs=false >/dev/null
ninja -C "$TMP/glava/build" >/dev/null
DESTDIR="$DEST" ninja -C "$TMP/glava/build" install >/dev/null

XDG="$DEST/etc/xdg/glava"
cp -r "$TMP/ncs/ncs" "$TMP/ncs/ncs.glsl" "$XDG/"
# [2026-10-24] Particules en ORANGE (celui du schema BTS -> Core du fond,
# 255/140/40), a la meme intensite que le bleu d origine (0.0118, 0.1412,
# 0.3412) : le melange est additif, une couleur plus forte sature en blanc.
sed -i 's/^#define color vec3(0.0118, 0.1412, 0.3412)/#define color vec3(0.3412, 0.1873, 0.0535)/' "$XDG/ncs.glsl"
grep -q '^#define color vec3(0.3412, 0.1873, 0.0535)' "$XDG/ncs.glsl" \
    || echo "glava-build : couleur NCS non changee (ncs.glsl a bouge ?)" >&2
sed -i -e 's/^#request mod bars/#request mod ncs/' \
       -e 's/^#request setdecorated true/#request setdecorated false/' \
       -e 's/^#request setmirror false/#request setmirror true/' \
       -e 's/^#request setversion 3 3/#request setversion 4 5/' \
       -e 's/^#request setshaderversion 330/#request setshaderversion 450/' \
       -e 's/^#request setxwintype "normal"/#request setxwintype "desktop"/' \
       -e 's/^#request setclickthrough false/#request setclickthrough true/' \
       "$XDG/rc.glsl"

install -Dm755 "$DIR/tools/osmo-glava.sh" "$DEST/usr/local/bin/osmo-glava"
install -d "$DEST/etc/xdg/autostart"
cat > "$DEST/etc/xdg/autostart/osmo-glava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=GLava NCS Spectrum
Comment=Visualiseur audio du bureau
Exec=/usr/local/bin/osmo-glava
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chmod 644 "$DEST/etc/xdg/autostart/osmo-glava.desktop"

if [ -n "$DEST" ]; then chroot "$DEST" ldconfig 2>/dev/null || true; else ldconfig; fi
echo "GLava + NCS : $(git -C "$TMP/glava" rev-parse --short HEAD) / $(git -C "$TMP/ncs" rev-parse --short HEAD) -> ${DEST:-/}"
