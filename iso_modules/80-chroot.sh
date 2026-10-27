#!/bin/bash
# iso_modules/80-chroot.sh - step 8: configure the rootfs inside the chroot (apt, kernel, desktop).
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not runnable on its own. A `return` at the top of a module means "nothing to do"
# (this is how --arm skips a step).
# Environment: ROOTFS, DIR, ISO_ROLE, ISO_LITE, ISO_ARCH, ISO_MIRROR, ISO_SUITE,
# ISO_DESKTOP, ISO_DEB_CACHE, NO_CACHE, OSMO_ISO_KB, OSMO_ISO_SOFTSIM, OSMO_FF_HOME.

echo -e "${GREEN}[8/9] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
# ── Persistent apt cache for the chroot ─────────────────────────────────────
# The apt/apt-fast download directory is a bind mount of the host cache
# ISO_DEB_CACHE/apt-archives, reused by every pass and later builds. It is
# unmounted before the squashfs (no .deb files in the ISO), and the chroot skips
# "apt-get clean" while it is mounted (that would empty the host cache).
# --no-cache: no bind mount.
ISO_APT_CACHE_BOUND=0
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    mkdir -p "$ISO_DEB_CACHE/apt-archives/partial" "$ROOTFS/var/cache/apt/archives"
    if mount --bind "$ISO_DEB_CACHE/apt-archives" "$ROOTFS/var/cache/apt/archives"; then
        ISO_APT_CACHE_BOUND=1
        echo -e "  ${GREEN}cache apt du chroot : $ISO_DEB_CACHE/apt-archives ($(du -sh "$ISO_DEB_CACHE/apt-archives" | cut -f1), $(find "$ISO_DEB_CACHE/apt-archives" -maxdepth 1 -name '*.deb' | wc -l) paquets)${NC}"
    fi
fi
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
# The host resolv.conf gives apt DNS during the build only; it is replaced at
# the end by 81-cloture-systeme.sh (see its DNS block).
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

# Install the apt-fast installer (same as the Dockerfile) into the rootfs.
install -m755 "$DIR/packaging/apt-fast-install.sh" "$ROOTFS/usr/local/sbin/apt-fast-install"

# The script below is single-quoted (no expansion at write time), so ISO_ROLE and
# the other settings are passed through the environment.
# LC_ALL=C.UTF-8: the host locale is not generated in the chroot and perl/debconf
# would warn "Setting locale failed" on every package. C.UTF-8 needs no locale-gen.
# NOTE: everything up to the closing quote is inside a single-quoted bash -c
# string: never put an apostrophe in it, comments included (use \047).
chroot "$ROOTFS" env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                   LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE= \
                   ISO_ROLE="$ISO_ROLE" ISO_LITE="$ISO_LITE" ISO_APT_CACHE_BOUND="$ISO_APT_CACHE_BOUND" \
                   ISO_ARCH="$ISO_ARCH" ISO_MIRROR="$ISO_MIRROR" \
                   ISO_DESKTOP="$ISO_DESKTOP" OSMO_ISO_KB="$OSMO_ISO_KB" \
                   OSMO_ISO_SOFTSIM="${OSMO_ISO_SOFTSIM:-1}" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"

# ── Fast apt/dpkg ───────────────────────────────────────────────────────────
# This rootfs is disposable (built, packed into a squashfs, then deleted), so
# the per-file fsync of dpkg is useless here and dominates build time.
# force-unsafe-io disables it, as the official Docker images do.
mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/02-unsafe-io
# Download settings (Languages=none, Retries, Pipeline-Depth, Use-Pty) are written
# by apt-fast-install below into /etc/apt/apt.conf.d/90osmo-operator, the same
# as in the Docker image and on the host.

APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

# ISO_SUITE comes from the chroot environment; the heredoc below is unquoted so
# that the variables are substituted.
_S="${ISO_SUITE:-noble}"
# The mirror follows the architecture (arm64: ports.ubuntu.com). arm64 also
# needs restricted (linux-firmware-raspi, the Pi boot firmware start4.elf).
_M="${ISO_MIRROR:-http://archive.ubuntu.com/ubuntu}"
_C="main universe multiverse"
[ "${ISO_ARCH:-amd64}" = "arm64" ] && _C="$_C restricted"
# ── Git: no forced HTTP/1.1 ─────────────────────────────────────────────────
# Remove any system-wide http.version setting. If a machine needs it, set it
# locally:  git config --global http.version HTTP/1.1
git config --system --unset http.version 2>/dev/null || true

cat > /etc/apt/sources.list <<SOURCES
deb $_M $_S           $_C
deb $_M $_S-updates    $_C
deb $_M $_S-security   $_C
SOURCES

# ── CA certificates first ───────────────────────────────────────────────────
# Installing ca-certificates is not enough: update-ca-certificates builds
# /etc/ssl/certs/ca-certificates.crt (used by OpenSSL, curl, git, apt, snap),
# and the postinst does not always run it in a chroot. Run it before the first
# TLS access (the NodeSource key below). --fresh rebuilds from the package store
# instead of whatever debootstrap left.
update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates || true

