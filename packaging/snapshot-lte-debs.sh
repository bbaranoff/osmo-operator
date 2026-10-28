#!/bin/bash
# =============================================================================
# snapshot-lte-debs.sh - THE BENCH 4G AND PHONE, AS .deb, FROM THE NATIVE
# INSTALL - the shortcut.
#
# Two paths lead to the same packages:
#   1. THE SHORTCUT (this script): the reference machine ALREADY has srsRAN
#      (ZeroMQ) compiled in /opt/LTE/srsRAN_4G, libzmq/czmq in /opt/LTE,
#      Open5GS in /opt/LTE/open5gs (install/ prefix), and the postmarketOS PPP
#      kernel in the session account's pmbootstrap work folder. All of it is
#      snapshotted into packages, as is (osmo-deb snapshot: nothing is
#      recompiled, nothing is reinstalled):
#          osmo-build-libzmq_4.3.5+git~noble_amd64.deb
#          osmo-build-srsgui_0.1+git~noble_amd64.deb        (before srsran: it links to it)
#          osmo-build-srsran_25.10+zmq+x86-64-v2~noble_amd64.deb  (ISA included)
#          osmo-build-open5gs_2.8.0+git~noble_amd64.deb
#          osmo-build-pmos-kernel_7.2.3.0+ppp~noble_amd64.deb   (packaging/build-pmos-kernel-deb.sh)
#      into /var/cache/osmo-debs: the ISO build (50-injection-image.sh) puts
#      them in the rootfs, and the Dockerfile (osmo-deb install) takes them
#      instead of compiling.
#   2. THE SOURCES: the Dockerfile and tools/osmo-lte-install.sh --build
#      compile srsRAN and Open5GS when the cache lacks these packages. The
#      pmOS kernel, however, is only built by osmo-pmos-build (pmbootstrap,
#      under the session account): it has NO docker path.
#
#   sudo packaging/snapshot-lte-debs.sh            everything that is there
#   sudo packaging/snapshot-lte-debs.sh --no-pmos  without the phone kernel
# =============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LTE="${OSMO_LTE_ROOT:-/opt/LTE}"
CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
OSMODEB="$REPO/packaging/osmo-deb.sh"
PMOS=1; [ "${1:-}" = "--no-pmos" ] && PMOS=0
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say() { echo -e "${CYAN}→${NC} $*"; }; ok() { echo -e "${GREEN}✓${NC} $*"; }; warn() { echo -e "${YELLOW}!${NC} $*"; }
[ "$(id -u)" -eq 0 ] || { echo "root requis" >&2; exit 1; }
export OSMO_DEB_CACHE="$CACHE"
mkdir -p "$CACHE"

# ── libzmq + czmq (compiled by hand in /opt/LTE, installed in /usr/local) ────
if [ -e /usr/local/lib/libzmq.so.5 ]; then
    say "libzmq / czmq"
    _z=( /usr/local/lib/libzmq.so* /usr/local/lib/libzmq.la /usr/local/lib/pkgconfig/libzmq.pc /usr/local/include/zmq.h /usr/local/include/zmq_utils.h )
    [ -e /usr/local/lib/libczmq.so ] && _z+=( /usr/local/lib/libczmq.so* /usr/local/lib/libczmq.la /usr/local/lib/pkgconfig/libczmq.pc /usr/local/include/czmq.h /usr/local/include/czmq_library.h /usr/local/include/czmq_prelude.h )
    [ -x /usr/local/bin/zmakecert ] && _z+=( /usr/local/bin/zmakecert )
    for d in "$LTE/libzmq" "$LTE/czmq"; do [ -d "$d" ] && _z+=( "$d" ); done
    _zv="$(git -C "$LTE/libzmq" describe --tags 2>/dev/null | sed 's/^v//; s/-.*//')"
    bash "$OSMODEB" snapshot libzmq "${_zv:-4.3.5}+git" "${_z[@]}" && ok "libzmq"
else
    warn "pas de /usr/local/lib/libzmq.so.5 : libzmq d Ubuntu (libzmq5) suffira"
fi

