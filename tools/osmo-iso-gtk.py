#!/usr/bin/python3
# osmo-iso-gtk.py - BUILD AN IMAGE OF THE BENCH, IN A GTK WINDOW (« osmo-iso »).
#
# A form in front of build-iso.sh: what to build - an ISO for a PC (amd64) or
# an SD image for ARM boards (arm64, Raspberry Pi 4 / Orange Pi 5 through
# armbian/build-armbian.sh) - its variant and options, where to write it. The
# command line is shown as it will run. « Construire » hands it to
# tools/osmo-gtk-run.py --root --progress: the password once (pkexec), a
# progress bar fed by the « [n/9] » markers of build-iso.sh, the complete
# console behind a button, the window kept open at the end to read the result.
#
# Also shown: free space where the build works (/var/tmp, OSMO_ISO_WORK) and
# where the image goes, the leftover work folders of past builds
# (/var/tmp/iso-build-*, removable here), and the images already in the
# output folder.
#
# Runs as the desktop user; only the build itself is root.
import os
import shlex
import shutil
import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # noqa: E402

REPO = os.environ.get("OSMO_REPO") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BUILD = os.path.join(REPO, "build-iso.sh")
RUN = os.path.join(REPO, "tools", "osmo-gtk-run.py")
WORK = os.environ.get("OSMO_ISO_WORK", "/var/tmp")
SORTIE_DEFAUT = os.path.expanduser("~/osmo-images")

VARIANTES = [          # (label, options)
    ("Bureau GNOME + installeur (desktop)", ["--desktop"]),
    ("Operateur, sans bureau", ["--role=operator"]),
    ("Lite (sans les sources de /opt/GSM)", ["--lite"]),
    ("Hub SS7 seul (interstp)", ["--role=interstp"]),
    ("Les quatre d'un coup (--all)", ["--all"]),
]
CARTES = [("rpi4", "Raspberry Pi 4"), ("opi5", "Orange Pi 5 (toute la famille)")]
DOCKER = [
    ("Tirer l'image publiee, sinon la construire (defaut)", []),
    ("Tirer obligatoirement (--skip-build)", ["--skip-build"]),
    ("Construire ici (--build-docker, long)", ["--build-docker"]),
]

CSS = b"""
.osmo-iso { background-color: #0b0e14; }
.osmo-iso label { color: #e6edf3; font: 10pt "Ubuntu"; }
.osmo-iso label.titre { color: #58a6ff; font: bold 14pt "Ubuntu"; }
.osmo-iso label.section { color: #58a6ff; font: bold 10pt "Ubuntu"; }
.osmo-iso label.aide { color: #8b949e; font: 9pt "Ubuntu"; }
.osmo-iso label.cmd { color: #c9d1d9; font: 9pt "Ubuntu Mono"; background: #161b22;
                      padding: 8px; border-radius: 6px; }
.osmo-iso label.ok { color: #3fb950; }
.osmo-iso label.ko { color: #f85149; }
.osmo-iso frame { border: 1px solid rgba(88,166,255,0.25); border-radius: 8px; padding: 6px; }
.osmo-iso frame > border { border: none; }
.osmo-iso button { background: rgba(22,27,34,0.9); color: #e6edf3; border: 1px solid rgba(88,166,255,0.3);
                   border-radius: 6px; padding: 4px 12px; }
.osmo-iso button:hover { border-color: #58a6ff; }
.osmo-iso button.go { background: #1f6feb; border: none; font: bold 11pt "Ubuntu"; padding: 8px 24px; }
.osmo-iso button.go:hover { background: #388bfd; }
.osmo-iso entry, .osmo-iso spinbutton, .osmo-iso combobox button {
                   background: #161b22; color: #e6edf3; border: 1px solid #30363d; border-radius: 6px; }
.osmo-iso radiobutton label, .osmo-iso checkbutton label { color: #e6edf3; }
"""


def taille(octets):
    for u in ("o", "Ko", "Mo", "Go", "To"):
        if octets < 1024 or u == "To":
            return ("%.1f %s" % (octets, u)).replace(".0 ", " ")
        octets /= 1024.0


def libre(chemin):
    while chemin and not os.path.exists(chemin):
        chemin = os.path.dirname(chemin)
    try:
        return shutil.disk_usage(chemin or "/").free
    except OSError:
        return 0


def du(chemin):
    try:
        out = subprocess.run(["du", "-sb", chemin], capture_output=True, text=True, timeout=20).stdout
        return int(out.split()[0])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return 0


