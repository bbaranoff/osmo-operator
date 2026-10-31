# pont/tchh.py - one TCH/H subchannel as seen from the mobile (GSM-HR, FACCH/H).
#
# The bridge codes the whole uplink TCH (speech, FACCH, SACCH/T) on behalf of the
# emulated phone (pont/uplink.py TchScheduler). On a TCH/H the burst rhythm, the
# interleaving and the FACCH differ from TCH/F:
#   - a subchannel owns one traffic frame out of two (gsm.tchh_sub_bid), burst
#     ids 0,1 alternate; a new block is coded at every bid 0;
#   - speech is interleaved over 4 bursts, FACCH/H over 6: the coding buffer is
#     shifted by 2 bursts at each bid 0 and a FACCH/H steals two speech frames;
#   - FACCH/H may only start at fixed positions (gsm.TCHH_UL_FACCH_A).
# TchHEmetteur is trxcon's tx_tchh_fn (osmocom-bb src/host/trxcon/src/
# sched_lchan_tchh.c), TchHRecepteur its rx_tchh_fn for the downlink monitor.
# No thread, no clock: the callers give the fn, pont/tests_tchh.py drives both
# against the BTS side of osmo-bts (sched_lchan_tchh.c) offline.
import ctypes

from . import gsm

BPLEN = 116
NBURSTS = 24
# LAPDm fill frame of the mobile (trxcon l1sched_lchan_prim_dummy_lapdm): UI, SAPI 0.
LAPDM_FILL = bytes((0x01, 0x03, 0x01)) + bytes((0x2b,)) * (gsm.MACBLOCK_LEN - 3)


class TchHEmetteur:
    """Uplink of TCH/H(ss). burst(fn, ...) returns the 116 coded bits to send at fn, or None.

    signalling=True: channel mode "signalling only" (no speech): a FACCH/H, the LAPDm fill
    frame when nothing is pending, at every FACCH/H position; elsewhere what remains of the
    interleaving buffer. Otherwise speech mode: a 14-byte HR frame, else the dummy speech
    block (inverted CRC3, BFI at the BTS), a FACCH/H taking precedence at its positions."""

    def __init__(self, ss, signalling=False):
        self.ss = ss & 1
        self.signalling = signalling
        self.buf = (gsm.ubit * (NBURSTS * BPLEN))()
        self.reset()

    def reset(self):
        ctypes.memset(self.buf, 0, NBURSTS * BPLEN)
        self.mask = 0
        self.facch_blocks = 0
        self.facch_sent = 0
        self.speech_sent = 0
        self.dummy_sent = 0

    def _shift(self):
        ctypes.memmove(self.buf, ctypes.byref(self.buf, 2 * BPLEN), 20 * BPLEN)
        ctypes.memset(ctypes.byref(self.buf, 20 * BPLEN), 0, 2 * BPLEN)
        self.mask = (self.mask << 2) & 0xFFFFFFFF

    def burst(self, fn, pop_voice, pop_facch):
        """pop_voice() / pop_facch(): next pending frame or None (only called when consumed)."""
        sb = gsm.tchh_sub_bid(fn)
        if sb is None or sb[0] != self.ss:
            return None
        bid = sb[1]
        m = fn % 26
        if bid > 0:
            if not (self.mask & 0x01):
                return None
        else:
            if self.mask == 0 and self.signalling and m not in gsm.TCHH_UL_FACCH_A:
                return None             # align the first FACCH/H
            self._shift()
            if self.facch_blocks > 2:
                if not self.signalling:
                    pop_voice()         # the 2nd speech frame stolen by the FACCH/H
            elif self.signalling:
                if m in gsm.TCHH_UL_FACCH_A:
                    msg = pop_facch() or LAPDM_FILL
                    if gsm.tch_hr_encode_into(self.buf, msg) == 0:
                        self.facch_blocks = 6
                        self.facch_sent += 1
            else:
                voice = pop_voice()
                facch = pop_facch() if m in gsm.TCHH_UL_FACCH_A else None
                if facch is not None:
                    if gsm.tch_hr_encode_into(self.buf, facch) == 0:
                        self.facch_blocks = 6
                        self.facch_sent += 1
                elif voice is not None and len(voice) in (gsm.HR_BYTES, gsm.HR_BYTES + 1):
                    gsm.tch_hr_encode_into(self.buf, voice)
                    self.speech_sent += 1
                else:
                    gsm.tch_hr_encode_into(self.buf, None)
                    self.dummy_sent += 1
        out = bytes(self.buf)[bid * BPLEN:(bid + 1) * BPLEN]
        self.mask |= 1 << bid
        if self.facch_blocks:
            self.facch_blocks -= 1
        return out


def _decodeur_brut(items, odd):
    """Default decoder: items are 116-bit coded bursts, None for a missing one."""
    return gsm.tch_hr_decode([b if b is not None else bytes(BPLEN) for b in items], odd)


class TchHRecepteur:
    """Downlink of TCH/H(ss): feed(fn, item) returns (rc, data) when a frame is decoded
    (rc = MACBLOCK_LEN for a FACCH/H, HR_BYTES for speech, < 0 for a bad frame), else None.
    By default `item` is the 116 coded bits of the burst; with decoder(items, odd) the
    caller may store anything (pont/downlink.py keeps (fn, burst) to try the burst in
    clear then deciphered). Missing bursts are passed as None."""

    def __init__(self, ss):
        self.ss = ss & 1
        self.reset()

    def reset(self):
        self.hist = []              # [(fn, coded116)], at most 6, consecutive frames of ss
        self.last_fn = None
        self.ongoing_facch = False

    def feed(self, fn, coded, decoder=None):
        sb = gsm.tchh_sub_bid(fn)
        if sb is None or sb[0] != self.ss:
            return None
        bid = sb[1]
        if self.last_fn is not None and fn != gsm.next_tchh_frame(self.last_fn, self.ss):
            self.hist = []          # a frame was lost: the interleaving is broken
        self.last_fn = fn
        if not self.hist and bid > 0:
            return None             # align on a bid 0
        self.hist.append((fn, coded))
        if len(self.hist) > 6:
            del self.hist[0]
        if bid != 1 or len(self.hist) < 4:
            return None
        if self.ongoing_facch:
            self.ongoing_facch = False      # 2nd speech frame stolen by the FACCH/H
            return None
        odd = (fn % 26) not in gsm.TCHH_DL_FACCH_F
        if len(self.hist) < 6 and not odd:
            return None             # a FACCH/H needs its 6 bursts
        # Always the last 6 bursts, oldest first (osmo-bts / trxcon BUFTAIL8): speech is
        # read from the 4 oldest (bursts 'a'..'d'), a FACCH/H from all 6 ('a'..'f').
        items = [None] * (6 - len(self.hist)) + [b for _, b in self.hist]
        rc, data = (decoder or _decodeur_brut)(items, odd)
        if rc == gsm.MACBLOCK_LEN:
            self.ongoing_facch = True
            return rc, data[:gsm.MACBLOCK_LEN]
        if rc == gsm.HR_BYTES:
            return rc, data[:gsm.HR_BYTES]
        return rc, b""
