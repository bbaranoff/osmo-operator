#!/usr/bin/env python3
# osmo-fond.py - LE FOND D ECRAN DU BANC, EN DEUX ETATS, AVEC UN FONDU ENTRE LES DEUX.
#
#   osmo-fond ville        le bureau au repos : la ville au bord de l eau, sans
#                          antenne (configs/gsm-lab-ville.jpg)
#   osmo-fond antenne      un banc tourne : la MEME ville, le pylone 2G/4G
#                          dresse devant, les icones qui montent
#                          (configs/gsm-lab-antenne.jpg)
#   osmo-fond etat         affiche l etat courant (ville / antenne / autre)
#   osmo-fond <fichier>    n importe quelle image, meme fondu
#
#   --duree S     longueur du fondu (defaut 2.4 s) ; --sec : pas de fondu
#   --pas N       nombre d images intermediaires (defaut 12)
#
# [2026-10-12] POURQUOI. Le bureau montrait l antenne en permanence. Choix du
# banc : au repos, la ville seule ; quand on LANCE la 2G (run standalone) ou
# la 4G (run multi), l antenne se dresse dans le paysage - en fondu, pas d un
# coup - et elle repart quand tout s eteint. Deux appelants :
#   - tools/osmo-launcher.py, au CLIC sur un run (immediat, avant meme que le
#     service soit debout) ;
#   - tools/osmo-panel.py, qui sait deja quand un banc monte ou tombe
#     (montrer(actif)) : couvre un lancement depuis un terminal, et le retour
#     a la ville a l arret.
# Les deux peuvent se suivre de pres : l outil est IDEMPOTENT (deja sur la
# cible : rien), et un seul fondu a la fois par session (verrou).
#
# COMMENT. GNOME Shell fait lui-meme un petit fondu croise (~1 s) a chaque
# changement de picture-uri. On s appuie dessus et on l allonge : Pillow rend N
# images intermediaires (melange lineaire des deux fonds) dans
# $XDG_RUNTIME_DIR/osmo-fond/, et on les pousse une a une par gsettings, a
# intervalle regulier ; la derniere valeur posee est le VRAI fichier
# (/usr/share/backgrounds/gsm-lab-*.jpg), pas une image de cache. Les images
# sont gardees (tmpfs, quelques Mo) : le fondu inverse les relit a l envers.
#
# UTILISATEUR. gsettings parle au bus de SESSION : l outil doit tourner comme
# l utilisateur du bureau. Lance en root (start-docker.sh, un service), il se relance
# lui-meme sous le compte qui a un gnome-shell et un /run/user/<uid>/bus.
import argparse
import fcntl
import hashlib
import os
import pwd
import signal
import subprocess
import sys
import time
from urllib.parse import quote, unquote, urlparse

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
BG_DIR = "/usr/share/backgrounds"
# Nom -> fichier pose par l install (80-chroot.sh / 80-bureau.sh), sinon le depot.
ETATS = {
    "ville":   ("gsm-lab-ville.jpg",   "le bureau au repos"),
    "antenne": ("gsm-lab-antenne.jpg", "un banc tourne"),
}
SCHEMA = "org.gnome.desktop.background"
CLES = ("picture-uri", "picture-uri-dark")


def dire(msg):
    print("[fond] " + msg, flush=True)


def fichier_etat(nom):
    f = ETATS[nom][0]
    for d in (BG_DIR, os.path.join(REPO, "configs")):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            return p
    return None


# ── tourner comme l utilisateur du bureau ────────────────────────────────────
def _session_bus(uid):
    p = "/run/user/%d/bus" % uid
    return "unix:path=" + p if os.path.exists(p) else None


def se_relancer_en_utilisateur():
    """Root sans bus de session : trouver le bureau et se relancer dessous."""
    if os.geteuid() != 0:
        return
    if os.environ.get("DBUS_SESSION_BUS_ADDRESS") and _session_bus(0):
        return                      # le bureau est a root (la cle live)
    candidats = []
    su = os.environ.get("SUDO_USER")
    if su:
        candidats.append(su)
    try:
        out = subprocess.run(["ps", "-eo", "user:32=,comm="], capture_output=True, text=True).stdout
        candidats += [l.split()[0] for l in out.splitlines() if l.strip().endswith("gnome-shell")]
    except OSError:
        pass
    for nom in candidats:
        try:
            pw = pwd.getpwnam(nom)
        except KeyError:
            continue
        bus = _session_bus(pw.pw_uid)
        if not bus:
            continue
        if pw.pw_uid == 0:
            os.environ["DBUS_SESSION_BUS_ADDRESS"] = bus
            os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/0")
            return
        env = {"DBUS_SESSION_BUS_ADDRESS": bus, "XDG_RUNTIME_DIR": "/run/user/%d" % pw.pw_uid,
               "HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name,
               "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
               "OSMO_REPO": REPO, "OSMO_FOND_RELANCE": "1"}
        os.execvp("runuser", ["runuser", "-u", pw.pw_name, "--", "env"] +
                  ["%s=%s" % kv for kv in env.items()] +
                  [sys.executable, os.path.abspath(__file__)] + sys.argv[1:])
    dire("aucun bureau GNOME trouve : rien a faire")
    sys.exit(0)


