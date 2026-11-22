#!/usr/bin/env python3
"""osmo-db.py - the SQL base of the bench configuration (SQLite, stdlib only).

The base READS the configuration files where they live (/etc/osmocom,
the mobile configs, globals.conf, the start and build .config...), and
follows them: a file whose content changed (sha256) is read again, every
changed value goes into the history. globals.conf is the layer written OVER
the rest: the web interface (osmo-egprs-web) and start.sh --configure write
it through this script; a plain start.sh only reads it.

    osmo-db.py sync                      read the files again (changed ones only)
    osmo-db.py json etat                 parameters, files, history (JSON)
    osmo-db.py json fichier CHEMIN       a file: content and parsed lines
    osmo-db.py json ran                  BTS (osmo-bsc.cfg + osmo-bts) and MS (HLR + mobile configs)
    osmo-db.py json core                 the core daemons, their key lines, the rules
    osmo-db.py coherence [--tout]        the SQL rules between the files (table regle):
                                         stick/ARFCN, band, unit-id, MCC/MNC, A5, MGW,
                                         GSUP, point codes, SIP, IMSI/Ki in hlr.db
                                         (status 1 if something does not match)
    osmo-db.py set CLE VALEUR [ORIGINE]  globals.conf: CLE="VALEUR" (then sync)
    osmo-db.py reset CLE [ORIGINE]       globals.conf: back to the example's value
    osmo-db.py ecrire CHEMIN [ORIGINE]   replace a scanned file by stdin (backup .bak-<date>)
    osmo-db.py globals-depuis-config F   globals.conf from the P_<CLE> of a start .config

Base: $OSMO_DB, default /var/lib/osmocom/osmo-operator.db
      (<repo>/.osmo-operator.db when /var/lib/osmocom is not writable).
Read paths: see CHEMINS below; $OSMO_DB_CHEMINS (':'-separated globs) adds some.
"""
import datetime, glob, hashlib, json, os, re, sqlite3, sys

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLOBALS = os.environ.get("OSMO_GLOBALS") or os.path.join(RACINE, "globals.conf")
EXEMPLE = os.path.join(RACINE, "globals.conf.example")


def chemin_base():
    if os.environ.get("OSMO_DB"):
        return os.environ["OSMO_DB"]
    d = "/var/lib/osmocom"
    if os.access(d, os.W_OK) or (not os.path.exists(d) and os.access("/var/lib", os.W_OK)):
        return os.path.join(d, "osmo-operator.db")
    return os.path.join(RACINE, ".osmo-operator.db")


def start_config():
    if os.environ.get("START_CONFIG"):
        return os.environ["START_CONFIG"]
    if os.access("/etc/osmocom", os.W_OK) or os.path.exists("/etc/osmocom/start.config"):
        return "/etc/osmocom/start.config"
    return os.path.join(RACINE, ".start.config")


# Globs (** = recursive). Every text file under them is read; its kind comes
# from genre(): vty = Osmocom config (indented nodes), kv = KEY=value lines,
# ini = [section] key = value (Asterisk), texte = content only.
CHEMINS = [
    GLOBALS, EXEMPLE,
    None,                                            # the start .config (start_config())
    os.path.join(RACINE, ".config"),
    "/etc/osmocom/**/*",                             # osmo-*.cfg, build.config, coeur.env, radio-plan.env...
    "/root/.osmocom/**/*",                           # bb/mobile*.cfg...
    "/etc/asterisk/**/*",
    "/etc/osmo-*", "/etc/default/osmo-*", "/etc/systemd/system/osmo-*",
    "/root/.config/srsran/*",
    "/opt/LTE/open5gs/install/etc/open5gs/*.yaml", "/opt/LTE/open5gs/install/etc/freeDiameter/*.conf",
    os.path.join(RACINE, "instances", "*.env"),
    "/opt/GSM/c54x_exe/*.cfg",                       # mobile_pont.cfg of the DSP bench
]
TAILLE_MAX = 2 * 1024 * 1024
IGNORES = re.compile(r"(\.bak|\.avant|\.tmp$|~$|\.(db|sqlite3?|pem|key|crt|der|pid|sock|log)$|/keys?/)")


def genre(p, brut):
    b = os.path.basename(p)
    if b.endswith(".cfg"):
        return "vty"
    if p.startswith("/etc/asterisk/") or b.endswith((".ini", ".service")):
        return "ini"
    if b.endswith((".env", ".config")) or b in ("globals.conf", "globals.conf.example") \
            or re.search(rb"^\s*(export\s+)?[A-Za-z_][A-Za-z0-9_]*=", brut, re.M):
        return "kv"
    return "texte"

SCHEMA = """
CREATE TABLE IF NOT EXISTS fichier(
    chemin TEXT PRIMARY KEY, genre TEXT, sha256 TEXT, mtime REAL, taille INTEGER,
    contenu TEXT, lu_le TEXT);
CREATE TABLE IF NOT EXISTS parametre(
    chemin TEXT, cle TEXT, valeur TEXT, PRIMARY KEY(chemin, cle));
CREATE TABLE IF NOT EXISTS ligne(
    chemin TEXT, n INTEGER, niveau INTEGER, noeud TEXT, texte TEXT, PRIMARY KEY(chemin, n));
CREATE TABLE IF NOT EXISTS globals(
    cle TEXT PRIMARY KEY, ordre INTEGER, valeur TEXT, defaut TEXT, section TEXT,
    aide TEXT, choix TEXT, bloc TEXT);
CREATE TABLE IF NOT EXISTS historique(
    t TEXT, chemin TEXT, cle TEXT, avant TEXT, apres TEXT, origine TEXT);
CREATE INDEX IF NOT EXISTS historique_t ON historique(t);
CREATE TABLE IF NOT EXISTS regle(id TEXT PRIMARY KEY, titre TEXT, description TEXT, requete TEXT);
CREATE VIEW IF NOT EXISTS effectif AS
    SELECT cle, CASE WHEN valeur IS NOT NULL AND valeur != '' THEN valeur ELSE defaut END AS valeur,
           section FROM globals;
"""

