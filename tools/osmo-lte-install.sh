#!/bin/bash
# =============================================================================
# osmo-lte-install.sh - THE BENCH 4G, INSTALLED ONCE FOR THE THREE PATHS.
#
# This script is the SINGLE place where the 4G (srsRAN over ZeroMQ, Open5GS)
# is installed; the three paths call it:
#   - addition.sh            (an already installed machine)     : --all
#   - update.sh              (the catch-up)                      : --configs --launchers
#   - iso_modules/72-lte-pmos.sh (the ISO build, in chroot)   : --deps --configs --launchers
#     (the binaries there come from the docker build .deb files:
#      osmo-build-srsran, osmo-build-open5gs, laid down by 50-injection-image.sh)
#
# WHERE THINGS LIVE:
#   /opt/LTE/srsGUI             srsGUI (Qt5 + Qwt): the real-time plots of
#                               srsenb / srsue. BUILT BEFORE srsRAN - its cmake
#                               looks for it at configure time - and installed
#                               in /usr/local/lib/libsrsgui
#   /opt/LTE/srsRAN_4G          srsRAN sources and build (ZeroMQ, GUI),
#                               binaries in /usr/local/bin (srsenb, srsue, srsepc)
#   /opt/LTE/open5gs            Open5GS sources; install prefix
#                               /opt/LTE/open5gs/install (bin, etc/open5gs, var/log)
#   /root/.config/srsran        enb.conf ue.conf sib.conf rr.conf rb.conf user_db.csv
#                               = the repo's configs/srsran (srs* read root's HOME)
#   /usr/local/bin/osmo-lte     the launcher (tools/osmo-lte.sh)
#   /usr/local/bin/osmo-epc     the core (tools/osmo-epc.sh), alias open5gs-epc.sh
#
#   osmo-lte-install                 = --deps --debs --configs --launchers
#   osmo-lte-install --all           same, plus --build if the binaries are missing
#   osmo-lte-install --build         builds srsRAN and Open5GS in /opt/LTE
#   osmo-lte-install --deps          the apt packages (runtime + build), mongodb-org
#   osmo-lte-install --debs          installs the cached .deb files (/var/cache/osmo-debs)
#   osmo-lte-install --configs       installs the repo configs
#   osmo-lte-install --launchers     osmo-lte, osmo-epc in /usr/local/bin
#                                    (+ the open5gs-webui unit, enabled)
#   osmo-lte-install --webui         builds the Open5GS WebUI (console :9999)
#   osmo-lte-install --force         (with --configs) overwrites existing configs
#
# Idempotent, non-fatal package by package. Usable in a session AND in the ISO
# chroot (no systemd: the systemctl calls fail there without stopping).
# =============================================================================
set -u

REPO="${OSMO_REPO:-${DIR:-/opt/GSM/osmo-operator}}"
LTE="${OSMO_LTE_ROOT:-/opt/LTE}"
O5GS="$LTE/open5gs"
O5GS_PREFIX="${OPEN5GS_PREFIX:-$O5GS/install}"
SRS="$LTE/srsRAN_4G"
SRSGUI="$LTE/srsGUI"
SRS_DIR="${OSMO_SRSRAN_DIR:-/root/.config/srsran}"
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
SRS_REF="${OSMO_SRSRAN_REF:-release_25_10}"
# srsGUI has neither tag nor release: it is master. The .deb version is
# therefore named here, once, and the three paths reuse it (Dockerfile,
# packaging/snapshot-lte-debs.sh, lte_debs).
SRSGUI_REF="${OSMO_SRSGUI_REF:-master}"
SRSGUI_VER="${OSMO_SRSGUI_VER:-0.1+git}"
O5GS_REF="${OSMO_OPEN5GS_REF:-v2.8.0}"
JOBS="${JOBS:-$(nproc)}"
# ── THE srsRAN ISA: PORTABLE, NOT « native » ─────────────────────────────────
# The srsRAN_4G CMakeLists sets GCC_ARCH to « native » by default, and its
# cmake/modules/FindSSE.cmake decides on -mavx/-mavx2/-mfma/-mavx512 through
# check_c_source_runs - that is, by RUNNING the test on the building machine.
# The binaries thus come out tailored for that processor; on a CPU without
# AVX2 (a VM that does not expose the full set, an older laptop, a different
# CI runner) the first such instruction raises SIGILL. An ISO moves from one
# machine to another by definition: it cannot be built « for the build
# machine ».
# A common baseline is therefore fixed (SSE4.1/SSE4.2, every x86_64 since
# 2009 - and srsRAN requires SSE4.1 anyway, see its « no SIMD instructions
# found ») and the AVX/AVX2/FMA/AVX512 detections, which only measure the
# host, are switched off.
# OSMO_SRSRAN_ARCH=native restores host-tuned binaries (faster, valid on THIS
# machine only); any other value is passed as is to -march= (x86-64,
# nehalem, haswell...). A -march the local gcc does not know is ignored by
# ADD_C_COMPILER_FLAG_IF_AVAILABLE: the compiler's x86-64 baseline is then
# used, portable as well.
SRS_ARCH="${OSMO_SRSRAN_ARCH:-x86-64-v2}"

