#!/bin/bash
# iso_modules/89-home-chiffre.sh - step 8i: encrypted second disk on /home.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment variables:
#   OSMO_ISO_CRYPTHOME_OWNER  account owning the encrypted home (default osmocom)

# ══════════════════════════════════════════════════════════════════════════════
# Step 8i: the system disk stays readable, secrets go to the second disk
# ══════════════════════════════════════════════════════════════════════════════
# Model: everything system-related is readable, everything keyring-related is
# encrypted.
#
# The system disk is intentionally NOT encrypted: the bench is driven as root
# (VTY, netns, tcpdump), the session logs in as root, and an operator must be
# able to extract a trace, read a log or repair the machine from a live key
# without decrypting anything.
#
# Secrets (GNOME keyring, browser cookies and tokens, profiles) live on a
# second LUKS2 disk mounted on /home. The unprivileged osmocom account has its
# home there, and applications holding secrets run as that account from the
# root session (run-as-owner).
#
# At boot the machine asks "decrypt /home -passphrase- or Enter" on the text
# console (plymouth is quit first, see unlock-home). An empty answer, a wrong
# passphrase or no answer never blocks the boot: the root session opens, /home
# stays empty, and the same applications start without secrets.
#
# Encryption is done by Calamares at install time:
#   - installer/calamares/modules/partition.conf splits the disk into root +
#     /home and marks root "noEncrypt", so "encrypt system" only encrypts
#     /home (LUKS2);
#   - crypthome-postinstall, run by shellprocess@osmo in the target, wires up
#     the result: crypttab and fstab entries ("noauto"), /etc/default/crypthome
#     (UUID, mapping, session owner), root keyring placed on the volume.
#
# This module encrypts nothing: it installs the tools in the rootfs for the
# live key and the target. With CRYPTHOME_UUID empty (live key, or install
# without encryption) unlock-home has nothing to do and exits.
#
# init-crypthome.sh covers the case Calamares does not: encrypting a second
# disk added later to an installed machine.
#
# run-as-owner is not a sandbox workaround: Firefox runs fine as root but would
# then write its cookies, tokens and keyring in clear on the system disk. The
# owner account is where secrets live, since its home is on the encrypted disk.
# It generalises the vlc wrapper of step 8e (85-installeur-bureau.sh: xhost,
# runuser, PULSE_SERVER, XDG_RUNTIME_DIR) to all applications holding secrets,
# conditionally: if the disk is not unlocked the application runs as root.
_CH_SRC="$DIR/configs/crypthome"
if [ ! -d "$_CH_SRC" ]; then
    echo -e "  ${YELLOW}!${NC} configs/crypthome absent - etape 8i sautee"
    return 0
fi

echo -e "${GREEN}[8i/9] Second disque chiffre sur /home (outils, rien n est chiffre ici)...${NC}"

# Account owning the encrypted home: osmocom (unprivileged), overridable.
_CH_OWNER="${OSMO_ISO_CRYPTHOME_OWNER:-osmocom}"

# ── Tools ──────────────────────────────────────────────────────────────────
# unlock-home / lock-home in sbin (they mount/unmount), run-as-owner and
# crypthome-session-setup in bin (called from the session).
install -d "$ROOTFS/usr/local/sbin" "$ROOTFS/usr/local/bin" "$ROOTFS/root" \
           "$ROOTFS/etc/systemd/system" "$ROOTFS/etc/default" "$ROOTFS/usr/local/share/applications"
install -m 0755 "$_CH_SRC/unlock-home"            "$ROOTFS/usr/local/sbin/unlock-home"
install -m 0755 "$_CH_SRC/lock-home"              "$ROOTFS/usr/local/sbin/lock-home"
install -m 0755 "$_CH_SRC/crypthome-fond"         "$ROOTFS/usr/local/sbin/crypthome-fond"  # background image for the LUKS prompt
install -m 0755 "$_CH_SRC/refresh-owner-apps"     "$ROOTFS/usr/local/sbin/refresh-owner-apps"
install -m 0755 "$_CH_SRC/run-as-owner"           "$ROOTFS/usr/local/bin/run-as-owner"
install -m 0755 "$_CH_SRC/crypthome-session-setup" "$ROOTFS/usr/local/bin/crypthome-session-setup"
install -m 0700 "$_CH_SRC/init-crypthome.sh"      "$ROOTFS/root/init-crypthome.sh"
# Run by Calamares in the target (shellprocess@osmo) to wire up the /home the
# installer just encrypted. In sbin because it edits crypttab, fstab and
# /etc/default/crypthome.
install -m 0755 "$_CH_SRC/crypthome-postinstall"  "$ROOTFS/usr/local/sbin/crypthome-postinstall"
install -m 0644 "$_CH_SRC/unlock-home.service"    "$ROOTFS/etc/systemd/system/unlock-home.service"

