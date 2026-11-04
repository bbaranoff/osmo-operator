#!/usr/bin/env python3
# tools/osmo-hr-transcodeur.py - GSM-HR <-> GSM-FR transcoder between osmo-sip-connector
# and Asterisk, for start.sh --hr.
#
# With --hr the voice is GSM-HR end to end on the GSM side (TCH/H, osmo-mgw in RTP
# passthrough), and the INVITE osmo-sip-connector sends only offers GSM-HR-08: Asterisk
# knows no HR and answers "488 Not Acceptable Here". Nothing in Osmocom transcodes HR.
#
# This process sits on the SIP leg between the two (127.0.0.1:5062):
#
#   osmo-sip-connector 127.0.0.1:5061 <-> [this, :5062] <-> Asterisk 127.0.0.1:5060
#
#   SIP  every message is forwarded to the other side, with our Via on top of requests
#        (taken off the responses, which go back where the request came from), the
#        Contact and the Request-URI rewritten to us so that in-dialog requests (BYE,
#        re-INVITE) also go through. An SDP carrying GSM-HR-08 from osmo-sip-connector
#        (or any SDP from Asterisk once the call is an HR one, and an Asterisk offer
#        while --hr is on) is rewritten: Asterisk is offered GSM (FR, RTP/AVP 3) on our
#        port, osmo-sip-connector GSM-HR-08 on another one.
#   RTP  one pair of sockets per call. HR from osmo-mgw is decoded to PCM and coded to
#        FR for Asterisk, FR from Asterisk decoded and coded to HR for osmo-mgw, each
#        packet sent FROM the port announced in the SDP: osmo-mgw drops RTP that does not
#        come from the remote address it was given.
#
# Codecs: libosmogapk (osmo-gapk built with --enable-gsmhr: the ETSI 06.06 reference
# code), through ctypes like pont/gsm.py does for libosmocoding. libgsmhr keeps the
# reference code's globals per instance: one HR state per direction and per call.
#
# start.sh --hr starts it and points both sides at it (network/setup-lora-codec.sh --on);
# without --hr it is stopped and the direct leg 5061 <-> 5060 comes back.
#
# --lora PORT : the VOICE of the calls with the other node goes on the LoRa radio,
#   as the raw GSM-HR frames of the MGW (coded by the ROM vocoder of the phone), in
#   the KISS frames of the RNode (tools/osmo-lora-voice.py). No codec on that path,
#   nothing on the IP: Asterisk still signals the call (its trunk leg carries no
#   media). A call is "with the other node" when the number dialled starts with the
#   code of another node of /etc/osmo-wan.conf (MO), or when the INVITE from
#   Asterisk carries X-Osmo-WAN (MT, set by [wan_in] of network/setup-wan-mesh.sh).
#   One such call at a time (the link cannot carry two). --lora loop: no radio,
#   the frames come back (test).
#
# Usage: osmo-hr-transcodeur.py [--port 5062] [--sc 127.0.0.1:5061] [--ast 127.0.0.1:5060]
#                               [--rtp 21000-21999] [--lora /dev/ttyUSB0] [--wan-conf FILE] [-v]
import argparse
import ctypes
import hashlib
import importlib.util
import logging
import os
import random
import re
import select
import signal
import socket
import struct
import sys
import time

log = logging.getLogger("hr-transcodeur")

# ── libosmogapk ───────────────────────────────────────────────────────────────
PCM_LEN = 320          # PCM_CANON_LEN: 160 s16 samples
HR_CANON = 14          # HR_CANON_LEN (TS 101 318)
HR_IETF = 15           # RFC 5993: ToC + 14
FR_LEN = 33            # FR_CANON_LEN, RFC 3551 payload type 3
HR_REF_ENC = 40        # HR_REF_ENC_LEN
HR_REF_DEC = 44        # HR_REF_DEC_LEN
CODEC_HR, CODEC_FR = 2, 3
PT_GSM = 3

_conv = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint)
_codec_conv = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                               ctypes.c_uint)


