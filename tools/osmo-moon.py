#!/usr/bin/env python3
# osmo-moon.py - the ANIMATED rider/moon, placed under Conky (top-right column).
#
# Same window mechanism as tools/osmo-panel.py: a GTK window of DESKTOP type
# (Gdk.WindowTypeHint.DESKTOP) - under all windows, above the wallpaper,
# undecorated, sticky, transparent (argb). It has NOTHING TO DO with the Conky
# configuration (osmo-conky.conf): it is a SEPARATE element, aligned VERTICALLY
# with Conky (same top-right column, same width 400), stuck BELOW it.
#
# The gif (820x560, 240 frames) is resized PROPORTIONALLY to the requested
# width (default 400, like Conky): height = width * 560/820. The animation is
# played frame by frame (GdkPixbuf.PixbufAnimation + iterator), each frame
# being scaled before display.
#
# Settings through environment variables:
#   OSMO_MOON_GIF     path of the gif    (default: configs/conky/cavalier_lune.gif)
#   OSMO_MOON_W       width in px        (default: 400, the width of Conky)
#   OSMO_MOON_GAP_X   right margin       (default: 24, the gap_x of Conky)
#   OSMO_MOON_GAP_Y   y of the gif top   (default: 600 = under Conky; to adjust
#                                          to the real height of Conky)
#
# Started by /usr/local/bin/osmo-desktop-panel (like osmo-panel.py + conky).
import os
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
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402

# THE DESKTOP TYPE DOES NOT WORK ON XWAYLAND. There, a window of type
# _NET_WM_WINDOW_TYPE_DESKTOP is put by GNOME Shell in the desktop layer,
# UNDER the full-screen icons window (DING extension) - which swallows all
# clicks: the panel would show but its buttons would not respond. A NORMAL
# window is kept instead, simply held below the others (keep_below + stick +
# out of the taskbar): same rendering, and the clicks arrive. On native X11
# (the live key) the DESKTOP type works and is kept.
TYPE_HINT = Gdk.WindowTypeHint.NORMAL if X11_FORCE else Gdk.WindowTypeHint.DESKTOP
# "BELOW" DOES NOT WORK ON XWAYLAND EITHER: with _NET_WM_STATE_BELOW, GNOME
# Shell puts the XWayland window under its own desktop layer (native Wayland),
# which is full screen and takes all clicks - the window stays visible but
# completely inert. Under XWayland "always below" is therefore given up:
# ordinary window, sticky and out of the taskbar. It comes to the front when
# clicked, the price to pay for being clickable at all. Set
# OSMO_DESKTOP_BELOW=1 to get the window under everything (clicks lost);
# on native X11 nothing changes.
KEEP_BELOW = (not X11_FORCE) or os.environ.get("OSMO_DESKTOP_BELOW") == "1"

import cairo  # noqa: E402

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
GIF = os.environ.get("OSMO_MOON_GIF", os.path.join(REPO, "configs/conky/cavalier_lune.gif"))
WIN_W = int(os.environ.get("OSMO_MOON_W", "400"))     # same width as Conky
GAP_X = int(os.environ.get("OSMO_MOON_GAP_X", "24"))  # same gap_x as Conky
GAP_Y = int(os.environ.get("OSMO_MOON_GAP_Y", "600")) # under Conky (to adjust)


def target_size(anim):
    """Imposed width, height PROPORTIONAL to the native ratio of the gif."""
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

        # top-right column of the primary monitor, like Conky (top_right)
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        g = mon.get_geometry()
        self.x = g.x + g.width - GAP_X - self.w
        self.y = g.y + GAP_Y
        print(f"[moon] {self.w}x{self.h} @ {self.x},{self.y} (gif {self.anim.get_width()}x{self.anim.get_height()})",
              flush=True)

        # window of DESKTOP type (cf. osmo-panel.py)
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
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        self.image = Gtk.Image()
        self.add(self.image)

        # animated playback: frame iterator, proportional scaling
        self.it = self.anim.get_iter(None)
        self.show_all()
        self._pos = (self.x, self.y)
        self._pin()
        self.connect("map-event", self._pin)
        GLib.timeout_add(500, self._pin)
        self._render()

    # REPOSITION AFTERWARDS. Even under X11, the window manager may move the
    # window when it maps it (mutter does so for undecorated windows it does
    # not recognise as desktop). A single move() before show_all() does not
    # hold: the window is repositioned on map-event, then one last time half
    # a second later.
    def _pin(self, *_a):
        self.move(*self._pos)
        return False
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
        delay = self.it.get_delay_time()   # ms; -1 = still image
        GLib.timeout_add(delay if delay > 0 else 100, self._render)
        return False


def main():
    Moon()
    Gtk.main()


if __name__ == "__main__":
    main()
