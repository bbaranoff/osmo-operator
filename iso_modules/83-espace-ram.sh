#!/bin/bash
# iso_modules/83-espace-ram.sh - fstab, tmp, journal, logrotate, tcpdump, purge, ssh, clavier
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Espace writable du live : /dev/shm + /tmp, en POURCENTAGE de la RAM ─────
# Le live boote en 'toram' → racine = overlay tmpfs (RAM). Les gros writers de la
# stack sont les cfiles I/Q dans /dev/shm (FFT/record, plusieurs centaines de Mo)
# et /tmp. systemd applique ces entrees au boot.
#
# POURQUOI PLUS 2 Go EN DUR
# Ces caps ne reservent rien, mais ils AUTORISENT : 2 + 2 Go, sur une machine
# ou le squashfs occupe deja ~2,5 Go de RAM et ou la racine elle-meme est un
# tmpfs, c'est plus que ce dont dispose une VM de 8 Go. Deux writers un peu
# gourmands suffisaient alors a saturer la memoire - et le symptome n'est pas
# "tmpfs plein" mais une machine exsangue : "No space left on device" sur la
# racine, puis un sshd qui n'arrive meme plus a envoyer sa banniere.
#
# En pourcentage, le plafond suit la taille de la machine : 20 % + 15 % laissent
# toujours les deux tiers de la RAM au squashfs, a la racine et aux processus.
# Une VM a 16 Go y gagne autant qu'une VM a 8 Go cesse de se noyer.
# Idempotent + anti-doublon : on purge d'abord toute entree tmpfs /tmp ou /dev/shm
# preexistante (y compris la variante 'nosuid,nodev' sans size=) et l'ancien
# commentaire de bloc, PUIS on (re)ecrit le bloc canonique size en pourcentage. Garantit
# exactement une entree /tmp et une entree /dev/shm dans le fstab du squashfs.
touch "$ROOTFS/etc/fstab"
sed -i -E \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]/d' \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/dev\/shm[[:space:]]/d' \
    -e '/^# osmo-operator live - espace writable/d' \
    "$ROOTFS/etc/fstab"
# /dev/shm : sizing via fstab (sans risque de doublon generateur).
cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
# osmo-operator live - espace writable (cfiles I/Q FFT)
tmpfs   /dev/shm   tmpfs   defaults,nosuid,nodev,size=20%   0 0
FSTAB
# --arm : la racine et la partition firmware sont de VRAIES partitions de la
# carte SD (92-rpi-image les nomme ainsi). Le live n en a pas : live-boot lui
# donne sa racine. Etiquettes, pas UUID : l image est fabriquee sans monter.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    # Les etiquettes d Armbian (armbi_root, RPICFG) : c est ce que son
    # armbian-resize-filesystem et sa doc attendent.
    sed -i -E -e '/^LABEL=armbi_root[[:space:]]/d' -e '/^LABEL=RPICFG[[:space:]]/d' "$ROOTFS/etc/fstab"
    cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
LABEL=armbi_root    /               ext4    defaults,noatime,commit=120,errors=remount-ro   0 1
LABEL=RPICFG        /boot/firmware  vfat    defaults                                        0 2
FSTAB
    install -d "$ROOTFS/boot/firmware"
fi
# /tmp : PAS dans fstab. Une entree fstab /tmp entre en collision avec l'unite
# systemd tmp.mount -> "systemd-fstab-generator: tmp.mount already exists,
# Duplicate entry in /etc/fstab" (generateur en exit 1) ; et l'ancien update.sh
# la reinjectait au boot, ce qui obligeait a la retirer apres coup. On gere /tmp
# en natif systemd via un drop-in size=15% : une seule source, zero doublon -
# et plus rien, au demarrage, qui reecrive fstab.
mkdir -p "$ROOTFS/etc/systemd/system/tmp.mount.d"
cat > "$ROOTFS/etc/systemd/system/tmp.mount.d/size.conf" <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=15%
EOF
chroot "$ROOTFS" systemctl enable tmp.mount 2>/dev/null || true

# ── Ce qui remplit la RAM : les ECRITURES DE LA PILE ────────────────────────
# En 'toram' la racine est un overlay tmpfs : TOUT ce qui s'ecrit a l'execution
# reste en RAM, rien n'atteint un disque. Le squashfs y est deja recopie, /tmp
# et /dev/shm en reservent 2 Go chacun - le reste, quelques Go, est tout ce dont
# dispose la racine.
#
# Trois writers non bornes suffisaient a la remplir, et le symptome n'apparait
# qu'apres des heures : "No space left on device" sur une machine qui n'a
# pourtant aucun disque plein.
#   1. le journal systemd, sans plafond ;
#   2. /var/log/osmocom/*.log - la pile journalise en 'filter all 1', et mobile
#      tourne avec une vingtaine de categories de debug ;
#   3. les captures pcap GSMTAP, ecrites en continu et sans limite de taille.
# On les borne ici, dans l'image : un cap pose au build vaut pour toutes les VM,
# alors qu'un nettoyage manuel est a refaire apres chaque boot.