# ── srsGUI: the real-time plots, BEFORE srsRAN (which links to it) ───────────
# srsRAN_4G is compiled with ENABLE_GUI=ON: srsenb and srsue LINK to
# libsrsgui. A srsRAN .deb without it would give binaries that do not start
# (« libsrsgui.so: cannot open shared object file »). So it comes first, in
# this file as in the cache.
if [ -e /usr/local/lib/libsrsgui.so ] || [ -e /usr/local/lib/libsrsgui.a ]; then
    say "srsGUI (traces srsenb / srsue)"
    _g=( /usr/local/lib/libsrsgui.* )
    [ -d /usr/local/include/srsgui ] && _g+=( /usr/local/include/srsgui )
    [ -e /usr/local/lib/pkgconfig/srsgui.pc ] && _g+=( /usr/local/lib/pkgconfig/srsgui.pc )
    [ -d "$LTE/srsGUI" ] && _g+=( "$LTE/srsGUI" )
    bash "$OSMODEB" snapshot srsgui "${OSMO_SRSGUI_VER:-0.1+git}" "${_g[@]}" && ok "srsgui"
else
    warn "pas de /usr/local/lib/libsrsgui : srsGUI non empaquete (srsRAN sera sans traces)"
fi

# ── srsRAN_4G: the tree (sources + build) and what make install put in place ─
if [ -f "$LTE/srsRAN_4G/build/install_manifest.txt" ]; then
    say "srsRAN_4G (ZeroMQ)"
    mapfile -t _s < <(grep -v '^$' "$LTE/srsRAN_4G/build/install_manifest.txt" | while read -r f; do [ -e "$f" ] && echo "$f"; done)
    _sv="$(git -C "$LTE/srsRAN_4G" describe --tags 2>/dev/null | sed 's/^release_//; s/-.*//; s/_/./g')"
    # ── THE ISA GOES INTO THE VERSION, AND IT IS OBSERVED, NOT ASSUMED ──────
    # This script SNAPSHOTS already compiled binaries: nothing here says which
    # -march they were built with. A srsenb built natively on the reference
    # machine would satisfy the Dockerfile's « osmo-deb install srsran », go
    # into the image and the ISO, and raise « Illegal instruction » on the
    # operator's machine (see SRS_ARCH in tools/osmo-lte-install.sh). So what
    # the binary CONTAINS is inspected - one %ymm/%zmm instruction and it is
    # native - and stated in its name. Without objdump nothing is decided:
    # +inconnu, which can never be confused with the portable one either.
    _sisa=inconnu
    if command -v objdump >/dev/null 2>&1 && [ -x /usr/local/bin/srsenb ]; then
        if objdump -d /usr/local/bin/srsenb 2>/dev/null | grep -qE '%[yz]mm[0-9]'; then _sisa=native
        else _sisa="$(printf '%s' "${OSMO_SRSRAN_ARCH:-x86-64-v2}" | tr -c 'A-Za-z0-9.' '-')"; fi
    fi
    [ "$_sisa" = native ] && warn "srsenb porte de l AVX : paquete en +native (il ne tournera que sur CETTE machine)"
    bash "$OSMODEB" snapshot srsran "${_sv:-25.10}+zmq+${_sisa}" "$LTE/srsRAN_4G" "${_s[@]}" && ok "srsran ${_sv:-25.10}+zmq+${_sisa} (${#_s[@]} fichiers installes + l arbre)"
else
    warn "pas de $LTE/srsRAN_4G/build/install_manifest.txt : srsRAN non empaquete"
fi

# ── Open5GS : l arbre entier, prefixe install/ compris ───────────────────────
if [ -x "$LTE/open5gs/install/bin/open5gs-mmed" ]; then
    say "Open5GS ($LTE/open5gs)"
    _ov="$(git -C "$LTE/open5gs" describe --tags 2>/dev/null | sed 's/^v//; s/-.*//')"
    # The logs and the .ctxt do not travel.
    find "$LTE/open5gs/install/var/log" -type f -delete 2>/dev/null || true
    rm -f "$LTE/open5gs/.ctxt"
    bash "$OSMODEB" snapshot open5gs "${_ov:-2.8.0}+git" "$LTE/open5gs" && ok "open5gs"
else
    warn "pas de $LTE/open5gs/install/bin/open5gs-mmed : Open5GS non empaquete (il vit encore dans /root ?)"
fi

# ── The postmarketOS PPP kernel ──────────────────────────────────────────────
if [ "$PMOS" = 1 ]; then
    say "noyau postmarketOS (PPP)"
    bash "$REPO/packaging/build-pmos-kernel-deb.sh" "${OSMO_PMB_WORK:-}" || warn "noyau pmOS non empaquete (voir ci-dessus)"
fi
echo; bash "$OSMODEB" list 2>/dev/null | grep -E 'libzmq|srsgui|srsran|open5gs|pmos-kernel' || true
