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
#   as the raw GSM speech frames of the MGW (coded by the ROM vocoder of the phone),
#   in the KISS frames of the RNode (tools/osmo-lora-voice.py). No codec on that
#   path, nothing on the IP: Asterisk still signals the call (its trunk leg carries
#   no media). A call is "with the other node" when the number dialled starts with
#   the code of another node of /etc/osmo-wan.conf (MO), or when the INVITE from
#   Asterisk carries X-Osmo-WAN (MT, set by [wan_in] of network/setup-wan-mesh.sh).
#   One such call at a time (the link cannot carry two). --lora loop: no radio,
#   the frames come back (test).
#   --codec fr (default): the call stays full-rate (TCH/F) and only the frames that
#   carry speech go on the air (--vad, GSM 06.10 xmaxc); the link takes one talker
#   at a time. --codec hr: --hr mode, HR frames (both sides at once fit).
#   --ptt manual (default): walkie-talkie by hand, STORE AND FORWARD. The RNode
#   firmware's CSMA caps the air at ~2 LoRa frames/s (2.2 kbit/s), far under any
#   GSM codec: live voice cannot pass. So "take" (mobile's VTY, patches/osmocom-bb-
#   mobile-lora-ptt.patch, or tools/lora-ptt) RECORDS what the MGW gives us,
#   "release" SENDS the recording as a message: SEIZE on the air, then the LoRa
#   frames at the pace the module accepts (CMD_READY polled before each one),
#   then RELEASE. The other side keeps the frames and plays the whole message to
#   its MGW when the RELEASE arrives; its own "take" is refused meanwhile. 5 s of
#   speech is ~63 LoRa frames, about 30 s on the air. --ptt live: no recording,
#   the frames go out while we hold the channel (choppy with the stock firmware).
#   --ptt auto: the old VOX, the first to speak seizes (VAD), RELEASE after --hold.
#   --ptt-port 5063: the UDP command port (take / release / status, 127.0.0.1).
#   --priority (node 1): "take" wins over a channel the other side holds.
#   Without --codec hr the transcoder leaves local calls untouched (no HR).
#
# Usage: osmo-hr-transcodeur.py [--port 5062] [--sc 127.0.0.1:5061] [--ast 127.0.0.1:5060]
#                               [--rtp 21000-21999] [--lora /dev/ttyUSB0] [--codec fr|hr]
#                               [--vad 8] [--no-alternat] [--priority] [--wan-conf FILE] [-v]
import argparse
from collections import deque
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

    def __init__(self, call_id, ports, codec="hr"):
        self.call_id = call_id
        self.lora = False
        self.codec = codec            # "hr" or "fr": what the MGW side carries
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

    def pt_mgw(self):
        return PT_GSM if self.codec == "fr" else self.hr_pt

    def rtpmap_mgw(self):
        return "GSM/8000" if self.codec == "fr" else "GSM-HR-08/8000"

    # Symmetric RTP: once a side has sent, its real source address wins over the SDP
    # c= line (Asterisk may announce its external_media_address there).
    def de_mgw(self, data, addr, lora=None):
        self.vu = time.monotonic()
        self.mgw_remote = addr
        p = rtp_payload(data)
        if p is None:
            return
        if self.lora:
            # FR: the 33-byte frame as is. HR: RFC 5993 payload -> canonical 14
            # bytes (FT 7 = no data). The transcoder decides (VAD, alternat).
            if self.codec == "fr":
                frame = p if len(p) == FR_LEN else None
            else:
                frame = p[1:1 + HR_CANON] if len(p) >= HR_IETF and (p[0] >> 4) & 7 != 7 else None
            if frame is not None and lora:
                self.n_hr += 1
                lora(frame)
            return
        if not self.ast_remote:
            return
        fr = self.vers_ast(p)
        if fr:
            self.n_hr += 1
            self.s_ast.sendto(self.rtp_ast.paquet(fr), self.ast_remote)

    def de_lora(self, frame):
        """A frame from the air -> RTP (GSM FR, or GSM-HR-08) to the MGW."""
        if not self.mgw_remote:
            return
        if self.rtp_mgw is None:
            self.rtp_mgw = RtpSortie(self.pt_mgw())
        self.n_fr += 1
        payload = frame if self.codec == "fr" else b"\x00" + frame
        self.s_mgw.sendto(self.rtp_mgw.paquet(payload), self.mgw_remote)

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
            log.info("appel %s (LoRa, %s) termine : %d trames vers l'air, %d de l'air", self.call_id,
                     self.codec.upper(), self.n_hr, self.n_fr)
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


