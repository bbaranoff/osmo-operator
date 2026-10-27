#!/bin/bash
# =============================================================================
# checks/check_all.sh -- run ALL bench checks in the right order and return
#                        ONE verdict.
#
# checks/ holds scripts that do not overlap: global_check sees the daemons,
# ss7_check the signalling, diag-* the interconnect from either side,
# wan_ss7_check the traffic between machines, annuaire the subscribers.
# This script selects WHAT MAKES SENSE HERE (mode and role decide), runs them
# from the most general to the most specific, logs everything, and ends with
# a table: one row per check, one verdict, one exit code.
#
# WHAT IT DOES NOT DO
#   - it modifies nothing and restarts nothing: all called checks are
#     read-only (only --dump changes daemon log levels, so it is optional and
#     never enabled by default);
#   - it reimplements no test: each verdict comes from the original script,
#     never from a second VTY read done here.
#
# CHECK SELECTION - WHAT RUNS, AND WHEN
#   mode           all checks honour --docker/--native; the option is passed
#                  through unchanged, so a single world is inspected.
#   diag-interstp  only if an inter-STP is QUERYABLE HERE (osmo-inter-stp
#                  container, or OSMO_ROLE=interstp): on an operator node the
#                  hub is another machine whose VTY listens on its loopback
#                  only, so running it would report a false "hub silent".
#   diag-stp-oper. the exact opposite: only when this node is NOT the hub and
#                  has an /etc/osmo-role (i.e. a WAN setup).
#   wan_ss7_check  only if /etc/osmo-wan.conf exists: without a WAN plan there
#                  is nothing "between nodes" to verify.
#   annuaire       only if the directory files exist (/var/tmp or /etc/osmocom).
#   dump + resume  never by default: vty-debug-dump.sh switches the daemons to
#                  DEBUG and writes several MB. --dump enables both, the
#                  summary rereading the dump just written.
#
# HOW A CHECK VERDICT IS DERIVED
# The checks/ scripts do not share one convention:
#   rc    global_check.sh / ss7_check.sh return the NUMBER of failures;
#   rcb   wan_ss7_check.sh returns 0 or 1;
#   motif diag-*.sh and annuaire.sh always return 0 - their verdict is in
#         their last section ("INTERCO SS7 : DOWN"), read from the output
#         with colors stripped.
#
# Usage:
#   sudo ./checks/check_all.sh [options]
#     --quick|-q        passed to global_check / ss7_check (quick pass)
#     --verbose|-v      passed to the checks that support it
#     --op=N            limit to one operator (global_check, annuaire)
#     --docker|--native force the world; without it, auto-detection
#     --mode=X          same as --docker / --native
#     --dump            add vty-debug-dump.sh then operator_summary.sh
#     --only=a,b        run only these checks (see --list)
#     --skip=a,b        run all checks except these
#     --list            show the checks, their key and applicability
#     --out FILE        full log (default /tmp/osmo-check-all-<date>.txt)
#     --no-log          write nothing to disk
#     --timeout N       maximum time per check, in seconds (default 300)
#     --no-color        plain output
#
# Env: OSMO_MODE=docker|native forces the world like --docker/--native.
#
# Exit code: number of failed checks (0 = all good), at most 125.
#
# Check keys: global ss7 interstp operator wan annuaire dump resume.
# Examples:
#   sudo ./checks/check_all.sh --quick
#   sudo ./checks/check_all.sh --only=global,ss7 --no-log
#   sudo ./checks/check_all.sh --native --dump
# =============================================================================

set -u

# ── Shared library (docker/native detection, inventory, VTY) ───────────────
# Path relative to THIS file: the repository lives in a home directory during
# development and in /opt/GSM/osmo-operator on the ISO.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo-operator/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Options ─────────────────────────────────────────────────────────────────
QUICK=0; VERBOSE=0; SPECIFIC_OP=""; WANT_DUMP=0
ONLY=""; SKIP_LIST=""; LIST_ONLY=0
LOGFILE=""; NO_LOG=0; TIMEOUT=300; USE_COLOR=1
MODE_FORCED=0; MODE_OPT=""

