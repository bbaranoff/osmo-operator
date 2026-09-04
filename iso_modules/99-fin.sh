#!/bin/bash
# iso_modules/99-fin.sh - rootfs transmis a la passe suivante, resume
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Le rootfs survit a cette passe si la parente le demande (--all) ─────────
# Deplace, pas copie : meme systeme de fichiers, instantane. cleanup() efface
# ensuite $WORK sans lui.
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
    echo -e "${GREEN}${BOLD}═══ Image SD Raspberry Pi 4 prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
    echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
    echo -e "  Gravure : ${CYAN}dd if=$(basename "$OUTPUT") of=/dev/sdX bs=4M status=progress conv=fsync${NC}"
    echo -e "  Au premier demarrage la racine s etend a la carte ; console HDMI/serie et ssh, root:osmo."
else
echo -e "${GREEN}${BOLD}═══ ISO prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
fi

