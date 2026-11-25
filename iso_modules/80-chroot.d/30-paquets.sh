# iso_modules/80-chroot.d/30-paquets.sh - apt-get update unique puis la grande installation (PKGS).
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# ── Single apt-get update, then apt-fast for everything else ───────────────
# Every extra source is added above so that this one update reads them all.
# apt-fast-install (/usr/local/sbin, same installer as the Dockerfile) installs
# aria2 and curl with apt-get, then downloads in parallel; it falls back to
# apt-get if GitHub is unreachable.
apt-get update -qq
/usr/local/sbin/apt-fast-install

# ── Single apt-get install ──────────────────────────────────────────────────
# One call resolves dependencies once, downloads in parallel and unpacks in a
# single order; this is the heaviest part of the chroot.
#
# It must stay right after apt-get update and before the build-dep: under set -e
# a failing build-dep must not take down the tools the ISO cannot work without:
#   nc       the whole repository queries the VTY with "nc 127.0.0.1 4239";
#            without nc the checks show an EMPTY diagnostic instead of failing.
#   socat    first-choice VTY transport of run_modules/_lib/core.sh; without it
#            21-abonnes-hlr.sh falls back to telnet, which does not exit on stdin
#            EOF, so HLR provisioning fails.
#   tcpdump  GSMTAP/M3UA captures; without it background captures fail silently.
#   git      the embedded repositories keep their .git and are updated in place.
#
# Two lists: the inter-STP hub only routes M3UA (no radio, QEMU, audio or PBX).
# ca-certificates comes first (its store is regenerated above).
#
# Kernel: on noble linux-image-generic is the 6.8 series. The vmlinuz detection
# further down (ls vmlinuz-*, sort -V, tail -1) picks the newest kernel.
# Package names depend on the suite: noble renamed the time_t ABI libraries
# (libasound2t64, libgnutls30t64, libdbi1t64, libsofia-sip-ua-glib3t64) and
# c-ares is libcares2.
#
# ── Kernel headers in the default image ─────────────────────────────────────
# linux-headers-* follows linux-image-* (the metapackage, not a fixed version),
# so headers always match the installed kernel, also after kernel updates.
# Out-of-tree modules (NVIDIA driver, SDR dongles, VirtualBox) need them for
# DKMS, which otherwise requires network access. dkms and build-essential go
# with them (build-essential is already in the arm64 list).
case "$_S" in
    noble) _KERNEL_PKG="linux-image-generic linux-headers-generic";           _T64="t64"; _CARES="libcares2" ;;
    *)     _KERNEL_PKG="linux-image-generic-hwe-22.04 linux-headers-generic-hwe-22.04"; _T64="";    _CARES="libc-ares2" ;;
esac
# ── arm64 / Raspberry Pi 4: Armbian, no live-boot ──────────────────────────
# Same packages as the Armbian rpi4b build (config/sources/families/bcm2711.conf):
# linux-image-current-bcm2711 (vmlinuz in /boot, dtb and overlays under
# /usr/lib/linux-image-<ver>), linux-dtb-current-bcm2711,
# armbian-bsp-cli-rpi4b-current (postinst.d hooks that copy kernel, dtb and
# firmware to /boot/firmware, first-boot resize, zram, motd, armbian-config),
# armbian-firmware; plus the Ubuntu Pi packages: linux-firmware-raspi
# (start4.elf, fixup4.dat, loaded by the GPU before the kernel), rpi-eeprom,
# libraspberrypi-bin (vcgencmd), raspi-config. No u-boot: the firmware loads
# vmlinuz directly (config.txt written by 82-arm-natif). build-essential and
# wget: toast and the launchers are compiled in this chroot, and osmo-update
# recompiles the launchers on the device. No live-boot: the root is an ext4 on
# the SD card mounted by the standard initramfs (root=LABEL=armbi_root).
_LIVE_PKGS="live-boot live-boot-initramfs-tools"
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    _KERNEL_PKG="linux-image-current-bcm2711 linux-headers-current-bcm2711 linux-dtb-current-bcm2711
      armbian-bsp-cli-rpi4b-current armbian-firmware
      linux-firmware-raspi rpi-eeprom libraspberrypi-bin raspi-config build-essential wget"
    _LIVE_PKGS=""
