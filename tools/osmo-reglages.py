#!/usr/bin/env python3
# Web page to configure the Osmocom stack of the bench.
#
#   python3 tools/osmo-reglages.py [--port 8090] [--bind 127.0.0.1]
#   puis http://127.0.0.1:8090/
#
# The page is in web/ (index.html, style.css, app.js); this script serves it and provides
# the /api/... API. Four tabs:
#   globals.conf : form on the model of globals.conf.example (tools/globals-complet.py:
#               network settings + all launcher variables), values read from and
#               written back to globals.conf
#   Demons    : running-config of each daemon read through the VTY, each line editable
#               live (configure terminal + node path + line), "no", add, write memory,
#               free VTY console
#   Fichiers  : raw editing of configs/*.cfg and /etc/osmocom/*.cfg (backup)
#   Etat      : osmo-* processes, ports, useful counters
# Nothing is restarted: VTY changes are immediate, globals.conf and the files are
# used by the next run. Listens on 127.0.0.1 only: the VTY console executes anything.
# Standard library only.

import argparse, glob, html, json, os, re, shutil, socket, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLOBALS = os.path.join(RACINE, "globals.conf")
EXEMPLE = GLOBALS + ".example"
WEB = os.path.join(RACINE, "web")
TYPES = {".html": "text/html", ".css": "text/css", ".js": "application/javascript", ".svg": "image/svg+xml", ".png": "image/png"}
DOSSIERS_CFG = [os.path.join(RACINE, "configs"), "/etc/osmocom", "/root/.osmocom/bb"]
PROMPT = re.compile(rb"[\r\n][^\r\n]*[>#] ?$")


# ── VTY ────────────────────────────────────────────────────

class Vty:
    def __init__(self, hote, port, delai=4.0):
        self.s = socket.create_connection((hote, port), 2)
        self.s.settimeout(delai)
        self.lire()
        self.cmd("enable")

    def lire(self):
        b = b""
        while True:
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                break
            if not d:
                break
            b += d
            b = re.sub(rb"\xff[\xfb-\xfe].", b"", b)  # negociation telnet (IAC WILL/WONT/DO/DONT)
            if PROMPT.search(b):
                break
        return b.decode("utf-8", "replace")

    def cmd(self, ligne):
        self.s.sendall(ligne.encode() + b"\r\n")
        r = self.lire().replace("\r", "")
                # strip the echo and the final prompt
        l = r.split("\n")
        if l and l[0].strip() == ligne.strip():
            l = l[1:]
        if l and re.search(r"[>#] ?$", l[-1]):
            l = l[:-1]
        return "\n".join(l)

    def fermer(self):
        try:
            self.s.sendall(b"exit\r\n")
            self.s.close()
        except OSError:
            pass


_cache_vty = {"t": 0, "liste": []}


def demons_vty():
    """Listening ports of the osmo-* and of mobile, probed: the VTY answers with a banner."""
    if time.time() - _cache_vty["t"] < 15:
        return _cache_vty["liste"]
    out = subprocess.run(["ss", "-ltnpH"], capture_output=True, text=True).stdout
    vus, liste = set(), []
    for l in out.splitlines():
        m = re.search(r"\s(\d+\.\d+\.\d+\.\d+):(\d+)\s.*users:\(\(\"([^\"]+)\",pid=(\d+)", l)
        if not m:
            continue
        hote, port, nom, pid = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        if not (nom.startswith("osmo") or nom == "mobile") or (hote, port) in vus:
            continue
        vus.add((hote, port))
        try:
            s = socket.create_connection((hote, port), 0.5)
            s.settimeout(0.6)
            b = b""
            try:
                while len(b) < 4096:
                    d = s.recv(4096)
                    if not d:
                        break
                    b += d
                    if PROMPT.search(b):
                        break
            except socket.timeout:
                pass
            s.close()
        except OSError:
            continue
        t = b.decode("latin-1", "replace")
        if "VTY" not in t and not re.search(r"[>#] ?$", t):
            continue  # port CTRL / GSUP / autre
        invite = re.findall(r"([\w.-]+)[>#] ?$", t)
        liste.append({"hote": hote, "port": port, "nom": nom, "pid": pid,
                      "invite": invite[-1] if invite else nom})
    liste.sort(key=lambda d: (d["nom"], d["hote"], d["port"]))
    _cache_vty.update(t=time.time(), liste=liste)
    return liste


