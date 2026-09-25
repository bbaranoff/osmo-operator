#!/bin/bash
# iso_modules/89-home-chiffre.sh - etape 8i : second disque chiffre sur /home
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ══════════════════════════════════════════════════════════════════════════════
# Etape 8i : le disque systeme reste lisible, les secrets vont sur le second
# ══════════════════════════════════════════════════════════════════════════════
# LE MODELE, en une phrase : tout ce qui est systeme est lisible, tout ce qui
# tient au trousseau est chiffre.
#
# Le disque systeme n est PAS chiffre, et c est voulu : le banc se pilote en
# root (VTY, netns, tcpdump), la session s ouvre sur root (etape 8d), et un
# operateur doit pouvoir sortir une trace, relire un journal ou reparer la
# machine depuis une cle live sans avoir a dechiffrer quoi que ce soit.
#
# Ce qui n a rien a faire en clair, ce sont les SECRETS : trousseau GNOME,
# cookies et jetons du navigateur, profils. Ceux-la vivent sur un SECOND
# disque, chiffre en LUKS2 et monte sur /home. Le compte osmocom - celui que
# l etape 8d cree non privilegie - y a son home, et les applications a secrets
# tournent SOUS LUI depuis la session de root (run-as-owner).
#
# AU DEMARRAGE la machine demande "Dechiffrer /home ? [o/N]". Repondre non,
# se tromper de phrase de passe ou ne rien repondre ne bloque JAMAIS le boot :
# la session root s ouvre, /home reste vide, et les memes applications
# demarrent sans secrets. C est ce qui rend le dispositif utilisable sur un
# banc qu on redemarre dix fois par jour.
#
# OU SE FAIT LE CHIFFREMENT, DESORMAIS : DANS CALAMARES.
# [2026-09-25] Le chiffrement n est plus une operation d apres-coup lancee
# depuis une session de bureau. Il se fait A L INSTALLATION :
#   - installer/calamares/modules/partition.conf decoupe le disque en DEUX,
#     racine + /home, et marque la racine "noEncrypt". Cocher « chiffrer le
#     systeme » ne chiffre donc que /home, en LUKS2 ;
#   - crypthome-postinstall, lance par shellprocess@osmo dans la cible,
#     raccorde ce que l installeur a produit : crypttab et fstab en "noauto",
#     /etc/default/crypthome rempli (UUID, mapping, ET le compte de session
#     comme proprietaire), trousseau de root pose sur le volume.
#
# POURQUOI PAS DANS LA SESSION. init-crypthome.sh recopie /home pendant que la
# session qui l a lance tient ce meme /home : la copie est prise a chaud,
# l ancien contenu doit etre evacue au redemarrage suivant, et le basculement
# s etale sur deux demarrages. A l installation, le disque est vierge et
# personne ne tient rien - il n y a ni copie, ni evacuation, ni deuxieme temps.
#
# CE MODULE, LUI, NE CHIFFRE TOUJOURS RIEN. Il pose les outils dans le rootfs,
# pour la cle live et pour la cible. Sur la cle live, et sur une machine
# installee sans avoir coche la case, CRYPTHOME_UUID reste vide : unlock-home
# constate qu il n y a rien a faire et sort.
#
# init-crypthome.sh RESTE, pour le cas qu il a toujours servi et que Calamares
# ne couvre pas : chiffrer un SECOND disque ajoute apres coup a une machine
# deja installee.
# ── "CE WRAPPER AVAIT ETE RETIRE" : NON, PAS CELUI-LA ───────────────────────
# L etape 8f (86-finitions.sh) raconte la suppression de ~180 lignes de
# plomberie qui relancaient CHROMIUM sous osmocom par runuser et xhost. Elle a
# eu lieu, elle etait justifiee, et il ne faut pas defaire ce module en croyant
# que c est la meme chose qui revient.
#
# Ce n est pas la meme chose. Ce wrapper-la existait pour UNE raison technique
# - "Running as root without --no-sandbox is not supported" - et Firefox, qui
# a remplace Chromium, n a pas cette contrainte : il demarre en root sans
# intermediaire. La raison avait donc disparu, et le code avec elle.
#
# run-as-owner repond a une question qui n a rien a voir : OU S ECRIVENT LES
# SECRETS. Firefox demarre tres bien en root - et ecrit alors ses cookies, ses
# jetons et son trousseau sur le disque systeme EN CLAIR. C est precisement ce
# qu on ne veut pas. Le compte n est pas un contournement de bac a sable, c est
# l endroit ou vivent les secrets : son home est sur le disque chiffre.
#
# Le pattern lui-meme n a d ailleurs jamais quitte le depot : le wrapper vlc de
# l etape 8e (85-installeur-bureau.sh) fait exactement cela - xhost, runuser,
# PULSE_SERVER, XDG_RUNTIME_DIR. run-as-owner le generalise, pour toutes les
# applications a secrets au lieu d une seule, et sur condition : le disque doit
# etre dechiffre, sinon l application demarre en root comme avant.
_CH_SRC="$DIR/configs/crypthome"
if [ ! -d "$_CH_SRC" ]; then
    echo -e "  ${YELLOW}!${NC} configs/crypthome absent - etape 8i sautee"
    return 0