# ── arm64: Armbian repository (noble), in addition to Ubuntu ports ─────────
# The arm64 base is Armbian 24.04: bcm2711 kernel (rpi-6.18.y), device trees,
# the rpi4b BSP package (hooks keeping /boot/firmware up to date, zram, resize,
# motd) and its base-files. The repository also carries the Ubuntu Pi packages
# (linux-firmware-raspi, rpi-eeprom, libraspberrypi-bin). Written after the
# certificates (https) and before the single apt-get update, deb822 format with
# the dearmored key in /usr/share/keyrings, as Armbian does.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    curl -fsSL --retry 3 https://apt.armbian.com/armbian.key | gpg --dearmor -o /usr/share/keyrings/armbian.gpg
    cat > /etc/apt/sources.list.d/armbian.sources <<EOF
Types: deb
URIs: https://apt.armbian.com
Suites: $_S
Components: main $_S-utils $_S-desktop
Signed-By: /usr/share/keyrings/armbian.gpg
EOF
    # /boot/firmware must exist before the kernel is installed: the BSP hooks
    # (zzz-copy-new-files, zzz-update-initramfs, bash -e) copy into it without
    # creating it, and their failure would abort this whole script.
    mkdir -p /boot/firmware
    echo "depot Armbian : https://apt.armbian.com $_S"
fi

# ── deb-src: before the single apt-get update ──────────────────────────────
# The gnuradio build-dep below needs the Sources indexes. The inter-STP hub has
# no gr-gsm, so it gets neither deb-src (~80 MB of indexes) nor build-dep.
if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    sed -nE "s|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p" \
        /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list
fi

# ── NodeSource: before the single apt-get update, nodejs in PKGS ───────────
# The dashboard needs node 22, which the distribution does not ship. The
# repository is added by hand (ASCII key in /etc/apt/keyrings, read as-is by
# apt >= 2.4) so nodejs joins the single install list. If the key download
# fails, the official setup script is used as a fallback further down.
NODE_VIA_APT=0
if ! command -v node >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            -o /etc/apt/keyrings/nodesource.asc; then
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        NODE_VIA_APT=1
    else
        echo "  WARN: cle NodeSource non telechargee - repli sur setup_22.x apres l install"
        rm -f /etc/apt/keyrings/nodesource.asc
    fi
fi

# ── MongoDB (Open5GS HSS/PCRF subscriber store): before the apt update ─────
# mongodb-org is not in Ubuntu: repo.mongodb.org (noble/8.0), dearmored key in
# /usr/share/keyrings, same file as tools/osmo-lte-install.sh. Without the key
# (no network to mongodb.org) the repository is skipped and osmo-epc reports it
# on first start.
MONGO_VIA_APT=0
if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    if curl -fsSL --retry 3 https://www.mongodb.org/static/pgp/server-8.0.asc \
            | gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg 2>/dev/null; then
        echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
            > /etc/apt/sources.list.d/mongodb-org-8.0.list
        MONGO_VIA_APT=1
    else
        echo "  WARN: cle MongoDB non telechargee - Open5GS sans base d abonnes (osmo-lte-install --deps plus tard)"
        rm -f /usr/share/keyrings/mongodb-server-8.0.gpg
    fi
fi

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

# ── GCC alternatives ────────────────────────────────────────────────────────
# Same as the Docker image (gcc-9 90, gcc-11 110) plus gcc-13, the noble
# compiler, as DEFAULT (130): it built the kernel, and DKMS (NVIDIA driver via
# ubuntu-drivers, osmo-drivers) builds modules with "gcc".
#   update-alternatives --config gcc      choose (g++ follows as a slave)
#   update-alternatives --set gcc /usr/bin/gcc-9
for _v in 9 11 13; do
    [ -x "/usr/bin/gcc-$_v" ] && [ -x "/usr/bin/g++-$_v" ] || continue
    update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-$_v" "$(( _v * 10 ))" \
        --slave /usr/bin/g++ g++ "/usr/bin/g++-$_v"
done
unset _v
[ -x /usr/bin/gcc-13 ] && update-alternatives --set gcc /usr/bin/gcc-13
echo "  [chroot] alternatives gcc : $(update-alternatives --list gcc 2>/dev/null | xargs) (defaut $(readlink -f /usr/bin/gcc))"

