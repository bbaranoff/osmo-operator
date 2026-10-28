#!/usr/bin/env python3
# paysage-render.py - ONE scene, TWO images: the bench wallpaper and the
# illustration of the central inset, cropped out of it.
#
#   python3 tools/paysage-render.py [--scale 2] \
#       --fond configs/gsm-lab-fond.jpg --encart configs/gsm-lab-wallpaper.jpg
#
# Both images come from the SAME drawing, so the inset does not look like a
# hole in the wallpaper:
#
#   - the WALLPAPER is the whole scene, in 16:9 (3840x2160 at --scale 2): a
#     low-poly landscape in the manner of the Ubuntu wallpaper "Province of the
#     south of France" (Delaunay triangulation over a smooth painting, flat
#     facets), with the bench subject: three pylons, the sun, the hills;
#   - the INSET is the exact crop of the box (510,220 .. 1410,1010) of the
#     1920x1080 frame in that scene. osmo-launcher.py / osmo-panel.py place the
#     inset window at that box, projected on the screen with the SAME
#     transformation GNOME applies to the wallpaper in "zoom" mode: the inset
#     image therefore lands pixel for pixel on the wallpaper it covers, whatever
#     the screen. osmo-fft-snap.py fits it "whole" into W x H: since it already
#     has that aspect ratio, no bands.
#
# The composition is designed for the bench screen: the big tree on the left,
# behind the dock and the icons; the village and the cypresses on the right,
# behind the (translucent) conky; the pylons and the sun INSIDE the inset box;
# the foot of the image (fields) under the launcher bar.
#
# Depends only on Pillow, numpy and scipy (Delaunay), present on the ISO image
# as on the host. Deterministic rendering (fixed seed).

import argparse
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.spatial import Delaunay

FW, FH = 1920, 1080               # the reference frame (tools/osmo-launcher.py)
BOX = (510, 220, 1410, 1010)      # the inset (osmo-fft-snap.py: BOX)

# ── THE PALETTE (that of the "Province" wallpaper, measured) ─────────────────
P = {
    "ciel_haut": (62, 140, 155), "ciel_bas": (138, 184, 186),
    "horizon": (226, 214, 176), "soleil": (252, 238, 160), "halo": (238, 200, 96),
    "nuage": (234, 228, 210), "nuage_clair": (244, 240, 228), "nuage_ombre": (196, 196, 184),
    "nuage_bleu": (166, 188, 190),
    "lointain": (112, 152, 156), "lointain2": (92, 134, 138),
    "colline": (122, 142, 76), "colline2": (150, 164, 88), "colline3": (96, 118, 66),
    "ocre": (214, 168, 70), "ble": (230, 196, 92), "orange": (216, 124, 52),
    "rouge": (176, 84, 44), "brun": (108, 48, 36), "olive": (142, 150, 70),
    "vert": (104, 130, 60), "vert_sombre": (62, 86, 52), "route": (232, 222, 190),
    "feuille": (74, 104, 60), "feuille2": (108, 134, 64), "feuille3": (44, 66, 44),
    "feuille_rouge": (110, 42, 30), "tronc": (70, 40, 30), "tronc2": (38, 24, 20),
    "cypres": (50, 70, 48), "cypres2": (32, 46, 34),
    "mur": (226, 200, 140), "mur_ombre": (190, 160, 100), "toit": (178, 96, 54),
    "pylone": (34, 42, 48), "pylone2": (58, 70, 78), "parabole": (236, 236, 228),
}


# LESS COLOUR, MORE RAW. The palette above is the bold one of the "Province"
# wallpaper; behind the dark panels of the bench it is pulled towards its grey
# (SATURATION: 1.0 = as is, 0 = grey) and darkened slightly; the facets are
# larger and more uneven.
SATURATION = 0.55
SOMBRE = 0.93


def rabattre(c):
    lum = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
    return tuple(int(max(0, min(255, (lum + (v - lum) * SATURATION) * SOMBRE))) for v in c)


