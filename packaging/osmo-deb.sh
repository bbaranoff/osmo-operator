#!/bin/bash
# =============================================================================
#  osmo-deb - un .deb par dossier compile, garde en cache, reinstalle au rebuild
# =============================================================================
#
#  PRINCIPE. Tout ce qui se compile dans l image (libosmocore, osmo-*, gapk,
#  QEMU, osmocom-bb, gr-gsm...) sort sous forme de paquet .deb, range dans
#      /var/cache/osmo-debs/osmo-build-<nom>_<version>~<suite>_<arch>.deb
#  Au rebuild suivant, si le paquet est la, on l installe (dpkg -i) au lieu de
#  recloner et recompiler. Le cache vit SUR L HOTE (/var/cache/osmo-debs) :
#  build.sh le recopie dans le contexte (.deb-cache/) avant `docker build`, et
#  ramene les paquets produits par l image une fois le build fini.
#
#  Trois verbes :
#
#    osmo-deb install <nom> <version>
#        Installe le .deb du cache s il existe. Sort en 0 dans ce cas, en 1
#        sinon (= il faut compiler). Avec OSMO_DEB_REFRESH=1, sort toujours
#        en 1 : le cache est ignore et sera reecrit (build.sh --no-cache).
#
#    osmo-deb pack <nom> <version> <commande...>
#        Lance <commande> avec DESTDIR=<staging> dans l environnement -
#        `make install`, `ninja install`, `cmake --install` l honorent tous -
#        fabrique le .deb depuis le staging, l installe dans la racine et le
#        range dans le cache. Usage type :
#            ./configure && make -j && osmo-deb pack libosmocore 1.12.1 make install
#
#    osmo-deb snapshot <nom> <version> <chemin...>
#        Pour ce qui n a pas d etape d installation (un arbre de sources qui
#        sert tel quel au runtime : osmocom-bb, qosmo-grgsm, un venv) : le .deb
#        est fabrique depuis des fichiers DEJA en place. Rien n est reinstalle.
#
#    osmo-deb list
#
#  La <version> est un choix de l appelant : la version amont quand elle est
#  epinglee (1.12.1), `0.git` quand on suit une branche. Le nom de la suite
#  Ubuntu (noble, jammy) est ajoute automatiquement : un paquet compile sur
#  jammy ne sera jamais pose sur un rootfs noble.
#
#  Variables : OSMO_DEB_CACHE (defaut /var/cache/osmo-debs)
#              OSMO_DEB_REFRESH=1  ignore le cache, reconstruit et remplace
# =============================================================================
set -euo pipefail

CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
REFRESH="${OSMO_DEB_REFRESH:-0}"
PREFIX="osmo-build-"
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

# Fabrique le .deb depuis un staging ($1) pour <nom> ($2) <version> ($3).
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
    # zstd quand dpkg le sait (jammy et noble), xz sinon : sur un arbre QEMU de
    # 1,5 Go la difference est de plusieurs minutes.
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
