#!/usr/bin/env python3
# osmo-fft-snap.py - the LIVE PANEL of the desktop: the wallpaper frame
# (tools/wallpaper-render.py, box 510,220-1410,1010 in 1920x1080), in TWO
# HALVES, each FADING to its bench once it is ready:
#
#   +-----------------------------------------------------------+
#   |  I/Q spectrum of the srsRAN UE (UL) |  srsUE console      |   4G
#   |  spectrum + waterfall (ZMQ 2001)    |  (tmux srsran:ue)   |
#   +-----------------------------------------------------------+
#   |  I/Q spectrum of the mobile (UL)    |  mobile.log (QEMU)  |   2G
#   |  spectrum + waterfall               |  last lines         |
#   +-----------------------------------------------------------+
#
# TWO HALVES, TWO BENCHES, TWO IMAGES. The frame is 790 px high and split in
# two: the top belongs to the 4G, the bottom to the 2G. Each half has ITS
# fade: as long as its bench is not there, it shows the comic strip the
# wallpaper carries at that spot (two images: a random geek comic at the top,
# Calvin & Hobbes at the bottom - tools/osmo-wallpaper.sh). One bench on, one
# live half; both, the whole panel.
#
# THE 4G IS LISTENED TO WITHOUT TAKING ANYTHING FROM IT. The srsRAN virtual
# radio is ZeroMQ in REQ/REP: the receiver ASKS for samples, and the
# transmitter ANSWERS it - once. A third party asking on the UE port (2001)
# would STEAL answers from the eNB, which would no longer have the whole
# uplink: attach fails, and with fail_on_disconnect its radio stops. So NO
# ZeroMQ socket is opened. The TCP traffic of the loopback interface is read
# through a raw capture (AF_PACKET, hence the unit runs as root), the port
# 2001 stream is followed and the ZMTP frames are cut out of it: each UE
# answer is [empty frame][long frame = N complex64 samples]. Nothing is sent
# back, nothing is consumed: srsue and srsenb cannot notice. The UE only
# transmits in bursts (PRACH, PUSCH...), and 11.52 MS/s make 92 MB/s on the
# loopback: only a 250 ms window is read per image and the PEAK of each
# spectrum bin over that window is kept, otherwise only silence between two
# bursts would be seen.
#
# 2G FFT source: the dashboard, http://127.0.0.1:8080/psd?src=ms - the same
# JSON as the FFT tab (fft1 view): freqs, psd (dB), dr, arfcn. The log: the
# stack's mobile.log (QEMU MS#1), read from the tail. On the 4G side, the log
# is the srsue console, captured in the « srsran » tmux that carries it
# (tools/osmo-lte.sh), and /tmp/ue.log as fallback.
#
#   /run/osmo-fft/panel.png   900x790   (wallpaper coordinates; osmo-panel.py
#                                        scales it to the screen)
#
# Launched by osmo-fft-snap.service. Depends only on Pillow and the DejaVu
# fonts, present on the image as on the host; numpy for the 4G FFT (without
# it, the top half says so and stays on its comic strip).
import glob
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
# DOWNLINK AS BACKGROUND, UPLINK ON TOP. The uplink alone (src=ms) only has
# signal when the mobile transmits (RACH, dedicated channel): in between the
# panel would show a flat floor. The downlink (src=bts, /tmp/iq_fft.fifo
# filled by pont.py) continuously carries the BCCH, the CCCH and hence the
# paging. It is drawn permanently, and the uplink is overlaid in orange as
# soon as it carries a burst.
# OSMO_FFT_2G=ms shows the uplink alone.
FFT_2G = os.environ.get("OSMO_FFT_2G", "bts+ms")
UL_ACTIF_DB = float(os.environ.get("OSMO_FFT_UL_ACTIF_DB", "20"))
OUT = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
PERIOD = float(os.environ.get("OSMO_FFT_PERIOD", "1"))
FADE_S = float(os.environ.get("OSMO_FFT_FADE", "3"))
# Opacity of the bench OVER the background image, once the fade is done.
#
# 1.0: with a lower value the comic strip would show through the log and the
# spectrum (the black strokes of the drawing between the mobile.log lines, the
# spectrum on a patterned background) and both would be lost. The fade stays:
# it is what moves from the image to the bench and back (FADE_S), and during
# those three seconds the two overlap. OSMO_FFT_OPACITY=0.86 lets the image
# show through for whoever wants to try.
OPACITY = max(0.0, min(1.0, float(os.environ.get("OSMO_FFT_OPACITY", "1.0"))))
# State written by tools/osmo-wallpaper.sh: is there a strip in the wallpaper?
# Without network, gocomics does not render the image and the wallpaper goes
# out WITHOUT strip - the frame is then empty, and blending the bench over
# nothing only dulls the spectrum and the log. In that case the panel goes to
# full opacity: no png, but mobile.log and the FFT stay sharp.
STRIP_STATE = os.environ.get("OSMO_WP_STATE", "/var/cache/osmo-wallpaper/strip.state")
WALLPAPER = os.environ.get("OSMO_WP_FILE", "/usr/share/backgrounds/gsm-lab-wallpaper.jpg")
# ── WHAT LIES UNDER THE PANEL: THE WHOLE ILLUSTRATION ───────────────────────
# The default wallpaper is an image without frame, and the GNOME desktop
# carries what the operator puts there (configs/gsm-lab-fond.jpg): cutting a
# box out of it would give an enlarged piece of sky and hill, meaningless.
# In « entier » mode the panel therefore shows the bench illustration WHOLE
# (pylons, sun, hill), fitted into its box - the top and bottom left free by
# the aspect ratio are filled with the same image, blurred and darkened,
# rather than two black bands.
#
# The composed render keeps its path: when osmo-wallpaper.sh has run and
# written FOND= in strip.state, THAT file is cropped - its frames are exactly
# where the box expects them. OSMO_FFT_FOND=decoupe forces the crop on
# $OSMO_WP_FILE.
# ONE SCENE. The illustration and the GNOME wallpaper come from the same
# drawing (tools/paysage-render.py): the wallpaper is the bare landscape, the
# illustration is the BOX crop of that landscape WITH the pylons. It thus
# already has the W x H format (900/790): « entier » fits it without band,
# and the antennas look planted into the desktop by the panel. The shipped
# files are a retouched version of that render, chosen on the bench.
ILLUSTRATION = os.environ.get("OSMO_FFT_IMAGE", "/usr/share/backgrounds/gsm-lab-wallpaper.jpg")
# NO IMAGE IN THE CENTRE. By default (« aucun ») the panel background is
# TRANSPARENT: bench down, the desktop shows; bench up, the two panes
# (spectrum, log) sit on top at PANEL_ALPHA opacity - not less, a spectrum
# over a light landscape is unreadable. panel.png is RGBA, osmo-panel.py
# displays it on a window that is itself transparent.
# OSMO_FFT_FOND=entier (the illustration) or decoupe give the image backgrounds.
FOND_MODE = os.environ.get("OSMO_FFT_FOND", "aucun")
PANEL_ALPHA = max(0.0, min(1.0, float(os.environ.get("OSMO_FFT_PANEL_ALPHA", "0.8"))))
PANEL = (8, 10, 14, int(round(255 * PANEL_ALPHA)))
# ── WHERE THE MOBILE LOG IS ─────────────────────────────────────────────────
# ONE PATH, PUBLISHED BY start-native.sh. mobile.log lives under LOG_DIR
# (= RUN_DIR/logs: /run/user/<uid>/osmo-nitb/logs, or /tmp/osmo-nitb without
# XDG_RUNTIME_DIR - environment/paths.env), and in --dsp under the c54x_exe
# RUNDIR (/tmp/c54x-pont). start-native.sh writes the actual path to
# /run/osmo-banc/mobile-log (like ms1-vty for the VTY port) and into the
# systemd environment (OSMO_MOBILE_LOG).
# Order: the published file; OSMO_MOBILE_LOG; else the most recent of the
# known locations; else the default. Resolved at every render: the log
# appears AFTER the panel is launched.
MOBILE_LOG_CANDIDATS = ("/run/user/*/osmo-nitb/logs/mobile.log",
                        "/tmp/osmo-nitb/logs/mobile.log",
                        "/tmp/c54x-pont/mobile.log")
