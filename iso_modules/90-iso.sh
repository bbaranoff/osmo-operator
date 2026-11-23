#!/bin/bash
# iso_modules/90-iso.sh - step 9: squashfs, kernel, GRUB menu, /.disk.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment variables:
#   OSMO_ISO_NO_VERIFY=1     skip the dpkg md5 integrity checks (~40 s per pass)
#   OSMO_ISO_SQUASH_JOBS=N   limit mksquashfs to N CPU cores (default: all)

# --arm: no squashfs or GRUB; 92-rpi-image writes the SD image.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ── Squashfs and ISO creation ──────────────────────────────────────────────
echo -e "${GREEN}[9/9] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

# 2>/dev/null || true: under pipefail an empty ls would exit before the
# "Kernel absent" message below.
VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$VMLINUZ" ] || [ -z "$INITRD" ]; then echo -e "${RED}Kernel absent${NC}"; exit 1; fi
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

# ── Squashfs compression: zstd rather than xz ──────────────────────────────
# The embedded kernel has CONFIG_SQUASHFS_DECOMP_SINGLE=y (one serialised
# decompression stream), so single-thread decompression speed matters: zstd
# -19 reads ~9x faster than xz for ~16% larger images.
# Fallback to xz: mksquashfs only supports zstd since 4.4 and only if built
# with libzstd, so the tool is probed with a test compression.
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

# ── Integrity check: package files against their dpkg md5sums ─────────────
# Kernel and initrd are kept in the squashfs: it is also the Calamares source
# (unpackfs.conf), and the installed system needs them.
#
# The check runs twice with exactly the same filter, so both lists compare:
#
#   rootfs altered            -> before compression (dpkg, or a build step
#                                overwriting a packaged file)
#   rootfs ok + squashfs bad  -> mksquashfs or the read-back
#
# Excluded (modified by the build on purpose): /opt and /root (sources and
# venv), /usr/local, MongoDB, osmo-* units, calamares.desktop (NoDisplay),
# live-boot (toram), os-release, usr/bin/screenfetch (patched by
# 86-finitions.sh), and the ldd-closure libs of step 8b ($WORK/closure.list).
# Deleted files (docs, locales) do not count.
#
# Result lists are timestamped and compared with the previous build: the same
# files every time points to a build step, a different set to the host.
# About 40 s per pass. OSMO_ISO_NO_VERIFY=1 skips it.
_vfy_stamp="$(date +%Y%m%d-%H%M%S)"