fi
# systemd-resolved is a separate package on noble, not pulled by the debootstrap
# minbase. Without it nothing answers on the 127.0.0.53 stub named in
# /etc/resolv.conf (see the DNS block of 81-cloture-systeme.sh).
#
# cryptsetup and rsync are in the BASE list: the encrypted /home disk (step 8i)
# also applies to images without a desktop (unlock-home opens the volume at
# boot, init-crypthome.sh copies the home with rsync -aHAX).
PKGS="ca-certificates openssl netcat-openbsd socat tcpdump git logrotate systemd-resolved
      $_KERNEL_PKG initramfs-tools dkms build-essential
      $_LIVE_PKGS
      libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev $_CARES
      libgnutls30${_T64} libgnutls28-dev libmnl-dev libmnl0
      libortp-dev libdbi1${_T64} libdbd-sqlite3 sqlite3
      libfftw3-single3 libusb-1.0-0
      libgsm1 libasound2${_T64}
      libsofia-sip-ua-glib3${_T64}
      liburing2 libslirp0
      iproute2 iptables net-tools lksctp-tools
      tmux telnet expect whiptail
      lsb-release openssh-server sudo
      console-setup keyboard-configuration locales
      psmisc
      cryptsetup rsync
      python3 python3-venv python3-scapy
      tshark wireshark-common
      wireguard-tools"
[ "$NODE_VIA_APT" = "1" ] && PKGS="$PKGS nodejs"

if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    # Radio, Calypso emulation, audio, PBX: operator node only.
    # gcc-9 and gcc-11 next to the noble gcc-13, as in the Docker image, to rebuild
    # osmocom-bb on the machine (jolly/testing and burst_ind need gcc-9). The
    # alternatives are set after installation, below.
    PKGS="$PKGS
      libasound2-plugins pulseaudio pulseaudio-utils alsa-utils
      binutils-arm-none-eabi gdb-multiarch
      gcc-9 g++-9 gcc-11 g++-11
      asterisk
      ffmpeg"
    # ── LTE: srsRAN (ZeroMQ) and Open5GS runtime libraries ─────────────────
    # The binaries come from the build .deb files (osmo-build-srsran,
    # osmo-build-open5gs, osmo-build-libzmq: 50-injection-image.sh); this list
    # provides their system libraries (authoritative, like the Dockerfile list).
    # The -dev packages stay: /opt/LTE is a workshop and
    # tools/osmo-lte-install.sh --build must be able to rebuild there.
    # qtbase5 / qwt / boost: srsGUI, built before srsRAN to enable its real-time
    # plots (see lte_build in tools/osmo-lte-install.sh); srsenb and srsue need them
    # at runtime once linked against srsgui.
    # mongodb-org: from the MongoDB repository added above; mongosh and the tools
    # (mongodump/mongorestore) for the subscriber database.
    PKGS="$PKGS
      libzmq5 libzmq3-dev libboost-program-options-dev libmbedtls-dev libconfig++-dev libfftw3-dev cmake
      qtbase5-dev libqt5opengl5-dev libqwt-qt5-dev libboost-system-dev libboost-thread-dev libboost-test-dev
      libpcsclite-dev
      meson ninja-build flex bison libgnutls28-dev libgcrypt20-dev libssl-dev libidn-dev
      libmongoc-dev libbson-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev
      libtins-dev libtalloc-dev libc-ares-dev
      zstd rsync kpartx"
    [ "$MONGO_VIA_APT" = "1" ] && PKGS="$PKGS mongodb-org mongodb-mongosh mongodb-database-tools"
    # kpartx: required by pmbootstrap (pmb/config/__init__.py, required_programs),
    # which refuses to start without it.

    # ── QEMU build headers: normal ISO only ────────────────────────────────
    # The normal image ships /opt/GSM/qosmo with its .git and build/ so that
    # "make -C build qemu-system-arm" can be rerun on the machine. ninja needs the
    # development .so links and headers, not just the runtimes (liburing2,
    # libslirp0, libpixman-1-0). The LITE image (Dockerfile.lite) strips the
    # toolchains, hence the ISO_LITE test.
    if [ "${ISO_LITE:-0}" != "1" ]; then
        PKGS="$PKGS
      liburing-dev libslirp-dev libpixman-1-dev"
    fi
fi

apt-fast install -y $APT_OPTS --no-install-recommends $PKGS

true