fi

echo -e "${GREEN}[8i/9] Second disque chiffre sur /home (outils, rien n est chiffre ici)...${NC}"

# Le compte qui portera le home chiffre. C est osmocom, le compte non
# privilegie de l etape 8d - surchargeable pour une image qui en nommerait un
# autre.
_CH_OWNER="${OSMO_ISO_CRYPTHOME_OWNER:-osmocom}"

# ── LES OUTILS ──────────────────────────────────────────────────────────────
# unlock-home / lock-home en sbin (ils montent et demontent), run-as-owner et
# crypthome-session-setup en bin (ils sont appeles depuis la session).
install -d "$ROOTFS/usr/local/sbin" "$ROOTFS/usr/local/bin" "$ROOTFS/root" \
           "$ROOTFS/etc/systemd/system" "$ROOTFS/etc/default" "$ROOTFS/usr/local/share/applications"
install -m 0755 "$_CH_SRC/unlock-home"            "$ROOTFS/usr/local/sbin/unlock-home"
install -m 0755 "$_CH_SRC/lock-home"              "$ROOTFS/usr/local/sbin/lock-home"
install -m 0755 "$_CH_SRC/refresh-owner-apps"     "$ROOTFS/usr/local/sbin/refresh-owner-apps"
install -m 0755 "$_CH_SRC/run-as-owner"           "$ROOTFS/usr/local/bin/run-as-owner"
install -m 0755 "$_CH_SRC/crypthome-session-setup" "$ROOTFS/usr/local/bin/crypthome-session-setup"
install -m 0700 "$_CH_SRC/init-crypthome.sh"      "$ROOTFS/root/init-crypthome.sh"
# Lance par Calamares dans la cible (shellprocess@osmo) : il raccorde le /home
# que l installeur vient de chiffrer. En sbin parce qu il touche crypttab,
# fstab et /etc/default/crypthome.
install -m 0755 "$_CH_SRC/crypthome-postinstall"  "$ROOTFS/usr/local/sbin/crypthome-postinstall"
install -m 0644 "$_CH_SRC/unlock-home.service"    "$ROOTFS/etc/systemd/system/unlock-home.service"

# La configuration : __OWNER__ est le seul reglage qui change d une image a
# l autre. CRYPTHOME_UUID reste VIDE - il est ecrit par init-crypthome.sh, sur
# la machine, quand le disque existe vraiment.
sed "s/__OWNER__/$_CH_OWNER/" "$_CH_SRC/crypthome.default" > "$ROOTFS/etc/default/crypthome"
chmod 0644 "$ROOTFS/etc/default/crypthome"

# ── LE SERVICE ──────────────────────────────────────────────────────────────
# Active des l image : sans UUID configure il ne fait rien, mais il est en
# place le jour ou l operateur lance init-crypthome.sh - qui n a alors plus
# qu a ecrire l UUID. Un service a activer apres coup est un service qu on
# oublie d activer.
chroot "$ROOTFS" systemctl enable unlock-home.service 2>/dev/null || \
    echo -e "  ${YELLOW}!${NC} unlock-home.service non active (systemctl indisponible dans le rootfs)"

