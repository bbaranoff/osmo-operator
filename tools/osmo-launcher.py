#!/usr/bin/env python3
# osmo-launcher.py - THE BOTTOM LAUNCHER BAR, clickable, by category.
#
# Same window mechanics as osmo-panel.py / osmo-dino.py: a window of DESKTOP
# type (Gdk.WindowTypeHint.DESKTOP - under the application windows, above the
# wallpaper, transparent, sticky, undecorated), placed at the very BOTTOM of
# the screen. It renders, as TRANSPARENT RECTANGLES grouped by category,
# everything that is started from the desktop of the bench:
#
#   Banc      : run standalone · run multi · run deka · Dashboard · tmux · VTY
#   Jeux      : Doom (freedoom) · Quake (OpenArena) · Dino
#   Media     : Kodi · YouTube
#   Telephone : Linphone
#   Outils    : Wireshark (root)
#
# Each application has THREE gestures:
#   - click on the name -> starts the application FITTED ON THE FFT FRAME
#                         (normal window moved/resized on the panel, via wmctrl);
#   - button  ⛶  -> starts in FULL SCREEN;
#   - button  ⤒  -> starts and SENDS TO THE TOP (LAB GSM zone): writes a
#                         command that osmo-topzone.py reads to fade the
#                         banner and host the window.
#
# ── THE "run" ENTRIES DO NOT OPEN A TERMINAL ─────────────────────────────────
# run standalone / run multi / run deka run IN THE BACKGROUND, without
# window: their output goes to a file ($XDG_RUNTIME_DIR/osmo-launcher/<name>.log),
# and the bar UNFOLDS ("▴ journal" button, or automatically on the click on
# a run) to show that log, live, above the buttons. One button per run
# already started switches from one to the other; "▾" folds. Privileges go
# through pkexec (desktop password window), as launch.sh does for the
# actions without terminal.
#
# Placement is done by spotting the NEW window that appeared after the
# launch (diff of the wmctrl ids): robust even for applications that fork
# (firefox, kodi). Started by /usr/local/bin/osmo-desktop-panel.
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

# SAME CONSTRAINT AS osmo-panel.py / osmo-dino.py (see their notes): under
# Wayland, GTK3 ignores move() and the DESKTOP type, and once on XWayland the
# pair DESKTOP type + "always below" makes the GNOME Shell desktop layer eat
# the clicks. X11 backend, normal window.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

TYPE_HINT = Gdk.WindowTypeHint.NORMAL if X11_FORCE else Gdk.WindowTypeHint.DESKTOP
KEEP_BELOW = (not X11_FORCE) or os.environ.get("OSMO_DESKTOP_BELOW") == "1"

FW, FH = 1920, 1080
# The FFT panel (tools/wallpaper-render.py): where an application started
# "in the panel" is fitted. Same box as osmo-panel.py.
FFT_BOX = (510, 220, 900, 790)
# The top LAB GSM zone (card of the wallpaper): the target of "send to the top".
TOP_BOX = (320, 60, 1110, 500)

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
RUN = RUN if os.path.isdir(RUN) else "/tmp"
PID_FILE = os.path.join(RUN, "osmo-launcher.pid")
# The channel to osmo-topzone.py: one line "HOST <winid>" or "HOST FS <winid>".
TOPZONE_CMD = os.path.join(RUN, "osmo-topzone.cmd")
# The logs of the "run" entries: one file per action, overwritten at each launch.
LOG_DIR = os.path.join(RUN, "osmo-launcher")
LOG_H = 300                     # height of the unfolded log, in px
LOG_W_MAX = 1240
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
INFO_PAGE = "file:///usr/share/osmo-operator/info.html"
if not os.path.exists("/usr/share/osmo-operator/info.html"):
    INFO_PAGE = "file://" + os.path.join(REPO, "configs/info.html")

