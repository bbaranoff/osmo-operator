#!/usr/bin/env python3
# osmo-fft-snap.py - l ENCART VIVANT du bureau : le cadre Calvin & Hobbes du fond
# d ecran (tools/wallpaper-render.py, boite 320,600-1430,1010 en 1920x1080) qui
# FOND vers le banc une fois qu il est pret :
#
#   +-----------------------------------------------------------+
#   |  Spectre I/Q du mobile (montant)   |  mobile.log (QEMU)   |
#   |  spectre + chute d eau             |  dernieres lignes    |
#   +-----------------------------------------------------------+
#
# Tant que le banc n est pas la (pas de flux I/Q sur /psd), l image EST le
# strip du jour, decoupe dans le fond d ecran : le Conky qui l affiche
# (tools/osmo-conky-panel.sh) est invisible. Des que le pont alimente la FFT,
# l image glisse en ~3 s (Image.blend) du strip vers le banc ; si le banc
# s arrete, elle revient au strip de la meme facon.
#
# Source FFT : le dashboard, http://127.0.0.1:8080/psd?src=ms - le meme JSON
# que l onglet FFT (vue fft1) : freqs, psd (dB), dr, arfcn. Le journal : le
# mobile.log de la pile (QEMU MS#1), lu par la queue.
#
#   /run/osmo-fft/panel.png   1110x410  (coordonnees du fond ; Conky le met a
#                                        l echelle de l ecran)
#
# Lance par osmo-fft-snap.service. Ne depend que de Pillow et des polices
# DejaVu, presents sur l image comme sur l hote.
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

from PIL import Image, ImageDraw, ImageFont

URL = os.environ.get("OSMO_FFT_URL", "http://127.0.0.1:8080/psd")
OUT = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
PERIOD = float(os.environ.get("OSMO_FFT_PERIOD", "1"))
FADE_S = float(os.environ.get("OSMO_FFT_FADE", "3"))
WALLPAPER = os.environ.get("OSMO_WP_FILE", "/usr/share/backgrounds/gsm-lab-wallpaper.png")
MOBILE_LOG = os.environ.get("OSMO_MOBILE_LOG", "/run/user/0/osmo-nitb/logs/mobile.log")
# L operateur choisi dans l encart (tools/osmo-panel.py, fleches) : OP=, MODE=,
# IP=, NAME=, DASH=. Absent ou natif : le dashboard et le journal locaux.
OP_FILE = os.path.join(OUT, "operator")
# La boite du strip dans le fond d ecran (wallpaper-render.py, main()).
BOX = (320, 600, 1430, 1010)
W, H = BOX[2] - BOX[0], BOX[3] - BOX[1]
PAD, FOOT = 18, 30
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x07")


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


F_TITLE = font("DejaVuSansMono-Bold.ttf", 15)
F_SMALL = font("DejaVuSansMono.ttf", 12)
F_LOG = font("DejaVuSansMono.ttf", 12)


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


def operator():
    """{'OP','MODE','IP','NAME','DASH'} de l operateur choisi, natif par defaut."""
    op = {"OP": "1", "MODE": "native", "IP": "", "NAME": "", "DASH": URL.rsplit("/", 1)[0]}
    try:
        with open(OP_FILE) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k in op:
                    op[k] = v
    except OSError:
        pass
    return op


def fetch(src):
    op = operator()
    base = URL if op["MODE"] != "docker" else op["DASH"].rstrip("/") + "/psd"
    req = urllib.request.Request(f"{base}?src={src}&t={int(time.time() * 1000)}",
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


# ── LE STRIP : DECOUPE DANS LE FOND D ECRAN, RELU QUAND IL CHANGE ───────────
# Le fond est refait chaque jour (osmo-wallpaper.timer) : on suit son mtime.
_base = {"mtime": None, "img": None}


def base_image():
    try:
        mt = os.stat(WALLPAPER).st_mtime
    except OSError:
        mt = None
    if mt != _base["mtime"] or _base["img"] is None:
        img = None
        if mt is not None:
            try:
                wp = Image.open(WALLPAPER).convert("RGB")
                if wp.size != (1920, 1080):
                    wp = wp.resize((1920, 1080), Image.LANCZOS)
                img = wp.crop(BOX)
            except Exception as e:  # fond illisible : cadre sombre, sans strip
                print(f"[fft-snap] fond {WALLPAPER} : {e}", file=sys.stderr, flush=True)
        if img is None:
            img = Image.new("RGB", (W, H), (20, 24, 36))
            ImageDraw.Draw(img).rounded_rectangle((0, 0, W - 1, H - 1), radius=26,
                                                 outline=(200, 200, 210), width=2)
        _base.update(mtime=mt, img=img)
    return _base["img"]


# ── LE JOURNAL DU MOBILE ────────────────────────────────────────────────────
def tail_lines(path, n, width):
    op = operator()
    if op["MODE"] == "docker":
        # Un conteneur : son journal docker (la pile y ecrit sur la sortie).
        try:
            data = subprocess.run(["docker", "logs", "--tail", str(n + 5), op["NAME"]],
                                  capture_output=True, text=True, timeout=3)
            data = (data.stdout + data.stderr)
        except Exception as e:
            return [f"{op['NAME']} : journal inaccessible ({type(e).__name__})"]
    else:
        try:
            with open(path, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 16384))
                data = f.read().decode("utf-8", "replace")
        except OSError:
            return [f"{os.path.basename(path)} : pas encore de journal"]
    lines = [ANSI.sub("", l).rstrip() for l in data.splitlines()]
    lines = [l for l in lines if l.strip()]
    out = []
    for l in lines[-n:]:
        # L horodatage osmocom (20260904135215721) mange 17 colonnes pour rien.
        l = re.sub(r"^\d{17}\s+", "", l)
        out.append(l[:width])
    return out or ["(journal vide)"]


