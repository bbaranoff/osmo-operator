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
    # [2026-09-08] ON ATTEND QUE LA JAMBE ARRIVE AVANT DE DECROCHER. Tenter
    # « call 1 answer » toutes les demi-secondes pendant que la jambe est
    # encore en paging faisait ecrire « % No alerting call » une dizaine de
    # fois sur TOUS les VTY du mobile - dont celui de l utilisateur. Le mobile
    # dit ou il en est dans « show ms » : tant que sa couche RR est « idle »,
    # rien n est encore arrive, on se tait.
    if action == "answer":
        for _ in range(essais * 2):
            out = MOB.cmd("show ms %s" % MS) or ""
            if "radio resource layer state: idle" not in out:
                break
            time.sleep(0.5)
        # Entre la reponse au paging et la sonnerie il reste une a trois
        # secondes : on garde toutes les tentatives (essais), pas quatre -
        # avec quatre, le mobile ne decrochait plus et la voix disparaissait.
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
            # « ARFCNs: 514 » sur ce banc (le « s » et les deux-points
            # comptaient : « ARFCN\s+ » ne trouvait rien).
            m = re.search(r'ARFCNs?:?\s+(\d+)', txt)
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


# ── LA 4G : srsRAN SUR LA RADIO VIRTUELLE ZEROMQ ────────────────────────────
# [2026-09-07] LE TELEPHONE EST SUR LA 4G, ET REDESCEND EN 2G POUR PARLER.
# Le banc a deux radios : la 2G d osmocom (osmo-bts-trx + le mobile
# osmocom-bb, qui EST l abonne 100101) et une 4G srsRAN sans materiel
# (srsENB <-> srsUE par ZeroMQ, ports 2000/2001, srsEPC derriere). L eNB
# annonce la 2G a ses UE par le SIB7 de sib.conf (la liste GERAN, mappee dans
# le SIB1 par si_mapping_info = [7]) : c est le CSFB, « CS fallback » - un UE
# pose sur la LTE, qui n a pas de voix, redescend sur la GSM le temps d un
# appel ou d un SMS, puis remonte.
#
# Ce modem fait ce que ferait la puce d un vrai telephone devant ces deux
# reseaux : il campe sur la 4G tant qu elle est la (+CEREG enregistre, AcT 7,
# TAC/ECI de l eNB), et des qu un service CS commence - un ATD, un RING, un
# SMS dans un sens ou l autre - il annonce qu il est passe sur la 2G (URC
# +CREG avec LAC/CI de la BTS et AcT 0) ; le service fini, il remonte. Phosh
# affiche donc « 4G », puis « 2G » pendant l appel, puis « 4G ».
#
# LA VERITE DE LA 4G, ELLE, VIENT DU BANC, comme celle de la 2G vient du VTY
# d osmo-bsc :
#   - l eNB est la si le port ZeroMQ de srsENB (2000) ecoute ;
#   - l UE est ATTACHE si srsUE a monte son tun (tun_srsue) avec une adresse -
#     il le fait dans son propre espace reseau (--gw.netns=ue1), c est la
#     qu on regarde. Pas de droit d y regarder (pas root) : on s en tient a
#     l eNB. OSMO_LTE_TEMOIN=enb pour ne regarder QUE l eNB, meme en root.
# Les identites (MCC/MNC, TAC, ECI, APN, les ARFCN GERAN du SIB7) sont lues
# dans les fichiers srsRAN eux-memes (OSMO_SRSRAN_DIR, sinon ~/.config/srsran
# de root, sinon /etc/srsran) : ce que le modem raconte est ce que l eNB emet.
ZMQ_PORT = int(os.environ.get("OSMO_ZMQ_PORT", "2000"))
LTE_NETNS = os.environ.get("OSMO_LTE_NETNS", "ue1")
LTE_TUN = os.environ.get("OSMO_LTE_TUN", "tun_srsue")
LTE_TEMOIN = os.environ.get("OSMO_LTE_TEMOIN", "ue")          # ue | enb
LTE_ON = os.environ.get("OSMO_LTE", "1") == "1"
# Le nom sous lequel la 4G apparait au telephone. srsRAN n emet pas de nom de
# reseau ; on en donne un, distinct de celui de la 2G (« Osmocom », lu sur
# osmo-bsc), pour que la liste des reseaux montre bien DEUX entrees.
LTE_NAME = os.environ.get("OSMO_LTE_NAME", "Osmocom 4G")
# Le constructeur annonce a AT+CGMI : il decide du greffon ModemManager, donc
# de la facon de faire la data (voir la reponse a +CGMI et a +GTRNDIS).
VENDOR = os.environ.get("OSMO_MODEM_VENDOR", "Fibocom")


def _tcp_ecoute(port, host="127.0.0.1"):
    try:
        s = socket.create_connection((host, port), timeout=0.3)
        s.close()
        return True
    except OSError:
        return False


