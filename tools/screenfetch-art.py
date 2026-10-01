#!/usr/bin/env python3
# screenfetch-art.py - ecrit configs/screenfetch/osmo-lab.sh : le logo en
# PIXEL ART COULEUR que screenfetch affiche a l ouverture de chaque terminal
# (osmo-banner, iso_modules/86-finitions.sh : « screenfetch -a »).
#
#     python3 tools/screenfetch-art.py
#
# [2026-10-01] Une parabole (la BTS) sur son socle vert, son bras et son
# illuminateur rouge, et le telephone a cote, ecran vert. Le dessin est CALCULE
# ici (ellipses, segments) sur une grille de pixels, puis rendu en demi-blocs
# « ▀ » : un caractere = deux pixels (couleur du haut en avant-plan, celle du
# bas en fond), en vraies couleurs 24 bits.
# screenfetch exige des lignes de meme largeur VISIBLE : chaque ligne fait W
# colonnes, les couleurs sont des sequences \e[...m (largeur nulle) que le
# printf de screenfetch interprete.
import math
import os

W, H = 30, 30
PAL = {
    "k": (16, 16, 24),     # contour
    "d": (84, 96, 130),    # parabole, creux
    "m": (138, 148, 180),  # parabole, flanc
    "l": (200, 208, 228),  # parabole, reflet
    "t": (216, 204, 160),  # bras de l illuminateur
    "r": (200, 70, 60),    # rouge : illuminateur et rotule
    "R": (232, 110, 100),
    "g": (140, 180, 140),  # socle
    "G": (90, 138, 90),
    "s": (150, 156, 176),  # support
    "p": (60, 66, 88),     # telephone, boitier
    "P": (96, 104, 134),
    "e": (70, 220, 120),   # telephone, ecran
    "E": (150, 255, 190),
    "y": (255, 176, 0),    # ondes
}
g = [["."] * W for _ in range(H)]


def put(x, y, c):
    x, y = int(round(x)), int(round(y))
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c


def line(x0, y0, x1, y1, c, w=1):
    n = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
    for i in range(n + 1):
        t = i / n
        for dx in range(w):
            for dy in range(w):
                put(x0 + (x1 - x0) * t + dx, y0 + (y1 - y0) * t + dy, c)


def ell(cx, cy, a, b, ang):
    ca, sa = math.cos(ang), math.sin(ang)

    def f(x, y):
        dx, dy = x - cx, y - cy
        u, v = dx * ca + dy * sa, -dx * sa + dy * ca
        return (u / a) ** 2 + (v / b) ** 2
    return f


def paint_ell(f, c, only=None):
    for y in range(H):
        for x in range(W):
            if f(x, y) <= 1 and (only is None or g[y][x] in only):
                g[y][x] = c


# -- la parabole : coque claire, creux sombre decale vers le haut-gauche ---
ang = math.radians(40)
coque = ell(15, 9, 10.8, 5.6, ang)
creux = ell(13.8, 8.2, 8.8, 4.0, ang)
bord = ell(15, 9, 12.0, 6.8, ang)
paint_ell(bord, "k")
paint_ell(coque, "m")
for y in range(H):                      # reflet : le flanc haut de la coque
    for x in range(W):
        if coque(x, y) <= 1 and creux(x, y) > 1 and creux(x + 1.4, y + 1.4) <= 1:
            g[y][x] = "l"
paint_ell(creux, "d")
# -- bras de l illuminateur : du creux vers le haut a droite, bout rouge ---
line(14, 9, 22, 2.5, "k", 3)
line(14.5, 9.5, 21.6, 3.2, "t", 1)
for (x, y) in ((22, 1), (23, 1), (22, 2), (23, 2), (24, 2), (23, 3), (24, 3)):
    put(x, y, "k")
for (x, y) in ((22, 2), (23, 2), (23, 3)):
    put(x, y, "r")
