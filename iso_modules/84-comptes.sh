#!/bin/bash
# iso_modules/84-comptes.sh - etape 8d : comptes, autologin console/bureau, linphone
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ══════════════════════════════════════════════════════════════════════════════
# Etape 8d : comptes, session, installeur - TOUT CE QUI PORTE DES APOSTROPHES
# ══════════════════════════════════════════════════════════════════════════════
# Ecrit ICI et pas dans le chroot de l etape 8 : ce chroot est un bash -c en
# QUOTES SIMPLES. Une apostrophe de plus et tout ce qui suit change de sens -
# et l erreur ne se voit qu au build suivant, sur une ligne sans rapport. Les
# configurations Calamares, les sudoers et les unites systemd en sont pleins.
# On ecrit donc dans "$ROOTFS" directement, avec le quoting normal du script.
echo -e "${GREEN}[8d/9] Comptes, session et installeur...${NC}"

# ── LE MODELE DE COMPTES ────────────────────────────────────────────────────
# root est le compte de TRAVAIL : le banc se pilote en root (start-direct.sh,
# les VTY, tcpdump, les netns), et tout le depot le suppose. La session s ouvre
# donc sur root, et les terminaux qu on y ouvre sont root sans rien demander.
#
# osmocom est un SECOND compte, non privilegie, sudoer - le bac a sable pour ce
# qui n a pas besoin des pleins pouvoirs : un navigateur, une session de bureau
# ordinaire. On y va EXPLICITEMENT (se deconnecter, le choisir dans GDM, ou
# "su - osmocom"), jamais par defaut.
#
# CE QUE CE N EST PLUS. Ce compte a longtemps ete un ALIAS D UID 0
# (usermod -o -u 0 osmocom) : un compte qui portait un nom d utilisateur
# ordinaire et les pleins pouvoirs, ce qui est le pire des deux mondes - on
# croit travailler sans privileges et on est root. C etait aussi la raison pour
# laquelle Chromium refusait de demarrer avec son bac a sable. Ici, osmocom est
# un vrai compte non privilegie, avec son propre UID.
chroot "$ROOTFS" bash -c "
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

# ── LA CONSOLE OUVRE SUR ROOT ───────────────────────────────────────────────
# Sur la cle live il n y a personne a authentifier : demander un mot de passe
# sur tty1 ne protege rien (qui tient le medium tient la machine) et empeche
# juste de travailler. --noclear garde a l ecran les messages du demarrage,
# qui sont souvent la seule trace d un module qui a echoue.
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
# Le Pi 4 : console=serial0 -> ttyS0 (mini-UART, enable_uart=1) ou ttyAMA0
# (PL011) selon l overlay ; les deux unites recoivent le meme drop-in.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    install -d "$ROOTFS/etc/systemd/system/serial-getty@ttyAMA0.service.d"
    cp "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin-root.conf" \
       "$ROOTFS/etc/systemd/system/serial-getty@ttyAMA0.service.d/10-autologin-root.conf"
fi
echo -e "  ${GREEN}✓${NC} tty1 et console serie : ouverture automatique sur ${CYAN}root${NC}"

# ── LE BUREAU AUSSI ─────────────────────────────────────────────────────────
# L etape 8 pose deja AutomaticLogin=root dans /etc/gdm3/custom.conf. On le
# reecrit ici sans condition : cette etape tourne meme quand ISO_DESKTOP vaut 0
# (le fichier est alors sans effet, GDM n est pas installe), et surtout elle
# garantit que le reglage est le meme des deux cotes - la cle live et le
# systeme installe, ou c est shellprocess-osmo.conf qui l ecrit.
if [ -d "$ROOTFS/etc/gdm3" ] || [ "${ISO_DESKTOP:-0}" = "1" ]; then
    install -d "$ROOTFS/etc/gdm3"
    cat > "$ROOTFS/etc/gdm3/custom.conf" <<'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 impose : sous VirtualBox/QEMU, la session Wayland de GNOME 42 tombe sur
# le pilote llvmpipe et rend un bureau inutilisable, quand elle demarre.
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

# ── LINPHONE : COMPTE PRE-PROVISIONNE ─────────────────────────────────
# Place ICI, et pas ailleurs : le compte doit exister AVANT le premier
# lancement du client. Linphone ne relit pas linphonerc a chaud - l instance
# qui tourne garde son etat en memoire et REECRIT le fichier en sortant. Un
# compte pose pendant que Linphone tourne n emet donc jamais de REGISTER, et
# le symptome est muet des DEUX cotes : cote client rien dans les journaux,
# cote Asterisk endpoint "Unavailable" sans le moindre 401 - puisque aucun
# paquet n arrive. Diagnostic du 2026-08-31, une capture de 90 s pour le voir.
# Le detail des deux pieges (relecture a chaud, publish de presence) est en
# tete de configs/linphonerc.
if [ "${ISO_DESKTOP:-0}" = "1" ] && [ -f "$DIR/configs/linphonerc" ]; then
    # Les DEUX comptes plus /etc/skel : la session s ouvre sur root (gdm3
    # ci-dessus), osmocom reste disponible apres deconnexion, et skel couvre
    # les comptes crees par l installeur sur le systeme cible.
    for _lh in "$ROOTFS/root" "$ROOTFS/home/osmocom" "$ROOTFS/etc/skel"; do
        install -d "$_lh/.config/linphone"
        cp -a "$DIR/configs/linphonerc" "$_lh/.config/linphone/linphonerc"
    done
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} linphone : compte ${CYAN}linphone_A${NC} pre-provisionne (poste ${CYAN}100${NC}, UDP vers 127.0.0.1:5060)"
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
