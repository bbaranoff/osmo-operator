#!/bin/bash
# iso_modules/82-arm-natif.sh - --arm : ce que l hote x86 ne peut pas produire
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# Sur la cible amd64 tout ceci est fait ailleurs, nativement (52-qemu, 71-debs-banc).
if [ "${ISO_ARCH:-amd64}" = "amd64" ]; then return 0; fi

# ═════════════════════════════════════════════════════════════════════════════
#  Etape 8e : COMPILATION NATIVE DANS LE CHROOT arm64
# ═════════════════════════════════════════════════════════════════════════════
# Trois choses que l ISO amd64 fabrique SUR L HOTE avec le gcc de l hote :
# toast (codec GSM 06.10), les lanceurs C qosmo-grgsm/qosmo-dsp, et les .deb du
# banc (build-debs.sh compile le lanceur et lit les binaires par ldd). Sur un
# hote x86 ca donnerait du x86 dans un rootfs arm64 - silencieusement, puisque
# aucune de ces etapes n est fatale. Ici tout tourne DANS le chroot, sous
# qemu-user : le gcc est celui du rootfs (build-essential, pose a l etape 8),
# le resultat est de l aarch64. Plus lent qu en natif, mais juste.
#
# Puis ce que le Pi exige et que l ISO ne connait pas : la partition firmware
# (/boot/firmware : noyau, initrd, device-trees, start4.elf, config.txt,
# cmdline.txt), posee par un hook qui rejouera a chaque mise a jour du noyau,
# et l agrandissement de la racine a la carte au premier demarrage.
echo -e "${GREEN}[8e/9] Compilation native dans le chroot ${ISO_ARCH} (toast, lanceurs, .deb du banc)...${NC}"
_arm_chroot() {
    chroot "$ROOTFS" env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive "$@"
}

# ── toast ────────────────────────────────────────────────────────────────────
if [ "$ISO_ROLE" != "interstp" ]; then
    if [ -x "$ROOTFS/usr/local/bin/toast" ]; then
        echo -e "  ${GREEN}✓${NC} toast deja present (image)"
    elif _arm_chroot bash -c '
        set -e; cd /opt/GSM
        wget -qO gsm-1.0.24.tar.gz https://www.quut.com/gsm/gsm-1.0.24.tar.gz
        tar xzf gsm-1.0.24.tar.gz && rm -f gsm-1.0.24.tar.gz && cd gsm-1.0-pl24
        make >/dev/null 2>&1 || true
        [ -x bin/toast ] || make toast >/dev/null 2>&1
        for b in toast untoast tcat; do [ -e "bin/$b" ] && install -m755 "bin/$b" "/usr/local/bin/$b"; done
        [ -x /usr/local/bin/toast ]' >"$WORK/toast-arm.log" 2>&1; then
        echo -e "  ${GREEN}✓${NC} toast compile dans le chroot (sources : /opt/GSM/gsm-1.0-pl24)"
    else
        echo -e "  ${YELLOW}!${NC} toast non compile dans le chroot (voir $WORK/toast-arm.log) - on continue" >&2
    fi
fi

# ── Lanceurs C qosmo-grgsm / qosmo-dsp ──────────────────────────────────────
if [ "$ISO_ROLE" != "interstp" ]; then
    for fork in qosmo-grgsm qosmo-dsp; do
        if [ -x "$ROOTFS/usr/local/bin/$fork" ]; then
            echo -e "  ${GREEN}✓${NC} lanceur $fork deja present (image)"
        elif [ -f "$ROOTFS/opt/GSM/$fork/tools/qosmo-launch/qosmo-launch.c" ]; then
            if _arm_chroot make -s -C "/opt/GSM/$fork/tools/qosmo-launch" "$fork" >"$WORK/launch-$fork.log" 2>&1 \
               && _arm_chroot install -Dm755 "/opt/GSM/$fork/tools/qosmo-launch/$fork" "/usr/local/bin/$fork"; then
                echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} compile dans le chroot"
            else
                echo -e "  ${YELLOW}!${NC} lanceur $fork : compilation echouee (voir $WORK/launch-$fork.log) - run.sh appellera qemu-system-arm directement" >&2
            fi
        else
            echo -e "  ${YELLOW}!${NC} lanceur $fork : pas de source dans le rootfs" >&2
        fi
    done
    # Le binaire arm64 doit etre executable ici, sous qemu-user : c est le test
    # qui aurait manque a une compilation croisee silencieuse.
    if [ -x "$ROOTFS/usr/local/bin/qemu-system-arm" ]; then
        if _arm_chroot /usr/local/bin/qemu-system-arm --version >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} qemu-system-arm (aarch64) s execute dans le chroot"
        else
            echo -e "${RED}qemu-system-arm du rootfs ne s execute pas sous qemu-user : binaire ou bibliotheques d une autre architecture ?${NC}" >&2
            file "$ROOTFS/usr/local/bin/qemu-system-arm" >&2 || true
            exit 1
        fi
    fi
