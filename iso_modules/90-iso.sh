#!/bin/bash
# iso_modules/90-iso.sh - etape 9 : squashfs, noyau, menu GRUB, /.disk
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# --arm : pas de squashfs ni de GRUB : 92-rpi-image ecrit l image SD.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ── Creation du squashfs et de l'ISO ───────────────────────────────────────
echo -e "${GREEN}[9/9] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

# 2>/dev/null || true : sous pipefail, un ls sans resultat faisait sortir le
# script AVANT le message « Kernel absent » qui suit.
VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$VMLINUZ" ] || [ -z "$INITRD" ]; then echo -e "${RED}Kernel absent${NC}"; exit 1; fi
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

# ── Compression du squashfs : zstd, et non xz ────────────────────────────────
# Le noyau embarque est compile avec CONFIG_SQUASHFS_DECOMP_SINGLE=y : UN SEUL
# flux de decompression, serialise par un mutex. Ajouter des vCPU a la VM n'y
# change donc rien - c'est le seul chiffre qui compte quand l'ISO est lue a la
# demande, et c'est celui qu'on regarde le moins.
#
# Mesure faite sur ce depot, meme contenu (360 Mo de /usr/bin de l'ISO lite),
# decompression a UN thread :
#
#     -comp xz -Xbcj x86    92,0 Mo    3,82 s
#     -comp zstd -level 19 106,9 Mo    0,41 s
#
# 16 % d'ISO en plus contre 9x en vitesse de lecture. Sur une image qui vit en
# machine virtuelle, dont chaque fichier ouvert au demarrage coute une
# decompression de bloc de 1 Mo, l'arbitrage se tranche tout seul.
#
# Le repli sur xz n'est pas de la prudence decorative : mksquashfs n'a le zstd
# que depuis la 4.4, et il n'est compile que si la libzstd etait la. On SONDE
# donc l'outil au lieu de lire son numero de version - une compression d'essai
# repond juste, une comparaison de versions non.
_squash_zstd_ok() {
    local t rc
    t="$(mktemp -d)" || return 1
    : > "$t/probe"
    mksquashfs "$t" "$t.sqfs" -comp zstd -no-progress -noappend >/dev/null 2>&1
    rc=$?
    rm -rf "$t" "$t.sqfs"
    return $rc
}

if _squash_zstd_ok; then
    SQUASH_COMP=(-comp zstd -Xcompression-level 19)
    echo -e "  Compression: ${CYAN}zstd -19${NC} (lecture ~9x plus rapide que xz a un thread)"
else
    SQUASH_COMP=(-comp xz -Xbcj x86)
    echo -e "  Compression: ${YELLOW}xz${NC} (mksquashfs sans zstd - ISO plus petite, mais lente a lire)"
fi

# [2026-09-02] PLUS D EXCLUSION de boot/vmlinuz-* ni de boot/initrd* : ce
# squashfs n est pas seulement la racine du live, c est aussi la SOURCE de
# Calamares (unpackfs.conf). Sans noyau dedans, le systeme installe n avait ni
# vmlinuz ni initrd : grub-mkconfig n ecrivait aucune entree Linux et la
# machine ne demarrait plus apres « installation reussie ». Les ~100 Mo de
# plus sont deja compresses (le noyau l est), ils ne pesent presque rien ici.
# ── Controle d integrite : les fichiers des paquets contre leurs md5 dpkg ───
# [2026-09-09] Le build du 8 au soir a livre une ISO ou ~440 fichiers
# differaient d UN bit (le bit 0 tombe a zero, jusque dans des noms de
# fichiers : « __pyc`che__ », « usr.share ») de ce que dpkg avait pose :
# libgjs, libmozjs, Xwayland, firefox, mesa, libwireshark... Resultat : GNOME
# Shell segfaultait dans libmozjs a chaque lancement, « Oh no! Something has
# gone wrong » au premier boot (VirtualBox comme QEMU). Les .deb sont
# verifies par leur CRC xz a l extraction : l alteration s est faite APRES,
# sur l hote (RAM ou disque) - une machine qui flanche sous la charge du
# build. Aucun maillon de la chaine ne le voit ; on compare donc les fichiers
# des paquets a leur md5 dpkg.
#
# [2026-09-14] Le controle ne se faisait qu APRES coup, sur le squashfs relu :
# il englobait tout le trajet, de l ecriture par dpkg jusqu a la relecture, et
# ne savait donc pas dire OU le bit avait bascule. On controle desormais DEUX
# FOIS, avec exactement le meme filtre - sans quoi comparer les deux listes
# n aurait aucun sens :
#
#   rootfs altere            -> c est ANTERIEUR a la compression (dpkg, ou une
#                               etape du build qui reecrit par-dessus un paquet)
#   rootfs sain + sqfs altere-> c est mksquashfs ou la relecture
#
# Ce que le build modifie lui-meme est ecarte : /opt et /root (sources et
# venv), /usr/local, MongoDB, les unites osmo-* (recopiees du docker),
# calamares.desktop (NoDisplay), live-boot (toram), os-release ; les fichiers
# supprimes (docs, locales) ne comptent pas ; ni les libs de la cloture ldd de
# l etape 8b, qui remplacent CELLES D APT a dessein ($WORK/closure.list).
#
# Et les listes sont desormais HORODATEES. Le critere qui tranche - « les
# memes fichiers a chaque build » (une etape du build les reecrit) contre « un
# tirage different a chaque fois » (l hote qui flanche) - etait inverifiable
# tant qu un fichier unique etait ecrase a chaque build : le rapport le pose
# maintenant tout seul, en comparant au build precedent.
# Environ 40 s par passe. OSMO_ISO_NO_VERIFY=1 pour passer outre.
_vfy_stamp="$(date +%Y%m%d-%H%M%S)"

