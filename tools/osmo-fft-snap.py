#!/usr/bin/env python3
# osmo-fft-snap.py - l ENCART VIVANT du bureau : le cadre Calvin & Hobbes du fond
# d ecran (tools/wallpaper-render.py, boite 510,600-1410,1010 en 1920x1080) qui
# FOND vers le banc une fois qu il est pret :
#
#   +-----------------------------------------------------------+
#   |  Spectre I/Q du mobile (montant)   |  mobile.log (QEMU)   |
#   |  spectre + chute d eau             |  dernieres lignes    |
#   +-----------------------------------------------------------+
#
# Tant que le banc n est pas la (pas de flux I/Q sur /psd), l image EST le
# strip du jour, decoupe dans le fond d ecran : le Conky qui l affiche
# (tools/osmo-conky-panel.sh) est invisible. Des que le pont alimente la FFT,
# l image glisse en ~3 s (Image.blend) du strip vers le banc ; si le banc
# s arrete - /psd rend une erreur au lieu d un spectre - elle revient au strip
# de la meme facon. Une fois le fondu fini, le banc est OPAQUE : le spectre et
# mobile.log doivent se lire, pas se deviner par-dessus un dessin.
#
# Source FFT : le dashboard, http://127.0.0.1:8080/psd?src=ms - le meme JSON
# que l onglet FFT (vue fft1) : freqs, psd (dB), dr, arfcn. Le journal : le
# mobile.log de la pile (QEMU MS#1), lu par la queue.
#
#   /run/osmo-fft/panel.png   900x410   (coordonnees du fond ; Conky le met a
#                                        l echelle de l ecran)
#
# Lance par osmo-fft-snap.service. Ne depend que de Pillow et des polices
# DejaVu, presents sur l image comme sur l hote.
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

from PIL import Image, ImageDraw, ImageFont

URL = os.environ.get("OSMO_FFT_URL", "http://127.0.0.1:8080/psd")
OUT = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
PERIOD = float(os.environ.get("OSMO_FFT_PERIOD", "1"))
FADE_S = float(os.environ.get("OSMO_FFT_FADE", "3"))
# Opacite du banc PAR-DESSUS l image du fond, une fois le fondu termine.
#
# [2026-09-04] ESSAYEE A 0.86, REMISE A 1.0. L idee etait de laisser l image du
# jour transparaitre sous le spectre. A l ecran, la bande dessinee traversait le
# journal et le spectre : les traits noirs du dessin passaient entre les lignes
# de mobile.log, et le spectre se lisait sur un fond a motifs. On perdait les
# deux - l image, hachee par le panneau, et le banc, illisible.
# Le fondu, lui, reste : c est LUI qui fait passer de l image au banc et
# retour (FADE_S), et pendant ces trois secondes les deux se superposent.
# OSMO_FFT_OPACITY=0.86 rend l ancien comportement a qui veut l essayer.
OPACITY = max(0.0, min(1.0, float(os.environ.get("OSMO_FFT_OPACITY", "1.0"))))
# Etat ecrit par tools/osmo-wallpaper.sh : y a-t-il un strip dans le fond ?
# Sans reseau, gocomics ne rend pas l image et le fond part SANS strip - le
# cadre est alors vide, et composer le banc en transparence par-dessus du vide
# ne fait que ternir le spectre et le journal. Dans ce cas l encart passe en
# opacite pleine : pas de png, mais le mobile.log et la FFT restent nets.
STRIP_STATE = os.environ.get("OSMO_WP_STATE", "/var/cache/osmo-wallpaper/strip.state")
WALLPAPER = os.environ.get("OSMO_WP_FILE", "/usr/share/backgrounds/gsm-lab-wallpaper.png")
MOBILE_LOG = os.environ.get("OSMO_MOBILE_LOG", "/run/user/0/osmo-nitb/logs/mobile.log")
# L operateur choisi dans l encart (tools/osmo-panel.py, fleches) : OP=, MODE=,
# IP=, NAME=, DASH=. Absent ou natif : le dashboard et le journal locaux.
OP_FILE = os.path.join(OUT, "operator")
# La boite du strip dans le fond d ecran (wallpaper-render.py, main()).
BOX = (510, 600, 1410, 1010)
W, H = BOX[2] - BOX[0], BOX[3] - BOX[1]
PAD = 18
# [2026-09-04] FOOT = 0 : PLUS DE BANDE DE PIED.
# Il y avait en bas de l encart un bandeau de 30 px portant « Operateur N ·
# spectre I/Q du mobile (http://...) », et la barre de boutons se posait dessus.
# C est le « rectangle » qu on voyait en travers du bas : une bande pleine
# largeur, distincte du contenu, pour une ligne de texte qui ne disait rien que
# les boutons ne disent deja (ils portent le numero de l operateur depuis
# qu ils suivent la selection). Le contenu - spectre, chute d eau, journal -
# prend donc toute la hauteur, et il ne reste QUE les boutons, poses par-dessus
# dans le coin. FOOT reste nomme : la geometrie s exprime avec, et le remettre
# a 30 rend l ancien pied.
FOOT = 0
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x07")
# ── LES COULEURS DU JOURNAL SONT DEJA DANS LE JOURNAL ───────────────────────
# mobile.log est ecrit AVEC ses codes ANSI (osmocom colorie par sous-systeme :
# « \033[0;31m<0004> gsm322.c:... \033[0;m »). L encart les jetait et
# repeignait les lignes au petit bonheur, sur des mots-cles (« error »,
# « call »...) : deux lignes du meme sous-systeme sortaient de couleurs
# differentes, et la lecture ne ressemblait plus du tout a celle du terminal.
# On rend donc la couleur que le journal porte, avec la palette Tango - celle
# du profil gnome-terminal de l image (85-installeur-bureau.sh).
SGR = re.compile(r"\x1b\[([0-9;]*)m")
TANGO = {
    "30": (85, 87, 83),    "31": (204, 0, 0),     "32": (78, 154, 6),
    "33": (196, 160, 0),   "34": (52, 101, 164),  "35": (117, 80, 123),
    "36": (6, 152, 154),   "37": (211, 215, 207),
}
TANGO_VIF = {
    "30": (128, 130, 126), "31": (239, 41, 41),   "32": (138, 226, 52),
    "33": (252, 233, 79),  "34": (114, 159, 207), "35": (173, 127, 168),
    "36": (52, 226, 226),  "37": (238, 238, 236),
}
LOG_DEFAUT = (200, 210, 225)