# ── THE srsRAN .deb VERSION CARRIES ITS ISA ─────────────────────────────────
# The ISA is part of the version: a native binary cannot be mistaken for a
# portable one, the .deb cache (locally and in the GitHub workflow restore
# keys) keeps both without one shadowing the other, and nothing is rebuilt
# once the right .deb is there.
srs_deb_version() {
    local v a
    v="${SRS_REF#release_}"; v="${v//_/.}"
    a="$(printf '%s' "$SRS_ARCH" | tr -c 'A-Za-z0-9.' '-')"   # osmo-deb: [A-Za-z0-9.+~-]
    printf '%s+zmq+%s\n' "$v" "$a"
}

: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${RED:=}"; : "${BOLD:=}"; : "${NC:=}"
_l_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_l_ok()   { echo -e "      ${GREEN}✓${NC} $*"; }
_l_warn() { echo -e "      ${YELLOW}!${NC} $*"; }
_l_err()  { echo -e "      ${RED}✗${NC} $*" >&2; }

# ── WILL THIS srsenb RUN ANYWHERE BUT HERE? ──────────────────────────────────
# An already installed srsenb - or one from a cached .deb built on ANOTHER
# machine - may be tailored for the CPU that built it, and nothing betrays
# it: it exists, its libraries resolve, --help answers. It only shows at the
# first real launch, as an « Illegal instruction (core dumped) » without a
# line of log (see SRS_ARCH above). So look at what the binary CONTAINS: a
# single %ymm (AVX/AVX2) or %zmm (AVX512) instruction condemns it outside its
# machine of origin. Without objdump (binutils absent) no verdict: what is
# there is kept, and no hour-long rebuild is triggered on a doubt.
_srs_isa_portable() {
    local b; b="$(command -v srsenb 2>/dev/null)" || return 0
    [ -n "$b" ] || return 0
    command -v objdump >/dev/null 2>&1 || return 0
    ! objdump -d "$b" 2>/dev/null | grep -qE '%[yz]mm[0-9]'
}

# ── THE PACKAGES ─────────────────────────────────────────────────────────────
# Runtime (what ldd of srsenb and open5gs-mmed asks for) AND build: the ISO is
# a workshop, « make » must be possible again in /opt/LTE. mongodb-org comes
# from the MongoDB repository (noble/8.0): the key and the source are laid
# down if missing. Non-fatal package by package.
_lte_apt_mongo_source() {
    local k=/usr/share/keyrings/mongodb-server-8.0.gpg
    local s=/etc/apt/sources.list.d/mongodb-org-8.0.list
    [ -s "$s" ] && [ -s "$k" ] && return 0
    command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 || { _l_warn "curl/gpg absents : pas de depot MongoDB"; return 1; }
    if curl -fsSL --retry 3 https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor --yes -o "$k" 2>/dev/null; then
        echo "deb [ arch=amd64,arm64 signed-by=$k ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > "$s"
        _l_ok "depot MongoDB 8.0 pose ($s)"
    else
        _l_warn "cle MongoDB injoignable : mongodb-org ne s installera pas (HSS/PCRF sans base)"
        return 1
    fi
}

