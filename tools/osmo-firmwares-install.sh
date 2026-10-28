#!/bin/bash
# =============================================================================
# osmo-firmwares-install.sh - THE PHONE FIRMWARES OUTSIDE THE ISO (supplements)
#
# Sourced by addition.sh (--gnuarm, --magnetite, --trx, --fernvale, --simcom).
# Each function is IDEMPOTENT (an already cloned tree is not re-cloned, an
# already built binary is not rebuilt without OSMO_FW_REFAIRE=1) and nothing
# is fatal: a missing mirror must not stop the other supplements.
#
#   osmo_gnuarm_install     the historical osmocom-bb toolchain: arm-elf-gcc 4.5.2,
#                           PULLED from the osmocom-bb-trx Docker image (not rebuilt)
#                           into /root/gnuarm, and the libmpfr.so.4 -> libmpfr.so.6
#                           link its cc1 requires
#   osmo_magnetite_install  FreeCalypso Magnetite for the Motorola C139 (the real
#                           TI firmware): Wine + TI TMS470 environment, pinned git
#                           sources, bench patches, 4 MiB flash image
#   osmo_calypso_fw_install the bench Calypso firmware (layer1 GPRS, rssi...)
#                           rebuilt with gnuarm from osmocom-bb eac4eed1 + patches
#   osmo_trx_install        osmocom-bb-trx: the published Docker image (host side,
#                           ubuntu 16.04) and the trx firmware (active TX) built
#                           with gnuarm
#   osmo_fernvale_install   MediaTek MT6260 (Fernvale): fernly, fernvale-nuttx,
#                           osmocom-bb-mtk-layer1, with arm-none-eabi
#   osmo_simcom_install     the SIMCom documentation and SDKs (~3.4 GB)
# =============================================================================

: "${GREEN:=}"; : "${YELLOW:=}"; : "${RED:=}"; : "${CYAN:=}"; : "${BOLD:=}"; : "${NC:=}"
: "${GSM_ROOT:=/opt/GSM}"
: "${REPO:=${DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
: "${OSMO_FW_JOBS:=$(nproc 2>/dev/null || echo 4)}"
OSMO_FW_LOG="${OSMO_FW_LOG:-/var/log/osmo-firmwares}"

_fw_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_fw_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_fw_err()  { echo -e "  ${RED}✗${NC} $*"; }
_fw_log()  { mkdir -p "$OSMO_FW_LOG" 2>/dev/null; echo "$OSMO_FW_LOG/$1.log"; }

# apt without questions, once per run of the supplement
_fw_apt() {
    if [ -z "${_FW_APT_UPDATE:-}" ]; then apt-get update -qq >/dev/null 2>&1 || true; _FW_APT_UPDATE=1; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >>"$(_fw_log apt)" 2>&1
}

# git clone if missing; nothing otherwise (an existing work tree is not touched)
_fw_clone() {   # url dest [branche]
    local url="$1" dest="$2" br="${3:-}"
    if [ -d "$dest/.git" ]; then _fw_ok "$(basename "$dest") deja present ($dest)"; return 0; fi
    git clone -q ${br:+-b "$br"} "$url" "$dest" >>"$(_fw_log git)" 2>&1 \
        && _fw_ok "$(basename "$dest") clone ($url${br:+ $br})" \
        || { _fw_err "clone de $url impossible (voir $(_fw_log git))"; return 1; }
}