MOBILE_LOG_DEFAUT = "/run/user/0/osmo-nitb/logs/mobile.log"


def mobile_log_path():
    # THE PUBLISHED FILE FIRST. OSMO_MOBILE_LOG is frozen at service start,
    # while /run/osmo-banc/mobile-log is rewritten at every bench launch
    # (e.g. rvinterf.log after a --ms-magnetite).
    try:
        with open("/run/osmo-banc/mobile-log") as f:
            publie = f.read().strip()
        if publie:
            return publie
    except OSError:
        pass
    force = os.environ.get("OSMO_MOBILE_LOG")
    if force:
        return force
    vus = []
    for motif in MOBILE_LOG_CANDIDATS:
        for p in glob.glob(motif):
            try:
                vus.append((os.stat(p).st_mtime, p))
            except OSError:
                pass
    return max(vus)[1] if vus else MOBILE_LOG_DEFAUT


# The operator selected in the panel (tools/osmo-panel.py, arrows): OP=,
# MODE=, IP=, NAME=, DASH=. Absent or native: the local dashboard and log.
OP_FILE = os.path.join(OUT, "operator")
# The panel box in the wallpaper (wallpaper-render.py, main()):
# THE FOUR FILES THAT KNOW IT MUST STAY IN AGREEMENT -
# wallpaper-render.py, osmo-fft-snap.py, osmo-panel.py, osmo-launcher.py.
BOX = (510, 220, 1410, 1010)
W, H = BOX[2] - BOX[0], BOX[3] - BOX[1]
# The two halves, in image coordinates: (top y, bottom y). The wallpaper
# draws two frames separated by ECART px (the two images), and each live half
# covers exactly its own.
ECART = 8
HH = (H - ECART) // 2
HAUT = (0, HH)
BAS = (H - HH, H)
PAD = 18
# FOOT = 0: NO FOOTER BAND. The content - spectrum, waterfall, log - takes
# the whole height, and only the buttons remain, laid on top in the corner
# (they carry the operator number, so a footer line would say nothing more).
# FOOT stays named: the geometry is expressed with it, and setting it to 30
# gives a footer band.
FOOT = 0
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x07")
# ── THE LOG COLOURS ARE ALREADY IN THE LOG ──────────────────────────────────
# mobile.log is written WITH its ANSI codes (osmocom colours by subsystem:
# « \033[0;31m<0004> gsm322.c:... \033[0;m »). The colour the log carries is
# rendered as is, with the Tango palette - the one of the image's
# gnome-terminal profile (85-installeur-bureau.sh) - so the reading matches
# the terminal.
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
    """The colour a terminal would give this line. None if it has none."""
    for m in SGR.finditer(brut):
        codes = [c for c in m.group(1).split(";") if c]
        if not codes or codes == ["0"]:
            continue                      # reset: not a colour
        table = TANGO_VIF if "1" in codes else TANGO
        for c in codes:
            if c in table:
                return table[c]
            if c.startswith("9") and len(c) == 2 and c[1] in "01234567":
                return TANGO_VIF["3" + c[1]]   # 90-97: the ECMA-48 bright colours
    return None


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