CSS = b"""
.osmo-launch { background: none; background-color: transparent; border: none;
               box-shadow: none; padding: 0; margin: 0; }
/* [2026-10-11] TRANSPARENCE TOTALE : les cadres de categorie n ont plus de fond ;
   textes et boutons portent une ombre pour rester lisibles sur le paysage. */
.osmo-cat { background: rgba(0,0,0,0); border: 1px solid rgba(239,230,210,0.18);
            border-radius: 10px; padding: 4px 8px; margin: 0 4px; }
.osmo-cat > label.title { color: #c9d4ee; font: 8pt "Ubuntu"; text-shadow: 0 1px 2px rgba(0,0,0,0.9); }
.osmo-app button { background: rgba(22,27,34,0.35); color: #e6edf3; text-shadow: 0 1px 2px rgba(0,0,0,0.9);
                   border: 1px solid rgba(88,166,255,0.25); border-radius: 6px;
                   padding: 1px 8px; font: 9pt "Ubuntu"; min-height: 0; }
.osmo-app button:hover { background: rgba(33,38,45,0.85); border-color: #58a6ff; }
.osmo-app button.mini { padding: 1px 5px; color: #a9b7de; font: 8pt "Ubuntu"; }
.osmo-app button.journal { color: #58a6ff; }
.osmo-help { background: #d62828; color: #ffffff; border: 2px solid #ff6b6b; border-radius: 999px;
             font: bold 22pt "Ubuntu"; min-width: 46px; min-height: 46px; padding: 0; margin: 0 6px; }
.osmo-help:hover { background: #ef3b3b; }
.osmo-log { background: rgba(10,12,18,0.93); border: 1px solid rgba(88,166,255,0.35);
            border-radius: 10px; padding: 6px 8px; margin: 0 0 6px 0; }
.osmo-log label.title { color: #58a6ff; font: bold 9pt "Ubuntu"; }
.osmo-log label.state { color: #8b949e; font: 8pt "Ubuntu"; }
.osmo-log button { background: rgba(22,27,34,0.7); color: #e6edf3;
                   border: 1px solid rgba(88,166,255,0.25); border-radius: 6px;
                   padding: 0 7px; font: 8pt "Ubuntu"; min-height: 0; }
.osmo-log button.actif { border-color: #58a6ff; color: #58a6ff; }
.osmo-log textview, .osmo-log textview text { background-color: transparent; color: #d8e0ea;
                   font-family: "Ubuntu Mono"; font-size: 9pt; }
"""


# ── THE SCREEN GEOMETRY (like osmo-panel.py) ─────────────────────────────────
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


# ── wmctrl: PLACE THE NEW WINDOW ─────────────────────────────────────────────
def _wmctrl_ids():
    try:
        out = subprocess.run(["wmctrl", "-l"], capture_output=True, text=True, timeout=3).stdout
        return {ln.split()[0] for ln in out.splitlines() if ln.strip()}
    except Exception:
        return set()


def _place(winid, geom):
    x, y, w, h = geom
    subprocess.run(["wmctrl", "-i", "-r", winid, "-b",
                    "remove,maximized_vert,maximized_horz,fullscreen"], timeout=3)
    subprocess.run(["wmctrl", "-i", "-r", winid, "-e", f"0,{x},{y},{w},{h}"], timeout=3)


def _fullscreen(winid):
    subprocess.run(["wmctrl", "-i", "-r", winid, "-b", "add,fullscreen"], timeout=3)


def spawn(argv):
    return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)


GTK_RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osmo-gtk-run.py")


def _terminal_argv(cmd, titre="Banc GSM"):
    """argv that opens `cmd` (shell string) in a VTE terminal placed INSIDE a
    GTK window of the bench (osmo-gtk-run.py --tty). No terminal emulator:
    no entry of the bar opens one."""
    return [sys.executable, GTK_RUN, "--tty", "--title", titre, "--", "bash", "-lc", cmd]


def _root_prefix():
    """argv prefix to execute as root WITHOUT terminal: nothing if already root,
    pkexec (desktop password window) otherwise, sudo -n as a last resort
    (it cannot ask: without NOPASSWD it fails at once, and the log says so)."""
    if os.geteuid() == 0:
        return []
    if shutil.which("pkexec") and os.environ.get("DISPLAY"):
        return ["pkexec", "env", "DISPLAY=" + os.environ.get("DISPLAY", ""),
                "XAUTHORITY=" + os.environ.get("XAUTHORITY", ""), "NO_COLOR=1", "TERM=dumb"]
    return ["sudo", "-n", "-E"]


LAUNCHER = None     # the window, so that the Actions can hand it a log


