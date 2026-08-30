# tcap.py - TCAP (Q.773) : begin / continue / end / abort, et les composants
# invoke / returnResultLast / returnError / reject.
#
# La console emet un begin contenant UN invoke, et lit ce qui revient. Le
# dialogue (AARQ/AARE) porte le contexte applicatif MAP : sans lui, un vrai
# HLR repond "abort" - on le met donc systematiquement.

from . import ber

# Tags applicatifs des messages TCAP.
BEGIN, END, CONTINUE, ABORT = 0x62, 0x64, 0x65, 0x67
TID_ORIG, TID_DEST = 0x48, 0x49
DIALOGUE, COMPONENTS = 0x6B, 0x6C

# Composants.
INVOKE, RET_RES_LAST, RET_ERROR, REJECT = 0xA1, 0xA2, 0xA3, 0xA4

DIALOGUE_AS_ID = "0.0.17.773.1.1.1"

MSG_NAME = {BEGIN: "begin", END: "end", CONTINUE: "continue", ABORT: "abort"}
COMP_NAME = {INVOKE: "invoke", RET_RES_LAST: "returnResultLast",
             RET_ERROR: "returnError", REJECT: "reject"}


def dialogue_request(app_context_oid):
    """dialoguePortion contenant un AARQ (demande d'ouverture)."""
    aarq = ber.tlv(0x60,
                   ber.tlv(0x80, b"\x07\x80") +               # version 1
                   ber.ctx(1, ber.enc_oid(app_context_oid)))
    external = ber.tlv(0x28,
                       ber.enc_oid(DIALOGUE_AS_ID) +
                       ber.ctx(0, aarq))
    return ber.tlv(DIALOGUE, external)


def invoke(invoke_id, opcode, parameter=b""):
    body = ber.enc_int(invoke_id) + ber.enc_int(opcode)
    if parameter:
        body += parameter
    return ber.tlv(INVOKE, body)


def begin(otid, components, app_context_oid=None):
    body = ber.tlv(TID_ORIG, otid)
    if app_context_oid:
        body += dialogue_request(app_context_oid)
    body += ber.tlv(COMPONENTS, components)
    return ber.tlv(BEGIN, body)


def end(dtid, components=b"", app_context_oid=None):
    body = ber.tlv(TID_DEST, dtid)
    if app_context_oid:
        body += dialogue_request(app_context_oid)
    if components:
        body += ber.tlv(COMPONENTS, components)
    return ber.tlv(END, body)


class Component(object):
    def __init__(self, kind, invoke_id=None, opcode=None, error=None,
                 parameter=None, raw=b""):
        self.kind = kind
        self.invoke_id = invoke_id
        self.opcode = opcode
        self.error = error
        self.parameter = parameter
        self.raw = raw


class Message(object):
    def __init__(self, kind="?", otid=b"", dtid=b"", components=None,
                 app_context="", abort_reason="", raw=b""):
        self.kind = kind
        self.otid = otid
        self.dtid = dtid
        self.components = components or []
        self.app_context = app_context
        self.abort_reason = abort_reason
        self.raw = raw

    def __str__(self):
        s = "TCAP %s" % self.kind
        if self.otid:
            s += " otid=%s" % self.otid.hex()
        if self.dtid:
            s += " dtid=%s" % self.dtid.hex()
        if self.app_context:
            s += " ac=%s" % self.app_context
        for c in self.components:
            s += " | %s" % c.kind
        return s


def _oid_str(raw):
    if not raw:
        return ""
    vals = [raw[0] // 40, raw[0] % 40]
    n = 0
    for b in raw[1:]:
        n = (n << 7) | (b & 0x7F)
        if not b & 0x80:
            vals.append(n)
            n = 0
    return ".".join(str(v) for v in vals)


def parse(data):
    """Rend un Message, ou None si ce n'est pas du TCAP."""
    top = ber.decode(data)
    if not top:
        return None
    e = top[0]
    kind = MSG_NAME.get(e.tag[0], "0x%02x" % e.tag[0])
    msg = Message(kind=kind, raw=data)
    for child in e.children:
        t = child.tag[0]
        if t == TID_ORIG:
            msg.otid = child.value
        elif t == TID_DEST:
            msg.dtid = child.value
        elif t == DIALOGUE:
            for sub in child.walk():
                if sub.cls == 0 and sub.num == 6 and len(sub.value) > 3:
                    oid = _oid_str(sub.value)
                    if oid != DIALOGUE_AS_ID:
                        msg.app_context = oid
        elif t == COMPONENTS:
            for comp in child.children:
                msg.components.append(_parse_component(comp))
        elif kind == "abort":
            msg.abort_reason = child.tagstr() + " " + child.value.hex()
    return msg


def _parse_component(comp):
    kind = COMP_NAME.get(comp.tag[0], comp.tagstr())
    invoke_id = opcode = error = None
    parameter = None
    kids = comp.children
    if kind == "invoke" and len(kids) >= 2:
        invoke_id = int.from_bytes(kids[0].value, "big", signed=True)
        opcode = int.from_bytes(kids[1].value, "big", signed=True)
        parameter = kids[2] if len(kids) > 2 else None
    elif kind == "returnResultLast" and kids:
        invoke_id = int.from_bytes(kids[0].value, "big", signed=True)
        if len(kids) > 1 and kids[1].constructed and kids[1].children:
            inner = kids[1].children
            opcode = int.from_bytes(inner[0].value, "big", signed=True)
            parameter = inner[1] if len(inner) > 1 else None
    elif kind == "returnError" and len(kids) >= 2:
        invoke_id = int.from_bytes(kids[0].value, "big", signed=True)
        error = int.from_bytes(kids[1].value, "big", signed=True)
        parameter = kids[2] if len(kids) > 2 else None
    elif kind == "reject" and kids:
        invoke_id = int.from_bytes(kids[0].value, "big", signed=True)
        parameter = kids[1] if len(kids) > 1 else None
    return Component(kind, invoke_id, opcode, error, parameter, comp.value)


def dialogue_response(app_context_oid, result=0, diagnostic=0):
    """dialoguePortion contenant un AARE (acceptation d'ouverture)."""
    aare = ber.tlv(0x61,
                   ber.tlv(0x80, b"\x07\x80") +
                   ber.ctx(1, ber.enc_oid(app_context_oid)) +
                   ber.ctx(2, ber.enc_int(result)) +
                   ber.ctx(3, ber.ctx(1, ber.enc_int(diagnostic))))
    external = ber.tlv(0x28, ber.enc_oid(DIALOGUE_AS_ID) + ber.ctx(0, aare))
    return ber.tlv(DIALOGUE, external)


def return_result_last(invoke_id, opcode, parameter=b""):
    inner = ber.enc_int(opcode) + parameter
    return ber.tlv(RET_RES_LAST, ber.enc_int(invoke_id) + ber.tlv(0x30, inner))


def return_error(invoke_id, error_code, parameter=b""):
    return ber.tlv(RET_ERROR,
                   ber.enc_int(invoke_id) + ber.enc_int(error_code) + parameter)


def end_response(dtid, components, app_context_oid=None):
    """end + AARE : la reponse complete a un begin."""
    body = ber.tlv(TID_DEST, dtid)
    if app_context_oid:
        body += dialogue_response(app_context_oid)
    body += ber.tlv(COMPONENTS, components)
    return ber.tlv(END, body)
