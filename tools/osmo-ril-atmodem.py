#!/usr/bin/env python3
# osmo-ril-atmodem.py - LE MODEM AT VIRTUEL QUI BRANCHE oFono SUR LE RIL.
#
# LA CHAINE, ET LE TROU QU ON BOUCHE ICI.
#
#   Android → rild → libreference-ril.so → port serie AT → CE PROGRAMME → oFono → banc
#
# libreference-ril.so (deja presente dans l image Waydroid, /vendor/lib64) ne
# sait parler qu a un modem AT : elle ouvre un port serie et y envoie du 3GPP
# 27.007 (AT+CFUN, AT+CREG?, ATD..., AT+CMGS...). oFono, lui, n est pas un
# modem : c est un consommateur de modem, avec une API D-Bus. Les deux ne se
# rencontrent donc jamais - sauf si quelqu un TIENT LE ROLE DU MODEM. C est ce
# que fait ce programme : il ouvre un pseudo-terminal, se comporte comme un
# modem 27.007 vu du port, et execute chaque commande sur oFono.
#
#   AT+CREG?        <- l etat d enregistrement lu sur org.ofono.NetworkRegistration
#   ATD100102;      <- org.ofono.VoiceCallManager.Dial
#   ATA / ATH       <- Answer / HangupAll
#   AT+CLCC         <- la liste des appels en cours (GetCalls)
#   AT+CMGS         <- org.ofono.MessageManager.SendMessage
#   +CMTI / RING    <- pousses vers le RIL quand oFono signale un SMS ou un appel
#
# CE QU IL MANQUE ENCORE, ET IL FAUT LE DIRE : l image Waydroid n embarque PAS
# le binaire rild (verifie : rien dans /system/bin ni /vendor/bin/hw, aucun
# service HAL radio, aucun .rc qui le lance). Ce programme est donc la moitie
# aval de la chaine, complete et testable seule (on peut lui parler a la main
# sur le pty), mais il faudra un rild - celui du pack Quectel, ou un rild AOSP
# construit pour x86_64 - pour que Android s y branche. tools/osmo-waydroid.sh
# (ril-install) pose le reste : service init, manifeste VINTF, permissions.
#
# Reglages :
#   OSMO_RIL_DIR      ou publier le lien vers le pty (defaut /run/osmo-ril)
#   OSMO_OFONO_MODEM  le modem oFono a piloter (defaut : le premier trouve)
#   OSMO_AT_ECHO      1 pour repondre en echo des le depart (ATE1)
import os
import pty
import re
import sys
import termios
import time
import tty

from gi.repository import Gio, GLib

RUN = os.environ.get("OSMO_RIL_DIR", "/run/osmo-ril")
LINK = os.path.join(RUN, "at-pty")
MODEM = os.environ.get("OSMO_OFONO_MODEM", "")
# [2026-09-06] LE JOURNAL DU PORT AT. Tout ce qui passe entre le RIL d Android
# et ce modem, dans les deux sens, horodate a la milliseconde. C est l outil
# pour voir OU une sequence s arrete - une commande a laquelle on repond mal
# bloque tout le reste en silence. « tail -f /var/log/osmo-at.log » pendant qu on
# manipule Android.
AT_LOG = os.environ.get("OSMO_AT_LOG", "/var/log/osmo-at.log")

OFONO = "org.ofono"
IF_MANAGER = "org.ofono.Manager"
IF_MODEM = "org.ofono.Modem"
IF_SMS = "org.ofono.MessageManager"
IF_VOICE = "org.ofono.VoiceCallManager"
IF_CALL = "org.ofono.VoiceCall"
IF_NETREG = "org.ofono.NetworkRegistration"
IF_SIM = "org.ofono.SimManager"


def log(*a):
    print("[at]", *a, flush=True)


_atlog = None


def atlog(sens, texte):
    """sens : '<' ce que le RIL envoie, '>' ce que le modem repond."""
    global _atlog
    if _atlog is None:
        try:
            _atlog = open(AT_LOG, "a", buffering=1)   # ligne par ligne : direct
            os.chmod(AT_LOG, 0o644)                   # lisible sans etre root
        except OSError as e:
            print("[at] journal %s impossible : %s" % (AT_LOG, e), file=sys.stderr)
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


