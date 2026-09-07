#!/usr/bin/env python3
# osmo-dino.py - le DINO (jeu "Coureur d'ombres") ANIME, pose sous le Conky.
#
# Remplace osmo-moon.py (le cavalier/lune en gif) : meme fenetre de type BUREAU
# (Gdk.WindowTypeHint.DESKTOP - sous toutes les fenetres, au-dessus du fond, non
# decoree, collante, transparente), meme colonne haut-droite, meme largeur 400,
# collee EN DESSOUS du Conky. Mais le contenu est une page HTML/canvas
# (configs/conky/dino.html) rendue par WebKit2 : le jeu tourne en mode "attract"
# tout seul (le dino court, Soleil/Lune, ombres calculees) - aucune interaction
# requise, comme une animation. On masque header/pied de page par une feuille de
# style injectee pour ne garder que le cadre du jeu.
#
# Reglage par variables d'environnement :
#   OSMO_DINO_HTML   chemin du html    (defaut: configs/conky/dino.html)
#   OSMO_DINO_W      largeur en px     (defaut: 400, la largeur du Conky)
#   OSMO_DINO_H      hauteur en px     (defaut: 260 ~ ratio 8/5 du cadre)
#   OSMO_DINO_GAP_X  marge a droite    (defaut: 24, le gap_x du Conky)
#   OSMO_DINO_GAP_Y  y du haut du jeu  (defaut: 680 = sous le Conky, qui descend
#                    jusque vers 580 ; 600 le laissait colle a lui)
#
# Lance par /usr/local/bin/osmo-desktop-panel (comme osmo-panel.py + conky).
import os
import sys

# [2026-09-06] LA FENETRE DE BUREAU EXIGE X11, PAS WAYLAND.
# Sous Wayland, GTK3 ignore window.move() ET Gdk.WindowTypeHint.DESKTOP : le
# compositeur place la fenetre ou il veut (au milieu, au premier plan) - d ou
# l encart et le dino qui « demarrent n importe ou ». Le protocole ne donne au
# client aucun moyen de se poser a des coordonnees absolues (il faudrait
# gtk-layer-shell, absent sur mutter). On passe donc par XWayland, ou le
# positionnement X11 est honore, exactement comme le Conky voisin (own_window
# type desktop) qui, lui, se cale bien. On ne force que si un DISPLAY existe :
# sans serveur X, mieux vaut le comportement par defaut qu un echec au demarrage.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

# [2026-09-06] ET ALORS LE TYPE BUREAU NE VA PLUS. Sur XWayland, une fenetre
# _NET_WM_WINDOW_TYPE_DESKTOP est rangee par GNOME Shell dans la couche du
# bureau, SOUS la fenetre plein ecran des icones (extension DING) - qui, elle,
# avale tous les clics : l encart s affichait mais ses boutons ne repondaient
# plus. On garde donc une fenetre NORMALE, simplement maintenue en dessous des
# autres (keep_below + stick + hors barre des taches) : meme rendu, et les
# clics arrivent. Sur X11 natif (la cle live) le type BUREAU marchait : on n y
# touche pas.
TYPE_HINT = Gdk.WindowTypeHint.NORMAL if X11_FORCE else Gdk.WindowTypeHint.DESKTOP
# [2026-09-06] ... ET « EN DESSOUS » NON PLUS. Deuxieme moitie du meme piege :
# avec _NET_WM_STATE_BELOW, GNOME Shell range la fenetre XWayland sous sa
# propre couche de bureau (native Wayland), qui est plein ecran et prend tous
# les clics - la fenetre restait visible mais totalement inerte. Sous XWayland
# on renonce donc a « toujours dessous » : fenetre ordinaire, collante et hors
# barre des taches. Elle passera au premier plan quand on clique dedans, ce qui
# est le prix a payer pour qu on puisse justement cliquer dedans. Mettre
# OSMO_DESKTOP_BELOW=1 pour retrouver l ancien comportement (fenetre sous tout,
# clics perdus) ; sur X11 natif rien ne change.
KEEP_BELOW = (not X11_FORCE) or os.environ.get("OSMO_DESKTOP_BELOW") == "1"

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HTML = os.environ.get("OSMO_DINO_HTML", os.path.join(REPO, "configs/conky/dino.html"))
WIN_W = int(os.environ.get("OSMO_DINO_W", "400"))     # meme largeur que le Conky
WIN_H = int(os.environ.get("OSMO_DINO_H", "260"))
GAP_X = int(os.environ.get("OSMO_DINO_GAP_X", "24"))  # meme gap_x que le Conky
GAP_Y = int(os.environ.get("OSMO_DINO_GAP_Y", "720"))  # sous le Conky, qui descend jusque vers 700

# On ne garde que le cadre du jeu : ni titre ni pied de page, cadre a ras bord.
INJECT_CSS = (
    "header,footer{display:none!important}"
    "body{padding:0!important;margin:0!important;min-height:auto!important;"
    "gap:0!important;background:var(--ink)!important}"
    ".frame{width:100%!important;max-width:none!important;border:0!important;"
    "border-radius:0!important;box-shadow:none!important;aspect-ratio:auto!important;"
    "height:100vh!important}"
)


class Dino(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-dino")
        if not os.path.exists(HTML):
            print(f"[dino] html introuvable: {HTML}", file=sys.stderr)
            sys.exit(1)
        self.w, self.h = WIN_W, WIN_H

        # colonne haut-droite du moniteur primaire, comme le Conky (top_right)
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        g = mon.get_geometry()
        self.x = g.x + g.width - GAP_X - self.w
        self.y = g.y + GAP_Y
        print(f"[dino] {self.w}x{self.h} @ {self.x},{self.y} ({HTML})", flush=True)

        # fenetre de type BUREAU (cf. osmo-panel.py / osmo-moon.py)
        self.set_type_hint(TYPE_HINT)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_below(KEEP_BELOW)
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
        self.connect("destroy", Gtk.main_quit)

        # WebView : feuille de style injectee (masque header/footer) + fond
        # transparent (le corps de la page reste sombre, c'est voulu).
        ucm = WebKit2.UserContentManager()
        ucm.add_style_sheet(WebKit2.UserStyleSheet(
            INJECT_CSS, WebKit2.UserContentInjectedFrames.ALL_FRAMES,
            WebKit2.UserStyleLevel.USER, None, None))
        self.view = WebKit2.WebView.new_with_user_content_manager(ucm)
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        self.add(self.view)
        self.view.load_uri(GLib.filename_to_uri(HTML, None))

        self.show_all()
        self._pos = (self.x, self.y)
        self._pin()
        self.connect("map-event", self._pin)
        GLib.timeout_add(500, self._pin)

    # [2026-09-06] SE REPOSER APRES COUP. Meme sous X11, le gestionnaire de
    # fenetres peut deplacer la fenetre au moment ou il la mappe (mutter le
    # fait pour les fenetres non decorees qu il ne reconnait pas comme du
    # bureau). Un seul move() avant show_all() ne tient donc pas : on recale
    # au map-event, puis une derniere fois une demi-seconde plus tard.
    def _pin(self, *_a):
        self.move(*self._pos)
        return False


def main():
    Dino()
    Gtk.main()


if __name__ == "__main__":
    main()