# ── LE BANC : SPECTRE A GAUCHE, JOURNAL A DROITE ────────────────────────────
history = []


def render_live(data):
    img = base_image().copy()
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = PAD, PAD, W - PAD, H - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=(8, 10, 14))
    split = x0 + int((x1 - x0) * 0.56)
    # Spectre
    d.text((x0, y0), "Spectre I/Q du mobile  ·  montant (UL)", font=F_TITLE, fill=(88, 166, 255))
    arfcn = data.get("arfcn", "?") if data else "?"
    tag = f"ARFCN {arfcn}"
    d.text((split - 12 - d.textlength(tag, font=F_SMALL), y0 + 2), tag, font=F_SMALL, fill=(63, 185, 80))
    sx0, sx1 = x0, split - 12
    sw = sx1 - sx0
    py0 = y0 + 24
    psd_h = 110
    py1 = py0 + psd_h
    d.rectangle((sx0, py0, sx1, py1), fill=(12, 16, 24))
    for gy in range(1, 4):
        yy = py0 + gy * psd_h // 4
        d.line((sx0, yy, sx1, yy), fill=(24, 30, 40))
    if data and "psd" in data:
        vals = resample(normalize(data["psd"], data.get("dr", 40)), sw)
        pts = [(sx0 + x, py1 - 1 - int(v * (psd_h - 4))) for x, v in enumerate(vals)]
        for x, y in pts:
            d.line((x, y, x, py1 - 1), fill=(30, 70, 110))
        d.line(pts, fill=(88, 210, 255), width=1)
        history.insert(0, vals)
    else:
        d.text((sx0 + 8, py0 + 8), "pas de flux", font=F_SMALL, fill=(248, 81, 73))
    # Chute d eau : une ligne par image, la plus recente en haut
    wy0 = py1 + 4
    wf_h = y1 - wy0
    del history[wf_h:]
    wf = Image.new("RGB", (sw, wf_h), (8, 10, 14))
    px = wf.load()
    for row, line in enumerate(history):
        for x in range(min(sw, len(line))):
            px[x, row] = inferno(line[x])
    img.paste(wf, (sx0, wy0))
    # Journal
    d = ImageDraw.Draw(img)
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    op = operator()
    d.text((lx0, y0), ("mobile.log  ·  QEMU MS#1" if op["MODE"] != "docker"
                       else f"journal  ·  {op['NAME']}"), font=F_TITLE, fill=(88, 166, 255))
    line_h = 15
    n = max(1, (y1 - (y0 + 26)) // line_h)
    cols = max(10, int((x1 - lx0) / 7.3))
    for i, l in enumerate(tail_lines(MOBILE_LOG, n, cols)):
        col = (200, 210, 225)
        if re.search(r"error|fail|reject|lost", l, re.I):
            col = (248, 81, 73)
        elif re.search(r"attach|answer|call|SMS|proceed", l, re.I):
            col = (63, 185, 80)
        d.text((lx0, y0 + 26 + i * line_h), l, font=F_LOG, fill=col)
    # Le pied : une barre sombre d abord, la legende du strip est dessous.
    d.rounded_rectangle((x0 - 6, y1 + 8, x1 + 6, H - PAD + 4), radius=6, fill=(20, 24, 36))
    cap = (f"Operateur {op['OP']}  ·  spectre I/Q du mobile ({op['DASH']}/psd)  ·  "
           + (os.path.basename(MOBILE_LOG) if op["MODE"] != "docker" else "docker logs"))
    d.text((x0, y1 + 12), cap, font=font("DejaVuSansMono.ttf", 13), fill=(160, 170, 190))
    return img


def write(img):
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, ".panel.tmp.png")
    img.save(tmp, "PNG")
    os.replace(tmp, os.path.join(OUT, "panel.png"))


def main():
    print(f"[fft-snap] {URL} + {MOBILE_LOG} -> {OUT}/panel.png toutes les {PERIOD}s "
          f"(fondu {FADE_S}s depuis {WALLPAPER})", flush=True)
    alpha = 0.0
    step = PERIOD / FADE_S if FADE_S > 0 else 1.0
    last_state = None
    while True:
        t = time.time()
        data = None
        try:
            data = fetch("ms")
        except Exception:
            data = None
        ready = bool(data) and "psd" in data
        if ready != last_state:
            print(f"[fft-snap] banc {'pret : fondu vers le spectre' if ready else 'absent : retour au strip'}",
                  flush=True)
            last_state = ready
        target = 1.0 if ready else 0.0
        alpha = min(target, alpha + step) if target > alpha else max(target, alpha - step)
        try:
            if alpha <= 0.0:
                history.clear()
                write(base_image())
            else:
                live = render_live(data)
                write(live if alpha >= 1.0 else Image.blend(base_image(), live, alpha))
        except Exception as e:
            print(f"[fft-snap] rendu : {e}", file=sys.stderr, flush=True)
        time.sleep(max(0.2, PERIOD - (time.time() - t)))


if __name__ == "__main__":
    main()
