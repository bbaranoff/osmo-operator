#!/bin/bash
# iso_modules/20-hote.sh - paquets de l hote (iso_host_packages)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Paquets hote requis pour fabriquer l'ISO (squashfs, grub, xorriso...) ──
# Installes ici plutot que dans le workflow CI : `sudo ./build-iso.sh` suffit
# sur une machine Debian/Ubuntu vierge, sans etape "Install host tools" externe.
# shim-signed / grub-efi-amd64-signed / dosfstools : la chaine Secure Boot.
# Voir "Etape 9" plus bas - sans eux l'ISO ne demarre pas sur une machine dont
# le Secure Boot est actif, et le firmware ne dit qu'une erreur de certificat.
# apt-fast partout : le meme installeur que le Dockerfile et le chroot
# (packaging/apt-fast-install.sh), donc les memes reglages apt sur l hote.
ISO_HOST_PKGS="squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools debootstrap git isolinux shim-signed grub-efi-amd64-signed zstd"
# --arm : ni grub ni xorriso ni squashfs. Il faut l emulation (qemu-user-static
# + binfmt-support : chroot et docker executent de l aarch64 sur l hote x86),
# debootstrap, et de quoi fabriquer l image SD sans monter quoi que ce soit :
# mke2fs -d (e2fsprogs), mkfs.vfat + mcopy (dosfstools, mtools), sfdisk.
[ "${ISO_ARCH:-amd64}" = "arm64" ] \
    && ISO_HOST_PKGS="debootstrap qemu-user-static binfmt-support dosfstools mtools e2fsprogs util-linux git zstd docker-buildx"
iso_host_packages() {
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
        # isolinux est optionnel (isohybrid) : on n'echoue pas s'il manque.
        apt-fast install -y --no-install-recommends $ISO_HOST_PKGS \
            || { [ "${ISO_ARCH:-amd64}" = "arm64" ] \
                 && apt-fast install -y --no-install-recommends debootstrap qemu-user-static binfmt-support dosfstools mtools e2fsprogs git \
                 || apt-fast install -y --no-install-recommends \
               squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools debootstrap git; }
    else
        echo -e "${YELLOW}apt-get absent : verification seule des outils hote.${NC}"
    fi
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

