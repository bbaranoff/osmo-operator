#!/usr/bin/env python3
# wallpaper-render.py - compose le fond d ecran du banc (1920x1080).
#
#   python3 wallpaper-render.py --tower configs/wallpaper/tower.png \
#           [--strip calvin.gif] [--date 2026-09-04] --out gsm-lab-wallpaper.png
#
# Disposition, pensee pour ne rien faire chevaucher sur l ecran :
#
#   +--------+------------------------------------------+-------------------+
#   | dock + | carte LAB GSM (x 320..1430, y 60..560)  | conky (400 px,    |
#   | icones |                                          | gap 24, y 40..660)|
#   | bureau | strip / encart (x 510..1410, CENTRE,      |                   |
#   | (haut  |                          y 600..1010)    |                   |
#   | gauche)|                                          |                   |
#   +--------+------------------------------------------+-------------------+
#
# Le pylone de la photo est au MILIEU (voir background/TOWER_X) : les deux
# panneaux sont translucides et le laissent passer.
# Les deux colonnes de cote ne recoivent que la photo. A gauche (x < 320) : le
# dock GNOME (~70 px) puis les icones du bureau, en haut a gauche (DING,
# start-corner top-left, cases de ~100 px). A droite (x >= 1440) : conky
# (top_right, gap_x 24, 400 px de large, cf. configs/conky/osmo-conky.conf).
#
# Sans --strip (pas de reseau au build, ou au boot), la zone du strip reste
# vide : le fond est complet sans lui. Le strip du jour est pose par
# tools/osmo-wallpaper.sh (service + timer osmo-wallpaper).
#
# Ne depend que de Pillow (python3-pil) et des polices DejaVu (fonts-dejavu),
# presents sur l image comme sur l hote.

# [2026-09-04] L ENCART EST AU MILIEU BAS. Sa boite etait (320, 600, 1430, 1010) :
# calee a gauche, sous la carte LAB GSM et sur la meme verticale qu elle. Depuis
# que le pylone de la photo est recentre (tools/wallpaper-render.py, TOWER_X),
# cet encart decale n avait plus de raison d etre - et il n a jamais ete au
# milieu de l ecran, seulement au milieu de la bande laissee libre.
# La nouvelle boite (510, 600, 1410, 1010) est CENTREE sur les 1920 px
# (510 + 900/2 = 960) et s arrete avant x=1440, ou commence la colonne du conky.
# LES TROIS FICHIERS QUI LA CONNAISSENT DOIVENT RESTER D ACCORD :
#   tools/wallpaper-render.py  (le cadre dessine dans le fond)
#   tools/osmo-fft-snap.py     (l image 900x410 qu on y peint)
#   tools/osmo-panel.py        (la fenetre GTK cliquable posee dessus)
import argparse
import datetime
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