KV = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
NOT_SET = re.compile(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$')


def maintenant():
    return datetime.datetime.now().isoformat(timespec="seconds")


def ouvrir():
    p = chemin_base()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    db = sqlite3.connect("file:%s" % p, timeout=10, uri=True)
    db.executescript(SCHEMA)
    db.executemany("INSERT OR REPLACE INTO regle VALUES (?,?,?,?)", REGLES)
    db.commit()
    return db


def valeur_kv(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v.replace('\\"', '"')


def parse_kv(texte):
    out = {}
    for l in texte.splitlines():
        m = KV.match(l)
        if m:
            out[m.group(1)] = valeur_kv(m.group(2))
        else:
            m = NOT_SET.match(l.strip())
            if m:
                out[m.group(1)] = "n"
    return out


def parse_ini(texte):
    """[section] key = value / key => value -> {"section.key": value} (last one wins)."""
    out, sec = {}, ""
    for l in texte.splitlines():
        s = l.strip()
        if not s or s[0] in ";#":
            continue
        m = re.match(r"^\[([^\]]+)\]", s)
        if m:
            sec = m.group(1); continue
        m = re.match(r"^([^=;]+?)\s*=>?\s*(.*)$", s)
        if m:
            out[(sec + "." if sec else "") + m.group(1).strip()] = m.group(2).split(";")[0].strip()
    return out


def parse_vty(texte):
    """Osmocom config: the node of a line = the chain of the less indented lines above it."""
    out, pile = [], []
    for n, l in enumerate(texte.splitlines(), 1):
        if not l.strip() or l.lstrip().startswith("!"):
            continue
        niveau = len(l) - len(l.lstrip(" "))
        while pile and pile[-1][0] >= niveau:
            pile.pop()
        out.append((n, niveau, " / ".join(t for _, t in pile), l.strip()))
        pile.append((niveau, l.strip()))
    return out


def catalogue():
    """globals.conf.example: key -> order, default, section, help, choices, block."""
    cat, aide, choix, section, bloc, ordre = {}, [], "", "", "reseau", 0
    try:
        lignes = open(EXEMPLE, encoding="utf-8").read().splitlines()
    except OSError:
        return cat
    for l in lignes:
        if l.startswith("# >>> VARIABLES DU LANCEUR"):
            bloc, aide, choix = "lanceur", [], ""
        elif l.startswith("# ── "):
            section, aide, choix = re.sub(r"\s*─+\s*$", "", l[5:]).strip(), [], ""
        elif l.startswith("# choix : "):
            choix = l[10:].strip()
        elif l.startswith("# ═") or l.strip() == "#":
            aide, choix = [], ""
        elif l.startswith("# "):
            aide.append(l[2:])
        else:
            m = KV.match(l)
            if m:
                ordre += 1
                cat[m.group(1)] = (ordre, valeur_kv(m.group(2)), section, "\n".join(aide), choix, bloc)
            aide, choix = [], ""
    return cat


def chemins():
    """The files read: [(path, kind)]. Text files only, without backups/keys."""
    vus, deja = [], set()
    extra = [g for g in os.environ.get("OSMO_DB_CHEMINS", "").split(":") if g]
    for motif in CHEMINS + extra:
        motif = motif or start_config()
        for p in sorted(glob.glob(motif, recursive=True)):
            if p in deja or not os.path.isfile(p) or os.path.islink(p) and not os.path.exists(p):
                continue
            if IGNORES.search(p):
                continue
            try:
                if os.path.getsize(p) > TAILLE_MAX:
                    continue
                with open(p, "rb") as f:
                    debut = f.read(8192)
            except OSError:
                continue
            if b"\0" in debut:
                continue                         # binary
            deja.add(p); vus.append((p, genre(p, debut)))
    return vus


def sync(db, origine="fichier"):
    """Read the files again; only the changed ones are parsed. -> number changed."""
    t, nb, presents = maintenant(), 0, set()
    for p, genre_ in chemins():
        presents.add(p)
        try:
            brut = open(p, "rb").read()
            st = os.stat(p)
        except OSError:
            continue
        sha = hashlib.sha256(brut).hexdigest()
        r = db.execute("SELECT sha256 FROM fichier WHERE chemin=?", (p,)).fetchone()
        if r and r[0] == sha:
            continue
        nb += 1
        texte = brut.decode("utf-8", "replace")
        genre = genre_
        db.execute("INSERT OR REPLACE INTO fichier VALUES (?,?,?,?,?,?,?)",
                   (p, genre, sha, st.st_mtime, st.st_size, texte, t))
        if genre in ("kv", "ini"):
            avant = dict(db.execute("SELECT cle, valeur FROM parametre WHERE chemin=?", (p,)).fetchall())
            apres = parse_kv(texte) if genre == "kv" else parse_ini(texte)
            db.execute("DELETE FROM parametre WHERE chemin=?", (p,))
            db.executemany("INSERT INTO parametre VALUES (?,?,?)", [(p, k, v) for k, v in apres.items()])
            if r:   # history only for a file already known (not at its first reading)
                for k in sorted(set(avant) | set(apres)):
                    if avant.get(k) != apres.get(k):
                        db.execute("INSERT INTO historique VALUES (?,?,?,?,?,?)",
                                   (t, p, k, avant.get(k), apres.get(k), origine))
        elif genre == "vty":
            db.execute("DELETE FROM ligne WHERE chemin=?", (p,))
            db.executemany("INSERT INTO ligne VALUES (?,?,?,?,?)", [(p,) + x for x in parse_vty(texte)])
            if r:
                db.execute("INSERT INTO historique VALUES (?,?,?,?,?,?)", (t, p, None, r[0][:12], sha[:12], origine))
    # Files gone
    for (p,) in db.execute("SELECT chemin FROM fichier").fetchall():
        if p not in presents:
            db.execute("DELETE FROM fichier WHERE chemin=?", (p,))
            db.execute("DELETE FROM parametre WHERE chemin=?", (p,))
            db.execute("DELETE FROM ligne WHERE chemin=?", (p,))
    # The globals catalog: the example's keys, with this machine's values
    cat = catalogue()
    actuel = dict(db.execute("SELECT cle, valeur FROM parametre WHERE chemin=?", (GLOBALS,)).fetchall())
    db.execute("DELETE FROM globals")
    db.executemany("INSERT INTO globals VALUES (?,?,?,?,?,?,?,?)",
                   [(k, o, actuel.get(k), d, s, a, c, b) for k, (o, d, s, a, c, b) in cat.items()])
    db.commit()
    return nb


# ── writing globals.conf ─────────────────────────────────────────────────────
def ecrire_globals(valeurs):
    """valeurs: {CLE: valeur}. Replaces the CLE= lines, appends the missing ones."""
    try:
        lignes = open(GLOBALS, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        lignes = open(EXEMPLE, encoding="utf-8").read().splitlines()
    reste = dict(valeurs)
    for i, l in enumerate(lignes):
        m = KV.match(l)
        if m and m.group(1) in reste:
            v = reste.pop(m.group(1))
            lignes[i] = '%s="%s"' % (m.group(1), v.replace('"', '\\"'))
    # A key absent from the file with an empty value: nothing to add (empty =
    # the script's default, same as absent).
    reste = {k: v for k, v in reste.items() if v != ""}
    if reste:
        lignes.append("")
        lignes.append("# ── ajoute par tools/osmo-db.py (%s) ──" % maintenant())
        for k, v in reste.items():
            lignes.append('%s="%s"' % (k, v.replace('"', '\\"')))
    tmp = GLOBALS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lignes) + "\n")
    os.replace(tmp, GLOBALS)


def valider(cle, valeur, cat):
    if cle not in cat:
        raise SystemExit("cle inconnue de globals.conf.example : %s" % cle)
    if "\n" in valeur or "`" in valeur or "$(" in valeur:
        raise SystemExit("valeur refusee pour %s (globals.conf est source par le shell)" % cle)
    choix = [c.strip() for c in cat[cle][4].split("|") if c.strip()]
    if choix and valeur and valeur not in choix:
        raise SystemExit("%s : %r n'est pas dans les choix (%s)" % (cle, valeur, " | ".join(choix)))


def poser(db, valeurs, origine):
    cat = catalogue()
    for k, v in valeurs.items():
        valider(k, v, cat)
    sync(db)
    ecrire_globals(valeurs)
    sync(db, origine)


# ── Coherence: SQL rules between configuration files ─────────────────────────
# A rule is a SELECT returning the INCOHERENCES as (fichier, message) rows: no
# row = coherent. They live in the table `regle` (the built-in ones below are
# rewritten at each opening; others added with INSERT stay). They see:
#   ligne(chemin, n, niveau, noeud, texte)   the Osmocom configs, node by node
#   parametre(chemin, cle, valeur)           KEY=value and [section] key files
#   globals / effectif                       globals.conf and its defaults
#   hlr.subscriber, hlr.auc_2g               OsmoHLR's base (read-only), if any
# and the functions mot(texte, i), reste(texte, i), hexa(s), dans_bande(b, arfcn).
BSC = "chemin LIKE '%/osmo-bsc.cfg'"
# The osmo-bts configs the bench RUNS: osmo-bts-trx (BTS 0), -bts1 (side-car),
# osmo-bts-virtual-gprs (cell of the virtphy MS / EGPRS). osmo-bts.cfg and
# osmo-bts-virtual.cfg are templates of other modes: not checked.
def bts_utilises(a):
    return "(%s.chemin LIKE '%%/osmo-bts-trx%%.cfg' OR %s.chemin LIKE '%%/osmo-bts-virtual-gprs.cfg')" % (a, a)
REGLES = [
    ("stick-arfcn", "Le stick des mobiles est une cellule du BSC",
     "Le 'stick' d'une config mobile doit etre l'ARFCN d'une BTS de osmo-bsc.cfg, sinon le mobile ne trouve jamais sa cellule.",
     f"""SELECT m.chemin, 'stick ' || mot(m.texte,2) || ' : aucune BTS de osmo-bsc.cfg sur cet ARFCN ('
            || (SELECT group_concat(mot(texte,2), ', ') FROM ligne WHERE {BSC} AND texte LIKE 'arfcn %') || ')'
         FROM ligne m WHERE m.texte LIKE 'stick %'
          AND EXISTS (SELECT 1 FROM ligne WHERE {BSC} AND texte LIKE 'arfcn %')
          AND NOT EXISTS (SELECT 1 FROM ligne b WHERE b.{BSC} AND b.texte = 'arfcn ' || mot(m.texte,2))"""),
    ("arfcn-bande", "L'ARFCN de chaque BTS est dans sa bande",
     "Dans osmo-bsc.cfg, l'arfcn du trx doit appartenir a la 'band' de sa BTS (GSM900 1-124/975-1023, DCS1800 512-885...).",
     f"""SELECT a.chemin, a.noeud || ' : arfcn ' || mot(a.texte,2) || ' hors de la bande ' || mot(b.texte,2)
         FROM ligne a JOIN ligne b ON b.chemin = a.chemin AND a.noeud LIKE b.noeud || ' / trx %' AND b.texte LIKE 'band %'
         WHERE a.{BSC} AND a.texte LIKE 'arfcn %' AND NOT dans_bande(mot(b.texte,2), mot(a.texte,2))"""),
    ("unit-id", "Chaque BTS est declaree au BSC",
     "L'ipa unit-id d'une config osmo-bts doit etre celui d'une BTS de osmo-bsc.cfg (sinon OML refuse).",
     f"""SELECT t.chemin, 'ipa unit-id ' || mot(t.texte,3) || ' : aucune BTS de osmo-bsc.cfg avec cet identifiant'
         FROM ligne t WHERE {bts_utilises('t')} AND t.texte LIKE 'ipa unit-id %'
          AND NOT EXISTS (SELECT 1 FROM ligne b WHERE b.{BSC} AND b.texte LIKE 'ipa unit-id ' || mot(t.texte,3) || ' %')"""),
    ("bande-bts", "Une BTS et sa declaration au BSC ont la meme bande",
     "La 'band' d'une config osmo-bts doit etre celle de la BTS de meme unit-id dans osmo-bsc.cfg.",
     f"""WITH bts AS (SELECT u.chemin, mot(u.texte,3) AS uid,
                        (SELECT mot(b.texte,2) FROM ligne b WHERE b.chemin = u.chemin AND b.texte LIKE 'band %') AS bande
                     FROM ligne u WHERE {bts_utilises('u')} AND u.texte LIKE 'ipa unit-id %'),
              bsc AS (SELECT u.noeud, mot(u.texte,3) AS uid,
                        (SELECT mot(b.texte,2) FROM ligne b WHERE b.chemin = u.chemin AND b.noeud = u.noeud AND b.texte LIKE 'band %') AS bande
                     FROM ligne u WHERE u.{BSC} AND u.texte LIKE 'ipa unit-id %')
         SELECT bts.chemin, 'band ' || bts.bande || ' mais ' || bsc.noeud || ' de osmo-bsc.cfg est en ' || bsc.bande
         FROM bts JOIN bsc ON bts.uid = bsc.uid WHERE bts.bande IS NOT bsc.bande"""),
    ("plmn", "Un seul MCC/MNC partout",
     "MCC/MNC de osmo-bsc.cfg, osmo-msc.cfg, du rplmn des mobiles et de globals.conf doivent etre les memes.",
     f"""WITH ref AS (SELECT CAST(mot((SELECT texte FROM ligne WHERE {BSC} AND texte LIKE 'network country code %'),4) AS INT) AS mcc,
                           CAST(mot((SELECT texte FROM ligne WHERE {BSC} AND texte LIKE 'mobile network code %'),4) AS INT) AS mnc),
              vu AS (
                SELECT chemin, 'MCC ' || mot(texte,4) AS quoi, CAST(mot(texte,4) AS INT) AS v, 'mcc' AS k FROM ligne
                  WHERE texte LIKE 'network country code %'
                UNION ALL SELECT chemin, 'MNC ' || mot(texte,4), CAST(mot(texte,4) AS INT), 'mnc' FROM ligne
                  WHERE texte LIKE 'mobile network code %'
                UNION ALL SELECT chemin, 'rplmn MCC ' || mot(texte,2), CAST(mot(texte,2) AS INT), 'mcc' FROM ligne WHERE texte LIKE 'rplmn % %'
                UNION ALL SELECT chemin, 'rplmn MNC ' || mot(texte,3), CAST(mot(texte,3) AS INT), 'mnc' FROM ligne WHERE texte LIKE 'rplmn % %'
                UNION ALL SELECT 'globals.conf', 'MCC=' || valeur, CAST(valeur AS INT), 'mcc' FROM globals WHERE cle = 'MCC' AND valeur != ''
                UNION ALL SELECT 'globals.conf', 'MNC=' || valeur, CAST(valeur AS INT), 'mnc' FROM globals WHERE cle = 'MNC' AND valeur != '')
         SELECT vu.chemin, vu.quoi || ' mais osmo-bsc.cfg : ' || printf('%03d/%02d', ref.mcc, ref.mnc)
         FROM vu, ref WHERE ref.mcc IS NOT NULL AND ((vu.k = 'mcc' AND vu.v != ref.mcc) OR (vu.k = 'mnc' AND vu.v != ref.mnc))"""),
    ("chiffrement", "Le meme chiffrement au BSC, au MSC et dans globals.conf",
     "La ligne 'encryption a5 ...' de osmo-bsc.cfg et osmo-msc.cfg, et ENCRYPTION de globals.conf.",
     f"""WITH ref AS (SELECT reste(texte,2) AS a5 FROM ligne WHERE {BSC} AND texte LIKE 'encryption %')
         SELECT l.chemin, l.texte || ' mais osmo-bsc.cfg : encryption ' || ref.a5 FROM ligne l, ref
           WHERE l.chemin LIKE '%/osmo-msc.cfg' AND l.texte LIKE 'encryption %' AND reste(l.texte,2) != ref.a5
         UNION ALL
         SELECT 'globals.conf', 'ENCRYPTION=' || g.valeur || ' mais osmo-bsc.cfg : encryption ' || ref.a5 FROM globals g, ref
           WHERE g.cle = 'ENCRYPTION' AND g.valeur != '' AND g.valeur != ref.a5"""),
    ("radio-globals", "ARFCN et bande de globals.conf appliques",
     "ARFCN et BAND de globals.conf (si poses) doivent se retrouver dans osmo-bsc.cfg : sinon start.sh --configure n'a pas regenere.",
     f"""SELECT 'globals.conf', 'ARFCN=' || g.valeur || ' : aucune BTS de osmo-bsc.cfg sur cet ARFCN'
           FROM globals g WHERE g.cle = 'ARFCN' AND g.valeur != ''
            AND EXISTS (SELECT 1 FROM ligne WHERE {BSC})
            AND NOT EXISTS (SELECT 1 FROM ligne b WHERE b.{BSC} AND b.texte = 'arfcn ' || g.valeur)
         UNION ALL
         SELECT 'globals.conf', 'BAND=' || g.valeur || ' : aucune BTS de osmo-bsc.cfg dans cette bande'
           FROM globals g WHERE g.cle = 'BAND' AND g.valeur != ''
            AND EXISTS (SELECT 1 FROM ligne WHERE {BSC})
            AND NOT EXISTS (SELECT 1 FROM ligne b WHERE b.{BSC} AND b.texte = 'band ' || g.valeur)"""),
    ("mgw", "Le BSC et le MSC joignent le MGW",
     "remote-ip/remote-port des noeuds 'mgw' de osmo-bsc.cfg et osmo-msc.cfg = bind ip/bind port de osmo-mgw.cfg (mgcp).",
     """WITH mgw AS (SELECT (SELECT mot(texte,3) FROM ligne WHERE chemin LIKE '%/osmo-mgw.cfg' AND noeud = 'mgcp' AND texte LIKE 'bind ip %') AS ip,
                           COALESCE((SELECT mot(texte,3) FROM ligne WHERE chemin LIKE '%/osmo-mgw.cfg' AND noeud = 'mgcp' AND texte LIKE 'bind port %'), '2427') AS port)
         SELECT l.chemin, l.noeud || ' : ' || l.texte || ' mais osmo-mgw.cfg ecoute sur ' || mgw.ip || ':' || mgw.port
         FROM ligne l, mgw WHERE mgw.ip IS NOT NULL AND l.noeud LIKE '%mgw %' AND l.chemin NOT LIKE '%/osmo-mgw.cfg'
           AND ((l.texte LIKE 'remote-ip %' AND mot(l.texte,2) != mgw.ip) OR (l.texte LIKE 'remote-port %' AND mot(l.texte,2) != mgw.port))"""),
    ("gsup", "Le MSC joint le HLR (GSUP)",
     "remote-ip/remote-port du noeud 'hlr' de osmo-msc.cfg = bind ip de 'hlr / gsup' dans osmo-hlr.cfg (port 4222).",
     """WITH h AS (SELECT (SELECT mot(texte,3) FROM ligne WHERE chemin LIKE '%/osmo-hlr.cfg' AND noeud = 'hlr / gsup' AND texte LIKE 'bind ip %') AS ip)
         SELECT l.chemin, 'hlr : ' || l.texte || ' mais osmo-hlr.cfg ecoute sur ' || h.ip || ':4222'
         FROM ligne l, h WHERE h.ip IS NOT NULL AND l.chemin LIKE '%/osmo-msc.cfg' AND l.noeud = 'hlr'
           AND ((l.texte LIKE 'remote-ip %' AND mot(l.texte,2) != h.ip) OR (l.texte LIKE 'remote-port %' AND mot(l.texte,2) != '4222'))"""),
    ("point-codes", "Les adresses SCCP visent des point codes existants",
     "Chaque 'sccp-address ... / point-code P' doit etre le point-code d'une instance cs7 d'un autre osmo-*.cfg.",
     """SELECT a.chemin, a.noeud || ' : point-code ' || mot(a.texte,2) || ' n''est le point-code d''aucune instance cs7'
         FROM ligne a WHERE a.noeud LIKE '%sccp-address %' AND a.texte LIKE 'point-code %'
          AND NOT EXISTS (SELECT 1 FROM ligne i WHERE i.chemin != a.chemin AND i.noeud = 'cs7 instance 0'
                          AND i.texte = 'point-code ' || mot(a.texte,2))"""),
    ("sip", "osmo-sip-connector joint Asterisk (ou le transcodeur HR)",
     "Le 'remote IP PORT' du noeud sip de osmo-sip-connector.cfg : le port de pjsip (transport-udp, 5060) ou 5062 (transcodeur --hr/--lora).",
     """WITH p AS (SELECT COALESCE((SELECT CASE WHEN instr(valeur, ':') THEN substr(valeur, instr(valeur, ':') + 1) END
                                  FROM parametre WHERE chemin LIKE '%/asterisk/pjsip.conf' AND cle = 'transport-udp.bind'), '5060') AS port)
         SELECT l.chemin, l.texte || ' : ni le port de pjsip (' || p.port || ') ni le transcodeur (5062)'
         FROM ligne l, p WHERE l.chemin LIKE '%/osmo-sip-connector.cfg' AND l.noeud = 'sip' AND l.texte LIKE 'remote % %'
           AND mot(l.texte,3) NOT IN (p.port, '5062')"""),
    ("gprs-ns", "Le GPRS des BTS joint l'SGSN (NS, 23000)",
     "Chaque 'gprs nsvc N remote ip X' / 'remote udp port P' d'une BTS de osmo-bsc.cfg doit etre un 'listen X P' du noeud ns de osmo-sgsn.cfg. La BTS 1 (side-car, SC_SGSN_IP de qosmo) n'est verifiee que si le modem GPRS est active (CONFIG_MODEM_GPRS=y du start).",
     f"""WITH nsvc AS (SELECT i.chemin, i.noeud, mot(i.texte,3) AS v, mot(i.texte,6) AS ip,
                         (SELECT mot(p.texte,7) FROM ligne p WHERE p.chemin = i.chemin AND p.noeud = i.noeud
                            AND p.texte LIKE 'gprs nsvc ' || mot(i.texte,3) || ' remote udp port %') AS port
                      FROM ligne i WHERE i.{BSC} AND i.texte LIKE 'gprs nsvc % remote ip %' AND mot(i.texte,6) != '0.0.0.0'
                        AND (i.noeud != 'network / bts 1'
                             OR EXISTS (SELECT 1 FROM parametre WHERE cle = 'CONFIG_MODEM_GPRS' AND valeur = 'y')))
         SELECT nsvc.chemin, nsvc.noeud || ' : nsvc ' || nsvc.v || ' vers ' || nsvc.ip || ':' || COALESCE(nsvc.port,'?')
                || ' mais osmo-sgsn.cfg ecoute sur ' || COALESCE((SELECT group_concat(mot(texte,2) || ':' || mot(texte,3), ', ')
                     FROM ligne WHERE chemin LIKE '%/osmo-sgsn.cfg' AND noeud LIKE 'ns%' AND texte LIKE 'listen % %'), 'rien')
         FROM nsvc WHERE EXISTS (SELECT 1 FROM ligne WHERE chemin LIKE '%/osmo-sgsn.cfg')
           AND NOT EXISTS (SELECT 1 FROM ligne s WHERE s.chemin LIKE '%/osmo-sgsn.cfg' AND s.noeud LIKE 'ns%'
                           AND s.texte = 'listen ' || nsvc.ip || ' ' || nsvc.port)"""),
    ("ggsn-gtp", "L'SGSN joint le GGSN (GTP)",
     "'ggsn N remote-ip X' de osmo-sgsn.cfg = 'gtp bind-ip X' de osmo-ggsn.cfg.",
     """WITH g AS (SELECT mot(texte,3) AS ip FROM ligne WHERE chemin LIKE '%/osmo-ggsn.cfg' AND texte LIKE 'gtp bind-ip %')
         SELECT l.chemin, l.texte || ' mais osmo-ggsn.cfg : gtp bind-ip ' || (SELECT group_concat(ip, ', ') FROM g)
         FROM ligne l WHERE l.chemin LIKE '%/osmo-sgsn.cfg' AND l.texte LIKE 'ggsn % remote-ip %'
           AND EXISTS (SELECT 1 FROM g) AND mot(l.texte,4) NOT IN (SELECT ip FROM g)"""),
    ("sgsn-gsup", "L'SGSN joint le HLR (GSUP)",
     "'gsup remote-ip/remote-port' de osmo-sgsn.cfg = bind ip de 'hlr / gsup' (port 4222).",
     """WITH h AS (SELECT (SELECT mot(texte,3) FROM ligne WHERE chemin LIKE '%/osmo-hlr.cfg' AND noeud = 'hlr / gsup' AND texte LIKE 'bind ip %') AS ip)
         SELECT l.chemin, l.texte || ' mais osmo-hlr.cfg ecoute sur ' || h.ip || ':4222'
         FROM ligne l, h WHERE h.ip IS NOT NULL AND l.chemin LIKE '%/osmo-sgsn.cfg'
           AND ((l.texte LIKE 'gsup remote-ip %' AND mot(l.texte,3) != h.ip) OR (l.texte LIKE 'gsup remote-port %' AND mot(l.texte,3) != '4222'))"""),
    ("un-serveur-par-port", "Jamais deux serveurs sur le meme ip:port",
     "Les sockets d'ecoute declarees par les osmo-*.cfg (NS 23000 de l'SGSN, NS locaux des PCU, GTP 2123/2152, MGCP, GSUP 4222, M3UA) : deux demons sur le meme protocole, port et adresse (0.0.0.0 couvre toutes les adresses) ne demarrent pas tous les deux.",
     f"""WITH s AS (
           SELECT chemin, 'udp' AS proto, mot(texte,2) AS ip, mot(texte,3) AS port, 'NS ' || texte AS quoi FROM ligne
             WHERE chemin LIKE '%/osmo-sgsn.cfg' AND noeud LIKE 'ns%' AND texte LIKE 'listen % %'
           UNION ALL SELECT chemin, 'udp', '0.0.0.0', mot(texte,7), noeud || ' : PCU ' || texte FROM ligne
             WHERE {BSC} AND texte LIKE 'gprs nsvc % local udp port %' AND mot(texte,7) != '0'
           UNION ALL SELECT chemin, 'udp', mot(texte,3), '2123', 'GTP-C ' || texte FROM ligne
             WHERE (chemin LIKE '%/osmo-ggsn.cfg' AND texte LIKE 'gtp bind-ip %') OR (chemin LIKE '%/osmo-sgsn.cfg' AND texte LIKE 'gtp local-ip %')
           UNION ALL SELECT chemin, 'udp', mot(texte,3), '2152', 'GTP-U ' || texte FROM ligne
             WHERE (chemin LIKE '%/osmo-ggsn.cfg' AND texte LIKE 'gtp bind-ip %') OR (chemin LIKE '%/osmo-sgsn.cfg' AND texte LIKE 'gtp local-ip %')
           UNION ALL SELECT chemin, 'udp', mot(texte,3), COALESCE((SELECT mot(p.texte,3) FROM ligne p WHERE p.chemin = l.chemin
                AND p.noeud = 'mgcp' AND p.texte LIKE 'bind port %'), '2427'), 'MGCP ' || texte FROM ligne l
             WHERE chemin LIKE '%/osmo-mgw.cfg' AND noeud = 'mgcp' AND texte LIKE 'bind ip %'
           UNION ALL SELECT chemin, 'tcp', mot(texte,3), '4222', 'GSUP ' || texte FROM ligne
             WHERE chemin LIKE '%/osmo-hlr.cfg' AND noeud = 'hlr / gsup' AND texte LIKE 'bind ip %'
           UNION ALL SELECT chemin, 'sctp', mot(texte,2), mot(noeud,5), 'M3UA ' || noeud || ' ' || texte FROM ligne
             WHERE noeud LIKE 'cs7 instance % / listen m3ua %' AND texte LIKE 'local-ip %')
         SELECT a.chemin, a.quoi || ' : ' || a.proto || ' ' || a.ip || ':' || a.port || ' aussi pris par ' || b.chemin || ' (' || b.quoi || ')'
         FROM s a JOIN s b ON a.proto = b.proto AND a.port = b.port AND (a.ip = b.ip OR a.ip = '0.0.0.0' OR b.ip = '0.0.0.0')
              AND (a.chemin < b.chemin OR (a.chemin = b.chemin AND a.quoi < b.quoi))
         WHERE a.chemin NOT LIKE '%osmo-bts%'"""),
    ("imsi-hlr", "Les SIM des mobiles sont dans le HLR",
     "L'imsi du test-sim de chaque config mobile doit etre un abonne de hlr.db, avec le meme Ki.",
     """SELECT m.chemin, 'imsi ' || mot(m.texte,2) || ' absent du HLR (hlr.db)'
         FROM ligne m WHERE m.noeud LIKE '%test-sim%' AND m.texte LIKE 'imsi %'
          AND NOT EXISTS (SELECT 1 FROM hlr.subscriber s WHERE s.imsi = mot(m.texte,2))
         UNION ALL
         SELECT m.chemin, 'imsi ' || mot(m.texte,2) || ' : Ki ' || hexa(reste(k.texte,3)) || ' mais HLR ' || a.ki
         FROM ligne m JOIN ligne k ON k.chemin = m.chemin AND k.noeud = m.noeud AND k.texte LIKE 'ki % %'
              JOIN hlr.subscriber s ON s.imsi = mot(m.texte,2) JOIN hlr.auc_2g a ON a.subscriber_id = s.id
         WHERE m.noeud LIKE '%test-sim%' AND m.texte LIKE 'imsi %' AND lower(a.ki) != hexa(reste(k.texte,3))"""),
]
HLR_DB = os.environ.get("OSMO_HLR_DB", "/var/lib/osmocom/hlr.db")


def _mot(t, i):
    m = (t or "").split()
    return m[i - 1] if 0 < i <= len(m) else None


def _reste(t, i):
    m = (t or "").split()
    return " ".join(m[i - 1:]) if 0 < i <= len(m) else None


def _hexa(s):
    return re.sub(r"[^0-9a-f]", "", (s or "").lower())


BANDES = {"GSM900": [(0, 124), (955, 1023)], "DCS1800": [(512, 885)], "PCS1900": [(512, 810)],
          "GSM850": [(128, 251)], "GSM450": [(259, 293)], "GSM480": [(306, 340)], "GSM750": [(438, 511)]}


def _dans_bande(b, a):
    try:
        a = int(a)
    except (TypeError, ValueError):
        return 1
    return 1 if b not in BANDES else int(any(x <= a <= y for x, y in BANDES[b]))


def coherence(db):
    """-> [{id, titre, description, requete, ok, violations: [{fichier, message}]}]"""
    for f, n, fn in (("mot", 2, _mot), ("reste", 2, _reste), ("hexa", 1, _hexa), ("dans_bande", 2, _dans_bande)):
        db.create_function(f, n, fn)
    hlr = os.path.exists(HLR_DB)
    if hlr and not any(r[1] == "hlr" for r in db.execute("PRAGMA database_list")):
        db.execute("ATTACH DATABASE ? AS hlr", ("file:%s?mode=ro" % HLR_DB,))
    out = []
    for rid, titre, desc, req in db.execute("SELECT id, titre, description, requete FROM regle ORDER BY rowid"):
        r = {"id": rid, "titre": titre, "description": desc, "requete": req}
        if "hlr." in req and not hlr:
            r.update(ok=None, violations=[], erreur="hlr.db absent (%s)" % HLR_DB)
        else:
            try:
                v = [{"fichier": a, "message": b} for a, b in db.execute(req).fetchall()]
                r.update(ok=not v, violations=v)
            except sqlite3.Error as e:
                r.update(ok=None, violations=[], erreur=str(e))
        out.append(r)
    return out


# ── JSON for the web interface ───────────────────────────────────────────────
def json_etat(db):
    g = [dict(zip(("cle", "ordre", "valeur", "defaut", "section", "aide", "choix", "bloc"), r))
         for r in db.execute("SELECT * FROM globals ORDER BY ordre")]
    f = [dict(zip(("chemin", "genre", "taille", "mtime", "lu_le"), r))
         for r in db.execute("SELECT chemin, genre, taille, mtime, lu_le FROM fichier ORDER BY chemin")]
    h = [dict(zip(("t", "chemin", "cle", "avant", "apres", "origine"), r))
         for r in db.execute("SELECT * FROM historique ORDER BY rowid DESC LIMIT 200")]
    sc = start_config()
    start = dict(db.execute("SELECT cle, valeur FROM parametre WHERE chemin=?", (sc,)).fetchall())
    return {"base": chemin_base(), "globals_conf": GLOBALS, "globals": g, "fichiers": f,
            "historique": h, "start_config": sc, "start": start, "coherence": coherence(db)}


def _violations_par_fichier(regles):
    out = {}
    for r in regles:
        for v in r["violations"]:
            out.setdefault(v["fichier"], []).append(dict(v, regle=r["id"], titre=r["titre"]))
    return out


def _bsc(db):
    r = db.execute("SELECT chemin FROM fichier WHERE chemin LIKE '%/osmo-bsc.cfg' ORDER BY chemin LIKE '/etc/%' DESC").fetchone()
    return r[0] if r else None


def json_ran(db):
    """The radio side: the BTS of osmo-bsc.cfg (with their osmo-bts config) and
    the MS (HLR subscribers + mobile configs), each with its incoherences."""
    regles = coherence(db)
    vf = _violations_par_fichier(regles)
    bsc = _bsc(db)
    bts = []
    if bsc:
        noeuds = [n for (n,) in db.execute(
            "SELECT DISTINCT noeud FROM ligne WHERE chemin=? AND noeud GLOB 'network / bts [0-9]*' "
            "ORDER BY n", (bsc,)) if re.fullmatch(r"network / bts \d+", n)]
        for nd in noeuds:
            lignes = [t for (t,) in db.execute("SELECT texte FROM ligne WHERE chemin=? AND noeud=? ORDER BY n", (bsc, nd))]
            trx = [(nn, t) for nn, t in db.execute(
                "SELECT noeud, texte FROM ligne WHERE chemin=? AND noeud LIKE ? ORDER BY n", (bsc, nd + " / trx %"))]
            def val(prefixe, src=lignes):
                for t in src:
                    if t.startswith(prefixe + " "):
                        return t[len(prefixe) + 1:]
            uid = (val("ipa unit-id") or "").split(" ")[0]
            arfcn = next((t.split()[1] for _, t in trx if t.startswith("arfcn ")), None)
            fichiers = [c for (c,) in db.execute(
                "SELECT DISTINCT chemin FROM ligne WHERE chemin LIKE '%/osmo-bts%.cfg' AND texte LIKE ?", ("ipa unit-id %s %%" % uid,))] if uid else []
            num = nd.split()[-1]
            bts.append({
                "id": num, "noeud": nd, "bande": val("band"), "arfcn": arfcn, "bande_arfcn": None,
                "cell_id": val("cell_identity"), "lac": val("location_area_code"), "bsic": val("base_station_id_code"),
                "unit_id": uid, "type": val("type"), "codec": val("codec-support"), "gprs": val("gprs mode"),
                "nsvc": [t for t in lignes if t.startswith("gprs nsvc 0 ")],
                "timeslots": [t for _, t in trx if t.startswith("phys_chan_config")],
                "fichiers_bts": fichiers, "lignes": lignes,
                "incoherences": [v for v in vf.get(bsc, []) if nd in v["message"] or "bts %s" % num in v["message"]]
                                + [v for f in fichiers for v in vf.get(f, [])]})
            if arfcn is not None:
                bts[-1]["bande_arfcn"] = next((b for b in BANDES if _dans_bande(b, arfcn) and b != "PCS1900"), None)
    # MS: HLR subscribers + mobile configs, by IMSI
    ms = {}
    if os.path.exists(HLR_DB):
        for imsi, msisdn, algo, ki in db.execute(
                "SELECT s.imsi, s.msisdn, a.algo_id_2g, a.ki FROM hlr.subscriber s "
                "LEFT JOIN hlr.auc_2g a ON a.subscriber_id = s.id ORDER BY s.imsi"):
            ms[imsi] = {"imsi": imsi, "msisdn": msisdn, "algo": {1: "comp128v1", 2: "comp128v2", 3: "comp128v3", 4: "xor"}.get(algo, algo),
                        "ki": ki, "hlr": True, "mobiles": [], "incoherences": []}
    for chemin, noeud, imsi in db.execute(
            "SELECT chemin, noeud, mot(texte,2) FROM ligne WHERE noeud LIKE '%test-sim%' AND texte LIKE 'imsi %' ORDER BY chemin"):
        lignes = dict((t.split(" ")[0], t) for (t,) in db.execute(
            "SELECT texte FROM ligne WHERE chemin=? ORDER BY n", (chemin,)))
        def l(k):
            t = lignes.get(k)
            return t.split(" ", 1)[1] if t and " " in t else None
        ki = db.execute("SELECT reste(texte,3) FROM ligne WHERE chemin=? AND noeud=? AND texte LIKE 'ki % %'", (chemin, noeud)).fetchone()
        vty = db.execute("SELECT mot(texte,3) FROM ligne WHERE chemin=? AND noeud='line vty' AND texte LIKE 'bind %'", (chemin,)).fetchone()
        e = ms.setdefault(imsi, {"imsi": imsi, "msisdn": None, "algo": None, "ki": None, "hlr": False, "mobiles": [], "incoherences": []})
        e["mobiles"].append({"fichier": chemin, "stick": l("stick"), "layer2_socket": l("layer2-socket"), "sim": l("sim"),
                             "imei": l("imei"), "ki": hexa(ki[0]) if ki else None, "vty": vty[0] if vty else None,
                             "rplmn": db.execute("SELECT reste(texte,2) FROM ligne WHERE chemin=? AND texte LIKE 'rplmn %'", (chemin,)).fetchone()})
        e["incoherences"] += vf.get(chemin, [])
    for e in ms.values():
        for m in e["mobiles"]:
            m["rplmn"] = m["rplmn"][0] if m["rplmn"] else None
    return {"bsc": bsc, "bts": bts, "ms": sorted(ms.values(), key=lambda x: x["imsi"]),
            "hlr_db": HLR_DB if os.path.exists(HLR_DB) else None}


CORE = [("msc", "OsmoMSC", "commutation CS"), ("bsc", "OsmoBSC", "controleur des BTS"), ("hlr", "OsmoHLR", "abonnes, GSUP"),
        ("mgw", "OsmoMGW", "media RTP"), ("stp", "OsmoSTP", "SS7 / M3UA"), ("sgsn", "OsmoSGSN", "paquet, NS/Gb"),
        ("ggsn", "OsmoGGSN", "GTP, APN"), ("sip-connector", "osmo-sip-connector", "MNCC <-> SIP"),
        ("pcu", "OsmoPCU", "ordonnanceur paquet")]
CLES_CORE = re.compile(r"^(point-code|network country code|mobile network code|short name|long name|encryption|authentication|"
                       r"bind ip|bind port|remote-ip|remote-port|local-ip|listen|gtp |ggsn |gsup |apn |ip prefix|"
                       r"remote |mncc|sccp-address|routing-key|asp |as |msc-addr|bsc-addr|ipa unit-id|subscriber-create)")


def json_core(db):
    regles = coherence(db)
    vf = _violations_par_fichier(regles)
    out = []
    for nom, titre, role in CORE:
        r = db.execute("SELECT chemin FROM fichier WHERE chemin LIKE ? ORDER BY chemin LIKE '/etc/%' DESC",
                       ("%%/osmo-%s.cfg" % nom,)).fetchone()
        if not r:
            continue
        cles = [{"noeud": n, "texte": t} for n, t in db.execute(
            "SELECT noeud, texte FROM ligne WHERE chemin=? ORDER BY n", (r[0],)) if CLES_CORE.match(t)]
        out.append({"id": nom, "titre": titre, "role": role, "fichier": r[0], "processus": "osmo-" + nom,
                    "cles": cles, "incoherences": vf.get(r[0], [])})
    return {"core": out, "regles": [{k: v for k, v in r.items() if k != "requete"} for r in regles]}


def hexa(s):
    return _hexa(s)


def json_fichier(db, p):
    r = db.execute("SELECT chemin, genre, sha256, mtime, taille, contenu, lu_le FROM fichier WHERE chemin=?",
                   (p,)).fetchone()
    if not r:
        raise SystemExit("fichier non suivi : %s" % p)
    d = dict(zip(("chemin", "genre", "sha256", "mtime", "taille", "contenu", "lu_le"), r))
    d["lignes"] = [dict(zip(("n", "niveau", "noeud", "texte"), x))
                   for x in db.execute("SELECT n, niveau, noeud, texte FROM ligne WHERE chemin=? ORDER BY n", (p,))]
    d["parametres"] = dict(db.execute("SELECT cle, valeur FROM parametre WHERE chemin=?", (p,)).fetchall())
    return d


def main(a):
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return 0
    db = ouvrir()
    cmd = a[0]
    if cmd == "sync":
        n = sync(db)
        if "--quiet" not in a:
            print("%s : %d fichier(s) relu(s)" % (chemin_base(), n))
    elif cmd == "json":
        sync(db)
        quoi = a[1] if len(a) > 1 else "etat"
        if quoi == "fichier":
            out = json_fichier(db, a[2])
        elif quoi in ("ran", "core"):
            coherence(db)          # registers the SQL functions, attaches hlr.db
            out = json_ran(db) if quoi == "ran" else json_core(db)
        else:
            out = json_etat(db)
        print(json.dumps(out, ensure_ascii=False))
    elif cmd == "coherence":
        sync(db)
        mauvais = 0
        for r in coherence(db):
            for v in r["violations"]:
                mauvais += 1
                print("INCOHERENT [%s] %s : %s" % (r["id"], v["fichier"], v["message"]))
            if r.get("erreur") and "--tout" in a:
                print("REGLE %s non evaluee : %s" % (r["id"], r["erreur"]))
            elif "--tout" in a and r["ok"]:
                print("ok         [%s] %s" % (r["id"], r["titre"]))
        return 1 if mauvais else 0
    elif cmd == "set":
        poser(db, {a[1]: a[2]}, a[3] if len(a) > 3 else "cli")
    elif cmd == "reset":
        cat = catalogue()
        if a[1] not in cat:
            raise SystemExit("cle inconnue : %s" % a[1])
        poser(db, {a[1]: cat[a[1]][1]}, a[2] if len(a) > 2 else "cli")
    elif cmd == "ecrire":
        p = os.path.abspath(a[1])
        if p not in [c for c, _ in chemins()]:
            raise SystemExit("ecriture refusee : %s n'est pas un fichier suivi" % p)
        contenu = sys.stdin.read()
        sync(db)
        bak = "%s.bak-%s" % (p, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.replace(p, bak) if os.path.exists(p) else None
        with open(p, "w", encoding="utf-8") as f:
            f.write(contenu)
        try:
            st = os.stat(bak); os.chmod(p, st.st_mode)
        except OSError:
            pass
        sync(db, a[2] if len(a) > 2 else "cli")
        print("ecrit : %s (sauvegarde %s)" % (p, bak))
    elif cmd == "globals-depuis-config":
        cfg = parse_kv(open(a[1], encoding="utf-8").read())
        cat = catalogue()
        vals = {k[9:]: v for k, v in cfg.items() if k.startswith("CONFIG_P_") and "__" not in k and k[9:] in cat}
        if vals:
            poser(db, vals, "start.sh --configure")
            print("globals.conf : %d parametre(s) depuis %s" % (len(vals), a[1]))
    else:
        print(__doc__, file=sys.stderr); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