class Action:
    """An application: how to start it - window, terminal, or background run with log."""
    def __init__(self, argv=None, term_cmd=None, fs_argv=None, log_cmd=None, root=False, slug=None):
        self.argv = argv          # normal graphical window
        self.term_cmd = term_cmd  # command to open in a terminal
        self.fs_argv = fs_argv    # full screen variant if the application handles it
        self.log_cmd = log_cmd    # shell command in the background, output in a log (no terminal)
        self.root = root          # log_cmd: as root (pkexec)
        self.slug = slug          # name of the log
        self.nom = slug or ""     # the button label (title of the tty window)

    def launch(self, mode):
        """mode: 'frame' (fitted on the panel) | 'full' (full screen) | 'top'."""
        if self.log_cmd is not None:
            if LAUNCHER is not None:
                LAUNCHER.run_logged(self)
            return
        before = _wmctrl_ids()
        if self.term_cmd is not None:
            spawn(_terminal_argv(self.term_cmd, self.nom or "Banc GSM"))
        elif mode == "full" and self.fs_argv:
            spawn(self.fs_argv)
        else:
            spawn(self.argv)
        GLib.timeout_add(400, self._settle, before, mode, 0)

    def _settle(self, before, mode, tries):
        new = _wmctrl_ids() - before
        # our own desktop windows are ignored
        new = {w for w in new}
        if not new:
            if tries < 25:  # ~10 s
                GLib.timeout_add(400, self._settle, before, mode, tries + 1)
            return False
        winid = sorted(new)[-1]
        if mode == "full":
            _fullscreen(winid)
        elif mode == "top":
            try:
                with open(TOPZONE_CMD + ".tmp", "w") as f:
                    f.write("HOST %s\n" % winid)
                os.replace(TOPZONE_CMD + ".tmp", TOPZONE_CMD)
            except OSError:
                _place(winid, box_to_screen(TOP_BOX))
        else:  # frame
            _place(winid, box_to_screen(FFT_BOX))
        return False


# ── THE CATALOGUE ────────────────────────────────────────────────────────────
def _sudo():
    return "" if os.geteuid() == 0 else "sudo -E "


