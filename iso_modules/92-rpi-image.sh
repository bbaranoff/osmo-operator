#!/bin/bash
# iso_modules/92-rpi-image.sh - --arm : l image SD du Raspberry Pi 4 (.img)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# amd64 : l ISO est faite par 90-iso / 91-secure-boot.
if [ "${ISO_ARCH:-amd64}" != "arm64" ]; then return 0; fi

# ═════════════════════════════════════════════════════════════════════════════
#  Etape 9 : L IMAGE SD
# ═════════════════════════════════════════════════════════════════════════════
# Deux partitions, table MBR (le GPU du Pi ne lit que ca) :
#   1  FAT32  RPICFG        le contenu de /boot/firmware (noyau, dtb, start4.elf)
#   2  ext4   armbi_root    le rootfs, persistant (pas de squashfs, pas de live)
# Les memes etiquettes, tailles (FAT de 512 Mo) et table MBR que les images
# Armbian rpi4b : armbian-resize-filesystem etend armbi_root au premier boot.
# RIEN N EST MONTE : mke2fs -d peuple l ext4 depuis le repertoire (proprietaires,
# modes, liens, xattrs/capabilities compris), mcopy remplit la FAT, sfdisk ecrit
# la table, dd assemble. Pas de loop device, pas de privilege particulier au
# dela de ce que le chroot demandait deja, et rien qui reste monte si ca casse.
# L ext4 fait la taille du rootfs plus 15 % et 768 Mo de marge ; au premier
# demarrage osmo-grow-root l etend a la carte.
echo -e "${GREEN}[9/9] Image SD Raspberry Pi 4 (${ISO_ARCH})...${NC}"

# ── Ce qui ne doit pas partir ────────────────────────────────────────────────
# L emulateur copie pour le chroot est un binaire x86 : inutile sur le Pi.
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
# Le cache apt lie pendant la construction est deja demonte (86-finitions) ;
# ce qui reste dans var/cache/apt est du rootfs lui-meme.
rm -rf "$ROOTFS/var/lib/apt/lists"/* "$ROOTFS/var/cache/apt/archives"/*.deb 2>/dev/null || true

# ── La partition firmware : le contenu de /boot/firmware, mis de cote ───────
# Dans l ext4, /boot/firmware doit etre un repertoire VIDE (le point de montage
# de la FAT) : on deplace son contenu et on le remet apres l image.
BOOTSRC="$WORK/bootfs"
rm -rf "$BOOTSRC"; mv "$ROOTFS/boot/firmware" "$BOOTSRC"; install -d "$ROOTFS/boot/firmware"
for _f in vmlinuz initrd.img start4.elf fixup4.dat bcm2711-rpi-4-b.dtb config.txt cmdline.txt; do
    [ -f "$BOOTSRC/$_f" ] || { echo -e "${RED}/boot/firmware/$_f absent - image impossible${NC}" >&2; exit 1; }
done

# ── Tailles ──────────────────────────────────────────────────────────────────
BOOT_MB="${OSMO_RPI_BOOT_MB:-512}"
_root_kb=$(du -sxk "$ROOTFS" | cut -f1)
ROOT_MB=$(( _root_kb / 1024 * 115 / 100 + 768 ))
[ -n "${OSMO_RPI_ROOT_MB:-}" ] && [ "$OSMO_RPI_ROOT_MB" -gt "$ROOT_MB" ] && ROOT_MB="$OSMO_RPI_ROOT_MB"
echo -e "  rootfs $(( _root_kb / 1024 )) Mo -> ext4 de ${ROOT_MB} Mo, FAT de ${BOOT_MB} Mo"

# ── Partition 1 : FAT32 ──────────────────────────────────────────────────────
BOOT_IMG="$WORK/boot.img"; rm -f "$BOOT_IMG"
mkfs.vfat -F 32 -n RPICFG -C "$BOOT_IMG" $(( BOOT_MB * 1024 )) >/dev/null
# mcopy -s : recursif (overlays/). Le "::" est la racine de la FAT.
mcopy -s -i "$BOOT_IMG" "$BOOTSRC"/* :: \
    || { echo -e "${RED}mcopy vers la partition firmware a echoue${NC}" >&2; exit 1; }
echo -e "  ${GREEN}✓${NC} RPICFG : $(mdir -i "$BOOT_IMG" :: | tail -1 | sed 's/^ *//')"

# ── Partition 2 : ext4, peuplee sans montage ────────────────────────────────
ROOT_IMG="$WORK/root.img"; rm -f "$ROOT_IMG"
truncate -s "${ROOT_MB}M" "$ROOT_IMG"
# -d : le contenu ; -m 1 : 1 % reserve root ; lazy_*=0 : les tables d inodes
# sont ecrites maintenant, pas au premier montage sur une carte SD lente.
mke2fs -q -F -t ext4 -L armbi_root -m 1 -E lazy_itable_init=0,lazy_journal_init=0 \
    -d "$ROOTFS" "$ROOT_IMG" \
    || { echo -e "${RED}mke2fs -d a echoue : rootfs trop gros pour ${ROOT_MB} Mo ? (OSMO_RPI_ROOT_MB=... pour forcer)${NC}" >&2; exit 1; }
echo -e "  ${GREEN}✓${NC} armbi_root : ext4 ${ROOT_MB} Mo peuplee ($(e2fsck -n "$ROOT_IMG" 2>/dev/null | tail -1 | sed 's/^[^:]*: //' || true))"

# Le contenu de /boot/firmware retourne dans le rootfs (une passe suivante, ou
# un rootfs conserve, doit le retrouver).
rm -rf "$ROOTFS/boot/firmware"; mv "$BOOTSRC" "$ROOTFS/boot/firmware"

# ── Assemblage : table MBR + les deux partitions ────────────────────────────
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
