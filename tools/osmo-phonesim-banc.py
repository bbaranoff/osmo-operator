#!/usr/bin/env python3
# osmo-phonesim-banc.py - THE BENCH MODEM, AS SEEN BY oFONO.
#
# THE COMPLETE CHAIN, AND WHERE THIS FILE SITS IN IT:
#
#   Android → rild → libreference-ril.so → pty AT → osmo-ril-atmodem.py → oFono
#                                                                           ↑
#                                                   THIS PROGRAM (AT over TCP) ┘
#                                                            ↓
#                                            the bench: osmo-bsc / osmo-msc VTY
#
# oFono does not make a modem: it DRIVES one. On this bench there is no
# dongle, so oFono must be given something that behaves like a modem: that is
# the role of the phonesim plugin, which opens a TCP connection and speaks
# plain AT over it. This program holds the other end of that connection and
# answers by reading THE BENCH.
#
# Setting up:
#   1. /etc/ofono/phonesim.conf:
#          [osmo]
#          Address=127.0.0.1
#          Port=12345
#   2. this program (it must listen BEFORE ofonod looks for the modem)
#   3. systemctl restart ofono  ->  a modem appears in org.ofono.Manager
#
# What the modem reports comes from osmo-bsc (VTY 4242): the network (MCC/MNC,
# name), the ARFCN, the registration state. A stopped bench = a modem "not
# registered", which is the truth, not a failure.
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
# The osmocom-bb mobile. IT is subscriber 100101, and its audio bridge
# (gsm_audio / gsm_mic) is what the VM relays: without it, no voice.
#
# THE DEFAULT PORT IS A LIST, NOT A SINGLE VALUE. The QEMU fork mobile
# (mobile.cfg) binds 4247, the DSP bench one (c54x_exe/mobile_pont.cfg) binds
# 4347. Without OSMO_MOB_VTY_PORT, 4247 then 4347 are tried at every
# connection; when the variable is set, it is the only address tried.
_MOB_HOST = os.environ.get("OSMO_MOB_VTY_HOST", "127.0.0.1")
if os.environ.get("OSMO_MOB_VTY_PORT"):
    MOB_VTY = (_MOB_HOST, int(os.environ["OSMO_MOB_VTY_PORT"]))
else:
    MOB_VTY = [(_MOB_HOST, 4247), (_MOB_HOST, 4347)]
MS = os.environ.get("OSMO_MS_NAME", "1")
# The subscriber this modem EMBODIES: the one of the Android phone. On the
# bench it is 100101 (IMSI 001010001000001), as shown by "show subscriber
# msisdn 100101" on the osmo-msc VTY.
IMSI = os.environ.get("OSMO_MS_IMSI", "001010001000001")
MSISDN = os.environ.get("OSMO_MS_MSISDN", "100101")
# SMS reception goes through the osmo-msc SMPP server (port 2775): an ESME is
# already declared in the bench conf (esme msc_tester / osmocom1).
SMPP_HOST = os.environ.get("OSMO_SMPP_HOST", "127.0.0.1")
SMPP_PORT = int(os.environ.get("OSMO_SMPP_PORT", "2775"))
SMPP_ID = os.environ.get("OSMO_SMPP_ID", "msc_tester")
SMPP_PW = os.environ.get("OSMO_SMPP_PASSWORD", "osmocom1")
SMPP_ON = os.environ.get("OSMO_SMPP", "1") == "1"
# Does an incoming SMS ALSO go to the osmocom-bb mobile? Yes by default:
# Android and the mobile are the same bench subscriber, and both are wanted
# in parallel.
DUPLIQUE = os.environ.get("OSMO_SMS_DUPLIQUE", "1") == "1"
# The inboxes for SMS delivered by the bench gateway. This program runs
# TWICE (the Android modem in listen mode, the VM one in --connect mode): each
# needs its own port. scripts/sms_notify.py notifies them, and
# scripts/sms-interop-relay.py calls it.
SMS_IN_HOST = os.environ.get("OSMO_SMS_IN_HOST", "127.0.0.1")
SMS_IN_LISTEN = int(os.environ.get("OSMO_SMS_IN_PORT", "12348"))
SMS_IN_CONNECT = int(os.environ.get("OSMO_SMS_IN_PORT_VM", "12349"))
# How a call requested by the Android phone becomes a bench call.
# {num} = the dialled number, {msisdn} = our number. The Local channel enters
# the Asterisk dialplan ("internal" context, the one carrying 100/500/600 and
# the GSM gateway), then switches back to our own number: the bench thus sets
# up a real call between the dialled number and the mobile.
CTX = os.environ.get("OSMO_CALL_CONTEXT", "internal")
# And the contexts through which the bench CALLS us. An incoming call shows
# up in the AMI as "Event: DialBegin / Context: <ctx> / DestExten: 100101".
# ALL contexts through which a call can reach us are accepted:
#   gsm_in      the gsm_msc endpoint, a call COMING FROM THE RADIO
#               (100102 -> 100101);
#   interop_in  the interop trunk (endpoint interop_trunk_opN), a call from
#               ANOTHER operator;
#   internal    a Linphone;
#   zadarma_in  the [zadarma] / [zadarma_pbx] trunk (pjsip.conf), a call from
#               the outside world via the Zadarma operator.
# Without the right context entrant() is never called and NO RING goes to
# oFono/ModemManager: the osmocom-bb mobile is paged by the MSC but the
# handset stays silent and the MSC eventually releases (MNCC cause DEST_OOO).
# The filter that matters remains DestExten == our MSISDN: the second leg of
# our own outgoing calls dials the REMOTE number, never ours.
IN_CTX = {c.strip() for c in os.environ.get(
    "OSMO_CALL_IN_CONTEXT", "gsm_in,interop_in,internal,zadarma_in").split(",") if c.strip()}
