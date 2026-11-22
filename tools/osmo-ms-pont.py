#!/usr/bin/python3
# osmo-ms-pont.py - THE MOBILE SIDE OF THE BENCH IN ONE WINDOW: it RUNS the
# chain (DSP, ARM, osmocon, mobile, bridge) and SHOWS its air.
#
#   osmo-ms-pont                 the window; "Demarrer" runs the chain
#   osmo-ms-pont --demo          the window fed with random bursts (no chain)
#   OSMO_MS_PONT_PORT=6790       UDP port of the air (copy of the bridge)
#
# THE CHAIN. "Demarrer" executes the steps of c54x_exe/run.sh WITHOUT the
# mobile (no layer 2/3): 1. c54x_exe --arm (the C54x DSP, TI mask-ROM),
# b. the noise injector (only if BRUIT_MODE is set), 2. qosmo (the ARM +
# osmocom-bb layer 1), 3. osmocon (romload, L1CTL relay), 5. pont_dsp.py
# (PONT=1, the bridge: BTS bursts -> DSP; it does not need the mobile).
# "Arreter" runs ./run.sh --stop. The state of each process is read from the
# pid files of RUNDIR (/tmp/c54x-pont), as ./run.sh --status does. run.sh
# needs root (SCHED_FIFO, taskset, /dev/shm): started as a user, the window
# goes through pkexec.
#
# ITS AIR. The bridge it launched is given one more copy port
# (PONT_DSP_COPIES = "6762 <port>", pont/trx.py): every downlink burst it
# hands to the DSP, and every uplink burst it sends to the BTS (marked 0xA5),
# also arrives here: tn, fn (big endian), rssi, marker, then the 148 bits.
# The window rebuilds the I/Q the DSP receives with THE SAME modulator as the
# BSP (qosmo calypso_gmsk.c: GMSK BT 0.3, 1 sample per symbol at instant 0.5,
# widening a = 0.3, calypso_bsp.c nb_moduler), adds white noise at the SNR of
# the bench (CALYPSO_BSP_SNR_DB of the running c54x_exe, else the slider), then
# receives it like a demodulator: derotation by j^-k, channel estimate on the
# training sequence (least squares), and shows:
#   - the constellation (derotated, normalised by the channel: two clouds at
#     +-1, stretched by the GMSK intersymbol interference), DL or UL;
#   - the eye diagram (real part, 8 samples per symbol);
#   - the I/Q of the last burst, training sequence highlighted;
#   - the correlation with the training sequence (lag -> TOA);
#   - the TDMA grid: 8 timeslots x the 51 frames of the multiframe, coloured by
#     burst type (FB, SB, NB per TSC, access burst, other);
#   - SNR and EVM measured on the training sequence, bursts per second.
# A burst seen here is the bridge's burst; its I/Q is MODELLED, not read in the
# DSP memory (the C54x DARAM is not exported).
import argparse
import collections
import math
import os
import random
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

import numpy as np

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # noqa: E402

GSM_ROOT = os.environ.get("GSM_ROOT", "/opt/GSM")
RUN_SH = os.environ.get("RUN_SH", os.path.join(GSM_ROOT, "c54x_exe", "run.sh"))
RUNDIR = os.environ.get("RUNDIR", "/tmp/c54x-pont")
PORT = int(os.environ.get("OSMO_MS_PONT_PORT", "6790"))
ETAPES = ("dsp", "qemu", "osmocon", "pont")

# ── GSM: training sequences (3GPP TS 45.002 5.2) ─────────────────────────────
TSC = [
    "00100101110000100010010111", "00101101110111100010110111",
    "01000011101110100100001110", "01000111101101000100011110",
    "00011010111001000001101011", "01001110101100000100111010",
    "10100111110110001010011111", "11101111000100101110111100",
]
SB_TRAIN = "1011100101100010000001000000111100101101010001010111011000011011"
AB_TRAIN = "01001011011111111001100110101010001111000"
TSC_B = [bytes(int(c) for c in t) for t in TSC]
SB_B = bytes(int(c) for c in SB_TRAIN)
AB_B = bytes(int(c) for c in AB_TRAIN)


