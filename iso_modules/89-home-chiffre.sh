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
# without decrypting anything. Once INSTALLED it is read-only: every session
# runs in RAM and is written back at shutdown only with the /home passphrase
# (osmo-racine-live, below).
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

# ── What the old model left (inherited rootfs) ────────────────────────────
# A rootfs inherited from a build before the simplification still carries the
# TPM porte, the second system and their units. osmo-racine-session.service in
# particular (Before=ssh.socket, After=network-online.target) puts dbus.service
# in an ordering cycle at every boot: systemd then drops sockets.target.
for _u in osmo-racine-session.service osmo-boite.target osmo-boite-consulter.service; do
    rm -f "$ROOTFS/etc/systemd/system/$_u" \
          "$ROOTFS/etc/systemd/system/multi-user.target.wants/$_u"
done
rm -f "$ROOTFS/usr/local/sbin/osmo-grub-esp" "$ROOTFS/usr/local/sbin/osmo-racine-copier" \
      "$ROOTFS/usr/local/sbin/osmo-porte" "$ROOTFS/usr/local/sbin/osmo-utilisateur" \
      "$ROOTFS/etc/apt/apt.conf.d/99osmo-grub-esp" "$ROOTFS/boot/osmo-porte.img" \
      "$ROOTFS/etc/xdg/autostart/osmo-porte-rappel.desktop" \
      "$ROOTFS/etc/initramfs-tools/hooks/osmo-racine-rw" \
      "$ROOTFS/etc/initramfs-tools/scripts/local-bottom/osmo-racine-rw" \
      "$ROOTFS/etc/initramfs-tools/conf.d/overlayroot"
rm -rf "$ROOTFS/etc/osmo-porte"
# the kexec preseed of the porte (LOAD_KEXEC=false): kexec-tools is gone too
[ -f "$ROOTFS/etc/default/kexec" ] && ! chroot "$ROOTFS" dpkg -s kexec-tools >/dev/null 2>&1 \
    && rm -f "$ROOTFS/etc/default/kexec"

# ── Tools ──────────────────────────────────────────────────────────────────
# unlock-home / lock-home in sbin (they mount/unmount), run-as-owner and
# crypthome-session-setup in bin (called from the session).
install -d "$ROOTFS/usr/local/sbin" "$ROOTFS/usr/local/bin" "$ROOTFS/root" \
           "$ROOTFS/etc/systemd/system" "$ROOTFS/etc/default" "$ROOTFS/usr/local/share/applications"
install -m 0755 "$_CH_SRC/unlock-home"            "$ROOTFS/usr/local/sbin/unlock-home"
install -m 0755 "$_CH_SRC/lock-home"              "$ROOTFS/usr/local/sbin/lock-home"
# THE INSTALLED DISK (partition.conf): EFI, / in clear and READ-ONLY (every
# write of a session in RAM, overlayroot), the black box partition, /home in
# LUKS2. At shutdown the /home passphrase writes the whole session (/, /root,
# /opt/GSM, /home) to the disk atomically; without it everything is wiped and
# a red warning stays on the console. Enabled by Calamares
# (shellprocess-osmo.conf: osmo-racine-live poser); the live key is not touched.
install -m 0755 "$_CH_SRC/osmo-racine-live"       "$ROOTFS/usr/local/sbin/osmo-racine-live"
install -m 0755 "$_CH_SRC/osmo-valider-appliquer" "$ROOTFS/usr/local/sbin/osmo-valider-appliquer"
# the disk against its fingerprint: total SHA-256 of / and of /home on the
# black box after every commit, compared at every boot BEFORE the /home
# passphrase is asked - a red warning when the disk was written to outside a
# session (enabled with the rest by osmo-racine-live poser)
install -m 0755 "$_CH_SRC/osmo-empreinte"         "$ROOTFS/usr/local/sbin/osmo-empreinte"
install -m 0644 "$DIR/services/osmo-empreinte.service" "$ROOTFS/etc/systemd/system/osmo-empreinte.service"
install -m 0644 "$DIR/services/osmo-empreinte-fond.service" "$ROOTFS/etc/systemd/system/osmo-empreinte-fond.service"
cat > "$ROOTFS/etc/xdg/autostart/osmo-empreinte-rappel.desktop" <<'RAPPEL'
[Desktop Entry]
Type=Application
Name=osmo-operator : disque modifie hors session
Exec=/usr/local/sbin/osmo-empreinte rappel
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
RAPPEL
# MEASURED BOOT, AN OPTION (sudo osmo-tpm poser): a TOTP code computed by the
# TPM only when firmware, GRUB, kernel, initramfs and the system disk are the
# sealed ones, shown next to the /home question. One kernel, no kexec.
# osmo-total is the one text that computes a volume's total (system and
# initramfs); osmo-qr draws the enrolment QR code without any library.
install -m 0755 "$_CH_SRC/osmo-tpm"               "$ROOTFS/usr/local/sbin/osmo-tpm"
install -m 0755 "$_CH_SRC/osmo-total"             "$ROOTFS/usr/local/sbin/osmo-total"
install -m 0755 "$_CH_SRC/osmo-qr"                "$ROOTFS/usr/local/sbin/osmo-qr"
chroot "$ROOTFS" bash -c 'command -v tpm2_unseal >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tpm2-tools >/dev/null 2>&1' \
    || echo -e "  ${YELLOW}!${NC} tpm2-tools non installe : l option « demarrage mesure » demandera de l installer"