# THE CALL GOES THROUGH THE AMI, NOT THE CLI. "channel originate" comes from
# the res_clioriginate module, absent from this installation (modules.conf is
# autoload = no). The AMI is active in manager.conf; its account is installed
# by start-native.sh from configs/manager-osmo.conf.
AMI_HOST = os.environ.get("OSMO_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("OSMO_AMI_PORT", "5038"))
AMI_USER = os.environ.get("OSMO_AMI_USER", "osmo")
AMI_PASS = os.environ.get("OSMO_AMI_PASSWORD", "osmocom1")

def clip(num):
    """The caller number as it must be PRESENTED, and its 27.007 type.

    A call from the outside via Zadarma arrives with an E.164 caller, but the
    dialplan strips the "+" before handing the call to the MSC ([zadarma_in]:
    Set(CALLERID(num)=${FILTER(0-9,...)})), because GSM signalling cannot
    carry it to the handset. The AMI thus gives "33656678074".

    The "+" is PUT BACK here, at presentation time, because 27.007 has a field
    for it: the number type. 145 = international (the "+" is implicit and the
    phone displays it again), 129 = unknown/national. Both are returned, and
    the caller gets back its +33656678074 form.

    Rule: a number already prefixed with "+" is international. Otherwise, ten
    digits or more WITHOUT a leading zero is international too - bench numbers
    are six digits (100101) and a French national number starts with 0, so
    neither can be mistaken for an international one.
    """
    n = (num or "").strip()
    if not n:
        return "", 129
    if n.startswith("+"):
        return n, 145
    if len(n) >= 10 and n.isdigit() and not n.startswith("0"):
        return "+" + n, 145
    return n, 129


_PROMPT = re.compile(rb'[\r\n][A-Za-z0-9_.\-]+(?:\([^)]*\))?[>#]\s*$')


AT_LOG = os.environ.get("OSMO_AT_LOG_OFONO", "/var/log/osmo-at-ofono.log")
_atlog = None


def log(*a):
    print("[banc]", *a, flush=True)


def atlog(sens, texte):
    """The log of THIS port: what oFono sends to the bench modem and what it
    answers. The counterpart of /var/log/osmo-at.log, which is the other end
    of the chain (the Android RIL). Together they tell the whole journey."""
    global _atlog
    if _atlog is None:
        # FALL BACK TO /tmp. The instance serving the VM runs as the ordinary
        # user and cannot write to /var/log: without the fallback it would
        # lose its whole AT trace, the one that says what ModemManager does
        # with a RING or a NO CARRIER.
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


# ── THE BENCH, READ THROUGH ITS VTY ─────────────────────────────────────────
class Vty:
    """A VTY connection kept open (same mechanics as tools/osmo-ts-probe.py:
    read up to the prompt, never sleep)."""

    def __init__(self, addr):
        # One address, or a list tried in order (see MOB_VTY).
        self.addrs = addr if isinstance(addr, list) else [addr]
        self.addr = self.addrs[0]
        self.s = None
        self.lock = threading.Lock()

    def _connect(self):
        for addr in self.addrs:
            try:
                self.s = socket.create_connection(addr, timeout=1.0)
                self.s.settimeout(1.0)
                self.addr = addr
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
    """A call command on the mobile. Returns True if it was accepted.

    WHY THE MOBILE, AND NOT THE VM. An ATD from the VM makes Asterisk start
    TWO legs: one plays the requested service (the echo of 600), the other
    calls 100101 - that is the MOBILE, not the VM. Without an answer that leg
    falls on Congestion(), gsm_audio stays at zero and nothing is heard - yet
    that bridge is what the VM relays. The mobile must therefore answer, and
    there is nobody to press the key: it is done through its VTY.
    """
    # WAIT FOR THE LEG TO ARRIVE BEFORE ANSWERING. A "call 1 answer" sent
    # while the leg is still in paging writes "% No alerting call" on ALL the
    # mobile's VTYs - including the user's. The mobile says where it stands in
    # "show ms": as long as its RR layer is "idle", nothing has arrived yet,
    # so keep quiet.
    if action == "answer":
        for _ in range(essais * 2):
            out = MOB.cmd("show ms %s" % MS) or ""
            if "radio resource layer state: idle" not in out:
                break
            time.sleep(0.5)
        # Between the paging response and the ringing there remain one to
        # three seconds: all attempts (essais) are kept, not just a few.
    # The mobile confirms with "% (MS 1) % Call is connected" - a message that
    # starts with "%", like its errors. Only "No alerting call" / "No call"
    # (nothing to answer yet) justifies a retry; "connected" or any other
    # reply means success.
    for _ in range(essais):
        MOB.cmd("enable")
        out = MOB.cmd("call %s %s" % (MS, action))
        if out is not None and "No alerting call" not in out and "No call" not in out:
            return True
        time.sleep(0.5)
    return False


def mobile_decroche():
    """The answer, insistently: the leg towards the subscriber takes a moment
    to make the mobile ring, and a single attempt comes too early."""
    if mobile("answer", essais=30):
        log("mobile : decroche")
        return True
    log("mobile : rien a decrocher")
    return False


class Banc:
    """The bench state, refreshed on demand and cached for one second - a
    modem is queried in bursts when the RIL starts (CREG, COPS, CSQ...), no
    need to make four VTY round trips for the same answer."""

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
            # The actual OsmoBSC format, as seen on the bench:
            #   "BSC is on MCC-MNC 001-01 and has 2 BTS"
            m = re.search(r'MCC-MNC\s+(\d+)-(\d+)', txt)
            if m:
                v["mcc"], v["mnc"] = m.group(1), m.group(2)
            m = re.search(r'Network Name.*?:\s*(\S.*)', txt)
            if m:
                v["name"] = m.group(1).strip()
        txt = BSC.cmd("show bts 0")
        if txt:
            # "ARFCNs: 514" on this bench (the "s" and the colon matter).
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


# ── THE 4G: srsRAN OVER THE ZEROMQ VIRTUAL RADIO ────────────────────────────
# THE PHONE IS ON 4G, AND DROPS TO 2G TO TALK.
# The bench has two radios: the osmocom 2G (osmo-bts-trx + the osmocom-bb
# mobile, which IS subscriber 100101) and an srsRAN 4G without hardware
# (srsENB <-> srsUE over ZeroMQ, ports 2000/2001, srsEPC behind). The eNB
# announces the 2G to its UEs through the SIB7 of sib.conf (the GERAN list,
# mapped into SIB1 by si_mapping_info = [7]): that is CSFB, "CS fallback" - a
# UE camped on LTE, which has no voice, drops to GSM for the duration of a
# call or an SMS, then climbs back.
#
# This modem does what the chip of a real phone would do in front of these
# two networks: it camps on the 4G as long as it is there (+CEREG registered,
# AcT 7, TAC/ECI of the eNB), and as soon as a CS service starts - an ATD, a
# RING, an SMS either way - it announces it has moved to 2G (URC +CREG with
# LAC/CI of the BTS and AcT 0); once the service ends, it climbs back. Phosh
# therefore shows "4G", then "2G" during the call, then "4G".
#
# THE TRUTH OF THE 4G COMES FROM THE BENCH, as that of the 2G comes from the
# osmo-bsc VTY:
#   - the eNB is there if the srsENB ZeroMQ port (2000) listens;
#   - the UE is ATTACHED if srsUE has brought up its tun (tun_srsue) with an
#     address - it does so in its own network namespace (--gw.netns=ue1),
#     which is where we look. No right to look there (not root): stick to
#     the eNB. OSMO_LTE_TEMOIN=enb to look ONLY at the eNB, even as root.
# The identities (MCC/MNC, TAC, ECI, APN, the GERAN ARFCNs of the SIB7) are
# read from the srsRAN files themselves (OSMO_SRSRAN_DIR, else root's
# ~/.config/srsran, else /etc/srsran): what the modem reports is what the
# eNB transmits.
ZMQ_PORT = int(os.environ.get("OSMO_ZMQ_PORT", "2000"))
LTE_NETNS = os.environ.get("OSMO_LTE_NETNS", "ue1")
LTE_TUN = os.environ.get("OSMO_LTE_TUN", "tun_srsue")
LTE_TEMOIN = os.environ.get("OSMO_LTE_TEMOIN", "ue")          # ue | enb
LTE_ON = os.environ.get("OSMO_LTE", "1") == "1"
# The name under which the 4G appears on the phone. srsRAN does not transmit
# a network name; one is given, distinct from that of the 2G ("Osmocom", read
# from osmo-bsc), so that the network list shows TWO entries.
LTE_NAME = os.environ.get("OSMO_LTE_NAME", "Osmocom 4G")
# DATA OVER 2G: THE GPRS MODEM ON THE CALYPSO (QEMU + TI ROM).
# Without 4G, the phone's data goes out through tun_modem, the tunnel of the
# osmocom-bb `modem` (PDP context, netns msgprs), NATed behind its address;
# the GGSN delivers it all on apn0, NATed to the Internet like the 4G SGi.
# The Calypso has only ONE layer-2 client: scripts/calypso-mode.sh gives it
# to the modem (ATD*99, data) or to the mobile (call, SMS: voice).
# OSMO_GPRS_DATA=0: disabled.
GPRS_DATA = os.environ.get("OSMO_GPRS_DATA", "1") == "1"
GPRS_NETNS = os.environ.get("OSMO_GPRS_NETNS", "msgprs")
GPRS_TUN = os.environ.get("OSMO_GPRS_TUN", "tun_modem")
GPRS_NET = os.environ.get("OSMO_GPRS_NET", "176.16.32.0/24")
CALYPSO_MODE = os.environ.get("OSMO_CALYPSO_MODE",
                              os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "calypso-mode.sh"))
CALYPSO_MODE_F = "/run/osmo-banc/calypso-mode"


def calypso_mode():
    """voix | data: who owns the Calypso (scripts/calypso-mode.sh)."""
    try:
        with open(CALYPSO_MODE_F) as f:
            return f.read().strip() or "voix"
    except OSError:
        return "voix"


def calypso(mode, attendre):
    """Give the Calypso to the mobile (voix) or to the GPRS modem (data).
    attendre: wait until the mobile is in service / the PDP is active
    (blocking, 2 to 4 min max)."""
    if not os.path.exists(CALYPSO_MODE):
        log("calypso : %s absent, pas de bascule %s" % (CALYPSO_MODE, mode))
        return False
    cmd = ["bash", CALYPSO_MODE, mode] + (["--wait"] if attendre else [])
    if not attendre:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        log("calypso : bascule en %s lancee" % mode)
        return True
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    for l in (r.stdout or "").splitlines():
        log("calypso : %s" % l)
    return r.returncode == 0
# The vendor announced to AT+CGMI: it decides the ModemManager plugin, hence
# the way data is done (see the replies to +CGMI and +GTRNDIS).
VENDOR = os.environ.get("OSMO_MODEM_VENDOR", "Fibocom")


def _tcp_ecoute(port, host="127.0.0.1"):
    try:
        s = socket.create_connection((host, port), timeout=0.3)
        s.close()
        return True
    except OSError:
        return False


class Lte:
    """The bench 4G: what srsRAN transmits, and whether our UE is on it."""

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
        """"key = value" (ini or libconfig, 0x accepted), or the default."""
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
        # The SIB7: the GERAN list the eNB gives its UEs for CSFB, and
        # whether it is scheduled in SIB1 (otherwise it is not transmitted,
        # and a real UE would not know there is a 2G next door).
        m = re.search(r'sib7\s*=\s*\{(.*?)\n\}', sib, re.S)
        if m:
            bloc = m.group(1)
            # The GERAN group of the SIB7 is start_arfcn PLUS the list that
            # follows (36.331, CarrierFreqsGERAN): both are announced.
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
        """True/False if the srsUE tun could be inspected, None otherwise."""
        # The tun is in the network namespace if srsue was started with
        # --gw.netns, on the host otherwise (plain "srsue"): BOTH are checked.
        # True as soon as it is seen; None if nowhere could be looked at (not
        # root for the namespace, and no tun on the host).
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
                # "ip -n ue1" is refused without root (Operation not
                # permitted) while the namespace exists: the tun may be there
                # unseen. Do not conclude "not attached" from the host view
                # alone.
                if "-n" in cmd and LTE_NETNS and os.path.exists("/run/netns/" + LTE_NETNS):
                    ns_ferme = True
                continue
            vu_quelque_part = True
            if re.search(r'\b%s\b.*\binet\b' % re.escape(LTE_TUN), r.stdout):
                return True
        if ns_ferme:
            # Without root, look through the srsue threads: the GW thread
            # did setns() into the namespace, and /proc/<pid>/task/<tid>/net/
            # is readable by everyone. fib_trie lists the local addresses
            # there: the tun shows up with its address once the attach
            # succeeded.
            vu = self._ue_attache_par_proc()
            if vu is not None:
                return vu
            return None
        return False if vu_quelque_part else None

    def _ue_attache_par_proc(self):
        """True/False from /proc/<srsue pid>/task/*/net, None if no srsue
        or nothing readable."""
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
                # A LOCAL address other than 127.x in the tun's namespace:
                # srsue received it from the EPC.
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
        """Once: is the 2G announced by the SIB7 the one of the bench?"""
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