# ── SIM: PC/SC reader (HID Omnikey), softSIM as a reader, pySim ───────────
# Same code as addition.sh --sim: tools/osmo-sim-install.sh (placed in the
# rootfs by 50-injection). Installs pcscd, libccid, pcsc-tools, opensc, pyscard,
# ruby/ruby-libxml (apt), the smartcard gem (softSIM in pcsc mode: the reader
# card served over SAP) and pySim (from git) in /opt/GSM/pysim-venv. softSIM
# itself is already installed (51-softsim.sh, host side): OSMO_SIM_SOFTSIM=0.
# Non-fatal. Skipped on the inter-STP hub (no mobile) and with --no-softsim
# (OSMO_ISO_SOFTSIM=0).
if [ "$ISO_ROLE" != "interstp" ] && [ "${OSMO_ISO_SOFTSIM:-1}" = "1" ]; then
    _SIMI=/opt/GSM/osmo-operator/tools/osmo-sim-install.sh
    if [ -f "$_SIMI" ]; then
        ( . "$_SIMI" && OSMO_SIM_SOFTSIM=0 REPO=/opt/GSM/osmo-operator osmo_sim_install ) \
            || echo "  WARN: osmo_sim_install a echoue (SIM par lecteur / pySim non poses, non fatal)"
    else
        echo "  WARN: $_SIMI absent -- pas de pcscd/pySim dans l image"
    fi
fi

# build-dep gnuradio: all GNU Radio dependencies (boost, fftw, gmp, log4cpp,
# volk...) needed by the custom gnuradio/gr-gsm in /usr/local. The Sources
# indexes are already present (deb-src.list written before apt-get update).
# The hub has no gr-gsm: no deb-src, no build-dep.
if [ -s /etc/apt/sources.list.d/deb-src.list ]; then
    apt-fast build-dep -y $APT_OPTS gnuradio || echo "WARN: apt build-dep gnuradio a echoue"
fi

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

# ── venv /root/.env: must exist and provide tomli ──────────────────────
# /root/.env is the venv activated by the bridge (grgsm_exe) and the root
# profile (.bashrc: [ -f /root/.env/bin/activate ] && source ...). It is copied
# from the image with "|| true", so it may be missing or point to an absent
# interpreter, and everything would silently fall back to the system python3.
#
# python3 -m venv WITHOUT --clear repairs: it recreates bin/ and pyvenv.cfg,
# installs pip via ensurepip and keeps site-packages. It works on the copied
# venv and on a missing directory. ensurepip needs python3-venv in PKGS.
#
# tomli: the code imports tomli (not tomllib), so it is installed explicitly.
python3 -m venv /root/.env
/root/.env/bin/python3 -m pip install -q --no-cache-dir --disable-pip-version-check tomli \
    || echo "WARN: pip a echoue pour tomli dans /root/.env"
if /root/.env/bin/python3 -c "import tomli" 2>/dev/null; then
    echo "  /root/.env : venv pret, tomli importable"
else
    echo "WARN: /root/.env sans tomli utilisable"
fi

# Docker is NOT installed in the ISO: the lab runs via start-native.sh and the
# web dashboard via native node. The host build uses the host docker only to
# extract binaries and configs.

# NodeSource fallback: only if the key could not be added before the update
# (see NODE_VIA_APT above). The official script runs its own update.
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/GSM/osmo-egprs-web/package.json ]; then
    cd /opt/GSM/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

# ── Dashboard installed at build time ───────────────────────────────────────
# install-web-service.sh (osmo-egprs-web repository) installs the node runtime,
# JS dependencies, the systemd unit, the TLS certificate and the Firefox
# policy. Running it here makes failures visible during the build;
# osmo-egprs-web-install.service at first boot is an idempotent catch-up.
#
#   WEB_NO_TLS=1   no certificate at build time: a private key generated here
#                  would be identical in every ISO. The certificate and the
#                  Firefox policy (which names the same addresses) are created
#                  on the machine at first boot with its real addresses.
#   WEB_NO_START=1 systemd does not run in a chroot; systemctl restart would
#                  fail and the script is set -eu.
if [ -x /opt/GSM/osmo-egprs-web/install-web-service.sh ]; then
    echo "  [web] install-web-service.sh (sans TLS ni demarrage : chroot)"
    WEB_NO_TLS=1 WEB_NO_START=1 bash /opt/GSM/osmo-egprs-web/install-web-service.sh \
        || echo "  [web] WARN: install-web-service.sh a echoue - le dashboard peut manquer dans l ISO"
else
    echo "  [web] WARN: install-web-service.sh absent de /opt/GSM/osmo-egprs-web"
fi

