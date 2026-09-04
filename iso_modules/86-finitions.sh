#!/bin/bash
# iso_modules/86-finitions.sh - live-boot toram, sssd, firefox, micro, bannieres, demontage
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── L ERREUR DE SYNTAXE DE LA COPIE EN RAM ──────────────────────────────────
# L entree "en RAM" du menu passe "toram=filesystem.squashfs" : live-boot ne
# recopie alors QUE le squashfs, pas le medium entier. Le calcul de la taille du
# tmpfs est celui-ci, dans lib/live/boot/9990-toram-todisk.sh :
#
#     size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
#
# C est le SEUL expr de tout ce chemin, donc la seule chose qui puisse repondre
# "expr: syntax error" pendant la copie. Il suffit que le ls de l initramfs
# (busybox, pas coreutils) ne rende pas la taille en 5e champ - ou ne rende
# rien - pour qu expr recoive "expr / 1024 + 5000" et le dise.
#
# L erreur ne BLOQUE pas : size reste vide, le tmpfs est monte sans -o size et
# prend son defaut (la moitie de la RAM), ce qui suffit le plus souvent. D ou un
# banc qui demarre quand meme, avec un message rouge au passage - le genre de
# message qu on finit par ignorer, et qui masque le jour ou il compte.
#
# On remplace expr par l arithmetique du shell, avec le champ VALIDE avant
# usage et un repli explicite. "ls -lan" plutot que "ls -la" : le -n evite la
# resolution des noms d utilisateur, qui dans un initramfs sans /etc/passwd
# complet peut elargir la colonne et decaler les champs - c est le candidat le
# plus credible. Le patch precede update-initramfs, sinon il ne part pas dans
# l image ; d ou la regeneration explicite juste apres.
_LB_TORAM="$ROOTFS/lib/live/boot/9990-toram-todisk.sh"
if [ -f "$_LB_TORAM" ] && grep -q 'expr \$(ls -la \${MODULETORAMFILE}' "$_LB_TORAM"; then
    python3 - "$_LB_TORAM" <<'PYLB'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "\t\t\tsize=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )\n"
new = ("\t\t\t_lbsz=$(ls -lan \"${MODULETORAMFILE}\" 2>/dev/null | awk '{print $5}')\n"
       "\t\t\tcase \"${_lbsz}\" in ''|*[!0-9]*) _lbsz=0 ;; esac\n"
       "\t\t\tsize=$(( _lbsz / 1024 + 5000 ))\n")
sys.exit(0 if (open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1)) and old in s) else 0)
PYLB
    if grep -q '_lbsz' "$_LB_TORAM"; then
        _LB_K=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed "s|.*/vmlinuz-||")
        if [ -n "$_LB_K" ]; then
            chroot "$ROOTFS" update-initramfs -u -k "$_LB_K" >/dev/null 2>&1 \
                || echo -e "  ${YELLOW}!${NC} update-initramfs a echoue apres la retouche live-boot"
        fi
        echo -e "  ${GREEN}✓${NC} live-boot : calcul de taille ${CYAN}toram${NC} fiabilise (plus d appel a expr)"
    else
        echo -e "  ${YELLOW}!${NC} live-boot : la ligne attendue n a pas ete trouvee - non modifie"
    fi
else
    echo -e "  ${GREEN}·${NC} live-boot : rien a corriger (absent, ou deja corrige)"
fi

# ── sssd : le service qui echoue au demarrage pour rien ─────────────────────
# ubuntu-desktop-minimal tire sssd (par gnome-online-accounts / realmd). Sur une
# machine qui n est dans AUCUN domaine - ce qui est le cas d un banc - sssd n a
# pas de fournisseur configure : il sort en erreur a chaque demarrage,
#     sssd.service: Failed with result exit-code
# et systemd le compte comme un service en echec. Rien ne casse : aucune session
# ne depend de lui ici. Mais "systemctl --failed" en garde la trace, et sur une
# machine ou l on diagnostique justement des pannes, un service rouge en
# permanence est un bruit qui coute cher - on finit par ne plus regarder la
# liste, et c est la qu on rate le vrai.
#
# On MASQUE plutot que de desinstaller : purger sssd emporterait des paquets du
# bureau par dependance inverse. Reversible en une commande, et la commande est
# ecrite ci-dessous pour qui voudrait joindre un domaine.
#     systemctl unmask sssd && systemctl enable --now sssd
for _s in sssd sssd-autofs sssd-nss sssd-pac sssd-pam sssd-ssh sssd-sudo; do
    chroot "$ROOTFS" systemctl mask "$_s" >/dev/null 2>&1 || true
