#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# verif.sh - automatic verdict for the operator in DSP mode:
#   1. uses the stack already running; otherwise (or with --restart) starts it with run-dsp.sh
#   2. waits for LOCATION UPDATING ACCEPT
#   3. N calls to 600 (Asterisk echo), for each one:
#        call       : Asterisk channel Up
#        DL voice   : Asterisk's announcement comes out of the ROM vocoder on gsm_audio
#        UL voice   : a 1 kHz tone injected into gsm_mic (the mobile's mic) comes back through the echo
#   4. summary; exit code 0 if everything is OK
#
#   ./verif.sh                     2 calls (starts the stack if it is not running)
#   ./verif.sh --appels 3          3 calls
#   ./verif.sh --restart           restarts the whole stack first (the current LU is lost)
#
# The recordings of each call stay in /tmp/verif/ (s16le 8 kHz mono).
# With the host PulseAudio, the announcement and the 1 kHz tone play on the speakers.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPELS=2 RESTART=auto
while [ $# -gt 0 ]; do
    case "$1" in
        --appels) APPELS="$2"; shift ;;
        --restart) RESTART=1 ;;
        --no-restart) RESTART=0 ;;
        -h|--help) sed -n '4,17p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
LOG_DIR="${LOG_DIR:-/run/osmo-minioperator/logs}"
MOBILE_LOG=/tmp/c54x-pont/mobile.log
LU_TIMEOUT="${LU_TIMEOUT:-300}"

say() { printf '\033[1m[verif]\033[0m %s\n' "$*"; }

# By default, do not break a running stack (and its LU): restart only if the
# mobile or the bridge is missing.
if [ "$RESTART" = auto ]; then
    if pgrep -x mobile >/dev/null && pgrep -f 'pont/pont_dsp[.]py' >/dev/null; then
        RESTART=0; say "stack already running: used as is (--restart to restart it)"
    else
        RESTART=1
    fi
fi
if [ "$RESTART" = 1 ]; then
    say "starting the stack (run-dsp.sh) ..."
    mkdir -p "$LOG_DIR"   # fresh container: run-dsp.sh has not created it yet
    "$HERE/run-dsp.sh" > "$LOG_DIR/../verif-run-dsp.log" 2>&1 || { say "run-dsp.sh FAILED (see $LOG_DIR/../verif-run-dsp.log)"; exit 1; }
fi
[ -r "$LOG_DIR/pulse_server" ] && export PULSE_SERVER="$(cat "$LOG_DIR/pulse_server")"
[ "${PULSE_SERVER:-}" = defaut ] && unset PULSE_SERVER

say "waiting for LOCATION UPDATING ACCEPT (max ${LU_TIMEOUT}s) ..."
t=0
until grep -aq 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null; do
    [ "$t" -ge "$LU_TIMEOUT" ] && { say "FAILED: no LU ACCEPT within ${LU_TIMEOUT}s"; exit 1; }
    sleep 2; t=$((t + 2))
done
say "LU ACCEPT ($([ "$RESTART" = 1 ] && echo "in ${t}s" || echo "already obtained"))"
# After the LU, the channel is released and the mobile re-syncs to the cell: a
# call placed in the same second gets its RACH ignored (cause 47).
[ "$RESTART" = 1 ] && { say "letting the mobile re-sync after the LU (20 s) ..."; sleep 20; }

exec python3 -I - "$APPELS" <<'PY'
import array, math, os, socket, subprocess, sys, time

APPELS = int(sys.argv[1])
DEST, VTY = "600", ("127.0.0.1", 4247)
TAUX, SEUIL_DL, SEUIL_TON = 8000, 300.0, 0.4
os.makedirs("/tmp/verif", exist_ok=True)

def dire(m): print(f"\033[1m[verif]\033[0m {m}", flush=True)

def vty(*cmds):
    with socket.create_connection(VTY, timeout=5) as s:
        time.sleep(0.3)
        for c in ("enable",) + cmds:
            s.sendall((c + "\r\n").encode()); time.sleep(0.3)

def canaux_up():
    r = subprocess.run(["asterisk", "-rx", "core show channels concise"], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if "!Up!" in l]

