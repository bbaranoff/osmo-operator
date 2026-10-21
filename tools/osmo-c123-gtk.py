#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""osmo-c123-gtk.py - le Motorola C123 emule, en photo : ecran LCD incruste, touches cliquables.

[2026-10-19] Le QEMU du depot (qosmo) n'a pas de backend gtk ; il publie l'ecran
ST7558 dans /dev/shm/calypso_lcd (hw/arm/calypso/calypso_st7558.c) et lit les
touches sur un socket Unix datagramme (/tmp/calypso_keys.sock,
calypso_armio.c). Cette fenetre GTK3 fait le reste :
  - la photo du telephone (data/c123.jpg ou .png ; sans photo, un schema) ;
    [2026-10-21] --modele c139 : data/c139.jpg + data/c139-zones.json et l'ecran
    couleur 96x64 publie par calypso_uwire.c (FreeCalypso Magnetite c139) ;
    auto (defaut) = d'apres le magic de l'image partagee ;
  - l'ecran 96x65 redessine a chaque changement, incruste dans la zone « lcd » ;
  - un clic sur une touche de la photo = press/release vers QEMU ; le clavier
    du PC marche aussi (0-9, * ou s, # ou h, fleches, Entree = menu,
    Entree pave ou o = ok, Echap ou p = power, F1/F2 = touches logicielles).
