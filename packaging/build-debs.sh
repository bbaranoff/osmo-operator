#!/bin/bash
# =============================================================================
#  packaging/build-debs.sh - un paquet .deb par composant du banc
# =============================================================================
#
#      osmo-operator     ce depot, tel quel, en /opt/GSM/osmo-operator
#                        (+ menu, icones, /usr/bin/osmo-start-direct)
#      pont              pont/ - le transceiver Python (pont/pont.py)
#      qemu-calypso      qosmo-grgsm : qemu-system-arm (machine calypso),
#                        run.sh + run_modules + environnement + cfgs +
#                        tmux_modules + keymaps, en /opt/GSM/qosmo-grgsm
#      calypso-firmware  /opt/GSM/firmware/board/compal_e88/layer1.highram.*
#
#  Les chemins d installation sont CEUX du banc (/opt/GSM/...) : tout le depot
#  les nomme en dur (bench.env, start-direct.sh, les unites systemd), et c est
#  ce qui permet a une machine installee par paquets de tourner exactement
#  comme l ISO. Le prix : un paquet refuse de s installer par-dessus un clone
#  git au meme endroit (preinst) - on ne melange pas un arbre gere par git et
#  un arbre gere par dpkg.
#
#      ./build-debs.sh                   les quatre, dans packaging/dist/
#      ./build-debs.sh --only pont,calypso-firmware
#      ./build-debs.sh --out /tmp/debs
#      ./build-debs.sh --no-strip        garde les symboles de qemu-system-arm
#
#  Outils : dpkg-deb (dpkg), git, strip (binutils, sinon --no-strip), ldd.
#  Pas de debhelper : chaque paquet est un arbre + DEBIAN/control construit a
#  la main, avec --root-owner-group (pas besoin de fakeroot).
#
#  Sources, surchargeables par l environnement :
#      OSMO_OPERATOR_SRC  (defaut : le depot qui contient ce script)
#      QOSMO_SRC          (defaut : /opt/GSM/qosmo-grgsm)
#      FIRMWARE_SRC       (defaut : /opt/GSM/firmware)
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OSMO_OPERATOR_SRC:=$(cd "$HERE/.." && pwd)}"
: "${QOSMO_SRC:=/opt/GSM/qosmo-grgsm}"
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

# Version = 0.1+git<date du dernier commit>.<hash court> de l arbre source.
# Deux constructions du meme commit donnent le meme numero : c est voulu.
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

