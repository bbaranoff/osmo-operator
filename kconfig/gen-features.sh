#!/bin/bash
# kconfig/gen-features.sh - Kconfig of the docker groups and iso modules
# =============================================================================
# tools/features.conf stays the single source of the dependency tree (it is
# also read by build-iso.sh at build time). This writes, into $1 (default
# kconfig/generated):
#
#   Kconfig.groups    config FEAT_<ID>      the docker groups (OSMO_WITH_<ID>)
#   Kconfig.modules   config ISO_MOD_<ID>   the optional iso modules
#                     config ISO_CORE_<ID>  the mandatory ones, selected by
#                                           TARGET_ISO (shown -*-)
#
# "depends" of features.conf -> "depends on". The help of a module is the
# first paragraph of the header of its iso_modules/NN-<id>.sh.
#
# KCONFIG_EXTRA below: what features.conf cannot say - which image a module
# is meaningful for. Kconfig syntax, appended to the symbol.
# =============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."
OUT="${1:-kconfig/generated}"
. tools/features.sh; feat_load

# Mandatory modules that only exist for one architecture: selected by
# ISO_CORE only under this condition.
declare -A KCONFIG_SELECT_IF=(
    [arm-natif]="ARCH_ARM64"
    [rpi-image]="ARCH_ARM64"
)
declare -A KCONFIG_EXTRA=(
    [arm-natif]="depends on ARCH_ARM64"
    [rpi-image]="depends on ARCH_ARM64"
    [lite]="depends on ISO_IMAGE_LITE || ISO_IMAGE_ALL"
    [ttcn]="depends on !ISO_IMAGE_LITE"
    [extensions-gnome]="depends on ISO_IMAGE_DESKTOP || ISO_IMAGE_ALL"
)

sym() {   # id -> Kconfig symbol
    local u="${1^^}"; u="${u//-/_}"
    case "${FEAT_KIND[$1]}" in
        docker|lib) echo "FEAT_$u" ;; iso) echo "ISO_MOD_$u" ;; core) echo "ISO_CORE_$u" ;;
    esac
}
deps_expr() {   # id -> "A && B" or "" (libs are selected, not depended on)
    local d out=()
    for d in ${FEAT_DEPS[$1]}; do
        [ -n "${FEAT_KIND[$d]:-}" ] || { echo "gen-features: $1 depend de $d, inconnu" >&2; exit 1; }
        [ "${FEAT_KIND[$d]}" = lib ] && continue
        out+=("$(sym "$d")")
    done
    local IFS='&'; local s="${out[*]}"; echo "${s//&/ && }"
}
qdesc() { local s="$1"; s="${s//\\/\\\\}"; echo "\"${s//\"/\\\"}\""; }

# First paragraph of the header comment of the module's script.
module_help() {
    local f; f="$(ls iso_modules/[0-9][0-9]-"$1".sh 2>/dev/null | head -1)"
    [ -n "$f" ] || return 0
    echo "	  Script : $f"
    # Header paragraphs; the "Sourced by build-iso.sh..." boilerplate one is
    # skipped; at most the first 3 others, 25 lines.
    local body
    body="$(awk 'NR==1 && /^#!/{next}
         !/^#/{exit}
         /^# *[=─━]{5,}/{next}
         /^#[[:space:]]*$/{ if (cur != "") { if (cur !~ /Sourced by/) { out = out (np ? "\t  \n" : "") cur; np++ } cur = "" }
                            if (np >= 3) exit; next }
         { sub(/^# ?/, ""); cur = cur "\t  " $0 "\n" }
         END { if (cur != "" && cur !~ /Sourced by/ && np < 3) out = out (np ? "\t  \n" : "") cur
               n = split(out, l, "\n"); for (i = 1; i <= n && i <= 25; i++) if (l[i] != "" || i < n) print l[i] }' "$f")"
    [ -n "$body" ] && { echo "	  "; echo "$body"; }
    return 0
}

emit() {   # id
    local id="$1" s d k dd
    s="$(sym "$id")"; d="$(deps_expr "$id")"; k="${FEAT_KIND[$id]}"
    echo "config $s"
    if [ "$k" = lib ]; then echo "	bool"; else echo "	bool $(qdesc "$id : ${FEAT_DESC[$id]}")"; fi
    for dd in ${FEAT_DEPS[$id]}; do [ "${FEAT_KIND[$dd]}" = lib ] && echo "	select $(sym "$dd")"; done
    case "$k" in
        docker) echo "	default y" ;;
        iso)    echo "	default y"; echo "	depends on TARGET_ISO" ;;
        core)   echo "	depends on TARGET_ISO" ;;
    esac
    [ -n "$d" ] && echo "	depends on $d"
    [ -n "${KCONFIG_EXTRA[$id]:-}" ] && echo "	${KCONFIG_EXTRA[$id]}"
    echo "	help"
    case "$k" in
        docker) echo "	  Composant '$id' du Dockerfile : OSMO_WITH_${id^^}=0|1,"
                echo "	  build.sh --without=$id. Decoche, BuildKit ne construit ni lui"
                echo "	  ni ce qu'il est seul a selectionner, et l'ISO perd les modules"
                echo "	  qui en dependent." ;;
        lib)    echo "	  ${FEAT_DESC[$id]}"
                echo "	  Jamais choisi directement : construit seulement si un"
                echo "	  composant coche le selectionne (OSMO_WITH_${id^^})." ;;
        iso)    module_help "$id"
                echo "	  "
                echo "	  Decoche : build-iso.sh --modules=... sans '$id'." ;;
        core)   module_help "$id"
                echo "	  "
                echo "	  Module obligatoire : selectionne par TARGET_ISO." ;;
    esac
    echo
}

