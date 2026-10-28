#!/usr/bin/env python3
# wallpaper-render.py - composes the bench wallpaper (1920x1080).
#
#   python3 wallpaper-render.py --tower configs/wallpaper/tower.png \
#           [--strip calvin.gif] [--date 2026-09-04] --out gsm-lab-wallpaper.png
#
# Layout, designed so that nothing overlaps on the screen:
#
#   +--------+------------------------------------------+-------------------+
#   | dock + | LAB GSM card (x 320..1430, y 60..560)    | conky (400 px,    |
#   | desktop|                                          | gap 24, y 40..660)|
#   | icons  | inset (x 510..1410, CENTRED, y 220..1010)|                   |
#   | (top   |   top   : random geek comic / 4G spectrum|                   |
#   | left)  |   bottom: Calvin & Hobbes / 2G spectrum  |                   |
#   +--------+------------------------------------------+-------------------+
#
# The pylon of the photo is in the MIDDLE (see background/TOWER_X): both
# panels are translucent and let it show through.
# The two side columns only receive the photo. On the left (x < 320): the
# GNOME dock (~70 px) then the desktop icons, top left (DING, start-corner
# top-left, ~100 px cells). On the right (x >= 1440): conky (top_right,
# gap_x 24, 400 px wide, cf. configs/conky/osmo-conky.conf).
#
# Without --strip (no network at build time, or at boot), the strip area
# stays empty: the wallpaper is complete without it. The strip of the day is
# placed by tools/osmo-wallpaper.sh (osmo-wallpaper service + timer).
#
# Depends only on Pillow (python3-pil) and the DejaVu fonts (fonts-dejavu),
# present on the image as on the host.

# THE INSET IS CENTRED, IN TWO FRAMES. The box (510, 220, 1410, 1010), i.e.
# 900x790, is CENTRED on the 1920 px (510 + 900/2 = 960) and stops before
# x=1440, where the conky column starts. It is split into two frames of 391 px
# separated by 8 px: the top one carries a randomly drawn geek comic (and the
# srsRAN UE spectrum when it runs), the bottom one Calvin & Hobbes (and the
# 2G spectrum). It overlaps the LAB GSM top zone (osmo-topzone.py,
# y 60..~400): intended, the banner stays a backdrop behind it.
# THE FOUR FILES THAT KNOW THIS BOX MUST STAY IN AGREEMENT:
#   tools/wallpaper-render.py  (the two frames drawn in the wallpaper)
#   tools/osmo-fft-snap.py     (the 900x790 image painted into it)
#   tools/osmo-panel.py        (the clickable GTK window placed on top)
#   tools/osmo-launcher.py     (where an app launched "in the panel" docks)
BOX_HAUT = (510, 220, 1410, 611)
BOX_BAS = (510, 619, 1410, 1010)
import argparse
import datetime
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

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
    """Horizontal band w x h, gradient between the `stops` colours."""
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


