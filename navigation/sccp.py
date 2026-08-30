# sccp.py - SCCP sans connexion (UDT / UDTS / XUDT), juste ce qu'il faut pour
# transporter du TCAP et pour COMPRENDRE un refus.
#
# Le "return cause" d'un UDTS est souvent la seule reponse qu'on obtient d'un
# reseau de labo : "no translation for this address", "unequipped user"...
# Le decoder proprement evite de conclure a tort a un silence.

MSG_UDT = 0x09
MSG_UDTS = 0x0A
MSG_XUDT = 0x11
MSG_XUDTS = 0x12

RETURN_CAUSE = {
    0x00: "no translation for an address of such nature",
    0x01: "no translation for this specific address",
    0x02: "subsystem congestion",
    0x03: "subsystem failure",
    0x04: "unequipped user (SSN absent)",
    0x05: "MTP failure",
    0x06: "network congestion",
    0x07: "unqualified",
    0x08: "error in message transport",
    0x09: "error in local processing",
    0x0A: "destination cannot perform reassembly",
    0x0B: "SCCP failure",
    0x0C: "hop counter violation",
    0x0D: "segmentation not supported",
    0x0E: "segmentation failure",
}

# SSN usuels (Q.713 + usages Osmocom).
SSN = {
    0: "inconnu", 1: "SCCP mgmt", 6: "HLR", 7: "VLR", 8: "MSC", 9: "EIR",
    10: "AUC", 142: "RANAP", 143: "RNSAP", 145: "GMLC", 146: "CAP",
    147: "gsmSCF", 148: "SIWF", 149: "SGSN", 150: "GGSN", 254: "BSSAP",
}

NAI = {0: "inconnu", 1: "abonne", 2: "reserve national", 3: "national",
       4: "international"}


def tbcd(digits):
    """Chiffres -> TBCD (demi-octets inverses, complement F)."""
    digits = "".join(c for c in str(digits) if c in "0123456789*#abc")
    out = bytearray()
    for i in range(0, len(digits), 2):
        lo = int(digits[i], 16)
        hi = int(digits[i + 1], 16) if i + 1 < len(digits) else 0x0F
        out.append((hi << 4) | lo)
    return bytes(out)


def untbcd(raw):
    out = []
    for b in raw:
        for nib in (b & 0x0F, (b >> 4) & 0x0F):
            if nib == 0x0F:
                continue
            out.append("%x" % nib)
    return "".join(out)


def pc_to_int(pc):
    """'1.11.2' (format ITU 3-8-3) ou entier -> entier 14 bits."""
    if isinstance(pc, int):
        return pc
    pc = str(pc).strip()
    if pc.isdigit():
        return int(pc)
    a, b, c = (int(x) for x in pc.split("."))
    return (a << 11) | (b << 3) | c


def int_to_pc(val):
    return "%d.%d.%d" % ((val >> 11) & 0x07, (val >> 3) & 0xFF, val & 0x07)


class Address(object):
    """Adresse SCCP : point code, SSN, et/ou global title (GTI 4)."""

    def __init__(self, pc=None, ssn=None, gt=None, tt=0, np=1, es=2, nai=4,
                 route_on_ssn=None):
        self.pc = pc
        self.ssn = ssn
        self.gt = gt
        self.tt = tt
        self.np = np          # 1 = ISDN/telephony E.164
        self.es = es          # 2 = BCD, nombre pair (ajuste a l'encodage)
        self.nai = nai        # 4 = international
        if route_on_ssn is None:
            route_on_ssn = gt is None
        self.route_on_ssn = route_on_ssn

    def encode(self):
        ai = 0
        body = b""
        if self.pc is not None:
            ai |= 0x01
            val = pc_to_int(self.pc)
            body += bytes([val & 0xFF, (val >> 8) & 0x3F])
        if self.ssn is not None:
            ai |= 0x02
            body += bytes([self.ssn & 0xFF])
        if self.gt:
            ai |= (4 << 2)                       # GTI = 4
            digits = "".join(c for c in str(self.gt) if c.isdigit())
            es = 1 if len(digits) % 2 else 2
            body += bytes([self.tt & 0xFF,
                           ((self.np & 0x0F) << 4) | (es & 0x0F),
                           self.nai & 0x7F]) + tbcd(digits)
        if self.route_on_ssn:
            ai |= 0x40
        return bytes([ai]) + body

    @classmethod
    def decode(cls, raw):
        if not raw:
            return cls()
        ai = raw[0]
        i = 1
        pc = ssn = gt = None
        tt = np = es = nai = 0
        if ai & 0x01:
            pc = int_to_pc(raw[i] | ((raw[i + 1] & 0x3F) << 8))
            i += 2
        if ai & 0x02:
            ssn = raw[i]
            i += 1
        gti = (ai >> 2) & 0x0F
        if gti == 4 and len(raw) > i + 2:
            tt = raw[i]
            np = (raw[i + 1] >> 4) & 0x0F
            es = raw[i + 1] & 0x0F
            nai = raw[i + 2] & 0x7F
            gt = untbcd(raw[i + 3:])
        elif gti == 1 and len(raw) > i:
            nai = raw[i] & 0x7F
            gt = untbcd(raw[i + 1:])
        elif gti == 2 and len(raw) > i:
            tt = raw[i]
            gt = untbcd(raw[i + 1:])
        addr = cls(pc=pc, ssn=ssn, gt=gt, tt=tt, np=np, es=es, nai=nai,
                   route_on_ssn=bool(ai & 0x40))
        return addr

    def __str__(self):
        bits = []
        if self.pc is not None:
            bits.append("PC %s" % self.pc)
        if self.ssn is not None:
            bits.append("SSN %d (%s)" % (self.ssn, SSN.get(self.ssn, "?")))
        if self.gt:
            bits.append("GT %s (nai %s)" % (self.gt, NAI.get(self.nai, self.nai)))
        bits.append("route sur %s" % ("SSN/PC" if self.route_on_ssn else "GT"))
        return ", ".join(bits)