# OSMO_MODE in the environment counts as forcing ("OSMO_MODE=native
# ./checks/check_all.sh"); it is passed to the children as an option.
case "${OSMO_MODE:-}" in docker|native) MODE_FORCED=1 ;; esac

while [ $# -gt 0 ]; do
    case "$1" in
        --quick|-q)   QUICK=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --op)         SPECIFIC_OP="${2:-}"; shift ;;
        --op=*)       SPECIFIC_OP="${1#*=}" ;;
        --dump)       WANT_DUMP=1 ;;
        --only)       ONLY="${2:-}"; shift ;;
        --only=*)     ONLY="${1#*=}" ;;
        --skip)       SKIP_LIST="${2:-}"; shift ;;
        --skip=*)     SKIP_LIST="${1#*=}" ;;
        --list)       LIST_ONLY=1 ;;
        --out)        LOGFILE="${2:-}"; shift ;;
        --out=*)      LOGFILE="${1#*=}" ;;
        --no-log)     NO_LOG=1 ;;
        --timeout)    TIMEOUT="${2:-}"; shift ;;
        --timeout=*)  TIMEOUT="${1#*=}" ;;
        --no-color)   USE_COLOR=0 ;;
        --docker|--native|--mode=*)
            osmo_mode_force "$1" || { echo "mode inconnu : $1" >&2; exit 1; }
            MODE_FORCED=1 ;;
        -h|--help)    sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "option inconnue : $1 (voir --help)" >&2; exit 1 ;;
    esac
    shift
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout attend un entier" >&2; exit 1 ;; esac

