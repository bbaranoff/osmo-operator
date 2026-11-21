#!/usr/bin/env python3
"""echotest.py - echo test with a SPEAK indicator (osmo-minioperator, DSP = TI ROM on c54x_exe).

Calls the 600 (Asterisk: a 22 s announcement, then Echo()), then shows live:
  MIC   what goes into the phone's microphone (gsm_mic: your mic, via docker-run.sh's PulseAudio)
        -> SPEAK when you talk: the voice enters the ROM vocoder, uplink
  ECHO  what comes back on the phone's loudspeaker (gsm_audio): Asterisk's echo, downlink
The ">>> say" prompt appears when Asterisk enters Echo(): say "hello 40c3", hear it come back.
"round trip" = from the start of your utterance to the start of its echo.

  python3 echotest.py                    call the 600 (or use the call already active), then the meters
  (always recorded unless --no-rec)      --rec DIR (default /root/echo): echo.cast (asciinema v2, this
                                         terminal) + the GSM tracks, only while they exist, same clock (t=0 =
                                         start of the cast): dl.wav downlink (gsm_audio, ROM vocoder output,
                                         from CC ACTIVE), ul.wav uplink (what Asterisk receives from the phone:
                                         MixMonitor r() started on the live channel), echo.wav both mixed.
                                         The raw microphone is never recorded (it only drives SPEAK).
  python3 echotest.py --duree 25         stop by itself 25 s after Echo() starts
  python3 echotest.py -f hello.wav       play this file into the mic once Echo() runs (no mic needed)
  options: --num 600 --texte "hello 40c3" --seuil 300 --attente 25 --deja
Ctrl-C stops; it hangs up only a call it dialled itself.
The call is followed through the phone's CC state in mobile.log. Asterisk's application is shown when
its channel is visible. SPEAK/ECHO: RMS over 50 ms above max(--seuil, 3 x the noise floor of the last 3 s).
Run inside the container, stack from ./run-dsp.sh up. Stdlib only.
"""
import argparse, array, collections, json, math, os, re, shutil, signal, socket, subprocess, sys, threading, time, wave

TAUX = 8000
MLOG = "/tmp/c54x-pont/mobile.log"
ap = argparse.ArgumentParser(description="echo test + SPEAK indicator")
ap.add_argument("--num", default="600")
ap.add_argument("--deja", action="store_true", help="a call is already up: never dial, never hang up")
ap.add_argument("-f", "--fichier", help="wav, or raw s16le 8 kHz mono, played into gsm_mic once Echo() runs")
ap.add_argument("--rec", default="/root/echo", help="directory: echo.cast + dl.wav, ul.wav, echo.wav: GSM tracks only (default /root/echo)")
ap.add_argument("--no-rec", action="store_true", help="do not record")
ap.add_argument("--duree", type=float, default=0, help="stop N s after Echo() starts (0 = until Ctrl-C)")
ap.add_argument("--attente", type=float, default=25, help="Asterisk channel not visible: Echo() assumed N s after answer")
ap.add_argument("--texte", default="hello 40c3", help="what the prompt asks you to say")
ap.add_argument("--seuil", type=float, default=300.0, help="minimum RMS for SPEAK / ECHO")
a = ap.parse_args()
if a.no_rec:
    a.rec = None

f = "/run/osmo-minioperator/logs/pulse_server"
if os.path.exists(f) and "PULSE_SERVER" not in os.environ:
    v = open(f).read().strip()
    if v and v != "defaut":
        os.environ["PULSE_SERVER"] = v

T0 = time.time()
COLS, ROWS = shutil.get_terminal_size((100, 30))
CAST = None
if a.rec:
    os.makedirs(a.rec, exist_ok=True)
    CAST = open(os.path.join(a.rec, "echo.cast"), "w")
    CAST.write(json.dumps({"version": 2, "width": COLS, "height": ROWS, "timestamp": int(T0),
                           "title": "echo test: hello 40c3 through the TI ROM (osmo-minioperator)"}) + "\n")


def out(t):
    sys.stdout.write(t); sys.stdout.flush()
    if CAST:
        CAST.write(json.dumps([round(time.time() - T0, 6), "o", t.replace("\n", "\r\n")]) + "\n"); CAST.flush()


