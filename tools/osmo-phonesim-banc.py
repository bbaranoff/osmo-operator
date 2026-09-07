#!/usr/bin/env python3
# osmo-phonesim-banc.py - LE MODEM DU BANC, VU PAR oFONO.
#
# LA CHAINE COMPLETE, ET LA PLACE DE CE FICHIER DEDANS :
#
#   Android → rild → libreference-ril.so → pty AT → osmo-ril-atmodem.py → oFono
#                                                                           ↑
#                                                   CE PROGRAMME (AT sur TCP) ┘
#                                                            ↓
#                                            le banc : VTY osmo-bsc / osmo-msc
#
# oFono ne fabrique pas de modem : il en PILOTE un. Sur ce banc il n y a pas de
# dongle - « l EC25, pour nous, c est oFono ». Il faut donc donner a oFono
# quelque chose qui se comporte comme un modem : c est le role du plugin
# phonesim, qui ouvre une connexion TCP et y parle AT tout court. Ce programme
# tient l autre bout de cette connexion et repond en lisant LE BANC.
#
# Mise en service :
#   1. /etc/ofono/phonesim.conf :
#          [osmo]
#          Address=127.0.0.1
#          Port=12345
#   2. ce programme (il doit ecouter AVANT qu ofonod cherche le modem)
#   3. systemctl restart ofono  ->  un modem apparait dans org.ofono.Manager
#
# Ce que le modem raconte vient d osmo-bsc (VTY 4242) : le reseau (MCC/MNC,
# nom), l ARFCN, l etat d enregistrement. Un banc arrete = un modem « pas
# enregistre », ce qui est la verite, pas une panne.
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HOST = os.environ.get("OSMO_PHONESIM_HOST", "127.0.0.1")
PORT = int(os.environ.get("OSMO_PHONESIM_PORT", "12345"))
BSC_VTY = (os.environ.get("OSMO_BSC_VTY_HOST", "127.0.0.1"),
           int(os.environ.get("OSMO_BSC_VTY_PORT", "4242")))
MSC_VTY = (os.environ.get("OSMO_MSC_VTY_HOST", "127.0.0.1"),
           int(os.environ.get("OSMO_MSC_VTY_PORT", "4254")))
# Le mobile osmocom-bb. C est LUI l abonne 100101, et c est son pont audio
# (gsm_audio / gsm_mic) que la VM relaie : sans lui, pas de voix.
MOB_VTY = (os.environ.get("OSMO_MOB_VTY_HOST", "127.0.0.1"),
           int(os.environ.get("OSMO_MOB_VTY_PORT", "4247")))
MS = os.environ.get("OSMO_MS_NAME", "1")
# L abonne que ce modem INCARNE : celui du telephone Android. Sur le banc c est
# 100101 (IMSI 001010001000001), releve par « show subscriber msisdn 100101 »
# sur le VTY d osmo-msc.
IMSI = os.environ.get("OSMO_MS_IMSI", "001010001000001")
MSISDN = os.environ.get("OSMO_MS_MSISDN", "100101")
# La reception des SMS passe par le serveur SMPP d osmo-msc (port 2775) : un
# ESME est deja declare dans la conf du banc (esme msc_tester / osmocom1).
SMPP_HOST = os.environ.get("OSMO_SMPP_HOST", "127.0.0.1")
SMPP_PORT = int(os.environ.get("OSMO_SMPP_PORT", "2775"))
SMPP_ID = os.environ.get("OSMO_SMPP_ID", "msc_tester")
SMPP_PW = os.environ.get("OSMO_SMPP_PASSWORD", "osmocom1")
SMPP_ON = os.environ.get("OSMO_SMPP", "1") == "1"
# Un SMS entrant va-t-il AUSSI au mobile osmocom-bb ? Oui par defaut : Android
# et le mobile sont le meme abonne du banc, et on veut les deux en parallele.
DUPLIQUE = os.environ.get("OSMO_SMS_DUPLIQUE", "1") == "1"
# Les boites d entree des SMS remis par la passerelle du banc. Ce programme
# tourne DEUX fois (le modem d Android en mode ecoute, celui de la VM en mode
# --connect) : il leur faut donc un port chacun. C est scripts/sms_notify.py
# qui les previent, et scripts/sms-interop-relay.py qui l appelle.
SMS_IN_HOST = os.environ.get("OSMO_SMS_IN_HOST", "127.0.0.1")
SMS_IN_LISTEN = int(os.environ.get("OSMO_SMS_IN_PORT", "12348"))
SMS_IN_CONNECT = int(os.environ.get("OSMO_SMS_IN_PORT_VM", "12349"))
# Comment un appel demande par le telephone Android devient un appel du banc.
# {num} = le numero compose, {msisdn} = notre numero. Le canal Local entre dans
# le plan de numerotation d Asterisk (contexte « internal », celui qui porte
# 100/500/600 et la passerelle GSM), puis rebascule sur notre propre numero :
# le banc etablit donc un vrai appel entre le numero compose et le mobile.
CTX = os.environ.get("OSMO_CALL_CONTEXT", "internal")
# Et le contexte par lequel le banc nous APPELLE. Releve sur le banc, sur un
# appel de 100102 vers 100101 : « Event: DialBegin / Context: gsm_in /
# DestExten: 100101 ». C est ce qui distingue un appel entrant de la seconde
# jambe de nos propres appels sortants, qui compose aussi notre numero.
# [2026-09-07] UN SEUL CONTEXTE NE SUFFISAIT PAS : LE TELEPHONE NE SONNAIT
# QUE POUR LES APPELS DE SON PROPRE OPERATEUR. « gsm_in » est le contexte de
# l endpoint gsm_msc, celui par lequel arrive un appel VENU DE LA RADIO
# (100102 -> 100101). Un appel d un AUTRE operateur, lui, entre par le trunk
# interop (endpoint interop_trunk_opN, context=interop_in) et un appel d un
# Linphone par « internal » : dans les deux cas le DialBegin ne portait pas
# « gsm_in », entrant() n etait jamais appele, et AUCUN RING ne partait vers
# oFono. Le mobile osmocom-bb, lui, etait bien pagine par le MSC (la radio
# s allume) - mais le combine, cote AT, ne sonnait pas ; personne ne decrochait
# et le MSC finissait par relacher (MNCC cause DEST_OOO), ce qui remonte en
# 503 chez l appelant. D ou « les appels op3 -> op1 ne passent pas ».
# On accepte donc TOUS les contextes par lesquels un appel peut nous arriver.
# Le filtre qui compte reste DestExten == notre MSISDN : la seconde jambe de
# nos propres appels sortants compose le numero DISTANT, jamais le notre.
IN_CTX = {c.strip() for c in os.environ.get(
    "OSMO_CALL_IN_CONTEXT", "gsm_in,interop_in,internal").split(",") if c.strip()}