def couleur_ansi(brut):
    """La couleur que ce terminal donnerait a cette ligne. None si elle n en a pas."""
    for m in SGR.finditer(brut):
        codes = [c for c in m.group(1).split(";") if c]
        if not codes or codes == ["0"]:
            continue                      # remise a zero : pas une couleur
        table = TANGO_VIF if "1" in codes else TANGO
        for c in codes:
            if c in table:
                return table[c]
            if c.startswith("9") and len(c) == 2 and c[1] in "01234567":
                return TANGO_VIF["3" + c[1]]   # 90-97 : les vifs d ECMA-48
    return None


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


F_TITLE = font("DejaVuSansMono-Bold.ttf", 15)
F_SMALL = font("DejaVuSansMono.ttf", 12)
F_LOG = font("DejaVuSansMono.ttf", 12)


def inferno(v):
    """Palette type inferno, 0..1 -> RGB (la meme famille que l onglet FFT)."""
    stops = [(0, (0, 0, 4)), (0.25, (87, 16, 110)), (0.5, (188, 55, 84)),
             (0.75, (249, 142, 9)), (1.0, (252, 255, 164))]
    v = 0.0 if v < 0 else 1.0 if v > 1 else v
    for i in range(len(stops) - 1):
        a, ca = stops[i]
        b, cb = stops[i + 1]
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            return tuple(int(ca[j] + (cb[j] - ca[j]) * t) for j in range(3))
    return stops[-1][1]


def operator():
    """{'OP','MODE','IP','NAME','DASH'} de l operateur choisi, natif par defaut."""
    op = {"OP": "1", "MODE": "native", "IP": "", "NAME": "", "DASH": URL.rsplit("/", 1)[0]}
    try:
        with open(OP_FILE) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k in op:
                    op[k] = v
    except OSError:
        pass
    return op


