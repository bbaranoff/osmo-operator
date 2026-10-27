#!/bin/bash
# operator_summary.sh - Summary of each operator's main characteristics
#
# Parses the dump produced by checks/vty-debug-dump.sh and extracts, operator
# by operator, the few figures that tell whether the network is alive: active
# ASPs, SS7 routes, HLR/VLR subscribers, BTS state, PDP contexts, ongoing calls.
#
# DUAL MODE (docker / native)
# This script talks to NO daemon: it reads a file. The mode only changes:
#   1. dump GENERATION (--live): the generator must look at the SAME world,
#      so the mode is passed to it through OSMO_MODE, even when forced here.
#   2. the INTER-STP: in docker it is the osmo-inter-stp container; in native
#      mode it is either this machine (role interstp) or ANOTHER machine whose
#      VTY is not reachable from here, so the dump contains nothing about it.
#      The section is then explicitly SKIPPED: a fabricated "0 active AS"
#      would read as an SS7 core outage.
#   3. the "container=osmo-operator-N" label of the dump: identical in native
#      mode (checks/_mode.sh, osmo_node). It is a CORRELATION KEY between the
#      dump blocks, not a queryable docker object: every extraction below
#      depends on it.
# The selected mode is printed in the header.
#
# Usage:
#   sudo ./checks/operator_summary.sh [--dump=/path/dump.txt] [--live]
#                                     [--docker|--native]
# Environment: OSMO_MODE=docker|native forces the mode.

set -euo pipefail

# ── Common docker/native detection library ───────────────────────────────────
# Looked up relative to THIS file (never absolute): the repo lives at
# different roots in development and on the ISO.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo-operator/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ────────────────────────────────────────────────────────────
DUMP_FILE=""
LIVE_MODE=0
TEMP_DUMP=""

# OSMO_MODE inherited from the environment is an explicit choice, like
# --docker/--native: reported as "force" in the header.
MODE_FORCED=0
[ -n "${OSMO_MODE:-}" ] && MODE_FORCED=1

for arg in "$@"; do
    case "$arg" in
        --dump=*) DUMP_FILE="${arg#*=}" ;;
        --live)   LIVE_MODE=1 ;;
        --docker|--native|--mode=*)
            # osmo_mode_force returns 2 when the argument is not a mode: only
            # "--mode=<anything>" can still fail here.
            if osmo_mode_force "$arg"; then
                MODE_FORCED=1
            else
                echo "Mode inconnu : ${arg} (attendu : --docker, --native)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [--dump=/chemin/dump.txt] [--live] [--docker|--native]"
            echo "  --dump   : Utilise un fichier de dump existant"
            echo "  --live   : Genere un dump live avant l'analyse"
            echo "  --docker : Force le mode conteneurs (osmo-operator-N)"
            echo "  --native : Force le mode natif (ISO, VM, machine nue)"
            echo "             sans option, le mode est detecte automatiquement"
            exit 0
            ;;
    esac
done

MODE="$(osmo_mode)"
if [ "$MODE_FORCED" -eq 1 ]; then MODE_SRC="force"; else MODE_SRC="detecte"; fi

# ── Display helpers ──────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo -e "$(printf '─%.0s' {1..70})"
}

print_row() {
    printf "  %-20s : %s\n" "$1" "$2"
}

print_section() {
    echo -e "\n  ${CYAN}${BOLD}$1${NC}"
}

