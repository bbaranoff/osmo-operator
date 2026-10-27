#!/bin/bash
# iso_modules/84-comptes.sh - step 8d: accounts, console/desktop autologin, linphone
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not meant to run on its own. A top-level `return` means "nothing to do here"
# (this is how --arm skips a step).

# ══════════════════════════════════════════════════════════════════════════════
# Step 8d: accounts, session, installer - everything that contains apostrophes
# ══════════════════════════════════════════════════════════════════════════════
# Written here rather than in the step 8 chroot, which is a single-quoted
# bash -c: one extra apostrophe changes the meaning of everything after it.
# Calamares configs, sudoers and systemd units are full of them, so they are
# written directly into "$ROOTFS" with the script's normal quoting.
echo -e "${GREEN}[8d/9] Comptes, session et installeur...${NC}"

# ── Account model ──────────────────────────────────────────────────────────
# root is the working account: the bench is driven as root (start-native.sh,
# VTYs, tcpdump, netns) and the whole repository assumes it. The session opens
# as root and terminals opened in it are root without prompting.
#
# osmocom is a second, unprivileged sudoer account with its own UID - a
# sandbox for what does not need full privileges (browser, ordinary desktop
# session). It is used explicitly (log out and pick it in GDM, or
# "su - osmocom"), never by default.
chroot "$ROOTFS" env LC_ALL=C.UTF-8 LANGUAGE= bash -c "
set -u
id -u osmocom >/dev/null 2>&1 || useradd -m -s /bin/bash -c 'Compte osmocom (non privilegie)' osmocom
echo 'osmocom:osmo' | chpasswd
echo 'root:osmo'    | chpasswd
passwd -u root >/dev/null 2>&1 || true
for g in sudo adm dialout audio video plugdev netdev cdrom; do
    getent group \$g >/dev/null && usermod -aG \$g osmocom
done
" 2>/dev/null || echo -e "  ${YELLOW}!${NC} creation des comptes incomplete"
echo -e "  ${GREEN}✓${NC} comptes : ${CYAN}root${NC} (travail, mdp osmo) et ${CYAN}osmocom${NC} (non privilegie, sudoer, mdp osmo)"

# ── Console logs in as root ───────────────────────────────────────────────
# On the live USB there is nobody to authenticate: a tty1 password protects
# nothing (whoever holds the medium holds the machine). --noclear keeps the
# boot messages on screen, often the only trace of a failed module.
install -d "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/10-autologin-root.conf" <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTY
install -d "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin-root.conf" <<'GETTYS'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
GETTYS
# Pi 4: console=serial0 -> ttyS0 (mini-UART, enable_uart=1) or ttyAMA0
# (PL011) depending on the overlay; both units get the same drop-in.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    install -d "$ROOTFS/etc/systemd/system/serial-getty@ttyAMA0.service.d"
    cp "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin-root.conf" \
       "$ROOTFS/etc/systemd/system/serial-getty@ttyAMA0.service.d/10-autologin-root.conf"
fi
echo -e "  ${GREEN}✓${NC} tty1 et console serie : ouverture automatique sur ${CYAN}root${NC}"

# ── Desktop autologin too ─────────────────────────────────────────────────
# Step 8 already sets AutomaticLogin=root in /etc/gdm3/custom.conf; it is
# rewritten here unconditionally so the setting is identical on the live USB
# and on the installed system (where shellprocess-osmo.conf writes it).
# Harmless when ISO_DESKTOP=0 (GDM not installed).
if [ -d "$ROOTFS/etc/gdm3" ] || [ "${ISO_DESKTOP:-0}" = "1" ]; then
    install -d "$ROOTFS/etc/gdm3"
    cat > "$ROOTFS/etc/gdm3/custom.conf" <<'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 forced: under VirtualBox/QEMU the GNOME 42 Wayland session falls back to
# llvmpipe and is unusable.
WaylandEnable=false
GDMCONF
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        "$ROOTFS/etc/pam.d/gdm-password" "$ROOTFS/etc/pam.d/gdm-autologin" 2>/dev/null || true
    install -d "$ROOTFS/root/.config" "$ROOTFS/home/osmocom/.config"
    echo yes > "$ROOTFS/root/.config/gnome-initial-setup-done"
    echo yes > "$ROOTFS/home/osmocom/.config/gnome-initial-setup-done"
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} session graphique : ouverture automatique sur ${CYAN}root${NC} (osmocom au choix, apres deconnexion)"
fi

# ── Linphone: pre-provisioned account ─────────────────────────────────────
# The account must exist before the client's first start: Linphone does not
# reload linphonerc at runtime and rewrites it on exit, so an account added
# while it runs never sends REGISTER (Asterisk shows the endpoint
# "Unavailable" with no 401). Details of both pitfalls (live reload, presence
# publish) are in the header of configs/linphonerc.
if [ "${ISO_DESKTOP:-0}" = "1" ] && [ -f "$DIR/configs/linphonerc" ]; then
    # Both accounts plus /etc/skel: the session opens as root (gdm3 above),
    # osmocom stays available after logout, and skel covers accounts created by
    # the installer on the target system.
    for _lh in "$ROOTFS/root" "$ROOTFS/home/osmocom" "$ROOTFS/etc/skel"; do
        install -d "$_lh/.config/linphone"
        cp -a "$DIR/configs/linphonerc" "$_lh/.config/linphone/linphonerc"
    done
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} linphone : compte ${CYAN}linphone_A${NC} pre-provisionne (poste ${CYAN}100${NC}, UDP vers 127.0.0.1:5060)"
fi


# End of module: `. file` returns the status of its last command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