def fetch(src):
    op = operator()
    base = URL if op["MODE"] != "docker" else op["DASH"].rstrip("/") + "/psd"
    req = urllib.request.Request(f"{base}?src={src}&t={int(time.time() * 1000)}",
                                 headers={"Cache-Control": "no-store"})
    with urllib.request.urlopen(req, timeout=2) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def normalize(psd, dr):
    top = max(psd)
    floor = top - (dr if dr and dr > 0 else 40)
    span = top - floor if top > floor else 1
    return [min(1.0, max(0.0, (p - floor) / span)) for p in psd]


def resample(vals, n):
    """Ramene une liste a n colonnes (max par groupe : un pic reste visible)."""
    if len(vals) <= n:
        return vals + [vals[-1]] * (n - len(vals)) if vals else [0.0] * n
    out = []
    step = len(vals) / n
    for i in range(n):
        a, b = int(i * step), max(int((i + 1) * step), int(i * step) + 1)
        out.append(max(vals[a:b]))
    return out


_strip = {"mtime": None, "present": True}


def strip_present():
    """Le fond du jour porte-t-il un strip ? (defaut : oui, on ne devine pas)"""
    try:
        mt = os.stat(STRIP_STATE).st_mtime
    except OSError:
        return True
    if mt != _strip["mtime"]:
        val = True
        try:
            with open(STRIP_STATE) as fh:
                for line in fh:
                    k, _, v = line.strip().partition("=")
                    if k == "STRIP":
                        val = v.strip().lower() != "non"
        except OSError:
            pass
        _strip.update(mtime=mt, present=val)
    return _strip["present"]


# ── LE STRIP : DECOUPE DANS LE FOND D ECRAN, RELU QUAND IL CHANGE ───────────
# Le fond est refait chaque jour (osmo-wallpaper.timer) : on suit son mtime.
_base = {"mtime": None, "img": None}


def base_image():
    try:
        mt = os.stat(WALLPAPER).st_mtime
    except OSError:
        mt = None
    if mt != _base["mtime"] or _base["img"] is None:
        img = None
        if mt is not None:
            try:
                wp = Image.open(WALLPAPER).convert("RGB")
                if wp.size != (1920, 1080):
                    wp = wp.resize((1920, 1080), Image.LANCZOS)
                img = wp.crop(BOX)
            except Exception as e:  # fond illisible : cadre sombre, sans strip
                print(f"[fft-snap] fond {WALLPAPER} : {e}", file=sys.stderr, flush=True)
        if img is None:
            img = Image.new("RGB", (W, H), (20, 24, 36))
            ImageDraw.Draw(img).rounded_rectangle((0, 0, W - 1, H - 1), radius=26,
                                                 outline=(200, 200, 210), width=2)
        _base.update(mtime=mt, img=img)
    return _base["img"]


# ── LE JOURNAL DU MOBILE ────────────────────────────────────────────────────
def tail_lines(path, n, width):
    op = operator()
    if op["MODE"] == "docker":
        # [2026-09-05] `docker logs` NE MONTRE RIEN D UN OPERATEUR, exactement
        # comme pour le hub (voir HUB_LOGS plus bas, corrige le 2026-09-04) :
        # la pile est lancee par `docker exec` dans un tmux et sa sortie part
        # dans des FICHIERS, pas sur le flux standard du conteneur. Celui-ci ne
        # porte que les deux lignes de l entrypoint ("Initialisation du
        # peripherique TUN...", "Created symlink..."), et le cadre restait donc
        # fige sur elles depuis le demarrage - sur un operateur dont la radio
        # tournait parfaitement. On lit le fichier DANS le conteneur ; le chemin
        # est celui du RUN_DIR de la pile, et `docker logs` reste en dernier
        # recours pour une image qui lancerait l operateur autrement.
        data = ""
        for chemin in (path, "/tmp/osmo-nitb/logs/mobile.log"):
            try:
                out = subprocess.run(["docker", "exec", op["NAME"], "tail", "-n", str(n + 5), chemin],
                                     capture_output=True, text=True, timeout=4)
            except Exception as e:
                return [(f"{op['NAME']} : journal inaccessible ({type(e).__name__})", None)]
            if out.returncode == 0 and out.stdout.strip():
                data = out.stdout
                break
            if "permission denied" in (out.stderr or "").lower():
                return [("journal indisponible (docker : droit refuse -", None),
                        ("  le compte n est pas dans le groupe docker)", None)]
        if not data:
            try:
                r = subprocess.run(["docker", "logs", "--tail", str(n + 5), op["NAME"]],
                                   capture_output=True, text=True, timeout=3)
                data = (r.stdout + r.stderr)
            except Exception as e:
                return [(f"{op['NAME']} : journal inaccessible ({type(e).__name__})", None)]
    else:
        try:
            with open(path, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 16384))
                data = f.read().decode("utf-8", "replace")
        except OSError:
            return [(f"{os.path.basename(path)} : pas encore de journal", None)]
    # On garde la ligne BRUTE le temps d en lire la couleur, puis on la nettoie.
    brutes = [l for l in data.splitlines() if ANSI.sub("", l).strip()]
    out = []
    for brut in brutes[-n:]:
        col = couleur_ansi(brut)
        l = ANSI.sub("", brut).rstrip()
        # L horodatage osmocom (20260904135215721) mange 17 colonnes pour rien.
        l = re.sub(r"^\d{17}\s+", "", l)
        out.append((l[:width], col))
    return out or [("(journal vide)", None)]


