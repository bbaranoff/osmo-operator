#!/usr/bin/env bash
# tools/fft_global.sh - FFT "jolie" d'un cfile LOCAL passe en argument (fichier statique).
#
# Derive de tools/fft.sh (osmo_egprs) mais SANS docker / ring / tail-live : lit
# directement un cfile sur l'hote, le balaye en boucle, et affiche
# PSD moyennee (Welch maison) + waterfall defilant (FuncAnimation).
#
# Usage :
#   ./tools/fft_global.sh my.cfile
#   ./tools/fft_global.sh my.cfile --save spectre.png
#   RATE=1083333 NSAMP=32768 REFRESH=0.25 FORMAT=cf32 ARFCN=514 ./tools/fft_global.sh my.cfile
#
# FORMAT : cf32 (complex64, defaut, ce qu'ecrit le shunt) | cs8 | cs16
#          (record.cfile d'osmo-trx est souvent cs8 -> FORMAT=cs8)
set -euo pipefail

CFILE="${1:?usage: tools/fft_global.sh <fichier.cfile> [--save out.png]}"
[ -f "$CFILE" ] || { echo "[fft] introuvable: $CFILE"; exit 1; }
export CFILE="$(readlink -f "$CFILE")"

export RATE="${RATE:-1083333}"      # 4 SPS natif = 26e6/24
export NSAMP="${NSAMP:-32768}"      # complex samples par fenetre
export REFRESH="${REFRESH:-0.25}"   # periode de rafraichissement (s)
export ARFCN="${ARFCN:-514}"        # juste pour le titre
export FORMAT="${FORMAT:-cf32}"     # cf32 | cs8 | cs16
export DISPLAY="${DISPLAY:-:0}"
export FFT_SAVE=""
[ "${2:-}" = "--save" ] && export FFT_SAVE="${3:?--save needs a path}"

python3 - <<'PYEOF'
import os, numpy as np
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

CFILE = os.environ["CFILE"]
RATE  = float(os.environ["RATE"]); NS = int(os.environ["NSAMP"])
REFRESH = float(os.environ["REFRESH"]); ARFCN = os.environ["ARFCN"]
FORMAT = os.environ.get("FORMAT","cf32").lower()
NFFT  = 4096                       # resolution FFT
WROWS = 120                        # lignes du waterfall

# ---- format d'echantillon -> dtype brut + bytes/sample complexe ----
if FORMAT in ("cf32","fc32","complex64"):
    RAWDT, ITEMS = np.float32, 2          # I,F float32
elif FORMAT in ("cs16","sc16","int16"):
    RAWDT, ITEMS = np.int16, 2
elif FORMAT in ("cs8","sc8","int8"):
    RAWDT, ITEMS = np.int8, 2
else:
    raise SystemExit(f"FORMAT inconnu: {FORMAT} (cf32|cs16|cs8)")
SAMP_BYTES = np.dtype(RAWDT).itemsize * ITEMS     # octets / sample complexe
FSIZE = os.path.getsize(CFILE)
NSAMP_TOT = FSIZE // SAMP_BYTES
print(f"[fft] {CFILE}  {FSIZE} o  format={FORMAT}  {NSAMP_TOT} samples  Fs={RATE/1e6:.4f} MHz")
if NSAMP_TOT < NFFT:
    raise SystemExit("[fft] fichier trop court pour une FFT")

win = np.hanning(NFFT).astype(np.float32)
freqs = np.fft.fftshift(np.fft.fftfreq(NFFT, 1.0/RATE)) / 1e3   # kHz

_off = [0]    # offset courant en SAMPLES (balayage en boucle)

def grab():
    """Lit NS samples complexes a l'offset courant, avance, boucle a la fin."""
    start = _off[0]
    if start + NS > NSAMP_TOT:
        start = 0
    raw = np.fromfile(CFILE, dtype=RAWDT, count=NS*ITEMS,
                      offset=start*SAMP_BYTES)
    _off[0] = start + NS
    if len(raw) < NFFT*ITEMS:
        return None
    raw = raw.astype(np.float32)
    iq = raw[0::2] + 1j*raw[1::2]
    if RAWDT == np.int8:   iq /= 128.0
    if RAWDT == np.int16:  iq /= 32768.0
    return iq.astype(np.complex64)

def welch_psd(iq):
    """PSD moyennee (segments NFFT, overlap 50%, Hann) en dB."""
    step = NFFT//2; nseg = max(1,(len(iq)-NFFT)//step + 1)
    acc = np.zeros(NFFT, dtype=np.float64)
    used = 0
    for i in range(nseg):
        seg = iq[i*step:i*step+NFFT]
        if len(seg) < NFFT: break
        sp = np.fft.fftshift(np.fft.fft(seg*win))
        acc += (sp.real**2 + sp.imag**2); used += 1
    psd = acc/max(1,used)
    return 10*np.log10(psd/(NFFT*RATE) + 1e-20)

# ---- figure "jolie" : PSD (haut) + waterfall (bas) alignees ----
plt.style.use("dark_background")
fig = plt.figure(figsize=(11,8))
gs = fig.add_gridspec(2, 2, width_ratios=[40, 1], height_ratios=[1, 1.4],
                      hspace=0.18, wspace=0.015)
axp = fig.add_subplot(gs[0, 0])
axw = fig.add_subplot(gs[1, 0], sharex=axp)
cax = fig.add_subplot(gs[1, 1])
fig.suptitle(f"FFT - {os.path.basename(CFILE)}  |  ARFCN={ARFCN}  Fs={RATE/1e6:.4f} MHz  fmt={FORMAT}",
             fontsize=11, color="#7fd")
(line,) = axp.plot(freqs, np.full(NFFT,-120), lw=0.5, color="#39f")
axp.set_xlim(freqs[0],freqs[-1]); axp.set_ylim(-130,-30)
axp.set_ylabel("PSD (dB)"); axp.grid(alpha=0.25)
axp.axvline(0, color="#f55", lw=0.7, alpha=0.7)
plt.setp(axp.get_xticklabels(), visible=False)

wf = np.full((WROWS,NFFT), -120.0)
im = axw.imshow(wf, aspect="auto", origin="upper", cmap="turbo",
                extent=[freqs[0],freqs[-1],0,WROWS], vmin=-120, vmax=-50,
                interpolation="bilinear")
axw.set_ylabel("temps (fenetres)"); axw.set_xlabel("offset (kHz)")
axw.axvline(0, color="#fff", lw=0.7, alpha=0.5)
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
    update(0)
    fig.savefig(SAVE, dpi=110, facecolor=fig.get_facecolor())
    print("ecrit", SAVE)
else:
    ani = FuncAnimation(fig, update, interval=int(REFRESH*1000),
                        blit=False, cache_frame_data=False)
    print("FFT - ferme la fenetre pour quitter.")
    plt.show()
PYEOF
