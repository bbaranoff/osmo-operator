#!/usr/bin/env python3
# Inscription des téléphones (appli network_monitoring) : code d'invitation -> compte SIP.
#
#   python3 tools/osmo-inscription.py [--port 8088] [--bind 0.0.0.0]   le service
#   python3 tools/osmo-inscription.py --nouveau-qrcode PSEUDO           invitation + QR code pour CET utilisateur
#   python3 tools/osmo-inscription.py --nouveau-code [--usages N]       invitation de 16 caracteres, sans QR code
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
    # LA SORTIE VERS L EXTERIEUR EST FERMEE aux inscrits : [inscrits] inclut
    # [internal], dont les numeros publics partent par le trunk (Zadarma,
    # dongle) aux frais du noeud - un code d invitation ne doit pas donner ca.
    # Les motifs ci-dessous passent AVANT ceux du contexte inclus ; seuls les
    # numeros de la liste blanche (--sortie NUM oui) sont renvoyes a [internal].
    permis = "|".join(sorted(n for n, c in e["comptes"].items() if c.get("sortie"))) or "aucun"
    # LE SMARTPHONE COMME LIGNE (chan_mobile, Bluetooth mains-libres). S il est
    # declare dans chan_mobile.conf, un poste autorise sort par LUI quand il est
    # connecte et libre (MobileStatus = 2), par le trunk habituel sinon.
    mobile = smartphone_declare()
    vers = "sortie-smartphone" if mobile else "internal"
    fermeture = "".join("""exten => %s,1,GotoIf($[${REGEX("^(%s)$" ${CALLERID(num)})}]?%s,${EXTEN},1)
 same => n,NoOp(=== SORTIE REFUSEE a ${CALLERID(num)} : ${EXTEN} (osmo-inscription --sortie) ===)
 same => n,Hangup(21)
""" % (motif, permis, vers) for motif in ("_0[1-9]XXXXXXXX", "_00.", "_+."))
    if mobile:
        tous = "&".join("PJSIP/%s" % n for n in sorted(e["comptes"]) if n in (e.get("smartphone_vers") or e["comptes"]))
        # ... et sur les postes internes du PC (Linphone A et B), s ils existent
        if not e.get("smartphone_vers"):
            tous = "&".join(x for x in (tous, "PJSIP/linphone_A", "PJSIP/linphone_B") if x)
        fermeture_fin = """
; Les numeros exterieurs d un poste autorise : par la SIM du smartphone s il est
; la (Bluetooth), sinon par le trunk du noeud.
[sortie-smartphone]
exten => _[+0-9].,1,MobileStatus(%(m)s,ETAT_MOBILE)
 same => n,GotoIf($["${ETAT_MOBILE}" = "2"]?mobile)
 same => n,NoOp(=== smartphone absent ou occupe (${ETAT_MOBILE}) : trunk du noeud ===)
 same => n,Goto(internal,${EXTEN},1)
 same => n(mobile),NoOp(=== SORTIE PAR LE SMARTPHONE : ${EXTEN} - de ${CALLERID(num)} ===)
 same => n,Dial(Mobile/%(m)s/${EXTEN},60,rT)
 same => n,Hangup()

; Les postes internes du noeud (Linphone A et B, sur le PC) : 7 + numero sort
; par le smartphone - 7123 pour la messagerie, 70612345678 pour un portable.
; C est le moyen d entendre un appel de la SIM sur les haut-parleurs du PC.
[internal]
exten => _7X.,1,NoOp(=== POSTE INTERNE -> SMARTPHONE : ${EXTEN:1} ===)
 same => n,Dial(Mobile/%(m)s/${EXTEN:1},60,rT)
 same => n,Hangup()

; Un appel recu par la SIM du smartphone : il sonne sur les postes du banc
; (--smartphone-vers NUM... pour n en faire sonner que certains).
[smartphone_in]
exten => s,1,NoOp(=== APPEL RECU PAR LA SIM : ${CALLERID(all)} ===)
; Un appel DU BANC qui sonne sur le smartphone (appli Android, compte « Banc »)
; est annonce lui aussi par le mains-libres, avec le numero du banc : ce n est
; pas un appel de la SIM. Ne pas le faire sonner sur les postes (boucle), et
; surtout ne pas raccrocher - raccrocher ici le refuserait sur le telephone.
 same => n,GotoIf($[${REGEX("^(3[0-9][0-9][0-9]|1001[0-9][0-9]|[1-7]00)$" ${CALLERID(num)})}]?banc)
 same => n,Dial(%(t)s,45,rT)
 same => n,Hangup()
 same => n(banc),NoOp(appel du banc sur le smartphone : laisse au telephone)
 same => n,Wait(14400)
""" % {"m": mobile, "t": tous or "PJSIP/aucun"}
    else:
        fermeture_fin = ""
    with open(os.path.join(AST, "extensions_inscrits.conf"), "w") as f:
        f.write("""; extensions_inscrits.conf - écrit par osmo-inscription.py, ne pas éditer
[inscrits]
""" + fermeture + """exten => _3XXX,1,NoOp(=== INSCRIT -> INSCRIT ${EXTEN} - CallerID: ${CALLERID(all)} ===)
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

""" + fermeture_fin + """
; Les SMS (SIP MESSAGE) des inscrits : vers un autre inscrit, en SIP ; vers
; un numero GSM, par le relais SMS (scripts/sms-sip-vers-gsm.py). Le texte
; passe en base64 : aucun caractere du SMS n atteint un shell.
[sms_inscrits]
; Un inscrit ecrit a un autre inscrit : par le relais aussi, qui remet le
; message a CHAQUE contact enregistre du destinataire. MessageSend(pjsip:3010)
; ne visait que le premier contact, souvent un ancien enregistrement mort
; (appli reinstallee) : le message partait dans le vide.
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


# UNE INVITATION = 16 CARACTERES, sans 0/o ni 1/l/i : 30^16, soit ~78 bits.
# Elle voyage dans un QR code (--nouveau-qrcode PSEUDO), avec l adresse du
# noeud et le pseudo : rien a taper. Les anciens codes courts (xxxx-xxxx)
# deja distribues restent reconnus tant qu ils n ont pas servi.
ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
LONGUEUR = 16


def jeton():
    return "".join(secrets.choice(ALPHABET) for _ in range(LONGUEUR))


def smartphone_declare():
    """Le nom de la ligne chan_mobile (un telephone appaire en Bluetooth), ou None."""
    try:
        txt = open(os.path.join(AST, "chan_mobile.conf")).read()
    except OSError:
        return None
    for nom, corps in re.findall(r"^\[(\w+)\]([^\[]*)", txt, re.M):
        if nom not in ("general", "adapter") and re.search(r"^\s*address\s*=", corps, re.M) \
                and re.search(r"^\s*port\s*=", corps, re.M):
            return nom
    return None


def normaliser(code):
    """Casse, espaces et tirets ignores. Un lien de QR code entier est accepte :
    on en prend le parametre « code »."""
    code = code or ""
    m = re.search(r"[?&]code=([^&\s]+)", code)
    if m:
        code = m.group(1)
    t = re.sub(r"[^0-9a-z]", "", code.lower())
    if len(t) == 8 and re.fullmatch(r"[0-9a-f]{8}", t):       # ancien code court
        return "%s-%s" % (t[:4], t[4:])
    return t


def noeud_ip():
    """L adresse du noeud a mettre dans le QR code (OSMO_NODE_IP, sinon la
    source de la route par defaut)."""
    ip = os.environ.get("OSMO_NODE_IP", "")
    if ip:
        return ip
    try:
        r = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True, text=True, timeout=3)
        m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)", r.stdout)
        return m.group(1) if m else ""
    except (OSError, subprocess.SubprocessError):
        return ""


PSEUDO_RE = r"[\w .\-]{1,40}"


def creer_invitation(pseudo, noeud="", usages=1):
    """Une invitation pour UN utilisateur nomme. Rend (lien, noeud) ; ValueError
    si le pseudo ou l adresse du noeud manquent. Sert a --nouveau-qrcode et a
    osmo-gtk (POST /admin/invitation)."""
    from urllib.parse import quote
    pseudo = (pseudo or "").strip()
    if not re.fullmatch(PSEUDO_RE, pseudo):
        raise ValueError("pseudo : 1 a 40 lettres, chiffres, espace, . _ -  (obligatoire : pas d utilisateur au hasard)")
    noeud = noeud or noeud_ip()
    if not noeud:
        raise ValueError("adresse du noeud introuvable : --noeud <adresse>")
    with VERROU:
        e = charger()
        code = jeton()
        e["codes"][code] = {"restant": usages, "pseudo": pseudo}
        sauver(e)
    return "osmo://inscription?noeud=%s&pseudo=%s&code=%s" % (noeud, quote(pseudo), code), noeud


def admin_etat():
    """Tout ce qu osmo-gtk montre dans son onglet Telephones."""
    e = charger()
    try:
        out = subprocess.run(["asterisk", "-rx", "pjsip show contacts"], capture_output=True, text=True, timeout=8).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    en_ligne = {m.group(1) for m in re.finditer(r"Contact:\s+(\d+)/\S+\s+\S+\s+Avail", out)}
    return {"ok": True, "noeud": noeud_ip(),
            "comptes": [{"num": k, "pseudo": v.get("pseudo", ""), "sortie": bool(v.get("sortie")),
                         "en_ligne": k in en_ligne} for k, v in sorted(e["comptes"].items())],
            "invitations": [{"debut": k[:4], "pseudo": v.get("pseudo", ""), "restant": v["restant"]}
                            for k, v in e["codes"].items() if v["restant"] > 0],
            "proxy": {"actif": proxy_actif(), "user": PROXY["user"] if proxy_actif() else None,
                      "dest": PROXY["dest"], "attente": len(PROXY["file"])},
            "bluetooth": bt_etat()}


def nouveau_qrcode(pseudo, noeud, png, usages=1):
    """Une invitation pour UN utilisateur nomme, et son QR code : dans le
    terminal, et en PNG. Rend le lien."""
    try:
        lien, noeud = creer_invitation(pseudo, noeud, usages)
    except ValueError as err:
        sys.exit(str(err))
    pseudo = pseudo.strip()
    png = png or os.path.join(os.path.dirname(ETAT), "qr-%s.png" % re.sub(r"[^\w.-]", "_", pseudo))
    try:
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", lien], check=True)
        subprocess.run(["qrencode", "-o", png, "-s", "10", "-m", "4", lien], check=True)
        os.chmod(png, 0o600)
        print("QR code : %s" % png)
    except FileNotFoundError:
        print("qrencode absent (apt install qrencode) : pas de QR code, voici le lien a transmettre")
    except subprocess.CalledProcessError as err:
        print("qrencode a echoue (%s) : voici le lien" % err)
    print("pour    : %s  (noeud %s, %d usage%s)" % (pseudo, noeud, usages, "s" if usages > 1 else ""))
    print("lien    : %s" % lien)
    return lien


def inscrire(code, pseudo):
    code, pseudo = normaliser(code), (pseudo or "").strip()
    with VERROU:
        e = charger()
        c = e["codes"].get(code)
        if not c or c["restant"] <= 0:
            # jamais l invitation entiere dans le journal : ses 4 premiers caracteres
            print("invitation refusée : %s… (%s)" % (code[:4], "épuisée" if c else "inconnue"), file=sys.stderr)
            return 403, {"ok": False, "error": "invitation inconnue ou déjà utilisée"}
        # une invitation nominative (QR code) : c est SON pseudo, quoi que dise le téléphone
        pseudo = c.get("pseudo") or pseudo
        if not re.fullmatch(PSEUDO_RE, pseudo):
            return 400, {"ok": False, "error": "pseudo : 1 à 40 lettres, chiffres, espace, . _ -"}
        libres = [str(n) for n in range(PREMIER, DERNIER + 1) if str(n) not in e["comptes"]]
        if not libres:
            return 503, {"ok": False, "error": "plus de numéro libre"}
        num, mdp = libres[0], secrets.token_urlsafe(12)
        e["comptes"][num] = {"pseudo": pseudo, "mdp": mdp, "code": code}
        c["restant"] -= 1
        sauver(e)
        ecrire_asterisk(e)
    return 200, {"ok": True, "msisdn": num, "sip_user": num, "sip_password": mdp, "pseudo": pseudo,
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


# ── LA LIGNE BLUETOOTH, PILOTEE PAR LES APPLIS ──────────────────────────────
# Le smartphone devient une ligne du banc par le mains-libres Bluetooth
# (chan_mobile). L onglet Proxy des applis fait tout d ici :
#   GET  /proxy/bluetooth            l etat : adaptateur, telephones appaires, ligne
#   POST /proxy/bluetooth/associer   ouvre une fenetre d appairage de 3 min : le
#                                    noeud devient visible et accepte ; le premier
#                                    telephone qui s associe devient LA ligne
#                                    (chan_mobile.conf ecrit, module recharge)
# Reserve a un compte du noeud (son mot de passe SIP sert de jeton).
BT = {"fin": 0.0, "message": "", "fil": None}
BT_DUREE = 180


def _sh(*cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def bt_adaptateur():
    out = _sh("bluetoothctl", "show")
    m = re.search(r"Controller ([0-9A-F:]{17})", out)
    a = re.search(r"Alias: (.+)", out)
    return {"adresse": m.group(1) if m else "", "nom": a.group(1).strip() if a else "",
            "allume": "Powered: yes" in out}


def bt_appaires():
    return [{"adresse": mac, "nom": nom.strip()}
            for mac, nom in re.findall(r"Device ([0-9A-F:]{17}) (.+)", _sh("bluetoothctl", "devices", "Paired"))]


def bt_ligne():
    """La ligne chan_mobile telle qu Asterisk la voit."""
    for l in _sh("asterisk", "-rx", "mobile show devices").splitlines():
        c = l.split()
        if len(c) >= 6 and re.fullmatch(r"[0-9A-F:]{17}", c[1]):
            return {"nom": c[0], "adresse": c[1], "connecte": c[4] == "Yes", "etat": c[5]}
    return None


def bt_etat():
    a = bt_adaptateur()
    reste = max(0, int(BT["fin"] - time.time()))
    return {"ok": True, "adaptateur": a, "appaires": bt_appaires(), "ligne": bt_ligne(),
            "fenetre": reste, "message": BT["message"]}


def bt_configurer(mac, nom):
    """Fait d un telephone appaire LA ligne du banc. -> message"""
    a = bt_adaptateur()
    _sh("bluetoothctl", "trust", mac)
    if "0000111f" not in _sh("bluetoothctl", "info", mac).lower():
        return "%s est associe, mais n offre pas le mains-libres (pas un telephone ?)" % nom
    _sh("asterisk", "-rx", "module load chan_mobile.so")
    port = None
    for l in _sh("asterisk", "-rx", "mobile search", timeout=60).splitlines():
        if l.startswith(mac):
            c = l.split()
            if c[-1].isdigit():
                port = c[-1]
    if not port:
        return "%s est associe, mais son canal mains-libres est introuvable (Bluetooth du telephone allume ?)" % nom
    with open(os.path.join(AST, "chan_mobile.conf"), "w") as f:
        f.write("""; chan_mobile.conf - ecrit par osmo-inscription.py (onglet Proxy des applis)
; Le smartphone comme ligne du banc, par Bluetooth (mains-libres).
[general]
interval=30

[adapter]
id=pc
address=%s

; %s
[smartphone]
address=%s
port=%s
context=smartphone_in
adapter=pc
group=1
""" % (a["adresse"], nom, mac, port))
    _sh("asterisk", "-rx", "module unload chan_mobile.so")
    time.sleep(1)
    _sh("asterisk", "-rx", "module load chan_mobile.so")
    with VERROU:
        ecrire_asterisk(charger())
    return "%s est la ligne du banc (canal %s)" % (nom, port)


def bt_fenetre():
    """3 min pendant lesquelles le noeud est visible et accepte un appairage."""
    avant = {d["adresse"] for d in bt_appaires()}
    _sh("rfkill", "unblock", "bluetooth")
    _sh("bluetoothctl", "power", "on")
    try:
        p = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    except OSError as e:
        BT["message"] = "bluetoothctl absent (%s)" % e
        BT["fin"] = 0
        return

    def dire(x):
        try:
            p.stdin.write(x + "\n"); p.stdin.flush()
        except OSError:
            pass
    for c in ("agent KeyboardDisplay", "default-agent", "pairable on", "discoverable on"):
        dire(c); time.sleep(0.5)
    BT["message"] = "le noeud est visible et accepte un telephone"
    nouveau = None
    while time.time() < BT["fin"] and nouveau is None:
        dire("yes")                               # confirme le code affiche des deux cotes
        time.sleep(2)
        nouveau = next((d for d in bt_appaires() if d["adresse"] not in avant), None)
    for c in ("discoverable off", "quit"):
        dire(c); time.sleep(0.3)
    try:
        p.wait(timeout=5)
    except subprocess.SubprocessError:
        p.kill()
    if nouveau is None:
        BT["message"] = "aucun telephone ne s est associe"
    else:
        BT["message"] = "%s associe, mise en place de la ligne..." % nouveau["nom"]
        BT["message"] = bt_configurer(nouveau["adresse"], nouveau["nom"])
    BT["fin"] = 0
    sys.stderr.write("bluetooth : %s\n" % BT["message"])


NUMEROS = {"quand": 0.0, "motif": ""}


def numeros_banc():
    """L expression reguliere des numeros que le noeud sert lui-meme : les
    comptes inscrits, et ce que le plan d appel [internal] connait de court
    (services 100, 600..., mobiles GSM _1001XX). Rien de fige dans les applis :
    elles la relisent. Les motifs longs ou ouverts (06..., 00., 7X.) sont les
    sorties vers l exterieur : ils n en font pas partie."""
    if time.time() - NUMEROS["quand"] < 60 and NUMEROS["motif"]:
        return NUMEROS["motif"]
    parts = set(charger()["comptes"])
    try:
        out = subprocess.run(["asterisk", "-rx", "dialplan show internal"], capture_output=True,
                             text=True, timeout=8).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for ext in re.findall(r"^\s+'([^']+)' =>", out, re.M):
        if re.fullmatch(r"\d{2,6}", ext):
            parts.add(ext)
        elif ext.startswith("_") and not re.search(r"[.!+*#]", ext):
            motif, n = "", 0
            for tok in re.findall(r"\[[^\]]+\]|.", ext[1:]):
                n += 1
                motif += {"X": r"\d", "Z": "[1-9]", "N": "[2-9]"}.get(tok, tok)
            if 2 <= n <= 6:
                parts.add(motif)
    NUMEROS.update(quand=time.time(), motif="|".join(sorted(parts)))
    return NUMEROS["motif"]


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
        if u.path.rstrip("/") == "/numeros":
            # les numeros du banc, pour le clavier natif des telephones
            return self._rep(200, {"ok": True, "motif": numeros_banc()})
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
        if u.path.rstrip("/") == "/admin/etat":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                return self._rep(403, {"ok": False, "error": "local seulement"})
            return self._rep(200, admin_etat())
        if u.path.rstrip("/") == "/proxy/bluetooth":
            return self._rep(200, bt_etat())
        if u.path.rstrip("/") == "/proxy":
            return self._rep(200, {"ok": True, "actif": proxy_actif(), "user": PROXY["user"] if proxy_actif() else None,
                                   "dest": PROXY["dest"], "attente": len(PROXY["file"])})
        self._rep(200 if u.path == "/" else 404, {"service": "osmo-inscription", "post": "/inscription"})

    def _admin(self, chemin, d):
        """L administration du noeud, pour osmo-gtk : cette machine seulement."""
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return self._rep(403, {"ok": False, "error": "local seulement"})
        if chemin == "/admin/invitation":
            try:
                lien, noeud = creer_invitation(str(d.get("pseudo") or ""), str(d.get("noeud") or ""))
            except ValueError as err:
                return self._rep(400, {"ok": False, "error": str(err)})
            sys.stderr.write("invitation creee pour %s (osmo-gtk)\n" % str(d.get("pseudo")).strip())
            return self._rep(200, {"ok": True, "lien": lien, "noeud": noeud})
        if chemin == "/admin/sortie":
            num = str(d.get("num") or "")
            with VERROU:
                e = charger()
                if num not in e["comptes"]:
                    return self._rep(404, {"ok": False, "error": "poste inconnu"})
                e["comptes"][num]["sortie"] = bool(d.get("oui"))
                sauver(e)
                ecrire_asterisk(e)
            return self._rep(200, {"ok": True})
        if chemin == "/admin/bluetooth/associer":
            with VERROU:
                if BT["fin"] <= time.time():
                    BT["fin"] = time.time() + BT_DUREE
                    BT["message"] = "ouverture..."
                    BT["fil"] = threading.Thread(target=bt_fenetre, daemon=True)
                    BT["fil"].start()
            return self._rep(200, bt_etat())
        return self._rep(404, {"ok": False, "error": "inconnu"})

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
        if chemin == "/proxy/bluetooth/associer":
            with VERROU:
                if BT["fin"] <= time.time():
                    BT["fin"] = time.time() + BT_DUREE
                    BT["message"] = "ouverture..."
                    BT["fil"] = threading.Thread(target=bt_fenetre, daemon=True)
                    BT["fil"].start()
            sys.stderr.write("bluetooth : fenetre d appairage ouverte par %s\n" % d.get("user"))
            return self._rep(200, bt_etat())
        if chemin == "/proxy/bluetooth/ligne":
            # refaire la ligne avec un telephone deja appaire
            mac = str(d.get("adresse") or "").upper()
            dev = next((x for x in bt_appaires() if x["adresse"] == mac), None)
            if dev is None:
                return self._rep(404, {"ok": False, "error": "ce telephone n est pas appaire au noeud"})
            BT["message"] = bt_configurer(dev["adresse"], dev["nom"])
            return self._rep(200, bt_etat())
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
        if chemin.startswith("/admin"):
            return self._admin(chemin, d)
        if chemin.startswith("/proxy"):
            return self._proxy(chemin, d)
        if chemin != "/inscription":
            return self._rep(404, {"ok": False, "error": "inconnu"})
        st, rep = inscrire(d.get("code"), d.get("pseudo"))
        if rep.get("ok"):
            rep["sip_domain"] = adresse_sip(self.client_address[0], self.connection.getsockname()[0])
        self._rep(st, rep)

    def log_message(self, fmt, *a):
        # jamais un mot de passe dans le journal : /proxy/sortants le porte dans son adresse
        ligne = re.sub(r"(mdp|code)=[^&\s\"]+", r"\1=***", fmt % a)
        sys.stderr.write("%s %s\n" % (self.client_address[0], ligne))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--nouveau-code", action="store_true")
    ap.add_argument("--usages", type=int, default=1)
    ap.add_argument("--nouveau-qrcode", metavar="PSEUDO",
                    help="une invitation de 16 caracteres pour CET utilisateur, en QR code (terminal + PNG)")
    ap.add_argument("--noeud", default="", help="adresse du noeud a mettre dans le QR code (defaut : celle de la route par defaut)")
    ap.add_argument("--png", default="", help="fichier PNG du QR code (defaut : a cote de l etat, qr-<pseudo>.png)")
    ap.add_argument("--liste", action="store_true")
    ap.add_argument("--smartphone-vers", nargs="*", metavar="NUMERO",
                    help="les postes qui sonnent quand la SIM du smartphone recoit un appel (aucun = tous)")
    ap.add_argument("--sortie", nargs=2, metavar=("NUMERO", "oui|non"),
                    help="autorise (oui) ou ferme (non) les appels vers l exterieur pour ce poste")
    a = ap.parse_args()
    if a.nouveau_code:
        with VERROU:
            e = charger()
            code = jeton()
            e["codes"][code] = {"restant": a.usages}
            sauver(e)
        print(code)
        return
    if a.nouveau_qrcode is not None:
        nouveau_qrcode(a.nouveau_qrcode, a.noeud, a.png, a.usages)
        return
    if a.smartphone_vers is not None:
        with VERROU:
            e = charger()
            inconnus = [n for n in a.smartphone_vers if n not in e["comptes"]]
            if inconnus:
                sys.exit("poste inconnu : %s" % ", ".join(inconnus))
            e["smartphone_vers"] = a.smartphone_vers
            sauver(e)
            ecrire_asterisk(e)
        print("appels recus par la SIM -> %s" % (", ".join(a.smartphone_vers) or "tous les postes"))
        return
    if a.sortie:
        num, choix = a.sortie
        with VERROU:
            e = charger()
            if num not in e["comptes"]:
                sys.exit("poste inconnu : %s" % num)
            e["comptes"][num]["sortie"] = choix.lower() in ("oui", "o", "1", "yes", "on")
            sauver(e)
            ecrire_asterisk(e)
        print("%s : sortie vers l exterieur %s" % (num, "autorisee" if e["comptes"][num]["sortie"] else "fermee"))
        return
    if a.liste:
        e = charger()
        for k, v in e["codes"].items():
            if v["restant"] > 0:                      # les 4 premiers caracteres suffisent a la reconnaitre
                print("invitation %s…  restant %d%s" % (k[:4], v["restant"], "  pour %s" % v["pseudo"] if v.get("pseudo") else ""))
        for k, v in sorted(e["comptes"].items()):
            print("compte %s  %s%s" % (k, v["pseudo"], "  (sortie vers l exterieur)" if v.get("sortie") else ""))
        return
    ecrire_asterisk(charger())
    print("osmo-inscription sur http://%s:%d/inscription" % (a.bind, a.port), file=sys.stderr)
    ThreadingHTTPServer((a.bind, a.port), H).serve_forever()


if __name__ == "__main__":
    main()
