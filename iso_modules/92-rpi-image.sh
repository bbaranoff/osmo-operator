#!/bin/bash
# iso_modules/92-rpi-image.sh - --arm: Raspberry Pi 4 SD card image (.img).
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment variables:
#   OSMO_RPI_BOOT_MB  size of the FAT firmware partition in MB (default 512)
#   OSMO_RPI_ROOT_MB  minimum size of the ext4 root partition in MB

# amd64: the ISO is built by 90-iso / 91-secure-boot.
if [ "${ISO_ARCH:-amd64}" != "arm64" ]; then return 0; fi

# ═════════════════════════════════════════════════════════════════════════════
#  Step 9: the SD image
# ═════════════════════════════════════════════════════════════════════════════
# Two partitions, MBR table (the Pi GPU only reads MBR):
#   1  FAT32  RPICFG        contents of /boot/firmware (kernel, dtb, start4.elf)
#   2  ext4   armbi_root    persistent rootfs (no squashfs, no live)
# Same labels, sizes (512 MB FAT) and MBR table as Armbian rpi4b images:
# armbian-resize-filesystem grows armbi_root to the card on first boot.
# Nothing is mounted: mke2fs -d populates the ext4 from the directory (owners,
# modes, links, xattrs/capabilities), mcopy fills the FAT, sfdisk writes the
# table, dd assembles. No loop device, nothing left mounted on failure.
# The ext4 is the rootfs size plus 15% plus 768 MB of headroom.
echo -e "${GREEN}[9/9] Image SD Raspberry Pi 4 (${ISO_ARCH})...${NC}"

# ── What must not be shipped ───────────────────────────────────────────────
# The emulator copied for the chroot is an x86 binary: useless on the Pi.
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
# The apt cache bind mount is already unmounted (86-finitions); what remains
# in var/cache/apt belongs to the rootfs itself.
rm -rf "$ROOTFS/var/lib/apt/lists"/* "$ROOTFS/var/cache/apt/archives"/*.deb 2>/dev/null || true

# ── Firmware partition: contents of /boot/firmware, set aside ──────────────
# In the ext4, /boot/firmware must be an EMPTY directory (FAT mount point):
# its contents are moved out and restored after the image is built.
BOOTSRC="$WORK/bootfs"
rm -rf "$BOOTSRC"; mv "$ROOTFS/boot/firmware" "$BOOTSRC"; install -d "$ROOTFS/boot/firmware"
for _f in vmlinuz initrd.img start4.elf fixup4.dat bcm2711-rpi-4-b.dtb config.txt cmdline.txt; do
    [ -f "$BOOTSRC/$_f" ] || { echo -e "${RED}/boot/firmware/$_f absent - image impossible${NC}" >&2; exit 1; }
done

# ── Sizes ──────────────────────────────────────────────────────────────────
BOOT_MB="${OSMO_RPI_BOOT_MB:-512}"
_root_kb=$(du -sxk "$ROOTFS" | cut -f1)
ROOT_MB=$(( _root_kb / 1024 * 115 / 100 + 768 ))
[ -n "${OSMO_RPI_ROOT_MB:-}" ] && [ "$OSMO_RPI_ROOT_MB" -gt "$ROOT_MB" ] && ROOT_MB="$OSMO_RPI_ROOT_MB"
echo -e "  rootfs $(( _root_kb / 1024 )) Mo -> ext4 de ${ROOT_MB} Mo, FAT de ${BOOT_MB} Mo"

# ── Partition 1: FAT32 ─────────────────────────────────────────────────────
BOOT_IMG="$WORK/boot.img"; rm -f "$BOOT_IMG"
mkfs.vfat -F 32 -n RPICFG -C "$BOOT_IMG" $(( BOOT_MB * 1024 )) >/dev/null
# mcopy -s: recursive (overlays/). "::" is the FAT root.
mcopy -s -i "$BOOT_IMG" "$BOOTSRC"/* :: \
    || { echo -e "${RED}mcopy vers la partition firmware a echoue${NC}" >&2; exit 1; }
echo -e "  ${GREEN}✓${NC} RPICFG : $(mdir -i "$BOOT_IMG" :: | tail -1 | sed 's/^ *//')"

# ── Partition 2: ext4, populated without mounting ─────────────────────────
ROOT_IMG="$WORK/root.img"; rm -f "$ROOT_IMG"
truncate -s "${ROOT_MB}M" "$ROOT_IMG"
# -d: contents; -m 1: 1% reserved for root; lazy_*=0: inode tables are
# written now, not on first mount on a slow SD card.
mke2fs -q -F -t ext4 -L armbi_root -m 1 -E lazy_itable_init=0,lazy_journal_init=0 \
    -d "$ROOTFS" "$ROOT_IMG" \
    || { echo -e "${RED}mke2fs -d a echoue : rootfs trop gros pour ${ROOT_MB} Mo ? (OSMO_RPI_ROOT_MB=... pour forcer)${NC}" >&2; exit 1; }
echo -e "  ${GREEN}✓${NC} armbi_root : ext4 ${ROOT_MB} Mo peuplee ($(e2fsck -n "$ROOT_IMG" 2>/dev/null | tail -1 | sed 's/^[^:]*: //' || true))"

# Put /boot/firmware back into the rootfs (a following pass, or a kept
# rootfs, needs it).
rm -rf "$ROOTFS/boot/firmware"; mv "$BOOTSRC" "$ROOTFS/boot/firmware"

# ── Assembly: MBR table + both partitions ─────────────────────────────────
rm -f "$OUTPUT"
_boot_start=2048
_boot_size=$(( BOOT_MB * 2048 ))
_root_start=$(( _boot_start + _boot_size ))
_root_size=$(( ROOT_MB * 2048 ))
truncate -s $(( (_root_start + _root_size + 2048) * 512 )) "$OUTPUT"
sfdisk --quiet "$OUTPUT" <<SFD
label: dos
unit: sectors
start=${_boot_start}, size=${_boot_size}, type=c, bootable
start=${_root_start}, size=${_root_size}, type=83
SFD
dd if="$BOOT_IMG" of="$OUTPUT" bs=512 seek="$_boot_start" conv=notrunc,sparse status=none
dd if="$ROOT_IMG" of="$OUTPUT" bs=512 seek="$_root_start" conv=notrunc,sparse status=none
rm -f "$BOOT_IMG" "$ROOT_IMG"
sfdisk --dump "$OUTPUT" | sed 's/^/    /' | grep -E "^ +$OUTPUT" || true
echo -e "  ${GREEN}✓${NC} image assemblee : $(du -h "$OUTPUT" | cut -f1) occupes, $(du -h --apparent-size "$OUTPUT" | cut -f1) apparents"

# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
