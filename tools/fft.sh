#!/usr/bin/env bash
# tools/fft.sh - "pretty" FFT of the Calypso I/Q stream, read DIRECTLY in the docker.
#
# Reads /tmp/record.cfile (the CONTINUOUS record ring, written by record_drain.py
# which drains iq_record.fifo in O_RDWR - DECOUPLED from the real-time relay
# loop) IN the container, fetches it as fc32 (complex64), and displays on the
# HOST's X: averaged PSD (home-made Welch) + scrolling waterfall. Loops (FuncAnimation).
#
# /!\ There is no 'fifo' mode (LIVE tap of /tmp/iq_fft.fifo): opening that fifo
#     for reading forces the IPC device to write it and disturbs the real-time
#     relay -> the grgsm decode stops (si-bridge 'fini') and camping freezes.
#     record.cfile is near-live and has NO effect on the pipeline.
#
# Usage:
#   ./tools/fft.sh                      # tail of record.cfile (default, non-intrusive)
#   FFT_SRC=sweep ./tools/fft.sh        # sweep the whole record ring
#   ./tools/fft.sh --save spectre.png   # one PNG capture (if no X)
#   CONTAINER=osmo-operator-1 CFILE=/tmp/record.cfile RATE=1083333 \
#   NSAMP=262144 REFRESH=1.0 ARFCN=514 ./tools/fft.sh
#
set -euo pipefail
export CONTAINER="${CONTAINER:-osmo-operator-1}"
export FFT_SRC="${FFT_SRC:-tail}"   # tail (defaut, NON-perturbant) | sweep - lisent record.cfile
# NB: no 'fifo' mode (LIVE tap of /tmp/iq_fft.fifo): opening that fifo for
# reading forces the IPC device to write it, which disturbs the real-time relay
# loop and CUTS the grgsm decode (si-bridge 'fini') -> camping freezes.
# record.cfile is read instead, fed by record_drain.py (decoupled, always-on).
export CFILE="${CFILE:-/dev/shm/dsp_iq.cfile}"    # entree DSP shunt = MS (le mobile qui repond a la BTS ; cfile fc32 en /dev/shm RAM). Fichier qui GRANDIT -> tail-c lit le frais. (override CFILE=/dev/shm/record.cfile = BTS)
export RATE="${RATE:-1083333}"      # 4 SPS natif = 26e6/24
export NSAMP="${NSAMP:-32768}"      # complex samples par fenetre (256 KB) - court = ca gigote
export REFRESH="${REFRESH:-0.25}"   # periode de rafraichissement (s) - court = fluide
export ARFCN="${ARFCN:-514}"        # juste pour le titre (DCS1800)
export DISPLAY="${DISPLAY:-:0}"
export FFT_SAVE=""
[ "${1:-}" = "--save" ] && export FFT_SAVE="${2:?--save needs a path}"

# guards
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }
case "$FFT_SRC" in
  sweep|tail) ;;
  *) echo "[fft] FFT_SRC='$FFT_SRC' invalide. Le mode 'fifo' (tap live) a ete retire"
     echo "[fft] (il perturbe le relai temps-reel et coupe le decode grgsm). -> tail."
     export FFT_SRC=tail ;;
esac
docker exec "$CONTAINER" test -f "$CFILE" \
  || { echo "record absent $CONTAINER:$CFILE (lance ./run.sh d'abord ; record_drain.py alimente record.cfile)"; exit 1; }

python3 - <<'PYEOF'
import os, sys, subprocess, numpy as np
import matplotlib
SAVE = os.environ.get("FFT_SAVE","")
if SAVE:
    matplotlib.use("Agg")
else:
    for bk in ("TkAgg","Qt5Agg","GTK3Agg"):
        try: matplotlib.use(bk); break
        except Exception: continue
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

CONT  = os.environ["CONTAINER"]; CFILE = os.environ["CFILE"]
RATE  = float(os.environ["RATE"]); NS = int(os.environ["NSAMP"])
REFRESH = float(os.environ["REFRESH"]); ARFCN = os.environ["ARFCN"]
NBYTES = NS*8                      # complex64 = 8 o/sample
NFFT  = 4096                       # resolution FFT (segment Welch)
WROWS = 120                        # lignes du waterfall

win = np.hanning(NFFT).astype(np.float32)
freqs = np.fft.fftshift(np.fft.fftfreq(NFFT, 1.0/RATE)) / 1e3   # kHz

