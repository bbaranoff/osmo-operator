#!/usr/bin/env python3
# osmo-fft-snap.py - l ENCART VIVANT du bureau : le cadre du fond d ecran
# (tools/wallpaper-render.py, boite 510,220-1410,1010 en 1920x1080), en DEUX
# MOITIES, chacune FONDANT vers son banc une fois qu il est pret :
#
#   +-----------------------------------------------------------+
#   |  Spectre I/Q du UE srsRAN (montant) |  console srsUE      |   4G
#   |  spectre + chute d eau (ZMQ 2001)   |  (tmux srsran:ue)   |
#   +-----------------------------------------------------------+
#   |  Spectre I/Q du mobile (montant)    |  mobile.log (QEMU)  |   2G
#   |  spectre + chute d eau              |  dernieres lignes   |
#   +-----------------------------------------------------------+
#
# [2026-09-08] DEUX MOITIES, DEUX BANCS, DEUX IMAGES. Le cadre ne portait que
# la 2G ; la 4G du banc (srsENB / srsUE par ZeroMQ) n avait aucune place a
# l ecran. Le cadre a donc grandi vers le haut (410 -> 790 px) et s est coupe
# en deux : le haut est a la 4G, le bas a la 2G. Chaque moitie a SON fondu :
# tant que son banc n est pas la, elle montre la bande dessinee que le fond
# d ecran porte a cet endroit (deux images : une BD geek au hasard en haut,
# Calvin & Hobbes en bas - tools/osmo-wallpaper.sh). Un banc allume, une
# moitie vivante ; les deux, tout l encart.
#
# LA 4G S ECOUTE SANS RIEN LUI PRENDRE. La radio virtuelle de srsRAN est du
# ZeroMQ en REQ/REP : celui qui recoit DEMANDE des echantillons, et celui qui
# emet les lui REPOND - une fois. Un troisieme qui viendrait demander sur le
# port de l UE (2001) VOLERAIT des reponses a l eNB, qui n aurait plus l
# uplink entier : attach rate, et avec fail_on_disconnect sa radio s arrete.
# On n ouvre donc AUCUNE socket ZeroMQ. On lit le trafic TCP de l interface
# de bouclage en prise brute (AF_PACKET, d ou l unite en root), on suit le
# flux du port 2001 et on y decoupe les trames ZMTP : chaque reponse de l UE
# est [trame vide][trame longue = N echantillons complex64]. Rien n est
# renvoye, rien n est consomme : srsue et srsenb ne peuvent pas s en
# apercevoir. Le UE n emet que par rafales (PRACH, PUSCH...), et 11,52 MS/s
# font 92 Mo/s sur le bouclage : on ne lit qu une fenetre de 250 ms par image
# et on garde la CRETE de chaque case du spectre sur cette fenetre, sinon on
# ne verrait que du silence entre deux rafales.
#
# Source FFT 2G : le dashboard, http://127.0.0.1:8080/psd?src=ms - le meme
# JSON que l onglet FFT (vue fft1) : freqs, psd (dB), dr, arfcn. Le journal :
# le mobile.log de la pile (QEMU MS#1), lu par la queue. Cote 4G, le journal
# est la console de srsue, capturee dans le tmux « srsran » qui le porte
# (tools/osmo-lte.sh), et /tmp/ue.log a defaut.
#
#   /run/osmo-fft/panel.png   900x790   (coordonnees du fond ; osmo-panel.py
#                                        le met a l echelle de l ecran)
#
# Lance par osmo-fft-snap.service. Ne depend que de Pillow et des polices
# DejaVu, presents sur l image comme sur l hote ; numpy pour la FFT 4G (sans
# lui, la moitie haute le dit et reste sur sa bande dessinee).
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
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
# La boite de l encart dans le fond d ecran (wallpaper-render.py, main()) :
# LES QUATRE FICHIERS QUI LA CONNAISSENT DOIVENT RESTER D ACCORD -
# wallpaper-render.py, osmo-fft-snap.py, osmo-panel.py, osmo-launcher.py.
BOX = (510, 220, 1410, 1010)
W, H = BOX[2] - BOX[0], BOX[3] - BOX[1]
# Les deux moities, en coordonnees de l image : (y haut, y bas). Le fond
# d ecran dessine deux cadres separes par ECART px (les deux images), et
# chaque moitie vivante recouvre exactement le sien.
ECART = 8
HH = (H - ECART) // 2
HAUT = (0, HH)
BAS = (H - HH, H)
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
            for m in (HAUT, BAS):     # les deux cadres, comme le fond les dessine
                ImageDraw.Draw(img).rounded_rectangle((0, m[0], W - 1, m[1] - 1), radius=26,
                                                     outline=(200, 200, 210), width=2)
        _base.update(mtime=mt, img=img)
    return _base["img"]