def udt(called, calling, data, pclass=0):
    """UDT : 3 pointeurs relatifs, puis les trois champs de longueur variable."""
    c1 = called.encode()
    c2 = calling.encode()
    f1 = bytes([len(c1)]) + c1
    f2 = bytes([len(c2)]) + c2
    f3 = bytes([len(data)]) + data
    p1 = 3
    p2 = p1 + len(f1) - 1
    p3 = p2 + len(f2) - 1
    return bytes([MSG_UDT, pclass & 0xFF, p1, p2, p3]) + f1 + f2 + f3


class Decoded(object):
    def __init__(self, kind, called=None, calling=None, data=b"", cause=None):
        self.kind = kind
        self.called = called
        self.calling = calling
        self.data = data
        self.cause = cause

    @property
    def cause_text(self):
        if self.cause is None:
            return ""
        return RETURN_CAUSE.get(self.cause, "cause 0x%02x" % self.cause)

    def __str__(self):
        if self.kind == "UDTS":
            return "UDTS - refus SCCP : %s" % self.cause_text
        return "%s vers %s, de %s, %d octets utiles" % (
            self.kind, self.called, self.calling, len(self.data))


def decode(raw):
    if not raw:
        return None
    mtype = raw[0]
    if mtype == MSG_UDT:
        p1, p2, p3 = raw[2], raw[3], raw[4]
        o1, o2, o3 = 2 + p1, 3 + p2, 4 + p3
        called = Address.decode(raw[o1 + 1:o1 + 1 + raw[o1]])
        calling = Address.decode(raw[o2 + 1:o2 + 1 + raw[o2]])
        data = raw[o3 + 1:o3 + 1 + raw[o3]]
        return Decoded("UDT", called, calling, data)
    if mtype == MSG_UDTS:
        cause = raw[1]
        p1, p2, p3 = raw[2], raw[3], raw[4]
        o1, o2, o3 = 2 + p1, 3 + p2, 4 + p3
        called = Address.decode(raw[o1 + 1:o1 + 1 + raw[o1]])
        calling = Address.decode(raw[o2 + 1:o2 + 1 + raw[o2]])
        data = raw[o3 + 1:o3 + 1 + raw[o3]]
        return Decoded("UDTS", called, calling, data, cause)
    if mtype in (MSG_XUDT, MSG_XUDTS):
        # XUDT : classe, hop counter, puis 4 pointeurs. On ne lit que l'utile.
        off = 3
        p1, p2, p3 = raw[off], raw[off + 1], raw[off + 2]
        o1, o2, o3 = off + p1, off + 1 + p2, off + 2 + p3
        called = Address.decode(raw[o1 + 1:o1 + 1 + raw[o1]])
        calling = Address.decode(raw[o2 + 1:o2 + 1 + raw[o2]])
        data = raw[o3 + 1:o3 + 1 + raw[o3]]
        return Decoded("XUDT" if mtype == MSG_XUDT else "XUDTS",
                       called, calling, data,
                       raw[1] if mtype == MSG_XUDTS else None)
    return Decoded("SCCP 0x%02x" % mtype, data=raw[1:])