W, H = 1920, 1080
FONT_DIR = "/usr/share/fonts/truetype/dejavu"


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_h(w, h, stops):
    """Bande horizontale w x h, degrade entre les couleurs `stops`."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    n = len(stops) - 1
    for x in range(w):
        t = x / max(1, w - 1) * n
        i = min(int(t), n - 1)
        c = lerp(stops[i], stops[i + 1], t - i)
        for y in range(h):
            px[x, y] = c
    return img


def rounded(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


# ── GOMMER LES DEFAUTS DE LA PHOTO ──────────────────────────────────────────
# [2026-09-04] La photo est prise EN CONTRE-JOUR, au telephone, et elle en porte
# les trois marques. Elles ne se voyaient pas tant que le pylone etait un
# lointain decor a gauche ; au milieu et agrandi x1.9, elles sautent aux yeux :
#
#   1. UN VOILE MAGENTA. Le soleil dans l objectif renvoie un halo diagonal
#      violace en travers du ciel - un fantome de diaphragme. Sur un fond bleu
#      nuit, il ressort comme une trainee sale que personne ne sait nommer.
#   2. DU FRANGEAGE CHROMATIQUE. Les montants sombres sur ciel brule prennent
#      un lisere violet (aberration laterale). L accentuation qui suit le
#      RENFORCAIT : on accentuait le defaut avec le detail.
#   3. DU BLOCKING JPEG. Le ciel est un degrade quasi uni : c est exactement ce
#      que le JPEG rend le plus mal (carres de 8x8 et bandes). L agrandissement
#      les etale en plaques visibles.
#
# Trois corrections, ciblees, dans cet ordre - et AVANT l accentuation, sinon
# on accentue ce qu on s apprete a gommer.
#
# OSMO_WP_CLEAN=0 les neutralise (pour comparer, ou pour une autre photo).
def nettoyer_photo(im):
    """Defrangeage magenta + lissage du ciel, sans toucher au treillis."""
    # [2026-09-04] PAR DEFAUT : NE RIEN FAIRE. Ce nettoyage a ete ecrit pour la
    # photo PRECEDENTE - un contre-jour au telephone, avec son voile de flare,
    # son frangeage et son blocking JPEG. La photo actuelle est propre, et
    # surtout elle est ROSE : un ciel de couchant, ou le vert est legitimement
    # sous la moyenne du rouge et du bleu sur la moitie de l image. La
    # correction magenta y verrait un defaut partout et REPEINDRAIT LE CIEL en
    # gris - elle detruirait exactement ce qui fait l image.
    # Le code reste, documente : OSMO_WP_CLEAN=1 le rallume pour une photo qui
    # en aurait besoin.
    if os.environ.get("OSMO_WP_CLEAN", "0") != "1":
        return im

    # ── 1 et 2. LE MAGENTA, VOILE ET LISERES, D UN SEUL GESTE ───────────────
    # Un ciel a R < G < B. Le halo de flare comme le frangeage ont la meme
    # signature : le VERT tombe sous la moyenne du rouge et du bleu (c est la
    # definition du magenta). On remonte donc le vert jusqu a cette moyenne, la
    # ou il est dessous. Ce qui est reellement magenta dans la scene - rien,
    # ici : du ciel et de l acier - n existe pas, donc rien de legitime n est
    # touche. Une correction en une passe, sans masque a regler.
    r, g, b = im.split()
    moy = ImageChops.add(r.point(lambda v: v // 2), b.point(lambda v: v // 2))
    g = ImageChops.lighter(g, moy)
    im = Image.merge("RGB", (r, g, b))

    # ── 3. LE CIEL LISSE, LE TREILLIS INTACT ────────────────────────────────
    # On ne peut pas flouter toute l image : le pylone y perdrait ce que
    # l accentuation lui rend juste apres. On construit donc un masque de
    # DETAIL - l ecart entre l image et sa version floue, c est-a-dire les
    # arretes - qu on elargit (MaxFilter) pour couvrir les bords, puis qu on
    # adoucit pour que la transition ne se voie pas. Le flou n est applique que
    # LA OU IL N Y A PAS DE DETAIL : le ciel, et lui seul.
    flou = im.filter(ImageFilter.GaussianBlur(2.2))
    gris = im.convert("L")
    ecart = ImageChops.difference(gris, gris.filter(ImageFilter.GaussianBlur(2.2)))
    masque = ecart.point(lambda v: 255 if v > 4 else 0)
    masque = masque.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.6))
    return Image.composite(im, flou, masque)


# ── OU TOMBE LE PYLONE SUR L ECRAN ──────────────────────────────────────────
# [2026-09-04] IL EST REVENU AU MILIEU. Il etait cale a GAUCHE : la photo etait
# decalee pour poser le SOLEIL en bas a gauche du strip, et le pylone suivait -
# il finissait derriere la colonne des icones du bureau, a moitie mange par le
# dock. Sur l ecran, le sujet de l image passait derriere les objets qui ne
# demandaient qu a etre lisibles.
#
# On ancre donc sur le PYLONE et non sur le soleil. Le mat traverse la photo
# d origine (1170x1123) autour de x = 658 : c est ce point qu on amene a
# TOWER_X (0.62 : entre la carte LAB GSM et la colonne du conky - le plein
# centre, 0.5, agrandissait trop la photo et noyait le soleil hors cadre),
# qui sont translucides - le pylone se lit a travers).
#
# L ECHELLE SE DEDUIT DE LA POSITION VOULUE, elle n est plus le simple "couvrir
# l ecran". Recadrer sans agrandir laissait un vide sur un cote, que la version
# precedente comblait par un miroir du ciel. On calcule la plus petite echelle
# qui met le pylone a sa place SANS vide d aucun cote - le miroir devient un
# filet de securite au lieu d etre la regle.
# x du mat, et taille de reference de configs/wallpaper/tower.jpg.
# [2026-09-04] Nouvelle photo (pylone hertzien au couchant, 3840x2160) : le mat
# y est a 34,2 % de la largeur, mesure en cherchant la colonne la plus
# STRUCTUREE de la bande centrale (somme du detail image-flou, colonne par
# colonne) - le pic est franc, sans ambiguite. L ancienne photo avait le sien a
# 658/1170 ; le rapport est ce qui compte, background() le remet a l echelle du
# fichier reel, donc remplacer l image ne demande que cette ligne.
# [2026-09-04] La photo est prise TELLE QUELLE, en PNG, a sa definition
# d origine (5824x3264) : la reduire ou la passer en JPEG pour alleger, c est
# perdre de la qualite sur la seule image que l ecran montre en grand. Le rendu
# la RE-DUIT de toute facon (echelle ~0.57 pour caler le mat), et reduire depuis
# la pleine definition donne un meilleur resultat que reduire deux fois.
TOWER_SRC = (1992, 5824, 3264)
TOWER_X = float(os.environ.get("OSMO_WP_TOWER_X", "0.62"))


def background(tower_path, tower_x=None, sun_y_at=984):
    """La photo en fond : le pylone AU MILIEU (tower_x, fraction de la largeur
    d ecran ; 0.5 par defaut). Assombrie au centre (les panneaux sont poses
    dessus) et teintee bleu nuit."""
    tower = nettoyer_photo(Image.open(tower_path).convert("RGB"))
    tw, th = tower.size
    src_x, ref_w, _ref_h = TOWER_SRC
    # Le repere du mat suit la taille reelle du fichier : une photo remplacee
    # par une autre du meme cadrage reste correcte.
    src_x = src_x * tw / ref_w
    target = (TOWER_X if tower_x is None else tower_x) * W
    # Trois contraintes : couvrir en hauteur, et ne deborder ni a gauche ni a
    # droite une fois le mat amene sur `target`.
    scale = max(H / th,
                target / max(src_x, 1),
                (W - target) / max(tw - src_x, 1))
    tower = tower.resize((int(tw * scale) + 1, int(th * scale) + 1), Image.LANCZOS)
    # ── ACCENTUER LE PYLONE ─────────────────────────────────────────────────
    # [2026-09-04] La photo est un CONTRE-JOUR : le soleil est derriere le mat,
    # qui sort donc en silhouette sombre sur un ciel brule, et l agrandissement
    # (x1.9 pour amener le pylone au milieu) etale ce peu de detail sur deux
    # fois plus de pixels. A l ecran, le treillis devenait une bouillie grise -
    # on voyait qu il y avait « quelque chose », pas une antenne.
    #
    # Trois gestes, dans cet ordre, et pas un de plus :
    #   1. un masque flou (unsharp) large et doux : il redonne l arete des
    #      montants et des croix sans creuser le grain du ciel ;
    #   2. le contraste, legerement : la silhouette se detache du halo ;
    #   3. la nettete, un cheveu : les cables et les panneaux d antenne.
    # Applique AVANT la teinte et l assombrissement : accentuer apres, ce
    # serait accentuer un voile bleu, pas la photo.
    #
    # Les trois valeurs sont reglables (OSMO_WP_SHARPEN=0 les neutralise) :
    # sur une autre photo, ou un ecran tres dense, le bon dosage n est pas le
    # meme, et une image sur-accentuee est pire qu une image molle.
    # [2026-09-04] 1 -> 0.45. L ancienne photo faisait 1170 px de large et etait
    # AGRANDIE x1.9 : il fallait beaucoup pour recoller les details etales. La
    # nouvelle fait 3840 px et se retrouve REDUITE (echelle ~0.9) - or reduire
    # affute deja. Garder 1 donnait des halos sur les haubans et un ciel
    # granuleux. Un cheveu suffit maintenant, juste pour compenser le
    # reechantillonnage.
    _shp = float(os.environ.get("OSMO_WP_SHARPEN", "0.45"))
    if _shp > 0:
        tower = tower.filter(ImageFilter.UnsharpMask(radius=2.4 * _shp,
                                                    percent=int(135 * _shp), threshold=3))
        tower = ImageEnhance.Contrast(tower).enhance(1 + 0.16 * _shp)
        tower = ImageEnhance.Sharpness(tower).enhance(1 + 0.35 * _shp)
    x0 = int(round(src_x * scale - target))
    x0 = max(0, min(x0, tower.width - W))
    # Verticalement, le soleil reste ou il etait : en bas a gauche du strip.
    sun_y = int(600 * scale * th / _ref_h)
    y0 = max(0, min(sun_y - sun_y_at, tower.height - H))
    bg = Image.new("RGB", (W, H))
    part = tower.crop((x0, y0, min(tower.width, x0 + W), y0 + H))
    bg.paste(part, (0, 0))
    gap = W - part.width
    if gap > 0:
        # Ne devrait plus arriver (l echelle est calculee pour), mais une photo
        # d un autre cadrage pourrait l imposer : miroir du bord, ciel uni.
        edge = tower.crop((tower.width - gap, y0, tower.width, y0 + H)).transpose(Image.FLIP_LEFT_RIGHT)
        bg.paste(edge, (part.width, 0))
    # Teinte bleu nuit + assombrissement : le pylone est au centre, donc SOUS
    # les deux panneaux - ils sont translucides, il faut qu il transparaisse
    # sans rendre le texte gris. D ou un assombrissement plus doux qu avant au
    # centre (85 -> 70) et symetrique.
    tint = Image.new("RGB", (W, H), (10, 18, 40))
    bg = Image.blend(bg, tint, 0.18)
    mask = gradient_h(W, 1, [(0, 0, 0), (70, 70, 70), (70, 70, 70), (0, 0, 0)]).resize((W, H))
    dark = Image.new("RGB", (W, H), (6, 10, 24))
    bg = Image.composite(dark, bg, mask.convert("L"))
    return bg


def glass_panel(base, box, radius=26, alpha=185, fill=(13, 22, 44), border=(90, 120, 200), blur=14):
    """Panneau translucide, fond legerement flou dessous (verre depoli)."""
    x0, y0, x1, y1 = box
    if blur > 0:
        region = base.crop(box).filter(ImageFilter.GaussianBlur(blur))
        base.paste(region, (x0, y0))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    rounded(d, box, radius, fill=fill + (alpha,), outline=border + (110,), width=2)
    base.paste(Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB"))


def gradient_text(base, xy, text, fnt, stops):
    """Texte rempli d un degrade horizontal."""
    x, y = xy
    l, t, r, b = fnt.getbbox(text)
    w, h = r - l, b - t
    mask = Image.new("L", (w + 4, h + 4), 0)
    ImageDraw.Draw(mask).text((-l + 2, -t + 2), text, font=fnt, fill=255)
    grad = gradient_h(w + 4, h + 4, stops)
    base.paste(grad, (x, y), mask)
    return w, h


def card(base, box, arfcn="514", band="DCS 1800"):
    x0, y0, x1, y1 = box
    # Carte bien transparente : le pylone et le ciel restent visibles derriere
    # le texte (le strip, lui, garde un fond opaque pour rester lisible).
    glass_panel(base, box, alpha=38, blur=0)
    d = ImageDraw.Draw(base)
    pad = 44
    x = x0 + pad
    y = y0 + 34

    # En-tete
    d.ellipse((x, y + 4, x + 14, y + 18), fill=(63, 185, 160))
    d.text((x + 28, y), "SOFTWARE DEFINED RADIO  ·  UM INTERFACE  ·  GR-GSM",
           font=font("DejaVuSansMono.ttf", 15), fill=(150, 170, 210))
    tag = f"ARFCN {arfcn}  ·  {band}"
    tf = font("DejaVuSansMono-Bold.ttf", 15)
    tw = d.textlength(tag, font=tf)
    rounded(d, (x1 - pad - tw - 28, y - 8, x1 - pad, y + 28), 10, outline=(63, 185, 160), width=2)
    d.text((x1 - pad - tw - 14, y), tag, font=tf, fill=(120, 230, 210))

    # Titre
    y += 46
    # Titre en violet uni (pas de degrade).
    tw, th = gradient_text(base, (x - 4, y), "LAB GSM", font("DejaVuSans-Bold.ttf", 86),
                           [(150, 100, 245), (150, 100, 245)])
    d = ImageDraw.Draw(base)
    y += th + 20
    sub = font("DejaVuSans.ttf", 22)
    subb = font("DejaVuSans-Bold.ttf", 22)
    line1 = [("Un réseau 2G complet, ", sub), ("sans matériel", subb),
             (" — baseband ", sub), ("Calypso", subb), (" émulé, cœur ", sub), ("Osmocom", subb), (",", sub)]
    line2 = [("de la synchro radio à l'appel voix chiffré en ", sub), ("A5/1", subb),
             ("  ·  couche 1 ", sub), ("gr-gsm", subb), (" (SDR)", sub)]
    for line in (line1, line2):
        cx = x
        for txt, f in line:
            d.text((cx, y), txt, font=f, fill=(215, 225, 245))
            cx += d.textlength(txt, font=f)
        y += 32

    # Trame TDMA
    y += 14
    d.text((x, y), "TRAME TDMA  ·  8 TIMESLOTS  ·  4,615 MS", font=font("DejaVuSansMono.ttf", 14),
           fill=(150, 170, 210))
    y += 26
    slots = [("TS0", "FCCH·SCH·BCCH"), ("TS1", "SDCCH"), ("TS2", "TCH/F"), ("TS3", "TCH/F"),
             ("TS4", "TCH/F"), ("TS5", "TCH/F"), ("TS6", "PDCH"), ("TS7", "PDCH")]
    inner = (x1 - pad) - x
    gap = 10
    sw = (inner - gap * 7) // 8
    sh = 58
    for i, (name, use) in enumerate(slots):
        sx = x + i * (sw + gap)
        active = i == 0
        rounded(d, (sx, y, sx + sw, y + sh), 8,
                fill=(58, 62, 150) if active else (24, 34, 70),
                outline=(120, 130, 240) if active else (60, 75, 130), width=2)
        nf = font("DejaVuSansMono-Bold.ttf", 16)
        uf = font("DejaVuSansMono.ttf", 11)
        d.text((sx + (sw - d.textlength(name, font=nf)) / 2, y + 12), name, font=nf, fill=(235, 240, 255))
        d.text((sx + (sw - d.textlength(use, font=uf)) / 2, y + 38), use, font=uf,
               fill=(120, 230, 210) if active else (140, 160, 200))
    y += sh + 8
    d.text((x, y), "0 µs", font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    mid = "1 burst = 577 µs"
    d.text((x + inner / 2 - d.textlength(mid, font=font("DejaVuSansMono.ttf", 12)) / 2, y), mid,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))
    end = "4615 µs"
    d.text((x1 - pad - d.textlength(end, font=font("DejaVuSansMono.ttf", 12)), y), end,
           font=font("DejaVuSansMono.ttf", 12), fill=(120, 140, 180))

    # Normal burst
    y += 24
    d.text((x, y), "NORMAL BURST  ·  156,25 BITS", font=font("DejaVuSansMono.ttf", 14), fill=(150, 170, 210))
    y += 24
    parts = [(3, "tail", (70, 80, 120)), (57, "data", (52, 205, 180)), (1, "", (240, 90, 120)),
             (26, "training", (120, 110, 240)), (1, "", (240, 90, 120)), (57, "data", (52, 205, 180)),
             (3, "tail", (70, 80, 120)), (8.25, "guard", (90, 100, 140))]
    total = sum(p[0] for p in parts)
    bx = x
    bh = 40
    for bits, name, col in parts:
        bw = inner * bits / total
        d.rectangle((bx, y, bx + bw, y + bh), fill=col)
        if name and bw > 40:
            lf = font("DejaVuSansMono-Bold.ttf", 12)
            lbl = f"{bits:g}"
            d.text((bx + (bw - d.textlength(lbl, font=lf)) / 2, y + 6), lbl, font=lf, fill=(10, 20, 40))
            d.text((bx + (bw - d.textlength(name, font=lf)) / 2, y + 22), name, font=lf, fill=(10, 20, 40))
        bx += bw
    y += bh + 12

    # Puces en bas
    chips = [("IMSI 001-01", (150, 170, 210)), ("A5/1 ✓", (120, 230, 210)), ("COMP128v1 ✓", (120, 230, 210)),
             ("TCH/F · GAPK fr", (120, 230, 210)), ("gr-gsm · trxcon · osmo-bts-trx", (150, 170, 210))]
    cf = font("DejaVuSansMono-Bold.ttf", 13)
    cx = x
    for txt, col in chips:
        cw = d.textlength(txt, font=cf) + 22
        rounded(d, (cx, y, cx + cw, y + 28), 8, outline=col, width=1)
        d.text((cx + 11, y + 6), txt, font=cf, fill=col)
        cx += cw + 10
    site = "bbaranoff.github.io"
    sf = font("DejaVuSansMono-Bold.ttf", 14)
    d.text((x1 - pad - d.textlength(site, font=sf), y + 6), site, font=sf, fill=(180, 200, 240))


def strip_panel(base, box, strip_path, date_str, credit=None):
    """L image du jour, dans un cadre blanc arrondi.

    `credit` est la ligne de pied : elle NOMME la source. Elle etait ecrite en
    dur (« Calvin & Hobbes ... gocomics.com ») du temps ou il n y avait qu une
    source ; depuis que osmo-wallpaper.sh en tire une au sort, une legende figee
    aurait attribue a Bill Watterson un xkcd ou une photo de la NASA.
    """
    x0, y0, x1, y1 = box
    glass_panel(base, box, fill=(20, 24, 36), alpha=210, border=(200, 200, 210))
    d = ImageDraw.Draw(base)
    pad = 18
    # ── PLUS DE LIGNE DE SOURCE DANS LE CADRE ───────────────────────────────
    # [2026-09-04] Ce pied portait « Bing · image du jour · Phare de
    # Westerheversand a Westerhever, Schleswig-Holstein, Allemagne (© ...) ».
    # Deux problemes, et le second suffit :
    #   - il passait SOUS la barre de boutons de l encart (Dashboard / tmux /
    #     VTY, plus les fleches), qui vit exactement la : on lisait une moitie
    #     de phrase derriere « Dashboard op2 » ;
    #   - il n a rien a faire la. Ce cadre est l ENCART DU BANC : des que la
    #     pile monte, il porte un spectre et un journal, et la provenance d une
    #     photo n y a aucun sens.
    # La place rendue va a l image, qui remplit maintenant tout le cadre.
    # OSMO_WP_CREDIT=1 remet la ligne pour qui la veut.
    foot = 30 if os.environ.get("OSMO_WP_CREDIT") == "1" else 0
    strip = Image.open(strip_path)
    strip.seek(0)
    strip = strip.convert("RGB")
    sw, sh = strip.size
    aw, ah = (x1 - x0) - 2 * pad, (y1 - y0) - 2 * pad - foot
    scale = min(aw / sw, ah / sh)
    strip = strip.resize((int(sw * scale), int(sh * scale)), Image.LANCZOS)
    sx = x0 + pad + (aw - strip.width) // 2
    sy = y0 + pad
    # Cadre blanc derriere le strip (les GIF ont des marges irregulieres).
    d.rounded_rectangle((sx - 6, sy - 6, sx + strip.width + 6, sy + strip.height + 6), radius=8,
                        fill=(255, 255, 255))
    base.paste(strip, (sx, sy))
    if foot == 0:
        return
    d = ImageDraw.Draw(base)
    cap = credit or f"Calvin & Hobbes  ·  Bill Watterson  ·  {date_str}  ·  gocomics.com"
    cf = font("DejaVuSansMono.ttf", 13)
    # ── LA LEGENDE NE DOIT PAS SORTIR DU CADRE ──────────────────────────────
    # [2026-09-04] Elle etait ecrite sans aucune limite de largeur. Tant que le
    # cadre faisait 1110 px, les legendes tenaient ; a 900 px (l encart recentre
    # au milieu bas), le credit Bing - « Phare de Westerheversand a Westerhever,
    # Schleswig-Holstein, Allemagne (© bluejayphoto/Getty Images) » - DEBORDAIT
    # sur le bureau, a droite du panneau. Et comme l encart vivant
    # (osmo-fft-snap.py) recouvre exactement le cadre et rien de plus, ce qui
    # depassait restait visible SOUS le spectre et le mobile.log : un bout de
    # phrase orpheline en travers du fond, sans rien pour l expliquer.
    #
    # On coupe donc a la largeur utile, avec une ellipse. Mesurer puis tronquer,
    # et non deviner un nombre de caracteres : la police est a chasse fixe ici,
    # mais la legende peut contenir des accents et des symboles.
    avail = (x1 - x0) - 2 * pad
    if d.textlength(cap, font=cf) > avail:
        while cap and d.textlength(cap + "...", font=cf) > avail:
            cap = cap[:-1]
        cap = cap.rstrip(" ·") + "..."
    d.text((x0 + pad, y1 - foot + 6), cap, font=cf, fill=(160, 170, 190))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tower", required=True)
    ap.add_argument("--strip", default=None)
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--credit", default=None,
                    help="ligne de pied sous l image (source, auteur). "
                         "Defaut : la legende Calvin & Hobbes.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--arfcn", default="514")
    ap.add_argument("--band", default="DCS 1800")
    ap.add_argument("--tower-x", type=float, default=None,
                    help="ou poser le pylone, en fraction de la largeur d ecran "
                         "(0.5 = milieu, le defaut ; 0.17 = l ancien calage a gauche)")
    a = ap.parse_args()

    base = background(a.tower, a.tower_x)
    card(base, (320, 60, 1430, 560), a.arfcn, a.band)
    if a.strip and os.path.isfile(a.strip):
        try:
            strip_panel(base, (510, 600, 1410, 1010), a.strip, a.date, a.credit)
        except Exception as e:  # GIF corrompu, page HTML au lieu d une image...
            print(f"[wallpaper] strip ignore : {e}", file=sys.stderr)
    tmp = a.out + ".tmp.png"
    base.save(tmp, "PNG", optimize=True)
    os.replace(tmp, a.out)
    print(f"[wallpaper] {a.out} ({W}x{H}, strip={'oui' if a.strip and os.path.isfile(a.strip) else 'non'})")


if __name__ == "__main__":
    main()
