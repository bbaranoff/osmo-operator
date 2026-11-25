# iso_modules/80-chroot.d/10-apt-base.sh - base apt : dpkg rapide, debconf, sources Ubuntu, certificats, Armbian, deb-src.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

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

true
