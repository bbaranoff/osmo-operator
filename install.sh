#!/bin/bash
# =============================================================================
#  install.sh - installation native, par modules
# =============================================================================
#
#  Meme architecture que run.sh : ce fichier n'est qu'un moteur. Chaque etape
#  vit dans install_modules/NN-<slug>.sh et respecte le contrat decrit dans
#  install_modules/_lib/inst.sh.
#
#      sudo ./install.sh                tout
#      ./install.sh --list              les etapes, sans rien faire
#      ./install.sh --dry-run           deroule sans effet de bord
#      sudo ./install.sh --only deps    une seule etape
#      sudo ./install.sh --skip build   tout sauf celle-la
#      ./install.sh --check             ce qui est deja installe
#
#  Ou : GSM_ROOT (defaut /opt/GSM) recoit sources et binaires.
#
#  SI VOUS DECOUVREZ LE PROJET, PREFEREZ DOCKER : `./tools/make-docker-image.sh` produit une image
#  complete et reproductible. Cette installation native s'adresse a ceux qui
#  veulent travailler sur les sources.
#
#  La liste des paquets n'est pas dupliquee ici : elle est EXTRAITE du
#  Dockerfile, qui reste la reference. Les deux ne peuvent donc pas diverger.
# -----------------------------------------------------------------------------
set -uo pipefail

INST_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODDIR="$INST_TREE/install_modules"
: "${GSM_ROOT:=/opt/GSM}"
: "${OSMOCOM_HOME:=$HOME/.osmocom}"
export INST_TREE GSM_ROOT OSMOCOM_HOME

DRY=0 ONLY="" SKIP="" ACTION=install
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    ACTION=list ;;
        --check)   ACTION=check ;;
        --dry-run) DRY=1 ;;
        --only)    ONLY="${2:-}"; shift ;;
        --skip)    SKIP="${2:-}"; shift ;;
        -h|--help) sed -n '3,24p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
        *) printf 'option inconnue : %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1; C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'; C_DIM=$'\033[2m'; C_Z=$'\033[0m'
else
    TTY=0; C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_Z=""