# ── ASTERISK, THROUGH THE AMI ───────────────────────────────────────────────
def _ami(actions, wait=3.0):
    """Open an AMI session, play the actions, return the raw reply."""
    try:
        s = socket.create_connection((AMI_HOST, AMI_PORT), timeout=5)
    except OSError as e:
        return None, "AMI injoignable (%s)" % e
    try:
        s.settimeout(wait)
        s.recv(4096)                                  # the banner
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
    """Give birth to the call: the dialled number is called in the bench
    dialplan, and once answered it is connected to our own number - hence to
    the subscriber's mobile. Returns (ok, channel or reason)."""
    chan = "Local/%s@%s" % (num, CTX)
    # ECHO_NO_PROMPT=1: Asterisk's 600 skips its announcement (demo-echotest)
    # and goes straight to Echo: with the recording of leg ;1 (sub-record),
    # the Playback -> Echo sequence makes Asterisk send a burst of RTP
    # silence packets towards the BTS. See the comment of 600 in
    # configs/extensions.conf; no effect on the other numbers. The echo test
    # announcement is played instead on the mobile leg (A() option of Dial,
    # via DIAL_OPTS), where it does not trigger the burst.
    extra = "Variable: DIAL_OPTS=A(demo-echotest)\r\n" if num == "600" else ""
    act = ("Action: Originate\r\n"
           "Channel: %s\r\n"
           "Context: %s\r\n"
           "Exten: %s\r\n"
           "Priority: 1\r\n"
           "CallerID: %s\r\n"
           "Variable: ECHO_NO_PROMPT=1\r\n"
           "%s"
           "Async: true\r\n\r\n" % (chan, CTX, MSISDN, MSISDN, extra))
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
    """An AMI event block ("Key: value" per line) returned as a dict."""
    d = {}
    for ligne in txt.split("\r\n"):
        cle, sep, val = ligne.partition(":")
        if sep:
            d[cle.strip()] = val.strip()
    return d


class AmiEcoute(threading.Thread):
    """The ear on Asterisk.

    WITHOUT IT, NEITHER RINGING NOR HANGUP. It is what emits the RING for an
    incoming call (otherwise ModemManager has nothing to show) and what
    learns that a call has ended (otherwise the call screen stays displayed
    when the other party hangs up).

    What is watched, as seen on the bench for a call from 100102 to 100101:
        Event: DialBegin      Context: gsm_in
        CallerIDNum: 100102   DestExten: 100101
        DestChannel: PJSIP/gsm_msc-0000000f
    then Hangup on that same channel for the end. Our own outgoing calls also
    dial our number: without the est_notre_jambe() filter the modem would
    ring itself.
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
            s.recv(4096)                                   # the banner
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
            # The second leg of our own calls dials OUR number: without this
            # test, the phone rings for the call it has just placed.
            if modem.est_notre_jambe(e.get("Channel") or ""):
                return
            modem.entrant(e.get("CallerIDNum") or "", e.get("DestChannel") or "")
        elif ev == "Newchannel":
            # ami_originate stores "Local/600@internal", which is the
            # REQUEST. Asterisk creates "Local/600@internal-0000000b;1": an
            # Action: Hangup needs that real name, noted as soon as it
            # appears. LATCH THE FIRST, NOT THE LAST: a Local channel comes
            # in PAIRS ("...;1" and "...;2", both events in the same
            # millisecond), so the name is replaced only while it still
            # equals the REQUEST (c["origine"]).
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


# ── DATA: A PPP SERVER AT THE END OF THE AT PORT ────────────────────────────
# WHY PPP, AND NOTHING ELSE. ModemManager, facing a modem that has only an AT
# port, knows a single way to do data: dial ATD*99***1#, wait for CONNECT,
# and let NetworkManager run pppd on the serial port. The plugins that can do
# without PPP (Fibocom +GTRNDIS, Huawei ^NDISDUP, Cinterion ^SWWAN) all
# require a USB network port - either to recognise the modem by its USB id,
# or to number the port (bInterfaceNumber); on a QEMU PCI serial port, none
# applies. So the phone must HAVE PPP (the ppp_generic/ppp_async modules,
# built for its kernel) and this modem must speak PPP at the other end: that
# is this block.
#
# What is done, and nothing more (RFC 1661, 1662, 1332):
#   - asynchronous HDLC framing (0x7e, 0x7d escape, FCS-16);
#   - LCP: MRU, ACCM, magic number, PFC and ACFC are accepted, the rest is
#     rejected (including authentication: the bench asks for none);
#     Echo-Requests are answered; a Terminate-Request ends the session;
#   - IPCP: the phone is GIVEN its address and DNS by Configure-Nak (this is
#     how an operator assigns them), VJ compression is refused;
#   - IPv6CP and CCP: Protocol-Reject, pppd does without;
#   - IP packets go into a tun, and that tun is placed IN THE NETWORK
#     NAMESPACE OF srsUE (--gw.netns) with a NAT towards tun_srsue: each
#     packet of the phone then crosses the 4G radio, the eNB, the EPC and the
#     SGi. If srsUE runs on the host (no netns), routing still goes through
#     tun_srsue, but the return takes the local shortcut - the UE and the
#     EPC being the same machine, the kernel delivers internally what is
#     addressed to a local address. This is said in the log.
import fcntl
import random
import struct

# The PPP link addresses must NOT be those the EPC gives the UE (with
# open5gs, srsUE receives 10.45.0.2): the phone's address would then be LOCAL
# on tun_srsue in the same namespace, and the NAT return would be delivered
# to the host instead of going back to the phone. A separate /30 that nothing
# else uses.
PPP_LOCAL = os.environ.get("OSMO_PPP_LOCAL", "10.99.0.1")      # us, the network
PPP_PEER = os.environ.get("OSMO_PPP_PEER", "10.99.0.2")        # the phone
PPP_DNS = [d.strip() for d in os.environ.get("OSMO_PPP_DNS", "8.8.8.8,8.8.4.4").split(",") if d.strip()]
PPP_IF = os.environ.get("OSMO_PPP_IF", "ppp-pmos")


def _sgi_net_defaut():
    """The UE subnet, for the host's SGi -> Internet egress: the one of
    smf.yaml with open5gs (10.45.0.0/16), 172.16.0.0/24 with srsEPC."""
    # The bench prefix (/opt/LTE/open5gs/install, the one of osmo-epc.sh) is
    # among the candidates: without it the MASQUERADE set here would not
    # cover the open5gs UEs (10.45.0.0/16).
    for f in ([os.path.join(os.environ["OPEN5GS_PREFIX"], "etc/open5gs/smf.yaml")] if os.environ.get("OPEN5GS_PREFIX") else []) + [
            "/opt/LTE/open5gs/install/etc/open5gs/smf.yaml",
            "/root/open5gs/install/etc/open5gs/smf.yaml", "/etc/open5gs/smf.yaml"]:
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
    """A system command, without raising: returns (rc, output)."""
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
        self.brut = bytearray()              # what arrives OUTSIDE a frame (an AT?)
        self.ident = 0
        self.lcp_ack_recu = self.lcp_ack_donne = self.lcp_ouvert = False
        self.ipcp_ack_recu = self.ipcp_ack_donne = self.ipcp_ouvert = False
        self.tun = None
        self.ns = None
        self.fini = False
        self.lock = threading.Lock()
        self.octets = [0, 0]                 # upstream, downstream
        self._motif_fin = None               # set by terminer()

    def terminer(self, motif):
        """WE close the session: Terminate-Request to pppd, which answers
        Terminate-Ack and stops; if it does not answer within a second, close
        anyway. fin() will say NO CARRIER on the port, and ModemManager takes
        over again in command mode."""
        if self.fini or self._motif_fin:
            return
        self._motif_fin = motif
        self._paquet(self.LCP, self.TERM_REQ, self._prochain(), b"")
        t = threading.Timer(1.0, lambda: self.fin(motif))
        t.daemon = True
        t.start()

    # -- the HDLC layer
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
                # Outside a frame: the port may have switched back to AT
                # (ModemManager taking over after pppd died). "AT" followed
                # by an end of line, and the port is given back.
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
            return                           # bad FCS: drop
        f = f[:-2]
        if f[:2] == b"\xff\x03":
            f = f[2:]
        if not f:
            return
        if f[0] & 1:                         # one-byte protocol (PFC)
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

    # -- the negotiation packets
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
                if t not in (1, 2, 5, 7, 8):     # MRU, ACCM, magic, PFC, ACFC
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
            # Do not insist on the ACCM: the magic number is enough.
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
                if t == 3:                    # the phone's address
                    if v != socket.inet_aton(PPP_PEER):
                        nak += self._opt(3, socket.inet_aton(PPP_PEER))
                elif t == 129:                # primary DNS
                    if v != socket.inet_aton(dns[0]):
                        nak += self._opt(129, socket.inet_aton(dns[0]))
                elif t == 131:                # secondary DNS
                    if v != socket.inet_aton(dns[1]):
                        nak += self._opt(131, socket.inet_aton(dns[1]))
                else:                         # VJ compression and the rest
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

    # -- the tun, and its hookup to the radio
    def _tun_monter(self):
        TUNSETIFF, IFF_TUN, IFF_NO_PI = 0x400454CA, 0x0001, 0x1000
        try:
            fd = os.open("/dev/net/tun", os.O_RDWR)
            fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", PPP_IF.encode(), IFF_TUN | IFF_NO_PI))
        except OSError as e:
            log("PPP : impossible de creer %s (%s) - il faut root ; la session reste sans IP" % (PPP_IF, e))
            return
        self.tun = fd
        self.ns = None
        _sh("ip", "addr", "replace", PPP_LOCAL, "peer", PPP_PEER + "/32", "dev", PPP_IF)
        _sh("ip", "link", "set", PPP_IF, "up", "mtu", "1500")
        if not self._radio_brancher():
            if GPRS_DATA:
                log("PPP : IPCP ouvert, %s au telephone ; sortie radio en attente du PDP GPRS (%s dans %s)"
                    % (PPP_PEER, GPRS_TUN, GPRS_NETNS))
                threading.Thread(target=self._attendre_radio, daemon=True).start()
            elif not self._raccourci_test():
                log("PPP : IPCP ouvert, %s au telephone, mais pas de %s : la data n a pas de sortie radio"
                    % (PPP_PEER, LTE_TUN))
        threading.Thread(target=self._depuis_tun, daemon=True).start()

    def _raccourci_test(self):
        """TEST SHORTCUT (no radio, no GGSN), OSMO_PPP_SHORTCUT=1: the phone
        goes out through the host's default interface, NATed behind its
        address, as the srsEPC SGi would do. Real EGPRS goes through the
        SGSN/GGSN; this path only serves to validate DNS, NAT and the
        phone's IP stack."""
        if os.environ.get("OSMO_PPP_SHORTCUT", "0") != "1":
            return False
        rc, up = _sh("sh", "-c", "ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i==\"dev\") print $(i+1); exit}'")
        if not up:
            return False
        _sh("sysctl", "-qw", "net.ipv4.ip_forward=1")
        rc, _ = _sh("iptables", "-w", "-t", "nat", "-C", "POSTROUTING", "-s", PPP_PEER, "-o", up, "-j", "MASQUERADE")
        if rc != 0:
            _sh("iptables", "-w", "-t", "nat", "-A", "POSTROUTING", "-s", PPP_PEER, "-o", up, "-j", "MASQUERADE")
        _sh("iptables", "-w", "-N", "DOCKER-USER")
        for spec in (("-s", PPP_PEER), ("-d", PPP_PEER)):
            rc, _ = _sh("iptables", "-w", "-C", "DOCKER-USER", *spec, "-j", "ACCEPT")
            if rc != 0:
                _sh("iptables", "-w", "-I", "DOCKER-USER", "1", *spec, "-j", "ACCEPT")
        rc, _ = _sh("iptables", "-w", "-C", "FORWARD", "-j", "DOCKER-USER")
        if rc != 0:
            _sh("iptables", "-w", "-I", "FORWARD", "1", "-j", "DOCKER-USER")
        log("PPP : IPCP ouvert, %s au telephone - RACCOURCI DE TEST : sortie directe par %s (sans GGSN)"
            % (PPP_PEER, up))
        return True

    def _radio_choix(self):
        """(netns or None, tun, network to NAT towards the Internet): the 4G
        if srsUE has its tun, else the GPRS PDP of the modem on the Calypso,
        else None."""
        if LTE_NETNS:
            rc, o = _sh("ip", "-n", LTE_NETNS, "-4", "-o", "addr", "show", LTE_TUN)
            if rc == 0 and "inet" in o:
                return LTE_NETNS, LTE_TUN, PPP_SGI_NET
        rc, o = _sh("ip", "-4", "-o", "addr", "show", LTE_TUN)
        if rc == 0 and "inet" in o:
            return None, LTE_TUN, PPP_SGI_NET
        if GPRS_DATA and GPRS_NETNS:
            rc, o = _sh("ip", "-n", GPRS_NETNS, "-4", "-o", "addr", "show", GPRS_TUN)
            if rc == 0 and "inet" in o:
                return GPRS_NETNS, GPRS_TUN, GPRS_NET
        return None

    def _radio_brancher(self):
        """Hook PPP_IF onto the available radio egress. False if none."""
        choix = self._radio_choix()
        if choix is None or self.tun is None:
            return False
        ns, tun, sgi = choix
        if ns != self.ns:
            cur = ["ip", "-n", self.ns] if self.ns else ["ip"]
            _sh(*cur, "link", "set", PPP_IF, "netns", ns if ns else "1")
            self.ns = ns
        ip = ["ip", "-n", self.ns] if self.ns else ["ip"]
        ex = ["ip", "netns", "exec", self.ns] if self.ns else []
        _sh(*ip, "addr", "replace", PPP_LOCAL, "peer", PPP_PEER + "/32", "dev", PPP_IF)
        _sh(*ip, "link", "set", PPP_IF, "up", "mtu", "1500")
        _sh(*ex, "sysctl", "-qw", "net.ipv4.ip_forward=1")
        _sh(*ex, "sysctl", "-qw", "net.ipv4.conf.%s.rp_filter=0" % PPP_IF)
        if self.ns:
            _sh(*ip, "route", "replace", "default", "dev", tun)
        else:
            _sh("ip", "route", "replace", "default", "dev", tun, "table", "45")
            rc, o = _sh("ip", "rule", "show")
            if PPP_PEER not in o:
                _sh("ip", "rule", "add", "from", PPP_PEER, "lookup", "45", "priority", "4500")
        rc, _ = _sh(*ex, "iptables", "-w", "-t", "nat", "-C", "POSTROUTING", "-s", PPP_PEER, "-o", tun, "-j", "MASQUERADE")
        if rc != 0:
            _sh(*ex, "iptables", "-w", "-t", "nat", "-A", "POSTROUTING", "-s", PPP_PEER, "-o", tun, "-j", "MASQUERADE")
        # The Internet egress of the UE network (4G SGi or GGSN pool)
        rc, up = _sh("sh", "-c", "ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i==\"dev\") print $(i+1); exit}'")
        if up:
            _sh("sysctl", "-qw", "net.ipv4.ip_forward=1")
            rc, _ = _sh("iptables", "-w", "-t", "nat", "-C", "POSTROUTING", "-s", sgi, "-o", up, "-j", "MASQUERADE")
            if rc != 0:
                _sh("iptables", "-w", "-t", "nat", "-A", "POSTROUTING", "-s", sgi, "-o", up, "-j", "MASQUERADE")
            _sh("iptables", "-w", "-N", "DOCKER-USER")
            for spec in (("-s", sgi), ("-d", sgi)):
                rc, _ = _sh("iptables", "-w", "-C", "DOCKER-USER", *spec, "-j", "ACCEPT")
                if rc != 0:
                    _sh("iptables", "-w", "-I", "DOCKER-USER", "1", *spec, "-j", "ACCEPT")
            rc, _ = _sh("iptables", "-w", "-C", "FORWARD", "-j", "DOCKER-USER")
            if rc != 0:
                _sh("iptables", "-w", "-I", "FORWARD", "1", "-j", "DOCKER-USER")
        log("PPP : IPCP ouvert, %s au telephone ; %s %s, la data passe par %s (%s)"
            % (PPP_PEER, PPP_IF, "dans l espace %s" % self.ns if self.ns else "sur l hote",
               tun, "GPRS, Calypso + ROM TI" if tun == GPRS_TUN else "4G, srsUE"))
        return True

    def _attendre_radio(self):
        """The GPRS modem's PDP arrives 30 to 120 s after ATD*99 (Calypso
        switch, attach, PDP): the egress is hooked up as soon as it is there."""
        t0 = time.time()
        while not self.fini and self.tun is not None and time.time() - t0 < 300:
            if self._radio_brancher():
                return
            time.sleep(2)
        if not self.fini and self.tun is not None:
            log("PPP : toujours pas de PDP GPRS apres 300 s (scripts/calypso-mode.sh etat)")

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


