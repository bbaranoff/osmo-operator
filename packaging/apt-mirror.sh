#!/bin/bash
# =============================================================================
#  apt-mirror - THE fastest Ubuntu mirror from here, measured, not assumed
# =============================================================================
#
#  Prints a mirror URL (http://.../ubuntu) on standard output.
#
#  The "archive.ubuntu.com" address is a geo-balanced entry point, not a
#  throughput commitment: it can answer at a few KB/s while a national or
#  hosting-provider mirror serves the same file in a fraction of a second,
#  leaving a docker build silent for minutes on `apt-get update`. So the
#  candidates are MEASURED, and the fastest one is the one that is used
#  everywhere a build talks to apt.
#
#  Candidates: $OSMO_UBUNTU_MIRRORS (space-separated list) if given, otherwise
#  the mirrors mirrors.ubuntu.com proposes for THIS country (GeoIP, the first
#  four) plus archive.ubuntu.com. Each candidate downloads
#  dists/<suite>/InRelease with a 5 s maximum; the fastest wins. If nothing
#  answers, archive.ubuntu.com.
#
#  OSMO_UBUNTU_MIRROR=http://... short-circuits everything: that mirror,
#  with no measurement (a local mirror, an apt proxy).
#
#  Usage:   MIRROR="$(packaging/apt-mirror.sh [suite])"   (default: noble)
#           The measurements go to stderr, the URL alone to stdout.
#           packaging/apt-mirror.sh --list [suite]
#           Every mirror that answers, "<ms>\t<url>", from the fastest to the
#           slowest, on stdout - this is what the live installer reads to
#           offer the choice (osmo-install, packagechooser@mirror page).
# =============================================================================
set -uo pipefail
LIST=0
if [ "${1:-}" = "--list" ]; then LIST=1; shift; fi
SUITE="${1:-noble}"
DEFAULT="http://archive.ubuntu.com/ubuntu"

if [ -n "${OSMO_UBUNTU_MIRROR:-}" ] && [ "$LIST" = 0 ]; then
    echo "${OSMO_UBUNTU_MIRROR%/}"; exit 0
fi
command -v curl >/dev/null 2>&1 || { [ "$LIST" = 1 ] && printf '0\t%s\n' "$DEFAULT" || echo "$DEFAULT"; exit 0; }

CANDIDATES="${OSMO_UBUNTU_MIRRORS:-}"
if [ -z "$CANDIDATES" ]; then
    # mirrors.txt (GeoIP) sometimes returns... archive.ubuntu.com itself. The
    # locale's country mirror (fr.archive, de.archive...), two large European
    # hosting providers and kernel.org are added: enough to always have a
    # mirror that answers.
    CANDIDATES="$(curl -fsSL -m 5 http://mirrors.ubuntu.com/mirrors.txt 2>/dev/null \
                  | grep -E '^https?://' | head -4 | tr '\n' ' ')"
    _cc="$(echo "${LC_ALL:-${LANG:-}}" | sed -nE 's/^[a-z]+_([A-Z]{2}).*/\1/p' | tr 'A-Z' 'a-z')"
    [ -n "$_cc" ] && CANDIDATES="$CANDIDATES http://${_cc}.archive.ubuntu.com/ubuntu"
    CANDIDATES="$CANDIDATES http://ubuntu.mirrors.ovh.net/ubuntu http://mirror.ubuntu.ikoula.com/ubuntu
                http://mirrors.edge.kernel.org/ubuntu $DEFAULT"
fi
# Without duplicates, in order.
CANDIDATES="$(for m in $CANDIDATES; do echo "${m%/}"; done | awk '!seen[$0]++' | tr '\n' ' ')"

best=""; best_t=999999; results=""
for m in $CANDIDATES; do
    m="${m%/}"
    # A single file, small and always present; 5 s max, and the time is
    # curl's own (ms), not an external clock.
    t="$(curl -s -m 5 -o /dev/null -w '%{http_code} %{time_total}' "$m/dists/$SUITE/InRelease" 2>/dev/null || true)"
    code="${t%% *}"; secs="${t##* }"
    if [ "$code" = "200" ]; then
        ms="$(awk -v s="$secs" 'BEGIN{printf "%d", s*1000}')"
        printf '  %-52s %6d ms\n' "$m" "$ms" >&2
        results="${results}${ms}	${m}
"
        if [ "$ms" -lt "$best_t" ]; then best="$m"; best_t="$ms"; fi
    else
        printf '  %-52s   -    (%s)\n' "$m" "${code:-timeout}" >&2
    fi
done
if [ "$LIST" = 1 ]; then
    printf '%s' "$results" | sort -n
    exit 0
fi
echo "${best:-$DEFAULT}"
