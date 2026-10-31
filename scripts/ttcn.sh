#!/bin/bash
# =============================================================================
# scripts/ttcn.sh - Osmocom TTCN-3 test suites (osmo-ttcn3-hacks) + Eclipse TITAN
# =============================================================================
#
# Usage:
#   scripts/ttcn.sh [--root DIR] [action ...]
#
# Actions (default: titan sources):
#   titan            eclipse-titan (>= 9.0.0 required by osmo-ttcn3-hacks, Ubuntu
#                    noble only ships 8.2.0) from the Osmocom OBS repository
#                    osmocom:latest, PINNED so that only eclipse-titan comes from
#                    it: the bench Osmocom stack (built from /opt/GSM) stays
#                    untouched. Also the build dependencies of the suites.
#   sources          clone osmo-ttcn3-hacks into $GSM_ROOT and fetch its TITAN
#                    protocol modules / test ports (make deps, pinned commits).
#   build [SUITE..]  compile the suites (make <suite>), default $TTCN_SUITES.
#   run   [SUITE..]  testenv.py run <suite>: builds the IUT from the sibling
#                    sources of $GSM_ROOT (osmo-dev, installed in the testenv
#                    cache, NOT in /usr) and runs it on the host. Logs, pcaps
#                    and JUnit XML in $TTCN_OUT/<suite>/; verdicts summed up in
#                    $TTCN_OUT/verdicts.txt. STOP THE BENCH FIRST: the suites
#                    bind the same ports (GSUP 4222, M3UA 2905, VTY 42xx).
#   pack  [ZIP]      zip $TTCN_OUT (default $TTCN_ZIP).
#
#   --root DIR       work on a rootfs (ISO build, iso_modules/80-ttcn.sh):
#                    titan is installed through chroot DIR, sources are cloned
#                    into DIR$GSM_ROOT from the host. build/run are refused.
#
# Environment:
#   GSM_ROOT=/opt/GSM            TTCN3_HACKS_REF=<branch|tag|commit>
#   TTCN_SUITES="hlr stp mgw sip"   TTCN_OUT=/var/tmp/ttcn-<date>
#   TTCN_ZIP=/home/nirvana/ttcn.zip TTCN_ARGS="--fast" (extra testenv args)
#   TESTENV_SRC_DIR=$GSM_ROOT/ttcn-src  (osmo-dev + clean IUT clones)
# -----------------------------------------------------------------------------
set -uo pipefail

GSM_ROOT="${GSM_ROOT:-/opt/GSM}"
TTCN3_HACKS_URL="${TTCN3_HACKS_URL:-https://gitea.osmocom.org/ttcn3/osmo-ttcn3-hacks}"
TTCN3_HACKS_REF="${TTCN3_HACKS_REF:-}"
TTCN_SUITES="${TTCN_SUITES:-hlr stp mgw sip}"
TTCN_OUT="${TTCN_OUT:-/var/tmp/ttcn-$(date +%Y%m%d-%H%M%S)}"
TTCN_ZIP="${TTCN_ZIP:-/home/nirvana/ttcn.zip}"
TTCN_ARGS="${TTCN_ARGS:-}"
TESTENV_SRC_DIR="${TESTENV_SRC_DIR:-$GSM_ROOT/ttcn-src}"
OBS_BASE="https://downloads.osmocom.org/packages/osmocom:/latest"

ROOT=""
say()  { echo "[ttcn] $*"; }
die()  { echo "[ttcn] ERREUR: $*" >&2; exit 1; }
inroot() { if [ -n "$ROOT" ]; then chroot "$ROOT" "$@"; else "$@"; fi; }

# Build/run dependencies of the suites (TITAN pulls libpcap/libsctp/libssl/libxml2
# itself) and the programs testenv checks for (_testenv/testenv/requirements.py).
TTCN_PKGS="eclipse-titan build-essential autoconf automake libtool pkg-config
git wget rsync file ccache bridge-utils wireshark-common libcap2-bin zip
libusb-1.0-0-dev libjansson-dev libgnutls28-dev libtalloc-dev libmnl-dev
libpcsclite-dev libsqlite3-dev libortp-dev libsofia-sip-ua-glib-dev
libc-ares-dev libdbi-dev libdbd-sqlite3 libnl-route-3-dev python3"

