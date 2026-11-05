#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
#
# freecalypso-fetch.sh - the FreeCalypso files from their OFFICIAL origins
# (freecalypso.org, hg.themyscira.org), through a local cache outside Git.
#
#   freecalypso-fetch.sh [--cache DIR] [--dest DIR] NAME... | all
#   freecalypso-fetch.sh [--cache DIR] --check NAME... | all     verify only, no download
#   freecalypso-fetch.sh --hg fc-magnetite|freecalypso-tools DEST  hg clone at the pinned revision
#   freecalypso-fetch.sh --list
#
# A file is downloaded only if it is absent from the cache or if its SHA256
# differs from the one expected below. A download whose SHA256 does not match
# is DELETED and the script fails: nothing continues with a corrupt file.
# --dest DIR copies the verified file there (same name), unless the copy is
# already there with the right SHA256.
#
# Cache: --cache, else $FREECALYPSO_CACHE, else <osmo-operator>/.cache/freecalypso
# (ignored by Git), else /opt/GSM/.cache/freecalypso (the script installed alone,
# in the Docker image for instance).
#
# ftp.freecalypso.org serves at ~18 KB/s (installed-env.tar.xz, 52 MB: about
# 50 min): the download resumes (curl -C - / wget --continue) and the timeouts
# are generous; a .part file stays in the cache between two attempts.
#
# Revisions: FC_MAGNETITE_REV (default 9394305d4ff5, "tip" accepted),
# FC_TOOLS_REV (default 2fa31723e525). An existing clone is never touched.
set -u

# name|origin|sha256
FILES=(
    "installed-env.tar.xz|ftp://ftp.freecalypso.org/pub/GSM/TI_src/wine/installed-env.tar.xz|befbb2ee73aae77368f1e37fae7e170e27944537648756482c2f77ba2efc0f0a"
    "nowhine.c|ftp://ftp.freecalypso.org/pub/GSM/TI_src/wine/nowhine.c|4266c289b709e61958e78eec24e1f8e141652738f00ea54ec32d400e3ce70674"
    "winebuild.sh|ftp://ftp.freecalypso.org/pub/GSM/TI_src/wine/winebuild.sh|b7bc74f444dcd843a2dc30425fd70d55803a5de06ff632fc09eba9250623853a"
    "README|ftp://ftp.freecalypso.org/pub/GSM/TI_src/wine/README|59e79ed8a7c48035f93b7ae5dfbd812f6014a2bd7d85dfacb12c971816f4595a"
    "compal-flash-boot-for-fc.bin|ftp://ftp.freecalypso.org/pub/GSM/FreeCalypso/compal-flash-boot-for-fc.bin|ffe3227324e507308a4d40c0e237a81d9c06b466ebea9cc63ad321c5dcb90dcd"
    "dsp-rom-3606-dump.txt|ftp://ftp.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt|e35798f50fd0a29aa61cd53e417c010d7f172582c7bc055211daab8af1e05470"
    "dsp-rom-3311-dump.txt|ftp://ftp.freecalypso.org/pub/GSM/Calypso/dsp-rom-3311-dump.txt|543d7f23ff10494375ae77fc3dfc95526f93dbc5348549ff6299347d24837d64"
    "sms-coding-utils-latest.tar.bz2|https://www.freecalypso.org/pub/GSM/FreeCalypso/sms-coding-utils-latest.tar.bz2|008ca3b428f67ce385c5e124f71121534955aee025bd44bf94912f844f52ec53"
)
HG_BASE="https://hg.themyscira.org"
FC_MAGNETITE_REV="${FC_MAGNETITE_REV:-9394305d4ff5}"
FC_TOOLS_REV="${FC_TOOLS_REV:-2fa31723e525}"

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${FREECALYPSO_CACHE:-}" ]; then CACHE="$FREECALYPSO_CACHE"
elif [ -f "$ICI/../build.sh" ]; then CACHE="$(cd "$ICI/.." && pwd)/.cache/freecalypso"
else CACHE=/opt/GSM/.cache/freecalypso; fi
DEST=""; CHECK=0; HG=""; NAMES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --cache) CACHE="${2:?--cache DIR}"; shift ;;
        --dest)  DEST="${2:?--dest DIR}"; shift ;;
        --check) CHECK=1 ;;
        --hg)    HG="${2:?--hg NAME DEST}"; HG_DEST="${3:?--hg NAME DEST}"; shift 2 ;;
        --list)  for e in "${FILES[@]}"; do IFS='|' read -r n u s <<<"$e"; printf '%-34s %s\n  %s\n' "$n" "$u" "$s"; done; exit 0 ;;
        -h|--help) sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "option inconnue : $1 (--help)" >&2; exit 2 ;;
        all) for e in "${FILES[@]}"; do NAMES+=("${e%%|*}"); done ;;
        *) NAMES+=("$1") ;;
    esac
    shift
