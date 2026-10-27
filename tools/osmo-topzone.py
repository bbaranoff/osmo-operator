#!/usr/bin/env python3
# osmo-topzone.py - THE TOP "LAB GSM" ZONE, live and clickable.
#
# Replaces the LAB GSM card formerly BAKED into the wallpaper
# (tools/wallpaper-render.py, run with OSMO_LIVE_BANNER=1 so that it does not
# draw it). It is a window of DESKTOP type (like osmo-panel.py) placed EXACTLY
# on the box of the card (320,60 .. 1430,560 in 1920x1080), which displays
# configs/conky/labgsm.html through WebKit.
#
# TWO ROLES:
#   1. IDLE (nothing hosted): the banner animates its 8 timeslots. It reads
#      $OSMO_FFT_DIR/timeslots.json (written by tools/osmo-ts-probe.py: osmo-bsc
#      config + VTY) and makes any timeslot carrying bursts BLINK IN ORANGE -
#      a TCH only blinks when there is voice. ARFCN / IMSI / A5 are the LIVE
#      values. The burst chronogram flickers with the activity.
#   2. HOSTING: when osmo-launcher.py sends an application "to the top", it
#      writes "HOST <winid>" in $XDG_RUNTIME_DIR/osmo-topzone.cmd. The banner
#      is then FADED and the application window is placed on the zone. A small
#      bar above (always in front) carries a close CROSS and a FULL SCREEN /
#      TOP RECTANGLE toggle.
import json
import os
import subprocess
import sys
import time

# SAME CONSTRAINT AS osmo-panel.py / osmo-dino.py (see their notes): under
# Wayland, GTK3 ignores move() and the DESKTOP type; once on XWayland,
# "always below" makes the GNOME Shell desktop layer swallow the clicks.
# X11 backend, normal window.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

# THE BANNER STAYS AT THE BACK. Unlike the panel and the launcher, it is
# WANTED stuck to the desktop, behind everything: it is a decoration, not a
# control panel. On XWayland this costs the clicks (GNOME Shell puts DESKTOP
# type windows under its icons layer, which swallows them) - so window
# hosting in the top zone does not respond to the mouse. That is the choice
# made here; OSMO_TOPZONE_CLIQUABLE=1 to get a normal window back (in front,
# but clickable) when it is needed.
_CLIQUABLE = os.environ.get("OSMO_TOPZONE_CLIQUABLE") == "1"
TYPE_HINT = Gdk.WindowTypeHint.NORMAL if _CLIQUABLE else Gdk.WindowTypeHint.DESKTOP
KEEP_BELOW = not _CLIQUABLE

FW, FH = 1920, 1080
# THE EMPTY BOTTOM IS REMOVED, NOT THE CONTENT.
# The box (1110x500, i.e. 1644x740 on the bench screen) is much taller than
# what the card fills; the page is written in vh/vw units (#card is
# height:100%, titles 8.5vh, labels 1.3vh...), so shortening the window or
# zooming the view to 0.5 would SHRINK the whole content.
# What is done: the page is rendered AT ITS ORIGINAL SIZE (the vh keep the
# reference height below, so the content is unchanged), the frame stops after
# its content (injected CSS: #card becomes height:auto), and the window is
# fitted to the height really occupied, measured IN the page once loaded.
# No empty space, and not one pixel of content lost.
TOP_BOX = (320, 60, 1110, 500)          # LAB GSM card (x,y,w,h) - the RENDERING
# The stylesheet that cuts the empty space. Note: #card is in
# "position:absolute; inset:0" - it is not a height that stretches it but its
# bottom:0. Setting height:auto changes NOTHING as long as the bottom is not
# released; both are needed.
INJECT_CSS = "#card{bottom:auto!important;height:auto!important}"
REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HTML = os.environ.get("OSMO_LABGSM_HTML", os.path.join(REPO, "configs/conky/labgsm.html"))
FFT_RUN = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")


# ── WHERE TO READ: THE SAME RULE AS THE PROBE, RE-EVALUATED ON EVERY TURN ───
# The SAME rule on both sides (tools/osmo-ts-probe.py, run_dir()), word for
# word: the first directory that exists and is writable, among $OSMO_FFT_DIR
# and /tmp - re-evaluated on every read, because /run/osmo-fft is a
# RuntimeDirectory that comes and goes with its service.
def ts_json():
    for d in (FFT_RUN, "/tmp"):
        if os.path.isdir(d) and os.access(d, os.W_OK):
            return os.path.join(d, "timeslots.json")
    return "/tmp/timeslots.json"
