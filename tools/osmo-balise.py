#!/usr/bin/python3
# osmo-balise.py - THE BEACON ON TOP OF THE MAST FOLLOWS THE BENCH, on the
# user's OWN wallpaper (the city at sunset with its telecom tower).
#
#   osmo-balise suivre          the session daemon: every 2 s, the bench state
#                               -> the matching variant of the wallpaper
#   osmo-balise generer [IMAGE [JOUR]]
#                               (re)builds the variants (once, cached)
#   osmo-balise jour FICHIER    the DAY picture shown at rest (same scene, same
#                               size), copied next to the variants
#   osmo-balise etat            prints the bench state as seen here
#   osmo-balise poser ETAT      sets one variant by hand (repos, demarrage,
#                               demarre, echec)
#
# THE FOUR STATES
#   repos       bench stopped: THE DAY PICTURE when one is given ("osmo-balise
#               jour"), else the evening one with the beacon OFF and no waves
#   demarrage   the bench is starting (osmo-banc.service "activating", or the
#               core coming up by hand): beacon RED, no waves
#   demarre     the bench is up (osmo-banc.service "active", or MSC + BSC +
#               BTS alive): beacon GREEN, and the waves of the picture (fixed,
#               not animated)
#   echec       osmo-banc.service "failed": beacon RED, no waves
#
# THE VARIANTS are derived from the user's picture, which is NEVER modified:
#   - the waves (orange arcs on the sky on both sides of the mast) are erased:
#     for each row, the pixels clearly warmer or brighter than the median sky
#     of that row are masked, then filled by diffusion (the sky is smooth
#     there) - "demarre" takes the arcs back from the original;
#   - the beacon: its red glow is erased, then the lamp is drawn off, red or
#     green with its halo.
# Written to ~/.local/share/backgrounds/osmo-balise/<hash of the picture>/.
# Positions (beacon, wave zones) in ~/.config/osmo-balise.json, created for
# the picture in place the first time (defaults tuned for the 1426x1103
# "Coucher de soleil urbain et tour telecom").
#
# THE SYSTEM PICTURES (ISO, native install, update.sh): configs/osmo-balise-
# soir.png and configs/osmo-balise-jour.png are installed as soir.png and
# jour.png in /usr/share/backgrounds/osmo-balise/, with their variants already
# built in <hash>/ (no numpy needed at session time). Without a personal
# ~/.config/osmo-balise.json, those are the pictures; a personal variants
# folder wins over the system one.
#   OSMO_BALISE_SORTIE   where "generer" writes (the build writes the system
#                        variants with it)
#   OSMO_BALISE_CONF     the config file (default ~/.config/osmo-balise.json)
#
# THE WALLPAPER STAYS THE USER'S: the daemon only acts while the wallpaper is
# that picture or one of its variants. Another wallpaper chosen in the
# settings: nothing is touched (and "osmo-balise generer" adopts a new one).
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse

CONF = os.environ.get("OSMO_BALISE_CONF") or os.path.expanduser("~/.config/osmo-balise.json")
SORTIE = os.environ.get("OSMO_BALISE_SORTIE") or os.path.expanduser("~/.local/share/backgrounds/osmo-balise")
SYS = os.environ.get("OSMO_BALISE_SYS") or "/usr/share/backgrounds/osmo-balise"
ETATS = ("repos", "demarrage", "demarre", "echec")
DEFAUT = {"balise": [1204, 219], "rayon_balise": 12,
          "zones": [[930, 190, 1123, 505], [1271, 190, 1426, 505]]}


