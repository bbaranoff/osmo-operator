# tui.py - la console : un schema du reseau ou l'on circule aux fleches, et
# d'ou l'on ouvre soit un VTY, soit un script SS7.
#
# Principes de navigation, tenus partout :
#   fleches      se deplacer (dans le schema : de boite en boite, dans l'espace)
#   Entree       ouvrir / valider
#   Echap        revenir en arriere ; DANS UN VTY, Echap ferme la session et
#                rend la main au schema - les autres VTY restent disponibles
#   q            quitter (depuis le schema)
#
# Le reste (v, s, a, c, r, ?) est du raccourci : tout est aussi atteignable a
# la fleche depuis le menu d'une boite.

import curses
import locale
import os
import time

from . import diagram
from . import mapops
from . import quickcmd
from . import sccp
from . import ss7
from . import topo as topo_mod
from . import vty as vty_mod

locale.setlocale(locale.LC_ALL, "")

C_DEFAULT, C_HUB, C_STP, C_CORE, C_RADIO, C_DATA, C_CONSOLE, C_BAR, C_WARN, C_OK = range(1, 11)

FAMILY_COLOR = {
    "SS7": C_STP, "coeur": C_CORE, "abonnes": C_CORE, "radio": C_RADIO,
    "media": C_DATA, "data": C_DATA, "voix": C_CORE, "mobile": C_RADIO,
}

HELP = [
    "NAVIGATION",
    "  fleches            se deplacer dans le schema (haut/bas/gauche/droite)",
    "  Entree             ouvrir le menu de l'element selectionne",
    "  Echap              revenir en arriere ; dans un VTY : fermer la session",
    "  Tab                element suivant, Maj-Tab precedent",
    "",
    "RACCOURCIS",
    "  v                  ouvrir directement le VTY de l'element",
    "  s                  scripts SS7 (operations MAP) sur l'element",
    "  a                  audit SS7 (DAUD) d'un point code",
    "  c                  connecter / deconnecter le lien M3UA de la console",
    "  j                  journal du lien M3UA",
    "  r                  relire la topologie (redecouverte complete)",
    "  ?                  cette aide            q  quitter",
    "",
    "DANS UN VTY",
    "  Entree             envoyer la commande",
    "  fleches haut/bas   historique des commandes",
    "  PagePrec/PageSuiv  faire defiler la sortie",
    "  Echap              fermer CE VTY et revenir au schema",
    "",
    "SCRIPTS SS7",
    "  La console s'enregistre sur l'inter-STP comme un ASP M3UA a part",
    "  entiere (RKM dynamique), avec son propre point code. Elle emet du",
    "  TCAP/MAP reel : sendRoutingInfoForSM, sendRoutingInfo, ATI, SAI...",
    "  Chaque envoi peut etre exporte en script Python autonome.",
]


# ── lecture des touches ───────────────────────────────────────────────────────
# ncurses ne reconnait les fleches que dans la forme prevue par le terminfo du
# terminal (ici "\x1bOB", mode curseur applicatif). Un multiplexeur, un SSH mal
# configure ou un terminal qui reste en mode normal envoient "\x1b[B" : ncurses
# rend alors trois touches brutes et la navigation semble morte. On decode donc
# nous-memes les deux formes. Echap seul reste Echap : c'est l'absence de suite
# dans les 40 ms qui le distingue d'un debut de sequence.
_CSI_FINAL = {
    "A": curses.KEY_UP, "B": curses.KEY_DOWN, "C": curses.KEY_RIGHT,
    "D": curses.KEY_LEFT, "H": curses.KEY_HOME, "F": curses.KEY_END,
    "Z": curses.KEY_BTAB, "P": curses.KEY_F1, "Q": curses.KEY_F2,
    "R": curses.KEY_F3, "S": curses.KEY_F4,
}
_CSI_TILDE = {1: curses.KEY_HOME, 2: curses.KEY_IC, 3: curses.KEY_DC,
              4: curses.KEY_END, 5: curses.KEY_PPAGE, 6: curses.KEY_NPAGE,
              15: curses.KEY_F5, 17: curses.KEY_F6, 18: curses.KEY_F7,
              19: curses.KEY_F8, 20: curses.KEY_F9, 21: curses.KEY_F10}


def read_key(win):
    key = win.getch()
    if key != 27:
        return key
    win.timeout(40)
    try:
        nxt = win.getch()
        if nxt == -1:
            return 27
        if nxt not in (ord("["), ord("O")):
            return 27
        params = ""
        for _ in range(8):
            ch = win.getch()
            if ch == -1:
                return 27
            c = chr(ch)
            if c.isdigit() or c == ";":
                params += c
                continue
            if c == "~":
                try:
                    return _CSI_TILDE.get(int(params.split(";")[0]), 27)
                except ValueError:
                    return 27
            return _CSI_FINAL.get(c, 27)
        return 27
    finally:
        win.timeout(-1)