# ── THE AT MODEM ────────────────────────────────────────────────────────────
class AtHandler(socketserver.StreamRequestHandler):
    """One modem per connection: oFono opens a single one."""

    role = "commande"             # "commande" (hvc0) or "data" (hvc1, see DATA)

    def setup(self):
        super().setup()
        global CURRENT, DATA
        if self.role == "data":
            DATA = self
        else:
            CURRENT = self        # oFono opens a single connection: this one
        self.echo = True          # a real modem starts with echo on
        self.cmee = 1
        self.creg_mode = 0
        self.cops_format = 2          # 0 = long name, 1 = short name, 2 = MCC/MNC
        self.calls = []               # the calls in progress, for +CLCC
        self.sms_target = None
        # How this system wants SMS announced. mt=2: the message pushed as
        # is; mt=1: stored, and only the index is signalled. Start with 2,
        # and AT+CNMI= tells the truth.
        self.cnmi_mt = 2
        self.cmgf = 0             # 0 = PDU (what ModemManager uses), 1 = text
        # The 4G and CSFB (see the Lte class). Three URC modes, one per
        # registration (CS, GPRS, EPS); ws46 = the technologies the system
        # ALLOWS (27.007 § 5.9: 12 GSM only, 28 E-UTRAN only, 31 both) - this
        # is Phosh's "preferred network" setting; _cs_hold holds the 2G for
        # the duration of the CS service, _retour is the timer that brings us
        # back to 4G; _rat_annonce, the last technology announced, to signal
        # only the changes.
        self.cgreg_mode = 0
        self.cereg_mode = 0
        self.ws46 = 31
        self._cs_hold = False
        self._retour = None
        self._rat_annonce = None
        self.data_cid = 0           # the PDP context "connected" by +GTRNDIS (0 = none)
        self.ppp = None             # the PPP session in progress (ATD*99), see the Ppp class
        self._urc_attente = []      # the URCs held back during data (see out)
        self._urc_lock = threading.Lock()
        self.port_commande = True   # False between NO CARRIER and the next AT command
        log("oFono s est connecte depuis %s (port de %s)" % (self.client_address, self.role))
        if self.role != "data":
            threading.Thread(target=self._veille, daemon=True).start()

    def finish(self):
        """The link is down: this modem is no longer "the" modem.

        CURRENT is cleared here so that on_passerelle_sms() and the RINGs of
        AmiEcoute do not write into a closed socket (out() swallows the
        OSError). The inbox keeps the message: it comes out at the next
        AT+CMGL.
        """
        global CURRENT, DATA
        if CURRENT is self:
            CURRENT = None
        if DATA is self:
            DATA = None
        if self.ppp is not None:
            self.ppp.fin("lien AT ferme")
        # THE CALLS DIE WITH THE LINK. The AMI only talks to CURRENT, so a
        # hangup would never reach this handler once a new one is born:
        # hang up on the Asterisk side and clear, otherwise the _sonne loop
        # would run forever and the other party would stay hanging.
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
        """The PPP session is over: the port becomes an AT port again, and
        says so like a modem (NO CARRIER) - ModemManager then restarts its
        probe and the bearer becomes "disconnected"."""
        self.ppp = None
        self.data_cid = 0
        # NO CARRIER goes out as is: it is what gives the port back. Then, as
        # long as the phone has not sent its first AT command, the port still
        # belongs to the stopping pppd: anything emitted would go into the
        # void (the +CREG of the 4G return, a +CMTI). Hold them (see out).
        self.port_commande = False
        atlog(">", "NO CARRIER")
        try:
            self.wfile.write(b"\r\nNO CARRIER\r\n")
            self.wfile.flush()
        except OSError:
            pass

    def _tag(self, sens):
        return sens if self.role != "data" else sens + "d"      # ">d": data port

    def out(self, text):
        # A SINGLE PORT, HENCE NO URC DURING PPP. The bench modem has only
        # one serial port: once ATD*99 has gone through, everything written
        # to it enters the PPP stream, and pppd drops RING, +CLIP, +CMTI as
        # noise. What must be announced during data waits here, and goes out
        # as soon as the port is back in command mode (see _urc_liberer,
        # called after the first AT command that follows). csfb_debut() cuts
        # the data for that: on a real network too, CSFB suspends data for
        # the duration of the CS service.
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
        """The port is in command mode: emit what was waiting."""
        with self._urc_lock:
            attente, self._urc_attente = self._urc_attente, []
        for text in attente:
            self.out(text)

    # -- the access technology: 4G at rest, 2G for the duration of a CS service
    def _modem(self):
        """The phone state lives on the command port: the data port refers
        to it."""
        if self.role == "data" and CURRENT is not None:
            return CURRENT
        return self

    def cs_actif(self):
        m = self._modem()
        return bool(m.calls) or m.sms_target is not None or m._cs_hold

    def appel_en_cours(self):
        return bool(self._modem().calls)

    def rat(self):
        """"lte" or "gsm": where the phone is camped right now."""
        if self.role == "data" and CURRENT is not None:
            return CURRENT.rat()
        if self.ws46 == 12:                   # the system asked for GSM only
            return "gsm"
        if not LTE.state()["ok"]:
            return "gsm"
        if self.cs_actif():
            return "gsm"                      # CSFB: we went down
        return "lte"

    def _reg(self, tag):
        """(stat, lac or tac, ci or eci, act) for +CREG, +CGREG or +CEREG in
        the current technology. act None = no position to give."""
        st = BANC.state()
        lte = LTE.state()
        if self.rat() == "lte":
            # Combined attach (EPS + IMSI attach via SGs): CS is registered
            # if the 2G is there, and everything is said with TAC/ECI, AcT 7.
            stat_cs = 1 if st["up"] else (2 if lte["ok"] else 0)
            stat = stat_cs if tag == "+CREG" else 1
            return stat, lte["tac"], lte["eci"], 7
        reg = 1 if st["up"] else 0
        if tag == "+CEREG":
            # On 2G, EPS is suspended (CSFB) or absent: no position.
            return (2 if lte["ok"] else 0), 0, 0, None
        return reg, st["lac"], st["cid"], 0

    def _ligne_reg(self, tag, mode, urc=False):
        stat, lac, ci, act = self._reg(tag)
        tete = "%s: " % tag + ("" if urc else "%d," % mode)
        if mode >= 2 and act is not None and stat in (1, 5):
            return '%s%d,"%04X","%08X",%d' % (tete, stat, lac, ci, act)
        return "%s%d" % (tete, stat)

    def annonce_rat(self):
        """Signal a technology change through the registration URCs the
        system asked for (AT+CREG=2 etc.). Order matters: the LAST
        announcement gives the AcT that ModemManager keeps, so end with the
        one carrying the current technology."""
        if self.role == "data":
            return                            # URCs go to the command port
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
        """The 4G may come up or go down while the phone does nothing: check
        every two seconds, and verify once that the 2G announced by the SIB7
        is indeed the one of the bench."""
        while CURRENT is self:
            try:
                st = BANC.state()
                if st["up"]:
                    LTE.verifier_geran(st["arfcn"])
                self.annonce_rat()
            except Exception as e:      # never at the cost of the modem itself
                log("veille 4G : %s" % e)
            time.sleep(2)

    def csfb_debut(self, motif, couper_data=True):
        """A CS service starts: go down to 2G right away, and cancel a 4G
        return that would be under way. couper_data: the PPP session is
        closed (a call: 2G has no data during voice; an SMS on a single port:
        the port must be given back to the URCs)."""
        t, self._retour = self._retour, None
        if t:
            t.cancel()
        self._cs_hold = True
        if GPRS_DATA and calypso_mode() == "data":
            # Class B: the Calypso's GPRS data gives way to voice. The mobile
            # comes back (same line as c54x_exe/run.sh) and we wait for it to
            # be in service before letting the call go.
            log("calypso : %s - le Calypso repasse au mobile (voix)" % motif)
            for m in (self, DATA):
                if m is not None and m.ppp is not None:
                    m.ppp.terminer("voix : le Calypso quitte le GPRS")
            calypso("voix", attendre=True)
        if self._rat_annonce == "lte":
            st = BANC.state()
            log("CSFB : %s - on quitte la 4G pour la 2G (ARFCN %s, LAC %d, CI %d)"
                % (motif, st["arfcn"] or "?", st["lac"], st["cid"]))
        # Data is suspended for the duration of the CS service - and above
        # all it is the only way to give the port back to the URCs (see out).
        # NetworkManager restarts ATD*99 by itself once the UE is back on 4G.
        if couper_data:
            for m in (self, DATA):
                if m is not None and m.ppp is not None:
                    log("CSFB : data suspendue (fin de la session PPP) le temps du service CS")
                    m.ppp.terminer("CSFB : data suspendue le temps du service CS")
        self.annonce_rat()

    def csfb_fin_apres(self, delai=2.0):
        """The CS service is over: in <delai> seconds, if another one has not
        started, climb back to 4G - the time a real UE takes to reselect its
        LTE cell once the call is hung up."""
        t, self._retour = self._retour, None
        if t:
            t.cancel()
        self._retour = threading.Timer(delai, self._retour_lte)
        self._retour.daemon = True
        self._retour.start()

    def _retour_lte(self):
        self._retour = None
        if self.calls or self.sms_target is not None:
            return                            # another CS service took over
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
                # Data mode: everything goes to PPP, nothing is echoed.
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
                    self.port_commande = True     # the phone speaks AT: the port is ours
                    # The held URCs go out BEFORE the command: if it is
                    # ATD*99, the port goes back to data right after, and a
                    # held "back to 4G" +CEREG would stay locked behind the
                    # PPP.
                    if self.ppp is None and self._urc_attente:
                        self._urc_liberer()
                if self.sms_target is not None and m.group() == b"\x1a":
                    self.sms(text)
                elif text:
                    self.command(text)
        log("oFono s est deconnecte")

    # -- the incoming calls, pushed by AmiEcoute
    def est_notre_jambe(self, chan):
        """Is this channel a leg of a call WE placed?

        ami_originate() starts "Local/<num>@internal" on one side and, on
        the other, dials OUR OWN number (Exten: MSISDN) - this is how the
        bench connects the other party to the subscriber. That second leg
        thus produces, for each of our outgoing calls:
            DialBegin  Context: internal  DestExten: 100101
        which is exactly the signature of an incoming call ("internal" is in
        IN_CTX so that a Linphone call can reach us). Our legs are therefore
        recognised by the channel THAT DIALS (the Local we requested), not by
        the context - a real incoming call always arrives through another
        channel. Without this filter the phone would ring for the call it has
        just placed and hang up by itself when that leg ends.
        """
        if not chan:
            return False
        for c in self.calls:
            ref = c.get("origine")
            if ref and chan.startswith(ref):
                return True
        return False

    def entrant(self, num, chan):
        """The bench calls us: ring until it stops."""
        if any(c.get("channel") == chan for c in self.calls):
            return
        c = {"num": num, "state": "incoming", "channel": chan}
        # The paging comes through the 4G (SGs), the ringing plays on the
        # 2G: go down BEFORE the first RING. With a separate data port, data
        # stays up: refusing ATD*99 during the ringing would push
        # NetworkManager into backoff (4 failures, then 5 min without retry).
        self.csfb_debut("appel entrant de %s" % (num or "inconnu"), couper_data=(DATA is None))
        self.calls.append(c)
        log("appel entrant de %s (%s)" % (num or "inconnu", chan))
        threading.Thread(target=self._sonne, args=(c,), daemon=True).start()

    def _sonne(self, c):
        """RING every three seconds, and +CLIP right behind to give the
        number - this is what ModemManager expects to present the call
        (AT+CLIP=1 is among the settings accepted)."""
        while c in self.calls and c["state"] == "incoming" and CURRENT is self:
            self.out("RING")
            if c["num"]:
                _n, _t = clip(c["num"])
                self.out('+CLIP: "%s",%d,,,,0' % (_n, _t))
            time.sleep(3)

    def fin_appel(self, chan):
        """Asterisk hung up this channel. This path is what closes Phosh's
        call screen when the other party hangs up."""
        for c in list(self.calls):
            ref = c.get("channel")
            # Our outgoing calls keep "Local/600@internal", which Asterisk
            # expands to "Local/600@internal-0000001a;1": compare by prefix.
            # Incoming ones carry the exact name.
            if ref and chan.startswith(ref):
                self.calls.remove(c)
                log("appel termine (%s)" % chan)
                self.out("NO CARRIER")
        if not self.calls:
            self.csfb_fin_apres()

    def deliver_sms(self, sender, text):
        """Deliver an incoming SMS THE WAY THE SYSTEM ASKED FOR.

        The message is always stored: even in mt=2 the system may want to
        read it again (AT+CMGL at startup). Only then is the URC chosen.
        """
        pdu = pdu_deliver(sender, text)
        idx = inbox_ranger(sender, text, pdu)
        # An SMS is a CS service on this bench (it comes from the MSC): go
        # down to 2G to receive it, climb back three seconds later. With a
        # separate data port, data stays up: the URCs have their port. On a
        # single port, data must be cut for +CMTI to get through.
        self.csfb_debut("SMS entrant de %s" % (sender or "inconnu"), couper_data=(DATA is None))
        self.csfb_fin_apres(3.0)
        if self.cnmi_mt == 2:
            tpdu_len = len(pdu) // 2 - 1      # without the leading SMSC octet
            self.out("+CMT: ,%d\r\n%s" % (tpdu_len, pdu))
            log("SMS remis directement (+CMT) : %s" % text)
        else:
            self.out('+CMTI: "SM",%d' % idx)
            log("SMS range en SM[%d], index signale (+CMTI) : %s" % (idx, text))

    # -- the three commands that go with the inbox
    def _sms_ligne(self, m, entete):
        """A CMGR/CMGL entry, in the current mode."""
        if self.cmgf:                         # text mode
            stat = "REC READ" if m["lu"] else "REC UNREAD"
            return '%s"%s","%s",,"%s"\r\n%s' % (entete, stat, m["sender"],
                                                 m["ts"], m["text"])
        stat = 1 if m["lu"] else 0            # PDU mode: 0 unread, 1 read
        return "%s%d,,%d\r\n%s" % (entete, stat, len(m["pdu"]) // 2 - 1,
                                     m["pdu"])

    # -- sending an SMS through the bench
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
            # "Fibocom", AND WHY. ModemManager picks its plugin from this
            # name. The generic plugin can only do data through PPP on the
            # AT port. The Fibocom plugin, when the modem has a NETWORK PORT
            # beside the AT port and answers AT+GTRNDIS=?, brings up an ECM
            # bearer: +GTRNDIS=1,<cid> to connect, address by DHCP on the
            # network port. That is what this bench does: QEMU's second
            # network card (tools/osmo-pmos-data.sh) is that port, and it
            # leads into srsUE's network namespace - hence onto the 4G radio.
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
            # THE THREE REGISTRATIONS, AND THE 4G. +CREG is circuit (voice,
            # SMS), +CGREG the 2G/3G packet, +CEREG the EPS - LTE. The modem
            # tells the truth: registered on the EPS when srsUE is attached,
            # and each reply carries the current technology (last field:
            # 0 = GSM, 7 = E-UTRAN). During a call or an SMS, the reply
            # switches to 2G (CSFB) and the EPS becomes "searching".
            # THE "TEST" FORM IS NOT A SETTING. The atmodem driver first
            # probes AT+CREG=? and expects the LIST of supported modes; a
            # plain OK makes it conclude the modem cannot register (oFono:
            # "Unable to initialize Network Registration", no
            # NetworkRegistration interface at all). Same trap for +CGREG
            # (data): "GPRS not supported on this device".
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
            # oFono queries the operator TWICE, in two formats: it sets
            # AT+COPS=3,2 then AT+COPS? for the numeric code (MCC/MNC), and
            # AT+COPS=3,0 then AT+COPS? for the name. The requested format
            # must be remembered, otherwise the name stays empty on the oFono
            # side.
            # The last field is the technology: 7 on 4G, 0 on 2G.
            rat = self.rat()
            act = 7 if rat == "lte" else 0
            nom = LTE_NAME if rat == "lte" else st["name"]
            if ub.endswith("=?"):
                # THE NETWORK SCAN ("Select a network" in Phosh). A real
                # scan sees a cell as soon as it TRANSMITS, not only when
                # attached to it: the 4G is listed as soon as the eNB is
                # online. It carries a name distinct from the 2G (LTE_NAME):
                # two "Osmocom" entries would merge into one on screen.
                # stat: 2 = current, 1 = available.
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
            # The SELECTION: AT+COPS=0 (automatic) or AT+COPS=1,<fmt>,<oper>
            # [,<act>]. Choosing the 4G entry of the list means camping on
            # LTE; the 2G entry, on GSM; automatic gives both back.
            #
            # THIS IS THE ONLY LEVER THE USER HAS. Phosh's "network type"
            # setting goes through ModemManager, which REFUSES to set it on
            # an AT-command modem ("Setting allowed modes not supported" -
            # it reads AT+WS46=? for the list, but never emits AT+WS46=<n>).
            # What remains is the manual network selection, and MM always
            # does it NUMERICALLY, WITHOUT technology: 'AT+COPS=1,2,"00101"'.
            # Both radios carry the same MCC/MNC, so the number does not say
            # which one is wanted. Settled by usage: automatic (+COPS=0) is
            # already "4G as long as it is there"; asking for MANUAL here can
            # only mean one thing - stay on 2G. A name (format 0 or 1) or an
            # explicit technology are taken at their word.
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
            # 27.007 § 5.9: the technology ALLOWED by the system - this is
            # Phosh's "network type" setting (2G / 4G / automatic).
            # 12 = GSM only, 28 = E-UTRAN only, 31 = GERAN + E-UTRAN.
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
            # Bench running = strong signal; bench stopped = no signal.
            # The virtual 4G is "stronger" than the 2G: it shows.
            rat = self.rat()
            self.out("+CSQ: %d,99" % (28 if rat == "lte" else 24 if st["up"] else 99))
            self.ok(); return

        if ub.startswith("+CESQ"):
            # Extended quality (27.007 § 8.69): rxlev/ber for 2G, rsrq/rsrp
            # for 4G, 255 = not applicable. On 4G: rsrq 20 (-9.5 dB), rsrp 70
            # (-71 dBm); on 2G: rxlev 24.
            if ub.endswith("=?"):
                self.out("+CESQ: (0-63,99),(0-7,99),(0-96,255),(0-49,255),(0-34,255),(0-97,255)")
                self.ok(); return
            if self.rat() == "lte":
                self.out("+CESQ: 99,99,255,255,20,70")
            else:
                self.out("+CESQ: %d,99,255,255,255,255" % (24 if st["up"] else 99))
            self.ok(); return

        if ub.startswith("+GTRNDIS"):
            # FIBOCOM'S ECM BEARER (see +CGMI). ModemManager probes
            # AT+GTRNDIS=? at initialisation; if answered, and it has a
            # network port grouped with this AT port, data no longer goes
            # through PPP: +GTRNDIS=1,<cid> "connects", +GTRNDIS=0,<cid>
            # disconnects, +GTRNDIS? gives the state, and the address comes
            # by DHCP on the network port (dnsmasq in srsUE's namespace,
            # tools/osmo-pmos-data.sh).
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
                    self.err(30)                 # 30 = no network service
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
            # The PDP context: the APN is that of srsEPC (epc.conf), the
            # phone's data is on the 4G - even if, without PPP, the system
            # cannot activate it through this port (see ATD*99).
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
            # The EPS mode of operation (24.301 § 4.3): 1 = "CS/PS mode 1,
            # voice centric" - the phone that drops to 2G to talk. Exactly
            # this bench.
            if ub.endswith("=?"):
                self.out("+CEMODE: (0-3)")
            elif ub.endswith("?"):
                self.out("+CEMODE: 1")
            self.ok(); return

        # ── WHAT oFONO ASKS AT INITIALISATION ───────────────────────────
        # As soon as Powered=true, oFono runs through the whole inventory of
        # a real modem - character sets, SMS services, and above all a long
        # series of AT+CRSM (reading the SIM card files). Answering ERROR to
        # all that makes oFono give up; so answer like a modem whose SIM does
        # not have these files, which is THE TRUTH here: there is no card,
        # the identity comes from the bench (AT+CIMI), not from a physical
        # SIM.
        if ub == "+CSCS=?":
            self.out('+CSCS: ("IRA","GSM","UCS2")'); self.ok(); return
        if ub.startswith("+CSMS"):
            # 1,1,1: sent, received and broadcast SMS supported.
            self.out("+CSMS: 1,1,1"); self.ok(); return
        if ub.startswith("+CSIM"):
            # FLATLY REFUSE APDU ACCESS. ModemManager probes the card with
            # AT+CSIM (raw APDU commands: file selection, IMSI read...).
            # Answering "OK" without data would leave it waiting for a reply
            # that never comes, and it would register no modem. Announcing
            # the command as unsupported makes it fall back to the ordinary
            # commands (+CIMI, +CPIN?), which are answered - there is no real
            # card here, the identity comes from the bench.
            self.err(4)          # 4 = operation not supported
            return
        if ub.startswith("+CRSM"):
            # 148,4 = SW1 0x94 / SW2 0x04, "file not found": the normal reply
            # of a SIM that does not carry the requested file.
            self.out("+CRSM: 148,4"); self.ok(); return
        # THE COMMAND THAT DECIDES EVERYTHING: AT+GCAP. Through it oFono
        # asks the modem what it can do; without "+CGSM" in the reply, it
        # does not enable the network layer and NEVER sends AT+CREG - the
        # NetworkRegistration interface then stays absent.
        if ub in ("+GCAP", "+CGCAP"):
            self.out("+GCAP: +CGSM,+FCLASS,+DS,+ES"); self.ok(); return

        # ── THE INBOX, SEEN THROUGH AT ──────────────────────────────────
        # THE TEST FORM FIRST. "AT+CMGF=?" starts with "+CMGF=": it must be
        # matched before the prefix test below, which would answer a bare OK
        # (and, for AT+CNMI=?, reset cnmi_mt to 2).
        if ub == "+CMGF=?":
            self.out("+CMGF: (0,1)"); self.ok(); return
        if ub == "+CNMI=?":
            self.out("+CNMI: (0-2),(0-3),(0,2),(0,1),(0,1)"); self.ok(); return
        if ub.startswith("+CMGF="):
            # Remember the mode: CMGR and CMGL do not answer the same way in
            # text and in PDU, and answering in the wrong mode gets the
            # message dropped.
            self.cmgf = 1 if ub[6:].strip().startswith("1") else 0
            self.ok(); return
        if ub == "+CMGF?":
            self.out("+CMGF: %d" % self.cmgf); self.ok(); return

        if ub.startswith("+CNMI="):
            # THE COMMAND THAT DECIDES EVERYTHING FOR INCOMING SMS. The
            # second field (mt) says whether the system wants the message
            # pushed (2) or only its index (1). ModemManager asks for 1.
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
            # The acknowledgement of a "+CMT:". Nothing to do: the message
            # has already left the bench. But OK MUST be answered, otherwise
            # the system believes delivery failed and turns off direct
            # announcement.
            self.ok(); return

        if ub.startswith("+CMGR="):
            try:
                idx = int(re.sub(r"\D", "", ub[6:]) or "0")
            except ValueError:
                self.err(); return
            m = inbox_get(idx)
            if m is None:
                self.err(321)            # 321 = invalid memory index
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
            # 0 / "REC UNREAD": only the unread ones. Anything else: all.
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
                    INBOX[:] = []            # "delete all", per the flag
                else:
                    INBOX[:] = [m for m in INBOX if m["idx"] != idx]
            self.ok(); return

        if ub == "+CSCS?":
            self.out('+CSCS: "IRA"'); self.ok(); return
        if ub.startswith("+CPMS"):
            # Three SMS memories, all reported as the same inbox. The count
            # must be TRUE: a system that reads "0 messages" will not fetch
            # what has just been stored.
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
            # THE COMMAND THAT DECIDES THE HANGUP. ModemManager first asks
            # AT+CLCC=? and, on ERROR, concludes that this modem cannot
            # return its call list - it then stops the periodic re-read and
            # has nothing left to learn that a call has ended. A real modem
            # answers OK.
            self.ok(); return

        if ub == "+CLCC":
            for i, c in enumerate(self.calls, start=1):
                # 27.007: idx, direction, state, mode, multiparty, number,
                # type. Direction 0 = outgoing, 1 = incoming. State 0 =
                # active, 2 = dialling, 4 = incoming ringing.
                sens = 1 if c["state"] == "incoming" else 0
                etat = {"active": 0, "incoming": 4}.get(c["state"], 2)
                _n, _t = clip(c["num"])
                self.out('+CLCC: %d,%d,%d,0,0,"%s",%d'
                         % (i, sens, etat, _n, _t))
            self.ok(); return

        if ub.startswith("+CMGS="):
            # Two forms: text mode (the number in quotes, for a manual test)
            # and PDU mode (a length - what oFono sends). In both cases the
            # rest arrives after the "> " prompt.
            m = re.search(r'"([^"]+)"', body)
            self.sms_target = m.group(1) if m else "<pdu>"
            try:
                self.wfile.write(b"\r\n> ")
                self.wfile.flush()
            except OSError:
                pass
            return

        if ub == "A":
            # ANSWER. The call ALREADY goes to the bench subscriber - the VM
            # and the mobile are the same 100101, as for SMS. The line cannot
            # be "taken": note that the call is in progress, and the voice
            # comes through the audio bridge (gsm_audio), which the VM
            # already relays.
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
                # A USSD CODE IS NOT A CALL. Phosh's dialler sends "*#100#"
                # as ATD: refused (27.007: operation not allowed); USSD goes
                # through AT+CUSD, below.
                log("ATD%s : code USSD/SS, pas un appel - refuse" % num)
                self.err(3); return
            if num.startswith("*99"):
                # ATD*99***<cid>#: DATA, by PPP on this port (see the Ppp
                # class). Answer CONNECT and the port switches to data mode:
                # NetworkManager starts pppd in the phone, and we hold the
                # other end. The phone's kernel must have
                # ppp_generic/ppp_async (built for it, see tools/osmo-pmos.sh)
                # - without them pppd dies and the port comes back to AT by
                # itself (Ppp.feed recognises an "AT").
                if not LTE.state()["ok"] and not st["up"]:
                    log("data : ATD%s refuse, aucun reseau" % num)
                    self.err(30)                 # 30 = no network service
                    return
                # NO DATA DURING A CS SERVICE. On 2G, a mobile in a call has
                # no data (class B); and here, with a SINGLE port, accepting
                # ATD*99 in the middle of a call would put the port back in
                # data mode: the NO CARRIER of the other party hanging up and
                # the +CEREG of the return to 4G would stay held behind the
                # PPP. NetworkManager retries by itself after the service.
                if DATA is None and self.cs_actif():
                    log("data : ATD%s refuse le temps du service CS (CSFB)" % num)
                    self.out("NO CARRIER")
                    return
                m = re.search(r"\*\*\*(\d+)#", num)
                self.data_cid = int(m.group(1)) if m else 1
                log("data : ATD%s -> CONNECT, PPP sur le port AT (cid %d, APN %s), par %s"
                    % (num, self.data_cid, LTE.state()["apn"],
                       "la 4G (srsUE)" if self.rat() == "lte" else "la 2G"))
                # CONNECT AFTER THE PDP, like a real modem. Answering CONNECT
                # right away would leave the phone's PPP session without an
                # egress during attach + PDP (1 to 3 min on the Calypso).
                # The data port waits for the switch and the PDP; on failure,
                # NO CARRIER, and NetworkManager asks again by itself.
                if GPRS_DATA and self.rat() == "gsm":
                    pdp = _sh("ip", "-n", GPRS_NETNS, "-4", "-o", "addr", "show", GPRS_TUN)
                    if not (pdp[0] == 0 and "inet" in pdp[1]):
                        log("data : ATD%s - le Calypso passe au GPRS, CONNECT a l arrivee du PDP" % num)
                        if not calypso("data", attendre=True):
                            log("data : pas de PDP GPRS, NO CARRIER (le telephone redemandera)")
                            self.out("NO CARRIER")
                            return
                self.out("CONNECT")
                self.port_commande = False
                self.ppp = Ppp(self)
                self.ppp.demarrer()
                return
            # CSFB: the call is made on 2G. Go down BEFORE dialling, as a
            # real UE leaves LTE on the Extended Service Request.
            self.csfb_debut("appel vers %s" % num, couper_data=(DATA is None))
            # "origine" = the REQUEST name of the Local channel
            # ("Local/600@internal"), which Asterisk expands to
            # "...-0000000b;1" and ";2". It is how our own legs are
            # recognised in the AMI events (cf. est_notre_jambe); "channel"
            # will be replaced by the real name.
            # RECORDED BEFORE DIALLING, NOT AFTER: the AMI events arrive on
            # ANOTHER connection (AmiEcoute) and the DialBegin of our second
            # leg (Exten 100101) can precede the return of ami_originate;
            # est_notre_jambe must already find the call.
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
            # 0 reject/release, 1 release the active ones, 1x release call x.
            self.out('+CHLD: (0,1,1x)'); self.ok(); return

        if ub in ("H", "+CHUP") or ub.startswith("+CHLD="):
            # ModemManager hangs up with +CHLD (27.007 § 7.13: 0 = reject the
            # incoming, 1 = release the active ones, 1x = release call x),
            # not with ATH. Without call hold on this bench, all three come
            # down to the same thing - hang up. +CHLD must be handled here
            # and not fall into the general "any ASSIGNMENT is accepted
            # without effect" rule below.
            #
            # WE hang up, so WE announce it, right away, once per call:
            # self.calls is cleared here, so fin_appel() finds nothing to
            # remove when Asterisk tears the channel down and would never
            # emit the NO CARRIER. fin_appel() stays in place for the other
            # direction (the other party hangs up first) and does not
            # duplicate: the list is empty when its event arrives.
            for c in self.calls:
                ami_hangup(c.get("channel", ""))
            n = len(self.calls)
            self.calls.clear()
            mobile("hangup")            # the subscriber is the mobile: it too
            for _ in range(n):
                self.out("NO CARRIER")
            self.csfb_fin_apres()       # nothing left in CS: back to 4G
            self.ok(); return

        if ub.startswith("+CUSD=1,"):
            # USSD, a minimum: *#100# returns the subscriber's number (as on
            # the osmocom-bb mobile); any other code is "released by the
            # network" (+CUSD: 2), without error nor drop to 2G.
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
            self.out("+CBC: 0,80"); self.ok(); return       # powered, 80 %
        if ub == "+CLCK=?":
            self.out('+CLCK: ("SC","AO","OI","AI")'); self.ok(); return

        # THE GENERAL RULE, AND WHY IT IS SAFE. At initialisation oFono runs
        # through some thirty SETTINGS (AT+CRC=1, AT+CNAP=1, AT+CDIP=1,
        # AT+CSCS="GSM"...) whose reply it never reads beyond the OK;
        # refusing them makes it abandon the whole initialisation. So
        # anything that is an ASSIGNMENT is accepted - a modem that accepts
        # a setting it does not apply lies to nobody, it has nothing to
        # report about it. An unknown READ (AT+XXX? or AT+XXX=?), on the
        # other hand, stays refused: there, an invented reply would make
        # oFono believe in a capability that does not exist.
        if "=" in ub and not ub.endswith("=?"):
            log("reglage accepte sans effet : %s" % line)
            self.ok(); return

        log("lecture non geree (refusee) : %s" % line)
        self.err()


