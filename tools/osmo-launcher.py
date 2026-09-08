#!/usr/bin/env python3
# osmo-launcher.py - LA BARRE DE LANCEMENT DU BAS, cliquable, categorisee.
#
# Meme mecanique de fenetre que osmo-panel.py / osmo-dino.py : une fenetre de
# type BUREAU (Gdk.WindowTypeHint.DESKTOP - sous les fenetres applicatives,
# au-dessus du fond, transparente, collante, non decoree), posee tout en BAS de
# l ecran. Elle rend, en RECTANGLES TRANSPARENTS groupes par categorie, tout ce
# qu on lance depuis le bureau du banc :
#
#   Banc      : run standalone · run multi · run deka · Dashboard · tmux · VTY
#   Jeux      : Doom · Quake · OpenRA · Dino
#   Media     : Kodi · YouTube
#   Telephone : Linphone
#   Outils    : Wireshark (root)
#
# Chaque appli a TROIS gestes :
#   - clic sur le nom  -> lance l appli CALEE SUR LE CADRE FFT (fenetre normale
#                         deplacee/redimensionnee sur l encart, via wmctrl) ;
#   - bouton  ⛶  -> lance en PLEIN ECRAN ;
#   - bouton  ⤒  -> lance et ENVOIE EN HAUT (zone LAB GSM) : ecrit une
#                         commande que osmo-topzone.py lit pour faire le fondu de
#                         la banniere et accueillir la fenetre.
#
# Le placement se fait en reperant la NOUVELLE fenetre apparue apres le
# lancement (diff des ids wmctrl) : robuste meme pour les applis qui forkent
# (firefox, kodi). Lance par /usr/local/bin/osmo-desktop-panel.
import os
import shlex
import signal
import subprocess
import sys
import time

# [2026-09-06] MEME PIEGE QUE osmo-panel.py / osmo-dino.py (voir leurs notes) :
# sous Wayland, GTK3 ignore move() et le type BUREAU, et une fois passe par
# XWayland le couple type BUREAU + « toujours dessous » fait manger les clics
# par la couche de bureau de GNOME Shell. Backend X11, fenetre normale.
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
# L encart FFT (tools/wallpaper-render.py) : c est la que se cale une appli
# lancee "dans le panel". Meme boite que osmo-panel.py.
FFT_BOX = (510, 220, 900, 790)
# La zone haute LAB GSM (carte du fond) : la cible de "envoyer en haut".
TOP_BOX = (320, 60, 1110, 500)

RUN = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
PID_FILE = os.path.join(RUN if os.path.isdir(RUN) else "/tmp", "osmo-launcher.pid")
# Le canal vers osmo-topzone.py : une ligne "HOST <winid>" ou "HOST FS <winid>".
TOPZONE_CMD = os.path.join(RUN if os.path.isdir(RUN) else "/tmp", "osmo-topzone.cmd")

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")

CSS = b"""
.osmo-launch { background: none; background-color: transparent; border: none;
               box-shadow: none; padding: 0; margin: 0; }
.osmo-cat { background: rgba(19,16,24,0.42); border: 1px solid rgba(239,230,210,0.18);
            border-radius: 10px; padding: 4px 8px; margin: 0 4px; }
.osmo-cat > label.title { color: #a9b7de; font: 8pt "DejaVu Sans Mono"; }
.osmo-app button { background: rgba(22,27,34,0.55); color: #e6edf3;
                   border: 1px solid rgba(88,166,255,0.25); border-radius: 6px;
                   padding: 1px 8px; font: 9pt "DejaVu Sans Mono"; min-height: 0; }
.osmo-app button:hover { background: rgba(33,38,45,0.85); border-color: #58a6ff; }
.osmo-app button.mini { padding: 1px 5px; color: #a9b7de; font: 8pt "DejaVu Sans Mono"; }
"""


# ── LA GEOMETRIE DE L ECRAN (comme osmo-panel.py) ────────────────────────────
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


# ── wmctrl : PLACER LA NOUVELLE FENETRE ──────────────────────────────────────
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


def _terminal_argv(cmd):
    """argv d un emulateur de terminal executant `cmd` (chaine shell)."""
    for term, opt in (("gnome-terminal", "--"), ("xfce4-terminal", "-e"),
                      ("konsole", "-e"), ("x-terminal-emulator", "-e"), ("xterm", "-e")):
        if subprocess.run(["which", term], capture_output=True).returncode == 0:
            if term == "gnome-terminal":
                return [term, "--", "bash", "-lc", cmd]
            return [term, opt, "bash -lc " + shlex.quote(cmd)]
    return ["xterm", "-e", "bash -lc " + shlex.quote(cmd)]


class Action:
    """Une appli : comment la lancer, et si c est un terminal."""
    def __init__(self, argv=None, term_cmd=None, fs_argv=None):
        self.argv = argv          # fenetre graphique normale
        self.term_cmd = term_cmd  # commande a ouvrir dans un terminal
        self.fs_argv = fs_argv    # variante plein ecran si l appli la gere

    def launch(self, mode):
        """mode: 'frame' (cale sur l encart) | 'full' (plein ecran) | 'top'."""
        before = _wmctrl_ids()
        if self.term_cmd is not None:
            spawn(_terminal_argv(self.term_cmd))
        elif mode == "full" and self.fs_argv:
            spawn(self.fs_argv)
        else:
            spawn(self.argv)
        GLib.timeout_add(400, self._settle, before, mode, 0)

    def _settle(self, before, mode, tries):
        new = _wmctrl_ids() - before
        # on ignore nos propres fenetres bureau
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