# ── LE BANC : SPECTRE A GAUCHE, JOURNAL A DROITE ────────────────────────────
history = []


# ── LA VUE DU HUB : DU SS7, PAS UNE FFT ─────────────────────────────────────
# [2026-09-04] Quand les fleches se posent sur l inter-STP, l encart affichait
# le meme spectre I/Q qu un operateur - c est-a-dire RIEN, et pour une raison
# de fond : un hub M3UA n a pas de radio. Il n a pas de /psd a interroger, pas
# d ARFCN, pas de mobile.log. Une FFT vide sur le noeud central du banc, c est
# l ecran le plus inutile qu on puisse afficher au moment ou l on cherche
# justement pourquoi le SS7 ne passe pas.
#
# Ce qu un hub a, en revanche : une matrice de connectivite (qui parle a qui),
# ses ASP, ses routes, et un journal. C est ce qu on montre.
#
# La matrice vient du CACHE que remplit tools/conky-osmo-status.sh
# (--refresh-matrix, depuis checks/ss7_check.sh) : la mesure prend une minute,
# elle n a rien a faire dans une boucle de rendu a 1 Hz. On lit le meme fichier
# que le Conky - une mesure, deux affichages. Les balises ${colorN} du Conky
# sont retirees ici et rendues en couleurs Pillow.
MATRIX_FILE = os.path.join(OUT, "ss7-matrix")
CONKY_TAG = re.compile(r"\$\{color[0-9]?\}")
COUL_SS7 = {"self": (88, 166, 255), "via": (63, 185, 80), "FAIL": (248, 81, 73)}


def matrice_lignes():
    """Le cache de la matrice, sans les balises Conky. [] s il n existe pas."""
    try:
        with open(MATRIX_FILE) as f:
            return [CONKY_TAG.sub("", l.rstrip("\n")) for l in f if l.strip()]
    except OSError:
        return []


# Les endroits ou le hub ecrit, dans l ordre ou on les essaie.
#
# [2026-09-04] `docker logs osmo-inter-stp` rend VIDE, et c est normal : le
# conteneur a pour commande `sleep infinity`, et osmo-stp est lance APRES par
# `docker exec` dans un tmux, sa sortie passant par un `tee` vers un fichier.
# Rien de tout cela ne traverse le flux standard du conteneur - le cadre
# « journal » restait donc desesperement vide sur un hub qui tournait tres bien.
# On lit donc le fichier, DANS le conteneur ; docker logs reste en dernier
# recours, pour une image qui lancerait le STP autrement.
HUB_LOGS = ("/tmp/osmo-stp.log", "/var/log/osmocom/osmo-stp.log")