# the measured boot ticked in the installer (Options page): it is posed after
# the first boot (a phone has to be enrolled) - a reminder at login until then
cat > "$ROOTFS/etc/xdg/autostart/osmo-tpm-rappel.desktop" <<'RAPPEL'
[Desktop Entry]
Type=Application
Name=osmo-operator : demarrage mesure a poser
Exec=sh -c 'grep -qs "^tpm=1" /etc/osmo-operator/options && [ ! -e /etc/osmo-tpm/actif ] && notify-send -u critical "Demarrage mesure (TPM) a poser" "Coche a l installation. Dans un terminal : sudo osmo-tpm poser (un telephone avec une appli TOTP sous la main)"'
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
RAPPEL
# the REC screen of a write at shutdown: cmatrix, and its red progress bar
install -m 0755 "$_CH_SRC/osmo-rec"               "$ROOTFS/usr/local/sbin/osmo-rec"
install -m 0755 "$_CH_SRC/osmo-valider-session"   "$ROOTFS/usr/local/bin/osmo-valider-session"
# the « Tout oublier ? » pseudo-neuralyzer (Yes: flash, wiped; No: passphrase).
# A flash.gif dropped in /usr/local/share/osmo-operator replaces the drawing.
install -m 0755 "$_CH_SRC/osmo-flash"             "$ROOTFS/usr/local/bin/osmo-flash"
install -d "$ROOTFS/usr/local/share/osmo-operator"
install -m 0644 "$DIR/services/osmo-fin-session.service" "$ROOTFS/etc/systemd/system/osmo-fin-session.service"
# the kept copy of the mounts of /home: its layers found gone at shutdown
# (enabled with the rest by osmo-racine-live poser)
install -m 0644 "$DIR/services/osmo-garde.service" "$ROOTFS/etc/systemd/system/osmo-garde.service"
# The black box: every change of every session, validated or wiped, one
# record encrypted with age (public key on the box, private key under the
# box's own passphrase, different from /home's). A login reminder until it
# has that passphrase.
install -m 0755 "$_CH_SRC/osmo-diffs"             "$ROOTFS/usr/local/sbin/osmo-diffs"
# the receiving end of the box's remote copy: any osmo machine can keep the
# copies of another (forced command, add-only)
install -m 0755 "$_CH_SRC/osmo-diffs-recevoir"    "$ROOTFS/usr/local/bin/osmo-diffs-recevoir"
install -m 0644 "$DIR/services/osmo-diffs.service" "$ROOTFS/etc/systemd/system/osmo-diffs.service"
# keys and passphrase of the box: at the first boot of the INSTALLED system
# (enabled by Calamares, shellprocess-osmo.conf), never on the live key
install -m 0644 "$DIR/services/osmo-diffs-init.service" "$ROOTFS/etc/systemd/system/osmo-diffs-init.service"
install -d "$ROOTFS/etc/xdg/autostart" "$ROOTFS/etc/profile.d"
cat > "$ROOTFS/etc/xdg/autostart/osmo-diffs-rappel.desktop" <<'RAPPEL'
[Desktop Entry]
Type=Application
Name=osmo-diffs : phrase de la boite noire
Exec=sh -c '! mountpoint -q /var/lib/osmo-diffs || [ -f /var/lib/osmo-diffs/cle.pub ] || notify-send -u critical "Boite noire non initialisee" "Sa phrase est demandee au demarrage (ou : sudo osmo-diffs init), DIFFERENTE de celle de /home"'
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
RAPPEL
# the red warning « session NON validee »: BEFORE A REBOOT OR A SHUTDOWN, not
# at login. osmo-fin-veille stays in the desktop session and makes logind wait
# (delay inhibitor, 300 s at most) while the warning is shown.
install -m 0755 "$_CH_SRC/osmo-fin-veille"        "$ROOTFS/usr/local/bin/osmo-fin-veille"
install -d "$ROOTFS/etc/systemd/logind.conf.d"
cat > "$ROOTFS/etc/systemd/logind.conf.d/osmo-fin.conf" <<'LOGIND'
# osmo-operator: the time logind waits for the « session NON validee » warning
# (and the /home passphrase) before a reboot or a shutdown - osmo-fin-veille
[Login]
InhibitDelayMaxSec=300
LOGIND
cat > "$ROOTFS/etc/xdg/autostart/osmo-valider-rappel.desktop" <<'RAPPEL'
[Desktop Entry]
Type=Application
Name=osmo-operator : session non validee (avant l extinction)
Exec=/usr/local/bin/osmo-fin-veille
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
RAPPEL
# the launcher: validate NOW. The /home passphrase given during the session
# writes the session as it is at that moment; what follows is kept only by a
# new validation, or by the passphrase at shutdown (which writes it all).
cat > "$ROOTFS/usr/local/share/applications/osmo-valider-session.desktop" <<'LANCEUR'
[Desktop Entry]
Type=Application
Name=Valider la session (maintenant)
Comment=Phrase de /home : la session telle qu elle est a cet instant est ecrite sur le disque ; ce qui suit ne l est pas
Exec=/usr/local/bin/osmo-valider-session
Icon=document-save
Terminal=false
Categories=System;
LANCEUR
# the former second launcher (« ecrire maintenant ») was the same gesture
rm -f "$ROOTFS/usr/local/share/applications/osmo-ecrire-session.desktop"
cat > "$ROOTFS/usr/local/share/applications/osmo-defaire-session.desktop" <<'LANCEUR'
[Desktop Entry]
Type=Application
Name=Defaire la derniere ecriture
Comment=Phrase de /home : la derniere ecriture sur le disque est defaite (puis la precedente...). La boite noire garde tout.
Exec=/usr/local/bin/osmo-valider-session --defaire
Icon=edit-undo
Terminal=false
Categories=System;
LANCEUR
cat > "$ROOTFS/usr/local/share/applications/osmo-fin-session.desktop" <<'LANCEUR'
[Desktop Entry]
Type=Application
Name=Fin de session
Comment=Tout oublier ? Yes : flash, la session est effacee. No : la phrase de /home, la session est gardee. Puis extinction.
Exec=/usr/local/bin/osmo-valider-session --fin poweroff
Icon=system-shutdown
Terminal=false
Categories=System;
LANCEUR
# and in every terminal, in red
cat > "$ROOTFS/etc/profile.d/98-osmo-session.sh" <<'PROFIL'
# osmo-operator: the disk was written to outside a session (osmo-empreinte)
if [ -t 1 ] && [ -s /run/osmo-alerte ]; then
    printf '\033[5;1;31m%s\033[0m\n' "!!! DISQUE MODIFIE HORS SESSION : $(head -n1 /run/osmo-alerte) - voir /run/osmo-alerte !!!"