def catalogue():
    tmux = os.environ.get("TMUX_SESSION", "calypso")
    vty = os.environ.get("MS_VTY_PORT", "")
    if not vty:
        try:                      # 4347 with --dsp: start-native.sh publishes the port
            vty = open("/run/osmo-banc/ms1-vty").read().strip() or "4247"
        except OSError:
            vty = "4247"
    dash = os.environ.get("DASH_PORT", "8080")
    browser = "firefox"
    for b in ("firefox", "chromium", "xdg-open"):
        if shutil.which(b):
            browser = b
            break
    # The three "run" entries: in the background, log in the bar (see the header).
    #   standalone : launch.sh --service starts osmo-banc.service and SAYS so
    #                (notification); then the log of the unit is followed.
    #   multi      : launch.sh --multi (osmo-multi.service, several minutes)
    #                IN PARALLEL with the log of the unit, which shows the
    #                containers coming up - run in sequence, the log would only
    #                start at the end of the startup.
    #   deka       : deka-start.sh (installed by addition.sh --opencl), which
    #                already tees into /var/log/deka.log.
    run_standalone = (f"{REPO}/launch.sh --service; echo; "
                      "exec journalctl -u osmo-banc -f -n 40 --no-pager -o cat")
    run_multi = (f"{REPO}/launch.sh --multi & "
                 "journalctl -u osmo-multi -f -n 20 --no-pager -o cat & wait")
    run_deka = ("if [ -x /root/deka/deka-start.sh ]; then exec /root/deka/deka-start.sh; "
                "else echo 'deka non installe : icone « Supplements » (addition.sh --opencl)'; fi")
    return [
        ("Banc", [
            ("run standalone", Action(log_cmd=run_standalone, root=True, slug="standalone")),
            ("run multi",      Action(log_cmd=run_multi, root=True, slug="multi")),
            ("run deka",       Action(log_cmd=run_deka, root=True, slug="deka")),
            ("Dashboard",      Action(argv=[browser, f"http://127.0.0.1:{dash}"])),
            # tmux, VTY, oFono, pmOS: interactive, hence a terminal - VTE, in a GTK
            # window of the bench, which stays open at the end.
            ("tmux",           Action(term_cmd=f"tmux attach -t {tmux} || tmux -S /tmp/osmocom_tmux attach -t osmocom || echo 'pas de session tmux'")),
            (f"VTY {vty}",     Action(term_cmd=f"telnet 127.0.0.1 {vty} || {{ echo; echo 'VTY injoignable'; }}")),
        ]),
        # Doom and Quake are only installed by addition.sh --extras (not in the
        # ISO): an entry only appears if its binary is there.
        ("Jeux", [j for j in [
            ("Doom",   Action(argv=["/usr/games/chocolate-doom", "-iwad", "/usr/share/games/doom/freedoom2.wad", "-window"],
                              fs_argv=["/usr/games/chocolate-doom", "-iwad", "/usr/share/games/doom/freedoom2.wad", "-fullscreen"])),
            ("Quake",  Action(argv=["/usr/games/openarena", "+set", "r_fullscreen", "0"],
                              fs_argv=["/usr/games/openarena", "+set", "r_fullscreen", "1"])),
            ("Dino",   Action(argv=["/usr/local/bin/osmo-dino-play"],
                              fs_argv=["/usr/local/bin/osmo-dino-play", "--fullscreen"])),
        ] if not j[1].argv[0].startswith("/usr/games/") or os.path.exists(j[1].argv[0])]),
        ("Media", [
            ("Kodi",    Action(argv=["kodi"], fs_argv=["kodi", "--fullscreen"])),
            ("YouTube", Action(argv=["/usr/local/bin/osmo-youtube"],
                               fs_argv=["/usr/local/bin/osmo-youtube", "--fullscreen"])),
        ]),
        ("Telephone", [
            ("Linphone", Action(argv=["sh", "-c", "linphone || linphone-desktop"])),
            ("oFono",    Action(term_cmd="/usr/local/bin/osmo-ofono")),
            # The phone of the bench: a postmarketOS/Phosh VM, with its ModemManager
            # plugged on the modem of the bench (tools/osmo-pmos.sh).
            ("pmOS",     Action(term_cmd="/usr/local/bin/osmo-pmos up")),
        ]),
        ("Outils", [
            ("Wireshark", Action(argv=["/usr/local/bin/osmo-wireshark-root"])),
        ]),
    ]