# ── Colors ──────────────────────────────────────────────────────────────────
if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
    GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m';   BOLD=$'\033[1m';    DIM=$'\033[2m'; NC=$'\033[0m'
else
    GREEN=; CYAN=; YELLOW=; RED=; BOLD=; DIM=; NC=
fi

banner() {
    echo ""
    echo "${BOLD}$*${NC}"
    printf '%s\n' "$(printf '─%.0s' $(seq 1 74))"
}

# ── Mode, role, inventory ───────────────────────────────────────────────────
MODE="$(osmo_mode)"
[ "$MODE_FORCED" -eq 1 ] && MODE_SRC="force" || MODE_SRC="detecte"

# Mode option passed to the children. ALWAYS passed, even when detected here:
# otherwise each child redetects, and on a host with docker installed but the
# lab running natively two detections may disagree.
MODE_OPT="--$MODE"

HUB_LOCAL=0; HUB_LABEL=""
if HUB_LABEL="$(osmo_hub 2>/dev/null)"; then HUB_LOCAL=1; else HUB_LABEL=""; fi

ROLE=""
[ -r /etc/osmo-role ] && \
    ROLE="$(awk -F= '/^OSMO_ROLE=/ { gsub(/[ \r\t]/, "", $2); print $2 }' /etc/osmo-role 2>/dev/null | tail -1)"

OPS="$(osmo_ops 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
N_OPS="$(printf '%s\n' "$OPS" | wc -w | tr -d ' ')"

# Subscriber directory files: start-docker.sh writes them on the HOST in
# /var/tmp and copies them into /etc/osmocom of each container. Same rule as
# checks/annuaire.sh.
ANNU_FOUND=0
for f in "${OSMO_ANNUAIRE:-}" /var/tmp/osmo-annuaire.csv /etc/osmocom/annuaire.csv; do
    [ -n "$f" ] && [ -r "$f" ] && { ANNU_FOUND=1; break; }
done

# ── Log ─────────────────────────────────────────────────────────────────────
# The log receives the output WITHOUT colors; the terminal keeps them.
STRIP_ANSI='s/\x1b\[[0-9;]*[a-zA-Z]//g'
if [ "$NO_LOG" -eq 0 ]; then
    [ -n "$LOGFILE" ] || LOGFILE="/tmp/osmo-check-all-$(date '+%Y%m%d-%H%M%S').txt"
    if : >"$LOGFILE" 2>/dev/null; then :; else
        echo "${YELLOW}journal impossible a ecrire (${LOGFILE}) - on continue sans${NC}" >&2
        NO_LOG=1; LOGFILE=""
    fi
else
    LOGFILE=""
fi
journal() { [ -n "$LOGFILE" ] && printf '%s\n' "$*" | sed "$STRIP_ANSI" >>"$LOGFILE"; return 0; }

# ── Catalogue ───────────────────────────────────────────────────────────────
# One record per check:  key | script | verdict | description
#   verdict = rc     the script returns the NUMBER of failures (global_check, ss7_check)
#             rcb    the script returns 0 or non-0 (wan_ss7_check)
#             motif  the script always returns 0: the verdict is read from its
#                    output, pattern given after ':' (diag-*, annuaire)
#             info   informational output, never failing (dump, resume)
# Order follows the diagnosis: running daemons, local signalling,
# interconnect, WAN, then subscribers.
CATALOGUE=(
  "global|global_check.sh|rc|etat de tous les demons (STP, HLR, MSC, BSC, BTS, PCU, SGSN, GGSN, MGW)"
  "ss7|ss7_check.sh|rc|signalisation SS7 : AS, ASP, routes, catch-all vers l inter-STP"
  "interstp|diag-interstp.sh|motif:INTERCO SS7 : (DOWN|PARTIELLE)|indeterminable|interco vue du HUB : qui est attache, qui manque"
  "operator|diag-stp-operator.sh|motif:INTERCO SS7 : DOWN|interco vue du NOEUD : conf disque vs demon, SCTP vers le hub"
  "wan|wan_ss7_check.sh|rcb|entre noeuds : SIP/RTP, relais SMS, point codes, iptables"
  "annuaire|annuaire.sh|motif:\\[FAIL\\]|abonnes : IMSI, MSISDN, cles Ki, attachement, annuaire SS7"
  "dump|vty-debug-dump.sh|info|dump DEBUG de tous les VTY (--dump seulement)"
  "resume|operator_summary.sh|info|resume par operateur, lu sur le dump (--dump seulement)"
)

champ() { printf '%s' "$1" | cut -d'|' -f"$2"; }
# The pattern may contain '|' (regex alternation): it spans everything
# between the 3rd field and the LAST one, the description being the last.
verdict_de()     { printf '%s' "${1#*|*|}" | sed 's/|[^|]*$//'; }
description_de() { printf '%s' "$1" | awk -F'|' '{print $NF}'; }

# applicable <key> - does this check make sense here? Prints the reason if not.
applicable() {
    case "$1" in
        global|ss7) return 0 ;;
        interstp)
            [ "$HUB_LOCAL" -eq 1 ] && return 0
            printf 'aucun inter-STP interrogeable ici (%s)' "$(osmo_hub_hint 2>/dev/null || echo 'hub distant ou absent')"
            return 1 ;;
        operator)
            [ "$HUB_LOCAL" -eq 1 ] && { printf 'ce noeud EST le hub - voir le check interstp'; return 1; }
            [ -r /etc/osmo-role ] && return 0
            printf '/etc/osmo-role absent : pas de montage WAN sur ce noeud'
            return 1 ;;
        wan)
            [ -r /etc/osmo-wan.conf ] && return 0
            printf '/etc/osmo-wan.conf absent : aucun plan WAN a verifier'
            return 1 ;;
        annuaire)
            [ "$ANNU_FOUND" -eq 1 ] && return 0
            printf 'aucune fiche (osmo-annuaire.csv) : banc lance sans annuaire'
            return 1 ;;
        dump|resume)
            [ "$WANT_DUMP" -eq 1 ] && return 0
            printf 'non demande (--dump)'
            return 1 ;;
    esac
    return 0
}

