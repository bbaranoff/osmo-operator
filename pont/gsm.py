import ctypes
import struct

HYPERFRAME = 26 * 51 * 2048
FRAME_DUR = 60.0 / 13000.0
MACBLOCK_LEN = 23
FR_BYTES = 33

GSMTAP_BCCH = 0x01
GSMTAP_CCCH = 0x04
GSMTAP_SDCCH4 = 0x07
GSMTAP_TCH_F = 0x09
GSMTAP_ACCH = 0x80
GSMTAP_SACCH = GSMTAP_SDCCH4 | GSMTAP_ACCH
GSMTAP_TCH_ACCH = GSMTAP_TCH_F | GSMTAP_ACCH

RR_PD = 0x06
RR_ASSIGNMENT_COMMAND = 0x2e
RR_ASSIGNMENT_COMPLETE = 0x29
RR_CHANNEL_RELEASE = 0x0d
RR_IMMEDIATE_ASSIGNMENT = 0x3f
RR_IMMEDIATE_ASSIGNMENT_EXT = 0x39
SI_TYPES = frozenset((0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e))
CCCH_TYPES = frozenset((0x3f, 0x39, 0x3a, 0x21, 0x22, 0x24))

TSC7 = bytes((1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0))
RACH_SYNC = bytes(int(c) for c in "01001011011111111001100110101010001111000")
RACH_SLOTS_51 = frozenset([4, 5] + list(range(14, 37)) + [45, 46])
SCH_SLOTS_51 = frozenset((1, 11, 21, 31, 41))
DUMMY_BURST = bytes((
    0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0,
    0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0,
    0, 0, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1,
    1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 0))
DUMMY_TOLERANCE = 8

_SOFT = bytes([127, 129] + [129] * 254)
_ONEBIT = bytes([0] + [1] * 255)

ubit = ctypes.c_int8
sbit = ctypes.c_int8
_cod = ctypes.CDLL("libosmocoding.so", use_errno=True)
_cod.gsm0503_xcch_encode.argtypes = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8)]
_cod.gsm0503_xcch_decode.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit),
                                     ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_rach_ext_encode.argtypes = [ctypes.POINTER(ubit), ctypes.c_uint16, ctypes.c_uint8, ctypes.c_bool]
_cod.gsm0503_sch_decode.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit)]
_cod.gsm0503_tch_fr_encode.argtypes = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8), ctypes.c_int, ctypes.c_int]
_cod.gsm0503_tch_fr_decode.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit), ctypes.c_int,
                                       ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_gsm = ctypes.CDLL("libosmogsm.so", use_errno=True)
_gsm.osmo_a5.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32,
                         ctypes.POINTER(ubit), ctypes.POINTER(ubit)]


def normalize_bits(raw148):
    return raw148.translate(_ONEBIT)


def is_dummy(burst):
    errors = 0
    for a, b in zip(burst, DUMMY_BURST):
        if a != b:
            errors += 1
            if errors > DUMMY_TOLERANCE:
                return False
    return True


def coded_from_burst(burst):
    return burst[3:61] + burst[87:145]


def burst_from_coded(coded):
    return bytes(3) + bytes(coded[:58]) + TSC7 + bytes(coded[58:116]) + bytes(3)


def _soft(bursts):
    return b"".join(bytes(b).translate(_SOFT) for b in bursts)


def xcch_decode(bursts4):
    buf = (sbit * (4 * 116)).from_buffer_copy(_soft(bursts4))
    l2 = (ctypes.c_uint8 * MACBLOCK_LEN)()
    ne = ctypes.c_int()
    nb = ctypes.c_int()
    rc = _cod.gsm0503_xcch_decode(l2, buf, ctypes.byref(ne), ctypes.byref(nb))
    return bytes(l2) if rc == 0 else None


def xcch_encode(l2):
    data = (ctypes.c_uint8 * MACBLOCK_LEN)(*l2[:MACBLOCK_LEN])
    e = (ubit * (4 * 116))()
    _cod.gsm0503_xcch_encode(e, data)
    raw = bytes(e)
    return [burst_from_coded(raw[k * 116:(k + 1) * 116]) for k in range(4)]


def tch_fr_decode(bursts8):
    buf = (sbit * (8 * 116)).from_buffer_copy(_soft(bursts8))
    out = (ctypes.c_uint8 * FR_BYTES)()
    ne = ctypes.c_int()
    nb = ctypes.c_int()
    rc = _cod.gsm0503_tch_fr_decode(out, buf, 1, 0, ctypes.byref(ne), ctypes.byref(nb))
    return rc, bytes(out)


