#!/usr/bin/env python3
# Fond « Telecom Operator » en bleu : les coups de pinceau orange du fond passent
# en dégradé violet sombre -> bleu clair (selon la luminosité du pixel).
# Restent orange / rouge : le logo ubuntu, OPERATOR, le panneau NO RF barré et le
# schéma téléphones -> BTS -> BSC -> MSC -> Core.
#
# [2026-10-23] Entree : la sortie de tools/osmo-fond-repos.py (2560x1600) ; les
# zones protegees sont en coordonnees de cette image. La chaine devient :
#   tools/osmo-fond-repos.py configs/gsm-lab-source.png /tmp/repos.png
#   tools/osmo-fond-bleu.py /tmp/repos.png /tmp/bleu.png
#   tools/osmo-fond-antenne.py /tmp/bleu.png /tmp/antenne.png
#
# Sans argument : toute la chaine d un coup, depuis configs/gsm-lab-source.png
# jusqu a configs/gsm-lab-ville.jpg et configs/gsm-lab-antenne.jpg.
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
        repos, bleu, antenne = (os.path.join(tmp, n) for n in ("repos.png", "bleu.png", "antenne.png"))
        for script, src, dst in (("osmo-fond-repos.py", os.path.join(configs, "gsm-lab-source.png"), repos),
                                 ("osmo-fond-bleu.py", repos, bleu),
                                 ("osmo-fond-antenne.py", bleu, antenne)):
            subprocess.run([sys.executable, os.path.join(outils, script), src, dst], check=True)
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

# teinte (-180..180 degres) et saturation
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

# poids « orange » : du bordeaux (-70) au jaune orangé (60), pixels saturés
w = np.clip((60 - h) / 15, 0, 1) * np.clip((h + 70) / 30, 0, 1) * np.clip((sat - .25) / .25, 0, 1)

# zones protegees : seuls les pixels vifs (logo, lettres, traits) y sont gardés,
# les coups de pinceau plus sombres derriere passent en bleu comme le reste
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

# dégradé marine -> cyan, suivant la luminosité
# [2026-10-24] etait violet sombre (45, 22, 85) -> bleu clair (120, 195, 255) ; demande : du cyan, un marine plus clair
L = 0.3 * r + 0.59 * g + 0.11 * b
t = np.clip(L / 0.6, 0, 1)[..., None]
MARINE, CYAN = np.array([35, 70, 140]) / 255, np.array([80, 225, 255]) / 255
neuf = (MARINE * (1 - t) + CYAN * t) * (0.55 + 0.45 * np.clip(mx / 0.9, 0, 1))[..., None] * 1.15
out = a * (1 - w[..., None]) + np.clip(neuf, 0, 1) * w[..., None]

# [2026-10-24] TITRE EN UBUNTU SANS. « TELECOM OPERATOR » etait peint au pinceau dans la source : on efface
# les lettres (blanches ou orange, dans le cadre du titre, dilatees pour prendre leur liseré sombre) en
# rebouchant par une convolution normalisee de plus en plus large (pas d OpenCV sur le banc), puis on les
# reecrit plus bas dans la police par defaut d Ubuntu. Le sous-titre « Open Source... » reste tel quel.
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

# [2026-10-24] un peu plus clair : gamma sur tout le fond (les sombres remontent plus que les clairs)
out = np.clip(out, 0, 1) ** float(os.environ.get("OSMO_FOND_GAMMA", "0.82"))
img = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
TITRE_FONTE = "/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf"
ft = ImageFont.truetype(TITRE_FONTE, round(150 * k))
ft.set_variation_by_axes([100, 800])
# les couleurs mesurees sur les lettres peintes : TELECOM blanc casse, OPERATOR orange en degrade vertical
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

# cadre autour du schema : tout tourne en local, sans emission radio. Le titre
# est pose dans une coupure du trait du haut (comme une legende de fieldset).
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
# la coupure doit laisser voir le fond : on efface le trait sous le titre
trou = Image.new("L", img.size, 255)
ImageDraw.Draw(trou).rectangle((tx - round(14 * k), y0 - round(6 * k), tx + tl + round(14 * k), y0 + round(6 * k)), fill=0)
# le coin du portable est DEVANT le cadre : pas de trait sur sa coque
ImageDraw.Draw(trou).polygon([(round(x * k), round(y * k)) for x, y in
                              ((1150, 1312), (1482, 1356), (1505, 1385), (1150, 1395))], fill=0)
calque.putalpha(Image.fromarray(np.minimum(np.asarray(calque.getchannel("A")), np.asarray(trou))))
img.alpha_composite(calque)
ImageDraw.Draw(img).text((tx, y0), titre, font=fonte, fill=ORANGE + (255,), anchor="lm")
img.convert("RGB").save(DST, optimize=True)
print(DST)
