#!/usr/bin/env python3
# plymouth-render.py - builds the images of the "osmo-bts" Plymouth theme.
#
#     python3 tools/plymouth-render.py --out configs/plymouth/osmo-bts
#
# THE THEME IS GENERATED, NOT STORED. A Plymouth theme is a set of PNGs:
# keeping them in the repository means some thirty binaries that can neither
# be read nor fixed in a diff. Here the drawing IS the code - change a colour,
# rerun the script, and the next ISO inherits it. iso_modules/86-finitions.sh
# calls it at build time.
#
# WHAT IS SHOWN AT BOOT (pure 2D):
#
#                        (  (  ( • )  )  )
#                               /|\
#                              / | \         a stylised antenna in the middle,
#                             /__|__\        thin circles opening from
#                                            its top
#                            LAB GSM
#                 ━━━━━━━━━━ (bar) ━━━━━━━━━━
#
#   A flat background, a single antenna in thick rounded strokes, and
#   concentric circles with a sharp stroke that open and fade out.
#
# --gif FILE also writes an animated preview (background + 24 frames, reduced),
# for the wiki or to judge the rendering without rebooting. It does NOT go in
# --out: everything in the theme folder goes into the initrd.
#
# Depends only on Pillow and the DejaVu fonts, like wallpaper-render.py.
import argparse
import math
import os

from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
BG_TOP, BG_BOT = (8, 12, 26), (16, 26, 52)
CYAN, GREEN, VIOLET, GREY = (88, 166, 255), (63, 185, 80), (166, 122, 255), (139, 148, 158)
NEON = (64, 224, 255)            # the cyan of the rings: vivid, like a neon
FRAMES = 24


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


def background():
    """FLAT night blue background (pure 2D, no vertical gradient)."""
    return Image.new("RGB", (W, H), BG_TOP)


def mast(d, cx, top_y, h, col=(200, 210, 225)):
    """The antenna, in pure 2D: a mast, two legs and two cross bars, thick
    strokes with round ends, and a bright dot at the top (where the waves start)."""
    w, lw = h * 0.26, 7
    foot = top_y + h
    def seg(a, b):
        d.line([a, b], fill=col, width=lw)
        for x, y in (a, b):
            d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=col)
    seg((cx, top_y + 18), (cx, foot))
    seg((cx, top_y + 30), (cx - w, foot))
    seg((cx, top_y + 30), (cx + w, foot))
    for t in (0.55, 0.82):                       # cross bars between the legs
        y = top_y + 30 + (foot - top_y - 30) * t
        dx = w * t
        seg((cx - dx, y), (cx + dx, y))
    r = 10
    d.ellipse([cx - r, top_y - r, cx + r, top_y + r], fill=NEON)
    return (cx, top_y)