def hub_journal(nom, n, width):
    """Les dernieres lignes du STP du hub. Sans docker (ou sans droit), on le
    dit plutot que de laisser un cadre vide - un cadre vide se lit comme une
    panne du hub, alors que c est la sonde qui n a pas le bras assez long."""
    for chemin in HUB_LOGS:
        try:
            out = subprocess.run(["docker", "exec", nom, "tail", "-n", str(n), chemin],
                                 capture_output=True, text=True, timeout=4)
        except Exception as e:
            return [(f"journal indisponible : {e}", (212, 153, 34))]
        if out.returncode == 0 and out.stdout.strip():
            return [(ANSI.sub("", l)[:width], None) for l in out.stdout.splitlines()[-n:]]
        if "permission denied" in (out.stderr or "").lower():
            return [("journal indisponible (docker : droit refuse -",
                     (212, 153, 34)), ("  le compte n est pas dans le groupe docker)", (212, 153, 34))]
    try:
        out = subprocess.run(["docker", "logs", "--tail", str(n), nom],
                             capture_output=True, text=True, timeout=4)
        lignes = (out.stdout + out.stderr).splitlines()[-n:]
        if lignes:
            return [(ANSI.sub("", l)[:width], None) for l in lignes]
    except Exception:
        pass
    return [("pas de journal : " + " ni ".join(HUB_LOGS), (139, 148, 158)),
            ("le hub tourne-t-il ?  docker ps --filter name=" + nom, (139, 148, 158))]


