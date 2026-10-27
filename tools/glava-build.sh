#!/bin/bash
# glava-build.sh - GLava + the "NCS Spectrum" module, built and installed.
#
#     tools/glava-build.sh            on the machine (/), as root
#     tools/glava-build.sh $ROOTFS    in the ISO rootfs (iso_modules/85-glava.sh)
#
# The desktop audio visualizer: the "NCS Spectrum" circle (particles turning
# around a disc, driven by the sound coming out of the speakers), placed as a
# desktop background. Two repositories, pinned to a commit:
#   - GLava (GPL-3): no package in noble, built here. The NCS module needs a
#     patch of glava/render.c (image textures for the particles,
#     imageLoad/imageStore - OpenGL >= 4.2), provided by the NCS repository;
#   - NCS_Spectrum_GLava: ncs.glsl and ncs/ go next to the GLava modules, in
#     /etc/xdg/glava. This repository has NO licence: it is cloned at build
#     time, not copied into ours.
# rc.glsl (system) is set as the NCS README asks: module ncs, OpenGL 4.5 /
# GLSL 450, setmirror (both channels), desktop window without border or
# click. Position and size come from tools/osmo-glava.sh, which computes them
# from the screen at startup.
#
# Built on the HOST (same Ubuntu as the image), installed through DESTDIR: no
# -dev packages to install and then remove in the rootfs.
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
# -Dobs=false: the OBS plugin needs libobs, unused here
meson setup "$TMP/glava/build" "$TMP/glava" --prefix /usr -Dobs=false >/dev/null
ninja -C "$TMP/glava/build" >/dev/null
DESTDIR="$DEST" ninja -C "$TMP/glava/build" install >/dev/null

XDG="$DEST/etc/xdg/glava"
cp -r "$TMP/ncs/ncs" "$TMP/ncs/ncs.glsl" "$XDG/"
# Particles in ORANGE (the one of the BTS -> Core diagram of the wallpaper,
# 255/140/40), at the same intensity as the original blue (0.0118, 0.1412,
# 0.3412): the blend is additive, a stronger colour saturates to white.
sed -i 's/^#define color vec3(0.0118, 0.1412, 0.3412)/#define color vec3(0.3412, 0.1873, 0.0535)/' "$XDG/ncs.glsl"
grep -q '^#define color vec3(0.3412, 0.1873, 0.0535)' "$XDG/ncs.glsl" \
    || echo "glava-build : couleur NCS non changee (ncs.glsl a bouge ?)" >&2
# The bottom band (bars module, started by osmo-glava next to the circle):
# thick bars (12 px, gap 3), light blue, transparent background.
sed -i -e 's/^#define BAR_WIDTH 5$/#define BAR_WIDTH 12/' \
       -e 's/^#define BAR_GAP 1$/#define BAR_GAP 3/' \
       -e 's/^#define USE_ALPHA 0$/#define USE_ALPHA 1/' \
       -e 's/^#define COLOR @fg:mix(#3366b2, #a0a0b2, clamp(d \/ GRADIENT, 0, 1))$/#define COLOR @fg:mix(#78c3ff, #d6eeff, clamp(d \/ GRADIENT, 0, 1))/' \
       "$XDG/bars.glsl"
grep -q '^#define COLOR @fg:mix(#78c3ff' "$XDG/bars.glsl" \
    || echo "glava-build : couleur des barres non changee (bars.glsl a bouge ?)" >&2
sed -i -e 's/^#request mod bars/#request mod ncs/' \
       -e 's/^#request setdecorated true/#request setdecorated false/' \
       -e 's/^#request setmirror false/#request setmirror true/' \
       -e 's/^#request setversion 3 3/#request setversion 4 5/' \
       -e 's/^#request setshaderversion 330/#request setshaderversion 450/' \
       -e 's/^#request setxwintype "normal"/#request setxwintype "desktop"/' \
       -e 's/^#request setclickthrough false/#request setclickthrough true/' \
       "$XDG/rc.glsl"

install -Dm755 "$DIR/tools/osmo-glava.sh" "$DEST/usr/local/bin/osmo-glava"
# A USER SERVICE. Circle AND bars are in the same cgroup:
#   systemctl --user stop glava      stops both (and removes the mixing)
#   systemctl --user start glava     restarts them
#   systemctl --user disable glava   no more GLava at login (this account)
# Enabled for all accounts (graphical-session.target.wants in
# /etc/systemd/user): starts with the graphical session, which provides DISPLAY.
rm -f "$DEST/etc/xdg/autostart/osmo-glava.desktop"
install -d "$DEST/etc/systemd/user/graphical-session.target.wants"
cat > "$DEST/etc/systemd/user/glava.service" <<'UNIT'
[Unit]
Description=GLava : cercle NCS et barres du bas (micro + haut-parleurs)
PartOf=graphical-session.target
After=graphical-session.target pulseaudio.service pipewire-pulse.service

[Service]
ExecStart=/usr/local/bin/osmo-glava
ExecStopPost=/usr/local/bin/osmo-glava --retirer-mix
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
chmod 644 "$DEST/etc/systemd/user/glava.service"
ln -sfn ../glava.service "$DEST/etc/systemd/user/graphical-session.target.wants/glava.service"

if [ -n "$DEST" ]; then chroot "$DEST" ldconfig 2>/dev/null || true; else ldconfig; fi
echo "GLava + NCS : $(git -C "$TMP/glava" rev-parse --short HEAD) / $(git -C "$TMP/ncs" rev-parse --short HEAD) -> ${DEST:-/}"
