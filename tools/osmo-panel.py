#!/usr/bin/env python3
# osmo-panel.py - l ENCART VIVANT du bureau, version cliquable.
#
# Une fenetre GTK de type BUREAU (le meme mecanisme que les icones DING
# d Ubuntu : sous toutes les fenetres, au-dessus du fond, et elle recoit les
# clics - ce que Conky ne sait pas faire), posee EXACTEMENT sur le cadre Calvin
# & Hobbes du fond d ecran (tools/wallpaper-render.py : boite 320,600-1430,1010
# en 1920x1080), a l echelle de l ecran. Elle affiche /run/osmo-fft/panel.png
# (tools/osmo-fft-snap.py : le strip du jour qui fond vers « FFT du mobile +
# mobile.log » quand le banc est pret) et, en pied, un petit menu :
#
#   [ Dashboard ]  firefox http://<operateur>:8080
#   [ tmux ]       un terminal attache a la session du banc
#   [ VTY 4247 ]   un terminal sur telnet 127.0.0.1 4247 (console du mobile)
#   [ < ] op 2/3 [ > ]   SEULEMENT en multi-operateur : passe d un operateur a
#                  l autre. Le choix est ecrit dans /run/osmo-fft/operator ; le
#                  rendu FFT (osmo-fft-snap.py) et le Conky en haut a droite
#                  (conky-osmo-status.sh) le lisent et suivent.
#
# Multi-operateur = /etc/osmocom/osmo-multi.conf (addition.sh) ET au moins un
# conteneur osmo-operator-N en marche (docker ps). Sans ca : pas de fleches.
#
# Lance par l autostart osmo-conky.desktop (avec le Conky osmo-conky.conf).
import os
import re
import shlex
import signal
import subprocess
import sys
import time

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402

RUN = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")
IMG = os.path.join(RUN, "panel.png")
OP_FILE = os.path.join(RUN, "operator")
PID_FILE = os.path.join(RUN, "panel.pid")
MULTI_CONF = os.environ.get("MULTI_CONF", "/etc/osmocom/osmo-multi.conf")
TMUX_SESSION = os.environ.get("TMUX_SESSION", "calypso")
DASH_PORT = int(os.environ.get("DASH_PORT", "8080"))
# Le VTY du client mobile (osmocom-bb « mobile »). 4247 pour MS#1 ; MS#2 est sur
# 4248 - voir start-direct.sh, qui les attribue.
VTY_PORT = int(os.environ.get("MS_VTY_PORT", "4247"))
# La boite du strip dans le fond (1920x1080).
BOX = (320, 600, 1110, 410)
FW, FH = 1920, 1080

CSS = b"""
.osmo-bar { background-color: rgba(20, 24, 36, 0.92); border-radius: 8px; padding: 2px 6px; }
.osmo-bar button { background: #161b22; color: #e6edf3; border: 1px solid #30363d;
                   border-radius: 6px; padding: 1px 8px; font: 9pt "DejaVu Sans Mono"; min-height: 0; }
.osmo-bar button:hover { background: #21262d; border-color: #58a6ff; }
.osmo-bar label { color: #8b949e; font: 9pt "DejaVu Sans Mono"; }
.osmo-bar label.op { color: #3fb950; font-weight: bold; }
"""


# ── LA GEOMETRIE : OU EST LE CADRE SUR CET ECRAN ────────────────────────────
def geometry():
    """(x, y, w, h) du cadre du strip sur l ecran, selon le mode d affichage
    du fond (zoom = couvre et rogne, scaled = contient, stretched)."""
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


# ── LES OPERATEURS ──────────────────────────────────────────────────────────
def operators():
    """Liste [(idx, mode, ip)] : le natif, puis les conteneurs EN MARCHE."""
    ops = []
    try:
        with open(MULTI_CONF) as f:
            txt = f.read()
    except OSError:
        txt = ""
    m = re.search(r'^MULTI_OPS="?([^"\n]*)"?', txt, re.M)
    specs = m.group(1).split() if m else []
    running = set()
    if any(":docker:" in s for s in specs):
        try:
            out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True,
                                 text=True, timeout=5).stdout
            running = set(out.split())
        except Exception:
            running = set()
    for spec in specs:
        parts = spec.split(":")
        if len(parts) < 3:
            continue
        idx, mode, ip = parts[0], parts[1], parts[2]
        if mode == "docker" and f"osmo-operator-{idx}" not in running:
            continue
        ops.append((idx, mode, ip))
    if not any(o[1] == "native" for o in ops):
        ops.insert(0, ("1", "native", ""))
    return ops


def write_operator(op):
    idx, mode, ip = op
    os.makedirs(RUN, exist_ok=True)
    tmp = OP_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"OP={idx}\nMODE={mode}\nIP={ip}\nNAME=osmo-operator-{idx}\n"
                f"DASH=http://{ip or '127.0.0.1'}:{DASH_PORT}\n")
    os.replace(tmp, OP_FILE)


def spawn(argv):
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def terminal(cmd):
    """Ouvre `cmd` (chaine shell) dans un emulateur de terminal."""
    root = "" if os.geteuid() == 0 else "sudo -E "
    for term, opt in (("gnome-terminal", "--"), ("xfce4-terminal", "-e"), ("konsole", "-e"), ("xterm", "-e")):
        if subprocess.run(["which", term], capture_output=True).returncode == 0:
            if term == "gnome-terminal":
                spawn([term, "--", "bash", "-c", root + cmd])
            else:
                spawn([term, opt, "bash -c " + shlex.quote(root + cmd)])
            return
    print("[panel] aucun emulateur de terminal", file=sys.stderr, flush=True)


