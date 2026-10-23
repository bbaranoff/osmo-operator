#!/usr/bin/env python3
# Fond « Telecom Operator » : agrandi en 2560x1600, terminal et ligne GSM réécrits nets.
#
# [2026-10-23] Image de depart : configs/gsm-lab-source.png (1586x992, generee par
# IA : texte du terminal invente, ligne « GSM | ... | MSC »). Regenerer le fond au
# repos, puis sa variante « banc en marche » :
#   tools/osmo-fond-repos.py configs/gsm-lab-source.png /tmp/repos.png
#   tools/osmo-fond-antenne.py /tmp/repos.png /tmp/antenne.png
# et poser les deux en JPEG (qualite 92) sous configs/gsm-lab-ville.jpg et
# configs/gsm-lab-antenne.jpg (les noms que lit tools/osmo-fond.py).
# Les coordonnees (ecran du portable, ligne GSM) sont celles de CETTE image source.
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SRC, DST = sys.argv[1], sys.argv[2]
W, H = 2560, 1600
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
MONO_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
SANS = "/usr/share/fonts/truetype/ubuntu/Ubuntu[wdth,wght].ttf"

src = Image.open(SRC).convert("RGB")
sx, sy = W / src.width, H / src.height
up = src.resize((W, H), Image.LANCZOS).filter(ImageFilter.UnsharpMask(2, 60, 2))


def coeffs(dst_pts, src_pts):
    """Coefficients PERSPECTIVE : point de sortie (dst) -> point d entree (src)."""
    A, b = [], []
    for (x, y), (u, v) in zip(dst_pts, src_pts):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return np.linalg.solve(np.array(A, float), np.array(b, float)).tolist()


def efface(img, masque, sigma):
    """Remplit les pixels du masque par un flou normalisé des pixels voisins."""
    a = np.asarray(img, float)
    m = (np.asarray(masque) > 0)
    garde = Image.fromarray(((~m) * 255).astype(np.uint8))
    num = np.stack([np.asarray(Image.fromarray((a[..., c] * ~m).astype(np.uint8))
                               .filter(ImageFilter.GaussianBlur(sigma)), float) for c in range(3)], -1)
    den = np.asarray(garde.filter(ImageFilter.GaussianBlur(sigma)), float)[..., None] / 255
    rempli = num / np.maximum(den, 1e-3)
    a[m] = rempli[m]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


# ── terminal du portable ────────────────────────────────────────────────────
Q = [(184 * sx, 507 * sy), (642 * sx, 521 * sy), (682 * sx, 793 * sy), (218 * sx, 806 * sy)]
FW, FH = 1480, 960
F = [(0, 0), (FW, 0), (FW, FH), (0, FH)]

plat = up.transform((FW, FH), Image.PERSPECTIVE, coeffs(F, Q), Image.BICUBIC)
lum = np.asarray(plat.convert("L"))
masque = (lum > 38).astype(np.uint8) * 255
masque[:80] = 0                                     # garde la barre de titre
masque = Image.fromarray(masque).filter(ImageFilter.MaxFilter(13))
plat = efface(plat, masque, 18)

VERT, BLANC, GRIS = (138, 226, 52), (225, 225, 225), (150, 150, 160)
lignes = [
    [("ubuntu@osmocom:~$ ", VERT, 1), ("systemctl status osmo-bsc", BLANC, 0)],
    [("● ", VERT, 0), ("osmo-bsc.service - Osmocom BSC", BLANC, 0)],
    [("     Loaded: loaded (/lib/systemd/system/osmo-bsc.service; enabled)", BLANC, 0)],
    [("     Active: ", BLANC, 0), ("active (running)", VERT, 1)],
    [("   Main PID: 2483 (osmo-bsc)", BLANC, 0)],
    [("      Tasks: 12 (limit: 2300)", BLANC, 0)],
    [("     Memory: 42.6M", BLANC, 0)],
    [("     CGroup: /system.slice/osmo-bsc.service", BLANC, 0)],
    [("             └─2483 /usr/bin/osmo-bsc", BLANC, 0)],
    [],
    [("ubuntu@osmocom:~$ ", VERT, 1), ("systemctl is-active osmo-bts-virtual", BLANC, 0),
     ("  # NO RF", GRIS, 0)],
    [("active", VERT, 1)],
    [],
    [("ubuntu@osmocom:~$ ", VERT, 1)],
]
fonte = {0: ImageFont.truetype(MONO, 31), 1: ImageFont.truetype(MONO_B, 31)}
calque = Image.new("RGBA", (FW, FH), (0, 0, 0, 0))
d = ImageDraw.Draw(calque)
y = 108
for morceaux in lignes:
    x = 58
    for texte, coul, gras in morceaux:
        d.text((x, y), texte, font=fonte[gras], fill=coul + (255,))
        x += d.textlength(texte, font=fonte[gras])
    if morceaux and morceaux[0][0].startswith("ubuntu@") and len(morceaux) == 1:
        d.rectangle([x + 2, y + 2, x + 18, y + 36], fill=(150, 230, 190, 255))   # curseur
    y += 50
# léger halo, comme un écran éclairé
halo = calque.filter(ImageFilter.GaussianBlur(4))
plat = plat.convert("RGBA")
plat.alpha_composite(Image.eval(halo, lambda v: v // 3))
plat.alpha_composite(calque)

retour = coeffs(Q, F)
colle = plat.transform((W, H), Image.PERSPECTIVE, retour, Image.BICUBIC)
forme = Image.new("L", (FW, FH), 255).transform((W, H), Image.PERSPECTIVE, retour, Image.BICUBIC)
up.paste(colle.convert("RGB"), (0, 0), forme)

# ── ligne « GSM | GPRS | EDGE | LTE » sous le logo osmocom ──────────────────
bx0, by0, bx1, by1 = int(615 * sx), int(176 * sy), int(995 * sx), int(208 * sy)
zone = up.crop((bx0, by0, bx1, by1))
mz = Image.fromarray(((np.asarray(zone.convert("L")) > 42) * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(11))
up.paste(efface(zone, mz, 10), (bx0, by0))

ff = ImageFont.truetype(SANS, 33)
ff.set_variation_by_axes([100, 400])
texte = "GSM   |   GPRS   |   EDGE   |   LTE"
d = ImageDraw.Draw(up)
espace = 4                                          # interlettrage comme l original
largeur = sum(d.textlength(c, font=ff) + espace for c in texte) - espace
x, cy = (bx0 + bx1) / 2 - largeur / 2, (by0 + by1) / 2
for c in texte:
    d.text((x, cy), c, font=ff, fill=(215, 215, 220), anchor="lm")
    x += d.textlength(c, font=ff) + espace

up.save(DST, optimize=True)
print(DST, up.size)