def p(*x):
    out(" ".join(str(i) for i in x) + "\n")


def vty(*cmds):
    s = socket.create_connection(("127.0.0.1", 4247), timeout=5)
    def lire(t):
        fin = time.time() + t
        while time.time() < fin:
            s.settimeout(max(0.05, fin - time.time()))
            try:
                if not s.recv(4096): break
            except socket.timeout: break
    lire(0.5); s.sendall(b"enable\r\n"); lire(0.5)
    for c in cmds:
        s.sendall(c.encode() + b"\r\n"); lire(1.0)
    s.close()


def canal():
    """Asterisk channel of the call: (state, application, channel name) or None."""
    try:
        o = subprocess.run(["asterisk", "-rx", "core show channels concise"], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return None
    for l in o.splitlines():
        c = l.split("!")
        if len(c) > 6:
            return c[4], c[5] + ("(" + c[6] + ")" if c[6] else ""), c[0]
    return None


def cc_depuis(pos):
    """Last CC state of the phone in mobile.log after byte pos: 'ACTIVE', 'NULL', ... or None."""
    try:
        with open(MLOG, "rb") as fh:
            fh.seek(pos); t = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    e = re.findall(r"gsm48_cc\.c:\d+ new state \S+ -> (\S+)", re.sub(r"\x1b\[[0-9;]*m", "", t))
    return e[-1] if e else None


def taille():
    try: return os.path.getsize(MLOG)
    except OSError: return 0


# ---- the two audio streams: level every 50 ms, and (--rec) every sample, timed on T0
niv = {"mic": 0.0, "echo": 0.0}
bruit = {"mic": collections.deque(maxlen=60), "echo": collections.deque(maxlen=60)}   # 3 s of 50 ms levels
pistes = {"mic": bytearray(), "echo": bytearray()}
debut_piste = {}
procs = []


def mesure(cle, dev):
    pr = subprocess.Popen(["parec", "--device=" + dev, "--format=s16le", "--rate=%d" % TAUX,
                           "--channels=1", "--raw", "--latency-msec=20"], stdout=subprocess.PIPE)
    procs.append(pr)
    n = TAUX // 20
    while True:
        b = pr.stdout.read(2 * n)
        if not b:
            return
        if cle not in debut_piste:                   # time of the first sample: now minus this block
            debut_piste[cle] = time.time() - len(b) / 2 / TAUX - T0
        if a.rec and cle == "echo":                  # only the GSM track is recorded, not the raw microphone
            pistes[cle] += b
        s = array.array("h", b[: len(b) // 2 * 2])
        r = math.sqrt(sum(x * x for x in s) / max(1, len(s)))
        niv[cle] = r; bruit[cle].append(r)


def seuil(cle):
    q = sorted(bruit[cle])
    plancher = q[len(q) // 5] if q else 0.0         # 20th percentile of the last 3 s
    return max(a.seuil, 3 * plancher)


def barre(r, w):
    x = 0.0 if r <= 30 else min(1.0, math.log10(r / 30) / math.log10(10000 / 30))
    k = int(round(x * w))
    return "\u2588" * k + "\u2591" * (w - k)


MM_DIR = "/var/spool/asterisk/monitor"
mm = {}


def mm_start(nom):
    """GSM uplink: what Asterisk receives from the phone (after the ROM's encoder, the network, the MGW).
    MixMonitor started from the CLI on the live channel (no dialplan change), r() = read direction only."""
    if mm or not a.rec:
        return
    f = os.path.join(MM_DIR, "echotest-%d-ul.wav" % int(T0))
    mm.update(nom=nom, f=f, t=time.time() - T0)
    # one argument "file,options" (the MixMonitor application syntax): with a space, r() was not taken
    r = subprocess.run(["asterisk", "-rx", "mixmonitor start %s %s/echotest-%d-mix.wav,r(%s)" % (nom, MM_DIR, int(T0), f)],
                       capture_output=True, text=True, timeout=5)
    mm["rsp"] = (r.stdout + r.stderr).strip()


def mm_stop():
    if mm:
        subprocess.run(["asterisk", "-rx", "mixmonitor stop %s" % mm["nom"]], capture_output=True, timeout=5)
        time.sleep(0.5)


def place(sig, debut, n):
    """sig (array h) placed at debut seconds on a track of n samples (t=0 = start of the cast)."""
    o = array.array("h", bytes(2 * n)); d = int(round(debut * TAUX))
    for i, x in enumerate(sig):
        if 0 <= d + i < n: o[d + i] = x
    return o


def ecrire_audio_gsm():
    """ul.wav: GSM uplink (Asterisk, MixMonitor r()), from the moment Asterisk has the channel.
    dl.wav: GSM downlink (gsm_audio, ROM vocoder output), from CC ACTIVE to the end of the call.
    echo.wav: both mixed. Nothing outside the call; the raw microphone is never recorded."""
    if not a.rec or "echo" not in debut_piste or t_actif is None:
        return
    dl = array.array("h", bytes(pistes["echo"][: len(pistes["echo"]) // 2 * 2]))
    t0d = debut_piste["echo"]
    i0, i1 = int((t_actif - t0d) * TAUX), int(((t_fin if t_fin else 1e9) - t0d) * TAUX)
    dl = dl[max(0, i0): max(0, i1)]
    debut_dl = max(t_actif, t0d)
    ul, debut_ul = array.array("h"), None
    if mm and os.path.exists(mm["f"]):
        try:
            w = wave.open(mm["f"]); r = w.getframerate()
            ul = array.array("h", w.readframes(w.getnframes())); debut_ul = mm["t"]
            if r != TAUX: ul = ul[::max(1, r // TAUX)]
        except Exception as e:
            p("uplink file unreadable: %s" % e)
    n = int(max(debut_dl + len(dl) / TAUX, (debut_ul or 0) + len(ul) / TAUX) * TAUX) + 1
    pdl = place(dl, debut_dl, n)
    pul = place(ul, debut_ul, n) if debut_ul is not None else array.array("h", bytes(2 * n))
    mix = array.array("h", (max(-32768, min(32767, x + y)) for x, y in zip(pdl, pul)))
    for nom, sig in (("dl.wav", pdl), ("ul.wav", pul), ("echo.wav", mix)):
        w = wave.open(os.path.join(a.rec, nom), "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(TAUX)
        w.writeframes(sig.tobytes()); w.close()
    p("recorded in %s: echo.cast; dl.wav (GSM downlink from %.1f s), ul.wav (GSM uplink %s), echo.wav (both); %.1f s"
      % (a.rec, debut_dl, ("from %.1f s, %.1f s long" % (debut_ul, len(ul) / TAUX)) if debut_ul is not None else "MISSING",
         n / TAUX))
    if debut_ul is not None:                         # Asterisk's copies, now in ul.wav (kept when the uplink is missing)
        for f in (mm.get("f"), mm.get("f", "").replace("-ul.wav", "-mix.wav")):
            if f and os.path.exists(f): os.remove(f)
    elif mm:
        p("uplink: mixmonitor on %s answered %r; files in %s: %s" % (mm["nom"], mm.get("rsp", ""), MM_DIR,
          " ".join(sorted(os.listdir(MM_DIR))) or "none"))
    else:
        p("uplink: no Asterisk channel seen during the call, mixmonitor never started")
    if not os.environ.get("ECHO_LIVE"):
        p("MP4: on the host, sudo /opt/GSM/demos/osmo/uplink-mp4.sh   (or run sudo /opt/GSM/demos/osmo/uplink-live.sh next time: MP4 right after Ctrl-C)")


signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
B, G, Y, M, D, R = "\033[1m", "\033[1;32m", "\033[1;33m", "\033[1;35m", "\033[2m", "\033[0m"
appel_lance = False
t_actif = t_fin = None          # call ACTIVE / ended, seconds from T0
pos_appel = taille()
for cle, dev in (("mic", "gsm_mic.monitor"), ("echo", "gsm_audio.monitor")):   # from the start: the whole call
    threading.Thread(target=mesure, args=(cle, dev), daemon=True).start()
try:
    if not a.deja and cc_depuis(0) == "ACTIVE":
        p("a call is already active (phone CC ACTIVE): meters only, Ctrl-C leaves it up")
        a.deja = True
    if a.deja:
        a.attente = 0; t_actif = time.time() - T0
    else:
        for essai in (1, 2):
            pos = taille()
            p(f"{Y}$ telnet 127.0.0.1 4247  (mobile)> call 1 {a.num}{R}")
            vty(f"call 1 {a.num}"); appel_lance = True
            t0 = time.time(); etat = None
            while time.time() - t0 < 30:
                etat = cc_depuis(pos) or etat
                out(f"\r\033[K  waiting: phone CC state {etat or '...'}  {time.time() - t0:4.0f} s")
                if etat in ("ACTIVE", "NULL"):
                    break
                time.sleep(0.5)
            out("\n")
            if etat == "ACTIVE":
                pos_appel = pos; t_actif = time.time() - T0
                break
            p(f"call not active (phone CC {etat}): nothing hung up")
            appel_lance = False
            if essai == 1:
                time.sleep(10)
        else:
            p("call NOT established. Is the phone camped?  grep -a NO_CELL_FOUND /tmp/c54x-pont/mobile.log | tail -1"
              "  -> if so, restart the stack: INSNS=120000 ./run-dsp.sh"); sys.exit(1)
        p("call established: phone CC state ACTIVE")
    p(f"{B}Say \"{a.texte}\" when the prompt says so (after Asterisk's announcement). Ctrl-C stops.{R}\n")
    w = max(10, min(40, COLS - 40))
    t_debut = time.time(); en_echo = False; t_echo = t_debut
    debut_mic = debut_echo = delai = None
    parle = echo = 0.0; joue = False; c = canal(); tc = time.time()
    out("\n\n\n")
    while True:
        time.sleep(0.1)
        now = time.time()
        if now - tc > 0.5:
            c = canal(); tc = now
        app = c[1] if c else "-"
        if c and t_actif is not None:
            mm_start(c[2])
        if not en_echo and ((c and c[1].startswith("Echo")) or (not c and now - t_debut > a.attente)):
            en_echo = True; t_echo = now
        if a.fichier and not joue and en_echo:
            joue = True
            lect = ["paplay", "--device=gsm_mic", a.fichier] if a.fichier.endswith(".wav") else \
                   ["pacat", "--playback", "--device=gsm_mic", "--format=s16le", "--rate=8000", "--channels=1", "--raw", a.fichier]
            procs.append(subprocess.Popen(lect, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        sm, se = seuil("mic"), seuil("echo")
        if niv["mic"] > sm:
            if now - parle > 0.6 and en_echo:
                debut_mic = now                       # start of an utterance
            parle = now
        if niv["echo"] > se:
            if now - echo > 0.6 and en_echo and debut_mic and (debut_echo is None or debut_echo < debut_mic):
                debut_echo = now; delai = debut_echo - debut_mic
            echo = now
        sp = f"{G}\u25cf SPEAK{R}" if now - parle < 0.3 else f"{D}\u25cb speak{R}"
        ec = f"{M}\u25c0 ECHO{R}" if now - echo < 0.3 else f"{D}  echo{R}"
        dire = f"{B}{Y}>>> say: {a.texte}{R}" if en_echo else f"{D}(announcement, wait for Echo){R}"
        dl = f"round trip {delai:.1f} s" if delai is not None else ""
        out("\033[3A\r\033[K" + f"  {dire}   Asterisk: {app}   {dl}   {now - t_debut:4.0f} s\n"
            + "\r\033[K" + f"  MIC  (uplink)   {G}{barre(niv['mic'], w)}{R} {niv['mic']:6.0f}  {sp}\n"
            + "\r\033[K" + f"  ECHO (downlink) {M}{barre(niv['echo'], w)}{R} {niv['echo']:6.0f}  {ec}\n")
        if appel_lance and cc_depuis(pos_appel) not in ("ACTIVE", None):
            t_fin = time.time() - T0
            p("call ended (phone CC %s)" % cc_depuis(pos_appel)); appel_lance = False; break
        if a.duree and en_echo and now - t_echo > a.duree:
            break
except KeyboardInterrupt:
    out("\n")
finally:
    mm_stop()
    if t_fin is None: t_fin = time.time() - T0
    if appel_lance:
        p(f"{Y}$ (mobile)> call 1 hangup{R}"); vty("call 1 hangup")
    time.sleep(0.3)
    for pr in procs:
        pr.terminate()
    time.sleep(0.2)
    ecrire_audio_gsm()
    if CAST:
        CAST.close()
