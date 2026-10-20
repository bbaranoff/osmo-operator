#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""osmo-c123-gtk.py - le Motorola C123 emule, en photo : ecran LCD incruste, touches cliquables.

[2026-10-19] Le QEMU du depot (qosmo) n'a pas de backend gtk ; il publie l'ecran
ST7558 dans /dev/shm/calypso_lcd (hw/arm/calypso/calypso_st7558.c) et lit les
touches sur un socket Unix datagramme (/tmp/calypso_keys.sock,
calypso_armio.c). Cette fenetre GTK3 fait le reste :
  - la photo du telephone (data/c123.jpg ou .png ; sans photo, un schema) ;
  - l'ecran 96x65 redessine a chaque changement, incruste dans la zone « lcd » ;
  - un clic sur une touche de la photo = press/release vers QEMU ; le clavier
    du PC marche aussi (0-9, * ou s, # ou h, fleches, Entree = menu,
    Entree pave ou o = ok, Echap ou p = power, F1/F2 = touches logicielles).
Zones : data/c123-zones.json (x, y, l, h normalises). `--calibrate` les
redefinit a la souris : pour chaque zone annoncee, cliquer le coin haut-gauche
puis le coin bas-droit ; `s` sauve, `q` quitte.

  /usr/bin/python3 tools/osmo-c123-gtk.py [--image PHOTO] [--zones JSON]
        [--lcd /dev/shm/calypso_lcd] [--keys /tmp/calypso_keys.sock]
        [--scale 2.5] [--calibrate]