# preinst commun : refuse un clone git au meme endroit (sauf mise a jour du
# paquet lui-meme, ou dpkg passe "upgrade").
write_preinst_guard() {   # $1=DEBIAN dir  $2=chemin installe
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

write_control() {   # $1=DEBIAN dir, puis champs sur stdin
    cat > "$1/control"
}

installed_size() { du -sk --exclude=DEBIAN "$1" | cut -f1; }

build_pkg() {   # $1=staging  $2=nom  $3=version  $4=arch
    printf 'Installed-Size: %s\n' "$(installed_size "$1")" >> "$1/DEBIAN/control"
    find "$1" -path "$1/DEBIAN" -prune -o -type d -exec chmod 755 {} + 2>/dev/null || true
    dpkg-deb --build --root-owner-group "$1" "$OUT/${2}_${3}_${4}.deb" >/dev/null
    echo "  $OUT/${2}_${3}_${4}.deb  ($(du -h "$OUT/${2}_${3}_${4}.deb" | cut -f1))"
}

# Dependances runtime d un binaire, par ldd -> dpkg -S. Les bibliotheques que
# dpkg ne connait pas (/usr/local/lib) sont ignorees : elles ne viennent d aucun
# paquet, donc aucun paquet ne peut les garantir.
shlib_depends() {
    # ldd rend /lib/x86_64-linux-gnu/... ; sur un systeme a /usr fusionne dpkg
    # ne connait souvent que /usr/lib/... : on tente les deux. Tout est en
    # "|| true" : sous pipefail, une seule bibliotheque inconnue faisait
    # echouer la substitution entiere, et set -e arretait le script.
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
    ln -s /opt/GSM/osmo-operator/start-direct.sh "$P/usr/bin/osmo-start-direct"
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
 Le depot osmo-operator installe en /opt/GSM/osmo-operator : start-direct.sh
 (lanceur natif, qui delegue a qosmo-grgsm/run.sh), les gabarits de
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
    install -m644 "$OSMO_OPERATOR_SRC/pont/README.md" "$D/" 2>/dev/null || true
    chmod 755 "$D/pont.py"
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
Description: pont TRX entre osmo-bts-trx et le Calypso emule (qosmo-grgsm)
 Transceiver TRX-UDP en Python : se presente a osmo-bts-trx sur 5700-5702,
 decode le descendant vers GSMTAP 4730/4731 (lu par le modele QEMU) et encode
 le montant depuis les sidebands /dev/shm/calypso_*. Installe en
 /opt/GSM/osmo-operator/pont, la ou start-direct.sh l attend (PONT_PY).
 Requiert libosmocoding (libosmocore) accessible par ld.so - fournie par la
 pile Osmocom, pas par un paquet Debian.
CTL
    build_pkg "$P" pont "$V" all
fi

# ── qemu-calypso ────────────────────────────────────────────────────────────
if wanted qemu-calypso; then
    BIN="$QOSMO_SRC/build/qemu-system-arm"
    [ -x "$BIN" ] || { echo "qemu-system-arm absent : $BIN (construisez qosmo-grgsm d abord)" >&2; exit 1; }
    V="$(tree_version "$QOSMO_SRC")"
    P="$WORK/qemu-calypso"; D="$P/opt/GSM/qosmo-grgsm"
    mkdir -p "$D/build" "$D/share/qemu" "$P/DEBIAN"
    for d in run_modules environnement cfgs tmux_modules opt-gsm-scripts; do
        [ -d "$QOSMO_SRC/$d" ] || continue
        tar -C "$QOSMO_SRC" --exclude='__pycache__' -cf - "$d" | tar -C "$D" -xf -
    done
    install -m755 "$QOSMO_SRC/run.sh" "$D/run.sh"
    for f in LICENSE COPYING; do [ -f "$QOSMO_SRC/$f" ] && install -m644 "$QOSMO_SRC/$f" "$D/$f"; done
    # Le binaire reste en build/ : bench.env le nomme la (QEMU_BIN), et QEMU
    # calcule son datadir PAR RAPPORT au binaire (build/../share/qemu) - d ou
    # les keymaps en share/qemu/keymaps, sinon "could not read keymap file".
    install -m755 "$BIN" "$D/build/qemu-system-arm"
    if [ "$STRIP" = 1 ] && command -v strip >/dev/null 2>&1; then
        strip --strip-unneeded "$D/build/qemu-system-arm" || true
    fi
    # Lanceur C qosmo-grgsm (tools/qosmo-launch) : c'est lui que 40-qemu.sh
    # appelle a la place de qemu-system-arm. Compile dans son dossier, livre
    # dans /usr/local/bin sous le nom du fork ; la source part avec l'arbre.
    if [ -f "$QOSMO_SRC/tools/qosmo-launch/qosmo-launch.c" ]; then
        mkdir -p "$D/tools/qosmo-launch" "$P/usr/local/bin"
        install -m644 "$QOSMO_SRC/tools/qosmo-launch/qosmo-launch.c" "$QOSMO_SRC/tools/qosmo-launch/Makefile" "$D/tools/qosmo-launch/"
        make -s -C "$QOSMO_SRC/tools/qosmo-launch" qosmo-grgsm >/dev/null \
            || { echo "compilation du lanceur qosmo-grgsm echouee ($QOSMO_SRC/tools/qosmo-launch)" >&2; exit 1; }
        install -m755 "$QOSMO_SRC/tools/qosmo-launch/qosmo-grgsm" "$P/usr/local/bin/qosmo-grgsm"
    fi
    # Console gdb en telnet (run_modules/44-gdb-telnet.sh) : le serveur, le
    # generateur du panneau et le panneau genere. gdb-multiarch et telnet
    # passent en Depends : sans eux le module se declare en echec (non bloquant).
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
    write_preinst_guard "$P/DEBIAN" /opt/GSM/qosmo-grgsm
    write_control "$P/DEBIAN" <<CTL
Package: qemu-calypso
Version: $V
Section: otherosfs
Priority: optional
Architecture: $ARCH_HOST
Maintainer: $MAINT
Depends: ${DEPS:+$DEPS, }bash, socat, tmux, tcpdump, procps, psmisc, gawk, python3, iproute2, gdb-multiarch, telnet
Recommends: osmo-operator, calypso-firmware
Homepage: https://github.com/bbaranoff/qosmo-grgsm
Description: QEMU avec la machine calypso (telephone Osmocom-BB emule) et son lanceur
 qemu-system-arm construit depuis qosmo-grgsm, avec le modele de SoC Calypso
 (ARM946, TPU/TSP, SIM, couche 1 gr-gsm), le lanceur run.sh et ses modules
 (run_modules/), l environnement du banc (environnement/bench.env), les
 configurations du mobile (cfgs/) et les dispositions tmux. Installe en
 /opt/GSM/qosmo-grgsm, sans les sources ni l arbre de construction.
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
