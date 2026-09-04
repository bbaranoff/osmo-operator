#!/usr/bin/env python3
# osmo-panel.py - l ENCART VIVANT du bureau, version cliquable.
#
# Une fenetre GTK de type BUREAU (le meme mecanisme que les icones DING
# d Ubuntu : sous toutes les fenetres, au-dessus du fond, et elle recoit les
# clics - ce que Conky ne sait pas faire), posee EXACTEMENT sur le cadre Calvin
# & Hobbes du fond d ecran (tools/wallpaper-render.py : boite 510,600-1410,1010
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
import socket
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
# [2026-09-04] LE VERROU D INSTANCE EST PAR SESSION, PAS PAR MACHINE. Il etait
# dans /run/osmo-fft, que systemd cree root:root (RuntimeDirectory de
# osmo-fft-snap.service). Sur la cle le bureau tourne en root et l ecriture
# passait ; sur le systeme installe le bureau est celui du compte cree par
# l installeur, et open(PID_FILE, "w") levait PermissionError - apport ouvrait
# "osmo-operator a rencontre une erreur interne" a CHAQUE ouverture de session.
# XDG_RUNTIME_DIR (/run/user/<uid>) appartient a l utilisateur, et un encart
# par session est exactement ce qu on veut compter.
_RUNDIR = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
PID_FILE = os.path.join(_RUNDIR if os.path.isdir(_RUNDIR) else RUN, "osmo-panel.pid")
MULTI_CONF = os.environ.get("MULTI_CONF", "/etc/osmocom/osmo-multi.conf")
TMUX_SESSION = os.environ.get("TMUX_SESSION", "calypso")
DASH_PORT = int(os.environ.get("DASH_PORT", "8080"))
# Le VTY du client mobile (osmocom-bb « mobile »). 4247 pour MS#1 ; MS#2 est sur
# 4248 - voir start-direct.sh, qui les attribue.
VTY_PORT = int(os.environ.get("MS_VTY_PORT", "4247"))
# La boite du strip dans le fond (1920x1080).
BOX = (510, 600, 900, 410)
FW, FH = 1920, 1080