class Lte:
    """La 4G du banc : ce que srsRAN emet, et si notre UE y est."""

    def __init__(self):
        self.dir = self._repertoire()
        self.cfg = self._lire_conf()
        self._t = 0
        self._v = {}
        self._dernier = None
        self._geran_verifie = False

    @staticmethod
    def _repertoire():
        cands = [os.environ.get("OSMO_SRSRAN_DIR", ""), "/root/.config/srsran",
                 os.path.expanduser("~/.config/srsran"), "/etc/srsran"]
        for d in cands:
            if d and os.path.isfile(os.path.join(d, "enb.conf")):
                return d
        return None

    def _texte(self, nom):
        if not self.dir:
            return ""
        try:
            with open(os.path.join(self.dir, nom), errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    @staticmethod
    def _val(texte, cle, defaut):
        """« cle = valeur » (ini ou libconfig, 0x accepte), ou le defaut."""
        m = re.search(r'^\s*%s\s*=\s*"?([0-9A-Za-z_.]+)' % re.escape(cle), texte, re.M)
        if not m:
            return defaut
        v = m.group(1)
        if isinstance(defaut, int):
            try:
                return int(v, 0)
            except ValueError:
                return defaut
        return v

    def _lire_conf(self):
        enb, rr, epc, sib = (self._texte(n) for n in ("enb.conf", "rr.conf", "epc.conf", "sib.conf"))
        c = {"mcc": self._val(enb, "mcc", "001"), "mnc": self._val(enb, "mnc", "01"),
             "enb_id": self._val(enb, "enb_id", 0x19B),
             "earfcn": self._val(enb, "dl_earfcn", 3350),
             "tac": self._val(rr, "tac", self._val(epc, "tac", 7)),
             "cell_id": self._val(rr, "cell_id", 1),
             "apn": self._val(epc, "apn", "srsapn"),
             "geran": [], "sib7_annonce": False}
        # Le SIB7 : la liste GERAN que l eNB donne a ses UE pour le CSFB, et
        # le fait qu il soit bien programme dans le SIB1 (sinon il n est pas
        # emis, et un vrai UE ne saurait pas qu il y a une 2G a cote).
        m = re.search(r'sib7\s*=\s*\{(.*?)\n\}', sib, re.S)
        if m:
            bloc = m.group(1)
            # Le groupe GERAN du SIB7, c est start_arfcn PLUS la liste qui
            # suit (36.331, CarrierFreqsGERAN) : les deux sont annonces.
            deb = re.search(r'start_arfcn\s*=\s*(\d+)', bloc)
            if deb:
                c["geran"].append(int(deb.group(1)))
            lst = re.search(r'explicit_list_of_arfcns\s*=\s*\(([^)]*)\)', bloc)
            if lst:
                c["geran"] += [int(x) for x in re.findall(r'\d+', lst.group(1))]
        m = re.search(r'si_mapping_info\s*=\s*\[([^\]]*)\]', sib)
        c["sib7_annonce"] = bool(m and re.search(r'\b7\b', m.group(1)))
        return c

    def _ue_attache(self):
        """True/False si on a pu regarder le tun de srsUE, None sinon."""
        # Le tun est dans l espace reseau si srsue a ete lance avec
        # --gw.netns, sur l hote sinon (« srsue » tout court) : on regarde
        # les DEUX. True des qu on le voit ; None si on n a pu regarder nulle
        # part (pas root pour l espace, et pas de tun sur l hote).
        essais = []
        if LTE_NETNS:
            essais.append(["ip", "-n", LTE_NETNS, "-4", "-o", "addr", "show"])
        essais.append(["ip", "-4", "-o", "addr", "show"])
        vu_quelque_part = False
        ns_ferme = False
        for cmd in essais:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                continue
            if r.returncode != 0:
                # [2026-09-08] « ip -n ue1 » refuse sans root (Operation not
                # permitted) alors que l espace existe : le tun peut y etre
                # sans qu on le voie. Ne pas conclure « pas attache » sur la
                # seule vue de l hote.
                if "-n" in cmd and LTE_NETNS and os.path.exists("/run/netns/" + LTE_NETNS):
                    ns_ferme = True
                continue
            vu_quelque_part = True
            if re.search(r'\b%s\b.*\binet\b' % re.escape(LTE_TUN), r.stdout):
                return True
        if ns_ferme:
            # Sans root, on regarde par les fils de srsue : le fil GW a fait
            # setns() dans l espace, et /proc/<pid>/task/<tid>/net/ se lit
            # par tout le monde. fib_trie y liste les adresses locales : le
            # tun y est avec son adresse des que l attach a abouti.
            vu = self._ue_attache_par_proc()
            if vu is not None:
                return vu
            return None
        return False if vu_quelque_part else None

    def _ue_attache_par_proc(self):
        """True/False d apres /proc/<pid srsue>/task/*/net, None si pas de
        srsue ou rien de lisible."""
        try:
            r = subprocess.run(["pgrep", "-x", "srsue"], capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            return None
        pids = r.stdout.split()
        if not pids:
            return False
        lu = False
        for pid in pids:
            try:
                tids = os.listdir("/proc/%s/task" % pid)
            except OSError:
                continue
            for tid in tids:
                base = "/proc/%s/task/%s/net/" % (pid, tid)
                try:
                    with open(base + "dev") as f:
                        dev = f.read()
                except OSError:
                    continue
                lu = True
                if LTE_TUN + ":" not in dev:
                    continue
                try:
                    with open(base + "fib_trie") as f:
                        trie = f.read()
                except OSError:
                    continue
                # Une adresse LOCAL autre que 127.x dans l espace du tun :
                # srsue l a recue de l EPC.
                if re.search(r'^\s+\|--\s+(?!127\.)\d+\.\d+\.\d+\.\d+\n\s+/32 host LOCAL', trie, re.M):
                    return True
        return False if lu else None

    def state(self):
        if time.time() - self._t < 1.0:
            return self._v
        v = dict(self.cfg)
        v["eci"] = ((v["enb_id"] & 0xFFFFF) << 8) | (v["cell_id"] & 0xFF)
        v["enb"] = LTE_ON and _tcp_ecoute(ZMQ_PORT)
        v["ue"] = self._ue_attache() if v["enb"] else False
        if LTE_TEMOIN == "enb":
            v["ok"] = v["enb"]
        else:
            v["ok"] = v["enb"] and v["ue"] is not False
        etat = (v["enb"], v["ok"])
        if etat != self._dernier:
            if v["ok"]:
                log("4G : eNB en ligne (ZeroMQ %d), UE %s - TAC %04X, ECI %08X, APN %s"
                    % (ZMQ_PORT, "attache" if v["ue"] else "non observable, on suit l eNB",
                       v["tac"], v["eci"], v["apn"]))
            elif not v["enb"]:
                log("4G : eNB absent (rien n ecoute sur le port ZeroMQ %d)" % ZMQ_PORT)
            else:
                log("4G : eNB en ligne mais srsUE pas attache (pas de %s avec une adresse, ni dans %s ni sur l hote)"
                    % (LTE_TUN, LTE_NETNS or "-"))
            self._dernier = etat
        self._v, self._t = v, time.time()
        return v

    def resume(self):
        c = self.cfg
        if not self.dir:
            log("4G : aucune configuration srsRAN trouvee (OSMO_SRSRAN_DIR) - valeurs par defaut")
        else:
            log("4G : configuration srsRAN dans %s" % self.dir)
        log("4G : PLMN %s%s, EARFCN %d, TAC %04X, eNB 0x%X, APN %s"
            % (c["mcc"], c["mnc"], c["earfcn"], c["tac"], c["enb_id"], c["apn"]))
        if c["geran"]:
            log("4G : SIB7 annonce la 2G sur ARFCN %s%s"
                % (", ".join(str(a) for a in c["geran"]),
                   "" if c["sib7_annonce"] else
                   " - MAIS le SIB7 n est pas dans si_mapping_info du SIB1 : il n est pas emis"))
        else:
            log("4G : pas de SIB7 (liste GERAN) dans sib.conf - pas de CSFB annonce aux UE")

    def verifier_geran(self, arfcn_bts):
        """Une fois : la 2G que le SIB7 annonce est-elle celle du banc ?"""
        if self._geran_verifie or not arfcn_bts:
            return
        self._geran_verifie = True
        try:
            a = int(arfcn_bts)
        except ValueError:
            return
        if self.cfg["geran"] and a not in self.cfg["geran"]:
            log("4G : ATTENTION, le SIB7 annonce ARFCN %s mais la BTS du banc est sur %d - "
                "un vrai UE ne trouverait pas la 2G pour son CSFB (sib.conf : explicit_list_of_arfcns)"
                % (", ".join(str(x) for x in self.cfg["geran"]), a))


LTE = Lte()


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
            # La seconde jambe de nos propres appels compose NOTRE numero : sans
            # ce test, le telephone sonne pour l appel qu il vient de passer.
            if modem.est_notre_jambe(e.get("Channel") or ""):
                return
            modem.entrant(e.get("CallerIDNum") or "", e.get("DestChannel") or "")
        elif ev == "Newchannel":
            # [2026-09-07] LE NOM QU ON GARDAIT N EN ETAIT PAS UN.
            # ami_originate range « Local/600@internal », qui est la DEMANDE.
            # Asterisk, lui, cree « Local/600@internal-0000000b;1 » : le
            # Action: Hangup sur l ancien nom ne trouvait rien et ne raccrochait
            # donc jamais - d ou les quatorze canaux empiles sur le banc. On
            # note le vrai nom des qu il apparait.
            # [2026-09-07] ON LATCHE LE PREMIER, PAS LE DERNIER. Un canal Local
            # arrive par PAIRES (« ...;1 » et « ...;2 », les deux evenements a
            # la meme milliseconde) : la boucle acceptait les deux et le nom
            # retenu finissait sur « ;2 ». On ne remplace donc le nom que tant
            # qu il vaut encore la DEMANDE (c["origine"]).
            chan = e.get("Channel") or ""
            for c in modem.calls:
                ref = c.get("channel")
                if ref and chan.startswith(ref) and chan != ref \
                        and c.get("channel") == c.get("origine"):
                    c["channel"] = chan
        elif ev == "Hangup" or (ev == "DialEnd" and e.get("DialStatus") != "ANSWER"):
            for chan in (e.get("Channel"), e.get("DestChannel")):
                if chan:
                    modem.fin_appel(chan)


# ── LA DATA : UN SERVEUR PPP AU BOUT DU PORT AT ─────────────────────────────
# [2026-09-07] POURQUOI PPP, ET PAS AUTRE CHOSE. ModemManager, devant un modem
# qui n a qu un port AT, ne connait qu une facon de faire la data : composer
# ATD*99***1#, attendre CONNECT, et laisser NetworkManager lancer pppd sur le
# port serie. Les greffons qui savent se passer de PPP (Fibocom +GTRNDIS,
# Huawei ^NDISDUP, Cinterion ^SWWAN) exigent tous un port reseau USB - soit
# pour reconnaitre le modem a son identifiant USB, soit pour numeroter le port
# (bInterfaceNumber) ; sur un port serie PCI de QEMU, aucun ne s applique.
# Verifie dans les sources de ModemManager le 2026-09-07. Il faut donc que le
# telephone AIT du PPP (les modules ppp_generic/ppp_async, compiles pour son
# noyau) et que ce modem parle PPP a l autre bout : c est ce bloc.
#
# Ce qu on fait, et rien de plus (RFC 1661, 1662, 1332) :
#   - le cadrage HDLC asynchrone (0x7e, echappement 0x7d, FCS-16) ;
#   - LCP : on accepte MRU, ACCM, nombre magique, PFC et ACFC, on rejette le
#     reste (dont l authentification : le banc n en demande pas) ; on repond
#     aux Echo-Request ; un Terminate-Request finit la session ;
#   - IPCP : on DONNE au telephone son adresse et ses DNS par Configure-Nak
#     (c est ainsi qu un operateur les attribue), on refuse la compression VJ ;
#   - IPv6CP et CCP : Protocol-Reject, pppd s en passe ;
#   - les paquets IP vont dans un tun, et ce tun est mis DANS L ESPACE RESEAU
#     DE srsUE (--gw.netns) avec un NAT vers tun_srsue : chaque paquet du
#     telephone traverse alors la radio 4G, l eNB, l EPC et le SGi. Si srsUE
#     tourne sur l hote (sans netns), on route quand meme par tun_srsue, mais
#     le retour, lui, prend le raccourci local - l UE et l EPC etant la meme
#     machine, le noyau livre en interne ce qui est adresse a une adresse
#     locale. On le dit dans le journal.
import fcntl
import random
import struct

# [2026-09-08] Les adresses du lien PPP ne doivent PAS etre celles que l EPC
# donne a l UE. Avec open5gs, srsUE recoit 10.45.0.2 ; le lien PPP en
# 10.45.0.1/.2 mettait alors l adresse du telephone en LOCAL sur tun_srsue,
# dans le meme espace reseau : le retour du NAT etait livre a l hote au lieu
# de repartir vers le telephone. Un /30 a part, que rien d autre n emploie.
PPP_LOCAL = os.environ.get("OSMO_PPP_LOCAL", "10.99.0.1")      # nous, le reseau
PPP_PEER = os.environ.get("OSMO_PPP_PEER", "10.99.0.2")        # le telephone
PPP_DNS = [d.strip() for d in os.environ.get("OSMO_PPP_DNS", "8.8.8.8,8.8.4.4").split(",") if d.strip()]
PPP_IF = os.environ.get("OSMO_PPP_IF", "ppp-pmos")


def _sgi_net_defaut():
    """Le sous-reseau des UE, pour la sortie SGi -> Internet de l hote :
    celui de smf.yaml avec open5gs (10.45.0.0/16), 172.16.0.0/24 avec srsEPC."""
    for f in ("/root/open5gs/install/etc/open5gs/smf.yaml", "/etc/open5gs/smf.yaml"):
        try:
            m = re.search(r'^\s*-\s*subnet:\s*(\d+\.\d+\.\d+\.\d+/\d+)', open(f).read(), re.M)
        except OSError:
            continue
        if m:
            return m.group(1)
    return "172.16.0.0/24"


PPP_SGI_NET = os.environ.get("OSMO_LTE_SGI_NET") or _sgi_net_defaut()

_FCS_TAB = []
for _b in range(256):
    _v = _b
    for _ in range(8):
        _v = (_v >> 1) ^ 0x8408 if _v & 1 else _v >> 1
    _FCS_TAB.append(_v)


def ppp_fcs(data, fcs=0xFFFF):
    for b in data:
        fcs = (fcs >> 8) ^ _FCS_TAB[(fcs ^ b) & 0xFF]
    return fcs


def _sh(*cmd):
    """Une commande systeme, sans lever : rend (rc, sortie)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


class Ppp:
    LCP, IPCP, IP, IPV6CP, CCP = 0xC021, 0x8021, 0x0021, 0x8057, 0x80FD
    CONF_REQ, CONF_ACK, CONF_NAK, CONF_REJ = 1, 2, 3, 4
    TERM_REQ, TERM_ACK, CODE_REJ, PROTO_REJ, ECHO_REQ, ECHO_REP = 5, 6, 7, 8, 9, 10

    def __init__(self, modem):
        self.modem = modem
        self.magic = struct.pack(">I", random.getrandbits(32))
        self.buf = bytearray()
        self.in_frame = False
        self.esc = False
        self.brut = bytearray()              # ce qui arrive HORS trame (un AT ?)
        self.ident = 0
        self.lcp_ack_recu = self.lcp_ack_donne = self.lcp_ouvert = False
        self.ipcp_ack_recu = self.ipcp_ack_donne = self.ipcp_ouvert = False
        self.tun = None
        self.ns = None
        self.fini = False
        self.lock = threading.Lock()
        self.octets = [0, 0]                 # montant, descendant
        self._motif_fin = None               # pose par terminer()

    def terminer(self, motif):
        """C est NOUS qui fermons la session : Terminate-Request a pppd, qui
        repond Terminate-Ack et s arrete ; s il ne repond pas dans la seconde,
        on ferme quand meme. fin() dira NO CARRIER au port, ModemManager
        reprend alors la main en mode commande."""
        if self.fini or self._motif_fin:
            return
        self._motif_fin = motif
        self._paquet(self.LCP, self.TERM_REQ, self._prochain(), b"")
        t = threading.Timer(1.0, lambda: self.fin(motif))
        t.daemon = True
        t.start()

    # -- la couche HDLC
    def feed(self, data):
        for b in data:
            if b == 0x7E:
                if self.in_frame and len(self.buf) >= 4:
                    self._trame(bytes(self.buf))
                self.buf.clear()
                self.in_frame = True
                self.esc = False
                self.brut.clear()
                continue
            if not self.in_frame:
                # Hors trame : le port a pu repasser en AT (ModemManager qui
                # reprend la main apres la mort de pppd). « AT » suivi d une
                # fin de ligne, et on rend le port.
                self.brut += bytes([b])
                if b in (0x0D, 0x0A):
                    ligne = self.brut.decode(errors="replace").strip().upper()
                    self.brut.clear()
                    if ligne.startswith("AT") or ligne == "+++":
                        self.fin("commande AT recue en mode donnees (%s)" % ligne)
                        return
                if len(self.brut) > 64:
                    del self.brut[:32]
                continue
            if self.esc:
                self.buf.append(b ^ 0x20)
                self.esc = False
            elif b == 0x7D:
                self.esc = True
            else:
                self.buf.append(b)

    def _trame(self, f):
        if ppp_fcs(f) != 0xF0B8:
            return                           # FCS faux : on jette
        f = f[:-2]
        if f[:2] == b"\xff\x03":
            f = f[2:]
        if not f:
            return
        if f[0] & 1:                         # protocole sur un octet (PFC)
            proto, pkt = f[0], f[1:]
        else:
            proto, pkt = struct.unpack(">H", f[:2])[0], f[2:]
        if proto == self.IP:
            self._vers_tun(pkt)
        elif proto == self.LCP:
            self._lcp(pkt)
        elif proto == self.IPCP:
            self._ipcp(pkt)
        else:
            self._proto_rejet(proto, pkt)

    def envoyer(self, proto, payload):
        f = b"\xff\x03" + struct.pack(">H", proto) + payload
        fcs = ppp_fcs(f) ^ 0xFFFF
        f += bytes([fcs & 0xFF, fcs >> 8])
        out = bytearray([0x7E])
        for b in f:
            if b < 0x20 or b in (0x7D, 0x7E):
                out += bytes([0x7D, b ^ 0x20])
            else:
                out.append(b)
        out.append(0x7E)
        with self.lock:
            try:
                self.modem.wfile.write(bytes(out))
                self.modem.wfile.flush()
            except OSError:
                self.fin("port ferme")

    # -- les paquets de negociation
    @staticmethod
    def _options(data):
        opts, i = [], 0
        while i + 2 <= len(data):
            t, ln = data[i], data[i + 1]
            if ln < 2 or i + ln > len(data):
                break
            opts.append((t, data[i + 2:i + ln]))
            i += ln
        return opts

    @staticmethod
    def _opt(t, v):
        return bytes([t, 2 + len(v)]) + v

    def _paquet(self, proto, code, ident, body):
        self.envoyer(proto, bytes([code, ident]) + struct.pack(">H", 4 + len(body)) + body)

    def _prochain(self):
        self.ident = (self.ident + 1) & 0xFF or 1
        return self.ident

    def demarrer(self):
        log("PPP : session ouverte (CONNECT), le telephone doit lancer pppd")
        self._lcp_requete()

    def _lcp_requete(self):
        self._paquet(self.LCP, self.CONF_REQ, self._prochain(),
                     self._opt(2, b"\x00\x00\x00\x00") + self._opt(5, self.magic))

    def _lcp(self, pkt):
        if len(pkt) < 4:
            return
        code, ident, ln = pkt[0], pkt[1], struct.unpack(">H", pkt[2:4])[0]
        body = pkt[4:ln]
        if code == self.CONF_REQ:
            rejet = b""
            for t, v in self._options(body):
                if t not in (1, 2, 5, 7, 8):     # MRU, ACCM, magique, PFC, ACFC
                    rejet += self._opt(t, v)
            if rejet:
                self._paquet(self.LCP, self.CONF_REJ, ident, rejet)
            else:
                self._paquet(self.LCP, self.CONF_ACK, ident, body)
                self.lcp_ack_donne = True
            if not self.lcp_ack_recu:
                self._lcp_requete()
        elif code == self.CONF_ACK:
            self.lcp_ack_recu = True
        elif code in (self.CONF_NAK, self.CONF_REJ):
            # On n insiste pas sur l ACCM : le nombre magique suffit.
            self._paquet(self.LCP, self.CONF_REQ, self._prochain(), self._opt(5, self.magic))
        elif code == self.TERM_REQ:
            self._paquet(self.LCP, self.TERM_ACK, ident, body)
            self.fin("le telephone a termine la session PPP")
            return
        elif code == self.TERM_ACK and self._motif_fin:
            self.fin(self._motif_fin)
            return
        elif code == self.ECHO_REQ:
            self._paquet(self.LCP, self.ECHO_REP, ident, self.magic + body[4:])
        if self.lcp_ack_recu and self.lcp_ack_donne and not self.lcp_ouvert:
            self.lcp_ouvert = True
            log("PPP : LCP ouvert, on passe a IPCP")
            self._ipcp_requete()

    def _proto_rejet(self, proto, pkt):
        if proto in (self.IPV6CP, self.CCP) or self.lcp_ouvert:
            self._paquet(self.LCP, self.PROTO_REJ, self._prochain(),
                         struct.pack(">H", proto) + pkt[:8])

    def _ipcp_requete(self):
        self._paquet(self.IPCP, self.CONF_REQ, self._prochain(),
                     self._opt(3, socket.inet_aton(PPP_LOCAL)))

    def _ipcp(self, pkt):
        if len(pkt) < 4:
            return
        code, ident, ln = pkt[0], pkt[1], struct.unpack(">H", pkt[2:4])[0]
        body = pkt[4:ln]
        if code == self.CONF_REQ:
            rejet, nak = b"", b""
            dns = PPP_DNS + PPP_DNS[:1]
            for t, v in self._options(body):
                if t == 3:                    # l adresse du telephone
                    if v != socket.inet_aton(PPP_PEER):
                        nak += self._opt(3, socket.inet_aton(PPP_PEER))
                elif t == 129:                # DNS primaire
                    if v != socket.inet_aton(dns[0]):
                        nak += self._opt(129, socket.inet_aton(dns[0]))
                elif t == 131:                # DNS secondaire
                    if v != socket.inet_aton(dns[1]):
                        nak += self._opt(131, socket.inet_aton(dns[1]))
                else:                         # compression VJ et le reste
                    rejet += self._opt(t, v)
            if rejet:
                self._paquet(self.IPCP, self.CONF_REJ, ident, rejet)
            elif nak:
                self._paquet(self.IPCP, self.CONF_NAK, ident, nak)
            else:
                self._paquet(self.IPCP, self.CONF_ACK, ident, body)
                self.ipcp_ack_donne = True
            if not self.ipcp_ack_recu:
                self._ipcp_requete()
        elif code == self.CONF_ACK:
            self.ipcp_ack_recu = True
        elif code in (self.CONF_NAK, self.CONF_REJ):
            self._ipcp_requete()
        elif code == self.TERM_REQ:
            self._paquet(self.IPCP, self.TERM_ACK, ident, body)
        if self.ipcp_ack_recu and self.ipcp_ack_donne and not self.ipcp_ouvert:
            self.ipcp_ouvert = True
            self._tun_monter()

    # -- le tun, et son branchement sur la radio
    def _tun_monter(self):
        TUNSETIFF, IFF_TUN, IFF_NO_PI = 0x400454CA, 0x0001, 0x1000
        try:
            fd = os.open("/dev/net/tun", os.O_RDWR)
            fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", PPP_IF.encode(), IFF_TUN | IFF_NO_PI))
        except OSError as e:
            log("PPP : impossible de creer %s (%s) - il faut root ; la session reste sans IP" % (PPP_IF, e))
            return
        self.tun = fd
        rc, _ = _sh("ip", "-n", LTE_NETNS, "-4", "-o", "addr", "show", LTE_TUN) if LTE_NETNS else (1, "")
        self.ns = LTE_NETNS if rc == 0 and "inet" in _ else None
        ip = ["ip", "-n", self.ns] if self.ns else ["ip"]
        ex = ["ip", "netns", "exec", self.ns] if self.ns else []
        if self.ns:
            _sh("ip", "link", "set", PPP_IF, "netns", self.ns)
        _sh(*ip, "addr", "replace", PPP_LOCAL, "peer", PPP_PEER + "/32", "dev", PPP_IF)
        _sh(*ip, "link", "set", PPP_IF, "up", "mtu", "1500")
        _sh(*ex, "sysctl", "-qw", "net.ipv4.ip_forward=1")
        _sh(*ex, "sysctl", "-qw", "net.ipv4.conf.%s.rp_filter=0" % PPP_IF)
        rc, _ = _sh(*ip, "-4", "-o", "addr", "show", LTE_TUN)
        radio = rc == 0 and "inet" in _
        if radio:
            # Tout ce qui vient du telephone sort par la radio (tun_srsue), en
            # NAT derriere l adresse de l UE. Dans l espace de srsUE c est la
            # route par defaut ; sur l hote, une table a part (fwmark inutile :
            # on route par l adresse source).
            if self.ns:
                _sh(*ip, "route", "replace", "default", "dev", LTE_TUN)
            else:
                _sh("ip", "route", "replace", "default", "dev", LTE_TUN, "table", "45")
                rc, _ = _sh("ip", "rule", "show")
                if PPP_PEER not in _:
                    _sh("ip", "rule", "add", "from", PPP_PEER, "lookup", "45", "priority", "4500")
            rc, _ = _sh(*ex, "iptables", "-w", "-t", "nat", "-C", "POSTROUTING", "-s", PPP_PEER, "-o", LTE_TUN, "-j", "MASQUERADE")
            if rc != 0:
                _sh(*ex, "iptables", "-w", "-t", "nat", "-A", "POSTROUTING", "-s", PPP_PEER, "-o", LTE_TUN, "-j", "MASQUERADE")
            # Et la sortie du SGi vers Internet, que srsEPC ne pose pas.
            rc, up = _sh("sh", "-c", "ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i==\"dev\") print $(i+1); exit}'")
            if up:
                _sh("sysctl", "-qw", "net.ipv4.ip_forward=1")
                rc, _ = _sh("iptables", "-w", "-t", "nat", "-C", "POSTROUTING", "-s", PPP_SGI_NET, "-o", up, "-j", "MASQUERADE")
                if rc != 0:
                    _sh("iptables", "-w", "-t", "nat", "-A", "POSTROUTING", "-s", PPP_SGI_NET, "-o", up, "-j", "MASQUERADE")
            log("PPP : IPCP ouvert, %s a %s ; %s monte %s, la data passe par %s%s"
                % (PPP_PEER, "le telephone", PPP_IF,
                   "dans l espace %s" % self.ns if self.ns else "sur l hote",
                   LTE_TUN,
                   "" if self.ns else " (retour en raccourci local : srsue sans --gw.netns)"))
        else:
            log("PPP : IPCP ouvert, %s au telephone, mais pas de %s : la data n a pas de sortie radio"
                % (PPP_PEER, LTE_TUN))
        threading.Thread(target=self._depuis_tun, daemon=True).start()

    def _vers_tun(self, pkt):
        if self.tun is None:
            return
        try:
            os.write(self.tun, pkt)
            self.octets[0] += len(pkt)
        except OSError:
            pass

    def _depuis_tun(self):
        fd = self.tun
        while not self.fini and fd is not None:
            try:
                pkt = os.read(fd, 2048)
            except OSError:
                return
            if not pkt:
                return
            self.octets[1] += len(pkt)
            self.envoyer(self.IP, pkt)

    def _tun_demonter(self):
        fd, self.tun = self.tun, None
        if fd is None:
            return
        ip = ["ip", "-n", self.ns] if self.ns else ["ip"]
        _sh(*ip, "link", "del", PPP_IF)
        if not self.ns:
            _sh("ip", "rule", "del", "from", PPP_PEER, "lookup", "45")
        try:
            os.close(fd)
        except OSError:
            pass

    def fin(self, motif):
        if self.fini:
            return
        self.fini = True
        log("PPP : fin (%s) - %d octets montes, %d descendus" % (motif, self.octets[0], self.octets[1]))
        self._tun_demonter()
        self.modem.ppp_fini()


# ── LE MODEM AT ─────────────────────────────────────────────────────────────
class AtHandler(socketserver.StreamRequestHandler):
    """Un modem par connexion : oFono en ouvre une seule."""

    role = "commande"             # « commande » (hvc0) ou « data » (hvc1, voir DATA)

    def setup(self):
        super().setup()
        global CURRENT, DATA
        if self.role == "data":
            DATA = self
        else:
            CURRENT = self        # oFono n ouvre qu une connexion : c est celle-ci
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
        # La 4G et le CSFB (voir la classe Lte). Trois modes d URC, un par
        # enregistrement (CS, GPRS, EPS) ; ws46 = les technologies que le
        # systeme AUTORISE (27.007 § 5.9 : 12 GSM seule, 28 E-UTRAN seule,
        # 31 les deux) - c est le reglage « reseau prefere » de Phosh ;
        # _cs_hold tient la 2G le temps du service CS, _retour est le
        # minuteur qui nous remonte sur la 4G ; _rat_annonce, la derniere
        # technologie annoncee, pour ne signaler que les changements.
        self.cgreg_mode = 0
        self.cereg_mode = 0
        self.ws46 = 31
        self._cs_hold = False
        self._retour = None
        self._rat_annonce = None
        self.data_cid = 0           # le contexte PDP « connecte » par +GTRNDIS (0 = aucun)
        self.ppp = None             # la session PPP en cours (ATD*99), voir la classe Ppp
        self._urc_attente = []      # les URC retenus pendant la data (voir out)
        self._urc_lock = threading.Lock()
        self.port_commande = True   # False entre NO CARRIER et la commande AT suivante
        log("oFono s est connecte depuis %s (port de %s)" % (self.client_address, self.role))
        if self.role != "data":
            threading.Thread(target=self._veille, daemon=True).start()

    def finish(self):
        """Le lien est tombe : ce modem n est plus « le » modem.

        [2026-09-07] CURRENT RESTAIT SUR UN MORT. Il etait pose dans setup() et
        jamais repris : apres une deconnexion, on_passerelle_sms() croyait
        avoir un correspondant, deliver_sms() ecrivait dans une douille fermee
        (out() avale l OSError) et journalisait « SMS remis » - un message
        annonce comme remis a personne. Meme piege pour les RING d AmiEcoute.
        La boite, elle, garde le message : il ressortira au prochain AT+CMGL.
        """
        global CURRENT, DATA
        if CURRENT is self:
            CURRENT = None
        if DATA is self:
            DATA = None
        if self.ppp is not None:
            self.ppp.fin("lien AT ferme")
        # [2026-09-08] LES APPELS MEURENT AVEC LE LIEN. Un appel arrive sur ce
        # gestionnaire, la VM redemarre : le lien tombe, un nouveau
        # gestionnaire nait, et l AMI ne parle qu a CURRENT - le raccroche
        # n arrivait donc jamais ici. La boucle _sonne tournait pour toujours
        # (RING toutes les 3 s dans le journal, vers une douille fermee) et le
        # correspondant restait pendu. On raccroche cote Asterisk et on vide.
        for c in list(self.calls):
            log("lien ferme : appel %s abandonne, raccroche cote Asterisk"
                % (c.get("channel") or c.get("num") or "?"))
            ami_hangup(c.get("channel"))
        self.calls.clear()
        t, self._retour = self._retour, None
        if t:
            t.cancel()
        try:
            super().finish()
        except OSError:
            pass

    def ppp_fini(self):
        """La session PPP est finie : le port redevient un port AT, et on le
        dit comme un modem (NO CARRIER) - ModemManager relance alors sa
        sonde et le porteur passe « deconnecte »."""
        self.ppp = None
        self.data_cid = 0
        # NO CARRIER part tel quel : c est lui qui rend le port. Ensuite, tant
        # que le telephone n a pas envoye sa premiere commande AT, le port est
        # encore a pppd qui s arrete : ce qu on emettrait partirait dans le
        # vide (les +CREG du retour 4G, un +CMTI). On retient (voir out).
        self.port_commande = False
        atlog(">", "NO CARRIER")
        try:
            self.wfile.write(b"\r\nNO CARRIER\r\n")
            self.wfile.flush()
        except OSError:
            pass

    def _tag(self, sens):
        return sens if self.role != "data" else sens + "d"      # « >d » : port de donnees

    def out(self, text):
        # [2026-09-08] UN SEUL PORT, DONC PAS D URC PENDANT LE PPP. Le modem du
        # banc n a qu un port serie : une fois ATD*99 passe, tout ce qu on y
        # ecrit entre dans le flux PPP, et pppd jette RING, +CLIP, +CMTI comme
        # du bruit. Le telephone ne voyait donc ni appel ni SMS entrant des
        # que la data etait montee. Ce qui doit etre annonce pendant la data
        # attend ici, et part des que le port est revenu en mode commande
        # (voir _urc_liberer, appele apres la premiere commande AT qui suit).
        # csfb_debut() coupe la data pour cela : sur un vrai reseau aussi, le
        # CSFB suspend la data le temps du service CS.
        if self.ppp is not None or not self.port_commande:
            with self._urc_lock:
                if text not in self._urc_attente:
                    self._urc_attente.append(text)
            atlog(self._tag("~"), text + "   (retenu : port en mode donnees)")
            return
        atlog(self._tag(">"), text)
        try:
            self.wfile.write(("\r\n%s\r\n" % text).encode())
            self.wfile.flush()
        except OSError:
            pass

    def _urc_liberer(self):
        """Le port est en mode commande : on emet ce qui attendait."""
        with self._urc_lock:
            attente, self._urc_attente = self._urc_attente, []
        for text in attente:
            self.out(text)

    # -- la technologie d acces : 4G au repos, 2G le temps d un service CS
    def _modem(self):
        """L etat du telephone vit sur le port de commande : le port de
        donnees s y reporte."""
        if self.role == "data" and CURRENT is not None:
            return CURRENT
        return self

    def cs_actif(self):
        m = self._modem()
        return bool(m.calls) or m.sms_target is not None or m._cs_hold

    def appel_en_cours(self):
        return bool(self._modem().calls)

    def rat(self):
        """« lte » ou « gsm » : ou le telephone est pose en ce moment."""
        if self.role == "data" and CURRENT is not None:
            return CURRENT.rat()
        if self.ws46 == 12:                   # le systeme a demande GSM seule
            return "gsm"
        if not LTE.state()["ok"]:
            return "gsm"
        if self.cs_actif():
            return "gsm"                      # CSFB : on est descendu
        return "lte"

    def _reg(self, tag):
        """(stat, lac ou tac, ci ou eci, act) pour +CREG, +CGREG ou +CEREG
        dans la technologie courante. act None = pas de position a donner."""
        st = BANC.state()
        lte = LTE.state()
        if self.rat() == "lte":
            # Rattachement combine (EPS + IMSI attach par SGs) : le CS est
            # enregistre si la 2G est la, et tout se dit avec TAC/ECI, AcT 7.
            stat_cs = 1 if st["up"] else (2 if lte["ok"] else 0)
            stat = stat_cs if tag == "+CREG" else 1
            return stat, lte["tac"], lte["eci"], 7
        reg = 1 if st["up"] else 0
        if tag == "+CEREG":
            # Sur la 2G, l EPS est suspendu (CSFB) ou absent : pas de position.
            return (2 if lte["ok"] else 0), 0, 0, None
        return reg, st["lac"], st["cid"], 0

    def _ligne_reg(self, tag, mode, urc=False):
        stat, lac, ci, act = self._reg(tag)
        tete = "%s: " % tag + ("" if urc else "%d," % mode)
        if mode >= 2 and act is not None and stat in (1, 5):
            return '%s%d,"%04X","%08X",%d' % (tete, stat, lac, ci, act)
        return "%s%d" % (tete, stat)

    def annonce_rat(self):
        """Signale un changement de technologie par les URC d enregistrement
        que le systeme a demandes (AT+CREG=2 etc.). L ordre compte : c est la
        DERNIERE annonce qui donne l AcT que ModemManager retient, on finit
        donc par celle qui porte la technologie du moment."""
        if self.role == "data":
            return                            # les URC vont sur le port de commande
        rat = self.rat()
        prev, self._rat_annonce = self._rat_annonce, rat
        if prev == rat:
            return
        if prev is not None:
            log("technologie : %s -> %s" % ("4G" if prev == "lte" else "2G",
                                             "4G" if rat == "lte" else "2G"))
        ordre = ("+CEREG", "+CGREG", "+CREG") if rat == "gsm" else ("+CREG", "+CGREG", "+CEREG")
        modes = {"+CREG": self.creg_mode, "+CGREG": self.cgreg_mode, "+CEREG": self.cereg_mode}
        for tag in ordre:
            if modes[tag] >= 1:
                self.out(self._ligne_reg(tag, modes[tag], urc=True))

    def _veille(self):
        """La 4G peut se lever ou tomber pendant que le telephone ne fait
        rien : on regarde toutes les deux secondes, et on verifie une fois que
        la 2G annoncee par le SIB7 est bien celle du banc."""
        while CURRENT is self:
            try:
                st = BANC.state()
                if st["up"]:
                    LTE.verifier_geran(st["arfcn"])
                self.annonce_rat()
            except Exception as e:      # jamais au prix du modem lui-meme
                log("veille 4G : %s" % e)
            time.sleep(2)

    def csfb_debut(self, motif, couper_data=True):
        """Un service CS commence : on descend sur la 2G, tout de suite, et on
        annule un retour 4G qui serait en route. couper_data : la session PPP
        est fermee (un appel : la 2G n a pas de data pendant la voix ; un SMS
        en port unique : il faut rendre le port aux URC)."""
        t, self._retour = self._retour, None
        if t:
            t.cancel()
        self._cs_hold = True
        if self._rat_annonce == "lte":
            st = BANC.state()
            log("CSFB : %s - on quitte la 4G pour la 2G (ARFCN %s, LAC %d, CI %d)"
                % (motif, st["arfcn"] or "?", st["lac"], st["cid"]))
        # La data est suspendue le temps du service CS - et c est surtout le
        # seul moyen de rendre le port aux URC (voir out). NetworkManager
        # relancera ATD*99 de lui-meme une fois l UE revenu sur la 4G.
        if couper_data:
            for m in (self, DATA):
                if m is not None and m.ppp is not None:
                    log("CSFB : data suspendue (fin de la session PPP) le temps du service CS")
                    m.ppp.terminer("CSFB : data suspendue le temps du service CS")
        self.annonce_rat()

    def csfb_fin_apres(self, delai=2.0):
        """Le service CS est fini : dans <delai> secondes, s il n en a pas
        commence un autre, on remonte sur la 4G - le temps qu un vrai UE met
        a reselectionner sa cellule LTE une fois l appel raccroche."""
        t, self._retour = self._retour, None
        if t:
            t.cancel()
        self._retour = threading.Timer(delai, self._retour_lte)
        self._retour.daemon = True
        self._retour.start()

    def _retour_lte(self):
        self._retour = None
        if self.calls or self.sms_target is not None:
            return                            # un autre service CS a pris le relais
        self._cs_hold = False
        if self._rat_annonce == "gsm" and LTE.state()["ok"] and self.ws46 != 12:
            log("CSFB : service CS termine, retour sur la 4G")
        self.annonce_rat()

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
            if self.ppp is not None:
                # Mode donnees : tout va au PPP, rien n est repete en echo.
                self.ppp.feed(data)
                buf = b""
                continue
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
                    atlog(self._tag("<"), text)
                if text:
                    self.port_commande = True     # le telephone parle AT : le port est a nous
                    # Les URC retenus partent AVANT la commande : si c est
                    # ATD*99, le port repasse en data juste apres, et un
                    # +CEREG « retour 4G » retenu resterait enferme derriere
                    # le PPP - Phosh gardait la 2G a l ecran.
                    if self.ppp is None and self._urc_attente:
                        self._urc_liberer()
                if self.sms_target is not None and m.group() == b"\x1a":
                    self.sms(text)
                elif text:
                    self.command(text)
        log("oFono s est deconnecte")

    # -- un SMS venu du banc, remis au modem
    # -- les appels entrants, pousses par AmiEcoute
    def est_notre_jambe(self, chan):
        """Ce canal est-il une jambe d un appel que NOUS avons lance ?

        [2026-09-07] LE TELEPHONE SE SONNAIT LUI-MEME, ET RACCROCHAIT SEUL.
        ami_originate() lance « Local/<num>@internal » d un cote et, de
        l autre, fait composer NOTRE PROPRE numero (Exten: MSISDN) - c est
        ainsi que le banc met le correspondant en relation avec l abonne. Cette
        seconde jambe produit donc, pour chacun de nos appels sortants :
            DialBegin  Context: internal  DestExten: 100101
        soit exactement la signature d un appel entrant (« internal » fait
        partie d IN_CTX depuis qu un appel Linphone doit pouvoir nous joindre).
        Le filtre « DestExten == notre MSISDN » ne separait donc rien : la
        remarque en tete d IN_CTX - « la seconde jambe compose le numero
        DISTANT, jamais le notre » - est fausse pour CE code.

        Consequence, reproduite sur le banc le 2026-09-07 (Originate vers 600,
        evenements AMI horodates) : des le ATD, entrant() ajoutait un DEUXIEME
        appel et envoyait RING - le telephone sonnait pour l appel qu il venait
        de passer ; +CLCC en annoncait deux ; et a la fin de la jambe,
        fin_appel() emettait NO CARRIER. ModemManager terminait alors l appel :
        l ecran d appel de Phosh se fermait tout seul, quelques dixiemes de
        seconde apres la numerotation. « Ca me disco quand je passe un appel ».
        On reconnait donc nos jambes au canal QUI COMPOSE (le Local que nous
        avons demande), et non au contexte - un vrai appel entrant, lui, arrive
        toujours par un autre canal.
        """
        if not chan:
            return False
        for c in self.calls:
            ref = c.get("origine")
            if ref and chan.startswith(ref):
                return True
        return False

    def entrant(self, num, chan):
        """Le banc nous appelle : on sonne jusqu a ce que ca cesse."""
        if any(c.get("channel") == chan for c in self.calls):
            return
        c = {"num": num, "state": "incoming", "channel": chan}
        # Le paging arrive par la 4G (SGs), la sonnerie se joue sur la 2G :
        # on descend AVANT le premier RING. Avec un port de donnees a part, la
        # data reste : refuser ATD*99 pendant la sonnerie faisait passer
        # NetworkManager en repli (4 echecs, puis 5 min sans reessayer).
        self.csfb_debut("appel entrant de %s" % (num or "inconnu"), couper_data=(DATA is None))
        self.calls.append(c)
        log("appel entrant de %s (%s)" % (num or "inconnu", chan))
        threading.Thread(target=self._sonne, args=(c,), daemon=True).start()

    def _sonne(self, c):
        """RING toutes les trois secondes, et +CLIP juste derriere pour donner
        le numero - c est ce que ModemManager attend pour presenter l appel
        (AT+CLIP=1 fait partie des reglages qu on accepte)."""
        while c in self.calls and c["state"] == "incoming" and CURRENT is self:
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
        if not self.calls:
            self.csfb_fin_apres()

    def deliver_sms(self, sender, text):
        """Remet un SMS entrant DE LA FACON QUE LE SYSTEME A DEMANDEE.

        On range toujours le message : meme en mt=2 le systeme peut vouloir le
        relire (AT+CMGL au demarrage). Ensuite seulement on choisit l URC.
        """
        pdu = pdu_deliver(sender, text)
        idx = inbox_ranger(sender, text, pdu)
        # Un SMS est un service CS sur ce banc (il vient du MSC) : on descend
        # sur la 2G le temps de le recevoir, on remonte trois secondes apres.
        # Avec un port de donnees a part, la data reste montee : les URC ont
        # leur port. En port unique, il faut couper pour que +CMTI passe.
        self.csfb_debut("SMS entrant de %s" % (sender or "inconnu"), couper_data=(DATA is None))
        self.csfb_fin_apres(3.0)
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
        self.csfb_debut("SMS vers %s" % num, couper_data=(DATA is None))
        out = MSC.cmd('subscriber msisdn %s sms sender msisdn %s send %s'
                      % (num, MSISDN, text))
        self.csfb_fin_apres(3.0)
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
            # [2026-09-07] « Fibocom », ET POURQUOI. ModemManager choisit son
            # greffon d apres ce nom. Le greffon generique ne sait faire la
            # data que par PPP sur le port AT - et le noyau de la VM n a pas
            # de PPP. Le greffon Fibocom, lui, quand le modem a un PORT RESEAU
            # a cote du port AT et repond a AT+GTRNDIS=?, monte un porteur
            # ECM : +GTRNDIS=1,<cid> pour connecter, adresse par DHCP sur le
            # port reseau. C est ce que fait ce banc : la seconde carte reseau
            # de QEMU (tools/osmo-pmos-data.sh) est ce port, et elle debouche
            # dans l espace reseau de srsUE - donc sur la radio 4G.
            self.out(VENDOR); self.ok(); return
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

        if ub.startswith(("+CREG", "+CGREG", "+CEREG")):
            # [2026-09-07] LES TROIS ENREGISTREMENTS, ET LA 4G. +CREG est le
            # circuit (voix, SMS), +CGREG le paquet 2G/3G, +CEREG l EPS - la
            # LTE. Ce modem repondait ERROR a +CEREG pour rester un modem 2G ;
            # depuis que le banc a une 4G (srsRAN, voir la classe Lte), il
            # dit la verite : enregistre sur l EPS quand srsUE est attache, et
            # chaque reponse porte la technologie du moment (dernier champ :
            # 0 = GSM, 7 = E-UTRAN). Pendant un appel ou un SMS, la reponse
            # bascule sur la 2G (CSFB) et l EPS passe « en recherche ».
            # [2026-09-06] LA FORME « TEST » N EST PAS UN REGLAGE. Le driver
            # atmodem sonde d abord AT+CREG=? et attend la LISTE des modes
            # supportes ; un simple OK lui fait conclure que le modem ne sait
            # pas s enregistrer - oFono journalisait « Unable to initialize
            # Network Registration » et n envoyait plus jamais AT+CREG?, donc
            # pas d interface NetworkRegistration du tout. Meme piege pour
            # +CGREG (la data), d ou « GPRS not supported on this device ».
            tag = ub.split("=")[0].rstrip("?")
            if ub.endswith("=?"):
                self.out("%s: (0-2)" % tag); self.ok(); return
            if "=" in ub:
                try:
                    mode = int(ub.split("=")[1][0])
                except (ValueError, IndexError):
                    mode = 0
                if tag == "+CREG":
                    self.creg_mode = mode
                elif tag == "+CGREG":
                    self.cgreg_mode = mode
                else:
                    self.cereg_mode = mode
                self.ok(); return
            mode = {"+CREG": self.creg_mode, "+CGREG": self.cgreg_mode,
                    "+CEREG": self.cereg_mode}[tag]
            self.out(self._ligne_reg(tag, mode))
            self.ok(); return

        if ub.startswith("+COPS"):
            # oFono interroge l operateur DEUX FOIS, dans deux formats : il pose
            # AT+COPS=3,2 puis AT+COPS? pour le code numerique (MCC/MNC), et
            # AT+COPS=3,0 puis AT+COPS? pour le nom. Repondre toujours en
            # numerique laissait le nom vide et MCC/MNC a None cote oFono - le
            # format demande doit etre retenu.
            # Le dernier champ est la technologie : 7 sur la 4G, 0 sur la 2G.
            rat = self.rat()
            act = 7 if rat == "lte" else 0
            nom = LTE_NAME if rat == "lte" else st["name"]
            if ub.endswith("=?"):
                # LA RECHERCHE DE RESEAUX (« Selectionner un reseau » dans
                # Phosh). Un vrai scan voit une cellule des qu elle EMET, pas
                # seulement quand on y est attache : la 4G est donc listee des
                # que l eNB est en ligne. Elle porte un nom distinct de la 2G
                # (LTE_NAME) : deux entrees « Osmocom » n en feraient qu une
                # a l ecran. stat : 2 = courant, 1 = disponible.
                lte = LTE.state()
                liste = []
                if lte["enb"]:
                    liste.append('(%d,"%s","%s","%s%s",7)'
                                 % (2 if rat == "lte" else 1, LTE_NAME, LTE_NAME, lte["mcc"], lte["mnc"]))
                if st["up"]:
                    liste.append('(%d,"%s","%s","%s%s",0)'
                                 % (2 if rat == "gsm" else 1, st["name"], st["name"], st["mcc"], st["mnc"]))
                self.out('+COPS: %s,,(0,1,3,4),(0,1,2)' % ",".join(liste))
                self.ok(); return
            if ub.endswith("?"):
                if self.cops_format == 2:
                    self.out('+COPS: 0,2,"%s%s",%d' % (st["mcc"], st["mnc"], act))
                else:
                    self.out('+COPS: 0,%d,"%s",%d' % (self.cops_format, nom, act))
                self.ok(); return
            m = re.match(r'\+COPS=3,(\d)', ub)
            if m:
                self.cops_format = int(m.group(1))
                self.ok(); return
            # La SELECTION : AT+COPS=0 (automatique) ou AT+COPS=1,<fmt>,<oper>
            # [,<act>]. Choisir l entree 4G de la liste, c est camper en LTE ;
            # l entree 2G, en GSM ; l automatique rend les deux.
            #
            # [2026-09-07] C EST LE SEUL LEVIER QU A L UTILISATEUR. Le reglage
            # « type de reseau » de Phosh passe par ModemManager, qui REFUSE de
            # le poser sur un modem a commandes AT : « Setting allowed modes not
            # supported » (MM 1.25.95 - il lit AT+WS46=? pour la liste, mais
            # n emet jamais AT+WS46=<n>). Reste la selection manuelle d un
            # reseau, et MM la fait toujours en NUMERIQUE, SANS technologie :
            # « AT+COPS=1,2,"00101" ». Or nos deux radios portent le meme
            # MCC/MNC - le numero ne dit donc pas laquelle on veut.
            # On tranche par l usage : l automatique (+COPS=0), c est deja
            # « la 4G tant qu elle est la » ; demander LA MAIN, ici, ne peut
            # vouloir dire qu une chose - rester sur la 2G. Un nom (format 0
            # ou 1) ou une technologie explicite, eux, sont pris au mot.
            m = re.match(r'\+COPS=(\d)(?:,(\d),"?([^",]*)"?(?:,(\d))?)?', ub)
            if m:
                mode, fmt, oper, actsel = (int(m.group(1)), m.group(2),
                                           m.group(3) or "", m.group(4))
                if mode == 0:
                    self.ws46 = 31
                elif mode == 1:
                    if actsel is not None:
                        self.ws46 = 28 if actsel == "7" else 12
                    elif fmt in ("0", "1") and oper:
                        self.ws46 = 28 if oper.strip().upper() == LTE_NAME.upper() else 12
                    else:
                        self.ws46 = 12
                log("selection de reseau : %s" % {31: "automatique (2G + 4G)", 28: "la 4G", 12: "la 2G"}[self.ws46])
                self.annonce_rat()
            self.ok(); return

        if ub.startswith("+WS46"):
            # 27.007 § 5.9 : la technologie AUTORISEE par le systeme - c est
            # le reglage « type de reseau » de Phosh (2G / 4G / automatique).
            # 12 = GSM seule, 28 = E-UTRAN seule, 31 = GERAN + E-UTRAN.
            if ub.endswith("=?"):
                self.out("+WS46: (12,28,31)"); self.ok(); return
            if ub.endswith("?"):
                self.out("+WS46: %d" % self.ws46); self.ok(); return
            try:
                v = int(re.sub(r"\D", "", ub.split("=", 1)[1]) or "31")
            except (ValueError, IndexError):
                self.err(); return
            if v not in (12, 28, 31):
                self.err(); return
            self.ws46 = v
            log("technologies autorisees : %s" % {12: "2G seule", 28: "4G seule", 31: "2G + 4G"}[v])
            self.annonce_rat()
            self.ok(); return

        if ub.startswith("+CSQ"):
            # Banc en marche = signal franc ; banc arrete = pas de signal.
            # La 4G virtuelle est « plus forte » que la 2G : ca se voit.
            rat = self.rat()
            self.out("+CSQ: %d,99" % (28 if rat == "lte" else 24 if st["up"] else 99))
            self.ok(); return

        if ub.startswith("+CESQ"):
            # La qualite etendue (27.007 § 8.69) : rxlev/ber pour la 2G,
            # rsrq/rsrp pour la 4G, 255 = sans objet. Sur la 4G : rsrq 20
            # (-9,5 dB), rsrp 70 (-71 dBm) ; sur la 2G : rxlev 24.
            if ub.endswith("=?"):
                self.out("+CESQ: (0-63,99),(0-7,99),(0-96,255),(0-49,255),(0-34,255),(0-97,255)")
                self.ok(); return
            if self.rat() == "lte":
                self.out("+CESQ: 99,99,255,255,20,70")
            else:
                self.out("+CESQ: %d,99,255,255,255,255" % (24 if st["up"] else 99))
            self.ok(); return

        if ub.startswith("+GTRNDIS"):
            # LE PORTEUR ECM DE FIBOCOM (voir +CGMI). ModemManager sonde
            # AT+GTRNDIS=? a l initialisation ; si on repond, et qu il a un
            # port reseau groupe avec ce port AT, la data ne passe plus par
            # PPP : +GTRNDIS=1,<cid> « connecte », +GTRNDIS=0,<cid> coupe,
            # +GTRNDIS? donne l etat, et l adresse vient par DHCP sur le port
            # reseau (dnsmasq dans l espace de srsUE, tools/osmo-pmos-data.sh).
            if ub.endswith("=?"):
                self.out("+GTRNDIS: (0,1),(1-11)"); self.ok(); return
            if ub.endswith("?"):
                self.out("+GTRNDIS: %d,%d" % (1 if self.data_cid else 0, self.data_cid or 1))
                self.ok(); return
            m = re.match(r'\+GTRNDIS=(\d)(?:,(\d+))?', ub)
            if not m:
                self.err(); return
            cid = int(m.group(2) or 1)
            if m.group(1) == "1":
                if not LTE.state()["ok"] and not st["up"]:
                    log("data : +GTRNDIS refuse, aucun reseau")
                    self.err(30)                 # 30 = pas de service reseau
                    return
                self.data_cid = cid
                log("data : porteur ECM connecte (cid %d, APN %s) - l adresse vient par DHCP "
                    "sur le port reseau, la data passe par %s"
                    % (cid, LTE.state()["apn"], "la 4G (srsUE)" if self.rat() == "lte" else "la 2G"))
            else:
                self.data_cid = 0
                log("data : porteur ECM coupe (cid %d)" % cid)
            self.ok(); return

        if ub == "+CGDCONT?":
            # Le contexte PDP : l APN est celui de srsEPC (epc.conf), la donnee
            # du telephone est sur la 4G - meme si, sans PPP, le systeme ne
            # peut pas l activer par ce port (voir ATD*99).
            self.out('+CGDCONT: 1,"IP","%s","0.0.0.0",0,0' % LTE.state()["apn"])
            self.ok(); return
        if ub == "+CGATT?":
            self.out("+CGATT: %d" % (1 if (LTE.state()["ok"] or st["up"]) else 0))
            self.ok(); return
        if ub == "+CGACT?":
            self.out("+CGACT: 1,%d" % (1 if (self.data_cid or self.ppp) else 0)); self.ok(); return
        if ub == "+CGACT=?":
            self.out("+CGACT: (0,1)"); self.ok(); return
        if ub.startswith("+CEMODE"):
            # Le mode d exploitation EPS (24.301 § 4.3) : 1 = « CS/PS mode 1,
            # voice centric » - le telephone qui redescend en 2G pour parler.
            # C est exactement ce banc.
            if ub.endswith("=?"):
                self.out("+CEMODE: (0-3)")
            elif ub.endswith("?"):
                self.out("+CEMODE: 1")
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
            if not num.startswith("*99") and ("*" in num or "#" in num):
                # [2026-09-08] UN CODE USSD N EST PAS UN APPEL. Le composeur
                # de Phosh envoie « *#100# » en ATD : on le lancait dans
                # Asterisk, on descendait en 2G, et on essayait de faire
                # decrocher le mobile pour rien. Refuse (27.007 : operation
                # non permise) ; l USSD passe par AT+CUSD, plus bas.
                log("ATD%s : code USSD/SS, pas un appel - refuse" % num)
                self.err(3); return
            if num.startswith("*99"):
                # ATD*99***<cid># : la DATA, par PPP sur ce port (voir la
                # classe Ppp). On repond CONNECT et le port passe en mode
                # donnees : NetworkManager lance pppd dans le telephone, et
                # c est nous qui tenons l autre bout. Le noyau du telephone
                # doit avoir ppp_generic/ppp_async (compiles pour lui, voir
                # tools/osmo-pmos.sh) - sans eux pppd meurt et le port
                # revient en AT tout seul (Ppp.feed reconnait un « AT »).
                if not LTE.state()["ok"] and not st["up"]:
                    log("data : ATD%s refuse, aucun reseau" % num)
                    self.err(30)                 # 30 = pas de service reseau
                    return
                # [2026-09-08] PAS DE DATA PENDANT UN SERVICE CS. Sur la 2G,
                # un mobile en appel n a pas de data (classe B) ; et ici, avec
                # UN SEUL port, accepter ATD*99 en plein appel remettait le
                # port en mode donnees : le NO CARRIER du correspondant qui
                # raccroche et le +CEREG du retour sur la 4G restaient retenus
                # derriere le PPP - ecran d appel fige, telephone bloque en
                # 2G. NetworkManager reessaie de lui-meme apres le service.
                if DATA is None and self.cs_actif():
                    log("data : ATD%s refuse le temps du service CS (CSFB)" % num)
                    self.out("NO CARRIER")
                    return
                m = re.search(r"\*\*\*(\d+)#", num)
                self.data_cid = int(m.group(1)) if m else 1
                log("data : ATD%s -> CONNECT, PPP sur le port AT (cid %d, APN %s), par %s"
                    % (num, self.data_cid, LTE.state()["apn"],
                       "la 4G (srsUE)" if self.rat() == "lte" else "la 2G"))
                self.out("CONNECT")
                self.port_commande = False
                self.ppp = Ppp(self)
                self.ppp.demarrer()
                return
            # CSFB : l appel se fait sur la 2G. On descend AVANT de composer,
            # comme un vrai UE quitte la LTE sur l Extended Service Request.
            self.csfb_debut("appel vers %s" % num, couper_data=(DATA is None))
            # « origine » = le nom de DEMANDE du canal Local (« Local/600@internal »),
            # qu Asterisk decline en « ...-0000000b;1 » et « ;2 ». C est par lui
            # qu on reconnait nos propres jambes dans les evenements AMI
            # (cf. est_notre_jambe) ; « channel » sera remplace par le vrai nom.
            # [2026-09-07] NOTE AVANT DE COMPOSER, PAS APRES. L appel etait
            # ajoute a la liste au retour d ami_originate ; or les evenements
            # AMI arrivent sur une AUTRE connexion (AmiEcoute) et le DialBegin
            # de notre seconde jambe (Exten 100101) peut precéder ce retour :
            # est_notre_jambe ne trouvait rien, entrant() sonnait le telephone
            # avec son propre numero, et le NO CARRIER qui suivait fermait
            # l appel qu on venait de passer. Releve dans la trace AT :
            # « ATD600; » puis RING +CLIP "100101" et NO CARRIER dans la ms.
            chan = "Local/%s@%s" % (num, CTX)
            appel = {"num": num, "state": "active", "channel": chan, "origine": chan}
            self.calls.append(appel)
            ok, detail = ami_originate(num)
            if not ok:
                log("appel vers %s refuse : %s" % (num, detail))
                if appel in self.calls:
                    self.calls.remove(appel)
                self.csfb_fin_apres()
                self.err(); return
            log("appel vers %s etabli par Asterisk" % num)
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
            self.csfb_fin_apres()       # plus rien en CS : retour sur la 4G
            self.ok(); return

        if ub.startswith("+CUSD=1,"):
            # USSD, un minimum : *#100# rend le numero de l abonne (comme sur
            # le mobile osmocom-bb) ; tout autre code est « libere par le
            # reseau » (+CUSD: 2), sans erreur ni descente en 2G.
            m = re.search(r'"([^"]*)"', body)
            code = m.group(1) if m else ""
            self.ok()
            if code.replace("*", "").replace("#", "") == "100":
                self.out('+CUSD: 0,"Votre numero : %s",15' % MSISDN)
            else:
                log("USSD %s : pas de service, on libere" % code)
                self.out("+CUSD: 2")
            return
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


INBOX_DERNIER = [0]            # le dernier index attribue (voir inbox_ranger)


def inbox_ranger(sender, text, pdu):
    """Range un SMS et rend son index, comme une memoire « SM ».

    [2026-09-08] LES INDEX TOURNENT. On reprenait l index 1 des que le
    telephone l avait efface (AT+CMGD=1) ; or ModemManager garde parfois ce
    message dans SA liste - son effacement a echoue chez lui (« SMS storage
    currently locked, try again later ») bien que le modem ait dit OK - et un
    +CMTI sur un index qu il croit deja connu est ignore : le SMS suivant
    passait a la trappe, une fois sur deux ou trois. On prend donc toujours
    l index libre SUIVANT, en tournant sur les 20 : un index n est repris
    qu apres 19 autres."""
    with INBOX_LOCK:
        pris = {m["idx"] for m in INBOX}
        if len(pris) >= INBOX_MAX:
            INBOX.pop(0)       # boite pleine : le plus ancien cede la place
            pris = {m["idx"] for m in INBOX}
        idx = INBOX_DERNIER[0]
        for _ in range(INBOX_MAX):
            idx = idx % INBOX_MAX + 1
            if idx not in pris:
                break
        INBOX_DERNIER[0] = idx
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
# [2026-09-08] LE MODEM A DEUX PORTS. Sur un seul port, une fois ATD*99
# passe, plus rien ne circule en AT : le telephone ne peut ni appeler ni
# envoyer un SMS tant que la data est montee (« No AT port available »), et
# les entrants n arrivent qu en coupant le PPP. Un vrai modem a un port de
# commande et un port de donnees. Ici aussi, desormais : CURRENT tient le
# port de commande (hvc0, URC, appels, SMS) ; DATA tient le port de donnees
# (hvc1, celui que ModemManager marque ID_MM_PORT_TYPE_AT_PPP et sur lequel il
# compose ATD*99). Les deux sont des AtHandler sur le meme etat du banc ; le
# port de donnees renvoie sur CURRENT pour ce qui est l etat du telephone
# (technologie, appel en cours). Sans --data, on reste en port unique.
DATA = None                    # le port de donnees, s il y en a un


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

    def __init__(self, sock, addr, role="commande"):
        # StreamRequestHandler.setup() attend self.request et fabrique lui-meme
        # connection/rfile/wfile : on lui donne juste la douille.
        self.role = role
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


def connect_to(dest, role="commande"):
    """dest = « hote:port » : on se connecte et on tient le modem sur ce lien."""
    host, _, port = dest.rpartition(":")
    temoin = int(os.environ.get("OSMO_VM_READY_PORT", "2222"))
    deja_dit = False
    while True:
        if temoin and not vm_prete(temoin):
            log("la VM n est pas prete (port %d ferme) - on patiente" % temoin)
            while not vm_prete(temoin):
                time.sleep(5)
            log("VM prete")
        try:
            s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=10)
        except OSError as e:
            if not deja_dit:
                log("connexion a %s (port de %s) impossible (%s) - on reessaie toutes les 5 s"
                    % (dest, role, e))
                deja_dit = True
            time.sleep(5)
            continue
        deja_dit = False
        # [2026-09-07] LE DELAI SERT A SE CONNECTER, PAS A TENIR LE LIEN.
        # create_connection(timeout=10) laisse ce delai SUR la douille : la
        # lecture suivante levait socket.timeout apres dix secondes de silence,
        # handle() rendait la main et le modem se debranchait tout seul. Or un
        # modem se tait la plupart du temps - ModemManager ne l interroge que
        # par a-coups. D ou des appels qui marchent puis disparaissent, et la
        # ronde « oFono s est deconnecte / lien ferme » dans ce journal. On
        # repasse donc en bloquant, comme le lien SMPP plus haut.
        s.settimeout(None)
        log("connecte a %s (port de %s)" % (dest, role))
        try:
            ClientHandler(s, (host, int(port)), role)
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
    LTE.resume()
    if SMPP_ON:
        Smpp(on_smpp_sms).start()
    AmiEcoute().start()
    data = None
    for i, a in enumerate(sys.argv):
        if a == "--data" and i + 1 < len(sys.argv):
            data = sys.argv[i + 1]
    for i, a in enumerate(sys.argv):
        if a == "--connect" and i + 1 < len(sys.argv):
            boite_entree(SMS_IN_CONNECT)
            if data:
                threading.Thread(target=connect_to, args=(data, "data"), daemon=True).start()
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