# ── DESKTOP variant: desktop, wireshark GUI, linphone ──────────────────────
# Placed after the main apt-get install (shared deps already present), before
# update-initramfs (the desktop pulls plymouth and modules for the initrd) and
# before apt-get clean.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo "  [desktop] ubuntu-desktop-minimal + wireshark + linphone-desktop"

    # WITH recommends: ubuntu-desktop-minimal puts almost everything in
    # Recommends. With --no-install-recommends it installs gnome-shell without
    # gdm3, session or terminal, giving a black screen at boot.
    #
    # linphone-desktop is the graphical client (linphone is a transition package).
    # wireshark pulls wireshark-qt. wmctrl + x11-utils (xdpyinfo): launch.sh tiles
    # the four windows into screen quarters (optional, placement only).
    #
    # One call for the desktop AND the installer (calamares, signed grub,
    # partitioning tools: see the next block). A failure stops the build: without
    # desktop or installer this image is useless.
    # snapd is not requested (the browser is a Mozilla .deb) but still comes as a
    # recommendation of ubuntu-desktop-minimal; see the snapd handling below.
    # x11-xserver-utils: xhost, used by run-as-owner (step 8i) to allow the
    # encrypted-home account on the root session X server.
    apt-fast install -y $APT_OPTS \
        ubuntu-desktop-minimal wireshark linphone-desktop \
        vlc chrome-gnome-shell \
        wmctrl x11-utils x11-xserver-utils xdotool zenity librsvg2-common \
        calamares squashfs-tools rsync dosfstools efibootmgr os-prober \
        cryptsetup cryptsetup-initramfs lvm2 pciutils ubuntu-drivers-common \
        conky-all fonts-dejavu fonts-ubuntu screenfetch python3-pil python3-gi python3-gi-cairo python3-cairo gir1.2-gtk-3.0 gir1.2-vte-2.91 \
        grub2-common grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-pc-bin \
        qml-module-qtquick2 qml-module-qtquick-layouts \
        qml-module-qtquick-window2 qml-module-qtquick-controls

    # ── Avahi: purged ───────────────────────────────────────────────────────
    # avahi comes only as a Recommends of ubuntu-desktop-minimal. On a GSM bench
    # avahi-daemon broadcasts mDNS (224.0.0.251:5353) on every interface, apn0 and
    # docker veths included, polluting GSMTAP and SIP captures; all addresses here
    # are static. --purge with libnss-mdns, and the mdns entries are removed from
    # /etc/nsswitch.conf so lookups do not query an absent service.
    apt-fast purge -y $APT_OPTS avahi-daemon avahi-utils avahi-autoipd libnss-mdns 2>/dev/null \
        || echo "  [desktop] avahi deja absent"
    apt-fast autoremove -y $APT_OPTS 2>/dev/null || true
    # Masked so that a future dependency cannot start it again.
    systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    # Double quotes only, no apostrophe (this block is inside a single-quoted
    # bash -c string, and bash -n on build-iso.sh cannot detect a stray one).
    sed -i "s/[[:space:]]*mdns4_minimal[[:space:]]*\[NOTFOUND=return\]//; s/[[:space:]]*mdns4//" \
        /etc/nsswitch.conf 2>/dev/null || true
    echo "  [desktop] avahi purge (mDNS retire du banc)"

    # ── Installer: Calamares (Ubiquity needs casper, this image uses live-boot) ──
    # Calamares is told where the squashfs is. Its configuration lives in the
    # repository (installer/calamares/) and is copied into the rootfs outside this
    # chroot (the files contain apostrophes).
    #
    # Each dependency covers a step:
    #   squashfs-tools  unpackfs, which copies the system to disk
    #   dosfstools      the FAT EFI partition
    #   efibootmgr      the UEFI boot entry
    #   os-prober       other systems, for the GRUB menu
    #   pciutils        lspci: NVIDIA card detection (osmo-install
    #   ubuntu-drivers  and contextualprocess@nvidia); ubuntu-drivers picks
    #   -common         the recommended nvidia-driver-5xx
    #   conky-all       the bench Conky dashboard (configs/conky/,
    #   python3-gi      the clickable live panel (tools/osmo-panel.py, GTK)
    #   gir1.2-gtk-3.0
    #   fonts-dejavu    GNOME autostart set below), live and installed disk
    #   python3-gi-     the c123 window (tools/osmo-c123-gtk.py): import cairo
    #   cairo (+cairo)  and Gdk.cairo_set_source_pixbuf, the emulated C123 screen
    #   lvm2            LVM in the Calamares manual partitioning (volume groups,
    #                   LUKS on LVM); its initramfs hook follows
    #   cryptsetup      LUKS: the installer encryption checkbox (partition.conf);
    #   (+ -initramfs)  cryptsetup-initramfs installs the hook that lets the target
    #                   initrd open an encrypted root
    #   qml-module-*    the slideshow during the copy
    # These packages are in the desktop apt-get install above (a failure aborts).
    # Here we also check that the binary exists, in case apt exits 0 without it.
    # We are inside the chroot: the binary is /usr/bin/calamares (no $ROOTFS here).
    if [ ! -x /usr/bin/calamares ]; then
        echo "ERREUR: calamares absent du rootfs apres apt-get - build DESKTOP interrompu." >&2
        echo "        (dependance Qt/KDE manquante au miroir ? relancer avec un cache .deb)" >&2
        exit 1
    fi

    # ── Tools Calamares calls but does not depend on ───────────────────────────
    # unpackfs runs unsquashfs and then rsync; without rsync the install fails
    # after partitioning with "error code 127" (command not found). Checked at
    # build time.
    for _t in rsync unsquashfs; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - unpackfs echouerait a l installation." >&2
            exit 1
        fi
    done

    # ── GRUB must be in the target, not only on the build host ─────────────
    # The calamares bootloader module runs grub-install INSIDE the installed
    # system (this rootfs); grub-install comes from grub2-common, not grub-common.
    # The signed binaries (shimx64, grubx64) are needed too: bootloader.conf sets
    # efiBootloaderId=ubuntu so the installed system boots with Secure Boot.
    for _t in grub-install grub-mkconfig grub-probe; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - le module bootloader echouerait." >&2
            exit 1
        fi
    done
    for _f in /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
              /usr/lib/shim/shimx64.efi.signed; do
        if [ ! -e "$_f" ]; then
            echo "ERREUR: $_f absent - le systeme installe ne demarrerait pas en Secure Boot." >&2
            exit 1
        fi
    done

    # ── Firefox: the Mozilla .deb, not the snap ────────────────────────────
    # The Ubuntu "firefox" package is a snap transition package, unusable in a
    # chroot. Mozilla publishes .deb packages (packages.mozilla.org), pinned above
    # the Ubuntu one and kept up to date by apt. The desktop file is
    # firefox.desktop and /etc/firefox/policies/policies.json is read directly.
    apt-fast purge -y firefox chromium-browser 2>/dev/null || true
    install -d -m0755 /etc/apt/keyrings
    _ff_ok=0
    if curl -fsSL --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
         -o /etc/apt/keyrings/packages.mozilla.org.asc; then
        echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
            > /etc/apt/sources.list.d/mozilla.list
        printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" \
            > /etc/apt/preferences.d/mozilla
        apt-get update -qq
        if apt-fast install -y $APT_OPTS firefox; then
            _ff_ok=1
            # The UI language follows the keyboard chosen at build time (--kb).
            apt-fast install -y $APT_OPTS "firefox-l10n-${OSMO_ISO_KB:-fr}" 2>/dev/null \
                || echo "  [desktop] firefox-l10n-${OSMO_ISO_KB:-fr} indisponible - interface en anglais"
        fi
    fi
    # ── Start page ──────────────────────────────────────────────────────────
    # Set as a DEFAULT preference (defaults/pref/), not a policy: policies.json
    # belongs to install-web-service.sh and Firefox reads only one. The operator
    # can still change it. OSMO_FF_HOME selects it at build time.
    if [ "$_ff_ok" = "1" ] && [ -d /usr/lib/firefox/defaults/pref ]; then
        cat > /usr/lib/firefox/defaults/pref/osmo-homepage.js <<FFPREF