# ── LE CATALOGUE ─────────────────────────────────────────────────────────────
def _sudo():
    return "" if os.geteuid() == 0 else "sudo -E "


def catalogue():
    tmux = os.environ.get("TMUX_SESSION", "calypso")
    vty = os.environ.get("MS_VTY_PORT", "4247")
    dash = os.environ.get("DASH_PORT", "8080")
    browser = "firefox"
    for b in ("firefox", "chromium", "xdg-open"):
        if subprocess.run(["which", b], capture_output=True).returncode == 0:
            browser = b
            break
    return [
        ("Banc", [
            ("run standalone", Action(term_cmd=f"{_sudo()}{REPO}/start-direct.sh; echo; read -n1 -rsp 'fin - touche...'")),
            # [2026-09-07] PAR L UNITE, comme l icone du bureau. Cette entree
            # lancait start-multi.sh EN DIRECT : le banc multi partait alors
            # hors de systemd, sans journal ni etat, et un `systemctl stop` ne
            # le voyait pas. launch.sh --multi demarre osmo-multi.service, dit
            # ce qui manque quand une condition de l unite n est pas remplie
            # (topologie absente = unite sautee en silence), et on deroule le
            # journal derriere - c est lui qui montre le demarrage.
            ("run multi",      Action(term_cmd=f"{_sudo()}{REPO}/launch.sh --multi; echo; {_sudo()}journalctl -u osmo-multi -n 40 --no-pager 2>/dev/null; echo; read -n1 -rsp 'fin - touche...'")),
            ("run deka",       Action(term_cmd="/usr/local/bin/osmo-deka-anim || { echo 'deka non installe (supplement OpenCL)'; read -n1 -rsp 'touche...'; }")),
            ("Dashboard",      Action(argv=[browser, f"http://127.0.0.1:{dash}"])),
            ("tmux",           Action(term_cmd=f"tmux attach -t {tmux} || tmux -S /tmp/osmocom_tmux attach -t osmocom || {{ echo 'pas de session tmux'; read -n1 -rsp 'touche...'; }}")),
            (f"VTY {vty}",     Action(term_cmd=f"telnet 127.0.0.1 {vty} || {{ echo; echo 'VTY injoignable'; read -n1 -rsp 'touche...'; }}")),
        ]),
        ("Jeux", [
            ("Doom",   Action(argv=["sh", "-c", "gzdoom -iwad /usr/share/games/doom/freedoom2.wad 2>/dev/null || gzdoom || freedoom2 || freedoom"],
                              fs_argv=["sh", "-c", "gzdoom -fullscreen -iwad /usr/share/games/doom/freedoom2.wad 2>/dev/null || gzdoom -fullscreen || freedoom2"])),
            ("Quake",  Action(argv=["quakespasm"], fs_argv=["quakespasm", "-fullscreen"])),
            ("OpenRA", Action(argv=["openra"])),
            ("Dino",   Action(argv=["/usr/local/bin/osmo-dino-play"],
                              fs_argv=["/usr/local/bin/osmo-dino-play", "--fullscreen"])),
        ]),
        ("Media", [
            ("Kodi",    Action(argv=["kodi"], fs_argv=["kodi", "--fullscreen"])),
            ("YouTube", Action(argv=["/usr/local/bin/osmo-youtube"],
                               fs_argv=["/usr/local/bin/osmo-youtube", "--fullscreen"])),
        ]),
        ("Telephone", [
            ("Linphone", Action(argv=["sh", "-c", "linphone || linphone-desktop"])),
            ("oFono",    Action(term_cmd="/usr/local/bin/osmo-ofono")),
            # Le telephone du banc : une VM postmarketOS/Phosh, avec son
            # ModemManager branche sur le modem du banc (tools/osmo-pmos.sh).
            ("pmOS",     Action(term_cmd="/usr/local/bin/osmo-pmos up; echo; read -n1 -rsp 'touche...'")),
        ]),
        ("Outils", [
            ("Wireshark", Action(argv=["/usr/local/bin/osmo-wireshark-root"])),
        ]),
    ]


class Launcher(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-launcher")
        (gx, gy, sw, sh), _ = screen_geom()
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
        self.connect("destroy", Gtk.main_quit)

        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        row.get_style_context().add_class("osmo-launch")
        row.set_halign(Gtk.Align.CENTER)
        row.set_valign(Gtk.Align.END)
        for cat, apps in catalogue():
            row.pack_start(self._cat_box(cat, apps), False, False, 0)
        self.add(row)

        # bande basse, pleine largeur, ~72 px
        self.h = 74
        self.set_default_size(sw, self.h)
        self.set_size_request(sw, self.h)
        self.move(gx, gy + sh - self.h)
        self.show_all()
        self.move(gx, gy + sh - self.h)

    def _draw(self, _w, cr):
        import cairo
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        return False

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
        box.pack_start(approw, False, False, 0)
        return box

    def _app_widget(self, name, action):
        wrap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        wrap.get_style_context().add_class("osmo-app")
        b = Gtk.Button(label=name)
        b.set_tooltip_text(f"{name} - clic: cale sur le cadre")
        b.connect("clicked", lambda *_a: action.launch("frame"))
        wrap.pack_start(b, False, False, 0)
        # ⛶ plein ecran
        bf = Gtk.Button(label="⛶")
        bf.get_style_context().add_class("mini")
        bf.set_tooltip_text("plein ecran")
        bf.connect("clicked", lambda *_a: action.launch("full"))
        wrap.pack_start(bf, False, False, 0)
        # ⤒ envoyer en haut (zone LAB GSM)
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
    Launcher()
    Gtk.main()