# One line of the header box, aligned on the 58 columns of the ╔══╗ frame.
box_line() {
    local txt="$1" pad
    pad=$(( 58 - 5 - ${#txt} ))
    [ "$pad" -ge 0 ] || pad=0
    echo -e "${CYAN}║     ${txt}$(printf '%*s' "$pad" '')║${NC}"
}

# ── Data extraction from the dump ────────────────────────────────────────────
#
# PIPEFAIL, for EVERY extraction in this file: under "set -o pipefail" a grep
# that finds nothing (rc 1) or a "head -1" that exits early (producer killed
# by SIGPIPE, rc 141) fails the whole pipeline, hence the assignment and,
# under "set -e", the script itself (empty or partial dump). The "|| true"
# hide no error: they mean "nothing found = zero", which wc and grep -c
# already printed.

extract_value() {
    local container="$1"
    local pattern="$2"
    local default="${3:-?}"

    grep -A20 "\[.*\] port=.* container=${container}" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | head -1 \
        | sed -E 's/^[[:space:]]+//' \
        || echo "$default"
}

extract_count() {
    local container="$1"
    local section="$2"
    local pattern="$3"

    grep -A50 "\[.*\] port=.* container=${container}.*$section" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | wc -l \
        | tr -d ' ' \
        || true
}

extract_subscriber_count() {
    local container="$1"
    local count

    count=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1 || true)

    echo "${count:-0}"
}

# Sets BTS_STATE, OML_OK and RSL_OK as GLOBAL variables, on purpose: it must
# be called without command substitution, otherwise the assignments would die
# with the $( ) sub-shell and OML/RSL would always show as disconnected.
extract_bts_info() {
    local container="$1"
    local bts_id="$2"
    local bts_block oper avail oml rsl

    bts_block=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -A20 "bts ${bts_id}" \
        | sed -n '/bts [0-9]/,/^$/p' || true)

    oper=$(echo "$bts_block" | grep -c "Oper 'Enabled'" || true)
    avail=$(echo "$bts_block" | grep -c "Avail 'OK'" || true)
    oml=$(echo "$bts_block" | grep -c "OML Link state: connected" || true)
    rsl=$(echo "$bts_block" | grep -c "RSL State: connected" || true)

    if [ "$oper" -gt 0 ] && [ "$avail" -gt 0 ]; then
        BTS_STATE="OK"
    elif [ "$oper" -gt 0 ]; then
        BTS_STATE="Enabled"
    else
        BTS_STATE="Down"
    fi

    # Also set OML/RSL for information
    [ "$oml" -gt 0 ] && OML_OK=1 || OML_OK=0
    [ "$rsl" -gt 0 ] && RSL_OK=1 || RSL_OK=0
}

extract_asp_state() {
    local container="$1"
    local component="$2"  # STP, MSC, BSC

    local asp_block=""
    if [ "$component" = "STP" ]; then
        asp_block=$(grep -A30 "\[OsmoSTP\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "MSC" ]; then
        asp_block=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "BSC" ]; then
        asp_block=$(grep -A30 "\[OsmoBSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    fi

    echo "$asp_block" | grep -c "ASP_ACTIVE" || true
}

# ── Live dump generation on request ──────────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ]; then
    echo -e "${CYAN}Generation d'un dump live (mode ${MODE})...${NC}"
    TEMP_DUMP="/tmp/vty-live-$$.txt"

    # The generator is looked up NEXT TO THIS FILE (BASH_SOURCE), not in the
    # current directory.
    DUMPER="$_here/vty-debug-dump.sh"
    [ -x "$DUMPER" ] || DUMPER="./vty-debug-dump.sh"

    # OSMO_MODE is passed explicitly: the generator must query the same world
    # as the one analysed here, even when --native/--docker forced a mode it
    # would not have detected by itself.
    if ! OSMO_MODE="$MODE" "$DUMPER" --out "$TEMP_DUMP" > /dev/null; then
        echo -e "${RED}Echec de la generation du dump (${DUMPER}, mode ${MODE}).${NC}" >&2
        if [ "$MODE" = native ]; then
            echo "  Mode natif : verifiez que les demons tournent (VTY 4239/4254/4242/4258...)." >&2
        else
            echo "  Mode docker : verifiez que les conteneurs osmo-operator-N sont en cours." >&2
        fi
        rm -f "$TEMP_DUMP"
        exit 1
    fi
    DUMP_FILE="$TEMP_DUMP"
    echo -e "${GREEN}✓ Dump genere : $DUMP_FILE${NC}"
fi

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo -e "${RED}Erreur : fichier de dump non specifie ou introuvable${NC}"
    echo "Utilisez --dump=/chemin/vers/dump.txt ou --live pour generer un dump"
    exit 1
fi

# ── Nodes present IN THE DUMP ────────────────────────────────────────────────
# "container=osmo-operator-N" is written by vty-debug-dump.sh in both modes:
# the container name in docker, the label returned by osmo_node() in native.
# The dump is therefore read the same way on both sides.
mapfile -t CONTAINERS < <(
    grep -E "container=osmo-operator-[0-9]+" "$DUMP_FILE" \
        | sed -E 's/.*container=([^ ]+).*/\1/' \
        | sort -u
)

INTER_STP=$(grep -E "container=osmo-inter-stp" "$DUMP_FILE" \
    | sed -E 's/.*container=([^ ]+).*/\1/' \
    | head -1 || true)

N_OPS=${#CONTAINERS[@]}

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Resume Operateurs - $(date '+%Y-%m-%d %H:%M')              ║${NC}"
echo -e "${CYAN}║     ${N_OPS} operateur(s) trouve(s)                             ║${NC}"
box_line "Mode : ${MODE} (${MODE_SRC})"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

# Silent dump: say so. Comparing it with the live inventory tells "nothing is
# running" from "the dump comes from elsewhere / is partial" - two very
# different failures, especially in native mode where no "docker ps" can
# decide.
if [ "$N_OPS" -eq 0 ]; then
    live_ops="$(osmo_ops 2>/dev/null | tr '\n' ' ' || true)"
    live_ops="${live_ops% }"
    echo ""
    echo -e "  ${YELLOW}Aucun bloc "container=osmo-operator-N" dans ce dump.${NC}"
    print_row "Operateurs vus ici" "${live_ops:-aucun} (mode ${MODE})"
    print_row "Dump" "vide, partiel, ou produit sur un autre noeud"
fi

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ -n "$INTER_STP" ]; then
    print_header "INTER-STP HUB (${INTER_STP})"

    asp_count=$(extract_asp_state "$INTER_STP" "STP")
    print_row "ASP actifs" "$asp_count"

    # Routes
    routes=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l || true)
    print_row "Routes configurees" "$routes"

    # AS
    as_count=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -c "AS_ACTIVE" || true)
    print_row "AS actifs" "$as_count"