# ── SMS RECEPTION: SMPP ESME ON osmo-msc ────────────────────────────────────
# Sending an SMS is done through the VTY ("subscriber ... sms ... send"), but
# RECEIVING requires the MSC to push something to us: the VTY notifies
# nothing. For that osmo-msc exposes an SMPP server (port 2775) to which we
# connect as an ESME. Each SMS routed to us arrives as deliver_sm, and is
# presented to the modem in the form the AT world expects: "+CMT:" with the
# message as a PDU, preceded by the URC.
#
# The protocol is binary but only a handful of messages are used:
# bind_transceiver, enquire_link (the heartbeat), deliver_sm and its reply.
# No library: it would be one more dependency on the image for three
# structures.
SMPP_BIND_TRANSCEIVER = 0x00000009
SMPP_BIND_TRANSCEIVER_RESP = 0x80000009
SMPP_DELIVER_SM = 0x00000005
SMPP_DELIVER_SM_RESP = 0x80000005
SMPP_ENQUIRE_LINK = 0x00000015
SMPP_ENQUIRE_LINK_RESP = 0x80000015


def _cstr(b, i):
    """A zero-terminated string, and the index right after it."""
    j = b.index(b"\x00", i)
    return b[i:j].decode(errors="replace"), j + 1


def gsm7_pack(text):
    """The GSM 7-bit alphabet, packed seven octets for eight characters -
    the default encoding of an SMS."""
    # The EXACT mirror of gsm7_unpack: septets are stacked into a bit buffer
    # and an octet is output as soon as there are eight bits.
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