F_TITLE = font("DejaVuSansMono-Bold.ttf", 15)
F_SMALL = font("DejaVuSansMono.ttf", 12)
F_LOG = font("DejaVuSansMono.ttf", 12)


def palette_sdr(v):
    """SDR palette, 0..1 -> RGB: navy, blue, cyan, green, yellow, red (the same as the
    FFT tab, sdr)."""
    ancres = [(0,0,40), (0,20,150), (0,90,255), (0,200,230), (0,210,80), (170,235,0), (255,230,0), (255,130,0), (230,0,0)]
    stops = [(i / (len(ancres) - 1), c) for i, c in enumerate(ancres)]
    v = 0.0 if v < 0 else 1.0 if v > 1 else v
    for i in range(len(stops) - 1):
        a, ca = stops[i]
        b, cb = stops[i + 1]
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            return tuple(int(ca[j] + (cb[j] - ca[j]) * t) for j in range(3))
    return stops[-1][1]


def operator():
    """{'OP','MODE','IP','NAME','DASH'} of the selected operator, native by default."""
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
    """Brings a list down to n columns (max per group: a peak stays visible)."""
    if len(vals) <= n:
        return vals + [vals[-1]] * (n - len(vals)) if vals else [0.0] * n
    out = []
    step = len(vals) / n
    for i in range(n):
        a, b = int(i * step), max(int((i + 1) * step), int(i * step) + 1)
        out.append(max(vals[a:b]))
    return out


_strip = {"mtime": None, "present": True, "fond": ""}


def _lire_strip_state():
    """Rereads strip.state (osmo-wallpaper.sh) when it changes: STRIP= and FOND=."""
    try:
        mt = os.stat(STRIP_STATE).st_mtime
    except OSError:
        _strip.update(mtime=None, present=True, fond="")
        return
    if mt == _strip["mtime"]:
        return
    present, fond = True, ""
    try:
        with open(STRIP_STATE) as fh:
            for line in fh:
                k, _, v = line.strip().partition("=")
                if k == "STRIP":
                    present = v.strip().lower() != "non"
                elif k == "FOND":
                    fond = v.strip()
    except OSError:
        pass
    _strip.update(mtime=mt, present=present, fond=fond)


