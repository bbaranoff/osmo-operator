#!/bin/bash
# tools/features.sh - the optional groups and their dependency tree
# =============================================================================
# Sourced by tools/menuconfig.sh and build-iso.sh (iso_modules/00-options.sh).
# The table is tools/features.conf:
#
#   kind|id|depends|description
#
#   kind     docker  a component of the Dockerfile (OSMO_WITH_<ID>), chosen
#            lib     a component nobody chooses: built only when a selected
#                    id depends on it (Kconfig "select" of a hidden symbol)
#            iso     an optional iso_modules/NN-<id>.sh
#            core    a mandatory iso module (shown, never deselected)
#            alias   a name standing for several ids (old group names:
#                    --without=grgsm ...); "depends" = the ids
#   depends  ids this one needs, space separated. Deselecting an id deselects,
#            transitively, everything that depends on it; selecting one
#            selects what it depends on (Kconfig "depends on" + "select").
#
# The selection is a space separated list of SELECTED ids, or "all".
# =============================================================================

FEAT_CONF="${FEAT_CONF:-$(dirname "${BASH_SOURCE[0]}")/features.conf}"
declare -gA FEAT_KIND FEAT_DEPS FEAT_DESC FEAT_ALIAS
declare -ga FEAT_IDS

feat_load() {
    local kind id deps desc
    FEAT_IDS=(); FEAT_KIND=(); FEAT_DEPS=(); FEAT_DESC=(); FEAT_ALIAS=()
    while IFS='|' read -r kind id deps desc; do
        [[ "$kind" =~ ^[[:space:]]*(#|$) ]] && continue
        kind="${kind// /}"; id="${id// /}"
        deps="$(echo $deps)"; desc="$(echo "$desc" | sed 's/^ *//;s/ *$//')"
        if [ "$kind" = alias ]; then FEAT_ALIAS[$id]="$deps"; FEAT_DESC[$id]="$desc"; continue; fi
        [ -n "${FEAT_KIND[$id]:-}" ] && echo "features.conf : id en double : $id (${FEAT_KIND[$id]} et $kind)" >&2
        FEAT_IDS+=("$id"); FEAT_KIND[$id]="$kind"; FEAT_DEPS[$id]="$deps"; FEAT_DESC[$id]="$desc"
    done <"$FEAT_CONF"
}

# ids of one kind (or of all kinds), in table order
# (always status 0: under pipefail, "feat_ids x | xargs || ..." must not fall through)
feat_ids() { local i; for i in "${FEAT_IDS[@]}"; do if [ -z "${1:-}" ] || [ "${FEAT_KIND[$i]}" = "$1" ]; then echo "$i"; fi; done; return 0; }

# Expand "all" and keep core ids always selected. -> normalized list
feat_norm() {
    local sel="$1" i out=()
    for i in "${FEAT_IDS[@]}"; do
        if [ "$sel" = all ] || [ "${FEAT_KIND[$i]}" = core ] || [[ " $sel " == *" $i "* ]]; then out+=("$i"); fi
    done
    echo "${out[*]}"
}

feat_has() { [[ " $1 " == *" $2 "* ]]; }

# ids that depend on $1 (directly)
feat_rdeps() { local i; for i in "${FEAT_IDS[@]}"; do if feat_has "${FEAT_DEPS[$i]}" "$1"; then echo "$i"; fi; done; return 0; }

# Remove $2 and, transitively, everything depending on it. -> new list
feat_off() {
    local sel="$1" id="$2" r
    [ "${FEAT_KIND[$id]:-}" = core ] && { echo "$sel"; return; }
    sel=" $sel "; sel="${sel// $id / }"
    for r in $(feat_rdeps "$id"); do feat_has "$sel" "$r" && sel=" $(feat_off "$sel" "$r") "; done
    echo $sel
}

# Add $2 and, transitively, what it depends on. -> new list
feat_on() {
    local sel="$1" id="$2" d
    feat_has "$sel" "$id" || sel="$sel $id"
    for d in ${FEAT_DEPS[$id]:-}; do feat_has "$sel" "$d" || sel="$(feat_on "$sel" "$d")"; done
    echo $sel
}

# Libs: exactly those a selected id needs (transitively). -> new list
feat_libs() {
    local sel="" i d changed=1
    for i in $1; do [ "${FEAT_KIND[$i]:-}" = lib ] || sel="$sel $i"; done
    while [ "$changed" = 1 ]; do
        changed=0
        for i in $sel; do
            for d in ${FEAT_DEPS[$i]:-}; do
                if [ "${FEAT_KIND[$d]:-}" = lib ] && ! feat_has "$sel" "$d"; then sel="$sel $d"; changed=1; fi
            done
        done
    done
    echo $sel
}

# Make a selection consistent: drop every id whose dependency is missing,
# then keep exactly the libs the remaining ids need.
feat_close() {
    local sel; sel="$(feat_libs "$(feat_norm "$1")")"
    local changed=1 i d
    while [ "$changed" = 1 ]; do
        changed=0
        for i in $sel; do
            for d in ${FEAT_DEPS[$i]}; do
                feat_has "$sel" "$d" || { sel="$(feat_off "$sel" "$i")"; changed=1; break 2; }
            done
        done
    done
    feat_libs "$sel"
}

# The selected ids that were dropped by feat_close (for a warning).
feat_dropped() { local a="$1" b="$2" i; for i in $a; do feat_has "$b" "$i" || echo "$i"; done; }

# Dependency tree of one id (indented, for the menu's help and --tree).
feat_tree() {
    local id="$1" pre="${2:-}" d
    echo "${pre}${id}  - ${FEAT_DESC[$id]}"
    for d in ${FEAT_DEPS[$id]}; do feat_tree "$d" "$pre    "; done
}

# Expand "all" and aliases into component ids (docker kind). -> list
feat_expand() {
    local x out=()
    for x in ${1//,/ }; do
        if [ "$x" = all ]; then out+=($(feat_ids docker))
        elif [ -n "${FEAT_ALIAS[$x]:-}" ]; then out+=(${FEAT_ALIAS[$x]})
        elif [ "${FEAT_KIND[$x]:-}" = docker ]; then out+=("$x")
        else echo "features : composant inconnu : $x (connus : $(feat_ids docker | xargs) ; alias : ${!FEAT_ALIAS[*]} ; all)" >&2; return 1
        fi
    done
    echo "${out[*]}"
}

# The docker components switched on by the environment (OSMO_WITH_<ID>=0|1,
# default 1; an old group variable, OSMO_WITH_GRGSM=0..., switches off its
# alias members). -> list
feat_docker_from_env() {
    local i a v out=()
    for i in $(feat_ids docker); do
        v="OSMO_WITH_${i^^}"; [ "${!v:-1}" = 1 ] || continue
        for a in "${!FEAT_ALIAS[@]}"; do
            if feat_has "${FEAT_ALIAS[$a]}" "$i"; then v="OSMO_WITH_${a^^}"; [ "${!v:-1}" = 1 ] || continue 2; fi
        done
        out+=("$i")
    done
    echo "${out[*]}"
}

# Export OSMO_WITH_<ID>=0|1 for every docker and lib id from a list of docker
# components (libs follow), plus OSMO_STAGE_LTE (the Dockerfile stage `lte`
# carries the 4G and pmbootstrap). The closed list -> FEAT_BUILD_SEL.
# Call it directly, not in $(...): the exports must reach the caller.
feat_export_build() {
    local sel i; sel="$(feat_close "$1")"
    FEAT_BUILD_SEL="$(for i in $sel; do case "${FEAT_KIND[$i]}" in docker|lib) echo "$i" ;; esac; done | xargs)"
    for i in "${FEAT_IDS[@]}"; do
        case "${FEAT_KIND[$i]}" in docker|lib) ;; *) continue ;; esac
        if feat_has "$sel" "$i"; then export "OSMO_WITH_${i^^}=1"; else export "OSMO_WITH_${i^^}=0"; fi
    done
    if [ "${OSMO_WITH_LTE:-0}" = 1 ] || [ "${OSMO_WITH_PMBOOTSTRAP:-0}" = 1 ]; then export OSMO_STAGE_LTE=1; else export OSMO_STAGE_LTE=0; fi
    return 0
}

# The OSMO_WITH_* list for build args (docker + lib ids, then the stage).
feat_build_args() {
    local i v
    for i in "${FEAT_IDS[@]}"; do
        case "${FEAT_KIND[$i]}" in docker|lib) v="OSMO_WITH_${i^^}"; echo "$v=${!v:-1}" ;; esac
    done
    echo "OSMO_STAGE_LTE=${OSMO_STAGE_LTE:-1}"
}
