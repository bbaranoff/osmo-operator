#!/bin/bash
# iso_modules/99-fin.sh - hand the rootfs to the next pass, print the summary.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment variables:
#   OSMO_ISO_ROOTFS_KEEP  path where the rootfs is kept for the next pass (--all)

# ── Keep the rootfs for the next pass if the parent asks (--all) ──────────
# Moved, not copied (same filesystem, instant). cleanup() then removes $WORK
# without it.
if [ -n "${OSMO_ISO_ROOTFS_KEEP:-}" ]; then
    umount "$ROOTFS/var/cache/apt/archives" 2>/dev/null || true
    umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null || true
    rm -rf "$OSMO_ISO_ROOTFS_KEEP"
    mkdir -p "$(dirname "$OSMO_ISO_ROOTFS_KEEP")"
    mv "$ROOTFS" "$OSMO_ISO_ROOTFS_KEEP"
    echo -e "  ${GREEN}✓${NC} rootfs conserve pour la passe suivante : ${CYAN}${OSMO_ISO_ROOTFS_KEEP}${NC}"
fi

echo ""
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    echo -e "${GREEN}${BOLD}═══ Image SD Raspberry Pi 4 (Armbian ${ISO_UBUNTU}) prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
    echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
    echo -e "  Gravure : ${CYAN}dd if=$(basename "$OUTPUT") of=/dev/sdX bs=4M status=progress conv=fsync${NC}"
    echo -e "  Au premier demarrage armbian-resize-filesystem etend la racine a la carte ; console HDMI/serie et ssh, root:osmo."
else
echo -e "${GREEN}${BOLD}═══ ISO prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