def strip_present():
    """Does the wallpaper of the day carry a strip? (default: yes, no guessing)"""
    _lire_strip_state()
    return _strip["present"]


def _source_fond():
    """(file, mode): the composed render to CROP, or the illustration to FIT."""
    _lire_strip_state()
    f = _strip["fond"]
    if _strip["present"] and f and os.path.isfile(f):
        return f, "decoupe"
    if FOND_MODE == "decoupe":
        return WALLPAPER, "decoupe"
    if FOND_MODE == "aucun":
        return None, "aucun"
    return (ILLUSTRATION if os.path.isfile(ILLUSTRATION) else WALLPAPER), "entier"


def _ajuster(im):
    """The WHOLE image in W x H: fitted and centred; the rest of the box is the
    same image filling it, blurred and darkened (no black bands)."""
    from PIL import ImageEnhance, ImageFilter
    im.thumbnail((2 * W, 2 * H), Image.LANCZOS)       # 1800x1580 (or more): fast enough
    sw, sh = im.size
    s = max(W / sw, H / sh)
    fond = im.resize((max(W, int(sw * s + 0.5)), max(H, int(sh * s + 0.5))), Image.LANCZOS)
    x0, y0 = (fond.width - W) // 2, (fond.height - H) // 2
    fond = fond.crop((x0, y0, x0 + W, y0 + H)).filter(ImageFilter.GaussianBlur(18))
    fond = ImageEnhance.Brightness(fond).enhance(0.5)
    s = min(W / sw, H / sh)
    dev = im.resize((max(1, int(sw * s)), max(1, int(sh * s))), Image.LANCZOS)
    fond.paste(dev, ((W - dev.width) // 2, (H - dev.height) // 2))
    return fond


# ── THE PANEL BACKGROUND, REREAD WHEN IT CHANGES ────────────────────────────
# The mtime of the chosen file is followed (and the file itself:
# osmo-wallpaper.sh may change it on the day it runs).
_base = {"cle": None, "img": None}


def base_image():
    src, mode = _source_fond()
    try:
        mt = os.stat(src).st_mtime if src else None
    except OSError:
        mt = None
    cle = (src, mode, mt)
    if cle != _base["cle"] or _base["img"] is None:
        img = None
        if mt is not None:
            try:
                wp = Image.open(src).convert("RGB")
                if mode == "decoupe":
                    if wp.size != (1920, 1080):
                        wp = wp.resize((1920, 1080), Image.LANCZOS)
                    img = wp.crop(BOX)
                else:
                    img = _ajuster(wp)
                print(f"[fft-snap] fond de l encart : {src} ({mode})", flush=True)
            except Exception as e:  # unreadable background: dark frame, no strip
                print(f"[fft-snap] fond {src} : {e}", file=sys.stderr, flush=True)
        if img is None and mode == "aucun":
            img = Image.new("RGBA", (W, H), (0, 0, 0, 0))     # nothing: the desktop
        elif img is None:
            img = Image.new("RGB", (W, H), (20, 24, 36))
            for m in (HAUT, BAS):     # the two frames, as the wallpaper draws them
                ImageDraw.Draw(img).rounded_rectangle((0, m[0], W - 1, m[1] - 1), radius=26,
                                                     outline=(200, 200, 210), width=2)
        _base.update(cle=cle, img=img.convert("RGBA"))
    return _base["img"]


def base_moitie(m):
    """The piece of background under one half of the panel (HAUT or BAS)."""
    return base_image().crop((0, m[0], W, m[1]))


# ── THE MOBILE LOG ──────────────────────────────────────────────────────────
# The name of the file read in each container (mobile.log, rvinterf.log...),
# filled by tail_lines for the panel title.
JOURNAL_DOCKER_NOM = {}


def tail_lines(path, n, width):
    op = operator()
    if op["MODE"] == "docker":
        # `docker logs` SHOWS NOTHING OF AN OPERATOR, exactly as for the hub
        # (see HUB_LOGS below): the stack is launched by `docker exec` in a
        # tmux and its output goes to FILES, not to the container's standard
        # stream, which only carries the two entrypoint lines. The file is
        # read INSIDE the container; `docker logs` remains the last resort for
        # an image that would launch the operator differently.
        data = ""
        # THE PATH PUBLISHED IN THE CONTAINER, NOT THE HOST ONE. The container
        # publishes its log in /run/osmo-banc/mobile-log too (start-native.sh):
        # it is read there, and failing that the most recent NON-EMPTY of the
        # known locations (DSP, instance 2, Magnetite, qosmo). The first line
        # returned carries the file name (@@path) for the panel title.
        choix = (
            'p=$(cat /run/osmo-banc/mobile-log 2>/dev/null); '
            'if [ -n "$p" ] && [ -s "$p" ]; then f="$p"; else f=""; '
            'for x in $(ls -t /tmp/c54x-pont/mobile.log /tmp/c54x-pont2/mobile.log '
            '/tmp/c54x-pont/rvinterf.log /tmp/c54x-pont2/rvinterf.log '
            '/tmp/osmo-nitb/logs/mobile.log /run/user/*/osmo-nitb/logs/mobile.log 2>/dev/null); do '
            '[ -s "$x" ] && { f="$x"; break; }; done; fi; '
            '[ -n "$f" ] || exit 3; echo "@@$f"; tail -n ' + str(n + 5) + ' "$f"')
        try:
            out = subprocess.run(["docker", "exec", op["NAME"], "sh", "-c", choix],
                                 capture_output=True, text=True, timeout=4)
        except Exception as e:
            return [(f"{op['NAME']} : journal inaccessible ({type(e).__name__})", None)]
        if out.returncode == 0 and out.stdout.startswith("@@"):
            nom, _, data = out.stdout.partition("\n")
            JOURNAL_DOCKER_NOM[op["NAME"]] = os.path.basename(nom[2:].strip())
        elif "permission denied" in (out.stderr or "").lower():
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
    # The RAW line is kept long enough to read its colour, then cleaned.
    brutes = [l for l in data.splitlines() if ANSI.sub("", l).strip()]
    out = []
    for brut in brutes[-n:]:
        col = couleur_ansi(brut)
        l = ANSI.sub("", brut).rstrip()
        # The osmocom timestamp (20260904135215721) eats 17 columns for nothing.
        l = re.sub(r"^\d{17}\s+", "", l)
        out.append((l[:width], col))
    return out or [("(journal vide)", None)]


# ── THE BENCH: SPECTRUM ON THE LEFT, LOG ON THE RIGHT ───────────────────────
history = []


# ── THE HUB VIEW: SS7, NOT AN FFT ───────────────────────────────────────────
# An M3UA hub has no radio: no /psd to query, no ARFCN, no mobile.log. An
# empty FFT on the central node of the bench would be useless precisely when
# one is looking for why SS7 does not pass.
#
# What a hub does have: a connectivity matrix (who talks to whom), its ASPs,
# its routes, and a log. That is what is shown.
#
# The matrix comes from the CACHE filled by tools/conky-osmo-status.sh
# (--refresh-matrix, from checks/ss7_check.sh): the measurement takes a
# minute, it has no place in a 1 Hz render loop. The same file as the Conky
# is read - one measurement, two displays. The Conky ${colorN} tags are
# stripped here and rendered as Pillow colours.
MATRIX_FILE = os.path.join(OUT, "ss7-matrix")
CONKY_TAG = re.compile(r"\$\{color[0-9]?\}")
COUL_SS7 = {"self": (88, 166, 255), "via": (63, 185, 80), "FAIL": (248, 81, 73)}


def matrice_lignes():
    """The matrix cache, without the Conky tags. [] if it does not exist."""
    try:
        with open(MATRIX_FILE) as f:
            return [CONKY_TAG.sub("", l.rstrip("\n")) for l in f if l.strip()]
    except OSError:
        return []


# The places where the hub writes, in the order they are tried.
#
# `docker logs osmo-inter-stp` is EMPTY by design: the container's command is
# `sleep infinity`, and osmo-stp is launched AFTERWARDS by `docker exec` in a
# tmux, its output going through a `tee` to a file. None of that crosses the
# container's standard stream. So the file is read INSIDE the container;
# docker logs remains the last resort, for an image that would launch the
# STP differently.
HUB_LOGS = ("/tmp/osmo-stp.log", "/var/log/osmocom/osmo-stp.log")


def hub_journal(nom, n, width):
    """The last lines of the hub STP. Without docker (or without permission),
    say so rather than leaving an empty frame - an empty frame reads like a
    hub failure, when it is the probe whose arm is not long enough."""
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
    """The panel when the selection is the inter-STP: matrix on the left, hub
    log on the right. Same frame, same margins and same footer as the radio
    view - only the content changes, so the eye keeps its landmarks when
    moving from an operator to the hub."""
    img = base_moitie(BAS).copy()
    d = ImageDraw.Draw(img)
    # ── THE PANE COVERS THE WHOLE FRAME, BORDER INCLUDED ────────────────────
    # The PAD margin would otherwise let base_image() show through - the piece
    # of wallpaper, hence the `glass_panel` painted there by
    # wallpaper-render.py: a lighter fill (20,24,36) and above all a BORDER
    # (200,200,210), a light rounded frame all around the panel.
    #
    # When the bench runs, the panel is a solid pane: it covers the WHOLE
    # frame, same radius as the wallpaper one (26) to land exactly on it.
    # The wallpaper frame stays visible when the bench is down - it then
    # frames the image of the day, and there it makes sense.
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=PANEL)
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=PANEL)
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
        # Each word is painted in its colour: self/via/FAIL carry the meaning.
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

    # The hub log, on the right, exactly where the mobile one lives.
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