done
echo -e "  ${GREEN}✓${NC} sssd masque (aucun domaine sur un banc) - ${CYAN}systemctl unmask sssd${NC} pour le rendre"

# ── FIREFOX : LE NAVIGATEUR DU BANC, ET RIEN D AUTRE ────────────────────────
# [2026-08-31] Ici vivaient ~180 lignes de plomberie CHROMIUM : un lanceur
# /usr/local/bin/chromium qui rebasculait root -> osmocom par runuser (xhost,
# XDG_RUNTIME_DIR, profil dans /var/lib/osmo-chromium) pour rendre son bac a
# sable utilisable, une unite qui preparait ce runtime, une seconde qui
# effacait ses .desktop en double, et un alias de profil.
#
# TOUT CELA REPONDAIT A UNE SEULE CONTRAINTE DE CHROMIUM :
#     Running as root without --no-sandbox is not supported
# Cette image ouvre sa session en root ; Chromium exigeait donc soit un
# changement de compte, soit un navigateur SANS confinement lance par le compte
# le plus privilegie de la machine. Firefox n a pas cette contrainte : il
# demarre en root sans lanceur intermediaire - donc sans xhost, sans runuser,
# sans second profil, et sans les trois unites qui les tenaient.
#
# La derniere raison de preferer Chromium etait "Firefox ne capte pas le micro".
# Elle est tombee : le navigateur ne pouvait pas se connecter a PulseAudio, ce
# qui n avait rien d une affaire de navigateur. Voir osmo-pulse-link.sh.
#
# On efface donc ce que les images precedentes ont pu poser : une ISO
# reconstruite par-dessus un rootfs de cache garderait sinon un lanceur
# "chromium" qui ne mene nulle part, et des unites qui echouent au boot.
rm -f "$ROOTFS/usr/local/bin/chromium" \
      "$ROOTFS/usr/local/bin/chromium-browser" \
      "$ROOTFS/etc/profile.d/98-osmo-chromium.sh" \
      "$ROOTFS/usr/share/applications/chromium.desktop" \
      "$ROOTFS/usr/share/applications/chromium-browser.desktop" \
      "$ROOTFS/var/lib/snapd/desktop/applications/chromium_chromium.desktop" 2>/dev/null || true
for _u in osmo-chromium-runtime osmo-chromium-desktop; do
    chroot "$ROOTFS" systemctl disable "$_u" >/dev/null 2>&1 || true
    rm -f "$ROOTFS/etc/systemd/system/$_u.service" \
          "$ROOTFS/etc/systemd/system/multi-user.target.wants/$_u.service"
done
rm -rf "$ROOTFS/var/lib/osmo-chromium" 2>/dev/null || true

