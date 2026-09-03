#!/bin/bash
# =============================================================================
#  apt-fast-install - UNE seule facon d installer apt-fast, partout
# =============================================================================
#
#  Utilise par : Dockerfile, Dockerfile.stp (COPY puis RUN), build-iso.sh (dans
#  le chroot du rootfs), build.sh et tools/make-docker-image.sh (sur l hote).
#  Apres ce script, tout le monde parle a apt de la meme facon :
#
#      apt-fast update
#      apt-fast install -y --no-install-recommends <paquets>
#      apt-fast build-dep -y <paquet>
#
#  apt-fast telecharge en parallele (aria2), dpkg installe ensuite comme
#  d habitude : le gain porte sur le telechargement, et il est net des qu on
#  pose plusieurs centaines de paquets. Si GitHub est injoignable, on pose un
#  apt-fast qui appelle apt-get : la commande existe toujours, le build
#  continue, plus lentement.
#
#  DLDIR = /var/cache/apt/archives : apt-fast telecharge la ou apt range ses
#  paquets. C est ce qui permet a build-iso.sh de monter un cache PERSISTANT
#  a cet endroit dans le chroot (les .deb du rootfs sont telecharges une fois,
#  pour toutes les passes et toutes les reconstructions).
#
#  Il pose aussi /etc/apt/apt.conf.d/90osmo-operator - les reglages apt qui
#  etaient repetes dans le chroot de l ISO et en ligne de commande sur l hote :
#  pas de traductions, 3 essais, pipeline HTTP, dpkg sans pty. Ce sont des
#  reglages de TELECHARGEMENT ; ils ne touchent ni aux recommends ni a la
#  facon dont dpkg ecrit.
#
#  Idempotent : deja installe -> ne refait que la conf.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APT_FAST_URL="${APT_FAST_URL:-https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast}"
BIN=/usr/local/sbin/apt-fast

cat > /etc/apt/apt.conf.d/90osmo-operator <<'CONF'
// osmo-operator : reglages apt communs (image docker, rootfs ISO, hote)
Acquire::Languages "none";
Acquire::Retries "3";
Acquire::http::Pipeline-Depth "5";
Dpkg::Use-Pty "0";
CONF

# aria2 et curl sont les seuls paquets que l on pose encore avec apt-get :
# apt-fast n existe pas avant eux.
if ! command -v aria2c >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y --no-install-recommends aria2 curl ca-certificates
fi

if [ ! -x "$BIN" ] || ! grep -q 'aria2' "$BIN" 2>/dev/null; then
    if curl -fsSL --retry 3 -o "$BIN.tmp" "$APT_FAST_URL" && grep -q 'aria2' "$BIN.tmp"; then
        mv -f "$BIN.tmp" "$BIN"
        echo "[apt-fast] installe depuis $APT_FAST_URL"
    else
        rm -f "$BIN.tmp"
        printf '#!/bin/sh\n# apt-fast de repli (telechargement impossible) : apt-get tel quel\nexec apt-get "$@"\n' > "$BIN"
        echo "[apt-fast] WARN: telechargement impossible - repli sur apt-get sous le meme nom" >&2
    fi
    chmod 755 "$BIN"
fi

# La conf d apt-fast : 16 connexions, aucune question. Ecrite a chaque fois,
# elle est courte et c est ce qui garantit que tous les environnements se
# ressemblent.
cat > /etc/apt-fast.conf <<'CONF'
_APTMGR=apt-get
DOWNLOADBEFORE=true
_MAXNUM=16
_MAXCONPERSRV=10
_SPLITCON=8
_MINSPLITSZ="1M"
_PIECEALGO="default"
DLDIR=/var/cache/apt/archives
DLLIST=/tmp/apt-fast.list
APT_FAST_TIMEOUT=60
VERBOSE_OUTPUT=false
CONF
mkdir -p /var/cache/apt/archives/partial

# Garder les .deb telecharges : c est le principe du cache. Les images docker
# posent /etc/apt/apt.conf.d/docker-clean, qui les efface apres chaque
# installation - il part. Keep-Downloaded-Packages vaut pour apt >= 1.2.
rm -f /etc/apt/apt.conf.d/docker-clean
cat > /etc/apt/apt.conf.d/91osmo-keep-debs <<'CONF'
// osmo-operator : les paquets telecharges restent dans /var/cache/apt/archives
Binary::apt::APT::Keep-Downloaded-Packages "true";
APT::Keep-Downloaded-Packages "true";
CONF
echo "[apt-fast] pret : $BIN"