# ── THE INBOX ───────────────────────────────────────────────────────────────
# WHY SMS MUST BE STORED. The modem does not decide alone how it announces an
# incoming SMS: the system tells it through AT+CNMI=<mode>,<mt>,... Two
# worlds:
#   mt=2: "push me the message right away"      -> URC "+CMT:" + the PDU
#   mt=1: "store it and only tell me where"     -> URC '+CMTI: "SM",<i>'
#         then the system reads it with AT+CMGR=<i>.
# ModemManager (postmarketOS VM) negotiates mt=1 ("AT+CNMI=2,1,2,1,0") and
# even lists the inbox at startup with AT+CMGL=4. Hence this store, and the
# commands that go with it (CMGR, CMGL, CMGD).
INBOX = []                     # [{idx, pdu, sender, text, lu, ts}]
INBOX_LOCK = threading.Lock()
INBOX_MAX = 20                 # what +CPMS announces as capacity


INBOX_DERNIER = [0]            # the last index assigned (see inbox_ranger)


def inbox_ranger(sender, text, pdu):
    """Store an SMS and return its index, like an "SM" memory.

    THE INDEXES ROTATE. ModemManager sometimes keeps a deleted message in
    ITS list (its deletion failed on its side, "SMS storage currently
    locked, try again later", although the modem said OK), and a +CMTI on an
    index it believes already known is ignored. So the NEXT free index is
    always taken, rotating over the 20: an index is reused only after 19
    others."""
    with INBOX_LOCK:
        pris = {m["idx"] for m in INBOX}
        if len(pris) >= INBOX_MAX:
            INBOX.pop(0)       # inbox full: the oldest gives way
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
    """A number in swapped nibbles, as in a PDU."""
    digits = re.sub(r"\D", "", num)
    if len(digits) % 2:
        digits += "F"
    return bytes(int(digits[i + 1] + digits[i], 16) for i in range(0, len(digits), 2))