lte_deps() {
    export DEBIAN_FRONTEND=noninteractive
    _l_say "paquets de la 4G (srsRAN ZeroMQ + Open5GS + MongoDB)"
    _lte_apt_mongo_source || true
    apt-get update -y >/dev/null 2>&1 || true
    local p
    # qtbase5/qwt/boost: srsGUI (the real-time plots of srsenb and srsue).
    # Without them the srsGUI cmake fails and srsRAN builds without plots -
    # nothing stops, but the constellation would never be seen.
    # libpcsclite-dev: srsUE reads a REAL SIM card through PC/SC
    # (srsue/hdr/stack/upper/pcsc_usim.h -> winscard.h); the srsRAN tree
    # shipped by osmo-build-srsran carries a CMakeCache where PCSC is ACTIVE,
    # so any rebuild needs winscard.h.
    for p in libzmq5 libzmq3-dev libboost-program-options-dev libmbedtls-dev libconfig++-dev libfftw3-dev libsctp-dev lksctp-tools cmake \
             qtbase5-dev libqt5opengl5-dev libqwt-qt5-dev libboost-system-dev libboost-thread-dev libboost-test-dev \
             libpcsclite-dev \
             meson ninja-build flex bison libgnutls28-dev libgcrypt20-dev libssl-dev libidn-dev libmongoc-dev libbson-dev \
             libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev libtins-dev libtalloc-dev libc-ares-dev \
             mongodb-org mongodb-mongosh mongodb-database-tools; do
        dpkg -s "$p" >/dev/null 2>&1 && continue
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
            && _l_ok "$p" || _l_warn "$p indisponible (apt) - ignore"
    done
    # mongod: ENABLED at boot (osmo-epc starts it anyway if it sleeps).
    # In a chroot without systemd, enable still creates the link.
    systemctl enable mongod >/dev/null 2>&1 && _l_ok "mongod active au demarrage" || true
}

# ── THE DOCKER BUILD .deb FILES ──────────────────────────────────────────────
# osmo-build-libzmq, osmo-build-srsran, osmo-build-open5gs: produced by the
# Dockerfile (osmo-deb pack) or by a snapshot of the reference machine
# (packaging/snapshot-lte-debs.sh). Installed only if the binaries are missing.
lte_debs() {
    local n deb suite
    suite="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")"
    # srsgui BEFORE srsran: it is the plot library, and srsRAN looks for it at
    # ITS configure time (see lte_build).
    for n in libzmq srsgui srsran open5gs; do
        case "$n" in
            libzmq)  [ -e /usr/local/lib/libzmq.so.5 ] || [ -e /usr/lib/x86_64-linux-gnu/libzmq.so.5 ] && continue ;;
            srsgui)  [ -e /usr/local/lib/libsrsgui.so ] || [ -e /usr/local/lib/libsrsgui.a ] && continue ;;
            srsran)  command -v srsenb >/dev/null 2>&1 && continue ;;
            open5gs) [ -x "$O5GS_PREFIX/bin/open5gs-mmed" ] && continue ;;
        esac
        deb="$(ls -1 "$DEB_CACHE"/osmo-build-${n}_*"~${suite}_$(dpkg --print-architecture).deb" 2>/dev/null | tail -1)"
        [ -n "$deb" ] || { _l_warn "$n : pas de binaire ni de .deb dans $DEB_CACHE (osmo-lte-install --build)"; continue; }
        dpkg -i --force-overwrite "$deb" >/dev/null 2>&1 && _l_ok "$n pose depuis $(basename "$deb")" || _l_warn "dpkg -i $(basename "$deb") a echoue"
    done
    ldconfig 2>/dev/null || true
}