def render_interstp(op):
    """L encart quand la selection est l inter-STP : matrice a gauche, journal
    du hub a droite. Meme cadre, memes marges et meme pied que la vue radio -
    seul le contenu change, pour que l oeil ne perde pas ses reperes en
    passant d un operateur au hub."""
    img = base_image().copy()
    d = ImageDraw.Draw(img)
    # ── LE PANNEAU COUVRE TOUT LE CADRE, BORDURE COMPRISE ───────────────────
    # [2026-09-04] Le rendu peignait son contenu EN RETRAIT de PAD (18 px), et
    # ces 18 px laissaient voir base_image() - c est-a-dire le morceau de fond
    # d ecran, donc le `glass_panel` que wallpaper-render.py y a peint : un
    # remplissage plus clair (20,24,36) et surtout une BORDURE (200,200,210).
    # A l ecran, cela dessinait un cadre clair arrondi tout autour de l encart -
    # « le rectangle ». Il ne venait ni de la barre GTK (dont le fond avait deja
    # ete supprime) ni du pied (dont la couleur avait deja ete alignee) : il
    # etait dans le fond d ecran, et l encart le laissait passer par ses marges.
    #
    # Quand le banc tourne, l encart est un panneau plein : il couvre TOUT le
    # cadre, meme rayon que celui du fond (26) pour tomber exactement dessus.
    # Le cadre du fond reste visible quand le banc est a l arret - c est alors
    # l image du jour qu il encadre, et la il a un sens.
    d.rounded_rectangle((0, 0, W - 1, H - 1), radius=26, fill=(8, 10, 14))
    x0, y0, x1, y1 = PAD, PAD, W - PAD, H - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=(8, 10, 14))
    split = x0 + int((x1 - x0) * 0.56)

    d.text((x0, y0), "Matrice de connectivite  ·  via inter-STP", font=F_TITLE, fill=(88, 166, 255))
    tag = f"PC {os.environ.get('MULTI_HUB_PC', '0.0.0')}"
    d.text((split - 12 - d.textlength(tag, font=F_SMALL), y0 + 2), tag, font=F_SMALL, fill=(63, 185, 80))

    lignes = matrice_lignes()
    yy = y0 + 30
    if not lignes:
        d.text((x0, yy), "premiere mesure en cours (checks/ss7_check.sh)...",
               font=F_SMALL, fill=(139, 148, 158))
    for ligne in lignes:
        xx = x0
        # Chaque mot est peint a sa couleur : self/via/FAIL portent le sens.
        for mot in re.split(r"(\s+)", ligne):
            if not mot:
                continue
            col = COUL_SS7.get(mot.strip(), (200, 208, 220))
            if mot.strip().startswith("SS7"):
                col = (63, 185, 80) if "OK" in ligne else (212, 153, 34)
            d.text((xx, yy), mot, font=F_LOG, fill=col)
            xx += d.textlength(mot, font=F_LOG)
        yy += 17
        if yy > y1 - 14:
            break

    # Le journal du hub, a droite, exactement ou vit celui du mobile.
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    d.text((lx0, y0), f"journal  ·  {op['NAME']}", font=F_TITLE, fill=(88, 166, 255))
    line_h = 15
    n = max(1, (y1 - (y0 + 26)) // line_h)
    cols = max(10, int((x1 - lx0) / 7.3))
    for i, (l, col) in enumerate(hub_journal(op["NAME"], n, cols)):
        if col is None:
            col = LOG_DEFAUT
            if re.search(r"error|fail|reject|lost|down", l, re.I):
                col = TANGO_VIF["31"]
            elif re.search(r"ASP|AS |active|established|route", l, re.I):
                col = TANGO_VIF["32"]
        d.text((lx0, y0 + 26 + i * line_h), l, font=F_LOG, fill=col)

    return img


def render_live(data):
    img = base_image().copy()
    d = ImageDraw.Draw(img)
    # ── LE PANNEAU COUVRE TOUT LE CADRE, BORDURE COMPRISE ───────────────────
    # [2026-09-04] Le rendu peignait son contenu EN RETRAIT de PAD (18 px), et
    # ces 18 px laissaient voir base_image() - c est-a-dire le morceau de fond
    # d ecran, donc le `glass_panel` que wallpaper-render.py y a peint : un
    # remplissage plus clair (20,24,36) et surtout une BORDURE (200,200,210).
    # A l ecran, cela dessinait un cadre clair arrondi tout autour de l encart -
    # « le rectangle ». Il ne venait ni de la barre GTK (dont le fond avait deja
    # ete supprime) ni du pied (dont la couleur avait deja ete alignee) : il
    # etait dans le fond d ecran, et l encart le laissait passer par ses marges.
    #
    # Quand le banc tourne, l encart est un panneau plein : il couvre TOUT le
    # cadre, meme rayon que celui du fond (26) pour tomber exactement dessus.
    # Le cadre du fond reste visible quand le banc est a l arret - c est alors
    # l image du jour qu il encadre, et la il a un sens.
    d.rounded_rectangle((0, 0, W - 1, H - 1), radius=26, fill=(8, 10, 14))
    x0, y0, x1, y1 = PAD, PAD, W - PAD, H - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=(8, 10, 14))
    split = x0 + int((x1 - x0) * 0.56)
    # Spectre
    d.text((x0, y0), "Spectre I/Q du mobile  ·  montant (UL)", font=F_TITLE, fill=(88, 166, 255))
    arfcn = data.get("arfcn", "?") if data else "?"
    tag = f"ARFCN {arfcn}"
    d.text((split - 12 - d.textlength(tag, font=F_SMALL), y0 + 2), tag, font=F_SMALL, fill=(63, 185, 80))
    sx0, sx1 = x0, split - 12
    sw = sx1 - sx0
    py0 = y0 + 24
    psd_h = 110
    py1 = py0 + psd_h
    d.rectangle((sx0, py0, sx1, py1), fill=(12, 16, 24))
    for gy in range(1, 4):
        yy = py0 + gy * psd_h // 4
        d.line((sx0, yy, sx1, yy), fill=(24, 30, 40))
    if data and "psd" in data:
        vals = resample(normalize(data["psd"], data.get("dr", 40)), sw)
        pts = [(sx0 + x, py1 - 1 - int(v * (psd_h - 4))) for x, v in enumerate(vals)]
        for x, y in pts:
            d.line((x, y, x, py1 - 1), fill=(30, 70, 110))
        d.line(pts, fill=(88, 210, 255), width=1)
        history.insert(0, vals)
    else:
        d.text((sx0 + 8, py0 + 8), "pas de flux", font=F_SMALL, fill=(248, 81, 73))
    # Chute d eau : une ligne par image, la plus recente en haut
    wy0 = py1 + 4
    wf_h = y1 - wy0
    del history[wf_h:]
    wf = Image.new("RGB", (sw, wf_h), (8, 10, 14))
    px = wf.load()
    for row, line in enumerate(history):
        for x in range(min(sw, len(line))):
            px[x, row] = inferno(line[x])
    img.paste(wf, (sx0, wy0))
    # Journal
    d = ImageDraw.Draw(img)
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    op = operator()
    d.text((lx0, y0), ("mobile.log  ·  QEMU MS#1" if op["MODE"] != "docker"
                       else f"journal  ·  {op['NAME']}"), font=F_TITLE, fill=(88, 166, 255))
    line_h = 15
    n = max(1, (y1 - (y0 + 26)) // line_h)
    cols = max(10, int((x1 - lx0) / 7.3))
    for i, (l, col) in enumerate(tail_lines(MOBILE_LOG, n, cols)):
        if col is None:
            # Journal sans couleurs (docker logs, redirection qui les a
            # mangees) : on retombe sur la lecture par mots-cles.
            col = LOG_DEFAUT
            if re.search(r"error|fail|reject|lost", l, re.I):
                col = TANGO_VIF["31"]
            elif re.search(r"attach|answer|call|SMS|proceed", l, re.I):
                col = TANGO_VIF["32"]
        d.text((lx0, y0 + 26 + i * line_h), l, font=F_LOG, fill=col)
    # ── LE PIED COUVRE JUSQU AU BAS, SANS RIEN LAISSER DEPASSER ─────────────
    # [2026-09-04] La barre s arretait a H - PAD + 4, et le commentaire d alors
    # l assumait : « la legende du strip est dessous ». Elle l etait, et ELLE SE
    # VOYAIT - une quinzaine de pixels de « NASA · Astronomy Picture of the Day
    # · 2026-09-04 · apod.nasa.gov », coupee en deux par le bord de l encart,
    # sous le spectre et le mobile.log. Une ligne orpheline en travers du
    # bureau, que rien n expliquait.
    #
    # Le panneau est construit SUR une copie du fond d ecran (base_image) : tout
    # ce que le rendu ne peint pas laisse voir le fond. On peint donc jusqu au
    # bord. Le rayon reste, mais le bas du rectangle sort du cadre (H + 8) :
    # l arrondi tombe hors de l image et le bas est franc, comme le bord de
    # l encart lui-meme.
    # [2026-09-04] LE PIED N EST PLUS D UNE AUTRE COULEUR QUE LE CORPS.
    # Il etait peint en (20,24,36) sous un corps en (8,10,14) : mesure sur
    # panel.png, c est une marche de douze niveaux, et elle dessinait une bande
    # claire en travers du bas de l encart - le « rectangle » qu on voyait
    # derriere les boutons, et qu on prenait pour un fond de la barre GTK. Ce
    # n en etait pas un : le fond de la barre avait deja ete supprime, la marche
    # etait dans l image. Meme couleur des deux cotes : un seul panneau.
    # Plus de legende : elle vivait dans la bande de pied, supprimee (FOOT = 0).
    # Ce qu elle disait - quel operateur, quel journal - est porte par les
    # boutons eux-memes (« Dashboard op2 », « VTY 4247 op2 ») et par le titre
    # de la colonne de droite.
    return img


def write(img):
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, ".panel.tmp.png")
    img.save(tmp, "PNG")
    os.replace(tmp, os.path.join(OUT, "panel.png"))


