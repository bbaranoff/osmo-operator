import logging
import os
import socket
import struct

from . import gsm

log = logging.getLogger("pont")

TCH_DL_PATH = "/dev/shm/calypso_tch_dl"
TCH_DL_SLOTS = 16
TCH_DL_SLOT = 48
GSMTAP_HOST = "127.0.0.1"


class Feeder:
    def __init__(self, cfg, stats):
        self.cfg = cfg
        self.stats = stats
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def l2(self, fn, chan, l2, tn=0, uplink=False):
        pkt = gsm.gsmtap_header(self.cfg.arfcn, fn, chan, tn, uplink) + bytes(l2)
        if not uplink:
            self.sock.sendto(pkt, (GSMTAP_HOST, self.cfg.gsmtap_port))
        if self.cfg.tap:
            self.sock.sendto(pkt, (GSMTAP_HOST, self.cfg.tap_port))

    def sch(self, fn):
        self.sock.sendto(b"SCH1" + struct.pack("<iii", self.cfg.bsic, fn, 0), (GSMTAP_HOST, self.cfg.sch_port))


class TchRing:
    def __init__(self):
        self.fd = None
        self.w = 0

    def publish(self, fr33, fn):
        if self.fd is None:
            self.fd = os.open(TCH_DL_PATH, os.O_CREAT | os.O_RDWR, 0o644)
            os.ftruncate(self.fd, 8 + TCH_DL_SLOTS * TCH_DL_SLOT)
            os.pwrite(self.fd, (0).to_bytes(4, "little") + TCH_DL_SLOTS.to_bytes(4, "little"), 0)
            self.w = 0
        self.w += 1
        rec = self.w.to_bytes(4, "little") + (fn & 0xffffffff).to_bytes(4, "little") + bytes(fr33)[:gsm.FR_BYTES]
        rec += bytes(TCH_DL_SLOT - len(rec))
        os.pwrite(self.fd, rec, 8 + ((self.w - 1) % TCH_DL_SLOTS) * TCH_DL_SLOT)
        os.pwrite(self.fd, self.w.to_bytes(4, "little"), 0)