def arbre_config(texte):
    """running-config -> list of lines {txt, prof, chemin[], noeud}."""
    lignes = []
    for brut in texte.split("\n"):
        if not brut.strip() or brut.strip() == "!" or brut.startswith("Current configuration"):
            continue
        prof = len(brut) - len(brut.lstrip(" "))
        lignes.append([prof, brut.strip()])
    sortie, pile = [], []
    for i, (prof, txt) in enumerate(lignes):
        while pile and pile[-1][0] >= prof:
            pile.pop()
        noeud = i + 1 < len(lignes) and lignes[i + 1][0] > prof
        sortie.append({"txt": txt, "prof": prof, "chemin": [p[1] for p in pile], "noeud": noeud})
        if noeud:
            pile.append((prof, txt))
    return sortie


def appliquer(hote, port, chemin, lignes):
    v = Vty(hote, port)
    journal = []
    try:
        journal.append(("configure terminal", v.cmd("configure terminal")))
        for c in chemin:
            journal.append((c, v.cmd(c)))
        for l in lignes:
            journal.append((l, v.cmd(l)))
        journal.append(("end", v.cmd("end")))
    finally:
        v.fermer()
    erreur = any(r.lstrip().startswith("%") for _, r in journal)
    return {"ok": not erreur,
            "journal": "\n".join("> " + c + ("\n" + r if r.strip() else "") for c, r in journal)}


def console(hote, port, lignes):
    v = Vty(hote, port, delai=6.0)
    try:
        out = []
        for l in lignes:
            if l.strip():
                out.append("> " + l + "\n" + v.cmd(l))
        return "\n".join(out)
    finally:
        v.fermer()


# ── globals.conf ───────────────────────────────────────────

LIGNE_VAR = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")


def _valeur(brut):
    v = brut.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def _valeurs(chemin):
    r = {}
    if os.path.exists(chemin):
        for l in open(chemin, encoding="utf-8"):
            m = LIGNE_VAR.match(l.rstrip("\n"))
            if m:
                r[m.group(1)] = _valeur(m.group(2))
    return r


def _patron():
    return EXEMPLE if os.path.exists(EXEMPLE) else GLOBALS


def lire_globals(patron=None, actuelles=None):
    """The template fields (order, section, comment, default, choices) with the current values."""
    if actuelles is None:
        actuelles = _valeurs(GLOBALS)
    champs, section, doc = [], "", []
    for l in open(patron or _patron(), encoding="utf-8"):
        l = l.rstrip("\n")
        m = re.match(r"#\s*──\s*(.+?)\s*─", l)
        if m:
            section, doc = m.group(1), []
            continue
        if l.startswith("#"):
            if section:
                doc.append(l.lstrip("# ").rstrip())
            continue
        m = LIGNE_VAR.match(l)
        if m:
            cle = m.group(1)
            defaut, choix = "", []
            for d in doc:
                md = re.match(r"defaut : (.*?)\s+\(\S+:\d+\)$", d)
                if md:
                    defaut = "" if md.group(1) == "(vide)" else md.group(1)
                mc = re.match(r"choix : (.*)$", d)
                if mc:
                    choix = [c.strip() for c in mc.group(1).split("|") if c.strip()]
            texte = " ".join(d for d in doc if not d.startswith("defaut :") and not d.startswith("choix :"))
            val = actuelles.get(cle, _valeur(m.group(2)))
            champs.append({"cle": cle, "val": val, "section": section, "doc": texte, "defaut": defaut, "choix": choix})
        doc = []
        # file variables absent from the template: kept, at the end of the list
    connues = {c["cle"] for c in champs}
    for cle, val in actuelles.items():
        if cle not in connues:
            champs.append({"cle": cle, "val": val, "section": "Hors patron", "doc": "", "defaut": "", "choix": []})
    return champs