# ── gsettings ────────────────────────────────────────────────────────────────
def gs_get(cle):
    try:
        v = subprocess.run(["gsettings", "get", SCHEMA, cle], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return v.strip("'")


def gs_set(uri):
    for cle in CLES:
        subprocess.run(["gsettings", "set", SCHEMA, cle, uri], timeout=5)


def uri_de(path):
    return "file://" + quote(os.path.abspath(path))


def chemin_de(uri):
    if not uri.startswith("file://"):
        return None
    return unquote(urlparse(uri).path)


def etat_courant():
    """(etat, chemin) : ville / antenne / « <cible> en cours » (image d un fondu
    interrompu - un osmo-fond tue en plein vol, cf. start-native.sh
    killall_python) / autre."""
    p = chemin_de(gs_get("picture-uri")) or ""
    for nom, (f, _) in ETATS.items():
        if os.path.basename(p) == f:
            return nom, p
    for nom in ETATS:
        if "/osmo-fond/" in p and os.path.basename(p).startswith(nom + "-"):
            return nom + " en cours", p
    return "autre", p


# ── le fondu ─────────────────────────────────────────────────────────────────
def _cache_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    if not os.path.isdir(base):
        base = "/tmp"
    d = os.path.join(base, "osmo-fond")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def rendre_etapes(src, dst, pas, cible):
    """Les images intermediaires src -> dst (sans les deux bouts) ; None si impossible."""
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        a = Image.open(src).convert("RGB")
        b = Image.open(dst).convert("RGB")
    except OSError:
        return None
    if a.size != b.size:
        # ramener la source au format de la cible, en « zoom » comme GNOME
        W, H = b.size
        r = max(W / a.width, H / a.height)
        a = a.resize((max(1, round(a.width * r)), max(1, round(a.height * r))), Image.LANCZOS)
        l, t = (a.width - W) // 2, (a.height - H) // 2
        a = a.crop((l, t, l + W, t + H))
    key = hashlib.sha1(("%s:%s:%s:%s:%d" % (src, os.path.getmtime(src), dst, os.path.getmtime(dst), pas)).encode()).hexdigest()[:10]
    d = _cache_dir()
    etapes = []
    for i in range(1, pas):
        p = os.path.join(d, "%s-%s-%02d.jpg" % (cible, key, i))
        if not os.path.isfile(p):
            Image.blend(a, b, i / pas).save(p, quality=88)
        etapes.append(p)
    return etapes


def poser(cible, duree, pas, sec):
    nom = cible if cible in ETATS else "autre"
    dst = fichier_etat(cible) if cible in ETATS else os.path.abspath(cible)
    if not dst or not os.path.isfile(dst):
        dire("image introuvable : %s" % (dst or cible))
        return 1
    etat, src = etat_courant()
    if (etat == nom and nom != "autre") or (src and os.path.abspath(src) == dst):
        dire("deja « %s » : rien a faire" % nom)
        return 0
    # un fondu interrompu : on repart de l image ou il s est arrete (src)
    # un seul fondu a la fois par session
    verrou = open(os.path.join(_cache_dir(), "verrou"), "w")
    try:
        fcntl.flock(verrou, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        dire("un fondu est deja en cours")
        return 0
    etapes = None
    if not sec and duree > 0 and pas > 1 and src and os.path.isfile(src):
        etapes = rendre_etapes(src, dst, pas, nom)
    try:
        if etapes:
            dire("fondu %s -> %s (%d images, %.1f s)" % (etat, nom, len(etapes), duree))
            dt = duree / (len(etapes) + 1)
            for p in etapes:
                gs_set(uri_de(p))
                time.sleep(dt)
        else:
            dire("%s -> %s (fondu GNOME seul)" % (etat, nom))
    finally:
        # quoi qu il arrive (erreur, SIGTERM), le VRAI fichier est pose
        gs_set(uri_de(dst))
    return 0


def main():
    ap = argparse.ArgumentParser(description="fond d ecran du banc : ville / antenne, en fondu")
    ap.add_argument("cible", help="ville | antenne | etat | <fichier image>")
    ap.add_argument("--duree", type=float, default=2.4, help="duree du fondu en secondes (defaut 2.4)")
    ap.add_argument("--pas", type=int, default=12, help="images intermediaires (defaut 12)")
    ap.add_argument("--sec", action="store_true", help="sans fondu")
    a = ap.parse_args()
    se_relancer_en_utilisateur()
    # SIGTERM pendant le fondu : le finally de poser() pose la cible
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    if a.cible == "etat":
        etat, p = etat_courant()
        print("%s\t%s" % (etat, p))
        return 0
    return poser(a.cible, a.duree, a.pas, a.sec)


if __name__ == "__main__":
    sys.exit(main())