class _FmtDesc(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("codec_type", ctypes.c_int),
                ("description", ctypes.c_char_p), ("name", ctypes.c_char_p),
                ("frame_len", ctypes.c_uint),
                ("conv_from_canon", _conv), ("conv_to_canon", _conv),
                ("header_len", ctypes.c_uint), ("header", ctypes.c_void_p)]


class _CodecDesc(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("description", ctypes.c_char_p),
                ("name", ctypes.c_char_p), ("canon_frame_len", ctypes.c_uint),
                ("codec_enc_format_type", ctypes.c_int), ("codec_dec_format_type", ctypes.c_int),
                ("codec_init", ctypes.CFUNCTYPE(ctypes.c_void_p)),
                ("codec_exit", ctypes.CFUNCTYPE(None, ctypes.c_void_p)),
                ("codec_encode", _codec_conv), ("codec_decode", _codec_conv),
                ("ecu_proc", ctypes.c_void_p)]


_gapk = ctypes.CDLL("libosmogapk.so.0")
_gapk.osmo_gapk_fmt_get_from_name.restype = ctypes.POINTER(_FmtDesc)
_gapk.osmo_gapk_fmt_get_from_name.argtypes = [ctypes.c_char_p]
_gapk.osmo_gapk_fmt_get_from_type.restype = ctypes.POINTER(_FmtDesc)
_gapk.osmo_gapk_fmt_get_from_type.argtypes = [ctypes.c_int]
_gapk.osmo_gapk_codec_get_from_type.restype = ctypes.POINTER(_CodecDesc)
_gapk.osmo_gapk_codec_get_from_type.argtypes = [ctypes.c_int]


def _fmt(name):
    p = _gapk.osmo_gapk_fmt_get_from_name(name.encode())
    if not p:
        raise RuntimeError("format gapk %s absent" % name)
    return p.contents


_HR = _gapk.osmo_gapk_codec_get_from_type(CODEC_HR).contents
_FR = _gapk.osmo_gapk_codec_get_from_type(CODEC_FR).contents
_F_IETF = _fmt("rtp-hr-ietf")
_F_HR_ENC = _gapk.osmo_gapk_fmt_get_from_type(_HR.codec_enc_format_type).contents
_F_HR_DEC = _gapk.osmo_gapk_fmt_get_from_type(_HR.codec_dec_format_type).contents
if not _HR.codec_encode or not _HR.codec_decode:
    sys.exit("osmo-gapk sans codec HR : recompiler avec ./configure --enable-gsmhr")


class _Buf:
    def __init__(self, n):
        self.b = ctypes.create_string_buffer(n)

    def ptr(self):
        return ctypes.cast(self.b, ctypes.c_void_p)


def _src(data):
    b = ctypes.create_string_buffer(bytes(data), len(data))
    return b, ctypes.cast(b, ctypes.c_void_p)


class HrVersFr:
    """HR (RFC 5993 payload) -> PCM -> FR (RFC 3551 payload)."""

    def __init__(self):
        self.hr = _HR.codec_init()
        self.fr = _FR.codec_init()
        if not self.hr or not self.fr:
            raise RuntimeError("codec_init HR/FR")
        self.canon, self.dec, self.pcm, self.out = _Buf(HR_CANON), _Buf(HR_REF_DEC), _Buf(PCM_LEN), _Buf(FR_LEN)

    def __call__(self, payload):
        if len(payload) < HR_IETF or (payload[0] >> 4) & 7 == 7:      # FT NO_DATA
            return None
        keep, p = _src(payload[:HR_IETF])
        _F_IETF.conv_to_canon(self.canon.ptr(), p, HR_IETF)
        _F_HR_DEC.conv_from_canon(self.dec.ptr(), self.canon.ptr(), HR_CANON)
        if _HR.codec_decode(self.hr, self.pcm.ptr(), self.dec.ptr(), HR_REF_DEC) < 0:
            return None
        if _FR.codec_encode(self.fr, self.out.ptr(), self.pcm.ptr(), PCM_LEN) < 0:
            return None
        return self.out.b.raw[:FR_LEN]

    def close(self):
        _HR.codec_exit(self.hr)
        _FR.codec_exit(self.fr)


