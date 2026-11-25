#!/usr/bin/env python3
# Inscription des téléphones (appli network_monitoring) : code d'invitation -> compte SIP.
#
#   python3 tools/osmo-inscription.py [--port 8088] [--bind 0.0.0.0]   le service
#   python3 tools/osmo-inscription.py --nouveau-code [--usages N]       crée un code
#   python3 tools/osmo-inscription.py --liste                           codes et comptes
#
# POST /inscription {"code": "...", "pseudo": "..."} ->
#   {"ok": true, "msisdn": "3001", "sip_user": "3001", "sip_password": "...",
#    "sip_domain": "<adresse du nœud vue par le téléphone>", "sip_port": 5060, "sip_transport": "udp"}
#
# Les comptes vivent dans /var/lib/osmo-inscription/etat.json ; à chaque démarrage et
# à chaque inscription le service réécrit /etc/asterisk/pjsip_inscrits.conf et
# extensions_inscrits.conf, s'assure que pjsip.conf / extensions.conf les incluent
# (generate_configs.sh peut les régénérer) puis recharge Asterisk.
# Numéros 3000-3999, contexte [inscrits] : appels entre inscrits, puis tout [internal].
# Pas d'authentification au-delà du code : réseau local ou WireGuard seulement.
# Bibliothèque standard uniquement.

import argparse, json, os, re, secrets, socket, subprocess, sys, threading, time
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ETAT = os.environ.get("INSCRIPTION_ETAT", "/var/lib/osmo-inscription/etat.json")
AST = os.environ.get("INSCRIPTION_ASTERISK", "/etc/asterisk")
PREMIER, DERNIER = 3000, 3999
SMS_GSM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "sms-sip-vers-gsm.py")
VERROU = threading.Lock()


def charger():
    try:
        with open(ETAT) as f:
            e = json.load(f)
    except (OSError, ValueError):
        e = {}
    e.setdefault("codes", {})
    e.setdefault("comptes", {})
    return e


def sauver(e):
    os.makedirs(os.path.dirname(ETAT), exist_ok=True)
    tmp = ETAT + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(e, f, indent=1)
    os.replace(tmp, ETAT)


def assurer_include(fichier, ligne):
    try:
        with open(fichier) as f:
            texte = f.read()
    except OSError:
        print("absent : %s" % fichier, file=sys.stderr)
        return
    if ligne not in texte:
        with open(fichier, "a") as f:
            f.write("\n; ajouté par osmo-inscription.py\n%s\n" % ligne)


def ecrire_asterisk(e):
    p = ["; pjsip_inscrits.conf - écrit par osmo-inscription.py, ne pas éditer\n"]
    for num, c in sorted(e["comptes"].items()):
        pseudo = re.sub(r'[<>"\r\n;]', "", c["pseudo"])[:40]
        p.append("""
[{n}]
type=endpoint
transport=transport-udp
context=inscrits
disallow=all
allow=alaw
allow=ulaw
allow=gsm
auth={n}
aors={n}
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
media_encryption=no
message_context=sms_inscrits
callerid="{p}" <{n}>

[{n}]
type=auth
auth_type=userpass
username={n}
password={pw}

[{n}]
type=aor
max_contacts=2
remove_existing=yes
qualify_frequency=30
""".format(n=num, p=pseudo, pw=c["mdp"]))
    with open(os.path.join(AST, "pjsip_inscrits.conf"), "w") as f:
        f.write("".join(p))
    with open(os.path.join(AST, "extensions_inscrits.conf"), "w") as f:
        f.write("""; extensions_inscrits.conf - écrit par osmo-inscription.py, ne pas éditer
[inscrits]
exten => _3XXX,1,NoOp(=== INSCRIT -> INSCRIT ${EXTEN} - CallerID: ${CALLERID(all)} ===)
 same => n,Dial(PJSIP/${EXTEN},30,rT)
 same => n,Hangup()
include => internal

; Les appels venant du GSM (osmo-sip-connector) vers un inscrit : _3XXX est
; plus precis que le _X. (routage inter-operateurs) de [gsm_in], il passe
; devant. Asterisk fusionne les deux [gsm_in].
[gsm_in]
exten => _3XXX,1,NoOp(=== GSM -> INSCRIT ${EXTEN} - CallerID: ${CALLERID(all)} ===)
 same => n,Dial(PJSIP/${EXTEN},30,rT)
 same => n,Hangup()

; Les SMS (SIP MESSAGE) des inscrits : vers un autre inscrit, en SIP ; vers
; un numero GSM, par le relais SMS (scripts/sms-sip-vers-gsm.py). Le texte
; passe en base64 : aucun caractere du SMS n atteint un shell.
[sms_inscrits]
exten => _3XXX,1,NoOp(=== SMS INSCRIT -> INSCRIT ${EXTEN} ===)
 same => n,MessageSend(pjsip:${EXTEN},${MESSAGE(from)})
 same => n,Hangup()
exten => _X.,1,NoOp(=== SMS INSCRIT ${MESSAGE(from)} -> GSM ${EXTEN} ===)
; L expediteur vient de l en-tete From (« "x" <sip:3001@...> »), passe brut en
; base64 : CALLERID(num) est vide sur un SIP MESSAGE, et le script en tire le
; numero. Guillemets : un argument vide ne decale rien.
 same => n,System(/usr/bin/python3 %s "${FILTER(0-9+,${EXTEN})}" "${BASE64_ENCODE(${MESSAGE(from)})}" "${BASE64_ENCODE(${MESSAGE(body)})}")
 same => n,Hangup()
; un numero exterieur en +33... : meme script (il le confie au telephone proxy)
exten => _+X.,1,Goto(${EXTEN:1},1)
exten => _00X.,1,NoOp(=== SMS INSCRIT ${MESSAGE(from)} -> EXTERIEUR ${EXTEN} ===)
 same => n,System(/usr/bin/python3 %s "${FILTER(0-9+,${EXTEN})}" "${BASE64_ENCODE(${MESSAGE(from)})}" "${BASE64_ENCODE(${MESSAGE(body)})}")
 same => n,Hangup()
""" % (SMS_GSM, SMS_GSM))
    assurer_include(os.path.join(AST, "pjsip.conf"), '#include "pjsip_inscrits.conf"')
    assurer_include(os.path.join(AST, "extensions.conf"), '#include "extensions_inscrits.conf"')
    # « pjsip reload » n'existe pas en Asterisk 20, et asterisk -rx rend 0 même
    # pour une commande inconnue : on regarde aussi la sortie.
    for cmd in ("module reload res_pjsip.so", "dialplan reload"):
        r = subprocess.run(["asterisk", "-rx", cmd], capture_output=True, text=True)
        if r.returncode or "No such command" in r.stdout:
            print("asterisk -rx %r : %s" % (cmd, (r.stderr or r.stdout).strip()), file=sys.stderr)