# args_de <key> - options to pass; each script takes different ones.
args_de() {
    local a=("$MODE_OPT")
    case "$1" in
        global)
            [ "$QUICK" -eq 1 ]        && a+=(--quick)
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose)
            [ -n "$SPECIFIC_OP" ]     && a+=("--op=$SPECIFIC_OP") ;;
        ss7)
            [ "$QUICK" -eq 1 ]        && a+=(--quick)
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose) ;;
        interstp)
            # diag-interstp.sh and diag-stp-operator.sh do not use _mode.sh: they read
            # /etc/osmo-role and the local VTYs and reject --docker/--native as an
            # unknown option, so MODE_OPT is not passed.
            a=()
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        operator)
            a=()
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        wan)
            a=()
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose) ;;
        annuaire)
            a=()
            [ -n "$SPECIFIC_OP" ]     && a+=(--op "$SPECIFIC_OP")
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        dump)
            a+=(--out "$DUMP_OUT") ;;
        resume)
            a+=("--dump=$DUMP_OUT") ;;
    esac
    printf '%s\n' "${a[@]:-}"
}

# ── --list: show what would be done, without doing it ───────────────────────
if [ "$LIST_ONLY" -eq 1 ]; then
    echo "${BOLD}checks disponibles${NC}   (mode ${MODE}, ${MODE_SRC})"
    echo ""
    printf '  %-10s %-24s %s\n' CLE SCRIPT ETAT
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    for e in "${CATALOGUE[@]}"; do
        k="$(champ "$e" 1)"; s="$(champ "$e" 2)"
        if raison="$(applicable "$k")"; then
            printf '  %-10s %-24s %slance%s\n' "$k" "$s" "$GREEN" "$NC"
        else
            printf '  %-10s %-24s %signore%s - %s\n' "$k" "$s" "$DIM" "$NC" "$raison"
        fi
        printf '  %-10s %-24s %s%s%s\n' "" "" "$DIM" "$(description_de "$e")" "$NC"
    done
    echo ""
    exit 0
fi

# ── Header ──────────────────────────────────────────────────────────────────
DUMP_OUT="/tmp/osmo-check-all-dump-$(date '+%Y%m%d-%H%M%S').txt"
DATE_DEB="$(date '+%Y-%m-%d %H:%M:%S')"

en_tete() {
    echo "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║   osmo-operator - CHECK COMPLET du banc                                     ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo "${NC}"
    printf '  date       : %s\n' "$DATE_DEB"
    printf '  machine    : %s\n' "$(hostname 2>/dev/null || echo '?')"
    printf '  mode       : %s%s%s (%s)\n' "$CYAN" "$MODE" "$NC" "$MODE_SRC"
    printf '  operateurs : %s   (%s)\n' "${N_OPS:-0}" "${OPS:-aucun}"
    if [ "$HUB_LOCAL" -eq 1 ]; then
        printf '  inter-STP  : %s%s%s (interrogeable ici)\n' "$GREEN" "$HUB_LABEL" "$NC"
    else
        printf '  inter-STP  : %s\n' "$(osmo_hub_hint 2>/dev/null || echo 'non interrogeable ici')"
    fi
    [ -n "$ROLE" ] && printf '  role       : %s\n' "$ROLE"
    [ -n "$LOGFILE" ] && printf '  journal    : %s\n' "$LOGFILE"
    # Osmocom VTYs listen on loopback and docker needs the socket: without root,
    # half the checks would report "silent" for reasons unrelated to the network.
    # Warn up front.
    [ "$(id -u)" -ne 0 ] && printf '  %s! lance sans root : certains checks seront incomplets (sudo recommande)%s\n' "$YELLOW" "$NC"
}
en_tete
en_tete_txt="$(en_tete 2>&1)"
journal "$en_tete_txt"

# ── Execution ───────────────────────────────────────────────────────────────
NB_OK=0; NB_KO=0; NB_IGN=0
RES_CLE=(); RES_ETAT=(); RES_RC=(); RES_DUREE=(); RES_NOTE=()

dans_liste() {   # dans_liste <aiguille> <a,b,c>
    local x; local IFS=','
    for x in $2; do [ "$x" = "$1" ] && return 0; done
    return 1
}

