#!/usr/bin/env python3
# "Telecom Operator" wallpaper in blue: the orange brush strokes of the background
# turn into a dark purple -> light blue gradient (by pixel luminance).
# Kept orange / red: the ubuntu logo, OPERATOR, the barred NO RF sign and the
# phones -> BTS -> BSC -> MSC -> Core diagram.
#
# Input: the output of tools/osmo-fond-repos.py (2560x1600); the protected
# zones are in the coordinates of that image. The chain is:
#   tools/osmo-fond-repos.py configs/gsm-lab-source.png /tmp/repos.png
#   tools/osmo-fond-bleu.py /tmp/repos.png /tmp/bleu.png
#   tools/osmo-fond-antenne.py /tmp/bleu.png /tmp/antenne.png
#
# Without argument: the whole chain at once, from configs/gsm-lab-source.png
# to configs/gsm-lab-ville.jpg and configs/gsm-lab-antenne.jpg.
#
# OSMO_FOND_ORANGE_HAUT=1: the "bench running" variant (the one without the
# NO RF) mixes both, the original orange at the top fading in a gradient into
# the blue towards the bottom. The chain without argument applies it to
# gsm-lab-antenne.jpg only; gsm-lab-ville.jpg (idle) stays blue.
import os
import subprocess
import sys
import tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

if len(sys.argv) == 1:
    outils = os.path.dirname(os.path.abspath(__file__))
    configs = os.path.join(os.path.dirname(outils), "configs")
    with tempfile.TemporaryDirectory() as tmp:
        repos, bleu, mix, antenne = (os.path.join(tmp, n) for n in ("repos.png", "bleu.png", "mix.png", "antenne.png"))
        for script, src, dst, env in (("osmo-fond-repos.py", os.path.join(configs, "gsm-lab-source.png"), repos, {}),
                                      ("osmo-fond-bleu.py", repos, bleu, {"OSMO_FOND_ORANGE_HAUT": "0"}),
                                      ("osmo-fond-bleu.py", repos, mix, {"OSMO_FOND_ORANGE_HAUT": "1"}),
                                      ("osmo-fond-antenne.py", mix, antenne, {})):
            subprocess.run([sys.executable, os.path.join(outils, script), src, dst], check=True,
                           env={**os.environ, **env})
        for src, nom in ((bleu, "gsm-lab-ville.jpg"), (antenne, "gsm-lab-antenne.jpg")):
            Image.open(src).convert("RGB").save(os.path.join(configs, nom), quality=92)
            print(os.path.join(configs, nom))
    sys.exit(0)
if len(sys.argv) != 3:
    sys.exit("usage : osmo-fond-bleu.py [ENTREE.png SORTIE.png]")

SRC, DST = sys.argv[1], sys.argv[2]
im = Image.open(SRC).convert("RGB")
W, H = im.size
k = W / 2560
a = np.asarray(im, float) / 255
r, g, b = a[..., 0], a[..., 1], a[..., 2]
yy, xx = np.mgrid[0:H, 0:W]

# hue (-180..180 degrees) and saturation
mx, mn = a.max(2), a.min(2)
c = mx - mn
h = np.zeros_like(mx)
nz = c > 1e-6
i = nz & (mx == r); h[i] = ((g - b)[i] / c[i]) % 6
i = nz & (mx == g) & (mx != r); h[i] = (b - r)[i] / c[i] + 2
i = nz & (mx == b) & (mx != r) & (mx != g); h[i] = (r - g)[i] / c[i] + 4
h = h * 60
h = np.where(h > 180, h - 360, h)
sat = np.where(mx > 0, c / np.maximum(mx, 1e-6), 0)

# "orange" weight: from burgundy (-70) to orange-yellow (60), saturated pixels
w = np.clip((60 - h) / 15, 0, 1) * np.clip((h + 70) / 30, 0, 1) * np.clip((sat - .25) / .25, 0, 1)

# protected zones: only the vivid pixels (logo, letters, strokes) are kept there,
# the darker brush strokes behind turn blue like the rest
P = np.zeros((H, W))
for x0, y0, x1, y1 in [(192, 128, 380, 310),      # logo ubuntu
                       (200, 470, 1060, 720),     # OPERATOR
                       (2045, 475, 2415, 700),    # NO RF + trait
                       (1320, 1075, 1660, 1305),  # schema : telephones + BTS
                       (1660, 1130, 2440, 1335)]: # schema : BSC / MSC / Core (pas le reflet au-dessus)
    P[int(y0 * k):int(y1 * k), int(x0 * k):int(x1 * k)] = 1
P[(xx - 2205 * k) ** 2 + (yy - 285 * k) ** 2 < (268 * k) ** 2] = 1   # cercle barré
vif = ((mx > .62) & (sat > .5)).astype(np.uint8) * 255
vif = np.asarray(Image.fromarray(vif).filter(ImageFilter.MaxFilter(5)), float) / 255
P = np.asarray(Image.fromarray((P * vif * 255).astype(np.uint8))
               .filter(ImageFilter.GaussianBlur(2 * k)), float) / 255
w = w * (1 - P)
if os.environ.get("OSMO_FOND_ORANGE_HAUT", "0") == "1":
        # pure orange on the first fifth, smoothstep fade down to 3/5: blue below
    u = np.clip((yy / H - 0.2) / 0.4, 0, 1)
    w = w * (u * u * (3 - 2 * u))

