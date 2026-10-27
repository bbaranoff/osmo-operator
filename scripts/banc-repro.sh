#!/bin/bash
# =============================================================================
#  banc-repro.sh — a reproducible experiment, from start to verdict
# =============================================================================
#  Intermittent call failures are diagnosed by replaying the same sequence
#  after each change and comparing comparable logs. This script freezes the
#  sequence: detached start, wait for camping, N identical calls, timestamped
#  collection, verdict per call.
#
#  It fixes nothing and guesses nothing. It produces a measurement.
#
#  Usage:
#     scripts/banc-repro.sh                      3 calls, with restart
#     scripts/banc-repro.sh --calls 5            5 calls
#     scripts/banc-repro.sh --no-restart         reuse the running stack
#     scripts/banc-repro.sh --dest 600           called number (default 600)
#
#  Output: a directory /root/repro-<timestamp>/ with all the logs of the run
#  and a resume.txt. Nothing is overwritten from one run to the next.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLS=3
DEST=600
RESTART=1
VTY=4247                 # MS#1; MS#2 is on 4248
CALL_S=20                # duration of one call
GAP_S=10                 # silence between two calls (the channel must be released)
BOOT_MAX=180             # maximum wait for camping

while [ $# -gt 0 ]; do
    case "$1" in
        --calls)      CALLS="${2:?}"; shift ;;
        --dest)       DEST="${2:?}"; shift ;;
        --vty)        VTY="${2:?}"; shift ;;
        --call-s)     CALL_S="${2:?}"; shift ;;
        --gap-s)      GAP_S="${2:?}"; shift ;;
        --no-restart) RESTART=0 ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/repro-$STAMP"
mkdir -p "$OUT"
LOGDIR=/run/user/0/osmo-nitb/logs

say() { printf '  %s\n' "$*"; }

# ── VTY: one command, one answer ────────────────────────────────────────────
# `enable` then the command. The daemon gets one second to answer: nc closes as
# soon as stdin ends, and without this pause the command is sent but the answer
# is never read.
vty() {
    { printf 'enable\n%s\n' "$1"; sleep 1; } | timeout 6 nc 127.0.0.1 "$VTY" 2>/dev/null
}

# ── 1. Start ────────────────────────────────────────────────────────────────
# CALYPSO_NO_ATTACH=1: run.sh does not attach to tmux at the end. Without it
# this script would stay blocked on an interactive session.
if [ "$RESTART" = 1 ]; then
    say "arret de la pile en cours"
    ( cd "$HERE" && CALYPSO_NO_ATTACH=1 ./start-native.sh --stop ) >"$OUT/stop.log" 2>&1
    sleep 3
    say "demarrage detache (CALYPSO_NO_ATTACH=1)"
    ( cd "$HERE" && CALYPSO_NO_ATTACH=1 setsid ./start-native.sh ) >"$OUT/start.log" 2>&1 &
else
    say "pile en cours reutilisee (--no-restart)"
fi

# ── 2. Wait for camping, do not assume it ───────────────────────────────────
# The VTY is polled rather than waiting a fixed delay: depending on the machine
# camping takes 40 s or 2 min, and a fixed sleep gives either waste or calls
# started before the mobile is ready — "failures" that measure nothing.
say "attente du camp (C3), maximum ${BOOT_MAX}s"
camp=0
for i in $(seq 1 "$BOOT_MAX"); do
    if vty "show ms" 2>/dev/null | grep -q "C3 camped normally"; then camp=1; break; fi
    sleep 1