def gs(*args):
    try:
        return subprocess.run(["gsettings"] + list(args), capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def fond_actuel():
    uri = gs("get", "org.gnome.desktop.background", "picture-uri").strip("'")
    return urllib.parse.unquote(uri[7:]) if uri.startswith("file://") else uri


def conf():
    try:
        with open(CONF) as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    # no personal config: the system pictures, if installed
    soir, jour_ = os.path.join(SYS, "soir.png"), os.path.join(SYS, "jour.png")
    if not os.path.exists(soir):
        return {}
    c = dict(DEFAUT, image=soir)
    if os.path.exists(jour_):
        c["jour"] = jour_
    try:
        c["empreinte"] = empreinte(soir)
    except OSError:
        return {}
    return c


def ecrire_conf(c):
    if os.environ.get("OSMO_BALISE_CONF") == "-":
        return
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        json.dump(c, f, indent=1)


def empreinte(chemin):
    h = hashlib.sha256()
    with open(chemin, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()[:16]


def dossiers(c):
    """The variant folders for this picture: the personal one, then the system one."""
    return [os.path.join(d, c["empreinte"]) for d in dict.fromkeys((SORTIE, SYS))]


def complet(d):
    return all(os.path.exists(os.path.join(d, e + ".png")) for e in ETATS)


def dossier(c, ecrire=False):
    """The folder in use: the first complete one (the personal one to write)."""
    ds = dossiers(c)
    if not ecrire:
        for d in ds:
            if complet(d):
                return d
    return ds[0]


def variantes(c, ecrire=False):
    return {e: os.path.join(dossier(c, ecrire), e + ".png") for e in ETATS}


# ── the picture work (Pillow + numpy) ────────────────────────────────────────
def generer(image=None, jour_explicite=None):
    c = conf()
    actuel = fond_actuel() if image is None else ""
    explicite = image is not None
    image = image or c.get("image")
    if not explicite and (not image or (actuel and os.path.exists(actuel) and SORTIE not in actuel
                                        and SYS not in actuel and actuel not in (image, c.get("jour")))):
        image = actuel                      # adopt the wallpaper in place
    if not image or not os.path.exists(image):
        sys.exit("osmo-balise : pas d'image de fond (%r)" % image)
    if c.get("image") != image:
        c = dict(DEFAUT, image=image)
    for k, v in DEFAUT.items():
        c.setdefault(k, v)
    if jour_explicite:
        c["jour"] = jour_explicite
    c["empreinte"] = empreinte(image)
    # an explicit picture is built where asked (OSMO_BALISE_SORTIE), even if
    # the system folder already has it
    if complet(dossier(c, ecrire=explicite)):
        poser_jour(c)
        ecrire_conf(c)
        return c
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    v = variantes(c, ecrire=True)
    print("osmo-balise : variantes de %s ..." % image, flush=True)
    src = Image.open(image).convert("RGB")
    im = np.asarray(src).astype(np.float32)
    h, w, _ = im.shape
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    rb, lum = r - b, (r + g + b) / 3

    # 1. the waves: mask, then diffusion
    zone = np.zeros((h, w), bool)
    for x0, y0, x1, y1 in c["zones"]:
        zone[max(0, y0):min(h, y1 + 1), max(0, x0):min(w, x1 + 1)] = True
    masque = np.zeros((h, w), bool)
    for y in np.where(zone.any(axis=1))[0]:
        cols = np.where(zone[y])[0]
        sel = (rb[y, cols] > np.median(rb[y, cols]) + 18) | (lum[y, cols] > np.median(lum[y, cols]) + 25)
        masque[y, cols[sel]] = True
    masque = (np.asarray(Image.fromarray((masque * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9))) > 0) & zone

    # 2. the beacon's red glow, masked too
    bx, by = c["balise"]
    R = c["rayon_balise"]
    yy, xx = np.mgrid[0:h, 0:w]
    disque = (xx - bx) ** 2 + (yy - by) ** 2 <= R * R
    masque_b = disque & (rb > -10)
    tout = masque | masque_b

    cur = im.copy()
    for y in np.where(tout.any(axis=1))[0]:
        ok = ~tout[y] & (zone[y] | ((xx[y] - bx) ** 2 + (y - by) ** 2 <= (3 * R) ** 2))
        if ok.any():
            cur[y, tout[y]] = np.median(im[y, ok], axis=0)
    for _ in range(600):
        moy = (np.roll(cur, 1, 0) + np.roll(cur, -1, 0) + np.roll(cur, 1, 1) + np.roll(cur, -1, 1)) / 4
        cur[tout] = moy[tout]
    cur[tout] += np.random.default_rng(1).normal(0, 1.2, (int(tout.sum()), 3))
    sans = np.clip(cur, 0, 255).astype(np.uint8)
    # with the waves (the original), the beacon erased all the same
    avec = np.asarray(src).copy()
    avec[masque_b] = sans[masque_b]

    def lampe(fond, coeur, halo, eteinte=False):
        base = Image.fromarray(fond).convert("RGBA")
        cal = Image.new("RGBA", base.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(cal)
        if eteinte:
            d.ellipse((bx - 4, by - 4, bx + 4, by + 4), fill=(52, 56, 74, 255), outline=(30, 32, 44, 255))
            d.ellipse((bx - 2, by - 3, bx, by - 1), fill=(110, 116, 140, 200))
        else:
            for k in range(14, 0, -1):          # the halo, then the lamp
                a = int(150 * (1 - k / 14) ** 2)
                d.ellipse((bx - k - 3, by - k - 3, bx + k + 3, by + k + 3), fill=halo + (a,))
            d.ellipse((bx - 4, by - 4, bx + 4, by + 4), fill=coeur + (255,))
            d.ellipse((bx - 2, by - 3, bx, by - 1), fill=(255, 255, 255, 190))
        return Image.alpha_composite(base, cal).convert("RGB")

    os.makedirs(dossier(c, ecrire=True), exist_ok=True)
    rouge, halo_r = (255, 70, 50), (255, 60, 40)
    vert, halo_v = (90, 255, 120), (70, 255, 110)
    lampe(sans, None, None, eteinte=True).save(v["repos"])
    poser_jour(c)
    lampe(sans, rouge, halo_r).save(v["demarrage"])
    lampe(sans, rouge, halo_r).save(v["echec"])
    lampe(avec, vert, halo_v).save(v["demarre"])
    ecrire_conf(c)
    print("osmo-balise : %s" % dossier(c, ecrire=True), flush=True)
    return c


def poser_jour(c):
    """The day picture (if any) becomes the "repos" variant: a copy, the original may move."""
    j = c.get("jour")
    d = dossier(c)
    if j and os.path.exists(j) and os.access(d if os.path.isdir(d) else os.path.dirname(d) or ".", os.W_OK):
        dst = os.path.join(d, "repos.png")
        if os.path.abspath(j) == os.path.abspath(dst):
            return
        if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(j) and empreinte(dst) == empreinte(j):
            return
        os.makedirs(d, exist_ok=True)
        shutil.copyfile(j, dst)


def jour(fichier):
    fichier = os.path.abspath(fichier)
    if not os.path.exists(fichier):
        sys.exit("osmo-balise : %s absent" % fichier)
    c = conf()
    if not c.get("empreinte"):
        c = generer()
    c["jour"] = fichier
    poser_jour(c)
    ecrire_conf(c)
    print("osmo-balise : jour = %s (copie : %s)" % (fichier, variantes(c)["repos"]))


# ── the bench state ──────────────────────────────────────────────────────────
def vivants():
    noms = set()
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                with open("/proc/%s/comm" % d) as f:
                    noms.add(f.read().strip())
            except OSError:
                pass
    return noms


def etat_banc():
    try:
        svc = subprocess.run(["systemctl", "is-active", os.environ.get("OSMO_BANC_SERVICE", "osmo-banc.service")],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        svc = ""
    if svc in ("activating", "reloading"):
        return "demarrage"
    if svc == "active":
        return "demarre"
    if svc == "failed":
        return "echec"
    if svc == "deactivating":
        return "repos"
    # started by hand (start.sh, no service): from the processes
    p = vivants()
    coeur = {"osmo-msc", "osmo-bsc", "osmo-hlr", "osmo-stp"} & p
    if {"osmo-msc", "osmo-bsc"} <= p and ("osmo-bts-trx" in p or "osmo-bts-virtua" in p):
        return "demarre"
    if coeur:
        return "demarrage"
    return "repos"


def poser(e, c=None):
    c = c or conf()
    if not c.get("empreinte"):
        return False
    v = variantes(c)
    actuel = fond_actuel()
    if actuel not in (c.get("image"), c.get("jour")) and not any(actuel.startswith(d + "/") for d in dossiers(c)):
        return False                        # another wallpaper: the user's choice, left alone
    if actuel == v[e] or not os.path.exists(v[e]):
        return True
    uri = "file://" + urllib.parse.quote(v[e])
    gs("set", "org.gnome.desktop.background", "picture-uri", uri)
    gs("set", "org.gnome.desktop.background", "picture-uri-dark", uri)
    return True


def suivre():
    c = conf()
    if not c.get("empreinte") or not complet(dossier(c)):
        try:
            c = generer()
        except SystemExit as e:
            print(e, file=sys.stderr)
            return 1
    dernier = None
    while True:
        e = etat_banc()
        if e != dernier:
            if poser(e, c):
                print("osmo-balise : %s" % e, flush=True)
            dernier = e
        time.sleep(float(os.environ.get("OSMO_BALISE_PERIODE", "2")))


def main():
    a = sys.argv[1:] or ["suivre"]
    if a[0] == "generer":
        generer(a[1] if len(a) > 1 else None, a[2] if len(a) > 2 else None)
    elif a[0] == "jour" and len(a) > 1:
        jour(a[1])
    elif a[0] == "etat":
        print(etat_banc())
    elif a[0] == "poser" and len(a) > 1 and a[1] in ETATS:
        sys.exit(0 if poser(a[1]) else 1)
    elif a[0] == "suivre":
        sys.exit(suivre() or 0)
    else:
        sys.exit("usage : osmo-balise suivre | generer [IMAGE [JOUR]] | jour FICHIER | etat | poser %s" % "|".join(ETATS))


if __name__ == "__main__":
    main()
