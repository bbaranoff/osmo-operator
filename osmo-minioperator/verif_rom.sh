#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
#
# verif_rom.sh - proof that the copies of the Calypso 3606 DSP mask ROM served by
# the mirrors (and any local copy) are, byte for byte, the dump published by
# FreeCalypso: https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
#
# The script trusts no one, not even itself: it downloads the original again
# from FreeCalypso, computes SHA-256 and SHA-512 of each copy, and compares
# each copy to the original with cmp (byte by byte).
#
#   ./verif_rom.sh                       default mirrors
#   ./verif_rom.sh --local FILE          also check a local copy (repeatable)
#   ./verif_rom.sh --mirror URL          add a mirror (repeatable)
#   ./verif_rom.sh --garder DIR          keep the downloaded files in DIR
#
# Exit code: 0 all identical; 1 at least one copy differs or is missing;
# 2 FreeCalypso original unreachable (compared to the reference SHA-256 only).
#
# By hand, without this script:
#   curl -fsSL https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt | sha256sum
#   curl -fsSL <mirror> | sha256sum        # same sum expected
set -u

ORIGINAL=https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
# SHA-256 taken from the original on 2026-10-29 (721860 bytes).
REF_SHA256=e35798f50fd0a29aa61cd53e417c010d7f172582c7bc055211daab8af1e05470
MIRRORS=(
    # gist pinned to its revision: the content of this URL can no longer change
    https://gist.githubusercontent.com/bbaranoff/ba2746dd4fe6117475d95f791bf7df35/raw/16a4e486776315ecdf6c8972c58e877fa19785c5/calypso_dsp.txt
    https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env/dsp-rom-3606-dump.txt
)
LOCAUX=(); GARDER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --local)  LOCAUX+=("${2:?--local FILE}"); shift ;;
        --mirror) MIRRORS+=("${2:?--mirror URL}"); shift ;;
        --garder) GARDER="${2:?--garder DIR}"; shift ;;
        -h|--help) sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
    esac
    shift
done
command -v curl >/dev/null || { echo "curl missing" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sha256() { sha256sum "$1" | cut -d' ' -f1; }
sha512() { sha512sum "$1" | cut -d' ' -f1; }
taille() { wc -c < "$1" | tr -d ' '; }

echo "== Original: $ORIGINAL"
orig="$TMP/original.txt"
if curl -fsSL --retry 2 -o "$orig" "$ORIGINAL"; then
    o256=$(sha256 "$orig")
    echo "   $(taille "$orig") bytes"
    echo "   SHA-256 $o256"
    echo "   SHA-512 $(sha512 "$orig")"
    if [ "$o256" = "$REF_SHA256" ]; then
        echo "   = reference SHA-256 of the repo"
    else
        echo "   WARNING: the FreeCalypso original changed since the reference ($REF_SHA256)"
    fi
    attendu="$o256"; code=0
else
    echo "   unreachable: comparing to the reference SHA-256 only ($REF_SHA256)"
    orig=""; attendu="$REF_SHA256"; code=2
fi

ko=0; n=0
verifier() {   # $1 = label, $2 = file
    n=$((n + 1))
    local s; s=$(sha256 "$2")
    echo "   $(taille "$2") bytes"
    echo "   SHA-256 $s"
    echo "   SHA-512 $(sha512 "$2")"
    if [ "$s" != "$attendu" ]; then
        echo "   DIFFERENT from the original"; ko=$((ko + 1)); return
    fi
    if [ -n "$orig" ]; then
        if cmp -s "$orig" "$2"; then echo "   IDENTICAL to the original (SHA-256 and byte-by-byte cmp)"
        else echo "   DIFFERENT from the original (cmp)"; ko=$((ko + 1)); fi
    else
        echo "   identical to the reference SHA-256"
    fi
}

i=0
for url in "${MIRRORS[@]}"; do
    i=$((i + 1)); f="$TMP/miroir$i.txt"
    echo; echo "== Mirror $i: $url"
    if curl -fsSL --retry 2 -o "$f" "$url"; then verifier "mirror $i" "$f"
    else n=$((n + 1)); ko=$((ko + 1)); echo "   unreachable"; fi
done
for l in "${LOCAUX[@]}"; do
    echo; echo "== Local: $l"
    if [ -r "$l" ]; then verifier "$l" "$l"
    else n=$((n + 1)); ko=$((ko + 1)); echo "   unreadable"; fi
done

if [ -n "$GARDER" ]; then
    mkdir -p "$GARDER" && cp "$TMP"/*.txt "$GARDER"/ && echo && echo "files kept in $GARDER"
fi

echo
if [ "$ko" -gt 0 ]; then
    echo "VERDICT: FAILED - $ko of $n copies different or unavailable"; exit 1
elif [ "$code" = 2 ]; then
    echo "VERDICT: $n copies match the reference SHA-256, FreeCalypso original not reached"; exit 2
else
    echo "VERDICT: OK - $n copies identical byte for byte to the FreeCalypso dump"; exit 0
fi