def base_moitie(m):
    """Le morceau de fond sous une moitie de l encart (HAUT ou BAS)."""
    return base_image().crop((0, m[0], W, m[1]))


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
    img = base_moitie(BAS).copy()
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
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=(8, 10, 14))
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
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
    img = base_moitie(BAS).copy()
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
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=(8, 10, 14))
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
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


# ── LA 4G : LE UE srsRAN, ECOUTE EN PRISE BRUTE SUR LE BOUCLAGE ─────────────
# Voir l entete : pas de socket ZeroMQ, on lit le TCP du port de l UE tel
# qu il passe sur lo et on y decoupe les trames ZMTP. Reglages :
#   OSMO_LTE_TAP_PORT    le port ZMQ « tx » de srsue (2001 ; 2000 = l eNB,
#                        donc le descendant, pour qui prefere le voir)
#   OSMO_LTE_TAP_IFACE   l interface (lo)
#   OSMO_LTE_TAP_WINDOW  la fenetre d ecoute par image, en s (0.25)
#   OSMO_SRSRAN_UE_CONF  le ue.conf a lire pour l EARFCN et la cadence
#   OSMO_SRSRAN_TMUX     le tmux (-L) qui porte srsue, fenetre « ue »
#   OSMO_SRSRAN_UE_LOG   le journal de srsue, a defaut du tmux
LTE_PORT = int(os.environ.get("OSMO_LTE_TAP_PORT", "2001"))
LTE_IFACE = os.environ.get("OSMO_LTE_TAP_IFACE", "lo")
LTE_FENETRE = float(os.environ.get("OSMO_LTE_TAP_WINDOW", "0.25"))
LTE_NFFT = 1024
LTE_UE_CONF = os.environ.get("OSMO_SRSRAN_UE_CONF", "/root/.config/srsran/ue.conf")
LTE_TMUX = os.environ.get("OSMO_SRSRAN_TMUX", "srsran")
LTE_UE_LOG = os.environ.get("OSMO_SRSRAN_UE_LOG", "/tmp/ue.log")
# Le marqueur d une reponse ZMTP de l UE : la trame vide du REQ/REP (0x01 =
# « il y en a une autre », taille 0), puis l en-tete d une trame longue (0x02,
# taille sur 8 octets grand-boutiste, dont les cinq premiers sont nuls tant
# qu elle fait moins de 2^24 octets - une trame d une seconde en ferait 92 M).
ZMTP_MARQUE = b"\x01\x00\x02\x00\x00\x00\x00\x00"
try:
    import numpy as np
except ImportError:      # la moitie 4G le dira ; la 2G n en a pas besoin
    np = None


def _tcp_ecoute(port):
    """Quelqu un ecoute-t-il ce port TCP ? (lecture de /proc/net/tcp, sans privilege)"""
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(f) as fh:
                next(fh)
                for l in fh:
                    c = l.split()
                    if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == port:
                        return True
        except (OSError, StopIteration, ValueError, IndexError):
            pass
    return False