# ── instances (c54x_exe/run.sh, one file per Calypso) ───────

INSTANCES = os.path.join(RACINE, "instances")
PATRON_INST = os.path.join(INSTANCES, "instance.env.example")
ROLES = {1: "Instance 1 — BTS : TRX Calypso (--bts) ou mobile sur le pont (--bts-classique)",
         2: "Instance 2 — MS QEMU par l air (--bts --ms / --ms-magnetite)",
         3: "Instance 3 — 2e TRX Calypso, TS1 (--ts 2)"}
LIGNE_INST = re.compile(r'^: "\$\{([A-Z_][A-Z0-9_]*):=(.*)\}"$')


def _fichier_instance(n):
    return os.path.join(INSTANCES, "instance-%d.env" % n)


def _valeurs_instance(n):
    r = {}
    chemin = _fichier_instance(n)
    if os.path.exists(chemin):
        for l in open(chemin, encoding="utf-8"):
            m = LIGNE_INST.match(l.rstrip("\n"))
            if m:
                r[m.group(1)] = m.group(2)
    return r


def lire_instance(n):
    if not os.path.exists(PATRON_INST):
        return []
    return lire_globals(PATRON_INST, _valeurs_instance(n))


def ecrire_instance(n, nouvelles):
    """instance-N.env on the model of the template: `: "${VAR:=value}"` (the environment keeps priority)."""
    valeurs = _valeurs_instance(n)
    valeurs.update({k: str(v).replace('"', "").replace("\n", " ") for k, v in nouvelles.items()})
    sortie = ["# instances/instance-%d.env — %s\n" % (n, ROLES.get(n, "")),
              "# ecrit par la page web (tools/osmo-reglages.py) ; lu par c54x_exe/run.sh (INSTANCE=%d)\n" % n]
    vues = set()
    for l in open(PATRON_INST, encoding="utf-8"):
        m = LIGNE_VAR.match(l.rstrip("\n"))
        if m:
            cle = m.group(1)
            val = valeurs.get(cle, "")
            vues.add(cle)
            sortie.append(('#%s\n' % cle) if val == "" else ': "${%s:=%s}"\n' % (cle, val))
        elif not l.startswith("# instances/instance.env.example") and not l.startswith("# Genere par"):
            sortie.append(l if l.endswith("\n") else l + "\n")
    for k in valeurs:
        if k not in vues and valeurs[k] != "":
            sortie.append(': "${%s:=%s}"\n' % (k, valeurs[k]))
    os.makedirs(INSTANCES, exist_ok=True)
    sauvegarde(_fichier_instance(n))
    with open(_fichier_instance(n), "w", encoding="utf-8") as f:
        f.writelines(sortie)


def sauvegarde(chemin):
    if os.path.exists(chemin):
        shutil.copy2(chemin, chemin + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))


def ecrire_globals(nouvelles):
    """Rewrites globals.conf on the model of the template: same lines and comments, current + new values."""
    valeurs = _valeurs(GLOBALS)
    valeurs.update({k: str(v).replace('"', "").replace("\n", " ") for k, v in nouvelles.items()})
        # in the launcher block (markers of tools/globals-complet.py), an EMPTY variable is
        # written as a comment: undefined. Exported empty by `set -a`, the launcher variables
        # would break the launch. Only the entered values become active.
    sortie, vues, bloc = [], set(), False
    for l in open(_patron(), encoding="utf-8"):
        if l.startswith("# >>> VARIABLES DU LANCEUR"):
            bloc = True
        elif l.startswith("# <<< FIN DES VARIABLES DU LANCEUR"):
            bloc = False
        m = LIGNE_VAR.match(l.rstrip("\n"))
        if m:
            cle = m.group(1)
            val = valeurs.get(cle, "")
            vues.add(cle)
            sortie.append(('#%s=""\n' % cle) if (bloc and val == "") else '%s="%s"\n' % (cle, val))
        else:
            sortie.append(l if l.endswith("\n") else l + "\n")
    reste = [k for k in valeurs if k not in vues]
    if reste:
        sortie.append("\n# ── Hors patron (gardees de l ancien globals.conf) ────────────\n")
        sortie += ['%s="%s"\n' % (k, valeurs[k]) for k in reste]
    sauvegarde(GLOBALS)
    with open(GLOBALS, "w", encoding="utf-8") as f:
        f.writelines(sortie)


