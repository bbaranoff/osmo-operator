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
#   run   [SUITE..]  run the suites against THE BENCH BINARIES ($TTCN_BIN,
#                    /usr/bin/osmo-*), not osmo-dev builds: the suite is
#                    compiled with TITAN (make <suite>), then for each of its
#                    testenv*.cfg the IUT is started from $TTCN_BIN with the
#                    config of the suite (copy=, prepare=), the suite runs
#                    (start-testsuite.sh, compared with expected-results.xml)
#                    and the IUT is stopped. Output in $TTCN_OUT/<suite>/<cfg>/,
#                    verdicts in $TTCN_OUT/verdicts.txt. STOP THE BENCH FIRST:
#                    the suites bind the same ports (GSUP 4222, M3UA 2905, VTY).
#   pack  [ZIP]      zip $TTCN_OUT (default $TTCN_ZIP).
#
#   --root DIR       work on a rootfs (ISO build, iso_modules/80-ttcn.sh):
#                    titan is installed through chroot DIR, sources are cloned
#                    into DIR$GSM_ROOT from the host. build/run are refused.
#
# Environment:
#   GSM_ROOT=/opt/GSM            TTCN3_HACKS_REF=<branch|tag|commit>
#   TTCN_SUITES="hlr stp mgw sip"   TTCN_OUT=/var/tmp/ttcn-<date>
#   TTCN_ZIP=/home/nirvana/ttcn.zip TTCN_BIN=/usr/bin (IUT binaries)
#   TTCN_CFG=<glob> (which testenv*.cfg: default osmo* if any, else all)
#   TTCN_IPL4_PORT=0 (IPL4asp default local port; its own default 9999 clashes)
# -----------------------------------------------------------------------------
set -uo pipefail

GSM_ROOT="${GSM_ROOT:-/opt/GSM}"
TTCN3_HACKS_URL="${TTCN3_HACKS_URL:-https://gitea.osmocom.org/ttcn3/osmo-ttcn3-hacks}"
TTCN3_HACKS_REF="${TTCN3_HACKS_REF:-}"
TTCN_SUITES="${TTCN_SUITES:-hlr stp mgw sip}"
TTCN_OUT="${TTCN_OUT:-/var/tmp/ttcn-$(date +%Y%m%d-%H%M%S)}"
TTCN_ZIP="${TTCN_ZIP:-/home/nirvana/ttcn.zip}"
TTCN_BIN="${TTCN_BIN:-/usr/bin}"
TTCN_CFG="${TTCN_CFG:-}"
TTCN_IPL4_PORT="${TTCN_IPL4_PORT:-0}"
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

# testenv*.cfg -> shell lines: "T <program> <config> <copy...>" for the
# testsuite, then "C <name>|<program>|<copy>|<prepare>|<vty_port>" per component.
cfg_parse() {
    python3 - "$1" <<'PY'
import sys, configparser
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1])
t = c["testsuite"]
print("T|%s|%s|%s" % (t["program"], t["config"], t.get("copy", "")))
for n in c.sections():
    if n == "testsuite":
        continue
    k = c[n]
    for unsup in ("setup", "clean"):
        if unsup in k:
            print("W|%s: %s= ignore" % (n, unsup))
    print("C|%s|%s|%s|%s|%s" % (n, k["program"], k.get("copy", ""), k.get("prepare", ""), k.get("vty_port", "")))
PY
}

wait_port() {   # wait_port PORT SECONDS
    local i
    for i in $(seq 1 $(( $2 * 2 ))); do
        ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN && return 0
        sleep 0.5
    done
    return 1
}