def srsran_ue_conf():
    """{'earfcn', 'srate'} d apres ue.conf ; des defauts raisonnables sinon."""
    conf = {"earfcn": "?", "srate": 11.52e6}
    try:
        section = ""
        with open(LTE_UE_CONF) as fh:
            for l in fh:
                l = l.strip()
                if l.startswith("["):
                    section = l
                elif l.startswith("dl_earfcn") and section == "[rat.eutra]":
                    conf["earfcn"] = l.split("=", 1)[1].strip()
                elif l.startswith("device_args"):
                    m = re.search(r"base_srate=([0-9.eE+]+)", l)
                    if m:
                        conf["srate"] = float(m.group(1))
    except (OSError, ValueError):
        pass
    return conf


class SondeLte(threading.Thread):
    """Ecoute la moitie 4G : etat = {psd (dB, LTE_NFFT cases, centre au milieu),
    crete (amplitude max vue), trames, erreur, t}. Ne tourne que si le port
    de l UE est ouvert - sinon rien a ecouter, et rien a ouvrir."""

    def __init__(self):
        super().__init__(daemon=True)
        self.etat = {"psd": None, "crete": 0.0, "trames": 0, "erreur": None, "t": 0.0}
        self.hann = (np.hanning(LTE_NFFT).astype(np.float32) if np is not None else None)

    def run(self):
        while True:
            if np is None:
                self.etat = dict(self.etat, psd=None, erreur="numpy absent : pas de FFT 4G")
                time.sleep(10)
                continue
            if not _tcp_ecoute(LTE_PORT):
                self.etat = dict(self.etat, psd=None, trames=0, erreur=None)
                time.sleep(PERIOD)
                continue
            try:
                self.capture()
            except PermissionError:
                self.etat = dict(self.etat, psd=None, erreur="prise brute refusee : root (CAP_NET_RAW) requis")
                time.sleep(10)
            except Exception as e:
                self.etat = dict(self.etat, psd=None, erreur=f"sonde : {type(e).__name__}: {e}")
                time.sleep(2)
            time.sleep(max(0.1, PERIOD - LTE_FENETRE))

    def capture(self):
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
        try:
            s.bind((LTE_IFACE, 0))
            s.settimeout(0.2)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
            buf, attendu, crete_psd, crete, trames = b"", None, None, 0.0, 0
            fin = time.time() + LTE_FENETRE
            while time.time() < fin:
                try:
                    pkt, adr = s.recvfrom(70000)
                except socket.timeout:
                    continue
                # Sur lo chaque paquet passe deux fois (sortant puis entrant) :
                # on ne garde que l entrant (pkttype 4 = PACKET_OUTGOING).
                if adr[2] == 4 or len(pkt) < 34 or pkt[12:14] != b"\x08\x00" or pkt[23] != 6:
                    continue
                tcp = 14 + (pkt[14] & 0xF) * 4
                sport, _dport, seq = struct.unpack("!HHI", pkt[tcp:tcp + 8])
                if sport != LTE_PORT:
                    continue
                charge = pkt[tcp + (pkt[tcp + 12] >> 4) * 4:]
                if not charge:
                    continue
                if attendu is not None and seq != attendu:
                    buf = b""            # trou dans le flux : on resynchronise
                attendu = (seq + len(charge)) & 0xFFFFFFFF
                buf += charge
                while True:
                    i = buf.find(ZMTP_MARQUE)
                    if i < 0:
                        buf = buf[-len(ZMTP_MARQUE):]
                        break
                    taille = int.from_bytes(buf[i + 3:i + 11], "big")
                    if taille % 8 or taille > (64 << 20):
                        buf = buf[i + 1:]            # faux marqueur dans les donnees
                        continue
                    if len(buf) < i + 11 + taille:
                        buf = buf[i:]
                        break
                    x = np.frombuffer(buf[i + 11:i + 11 + taille], dtype=np.complex64)
                    buf = buf[i + 11 + taille:]
                    n = len(x) // LTE_NFFT
                    if n == 0:
                        continue
                    trames += 1
                    blocs = x[:n * LTE_NFFT].reshape(n, LTE_NFFT) * self.hann
                    p = np.abs(np.fft.fftshift(np.fft.fft(blocs, axis=1), axes=1)) ** 2
                    p = p.max(axis=0) / (LTE_NFFT * LTE_NFFT)
                    crete_psd = p if crete_psd is None else np.maximum(crete_psd, p)
                    crete = max(crete, float(np.max(np.abs(x))))
        finally:
            s.close()
        if trames == 0:
            self.etat = dict(self.etat, psd=None, trames=0, erreur=None, t=time.time())
        else:
            self.etat = {"psd": (10 * np.log10(crete_psd + 1e-20)).tolist(), "crete": crete,
                         "trames": trames, "erreur": None, "t": time.time()}