def init_colors():
    curses.start_color()
    curses.use_default_colors()
    pairs = {
        C_DEFAULT: (curses.COLOR_WHITE, -1),
        C_HUB: (curses.COLOR_MAGENTA, -1),
        C_STP: (curses.COLOR_CYAN, -1),
        C_CORE: (curses.COLOR_GREEN, -1),
        C_RADIO: (curses.COLOR_YELLOW, -1),
        C_DATA: (curses.COLOR_BLUE, -1),
        C_CONSOLE: (curses.COLOR_WHITE, -1),
        C_BAR: (curses.COLOR_BLACK, curses.COLOR_CYAN),
        C_WARN: (curses.COLOR_RED, -1),
        C_OK: (curses.COLOR_GREEN, -1),
    }
    for idx, (fg, bg) in pairs.items():
        try:
            curses.init_pair(idx, fg, bg)
        except curses.error:
            pass


class App(object):
    def __init__(self, stdscr, topo):
        self.scr = stdscr
        self.topo = topo
        self.pool = vty_mod.VtyPool(docker=topo.docker)
        self.client = None
        self.local_pc = topo.free_point_code()
        self.local_ssn = mapops.SSN_MSC
        self.sel = 0
        self.top = 0
        self.left = 0
        self.status = "Bienvenue. Fleches pour circuler, Entree pour ouvrir, ? pour l'aide."
        self.status_attr = C_DEFAULT
        self.rebuild()

    # ── etat ─────────────────────────────────────────────────────────────
    def rebuild(self):
        extra = {"local_pc": self.local_pc, "local_ssn": self.local_ssn,
                 "state": (self.client.asp.state if self.client and self.client.asp
                           else "hors ligne")}
        self.lines, self.boxes = diagram.build(self.topo, extra)
        self.sel = min(self.sel, max(0, len(self.boxes) - 1))

    def say(self, text, attr=C_DEFAULT):
        self.status = text
        self.status_attr = attr

    # ── dessin ───────────────────────────────────────────────────────────
    def draw(self):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        title = " CONSOLE SS7 - osmo_egprs "
        link = "M3UA %s" % (self.client.asp.state if self.client and self.client.asp
                            else "hors ligne")
        head = "%s| %s operateur(s) | hub %s:%s | console PC %s | %s" % (
            title, len(self.topo.operators), self.topo.hub_ip or "?",
            self.topo.hub_port, self.local_pc, link)
        self.scr.attron(curses.color_pair(C_BAR))
        self.scr.addstr(0, 0, head.ljust(w - 1)[:w - 1])
        self.scr.attroff(curses.color_pair(C_BAR))

        view_h = h - 3
        self.draw_map(1, view_h, w)

        foot = ("fleches:circuler  Entree:ouvrir  v:VTY  s:script SS7  "
                "a:audit  c:lien M3UA  r:relire  ?:aide  q:quitter")
        self.scr.attron(curses.color_pair(C_BAR))
        self.scr.addstr(h - 1, 0, foot.ljust(w - 1)[:w - 1])
        self.scr.attroff(curses.color_pair(C_BAR))
        self.scr.attron(curses.color_pair(self.status_attr))
        self.scr.addstr(h - 2, 0, self.status.ljust(w - 1)[:w - 1])
        self.scr.attroff(curses.color_pair(self.status_attr))
        self.scr.noutrefresh()
        curses.doupdate()

    def _scroll_to_selection(self, view_h, view_w):
        if not self.boxes:
            return
        b = self.boxes[self.sel]
        if b.y < self.top:
            self.top = max(0, b.y - 1)
        if b.y + b.h > self.top + view_h:
            self.top = b.y + b.h - view_h
        if b.x < self.left:
            self.left = max(0, b.x - 2)
        if b.x + b.w > self.left + view_w:
            self.left = b.x + b.w - view_w + 2
        self.top = max(0, self.top)
        self.left = max(0, self.left)

    def draw_map(self, y0, view_h, view_w):
        self._scroll_to_selection(view_h, view_w)
        for row in range(view_h):
            src = self.top + row
            if src >= len(self.lines):
                break
            text = self.lines[src][self.left:self.left + view_w - 1]
            try:
                self.scr.addstr(y0 + row, 0, text)
            except curses.error:
                pass
        for i, b in enumerate(self.boxes):
            attr = curses.color_pair(self._box_color(b))
            if i == self.sel:
                attr = curses.color_pair(self._box_color(b)) | curses.A_REVERSE | curses.A_BOLD
            for row in range(b.h):
                src = b.y + row
                if src < self.top or src >= self.top + view_h:
                    continue
                if src >= len(self.lines):
                    continue
                line = self.lines[src]
                seg = line[b.x:b.x + b.w].ljust(b.w)
                sx = b.x - self.left
                if sx < 0 or sx + b.w > view_w - 1:
                    seg = seg[max(0, -sx):max(0, view_w - 1 - max(sx, 0))]
                    sx = max(sx, 0)
                try:
                    self.scr.addstr(y0 + src - self.top, sx, seg, attr)
                except curses.error:
                    pass

    def _box_color(self, b):
        if b.kind == "hub":
            return C_HUB
        if b.kind == "console":
            return C_CONSOLE
        if b.kind == "stp":
            return C_STP
        if b.ref is not None and getattr(b.ref, "family", None):
            return FAMILY_COLOR.get(b.ref.family, C_DEFAULT)
        return C_DEFAULT

    # ── fenetres generiques ──────────────────────────────────────────────
    def _win(self, height, width, title):
        h, w = self.scr.getmaxyx()
        height = min(height, h - 2)
        width = min(width, w - 2)
        y = max(0, (h - height) // 2)
        x = max(0, (w - width) // 2)
        win = curses.newwin(height, width, y, x)
        win.keypad(True)
        win.box()
        win.addstr(0, 2, " %s " % title[:width - 6], curses.A_BOLD)
        return win

    def menu(self, title, items, footer="fleches + Entree, Echap pour revenir"):
        """items : liste de (etiquette, valeur). Rend la valeur, ou None."""
        if not items:
            self.show_text(title, ["(rien a proposer ici)"])
            return None
        idx = 0
        width = max([len(title) + 8] + [len(i[0]) + 8 for i in items] + [len(footer) + 6])
        win = self._win(len(items) + 4, min(width, 100), title)
        while True:
            win.erase()
            win.box()
            win.addstr(0, 2, " %s " % title, curses.A_BOLD)
            for i, (label, _val) in enumerate(items):
                attr = curses.A_REVERSE if i == idx else curses.A_NORMAL
                try:
                    win.addstr(1 + i, 2, ("%-*s" % (win.getmaxyx()[1] - 4, label))[
                        :win.getmaxyx()[1] - 4], attr)
                except curses.error:
                    pass
            try:
                win.addstr(win.getmaxyx()[0] - 2, 2, footer[:win.getmaxyx()[1] - 4],
                           curses.A_DIM)
            except curses.error:
                pass
            win.refresh()
            key = read_key(win)
            if key in (curses.KEY_UP, ord("k")):
                idx = (idx - 1) % len(items)
            elif key in (curses.KEY_DOWN, ord("j")):
                idx = (idx + 1) % len(items)
            elif key in (curses.KEY_HOME,):
                idx = 0
            elif key in (curses.KEY_END,):
                idx = len(items) - 1
            elif key in (10, 13, curses.KEY_ENTER, curses.KEY_RIGHT):
                return items[idx][1]
            elif key in (27, curses.KEY_LEFT, ord("q")):
                return None
            elif key == curses.KEY_RESIZE:
                self.draw()

    def show_text(self, title, lines, wrap=True):
        """Zone de texte defilante. Echap ou q pour revenir."""
        h, w = self.scr.getmaxyx()
        win = self._win(h - 2, w - 2, title)
        inner_h = win.getmaxyx()[0] - 3
        inner_w = win.getmaxyx()[1] - 4
        flat = []
        for line in lines:
            line = line.replace("\t", "    ")
            if wrap:
                while len(line) > inner_w:
                    flat.append(line[:inner_w])
                    line = line[inner_w:]
            flat.append(line[:inner_w])
        pos = 0
        while True:
            win.erase()
            win.box()
            win.addstr(0, 2, " %s " % title[:inner_w], curses.A_BOLD)
            for i in range(inner_h):
                if pos + i >= len(flat):
                    break
                try:
                    win.addstr(1 + i, 2, flat[pos + i])
                except curses.error:
                    pass
            hint = "fleches/PagePrec/PageSuiv pour defiler - Echap pour revenir"
            if len(flat) > inner_h:
                hint = "%d/%d - %s" % (pos + 1, len(flat), hint)
            try:
                win.addstr(win.getmaxyx()[0] - 2, 2, hint[:inner_w], curses.A_DIM)
            except curses.error:
                pass
            win.refresh()
            key = read_key(win)
            if key in (27, ord("q")):
                return
            elif key == curses.KEY_DOWN:
                pos = min(max(0, len(flat) - inner_h), pos + 1)
            elif key == curses.KEY_UP:
                pos = max(0, pos - 1)
            elif key == curses.KEY_NPAGE:
                pos = min(max(0, len(flat) - inner_h), pos + inner_h)
            elif key == curses.KEY_PPAGE:
                pos = max(0, pos - inner_h)
            elif key == curses.KEY_HOME:
                pos = 0
            elif key == curses.KEY_END:
                pos = max(0, len(flat) - inner_h)
            elif key == curses.KEY_RESIZE:
                self.draw()
                return

    def form(self, title, fields, note=""):
        """fields : liste de dicts {key,label,value,help}. Rend un dict ou None.

        Navigation : haut/bas entre les champs, frappe pour editer, Entree sur
        [ Envoyer ] pour valider, Echap pour abandonner."""
        idx = 0
        rows = fields + [{"key": "__submit__", "label": "[ Envoyer ]", "value": "",
                          "help": "Entree pour lancer"}]
        height = len(rows) + (6 if note else 5)
        width = 78
        win = self._win(height, width, title)
        inner_w = win.getmaxyx()[1] - 4
        while True:
            win.erase()
            win.box()
            win.addstr(0, 2, " %s " % title, curses.A_BOLD)
            y = 1
            if note:
                win.addstr(y, 2, note[:inner_w], curses.A_DIM)
                y += 1
            for i, f in enumerate(rows):
                attr = curses.A_REVERSE if i == idx else curses.A_NORMAL
                if f["key"] == "__submit__":
                    win.addstr(y + i, 2, ("%-*s" % (inner_w, f["label"]))[:inner_w],
                               attr | curses.A_BOLD)
                else:
                    label = "%-26s" % f["label"][:26]
                    val = str(f.get("value", ""))
                    win.addstr(y + i, 2, label, curses.A_NORMAL)
                    win.addstr(y + i, 2 + len(label),
                               ("%-*s" % (inner_w - len(label), val))[:inner_w - len(label)],
                               attr)
            cur = rows[idx]
            hint = cur.get("help") or "haut/bas : champ suivant - Echap : abandonner"
            try:
                win.addstr(win.getmaxyx()[0] - 2, 2, hint[:inner_w], curses.A_DIM)
            except curses.error:
                pass
            win.refresh()
            key = read_key(win)
            if key == 27:
                return None
            if key in (curses.KEY_UP,):
                idx = (idx - 1) % len(rows)
            elif key in (curses.KEY_DOWN, 9):
                idx = (idx + 1) % len(rows)
            elif key in (10, 13, curses.KEY_ENTER):
                if rows[idx]["key"] == "__submit__":
                    return dict((f["key"], f.get("value", "")) for f in fields)
                idx = (idx + 1) % len(rows)
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                if cur["key"] != "__submit__":
                    cur["value"] = str(cur.get("value", ""))[:-1]
            elif key == 21:                      # Ctrl-U
                if cur["key"] != "__submit__":
                    cur["value"] = ""
            elif key == curses.KEY_RESIZE:
                self.draw()
            elif 32 <= key < 127 and cur["key"] != "__submit__":
                cur["value"] = str(cur.get("value", "")) + chr(key)

    def confirm(self, question):
        return self.menu(question, [("Oui", True), ("Non", False)]) is True

    # ── VTY ──────────────────────────────────────────────────────────────
    def vty_view(self, node, port, label):
        try:
            sess = self.pool.get(node, port)
        except vty_mod.VtyError as exc:
            self.say("VTY %s:%s - %s" % (node, port, exc), C_WARN)
            return
        lines = [l for l in (sess.banner or "").split("\n") if l.strip()]
        lines.append("")
        lines.append("--- Echap ferme cette session et revient au schema ---")
        history = []
        hpos = 0
        current = ""
        scroll = None
        h, w = self.scr.getmaxyx()
        win = curses.newwin(h, w, 0, 0)
        win.keypad(True)
        while True:
            win.erase()
            head = " VTY %s - %s (port %d) " % (label, node, port)
            win.attron(curses.color_pair(C_BAR))
            win.addstr(0, 0, head.ljust(w - 1)[:w - 1])
            win.attroff(curses.color_pair(C_BAR))
            body_h = h - 3
            view = lines if scroll is None else lines[:scroll + body_h]
            start = max(0, len(view) - body_h)
            for i, line in enumerate(view[start:start + body_h]):
                try:
                    win.addstr(1 + i, 0, line[:w - 1])
                except curses.error:
                    pass
            foot = ("Entree:envoyer  haut/bas:historique  PagePrec/Suiv:defiler  "
                    "Echap:fermer ce VTY")
            win.attron(curses.color_pair(C_BAR))
            win.addstr(h - 2, 0, foot.ljust(w - 1)[:w - 1])
            win.attroff(curses.color_pair(C_BAR))
            prompt = "%s> " % label
            win.addstr(h - 1, 0, (prompt + current)[:w - 1], curses.A_BOLD)
            win.move(h - 1, min(w - 1, len(prompt) + len(current)))
            win.refresh()
            key = read_key(win)
            if key == 27:
                self.pool.drop(node, port)
                self.say("VTY %s:%s ferme - les autres VTY restent ouverts."
                         % (node, port), C_OK)
                return
            if key in (10, 13, curses.KEY_ENTER):
                cmd = current.strip()
                current = ""
                if not cmd:
                    continue
                if cmd in ("quit", "exit"):
                    self.pool.drop(node, port)
                    return
                history.append(cmd)
                hpos = len(history)
                lines.append("")
                lines.append("%s> %s" % (label, cmd))
                try:
                    out = sess.cmd(cmd)
                except vty_mod.VtyError as exc:
                    out = "[session perdue : %s]" % exc
                rows = out.split("\n")
                # Le VTY renvoie la commande en echo : elle est deja affichee
                # au-dessus, on ne la montre pas deux fois.
                if rows and rows[0].strip() == cmd:
                    rows = rows[1:]
                lines.extend(rows)
                scroll = None
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                current = current[:-1]
            elif key == 21:
                current = ""
            elif key == curses.KEY_UP:
                if history:
                    hpos = max(0, hpos - 1)
                    current = history[hpos]
            elif key == curses.KEY_DOWN:
                if history:
                    hpos = min(len(history), hpos + 1)
                    current = history[hpos] if hpos < len(history) else ""
            elif key == curses.KEY_PPAGE:
                base = len(lines) if scroll is None else scroll
                scroll = max(0, base - (h - 3))
            elif key == curses.KEY_NPAGE:
                if scroll is not None:
                    scroll += h - 3
                    if scroll >= len(lines):
                        scroll = None
            elif key == curses.KEY_RESIZE:
                h, w = self.scr.getmaxyx()
                win = curses.newwin(h, w, 0, 0)
                win.keypad(True)
            elif 32 <= key < 127:
                current += chr(key)

    # ── lien SS7 ─────────────────────────────────────────────────────────
    def ensure_link(self):
        if self.client and self.client.connected:
            return True
        if not self.topo.hub_ip:
            self.say("aucun hub SS7 connu : pas de lien M3UA possible", C_WARN)
            return False
        self.say("connexion M3UA vers %s:%s ..." % (self.topo.hub_ip, self.topo.hub_port))
        self.draw()
        try:
            self.client = ss7.Ss7Client(self.topo.hub_ip, self.topo.hub_port,
                                        self.local_pc, self.local_ssn)
            state = self.client.connect()
        except Exception as exc:
            self.say("lien M3UA impossible : %s" % exc, C_WARN)
            self.client = None
            return False
        self.rebuild()
        self.say("lien M3UA %s - la console est un ASP du hub (PC %s)"
                 % (state, self.local_pc), C_OK)
        return True

    def toggle_link(self):
        if self.client and self.client.connected:
            self.client.close()
            self.client = None
            self.rebuild()
            self.say("lien M3UA ferme", C_WARN)
        else:
            self.ensure_link()

    def audit_dialog(self, default_pc=""):
        if not self.ensure_link():
            return
        vals = self.form("Audit SS7 (DAUD)", [
            {"key": "pc", "label": "Point code a auditer", "value": default_pc,
             "help": "ex 1.11.1 - le STP repond DAVA (joignable) ou DUNA"},
        ])
        if not vals or not vals["pc"].strip():
            return
        rep = self.client.audit(vals["pc"].strip())
        self.show_text("Audit %s" % vals["pc"], rep.lines + [""] +
                       ["Journal du lien :"] + self.client.events[-12:])

    def map_dialog(self, default_pc="", default_ssn=None):
        if not self.ensure_link():
            return
        items = [("%-22s %s" % (o.key, o.name), o.key) for o in mapops.OPERATIONS]
        key = self.menu("Operations MAP - schema %s" % self.local_pc, items)
        if key is None:
            return
        op = mapops.BY_KEY[key]
        fields = []
        for p in op.params:
            fields.append({"key": p.key, "label": p.label, "value": p.default,
                           "help": p.help})
        fields.append({"key": "__pc", "label": "Point code destination",
                       "value": default_pc or (self.topo.operators[0].sccp.get(
                           "addr-msc", {}).get("pc", "") if self.topo.operators else ""),
                       "help": "ou vide si routage sur GT"})
        fields.append({"key": "__ssn", "label": "SSN destination",
                       "value": str(default_ssn if default_ssn else op.ssn),
                       "help": "6 HLR, 7 VLR, 8 MSC, 147 gsmSCF, 254 BSSAP"})
        fields.append({"key": "__gt", "label": "Global title destination",
                       "value": "", "help": "laisser vide pour router sur PC/SSN"})
        vals = self.form("%s (opcode %d)" % (op.name, op.opcode), fields,
                         note=op.summary[:74])
        if vals is None:
            return
        dest_pc = vals.pop("__pc").strip()
        dest_ssn = vals.pop("__ssn").strip()
        dest_gt = vals.pop("__gt").strip()
        if not dest_pc and not dest_gt:
            self.say("il faut au moins un point code ou un global title", C_WARN)
            return
        self.say("emission de %s ..." % op.name)
        self.draw()
        try:
            rep = self.client.send_map(op, vals, dest_pc or "0.0.0",
                                       int(dest_ssn) if dest_ssn else None,
                                       dest_gt, route_on_gt=bool(dest_gt and not dest_pc))
        except Exception as exc:
            self.show_text("Echec", ["%s : %s" % (type(exc).__name__, exc)])
            return
        lines = rep.lines + ["", "Journal du lien :"] + self.client.events[-10:]
        lines += ["", "e : exporter cet envoi en script Python autonome",
                  "Echap : revenir"]
        self.show_text("%s -> %s" % (op.name, dest_gt or dest_pc), lines)
        if self.confirm("Exporter cet envoi en script Python ?"):
            path = export_script(op, vals, dest_pc, dest_ssn, dest_gt,
                                 self.local_pc, self.topo)
            self.show_text("Script ecrit", [
                "Le script autonome est ecrit dans :", "", "  %s" % path, "",
                "Il rejoue exactement cet envoi :",
                "  python3 %s" % os.path.relpath(path, topo_mod.REPO)])

    # ── menus des boites ─────────────────────────────────────────────────
    def open_box(self, box):
        if box.kind == "console":
            self.console_menu()
        elif box.kind == "hub":
            self.hub_menu(box)
        elif box.kind == "stp":
            self.stp_menu(box)
        elif box.kind == "service":
            self.service_menu(box)

    def console_menu(self):
        connected = bool(self.client and self.client.connected)
        items = [
            ("Deconnecter le lien M3UA" if connected else "Connecter le lien M3UA",
             "link"),
            ("Operations MAP (sendRoutingInfo, SRI-SM, ATI...)", "map"),
            ("Audit d'un point code (DAUD)", "audit"),
            ("Journal du lien M3UA", "log"),
            ("Changer le point code de la console", "pc"),
            ("Informations", "info"),
        ]
        action = self.menu("CONSOLE SS7 (PC %s)" % self.local_pc, items)
        if action == "link":
            self.toggle_link()
        elif action == "map":
            self.map_dialog()
        elif action == "audit":
            self.audit_dialog()
        elif action == "log":
            self.show_text("Journal M3UA",
                           self.client.events if self.client else ["(pas de lien)"])
        elif action == "pc":
            vals = self.form("Point code de la console", [
                {"key": "pc", "label": "Point code", "value": self.local_pc,
                 "help": "il sera enregistre sur le hub par RKM dynamique"},
                {"key": "ssn", "label": "SSN local", "value": str(self.local_ssn),
                 "help": "identite SCCP de la console"}])
            if vals:
                self.local_pc = vals["pc"].strip() or self.local_pc
                try:
                    self.local_ssn = int(vals["ssn"])
                except ValueError:
                    pass
                if self.client:
                    self.client.close()
                    self.client = None
                self.rebuild()
                self.say("console : PC %s, SSN %d" % (self.local_pc, self.local_ssn))
        elif action == "info":
            self.show_text("Console SS7", [
                "La console se connecte a l'inter-STP en M3UA sur SCTP et",
                "enregistre dynamiquement une routing key pour son point code.",
                "",
                "  hub          : %s:%s" % (self.topo.hub_ip, self.topo.hub_port),
                "  point code   : %s" % self.local_pc,
                "  SSN local    : %s" % self.local_ssn,
                "  etat         : %s" % (self.client.asp.state if self.client
                                         and self.client.asp else "hors ligne"),
                "",
                "Tout ce qu'elle emet passe par le meme chemin SS7 que le trafic",
                "des operateurs : c'est le lab qui route, pas une simulation.",
            ])

    def hub_menu(self, box):
        node = box.ref
        items = [("Etat du lien M3UA de la console", "link"),
                 ("Auditer un point code a travers le hub", "audit"),
                 ("Journal M3UA", "log")]
        if node and node.name != "hub-distant":
            items.insert(0, ("Ouvrir le VTY du hub (STP)", "vty"))
        else:
            items.append(("Pourquoi le hub n'a pas de VTY ici", "why"))
        action = self.menu("INTER-STP %s" % (self.topo.hub_ip or ""), items)
        if action == "vty":
            self.vty_view(node.name, 4239, "hub-STP")
        elif action == "audit":
            self.audit_dialog()
        elif action == "link":
            self.console_menu()
        elif action == "log":
            self.show_text("Journal M3UA",
                           self.client.events if self.client else ["(pas de lien)"])
        elif action == "why":
            self.show_text("Hub distant", [
                "Le hub tourne sur %s : ce n'est pas cette machine." % self.topo.hub_ip,
                "",
                "Le VTY d'Osmocom n'ecoute que sur la boucle locale de SON noeud :",
                "il n'est donc pas interrogeable d'ici. Ce qui l'est, en revanche :",
                "",
                "  - le lien M3UA/SCTP de chaque operateur vers le hub ;",
                "  - l'etat des AS et ASP vus du cote operateur (VTY du STP local) ;",
                "  - l'audit DAUD d'un point code a travers le hub.",
                "",
                "Sur le noeud du hub : ./start-interstp.sh --status",
            ])

    def stp_menu(self, box):
        node = box.ref
        items = [("Ouvrir le VTY du STP (4239)", "vty"),
                 ("AS / ASP / routes (vue rapide)", "quick"),
                 ("Auditer le point code %s" % node.point_code, "audit"),
                 ("Cibler ce noeud en MAP", "map"),
                 ("Configuration heritee (osmo-stp.cfg)", "cfg"),
                 ("Informations", "info")]
        action = self.menu("%s - STP %s" % (node.title, node.point_code), items)
        if action == "vty":
            self.vty_view(node.name, 4239, "%s-STP" % node.title)
        elif action == "quick":
            self.quick_menu(node, "OsmoSTP", 4239)
        elif action == "audit":
            self.audit_dialog(node.point_code)
        elif action == "map":
            self.map_dialog(node.point_code)
        elif action == "cfg":
            self.show_text("osmo-stp.cfg (%s)" % node.name,
                           node.cfg.get("osmo-stp.cfg", "(non lu)").split("\n"),
                           wrap=False)
        elif action == "info":
            lines = ["noeud        : %s" % node.name,
                     "point code   : %s" % node.point_code,
                     "M3UA local   : %s" % node.local_m3ua,
                     "hub          : %s:%s" % (node.hub_ip, node.hub_port),
                     "routing key  : %s" % node.routing_ctx,
                     "noeud WAN    : %s" % (node.wan_node or "-"),
                     "", "Adresses SCCP heritees des configurations :"]
            for name, addr in sorted(node.sccp.items()):
                lines.append("  %-22s PC %-8s SSN %-4s (%s)" % (
                    name, addr.get("pc") or "-", addr.get("ssn") or "-",
                    addr.get("source")))
            lines += ["", "Services VTY decouverts :"]
            for s in node.services:
                lines.append("  %-12s port %s" % (s.label, s.port))
            self.show_text("Informations %s" % node.title, lines)

    def service_menu(self, box):
        svc = box.ref
        node = box.node
        items = [("Ouvrir le VTY (%d)" % svc.port, "vty"),
                 ("Commandes rapides", "quick"),
                 ("Informations", "info")]
        if svc.daemon in ("OsmoMSC", "OsmoHLR", "OsmoSGSN"):
            items.insert(2, ("Cibler ce demon en MAP", "map"))
        action = self.menu("%s - %s" % (node.title, svc.label), items)
        if action == "vty":
            self.vty_view(node.name, svc.port, "%s-%s" % (node.title, svc.label))
        elif action == "quick":
            self.quick_menu(node, svc.daemon, svc.port)
        elif action == "map":
            ssn = {"OsmoHLR": mapops.SSN_HLR, "OsmoMSC": mapops.SSN_MSC,
                   "OsmoSGSN": 149}.get(svc.daemon, mapops.SSN_HLR)
            pc = ""
            for key in ("addr-msc", "addr-bsc"):
                if key in node.sccp and node.sccp[key].get("pc"):
                    pc = node.sccp[key]["pc"]
                    break
            if svc.daemon == "OsmoMSC" and node.sccp.get("_self_osmo-msc.cfg"):
                pc = node.sccp["_self_osmo-msc.cfg"].get("pc") or pc
            self.map_dialog(pc or node.point_code, ssn)
        elif action == "info":
            self.show_text("%s sur %s" % (svc.label, node.name), [
                "demon        : %s" % svc.daemon,
                "port VTY     : %s" % svc.port,
                "famille      : %s" % svc.family,
                "noeud        : %s (%s)" % (node.name, node.point_code),
                "",
                "Echap ferme un VTY sans fermer les autres : la console garde",
                "une session par port, et le schema reste accessible.",
            ])

    def quick_menu(self, node, daemon, port):
        cmds = quickcmd.for_daemon(daemon)
        items = [("%-32s %s" % (label, cmd), cmd) for label, cmd in cmds]
        cmd = self.menu("Commandes rapides - %s" % daemon, items)
        if cmd is None:
            return
        try:
            out = self.pool.cmd(node.name, port, cmd)
        except vty_mod.VtyError as exc:
            out = "[VTY indisponible : %s]" % exc
        self.show_text("%s : %s" % (node.name, cmd), out.split("\n"), wrap=False)

    # ── boucle principale ────────────────────────────────────────────────
    # Les raccourcis sont en MINUSCULES uniquement : les sequences de fleches
    # se terminent par A, B, C ou D, et une sequence mal decoupee par le
    # terminal arriverait sinon comme un raccourci - une fleche fermerait le
    # lien M3UA. Avec des minuscules seules, le pire cas ne fait rien.
    def run(self):
        while True:
            self.draw()
            key = read_key(self.scr)
            if key == ord("q"):
                if self.pool.sessions and not self.confirm(
                        "Des sessions VTY sont ouvertes. Quitter ?"):
                    continue
                return
            elif key == curses.KEY_RESIZE:
                continue
            elif key == curses.KEY_UP:
                self.sel = diagram.navigate(self.boxes, self.sel, (0, -1))
            elif key == curses.KEY_DOWN:
                self.sel = diagram.navigate(self.boxes, self.sel, (0, 1))
            elif key == curses.KEY_LEFT:
                self.sel = diagram.navigate(self.boxes, self.sel, (-1, 0))
            elif key == curses.KEY_RIGHT:
                self.sel = diagram.navigate(self.boxes, self.sel, (1, 0))
            elif key == 9:
                self.sel = (self.sel + 1) % max(1, len(self.boxes))
            elif key == curses.KEY_BTAB:
                self.sel = (self.sel - 1) % max(1, len(self.boxes))
            elif key in (10, 13, curses.KEY_ENTER):
                if self.boxes:
                    self.open_box(self.boxes[self.sel])
            elif key == ord("v"):
                self.direct_vty()
            elif key == ord("s"):
                box = self.boxes[self.sel] if self.boxes else None
                pc = box.node.point_code if box and box.node else ""
                self.map_dialog(pc)
            elif key == ord("a"):
                box = self.boxes[self.sel] if self.boxes else None
                self.audit_dialog(box.node.point_code if box and box.node else "")
            elif key == ord("c"):
                self.toggle_link()
            elif key == ord("j"):
                self.show_text("Journal M3UA",
                               self.client.events if self.client else ["(pas de lien)"])
            elif key == ord("r"):
                self.say("redecouverte de la topologie ...")
                self.draw()
                self.pool.close_all()
                self.topo = topo_mod.discover()
                self.rebuild()
                self.say("topologie relue : %d operateur(s), hub %s"
                         % (len(self.topo.operators), self.topo.hub_ip or "-"), C_OK)
            elif key in (ord("?"), ord("h")):
                self.show_text("Aide", HELP)
            elif key == 27:
                self.say("Echap : deja au schema. q pour quitter, ? pour l'aide.")

    def direct_vty(self):
        if not self.boxes:
            return
        box = self.boxes[self.sel]
        if box.kind == "service":
            self.vty_view(box.node.name, box.ref.port,
                          "%s-%s" % (box.node.title, box.ref.label))
        elif box.kind == "stp":
            self.vty_view(box.ref.name, 4239, "%s-STP" % box.ref.title)
        elif box.kind == "hub" and box.ref and box.ref.name != "hub-distant":
            self.vty_view(box.ref.name, 4239, "hub-STP")
        else:
            self.say("cet element n'a pas de VTY joignable depuis ici", C_WARN)


def export_script(op, values, dest_pc, dest_ssn, dest_gt, local_pc, topo):
    """Ecrit un script Python autonome qui rejoue exactement cet envoi."""
    out_dir = os.path.join(topo_mod.REPO, "navigation", "scripts")
    os.makedirs(out_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = os.path.join(out_dir, "%s-%s.py" % (op.key, stamp))
    body = '''#!/usr/bin/env python3
# Genere par la console SS7 (navigation/) le {stamp}.
# Rejoue un envoi MAP {name} vers {dest}.
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from navigation import ss7

client = ss7.Ss7Client({hub!r}, {port!r}, local_pc={local!r})
print("lien M3UA :", client.connect())
rapport = client.send_map({op!r}, {values!r},
                          dest_pc={pc!r}, dest_ssn={ssn!r}, dest_gt={gt!r},
                          route_on_gt={rogt!r})
print(rapport)
client.close()
'''.format(stamp=stamp, name=op.name, dest=dest_gt or dest_pc,
           hub=topo.hub_ip, port=topo.hub_port, local=local_pc, op=op.key,
           values=values, pc=dest_pc or "0.0.0",
           ssn=int(dest_ssn) if dest_ssn else op.ssn, gt=dest_gt,
           rogt=bool(dest_gt and not dest_pc))
    with open(path, "w") as fh:
        fh.write(body)
    os.chmod(path, 0o755)
    return path


def main(topo):
    def _run(stdscr):
        curses.curs_set(0)
        try:
            curses.set_escdelay(60)
        except Exception:
            pass
        init_colors()
        stdscr.keypad(True)
        app = App(stdscr, topo)
        try:
            app.run()
        finally:
            app.pool.close_all()
            if app.client:
                app.client.close()
    curses.wrapper(_run)