# ── oFONO ───────────────────────────────────────────────────────────────────
class Ofono:
    """Le strict necessaire d oFono, en Gio (pas de dbus-python sur l image)."""

    def __init__(self):
        self.c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.modem = MODEM or self._first_modem()

    def _first_modem(self):
        try:
            modems = self.call("/", IF_MANAGER, "GetModems").unpack()[0]
        except GLib.Error:
            return ""
        return modems[0][0] if modems else ""

    def call(self, path, iface, method, params=None, timeout=20000):
        return self.c.call_sync(OFONO, path, iface, method, params, None,
                                Gio.DBusCallFlags.NONE, timeout, None)

    def props(self, iface, path=None):
        try:
            return self.call(path or self.modem, iface, "GetProperties").unpack()[0]
        except GLib.Error:
            return {}

    def calls(self):
        try:
            return self.call(self.modem, IF_VOICE, "GetCalls").unpack()[0]
        except GLib.Error:
            return []

    def subscribe(self, iface, signal, cb, path=None):
        return self.c.signal_subscribe(OFONO, iface, signal, path, None,
                                       Gio.DBusSignalFlags.NONE, cb)


# ── LE MODEM VU DU PORT SERIE ───────────────────────────────────────────────
# Les etats 27.007 attendus par le RIL. On traduit ce que dit oFono.
_CREG_STATE = {"unregistered": 0, "registered": 1, "searching": 2,
               "denied": 3, "unknown": 4, "roaming": 5}