def srsran_journal(n, width):
    """Les dernieres lignes de la console de srsue : la fenetre « ue » du tmux
    qui le porte, et le journal fichier a defaut."""
    try:
        out = subprocess.run(["tmux", "-L", LTE_TMUX, "capture-pane", "-p", "-t", f"{LTE_TMUX}:ue"],
                             capture_output=True, text=True, timeout=2)
        lignes = [ANSI.sub("", l).rstrip() for l in out.stdout.splitlines()]
        lignes = [l for l in lignes if l.strip()]
        if out.returncode == 0 and lignes:
            return [(l[:width], None) for l in lignes[-n:]]
    except Exception:
        pass
    try:
        with open(LTE_UE_LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 16384))
            data = f.read().decode("utf-8", "replace")
        lignes = [ANSI.sub("", l).rstrip() for l in data.splitlines() if l.strip()]
        if lignes:
            return [(l[:width], None) for l in lignes[-n:]]
    except OSError:
        pass
    return [("console srsue introuvable :", (139, 148, 158)),
            (f"  ni tmux -L {LTE_TMUX} (fenetre ue), ni {LTE_UE_LOG}", (139, 148, 158))]


historique_lte = []


def render_lte(etat):
    """La moitie haute : le spectre montant du UE srsRAN a gauche, sa console a
    droite. Meme cadre, memes marges que la 2G : un seul encart, deux bancs."""
    img = base_moitie(HAUT).copy()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=(8, 10, 14))
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=(8, 10, 14))
    split = x0 + int((x1 - x0) * 0.56)
    conf = srsran_ue_conf()
    d.text((x0, y0), "Spectre I/Q du UE srsRAN  ·  UL", font=F_TITLE, fill=(88, 166, 255))
    tag = f"EARFCN {conf['earfcn']} · ZMQ {LTE_PORT}"
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
    # L axe : la cadence, de -srate/2 a +srate/2 autour de la porteuse.
    demi = conf["srate"] / 2e6
    for k, frac in ((f"-{demi:.2f}", 0.0), ("0", 0.5), (f"+{demi:.2f} MHz", 1.0)):
        tx = sx0 + int(frac * sw)
        tx = min(max(tx - d.textlength(k, font=F_SMALL) * frac, sx0), sx1 - d.textlength(k, font=F_SMALL))
        d.text((tx, py1 + 2), k, font=F_SMALL, fill=(90, 100, 120))
    psd = etat.get("psd")
    if etat.get("erreur"):
        d.text((sx0 + 8, py0 + 8), etat["erreur"], font=F_SMALL, fill=(248, 81, 73))
        vals = None
    elif psd is None:
        d.text((sx0 + 8, py0 + 8), "pas de flux (l eNB ne demande rien a l UE)", font=F_SMALL,
               fill=(248, 81, 73))
        vals = None
    else:
        # Echelle : le haut suit la crete, jamais sous -60 dB - ainsi le
        # silence entre deux rafales reste a plat au lieu d etre etire.
        haut = max(max(psd), -60.0)
        vals = resample([min(1.0, max(0.0, (p - (haut - 50)) / 50)) for p in psd], sw)
        pts = [(sx0 + x, py1 - 1 - int(v * (psd_h - 4))) for x, v in enumerate(vals)]
        for x, y in pts:
            d.line((x, y, x, py1 - 1), fill=(30, 70, 110))
        d.line(pts, fill=(88, 210, 255), width=1)
        if etat.get("crete", 0.0) < 1e-6:
            d.text((sx0 + 8, py0 + 8), "silence : le UE n emet pas (veille)", font=F_SMALL,
                   fill=(139, 148, 158))
    historique_lte.insert(0, vals if vals is not None else [0.0] * sw)
    wy0 = py1 + 18
    wf_h = y1 - wy0
    del historique_lte[wf_h:]
    wf = Image.new("RGB", (sw, wf_h), (8, 10, 14))
    px = wf.load()
    for row, line in enumerate(historique_lte):
        for x in range(min(sw, len(line))):
            px[x, row] = inferno(line[x])
    img.paste(wf, (sx0, wy0))
    d = ImageDraw.Draw(img)
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    d.text((lx0, y0), "console srsUE  ·  tmux srsran:ue", font=F_TITLE, fill=(88, 166, 255))
    line_h = 15
    n = max(1, (y1 - (y0 + 26)) // line_h)
    cols = max(10, int((x1 - lx0) / 7.3))
    for i, (l, col) in enumerate(srsran_journal(n, cols)):
        if col is None:
            col = LOG_DEFAUT
            if re.search(r"reject|fail|error|release|lost|timeout", l, re.I):
                col = TANGO_VIF["31"]
            elif re.search(r"attach|found (plmn|cell)|complete|connected|network attach", l, re.I):
                col = TANGO_VIF["32"]
        d.text((lx0, y0 + 26 + i * line_h), l, font=F_LOG, fill=col)
    return img


def write(img):
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, ".panel.tmp.png")
    img.save(tmp, "PNG")
    os.replace(tmp, os.path.join(OUT, "panel.png"))


