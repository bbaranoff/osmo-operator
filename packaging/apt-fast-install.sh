#!/bin/bash
# =============================================================================
#  apt-fast-install - ONE single way to install apt-fast, everywhere
# =============================================================================
#
#  Used by: Dockerfile, Dockerfile.stp (COPY then RUN), build-iso.sh (in the
#  rootfs chroot), build.sh and tools/make-docker-image.sh (on the host).
#  After this script, everyone talks to apt the same way:
#
#      apt-fast update
#      apt-fast install -y --no-install-recommends <packages>
#      apt-fast build-dep -y <package>
#
#  apt-fast downloads in parallel (aria2), dpkg then installs as usual: the
#  gain is on the download, and it is clear as soon as several hundred
#  packages are installed. If GitHub is unreachable, an apt-fast that calls
#  apt-get is installed: the command always exists, the build goes on, more
#  slowly.
#
#  DLDIR = /var/cache/apt/archives: apt-fast downloads where apt stores its
#  packages. This is what lets build-iso.sh mount a PERSISTENT cache at that
#  place in the chroot (the rootfs .deb are downloaded once, for every pass
#  and every rebuild).
#
#  It also installs /etc/apt/apt.conf.d/90osmo-operator - the apt settings
#  shared by the ISO chroot and the host command line: no translations,
#  3 retries, HTTP pipelining, dpkg without pty. These are DOWNLOAD
#  settings; they touch neither the recommends nor the way dpkg writes
#  its files.
#
#  Idempotent: already installed -> only redoes the conf.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APT_FAST_URL="${APT_FAST_URL:-https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast}"
BIN=/usr/local/sbin/apt-fast

# 30 s timeout and no pipelining: a mirror that does not answer fails in
# 30 s and moves on to the next retry, instead of blocking 120 s (the
# default) times three retries, silently. HTTP pipelining brings nothing here
# (aria2 already parallelises) and is a known source of connections left
# hanging behind some load balancers.
cat > /etc/apt/apt.conf.d/90osmo-operator <<'CONF'
// osmo-operator : reglages apt communs (image docker, rootfs ISO, hote)
Acquire::Languages "none";
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::http::Pipeline-Depth "0";
Dpkg::Use-Pty "0";
// Avant CHAQUE dpkg : les .deb a installer sont decompresses de bout en bout ;
// un fichier corrompu est supprime du cache et l installation s arrete, a
// relancer (osmo-apt-get, sous apt-fast, relance tout seul). Voir
// /usr/local/sbin/osmo-deb-check.
DPkg::Pre-Install-Pkgs { "/usr/local/sbin/osmo-deb-check"; };
DPkg::Tools::Options::/usr/local/sbin/osmo-deb-check::Version "1";
CONF

# ── The apt cache is PERSISTENT everywhere here: a corrupted .deb stays in it ─
# apt does not re-verify a file already present in /var/cache/apt/archives,
# and that cache is never cleared here (Keep-Downloaded-Packages, docker build
# cache mount, persistent cache of the ISO chroot): a file with the expected
# size but a bad SHA256 (altered download on a flaky mirror) would stay there
# for every build. Two pieces:
#   osmo-deb-check   DPkg::Pre-Install-Pkgs hook: apt passes it the paths of
#                    the .deb it is about to install; each is fully
#                    decompressed (dpkg-deb --fsys-tarfile); the bad ones are
#                    DELETED, a marker is set and apt stops before dpkg. The
#                    next apt re-downloads what is missing, with hash check.
#   osmo-apt-get     the "apt-get" that apt-fast runs (_APTMGR): if apt fails
#                    and the marker is there, it retries once. For an apt-get
#                    called directly, the message says to rerun.
cat > /usr/local/sbin/osmo-deb-check <<'CHK'
#!/bin/sh
# osmo-deb-check - apt hook (DPkg::Pre-Install-Pkgs, protocol 1: one .deb path
# per line on stdin). Deletes from the cache the .deb whose data archive does
# not decompress, and refuses the installation if there were any.
MARK=/run/osmo-deb-check.bad
rm -f "$MARK"
bad=0; n=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    if ! dpkg-deb --fsys-tarfile "$f" >/dev/null 2>&1; then
        echo "osmo-deb-check: CORROMPU, supprime du cache : $f" >&2
        rm -f "$f"
        bad=$((bad + 1))
    fi