# Depth-first order: an id, then the ids whose dependencies are all already
# out and that depend on it - mconf then shows them indented under it.
tree_order() {   # kind -> ordered ids
    local kind="$1" done=" " i
    _visit() {
        local x="$1" y d ok
        done="$done$x "; echo "$x"
        for y in $(feat_ids "$kind"); do
            [[ "$done" == *" $y "* ]] && continue
            feat_has "${FEAT_DEPS[$y]}" "$x" || continue
            ok=1; for d in ${FEAT_DEPS[$y]}; do
                [ "${FEAT_KIND[$d]}" = "$kind" ] && [[ "$done" != *" $d "* ]] && ok=0
            done
            [ "$ok" = 1 ] && _visit "$y"
        done
    }
    for i in $(feat_ids "$kind"); do [[ "$done" == *" $i "* ]] || _visit "$i"; done
}

mkdir -p "$OUT"
hdr="# GENERATED by kconfig/gen-features.sh from tools/features.conf - do not edit"

{
    echo "$hdr"; echo
    for i in $(tree_order docker); do emit "$i"; done
    for i in $(feat_ids lib); do emit "$i"; done
} >"$OUT/Kconfig.groups.tmp"

{
    echo "$hdr"; echo
    for i in $(tree_order iso); do emit "$i"; done
    echo 'comment "--- Modules obligatoires de l ISO (toujours construits) ---"'; echo
    echo "config ISO_CORE"
    echo "	def_bool TARGET_ISO"
    for i in $(feat_ids core); do echo "	select $(sym "$i")${KCONFIG_SELECT_IF[$i]:+ if ${KCONFIG_SELECT_IF[$i]}}"; done
    echo
    for i in $(tree_order core); do emit "$i"; done
} >"$OUT/Kconfig.modules.tmp"

# ── Native install: install_modules/NN-<slug>.sh (INST_REGISTER, INST_DEPS) ─
# install.sh --skip <slugs> for the ones left out; prereqs always runs.
{
    echo "$hdr (and install_modules/)"; echo
    for f in install_modules/[0-9][0-9]-*.sh; do
        slug="$(sed -n 's/^INST_REGISTER \([^ ]*\) .*/\1/p' "$f" | head -1)"
        desc="$(sed -n 's/^INST_REGISTER [^ ]* "\(.*\)".*/\1/p' "$f" | head -1)"
        [ -n "$slug" ] || continue
        deps="$(sed -n "s/^INST_DEPS\[$slug\]=\"\(.*\)\"/\1/p" "$f" | head -1)"
        u="${slug^^}"; u="${u//-/_}"
        echo "config NATIVE_MOD_$u"
        if [ "$slug" = prereqs ]; then
            echo "	def_bool TARGET_NATIVE"
        else
            echo "	bool $(qdesc "$slug : $desc")"
            echo "	default y"
            echo "	depends on TARGET_NATIVE && NATIVE_INSTALL"
        fi
        dexpr=""; for d in $deps; do du="${d^^}"; dexpr="${dexpr:+$dexpr && }NATIVE_MOD_${du//-/_}"; done
        [ -n "$dexpr" ] && echo "	depends on $dexpr"
        echo "	help"
        echo "	  Script : $f (install.sh)"
        b="$(awk 'NR==1 && /^#!/{next} !/^#/{exit} {sub(/^# ?/,""); print "\t  " $0}' "$f" | head -12)"
        [ -n "$b" ] && { echo "	  "; echo "$b"; }
        echo "	  "
        echo "	  Decoche : install.sh --skip $slug."
        echo
    done
} >"$OUT/Kconfig.native.tmp"

# Rewrite only when changed (make does not rerun what depends on them).
for f in Kconfig.groups Kconfig.modules Kconfig.native; do
    if cmp -s "$OUT/$f.tmp" "$OUT/$f"; then rm -f "$OUT/$f.tmp"; else mv -f "$OUT/$f.tmp" "$OUT/$f"; fi
done
