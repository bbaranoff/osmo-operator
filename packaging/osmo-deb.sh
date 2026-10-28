#!/bin/bash
# =============================================================================
#  osmo-deb - one .deb per compiled folder, kept in cache, reinstalled at rebuild
# =============================================================================
#
#  PRINCIPLE. Everything compiled in the image (libosmocore, osmo-*, gapk,
#  QEMU, osmocom-bb, gr-gsm...) comes out as a .deb package, stored in
#      /var/cache/osmo-debs/osmo-build-<name>_<version>~<suite>_<arch>.deb
#  At the next rebuild, if the package is there, it is installed (dpkg -i)
#  instead of re-cloning and recompiling. The cache lives ON THE HOST
#  (/var/cache/osmo-debs): build.sh copies it into the context (.deb-cache/)
#  before `docker build`, and brings back the packages the image produced.
#
#  Three verbs:
#
#    osmo-deb install <name> <version>
#        Installs the cached .deb if it exists. Exits 0 in that case, 1
#        otherwise (= compilation needed). With OSMO_DEB_REFRESH=1, always
#        exits 1: the cache is ignored and will be rewritten (build.sh --no-cache).
#
#    osmo-deb pack <name> <version> <command...>
#        Runs <command> with DESTDIR=<staging> in the environment -
#        `make install`, `ninja install`, `cmake --install` all honour it -
#        builds the .deb from the staging, installs it in the root and stores
#        it in the cache. Typical usage:
#            ./configure && make -j && osmo-deb pack libosmocore 1.12.1 make install
#        THE SOURCE TREE GOES WITH IT: the current folder, when under
#        /opt/GSM, is added as is to the package (.git, compiled objects). At
#        a rebuild from the cache, /opt/GSM/<name> thus always exists - the
#        image and the ISO stay a workshop where one can reread, patch and
#        run `make` again. Without it, a full cache would give an image
#        WITHOUT any source. OSMO_DEB_SRC=/path names another tree; OSMO_DEB_NO_SRC=1 drops it.
#
#    osmo-deb snapshot <name> <version> <path...>
#        For what has no install step (a source tree used as is at runtime:
#        osmocom-bb, qosmo-grgsm, a venv): the .deb is built from files
#        ALREADY in place. Nothing is reinstalled.
#
#    osmo-deb list
#
#  The <version> is the caller's choice: the upstream version when pinned
#  (1.12.1), `0.git` when following a branch. The Ubuntu suite name (noble,
#  jammy) is added automatically: a package compiled on jammy is never
#  installed on a noble rootfs.
#
#  Variables: OSMO_DEB_CACHE (default /var/cache/osmo-debs)
#             OSMO_DEB_REFRESH=1  ignores the cache, rebuilds and replaces
# =============================================================================
set -euo pipefail

CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
REFRESH="${OSMO_DEB_REFRESH:-0}"
PREFIX="osmo-build-"
SRC_ROOT="${OSMO_DEB_SRC_ROOT:-/opt/GSM}"   # the source trees live there
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
SUITE="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")"
MAINT="osmo-operator <bastienbaranoff@gmail.com>"

log() { echo "[osmo-deb] $*" >&2; }
die() { log "ERREUR : $*"; exit 1; }

usage() { sed -n '2,45p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit "${1:-0}"; }

check_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die "nom de paquet invalide : '$1' (minuscules, chiffres, . + -)"
    [[ "$2" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]] || die "version invalide : '$2' (doit commencer par un chiffre)"
}

deb_path() { printf '%s/%s%s_%s~%s_%s.deb' "$CACHE" "$PREFIX" "$1" "$2" "$SUITE" "$ARCH"; }

