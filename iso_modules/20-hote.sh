#!/bin/bash
# iso_modules/20-hote.sh - paquets de l hote (iso_host_packages)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Paquets hote requis pour fabriquer l'ISO (squashfs, grub, xorriso...) ──
# Installes ici plutot que dans le workflow CI : `sudo ./build-iso.sh` suffit
# sur une machine Debian/Ubuntu vierge, sans etape "Install host tools" externe.
#
# [2026-09-10] LA LISTE EST CELLE D UNE UBUNTU 24.04 FRAICHE. Elle a ete
# etablie non pas d apres ce qui manquait sur LA machine de developpement -
# qui a tout depuis longtemps - mais d apres ce que la chaine APPELLE SUR L
# HOTE, paquet par paquet, en partant d une noble qui n a qu ubuntu-minimal.
# Ce qui manquait vraiment :
#   syslinux-utils   isohybrid (91-secure-boot). "isolinux" NE LE FOURNIT PAS :
#                    isolinux pose isolinux.bin, isohybrid est dans
#                    syslinux-utils. La ligne d avant listait isolinux et
#                    l ISO sortait sans table de partitions hybride - une clef
#                    USB gravee en dd ne bootait pas sur les BIOS qui l exigent.
#   rsync            unpackfs de calamares, et les copies de rootfs (87-lite).
#   wget curl        firmware TAS2781 et sources gsm-1.0.24 (52-qemu), noyau
#                    pmOS (88-lte-pmos), cles de depots (80-chroot).
#   ca-certificates gnupg  ces telechargements sont en https, et les cles de
#                    depot passent par gpg --dearmor.
#   python3-pil      tools/plymouth-render.py (86-finitions) : le theme de
#                    demarrage est GENERE, il lui faut Pillow.
#   python3-yaml     controle des configs calamares (85-installeur-bureau).
#   gcc make         toast/untoast (codec GSM 06.10) compile sur l hote pour
#                    le rootfs (52-qemu). Sans eux : ISO sans toast, en silence.
#   kpartx           images disque de l installeur et de pmOS (85, 88).
#   e2fsprogs fdisk util-linux  mke2fs / sfdisk / losetup.
#   xz-utils cpio file zstd  squashfs -comp xz, initrd, identification.
#   grub2-common     grub-install ; grub-common seul n a que grub-mkrescue.
# Ubuntu 24.04 fournit deja : tar, gzip, dpkg-deb, coreutils, mount. Pas la
# peine de les demander. aria2 et curl viennent avec apt-fast-install.sh.
#
# shim-signed / grub-efi-amd64-signed / dosfstools : la chaine Secure Boot.
# Voir "Etape 9" plus bas - sans eux l'ISO ne demarre pas sur une machine dont
# le Secure Boot est actif, et le firmware ne dit qu'une erreur de certificat.
# apt-fast partout : le meme installeur que le Dockerfile et le chroot
# (packaging/apt-fast-install.sh), donc les memes reglages apt sur l hote.
#
# COMMUN AUX DEUX ARCHITECTURES : tout ce qui n est ni grub ni xorriso.
ISO_HOST_PKGS_COMMON="debootstrap git rsync wget curl ca-certificates gnupg \
zstd xz-utils cpio file gcc make python3 python3-pil python3-yaml \
e2fsprogs fdisk util-linux dosfstools mtools kpartx"
# amd64 : l ISO elle-meme - squashfs, grub (BIOS + EFI), xorriso, isohybrid.
ISO_HOST_PKGS="$ISO_HOST_PKGS_COMMON squashfs-tools xorriso grub-common grub2-common grub-pc-bin grub-efi-amd64-bin shim-signed grub-efi-amd64-signed isolinux syslinux-common syslinux-utils"
# --arm : ni grub ni xorriso ni squashfs. Il faut l emulation (qemu-user-static
# + binfmt-support : chroot et docker executent de l aarch64 sur l hote x86),
# debootstrap, et de quoi fabriquer l image SD sans monter quoi que ce soit :
# mke2fs -d (e2fsprogs), mkfs.vfat + mcopy (dosfstools, mtools), sfdisk.
[ "${ISO_ARCH:-amd64}" = "arm64" ] \
    && ISO_HOST_PKGS="$ISO_HOST_PKGS_COMMON qemu-user-static binfmt-support docker-buildx"

