#!/usr/bin/env python3
# osmo-dongle-passerelle.py - THE REAL NETWORK, FOR THE postmarketOS PHONE.
#
# THE CHAIN:
#
#   postmarketOS VM -> ModemManager -> AT over the PCI serial port
#        -> osmo-phonesim-banc.py --connect           (the bench modem)
#              | number of the bench   -> osmo-msc VTY (unchanged)
#              | number outside        -> THIS PROGRAM (127.0.0.1:12350)
#                                            -> AT+CMGS on a Huawei dongle
#                                            -> real operator (Free: 3G/4G, no 2G)
#
#   real operator -> dongle (+CMTI) -> THIS PROGRAM
#        -> scripts/sms_notify.py -> SMS inboxes of the bench modems
#           (12348 Android/oFono, 12349 postmarketOS VM) -> +CMTI on the phone
#
# The dongle is the INTERCONNECT POINT of the bench: a commercial UE, closed
# firmware, used for what it is - a door onto the public network - and never
# presented as the phone. The phone stays the VM; the bench stays the operator.
#
# THE OUTBOUND PROTOCOL (what osmo-phonesim-banc.py sends): one JSON line
#   {"to": "+33612345678", "text": "..."}
# answered by one JSON line
#   {"ok": true, "mr": "12"}   or   {"ok": false, "error": "..."}
#
# TWO BACKENDS, ONE OWNER OF THE DONGLE.
#   at        (default) this program holds the AT port: SMS only, no voice.
#   asterisk  chan_dongle holds the dongle (voice + SMS, configs/dongle.conf):
#             outbound SMS go through the AMI (DongleSendSMS), inbound SMS
#             reach the modems through [dongle_in] of extensions.conf, so
#             this program only serves the outbound port.
#
# Settings:
#   OSMO_DONGLE_BACKEND  at | asterisk                   (default at)
#   OSMO_DONGLE_DEV      chan_dongle device              (default dongle0)
#   OSMO_AMI_HOST/PORT/USER/PASSWORD  as osmo-phonesim-banc.py
#   OSMO_DONGLE_AT       AT (PCUI) port of the dongle    (default /dev/ttyUSB2)
#   OSMO_DONGLE_PIN      SIM PIN, if any
#   OSMO_DONGLE_SMSC     force the SMSC address (normally on the SIM)
#   OSMO_DONGLE_PORT     outbound listening port         (default 12350)
#   OSMO_DONGLE_IMSI     bench subscriber receiving the inbound SMS
#                        (default: empty = every bench modem)
#   OSMO_SMS_NOTIFY      the modem inboxes (see scripts/sms_notify.py)
#
# Usage:
#   tools/osmo-dongle-passerelle.py            # holds the line
#   tools/osmo-dongle-passerelle.py --essai    # no dongle: outbound SMS logged only
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "scripts"))

from sms_notify import notifier  # noqa: E402

AT_PORT = os.environ.get("OSMO_DONGLE_AT", "/dev/ttyUSB2")
PIN = os.environ.get("OSMO_DONGLE_PIN") or None
SMSC = os.environ.get("OSMO_DONGLE_SMSC") or None
LISTEN = ("127.0.0.1", int(os.environ.get("OSMO_DONGLE_PORT", "12350")))
DEST_IMSI = os.environ.get("OSMO_DONGLE_IMSI", "")


def log(*a):
    print("[dongle]", *a, flush=True)


class Essai:
    """No dongle: the outbound path can still be checked end to end."""

    def cmd_prompt(self, c, payload, timeout=60):
        log("[essai] %s / %s" % (c, payload))
        return ["+CMGS: 0"]


BACKEND = os.environ.get("OSMO_DONGLE_BACKEND", "at")
DONGLE_DEV = os.environ.get("OSMO_DONGLE_DEV", "dongle0")
AMI = (os.environ.get("OSMO_AMI_HOST", "127.0.0.1"),
       int(os.environ.get("OSMO_AMI_PORT", "5038")))
AMI_USER = os.environ.get("OSMO_AMI_USER", "osmo")
AMI_PASS = os.environ.get("OSMO_AMI_PASSWORD", "osmocom1")


class Ami:
    """chan_dongle owns the dongle: an SMS is one AMI action."""

    def _bloc(self, f):
        d = {}
        while True:
            l = f.readline()
            if not l:
                raise OSError("AMI ferme")
            l = l.rstrip("\r\n")
            if not l:
                if d:
                    return d
                continue
            k, _, v = l.partition(":")
            d[k.strip()] = v.strip()

    def _action(self, f, s, **kw):
        s.sendall(("".join("%s: %s\r\n" % kv for kv in kw.items()) + "\r\n").encode())
        while True:
            b = self._bloc(f)
            if b.get("ActionID") == kw.get("ActionID") and "Response" in b:
                return b

    def cmd_prompt(self, c, payload, timeout=60):
        to = re.search(r'"([^"]+)"', c).group(1)
        s = socket.create_connection(AMI, timeout=timeout)
        try:
            f = s.makefile("r", encoding="utf-8", errors="replace", newline="\r\n")
            f.readline()                                   # banner
            r = self._action(f, s, Action="Login", Username=AMI_USER,
                             Secret=AMI_PASS, Events="off", ActionID="l")
            if r["Response"] != "Success":
                raise RuntimeError("AMI : %s" % r.get("Message"))
            # an AMI header is one line: line breaks of the SMS become spaces
            r = self._action(f, s, Action="DongleSendSMS", Device=DONGLE_DEV,
                             Number=to, Message=re.sub(r"[\r\n]+", " ", payload),
                             ActionID="sms")
            self._action(f, s, Action="Logoff", ActionID="o")
        finally:
            s.close()
        if r["Response"] != "Success":
            raise RuntimeError("chan_dongle : %s" % r.get("Message"))
        return ["+CMGS: %s" % r.get("ID", "?")]


