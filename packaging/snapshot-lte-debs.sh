#!/bin/bash
# =============================================================================
# snapshot-lte-debs.sh - LA 4G ET LE TELEPHONE DU BANC, EN .deb, DEPUIS LE
# NATIF - le raccourci.
#
# [2026-09-08] Deux chemins menent aux memes paquets :
#   1. LE RACCOURCI (ce script) : la machine de reference a DEJA srsRAN (ZeroMQ)
#      compile dans /opt/LTE/srsRAN_4G, libzmq/czmq dans /opt/LTE, Open5GS dans
#      /opt/LTE/open5gs (prefixe install/), et le noyau postmarketOS PPP dans
#      le dossier de travail pmbootstrap du compte de session. On photographie
#      tout cela en paquets, tels quels (osmo-deb snapshot : rien n est
#      recompile, rien n est reinstalle) :
#          osmo-build-libzmq_4.3.5+git~noble_amd64.deb
#          osmo-build-srsgui_0.1+git~noble_amd64.deb        (avant srsran : il s y lie)
#          osmo-build-srsran_25.10+zmq~noble_amd64.deb
#          osmo-build-open5gs_2.8.0+git~noble_amd64.deb
#          osmo-build-pmos-kernel_7.2.3.0+ppp~noble_amd64.deb   (packaging/build-pmos-kernel-deb.sh)
#      dans /var/cache/osmo-debs : le build ISO (50-injection-image.sh) les
#      pose dans le rootfs, et le Dockerfile (osmo-deb install) les prend au
#      lieu de compiler.
#   2. LES SOURCES : le Dockerfile et tools/osmo-lte-install.sh --build
#      compilent srsRAN et Open5GS quand le cache n a pas ces paquets. Le
#      noyau pmOS, lui, ne se construit que par osmo-pmos-build (pmbootstrap,
#      sous le compte de session) : il n a PAS de chemin docker.
#
#   sudo packaging/snapshot-lte-debs.sh            tout ce qui est la
#   sudo packaging/snapshot-lte-debs.sh --no-pmos  sans le noyau du telephone
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

# ── libzmq + czmq (compiles a la main dans /opt/LTE, installes en /usr/local) ─
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

# ── srsGUI : les traces temps reel, AVANT srsRAN (qui s y lie) ───────────────
# [2026-09-10] srsRAN_4G est desormais compile avec ENABLE_GUI=ON : srsenb et
# srsue se LIENT a libsrsgui. Un .deb de srsRAN sans celui-la donnerait des
# binaires qui ne demarrent pas (« libsrsgui.so: cannot open shared object
# file »). Il passe donc avant, dans ce fichier comme dans le cache.
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

# ── srsRAN_4G : l arbre (sources + build) et ce que make install a pose ──────
if [ -f "$LTE/srsRAN_4G/build/install_manifest.txt" ]; then
    say "srsRAN_4G (ZeroMQ)"
    mapfile -t _s < <(grep -v '^$' "$LTE/srsRAN_4G/build/install_manifest.txt" | while read -r f; do [ -e "$f" ] && echo "$f"; done)
    _sv="$(git -C "$LTE/srsRAN_4G" describe --tags 2>/dev/null | sed 's/^release_//; s/-.*//; s/_/./g')"
    bash "$OSMODEB" snapshot srsran "${_sv:-25.10}+zmq" "$LTE/srsRAN_4G" "${_s[@]}" && ok "srsran (${#_s[@]} fichiers installes + l arbre)"
else
    warn "pas de $LTE/srsRAN_4G/build/install_manifest.txt : srsRAN non empaquete"
fi

# ── Open5GS : l arbre entier, prefixe install/ compris ───────────────────────
if [ -x "$LTE/open5gs/install/bin/open5gs-mmed" ]; then
    say "Open5GS ($LTE/open5gs)"
    _ov="$(git -C "$LTE/open5gs" describe --tags 2>/dev/null | sed 's/^v//; s/-.*//')"
    # Les journaux et le .ctxt ne voyagent pas.
    find "$LTE/open5gs/install/var/log" -type f -delete 2>/dev/null || true
    rm -f "$LTE/open5gs/.ctxt"
    bash "$OSMODEB" snapshot open5gs "${_ov:-2.8.0}+git" "$LTE/open5gs" && ok "open5gs"
else
    warn "pas de $LTE/open5gs/install/bin/open5gs-mmed : Open5GS non empaquete (il vit encore dans /root ?)"
fi

# ── Le noyau postmarketOS PPP ────────────────────────────────────────────────
if [ "$PMOS" = 1 ]; then
    say "noyau postmarketOS (PPP)"
    bash "$REPO/packaging/build-pmos-kernel-deb.sh" "${OSMO_PMB_WORK:-}" || warn "noyau pmOS non empaquete (voir ci-dessus)"
fi
echo; bash "$OSMODEB" list 2>/dev/null | grep -E 'libzmq|srsgui|srsran|open5gs|pmos-kernel' || true