# One testenv*.cfg of one suite, against the bench binaries.
run_cfg() {
    local d="$1" s="$2" f="$3" name td line kind a b c e g pids=() rc=0
    name="$(basename "$f" .cfg)"; name="${name#testenv}"; name="${name#_}"; name="${name:-default}"
    td="$TTCN_OUT/$s/$name"
    rm -rf "$td"; mkdir -p "$td/testsuite"
    cp -a "$d/Common.cfg" "$td/"
    local tprog tcfg tcopy
    while IFS='|' read -r kind a b c e g; do
        case "$kind" in
            W) say "  attention : $a" ;;
            T) tprog="$a"; tcfg="$b"; tcopy="$c"
               # The suite config includes <Suite>.default (and sometimes other
               # *.cfg/*.default of its directory): copy them all, as testenv.
               # shellcheck disable=SC2086
               ( cd "$d/$s" && cp -a "$tcfg" $tcopy ./*.default "$td/testsuite/" 2>/dev/null ) ;;
            C) if [ -n "$g" ] && ss -ltn "sport = :$g" 2>/dev/null | grep -q LISTEN; then
                   say "  $a : port VTY $g deja pris : $(ss -ltnpH "sport = :$g" | grep -o 'users:.*')"
                   say "  arreter le banc (./start.sh --stop) ou le processus ci-dessus"; rc=1; continue
               fi
               mkdir -p "$td/$a"
               # shellcheck disable=SC2086
               [ -n "$c" ] && ( cd "$d/$s" && cp -a $c "$td/$a/" )
               ( cd "$td/$a" && PATH="$TTCN_BIN:$PATH" && { [ -z "$e" ] || bash -c "$e"; } ) \
                   || say "  $a : prepare echoue ($e)"
               say "  IUT $a : $TTCN_BIN/${b%% *} (${b#* })"
               ( cd "$td/$a" && PATH="$TTCN_BIN:$PATH" exec setsid bash -c "exec $b" ) \
                   > "$td/$a/$a.log" 2>&1 &
               pids+=($!)
               if [ -n "$g" ] && ! wait_port "$g" 15; then
                   say "  $a : VTY $g muet apres 15 s (voir $td/$a/$a.log)"; rc=1
               fi ;;
        esac
    done < <(cfg_parse "$f")
    if [ "$rc" = 0 ]; then
        # IPL4asp binds client sockets without a local port to 0.0.0.0:9999 by
        # default, taken here by open5gs-webui: "bind failed: Address already in
        # use" and every test fails before reaching the IUT. Ephemeral port.
        printf '\n# scripts/ttcn.sh\n[TESTPORT_PARAMETERS]\n*.*.defaultListeningPort := "%s"\n' \
            "$TTCN_IPL4_PORT" >> "$td/testsuite/$tcfg"
        say "  suite $tprog ($tcfg)"
        # Common.cfg: TCPDUMP_START/STOP from $TTCN3_HACKS_PATH, one pcap per test
        # in $TTCN3_PCAP_PATH.
        ( cd "$td/testsuite" && TTCN3_HACKS_PATH="$d" TTCN3_PCAP_PATH="$td/testsuite" \
              "$d/start-testsuite.sh" "$d/_build/$s/$tprog" "$tcfg" ) \
            > "$td/testsuite/console.log" 2>&1 || rc=1
        grep -E '^(Overall|Verdict statistics|Test execution summary)|^ *(pass|fail|error|inconc|none)' \
            "$td/testsuite/console.log" | tail -4 | sed 's/^/    /'
    fi
    local p
    for p in "${pids[@]+"${pids[@]}"}"; do kill -TERM -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null; done
    sleep 1
    for p in "${pids[@]+"${pids[@]}"}"; do kill -KILL -- "-$p" 2>/dev/null; done
    wait 2>/dev/null
    return $rc
}

act_run() {
    [ -z "$ROOT" ] || die "run refuse avec --root"
    local d="$GSM_ROOT/osmo-ttcn3-hacks" s f rc=0 cfgs
    command -v ttcn3_compiler >/dev/null || die "eclipse-titan absent : scripts/ttcn.sh titan"
    mkdir -p "$TTCN_OUT"
    : > "$TTCN_OUT/verdicts.txt"
    # shellcheck disable=SC2086
    [ $# -gt 0 ] || set -- $TTCN_SUITES
    for s in "$@"; do
        [ -d "$d/$s" ] || { say "$s : suite inconnue"; rc=1; continue; }
        rm -rf "${TTCN_OUT:?}/$s"; mkdir -p "$TTCN_OUT/$s"
        say "== $s : compilation TITAN (make $s)"
        make -C "$d" "$s" > "$TTCN_OUT/$s/build.log" 2>&1 \
            || { say "$s : compilation echouee (voir $s/build.log)"; rc=1; continue; }
        # Several testenv*.cfg: the Osmocom ones if named so (hlr: osmo, not
        # pyhss), otherwise all of them (stp: ipa, m3ua, tcap...).
        if [ -n "$TTCN_CFG" ]; then cfgs=("$d/$s"/testenv_$TTCN_CFG.cfg)
        elif compgen -G "$d/$s/testenv_osmo*.cfg" >/dev/null; then cfgs=("$d/$s"/testenv_osmo*.cfg)
        else cfgs=("$d/$s"/testenv*.cfg)
        fi
        for f in "${cfgs[@]}"; do
            [ -f "$f" ] || continue
            say "-- $s / $(basename "$f")"
            run_cfg "$d" "$s" "$f" || rc=1
        done
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
