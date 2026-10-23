#!/bin/bash
# iso_modules/85-glava.sh - le visualiseur audio du bureau (GLava + NCS Spectrum)
# Source par build-iso.sh, dans l ordre des numeros. `return` en tete = rien a faire.
#
# [2026-10-23] GLava n a pas de paquet dans noble : tools/glava-build.sh le
# compile sur l HOTE (meme Ubuntu que l image) avec le patch du module NCS, et
# l installe dans le rootfs par DESTDIR - binaire, shaders dans /etc/xdg/glava,
# lanceur /usr/local/bin/osmo-glava, autostart /etc/xdg/autostart. Les
# bibliotheques d execution (libpulse0, libx11-6, libxext6, libxrender1,
# libxcomposite1, libgl1) viennent deja avec le bureau GNOME.
#
# Bureau seulement (--desktop), amd64. Desactivable : OSMO_ISO_GLAVA=0.
# Un echec (reseau, paquets -dev absents de l hote) n arrete pas le build :
# l ISO sort sans visualiseur, avec un avertissement.
if [ "${ISO_ARCH:-amd64}" = "arm64" ] || [ "${ISO_DESKTOP:-0}" != "1" ]; then return 0; fi
if [ "${OSMO_ISO_GLAVA:-1}" != "1" ]; then
    echo -e "  ${YELLOW}!${NC} GLava desactive (OSMO_ISO_GLAVA=0)"
    return 0
fi

if _GLV_LOG=$("$DIR/tools/glava-build.sh" "$ROOTFS" 2>&1); then
    echo -e "  ${GREEN}✓${NC} ${_GLV_LOG##*$'\n'}"
    _GLV_MANQUE=$(chroot "$ROOTFS" ldd /usr/bin/glava 2>/dev/null | grep 'not found' || true)
    [ -z "$_GLV_MANQUE" ] || echo -e "  ${YELLOW}!${NC} GLava : bibliotheques absentes du rootfs :\n$_GLV_MANQUE" >&2
else
    echo -e "  ${YELLOW}!${NC} GLava non installe :\n$_GLV_LOG" | tail -4 >&2
fi
