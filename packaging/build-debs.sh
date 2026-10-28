#!/bin/bash
# =============================================================================
#  packaging/build-debs.sh - one .deb package per bench component
# =============================================================================
#
#      osmo-operator     this repo, as is, in /opt/GSM/osmo-operator
#                        (+ menu, icons, /usr/bin/osmo-start-direct)
#      pont              pont/ - the Python transceiver (pont/pont.py)
#      qemu-calypso      qosmo: qemu-system-arm (calypso machine),
#                        run.sh + run_modules + environment + cfgs +
#                        tmux_modules + keymaps, in /opt/GSM/qosmo
#      calypso-firmware  /opt/GSM/firmware/board/compal_e88/layer1.highram.*
#
#  The install paths are THOSE of the bench (/opt/GSM/...): the whole repo
#  hardcodes them (bench.env, start-native.sh, the systemd units), and this
#  is what lets a machine installed from packages run exactly like the ISO.
#  The price: a package refuses to install over a git clone at the same
#  place (preinst) - a git-managed tree and a dpkg-managed tree are not
#  mixed.
#
#      ./build-debs.sh                   all four, into packaging/dist/
#      ./build-debs.sh --only pont,calypso-firmware
#      ./build-debs.sh --out /tmp/debs
#      ./build-debs.sh --no-strip        keeps the qemu-system-arm symbols
#
#  Tools: dpkg-deb (dpkg), git, strip (binutils, otherwise --no-strip), ldd.
#  No debhelper: each package is a tree + DEBIAN/control built by hand, with
#  --root-owner-group (no fakeroot needed).
#
#  Sources, overridable from the environment:
#      OSMO_OPERATOR_SRC  (default: the repo containing this script)
#      QOSMO_SRC          (default: /opt/GSM/qosmo)
#      FIRMWARE_SRC       (default: /opt/GSM/firmware)
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OSMO_OPERATOR_SRC:=$(cd "$HERE/.." && pwd)}"
: "${QOSMO_SRC:=/opt/GSM/qosmo}"
: "${FIRMWARE_SRC:=/opt/GSM/firmware}"
OUT="$HERE/dist"
ONLY=""
STRIP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="${2:?}"; shift ;;
        --out=*)    OUT="${1#*=}" ;;
        --only)     ONLY="${2:?}"; shift ;;
        --only=*)   ONLY="${1#*=}" ;;
        --no-strip) STRIP=0 ;;
        -h|--help)  sed -n '2,33p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done
for t in dpkg-deb git; do
    command -v "$t" >/dev/null 2>&1 || { echo "outil manquant : $t" >&2; exit 1; }
done
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/osmo-debs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MAINT="osmo-operator <bastienbaranoff@gmail.com>"
ARCH_HOST="$(dpkg --print-architecture)"

wanted() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }

# Version = 0.1+git<last commit date>.<short hash> of the source tree.
# Two builds of the same commit give the same number: this is intended.
tree_version() {
    local d="$1"
    if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '0.1+git%s.%s' \
            "$(git -C "$d" log -1 --format=%cd --date=format:%Y%m%d)" \
            "$(git -C "$d" rev-parse --short HEAD)"
    else
        printf '0.1+local%s' "$(date +%Y%m%d)"
    fi
}

# Shared preinst: refuses a git clone at the same place (except when upgrading
# the package itself, where dpkg passes "upgrade").
write_preinst_guard() {   # $1=DEBIAN dir  $2=installed path
    cat > "$1/preinst" <<PRE
#!/bin/sh
set -e
if [ "\$1" = install ] && [ -d "$2/.git" ]; then
    echo "$2 est un clone git : ce paquet ne s installe pas par-dessus." >&2
    echo "Deplacez ce clone (ou supprimez-le) avant d installer le paquet." >&2
    exit 1
fi
exit 0
PRE
    chmod 755 "$1/preinst"
}

write_control() {   # $1=DEBIAN dir, then fields on stdin
    cat > "$1/control"
}

installed_size() { du -sk --exclude=DEBIAN "$1" | cut -f1; }