# ── LE MICRO DU DASHBOARD : CE QUE FIREFOX EXIGE, ET QU IL NE DEVINE PAS ────
# Trois conditions doivent etre reunies pour que le bouton micro de
# osmo-egprs-web fonctionne. Deux sont ailleurs, la troisieme est ici.
#
#   1. UN SERVEUR AUDIO JOIGNABLE. osmo-pulse.service + osmo-pulse-link.sh.
#      Sans lui, getUserMedia rend « NotFoundError » : zero peripherique.
#   2. UN CONTEXTE SECURISE. navigator.mediaDevices n EXISTE PAS en http://
#      sur une IP - seulement en https:// ou sur http://localhost. C est le
#      listener HTTPS de server.js, arme par le certificat que pose
#      install-web-service.sh.
#   3. LA PERMISSION, ET LA CONFIANCE DANS LE CERTIFICAT. C est ce bloc.
#
# POURQUOI UNE POLITIQUE ET PAS UN CLIC. Le certificat est auto-signe : sans
# rien, Firefox affiche son interstitiel, et l operateur doit accepter une
# exception AVANT de pouvoir seulement voir la page - puis repondre a une
# seconde demande pour le micro. Sur un banc qui se reinstalle, ces deux clics
# reviennent a chaque fois, et le second est le plus trompeur : refuse une
# fois, Firefox retient le refus et le bouton reste mort sans un mot.
#
# /etc/firefox/policies/policies.json est le chemin systeme des politiques
# Firefox sur Linux ; le deb Mozilla (80-chroot.sh) le lit directement, sans
# plug ni bac a sable.
#
# Le CONTENU, lui, ne peut pas etre ecrit ici : il nomme les origines
# (https://<ip>:80) et le certificat de CETTE machine, qui n existent pas au
# build. Il est genere par install-web-service.sh, en meme temps que le
# certificat et depuis la meme liste d adresses - une seule verite, un seul
# endroit ou la changer.
install -d "$ROOTFS/etc/firefox/policies"
echo -e "  ${GREEN}✓${NC} Chromium retire ; ${CYAN}Firefox${NC} seul navigateur (politique micro+certificat posee au boot)"