# ── Fichiers ───────────────────────────────────────────────

def fichiers_cfg():
    r = []
    for d in DOSSIERS_CFG:
        for p in sorted(glob.glob(os.path.join(d, "*.cfg")) + glob.glob(os.path.join(d, "*.conf"))):
            r.append(p)
    return r


def fichier_autorise(p):
    p = os.path.realpath(p)
    return p in [os.path.realpath(x) for x in fichiers_cfg()]


# "Configs osmo" tab: each /etc/osmocom/osmo-*.cfg, its template in configs/ (start.sh
# regenerates /etc/osmocom from configs/ on every run: an edit of /etc only lives until
# then) and the daemon currently reading it (-c <file> in its command line).
PROTEGES = "/etc/osmocom/.proteges"   # lib/gabarits.sh install_configs_native n'ecrase pas ces fichiers


def proteges():
    try:
        with open(PROTEGES, encoding="utf-8") as f:
            return {l.split("#")[0].strip() for l in f} - {""}
    except FileNotFoundError:
        return set()


def proteger(nom, on):
    if "/" in nom or not nom:
        raise ValueError("nom invalide")
    if (nom in proteges()) == on:
        return
    lignes = []
    if os.path.exists(PROTEGES):
        with open(PROTEGES, encoding="utf-8") as f:
            lignes = [l for l in f if l.split("#")[0].strip() != nom]
    else:
        lignes = ["# Fichiers de /etc/osmocom que start.sh ne regenere pas depuis configs/ (un par ligne).\n"]
    if on:
        lignes.append(nom + "\n")
    with open(PROTEGES, "w", encoding="utf-8") as f:
        f.writelines(lignes)


def configs_osmo():
    cmds = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout.splitlines()[1:]
    prot = proteges()
    r = []
    for p in sorted(glob.glob("/etc/osmocom/osmo-*.cfg")):
        nom = os.path.basename(p)
        gab = os.path.join(RACINE, "configs", nom)
        st = os.stat(p)
        pid = next((c.split(None, 1)[0] for c in cmds
                    if re.search(r"(^|\s)-c\s+" + re.escape(p) + r"(\s|$)", c.split(None, 1)[-1])), None)
        r.append({"nom": nom[:-4], "etc": p, "gabarit": gab if os.path.exists(gab) else None,
                  "pid": pid, "taille": st.st_size, "mtime": int(st.st_mtime), "protege": nom in prot})
    return r


# ── Etat ───────────────────────────────────────────────────

def etat():
    ps = subprocess.run(["ps", "-eo", "pid,etimes,rss,pcpu,args", "--sort=args"],
                        capture_output=True, text=True).stdout.splitlines()
    procs = []
    for l in ps[1:]:
        c = l.split(None, 4)
        if len(c) == 5 and re.search(r"(^|/)(osmo-[\w-]+|mobile|qemu-system-arm|c54x_exe)\b", c[4]) \
                and "osmo-reglages" not in c[4]:
            procs.append({"pid": c[0], "age": int(c[1]), "rss": int(c[2]) // 1024,
                          "cpu": c[3], "cmd": c[4][:160]})
    return {"procs": procs, "vty": demons_vty()}


