#!/usr/bin/env python3
# grub-theme-render.py - builds the "osmo" GRUB theme.
#
#     python3 tools/grub-theme-render.py --out /boot/grub/themes/osmo
#
# Like the Plymouth theme (tools/plymouth-render.py): THE THEME IS GENERATED,
# NOT STORED. The drawing is the code; change a colour, rerun the script.
# Called by iso_modules/86-finitions.sh (installed system) and
# iso_modules/90-iso.sh (live menu).
#
# WHAT IS SHOWN (sober): a plain night-blue background with a faint vertical
# gradient; « osmo-operator » at the top, the menu in the middle in a thin
# frame, and two line drawings framing it, in the same muted blue: the MOBILE
# (a Calypso-era handset) on the LEFT, the BTS (a lattice mast with its
# sector antennas) on the RIGHT, each sending waves towards the menu - the
# radio link the bench emulates. The selected entry is a flat bar.
#
# The fonts (.pf2) are made by grub-mkfont (grub-common) from Ubuntu
# (fonts-ubuntu): the same family as the desktop.
import argparse
import os
import subprocess
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = "/usr/share/fonts/truetype/ubuntu"
W, H = 1920, 1080
ORANGE = (255, 140, 40)

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
a = p.parse_args()
os.makedirs(a.out, exist_ok=True)
out = lambda n: os.path.join(a.out, n)


def police(f, t):
    return ImageFont.truetype(os.path.join(FONTS, f), t)


# ── background ───────────────────────────────────────────────────────────────
FOND_HAUT, FOND_BAS = (14, 20, 32), (8, 12, 20)
TRAIT = (92, 128, 168)          # the drawings
ONDE = (92, 128, 168)
fond = Image.new("RGB", (W, H))
dv = ImageDraw.Draw(fond)
for y in range(H):
    t = y / (H - 1)
    dv.line([(0, y), (W, y)], fill=tuple(round(FOND_HAUT[k] * (1 - t) + FOND_BAS[k] * t) for k in range(3)))

# drawn 4x larger, then reduced: smooth lines without antialiasing support
K = 4
calque = Image.new("RGBA", (W * K, H * K), (0, 0, 0, 0))
dc = ImageDraw.Draw(calque)
L = 3 * K                        # line width


def ondes(cx, cy, sens, n=3, r0=46, pas=34, ouverture=38):
    """Arcs centred on (cx, cy), opening towards sens (+1 right, -1 left)."""
    centre = 0 if sens > 0 else 180
    for i in range(n):
        r = (r0 + i * pas) * K
        dc.arc((cx * K - r, cy * K - r, cx * K + r, cy * K + r),
               centre - ouverture, centre + ouverture, fill=ONDE + (255 - 60 * i,), width=L)


# THE MOBILE, left: candybar handset, stub antenna, screen, keypad
mx, my = 250, 560               # centre of the body
bw, bh = 150, 330
x0, y0, x1, y1 = mx - bw // 2, my - bh // 2, mx + bw // 2, my + bh // 2
dc.rounded_rectangle((x0 * K, y0 * K, x1 * K, y1 * K), radius=26 * K, outline=TRAIT, width=L)
dc.rounded_rectangle(((x1 - 40) * K, (y0 - 46) * K, (x1 - 20) * K, (y0 + 4) * K), radius=8 * K,
                     outline=TRAIT, width=L)                                        # antenna
dc.rounded_rectangle(((x0 + 22) * K, (y0 + 34) * K, (x1 - 22) * K, (y0 + 124) * K), radius=8 * K,
                     outline=TRAIT, width=L)                                        # screen
dc.line(((mx - 18) * K, (y0 + 18) * K, (mx + 18) * K, (y0 + 18) * K), fill=TRAIT, width=L)  # earpiece
for j in range(4):                                                                  # keypad 3x4
    for i in range(3):
        kx, ky = x0 + 38 + i * 37, y0 + 158 + j * 36
        dc.rounded_rectangle(((kx - 12) * K, (ky - 9) * K, (kx + 12) * K, (ky + 9) * K),
                             radius=6 * K, outline=TRAIT, width=2 * K)
ondes(x1 - 30, y0 - 46, +1)

# THE BTS, right: lattice mast, three sector antennas, waves to the left
bx, sol, haut = 1670, 860, 300  # axis, ground, top of the mast
demi_bas, demi_haut = 70, 16
gx0, gx1 = bx - demi_bas, bx + demi_bas
hx0, hx1 = bx - demi_haut, bx + demi_haut
dc.line((gx0 * K, sol * K, hx0 * K, haut * K), fill=TRAIT, width=L)
dc.line((gx1 * K, sol * K, hx1 * K, haut * K), fill=TRAIT, width=L)
etages = 6
for e in range(etages + 1):                       # rungs and cross bracing
    t0, t1 = e / etages, (e + 1) / etages
    ya, yb = sol - (sol - haut) * t0, sol - (sol - haut) * t1
    la = demi_bas + (demi_haut - demi_bas) * t0
    lb = demi_bas + (demi_haut - demi_bas) * t1
    dc.line(((bx - la) * K, ya * K, (bx + la) * K, ya * K), fill=TRAIT, width=2 * K)
    if e < etages:
        dc.line(((bx - la) * K, ya * K, (bx + lb) * K, yb * K), fill=TRAIT, width=2 * K)
        dc.line(((bx + la) * K, ya * K, (bx - lb) * K, yb * K), fill=TRAIT, width=2 * K)
