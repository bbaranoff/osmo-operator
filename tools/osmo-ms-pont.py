#!/usr/bin/python3
# osmo-ms-pont.py - CONSTELLATION: THE BENCH IN ONE WINDOW, FROM ITS AIR. It
# STARTS the bench (or the chain alone), SHOWS its air (constellation, I/Q),
# its core network, its mobile, and INSTALLS it.
#
#   osmo-gtk / constellation / iq-visual / osmo-ms-pont   the same window (links;
#                                data/desktop/osmo-gtk.desktop, pinned in the dock)
#   osmo-gtk --onglet Kconfig    opens on a tab (Air, Core, L23, Kconfig, Tests,
#                                Telephones, Notebooks, Wiki, Infos, Installation)
#   osmo-ms-pont                 the window; "Demarrage complet" starts the bench
#   osmo-ms-pont --demo          the window fed with random bursts (no chain)
#   OSMO_MS_PONT_PORT=6790       UDP port of the air (copy of the bridge)
#
# THE FULL START. "Demarrage complet" runs launch.sh --service, as the
# launcher's "run standalone": osmo-banc.service brings up the whole bench
# (core network, chain, mobile, bridge; pont_dsp.py copies its bursts to udp
# 6790 by itself). "Arreter" stops osmo-banc.service, then runs run.sh --stop
# (for a chain started alone). "Chaine seule" keeps the
# former start, below.
#
# THE CHAIN ALONE. "Chaine seule" executes the steps of c54x_exe/run.sh WITHOUT the
# mobile (no layer 2/3): 1. c54x_exe --arm (the C54x DSP, TI mask-ROM),
# b. the noise injector (only if BRUIT_MODE is set), 2. qosmo (the ARM +
# osmocom-bb layer 1), 3. osmocon (romload, L1CTL relay), 5. pont_dsp.py
# (PONT=1, the bridge: BTS bursts -> DSP; it does not need the mobile).
# The state of each process is read from the
# pid files of RUNDIR (/tmp/c54x-pont), as ./run.sh --status does. run.sh
# needs root (SCHED_FIFO, taskset, /dev/shm): started as a user, the window
# asks for the root password ONCE (pkexec, see HELPER) and runs every root
# action through that one helper.
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
#   - the I/Q of the last burst of EACH direction, both from the middle line:
#     the MS (uplink) above, drawn upwards, the BTS (downlink) below, drawn
#     downwards; training sequence highlighted;
#   - the correlation with the training sequence (lag -> TOA);
#   - the TDMA grid: 8 timeslots x the 51 frames of the multiframe, coloured by
#     burst type (FB, SB, NB per TSC, access burst, other);
#   - SNR and EVM measured on the training sequence, bursts per second.
# A burst seen here is the bridge's burst; its I/Q is MODELLED, not read in the
# DSP memory (the C54x DARAM is not exported).
#
# THE TABS: Air, Core, L23, Journaux (the logs: dsp, qemu, osmocon, mobile,
# pont, vsp, gdb...; the ARM <-> DSP mailbox, CALYPSO_MAILBOX=1; each Osmocom
# daemon, its file or its journal; osmo-banc, osmo-lte), Kconfig (start.sh --configure and make menuconfig,
# the kernel menu in GTK, kconfiglib), Tests (DSP replay, ROM, TOA, TCH/H;
# $GSM_ROOT/tests: banc-max and each of its rungs, pytest; TTCN-3 suites through
# scripts/ttcn.sh; checks/*), Notebooks (wiki/*.ipynb, runnable cell by cell), Wiki (README,
# wiki/*.md, c54x_exe docs), Infos (machine, isolation, DSP budget, chain,
# services, ports, radio plan, versions), Installation.
# "Installation" (last): the steps of install.sh (--list), their
# state (--check), and buttons: check, install the selected step (--only),
# reinstall it (--only --reinstall), simulate everything (--dry-run), install
# everything; as root through the window's helper, the output in the tab.
# "Air": the plots above. "Core": the network daemons (HLR, MSC,
# BSC, STP, MGW, SGSN, GGSN, PCU, BTS, SIP; same list and VTY ports as
# tools/conky-osmo-status.sh core), their state, a VTY console on the one
# selected and its log: OSMO_CORE_LOGS/<daemon>.log (default /var/log/osmocom)
# when readable, else its systemd journal (journalctl -u, group adm). "L23": the osmocom-bb mobile
# (layer 2/3, step 4 of run.sh, which "Demarrer la chaine" leaves out): start
# it on the running chain, stop it, its log ($RUNDIR/mobile.log) and its VTY
# (the bind port of $MOBILE_CFG, default 4247).
import argparse
import collections
import json
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
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402

GSM_ROOT = os.environ.get("GSM_ROOT", "/opt/GSM")
RUN_SH = os.environ.get("RUN_SH", os.path.join(GSM_ROOT, "c54x_exe", "run.sh"))
RUNDIR = os.environ.get("RUNDIR", "/tmp/c54x-pont")
PORT = int(os.environ.get("OSMO_MS_PONT_PORT", "6790"))
ETAPES = ("dsp", "qemu", "osmocon", "mobile", "pont")
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
INSTALL_SH = os.path.join(REPO, "install.sh")
CORE_LOGS = os.environ.get("OSMO_CORE_LOGS", "/var/log/osmocom")
# name, process (comm, 15 characters at most for pgrep -x), VTY port (0: none)
CORE = (("HLR", "osmo-hlr", 4258), ("MSC", "osmo-msc", 4254), ("BSC", "osmo-bsc", 4242),
        ("STP", "osmo-stp", 4239), ("MGW", "osmo-mgw", 4243), ("SGSN", "osmo-sgsn", 4245),
        ("GGSN", "osmo-ggsn", 4260), ("PCU", "osmo-pcu", 4240), ("BTS", "osmo-bts-trx", 4241),
        ("SIP", "osmo-sip-connector", 4256), ("SMSC", "proto-smsc-daemon", 0), ("PBX", "asterisk", 0))

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
    """Pid of step n if it lives. The chain runs as ROOT and this window as the
    desktop user: kill(pid, 0) then fails with EPERM, which means "it exists"."""
    try:
        with open(os.path.join(RUNDIR, n + ".pid")) as f:
            p = int(f.read().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(p, 0)
    except PermissionError:
        return p
    except OSError:
        return None
    return p


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


def commande_chaine(args, brut=None):
    """argv + env: args = [] runs steps 1, b, 2, 3, 5 (no mobile), else run.sh <args>;
    brut: that argv as is (as root, like run.sh)."""
    env = {"PONT": "1", "PONT_DSP_COPIES": "6762 %d" % PORT}
    if brut:
        base = list(brut)
    elif args:
        base = ["bash", RUN_SH] + args
    else:
        r = RUN_SH.replace("'", "")
        base = ["bash", "-c", "set -e; for e in 1 b 2 3 5; do bash '%s' --step $e; done" % r]
    return base, env


# ── ONE privilege elevation for the whole window ─────────────────────────────
# Started as the desktop user, the window asks for the root password ONCE
# (pkexec, at start or at the first root action): pkexec runs ONE helper,
# HELPER below, which then runs every root action of the window - chain, full
# start, stop, mobile, install.sh, tests, Kconfig save, the notebook kernel -
# and streams their output back. Protocol on its stdin/stdout, one JSON per
# line: {"id", "argv", "env", "cwd", "stdin"} starts a job, {"id", "in"} feeds
# its stdin, {"id", "signal"} signals its process group; back come {"id", "l"}
# (an output line) and {"id", "rc"} (the end). Jobs run in their own session:
# closing the window does not stop a bench it started. Only this window's own
# pipe reaches the helper.
HELPER = r'''
import json, os, subprocess, sys, threading
verrou = threading.Lock()
jobs, attente = {}, {}


def envoyer(d):
    with verrou:
        sys.stdout.write(json.dumps(d) + "\n")
        sys.stdout.flush()


def tache(j, argv, env, cwd, entree):
    try:
        p = subprocess.Popen(argv, env=env, cwd=cwd or "/", stdin=subprocess.PIPE if entree else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as e:
        envoyer({"id": j, "l": "echec : %s\n" % e})
        envoyer({"id": j, "rc": 127})
        return
    with verrou:
        jobs[j] = p
        for t in attente.pop(j, []):
            try:
                p.stdin.write(t.encode())
                p.stdin.flush()
            except OSError:
                pass
    for b in iter(p.stdout.readline, b""):
        envoyer({"id": j, "l": b.decode("utf-8", "replace")})
    rc = p.wait()
    with verrou:
        jobs.pop(j, None)
    envoyer({"id": j, "rc": rc})


base = dict(os.environ)
base["PATH"] = base.get("PATH") or "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
base.setdefault("HOME", "/root")
envoyer({"pret": os.geteuid()})
for ligne in sys.stdin:
    try:
        m = json.loads(ligne)
    except ValueError:
        continue
    j = m.get("id")
    if "argv" in m:
        env = dict(base)
        env.update(m.get("env") or {})
        threading.Thread(target=tache, args=(j, m["argv"], env, m.get("cwd"), m.get("stdin")), daemon=True).start()
    elif "in" in m:
        with verrou:
            p = jobs.get(j)
            if p is None:
                attente.setdefault(j, []).append(m["in"])
                continue
        try:
            p.stdin.write(m["in"].encode())
            p.stdin.flush()
        except OSError:
            pass
    elif "signal" in m:
        with verrou:
            p = jobs.get(j)
        if p:
            try:
                os.killpg(p.pid, m["signal"])
            except OSError:
                pass
'''


class Racine:
    """The root helper, seen from the window (see HELPER)."""

    def __init__(self):
        self.p = None
        self.ok = os.geteuid() == 0
        self.cb = {}
        self.n = 0
        self.lock = threading.Lock()
        self.debut = threading.Lock()
        self.pret = threading.Event()

    def disponible(self):
        return os.geteuid() == 0 or (self.ok and self.p is not None and self.p.poll() is None)

    def demarrer(self):
        """BLOCKING (call it from a thread): the pkexec password, once. True when root is there."""
        with self.debut:
            if self.disponible():
                return True
            pk = shutil.which("pkexec")
            if not pk:
                return False
            self.ok = False
            self.pret.clear()
            try:
                p = subprocess.Popen([pk, "/usr/bin/python3", "-u", "-c", HELPER], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except OSError:
                return False
            self.p = p
            threading.Thread(target=self._lire, args=(p,), daemon=True).start()
            self.pret.wait(900)
            return self.ok

    def _lire(self, p):
        for b in p.stdout:
            try:
                m = json.loads(b)
            except ValueError:
                continue
            if "pret" in m:
                self.ok = m["pret"] == 0
                self.pret.set()
                continue
            c = self.cb.get(m.get("id"))
            if not c:
                continue
            if "l" in m:
                c[0](m["l"])
            elif "rc" in m:
                self.cb.pop(m["id"], None)
                c[1](m["rc"])
        self.ok = False                 # refused, or the helper is gone
        self.pret.set()
        for c in list(self.cb.values()):
            c[1](126)
        self.cb.clear()

    def _envoyer(self, d):
        with self.lock:
            self.p.stdin.write((json.dumps(d) + "\n").encode())
            self.p.stdin.flush()

    def lancer(self, argv, env, cwd, ligne, fin, stdin=False):
        with self.lock:
            self.n += 1
            j = self.n
        self.cb[j] = (ligne, fin)
        try:
            self._envoyer({"id": j, "argv": list(argv), "env": env, "cwd": cwd, "stdin": stdin})
        except (OSError, ValueError):
            self.cb.pop(j, None)
            fin(126)
        return Distant(self, j)


class Distant:
    """A job of the root helper."""

    def __init__(self, r, j):
        self.r, self.j = r, j

    def ecrire(self, t):
        self.r._envoyer({"id": self.j, "in": t})

    def signal(self, sig):
        try:
            self.r._envoyer({"id": self.j, "signal": int(sig)})
        except (OSError, ValueError):
            pass


class Local:
    """A job run directly (window already root, or no root needed)."""

    def __init__(self, p):
        self.p = p

    def ecrire(self, t):
        self.p.stdin.write(t.encode())
        self.p.stdin.flush()

    def signal(self, sig):
        try:
            os.killpg(self.p.pid, sig)
        except OSError:
            pass


def executer(racine, argv, env, cwd, ligne, fin, root=False, stdin=False):
    """Runs argv, as root through `racine` when asked (and the window is not root). ligne(text) per
    output line, fin(rc) at the end, both from a thread. BLOCKING the first time (password): call it
    from a thread. Returns a handle (.ecrire, .signal) or None."""
    if root and os.geteuid() != 0:
        if not racine.demarrer():
            ligne("root refuse (mot de passe) ou pkexec absent : action non lancee\n")
            fin(126)
            return None
        return racine.lancer(argv, env, cwd, ligne, fin, stdin)
    try:
        p = subprocess.Popen(argv, env=dict(os.environ, **env), cwd=cwd, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as e:
        ligne("echec : %s\n" % e)
        fin(127)
        return None

    def suivre():
        for b in p.stdout:
            ligne(b.decode("utf-8", "replace"))
        fin(p.wait())
    threading.Thread(target=suivre, daemon=True).start()
    return Local(p)


def port_mobile():
    cfg = os.environ.get("MOBILE_CFG", os.path.join(os.path.dirname(RUN_SH), "mobile_pont.cfg"))
    try:
        with open(cfg) as f:
            for l in f:
                m = re.match(r"\s*bind 127\.0\.0\.1 (\d+)", l)
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 4247


# WHICH PROCESSES LIVE: ONE scan of /proc/*/comm every 2 s, in a background
# thread (about 20 ms), instead of one pgrep per daemon in the GTK loop (12
# pgrep = 0.46 s, twice every 2 s: the window stalled, and so did the desktop's
# few cpus once isoler.sh had reserved the others).
_PROCS = {"noms": set(), "parti": False}


def _veilleur_procs():
    while True:
        noms = set()
        try:
            ds = os.listdir("/proc")
        except OSError:
            ds = []
        for d in ds:
            if d.isdigit():
                try:
                    with open("/proc/%s/comm" % d) as f:
                        noms.add(f.read().strip())
                except OSError:
                    pass
        _PROCS["noms"] = noms
        time.sleep(2)


def pid_proc(nom):
    """True when a process of that name (comm, 15 characters) lives."""
    if not _PROCS["parti"]:
        _PROCS["parti"] = True
        threading.Thread(target=_veilleur_procs, daemon=True).start()
    return nom[:15] in _PROCS["noms"]


def vty(port, commandes, delai=3.0):
    """Runs the commands on the Osmocom VTY 127.0.0.1:port (after "enable"), returns the text."""
    invite = re.compile(rb"\r?\n?[\w.-]+(\([\w-]+\))?[>#] $")

    def lire(sk):
        buf = b""
        fin = time.monotonic() + delai
        while time.monotonic() < fin:
            try:
                d = sk.recv(65536)
            except socket.timeout:
                continue
            if not d:
                break
            buf += d
            if invite.search(buf):
                break
        return buf

    try:
        with socket.create_connection(("127.0.0.1", port), timeout=delai) as sk:
            sk.settimeout(0.3)
            lire(sk)
            sorties = []
            for c in ["enable"] + list(commandes):
                sk.sendall(c.encode() + b"\n")
                r = lire(sk)
                if c != "enable":
                    sorties.append(r)
            sk.sendall(b"exit\n")
    except OSError as e:
        return "VTY %d : %s\n" % (port, e)
    txt = b"".join(sorties).decode("utf-8", "replace").replace("\r", "")
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt)


def queue(chemin, n=300, ansi=False):
    """The last n lines of a file; ansi: keep the colour codes (the coloured log views read them)."""
    try:
        with open(chemin, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200000))
            lignes = f.read().decode("utf-8", "replace").splitlines()[-n:]
        t = "\n".join(lignes) + "\n"
        return t if ansi else re.sub(r"\x1b\[[0-9;]*m", "", t)
    except OSError:
        return None


# ── LOG COLOURS ──────────────────────────────────────────────────────────────
# The log views (Journaux, Core, L23, Tests) are dark, like a terminal. A line
# that carries ANSI colour codes (the Osmocom log files) is shown with THEM;
# the others (journalctl, the bench, the tests) are coloured from what they
# say. colorer() runs in the worker thread: the GTK loop only inserts.
C_GRIS, C_ATTENUE, C_TEXTE = "#7f849c", "#585b70", "#cdd6f4"
C_ROUGE, C_JAUNE, C_VERT, C_ORANGE = "#f38ba8", "#f9e2af", "#a6e3a1", "#fab387"
C_CYAN, C_BLEU, C_VIOLET, C_ROSE = "#89dceb", "#89b4fa", "#cba6f7", "#f5c2e7"
_ANSI_BASE = ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
              "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#ffffff"]


def _ansi256(n):
    if n < 16:
        return _ANSI_BASE[n]
    if n < 232:
        n -= 16
        v = [0, 95, 135, 175, 215, 255]
        r, g, b = v[n // 36], v[n // 6 % 6], v[n % 6]
        # the dark cube colours (osmocom's 38;5;23) would vanish on a dark background: lightened
        if r + g + b < 200:
            r, g, b = (min(255, x + 90) for x in (r, g, b))
        return "#%02x%02x%02x" % (r, g, b)
    g = 8 + 10 * (n - 232)
    return "#%02x%02x%02x" % ((max(g, 110),) * 3)


def _ansi(ligne):
    """[(text, colour, bold)] of a line with SGR codes."""
    out, coul, gras = [], None, False
    for i, morceau in enumerate(re.split(r"\x1b\[([0-9;]*)m", ligne)):
        if i % 2 == 0:
            if morceau:
                out.append((morceau, coul, gras))
            continue
        codes = [int(c) for c in morceau.split(";") if c.isdigit()] or [0]
        k = 0
        while k < len(codes):
            c = codes[k]
            if c == 0:
                coul, gras = None, False
            elif c == 1:
                gras = True
            elif c == 22:
                gras = False
            elif 30 <= c <= 37:
                coul = _ANSI_BASE[c - 30 + (8 if gras else 0)]
            elif 90 <= c <= 97:
                coul = _ANSI_BASE[c - 90 + 8]
            elif c == 39:
                coul = None
            elif c == 38 and k + 2 < len(codes) and codes[k + 1] == 5:
                coul = _ansi256(codes[k + 2])
                k += 2
            elif c == 38 and k + 4 < len(codes) and codes[k + 1] == 2:
                coul = "#%02x%02x%02x" % tuple(codes[k + 2:k + 5])
                k += 4
            k += 1
    return out


# (regex, colour, bold), applied in order: a later rule wins on the characters it covers
_REGLES = [
    (re.compile(r"0x[0-9a-fA-F]+"), C_ATTENUE, False),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), C_BLEU, False),
    (re.compile(r"\b[\w./-]+\.(?:c|h|py|sh|cpp):\d+\b"), C_BLEU, False),
    (re.compile(r"<[0-9a-f]{4}>"), C_VIOLET, False),
    (re.compile(r"\b(?:IMSI|MSISDN|TMSI)[-=:][\w-]+|\b\d{15}\b"), C_ROSE, False),
    (re.compile(r"\bDEBUG\b"), C_GRIS, False),
    (re.compile(r"\bINFO\b"), C_VERT, False),
    (re.compile(r"\b(?:NOTICE|WARNING|WARN|warning)\b"), C_JAUNE, True),
    (re.compile(r"\b(?:Started|Starting|Reached|connected|accept\(\)ed|successful(?:ly)?|OK|ok|PASS(?:ED)?|DECODED)\b"), C_VERT, False),
    (re.compile(r"\b(?:Stopping|Stopped|Deactivated|Terminating|Scheduled restart|restart counter is at \d+|signal=\d+)"), C_ORANGE, False),
    (re.compile(r"\b(?:ERROR|FATAL|CRITICAL|Error|error|Failed|failed|FAILURE|FAILED|FAIL|Traceback|exit-code|"
                r"refused|timeout|TIMEOUT|segfault|Aborted|KO)\b|status=[1-9]\d*"), C_ROUGE, True),
    (re.compile(r"\[ OK \]|\[ +OK +\]|● ok|✓"), C_VERT, True),
    (re.compile(r"\[SKIP\]|\[ \.\. \]"), C_GRIS, False),
    (re.compile(r"\[FAIL\]|\[ KO \]|\[ECHEC\]|✗"), C_ROUGE, True),
    (re.compile(r"^\[fin, code 0\]$"), C_VERT, True),
    (re.compile(r"^\[fin, code [1-9]\d*\]$"), C_ROUGE, True),
    (re.compile(r"^\$ .*"), C_CYAN, True),
]
# a journalctl line: "nov. 23 15:06:38.566241 acer osmo-hlr[3320910]: message"
_JOURNAL = re.compile(r"^(\S+\.? \d+ \d\d:\d\d:\d\d(?:\.\d+)?) (\S+) ([^\s\[:]+)(\[\d+\])?: ")
_HORO = re.compile(r"^(?:\d{17}|\d{4}-\d\d-\d\d[ T][\d:.]+|\d\d:\d\d:\d\d(?:\.\d+)?) ")
_TALLOC = re.compile(r"full talloc report|contains +\d+ bytes in +\d+ blocks")


