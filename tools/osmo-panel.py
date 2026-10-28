#!/usr/bin/env python3
# osmo-panel.py - the LIVE PANEL of the desktop, clickable version.
#
# A GTK window of type DESKTOP (the same mechanism as Ubuntu's DING icons:
# below every window, above the background, and it receives clicks - which
# Conky cannot do), placed EXACTLY on the Calvin & Hobbes frame of the
# wallpaper (tools/wallpaper-render.py: box 510,220-1410,1010 in 1920x1080),
# scaled to the screen. It shows /run/osmo-fft/panel.png
# (tools/osmo-fft-snap.py: the strip of the day fading to « mobile FFT +
# mobile.log » once the bench is ready) and, at the bottom, a small menu:
#
#   [ Dashboard ]  firefox http://<operator>:8080
#   [ tmux ]       a terminal attached to the bench session
#   [ VTY 4247 ]   a terminal on telnet 127.0.0.1 4247 (mobile console)
#   [ ZMQ ]        the state of the srsRAN virtual radio (ZeroMQ): green when
#                  the entry points listen, grey otherwise. A click opens a
#                  terminal showing who listens and who is connected.
#   IP 192.168.x.y the address of THIS machine on the network - the one to
#                  write into a srsRAN running elsewhere, or to give to
#                  another bench node. A click copies it to the clipboard.
#   [ < ] op 2/3 [ > ]   ONLY in multi-operator: moves from one operator to
#                  the next. The choice is written to /run/osmo-fft/operator;
#                  the FFT render (osmo-fft-snap.py) and the Conky at the top
#                  right (conky-osmo-status.sh) read it and follow.
#
# Multi-operator = /etc/osmocom/osmo-multi.conf (addition.sh) AND at least one
# osmo-operator-N container running (docker ps). Without that: no arrows.
#
# Launched by the osmo-conky.desktop autostart (with the osmo-conky.conf Conky).
#
# THE PANEL IS ONLY THERE WHEN A BENCH RUNS. Bench down, the window is HIDDEN
# (not merely transparent: the button bar would sit in the middle of an empty
# desktop). It appears as soon as a 2G (native osmo-bsc, an osmo-operator-N
# container, the hub) or a 4G (open5gs-mmed, srsenb, srsue) is up, and goes
# away when everything stops. The process itself stays: osmo-desktop-panel
# counts it as alive and does not start a second one. OSMO_PANEL_TOUJOURS=1
# keeps it on screen whatever happens.
import os
import re
import shlex
import signal
import socket
import shutil
import subprocess
import sys
import threading
import time

import cairo
# THE DESKTOP WINDOW REQUIRES X11, NOT WAYLAND.
# Under Wayland, GTK3 ignores window.move() AND Gdk.WindowTypeHint.DESKTOP:
# the compositor places the window where it wants (centred, in front). The
# protocol gives the client no way to sit at absolute coordinates (it would
# take gtk-layer-shell, absent on mutter). So go through XWayland, where X11
# positioning is honoured, exactly like the neighbouring Conky (own_window
# type desktop). Only forced when a DISPLAY exists: without an X server, the
# default behaviour is better than a failure at startup.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402

# AND THEN THE DESKTOP TYPE NO LONGER WORKS. On XWayland, a
# _NET_WM_WINDOW_TYPE_DESKTOP window is put by GNOME Shell in the desktop
# layer, BELOW the fullscreen icon window (DING extension) - which swallows
# every click: the panel would show but its buttons would not respond. So a
# NORMAL window is kept, simply held below the others (keep_below + stick +
# out of the taskbar): same rendering, and the clicks arrive. On native X11
# (the live key) the DESKTOP type works and is kept.
TYPE_HINT = Gdk.WindowTypeHint.NORMAL if X11_FORCE else Gdk.WindowTypeHint.DESKTOP
# ... AND NEITHER DOES « BELOW ». Second half of the same trap: with
# _NET_WM_STATE_BELOW, GNOME Shell puts the XWayland window under its own
# desktop layer (native Wayland), which is fullscreen and takes every click -
# the window stays visible but fully inert. Under XWayland « always below »
# is therefore given up: ordinary window, sticky and out of the taskbar. It
# comes to the front when clicked, which is the price for being clickable at
# all. OSMO_DESKTOP_BELOW=1 restores the window-below-everything behaviour
# (clicks lost); on native X11 nothing changes.
KEEP_BELOW = (not X11_FORCE) or os.environ.get("OSMO_DESKTOP_BELOW") == "1"