# ── Docker : une dependance, pas une option ─────────────────────────────────
# Toute la chaine part d une image docker (build.sh, ou --skip-build qui la
# tire du Hub). build.sh pose docker.io + docker-compose-v2 + docker-buildx,
# mais il n est PAS appele en --skip-build - et le controle d outils de
# 22-wan-table, lui, exige docker dans les deux cas. On le pose donc ici.
# UNIQUEMENT SI ABSENT : sur un hote qui a docker-ce (depot Docker), poser
# docker.io le casserait. Un docker deja la, quelle que soit sa provenance,
# est laisse tel quel.
iso_host_docker() {
    if command -v docker >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
        return 0
    fi
    echo -e "  ${CYAN}docker absent : installation de docker.io + compose v2 + buildx${NC}"
    apt-fast install -y --no-install-recommends docker.io docker-compose-v2 docker-buildx \
        || apt-fast install -y --no-install-recommends docker.io docker-compose-v2 \
        || apt-fast install -y --no-install-recommends docker.io \
        || { echo -e "${RED}docker non installable par apt : posez-le (get.docker.com) et relancez${NC}" >&2; return 1; }
    systemctl enable --now docker >/dev/null 2>&1 || true
}

# ── Les outils que la chaine appelle, et le paquet qui les porte ────────────
# Le controle d avant ne nommait que six binaires et disait "Manquant: X" sans
# dire quoi installer. Ici chaque outil sait d ou il vient : un hote ou apt a
# echoue (miroir coupe, paquet retire) donne une ligne par outil et LA commande
# qui repare. Les outils optionnels (isohybrid, gcc) ne font qu avertir.
iso_host_check_tools() {
    local missing="" pkgs="" t p
    local required="debootstrap git rsync wget curl mkfs.vfat mcopy sfdisk mke2fs kpartx python3"
    local optional="isohybrid gcc make"
    [ "${ISO_ARCH:-amd64}" = "arm64" ] \
        || required="$required mksquashfs unsquashfs xorriso grub-mkrescue grub-mkimage"
    for t in $required; do
        command -v "$t" >/dev/null 2>&1 && continue
        case "$t" in
            mksquashfs|unsquashfs) p=squashfs-tools ;;
            grub-mkrescue|grub-mkimage) p=grub-common ;;
            mkfs.vfat) p=dosfstools ;;  mcopy) p=mtools ;;
            sfdisk) p=fdisk ;;          mke2fs) p=e2fsprogs ;;
            *) p="$t" ;;
        esac
        missing="$missing $t"; pkgs="$pkgs $p"
    done
    for t in $optional; do
        command -v "$t" >/dev/null 2>&1 \
            || echo -e "  ${YELLOW}!${NC} $t absent (optionnel) : $([ "$t" = isohybrid ] \
                 && echo "pas de table hybride sur l ISO (clef USB gravee en dd)" \
                 || echo "toast/untoast ne seront pas compiles")" >&2
    done
    if [ -n "$missing" ]; then
        echo -e "${RED}Outils hote manquants :${missing}${NC}" >&2
        echo -e "${RED}  apt-get install -y$(echo "$pkgs" | tr ' ' '\n' | sort -u | tr '\n' ' ')${NC}" >&2
        return 1
    fi
    # Pillow : plymouth-render.py est appele avec le python3 du PATH, qui peut
    # etre un venv (/root/.env) ou python3-pil n est pas. On avertit, on ne
    # bloque pas : le theme de demarrage n empeche pas l ISO de sortir.
    python3 -c "import PIL" >/dev/null 2>&1 \
        || echo -e "  ${YELLOW}!${NC} Pillow absent du python3 du PATH ($(command -v python3)) - theme Plymouth non genere" >&2
    return 0
}