done
if [ "$camp" != 1 ]; then
    say "PAS DE CAMP apres ${BOOT_MAX}s — on s'arrete, les appels ne mesureraient rien"
    vty "show ms" > "$OUT/show-ms-echec.txt" 2>&1
    cp "$LOGDIR"/*.log "$OUT/" 2>/dev/null
    exit 1
fi
say "campe apres ${i}s"

# Marker: everything that follows in pont.log belongs to the experiment.
PONT_DEBUT=$(wc -l < /dev/shm/pont.log 2>/dev/null || echo 0)

# ── 3. The calls ────────────────────────────────────────────────────────────
: > "$OUT/appels.txt"
for n in $(seq 1 "$CALLS"); do
    say "appel $n/$CALLS  -> $DEST"
    avant=$(wc -l < /dev/shm/pont.log 2>/dev/null || echo 0)
    vty "call 1 $DEST" > "$OUT/appel-$n-vty.txt" 2>&1
    sleep "$CALL_S"
    vty "call 1 hangup" >> "$OUT/appel-$n-vty.txt" 2>&1
    sleep 2

    # Verdict: in the slice of pont.log produced by this call, a
    # "DESARME (CHANNEL RELEASE" marks a TCH that lived; a "SANS ASSIGNMENT
    # COMPLETE" marks a mobile that did not switch. Cumulative counters are not
    # used, they would mix in the previous calls.
    tranche=$(tail -n +$((avant + 1)) /dev/shm/pont.log 2>/dev/null)
    if printf '%s' "$tranche" | grep -q "SANS ASSIGNMENT COMPLETE"; then
        verdict=ECHEC
    elif printf '%s' "$tranche" | grep -q "DESARME (CHANNEL RELEASE"; then
        verdict=OK
    else
        verdict=INDETERMINE
    fi
    printf 'appel %d : %s\n' "$n" "$verdict" | tee -a "$OUT/appels.txt"
    printf '%s' "$tranche" > "$OUT/appel-$n-pont.log"
    sleep "$GAP_S"
done

# ── 4. Collection ───────────────────────────────────────────────────────────
say "collecte des journaux"
cp /dev/shm/pont.log            "$OUT/pont.log"            2>/dev/null
tail -n +$((PONT_DEBUT + 1)) /dev/shm/pont.log > "$OUT/pont-experience.log" 2>/dev/null
cp "$LOGDIR"/qemu.log           "$OUT/qemu.log"            2>/dev/null
cp "$LOGDIR"/qemu-tete.log      "$OUT/qemu-tete.log"       2>/dev/null
cp "$LOGDIR"/mobile.log         "$OUT/mobile.log"          2>/dev/null
journalctl -u osmo-bsc --since "-30min" --no-pager > "$OUT/osmo-bsc.log" 2>/dev/null
journalctl -u osmo-msc --since "-30min" --no-pager > "$OUT/osmo-msc.log" 2>/dev/null
for f in calypso_dcch_cfg calypso_kc_l1 calypso_tch_cfg; do
    [ -e "/dev/shm/$f" ] && od -A d -t x1 "/dev/shm/$f" > "$OUT/$f.hex" 2>/dev/null
done

# ── 5. Summary ──────────────────────────────────────────────────────────────
# The pont.py counters (STATS, DETAIL blocs) are real cumulative counts. The
# shunt ones are rate-limited SHUNT_LOG lines (e.g. `if (++n <= 3 || n % 2000 == 0)`):
# counting them would give a number that measures nothing. Only what is
# reliable goes here, and it is said.
{
    echo "=== experience $STAMP : $CALLS appels vers $DEST ==="
    cat "$OUT/appels.txt"
    echo
    echo "--- canaux dedies appris par le shunt (compteur reel, non limite) ---"
    grep -ac "DCCH #" "$OUT/qemu.log" 2>/dev/null
    grep -ah "DCCH #" "$OUT/qemu.log" 2>/dev/null | tail -5
    echo
    echo "--- pont : compteurs cumulatifs (FIABLES) ---"
    grep -a "STATS" "$OUT/pont.log" 2>/dev/null | tail -1
    grep -a "DETAIL blocs" "$OUT/pont.log" 2>/dev/null | tail -1
    grep -a "SOUS-VOIE ACTIVE" "$OUT/pont.log" 2>/dev/null | tail -1
    echo
    echo "--- reseau : echecs d'assignation ---"
    grep -ac "Assignment failed" "$OUT/osmo-bsc.log" 2>/dev/null
    echo
    echo "--- mobile : SAPI invalides ---"
    grep -ac "unsupported SAPI" "$OUT/mobile.log" 2>/dev/null
    echo
    echo "ATTENTION : les SHUNT_LOG du shunt sont limites en debit."
    echo "Ne pas utiliser 'grep -c' sur eux comme un compteur."
} > "$OUT/resume.txt" 2>&1

cat "$OUT/resume.txt"
say "tout est dans $OUT"
