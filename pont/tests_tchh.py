# pont/tests_tchh.py - offline check of pont/tchh.py against the BTS side of osmo-bts.
#
#   cd osmo-operator && python3 -m pont.tests_tchh
#
# Uplink : TchHEmetteur (mobile) -> transcription of osmo-bts rx_tchh_fn
#          (src/osmo-bts-trx/sched_lchan_tchh.c): 2-burst shift at bid 0, decoding at
#          bid 1 over the last 6 bursts, odd = burst 'f' not at a FACCH/H position,
#          the 2 bursts after a FACCH/H skipped.
# Downlink: transcription of osmo-bts tx_tchh_fn (FACCH/H only at its 'a' positions,
#          dummy speech otherwise) -> TchHRecepteur.
# Both subchannels, a few thousand frames, FACCH/H and GSM-HR frames compared one by one.
import ctypes
import os
import random
import sys

from . import gsm
from .tchh import BPLEN, NBURSTS, TchHEmetteur, TchHRecepteur

TCHH_UL_FACCH_F = frozenset((10, 11, 19, 20, 2, 3))     # osmo-bts sched_tchh_ul_facch_map


class BtsMontant:
    """osmo-bts rx_tchh_fn for one subchannel (hard bits in, no measurements)."""

    def __init__(self, ss):
        self.ss = ss
        self.buf = [bytes(BPLEN)] * NBURSTS
        self.mask = 0
        self.ongoing = False
        self.facch, self.parole, self.bfi = [], [], 0

    def burst(self, fn, coded):
        sb = gsm.tchh_sub_bid(fn)
        if sb is None or sb[0] != self.ss:
            return
        bid = sb[1]
        if bid == 0:
            self.buf = self.buf[2:22] + [bytes(BPLEN)] * 2 + self.buf[22:]
            self.mask = (self.mask << 2) & 0xFFFFFFFF
        self.mask |= 1 << bid
        self.buf[20 + bid] = coded
        if bid != 1 or (self.mask & 0x3f) != 0x3f:
            return
        if self.ongoing:
            self.ongoing = False
            return
        rc, data = gsm.tch_hr_decode(self.buf[16:22], (fn % 26) not in TCHH_UL_FACCH_F)
        if rc == gsm.MACBLOCK_LEN:
            self.ongoing = True
            self.facch.append(data[:gsm.MACBLOCK_LEN])
        elif rc == gsm.HR_BYTES:
            self.parole.append(data[:gsm.HR_BYTES])
        else:
            self.bfi += 1


class BtsDescendant:
    """osmo-bts tx_tchh_fn for one subchannel, speech mode."""

    def __init__(self, ss):
        self.ss = ss
        self.buf = (gsm.ubit * (NBURSTS * BPLEN))()
        self.mask = 0
        self.ongoing = False

    def burst(self, fn, pop_parole, pop_facch):
        sb = gsm.tchh_sub_bid(fn)
        if sb is None or sb[0] != self.ss:
            return None
        bid = sb[1]
        if bid > 0:
            if not (self.mask & 0x01):
                return None
        else:
            self.mask = (self.mask << 2) & 0xFF
            ctypes.memmove(self.buf, ctypes.byref(self.buf, 2 * BPLEN), 20 * BPLEN)
            ctypes.memset(ctypes.byref(self.buf, 20 * BPLEN), 0, 2 * BPLEN)
            parole = pop_parole()
            facch = pop_facch() if (fn % 26) in gsm.TCHH_DL_FACCH_A else None
            if self.ongoing:
                self.ongoing = False        # 2nd speech frame dropped
            else:
                msg = facch if facch is not None else parole
                if facch is not None:
                    self.ongoing = True
                gsm.tch_hr_encode_into(self.buf, msg)
        self.mask |= 1 << bid
        return bytes(self.buf)[bid * BPLEN:(bid + 1) * BPLEN]


def _l2(octets):
    return bytes(octets) + bytes((0x2b,)) * (gsm.MACBLOCK_LEN - len(octets))


SABM = _l2((0x01, 0x3f, 0x01))
ASS_COMPLETE = _l2((0x03, 0x00, 0x09, 0x06, 0x29, 0x00))