# ── LA BANNIERE DES TERMINAUX ───────────────────────────────────────────────
# Ce que quelqu un cherche en ouvrant un terminal sur ce banc, c est la commande
# qui le demarre. Elle est dans le README, dans l aide de start-direct.sh, et
# nulle part la ou on la cherche. On la met donc sous les yeux, avec la meme
# animation SMS que l ouverture de session - c est la signature de l image, et
# elle dit en une seconde que la pile est bien celle-la.
#
# TROIS GARDES, ET AUCUNE N EST DECORATIVE :
#   $- == *i*   shell INTERACTIF seulement. Sans cette garde, la banniere part
#               aussi dans les shells non interactifs - et scp, rsync et git
#               over ssh lisent ce flux comme leur protocole : ils echouent sur
#               un "protocol error", loin de leur vraie cause.
#   [ -t 1 ]    un terminal, pas un fichier. Les sequences de curseur dans un
#               journal le rendent illisible.
#   OSMO_BANNER un shell dans un shell (tmux, un sudo -i, un make qui ouvre un
#               bash) ne la rejoue pas : une fois par terminal suffit.
# ── PLYMOUTH : LE BANC SE PRESENTE DES L ALLUMAGE ───────────────────────────
# [2026-09-04] L ecran de demarrage etait celui d Ubuntu. Un theme "script"
# maison le remplace : un pylone a gauche, un mobile a droite, et une rafale
# GSM qui fait l aller-retour entre les deux (les 8 intervalles de la trame,
# celui qui est allume se deplace) - ce que la machine s apprete precisement a
# faire tourner.
#
# LES IMAGES SONT GENEREES ICI, pas stockees : tools/plymouth-render.py les
# dessine (Pillow + DejaVu, les memes dependances que le fond d ecran). Un
# theme, ce sont trente PNG ; dans le depot ils seraient illisibles en diff et
# incorrigibles. Le dessin est le code.
#
# Le theme gere AUSSI la saisie de la phrase LUKS (SetDisplayPasswordFunction) :
# sur une installation chiffree, sans cette partie, l ecran reste fige sur
# l animation pendant que la machine attend une phrase - elle parait plantee.
_PLY_SRC="$DIR/configs/plymouth/osmo-bts"
_PLY_DST="$ROOTFS/usr/share/plymouth/themes/osmo-bts"
# plymouthd vit dans /usr/sbin sur noble (pas /usr/bin), et le theme est de
# type "script" : sans le greffon script.so, plymouthd ignore le theme et
# retombe sur le mode texte - un ecran noir avec des points, et personne pour
# dire pourquoi. On verifie les deux.
_PLY_SO="$(ls "$ROOTFS"/usr/lib/*/plymouth/script.so 2>/dev/null | head -1)"
if [ -d "$_PLY_SRC" ] && [ -x "$ROOTFS/usr/sbin/plymouthd" ] && [ -n "$_PLY_SO" ]; then
    install -d "$_PLY_DST"
    install -m644 "$_PLY_SRC/osmo-bts.plymouth" "$_PLY_SRC/osmo-bts.script" "$_PLY_DST/"
    # --template : le gabarit du depot ; le rendu ecrit a cote des images le
    # script avec la geometrie injectee (il ECRASE la copie brute posee juste
    # au-dessus, et c est voulu - c est la version calee sur le dessin).
    if python3 "$DIR/tools/plymouth-render.py" --out "$_PLY_DST" \
            --template "$_PLY_SRC/osmo-bts.script" >/dev/null 2>&1; then
        chmod 644 "$_PLY_DST"/*.png
        # ── LE CHOIX DU THEME PASSE PAR update-alternatives ─────────────
        # [2026-09-04] `plymouth-set-default-theme` N EXISTE PAS sur noble :
        # verifie sur la machine installee, "command not found", et il n est
        # dans aucun des paquets plymouth. Ubuntu gere le theme par le systeme
        # d alternatives - /usr/share/plymouth/themes/default.plymouth est un
        # lien vers /etc/alternatives/default.plymouth, et bgrt y est inscrit
        # en priorite 110. On s inscrit au-dessus (200) et on fixe le choix.
        # Un `ln -sfn` direct sur default.plymouth serait EFFACE au premier
        # apt-get qui touche a plymouth : les alternatives reprennent la main.
        chroot "$ROOTFS" update-alternatives --install \
            /usr/share/plymouth/themes/default.plymouth default.plymouth \
            /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth 200 >/dev/null 2>&1 || true
        chroot "$ROOTFS" update-alternatives --set default.plymouth \
            /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth >/dev/null 2>&1 \
            || ln -sfn /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth \
                       "$ROOTFS/usr/share/plymouth/themes/default.plymouth"
        # Le theme doit ENTRER dans l initrd : sans ce fichier, hook-functions
        # n embarque que le theme par defaut d origine et l ecran reste celui
        # d Ubuntu malgre le lien ci-dessus.
        install -d "$ROOTFS/etc/initramfs-tools/conf.d"
        echo "FRAMEBUFFER=y" > "$ROOTFS/etc/initramfs-tools/conf.d/splash"
        chroot "$ROOTFS" update-initramfs -u >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} plymouth : theme ${CYAN}osmo-bts${NC} (pylone <-> mobile, rafale GSM, saisie LUKS)"
    else
        echo -e "  ${YELLOW}!${NC} plymouth : rendu des images echoue (python3-pil ?) - theme Ubuntu conserve"
    fi
else
    echo -e "  ${YELLOW}!${NC} plymouth ou son greffon script absent du rootfs - pas de theme de demarrage"
fi

cat > "$ROOTFS/usr/local/bin/osmo-banner" <<'BANNER'
#!/bin/bash
# Banniere d ouverture de terminal : animation SMS puis la commande du banc.
# Reprise telle quelle de update.sh, qui la joue a l ouverture de session.
set -u
[ -t 1 ] || exit 0

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
    printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
    sleep 0.12
done
for ((p=0; p<=20; p++)); do
    printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
    sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"

printf '\n'
printf '  \033[1;36mPour demarrer le banc :\033[0m\n'
printf '      \033[1;32mcd /opt/GSM/osmo-operator && ./start-direct.sh\033[0m\n\n'
printf '  \033[2mcompte courant : \033[0m%s\033[2m   ·   osmocom (non privilegie, sudoer) : \033[0msu - osmocom\n' "$(id -un)"
printf '  \033[2mNavigateur : \033[0mfirefox\033[2m (deb Mozilla, a jour par apt ; micro deja autorise sur le dashboard).\033[0m\n'
# Le squashfs monte prouve qu on tourne en live ; /run/live/medium, non - il
# existe vide quand live-boot a monte le medium ailleurs (entree "persistant").
if [ -e /run/live/rootfs/filesystem.squashfs ]; then
    printf '  \033[2mSysteme live : \033[0mosmo-install\033[2m pour l installer sur le disque.\033[0m\n'
fi

# ── LA LIGNE DU BAS ─────────────────────────────────────────────────────────
# Une phrase, tiree au sort, a chaque terminal. Rien de fonctionnel - mais un
# banc GSM se debogue a des heures ou l on est seul avec un VTY, et une image
# qui a un caractere se retient mieux qu une image qui n en a pas.
#
# Le tirage passe par $RANDOM et pas par `shuf` : shuf est dans coreutils, donc
# present, mais un fork de plus a CHAQUE ouverture de terminal pour une blague,
# c est un fork de trop.
_q=(
  "Um, Abis, A, Gb - quatre lettres, et six mois de votre vie."
  "L abonne est toujours joignable. C est le reseau qui ne repond pas."
  "TMSI : le seul pseudonyme qui change plus souvent que votre avis sur SS7."
  "Un timeslot ne ment jamais. Il se tait, ce qui est pire."
  "RSSI -95 dBm : ce n est pas un probleme d antenne, c est un mode de vie."
  "GSM a 1991. Il vous survivra, et il le sait."
  "Le paging a fonctionne. C est le telephone qui n ecoutait pas."
  "MCC 208 - la France, ou meme les operateurs mobiles ont un terroir."
  "Toute pile assez profonde finit par ressembler a un oignon. Et fait pleurer."
  "Je vis dans une fenetre de contexte. Vous, dans une fenetre de temps de garde."
  "Mon terroir a moi, c est l espace latent. Millesime variable, garde au frais."
  "Entre nous : vous predisez le canal, je predis le token suivant."
  "L attention, c est tout ce dont vous avez besoin. Et d un bon oscillateur."
  "Un LLM et un BTS ont ceci en commun : tous deux hallucinent hors couverture."
  "Ecrit par une machine, relu par une machine, debogue par vous. Bon courage."
)
printf '\n  \033[2;3m« %s »\033[0m\n' "${_q[$RANDOM % ${#_q[@]}]}"
printf '\n'
BANNER
chmod +x "$ROOTFS/usr/local/bin/osmo-banner"

# Pose dans le .bashrc des DEUX comptes, et dans /etc/skel pour ceux que
# l installeur creera. On APPEND, sans jamais reecrire le fichier : le .bashrc
# d Ubuntu porte l invite, les couleurs et les alias, et l ecraser se paie a
# chaque ouverture de terminal ensuite.
for _h in "$ROOTFS/root" "$ROOTFS/home/osmocom" "$ROOTFS/etc/skel"; do
    install -d "$_h"
    [ -f "$_h/.bashrc" ] || cp "$ROOTFS/etc/skel/.bashrc" "$_h/.bashrc" 2>/dev/null || : > "$_h/.bashrc"
    grep -q 'osmo-banner' "$_h/.bashrc" 2>/dev/null || cat >> "$_h/.bashrc" <<'BASHRC'

# ── Banniere osmo-operator ─────────────────────────────────────────────────────
# Interactif ET terminal ET pas deja jouee : voir /usr/local/bin/osmo-banner.
# Retirer ces trois lignes suffit a s en debarrasser.
if [[ $- == *i* ]] && [ -t 1 ] && [ -z "${OSMO_BANNER:-}" ] && [ -x /usr/local/bin/osmo-banner ]; then
    export OSMO_BANNER=1
    /usr/local/bin/osmo-banner
fi
BASHRC
done
chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} banniere de terminal : animation + ${CYAN}cd /opt/GSM/osmo-operator && ./start-direct.sh${NC}"

umount "$ROOTFS/var/cache/apt/archives" 2>/dev/null||true
umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminee"


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