def ripples(d, at, phase, rmax=300, n=4, col=NEON):
    """The waves, in pure 2D: concentric CIRCLES centred on the antenna, which
    open and fade out as they move away. A single sharp stroke per circle: no
    perspective ellipse, cone, halo or light core."""
    x, y = at
    for k in range(n):
        t = ((phase + k / n) % 1.0)
        r = 28 + t * rmax
        a = int(255 * (1 - t) ** 0.9)
        d.ellipse([x - r, y - r, x + r, y + r], outline=(col[0], col[1], col[2], a), width=4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--template", default=None,
                    help="le gabarit osmo-bts.script (defaut : celui du depot)")
    ap.add_argument("--gif", default=None,
                    help="ecrit aussi un apercu anime (GIF) a ce chemin")
    ap.add_argument("--gif-width", type=int, default=960,
                    help="largeur de l apercu GIF (defaut 960)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    bg = background()
    d = ImageDraw.Draw(bg)
    ant = mast(d, W // 2, int(H * 0.36), int(H * 0.25))
    f_title, f_sub = font("DejaVuSans-Bold.ttf", 64), font("DejaVuSansMono.ttf", 24)
    d.text((W / 2, 900), "LAB GSM", font=f_title, fill=(230, 237, 243), anchor="mm")
    d.text((W / 2, 952), "reseau 2G complet, sans materiel  ·  osmocom  ·  calypso emule",
           font=f_sub, fill=GREY, anchor="mm")
    bg.save(os.path.join(a.out, "background.png"), "PNG", optimize=True)

    # The frames: only the BAND between the two antennas, in RGBA. Plymouth
    # draws them over the background - one image per frame rather than a
    # complete background redrawn 24 times (24 x 1.3 MB would not fit well in
    # an initrd). The band encloses the WHOLE circles (maximum radius + stroke):
    # a circle is never cut by its edge. Outside the strokes it is transparent,
    # hence light in the initrd.
    R, M = 230, 12
    bx0, bx1 = ant[0] - 28 - R - M, ant[0] + 28 + R + M
    strip_y = ant[1] - 28 - R - M
    strip_h = 2 * (28 + R + M)
    tip = (ant[0] - bx0, ant[1] - strip_y)                 # the top of the antenna, in the band
    frames = []
    for i in range(FRAMES):
        t = i / FRAMES
        im = Image.new("RGBA", (int(bx1 - bx0), strip_h), (0, 0, 0, 0))
        dd = ImageDraw.Draw(im)
        # the waves, and nothing else
        ripples(dd, tip, t, rmax=R, n=3)
        im.save(os.path.join(a.out, "burst-%02d.png" % i), "PNG", optimize=True)
        frames.append(im)

    # The animated preview: the background, the band drawn over it in place, one
    # image per frame, at ~12 fps as in the theme (one frame every 4 passes at
    # 50 Hz). Reduced: a 1920x1080 GIF of 24 images weighs several MB for
    # nothing.
    if a.gif:
        gw = max(160, a.gif_width)
        gh = int(H * gw / W)
        seq = []
        for im in frames:
            full = bg.convert("RGBA")
            full.alpha_composite(im, (int(bx0), int(strip_y)))
            seq.append(full.convert("RGB").resize((gw, gh), Image.LANCZOS)
                       .quantize(colors=128, method=Image.Quantize.MEDIANCUT))
        seq[0].save(a.gif, save_all=True, append_images=seq[1:], loop=0,
                    duration=int(1000 * 4 / 50), optimize=True)
        print("[plymouth] apercu : %s (%dx%d, %d images)" % (a.gif, gw, gh, FRAMES))

    # The progress bar: a background and a dot running over it.
    bar = Image.new("RGBA", (520, 8), (255, 255, 255, 0))
    ImageDraw.Draw(bar).rounded_rectangle([0, 0, 519, 7], 4, fill=(38, 48, 76, 255))
    bar.save(os.path.join(a.out, "progress-box.png"), "PNG")
    dot = Image.new("RGBA", (64, 8), (0, 0, 0, 0))
    ImageDraw.Draw(dot).rounded_rectangle([0, 0, 63, 7], 4, fill=CYAN + (255,))
    dot.save(os.path.join(a.out, "progress-bar.png"), "PNG")
    # The LUKS passphrase entry field (theme script: it has to be drawn here).
    # Without these two images, an encrypted installation asks for its
    # passphrase on an empty screen.
    ent = Image.new("RGBA", (620, 56), (0, 0, 0, 0))
    ImageDraw.Draw(ent).rounded_rectangle([0, 0, 619, 55], 10, fill=(18, 26, 48, 235),
                                          outline=CYAN + (170,), width=2)
    ent.save(os.path.join(a.out, "entry.png"), "PNG")
    bul = Image.new("RGBA", (18, 18), (0, 0, 0, 0))
    ImageDraw.Draw(bul).ellipse([0, 0, 17, 17], fill=(230, 237, 243, 255))
    bul.save(os.path.join(a.out, "bullet.png"), "PNG")
    # ── THE SCRIPT IS WRITTEN FROM HERE TOO ─────────────────────────────────
    # It needs to know WHERE the band between the two antennas is; these
    # numbers were just computed above. Copying them by hand into the .script
    # would guarantee they diverge at the first adjustment.
    tpl = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "configs", "plymouth", "osmo-bts", "osmo-bts.script")
    tpl = a.template or os.path.normpath(tpl)
    if os.path.isfile(tpl):
        with open(tpl, encoding="utf-8") as f:
            sc = f.read()
        for k, v in (("@@BX@@", bx0 / W), ("@@BY@@", strip_y / H),
                     ("@@BW@@", (bx1 - bx0) / W), ("@@BH@@", strip_h / H)):
            sc = sc.replace(k, "%.4f" % v)
        with open(os.path.join(a.out, "osmo-bts.script"), "w", encoding="utf-8") as f:
            f.write(sc)
        print("[plymouth] script : bande a x=%.3f y=%.3f  %.3f x %.3f (fractions d ecran)"
              % (bx0 / W, strip_y / H, (bx1 - bx0) / W, strip_h / H))
    else:
        print("[plymouth] gabarit %s introuvable - script NON regenere" % tpl)
    print("[plymouth] %s : fond + %d frames + barre + saisie" % (a.out, FRAMES))


if __name__ == "__main__":
    main()
