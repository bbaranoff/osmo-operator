#!/usr/bin/env python3
# osmo-topzone.py - LA ZONE HAUTE « LAB GSM », vivante et cliquable.
#
# Remplace la carte LAB GSM autrefois CUITE dans le fond d ecran
# (tools/wallpaper-render.py, desormais lance avec OSMO_LIVE_BANNER=1 pour ne
# plus la dessiner). C est une fenetre de type BUREAU (comme osmo-panel.py) posee
# EXACTEMENT sur la boite de la carte (320,60 .. 1430,560 en 1920x1080), qui
# affiche configs/conky/labgsm.html via WebKit.
#
# DEUX ROLES :
#   1. AU REPOS (rien d heberge) : la banniere anime ses 8 timeslots. Elle lit
#      $OSMO_FFT_DIR/timeslots.json (ecrit par tools/osmo-ts-probe.py : conf
#      osmo-bsc + VTY) et fait CLIGNOTER EN ORANGE tout timeslot qui porte des
#      bursts - un TCH ne clignote que s il y a de la voix. ARFCN / IMSI / A5
#      sont les valeurs LIVE. Le chronogramme du burst scintille avec l activite.
#   2. HEBERGEMENT : quand osmo-launcher.py envoie « en haut » une appli, il
#      ecrit "HOST <winid>" dans $XDG_RUNTIME_DIR/osmo-topzone.cmd. On fait alors
#      le FONDU de la banniere et on cale la fenetre de l appli sur la zone. Une
#      petite barre au-dessus (toujours devant) porte une CROIX de fermeture et
#      un bascule PLEIN ECRAN / RECTANGLE HAUT.
import json
import os
import subprocess
import sys
import time

# [2026-09-06] MEME PIEGE QUE osmo-panel.py / osmo-dino.py (voir leurs notes) :
# sous Wayland, GTK3 ignore move() et le type BUREAU ; une fois passe par
# XWayland, « toujours dessous » fait avaler les clics par la couche de bureau
# de GNOME Shell. Backend X11, fenetre normale.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

# [2026-09-06] LA BANNIERE, ELLE, RESTE AU FOND. Contrairement a l encart et au
# lanceur, on la VEUT collee au bureau, derriere tout : c est un decor, pas un
# panneau de commande. Sur XWayland ca coute les clics (GNOME Shell range les
# fenetres de type BUREAU sous sa couche d icones, qui les avale) - donc
# l hebergement de fenetre dans la zone haute ne repond plus a la souris. C est
# le choix assume ici ; OSMO_TOPZONE_CLIQUABLE=1 pour reprendre une fenetre
# normale (devant, mais cliquable) si on a besoin de s en servir.
_CLIQUABLE = os.environ.get("OSMO_TOPZONE_CLIQUABLE") == "1"
TYPE_HINT = Gdk.WindowTypeHint.NORMAL if _CLIQUABLE else Gdk.WindowTypeHint.DESKTOP
KEEP_BELOW = not _CLIQUABLE

FW, FH = 1920, 1080
# [2026-09-06] ON ENLEVE LE VIDE DU BAS, PAS LE CONTENU.
# La boite (1110x500, soit 1644x740 sur l ecran du banc) etait bien plus haute
# que ce que la carte remplit : tout le bas etait du fond vide qui mangeait le
# bureau. Deux fausses pistes, ecartees :
#   - rapetisser la boite : la page est ecrite en unites vh/vw (#card fait
#     height:100%, les titres 8.5vh, les etiquettes 1.3vh...), donc raccourcir
#     la fenetre RAPETISSE tout l interieur - ce n est pas ce qu on veut ;
#   - zoomer la vue a 0.5 : meme resultat, l interieur maigrit.
# Ce qu on fait : la page est rendue A SA TAILLE D ORIGINE (les vh gardent la
# hauteur de reference ci-dessous, donc l interieur est identique a avant), le
# cadre s arrete apres son contenu (CSS injecte : #card passe en height:auto),
# et la fenetre se cale sur la hauteur reellement occupee, mesuree DANS la page
# une fois chargee. Plus de vide, et pas un pixel de contenu perdu.
TOP_BOX = (320, 60, 1110, 500)          # carte LAB GSM (x,y,w,h) - le RENDU
# La feuille qui coupe le vide. Attention au piege : #card est en
# « position:absolute; inset:0 » - ce n est pas une hauteur qui l etire mais son
# bottom:0. Lui poser height:auto ne change donc RIEN tant qu on ne relache pas
# le bas ; il faut les deux.
INJECT_CSS = "#card{bottom:auto!important;height:auto!important}"
REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HTML = os.environ.get("OSMO_LABGSM_HTML", os.path.join(REPO, "configs/conky/labgsm.html"))
FFT_RUN = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")


