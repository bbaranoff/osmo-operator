#!/usr/bin/env python3
# plymouth-render.py - fabrique les images du theme Plymouth « osmo-bts ».
#
#     python3 tools/plymouth-render.py --out configs/plymouth/osmo-bts
#
# LE THEME EST GENERE, PAS STOCKE. Un theme Plymouth, ce sont des PNG : les
# garder dans le depot, c est une trentaine de binaires qu on ne peut ni relire
# ni corriger en diff. Ici le dessin EST le code - on change une couleur, on
# rejoue le script, et l ISO suivante en herite. iso_modules/86-finitions.sh
# l appelle au build.
#
# CE QU ON VOIT AU DEMARRAGE ([2026-10-23] plus simple, 2D pure) :
#
#                        (  (  ( • )  )  )
#                               /|\
#                              / | \         une antenne stylisee au centre,
#                             /__|__\        des cercles fins qui s ouvrent
#                                            depuis son sommet
#                            LAB GSM
#                 ━━━━━━━━━━ (barre) ━━━━━━━━━━
#
#   Un fond uni, une seule antenne en traits epais arrondis, et des cercles
#   concentriques a trait net qui s ouvrent et s effacent. Plus de pylone en
#   treillis, de mobile ni d anneaux « 3D » (ellipses en perspective, halo
#   neon) : trop charge, ils se recouvraient.
#
# --gif FICHIER sort en plus un apercu anime (fond + 24 frames, reduit), pour
# le wiki ou pour juger le rendu sans redemarrer. Il ne va PAS dans --out :
# tout ce qui est dans le dossier du theme part dans l initrd.
#
# Ne depend que de Pillow et des polices DejaVu, comme wallpaper-render.py.
import argparse
import math
import os

from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
BG_TOP, BG_BOT = (8, 12, 26), (16, 26, 52)
CYAN, GREEN, VIOLET, GREY = (88, 166, 255), (63, 185, 80), (166, 122, 255), (139, 148, 158)
NEON = (64, 224, 255)            # le cyan des anneaux : vif, comme un neon
FRAMES = 24


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


def background():
    """Fond UNI bleu nuit ([2026-10-23] 2D pure : plus de degrade vertical)."""
    return Image.new("RGB", (W, H), BG_TOP)


def mast(d, cx, top_y, h, col=(200, 210, 225)):
    """L antenne, en 2D pure : un mat, deux jambages et deux traverses, traits
    epais a bouts ronds, et un point lumineux au sommet (d ou partent les ondes)."""
    w, lw = h * 0.26, 7
    foot = top_y + h
    def seg(a, b):
        d.line([a, b], fill=col, width=lw)
        for x, y in (a, b):
            d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=col)
    seg((cx, top_y + 18), (cx, foot))
    seg((cx, top_y + 30), (cx - w, foot))
    seg((cx, top_y + 30), (cx + w, foot))
    for t in (0.55, 0.82):                       # traverses entre les jambages
        y = top_y + 30 + (foot - top_y - 30) * t
        dx = w * t
        seg((cx - dx, y), (cx + dx, y))
    r = 10
    d.ellipse([cx - r, top_y - r, cx + r, top_y + r], fill=NEON)
    return (cx, top_y)


def ripples(d, at, phase, rmax=300, n=4, col=NEON):
    """Les ondes, en 2D pure : des CERCLES concentriques centres sur l antenne,
    qui s ouvrent et s effacent en s eloignant. Un seul trait net par cercle :
    plus d ellipse en perspective, de cone, de halo ni de coeur clair (le
    « neon 3D » du 2026-10-01, retire le 2026-10-23)."""
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

    # Les frames : seulement la BANDE entre les deux antennes, en RGBA. Plymouth
    # les pose par-dessus le fond - une image par frame plutot qu un fond
    # complet redessine 24 fois (24 x 1,3 Mo tiendrait mal dans un initrd).
    # La bande englobe les cercles ENTIERS (rayon maximal + trait) : un cercle
    # n est jamais coupe par son bord. Hors des traits elle est transparente,
    # donc legere dans l initrd.
    R, M = 230, 12
    bx0, bx1 = ant[0] - 28 - R - M, ant[0] + 28 + R + M
    strip_y = ant[1] - 28 - R - M
    strip_h = 2 * (28 + R + M)
    tip = (ant[0] - bx0, ant[1] - strip_y)                 # le sommet de l antenne, dans la bande
    frames = []
    for i in range(FRAMES):
        t = i / FRAMES
        im = Image.new("RGBA", (int(bx1 - bx0), strip_h), (0, 0, 0, 0))
        dd = ImageDraw.Draw(im)
        # les ondes, et rien d autre
        ripples(dd, tip, t, rmax=R, n=3)
        im.save(os.path.join(a.out, "burst-%02d.png" % i), "PNG", optimize=True)
        frames.append(im)

    # L apercu anime : le fond, la bande posee dessus a sa place, une image par
    # frame, a ~12 i/s comme dans le theme (une frame toutes les 4 passes a
    # 50 Hz). Reduit : un GIF 1920x1080 de 24 images pese plusieurs Mo pour
    # rien.
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

    # La barre d avancement : un fond et une pastille qui court dessus.
    bar = Image.new("RGBA", (520, 8), (255, 255, 255, 0))
    ImageDraw.Draw(bar).rounded_rectangle([0, 0, 519, 7], 4, fill=(38, 48, 76, 255))
    bar.save(os.path.join(a.out, "progress-box.png"), "PNG")
    dot = Image.new("RGBA", (64, 8), (0, 0, 0, 0))
    ImageDraw.Draw(dot).rounded_rectangle([0, 0, 63, 7], 4, fill=CYAN + (255,))
    dot.save(os.path.join(a.out, "progress-bar.png"), "PNG")
    # Le champ de saisie de la phrase LUKS (theme script : c est a nous de le
    # dessiner). Sans ces deux images, une installation chiffree demande sa
    # phrase sur un ecran vide.
    ent = Image.new("RGBA", (620, 56), (0, 0, 0, 0))
    ImageDraw.Draw(ent).rounded_rectangle([0, 0, 619, 55], 10, fill=(18, 26, 48, 235),
                                          outline=CYAN + (170,), width=2)
    ent.save(os.path.join(a.out, "entry.png"), "PNG")
    bul = Image.new("RGBA", (18, 18), (0, 0, 0, 0))
    ImageDraw.Draw(bul).ellipse([0, 0, 17, 17], fill=(230, 237, 243, 255))
    bul.save(os.path.join(a.out, "bullet.png"), "PNG")
    # ── LE SCRIPT SORT D ICI AUSSI ──────────────────────────────────────────
    # Il a besoin de savoir OU est la bande entre les deux antennes ; ces
    # nombres viennent d etre calcules ci-dessus. Les recopier a la main dans
    # le .script, c est la garantie qu ils divergeront au premier reglage.
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