dc.line(((gx0 - 40) * K, sol * K, (gx1 + 40) * K, sol * K), fill=TRAIT, width=L)   # ground
for dx in (-44, 0, 44):                           # sector antennas on a head frame
    dc.rounded_rectangle(((bx + dx - 11) * K, (haut - 86) * K, (bx + dx + 11) * K, (haut - 10) * K),
                         radius=5 * K, outline=TRAIT, width=L)
dc.line(((bx - 56) * K, (haut - 4) * K, (bx + 56) * K, (haut - 4) * K), fill=TRAIT, width=L)
ondes(bx - 60, haut - 48, -1)

calque = calque.resize((W, H), Image.LANCZOS)
fond = Image.alpha_composite(fond.convert("RGBA"), calque).convert("RGB")

d = ImageDraw.Draw(fond)
titre = police("Ubuntu-M.ttf", 60)
d.text((W / 2, 150), "osmo-operator", font=titre, fill=(226, 232, 242), anchor="mm")
sous = police("Ubuntu-L.ttf", 26)
d.text((W / 2, 212), "localhost  ·  no radio emission", font=sous, fill=ORANGE, anchor="mm")
fond.save(out("background.png"), optimize=True)


# ── menu panel (9 pieces: menu_*.png) ──────────────────────────────────────
def neuf(prefixe, taille, rayon, remplissage, bord, epais):
    """Draws a rounded rectangle and cuts it into 9 pieces for GRUB."""
    s = taille
    im = Image.new("RGBA", (3 * s, 3 * s), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle((0, 0, 3 * s - 1, 3 * s - 1), radius=rayon,
                                         fill=remplissage, outline=bord, width=epais)
    noms = {"nw": (0, 0), "n": (1, 0), "ne": (2, 0), "w": (0, 1), "c": (1, 1),
            "e": (2, 1), "sw": (0, 2), "s": (1, 2), "se": (2, 2)}
    for nom, (i, j) in noms.items():
        im.crop((i * s, j * s, (i + 1) * s, (j + 1) * s)).save(out("%s_%s.png" % (prefixe, nom)))


neuf("menu", 16, 12, (16, 24, 38, 200), (60, 84, 112, 255), 2)

# ── selected entry (select_w / select_c / select_e): a flat bar ────────────
HS = 44
barre = Image.new("RGBA", (400, HS), (0, 0, 0, 0))
ImageDraw.Draw(barre).rounded_rectangle((0, 0, 399, HS - 1), radius=8, fill=(44, 72, 108, 255))
barre.crop((0, 0, HS // 2, HS)).save(out("select_w.png"))
barre.crop((HS // 2, 0, 400 - HS // 2, HS)).save(out("select_c.png"))
barre.crop((400 - HS // 2, 0, 400, HS)).save(out("select_e.png"))

# ── fonts ────────────────────────────────────────────────────────────────────
# -r: ASCII, Latin-1 and Latin extended A (the accents of the entries), the
# middle dot of the help. -n sets the name: "Osmo Regular 24".
plages = "0x20-0x7E,0xA0-0x17F,0x2022-0x2022"
for fichier, nom, taille in (("Ubuntu-R.ttf", "Osmo", 24), ("Ubuntu-M.ttf", "OsmoM", 22),
                             ("Ubuntu-R.ttf", "Osmo", 18)):
    subprocess.run(["grub-mkfont", "-s", str(taille), "-n", nom, "-r", plages,
                    "-o", out("%s-%d.pf2" % (nom.lower(), taille)), os.path.join(FONTS, fichier)],
                   check=True)

# ── theme.txt ────────────────────────────────────────────────────────────────
theme = """# GENERE par tools/grub-theme-render.py - ne pas modifier a la main.
title-text: ""
desktop-image: "background.png"
desktop-color: "#0b1018"
terminal-font: "Osmo Regular 18"
terminal-box: "menu_*.png"

+ boot_menu {
    left = 27%
    top = 33%
    width = 46%
    height = 42%
    menu_pixmap_style = "menu_*.png"
    item_font = "Osmo Regular 24"
    item_color = "#b8c3d4"
    selected_item_font = "OsmoM Regular 22"
    selected_item_color = "#ffffff"
    selected_item_pixmap_style = "select_*.png"
    item_height = 44
    item_spacing = 8
    item_padding = 18
    icon_width = 0
    icon_height = 0
    item_icon_space = 0
    scrollbar = false
}

+ label {
    id = "__timeout__"
    left = 0
    top = 84%
    width = 100%
    align = "center"
    font = "Osmo Regular 24"
    color = "#ff8c28"
    text = "Démarrage automatique dans %d s"
}

+ label {
    left = 0
    top = 91%
    width = 100%
    align = "center"
    font = "Osmo Regular 18"
    color = "#6f7d92"
    text = "flèches  choisir    •    Entrée  démarrer    •    e  modifier    •    c  console"
}
"""
with open(out("theme.txt"), "w") as f:
    f.write(theme)
print(a.out)