# Configuration: __OWNER__ is the only per-image setting. CRYPTHOME_UUID stays
# empty; it is written on the machine once the disk exists.
sed "s/__OWNER__/$_CH_OWNER/" "$_CH_SRC/crypthome.default" > "$ROOTFS/etc/default/crypthome"
chmod 0644 "$ROOTFS/etc/default/crypthome"

# ── Service ────────────────────────────────────────────────────────────────
# Enabled in the image: without a configured UUID it does nothing, but it is
# ready when init-crypthome.sh only has to write the UUID.
chroot "$ROOTFS" systemctl enable unlock-home.service 2>/dev/null || \
    echo -e "  ${YELLOW}!${NC} unlock-home.service non active (systemctl indisponible dans le rootfs)"

# ── Root keyring exists only on the encrypted disk ─────────────────────────
# Symlink to the encrypted disk, created before the first root session makes a
# real directory there. Disk locked = dangling link = gnome-keyring cannot
# write anything in clear on the system disk.
install -d -m 0700 "$ROOTFS/root/.local/share"
rm -rf "$ROOTFS/root/.local/share/keyrings"
ln -sfn /home/.crypthome/root-keyrings "$ROOTFS/root/.local/share/keyrings"

# ── Audio for the owner account ────────────────────────────────────────────
# PulseAudio runs in system mode: the daemon belongs to `pulse` and only
# accepts members of pulse-access. The browser (dashboard microphone) runs as
# the owner; without these groups getUserMedia returns "NotFoundError".
chroot "$ROOTFS" bash -c "
    getent group pulse-access >/dev/null 2>&1 && usermod -aG pulse-access,audio,video $_CH_OWNER
" 2>/dev/null || echo -e "  ${YELLOW}!${NC} groupes audio non ajoutes a ${CYAN}$_CH_OWNER${NC}"

# ── Session ────────────────────────────────────────────────────────────────
# The autostart entry prepares the switch when the root session opens: X
# server authorisation and a user session for the owner account. Without it
# the first Firefox launch waits for logind for several seconds silently.
if [ -d "$ROOTFS/etc/gdm3" ] || [ "${ISO_DESKTOP:-0}" = "1" ]; then
    install -d "$ROOTFS/root/.config/autostart" "$ROOTFS/etc/skel/.config/autostart"
    install -m 0644 "$_CH_SRC/crypthome-session.desktop" \
        "$ROOTFS/root/.config/autostart/crypthome-session.desktop"
    install -m 0644 "$_CH_SRC/crypthome-session.desktop" \
        "$ROOTFS/etc/skel/.config/autostart/crypthome-session.desktop"

    # Launchers of applications holding secrets go through run-as-owner. Done in
    # the chroot since the list depends on what is actually installed.
    chroot "$ROOTFS" /usr/local/sbin/refresh-owner-apps 2>/dev/null | sed 's/^/  /' || \
        echo -e "  ${YELLOW}!${NC} lanceurs non rediriges (a refaire avec refresh-owner-apps)"
    echo -e "  ${GREEN}✓${NC} applications a secrets : sous ${CYAN}$_CH_OWNER${NC} quand /home est dechiffre, sous ${CYAN}root${NC} sinon"
fi

# ── Required in the rootfs ─────────────────────────────────────────────────
# cryptsetup to open the volume, rsync for init-crypthome.sh, x11-xserver-utils
# for xhost.
for _p in cryptsetup rsync xhost; do
    chroot "$ROOTFS" bash -c "command -v $_p >/dev/null 2>&1" || \
        echo -e "  ${YELLOW}!${NC} ${CYAN}$_p${NC} absent du rootfs - requis par le dispositif de chiffrement"
done

echo -e "  ${GREEN}✓${NC} outils poses : ${CYAN}unlock-home${NC}, ${CYAN}lock-home${NC}, ${CYAN}crypthome-postinstall${NC} (Calamares), ${CYAN}init-crypthome.sh${NC} (second disque)"
echo -e "  ${GREEN}✓${NC} a l installation : cocher ${CYAN}« chiffrer »${NC} chiffre ${CYAN}/home${NC} seul, la racine reste lisible"
echo -e "  ${GREEN}✓${NC} demarrage : ${CYAN}« decrypt /home -passphrase- or Enter »${NC} sur la console - le boot aboutit quelle que soit la reponse"

# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