class Launcher(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-launcher")
        (gx, gy, sw, sh), _ = screen_geom()
        self.geo = (gx, gy, sw, sh)
        self.set_type_hint(TYPE_HINT)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_below(KEEP_BELOW)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.connect("draw", self._draw)
        self.connect("destroy", self._quit)

        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        # ── the run logs ───────────────────────────────────────────────────
        self.runs = {}          # slug -> {"proc": Popen|None, "titre": str, "log": path, "bouton": Gtk.Button}
        self.cur = None         # displayed slug
        self._shown = ""        # last text pushed into the view
        self.deplie = False
        os.makedirs(LOG_DIR, exist_ok=True)

        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        col.get_style_context().add_class("osmo-launch")
        col.set_valign(Gtk.Align.END)
        self.revealer = Gtk.Revealer()
        self.revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        self.revealer.set_transition_duration(180)
        self.revealer.add(self._log_box(sw))
        col.pack_start(self.revealer, False, False, 0)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        row.set_halign(Gtk.Align.CENTER)
        row.set_valign(Gtk.Align.END)
        for cat, apps in catalogue():
            row.pack_start(self._cat_box(cat, apps), False, False, 0)
        # The big red "?": the Info page (each module, icon / bar / CLI).
        aide = Gtk.Button(label="?")
        aide.get_style_context().add_class("osmo-help")
        aide.set_valign(Gtk.Align.CENTER)
        aide.set_tooltip_text("Info : comment lancer chaque module (icone, barre, CLI)")
        aide.connect("clicked", lambda *_a: spawn(["xdg-open", INFO_PAGE]))
        row.pack_end(aide, False, False, 0)
        col.pack_start(row, False, False, 0)
        self.add(col)

        # bottom band, full width, ~72 px; unfolded: + the log
        self.h = 74
        self._taille(self.h)
        self.show_all()
        self._taille(self.h)
        GLib.timeout_add(700, self._refresh_log)

    def _taille(self, h):
        gx, gy, sw, sh = self.geo
        self.set_size_request(sw, h)
        self.resize(sw, h)
        self.move(gx, gy + sh - h)

    def _draw(self, _w, cr):
        import cairo
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        return False

    def _quit(self, *_a):
        self.stop_runs()
        Gtk.main_quit()

    # ── the log: the box above the buttons ────────────────────────────────
    def _log_box(self, sw):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.get_style_context().add_class("osmo-log")
        box.set_halign(Gtk.Align.CENTER)
        box.set_size_request(min(sw - 60, LOG_W_MAX), LOG_H)
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.lbl_titre = Gtk.Label(label="journal")
        self.lbl_titre.get_style_context().add_class("title")
        self.lbl_etat = Gtk.Label(label="")
        self.lbl_etat.get_style_context().add_class("state")
        head.pack_start(self.lbl_titre, False, False, 0)
        head.pack_start(self.lbl_etat, False, False, 0)
        self.onglets = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        head.pack_end(self._bouton("▾ replier", self.replier), False, False, 0)
        b_stop = self._bouton("■ stop", self._stop_courant)
        b_stop.set_tooltip_text("arrete la commande en cours (pas le banc : launch.sh --stop)")
        head.pack_end(b_stop, False, False, 0)
        head.pack_end(self.onglets, False, False, 0)
        box.pack_start(head, False, False, 0)
        sc = Gtk.ScrolledWindow()
        sc.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.tv = Gtk.TextView()
        self.tv.set_editable(False)
        self.tv.set_cursor_visible(False)
        self.tv.set_monospace(True)
        self.tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.tv.set_left_margin(6)
        self.tv.set_right_margin(6)
        sc.add(self.tv)
        box.pack_start(sc, True, True, 0)
        return box

    @staticmethod
    def _bouton(label, cb):
        b = Gtk.Button(label=label)
        b.connect("clicked", lambda *_a: cb())
        return b

    def deplier(self, slug=None):
        if slug:
            self.cur = slug
            for s, r in self.runs.items():
                ctx = r["bouton"].get_style_context()
                (ctx.add_class if s == slug else ctx.remove_class)("actif")
            self.lbl_titre.set_text("journal : " + self.runs[slug]["titre"])
            self._shown = ""
        if not self.deplie:
            self.deplie = True
            self._taille(self.h + LOG_H + 10)
            self.revealer.set_reveal_child(True)
        self._refresh_log()

    def replier(self):
        if not self.deplie:
            return
        self.deplie = False
        self.revealer.set_reveal_child(False)
        GLib.timeout_add(200, lambda: (self._taille(self.h), False)[1])

    def basculer(self):
        if self.deplie:
            self.replier()
        elif self.runs:
            self.deplier(self.cur or next(iter(self.runs)))
        else:
            self.lbl_titre.set_text("journal : aucun run lance")
            self.deplier()

    # ── start a run in the background ──────────────────────────────────────
    def run_logged(self, action):
        slug = action.slug or re.sub(r"\W+", "-", action.log_cmd)[:24]
        log = os.path.join(LOG_DIR, slug + ".log")
        r = self.runs.get(slug)
        if r is None:
            b = self._bouton(slug, lambda s=slug: self.deplier(s))
            self.onglets.pack_start(b, False, False, 0)
            b.show()
            r = self.runs[slug] = {"proc": None, "titre": slug, "log": log, "bouton": b}
        self._stop(r)
        # 2G (standalone) or 4G (multi): the antenna rises in the wallpaper from
        # the click on (tools/osmo-fond.py, fade) - osmo-panel.py does the same
        # when it sees the bench up, without effect if it already is.
        if slug in ("standalone", "multi"):
            fond = os.path.join(REPO, "tools", "osmo-fond.py")
            if os.path.exists(fond):
                spawn([sys.executable, fond, "antenne"])
        argv = (_root_prefix() if action.root else []) + ["bash", "-lc", action.log_cmd]
        env = dict(os.environ, NO_COLOR="1", TERM="dumb")
        try:
            fh = open(log, "w")
            fh.write("$ %s\n" % action.log_cmd)
            fh.flush()
            r["proc"] = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=fh, stderr=subprocess.STDOUT,
                                         start_new_session=True, env=env)
            fh.close()
        except OSError as e:
            with open(log, "a") as fh:
                fh.write("lancement impossible : %s\n" % e)
        self.deplier(slug)

    @staticmethod
    def _stop(r):
        p = r.get("proc")
        if p is None or p.poll() is not None:
            r["proc"] = None
            return
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
        r["proc"] = None

    def _stop_courant(self):
        if self.cur and self.cur in self.runs:
            self._stop(self.runs[self.cur])
            with open(self.runs[self.cur]["log"], "a") as fh:
                fh.write("\n[stop]\n")

    def stop_runs(self):
        for r in self.runs.values():
            self._stop(r)

    def _refresh_log(self):
        if not self.deplie or not self.cur or self.cur not in self.runs:
            return True
        r = self.runs[self.cur]
        p = r.get("proc")
        if p is not None and p.poll() is not None:
            self.lbl_etat.set_text("termine (statut %d)" % p.returncode)
        elif p is not None:
            self.lbl_etat.set_text("en cours ...")
        else:
            self.lbl_etat.set_text("")
        try:
            with open(r["log"], "rb") as fh:
                fh.seek(0, os.SEEK_END)
                taille = fh.tell()
                fh.seek(max(0, taille - 48 * 1024))
                data = fh.read().decode("utf-8", "replace")
        except OSError:
            data = ""
        data = ANSI.sub("", data)
        if data != self._shown:
            self._shown = data
            buf = self.tv.get_buffer()
            buf.set_text(data)
            fin = buf.get_end_iter()
            self.tv.scroll_to_iter(fin, 0.0, False, 0.0, 1.0)
        return True

    # ── the buttons ────────────────────────────────────────────────────────
    def _cat_box(self, cat, apps):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.get_style_context().add_class("osmo-cat")
        lbl = Gtk.Label(label=cat)
        lbl.get_style_context().add_class("title")
        lbl.set_halign(Gtk.Align.START)
        box.pack_start(lbl, False, False, 0)
        approw = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)
        for name, action in apps:
            approw.pack_start(self._app_widget(name, action), False, False, 0)
        if cat == "Banc":
            wrap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
            wrap.get_style_context().add_class("osmo-app")
            bj = Gtk.Button(label="▴ journal")
            bj.get_style_context().add_class("journal")
            bj.set_tooltip_text("deplie / replie le journal des run")
            bj.connect("clicked", lambda *_a: self.basculer())
            wrap.pack_start(bj, False, False, 0)
            approw.pack_start(wrap, False, False, 0)
        box.pack_start(approw, False, False, 0)
        return box

    def _app_widget(self, name, action):
        wrap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        wrap.get_style_context().add_class("osmo-app")
        b = Gtk.Button(label=name)
        action.nom = name
        b.connect("clicked", lambda *_a: action.launch("frame"))
        wrap.pack_start(b, False, False, 0)
        if action.log_cmd is not None:
            # a run has no window to fit nor to send to the top: a single button
            b.set_tooltip_text(f"{name} - en fond, journal dans la barre")
            return wrap
        b.set_tooltip_text(f"{name} - clic: cale sur le cadre")
        # ⛶ full screen
        bf = Gtk.Button(label="⛶")
        bf.get_style_context().add_class("mini")
        bf.set_tooltip_text("plein ecran")
        bf.connect("clicked", lambda *_a: action.launch("full"))
        wrap.pack_start(bf, False, False, 0)
        # ⤒ send to the top (LAB GSM zone)
        bt = Gtk.Button(label="⤒")
        bt.get_style_context().add_class("mini")
        bt.set_tooltip_text("envoyer en haut (zone LAB GSM)")
        bt.connect("clicked", lambda *_a: action.launch("top"))
        wrap.pack_start(bt, False, False, 0)
        return wrap


def single_instance():
    try:
        old = int(open(PID_FILE).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM)
            time.sleep(0.3)
    except (OSError, ValueError):
        pass
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError as e:
        print("osmo-launcher : verrou %s non ecrit (%s)" % (PID_FILE, e), file=sys.stderr)


if __name__ == "__main__":
    single_instance()
    LAUNCHER = Launcher()
    # SIGTERM (restart by the desktop guardian, single_instance): the
    # journalctl -f started in the background must not outlive the bar.
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda *_a: (LAUNCHER._quit(), False)[1])
    Gtk.main()