fi
begin() { if [ $TTY -eq 1 ]; then printf '[ %s..%s ] %s' "$C_DIM" "$C_Z" "$1"; else printf '[ .. ] %s\n' "$1"; fi; }
end()   { [ $TTY -eq 1 ] && printf '\r\033[K'; printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
          [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"; printf '\n'; }

LOGDIR="${LOG_DIR:-/tmp/osmo-nitb-install}"; mkdir -p "$LOGDIR" 2>/dev/null || true

[ -d "$MODDIR" ] || { printf 'install_modules/ introuvable\n' >&2; exit 2; }
. "$MODDIR/_lib/inst.sh"
shopt -s nullglob; for f in "$MODDIR"/[0-9][0-9]-*.sh; do . "$f"; done; shopt -u nullglob
[ ${#INST_ORDER[@]} -eq 0 ] && { printf 'aucun module d installation\n' >&2; exit 2; }

in_csv() { case ",$1," in *",$2,"*) return 0;; esac; return 1; }
selected=()
for s in "${INST_ORDER[@]}"; do
    [ -n "$ONLY" ] && { in_csv "$ONLY" "$s" || continue; }
    [ -n "$SKIP" ] && { in_csv "$SKIP" "$s" && continue; }
    selected+=("$s")
done

if [ "$ACTION" = list ]; then
    printf 'Etapes - %d, dans cet ordre\n\n' "${#selected[@]}"
    for s in "${selected[@]}"; do
        printf '  %-10s %-38s %s%s\n' "$s" "${INST_DESC[$s]}" \
            "$([ "${INST_REQUIRED[$s]}" = 1 ] && echo obligatoire || echo optionnelle)" \
            "$([ -n "${INST_DEPS[$s]}" ] && echo "  apres: ${INST_DEPS[$s]}")"
    done
    printf '\nGSM_ROOT = %s\n' "$GSM_ROOT"
    exit 0
fi

if [ "$ACTION" = check ]; then
    rc=0
    for s in "${selected[@]}"; do
        p="$(inst_prefix "$s")"
        if declare -F "${p}_done" >/dev/null; then
            if "${p}_done" >/dev/null 2>&1; then end " OK " "$C_OK" "${INST_DESC[$s]}" "deja installe"
            else end "----" "$C_SK" "${INST_DESC[$s]}" "a faire"; rc=1; fi
        else
            end " ?  " "$C_DIM" "${INST_DESC[$s]}" "pas de controle"
        fi
    done
    exit $rc
fi

# root : exige seulement si une etape retenue le demande
need_root=0
for s in "${selected[@]}"; do [ "${INST_ROOT[$s]}" = 1 ] && need_root=1; done
if [ $DRY -eq 0 ] && [ $need_root -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    printf 'Cette installation ecrit dans %s, /usr/local et /etc/osmocom.\n' "$GSM_ROOT" >&2
    printf 'Relancez avec sudo, ou inspectez sans rien modifier :  ./install.sh --dry-run\n' >&2
    exit 2
fi

declare -A STATE=()
nb_ok=0 nb_skip=0 nb_fail=0
for s in "${selected[@]}"; do
    p="$(inst_prefix "$s")"; log="$LOGDIR/$s.log"
    _INST_REASON=""; _INST_HINT=""

    dep_ko=""
    for d in ${INST_DEPS[$s]}; do
        case "${STATE[$d]:-absent}" in ok|skip) ;; *) dep_ko="$d"; break;; esac
    done
    if [ -n "$dep_ko" ]; then
        end "SKIP" "$C_SK" "${INST_DESC[$s]}" "depend de $dep_ko, non satisfaite"
        STATE[$s]=skip; nb_skip=$((nb_skip+1)); continue
    fi

    begin "${INST_DESC[$s]}"

    if declare -F "${p}_done" >/dev/null && "${p}_done" >>"$log" 2>&1; then
        end "SKIP" "$C_SK" "${INST_DESC[$s]}" "deja installe"
        STATE[$s]=skip; nb_skip=$((nb_skip+1)); continue
    fi

    if declare -F "${p}_check" >/dev/null; then
        "${p}_check" >>"$log" 2>&1; rc=$?
        if [ $rc -eq $INST_RC_FAIL ]; then
            end "FAIL" "$C_KO" "${INST_DESC[$s]}" "${_INST_REASON:-prerequis non satisfait}"
            [ -n "$_INST_HINT" ] && printf '       %s→ %s%s\n' "$C_DIM" "$_INST_HINT" "$C_Z"
            printf '       %sjournal : %s%s\n' "$C_DIM" "$log" "$C_Z"
            nb_fail=$((nb_fail+1)); STATE[$s]=fail
            [ "${INST_REQUIRED[$s]}" = 1 ] && { printf '\ninstallation interrompue\n'; exit 1; }
            continue
        fi
    fi

    if [ $DRY -eq 1 ]; then
        end " -- " "$C_DIM" "${INST_DESC[$s]}" "simule"; STATE[$s]=ok; continue
    fi

    "${p}_run" >>"$log" 2>&1; rc=$?
    case $rc in
        $INST_RC_DONE) end "SKIP" "$C_SK" "${INST_DESC[$s]}" "${_INST_REASON:-rien a faire}"
                       STATE[$s]=skip; nb_skip=$((nb_skip+1)); continue ;;
        $INST_RC_FAIL) end "FAIL" "$C_KO" "${INST_DESC[$s]}" "${_INST_REASON:-echec}"
                       [ -n "$_INST_HINT" ] && printf '       %s→ %s%s\n' "$C_DIM" "$_INST_HINT" "$C_Z"
                       printf '       %sjournal : %s%s\n' "$C_DIM" "$log" "$C_Z"
                       nb_fail=$((nb_fail+1)); STATE[$s]=fail
                       [ "${INST_REQUIRED[$s]}" = 1 ] && { printf '\ninstallation interrompue\n'; exit 1; }
                       continue ;;
    esac

    # installer n'est pas avoir installe : on controle apres coup
    if declare -F "${p}_verify" >/dev/null; then
        if ! "${p}_verify" >>"$log" 2>&1; then
            end "FAIL" "$C_KO" "${INST_DESC[$s]}" "faite, mais le controle echoue : ${_INST_REASON:-}"
            [ -n "$_INST_HINT" ] && printf '       %s→ %s%s\n' "$C_DIM" "$_INST_HINT" "$C_Z"
            printf '       %sjournal : %s%s\n' "$C_DIM" "$log" "$C_Z"
            nb_fail=$((nb_fail+1)); STATE[$s]=fail
            [ "${INST_REQUIRED[$s]}" = 1 ] && { printf '\ninstallation interrompue\n'; exit 1; }
            continue
        fi
    fi

    end " OK " "$C_OK" "${INST_DESC[$s]}"; STATE[$s]=ok; nb_ok=$((nb_ok+1))
done

printf '\n%d ok · %d ignores · %d echecs\n' "$nb_ok" "$nb_skip" "$nb_fail"
if [ $nb_fail -eq 0 ] && [ $DRY -eq 0 ]; then
    printf '\n  %sverifier%s   ./install.sh --check\n'          "$C_DIM" "$C_Z"
    printf '  %slancer%s     ./run.sh --list   puis   ./run.sh\n\n' "$C_DIM" "$C_Z"
fi
[ $nb_fail -gt 0 ] && exit 1
exit 0