RUN = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
CMD_FILE = os.path.join(RUN if os.path.isdir(RUN) else "/tmp", "osmo-topzone.cmd")
# THE BENCH STATE, WRITTEN BY osmo-panel.py ("1": a 2G or a 4G is running,
# "0": nothing). Bench stopped, the banner fades and the zone only carries the
# "Telecom Operator" title; when the 2G starts, the title fades into the
# banner (labgsm.html, osmoBanc). File absent: idle.
ETAT_FILE = os.path.join(RUN if os.path.isdir(RUN) else "/tmp", "osmo-banc.etat")


def banc_etat():
    try:
        return open(ETAT_FILE).read().strip() == "1"
    except OSError:
        return False


def screen_geom():
    disp = Gdk.Display.get_default()
    mon = disp.get_primary_monitor() or disp.get_monitor(0)
    g = mon.get_geometry()
    sw, sh = g.width, g.height
    try:
        from gi.repository import Gio
        mode = Gio.Settings.new("org.gnome.desktop.background").get_string("picture-options")
    except Exception:
        mode = "zoom"
    if mode == "stretched":
        sx, sy, ox, oy = sw / FW, sh / FH, 0, 0
    else:
        s = min(sw / FW, sh / FH) if mode == "scaled" else max(sw / FW, sh / FH)
        sx = sy = s
        ox, oy = (FW * s - sw) / 2, (FH * s - sh) / 2
    return (g.x, g.y, sw, sh), (sx, sy, ox, oy)


def box_to_screen(box):
    (gx, gy, sw, sh), (sx, sy, ox, oy) = screen_geom()
    bx, by, bw, bh = box
    return (gx + int(bx * sx - ox), gy + int(by * sy - oy), int(bw * sx), int(bh * sy))


def _place(winid, geom):
    x, y, w, h = geom
    subprocess.run(["wmctrl", "-i", "-r", winid, "-b",
                    "remove,maximized_vert,maximized_horz,fullscreen"], timeout=3)
    subprocess.run(["wmctrl", "-i", "-r", winid, "-e", f"0,{x},{y},{w},{h}"], timeout=3)


def _fullscreen(winid, on=True):
    subprocess.run(["wmctrl", "-i", "-r", winid, "-b",
                    ("add" if on else "remove") + ",fullscreen"], timeout=3)


def _close_win(winid):
    subprocess.run(["wmctrl", "-i", "-c", winid], timeout=3)


class Strip(Gtk.Window):
    """Control bar ALWAYS IN FRONT (cross + full screen toggle)."""
    def __init__(self, on_close, on_toggle):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_accept_focus(False)
        prov = Gtk.CssProvider()
        prov.load_from_data(b".strip{background:rgba(19,16,24,0);border-radius:8px}"
                            b".strip button{color:#efe6d2;background:rgba(40,34,52,.5);text-shadow:0 1px 2px rgba(0,0,0,.9);"
                            b"border:1px solid rgba(239,230,210,.25);border-radius:6px;"
                            b"margin:2px;padding:0 8px;font:11pt 'DejaVu Sans Mono'}"
                            b".strip button:hover{border-color:#ff9a3c}")
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        box.get_style_context().add_class("strip")
        self.b_mode = Gtk.Button(label="⛶")
        self.b_mode.set_tooltip_text("plein écran / rectangle haut")
        self.b_mode.connect("clicked", lambda *_a: on_toggle())
        b_close = Gtk.Button(label="✕")
        b_close.set_tooltip_text("fermer et rendre la bannière")
        b_close.connect("clicked", lambda *_a: on_close())
        box.pack_start(self.b_mode, False, False, 0)
        box.pack_start(b_close, False, False, 0)
        self.add(box)

    def show_at(self, x, y):
        self.show_all()
        self.set_keep_above(True)
        self.move(x, y)


