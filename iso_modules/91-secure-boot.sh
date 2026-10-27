#!/bin/bash
# iso_modules/91-secure-boot.sh - Secure Boot ISO (signed shim + grub), or
# grub-mkrescue fallback.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Host requirements for Secure Boot: shim-signed, grub-efi-amd64-signed,
# mtools, dosfstools (sbsigntool optional, to verify the kernel signature).

# --arm: no shim or xorriso on the Pi.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ══════════════════════════════════════════════════════════════════════════════
# SECURE BOOT - why this step does not use grub-mkrescue
# ══════════════════════════════════════════════════════════════════════════════
# grub-mkrescue builds an unsigned BOOTX64.EFI from host modules, which the
# firmware refuses to load when Secure Boot is enabled.
#
# Chain of trust:
#
#   firmware --(Microsoft key)--> shimx64.efi.signed   package shim-signed
#            --(Canonical key)--> gcdx64.efi.signed    package grub-efi-amd64-signed
#            --(Canonical key)--> vmlinuz              linux-image-generic (signed)
#
# shim is the only Microsoft-signed link; it carries the Canonical key. It is
# copied from the package, not built.
#
# gcdx64, not grubx64: both are Canonical-signed but their compiled prefix
# differs:
#     grubx64.efi.signed  -> prefix /EFI/ubuntu, looks for its config on the
#                            EFI partition (absent on an ISO: bare "grub>").
#     gcdx64.efi.signed   -> prefix /boot/grub relative to the boot medium
#                            (optical variant), finds $ISOROOT/boot/grub/grub.cfg.
# A stub /EFI/ubuntu/grub.cfg is still put on the ESP for the grubx64 fallback.
#
# Nothing is signed here: no private key, nothing to enrol (no MokManager on
# first boot). Only binaries already signed by Microsoft and Canonical are
# assembled, like an official Ubuntu ISO.
#
# BIOS boot: the El Torito i386-pc image is built by grub-mkimage
# (i386-pc-eltorito, includes cdboot.img) and the hybrid MBR by --grub2-mbr.
#
# Fallback: if a component is missing on the host, grub-mkrescue builds an
# ISO that boots everywhere EXCEPT with Secure Boot, and this is reported.

SB_SHIM=""
for c in /usr/lib/shim/shimx64.efi.signed \
         /usr/lib/shim/shimx64.efi.signed.latest \
         /usr/lib/shim/shimx64.efi; do
    [ -f "$c" ] && { SB_SHIM="$c"; break; }
done
# gcdx64 first (prefix /boot/grub, for optical media), grubx64 as fallback.
SB_GRUB="" ; SB_GRUB_KIND=""
for c in /usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed:gcd \
         /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed:grub; do
    [ -f "${c%:*}" ] && { SB_GRUB="${c%:*}"; SB_GRUB_KIND="${c##*:}"; break; }
done
SB_MM=""
for c in /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi; do
    [ -f "$c" ] && { SB_MM="$c"; break; }
done

# The kernel must be signed too: shim validates GRUB, GRUB validates the
# kernel. An unsigned vmlinuz fails AFTER the menu. Ubuntu "generic" kernels
# are signed; the signature is checked rather than trusting the package name.
SB_KERNEL_SIGNED=0
if command -v sbverify &>/dev/null; then
    sbverify --list "$ISOROOT/boot/vmlinuz" &>/dev/null && SB_KERNEL_SIGNED=1
elif grep -qa '~Module signature appended~\|sbat\|Canonical Ltd\. Secure Boot' "$ISOROOT/boot/vmlinuz" 2>/dev/null; then
    SB_KERNEL_SIGNED=1
fi

SECURE_BOOT_OK=0
if [ -n "$SB_SHIM" ] && [ -n "$SB_GRUB" ] && command -v mmd &>/dev/null; then
    echo -e "${GREEN}[9/9] ISO Secure Boot (shim + grub signes)...${NC}"
    echo -e "  shim : ${CYAN}${SB_SHIM}${NC}"
    echo -e "  grub : ${CYAN}${SB_GRUB}${NC} (${SB_GRUB_KIND})"

    # ── EFI system partition ──────────────────────────────────────────────────
    # FAT16 with a 16 MB floor: the content is ~4 MB, but FAT16 needs at least
    # 4085 clusters or mkfs.vfat fails. 16 MB with 2 KB clusters (-s 4) gives
    # 8192 clusters.
    SB_ESP="$WORK/efi.img"
    SB_KB=$(( ( $(stat -Lc%s "$SB_SHIM") + $(stat -Lc%s "$SB_GRUB") \
              + $( [ -n "$SB_MM" ] && stat -Lc%s "$SB_MM" || echo 0 ) ) / 1024 + 2048 ))
    [ "$SB_KB" -lt 16384 ] && SB_KB=16384
    rm -f "$SB_ESP"
    mkfs.vfat -F 16 -s 4 -n OSMOEFI -C "$SB_ESP" "$SB_KB" >/dev/null

    mmd   -i "$SB_ESP" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
    mcopy -i "$SB_ESP" "$SB_SHIM" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$SB_ESP" "$SB_GRUB" ::/EFI/BOOT/grubx64.efi
    [ -n "$SB_MM" ] && mcopy -i "$SB_ESP" "$SB_MM" ::/EFI/BOOT/mmx64.efi

    # Stub: last resort of the config embedded in gcdx64, which ends with
    # "source $cmdpath/grub.cfg" ($cmdpath = /EFI/BOOT on this ESP). Also used
    # as-is by the grubx64 fallback (prefix /EFI/ubuntu).
    #
    # "search --set=root" leaves the variable unchanged on failure, so a fresh
    # variable is used to test the result, and a message is printed if nothing
    # is found.
    cat > "$WORK/esp-grub.cfg" <<'ESPCFG'