# ── ERASING THE PHOTO'S DEFECTS ─────────────────────────────────────────────
# A backlit phone photo carries three marks, obvious once the pylon is in the
# middle and enlarged:
#
#   1. A MAGENTA VEIL. The sun in the lens throws a purplish diagonal halo
#      across the sky - a diaphragm ghost. On a night-blue background it reads
#      as a dirty streak.
#   2. CHROMATIC FRINGING. Dark uprights against a burnt sky take a purple
#      edge (lateral aberration). The sharpening that follows would REINFORCE
#      it: the defect gets sharpened along with the detail.
#   3. JPEG BLOCKING. The sky is a nearly flat gradient: exactly what JPEG
#      renders worst (8x8 squares and bands). Enlargement spreads them into
#      visible plates.
#
# Three targeted corrections, in this order - and BEFORE sharpening, otherwise
# what is about to be erased gets sharpened first.
#
# OSMO_WP_CLEAN=1 enables them (off by default, see below).
def nettoyer_photo(im):
    """Magenta defringing + sky smoothing, without touching the lattice."""
    # DEFAULT: DO NOTHING. This cleanup suits a backlit phone photo with flare,
    # fringing and JPEG blocking. The current photo is clean, and above all it
    # is PINK: a sunset sky, where green legitimately sits below the mean of
    # red and blue over half the image. The magenta correction would see a
    # defect everywhere and REPAINT THE SKY grey. The code stays, documented:
    # OSMO_WP_CLEAN=1 turns it on for a photo that needs it.
    if os.environ.get("OSMO_WP_CLEAN", "0") != "1":
        return im

    # ── 1 and 2. THE MAGENTA, VEIL AND FRINGES, IN ONE GESTURE ──────────────
    # A sky has R < G < B. The flare halo and the fringing share the same
    # signature: GREEN falls below the mean of red and blue (the definition
    # of magenta). Green is therefore raised up to that mean wherever it sits
    # below it. Nothing in the scene (sky and steel) is legitimately magenta,
    # so nothing legitimate is touched. A one-pass correction, no mask to tune.
    r, g, b = im.split()
    moy = ImageChops.add(r.point(lambda v: v // 2), b.point(lambda v: v // 2))
    g = ImageChops.lighter(g, moy)
    im = Image.merge("RGB", (r, g, b))

    # ── 3. THE SKY SMOOTHED, THE LATTICE INTACT ─────────────────────────────
    # The whole image cannot be blurred: the pylon would lose what the
    # sharpening gives it right after. So a DETAIL mask is built - the
    # difference between the image and its blurred version, i.e. the edges -
    # widened (MaxFilter) to cover the borders, then softened so that the
    # transition does not show. The blur is applied only WHERE THERE IS NO
    # DETAIL: the sky, and the sky alone.
    flou = im.filter(ImageFilter.GaussianBlur(2.2))
    gris = im.convert("L")
    ecart = ImageChops.difference(gris, gris.filter(ImageFilter.GaussianBlur(2.2)))
    masque = ecart.point(lambda v: 255 if v > 4 else 0)
    masque = masque.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.6))
    return Image.composite(im, flou, masque)


# ── WHERE THE PYLON LANDS ON THE SCREEN ─────────────────────────────────────
# The photo is anchored on the PYLON, not on the sun: the mast column of the
# source photo (TOWER_SRC) is brought to TOWER_X (0.62: between the LAB GSM
# card and the conky column - the exact centre, 0.5, would enlarge the photo
# too much and push the sun out of frame). The panels placed there are
# translucent, so the pylon reads through them.
#
# THE SCALE IS DERIVED FROM THE WANTED POSITION, not simply "cover the
# screen": the smallest scale that puts the pylon in place WITHOUT a gap on
# either side. The mirrored edge below is only a safety net for a photo with
# a different framing.
# x of the mast, and reference size of configs/wallpaper/tower.jpg.
# The mast sits at 34.2 % of the width, measured by looking for the most
# STRUCTURED column of the central band (sum of image-minus-blur detail,
# column by column). The ratio is what matters: background() rescales it to
# the real file size, so replacing the photo only requires this line.
# The photo is used AS IS, in PNG, at its native resolution (5824x3264): the
# render DOWNSCALES it anyway (scale ~0.57 to place the mast), and downscaling
# from full resolution gives a better result than downscaling twice.
TOWER_SRC = (1992, 5824, 3264)
TOWER_X = float(os.environ.get("OSMO_WP_TOWER_X", "0.62"))


