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
# s arrete - /psd rend une erreur au lieu d un spectre - elle revient au strip
# de la meme facon. Une fois le fondu fini, le banc est OPAQUE : le spectre et
# mobile.log doivent se lire, pas se deviner par-dessus un dessin.
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
# Opacite du banc PAR-DESSUS l image du fond, une fois le fondu termine.
#
# [2026-09-04] ESSAYEE A 0.86, REMISE A 1.0. L idee etait de laisser l image du
# jour transparaitre sous le spectre. A l ecran, la bande dessinee traversait le
# journal et le spectre : les traits noirs du dessin passaient entre les lignes
# de mobile.log, et le spectre se lisait sur un fond a motifs. On perdait les
# deux - l image, hachee par le panneau, et le banc, illisible.
# Le fondu, lui, reste : c est LUI qui fait passer de l image au banc et
# retour (FADE_S), et pendant ces trois secondes les deux se superposent.
# OSMO_FFT_OPACITY=0.86 rend l ancien comportement a qui veut l essayer.
OPACITY = max(0.0, min(1.0, float(os.environ.get("OSMO_FFT_OPACITY", "1.0"))))
# Etat ecrit par tools/osmo-wallpaper.sh : y a-t-il un strip dans le fond ?
# Sans reseau, gocomics ne rend pas l image et le fond part SANS strip - le
# cadre est alors vide, et composer le banc en transparence par-dessus du vide
# ne fait que ternir le spectre et le journal. Dans ce cas l encart passe en
# opacite pleine : pas de png, mais le mobile.log et la FFT restent nets.
STRIP_STATE = os.environ.get("OSMO_WP_STATE", "/var/cache/osmo-wallpaper/strip.state")
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
# ── LES COULEURS DU JOURNAL SONT DEJA DANS LE JOURNAL ───────────────────────
# mobile.log est ecrit AVEC ses codes ANSI (osmocom colorie par sous-systeme :
# « \033[0;31m<0004> gsm322.c:... \033[0;m »). L encart les jetait et
# repeignait les lignes au petit bonheur, sur des mots-cles (« error »,
# « call »...) : deux lignes du meme sous-systeme sortaient de couleurs
# differentes, et la lecture ne ressemblait plus du tout a celle du terminal.
# On rend donc la couleur que le journal porte, avec la palette Tango - celle
# du profil gnome-terminal de l image (85-installeur-bureau.sh).
SGR = re.compile(r"\x1b\[([0-9;]*)m")
TANGO = {
    "30": (85, 87, 83),    "31": (204, 0, 0),     "32": (78, 154, 6),
    "33": (196, 160, 0),   "34": (52, 101, 164),  "35": (117, 80, 123),
    "36": (6, 152, 154),   "37": (211, 215, 207),
}
TANGO_VIF = {
    "30": (128, 130, 126), "31": (239, 41, 41),   "32": (138, 226, 52),
    "33": (252, 233, 79),  "34": (114, 159, 207), "35": (173, 127, 168),
    "36": (52, 226, 226),  "37": (238, 238, 236),
}
LOG_DEFAUT = (200, 210, 225)


def couleur_ansi(brut):
    """La couleur que ce terminal donnerait a cette ligne. None si elle n en a pas."""
    for m in SGR.finditer(brut):
        codes = [c for c in m.group(1).split(";") if c]
        if not codes or codes == ["0"]:
            continue                      # remise a zero : pas une couleur
        table = TANGO_VIF if "1" in codes else TANGO
        for c in codes:
            if c in table:
                return table[c]
            if c.startswith("9") and len(c) == 2 and c[1] in "01234567":
                return TANGO_VIF["3" + c[1]]   # 90-97 : les vifs d ECMA-48
    return None


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


_strip = {"mtime": None, "present": True}


def strip_present():
    """Le fond du jour porte-t-il un strip ? (defaut : oui, on ne devine pas)"""
    try:
        mt = os.stat(STRIP_STATE).st_mtime
    except OSError:
        return True
    if mt != _strip["mtime"]:
        val = True
        try:
            with open(STRIP_STATE) as fh:
                for line in fh:
                    k, _, v = line.strip().partition("=")
                    if k == "STRIP":
                        val = v.strip().lower() != "non"
        except OSError:
            pass
        _strip.update(mtime=mt, present=val)
    return _strip["present"]


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
            return [(f"{op['NAME']} : journal inaccessible ({type(e).__name__})", None)]
    else:
        try:
            with open(path, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 16384))
                data = f.read().decode("utf-8", "replace")
        except OSError:
            return [(f"{os.path.basename(path)} : pas encore de journal", None)]
    # On garde la ligne BRUTE le temps d en lire la couleur, puis on la nettoie.
    brutes = [l for l in data.splitlines() if ANSI.sub("", l).strip()]
    out = []
    for brut in brutes[-n:]:
        col = couleur_ansi(brut)
        l = ANSI.sub("", brut).rstrip()
        # L horodatage osmocom (20260904135215721) mange 17 colonnes pour rien.
        l = re.sub(r"^\d{17}\s+", "", l)
        out.append((l[:width], col))
    return out or [("(journal vide)", None)]


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
    for i, (l, col) in enumerate(tail_lines(MOBILE_LOG, n, cols)):
        if col is None:
            # Journal sans couleurs (docker logs, redirection qui les a
            # mangees) : on retombe sur la lecture par mots-cles.
            col = LOG_DEFAUT
            if re.search(r"error|fail|reject|lost", l, re.I):
                col = TANGO_VIF["31"]
            elif re.search(r"attach|answer|call|SMS|proceed", l, re.I):
                col = TANGO_VIF["32"]
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
                # TOUJOURS un blend, meme a fondu termine : c est ce qui laisse
                # le strip transparaitre sous le banc. Sans strip derriere, rien
                # a laisser voir : opacite pleine.
                op = OPACITY if strip_present() else 1.0
                write(Image.blend(base_image(), live, alpha * op))
        except Exception as e:
            print(f"[fft-snap] rendu : {e}", file=sys.stderr, flush=True)
        time.sleep(max(0.2, PERIOD - (time.time() - t)))


if __name__ == "__main__":
    main()
