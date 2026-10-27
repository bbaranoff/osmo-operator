#!/bin/bash
# iso_modules/85-extensions-gnome.sh - GNOME Shell extensions enabled by default
# Sourced by build-iso.sh in numeric order. A top-level `return` means nothing to do.
#
# EasyScreenCast is installed and enabled for all accounts by
# tools/gnome-extensions-install.sh (zip from extensions.gnome.org, sha256
# checked). chrome-gnome-shell comes from apt (desktop package list, 80-chroot.sh).
# Desktop only (--desktop), amd64. A failure (network) does not stop the build.
if [ "${ISO_ARCH:-amd64}" = "arm64" ] || [ "${ISO_DESKTOP:-0}" != "1" ]; then return 0; fi

if _EXT_LOG=$("$DIR/tools/gnome-extensions-install.sh" "$ROOTFS" 2>&1); then
    echo -e "  ${GREEN}✓${NC} ${_EXT_LOG##*$'\n'}"
else
    echo -e "  ${YELLOW}!${NC} extensions GNOME non posees :\n$_EXT_LOG" | tail -4 >&2
fi