fi

# ── Les .deb du banc (etape 7c), fabriques dans le chroot ───────────────────
if [ -x "$ROOTFS/opt/GSM/osmo-operator/packaging/build-debs.sh" ]; then
    install -d "$ROOTFS/var/cache/osmo-debs"
    if _arm_chroot env OSMO_OPERATOR_SRC=/opt/GSM/osmo-operator QOSMO_SRC=/opt/GSM/qosmo-grgsm \
         FIRMWARE_SRC=/opt/GSM/firmware TMPDIR=/var/tmp \
         bash /opt/GSM/osmo-operator/packaging/build-debs.sh --out /var/cache/osmo-debs \
         >"$WORK/build-debs.log" 2>&1; then
        echo -e "  ${GREEN}✓${NC} $(ls "$ROOTFS"/var/cache/osmo-debs/*.deb 2>/dev/null | wc -l) paquets dans ${CYAN}/var/cache/osmo-debs${NC}"
    else
        echo -e "  ${YELLOW}!${NC} paquets .deb du banc non construits (voir $WORK/build-debs.log) - l image sort sans eux"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
#  La partition firmware du Pi : /boot/firmware
# ═════════════════════════════════════════════════════════════════════════════
# Le Pi 4 ne demarre pas par GRUB : son GPU lit une partition FAT (la premiere,
# etiquette system-boot), y charge start4.elf, lit config.txt, puis le noyau et
# l initrd designes. Ubuntu monte cette partition sur /boot/firmware et la
# tient a jour par flash-kernel ; on fait la meme chose avec UN script, appele
# ici pour peupler la partition, et rejoue par les hooks noyau/initramfs a
# chaque mise a jour d apt sur la machine. Ce qu il pose :
#   vmlinuz, initrd.img         le noyau raspi et son initramfs (/boot)
#   bcm2711-rpi-4-b.dtb ...     les device-trees (/lib/firmware/<ver>/device-tree)
#   overlays/                   les overlays (vc4-kms-v3d, uart, ...)
#   start4.elf, fixup4.dat...   le firmware GPU (linux-firmware-raspi)
#   config.txt, cmdline.txt     ecrits une fois, jamais ecrases
# kernel=vmlinuz : le firmware du Pi sait decompresser un vmlinuz gzip arm64
# (c est ainsi qu Ubuntu demarre depuis 22.04, sans u-boot).
cat > "$ROOTFS/usr/local/sbin/osmo-rpi-firmware" <<'RPIFW'
#!/bin/sh
# osmo-rpi-firmware - peuple /boot/firmware (partition FAT lue par le GPU du Pi)
# Rejoue par /etc/kernel/postinst.d et /etc/initramfs/post-update.d.
set -e
FW=/boot/firmware
K=$(ls /boot/vmlinuz-*-raspi 2>/dev/null | sort -V | tail -1 || true)
[ -n "$K" ] || { echo "osmo-rpi-firmware: aucun noyau raspi dans /boot" >&2; exit 0; }
V=${K#/boot/vmlinuz-}
mkdir -p "$FW/overlays"
cp -f "$K" "$FW/vmlinuz"
[ -f "/boot/initrd.img-$V" ] && cp -f "/boot/initrd.img-$V" "$FW/initrd.img"
DT="/lib/firmware/$V/device-tree"
if [ -d "$DT/broadcom" ]; then
    for d in "$DT"/broadcom/bcm2711-*.dtb; do [ -f "$d" ] && cp -f "$d" "$FW/"; done
fi
if [ -d "$DT/overlays" ]; then cp -f "$DT"/overlays/* "$FW/overlays/" 2>/dev/null || true; fi
for f in /usr/lib/linux-firmware-raspi/*; do [ -f "$f" ] && cp -f "$f" "$FW/"; done
if [ ! -f "$FW/config.txt" ]; then
cat > "$FW/config.txt" <<'CFG'
# osmo-operator - Raspberry Pi 4 (arm64). Ecrit a la fabrication de l image,
# jamais reecrit ensuite : modifiez librement.
[all]
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd.img followkernel
arm_64bit=1
enable_uart=1
dtparam=audio=on
disable_overscan=1
dtoverlay=vc4-kms-v3d
disable_fw_kms_setup=1
camera_auto_detect=0
display_auto_detect=1
[pi4]
max_framebuffers=2
arm_boost=1
CFG
fi
if [ ! -f "$FW/cmdline.txt" ]; then
    printf '%s\n' "console=serial0,115200 console=tty1 root=LABEL=writable rootfstype=ext4 rootwait fixrtc fsck.repair=yes cgroup_enable=memory cgroup_memory=1" > "$FW/cmdline.txt"
fi
sync
echo "osmo-rpi-firmware: $FW a jour (noyau $V)"
RPIFW
chmod 755 "$ROOTFS/usr/local/sbin/osmo-rpi-firmware"
install -d "$ROOTFS/etc/kernel/postinst.d" "$ROOTFS/etc/initramfs/post-update.d"
for _h in "$ROOTFS/etc/kernel/postinst.d/zz-osmo-rpi-firmware" "$ROOTFS/etc/initramfs/post-update.d/zz-osmo-rpi-firmware"; do
    printf '#!/bin/sh\n# osmo-operator : /boot/firmware suit le noyau (voir osmo-rpi-firmware)\nexec /usr/local/sbin/osmo-rpi-firmware\n' > "$_h"
    chmod 755 "$_h"
done
install -d "$ROOTFS/boot/firmware"
if _arm_chroot /usr/local/sbin/osmo-rpi-firmware >"$WORK/rpi-firmware.log" 2>&1 \
   && [ -f "$ROOTFS/boot/firmware/vmlinuz" ] && [ -f "$ROOTFS/boot/firmware/start4.elf" ] \
   && [ -f "$ROOTFS/boot/firmware/bcm2711-rpi-4-b.dtb" ]; then
    echo -e "  ${GREEN}✓${NC} /boot/firmware : $(ls "$ROOTFS/boot/firmware" | wc -l) entrees, noyau $(ls "$ROOTFS"/boot/vmlinuz-*-raspi | sort -V | tail -1 | sed 's|.*/vmlinuz-||')"
else
    echo -e "${RED}/boot/firmware incomplet (voir $WORK/rpi-firmware.log) : vmlinuz, start4.elf ou bcm2711-rpi-4-b.dtb manquent${NC}" >&2
    ls -la "$ROOTFS/boot/firmware" >&2 || true
    exit 1
fi

# ── La racine s etend a la carte au premier demarrage ───────────────────────
# L image fait la taille du rootfs plus une marge ; la carte fait 16, 32, 64 Go.
# growpart (cloud-guest-utils) pousse la partition 2 au bout du disque, resize2fs
# suit, une fois - le marqueur empeche de rejouer.
cat > "$ROOTFS/usr/local/sbin/osmo-grow-root" <<'GROW'
#!/bin/sh
# osmo-grow-root - agrandit la partition racine a toute la carte (une fois)
MARK=/var/lib/osmo-grow-root.done
[ -e "$MARK" ] && exit 0
src=$(findmnt -no SOURCE / 2>/dev/null) || exit 0
case "$src" in /dev/*) ;; *) exit 0 ;; esac
name=$(basename "$src")
disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
part=$(cat "/sys/class/block/$name/partition" 2>/dev/null)
[ -n "$disk" ] && [ -n "$part" ] || exit 0
out=$(growpart "/dev/$disk" "$part" 2>&1) && echo "osmo-grow-root: $out" || case "$out" in *NOCHANGE*) ;; *) echo "osmo-grow-root: $out" >&2 ;; esac
resize2fs "$src" >/dev/null 2>&1 || true
touch "$MARK"
GROW
chmod 755 "$ROOTFS/usr/local/sbin/osmo-grow-root"
cat > "$ROOTFS/etc/systemd/system/osmo-grow-root.service" <<'UNIT'
[Unit]
Description=osmo-operator : agrandit la racine a la carte SD (premier demarrage)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target
ConditionPathExists=!/var/lib/osmo-grow-root.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/osmo-grow-root
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
chroot "$ROOTFS" systemctl enable osmo-grow-root >/dev/null 2>&1 || true
echo -e "  ${GREEN}✓${NC} osmo-grow-root.service : la racine prendra toute la carte au premier boot"