[2026-10-21] Plusieurs instances (c54x_exe/run.sh INSTANCE=N : ecran
/dev/shm/calypsoN/calypso_lcd, touches /tmp/calypso_keysN.sock). Sans
--instance, la fenetre choisit la premiere instance vivante qui N'EST PAS un
TRX de la BTS (firmware trx : /tmp/c54x-pontN/transceiver.log ou « BTS MODE »
dans osmocon.log) - le montage --bts --ms met le mobile en instance 2. La
touche power (rouge, Echap, p) eteint le firmware des l'appui (trx comme
layer1 : « Powering off due to keypress ») : elle n'est envoyee qu'apres un
APPUI LONG (%.1f s), et jamais a une instance TRX (le 21/10 a 08:18 un power
envoye a l'instance 1 a eteint le TRX et la BTS a perdu son horloge).
Zones : data/c123-zones.json (x, y, l, h normalises). `--calibrate` les
redefinit a la souris : pour chaque zone annoncee, cliquer le coin haut-gauche
puis le coin bas-droit ; `s` sauve, `q` quitte.

  /usr/bin/python3 tools/osmo-c123-gtk.py [--image PHOTO] [--zones JSON]
        [--instance N] [--lcd /dev/shm/calypso_lcd] [--keys /tmp/calypso_keys.sock]
        [--scale 2.5] [--calibrate] [--power-libre] [--toutes [1,2,3]]
(python3 systeme : celui de /root/.env n'a pas PyGObject.)
"""
import argparse
import json
import os
import socket
import struct
import sys
import time

try:
    import gi
except ModuleNotFoundError:
    # [2026-10-21] lance avec le python du venv (/root/.env : pas de PyGObject) : on se relance
    # avec le python systeme, qui a gi ; « pip install gi » n'est pas le bon paquet.
    if os.path.realpath(sys.executable) != os.path.realpath("/usr/bin/python3") and os.path.exists("/usr/bin/python3"):
        os.execv("/usr/bin/python3", ["/usr/bin/python3", os.path.abspath(__file__)] + sys.argv[1:])
    sys.stderr.write("PyGObject (gi) introuvable : apt install python3-gi gir1.2-gtk-3.0, et lancer avec /usr/bin/python3\n")
    sys.exit(1)
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf  # noqa: E402
import cairo  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
LCD_W, LCD_H, LCD_PAGES, LCD_HDR = 96, 65, 9, 32
POWER_APPUI_LONG_S = 1.2       # duree d'appui sur power avant de l'envoyer au firmware
__doc__ = __doc__ % POWER_APPUI_LONG_S
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


def rundir_instance(n):
    return "/tmp/c54x-pont" if n == 1 else "/tmp/c54x-pont%d" % n


def chemins_instance(n):
    """(ecran, socket des touches) de l'instance n (c54x_exe/run.sh : INSTANCE=1 sans suffixe)."""
    if n == 1:
        return "/dev/shm/calypso_lcd", "/tmp/calypso_keys.sock"
    return "/dev/shm/calypso%d/calypso_lcd" % n, "/tmp/calypso_keys%d.sock" % n


def instance_vivante(n):
    try:
        with open(os.path.join(rundir_instance(n), "dsp.pid")) as f:
            pid = int(f.read().strip() or 0)
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def instance_est_trx(n):
    """Vrai si l'instance n fait tourner le firmware trx (radio de la BTS) : un power l'eteint et la BTS
    perd son horloge. Indices : transceiver.log dans son RUNDIR (run.sh OSMO_TRX=1), ou « BTS MODE » sur
    sa console (trx.highram imprime BTS MODE: ... des le L1CTL_RESET)."""
    rd = rundir_instance(n)
    if os.path.isfile(os.path.join(rd, "transceiver.log")):
        return True
    try:
        with open(os.path.join(rd, "osmocon.log"), "rb") as f:
            return b"BTS MODE:" in f.read(1 << 20)
    except OSError:
        return False


def instance_par_defaut():
    """La premiere instance vivante qui n'est pas un TRX (le mobile du montage --bts --ms est la 2) ;
    a defaut la premiere vivante ; a defaut 1."""
    vivantes = [n for n in range(1, 9) if instance_vivante(n)]
    for n in vivantes:
        if not instance_est_trx(n):
            return n
    return vivantes[0] if vivantes else 1


def magic_lcd(path):
    """Le magic de l'image partagee : « C123LCD » (ST7558 mono) ou « C139LCD » (couleur), None si absente."""
    try:
        with open(path, "rb") as f:
            m = f.read(7)
    except OSError:
        return None
    return m.decode("ascii", "replace") if m in (b"C123LCD", b"C139LCD") else None


class Lcd:
    """L'image partagee : en-tete de 32 octets (magic, largeur, hauteur, pages ou octets/point, drapeaux,
    compteur) puis les points. Deux magics : « C123LCD » (calypso_st7558.c : 96 x 9 pages, 1 bit par point,
    bit 0 en haut) et « C139LCD » (calypso_uwire.c, Magnetite c139 : 96x64 RGB565 petit-boutiste)."""

    def __init__(self, path):
        self.path = path
        self.seq = -1
        self.flags = 0
        self.pages = b""
        self.w, self.h, self.modele = LCD_W, LCD_H, "c123"
        self.surface = cairo.ImageSurface(cairo.FORMAT_RGB24, self.w, self.h)
        self.vivant = False
        self._peindre()

    def lire(self):
        try:
            with open(self.path, "rb") as f:
                buf = f.read(LCD_HDR + 96 * 64 * 2)
        except OSError:
            if self.vivant:
                self.vivant = False
                return True
            return False
        if len(buf) < LCD_HDR + 8 or buf[:7] not in (b"C123LCD", b"C139LCD"):
            return False
        w, h, pages, flags, _pad, seq = struct.unpack_from("<HHHBBI", buf, 8)
        modele = "c139" if buf[:7] == b"C139LCD" else "c123"
        taille = w * h * pages if modele == "c139" else w * pages
        if not (1 <= w <= 256 and 1 <= h <= 256) or len(buf) < LCD_HDR + taille:
            return False
        if seq == self.seq and self.vivant:
            return False
        if (w, h, modele) != (self.w, self.h, self.modele):
            self.w, self.h, self.modele = w, h, modele
            self.surface = cairo.ImageSurface(cairo.FORMAT_RGB24, w, h)
        self.seq, self.flags, self.pages, self.vivant = seq, flags, buf[LCD_HDR:LCD_HDR + taille], True
        self._peindre()
        return True

    def _peindre(self):
        if self.modele == "c139":
            self._peindre_c139()
            return
        inverse, eteint = bool(self.flags & 1), bool(self.flags & 2)
        on, off = (0x1a2a1a, 0xc8d8b0) if not inverse else (0xc8d8b0, 0x1a2a1a)
        if eteint or not self.vivant:
            on = off = 0x9aa892
        data = self.surface.get_data()
        stride = self.surface.get_stride()
        pages = self.pages
        for y in range(self.h):
            page, mask = y >> 3, 1 << (y & 7)
            base = page * self.w
            for x in range(self.w):
                bit = pages[base + x] & mask if pages else 0
                c = on if bit else off
                o = y * stride + x * 4
                data[o:o + 4] = struct.pack("<I", c)
        self.surface.mark_dirty()

    def _peindre_c139(self):
        """RGB565 -> RGB24 ; sans QEMU : gris uniforme."""
        data = self.surface.get_data()
        stride = self.surface.get_stride()
        src = self.pages
        for y in range(self.h):
            for x in range(self.w):
                if src and self.vivant:
                    i = (y * self.w + x) * 2
                    p = src[i] | (src[i + 1] << 8)
                    r, g, b = (p >> 11) & 0x1f, (p >> 5) & 0x3f, p & 0x1f
                    c = ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
                else:
                    c = 0x9aa892
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


FENETRES = []


def fenetre_fermee(_w):
    """Une fenetre fermee ; Gtk.main s'arrete avec la derniere."""
    if _w in FENETRES:
        FENETRES.remove(_w)
    if not FENETRES:
        Gtk.main_quit()


class Fenetre(Gtk.Window):
    def __init__(self, args):
        # [2026-10-21] --modele c139 (FreeCalypso Magnetite) : photo data/c139.jpg, zones data/c139-zones.json,
        # ecran couleur « C139LCD » ; auto = d'apres le magic de l'image partagee, c123 a defaut.
        self.modele = args.modele
        if self.modele == "auto":
            self.modele = "c139" if magic_lcd(args.lcd) == "C139LCD" else "c123"
        if not args.zones:
            args.zones = os.path.join(DATA, "%s-zones.json" % self.modele)
        self.modele_force = args.modele != "auto"
        self.args = args
        super().__init__(title=self._titre())
        self.zones = self._charger_zones(args.zones)
        self.pixbuf = self._charger_image(args.image)
        self.lcd = Lcd(args.lcd)
        self.clavier = Clavier(args.keys)
        self.enfoncees = set()
        # un C139 Magnetite n'est jamais un TRX de la BTS (les traces trx d'un ancien run ne comptent pas)
        self.trx = instance_est_trx(args.instance) if args.instance and self.modele != "c139" else False
        self.power_depuis = None      # instant de l'appui sur power (appui long en cours)
        self.power_envoyee = False    # press power deja transmis au firmware
        self.calibrage = [] if args.calibrate else None   # [(zone, x1, y1)] en cours
        self.cal_index = 0
        self.cal_premier = None

        self.lw, self.lh = self._taille()

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
        self.connect("destroy", fenetre_fermee)
        GLib.timeout_add(40, self.tic)
        self._statut()

    # --- chargements -------------------------------------------------------
    def _titre(self):
        role = "TRX de la BTS" if (self.args.instance and instance_est_trx(self.args.instance)) else "mobile"
        if self.modele == "c139":
            role = "mobile Magnetite"
        titre = "Motorola %s - Calypso emule" % self.modele.upper()
        if self.args.instance:
            titre += " - instance %d (%s)" % (self.args.instance, role)
        return titre

    def _taille(self):
        if self.pixbuf:
            iw, ih = self.pixbuf.get_width(), self.pixbuf.get_height()
        else:
            iw, ih = 300, 630
        scale = self.args.scale or min(2.5, 900.0 / ih)
        return int(iw * scale), int(ih * scale)

    def _changer_modele(self, modele):
        """[2026-10-21] l'ecran partage change de magic (ex. --bts --ms-magnetite : l'instance 2
        devient un C139 Magnetite apres l'ouverture de la fenetre) : photo, zones, taille et titre suivent."""
        self.modele = modele
        self.args.zones = os.path.join(DATA, "%s-zones.json" % modele)
        self.zones = self._charger_zones(self.args.zones)
        self.pixbuf = self._charger_image(None)
        self.lw, self.lh = self._taille()
        self.zone.set_size_request(self.lw, self.lh)
        self.resize(self.lw, self.lh + 24)
        self.set_title(self._titre())
        self._statut("modele %s (ecran %dx%d)" % (modele, self.lcd.w, self.lcd.h))

    def _charger_zones(self, path):
        with open(path) as f:
            z = json.load(f)
        return {k: v for k, v in z.items() if not k.startswith("_")}

    def _charger_image(self, path):
        candidats = [path] if path else [os.path.join(DATA, self.modele + ext) for ext in (".jpg", ".png", ".jpeg")]
        for p in candidats:
            if p and os.path.isfile(p):
                try:
                    return GdkPixbuf.Pixbuf.new_from_file(p)
                except GLib.Error as e:
                    print("photo illisible %s : %s" % (p, e), file=sys.stderr)
        print("pas de photo (%s) : schema dessine a la place ; posez la photo du %s dans data/%s.jpg"
              % (", ".join(c for c in candidats if c), self.modele.upper(), self.modele), file=sys.stderr)
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
        cr.scale(w / self.lcd.w, h / self.lcd.h)
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
            self.appuyer(nom)
        return True

    def relacher(self, _w, ev):
        if self.calibrage is not None:
            return True
        for nom in list(self.enfoncees):
            self.lacher(nom)
        self.zone.queue_draw()
        return True

    # --- touches : press/release vers QEMU, power sous appui long ---------
    def appuyer(self, nom):
        if nom in self.enfoncees:
            return
        self.enfoncees.add(nom)
        if nom == "power" and not self.args.power_libre:
            self.power_depuis = time.monotonic()
            self.power_envoyee = False
            if self.trx:
                self._statut("power ignoree : l'instance %s est le TRX de la BTS (un power l'eteint et la BTS perd son horloge)"
                             % self.args.instance)
            else:
                self._statut("power : maintenir %.1f s pour eteindre le firmware" % POWER_APPUI_LONG_S)
        else:
            self.clavier.envoyer("press", nom)
            self._statut("touche %s" % nom)
        self.zone.queue_draw()

    def lacher(self, nom):
        if nom not in self.enfoncees:
            return
        self.enfoncees.discard(nom)
        if nom == "power" and not self.args.power_libre:
            if self.power_envoyee:
                self.clavier.envoyer("release", nom)
            elif not self.trx:
                self._statut("power relachee avant %.1f s : rien envoye" % POWER_APPUI_LONG_S)
            self.power_depuis = None
            self.power_envoyee = False
        else:
            self.clavier.envoyer("release", nom)
        self.zone.queue_draw()

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
            self.appuyer(nom)
        else:
            self.lacher(nom)
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
                     "recalibrer : osmo-c123-gtk.py --modele %s --calibrate" % self.modele}
        z.update({k: self.zones[k] for k in ORDRE_ZONES if k in self.zones})
        with open(self.args.zones, "w") as f:
            json.dump(z, f, indent=2)
        self._statut("zones sauvees dans %s" % self.args.zones)

    # --- boucle ------------------------------------------------------------
    def tic(self):
        if self.lcd.vivant and not self.modele_force and self.lcd.modele != self.modele:
            self._changer_modele(self.lcd.modele)
        if self.lcd.lire():
            self.zone.queue_draw()
            self._statut()
        if (self.power_depuis is not None and not self.power_envoyee and not self.trx
                and time.monotonic() - self.power_depuis >= POWER_APPUI_LONG_S):
            self.power_envoyee = True
            self.clavier.envoyer("press", "power")
            self._statut("power envoyee a l'instance %s (appui long)" % self.args.instance)
        return True

    def _statut(self, msg=None):
        if self.calibrage is not None and msg is None:
            msg = "calibrage : %s : coin haut-gauche" % ORDRE_ZONES[0]
        etat = "LCD %s (v%d)" % ("vivant" if self.lcd.vivant else "absent", max(self.lcd.seq, 0))
        clav = "touches -> %s%s" % (self.args.keys, " (%s)" % self.clavier.erreur if self.clavier.erreur else "")
        inst = "instance %s%s · " % (self.args.instance, " (TRX de la BTS)" if self.trx else "") if self.args.instance else ""
        self.statut.set_text("%s%s · %s%s" % (inst, etat, clav, " · " + msg if msg else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--modele", choices=["auto", "c123", "c139"], default="auto",
                    help="telephone : c123 (ST7558 mono, osmocom-bb) ou c139 (ecran couleur, FreeCalypso Magnetite) ; "
                         "auto = d'apres l'ecran partage (defaut)")
    ap.add_argument("--image", help="photo du telephone (defaut data/<modele>.jpg|png)")
    ap.add_argument("--zones", default=None, help="zones cliquables (defaut data/<modele>-zones.json)")
    ap.add_argument("--instance", type=int, default=0,
                    help="instance c54x_exe (1 = /dev/shm/calypso_lcd, N = /dev/shm/calypsoN/... et /tmp/calypso_keysN.sock) ; "
                         "defaut : la premiere instance vivante qui n'est pas un TRX de la BTS")
    ap.add_argument("--lcd", default=os.environ.get("CALYPSO_LCD_SHM"), help="ecran partage (prime sur --instance)")
    ap.add_argument("--keys", default=os.environ.get("CALYPSO_KEYS_SOCK"), help="socket des touches (prime sur --instance)")
    ap.add_argument("--power-libre", action="store_true",
                    help="touche power envoyee des l'appui, meme a un TRX (defaut : appui long de %.1f s, jamais a un TRX)"
                         % POWER_APPUI_LONG_S)
    ap.add_argument("--toutes", nargs="?", const="1,2,3,4", metavar="N,M,...",
                    help="une fenetre par instance (defaut 1,2,3,4 : TRX TS0, mobile, TRX TS1, rssi ; plus toute autre instance vivante, et celles qui "
                         "apparaissent ensuite : guet toutes les 2 s), cote a cote")
    ap.add_argument("--scale", type=float, default=0, help="facteur d'agrandissement de la photo (defaut : hauteur 900 px max)")
    ap.add_argument("--calibrate", action="store_true", help="redefinir les zones a la souris")
    ap.add_argument("--autotest", action="store_true", help="sans fenetre : lit l'image LCD une fois et sort")
    args = ap.parse_args()
    if args.toutes:
        if args.calibrate or args.autotest:
            ap.error("--toutes ne va pas avec --calibrate / --autotest")
        voulues = [int(x) for x in args.toutes.replace(" ", ",").split(",") if x]
        for n in range(1, 9):
            if n not in voulues and instance_vivante(n):
                voulues.append(n)
        ouvertes = {}
        pos = [0]

        def ouvrir(n):
            a = argparse.Namespace(**vars(args))
            a.instance, a.lcd, a.keys = n, None, None
            a.lcd, a.keys = chemins_instance(n)
            if not args.scale:
                a.scale = 1.1                      # quatre telephones de front sur un ecran 1080p
            f = Fenetre(a)
            FENETRES.append(f)
            ouvertes[n] = f
            f.move(pos[0], 0)
            pos[0] += f.lw + 24
            f.show_all()

        for n in voulues:
            ouvrir(n)

        # [2026-10-21] une instance lancee APRES la fenetre (banc-rssi, INSTANCE=4...) avait pas de fenetre :
        # on guette les instances 1..8 toutes les 2 s et on ouvre celles qui apparaissent.
        def guetter():
            for n in range(1, 9):
                if n not in ouvertes and instance_vivante(n):
                    print("instance %d apparue : fenetre ouverte" % n, file=sys.stderr)
                    ouvrir(n)
            return True
        GLib.timeout_add(2000, guetter)
        Gtk.main()
        return 0
    if not args.instance and not (args.lcd and args.keys):
        args.instance = instance_par_defaut()
    if args.instance:
        lcd, keys = chemins_instance(args.instance)
        args.lcd = args.lcd or lcd
        args.keys = args.keys or keys
        if instance_est_trx(args.instance):
            print("instance %d : firmware trx (TRX de la BTS) ; touche power refusee sans --power-libre" % args.instance,
                  file=sys.stderr)
    if args.autotest:
        lcd = Lcd(args.lcd)
        ok = lcd.lire()
        print("lcd %s : vivant=%s seq=%d flags=%d" % (args.lcd, lcd.vivant, lcd.seq, lcd.flags))
        return 0 if ok else 1
    f = Fenetre(args)
    FENETRES.append(f)
    f.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