P = {k: rabattre(v) for k, v in P.items()}


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def shade(c, k):
    return tuple(max(0, min(255, int(round(v * k)))) for v in c)


# ── THE LANDSCAPE LINES (in 1920x1080 frame coordinates) ─────────────────────
def ligne(x, base, amp, freqs, phase=0.0):
    """A soft silhouette: sum of sines."""
    y = base
    for i, (a, f) in enumerate(zip(amp, freqs)):
        y += a * math.sin(f * x / FW * 2 * math.pi + phase + i * 1.7)
    return y


HORIZON = 640.0
LIGNES = {
    # name: (function y(x), colour)
    "lointain": (lambda x: ligne(x, 612, (46, 20, 7), (1.3, 3.1, 7.0), 0.4), P["lointain"]),
    "lointain2": (lambda x: ligne(x, 648, (30, 12, 5), (2.2, 4.3, 9.0), 3.6), P["lointain2"]),
    "colline": (lambda x: ligne(x, 690, (40, 16, 6), (0.9, 2.6, 6.0), 1.2), P["colline"]),
    "colline2": (lambda x: ligne(x, 735, (30, 14, 5), (1.1, 3.4, 8.0), 3.3), P["colline2"]),
    "colline3": (lambda x: ligne(x, 770, (24, 10, 4), (1.4, 2.9, 7.5), 0.9), P["colline3"]),
    "ocre": (lambda x: ligne(x, 820, (26, 10, 4), (0.8, 2.2, 5.0), 2.6), P["ocre"]),
    "ble": (lambda x: ligne(x, 870, (20, 8, 4), (1.2, 3.0, 6.5), 1.5), P["ble"]),
    "orange": (lambda x: ligne(x, 925, (24, 10, 4), (0.7, 2.4, 5.5), 4.0), P["orange"]),
    "rouge": (lambda x: ligne(x, 985, (18, 8, 4), (1.0, 2.8, 6.0), 0.2), P["rouge"]),
    "brun": (lambda x: ligne(x, 1040, (14, 6, 3), (1.3, 3.2, 7.0), 2.9), P["brun"]),
}
ORDRE = ["lointain", "lointain2", "colline", "colline2", "colline3",
         "ocre", "ble", "orange", "rouge", "brun"]


def bande_polygone(f, s, pas=24):
    """The polygon (scale s) under line f, down to the bottom of the frame."""
    pts = [(x * s, f(x) * s) for x in range(-40, FW + 41, pas)]
    return pts + [((FW + 40) * s, (FH + 40) * s), (-40 * s, (FH + 40) * s)]