def main():
    print(f"[fft-snap] {URL} + {MOBILE_LOG} -> {OUT}/panel.png toutes les {PERIOD}s "
          f"(fondu {FADE_S}s depuis {WALLPAPER})", flush=True)
    alpha = 0.0
    step = PERIOD / FADE_S if FADE_S > 0 else 1.0
    last_state = None
    while True:
        t = time.time()
        op_courant = operator()
        # Le hub n a pas de /psd : l interroger ne rendrait jamais rien et
        # l encart resterait sur le strip. Sa vue est « prete » des qu il est
        # selectionne - c est la matrice et son journal qui font le contenu.
        if op_courant.get("MODE") == "interstp":
            data, ready = None, True
        else:
            data = None
            try:
                data = fetch("ms")
            except Exception:
                data = None
            ready = bool(data) and "psd" in data
        if ready != last_state:
            print(f"[fft-snap] banc {'pret : fondu vers le spectre' if ready else 'absent : retour au strip'}",
                  flush=True)
            last_state = ready
        target = 1.0 if ready else 0.0
        alpha = min(target, alpha + step) if target > alpha else max(target, alpha - step)
        try:
            if alpha <= 0.0:
                history.clear()
                write(base_image())
            else:
                live = (render_interstp(op_courant)
                        if op_courant.get("MODE") == "interstp" else render_live(data))
                # TOUJOURS un blend, meme a fondu termine : c est ce qui laisse
                # le strip transparaitre sous le banc. Sans strip derriere, rien
                # a laisser voir : opacite pleine.
                op = OPACITY if strip_present() else 1.0
                write(Image.blend(base_image(), live, alpha * op))
        except Exception as e:
            print(f"[fft-snap] rendu : {e}", file=sys.stderr, flush=True)
        time.sleep(max(0.2, PERIOD - (time.time() - t)))


if __name__ == "__main__":
    main()