put(23, 2, "R")
# -- support : du dessous de la parabole a la rotule, puis au socle ---------
line(11, 14, 8, 18, "k", 4)
line(11.5, 14.5, 9, 18, "s", 2)
for y in range(18, 26):                 # pied trapezoidal
    half = 2 + (y - 18) * 0.55
    for x in range(int(8 - half) - 1, int(8 + half) + 2):
        put(x, y, "k")
for y in range(18, 26):
    half = 2 + (y - 18) * 0.55
    for x in range(int(8 - half), int(8 + half) + 1):
        put(x, y, "s" if x < 8 else "m")
for (x, y) in ((7, 17), (8, 17), (9, 17), (6, 18), (10, 18), (6, 19), (10, 19), (7, 20), (8, 20), (9, 20)):
    put(x, y, "k")
for (x, y) in ((7, 18), (8, 18), (9, 18), (7, 19), (9, 19)):
    put(x, y, "r")
put(8, 19, "k")
# -- socle vert -------------------------------------------------------------
for x in range(1, 20):
    put(x, 25, "k"); put(x, 29, "k")
for y in range(26, 29):
    put(1, y, "k"); put(19, y, "k")
    for x in range(2, 19):
        put(x, y, "g" if y < 28 else "G")
for x in range(2, 19):
    put(x, 26, "l" if x % 7 else "g")
# -- le telephone, a droite, ecran vert, avec ses ondes ---------------------
for y in range(17, 28):
    for x in range(22, 29):
        put(x, y, "k")
for y in range(18, 27):
    for x in range(23, 28):
        put(x, y, "p")
for y in range(19, 22):
    for x in range(24, 27):
        put(x, y, "e")
put(24, 19, "E"); put(25, 19, "E")
for (x, y) in ((24, 23), (26, 23), (24, 24), (26, 24), (24, 25), (26, 25)):
    put(x, y, "P")
for (x, y) in ((25, 23), (25, 24), (25, 25)):
    put(x, y, "P")
line(27, 17, 28, 14, "k", 1)            # antenne
for (x, y) in ((24, 12), (26, 11), (25, 14), (28, 12)):
    put(x, y, "y")                      # ondes qui partent du telephone


def cell(top, bot):
    def fg(c): return "\\e[38;2;%d;%d;%dm" % PAL[c]
    def bg(c): return "\\e[48;2;%d;%d;%dm" % PAL[c]
    if top == "." and bot == ".":
        return " "
    if bot == ".":
        return fg(top) + "▀\\e[0m"
    if top == ".":
        return fg(bot) + "▄\\e[0m"
    return fg(top) + bg(bot) + "▀\\e[0m"


EN_TETE = r'''#!/bin/bash
# configs/screenfetch/osmo-lab.sh - le logo pixel art du banc, pour screenfetch -a.
# GENERE par tools/screenfetch-art.py : c est la qu on retouche le dessin.
# Source par screenfetch (asciiText) : startline, fulloutput (une ligne = un %s
# en queue, @W@ colonnes visibles chacune), labelcolor / textcolor.
#
# Les couleurs des INFOS ne se posent pas ici : screenfetch a deja fige ses
# lignes quand il source ce fichier. Elles sont posees par osmo-banner, qui
# filtre la sortie (utilisateur jaune, hote vert ; root rouge, hote jaune).
labelcolor=$'\e[1;33m'
textcolor=$'\e[0m'
startline="0"
logowidth="@W@"
fulloutput=(
'''


def main():
    out = []
    for r in range(0, H, 2):
        s = "".join(cell(g[r][x], g[r + 1][x]) for x in range(W))
        out.append('"' + s + '  %s"')
    dst = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "configs", "screenfetch", "osmo-lab.sh"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        f.write(EN_TETE.replace("@W@", str(W + 2)) + "\n".join(out) + ")\n")
    print("[screenfetch-art] %s : %d lignes de %d colonnes" % (dst, H // 2, W + 2))


if __name__ == "__main__":
    main()