RUN = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
IMG = os.path.join(RUN, "panel.png")
OP_FILE = os.path.join(RUN, "operator")
# THE INSTANCE LOCK IS PER SESSION, NOT PER MACHINE. /run/osmo-fft is created
# root:root by systemd (RuntimeDirectory of osmo-fft-snap.service) and is not
# writable by the desktop user of an installed system. XDG_RUNTIME_DIR
# (/run/user/<uid>) belongs to the user, and one panel per session is exactly
# what is to be counted.
_RUNDIR = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
PID_FILE = os.path.join(_RUNDIR if os.path.isdir(_RUNDIR) else RUN, "osmo-panel.pid")
ETAT_FILE = os.path.join(_RUNDIR if os.path.isdir(_RUNDIR) else RUN, "osmo-banc.etat")
REPO_DIR = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
MULTI_CONF = os.environ.get("MULTI_CONF", "/etc/osmocom/osmo-multi.conf")
TMUX_SESSION = os.environ.get("TMUX_SESSION", "calypso")
DASH_PORT = int(os.environ.get("DASH_PORT", "8080"))
# The VTY of the mobile client (osmocom-bb « mobile »). 4247 for MS#1; MS#2 is
# on 4248 - see start-native.sh, which assigns them.
# 4247, or 4347 in --dsp: start-native.sh publishes the actual port in
# /run/osmo-banc/ms1-vty. MS_VTY_PORT forces it; else the file; else 4247.
def vty_port():
    if os.environ.get("MS_VTY_PORT"):
        return int(os.environ["MS_VTY_PORT"])
    try:
        with open("/run/osmo-banc/ms1-vty") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 4247


VTY_PORT = vty_port()
# The panel box in the wallpaper (1920x1080): x, y, width, height.
# 790 high: two halves (4G on top, 2G at the bottom), see
# tools/osmo-fft-snap.py. The four files that know it must stay in agreement
# (list in tools/wallpaper-render.py).
BOX = (510, 220, 900, 790)
FW, FH = 1920, 1080

# THE BAR HAS NO BACKGROUND. The footer is already painted by
# osmo-fft-snap.py; a second background behind the buttons would show a
# visible edge across the panel footer. The buttons have their own background
# (`.osmo-bar button`) and stand out well enough on their own.
CSS = b"""
/* `background-color: transparent` IS NOT ENOUGH. Adwaita does not only paint
   a colour on a box: it sets a `background-image` (a gradient), plus a border
   and a shadow. Neutralising the colour alone leaves the image - a lighter
   band behind the buttons, over the footer painted by osmo-fft-snap.py. All
   four are switched off.
   `background: none` MUST come before `background-color`, otherwise the
   shorthand property puts the default colour back afterwards. */
.osmo-bar { background: none; background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; margin: 0; }
.osmo-bar button { background: #161b22; color: #e6edf3; border: 1px solid #30363d;
                   border-radius: 6px; padding: 1px 8px; font: 9pt "DejaVu Sans Mono"; min-height: 0; }
.osmo-bar button:hover { background: #21262d; border-color: #58a6ff; }
.osmo-bar button.arrow { font: 15pt "DejaVu Sans Mono"; font-weight: bold;
                         padding: 0 14px; min-width: 34px; color: #3fb950; }
.osmo-bar button.arrow:hover { border-color: #ff9a3c; color: #ff9a3c; }
.osmo-bar label { color: #8b949e; font: 9pt "DejaVu Sans Mono"; }
.osmo-bar label.op { color: #3fb950; font-weight: bold; font-size: 11pt; }
/* The virtual radio: green when it listens, grey when it is down.
   The colour IS the information - it is what one reads at a glance. */
.osmo-bar button.zmq-on  { color: #3fb950; border-color: #238636; }
.osmo-bar button.zmq-off { color: #6e7681; }
.osmo-bar label.ip { color: #58a6ff; font-weight: bold; }
"""


# ── THE GEOMETRY: WHERE THE FRAME IS ON THIS SCREEN ─────────────────────────
def geometry():
    """(x, y, w, h) of the strip frame on screen, according to the wallpaper
    display mode (zoom = cover and crop, scaled = contain, stretched)."""
    disp = Gdk.Display.get_default()
    mon = disp.get_primary_monitor() or disp.get_monitor(0)
    g = mon.get_geometry()
    sw, sh = g.width, g.height
    try:
        mode = Gio.Settings.new("org.gnome.desktop.background").get_string("picture-options")
    except Exception:
        mode = "zoom"
    if mode == "stretched":
        sx, sy, ox, oy = sw / FW, sh / FH, 0, 0
    else:
        s = min(sw / FW, sh / FH) if mode == "scaled" else max(sw / FW, sh / FH)
        sx = sy = s
        ox, oy = (FW * s - sw) / 2, (FH * s - sh) / 2
    bx, by, bw, bh = BOX
    return (g.x + int(bx * sx - ox), g.y + int(by * sy - oy), int(bw * sx), int(bh * sy)), (sw, sh, mode)


# ── THE OPERATORS ───────────────────────────────────────────────────────────
# STOPPED OPERATORS COUNT TOO. The screen must be able to settle on a stopped
# operator - that is precisely when it is needed for diagnosis. So the WHOLE
# topology is returned, with the state (up) next to each entry, and the panel
# footer reads "op 3/3 arrete" instead of hiding the button.
# ON THE OTHER HAND, NO ARROWS OUTSIDE MULTI-OPERATOR. Without
# /etc/osmocom/osmo-multi.conf - a single-operator bench - there is nothing
# to navigate to: the list returns the native one only, and update_op() hides
# the arrows. No operators 2 and 3 are invented.
# Same list and same rule as tools/osmo-op.sh, the command-line version (and
# the reference definition).


