#!/usr/bin/env python3
# osmo-gtk-run.py - UNE COMMANDE, UNE FENETRE GTK : le terminal devient un journal.
#
#     osmo-gtk-run.py [--title T] [--icon FICHIER] [--root] [--tty]
#                     [--close-on-exit] [--cwd DIR] -- COMMANDE [ARGS...]
#
# [2026-10-01] AUCUN FAVORI N OUVRE PLUS DE TERMINAL. Les icones du dock et du
# bureau (supplements, update, Claude, deka, telephone pmOS, 4G, pilotes, le
# journal du multi, la console tmux, la VTY du mobile...) ouvraient chacune un
# gnome-terminal, avec un « read -n1 » a la fin pour que la fenetre ne se
# ferme pas avant qu on ait lu. Elles passent toutes par ICI : une fenetre GTK
# du banc (meme habillage que la barre de lancement, tools/osmo-launcher.py),
# qui montre la sortie de la commande, dit quand elle est finie et avec quel
# statut, et reste ouverte jusqu a « fermer ».
#
# DEUX FACONS DE MONTRER LA COMMANDE :
#   - journal (defaut) : stdout + stderr de la commande dans une vue texte
#     (couleurs ANSI retirees, defilement automatique, « copier »). Pour tout
#     ce qui ne fait qu ecrire : journalctl -f, un status, un service qu on
#     demarre.
#   - --tty : un VRAI terminal (widget VTE) dans la fenetre. Pour ce qui
#     pose des questions (whiptail, sudo, « Entree pour continuer »), anime
#     la ligne (update.sh teste `[ -t 1 ]` et sort sans tty), ou est
#     interactif de bout en bout (claude, tmux attach, telnet). C est le
#     terminal, mais DANS le GTK, avec le meme bandeau d etat ; sans
#     gir1.2-vte-2.91, on retombe sur le journal et on le dit.
#
# --root : la commande tourne en root. Deja root : rien a faire. Sinon pkexec
# (la fenetre de mot de passe du bureau) avec DISPLAY, XAUTHORITY et les
# variables de proxy de la session - pkexec nettoie l environnement, et sans
# ce report les git clone des supplements echouent derriere un proxy. Sans
# pkexec : sudo (qui demande dans le terminal en --tty, et ne peut pas
# demander en journal : sudo -n, l echec se lit dans la fenetre).
#
# Lance par les .desktop du depot (data/desktop/), les lanceurs poses par
# iso_modules/85-installeur-bureau.sh, addition.sh, update.sh, et par les
# barres GTK du bureau (osmo-launcher.py, osmo-panel.py) pour leurs entrees
# interactives.
import argparse
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading


def _root_prefix(tty):
    """Prefixe argv pour executer en root : rien si on l est deja, pkexec avec
    l environnement utile sinon, sudo en dernier recours."""
    if os.geteuid() == 0:
        return []
    if shutil.which("pkexec") and os.environ.get("DISPLAY"):
        env = ["DISPLAY=" + os.environ.get("DISPLAY", ""),
               "XAUTHORITY=" + os.environ.get("XAUTHORITY", "")]
        for v in ("http_proxy", "https_proxy", "ftp_proxy", "no_proxy",
                  "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "NO_PROXY"):
            if os.environ.get(v):
                env.append(v + "=" + os.environ[v])
        if not tty:
            env += ["NO_COLOR=1", "TERM=dumb"]
        return ["pkexec", "env"] + env
    if shutil.which("sudo"):
        return ["sudo", "-E"] if tty else ["sudo", "-n", "-E"]
    return []


def _parse():
    ap = argparse.ArgumentParser(description="montre une commande dans une fenetre GTK")
    ap.add_argument("--title", default="osmo-operator")
    ap.add_argument("--icon", default=None, help="fichier d icone (PNG/SVG)")
    ap.add_argument("--root", action="store_true", help="en root (pkexec, ou sudo)")
    ap.add_argument("--tty", action="store_true", help="un terminal (VTE) plutot qu un journal")
    ap.add_argument("--close-on-exit", action="store_true", help="ferme la fenetre si la commande sort en 0")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--width", type=int, default=980)
    ap.add_argument("--height", type=int, default=600)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if a.cmd and a.cmd[0] == "--":
        a.cmd = a.cmd[1:]
    if not a.cmd:
        ap.error("aucune commande (osmo-gtk-run.py --title T -- commande args)")
    return a


ARGS = _parse()


def _exec_direct(pourquoi):
    # Pas de bureau, ou pas de GTK : on execute tel quel, dans le terminal
    # courant - mieux vaut la commande sans fenetre que pas de commande.
    print("[osmo-gtk-run] %s : execution directe" % pourquoi, file=sys.stderr)
    argv = (_root_prefix(True) if ARGS.root else []) + ARGS.cmd
    if ARGS.cwd:
        os.chdir(ARGS.cwd)
    os.execvp(argv[0], argv)


if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
    _exec_direct("pas de bureau (DISPLAY)")

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GLib, Gtk  # noqa: E402
except (ImportError, ValueError) as _e:
    _exec_direct("GTK indisponible (%s)" % _e)

try:
    gi.require_version("Vte", "2.91")
    from gi.repository import Vte  # noqa: E402
except (ValueError, ImportError):
    Vte = None

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
MAX_CHARS = 400_000          # au-dela, on coupe le debut : le journal n est pas une archive

CSS = b"""
.osmo-run { background-color: #0b0e14; }
.osmo-run label.title { color: #58a6ff; font: bold 10pt "Ubuntu"; }
.osmo-run label.state { color: #8b949e; font: 9pt "Ubuntu"; }
.osmo-run label.state.ok { color: #3fb950; }
.osmo-run label.state.ko { color: #f85149; }
.osmo-run button { background: rgba(22,27,34,0.9); color: #e6edf3;
                   border: 1px solid rgba(88,166,255,0.3); border-radius: 6px;
                   padding: 2px 10px; font: 9pt "Ubuntu"; min-height: 0; }
.osmo-run button:hover { border-color: #58a6ff; }
.osmo-run textview, .osmo-run textview text { background-color: #0b0e14; color: #d8e0ea;
                   font-family: "Ubuntu Mono"; font-size: 10pt; }
.osmo-run .cmd { color: #6e7681; font: 8pt "Ubuntu Mono"; }
"""


class Run(Gtk.Window):
    def __init__(self, a):
        super().__init__(title=a.title)
        self.a = a
        self.proc = None            # journal : Popen
        self.child_pid = None       # tty : pid du fils VTE
        self.fini = False
        self.set_default_size(a.width, a.height)
        if a.icon and os.path.exists(a.icon):
            try:
                self.set_icon_from_file(a.icon)
            except Exception:
                pass
        self.connect("destroy", self._quit)
        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        col.get_style_context().add_class("osmo-run")
        col.set_border_width(6)

        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        t = Gtk.Label(label=a.title)
        t.get_style_context().add_class("title")
        self.state = Gtk.Label(label="en cours ...")
        self.state.get_style_context().add_class("state")
        head.pack_start(t, False, False, 0)
        head.pack_start(self.state, False, False, 0)
        self.b_close = Gtk.Button(label="fermer")
        self.b_close.connect("clicked", lambda *_x: self.destroy())
        head.pack_end(self.b_close, False, False, 0)
        if not a.tty:
            b_copy = Gtk.Button(label="copier")
            b_copy.set_tooltip_text("copie tout le journal dans le presse-papier")
            b_copy.connect("clicked", self._copier)
            head.pack_end(b_copy, False, False, 0)
        self.b_stop = Gtk.Button(label="■ stop")
        self.b_stop.set_tooltip_text("envoie SIGTERM a la commande")
        self.b_stop.connect("clicked", lambda *_x: self.stop())
        head.pack_end(self.b_stop, False, False, 0)
        col.pack_start(head, False, False, 0)

        cmdl = Gtk.Label(label="$ " + " ".join(shlex.quote(c) for c in a.cmd))
        cmdl.get_style_context().add_class("cmd")
        cmdl.set_halign(Gtk.Align.START)
        cmdl.set_ellipsize(3)       # Pango.EllipsizeMode.END
        col.pack_start(cmdl, False, False, 0)

        self.tty = bool(a.tty and Vte is not None)
        if self.tty:
            self.term = Vte.Terminal()
            self.term.set_scrollback_lines(20000)
            self.term.set_scroll_on_output(False)
            self.term.set_scroll_on_keystroke(True)
            try:
                from gi.repository import Pango
                self.term.set_font(Pango.FontDescription("Ubuntu Mono 10"))
            except Exception:
                pass
            fg, bg = Gdk.RGBA(), Gdk.RGBA()
            fg.parse("#d8e0ea")
            bg.parse("#0b0e14")
            self.term.set_colors(fg, bg, None)
            self.term.connect("child-exited", self._tty_exit)
            sc = Gtk.ScrolledWindow()
            sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            sc.add(self.term)
            col.pack_start(sc, True, True, 0)
        else:
            sc = Gtk.ScrolledWindow()
            sc.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
            self.tv = Gtk.TextView()
            self.tv.set_editable(False)
            self.tv.set_cursor_visible(False)
            self.tv.set_monospace(True)
            self.tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            self.tv.set_left_margin(6)
            self.tv.set_right_margin(6)
            sc.add(self.tv)
            self.sc = sc
            col.pack_start(sc, True, True, 0)
        self.add(col)
        self.show_all()
        if a.tty and Vte is None:
            self._append("[osmo-gtk-run] VTE (gir1.2-vte-2.91) absent : journal au lieu du terminal, "
                         "les questions de la commande ne pourront pas etre repondues.\n")
        GLib.idle_add(self._start)

    # ── lancer ────────────────────────────────────────────────────────────
    def _argv(self):
        return (_root_prefix(self.tty) if self.a.root else []) + list(self.a.cmd)

    def _start(self):
        argv = self._argv()
        cwd = self.a.cwd or None
        if self.tty:
            env = dict(os.environ)
            env.setdefault("TERM", "xterm-256color")
            envv = ["%s=%s" % kv for kv in env.items()]
            try:
                self.term.spawn_async(Vte.PtyFlags.DEFAULT, cwd, argv, envv,
                                      GLib.SpawnFlags.DEFAULT, None, None, -1, None,
                                      self._tty_spawned)
            except Exception as e:
                self.term.feed(("lancement impossible : %s\r\n" % e).encode())
                self._done(127)
            self.term.grab_focus()
            return False
        env = dict(os.environ, NO_COLOR="1", TERM="dumb")
        try:
            self.proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         start_new_session=True, env=env)
        except OSError as e:
            self._append("lancement impossible : %s\n" % e)
            self._done(127)
            return False
        threading.Thread(target=self._pump, daemon=True).start()
        return False

    def _tty_spawned(self, _term, pid, error, *_a):
        if error is not None or not pid or pid < 0:
            self.term.feed(("lancement impossible : %s\r\n" % error).encode())
            self._done(127)
            return
        self.child_pid = pid

    def _tty_exit(self, _term, status):
        # status : format waitpid
        rc = (status >> 8) & 0xff if (status & 0xff) == 0 else 128 + (status & 0x7f)
        self._done(rc)

    def _pump(self):
        try:
            for chunk in iter(lambda: self.proc.stdout.read1(4096), b""):
                GLib.idle_add(self._append, chunk.decode("utf-8", "replace"))
        except Exception:
            pass
        rc = self.proc.wait()
        GLib.idle_add(self._done, rc)

    # ── montrer ───────────────────────────────────────────────────────────
    def _append(self, text):
        if self.tty:
            self.term.feed(text.replace("\n", "\r\n").encode())
            return False
        buf = self.tv.get_buffer()
        adj = self.sc.get_vadjustment()
        en_bas = adj.get_value() + adj.get_page_size() >= adj.get_upper() - 40
        buf.insert(buf.get_end_iter(), ANSI.sub("", text))
        n = buf.get_char_count()
        if n > MAX_CHARS:
            buf.delete(buf.get_start_iter(), buf.get_iter_at_offset(n - MAX_CHARS))
        if en_bas:
            self.tv.scroll_to_mark(buf.get_insert(), 0.0, True, 0.0, 1.0)
        return False

    def _done(self, rc):
        if self.fini:
            return False
        self.fini = True
        ctx = self.state.get_style_context()
        if rc == 0:
            self.state.set_text("termine")
            ctx.add_class("ok")
        else:
            self.state.set_text("termine (statut %d)" % rc)
            ctx.add_class("ko")
        self.b_stop.set_sensitive(False)
        if self.a.close_on_exit and rc == 0:
            GLib.timeout_add(1200, lambda: (self.destroy(), False)[1])
        return False

    def _copier(self, *_a):
        buf = self.tv.get_buffer()
        texte = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(texte, -1)

    # ── arreter ───────────────────────────────────────────────────────────
    def stop(self):
        if self.tty:
            if self.child_pid:
                try:
                    os.killpg(os.getpgid(self.child_pid), signal.SIGTERM)
                except OSError:
                    try:
                        os.kill(self.child_pid, signal.SIGTERM)
                    except OSError:
                        pass
            return
        if self.proc is not None and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except OSError:
                pass

    def _quit(self, *_a):
        # La fenetre part : la commande aussi. Un journalctl -f ou un tmux
        # attach orphelin n a aucune raison de survivre a ce qu on regardait.
        self.stop()
        Gtk.main_quit()


def main():
    Run(ARGS)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda *_x: (Gtk.main_quit(), False)[1])
    Gtk.main()


if __name__ == "__main__":
    main()