# Appelable plusieurs fois (21-docker-build en --all, puis 22-wan-table) : apt
# ne tourne qu au premier appel. Sans ce garde-fou, une passe --all refaisait
# l `apt-fast install` a chaque module qui appelle la fonction.
_ISO_HOST_PKGS_DONE=0
iso_host_packages() {
    [ "$_ISO_HOST_PKGS_DONE" = "1" ] && return 0
    _ISO_HOST_PKGS_DONE=1
    if [ "${OSMO_ISO_HOST_READY:-0}" = "1" ]; then
        echo -e "${GREEN}[0/9] Paquets hote : deja poses par la passe parente${NC}"; return 0
    fi
    if command -v apt-get &>/dev/null; then
        echo -e "${GREEN}[0/9] Installation des paquets hote (apt-fast)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        bash "$DIR/packaging/apt-fast-install.sh" >/dev/null 2>&1 \
            || echo -e "  ${YELLOW}apt-fast non installe - apt-get${NC}"
        command -v apt-fast >/dev/null 2>&1 || apt-fast() { apt-get "$@"; }
        apt-fast update -qq || true
        # UN paquet introuvable (retire d une suite, miroir partiel) faisait
        # echouer la ligne entiere, et le repli d avant reposait une liste
        # ecrite a la main, plus courte que la vraie. Repli generique : on
        # reprend paquet par paquet, et on NOMME ceux qui n ont pas voulu.
        if ! apt-fast install -y --no-install-recommends $ISO_HOST_PKGS; then
            echo -e "  ${YELLOW}installation groupee refusee - reprise paquet par paquet${NC}"
            local _ko="" _p
            for _p in $ISO_HOST_PKGS; do
                apt-fast install -y --no-install-recommends "$_p" >/dev/null 2>&1 || _ko="$_ko $_p"
            done
            [ -n "$_ko" ] && echo -e "  ${YELLOW}non installes :${_ko}${NC}" >&2
        fi
        iso_host_docker || true
    else
        echo -e "${YELLOW}apt-get absent : verification seule des outils hote.${NC}"
    fi
    iso_host_check_tools
}

# ── binfmt : l hote x86 doit executer l aarch64 de facon TRANSPARENTE ────────
# Deux consommateurs. Le chroot du rootfs : il suffit que qemu-aarch64-static
# soit enregistre dans binfmt_misc et copie DANS le rootfs. Docker (buildx
# --platform linux/arm64, docker run de l image arm64 pour la cloture ldd) :
# le conteneur n a pas l emulateur, il faut le drapeau F (fix-binary) pour que
# le noyau garde un descripteur ouvert sur l emulateur de l hote. Le paquet
# qemu-user-static l enregistre avec F depuis jammy ; si ce n est pas le cas
# ici, on passe par l image binfmt de Docker (tonistiigi/binfmt), qui fait
# exactement cet enregistrement - c est un telechargement, il est dit.
iso_arm_binfmt() {
    [ "${ISO_ARCH:-amd64}" = "arm64" ] || return 0
    local f=/proc/sys/fs/binfmt_misc/qemu-aarch64
    [ -d /proc/sys/fs/binfmt_misc ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    [ -e "$f" ] || update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
    if [ -e "$f" ] && grep -q '^flags:.*F' "$f"; then
        echo -e "  ${GREEN}✓${NC} binfmt qemu-aarch64 (fix-binary) : chroot et docker savent executer l aarch64"
        return 0
    fi
    echo -e "  ${YELLOW}binfmt qemu-aarch64 sans drapeau F - enregistrement via tonistiigi/binfmt (docker)${NC}"
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || true
    if [ -e "$f" ] && grep -q '^flags:.*F' "$f"; then
        echo -e "  ${GREEN}✓${NC} binfmt qemu-aarch64 enregistre (fix-binary)"
    else
        echo -e "${RED}binfmt qemu-aarch64 indisponible : apt install qemu-user-static binfmt-support, puis relancez${NC}" >&2
        exit 1
    fi
}


# ── ET ON LES POSE ICI, AU LANCEMENT ────────────────────────────────────────
# [2026-09-10] La fonction etait DEFINIE dans ce module mais appelee seulement
# par 21-docker-build (branche --all) et 22-wan-table. Consequence sur une
# machine fraiche : le premier module a avoir besoin d un outil le trouvait
# absent, et l erreur tombait plusieurs etapes plus loin - loin de sa cause.
# Les paquets sont maintenant poses des le module 20, avant le moindre docker
# build ; le seul module qui passe avant est 10-clavier (la question du
# clavier, qu on veut toujours en premier). Les appels de 21 et 22 restent :
# ils ne refont rien (garde _ISO_HOST_PKGS_DONE).
iso_host_packages


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