SRC  = os.environ.get("FFT_SRC","tail")    # tail (defaut) | sweep - lisent record.cfile
if SRC not in ("sweep","tail"): SRC = "tail"   # 'fifo' retire (tap live nocif)
BS   = 4096; NBLK = max(1, NBYTES//BS)

# ---- file modes: sweep the ring (sweep) or read the tail of record.cfile
#      (fed by record_drain.py, decoupled from the real-time relay loop).
def _filesize():
    try:
        return int(subprocess.run(["docker","exec",CONT,"stat","-c","%s",CFILE],
                                  capture_output=True,timeout=5).stdout or 0)
    except Exception: return NBYTES
def _ringsize():
    # ring size published by record_drain (modulo for the LIVE wrap)
    try:
        v = int(subprocess.run(["docker","exec",CONT,"cat",CFILE+".ring"],
                               capture_output=True,timeout=5).stdout or 0)
        if v > 0: return v
    except Exception: pass
    return _filesize()
RING = _ringsize()
_off = [0]

def _dd(skip_blk, count_blk):
    return subprocess.run(["docker","exec",CONT,"dd","if="+CFILE,"bs="+str(BS),
        "skip="+str(skip_blk),"count="+str(count_blk),"status=none"],
        capture_output=True, timeout=8).stdout

def grab():
    """Rend NBYTES d'I/Q complex64 (le plus frais), depuis record.cfile.
    SRC=tail  : derniers octets (defaut, near-live, non-perturbant).
    SRC=sweep : balaye le ring record (offset qui avance)."""
    if SRC == "sweep":
        skip = _off[0] // BS
        try:
            raw = subprocess.run(["docker","exec",CONT,"dd","if="+CFILE,
                "bs="+str(BS),"skip="+str(skip),"count="+str(NBLK),"status=none"],
                capture_output=True, timeout=8).stdout
        except Exception:
            return None
        _off[0] += NBYTES
        if _off[0] + NBYTES > RING: _off[0] = 0
    else:
        # LIVE (tail): read the fresh window ENDING at the write offset
        # published by record_drain (<cfile>.off). With the ring, seek(0) puts
        # the fresh data at `w` (middle), NOT at the tail. Block-aligned + wrap.
        try:
            w = int(subprocess.run(["docker","exec",CONT,"cat",CFILE+".off"],
                                   capture_output=True, timeout=5).stdout or -1)
        except Exception:
            w = -1
        try:
            if w >= 0:
                wblk = w // BS; start_blk = wblk - NBLK
                if start_blk >= 0:
                    raw = _dd(start_blk, NBLK)
                else:                              # fenetre a cheval sur le wrap
                    ring_blk = RING // BS; n_end = -start_blk
                    raw = _dd(ring_blk - n_end, n_end) + _dd(0, wblk)
            else:                                   # repli : pas d'offset publie
                raw = subprocess.run(["docker","exec",CONT,"tail","-c",str(NBYTES),CFILE],
                                     capture_output=True, timeout=8).stdout
        except Exception:
            return None
    n = (len(raw)//8)*8
    if n < NFFT*8: return None
    return np.frombuffer(raw[:n], dtype=np.complex64)

def welch_psd(iq):
    """PSD moyennee (segments NFFT, overlap 50%, fenetre Hann) en dB"""
    step = NFFT//2; nseg = max(1,(len(iq)-NFFT)//step + 1)
    acc = np.zeros(NFFT, dtype=np.float64)
    for i in range(nseg):
        seg = iq[i*step:i*step+NFFT]
        if len(seg) < NFFT: break
        sp = np.fft.fftshift(np.fft.fft(seg*win))
        acc += (sp.real**2 + sp.imag**2)
    psd = acc/max(1,nseg)
    return 10*np.log10(psd/ (NFFT*RATE) + 1e-20)

# ---- "pretty" figure: PSD (top) + waterfall (bottom) vertically ALIGNED.
#      GridSpec 2x2: col 0 = the 2 plots (SAME width), col 1 = colorbar (only on
#      the waterfall row) -> the colorbar does not shrink the waterfall, so x=0
#      falls on the SAME vertical in the PSD and the waterfall. sharex links the axes. ----
plt.style.use("dark_background")
fig = plt.figure(figsize=(11,8))
gs = fig.add_gridspec(2, 2, width_ratios=[40, 1], height_ratios=[1, 1.4],
                      hspace=0.18, wspace=0.015)
axp = fig.add_subplot(gs[0, 0])
axw = fig.add_subplot(gs[1, 0], sharex=axp)   # x partage -> aligne avec la PSD
cax = fig.add_subplot(gs[1, 1])               # colorbar dans sa colonne (n'affecte pas axw)
fig.suptitle(f"Calypso I/Q live - {CONT}:{CFILE}  |  ARFCN={ARFCN}  Fs={RATE/1e6:.4f} MHz",
             fontsize=11, color="#7fd")
(line,) = axp.plot(freqs, np.full(NFFT,-120), lw=0.5, color="#39f")
axp.set_xlim(freqs[0],freqs[-1]); axp.set_ylim(-130,-30)
axp.set_ylabel("PSD (dB)"); axp.grid(alpha=0.25)
axp.axvline(0, color="#f55", lw=0.7, alpha=0.7)
plt.setp(axp.get_xticklabels(), visible=False)   # l'axe x est porte par la waterfall en bas

wf = np.full((WROWS,NFFT), -120.0)
im = axw.imshow(wf, aspect="auto", origin="upper", cmap="turbo",
                extent=[freqs[0],freqs[-1],0,WROWS], vmin=-120, vmax=-50,
                interpolation="bilinear")
axw.set_ylabel("temps (frames)"); axw.set_xlabel("offset (kHz)")
axw.axvline(0, color="#fff", lw=0.7, alpha=0.5)  # meme 0 vertical que la PSD
fig.colorbar(im, cax=cax, label="dB")
fig.subplots_adjust(left=0.08, right=0.92, top=0.92, bottom=0.08)

def update(_):
    iq = grab()
    if iq is None: return line, im
    psd = welch_psd(iq)
    line.set_ydata(psd)
    lo,hi = np.percentile(psd,5), np.percentile(psd,99.5)
    axp.set_ylim(lo-5, hi+8)
    global wf
    wf = np.roll(wf,1,axis=0); wf[0,:] = psd
    im.set_data(wf); im.set_clim(lo, hi+5)
    return line, im

if SAVE:
    update(0)                       # une passe
    fig.savefig(SAVE, dpi=110, facecolor=fig.get_facecolor())
    print("ecrit", SAVE)
else:
    ani = FuncAnimation(fig, update, interval=int(REFRESH*1000),
                        blit=False, cache_frame_data=False)
    print("FFT live - ferme la fenetre pour quitter.")
    plt.show()
PYEOF