done

sha256() { sha256sum "$1" | cut -d' ' -f1; }
entry() {   # $1 = name -> prints "url|sha"
    local e; for e in "${FILES[@]}"; do [ "${e%%|*}" = "$1" ] && { echo "${e#*|}"; return 0; }; done
    echo "freecalypso-fetch : fichier inconnu : $1 (--list)" >&2; return 1
}

# ── hg clone at a pinned revision ────────────────────────────────────────────
if [ -n "$HG" ]; then
    case "$HG" in
        fc-magnetite)      rev="$FC_MAGNETITE_REV" ;;
        freecalypso-tools) rev="$FC_TOOLS_REV" ;;
        *) echo "--hg : fc-magnetite ou freecalypso-tools, pas $HG" >&2; exit 2 ;;
    esac
    if [ -d "$HG_DEST/.hg" ] || [ -d "$HG_DEST/.git" ]; then
        echo "$HG : deja present dans $HG_DEST (non touche)"; exit 0
    fi
    command -v hg >/dev/null 2>&1 || { echo "hg (mercurial) manquant : apt-get install mercurial" >&2; exit 1; }
    echo "hg clone $HG_BASE/$HG -> $HG_DEST (revision $rev)"
    hg clone -q "$HG_BASE/$HG" "$HG_DEST" || { rm -rf "$HG_DEST"; echo "hg clone $HG en echec" >&2; exit 1; }
    hg -R "$HG_DEST" update -q -r "$rev" || { echo "$HG : revision $rev introuvable" >&2; exit 1; }
    echo "$HG : $(hg -R "$HG_DEST" id -i)"
    exit 0
fi

[ ${#NAMES[@]} -gt 0 ] || { echo "rien a faire : NAME... ou all (--help)" >&2; exit 2; }

# ── download with resume: curl, else wget ────────────────────────────────────
# generous: 60 s to connect, abort only below 256 B/s for 10 min, 5 retries
telecharger() {   # $1 = url, $2 = partial file (kept between attempts)
    if command -v curl >/dev/null 2>&1; then
        curl -fL -sS -C - --retry 5 --retry-delay 15 --retry-all-errors \
             --connect-timeout 60 --speed-limit 256 --speed-time 600 \
             -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --continue --timeout=60 --tries=5 --waitretry=15 --read-timeout=600 -O "$2" "$1"
    else
        echo "ni curl ni wget" >&2; return 1
    fi
}

mkdir -p "$CACHE" || { echo "cache $CACHE : creation impossible" >&2; exit 1; }
ko=0
for n in "${NAMES[@]}"; do
    e="$(entry "$n")" || { ko=1; continue; }
    url="${e%%|*}"; sha="${e#*|}"; f="$CACHE/$n"
    if [ -s "$f" ] && [ "$(sha256 "$f")" = "$sha" ]; then
        echo "$n : en cache, SHA256 verifie ($CACHE)"
    elif [ "$CHECK" = 1 ]; then
        echo "$n : ABSENT ou SHA256 different dans $CACHE" >&2; ko=1; continue
    else
        [ -e "$f" ] && echo "$n : SHA256 different de l'attendu, retelechargement" >&2
        rm -f "$f"
        echo "$n : telechargement $url"
        ok=0
        for essai in 1 2; do
            telecharger "$url" "$f.part"; rc=$?
            # a resumed file already complete can make curl/ftp return an
            # error: the hash decides, not the exit code
            if [ -s "$f.part" ] && [ "$(sha256 "$f.part")" = "$sha" ]; then ok=1; break; fi
            if [ -s "$f.part" ] && [ "$rc" = 0 ]; then
                echo "$n : SHA256 DIFFERENT apres telechargement complet" >&2
                echo "   attendu $sha" >&2
                echo "   obtenu  $(sha256 "$f.part")" >&2
                rm -f "$f.part"; break        # a full download with a bad hash: no retry
            fi
            echo "$n : telechargement interrompu (code $rc), nouvel essai avec reprise" >&2
        done
        if [ "$ok" = 1 ]; then
            mv -f "$f.part" "$f"; echo "$n : telecharge, SHA256 verifie"
        else
            [ -s "$f.part" ] || rm -f "$f.part"
            echo "$n : ECHEC - fichier corrompu ou injoignable, rien n'est garde sous ce nom" >&2
            echo "   origine : $url" >&2
            ko=1; continue
        fi
    fi
    if [ -n "$DEST" ]; then
        if [ -s "$DEST/$n" ] && [ "$(sha256 "$DEST/$n")" = "$sha" ]; then :
        else mkdir -p "$DEST" && install -m644 "$f" "$DEST/$n" && echo "$n -> $DEST/$n" || { echo "$n : copie vers $DEST impossible" >&2; ko=1; }
        fi
    fi
done
exit $ko
