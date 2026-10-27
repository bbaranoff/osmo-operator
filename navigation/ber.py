# ber.py - the bare minimum of BER (X.690): enough to write and read TCAP
# and MAP without an external dependency.
#
# Deliberately small: short or long tags, short, long and indefinite lengths,
# primitive and constructed elements. Nothing more is needed for the MAP
# operations the console sends.

def enc_len(n):
    if n < 0x80:
        return bytes([n])
    out = b""
    while n:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    return bytes([0x80 | len(out)]) + out


def tlv(tag, value):
    """tag: integer (0x30) or byte sequence for long tags."""
    if isinstance(tag, int):
        tag = bytes([tag])
    return bytes(tag) + enc_len(len(value)) + value


def enc_int(value, tag=0x02):
    if value == 0:
        return tlv(tag, b"\x00")
    neg = value < 0
    raw = b""
    v = value
    if neg:
        v = -value - 1
    while v:
        raw = bytes([v & 0xFF]) + raw
        v >>= 8
    if neg:
        raw = bytes([(~b) & 0xFF for b in raw])
        if not raw or not (raw[0] & 0x80):
            raw = b"\xff" + raw
    elif raw[0] & 0x80:
        raw = b"\x00" + raw
    return tlv(tag, raw)


def enc_bool(value, tag=0x01):
    return tlv(tag, b"\xff" if value else b"\x00")


def enc_null(tag=0x05):
    return tlv(tag, b"")


def enc_oid(dotted, tag=0x06):
    parts = [int(x) for x in dotted.split(".")]
    body = bytes([parts[0] * 40 + parts[1]])
    for p in parts[2:]:
        if p < 0x80:
            body += bytes([p])
            continue
        chunk = []
        while p:
            chunk.insert(0, (p & 0x7F) | 0x80)
            p >>= 7
        chunk[-1] &= 0x7F
        body += bytes(chunk)
    return tlv(tag, body)


def ctx(num, value, constructed=True):
    """Context tag [num], constructed or primitive."""
    tag = 0x80 | num | (0x20 if constructed else 0x00)
    return tlv(tag, value)


class Elem(object):
    __slots__ = ("tag", "constructed", "value", "children", "raw")

    def __init__(self, tag, constructed, value, children, raw):
        self.tag = tag
        self.constructed = constructed
        self.value = value
        self.children = children
        self.raw = raw

    @property
    def cls(self):
        return (self.tag[0] & 0xC0) >> 6      # 0 univ, 1 appli, 2 ctx, 3 priv

    @property
    def num(self):
        t = self.tag[0] & 0x1F
        if t != 0x1F:
            return t
        n = 0
        for b in self.tag[1:]:
            n = (n << 7) | (b & 0x7F)
        return n

    def find(self, cls, num, deep=True):
        """First element of a given class/number."""
        for e in self.walk() if deep else self.children:
            if e.cls == cls and e.num == num:
                return e
        return None

    def walk(self):
        for c in self.children:
            yield c
            for sub in c.walk():
                yield sub

    def tagstr(self):
        names = {0: "univ", 1: "appl", 2: "ctx", 3: "priv"}
        return "%s[%d]%s" % (names[self.cls], self.num,
                             "c" if self.constructed else "p")

    def __repr__(self):
        return "<%s len=%d>" % (self.tagstr(), len(self.value))


def _read_tag(data, i):
    start = i
    b0 = data[i]
    i += 1
    if (b0 & 0x1F) == 0x1F:
        while i < len(data) and data[i] & 0x80:
            i += 1
        i += 1
    return data[start:i], i


def _read_len(data, i):
    b = data[i]
    i += 1
    if b < 0x80:
        return b, i
    if b == 0x80:
        return -1, i                      # indefinite length
    n = b & 0x7F
    val = int.from_bytes(data[i:i + n], "big")
    return val, i + n


def decode(data, limit=None):
    """Return the list of top-level elements."""
    out = []
    i = 0
    end = len(data) if limit is None else min(limit, len(data))
    while i < end:
        try:
            tag, i = _read_tag(data, i)
            length, i = _read_len(data, i)
        except IndexError:
            break
        if length < 0:                    # indefinite: up to the 00 00
            j = data.find(b"\x00\x00", i)
            if j < 0:
                j = end
            value = data[i:j]
            nxt = j + 2
        else:
            value = data[i:i + length]
            nxt = i + length
        constructed = bool(tag[0] & 0x20)
        children = decode(value) if constructed and value else []
        out.append(Elem(tag, constructed, value, children, data[:nxt]))
        i = nxt
    return out


def dump(elems, indent=0, out=None):
    """Readable tree - used to show a raw MAP answer."""
    out = [] if out is None else out
    for e in elems:
        head = "%s%s len=%d" % ("  " * indent, e.tagstr(), len(e.value))
        if e.constructed and e.children:
            out.append(head)
            dump(e.children, indent + 1, out)
        else:
            out.append("%s  %s" % (head, e.value.hex()))
    return out
