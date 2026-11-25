# iso_modules/80-chroot.d/64-apparence.sh - raccourcis, gschema, fond d ecran, favoris du dock.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

    # Screen lock and suspend disabled: the bench screen stays on during captures
    # and calls, and a live session has no chosen password. The keyboard layout
    # follows --kb. printf instead of a heredoc: gschema values need apostrophes
    # (written as \047 inside this single-quoted block).
    # ── Conky arrows on the keyboard ────────────────────────────────────
    # Conky windows ignore the pointer, so the operator selection shown by Conky
    # is changed with Ctrl+AltGr+Right (next) and Ctrl+AltGr+Left (previous).
    # Ctrl+Alt+arrows stay with GNOME workspaces; AltGr is ISO_Level3_Shift,
    # <Mod5> in GTK accelerator syntax. osmo-op writes /run/osmo-fft/operator,
    # read by the panel, osmo-fft-snap.py and Conky.
    printf "[org.gnome.settings-daemon.plugins.media-keys]\ncustom-keybindings=[\047/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/\047,\047/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/\047]\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/]\nname=\047osmo-operator : arret suivant (Conky)\047\ncommand=\047/usr/local/bin/osmo-op --next\047\nbinding=\047<Control><Mod5>Right\047\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/]\nname=\047osmo-operator : arret precedent (Conky)\047\ncommand=\047/usr/local/bin/osmo-op --prev\047\nbinding=\047<Control><Mod5>Left\047\n\n" \
        > /usr/share/glib-2.0/schemas/98-osmo-keys.gschema.override

    printf "[org.gnome.desktop.session]\nidle-delay=uint32 0\n\n[org.gnome.desktop.screensaver]\nlock-enabled=false\nidle-activation-enabled=false\n\n[org.gnome.settings-daemon.plugins.power]\nsleep-inactive-ac-type=\047nothing\047\nsleep-inactive-battery-type=\047nothing\047\n\n[org.gnome.desktop.input-sources]\nsources=[(\047xkb\047,\047%s\047)]\n" \
        "${OSMO_ISO_KB:-fr}" > /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    # ── Light mode, Yaru blue ───────────────────────────────────────────
    # Blue accent (Yaru-blue icons), light color scheme by default, same as the
    # native install (install_modules/80-bureau.sh); dark mode is available in
    # Settings > Appearance. The :ubuntu sections duplicate the plain one
    # (10_ubuntu-settings.gschema.override sets gtk-theme=Yaru there and the ubuntu
    # session reads it first); :GNOME-Greeter applies the theme to the gdm screen.
    for _sec in "org.gnome.desktop.interface" "org.gnome.desktop.interface:ubuntu" "org.gnome.desktop.interface:GNOME-Greeter"; do
        printf "\n[%s]\ncolor-scheme=\047default\047\ngtk-theme=\047Yaru-blue\047\nicon-theme=\047Yaru-blue\047\ncursor-theme=\047Yaru\047\n" "$_sec" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    done
    unset _sec
    # ── GSM LAB wallpaper ───────────────────────────────────────────────
    # Set as the session DEFAULT through the schema (a user setting would not
    # survive a non-persistent live boot).
    #   gsm-lab-ville.jpg     idle wallpaper and schema default
    #   gsm-lab-antenne.jpg   same scene with the 2G/4G tower, faded in by
    #                         tools/osmo-fond.py when a 2G or 4G network starts
    #                         (osmo-launcher.py, osmo-panel.py); back to idle on stop
    #   gsm-lab-fond.jpg      low-poly landscape (tools/paysage-render.py), fallback
    #   gsm-lab-wallpaper.jpg tower illustration, also installed
    # 85-installeur-bureau.sh reinstalls the files from the local repository; the
    # schema names the wallpaper regardless. The native install
    # (install_modules/80-bureau.sh) uses the same wallpaper.
    _WP=/opt/GSM/osmo-operator/configs/gsm-lab-wallpaper.jpg
    _FOND=/opt/GSM/osmo-operator/configs/gsm-lab-fond.jpg
    _VILLE=/opt/GSM/osmo-operator/configs/gsm-lab-ville.jpg
    [ -f "$_WP" ] && install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-wallpaper.jpg
    [ -f "${_VILLE%ville.jpg}antenne.jpg" ] \
        && install -Dm644 "${_VILLE%ville.jpg}antenne.jpg" /usr/share/backgrounds/gsm-lab-antenne.jpg
    if [ -f "$_FOND" ]; then
        install -Dm644 "$_FOND" /usr/share/backgrounds/gsm-lab-fond.jpg
    elif [ -f "$_WP" ]; then
        install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-fond.jpg
    fi
    # The default is the DAY picture of the mast beacon (tools/osmo-balise.py,
    # placed with its variants by 85-installeur-bureau.sh): the beacon daemon
    # switches it to the evening while the bench runs.
    _JOUR=/opt/GSM/osmo-operator/configs/osmo-balise-jour.png
    if [ -f "$_VILLE" ]; then
        install -Dm644 "$_VILLE" /usr/share/backgrounds/gsm-lab-ville.jpg
        _DEFAUT=/usr/share/backgrounds/gsm-lab-ville.jpg
    fi
    if [ -f "$_JOUR" ]; then
        install -Dm644 "$_JOUR" /usr/share/backgrounds/osmo-balise/jour.png
        _DEFAUT=/usr/share/backgrounds/osmo-balise/jour.png
    elif [ -f "$_VILLE" ]; then
        :
    else
        _DEFAUT=/usr/share/backgrounds/gsm-lab-fond.jpg
    fi
    if [ -f "$_WP" ] || [ -f "$_FOND" ] || [ -f "$_VILLE" ] || [ -f "$_JOUR" ]; then
        # Three sections: the plain value plus the [schema:ubuntu] and
        # [schema:GNOME-Greeter] desktop overrides from
        # 10_ubuntu-settings.gschema.override, which an ubuntu:GNOME session reads
        # first (otherwise the greeter and DING would use the Ubuntu default).
        for _sec in "org.gnome.desktop.background" "org.gnome.desktop.background:ubuntu" "org.gnome.desktop.background:GNOME-Greeter"; do
            printf "\n[%s]\npicture-uri=\047file://%s\047\npicture-uri-dark=\047file://%s\047\npicture-options=\047zoom\047\nprimary-color=\047#0d1b2a\047\n" "$_sec" "$_DEFAUT" "$_DEFAUT" \
                >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        done
        unset _sec
        # Desktop icons (DING): the home folder ONLY, in the top-left corner,
        # where the wallpaper leaves room (no trash, volumes, network volumes,
        # drop place; no launchers either, 85-installeur-bureau.sh).
        for _sec in "org.gnome.shell.extensions.ding" "org.gnome.shell.extensions.ding:ubuntu"; do
            printf "\n[%s]\nstart-corner=\047top-left\047\nshow-home=true\nshow-trash=false\nshow-volumes=false\nshow-network-volumes=false\nshow-drop-place=false\n" "$_sec" \
                >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        done
        unset _sec
        echo "  [desktop] fond d ecran GSM LAB pose : $_DEFAUT"
    else
        echo "  [desktop] WARN: $_WP absent -- fond d ecran GNOME par defaut"
    fi
    # ── Dock: bench favorites ───────────────────────────────────────────
    # Set as the schema DEFAULT (non-persistent live) and also in
    # [org.gnome.shell:ubuntu], which 10_ubuntu-settings fills with the Ubuntu list
    # and the ubuntu:GNOME session reads first.
    # Entries pointing to a missing .desktop are silently ignored by GNOME Shell,
    # so deka.desktop and claude.desktop may be listed even when not installed
    # (deka comes from addition.sh). firefox.desktop is the Mozilla .deb one;
    # osmo-pmos.desktop (postmarketOS/Phosh VM) comes from
    # tools/osmo-extras-install.sh.
    for _sec in "org.gnome.shell" "org.gnome.shell:ubuntu"; do
        printf "\n[%s]\nfavorite-apps=[\047osmo-info.desktop\047, \047firefox.desktop\047, \047org.gnome.Nautilus.desktop\047, \047claude.desktop\047, \047osmo-launch.desktop\047, \047osmo-gtk.desktop\047, \047osmo-install.desktop\047, \047osmo-tutorial.desktop\047, \047osmo-addition.desktop\047, \047osmo-multi.desktop\047, \047osmo-update.desktop\047, \047osmo-paint.desktop\047, \047deka.desktop\047, \047linphone.desktop\047, \047osmo-wireshark-root.desktop\047, \047osmo-pmos.desktop\047, \047osmo-lte.desktop\047]\n" "$_sec" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    done
    unset _sec
    echo "  [desktop] favoris du dock poses (14 entrees)"

true