def background(tower_path, tower_x=None, sun_y_at=984):
    """The photo as background: the pylon IN THE MIDDLE (tower_x, fraction of
    the screen width; TOWER_X by default). Darkened at the centre (the panels
    sit on top) and tinted night blue."""
    tower = nettoyer_photo(Image.open(tower_path).convert("RGB"))
    tw, th = tower.size
    src_x, ref_w, _ref_h = TOWER_SRC
    # The mast reference follows the real file size: a photo replaced by
    # another of the same framing stays correct.
    src_x = src_x * tw / ref_w
    target = (TOWER_X if tower_x is None else tower_x) * W
    # Three constraints: cover the height, and overflow neither left nor
    # right once the mast is brought to `target`.
    scale = max(H / th,
                target / max(src_x, 1),
                (W - target) / max(tw - src_x, 1))
    tower = tower.resize((int(tw * scale) + 1, int(th * scale) + 1), Image.LANCZOS)
    # ── SHARPENING THE PYLON ────────────────────────────────────────────────
    # The pylon is a dark silhouette against a bright sky; three gestures, in
    # this order, and not one more:
    #   1. a wide, soft unsharp mask: it gives back the edge of the uprights
    #      and the braces without digging into the grain of the sky;
    #   2. the contrast, slightly: the silhouette stands out from the halo;
    #   3. the sharpness, a hair: the cables and the antenna panels.
    # Applied BEFORE the tint and the darkening: sharpening afterwards would
    # sharpen a blue veil, not the photo.
    #
    # The three values scale with OSMO_WP_SHARPEN (0 disables them): on
    # another photo, or a very dense screen, the right dose is not the same,
    # and an over-sharpened image is worse than a soft one. The default 0.45
    # is a light touch: the photo is DOWNSCALED by the render, and downscaling
    # already sharpens; a stronger value gives halos on the guy wires and a
    # grainy sky.
    _shp = float(os.environ.get("OSMO_WP_SHARPEN", "0.45"))
    if _shp > 0:
        tower = tower.filter(ImageFilter.UnsharpMask(radius=2.4 * _shp,
                                                    percent=int(135 * _shp), threshold=3))
        tower = ImageEnhance.Contrast(tower).enhance(1 + 0.16 * _shp)
        tower = ImageEnhance.Sharpness(tower).enhance(1 + 0.35 * _shp)
    x0 = int(round(src_x * scale - target))
    x0 = max(0, min(x0, tower.width - W))
    # Vertically, the sun stays where it was: bottom left of the strip.
    sun_y = int(600 * scale * th / _ref_h)
    y0 = max(0, min(sun_y - sun_y_at, tower.height - H))
    bg = Image.new("RGB", (W, H))
    part = tower.crop((x0, y0, min(tower.width, x0 + W), y0 + H))
    bg.paste(part, (0, 0))
    gap = W - part.width
    if gap > 0:
        # Should not happen (the scale is computed for it), but a photo with
        # another framing could force it: mirror of the edge, flat sky.
        edge = tower.crop((tower.width - gap, y0, tower.width, y0 + H)).transpose(Image.FLIP_LEFT_RIGHT)
        bg.paste(edge, (part.width, 0))
    # Night-blue tint + darkening: the pylon is at the centre, hence UNDER
    # both panels - they are translucent, it must show through without
    # turning the text grey. Hence a soft (70), symmetric darkening at the
    # centre.
    tint = Image.new("RGB", (W, H), (10, 18, 40))
    bg = Image.blend(bg, tint, 0.18)
    mask = gradient_h(W, 1, [(0, 0, 0), (70, 70, 70), (70, 70, 70), (0, 0, 0)]).resize((W, H))
    dark = Image.new("RGB", (W, H), (6, 10, 24))
    bg = Image.composite(dark, bg, mask.convert("L"))
    return bg