# ── HTTP ───────────────────────────────────────────────────

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def envoyer(self, code, corps, type_="application/json"):
        if not isinstance(corps, bytes):
            corps = (json.dumps(corps) if type_ == "application/json" else corps).encode()
        self.send_response(code)
        self.send_header("Content-Type", type_ + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def corps_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            if u.path == "/" or not u.path.startswith("/api/"):
                nom = "index.html" if u.path == "/" else u.path.lstrip("/")
                chemin = os.path.realpath(os.path.join(WEB, nom))
                if not chemin.startswith(os.path.realpath(WEB) + os.sep) or not os.path.isfile(chemin):
                    return self.envoyer(404, {"err": "introuvable"})
                with open(chemin, "rb") as f:
                    return self.envoyer(200, f.read(), TYPES.get(os.path.splitext(chemin)[1], "application/octet-stream"))
            if u.path == "/api/globals":
                return self.envoyer(200, lire_globals())
            if u.path == "/api/instances":
                return self.envoyer(200, [{"n": n, "role": r, "fichier": _fichier_instance(n),
                                           "existe": os.path.exists(_fichier_instance(n))} for n, r in ROLES.items()])
            if u.path == "/api/instance":
                return self.envoyer(200, lire_instance(int(q.get("n", "1"))))
            if u.path == "/api/demons":
                if q.get("rafraichir"):
                    _cache_vty["t"] = 0
                return self.envoyer(200, demons_vty())
            if u.path == "/api/config":
                v = Vty(q["hote"], int(q["port"]), delai=6.0)
                try:
                    t = v.cmd("show running-config")
                finally:
                    v.fermer()
                return self.envoyer(200, {"lignes": arbre_config(t), "brut": t})
            if u.path == "/api/fichiers":
                return self.envoyer(200, fichiers_cfg())
            if u.path == "/api/configs-osmo":
                return self.envoyer(200, configs_osmo())
            if u.path == "/api/fichier":
                if not fichier_autorise(q["p"]):
                    return self.envoyer(403, {"err": "fichier hors liste"})
                with open(q["p"], encoding="utf-8", errors="replace") as f:
                    return self.envoyer(200, {"texte": f.read()})
            if u.path == "/api/etat":
                return self.envoyer(200, etat())
            self.envoyer(404, {"err": "?"})
        except Exception as e:
            self.envoyer(500, {"err": "%s: %s" % (type(e).__name__, e)})

    def do_POST(self):
        u = urlparse(self.path)
        try:
            j = self.corps_json()
            if u.path == "/api/globals":
                ecrire_globals(j)
                return self.envoyer(200, {"ok": True})
            if u.path == "/api/instance":
                ecrire_instance(int(j["n"]), j["valeurs"])
                return self.envoyer(200, {"ok": True, "fichier": _fichier_instance(int(j["n"]))})
            if u.path == "/api/appliquer":
                return self.envoyer(200, appliquer(j["hote"], int(j["port"]), j["chemin"], j["lignes"]))
            if u.path == "/api/console":
                return self.envoyer(200, {"sortie": console(j["hote"], int(j["port"]), j["lignes"])})
            if u.path == "/api/fichier":
                if not fichier_autorise(j["p"]):
                    return self.envoyer(403, {"err": "fichier hors liste"})
                sauvegarde(j["p"])
                with open(j["p"], "w", encoding="utf-8") as f:
                    f.write(j["texte"])
                                                                # edited here: kept across the regeneration
                protege = os.path.dirname(os.path.realpath(j["p"])) == "/etc/osmocom"
                if protege:
                    proteger(os.path.basename(j["p"]), True)
                return self.envoyer(200, {"ok": True, "protege": protege})
            if u.path == "/api/protege":
                proteger(os.path.basename(j["nom"]), bool(j["on"]))
                return self.envoyer(200, {"ok": True})
            self.envoyer(404, {"err": "?"})
        except Exception as e:
            self.envoyer(500, {"err": "%s: %s" % (type(e).__name__, e)})


if __name__ == "__main__":
    a = argparse.ArgumentParser(description="Page web de reglage Osmocom")
    a.add_argument("--port", type=int, default=8090)
    a.add_argument("--bind", default="127.0.0.1")
    o = a.parse_args()
    print("Reglages Osmocom : http://%s:%d/" % (o.bind, o.port))
    ThreadingHTTPServer((o.bind, o.port), H).serve_forever()
