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

import argparse, json, os, re, secrets, socket, subprocess, sys, threading
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
exten => _X.,1,NoOp(=== SMS INSCRIT ${CALLERID(num)} -> GSM ${EXTEN} ===)
 same => n,System(/usr/bin/python3 %s ${FILTER(0-9,${EXTEN})} ${FILTER(0-9,${CALLERID(num)})} ${BASE64_ENCODE(${MESSAGE(body)})})
 same => n,Hangup()
""" % SMS_GSM)
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


class H(BaseHTTPRequestHandler):
    def _rep(self, st, obj):
        b = json.dumps(obj).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._rep(200 if self.path == "/" else 404, {"service": "osmo-inscription", "post": "/inscription"})

    def do_POST(self):
        if self.path.rstrip("/") != "/inscription":
            return self._rep(404, {"ok": False, "error": "inconnu"})
        try:
            n = min(int(self.headers.get("Content-Length") or 0), 4096)
            d = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._rep(400, {"ok": False, "error": "JSON attendu"})
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
