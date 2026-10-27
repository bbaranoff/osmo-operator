#!/bin/bash
# iso_modules/82-arm-natif.sh - --arm: what the x86 build host cannot produce
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not meant to run on its own. A top-level `return` means "nothing to do here"
# (this is how --arm skips a step).

# On amd64 all of this is done elsewhere, natively (52-qemu, 71-debs-banc).
if [ "${ISO_ARCH:-amd64}" = "amd64" ]; then return 0; fi

# ═════════════════════════════════════════════════════════════════════════════
#  Step 8e: native compilation inside the arm64 chroot
# ═════════════════════════════════════════════════════════════════════════════
# The amd64 ISO builds these on the host with the host gcc: toast (GSM 06.10
# codec), the qosmo C launcher, c54x_exe/grgsm_exe, and the bench .deb packages
# (build-debs.sh compiles the launcher and inspects binaries with ldd). On an
# x86 host that would silently put x86 code into an arm64 rootfs, since none of
# these steps is fatal. Here everything runs inside the chroot under qemu-user,
# with the rootfs gcc (build-essential, step 8): the output is aarch64. Slower
# than native, but correct.
#
# Then the Pi-specific parts: the firmware partition (/boot/firmware: kernel,
# initrd, device trees, start4.elf, config.txt, cmdline.txt), kept up to date by
# hooks on each kernel update, and growing the root filesystem to the card size
# on first boot.
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

# ── Lanceur C qosmo ─────────────────────────────────────────────────────────
if [ "$ISO_ROLE" != "interstp" ]; then
    for fork in qosmo; do
        if [ -x "$ROOTFS/usr/local/bin/$fork" ]; then
            echo -e "  ${GREEN}✓${NC} lanceur $fork deja present (image)"
        elif [ -f "$ROOTFS/opt/GSM/$fork/tools/qosmo-launch/qosmo-launch.c" ]; then
            if _arm_chroot make -s -C "/opt/GSM/$fork/tools/qosmo-launch" ALIAS="$fork" "$fork" >"$WORK/launch-$fork.log" 2>&1 \
               && _arm_chroot install -Dm755 "/opt/GSM/$fork/tools/qosmo-launch/$fork" "/usr/local/bin/$fork"; then
                echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} compile dans le chroot"
            else
                echo -e "  ${YELLOW}!${NC} lanceur $fork : compilation echouee (voir $WORK/launch-$fork.log) - run.sh appellera qemu-system-arm directement" >&2
            fi
        else
            echo -e "  ${YELLOW}!${NC} lanceur $fork : pas de source dans le rootfs" >&2
        fi
    done
    # c54x_exe and grgsm_exe binaries copied from the host are x86: rebuild them
    # here from the rootfs sources.
    for _e in c54x_exe grgsm_exe; do
        [ -f "$ROOTFS/opt/GSM/$_e/Makefile" ] || continue
        if _arm_chroot make -s -B -C "/opt/GSM/$_e" >"$WORK/make-$_e.log" 2>&1; then
            echo -e "  ${GREEN}✓${NC} ${CYAN}/opt/GSM/$_e/$_e${NC} compile dans le chroot"
        else
            echo -e "  ${YELLOW}!${NC} $_e : compilation echouee (voir $WORK/make-$_e.log)" >&2
        fi
    done
    # The arm64 binary must run here under qemu-user; this catches a binary or
    # libraries of the wrong architecture.
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

# ── Bench .deb packages (step 7c), built inside the chroot ─────────────────
if [ -x "$ROOTFS/opt/GSM/osmo-operator/packaging/build-debs.sh" ]; then
    install -d "$ROOTFS/var/cache/osmo-debs"
    if _arm_chroot env OSMO_OPERATOR_SRC=/opt/GSM/osmo-operator QOSMO_SRC=/opt/GSM/qosmo \
         FIRMWARE_SRC=/opt/GSM/firmware TMPDIR=/var/tmp \
         bash /opt/GSM/osmo-operator/packaging/build-debs.sh --out /var/cache/osmo-debs \
         >"$WORK/build-debs.log" 2>&1; then
        echo -e "  ${GREEN}✓${NC} $(ls "$ROOTFS"/var/cache/osmo-debs/*.deb 2>/dev/null | wc -l) paquets dans ${CYAN}/var/cache/osmo-debs${NC}"
    else
        echo -e "  ${YELLOW}!${NC} paquets .deb du banc non construits (voir $WORK/build-debs.log) - l image sort sans eux"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