# ── THE SMOOTH PAINTING (what the triangulation will facet) ──────────────────
def ciel(w, h, s):
    """Sky gradient, warm towards the horizon, and the sun halo."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    t = np.clip(yy / (HORIZON * s), 0, 1)[..., None]
    haut = np.array(P["ciel_haut"], np.float32)
    bas = np.array(P["ciel_bas"], np.float32)
    hor = np.array(P["horizon"], np.float32)
    img = haut + (bas - haut) * np.clip(t / 0.75, 0, 1)
    th = np.clip((t - 0.62) / 0.38, 0, 1) ** 1.6
    img = img + (hor - img) * th
    # the halo: a low sun, at the centre of the inset
    sx, sy, r = SOLEIL
    d = np.sqrt(((xx - sx * s) ** 2) + ((yy - sy * s) ** 2) * 1.35) / (r * s)
    halo = np.exp(-(d / 3.0) ** 2)[..., None] * 0.6
    halo += np.exp(-(d / 1.35) ** 2)[..., None] * 0.45
    img = img + (np.array(P["halo"], np.float32) - img) * np.clip(halo, 0, 1)
    return img


SOLEIL = (935, 548, 82)           # centre x, centre y, radius (1920x1080 frame)


def nuages(rng, s):
    """Flat clouds, in stretched banks, like paper cut-outs."""
    out = []
    bancs = [(230, 140, 640, 70), (1520, 110, 560, 64), (860, 190, 460, 52),
             (1250, 290, 360, 40), (470, 320, 420, 44), (1720, 350, 300, 32),
             (1020, 400, 260, 26), (320, 450, 260, 22), (1480, 450, 220, 18)]
    for (cx, cy, lw, lh) in bancs:
        for k in range(2):
            pts = []
            n = rng.randint(7, 10)
            ox, oy = rng.uniform(-lw * 0.2, lw * 0.2), rng.uniform(-lh * 0.3, lh * 0.3) - k * lh * 0.18
            for i in range(n):
                a = 2 * math.pi * i / n
                rx = lw * (0.5 - 0.14 * k) * rng.uniform(0.8, 1.05)
                ry = lh * (0.5 - 0.1 * k) * rng.uniform(0.7, 1.15)
                pts.append(((cx + ox + rx * math.cos(a)) * s, (cy + oy + ry * math.sin(a)) * s))
            c = [P["nuage"], P["nuage_clair"]][k]
            out.append((pts, c))
        # a bluish shadow under the bank
        pts = [((cx + lw * 0.45 * math.cos(a) - lw * 0.08) * s, (cy + lh * 0.55 + lh * 0.22 * math.sin(a)) * s)
               for a in np.linspace(0, 2 * math.pi, 7, endpoint=False)]
        out.insert(len(out) - 2, (pts, P["nuage_bleu"]))
    return out


def peinture(w, h, s, rng):
    img = Image.fromarray(np.clip(ciel(w, h, s), 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    nuag = nuages(rng, s)
    for pts, c in nuag:
        d.polygon(pts, fill=c)
    # the sun disc (faceted later, then redrawn sharp on top)
    sx, sy, r = SOLEIL
    d.ellipse((sx * s - r * s, sy * s - r * s, sx * s + r * s, sy * s + r * s), fill=P["soleil"])
    for nom in ORDRE:
        f, c = LIGNES[nom]
        d.polygon(bande_polygone(f, s), fill=c)
    # a light road winding from the bottom up to the village, on the right
    route = [(1130, 1100), (1200, 1010), (1340, 930), (1500, 860), (1620, 790), (1700, 740), (1740, 712)]
    larg = [40, 32, 26, 18, 12, 8, 5]
    gauche, droite = [], []
    for i, (x, y) in enumerate(route):
        xp, yp = route[max(0, i - 1)]
        xn, yn = route[min(len(route) - 1, i + 1)]
        dx, dy = xn - xp, yn - yp
        n = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / n, dx / n          # the normal
        gauche.append(((x + nx * larg[i]) * s, (y + ny * larg[i]) * s))
        droite.append(((x - nx * larg[i]) * s, (y - ny * larg[i]) * s))
    d.polygon(gauche + droite[::-1], fill=P["route"])
    # patches of green and olive in the fields (distant groves, hedges)
    for (cx, cy, rw, rh, c) in [(260, 790, 90, 18, P["vert"]), (1180, 760, 120, 14, P["vert_sombre"]),
                                (640, 805, 70, 12, P["olive"]), (1800, 700, 90, 16, P["vert"]),
                                (120, 905, 160, 30, P["olive"]), (480, 940, 120, 22, P["vert_sombre"]),
                                (1950, 870, 140, 28, P["olive"]), (80, 1010, 130, 26, P["vert_sombre"])]:
        pts = [((cx + rw * math.cos(a) * rng.uniform(0.8, 1.1)) * s,
                (cy + rh * math.sin(a) * rng.uniform(0.7, 1.2)) * s)
               for a in np.linspace(0, 2 * math.pi, 8, endpoint=False)]
        d.polygon(pts, fill=c)
    return img, nuag


# ── THE POINTS, THEN THE FACETS ──────────────────────────────────────────────
def points_scene(w, h, s, rng, nuag):
    pts = []
    # an irregular scatter: wide in the sky, tight in the fields
    y = 0.0
    while y < FH + 60:
        pas = 210 if y < 520 else (96 if y < 800 else 78)
        x = -40.0
        while x < FW + 60:
            pts.append(((x + rng.uniform(-0.6, 0.6) * pas) * s, (y + rng.uniform(-0.6, 0.6) * pas) * s))
            x += pas
        y += pas * 0.85
    # the silhouettes: points along each line, so that the facets stop
    # sharply there (a ridge stays a ridge)
    for nom in ORDRE:
        f, _ = LIGNES[nom]
        x = -40.0
        while x < FW + 40:
            pts.append((x * s, f(x) * s))
            x += rng.uniform(34, 64)
    # the outline of the clouds and the sun
    for poly, _ in nuag:
        pts.extend(poly)
    sx, sy, r = SOLEIL
    for a in np.linspace(0, 2 * math.pi, 14, endpoint=False):
        pts.append(((sx + r * math.cos(a)) * s, (sy + r * math.sin(a)) * s))
    for a in np.linspace(0, 2 * math.pi, 9, endpoint=False):
        pts.append(((sx + 2.2 * r * math.cos(a)) * s, (sy + 1.6 * r * math.sin(a)) * s))
    # the corners
    pts += [(-60 * s, -60 * s), ((FW + 60) * s, -60 * s), (-60 * s, (FH + 60) * s), ((FW + 60) * s, (FH + 60) * s)]
    return np.array(pts, np.float64)


def facettes(peint, pts, rng):
    """Each Delaunay triangle takes the average colour of the painting
    under it, slightly varied: the flat facets of the low-poly."""
    arr = np.asarray(peint).astype(np.float32)
    h, w = arr.shape[:2]
    tri = Delaunay(pts)
    out = Image.new("RGB", (w, h), P["ciel_haut"])
    d = ImageDraw.Draw(out)
    # barycentric sampling points (inside the triangle)
    bary = np.array([(1 / 3, 1 / 3, 1 / 3), (0.6, 0.2, 0.2), (0.2, 0.6, 0.2), (0.2, 0.2, 0.6),
                     (0.45, 0.45, 0.1), (0.1, 0.45, 0.45), (0.45, 0.1, 0.45)], np.float32)
    for simplex in tri.simplices:
        p = pts[simplex]
        samp = bary @ p
        xs = np.clip(samp[:, 0], 0, w - 1).astype(int)
        ys = np.clip(samp[:, 1], 0, h - 1).astype(int)
        cols = arr[ys, xs]
        # the median rather than the mean: a triangle straddling a ridge takes
        # the colour of the side that fills it, not a grey mix
        c = np.median(cols, axis=0)
        k = rng.uniform(0.90, 1.10)
        c = np.clip(c * k, 0, 255).astype(int)
        d.polygon([tuple(q) for q in p], fill=tuple(int(v) for v in c))
    return out


# ── THE SUBJECTS, SHARP, ON TOP ──────────────────────────────────────────────
def pylone(d, s, x, base, haut, larg, deck=False, paraboles=(), antennes=True):
    """A lattice pylon: two uprights that narrow, cross braces, a platform
    and dishes for the big one."""
    c, c2 = P["pylone"], P["pylone2"]
    ht = base - haut
    n = max(6, int(ht / 42))
    pts_g, pts_d = [], []
    for i in range(n + 1):
        t = i / n
        y = base - ht * t
        lw = larg * (1 - 0.82 * t) + 2
        pts_g.append((x - lw, y))
        pts_d.append((x + lw, y))
    lw_px = max(2, int(2.2 * s))
    # uprights
    d.line([(px * s, py * s) for px, py in pts_g], fill=c, width=lw_px)
    d.line([(px * s, py * s) for px, py in pts_d], fill=c, width=lw_px)
    # X braces and landings
    for i in range(n):
        (gx0, gy0), (gx1, gy1) = pts_g[i], pts_g[i + 1]
        (dx0, dy0), (dx1, dy1) = pts_d[i], pts_d[i + 1]
        d.line([(gx0 * s, gy0 * s), (dx1 * s, dy1 * s)], fill=c2, width=max(1, int(1.1 * s)))
        d.line([(dx0 * s, dy0 * s), (gx1 * s, gy1 * s)], fill=c2, width=max(1, int(1.1 * s)))
        d.line([(gx0 * s, gy0 * s), (dx0 * s, dy0 * s)], fill=c, width=max(1, int(1.3 * s)))
    # the foot: a polygonal base
    d.polygon([((x - larg - 6) * s, base * s), ((x + larg + 6) * s, base * s),
               ((x + larg + 2) * s, (base - 10) * s), ((x - larg - 2) * s, (base - 10) * s)], fill=c)
    if deck:
        y = haut + ht * 0.30
        d.polygon([((x - larg * 1.5) * s, y * s), ((x + larg * 1.5) * s, y * s),
                   ((x + larg * 1.15) * s, (y - 22) * s), ((x - larg * 1.15) * s, (y - 22) * s)], fill=c)
        d.polygon([((x - larg * 1.3) * s, (y - 22) * s), ((x + larg * 1.3) * s, (y - 22) * s),
                   ((x + larg * 0.8) * s, (y - 36) * s), ((x - larg * 0.8) * s, (y - 36) * s)], fill=c2)
        d.polygon([((x - larg * 1.5) * s, y * s), ((x + larg * 1.5) * s, y * s),
                   ((x + larg * 0.9) * s, (y + 24) * s), ((x - larg * 0.9) * s, (y + 24) * s)], fill=c2)
    for (dy, cote, r) in paraboles:
        y = haut + ht * dy
        lw = larg * (1 - 0.82 * (base - y) / ht) + 2
        cx = x + cote * (lw + r * 0.7)
        d.ellipse(((cx - r * 0.55) * s, (y - r) * s, (cx + r * 0.55) * s, (y + r) * s), fill=P["parabole"])
        d.ellipse(((cx - r * 0.25) * s, (y - r * 0.85) * s, (cx + r * 0.35) * s, (y + r * 0.85) * s), fill=(214, 214, 206))
    if antennes:
        # the mast at the top
        d.line([(x * s, haut * s), (x * s, (haut - ht * 0.14) * s)], fill=c, width=max(1, int(1.6 * s)))
        d.polygon([((x - 3) * s, (haut - ht * 0.14) * s), ((x + 3) * s, (haut - ht * 0.14) * s),
                   (x * s, (haut - ht * 0.21) * s)], fill=c)
        for k in (0.04, 0.09):
            y = haut + ht * k
            d.line([((x - 9) * s, y * s), ((x + 9) * s, y * s)], fill=c, width=max(1, int(1.3 * s)))
            d.rectangle(((x - 11) * s, (y - 5) * s, (x - 8) * s, (y + 5) * s), fill=c)
            d.rectangle(((x + 8) * s, (y - 5) * s, (x + 11) * s, (y + 5) * s), fill=c)


def arbre(d, s, rng, x, base, hauteur, envergure):
    """The big tree on the left: twisted trunk, branches, foliage in shards."""
    tx = x
    # trunk in several tilting segments
    seg = [(tx, base), (tx + 10, base - hauteur * 0.25), (tx - 8, base - hauteur * 0.5),
           (tx + 14, base - hauteur * 0.7), (tx + 2, base - hauteur * 0.86)]
    larg = [34, 26, 20, 15, 10]
    for i in range(len(seg) - 1):
        (x0, y0), (x1, y1) = seg[i], seg[i + 1]
        l0, l1 = larg[i], larg[i + 1]
        d.polygon([((x0 - l0) * s, y0 * s), ((x0 + l0) * s, y0 * s), ((x1 + l1) * s, y1 * s), ((x1 - l1) * s, y1 * s)],
                  fill=P["tronc"])
        d.polygon([((x0 - l0) * s, y0 * s), ((x0 - l0 * 0.3) * s, y0 * s), ((x1 - l1 * 0.3) * s, y1 * s), ((x1 - l1) * s, y1 * s)],
                  fill=P["tronc2"])
    # the roots
    d.polygon([((tx - 60) * s, base * s), ((tx + 70) * s, base * s), ((tx + 30) * s, (base - 24) * s), ((tx - 28) * s, (base - 26) * s)],
              fill=P["tronc"])
    # branches
    branches = [((tx - 4, base - hauteur * 0.55), (tx - 120, base - hauteur * 0.78), 9),
                ((tx + 8, base - hauteur * 0.68), (tx + 150, base - hauteur * 0.9), 8),
                ((tx + 2, base - hauteur * 0.84), (tx - 70, base - hauteur * 1.02), 6),
                ((tx + 2, base - hauteur * 0.86), (tx + 60, base - hauteur * 1.05), 6),
                ((tx - 120, base - hauteur * 0.78), (tx - 210, base - hauteur * 0.88), 5),
                ((tx + 150, base - hauteur * 0.9), (tx + 260, base - hauteur * 0.98), 5)]
    for (a, b, w) in branches:
        d.line([(a[0] * s, a[1] * s), (b[0] * s, b[1] * s)], fill=P["tronc"], width=int(w * s))
    # foliage: triangular shards around a few centres
    centres = [(tx - 180, base - hauteur * 0.95, 150), (tx + 40, base - hauteur * 1.05, 190),
               (tx + 230, base - hauteur * 1.0, 160), (tx - 60, base - hauteur * 1.15, 130),
               (tx + 120, base - hauteur * 1.2, 120), (tx - 240, base - hauteur * 0.8, 90),
               (tx + 300, base - hauteur * 0.9, 100)]
    couleurs = [P["feuille"], P["feuille2"], P["feuille3"], P["feuille"], P["feuille2"], P["feuille"],
                P["feuille3"], P["feuille_rouge"]]
    for (cx, cy, r) in centres:
        for _ in range(26):
            a = rng.uniform(0, 2 * math.pi)
            rr = r * rng.uniform(0.2, 1.0)
            px, py = cx + rr * math.cos(a), cy + rr * math.sin(a) * 0.75
            n = rng.randint(3, 5)
            size = rng.uniform(28, 70)
            pts = []
            for i in range(n):
                aa = 2 * math.pi * i / n + rng.uniform(-0.3, 0.3)
                pts.append(((px + size * math.cos(aa)) * s, (py + size * 0.8 * math.sin(aa)) * s))
            c = rng.choice(couleurs)
            d.polygon(pts, fill=shade(c, rng.uniform(0.85, 1.12)))


def cypres(d, s, x, base, h, w):
    d.polygon([((x - w) * s, base * s), ((x + w) * s, base * s), ((x + w * 0.6) * s, (base - h * 0.55) * s),
               (x * s, (base - h) * s), ((x - w * 0.6) * s, (base - h * 0.55) * s)], fill=P["cypres"])
    d.polygon([((x - w) * s, base * s), ((x - w * 0.1) * s, base * s), ((x - w * 0.05) * s, (base - h * 0.6) * s),
               (x * s, (base - h) * s), ((x - w * 0.6) * s, (base - h * 0.55) * s)], fill=P["cypres2"])


def maison(d, s, x, base, w, h):
    d.polygon([(x * s, base * s), ((x + w) * s, base * s), ((x + w) * s, (base - h) * s), (x * s, (base - h) * s)], fill=P["mur"])
    d.polygon([((x + w * 0.62) * s, base * s), ((x + w) * s, base * s), ((x + w) * s, (base - h) * s), ((x + w * 0.62) * s, (base - h) * s)],
              fill=P["mur_ombre"])
    d.polygon([((x - w * 0.08) * s, (base - h) * s), ((x + w * 1.08) * s, (base - h) * s),
               ((x + w * 0.95) * s, (base - h * 1.35) * s), ((x + w * 0.05) * s, (base - h * 1.35) * s)], fill=P["toit"])
    d.polygon([((x - w * 0.08) * s, (base - h) * s), ((x + w * 0.5) * s, (base - h) * s),
               ((x + w * 0.45) * s, (base - h * 1.35) * s), ((x + w * 0.05) * s, (base - h * 1.35) * s)], fill=shade(P["toit"], 1.15))
    # windows and door, in shadow
    for fx in (0.14, 0.40):
        d.rectangle(((x + w * fx) * s, (base - h * 0.78) * s, (x + w * (fx + 0.1)) * s, (base - h * 0.55) * s), fill=P["cypres2"])
    d.rectangle(((x + w * 0.27) * s, (base - h * 0.38) * s, (x + w * 0.37) * s, base * s), fill=P["cypres2"])




def dessiner(scale, seed=7, antennes=True):
    rng = random.Random(seed)
    w, h = FW * scale, FH * scale
    peint, nuag = peinture(w, h, scale, rng)
    pts = points_scene(w, h, scale, rng, nuag)
    img = facettes(peint, pts, rng)

    # the sharp sun (a faceted disc), then the land goes back in front
    avant = img.copy()
    s = scale
    d = ImageDraw.Draw(img)
    sx, sy, r = SOLEIL
    d.polygon([((sx + r * math.cos(a)) * s, (sy + r * math.sin(a)) * s)
               for a in np.linspace(0, 2 * math.pi, 11, endpoint=False)], fill=P["soleil"])
    masque = Image.new("L", img.size, 0)
    ImageDraw.Draw(masque).polygon(bande_polygone(LIGNES["lointain"][0], scale), fill=255)
    img.paste(avant, (0, 0), masque)
    # the village on the right (behind the conky), on the "colline" ridge
    fc = LIGNES["colline"][0]
    maison(d, s, 1705, fc(1725) + 6, 84, 42)
    for (x, hh, ww) in [(1660, 120, 10), (1680, 96, 7), (1820, 104, 8)]:
        cypres(d, s, x, fc(x) + 10, hh, ww)
    # THE PYLONS ARE ONLY IN THE INSET. The wallpaper is the bare landscape;
    # the middle window is what plants the antennas in it, within its box -
    # all three are therefore entirely inside BOX (510..1410, 220..1010).
    if antennes:
        fl2 = LIGNES["lointain2"][0]
        pylone(d, s, 592, fl2(592) + 4, 505, 7, antennes=True)
        pylone(d, s, 705, fl2(705) + 6, 420, 11, antennes=True)
        pylone(d, s, 1255, fc(1255) + 2, 330, 30, deck=True,
               paraboles=((0.42, -1, 18), (0.50, 1, 15), (0.60, -1, 12)))
    # the big tree on the left, behind the dock and the icons
    fo = LIGNES["ocre"][0]
    arbre(d, s, rng, 170, fo(170) + 40, 560, 300)
    # tufts of grass at the foot, under the launcher bar
    for _ in range(60):
        x = rng.uniform(-20, FW + 20)
        y = rng.uniform(1030, 1085)
        hh = rng.uniform(10, 26)
        c = shade(P["brun"] if y > 1040 else P["rouge"], rng.uniform(0.7, 0.95))
        d.polygon([((x - 5) * s, y * s), ((x + 5) * s, y * s), ((x + rng.uniform(-6, 6)) * s, (y - hh) * s)], fill=c)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", type=int, default=2, help="2 : fond 3840x2160, encart 1800x1580")
    ap.add_argument("--fond", required=True, help="le fond d ecran GNOME (scene entiere)")
    ap.add_argument("--encart", required=True, help="l illustration de l encart (decoupe BOX)")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    # two renders of the same seed: the bare landscape (wallpaper) and the
    # same with the pylons, of which only the inset box is kept
    img = dessiner(a.scale, a.seed, antennes=False)
    img.save(a.fond, "JPEG", quality=92, optimize=True)
    s = a.scale
    enc = dessiner(a.scale, a.seed, antennes=True).crop((BOX[0] * s, BOX[1] * s, BOX[2] * s, BOX[3] * s))
    enc.save(a.encart, "JPEG", quality=92, optimize=True)
    print(f"fond   : {a.fond} {img.size}")
    print(f"encart : {a.encart} {enc.size} (boite {BOX} x{s})")


if __name__ == "__main__":
    main()
