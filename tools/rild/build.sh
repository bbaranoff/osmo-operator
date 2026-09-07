#!/bin/bash
# build.sh - compile osmo-rild pour Android 13 x86_64 (l image Waydroid).
#
# Il faut le NDK Android (r26 ou plus) et l en-tete ril.h d AOSP :
#   NDK=/chemin/android-ndk-r26d  RIL_H=/chemin/vers/telephony  ./build.sh
#
# ril.h se recupere sur android.googlesource.com :
#   platform/hardware/ril/+/refs/tags/android-13.0.0_r1/include/telephony/ril.h
# et doit etre pose dans <RIL_H>/telephony/ril.h (le #include est
# <telephony/ril.h>).
#
# Le binaire produit ne depend que de la libc d Android et de libdl : il charge
# libril.so et l implementation a l execution, par dlopen. C est voulu - il doit
# marcher avec les bibliotheques DE L IMAGE, pas avec celles d une autre.
set -eu
NDK="${NDK:-/var/tmp/osmo-ril-src/android-ndk-r26d}"
RIL_H="${RIL_H:-/var/tmp/osmo-ril-src/include}"
API="${API:-33}"                       # 33 = Android 13
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/osmo-rild}"

CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android$API-clang"
[ -x "$CC" ] || { echo "compilateur introuvable : $CC" >&2; exit 1; }
[ -f "$RIL_H/telephony/ril.h" ] || { echo "ril.h introuvable dans $RIL_H/telephony/" >&2; exit 1; }

# -DRIL_SHLIB : dans ril.h, struct RIL_Env et RIL_Init ne sont declarees que
# sous ce drapeau (c est ainsi que le rild d AOSP se compile lui-meme).
"$CC" -Wall -Wextra -O2 -DRIL_SHLIB -I"$RIL_H" -o "$OUT" "$HERE/osmo-rild.c" -ldl
echo "$OUT"
file "$OUT" 2>/dev/null | head -c 140; echo