def scts_maintenant():
    """The timestamp of an SMS-DELIVER (23.040 § 9.2.3.11): six pairs of
    digits in swapped nibbles, then the time zone in quarters of an hour.

    A real modem gives the network time; the bench time is given, which is
    the same. An all-zero timestamp (year 00 / month 00 / day 00) is not a
    valid date and Chatty may drop the message when reading it.
    """
    t = time.localtime()
    out = bytearray(int(("%02d" % v)[::-1], 16) for v in
                    (t.tm_year % 100, t.tm_mon, t.tm_mday,
                     t.tm_hour, t.tm_min, t.tm_sec))
    quarts = -(time.altzone if t.tm_isdst else time.timezone) // 900
    octet = int(("%02d" % abs(quarts))[::-1], 16)
    if quarts < 0:
        octet |= 0x08                  # the sign, bit 3 of the first nibble
    out.append(octet)
    return bytes(out)


def pdu_deliver(sender, text):
    """A complete SMS-DELIVER, as a modem returns it on "+CMT:"."""
    digits = re.sub(r"\D", "", sender)
    oa = bytes([len(digits), 0x81]) + semi_octets(sender)   # 0x81: national number
    ud, n = gsm7_pack(text)
    scts = scts_maintenant()
    pdu = b"\x00" + b"\x04" + oa + b"\x00\x00" + scts + bytes([n]) + ud
    return pdu.hex().upper()


