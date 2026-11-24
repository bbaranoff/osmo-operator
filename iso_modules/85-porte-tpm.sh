#!/bin/bash
# iso_modules/85-porte-tpm.sh - step 8p: the PORTE (TPM code before nirvana's
# passphrase) of an installed bench.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step). Runs before
# 86-finitions.sh, while /proc, /sys and /dev are still in the rootfs.
#
# What it puts in the image:
#   /etc/osmo-porte/initramfs   initramfs-tools config of the porte
#                               (configs/porte/initramfs: boot=osmo-porte)
#   /boot/osmo-porte.img        the porte initrd for the image's kernel -
#                               copied with that kernel onto the osmo-racine
#                               partition at installation (osmo-racine-copier)
#   /usr/local/sbin/osmo-porte  sealing / QR / state, from nirvana's system
# The first GRUB menu (osmo-grub-esp) boots the porte only when the machine
# HAS an active TPM; otherwise GRUB asks the passphrase itself.

if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi
_PO_SRC="$DIR/configs/porte"
[ -d "$_PO_SRC/initramfs" ] || { echo -e "  ${YELLOW}!${NC} configs/porte absent - porte TPM sautee"; return 0; }

echo -e "${GREEN}[8p/9] Porte TPM (code avant la phrase de nirvana)...${NC}"
install -d "$ROOTFS/etc/osmo-porte"
rm -rf "$ROOTFS/etc/osmo-porte/initramfs"
cp -r "$_PO_SRC/initramfs" "$ROOTFS/etc/osmo-porte/initramfs"
chmod 755 "$ROOTFS/etc/osmo-porte/initramfs/hooks/"*
install -m 0755 "$_PO_SRC/osmo-porte" "$ROOTFS/usr/local/sbin/osmo-porte"
# several people on nirvana's system: a LUKS key slot and an fscrypt home each
install -m 0755 "$_PO_SRC/osmo-utilisateur" "$ROOTFS/usr/local/sbin/osmo-utilisateur"

# kexec-tools must not take over reboots (its debconf default may): the porte
# uses kexec itself, the system reboots through the firmware
printf 'LOAD_KEXEC=false\n' > "$ROOTFS/etc/default/kexec"

_PO_VER="$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"; _PO_VER="${_PO_VER##*/vmlinuz-}"
if [ -n "$_PO_VER" ] && chroot "$ROOTFS" mkinitramfs -d /etc/osmo-porte/initramfs \
        -o /boot/osmo-porte.img "$_PO_VER" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} porte : /boot/osmo-porte.img ($(du -h "$ROOTFS/boot/osmo-porte.img" | cut -f1), noyau ${CYAN}${_PO_VER}${NC})"
else
    echo -e "  ${YELLOW}!${NC} initrd de la porte non construit - les machines installees demanderont la phrase dans GRUB"
fi

# reminder at login until the code is sealed (nirvana's system, TPM present)
install -d "$ROOTFS/etc/xdg/autostart"
cat > "$ROOTFS/etc/xdg/autostart/osmo-porte-rappel.desktop" <<'RAPPEL'
[Desktop Entry]
Type=Application
Name=osmo-porte : code TPM a sceller
Exec=sh -c '[ -e /dev/tpmrm0 ] && [ -s /var/lib/osmo-porte/pcr-porte.bin ] && [ ! -s /etc/osmo-porte/secret.bin ] && [ "$(id -u)" != 0 ] && notify-send -u critical "Code TPM de la porte non scelle" "Dans un terminal : sudo osmo-porte sceller, puis sudo osmo-porte qr"'
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
RAPPEL

# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
