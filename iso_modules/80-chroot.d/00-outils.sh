# iso_modules/80-chroot.d/00-outils.sh - helpers for the other fragments:
# components (iso_modules/components.conf) and their status.
# Run INSIDE the chroot by iso_modules/80-chroot.sh, sourced FIRST.
#
#   composant <nom> <commande...>
#       Runs the command in THIS shell (its variables and its cd stay), its
#       output shown and kept. Writes one line to the status file: component,
#       class, ok/echec, duration, last output line. Failure of a CRITIQUE
#       component: stop (exit 1). Failure of an OPTIONNEL one: WARN, go on.
#       COMPOSANT_RC holds the command status either way.
#   run_optional <nom> <commande...>     same as composant (class from the
#       table, OPTIONNEL when the component is not listed).
#   composant_absent <nom> <raison>      the component could not even start
#       (script missing): recorded as « absent », same rule by class.
#   osmo_statut <nom> <classe> <statut> <duree> <erreur>   raw status line.
# Fin de fragment : `true`.

mkdir -p /var/log/osmo-build
OSMO_BUILD_STATUS=/var/log/osmo-build/status.jsonl
OSMO_COMPONENTS=/var/lib/osmo-build/components.conf

_osmo_json() {   # string -> JSON-escaped, control characters dropped
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    printf '%s' "$s" | tr -d '\000-\037'
}
# Wait for a tee whose input was just closed. A daemon started in the
# background by the command may still hold the pipe: after 30 s the tee is
# ended rather than waited for ever.
osmo_attendre_tee() {
    local _
    for _ in $(seq 300); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
    return 0
}
_osmo_classe() {
    local c=""
    [ -r "$OSMO_COMPONENTS" ] && c="$(awk -F'|' -v n="$1" '$1 == n { print $2; exit }' "$OSMO_COMPONENTS")"
    echo "${c:-OPTIONNEL}"
}
osmo_statut() {
    printf '{"composant":"%s","classe":"%s","statut":"%s","duree_s":%s,"erreur":"%s"}\n' \
        "$(_osmo_json "$1")" "$2" "$3" "${4:-0}" "$(_osmo_json "${5:-}")" >> "$OSMO_BUILD_STATUS"
}
_osmo_echec() {   # nom classe statut erreur
    if [ "$2" = CRITIQUE ]; then
        echo "ERREUR: composant CRITIQUE $1 : $3 - $4" >&2
        exit 1
    fi
    echo "  WARN: composant optionnel $1 : $3 - ${4:-sans message} (build continue, voir status.json)"
    return 0
}
composant() {
    local nom="$1" classe t0 tmp derniere errexit=0; shift
    classe="$(_osmo_classe "$nom")"; t0=$SECONDS; tmp="$(mktemp)"
    case "$-" in *e*) errexit=1 ;; esac
    set +e
    # The output goes through a tee opened on its own descriptor: its PID is
    # known for sure, and closing the descriptor ends it (then wait for it, so
    # the kept output is complete before its last line is read).
    local fd tee_pid
    exec {fd}> >(tee "$tmp"); tee_pid=$!
    "$@" >&"$fd" 2>&1
    COMPOSANT_RC=$?
    exec {fd}>&-
    osmo_attendre_tee "$tee_pid"
    [ "$errexit" = 1 ] && set -e
    derniere="$(grep -v '^[[:space:]]*$' "$tmp" | tail -1)"; rm -f "$tmp"
    if [ "$COMPOSANT_RC" -eq 0 ]; then
        osmo_statut "$nom" "$classe" ok $((SECONDS - t0)) ""
        return 0
    fi
    osmo_statut "$nom" "$classe" echec $((SECONDS - t0)) "code $COMPOSANT_RC : $derniere"
    _osmo_echec "$nom" "$classe" "echec (code $COMPOSANT_RC)" "$derniere"
}
run_optional() { composant "$@"; }
composant_absent() {
    local classe; classe="$(_osmo_classe "$1")"; COMPOSANT_RC=127
    osmo_statut "$1" "$classe" absent 0 "$2"
    _osmo_echec "$1" "$classe" absent "$2"
}

true
