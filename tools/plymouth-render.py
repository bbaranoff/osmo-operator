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
# CE QU ON VOIT AU DEMARRAGE :
#
#     ((( ▲ )))                                     ▄▄▄
#      pylone   ---- burst ---->                   |o o|   <- le mobile
#      (BTS)    <--- burst -----                   |___|
#
#   Un pylone a gauche, un mobile a droite, et une rafale GSM qui fait
#   l aller-retour entre les deux - c est litteralement ce que la machine
#   s apprete a faire tourner. Des anneaux concentriques « 3D » (ellipses en
#   perspective, neon cyan) s ouvrent depuis le pylone et depuis le mobile. En bas, le nom du banc et la barre d avancement.
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
    """Degrade vertical bleu nuit, le meme bleu que le fond d ecran du banc."""
    bg = Image.new("RGB", (W, H), BG_TOP)
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOT)))
    return bg


def tower(d, cx, base_y, h, col=GREY):
    """Un pylone en treillis : deux montants qui se rapprochent, des croix
    entre les deux, et trois petits panneaux d antenne en haut."""
    top_w, bot_w = h * 0.055, h * 0.30
    def edges(t):                      # t = 0 en bas, 1 en haut
        wdt = bot_w + (top_w - bot_w) * t
        y = base_y - h * t
        return (cx - wdt / 2, y), (cx + wdt / 2, y)
    steps = 14
    pts = [edges(i / steps) for i in range(steps + 1)]
    for i in range(steps):
        (l0, r0), (l1, r1) = pts[i], pts[i + 1]
        d.line([l0, l1], fill=col, width=4)
        d.line([r0, r1], fill=col, width=4)
        d.line([l0, r1], fill=col, width=2)     # les croix du treillis
        d.line([r0, l1], fill=col, width=2)
        d.line([l1, r1], fill=col, width=2)
    # Les panneaux d antenne, en haut, ecartes en triangle.
    tx, ty = cx, base_y - h
    for dx in (-38, 0, 38):
        d.rounded_rectangle([tx + dx - 7, ty - 46, tx + dx + 7, ty - 4], 4,
                            fill=(30, 42, 70), outline=CYAN, width=2)
    d.line([(tx, ty - 4), (tx, ty + 20)], fill=col, width=4)
    return (tx, ty - 25)               # le point d ou partent les ondes


def handset(d, cx, cy, hh=210, col=GREY):
    """Un mobile : coque, ecran, touche - et sa petite antenne fouet, parce que
    le banc emule un Calypso, pas un smartphone."""
    hw = hh * 0.46
    box = [cx - hw / 2, cy - hh / 2, cx + hw / 2, cy + hh / 2]
    d.rounded_rectangle(box, 16, fill=(26, 34, 58), outline=col, width=4)
    d.rounded_rectangle([box[0] + 12, box[1] + 16, box[2] - 12, box[1] + hh * 0.46], 6,
                        fill=(14, 40, 30), outline=GREEN, width=2)
    for r in range(3):                 # le clavier
        for c in range(3):
            x = box[0] + 20 + c * (hw - 40) / 2
            y = box[1] + hh * 0.56 + r * (hh * 0.30) / 2
            d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=(40, 52, 80))
    d.line([(cx + hw / 2 - 10, cy - hh / 2), (cx + hw / 2 + 4, cy - hh / 2 - 42)], fill=col, width=5)
    return (cx + hw / 2 + 4, cy - hh / 2 - 46)


