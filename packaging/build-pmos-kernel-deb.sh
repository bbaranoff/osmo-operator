#!/bin/bash
# =============================================================================
# build-pmos-kernel-deb.sh - LE NOYAU postmarketOS AVEC PPP, EN .deb.
#
# [2026-09-08] Le noyau du telephone (linux-postmarketos-stable, rebati avec
# CONFIG_PPP pour la data 4G du modem du banc) est un .apk signe par la cle
# du build pmbootstrap. Il se construit en 15 a 40 minutes, sous un compte
# NON root, avec des montages de boucle : impossible dans un `docker build`.
# Ce script prend donc le noyau DEJA CONSTRUIT (le dossier de travail
# pmbootstrap de la machine de reference) et en fait un paquet Debian :
#
#     osmo-build-pmos-kernel_<version>+ppp~<suite>_<arch>.deb
#
# qui pose, sous /opt/user_interface/kernel/pmos/ :
#     linux-postmarketos-stable-<ver>.apk   le noyau (modules PPP signes dedans)
#     APKINDEX.tar.gz                       l index du depot local pmbootstrap
#     <cle>.rsa.pub                         la cle PUBLIQUE qui a signe l apk
#     pmaports.commit                       le commit pmaports d ou il vient
#     pmaports-linux-postmarketos-stable-ppp.patch   la config (CONFIG_PPP=m...)
#
# tools/osmo-pmos-build.sh sait lire ce dossier : il copie l apk et l index
# dans le depot local de pmbootstrap, la cle dans config_apk_keys, et
# « pmbootstrap install » prend ce noyau-la sans rien recompiler.
#
# Le .deb va dans /opt/user_interface/kernel/ (c est la qu on le range) ET
# dans /var/cache/osmo-debs/ : iso_modules/50-injection-image.sh y prend tous
# les osmo-build-*.deb de la suite, le noyau part donc dans l ISO tout seul.
#
#   sudo packaging/build-pmos-kernel-deb.sh [dossier de travail pmbootstrap]
#       defaut : le dossier « work » du pmbootstrap_v3.cfg du compte de session
#                (SUDO_USER), sinon ~<user>/test, sinon $OSMO_PMB_WORK
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UI="${OSMO_UI_ROOT:-/opt/user_interface}"
KDIR="$UI/kernel"
CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
SUITE="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say() { echo -e "${CYAN}→${NC} $*"; }; ok() { echo -e "${GREEN}✓${NC} $*"; }
die() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# Le dossier de travail pmbootstrap : argument, sinon celui du compte de session.
_user="${SUDO_USER:-}"
[ -z "$_user" ] && [ -n "${PKEXEC_UID:-}" ] && _user="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
_home="$(getent passwd "${_user:-root}" | cut -d: -f6)"
WORK="${1:-${OSMO_PMB_WORK:-}}"
if [ -z "$WORK" ]; then
    for c in "$_home/.config/pmbootstrap_v3.cfg" "$_home/.config/pmbootstrap.cfg"; do
        [ -f "$c" ] && WORK="$(sed -n 's/^work *= *//p' "$c" | head -1)" && [ -n "$WORK" ] && break
    done
fi
[ -n "$WORK" ] || WORK="$_home/test"
[ -d "$WORK/packages" ] || die "pas de dossier packages/ dans $WORK (dossier de travail pmbootstrap ?)"