class FrVersHr:
    """FR (RFC 3551 payload) -> PCM -> HR (RFC 5993 payload)."""

    def __init__(self):
        self.hr = _HR.codec_init()
        self.fr = _FR.codec_init()
        if not self.hr or not self.fr:
            raise RuntimeError("codec_init HR/FR")
        self.pcm, self.enc, self.canon, self.out = _Buf(PCM_LEN), _Buf(HR_REF_ENC), _Buf(HR_CANON), _Buf(HR_IETF)

    def __call__(self, payload):
        if len(payload) != FR_LEN:
            return None
        keep, p = _src(payload)
        if _FR.codec_decode(self.fr, self.pcm.ptr(), p, FR_LEN) < 0:
            return None
        if _HR.codec_encode(self.hr, self.enc.ptr(), self.pcm.ptr(), PCM_LEN) < 0:
            return None
        _F_HR_ENC.conv_to_canon(self.canon.ptr(), self.enc.ptr(), HR_REF_ENC)
        _F_IETF.conv_from_canon(self.out.ptr(), self.canon.ptr(), HR_CANON)
        return self.out.b.raw[:HR_IETF]

    def close(self):
        _HR.codec_exit(self.hr)
        _FR.codec_exit(self.fr)


# ── RTP ───────────────────────────────────────────────────────────────────────
def rtp_payload(pkt):
    if len(pkt) < 12 or pkt[0] >> 6 != 2:
        return None
    n = 12 + 4 * (pkt[0] & 0x0F)
    if pkt[0] & 0x10:
        if len(pkt) < n + 4:
            return None
        n += 4 + 4 * struct.unpack_from(">H", pkt, n + 2)[0]
    end = len(pkt)
    if pkt[0] & 0x20:
        end -= pkt[-1]
    return pkt[n:end] if end > n else None


class RtpSortie:
    def __init__(self, pt):
        self.pt, self.seq, self.ts = pt, random.randrange(65536), random.randrange(1 << 32)
        self.ssrc, self.premier = random.randrange(1 << 32), True

    def paquet(self, payload):
        h = struct.pack(">BBHII", 0x80, (0x80 if self.premier else 0) | self.pt,
                        self.seq, self.ts, self.ssrc)
        self.premier = False
        self.seq = (self.seq + 1) & 0xFFFF
        self.ts = (self.ts + 160) & 0xFFFFFFFF
        return h + payload


class Session:
    """One call: s_mgw faces osmo-mgw (HR), s_ast faces Asterisk (FR).
    lora=True: the HR frames go to / come from the LoRa link instead of Asterisk."""

    def __init__(self, call_id, ports):
        self.call_id = call_id
        self.lora = False
        self.s_mgw = ports.ouvrir()
        self.s_ast = ports.ouvrir()
        self.mgw_remote = None
        self.ast_remote = None
        self.hr_pt = 96
        self.vers_ast, self.vers_mgw = HrVersFr(), FrVersHr()
        self.rtp_ast, self.rtp_mgw = RtpSortie(PT_GSM), None
        self.vu = time.monotonic()
        self.n_hr = self.n_fr = 0
        self.fin = None

    def port_mgw(self):
        return self.s_mgw.getsockname()[1]

    def port_ast(self):
        return self.s_ast.getsockname()[1]

    # Symmetric RTP: once a side has sent, its real source address wins over the SDP
    # c= line (Asterisk may announce its external_media_address there).
    def de_mgw(self, data, addr, lora=None):
        self.vu = time.monotonic()
        self.mgw_remote = addr
        p = rtp_payload(data)
        if p is None:
            return
        if self.lora:
            # RFC 5993 payload -> canonical 14 bytes on the air. FT 7 = no data.
            if lora and len(p) >= HR_IETF and (p[0] >> 4) & 7 != 7:
                self.n_hr += 1
                lora.send(p[1:1 + HR_CANON])
            return
        if not self.ast_remote:
            return
        fr = self.vers_ast(p)
        if fr:
            self.n_hr += 1
            self.s_ast.sendto(self.rtp_ast.paquet(fr), self.ast_remote)

    def de_lora(self, hr14):
        """A frame from the air -> RTP GSM-HR-08 to the MGW."""
        if not self.mgw_remote:
            return
        if self.rtp_mgw is None:
            self.rtp_mgw = RtpSortie(self.hr_pt)
        self.n_fr += 1
        self.s_mgw.sendto(self.rtp_mgw.paquet(b"\x00" + hr14), self.mgw_remote)

    def de_ast(self, data, addr):
        self.vu = time.monotonic()
        self.ast_remote = addr
        if self.lora:
            return                     # Asterisk's leg carries no media on a LoRa call
        p = rtp_payload(data)
        if p is None or not self.mgw_remote:
            return
        if self.rtp_mgw is None:
            self.rtp_mgw = RtpSortie(self.hr_pt)
        hr = self.vers_mgw(p)
        if hr:
            self.n_fr += 1
            self.s_mgw.sendto(self.rtp_mgw.paquet(hr), self.mgw_remote)

    def close(self):
        for s in (self.s_mgw, self.s_ast):
            s.close()
        self.vers_ast.close()
        self.vers_mgw.close()
        if self.lora:
            log.info("appel %s (LoRa) termine : %d trames HR vers l'air, %d de l'air", self.call_id, self.n_hr, self.n_fr)
        else:
            log.info("appel %s termine : %d trames HR->FR, %d FR->HR", self.call_id, self.n_hr, self.n_fr)


