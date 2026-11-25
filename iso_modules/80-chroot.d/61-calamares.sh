# iso_modules/80-chroot.d/61-calamares.sh - installeur Calamares et ses outils (rsync, unsquashfs, GRUB signe).
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

    # ── Installer: Calamares (Ubiquity needs casper, this image uses live-boot) ──
    # Calamares is told where the squashfs is. Its configuration lives in the
    # repository (installer/calamares/) and is copied into the rootfs outside this
    # chroot (the files contain apostrophes).
    #
    # Each dependency covers a step:
    #   squashfs-tools  unpackfs, which copies the system to disk
    #   dosfstools      the FAT EFI partition
    #   efibootmgr      the UEFI boot entry
    #   os-prober       other systems, for the GRUB menu
    #   pciutils        lspci: NVIDIA card detection (osmo-install
    #   ubuntu-drivers  and contextualprocess@nvidia); ubuntu-drivers picks
    #   -common         the recommended nvidia-driver-5xx
    #   conky-all       the bench Conky dashboard (configs/conky/,
    #   python3-gi      the clickable live panel (tools/osmo-panel.py, GTK)
    #   gir1.2-gtk-3.0
    #   fonts-dejavu    GNOME autostart set below), live and installed disk
    #   python3-gi-     the c123 window (tools/osmo-c123-gtk.py): import cairo
    #   cairo (+cairo)  and Gdk.cairo_set_source_pixbuf, the emulated C123 screen
    #   lvm2            LVM in the Calamares manual partitioning (volume groups,
    #                   LUKS on LVM); its initramfs hook follows
    #   cryptsetup      LUKS: the installer encryption checkbox (partition.conf);
    #   (+ -initramfs)  cryptsetup-initramfs installs the hook that lets the target
    #                   initrd open an encrypted root
    #   qml-module-*    the slideshow during the copy
    # These packages are in the desktop apt-get install above (a failure aborts).
    # Here we also check that the binary exists, in case apt exits 0 without it.
    # We are inside the chroot: the binary is /usr/bin/calamares (no $ROOTFS here).
    if [ ! -x /usr/bin/calamares ]; then
        echo "ERREUR: calamares absent du rootfs apres apt-get - build DESKTOP interrompu." >&2
        echo "        (dependance Qt/KDE manquante au miroir ? relancer avec un cache .deb)" >&2
        exit 1
    fi

    # ── Tools Calamares calls but does not depend on ───────────────────────────
    # unpackfs runs unsquashfs and then rsync; without rsync the install fails
    # after partitioning with "error code 127" (command not found). Checked at
    # build time.
    for _t in rsync unsquashfs; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - unpackfs echouerait a l installation." >&2
            exit 1
        fi
    done

    # ── GRUB must be in the target, not only on the build host ─────────────
    # The calamares bootloader module runs grub-install INSIDE the installed
    # system (this rootfs); grub-install comes from grub2-common, not grub-common.
    # The signed binaries (shimx64, grubx64) are needed too: bootloader.conf sets
    # efiBootloaderId=ubuntu so the installed system boots with Secure Boot.
    for _t in grub-install grub-mkconfig grub-probe; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - le module bootloader echouerait." >&2
            exit 1
        fi
    done
    for _f in /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
              /usr/lib/shim/shimx64.efi.signed; do
        if [ ! -e "$_f" ]; then
            echo "ERREUR: $_f absent - le systeme installe ne demarrerait pas en Secure Boot." >&2
            exit 1
        fi
    done

true
