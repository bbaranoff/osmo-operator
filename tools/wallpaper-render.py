#!/usr/bin/env python3
# wallpaper-render.py - compose le fond d ecran du banc (1920x1080).
#
#   python3 wallpaper-render.py --tower configs/wallpaper/tower.jpg \
#           [--strip calvin.gif] [--date 2026-09-04] --out gsm-lab-wallpaper.png
#
# Disposition, pensee pour ne rien faire chevaucher sur l ecran :
#
#   +--------+------------------------------------------+-------------------+
#   | dock + | carte LAB GSM (x 320..1430, y 60..560)  | conky (400 px,    |
#   | icones |                                          | gap 24, y 40..660)|
#   | bureau | strip Calvin & Hobbes (x 320..1430,      |                   |
#   | (haut  |                          y 600..1010)    |                   |
#   | gauche)|                                          |                   |
#   +--------+------------------------------------------+-------------------+
#
# Les deux colonnes de cote ne recoivent que la photo. A gauche (x < 320) : le
# dock GNOME (~70 px) puis les icones du bureau, en haut a gauche (DING,
# start-corner top-left, cases de ~100 px). A droite (x >= 1440) : conky
# (top_right, gap_x 24, 400 px de large, cf. configs/conky/osmo-conky.conf).
#
# Sans --strip (pas de reseau au build, ou au boot), la zone du strip reste
# vide : le fond est complet sans lui. Le strip du jour est pose par
# tools/osmo-wallpaper.sh (service + timer osmo-wallpaper).
#
# Ne depend que de Pillow (python3-pil) et des polices DejaVu (fonts-dejavu),
# presents sur l image comme sur l hote.