def glass_panel(base, box, radius=26, alpha=185, fill=(13, 22, 44), border=(90, 120, 200), blur=14):
    """Translucent panel, slightly blurred background underneath (frosted glass)."""
    x0, y0, x1, y1 = box
    if blur > 0:
        region = base.crop(box).filter(ImageFilter.GaussianBlur(blur))
        base.paste(region, (x0, y0))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    rounded(d, box, radius, fill=fill + (alpha,), outline=border + (110,), width=2)
    base.paste(Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB"))


def gradient_text(base, xy, text, fnt, stops):
    """Text filled with a horizontal gradient."""
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
    # Very transparent card: the pylon and the sky stay visible behind the
    # text (the strip, on the other hand, keeps an opaque background to stay
    # readable).
    glass_panel(base, box, alpha=38, blur=0)
    d = ImageDraw.Draw(base)
    pad = 44
    x = x0 + pad
    y = y0 + 34

    # Header
    d.ellipse((x, y + 4, x + 14, y + 18), fill=(63, 185, 160))
    d.text((x + 28, y), "SOFTWARE DEFINED RADIO  ·  UM INTERFACE  ·  GR-GSM",
           font=font("DejaVuSansMono.ttf", 15), fill=(150, 170, 210))
    tag = f"ARFCN {arfcn}  ·  {band}"
    tf = font("DejaVuSansMono-Bold.ttf", 15)
    tw = d.textlength(tag, font=tf)
    rounded(d, (x1 - pad - tw - 28, y - 8, x1 - pad, y + 28), 10, outline=(63, 185, 160), width=2)
    d.text((x1 - pad - tw - 14, y), tag, font=tf, fill=(120, 230, 210))

    # Title
    y += 46
    # Title in plain purple (no gradient).
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

    # TDMA frame
    y += 14
    d.text((x, y), "TRAME TDMA  ·  8 TIMESLOTS  ·  4,615 MS", font=font("DejaVuSansMono.ttf", 14),
           fill=(150, 170, 210))
    y += 26
    slots = [("TS0", "FCCH·SCH·BCCH"), ("TS1", "SDCCH"), ("TS2", "TCH/F"), ("TS3", "TCH/F"),
             ("TS4", "TCH/F"), ("TS5", "TCH/F"), ("TS6", "PDCH"), ("TS7", "PDCH")]
    inner = (x1 - pad) - x
    gap = 10
    sw = (inner - gap * 7) // 8
    # TALL CELLS, NOT WIDE - same gesture as in the live banner
    # (configs/conky/labgsm.html): the width (sw, computed from the card) is
    # fixed; only sh is tall, and the text keeps its size, vertically centred
    # in the cell.
    sh = 148
    for i, (name, use) in enumerate(slots):
        sx = x + i * (sw + gap)
        active = i == 0
        rounded(d, (sx, y, sx + sw, y + sh), 10,
                fill=(58, 62, 150) if active else (24, 34, 70),
                outline=(120, 130, 240) if active else (60, 75, 130), width=2)
        nf = font("DejaVuSansMono-Bold.ttf", 16)
        uf = font("DejaVuSansMono.ttf", 11)
        cy = y + sh / 2
        d.text((sx + (sw - d.textlength(name, font=nf)) / 2, cy - 24), name, font=nf, fill=(235, 240, 255))
        d.text((sx + (sw - d.textlength(use, font=uf)) / 2, cy + 2), use, font=uf,
               fill=(120, 230, 210) if active else (140, 160, 200))
    y += sh + 8
    d.text((x, y), "0 µs", font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    mid = "1 burst = 577 µs"
    d.text((x + inner / 2 - d.textlength(mid, font=font("DejaVuSansMono.ttf", 12)) / 2, y), mid,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    end = "4615 µs"
    d.text((x1 - pad - d.textlength(end, font=font("DejaVuSansMono.ttf", 12)), y), end,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))

    y += 22

    # Chips at the bottom
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


def strip_panel(base, box, strip_path, date_str, credit=None):
    """The image of the day, in a rounded white frame.

    `credit` is the footer line: it NAMES the source. osmo-wallpaper.sh draws
    the source at random, so the caption must come from the caller; the
    Calvin & Hobbes caption is only the default.
    """
    x0, y0, x1, y1 = box
    glass_panel(base, box, fill=(20, 24, 36), alpha=210, border=(200, 200, 210))
    d = ImageDraw.Draw(base)
    pad = 18
    # ── NO SOURCE LINE IN THE FRAME BY DEFAULT ──────────────────────────────
    # The footer would sit UNDER the inset's button bar (Dashboard / tmux /
    # VTY, plus the arrows), which lives exactly there, and this frame is the
    # BENCH INSET: as soon as the stack comes up it carries a spectrum and a
    # log, where a photo credit makes no sense. The image therefore fills the
    # whole frame. OSMO_WP_CREDIT=1 adds the line back.
    foot = 30 if os.environ.get("OSMO_WP_CREDIT") == "1" else 0
    strip = Image.open(strip_path)
    strip.seek(0)
    strip = strip.convert("RGB")
    sw, sh = strip.size
    aw, ah = (x1 - x0) - 2 * pad, (y1 - y0) - 2 * pad - foot
    scale = min(aw / sw, ah / sh)
    strip = strip.resize((int(sw * scale), int(sh * scale)), Image.LANCZOS)
    sx = x0 + pad + (aw - strip.width) // 2
    sy = y0 + pad
    # White frame behind the strip (GIFs have irregular margins).
    d.rounded_rectangle((sx - 6, sy - 6, sx + strip.width + 6, sy + strip.height + 6), radius=8,
                        fill=(255, 255, 255))
    base.paste(strip, (sx, sy))
    if foot == 0:
        return
    d = ImageDraw.Draw(base)
    cap = credit or f"Calvin & Hobbes  ·  Bill Watterson  ·  {date_str}  ·  gocomics.com"
    cf = font("DejaVuSansMono.ttf", 13)
    # ── THE CAPTION MUST NOT LEAVE THE FRAME ────────────────────────────────
    # The live inset (osmo-fft-snap.py) covers exactly the frame and nothing
    # more, so anything overflowing would stay visible beside the spectrum.
    # Cut at the usable width, with an ellipsis. Measure then truncate, rather
    # than guessing a number of characters: the font is monospaced here, but
    # the caption may contain accents and symbols.
    avail = (x1 - x0) - 2 * pad
    if d.textlength(cap, font=cf) > avail:
        while cap and d.textlength(cap + "...", font=cf) > avail:
            cap = cap[:-1]
        cap = cap.rstrip(" ·") + "..."
    d.text((x0 + pad, y1 - foot + 6), cap, font=cf, fill=(160, 170, 190))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tower", required=True)
    ap.add_argument("--strip", default=None, help="l image du cadre du BAS (Calvin & Hobbes)")
    ap.add_argument("--strip-haut", default=None, help="l image du cadre du HAUT (la BD geek)")
    ap.add_argument("--credit-haut", default=None)
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--credit", default=None,
                    help="ligne de pied sous l image (source, auteur). "
                         "Defaut : la legende Calvin & Hobbes.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--arfcn", default="514")
    ap.add_argument("--band", default="DCS 1800")
    ap.add_argument("--tower-x", type=float, default=None,
                    help="ou poser le pylone, en fraction de la largeur d ecran "
                         "(0.5 = milieu, le defaut ; 0.17 = l ancien calage a gauche)")
    a = ap.parse_args()

    base = background(a.tower, a.tower_x)
    # THE LAB GSM CARD IS NOT BAKED INTO THE WALLPAPER BY DEFAULT.
    # tools/osmo-topzone.py (live WebKit widget) renders it, with the blinking
    # timeslots and the live ARFCN/IMSI/A5 values; a card painted here as well
    # would show twice behind the live one. OSMO_LEGACY_BANNER=1 bakes the
    # static card for a standalone wallpaper (a bench without the live desktop).
    if os.environ.get("OSMO_LEGACY_BANNER", "0") == "1":
        card(base, (320, 60, 1430, 560), a.arfcn, a.band)
    # Two frames, two images. A frame without an image is still drawn (empty):
    # the spectrum will cover it, and empty it says "nothing to show here".
    poses = {}
    for nom, box, chemin, credit in (("bas", BOX_BAS, a.strip, a.credit),
                                     ("haut", BOX_HAUT, a.strip_haut, a.credit_haut)):
        poses[nom] = False
        if chemin and os.path.isfile(chemin):
            try:
                strip_panel(base, box, chemin, a.date, credit)
                poses[nom] = True
            except Exception as e:  # corrupt GIF, HTML page instead of an image...
                print(f"[wallpaper] image du {nom} ignoree : {e}", file=sys.stderr)
        else:
            glass_panel(base, box, fill=(20, 24, 36), alpha=210, border=(200, 200, 210))
    tmp = a.out + ".tmp.png"
    base.save(tmp, "PNG", optimize=True)
    os.replace(tmp, a.out)
    print(f"[wallpaper] {a.out} ({W}x{H}, bas={'oui' if poses['bas'] else 'non'}, "
          f"haut={'oui' if poses['haut'] else 'non'})")


if __name__ == "__main__":
    main()