class AtModem:
    def __init__(self, ofono, fd):
        self.o = ofono
        self.fd = fd
        self.buf = b""
        self.echo = os.environ.get("OSMO_AT_ECHO") == "1"
        self.cmee = 0
        self.creg_mode = 0          # 0 = pas d URC, 1/2 = URC d enregistrement
        self.cmgf = 0               # 0 = PDU (ce que veut le RIL), 1 = texte
        self.sms_target = None      # numero en attente entre AT+CMGS et le ^Z

    # -- ecriture vers le RIL
    def send(self, text):
        atlog(">", text)
        try:
            os.write(self.fd, ("\r\n%s\r\n" % text).encode())
        except OSError as e:
            log("ecriture impossible :", e)

    def ok(self):
        self.send("OK")

    def err(self, code=100):
        self.send("+CME ERROR: %d" % code if self.cmee else "ERROR")

    # -- lecture depuis le RIL
    def feed(self, data):
        if self.echo:
            try:
                os.write(self.fd, data)
            except OSError:
                pass
        self.buf += data
        while True:
            m = re.search(rb"[\r\n\x1a]", self.buf)
            if not m:
                return
            line, self.buf = self.buf[:m.start()], self.buf[m.end():]
            end = self.buf[m.start():m.end()] if False else m.group()
            text = line.decode(errors="replace").strip()
            if text:
                atlog("<", text)
            if end == b"\x1a" or self.sms_target is not None:
                self.on_sms_body(text, submitted=(end == b"\x1a"))
            elif text:
                self.on_line(text)

    # -- le corps d un SMS, entre AT+CMGS=... et Ctrl-Z
    def on_sms_body(self, text, submitted):
        if not submitted:
            return                      # on attend encore le Ctrl-Z
        num, self.sms_target = self.sms_target, None
        if not num:
            self.err()
            return
        try:
            self.o.call(self.o.modem, IF_SMS, "SendMessage",
                        GLib.Variant("(ss)", (num, text)))
            self.send("+CMGS: 1")
            self.ok()
            log("SMS envoye a %s" % num)
        except GLib.Error as e:
            log("envoi refuse :", e.message.split(":")[-1].strip())
            self.err()

    # -- une commande AT
    def on_line(self, line):
        cmd = line.upper()
        if not cmd.startswith("AT"):
            return
        body = line[2:]
        ub = cmd[2:]

        # les basiques que le RIL envoie au demarrage
        if ub in ("", "&F", "Z", "E0", "E1", "+CMEE=1", "+CMEE=2", "V1", "Q0",
                  "S0=0", "+CSCS=\"UCS2\"", "+CSCS=\"IRA\"", "+CMGF=0",
                  "+CNMI=1,2,0,1,0", "+CGEREP=1,0", "+CLIP=1", "+COLP=0",
                  "+CSSN=0,0", "+CSNS=0", "+CMOD=0"):
            if ub == "E0":
                self.echo = False
            elif ub == "E1":
                self.echo = True
            elif ub.startswith("+CMEE"):
                self.cmee = 1
            elif ub == "+CMGF=0":
                self.cmgf = 0
            self.ok()
            return

        # identite du modem : ce que le RIL affiche dans « a propos »
        if ub in ("+CGMI", "+GMI"):
            self.send("Osmocom"); self.ok(); return
        if ub in ("+CGMM", "+GMM"):
            self.send("osmo-ril-atmodem"); self.ok(); return
        if ub in ("+CGMR", "+GMR"):
            self.send("1.0"); self.ok(); return
        if ub in ("+CGSN", "+GSN"):
            self.send(self.o.props(IF_MODEM).get("Serial", "000000000000000"))
            self.ok(); return

        # la SIM
        if ub == "+CPIN?":
            sim = self.o.props(IF_SIM)
            self.send("+CPIN: READY" if sim.get("Present", True) else "+CME ERROR: 10")
            self.ok(); return
        if ub == "+CIMI":
            self.send(self.o.props(IF_SIM).get("SubscriberIdentity", "001010000000000"))
            self.ok(); return
        if ub.startswith("+CRSM") or ub.startswith("+CCID") or ub.startswith("+CSIM"):
            self.err(); return       # le RIL sait s en passer

        # la radio
        if ub.startswith("+CFUN"):
            if ub.endswith("?"):
                on = self.o.props(IF_MODEM).get("Online", False)
                self.send("+CFUN: %d" % (1 if on else 4))
                self.ok(); return
            want = ub.rstrip().endswith("1")
            try:
                self.o.call(self.o.modem, IF_MODEM, "SetProperty",
                            GLib.Variant("(sv)", ("Online", GLib.Variant("b", want))))
            except GLib.Error as e:
                log("CFUN refuse :", e.message.split(":")[-1].strip())
            self.ok(); return

        # l enregistrement reseau
        if ub.startswith("+CREG") or ub.startswith("+CGREG") or ub.startswith("+CEREG"):
            tag = "+CREG" if ub.startswith("+CREG") else ("+CGREG" if ub.startswith("+CGREG") else "+CEREG")
            if "=" in ub:
                try:
                    self.creg_mode = int(ub.split("=")[1][0])
                except (ValueError, IndexError):
                    self.creg_mode = 0
                self.ok(); return
            net = self.o.props(IF_NETREG)
            st = _CREG_STATE.get(str(net.get("Status", "unknown")), 4)
            lac = int(net.get("LocationAreaCode", 0) or 0)
            cid = int(net.get("CellId", 0) or 0)
            if self.creg_mode >= 2:
                self.send("%s: %d,%d,\"%04X\",\"%08X\"" % (tag, self.creg_mode, st, lac, cid))
            else:
                self.send("%s: %d,%d" % (tag, self.creg_mode, st))
            self.ok(); return

        if ub.startswith("+COPS"):
            net = self.o.props(IF_NETREG)
            if ub.endswith("?"):
                self.send("+COPS: 0,0,\"%s\",0" % net.get("Name", "Osmocom"))
            self.ok(); return

        if ub.startswith("+CSQ"):
            # oFono donne une force en %, le 27.007 attend 0..31
            pct = int(net_strength(self.o))
            self.send("+CSQ: %d,99" % min(31, round(pct * 31 / 100)))
            self.ok(); return

        # les appels
        if cmd.startswith("ATD") and (cmd.endswith(";") or ";" in cmd):
            num = re.sub(r"[^0-9+*#]", "", body.split(";")[0][1:])
            try:
                self.o.call(self.o.modem, IF_VOICE, "Dial",
                            GLib.Variant("(ss)", (num, "default")))
                self.ok()
                log("appel vers %s" % num)
            except GLib.Error as e:
                log("appel refuse :", e.message.split(":")[-1].strip())
                self.err()
            return
        if ub == "A":
            for path, props in self.o.calls():
                if props.get("State") == "incoming":
                    try:
                        self.o.call(path, IF_CALL, "Answer")
                    except GLib.Error:
                        pass
            self.ok(); return
        if ub in ("H", "+CHUP") or ub.startswith("+CHLD"):
            try:
                self.o.call(self.o.modem, IF_VOICE, "HangupAll")
            except GLib.Error:
                pass
            self.ok(); return
        if ub == "+CLCC":
            for i, (path, props) in enumerate(self.o.calls(), start=1):
                st = {"active": 0, "held": 1, "dialing": 2, "alerting": 3,
                      "incoming": 4, "waiting": 5}.get(props.get("State", ""), 6)
                direction = 1 if props.get("State") in ("incoming", "waiting") else 0
                num = props.get("LineIdentification", "")
                self.send("+CLCC: %d,%d,%d,0,0,\"%s\",129" % (i, direction, st, num))
            self.ok(); return

        # les SMS
        if ub.startswith("+CMGS="):
            # En mode texte le numero est entre guillemets ; en PDU le RIL
            # envoie une longueur, et le numero est dans le PDU - non gere ici
            # (le pont oFono s en charge tant qu on n a pas de rild).
            m = re.search(r'"([^"]+)"', body)
            if m:
                self.sms_target = m.group(1)
                try:
                    os.write(self.fd, b"\r\n> ")
                except OSError:
                    pass
                return
            self.err(); return
        if ub.startswith("+CMGF"):
            self.cmgf = 1 if ub.rstrip().endswith("1") else 0
            self.ok(); return
        if ub.startswith("+CSCA"):
            self.send("+CSCA: \"\",129"); self.ok(); return

        # ── CE QUE LE RIL D ANDROID DEMANDE A L INITIALISATION ──────────
        # [2026-09-06] Releve sur le banc, la premiere fois que osmo-rild a
        # ouvert ce port : ATE0Q0V1, AT+CTEC?, AT+WNAM, AT+CCWA=1, AT+CMUT=0,
        # AT+CSSN=0,1, AT+CSCS="HEX", AT+CUSD=1... Tant qu on refusait tout ca,
        # libreference-ril restait bloquee au tout debut de sa sequence et ne
        # publiait jamais son interface - le framework ne voyait donc aucun
        # service radio.
        if ub in ("E0Q0V1", "E1Q0V1", "Q0V1", "E0V1"):
            self.echo = ub.startswith("E1")
            self.ok(); return
        if ub.startswith("+CTEC"):
            # « current technology » du reference-ril : 0 = GSM, ce que le banc
            # fait effectivement.
            self.send("+CTEC: 0,1" if ub.endswith("?") else "+CTEC: 0")
            self.ok(); return
        if ub.startswith("+WNAM"):
            self.send('+WNAM: "%s"' % (self.o.props(IF_NETREG).get("Name") or "Osmocom"))
            self.ok(); return
        if ub.startswith("+CSCS"):
            if ub.endswith("=?"):
                self.send('+CSCS: ("IRA","GSM","UCS2","HEX")')
            elif ub.endswith("?"):
                self.send('+CSCS: "HEX"')
            self.ok(); return

        # Meme regle que le modem cote oFono (tools/osmo-phonesim-banc.py) :
        # une AFFECTATION est acceptee - un modem qui accepte un reglage sans
        # l appliquer ne raconte rien de faux ; une LECTURE inconnue est
        # refusee, parce qu une reponse inventee ferait croire a une capacite
        # qui n existe pas.
        if "=" in ub and not ub.endswith("=?"):
            log("reglage accepte sans effet : %s" % line)
            self.ok(); return

        log("lecture non geree (refusee) : %s" % line)
        self.err()

    # ── les evenements d oFono pousses vers le RIL ───────────────────────────
    def on_incoming_sms(self, _c, _s, _p, _i, _sig, params):
        info = params[1]
        log("SMS entrant de %s" % info.get("Sender", "?"))
        self.send("+CMTI: \"SM\",1")

    def on_call_added(self, _c, _s, _p, _i, _sig, params):
        props = params[1]
        if props.get("State") == "incoming":
            num = props.get("LineIdentification", "")
            self.send("+CLIP: \"%s\",129" % num)
            self.send("RING")

    def on_netreg_changed(self, _c, _s, _p, _i, _sig, params):
        if self.creg_mode and params[0] in ("Status", "CellId", "LocationAreaCode"):
            net = self.o.props(IF_NETREG)
            st = _CREG_STATE.get(str(net.get("Status", "unknown")), 4)
            self.send("+CREG: %d" % st)