fi
if [ -t 1 ] && [ -s /run/osmo-alerte-copie ]; then
    printf '\033[1;31m%s\033[0m\n' "!!! BOITE NOIRE NON COPIEE AILLEURS : $(cat /run/osmo-alerte-copie) (sudo osmo-diffs envoyer) !!!"
fi
# osmo-operator: / in RAM -> red warning. A validation covers the moment it
# was given; what follows needs another one, or the passphrase at shutdown.
if [ -t 1 ] && [ ! -e /run/osmo-racine/valide ] && mountpoint -q /media/root-ro 2>/dev/null; then
    if [ -e /run/osmo-racine/ecrit ]; then
        printf '\033[1;31m%s\033[0m\n' "ATTENTION : session validee a $(date -r /run/osmo-racine/ecrit '+%H:%M') - ce qui a suivi sera EFFACE a l extinction sans la phrase de /home." \
            "  osmo-valider-session : valider de nouveau, maintenant"
    else
        printf '\033[1;31m%s\033[0m\n' "ATTENTION : session non validee - sans la phrase de /home, tout est EFFACE a l extinction." \
            "  osmo-valider-session : ecrit la session telle qu elle est maintenant (pas ce qui suit)"
    fi
fi
PROFIL
chmod 0644 "$ROOTFS/etc/profile.d/98-osmo-session.sh"
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
for _p in cryptsetup rsync xhost overlayroot-chroot age getfattr zenity; do
    chroot "$ROOTFS" bash -c "command -v $_p >/dev/null 2>&1" || \
        echo -e "  ${YELLOW}!${NC} ${CYAN}$_p${NC} absent du rootfs - requis par le dispositif de chiffrement"
done

echo -e "  ${GREEN}✓${NC} outils poses : ${CYAN}unlock-home${NC}, ${CYAN}lock-home${NC}, ${CYAN}crypthome-postinstall${NC} (Calamares), ${CYAN}init-crypthome.sh${NC} (second disque)"
echo -e "  ${GREEN}✓${NC} a l installation : cocher ${CYAN}« chiffrer »${NC} chiffre ${CYAN}/home${NC} seul, la racine reste lisible"
echo -e "  ${GREEN}✓${NC} demarrage : ${CYAN}« decrypt /home -passphrase- or Enter »${NC} sur la console - le boot aboutit quelle que soit la reponse"
echo -e "  ${GREEN}✓${NC} installe : ${CYAN}/${NC} en lecture seule (RAM) ; a l extinction la phrase de ${CYAN}/home${NC} ecrit la session, sinon ${RED}tout est efface${NC}"

# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