# [2026-09-06] L APPEL PASSE PAR L AMI, PAS PAR LA CLI. « channel originate »
# vient du module res_clioriginate, absent de cette installation (modules.conf
# est en autoload = no) : la CLI repondait « No such command ». L AMI, lui, est
# deja actif dans manager.conf ; il n y manquait qu un compte, pose par
# start-direct.sh depuis configs/manager-osmo.conf.
AMI_HOST = os.environ.get("OSMO_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("OSMO_AMI_PORT", "5038"))
AMI_USER = os.environ.get("OSMO_AMI_USER", "osmo")
AMI_PASS = os.environ.get("OSMO_AMI_PASSWORD", "osmocom1")

_PROMPT = re.compile(rb'[\r\n][A-Za-z0-9_.\-]+(?:\([^)]*\))?[>#]\s*$')


AT_LOG = os.environ.get("OSMO_AT_LOG_OFONO", "/var/log/osmo-at-ofono.log")
_atlog = None


def log(*a):
    print("[banc]", *a, flush=True)


def atlog(sens, texte):
    """Le journal de CE port-ci : ce qu oFono envoie au modem du banc et ce
    qu il repond. Le pendant de /var/log/osmo-at.log, qui est l autre bout de
    la chaine (le RIL d Android). Les deux ensemble racontent tout le trajet."""
    global _atlog
    if _atlog is None:
        # [2026-09-07] SE RABATTRE SUR /tmp. L instance qui sert la VM tourne
        # sous l utilisateur ordinaire et ne peut pas ecrire dans /var/log :
        # elle perdait donc TOUTE sa trace AT, celle qui dit justement ce que
        # ModemManager fait d un RING ou d un NO CARRIER. Sans trace, plus de
        # diagnostic possible sur le seul bout de chaine qui compte ici.
        for chemin in (AT_LOG, "/tmp/osmo-at-ofono-%s.log" % os.environ.get("USER", "x")):
            try:
                _atlog = open(chemin, "a", buffering=1)
                try:
                    os.chmod(chemin, 0o644)
                except OSError:
                    pass
                if chemin != AT_LOG:
                    print("[banc] trace AT dans %s" % chemin, file=sys.stderr)
                break
            except OSError as e:
                print("[banc] journal %s impossible : %s" % (chemin, e), file=sys.stderr)
                _atlog = False
    if not _atlog:
        return
    stamp = time.strftime("%H:%M:%S") + ".%03d" % (int(time.time() * 1000) % 1000)
    for ligne in texte.replace("\r", "\n").split("\n"):
        if ligne.strip():
            try:
                _atlog.write("%s %s %s\n" % (stamp, sens, ligne.strip()))
            except OSError:
                return


# ── LE BANC, LU PAR SON VTY ─────────────────────────────────────────────────
class Vty:
    """Une connexion VTY qu on garde ouverte (meme mecanique que
    tools/osmo-ts-probe.py : on lit jusqu au prompt, on ne dort pas)."""

    def __init__(self, addr):
        self.addr = addr
        self.s = None
        self.lock = threading.Lock()

    def _connect(self):
        try:
            self.s = socket.create_connection(self.addr, timeout=1.0)
            self.s.settimeout(1.0)
            self._read()
            return True
        except OSError:
            self.s = None
            return False

    def _read(self, limit=262144):
        buf = b""
        while True:
            try:
                chunk = self.s.recv(4096)
            except socket.timeout:
                break
            except OSError:
                self.s = None
                return None
            if not chunk:
                self.s = None
                return None
            buf += chunk
            if _PROMPT.search(buf) or len(buf) > limit:
                break
        return buf

    def cmd(self, text):
        with self.lock:
            if self.s is None and not self._connect():
                return None
            try:
                self.s.sendall(text.encode() + b"\r\n")
            except OSError:
                self.s = None
                if not self._connect():
                    return None
                try:
                    self.s.sendall(text.encode() + b"\r\n")
                except OSError:
                    self.s = None
                    return None
            out = self._read()
            return out.decode(errors="replace") if out else None


BSC = Vty(BSC_VTY)
MSC = Vty(MSC_VTY)
MOB = Vty(MOB_VTY)


def mobile(action, essais=1):
    """Une commande d appel sur le mobile. Rend True si elle a ete acceptee.

    [2026-09-07] POURQUOI LE MOBILE, ET PAS LA VM. Un ATD de la VM fait lancer
    a Asterisk DEUX jambes : l une joue le service demande (l echo du 600),
    l autre appelle le 100101 - c est-a-dire le MOBILE, pas la VM. Releve sur
    le banc, quatorze canaux restes ouverts, tous par paires :
        Local/600@internal-0000000b;2   Application: Echo
        Local/600@internal-0000000b;1   Application: Congestion
    La jambe qui doit joindre l abonne tombait sur Congestion(), faute de
    decroche : l echo parlait dans le vide, gsm_audio restait a zero (crete 0,
    mesuree) et on n entendait rien. Or c est ce pont-la que la VM relaie. Le
    mobile doit donc repondre - et il n y a personne pour appuyer sur la
    touche. On le fait par son VTY.
    """
    for _ in range(essais):
        MOB.cmd("enable")
        out = MOB.cmd("call %s %s" % (MS, action))
        if out is not None and "%" not in out:
            return True
        time.sleep(0.5)
    return False


def mobile_decroche():
    """Le decroche, en insistant : la jambe vers l abonne met un instant a
    faire sonner le mobile, et une seule tentative arrive trop tot."""
    if mobile("answer", essais=30):
        log("mobile : decroche")
        return True
    log("mobile : rien a decrocher")
    return False


class Banc:
    """L etat du banc, rafraichi a la demande et garde une seconde en cache -
    un modem est interroge en rafale au demarrage du RIL (CREG, COPS, CSQ...),
    inutile de refaire quatre allers-retours VTY pour la meme reponse."""

    def __init__(self):
        self._t = 0
        self._v = {}

    def state(self):
        if time.time() - self._t < 1.0:
            return self._v
        v = {"up": False, "mcc": "001", "mnc": "01", "name": "Osmocom",
             "arfcn": "", "lac": 0, "cid": 0}
        txt = BSC.cmd("show network")
        if txt:
            v["up"] = True
            # [2026-09-06] LE FORMAT REEL D OsmoBSC, releve sur le banc :
            #   « BSC is on MCC-MNC 001-01 and has 2 BTS »
            # (et non les « Country Code: » / « Network Code: » que cherchait la
            # premiere version - elle ne trouvait donc jamais rien et laissait
            # le modem sur les valeurs par defaut).
            m = re.search(r'MCC-MNC\s+(\d+)-(\d+)', txt)
            if m:
                v["mcc"], v["mnc"] = m.group(1), m.group(2)
            m = re.search(r'Network Name.*?:\s*(\S.*)', txt)
            if m:
                v["name"] = m.group(1).strip()
        txt = BSC.cmd("show bts 0")
        if txt:
            m = re.search(r'ARFCN\s+(\d+)', txt)
            if m:
                v["arfcn"] = m.group(1)
            m = re.search(r'LAC\s+(\d+)', txt)
            if m:
                v["lac"] = int(m.group(1))
            m = re.search(r'(?:Cell ID|CI)\s+(\d+)', txt)
            if m:
                v["cid"] = int(m.group(1))
        self._v, self._t = v, time.time()
        return v


BANC = Banc()


# ── ASTERISK, PAR L AMI ─────────────────────────────────────────────────────
def _ami(actions, wait=3.0):
    """Ouvre une session AMI, joue les actions, rend la reponse brute."""
    try:
        s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    except OSError as e:
        return None, "AMI injoignable (%s)" % e
    try:
        s.settimeout(wait)
        s.recv(4096)                                  # la banniere
        s.sendall(("Action: Login\r\nUsername: %s\r\nSecret: %s\r\n\r\n"
                   % (AMI_USER, AMI_PASS)).encode())
        rep = s.recv(4096).decode(errors="replace")
        if "Success" not in rep:
            return None, "connexion AMI refusee"
        for act in actions:
            s.sendall(act.encode())
        out = b""
        end = time.time() + wait
        while time.time() < end:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            out += chunk
            if b"Response: Success" in out or b"Response: Error" in out:
                break
        return out.decode(errors="replace"), ""
    except OSError as e:
        return None, str(e)
    finally:
        try:
            s.sendall(b"Action: Logoff\r\n\r\n")
            s.close()
        except OSError:
            pass


def ami_originate(num):
    """Fait naitre l appel : le numero compose est appele dans le plan du banc,
    et une fois decroche il est mis en relation avec notre propre numero - donc
    avec le mobile de l abonne. Rend (ok, canal ou raison)."""
    chan = "Local/%s@%s" % (num, CTX)
    act = ("Action: Originate\r\n"
           "Channel: %s\r\n"
           "Context: %s\r\n"
           "Exten: %s\r\n"
           "Priority: 1\r\n"
           "CallerID: %s\r\n"
           "Async: true\r\n\r\n" % (chan, CTX, MSISDN, MSISDN))
    out, err = _ami([act], wait=5.0)
    if out is None:
        return False, err
    if "Response: Error" in out:
        m = re.search(r"Message: (.+)", out)
        return False, (m.group(1).strip() if m else "refus d Asterisk")
    return True, chan


def ami_hangup(channel):
    if not channel:
        return
    _ami(["Action: Hangup\r\nChannel: %s\r\n\r\n" % channel], wait=2.0)


def _bloc(txt):
    """Un bloc d evenement AMI (« Cle: valeur » par ligne) rendu en dict."""
    d = {}
    for ligne in txt.split("\r\n"):
        cle, sep, val = ligne.partition(":")
        if sep:
            d[cle.strip()] = val.strip()
    return d


class AmiEcoute(threading.Thread):
    """L oreille sur Asterisk.

    [2026-09-07] SANS ELLE, NI SONNERIE NI RACCROCHE. Ce modem ne savait que
    COMPOSER. Il n emettait aucun RING : ModemManager n avait donc rien a
    montrer et les appels entrants n existaient pas dans l interface. Et il
    n apprenait jamais qu un appel s etait termine : quand le correspondant
    raccrochait, l ecran d appel restait affiche. Les deux manques ont la meme
    cause - personne n ecoutait Asterisk - et donc le meme remede.

    Ce qu on guette, releve sur le banc pour un appel de 100102 vers 100101 :
        Event: DialBegin      Context: gsm_in
        CallerIDNum: 100102   DestExten: 100101
        DestChannel: PJSIP/gsm_msc-0000000f
    puis Hangup sur ce meme canal pour la fin. Le contexte compte : nos propres
    appels sortants font eux aussi composer notre numero, mais depuis
    « internal » - sans ce filtre le modem se sonnerait lui-meme.
    """

    daemon = True

    def run(self):
        while True:
            try:
                self._session()
            except OSError as e:
                log("AMI : lien perdu (%s)" % e)
            time.sleep(5)

    def _session(self):
        s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
        try:
            s.settimeout(None)
            s.recv(4096)                                   # la banniere
            s.sendall(("Action: Login\r\nUsername: %s\r\nSecret: %s\r\n"
                       "Events: on\r\n\r\n" % (AMI_USER, AMI_PASS)).encode())
            log("AMI : a l ecoute des appels")
            buf = b""
            while True:
                d = s.recv(8192)
                if not d:
                    return
                buf += d
                while b"\r\n\r\n" in buf:
                    blk, buf = buf.split(b"\r\n\r\n", 1)
                    self._evenement(_bloc(blk.decode(errors="replace")))
        finally:
            try:
                s.close()
            except OSError:
                pass

    def _evenement(self, e):
        modem = CURRENT
        if modem is None:
            return
        ev = e.get("Event")
        if ev == "DialBegin" and e.get("Context") in IN_CTX \
                and e.get("DestExten") == MSISDN:
            modem.entrant(e.get("CallerIDNum") or "", e.get("DestChannel") or "")
        elif ev == "Newchannel":
            # [2026-09-07] LE NOM QU ON GARDAIT N EN ETAIT PAS UN.
            # ami_originate range « Local/600@internal », qui est la DEMANDE.
            # Asterisk, lui, cree « Local/600@internal-0000000b;1 » : le
            # Action: Hangup sur l ancien nom ne trouvait rien et ne raccrochait
            # donc jamais - d ou les quatorze canaux empiles sur le banc. On
            # note le vrai nom des qu il apparait.
            chan = e.get("Channel") or ""
            for c in modem.calls:
                ref = c.get("channel")
                if ref and chan.startswith(ref) and chan != ref:
                    c["channel"] = chan
        elif ev == "Hangup" or (ev == "DialEnd" and e.get("DialStatus") != "ANSWER"):
            for chan in (e.get("Channel"), e.get("DestChannel")):
                if chan:
                    modem.fin_appel(chan)


# ── LE MODEM AT ─────────────────────────────────────────────────────────────
class AtHandler(socketserver.StreamRequestHandler):
    """Un modem par connexion : oFono en ouvre une seule."""

    def setup(self):
        super().setup()
        global CURRENT
        CURRENT = self            # oFono n ouvre qu une connexion : c est celle-ci
        self.echo = True          # un vrai modem demarre en echo
        self.cmee = 1
        self.creg_mode = 0
        self.cops_format = 2          # 0 = nom long, 1 = nom court, 2 = MCC/MNC
        self.calls = []               # les appels en cours, pour +CLCC
        self.sms_target = None
        # Comment ce systeme veut qu on lui annonce les SMS. mt=2 : le message
        # pousse tel quel ; mt=1 : rangé, et on ne signale que l index. On
        # part sur 2, et AT+CNMI= vient dire la verite.
        self.cnmi_mt = 2
        self.cmgf = 0             # 0 = PDU (ce qu utilise ModemManager), 1 = texte
        log("oFono s est connecte depuis %s" % (self.client_address,))

    def finish(self):
        """Le lien est tombe : ce modem n est plus « le » modem.

        [2026-09-07] CURRENT RESTAIT SUR UN MORT. Il etait pose dans setup() et
        jamais repris : apres une deconnexion, on_passerelle_sms() croyait
        avoir un correspondant, deliver_sms() ecrivait dans une douille fermee
        (out() avale l OSError) et journalisait « SMS remis » - un message
        annonce comme remis a personne. Meme piege pour les RING d AmiEcoute.
        La boite, elle, garde le message : il ressortira au prochain AT+CMGL.
        """
        global CURRENT
        if CURRENT is self:
            CURRENT = None
        try:
            super().finish()
        except OSError:
            pass

    def out(self, text):
        atlog(">", text)
        try:
            self.wfile.write(("\r\n%s\r\n" % text).encode())
            self.wfile.flush()
        except OSError:
            pass

    def ok(self):
        self.out("OK")

    def err(self, code=100):
        self.out("+CME ERROR: %d" % code if self.cmee else "ERROR")

    def handle(self):
        buf = b""
        while True:
            try:
                data = self.rfile.read1(4096)
            except (OSError, ValueError):
                break
            if not data:
                break
            if self.echo:
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                except OSError:
                    pass
            buf += data
            while True:
                m = re.search(rb"[\r\n\x1a]", buf)
                if not m:
                    break
                line, buf = buf[:m.start()], buf[m.end():]
                text = line.decode(errors="replace").strip()
                if text:
                    atlog("<", text)
                if self.sms_target is not None and m.group() == b"\x1a":
                    self.sms(text)
                elif text:
                    self.command(text)
        log("oFono s est deconnecte")

    # -- un SMS venu du banc, remis au modem
    # -- les appels entrants, pousses par AmiEcoute
    def entrant(self, num, chan):
        """Le banc nous appelle : on sonne jusqu a ce que ca cesse."""
        if any(c.get("channel") == chan for c in self.calls):
            return
        c = {"num": num, "state": "incoming", "channel": chan}
        self.calls.append(c)
        log("appel entrant de %s (%s)" % (num or "inconnu", chan))
        threading.Thread(target=self._sonne, args=(c,), daemon=True).start()

    def _sonne(self, c):
        """RING toutes les trois secondes, et +CLIP juste derriere pour donner
        le numero - c est ce que ModemManager attend pour presenter l appel
        (AT+CLIP=1 fait partie des reglages qu on accepte)."""
        while c in self.calls and c["state"] == "incoming":
            self.out("RING")
            if c["num"]:
                self.out('+CLIP: "%s",129,,,,0' % c["num"])
            time.sleep(3)

    def fin_appel(self, chan):
        """Asterisk a raccroche ce canal. Sans ce chemin, l ecran d appel de
        Phosh restait affiche quand le correspondant raccrochait."""
        for c in list(self.calls):
            ref = c.get("channel")
            # Nos appels sortants gardent « Local/600@internal », qu Asterisk
            # decline en « Local/600@internal-0000001a;1 » : on compare donc
            # par le debut. Les entrants, eux, portent le nom exact.
            if ref and chan.startswith(ref):
                self.calls.remove(c)
                log("appel termine (%s)" % chan)
                self.out("NO CARRIER")

    def deliver_sms(self, sender, text):
        """Remet un SMS entrant DE LA FACON QUE LE SYSTEME A DEMANDEE.

        On range toujours le message : meme en mt=2 le systeme peut vouloir le
        relire (AT+CMGL au demarrage). Ensuite seulement on choisit l URC.
        """
        pdu = pdu_deliver(sender, text)
        idx = inbox_ranger(sender, text, pdu)
        if self.cnmi_mt == 2:
            tpdu_len = len(pdu) // 2 - 1      # sans l octet de SMSC en tete
            self.out("+CMT: ,%d\r\n%s" % (tpdu_len, pdu))
            log("SMS remis directement (+CMT) : %s" % text)
        else:
            self.out('+CMTI: "SM",%d' % idx)
            log("SMS range en SM[%d], index signale (+CMTI) : %s" % (idx, text))

    # -- les trois commandes qui vont avec la boite
    def _sms_ligne(self, m, entete):
        """Une entree de CMGR/CMGL, dans le mode courant."""
        if self.cmgf:                         # mode texte
            stat = "REC READ" if m["lu"] else "REC UNREAD"
            return '%s"%s","%s",,"%s"\r\n%s' % (entete, stat, m["sender"],
                                                 m["ts"], m["text"])
        stat = 1 if m["lu"] else 0            # mode PDU : 0 non lu, 1 lu
        return "%s%d,,%d\r\n%s" % (entete, stat, len(m["pdu"]) // 2 - 1,
                                     m["pdu"])

    # -- l envoi d un SMS par le banc
    def sms(self, text):
        num, self.sms_target = self.sms_target, None
        if num == "<pdu>":
            try:
                num, text = parse_submit(text.strip())
            except (ValueError, IndexError) as e:
                log("PDU illisible (%s) : %s" % (e, text[:60]))
                self.err()
                return
        out = MSC.cmd('subscriber msisdn %s sms sender msisdn %s send %s'
                      % (num, MSISDN, text))
        if out is None:
            log("SMS non envoye : osmo-msc injoignable")
            self.err()
            return
        log("SMS a %s : %s" % (num, text))
        self.out("+CMGS: 1")
        self.ok()

    def command(self, line):
        cmd = line.upper()
        if not cmd.startswith("AT"):
            return
        ub = cmd[2:]
        body = line[2:]
        st = BANC.state()

        if ub in ("", "&F", "Z", "V1", "Q0", "S0=0", "+CMEE=1", "+CMEE=2",
                  "+CLIP=1", "+COLP=0", "+CSSN=0,0", "+CMOD=0", "+CSNS=0",
                  "+CSCS=\"IRA\"",
                  "+CSCS=\"UCS2\"", "+CGEREP=1,0", "+CVHU=0", "&C1", "&D2"):
            self.ok()
            return
        if ub == "E0":
            self.echo = False; self.ok(); return
        if ub == "E1":
            self.echo = True; self.ok(); return

        if ub in ("+CGMI", "+GMI"):
            self.out("Osmocom"); self.ok(); return
        if ub in ("+CGMM", "+GMM"):
            self.out("osmo-banc"); self.ok(); return
        if ub in ("+CGMR", "+GMR"):
            self.out("1.0"); self.ok(); return
        if ub in ("+CGSN", "+GSN"):
            self.out("35000000000000"); self.ok(); return
        if ub == "+CIMI":
            self.out(IMSI); self.ok(); return
        if ub == "+CPIN?":
            self.out("+CPIN: READY"); self.ok(); return
        if ub.startswith("+CNUM"):
            self.out('+CNUM: "","%s",129' % MSISDN); self.ok(); return

        if ub.startswith("+CFUN"):
            if ub.endswith("?"):
                self.out("+CFUN: %d" % (1 if st["up"] else 4))
            self.ok(); return

        if ub.startswith("+CEREG"):
            # [2026-09-07] +CEREG N EXISTE PAS SUR CE MODEM, ET C EST VOULU.
            # +CEREG est l enregistrement EPS, celui de la LTE. Repondre
            # seulement « pas enregistre » ne suffisait pas : en repondant a
            # AT+CEREG=? le modem DECLARE savoir faire de la LTE, et
            # ModemManager le classe comme un modem 4G - Phosh affichait « 4G »
            # sur un banc GSM. Un modem 2G repond ERROR a +CEREG, tout court.
            self.err(); return

        if ub.startswith(("+CREG", "+CGREG")):
            tag = "+CREG" if ub.startswith("+CREG") else "+CGREG"
            # [2026-09-06] LA FORME « TEST » N EST PAS UN REGLAGE. Le driver
            # atmodem sonde d abord AT+CREG=? et attend la LISTE des modes
            # supportes ; un simple OK lui fait conclure que le modem ne sait
            # pas s enregistrer - oFono journalisait « Unable to initialize
            # Network Registration » et n envoyait plus jamais AT+CREG?, donc
            # pas d interface NetworkRegistration du tout. Meme piege pour
            # +CGREG (la data), d ou « GPRS not supported on this device ».
            if ub.endswith("=?"):
                self.out("%s: (0-2)" % tag); self.ok(); return
            if "=" in ub:
                try:
                    self.creg_mode = int(ub.split("=")[1][0])
                except (ValueError, IndexError):
                    self.creg_mode = 0
                self.ok(); return
            reg = 1 if st["up"] else 0        # 1 = enregistre sur le reseau local
            # [2026-09-07] ET ON DIT LAQUELLE. Le dernier champ de +CREG est la
            # technologie d acces : 0 = GSM. Sans lui, ModemManager n a rien
            # pour trancher et retombe sur ce que le modem PRETEND savoir
            # faire. On l affirme donc, plutot que de le laisser deviner.
            if self.creg_mode >= 2:
                self.out('%s: %d,%d,"%04X","%08X",0'
                         % (tag, self.creg_mode, reg, st["lac"], st["cid"]))
            else:
                self.out("%s: %d,%d" % (tag, self.creg_mode, reg))
            self.ok(); return

        if ub.startswith("+COPS"):
            # oFono interroge l operateur DEUX FOIS, dans deux formats : il pose
            # AT+COPS=3,2 puis AT+COPS? pour le code numerique (MCC/MNC), et
            # AT+COPS=3,0 puis AT+COPS? pour le nom. Repondre toujours en
            # numerique laissait le nom vide et MCC/MNC a None cote oFono - le
            # format demande doit etre retenu.
            if ub.endswith("=?"):
                self.out('+COPS: (2,"%s","%s","%s%s",0)'
                         % (st["name"], st["name"], st["mcc"], st["mnc"]))
                self.ok(); return
            if ub.endswith("?"):
                if self.cops_format == 2:
                    self.out('+COPS: 0,2,"%s%s",0' % (st["mcc"], st["mnc"]))
                else:
                    self.out('+COPS: 0,%d,"%s",0' % (self.cops_format, st["name"]))
                self.ok(); return
            m = re.match(r'\+COPS=3,(\d)', ub)
            if m:
                self.cops_format = int(m.group(1))
            self.ok(); return

        if ub.startswith("+CSQ"):
            # Banc en marche = signal franc ; banc arrete = pas de signal.
            self.out("+CSQ: %d,99" % (24 if st["up"] else 99))
            self.ok(); return

        # ── CE QU oFONO DEMANDE A L INITIALISATION ──────────────────────
        # [2026-09-06] Releve sur le banc : des qu on passe Powered=true, oFono
        # deroule tout l inventaire d un vrai modem - jeux de caracteres,
        # services SMS, et surtout une longue serie d AT+CRSM (la lecture des
        # fichiers de la carte SIM). Repondre ERROR a tout ca fait abandonner
        # oFono ; on repond donc comme un modem dont la SIM n a pas ces
        # fichiers, ce qui est LA VERITE ici : il n y a pas de carte, l identite
        # vient du banc (AT+CIMI) et non d une SIM physique.
        if ub == "+CSCS=?":
            self.out('+CSCS: ("IRA","GSM","UCS2")'); self.ok(); return
        if ub.startswith("+CSMS"):
            # 1,1,1 : SMS emis, recus et diffuses pris en charge.
            self.out("+CSMS: 1,1,1"); self.ok(); return
        if ub.startswith("+CSIM"):
            # [2026-09-07] REFUSER FRANCHEMENT L ACCES APDU. ModemManager sonde
            # la carte avec AT+CSIM (des commandes APDU brutes : selection de
            # fichiers, lecture de l IMSI...). Repondre « OK » sans donnee le
            # laisse attendre une reponse qui ne vient jamais et il n enregistre
            # aucun modem. En annoncant que la commande n est pas geree, il se
            # rabat sur les commandes ordinaires (+CIMI, +CPIN?), auxquelles on
            # sait repondre - il n y a pas de vraie carte ici, l identite vient
            # du banc.
            self.err(4)          # 4 = operation non supportee
            return
        if ub.startswith("+CRSM"):
            # 148,4 = SW1 0x94 / SW2 0x04, « fichier introuvable » : la reponse
            # normale d une SIM qui ne porte pas le fichier demande.
            self.out("+CRSM: 148,4"); self.ok(); return
        # Les lectures dont oFono a besoin pour monter MessageManager et la
        # data : refusees, elles laissaient ces interfaces absentes.
        # [2026-09-06] LA COMMANDE QUI DECIDE DE TOUT : AT+GCAP. C est par elle
        # qu oFono demande au modem ce qu il sait faire ; sans « +CGSM » dans la
        # reponse, il n active pas la couche reseau et n envoie meme JAMAIS
        # AT+CREG - l interface NetworkRegistration reste alors absente, ce
        # qu on a observe tel quel sur le banc (aucun CREG dans le journal).
        if ub in ("+GCAP", "+CGCAP"):
            self.out("+GCAP: +CGSM,+FCLASS,+DS,+ES"); self.ok(); return

        # ── LA BOITE DE RECEPTION, VUE EN AT ────────────────────────────
        # [2026-09-07] LA FORME TEST D ABORD. « AT+CMGF=? » commence par
        # « +CMGF= » : le prefixe ci-dessous l attrapait, repondait OK tout nu
        # et laissait la vraie reponse (plus bas dans cette fonction) en code
        # mort - releve dans la trace AT, « < AT+CMGF=? » suivi d un « > OK ».
        # Meme piege pour AT+CNMI=?, qui en prime remettait cnmi_mt a 2.
        if ub == "+CMGF=?":
            self.out("+CMGF: (0,1)"); self.ok(); return
        if ub == "+CNMI=?":
            self.out("+CNMI: (0-2),(0-3),(0,2),(0,1),(0,1)"); self.ok(); return
        if ub.startswith("+CMGF="):
            # Retenir le mode : CMGR et CMGL ne repondent pas pareil en texte
            # et en PDU, et repondre dans le mauvais mode fait jeter le message.
            self.cmgf = 1 if ub[6:].strip().startswith("1") else 0
            self.ok(); return
        if ub == "+CMGF?":
            self.out("+CMGF: %d" % self.cmgf); self.ok(); return

        if ub.startswith("+CNMI="):
            # LA COMMANDE QUI DECIDE DE TOUT POUR LES ENTRANTS. Le deuxieme
            # champ (mt) dit si le systeme veut le message pousse (2) ou
            # seulement son index (1). ModemManager demande 1.
            champs = ub[6:].split(",")
            try:
                self.cnmi_mt = int(champs[1]) if len(champs) > 1 else 2
            except ValueError:
                self.cnmi_mt = 2
            log("annonce des SMS entrants : mt=%d (%s)"
                % (self.cnmi_mt,
                   "+CMT direct" if self.cnmi_mt == 2 else "+CMTI puis CMGR"))
            self.ok(); return
        if ub == "+CNMI?":
            self.out("+CNMI: 2,%d,2,1,0" % self.cnmi_mt); self.ok(); return

        if ub.startswith("+CNMA"):
            # L accuse de reception d un « +CMT: ». Rien a faire : le message
            # est deja parti du banc. Mais il FAUT repondre OK, sinon le
            # systeme croit la remise ratee et coupe l annonce directe.
            self.ok(); return

        if ub.startswith("+CMGR="):
            try:
                idx = int(re.sub(r"\D", "", ub[6:]) or "0")
            except ValueError:
                self.err(); return
            m = inbox_get(idx)
            if m is None:
                self.err(321)            # 321 = index de memoire invalide
                return
            self.out(self._sms_ligne(m, "+CMGR: "))
            m["lu"] = True
            self.ok(); return

        if ub.startswith("+CMGL"):
            if ub.endswith("=?"):
                self.out('+CMGL: (0,1,2,3,4)' if not self.cmgf else
                         '+CMGL: ("REC UNREAD","REC READ","ALL")')
                self.ok(); return
            arg = ub[6:].strip().strip('"').upper() if "=" in ub else "4"
            # 0 / « REC UNREAD » : seulement les non lus. Tout le reste : tout.
            que_non_lus = arg in ("0", "REC UNREAD")
            with INBOX_LOCK:
                liste = [m for m in INBOX if not (que_non_lus and m["lu"])]
            for m in liste:
                self.out(self._sms_ligne(m, "+CMGL: %d," % m["idx"]))
            for m in liste:
                m["lu"] = True
            self.ok(); return

        if ub.startswith("+CMGD"):
            if ub.endswith("=?"):
                with INBOX_LOCK:
                    idxs = ",".join(str(m["idx"]) for m in INBOX)
                self.out("+CMGD: (%s),(0-4)" % idxs); self.ok(); return
            champs = ub[6:].split(",")
            try:
                idx = int(re.sub(r"\D", "", champs[0]) or "0")
            except ValueError:
                self.err(); return
            drapeau = champs[1].strip() if len(champs) > 1 else "0"
            with INBOX_LOCK:
                if drapeau in ("1", "2", "3", "4"):
                    INBOX[:] = []            # « efface tout », selon le drapeau
                else:
                    INBOX[:] = [m for m in INBOX if m["idx"] != idx]
            self.ok(); return

        if ub == "+CSCS?":
            self.out('+CSCS: "IRA"'); self.ok(); return
        if ub.startswith("+CPMS"):
            # Trois memoires SMS : on n en tient aucune (les SMS passent par le
            # banc), on annonce donc des boites vides mais existantes.
            # Le compte doit etre VRAI : un systeme qui lit « 0 message »
            # ne va pas chercher ce qu on vient de ranger.
            with INBOX_LOCK:
                n = len(INBOX)
            if ub.endswith("=?"):
                self.out('+CPMS: ("SM"),("SM"),("SM")')
            elif ub.startswith("+CPMS="):
                self.out('+CPMS: %d,%d,%d,%d,%d,%d'
                         % (n, INBOX_MAX, n, INBOX_MAX, n, INBOX_MAX))
            else:
                self.out('+CPMS: "SM",%d,%d,"SM",%d,%d,"SM",%d,%d'
                         % (n, INBOX_MAX, n, INBOX_MAX, n, INBOX_MAX))
            self.ok(); return
        if ub == "+CSMS?":
            self.out("+CSMS: 0,1,1,1"); self.ok(); return
        if ub == "+CGDCONT=?":
            self.out('+CGDCONT: (1-4),"IP",,,(0-2),(0-4)'); self.ok(); return
        if ub in ("+CMUT?", "+CMUT=?"):
            self.out("+CMUT: 0"); self.ok(); return
        if ub in ("+CLVL?", "+CLVL=?"):
            self.out("+CLVL: 5" if ub.endswith("?") and "=" not in ub else "+CLVL: (0-9)")
            self.ok(); return

        if ub in ("+CPINR", "+CUAD") or ub.startswith(("+PTTY", "+VTD", "+CCWA",
                                                       "+CIND", "+CMER", "+CPBS",
                                                       "+CSCB", "+CGATT", "+CPMS")):
            self.ok(); return

        if ub == "+CLCC=?":
            # [2026-09-07] LA COMMANDE QUI DECIDE DU RACCROCHAGE. Releve dans
            # la trace AT de la VM : ModemManager n envoie JAMAIS AT+CLCC. Il
            # commence par demander AT+CLCC=? et, sur ERROR, conclut que ce
            # modem ne sait pas rendre sa liste d appels - il coupe alors la
            # relecture periodique et ne lui reste plus rien pour apprendre
            # qu un appel s est termine. Quand le correspondant raccrochait,
            # l ecran d appel restait donc affiche. Un vrai modem repond OK.
            self.ok(); return

        if ub == "+CLCC":
            for i, c in enumerate(self.calls, start=1):
                # 27.007 : idx, direction, etat, mode, multipartie, numero,
                # type. Direction 0 = sortant, 1 = entrant. Etat 0 = actif,
                # 2 = en cours d appel, 4 = entrant qui sonne.
                sens = 1 if c["state"] == "incoming" else 0
                etat = {"active": 0, "incoming": 4}.get(c["state"], 2)
                self.out('+CLCC: %d,%d,%d,0,0,"%s",129'
                         % (i, sens, etat, c["num"]))
            self.ok(); return

        if ub.startswith("+CMGS="):
            # Deux formes : mode texte (le numero entre guillemets, pour un
            # essai a la main) et mode PDU (une longueur - c est ce qu envoie
            # oFono). Dans les deux cas la suite arrive apres l invite « > ».
            m = re.search(r'"([^"]+)"', body)
            self.sms_target = m.group(1) if m else "<pdu>"
            try:
                self.wfile.write(b"\r\n> ")
                self.wfile.flush()
            except OSError:
                pass
            return

        if ub == "A":
            # [2026-09-07] DECROCHER. L appel va DEJA vers l abonne du banc -
            # la VM et le mobile sont le meme 100101, comme pour les SMS. On ne
            # peut donc pas « prendre » la ligne : on note que l appel est en
            # cours, et la voix arrive par le pont audio (gsm_audio), que la VM
            # relaie deja.
            for c in self.calls:
                if c["state"] == "incoming":
                    c["state"] = "active"
                    log("appel de %s decroche" % (c["num"] or "inconnu"))
                    threading.Thread(target=mobile_decroche, daemon=True).start()
                    self.ok(); return
            self.err(); return

        if cmd.startswith("ATD"):
            num = re.sub(r"[^0-9+*#]", "", body.split(";")[0][1:])
            if not num:
                self.err(); return
            ok, detail = ami_originate(num)
            if not ok:
                log("appel vers %s refuse : %s" % (num, detail))
                self.err(); return
            log("appel vers %s etabli par Asterisk" % num)
            self.calls.append({"num": num, "state": "active", "channel": detail})
            threading.Thread(target=mobile_decroche, daemon=True).start()
            self.ok()
            return

        if ub == "+CHLD=?":
            # 0 rejeter/liberer, 1 liberer les actifs, 1x liberer l appel x.
            self.out('+CHLD: (0,1,1x)'); self.ok(); return

        if ub in ("H", "+CHUP") or ub.startswith("+CHLD="):
            # [2026-09-07] ET C EST +CHLD QUI RACCROCHE, PAS ATH.
            # Trace de la VM postmarketOS (/tmp/osmo-at-ofono-*.log) :
            #     06:53:04.174 < AT+CHLD=11      ModemManager raccroche
            #     06:53:04.207 > RING            ... et on sonnait toujours
            #     06:53:04.824 < AT+CHUP         il en fallait une SECONDE
            # +CHLD n etait traite nulle part ici (osmo-ril-atmodem.py, lui,
            # l a toujours reconnu). Il tombait donc dans la regle generale
            # « toute AFFECTATION est acceptee sans effet » : on repondait OK -
            # ModemManager croyait avoir raccroche - et l appel continuait de
            # sonner jusqu au +CHUP suivant. D ou le double raccrochage.
            # 27.007 § 7.13 : 0 = rejeter l entrant, 1 = liberer les actifs,
            # 1x = liberer l appel x. Sans mise en attente sur ce banc, les
            # trois reviennent au meme - on raccroche.
            #
            # IL FALLAIT RACCROCHER DEUX FOIS DEPUIS pmOS (suite).
            # On vidait self.calls ici meme : quand Asterisk demolissait
            # ensuite le canal pour de bon, fin_appel() ne trouvait plus rien a
            # retirer et n emettait donc JAMAIS le « NO CARRIER ». Cote VM,
            # ModemManager n apprenait pas la fin de l appel - l ecran d appel
            # restait, et il fallait un second ATH (que le premier avait deja
            # rendu sans objet) pour que l interface se resigne.
            # C est nous qui raccrochons : c est donc a nous de l annoncer,
            # tout de suite, une fois par appel. fin_appel() reste en place
            # pour l autre sens (le correspondant raccroche le premier) et ne
            # fera pas doublon : la liste est vide quand son evenement arrive.
            for c in self.calls:
                ami_hangup(c.get("channel", ""))
            n = len(self.calls)
            self.calls.clear()
            mobile("hangup")            # l abonne, c est le mobile : lui aussi
            for _ in range(n):
                self.out("NO CARRIER")
            self.ok(); return

        if ub == "+CBC":
            self.out("+CBC: 0,80"); self.ok(); return       # alimente, 80 %
        if ub == "+CLCK=?":
            self.out('+CLCK: ("SC","AO","OI","AI")'); self.ok(); return

        # [2026-09-06] LA REGLE GENERALE, ET POURQUOI ELLE EST SURE. oFono
        # deroule a l initialisation une trentaine de REGLAGES (AT+CRC=1,
        # AT+CNAP=1, AT+CDIP=1, AT+CSCS="GSM"...) dont il ne lit jamais la
        # reponse au-dela du OK : refuser ceux-la faisait abandonner
        # l initialisation entiere. On accepte donc tout ce qui est une
        # AFFECTATION - un modem qui accepte un reglage qu il n applique pas ne
        # ment a personne, il n a rien a rapporter dessus. En revanche une
        # LECTURE inconnue (AT+XXX? ou AT+XXX=?) reste refusee : la, une reponse
        # inventee ferait croire a oFono a une capacite qui n existe pas.
        if "=" in ub and not ub.endswith("=?"):
            log("reglage accepte sans effet : %s" % line)
            self.ok(); return

        log("lecture non geree (refusee) : %s" % line)
        self.err()


# ── LA RECEPTION DES SMS : ESME SMPP SUR osmo-msc ───────────────────────────
# Emettre un SMS se fait par le VTY (« subscriber ... sms ... send »), mais
# RECEVOIR demande que le MSC nous pousse quelque chose : le VTY ne notifie
# rien. osmo-msc expose pour cela un serveur SMPP (port 2775) auquel on se
# connecte comme ESME. Chaque SMS route vers nous arrive en deliver_sm, et on
# le presente au modem sous la forme que le monde AT attend : « +CMT: » avec le
# message en PDU, precede de l URC.
#
# Le protocole est binaire mais on n en utilise qu une poignee de messages :
# bind_transceiver, enquire_link (le battement de coeur), deliver_sm et sa
# reponse. Pas de bibliotheque : ce serait une dependance de plus sur l image
# pour trois structures.
SMPP_BIND_TRANSCEIVER = 0x00000009
SMPP_BIND_TRANSCEIVER_RESP = 0x80000009
SMPP_DELIVER_SM = 0x00000005
SMPP_DELIVER_SM_RESP = 0x80000005
SMPP_ENQUIRE_LINK = 0x00000015
SMPP_ENQUIRE_LINK_RESP = 0x80000015


def _cstr(b, i):
    """Une chaine terminee par zero, et l indice juste apres."""
    j = b.index(b"\x00", i)
    return b[i:j].decode(errors="replace"), j + 1


def gsm7_pack(text):
    """L alphabet GSM 7 bits, tasse par paquets de sept octets pour huit
    caracteres - l encodage par defaut d un SMS."""
    # [2026-09-06] Le miroir EXACT de gsm7_unpack : on empile les septets dans
    # un tampon de bits et on sort un octet des qu il y en a huit. La premiere
    # version decalait a l envers et produisait un texte illisible - verifie en
    # relisant son propre resultat, qui ne redonnait pas le message d origine.
    septets = [ord(c) & 0x7F for c in text]
    out = bytearray()
    cur = bits = 0
    for sep in septets:
        cur |= sep << bits
        bits += 7
        while bits >= 8:
            out.append(cur & 0xFF)
            cur >>= 8
            bits -= 8
    if bits:
        out.append(cur & 0xFF)
    return bytes(out), len(septets)


# ── LA BOITE DE RECEPTION ───────────────────────────────────────────────────
# [2026-09-07] POURQUOI IL FAUT STOCKER LES SMS. Le modem ne decide pas seul
# comment il annonce un SMS entrant : c est le systeme qui le lui dit par
# AT+CNMI=<mode>,<mt>,... Deux mondes s y opposent :
#   mt=2 : « pousse-moi le message tout de suite »   -> URC « +CMT: » + le PDU
#   mt=1 : « range-le et dis-moi seulement ou »      -> URC « +CMTI: "SM",<i> »
#          puis le systeme vient le lire par AT+CMGR=<i>.
# ModemManager, celui de la VM postmarketOS, negocie mt=1 - releve tel quel
# dans le journal : « AT+CNMI=2,1,2,1,0 ». Il liste meme la boite au demarrage
# par AT+CMGL=4. Or ce programme n emettait QUE « +CMT: » et ne tenait aucune
# boite : les SMS entrants partaient donc dans le vide, et rien n arrivait dans
# la VM. D ou ce magasin, et les commandes qui vont avec (CMGR, CMGL, CMGD).
INBOX = []                     # [{idx, pdu, sender, text, lu, ts}]
INBOX_LOCK = threading.Lock()
INBOX_MAX = 20                 # ce que +CPMS annonce comme capacite


def inbox_ranger(sender, text, pdu):
    """Range un SMS et rend son index, comme une memoire « SM »."""
    with INBOX_LOCK:
        libres = [i for i in range(1, INBOX_MAX + 1)
                  if all(m["idx"] != i for m in INBOX)]
        if not libres:
            INBOX.pop(0)       # boite pleine : le plus ancien cede la place
            libres = [i for i in range(1, INBOX_MAX + 1)
                      if all(m["idx"] != i for m in INBOX)]
        idx = libres[0]
        INBOX.append({"idx": idx, "pdu": pdu, "sender": sender, "text": text,
                      "lu": False, "ts": time.strftime("%y/%m/%d,%H:%M:%S+08")})
        INBOX.sort(key=lambda m: m["idx"])
    return idx


def inbox_get(idx):
    with INBOX_LOCK:
        for m in INBOX:
            if m["idx"] == idx:
                return m
    return None


def semi_octets(num):
    """Un numero en demi-octets inverses, comme dans un PDU."""
    digits = re.sub(r"\D", "", num)
    if len(digits) % 2:
        digits += "F"
    return bytes(int(digits[i + 1] + digits[i], 16) for i in range(0, len(digits), 2))


def scts_maintenant():
    """L horodatage d un SMS-DELIVER (23.040 § 9.2.3.11) : six paires de
    chiffres en demi-octets inverses, puis le fuseau en quarts d heure.

    [2026-09-07] POURQUOI PAS DES ZEROS. pdu_deliver posait « bytes(7) », soit
    an 00 / mois 00 / jour 00 : une date qui n existe pas. ModemManager la
    transmet telle quelle et Chatty peut jeter le message en la lisant. Un
    modem donne l heure du reseau ; on donne celle du banc, qui est la meme.
    """
    t = time.localtime()
    out = bytearray(int(("%02d" % v)[::-1], 16) for v in
                    (t.tm_year % 100, t.tm_mon, t.tm_mday,
                     t.tm_hour, t.tm_min, t.tm_sec))
    quarts = -(time.altzone if t.tm_isdst else time.timezone) // 900
    octet = int(("%02d" % abs(quarts))[::-1], 16)
    if quarts < 0:
        octet |= 0x08                  # le signe, bit 3 du premier demi-octet
    out.append(octet)
    return bytes(out)


def pdu_deliver(sender, text):
    """Un SMS-DELIVER complet, tel qu un modem le rend sur « +CMT: »."""
    digits = re.sub(r"\D", "", sender)
    oa = bytes([len(digits), 0x81]) + semi_octets(sender)   # 0x81 : numero national
    ud, n = gsm7_pack(text)
    scts = scts_maintenant()
    pdu = b"\x00" + b"\x04" + oa + b"\x00\x00" + scts + bytes([n]) + ud
    return pdu.hex().upper()


def gsm7_unpack(data, n):
    """L inverse de gsm7_pack : les septets tasses redeviennent des caracteres."""
    out, cur, bits = [], 0, 0
    for b in data:
        cur |= b << bits
        bits += 8
        while bits >= 7 and len(out) < n:
            out.append(chr(cur & 0x7F))
            cur >>= 7
            bits -= 7
    return "".join(out)


def parse_submit(pdu_hex):
    """Lit un SMS-SUBMIT et rend (numero, texte).

    [2026-09-06] POURQUOI IL FAUT DECODER ICI. oFono n envoie PAS les SMS en
    mode texte : il envoie « AT+CMGS=<longueur> » puis un PDU. La premiere
    version cherchait un numero entre guillemets et refusait donc tout ce qui
    venait d oFono - c est-a-dire tout ce qui vient d Android.
    """
    b = bytes.fromhex(pdu_hex)
    i = 0
    i += 1 + b[0]                      # longueur du SMSC, puis on le saute
    first = b[i]; i += 1               # octet de type
    i += 1                             # reference du message
    ndigits = b[i]; i += 1
    i += 1                             # type d adresse
    nbytes = (ndigits + 1) // 2
    num = ""
    for octet in b[i:i + nbytes]:
        num += "%d%d" % (octet & 0x0F, octet >> 4)
    num = num[:ndigits]
    i += nbytes
    i += 1                             # protocole
    dcs = b[i]; i += 1
    if first & 0x10:                   # periode de validite presente
        i += 1
    udl = b[i]; i += 1
    ud = b[i:]
    if dcs & 0x0C == 0x08:             # UCS2
        text = ud[:udl].decode("utf-16-be", errors="replace")
    else:
        text = gsm7_unpack(ud, udl)
    return num, text


class Smpp(threading.Thread):
    """L ESME : se lie au MSC, tient la liaison, et remet les SMS au modem."""

    daemon = True

    def __init__(self, deliver_cb):
        super().__init__(name="smpp")
        self.deliver = deliver_cb
        self.seq = 0
        self.s = None

    def _pack(self, cmd_id, body=b"", status=0):
        self.seq += 1
        return (len(body) + 16).to_bytes(4, "big") + cmd_id.to_bytes(4, "big") + \
            status.to_bytes(4, "big") + self.seq.to_bytes(4, "big") + body

    def _bind(self):
        body = (SMPP_ID.encode() + b"\x00" + SMPP_PW.encode() + b"\x00" +
                b"osmo\x00" + b"\x34" + b"\x00\x00" + b"\x00")
        self.s.sendall(self._pack(SMPP_BIND_TRANSCEIVER, body))
        head = self._recv(16)
        if not head:
            return False
        ln = int.from_bytes(head[:4], "big")
        cmd = int.from_bytes(head[4:8], "big")
        status = int.from_bytes(head[8:12], "big")
        self._recv(ln - 16)
        if cmd == SMPP_BIND_TRANSCEIVER_RESP and status == 0:
            log("SMPP : lie a osmo-msc comme « %s »" % SMPP_ID)
            return True
        log("SMPP : liaison refusee (statut %d)" % status)
        return False

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            try:
                chunk = self.s.recv(n - len(buf))
            except OSError:
                return None
            if not chunk:
                return None
            buf += chunk
        return buf

    def run(self):
        while True:
            try:
                self.s = socket.create_connection((SMPP_HOST, SMPP_PORT), timeout=5)
                self.s.settimeout(None)
                if not self._bind():
                    self.s.close()
                    time.sleep(5)
                    continue
                self._loop()
            except OSError as e:
                log("SMPP : %s" % e)
            finally:
                try:
                    if self.s:
                        self.s.close()
                except OSError:
                    pass
            time.sleep(5)          # le MSC redemarre, on repasse le voir

    def _loop(self):
        while True:
            head = self._recv(16)
            if not head:
                return
            ln = int.from_bytes(head[:4], "big")
            cmd = int.from_bytes(head[4:8], "big")
            seq = head[12:16]
            body = self._recv(ln - 16) if ln > 16 else b""
            if body is None:
                return
            if cmd == SMPP_ENQUIRE_LINK:
                self.s.sendall(b"\x00\x00\x00\x10" +
                               SMPP_ENQUIRE_LINK_RESP.to_bytes(4, "big") +
                               b"\x00\x00\x00\x00" + seq)
            elif cmd == SMPP_DELIVER_SM:
                try:
                    self._on_deliver(body)
                except (ValueError, IndexError) as e:
                    log("SMPP : deliver_sm illisible (%s)" % e)
                self.s.sendall(b"\x00\x00\x00\x11" +
                               SMPP_DELIVER_SM_RESP.to_bytes(4, "big") +
                               b"\x00\x00\x00\x00" + seq + b"\x00")

    def _on_deliver(self, b):
        i = 0
        _svc, i = _cstr(b, i)
        i += 2                                    # ton et npi de la source
        src, i = _cstr(b, i)
        i += 2                                    # ton et npi du destinataire
        dst, i = _cstr(b, i)
        i += 3                                    # esm_class, protocole, priorite
        _sched, i = _cstr(b, i)
        _valid, i = _cstr(b, i)
        i += 3                                    # registered, replace, coding
        i += 1                                    # sm_default_msg_id
        ln = b[i]; i += 1
        text = b[i:i + ln].decode("latin-1", errors="replace")
        log("SMS entrant de %s pour %s : %s" % (src, dst, text))
        self.deliver(src, text)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


CURRENT = None                 # le modem actuellement ouvert par oFono


def on_smpp_sms(sender, text):
    """Un SMS arrive du banc. Deux destinataires, pas un :

    [2026-09-06] LE TELEPHONE ANDROID EST LE MEME ABONNE QUE LE MOBILE. Le banc
    n a qu un 100101, et on veut qu il sonne des DEUX cotes - dans Android par
    le RIL, et sur le mobile osmocom-bb comme avant. Or « smpp-first » detourne
    le SMS vers nous AVANT la livraison interne : le mobile ne verrait plus
    rien. On le lui remet donc nous-memes, par la commande VTY du MSC, qui elle
    livre directement au mobile sans repasser par SMPP - pas de boucle
    possible. OSMO_SMS_DUPLIQUE=0 pour n en garder qu un (Android seul).
    """
    if CURRENT is not None:
        CURRENT.deliver_sms(sender, text)
    else:
        log("oFono n est pas connecte : rien a remettre a Android")
    if DUPLIQUE:
        out = MSC.cmd("subscriber msisdn %s sms sender msisdn %s send %s"
                      % (MSISDN, sender, text))
        if out is None:
            log("copie au mobile impossible : osmo-msc injoignable")
        else:
            log("copie remise au mobile %s" % MSISDN)


# ── LA BOITE D ENTREE : LES SMS QUE LA PASSERELLE NOUS REMET ────────────────
# [2026-09-07] POURQUOI UNE SECONDE VOIE, A COTE DU SMPP. Le banc tourne avec
# « sms-over-gsup » (osmo-msc.cfg). Dans ce mode, un SM-RP recu de la radio
# part au HLR en gsm_04_11.c:742 SANS jamais passer par gsm340_rx_tpdu() :
# sms_route_mt_sms() n est pas appele, donc smpp_try_deliver() non plus. Le
# « smpp-first » et les quatre « route prefix ... 100101 » de la conf sont donc
# de la configuration morte tant que sms-over-gsup est la - l ESME ci-dessus
# est bien LIE au port 2775, et il ne recoit RIEN. Et le MT qui revient par
# GSUP est pousse directement a l abonne par la voie radio : le mobile
# osmocom-bb l a (on le lit dans mobile.log), les modems logiciels non.
#
# La passerelle previent donc les modems la ou elle decide la remise locale
# (scripts/sms-interop-relay.py, inject_mt_sms), par scripts/sms_notify.py.
# On ne duplique RIEN ici, contrairement a la voie SMPP : le mobile a deja son
# exemplaire par la radio, le lui renvoyer le ferait sonner deux fois.
class SmsInHandler(socketserver.StreamRequestHandler):
    """Une ligne JSON : {"imsi": ..., "from": ..., "text": ...}."""

    def handle(self):
        try:
            ligne = self.rfile.readline(65536)
        except OSError:
            return
        try:
            msg = json.loads(ligne.decode("utf-8", errors="replace"))
        except ValueError as e:
            log("passerelle : message illisible (%s)" % e)
            return
        imsi = str(msg.get("imsi") or "")
        if imsi and imsi != IMSI:
            return                       # ce SMS-la est pour un autre abonne
        on_passerelle_sms(str(msg.get("from") or ""), str(msg.get("text") or ""))
        try:
            self.wfile.write(b'{"ok":true}\n')
        except OSError:
            pass


def on_passerelle_sms(sender, text):
    """Aucun systeme au bout du fil ? On range quand meme : la VM peut etre en
    train de demarrer, et ModemManager liste la boite par AT+CMGL=4 des qu il
    se branche. Un SMS n a pas a se perdre parce que le modem etait absent."""
    if CURRENT is not None:
        CURRENT.deliver_sms(sender, text)
        return
    idx = inbox_ranger(sender, text, pdu_deliver(sender, text))
    log("SMS de la passerelle range en SM[%d], personne au bout du fil : %s"
        % (idx, text))


def boite_entree(port):
    """Ouvre la boite. Port deja pris = c est l autre instance du modem qui l
    a : on le dit et on continue, tout le reste du modem marche sans."""
    try:
        srv = Server((SMS_IN_HOST, port), SmsInHandler)
    except OSError as e:
        log("boite d entree SMS sur %d impossible (%s)" % (port, e))
        return
    log("boite d entree SMS sur %s:%d" % (SMS_IN_HOST, port))
    threading.Thread(target=srv.serve_forever, daemon=True).start()


class ClientHandler(AtHandler):
    """Le meme modem, mais c est NOUS qui allons vers le port.

    [2026-09-07] POURQUOI CE MODE. Quand le modem est branche sur un port serie
    de machine virtuelle, le firmware UEFI de la VM traite ce port comme une
    console : il lit les reponses du modem comme des touches pressees, croit
    qu on interrompt le demarrage et ouvre son menu - la VM ne demarre jamais.
    Le remede est qu il n y ait PERSONNE au bout du fil tant que le firmware
    travaille : QEMU ecoute (server=on,wait=off), et on vient s y connecter
    une fois le systeme charge.
    """

    def __init__(self, sock, addr):
        # StreamRequestHandler.setup() attend self.request et fabrique lui-meme
        # connection/rfile/wfile : on lui donne juste la douille.
        self.request = sock
        self.client_address = addr
        self.server = None
        self.setup()
        try:
            self.handle()
        finally:
            self.finish()


def vm_prete(port):
    """Le systeme de la VM repond-il ? On se sert d un port temoin (le SSH de
    la machine virtuelle, 2222 par defaut).

    [2026-09-07] POURQUOI ATTENDRE. Le firmware UEFI de la VM lit tout port
    serie comme une console : si le modem se branche pendant qu il travaille,
    ses reponses passent pour des touches et le demarrage s arrete sur le menu.
    Le mode --connect rebouclant toutes les cinq secondes, il retombait dedans
    a chaque redemarrage de la VM. On ne se branche donc QUE lorsque le systeme
    est leve.
    """
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.close()
        return True
    except OSError:
        return False


def connect_to(dest):
    """dest = « hote:port » : on se connecte et on tient le modem sur ce lien."""
    host, _, port = dest.rpartition(":")
    temoin = int(os.environ.get("OSMO_VM_READY_PORT", "2222"))
    while True:
        if temoin and not vm_prete(temoin):
            log("la VM n est pas prete (port %d ferme) - on patiente" % temoin)
            while not vm_prete(temoin):
                time.sleep(5)
            log("VM prete")
        try:
            s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=10)
        except OSError as e:
            log("connexion a %s impossible (%s) - nouvel essai dans 5 s" % (dest, e))
            time.sleep(5)
            continue
        # [2026-09-07] LE DELAI SERT A SE CONNECTER, PAS A TENIR LE LIEN.
        # create_connection(timeout=10) laisse ce delai SUR la douille : la
        # lecture suivante levait socket.timeout apres dix secondes de silence,
        # handle() rendait la main et le modem se debranchait tout seul. Or un
        # modem se tait la plupart du temps - ModemManager ne l interroge que
        # par a-coups. D ou des appels qui marchent puis disparaissent, et la
        # ronde « oFono s est deconnecte / lien ferme » dans ce journal. On
        # repasse donc en bloquant, comme le lien SMPP plus haut.
        s.settimeout(None)
        log("connecte a %s" % dest)
        try:
            ClientHandler(s, (host, int(port)))
        except OSError as e:
            log("lien rompu : %s" % e)
        finally:
            try:
                s.close()
            except OSError:
                pass
        log("lien ferme, on repasse dans 5 s")
        time.sleep(5)


def main():
    if SMPP_ON:
        Smpp(on_smpp_sms).start()
    AmiEcoute().start()
    for i, a in enumerate(sys.argv):
        if a == "--connect" and i + 1 < len(sys.argv):
            boite_entree(SMS_IN_CONNECT)
            return connect_to(sys.argv[i + 1])
    boite_entree(SMS_IN_LISTEN)
    srv = Server((HOST, PORT), AtHandler)
    log("modem du banc en ecoute sur %s:%d" % (HOST, PORT))
    log("declarer dans /etc/ofono/phonesim.conf :")
    log("  [osmo]")
    log("  Address=%s" % HOST)
    log("  Port=%d" % PORT)
    log("puis : systemctl restart ofono")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
