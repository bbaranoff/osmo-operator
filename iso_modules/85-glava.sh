#!/bin/bash
# iso_modules/85-glava.sh - desktop audio visualiser (GLava + NCS Spectrum)
# Sourced by build-iso.sh in numeric order. A top-level `return` means nothing to do.
#
# GLava has no package in noble: tools/glava-build.sh builds it on the host
# (same Ubuntu as the image) with the NCS module patch and installs it into the
# rootfs via DESTDIR - binary, shaders in /etc/xdg/glava, launcher
# /usr/local/bin/osmo-glava, user service glava.service. Runtime libraries
# (libpulse0, libx11-6, libxext6, libxrender1, libxcomposite1, libgl1) already
# come with the GNOME desktop.
#
# Desktop only (--desktop), amd64. Disable with OSMO_ISO_GLAVA=0.
# A failure (network, missing -dev packages on the host) does not stop the
# build: the ISO ships without the visualiser, with a warning.
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