class TopZone(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-topzone")
        x, y, w, h = box_to_screen(TOP_BOX)
        self.box_geo = (x, y, w, h)
        self.hosted = None       # winid of the hosted application
        self.fs = False          # full screen mode of the hosted application
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
        self.connect("destroy", Gtk.main_quit)

        ucm = WebKit2.UserContentManager()
        ucm.add_style_sheet(WebKit2.UserStyleSheet(
            INJECT_CSS, WebKit2.UserContentInjectedFrames.ALL_FRAMES,
            WebKit2.UserStyleLevel.USER, None, None))
        self.view = WebKit2.WebView.new_with_user_content_manager(ucm)
        # Once the page is loaded, it is asked for the height the card REALLY
        # occupies and the window is fitted to it.
        self.view.connect("load-changed", self.on_load)
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        self.add(self.view)
        if os.path.exists(HTML):
            self.view.load_uri(GLib.filename_to_uri(HTML, None))
        else:
            self.view.load_html("<h1 style='color:#fff;font-family:sans-serif'>labgsm.html introuvable</h1>", None)

        self.strip = Strip(self.on_close, self.on_toggle)

        self._cmd_mtime = None
        self._etat_mtime = None
        self._etat = False           # what the page shows: False = the title
        self.show_all()
        self.move(x, y)
        # The file is looked at five times per second and the state is pushed
        # ONLY if it changed: reactive, and no useless JS.
        self._ts_mtime = None
        GLib.timeout_add(200, self.push_state)
        GLib.timeout_add(500, self.poll_cmd)

    # ── fit the window to the useful height ─────────────────────────────────
    def on_load(self, _view, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        # the bench state as it is, WITHOUT fade (the page starts "idle")
        self._banc(banc_etat(), instant=True)
        # A hair of margin under the frame, otherwise the bottom border grazes
        # the edge of the window.
        self.view.run_javascript(
            "(function(){var c=document.getElementById('card')||document.body;"
            "return Math.ceil(c.getBoundingClientRect().bottom)+2;})()",
            None, self.on_height, None)

    def on_height(self, view, res, _data):
        try:
            val = view.run_javascript_finish(res).get_js_value().to_double()
        except Exception as e:                      # page replaced, JS cut...
            print("[topzone] hauteur non mesuree : %s" % e, file=sys.stderr, flush=True)
            return
        h = int(val)
        x, y, w, h_full = self.box_geo
        if not (0 < h < h_full):                    # absurd measurement: everything is kept
            print("[topzone] hauteur mesuree %d ignoree (fenetre %d)" % (h, h_full),
                  file=sys.stderr, flush=True)
            return
        print("[topzone] hauteur utile %d px (au lieu de %d)" % (h, h_full), flush=True)
        self.box_geo = (x, y, w, h)
        self.set_size_request(w, h)
        self.resize(w, h)
        self.move(x, y)

    # ── idle: push the timeslot state into the page ──────────────────────────
    def push_state(self):
        chemin = ts_json()
        try:
            mt = (chemin, os.stat(chemin).st_mtime)
        except OSError:
            mt = None
        if mt is not None and mt == self._ts_mtime:
            return True                      # nothing new since the last turn
        self._ts_mtime = mt
        try:
            with open(chemin) as f:
                state = f.read().strip()
        except OSError:
            state = ""
        if state:
            js = "window.__osmoLive=true; if(window.osmoUpdate){osmoUpdate(%s);}" % state
            try:
                self.view.run_javascript(js, None, None, None)
            except Exception:
                pass
        return True

    def _fade(self, on):
        try:
            self.view.run_javascript("if(window.osmoFade)osmoFade(%s);" % ("true" if on else "false"),
                                     None, None, None)
        except Exception:
            pass

    # ── "Telecom Operator" title (idle) <-> banner (bench up) ──────────────────
    def _banc(self, on, instant=False):
        self._etat = on
        try:
            self.view.run_javascript("if(window.osmoBanc)osmoBanc(%s,%s);"
                                     % ("true" if on else "false", "true" if instant else "false"),
                                     None, None, None)
        except Exception:
            pass

    def poll_etat(self):
        try:
            mt = os.stat(ETAT_FILE).st_mtime
        except OSError:
            mt = None
        if mt == self._etat_mtime:
            return
        self._etat_mtime = mt
        on = banc_etat()
        if on != self._etat:
            print("[topzone] %s" % ("un banc tourne : banniere" if on else "banc a l arret : titre"), flush=True)
            self._banc(on)

    # ── hosting: read the osmo-launcher -> osmo-topzone channel ──────────────
    def poll_cmd(self):
        self.poll_etat()
        try:
            mt = os.stat(CMD_FILE).st_mtime
        except OSError:
            return True
        if mt == self._cmd_mtime:
            return True
        self._cmd_mtime = mt
        try:
            line = open(CMD_FILE).read().strip()
        except OSError:
            return True
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "HOST":
            self.host(parts[-1], full=("FS" in parts))
        return True

    def host(self, winid, full=False):
        self.hosted = winid
        self.fs = full
        self._fade(True)
        x, y, w, h = self.box_geo
        if full:
            _fullscreen(winid, True)
        else:
            _place(winid, self.box_geo)
        # the control bar, in the top-right corner of the zone
        self.strip.b_mode.set_label("▭" if full else "⛶")
        self.strip.show_at(x + w - 74, max(0, y - 2))

    def on_toggle(self):
        if not self.hosted:
            return
        self.fs = not self.fs
        if self.fs:
            _fullscreen(self.hosted, True)
            self.strip.b_mode.set_label("▭")
        else:
            _place(self.hosted, self.box_geo)
            self.strip.b_mode.set_label("⛶")
        x, y, w, h = self.box_geo
        self.strip.show_at(x + w - 74, max(0, y - 2))

    def on_close(self):
        if self.hosted:
            _close_win(self.hosted)
        self.hosted = None
        self.fs = False
        self.strip.hide()
        self._fade(False)


if __name__ == "__main__":
    TopZone()
    Gtk.main()
