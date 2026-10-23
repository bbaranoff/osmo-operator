#!/usr/bin/env python3
# Variante « banc en marche » du fond : sans le bandeau ubuntu|osmocom ni le NO RF,
# pour laisser la place à la bannière et au Conky. Seuls les pixels clairs des
# logos / du panneau sont effacés (le fond derrière est sombre) ; on les remplit
# par un flou normalisé des voisins sombres, plus un léger grain.
#
# [2026-10-23] Entree : la sortie de tools/osmo-fond-repos.py (2560x1600) ; les
# zones effacees sont en coordonnees de cette image. Voir l en-tete de
# osmo-fond-repos.py pour la chaine complete.
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

# zone 1 : bandeau ubuntu | osmocom | GSM...LTE - seuls les pixels clairs
zone = np.zeros((H, W), bool); zone[115:355, 175:1630] = True
trou = dilate(clair & zone, 23)
# zone 2 : panneau NO RF (disque du cercle barré + texte + trait) - en entier,
# le fond orange derriere le texte ne se distingue pas du trait
cx, cy, r = 2205, 285, 268
norf = (xx - cx) ** 2 + (yy - cy) ** 2 < r ** 2
norf[475:700, 2045:2415] = True
norf = dilate(norf, 9)

# remplissage : moyenne des pixels sombres voisins, à plusieurs échelles
garde = (~trou).astype(float)
rempli = np.zeros_like(im); poids = np.zeros((H, W))
for s, seuil in ((6, .15), (14, .15), (30, .15), (60, .1), (120, .03), (250, 0.003)):
    num = flou(im * garde[..., None], s)
    den = flou_m(garde, s)
    ok = (den > seuil) & (poids == 0)
    rempli[ok] = num[ok] / den[ok][:, None]
    poids[ok] = 1

# panneau NO RF : membrane lisse (diffusion depuis le bord, a 1/8), sans les
# paliers des echelles de flou, puis les coups de pinceau d une zone 690 px a
# gauche (bandeau deja efface, tour de la ville evitee), estompes vers le bas
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

# grain : un bruit léger, flouté d un pixel, pour ne pas laisser d aplat lisse
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
