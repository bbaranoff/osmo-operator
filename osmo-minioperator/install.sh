#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# install.sh - osmo-minioperator, native install (Ubuntu 24.04)
# ─────────────────────────────────────────────────────────────────────────────
# Native equivalent of the Dockerfile: same Osmocom stack (from the upstream
# .debs), same qosmo + c54x_exe builds, same firmware. Run as root on an
# ubuntu:24.04 (noble).
#
#   Osmocom network stack OBS binary repo osmocom:latest (no compilation)
#   /opt/GSM/qosmo        QEMU arm-softmmu --enable-l1-grgsm + `qosmo` launcher
#   /opt/GSM/c54x_exe     the C54x outside QEMU (linked to libosmocoding/libosmocore)
#   /opt/GSM/firmware     prebuilt binaries (github.com/bbaranoff/firmware)
#
# Idempotent: each step is skipped if its target already exists.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT=/opt/GSM
OSMO_OBS=${OSMO_OBS:-https://downloads.osmocom.org/packages/osmocom:/latest/xUbuntu_24.04}
OSMO_ASC_URL=${OSMO_ASC_URL:-https://obs.osmocom.org/projects/osmocom/public_key}
OSMOCOM_BB_REF=${OSMOCOM_BB_REF:-eac4eed1}
# Pinned commits (verified: LU + ROM voice).
QOSMO_REF=${QOSMO_REF:-9e18bf9e5574ae2d277d84de787208ed7aa7f6e2}
C54X_EXE_REF=${C54X_EXE_REF:-dadc7c73d6294dfafede78cb3774311313a7111d}
FIRMWARE_REF=${FIRMWARE_REF:-cb97f3f6a071726b52b6c7fd88f096b0d5bbfb48}
# DSP ROM 3606 dump (published by FreeCalypso): URLs tried in order
# (full URLs of the dump); the first one with the right SHA-256 wins.
ROM_MIRRORS=${ROM_MIRRORS:-https://gist.githubusercontent.com/bbaranoff/ba2746dd4fe6117475d95f791bf7df35/raw/16a4e486776315ecdf6c8972c58e877fa19785c5/calypso_dsp.txt https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env/dsp-rom-3606-dump.txt https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt}
# Verified SHA-256 of the DSP ROM 3606 dump (dsp-rom-3606-dump.txt -> calypso_dsp.txt).
CALYPSO_DSP_SHA256=${CALYPSO_DSP_SHA256:-e35798f50fd0a29aa61cd53e417c010d7f172582c7bc055211daab8af1e05470}
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
export LD_LIBRARY_PATH=/usr/local/lib

# clone_fige <url> <dir> <ref>: clone + checkout of the pinned commit. A tree already
# present is not touched (dev tree): a mismatch is only reported.
clone_fige() {
    local url="$1" dir="$2" ref="$3"
    if [ -d "$dir/.git" ]; then
        [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir" rev-parse "$ref^{commit}" 2>/dev/null)" ] \
            || echo "WARNING: $dir exists and is not at the pinned commit $ref (left as is)"
        return 0
    fi
    git clone "$url" "$dir" && git -C "$dir" checkout -q "$ref"
}

log() { echo -e "\n\033[1;36m== $* ==\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo bash install.sh)." >&2
    exit 1
fi

# ── 1. Build dependencies ────────────────────────────────────────────────────
log "apt dependencies (build qosmo + c54x_exe)"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential git gcc g++ make cmake autoconf automake libtool pkg-config \
    wget curl ca-certificates gnupg \
    python3 python3-dev python3-venv python3-pip python3-numpy python3-scipy \
    libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
    iproute2 procps psmisc util-linux

# ── 2. Osmocom binary repo + network stack (upstream .debs) ──────────────────
log "Osmocom repo (OBS) + network stack"
# Armored public key (.asc) in /usr/share/osmocom-keyring/: the
# osmocom-keyring package updates it there when it is extended.
install -d /usr/share/osmocom-keyring
curl -fsSL "${OSMO_ASC_URL}" -o /usr/share/osmocom-keyring/osmocom.asc
echo "deb [signed-by=/usr/share/osmocom-keyring/osmocom.asc] ${OSMO_OBS}/ ./" \
    > /etc/apt/sources.list.d/osmocom.list
apt-get update
# libosmocore-dev: libosmocoding.pc + libosmocore.pc to link c54x_exe.
# osmo-stp: MSC and BSC speak SS7 (M3UA) through it. telnet: HLR provisioning
# through the VTY (run-dsp.sh).
# libosmo-csn1-dev + libosmo-gprs-*-dev: required by osmocom-bb (pkg-config).
apt-get install -y --no-install-recommends \
    libosmocore-dev telnet \
    osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts osmo-pcu osmo-trx \
    osmo-sgsn osmo-ggsn osmo-sip-connector \
    libosmo-csn1-dev libosmo-gprs-rlcmac-dev libosmo-gprs-llc-dev \
    libosmo-gprs-gmm-dev libosmo-gprs-sm-dev libosmo-gprs-sndcp-dev \
    asterisk asterisk-core-sounds-en pulseaudio-utils

git config --global http.postBuffer 524288000
mkdir -p "$ROOT"

# ── 3. qosmo: QEMU arm-softmmu --enable-l1-grgsm ─────────────────────────────
log "qosmo (QEMU Calypso)"
if [ ! -x /usr/local/bin/qosmo ]; then
    clone_fige https://github.com/bbaranoff/qosmO "$ROOT/qosmo" "$QOSMO_REF"
    cd "$ROOT/qosmo"
    [ -d /root/.venv-qemu ] || python3 -m venv /root/.venv-qemu
    # shellcheck disable=SC1091
    source /root/.venv-qemu/bin/activate
    pip install --no-cache-dir tomli
    mkdir -p build && cd build
    ../configure --target-list=arm-softmmu --enable-l1-grgsm \
        --prefix="$ROOT/qemu-install" --disable-werror --disable-docs
    make -j"$(nproc)"
    make install
    cp "$ROOT/qemu-install/bin/qemu-system-arm" /usr/local/bin/qemu-system-arm
    cp "$ROOT/qemu-install/bin/qosmo" /usr/local/bin/qosmo
    deactivate || true
else
    echo "qosmo already installed, skipped."
fi

# ── 4. Calypso firmware (prebuilt) ───────────────────────────────────────────
log "Calypso firmware"
clone_fige https://github.com/bbaranoff/firmware "$ROOT/firmware" "$FIRMWARE_REF"

# ── 5. c54x_exe: the C54x outside QEMU ───────────────────────────────────────
# -march=native removed from CFLAGS (possible SIGILL if the run CPU differs).
log "c54x_exe (C54x outside QEMU)"
clone_fige https://github.com/bbaranoff/c54x_exe "$ROOT/c54x_exe" "$C54X_EXE_REF"
cd "$ROOT/c54x_exe"
make QOSMO="$ROOT/qosmo" \
    CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"
ROM_SRC="$(mktemp -d)"; ok=0
for url in $ROM_MIRRORS; do
    echo "DSP ROM: trying $url"
    curl -fsSL --retry 2 -o "$ROM_SRC/dsp-rom-3606-dump.txt" "$url" \
        && echo "$CALYPSO_DSP_SHA256  $ROM_SRC/dsp-rom-3606-dump.txt" | sha256sum -c - \
        && { ok=1; break; } || true
done
[ "$ok" = 1 ] || { echo "DSP ROM: no mirror with the expected SHA-256 ($ROM_MIRRORS) - giving up" >&2; exit 1; }
FREECALYPSO_URL="file://$ROM_SRC" bash rom/fetch-rom.sh --dest "$ROOT" --dest "$ROOT/c54x_exe/rom"
mv "$ROM_SRC/dsp-rom-3606-dump.txt" "$ROOT/calypso_dsp.txt"; rmdir "$ROM_SRC"
cp "$ROOT/calypso_dsp.txt" rom/calypso_dsp.txt

# ── 6. osmocom-bb: layer 2/3 (mobile), osmocon, trxcon ───────────────────────
# Built in src/ with `make nofirmware` (host tools, NOT the firmware). Pin
# eac4eed1: beyond it, trxcon leaves `make nofirmware`.
log "osmocom-bb (make nofirmware in src/)"
if [ ! -x "$ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" ]; then
    [ -d "$ROOT/osmocom-bb" ] || git clone https://gitea.osmocom.org/phone-side/osmocom-bb "$ROOT/osmocom-bb"
    git -C "$ROOT/osmocom-bb" checkout -q "$OSMOCOM_BB_REF"
    make -C "$ROOT/osmocom-bb/src" nofirmware
else
    echo "osmocom-bb already built, skipped."
fi
# make nofirmware installs nothing: expose `mobile` in the PATH.
ln -sf "$ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" /usr/local/bin/mobile

# ── 7. Frozen configs (single operator) -> /etc/osmocom ──────────────────────
log "Frozen configs -> /etc/osmocom"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d /etc/osmocom /var/lib/osmocom
cp "$HERE/configs/"*.cfg /etc/osmocom/
install -d /root/.osmocom/bb && cp "$HERE/configs/mobile.cfg" /root/.osmocom/bb/mobile.cfg
cp "$HERE/configs/asterisk/"*.conf /etc/asterisk/
chmod +x "$HERE/run-dsp.sh" "$HERE/start.sh" "$HERE/docker-run.sh" 2>/dev/null || true

ldconfig
log "Done. Start the operator in DSP mode: $HERE/run-dsp.sh"
