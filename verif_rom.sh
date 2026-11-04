#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
#
# verif_rom.sh - preuve que les copies de la mask-ROM DSP Calypso 3606 servies par
# les miroirs (et toute copie locale) sont, octet pour octet, le dump publie par
# FreeCalypso : https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
#
# Le script ne fait confiance a personne, pas meme a lui-meme : il retelecharge
# l'original chez FreeCalypso, calcule SHA-256 et SHA-512 de chaque copie, et
# compare chaque copie a l'original avec cmp (octet par octet).
#
#   ./verif_rom.sh                       miroirs par defaut
#   ./verif_rom.sh --local FICHIER       verifie aussi une copie locale (repetable)
#   ./verif_rom.sh --mirror URL          ajoute un miroir (repetable)
#   ./verif_rom.sh --garder DIR          conserve les fichiers telecharges dans DIR
#
# Code de sortie : 0 tout identique ; 1 au moins une copie differe ou manque ;
# 2 original FreeCalypso injoignable (comparaison au SHA-256 de reference seule).
#
# A la main, sans ce script :
#   curl -fsSL https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt | sha256sum
#   curl -fsSL <miroir> | sha256sum        # meme somme attendue
set -u

ORIGINAL=https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
# SHA-256 releve sur l'original le 2026-10-29 (721860 octets).
REF_SHA256=e35798f50fd0a29aa61cd53e417c010d7f172582c7bc055211daab8af1e05470
MIRRORS=(
    # gist epingle sur sa revision : le contenu de cette URL ne peut plus changer
    https://gist.githubusercontent.com/bbaranoff/ba2746dd4fe6117475d95f791bf7df35/raw/16a4e486776315ecdf6c8972c58e877fa19785c5/calypso_dsp.txt
    https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env/dsp-rom-3606-dump.txt
)
LOCAUX=(); GARDER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --local)  LOCAUX+=("${2:?--local FICHIER}"); shift ;;
        --mirror) MIRRORS+=("${2:?--mirror URL}"); shift ;;
        --garder) GARDER="${2:?--garder DIR}"; shift ;;
        -h|--help) sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1 (--help)" >&2; exit 2 ;;
    esac
    shift
done
command -v curl >/dev/null || { echo "curl manquant" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sha256() { sha256sum "$1" | cut -d' ' -f1; }
sha512() { sha512sum "$1" | cut -d' ' -f1; }
taille() { wc -c < "$1" | tr -d ' '; }

echo "== Original : $ORIGINAL"
orig="$TMP/original.txt"
if curl -fsSL --retry 2 -o "$orig" "$ORIGINAL"; then
    o256=$(sha256 "$orig")
    echo "   $(taille "$orig") octets"
    echo "   SHA-256 $o256"
    echo "   SHA-512 $(sha512 "$orig")"
    if [ "$o256" = "$REF_SHA256" ]; then
        echo "   = SHA-256 de reference du depot"
    else
        echo "   ATTENTION : l'original FreeCalypso a change depuis la reference ($REF_SHA256)"
    fi
    attendu="$o256"; code=0
else
    echo "   injoignable : comparaison au SHA-256 de reference seule ($REF_SHA256)"
    orig=""; attendu="$REF_SHA256"; code=2
fi

ko=0; n=0
verifier() {   # $1 = libelle, $2 = fichier
    n=$((n + 1))
    local s; s=$(sha256 "$2")
    echo "   $(taille "$2") octets"
    echo "   SHA-256 $s"
    echo "   SHA-512 $(sha512 "$2")"
    if [ "$s" != "$attendu" ]; then
        echo "   DIFFERENT de l'original"; ko=$((ko + 1)); return
    fi
    if [ -n "$orig" ]; then
        if cmp -s "$orig" "$2"; then echo "   IDENTIQUE a l'original (SHA-256 et cmp octet par octet)"
        else echo "   DIFFERENT de l'original (cmp)"; ko=$((ko + 1)); fi
    else
        echo "   identique au SHA-256 de reference"
    fi
}

i=0
for url in "${MIRRORS[@]}"; do
    i=$((i + 1)); f="$TMP/miroir$i.txt"
    echo; echo "== Miroir $i : $url"
    if curl -fsSL --retry 2 -o "$f" "$url"; then verifier "miroir $i" "$f"
    else n=$((n + 1)); ko=$((ko + 1)); echo "   injoignable"; fi
done
for l in "${LOCAUX[@]}"; do
    echo; echo "== Local : $l"
    if [ -r "$l" ]; then verifier "$l" "$l"
    else n=$((n + 1)); ko=$((ko + 1)); echo "   illisible"; fi
done

if [ -n "$GARDER" ]; then
    mkdir -p "$GARDER" && cp "$TMP"/*.txt "$GARDER"/ && echo && echo "fichiers conserves dans $GARDER"
fi

echo
if [ "$ko" -gt 0 ]; then
    echo "VERDICT : ECHEC - $ko copie(s) sur $n differente(s) ou indisponible(s)"; exit 1
elif [ "$code" = 2 ]; then
    echo "VERDICT : $n copie(s) au SHA-256 de reference, original FreeCalypso non joint"; exit 2
else
    echo "VERDICT : OK - $n copie(s) identiques octet pour octet au dump FreeCalypso"; exit 0
fi