act_titan() {
    local osrel="$ROOT/etc/os-release" id ver repo
    id="$(. "$osrel"; echo "$ID")"; ver="$(. "$osrel"; echo "$VERSION_ID")"
    case "$id" in
        ubuntu) repo="xUbuntu_$ver" ;;
        debian) repo="Debian_$ver" ;;
        *) die "distribution $id non geree par osmocom:latest" ;;
    esac
    say "depot osmocom:latest ($repo), epingle sur eclipse-titan seul"
    install -d "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/apt/preferences.d"
    curl -fsSL --retry 3 "$OBS_BASE/$repo/Release.key" -o "$ROOT/etc/apt/keyrings/osmocom-latest.asc" \
        || die "cle $OBS_BASE/$repo/Release.key injoignable"
    echo "deb [signed-by=/etc/apt/keyrings/osmocom-latest.asc] $OBS_BASE/$repo/ ./" \
        > "$ROOT/etc/apt/sources.list.d/osmocom-latest.list"
    # Everything from downloads.osmocom.org is refused (-1) except eclipse-titan:
    # the osmocom:latest libosmo*/osmo-* packages would replace the bench builds.
    cat > "$ROOT/etc/apt/preferences.d/osmocom-latest-titan" <<'EOF'
# scripts/ttcn.sh: only eclipse-titan comes from osmocom:latest
Package: *
Pin: origin downloads.osmocom.org
Pin-Priority: -1

Package: eclipse-titan
Pin: origin downloads.osmocom.org
Pin-Priority: 1001
EOF
    inroot env DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update"
    # shellcheck disable=SC2086
    inroot env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold $TTCN_PKGS || die "installation eclipse-titan / dependances"
    say "$(inroot ttcn3_compiler -v 2>&1 | grep -m1 -i 'version' || echo 'ttcn3_compiler installe')"
}

act_sources() {
    local d="$ROOT$GSM_ROOT/osmo-ttcn3-hacks"
    command -v git >/dev/null && command -v make >/dev/null || die "git et make requis"
    if [ -d "$d/.git" ]; then
        say "osmo-ttcn3-hacks deja present ($d)"
    else
        say "clonage $TTCN3_HACKS_URL -> $d"
        git clone "$TTCN3_HACKS_URL" "$d" || die "clonage osmo-ttcn3-hacks"
    fi
    if [ -n "$TTCN3_HACKS_REF" ]; then
        git -c safe.directory='*' -C "$d" fetch -q origin && \
        git -c safe.directory='*' -C "$d" checkout -q "$TTCN3_HACKS_REF" || die "checkout $TTCN3_HACKS_REF"
    fi
    # deps/: ~45 eclipse-titan protocol modules and test ports, each at the
    # commit pinned in deps/Makefile. Plain git clones: runs on the host.
    say "make deps (modules de protocole et ports de test TITAN)"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
        make -C "$d/deps" -j"$(nproc)" >/dev/null || die "make deps"
    say "sources TTCN-3 pretes : $d"
}

