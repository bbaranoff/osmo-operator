#!/bin/bash
# osmo-dongle-install.sh - chan_dongle for the bench Asterisk (Huawei voice dongle).
#
# Builds the out-of-tree module against the INSTALLED Asterisk, installs it,
# installs configs/dongle.conf, gives Asterisk the serial ports and loads it.
#
#   sudo tools/osmo-dongle-install.sh            # build + install + load
#   sudo tools/osmo-dongle-install.sh --dongle   # same, then TRUNK_EXT=dongle
#
# Settings:
#   OSMO_CHAN_DONGLE_REPO  git repository of the module
#   OSMO_CHAN_DONGLE_REF   branch / tag / commit
# The module follows Asterisk's internal API: if the build fails on this
# Asterisk version, point OSMO_CHAN_DONGLE_REPO at a fork that supports it.
set -euo pipefail

REPO="${OSMO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC_REPO="${OSMO_CHAN_DONGLE_REPO:-https://github.com/wdoekes/asterisk-chan-dongle}"
SRC_REF="${OSMO_CHAN_DONGLE_REF:-master}"
WORK="${TMPDIR:-/tmp}/chan_dongle.$$"

[ "$(id -u)" = 0 ] || { echo "[dongle] a lancer en root" >&2; exit 1; }
command -v asterisk >/dev/null || { echo "[dongle] Asterisk absent" >&2; exit 1; }

AST_VER="$(asterisk -V | awk '{print $2}')"
echo "[dongle] Asterisk $AST_VER"

apt-get install -y --no-install-recommends \
    asterisk-dev git autoconf automake make gcc libsqlite3-dev >/dev/null

git clone --depth 1 --branch "$SRC_REF" "$SRC_REPO" "$WORK"
cd "$WORK"
[ -x ./bootstrap ] && ./bootstrap
./configure --with-astversion="$AST_VER" --with-asterisk=/usr/include
make -j"$(nproc)"

MODDIR="$(asterisk -rx 'core show settings' 2>/dev/null | awk -F': *' '/Module directory/{print $2}')"
[ -n "$MODDIR" ] || MODDIR="$(dirname "$(find /usr/lib -name chan_pjsip.so -path '*asterisk*' | head -1)")"
install -m644 chan_dongle.so "$MODDIR/"
echo "[dongle] chan_dongle.so -> $MODDIR"
cd / && rm -rf "$WORK"

# The configuration: never overwrite a dongle.conf already adapted by hand.
[ -f /etc/asterisk/dongle.conf ] || install -m640 -o asterisk -g asterisk \
    "$REPO/configs/dongle.conf" /etc/asterisk/dongle.conf

# The serial ports belong to dialout.
usermod -aG dialout asterisk 2>/dev/null || true

if asterisk -rx 'core show version' >/dev/null 2>&1; then
    asterisk -rx 'module load chan_dongle.so' || true
    asterisk -rx 'module load app_system.so' || true
    asterisk -rx 'dialplan reload' >/dev/null
    [ "${1:-}" = "--dongle" ] && asterisk -rx 'dialplan set global TRUNK_EXT dongle'
    asterisk -rx 'dongle show devices' || true
else
    echo "[dongle] Asterisk arrete : le module sera charge au prochain demarrage"
fi
echo "[dongle] SMS sortants : OSMO_DONGLE_BACKEND=asterisk tools/osmo-dongle-passerelle.py"