class Passerelle:
    def __init__(self, essai=False):
        self.essai = essai
        if essai:
            self.m = Essai()
            return
        if BACKEND == "asterisk":
            self.m = Ami()
            return
        from huawei_at import Modem
        self.m = Modem(AT_PORT, verbose=os.environ.get("OSMO_DONGLE_VERBOSE") == "1")
        # Automatic mode: on Free there is no 2G, SMS go over 3G/4G.
        self.m.init(pin=PIN, force_2g=False)
        self.m.register(None)
        self.m.cmd("AT+CMGF=1")
        self.m.try_cmd('AT+CSCS="GSM"')
        self.m.try_cmd('AT+CPMS="SM","SM","SM"')
        if SMSC:
            self.m.cmd('AT+CSCA="%s",145' % SMSC)
        self.m.cmd("AT+CNMI=2,1,0,0,0")     # +CMTI: "SM",<idx>
        # What arrived while the gateway was down.
        for l in self.m.try_cmd('AT+CMGL="REC UNREAD"', timeout=20) or []:
            mm = re.match(r"\+CMGL:\s*(\d+)", l)
            if mm:
                self.lire(mm.group(1))

    # ── outbound: bench -> real network ─────────────────────────────────────
    def envoyer(self, to, text):
        r = self.m.cmd_prompt('AT+CMGS="%s"' % to, text, timeout=60)
        mr = next((l.split(":", 1)[1].strip() for l in r if l.startswith("+CMGS")), "?")
        log("SMS vers %s envoye (MR=%s)" % (to, mr))
        return mr

    # ── inbound: real network -> bench ──────────────────────────────────────
    def lire(self, idx):
        r = self.m.try_cmd("AT+CMGR=%s" % idx, timeout=10) or []
        if not r:
            return
        # +CMGR: "REC UNREAD","+33612345678",,"26/11/25,10:31:00+04"
        mm = re.match(r'\+CMGR:\s*"[^"]*","([^"]*)"', r[0])
        sender = mm.group(1) if mm else "?"
        text = "\n".join(r[1:])
        log("SMS de %s : %s" % (sender, text))
        n = notifier(DEST_IMSI, sender, text, log=log)
        if n:
            self.m.try_cmd("AT+CMGD=%s" % idx)   # delivered: free the SIM slot
        else:
            log("aucun modem du banc joignable : SMS garde sur la SIM (index %s)" % idx)

    def ecouter(self):
        while True:
            u = self.m.wait_urc(timeout=1)
            if not u:
                continue
            if u.startswith("+CMTI"):
                mm = re.match(r'\+CMTI:\s*"\w+",(\d+)', u)
                if mm:
                    self.lire(mm.group(1))
            elif u.startswith("RING") or u.startswith("+CLIP"):
                log("appel entrant ignore (voix : pas encore cablee) : %s" % u)


PASSERELLE = None


class Sortant(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            msg = json.loads(self.rfile.readline(65536).decode("utf-8", "replace"))
            to, text = str(msg["to"]), str(msg["text"])
            rep = {"ok": True, "mr": PASSERELLE.envoyer(to, text)}
        except Exception as e:                    # one bad SMS never kills the gateway
            log("envoi refuse : %s" % e)
            rep = {"ok": False, "error": str(e)}
        try:
            self.wfile.write((json.dumps(rep) + "\n").encode())
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global PASSERELLE
    essai = "--essai" in sys.argv
    try:
        PASSERELLE = Passerelle(essai)
    except Exception as e:
        log("dongle indisponible sur %s : %s" % (AT_PORT, e))
        log("--essai pour ouvrir la passerelle sans dongle")
        return 1
    srv = Server(LISTEN, Sortant)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log("sortant : en ecoute sur %s:%d" % LISTEN)
    if essai or BACKEND == "asterisk":
        log("MODE ESSAI : aucun dongle, les SMS sortants sont seulement journalises"
            if essai else "chan_dongle (%s) : SMS sortants par l'AMI, entrants par "
            "[dongle_in]" % DONGLE_DEV)
        while True:
            time.sleep(3600)
    log("entrant : SMS du reseau reel -> modems du banc")
    try:
        PASSERELLE.ecouter()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