# Builds the .deb from a staging ($1) for <name> ($2) <version> ($3).
make_deb() {
    local stage="$1" name="$2" ver="$3" deb size
    deb="$(deb_path "$name" "$ver")"
    mkdir -p "$CACHE" "$stage/DEBIAN"
    size="$(du -sk --exclude=DEBIAN "$stage" | cut -f1)"
    cat > "$stage/DEBIAN/control" <<CTL
Package: ${PREFIX}${name}
Version: ${ver}~${SUITE}
Architecture: ${ARCH}
Maintainer: ${MAINT}
Installed-Size: ${size}
Section: misc
Priority: optional
Description: osmo-operator - ${name} ${ver}, compile dans l image (${SUITE})
 Paquet produit par osmo-deb au build de l image osmocom-nitb. Il ne declare
 aucune dependance : les bibliotheques systeme viennent de la liste apt du
 Dockerfile, qui fait autorite.
CTL
    # zstd when dpkg supports it (jammy and noble), xz otherwise: on a 1.5 GB
    # QEMU tree the difference is several minutes.
    rm -f "$deb.tmp"
    if ! dpkg-deb --build --root-owner-group -Zzstd "$stage" "$deb.tmp" >/dev/null 2>&1; then
        dpkg-deb --build --root-owner-group -Zxz "$stage" "$deb.tmp" >/dev/null
    fi
    mv -f "$deb.tmp" "$deb"
    log "$name $ver -> $deb ($(du -h "$deb" | cut -f1))"
}

cmd_install() {
    [ $# -eq 2 ] || usage 2
    check_name "$1" "$2"
    local deb; deb="$(deb_path "$1" "$2")"
    if [ "$REFRESH" = "1" ]; then
        log "$1 $2 : cache ignore (OSMO_DEB_REFRESH=1) -> compilation"; return 1
    fi
    if [ ! -s "$deb" ]; then
        log "$1 $2 : pas en cache ($(basename "$deb")) -> compilation"; return 1
    fi
    log "$1 $2 : installe depuis le cache ($(basename "$deb"))"
    dpkg -i --force-overwrite "$deb" >/dev/null
    ldconfig 2>/dev/null || true
    return 0
}

cmd_pack() {
    [ $# -ge 3 ] || usage 2
    local name="$1" ver="$2"; shift 2
    check_name "$name" "$ver"
    local stage; stage="$(mktemp -d "${TMPDIR:-/tmp}/osmo-deb.XXXXXX")"
    DESTDIR="$stage" "$@"
    if [ -z "$(find "$stage" -mindepth 1 -maxdepth 1 ! -name DEBIAN 2>/dev/null)" ]; then
        rm -rf "$stage"
        die "$name : rien n a ete installe dans DESTDIR - la commande l ignore-t-elle ?"
    fi
    # The source tree (the current folder, under /opt/GSM) goes into the
    # package: the sources stay in /opt/GSM even when the cache spares the
    # cloning and compiling. See the header.
    local src="${OSMO_DEB_SRC:-$PWD}"
    if [ "${OSMO_DEB_NO_SRC:-0}" != "1" ] && [ -d "$src" ] \
       && case "$src" in "$SRC_ROOT"/?*) true ;; *) false ;; esac; then
        mkdir -p "$stage$(dirname "$src")"
        # `cp -an`: the install prefix may live UNDER the source tree (Open5GS:
        # /opt/LTE/open5gs/install), in which case it is ALREADY in the
        # staging. The copy completes around what is already there (-n: never
        # over what the install command just put in place).
        cp -an "$src" "$stage$(dirname "$src")/"
        log "$name : arbre de sources $src inclus dans le paquet"
    fi
    make_deb "$stage" "$name" "$ver"
    dpkg -i --force-overwrite "$(deb_path "$name" "$ver")" >/dev/null
    ldconfig 2>/dev/null || true
    rm -rf "$stage"
}

cmd_snapshot() {
    [ $# -ge 3 ] || usage 2
    local name="$1" ver="$2"; shift 2
    check_name "$name" "$ver"
    local stage p; stage="$(mktemp -d "${TMPDIR:-/tmp}/osmo-deb.XXXXXX")"
    for p in "$@"; do
        [ -e "$p" ] || { rm -rf "$stage"; die "$name : $p n existe pas"; }
        case "$p" in /*) ;; *) rm -rf "$stage"; die "$name : chemin absolu requis ($p)" ;; esac
        mkdir -p "$stage$(dirname "$p")"
        cp -a "$p" "$stage$(dirname "$p")/"
    done
    make_deb "$stage" "$name" "$ver"
    rm -rf "$stage"
}

cmd_list() {
    ls -1sh "$CACHE"/${PREFIX}*.deb 2>/dev/null || log "cache vide ($CACHE)"
}

case "${1:-}" in
    install)  shift; cmd_install "$@" ;;
    pack)     shift; cmd_pack "$@" ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    list)     cmd_list ;;
    -h|--help|help|'') usage 0 ;;
    *) die "verbe inconnu : $1 (install|pack|snapshot|list)" ;;
esac