elif osmo_is_native; then
    # Nothing about the hub in the dump, and we are native: either this
    # machine IS the hub and the dump predates it, or the hub is ANOTHER
    # machine whose VTY 4239 listens only on its own 127.0.0.1 and is NOT
    # observable from here. Skipped visibly rather than showing zero counters
    # that would read as a dead SS7 core.
    print_header "INTER-STP HUB - ignore (natif)"
    if hub_here="$(osmo_hub)"; then
        print_row "Hub local" "${hub_here} present ici, mais absent du dump"
        print_row "Pour l'inclure" "relancez avec --live"
    else
        print_row "Hub" "$(osmo_hub_hint)"
    fi

elif hub_remote="$(osmo_hub_is_remote 2>/dev/null)"; then
    # WAN: the hub lives on ANOTHER machine (--hub-ip / OSMO_HUB_IP), so it
    # cannot appear in a dump taken here, and its VTY 4239 listens only on its
    # own loopback. What is observable from here is the LINK to it: the SCTP
    # association each node keeps open.
    print_header "INTER-STP HUB - distant (${hub_remote})"
    hub_assoc="$(osmo_hub_assoc "$hub_remote" 2>/dev/null)" && hub_rc=0 || hub_rc=$?
    case "$hub_rc" in
        0) print_row "Lien M3UA/SCTP" "${hub_assoc} noeud(s) associe(s) a ${hub_remote}:${OSMO_HUB_M3UA_PORT}" ;;
        1) print_row "Lien M3UA/SCTP" "aucune association vers ${hub_remote}:${OSMO_HUB_M3UA_PORT}" ;;
        *) print_row "Lien M3UA/SCTP" "non sondable ici (ss --sctp absent des noeuds)" ;;
    esac
    print_row "Etat interne" "$(osmo_hub_hint)"

elif hub_here="$(osmo_hub)"; then
    # Docker mode: the container runs but is not in the dump, so the dump
    # predates the hub. Without a hub container nothing is printed: there is
    # simply no inter-STP in this lab.
    print_header "INTER-STP HUB (${hub_here})"
    print_row "Etat" "conteneur en cours, mais absent du dump"
    print_row "Pour l'inclure" "relancez avec --live"
fi

