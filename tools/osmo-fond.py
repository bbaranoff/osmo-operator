#!/usr/bin/env python3
# osmo-fond.py - THE BENCH WALLPAPER, IN TWO STATES, WITH A FADE BETWEEN THEM.
#
#   osmo-fond ville        the idle desktop: the city by the water, without
#                          antenna (configs/gsm-lab-ville.jpg)
#   osmo-fond antenne      a bench is running: the SAME city, the 2G/4G mast
#                          raised in front, the icons going up
#                          (configs/gsm-lab-antenne.jpg)
#   osmo-fond etat         prints the current state (ville / antenne / autre)
#   osmo-fond <file>       any image, same fade
#
#   --duree S     length of the fade (default 2.4 s); --sec: no fade
#   --pas N       number of intermediate images (default 12)
#
# WHY. Bench choice: idle, the city alone; when the 2G (standalone run) or
# the 4G (multi run) is STARTED, the antenna rises in the landscape - with a
# fade, not at once - and it goes away when everything stops. Two callers:
#   - tools/osmo-launcher.py, on the CLICK on a run (immediately, even before
#     the service is up);
#   - tools/osmo-panel.py, which already knows when a bench goes up or down
#     (montrer(actif)): covers a launch from a terminal, and the return to
#     the city on stop.
#
# Both may follow each other closely: the tool is IDEMPOTENT (already on the
# target: nothing), and only one fade at a time per session (lock).
#
# HOW. GNOME Shell itself does a short cross-fade (~1 s) on every change of
# picture-uri. It is relied upon and stretched: Pillow renders N intermediate
# images (linear blend of the two wallpapers) in
# $XDG_RUNTIME_DIR/osmo-fond/, pushed one by one through gsettings at a
# regular interval; the last value set is the REAL file
# (/usr/share/backgrounds/gsm-lab-*.jpg), not a cache image. The images are
# kept (tmpfs, a few MB): the reverse fade reads them backwards.
#
# USER. gsettings talks to the SESSION bus: the tool must run as the desktop
# user. Started as root (start-docker.sh, a service), it re-executes itself
# under the account that has a gnome-shell and a /run/user/<uid>/bus.
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
# Name -> file installed by the install (80-chroot.sh / 80-bureau.sh), else the repo.
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


# ── run as the desktop user ──────────────────────────────────────────────────
def _session_bus(uid):
    p = "/run/user/%d/bus" % uid
    return "unix:path=" + p if os.path.exists(p) else None


def se_relancer_en_utilisateur():
    """Root without a session bus: find the desktop and re-execute under it."""
    if os.geteuid() != 0:
        return
    if os.environ.get("DBUS_SESSION_BUS_ADDRESS") and _session_bus(0):
        return                      # the desktop belongs to root (the live key)
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
    """(state, path): ville / antenne / "<target> en cours" (image of an
    interrupted fade - an osmo-fond killed in flight, cf. start-native.sh
    killall_python) / autre."""
    p = chemin_de(gs_get("picture-uri")) or ""
    for nom, (f, _) in ETATS.items():
        if os.path.basename(p) == f:
            return nom, p
    for nom in ETATS:
        if "/osmo-fond/" in p and os.path.basename(p).startswith(nom + "-"):
            return nom + " en cours", p
    return "autre", p


# ── the fade ─────────────────────────────────────────────────────────────────
def _cache_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    if not os.path.isdir(base):
        base = "/tmp"
    d = os.path.join(base, "osmo-fond")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def rendre_etapes(src, dst, pas, cible):
    """The intermediate images src -> dst (without both ends); None if impossible."""
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
        # bring the source to the target format, "zoomed" like GNOME
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
    # an interrupted fade: restart from the image where it stopped (src)
    # only one fade at a time per session
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
        # whatever happens (error, SIGTERM), the REAL file is set
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
    # SIGTERM during the fade: the finally of poser() sets the target
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    if a.cible == "etat":
        etat, p = etat_courant()
        print("%s\t%s" % (etat, p))
        return 0
    return poser(a.cible, a.duree, a.pas, a.sec)


if __name__ == "__main__":
    sys.exit(main())