def tch_fr_encode_into(buf24, payload):
    if payload:
        data = (ctypes.c_uint8 * len(payload))(*payload)
        _cod.gsm0503_tch_fr_encode(buf24, data, len(payload), 1)
    else:
        _cod.gsm0503_tch_fr_encode(buf24, None, 0, 1)


def sch_decode(burst):
    d78 = burst[3:42] + burst[106:145]
    buf = (sbit * 78)(*[-127 if b else 127 for b in d78])
    sb = (ctypes.c_uint8 * 4)()
    return _cod.gsm0503_sch_decode(sb, buf) == 0


def rach_burst(ra, bsic):
    coded = (ubit * 40)()
    _cod.gsm0503_rach_ext_encode(coded, ctypes.c_uint16(ra), ctypes.c_uint8(bsic), False)
    return bytes(8) + RACH_SYNC + bytes(coded)[:36] + bytes(148 - 8 - 41 - 36)


def a5_keystream(algo, kc, fn):
    key = (ctypes.c_uint8 * 8)(*kc)
    dl = (ubit * 114)()
    ul = (ubit * 114)()
    _gsm.osmo_a5(algo, key, ctypes.c_uint32(fn & 0xffffffff), dl, ul)
    return bytes(dl), bytes(ul)


def a5_xor(burst, ks):
    b = bytearray(burst)
    for i in range(57):
        b[3 + i] ^= ks[i]
        b[88 + i] ^= ks[57 + i]
    return bytes(b)


def gsmtap_header(arfcn, fn, chan, tn, uplink):
    a = arfcn | (0x4000 if uplink else 0)
    return struct.pack(">BBBBHbBIBBBB", 2, 4, 0x01, tn, a, 0, 0, fn, chan, 0, 0, 0)


def rr_message_type(l2):
    for off in (0, 3):
        if len(l2) > off + 1 and l2[off] == RR_PD:
            if off == 3 and (l2[2] >> 2) < 2:
                continue
            return off, l2[off + 1]
    return None, None


def tch_burst_index(fn):
    m = fn % 26
    return m if m < 12 else m - 1


def is_tch_carrier(fn):
    return fn % 26 not in (12, 25)


def next_tch_carrier(fn):
    n = (fn + 1) % HYPERFRAME
    while not is_tch_carrier(n):
        n = (n + 1) % HYPERFRAME
    return n


def sacch_tf_frame(tn):
    return 12 if tn % 2 == 0 else 25


def sacch_tf_block_base(tn):
    # 45.002 table 5 : le bloc SACCH/TF du TN commence a la trame 12 + 13*TN de la 104-multitrame
    return (12 + 13 * tn) % 104


def sacch_tf_block_start(fn, tn):
    return fn % 104 == sacch_tf_block_base(tn)


class SlotPlan:
    def __init__(self, name, sdcch_dl, sacch_dl, other_dl):
        self.name = name
        self.n_sub = len(sdcch_dl)
        self.sdcch_dl = tuple(sdcch_dl)
        self.sacch_dl = tuple(sacch_dl)
        half = len(sacch_dl)
        self.sacch_dl102 = tuple(sacch_dl[i % half] + (51 if i >= half else 0) for i in range(self.n_sub))
        self.ded_bases = tuple(sorted(set(self.sdcch_dl + self.sacch_dl)))
        self.block_bases = tuple(sorted(set(self.sdcch_dl + self.sacch_dl + tuple(other_dl))))

    def ul_base(self, ss):
        return (self.sdcch_dl[ss % self.n_sub] + 15) % 51


PLAN_SDCCH4 = SlotPlan("CCCH+SDCCH4", (22, 26, 32, 36), (42, 46), (2, 6, 12, 16))
PLAN_SDCCH8 = SlotPlan("SDCCH8", (0, 4, 8, 12, 16, 20, 24, 28), (32, 36, 40, 44), ())


def plan_for(phys):
    if phys.startswith("SDCCH8"):
        return PLAN_SDCCH8
    if phys.startswith("CCCH"):
        return PLAN_SDCCH4
    return None


def load_timeslots(path):
    ts = {}
    try:
        cur = None
        n_bts = 0
        for line in open(path, encoding="utf-8", errors="ignore"):
            s = line.strip()
            if s.startswith("bts "):
                n_bts += 1
                if n_bts > 1:
                    break
                cur = None
            elif s.startswith("timeslot "):
                cur = int(s.split()[1])
            elif s.startswith("phys_chan_config") and cur is not None:
                ts[cur] = s.split(None, 1)[1].strip()
                cur = None
    except OSError:
        pass
    return ts or {0: "CCCH+SDCCH4", 1: "SDCCH8", 2: "TCH/F", 3: "TCH/F"}
