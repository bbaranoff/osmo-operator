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
        LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE= DEBIAN_FRONTEND=noninteractive "$@"
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
#  La partition firmware du Pi : /boot/firmware, comme Armbian la peuple
# ═════════════════════════════════════════════════════════════════════════════
# Le Pi 4 ne demarre pas par GRUB ni par u-boot : son GPU lit une partition FAT
# (la premiere, etiquette RPICFG), y charge start4.elf, lit config.txt, puis le
# noyau et l initrd designes. Armbian monte cette partition sur /boot/firmware
# et la tient a jour par trois hooks de son paquet BSP (armbian-bsp-cli-rpi4b) :
#   /etc/kernel/postinst.d/z51-raspi-firmware   start4.elf, fixup4.dat... depuis
#                                               /usr/lib/linux-firmware-raspi
#   /etc/kernel/postinst.d/zzz-copy-new-files   vmlinuz, *.dtb, overlays/
#   /etc/initramfs/post-update.d/zzz-update-initramfs   initrd.img
# Le noyau s installe AVANT le BSP dans un meme apt : ses hooks n ont pas
# tourne. On les rejoue ici, comme le fait le build Armbian lui-meme
# (post_family_tweaks__populate_boot_firmware_directory), puis update-initramfs
# pour que l initrd parte par le troisieme hook. Toute mise a jour du noyau
# par apt sur la machine refera la meme chose, sans nous.
_KVER="$(ls "$ROOTFS"/boot/vmlinuz-*-bcm2711 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||' || true)"
[ -n "$_KVER" ] || { echo -e "${RED}aucun noyau Armbian bcm2711 dans /boot du rootfs (linux-image-current-bcm2711 non installe ?)${NC}" >&2; exit 1; }
install -d "$ROOTFS/boot/firmware"
for _h in /etc/kernel/postinst.d/z51-raspi-firmware /etc/kernel/postinst.d/zzz-copy-new-files; do
    [ -x "$ROOTFS$_h" ] || { echo -e "${RED}hook Armbian absent : $_h (armbian-bsp-cli-rpi4b-current non installe ?)${NC}" >&2; exit 1; }
    _arm_chroot "$_h" "$_KVER" >>"$WORK/rpi-firmware.log" 2>&1 \
        || { echo -e "${RED}$_h a echoue (voir $WORK/rpi-firmware.log)${NC}" >&2; tail -5 "$WORK/rpi-firmware.log" >&2; exit 1; }
done
_arm_chroot update-initramfs -u -k "$_KVER" >>"$WORK/rpi-firmware.log" 2>&1 \
    || { echo -e "${RED}update-initramfs -k $_KVER a echoue (voir $WORK/rpi-firmware.log)${NC}" >&2; exit 1; }
[ -f "$ROOTFS/boot/firmware/initrd.img" ] || cp -f "$ROOTFS/boot/initrd.img-$_KVER" "$ROOTFS/boot/firmware/initrd.img"

# config.txt et cmdline.txt : ceux qu Armbian ecrit pour rpi4b (bcm2711.conf,
# pre_umount_final_image__write_raspi_config/cmdline), a deux details pres :
# la console serie est activee (enable_uart=1 : un banc a souvent un cable
# serie, et l autologin root y est pose par 84-comptes), et loglevel n est pas
# force a 1 - on veut lire ce que dit le noyau. Ecrits une fois, jamais
# reecrits ensuite : modifiez librement sur la carte.
cat > "$ROOTFS/boot/firmware/config.txt" <<'CFG'
# osmo-operator sur Armbian - Raspberry Pi 4 (arm64)
# For more options and information see http://rptl.io/configtxt

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Additional overlays and parameters are documented /boot/firmware/overlays/README

# Automatically load overlays for detected cameras / DSI displays
camera_auto_detect=1
display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
disable_fw_kms_setup=1

# Disable compensation for displays with overscan
disable_overscan=1

# Run as fast as firmware / board allows
arm_boost=1

# Console serie (serial0 -> ttyS0), autologin root (osmo-operator)
enable_uart=1

[cm4]
otg_mode=1

[all]
kernel=vmlinuz
initramfs initrd.img followkernel
arm_64bit=1
CFG
printf '%s\n' "console=serial0,115200 console=tty1 root=LABEL=armbi_root rootfstype=ext4 fsck.repair=yes rootwait logo.nologo cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" \
    > "$ROOTFS/boot/firmware/cmdline.txt"

for _f in vmlinuz initrd.img start4.elf fixup4.dat bcm2711-rpi-4-b.dtb config.txt cmdline.txt overlays/vc4-kms-v3d.dtbo; do
    [ -e "$ROOTFS/boot/firmware/$_f" ] || { echo -e "${RED}/boot/firmware/$_f absent apres les hooks Armbian (voir $WORK/rpi-firmware.log)${NC}" >&2; ls -la "$ROOTFS/boot/firmware" >&2; exit 1; }
done
echo -e "  ${GREEN}✓${NC} /boot/firmware : noyau ${CYAN}${_KVER}${NC}, $(ls "$ROOTFS/boot/firmware" | wc -l) entrees ($(du -sh "$ROOTFS/boot/firmware" | cut -f1))"

# ── Les services Armbian du premier demarrage ───────────────────────────────
# armbian-resize-filesystem : etend la partition racine a la carte et
# resize2fs, une fois (c est lui, pas nous, qui sait le faire sur MBR ET GPT).
# armbian-firstrun : cles ssh regenerees, reglages materiels. Le BSP enable
# zram, hardware-optimize, led-state, monitor par son postinst ; ces deux-la
# non (le build Armbian le fait a la fabrication de l image, comme ici).
# armbian-ramlog (log2ram) : COUPE. Il tient /var/log dans 50 Mo de RAM et
# synchronise sur la carte : les journaux osmocom (logrotate a 32 Mo x 3), les
# pcap en anneau du tcpdump enveloppe (5 x 32 Mo) le rempliraient en une heure
# et les ecritures echoueraient sans un mot. Sur un banc, /var/log sur la carte.
chroot "$ROOTFS" systemctl enable armbian-resize-filesystem armbian-firstrun >/dev/null 2>&1 \
    || echo -e "  ${YELLOW}!${NC} armbian-resize-filesystem / armbian-firstrun : enable a echoue" >&2
install -d "$ROOTFS/etc/default"
if [ -f "$ROOTFS/etc/default/armbian-ramlog" ] || [ -f "$ROOTFS/etc/default/armbian-ramlog.dpkg-dist" ]; then
    cp -f "$ROOTFS/etc/default/armbian-ramlog.dpkg-dist" "$ROOTFS/etc/default/armbian-ramlog" 2>/dev/null || true
    sed -i 's/^ENABLED=.*/ENABLED=false/' "$ROOTFS/etc/default/armbian-ramlog"
    chroot "$ROOTFS" systemctl disable armbian-ramlog >/dev/null 2>&1 || true
fi
# Pas d assistant Armbian au premier login : root:osmo est deja pose, le
# marqueur /root/.not_logged_in_yet n existe que dans les images Armbian.
rm -f "$ROOTFS/root/.not_logged_in_yet"
echo -e "  ${GREEN}✓${NC} armbian-resize-filesystem et armbian-firstrun actives, armbian-ramlog coupe"

# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