# ── LE MODEM D ESSAI ────────────────────────────────────────────────────────
# Sans modem oFono (banc arrete, EC25 debranche), le programme n aurait rien a
# piloter et sortirait aussitot - impossible de mettre au point le dialogue AT
# ni de verifier ce que le RIL recevra. --essai remplace donc oFono par des
# reponses par defaut : le modem repond comme un modem eteint mais poli
# (CFUN 0, CREG 0, aucun appel), et TOUTE commande d action est journalisee au
# lieu d etre executee. C est un banc d essai pour la mecanique, jamais un
# substitut au vrai chemin.
class OfonoEssai:
    modem = "/essai/modem0"

    def props(self, iface, path=None):
        if iface == IF_SIM:
            return {"Present": True, "SubscriberIdentity": "001010000000001"}
        if iface == IF_NETREG:
            return {"Status": "unregistered", "Name": "Osmocom", "Strength": 0}
        if iface == IF_MODEM:
            return {"Online": False, "Serial": "000000000000001"}
        return {}

    def calls(self):
        return []

    def call(self, path, iface, method, params=None, timeout=20000):
        log("[essai] %s.%s ignore" % (iface.rsplit(".", 1)[-1], method))
        return GLib.Variant("()", ())

    def subscribe(self, *a, **kw):
        return 0


