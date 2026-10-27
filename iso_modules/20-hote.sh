#!/bin/bash
# iso_modules/20-hote.sh - host packages needed to build the image (iso_host_packages)
# Sourced by build-iso.sh in numeric order (same shell, variables and
# functions); not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (that is how --arm skips a step).

# ── Host packages required to build the ISO (squashfs, grub, xorriso...) ──
# Installed here rather than in the CI workflow: `sudo ./build-iso.sh` is
# enough on a fresh Debian/Ubuntu machine.
#
# The list is what the chain calls ON THE HOST, starting from a fresh Ubuntu
# 24.04 with only ubuntu-minimal:
#   syslinux-utils   isohybrid (91-secure-boot). The isolinux package does NOT
#                    provide it; without it the ISO has no hybrid partition
#                    table and a dd-written USB key does not boot on some BIOSes.
#   rsync            calamares unpackfs, rootfs copies (87-lite).
#   wget curl        TAS2781 firmware and gsm-1.0.24 sources (52-qemu), pmOS
#                    kernel (88-lte-pmos), repository keys (80-chroot).
#   ca-certificates gnupg  downloads are https, repository keys go through
#                    gpg --dearmor.
#   python3-pil      tools/plymouth-render.py (86-finitions): the boot theme is
#                    GENERATED and needs Pillow.
#   python3-yaml     calamares config check (85-installeur-bureau).
#   gcc make         toast/untoast (GSM 06.10 codec) built on the host for the
#                    rootfs (52-qemu). Without them the ISO silently lacks toast.
#   kpartx           installer and pmOS disk images (85, 88).
#   e2fsprogs fdisk util-linux  mke2fs / sfdisk / losetup.
#   xz-utils cpio file zstd  squashfs -comp xz, initrd, identification.
#   grub2-common     grub-install; grub-common alone only has grub-mkrescue.
#   fonts-ubuntu     tools/grub-theme-render.py (86, 90): GRUB theme fonts,
#                    converted by grub-mkfont (grub-common).
#   meson ninja-build pkg-config libpulse-dev libx11-dev libxext-dev
#   libxrender-dev libxcomposite-dev libgl-dev  GLava built on the host for the
#                    rootfs (tools/glava-build.sh, 85-glava).
# Ubuntu 24.04 already provides tar, gzip, dpkg-deb, coreutils, mount. aria2
# and curl come with apt-fast-install.sh.
#
# shim-signed / grub-efi-amd64-signed / dosfstools: the Secure Boot chain
# (see step 9); without them the ISO does not boot with Secure Boot enabled
# and the firmware only reports a certificate error.
# apt-fast everywhere: same installer as the Dockerfile and the chroot
# (packaging/apt-fast-install.sh), hence the same apt settings on the host.
#
# COMMON TO BOTH ARCHITECTURES: everything except grub and xorriso.
ISO_HOST_PKGS_COMMON="debootstrap git rsync wget curl ca-certificates gnupg \
zstd xz-utils cpio file gcc make python3 python3-pil python3-yaml \
e2fsprogs fdisk util-linux dosfstools mtools kpartx"
# amd64: the ISO itself - squashfs, grub (BIOS + EFI), xorriso, isohybrid.
ISO_HOST_PKGS="$ISO_HOST_PKGS_COMMON squashfs-tools xorriso grub-common grub2-common grub-pc-bin grub-efi-amd64-bin shim-signed grub-efi-amd64-signed isolinux syslinux-common syslinux-utils \
fonts-ubuntu meson ninja-build pkg-config libpulse-dev libx11-dev libxext-dev libxrender-dev libxcomposite-dev libgl-dev"
# --arm: no grub, xorriso or squashfs. Needs emulation (qemu-user-static +
# binfmt-support: chroot and docker run aarch64 code on the x86 host),
# debootstrap, and tools to build the SD image without mounting anything:
# mke2fs -d (e2fsprogs), mkfs.vfat + mcopy (dosfstools, mtools), sfdisk.
[ "${ISO_ARCH:-amd64}" = "arm64" ] \
    && ISO_HOST_PKGS="$ISO_HOST_PKGS_COMMON qemu-user-static binfmt-support docker-buildx"

# ── Docker: a dependency, not an option ───────────────────────────────────
# The whole chain starts from a docker image (build.sh, or a pull). build.sh
# installs docker.io + docker-compose-v2 + docker-buildx but is not called on
# a pull, while the 22-wan-table tool check requires docker in both cases.
# ONLY IF MISSING: installing docker.io on a host with docker-ce (Docker repo)
# would break it. An existing docker, whatever its origin, is left as is.
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

# ── Tools called by the chain, and the package providing each ─────────────
# A missing tool is reported with THE command that installs it. Optional
# tools (isohybrid, gcc) only produce a warning.
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
    # Pillow: plymouth-render.py runs with the python3 from PATH, which may be a
    # venv (/root/.env) without python3-pil. Warning only: the boot theme does
    # not prevent the ISO from being built.
    python3 -c "import PIL" >/dev/null 2>&1 \
        || echo -e "  ${YELLOW}!${NC} Pillow absent du python3 du PATH ($(command -v python3)) - theme Plymouth non genere" >&2
    return 0
}

# May be called several times (21-docker-build with --all, then
# 22-wan-table): apt only runs on the first call.
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
        # One unavailable package (removed from a suite, partial mirror) fails the
        # whole line: fall back to installing package by package and NAME the
        # failures.
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

# ── binfmt: the x86 host must run aarch64 code TRANSPARENTLY ──────────────
# Two consumers. The rootfs chroot: qemu-aarch64-static must be registered in
# binfmt_misc and copied INTO the rootfs. Docker (buildx --platform
# linux/arm64, docker run of the arm64 image for the ldd closure): the
# container has no emulator, so the F (fix-binary) flag is required for the
# kernel to keep the host emulator open. qemu-user-static registers it with F
# since jammy; otherwise use Docker's binfmt image (tonistiigi/binfmt), which
# does exactly that registration (a download, announced).
#
# On an arm64 host there is nothing to emulate: compare with the host
# architecture, as build.sh and 40-rootfs.sh do, and only set up emulation
# when they differ.
iso_arm_binfmt() {
    [ "${ISO_ARCH:-amd64}" = "arm64" ] || return 0
    if [ "${ISO_ARCH}" = "$(dpkg --print-architecture 2>/dev/null || echo amd64)" ]; then
        echo -e "  ${GREEN}✓${NC} hote deja en ${ISO_ARCH} : ni qemu-user ni binfmt, tout est natif"
        return 0
    fi
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


# ── INSTALL THEM HERE, AT STARTUP ──────────────────────────────────────────
# Host packages are installed in module 20, before any docker build, so a
# missing tool fails early (only 10-clavier runs before). The calls in 21 and
# 22 do nothing more (_ISO_HOST_PKGS_DONE guard).
iso_host_packages


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