def _hr_aleatoire(rng):
    return bytes(rng.randrange(256) for _ in range(gsm.HR_BYTES))


def montant(ss, fn0, nfn, rng):
    ms, bts = TchHEmetteur(ss), BtsMontant(ss)
    facch_q = [SABM, ASS_COMPLETE]
    parole_q = [_hr_aleatoire(rng) for _ in range(400)]
    envoyees = []

    def pop_parole():
        if not parole_q:
            return None
        f = parole_q.pop(0)
        envoyees.append(f)
        return f

    def pop_facch():
        return facch_q.pop(0) if facch_q else None

    for k in range(nfn):
        fn = (fn0 + k) % gsm.HYPERFRAME
        coded = ms.burst(fn, pop_parole, pop_facch)
        if coded is not None:
            bts.burst(fn, coded)
    return ms, bts, envoyees


def descendant(ss, fn0, nfn, rng):
    bts, ms = BtsDescendant(ss), TchHRecepteur(ss)
    facch_q = [SABM, ASS_COMPLETE]
    parole_q = [_hr_aleatoire(rng) for _ in range(400)]
    envoyees, facch_rx, parole_rx, bfi = [], [], [], 0

    def pop_parole():
        if not parole_q:
            return None
        f = parole_q.pop(0)
        envoyees.append(f)
        return f

    def pop_facch():
        return facch_q.pop(0) if facch_q else None

    for k in range(nfn):
        fn = (fn0 + k) % gsm.HYPERFRAME
        coded = bts.burst(fn, pop_parole, pop_facch)
        if coded is None:
            continue
        r = ms.feed(fn, coded)
        if r is None:
            continue
        if r[0] == gsm.MACBLOCK_LEN:
            facch_rx.append(r[1])
        elif r[0] == gsm.HR_BYTES:
            parole_rx.append(r[1])
        else:
            bfi += 1
    return envoyees, facch_rx, parole_rx, bfi


def _sous_suite(petite, grande):
    """True if `petite` appears in `grande` in order (frames stolen by a FACCH may be missing)."""
    it = iter(grande)
    return all(any(x == y for y in it) for x in petite)


def main():
    rng = random.Random(int(os.environ.get("TCHH_SEED", "1")))
    ok = True
    for ss in (0, 1):
        for fn0 in (0, 7, 13, 25, 1000003):
            ms, bts, env = montant(ss, fn0, 3000, rng)
            f_ok = bts.facch == [SABM, ASS_COMPLETE]
            p_ok = len(bts.parole) >= len(env) - 6 and _sous_suite(bts.parole, env) and bts.parole[:3] != []
            ok &= f_ok and p_ok
            print("UL TCH/H(%d) fn0=%-8d FACCH %s (%d/2)  parole %d decodees / %d emises, ordre %s, BFI %d"
                  % (ss, fn0, "OK" if f_ok else "KO", len(bts.facch), len(bts.parole), len(env),
                     "OK" if p_ok else "KO", bts.bfi))
            env, frx, prx, bfi = descendant(ss, fn0, 3000, rng)
            f_ok = frx == [SABM, ASS_COMPLETE]
            p_ok = len(prx) >= len(env) - 8 and _sous_suite(prx, env)
            ok &= f_ok and p_ok
            print("DL TCH/H(%d) fn0=%-8d FACCH %s (%d/2)  parole %d decodees / %d emises, ordre %s, BFI %d"
                  % (ss, fn0, "OK" if f_ok else "KO", len(frx), len(prx), len(env),
                     "OK" if p_ok else "KO", bfi))
    # SACCH/TH: block bases against osmo-bts frame_tchh_ts01..67
    attendu = {(0, 0): 12, (0, 1): 25, (2, 0): 38, (2, 1): 51, (4, 0): 64, (4, 1): 77, (6, 0): 90, (6, 1): 103}
    s_ok = all(gsm.sacch_t_block_base(tn, ss) == v and gsm.sacch_t_block_base(tn + 1, ss) == v
               for (tn, ss), v in attendu.items())
    ok &= s_ok
    print("SACCH/TH bases (osmo-bts frame_tchh_ts01..67) :", "OK" if s_ok else "KO")
    print("RESULTAT :", "OK" if ok else "ECHEC")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
