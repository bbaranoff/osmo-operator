#!/bin/bash
# =============================================================================
#  apt-mirror - LE miroir Ubuntu le plus rapide d ici, mesure, pas suppose
# =============================================================================
#
#  Affiche une URL de miroir (http://.../ubuntu) sur la sortie standard.
#
#  [2026-09-04] archive.ubuntu.com repondait a 3 Ko/s depuis l hote de build
#  (20 s et un timeout pour un InRelease de 250 Ko) quand fr.archive, ovh et
#  ikoula servaient le meme fichier en 0,1 s. Le build docker restait muet a
#  l etape 3/64 (apt-get update -qq) pendant dix minutes, sans rien dire.
#  L adresse "archive.ubuntu.com" est un point d entree geo-equilibre, pas
#  un engagement de debit : on MESURE.
#
#  Candidats : $OSMO_UBUNTU_MIRRORS (liste separee par des espaces) si donne,
#  sinon les miroirs que mirrors.ubuntu.com propose pour CE pays (GeoIP, les
#  quatre premiers) plus archive.ubuntu.com. Chaque candidat telecharge
#  dists/<suite>/InRelease avec 5 s au maximum ; le plus rapide gagne. Si rien
#  ne repond, archive.ubuntu.com, comme avant.
#
#  OSMO_UBUNTU_MIRROR=http://... court-circuite tout : c est ce miroir, sans
#  mesure (un miroir local, un proxy apt).
#
#  Usage :  MIRROR="$(packaging/apt-mirror.sh [suite])"   (defaut : noble)
#           Les mesures vont sur stderr, l URL seule sur stdout.
#           packaging/apt-mirror.sh --list [suite]
#           Tous les miroirs qui repondent, "<ms>\t<url>", du plus rapide au
#           plus lent, sur stdout - c est ce que lit l installeur du live pour
#           proposer le choix (osmo-install, page packagechooser@mirror).
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
    # mirrors.txt (GeoIP) renvoie parfois... archive.ubuntu.com lui-meme. On
    # y ajoute le miroir du pays de la locale (fr.archive, de.archive...), deux
    # gros hebergeurs europeens et kernel.org : de quoi toujours avoir un
    # miroir qui repond.
    CANDIDATES="$(curl -fsSL -m 5 http://mirrors.ubuntu.com/mirrors.txt 2>/dev/null \
                  | grep -E '^https?://' | head -4 | tr '\n' ' ')"
    _cc="$(echo "${LC_ALL:-${LANG:-}}" | sed -nE 's/^[a-z]+_([A-Z]{2}).*/\1/p' | tr 'A-Z' 'a-z')"
    [ -n "$_cc" ] && CANDIDATES="$CANDIDATES http://${_cc}.archive.ubuntu.com/ubuntu"
    CANDIDATES="$CANDIDATES http://ubuntu.mirrors.ovh.net/ubuntu http://mirror.ubuntu.ikoula.com/ubuntu
                http://mirrors.edge.kernel.org/ubuntu $DEFAULT"
fi
# Sans doublon, dans l ordre.
CANDIDATES="$(for m in $CANDIDATES; do echo "${m%/}"; done | awk '!seen[$0]++' | tr '\n' ' ')"

best=""; best_t=999999; results=""
for m in $CANDIDATES; do
    m="${m%/}"
    # Un seul fichier, petit et toujours present ; 5 s max, et le temps est
    # celui de curl lui-meme (ms), pas une horloge externe.
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
