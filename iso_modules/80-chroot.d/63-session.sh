# iso_modules/80-chroot.d/63-session.sh - session : graphical.target, audio, NetworkManager, autologin, PipeWire.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

    systemctl set-default graphical.target

    # ── Audio: system-wide PulseAudio, also on noble ───────────────────────
    # ubuntu-desktop-minimal on noble depends on pipewire-pulse; the bench relies on
    # the SYSTEM pulseaudio daemon (/run/pulse/native, osmo-pulse.service: gsm_audio
    # sink, gapk). Installing pulseaudio removes the desktop METAPACKAGE only; the
    # desktop packages are then marked manual so autoremove keeps them.
    #
    # pulseaudio and pipewire-pulse are co-installable on noble, so pipewire-pulse
    # must be purged explicitly: otherwise it holds /run/user/<uid>/pulse/native,
    # and since wireplumber has no ALSA access (51-osmo-no-alsa.lua, the cards
    # belong to the system daemon) the session only sees "Dummy Output" and is
    # silent. This shows only for non-root users (installed disk).
    #
    # pipewire-pulse is purged, its user units masked (it may come back with a
    # desktop update) and the result verified. pipewire itself stays (GNOME
    # screencast). The session is connected to the system daemon by
    # /etc/pulse/client.conf.d and a user unit, both installed by
    # iso_modules/82-services.sh.
    if [ "$_S" = "noble" ]; then
        _auto=$(apt-mark showauto)
        composant pulseaudio net_retry apt-fast install -y $APT_OPTS pulseaudio pulseaudio-utils
        if [ -n "$_auto" ]; then apt-mark manual $_auto >/dev/null 2>&1 || true; fi
        # Explicit purge: installing pulseaudio does not remove it.
        apt-get purge -y pipewire-pulse pipewire-media-session >/dev/null 2>&1 || true
        systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
        # Masked in case a desktop update reinstalls pipewire-pulse: the socket
        # /run/user/<uid>/pulse/native must stay free for the link to the system daemon.
        systemctl --global mask pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true
        # wireplumber stays (GNOME screencast uses PipeWire) but must not take the
        # sound cards: they belong to the pulseaudio daemon.
        mkdir -p /etc/wireplumber/main.lua.d
        printf "alsa_monitor.enabled = false\n" > /etc/wireplumber/main.lua.d/51-osmo-no-alsa.lua
        if [ -x /usr/bin/pulseaudio ]; then
            echo "  [desktop] audio : pulseaudio systeme retabli ($(dpkg-query -W -f=\${Version} pulseaudio)), wireplumber sans ALSA"
        else
            echo "  [desktop] WARN: /usr/bin/pulseaudio toujours absent - osmo-pulse.service echouera"
        fi
        # Verify that pipewire-pulse is really gone.
        if [ -x /usr/bin/pipewire-pulse ]; then
            echo "  [desktop] WARN: pipewire-pulse TOUJOURS PRESENT - il prendra /run/user/<uid>/pulse/native et le bureau sera muet"
        else
            echo "  [desktop] audio : pipewire-pulse purge (pipewire reste pour le screencast)"
        fi
    fi

    # ── NetworkManager: enabled ────────────────────────────────────────────
    # systemd-networkd keeps the bench interfaces (apn0, packet core tun/veth);
    # NetworkManager manages the physical cards (Wi-Fi, VPN, manual switching).
    # The split is defined in /etc/NetworkManager/conf.d/10-osmo-networkd.conf,
    # written outside this chroot. Without it both would fight over the same card.
    systemctl unmask NetworkManager 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    # ── No network wait at boot ────────────────────────────────────────────
    # The wait-online units can delay boot by minutes: bench interfaces (apn0,
    # tun/veth) are never "online" in their sense and the WAN cable is often
    # unplugged. Nothing we start needs a default route first (bench units use
    # Restart=on-failure, osmo-update exits 0 offline).
    # They are MASKED (not just disabled) because third-party units (apt-daily,
    # snapd...) pull network-online.target, which then becomes immediate. This
    # also avoids an extra delay at shutdown.
    systemctl disable NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask    NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true

    # ── Autologin ──────────────────────────────────────────────────────────
    # Directly as root (there is no separate "osmocom" account). GDM refuses
    # sessions for uid 0 through PAM, not gdm3.conf:
    #     auth required pam_succeed_if.so user != root quiet_success
    # That line is commented out, otherwise no login works at all.
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin 2>/dev/null || true
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<GDM
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 forced: under VirtualBox/QEMU the GNOME Wayland session falls back to
# llvmpipe and is unusable.
WaylandEnable=false
GDM

    # ── PipeWire for the root session ──────────────────────────────────────
    # GNOME screencast (Ctrl+Alt+Shift+R) requires PipeWire, and the upstream
    # pipewire.socket/pipewire.service units carry ConditionUser=!root, so the
    # root autologin session would have no /run/user/0/pipewire-0.
    # An EMPTY assignment resets the inherited conditions (the systemd way to
    # cancel them). /etc/systemd/user/ applies to every account.
    # Known limitation: PipeWire as root is not supported upstream. On noble the
    # wireplumber ALSA monitor is disabled above (51-osmo-no-alsa.lua) so it does
    # not compete with the bench pulseaudio --system.
    for _pwu in pipewire.socket pipewire.service; do
        mkdir -p "/etc/systemd/user/${_pwu}.d"
        # Double quotes: this block is inside single quotes.
        printf "[Unit]\nConditionUser=\n" > "/etc/systemd/user/${_pwu}.d/10-allow-root.conf"
    done
    unset _pwu

    # The first-login assistant would run at EVERY boot on a non-persistent live:
    # disable it.
    rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop
    for h in /root; do
        mkdir -p "$h/.config" && echo yes > "$h/.config/gnome-initial-setup-done"
    done

true