# ── Loop over operators ──────────────────────────────────────────────────────
# "${CONTAINERS[@]+...}": on a silent dump the array is empty, and under
# "set -u" a bare "${CONTAINERS[@]}" would abort instead of doing nothing.
for container in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
    # The number is the label suffix; mapfile only let "osmo-operator-<digits>"
    # through, so no sub-shell or grep is needed here.
    op_id="${container##*-}"

    print_header "OPERATEUR ${op_id} (${container})"

    # ── Local STP ────────────────────────────────────────────────────────────
    print_section "SS7"

    # Active ASPs in STP
    stp_asp=$(extract_asp_state "$container" "STP")
    print_row "ASP actifs (STP)" "$stp_asp"

    # Routes
    routes=$(grep -A50 "\[OsmoSTP\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l || true)
    print_row "Routes configurees" "$routes"

    # ── MSC ───────────────────────────────────────────────────────────────
    print_section "MSC"

    msc_asp=$(extract_asp_state "$container" "MSC")
    print_row "ASP actif" "$([ "$msc_asp" -gt 0 ] && echo "✓" || echo "✗")"

    # VLR subscribers
    vlr_count=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A20 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1 || true)
    print_row "Subscribers VLR" "${vlr_count:-0}"

    # Transactions
    trans=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "transaction" || true)
    print_row "Transactions" "$trans"

    # ── BSC ───────────────────────────────────────────────────────────────
    print_section "BSC"

    bsc_asp=$(extract_asp_state "$container" "BSC")
    print_row "ASP actif" "$([ "$bsc_asp" -gt 0 ] && echo "✓" || echo "✗")"

    # BTS 0 state
    OML_OK=0
    RSL_OK=0
    BTS_STATE="Down"
    extract_bts_info "$container" 0
    print_row "BTS 0 etat" "$BTS_STATE"
    print_row "  ├─ OML" "$([ "$OML_OK" -eq 1 ] && echo "✓ connecte" || echo "✗ deconnecte")"
    print_row "  └─ RSL" "$([ "$RSL_OK" -eq 1 ] && echo "✓ connecte" || echo "✗ deconnecte")"

    # Total number of BTS
    n_bts=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -c "^ bts [0-9]" || true)
    print_row "BTS totales" "$n_bts"

    # ── HLR ───────────────────────────────────────────────────────────────
    print_section "HLR"

    subs_count=$(extract_subscriber_count "$container")
    print_row "Abonnes" "$subs_count"

    # GSUP connections
    gsup=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "GSUP" || true)
    print_row "Connexions GSUP" "$gsup"

    # ── BTS (if available) ───────────────────────────────────────────────────
    print_section "BTS (phy)"

    # Active LCHANs
    lchan=$(grep -A30 "\[OsmoBTS\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "lchan" || true)
    print_row "LCHAN" "$lchan"

    # ── SGSN/GGSN (if GPRS is enabled) ───────────────────────────────────────
    print_section "GPRS"

    # NS entities
    ns=$(grep -A30 "\[OsmoSGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "NS entity" || true)
    print_row "NS entities" "$ns"

    # PDP contexts
    pdp=$(grep -A30 "\[OsmoGGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "PDP context" || true)
    print_row "PDP contexts" "$pdp"

    # ── Auxiliary services ───────────────────────────────────────────────────
    print_section "Services"

    # SIP connector
    sip_logs=$(grep -A10 "\[OsmoSIPconn\]" "$DUMP_FILE" \
        | grep -c "container=${container}" || true)
    print_row "SIP connector" "$([ "$sip_logs" -gt 0 ] && echo "✓ actif" || echo "?")"

    # SMS relay port
    sms=$(grep -A10 "\[.*\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -c "port 7890" || true)
    print_row "SMS relay" "$([ "$sms" -gt 0 ] && echo "✓ actif" || echo "?")"

    # ── Quick statistics ─────────────────────────────────────────────────────
    print_section "Statistiques"

    # Active calls
    calls=$(grep -A20 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "call-leg" || true)
    print_row "Appels actifs" "$calls"

    # Paging
    paging=$(grep -A20 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "paging" || true)
    print_row "Paging actifs" "$paging"

done

# ── Cleanup ──────────────────────────────────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ] && [ -n "$TEMP_DUMP" ]; then
    rm -f "$TEMP_DUMP"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Analyse terminee - Dump utilise : ${DUMP_FILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