enregistre() {   # enregistre <cle> <etat> <rc> <duree> <note>
    RES_CLE+=("$1"); RES_ETAT+=("$2"); RES_RC+=("$3"); RES_DUREE+=("$4"); RES_NOTE+=("${5:-}")
}

for entree in "${CATALOGUE[@]}"; do
    cle="$(champ "$entree" 1)"
    script="$(champ "$entree" 2)"
    verdict="$(verdict_de "$entree")"
    desc="$(description_de "$entree")"
    chemin="$_here/$script"

    # --only / --skip first: user-excluded checks are not evaluated and are not
    # reported as "not applicable" (a choice, not a finding).
    [ -n "$ONLY" ]      && { dans_liste "$cle" "$ONLY"      || continue; }
    [ -n "$SKIP_LIST" ] && { dans_liste "$cle" "$SKIP_LIST" && continue; }

    if ! raison="$(applicable "$cle")"; then
        banner "[$cle] $script"
        echo "  ${DIM}ignore${NC} - $raison"
        journal ""; journal "== [$cle] $script =="; journal "  ignore - $raison"
        NB_IGN=$((NB_IGN+1)); enregistre "$cle" IGNORE "-" "-" "$raison"
        continue
    fi

    if [ ! -x "$chemin" ]; then
        banner "[$cle] $script"
        echo "  ${RED}absent ou non executable${NC} : $chemin"
        journal ""; journal "== [$cle] $script =="; journal "  absent : $chemin"
        NB_KO=$((NB_KO+1)); enregistre "$cle" ABSENT "-" "-" "$chemin introuvable"
        continue
    fi

    mapfile -t opts < <(args_de "$cle")
    # args_de prints an empty line when there are no options; avoid passing an
    # empty argument, which some scripts reject.
    [ "${#opts[@]}" -eq 1 ] && [ -z "${opts[0]}" ] && opts=()

    banner "[$cle] $script ${DIM}${opts[*]:-}${NC}"
    echo "  ${DIM}${desc}${NC}"
    echo ""
    journal ""
    journal "════════════════════════════════════════════════════════════════════════"
    journal "== [$cle] $script ${opts[*]:-}"
    journal "   $desc"
    journal "════════════════════════════════════════════════════════════════════════"

    tmp="$(mktemp "${TMPDIR:-/tmp}/osmo-check-$cle-XXXXXX")"
    debut=$SECONDS
    # timeout: a VTY that never answers (frozen daemon, hung docker exec) would
    # block the whole report; cut it, report it, continue.
    # PIPESTATUS rather than "set -o pipefail": under pipefail a trailing
    # "grep -q" in a child would return 141 (see checks/_mode.sh).
    timeout "$TIMEOUT" "$chemin" "${opts[@]}" 2>&1 | tee "$tmp"
    rc="${PIPESTATUS[0]}"
    duree=$((SECONDS - debut))

    [ -n "$LOGFILE" ] && sed "$STRIP_ANSI" "$tmp" >>"$LOGFILE"
    propre="$(sed "$STRIP_ANSI" "$tmp")"
    rm -f "$tmp"

    etat=OK; note=""
    if [ "$rc" -eq 124 ]; then
        etat=TIMEOUT; note="coupe apres ${TIMEOUT}s"
    else
        case "$verdict" in
            rc)
                # global_check.sh and ss7_check.sh return the number of failures.
                if [ "$rc" -ne 0 ]; then etat=ECHEC; note="$rc test(s) en echec"; fi ;;
            rcb)
                if [ "$rc" -ne 0 ]; then etat=ECHEC; note="code de retour $rc"; fi ;;
            motif:*)
                # The script always returns 0: its verdict is in its output. Keep the whole
                # LINE, not just the pattern, so the summary is self-explanatory.
                m="${verdict#motif:}"
                nb="$(printf '%s\n' "$propre" | grep -Ec -- "$m")"
                if [ "${nb:-0}" -gt 0 ]; then
                    etat=ECHEC
                    note="$(printf '%s\n' "$propre" | grep -Em1 -- "$m" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-60)"
                    [ "$nb" -gt 1 ] && note="$note (+$((nb-1)))"
                fi ;;
            info)
                etat=INFO ;;
        esac
    fi

    case "$etat" in
        OK)      NB_OK=$((NB_OK+1));  echo ""; echo "  ${GREEN}→ $cle : OK${NC} (${duree}s)" ;;
        INFO)    NB_OK=$((NB_OK+1));  echo ""; echo "  ${CYAN}→ $cle : termine${NC} (${duree}s)" ;;
        TIMEOUT) NB_KO=$((NB_KO+1));  echo ""; echo "  ${RED}→ $cle : TIMEOUT${NC} - $note" ;;
        *)       NB_KO=$((NB_KO+1));  echo ""; echo "  ${RED}→ $cle : PROBLEMES${NC} - $note (${duree}s)" ;;
    esac
    journal "  → $cle : $etat ${note} (${duree}s, rc=$rc)"

    enregistre "$cle" "$etat" "$rc" "${duree}s" "$note"