// Pose par build-iso.sh (iso_modules/80-chroot.sh). Preference PAR DEFAUT :
// modifiable dans Firefox, remise a cette valeur sur un profil neuf.
pref("browser.startup.homepage", "${OSMO_FF_HOME:-https://pl4y.store}");
pref("browser.startup.page", 1);
FFPREF
        echo "  [desktop] Firefox : page de demarrage ${OSMO_FF_HOME:-https://pl4y.store}"
    fi
    if [ "$_ff_ok" = "1" ]; then
        echo "  [desktop] Firefox : $(dpkg-query -W -f=\${Version} firefox 2>/dev/null) (deb Mozilla, packages.mozilla.org)"
    else
        echo "  [desktop] WARN: Firefox (deb Mozilla) NON installe - packages.mozilla.org injoignable ?"
    fi
    # No snaps in the image: disable snap seeding and remove the snap install unit
    # that older images installed (it would fail at boot on a cached rootfs).
    rm -rf /var/lib/osmo-snaps
    rm -f /etc/systemd/system/osmo-firefox-snap.service \
          /etc/systemd/system/multi-user.target.wants/osmo-firefox-snap.service \
          /usr/local/sbin/osmo-firefox-snap
    # ── snapd stays usable ──────────────────────────────────────────────────
    # The image ships no snaps, but snapd remains available through SOCKET
    # activation: it starts only when someone talks to it. snapd.seeded returns
    # immediately without a seed.
    systemctl unmask snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service 2>/dev/null || true
    systemctl enable snapd.socket snapd.apparmor.service 2>/dev/null || true
    # snapd.service is not enabled: the socket starts it on demand.
    systemctl disable snapd.service 2>/dev/null || true

    systemctl set-default graphical.target

    # ── Audio: system-wide PulseAudio, also on noble ───────────────────────
    # ubuntu-desktop-minimal on noble depends on pipewire-pulse; the bench relies on
    # the SYSTEM pulseaudio daemon (/run/pulse/native, osmo-pulse.service: gsm_audio
    # sink, gapk). Installing pulseaudio removes the desktop METAPACKAGE only; the
    # desktop packages are then marked manual so autoremove keeps them.
    #
    # pulseaudio and pipewire-pulse are co-installable on noble, so pipewire-pulse
    # must be purged explicitly: otherwise it holds /run/user/<uid>/pulse/native,
    # and since wireplumber has no ALSA access (51-osmo-no-alsa.lua, the cards
    # belong to the system daemon) the session only sees "Dummy Output" and is
    # silent. This shows only for non-root users (installed disk).
    #
    # pipewire-pulse is purged, its user units masked (it may come back with a
    # desktop update) and the result verified. pipewire itself stays (GNOME
    # screencast). The session is connected to the system daemon by
    # /etc/pulse/client.conf.d and a user unit, both installed by
    # iso_modules/82-services.sh.
    if [ "$_S" = "noble" ]; then
        _auto=$(apt-mark showauto)
        apt-fast install -y $APT_OPTS pulseaudio pulseaudio-utils \
            || echo "  [desktop] WARN: apt n a pas pu remettre pulseaudio (conflit pipewire-pulse ?)"
        if [ -n "$_auto" ]; then apt-mark manual $_auto >/dev/null 2>&1 || true; fi
        # Explicit purge: installing pulseaudio does not remove it.
        apt-get purge -y pipewire-pulse pipewire-media-session >/dev/null 2>&1 || true
        systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
        # Masked in case a desktop update reinstalls pipewire-pulse: the socket
        # /run/user/<uid>/pulse/native must stay free for the link to the system daemon.
        systemctl --global mask pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true
        # wireplumber stays (GNOME screencast uses PipeWire) but must not take the
        # sound cards: they belong to the pulseaudio daemon.
        mkdir -p /etc/wireplumber/main.lua.d
        printf "alsa_monitor.enabled = false\n" > /etc/wireplumber/main.lua.d/51-osmo-no-alsa.lua
        if [ -x /usr/bin/pulseaudio ]; then
            echo "  [desktop] audio : pulseaudio systeme retabli ($(dpkg-query -W -f=\${Version} pulseaudio)), wireplumber sans ALSA"
        else
            echo "  [desktop] WARN: /usr/bin/pulseaudio toujours absent - osmo-pulse.service echouera"
        fi
        # Verify that pipewire-pulse is really gone.
        if [ -x /usr/bin/pipewire-pulse ]; then
            echo "  [desktop] WARN: pipewire-pulse TOUJOURS PRESENT - il prendra /run/user/<uid>/pulse/native et le bureau sera muet"
        else
            echo "  [desktop] audio : pipewire-pulse purge (pipewire reste pour le screencast)"
        fi
    fi

    # ── NetworkManager: enabled ────────────────────────────────────────────
    # systemd-networkd keeps the bench interfaces (apn0, packet core tun/veth);
    # NetworkManager manages the physical cards (Wi-Fi, VPN, manual switching).
    # The split is defined in /etc/NetworkManager/conf.d/10-osmo-networkd.conf,
    # written outside this chroot. Without it both would fight over the same card.
    systemctl unmask NetworkManager 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    # ── No network wait at boot ────────────────────────────────────────────
    # The wait-online units can delay boot by minutes: bench interfaces (apn0,
    # tun/veth) are never "online" in their sense and the WAN cable is often
    # unplugged. Nothing we start needs a default route first (bench units use
    # Restart=on-failure, osmo-update exits 0 offline).
    # They are MASKED (not just disabled) because third-party units (apt-daily,
    # snapd...) pull network-online.target, which then becomes immediate. This
    # also avoids an extra delay at shutdown.
    systemctl disable NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask    NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true

    # ── Autologin ──────────────────────────────────────────────────────────
    # Directly as root (there is no separate "osmocom" account). GDM refuses
    # sessions for uid 0 through PAM, not gdm3.conf:
    #     auth required pam_succeed_if.so user != root quiet_success
    # That line is commented out, otherwise no login works at all.
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin 2>/dev/null || true
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<GDM
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 forced: under VirtualBox/QEMU the GNOME Wayland session falls back to
# llvmpipe and is unusable.
WaylandEnable=false
GDM

    # ── PipeWire for the root session ──────────────────────────────────────
    # GNOME screencast (Ctrl+Alt+Shift+R) requires PipeWire, and the upstream
    # pipewire.socket/pipewire.service units carry ConditionUser=!root, so the
    # root autologin session would have no /run/user/0/pipewire-0.
    # An EMPTY assignment resets the inherited conditions (the systemd way to
    # cancel them). /etc/systemd/user/ applies to every account.
    # Known limitation: PipeWire as root is not supported upstream. On noble the
    # wireplumber ALSA monitor is disabled above (51-osmo-no-alsa.lua) so it does
    # not compete with the bench pulseaudio --system.
    for _pwu in pipewire.socket pipewire.service; do
        mkdir -p "/etc/systemd/user/${_pwu}.d"
        # Double quotes: this block is inside single quotes.
        printf "[Unit]\nConditionUser=\n" > "/etc/systemd/user/${_pwu}.d/10-allow-root.conf"
    done
    unset _pwu

    # The first-login assistant would run at EVERY boot on a non-persistent live:
    # disable it.
    rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop
    for h in /root; do
        mkdir -p "$h/.config" && echo yes > "$h/.config/gnome-initial-setup-done"
    done

    # Screen lock and suspend disabled: the bench screen stays on during captures
    # and calls, and a live session has no chosen password. The keyboard layout
    # follows --kb. printf instead of a heredoc: gschema values need apostrophes
    # (written as \047 inside this single-quoted block).
    # ── Conky arrows on the keyboard ────────────────────────────────────
    # Conky windows ignore the pointer, so the operator selection shown by Conky
    # is changed with Ctrl+AltGr+Right (next) and Ctrl+AltGr+Left (previous).
    # Ctrl+Alt+arrows stay with GNOME workspaces; AltGr is ISO_Level3_Shift,
    # <Mod5> in GTK accelerator syntax. osmo-op writes /run/osmo-fft/operator,
    # read by the panel, osmo-fft-snap.py and Conky.
    printf "[org.gnome.settings-daemon.plugins.media-keys]\ncustom-keybindings=[\047/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/\047,\047/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/\047]\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-next/]\nname=\047osmo-operator : arret suivant (Conky)\047\ncommand=\047/usr/local/bin/osmo-op --next\047\nbinding=\047<Control><Mod5>Right\047\n\n[org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/osmo-op-prev/]\nname=\047osmo-operator : arret precedent (Conky)\047\ncommand=\047/usr/local/bin/osmo-op --prev\047\nbinding=\047<Control><Mod5>Left\047\n\n" \
        > /usr/share/glib-2.0/schemas/98-osmo-keys.gschema.override

    printf "[org.gnome.desktop.session]\nidle-delay=uint32 0\n\n[org.gnome.desktop.screensaver]\nlock-enabled=false\nidle-activation-enabled=false\n\n[org.gnome.settings-daemon.plugins.power]\nsleep-inactive-ac-type=\047nothing\047\nsleep-inactive-battery-type=\047nothing\047\n\n[org.gnome.desktop.input-sources]\nsources=[(\047xkb\047,\047%s\047)]\n" \
        "${OSMO_ISO_KB:-fr}" > /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    # ── Light mode, Yaru blue ───────────────────────────────────────────
    # Blue accent (Yaru-blue icons), light color scheme by default, same as the
    # native install (install_modules/80-bureau.sh); dark mode is available in
    # Settings > Appearance. The :ubuntu sections duplicate the plain one
    # (10_ubuntu-settings.gschema.override sets gtk-theme=Yaru there and the ubuntu
    # session reads it first); :GNOME-Greeter applies the theme to the gdm screen.
    for _sec in "org.gnome.desktop.interface" "org.gnome.desktop.interface:ubuntu" "org.gnome.desktop.interface:GNOME-Greeter"; do
        printf "\n[%s]\ncolor-scheme=\047default\047\ngtk-theme=\047Yaru-blue\047\nicon-theme=\047Yaru-blue\047\ncursor-theme=\047Yaru\047\n" "$_sec" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    done
    unset _sec
    # ── GSM LAB wallpaper ───────────────────────────────────────────────
    # Set as the session DEFAULT through the schema (a user setting would not
    # survive a non-persistent live boot).
    #   gsm-lab-ville.jpg     idle wallpaper and schema default
    #   gsm-lab-antenne.jpg   same scene with the 2G/4G tower, faded in by
    #                         tools/osmo-fond.py when a 2G or 4G network starts
    #                         (osmo-launcher.py, osmo-panel.py); back to idle on stop
    #   gsm-lab-fond.jpg      low-poly landscape (tools/paysage-render.py), fallback
    #   gsm-lab-wallpaper.jpg tower illustration, also installed
    # 85-installeur-bureau.sh reinstalls the files from the local repository; the
    # schema names the wallpaper regardless. The native install
    # (install_modules/80-bureau.sh) uses the same wallpaper.
    _WP=/opt/GSM/osmo-operator/configs/gsm-lab-wallpaper.jpg
    _FOND=/opt/GSM/osmo-operator/configs/gsm-lab-fond.jpg
    _VILLE=/opt/GSM/osmo-operator/configs/gsm-lab-ville.jpg
    [ -f "$_WP" ] && install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-wallpaper.jpg
    [ -f "${_VILLE%ville.jpg}antenne.jpg" ] \
        && install -Dm644 "${_VILLE%ville.jpg}antenne.jpg" /usr/share/backgrounds/gsm-lab-antenne.jpg
    if [ -f "$_FOND" ]; then
        install -Dm644 "$_FOND" /usr/share/backgrounds/gsm-lab-fond.jpg
    elif [ -f "$_WP" ]; then
        install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-fond.jpg
    fi
    if [ -f "$_VILLE" ]; then
        install -Dm644 "$_VILLE" /usr/share/backgrounds/gsm-lab-ville.jpg
        _DEFAUT=/usr/share/backgrounds/gsm-lab-ville.jpg
    else
        _DEFAUT=/usr/share/backgrounds/gsm-lab-fond.jpg
    fi
    if [ -f "$_WP" ] || [ -f "$_FOND" ] || [ -f "$_VILLE" ]; then
        # Three sections: the plain value plus the [schema:ubuntu] and
        # [schema:GNOME-Greeter] desktop overrides from
        # 10_ubuntu-settings.gschema.override, which an ubuntu:GNOME session reads
        # first (otherwise the greeter and DING would use the Ubuntu default).
        for _sec in "org.gnome.desktop.background" "org.gnome.desktop.background:ubuntu" "org.gnome.desktop.background:GNOME-Greeter"; do
            printf "\n[%s]\npicture-uri=\047file://%s\047\npicture-uri-dark=\047file://%s\047\npicture-options=\047zoom\047\nprimary-color=\047#0d1b2a\047\n" "$_sec" "$_DEFAUT" "$_DEFAUT" \
                >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        done
        unset _sec
        # Desktop icons (DING) in the top-left corner, where the wallpaper leaves room.
        for _sec in "org.gnome.shell.extensions.ding" "org.gnome.shell.extensions.ding:ubuntu"; do
            printf "\n[%s]\nstart-corner=\047top-left\047\nshow-trash=false\nshow-volumes=false\n" "$_sec" \
                >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        done
        unset _sec
        echo "  [desktop] fond d ecran GSM LAB pose : $_DEFAUT"
    else
        echo "  [desktop] WARN: $_WP absent -- fond d ecran GNOME par defaut"
    fi
    # ── Dock: bench favorites ───────────────────────────────────────────
    # Set as the schema DEFAULT (non-persistent live) and also in
    # [org.gnome.shell:ubuntu], which 10_ubuntu-settings fills with the Ubuntu list
    # and the ubuntu:GNOME session reads first.
    # Entries pointing to a missing .desktop are silently ignored by GNOME Shell,
    # so deka.desktop and claude.desktop may be listed even when not installed
    # (deka comes from addition.sh). firefox.desktop is the Mozilla .deb one;
    # osmo-pmos.desktop (postmarketOS/Phosh VM) comes from
    # tools/osmo-extras-install.sh.
    for _sec in "org.gnome.shell" "org.gnome.shell:ubuntu"; do
        printf "\n[%s]\nfavorite-apps=[\047osmo-info.desktop\047, \047firefox.desktop\047, \047org.gnome.Nautilus.desktop\047, \047claude.desktop\047, \047osmo-launch.desktop\047, \047osmo-install.desktop\047, \047osmo-tutorial.desktop\047, \047osmo-addition.desktop\047, \047osmo-multi.desktop\047, \047osmo-update.desktop\047, \047osmo-paint.desktop\047, \047deka.desktop\047, \047linphone.desktop\047, \047osmo-wireshark-root.desktop\047, \047osmo-pmos.desktop\047, \047osmo-lte.desktop\047]\n" "$_sec" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    done
    unset _sec
    echo "  [desktop] favoris du dock poses (14 entrees)"

    # ── Extras (media, tools) in the native image ───────────────────────
    # Same set and code as addition.sh (tools/osmo-extras-install.sh): Kodi,
    # YouTube + uBlock, Wireshark (root), Linphone, grouped in Games / Media /
    # Phone / Tools folders. Non-fatal. Runs as root in the chroot with the
    # repository at /opt/GSM/osmo-operator.
    _EXTRAS=/opt/GSM/osmo-operator/tools/osmo-extras-install.sh
    if [ -f "$_EXTRAS" ]; then
        echo "  [desktop] jeux + media (natif) : $_EXTRAS"
        # Games (Doom/Quake III, ~470 MB) are excluded: they are installed only by
        # addition.sh --extras on an installed machine.
        OSMO_EXTRAS_JEUX=0 REPO=/opt/GSM/osmo-operator . "$_EXTRAS" && OSMO_EXTRAS_JEUX=0 osmo_extras_install || \
            echo "  [desktop] WARN: osmo_extras_install a echoue (non fatal)"
    else
        echo "  [desktop] WARN: $_EXTRAS absent -- pas de jeux/media dans l image"
    fi

    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true

    echo "  [desktop] GNOME pret : autologin root, X11, NetworkManager actif, Firefox deb Mozilla"
fi

# ── CA certificates: final check ────────────────────────────────────────────
# The store was regenerated at the start of this chroot; just check it is
# not empty.
if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
    echo "  certificats : $(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt) autorites dans /etc/ssl/certs"
else
    echo "  WARN: /etc/ssl/certs/ca-certificates.crt vide - le TLS echouera dans l image"
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

# Remove deb-src.list: its Sources indexes (~80 MB) were only needed for the
# gnuradio build-dep and would be loaded into RAM by the first apt-get update
# on a toram live. No "apt-get clean" when /var/cache/apt/archives is the
# bind-mounted host cache: only indexes and binary caches are removed.
if [ "${ISO_APT_CACHE_BOUND:-0}" = "1" ]; then
    rm -f /var/cache/apt/*.bin; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
else
    apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
fi
rm -f /etc/apt/sources.list.d/deb-src.list
'


# End of module: sourcing returns the status of the LAST command and
# build-iso.sh runs under set -e, so always end with a true status.
true