def classer(bits):
    """(type, tsc, first bit of the training, its length): FB, SB, NB, AB, ?"""
    if not any(bits[3:145]):
        return "FB", None, 0, 0
    if bits[42:106] == SB_B:
        return "SB", None, 42, 64
    t = bits[61:87]
    for i, ref in enumerate(TSC_B):
        if t == ref:
            return "NB", i, 61, 26
    if bits[8:49] == AB_B:
        return "AB", None, 8, 41
    return "?", None, 0, 0


# ── the modulator of the BSP (qosmo calypso_gmsk.c) ──────────────────────────
OS = 8
_K = 2.0 * math.pi * 0.3 / math.sqrt(math.log(2.0))
_Q = lambda x: 0.5 * math.erfc(x / math.sqrt(2.0))  # noqa: E731
_TG = np.arange(3 * OS) / OS - 1.5 + 0.5 / OS
_G = np.array([_Q(_K * (t - 0.5)) - _Q(_K * (t + 0.5)) for t in _TG])
_G /= _G.sum()


def moduler(bits):
    """(1 sample/symbol at instant 0.5 as the BSP, oversampled trajectory)"""
    b = np.frombuffer(bits, dtype=np.uint8) & 1
    prev = np.concatenate(([1], b[:-1]))
    a = 1.0 - 2.0 * (b ^ prev)
    x = np.zeros(len(b) * OS)
    x[::OS] = a
    ph = (np.pi / 2) * np.cumsum(np.convolve(x, _G))
    w = np.exp(1j * ph)
    m = (np.arange(len(b)) + 2) * OS - 1
    return w[m], w[OS:OS + len(b) * OS]


def elargir(s, a=0.3):
    y = s.copy()
    y[1:] += a * s[:-1]
    y[:-1] += a * s[1:]
    return y / (1 + 2 * a)


# Derotation: the BSP samples symbol k at t = k + 0.5 (index (k+2)*OS-1 of the
# trajectory), where the GMSK phase is pi/2 (k+1) away from a +-1 point.
ROT = np.exp(-1j * np.pi / 2 * (np.arange(148) + 1))
ROT_OS = np.exp(-1j * np.pi / 2 * (np.arange(148 * OS) + 1) / OS)


def recevoir(bits, snr_db, rng):
    """Model + receiver of one burst -> dict, or None for an FB / unknown burst."""
    typ, tsc, t0, tl = classer(bits)
    s1, w = moduler(bits)
    s1 = elargir(s1)
    if snr_db is not None:
        sig = 10 ** (-snr_db / 20.0) / math.sqrt(2)
        s1 = s1 + sig * (rng.standard_normal(148) + 1j * rng.standard_normal(148))
        w = w + sig * (rng.standard_normal(w.size) + 1j * rng.standard_normal(w.size)) * 0.6
    d = s1 * ROT
    out = {"type": typ, "tsc": tsc, "t0": t0, "tl": tl, "iq": s1, "os": w * ROT_OS[:w.size]}
    if tl == 0:
        return out
    ref, _ = moduler(bits)                       # what the receiver knows: the training bits
    ref = elargir(ref) * ROT
    r = ref[t0:t0 + tl]
    y = d[t0:t0 + tl]
    h = np.vdot(r, y) / np.vdot(r, r)
    if abs(h) < 1e-9:
        return out
    z = d / h
    err = z[t0:t0 + tl] - r
    p_err = float(np.mean(np.abs(err) ** 2))
    out["const"] = z
    out["snr"] = 10 * math.log10(float(np.mean(np.abs(r) ** 2)) / p_err) if p_err > 1e-12 else 99.0
    out["evm"] = 100.0 * math.sqrt(p_err / float(np.mean(np.abs(r) ** 2)))
    lags = range(-6, 7)
    out["corr"] = [abs(np.vdot(r, d[t0 + l:t0 + l + tl])) / tl if 0 <= t0 + l and t0 + l + tl <= 148 else 0.0
                   for l in lags]
    return out