def net_strength(o):
    return o.props(IF_NETREG).get("Strength", 0) or 0


def main():
    essai = "--essai" in sys.argv or os.environ.get("OSMO_AT_ESSAI") == "1"
    o = None
    if not essai:
        try:
            o = Ofono()
        except GLib.Error as e:
            print("[at] bus systeme injoignable : %s" % e, file=sys.stderr)
            return 1
        if not o.modem:
            print("[at] aucun modem oFono (ofonod demarre ? modem branche ?)\n"
                  "[at] --essai pour ouvrir quand meme un modem de mise au point",
                  file=sys.stderr)
            return 1
        log("modem oFono", o.modem)
    else:
        o = OfonoEssai()
        log("MODE ESSAI : aucun oFono derriere, reponses par defaut")

    master, slave = pty.openpty()
    name = os.ttyname(slave)
    tty.setraw(master)
    # Le RIL ouvrira le lien stable, pas le /dev/pts/N du jour.
    os.makedirs(RUN, exist_ok=True)
    try:
        if os.path.islink(LINK) or os.path.exists(LINK):
            os.remove(LINK)
        os.symlink(name, LINK)
    except OSError as e:
        log("lien %s non pose : %s" % (LINK, e))
    log("modem AT virtuel sur %s (lien : %s)" % (name, LINK))
    log("a donner a rild :  rild -l /vendor/lib64/libreference-ril.so -d %s" % LINK)

    m = AtModem(o, master)
    o.subscribe(IF_SMS, "IncomingMessage", m.on_incoming_sms, path=o.modem)
    o.subscribe(IF_VOICE, "CallAdded", m.on_call_added, path=o.modem)
    o.subscribe(IF_NETREG, "PropertyChanged", m.on_netreg_changed, path=o.modem)

    def readable(_src, _cond):
        try:
            data = os.read(master, 4096)
        except OSError:
            return True
        if data:
            m.feed(data)
        return True

    GLib.io_add_watch(master, GLib.IO_IN, readable)
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
