#!/usr/bin/env python3
# osmo-fft-snap.py - les deux spectres I/Q du banc (MS montant, BTS descendant)
# rendus en PNG pour le Conky du bureau (configs/conky/osmo-conky-fft.conf).
#
# Source : le dashboard, http://127.0.0.1:8080/psd?src=ms|bts - le meme JSON que
# l onglet FFT (vue "fft1") du navigateur : freqs (Hz), psd (dB), dr (plage
# dynamique), arfcn, label. Ici pas de navigateur : on trace en Pillow, une
# image par source, toutes les secondes, et Conky les affiche (${image ... -n}).
#
#   /run/osmo-fft/ms.png   376x300   spectre + chute d eau, MS (seule source par defaut)
#   /run/osmo-fft/bts.png  376x300   idem BTS, si OSMO_FFT_SOURCES=ms,bts
#
# Sans flux (stack arretee, "flux pas encore pret"), l image le dit en clair
# plutot que de figer le dernier spectre. Lance par osmo-fft-snap.service.
import json
import os
import sys
import time
import urllib.request

from PIL import Image, ImageDraw, ImageFont

URL = os.environ.get("OSMO_FFT_URL", "http://127.0.0.1:8080/psd")
OUT = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
PERIOD = float(os.environ.get("OSMO_FFT_PERIOD", "1"))
# [2026-09-04] UN SEUL SPECTRE, CELUI DU MOBILE. Le Conky ne montre plus que le
# montant (MS) : c est le signal qu on regarde sur le banc, la BTS emet en
# continu et son spectre n apprend rien. L image prend donc toute la hauteur
# (300 px : spectre plus haut, chute d eau plus longue). OSMO_FFT_SOURCES=ms,bts
# et OSMO_FFT_H=150 redonnent les deux vignettes d avant.
W = 376
H = int(os.environ.get("OSMO_FFT_H", "300"))
TITLE_H = 18
PSD_H = int(os.environ.get("OSMO_FFT_PSD_H", str(max(58, H // 4))))
WF_H = H - TITLE_H - PSD_H - 4
FONT_DIR = "/usr/share/fonts/truetype/dejavu"

ALL_SOURCES = {"ms": "MS  ·  montant (UL)", "bts": "BTS  ·  descendant (DL)"}
SOURCES = {k: ALL_SOURCES[k] for k in os.environ.get("OSMO_FFT_SOURCES", "ms").split(",") if k in ALL_SOURCES}
history = {k: [] for k in SOURCES}


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


F_TITLE = font("DejaVuSansMono-Bold.ttf", 11)
F_SMALL = font("DejaVuSansMono.ttf", 10)


def inferno(v):
    """Palette type inferno, 0..1 -> RGB (la meme famille que l onglet FFT)."""
    stops = [(0, (0, 0, 4)), (0.25, (87, 16, 110)), (0.5, (188, 55, 84)),
             (0.75, (249, 142, 9)), (1.0, (252, 255, 164))]
    v = 0.0 if v < 0 else 1.0 if v > 1 else v
    for i in range(len(stops) - 1):
        a, ca = stops[i]
        b, cb = stops[i + 1]
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            return tuple(int(ca[j] + (cb[j] - ca[j]) * t) for j in range(3))
    return stops[-1][1]


def fetch(src):
    req = urllib.request.Request(f"{URL}?src={src}&t={int(time.time() * 1000)}",
                                 headers={"Cache-Control": "no-store"})
    with urllib.request.urlopen(req, timeout=2) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def normalize(psd, dr):
    top = max(psd)
    floor = top - (dr if dr and dr > 0 else 40)
    span = top - floor if top > floor else 1
    return [min(1.0, max(0.0, (p - floor) / span)) for p in psd]


def resample(vals, n):
    """Ramene une liste a n colonnes (max par groupe : un pic reste visible)."""
    if len(vals) <= n:
        return vals + [vals[-1]] * (n - len(vals)) if vals else [0.0] * n
    out = []
    step = len(vals) / n
    for i in range(n):
        a, b = int(i * step), max(int((i + 1) * step), int(i * step) + 1)
        out.append(max(vals[a:b]))
    return out


def render(src, data, err=None):
    img = Image.new("RGB", (W, H), (13, 17, 23))
    d = ImageDraw.Draw(img)
    title = SOURCES[src]
    d.text((6, 3), title, font=F_TITLE, fill=(88, 166, 255))
    if err or not data or "psd" not in data:
        msg = (data or {}).get("error") if data else None
        msg = msg or err or "pas de flux"
        d.text((6, TITLE_H + 6), "ARFCN " + str((data or {}).get("arfcn", "?")), font=F_SMALL, fill=(120, 130, 150))
        d.rectangle((0, TITLE_H + PSD_H + 2, W, H), fill=(8, 10, 14))
        d.text((6, TITLE_H + PSD_H + 10), str(msg)[:52], font=F_SMALL, fill=(248, 81, 73))
        d.text((6, TITLE_H + PSD_H + 26), "stack arretee ? ./start-direct.sh", font=F_SMALL, fill=(120, 130, 150))
        history[src].clear()
        return img
    arfcn = data.get("arfcn", "?")
    tag = f"ARFCN {arfcn}"
    d.text((W - 6 - d.textlength(tag, font=F_SMALL), 4), tag, font=F_SMALL, fill=(63, 185, 80))

    vals = resample(normalize(data["psd"], data.get("dr", 40)), W)
    # Spectre
    y0, y1 = TITLE_H, TITLE_H + PSD_H
    d.rectangle((0, y0, W, y1), fill=(8, 10, 14))
    for gy in range(1, 4):
        yy = y0 + gy * PSD_H // 4
        d.line((0, yy, W, yy), fill=(24, 30, 40))
    pts = [(x, y1 - 1 - int(v * (PSD_H - 4))) for x, v in enumerate(vals)]
    for x, y in pts:
        d.line((x, y, x, y1 - 1), fill=(30, 70, 110))
    d.line(pts, fill=(88, 210, 255), width=1)
    # Chute d eau : une ligne par image, la plus recente en haut
    hist = history[src]
    hist.insert(0, vals)
    del hist[WF_H:]
    wy = y1 + 4
    wf = Image.new("RGB", (W, WF_H), (8, 10, 14))
    px = wf.load()
    for row, line in enumerate(hist):
        for x, v in enumerate(line):
            px[x, row] = inferno(v)
    img.paste(wf, (0, wy))
    return img


def write(src, img):
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, f".{src}.tmp.png")
    img.save(tmp, "PNG")
    os.replace(tmp, os.path.join(OUT, f"{src}.png"))


def main():
    print(f"[fft-snap] {URL} -> {OUT} toutes les {PERIOD}s", flush=True)
    while True:
        t = time.time()
        for src in SOURCES:
            data, err = None, None
            try:
                data = fetch(src)
            except Exception as e:  # dashboard absent, timeout...
                err = f"dashboard injoignable ({type(e).__name__})"
            try:
                write(src, render(src, data, err))
            except Exception as e:
                print(f"[fft-snap] rendu {src} : {e}", file=sys.stderr, flush=True)
        time.sleep(max(0.2, PERIOD - (time.time() - t)))


if __name__ == "__main__":
    main()