class Ports:
    def __init__(self, lo, hi):
        self.lo, self.hi, self.next = lo, hi, lo

    def ouvrir(self):
        for _ in range(self.hi - self.lo + 1):
            p = self.next
            self.next = self.lo if self.next >= self.hi else self.next + 1
            if p % 2:
                continue
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.bind(("127.0.0.1", p))
                return s
            except OSError:
                s.close()
        raise RuntimeError("plus de port RTP libre")


# ── SIP ───────────────────────────────────────────────────────────────────────
HR_RTPMAP = re.compile(r"^a=rtpmap:(\d+)\s+GSM-HR-08/8000", re.I | re.M)


def sdp_media(sdp):
    c = re.search(r"^c=IN IP4 (\S+)", sdp, re.M)
    m = re.search(r"^m=audio (\d+) ", sdp, re.M)
    if not c or not m:
        return None
    return c.group(1), int(m.group(1))


def sdp_reecrire(sdp, port, pt, rtpmap):
    """Same session, one audio codec: pt at 127.0.0.1:port."""
    out = []
    for line in sdp.replace("\r\n", "\n").split("\n"):
        if line.startswith("c=IN IP4 "):
            line = "c=IN IP4 127.0.0.1"
        elif line.startswith("o="):
            f = line.split(" ")
            if len(f) >= 6:
                f[5] = "127.0.0.1"
            line = " ".join(f)
        elif line.startswith("m=audio "):
            f = line.split(" ")
            line = "m=audio %d %s %d" % (port, f[2], pt)
            out.append(line)
            out.append("a=rtpmap:%d %s" % (pt, rtpmap))
            out.append("a=ptime:20")
            continue
        elif line.startswith(("a=rtpmap:", "a=fmtp:", "a=ptime:", "a=maxptime:")):
            continue
        if line:
            out.append(line)
    return "\r\n".join(out) + "\r\n"


class Message:
    def __init__(self, raw):
        head, _, self.body = raw.partition(b"\r\n\r\n")
        lines = head.decode("utf-8", "replace").split("\r\n")
        self.start = lines[0]
        self.headers = lines[1:]
        self.is_request = not self.start.startswith("SIP/2.0")

    def get(self, name, short=None):
        for h in self.headers:
            k = h.split(":", 1)[0].strip().lower()
            if k == name.lower() or (short and k == short):
                return h.split(":", 1)[1].strip()
        return None

    def method(self):
        if self.is_request:
            return self.start.split(" ", 1)[0]
        cseq = self.get("CSeq") or ""
        return cseq.split()[-1] if cseq else ""

    def status(self):
        return 0 if self.is_request else int(self.start.split(" ")[1])

    def bytes(self):
        hs = [h for h in self.headers if h.split(":", 1)[0].strip().lower() not in ("content-length", "l")]
        hs.append("Content-Length: %d" % len(self.body))
        return ("\r\n".join([self.start] + hs) + "\r\n\r\n").encode() + self.body