M3UA_PORT = int(os.environ.get("MULTI_M3UA_PORT", "2908"))

# ── THE srsRAN VIRTUAL RADIO (ZeroMQ) ───────────────────────────────────────
# srsRAN without hardware: the « zmq » driver replaces the radio card with two
# ZeroMQ sockets - one carries the samples from the station to the mobile,
# the other from the mobile to the station (tcp://IP:2000 and :2001 by
# default). The bench uses it to give the phone a REAL radio layer: srsUE
# attaches to the station, and the phone modem (postmarketOS, via
# tools/osmo-pmos.sh) talks to that mobile.
# NOTHING about the state is guessed: look at who listens on those ports.
ZMQ_PORTS = [int(x) for x in os.environ.get("OSMO_ZMQ_PORTS", "2000,2001").split(",") if x.strip()]


def _sctp_ecoute(port):
    """Does an SCTP socket listen on this port? Direct read of
    /proc/net/sctp/eps - no privilege, and `ss` may not be installed."""
    try:
        with open("/proc/net/sctp/eps") as f:
            for line in f.readlines()[1:]:
                ch = line.split()
                # LPORT column: the 5th field in the kernel format.
                if len(ch) > 4 and ch[4] == str(port):
                    return True
    except OSError:
        pass
    try:
        out = subprocess.run(["ss", "-an"], capture_output=True, text=True, timeout=3).stdout
        return any(l.startswith("sctp") and f":{port}" in l for l in out.splitlines())
    except Exception:
        return False


def _tcp_ecoute(port):
    """Does a TCP socket listen on this port? /proc/net/tcp{,6} is read
    directly: no privilege, and `ss` may be missing. The 4th column is
    « 0A » (TCP_LISTEN) and the local address is « HEX:PORT »."""
    hexport = "%04X" % port
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(f) as fh:
                for line in fh.readlines()[1:]:
                    ch = line.split()
                    if len(ch) > 3 and ch[3] == "0A" and ch[1].endswith(":" + hexport):
                        return True
        except OSError:
            continue
    return False


def zmq_etat():
    """(active, detail) of the srsRAN virtual radio.

    Active = at least one of the ZeroMQ ports listens. The detail names those
    that listen: on a half-started bench (station launched, mobile not yet),
    it is the only way to see which of the two is missing.
    """
    ouverts = [p for p in ZMQ_PORTS if _tcp_ecoute(p)]
    if not ouverts:
        return False, "aucun point d entree ZeroMQ (srsRAN arrete)"
    manque = [p for p in ZMQ_PORTS if p not in ouverts]
    detail = "ecoute : " + ", ".join(str(p) for p in ouverts)
    if manque:
        detail += " ; MANQUE : " + ", ".join(str(p) for p in manque)
    return True, detail


def ip_locale():
    """The address of this machine on the network - the one given to others.

    « ip route get » names the interface carrying the default route without
    sending a single packet: it is the right answer even with no network at
    the other end, and it does not depend on a hard-coded interface name.
    """
    try:
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"],
                             capture_output=True, text=True, timeout=2).stdout
        m = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    # No default route (isolated bench): the first non-local address.
    try:
        out = subprocess.run(["ip", "-4", "-br", "addr"], capture_output=True,
                             text=True, timeout=2).stdout
        for ligne in out.splitlines():
            m = re.search(r"(\d+\.\d+\.\d+\.\d+)/", ligne)
            if m and not m.group(1).startswith("127."):
                return m.group(1)
    except Exception:
        pass
    return "127.0.0.1"


def ip_toutes():
    """All the addresses, for the tooltip: a bench has several (the network,
    the docker bridges, apn0...) and the one that matters depends on who is
    asking."""
    try:
        out = subprocess.run(["ip", "-4", "-br", "addr"], capture_output=True,
                             text=True, timeout=2).stdout.strip()
        return out or "aucune adresse"
    except Exception:
        return "adresses illisibles"