#  Pi firmware partition: /boot/firmware, populated the Armbian way
# ═════════════════════════════════════════════════════════════════════════════
# The Pi 4 boots neither via GRUB nor u-boot: its GPU reads a FAT partition
# (the first one, label RPICFG), loads start4.elf, reads config.txt, then the
# kernel and initrd it names. Armbian mounts this partition on /boot/firmware
# and keeps it up to date with three hooks from its BSP package
# (armbian-bsp-cli-rpi4b):
#   /etc/kernel/postinst.d/z51-raspi-firmware   start4.elf, fixup4.dat... from
#                                               /usr/lib/linux-firmware-raspi
#   /etc/kernel/postinst.d/zzz-copy-new-files   vmlinuz, *.dtb, overlays/
#   /etc/initramfs/post-update.d/zzz-update-initramfs   initrd.img
# The kernel is installed before the BSP in the same apt run, so these hooks
# have not run yet. Replay them here, as the Armbian build does
# (post_family_tweaks__populate_boot_firmware_directory), then run
# update-initramfs so the third hook installs the initrd. Later kernel updates
# via apt on the machine do the same automatically.
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

# config.txt and cmdline.txt: as written by Armbian for rpi4b (bcm2711.conf,
# pre_umount_final_image__write_raspi_config/cmdline), except that the serial
# console is enabled (enable_uart=1; root autologin on it is set up by
# 84-comptes) and loglevel is not forced to 1. Written once, never
# overwritten afterwards: edit freely on the card.
cat > "$ROOTFS/boot/firmware/config.txt" <<'CFG'
# osmo-operator on Armbian - Raspberry Pi 4 (arm64)
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

# Serial console (serial0 -> ttyS0), root autologin (osmo-operator)
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

# ── Armbian first-boot services ────────────────────────────────────────────
# armbian-resize-filesystem: grows the root partition to the card and runs
# resize2fs, once (handles both MBR and GPT).
# armbian-firstrun: regenerates ssh keys, hardware tweaks. The BSP postinst
# enables zram, hardware-optimize, led-state and monitor, but not these two.
# armbian-ramlog (log2ram) is disabled: it keeps /var/log in 50 MB of RAM;
# osmocom logs (logrotate 32 MB x 3) and the tcpdump pcap ring (5 x 32 MB)
# would fill it and writes would fail silently. /var/log stays on the card.
chroot "$ROOTFS" systemctl enable armbian-resize-filesystem armbian-firstrun >/dev/null 2>&1 \
    || echo -e "  ${YELLOW}!${NC} armbian-resize-filesystem / armbian-firstrun : enable a echoue" >&2
install -d "$ROOTFS/etc/default"
if [ -f "$ROOTFS/etc/default/armbian-ramlog" ] || [ -f "$ROOTFS/etc/default/armbian-ramlog.dpkg-dist" ]; then
    cp -f "$ROOTFS/etc/default/armbian-ramlog.dpkg-dist" "$ROOTFS/etc/default/armbian-ramlog" 2>/dev/null || true
    sed -i 's/^ENABLED=.*/ENABLED=false/' "$ROOTFS/etc/default/armbian-ramlog"
    chroot "$ROOTFS" systemctl disable armbian-ramlog >/dev/null 2>&1 || true
fi
# No Armbian first-login wizard: root:osmo is already set; the marker
# /root/.not_logged_in_yet only exists in Armbian images.
rm -f "$ROOTFS/root/.not_logged_in_yet"
echo -e "  ${GREEN}✓${NC} armbian-resize-filesystem et armbian-firstrun actives, armbian-ramlog coupe"

# End of module: `. file` returns the status of its last command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