def _heuristique(ligne):
    n = len(ligne)
    coul = [None] * n
    gras = [False] * n

    def poser(a, b, c, g=False):
        for k in range(a, min(b, n)):
            coul[k] = c
            gras[k] = g
    debut = 0
    m = _JOURNAL.match(ligne)
    if m:
        poser(m.start(1), m.end(1), C_GRIS)
        poser(m.start(2), m.end(2), C_ATTENUE)
        poser(m.start(3), m.end(3), C_CYAN, True)
        if m.group(4):
            poser(m.start(4), m.end(4), C_ATTENUE)
        debut = m.end()
    h = _HORO.match(ligne[debut:])
    if h:
        poser(debut, debut + h.end(), C_GRIS)
    if _TALLOC.search(ligne, debut):
        poser(debut, n, C_ATTENUE)          # the memory report printed at every clean exit
    else:
        for rx, c, g in _REGLES:
            for mm in rx.finditer(ligne, debut):
                poser(mm.start(), mm.end(), c, g)
    out, k = [], 0
    while k < n:
        j = k
        while j < n and coul[j] == coul[k] and gras[j] == gras[k]:
            j += 1
        out.append((ligne[k:j], coul[k], gras[k]))
        k = j
    return out


def _vers_la_fin_tv(t):
    """Shows the end of the TextView t. scroll_to_iter (and even scroll_to_mark)
    right after set_text does nothing: the line heights are not computed yet,
    and the log stayed at the top. The scrollbar is put at the bottom once GTK
    is idle, when the heights are known (measured: idle -> bottom,
    scroll_to_iter/scroll_to_mark -> top)."""
    def bas():
        a = t.get_vadjustment()
        if a is not None:
            a.set_value(a.get_upper() - a.get_page_size())
        return False
    GLib.idle_add(bas, priority=GLib.PRIORITY_LOW)


def colorer(txt):
    """[(text, colour or None, bold)] for a whole text, line by line, newlines included."""
    segs = []
    for ligne in txt.split("\n"):
        segs.extend(_ansi(ligne) if "\x1b[" in ligne else _heuristique(ligne))
        segs.append(("\n", None, False))
    if segs:
        segs.pop()
    return segs


C54X = os.path.dirname(RUN_SH)
WIKI = os.path.join(REPO, "wiki")
NOTEBOOKS = sorted(os.path.join(WIKI, f) for f in (os.listdir(WIKI) if os.path.isdir(WIKI) else [])
                   if f.endswith(".ipynb"))


def _pages_wiki():
    p = [("README (osmo-operator)", os.path.join(REPO, "README.md"))]
    if os.path.isdir(WIKI):
        noms = sorted(f for f in os.listdir(WIKI) if f.endswith(".md"))
        noms.sort(key=lambda f: f != "Home.md")
        p += [(f[:-3].replace("-", " "), os.path.join(WIKI, f)) for f in noms]
    for f in ("README.md", "LAUNCH.md", "MAILBOX.md", "proof_toa_23.md"):
        p.append(("c54x_exe : " + f[:-3], os.path.join(C54X, f)))
    d = os.path.join(C54X, "docs")
    if os.path.isdir(d):
        p += [("c54x_exe : " + f[:-3], os.path.join(d, f)) for f in sorted(os.listdir(d)) if f.endswith(".md")]
    return [x for x in p if os.path.exists(x[1])]


PAGES_WIKI = _pages_wiki()


def _start_config():
    try:
        return subprocess.run(["bash", os.path.join(REPO, "tools", "start-config.sh"), "--path"], capture_output=True,
                              text=True, timeout=10).stdout.strip() or "/etc/osmocom/start.config"
    except (OSError, subprocess.TimeoutExpired):
        return "/etc/osmocom/start.config"


# title, Kconfig (relative to REPO), configuration written, generator run first
KCONFIGS = (("Demarrage du banc (start.sh --configure)", "kconfig/start/Kconfig", _start_config, "start"),
            ("Build et ISO (make menuconfig)", "Kconfig", os.path.join(REPO, ".config"), "build"))


def kc_arbre():
    """The tree the Kconfig files are read from ($srctree). The generators write
    kconfig/generated and kconfig/start/generated INSIDE the repository: on an
    installed bench the repository belongs to root and the window runs as the
    session account - "mkdir: Permission denied", then Kconfig.build "not found".
    The repository itself when it can be written; otherwise a tree of LINKS to it
    in the user's cache, where only the two generated/ directories are real."""
    if all(os.access(os.path.join(REPO, d), os.W_OK) for d in ("kconfig", "kconfig/start")):
        return REPO
    ombre = os.path.join(GLib.get_user_cache_dir(), "osmo-operator", "kconfig-src")

    def lier(src, dst):
        if os.path.islink(dst) and os.readlink(dst) == src:
            return
        if os.path.islink(dst) or os.path.isfile(dst):
            os.unlink(dst)
        if not os.path.exists(dst):
            os.symlink(src, dst)

    for d in ("kconfig/generated", "kconfig/start/generated"):
        os.makedirs(os.path.join(ombre, d), exist_ok=True)
    for rel, sauf in (("", ("kconfig",)), ("kconfig", ("start", "generated")), ("kconfig/start", ("generated",))):
        for e in os.listdir(os.path.join(REPO, rel)):
            if e not in sauf:
                lier(os.path.join(REPO, rel, e), os.path.join(ombre, rel, e))
    return ombre


def kc_generateurs(quoi, arbre):
    """The commands that write the generated Kconfig parts of `quoi` into `arbre`."""
    if quoi == "start":
        return [["bash", os.path.join(REPO, "kconfig/start/gen-start.sh"), os.path.join(arbre, "kconfig/start/generated")]]
    if arbre == REPO:
        return [["make", "-s", "kconfig-gen"]]
    g = os.path.join(arbre, "kconfig/generated")
    return [["bash", os.path.join(REPO, "kconfig/gen-features.sh"), g],
            ["bash", os.path.join(REPO, "kconfig/gen-params.sh"), "build", os.path.join(g, "Kconfig.params")]]

KC_VERROU = threading.Lock()
TESTS_DIR = os.environ.get("OSMO_TESTS", os.path.join(GSM_ROOT, "tests"))


def _barreaux():
    """The rungs of banc-max.sh (--list): name, description."""
    try:
        out = subprocess.run(["bash", os.path.join(TESTS_DIR, "banc-max.sh"), "--list"], capture_output=True,
                             text=True, timeout=20, cwd=TESTS_DIR).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [(m.group(1), m.group(2)) for m in (re.match(r"^\s{2}(\S+)\s+(.*)", l) for l in out.splitlines()) if m]