# ── LE TROUSSEAU DE ROOT N EXISTE QU EN CHIFFRE ─────────────────────────────
# Lien vers le disque chiffre, pose MAINTENANT - avant que la premiere session
# de root ne cree un vrai repertoire a cet endroit. Disque non dechiffre =
# lien mort = gnome-keyring ne peut RIEN ecrire en clair sur le disque
# systeme. Un trousseau absent vaut mieux qu un trousseau lisible : c est
# exactement le compromis qu on veut ici.
install -d -m 0700 "$ROOTFS/root/.local/share"
rm -rf "$ROOTFS/root/.local/share/keyrings"
ln -sfn /home/.crypthome/root-keyrings "$ROOTFS/root/.local/share/keyrings"

# ── LE SON DU COMPTE PROPRIETAIRE ───────────────────────────────────────────
# PulseAudio tourne en mode SYSTEME sur ce banc : le demon appartient au compte
# `pulse` et n accepte que les membres de pulse-access. Le navigateur porte le
# micro du tableau de bord (voir l etape 8f) et il tourne desormais sous le
# compte proprietaire : sans ces groupes, getUserMedia rend « NotFoundError »
# pendant que pactl liste les peripheriques en RUNNING - et on cherche des
# heures du cote « permission micro » ou « pilote son ».
chroot "$ROOTFS" bash -c "
    getent group pulse-access >/dev/null 2>&1 && usermod -aG pulse-access,audio,video $_CH_OWNER
" 2>/dev/null || echo -e "  ${YELLOW}!${NC} groupes audio non ajoutes a ${CYAN}$_CH_OWNER${NC}"

# ── LA SESSION ──────────────────────────────────────────────────────────────
# L autostart prepare la bascule des l ouverture de la session root :
# autorisation sur le serveur X et session utilisateur du compte proprietaire.
# Sans lui, le premier lancement de Firefox attend logind plusieurs secondes
# sans rien afficher, et on croit que le clic n a pas pris.
if [ -d "$ROOTFS/etc/gdm3" ] || [ "${ISO_DESKTOP:-0}" = "1" ]; then
    install -d "$ROOTFS/root/.config/autostart" "$ROOTFS/etc/skel/.config/autostart"
    install -m 0644 "$_CH_SRC/crypthome-session.desktop" \
        "$ROOTFS/root/.config/autostart/crypthome-session.desktop"
    install -m 0644 "$_CH_SRC/crypthome-session.desktop" \
        "$ROOTFS/etc/skel/.config/autostart/crypthome-session.desktop"

    # Les lanceurs des applications a secrets passent par run-as-owner. Dans
    # le chroot, et pas ici : la liste depend de ce qui est REELLEMENT
    # installe dans le rootfs, et seul le chroot le sait.
    chroot "$ROOTFS" /usr/local/sbin/refresh-owner-apps 2>/dev/null | sed 's/^/  /' || \
        echo -e "  ${YELLOW}!${NC} lanceurs non rediriges (a refaire avec refresh-owner-apps)"
    echo -e "  ${GREEN}✓${NC} applications a secrets : sous ${CYAN}$_CH_OWNER${NC} quand /home est dechiffre, sous ${CYAN}root${NC} sinon"
fi

# ── CE QU IL FAUT DANS LE ROOTFS ────────────────────────────────────────────
# cryptsetup pour ouvrir le volume, rsync pour la recopie du home par
# init-crypthome.sh, x11-xserver-utils pour xhost. Absents, tout le dispositif
# echoue au pire moment : au premier demarrage apres chiffrement.
for _p in cryptsetup rsync xhost; do
    chroot "$ROOTFS" bash -c "command -v $_p >/dev/null 2>&1" || \
        echo -e "  ${YELLOW}!${NC} ${CYAN}$_p${NC} absent du rootfs - requis par le dispositif de chiffrement"
done

echo -e "  ${GREEN}✓${NC} outils poses : ${CYAN}unlock-home${NC}, ${CYAN}lock-home${NC}, ${CYAN}crypthome-postinstall${NC} (Calamares), ${CYAN}init-crypthome.sh${NC} (second disque)"
echo -e "  ${GREEN}✓${NC} a l installation : cocher ${CYAN}« chiffrer »${NC} chiffre ${CYAN}/home${NC} seul, la racine reste lisible"
echo -e "  ${GREEN}✓${NC} demarrage : ${CYAN}« Dechiffrer /home ? [o/N] »${NC} - le boot aboutit quelle que soit la reponse"

# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