# navy -> cyan gradient, following the luminance
# (a lighter navy and some cyan rather than dark purple -> light blue)
L = 0.3 * r + 0.59 * g + 0.11 * b
t = np.clip(L / 0.6, 0, 1)[..., None]
MARINE, CYAN = np.array([35, 70, 140]) / 255, np.array([80, 225, 255]) / 255
neuf = (MARINE * (1 - t) + CYAN * t) * (0.55 + 0.45 * np.clip(mx / 0.9, 0, 1))[..., None] * 1.15
out = a * (1 - w[..., None]) + np.clip(neuf, 0, 1) * w[..., None]

# TITLE IN UBUNTU SANS. "TELECOM OPERATOR" is brush painted in the source: the
# letters (white or orange, inside the title frame, dilated to take their dark
# outline) are erased by filling with a wider and wider normalised convolution
# (no OpenCV on the bench), then rewritten lower in the default Ubuntu font.
X0, Y0, X1, Y1 = (round(v * k) for v in (160, 375, 1065, 708))
L = 0.3 * out[..., 0] + 0.59 * out[..., 1] + 0.11 * out[..., 2]
omx, omn = out.max(2), out.min(2)
osat = np.where(omx > 0, (omx - omn) / np.maximum(omx, 1e-6), 0)
lettre = np.zeros((H, W), bool)
lettre[Y0:Y1, X0:X1] = (((L > .38) & (osat < .45)) |
                        ((out[..., 0] > .45) & (out[..., 0] > out[..., 1] * 1.3) & (osat > .4)))[Y0:Y1, X0:X1]
M = np.asarray(Image.fromarray((lettre * 255).astype(np.uint8))
               .filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MaxFilter(5))) > 127
connu = (~M).astype(float)
for rayon in (2, 4, 8, 16, 32, 64):
    num = np.asarray(Image.fromarray((np.clip(out * connu[..., None], 0, 1) * 255).astype(np.uint8))
                     .filter(ImageFilter.GaussianBlur(rayon * k)), float) / 255
    den = np.asarray(Image.fromarray((connu * 255).astype(np.uint8))
                     .filter(ImageFilter.GaussianBlur(rayon * k)), float) / 255
    sel = M & (den > .02) & (connu < .5)
    out[sel] = (num / np.maximum(den[..., None], 1e-3))[sel]
    connu[sel] = 1

# a bit lighter: gamma on the whole background (darks rise more than lights)
out = np.clip(out, 0, 1) ** float(os.environ.get("OSMO_FOND_GAMMA", "0.82"))
img = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
TITRE_FONTE = "/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf"
ft = ImageFont.truetype(TITRE_FONTE, round(150 * k))
ft.set_variation_by_axes([100, 800])
# colours measured on the painted letters: TELECOM off-white, OPERATOR orange gradient
def titre_degrade(xy, texte, haut, bas):
    masque = Image.new("L", img.size, 0)
    ImageDraw.Draw(masque).text(xy, texte, font=ft, fill=255, anchor="lt")
    y0_, y1_ = masque.getbbox()[1], masque.getbbox()[3]
    tt = np.clip((np.arange(img.size[1]) - y0_) / max(1, y1_ - y0_), 0, 1)[:, None, None]
    couleur = np.array(haut) * (1 - tt) + np.array(bas) * tt
    couche = Image.fromarray(np.broadcast_to(couleur, (img.size[1], img.size[0], 3)).astype(np.uint8))
    img.paste(couche, (0, 0), masque)
titre_degrade((round(200 * k), round(400 * k)), "TELECOM", (249, 247, 245), (248, 246, 244))
titre_degrade((round(200 * k), round(545 * k)), "OPERATOR", (248, 112, 2), (247, 99, 2))

# frame around the diagram: everything runs locally, no radio emission. The
# title is placed in a gap of the top stroke (like a fieldset legend).
ORANGE = (255, 140, 40)
SANS = "/usr/share/fonts/truetype/ubuntu/Ubuntu[wdth,wght].ttf"
fonte = ImageFont.truetype(SANS, round(30 * k))
fonte.set_variation_by_axes([100, 500])
titre = "localhost  ·  no radio emission"
x0, y0, x1, y1 = (round(v * k) for v in (1300, 1035, 2465, 1345))
calque = Image.new("RGBA", img.size, (0, 0, 0, 0))
d = ImageDraw.Draw(calque)
d.rounded_rectangle((x0, y0, x1, y1), radius=round(18 * k),
                    outline=ORANGE + (235,), width=max(2, round(3 * k)))
tl = d.textlength(titre, font=fonte)
tx = x0 + round(40 * k)
d.rectangle((tx - round(14 * k), y0 - round(6 * k), tx + tl + round(14 * k), y0 + round(6 * k)), fill=(0, 0, 0, 0))
img = img.convert("RGBA")
# the gap must show the background: the stroke under the title is erased
trou = Image.new("L", img.size, 255)
ImageDraw.Draw(trou).rectangle((tx - round(14 * k), y0 - round(6 * k), tx + tl + round(14 * k), y0 + round(6 * k)), fill=0)
# the laptop corner is IN FRONT of the frame: no stroke on its shell
ImageDraw.Draw(trou).polygon([(round(x * k), round(y * k)) for x, y in
                              ((1150, 1312), (1482, 1356), (1505, 1385), (1150, 1395))], fill=0)
calque.putalpha(Image.fromarray(np.minimum(np.asarray(calque.getchannel("A")), np.asarray(trou))))
img.alpha_composite(calque)
ImageDraw.Draw(img).text((tx, y0), titre, font=fonte, fill=ORANGE + (255,), anchor="lm")
img.convert("RGB").save(DST, optimize=True)
print(DST)
