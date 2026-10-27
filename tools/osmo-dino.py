#!/usr/bin/env python3
# osmo-dino.py - the ANIMATED DINO ("Coureur d'ombres" game), placed under Conky.
#
# Replaces osmo-moon.py (the rider/moon gif): same window of DESKTOP type
# (Gdk.WindowTypeHint.DESKTOP - under all windows, above the wallpaper,
# undecorated, sticky, transparent), same top-right column, same width 400,
# stuck BELOW Conky. But the content is an HTML/canvas page
# (configs/conky/dino.html) rendered by WebKit2: the game runs in "attract"
# mode on its own (the dino runs, Sun/Moon, computed shadows) - no interaction
# required, like an animation. Header/footer are hidden by an injected
# stylesheet to keep only the frame of the game.
#
# Settings through environment variables:
#   OSMO_DINO_HTML   path of the html  (default: configs/conky/dino.html)
#   OSMO_DINO_W      width in px       (default: 400, the width of Conky)
#   OSMO_DINO_H      height in px      (default: 260 ~ 8/5 ratio of the frame)
#   OSMO_DINO_GAP_X  right margin      (default: 24, the gap_x of Conky)
#   OSMO_DINO_GAP_Y  y of the game top (default: 680 = under Conky, which goes
#                    down to about 580)
#
# Started by /usr/local/bin/osmo-desktop-panel (like osmo-panel.py + conky).
import os
import subprocess
import sys

# THE DESKTOP WINDOW REQUIRES X11, NOT WAYLAND.
# Under Wayland, GTK3 ignores window.move() AND Gdk.WindowTypeHint.DESKTOP: the
# compositor places the window where it wants (in the middle, in front). The
# protocol gives the client no way to place itself at absolute coordinates
# (it would need gtk-layer-shell, absent on mutter). XWayland is used instead,
# where X11 positioning is honoured, exactly like the neighbouring Conky
# (own_window type desktop). Only forced when a DISPLAY exists: without an X
# server, the default behaviour is better than a failure at startup.
X11_FORCE = os.environ.get("XDG_SESSION_TYPE") == "wayland" and bool(os.environ.get("DISPLAY"))
if X11_FORCE:
    os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

# THE DESKTOP TYPE DOES NOT WORK ON XWAYLAND. There, a window of type
# _NET_WM_WINDOW_TYPE_DESKTOP is put by GNOME Shell in the desktop layer,
# UNDER the full-screen icons window (DING extension) - which swallows all
# clicks: the panel would show but its buttons would not respond. A NORMAL
# window is kept instead, simply held below the others (keep_below + stick +
# out of the taskbar): same rendering, and the clicks arrive. On native X11
# (the live key) the DESKTOP type works and is kept.
# APPLICATION MODE (--app, or OSMO_DINO_APP=1).
# The dino is not placed on the desktop: it is in the APPLICATION MENU
# (data/desktop/osmo-dino.desktop), and opens like any program. What
# changes, and nothing else: an ORDINARY window - decorated, resizable, in
# the taskbar, centred, neither sticky nor held below - and the page rendered
# as is, without the stylesheet that trims the frame to fit a 400x260
# corner. The full screen button of the page does not have to delegate to
# osmo-dino-play: this window CAN grow.
APP_MODE = os.environ.get("OSMO_DINO_APP") == "1" or "--app" in sys.argv[1:]

TYPE_HINT = Gdk.WindowTypeHint.NORMAL if (X11_FORCE or APP_MODE) else Gdk.WindowTypeHint.DESKTOP
# "BELOW" DOES NOT WORK ON XWAYLAND EITHER: with _NET_WM_STATE_BELOW, GNOME
# Shell puts the XWayland window under its own desktop layer (native Wayland),
# which is full screen and takes all clicks - the window stays visible but
# completely inert. Under XWayland "always below" is therefore given up:
# ordinary window, sticky and out of the taskbar. It comes to the front when
# clicked, the price to pay for being clickable at all. Set
# OSMO_DESKTOP_BELOW=1 to get the window under everything (clicks lost);
# on native X11 nothing changes.
KEEP_BELOW = (not APP_MODE) and ((not X11_FORCE) or os.environ.get("OSMO_DESKTOP_BELOW") == "1")

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HTML = os.environ.get("OSMO_DINO_HTML", os.path.join(REPO, "configs/conky/dino.html"))
WIN_W = int(os.environ.get("OSMO_DINO_W", "880" if APP_MODE else "400"))  # widget: the width of Conky
WIN_H = int(os.environ.get("OSMO_DINO_H", "560" if APP_MODE else "260"))
GAP_X = int(os.environ.get("OSMO_DINO_GAP_X", "24"))  # same gap_x as Conky
GAP_Y = int(os.environ.get("OSMO_DINO_GAP_Y", "720"))  # under Conky, which goes down to about 700