# THE osmocom-bb .map ISSUE. The .map file is requested at link time in two
# forms, both broken as soon as the link goes through the gcc driver ($(CC)):
#   "-Map board/..."       (jolly/testing, MTK): gcc reads -Map as -M -ap;
#   "-Wl,-Map board/..."   (upstream osmocom-bb, eac4eed1): -Map goes to ld but
#                            the NAME goes to gcc, as an input file: "board/
#                            compal_e88/hello_world.highram.map: No such file".
# Both become -Wl,-Map,<file> (comma). Through $(LD) directly (gnuarm on
# jolly/testing) "-Map file" is right: left untouched. The script solve_envs.py
# is Python 2 (print without parentheses): without python2 on the host, no
# environment is resolved and the firmware comes out without .bin, silently.
_fw_bb_corriger() {   # racine/src/target/firmware
    local fw="$1" mk="$1/Makefile.inc"
    if [ -f "$mk" ] && grep -q '^\s*-Wl,-Map board' "$mk"; then
        sed -i 's|^\(\s*\)-Wl,-Map board/|\1-Wl,-Map,board/|' "$mk"
        _fw_ok "Makefile.inc : -Wl,-Map <fichier> -> -Wl,-Map,<fichier>"
    fi
    if [ -f "$mk" ] && grep -q '^\s*-Map board' "$mk" \
       && grep -B2 '^\s*-Map board' "$mk" | grep -q '\$(CC)'; then
        sed -i 's|^\(\s*\)-Map board/\$(2)/\$(1)\.\$(3)\.map |\1-Wl,-Map,board/$(2)/$(1).$(3).map |' "$mk"
        _fw_ok "Makefile.inc : -Map -> -Wl,-Map,<fichier> (lien par gcc)"
    fi
    if [ -f "$fw/solve_envs.py" ] && grep -q "^\s*print ' '" "$fw/solve_envs.py"; then
        sed -i "1s|python\$|python3|; s|^\(\s*\)print ' '.join(envs)|\1print(' '.join(envs))|" "$fw/solve_envs.py"
        _fw_ok "solve_envs.py passe en Python 3"
    fi
}

# ── gnuarm ───────────────────────────────────────────────────────────────────
# THE TOOLCHAIN IS NOT REBUILT: gnu-arm-installer (binutils, gcc 4.5.2,
# newlib 1.19 from sources) takes a long time and depends on mirrors that
# disappear (newlib has left sources.redhat.com). The osmocom-bb-trx image,
# already pulled for --trx, carries the same toolchain, built once and for
# all: /root/gnuarm/install. It is copied out of the image (docker create +
# docker cp, without running a container) to $GNUARM_DIR/install. Its
# binaries come from Ubuntu 16.04: on noble they only lack libmpfr.so.4, the
# link installed below. Tested: compiling and linking a .c with newlib
# (-mcpu=arm7tdmi) with arm-elf-gcc 4.5.2.
GNUARM_DIR="${GNUARM_DIR:-/root/gnuarm}"
OSMOCOM_BB_TRX_IMAGE="${OSMOCOM_BB_TRX_IMAGE:-ghcr.io/bbaranoff/osmocom-bb-trx:main}"
osmo_gnuarm_install() {
    echo -e "${BOLD}== gnuarm (arm-elf-gcc 4.5.2, image $OSMOCOM_BB_TRX_IMAGE) ==${NC}"
    if [ ! -x "$GNUARM_DIR/install/bin/arm-elf-gcc" ]; then
        if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
            _fw_err "docker absent ou arrete : gnuarm vient de l image $OSMOCOM_BB_TRX_IMAGE (addition.sh --docker)"
            return 1
        fi
        local log c; log="$(_fw_log gnuarm)"
        docker pull "$OSMOCOM_BB_TRX_IMAGE" >>"$log" 2>&1 \
            || { _fw_err "docker pull $OSMOCOM_BB_TRX_IMAGE en echec (voir $log)"; return 1; }
        c="$(docker create "$OSMOCOM_BB_TRX_IMAGE" 2>>"$log")" \
            || { _fw_err "docker create en echec (voir $log)"; return 1; }
        mkdir -p "$GNUARM_DIR"
        rm -rf "$GNUARM_DIR/install"
        docker cp -q "$c:/root/gnuarm/install" "$GNUARM_DIR/install" >>"$log" 2>&1
        local rc=$?
        docker rm -f "$c" >/dev/null 2>&1
        [ "$rc" = 0 ] || { _fw_err "docker cp de /root/gnuarm/install en echec (voir $log)"; return 1; }
        _fw_ok "gnuarm copie depuis l image ($GNUARM_DIR/install, $(du -sh "$GNUARM_DIR/install" | cut -f1))"
    fi
    # cc1 of gcc 4.5.2 is linked to libmpfr.so.4, which noble no longer provides
    # (libmpfr.so.6, same ABI for what it uses): without this link, "cc1: error
    # while loading shared libraries: libmpfr.so.4".
    if [ ! -e /usr/local/lib/libmpfr.so.4 ]; then
        local m6; m6="$(ls /usr/lib/*-linux-gnu/libmpfr.so.6 2>/dev/null | head -1)"
        if [ -n "$m6" ]; then ln -sf "$m6" /usr/local/lib/libmpfr.so.4 && ldconfig && _fw_ok "lien libmpfr.so.4 -> $m6"
        else _fw_warn "libmpfr.so.6 introuvable : apt install libmpfr6"; fi
    fi
    if echo 'int main(void){return 0;}' | "$GNUARM_DIR/install/bin/arm-elf-gcc" -x c -c -o /dev/null - 2>/dev/null; then
        _fw_ok "arm-elf-gcc $("$GNUARM_DIR/install/bin/arm-elf-gcc" -dumpversion) operationnel ($GNUARM_DIR/install/bin)"
    else
        _fw_err "arm-elf-gcc ne compile pas (cc1, libmpfr ?)"; return 1
    fi
    # $GNUARM_DIR/install/bin in the PATH of every login shell
    # (scripts/osmo-gnuarm-profile.sh -> /etc/profile.d/97-osmo-gnuarm.sh)
    if [ -f "${REPO:-/opt/GSM/osmo-operator}/scripts/osmo-gnuarm-profile.sh" ]; then
        install -m644 "${REPO:-/opt/GSM/osmo-operator}/scripts/osmo-gnuarm-profile.sh" /etc/profile.d/97-osmo-gnuarm.sh \
            && _fw_ok "PATH : $GNUARM_DIR/install/bin (/etc/profile.d/97-osmo-gnuarm.sh, nouveaux shells)"
    fi
}

