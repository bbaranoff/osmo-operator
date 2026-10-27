#!/bin/bash
# armbian/userpatches/customize-image.sh - install the osmo-operator stack into the Armbian image
#
# Run by armbian/build INSIDE the image chroot (arguments: $RELEASE $LINUXFAMILY $BOARD
# $BUILD_DESKTOP), with userpatches/overlay mounted at /tmp/overlay. Condensed equivalent of the
# ISO modules 50-injection-image, 80-chroot, 82-arm-natif and 84-comptes:
#   1. Ubuntu runtime packages needed by the stack (list from 80-chroot.sh, without kernel/live)
#   2. dpkg -i of the Docker build .debs (osmo-build-*: libosmocore, osmo-*, gapk, QEMU, osmocom-bb...)
#   3. copy of /tmp/overlay/osmo/rootfs onto / (/usr/local, /opt/GSM, /etc/osmocom, units...)
#   4. what an x86 host cannot produce, compiled HERE (aarch64): toast, qosmo launcher,
#      c54x_exe / grgsm_exe, bench .debs (packaging/build-debs.sh)
#   5. accounts (root/osmo, osmocom/osmo), no Armbian first-login wizard, services
# Kernel, Pi firmware and root filesystem resizing are handled by Armbian.
set -euo pipefail
RELEASE="${1:-}"; LINUXFAMILY="${2:-}"; BOARD="${3:-}"; BUILD_DESKTOP="${4:-}"
OV=/tmp/overlay/osmo
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
log() { echo "[osmo-customize] $*"; }
log "release=$RELEASE family=$LINUXFAMILY board=$BOARD desktop=$BUILD_DESKTOP overlay=$OV"
[ -d "$OV" ] || { log "pas d overlay $OV : image Armbian nue"; exit 0; }
[ -f "$OV/SOURCE" ] && log "pile : $(tr '\n' ' ' < "$OV/SOURCE")"
case "$RELEASE" in noble) ;; *) log "ATTENTION : les .deb du build visent noble, pas $RELEASE" ;; esac

# ── 1. Runtime packages ─────────────────────────────────────────────────────
apt-get update
PKGS="ca-certificates openssl netcat-openbsd socat tcpdump git logrotate systemd-resolved build-essential wget
      libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev libc-ares2
      libgnutls30t64 libgnutls28-dev libmnl-dev libmnl0
      libortp-dev libdbi1t64 libdbd-sqlite3 sqlite3
      libfftw3-single3 libusb-1.0-0 libgsm1 libasound2t64
      libsofia-sip-ua-glib3t64 liburing2 libslirp0
      iproute2 iptables net-tools lksctp-tools
      tmux telnet expect whiptail lsb-release openssh-server sudo
      console-setup keyboard-configuration locales psmisc cryptsetup rsync
      python3 python3-venv python3-scapy tshark wireshark-common
      libasound2-plugins pulseaudio pulseaudio-utils alsa-utils
      binutils-arm-none-eabi gdb-multiarch asterisk ffmpeg
      libzmq5 libfftw3-dev cmake libpcsclite-dev meson ninja-build flex bison
      libgcrypt20-dev libssl-dev libidn-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev
      libtins-dev libc-ares-dev zstd kpartx"
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS || {
    log "apt : certains paquets manquent sur $RELEASE/arm64, on pose ce qui existe"
    for p in $PKGS; do apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || log "  absent : $p"; done
}