# ── THE BUILD, IN /opt/LTE ───────────────────────────────────────────────────
# srsRAN_4G with ZeroMQ (Ubuntu's libzmq3-dev is enough), Open5GS through
# meson with the /opt/LTE/open5gs/install prefix. Under OSMO_DEB=1 (the
# Dockerfile) each step is packed into a .deb via osmo-deb pack; otherwise
# make/ninja install directly.
lte_build() {
    mkdir -p "$LTE"
    local pack=""
    [ "${OSMO_DEB:-0}" = "1" ] && command -v osmo-deb >/dev/null 2>&1 && pack=1
    # ── THE .deb VERSIONS: WRITTEN ONCE, FOR EVERYONE ────────────────────────
    # The names that count are those of the Dockerfile and of
    # packaging/snapshot-lte-debs.sh: osmo-build-srsran_25.10+zmq+<isa>,
    # osmo-build-open5gs_2.8.0+git. They are derived here from the same git
    # refs, with dots (osmo-deb refuses an underscore in a version).
    local srs_ver o5gs_ver
    srs_ver="$(srs_deb_version)"                                    # release_25_10 -> 25.10+zmq+x86-64-v2
    o5gs_ver="${O5GS_REF#v}+git"                                    # v2.8.0       -> 2.8.0+git
    # ── srsGUI FIRST: srsRAN IS THE ONE LOOKING FOR IT ──────────────────────
    # The real-time plots of srsenb and srsue (constellation, spectrum, PDSCH)
    # come from srsGUI (github.com/srsran/srsGUI, Qt5 + Qwt), a SEPARATE
    # library - and the srsRAN cmake looks for it AT ITS OWN CONFIGURE TIME.
    # Installed afterwards it would be useless: it is therefore built HERE,
    # just before, and srsRAN is configured with ENABLE_GUI=ON below.
    #
    # NON-FATAL, ON PURPOSE: without Qt, without network, or if the srsGUI
    # cmake fails, a warning is printed and the build goes on. ENABLE_GUI=ON
    # then breaks nothing - the srsRAN cmake notices the absence and does not
    # enable the plots. A bench without a constellation window is still a
    # bench; a bench that no longer builds is not.
    if [ ! -e /usr/local/lib/libsrsgui.so ] && [ ! -e /usr/local/lib/libsrsgui.a ]; then
        _l_say "srsGUI $SRSGUI_REF -> $SRSGUI (les traces de srsenb / srsue)"
        if [ ! -d "$SRSGUI/.git" ]; then
            git clone --depth 1 -b "$SRSGUI_REF" https://github.com/srsran/srsGUI "$SRSGUI" >/dev/null 2>&1 \
              || git clone --depth 1 https://github.com/srsran/srsGUI "$SRSGUI" >/dev/null 2>&1 \
              || _l_warn "srsGUI : clone impossible - srsRAN se compilera sans traces"
        fi
        if [ -d "$SRSGUI" ]; then
            # ── -DBOOST_TIMER_ENABLE_DEPRECATED: WITHOUT IT, NOTHING COMES OUT
            # srsGUI does not build on Boost 1.83 (noble): its TESTS
            # (test/cxx/*_test.cpp) include boost/progress.hpp and
            # boost/timer.hpp, which are deprecated and #error out - and
            # `make install` goes through the `all` target, tests included, so
            # one test that does not compile blocks the whole install. Boost
            # itself says what to do (« You can define
            # BOOST_TIMER_ENABLE_DEPRECATED to suppress this error »): it is
            # defined, rather than removing targets from the upstream project.
            ( cd "$SRSGUI" && mkdir -p build && cd build \
              && cmake -DCMAKE_BUILD_TYPE=Release \
                       -DCMAKE_CXX_FLAGS=-DBOOST_TIMER_ENABLE_DEPRECATED .. >/dev/null 2>&1 \
              && make -j"$JOBS" >/dev/null 2>&1 \
              && if [ -n "$pack" ]; then OSMO_DEB_SRC_ROOT="$LTE" OSMO_DEB_SRC="$SRSGUI" osmo-deb pack srsgui "$SRSGUI_VER" make install
                 else make install >/dev/null 2>&1; fi ) \
              && { ldconfig; _l_ok "srsGUI : /usr/local/lib/libsrsgui"; } \
              || _l_warn "srsGUI : compilation echouee - srsRAN se compilera sans traces"
        fi
    else
        _l_ok "srsGUI deja la (/usr/local/lib/libsrsgui)"
    fi
    # ── A srsenb WITHOUT PLOTS DOES NOT FIX ITSELF ──────────────────────────
    # A machine that already has srsRAN - or got it from osmo-build-srsran -
    # may carry binaries without plots even with libsrsgui freshly installed
    # ten lines above. So check what the binary is LINKED against, not only
    # whether it exists.
    _srs_lie_gui() {
        local b; b="$(command -v srsenb 2>/dev/null)" || return 1
        [ -n "$b" ] && ldd "$b" 2>/dev/null | grep -q libsrsgui
    }
    if ! command -v srsenb >/dev/null 2>&1 \
       || { [ -e /usr/local/lib/libsrsgui.so ] && ! _srs_lie_gui; } \
       || { [ "$SRS_ARCH" != native ] && ! _srs_isa_portable; }; then
        if command -v srsenb >/dev/null 2>&1; then
            if [ "$SRS_ARCH" != native ] && ! _srs_isa_portable; then
                _l_say "srsRAN_4G : recompilation, srsenb porte de l AVX (taille pour le CPU du build, SIGILL ailleurs)"
            else
                _l_say "srsRAN_4G : recompilation, srsenb n est pas lie a srsGUI"
            fi
        else
            _l_say "srsRAN_4G $SRS_REF (ZeroMQ, -march=$SRS_ARCH) -> $SRS"
        fi
        if [ ! -d "$SRS/.git" ]; then
            git clone --depth 1 -b "$SRS_REF" https://github.com/srsran/srsRAN_4G "$SRS" || { _l_err "clone srsRAN_4G"; return 1; }
        fi
        # ── THE CMAKE CACHE LIES ABOUT THE ISA ─────────────────────────────
        # HAVE_AVX2, HAVE_FMA, HAVE_AVX512 are CACHE variables set by the
        # check_c_source_runs of FindSSE.cmake. -DENABLE_AVX2=OFF prevents the
        # TEST from running, it does not erase a previous answer: on an
        # already configured tree, the CMakeLists `if (HAVE_AVX2)` would reread
        # the cache and put -mavx2 back. So start from an empty build - the
        # flags change anyway, every object has to be rebuilt.
        rm -rf "$SRS/build"
        # -DGCC_ARCH: the common baseline (see SRS_ARCH above). The four
        # ENABLE_* switch off the detections that only measure the host;
        # SSE4.1 stays active (ENABLE_SSE=ON by default), otherwise cmake
        # stops on « no SIMD instructions found » and srsRAN loses its -Ofast.
        _srs_isa=(-DGCC_ARCH="$SRS_ARCH" -DENABLE_AVX=OFF -DENABLE_AVX2=OFF -DENABLE_FMA=OFF -DENABLE_AVX512=OFF)
        [ "$SRS_ARCH" = native ] && _srs_isa=(-DGCC_ARCH=native)
        ( cd "$SRS" && mkdir -p build && cd build \
          && cmake -DENABLE_ZEROMQ=ON -DENABLE_GUI=ON -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SOAPYSDR=OFF \
                   "${_srs_isa[@]}" \
                   -DCMAKE_BUILD_TYPE=Release .. >/dev/null \
          && make -j"$JOBS" >/dev/null \
          && if [ -n "$pack" ]; then OSMO_DEB_SRC_ROOT="$LTE" OSMO_DEB_SRC="$SRS" osmo-deb pack srsran "$srs_ver" make install
             else make install >/dev/null; fi ) \
          && { ldconfig; _l_ok "srsRAN : $(command -v srsenb)"; } || { _l_err "srsRAN : compilation echouee"; return 1; }
    else
        _l_ok "srsRAN deja la ($(command -v srsenb))$(_srs_lie_gui && echo ' + traces srsGUI')"
    fi
    if [ ! -x "$O5GS_PREFIX/bin/open5gs-mmed" ]; then
        _l_say "Open5GS $O5GS_REF -> $O5GS (prefixe $O5GS_PREFIX)"
        if [ ! -d "$O5GS/.git" ]; then
            git clone --depth 1 -b "$O5GS_REF" https://github.com/open5gs/open5gs "$O5GS" || { _l_err "clone open5gs"; return 1; }
        fi
        ( cd "$O5GS" \
          && { [ -f build/build.ninja ] || meson setup build --prefix="$O5GS_PREFIX" >/dev/null; } \
          && ninja -C build -j"$JOBS" >/dev/null \
          && if [ -n "$pack" ]; then OSMO_DEB_SRC_ROOT="$LTE" OSMO_DEB_SRC="$O5GS" osmo-deb pack open5gs "$o5gs_ver" ninja -C build install
             else ninja -C build install >/dev/null; fi ) \
          && { ldconfig; _l_ok "Open5GS : $O5GS_PREFIX/bin"; } || { _l_err "Open5GS : compilation echouee"; return 1; }
    else
        _l_ok "Open5GS deja la ($O5GS_PREFIX/bin/open5gs-mmed)"
    fi
}