# Only the frame of the game is kept: no title nor footer, frame flush to the edge.
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
        self._plein = False

        if APP_MODE:
            # A window like the others: the window manager places it, resizes it
            # and puts it in the taskbar. No move(), hence no _pin either - nothing
            # tries to put it back in a corner it no longer has.
            self.x = self.y = 0
            print(f"[dino] application {self.w}x{self.h} ({HTML})", flush=True)
            self.set_type_hint(TYPE_HINT)
            self.set_default_size(self.w, self.h)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.set_icon_name("osmo-dino")
        else:
            # top-right column of the primary monitor, like Conky (top_right)
            disp = Gdk.Display.get_default()
            mon = disp.get_primary_monitor() or disp.get_monitor(0)
            g = mon.get_geometry()
            self.x = g.x + g.width - GAP_X - self.w
            self.y = g.y + GAP_Y
            print(f"[dino] {self.w}x{self.h} @ {self.x},{self.y} ({HTML})", flush=True)

            # window of DESKTOP type (cf. osmo-panel.py / osmo-moon.py)
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

        # WebView: injected stylesheet (hides header/footer) + transparent
        # background (the body of the page stays dark, on purpose).
        ucm = WebKit2.UserContentManager()
        # The stylesheet is only for the widget: it hides header and footer to
        # keep only the frame of the game in 400x260. As an application, the
        # page is shown whole, as in a browser.
        if not APP_MODE:
            ucm.add_style_sheet(WebKit2.UserStyleSheet(
                INJECT_CSS, WebKit2.UserContentInjectedFrames.ALL_FRAMES,
                WebKit2.UserStyleLevel.USER, None, None))
        # THE FULL SCREEN BUTTON OF THE WIDGET. A page cannot enlarge a GTK
        # window, and this 400x260 widget has nothing to enlarge anyway: it is a
        # corner of the desktop. The page therefore knows it is a "widget"
        # (OSMO_HOST) and, on click, sends a WebKit message - the REAL game is
        # then opened, full screen, in its own window.
        # 'widget' makes the page delegate full screen (dino.html l.519). As an
        # application, the host CAN grow: 'app' is announced, and the {full:...}
        # message is handled below by _on_message.
        ucm.add_script(WebKit2.UserScript(
            "window.OSMO_HOST='app';" if APP_MODE else "window.OSMO_HOST='widget';",
            WebKit2.UserContentInjectedFrames.ALL_FRAMES,
            WebKit2.UserScriptInjectionTime.START, None, None))
        ucm.connect("script-message-received::osmo", self._on_message)
        ucm.register_script_message_handler("osmo")
        self.view = WebKit2.WebView.new_with_user_content_manager(ucm)
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        self.add(self.view)
        self.view.load_uri(GLib.filename_to_uri(HTML, None))

        self.show_all()
        self._pos = (self.x, self.y)
        if not APP_MODE:
            self._pin()
            self.connect("map-event", self._pin)
            GLib.timeout_add(500, self._pin)

    # REPOSITION AFTERWARDS. Even under X11, the window manager may move the
    # window when it maps it (mutter does so for undecorated windows it does
    # not recognise as desktop). A single move() before show_all() does not
    # hold: the window is repositioned on map-event, then one last time half
    # a second later.
    def _pin(self, *_a):
        self.move(*self._pos)
        return False

    def _on_message(self, _ucm, result):
        """{full:...}: as an application, THIS window; as a widget, the one of the game."""
        if APP_MODE:
            # The page sends {full:true} or {full:false} - followed.
            try:
                val = result.get_js_value()
                plein = bool(val.object_get_property("full").to_boolean())
            except Exception:
                plein = not self._plein
            self._plein = plein
            self.fullscreen() if plein else self.unfullscreen()
            return
        for cand in ("/usr/local/bin/osmo-dino-play",):
            if os.path.exists(cand):
                subprocess.Popen([cand, "--fullscreen"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
                return
        print("[dino] osmo-dino-play absent (tools/osmo-extras-install.sh le pose)", flush=True)


def main():
    Dino()
    Gtk.main()


if __name__ == "__main__":
    main()