def operators():
    """List [(idx, mode, ip, up)]: the whole topology, running or not."""
    ops = []
    try:
        with open(MULTI_CONF) as f:
            txt = f.read()
    except OSError:
        txt = ""
    m = re.search(r'^MULTI_OPS="?([^"\n]*)"?', txt, re.M)
    specs = m.group(1).split() if m else []
    if not specs:
        # No multi-operator topology: a single operator, the native one.
        # update_op() will hide the arrows - there is nowhere to go.
        specs = ["1:native:"]
    # `docker ps` FAILS UNDER THE SESSION ACCOUNT if it is not in the `docker`
    # group ("permission denied ... /var/run/docker.sock"). « absent » and
    # « invisible » are not confused: when docker does not answer, the
    # operator's dashboard is probed instead, which needs no privilege. Same
    # rule as tools/osmo-op.sh.
    running = set()
    docker_ok = False
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True,
                           text=True, timeout=5)
        docker_ok = r.returncode == 0
        running = set(r.stdout.split())
    except Exception:
        docker_ok = False

    def reachable(ip):
        if not ip:
            return False
        try:
            with socket.create_connection((ip, DASH_PORT), timeout=0.4):
                return True
        except OSError:
            return False

    for spec in specs:
        parts = spec.split(":")
        if len(parts) < 3:
            continue
        idx, mode, ip = parts[0], parts[1], parts[2]
        if mode == "native":
            up = subprocess.run(["pgrep", "-x", "osmo-bsc"], capture_output=True).returncode == 0
        elif docker_ok:
            up = f"osmo-operator-{idx}" in running
        else:
            up = reachable(ip)
        ops.append((idx, mode, ip, up))
    if not any(o[1] == "native" for o in ops):
        ops.insert(0, ("1", "native", "", False))
    # ── THE HUB IS THE LAST STOP OF THE CYCLE ───────────────────────────────
    # The node that links the operators is the one queried when SS7 goes
    # wrong. The panel renders it as an SS7 view (connectivity matrix + hub
    # log) and not as a spectrum: an M3UA hub has no radio, an FFT would mean
    # nothing there. See tools/osmo-fft-snap.py, render_interstp().
    # Same rule as tools/osmo-op.sh, the reference definition.
    if specs and any(o[1] == "docker" for o in ops):
        hub_ip = ""
        m = re.search(r'^MULTI_HUB_IP="?([^"\s#]*)', txt, re.M)
        if m:
            hub_ip = m.group(1)
        hub = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
        # THE HUB HAS NO DASHBOARD: the inter-STP only routes M3UA, so the
        # `reachable()` fallback on :8080 would say nothing. Without docker
        # access, look at what it REALLY listens on: an SCTP socket on the
        # M3UA port. A TCP probe is mute there (it is SCTP), hence the read
        # of /proc/net/sctp.
        up = hub in running if docker_ok else _sctp_ecoute(M3UA_PORT)
        ops.append(("hub", "interstp", hub_ip or "172.20.0.10", up))
    return ops


# ── IS THERE A BENCH TO SHOW? ───────────────────────────────────────────────
# 2G: an operator of the topology running (native, container or hub - the
# operators() list, which already knows). 4G: one of the daemons the Conky
# looks at to say « 4G up » (tools/conky-osmo-status.sh, lte) - same names,
# same rule. `pgrep -x`: the exact NAME, not the command line (a
# `tail -F srsue.log` or this panel itself do not count).
LTE_DEMONS = os.environ.get("OSMO_LTE_DEMONS", "open5gs-mmed|srsenb|srsue")
PANEL_TOUJOURS = os.environ.get("OSMO_PANEL_TOUJOURS") == "1"


def lte_actif():
    try:
        out = subprocess.run(["pgrep", "-x", LTE_DEMONS], capture_output=True,
                             text=True, timeout=5).stdout.split()
    except Exception:
        return False
    # pgrep also lists ZOMBIES (a crashed srsue not yet reaped by its parent):
    # a dead process holds no bench, it is not counted.
    for pid in out:
        try:
            with open(f"/proc/{pid}/stat") as f:
                if f.read().rsplit(")", 1)[1].split()[0] != "Z":
                    return True
        except (OSError, IndexError):
            return True       # unreadable: assume alive rather than hiding a bench
    return False


def banc_actif(ops):
    """True if a 2G (an operator or the hub running) or a 4G is running."""
    return PANEL_TOUJOURS or any(o[3] for o in ops) or lte_actif()


# ── THE FILE IS THE SHARED SOURCE, NOT AN OUTPUT ────────────────────────────
# The keyboard shortcut, `osmo-op --next` and other sessions change
# /run/osmo-fft/operator too. The panel therefore READS it, and only WRITES
# it on a click of its own arrows - rewriting it on every refresh would
# cancel a choice made elsewhere.
def read_operator():
    """The selected operator, whoever selected it (panel arrows, keyboard
    shortcut, `osmo-op`). None if the file does not exist."""
    try:
        with open(OP_FILE) as f:
            for line in f:
                if line.startswith("OP="):
                    return line[3:].strip() or None
    except OSError:
        pass
    return None


def write_operator(op):
    idx, mode, ip = op[0], op[1], op[2]
    # NAME is the CONTAINER name: it is how osmo-fft-snap.py and the Conky get
    # in (docker exec). For the hub it is not « osmo-operator-hub » - that
    # container does not exist - but osmo-inter-stp. Same rule as
    # tools/osmo-op.sh.
    nom = (os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp") if mode == "interstp"
           else f"osmo-operator-{idx}")
    os.makedirs(RUN, exist_ok=True)
    tmp = OP_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"OP={idx}\nMODE={mode}\nIP={ip}\nNAME={nom}\n"
                f"DASH=http://{ip or '127.0.0.1'}:{DASH_PORT}\n")
    os.replace(tmp, OP_FILE)


def spawn(argv):
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def terminal(cmd, titre="osmo-panel"):
    """Opens `cmd` (shell string) in a VTE terminal placed INSIDE a bench GTK
    window (tools/osmo-gtk-run.py --tty). No terminal emulator is involved:
    no panel entry opens one."""
    root = "" if os.geteuid() == 0 else "sudo -E "
    gtk_run = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osmo-gtk-run.py")
    spawn([sys.executable, gtk_run, "--tty", "--title", titre, "--", "bash", "-c", root + cmd])