act_build() {
    [ -z "$ROOT" ] || die "build refuse avec --root"
    local d="$GSM_ROOT/osmo-ttcn3-hacks" s rc=0
    # shellcheck disable=SC2086
    [ $# -gt 0 ] || set -- $TTCN_SUITES
    for s in "$@"; do
        say "compilation $s"
        make -C "$d" "$s" || { say "ECHEC compilation $s"; rc=1; }
    done
    return $rc
}

# Verdicts of one suite: the JUnit XML written by start-testsuite.sh.
verdicts() {
    python3 - "$@" <<'PY'
import sys, glob, os, xml.etree.ElementTree as ET
out, suite = sys.argv[1], sys.argv[2]
rows, tot = [], {"pass": 0, "fail": 0, "error": 0, "skip": 0}
for f in sorted(glob.glob(os.path.join(out, "**", "junit-xml-*.log"), recursive=True)):
    try:
        root = ET.parse(f).getroot()
    except ET.ParseError:
        continue
    for tc in root.iter("testcase"):
        v = "pass"
        if tc.find("failure") is not None: v = "fail"
        elif tc.find("error") is not None: v = "error"
        elif tc.find("skipped") is not None: v = "skip"
        tot[v] += 1
        rows.append("%-6s %s.%s" % (v.upper(), tc.get("classname", ""), tc.get("name", "")))
print("== %s : %d pass, %d fail, %d error, %d skip" % (suite, tot["pass"], tot["fail"], tot["error"], tot["skip"]))
print("\n".join(rows) if rows else "   (aucun JUnit XML : voir les journaux)")
PY
}

act_run() {
    [ -z "$ROOT" ] || die "run refuse avec --root"
    local d="$GSM_ROOT/osmo-ttcn3-hacks" s rc=0
    command -v ttcn3_compiler >/dev/null || die "eclipse-titan absent : scripts/ttcn.sh titan"
    mkdir -p "$TTCN_OUT"
    : > "$TTCN_OUT/verdicts.txt"
    # shellcheck disable=SC2086
    [ $# -gt 0 ] || set -- $TTCN_SUITES
    # The IUT (osmo-hlr, osmo-stp...) is built by osmo-dev from clean clones in
    # TESTENV_SRC_DIR, NOT from the bench trees of $GSM_ROOT: those are patched
    # and configured in-tree, which an out-of-tree osmo-dev build refuses.
    export TESTENV_SRC_DIR
    mkdir -p "$TESTENV_SRC_DIR"
    if [ ! -d "$TESTENV_SRC_DIR/osmo-dev" ]; then
        say "testenv init osmo-dev -> $TESTENV_SRC_DIR"
        ( cd "$d" && ./testenv.py init osmo-dev ) || die "testenv init osmo-dev"
    fi
    local cfg
    for s in "$@"; do
        # Several testenv*.cfg: the Osmocom one(s) if named so (hlr: osmo, not
        # pyhss), otherwise all of them (stp: ipa, m3ua, tcap...).
        cfg=()
        if [ -n "$(ls "$d/$s"/testenv_osmo*.cfg 2>/dev/null)" ]; then cfg=(-c 'osmo*')
        elif [ "$(ls "$d/$s"/testenv*.cfg 2>/dev/null | wc -l)" -gt 1 ]; then cfg=(-c all)
        fi
        say "testenv run $s ${cfg[*]} -> $TTCN_OUT/$s"
        rm -rf "${TTCN_OUT:?}/$s"
        # shellcheck disable=SC2086
        ( cd "$d" && ./testenv.py run "$s" "${cfg[@]+"${cfg[@]}"}" --log-dir "$TTCN_OUT/$s" --no-tee $TTCN_ARGS ) \
            > "$TTCN_OUT/$s.console.log" 2>&1 || { say "$s : testenv rc=$? (voir $s.console.log)"; rc=1; }
        verdicts "$TTCN_OUT/$s" "$s" | tee -a "$TTCN_OUT/verdicts.txt"
    done
    say "verdicts : $TTCN_OUT/verdicts.txt"
    return $rc
}

act_pack() {
    local zip="${1:-$TTCN_ZIP}"
    [ -d "$TTCN_OUT" ] || die "$TTCN_OUT absent (lancer run d abord, ou TTCN_OUT=...)"
    rm -f "$zip"
    ( cd "$(dirname "$TTCN_OUT")" && zip -qr "$zip" "$(basename "$TTCN_OUT")" ) || die "zip $zip"
    say "archive : $zip ($(du -h "$zip" | cut -f1))"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)   ROOT="${2:?--root DIR}"; shift ;;
        --root=*) ROOT="${1#*=}" ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) break ;;
    esac
    shift
done
[ -z "$ROOT" ] || [ -d "$ROOT/etc" ] || die "--root $ROOT : pas un rootfs"
[ "$(id -u)" = 0 ] || die "a lancer en root (apt, chroot, setcap de testenv)"
[ $# -gt 0 ] || set -- titan sources

rc=0
while [ $# -gt 0 ]; do
    a="$1"; shift
    args=()
    while [ $# -gt 0 ]; do
        case "$1" in titan|sources|build|run|pack) break ;; esac
        args+=("$1"); shift
    done
    case "$a" in
        titan)   act_titan ;;
        sources) act_sources ;;
        build)   act_build "${args[@]+"${args[@]}"}" ;;
        run)     act_run "${args[@]+"${args[@]}"}" ;;
        pack)    act_pack "${args[@]+"${args[@]}"}" ;;
        *) die "action inconnue : $a (titan|sources|build|run|pack)" ;;
    esac || rc=1
done
exit $rc