# ── THE freeDiameter CERTIFICATES ────────────────────────────────────────────
# The bench Diameter peers are in No_TLS, but freeDiameter loads TLS_Cred /
# TLS_CA at init and refuses to start without them. Open5GS ships its own
# (configs/open5gs/tls of its repo) through the same install_conf that does
# nothing under DESTDIR (see lte_configs): ours are therefore generated, once
# (self-signed CA + one certificate per daemon), without touching existing ones.
lte_tls() {
    local t="$O5GS_PREFIX/etc/open5gs/tls" n
    command -v openssl >/dev/null 2>&1 || { _l_warn "openssl absent : pas de certificats freeDiameter (apt install openssl)"; return 0; }
    mkdir -p "$t"
    if [ ! -s "$t/ca.crt" ] || [ ! -s "$t/ca.key" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=ca.localdomain" \
            -keyout "$t/ca.key" -out "$t/ca.crt" >/dev/null 2>&1 || { _l_warn "CA freeDiameter : openssl a echoue"; return 0; }
    fi
    for n in mme hss pcrf smf; do
        [ -s "$t/$n.crt" ] && [ -s "$t/$n.key" ] && continue
        openssl req -newkey rsa:2048 -nodes -subj "/CN=$n.localdomain" -keyout "$t/$n.key" -out "$t/$n.csr" >/dev/null 2>&1 \
        && openssl x509 -req -in "$t/$n.csr" -CA "$t/ca.crt" -CAkey "$t/ca.key" -CAcreateserial -days 3650 -out "$t/$n.crt" >/dev/null 2>&1 \
        || _l_warn "certificat freeDiameter $n : openssl a echoue"
        rm -f "$t/$n.csr"
    done
    chmod 600 "$t"/*.key 2>/dev/null || true
}

# ── THE CONFIGS ──────────────────────────────────────────────────────────────
# The repo ones, as they run on the reference bench:
#   configs/srsran/*   -> /root/.config/srsran   (eNB 0x19B, TAC 7, EARFCN 3350,
#                         MME 127.0.0.2, ZeroMQ 2000/2001 at 11.52e6, SIB3+SIB7,
#                         UE 001010001000001, APN srsapn, netns ue1)
#   configs/open5gs/*.yaml -> $PREFIX/etc/open5gs (MME 127.0.0.2, SGs towards
#                         OsmoMSC 127.0.0.1, TAC 7 / LAC 1, UE 10.45.0.0/16)
# An existing config is not overwritten (the bench's live settings), except
# with --force: it is kept as .bak-osmo next to it.
lte_configs() {
    local force="${1:-0}" f dst
    mkdir -p "$SRS_DIR"
    for f in "$REPO"/configs/srsran/*; do
        [ -f "$f" ] || continue
        dst="$SRS_DIR/$(basename "$f")"
        if [ -f "$dst" ] && [ "$force" != "1" ]; then continue; fi
        [ -f "$dst" ] && ! cmp -s "$f" "$dst" && cp -a "$dst" "$dst.bak-osmo"
        install -m644 "$f" "$dst"
    done
    _l_ok "srsRAN : configs dans $SRS_DIR ($(ls "$SRS_DIR" | grep -c '\.conf$') .conf, user_db.csv)"
    # The BINARY is what says whether Open5GS is installed: an Open5GS from
    # the cached .deb, or an install whose etc/ was cleaned (the lite ISO
    # cleans /opt/LTE), has its binaries without the example yaml files. The
    # etc/ directory is created here.
    if [ -x "$O5GS_PREFIX/bin/open5gs-mmed" ] || [ -d "$O5GS_PREFIX/etc/open5gs" ] || [ "$force" = "1" ]; then
        mkdir -p "$O5GS_PREFIX/etc/open5gs" "$O5GS_PREFIX/var/log/open5gs"
        for f in "$REPO"/configs/open5gs/*.yaml; do
            [ -f "$f" ] || continue
            dst="$O5GS_PREFIX/etc/open5gs/$(basename "$f")"
            # The yaml files carry the /opt/LTE/open5gs/install prefix: another
            # prefix (OPEN5GS_PREFIX) is substituted on the fly.
            if [ -f "$dst" ] && [ "$force" != "1" ] && grep -q 'osmo-operator' "$dst" 2>/dev/null; then continue; fi
            [ -f "$dst" ] && ! cmp -s "$f" "$dst" && cp -a "$dst" "$dst.bak-osmo"
            sed "s#/opt/LTE/open5gs/install#$O5GS_PREFIX#g" "$f" > "$dst"
        done
        _l_ok "Open5GS : configs dans $O5GS_PREFIX/etc/open5gs"
        # freeDiameter AND the TLS certificates: what « ninja install » does
        # NOT lay down under DESTDIR (install_conf of meson.build: nothing if
        # DESTDIR is defined), hence never in the osmo-build-open5gs .deb -
        # without them the MME, HSS, PCRF and SMF die at init (« Unable to
        # open configuration file … freeDiameter/mme.conf »). See
        # configs/open5gs/freeDiameter/mme.conf. The .fdx directory depends on
        # the triplet (lib/x86_64-linux-gnu on amd64): substituted as well.
        local fdd fdlib
        fdd="$O5GS_PREFIX/etc/freeDiameter"; mkdir -p "$fdd"
        fdlib="$(ls -d "$O5GS_PREFIX"/lib/*/freeDiameter "$O5GS_PREFIX"/lib/freeDiameter 2>/dev/null | head -1)"
        for f in "$REPO"/configs/open5gs/freeDiameter/*.conf; do
            [ -f "$f" ] || continue
            dst="$fdd/$(basename "$f")"
            if [ -f "$dst" ] && [ "$force" != "1" ] && grep -q 'osmo-operator' "$dst" 2>/dev/null; then continue; fi
            [ -f "$dst" ] && ! cmp -s "$f" "$dst" && cp -a "$dst" "$dst.bak-osmo"
            sed "s#/opt/LTE/open5gs/install/lib/x86_64-linux-gnu/freeDiameter#${fdlib:-$O5GS_PREFIX/lib/x86_64-linux-gnu/freeDiameter}#g; s#/opt/LTE/open5gs/install#$O5GS_PREFIX#g" "$f" > "$dst"
        done
        lte_tls
        _l_ok "freeDiameter : $(ls "$fdd" 2>/dev/null | grep -c '\.conf$') .conf dans $fdd, TLS dans $O5GS_PREFIX/etc/open5gs/tls"
    else
        _l_warn "Open5GS pas installe (pas de $O5GS_PREFIX/bin/open5gs-mmed) : ses configs seront posees apres --build / --debs"
    fi
}

# ── THE LAUNCHERS ────────────────────────────────────────────────────────────
lte_launchers() {
    local t
    for t in osmo-lte osmo-epc; do
        [ -f "$REPO/tools/$t.sh" ] || { _l_warn "$REPO/tools/$t.sh absent"; continue; }
        chmod 755 "$REPO/tools/$t.sh"
        ln -sfn "$REPO/tools/$t.sh" "/usr/local/bin/$t"
    done
    # The core's older name, kept: habits and the bench notes use it.
    ln -sfn "$REPO/tools/osmo-epc.sh" /usr/local/bin/open5gs-epc.sh
    _l_ok "lanceurs : /usr/local/bin/osmo-lte, osmo-epc (alias open5gs-epc.sh)"
    # ── THE 4G SUBSCRIBER CONSOLE: INSTALLED AND ENABLED BY DEFAULT ─────────
    # Like the 2G dashboard (osmo-egprs-web). The unit still does not start
    # until the WebUI is built: its ConditionPathExists skips it, without
    # failure. « --webui » builds it. A MASKED unit is left alone: that is the
    # way to say no.
    if [ -f "$REPO/services/open5gs-webui.service" ]; then
        install -m644 "$REPO/services/open5gs-webui.service" \
                /etc/systemd/system/open5gs-webui.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        if [ "$(systemctl is-enabled open5gs-webui 2>/dev/null)" != masked ]; then
            systemctl enable open5gs-webui >/dev/null 2>&1 || true
        fi
        _l_ok "console 4G : open5gs-webui.service posee et activee (:9999)"
    fi
}

# ── THE OPEN5GS WEBUI: THE 4G SUBSCRIBER CONSOLE ─────────────────────────────
# The WebUI provisions LTE subscribers (otherwise done by hand in MongoDB or
# with « osmo-epc subscribers », which replays the repo JSON). It lives in the
# Open5GS SOURCES (webui/), not in the install prefix: a machine installed
# from the bench .deb files (osmo-build-open5gs) does NOT have it. It is
# fetched with a sparse checkout - the whole open5gs repo for one Next.js
# directory would be absurd - and built in place. It is npm: it needs the
# network and takes a few minutes. Hence a separate sub-command, outside the
# default path.
lte_webui() {
    local dir="$O5GS/webui" tmp="$LTE/.open5gs-webui-src"
    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
        || { _l_warn "WebUI Open5GS : node/npm absents - rien a construire"; return 1; }
    if [ ! -f "$dir/package.json" ]; then
        _l_say "WebUI Open5GS $O5GS_REF -> $dir"
        rm -rf "$tmp"
        # sparse: only webui/ is fetched (and blobs on demand).
        if git clone --depth 1 --filter=blob:none --sparse -b "$O5GS_REF" \
               https://github.com/open5gs/open5gs "$tmp" >/dev/null 2>&1 \
           && ( cd "$tmp" && git sparse-checkout set webui >/dev/null 2>&1 ) \
           && [ -d "$tmp/webui" ]; then
            mkdir -p "$O5GS"
            rm -rf "$dir"; mv "$tmp/webui" "$dir"; rm -rf "$tmp"
        else
            rm -rf "$tmp"; _l_err "WebUI Open5GS : recuperation des sources echouee"; return 1
        fi
    fi
    # `npm install` and not `npm ci --omit=dev`: Next.js builds WITH its
    # development dependencies, and the repo does not always ship an
    # up-to-date package-lock.
    ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 \
      && npm run build >/dev/null 2>&1 ) \
        || { _l_err "WebUI Open5GS : npm install / build echoue (voir $dir)"; return 1; }
    [ -f "$dir/server/index.js" ] || { _l_err "WebUI Open5GS : pas de server/index.js apres build"; return 1; }
    _l_ok "WebUI Open5GS construit ($dir) - console des abonnes sur :9999"
    systemctl restart open5gs-webui >/dev/null 2>&1 || true
}

osmo_lte_install() {
    local deps=0 debs=0 configs=0 launchers=0 build=0 all=0 force=0 webui=0 a rc=0
    for a in "$@"; do case "$a" in
        --deps) deps=1 ;; --debs) debs=1 ;; --configs) configs=1 ;; --launchers) launchers=1 ;;
        --build) build=1 ;; --all) all=1 ;; --force) force=1 ;; --webui) webui=1 ;;
        # The Dockerfile asks for the name instead of copying it: written
        # once, and changing OSMO_SRSRAN_ARCH changes both.
        --srs-deb-version) srs_deb_version; return 0 ;;
        *) echo "osmo-lte-install : option inconnue $a" >&2; return 2 ;;
    esac; done
    if [ $((deps + debs + configs + launchers + build + all + webui)) -eq 0 ]; then deps=1; debs=1; configs=1; launchers=1; fi
    if [ "$all" = 1 ]; then deps=1; debs=1; configs=1; launchers=1; fi
    [ "$deps" = 1 ] && lte_deps
    [ "$debs" = 1 ] && lte_debs
    # « ! command -v srsenb » is not enough to decide on a build: a srsenb
    # that is PRESENT but tailored for another machine's CPU would get through
    # --all (hence addition.sh and update.sh). Same question as elsewhere:
    # will this binary run HERE?
    if [ "$build" = 1 ] || { [ "$all" = 1 ] && { ! command -v srsenb >/dev/null 2>&1 \
            || { [ "$SRS_ARCH" != native ] && ! _srs_isa_portable; } \
            || [ ! -x "$O5GS_PREFIX/bin/open5gs-mmed" ]; }; }; then
        # A failed build does not stop the rest (configs, launchers: the bench
        # must stay usable without the 4G) but the return code reports it.
        # The callers handle it (`|| true`, `|| inst_hint`): addition.sh,
        # update.sh, install_modules/50-build.sh.
        lte_build || rc=1
    fi
    [ "$configs" = 1 ] && lte_configs "$force"
    [ "$launchers" = 1 ] && lte_launchers
    # The WebUI goes through npm and the network: never in the default path,
    # only on request (or with --all, which is already the long path).
    if [ "$webui" = 1 ] || [ "$all" = 1 ]; then lte_webui || rc=1; fi
    return $rc
}

# Sourced (addition.sh, update.sh) or executed (ISO, command line).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "osmo-lte-install : root requis" >&2; exit 1; }
    osmo_lte_install "$@"
fi