def normaliser(code):
    """Majuscules, espaces, tirets « − – » ou absents : on ne garde que l'hexa."""
    h = re.sub(r"[^0-9a-f]", "", (code or "").lower())
    return "%s-%s" % (h[:4], h[4:]) if len(h) == 8 else h


def inscrire(code, pseudo):
    code, pseudo = normaliser(code), (pseudo or "").strip()
    if not re.fullmatch(r"[\w .\-]{1,40}", pseudo):
        return 400, {"ok": False, "error": "pseudo : 1 à 40 lettres, chiffres, espace, . _ -"}
    with VERROU:
        e = charger()
        c = e["codes"].get(code)
        if not c or c["restant"] <= 0:
            print("code refusé : %r (%s)" % (code, "épuisé" if c else "inconnu"), file=sys.stderr)
            return 403, {"ok": False, "error": "code d'invitation inconnu ou déjà utilisé"}
        libres = [str(n) for n in range(PREMIER, DERNIER + 1) if str(n) not in e["comptes"]]
        if not libres:
            return 503, {"ok": False, "error": "plus de numéro libre"}
        num, mdp = libres[0], secrets.token_urlsafe(12)
        e["comptes"][num] = {"pseudo": pseudo, "mdp": mdp, "code": code}
        c["restant"] -= 1
        sauver(e)
        ecrire_asterisk(e)
    return 200, {"ok": True, "msisdn": num, "sip_user": num, "sip_password": mdp,
                 "sip_port": 5060, "sip_transport": "udp"}