# ── the chain ────────────────────────────────────────────────────────────────
def pid_de(n):
    try:
        with open(os.path.join(RUNDIR, n + ".pid")) as f:
            p = int(f.read().strip())
        os.kill(p, 0)
        return p
    except (OSError, ValueError):
        return None


def snr_du_banc():
    p = pid_de("dsp")
    if not p:
        return None
    try:
        with open("/proc/%d/environ" % p, "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"CALYPSO_BSP_SNR_DB="):
                    return float(kv.split(b"=", 1)[1])
    except (OSError, ValueError):
        pass
    return None


def commande_chaine(args):
    """argv + env: args = [] runs steps 1, b, 2, 3, 5 (no mobile), else run.sh <args>."""
    env = {"PONT": "1", "PONT_DSP_COPIES": "6762 %d" % PORT}
    if args:
        base = ["bash", RUN_SH] + args
    else:
        r = RUN_SH.replace("'", "")
        base = ["bash", "-c", "set -e; for e in 1 b 2 3 5; do bash '%s' --step $e; done" % r]
    if os.geteuid() == 0:
        return base, dict(os.environ, **env)
    pk = shutil.which("pkexec")
    if not pk:
        return None, None
    return [pk, "env"] + ["%s=%s" % kv for kv in env.items()] + base, dict(os.environ)


# ── the air: UDP copies of the bridge ────────────────────────────────────────
class Air:
    def __init__(self):
        self.lock = threading.Lock()
        self.file = {"DL": collections.deque(maxlen=64), "UL": collections.deque(maxlen=64)}
        self.grille = {"DL": {}, "UL": {}}
        self.compte = {"DL": 0, "UL": 0}
        self.dernier = {"DL": None, "UL": None}

    def recu(self, data):
        if len(data) < 8 + 148:
            return
        tn = data[0] & 7
        fn = struct.unpack(">L", data[1:5])[0]
        sens = "UL" if data[6] == 0xA5 else "DL"
        bits = bytes(b & 1 for b in data[8:8 + 148])
        typ, tsc, _, _ = classer(bits)
        with self.lock:
            self.grille[sens][(tn, fn % 51)] = (typ, tsc, time.monotonic())
            self.compte[sens] += 1
            self.dernier[sens] = (fn, tn, data[5])
            self.file[sens].append((fn, tn, bits))

    def ecouter(self):
        sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sk.bind(("127.0.0.1", PORT))
        except OSError as e:
            print("[osmo-ms-pont] udp/%d : %s" % (PORT, e), file=sys.stderr)
            return
        while True:
            data, _ = sk.recvfrom(512)
            self.recu(data)

    def demo(self):
        """Random bursts as a BCCH carrier: FB/SB on TS0, NB TSC 7 elsewhere, RACH on UL."""
        fn = 0
        while True:
            for tn in range(8):
                m = fn % 51
                if tn == 0 and m % 10 == 0 and m != 50:
                    bits = bytes(148)
                elif tn == 0 and m % 10 == 1:
                    b = [random.getrandbits(1) for _ in range(148)]
                    b[42:106] = SB_B
                    bits = bytes(b)
                else:
                    b = [random.getrandbits(1) for _ in range(148)]
                    b[61:87] = TSC_B[7 if tn else 0]
                    bits = bytes(b)
                self.recu(bytes([tn]) + struct.pack(">L", fn) + bytes([60, 0, 0]) + bits)
                if tn == 2 and fn % 4 == 0:
                    b = [0] * 148
                    b[8:49] = AB_B
                    for i in range(49, 85):
                        b[i] = random.getrandbits(1)
                    self.recu(bytes([tn]) + struct.pack(">L", fn) + bytes([0, 0xA5, 0]) + bytes(b))
                elif tn == 2:
                    b = [random.getrandbits(1) for _ in range(148)]
                    b[61:87] = TSC_B[7]
                    self.recu(bytes([tn]) + struct.pack(">L", fn) + bytes([0, 0xA5, 0]) + bytes(b))
            fn = (fn + 1) % 2715648
            time.sleep(0.004615)


# ── drawing ──────────────────────────────────────────────────────────────────
FOND = (0.0, 0.17, 0.21)          # the terminal background, rgb(0,43,54)
GRILLE = (0.20, 0.30, 0.34)
TEXTE = (0.51, 0.58, 0.59)
AMBRE = (1.0, 0.69, 0.0)
COUL = {"FB": (1.0, 0.84, 0.37), "SB": (0.31, 0.88, 0.83), "AB": (1.0, 0.33, 0.33), "?": (0.36, 0.32, 0.19)}
COUL_TSC = [(0.31, 0.98, 0.48), (0.41, 1.0, 0.58), (0.34, 0.65, 1.0), (0.49, 0.75, 1.0),
            (1.0, 0.47, 0.78), (1.0, 0.57, 0.87), (0.5, 0.95, 0.9), (0.75, 1.0, 0.35)]


def couleur(typ, tsc):
    return COUL_TSC[tsc] if typ == "NB" and tsc is not None else COUL.get(typ, COUL["?"])


def cadre(cr, w, h, titre):
    cr.set_source_rgb(*FOND)
    cr.paint()
    cr.set_source_rgb(*GRILLE)
    cr.set_line_width(1)
    cr.rectangle(0.5, 0.5, w - 1, h - 1)
    cr.stroke()
    cr.set_source_rgb(*AMBRE)
    cr.select_font_face("Ubuntu Mono")
    cr.set_font_size(13)
    cr.move_to(8, 16)
    cr.show_text(titre)


class Fenetre(Gtk.Window):
    def __init__(self, demo):
        super().__init__(title="osmo-ms-pont")
        self.set_default_size(1280, 820)
        self.connect("destroy", Gtk.main_quit)
        self.air = Air()
        self.rng = np.random.default_rng()
        self.sens = "DL"
        self.gel = False
        self.points = collections.deque(maxlen=148 * 24)
        self.yeux = collections.deque(maxlen=30)
        self.dernier = None
        self.mesures = collections.deque(maxlen=50)
        self.debit = {"DL": 0.0, "UL": 0.0}
        self._cpt = (time.monotonic(), 0, 0)
        self.chaine = None

        racine = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        racine.set_border_width(8)
        self.add(racine)

        # the chain: buttons + one state per step
        haut = Gtk.Box(spacing=8)
        racine.pack_start(haut, False, False, 0)
        self.b_go = Gtk.Button(label="Demarrer la chaine")
        self.b_go.connect("clicked", lambda *_: self.lancer([]))
        self.b_stop = Gtk.Button(label="Arreter")
        self.b_stop.connect("clicked", lambda *_: self.lancer(["--stop"]))
        haut.pack_start(self.b_go, False, False, 0)
        haut.pack_start(self.b_stop, False, False, 0)
        self.etats = {}
        for n in ETAPES:
            l = Gtk.Label()
            l.set_use_markup(True)
            haut.pack_start(l, False, False, 6)
            self.etats[n] = l
        if demo:
            self.b_go.set_sensitive(False)
            self.b_stop.set_sensitive(False)
        haut.pack_end(self._choix_sens(), False, False, 0)
        self.b_gel = Gtk.ToggleButton(label="Figer")
        self.b_gel.connect("toggled", lambda b: setattr(self, "gel", b.get_active()))
        haut.pack_end(self.b_gel, False, False, 0)

        # noise: the bench's, or the slider's
        bruit = Gtk.Box(spacing=8)
        racine.pack_start(bruit, False, False, 0)
        self.c_bruit = Gtk.CheckButton(label="bruit blanc, SNR (dB)")
        self.c_bruit.set_active(True)
        self.s_snr = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 40, 1)
        self.s_snr.set_value(20)
        self.s_snr.set_size_request(260, -1)
        self.l_bruit = Gtk.Label(xalign=0)
        bruit.pack_start(self.c_bruit, False, False, 0)
        bruit.pack_start(self.s_snr, False, False, 0)
        bruit.pack_start(self.l_bruit, False, False, 0)
        self.l_info = Gtk.Label(xalign=0)
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_family_new("Ubuntu Mono"))
        self.l_info.set_attributes(attrs)
        bruit.pack_end(self.l_info, False, False, 0)

        # the plots
        g = Gtk.Grid(column_spacing=6, row_spacing=6, column_homogeneous=True, row_homogeneous=True)
        racine.pack_start(g, True, True, 0)
        self.z_const = self._zone(self.dessin_const)
        self.z_oeil = self._zone(self.dessin_oeil)
        self.z_iq = self._zone(self.dessin_iq)
        self.z_corr = self._zone(self.dessin_corr)
        self.z_grille = self._zone(self.dessin_grille)
        g.attach(self.z_const, 0, 0, 1, 2)
        g.attach(self.z_oeil, 1, 0, 1, 1)
        g.attach(self.z_corr, 2, 0, 1, 1)
        g.attach(self.z_iq, 1, 1, 2, 1)
        g.attach(self.z_grille, 0, 2, 3, 1)

        # logs of the chain launch
        self.journal = Gtk.TextView(editable=False, monospace=True)
        self.journal.set_size_request(-1, 90)
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(-1, 100)
        sw.add(self.journal)
        racine.pack_start(sw, False, False, 0)

        threading.Thread(target=self.air.demo if demo else self.air.ecouter, daemon=True).start()
        GLib.timeout_add(60, self.tic)
        GLib.timeout_add(1000, self.tic_etats)
        self.tic_etats()
        self.show_all()

    def _zone(self, f):
        z = Gtk.DrawingArea()
        z.connect("draw", lambda w, cr: f(cr, w.get_allocated_width(), w.get_allocated_height()))
        return z

    def _choix_sens(self):
        b = Gtk.Box(spacing=0)
        r1 = Gtk.RadioButton.new_with_label(None, "descendant")
        r2 = Gtk.RadioButton.new_with_label_from_widget(r1, "montant")
        r1.connect("toggled", lambda r: r.get_active() and self._sens("DL"))
        r2.connect("toggled", lambda r: r.get_active() and self._sens("UL"))
        b.pack_start(r1, False, False, 0)
        b.pack_start(r2, False, False, 0)
        return b

    def _sens(self, s):
        self.sens = s
        self.points.clear()
        self.yeux.clear()
        self.mesures.clear()
        self.dernier = None

    # ── the chain ──────────────────────────────────────────────────────────
    def ecrire(self, txt):
        buf = self.journal.get_buffer()
        buf.insert(buf.get_end_iter(), txt)
        if buf.get_line_count() > 400:
            buf.delete(buf.get_start_iter(), buf.get_iter_at_line(buf.get_line_count() - 400))
        self.journal.scroll_to_iter(buf.get_end_iter(), 0, False, 0, 0)
        return False

    def lancer(self, args):
        argv, env = commande_chaine(args)
        if not argv:
            self.ecrire("run.sh demande root : lancer osmo-ms-pont en root (ou installer pkexec)\n")
            return
        self.ecrire("$ %s\n" % " ".join(argv))

        def suivre():
            try:
                p = subprocess.Popen(argv, env=env, cwd=os.path.dirname(RUN_SH), stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as e:
                GLib.idle_add(self.ecrire, "echec : %s\n" % e)
                return
            for ligne in p.stdout:
                GLib.idle_add(self.ecrire, re.sub(r"\x1b\[[0-9;]*m", "", ligne.decode("utf-8", "replace")))
            GLib.idle_add(self.ecrire, "[fin, code %s]\n" % p.wait())
        threading.Thread(target=suivre, daemon=True).start()

    def tic_etats(self):
        for n in ETAPES:
            p = pid_de(n)
            self.etats[n].set_markup('<span foreground="%s">●</span> %s' % ("#50FA7B" if p else "#FF5555", n))
        snr = snr_du_banc()
        if snr is not None:
            self.s_snr.set_value(snr)
            self.l_bruit.set_text("(celui du banc : CALYPSO_BSP_SNR_DB=%g)" % snr)
        else:
            self.l_bruit.set_text("")
        return True

    # ── processing ─────────────────────────────────────────────────────────
    def tic(self):
        t = time.monotonic()
        with self.air.lock:
            t0, d0, u0 = self._cpt
            if t - t0 >= 1.0:
                self.debit = {"DL": (self.air.compte["DL"] - d0) / (t - t0), "UL": (self.air.compte["UL"] - u0) / (t - t0)}
                self._cpt = (t, self.air.compte["DL"], self.air.compte["UL"])
            lot = list(self.air.file[self.sens])
            self.air.file[self.sens].clear()
        if not self.gel:
            snr = self.s_snr.get_value() if self.c_bruit.get_active() else None
            for fn, tn, bits in lot[-24:]:
                r = recevoir(bits, snr, self.rng)
                r["fn"], r["tn"] = fn, tn
                if "const" in r:
                    self.points.extend(r["const"])
                    self.mesures.append((r["snr"], r["evm"]))
                    self.yeux.append(r["os"].real / max(1e-9, np.max(np.abs(r["os"].real))))
                    self.dernier = r
                elif self.dernier is None:
                    self.dernier = r
            for z in (self.z_const, self.z_oeil, self.z_iq, self.z_corr):
                z.queue_draw()
        self.z_grille.queue_draw()
        d = self.dernier
        snr_m = np.mean([m[0] for m in self.mesures]) if self.mesures else float("nan")
        evm_m = np.mean([m[1] for m in self.mesures]) if self.mesures else float("nan")
        self.l_info.set_text("%s  fn %-7s tn %s  %s%s   SNR %5.1f dB  EVM %5.1f %%   DL %4.0f/s  UL %4.0f/s" % (
            self.sens, d["fn"] if d else "-", d["tn"] if d else "-", d["type"] if d else "-",
            (" TSC%d" % d["tsc"]) if d and d["tsc"] is not None else "", snr_m, evm_m,
            self.debit["DL"], self.debit["UL"]))
        return True

    # ── plots ──────────────────────────────────────────────────────────────
    def dessin_const(self, cr, w, h):
        cadre(cr, w, h, "constellation (derotee, / canal estime) - %s" % self.sens)
        c = min(w, h - 24) / 2 - 12
        cx, cy = w / 2, 24 + (h - 24) / 2
        e = c / 1.6
        cr.set_source_rgb(*GRILLE)
        cr.move_to(cx - c, cy); cr.line_to(cx + c, cy)
        cr.move_to(cx, cy - c); cr.line_to(cx, cy + c)
        cr.stroke()
        for x in (-1, 1):
            cr.arc(cx + x * e, cy, 3, 0, 2 * math.pi)
            cr.stroke()
        pts = np.array(self.points) if self.points else np.zeros(0, complex)
        n = len(pts)
        for i, p in enumerate(pts):
            a = 0.15 + 0.85 * (i / max(1, n))
            cr.set_source_rgba(0.31, 0.98, 0.48, a) if p.real >= 0 else cr.set_source_rgba(0.34, 0.65, 1.0, a)
            cr.rectangle(cx + p.real * e - 1, cy - p.imag * e - 1, 2, 2)
            cr.fill()

    def dessin_oeil(self, cr, w, h):
        cadre(cr, w, h, "diagramme de l'oeil (I, 2 symboles)")
        x0, y0, ww, hh = 10, 26, w - 20, h - 36
        cr.set_source_rgb(*GRILLE)
        cr.move_to(x0, y0 + hh / 2); cr.line_to(x0 + ww, y0 + hh / 2)
        cr.move_to(x0 + ww / 2, y0); cr.line_to(x0 + ww / 2, y0 + hh)
        cr.stroke()
        cr.set_line_width(1)
        L = 2 * OS
        for v in self.yeux:
            cr.set_source_rgba(1.0, 0.69, 0.0, 0.18)
            for k in range(OS // 2, len(v) - L, OS):
                seg = v[k:k + L + 1]
                for j, y in enumerate(seg):
                    X = x0 + ww * j / L
                    Y = y0 + hh / 2 - y * hh * 0.45
                    cr.line_to(X, Y) if j else cr.move_to(X, Y)
                cr.stroke()

    def dessin_iq(self, cr, w, h):
        d = self.dernier
        cadre(cr, w, h, "I/Q de la rafale (8 ech./symbole)%s" % (
            "" if not d else " - fn %d tn %d %s" % (d["fn"], d["tn"], d["type"])))
        if not d:
            return
        x0, y0, ww, hh = 10, 26, w - 20, h - 36
        if d["tl"]:
            cr.set_source_rgba(1.0, 0.69, 0.0, 0.12)
            cr.rectangle(x0 + ww * d["t0"] / 148, y0, ww * d["tl"] / 148, hh)
            cr.fill()
        v = d["os"]
        for comp, col in ((v.real, (0.31, 0.98, 0.48)), (v.imag, (0.34, 0.65, 1.0))):
            cr.set_source_rgb(*col)
            n = len(comp)
            for j, y in enumerate(comp):
                X = x0 + ww * j / n
                Y = y0 + hh / 2 - y * hh * 0.42
                cr.line_to(X, Y) if j else cr.move_to(X, Y)
            cr.stroke()

    def dessin_corr(self, cr, w, h):
        cadre(cr, w, h, "correlation sequence d'apprentissage (TOA)")
        d = self.dernier
        if not d or "corr" not in d:
            return
        c = d["corr"]
        x0, y0, ww, hh = 14, 26, w - 28, h - 46
        m = max(c) or 1
        bw = ww / len(c)
        for i, v in enumerate(c):
            cr.set_source_rgb(*(AMBRE if v == m else (0.36, 0.32, 0.19)))
            cr.rectangle(x0 + i * bw + 2, y0 + hh * (1 - v / m), bw - 4, hh * v / m)
            cr.fill()
            cr.set_source_rgb(*TEXTE)
            cr.set_font_size(10)
            cr.move_to(x0 + i * bw + bw / 2 - 5, y0 + hh + 14)
            cr.show_text("%+d" % (i - 6))
        cr.set_source_rgb(*AMBRE)
        cr.set_font_size(12)
        cr.move_to(w - 110, 34)
        cr.show_text("TOA %+d symb." % (c.index(m) - 6))

    def dessin_grille(self, cr, w, h):
        cadre(cr, w, h, "TDMA %s : 8 timeslots x 51 trames   FB jaune  SB cyan  NB couleur du TSC  AB rouge" % self.sens)
        x0, y0 = 40, 26
        cw, ch = (w - x0 - 10) / 51, (h - y0 - 8) / 8
        now = time.monotonic()
        with self.air.lock:
            gr = dict(self.air.grille[self.sens])
        cr.set_font_size(10)
        for tn in range(8):
            cr.set_source_rgb(*TEXTE)
            cr.move_to(8, y0 + tn * ch + ch * 0.7)
            cr.show_text("TS%d" % tn)
            for m in range(51):
                e = gr.get((tn, m))
                if e and now - e[2] < 2.0:
                    cr.set_source_rgb(*couleur(e[0], e[1]))
                else:
                    cr.set_source_rgb(0.05, 0.22, 0.26)
                cr.rectangle(x0 + m * cw + 1, y0 + tn * ch + 1, cw - 2, ch - 2)
                cr.fill()


def main():
    ap = argparse.ArgumentParser(description="osmo-ms-pont : la chaine mobile (DSP, ARM, osmocon, pont) et son air")
    ap.add_argument("--demo", action="store_true", help="rafales aleatoires, sans la chaine")
    a = ap.parse_args()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    Fenetre(a.demo)
    Gtk.main()


if __name__ == "__main__":
    main()
