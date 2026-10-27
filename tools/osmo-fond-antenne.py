#!/usr/bin/env python3
# "Bench running" variant of the wallpaper: without the ubuntu|osmocom banner and
# the NO RF sign, to leave room for the banner and Conky. Only the light pixels of
# the logos / sign are erased (the background behind them is dark); they are filled
# with a normalised blur of the dark neighbours, plus a light grain.
#
# Input: the output of tools/osmo-fond-repos.py (2560x1600); the erased areas are
# in the coordinates of that image. See the header of osmo-fond-repos.py for the
# complete chain.
import sys
import numpy as np
from PIL import Image, ImageFilter

SRC, DST = sys.argv[1], sys.argv[2]
im = np.asarray(Image.open(SRC).convert("RGB"), float)
H, W, _ = im.shape
yy, xx = np.mgrid[0:H, 0:W]


def flou(a, s):
    return np.stack([np.asarray(Image.fromarray(np.clip(a[..., c], 0, 255).astype(np.uint8))
                                .filter(ImageFilter.GaussianBlur(s)), float) for c in range(3)], -1)


def flou_m(m, s):
    return np.asarray(Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8))
                      .filter(ImageFilter.GaussianBlur(s)), float) / 255


def dilate(m, n):
    return np.asarray(Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(n))) > 0


lum = im.max(axis=2)
clair = lum > 55

# zone 1: ubuntu | osmocom | GSM...LTE banner - light pixels only
zone = np.zeros((H, W), bool); zone[115:355, 175:1630] = True
trou = dilate(clair & zone, 23)
# zone 2: NO RF sign (disc of the barred circle + text + stroke) - whole area,
# the orange background behind the text cannot be told apart from the stroke
cx, cy, r = 2205, 285, 268
norf = (xx - cx) ** 2 + (yy - cy) ** 2 < r ** 2
norf[475:700, 2045:2415] = True
norf = dilate(norf, 9)

# fill: mean of the neighbouring dark pixels, at several scales
garde = (~trou).astype(float)
rempli = np.zeros_like(im); poids = np.zeros((H, W))
for s, seuil in ((6, .15), (14, .15), (30, .15), (60, .1), (120, .03), (250, 0.003)):
    num = flou(im * garde[..., None], s)
    den = flou_m(garde, s)
    ok = (den > seuil) & (poids == 0)
    rempli[ok] = num[ok] / den[ok][:, None]
    poids[ok] = 1

# NO RF sign: smooth membrane (diffusion from the edge, at 1/8), without the
# steps of the blur scales, then the brush strokes of a 690 px zone on the
# left (banner already erased, city tower avoided), faded towards the bottom
def membrane(img, trou, f=8, n=400):
    h, w = H // f, W // f
    p = np.stack([np.asarray(Image.fromarray(img[..., c].astype(np.uint8)).resize((w, h), Image.BOX), float)
                  for c in range(3)], -1)
    t = np.asarray(Image.fromarray((trou * 255).astype(np.uint8)).resize((w, h), Image.BOX)) > 0
    q = p.copy(); q[t] = p[~t].mean(axis=0)
    for _ in range(n):
        v = (np.roll(q, 1, 0) + np.roll(q, -1, 0) + np.roll(q, 1, 1) + np.roll(q, -1, 1)) / 4
        q[t] = v[t]
    return np.stack([np.asarray(Image.fromarray(np.clip(q[..., c], 0, 255).astype(np.uint8))
                                .resize((W, H), Image.BICUBIC), float) for c in range(3)], -1)

# grain: light noise, blurred by one pixel, so as not to leave a flat area
rng = np.random.default_rng(23)
bruit = rng.normal(0, 5, (H, W))
bruit = np.asarray(Image.fromarray(np.clip(bruit + 128, 0, 255).astype(np.uint8))
                   .filter(ImageFilter.GaussianBlur(0.8)), float) - 128
rempli = rempli + bruit[..., None] * np.array([1.0, 0.6, 1.0])

m = flou_m(trou.astype(float), 3)
m = np.maximum(m, trou)[..., None]
out = im * (1 - m) + rempli * m

lisse = membrane(out, norf)
don = np.roll(out, 690, axis=1)
coups = don - flou(don, 22)
attenue = np.clip((660 - yy) / 80, 0, 1)[..., None]
remp2 = lisse + 0.8 * coups * attenue + bruit[..., None] * np.array([1.0, 0.6, 1.0])
m2 = flou_m(dilate(norf, 21).astype(float), 10)
m2 = np.maximum(m2, norf)[..., None]
out = out * (1 - m2) + remp2 * m2
Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(DST, optimize=True)
print(DST)