def adresse_sip(client, defaut):
    """L'adresse d'où Asterisk (bind 0.0.0.0) répondra à ce client : la source
    que le noyau choisit pour aller vers lui. Ce n'est pas forcément celle que le
    client a appelée : un téléphone en data LTE (10.45.0.x) qui vise
    192.168.1.91 reçoit les réponses UDP de 10.45.0.1, et le NAT de son côté
    les jette. En TCP (HTTP) le problème n'existe pas, d'où le piège."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((client, 5060))          # UDP : aucun paquet émis, juste la route
        src = s.getsockname()[0]
        s.close()
        return defaut if src.startswith("127.") else src
    except OSError:
        return defaut


# ── LE PROXY : un smartphone prete sa carte SIM au banc ─────────────────────
# L appli Android (onglet Proxy) s annonce avec son compte SIP du noeud. Tant
# qu elle donne signe de vie :
#   - un SMS recu par sa SIM arrive ici (POST /proxy/entrant) et repart vers un
#     numero du banc (GSM : relais interop ; poste SIP : AMI d Asterisk) ;
#   - un SMS du banc vers un numero EXTERIEUR (06..., +33..., 00...) est mis en
#     file (POST /proxy/sortant, depuis cette machine seulement) et l appli le
#     retire (GET /proxy/sortants) pour l envoyer par sa SIM.
# Les appels ne passent pas par ici : Android n ouvre pas la voix d un appel
# GSM a une appli ; le renvoi d appel de l operateur (**21*) fait ce travail.
# Le mot de passe SIP du compte sert de jeton : pas de compte, pas de proxy.
PROXY_VIE = 90                      # s sans nouvelles : le proxy est tenu pour parti
PROXY = {"user": None, "dest": "", "vu": 0.0, "file": []}
EXTERIEUR = re.compile(os.environ.get("OSMO_SMS_EXTERIEUR", r"(\+|00)\d{6,15}|0[1-9]\d{8}"))
SIP_RE = re.compile(os.environ.get("OSMO_SMS_SIP_RE", r"3\d{3}"))
RELAIS = ("127.0.0.1", int(os.environ.get("OSMO_SMS_RELAIS_PORT", "7890")))
AMI_CONF = "/etc/asterisk/manager.d/osmo.conf"


def proxy_compte(user, mdp):
    """Le compte SIP qui s annonce : connu, et avec le bon mot de passe."""
    c = charger()["comptes"].get(str(user or ""))
    return bool(c) and bool(mdp) and secrets.compare_digest(str(mdp), c["mdp"])


def proxy_actif():
    return PROXY["user"] is not None and time.time() - PROXY["vu"] < PROXY_VIE


def vers_le_banc(dest, de, texte):
    """Un SMS venu de l exterieur, remis a un numero du banc. -> (ok, raison)"""
    dest, de = re.sub(r"\D", "", dest), re.sub(r"[^\d]", "", de) or "0"
    if SIP_RE.fullmatch(dest):
        return ami_message(dest, de, texte)
    try:
        with socket.create_connection(RELAIS, timeout=10) as s:
            s.sendall((json.dumps({"type": "mt_sms", "dest_msisdn": dest, "from_number": de,
                                   "message_text": texte}) + "\n").encode())
            rep = b""
            while b"\n" not in rep:
                bloc = s.recv(4096)
                if not bloc:
                    break
                rep += bloc
        r = json.loads(rep.decode() or "{}")
        return r.get("status") == "ok", r.get("reason", "")
    except (OSError, ValueError) as e:
        return False, "relais SMS injoignable (%s)" % e


def ami_message(dest, de, texte):
    """SIP MESSAGE a tous les appareils d un poste, par l AMI d Asterisk."""
    user, secret = "osmo", ""
    try:
        for ligne in open(AMI_CONF):
            m = re.match(r"\s*\[(\w+)\]", ligne)
            if m:
                user = m.group(1)
            m = re.match(r"\s*secret\s*=\s*(\S+)", ligne)
            if m:
                secret = m.group(1)
    except OSError as e:
        return False, "%s illisible (%s)" % (AMI_CONF, e)
    try:
        out = subprocess.run(["asterisk", "-rx", "pjsip show contacts"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    cibles = ["pjsip:%s/%s" % (dest, c) for c in re.findall(r"Contact:\s+%s/(sips?:\S+)" % re.escape(dest), out)] \
        or ["pjsip:%s" % dest]
    corps = texte.replace("\r", " ").replace("\n", " ")
    act = "Action: Login\r\nUsername: %s\r\nSecret: %s\r\nEvents: off\r\n\r\n" % (user, secret)
    for c in cibles:
        act += "Action: MessageSend\r\nTo: %s\r\nFrom: \"%s\" <sip:%s@127.0.0.1>\r\nBody: %s\r\n\r\n" % (c, de, de, corps)
    act += "Action: Logoff\r\n\r\n"
    try:
        with socket.create_connection(("127.0.0.1", int(os.environ.get("OSMO_AMI_PORT", "5038"))), timeout=5) as s:
            s.sendall(act.encode("utf-8"))
            s.settimeout(3)
            data = b""
            try:
                while True:
                    bloc = s.recv(4096)
                    if not bloc:
                        break
                    data += bloc
            except OSError:
                pass
    except OSError as e:
        return False, "AMI injoignable (%s)" % e
    return (b"Message successfully" in data or data.count(b"Response: Success") >= 2), ""


class H(BaseHTTPRequestHandler):
    def _rep(self, st, obj):
        b = json.dumps(obj).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.rstrip("/") == "/proxy/sortants":
            # l appli retire les SMS a envoyer par sa SIM (et donne signe de vie)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            if not proxy_compte(q.get("user"), q.get("mdp")):
                return self._rep(403, {"ok": False, "error": "compte inconnu"})
            with VERROU:
                if PROXY["user"] != q["user"]:
                    return self._rep(409, {"ok": False, "error": "ce compte n est pas le proxy du noeud"})
                PROXY["vu"] = time.time()
                sms, PROXY["file"] = PROXY["file"], []
            return self._rep(200, {"ok": True, "sms": sms})
        if u.path.rstrip("/") == "/proxy":
            return self._rep(200, {"ok": True, "actif": proxy_actif(), "user": PROXY["user"] if proxy_actif() else None,
                                   "dest": PROXY["dest"], "attente": len(PROXY["file"])})
        self._rep(200 if u.path == "/" else 404, {"service": "osmo-inscription", "post": "/inscription"})

    def _proxy(self, chemin, d):
        if chemin == "/proxy/sortant":
            # un SMS du banc vers l exterieur : cette machine seulement (Asterisk, relais)
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                return self._rep(403, {"ok": False, "error": "local seulement"})
            vers, texte = str(d.get("vers") or ""), str(d.get("texte") or "")
            if not EXTERIEUR.fullmatch(vers) or not texte:
                return self._rep(400, {"ok": False, "error": "numero exterieur et texte attendus"})
            with VERROU:
                if not proxy_actif():
                    return self._rep(503, {"ok": False, "error": "aucun telephone proxy en ligne"})
                PROXY["file"].append({"vers": vers, "texte": texte[:1500], "de": str(d.get("de") or "")})
                del PROXY["file"][:-50]
            sys.stderr.write("proxy : SMS %s -> %s en file\n" % (d.get("de"), vers))
            return self._rep(200, {"ok": True})
        if not proxy_compte(d.get("user"), d.get("mdp")):
            return self._rep(403, {"ok": False, "error": "compte inconnu"})
        if chemin == "/proxy/etat":
            # l appli s annonce (actif) ou se retire ; dest = qui recoit sur le banc
            with VERROU:
                if d.get("actif"):
                    PROXY.update(user=str(d["user"]), dest=re.sub(r"\D", "", str(d.get("dest") or "")), vu=time.time())
                elif PROXY["user"] == str(d["user"]):
                    PROXY.update(user=None, file=[])
            sys.stderr.write("proxy : %s %s (vers %s)\n" % (d["user"], "actif" if d.get("actif") else "retire", PROXY["dest"]))
            return self._rep(200, {"ok": True, "actif": proxy_actif(), "dest": PROXY["dest"]})
        if chemin == "/proxy/entrant":
            # un SMS recu par la SIM du telephone : vers le numero du banc choisi
            if PROXY["user"] != str(d["user"]):
                return self._rep(409, {"ok": False, "error": "ce compte n est pas le proxy du noeud"})
            PROXY["vu"] = time.time()
            if not PROXY["dest"]:
                return self._rep(400, {"ok": False, "error": "pas de destinataire sur le banc"})
            ok, pourquoi = vers_le_banc(PROXY["dest"], str(d.get("de") or ""), str(d.get("texte") or "")[:1500])
            sys.stderr.write("proxy : SMS de %s -> %s : %s\n" % (d.get("de"), PROXY["dest"], "ok" if ok else pourquoi))
            return self._rep(200 if ok else 502, {"ok": ok, "error": pourquoi})
        self._rep(404, {"ok": False, "error": "inconnu"})

    def do_POST(self):
        chemin = urlparse(self.path).path.rstrip("/")
        try:
            n = min(int(self.headers.get("Content-Length") or 0), 8192)
            d = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._rep(400, {"ok": False, "error": "JSON attendu"})
        if chemin.startswith("/proxy"):
            return self._proxy(chemin, d)
        if chemin != "/inscription":
            return self._rep(404, {"ok": False, "error": "inconnu"})
        st, rep = inscrire(d.get("code"), d.get("pseudo"))
        if rep.get("ok"):
            rep["sip_domain"] = adresse_sip(self.client_address[0], self.connection.getsockname()[0])
        self._rep(st, rep)

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % a))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--nouveau-code", action="store_true")
    ap.add_argument("--usages", type=int, default=1)
    ap.add_argument("--liste", action="store_true")
    a = ap.parse_args()
    if a.nouveau_code:
        with VERROU:
            e = charger()
            code = "%s-%s" % (secrets.token_hex(2), secrets.token_hex(2))
            e["codes"][code] = {"restant": a.usages}
            sauver(e)
        print(code)
        return
    if a.liste:
        e = charger()
        for k, v in e["codes"].items():
            print("code %s  restant %d" % (k, v["restant"]))
        for k, v in sorted(e["comptes"].items()):
            print("compte %s  %s" % (k, v["pseudo"]))
        return
    ecrire_asterisk(charger())
    print("osmo-inscription sur http://%s:%d/inscription" % (a.bind, a.port), file=sys.stderr)
    ThreadingHTTPServer((a.bind, a.port), H).serve_forever()


if __name__ == "__main__":
    main()