apk="$(find "$WORK/packages" -name 'linux-postmarketos-stable-[0-9]*.apk' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
[ -n "$apk" ] || die "aucun linux-postmarketos-stable-*.apk dans $WORK/packages - le noyau n a pas ete construit (osmo-pmos-build)"
# (grep -q ferme le tube avant la fin de tar : sous pipefail ce serait un
# faux echec - d ou la substitution de processus.)
grep -q 'ppp_async\.ko' < <(tar tzf "$apk" 2>/dev/null) || die "$apk n a PAS ppp_async.ko : ce n est pas le noyau PPP"
ver="$(basename "$apk" .apk | sed 's/^linux-postmarketos-stable-//')"          # 7.2.3-r0
dver="$(echo "$ver" | sed 's/-r/./')+ppp"                                       # 7.2.3.0+ppp
index="$(dirname "$apk")/APKINDEX.tar.gz"
channel="$(basename "$(dirname "$(dirname "$apk")")")"                          # edge
parch="$(basename "$(dirname "$apk")")"                                         # x86_64
pub="$(ls -1 "$WORK"/config_abuild/*.rsa.pub 2>/dev/null | head -1)"
[ -n "$pub" ] || pub="$(ls -1 "$WORK"/config_apk_keys/pmos@*.rsa.pub 2>/dev/null | head -1)"
[ -n "$pub" ] || die "pas de cle publique pmos@*.rsa.pub dans $WORK/config_abuild ni config_apk_keys"
aports="$(sed -n 's/^aports *= *//p' "$_home/.config/pmbootstrap_v3.cfg" 2>/dev/null | head -1)"
[ -n "$aports" ] && [ -d "$aports/.git" ] || aports="$WORK/cache_git/pmaports"
commit="$(git -C "$aports" rev-parse HEAD 2>/dev/null || echo inconnu)"

say "noyau : $apk ($ver, $channel/$parch), cle $(basename "$pub"), pmaports $commit"

stage="$(mktemp -d /var/tmp/pmos-kernel-deb.XXXXXX)"; trap 'rm -rf "$stage"' EXIT
d="$stage$KDIR/pmos"
mkdir -p "$d" "$stage/DEBIAN"
cp -f "$apk" "$d/"
[ -f "$index" ] && cp -f "$index" "$d/"
cp -f "$pub" "$d/"
echo "$commit" > "$d/pmaports.commit"
echo "$channel $parch $ver" > "$d/apk.info"
if [ -f "$REPO/patches/pmaports-linux-postmarketos-stable-ppp.patch" ]; then
    cp -f "$REPO/patches/pmaports-linux-postmarketos-stable-ppp.patch" "$d/"
elif git -C "$aports" diff --quiet 2>/dev/null; then :; else
    git -C "$aports" diff > "$d/pmaports-linux-postmarketos-stable-ppp.patch"
fi
cat > "$d/README" <<EOF
Noyau postmarketOS $ver (x86_64, qemu-amd64) rebati avec PPP pour la data 4G
du telephone du banc. Produit par packaging/build-pmos-kernel-deb.sh depuis
$WORK le $(date -I).
  - l apk est signe par $(basename "$pub") : la cle doit etre dans
    config_apk_keys/ du dossier de travail pmbootstrap qui l installe ;
  - pmaports doit etre au commit $commit (meme pkgver/pkgrel : $ver),
    avec le patch ci-joint applique, pour que pmbootstrap le prefere au depot ;
  - tools/osmo-pmos-build.sh (osmo-pmos-build) fait tout cela.
EOF
size="$(du -sk --exclude=DEBIAN "$stage" | cut -f1)"
cat > "$stage/DEBIAN/control" <<CTL
Package: osmo-build-pmos-kernel
Version: ${dver}~${SUITE}
Architecture: ${ARCH}
Maintainer: osmo-operator <bastienbaranoff@gmail.com>
Installed-Size: ${size}
Section: misc
Priority: optional
Description: osmo-operator - noyau postmarketOS ${ver} avec PPP (telephone du banc)
 L apk linux-postmarketos-stable rebati avec CONFIG_PPP pour la data 4G du
 modem du banc, son index, sa cle publique et le patch pmaports, sous
 ${KDIR}/pmos. Lu par osmo-pmos-build (tools/osmo-pmos-build.sh).
CTL
mkdir -p "$KDIR" "$CACHE"
deb="$KDIR/osmo-build-pmos-kernel_${dver}~${SUITE}_${ARCH}.deb"
dpkg-deb --build --root-owner-group -Zzstd "$stage" "$deb" >/dev/null 2>&1 \
    || dpkg-deb --build --root-owner-group -Zxz "$stage" "$deb" >/dev/null
cp -f "$deb" "$CACHE/"
ok "$deb ($(du -h "$deb" | cut -f1)) - copie dans $CACHE"
# Et pose sur cette machine : /opt/user_interface/kernel/pmos rempli.
dpkg -i --force-overwrite "$deb" >/dev/null 2>&1 && ok "pose : $KDIR/pmos/" || echo "  (dpkg -i a echoue : dpkg -i $deb)"