def render_live(data, data_ul=None):
    img = base_moitie(BAS).copy()
    d = ImageDraw.Draw(img)
    # ── THE PANE COVERS THE WHOLE FRAME, BORDER INCLUDED ────────────────────
    # Same rule as render_interstp(): a solid pane over the whole frame, same
    # radius as the wallpaper frame (26), so that nothing of the wallpaper
    # `glass_panel` (fill and border) shows through the margins.
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=PANEL)
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=PANEL)
    split = x0 + int((x1 - x0) * 0.56)
    # Spectrum
    titre = ("Spectre I/Q du mobile  ·  montant (UL)" if FFT_2G == "ms"
             else "Spectre I/Q  ·  DL + UL")
    d.text((x0, y0), titre, font=F_TITLE, fill=(88, 166, 255))
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
        ul = data_ul.get("psd") if data_ul else None
        if ul and max(ul) - min(ul) >= UL_ACTIF_DB:
            # Uplink burst: its curve on top, and in the waterfall the max of
            # both, so that a RACH or an SDCCH block leaves its trace there.
            vul = resample(normalize(ul, data_ul.get("dr", 40)), sw)
            d.line([(sx0 + x, py1 - 1 - int(v * (psd_h - 4))) for x, v in enumerate(vul)],
                   fill=(255, 166, 60), width=1)
            vals = [max(a, b) for a, b in zip(vals, vul)]
        history.insert(0, vals)
    else:
        d.text((sx0 + 8, py0 + 8), "pas de flux", font=F_SMALL, fill=(248, 81, 73))
    # Waterfall: one line per image, the most recent at the top
    wy0 = py1 + 4
    wf_h = y1 - wy0
    del history[wf_h:]
    wf = Image.new("RGB", (sw, wf_h), (8, 10, 14))
    px = wf.load()
    for row, line in enumerate(history):
        for x in range(min(sw, len(line))):
            px[x, row] = palette_sdr(line[x])
    img.paste(wf, (sx0, wy0))
    # Log
    d = ImageDraw.Draw(img)
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    op = operator()
    # The title names the file read: rvinterf.log (TI traces) with --ms-magnetite
    line_h = 15
    n = max(1, (y1 - (y0 + 26)) // line_h)
    cols = max(10, int((x1 - lx0) / 7.3))
    # The lines first: for a container, reading them is what says which file
    # carries the log (JOURNAL_DOCKER_NOM), and the title names it.
    lignes = tail_lines(mobile_log_path(), n, cols)
    d.text((lx0, y0), (f"{os.path.basename(mobile_log_path())}  ·  QEMU MS#1" if op["MODE"] != "docker"
                       else f"{JOURNAL_DOCKER_NOM.get(op['NAME'], 'journal')}  ·  {op['NAME']}  ·  MS#1"),
           font=F_TITLE, fill=(88, 166, 255))
    for i, (l, col) in enumerate(lignes):
        if col is None:
            # Log without colours (docker logs, a redirection that ate them):
            # fall back on keyword matching.
            col = LOG_DEFAUT
            if re.search(r"error|fail|reject|lost", l, re.I):
                col = TANGO_VIF["31"]
            elif re.search(r"attach|answer|call|SMS|proceed", l, re.I):
                col = TANGO_VIF["32"]
        d.text((lx0, y0 + 26 + i * line_h), l, font=F_LOG, fill=col)
    # The pane is built ON a copy of the wallpaper (base_image): whatever the
    # render does not paint lets the background show, so the pane is painted
    # to the edge in a single colour (no footer band, FOOT = 0). What a
    # footer caption would say - which operator, which log - is carried by
    # the buttons themselves (« Dashboard op2 », « VTY 4247 op2 ») and by the
    # title of the right column.
    return img


# ── THE 4G: THE srsRAN UE, RAW-CAPTURED ON THE LOOPBACK ─────────────────────
# See the header: no ZeroMQ socket, the TCP of the UE port is read as it
# passes on lo and the ZMTP frames are cut out of it. Settings:
#   OSMO_LTE_TAP_PORT    the « tx » ZMQ port of srsue (2001; 2000 = the eNB,
#                        hence the downlink, for whoever prefers to see it)
#   OSMO_LTE_TAP_IFACE   the interface (lo)
#   OSMO_LTE_TAP_WINDOW  the listening window per image, in s (0.25)
#   OSMO_SRSRAN_UE_CONF  the ue.conf to read for the EARFCN and the rate
#   OSMO_SRSRAN_TMUX     the tmux (-L) carrying srsue, window « ue »
#   OSMO_SRSRAN_UE_LOG   the srsue log, failing the tmux
LTE_PORT = int(os.environ.get("OSMO_LTE_TAP_PORT", "2001"))
LTE_IFACE = os.environ.get("OSMO_LTE_TAP_IFACE", "lo")
LTE_FENETRE = float(os.environ.get("OSMO_LTE_TAP_WINDOW", "0.25"))
LTE_NFFT = 1024
LTE_UE_CONF = os.environ.get("OSMO_SRSRAN_UE_CONF", "/root/.config/srsran/ue.conf")
LTE_TMUX = os.environ.get("OSMO_SRSRAN_TMUX", "srsran")
# tools/osmo-lte.sh launches srsue with --log.filename=/tmp/osmo-lte-ue.log
# (which overrides the « filename = /tmp/ue.log » of ue.conf) and its STANDARD
# OUTPUT into /tmp/osmo-lte-ue.console - that is where « Found PLMN », « RRC
# Connected », « Network attach successful » are. The tmux -L srsran only
# exists if it was opened by hand.
LTE_UE_LOG = os.environ.get("OSMO_SRSRAN_UE_LOG", "/tmp/osmo-lte-ue.log")
LTE_UE_CONSOLE = os.environ.get("OSMO_SRSRAN_UE_CONSOLE", "/tmp/osmo-lte-ue.console")
LTE_UE_SOURCES = [LTE_UE_CONSOLE, LTE_UE_LOG, "/tmp/ue.log"]
# The marker of a ZMTP answer from the UE: the empty frame of the REQ/REP
# (0x01 = « there is another one », size 0), then the header of a long frame
# (0x02, 8-byte big-endian size, whose first five bytes are zero as long as
# it is under 2^24 bytes - a one-second frame would be 92 M).
ZMTP_MARQUE = b"\x01\x00\x02\x00\x00\x00\x00\x00"
try:
    import numpy as np
except ImportError:      # the 4G half will say so; the 2G does not need it
    np = None


def _tcp_ecoute(port):
    """Does someone listen on this TCP port? (read of /proc/net/tcp, no privilege)"""
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
    """{'earfcn', 'srate'} from ue.conf; reasonable defaults otherwise."""
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
    """Listens for the 4G half: etat = {psd (dB, LTE_NFFT bins, centre in the
    middle), crete (max amplitude seen), trames, erreur, t}. Only runs when
    the UE port is open - otherwise nothing to listen to, and nothing to open."""

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
                # On lo each packet passes twice (outgoing then incoming):
                # only the incoming one is kept (pkttype 4 = PACKET_OUTGOING).
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
                    buf = b""            # gap in the stream: resynchronise
                attendu = (seq + len(charge)) & 0xFFFFFFFF
                buf += charge
                while True:
                    i = buf.find(ZMTP_MARQUE)
                    if i < 0:
                        buf = buf[-len(ZMTP_MARQUE):]
                        break
                    taille = int.from_bytes(buf[i + 3:i + 11], "big")
                    if taille % 8 or taille > (64 << 20):
                        buf = buf[i + 1:]            # false marker inside the data
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


def _queue_fichier(chemin, n):
    """The last n non-empty lines of a text file, without ANSI colours;
    [] if it is absent or empty."""
    try:
        with open(chemin, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    # RRC measurements (« MEAS: New measurement serving cell ») arrive every
    # 20 ms: they would drown the attach. Only the events are kept.
    # Last line still being written: it is not shown truncated.
    if data and not data.endswith("\n"):
        data = data[:data.rfind("\n") + 1]
    # srsue writes its progress bars with \r: only the last segment counts.
    lignes = [ANSI.sub("", l.split("\r")[-1]).rstrip() for l in data.splitlines()]
    return [l for l in lignes if l.strip() and " MEAS:" not in l][-n:]


def srsran_journal(n, width):
    """The last lines of the srsue console: the « ue » window of the tmux
    carrying it if it exists, otherwise its standard output
    (osmo-lte-ue.console: PLMN found, RRC, attach) COMPLETED by its log
    (osmo-lte-ue.log: RRC/NAS at info level, see configs/srsran/ue.conf)."""
    try:
        out = subprocess.run(["tmux", "-L", LTE_TMUX, "capture-pane", "-p", "-t", f"{LTE_TMUX}:ue"],
                             capture_output=True, text=True, timeout=2)
        lignes = [ANSI.sub("", l).rstrip() for l in out.stdout.splitlines()]
        lignes = [l for l in lignes if l.strip()]
        if out.returncode == 0 and lignes:
            return [(l[:width], None) for l in lignes[-n:]]
    except Exception:
        pass
    # Console first (the essentials fit in a few lines), the log takes the
    # rest of the room: both truncated from the top, keeping the most recent.
    console = _queue_fichier(LTE_UE_CONSOLE, max(1, n // 3))
    journal = _queue_fichier(LTE_UE_LOG, n)
    if not console and not journal:
        journal = _queue_fichier("/tmp/ue.log", n)
    if console or journal:
        lignes = console + journal[-max(0, n - len(console)):] if journal else console
        return [(l[:width], None) for l in lignes[-n:]]
    return [("console srsue introuvable :", (139, 148, 158)),
            (f"  ni tmux -L {LTE_TMUX} (fenetre ue), ni " + ", ni ".join(LTE_UE_SOURCES),
             (139, 148, 158))]


historique_lte = []


def render_lte(etat):
    """The top half: the uplink spectrum of the srsRAN UE on the left, its
    console on the right. Same frame, same margins as the 2G: one panel, two
    benches."""
    img = base_moitie(HAUT).copy()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, W - 1, HH - 1), radius=26, fill=PANEL)
    x0, y0, x1, y1 = PAD, PAD, W - PAD, HH - PAD - FOOT
    d.rounded_rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), radius=8, fill=PANEL)
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
    # The axis: the sample rate, from -srate/2 to +srate/2 around the carrier.
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
        # Scale: the top follows the peak, never below -60 dB - so the
        # silence between two bursts stays flat instead of being stretched.
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
            px[x, row] = palette_sdr(line[x])
    img.paste(wf, (sx0, wy0))
    d = ImageDraw.Draw(img)
    lx0 = split
    d.line((lx0 - 6, y0, lx0 - 6, y1), fill=(30, 36, 48))
    d.text((lx0, y0), "console srsUE  ·  osmo-lte-ue.console + .log", font=F_TITLE, fill=(88, 166, 255))
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
    print(f"[fft-snap] {URL} + {mobile_log_path()} (2G, bas) + prise brute {LTE_IFACE}:{LTE_PORT} (4G, haut)"
          f" -> {OUT}/panel.png toutes les {PERIOD}s (fondu {FADE_S}s depuis {WALLPAPER})", flush=True)
    sonde = SondeLte()
    sonde.start()
    # One fade per half: « bas » follows the 2G (or the hub), « haut » the 4G.
    alpha = {"bas": 0.0, "haut": 0.0}
    step = PERIOD / FADE_S if FADE_S > 0 else 1.0
    last_state = {"bas": None, "haut": None}
    while True:
        t = time.time()
        op_courant = operator()
        # The hub has no /psd: querying it would never return anything and
        # the panel would stay on the strip. Its view is « ready » as soon as
        # it is selected - the matrix and its log make the content.
        if op_courant.get("MODE") == "interstp":
            data, data_ul, ready = None, None, True
        else:
            data = data_ul = None
            try:
                data = fetch("ms" if FFT_2G == "ms" else "bts")
            except Exception:
                data = None
            if FFT_2G != "ms":
                try:
                    data_ul = fetch("ms")
                except Exception:
                    data_ul = None
                # No downlink (bridge without DL FIFO): the uplink alone.
                if not (data and "psd" in data) and data_ul and "psd" in data_ul:
                    data, data_ul = data_ul, None
            ready = bool(data) and "psd" in data
        # The 4G is « there » as soon as srsue holds its ZMQ port: the
        # spectrum may be empty (no burst), but the panel then shows that
        # silence, with the UE console next to it - precisely what one wants
        # to see while waiting for the attach.
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
            # ALWAYS a blend, even once the fade is done: it is what lets the
            # strip show through under the bench. Without a strip behind,
            # nothing to show: full opacity.
            op = OPACITY if strip_present() else 1.0
            if alpha["bas"] <= 0.0:
                history.clear()
            else:
                live = (render_interstp(op_courant)
                        if op_courant.get("MODE") == "interstp" else render_live(data, data_ul))
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