import argparse
import datetime
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
FONT_DIR = "/usr/share/fonts/truetype/dejavu"


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_h(w, h, stops):
    """Bande horizontale w x h, degrade entre les couleurs `stops`."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    n = len(stops) - 1
    for x in range(w):
        t = x / max(1, w - 1) * n
        i = min(int(t), n - 1)
        c = lerp(stops[i], stops[i + 1], t - i)
        for y in range(h):
            px[x, y] = c
    return img


def rounded(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def background(tower_path, sun_at=(250, 984)):
    """La photo en fond : le pylone A GAUCHE (colonne des icones et, en
    transparence, le bord gauche de la carte), le soleil en bas a gauche du
    strip Calvin & Hobbes (sun_at, en pixels du fond). La photo, mise a la
    largeur de l ecran, est decalee vers la gauche pour cela ; le vide qui
    s ouvre a droite est comble par le ciel en miroir - c est la colonne du
    conky, un ciel uni suffit. Assombrie au centre (les panneaux) et teintee
    bleu nuit."""
    tower = Image.open(tower_path).convert("RGB")
    tw, th = tower.size
    scale = max(W / tw, H / th)
    tower = tower.resize((int(tw * scale) + 1, int(th * scale) + 1), Image.LANCZOS)
    # Le soleil est vers (480, 600) sur la photo d origine (1170x1123).
    sun_x, sun_y = int(480 * scale), int(600 * scale)
    x0 = max(0, min(sun_x - sun_at[0], tower.width - 1))
    y0 = max(0, min(sun_y - sun_at[1], tower.height - H))
    bg = Image.new("RGB", (W, H))
    part = tower.crop((x0, y0, min(tower.width, x0 + W), y0 + H))
    bg.paste(part, (0, 0))
    gap = W - part.width
    if gap > 0:
        # Miroir du bord droit de la photo (ciel) pour combler jusqu au bord.
        edge = tower.crop((tower.width - gap, y0, tower.width, y0 + H)).transpose(Image.FLIP_LEFT_RIGHT)
        bg.paste(edge, (part.width, 0))
    # Teinte bleu nuit + assombrissement : leger a gauche (le pylone), plus
    # marque sous les panneaux, nul a droite (le conky se detache seul).
    tint = Image.new("RGB", (W, H), (10, 18, 40))
    bg = Image.blend(bg, tint, 0.18)
    mask = gradient_h(W, 1, [(0, 0, 0), (85, 85, 85), (60, 60, 60), (0, 0, 0)]).resize((W, H))
    dark = Image.new("RGB", (W, H), (6, 10, 24))
    bg = Image.composite(dark, bg, mask.convert("L"))
    return bg


def glass_panel(base, box, radius=26, alpha=185, fill=(13, 22, 44), border=(90, 120, 200), blur=14):
    """Panneau translucide, fond legerement flou dessous (verre depoli)."""
    x0, y0, x1, y1 = box
    if blur > 0:
        region = base.crop(box).filter(ImageFilter.GaussianBlur(blur))
        base.paste(region, (x0, y0))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    rounded(d, box, radius, fill=fill + (alpha,), outline=border + (110,), width=2)
    base.paste(Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB"))


def gradient_text(base, xy, text, fnt, stops):
    """Texte rempli d un degrade horizontal."""
    x, y = xy
    l, t, r, b = fnt.getbbox(text)
    w, h = r - l, b - t
    mask = Image.new("L", (w + 4, h + 4), 0)
    ImageDraw.Draw(mask).text((-l + 2, -t + 2), text, font=fnt, fill=255)
    grad = gradient_h(w + 4, h + 4, stops)
    base.paste(grad, (x, y), mask)
    return w, h


def card(base, box, arfcn="514", band="DCS 1800"):
    x0, y0, x1, y1 = box
    # Carte bien transparente : le pylone et le ciel restent visibles derriere
    # le texte (le strip, lui, garde un fond opaque pour rester lisible).
    glass_panel(base, box, alpha=38, blur=0)
    d = ImageDraw.Draw(base)
    pad = 44
    x = x0 + pad
    y = y0 + 34

    # En-tete
    d.ellipse((x, y + 4, x + 14, y + 18), fill=(63, 185, 160))
    d.text((x + 28, y), "SOFTWARE DEFINED RADIO  ·  UM INTERFACE  ·  GR-GSM",
           font=font("DejaVuSansMono.ttf", 15), fill=(150, 170, 210))
    tag = f"ARFCN {arfcn}  ·  {band}"
    tf = font("DejaVuSansMono-Bold.ttf", 15)
    tw = d.textlength(tag, font=tf)
    rounded(d, (x1 - pad - tw - 28, y - 8, x1 - pad, y + 28), 10, outline=(63, 185, 160), width=2)
    d.text((x1 - pad - tw - 14, y), tag, font=tf, fill=(120, 230, 210))

    # Titre
    y += 46
    # Titre en violet uni (pas de degrade).
    tw, th = gradient_text(base, (x - 4, y), "LAB GSM", font("DejaVuSans-Bold.ttf", 86),
                           [(150, 100, 245), (150, 100, 245)])
    d = ImageDraw.Draw(base)
    y += th + 20
    sub = font("DejaVuSans.ttf", 22)
    subb = font("DejaVuSans-Bold.ttf", 22)
    line1 = [("Un réseau 2G complet, ", sub), ("sans matériel", subb),
             (" — baseband ", sub), ("Calypso", subb), (" émulé, cœur ", sub), ("Osmocom", subb), (",", sub)]
    line2 = [("de la synchro radio à l'appel voix chiffré en ", sub), ("A5/1", subb),
             ("  ·  couche 1 ", sub), ("gr-gsm", subb), (" (SDR)", sub)]
    for line in (line1, line2):
        cx = x
        for txt, f in line:
            d.text((cx, y), txt, font=f, fill=(215, 225, 245))
            cx += d.textlength(txt, font=f)
        y += 32

    # Trame TDMA
    y += 14
    d.text((x, y), "TRAME TDMA  ·  8 TIMESLOTS  ·  4,615 MS", font=font("DejaVuSansMono.ttf", 14),
           fill=(150, 170, 210))
    y += 26
    slots = [("TS0", "FCCH·SCH·BCCH"), ("TS1", "SDCCH"), ("TS2", "TCH/F"), ("TS3", "TCH/F"),
             ("TS4", "TCH/F"), ("TS5", "TCH/F"), ("TS6", "PDCH"), ("TS7", "PDCH")]
    inner = (x1 - pad) - x
    gap = 10
    sw = (inner - gap * 7) // 8
    sh = 58
    for i, (name, use) in enumerate(slots):
        sx = x + i * (sw + gap)
        active = i == 0
        rounded(d, (sx, y, sx + sw, y + sh), 8,
                fill=(58, 62, 150) if active else (24, 34, 70),
                outline=(120, 130, 240) if active else (60, 75, 130), width=2)
        nf = font("DejaVuSansMono-Bold.ttf", 16)
        uf = font("DejaVuSansMono.ttf", 11)
        d.text((sx + (sw - d.textlength(name, font=nf)) / 2, y + 12), name, font=nf, fill=(235, 240, 255))
        d.text((sx + (sw - d.textlength(use, font=uf)) / 2, y + 38), use, font=uf,
               fill=(120, 230, 210) if active else (140, 160, 200))
    y += sh + 8
    d.text((x, y), "0 µs", font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    mid = "1 burst = 577 µs"
    d.text((x + inner / 2 - d.textlength(mid, font=font("DejaVuSansMono.ttf", 12)) / 2, y), mid,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    end = "4615 µs"
    d.text((x1 - pad - d.textlength(end, font=font("DejaVuSansMono.ttf", 12)), y), end,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))

    # Normal burst
    y += 24
    d.text((x, y), "NORMAL BURST  ·  156,25 BITS", font=font("DejaVuSansMono.ttf", 14), fill=(150, 170, 210))
    y += 24
    parts = [(3, "tail", (70, 80, 120)), (57, "data", (52, 205, 180)), (1, "", (240, 90, 120)),
             (26, "training", (120, 110, 240)), (1, "", (240, 90, 120)), (57, "data", (52, 205, 180)),
             (3, "tail", (70, 80, 120)), (8.25, "guard", (90, 100, 140))]
    total = sum(p[0] for p in parts)
    bx = x
    bh = 40
    for bits, name, col in parts:
        bw = inner * bits / total
        d.rectangle((bx, y, bx + bw, y + bh), fill=col)
        if name and bw > 40:
            lf = font("DejaVuSansMono-Bold.ttf", 12)
            lbl = f"{bits:g}"
            d.text((bx + (bw - d.textlength(lbl, font=lf)) / 2, y + 6), lbl, font=lf, fill=(10, 20, 40))
            d.text((bx + (bw - d.textlength(name, font=lf)) / 2, y + 22), name, font=lf, fill=(10, 20, 40))
        bx += bw
    y += bh + 12

    # Puces en bas
    chips = [("IMSI 001-01", (150, 170, 210)), ("A5/1 ✓", (120, 230, 210)), ("COMP128v1 ✓", (120, 230, 210)),
             ("TCH/F · GAPK fr", (120, 230, 210)), ("gr-gsm · trxcon · osmo-bts-trx", (150, 170, 210))]
    cf = font("DejaVuSansMono-Bold.ttf", 13)
    cx = x
    for txt, col in chips:
        cw = d.textlength(txt, font=cf) + 22
        rounded(d, (cx, y, cx + cw, y + 28), 8, outline=col, width=1)
        d.text((cx + 11, y + 6), txt, font=cf, fill=col)
        cx += cw + 10
    site = "bbaranoff.github.io"
    sf = font("DejaVuSansMono-Bold.ttf", 14)
    d.text((x1 - pad - d.textlength(site, font=sf), y + 6), site, font=sf, fill=(180, 200, 240))


def strip_panel(base, box, strip_path, date_str):
    """Le strip Calvin & Hobbes du jour, dans un cadre blanc arrondi."""
    x0, y0, x1, y1 = box
    glass_panel(base, box, fill=(20, 24, 36), alpha=210, border=(200, 200, 210))
    d = ImageDraw.Draw(base)
    pad = 18
    foot = 30
    strip = Image.open(strip_path)
    strip.seek(0)
    strip = strip.convert("RGB")
    sw, sh = strip.size
    aw, ah = (x1 - x0) - 2 * pad, (y1 - y0) - 2 * pad - foot
    scale = min(aw / sw, ah / sh)
    strip = strip.resize((int(sw * scale), int(sh * scale)), Image.LANCZOS)
    sx = x0 + pad + (aw - strip.width) // 2
    sy = y0 + pad
    # Cadre blanc derriere le strip (les GIF ont des marges irregulieres).
    d.rounded_rectangle((sx - 6, sy - 6, sx + strip.width + 6, sy + strip.height + 6), radius=8,
                        fill=(255, 255, 255))
    base.paste(strip, (sx, sy))
    d = ImageDraw.Draw(base)
    cap = f"Calvin & Hobbes  ·  Bill Watterson  ·  {date_str}  ·  gocomics.com"
    cf = font("DejaVuSansMono.ttf", 13)
    d.text((x0 + pad, y1 - foot + 6), cap, font=cf, fill=(160, 170, 190))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tower", required=True)
    ap.add_argument("--strip", default=None)
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--out", required=True)
    ap.add_argument("--arfcn", default="514")
    ap.add_argument("--band", default="DCS 1800")
    a = ap.parse_args()

    base = background(a.tower)
    card(base, (320, 60, 1430, 560), a.arfcn, a.band)
    if a.strip and os.path.isfile(a.strip):
        try:
            strip_panel(base, (320, 600, 1430, 1010), a.strip, a.date)
        except Exception as e:  # GIF corrompu, page HTML au lieu d une image...
            print(f"[wallpaper] strip ignore : {e}", file=sys.stderr)
    tmp = a.out + ".tmp.png"
    base.save(tmp, "PNG", optimize=True)
    os.replace(tmp, a.out)
    print(f"[wallpaper] {a.out} ({W}x{H}, strip={'oui' if a.strip and os.path.isfile(a.strip) else 'non'})")


if __name__ == "__main__":
    main()