# ── Magnetite (C139) ─────────────────────────────────────────────────────────
# NOTHING FROM freecalypso.org: its FTP caps at ~18 KB/s (52 MB of TI
# environment = 45 min). github.com/bbaranoff/fc-magnetite carries the converted
# hg history (tip 9394305d4ff5, upstream under the bench patches) and, in
# freecalypso-env/, the Wine environment, the Compal bootloader and freecalypso-tools.
FC_MAGNETITE_GIT="${FC_MAGNETITE_GIT:-https://github.com/bbaranoff/fc-magnetite}"
FC_ENV_URL="${FC_ENV_URL:-https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env}"
osmo_magnetite_install() {
    echo -e "${BOLD}== FreeCalypso Magnetite (C139) : Wine + TI TMS470 ==${NC}"
    local fcm="$GSM_ROOT/fc-magnetite" fht="$GSM_ROOT/fc-host-tools" wdl="$GSM_ROOT/fc-wine-dl" \
          bdl="$GSM_ROOT/fc-dl" out="$GSM_ROOT/firmware/magnetite" log; log="$(_fw_log magnetite)"
    # 32-bit Wine: the TMS470 (cl470, asm470, lnk470) is a 32-bit Windows binary
    dpkg --print-foreign-architectures | grep -qx i386 || dpkg --add-architecture i386
    _FW_APT_UPDATE=""
    _fw_apt git wine wine64 wine32:i386 xz-utils wget build-essential \
        || { _fw_err "installation de Wine en echec (voir $(_fw_log apt))"; return 1; }
    _fw_ok "wine $(wine --version 2>/dev/null)"
    # the sources: Magnetite (the git repository, freecalypso-env/ included) and the
    # FreeCalypso host tools (rvinterf, fc-shell, fc-fsio: run.sh needs them). An old
    # hg clone stays as is: the environment is then taken from FC_ENV_URL.
    if [ ! -d "$fcm/.hg" ] && [ ! -d "$fcm/.git" ]; then
        git clone -q "$FC_MAGNETITE_GIT" "$fcm" >>"$log" 2>&1 \
            || { _fw_err "git clone fc-magnetite en echec (voir $log)"; return 1; }
        _fw_ok "fc-magnetite clone ($FC_MAGNETITE_GIT)"
    fi
    # _fc_env <file> <destination>: the copy from the clone, else the GitHub repository
    _fc_env() {
        [ -s "$2" ] && return 0
        if [ -s "$fcm/freecalypso-env/$1" ]; then cp "$fcm/freecalypso-env/$1" "$2"
        else wget -q -O "$2" "$FC_ENV_URL/$1" >>"$log" 2>&1 || { rm -f "$2"; return 1; }; fi
    }
    if [ ! -f "$fht/Makefile" ]; then
        mkdir -p "$fht" "$wdl"
        _fc_env freecalypso-tools.tar.xz "$wdl/freecalypso-tools.tar.xz" \
            && tar xJf "$wdl/freecalypso-tools.tar.xz" -C "$fht" --strip-components=1 >>"$log" 2>&1 \
            || _fw_warn "freecalypso-tools : extraction en echec"
    fi
    [ -x "$fht/rvinterf/lowlevel/rvinterf" ] || make -C "$fht" -j"$OSMO_FW_JOBS" >>"$log" 2>&1 \
        || _fw_warn "outils hote FreeCalypso : make en echec (voir $log)"
    # the bench patches (forced ARFCN, auto registration, SMS, MMI): a single file,
    # regenerated by `hg diff` in fc-magnetite (patches/fc-magnetite-banc.patch)
    local p="$REPO/patches/fc-magnetite-banc.patch"
    if [ -f "$p" ]; then
        if (cd "$fcm" && patch -p1 -R --dry-run -s -f <"$p" >/dev/null 2>&1); then _fw_ok "patchs du banc deja appliques"
        elif (cd "$fcm" && patch -p1 -s -f <"$p" >>"$log" 2>&1); then _fw_ok "patchs du banc appliques ($(basename "$p"))"
        else _fw_warn "$(basename "$p") ne s applique pas sur cet arbre (voir $log)"; fi
    fi
    # the TI environment installed (compiler, cygwin, perl, java) in ~/.wine/drive_c
    mkdir -p "$wdl" "$bdl" "$out"
    local f
    for f in installed-env.tar.xz nowhine.c winebuild.sh README; do
        _fc_env "$f" "$wdl/$f" || _fw_warn "telechargement $f en echec"
    done
    if [ ! -d "$HOME/.wine/drive_c/Dvpt_tools" ]; then
        WINEDEBUG=-all wineboot -i >>"$log" 2>&1
        tar xJf "$wdl/installed-env.tar.xz" -C "$HOME/.wine/drive_c" >>"$log" 2>&1 \
            && _fw_ok "environnement TI pose dans $HOME/.wine/drive_c" \
            || { _fw_err "environnement TI : extraction en echec"; return 1; }
        WINEDEBUG=-all wineboot -u >>"$log" 2>&1
    fi
    [ -x /usr/local/bin/nowhine ] || gcc -O2 -o /usr/local/bin/nowhine "$wdl/nowhine.c" >>"$log" 2>&1 \
        || _fw_warn "nowhine : compilation en echec"
    # the build: c139, hybrid-ui-vo. WITHOUT -j: the TMS470 under Wine writes
    # temporary files with fixed names, two parallel cl470 step on each other.
    # THE BENCH VARIANT: DWNLD 0 (FC_MAGNETITE_DWNLD), -nopatch directory. The DSP
    # patch downloaded by the TI L1 (DWNLD 1) fails under the emulation
    # (LA_LoadPage: race on LA_TIMEOUT); the bench runs on this build, checked
    # byte for byte against c139-flash.img. L1_DYN_DSP_DWNLD stays at 1 (at 0,
    # l1audio_async.c does not compile). FC_MAGNETITE_DWNLD=1: the original build.
    local dwnld="${FC_MAGNETITE_DWNLD:-0}" suf="" b
    [ "$dwnld" = 0 ] && suf="-nopatch"
    b="$fcm/build-c139-hybrid-ui-vo$suf"
    if [ ! -s "$b/fwimage.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
        ( cd "$fcm" && (cd helpers && make) && ./configure.sh --clean c139 hybrid-ui-vo ${suf:+SUFFIX=$suf} \
            && sed -i "s/^#define DWNLD [01]\$/#define DWNLD $dwnld/" "$b/config/swconfig.cfg" \
            && cd "$b" && WINEDEBUG=-all make ) \
            >>"$log" 2>&1 || { _fw_err "compilation Magnetite en echec (voir $log)"; return 1; }
    fi
    _fw_ok "fwimage.bin (DWNLD $dwnld) : $(stat -c %s "$b/fwimage.bin") octets, $b"
    # the 4 MiB flash image: FreeCalypso Compal bootloader at 0, fwimage.bin at
    # 0x10000, FFS at 0x3C0000 (IMEI, afcparams, rfcap written by fc-fsio). An
    # EXISTING image only changes its firmware area: the bench bootloader and FFS
    # stay as they are (the bootloader area of the bench image differs by 4 bytes
    # from the FreeCalypso file, at vector 0x10; the bench boots with it). The old
    # image is copied to .avant-supplement.
    _fc_env compal-flash-boot-for-fc.bin "$bdl/compal-flash-boot-for-fc.bin" \
        || _fw_warn "bootloader Compal : telechargement en echec"
    [ -f "$out/c139-flash.img" ] && cp -p "$out/c139-flash.img" "$out/c139-flash.img.avant-supplement"
    python3 - "$bdl/compal-flash-boot-for-fc.bin" "$b/fwimage.bin" "$out/c139-flash.img" <<'EOF' \
        && _fw_ok "image flash $out/c139-flash.img" || _fw_err "assemblage de l image flash en echec"
import os, sys
boot, fw, img_path = sys.argv[1:4]
f = open(fw, "rb").read()
if os.path.exists(img_path) and os.path.getsize(img_path) == 4 << 20:
    img = bytearray(open(img_path, "rb").read())              # bench bootloader + FFS kept
    img[0x10000:0x3C0000] = b"\xff" * (0x3C0000 - 0x10000)
else:
    img = bytearray(b"\xff" * (4 << 20))
    b = open(boot, "rb").read(); img[0:len(b)] = b
img[0x10000:0x10000 + len(f)] = f
open(img_path, "wb").write(img)
EOF
    echo -e "  ${CYAN}→${NC} lancer : ${BOLD}./start.sh --bts-classique --ms-magnetite --gapk${NC} (appels : ENCRYPTION=\"a5 0\" et --regen)"
}

# ── osmocom-bb-trx ───────────────────────────────────────────────────────────
osmo_trx_install() {
    echo -e "${BOLD}== osmocom-bb-trx (jolly/testing, TX) ==${NC}"
    # host side (layer23 --enable-transceiver, libosmocore 1.1.0): the published
    # image (github.com/bbaranoff/osmocom-bb-trx, ubuntu 16.04 + gcc 4.9/5 + gnuarm)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker pull "$OSMOCOM_BB_TRX_IMAGE" >>"$(_fw_log trx)" 2>&1; then _fw_ok "image $OSMOCOM_BB_TRX_IMAGE"
        else _fw_warn "docker pull $OSMOCOM_BB_TRX_IMAGE en echec (voir $(_fw_log trx))"; fi
    else
        _fw_warn "docker absent ou arrete : l image osmocom-bb-trx n est pas tiree (addition.sh --docker)"
    fi
    # the trx firmware, with the gnuarm toolchain, in a separate tree (the bench
    # one, osmocom-bb-transceiver, keeps its patches and is not touched)
    osmo_gnuarm_install || return 1
    local t="$GSM_ROOT/osmocom-bb-trx" log; log="$(_fw_log trx)"
    _fw_apt autoconf automake libtool pkg-config python3 git   # libosmocore cote cible
    _fw_clone https://gitea.osmocom.org/phone-side/osmocom-bb "$t" jolly/testing || return 1
    sed -i 's/^#CFLAGS += -DCONFIG_TX_ENABLE/CFLAGS += -DCONFIG_TX_ENABLE/' "$t/src/target/firmware/Makefile"
    _fw_bb_corriger "$t/src/target/firmware"
    if [ ! -s "$t/src/target/firmware/board/compal_e88/trx.highram.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
        ( cd "$t/src" && PATH="$GNUARM_DIR/install/bin:$PATH" make -j"$OSMO_FW_JOBS" firmware ) >>"$log" 2>&1 \
            || { _fw_err "firmware trx en echec (voir $log)"; return 1; }
    fi
    if [ -s "$t/src/target/firmware/board/compal_e88/trx.highram.bin" ]; then
        _fw_ok "firmware trx (TX) : $t/src/target/firmware/board/compal_e88/trx.{highram,e88loader,e88flash}.bin"
    else
        _fw_err "trx.highram.bin absent apres make (voir $log)"; return 1
    fi
}

# ── bench Calypso firmware (layer1 GPRS, rssi...) with gnuarm ───────────────
# Rebuilds the bench osmocom-bb tree (OSMOCOM_BB_REF + patches/osmocom-bb-*.patch,
# including the GPRS layer1) with arm-elf-gcc 4.5.2: "cd src && make", the whole
# tree (host tools, target libosmocore, firmware). layer1 only exists in highram:
# with the PDCH it no longer fits in the 64 KB of the Compal loader
# (target/firmware/Makefile). OSMO_FW_INSTALLER=1 installs layer1/rssi
# .highram.{elf,bin} in /opt/GSM/firmware, layer1 also under the name
# layer1.highram.gprs.* (the one dsp-rom-max.sh and egprs-dsp.sh read); the
# previous ones remain as .avant-<date>.
OSMOCOM_BB_REF="${OSMOCOM_BB_REF:-eac4eed1}"
osmo_calypso_fw_install() {
    echo -e "${BOLD}== firmware Calypso du banc (osmocom-bb, gnuarm) ==${NC}"
    osmo_gnuarm_install || return 1
    local t="$GSM_ROOT/osmocom-bb" fw log; log="$(_fw_log calypso-fw)"
    _fw_apt autoconf automake libtool pkg-config python3 git
    if [ ! -d "$t/.git" ]; then
        _fw_clone https://gitea.osmocom.org/phone-side/osmocom-bb "$t" || return 1
        git -C "$t" checkout -q "$OSMOCOM_BB_REF" && _fw_ok "osmocom-bb epingle sur $OSMOCOM_BB_REF"
    fi
    OSMO_PATCHES_ONLY=osmocom-bb GSM_ROOT="$GSM_ROOT" REPO="$REPO" bash "$REPO/tools/osmo-patches-apply.sh" "$GSM_ROOT" \
        || _fw_warn "un correctif osmocom-bb ne s applique pas (ci-dessus)"
    fw="$t/src/target/firmware"
    _fw_bb_corriger "$fw"
    if ( cd "$t/src" && PATH="$GNUARM_DIR/install/bin:$PATH" make -j"$OSMO_FW_JOBS" ) >>"$log" 2>&1; then
        _fw_ok "osmocom-bb : make complet dans $t/src (gnuarm)"
    else
        _fw_err "make dans $t/src en echec (voir $log)"; return 1
    fi
    local b="$fw/board/compal_e88" ok=1 a
    for a in layer1 rssi; do
        if [ -s "$b/$a.highram.bin" ]; then _fw_ok "$a.highram.bin ($b)"; else _fw_err "$a.highram.bin absent (voir $log)"; ok=0; fi
    done
    if [ "$ok" = 1 ] && [ "${OSMO_FW_INSTALLER:-0}" = 1 ]; then
        local dst="$GSM_ROOT/firmware/board/compal_e88" d n x; d="$(date +%Y%m%d-%H%M)"
        mkdir -p "$dst"
        for a in layer1 rssi; do
            for n in "$a.highram" $([ "$a" = layer1 ] && echo layer1.highram.gprs); do
                for x in elf bin; do
                    [ -f "$dst/$n.$x" ] && cp -p "$dst/$n.$x" "$dst/$n.$x.avant-$d"
                    cp -f "$b/$a.highram.$x" "$dst/$n.$x"
                done
            done
        done
        _fw_ok "pose dans $dst (anciens en .avant-$d)"
    elif [ "$ok" = 1 ]; then
        echo -e "  ${CYAN}→${NC} le banc garde le firmware livre ; OSMO_FW_INSTALLER=1 pour poser celui-ci dans $GSM_ROOT/firmware"
    fi
    [ "$ok" = 1 ]
}

# ── Fernvale (MT6260) ────────────────────────────────────────────────────────
osmo_fernvale_install() {
    echo -e "${BOLD}== Fernvale (MediaTek MT6260) ==${NC}"
    local log; log="$(_fw_log fernvale)"
    _fw_apt gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi build-essential \
            libusb-1.0-0-dev genromfs python3 autoconf automake libtool pkg-config git \
        || _fw_warn "paquets arm-none-eabi : installation incomplete (voir $(_fw_log apt))"
    local fl="$GSM_ROOT/fernly" nx="$GSM_ROOT/fernvale-nuttx" mtk="$GSM_ROOT/osmocom-bb-mtk-layer1"
    _fw_clone https://github.com/bbaranoff/fernly "$fl"
    _fw_clone https://github.com/bbaranoff/fernvale-nuttx "$nx"
    _fw_clone https://github.com/bbaranoff/osmocom-bb-mtk-layer1 "$mtk" mtk-layer1
    # fernly: the reverse-engineering OS and its USB loader (fernly-usb-loader, native)
    if [ -d "$fl" ]; then
        if ( cd "$fl" && make CROSS_COMPILE=arm-none-eabi- ) >>"$log" 2>&1; then
            _fw_ok "fernly : $fl/build/firmware.bin + fernly-usb-loader"
        else _fw_err "fernly : make en echec (voir $log)"; fi
        [ -f "$fl/95-fernvale-test.rules" ] && install -D -m644 "$fl/95-fernvale-test.rules" /etc/udev/rules.d/95-fernvale-test.rules \
            && udevadm control --reload 2>/dev/null; true
    fi
    # NuttX (kosagi-fernvale/nsh): the build fixes are already in the repository
    if [ -d "$nx/nuttx" ]; then
        if [ ! -s "$nx/nuttx/nuttx.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
            ( cd "$nx/nuttx/tools" && ./configure.sh kosagi-fernvale/nsh && cd .. \
                && make CROSSDEV=arm-none-eabi- ARCROSSDEV=arm-none-eabi- ) >>"$log" 2>&1 \
                || _fw_err "NuttX : make en echec (voir $log)"
        fi
        [ -s "$nx/nuttx/nuttx.bin" ] && _fw_ok "NuttX : $nx/nuttx/nuttx.bin"
    fi
    # osmocom-bb layer1 MTK (bringup + layer1 MT6260)
    if [ -d "$mtk/src" ]; then
        _fw_bb_corriger "$mtk/src/target/firmware"
        if ( cd "$mtk/src" && make mtk-firmware CROSS_HOST=arm-none-eabi ) >>"$log" 2>&1 \
           && [ -s "$mtk/src/target/firmware/board/fernvale/layer1.mt6260.bin" ]; then
            _fw_ok "layer1 MTK : $mtk/src/target/firmware/board/fernvale/{bringup,layer1}.mt6260.bin"
        else _fw_err "layer1 MTK : make mtk-firmware en echec (voir $log)"; fi
    fi
    echo -e "  ${CYAN}→${NC} charger : ${BOLD}$fl/build/fernly-usb-loader -s /dev/fernvale $fl/build/usb-loader.bin <payload.bin>${NC}"
}

# ── SIMCom ───────────────────────────────────────────────────────────────────
osmo_simcom_install() {
    echo -e "${BOLD}== SIMCom : documentation et SDK ==${NC}"
    # ~3.4 GB (rar archives of the SDKs, reports): a clone without history
    local d="$GSM_ROOT/simcom"
    if [ -d "$d/.git" ]; then _fw_ok "simcom deja present ($d)"; return 0; fi
    git clone -q --depth 1 https://github.com/bbaranoff/simcom "$d" >>"$(_fw_log git)" 2>&1 \
        && _fw_ok "simcom clone dans $d ($(du -sh "$d" 2>/dev/null | cut -f1))" \
        || _fw_err "clone de bbaranoff/simcom en echec"
    _fw_apt p7zip-full unrar 2>/dev/null || true   # the SDKs ship as .rar / .7z
}