# ── OU LIRE : LA MEME REGLE QUE LA SONDE, ET RELUE A CHAQUE TOUR ────────────
# [2026-09-10] Ce chemin etait fige au demarrage, et sa regle n etait pas tout
# a fait celle de l ecrivain (tools/osmo-ts-probe.py, run_dir()) : la sonde se
# repliait sur $XDG_RUNTIME_DIR, jamais regarde ici. Deux regles pour un seul
# fichier, et la banniere restait en demonstration devant un banc qui portait
# des appels, sans une ligne d erreur nulle part. C est la MEME regle des deux
# cotes, mot pour mot : le premier repertoire qui existe et ou l on peut
# ecrire, entre $OSMO_FFT_DIR et /tmp - relue a chaque lecture, parce que
# /run/osmo-fft est un RuntimeDirectory qui va et vient avec son service.
def ts_json():
    for d in (FFT_RUN, "/tmp"):
        if os.path.isdir(d) and os.access(d, os.W_OK):
            return os.path.join(d, "timeslots.json")
    return "/tmp/timeslots.json"
RUN = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
CMD_FILE = os.path.join(RUN if os.path.isdir(RUN) else "/tmp", "osmo-topzone.cmd")


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
    """Barre de controle TOUJOURS DEVANT (croix + bascule plein ecran)."""
    def __init__(self, on_close, on_toggle):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_accept_focus(False)
        prov = Gtk.CssProvider()
        prov.load_from_data(b".strip{background:rgba(19,16,24,.85);border-radius:8px}"
                            b".strip button{color:#efe6d2;background:rgba(40,34,52,.9);"
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
        self.hosted = None       # winid de l appli hebergee
        self.fs = False          # mode plein ecran de l appli hebergee
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
        # Une fois la page chargee, on lui demande la hauteur que la carte
        # occupe VRAIMENT et on rabat la fenetre dessus.
        self.view.connect("load-changed", self.on_load)
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        self.add(self.view)
        if os.path.exists(HTML):
            self.view.load_uri(GLib.filename_to_uri(HTML, None))
        else:
            self.view.load_html("<h1 style='color:#fff;font-family:sans-serif'>labgsm.html introuvable</h1>", None)

        self.strip = Strip(self.on_close, self.on_toggle)

        self._cmd_mtime = None
        self.show_all()
        self.move(x, y)
        # [2026-09-06] LE TEMPS REEL SE PERD AUSSI ICI. On poussait l etat une
        # fois par seconde, en aveugle : ajoute a la seconde de la sonde, un
        # timeslot pouvait mettre deux secondes a clignoter. On regarde
        # maintenant le fichier cinq fois par seconde et on ne pousse QUE s il
        # a change - plus reactif, et moins de JS inutile qu avant.
        self._ts_mtime = None
        GLib.timeout_add(200, self.push_state)
        GLib.timeout_add(500, self.poll_cmd)

    # ── rabattre la fenetre sur la hauteur utile ────────────────────────────
    def on_load(self, _view, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        # Un cheveu de marge sous le cadre, sinon la bordure du bas rase le
        # bord de la fenetre.
        self.view.run_javascript(
            "(function(){var c=document.getElementById('card')||document.body;"
            "return Math.ceil(c.getBoundingClientRect().bottom)+2;})()",
            None, self.on_height, None)

    def on_height(self, view, res, _data):
        try:
            val = view.run_javascript_finish(res).get_js_value().to_double()
        except Exception as e:                      # page remplacee, JS coupe...
            print("[topzone] hauteur non mesuree : %s" % e, file=sys.stderr, flush=True)
            return
        h = int(val)
        x, y, w, h_full = self.box_geo
        if not (0 < h < h_full):                    # mesure absurde : on garde tout
            print("[topzone] hauteur mesuree %d ignoree (fenetre %d)" % (h, h_full),
                  file=sys.stderr, flush=True)
            return
        print("[topzone] hauteur utile %d px (au lieu de %d)" % (h, h_full), flush=True)
        self.box_geo = (x, y, w, h)
        self.set_size_request(w, h)
        self.resize(w, h)
        self.move(x, y)

    # ── au repos : pousser l etat des timeslots dans la page ─────────────────
    def push_state(self):
        chemin = ts_json()
        try:
            mt = (chemin, os.stat(chemin).st_mtime)
        except OSError:
            mt = None
        if mt is not None and mt == self._ts_mtime:
            return True                      # rien de neuf depuis le dernier tour
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

    # ── hebergement : lire le canal osmo-launcher -> osmo-topzone ────────────
    def poll_cmd(self):
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
        # la barre de controle, au coin haut-droit de la zone
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