def gsm7_unpack(data, n):
    """The inverse of gsm7_pack: the packed septets become characters again."""
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
    """Read an SMS-SUBMIT and return (number, text).

    oFono does NOT send SMS in text mode: it sends "AT+CMGS=<length>" then
    a PDU, so decoding is required here.
    """
    b = bytes.fromhex(pdu_hex)
    i = 0
    i += 1 + b[0]                      # SMSC length, then skip it
    first = b[i]; i += 1               # type octet
    i += 1                             # message reference
    ndigits = b[i]; i += 1
    i += 1                             # address type
    nbytes = (ndigits + 1) // 2
    num = ""
    for octet in b[i:i + nbytes]:
        num += "%d%d" % (octet & 0x0F, octet >> 4)
    num = num[:ndigits]
    i += nbytes
    i += 1                             # protocol
    dcs = b[i]; i += 1
    if first & 0x10:                   # validity period present
        i += 1
    udl = b[i]; i += 1
    ud = b[i:]
    if dcs & 0x0C == 0x08:             # UCS2
        text = ud[:udl].decode("utf-16-be", errors="replace")
    else:
        text = gsm7_unpack(ud, udl)
    return num, text


class Smpp(threading.Thread):
    """The ESME: binds to the MSC, keeps the link, and delivers SMS to the modem."""

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
            time.sleep(5)          # the MSC restarts, come back to it

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
        i += 2                                    # source ton and npi
        src, i = _cstr(b, i)
        i += 2                                    # destination ton and npi
        dst, i = _cstr(b, i)
        i += 3                                    # esm_class, protocol, priority
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


CURRENT = None                 # the modem currently opened by oFono
# THE MODEM HAS TWO PORTS. On a single port, once ATD*99 has gone through,
# nothing flows in AT any more: the phone can neither call nor send an SMS
# while data is up ("No AT port available"), and incoming ones only arrive
# by cutting the PPP. A real modem has a command port and a data port. Here
# too: CURRENT holds the command port (hvc0, URCs, calls, SMS); DATA holds
# the data port (hvc1, the one ModemManager marks ID_MM_PORT_TYPE_AT_PPP and
# on which it dials ATD*99). Both are AtHandlers on the same bench state; the
# data port refers to CURRENT for the phone state (technology, call in
# progress). Without --data, single port.
DATA = None                    # the data port, if there is one


def on_smpp_sms(sender, text):
    """An SMS arrives from the bench. Two recipients, not one:

    THE ANDROID PHONE IS THE SAME SUBSCRIBER AS THE MOBILE. The bench has
    only one 100101, and it must ring on BOTH sides - in Android through the
    RIL, and on the osmocom-bb mobile. "smpp-first" diverts the SMS to us
    BEFORE internal delivery, so the mobile would see nothing: it is handed
    over by us, through the MSC VTY command, which delivers directly to the
    mobile without going through SMPP again - no loop possible.
    OSMO_SMS_DUPLIQUE=0 to keep only one (Android alone).
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


# ── THE INBOX: THE SMS THE GATEWAY HANDS TO US ──────────────────────────────
# WHY A SECOND PATH, BESIDE SMPP. The bench runs with "sms-over-gsup"
# (osmo-msc.cfg). In that mode, an SM-RP received from the radio goes to the
# HLR WITHOUT ever passing through gsm340_rx_tpdu(): sms_route_mt_sms() is
# not called, hence smpp_try_deliver() neither. "smpp-first" and the "route
# prefix ... 100101" lines of the conf are dead configuration as long as
# sms-over-gsup is there - the ESME above is BOUND to port 2775 and receives
# NOTHING. And the MT that comes back through GSUP is pushed directly to the
# subscriber over the radio: the osmocom-bb mobile gets it, the software
# modems do not.
#
# The gateway therefore notifies the modems where it decides local delivery
# (scripts/sms-interop-relay.py, inject_mt_sms), through
# scripts/sms_notify.py. NOTHING is duplicated here, unlike the SMPP path:
# the mobile already has its copy over the radio, sending it again would
# make it ring twice.
class SmsInHandler(socketserver.StreamRequestHandler):
    """One JSON line: {"imsi": ..., "from": ..., "text": ...}."""

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
            return                       # that SMS is for another subscriber
        on_passerelle_sms(str(msg.get("from") or ""), str(msg.get("text") or ""))
        try:
            self.wfile.write(b'{"ok":true}\n')
        except OSError:
            pass


def on_passerelle_sms(sender, text):
    """No system at the end of the line? Store anyway: the VM may be
    booting, and ModemManager lists the inbox with AT+CMGL=4 as soon as it
    connects. An SMS must not be lost because the modem was absent."""
    if CURRENT is not None:
        CURRENT.deliver_sms(sender, text)
        return
    idx = inbox_ranger(sender, text, pdu_deliver(sender, text))
    log("SMS de la passerelle range en SM[%d], personne au bout du fil : %s"
        % (idx, text))


def boite_entree(port):
    """Open the inbox. Port already taken = the other modem instance has it:
    say so and go on, everything else in the modem works without it."""
    try:
        srv = Server((SMS_IN_HOST, port), SmsInHandler)
    except OSError as e:
        log("boite d entree SMS sur %d impossible (%s)" % (port, e))
        return
    log("boite d entree SMS sur %s:%d" % (SMS_IN_HOST, port))
    threading.Thread(target=srv.serve_forever, daemon=True).start()


class ClientHandler(AtHandler):
    """The same modem, but WE go towards the port.

    WHY THIS MODE. When the modem is plugged into a virtual machine serial
    port, the VM's UEFI firmware treats that port as a console: it reads the
    modem's replies as key presses, believes the boot is being interrupted
    and opens its menu - the VM never boots. The remedy is that NOBODY is at
    the end of the line while the firmware works: QEMU listens
    (server=on,wait=off), and we connect once the system is loaded.
    """

    def __init__(self, sock, addr, role="commande"):
        # StreamRequestHandler.setup() expects self.request and builds
        # connection/rfile/wfile itself: just give it the socket.
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
    """Does the VM's system answer? A witness port is used (the virtual
    machine's SSH, 2222 by default).

    WHY WAIT. The VM's UEFI firmware reads any serial port as a console: if
    the modem connects while it works, its replies pass for key presses and
    the boot stops on the menu. The --connect mode loops every five seconds,
    so it must connect ONLY once the system is up.
    """
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.close()
        return True
    except OSError:
        return False


def connect_to(dest, role="commande"):
    """dest = "host:port": connect and hold the modem on that link."""
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
        # THE TIMEOUT IS FOR CONNECTING, NOT FOR HOLDING THE LINK.
        # create_connection(timeout=10) leaves that timeout ON the socket:
        # the next read would raise socket.timeout after ten seconds of
        # silence and the modem would unplug itself. A modem is silent most
        # of the time - ModemManager only queries it in bursts. So switch
        # back to blocking, like the SMPP link above.
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