class Panel(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-panel (osmo-egprs)")
        (x, y, w, h), (sw, sh, mode) = geometry()
        print(f"[panel] ecran {sw}x{sh} ({mode}) : encart a {x},{y} {w}x{h}", flush=True)
        self.geo = (x, y, w, h)
        self.set_type_hint(TYPE_HINT)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_below(KEEP_BELOW)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        self.set_default_size(w, h)
        self.set_size_request(w, h)
        self.move(x, y)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.image = Gtk.Image()
        overlay = Gtk.Overlay()
        overlay.add(self.image)

        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        bar.get_style_context().add_class("osmo-bar")
        bar.set_halign(Gtk.Align.END)
        bar.set_valign(Gtk.Align.END)
        scale = w / BOX[2]
        bar.set_margin_end(int(18 * scale))
        bar.set_margin_bottom(int(14 * scale))
        b_dash = self.b_dash = Gtk.Button(label="Dashboard")
        b_dash.set_tooltip_text("firefox sur le tableau de bord de l operateur choisi")
        b_dash.connect("clicked", self.on_dash)
        b_tmux = self.b_tmux = Gtk.Button(label="tmux")
        b_tmux.set_tooltip_text("terminal attache a la session du banc (Ctrl-b d pour detacher)")
        b_tmux.connect("clicked", self.on_tmux)
        # The mobile VTY: the console where one types « show ms »,
        # « call 100102 »... the third place opened by hand ten times a session.
        b_vty = self.b_vty = Gtk.Button(label=f"VTY {VTY_PORT}")
        b_vty.set_tooltip_text(f"terminal : telnet 127.0.0.1 {VTY_PORT} (console du mobile)")
        b_vty.connect("clicked", self.on_vty)
        # The srsRAN virtual radio, and the machine address. Both answer the
        # same question - « where do I plug the phone? ».
        b_zmq = self.b_zmq = Gtk.Button(label="ZMQ")
        b_zmq.connect("clicked", self.on_zmq)
        self.l_ip = Gtk.Label(label="IP —")
        self.l_ip.get_style_context().add_class("ip")
        # A label does not receive clicks: wrap it in an event box.
        ip_box = Gtk.EventBox()
        ip_box.add(self.l_ip)
        ip_box.connect("button-press-event", self.on_ip)
        ip_box.set_tooltip_text("l adresse de cette machine - un clic la copie")
        self.ip_box = ip_box

        self.b_prev = Gtk.Button(label="◀")
        self.b_next = Gtk.Button(label="▶")
        self.b_prev.get_style_context().add_class("arrow")
        self.b_next.get_style_context().add_class("arrow")
        self.b_prev.set_tooltip_text("operateur precedent (op1, op2 ...)")
        self.b_next.set_tooltip_text("operateur suivant (op1, op2 ...)")
        self.b_prev.connect("clicked", self.on_prev)
        self.b_next.connect("clicked", self.on_next)
        self.l_op = Gtk.Label(label="")
        self.l_op.get_style_context().add_class("op")
        for wdg in (b_dash, b_tmux, b_vty, b_zmq, ip_box,
                    self.b_prev, self.l_op, self.b_next):
            bar.pack_start(wdg, False, False, 0)
        overlay.add_overlay(bar)
        self.add(overlay)

        self.ops = []
        self.cur = 0
        self.mtime = None
        self._pos = (x, y)
        self.connect("map-event", self._pin)
        # The children are shown, the WINDOW only if a bench runs
        # (refresh_ops, below): a show_all() here would flash it on screen
        # for a second before hiding it.
        overlay.show_all()
        self.update_op()          # show_all showed everything: re-hide the arrows outside multi
        # None: unknown state - the first refresh_ops writes the bench state
        # (wallpaper, state file) even when it is « stopped ».
        self._visible = None
        self.refresh_ops()
        self.refresh_image()
        GLib.timeout_add(1000, self.refresh_image)
        GLib.timeout_add(2000, self.refresh_ops)
        self.refresh_zmq()
        GLib.timeout_add(3000, self.refresh_zmq)

    # ── show / hide according to the bench ─────────────────────────────────
    def montrer(self, actif):
        if actif == self._visible:
            return
        self._visible = actif
        self._etat_banc(actif)
        if actif:
            print("[panel] un banc tourne : encart a l ecran", flush=True)
            self.show()
            self._pin()
            GLib.timeout_add(500, self._pin)
        else:
            print("[panel] plus de banc : encart cache", flush=True)
            self.hide()

    # THE DESKTOP FOLLOWS THE BENCH, NOT ONLY THE PANEL. At the same moment:
    # (1) the wallpaper fades from the city alone to the city with the
    # antenna (tools/osmo-fond.py), and back when stopped; (2) the state is
    # written to $XDG_RUNTIME_DIR/osmo-banc.etat ("1"/"0"), which
    # osmo-topzone.py reads to fade the « Telecom Operator » title to the LAB
    # GSM banner. osmo-launcher.py also launches the wallpaper on the CLICK
    # of a run (earlier than the detection here); osmo-fond is idempotent,
    # both coexist.
    def _etat_banc(self, actif):
        try:
            with open(ETAT_FILE + ".tmp", "w") as f:
                f.write("1\n" if actif else "0\n")
            os.replace(ETAT_FILE + ".tmp", ETAT_FILE)
        except OSError as e:
            print("[panel] etat du banc non ecrit : %s" % e, flush=True)
        fond = os.path.join(REPO_DIR, "tools", "osmo-fond.py")
        if os.path.exists(fond):
            spawn([sys.executable, fond, "antenne" if actif else "ville"])
        self._conky_fondu(actif)

    # THE CONKY FOLLOWS TOO, WITH A FADE. Bench down, the dashboard has
    # nothing to say (« banc a l arret - ./start-native.sh » twice): it is
    # faded out, and comes back with the bench. No kill: the osmo-desktop-panel
    # guardian would restart a conky within five seconds. Its X11 WINDOW is
    # acted on instead: opacity (_NET_WM_WINDOW_OPACITY, honoured by mutter)
    # going down in a dozen steps, then unmap (xdotool); on return, map then
    # the opacity goes back up. Without xdotool, opacity 0 is enough to hide
    # it. The conky may be restarted meanwhile (new window): _conky_veille
    # puts the window back in the wanted state on every refresh_ops round.
    def _conky_fenetre(self):
        try:
            out = subprocess.run(["xdotool", "search", "--classname", "^conky$"],
                                 capture_output=True, text=True, timeout=3).stdout.split()
        except (OSError, subprocess.TimeoutExpired):
            out = []
        if not out:
            try:
                for l in subprocess.run(["wmctrl", "-lx"], capture_output=True, text=True, timeout=3).stdout.splitlines():
                    f = l.split()
                    if len(f) > 2 and f[2].lower().startswith("conky."):
                        out.append(str(int(f[0], 16)))
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
        return out[0] if out else None

    @staticmethod
    def _conky_opacite(win, v):
        subprocess.run(["xprop", "-id", win, "-f", "_NET_WM_WINDOW_OPACITY", "32c",
                        "-set", "_NET_WM_WINDOW_OPACITY", str(int(max(0.0, min(1.0, v)) * 0xFFFFFFFF))],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)

    def _conky_fondu(self, actif, pas=12, duree=1.2):
        if os.environ.get("OSMO_CONKY_TOUJOURS") == "1":
            return
        win = self._conky_fenetre()
        self._conky_voulu = actif
        if not win:
            return
        xdo = shutil.which("xdotool")

        def anim():
            try:
                if actif:
                    self._conky_opacite(win, 0.0)
                    if xdo:
                        subprocess.run([xdo, "windowmap", win], timeout=3)
                    for i in range(1, pas + 1):
                        self._conky_opacite(win, i / pas)
                        time.sleep(duree / pas)
                    subprocess.run(["xprop", "-id", win, "-remove", "_NET_WM_WINDOW_OPACITY"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                else:
                    for i in range(pas - 1, -1, -1):
                        self._conky_opacite(win, i / pas)
                        time.sleep(duree / pas)
                    if xdo:
                        subprocess.run([xdo, "windowunmap", win], timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                pass
            self._conky_win = win
        threading.Thread(target=anim, daemon=True).start()

    # A fade killed in flight would leave the wallpaper on an intermediate
    # image. Every 10 s the wallpaper URI is reread: if it is not the file
    # expected for the current state, osmo-fond is relaunched (idempotent, it
    # resumes from the image it was at).
    def _fond_veille(self):
        if self._visible is None or os.environ.get("OSMO_FOND_TOUJOURS") == "1":
            return
        t = time.monotonic()
        if t - getattr(self, "_fond_t", 0) < 10:
            return
        self._fond_t = t
        attendu = "gsm-lab-antenne.jpg" if self._visible else "gsm-lab-ville.jpg"
        try:
            uri = subprocess.run(["gsettings", "get", "org.gnome.desktop.background", "picture-uri"],
                                 capture_output=True, text=True, timeout=5).stdout.strip().strip("'")
        except (OSError, subprocess.TimeoutExpired):
            return
        if uri.endswith("/" + attendu) or "/osmo-fond/" not in uri and "gsm-lab-" not in uri:
            return          # in place, or a wallpaper chosen by the user: left alone
        fond = os.path.join(REPO_DIR, "tools", "osmo-fond.py")
        if os.path.exists(fond):
            print("[panel] fond d ecran a reprendre : %s" % os.path.basename(uri), flush=True)
            spawn([sys.executable, fond, "antenne" if self._visible else "ville"])

    def _conky_veille(self):
        # a conky restarted (other window) while the bench is down: hide it at
        # once; and if it vanished then reappeared on return, show it
        voulu = getattr(self, "_conky_voulu", None)
        if voulu is None or voulu or os.environ.get("OSMO_CONKY_TOUJOURS") == "1":
            return
        win = self._conky_fenetre()
        if not win:
            return
        # the X id may be REUSED by a restarted conky: look at the actual
        # window state, not only its number
        try:
            mappee = "IsViewable" in subprocess.run(["xwininfo", "-id", win], capture_output=True,
                                                   text=True, timeout=3).stdout
        except (OSError, subprocess.TimeoutExpired):
            mappee = False
        if win != getattr(self, "_conky_win", None) or (mappee and shutil.which("xdotool")):
            self._conky_fondu(False, pas=1, duree=0)

    # RE-PLACE AFTERWARDS. Even under X11, the window manager may move the
    # window when it maps it (mutter does so for undecorated windows it does
    # not recognise as desktop). A single move() before show_all() does not
    # hold: re-place on map-event, then one last time half a second later.
    def _pin(self, *_a):
        self.move(*self._pos)
        return False
    def on_draw(self, _w, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        return False

    # ── the image ──────────────────────────────────────────────────────────
    def refresh_image(self):
        try:
            mt = os.stat(IMG).st_mtime
        except OSError:
            return True
        if mt == self.mtime:
            return True
        self.mtime = mt
        _, _, w, h = self.geo
        try:
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(IMG, w, h, False)
            self.image.set_from_pixbuf(pb)
        except GLib.Error:
            pass  # file being written: next second
        return True

    # ── the operators ──────────────────────────────────────────────────────
    def refresh_ops(self):
        ops = operators()
        changed = ops != self.ops
        if changed:
            sel = self.ops[self.cur] if self.ops and self.cur < len(self.ops) else None
            self.ops = ops
            self.cur = next((i for i, o in enumerate(ops) if sel and o[0] == sel[0]), 0)
        # Did someone else choose? (keyboard shortcut, `osmo-op`, another
        # session). If so, follow it - without rewriting the file.
        want = read_operator()
        if want is not None:
            i = next((i for i, o in enumerate(self.ops) if o[0] == want), None)
            if i is not None and i != self.cur:
                self.cur = i
                changed = True
        if changed:
            self.update_op(write=(want is None))
        self.montrer(banc_actif(self.ops))
        self._conky_veille()
        self._fond_veille()
        return True

    def update_op(self, write=True):
        global VTY_PORT
        # The arrows are ALWAYS there as soon as the topology has more than
        # one operator - running or not (see operators()). A stopped operator
        # is said in the label, it does not make the button disappear.
        multi = len(self.ops) > 1
        for wdg in (self.b_prev, self.b_next, self.l_op):
            wdg.set_visible(multi)
        if self.ops:
            op = self.ops[self.cur]
            etat = "" if op[3] else " arrete"
            libelle = "inter-STP" if op[1] == "interstp" else f"op {op[0]}/{len(self.ops)}"
            self.l_op.set_text(f"{libelle}{etat}")
            self.l_op.set_tooltip_text(
                "\n".join(f"op {o[0]} {o[1]} {o[2] or '(hote)'} "
                           f"{'actif' if o[3] else 'arrete'}" for o in self.ops))
            # The three buttons target the selected operator: they SAY so in
            # their label, so pushing the arrows shows which operator they
            # will land on.
            hub = op[1] == "interstp"
            suff = (" hub" if hub else f" op{op[0]}") if len(self.ops) > 1 else ""
            if hub:
                cible = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            elif op[1] == "docker":
                cible = f"osmo-operator-{op[0]}"
            else:
                cible = f"{op[2] or '127.0.0.1'}"
            self.b_dash.set_label("Dashboard" + suff)
            self.b_dash.set_tooltip_text(f"firefox http://{op[2] or '127.0.0.1'}:{DASH_PORT} ({cible})")
            self.b_tmux.set_label("tmux" + suff)
            self.b_tmux.set_tooltip_text(f"terminal sur la session tmux de {cible}")
            VTY_PORT = vty_port()
            self.b_vty.set_label(f"VTY {VTY_PORT}" + suff)
            self.b_vty.set_tooltip_text(f"terminal : telnet 127.0.0.1 {VTY_PORT} dans {cible}")
            # `write=False` when only FOLLOWING the file: rewriting it
            # identically is useless, and rewriting it with our own idea would
            # cancel a choice made at the keyboard.
            if write:
                write_operator(op)

    def on_prev(self, *_):
        if self.ops:
            self.cur = (self.cur - 1) % len(self.ops)
            self.update_op()

    def on_next(self, *_):
        if self.ops:
            self.cur = (self.cur + 1) % len(self.ops)
            self.update_op()

    # ── the virtual radio and the address, refreshed with the rest ─────────
    def refresh_zmq(self):
        actif, detail = zmq_etat()
        ctx = self.b_zmq.get_style_context()
        ctx.remove_class("zmq-on" if not actif else "zmq-off")
        ctx.add_class("zmq-on" if actif else "zmq-off")
        self.b_zmq.set_label("ZMQ" if actif else "ZMQ ○")
        self.b_zmq.set_tooltip_text("radio virtuelle srsRAN (ZeroMQ)\n%s\nun clic : qui ecoute, qui est connecte" % detail)
        ip = ip_locale()
        self.l_ip.set_text("IP %s" % ip)
        self.l_ip.set_tooltip_text("adresse de cette machine (un clic la copie)\n\n%s" % ip_toutes())
        return True

    def on_zmq(self, *_):
        ports = "|".join(str(p) for p in ZMQ_PORTS)
        # ss first (it names the process), netstat as fallback.
        cmd = (f"echo 'Radio virtuelle srsRAN (ZeroMQ) - ports {', '.join(str(p) for p in ZMQ_PORTS)}'; echo;"
               f" (ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep -E ':({ports})\\b' || echo 'personne n ecoute';"
               f" echo; echo 'connexions etablies :';"
               f" (ss -ntp 2>/dev/null || netstat -ntp 2>/dev/null) | grep -E ':({ports})\\b' || echo 'aucune';"
               f" echo; echo 'processus srsRAN :'; pgrep -a 'srsenb|srsue|srsepc|gnb|srsran' || echo 'aucun';"
               f" echo; read -n1 -rsp 'touche pour fermer...'")
        terminal(cmd)

    def on_ip(self, *_):
        """Copy the address: that is what it is for nine times out of ten -
        pasting it into a srsRAN configuration file or on another host."""
        ip = ip_locale()
        try:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(ip, -1)
            self.l_ip.set_text("IP %s ✓" % ip)
            GLib.timeout_add(1200, lambda: (self.l_ip.set_text("IP %s" % ip), False)[1])
        except Exception:
            pass
        return True

    # ── the buttons ────────────────────────────────────────────────────────
    def on_dash(self, *_):
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
        url = f"http://{op[2] or '127.0.0.1'}:{DASH_PORT}"
        for browser in ("firefox", "chromium", "xdg-open"):
            if subprocess.run(["which", browser], capture_output=True).returncode == 0:
                spawn([browser, url])
                return

    def on_vty(self, *_):
        # telnet, not nc: it is what the Osmocom documentation gives, and the
        # VTY expects a real line-by-line terminal. The final `read` keeps the
        # window open when the port is closed - otherwise it would close
        # before the reason could be read.
        #
        # A CONTAINER'S VTY IS INSIDE THE CONTAINER: the port is NOT published
        # on the operator's docker network (start-docker.sh only publishes
        # what the host needs). So enter the container, exactly as for tmux.
        VTY_PORT = vty_port()
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
        if op[1] == "interstp":
            # The hub has neither mobile nor VTY 4247: its console is the STP (4239).
            c = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            cmd = (f"docker exec -it {c} telnet 127.0.0.1 4239"
                   f" || {{ echo; echo 'VTY 4239 injoignable dans {c} (hub arrete ?)'; read -r _; }}")
        elif op[1] == "docker":
            c = f"osmo-operator-{op[0]}"
            cmd = (f"docker exec -it {c} telnet 127.0.0.1 {VTY_PORT}"
                   f" || {{ echo; echo 'VTY {VTY_PORT} injoignable dans {c} (operateur arrete ?)';"
                   f" read -r _; }}")
        else:
            cmd = (f"telnet 127.0.0.1 {VTY_PORT}"
                   f" || {{ echo; echo 'VTY 127.0.0.1:{VTY_PORT} injoignable - banc arrete ?'; read -r _; }}")
        terminal(cmd)

    def on_tmux(self, *_):
        # start-docker.sh opens a session named « osmo » on the DEFAULT socket
        # in the container ("docker exec -ti osmo-operator-2 tmux attach -t
        # osmo"); the « osmocom » session on /tmp/osmocom_tmux is the other
        # layout. Both are tried, in order, before concluding.
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
        if op[1] == "interstp":
            c = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            cmd = (f"docker exec -it {c} bash"
                   f" || {{ echo; echo 'hub {c} injoignable'; read -r _; }}")
        elif op[1] == "docker":
            c = f"osmo-operator-{op[0]}"
            cmd = (f"docker exec -it {c} tmux attach -t osmo"
                   f" || docker exec -it {c} tmux -S /tmp/osmocom_tmux attach -t osmocom"
                   f" || docker exec -it {c} tmux attach"
                   f" || {{ echo; echo 'pas de session tmux dans {c} (operateur arrete ?)';"
                   f" echo 'docker ps -a --filter name={c}'; read -r _; }}")
        else:
            cmd = (f"tmux attach -t {TMUX_SESSION}"
                   f" || tmux -S /tmp/osmocom_tmux attach -t osmocom"
                   f" || {{ echo; echo 'pas de session tmux « {TMUX_SESSION} » - banc arrete ?'; read -r _; }}")
        terminal(cmd)


def single_instance():
    try:
        old = int(open(PID_FILE).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM)
            time.sleep(0.3)
    except (OSError, ValueError):
        pass
    # A lock that cannot be written is no reason not to show the panel: at
    # worst two windows, never a crash dialog.
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError as e:
        print("osmo-panel : verrou %s non ecrit (%s)" % (PID_FILE, e), file=sys.stderr)


if __name__ == "__main__":
    single_instance()
    Panel()
    Gtk.main()