class Fenetre(Gtk.Window):
    def __init__(self):
        super().__init__(title="osmo-iso : construire une image du banc")
        self.set_default_size(820, 760)
        self.get_style_context().add_class("osmo-iso")
        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        sc = Gtk.ScrolledWindow()
        sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.add(sc)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=18)
        sc.add(box)

        t = Gtk.Label(label="Construire une image du banc", xalign=0)
        t.get_style_context().add_class("titre")
        box.pack_start(t, False, False, 0)
        a = Gtk.Label(label="build-iso.sh, en root (mot de passe une fois). Une ISO pour un PC, "
                            "ou une image SD pour carte ARM.", xalign=0, wrap=True)
        a.get_style_context().add_class("aide")
        box.pack_start(a, False, False, 0)

        # ── the target ──────────────────────────────────────────────────────
        cible = self.section(box, "Cible")
        hb = Gtk.Box(spacing=18)
        self.r_iso = Gtk.RadioButton.new_with_label(None, "ISO pour PC (amd64)")
        self.r_arm = Gtk.RadioButton.new_with_label_from_widget(self.r_iso, "Image SD pour carte ARM (arm64)")
        hb.pack_start(self.r_iso, False, False, 0)
        hb.pack_start(self.r_arm, False, False, 0)
        cible.pack_start(hb, False, False, 0)

        # amd64
        self.p_iso = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        g = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.variante = Gtk.ComboBoxText()
        for lab, _ in VARIANTES:
            self.variante.append_text(lab)
        self.variante.set_active(0)
        self.noeud = Gtk.SpinButton.new_with_range(1, 99, 1)
        self.version = Gtk.ComboBoxText()
        for v in ("24.04", "22.04"):
            self.version.append_text(v)
        self.version.set_active(0)
        self.ligne(g, 0, "Variante", self.variante)
        self.ligne(g, 1, "Numero du noeud", self.noeud)
        self.ligne(g, 2, "Ubuntu", self.version)
        self.p_iso.pack_start(g, False, False, 0)
        cible.pack_start(self.p_iso, False, False, 0)

        # arm64
        self.p_arm = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.cartes = {}
        for k, lab in CARTES:
            c = Gtk.CheckButton(label=lab)
            c.set_active(True)
            self.cartes[k] = c
            self.p_arm.pack_start(c, False, False, 0)
        self.arm_bureau = Gtk.CheckButton(label="Bureau GNOME + bureau du banc (--desktop)")
        self.p_arm.pack_start(self.arm_bureau, False, False, 0)
        h = Gtk.Label(label="Premier build arm64 : emulation aarch64, compter une dizaine d'heures.",
                      xalign=0, wrap=True)
        h.get_style_context().add_class("aide")
        self.p_arm.pack_start(h, False, False, 0)
        cible.pack_start(self.p_arm, False, False, 0)

        # ── options ─────────────────────────────────────────────────────────
        opt = self.section(box, "Options")
        g = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.docker = Gtk.ComboBoxText()
        for lab, _ in DOCKER:
            self.docker.append_text(lab)
        self.docker.set_active(0)
        self.clavier = Gtk.Entry(text="fr", width_chars=6)
        self.ligne(g, 0, "Image docker source", self.docker)
        self.ligne(g, 1, "Clavier", self.clavier)
        opt.pack_start(g, False, False, 0)
        self.c_banc = Gtk.CheckButton(label="Demarrer le banc au boot (osmo-banc.service)")
        self.c_multi = Gtk.CheckButton(label="Demarrer le multi-operateur au boot (osmo-multi.service)")
        self.c_softsim = Gtk.CheckButton(label="softSIM, pySim et lecteur de carte")
        self.c_softsim.set_active(True)
        self.c_debs = Gtk.CheckButton(label="Embarquer les .deb du banc (/var/cache/osmo-debs)")
        self.c_debs.set_active(True)
        self.c_cache = Gtk.CheckButton(label="Tout recompiler (--no-cache, tres long)")
        for c in (self.c_banc, self.c_multi, self.c_softsim, self.c_debs, self.c_cache):
            opt.pack_start(c, False, False, 0)

        # ── output ──────────────────────────────────────────────────────────
        so = self.section(box, "Sortie")
        hb = Gtk.Box(spacing=8)
        self.dossier = Gtk.Entry(text=SORTIE_DEFAUT, hexpand=True)
        b = Gtk.Button(label="Choisir...")
        b.connect("clicked", self.choisir)
        hb.pack_start(Gtk.Label(label="Dossier"), False, False, 0)
        hb.pack_start(self.dossier, True, True, 0)
        hb.pack_start(b, False, False, 0)
        so.pack_start(hb, False, False, 0)
        hb = Gtk.Box(spacing=8)
        self.nom = Gtk.Entry(hexpand=True, placeholder_text="automatique (osmo-operator-<variante>.iso)")
        hb.pack_start(Gtk.Label(label="Nom"), False, False, 0)
        hb.pack_start(self.nom, True, True, 0)
        so.pack_start(hb, False, False, 0)
        self.images = Gtk.Label(xalign=0, wrap=True, selectable=True)
        self.images.get_style_context().add_class("aide")
        so.pack_start(self.images, False, False, 0)

        # ── disk ────────────────────────────────────────────────────────────
        di = self.section(box, "Disque")
        self.l_disque = Gtk.Label(xalign=0, wrap=True)
        di.pack_start(self.l_disque, False, False, 0)
        hb = Gtk.Box(spacing=8)
        self.l_vieux = Gtk.Label(xalign=0, wrap=True, hexpand=True)
        self.l_vieux.get_style_context().add_class("aide")
        self.b_nettoyer = Gtk.Button(label="Supprimer ces dossiers")
        self.b_nettoyer.connect("clicked", self.nettoyer)
        hb.pack_start(self.l_vieux, True, True, 0)
        hb.pack_start(self.b_nettoyer, False, False, 0)
        di.pack_start(hb, False, False, 0)

        # ── the command, the button ─────────────────────────────────────────
        cm = self.section(box, "Commande")
        self.l_cmd = Gtk.Label(xalign=0, wrap=True, selectable=True)
        self.l_cmd.set_line_wrap_mode(Pango.WrapMode.CHAR)
        self.l_cmd.get_style_context().add_class("cmd")
        cm.pack_start(self.l_cmd, False, False, 0)
        hb = Gtk.Box(spacing=12)
        self.etat = Gtk.Label(xalign=0, hexpand=True, wrap=True)
        go = Gtk.Button(label="Construire")
        go.get_style_context().add_class("go")
        go.connect("clicked", self.construire)
        hb.pack_start(self.etat, True, True, 0)
        hb.pack_end(go, False, False, 0)
        box.pack_start(hb, False, False, 4)

        for w in (self.r_iso, self.r_arm, self.arm_bureau, self.c_banc, self.c_multi, self.c_softsim,
                  self.c_debs, self.c_cache, *self.cartes.values()):
            w.connect("toggled", self.maj)
        for w in (self.variante, self.version, self.docker):
            w.connect("changed", self.maj)
        for w in (self.clavier, self.dossier, self.nom):
            w.connect("changed", self.maj)
        self.noeud.connect("value-changed", self.maj)
        self.connect("destroy", Gtk.main_quit)
        self.show_all()
        self.maj()
        self.disque()
        GLib.timeout_add_seconds(30, lambda: (self.disque(), True)[1])

    # ── helpers ─────────────────────────────────────────────────────────────
    def section(self, box, titre):
        fr = Gtk.Frame()
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=8)
        l = Gtk.Label(label=titre, xalign=0)
        l.get_style_context().add_class("section")
        v.pack_start(l, False, False, 0)
        fr.add(v)
        box.pack_start(fr, False, False, 0)
        return v

    @staticmethod
    def ligne(grid, r, lab, w):
        grid.attach(Gtk.Label(label=lab, xalign=0), 0, r, 1, 1)
        grid.attach(w, 1, r, 1, 1)

    def arm(self):
        return self.r_arm.get_active()

    def args(self):
        a = []
        if self.arm():
            a.append("--arm")
            cs = [k for k, c in self.cartes.items() if c.get_active()]
            a.append("--board=%s" % ("all" if len(cs) == len(self.cartes) else ",".join(cs)))
            if self.arm_bureau.get_active():
                a.append("--desktop")
        else:
            a += VARIANTES[self.variante.get_active()][1]
            if self.noeud.get_value_as_int() != 1:
                a.append("--node=%d" % self.noeud.get_value_as_int())
            if self.version.get_active_text() != "24.04":
                a.append("--version=%s" % self.version.get_active_text())
        a += DOCKER[self.docker.get_active()][1]
        kb = self.clavier.get_text().strip()
        if kb and kb != "fr":
            a.append("--kb=%s" % kb)
        if self.c_banc.get_active():
            a.append("--banc")
        if self.c_multi.get_active():
            a.append("--multi")
        if not self.c_softsim.get_active():
            a.append("--no-softsim")
        if not self.c_debs.get_active():
            a.append("--without-debs")
        if self.c_cache.get_active():
            a.append("--no-cache")
        nom = self.nom.get_text().strip()
        if nom:
            a.append("--output=%s" % os.path.join(self.sortie(), nom))
        return a

    def sortie(self):
        return os.path.expanduser(self.dossier.get_text().strip() or SORTIE_DEFAUT)

    def erreur(self):
        if self.arm():
            if not any(c.get_active() for c in self.cartes.values()):
                return "choisir au moins une carte"
        elif VARIANTES[self.variante.get_active()][1] == ["--all"] and self.nom.get_text().strip():
            return "--all produit quatre images : laisser le nom automatique"
        return ""

    def maj(self, *_):
        self.p_iso.set_visible(not self.arm())
        self.p_arm.set_visible(self.arm())
        self.nom.set_placeholder_text("automatique (" + ("<carte>.img" if self.arm() else
                                                         "osmo-operator-<variante>.iso") + ")")
        self.l_cmd.set_text("cd %s\nsudo bash %s %s" % (shlex.quote(self.sortie()), shlex.quote(BUILD),
                                                       " ".join(shlex.quote(x) for x in self.args())))
        e = self.erreur()
        self.etat.set_text(e)
        self.etat.get_style_context().add_class("ko") if e else self.etat.get_style_context().remove_class("ko")
        self.lister_images()

    def lister_images(self):
        d = self.sortie()
        try:
            im = sorted((f for f in os.listdir(d) if f.endswith((".iso", ".img", ".img.xz"))),
                        key=lambda f: -os.path.getmtime(os.path.join(d, f)))
        except OSError:
            im = []
        self.images.set_text("Deja dans ce dossier : " + (", ".join(
            "%s (%s)" % (f, taille(os.path.getsize(os.path.join(d, f)))) for f in im[:6]) if im else "aucune image"))

    def disque(self):
        w, s = libre(WORK), libre(self.sortie())
        besoin = 40 * 1024 ** 3
        txt = "Travail (%s) : %s libres" % (WORK, taille(w))
        if os.path.realpath(WORK) != os.path.realpath(self.sortie()):
            txt += "    -    sortie (%s) : %s libres" % (self.sortie(), taille(s))
        txt += "\nUne ISO bureau demande environ 40 Go de travail."
        self.l_disque.set_text(txt)
        ctx = self.l_disque.get_style_context()
        ctx.remove_class("ok"); ctx.remove_class("ko")
        ctx.add_class("ok" if w >= besoin else "ko")
        vieux = sorted(os.path.join(WORK, f) for f in os.listdir(WORK) if f.startswith("iso-build-")) \
            if os.path.isdir(WORK) else []
        self.vieux = [v for v in vieux if not self.monte(v)]
        if self.vieux:
            self.l_vieux.set_text("Restes de builds precedents : " + ", ".join(
                "%s (%s)" % (os.path.basename(v), taille(du(v))) for v in self.vieux))
        else:
            self.l_vieux.set_text("Aucun reste de build precedent.")
        self.b_nettoyer.set_sensitive(bool(self.vieux))

    @staticmethod
    def monte(d):
        try:
            with open("/proc/self/mountinfo") as f:
                return any((" %s/" % d) in l or (" %s " % d) in l for l in f)
        except OSError:
            return True

    # ── actions ─────────────────────────────────────────────────────────────
    def choisir(self, _b):
        dlg = Gtk.FileChooserDialog(title="Dossier de sortie", parent=self,
                                    action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_buttons("Annuler", Gtk.ResponseType.CANCEL, "Choisir", Gtk.ResponseType.OK)
        if os.path.isdir(self.sortie()):
            dlg.set_current_folder(self.sortie())
        if dlg.run() == Gtk.ResponseType.OK:
            self.dossier.set_text(dlg.get_filename())
        dlg.destroy()
        self.disque()

    def lancer(self, titre, argv, progress=True):
        cmd = [sys.executable, RUN, "--root", "--keep-open", "--title", titre]
        if progress:
            cmd.append("--progress")
        subprocess.Popen(cmd + ["--"] + argv, start_new_session=True)

    def nettoyer(self, _b):
        if not self.vieux:
            return
        d = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                              buttons=Gtk.ButtonsType.OK_CANCEL,
                              text="Supprimer les restes de builds precedents ?")
        d.format_secondary_text("\n".join(self.vieux))
        ok = d.run() == Gtk.ResponseType.OK
        d.destroy()
        if ok:
            self.lancer("osmo-iso : nettoyage", ["rm", "-rf", "--one-file-system"] + self.vieux, progress=False)
            GLib.timeout_add_seconds(5, lambda: (self.disque(), False)[1])

    def construire(self, _b):
        e = self.erreur()
        if e:
            self.etat.set_text(e)
            return
        d = self.sortie()
        try:
            os.makedirs(d, exist_ok=True)
        except OSError as ex:
            self.etat.set_text("dossier de sortie : %s" % ex)
            return
        titre = "osmo-iso : " + ("image SD arm64" if self.arm() else
                                 VARIANTES[self.variante.get_active()][0])
        # the « cd » INSIDE the command: pkexec starts in root's home, a
        # --cwd given to osmo-gtk-run would be lost on the way
        self.lancer(titre, ["bash", "-c", 'cd -- "$0" && exec bash "$@"', d, BUILD] + self.args())
        self.etat.set_text("Construction lancee dans sa fenetre (mot de passe demande une fois).")


def main():
    if not os.path.exists(BUILD):
        sys.exit("osmo-iso : %s absent" % BUILD)
    Fenetre()
    Gtk.main()


if __name__ == "__main__":
    main()
