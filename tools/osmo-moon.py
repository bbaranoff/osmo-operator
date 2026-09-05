#!/usr/bin/env python3
# osmo-moon.py - le cavalier/lune ANIME, pose sous le Conky (colonne haut-droite).
#
# Meme mecanisme de fenetre que tools/osmo-panel.py : une fenetre GTK de type
# BUREAU (Gdk.WindowTypeHint.DESKTOP) - sous toutes les fenetres, au-dessus du
# fond, non decoree, collante, transparente (argb). Elle N'A RIEN A VOIR avec la
# conf Conky (osmo-conky.conf) : c'est un element SEPARE, aligne A LA VERTICALE
# du Conky (meme colonne haut-droite, meme largeur 400), colle EN DESSOUS de lui.
#
# Le gif (820x560, 240 frames) est redimensionne PROPORTIONNELLEMENT a la largeur
# demandee (defaut 400, comme le Conky) : hauteur = largeur * 560/820. L'animation
# est jouee frame par frame (GdkPixbuf.PixbufAnimation + iterateur), chaque frame
# etant mise a l'echelle avant affichage.
#
# Reglage par variables d'environnement :
#   OSMO_MOON_GIF     chemin du gif      (defaut: configs/conky/cavalier_lune.gif)
#   OSMO_MOON_W       largeur en px      (defaut: 400, la largeur du Conky)
#   OSMO_MOON_GAP_X   marge a droite     (defaut: 24, le gap_x du Conky)
#   OSMO_MOON_GAP_Y   y du haut du gif   (defaut: 600 = sous le Conky ; a ajuster
#                                          selon la hauteur reelle du Conky)
#
# Lance par /usr/local/bin/osmo-desktop-panel (comme osmo-panel.py + conky).
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402

import cairo  # noqa: E402

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
GIF = os.environ.get("OSMO_MOON_GIF", os.path.join(REPO, "configs/conky/cavalier_lune.gif"))
WIN_W = int(os.environ.get("OSMO_MOON_W", "400"))     # meme largeur que le Conky
GAP_X = int(os.environ.get("OSMO_MOON_GAP_X", "24"))  # meme gap_x que le Conky
GAP_Y = int(os.environ.get("OSMO_MOON_GAP_Y", "600")) # sous le Conky (a ajuster)


def target_size(anim):
    """Largeur imposee, hauteur PROPORTIONNELLE au ratio natif du gif."""
    gw, gh = anim.get_width(), anim.get_height()
    w = WIN_W
    h = max(1, round(w * gh / gw))
    return w, h


class Moon(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-moon")
        try:
            self.anim = GdkPixbuf.PixbufAnimation.new_from_file(GIF)
        except GLib.Error as e:
            print(f"[moon] gif introuvable/illisible: {GIF} ({e})", file=sys.stderr)
            sys.exit(1)
        self.w, self.h = target_size(self.anim)

        # colonne haut-droite du moniteur primaire, comme le Conky (top_right)
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        g = mon.get_geometry()
        self.x = g.x + g.width - GAP_X - self.w
        self.y = g.y + GAP_Y
        print(f"[moon] {self.w}x{self.h} @ {self.x},{self.y} (gif {self.anim.get_width()}x{self.anim.get_height()})",
              flush=True)

        # fenetre de type BUREAU (cf. osmo-panel.py)
        self.set_type_hint(Gdk.WindowTypeHint.DESKTOP)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_below(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        self.set_default_size(self.w, self.h)
        self.set_size_request(self.w, self.h)
        self.move(self.x, self.y)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        self.image = Gtk.Image()
        self.add(self.image)

        # lecture animee : iterateur de frames, mise a l'echelle proportionnelle
        self.it = self.anim.get_iter(None)
        self.show_all()
        self.move(self.x, self.y)
        self._render()

    def on_draw(self, _w, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        return False

    def _render(self):
        self.it.advance(None)
        frame = self.it.get_pixbuf()
        scaled = frame.scale_simple(self.w, self.h, GdkPixbuf.InterpType.BILINEAR)
        self.image.set_from_pixbuf(scaled)
        delay = self.it.get_delay_time()   # ms ; -1 = image fixe
        GLib.timeout_add(delay if delay > 0 else 100, self._render)
        return False


def main():
    Moon()
    Gtk.main()


if __name__ == "__main__":
    main()
