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
# WHAT IS SHOWN:
#   - as background, the city of the wallpaper (configs/gsm-lab-ville.jpg) blurred
#     and darkened, in the same dark purple -> blue gradient;
#   - at the top, "osmo-operator" and, in orange, "localhost · no radio emission"
#     (the frame of the desktop diagram);
#   - in the middle, the menu in a translucent panel with a blue border; the
#     selected entry is a pill in a purple -> blue gradient;
#   - at the bottom, the countdown (orange) and the keyboard help.
#
# The fonts (.pf2) are made by grub-mkfont (grub-common) from Ubuntu
# (fonts-ubuntu): the same family as the desktop.
import argparse
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = "/usr/share/fonts/truetype/ubuntu"
W, H = 1920, 1080
ORANGE = (255, 140, 40)
VIOLET = (58, 30, 110)
BLEU = (70, 150, 245)
BORD = (110, 175, 255)

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--fond", default=os.path.join(REPO, "configs", "gsm-lab-ville.jpg"))
a = p.parse_args()
os.makedirs(a.out, exist_ok=True)
out = lambda n: os.path.join(a.out, n)


def police(f, t):
    return ImageFont.truetype(os.path.join(FONTS, f), t)


# ── background ───────────────────────────────────────────────────────────────
src = Image.open(a.fond).convert("RGB")
r = max(W / src.width, H / src.height)
src = src.resize((round(src.width * r), round(src.height * r)), Image.LANCZOS)
x0, y0 = (src.width - W) // 2, (src.height - H) // 2
fond = src.crop((x0, y0, x0 + W, y0 + H)).filter(ImageFilter.GaussianBlur(30))
# veil: dark purple at the top left -> night blue at the bottom right
voile = Image.new("RGB", (W, H))
dv = ImageDraw.Draw(voile)
for i in range(W + H):
    t = i / (W + H)
    c = (round(22 * (1 - t) + 6 * t), round(8 * (1 - t) + 14 * t), round(44 * (1 - t) + 40 * t))
    dv.line([(i, 0), (i - H, H)], fill=c, width=2)
fond = Image.blend(fond, voile, 0.62)

d = ImageDraw.Draw(fond)
titre = police("Ubuntu-B.ttf", 74)
d.text((W / 2, 150), "osmo-operator", font=titre, fill=(245, 245, 250), anchor="mm")
sous = police("Ubuntu-M.ttf", 30)
d.text((W / 2, 222), "localhost  ·  no radio emission", font=sous, fill=ORANGE, anchor="mm")
lw = d.textlength("localhost  ·  no radio emission", font=sous)
d.line([(W / 2 - lw / 2, 252), (W / 2 + lw / 2, 252)], fill=ORANGE + (255,), width=2)
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


neuf("menu", 24, 22, (12, 8, 30, 175), BORD + (200,), 2)

# ── selected entry (select_w / select_c / select_e): gradient pill ──────────
HS = 44
pastille = Image.new("RGBA", (400, HS), (0, 0, 0, 0))
masque = Image.new("L", (400, HS), 0)
ImageDraw.Draw(masque).rounded_rectangle((0, 0, 399, HS - 1), radius=HS // 2, fill=255)
deg = Image.new("RGBA", (400, HS))
dd = ImageDraw.Draw(deg)
for x in range(400):
    t = x / 399
    dd.line([(x, 0), (x, HS)], fill=tuple(round(VIOLET[k] * (1 - t) + BLEU[k] * t) for k in range(3)) + (235,))
pastille.paste(deg, (0, 0), masque)
pastille.crop((0, 0, HS // 2, HS)).save(out("select_w.png"))
pastille.crop((HS // 2, 0, 400 - HS // 2, HS)).save(out("select_c.png"))
pastille.crop((400 - HS // 2, 0, 400, HS)).save(out("select_e.png"))

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
desktop-color: "#0b0820"
terminal-font: "Osmo Regular 18"
terminal-box: "menu_*.png"

+ boot_menu {
    left = 27%
    top = 33%
    width = 46%
    height = 42%
    menu_pixmap_style = "menu_*.png"
    item_font = "Osmo Regular 24"
    item_color = "#c9cde0"
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
    color = "#8f96b8"
    text = "flèches  choisir    •    Entrée  démarrer    •    e  modifier    •    c  console"
}
"""
with open(out("theme.txt"), "w") as f:
    f.write(theme)
print(a.out)