# ── /etc/osmo-wan.conf : the codes of the OTHER nodes (MO call toward the WAN) ──
def wan_codes_etrangers(path):
    try:
        txt = open(path).read()
    except OSError:
        return []
    m = re.search(r'^WAN_NODES="([^"]*)"', txt, re.M)
    me = re.search(r"^WAN_NODE_ID=(\d+)", txt, re.M)
    if not m:
        return []
    me = me.group(1) if me else ""
    codes = []
    for ent in m.group(1).replace(",", " ").split():
        f = ent.split(":")
        if len(f) >= 3 and f[0] != me:
            codes.append(f[2])
    return codes


def lien_lora(spec, frames=4):
    spec_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osmo-lora-voice.py")
    sp = importlib.util.spec_from_file_location("lora_voice", spec_path)
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod.LoraLink(spec, frames=frames, loop=(spec == "loop"))


class Transcodeur:
    def __init__(self, port, sc, ast, rtp_lo, rtp_hi, lora=None, codes=()):
        self.lora = lora                # LoraLink or None
        self.codes = list(codes)        # WAN codes of the other nodes
        self.lora_sess = None           # the one call on the air
        self.t_lora_stats = time.monotonic()
        self.sip = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sip.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sip.bind(("127.0.0.1", port))
        self.moi = "127.0.0.1:%d" % port
        self.sc, self.ast = sc, ast
        self.ports = Ports(rtp_lo, rtp_hi)
        self.sessions = {}          # Call-ID -> Session
        self.branches = {}          # our branch -> (origin addr, time)
        self.rtp = {}               # socket -> (session, "mgw"|"ast")

    # SIP routing -----------------------------------------------------------
    def autre(self, addr):
        if addr == self.sc or (addr[0] == self.sc[0] and addr[1] != self.ast[1]):
            return self.ast, "sc"
        if addr == self.ast:
            return self.sc, "ast"
        return None, None

    def contact_vers_moi(self, msg):
        for i, h in enumerate(msg.headers):
            k = h.split(":", 1)[0].strip().lower()
            if k in ("contact", "m"):
                msg.headers[i] = re.sub(r"(sips?:(?:[^@;>]*@)?)[^;>:]+(:\d+)?", r"\g<1>" + self.moi, h, count=1)

    def requete(self, msg, dst, origine):
        f = msg.start.split(" ")
        if len(f) == 3:
            f[1] = re.sub(r"^(sips?:(?:[^@;>]*@)?)[^;>:]+(:\d+)?", r"\g<1>%s:%d" % dst, f[1])
            msg.start = " ".join(f)
        via = msg.get("Via", "v") or ""
        br = "z9hG4bK-hrx-" + hashlib.md5((via + msg.start).encode()).hexdigest()[:16]
        self.branches[br] = (origine, time.monotonic())
        msg.headers.insert(0, "Via: SIP/2.0/UDP %s;branch=%s;rport" % (self.moi, br))

    def reponse(self, msg):
        for i, h in enumerate(msg.headers):
            if h.split(":", 1)[0].strip().lower() in ("via", "v"):
                m = re.search(r"branch=(z9hG4bK-hrx-[0-9a-f]+)", h)
                if not m or self.moi not in h:
                    return None
                del msg.headers[i]
                ent = self.branches.get(m.group(1))
                return ent[0] if ent else None
        return None

    # SDP --------------------------------------------------------------------
    def session(self, call_id, creer):
        s = self.sessions.get(call_id)
        if s is None and creer:
            s = self.sessions[call_id] = Session(call_id, self.ports)
            self.rtp[s.s_mgw] = (s, "mgw")
            self.rtp[s.s_ast] = (s, "ast")
            log.info("appel %s : transcodage HR <-> FR (mgw:%d ast:%d)", call_id, s.port_mgw(), s.port_ast())
        return s

    def sdp(self, msg, de):
        ctype = (msg.get("Content-Type", "c") or "").lower()
        if not msg.body or "application/sdp" not in ctype:
            return
        call_id = msg.get("Call-ID", "i")
        sdp = msg.body.decode("utf-8", "replace")
        med = sdp_media(sdp)
        if not med:
            return
        if de == "sc":
            m = HR_RTPMAP.search(sdp)
            s = self.session(call_id, bool(m))
            if not s:
                return                                  # no HR: untouched (full-rate call)
            if m:
                s.hr_pt = int(m.group(1))
            s.mgw_remote = med
            # MO toward the WAN: the number dialled starts with another node's code.
            if self.lora and msg.is_request and msg.method() == "INVITE" and not s.lora:
                user = re.match(r"INVITE sips?:(?:\+)?(\d+)", msg.start)
                if user and any(user.group(1).startswith(c) and len(user.group(1)) > len(c)
                                for c in self.codes):
                    self.appel_lora(s, "vers %s" % user.group(1))
            msg.body = sdp_reecrire(sdp, s.port_ast(), PT_GSM, "GSM/8000").encode()
        else:
            # Asterisk: answer to an HR offer, or an offer (MT call) -- with --hr the
            # radio side only has TCH/H, it must be offered GSM-HR-08.
            s = self.session(call_id, msg.is_request)
            if not s:
                return
            s.ast_remote = med
            # MT from the WAN: [wan_in] marks the INVITE (network/setup-wan-mesh.sh).
            if self.lora and msg.is_request and msg.get("X-Osmo-WAN") and not s.lora:
                self.appel_lora(s, "du WAN, de %s" % (msg.get("From", "f") or "?").split("<")[-1].rstrip(">"))
            msg.body = sdp_reecrire(sdp, s.port_mgw(), s.hr_pt, "GSM-HR-08/8000").encode()

    def appel_lora(self, s, quoi):
        if self.lora_sess and self.lora_sess is not s and self.lora_sess.call_id in self.sessions:
            log.warning("appel %s %s : le LoRa porte deja l'appel %s, celui-ci reste en IP", s.call_id, quoi,
                        self.lora_sess.call_id)
            return
        s.lora = True
        self.lora_sess = s
        log.info("appel %s %s : voix en RF sur le LoRa (trames HR brutes, sans codec)", s.call_id, quoi)

    def fin_appel(self, msg):
        call_id = msg.get("Call-ID", "i")
        s = self.sessions.get(call_id)
        if not s:
            return
        meth, st = msg.method(), msg.status()
        if (msg.is_request and meth == "BYE") or (meth == "INVITE" and st >= 300) or \
                (meth == "CANCEL" and msg.is_request):
            s.fin = s.fin or time.monotonic() + 2.0

    def sip_recu(self, raw, addr):
        if not raw.strip():
            return                                      # keep-alive
        dst, de = self.autre(addr)
        if not dst:
            log.debug("SIP de %s:%d ignore", *addr)
            return
        msg = Message(raw)
        if msg.is_request:
            self.requete(msg, dst, addr)
        else:
            orig = self.reponse(msg)
            if orig is None:
                log.debug("reponse sans notre Via, ignoree : %s", msg.start)
                return
            dst = orig
        self.contact_vers_moi(msg)
        self.sdp(msg, de)
        self.fin_appel(msg)
        self.sip.sendto(msg.bytes(), dst)
        log.debug("%s %s -> %s:%d", de, msg.start, *dst)

    # loop -------------------------------------------------------------------
    def menage(self):
        now = time.monotonic()
        for cid, s in list(self.sessions.items()):
            # Closed on BYE / CANCEL / failed INVITE. The idle limit is only a safety
            # net: a call without RTP in one direction (no speech on the radio side)
            # is still a call.
            if (s.fin and now > s.fin) or now - s.vu > 3600:
                del self.sessions[cid]
                self.rtp.pop(s.s_mgw, None)
                self.rtp.pop(s.s_ast, None)
                if self.lora_sess is s:
                    self.lora_sess = None
                    self.lora.flush()
                s.close()
        for br, (_, t) in list(self.branches.items()):
            if now - t > 64:
                del self.branches[br]

    def run(self):
        log.info("transcodeur HR <-> FR sur %s : sip-connector %s:%d, Asterisk %s:%d",
                 self.moi, *self.sc, *self.ast)
        self.dernier = time.monotonic()
        if self.lora:
            log.info("voix des appels inter-noeuds en RF : %s ; indicatifs des autres noeuds : %s",
                     self.lora.describe(), ", ".join(self.codes) or "aucun (voir --wan-conf)")
        while True:
            self.step(1.0)

    def lora_tick(self):
        """Frames from the air -> the MGW of the LoRa call ; 5 s statistics."""
        if not self.lora:
            return
        for hr14 in self.lora.poll():
            if self.lora_sess:
                self.lora_sess.de_lora(hr14)
        now = time.monotonic()
        if now - self.t_lora_stats >= 5:
            self.t_lora_stats = now
            st = self.lora.stats()
            if st["tx"] or st["rx"]:
                log.info("LoRa 5 s : tx %d trames, rx %d (perdues %d, jetees %d), tampon %d",
                         st["tx"], st["rx"], st["lost"], st["drop"], st["buffer"])

    def step(self, timeout):
        """One select() round: SIP, RTP, and the LoRa link."""
        fds = [self.sip] + list(self.rtp)
        if self.lora:
            timeout = min(timeout, self.lora.timeout())
            if self.lora.fileno() is not None:
                fds.append(self.lora)
        rd, _, _ = select.select(fds, [], [], timeout)
        if self.lora and self.lora in rd:
            rd.remove(self.lora)
        self.lora_tick()
        if True:
            for s in rd:
                try:
                    data, addr = s.recvfrom(8192)
                except OSError:
                    continue
                if s is self.sip:
                    try:
                        self.sip_recu(data, addr)
                    except Exception:
                        log.exception("message SIP de %s:%d", *addr)
                    continue
                ent = self.rtp.get(s)
                if ent:
                    sess, cote = ent
                    try:
                        if cote == "mgw":
                            sess.de_mgw(data, addr, self.lora)
                        else:
                            sess.de_ast(data, addr)
                    except OSError as e:
                        log.warning("appel %s : RTP %s non relaye (%s)", sess.call_id, cote, e)
            if time.monotonic() - self.dernier > 1.0:
                self.dernier = time.monotonic()
                self.menage()


