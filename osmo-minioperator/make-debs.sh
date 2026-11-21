#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# make-debs.sh - builds the qosmo and c54x_exe .debs from the osmo-minioperator
# image built from source (BUILD_DEB=1):
#
#   sudo docker build -t osmo-minioperator --build-arg BUILD_DEB=1 .
#   sudo ./make-debs.sh [directory]        # default: ./debs
#
# The packages use the paths expected by c54x_exe/run.sh
# (/opt/GSM/qosmo/build/qemu-system-arm, /opt/GSM/c54x_exe/...). The DSP
# mask ROM (TI code, not GPL) is NOT in the c54x_exe package: it is still
# downloaded and verified by rom/fetch-rom.sh when the image is built.
set -eu
IMG="${IMG:-osmo-minioperator}"
OUT="$(realpath -m "${1:-debs}")"
mkdir -p "$OUT"

docker run --rm --entrypoint bash -v "$OUT:/out" "$IMG" -c '
set -eu
[ -x /opt/GSM/qosmo/build/qemu-system-arm ] && [ -d /opt/GSM/c54x_exe/.git ] \
    || { echo "image without the sources: build it with --build-arg BUILD_DEB=1" >&2; exit 1; }
version() {   # 0.git<commit date>.<sha> (no ~: GitHub renames it in the assets)
    git -C "$1" log -1 --format="0.git%cd.%h" --date=format:%Y%m%d
}
control() {   # control <dir> <name> <version> <depends> <description>
    install -d "$1/DEBIAN"
    cat > "$1/DEBIAN/control" <<EOF
Package: $2
Version: $3
Architecture: amd64
Maintainer: Bastien Baranoff <bastienbaranoff@gmail.com>
Depends: $4
Section: misc
Priority: optional
Installed-Size: $(du -sk "$1" | cut -f1)
Description: $5
EOF
}

# ── qosmo : QEMU Calypso (ARM + layer1) ──────────────────────────────────────
Q=/opt/GSM/qosmo; V=$(version $Q); P=/tmp/qosmo_${V}_amd64
install -d $P$Q/build $P/usr/local/bin $P/usr/share/doc/qosmo
install -m755 $Q/build/qemu-system-arm $P$Q/build/
cp -a $Q/tools $P$Q/
ln -s $Q/build/qemu-system-arm $P/usr/local/bin/qemu-system-arm
install -m755 /usr/local/bin/qosmo $P/usr/local/bin/
cp $Q/COPYING $P/usr/share/doc/qosmo/copyright
echo "https://github.com/bbaranoff/qosmO commit $(git -C $Q rev-parse HEAD)" > $P/usr/share/doc/qosmo/SOURCE
control $P qosmo "$V" "libglib2.0-0t64, libpixman-1-0, libslirp0, libusb-1.0-0, zlib1g" \
    "QEMU Calypso (qosmo): phone ARM + layer1, arm-softmmu target"
dpkg-deb --root-owner-group -Zxz --build $P /out/ >/dev/null

# ── c54x_exe: TMS320C54x DSP outside QEMU ────────────────────────────────────
C=/opt/GSM/c54x_exe; V=$(version $C); P=/tmp/c54x-exe_${V}_amd64
install -d $P$C $P/usr/share/doc/c54x-exe
# Repo files (calypso_dsp.Registers.bin included: register state at reset,
# not ROM); the ROM sections written by fetch-rom.sh are left out.
git -C $C ls-files -z | tar -C $C --null -T - -cf - | tar -C $P$C -xf -
install -m755 $C/c54x_exe $P$C/
cp $C/LICENSE $P/usr/share/doc/c54x-exe/copyright
echo "https://github.com/bbaranoff/c54x_exe commit $(git -C $C rev-parse HEAD)" > $P/usr/share/doc/c54x-exe/SOURCE
control $P c54x-exe "$V" "libosmocore22, libosmogsm20, libosmocodec4, libosmocoding0, libtalloc2, python3, curl" \
    "Calypso TI C54x DSP emulator (c54x_exe), without the TI mask ROM (rom/fetch-rom.sh)"
dpkg-deb --root-owner-group -Zxz --build $P /out/ >/dev/null

# No TI ROM in the packages (Registers.bin: not ROM).
for d in /out/*.deb; do
    ! dpkg-deb -c "$d" | grep -vF Registers.bin | grep -qE "calypso_dsp[^/]*\.(bin|txt)$" || { echo "ROM in $d" >&2; exit 1; }
done
chown "'"$(id -u):$(id -g)"'" /out/*.deb
'
(cd "$OUT" && sha256sum *.deb | tee SHA256SUMS)