# Run the check on a given root. Sets _vfy_out (failing paths, without
# ": FAILED"), _vfy_n (their count) and _vfy_prev (list of the previous build
# with the same label, empty on the first build).
_vfy_paquets() {   # $1 = label (rootfs|squashfs), $2 = root to check
    local _k="$1" _r="$2" _skip="$WORK/closure.list"
    [ -s "$_skip" ] || _skip=/dev/null
    _vfy_out="/var/tmp/osmo-iso-verify-${_vfy_stamp}-${_k}.failed"
    ( cd "$_r" && cat var/lib/dpkg/info/*.md5sums 2>/dev/null \
        | grep -vE '^[0-9a-f]{32}  (opt/|root/|usr/local/|mongodb|usr/lib/systemd/system/osmo-|usr/share/applications/calamares\.desktop$|lib/live/boot/|usr/lib/os-release$|usr/bin/screenfetch$)' \
        | awk -v skip="$_skip" 'BEGIN{while((getline l < skip)>0) s[l]=1} !(substr($0,35) in s)' \
        | md5sum -c --quiet 2>/dev/null | grep -v 'open or read' \
        | sed 's/: FAILED$//' ) > "$_vfy_out" || true
    _vfy_n=$(wc -l < "$_vfy_out")
    # Legacy path, points to the latest pass.
    ln -sf "$_vfy_out" /var/tmp/osmo-iso-verify.failed
    _vfy_prev=$(ls -1t /var/tmp/osmo-iso-verify-*-"${_k}".failed 2>/dev/null \
        | grep -vF "$_vfy_stamp" | head -1) || true
    # Keep the last 20 lists.
    ls -1t /var/tmp/osmo-iso-verify-*-"${_k}".failed 2>/dev/null \
        | tail -n +21 | xargs -r rm -f || true
}

# Verdict for a non-empty list. The comparison with the previous build gives
# the diagnosis, not the number of files.
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
            echo -e "  ${YELLOW}RAM non-ECC : rien ne sera jamais signale (ni EDAC, ni dmesg).${NC}"
            echo -e "  ${YELLOW}La faute n apparait que SOUS CHARGE SOUTENUE sur tous les coeurs :${NC}"
            echo -e "  ${YELLOW}memtest86+ peut passer une nuit entiere sans rien voir (il ne${NC}"
            echo -e "  ${YELLOW}chauffe pas le CPU). Refaire plutot ce build a froid, et le${NC}"
            echo -e "  ${YELLOW}refaire avec OSMO_ISO_SQUASH_JOBS=4 : si les echecs disparaissent${NC}"
            echo -e "  ${YELLOW}a 4 coeurs et reviennent a 32, c est l alimentation/le CPU sous${NC}"
            echo -e "  ${YELLOW}charge, pas une barrette morte (un i9-14900HX est concerne par${NC}"
            echo -e "  ${YELLOW}l instabilite Raptor Lake : microcode a jour = degradation${NC}"
            echo -e "  ${YELLOW}arretee, pas reparee). Sinon : memtest86+, et temperatures.${NC}"
        fi
    else
        echo -e "  ${YELLOW}Pas de build precedent a comparer. Relancer tel quel : meme liste =${NC}"
        echo -e "  ${YELLOW}une etape du build reecrit ces fichiers ; liste differente = l hote.${NC}"
    fi
}

# Pass 1: the rootfs as left by dpkg and the build, before compression.
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

# ── OSMO_ISO_SQUASH_JOBS: limit compression parallelism ───────────────────
# mksquashfs uses all cores by default. Limiting it helps tell host
# instability under full load from a build problem, and allows a correct
# (slower) build on such a host. Empty by default.
SQUASH_JOBS=()
if [ -n "${OSMO_ISO_SQUASH_JOBS:-}" ]; then
    SQUASH_JOBS=(-processors "$OSMO_ISO_SQUASH_JOBS")
    echo -e "  ${CYAN}compression bridee a ${OSMO_ISO_SQUASH_JOBS} coeur(s) (OSMO_ISO_SQUASH_JOBS)${NC}"
fi
mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    "${SQUASH_COMP[@]}" "${SQUASH_JOBS[@]}" -b 1M \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

# ── Pass 2: the squashfs read back, against the same dpkg md5sums ─────────
# Pass 1 found the rootfs clean, so failures here come from compression,
# writing or the read-back. See pass 1 for the filter.
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
            echo -e "  ${YELLOW}Le rootfs, lui, etait conforme juste avant (passe 1). NE PAS${NC}"
            echo -e "  ${YELLOW}chercher un bug de mksquashfs : il est deterministe, il donnerait${NC}"
            echo -e "  ${YELLOW}les MEMES fichiers a chaque fois. Ce qu il compresse, ce sont les${NC}"
            echo -e "  ${YELLOW}pages que la lecture du rootfs vient de remplir - 20 Go lus a${NC}"
            echo -e "  ${YELLOW}pleine charge - et c est LA que les octets basculent. Il les${NC}"
            echo -e "  ${YELLOW}compresse fidelement ensuite. Compression a tous les coeurs = le${NC}"
            echo -e "  ${YELLOW}moment ou l hote chauffe et consomme le plus de tout le build.${NC}"
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

# ── GRUB menu ──────────────────────────────────────────────────────────────
# RAM figures shown in the menu are computed from the squashfs just written.
SQ_MB=$(( $(stat -Lc%s "$ISOROOT/live/filesystem.squashfs") / 1048576 ))
# toram copies the squashfs to a tmpfs and the system runs on top of it:
# file size plus 2 GB, rounded up to the next GB.
RAM_TORAM_GB=$(( (SQ_MB + 2048 + 1023) / 1024 ))
SQ_GB=$(awk -v m="$SQ_MB" 'BEGIN{printf "%.1f", m/1024}')

# "osmo" theme (tools/grub-theme-render.py), same as on the installed system.
# If it cannot load (missing fonts, signed GRUB without gfxterm), the
# "if loadfont" block is skipped and the menu stays in text mode.
python3 "$DIR/tools/grub-theme-render.py" --out "$ISOROOT/boot/grub/themes/osmo" >/dev/null 2>&1 \
    || echo -e "  ${YELLOW}!${NC} grub : rendu du theme echoue - menu du live en texte"

cat > "$ISOROOT/boot/grub/grub.cfg" <<GRUB
# WARNING - this file is GENERATED by build-iso.sh. Changes made in the ISO
# do not survive the next build.
#
# Under VirtualBox, two settings avoid minutes of waiting on the "RAM" entry:
# attach the ISO to the SATA controller rather than IDE, and enable
# "Use Host I/O Cache" on it.

set default=0
set timeout=5

if loadfont /boot/grub/themes/osmo/osmo-18.pf2; then
    loadfont /boot/grub/themes/osmo/osmo-24.pf2
    loadfont /boot/grub/themes/osmo/osmom-22.pf2
    set gfxmode=auto
    insmod all_video
    insmod gfxterm
    insmod png
    terminal_output gfxterm
    set theme=/boot/grub/themes/osmo/theme.txt
fi

# Three main entries (read from medium, copy to RAM, write to medium); the
# rest is in a submenu.
menuentry "osmo-operator" {
    linux  /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}

# Plain "toram" makes live-boot copy the WHOLE medium to a tmpfs
# (lib/live/boot/9990-toram-todisk.sh) with a silent "cp -a".
# "toram=filesystem.squashfs" copies only the squashfs (tmpfs sized on it),
# and "quiet" is omitted so the copy progress is visible.
menuentry "osmo-operator - en RAM (copie ${SQ_GB} Go - ${RAM_TORAM_GB} Go de RAM mini)" {
    linux  /boot/vmlinuz boot=live toram=filesystem.squashfs
    initrd /boot/initrd.img
}

# Without persistence the root is a tmpfs overlay: everything written is lost
# at reboot. No toram here, since the overlay would then stay in RAM.
#
# Requires a volume LABELLED "persistence" holding a persistence.conf with
# the line "/ union":
#   sudo mkfs.ext4 -L persistence /dev/sdX3
#   sudo mount /dev/sdX3 /mnt && echo "/ union" | sudo tee /mnt/persistence.conf
# In a VM a second disk is enough. Without such a volume this entry boots
# as a plain live system.
menuentry "osmo-operator - persistant (ecrit sur le medium)" {
    linux  /boot/vmlinuz boot=live persistence persistence-encryption=none quiet
    initrd /boot/initrd.img
}

# Verbose variants (same command lines without "quiet") are for diagnostics.
# No graphics acceleration: for GPUs the 6.8 kernel does not support (recent
# AMD RDNA without firmware, NVIDIA without nouveau) that give a black screen
# or a crash; nomodeset keeps the firmware framebuffer.
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

# ── /.disk/info: required for UEFI boot, otherwise GRUB stops at "grub>" ──
# Ubuntu's signed GRUB (gcdx64.efi.signed) has an embedded config:
#
#     if [ -z "$prefix" -o ! -e "$prefix" ]; then
#         if ! search --file --set=root /.disk/info; then
#             search --file --set=root /.disk/mini-info
#         fi
#         set prefix=($root)/boot/grub
#     fi
#     ... source $prefix/grub.cfg ... else source $cmdpath/grub.cfg
#
# Its compiled prefix "/boot/grub" has no device and resolves on the EFI
# (FAT) partition, which has no /boot/grub, so it relies on finding
# /.disk/info. BIOS boot (eltorito.img, built with -p /boot/grub) does not
# need it. Ubuntu and Debian ISOs ship the same file for the same reason.
mkdir -p "$ISOROOT/.disk"
printf 'osmo-operator %s - live amd64 (%s)\n' "$VERSION" "$LABEL" > "$ISOROOT/.disk/info"
cp "$ISOROOT/.disk/info" "$ISOROOT/.disk/mini-info"
echo -e "  ${GREEN}✓${NC} ${CYAN}/.disk/info${NC} pose : le GRUB signe retrouve le medium en UEFI"

# EFI modules where $prefix will look for them. The generated menu only uses
# commands built into the signed binary, but they make "insmod" work at the
# prompt. 3 MB.
if [ -d /usr/lib/grub/x86_64-efi ]; then
    mkdir -p "$ISOROOT/boot/grub/x86_64-efi"
    cp -a /usr/lib/grub/x86_64-efi/*.mod /usr/lib/grub/x86_64-efi/*.lst \
          "$ISOROOT/boot/grub/x86_64-efi/" 2>/dev/null || true
    # No grub.cfg in this directory: the embedded config tries
    # "$prefix/x86_64-efi/grub.cfg" BEFORE "$prefix/grub.cfg".
    rm -f "$ISOROOT/boot/grub/x86_64-efi/grub.cfg"
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