build_pkg() {   # $1=staging  $2=nom  $3=version  $4=arch
    printf 'Installed-Size: %s\n' "$(installed_size "$1")" >> "$1/DEBIAN/control"
    find "$1" -path "$1/DEBIAN" -prune -o -type d -exec chmod 755 {} + 2>/dev/null || true
    dpkg-deb --build --root-owner-group "$1" "$OUT/${2}_${3}_${4}.deb" >/dev/null
    echo "  $OUT/${2}_${3}_${4}.deb  ($(du -h "$OUT/${2}_${3}_${4}.deb" | cut -f1))"
}

# Runtime dependencies of a binary, via ldd -> dpkg -S. Libraries unknown to
# dpkg (/usr/local/lib) are ignored: they come from no package, so no package
# can guarantee them.
shlib_depends() {
    # ldd returns /lib/x86_64-linux-gnu/...; on a merged-/usr system dpkg often
    # only knows /usr/lib/...: both are tried. Everything is "|| true": under
    # pipefail a single unknown library would fail the whole substitution and
    # set -e would stop the script.
    local so
    { ldd "$1" 2>/dev/null | awk '/=> \//{print $3}' || true; } | while read -r so; do
        { dpkg -S "$so" 2>/dev/null || dpkg -S "/usr$so" 2>/dev/null || true; } | cut -d: -f1 | head -1
    done | grep -v '^$' | sort -u | paste -sd, - | sed 's/,/, /g' || true
}

# ── osmo-operator ───────────────────────────────────────────────────────────
if wanted osmo-operator; then
    V="$(tree_version "$OSMO_OPERATOR_SRC")"
    P="$WORK/osmo-operator"; D="$P/opt/GSM/osmo-operator"
    mkdir -p "$D" "$P/DEBIAN" "$P/usr/bin" "$P/usr/share/applications" \
             "$P/usr/share/osmo-operator/icons" "$P/usr/share/icons/hicolor/scalable/apps"
    tar -C "$OSMO_OPERATOR_SRC" \
        --exclude=.git --exclude=./pont --exclude=./packaging/dist \
        --exclude='__pycache__' --exclude='*.iso' --exclude='vty-debug-dump-*' \
        -cf - . | tar -C "$D" -xf -
    ln -s /opt/GSM/osmo-operator/start-native.sh "$P/usr/bin/osmo-start-native"
    ln -s /opt/GSM/osmo-operator/start-native.sh "$P/usr/bin/osmo-start-direct"   # ancien nom
    for e in osmo-launch osmo-multi; do
        install -m644 "$OSMO_OPERATOR_SRC/data/desktop/$e.desktop" "$P/usr/share/applications/$e.desktop"
        install -m644 "$OSMO_OPERATOR_SRC/data/$e.svg" "$P/usr/share/osmo-operator/icons/$e.svg"
        install -m644 "$OSMO_OPERATOR_SRC/data/$e.svg" "$P/usr/share/icons/hicolor/scalable/apps/$e.svg"
    done
    install -m644 "$OSMO_OPERATOR_SRC/data/osmo-tutorial.svg" "$P/usr/share/osmo-operator/icons/" 2>/dev/null || true
    install -m644 "$OSMO_OPERATOR_SRC/data/tutorial.html" "$P/usr/share/osmo-operator/" 2>/dev/null || true
    write_preinst_guard "$P/DEBIAN" /opt/GSM/osmo-operator
    cat > "$P/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor || true
exit 0
POST
    chmod 755 "$P/DEBIAN/postinst"
    write_control "$P/DEBIAN" <<CTL
Package: osmo-operator
Version: $V
Section: net
Priority: optional
Architecture: all
Maintainer: $MAINT
Depends: bash, python3, socat, netcat-openbsd, tcpdump, tmux, expect, whiptail, iproute2, sqlite3, git, pont (>= 0.1), qemu-calypso, calypso-firmware
Recommends: pulseaudio, pulseaudio-utils, asterisk, wireshark
Homepage: https://github.com/bbaranoff/osmo-operator
Description: banc GSM/EGPRS Osmocom - lanceur, configurations, outils
 Le depot osmo-operator installe en /opt/GSM/osmo-operator : start-native.sh
 (lanceur natif, qui delegue a qosmo/run.sh), les gabarits de
 configuration Osmocom et Asterisk, les scripts reseau/WAN/SS7, les checks, le
 menu et les icones du bureau. Les demons Osmocom eux-memes (osmo-stp, hlr,
 msc, bsc, bts...) ne sont pas dans ce paquet : ils viennent du depot Osmocom
 ou d une compilation locale (/usr/local).