_lora_mod = None


def lora_module():
    global _lora_mod
    if _lora_mod is None:
        spec_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osmo-lora-voice.py")
        sp = importlib.util.spec_from_file_location("lora_voice", spec_path)
        _lora_mod = importlib.util.module_from_spec(sp)
        sp.loader.exec_module(_lora_mod)
    return _lora_mod


def lien_lora(spec, frames=4, codec="fr"):
    mod = lora_module()
    return mod.LoraLink(spec, frames=frames, loop=(spec == "loop"),
                        frame_len=mod.FR if codec == "fr" else mod.HR)


class Transcodeur:
    def __init__(self, port, sc, ast, rtp_lo, rtp_hi, lora=None, codes=(), codec="hr",
                 vad=8, alternat=True, priority=False, hold=1.5, theirs_timeout=3.0,
                 ptt="manual", ptt_port=5063):
        self.lora = lora                # LoraLink or None
        self.codes = list(codes)        # WAN codes of the other nodes
        self.codec = codec              # codec of the LoRa calls ("fr" / "hr")
        self.hr = (codec == "hr")       # HR mode: local calls transcoded HR <-> FR
        self.lora_sess = None           # the one call on the air
        self.t_lora_stats = time.monotonic()
        # Walkie-talkie: manual (take / release on the command port) or auto (VOX:
        # speech gate on FR frames, the first to speak seizes).
        self.ptt = ptt if lora else None
        self.vad = lora_module().Vad(vad, 8) if (lora and codec == "fr" and vad > 0 and ptt == "auto") else None
        self.alternat, self.priority, self.hold = alternat or ptt == "manual", priority, hold
        self.ptt_sock = None
        if lora and ptt in ("manual", "live"):
            self.ptt_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.ptt_sock.bind(("127.0.0.1", ptt_port))
        # The semaphore: FREE, MINE (we hold the channel), THEIRS (the other node does).
        self.floor = "FREE"
        self.t_rx_last = 0.0            # last frame heard from the other node
        self.t_tx_last = 0.0            # last frame we put on the air
        self.n_yield = 0                # frames dropped because the other side holds the channel
        # Store-and-forward (ptt manual): what we record, and the message being sent.
        self.record = []                # speech frames recorded since "take"
        self.recording = False
        self.sending = None             # deque of LoRa payload tuples still to send
        self.sent_total = 0
        self.t_ready_query = 0.0
        self.RECORD_MAX = 3000          # 60 s of speech
        if lora and ptt == "manual":
            lora.hold_playout = True
            lora.max_rx = self.RECORD_MAX
        # hold: silence before we give the channel back (a pause between two
        # sentences must NOT release it, or the other side grabs it on a breath
        # and the talker gets cut: 0.4 s was far too short on the air).
        # theirs_timeout: a lost RELEASE must not block us forever.
        self.THEIRS_TIMEOUT = theirs_timeout if ptt != "manual" else max(theirs_timeout, 8.0)
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
    # ── the semaphore ──
    def floor_set(self, state, why):
        if state != self.floor:
            log.info("canal : %s -> %s (%s)", self.floor, state, why)
            self.floor = state

    # ── manual PTT: "take" / "release" / "status" on the command port ──
    # ── manual PTT (store-and-forward): "take" / "release" / "status" on the command port ──
    def ptt_commande(self, data, addr):
        mod = lora_module()
        cmd = data.decode("utf-8", "replace").strip().lower()
        etat = {"FREE": "canal libre", "MINE": "canal a nous", "THEIRS": "canal a l'autre"}
        fl = self.lora.frames
        if cmd in ("take", "t", "prendre"):
            if not self.lora_sess:
                rep = "pas d'appel LoRa en cours, rien a prendre"
            elif self.recording:
                rep = "deja en enregistrement (%.1f s) : release pour envoyer" % (len(self.record) * 0.02)
            elif self.sending is not None:
                rep = "envoi en cours (%d trames LoRa restantes) : attendre" % len(self.sending)
            elif self.floor == "THEIRS" and not self.priority:
                rep = "refuse : l'autre envoie un message (attendre son release)"
            else:
                self.record = []
                self.recording = True
                rep = "enregistrement : parlez, puis release pour envoyer"
        elif cmd in ("release", "r", "lacher"):
            if self.recording:
                self.recording = False
                n = len(self.record)
                if n == 0:
                    rep = "rien enregistre, rien envoye"
                else:
                    self.sending = deque(tuple(self.record[i:i + fl]) for i in range(0, n, fl))
                    self.sent_total = len(self.sending)
                    self.record = []
                    self.lora.send_control(mod.SEIZE)
                    self.floor_set("MINE", "envoi d'un message de %d trames LoRa" % self.sent_total)
                    self.t_ready_query = 0.0
                    rep = "envoi de %.1f s de parole : %d trames LoRa, compter ~%.0f s sur l'air" % (
                        n * 0.02, self.sent_total, self.sent_total / 2.0)
            elif self.sending is not None:
                rep = "envoi en cours (%d/%d trames LoRa)" % (self.sent_total - len(self.sending), self.sent_total)
            else:
                rep = "rien a envoyer (%s)" % etat[self.floor]
        elif cmd in ("status", "s", "etat", "?"):
            if self.recording:
                rep = "enregistrement en cours : %.1f s" % (len(self.record) * 0.02)
            elif self.sending is not None:
                rep = "envoi : %d/%d trames LoRa" % (self.sent_total - len(self.sending), self.sent_total)
            else:
                rep = etat[self.floor] + ("" if self.lora_sess else " ; pas d'appel LoRa") + \
                      (" ; message de l'autre en reception : %d trames" % len(self.lora.rx) if self.lora.rx else "")
        else:
            rep = "commandes : take (enregistrer) | release (envoyer) | status"
        log.info("PTT %s de %s:%d -> %s", cmd, addr[0], addr[1], rep)
        try:
            self.ptt_sock.sendto(rep.encode(), addr)
        except OSError:
            pass

    def envoi_tick(self, now):
        """Store-and-forward sender: one LoRa frame when the module says it has room."""
        if self.sending is None:
            return
        if not self.sending:
            self.lora.send_control(lora_module().RELEASE)
            self.floor_set("FREE", "message envoye (%d trames LoRa)" % self.sent_total)
            self.sending = None
            return
        ready = self.lora.is_ready()
        if ready is None and now - self.t_ready_query > 0.5:
            ready = True                               # no answer: fall back to the known pace
        if ready:
            self.lora.send_now(self.sending.popleft())
            self.lora.query_ready()
            self.t_ready_query = now
            self.t_tx_last = now
        elif ready is False and now - self.t_ready_query > 0.1:
            self.lora.query_ready()
            self.t_ready_query = now

    def floor_tick(self, now):
        """Timeouts: auto mode releases after `hold` of silence; their seizure expires."""
        if self.floor == "MINE" and self.ptt not in ("manual", "live") and now - self.t_tx_last >= self.hold:
            self.lora.send_control(lora_module().RELEASE)
            self.floor_set("FREE", "fin de parole, RELEASE envoye")
        elif self.floor == "THEIRS" and now - self.t_rx_last >= self.THEIRS_TIMEOUT:
            self.floor_set("FREE", "plus rien de l'autre depuis %.1f s" % self.THEIRS_TIMEOUT)

    def floor_heard(self, now, cmd=None):
        """The other node sent voice (cmd None), SEIZE or RELEASE."""
        mod = lora_module()
        self.t_rx_last = now
        if cmd == mod.RELEASE:
            if self.floor == "THEIRS":
                self.floor_set("FREE", "RELEASE recu")
            if self.ptt == "manual":
                n = self.lora.release_playout()
                if n:
                    log.info("message de l'autre complet : %d trames (%.1f s), lecture vers le MGW", n, n * 0.02)
            return
        # voice or SEIZE: they hold the channel, unless we hold it with priority
        if self.floor == "MINE" and self.priority:
            return
        if self.floor == "MINE":
            self.floor_set("THEIRS", "collision, l'autre est prioritaire")
        elif self.floor == "FREE":
            self.floor_set("THEIRS", "SEIZE recu" if cmd else "voix recue")

    # Our frame toward the air: speech gate, then the semaphore.
    def vers_air(self, frame):
        if self.vad and not self.vad.speech(frame):
            return
        now = time.monotonic()
        if self.ptt == "manual":
            if self.recording:
                if len(self.record) < self.RECORD_MAX:
                    self.record.append(frame)
            else:
                self.n_yield += 1            # not recording: nothing goes out
            return
        if self.ptt == "live":
            if self.floor != "MINE":
                self.n_yield += 1            # nothing goes out unless we took the channel
                return
        elif self.alternat:
            if self.floor == "THEIRS":
                self.n_yield += 1            # the other side holds the channel: we listen
                return
            if self.floor == "FREE":
                self.lora.send_control(lora_module().SEIZE)
                self.floor_set("MINE", "parole, SEIZE envoye")
        self.t_tx_last = now
        self.lora.send(frame)

    def session(self, call_id, creer, codec=None):
        s = self.sessions.get(call_id)
        if s is None and creer:
            s = self.sessions[call_id] = Session(call_id, self.ports, codec or ("hr" if self.hr else "fr"))
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
            # MO toward the WAN: the number dialled starts with another node's code.
            wan = None
            if self.lora and msg.is_request and msg.method() == "INVITE":
                user = re.match(r"INVITE sips?:(?:\+)?(\d+)", msg.start)
                if user and any(user.group(1).startswith(c) and len(user.group(1)) > len(c)
                                for c in self.codes):
                    wan = user.group(1)
            # HR mode: every HR offer is a session (transcoded). FR mode: only the
            # LoRa calls, with the codec the MGW offers (FR unless HR is offered).
            s = self.session(call_id, (self.hr and bool(m)) or bool(wan), "hr" if m else "fr")
            if not s:
                return                                  # untouched (full-rate local call)
            if m:
                s.hr_pt = int(m.group(1))
            s.mgw_remote = med
            if wan and not s.lora:
                self.appel_lora(s, "vers %s" % wan)
            msg.body = sdp_reecrire(sdp, s.port_ast(), PT_GSM, "GSM/8000").encode()
        else:
            # Asterisk: answer to an offer, or an offer (MT call). MT from the WAN:
            # [wan_in] marks the INVITE (network/setup-wan-mesh.sh). With --hr the
            # radio side only has TCH/H, the MGW must be offered GSM-HR-08; in FR
            # mode a LoRa MT call is offered GSM (FR) and local MT calls are left alone.
            wan = bool(self.lora and msg.is_request and msg.get("X-Osmo-WAN"))
            s = self.session(call_id, msg.is_request and (self.hr or wan))
            if not s:
                return
            s.ast_remote = med
            if wan and not s.lora:
                self.appel_lora(s, "du WAN, de %s" % (msg.get("From", "f") or "?").split("<")[-1].rstrip(">"))
            msg.body = sdp_reecrire(sdp, s.port_mgw(), s.pt_mgw(), s.rtpmap_mgw()).encode()

    def appel_lora(self, s, quoi):
        if self.lora_sess and self.lora_sess is not s and self.lora_sess.call_id in self.sessions:
            log.warning("appel %s %s : le LoRa porte deja l'appel %s, celui-ci reste en IP", s.call_id, quoi,
                        self.lora_sess.call_id)
            return
        s.lora = True
        self.lora_sess = s
        log.info("appel %s %s : voix en RF sur le LoRa (trames %s brutes du vocodeur ROM, sans codec%s%s)",
                 s.call_id, quoi, s.codec.upper(), ", VAD" if self.vad else "",
                 ", alternat%s" % (" prioritaire" if self.priority else "") if self.alternat else "")

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
                    if self.floor == "MINE":
                        self.lora.send_control(lora_module().RELEASE)
                        self.floor_set("FREE", "fin d'appel")
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
            log.info("voix des appels inter-noeuds en RF : %s ; talkie %s ; indicatifs des autres noeuds : %s",
                     self.lora.describe(),
                     ("MANUEL store-and-forward : take enregistre, release envoie, sur 127.0.0.1:%d (VTY du mobile, tools/lora-ptt)%s" % (
                         self.ptt_sock.getsockname()[1], ", prioritaire" if self.priority else ""))
                     if self.ptt == "manual" else ("LIVE : take / release sur 127.0.0.1:%d%s, l'autre expire apres %.1f s" % (
                         self.ptt_sock.getsockname()[1], ", prioritaire" if self.priority else "", self.THEIRS_TIMEOUT))
                     if self.ptt == "live" else
                     ("auto (VOX seuil %s%s, RELEASE apres %.1f s de silence)" % (
                         self.vad.threshold if self.vad else "-", ", prioritaire" if self.priority else "", self.hold)),
                     ", ".join(self.codes) or "aucun (voir --wan-conf)")
        while True:
            self.step(1.0)

    def lora_tick(self):
        """Frames from the air -> the MGW of the LoRa call ; 5 s statistics."""
        if not self.lora:
            return
        frames = self.lora.poll()
        now = time.monotonic()
        # The semaphore follows the ORDER of arrival: "voice then RELEASE" frees
        # the channel, "RELEASE then voice" is a new seizure.
        self.lora.controls.clear()
        while self.lora.events:
            kind, val = self.lora.events.popleft()
            self.floor_heard(now, val if kind == "ctl" else None)
        if frames and self.lora_sess:
            for fr in frames:
                self.lora_sess.de_lora(fr)
        if self.alternat:
            self.floor_tick(now)
        if self.ptt == "manual":
            self.envoi_tick(now)
            # a message cut by a lost RELEASE: play what we have after 6 s of silence
            if self.lora.rx and not self.lora.playing and now - self.lora.t_rx_frame > 6.0:
                log.info("message de l'autre sans RELEASE : lecture de %d trames", self.lora.release_playout())
        if now - self.t_lora_stats >= 5:
            self.t_lora_stats = now
            st = self.lora.stats()
            v = self.vad
            if st["tx"] or st["rx"] or (v and (v.n_speech or v.n_silence)) or self.n_yield:
                log.info("LoRa 5 s : tx %d trames LoRa, rx %d (perdues %d, jetees %d), tampon %d%s%s",
                         st["tx"], st["rx"], st["lost"], st["drop"], st["buffer"],
                         " ; VAD parole %d / silence %d" % (v.n_speech, v.n_silence) if v else "",
                         " ; cedees a l'autre %d" % self.n_yield if self.n_yield else "")
                if self.alternat:
                    log.info("canal : %s" % {"FREE": "libre", "MINE": "a nous", "THEIRS": "a l'autre"}[self.floor])
                rs = self.lora.radio_stats()
                if rs:
                    log.info("module : %s", rs)
            if v:
                v.n_speech = v.n_silence = 0
            self.n_yield = 0

    def step(self, timeout):
        """One select() round: SIP, RTP, and the LoRa link."""
        fds = [self.sip] + list(self.rtp)
        if self.lora:
            timeout = min(timeout, self.lora.timeout())
            if self.lora.fileno() is not None:
                fds.append(self.lora)
            if self.ptt_sock:
                fds.append(self.ptt_sock)
        rd, _, _ = select.select(fds, [], [], timeout)
        if self.lora and self.lora in rd:
            rd.remove(self.lora)
        if self.ptt_sock and self.ptt_sock in rd:
            rd.remove(self.ptt_sock)
            try:
                self.ptt_commande(*self.ptt_sock.recvfrom(256))
            except OSError:
                pass
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
                            sess.de_mgw(data, addr, self.vers_air if self.lora else None)
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
    ap.add_argument("--lora-frames", type=int, default=4, help="trames parole par trame LoRa")
    ap.add_argument("--codec", choices=["fr", "hr"], default="fr",
                    help="fr : appels LoRa en full-rate, locaux non touches ; hr : mode --hr (transcodage local, LoRa en HR)")
    ap.add_argument("--vad", type=int, default=8, help="seuil de parole (xmaxc GSM 06.10) des trames FR vers l'air, 0 = tout envoyer")
    ap.add_argument("--no-alternat", action="store_true", help="pas de discipline talkie : chacun emet quand il parle")
    ap.add_argument("--priority", action="store_true", help="alternat : ce noeud garde la parole si les deux parlent (noeud 1)")
    ap.add_argument("--ptt", choices=["manual", "live", "auto"], default="manual",
                    help="manual : take enregistre, release envoie le message (store-and-forward) ; live : trames en direct tant qu'on tient ; auto : VOX")
    ap.add_argument("--ptt-port", type=int, default=5063, help="port UDP des commandes take / release / status (127.0.0.1)")
    ap.add_argument("--hold", type=float, default=1.5, help="auto : secondes de silence avant de rendre le canal (RELEASE)")
    ap.add_argument("--theirs-timeout", type=float, default=3.0, help="alternat : secondes sans trame de l'autre avant de le considerer parti")
    ap.add_argument("--wan-conf", default="/etc/osmo-wan.conf", help="table WAN (indicatifs des autres noeuds)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s [hr-transcodeur] %(message)s", datefmt="%H:%M:%S")
    lo, hi = (int(x) for x in a.rtp.split("-"))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    lora = lien_lora(a.lora, a.lora_frames, a.codec) if a.lora else None
    codes = wan_codes_etrangers(a.wan_conf) if a.lora else []
    Transcodeur(a.port, a.sc, a.ast, lo, hi, lora=lora, codes=codes, codec=a.codec, vad=a.vad,
                alternat=not a.no_alternat, priority=a.priority, hold=a.hold,
                theirs_timeout=a.theirs_timeout, ptt=a.ptt, ptt_port=a.ptt_port).run()


if __name__ == "__main__":
    main()