# group, name, argv, cwd, root, condition: "" (alone), "banc" (bench running), "lance" (starts the bench
# itself), "arret" (bench STOPPED: same ports), "long" (installs / compiles)
def _tests():
    T = [
        ("DSP et emulation", "Rejeu DSP : acquisition FB/SB deterministe", ["./c54x_exe", "--rejouer", "--trames", "4000"], C54X, False, ""),
        ("DSP et emulation", "ROM du DSP (verif_rom.sh)", ["bash", "verif_rom.sh"], C54X, False, ""),
        ("DSP et emulation", "TOA 23 : preuve reproduite (repro_toa.sh)", ["bash", "repro_toa.sh"], C54X, False, "long"),
        ("DSP et emulation", "TCH/H du pont contre osmo-bts (pont.tests_tchh)", ["python3", "-m", "pont.tests_tchh"], REPO, False, ""),
    ]
    bm = os.path.join(TESTS_DIR, "banc-max.sh")
    if os.path.exists(bm):
        T += [
            ("banc-max : l'echelle", "banc-max : DSP, redemarre, jusqu'au bout (defaut)", ["bash", "banc-max.sh"], TESTS_DIR, True, "lance"),
            ("banc-max : l'echelle", "banc-max --dsp : sur la pile en cours", ["bash", "banc-max.sh", "--dsp", "--continue"], TESTS_DIR, True, "banc"),
            ("banc-max : l'echelle", "banc-max --grgsm --restart : couche 1 gr-gsm", ["bash", "banc-max.sh", "--grgsm", "--restart", "--continue"], TESTS_DIR, True, "lance"),
            ("banc-max : l'echelle", "banc-max --campagne : grgsm puis dsp + rapport", ["bash", "banc-max.sh", "--campagne"], TESTS_DIR, True, "lance"),
            ("banc-max : l'echelle", "banc-max --full : 2 couches 1, 4G, multi, voix", ["bash", "banc-max.sh", "--full", "--continue"], TESTS_DIR, True, "lance"),
            ("banc-max : l'echelle", "banc-max --ms2 --data : + MS#2 et GPRS", ["bash", "banc-max.sh", "--dsp", "--continue", "--ms2", "--data"], TESTS_DIR, True, "banc"),
        ]
        for nom, desc in _barreaux():
            T.append(("banc-max : un barreau", "%s : %s" % (nom, desc[:70]), ["bash", "banc-max.sh", "--dsp", "--continue",
                      "--only=%s" % nom], TESTS_DIR, True, "banc"))
        if os.path.exists(os.path.join(TESTS_DIR, "sms-rafale.sh")):
            T.append(("banc-max : l'echelle", "sms-rafale.sh 5 : cinq SMS MO un par un", ["bash", "sms-rafale.sh", "5"], TESTS_DIR, True, "banc"))
    py = os.path.join(TESTS_DIR, "pytest")
    if os.path.isdir(py):
        # the SYSTEM python (apt python3-pytest), not the /root/.env venv that
        # run_tests.sh takes by default: the venv has no pytest
        T.append(("pytest (pile vivante)", "pytest : toute la suite (run_tests.sh)",
                  ["env", "CALYPSO_PY=/usr/bin/python3", "bash", "run_tests.sh"], py, True, "banc"))
        for f in sorted(os.listdir(py)):
            if f.startswith("test_") and f.endswith(".py"):
                T.append(("pytest (pile vivante)", "pytest %s" % f[:-3], ["/usr/bin/python3", "-m", "pytest", "-v", f], py, True, "banc"))
    if os.path.exists(os.path.join(REPO, "scripts", "ttcn.sh")):
        tt = ["bash", "scripts/ttcn.sh"]
        T += [
            ("TTCN-3 (osmo-ttcn3-hacks + TITAN)", "TTCN : installer eclipse-titan", tt + ["titan"], REPO, True, "long"),
            ("TTCN-3 (osmo-ttcn3-hacks + TITAN)", "TTCN : sources des suites", tt + ["sources"], REPO, True, "long"),
            ("TTCN-3 (osmo-ttcn3-hacks + TITAN)", "TTCN : compiler les suites", tt + ["build"], REPO, True, "long"),
        ]
        for suite in os.environ.get("TTCN_SUITES", "hlr stp mgw sip").split():
            T.append(("TTCN-3 (osmo-ttcn3-hacks + TITAN)", "TTCN : suite %s contre les binaires du banc" % suite,
                      tt + ["run", suite], REPO, True, "arret"))
        T.append(("TTCN-3 (osmo-ttcn3-hacks + TITAN)", "TTCN : toutes les suites + zip", ["bash", "-c",
                  "bash scripts/ttcn.sh run && bash scripts/ttcn.sh pack"], REPO, True, "arret"))
    T += [
        ("Depot : verifications", "Verification de l'installation (install.sh --only verify)", ["bash", "install.sh", "--only", "verify"], REPO, True, ""),
        ("Depot : verifications", "Sante de chaque composant Osmocom (global_check.sh)", ["bash", "checks/global_check.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Toutes les verifications (check_all.sh)", ["bash", "checks/check_all.sh"], REPO, True, "banc"),
        ("Depot : verifications", "SS7 : architecture inter-STP (ss7_check.sh)", ["bash", "checks/ss7_check.sh"], REPO, True, "banc"),
        ("Depot : verifications", "SS7 sur le WAN (wan_ss7_check.sh)", ["bash", "checks/wan_ss7_check.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Resume des operateurs (operator_summary.sh)", ["bash", "checks/operator_summary.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Annuaire des abonnes (annuaire.sh)", ["bash", "checks/annuaire.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Diagnostic inter-STP (diag-interstp.sh)", ["bash", "checks/diag-interstp.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Diagnostic STP de l'operateur (diag-stp-operator.sh)", ["bash", "checks/diag-stp-operator.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Dump de toutes les VTY (vty-debug-dump.sh)", ["bash", "checks/vty-debug-dump.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Console SS7 : toutes les commandes (test-console.sh)", ["bash", "navigation/test-console.sh"], REPO, True, "banc"),
        ("Depot : verifications", "Etat CS7 (scripts/check.sh)", ["bash", "scripts/check.sh"], REPO, True, "banc"),
    ]

    def present(t):
        cible = next((a for a in t[2] if a.endswith((".sh", ".py")) or a.startswith("./")), None)
        return cible is None or os.path.exists(os.path.join(t[3], cible))
    return tuple(t for t in T if present(t))


TESTS = _tests()
CONDITIONS = {"": "seul", "banc": "banc lance", "lance": "lance le banc", "arret": "banc ARRETE", "long": "installe / long"}

# the notebook kernel (see _onglet_notebooks)
NOYAU = r'''
import ast, json, os, subprocess, sys, tempfile, traceback, types
ns = {"__name__": "__main__"}


def display(*objs, **_kw):
    """IPython.display.display, for the window: an image (PIL) goes to the cell as a picture."""
    for o in objs:
        if hasattr(o, "save") and hasattr(o, "size"):
            f = tempfile.NamedTemporaryFile(prefix="constellation-", suffix=".png", delete=False)
            o.save(f, "PNG")
            f.close()
            os.chmod(f.name, 0o644)         # the kernel may be root, the window is not
            print("\x00IMG " + f.name, flush=True)
        else:
            print(o if isinstance(o, str) else repr(o), flush=True)


try:
    import IPython.display  # noqa: F401  (the real one when installed)
except ImportError:
    _ip, _ipd = types.ModuleType("IPython"), types.ModuleType("IPython.display")
    _ipd.display = display
    _ip.display = _ipd
    sys.modules["IPython"], sys.modules["IPython.display"] = _ip, _ipd
ns["display"] = display
while True:
    try:
        ligne = sys.stdin.readline()
    except KeyboardInterrupt:
        continue
    if not ligne:
        break
    m = json.loads(ligne)
    code, rc = m["code"], 0
    try:
        if code.lstrip().startswith("%%bash"):
            corps = code.lstrip().split("\n", 1)
            rc = subprocess.run(["bash", "-c", corps[1] if len(corps) > 1 else ""]).returncode
        else:
            t = ast.parse(code)
            fin = t.body.pop() if t.body and isinstance(t.body[-1], ast.Expr) else None
            exec(compile(t, "<cellule %d>" % m["id"], "exec"), ns)
            if fin is not None:
                v = eval(compile(ast.Expression(fin.value), "<cellule %d>" % m["id"], "eval"), ns)
                if v is not None:
                    display(v)
    except KeyboardInterrupt:
        print("interrompu"); rc = 130
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 1
    except BaseException:
        traceback.print_exc(); rc = 1
    sys.stdout.flush(); sys.stderr.flush()
    print("\x00FIN %d %d" % (m["id"], rc), flush=True)
'''


def _rgba(c):
    from gi.repository import Gdk
    r = Gdk.RGBA()
    r.parse(c)
    return r


def _inline_pango(t):
    t = GLib.markup_escape_text(t)
    t = re.sub(r"`([^`]+)`", r'<tt><span background="#ececec">\1</span></tt>', t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"(?<![\w*])\*([^*\s][^*]*)\*(?!\w)", r"<i>\1</i>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<span foreground="#1f6feb">\1</span>', t)
    return t


def md_pango(src):
    """Markdown of a notebook cell -> Pango markup (headers, code, bold, lists)."""
    out, bloc = [], False
    for l in src.splitlines():
        if l.strip().startswith("```"):
            bloc = not bloc
            continue
        if bloc:
            out.append('<tt><span background="#ececec">%s</span></tt>' % GLib.markup_escape_text(l))
            continue
        m = re.match(r"^(#{1,6})\s+(.*)", l)
        if m:
            taille = {1: "x-large", 2: "large", 3: "medium"}.get(len(m.group(1)), "medium")
            out.append('<span size="%s"><b>%s</b></span>' % (taille, _inline_pango(m.group(2))))
        elif re.match(r"^\s*[-*]\s+", l):
            out.append("  • " + _inline_pango(re.sub(r"^\s*[-*]\s+", "", l)))
        else:
            out.append(_inline_pango(l))
    return "\n".join(out)


NB_CSS = b"""
.nb-fond { background-color: #eef1f5; }
.nb-md, .nb-md text { background-color: transparent; color: #1f2328; }
.nb-carte { background-color: #ffffff; border: 1px solid #d0d7de; border-radius: 10px;
            box-shadow: 0 1px 3px rgba(27,31,36,0.12); }
.nb-carte.nb-encours { border-color: #d4a72c; box-shadow: 0 0 0 2px rgba(212,167,44,0.35); }
.nb-carte.nb-ok { border-left: 4px solid #2da44e; }
.nb-carte.nb-ko { border-left: 4px solid #cf222e; }
.nb-entete { padding: 4px 8px; }
.nb-num { font-family: "Ubuntu Mono", monospace; color: #6e7781; }
button.nb-run { border-radius: 16px; min-width: 30px; min-height: 30px; padding: 0;
                background-image: none; background-color: #1f6feb; color: #ffffff; border: none; }
button.nb-run:hover { background-color: #388bfd; }
.nb-code, .nb-code text { background-color: #1e1e2e; color: #cdd6f4; }
.nb-code { border-radius: 6px; padding: 8px 10px; font-family: "Ubuntu Mono", monospace; }
.nb-sortie, .nb-sortie text { background-color: #11111b; color: #cdd6f4; }
.nb-sortie { border-radius: 6px; padding: 8px 10px; font-family: "Ubuntu Mono", monospace; }
.nb-barre { padding: 6px; background-color: #ffffff; border-bottom: 1px solid #d0d7de; }
.nb-pastille { border-radius: 10px; padding: 2px 10px; background-color: #ddf4ff; color: #0969da; }
"""

_PY_MOTS = (r"\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|"
            r"finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b")
_Q3, _A3 = '"' * 3, "'" * 3
_PY_JETONS = re.compile(
    r"(?P<com>#[^\n]*)"
    r"|(?P<chaine>[rbfRBF]{0,2}(?:" + _Q3 + r"[\s\S]*?" + _Q3 + "|" + _A3 + r"[\s\S]*?" + _A3
    + r"|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'))"
    r"|(?P<magie>^[ \t]*[!%][^\n]*)"
    r"|(?P<mot>" + _PY_MOTS + r")"
    r"|(?P<nombre>\b0[xX][0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"
    r"|(?P<appel>\b[A-Za-z_]\w*(?=\())", re.M)
_PY_COUL = {"com": "#6c7086", "chaine": "#a6e3a1", "magie": "#f9e2af", "mot": "#cba6f7",
            "nombre": "#fab387", "appel": "#89b4fa", "var": "#f5c2e7"}
_SH_MOTS = (r"\b(?:if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|exit|local|export|"
            r"set|unset|source|cd|echo|printf|test|sudo|trap|shift|read|eval|exec)\b")
_SH_JETONS = re.compile(
    r"(?P<magie>^%%[^\n]*)"
    r"|(?P<com>(?:^|(?<=\s))#[^\n]*)"
    r"|(?P<chaine>\"(?:\\.|[^\"\\])*\"|'[^']*')"
    r"|(?P<var>\$\{[^}]*\}|\$[A-Za-z_]\w*|\$[0-9@#?*!$-])"
    r"|(?P<mot>" + _SH_MOTS + r")"
    r"|(?P<nombre>(?<![\w.-])\d+(?![\w.-]))", re.M)


def py_colorer(buf):
    """Syntax colours of a code cell (Python; lines starting with ! or % as shell)."""
    tt = buf.get_tag_table()
    for nom, coul in _PY_COUL.items():
        if not tt.lookup("py-" + nom):
            buf.create_tag("py-" + nom, foreground=coul,
                           **({"style": Pango.Style.ITALIC} if nom == "com" else {}))
    a, z = buf.get_start_iter(), buf.get_end_iter()
    for nom in _PY_COUL:
        buf.remove_tag_by_name("py-" + nom, a, z)
    txt = buf.get_text(a, z, False)
    jetons = _SH_JETONS if re.match(r"\s*%%(bash|sh|script)", txt) else _PY_JETONS
    for m in jetons.finditer(txt):
        buf.apply_tag_by_name("py-" + m.lastgroup, buf.get_iter_at_offset(m.start()), buf.get_iter_at_offset(m.end()))


_MD_EN_LIGNE = re.compile(
    r"`([^`]+)`"                                   # 1 code
    r"|!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"   # 2,3 image
    r"|\[((?:[^\]\[]|\[[^\]]*\])+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"   # 4,5 link
    r"|\*\*(.+?)\*\*|__(.+?)__"                    # 6,7 bold
    r"|~~(.+?)~~"                                  # 8 strike
    r"|(?<![\w*])\*([^*\s](?:[^*]*[^*\s])?)\*(?!\w)"   # 9 italic
    r"|(?<![\w_])_([^_\s](?:[^_]*[^_\s])?)_(?!\w)"     # 10 italic
    r"|<(https?://[^>\s]+)>"                       # 11 bare link
    r"|<img\s[^>]*?src=\"([^\"]+)\"[^>]*>"         # 12 html image
    r"|<br\s*/?>"                                  # line break
    r"|</?[a-zA-Z][^>]*>")                         # any other html tag: dropped


def md_segments(t, tags=()):
    """One line of Markdown -> [(text, tags, link, image)]: the inline marks
    interpreted, nested ones included (a link inside bold...)."""
    out, pos = [], 0
    for m in _MD_EN_LIGNE.finditer(t):
        if m.start() > pos:
            out.append((t[pos:m.start()], tags, None, None))
        pos = m.end()
        g = m.groups()
        if g[0] is not None:
            out.append((g[0], tags + ("code",), None, None))
        elif g[2] is not None:
            out.append((g[1] or "", tags, None, g[2]))
        elif g[4] is not None:
            out += [(x, tg + ("lien",), g[4], im) for x, tg, _l, im in md_segments(g[3], tags)]
        elif g[5] is not None or g[6] is not None:
            out += md_segments(g[5] if g[5] is not None else g[6], tags + ("gras",))
        elif g[7] is not None:
            out += md_segments(g[7], tags + ("barre",))
        elif g[8] is not None or g[9] is not None:
            out += md_segments(g[8] if g[8] is not None else g[9], tags + ("ital",))
        elif g[10] is not None:
            out.append((g[10], tags + ("lien",), g[10], None))
        elif g[11] is not None:
            out.append(("", tags, None, g[11]))
        elif m.group(0).lower().startswith("<br"):
            out.append(("\n", tags, None, None))
    if pos < len(t):
        out.append((t[pos:], tags, None, None))
    return out


def md_markup(t):
    """One line of Markdown -> Pango markup for a Gtk.Label (table cells):
    links are real <a href>."""
    out = []
    for txt, tags, lien, image in md_segments(t):
        if image and not txt:
            txt = "[image]"
        x = GLib.markup_escape_text(txt)
        if "code" in tags:
            x = '<tt><span background="#ececec" foreground="#202020">%s</span></tt>' % x
        if "gras" in tags:
            x = "<b>%s</b>" % x
        if "ital" in tags:
            x = "<i>%s</i>" % x
        if "barre" in tags:
            x = "<s>%s</s>" % x
        if lien:
            x = '<a href="%s">%s</a>' % (GLib.markup_escape_text(lien), x)
        out.append(x)
    return "".join(out)


def md_tags(buf):
    """The tags md_buffer writes with (created once per buffer)."""
    if buf.get_tag_table().lookup("h1"):
        return
    mono = "Ubuntu Mono"
    buf.create_tag("h1", weight=Pango.Weight.BOLD, scale=1.7, pixels_above_lines=14, pixels_below_lines=8)
    buf.create_tag("h2", weight=Pango.Weight.BOLD, scale=1.4, pixels_above_lines=14, pixels_below_lines=6)
    buf.create_tag("h3", weight=Pango.Weight.BOLD, scale=1.18, pixels_above_lines=10, pixels_below_lines=4)
    buf.create_tag("h4", weight=Pango.Weight.BOLD, pixels_above_lines=8, pixels_below_lines=2)
    buf.create_tag("code", family=mono, background="#ececec", foreground="#202020")
    buf.create_tag("bloc", family=mono, paragraph_background="#f2f2f2", foreground="#202020",
                   wrap_mode=Gtk.WrapMode.NONE, left_margin=28, right_margin=16)
    buf.create_tag("table", family=mono, wrap_mode=Gtk.WrapMode.NONE)
    buf.create_tag("gras", weight=Pango.Weight.BOLD)
    buf.create_tag("ital", style=Pango.Style.ITALIC)
    buf.create_tag("barre", strikethrough=True)
    buf.create_tag("lien", foreground="#1f6feb", underline=Pango.Underline.SINGLE)
    buf.create_tag("cite", left_margin=34, style=Pango.Style.ITALIC, foreground="#4a5560",
                   paragraph_background="#f3f6fa", pixels_above_lines=3, pixels_below_lines=3)
    buf.create_tag("regle", foreground="#b8b8b8", justification=Gtk.Justification.CENTER)
    buf.create_tag("para", pixels_below_lines=7)
    for k in range(4):
        buf.create_tag("puce%d" % k, left_margin=30 + 24 * k, indent=-14, pixels_below_lines=2)
    buf.create_tag("trouve", background="#ffe066")


def md_buffer(buf, texte, vue=None, base=None, ouvrir=None):
    """Markdown page -> TextBuffer, INTERPRETED: headings, paragraphs (soft
    line breaks joined), bold/italic/strike/code, links (clickable through
    buf.md_liens: tag -> target), quotes, rules, nested and numbered lists,
    task boxes, fenced code, images (local files, shown in the page) and
    TABLES - real grids of cells when the view is given (child anchors),
    aligned text otherwise. base: directory the page's relative paths start
    from. ouvrir(target): called by a click on a link in a table cell."""
    md_tags(buf)
    buf.set_text("")
    buf.md_liens = {}
    largeur = 900

    def fin():
        return buf.get_end_iter()

    def image(src, alt):
        if re.match(r"^[a-z]+://", src):
            return False
        f = os.path.normpath(os.path.join(base or "", src.split("#")[0]))
        try:
            from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(f)
            if pb.get_width() > largeur:
                pb = pb.scale_simple(largeur, int(pb.get_height() * largeur / pb.get_width()),
                                     GdkPixbuf.InterpType.BILINEAR)
            buf.insert_pixbuf(fin(), pb)
            return True
        except Exception:                                    # noqa: BLE001 - no image: its caption
            return False

    def ecrire(t, *tags):
        if tags:
            buf.insert_with_tags_by_name(fin(), t, *tags)
        else:
            buf.insert(fin(), t)

    def en_ligne(t, *tags):
        for txt, tg, lien, img in md_segments(t):
            if img is not None and image(img, txt):
                continue
            if img is not None:
                txt, tg = "[%s]" % (txt or os.path.basename(img)), tg + ("ital",)
                lien = lien or img
            if not txt:
                continue
            noms = list(dict.fromkeys(tags + tg))
            if lien:
                tag = buf.create_tag(None)
                buf.md_liens[tag] = lien
                buf.insert_with_tags(fin(), txt, tag, *[buf.get_tag_table().lookup(n) for n in noms])
            else:
                ecrire(txt, *noms)

    def cellules(l):
        l = l.strip()
        l = l[1:] if l.startswith("|") else l
        l = l[:-1] if l.endswith("|") and not l.endswith("\\|") else l
        return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", l)]

    def tableau(lignes):
        def sep(l):
            return re.match(r"^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$", l) is not None

        rangs = [cellules(l) for l in lignes if not sep(l)]
        entete = len(lignes) > 1 and sep(lignes[1])
        if entete and rangs and not any(rangs[0]):          # « | | | » : a table without header
            rangs, entete = rangs[1:], False
        if not rangs:
            return
        ncol = max(len(r) for r in rangs)
        if vue is None:
            brut = [[re.sub(r"<[^>]+>", "", "".join(x for x, *_ in md_segments(c))) for c in r] for r in rangs]
            larg = [max(len(r[i]) if i < len(r) else 0 for r in brut) for i in range(ncol)]
            for k, r in enumerate(brut):
                ecrire("  ".join((r[i] if i < len(r) else "").ljust(larg[i]) for i in range(ncol)).rstrip() + "\n",
                       *(("table", "gras") if entete and k == 0 else ("table",)))
            return
        grille = Gtk.Grid(column_spacing=0, row_spacing=0)
        grille.get_style_context().add_class("md-table")
        # a wrapped label takes its MINIMUM width inside a text view: each
        # column is given its width in characters - its longest cell, within
        # a budget shared in proportion when the table is too wide
        def large(c):          # code is set in a wider face than the text the widths are counted in
            return int(sum(len(x) * (1.3 if "code" in tg else 1.0) for x, tg, *_ in md_segments(c)))

        longs = [max([large(r[i]) if i < len(r) else 0 for r in rangs] + [3]) + 2 for i in range(ncol)]
        budget = 118 - 2 * ncol
        if sum(longs) > budget:
            longs = [max(8, min(n, int(budget * n / sum(longs)))) for n in longs]
        for k, r in enumerate(rangs):
            for i in range(ncol):
                c = r[i] if i < len(r) else ""
                lab = Gtk.Label(xalign=0, yalign=0, wrap=True, selectable=True)
                lab.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
                lab.set_width_chars(longs[i])
                lab.set_max_width_chars(longs[i])
                lab.set_markup(("<b>%s</b>" % md_markup(c)) if entete and k == 0 else md_markup(c))
                if ouvrir:
                    lab.connect("activate-link", lambda _l, uri: (ouvrir(uri), True)[1])
                cadre = Gtk.EventBox()
                cadre.get_style_context().add_class("md-tete" if entete and k == 0 else
                                                    ("md-pair" if k % 2 else "md-impair"))
                lab.set_margin_start(8), lab.set_margin_end(8), lab.set_margin_top(5), lab.set_margin_bottom(5)
                cadre.add(lab)
                grille.attach(cadre, i, k, 1, 1)
        ancre = buf.create_child_anchor(fin())
        vue.add_child_at_anchor(grille, ancre)
        grille.show_all()
        ecrire("\n")

    lignes = texte.replace("\r\n", "\n").split("\n")
    para, n, i = [], len(lignes), 0

    def vider():
        if para:
            en_ligne(" ".join(x.strip() for x in para), "para")
            ecrire("\n", "para")
            del para[:]

    while i < n:
        l = lignes[i]
        nu = l.strip()
        if nu.startswith("```") or nu.startswith("~~~"):
            vider()
            cloture = nu[:3]
            i += 1
            while i < n and not lignes[i].strip().startswith(cloture):
                ecrire(lignes[i] + "\n", "bloc")
                i += 1
            i += 1
            ecrire("\n")
            continue
        if nu.startswith("<!--"):
            vider()
            while i < n and "-->" not in lignes[i]:
                i += 1
            i += 1
            continue
        if not nu:
            vider()
            i += 1
            continue
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", l)
        if m:
            vider()
            h = {1: "h1", 2: "h2", 3: "h3"}.get(len(m.group(1)), "h4")
            en_ligne(m.group(2), h)
            ecrire("\n", h)
            i += 1
            continue
        if re.match(r"^\s*([-*_])(\s*\1){2,}\s*$", l):
            vider()
            ecrire("─" * 60 + "\n", "regle")
            i += 1
            continue
        if nu.startswith("|") or (i + 1 < n and "|" in l and re.match(r"^\s*\|?\s*:?-{2,}[\s:|-]*$", lignes[i + 1])):
            vider()
            bloc = []
            while i < n and lignes[i].strip() and "|" in lignes[i]:
                bloc.append(lignes[i])
                i += 1
            tableau(bloc)
            continue
        if nu.startswith(">"):
            vider()
            cit = []
            while i < n and lignes[i].strip().startswith(">"):
                cit.append(re.sub(r"^\s*>\s?", "", lignes[i]))
                i += 1
            en_ligne(" ".join(x.strip() for x in cit), "cite")
            ecrire("\n", "cite")
            ecrire("\n")
            continue
        m = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)", l)
        if m:
            vider()
            niveau = min(3, len(m.group(1).replace("\t", "    ")) // 2)
            corps = m.group(3)
            # continuation lines of the item
            while i + 1 < n and lignes[i + 1].strip() and re.match(r"^\s+\S", lignes[i + 1]) \
                    and not re.match(r"^\s*([-*+]|\d+[.)])\s+", lignes[i + 1]) \
                    and not lignes[i + 1].strip().startswith(("```", "|", ">")):
                i += 1
                corps += " " + lignes[i].strip()
            marque = "•◦▪▫"[niveau] if m.group(2) in "-*+" else m.group(2)
            c = re.match(r"^\[([ xX])\]\s+(.*)", corps)
            if c:
                marque, corps = ("☑" if c.group(1) != " " else "☐"), c.group(2)
            en_ligne("%s %s" % (marque, corps), "puce%d" % niveau)
            ecrire("\n", "puce%d" % niveau)
            i += 1
            continue
        para.append(l)
        i += 1
    vider()


def _cmd(argv, timeout=10):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).rstrip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return "(%s : %s)" % (argv[0], e)


def _lire(f):
    try:
        with open(f) as h:
            return h.read().rstrip()
    except OSError:
        return None


def infos_texte():
    s = []

    def titre(t):
        s.append("\n══ %s %s" % (t, "═" * max(0, 70 - len(t))))
    titre("MACHINE")
    s.append(_cmd(["bash", "-c", "lscpu | grep -E '^(Model name|CPU\\(s\\)|Thread|Core|Socket|CPU max MHz|CPU min MHz)'"]))
    gov = _lire("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
    s.append("governor cpu0 : %s   profil : %s" % (gov, _cmd(["powerprofilesctl", "get"], 3)))
    s.append("frequences actuelles (MHz) : " + " ".join(
        str(int(int(_lire("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq" % c) or 0) / 1000))
        for c in range(os.cpu_count() or 1)))
    s.append(_cmd(["bash", "-c", "uptime; free -h | head -2; df -h /opt /tmp /dev/shm 2>/dev/null"]))
    t = _cmd(["bash", "-c", "sensors 2>/dev/null | grep -E 'Tctl|edge' | head -3"], 5)
    if t:
        s.append(t)

    titre("ISOLATION DES CPUS (c54x_exe/isoler.sh)")
    env = _lire("/run/c54x-isol.env")
    s.append(env if env else "inactive (./isoler.sh on pour reserver les cpus du banc)")
    s.append("isoles au boot : %s" % (_lire("/sys/devices/system/cpu/isolated") or "aucun"))

    titre("BUDGET DU DSP (INSNS)")
    s.append(_cmd(["bash", "-c", "eval \"$(sed -n '/^insns_auto() {/,/^}/p' '%s')\"; . /run/c54x-isol.env 2>/dev/null; "
                   "RT_CPUS_DSP=\"${ISOL_CPUS_DSP:-}\" insns_auto" % RUN_SH.replace("'", "")]) +
             " instructions C54x par trame  (frequence max du cpu du DSP / nproc x 4,615 ms ; plafond, le DSP s'arrete a IDLE)")
    s.append("nproc --all : %s" % _cmd(["nproc", "--all"]))

    titre("CHAINE (RUNDIR %s)" % RUNDIR)
    for n in ("dsp", "qemu", "osmocon", "mobile", "transceiver", "pont", "air", "rvinterf"):
        p = pid_de(n)
        if p or os.path.exists(os.path.join(RUNDIR, n + ".pid")):
            aff = _cmd(["taskset", "-cp", str(p)]).split(":")[-1].strip() if p else "-"
            s.append("%-12s %s  cpus %s" % (n, ("pid %d" % p) if p else "arrete", aff))
    snr = snr_du_banc()
    s.append("SNR du banc : %s" % ("%g dB" % snr if snr is not None else "-"))

    titre("SERVICES")
    unites = ["osmo-banc", "osmo-lte", "osmo-multi", "osmo-fft-snap", "osmo-egprs-web", "c54x-garde"] + \
             [p for _n, p, _v in CORE]
    etats = _cmd(["systemctl", "is-active"] + unites).splitlines()
    for u, e in zip(unites, etats + [""] * len(unites)):
        s.append("%-22s %s" % (u, e))

    titre("COEUR : PORTS VTY")
    ss = _cmd(["ss", "-ltn"])
    for nom, proc, port in CORE:
        if port:
            s.append("%-5s %-20s %5d  %s" % (nom, proc, port, "ecoute" if ":%d " % port in ss else "-"))
    s.append("mobile VTY %d  %s" % (port_mobile(), "ecoute" if ":%d " % port_mobile() in ss else "-"))

    titre("PLAN RADIO (/etc/osmocom/radio-plan.env)")
    s.append(_lire("/etc/osmocom/radio-plan.env") or "-")

    titre("CONFIGURATION DE DEMARRAGE")
    sc = _start_config()
    s.append("%s : %s" % (sc, "present" if os.path.exists(sc) else "absent"))
    if os.path.exists(sc):
        s.append("commande : " + _cmd(["bash", os.path.join(REPO, "tools", "start-config.sh"), "--print", sc]))

    titre("VERSIONS")
    for d in (REPO, C54X, os.path.join(GSM_ROOT, "qosmo"), os.path.join(GSM_ROOT, "osmocom-bb")):
        if os.path.isdir(os.path.join(d, ".git")):
            s.append("%-34s %s" % (d, _cmd(["git", "-C", d, "log", "-1", "--format=%h %ad %s", "--date=short"])))
    s.append("noyau : " + _cmd(["uname", "-r"]))

    titre("COMMANDES UTILES")
    s.append("constellation | iq-visual          cette fenetre\n"
             "c54x_exe/isoler.sh on|off|status   les cpus reserves\n"
             "start.sh --configure               le menu de demarrage (onglet Kconfig ici)\n"
             "make menuconfig | make iso         build (onglet Kconfig, « Build et ISO »)\n"
             "banc-trx | banc-mobile | banc-rssi les chaines Calypso ; c123 la fenetre du telephone")
    return "\n".join(s).lstrip() + "\n"



# ── the logs (Journaux tab, and the log of the Core tab) ─────────────────────
NITB_LOGS = os.environ.get("OSMO_NITB_LOGS", "/tmp/osmo-nitb/logs")
# daemons the bench starts OUTSIDE systemd: their log is in NITB_LOGS
NITB_DE = {"osmo-bts-trx": "bts.log", "proto-smsc-daemon": "smsc-op1.log", "asterisk": "asterisk.log"}
MAILBOX = os.environ.get("CALYPSO_MAILBOX_FILE", os.path.join(os.environ.get("LOG_DIR", "/tmp/calypso/logs"), "mailbox.log"))


def sources_journaux():
    """group, name, kind (file | journal), target, hint when absent."""
    S = [("Fenetre", "commandes lancees (demarrage, arret, chaine, mobile)", "fenetre", "", "")]
    for n, d in (("dsp", "c54x_exe : le DSP C54x"), ("qemu", "qemu-system-arm : l'ARM (qosmo)"),
                 ("osmocon", "osmocon : romload, relais L1CTL"), ("mobile", "mobile : osmocom-bb layer 2/3"),
                 ("pont", "pont : rafales BTS <-> DSP"), ("vsp", "vsp : la voix (VSP)"), ("gdb", "gdb : console de l'ARM"),
                 ("qemu-debug", "qemu -d (QEMU_DEBUG_FLAGS)"), ("transceiver", "transceiver (OSMO_TRX=1)"),
                 ("air", "air.py : l'air entre deux Calypso"), ("rvinterf", "rvinterf (FreeCalypso)")):
        S.append(("Chaine Calypso", d, "file", os.path.join(RUNDIR, n + ".log"), "etape pas lancee"))
    S.append(("Mailbox ARM <-> DSP", "mailbox, cote DSP (c54x_exe)", "file", MAILBOX,
              "CALYPSO_MAILBOX=1 au demarrage pour l'ecrire"))
    S.append(("Mailbox ARM <-> DSP", "mailbox, cote ARM (QEMU)", "file", MAILBOX[:-4] + "-arm.log",
              "CALYPSO_MAILBOX=1 au demarrage pour l'ecrire"))
    for nom, proc, _port in CORE:
        S.append(("Osmocom", "%s (%s)" % (nom, proc), "osmo", proc, ""))
    noms = {"bts", "sidecar-bts", "sidecar-faketrx", "sidecar-trxcon", "sidecar-mobile", "asterisk", "smsc-op1", "gapk-auto"}
    if os.path.isdir(NITB_LOGS):
        noms |= {f[:-4] for f in os.listdir(NITB_LOGS) if f.endswith(".log")}
    for n in sorted(noms):
        S.append(("Banc (%s)" % NITB_LOGS, n, "file", os.path.join(NITB_LOGS, n + ".log"), "pas ecrit par ce mode"))
    for u, d in (("osmo-banc", "le service du banc (start.sh)"), ("osmo-lte", "la 4G"), ("c54x-garde", "le garde-fou temps reel")):
        S.append(("Services", "%s : %s" % (u, d), "journal", u, ""))
    return S


def lire_journal(kind, cible, n=1000):
    """(text, where it came from). osmo: the file when readable and not empty, else the journal."""
    if kind == "osmo":
        for f in (os.path.join(CORE_LOGS, cible + ".log"), os.path.join(NITB_LOGS, NITB_DE.get(cible, cible + ".log"))):
            if os.access(f, os.R_OK) and os.path.getsize(f) > 0:
                return queue(f, n, ansi=True) or "", f
        kind = "journal"
    if kind == "journal":
        try:
            out = subprocess.run(["journalctl", "-u", cible, "-n", str(n), "--no-pager", "-o", "short-precise"],
                                 capture_output=True, text=True, timeout=10)
            return re.sub(r"\x1b\[[0-9;]*m", "", out.stdout + out.stderr), "journalctl -u " + cible
        except (OSError, subprocess.TimeoutExpired) as e:
            return "journalctl : %s\n" % e, "journalctl -u " + cible
    t = queue(cible, n, ansi=True)
    return t, cible


# ── the air: UDP copies of the bridge ────────────────────────────────────────
# THE SIP TRUNK (tab « Trunk SIP »): what is written to TRUNK_DIR/pjsip_trunk.conf from what is
# typed in the tab. No operator, no login and no password in the repository.
TRUNK_DIR = os.environ.get("OSMO_ASTERISK_DIR", "/etc/asterisk")
TRUNK_MODELE = """; pjsip_trunk.conf - written by osmo-gtk (tab « Trunk SIP »), do not edit by hand.
; The SIP trunk of the bench: PJSIP/<number>@trunk_sip goes out, its calls come in [trunk_in].

[trunk_sip_auth]
type=auth
auth_type=userpass
username=%(user)s
password=%(mdp)s

[trunk_sip]
type=aor
contact=sip:%(serveur)s
qualify_frequency=60
qualify_timeout=5.0

[trunk_sip]
type=endpoint
transport=transport-udp
context=trunk_in
disallow=all
allow=gsm
allow=ulaw
allow=alaw
outbound_auth=trunk_sip_auth
aors=trunk_sip
from_user=%(numero)s
from_domain=%(hote)s
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
media_encryption=no
dtmf_mode=rfc4733

[trunk_sip-identify]
type=identify
endpoint=trunk_sip
match=%(hote)s
"""
TRUNK_REG = """
[trunk_sip_reg]
type=registration
transport=transport-udp
outbound_auth=trunk_sip_auth
server_uri=sip:%(serveur)s
client_uri=sip:%(user)s@%(serveur)s
contact_user=%(user)s
retry_interval=60
forbidden_retry_interval=600
expiration=300
line=yes
endpoint=trunk_sip
"""

# ILLUSTRATIONS: the bench's own, recent artwork (configs/osmo-balise-*.png, the
# desktop of the current image) as a band on top of some tabs.
BANNIERES = {"Telephones": ("osmo-balise-soir.png", "Telephones", "Network Monitor : invitation, QR code, comptes, ligne Bluetooth"),
             "Installation": ("osmo-balise-jour.png", "Installation", "les etapes de install.sh et leur etat sur cette machine"),
             "Infos": ("osmo-balise-soir.png", "Le banc", "machine, chaine, services, ports, plan radio")}


def banniere(fichier, titre, sous_titre, hauteur=96):
    """A band: the image covers it (cropped around its middle), darkened on the left
    under the title. None when the image is not there."""
    chemin = os.path.join(REPO, "configs", fichier)
    try:
        from gi.repository import Gdk, GdkPixbuf
        import cairo
        pb = GdkPixbuf.Pixbuf.new_from_file(chemin)
    except Exception:                                        # noqa: BLE001 - no image: no band
        return None
    z = Gtk.DrawingArea()
    z.set_size_request(-1, hauteur)
    cache = {}

    def dessin(w, cr):
        W, H = w.get_allocated_width(), w.get_allocated_height()
        if cache.get("w") != W:
            e = W / pb.get_width()
            cache["pb"] = pb.scale_simple(W, max(H, int(pb.get_height() * e)), GdkPixbuf.InterpType.BILINEAR)
            cache["w"] = W
        img = cache["pb"]
        Gdk.cairo_set_source_pixbuf(cr, img, 0, -(img.get_height() - H) * 0.42)
        cr.paint()
        g = cairo.LinearGradient(0, 0, W * 0.75, 0)
        g.add_color_stop_rgba(0, 0.02, 0.05, 0.10, 0.82)
        g.add_color_stop_rgba(1, 0.02, 0.05, 0.10, 0.0)
        cr.set_source(g)
        cr.paint()
        cr.set_source_rgb(1, 1, 1)
        cr.select_font_face("Ubuntu", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(26)
        cr.move_to(22, H / 2 + 2)
        cr.show_text(titre)
        cr.select_font_face("Ubuntu", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(13)
        cr.set_source_rgba(1, 1, 1, 0.85)
        cr.move_to(23, H / 2 + 24)
        cr.show_text(sous_titre)
        return False
    z.connect("draw", dessin)
    return z


# VTY shortcuts PER DAEMON: a command only exists on the daemon that defines
# it ("show bts" on the BSC and the BTS, "show cs7 ..." on what speaks SS7,
# "show subscribers all" on the HLR...). Every one below is in that daemon's
# own "list". "{ms}" is replaced by the name of the mobile's first MS.
RACCOURCIS_CORE = {
    "HLR": ["show subscribers all", "show subscribers last-seen", "show gsup-connections", "show runtime"],
    "MSC": ["show subscriber cache", "show connection", "show bsc", "show cs7 instance 0 asp",
            "show sms-queue", "show runtime"],
    "BSC": ["show bts", "show bts brief", "show trx", "show lchan summary", "show cs7 instance 0 asp",
            "show mscs", "show runtime"],
    "STP": ["show cs7 instance 0 asp", "show cs7 instance 0 as all", "show cs7 instance 0 route",
            "show cs7 instance 0 users", "show runtime"],
    "MGW": ["show mgcp", "show mgcp active", "show stats", "show runtime"],
    "SGSN": ["show mm-context all", "show pdp-context all", "show ns entities", "show bssgp", "show runtime"],
    "GGSN": ["show ggsn", "show stats", "show runtime"],
    "PCU": ["show bts statistics", "show bts pdch", "show ms all", "show tbf all", "show runtime"],
    "BTS": ["show bts", "show trx", "show lchan summary", "show transceiver", "show phy", "show runtime"],
    "SIP": ["show calls", "show calls summary", "show mncc-connection", "show runtime"],
}
RACCOURCIS_DEFAUT = ["show version", "show runtime", "show stats"]
CADENCE_RAPIDE_MS = 30          # "30 img/s" (the timer's period; the drawing takes the rest of the 33 ms)
CADENCE_LENTE_MS = 100          # "lent": 10 images/s, the former rate
OEIL_PAR_IMAGE = 2              # eye diagram: bursts added to the layer per image, at most
OEIL_FONDU = 0.08               # ...and how much each one fades the older traces
IQ_HZ = 10                      # the I/Q plot (one burst) is renewed at most 10 times a second
RAFALES_PAR_S = 120             # bursts demodulated per second, at most, whatever the rate
RACCOURCIS_MOBILE = ["show ms", "show subscriber {ms}", "show cell {ms}", "show neighbour-cells {ms}",
                     "show support {ms}", "show ba {ms}"]


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
        super().__init__(title="Constellation - le banc, son air (I/Q), son coeur, son mobile")
        self.set_icon_name("osmo-constellation")
        ic = "/usr/share/osmo-operator/icons/osmo-constellation.svg"
        if os.path.exists(ic):
            try:
                self.set_icon_from_file(ic)
            except GLib.Error:
                pass
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
        self.journal_txt = ""           # output of the commands the window runs (Journaux tab, "Fenetre")

        css = Gtk.CssProvider()
        css.load_from_data(b"textview.osmo-journal, textview.osmo-journal text { background-color: #1e1e2e; color: #cdd6f4; }")
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        racine = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        racine.set_border_width(8)
        self.add(racine)

        # the chain: buttons + one state per step
        haut = Gtk.Box(spacing=8)
        racine.pack_start(haut, False, False, 0)
        self.b_go = Gtk.Button(label="Demarrage complet")
        self.b_go.set_tooltip_text("launch.sh --service : tout le banc (coeur, chaine, mobile, pont)")
        self.b_go.connect("clicked", lambda *_: self.lancer([], brut=["bash", os.path.join(REPO, "launch.sh"), "--service"]))
        self.b_stop = Gtk.Button(label="Arreter")
        self.b_stop.set_tooltip_text("systemctl stop osmo-banc, puis run.sh --stop (la chaine seule)")
        self.b_stop.connect("clicked", lambda *_: self.lancer([], brut=["bash", "-c",
                            "systemctl stop osmo-banc; bash '%s' --stop" % RUN_SH.replace("'", "")]))
        self.b_chaine = Gtk.Button(label="Chaine seule")
        self.b_chaine.set_tooltip_text("run.sh etapes 1, b, 2, 3, 5 : DSP, ARM, osmocon, pont, sans coeur ni mobile")
        self.b_chaine.connect("clicked", lambda *_: self.lancer([]))
        haut.pack_start(self.b_go, False, False, 0)
        haut.pack_start(self.b_stop, False, False, 0)
        haut.pack_start(self.b_chaine, False, False, 0)
        self.etats = {}
        for n in ETAPES:
            l = Gtk.Label()
            l.set_use_markup(True)
            haut.pack_start(l, False, False, 6)
            self.etats[n] = l
        if demo:
            for b in (self.b_go, self.b_stop, self.b_chaine):
                b.set_sensitive(False)
        self.racine = Racine()
        self.b_root = Gtk.Button(label="Mot de passe root")
        self.b_root.set_tooltip_text("une seule fois pour toute la fenetre (pkexec) : chaine, installation, tests, notebooks")
        self.b_root.connect("clicked", lambda *_: self.elever())
        self.b_root.set_no_show_all(True)
        self.l_root = Gtk.Label()
        haut.pack_start(self.l_root, False, False, 6)
        haut.pack_start(self.b_root, False, False, 0)
        haut.pack_end(self._choix_sens(), False, False, 0)
        self.b_gel = Gtk.ToggleButton(label="Figer")
        self.b_gel.connect("toggled", lambda b: setattr(self, "gel", b.get_active()))
        haut.pack_end(self.b_gel, False, False, 0)

        # the tabs: Air (the plots), Core, L23
        self.onglets = Gtk.Notebook()
        racine.pack_start(self.onglets, True, True, 0)
        air = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        air.set_border_width(6)
        self.onglets.append_page(air, Gtk.Label(label="Air"))
        self.onglets.append_page(self._onglet_core(), Gtk.Label(label="Core"))
        self.onglets.append_page(self._onglet_l23(), Gtk.Label(label="L23"))
        self.jx_page = self._onglet_journaux()
        self.onglets.append_page(self.jx_page, Gtk.Label(label="Journaux"))
        for f, t in ((self._onglet_kconfig, "Kconfig"), (self._onglet_tests, "Tests"),
                     (self._onglet_telephones, "Telephones"), (self._onglet_trunk, "Trunk SIP"),
                     (self._onglet_notebooks, "Notebooks"), (self._onglet_wiki, "Wiki"), (self._onglet_infos, "Infos"),
                     (self._onglet_install, "Installation")):
            page, bande = f(), banniere(*BANNIERES[t]) if t in BANNIERES else None
            if bande is not None:                   # an illustration on top of the tab
                boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
                boite.pack_start(bande, False, False, 0)
                boite.pack_start(page, True, True, 0)
                page = boite
            self.onglets.append_page(page, Gtk.Label(label=t))

        # noise: the bench's, or the slider's
        bruit = Gtk.Box(spacing=8)
        air.pack_start(bruit, False, False, 0)
        self.c_bruit = Gtk.CheckButton(label="bruit blanc, SNR (dB)")
        self.c_bruit.set_active(True)
        self.s_snr = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 40, 1)
        self.s_snr.set_value(20)
        self.s_snr.set_size_request(260, -1)
        self.l_bruit = Gtk.Label(xalign=0)
        bruit.pack_start(self.c_bruit, False, False, 0)
        bruit.pack_start(self.s_snr, False, False, 0)
        bruit.pack_start(self.l_bruit, False, False, 0)
        # slow by default (it reads better); OSMO_GTK_RAPIDE=1 starts at 30 images/s
        self.periode = CADENCE_RAPIDE_MS if os.environ.get("OSMO_GTK_RAPIDE", "0") == "1" else CADENCE_LENTE_MS
        self.b_cadence = Gtk.ToggleButton(tooltip_text="cadence de l air : 30 images par seconde, ou lent (10)")
        self.b_cadence.set_active(self.periode == CADENCE_RAPIDE_MS)
        self._cadence(self.b_cadence)
        self.b_cadence.connect("toggled", self._cadence)
        bruit.pack_start(self.b_cadence, False, False, 0)
        self.l_info = Gtk.Label(xalign=0)
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_family_new("Ubuntu Mono"))
        self.l_info.set_attributes(attrs)
        bruit.pack_end(self.l_info, False, False, 0)

        # the plots
        g = Gtk.Grid(column_spacing=6, row_spacing=6, column_homogeneous=True, row_homogeneous=True)
        air.pack_start(g, True, True, 0)
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

        # the output of the commands the window runs (full start, stop, chain, mobile...): no band at
        # the bottom any more, it goes to the Journaux tab ("Fenetre") and its last line to the top bar
        self.l_derniere = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END, max_width_chars=60)
        self.l_derniere.set_tooltip_text("sortie complete : onglet Journaux, « Fenetre : commandes lancees »")
        haut.pack_start(self.l_derniere, True, True, 6)

        threading.Thread(target=self.air.demo if demo else self.air.ecouter, daemon=True).start()
        # THE AIR, TWO SPEEDS (button of the Air tab): 30 images per second, or
        # slow (10). The period is that of the timer, minus nothing: the real
        # rate is measured and shown next to the measures.
        self._cad_t, self._cad_n, self.cadence_reelle = time.monotonic(), 0, 0.0
        GLib.timeout_add(self.periode, self._tic_cadence)
        GLib.timeout_add(1000, self.tic_etats)
        GLib.timeout_add(2000, self.tic_journaux)
        # Kconfig (gen-start.sh: 5 s), Installation and Infos load at their FIRST visit, in the background
        self._vus = set()
        self.onglets.connect("switch-page", self._onglet_change)
        self.tic_etats()
        self._root_etat()
        if not demo and os.geteuid() != 0 and os.environ.get("OSMO_GTK_ROOT", "1") == "1":
            GLib.idle_add(self.elever)          # the password, once, at start (OSMO_GTK_ROOT=0: at the first root action)
        self.show_all()

    # ── Core and L23 tabs ──────────────────────────────────────────────────
    @staticmethod
    def _texte(h=-1, sombre=False):
        t = Gtk.TextView(editable=False, monospace=True)
        t.set_wrap_mode(Gtk.WrapMode.NONE)
        if sombre:
            t.get_style_context().add_class("osmo-journal")
        sw = Gtk.ScrolledWindow()
        sw.set_vexpand(True)
        if h > 0:
            sw.set_size_request(-1, h)
        sw.add(t)
        return t, sw

    def _tag(self, buf, coul, gras):
        nom = "c%s%s" % (coul or "", "g" if gras else "")
        tag = buf.get_tag_table().lookup(nom)
        if tag is None:
            kw = {"foreground": coul} if coul else {}
            if gras:
                kw["weight"] = Pango.Weight.BOLD
            tag = buf.create_tag(nom, **kw)
        return tag

    def _inserer(self, t, segs):
        buf = t.get_buffer()
        for texte, coul, gras in segs:
            if coul or gras:
                buf.insert_with_tags(buf.get_end_iter(), texte, self._tag(buf, coul, gras))
            else:
                buf.insert(buf.get_end_iter(), texte)

    def _remplir_couleur(self, t, txt, segs=None, bas=True):
        """Like _remplir, in colour (segs: colorer(txt), computed in the worker thread)."""
        if getattr(t, "_osmo_txt", None) == txt:
            return False
        t._osmo_txt = txt
        t.get_buffer().set_text("")
        self._inserer(t, segs if segs is not None else colorer(txt))
        if bas:
            _vers_la_fin_tv(t)
        return False

    def _ajouter_couleur(self, t, txt):
        """Appends coloured text (streamed output: tests)."""
        t._osmo_txt = None
        self._inserer(t, colorer(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt) if "\x1b[" in txt and
                                     not re.search(r"\x1b\[[0-9;]*m", txt) else txt))
        _vers_la_fin_tv(t)

    @staticmethod
    def _remplir(t, txt, bas=True):
        t._osmo_txt = None                  # the coloured fill must not believe it is still shown
        buf = t.get_buffer()
        if buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False) == txt:
            return False
        buf.set_text(txt)
        if bas:
            _vers_la_fin_tv(t)
        return False

    def _console(self, port_de, raccourcis):
        """A VTY console: shortcut buttons, an entry, the output. port_de() gives the port.
        raccourcis: a list, or a function giving the list for what is selected now (the box's
        raccourcis_maj() rebuilds the buttons). "{ms}" in a command is the mobile's first MS."""
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        ligne = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=12,
                            column_spacing=4, row_spacing=2, homogeneous=False)
        b.pack_start(ligne, False, False, 0)
        e = Gtk.Entry(placeholder_text="commande VTY (Entree) - « list » donne celles de ce demon")
        sortie, sw = self._texte()

        def executer(port, cmd):
            if "{ms}" in cmd:
                m = re.search(r"MS '([^']+)'", vty(port, ["show ms"]))
                cmd = cmd.replace("{ms}", m.group(1) if m else "1")
            return cmd, vty(port, [cmd])

        def envoyer(cmd):
            cmd = cmd.strip()
            if not cmd:
                return
            port = port_de()
            if not port:
                self._remplir(sortie, "pas de VTY pour ce demon\n")
                return
            self._remplir(sortie, "VTY %d > %s ...\n" % (port, cmd.replace(" {ms}", "")))

            def faire():
                c, r = executer(port, cmd)
                GLib.idle_add(self._remplir, sortie, "VTY %d > %s\n%s" % (port, c, r))
            threading.Thread(target=faire, daemon=True).start()

        def maj():
            for w in ligne.get_children():
                ligne.remove(w)
            for r in (raccourcis() if callable(raccourcis) else raccourcis):
                bt = Gtk.Button(label=r.replace(" {ms}", ""))
                bt.connect("clicked", lambda _b, c=r: envoyer(c))
                ligne.add(bt)
            ligne.show_all()
        maj()
        b.raccourcis_maj = maj
        e.connect("activate", lambda w: (envoyer(w.get_text()), w.set_text("")))
        b.pack_start(e, False, False, 0)
        b.pack_start(sw, True, True, 0)
        return b

    def _onglet_core(self):
        p = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        p.set_border_width(6)
        self.core_store = Gtk.ListStore(str, str, str, str, int)   # state markup, name, process, port, port
        for nom, proc, port in CORE:
            self.core_store.append(["", nom, proc, str(port) if port else "-", port])
        vue = Gtk.TreeView(model=self.core_store)
        for i, titre in ((0, ""), (1, "demon"), (2, "processus"), (3, "VTY")):
            r = Gtk.CellRendererText()
            vue.append_column(Gtk.TreeViewColumn(titre, r, **({"markup": 0} if i == 0 else {"text": i})))
        vue.get_selection().select_path(Gtk.TreePath.new_first())
        vue.get_selection().connect("changed", lambda *_: (self.core_console.raccourcis_maj(), self.tic_journaux()))
        self.core_vue = vue
        g = Gtk.ScrolledWindow()
        g.set_size_request(300, -1)
        g.add(vue)
        p.pack1(g, False, False)
        droite = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        self.core_console = self._console(
            self._core_port, lambda: RACCOURCIS_CORE.get(self._core_choisi()[0], RACCOURCIS_DEFAUT))
        droite.pack1(self.core_console, True, False)
        bas = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.core_titre = Gtk.Label(xalign=0)
        self.core_log, sw = self._texte(160, sombre=True)
        bas.pack_start(self.core_titre, False, False, 0)
        bas.pack_start(sw, True, True, 0)
        droite.pack2(bas, True, False)
        p.pack2(droite, True, False)
        return p

    def _core_choisi(self):
        m, it = self.core_vue.get_selection().get_selected()
        return (m[it][1], m[it][2], m[it][4]) if it else (None, None, 0)

    def _core_port(self):
        return self._core_choisi()[2]

    def _onglet_l23(self):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.set_border_width(6)
        haut = Gtk.Box(spacing=8)
        b.pack_start(haut, False, False, 0)
        go = Gtk.Button(label="Demarrer le mobile (etape 4)")
        go.connect("clicked", lambda *_: self.lancer(["--step", "4"]))
        stop = Gtk.Button(label="Arreter le mobile")
        r = os.path.join(RUNDIR, "mobile.pid").replace("'", "")
        stop.connect("clicked", lambda *_: self.lancer([], brut=["bash", "-c",
                     "p=$(cat '%s' 2>/dev/null) && kill $p && rm -f '%s' && echo mobile arrete" % (r, r)]))
        self.l23_etat = Gtk.Label()
        self.l23_etat.set_use_markup(True)
        haut.pack_start(go, False, False, 0)
        haut.pack_start(stop, False, False, 0)
        haut.pack_start(self.l23_etat, False, False, 6)
        p = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        b.pack_start(p, True, True, 0)
        p.pack1(self._console(port_mobile, RACCOURCIS_MOBILE), True, False)
        self.l23_log, sw = self._texte(200, sombre=True)
        p.pack2(sw, True, False)
        return b

    def _onglet_install(self):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.set_border_width(6)
        haut = Gtk.Box(spacing=6)
        b.pack_start(haut, False, False, 0)
        boutons = (("Verifier", "install.sh --check (sans root)", lambda: self.install_verifier()),
                   ("Installer l'etape", "install.sh --only <etape>", lambda: self._install(["--only", self._etape()])),
                   ("Reinstaller l'etape", "install.sh --only <etape> --reinstall",
                    lambda: self._install(["--only", self._etape(), "--reinstall"])),
                   ("Simulation", "install.sh --dry-run : parcourt tout, sans effet", lambda: self._install(["--dry-run"], root=False)),
                   ("Tout installer", "install.sh : toutes les etapes, dans l'ordre", lambda: self._install([])))
        for lab, tip, f in boutons:
            bt = Gtk.Button(label=lab)
            bt.set_tooltip_text(tip)
            bt.connect("clicked", lambda _b, f=f: f())
            haut.pack_start(bt, False, False, 0)
        self.install_racine = Gtk.Label(xalign=0)
        haut.pack_end(self.install_racine, False, False, 0)
        p = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        b.pack_start(p, True, True, 0)
        # state markup, slug, label, mandatory, after, state text
        self.install_store = Gtk.ListStore(str, str, str, str, str, str)
        vue = Gtk.TreeView(model=self.install_store)
        for i, titre in ((0, ""), (1, "etape"), (2, "description"), (3, ""), (4, "apres"), (5, "etat")):
            vue.append_column(Gtk.TreeViewColumn(titre, Gtk.CellRendererText(), **({"markup": 0} if i == 0 else {"text": i})))
        vue.connect("row-activated", lambda *_: self._install(["--only", self._etape()]))
        self.install_vue = vue
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(-1, 260)
        sw.add(vue)
        p.pack1(sw, False, False)
        self.install_log, sw2 = self._texte(200, sombre=True)
        p.pack2(sw2, True, False)
        return b

    def _etape(self):
        m, it = self.install_vue.get_selection().get_selected()
        return m[it][1] if it else ""

    @staticmethod
    def _sans_couleur(txt):
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt)

    def install_lister(self):
        try:
            out = subprocess.run(["bash", INSTALL_SH, "--list"], capture_output=True, text=True, timeout=20,
                                 env=dict(os.environ, NO_COLOR="1"), cwd=REPO).stdout
        except (OSError, subprocess.TimeoutExpired) as e:
            self._ecrire_install("install.sh --list : %s\n" % e)
            return
        self.install_store.clear()
        for l in self._sans_couleur(out).splitlines():
            m = re.match(r"^\s{2}(\S+)\s+(.+?)\s{2,}(obligatoire|optionnelle)(?:\s+apres:\s*(.*))?$", l)
            if m:
                self.install_store.append(["", m.group(1), m.group(2), m.group(3), m.group(4) or "", ""])
        r = re.search(r"GSM_ROOT\s*=\s*(\S+)", out)
        self.install_racine.set_text("GSM_ROOT = %s" % (r.group(1) if r else os.environ.get("GSM_ROOT", "/opt/GSM")))
        if len(self.install_store):
            self.install_vue.get_selection().select_path(Gtk.TreePath.new_first())
        self.install_verifier()

    def install_verifier(self):
        def faire():
            try:
                out = subprocess.run(["bash", INSTALL_SH, "--check"], capture_output=True, text=True, timeout=120,
                                     env=dict(os.environ, NO_COLOR="1"), cwd=REPO).stdout
            except (OSError, subprocess.TimeoutExpired) as e:
                out = "install.sh --check : %s\n" % e
            GLib.idle_add(self._etats_install, self._sans_couleur(out))
        threading.Thread(target=faire, daemon=True).start()

    def _etats_install(self, out):
        etats = {}
        for l in out.splitlines():
            m = re.match(r"^\[\s*(OK|----|\?|KO|!!)?\s*\]\s+(.+?)\s+\(([^)]*)\)\s*$", l)
            if m:
                etats[m.group(2)] = (m.group(1) or "?", m.group(3))
        couleurs = {"OK": "#50FA7B", "----": "#FF5555", "?": "#F1FA8C"}
        for row in self.install_store:
            code, txt = etats.get(row[2], ("?", ""))
            row[0] = '<span foreground="%s">●</span>' % couleurs.get(code, "#FF5555")
            row[5] = txt
        self._remplir(self.install_log, "$ install.sh --check\n" + out)
        return False

    def _ecrire_install(self, txt):
        self._ajouter_couleur(self.install_log, txt)
        return False

    def _install(self, args, root=True):
        if "--only" in args and not self._etape():
            self._ecrire_install("choisir une etape dans la liste\n")
            return
        argv = ["bash", INSTALL_SH] + args
        self._remplir(self.install_log, "$ %s%s\n" % (" ".join(argv), "   [root]" if root else ""))
        self.lancer([], argv=argv, cwd=REPO, ecrire=self._ecrire_install, root=root, env={"GSM_ROOT": GSM_ROOT},
                    apres=lambda rc: self.install_verifier())

    # ══ KCONFIG: the kernel-style menu, in GTK ═════════════════════════════
    # The same Kconfig files as "start.sh --configure" (mconf, TUI) and
    # "make menuconfig", read with tools/kconfig/kconfiglib.py: the tree of
    # menus, a box per bool/tristate, a radio per choice entry, an editable
    # value per string/int/hex; the help of the selected line below. Each
    # change is re-evaluated at once (dependencies, visibility).
    def _onglet_kconfig(self):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.set_border_width(6)
        haut = Gtk.Box(spacing=6)
        b.pack_start(haut, False, False, 0)
        self.kc_combo = Gtk.ComboBoxText()
        for titre, *_ in KCONFIGS:
            self.kc_combo.append_text(titre)
        self.kc_combo.set_active(0)
        self.kc_combo.connect("changed", lambda *_: self.kc_charger())
        haut.pack_start(self.kc_combo, False, False, 0)
        for lab, tip, f in (("Recharger", "relit le Kconfig et la configuration enregistree", self.kc_charger),
                            ("Enregistrer", "ecrit la configuration (.config / start.config)", self.kc_enregistrer),
                            ("Enregistrer et demarrer", "start.sh --config=<fichier> --no-attach (root)", self.kc_demarrer)):
            bt = Gtk.Button(label=lab)
            bt.set_tooltip_text(tip)
            bt.connect("clicked", lambda _b, f=f: f())
            haut.pack_start(bt, False, False, 0)
        self.kc_cherche = Gtk.SearchEntry(placeholder_text="chercher (symbole ou texte)")
        self.kc_cherche.connect("search-changed", lambda *_: self.kc_remplir())
        haut.pack_end(self.kc_cherche, False, False, 0)
        self.kc_fichier = Gtk.Label(xalign=0, selectable=True)
        b.pack_start(self.kc_fichier, False, False, 0)
        p = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        b.pack_start(p, True, True, 0)
        # prompt, value, active, toggle visible, radio, editable, index, symbol, row background
        self.kc_store = Gtk.TreeStore(str, str, bool, bool, bool, bool, int, str, str)
        vue = Gtk.TreeView(model=self.kc_store)
        vue.set_grid_lines(Gtk.TreeViewGridLines.HORIZONTAL)
        rt = Gtk.CellRendererToggle()
        rt.connect("toggled", self._kc_bascule)
        c = Gtk.TreeViewColumn("", rt, active=2, visible=3, radio=4, cell_background=8)
        vue.append_column(c)
        ro = Gtk.CellRendererText(ypad=4, ellipsize=Pango.EllipsizeMode.END)
        co = Gtk.TreeViewColumn("option", ro, markup=0, cell_background=8)
        co.set_expand(True)
        co.set_resizable(True)
        vue.append_column(co)
        re_ = Gtk.CellRendererText(family="Ubuntu Mono", foreground="#0550ae")
        re_.connect("edited", self._kc_edite)
        cv = Gtk.TreeViewColumn("valeur", re_, text=1, editable=5, cell_background=8)
        cv.set_resizable(True)
        cv.set_min_width(180)
        vue.append_column(cv)
        vue.append_column(Gtk.TreeViewColumn("symbole", Gtk.CellRendererText(foreground="#8c959f", scale=0.85,
                                                                              family="Ubuntu Mono"),
                                             text=7, cell_background=8))
        vue.get_selection().connect("changed", self._kc_aide)
        self.kc_vue = vue
        sw = Gtk.ScrolledWindow()
        sw.add(vue)
        p.pack1(sw, True, False)
        self.kc_help, sw2 = self._texte(170)
        self.kc_help.set_wrap_mode(Gtk.WrapMode.WORD)
        self.kc_help.set_monospace(False)          # the help is INTERPRETED (md_buffer), like the Wiki
        self.kc_help.set_left_margin(14)
        self.kc_help.set_right_margin(14)
        p.pack2(sw2, False, False)
        self.kc = None
        self.kc_cfg = None
        return b

    def _kc_lib(self):
        d = os.path.join(REPO, "tools", "kconfig")
        if d not in sys.path:
            sys.path.insert(0, d)
        import kconfiglib
        return kconfiglib

    def kc_charger(self):
        """gen-start.sh (several seconds) and the kconfiglib parse in a thread; the tree in the GTK loop."""
        titre, kfile, cfg, gen = KCONFIGS[self.kc_combo.get_active()]
        self.kc_fichier.set_text("chargement de %s ..." % kfile)
        self.kc_store.clear()
        self.kc_gen = getattr(self, "kc_gen", 0) + 1
        g = self.kc_gen

        def faire():
            c = cfg() if callable(cfg) else cfg
            msg = ""
            try:
                arbre = kc_arbre()
            except OSError as e:
                arbre, msg = REPO, "arbre Kconfig : %s\n" % e
            for cmd in kc_generateurs(gen, arbre):
                try:
                    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=180)
                    if r.returncode:
                        msg += "%s : code %d\n%s" % (" ".join(cmd), r.returncode, r.stdout[-2000:] + r.stderr[-2000:])
                except (OSError, subprocess.TimeoutExpired) as e:
                    msg += "%s : %s" % (" ".join(cmd), e)
            kc = None
            try:
                kl = self._kc_lib()
                with KC_VERROU:
                    ancien = {k: os.environ.get(k) for k in ("srctree", "KCONFIG_CONFIG")}
                    os.environ.update(srctree=arbre, KCONFIG_CONFIG=c)
                    try:
                        kc = kl.Kconfig(kfile, warn=False)
                        if os.path.exists(c):
                            kc.load_config(c)
                    finally:
                        for k, v in ancien.items():
                            if v is None:
                                os.environ.pop(k, None)
                            else:
                                os.environ[k] = v
            except Exception as e:              # kconfiglib raises its own errors
                msg += "\nlecture de %s impossible : %s" % (kfile, e)
            GLib.idle_add(self._kc_charge, g, kc, c, kfile, msg)
        threading.Thread(target=faire, daemon=True).start()
        return False

    def _kc_charge(self, g, kc, cfg, kfile, msg):
        if g != self.kc_gen:
            return False                        # another Kconfig was chosen meanwhile
        self.kc, self.kc_cfg = kc, cfg
        self.kc_fichier.set_text("%s  ->  %s%s" % (os.path.join(REPO, kfile), cfg,
                                                   "" if os.path.exists(cfg) else "  (pas encore ecrit)"))
        self.kc_remplir()
        if msg:
            self._remplir(self.kc_help, msg.strip() + "\n", bas=False)
        return False

    def kc_remplir(self):
        self.kc_store.clear()
        self.kc_noeuds = []
        if not self.kc:
            return
        kl = self._kc_lib()
        q = self.kc_cherche.get_text().strip().lower()

        def correspond(node):
            if not q:
                return True
            nom = getattr(node.item, "name", "") or ""
            return q in node.prompt[0].lower() or q in nom.lower()

        def ajout(parent, node):
            while node:
                visible = node.prompt and kl.expr_value(node.prompt[1])
                if visible:
                    if q:
                        if correspond(node):
                            self._kc_ligne(None, node, kl)
                        if node.list:
                            ajout(None, node.list)
                    else:
                        it = self._kc_ligne(parent, node, kl)
                        if node.list:
                            ajout(it, node.list)
                elif node.list and not node.prompt:
                    ajout(parent, node.list)
                node = node.next
        ajout(None, self.kc.top_node.list)
        self.kc_vue.expand_all()

    @staticmethod
    def _kc_prompt(texte):
        """A prompt as markup. The generated ones read « NAME : defaut : VALUE  (file:line) »:
        the name in bold, the default as code, where it comes from small and grey."""
        m = re.match(r"^(\S+) : defaut : (.*?)\s+\(([^()\s]+:\S*)\)$", texte)
        e = GLib.markup_escape_text
        if not m:
            return e(texte)
        return ('<b>%s</b>   <span foreground="#57606a">defaut</span> '
                '<tt><span background="#eef1f5" foreground="#24292f"> %s </span></tt>   '
                '<span size="small" foreground="#8c959f">%s</span>' % (e(m.group(1)), e(m.group(2)), e(m.group(3))))

    def _kc_ligne(self, parent, node, kl):
        it = node.item
        idx = len(self.kc_noeuds)
        self.kc_noeuds.append(node)
        p = self._kc_prompt(node.prompt[0])
        if it == kl.MENU:
            row = ['<span size="large"><b>%s</b></span>' % p, "", False, False, False, False, idx, "", "#dde5ee"]
        elif it == kl.COMMENT:
            row = ['<span foreground="#57606a" size="small"><b>%s</b></span>' % GLib.markup_escape_text(
                node.prompt[0].upper()), "", False, False, False, False, idx, "", "#f3f5f8"]
        elif isinstance(it, kl.Choice):
            sel = it.selection
            # the value of a choice: the TEXT of the option taken, not its symbol
            val = (sel.nodes[0].prompt[0] if sel and sel.nodes and sel.nodes[0].prompt else sel.name) if sel else ""
            row = [p if p.startswith("<b>") else "<b>%s</b>" % p, val, False, False, False, False, idx, it.name or "", None]
        else:
            t = it.orig_type
            if t in (kl.BOOL, kl.TRISTATE):
                radio = it.choice is not None
                val = kl.TRI_TO_STR[it.tri_value] if t == kl.TRISTATE else ""
                row = [p, val, it.tri_value > 0, True, radio, False, idx, it.name, None]
            else:
                row = [p, it.str_value, False, False, False, True, idx, it.name, None]
        return self.kc_store.append(parent, row)

    def _kc_noeud(self, chemin):
        return self.kc_noeuds[self.kc_store[chemin][6]]

    def _kc_bascule(self, _r, chemin):
        kl = self._kc_lib()
        sym = self._kc_noeud(chemin).item
        if not isinstance(sym, kl.Symbol):
            return
        if sym.choice is not None:
            sym.set_value(2)
        elif sym.assignable:
            a = list(sym.assignable)
            v = a[(a.index(sym.tri_value) + 1) % len(a)] if sym.tri_value in a else a[-1]
            if sym.orig_type == kl.BOOL:
                v = 0 if sym.tri_value else 2
            sym.set_value(v)
        else:
            self._remplir(self.kc_help, "%s n'est pas modifiable ici (dependances : %s)\n" % (
                sym.name, kl.expr_str(sym.direct_dep)), bas=False)
            return
        self.kc_remplir()

    def _kc_edite(self, _r, chemin, texte):
        sym = self._kc_noeud(chemin).item
        if not sym.set_value(texte):
            self._remplir(self.kc_help, "valeur refusee pour %s : %r\n" % (sym.name, texte), bas=False)
        self.kc_remplir()

    def _kc_aide(self, sel):
        """The help of the option selected, as a small Markdown page (md_buffer): its
        facts in a table, then the help text of the Kconfig."""
        m, it = sel.get_selected()
        if not it or not self.kc:
            return
        kl = self._kc_lib()
        node = self.kc_noeuds[m[it][6]]
        item = node.item

        def c(x):
            return "`%s`" % str(x).replace("`", "'").replace("|", "\\|")

        l = ["### %s" % (node.prompt[0] if node.prompt else ""), "", "| | |", "|---|---|"]
        if isinstance(item, (kl.Symbol, kl.Choice)):
            l.append("| symbole | %s |" % c("CONFIG_%s" % (item.name or "(choix)")))
            l.append("| type | %s |" % kl.TYPE_TO_STR[item.orig_type])
            l.append("| valeur | %s |" % c(item.str_value if item.str_value != "" else "(vide)"))
            l.append("| depend de | %s |" % c(kl.expr_str(node.dep)))
            if isinstance(item, kl.Symbol) and item.rev_dep is not self.kc.n:
                l.append("| selectionne par | %s |" % c(kl.expr_str(item.rev_dep)))
        l.append("| defini dans | %s |" % c("%s:%d" % (node.filename, node.linenr)))
        l += ["", getattr(node, "help", None) or "*(pas d'aide)*"]
        for w in self.kc_help.get_children():
            self.kc_help.remove(w)
        md_buffer(self.kc_help.get_buffer(), "\n".join(l) + "\n", vue=self.kc_help, base=REPO)

    def kc_enregistrer(self, ensuite=None):
        if not self.kc:
            return
        cfg = self.kc_cfg
        try:
            os.makedirs(os.path.dirname(cfg), exist_ok=True)
            msg = self.kc.write_config(cfg)
            self._remplir(self.kc_help, "%s\n" % msg, bas=False)
            if ensuite:
                ensuite()
        except OSError:
            tmp = os.path.join(GLib.get_tmp_dir(), "constellation-%d.config" % os.getpid())
            self.kc.write_config(tmp)
            self.lancer([], brut=["install", "-Dm644", tmp, cfg], ecrire=self._kc_ecrire,
                        apres=lambda rc: ensuite() if ensuite and rc == 0 else None)
        self.kc_fichier.set_text("%s  ->  %s" % (KCONFIGS[self.kc_combo.get_active()][1], cfg))

    def _kc_ecrire(self, txt):
        buf = self.kc_help.get_buffer()
        buf.insert(buf.get_end_iter(), txt)
        return False

    def kc_demarrer(self):
        cfg = self.kc_cfg
        if KCONFIGS[self.kc_combo.get_active()][1] != "kconfig/start/Kconfig":
            self._remplir(self.kc_help, "« Enregistrer et demarrer » sert la configuration de demarrage ; "
                                        "le build se lance par make (onglet Infos : commandes).\n", bas=False)
            return
        start = os.path.join(REPO, "start.sh").replace("'", "")
        c = cfg.replace("'", "")

        def go():
            self.onglets.set_current_page(0)
            self.lancer([], brut=["bash", "-c", "python3 '%s/tools/osmo-db.py' globals-depuis-config '%s' && "
                                  "OSMO_CONFIGURE=1 bash '%s' --config='%s' --no-attach" % (REPO, c, start, c)])
        self.kc_enregistrer(ensuite=go)

    # ══ TESTS ══════════════════════════════════════════════════════════════
    def _onglet_tests(self):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.set_border_width(6)
        haut = Gtk.Box(spacing=6)
        b.pack_start(haut, False, False, 0)
        for lab, tip, f in (
                ("Lancer", "le test choisi, ou tout son groupe", lambda: self.tests_suite(self._tests_choisis())),
                ("Tests seuls", "ceux qui ne demandent ni banc, ni installation", lambda: self.tests_suite(
                    [i for i, t in enumerate(TESTS) if t[5] == ""])),
                ("Tests sur le banc lance", "ceux qui lisent la pile en cours", lambda: self.tests_suite(
                    [i for i, t in enumerate(TESTS) if t[5] == "banc"])),
                ("Arreter la suite", "le test en cours finit, les suivants ne partent pas", lambda: setattr(self, "test_file", []))):
            bt = Gtk.Button(label=lab)
            bt.set_tooltip_text(tip)
            bt.connect("clicked", lambda _b, f=f: f())
            haut.pack_start(bt, False, False, 0)
        self.test_bilan = Gtk.Label(xalign=0)
        haut.pack_end(self.test_bilan, False, False, 0)
        p = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        b.pack_start(p, True, True, 0)
        # state, name, condition, command, index (-1: a group)
        self.test_store = Gtk.TreeStore(str, str, str, str, int)
        self.test_iters = {}
        groupes = {}
        for i, (g, nom, argv, cwd, _root, cond) in enumerate(TESTS):
            if g not in groupes:
                groupes[g] = self.test_store.append(None, ["", "<b>%s</b>" % GLib.markup_escape_text(g), "", "", -1])
            self.test_iters[i] = self.test_store.append(groupes[g], ["", GLib.markup_escape_text(nom),
                                                                     CONDITIONS[cond], " ".join(argv), i])
        vue = Gtk.TreeView(model=self.test_store)
        vue.append_column(Gtk.TreeViewColumn("", Gtk.CellRendererText(), markup=0))
        vue.append_column(Gtk.TreeViewColumn("test", Gtk.CellRendererText(), markup=1))
        vue.append_column(Gtk.TreeViewColumn("condition", Gtk.CellRendererText(foreground="#888"), text=2))
        vue.get_selection().connect("changed", lambda s: self._test_decrire())
        vue.connect("row-activated", lambda *_: self.tests_suite(self._tests_choisis()))
        vue.set_tooltip_column(3)
        vue.expand_all()
        self.test_vue = vue
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(560, -1)
        sw.add(vue)
        p.pack1(sw, False, False)
        self.test_log, sw2 = self._texte(sombre=True)
        p.pack2(sw2, True, False)
        self.test_sorties = {}
        self.test_file = []
        self.test_rc = {}
        return b

    def _test_choisi(self):
        m, it = self.test_vue.get_selection().get_selected()
        return m[it][4] if it and m[it][4] >= 0 else None

    def _tests_choisis(self):
        m, it = self.test_vue.get_selection().get_selected()
        if not it:
            return []
        if m[it][4] >= 0:
            return [m[it][4]]
        c = m.iter_children(it)
        out = []
        while c:
            out.append(m[c][4])
            c = m.iter_next(c)
        return out

    def _test_decrire(self):
        i = self._test_choisi()
        if i is None:
            return
        if i in self.test_sorties:
            self._remplir_couleur(self.test_log, self.test_sorties[i])
            return
        _g, nom, argv, cwd, root, cond = TESTS[i]
        fichier = next((os.path.join(cwd, a) for a in argv if a.endswith((".sh", ".py")) and
                        os.path.exists(os.path.join(cwd, a))), None)
        entete = []
        if fichier:
            with open(fichier, errors="replace") as f:
                for l in f.readlines()[1:70]:
                    if not l.startswith("#"):
                        break
                    entete.append(l[1:].rstrip())
        self._remplir(self.test_log, "%s\n$ (cd %s && %s)%s\ncondition : %s\n\n%s\n" % (
            nom, cwd, " ".join(argv), "   [root]" if root else "", CONDITIONS[cond],
            "\n".join(entete) or "(pas d'en-tete)"), bas=False)

    def _test_etat(self, i, markup):
        self.test_store[self.test_iters[i]][0] = markup

    def test_lancer(self, i, apres=None):
        if i is None:
            return
        _g, nom, argv, cwd, root, _cond = TESTS[i]
        self._test_etat(i, '<span foreground="#F1FA8C">●</span>')
        self.test_sorties[i] = "$ (cd %s && %s)%s\n" % (cwd, " ".join(argv), "   [root]" if root else "")
        self.test_vue.get_selection().select_iter(self.test_iters[i])
        self._remplir_couleur(self.test_log, self.test_sorties[i])

        def ecrire(txt, i=i):
            self.test_sorties[i] += txt
            if len(self.test_sorties[i]) > 2000000:
                self.test_sorties[i] = self.test_sorties[i][-1500000:]
            if self._test_choisi() == i:
                self._ajouter_couleur(self.test_log, txt)
            return False

        def fini(rc, i=i):
            self.test_rc[i] = rc
            self._test_etat(i, '<span foreground="%s">●</span> %s' % ("#50FA7B" if rc == 0 else "#FF5555", rc))
            ok = sum(1 for v in self.test_rc.values() if v == 0)
            self.test_bilan.set_text("%d reussis, %d en echec" % (ok, len(self.test_rc) - ok))
            if apres:
                apres(rc)
        self.lancer([], argv=list(argv), cwd=cwd, ecrire=ecrire, apres=fini, root=root)

    def tests_suite(self, liste):
        """Runs the tests one after the other (each waits for the previous one)."""
        self.test_file = list(liste)
        for i in self.test_file:
            self._test_etat(i, '<span foreground="#888">en attente</span>')
        self._test_suivant()

    def _test_suivant(self):
        if self.test_file:
            self.test_lancer(self.test_file.pop(0), apres=lambda rc: self._test_suivant())

    # ══ NOTEBOOKS: the wiki's Jupyter notebooks, runnable here ═════════════
    # One python3 per notebook acts as the kernel: the cells share its
    # namespace (the helpers of the first cell serve the next ones), a
    # %%bash cell runs in bash, the value of a last expression is printed,
    # as in Jupyter. "Interrompre" sends SIGINT to its process group.
    def _onglet_notebooks(self):
        from gi.repository import Gdk
        css = Gtk.CssProvider()
        css.load_from_data(NB_CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        haut = Gtk.Box(spacing=6)
        haut.get_style_context().add_class("nb-barre")
        b.pack_start(haut, False, False, 0)
        self.nb_combo = Gtk.ComboBoxText()
        for f in NOTEBOOKS:
            self.nb_combo.append_text(os.path.basename(f))
        self.nb_combo.connect("changed", lambda *_: self.nb_ouvrir())
        haut.pack_start(self.nb_combo, False, False, 0)
        for lab, icone, f in (("Tout executer", "media-playback-start-symbolic", self.nb_tout),
                              ("Interrompre", "media-playback-stop-symbolic", self.nb_interrompre),
                              ("Redemarrer le noyau", "view-refresh-symbolic", self.nb_redemarrer),
                              ("Enregistrer", "document-save-symbolic", self.nb_enregistrer)):
            bt = Gtk.Button(label=lab, image=Gtk.Image.new_from_icon_name(icone, Gtk.IconSize.BUTTON),
                            always_show_image=True)
            bt.connect("clicked", lambda _b, f=f: f())
            haut.pack_start(bt, False, False, 0)
        self.nb_etat = Gtk.Label(xalign=0)
        self.nb_etat.get_style_context().add_class("nb-pastille")
        haut.pack_end(self.nb_etat, False, False, 0)
        self.nb_boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.nb_boite.set_border_width(18)
        self.nb_boite.set_margin_start(40)
        self.nb_boite.set_margin_end(40)
        self.nb_sw = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                        vscrollbar_policy=Gtk.PolicyType.AUTOMATIC)
        fond = Gtk.EventBox()
        fond.get_style_context().add_class("nb-fond")
        fond.add(self.nb_boite)
        self.nb_sw.add(fond)
        b.pack_start(self.nb_sw, True, True, 0)
        self.nb_noyau = None
        self.nb_cellules = []
        self.nb_file = []
        self.nb_courante = None
        self.nb_compteur = 0
        if NOTEBOOKS:
            self.nb_combo.set_active(0)
        return b

    def _nb_classe(self, k, classe):
        """The look of a code cell: '', nb-encours, nb-ok or nb-ko."""
        ctx = self.nb_cellules[k]["carte"].get_style_context()
        for c in ("nb-encours", "nb-ok", "nb-ko"):
            ctx.remove_class(c)
        if classe:
            ctx.add_class(classe)

    def nb_ouvrir(self):
        i = self.nb_combo.get_active()
        if i < 0:
            return
        self.nb_redemarrer(silence=True)
        for w in self.nb_boite.get_children():
            self.nb_boite.remove(w)
        self.nb_chemin = NOTEBOOKS[i]
        with open(self.nb_chemin) as f:
            self.nb_json = json.load(f)
        self.nb_cellules = []
        self.nb_compteur = 0
        base = os.path.dirname(self.nb_chemin)

        def lien(u):
            subprocess.Popen(["xdg-open", u], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        for n, c in enumerate(self.nb_json.get("cells", [])):
            src = "".join(c.get("source", []))
            if c.get("cell_type") == "markdown":
                # the same interpreter as the Wiki tab: headings, tables, images, links
                t = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD,
                                 left_margin=6, right_margin=6)
                t.get_style_context().add_class("nb-md")
                md_buffer(t.get_buffer(), src, vue=t, base=base, ouvrir=lien)
                self.nb_boite.pack_start(t, False, False, 0)
                continue
            if c.get("cell_type") != "code":
                continue
            carte = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            carte.get_style_context().add_class("nb-carte")
            ligne = Gtk.Box(spacing=8)
            ligne.get_style_context().add_class("nb-entete")
            bt = Gtk.Button(label="▶", tooltip_text="executer cette cellule")
            bt.get_style_context().add_class("nb-run")
            num = Gtk.Label(label="[ ]", xalign=0)
            num.get_style_context().add_class("nb-num")
            statut = Gtk.Label(xalign=1)
            ligne.pack_start(bt, False, False, 0)
            ligne.pack_start(num, False, False, 0)
            ligne.pack_end(statut, False, False, 4)
            carte.pack_start(ligne, False, False, 0)
            code = Gtk.TextView(monospace=True)
            code.get_style_context().add_class("nb-code")
            code.get_buffer().set_text(src)
            py_colorer(code.get_buffer())
            code.get_buffer().connect("changed", py_colorer)
            # a long line scrolls inside its cell; the page itself never
            # scrolls sideways, so the text of the Markdown cells wraps
            sw_code = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.AUTOMATIC,
                                         vscrollbar_policy=Gtk.PolicyType.NEVER)
            sw_code.set_margin_start(8)
            sw_code.set_margin_end(8)
            sw_code.set_margin_bottom(8)
            sw_code.add(code)
            carte.pack_start(sw_code, False, False, 0)
            sortie = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.CHAR, cursor_visible=False)
            sortie.get_style_context().add_class("nb-sortie")
            sortie.set_margin_start(8)
            sortie.set_margin_end(8)
            sortie.set_margin_bottom(8)
            sortie.set_no_show_all(True)
            carte.pack_start(sortie, False, False, 0)
            k = len(self.nb_cellules)
            self.nb_cellules.append({"code": code, "sortie": sortie, "statut": statut, "index": n,
                                     "carte": carte, "num": num})
            bt.connect("clicked", lambda _b, k=k: self.nb_executer([k]))
            self.nb_boite.pack_start(carte, False, False, 0)
        self.nb_boite.show_all()
        self.nb_etat.set_text("%d cellules de code" % len(self.nb_cellules))

    def _nb_noyau(self):
        """The kernel of the notebook (started on demand, BLOCKING the first time: password). As root
        through the window's helper, so that the cells that use sudo / $SUDO or start the bench work."""
        if self.nb_noyau is not None:
            return self.nb_noyau
        gen = self.nb_gen = getattr(self, "nb_gen", 0) + 1
        tampon = [""]

        def ligne(t):
            if gen != self.nb_gen:
                return
            for l in (tampon[0] + t).splitlines(True):
                if not l.endswith("\n"):
                    tampon[0] = l
                    return
                im = re.match(r"\x00IMG (\S+)", l)
                m = re.match(r"\x00FIN (\d+) (-?\d+)", l)
                if im:
                    GLib.idle_add(self._nb_image, im.group(1))
                elif m:
                    GLib.idle_add(self._nb_fin, int(m.group(1)), int(m.group(2)))
                else:
                    GLib.idle_add(self._nb_sortie, l)
            tampon[0] = ""

        def fin(_rc):
            if gen == self.nb_gen:
                self.nb_noyau = None
                GLib.idle_add(self._nb_mort)
        self.nb_noyau = executer(self.racine, ["/usr/bin/python3", "-u", "-c", NOYAU], {"PYTHONUNBUFFERED": "1"},
                                 REPO, ligne, fin, root=True, stdin=True)
        return self.nb_noyau

    def nb_executer(self, liste):
        self.nb_file.extend(liste)
        for k in liste:
            self.nb_cellules[k]["statut"].set_markup('<span foreground="#888">en attente</span>')
        if self.nb_courante is None:
            self._nb_suivante()

    def nb_tout(self):
        self.nb_executer(list(range(len(self.nb_cellules))))

    def _nb_suivante(self):
        if not self.nb_file:
            self.nb_courante = None
            self.nb_etat.set_text("au repos")
            return
        k = self.nb_file.pop(0)
        c = self.nb_cellules[k]
        self.nb_courante = k
        buf = c["code"].get_buffer()
        src = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        c["sortie"].get_buffer().set_text("")
        c["sortie"].show()
        c["statut"].set_markup('<span foreground="#9a6700">● en cours</span>')
        c["num"].set_text("[*]")
        self._nb_classe(k, "nb-encours")
        self.nb_etat.set_text("cellule %d / %d" % (k + 1, len(self.nb_cellules)))
        def envoyer():
            try:
                n = self._nb_noyau()
                if n is None:
                    raise OSError("noyau non demarre")
                n.ecrire(json.dumps({"id": k, "code": src}) + "\n")
            except (OSError, ValueError) as e:
                GLib.idle_add(self._nb_sortie, "noyau : %s\n" % e)
                GLib.idle_add(self._nb_fin, k, 1)
        threading.Thread(target=envoyer, daemon=True).start()

    def _nb_sortie(self, txt):
        if self.nb_courante is None:
            return False
        v = self.nb_cellules[self.nb_courante]["sortie"]
        buf = v.get_buffer()
        buf.insert(buf.get_end_iter(), re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt))
        if buf.get_line_count() > 3000:
            buf.delete(buf.get_start_iter(), buf.get_iter_at_line(buf.get_line_count() - 3000))
        return False

    def _nb_image(self, chemin):
        if self.nb_courante is None:
            return False
        try:
            from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(chemin)
        except GLib.Error as e:
            return self._nb_sortie("image %s : %s\n" % (chemin, e))
        try:
            os.unlink(chemin)
        except OSError:
            pass
        buf = self.nb_cellules[self.nb_courante]["sortie"].get_buffer()
        buf.insert_pixbuf(buf.get_end_iter(), pb)
        buf.insert(buf.get_end_iter(), "\n")
        return False

    def _nb_fin(self, k, rc):
        if k < len(self.nb_cellules):
            self.nb_cellules[k]["statut"].set_markup('<span foreground="%s">● %s</span>' % (
                ("#1a7f37", "ok") if rc == 0 else ("#cf222e", "code %d" % rc)))
            self.nb_compteur += 1
            self.nb_cellules[k]["num"].set_text("[%d]" % self.nb_compteur)
            self._nb_classe(k, "nb-ok" if rc == 0 else "nb-ko")
        if rc != 0:
            for j in self.nb_file:
                self.nb_cellules[j]["statut"].set_text("")
            self.nb_file = []           # stop at the first failing cell, as "Run all" does
        self.nb_courante = None
        self._nb_suivante()
        return False

    def _nb_mort(self):
        if self.nb_courante is not None:
            self._nb_sortie("[noyau arrete]\n")
            self._nb_fin(self.nb_courante, 1)
        return False

    def nb_interrompre(self):
        if self.nb_noyau is not None:
            self.nb_noyau.signal(signal.SIGINT)

    def nb_redemarrer(self, silence=False):
        n, self.nb_noyau = self.nb_noyau, None
        self.nb_gen = getattr(self, "nb_gen", 0) + 1        # what the old kernel still says is ignored
        self.nb_file = []
        if n is not None:
            n.signal(signal.SIGTERM)
        self.nb_courante = None
        if not silence:
            self.nb_etat.set_text("noyau redemarre")
            for c in self.nb_cellules:
                c["statut"].set_text("")

    def nb_enregistrer(self):
        """Writes the edited code back into the .ipynb (outputs left out)."""
        cells = self.nb_json.get("cells", [])
        for c in self.nb_cellules:
            buf = c["code"].get_buffer()
            src = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
            cells[c["index"]]["source"] = src.splitlines(True)
        try:
            with open(self.nb_chemin, "w") as f:
                json.dump(self.nb_json, f, ensure_ascii=False, indent=1)
                f.write("\n")
            self.nb_etat.set_text("enregistre : %s" % os.path.basename(self.nb_chemin))
        except OSError as e:
            self.nb_etat.set_text("non enregistre : %s" % e)

    # ══ WIKI ═══════════════════════════════════════════════════════════════
    def _onglet_wiki(self):
        p = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        p.set_border_width(6)
        g = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.wiki_cherche = Gtk.SearchEntry(placeholder_text="chercher dans la page")
        self.wiki_cherche.connect("activate", lambda *_: self.wiki_suivant())
        self.wiki_cherche.connect("search-changed", lambda *_: self.wiki_suivant(depuis_debut=True))
        g.pack_start(self.wiki_cherche, False, False, 0)
        self.wiki_store = Gtk.ListStore(str, str)
        for titre, chemin in PAGES_WIKI:
            self.wiki_store.append([titre, chemin])
        vue = Gtk.TreeView(model=self.wiki_store, headers_visible=False)
        vue.append_column(Gtk.TreeViewColumn("", Gtk.CellRendererText(), text=0))
        vue.get_selection().connect("changed", self._wiki_ouvrir)
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(260, -1)
        sw.add(vue)
        g.pack_start(sw, True, True, 0)
        p.pack1(g, False, False)
        self.wiki_vue = Gtk.TextView(editable=False, wrap_mode=Gtk.WrapMode.WORD, left_margin=16, right_margin=16,
                                     top_margin=10, cursor_visible=False)
        md_tags(self.wiki_vue.get_buffer())
        css = Gtk.CssProvider()
        css.load_from_data(b""".md-table { border: 1px solid #c9d1d9; margin: 6px 0 10px 0; }
.md-tete { background-color: #e6ebf1; border: 1px solid #c9d1d9; }
.md-pair { background-color: #f6f8fa; border: 1px solid #d8dee4; }
.md-impair { background-color: #ffffff; border: 1px solid #d8dee4; }
.md-tete label, .md-pair label, .md-impair label { color: #1f2328; }""")
        from gi.repository import Gdk
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.wiki_vue.connect("button-release-event", self._wiki_clic)
        self.wiki_vue.connect("motion-notify-event", self._wiki_survol)
        self._wiki_vue_liste = vue
        self._wiki_fichier = None
        sw2 = Gtk.ScrolledWindow()
        sw2.add(self.wiki_vue)
        p.pack2(sw2, True, False)
        if PAGES_WIKI:
            vue.get_selection().select_path(Gtk.TreePath.new_first())
        return p

    def _wiki_ouvrir(self, sel):
        m, it = sel.get_selected()
        if not it:
            return
        self._wiki_charger(m[it][1])

    def _wiki_charger(self, chemin):
        try:
            with open(chemin, errors="replace") as f:
                texte = f.read()
        except OSError as e:
            texte = "%s\n" % e
        self._wiki_fichier = chemin
        # the tables of the previous page are widgets of the view
        for w in self.wiki_vue.get_children():
            self.wiki_vue.remove(w)
        md_buffer(self.wiki_vue.get_buffer(), texte, vue=self.wiki_vue, base=os.path.dirname(chemin),
                  ouvrir=self._wiki_lien)
        self.wiki_vue.scroll_to_iter(self.wiki_vue.get_buffer().get_start_iter(), 0, False, 0, 0)

    def _wiki_lien_sous(self, ev):
        x, y = self.wiki_vue.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, int(ev.x), int(ev.y))
        ok, it = self.wiki_vue.get_iter_at_location(x, y)
        if not ok:
            return None
        liens = getattr(self.wiki_vue.get_buffer(), "md_liens", {})
        for t in it.get_tags():
            if t in liens:
                return liens[t]
        return None

    def _wiki_survol(self, _w, ev):
        from gi.repository import Gdk
        win = self.wiki_vue.get_window(Gtk.TextWindowType.TEXT)
        if win:
            win.set_cursor(Gdk.Cursor.new_from_name(win.get_display(),
                                                    "pointer" if self._wiki_lien_sous(ev) else "text"))
        return False

    def _wiki_clic(self, _w, ev):
        if ev.button != 1 or self.wiki_vue.get_buffer().get_has_selection():
            return False
        cible = self._wiki_lien_sous(ev)
        if cible:
            self._wiki_lien(cible)
        return False

    def _wiki_lien(self, cible):
        """A link of the page: another Markdown page opens here, a heading
        (#...) is searched in the page, anything else goes to the desktop."""
        if cible.startswith("#"):
            mot = cible[1:].replace("-", " ")
            buf = self.wiki_vue.get_buffer()
            r = buf.get_start_iter().forward_search(mot, Gtk.TextSearchFlags.CASE_INSENSITIVE, None)
            if r:
                self.wiki_vue.scroll_to_iter(r[0], 0.0, True, 0, 0.05)
            return
        if re.match(r"^[a-z][a-z0-9+.-]*:", cible):
            subprocess.Popen(["xdg-open", cible], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        f = os.path.normpath(os.path.join(os.path.dirname(self._wiki_fichier or REPO), cible.split("#")[0]))
        if f.endswith(".md") and os.path.isfile(f):
            for k, rang in enumerate(self.wiki_store):
                if os.path.realpath(rang[1]) == os.path.realpath(f):
                    self._wiki_vue_liste.get_selection().select_path(Gtk.TreePath.new_from_indices([k]))
                    return
            self._wiki_charger(f)
        elif os.path.exists(f):
            subprocess.Popen(["xdg-open", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wiki_suivant(self, depuis_debut=False):
        buf = self.wiki_vue.get_buffer()
        buf.remove_tag_by_name("trouve", buf.get_start_iter(), buf.get_end_iter())
        q = self.wiki_cherche.get_text()
        if not q:
            return
        depart = buf.get_start_iter() if depuis_debut or not getattr(self, "_wiki_pos", None) else \
            buf.get_iter_at_offset(self._wiki_pos)
        r = depart.forward_search(q, Gtk.TextSearchFlags.CASE_INSENSITIVE, None) or \
            buf.get_start_iter().forward_search(q, Gtk.TextSearchFlags.CASE_INSENSITIVE, None)
        if r:
            a, z = r
            buf.apply_tag_by_name("trouve", a, z)
            self._wiki_pos = z.get_offset()
            self.wiki_vue.scroll_to_iter(a, 0.1, True, 0, 0.3)

    # ══ TRUNK SIP: the way out to the public network, typed here ════════════
    def _onglet_trunk(self):
        """The SIP trunk of the bench (an account at a SIP operator). NOTHING of it is in the
        repository: server, SIP login and password are typed here and written to
        /etc/asterisk/pjsip_trunk.conf (root, mode 640, included by pjsip.conf), then Asterisk
        is reloaded. The dialplan reaches it as PJSIP/<number>@trunk_sip; its calls arrive in
        [trunk_in]."""
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        b.set_border_width(10)
        g = Gtk.Grid(column_spacing=10, row_spacing=6)
        b.pack_start(g, False, False, 0)
        self.tk = {}
        for i, (cle, lab, aide, secret) in enumerate((
                ("serveur", "Serveur SIP", "le registrar de l operateur, par exemple sip.exemple.net (ou hote:port)", False),
                ("user", "Identifiant SIP", "le login SIP du compte chez l operateur", False),
                ("mdp", "Mot de passe SIP", "il n est ecrit que dans /etc/asterisk/pjsip_trunk.conf (root, 640)", True),
                ("numero", "Numero presente", "facultatif : le numero montre a l appele (defaut : l identifiant)", False))):
            l = Gtk.Label(label=lab, xalign=1)
            e = Gtk.Entry(width_chars=42, placeholder_text=aide)
            if secret:
                e.set_visibility(False)
                e.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            g.attach(l, 0, i, 1, 1)
            g.attach(e, 1, i, 1, 1)
            self.tk[cle] = e
        self.tk_reg = Gtk.CheckButton(label="s enregistrer aupres de l operateur (appels entrants)")
        self.tk_reg.set_active(True)
        g.attach(self.tk_reg, 1, 4, 1, 1)
        ligne = Gtk.Box(spacing=6)
        b.pack_start(ligne, False, False, 0)
        for lab, cls, f in (("Ecrire le trunk et recharger Asterisk", "suggested-action", self.tk_ecrire),
                            ("Etat", None, self.tk_etat), ("Retirer le trunk", "destructive-action", self.tk_retirer)):
            bt = Gtk.Button(label=lab)
            if cls:
                bt.get_style_context().add_class(cls)
            bt.connect("clicked", lambda _b, f=f: f())
            ligne.pack_start(bt, False, False, 0)
        self.tk_sortie, sw = self._texte(160)
        b.pack_start(sw, True, True, 0)
        self._remplir(self.tk_sortie, "Le trunk n est ecrit nulle part dans le depot : renseigner le compte, puis "
                                      "« Ecrire le trunk ».\n« Etat » montre ce qu Asterisk en dit (sans le mot de passe).\n")
        return b

    def _tk_dire(self, txt):
        buf = self.tk_sortie.get_buffer()
        buf.insert(buf.get_end_iter(), txt)
        _vers_la_fin_tv(self.tk_sortie)
        return False

    def tk_ecrire(self):
        v = {k: e.get_text().strip() for k, e in self.tk.items()}
        v["mdp"] = self.tk["mdp"].get_text()
        err = []
        if not re.match(r"^[A-Za-z0-9.-]+(:\d+)?$", v["serveur"]):
            err.append("serveur : un nom d hote ou une adresse (hote ou hote:port)")
        if not re.match(r"^[\w.@+-]+$", v["user"]):
            err.append("identifiant : lettres, chiffres, . @ + - _")
        if not v["mdp"] or re.search(r"[\r\n;]", v["mdp"]):
            err.append("mot de passe : requis, sans retour a la ligne ni point-virgule (commentaire d Asterisk)")
        if v["numero"] and not re.match(r"^[\w.+-]+$", v["numero"]):
            err.append("numero presente : chiffres, +, lettres")
        if err:
            return self._remplir(self.tk_sortie, "Refuse :\n  " + "\n  ".join(err) + "\n")
        v["numero"] = v["numero"] or v["user"]
        v["hote"] = v["serveur"].split(":")[0]
        conf = TRUNK_MODELE % v + ((TRUNK_REG % v) if self.tk_reg.get_active() else "")
        # through a file of the user's own (0600), installed by root, then removed
        fd, tmp = __import__("tempfile").mkstemp(prefix="trunk-", suffix=".conf")
        with os.fdopen(fd, "w") as f:
            f.write(conf)
        cmd = ("install -m 640 -o asterisk -g asterisk '%(t)s' %(d)s/pjsip_trunk.conf 2>/dev/null "
               "|| install -m 640 '%(t)s' %(d)s/pjsip_trunk.conf; rc=$?; rm -f '%(t)s'; [ $rc = 0 ] || exit $rc; "
               "grep -q '^#tryinclude pjsip_trunk.conf' %(d)s/pjsip.conf "
               "|| printf '\\n; the SIP trunk, written by osmo-gtk (tab Trunk SIP)\\n#tryinclude pjsip_trunk.conf\\n' >> %(d)s/pjsip.conf; "
               "asterisk -rx 'module reload res_pjsip.so' >/dev/null 2>&1; sleep 3; "
               "echo 'trunk ecrit : %(d)s/pjsip_trunk.conf'; asterisk -rx 'pjsip show registrations' 2>&1 | tail -n 6"
               % {"t": tmp, "d": TRUNK_DIR})
        self.tk["mdp"].set_text("")
        self._remplir(self.tk_sortie, "ecriture du trunk %s@%s ...\n" % (v["user"], v["serveur"]))
        self.lancer([], argv=["bash", "-c", cmd], cwd=REPO, ecrire=self._tk_dire)

    def tk_etat(self):
        self._remplir(self.tk_sortie, "")
        self.lancer([], argv=["bash", "-c",
                              "[ -f %(d)s/pjsip_trunk.conf ] && echo 'trunk : '$(sed -n 's/^client_uri=//p; s/^contact=//p' %(d)s/pjsip_trunk.conf | head -n 1) "
                              "|| echo 'pas de trunk ecrit (%(d)s/pjsip_trunk.conf)'; "
                              "asterisk -rx 'pjsip show registrations' 2>&1 | tail -n 8; "
                              "asterisk -rx 'pjsip show endpoint trunk_sip' 2>&1 | grep -E 'Endpoint:|Contact:|Unable' | head -n 4"
                              % {"d": TRUNK_DIR}], cwd=REPO, ecrire=self._tk_dire)

    def tk_retirer(self):
        self._remplir(self.tk_sortie, "")
        self.lancer([], argv=["bash", "-c",
                              "rm -f %(d)s/pjsip_trunk.conf && asterisk -rx 'module reload res_pjsip.so' >/dev/null 2>&1; "
                              "echo 'trunk retire : plus de sortie SIP vers l exterieur'" % {"d": TRUNK_DIR}],
                    cwd=REPO, ecrire=self._tk_dire)

    # ══ JOURNAUX: chain (dsp, qemu, osmocon, mobile, pont...), mailbox, Osmocom ══
    def _onglet_journaux(self):
        p = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        p.set_border_width(6)
        self.jx_sources = sources_journaux()
        self.jx_store = Gtk.TreeStore(str, str, int)       # state, name, index (-1: group)
        groupes, self.jx_iters = {}, {}
        for i, (g, nom, _k, _c, _h) in enumerate(self.jx_sources):
            if g not in groupes:
                groupes[g] = self.jx_store.append(None, ["", "<b>%s</b>" % GLib.markup_escape_text(g), -1])
            self.jx_iters[i] = self.jx_store.append(groupes[g], ["", GLib.markup_escape_text(nom), i])
        vue = Gtk.TreeView(model=self.jx_store, headers_visible=False)
        vue.append_column(Gtk.TreeViewColumn("", Gtk.CellRendererText(), markup=0))
        vue.append_column(Gtk.TreeViewColumn("", Gtk.CellRendererText(), markup=1))
        vue.expand_all()
        vue.get_selection().connect("changed", lambda *_: self.jx_lire(force=True))
        self.jx_vue = vue
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(300, -1)
        sw.add(vue)
        p.pack1(sw, False, False)
        d = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        haut = Gtk.Box(spacing=6)
        d.pack_start(haut, False, False, 0)
        self.jx_suivre = Gtk.CheckButton(label="suivre")
        self.jx_suivre.set_active(True)
        self.jx_filtre = Gtk.SearchEntry(placeholder_text="filtre (texte ou regex)")
        self.jx_filtre.connect("search-changed", lambda *_: self.jx_lire(force=True))
        self.jx_n = Gtk.SpinButton.new_with_range(100, 20000, 100)
        self.jx_n.set_value(1000)
        self.jx_n.connect("value-changed", lambda *_: self.jx_lire(force=True))
        haut.pack_start(self.jx_suivre, False, False, 0)
        haut.pack_start(Gtk.Label(label="lignes"), False, False, 0)
        haut.pack_start(self.jx_n, False, False, 0)
        haut.pack_start(self.jx_filtre, True, True, 0)
        self.jx_ou = Gtk.Label(xalign=0, selectable=True)
        d.pack_start(self.jx_ou, False, False, 0)
        self.jx_texte, sw2 = self._texte(sombre=True)
        d.pack_start(sw2, True, True, 0)
        p.pack2(d, True, False)
        vue.get_selection().select_iter(self.jx_iters[0])
        GLib.timeout_add(1500, self._jx_tic)
        return p

    def _jx_tic(self):
        # only while the tab is shown: states of every source (file sizes, the /proc scan), then the
        # selected one re-read in a thread when followed
        if self.onglets.get_nth_page(self.onglets.get_current_page()) is not self.jx_page:
            return True
        for i, (_g, _n, k, c, _h) in enumerate(self.jx_sources):
            if k == "file":
                ok = os.path.exists(c) and os.path.getsize(c) > 0
                self.jx_store[self.jx_iters[i]][0] = '<span foreground="%s">●</span>' % ("#50FA7B" if ok else "#555")
            elif k == "osmo":
                self.jx_store[self.jx_iters[i]][0] = '<span foreground="%s">●</span>' % (
                    "#50FA7B" if pid_proc(c) else "#FF5555")
        if self.jx_suivre.get_active() and not getattr(self, "_jx_occupe", False):
            self.jx_lire()
        return True

    def jx_lire(self, force=False):
        m, it = self.jx_vue.get_selection().get_selected()
        if not it or m[it][2] < 0:
            return
        _g, nom, kind, cible, hint = self.jx_sources[m[it][2]]
        n = int(self.jx_n.get_value())

        def faire():
            if kind == "fenetre":
                txt, ou = "\n".join(self.journal_txt.splitlines()[-n:]) + "\n", "commandes lancees par cette fenetre"
            else:
                txt, ou = lire_journal(kind, cible, n)
            if txt is None:
                txt = "(%s absent%s)\n" % (cible, " : " + hint if hint else "")
            q = self.jx_filtre.get_text().strip()
            if q:
                nu = lambda l: re.sub(r"\x1b\[[0-9;]*m", "", l)
                try:
                    r = re.compile(q, re.I)
                    txt = "\n".join(l for l in txt.splitlines() if r.search(nu(l))) + "\n"
                except re.error:
                    txt = "\n".join(l for l in txt.splitlines() if q.lower() in nu(l).lower()) + "\n"
            GLib.idle_add(self._jx_montrer, txt, ou, colorer(txt))
        self._jx_occupe = True
        threading.Thread(target=faire, daemon=True).start()

    def _jx_montrer(self, txt, ou, segs):
        self._jx_occupe = False
        self.jx_ou.set_text(ou)
        self._remplir_couleur(self.jx_texte, txt, segs, bas=self.jx_suivre.get_active())
        return False

    # ══ INFOS: the most the machine and the bench can say ══════════════════
    # ── Telephones: the phones of the node (Network Monitor, Android / postmarketOS) ──
    # One tab for what was only in a terminal: the invitation of a NAMED user as
    # a QR code (osmo-inscription --nouveau-qrcode), the accounts and who is on
    # line, the way out to the outside, the phone that lends its SIM (proxy) and
    # the Bluetooth line. Talks to the osmo-inscription service of THIS machine
    # (http://127.0.0.1:8088/admin/..., local only).
    TEL_API = "http://127.0.0.1:%s" % os.environ.get("OSMO_INSCRIPTION_PORT", "8088")

    def _tel_http(self, chemin, corps=None):
        import urllib.error
        import urllib.request
        req = urllib.request.Request(self.TEL_API + chemin, data=None if corps is None else json.dumps(corps).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            try:
                return json.loads(e.read().decode() or "{}")
            except ValueError:
                return {"ok": False, "error": "HTTP %d" % e.code}
        except (OSError, ValueError) as e:
            return {"ok": False, "error": "service osmo-inscription injoignable (%s)" % e}

    def _tel_fil(self, chemin, corps, suite):
        threading.Thread(target=lambda: GLib.idle_add(suite, self._tel_http(chemin, corps)), daemon=True).start()

    def _onglet_telephones(self):
        p = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        p.set_border_width(6)
        # left: the invitation and its QR code
        g = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        g.set_size_request(380, -1)
        t = Gtk.Label(xalign=0)
        t.set_markup("<b>Inviter un telephone</b>")
        g.pack_start(t, False, False, 0)
        aide = Gtk.Label(xalign=0, wrap=True)
        aide.set_text("Un pseudo par personne (obligatoire), puis le QR code : dans Network Monitor "
                      "(Android ou postmarketOS), « Demarrage rapide » puis « Scanner le QR code ». "
                      "L invitation sert une fois.")
        g.pack_start(aide, False, False, 0)
        ligne = Gtk.Box(spacing=6)
        self.tel_pseudo = Gtk.Entry(placeholder_text="pseudo de la personne")
        self.tel_pseudo.connect("activate", lambda *_: self.tel_inviter())
        ligne.pack_start(self.tel_pseudo, True, True, 0)
        b = Gtk.Button(label="Creer le QR code")
        b.connect("clicked", lambda *_: self.tel_inviter())
        ligne.pack_start(b, False, False, 0)
        g.pack_start(ligne, False, False, 0)
        self.tel_qr = Gtk.Image()
        g.pack_start(self.tel_qr, False, False, 6)
        self.tel_lien = Gtk.Label(xalign=0, wrap=True, selectable=True)
        self.tel_lien.set_line_wrap_mode(Pango.WrapMode.CHAR)
        g.pack_start(self.tel_lien, False, False, 0)
        self.tel_copier = Gtk.Button(label="Copier le lien")
        self.tel_copier.set_sensitive(False)
        self.tel_copier.connect("clicked", lambda *_: Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(
            getattr(self, "_tel_lien", ""), -1))
        g.pack_start(self.tel_copier, False, False, 0)
        p.pack1(g, False, False)
        # right: accounts, proxy, Bluetooth
        d = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        haut = Gtk.Box(spacing=6)
        bt = Gtk.Button(label="Actualiser")
        bt.connect("clicked", lambda *_: self.tel_actualiser())
        haut.pack_start(bt, False, False, 0)
        self.tel_demarrage = Gtk.Button(label="Demarrer le service")
        self.tel_demarrage.set_tooltip_text("Demarre osmo-inscription (port 8088, reseau local de confiance uniquement).")
        self.tel_demarrage.connect("clicked", self.tel_demarrer)
        haut.pack_start(self.tel_demarrage, False, False, 0)
        self._tel_demarrage_en_cours = False
        self.tel_heure = Gtk.Label(xalign=0)
        haut.pack_start(self.tel_heure, False, False, 0)
        d.pack_start(haut, False, False, 0)
        # number, pseudo, state markup, way out, on line
        self.tel_store = Gtk.ListStore(str, str, str, bool)
        vue = Gtk.TreeView(model=self.tel_store)
        for i, titre in ((2, ""), (0, "poste"), (1, "pseudo")):
            r = Gtk.CellRendererText()
            vue.append_column(Gtk.TreeViewColumn(titre, r, **({"markup": i} if i == 2 else {"text": i})))
        rt = Gtk.CellRendererToggle()
        rt.connect("toggled", self._tel_sortie)
        vue.append_column(Gtk.TreeViewColumn("sortie vers l exterieur", rt, active=3))
        sw = Gtk.ScrolledWindow()
        sw.add(vue)
        d.pack_start(sw, True, True, 0)
        self.tel_vue = vue
        vue.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        # the clean-up: selected phones, those that are off line, everything
        menage = Gtk.Box(spacing=6)
        for texte, quoi, aide in (
                ("Effacer la selection", "selection", "Retire les postes selectionnes (Ctrl ou Maj pour plusieurs)."),
                ("Effacer les hors ligne", "hors_ligne", "Retire tous les postes qui ne sont pas en ligne en ce moment."),
                ("Tout effacer", "tous", "Retire TOUS les postes : chaque telephone devra etre reinvite."),
                ("Effacer les invitations", "invitations", "Annule les invitations en attente, jamais utilisees.")):
            bm = Gtk.Button(label=texte)
            bm.set_tooltip_text(aide + " Les numeros redeviennent libres.")
            bm.connect("clicked", self._tel_effacer, quoi)
            menage.pack_start(bm, False, False, 0)
        d.pack_start(menage, False, False, 0)
        self.tel_invits = Gtk.Label(xalign=0, wrap=True)
        d.pack_start(self.tel_invits, False, False, 0)
        self.tel_proxy = Gtk.Label(xalign=0, wrap=True)
        d.pack_start(self.tel_proxy, False, False, 0)
        bas = Gtk.Box(spacing=6)
        self.tel_bt = Gtk.Label(xalign=0, wrap=True)
        bas.pack_start(self.tel_bt, True, True, 0)
        ba = Gtk.Button(label="Associer un telephone (Bluetooth)")
        ba.set_tooltip_text("Le noeud devient visible 3 min ; associez-le depuis les reglages Bluetooth du "
                            "telephone, ou depuis l onglet Proxy de l appli. La ligne se met en place seule.")
        ba.connect("clicked", lambda *_: self._tel_fil("/admin/bluetooth/associer", {}, lambda r: self.tel_actualiser()))
        bas.pack_start(ba, False, False, 0)
        d.pack_start(bas, False, False, 0)
        p.pack2(d, True, False)
        GLib.timeout_add_seconds(5, self._tel_tic, p)
        return p

    def _tel_tic(self, page):
        if self.onglets.get_nth_page(self.onglets.get_current_page()) is page:
            self.tel_actualiser()
        return True

    def tel_demarrer(self, *_):
        if self._tel_demarrage_en_cours:
            return False
        self._tel_demarrage_en_cours = True
        self.tel_demarrage.set_sensitive(False)
        self.tel_heure.set_text("Demarrage de osmo-inscription...")
        self.lancer([], argv=["systemctl", "start", "osmo-inscription.service"],
                    cwd=REPO, root=True, apres=self._tel_demarre)
        return False

    def _tel_demarre(self, rc):
        self._tel_demarrage_en_cours = False
        self.tel_demarrage.set_sensitive(True)
        if rc != 0:
            self.tel_heure.set_text("Demarrage refuse ou en echec (code %s) : journalctl -u osmo-inscription" % rc)
            self.ecrire("osmo-inscription : journalctl -u osmo-inscription -n 50 --no-pager\n")
        else:
            self.tel_actualiser()
        return False

    def tel_actualiser(self):
        if not self._tel_demarrage_en_cours:
            self._tel_fil("/admin/etat", None, self._tel_montrer)
        return False

    def _tel_montrer(self, e):
        if self._tel_demarrage_en_cours:
            return False
        if not e.get("ok"):
            self.tel_demarrage.show()
            self.tel_heure.set_text(e.get("error", "erreur"))
            return False
        self.tel_demarrage.hide()
        self.tel_heure.set_text("noeud %s - releve a %s" % (e.get("noeud") or "?", time.strftime("%H:%M:%S")))
        lignes = [[c["num"], c["pseudo"],
                   '<span foreground="%s">●</span>' % ("#3fb950" if c["en_ligne"] else "#6e7681"),
                   c["sortie"]] for c in e.get("comptes", [])]
        if lignes != [list(r) for r in self.tel_store]:      # unchanged: the selection stays
            self.tel_store.clear()
            for li in lignes:
                self.tel_store.append(li)
        inv = e.get("invitations", [])
        self.tel_invits.set_text("Invitations en attente : " + (", ".join(
            "%s… (%s)" % (i["debut"], i["pseudo"] or "sans pseudo") for i in inv) or "aucune"))
        px = e.get("proxy", {})
        self.tel_proxy.set_text("Pret de SIM (SMS) : " + (
            "poste %s, vers %s, %d SMS en attente" % (px.get("user"), px.get("dest") or "?", px.get("attente", 0))
            if px.get("actif") else "aucun telephone ne prete sa SIM"))
        b = e.get("bluetooth", {})
        li = b.get("ligne")
        if b.get("fenetre"):
            txt = "le noeud « %s » attend un telephone (encore %d s)" % ((b.get("adaptateur") or {}).get("nom", "?"), b["fenetre"])
        elif li:
            nom = next((x["nom"] for x in b.get("appaires", []) if x["adresse"] == li["adresse"]), li["adresse"])
            txt = "%s, %s" % (nom, ("connecte, ligne libre" if li.get("etat") == "Free" else "en appel")
                              if li.get("connecte") else "hors de portee")
        else:
            txt = b.get("message") or "aucun telephone associe"
        self.tel_bt.set_text("Ligne Bluetooth (appels) : " + txt)
        return False

    def _tel_effacer(self, _b, quoi):
        m, chemins = self.tel_vue.get_selection().get_selected_rows()
        nums = [m[c][0] for c in chemins]
        corps, question = {
            "selection": ({"nums": nums}, "Effacer %s ?" % (", ".join(nums) or "(aucun poste selectionne)")),
            "hors_ligne": ({"hors_ligne": True}, "Effacer tous les postes hors ligne ?"),
            "tous": ({"tous": True}, "Effacer TOUS les postes du noeud ?"),
            "invitations": ({"invitations": True}, "Annuler les invitations en attente ?"),
        }[quoi]
        if quoi == "selection" and not nums:
            self.tel_heure.set_text("selectionnez d abord un ou plusieurs postes")
            return
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                buttons=Gtk.ButtonsType.OK_CANCEL, text=question)
        dlg.format_secondary_text("Un poste efface ne peut plus se connecter : son telephone devra scanner une "
                                  "nouvelle invitation. Les numeros redeviennent libres.")
        ok = dlg.run() == Gtk.ResponseType.OK
        dlg.destroy()
        if ok:
            self._tel_fil("/admin/effacer", corps, self._tel_efface)

    def _tel_efface(self, r):
        self.tel_actualiser()
        if r.get("ok"):
            self.tel_heure.set_text("effaces : %s, %d invitation(s)" % (" ".join(r.get("postes", [])) or "aucun poste",
                                                                        r.get("invitations", 0)))
        else:
            self.tel_heure.set_text(r.get("error", "erreur"))
        return False

    def _tel_sortie(self, _r, chemin):
        it = self.tel_store.get_iter(chemin)
        num, oui = self.tel_store[it][0], not self.tel_store[it][3]
        self._tel_fil("/admin/sortie", {"num": num, "oui": oui}, lambda r: self.tel_actualiser())

    def tel_inviter(self):
        pseudo = self.tel_pseudo.get_text().strip()
        if not pseudo:
            self.tel_lien.set_text("Il faut un pseudo : pas d invitation sans nom.")
            return
        self._tel_fil("/admin/invitation", {"pseudo": pseudo}, self._tel_invite)

    def _tel_invite(self, r):
        if not r.get("ok"):
            self.tel_qr.clear()
            self.tel_copier.set_sensitive(False)
            self.tel_lien.set_text(r.get("error", "erreur"))
            return False
        self._tel_lien = r["lien"]
        self.tel_lien.set_text(r["lien"])
        self.tel_copier.set_sensitive(True)
        self.tel_pseudo.set_text("")
        try:        # the PNG goes through a pipe: the secret never lands in a file
            png = subprocess.run(["qrencode", "-o", "-", "-s", "7", "-m", "3", r["lien"]],
                                 capture_output=True, check=True, timeout=10).stdout
            ld = GdkPixbuf.PixbufLoader.new_with_type("png")
            ld.write(png)
            ld.close()
            self.tel_qr.set_from_pixbuf(ld.get_pixbuf())
        except (OSError, subprocess.SubprocessError, GLib.Error) as err:
            self.tel_qr.clear()
            self.tel_lien.set_text("%s\n(QR code impossible : %s - apt install qrencode)" % (r["lien"], err))
        self.tel_actualiser()
        return False

    def _onglet_infos(self):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.set_border_width(6)
        haut = Gtk.Box(spacing=6)
        b.pack_start(haut, False, False, 0)
        bt = Gtk.Button(label="Actualiser")
        bt.connect("clicked", lambda *_: self.infos_actualiser())
        haut.pack_start(bt, False, False, 0)
        self.infos_heure = Gtk.Label(xalign=0)
        haut.pack_start(self.infos_heure, False, False, 0)
        self.infos_vue, sw = self._texte()
        b.pack_start(sw, True, True, 0)
        return b

    def infos_actualiser(self):
        threading.Thread(target=lambda: GLib.idle_add(self._infos_montrer, infos_texte()), daemon=True).start()
        return False

    def _infos_montrer(self, txt):
        self._remplir(self.infos_vue, txt, bas=False)
        self.infos_heure.set_text(time.strftime("releve a %H:%M:%S"))
        return False

    def tic_journaux(self):
        """Core and L23 tabs, only the one shown; files and journal read in a thread."""
        page = self.onglets.get_current_page()
        if page not in (1, 2) or getattr(self, "_jn_occupe", False):
            return True
        if page == 1:
            for row in self.core_store:
                row[0] = '<span foreground="%s">●</span>' % ("#50FA7B" if pid_proc(row[2]) else "#FF5555")
            _nom, proc, _port = self._core_choisi()
            if not proc:
                return True

            def lire():
                txt, ou = lire_journal("osmo", proc, 300)
                GLib.idle_add(self._jn_core, txt, ou, colorer(txt or ""))
        else:
            p = pid_de("mobile")
            self.l23_etat.set_markup('<span foreground="%s">●</span> mobile%s  VTY %d' % (
                "#50FA7B" if p else "#FF5555", " (pid %d)" % p if p else "", port_mobile()))

            def lire():
                f = os.path.join(RUNDIR, "mobile.log")
                t = queue(f, ansi=True) or "(pas de %s)\n" % f
                GLib.idle_add(self._jn_l23, t, colorer(t))
        self._jn_occupe = True
        threading.Thread(target=lire, daemon=True).start()
        return True

    def _jn_core(self, txt, ou, segs):
        self._jn_occupe = False
        self.core_titre.set_text("journal : " + ou)
        self._remplir_couleur(self.core_log, txt or "", segs)
        return False

    def _jn_l23(self, txt, segs):
        self._jn_occupe = False
        self._remplir_couleur(self.l23_log, txt, segs)
        return False

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
        self.journal_txt = (self.journal_txt + txt)[-400000:]
        lignes = [l for l in txt.splitlines() if l.strip()]
        if lignes:
            self.l_derniere.set_text(lignes[-1].strip())
        return False

    def lancer(self, args, brut=None, argv=None, ecrire=None, apres=None, cwd=None, root=True, env=None):
        """Runs a command, its output into ecrire, apres(rc) at the end. root: through the ONE root
        helper of the window (password asked once). Without argv: the chain (commande_chaine)."""
        ecrire = ecrire or self.ecrire
        if argv is None:
            argv, env0 = commande_chaine(args, brut)
            env = dict(env0, **(env or {}))
            ecrire("$ %s\n" % " ".join(argv))
        env = dict({"NO_COLOR": "1"}, **(env or {}))
        cwd = cwd or os.path.dirname(RUN_SH)

        def ligne(t):
            GLib.idle_add(ecrire, re.sub(r"\x1b\[[0-9;]*m", "", t))

        def fin(rc):
            GLib.idle_add(ecrire, "[fin, code %s]\n" % rc)
            if apres:
                GLib.idle_add(apres, rc)
            GLib.idle_add(self._root_etat)
        threading.Thread(target=executer, args=(self.racine, argv, env, cwd, ligne, fin, root), daemon=True).start()

    def _onglet_change(self, nb, page, _n):
        t = nb.get_tab_label_text(page)
        if t in self._vus:
            return
        self._vus.add(t)
        f = {"Kconfig": self.kc_charger, "Installation": self.install_lister, "Infos": self.infos_actualiser,
             "Telephones": self.tel_actualiser}.get(t)
        if f:
            GLib.idle_add(f)

    # the root state, in the top bar
    def _root_etat(self):
        if os.geteuid() == 0:
            self.l_root.set_markup('<span foreground="#50FA7B">● root</span>')
            self.b_root.hide()
        elif self.racine.disponible():
            self.l_root.set_markup('<span foreground="#50FA7B">● root (mot de passe donne)</span>')
            self.b_root.hide()
        else:
            self.l_root.set_markup('<span foreground="#FF5555">● pas root</span>')
            self.b_root.show()
        return False

    def elever(self):
        """Asks for the root password now (once for the whole window)."""
        self.l_root.set_markup('<span foreground="#F1FA8C">● mot de passe root...</span>')
        threading.Thread(target=lambda: (self.racine.demarrer(), GLib.idle_add(self._root_etat)), daemon=True).start()
        return False

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
    def _tic_cadence(self):
        self.tic()
        # the real rate, over the last second
        t = time.monotonic()
        self._cad_n += 1
        if t - self._cad_t >= 1.0:
            self.cadence_reelle = self._cad_n / (t - self._cad_t)
            self._cad_t, self._cad_n = t, 0
        # nothing is drawn outside the Air tab: no need to wake up 30 times a second
        visible = self.onglets.get_current_page() == 0
        GLib.timeout_add(self.periode if visible else CADENCE_LENTE_MS, self._tic_cadence)
        return False

    def _cadence(self, bouton):
        """The button of the Air tab: 30 images per second, or the slow rate (10)."""
        rapide = bouton.get_active()
        self.periode = CADENCE_RAPIDE_MS if rapide else CADENCE_LENTE_MS
        bouton.set_label("30 img/s" if rapide else "lent (10 img/s)")

    def tic(self):
        t = time.monotonic()
        with self.air.lock:
            t0, d0, u0 = self._cpt
            if t - t0 >= 1.0:
                self.debit = {"DL": (self.air.compte["DL"] - d0) / (t - t0), "UL": (self.air.compte["UL"] - u0) / (t - t0)}
                self._cpt = (t, self.air.compte["DL"], self.air.compte["UL"])
            lot = list(self.air.file[self.sens])
            self.air.file[self.sens].clear()
            autre = "UL" if self.sens == "DL" else "DL"
            lot_autre = list(self.air.file[autre])
            self.air.file[autre].clear()
        if self.onglets.get_current_page() != 0:
            return True                 # the air is only demodulated and drawn while it is looked at
        if not hasattr(self, "iq_sens"):
            self.iq_sens = {"DL": None, "UL": None}     # last burst of each direction, for the I/Q plot
        if not self.gel and lot_autre:
            # the other direction only feeds the I/Q plot (MS above, BTS below): its last burst
            snr = self.s_snr.get_value() if self.c_bruit.get_active() else None
            for fn, tn, bits in reversed(lot_autre[-8:]):
                r = recevoir(bits, snr, self.rng)
                r["fn"], r["tn"] = fn, tn
                if "const" in r or self.iq_sens[autre] is None:
                    self.iq_sens[autre] = r
                    if "const" in r:
                        break
        if not self.gel:
            snr = self.s_snr.get_value() if self.c_bruit.get_active() else None
            # as many bursts per second at both speeds
            for fn, tn, bits in lot[-max(2, int(RAFALES_PAR_S * self.periode / 1000)):]:
                r = recevoir(bits, snr, self.rng)
                r["fn"], r["tn"] = fn, tn
                if "const" in r:
                    self.points.extend(r["const"])
                    self.mesures.append((r["snr"], r["evm"]))
                    self.yeux.append(r["os"].real / max(1e-9, np.max(np.abs(r["os"].real))))
                    self.yeux_n = getattr(self, "yeux_n", 0) + 1
                    self.dernier = r
                elif self.dernier is None:
                    self.dernier = r
            if self.dernier is not None:
                self.iq_sens[self.sens] = self.dernier
            for z in (self.z_const, self.z_oeil, self.z_iq, self.z_corr):
                z.queue_draw()
        self.z_grille.queue_draw()
        d = self.dernier
        snr_m = np.mean([m[0] for m in self.mesures]) if self.mesures else float("nan")
        evm_m = np.mean([m[1] for m in self.mesures]) if self.mesures else float("nan")
        self.l_info.set_text("%s  fn %-7s tn %s  %s%s   SNR %5.1f dB  EVM %5.1f %%   DL %4.0f/s  UL %4.0f/s   %2.0f img/s" % (
            self.sens, d["fn"] if d else "-", d["tn"] if d else "-", d["type"] if d else "-",
            (" TSC%d" % d["tsc"]) if d and d["tsc"] is not None else "", snr_m, evm_m,
            self.debit["DL"], self.debit["UL"], self.cadence_reelle))
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
        n = len(self.points)
        W, H = int(w), int(h)
        if not n or W < 8 or H < 8:
            return
        # 3500 points: written into ONE image with numpy (a rectangle + a fill
        # per point from Python is 20 ms). 2x2 pixels each, the newest brightest,
        # written last (so it wins where points overlap).
        import cairo
        pts = np.fromiter(self.points, complex, n)
        x = np.rint(cx + pts.real * e).astype(np.intp)
        y = np.rint(cy - pts.imag * e).astype(np.intp)
        ok = (x >= 1) & (x < W) & (y >= 1) & (y < H)
        a = (0.15 + 0.85 * np.arange(n) / max(1, n))[:, None]
        coul = np.where((pts.real >= 0)[:, None], (0.48, 0.98, 0.31), (1.0, 0.65, 0.34))    # B, G, R
        px = np.empty((n, 4), np.uint8)
        px[:, :3] = coul * a * 255                                    # premultiplied
        px[:, 3:] = a * 255
        img = np.zeros((H, W, 4), np.uint8)
        x, y, px = x[ok], y[ok], px[ok]
        for dx in (-1, 0):
            for dy in (-1, 0):
                img[y + dy, x + dx] = px
        surf = cairo.ImageSurface.create_for_data(img, cairo.FORMAT_ARGB32, W, H, W * 4)
        cr.set_source_surface(surf, 0, 0)
        cr.paint()
        surf.finish()

    def dessin_oeil(self, cr, w, h):
        cadre(cr, w, h, "diagramme de l'oeil (I, 2 symboles)")
        x0, y0, ww, hh = 10, 26, w - 20, h - 36
        cr.set_source_rgb(*GRILLE)
        cr.move_to(x0, y0 + hh / 2); cr.line_to(x0 + ww, y0 + hh / 2)
        cr.move_to(x0 + ww / 2, y0); cr.line_to(x0 + ww / 2, y0 + hh)
        cr.stroke()
        # A PHOSPHOR LAYER. Redrawing the 30 bursts kept (146 traces of 17
        # points each) at every image costs 0.6 s: the traces are drawn ONCE,
        # into a layer that stays, and each new burst fades the older ones a
        # little - as on an oscilloscope. An image then costs one paint, plus
        # the bursts that arrived since the last one.
        import cairo
        W, H = int(w), int(h)
        if W < 8 or H < 8:
            return
        vus = getattr(self, "yeux_n", len(self.yeux))
        c = getattr(self, "_oeil", None)
        if c is None or c["taille"] != (W, H):
            c = self._oeil = {"taille": (W, H), "surf": cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H), "vus": vus}
            nouveaux = list(self.yeux)                    # new size: everything again, once
        else:
            k = min(vus - c["vus"], len(self.yeux), OEIL_PAR_IMAGE)
            nouveaux = list(self.yeux)[-k:] if k > 0 else []
            c["vus"] = vus
        if nouveaux:
            L = 2 * OS
            lc = cairo.Context(c["surf"])
            lc.set_line_width(1)
            xs = [x0 + ww * j / L for j in range(L + 1)]
            for v in nouveaux:
                lc.set_operator(cairo.OPERATOR_DEST_OUT)
                lc.set_source_rgba(0, 0, 0, OEIL_FONDU)
                lc.paint()
                lc.set_operator(cairo.OPERATOR_OVER)
                lc.set_source_rgba(1.0, 0.69, 0.0, 0.18)
                ys = (y0 + hh / 2 - np.asarray(v) * hh * 0.45).tolist()
                debuts = list(range(OS // 2, len(ys) - L, 2 * OS))       # one symbol out of two
                # 6 strokes per burst: the traces of one stroke do not add up
                # where they cross, those of different strokes do
                for g in range(6):
                    for k in debuts[g::6]:
                        lc.move_to(xs[0], ys[k])
                        for j in range(1, L + 1):
                            lc.line_to(xs[j], ys[k + j])
                    lc.stroke()
        cr.set_source_surface(c["surf"], 0, 0)
        cr.paint()

    def dessin_iq(self, cr, w, h):
        """The two directions at once, both from the MIDDLE line: the MS (uplink)
        above, drawn upwards, the BTS (downlink) below, drawn downwards (mirror).
        A sample in [-1, 1] becomes a height in [0, 1] of its half: -1 on the middle
        line, +1 at the edge. Training sequence shaded in each half.
        ONE burst per direction is shown: it is drawn into a layer, renewed at most
        IQ_HZ times a second (nobody reads 30 different bursts a second, and 4700
        line segments per image is what the plot costs)."""
        import cairo
        W, H = int(w), int(h)
        if W < 8 or H < 8:
            return
        t = time.monotonic()
        c = getattr(self, "_iq", None)
        if c is None or c["taille"] != (W, H) or t - c["t"] >= 1.0 / IQ_HZ:
            if c is None or c["taille"] != (W, H):
                c = self._iq = {"taille": (W, H), "surf": cairo.ImageSurface(cairo.FORMAT_RGB24, W, H)}
            c["t"] = t
            self._dessin_iq(cairo.Context(c["surf"]), w, h)
        cr.set_source_surface(c["surf"], 0, 0)
        cr.paint()

    def _dessin_iq(self, cr, w, h):
        cadre(cr, w, h, "I/Q des rafales (8 ech./symbole) : MS en haut, BTS en bas, depuis le milieu")
        x0, y0, ww, hh = 10, 26, w - 20, h - 36
        mid = y0 + hh / 2
        demi = hh / 2 - 4
        cr.set_source_rgba(1, 1, 1, 0.35)
        cr.set_line_width(1)
        cr.move_to(x0, mid)
        cr.line_to(x0 + ww, mid)
        cr.stroke()
        cr.set_font_size(11)
        for sens, haut, nom in (("UL", True, "MS (montant)"), ("DL", False, "BTS (descendant)")):
            d = getattr(self, "iq_sens", {}).get(sens)
            sgn = -1 if haut else 1
            ty = y0 + 14 if haut else y0 + hh - 4
            cr.set_source_rgb(0.85, 0.85, 0.85)
            cr.move_to(x0 + 4, ty)
            cr.show_text(nom + ("" if not d else "   fn %d tn %d %s" % (d["fn"], d["tn"], d["type"])))
            if not d:
                continue
            if d["tl"]:
                cr.set_source_rgba(1.0, 0.69, 0.0, 0.12)
                cr.rectangle(x0 + ww * d["t0"] / 148, mid if not haut else mid - demi, ww * d["tl"] / 148, demi)
                cr.fill()
            v = d["os"]
            m = max(1e-9, float(np.max(np.abs(np.concatenate((v.real, v.imag))))))
            n = len(v)
            pas = max(1, n // max(1, int(ww)))           # no more points than pixels
            xs = (x0 + ww * np.arange(0, n, pas) / n).tolist()
            for comp, col in ((v.real, (0.31, 0.98, 0.48)), (v.imag, (0.34, 0.65, 1.0))):
                cr.set_source_rgb(*col)
                cr.set_line_width(1.2)
                ys = (mid + sgn * demi * 0.95 * (comp[::pas] / m + 1) / 2).tolist()
                cr.move_to(xs[0], ys[0])
                for X, Y in zip(xs[1:], ys[1:]):
                    cr.line_to(X, Y)
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
        par_couleur = {}                 # one fill per colour, not one per cell
        for tn in range(8):
            cr.set_source_rgb(*TEXTE)
            cr.move_to(8, y0 + tn * ch + ch * 0.7)
            cr.show_text("TS%d" % tn)
            for m in range(51):
                e = gr.get((tn, m))
                coul = couleur(e[0], e[1]) if e and now - e[2] < 2.0 else (0.05, 0.22, 0.26)
                par_couleur.setdefault(coul, []).append((x0 + m * cw + 1, y0 + tn * ch + 1))
        for coul, cases in par_couleur.items():
            cr.set_source_rgb(*coul)
            for X, Y in cases:
                cr.rectangle(X, Y, cw - 2, ch - 2)
            cr.fill()


def main():
    ap = argparse.ArgumentParser(description="constellation : le banc (demarrage, air I/Q, coeur, mobile L23, installation)")
    ap.add_argument("--demo", action="store_true", help="rafales aleatoires, sans la chaine")
    ap.add_argument("--onglet", help="onglet ouvert : Air, Core, L23, Journaux, Kconfig, Tests, Telephones, Trunk SIP, Notebooks, Wiki, Infos, Installation")
    a = ap.parse_args()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    GLib.set_prgname("osmo-ms-pont.py")
    f = Fenetre(a.demo)
    if a.onglet:
        for i in range(f.onglets.get_n_pages()):
            if f.onglets.get_tab_label_text(f.onglets.get_nth_page(i)).lower() == a.onglet.lower():
                f.onglets.get_nth_page(i).show()        # a hidden page cannot become the current one
                f.onglets.set_current_page(i)
    Gtk.main()


if __name__ == "__main__":
    main()