done
if [ "$bad" -gt 0 ]; then
    echo "$bad" > "$MARK"
    echo "osmo-deb-check: $bad paquet(s) corrompu(s) retire(s) sur $n - relancez la commande, apt les retelechargera" >&2
    exit 1
fi
exit 0
CHK
chmod 755 /usr/local/sbin/osmo-deb-check
cat > /usr/local/sbin/osmo-apt-get <<'OAG'
#!/bin/sh
# osmo-apt-get - apt-get with ONE retry when osmo-deb-check removed corrupted
# .deb from the cache (marker /run/osmo-deb-check.bad).
MARK=/run/osmo-deb-check.bad
rm -f "$MARK"
apt-get "$@" && exit 0
rc=$?
if [ -f "$MARK" ]; then
    echo "osmo-apt-get: cache apt nettoye ($(cat "$MARK") .deb corrompu(s)) - relance de : apt-get $*" >&2
    rm -f "$MARK"
    exec apt-get "$@"
fi
exit "$rc"
OAG
chmod 755 /usr/local/sbin/osmo-apt-get

# ── The Ubuntu mirror: the one the caller measured (packaging/apt-mirror.sh)
# OSMO_UBUNTU_MIRROR=http://... replaces archive.ubuntu.com in the sources of
# the current system - the docker image (build-arg), the ISO rootfs.
# Never on the host unless asked: build.sh does not export it.
if [ -n "${OSMO_UBUNTU_MIRROR:-}" ]; then
    _m="${OSMO_UBUNTU_MIRROR%/}"
    for _f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
        [ -f "$_f" ] || continue
        # archive AND security: security.ubuntu.com lives on the same Canonical
        # addresses as archive (91.189.9x, 185.125.190.x) - when one is
        # unreachable, so is the other. Every Ubuntu mirror serves noble-security.
        sed -i -E "s#https?://(archive|[a-z]{2}\.archive|security)\.ubuntu\.com/ubuntu/?#${_m}#g" "$_f"
    done
    echo "[apt-fast] miroir Ubuntu : $_m"
fi

# aria2 and curl are the only packages still installed with apt-get:
# apt-fast does not exist before them.
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

# The apt-fast conf: 16 connections, no questions. Written every time, it is
# short and this is what guarantees that all environments look alike.
cat > /etc/apt-fast.conf <<'CONF'
_APTMGR=/usr/local/sbin/osmo-apt-get
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

# Keep the downloaded .deb: that is the point of the cache. Docker images ship
# /etc/apt/apt.conf.d/docker-clean, which deletes them after every
# installation - it is removed. Keep-Downloaded-Packages applies to apt >= 1.2.
rm -f /etc/apt/apt.conf.d/docker-clean
cat > /etc/apt/apt.conf.d/91osmo-keep-debs <<'CONF'
// osmo-operator : les paquets telecharges restent dans /var/cache/apt/archives
Binary::apt::APT::Keep-Downloaded-Packages "true";
APT::Keep-Downloaded-Packages "true";
CONF
# If /usr/local/sbin is not in the caller's PATH (root without sudo, custom
# PATH), the command would be unreachable right after "ready": a link in
# /usr/local/bin, which is always there, settles it without touching PATH.
if ! command -v apt-fast >/dev/null 2>&1; then
    ln -sfn "$BIN" /usr/local/bin/apt-fast
    echo "[apt-fast] /usr/local/sbin absent du PATH - lien /usr/local/bin/apt-fast"
fi
echo "[apt-fast] pret : $BIN"