(python3 systeme : celui de /root/.env n'a pas PyGObject.)
"""
import argparse
import json
import os
import socket
import struct
import sys
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf  # noqa: E402
import cairo  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
LCD_W, LCD_H, LCD_PAGES, LCD_HDR = 96, 65, 9, 32
ORDRE_ZONES = ["lcd", "lsb", "rsb", "up", "left", "menu", "right", "down", "ok", "power",
               "1", "2", "3", "4", "5", "6", "7", "8", "9", "star", "0", "hash"]
LIBELLES = {"lsb": "─", "rsb": "─", "up": "▲", "down": "▼", "left": "◀", "right": "▶",
            "menu": "●", "ok": "☎", "power": "⏻", "star": "*", "hash": "#"}
CLAVIER = {  # nom de touche GDK -> touche du C123
    "0": "0", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
    "KP_0": "0", "KP_1": "1", "KP_2": "2", "KP_3": "3", "KP_4": "4", "KP_5": "5", "KP_6": "6",
    "KP_7": "7", "KP_8": "8", "KP_9": "9", "asterisk": "star", "KP_Multiply": "star", "s": "star",
    "numbersign": "hash", "h": "hash", "Up": "up", "Down": "down", "Left": "left", "Right": "right",
    "Return": "menu", "KP_Enter": "ok", "o": "ok", "Escape": "power", "p": "power",
    "F1": "lsb", "F2": "rsb",
}


class Lcd:
    """L'image partagee ecrite par calypso_st7558.c : en-tete de 32 octets puis 96 x 9 pages."""

    def __init__(self, path):
        self.path = path
        self.seq = -1
        self.flags = 0
        self.pages = b""
        self.surface = cairo.ImageSurface(cairo.FORMAT_RGB24, LCD_W, LCD_H)
        self.vivant = False
        self._peindre()

    def lire(self):
        try:
            with open(self.path, "rb") as f:
                buf = f.read(LCD_HDR + LCD_W * LCD_PAGES)
        except OSError:
            if self.vivant:
                self.vivant = False
                return True
            return False
        if len(buf) < LCD_HDR + LCD_W * LCD_PAGES or buf[:7] != b"C123LCD":
            return False
        w, h, pages, flags, _pad, seq = struct.unpack_from("<HHHBBI", buf, 8)
        if seq == self.seq and self.vivant:
            return False
        self.seq, self.flags, self.pages, self.vivant = seq, flags, buf[LCD_HDR:], True
        self._peindre()
        return True

    def _peindre(self):
        inverse, eteint = bool(self.flags & 1), bool(self.flags & 2)
        on, off = (0x1a2a1a, 0xc8d8b0) if not inverse else (0xc8d8b0, 0x1a2a1a)
        if eteint or not self.vivant:
            on = off = 0x9aa892
        data = self.surface.get_data()
        stride = self.surface.get_stride()
        pages = self.pages
        for y in range(LCD_H):
            page, mask = y >> 3, 1 << (y & 7)
            base = page * LCD_W
            for x in range(LCD_W):
                bit = pages[base + x] & mask if pages else 0
                c = on if bit else off
                o = y * stride + x * 4
                data[o:o + 4] = struct.pack("<I", c)
        self.surface.mark_dirty()


class Clavier:
    """Le socket datagramme de calypso_armio.c : « press X », « release X », « tap X ms »."""

    def __init__(self, path):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.erreur = None

    def envoyer(self, cmd, touche):
        try:
            self.sock.sendto(("%s %s\n" % (cmd, touche)).encode(), self.path)
            self.erreur = None
            return True
        except OSError as e:
            self.erreur = str(e)
            return False


class Fenetre(Gtk.Window):
    def __init__(self, args):
        super().__init__(title="Motorola C123 - Calypso emule")
        self.args = args
        self.zones = self._charger_zones(args.zones)
        self.pixbuf = self._charger_image(args.image)
        self.lcd = Lcd(args.lcd)
        self.clavier = Clavier(args.keys)
        self.enfoncees = set()
        self.calibrage = [] if args.calibrate else None   # [(zone, x1, y1)] en cours
        self.cal_index = 0
        self.cal_premier = None

        if self.pixbuf:
            iw, ih = self.pixbuf.get_width(), self.pixbuf.get_height()
        else:
            iw, ih = 300, 630
        scale = args.scale or min(2.5, 900.0 / ih)
        self.lw, self.lh = int(iw * scale), int(ih * scale)

        boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(boite)
        self.zone = Gtk.DrawingArea()
        self.zone.set_size_request(self.lw, self.lh)
        self.zone.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
                             | Gdk.EventMask.POINTER_MOTION_MASK)
        self.zone.connect("draw", self.dessiner)
        self.zone.connect("button-press-event", self.clic)
        self.zone.connect("button-release-event", self.relacher)
        boite.pack_start(self.zone, True, True, 0)
        self.statut = Gtk.Label(xalign=0)
        self.statut.set_margin_start(6)
        boite.pack_start(self.statut, False, False, 2)
        self.connect("key-press-event", self.touche_pc)
        self.connect("key-release-event", self.touche_pc)
        self.connect("destroy", Gtk.main_quit)
        GLib.timeout_add(40, self.tic)
        self._statut()

    # --- chargements -------------------------------------------------------
    def _charger_zones(self, path):
        with open(path) as f:
            z = json.load(f)
        return {k: v for k, v in z.items() if not k.startswith("_")}

    def _charger_image(self, path):
        candidats = [path] if path else [os.path.join(DATA, "c123.jpg"), os.path.join(DATA, "c123.png"),
                                         os.path.join(DATA, "c123.jpeg")]
        for p in candidats:
            if p and os.path.isfile(p):
                try:
                    return GdkPixbuf.Pixbuf.new_from_file(p)
                except GLib.Error as e:
                    print("photo illisible %s : %s" % (p, e), file=sys.stderr)
        print("pas de photo (%s) : schema dessine a la place ; posez la photo du C123 dans data/c123.jpg"
              % ", ".join(c for c in candidats if c), file=sys.stderr)
        return None

    # --- geometrie ---------------------------------------------------------
    def rect(self, nom):
        x, y, w, h = self.zones[nom]
        return x * self.lw, y * self.lh, w * self.lw, h * self.lh

    def zone_sous(self, px, py):
        for nom in self.zones:
            if nom == "lcd":
                continue
            x, y, w, h = self.rect(nom)
            if x <= px <= x + w and y <= py <= y + h:
                return nom
        return None

    # --- dessin ------------------------------------------------------------
    def dessiner(self, _w, cr):
        if self.pixbuf:
            cr.save()
            cr.scale(self.lw / self.pixbuf.get_width(), self.lh / self.pixbuf.get_height())
            Gdk.cairo_set_source_pixbuf(cr, self.pixbuf, 0, 0)
            cr.paint()
            cr.restore()
        else:
            self._schema(cr)
        # l'ecran
        x, y, w, h = self.rect("lcd")
        cr.save()
        cr.translate(x, y)
        cr.scale(w / LCD_W, h / LCD_H)
        cr.set_source_surface(self.lcd.surface, 0, 0)
        cr.get_source().set_filter(cairo.FILTER_NEAREST)
        cr.paint()
        cr.restore()
        if not self.lcd.vivant:
            cr.set_source_rgba(0, 0, 0, 0.55)
            cr.rectangle(x, y, w, h)
            cr.fill()
            cr.set_source_rgb(1, 1, 1)
            cr.set_font_size(max(10, h / 6))
            cr.move_to(x + 6, y + h / 2)
            cr.show_text("QEMU absent")
        # touches enfoncees
        for nom in self.enfoncees:
            if nom in self.zones:
                x, y, w, h = self.rect(nom)
                cr.set_source_rgba(1.0, 0.85, 0.1, 0.45)
                cr.rectangle(x, y, w, h)
                cr.fill()
        # calibrage : zones deja posees + zone en cours
        if self.calibrage is not None:
            cr.set_line_width(1.5)
            for nom in self.zones:
                x, y, w, h = self.rect(nom)
                cr.set_source_rgba(0.1, 0.6, 1.0, 0.8)
                cr.rectangle(x, y, w, h)
                cr.stroke()
                cr.move_to(x + 2, y + h - 2)
                cr.set_font_size(10)
                cr.show_text(nom)
            if self.cal_premier:
                cr.set_source_rgba(1, 0, 0, 0.9)
                cr.arc(self.cal_premier[0], self.cal_premier[1], 4, 0, 6.3)
                cr.fill()
        return False

    def _schema(self, cr):
        cr.set_source_rgb(0.82, 0.82, 0.84)
        cr.rectangle(0, 0, self.lw, self.lh)
        cr.fill()
        cr.set_source_rgb(0.25, 0.25, 0.28)
        cr.rectangle(self.lw * 0.04, self.lh * 0.02, self.lw * 0.92, self.lh * 0.96)
        cr.fill()
        for nom in self.zones:
            if nom == "lcd":
                continue
            x, y, w, h = self.rect(nom)
            cr.set_source_rgb(0.85, 0.85, 0.87)
            cr.rectangle(x, y, w, h)
            cr.fill()
            cr.set_source_rgb(0.1, 0.1, 0.1)
            cr.set_font_size(max(9, h * 0.6))
            cr.move_to(x + w * 0.3, y + h * 0.75)
            cr.show_text(LIBELLES.get(nom, nom))

    # --- entrees -----------------------------------------------------------
    def clic(self, _w, ev):
        if self.calibrage is not None:
            return self._clic_calibrage(ev)
        nom = self.zone_sous(ev.x, ev.y)
        if nom:
            self.enfoncees.add(nom)
            self.clavier.envoyer("press", nom)
            self._statut("touche %s" % nom)
            self.zone.queue_draw()
        return True

    def relacher(self, _w, ev):
        if self.calibrage is not None:
            return True
        for nom in list(self.enfoncees):
            self.clavier.envoyer("release", nom)
        self.enfoncees.clear()
        self.zone.queue_draw()
        return True

    def touche_pc(self, _w, ev):
        nom_gdk = Gdk.keyval_name(ev.keyval)
        if self.calibrage is not None:
            if ev.type == Gdk.EventType.KEY_PRESS and nom_gdk == "s":
                self._sauver_zones()
            elif ev.type == Gdk.EventType.KEY_PRESS and nom_gdk == "q":
                Gtk.main_quit()
            return True
        nom = CLAVIER.get(nom_gdk)
        if not nom:
            return False
        if ev.type == Gdk.EventType.KEY_PRESS:
            if nom not in self.enfoncees:
                self.enfoncees.add(nom)
                self.clavier.envoyer("press", nom)
        else:
            self.enfoncees.discard(nom)
            self.clavier.envoyer("release", nom)
        self.zone.queue_draw()
        return True

    # --- calibrage ---------------------------------------------------------
    def _clic_calibrage(self, ev):
        if self.cal_index >= len(ORDRE_ZONES):
            self._statut("calibrage termine : s = sauver, q = quitter")
            return True
        nom = ORDRE_ZONES[self.cal_index]
        if self.cal_premier is None:
            self.cal_premier = (ev.x, ev.y)
            self._statut("%s : coin bas-droit" % nom)
        else:
            x1, y1 = self.cal_premier
            x2, y2 = ev.x, ev.y
            self.zones[nom] = [round(min(x1, x2) / self.lw, 4), round(min(y1, y2) / self.lh, 4),
                               round(abs(x2 - x1) / self.lw, 4), round(abs(y2 - y1) / self.lh, 4)]
            self.cal_premier = None
            self.cal_index += 1
            if self.cal_index < len(ORDRE_ZONES):
                self._statut("%s : coin haut-gauche" % ORDRE_ZONES[self.cal_index])
            else:
                self._statut("calibrage termine : s = sauver, q = quitter")
        self.zone.queue_draw()
        return True

    def _sauver_zones(self):
        z = {"_doc": "Zones cliquables de la photo du C123, [x, y, largeur, hauteur] normalises ; "
                     "recalibrer : osmo-c123-gtk.py --calibrate"}
        z.update({k: self.zones[k] for k in ORDRE_ZONES if k in self.zones})
        with open(self.args.zones, "w") as f:
            json.dump(z, f, indent=2)
        self._statut("zones sauvees dans %s" % self.args.zones)

    # --- boucle ------------------------------------------------------------
    def tic(self):
        if self.lcd.lire():
            self.zone.queue_draw()
            self._statut()
        return True

    def _statut(self, msg=None):
        if self.calibrage is not None and msg is None:
            msg = "calibrage : %s : coin haut-gauche" % ORDRE_ZONES[0]
        etat = "LCD %s (v%d)" % ("vivant" if self.lcd.vivant else "absent", max(self.lcd.seq, 0))
        clav = "touches -> %s%s" % (self.args.keys, " (%s)" % self.clavier.erreur if self.clavier.erreur else "")
        self.statut.set_text("%s · %s%s" % (etat, clav, " · " + msg if msg else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", help="photo du telephone (defaut data/c123.jpg|png)")
    ap.add_argument("--zones", default=os.path.join(DATA, "c123-zones.json"))
    ap.add_argument("--lcd", default=os.environ.get("CALYPSO_LCD_SHM", "/dev/shm/calypso_lcd"))
    ap.add_argument("--keys", default=os.environ.get("CALYPSO_KEYS_SOCK", "/tmp/calypso_keys.sock"))
    ap.add_argument("--scale", type=float, default=0, help="facteur d'agrandissement de la photo (defaut : hauteur 900 px max)")
    ap.add_argument("--calibrate", action="store_true", help="redefinir les zones a la souris")
    ap.add_argument("--autotest", action="store_true", help="sans fenetre : lit l'image LCD une fois et sort")
    args = ap.parse_args()
    if args.autotest:
        lcd = Lcd(args.lcd)
        ok = lcd.lire()
        print("lcd %s : vivant=%s seq=%d flags=%d" % (args.lcd, lcd.vivant, lcd.seq, lcd.flags))
        return 0 if ok else 1
    f = Fenetre(args)
    f.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