def hote_port(v):
    h, _, p = v.rpartition(":")
    return h, int(p)


def main():
    ap = argparse.ArgumentParser(description="Transcodeur GSM-HR <-> GSM-FR (sip-connector <-> Asterisk)")
    ap.add_argument("--port", type=int, default=5062)
    ap.add_argument("--sc", type=hote_port, default=("127.0.0.1", 5061))
    ap.add_argument("--ast", type=hote_port, default=("127.0.0.1", 5060))
    ap.add_argument("--rtp", default="21000-21999")
    ap.add_argument("--lora", help="port serie du RNode (voix inter-noeuds en RF), ou 'loop' (test)")
    ap.add_argument("--lora-frames", type=int, default=4, help="trames HR par trame LoRa")
    ap.add_argument("--wan-conf", default="/etc/osmo-wan.conf", help="table WAN (indicatifs des autres noeuds)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s [hr-transcodeur] %(message)s", datefmt="%H:%M:%S")
    lo, hi = (int(x) for x in a.rtp.split("-"))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    lora = lien_lora(a.lora, a.lora_frames) if a.lora else None
    codes = wan_codes_etrangers(a.wan_conf) if a.lora else []
    Transcodeur(a.port, a.sc, a.ast, lo, hi, lora=lora, codes=codes).run()


if __name__ == "__main__":
    main()
