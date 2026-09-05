#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# overlay-draw.py - dessin vectoriel façon Inkscape, en OVERLAY transparent
# TOUJOURS AU PREMIER PLAN par-dessus le bureau. Tout tient dans UNE fenêtre :
# le canevas plein écran + une barre d'outils verticale collée EN BAS À DROITE.
#
# Feutre (outil par défaut) : on MAINTIENT le clic gauche pour tracer à main
# levée ; le trait reste au premier plan et il est effaçable (gomme, ou la case
# « tout effacer » du coin bas-droit).
#
# Barre d'outils (de bas en haut, collée au bord droit et au bord bas) :
#   [C]  Tout effacer   (case rouge, dans le coin)
#   Gomme · Couleur (cliquer = couleur suivante) · − · +  (épaisseur)
#   Ellipse · Rectangle · Segment · Feutre · Déplacer · Annuler
#   Traverser (clic-à-travers) · Quitter
#
# Molette   = épaisseur du trait.
# Clavier   : b feutre · l segment · r rect · e ellipse · x gomme · s déplacer
#             z annuler · Suppr efface la sélection · Espace traverser · Échap/q quitter
#
# X11 + compositeur (GNOME/mutter) requis pour la transparence par pixel.
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import cairo
import math
import copy
import time
import os

GRAB_R = 14
HIT_TOL = 8
BS = 46          # côté d'un bouton de la barre
GAP = 6          # espace entre boutons
MARGIN = 12      # marge aux bords droit / bas
DOT_R = 24       # rayon de la pastille de rappel (état dormant)
DOT_MARGIN = 22  # marge de la pastille aux bords
HOLD_MS = 220    # durée de maintien du 2e clic pour réveiller depuis la pastille

SWATCHES = [
    (0.00, 0.82, 1.00), (1.00, 0.58, 0.00), (0.20, 0.90, 0.35),
    (1.00, 0.25, 0.35), (1.00, 0.90, 0.10), (0.75, 0.45, 1.00),
    (1.00, 1.00, 1.00), (0.05, 0.05, 0.05),
]

# ordre de la barre, du COIN bas-droit vers le HAUT
TOOLBAR = ["clear", "eraser", "color", "width_dn", "width_up",
           "ellipse", "rect", "line", "pencil", "select", "undo",
           "pass", "quit"]
TOOL_IDS = {"pencil", "line", "rect", "ellipse", "eraser", "select", "node"}


def dist(ax, ay, bx, by):
    return math.hypot(ax - bx, ay - by)