# 1. Journal : volatile (il est de toute facon perdu au reboot d'un live) et
#    plafonne. Sans RuntimeMaxUse, journald s'autorise 10 % de la RAM.
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
# --arm : la racine est persistante, le journal aussi (Storage=persistent,
# plafonne) ; volatile jetterait les logs a chaque reboot d une carte SD.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=256M
RuntimeMaxUse=64M
EOF
else
cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
# osmo-operator live : la racine est en RAM, le journal ne doit pas la manger.
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeKeepFree=256M
EOF
fi

# 2. Logs Osmocom : rotation a la TAILLE, pas a la date - une pile bavarde
#    remplit en une heure ce qu'une rotation quotidienne ne verrait jamais.
#    copytruncate : les demons gardent leur descripteur ouvert ; sans lui la
#    rotation leur laisse un fichier supprime, et l'espace n'est pas rendu.
mkdir -p "$ROOTFS/etc/logrotate.d"
cat > "$ROOTFS/etc/logrotate.d/osmocom" <<'EOF'
/var/log/osmocom/*.log {
    size 32M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
# logrotate.timer ne passe qu'une fois par jour : trop tard pour un tmpfs.
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.service" <<'EOF'
[Unit]
Description=osmo-operator - rotation des journaux Osmocom (racine en RAM)
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/osmocom --state /run/osmo-logrotate.state
EOF
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.timer" <<'EOF'
[Unit]
Description=osmo-operator - rotation des journaux Osmocom toutes les 15 min
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
chroot "$ROOTFS" systemctl enable osmo-logrotate.timer 2>/dev/null || true

# 3. Captures pcap : purge de celles de plus d'une heure. La capture GSMTAP
#    tourne en continu ; elle sert a regarder ce qui vient de se passer, pas a
#    constituer un historique - qu'aucun live ne pourrait de toute facon garder.
mkdir -p "$ROOTFS/etc/tmpfiles.d"
cat > "$ROOTFS/etc/tmpfiles.d/osmo-captures.conf" <<'EOF'
# osmo-operator : les captures vivent en RAM, on ne les garde pas plus d'une heure.
d /run/user/0/osmo-nitb/captures 0755 root root 1h
EOF

# 3bis. Le ring, plutot qu'un fichier qui gonfle
# Purger toutes les heures ne protege de rien : entre deux passages, UNE
# capture continue peut a elle seule remplir la RAM - et sur un lien charge,
# c'est l'affaire de quelques minutes, pas d'une nuit. Un fichier unique en -w
# croit sans limite ; -C <Mo> -W <n> lui substitue un ANNEAU de n fichiers qui
# se recyclent : la capture ne s'arrete jamais, l'empreinte reste bornee.
#
# Par un wrapper plutot qu'en corrigeant les appelants : la capture GSMTAP est
# lancee depuis le dashboard web (autre depot, clone au build) et depuis des
# outils qui ne vivent pas dans ce depot-ci. Un wrapper vaut pour tous, y
# compris ceux qu'on ajoutera. /usr/local/bin precede /usr/bin dans le PATH :
# l'appel "tcpdump" passe par lui sans que rien n'ait a etre reecrit.
#
# Il ne force rien quand l'appelant a deja choisi (-C ou -W presents), et sans
# -w il n'y a rien a borner.
cat > "$ROOTFS/usr/local/bin/tcpdump" <<'TCPDUMPEOF'
#!/bin/sh
# tcpdump - wrapper osmo-operator : impose un anneau aux captures sur fichier.
#
# La racine du live est un tmpfs : une capture non bornee finit par remplir la
# RAM, et l'erreur ("No space left on device") tombe des heures plus tard, sur
# une machine qui n'a pourtant aucun disque plein.
#
# DEUX PIEGES, DEUX PARADES
#  -Z root : avec -C/-W, tcpdump cree les membres suivants de l'anneau APRES
#            avoir abandonne ses privileges (utilisateur "tcpdump"). Sans -Z il
#            echoue des le premier : "Permission denied" - et aucune capture.
#            Sans -C il ouvrait le fichier AVANT, d'ou un fonctionnement qui ne
#            cassait qu'en ajoutant l'anneau.
#  lien    : avec -C/-W, tcpdump n'ecrit pas le nom demande mais numerote les
#            membres (capture.pcap0, .pcap1...). Le nom exact n'existe jamais,
#            et l'appelant qui l'attend conclut a un echec. On maintient donc
#            <nom exact> -> membre courant : la barriere le suit, qui ouvre le
#            fichier lit la capture en cours, et rien n'a a etre reecrit.
#
# Reglable : OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump

has_w=0; has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Rien a borner, ou l'appelant a deja choisi son anneau : on s'efface.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Le veilleur du lien. Lance AVANT l'exec : apres, ce processus EST tcpdump.
# $$ reste le meme a travers l'exec, donc il suit exactement sa vie et s'arrete
# avec lui - aucun processus orphelin a nettoyer.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
TCPDUMPEOF
chmod +x "$ROOTFS/usr/local/bin/tcpdump"

# ── Purge complete a chaque relance ─────────────────────────────────────────
# Les caps ci-dessus empechent la derive PENDANT une session ; celui-ci repart
# d'une racine propre A CHAQUE DEMARRAGE. Sur un live c'est sans perte : ces
# fichiers ne survivraient pas au reboot de toute facon. Avec persistance, en
# revanche, ils s'accumuleraient d'un boot a l'autre jusqu'a remplir le medium -
# c'est precisement le cas ou la purge devient indispensable.
#
# Avant la pile (Before=osmo-*.service) : purger APRES le demarrage effacerait
# les journaux de la session en cours, et le premier incident serait invisible.
cat > "$ROOTFS/usr/local/sbin/osmo-purge.sh" <<'PURGEEOF'
#!/bin/bash
# osmo-purge.sh - repart d'une racine propre. Appele au boot par osmo-purge.service.
# Ne touche NI aux configs (/etc/osmocom), NI aux bases (HLR) : seulement ce qui
# se regenere - journaux, captures, fichiers de travail.
set -u

purge_dir() {   # $1=repertoire  $2=motif
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f -name "$2" -delete 2>/dev/null || true
}

# Journaux de la pile
purge_dir /var/log/osmocom '*.log'
purge_dir /var/log/osmocom '*.log.*'
purge_dir /var/log/osmocom '*.gz'

# Captures pcap (GSMTAP et autres)
rm -rf /run/user/0/osmo-nitb/captures/* 2>/dev/null || true
purge_dir /var/log/osmocom '*.pcap'
find /tmp /var/tmp -maxdepth 2 -type f -name '*.pcap*' -delete 2>/dev/null || true

# Fichiers de travail : I/Q FFT (plusieurs centaines de Mo piece)
find /dev/shm -maxdepth 1 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true
# Les MEMES fichiers HORS /dev/shm - ce sont eux qui ont rempli la RAM de la VM
# (4,6 Go mesures). Le mode pont ecrit /root/record.cfile et /root/record_ul.cfile
# en continu et empile /root/osmo-rec/*.cfile jusqu'a son propre plafond de 64 Go ;
# sur un live la racine EST un tmpfs, donc ce plafond n'en est pas un. Ne purger
# que /dev/shm laissait passer la totalite de ce qui se remplit vraiment.
find /root /tmp /var/tmp -maxdepth 2 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true

# Repertoire d'execution du live, recree par la pile au demarrage
rm -rf /run/user/0/osmo-nitb/logs/* 2>/dev/null || true

# Journal systemd volatile
command -v journalctl >/dev/null 2>&1 && journalctl --rotate --vacuum-time=1s >/dev/null 2>&1

exit 0
PURGEEOF
chmod +x "$ROOTFS/usr/local/sbin/osmo-purge.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-purge.service" <<'EOF'
[Unit]
Description=osmo-operator - purge des journaux, captures et fichiers de travail
DefaultDependencies=no
After=local-fs.target
Before=osmo-stp.service osmo-interstp.service osmo-msc.service osmo-bsc.service
Before=osmo-egprs-web.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-purge.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-purge.service 2>/dev/null || true

# SSH : autorise le login root par mot de passe + active le service au boot.
if [ -f "$ROOTFS/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
        "$ROOTFS/etc/ssh/sshd_config"
    grep -q '^PermitRootLogin yes' "$ROOTFS/etc/ssh/sshd_config" || \
        echo 'PermitRootLogin yes' >> "$ROOTFS/etc/ssh/sshd_config"
fi
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# ── Clavier : fige DANS l'image, plus demande au premier boot ───────────────
# Le choix se fait au debut de cette construction (voir "LES QUESTIONS"). Ici on
# ne fait que l'ecrire. L'ancienne version posait la question dans
# /etc/profile.d au premier login : chaque machine du banc s'arretait alors sur
# un menu, et une VM demarree sans console attendait une reponse que personne
# n'allait donner.
cat > "$ROOTFS/etc/default/keyboard" <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${OSMO_ISO_KB}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
chroot "$ROOTFS" setupcon --force 2>/dev/null || true
chroot "$ROOTFS" dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

# Ce qui reste au login : le rappel, qui n'attend rien.
# La commande DEPEND du role : le hub n'a pas de coeur GSM a demarrer, et
# start-direct.sh y chercherait un BSC, un MSC, une BTS qui n'existent pas.
# Lui dicter start-direct.sh, c'est envoyer droit dans une erreur.
if [ "$ISO_ROLE" = "interstp" ]; then
    OSMO_START_HINT='Pour demarrer le hub SS7 : /opt/GSM/osmo-operator/start-interstp.sh'
    OSMO_START_HINT2='  (etat des noeuds attaches : ./start-interstp.sh --status)'
else
    OSMO_START_HINT='Pour demarrer la stack : /opt/GSM/osmo-operator/start-direct.sh --node N'
    OSMO_START_HINT2='  (N de 1 a 9 : il fixe les point codes 1.<N>1.x du noeud)'
fi
cat > "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh" <<KBSCRIPT
#!/bin/bash
[ "\$(id -u)" -ne 0 ] && return 0
[ -n "\${OSMO_DISCLAIMER_SHOWN:-}" ] && return 0
export OSMO_DISCLAIMER_SHOWN=1
echo ""
echo -e "  \033[1;33mDisclaimer\033[0m - banc d'essai GSM/SS7 Osmocom."
echo -e "  A n'utiliser que sur un reseau radio \033[1mISOLE\033[0m (cage/attenuateur) ou"
echo -e "  sur une bande sous licence : emettre sur le spectre public est illegal."
echo -e "  Aucun service Osmocom n'est lance automatiquement sur cette ISO."
echo -e "  \033[1;33m${OSMO_START_HINT}\033[0m"
echo -e "  \033[0;36m${OSMO_START_HINT2}\033[0m"
echo -e "  clavier : \033[1;32m\$(awk -F\\" '/^XKBLAYOUT/{print \$2}' /etc/default/keyboard 2>/dev/null)\033[0m  \033[0;36m(changer : osmo-keyboard)\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh"
rm -f "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"

# Le choix du clavier reste offert - mais QUAND ON LE DEMANDE. C'est le meme
# menu qu'avant ; ce qui change, c'est qu'il ne s'interpose plus entre le login
# et le shell : une VM sans console ne peut plus rester bloquee dessus.
cat > "$ROOTFS/usr/local/bin/osmo-keyboard" <<'KBCMD'
#!/bin/bash
# osmo-keyboard - change la disposition clavier du systeme, a la demande.
[ "$(id -u)" -ne 0 ] && { echo "Root requis."; exit 1; }

if [ -n "$1" ]; then
    KB_LAYOUT="$1"
else
    echo ""
    echo -e "\033[1;36m== Configuration clavier ==\033[0m"
    echo "  1) fr    2) us    3) de    4) es    5) it"
    echo "  6) pt    7) gb    8) be    9) ch    0) autre"
    echo ""
    read -rp "  Choix [1] : " KB_CHOICE
    case "${KB_CHOICE:-1}" in
        1|"") KB_LAYOUT="fr" ;;
        2) KB_LAYOUT="us" ;;  3) KB_LAYOUT="de" ;;
        4) KB_LAYOUT="es" ;;  5) KB_LAYOUT="it" ;;
        6) KB_LAYOUT="pt" ;;  7) KB_LAYOUT="gb" ;;
        8) KB_LAYOUT="be" ;;  9) KB_LAYOUT="ch" ;;
        0) read -rp "  Layout (fr, us, ru, ar...) : " KB_LAYOUT
           KB_LAYOUT="${KB_LAYOUT:-us}" ;;
        *) KB_LAYOUT="fr" ;;
    esac
fi

loadkeys "$KB_LAYOUT" 2>/dev/null || true
cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true
echo -e "  \033[1;32mClavier : ${KB_LAYOUT}\033[0m   (sans persistance, revient au reboot)"
KBCMD
chmod +x "$ROOTFS/usr/local/bin/osmo-keyboard"