# ── 2. Docker build .debs ───────────────────────────────────────────────────
if ls "$OV"/debs/*.deb >/dev/null 2>&1; then
    install -d /var/cache/osmo-debs
    cp -f "$OV"/debs/*.deb /var/cache/osmo-debs/
    dpkg -i --force-overwrite /var/cache/osmo-debs/osmo-build-*.deb || apt-get install -y -f
    ldconfig
    log "$(ls /var/cache/osmo-debs/*.deb | wc -l) paquets du build poses"
else
    log "pas de .deb du build dans l overlay : tout vient de l arbre rootfs/"
fi

# ── 3. Docker image tree ────────────────────────────────────────────────────
if [ -d "$OV/rootfs" ]; then
    cp -a "$OV/rootfs/." /
    ldconfig
    log "arbre recopie : $(du -sh "$OV/rootfs" | cut -f1) (/usr/local, /opt/GSM, /etc/osmocom, unites)"
fi

# ── 4. Native compilation (aarch64) ─────────────────────────────────────────
if [ ! -x /usr/local/bin/toast ]; then
    ( set -e; cd /opt/GSM
      wget -qO gsm-1.0.24.tar.gz https://www.quut.com/gsm/gsm-1.0.24.tar.gz
      tar xzf gsm-1.0.24.tar.gz && rm -f gsm-1.0.24.tar.gz && cd gsm-1.0-pl24
      make >/dev/null 2>&1 || true; [ -x bin/toast ] || make toast >/dev/null 2>&1
      for b in toast untoast tcat; do [ -e "bin/$b" ] && install -m755 "bin/$b" "/usr/local/bin/$b"; done
    ) && log "toast compile" || log "toast non compile (on continue)"
fi
for fork in qosmo; do
    if [ -d "/opt/GSM/$fork/tools/qosmo-launch" ]; then
        make -s -C "/opt/GSM/$fork/tools/qosmo-launch" ALIAS="$fork" "$fork" && install -Dm755 "/opt/GSM/$fork/tools/qosmo-launch/$fork" "/usr/local/bin/$fork" \
            && log "lanceur /usr/local/bin/$fork compile" || log "lanceur $fork : echec (run.sh appellera qemu-system-arm directement)"
    fi
done
for e in c54x_exe grgsm_exe; do
    [ -d "/opt/GSM/$e" ] && { make -s -B -C "/opt/GSM/$e" && log "$e compile" || log "$e : compilation echouee"; }
done
/usr/local/bin/qemu-system-arm --version >/dev/null 2>&1 && log "qemu-system-arm (aarch64) s execute" || log "qemu-system-arm absent ou KO"
if [ -x /opt/GSM/osmo-operator/packaging/build-debs.sh ]; then
    install -d /var/cache/osmo-debs
    env OSMO_OPERATOR_SRC=/opt/GSM/osmo-operator QOSMO_SRC=/opt/GSM/qosmo bash /opt/GSM/osmo-operator/packaging/build-debs.sh --out /var/cache/osmo-debs \
        && log ".deb du banc construits dans /var/cache/osmo-debs" || log ".deb du banc non construits (l image sort sans eux)"
fi

# ── 4b. Bench desktop (BUILD_DESKTOP=yes: minimal GNOME installed by Armbian) ─
# Subset of what the ISO --desktop adds on top of GNOME (iso_modules/80-chroot.sh,
# 85-installeur-bureau.sh) that makes sense on a board: X11 autologin as root, GSM LAB
# wallpaper, dark/Yaru blue theme, repository icons and dock, Conky and the panel
# (osmo-desktop-panel, extracted by build-armbian.sh), c123 and its GTK packages.
# No calamares, grub, secure boot, Mozilla firefox or GNOME extensions.
# Known limitation: GLava is not installed by default; its NCS circle needs OpenGL >= 4.2
# (imageLoad/Store), which neither the Pi 4 V3D nor the Orange Pi 5 Mali G610 provide under
# Mesa (GL 3.1). Use OSMO_ARM_GLAVA=1 sudo ./build-armbian.sh ... to try anyway (overlay marker OSMO_ARM_GLAVA).
if [ "$BUILD_DESKTOP" = yes ]; then
    REPO=/opt/GSM/osmo-operator
    DPKGS="conky-all fonts-dejavu python3-pil python3-gi python3-gi-cairo python3-cairo
           gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 gir1.2-vte-2.91 wmctrl x11-utils x11-xserver-utils
           xdotool zenity librsvg2-common yaru-theme-gtk yaru-theme-icon yaru-theme-gnome-shell
           wireshark vlc linphone-desktop gnome-terminal"
    apt-get update
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $DPKGS || {
        for p in $DPKGS; do apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || log "  bureau, absent : $p"; done
    }

    # gdm: root autologin under X11 (the bench runs as root; xdotool, xprop and Conky need X)
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin 2>/dev/null || true
    install -d /etc/gdm3
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=root\nWaylandEnable=false\n' > /etc/gdm3/custom.conf
    rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop

    # Schema defaults: wallpaper, theme, idle, keyboard, dock (same values as the ISO)
    OVR=/usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    FOND=/usr/share/backgrounds/gsm-lab-ville.jpg
    for f in gsm-lab-ville.jpg gsm-lab-antenne.jpg gsm-lab-fond.jpg; do
        [ -f "$REPO/configs/$f" ] && install -Dm644 "$REPO/configs/$f" "/usr/share/backgrounds/$f"
    done
    [ -f "$FOND" ] || FOND=/usr/share/backgrounds/gsm-lab-fond.jpg
    printf "[org.gnome.desktop.session]\nidle-delay=uint32 0\n\n[org.gnome.desktop.screensaver]\nlock-enabled=false\nidle-activation-enabled=false\n\n[org.gnome.settings-daemon.plugins.power]\nsleep-inactive-ac-type='nothing'\nsleep-inactive-battery-type='nothing'\n\n[org.gnome.desktop.input-sources]\nsources=[('xkb','%s')]\n" \
        "${OSMO_KB:-fr}" > "$OVR"
    for sec in org.gnome.desktop.interface org.gnome.desktop.interface:GNOME-Greeter; do
        printf "\n[%s]\ncolor-scheme='default'\ngtk-theme='Yaru-blue'\nicon-theme='Yaru-blue'\ncursor-theme='Yaru'\n" "$sec" >> "$OVR"
    done
    if [ -f "$FOND" ]; then
        for sec in org.gnome.desktop.background org.gnome.desktop.background:GNOME-Greeter; do
            printf "\n[%s]\npicture-uri='file://%s'\npicture-uri-dark='file://%s'\npicture-options='zoom'\nprimary-color='#0d1b2a'\n" "$sec" "$FOND" "$FOND" >> "$OVR"
        done
    fi
    printf "\n[org.gnome.shell]\nfavorite-apps=['osmo-info.desktop', 'org.gnome.Nautilus.desktop', 'osmo-launch.desktop', 'osmo-tutorial.desktop', 'osmo-addition.desktop', 'osmo-update.desktop', 'linphone.desktop', 'org.wireshark.Wireshark.desktop', 'org.gnome.Terminal.desktop']\n" >> "$OVR"
    printf "[org.gnome.settings-daemon.plugins.media-keys]\ncustom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/','/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/']\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/]\nname='osmo-operator : arret suivant (Conky)'\ncommand='/usr/local/bin/osmo-op --next'\nbinding='<Control><Mod5>Right'\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/]\nname='osmo-operator : arret precedent (Conky)'\ncommand='/usr/local/bin/osmo-op --prev'\nbinding='<Control><Mod5>Left'\n" \
        > /usr/share/glib-2.0/schemas/98-osmo-keys.gschema.override
    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || log "glib-compile-schemas a echoue"

    # Repository icons (except multi: installed by addition.sh --multi, see 85-installeur-bureau.sh)
    install -d /usr/share/applications /usr/share/icons/hicolor/scalable/apps
    for d in "$REPO"/data/desktop/*.desktop; do
        [ -f "$d" ] || continue
        e=$(basename "$d" .desktop); [ "$e" = osmo-multi ] && continue
        install -m644 "$d" "/usr/share/applications/$e.desktop"
        [ -f "$REPO/data/$e.svg" ] && install -m644 "$REPO/data/$e.svg" "/usr/share/icons/hicolor/scalable/apps/$e.svg"
    done
    gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true

    # Desktop commands in PATH (same links as iso_modules/70-scripts.sh)
    ln -sf "$REPO/start-native.sh"        /usr/local/bin/osmo-start-native
    ln -sf "$REPO/tools/osmo-fond.py"     /usr/local/bin/osmo-fond
    ln -sf "$REPO/tools/osmo-op.sh"       /usr/local/bin/osmo-op
    ln -sf "$REPO/tools/osmo-drivers.sh"  /usr/local/bin/osmo-drivers
    ln -sf "$REPO/tools/overlay-draw.py"  /usr/local/bin/overlay-draw
    ln -sf "$REPO/tools/osmo-c123-gtk.py" /usr/local/bin/c123
    ln -sf "$REPO/tools/osmo-c123-gtk.py" /usr/local/bin/osmo-c123

    # Conky and the panel, kept alive for the whole session (same watchdog as the ISO)
    if [ -s "$OV/osmo-desktop-panel" ]; then
        install -m755 "$OV/osmo-desktop-panel" /usr/local/bin/osmo-desktop-panel
        install -d /etc/xdg/autostart
        printf '[Desktop Entry]\nType=Application\nName=Conky osmo-operator\nComment=Tableau de bord du banc GSM\nExec=/usr/local/bin/osmo-desktop-panel\nIcon=utilities-system-monitor\nTerminal=false\nNoDisplay=true\nOnlyShowIn=GNOME;\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=6\n' \
            > /etc/xdg/autostart/osmo-conky.desktop
        log "bureau : Conky + encart a la connexion"
    fi

    if [ -f "$OV/OSMO_ARM_GLAVA" ]; then
        apt-get install -y --no-install-recommends git meson ninja-build gcc pkg-config patch \
            libpulse-dev libx11-dev libxext-dev libxrender-dev libxcomposite-dev libgl-dev >/dev/null \
            && bash "$REPO/tools/glava-build.sh" && log "GLava pose (OSMO_ARM_GLAVA)" \
            || log "GLava non pose"
    fi
    log "bureau du banc pose (fond $FOND)"
fi

# Bench aliases (banc-rssi, banc-trx, c123-1...): profile.d AND real commands, desktop or not
if [ -f /opt/GSM/osmo-operator/scripts/osmo-banc-aliases.sh ]; then
    install -m644 /opt/GSM/osmo-operator/scripts/osmo-banc-aliases.sh /etc/profile.d/98-osmo-banc-aliases.sh
    bash /opt/GSM/osmo-operator/tools/osmo-banc-cmd.sh --install /usr/local/bin
fi

# ── 5. Accounts, first login, services ──────────────────────────────────────
id -u osmocom >/dev/null 2>&1 || useradd -m -s /bin/bash -c 'Compte osmocom (non privilegie)' osmocom
echo 'osmocom:osmo' | chpasswd
echo 'root:osmo'    | chpasswd
usermod -aG sudo,audio,dialout,plugdev osmocom 2>/dev/null || true
rm -f /root/.not_logged_in_yet  # no Armbian first-login wizard: accounts are already set
for u in osmo-egprs-web osmo-pulse; do systemctl enable "$u" 2>/dev/null || true; done
for u in osmo-banc osmo-multi; do  # installed, not enabled: set OSMO_IMAGE_BANC=1 / OSMO_IMAGE_MULTI=1 in the overlay to enable
    v="OSMO_IMAGE_${u#osmo-}"; v="${v^^}"
    [ -f "$OV/$v" ] && systemctl enable "$u" 2>/dev/null && log "$u active au boot"
done
apt-get clean; rm -rf /var/lib/apt/lists/*
log "termine"