def dist_point_seg(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return dist(px, py, ax, ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return dist(px, py, ax + t * dx, ay + t * dy)


def obj_bbox(o):
    xs = [p[0] for p in o["pts"]]; ys = [p[1] for p in o["pts"]]
    return min(xs), min(ys), max(xs), max(ys)


def obj_hit(o, x, y, tol):
    t = o["pts"]; typ = o["type"]; tol = tol + o["width"] / 2.0
    if typ in ("line", "path"):
        if len(t) == 1:
            return dist(x, y, t[0][0], t[0][1]) <= tol
        return any(dist_point_seg(x, y, a[0], a[1], b[0], b[1]) <= tol
                   for a, b in zip(t, t[1:]))
    x0, y0, x1, y1 = obj_bbox(o)
    if o.get("fill") and x0 - tol <= x <= x1 + tol and y0 - tol <= y <= y1 + tol:
        return True
    if typ == "rect":
        v = (abs(x - x0) <= tol or abs(x - x1) <= tol) and (y0 - tol <= y <= y1 + tol)
        h = (abs(y - y0) <= tol or abs(y - y1) <= tol) and (x0 - tol <= x <= x1 + tol)
        return v or h
    if typ == "ellipse":
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        rx, ry = max((x1 - x0) / 2, 1), max((y1 - y0) / 2, 1)
        d = math.sqrt(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2)
        return abs(d - 1.0) <= (tol / min(rx, ry) + 0.06)
    return False


def obj_translate(o, dx, dy):
    o["pts"] = [(px + dx, py + dy) for px, py in o["pts"]]


def _hex(c):
    return "#%02x%02x%02x" % (int(c[0] * 255), int(c[1] * 255), int(c[2] * 255))


class Overlay(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("overlay-draw")
        self.set_app_paintable(True)
        screen = self.get_screen()
        vis = screen.get_rgba_visual()
        self.has_alpha = vis is not None
        if self.has_alpha:
            self.set_visual(vis)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()

        # état du document
        self.objects = []
        self.selected = None
        self.tool = "pencil"           # le feutre par défaut
        self.color_idx = 0
        self.color = SWATCHES[0]
        self.width = 4.0
        self.fill = False
        self.passthrough = False
        self.undo_stack = []
        self.redo_stack = []
        self.status = ""
        self.status_until = 0
        self.dormant = False           # rangé dans la pastille du coin
        self._dot_pressed = False      # 2e clic de la pastille maintenu ?

        # état d'interaction
        self.drag = None
        self.start = None
        self.temp = None
        self.pen_pts = None
        self.buttons = []              # [(id, x, y, w, h)] recalculé au rendu

        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.KEY_PRESS_MASK
            | Gdk.EventMask.SCROLL_MASK)
        self.connect("draw", self.on_draw)
        self.connect("button-press-event", self.on_press)
        self.connect("button-release-event", self.on_release)
        self.connect("motion-notify-event", self.on_motion)
        self.connect("key-press-event", self.on_key)
        self.connect("scroll-event", self.on_scroll)
        self.connect("destroy", Gtk.main_quit)

        self.fullscreen()
        self.show_all()
        GLib.timeout_add(300, lambda: (self.set_keep_above(True), False)[1])

    # ── barre d'outils : géométrie et clics ────────────────────────────────
    def layout_buttons(self, W, H):
        self.buttons = []
        x = W - MARGIN - BS
        for i, bid in enumerate(TOOLBAR):
            y = H - MARGIN - BS - i * (BS + GAP)
            self.buttons.append((bid, x, y, BS, BS))

    def button_at(self, x, y):
        for bid, bx, by, bw, bh in self.buttons:
            if bx <= x <= bx + bw and by <= y <= by + bh:
                return bid
        return None

    def toolbar_region(self):
        reg = cairo.Region()
        for _bid, bx, by, bw, bh in self.buttons:
            reg.union(cairo.RectangleInt(int(bx), int(by), int(bw), int(bh)))
        return reg

    def full_region(self):
        # ce binding refuse None pour « pas de forme » : on redonne l'entree a
        # toute la fenetre avec une region pleine (equivalent a aucune forme).
        a = self.get_allocation()
        return cairo.Region(cairo.RectangleInt(0, 0, max(a.width, 1), max(a.height, 1)))

    def do_button(self, bid):
        if bid in TOOL_IDS:
            self.tool = bid
            self.finish_pen()
        elif bid == "clear":
            self.clear_all()
        elif bid == "color":
            self.color_idx = (self.color_idx + 1) % len(SWATCHES)
            self.color = SWATCHES[self.color_idx]
            self.apply_style()
        elif bid == "width_dn":
            self.set_width(self.width - 1)
        elif bid == "width_up":
            self.set_width(self.width + 1)
        elif bid == "undo":
            self.undo()
        elif bid == "pass":
            self.set_passthrough(not self.passthrough)
        elif bid == "quit":
            self.go_dormant()
        self.queue_draw()

    # ── état dormant : tout se range dans une pastille au coin bas-droit ─────
    def dot_center(self):
        a = self.get_allocation()
        return a.width - DOT_MARGIN - DOT_R, a.height - DOT_MARGIN - DOT_R

    def dot_region(self):
        cx, cy = self.dot_center()
        r = DOT_R + 6
        return cairo.Region(cairo.RectangleInt(int(cx - r), int(cy - r),
                                               int(2 * r), int(2 * r)))

    def go_dormant(self):
        # la croix (X) ne quitte pas : elle range. Le dessin disparaît, seule
        # la pastille reste, toujours au-dessus. Le travail est gardé en mémoire.
        self.dormant = True
        self.drag = None
        self.temp = None
        self.pen_pts = None
        gw = self.get_window()
        if gw is not None:
            gw.input_shape_combine_region(self.dot_region(), 0, 0)
        self.queue_draw()

    def wake(self):
        self.dormant = False
        self.passthrough = False
        gw = self.get_window()
        if gw is not None:
            gw.input_shape_combine_region(self.full_region(), 0, 0)
        self.set_keep_above(True)
        self.queue_draw()

    def _dot_wake_if_held(self):
        # appelé HOLD_MS après le 2e clic : on ne reveille que s'il est encore
        # enfonce -> « double-clic dont le deuxieme appui reste long ».
        if self.dormant and self._dot_pressed:
            self.wake()
        return False

    # ── helpers document ────────────────────────────────────────────────────
    def new_obj(self, typ, pts):
        return {"type": typ, "pts": pts, "stroke": self.color,
                "width": self.width, "fill": self.color if self.fill else None}

    def topmost_at(self, x, y):
        for o in reversed(self.objects):
            if obj_hit(o, x, y, HIT_TOL):
                return o
        return None

    def set_width(self, v):
        self.width = max(1.0, min(40.0, v))
        self.apply_style()
        self.flash("épaisseur %d" % self.width)

    def apply_style(self):
        o = self.selected
        if o is not None and o in self.objects:
            o["stroke"] = self.color
            o["width"] = self.width
            self.queue_draw()

    def flash(self, msg):
        self.status = msg
        self.status_until = time.time() + 1.5
        self.queue_draw()

    # ── historique ──────────────────────────────────────────────────────────
    def push_undo(self):
        self.undo_stack.append(copy.deepcopy(self.objects))
        if len(self.undo_stack) > 120:
            self.undo_stack.pop(0)
        self.redo_stack.clear()

    def undo(self):
        if self.undo_stack:
            self.redo_stack.append(copy.deepcopy(self.objects))
            self.objects = self.undo_stack.pop()
            self.selected = None

    def redo(self):
        if self.redo_stack:
            self.undo_stack.append(copy.deepcopy(self.objects))
            self.objects = self.redo_stack.pop()
            self.selected = None

    def delete_selected(self):
        if self.selected in self.objects:
            self.push_undo()
            self.objects.remove(self.selected)
            self.selected = None
            self.queue_draw()

    def clear_all(self):
        if self.objects:
            self.push_undo()
            self.objects = []
            self.selected = None
            self.flash("tableau effacé")

    # ── clic-à-travers : seule la barre reste cliquable ────────────────────
    def set_passthrough(self, on):
        self.passthrough = on
        gw = self.get_window()
        if gw is not None:
            gw.input_shape_combine_region(self.toolbar_region() if on else self.full_region(), 0, 0)
        self.flash("clic-à-travers " + ("ON" if on else "OFF"))

    # ── entrées souris ────────────────────────────────────────────────────
    def on_press(self, w, e):
        x, y = e.x, e.y
        if self.dormant:
            cx, cy = self.dot_center()
            if e.button == 1 and dist(x, y, cx, cy) <= DOT_R + 6:
                self._dot_pressed = True
                if e.type == Gdk.EventType._2BUTTON_PRESS:
                    GLib.timeout_add(HOLD_MS, self._dot_wake_if_held)
            return True
        bid = self.button_at(x, y)
        if bid is not None and e.button == 1:
            self.do_button(bid)
            return True
        if self.passthrough:
            return False
        if e.button == 3:
            self.finish_pen()
            return True
        if e.button != 1:
            return False

        tool = self.tool
        if tool == "select":
            o = self.topmost_at(x, y)
            self.selected = o
            if o is not None:
                self.push_undo()
                self.drag = ("move",)
                self.start = (x, y)
            self.queue_draw()
            return True
        if tool == "eraser":
            o = self.topmost_at(x, y)
            if o is not None:
                self.push_undo()
                self.objects.remove(o)
                if self.selected is o:
                    self.selected = None
            self.drag = ("erase",)
            self.queue_draw()
            return True
        if tool == "pencil":                       # le feutre
            self.push_undo()
            self.temp = self.new_obj("path", [(x, y)])
            self.drag = ("free",)
            return True
        if tool in ("rect", "ellipse", "line"):
            self.push_undo()
            self.temp = self.new_obj(tool, [(x, y), (x, y)])
            self.drag = ("create",)
            self.start = (x, y)
            return True
        return False

    def on_motion(self, w, e):
        if self.dormant:
            return False
        if self.drag is None:
            return False
        x, y = e.x, e.y
        k = self.drag[0]
        if k == "move" and self.selected:
            obj_translate(self.selected, x - self.start[0], y - self.start[1])
            self.start = (x, y)
        elif k == "free" and self.temp:
            self.temp["pts"].append((x, y))
        elif k == "create" and self.temp:
            self.temp["pts"][1] = (x, y)
        elif k == "erase":
            o = self.topmost_at(x, y)
            if o is not None:
                self.objects.remove(o)
        self.queue_draw()
        return True

    def on_release(self, w, e):
        if self.dormant:
            self._dot_pressed = False
            return True
        if self.drag and self.drag[0] in ("free", "create") and self.temp:
            keep = True
            if self.temp["type"] == "line":
                p = self.temp["pts"]
                keep = dist(p[0][0], p[0][1], p[1][0], p[1][1]) >= 3
            if self.temp["type"] == "path" and len(self.temp["pts"]) < 2:
                keep = False
            if keep:
                self.objects.append(self.temp)
                self.selected = self.temp
        self.temp = None
        self.drag = None
        self.queue_draw()
        return True

    def finish_pen(self):
        if self.pen_pts and len(self.pen_pts) >= 2:
            self.objects.append(self.new_obj("path", self.pen_pts[:]))
        self.pen_pts = None
        self.queue_draw()

    def on_scroll(self, w, e):
        if e.direction == Gdk.ScrollDirection.UP:
            self.set_width(self.width + 1)
        elif e.direction == Gdk.ScrollDirection.DOWN:
            self.set_width(self.width - 1)
        return True

    def on_key(self, w, e):
        k = e.keyval
        if k in (Gdk.KEY_Escape, Gdk.KEY_q):
            if self.pen_pts is not None:
                self.finish_pen()
            else:
                self.destroy()
        elif k in (Gdk.KEY_Delete, Gdk.KEY_BackSpace):
            self.delete_selected()
        elif k == Gdk.KEY_z:
            self.undo(); self.queue_draw()
        elif k == Gdk.KEY_y:
            self.redo(); self.queue_draw()
        elif k == Gdk.KEY_space:
            self.set_passthrough(not self.passthrough)
        else:
            m = {Gdk.KEY_b: "pencil", Gdk.KEY_l: "line", Gdk.KEY_r: "rect",
                 Gdk.KEY_e: "ellipse", Gdk.KEY_x: "eraser", Gdk.KEY_s: "select"}
            if k in m:
                self.tool = m[k]; self.finish_pen(); self.queue_draw()
        return True

    # ── rendu des objets ────────────────────────────────────────────────────
    def draw_obj(self, cr, o, ghost=False):
        pts = o["pts"]; r, g, b = o["stroke"]; a = 0.45 if ghost else 0.97
        cr.set_line_cap(cairo.LINE_CAP_ROUND); cr.set_line_join(cairo.LINE_JOIN_ROUND)

        def path():
            typ = o["type"]
            if typ in ("line", "path"):
                cr.move_to(*pts[0])
                for p in pts[1:]:
                    cr.line_to(*p)
            elif typ == "rect":
                x0, y0, x1, y1 = obj_bbox(o); cr.rectangle(x0, y0, x1 - x0, y1 - y0)
            elif typ == "ellipse":
                x0, y0, x1, y1 = obj_bbox(o)
                cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                rx, ry = max((x1 - x0) / 2, .5), max((y1 - y0) / 2, .5)
                cr.save(); cr.translate(cx, cy); cr.scale(rx, ry)
                cr.arc(0, 0, 1, 0, 2 * math.pi); cr.restore()

        if o.get("fill") and o["type"] in ("rect", "ellipse", "path"):
            path(); fr, fg, fb = o["fill"]
            cr.set_source_rgba(fr, fg, fb, 0.3 if ghost else 0.5); cr.fill()
        path(); cr.set_source_rgba(0, 0, 0, 0.5)
        cr.set_line_width(o["width"] + 2.5); cr.stroke()
        path(); cr.set_source_rgba(r, g, b, a)
        cr.set_line_width(o["width"]); cr.stroke()

    def on_draw(self, w, cr):
        a = self.get_allocation()

        # fond
        cr.set_operator(cairo.OPERATOR_SOURCE)
        if self.dormant:
            cr.set_source_rgba(0, 0, 0, 0.0)      # rien que la pastille
        else:
            cr.set_source_rgba(0, 0, 0, 0.0 if self.has_alpha else 0.08)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)

        if self.dormant:
            self.draw_dot(cr)
            return False

        self.layout_buttons(a.width, a.height)
        for o in self.objects:
            self.draw_obj(cr, o)
        if self.temp:
            self.draw_obj(cr, self.temp, ghost=True)

        # sélection
        sel = self.selected
        if sel is not None and sel in self.objects and self.tool == "select":
            x0, y0, x1, y1 = obj_bbox(sel)
            cr.set_dash([5, 4]); cr.set_line_width(1); cr.set_source_rgba(1, 1, 1, .8)
            cr.rectangle(x0 - 4, y0 - 4, x1 - x0 + 8, y1 - y0 + 8); cr.stroke(); cr.set_dash([])

        self.draw_toolbar(cr)

        if self.status and time.time() < self.status_until:
            self._text(cr, self.status, 18, 30, (1, 1, 1))
        return False

    # ── la pastille de rappel (état dormant) ───────────────────────────────
    def draw_dot(self, cr):
        cx, cy = self.dot_center()
        cr.arc(cx, cy, DOT_R, 0, 2 * math.pi)          # halo sombre
        cr.set_source_rgba(0, 0, 0, 0.5); cr.fill()
        cr.arc(cx, cy, DOT_R - 3, 0, 2 * math.pi)      # pastille couleur
        cr.set_source_rgba(*self.color, 0.95); cr.fill()
        cr.arc(cx, cy, DOT_R - 3, 0, 2 * math.pi)
        cr.set_source_rgba(1, 1, 1, 0.85); cr.set_line_width(1.5); cr.stroke()
        # petit trait de feutre en signe
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.set_line_width(2.4); cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.move_to(cx - 10, cy + 5)
        cr.curve_to(cx - 3, cy - 10, cx + 3, cy + 10, cx + 10, cy - 5)
        cr.stroke()

    # ── barre d'outils dessinée dans le canevas ────────────────────────────
    def draw_toolbar(self, cr):
        for bid, x, y, w, h in self.buttons:
            active = (bid == self.tool)
            # fond du bouton
            self._round_rect(cr, x, y, w, h, 9)
            if bid == "clear":
                cr.set_source_rgba(0.80, 0.12, 0.16, 0.92)
            elif active:
                cr.set_source_rgba(0.16, 0.55, 0.95, 0.95)
            else:
                cr.set_source_rgba(0.14, 0.15, 0.18, 0.85)
            cr.fill()
            self._round_rect(cr, x, y, w, h, 9)
            cr.set_source_rgba(1, 1, 1, 0.22); cr.set_line_width(1); cr.stroke()
            self.draw_icon(cr, bid, x, y, w, h)

    def draw_icon(self, cr, bid, x, y, w, h):
        cx, cy = x + w / 2, y + h / 2
        white = (0.95, 0.95, 0.97)
        cr.set_line_width(2.2); cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_source_rgba(*white, 1)

        if bid == "clear":
            self._glyph(cr, "C", cx, cy, 20)
        elif bid == "eraser":
            cr.save(); cr.translate(cx, cy); cr.rotate(-0.5)
            cr.rectangle(-11, -6, 22, 12); cr.stroke()
            cr.move_to(0, -6); cr.line_to(0, 6); cr.stroke(); cr.restore()
        elif bid == "color":
            cr.arc(cx, cy, 12, 0, 2 * math.pi)
            cr.set_source_rgba(*self.color, 1); cr.fill()
            cr.arc(cx, cy, 12, 0, 2 * math.pi)
            cr.set_source_rgba(1, 1, 1, .8); cr.set_line_width(1.5); cr.stroke()
        elif bid == "width_dn":
            cr.move_to(cx - 9, cy); cr.line_to(cx + 9, cy); cr.stroke()
        elif bid == "width_up":
            cr.move_to(cx - 9, cy); cr.line_to(cx + 9, cy)
            cr.move_to(cx, cy - 9); cr.line_to(cx, cy + 9); cr.stroke()
        elif bid == "ellipse":
            cr.save(); cr.translate(cx, cy); cr.scale(1.4, 1.0)
            cr.arc(0, 0, 9, 0, 2 * math.pi); cr.restore(); cr.stroke()
        elif bid == "rect":
            cr.rectangle(cx - 11, cy - 8, 22, 16); cr.stroke()
        elif bid == "line":
            cr.move_to(cx - 11, cy + 9); cr.line_to(cx + 11, cy - 9); cr.stroke()
        elif bid == "pencil":                       # feutre : petite vague
            cr.move_to(cx - 12, cy + 6)
            cr.curve_to(cx - 4, cy - 12, cx + 4, cy + 12, cx + 12, cy - 6)
            cr.stroke()
        elif bid == "select":
            cr.move_to(cx - 8, cy - 10); cr.line_to(cx - 8, cy + 8)
            cr.line_to(cx - 3, cy + 3); cr.line_to(cx + 1, cy + 11)
            cr.line_to(cx + 4, cy + 9); cr.line_to(cx, cy + 1)
            cr.line_to(cx + 7, cy + 1); cr.close_path(); cr.stroke()
        elif bid == "undo":
            cr.arc(cx, cy + 1, 9, math.radians(40), math.radians(300)); cr.stroke()
            cr.move_to(cx - 9, cy - 4); cr.line_to(cx - 12, cy + 2)
            cr.line_to(cx - 4, cy + 1); cr.close_path(); cr.fill()
        elif bid == "pass":
            cr.move_to(cx - 11, cy); cr.line_to(cx + 8, cy)
            cr.move_to(cx + 2, cy - 6); cr.line_to(cx + 10, cy); cr.line_to(cx + 2, cy + 6)
            cr.stroke()
            if self.passthrough:
                cr.set_source_rgba(0.2, 0.9, 0.35, 1)
                cr.arc(x + w - 9, y + 9, 4, 0, 2 * math.pi); cr.fill()
        elif bid == "quit":
            cr.move_to(cx - 8, cy - 8); cr.line_to(cx + 8, cy + 8)
            cr.move_to(cx + 8, cy - 8); cr.line_to(cx - 8, cy + 8); cr.stroke()

        # valeur d'épaisseur affichée sur les boutons − / +
        if bid == "width_up":
            self._text(cr, "%d" % self.width, x + 4, y - 4, (0.8, 0.85, 0.9), 12)

    def _round_rect(self, cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
        cr.close_path()

    def _glyph(self, cr, s, cx, cy, size):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(size)
        xb, yb, tw, th, _, _ = cr.text_extents(s)
        cr.move_to(cx - tw / 2 - xb, cy - yb - th / 2 + th)
        cr.show_text(s)

    def _text(self, cr, s, x, y, rgb, size=15):
        cr.select_font_face("monospace", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(size)
        cr.move_to(x + 1, y + 1); cr.set_source_rgba(0, 0, 0, .8); cr.show_text(s)
        cr.move_to(x, y); cr.set_source_rgba(*rgb, 1); cr.show_text(s)

    # ── export (bonus, touche non mappée dans la barre pour rester compact) ──
    def export(self):
        ts = time.strftime("%Y%m%d-%H%M%S")
        base = os.path.expanduser("~/overlay-draw-%s" % ts)
        a = self.get_allocation()
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, a.width, a.height)
        cr = cairo.Context(surf)
        for o in self.objects:
            self.draw_obj(cr, o)
        surf.write_to_png(base + ".png")
        self.flash("exporté %s.png" % base)


def main():
    Overlay()
    Gtk.main()


if __name__ == "__main__":
    main()