# [2026-09-04] LA BARRE N A PLUS DE FOND. Elle posait un rectangle sombre
# derriere les boutons, EN PLUS du pied deja peint par osmo-fft-snap.py : deux
# fonds l un sur l autre, aux bords qui ne tombaient pas au meme endroit, et une
# arete visible en travers du pied de l encart. Les boutons ont deja leur propre
# fond (`.osmo-bar button`), ils se detachent tres bien seuls.
CSS = b"""
/* [2026-09-04] `background-color: transparent` NE SUFFIT PAS, et le rectangle
   reapparaissait. Adwaita ne peint pas seulement une couleur sur une boite : il
   y pose un `background-image` (un degrade), plus une bordure et une ombre.
   Neutraliser la seule couleur laisse l image - d ou le bandeau plus clair qui
   revenait derriere les boutons, par-dessus le pied deja peint par
   osmo-fft-snap.py. On coupe les quatre.
   `background: none` DOIT venir avant `background-color`, sinon la propriete
   raccourcie remet la couleur par defaut apres coup. */
.osmo-bar { background: none; background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; margin: 0; }
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
# [2026-09-04] LES OPERATEURS ARRETES COMPTENT AUSSI.
# Cette fonction ne rendait que les conteneurs EN MARCHE (docker ps), et
# update_op() ne montrait les fleches qu a partir de deux entrees. Consequence :
# sur un banc ou op2 et op3 n avaient pas demarre, l encart n avait AUCUNE
# fleche - donc aucun moyen de regarder l operateur qu on voulait justement
# diagnostiquer. C est l inverse du besoin : l ecran doit pouvoir se poser sur
# un operateur eteint, c est meme la le seul moment ou on en a besoin.
# On rend donc TOUTE la topologie, avec l etat (up) a cote, et le pied de
# l encart ecrit "op 3/3 arrete" au lieu de faire disparaitre le bouton.
# EN REVANCHE, PAS DE FLECHES HORS MULTI-OPERATEUR. Sans
# /etc/osmocom/osmo-multi.conf - donc sur un banc a un seul operateur - il n y a
# rien vers quoi naviguer : la liste rend le seul natif, et update_op() cache
# les fleches. On n invente pas d operateurs 2 et 3 qui n existent pas.
# Meme liste et meme regle que tools/osmo-op.sh, qui est la version en ligne
# de commande (et la definition de reference).


M3UA_PORT = int(os.environ.get("MULTI_M3UA_PORT", "2908"))


def _sctp_ecoute(port):
    """Un socket SCTP ecoute-t-il sur ce port ? Lecture directe de
    /proc/net/sctp/eps - aucun privilege, et `ss` peut ne pas etre installe."""
    try:
        with open("/proc/net/sctp/eps") as f:
            for line in f.readlines()[1:]:
                ch = line.split()
                # colonne LPORT : la 4e dans le format du noyau.
                if len(ch) > 4 and ch[4] == str(port):
                    return True
    except OSError:
        pass
    try:
        out = subprocess.run(["ss", "-an"], capture_output=True, text=True, timeout=3).stdout
        return any(l.startswith("sctp") and f":{port}" in l for l in out.splitlines())
    except Exception:
        return False


def operators():
    """Liste [(idx, mode, ip, up)] : toute la topologie, marche ou pas."""
    ops = []
    try:
        with open(MULTI_CONF) as f:
            txt = f.read()
    except OSError:
        txt = ""
    m = re.search(r'^MULTI_OPS="?([^"\n]*)"?', txt, re.M)
    specs = m.group(1).split() if m else []
    if not specs:
        # Pas de topologie multi-operateur : un seul operateur, le natif.
        # update_op() cachera les fleches - il n y a nulle part ou aller.
        specs = ["1:native:"]
    # [2026-09-04] `docker ps` ECHOUE SOUS LE COMPTE DE LA SESSION s il n est pas
    # dans le groupe `docker` ("permission denied ... /var/run/docker.sock"), et
    # l encart annoncait alors « op 3/3 arrete » avec les conteneurs bien en
    # marche. On ne confond plus « absent » et « invisible » : quand docker ne
    # nous repond pas, on sonde le tableau de bord de l operateur, qui ne
    # demande aucun privilege. Meme regle que tools/osmo-op.sh.
    running = set()
    docker_ok = False
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True,
                           text=True, timeout=5)
        docker_ok = r.returncode == 0
        running = set(r.stdout.split())
    except Exception:
        docker_ok = False

    def reachable(ip):
        if not ip:
            return False
        try:
            with socket.create_connection((ip, DASH_PORT), timeout=0.4):
                return True
        except OSError:
            return False

    for spec in specs:
        parts = spec.split(":")
        if len(parts) < 3:
            continue
        idx, mode, ip = parts[0], parts[1], parts[2]
        if mode == "native":
            up = subprocess.run(["pgrep", "-x", "osmo-bsc"], capture_output=True).returncode == 0
        elif docker_ok:
            up = f"osmo-operator-{idx}" in running
        else:
            up = reachable(ip)
        ops.append((idx, mode, ip, up))
    if not any(o[1] == "native" for o in ops):
        ops.insert(0, ("1", "native", "", False))
    # ── LE HUB EST LE DERNIER ARRET DU CYCLE ────────────────────────────────
    # [2026-09-04] On pouvait regarder les trois operateurs, jamais le noeud qui
    # les relie - alors que c est lui qu on interroge quand le SS7 va mal.
    # L encart le rend par une vue SS7 (matrice de connectivite + journal du
    # hub) et non par un spectre : un hub M3UA n a pas de radio, une FFT n y
    # voudrait rien dire. Voir tools/osmo-fft-snap.py, render_interstp().
    # Meme regle que tools/osmo-op.sh, la definition de reference.
    if specs and any(o[1] == "docker" for o in ops):
        hub_ip = ""
        m = re.search(r'^MULTI_HUB_IP="?([^"\s#]*)', txt, re.M)
        if m:
            hub_ip = m.group(1)
        hub = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
        # [2026-09-04] LE HUB N A PAS DE TABLEAU DE BORD. Le repli `reachable()`
        # tapait sur 172.20.0.10:8080, que l inter-STP n ecoute pas - il ne
        # route que du M3UA : l encart affichait « inter-STP arrete » sur un hub
        # parfaitement vivant. Sans acces docker, on regarde donc ce qu il
        # ecoute VRAIMENT, un socket SCTP sur le port M3UA. Une sonde TCP y est
        # muette (c est du SCTP), d ou la lecture de /proc/net/sctp.
        up = hub in running if docker_ok else _sctp_ecoute(M3UA_PORT)
        ops.append(("hub", "interstp", hub_ip or "172.20.0.10", up))
    return ops


# ── LE FICHIER EST LA SOURCE PARTAGEE, PAS UNE SORTIE ───────────────────────
# [2026-09-04] Cet encart ECRIVAIT /run/osmo-fft/operator et ne le LISAIT
# jamais. Trois consequences, toutes vues sur le banc :
#   - Ctrl+Alt+O (raccourci) et `osmo-op --next` changeaient bien le fichier -
#     le Conky suivait - mais l encart, lui, restait sur son operateur : ses
#     boutons Dashboard / tmux / VTY continuaient de viser l ancien ;
#   - pire, des qu un conteneur changeait d etat, refresh_ops() rappelait
#     update_op(), qui REECRIVAIT le fichier avec la selection de l encart :
#     le choix fait au clavier etait annule quelques secondes plus tard, sans
#     que rien ne l explique. « ctrl alt O ne marche pas » - il marchait, il
#     etait ecrase.
#   - et deux encarts (deux sessions) se seraient disputes le fichier.
# L encart LIT donc maintenant, et n ECRIT que sur un clic de ses fleches.
def read_operator():
    """L operateur choisi, quel que soit celui qui l a choisi (fleches de
    l encart, raccourci clavier, `osmo-op`). None si le fichier n existe pas."""
    try:
        with open(OP_FILE) as f:
            for line in f:
                if line.startswith("OP="):
                    return line[3:].strip() or None
    except OSError:
        pass
    return None


def write_operator(op):
    idx, mode, ip = op[0], op[1], op[2]
    # NAME est le nom du CONTENEUR : c est par lui que osmo-fft-snap.py et le
    # Conky entrent (docker exec). Pour le hub ce n est pas
    # « osmo-operator-hub » - ce conteneur n existe pas - mais osmo-inter-stp.
    # Meme regle que tools/osmo-op.sh.
    nom = (os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp") if mode == "interstp"
           else f"osmo-operator-{idx}")
    os.makedirs(RUN, exist_ok=True)
    tmp = OP_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"OP={idx}\nMODE={mode}\nIP={ip}\nNAME={nom}\n"
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
        b_dash = self.b_dash = Gtk.Button(label="Dashboard")
        b_dash.set_tooltip_text("firefox sur le tableau de bord de l operateur choisi")
        b_dash.connect("clicked", self.on_dash)
        b_tmux = self.b_tmux = Gtk.Button(label="tmux")
        b_tmux.set_tooltip_text("terminal attache a la session du banc (Ctrl-b d pour detacher)")
        b_tmux.connect("clicked", self.on_tmux)
        # Le VTY du mobile : la console ou l on tape « show ms », « call 100102 »
        # ... C est le troisieme endroit qu on ouvre a la main dix fois par
        # seance ; il n avait pas de bouton.
        b_vty = self.b_vty = Gtk.Button(label=f"VTY {VTY_PORT}")
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
        GLib.timeout_add(2000, self.refresh_ops)
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
        changed = ops != self.ops
        if changed:
            sel = self.ops[self.cur] if self.ops and self.cur < len(self.ops) else None
            self.ops = ops
            self.cur = next((i for i, o in enumerate(ops) if sel and o[0] == sel[0]), 0)
        # Quelqu un d autre a-t-il choisi ? (raccourci clavier, `osmo-op`, une
        # autre session). Si oui, on le suit - sans reecrire le fichier.
        want = read_operator()
        if want is not None:
            i = next((i for i, o in enumerate(self.ops) if o[0] == want), None)
            if i is not None and i != self.cur:
                self.cur = i
                changed = True
        if changed:
            self.update_op(write=(want is None))
        return True

    def update_op(self, write=True):
        # Les fleches sont TOUJOURS la des qu il y a plus d un operateur dans la
        # topologie - qu ils tournent ou non (voir operators()). Un operateur
        # arrete se dit dans le libelle, il ne fait pas disparaitre le bouton.
        multi = len(self.ops) > 1
        for wdg in (self.b_prev, self.b_next, self.l_op):
            wdg.set_visible(multi)
        if self.ops:
            op = self.ops[self.cur]
            etat = "" if op[3] else " arrete"
            libelle = "inter-STP" if op[1] == "interstp" else f"op {op[0]}/{len(self.ops)}"
            self.l_op.set_text(f"{libelle}{etat}")
            self.l_op.set_tooltip_text(
                "\n".join(f"op {o[0]} {o[1]} {o[2] or '(hote)'} "
                           f"{'actif' if o[3] else 'arrete'}" for o in self.ops))
            # Les trois boutons visent l operateur choisi : ils le DISENT.
            # Sans ca, "Dashboard / tmux / VTY 4247" ne changeait pas d aspect
            # quand on poussait les fleches, et rien ne disait sur quel
            # operateur on allait tomber.
            hub = op[1] == "interstp"
            suff = (" hub" if hub else f" op{op[0]}") if len(self.ops) > 1 else ""
            if hub:
                cible = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            elif op[1] == "docker":
                cible = f"osmo-operator-{op[0]}"
            else:
                cible = f"{op[2] or '127.0.0.1'}"
            self.b_dash.set_label("Dashboard" + suff)
            self.b_dash.set_tooltip_text(f"firefox http://{op[2] or '127.0.0.1'}:{DASH_PORT} ({cible})")
            self.b_tmux.set_label("tmux" + suff)
            self.b_tmux.set_tooltip_text(f"terminal sur la session tmux de {cible}")
            self.b_vty.set_label(f"VTY {VTY_PORT}" + suff)
            self.b_vty.set_tooltip_text(f"terminal : telnet 127.0.0.1 {VTY_PORT} dans {cible}")
            # `write=False` quand on ne fait que SUIVRE le fichier : le
            # reecrire a l identique est inutile, et le reecrire avec notre
            # propre idee est ce qui annulait le choix fait au clavier.
            if write:
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
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
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
        #
        # [2026-09-04] LE VTY D UN CONTENEUR EST DANS LE CONTENEUR. On faisait
        # « telnet <ip-du-conteneur> 4247 » : ce port n est PAS publie sur le
        # reseau docker de l operateur (start.sh ne publie que ce dont l hote a
        # besoin), et le bouton rendait "Connection refused" sur un operateur
        # parfaitement vivant. On entre donc dans le conteneur pour le natif du
        # dedans, exactement comme pour tmux.
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
        if op[1] == "interstp":
            # Le hub n a ni mobile ni VTY 4247 : sa console, c est le STP (4239).
            c = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            cmd = (f"docker exec -it {c} telnet 127.0.0.1 4239"
                   f" || {{ echo; echo 'VTY 4239 injoignable dans {c} (hub arrete ?)'; read -r _; }}")
        elif op[1] == "docker":
            c = f"osmo-operator-{op[0]}"
            cmd = (f"docker exec -it {c} telnet 127.0.0.1 {VTY_PORT}"
                   f" || {{ echo; echo 'VTY {VTY_PORT} injoignable dans {c} (operateur arrete ?)';"
                   f" read -r _; }}")
        else:
            cmd = (f"telnet 127.0.0.1 {VTY_PORT}"
                   f" || {{ echo; echo 'VTY 127.0.0.1:{VTY_PORT} injoignable - banc arrete ?'; read -r _; }}")
        terminal(cmd)

    def on_tmux(self, *_):
        # [2026-09-04] LE NOM DE LA SESSION N ETAIT PAS LE BON. On attachait
        # « tmux -S /tmp/osmocom_tmux attach -t osmocom » dans le conteneur,
        # alors que start.sh y ouvre une session nommee « osmo » sur le socket
        # PAR DEFAUT (voir son commentaire : "docker exec -ti osmo-operator-2
        # tmux attach -t osmo"). Le bouton disait donc "pas de session tmux"
        # sur un operateur qui en avait une. On essaie les deux, dans l ordre
        # ou elles existent, avant de conclure.
        op = self.ops[self.cur] if self.ops else ("1", "native", "", False)
        if op[1] == "interstp":
            c = os.environ.get("MULTI_HUB_NAME", "osmo-inter-stp")
            cmd = (f"docker exec -it {c} bash"
                   f" || {{ echo; echo 'hub {c} injoignable'; read -r _; }}")
        elif op[1] == "docker":
            c = f"osmo-operator-{op[0]}"
            cmd = (f"docker exec -it {c} tmux attach -t osmo"
                   f" || docker exec -it {c} tmux -S /tmp/osmocom_tmux attach -t osmocom"
                   f" || docker exec -it {c} tmux attach"
                   f" || {{ echo; echo 'pas de session tmux dans {c} (operateur arrete ?)';"
                   f" echo 'docker ps -a --filter name={c}'; read -r _; }}")
        else:
            cmd = (f"tmux attach -t {TMUX_SESSION}"
                   f" || tmux -S /tmp/osmocom_tmux attach -t osmocom"
                   f" || {{ echo; echo 'pas de session tmux « {TMUX_SESSION} » - banc arrete ?'; read -r _; }}")
        terminal(cmd)


def single_instance():
    try:
        old = int(open(PID_FILE).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM)
            time.sleep(0.3)
    except (OSError, ValueError):
        pass
    # Un verrou qu on ne peut pas ecrire n est pas une raison de ne pas afficher
    # l encart : au pire deux fenetres, jamais une boite de crash.
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError as e:
        print("osmo-panel : verrou %s non ecrit (%s)" % (PID_FILE, e), file=sys.stderr)


if __name__ == "__main__":
    single_instance()
    Panel()
    Gtk.main()