class Panel(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-panel (osmo-egprs)")
        (x, y, w, h), (sw, sh, mode) = geometry()
        print(f"[panel] ecran {sw}x{sh} ({mode}) : encart a {x},{y} {w}x{h}", flush=True)
        self.geo = (x, y, w, h)
        self.set_type_hint(Gdk.WindowTypeHint.DESKTOP)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_below(True)
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
        b_dash = Gtk.Button(label="Dashboard")
        b_dash.set_tooltip_text("firefox sur le tableau de bord de l operateur choisi")
        b_dash.connect("clicked", self.on_dash)
        b_tmux = Gtk.Button(label="tmux")
        b_tmux.set_tooltip_text("terminal attache a la session du banc (Ctrl-b d pour detacher)")
        b_tmux.connect("clicked", self.on_tmux)
        # Le VTY du mobile : la console ou l on tape « show ms », « call 100102 »
        # ... C est le troisieme endroit qu on ouvre a la main dix fois par
        # seance ; il n avait pas de bouton.
        b_vty = Gtk.Button(label="VTY 4247")
        b_vty.set_tooltip_text(f"terminal : telnet 127.0.0.1 {VTY_PORT} (console du mobile)")
        b_vty.connect("clicked", self.on_vty)
        self.b_prev = Gtk.Button(label="<")
        self.b_next = Gtk.Button(label=">")
        self.b_prev.connect("clicked", self.on_prev)
        self.b_next.connect("clicked", self.on_next)
        self.l_op = Gtk.Label(label="")
        self.l_op.get_style_context().add_class("op")
        for wdg in (b_dash, b_tmux, b_vty, self.b_prev, self.l_op, self.b_next):
            bar.pack_start(wdg, False, False, 0)
        overlay.add_overlay(bar)
        self.add(overlay)

        self.ops = []
        self.cur = 0
        self.mtime = None
        self.refresh_ops()
        self.refresh_image()
        GLib.timeout_add(1000, self.refresh_image)
        GLib.timeout_add(5000, self.refresh_ops)
        self.show_all()
        self.update_op()          # show_all vient de tout montrer : on recache les fleches hors multi
        self.move(x, y)

    def on_draw(self, _w, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        return False

    # ── l image ────────────────────────────────────────────────────────────
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
            pass  # fichier en cours d ecriture : prochaine seconde
        return True

    # ── les operateurs ─────────────────────────────────────────────────────
    def refresh_ops(self):
        ops = operators()
        if ops != self.ops:
            sel = self.ops[self.cur] if self.ops and self.cur < len(self.ops) else None
            self.ops = ops
            self.cur = next((i for i, o in enumerate(ops) if sel and o[0] == sel[0]), 0)
            self.update_op()
        return True

    def update_op(self):
        multi = len(self.ops) > 1
        for wdg in (self.b_prev, self.b_next, self.l_op):
            wdg.set_visible(multi)
        if self.ops:
            op = self.ops[self.cur]
            self.l_op.set_text(f"op {op[0]}/{len(self.ops)}")
            write_operator(op)

    def on_prev(self, *_):
        if self.ops:
            self.cur = (self.cur - 1) % len(self.ops)
            self.update_op()

    def on_next(self, *_):
        if self.ops:
            self.cur = (self.cur + 1) % len(self.ops)
            self.update_op()

    # ── les boutons ────────────────────────────────────────────────────────
    def on_dash(self, *_):
        op = self.ops[self.cur] if self.ops else ("1", "native", "")
        url = f"http://{op[2] or '127.0.0.1'}:{DASH_PORT}"
        for browser in ("firefox", "chromium", "xdg-open"):
            if subprocess.run(["which", browser], capture_output=True).returncode == 0:
                spawn([browser, url])
                return

    def on_vty(self, *_):
        # telnet, et pas nc : c est ce que la documentation Osmocom donne, et le
        # VTY attend un vrai terminal ligne a ligne. Le `read` final garde la
        # fenetre ouverte quand le port est ferme - sinon elle se refermerait
        # avant qu on ait lu pourquoi.
        op = self.ops[self.cur] if self.ops else ("1", "native", "")
        host = op[2] or "127.0.0.1"
        cmd = (f"telnet {host} {VTY_PORT}"
               f" || {{ echo; echo 'VTY {host}:{VTY_PORT} injoignable - banc arrete ?'; read -r _; }}")
        terminal(cmd)

    def on_tmux(self, *_):
        op = self.ops[self.cur] if self.ops else ("1", "native", "")
        if op[1] == "docker":
            cmd = (f"docker exec -it osmo-operator-{op[0]} tmux -S /tmp/osmocom_tmux attach -t osmocom"
                   f" || {{ echo; echo 'pas de session tmux dans osmo-operator-{op[0]}'; read -r _; }}")
        else:
            cmd = (f"tmux attach -t {TMUX_SESSION}"
                   f" || {{ echo; echo 'pas de session tmux « {TMUX_SESSION} » - banc arrete ?'; read -r _; }}")
        terminal(cmd)


def single_instance():
    os.makedirs(RUN, exist_ok=True)
    try:
        old = int(open(PID_FILE).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM)
            time.sleep(0.3)
    except (OSError, ValueError):
        pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


if __name__ == "__main__":
    single_instance()
    Panel()
    Gtk.main()