def main():
    print(f"[fft-snap] {URL} + {MOBILE_LOG} (2G, bas) + prise brute {LTE_IFACE}:{LTE_PORT} (4G, haut)"
          f" -> {OUT}/panel.png toutes les {PERIOD}s (fondu {FADE_S}s depuis {WALLPAPER})", flush=True)
    sonde = SondeLte()
    sonde.start()
    # Un fondu par moitie : « bas » suit la 2G (ou le hub), « haut » la 4G.
    alpha = {"bas": 0.0, "haut": 0.0}
    step = PERIOD / FADE_S if FADE_S > 0 else 1.0
    last_state = {"bas": None, "haut": None}
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
        # La 4G est « la » des que srsue tient son port ZMQ : le spectre peut
        # etre vide (pas de rafale), mais l encart montre alors ce silence,
        # avec la console de l UE a cote - ce qu on veut voir quand on attend
        # l attach, justement.
        prets = {"bas": ready, "haut": _tcp_ecoute(LTE_PORT)}
        for m, nom in (("bas", "banc 2G"), ("haut", "banc 4G (srsue)")):
            if prets[m] != last_state[m]:
                print(f"[fft-snap] {nom} {'pret : fondu vers le spectre' if prets[m] else 'absent : retour a la bande dessinee'}",
                      flush=True)
                last_state[m] = prets[m]
            target = 1.0 if prets[m] else 0.0
            alpha[m] = (min(target, alpha[m] + step) if target > alpha[m]
                        else max(target, alpha[m] - step))
        try:
            img = base_image().copy()
            # TOUJOURS un blend, meme a fondu termine : c est ce qui laisse
            # le strip transparaitre sous le banc. Sans strip derriere, rien
            # a laisser voir : opacite pleine.
            op = OPACITY if strip_present() else 1.0
            if alpha["bas"] <= 0.0:
                history.clear()
            else:
                live = (render_interstp(op_courant)
                        if op_courant.get("MODE") == "interstp" else render_live(data))
                img.paste(Image.blend(base_moitie(BAS), live, alpha["bas"] * op), (0, BAS[0]))
            if alpha["haut"] <= 0.0:
                historique_lte.clear()
            else:
                live = render_lte(sonde.etat)
                img.paste(Image.blend(base_moitie(HAUT), live, alpha["haut"] * op), (0, HAUT[0]))
            write(img)
        except Exception as e:
            print(f"[fft-snap] rendu : {e}", file=sys.stderr, flush=True)
        time.sleep(max(0.2, PERIOD - (time.time() - t)))


if __name__ == "__main__":
    main()