def raccrocher():
    try: vty("hangup 1")
    except OSError: pass
    subprocess.run(["asterisk", "-rx", "channel request hangup all"], capture_output=True)
    for _ in range(20):
        if not canaux_up(): return
        time.sleep(0.5)

def lire(chemin, depuis=0):
    with open(chemin, "rb") as f:
        f.seek(depuis * 2); return array.array("h", f.read())

def rms(s): return math.sqrt(sum(x * x for x in s) / len(s)) if s else 0.0

def part_1k(s):
    """Share of the energy at 1 kHz (Goertzel) in the segment."""
    if not s: return 0.0
    k = 2 * math.cos(2 * math.pi * 1000 / TAUX); s1 = s2 = 0.0
    for x in s: s0 = x + k * s1 - s2; s2, s1 = s1, s0
    p = s1 * s1 + s2 * s2 - k * s1 * s2
    tot = sum(x * x for x in s)
    return (2 * p / len(s)) / tot if tot else 0.0

def ton(duree):
    n = int(duree * TAUX)
    return array.array("h", (int(8000 * math.sin(2 * math.pi * 1000 * i / TAUX)) for i in range(n))).tobytes()

def appel(i):
    raw = f"/tmp/verif/appel{i}.raw"
    rec = subprocess.Popen(["parec", "--device=gsm_audio.monitor", "--format=s16le", f"--rate={TAUX}",
                            "--channels=1", "--raw"], stdout=open(raw, "wb"))
    res = {"appel": False, "dl": 0.0, "ul": 0.0, "essais": 0}
    try:
        time.sleep(1)
        for essai in (1, 2):
            t0 = time.time()
            vty(f"call 1 {DEST}")
            while time.time() - t0 < 30 and not canaux_up(): time.sleep(0.5)
            if canaux_up(): break
            raccrocher(); time.sleep(10)
        res["essais"] = essai
        if not canaux_up():
            return res
        res["appel"] = True
        # announcement: wait for the start (RMS > threshold), then the end (2 s of quiet)
        debut = fin = None; pos = 0; t1 = time.time()
        while time.time() - t1 < 90:
            time.sleep(1)
            d = lire(raw)
            while pos + TAUX <= len(d):
                r = rms(d[pos:pos + TAUX]); res["dl"] = max(res["dl"], r)
                if debut is None and r > SEUIL_DL: debut = pos
                if debut is not None and r < SEUIL_DL / 3:
                    fin = fin if fin is not None else pos
                elif debut is not None:
                    fin = None
                pos += TAUX
            if fin is not None and pos - fin >= 2 * TAUX: break
        if debut is None:
            return res
        # echo: 4 s of 1 kHz into the mobile's mic, then look for the return
        marque = len(lire(raw))
        subprocess.run(["pacat", "--playback", "--device=gsm_mic", "--format=s16le", f"--rate={TAUX}",
                        "--channels=1", "--raw"], input=ton(4.0))
        time.sleep(6)
        retour = lire(raw, marque)
        res["ul"] = max((part_1k(retour[p:p + TAUX]) for p in range(0, max(1, len(retour) - TAUX), TAUX // 2)),
                        default=0.0)
        return res
    finally:
        raccrocher(); rec.terminate(); rec.wait()

ok_total = True
for i in range(1, APPELS + 1):
    dire(f"call {i}/{APPELS} to {DEST} ...")
    r = appel(i)
    v_appel = r["appel"]; v_dl = r["dl"] > SEUIL_DL; v_ul = r["ul"] > SEUIL_TON
    ok = v_appel and v_dl and v_ul; ok_total &= ok
    dire(f"call {i}: {'OK' if ok else 'FAILED'}  | established {'yes' if v_appel else 'NO'}{' (2nd attempt)' if r['essais'] == 2 else ''}"
         f" | DL voice {'yes' if v_dl else 'NO'} (max RMS {r['dl']:.0f})"
         f" | UL voice (1 kHz echo) {'yes' if v_ul else 'NO'} (1 kHz share {r['ul']:.2f})")
    time.sleep(3)
dire("VERDICT: " + ("OK - attach, calls, downlink and uplink voice" if ok_total else "FAILED (see above)"))
sys.exit(0 if ok_total else 1)
PY