# Le controle, applique a une racine quelconque. Pose _vfy_out (les chemins en
# echec, sans le « : FAILED » - on compare ces listes d un build a l autre),
# _vfy_n (leur nombre) et _vfy_prev (la liste du build precedent de meme
# etiquette, vide au premier build).
_vfy_paquets() {   # $1 = etiquette (rootfs|squashfs), $2 = racine a controler
    local _k="$1" _r="$2" _skip="$WORK/closure.list"
    [ -s "$_skip" ] || _skip=/dev/null
    _vfy_out="/var/tmp/osmo-iso-verify-${_vfy_stamp}-${_k}.failed"
    ( cd "$_r" && cat var/lib/dpkg/info/*.md5sums 2>/dev/null \
        | grep -vE '^[0-9a-f]{32}  (opt/|root/|usr/local/|mongodb|usr/lib/systemd/system/osmo-|usr/share/applications/calamares\.desktop$|lib/live/boot/|usr/lib/os-release$)' \
        | awk -v skip="$_skip" 'BEGIN{while((getline l < skip)>0) s[l]=1} !(substr($0,35) in s)' \
        | md5sum -c --quiet 2>/dev/null | grep -v 'open or read' \
        | sed 's/: FAILED$//' ) > "$_vfy_out" || true
    _vfy_n=$(wc -l < "$_vfy_out")
    # Le chemin historique reste valable : il pointe sur la derniere passe.
    ln -sf "$_vfy_out" /var/tmp/osmo-iso-verify.failed
    _vfy_prev=$(ls -1t /var/tmp/osmo-iso-verify-*-"${_k}".failed 2>/dev/null \
        | grep -vF "$_vfy_stamp" | head -1) || true
    # Les 20 dernieres : de quoi juger la stabilite, pas de quoi remplir /var/tmp.
    ls -1t /var/tmp/osmo-iso-verify-*-"${_k}".failed 2>/dev/null \
        | tail -n +21 | xargs -r rm -f || true
}

# Le verdict, une fois qu une liste n est pas vide. C est la comparaison au
# build precedent qui porte le diagnostic, pas le nombre de fichiers.
_vfy_verdict() {
    local _c
    head -8 "$_vfy_out" | sed 's/^/      /'
    if [ "$_vfy_n" -gt 8 ]; then echo "      ... (liste complete : $_vfy_out)"; fi
    if [ -n "$_vfy_prev" ]; then
        _c=$(grep -cxF -f "$_vfy_out" "$_vfy_prev" 2>/dev/null) || _c=0
        if [ "${_c:-0}" -gt 0 ]; then
            echo -e "  ${YELLOW}${_c} de ces fichiers echouaient DEJA au build precedent${NC}"
            echo -e "  ${YELLOW}($(basename "$_vfy_prev")) : la liste est STABLE. Ce n est pas de la${NC}"
            echo -e "  ${YELLOW}RAM qui flanche - c est une etape du build qui reecrit ces fichiers${NC}"
            echo -e "  ${YELLOW}par-dessus leur paquet sans etre ecartee du filtre ci-dessus.${NC}"
        else
            echo -e "  ${YELLOW}Aucun de ces fichiers n echouait au build precedent${NC}"
            echo -e "  ${YELLOW}($(basename "$_vfy_prev")) : le tirage CHANGE a chaque fois. Aucune${NC}"
            echo -e "  ${YELLOW}etape du build ne vise des fichiers au hasard : c est l hote.${NC}"
            echo -e "  ${YELLOW}RAM non-ECC (rien ne sera jamais signale), chauffe, disque.${NC}"
            echo -e "  ${YELLOW}memtest86+ plusieurs passes, temperatures sous charge.${NC}"
        fi
    else
        echo -e "  ${YELLOW}Pas de build precedent a comparer. Relancer tel quel : meme liste =${NC}"
        echo -e "  ${YELLOW}une etape du build reecrit ces fichiers ; liste differente = l hote.${NC}"
    fi
}

# Passe 1 : le rootfs tel que dpkg et le build l ont laisse. Avant les 20 Go
# de compression - inutile de les payer pour retrouver l alteration a la sortie.
if [ "${OSMO_ISO_NO_VERIFY:-0}" != "1" ]; then
    _vfy_paquets rootfs "$ROOTFS"
    if [ "$_vfy_n" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} rootfs conforme a dpkg avant compression"
    else
        echo -e "  ${RED}✗ rootfs ALTERE AVANT compression : ${_vfy_n} fichier(s)${NC}"
        _vfy_verdict
        echo -e "  ${YELLOW}L alteration est ANTERIEURE a mksquashfs : la compression et sa${NC}"
        echo -e "  ${YELLOW}relecture sont hors de cause, ne pas les chercher.${NC}"
        echo -e "  ${YELLOW}OSMO_ISO_NO_VERIFY=1 pour livrer quand meme (l ISO plantera).${NC}"
        exit 1
    fi
fi

mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    "${SQUASH_COMP[@]}" -b 1M \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

# ── Passe 2 : le squashfs relu, contre les memes md5 dpkg ──────────────────
# La passe 1 (avant mksquashfs) a dit que le rootfs etait sain ; ce qui
# echoue ici n a donc pu etre altere que par la compression elle-meme, son
# ecriture, ou cette relecture. Voir le pave de la passe 1 pour le filtre.
if [ "${OSMO_ISO_NO_VERIFY:-0}" != "1" ]; then
    _vfy_mnt="$WORK/sqfs-verify"
    mkdir -p "$_vfy_mnt"
    if mount -t squashfs -o loop,ro "$ISOROOT/live/filesystem.squashfs" "$_vfy_mnt" 2>/dev/null; then
        _vfy_paquets squashfs "$_vfy_mnt"
        umount "$_vfy_mnt" 2>/dev/null || true
        if [ "$_vfy_n" -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} squashfs relu : les fichiers des paquets sont conformes a dpkg"
        else
            echo -e "  ${RED}✗ squashfs ALTERE : ${_vfy_n} fichier(s) ne correspondent plus a leur paquet${NC}"
            _vfy_verdict
            echo -e "  ${YELLOW}Le rootfs, lui, etait conforme juste avant (passe 1) : les memes${NC}"
            echo -e "  ${YELLOW}octets sont devenus faux EN PASSANT par mksquashfs. Compression a${NC}"
            echo -e "  ${YELLOW}tous les coeurs = le moment ou l hote chauffe le plus du build.${NC}"
            echo -e "  ${YELLOW}OSMO_ISO_NO_VERIFY=1 pour livrer quand meme (l ISO plantera).${NC}"
            exit 1
        fi
    else
        echo -e "  ${YELLOW}!${NC} squashfs non relu (mount loop impossible) : seule la passe 1 a parle"
    fi
    rmdir "$_vfy_mnt" 2>/dev/null || true
    unset _vfy_mnt _vfy_out _vfy_n _vfy_prev _vfy_stamp
fi

cp "$VMLINUZ" "$ISOROOT/boot/vmlinuz"
cp "$INITRD"  "$ISOROOT/boot/initrd.img"

# ── Menu GRUB ────────────────────────────────────────────────────────────────
# Les chiffres de RAM annonces sont CALCULES sur le squashfs qui vient d'etre
# ecrit, pas recopies d'un ancien build. Les libelles en dur ("RAM ~6 Go")
# etaient faux des que l'image maigrissait, et une consigne fausse coute plus
# cher que pas de consigne : on dimensionne la VM sur elle.
SQ_MB=$(( $(stat -Lc%s "$ISOROOT/live/filesystem.squashfs") / 1048576 ))
# toram recopie le squashfs dans un tmpfs, puis le systeme tourne par-dessus :
# la taille du fichier, plus 2 Go pour le reste, arrondi au Go superieur.
RAM_TORAM_GB=$(( (SQ_MB + 2048 + 1023) / 1024 ))
SQ_GB=$(awk -v m="$SQ_MB" 'BEGIN{printf "%.1f", m/1024}')

cat > "$ISOROOT/boot/grub/grub.cfg" <<GRUB
# ATTENTION - ce fichier est GENERE par build-iso.sh. Le modifier dans l'ISO ne
# survit pas au build suivant.
#
# Sous VirtualBox, deux reglages evitent des minutes d'attente sur l'entree
# "en RAM" : attacher l'ISO au controleur SATA plutot qu'IDE, et cocher
# "Utiliser le cache E/S de l'hote" dessus.

set default=0
set timeout=5

# TROIS entrees, et le reste dans un sous-menu. Cinq lignes dont deux doublons
# "verbose", c est un menu ou l on cherche - alors que le choix reel n en compte
# que trois : lire depuis le medium, copier en RAM, ecrire sur le medium.
menuentry "osmo-operator" {
    linux  /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}

# "toram" tout court ferait recopier a live-boot le MEDIUM ENTIER dans un tmpfs
# (lib/live/boot/9990-toram-todisk.sh) : le squashfs, mais AUSSI l initrd de
# 82 Mo, le vmlinuz et efi.img. Et comme rsync n est pas dans l initrd, la copie
# se fait par "cp -a", qui n affiche RIEN - avec "quiet" en plus, l ecran reste
# fige plusieurs minutes sans le moindre signe de vie, et on croit a un
# plantage. D ou "toram=filesystem.squashfs" (seul le squashfs est copie, et le
# tmpfs est dimensionne sur lui) et l absence de "quiet" ici : la copie se voit.
menuentry "osmo-operator - en RAM (copie ${SQ_GB} Go - ${RAM_TORAM_GB} Go de RAM mini)" {
    linux  /boot/vmlinuz boot=live toram=filesystem.squashfs
    initrd /boot/initrd.img
}

# Sans persistance, la racine est un overlay tmpfs : tout ce qui s ecrit vit en
# RAM et meurt au reboot - configs SS7 posees a la main, base HLR, journaux.
# PAS de toram ici, et c est le point : avec toram le systeme est recopie en RAM
# et l overlay y reste, ce qui annulerait l interet.
#
# Il faut un volume ETIQUETE "persistence" portant un persistence.conf dont la
# seule ligne utile est "/ union" :
#   sudo mkfs.ext4 -L persistence /dev/sdX3
#   sudo mount /dev/sdX3 /mnt && echo "/ union" | sudo tee /mnt/persistence.conf
# En VM, un second disque suffit. Sans volume ainsi etiquete, cette entree
# demarre comme un live ordinaire : rien ne casse, rien n est garde.
menuentry "osmo-operator - persistant (ecrit sur le medium)" {
    linux  /boot/vmlinuz boot=live persistence persistence-encryption=none quiet
    initrd /boot/initrd.img
}

# Les variantes verbose ne servent qu au diagnostic : elles sont les memes
# lignes de commande sans "quiet". Elles restent atteignables, mais elles ne
# tiennent plus la moitie du menu.
# [2026-09-08] SANS ACCELERATION GRAPHIQUE. Un GPU que le noyau 6.8 de l ISO
# ne sait pas (AMD RDNA recent sans son firmware, NVIDIA sans nouveau) donne
# un ecran noir ou un plantage a l amorcage : nomodeset laisse le framebuffer
# du firmware, le bureau tourne en logiciel, et l on peut au moins installer.
menuentry "osmo-operator - sans acceleration graphique (nomodeset : ecran noir, plantage AMD/NVIDIA)" {
    linux  /boot/vmlinuz boot=live nomodeset quiet
    initrd /boot/initrd.img
}

submenu "Options (demarrage verbeux)" {
    menuentry "osmo-operator - verbose" {
        linux  /boot/vmlinuz boot=live
        initrd /boot/initrd.img
    }
    menuentry "osmo-operator - persistant verbose" {
        linux  /boot/vmlinuz boot=live persistence persistence-encryption=none
        initrd /boot/initrd.img
    }
    menuentry "osmo-operator - persistant, sans acceleration graphique (nomodeset)" {
        linux  /boot/vmlinuz boot=live persistence persistence-encryption=none nomodeset
        initrd /boot/initrd.img
    }
}
GRUB
echo -e "  ${GREEN}✓${NC} menu GRUB : defaut = lecture depuis le medium ; toram annonce ${CYAN}${RAM_TORAM_GB} Go${NC} de RAM"

# ── /.disk/info : LE FICHIER SANS LEQUEL L'ISO S'ARRETE SUR "grub>" EN UEFI ──
# Ce fichier vide d'apparence est ce que le GRUB signe d'Ubuntu CHERCHE pour se
# reperer. gcdx64.efi.signed porte un disque memoire dont la configuration est,
# mot pour mot :
#
#     if [ -z "$prefix" -o ! -e "$prefix" ]; then
#         if ! search --file --set=root /.disk/info; then
#             search --file --set=root /.disk/mini-info
#         fi
#         set prefix=($root)/boot/grub
#     fi
#     ... source $prefix/grub.cfg ... sinon source $cmdpath/grub.cfg
#
# Son prefixe compile vaut "/boot/grub" SANS peripherique : il se resout donc
# sur le disque d'ou le firmware a charge le binaire, c'est-a-dire la partition
# EFI (FAT) - qui ne contient pas /boot/grub. Le test "! -e $prefix" est vrai,
# et tout repose alors sur la recherche de /.disk/info. Ce fichier n'existait
# pas ici : la recherche echouait, $root restait sur la FAT, aucun grub.cfg
# n'etait trouve, et GRUB rendait la main sur son invite "grub>".
#
# POURQUOI CA MARCHAIT EN MACHINE VIRTUELLE. VirtualBox demarre en BIOS par
# defaut : c'est eltorito.img qui joue, construit ici avec -p /boot/grub sur
# le lecteur de boot, et il trouve sa configuration sans rien chercher. Le
# chemin UEFI - le seul qu'un portable recent emprunte - n'etait donc jamais
# exerce. La panne n'etait pas "sur ce portable", elle etait sur TOUT UEFI.
#
# Les ISO Ubuntu et Debian posent ce meme fichier, pour cette meme raison.
mkdir -p "$ISOROOT/.disk"
printf 'osmo-operator %s - live amd64 (%s)\n' "$VERSION" "$LABEL" > "$ISOROOT/.disk/info"
cp "$ISOROOT/.disk/info" "$ISOROOT/.disk/mini-info"
echo -e "  ${GREEN}✓${NC} ${CYAN}/.disk/info${NC} pose : le GRUB signe retrouve le medium en UEFI"

# Les modules EFI, la ou $prefix les cherchera. Le menu genere plus haut n'use
# que de commandes deja compilees dans le binaire signe (set, menuentry, linux,
# initrd, submenu), mais grub-mkrescue les deposait, et leur absence transforme
# le moindre "insmod" tape a l'invite en echec incomprehensible. 3 Mo.
if [ -d /usr/lib/grub/x86_64-efi ]; then
    mkdir -p "$ISOROOT/boot/grub/x86_64-efi"
    cp -a /usr/lib/grub/x86_64-efi/*.mod /usr/lib/grub/x86_64-efi/*.lst \
          "$ISOROOT/boot/grub/x86_64-efi/" 2>/dev/null || true
    # ATTENTION : surtout PAS de grub.cfg dans ce repertoire. La configuration
    # embarquee ci-dessus teste "$prefix/x86_64-efi/grub.cfg" AVANT
    # "$prefix/grub.cfg" : un fichier ici detournerait le menu.
    rm -f "$ISOROOT/boot/grub/x86_64-efi/grub.cfg"
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