class Downlink:
    def __init__(self, cfg, stats, cipher, dedicated, tch, feeder, record, timeslots):
        self.cfg = cfg
        self.stats = stats
        self.cipher = cipher
        self.dedicated = dedicated
        self.tch = tch
        self.feed = feeder
        self.record = record
        self.timeslots = timeslots
        self.blocks = {}
        self.ring = TchRing()
        self.tch_acc = []
        self.tch_last_fn = None
        self.sacch_acc = {}
        tch.on_close.append(self._tch_reset)

    def _tch_reset(self):
        self.tch_acc = []
        self.tch_last_fn = None
        self.sacch_acc = {}

    def dispatch(self, tn, fn, burst):
        if self.record:
            self.record.feed_dl(fn, tn, burst)
        if tn == 0 and fn % 51 in gsm.SCH_SLOTS_51:
            if gsm.sch_decode(burst):
                self.feed.sch(fn)
            return
        if tn == self.tch.active_tn():
            self._tch(tn, fn, burst)
            return
        phys = self.timeslots.get(tn, "")
        plan = gsm.plan_for(phys)
        if plan is not None:
            self._signalling(tn, fn, burst, plan)

    def _active_subchannel(self, tn, plan):
        ded = self.dedicated.plan()
        if ded is None:
            return None, False
        dplan, ss, dtn = ded
        if dtn != tn:
            return None, True
        if dplan is not plan:
            return None, False
        return ss % plan.n_sub, False

    def _signalling(self, tn, fn, burst, plan):
        m51 = fn % 51
        base = next((b for b in plan.block_bases if b <= m51 <= b + 3), None)
        if base is None:
            return
        fn0 = fn - (m51 - base)
        ss, elsewhere = self._active_subchannel(tn, plan)
        if elsewhere and base in plan.ded_bases:
            self.stats.dl_skipped += 1
            return
        if ss is not None:
            if base in plan.sdcch_dl and base != plan.sdcch_dl[ss]:
                return
            if base in plan.sacch_dl and (fn0 % 102) != plan.sacch_dl102[ss]:
                return
        if len(self.blocks) > 64:
            self.blocks.clear()
        if gsm.is_dummy(burst):
            self.stats.dl_dummy += 1
            return
        if base in plan.ded_bases:
            burst = self.cipher.apply(burst, fn, False)
        acc = self.blocks.setdefault((tn, fn0), [])
        acc.append(gsm.coded_from_burst(burst))
        self.stats.dl_bursts += 1
        if len(acc) < 4:
            return
        del self.blocks[(tn, fn0)]
        l2 = gsm.xcch_decode(acc)
        self.stats.block(tn, base, l2 is not None)
        if l2 is None:
            self.stats.dl_crc_fail += 1
            return
        self.stats.dl_blocks += 1
        if base in plan.sdcch_dl:
            self.feed.l2(fn0, gsm.GSMTAP_SDCCH4, l2, tn)
            self._rr_downlink(l2, fn0)
            return
        if base in plan.sacch_dl:
            self.feed.l2(fn0, gsm.GSMTAP_SACCH, l2, tn)
            return
        mt = None
        if len(l2) >= 3 and l2[1] == gsm.RR_PD:
            mt = l2[2]
        elif len(l2) >= 5 and l2[3] == gsm.RR_PD:
            mt = l2[4]
        if mt in (gsm.RR_IMMEDIATE_ASSIGNMENT, gsm.RR_IMMEDIATE_ASSIGNMENT_EXT):
            self.cipher.release("IMMEDIATE ASSIGNMENT")
        if mt in gsm.SI_TYPES:
            self.feed.l2(fn0, gsm.GSMTAP_BCCH, l2, tn)
        elif mt in gsm.CCCH_TYPES:
            self.feed.l2(fn0, gsm.GSMTAP_CCCH, l2, tn)

    def _rr_downlink(self, l2, fn):
        off, mt = gsm.rr_message_type(l2)
        if mt == gsm.RR_ASSIGNMENT_COMMAND and len(l2) > off + 4:
            b0, b1, b2 = l2[off + 2], l2[off + 3], l2[off + 4]
            if (b1 >> 4) & 1:
                log.warning("ASSIGNMENT COMMAND avec saut de frequence : TCH non arme (fn=%u)", fn)
                return
            self.tch.arm(b0 & 0x07, (b1 >> 5) & 0x07, ((b1 & 0x03) << 8) | b2)
        elif mt == gsm.RR_CHANNEL_RELEASE:
            self.tch.close("CHANNEL RELEASE")
            self.cipher.release("CHANNEL RELEASE")

    def _tch(self, tn, fn, burst):
        if gsm.is_dummy(burst):
            self.stats.dl_dummy += 1
            return
        if fn % 26 == gsm.sacch_tf_frame(tn):
            self._tch_sacch(tn, fn, self.cipher.apply(burst, fn, False))
            return
        if not gsm.is_tch_carrier(fn):
            return
        burst = self.cipher.apply(burst, fn, False)
        if self.tch_last_fn is not None and fn != gsm.next_tch_carrier(self.tch_last_fn):
            self.tch_acc = []
        self.tch_last_fn = fn
        self.tch_acc.append(gsm.coded_from_burst(burst))
        if len(self.tch_acc) > 8:
            del self.tch_acc[0]
        if len(self.tch_acc) < 8 or gsm.tch_burst_index(fn) % 4 != 3:
            return
        rc, fr = gsm.tch_fr_decode(self.tch_acc)
        if rc == gsm.FR_BYTES:
            self.stats.tch_dl += 1
            self.ring.publish(fr, fn)
        elif rc == gsm.MACBLOCK_LEN:
            self.stats.tch_facch_dl += 1
            l2 = fr[:gsm.MACBLOCK_LEN]
            self.feed.l2(fn, gsm.GSMTAP_TCH_F, l2, tn)
            if gsm.rr_message_type(l2)[1] == gsm.RR_CHANNEL_RELEASE:
                self.tch.close("CHANNEL RELEASE (FACCH)")
                self.cipher.release("CHANNEL RELEASE (FACCH)")
        else:
            self.stats.tch_crc += 1

    def _tch_sacch(self, tn, fn, burst):
        start = gsm.sacch_tf_frame(tn)
        block = fn - ((fn % 104 - start) % 104)
        acc = self.sacch_acc.setdefault(block, [])
        acc.append(gsm.coded_from_burst(burst))
        if len(self.sacch_acc) > 4:
            for k in sorted(self.sacch_acc)[:-2]:
                del self.sacch_acc[k]
        if len(acc) < 4:
            return
        del self.sacch_acc[block]
        l2 = gsm.xcch_decode(acc)
        if l2 is None:
            self.stats.tch_crc += 1
            return
        self.stats.tch_sacch_dl += 1
        self.feed.l2(block, gsm.GSMTAP_TCH_ACCH, l2, tn)
