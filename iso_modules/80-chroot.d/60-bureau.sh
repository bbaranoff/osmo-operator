# iso_modules/80-chroot.d/60-bureau.sh - bureau : ubuntu-desktop-minimal, wireshark, linphone, avahi purge.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

# ── DESKTOP variant: desktop, wireshark GUI, linphone ──────────────────────
# Placed after the main apt-get install (shared deps already present), before
# update-initramfs (the desktop pulls plymouth and modules for the initrd) and
# before apt-get clean.
    echo "  [desktop] ubuntu-desktop-minimal + wireshark + linphone-desktop"

    # WITH recommends: ubuntu-desktop-minimal puts almost everything in
    # Recommends. With --no-install-recommends it installs gnome-shell without
    # gdm3, session or terminal, giving a black screen at boot.
    #
    # linphone-desktop is the graphical client (linphone is a transition package).
    # wireshark pulls wireshark-qt. wmctrl + x11-utils (xdpyinfo): launch.sh tiles
    # the four windows into screen quarters (optional, placement only).
    #
    # One call for the desktop AND the installer (calamares, signed grub,
    # partitioning tools: see the next block). A failure stops the build: without
    # desktop or installer this image is useless.
    # snapd is not requested (the browser is a Mozilla .deb) but still comes as a
    # recommendation of ubuntu-desktop-minimal; see the snapd handling below.
    # x11-xserver-utils: xhost, used by run-as-owner (step 8i) to allow the
    # encrypted-home account on the root session X server.
    apt-fast install -y $APT_OPTS \
        ubuntu-desktop-minimal wireshark linphone-desktop \
        vlc chrome-gnome-shell \
        wmctrl x11-utils x11-xserver-utils xdotool zenity librsvg2-common \
        calamares squashfs-tools rsync dosfstools efibootmgr os-prober \
        cryptsetup cryptsetup-initramfs lvm2 pciutils ubuntu-drivers-common \
        conky-all fonts-dejavu fonts-ubuntu screenfetch bash-completion overlayroot age attr cmatrix xterm python3-pil python3-numpy python3-pytest python3-gi python3-gi-cairo python3-cairo gir1.2-gtk-3.0 gir1.2-vte-2.91 \
        grub2-common grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-pc-bin \
        qml-module-qtquick2 qml-module-qtquick-layouts \
        qml-module-qtquick-window2 qml-module-qtquick-controls

    # ── Avahi: purged ───────────────────────────────────────────────────────
    # avahi comes only as a Recommends of ubuntu-desktop-minimal. On a GSM bench
    # avahi-daemon broadcasts mDNS (224.0.0.251:5353) on every interface, apn0 and
    # docker veths included, polluting GSMTAP and SIP captures; all addresses here
    # are static. --purge with libnss-mdns, and the mdns entries are removed from
    # /etc/nsswitch.conf so lookups do not query an absent service.
    apt-fast purge -y $APT_OPTS avahi-daemon avahi-utils avahi-autoipd libnss-mdns 2>/dev/null \
        || echo "  [desktop] avahi deja absent"
    apt-fast autoremove -y $APT_OPTS 2>/dev/null || true
    # Masked so that a future dependency cannot start it again.
    systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    # Double quotes only, no apostrophe (this block is inside a single-quoted
    # bash -c string, and bash -n on build-iso.sh cannot detect a stray one).
    sed -i "s/[[:space:]]*mdns4_minimal[[:space:]]*\[NOTFOUND=return\]//; s/[[:space:]]*mdns4//" \
        /etc/nsswitch.conf 2>/dev/null || true
    echo "  [desktop] avahi purge (mDNS retire du banc)"

true