done

# ── Summary ─────────────────────────────────────────────────────────────────
bilan() {
    echo ""
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    echo "  ${BOLD}BILAN - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    printf '  %-10s %-9s %-6s %-7s %s\n' CHECK ETAT RC DUREE COMMENTAIRE
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    local i coul
    for i in "${!RES_CLE[@]}"; do
        case "${RES_ETAT[$i]}" in
            OK)                coul="$GREEN" ;;
            INFO)              coul="$CYAN" ;;
            IGNORE)            coul="$DIM" ;;
            ECHEC|TIMEOUT|ABSENT) coul="$RED" ;;
            *)                 coul="$YELLOW" ;;
        esac
        printf '  %-10s %s%-9s%s %-6s %-7s %s\n' \
            "${RES_CLE[$i]}" "$coul" "${RES_ETAT[$i]}" "$NC" \
            "${RES_RC[$i]}" "${RES_DUREE[$i]}" "${RES_NOTE[$i]}"
    done
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    printf '  %s%d ok%s   %s%d en echec%s   %s%d ignore%s   (mode %s)\n' \
        "$GREEN" "$NB_OK" "$NC" "$RED" "$NB_KO" "$NC" "$DIM" "$NB_IGN" "$NC" "$MODE"
    echo ""
    if [ "$NB_KO" -eq 0 ] && [ "$NB_OK" -eq 0 ]; then
        # Everything skipped or excluded: nothing was inspected, so do not report OK.
        echo "  ${YELLOW}${BOLD}AUCUN CHECK N A TOURNE${NC} - tout etait ignore ou exclu (--list pour savoir pourquoi)"
    elif [ "$NB_KO" -eq 0 ]; then
        echo "  ${GREEN}${BOLD}BANC OK${NC} - ${NB_OK} check(s) passes, aucun en echec"
    else
        echo "  ${RED}${BOLD}PROBLEMES DETECTES${NC} - ${NB_KO} check(s) en echec"
        echo ""
        echo "  ${DIM}rejouer un seul check en detail :${NC}"
        for i in "${!RES_CLE[@]}"; do
            case "${RES_ETAT[$i]}" in
                ECHEC|TIMEOUT) echo "    ./checks/check_all.sh --only=${RES_CLE[$i]} --verbose" ;;
            esac
        done
    fi
    [ -n "$LOGFILE" ] && { echo ""; echo "  ${CYAN}journal complet :${NC} $LOGFILE"; }
    [ "$WANT_DUMP" -eq 1 ] && [ -s "$DUMP_OUT" ] && echo "  ${CYAN}dump VTY        :${NC} $DUMP_OUT"
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    echo ""
}
bilan
journal "$(bilan)"

# Same convention as global_check.sh / ss7_check.sh: exit code = number of
# failures, capped at 125 (126, 127 and 128+n have special meanings).
[ "$NB_KO" -gt 125 ] && NB_KO=125
exit "$NB_KO"