search --no-floppy --file --set=osmodev /.disk/info
if [ -z "$osmodev" ]; then
    search --no-floppy --file --set=osmodev /boot/grub/grub.cfg
fi
if [ -n "$osmodev" ]; then
    set root=$osmodev
    set prefix=($osmodev)/boot/grub
    configfile ($osmodev)/boot/grub/grub.cfg
fi
echo "GRUB : ni /.disk/info ni /boot/grub/grub.cfg trouves sur les disques vus."
echo "Le medium n'est probablement pas lisible par le firmware a ce stade."
ESPCFG
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/ubuntu/grub.cfg
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/BOOT/grub.cfg

    # ── Same tree in the ISO9660 filesystem ───────────────────────────────────
    # The appended ESP is enough for DVDs and image-mode writes (dd, Rufus DD).
    # Copying the ISO contents onto a FAT-formatted key (common on Windows) only
    # sees the ISO9660, which also needs /EFI/BOOT (xorriso warns otherwise).
    # Ubuntu ISOs do the same.
    mkdir -p "$ISOROOT/EFI/BOOT"
    cp "$SB_SHIM" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"
    cp "$SB_GRUB" "$ISOROOT/EFI/BOOT/grubx64.efi"
    [ -n "$SB_MM" ] && cp "$SB_MM" "$ISOROOT/EFI/BOOT/mmx64.efi"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/BOOT/grub.cfg"
    mkdir -p "$ISOROOT/EFI/ubuntu"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/ubuntu/grub.cfg"

    # ── BIOS boot image, built here since grub-mkrescue is not used ───────────
    # i386-pc-eltorito already includes cdboot.img: usable directly as
    # -eltorito-boot.
    SB_BIOS="$WORK/eltorito.img"
    grub-mkimage -O i386-pc-eltorito -p /boot/grub -o "$SB_BIOS" \
        biosdisk iso9660 part_msdos part_gpt fat ext2 normal linux configfile \
        search search_label search_fs_uuid search_fs_file loopback gzio \
        all_video gfxterm videotest videoinfo test echo ls minicmd sleep \
        halt reboot chain 2>/dev/null

    if [ -s "$SB_BIOS" ]; then
        # -eltorito-alt-boot separates the two catalog entries (BIOS, then UEFI).
        # "--interval:appended_partition_2" refers to the partition appended below,
        # without storing it twice in the image.
        xorriso -as mkisofs -iso-level 3 \
            -volid "$LABEL" \
            -full-iso9660-filenames \
            -eltorito-boot boot/grub/eltorito.img \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                --eltorito-catalog boot/grub/boot.cat \
                --grub2-boot-info \
                --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
            -eltorito-alt-boot \
                -e --interval:appended_partition_2:all:: \
                -no-emul-boot \
            -append_partition 2 0xef "$SB_ESP" \
            -appended_part_as_gpt \
            -o "$OUTPUT" \
            -graft-points "$ISOROOT" "/boot/grub/eltorito.img=$SB_BIOS" \
            && SECURE_BOOT_OK=1
    fi

    if [ "$SECURE_BOOT_OK" = "1" ]; then
        if [ "$SB_KERNEL_SIGNED" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ISO signee Secure Boot : shim -> grub -> noyau, chaine complete"
        else
            echo -e "  ${YELLOW}⚠${NC}  shim et grub sont signes, mais la signature du NOYAU n'a pas"
            echo -e "     pu etre confirmee ($ISOROOT/boot/vmlinuz). Si le boot s'arrete APRES"
            echo -e "     le menu GRUB, c'est la : installez sbsigntool pour le verifier, ou"
            echo -e "     utilisez un noyau linux-image-generic non recompile."
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}  assemblage Secure Boot echoue - repli sur grub-mkrescue"
    fi
else
    echo -e "${YELLOW}[9/9] Secure Boot indisponible sur cet hote :${NC}"
    [ -z "$SB_SHIM" ] && echo -e "     shim absent  -> apt install ${CYAN}shim-signed${NC}"
    [ -z "$SB_GRUB" ] && echo -e "     grub signe absent -> apt install ${CYAN}grub-efi-amd64-signed${NC}"
    command -v mmd &>/dev/null || echo -e "     mtools absent -> apt install ${CYAN}mtools dosfstools${NC}"
fi

if [ "$SECURE_BOOT_OK" != "1" ]; then
# Fallback: ISO that boots in BIOS and UEFI without Secure Boot.
#
# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

    grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
        --product-name "osmo-operator $VERSION" -- -volid "$LABEL"
    if command -v isohybrid &>/dev/null; then
        isohybrid --uefi "$OUTPUT"
    fi
    echo -e "  ${YELLOW}!${NC} ISO NON signee : elle ne demarrera pas si Secure Boot est actif."
    echo -e "    Desactivez-le dans le firmware, ou construisez sur un hote qui a"
    echo -e "    ${CYAN}shim-signed${NC} et ${CYAN}grub-efi-amd64-signed${NC}."
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Creation de l'ISO echouee - rien n'a ete ecrit${NC}"
    exit 1
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