CTL
    build_pkg "$P" osmo-operator "$V" all
fi

# ── pont ────────────────────────────────────────────────────────────────────
if wanted pont; then
    V="$(tree_version "$OSMO_OPERATOR_SRC")"
    P="$WORK/pont"; D="$P/opt/GSM/osmo-operator/pont"
    mkdir -p "$D" "$P/DEBIAN"
    install -m644 "$OSMO_OPERATOR_SRC"/pont/*.py "$D/"
    # The DSP bridge (pont_dsp.py -> pont.dsp.main).
    mkdir -p "$D/dsp"
    install -m644 "$OSMO_OPERATOR_SRC"/pont/dsp/*.py "$D/dsp/"
    install -m644 "$OSMO_OPERATOR_SRC/pont/README.md" "$D/" 2>/dev/null || true
    chmod 755 "$D/pont.py" "$D/pont_dsp.py"
    write_preinst_guard "$P/DEBIAN" /opt/GSM/osmo-operator
    write_control "$P/DEBIAN" <<CTL
Package: pont
Version: $V
Section: net
Priority: optional
Architecture: all
Maintainer: $MAINT
Depends: python3 (>= 3.10), python3-numpy
Enhances: osmo-operator
Homepage: https://github.com/bbaranoff/osmo-operator
Description: pont TRX entre osmo-bts-trx et le Calypso emule (qosmo)
 Transceiver TRX-UDP en Python : se presente a osmo-bts-trx sur 5700-5702,
 decode le descendant vers GSMTAP 4730/4731 (lu par le modele QEMU) et encode
 le montant depuis les sidebands /dev/shm/calypso_*. Installe en
 /opt/GSM/osmo-operator/pont, la ou start-native.sh l attend (PONT_PY).
 Requiert libosmocoding (libosmocore) accessible par ld.so - fournie par la
 pile Osmocom, pas par un paquet Debian.
CTL
    build_pkg "$P" pont "$V" all
fi

# ── qemu-calypso ────────────────────────────────────────────────────────────
if wanted qemu-calypso; then
    BIN="$QOSMO_SRC/build/qemu-system-arm"
    [ -x "$BIN" ] || { echo "qemu-system-arm absent : $BIN (construisez qosmo d abord)" >&2; exit 1; }
    V="$(tree_version "$QOSMO_SRC")"
    P="$WORK/qemu-calypso"; D="$P/opt/GSM/qosmo"
    mkdir -p "$D/build" "$D/share/qemu" "$P/DEBIAN"
    for d in run_modules environnement cfgs tmux_modules opt-gsm-scripts; do
        [ -d "$QOSMO_SRC/$d" ] || continue
        tar -C "$QOSMO_SRC" --exclude='__pycache__' -cf - "$d" | tar -C "$D" -xf -
    done
    install -m755 "$QOSMO_SRC/run.sh" "$D/run.sh"
    for f in LICENSE COPYING; do [ -f "$QOSMO_SRC/$f" ] && install -m644 "$QOSMO_SRC/$f" "$D/$f"; done
    # The binary stays in build/: bench.env names it there (QEMU_BIN), and QEMU
    # computes its datadir RELATIVE to the binary (build/../share/qemu) - hence
    # the keymaps in share/qemu/keymaps, otherwise "could not read keymap file".
    install -m755 "$BIN" "$D/build/qemu-system-arm"
    if [ "$STRIP" = 1 ] && command -v strip >/dev/null 2>&1; then
        strip --strip-unneeded "$D/build/qemu-system-arm" || true
    fi
    # qosmo C launcher (tools/qosmo-launch): the one 40-qemu.sh calls instead
    # of qemu-system-arm. Compiled in its folder, shipped as
    # /usr/local/bin/qosmo; the source goes with the tree.
    if [ -f "$QOSMO_SRC/tools/qosmo-launch/qosmo-launch.c" ]; then
        mkdir -p "$D/tools/qosmo-launch" "$P/usr/local/bin"
        install -m644 "$QOSMO_SRC/tools/qosmo-launch/qosmo-launch.c" "$QOSMO_SRC/tools/qosmo-launch/Makefile" "$D/tools/qosmo-launch/"
        make -s -C "$QOSMO_SRC/tools/qosmo-launch" ALIAS=qosmo TREE=/opt/GSM/qosmo qosmo >/dev/null \
            || { echo "compilation du lanceur qosmo echouee ($QOSMO_SRC/tools/qosmo-launch)" >&2; exit 1; }
        install -m755 "$QOSMO_SRC/tools/qosmo-launch/qosmo" "$P/usr/local/bin/qosmo"
    fi
    # gdb console over telnet (run_modules/44-gdb-telnet.sh): the server, the
    # panel generator and the generated panel. gdb-multiarch and telnet go in
    # Depends: without them the module reports failure (non-blocking).
    if [ -f "$QOSMO_SRC/tools/gdb-telnet.py" ]; then
        install -m755 "$QOSMO_SRC/tools/gdb-telnet.py" "$D/tools/gdb-telnet.py"
        install -m755 "$QOSMO_SRC/tools/gdb_cmd.sh" "$D/tools/gdb_cmd.sh"
        (cd "$D/tools" && bash ./gdb_cmd.sh >/dev/null) || { echo "gdb_cmd.sh : generation de cmd.gdb echouee" >&2; exit 1; }
    fi
    km=""
    for c in "$QOSMO_SRC/build/pc-bios/keymaps" "$QOSMO_SRC/pc-bios/keymaps" \
             /opt/GSM/qemu-install/share/qemu/keymaps /usr/share/qemu/keymaps; do
        [ -f "$c/en-us" ] && { km="$c"; break; }
    done
    [ -n "$km" ] || { echo "keymaps QEMU introuvables (en-us)" >&2; exit 1; }
    cp -a "$km" "$D/share/qemu/keymaps"
    DEPS="$(shlib_depends "$D/build/qemu-system-arm")"
    write_preinst_guard "$P/DEBIAN" /opt/GSM/qosmo
    write_control "$P/DEBIAN" <<CTL
Package: qemu-calypso
Version: $V
Section: otherosfs
Priority: optional
Architecture: $ARCH_HOST
Maintainer: $MAINT
Depends: ${DEPS:+$DEPS, }bash, socat, tmux, tcpdump, procps, psmisc, gawk, python3, iproute2, gdb-multiarch, telnet
Recommends: osmo-operator, calypso-firmware
Homepage: https://github.com/bbaranoff/qosmO
Description: QEMU avec la machine calypso (telephone Osmocom-BB emule) et son lanceur
 qemu-system-arm construit depuis qosmo, avec le modele de SoC Calypso
 (ARM946, TPU/TSP, SIM, couche 1 gr-gsm), le lanceur run.sh et ses modules
 (run_modules/), l environnement du banc (environnement/bench.env), les
 configurations du mobile (cfgs/) et les dispositions tmux. Installe en
 /opt/GSM/qosmo, sans les sources ni l arbre de construction.
CTL
    build_pkg "$P" qemu-calypso "$V" "$ARCH_HOST"
fi

# ── calypso-firmware ────────────────────────────────────────────────────────
if wanted calypso-firmware; then
    FW="$FIRMWARE_SRC/board/compal_e88"
    [ -f "$FW/layer1.highram.elf" ] || { echo "firmware absent : $FW/layer1.highram.elf" >&2; exit 1; }
    V="$(tree_version "$FIRMWARE_SRC")"
    P="$WORK/calypso-firmware"; D="$P/opt/GSM/firmware/board/compal_e88"
    mkdir -p "$D" "$P/DEBIAN"
    install -m644 "$FW/layer1.highram.elf" "$FW/layer1.highram.bin" "$D/"
    [ -f "$FIRMWARE_SRC/COPYING" ] && install -m644 "$FIRMWARE_SRC/COPYING" "$P/opt/GSM/firmware/COPYING"
    write_preinst_guard "$P/DEBIAN" /opt/GSM/firmware
    write_control "$P/DEBIAN" <<CTL
Package: calypso-firmware
Version: $V
Section: misc
Priority: optional
Architecture: all
Maintainer: $MAINT
Homepage: https://github.com/bbaranoff/firmware
Description: firmware layer1 Osmocom-BB (compal_e88) pour le Calypso emule
 layer1.highram.elf (charge par qemu-system-arm -kernel) et layer1.highram.bin
 (envoye par osmocon), pre-compiles depuis osmocom-bb. Chemin fixe attendu par
 bench.env : /opt/GSM/firmware/board/compal_e88/.
CTL
    build_pkg "$P" calypso-firmware "$V" all
fi
echo "termine : $OUT"