def ripples(d, at, phase, rmax=300, n=4, col=NEON, aspect=0.32, cone=0.30):
    """Les ondes « 3D » : des anneaux concentriques POSES A PLAT, vus en
    perspective (ellipses, rapport `aspect`), qui s ouvrent depuis l antenne
    et s effacent en s eloignant. Les grands anneaux descendent un peu
    (`cone`) : empiles, ils dessinent un cone de rayonnement, comme les
    cercles d un radar ou d une balise - c est l image demandee le
    2026-10-01, a la place des trois arcs plats d avant. Chaque anneau porte
    un halo (trait large et pale) sous son trait net : c est lui qui donne
    le « neon » cyan."""
    x, y = at
    for k in range(n):
        t = ((phase + k / n) % 1.0)
        rx = 28 + t * rmax
        ry = rx * aspect
        cy = y + t * rmax * cone
        a = int(255 * (1 - t) ** 0.9)
        box = [x - rx, cy - ry, x + rx, cy + ry]
        d.ellipse(box, outline=(col[0], col[1], col[2], a // 3), width=13)   # halo
        d.ellipse(box, outline=(col[0], col[1], col[2], a), width=5)         # trait
        d.ellipse([x - rx + 1, cy - ry + 1, x + rx - 1, cy + ry - 1],
                  outline=(235, 252, 255, int(a * 0.8)), width=2)            # coeur clair


def burst(d, x, y, t):
    """La rafale qui traverse : huit creneaux (les 8 intervalles de la trame),
    celui qui est « allume » se deplace avec le temps."""
    slot_w, gap, hgt = 16, 5, 30
    total = 8 * slot_w + 7 * gap
    x0 = x - total / 2
    lit = int(t * 8) % 8
    for i in range(8):
        sx = x0 + i * (slot_w + gap)
        col = VIOLET if i == lit else (52, 64, 98)
        d.rectangle([sx, y - hgt / 2, sx + slot_w, y + hgt / 2], fill=col)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--template", default=None,
                    help="le gabarit osmo-bts.script (defaut : celui du depot)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    bg = background()
    d = ImageDraw.Draw(bg)
    ant = tower(d, 470, 760, 470)
    ms = handset(d, 1450, 640)
    f_title, f_sub = font("DejaVuSans-Bold.ttf", 64), font("DejaVuSansMono.ttf", 24)
    d.text((W / 2, 900), "LAB GSM", font=f_title, fill=(230, 237, 243), anchor="mm")
    d.text((W / 2, 952), "reseau 2G complet, sans materiel  ·  osmocom  ·  calypso emule",
           font=f_sub, fill=GREY, anchor="mm")
    bg.save(os.path.join(a.out, "background.png"), "PNG", optimize=True)

    # Les frames : seulement la BANDE entre les deux antennes, en RGBA. Plymouth
    # les pose par-dessus le fond - une image par frame plutot qu un fond
    # complet redessine 24 fois (24 x 1,3 Mo tiendrait mal dans un initrd).
    # La bande part SOUS la pointe du pylone et englobe les anneaux (qui
    # debordent de part et d autre des deux antennes) : les ellipses ne sont
    # jamais coupees par le bord de la bande.
    bx0, bx1 = ant[0] - 360, ms[0] + 220
    strip_y, strip_h = ant[1] - 110, 300
    tip = (ant[0] - bx0, ant[1] - strip_y)                 # la pointe du pylone, dans la bande
    ms_top = (ms[0] - bx0, ms[1] - 95 - strip_y)            # le haut du mobile, dans la bande
    for i in range(FRAMES):
        t = i / FRAMES
        im = Image.new("RGBA", (int(bx1 - bx0), strip_h), (0, 0, 0, 0))
        dd = ImageDraw.Draw(im)
        # Les ondes : grands anneaux depuis le pylone (descendant), petits
        # anneaux depuis le mobile (montant), decales d une demi-periode.
        ripples(dd, tip, t, rmax=340, n=4)
        ripples(dd, ms_top, (t + 0.5) % 1.0, rmax=190, n=3, aspect=0.36)
        # Aller (montant) puis retour (descendant) : une periode complete.
        u = (t * 2) % 1.0
        xa, xb = tip[0] + 90, ms_top[0] - 90
        ya = tip[1] + 40
        if t < 0.5:
            burst(dd, xa + u * (xb - xa), ya, t * 4)
        else:
            burst(dd, xb - u * (xb - xa), ya + 80, t * 4)
        # Le sens, ecrit : UL en haut, DL en bas - c est un banc, pas un ecran
        # de veille.
        dd.text((xa - 34, ya - 26), "DL", font=font("DejaVuSansMono.ttf", 18), fill=CYAN + (150,))
        dd.text((xb + 10, ya + 54), "UL", font=font("DejaVuSansMono.ttf", 18), fill=GREEN + (150,))
        im.save(os.path.join(a.out, "burst-%02d.png" % i), "PNG", optimize=True)

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
