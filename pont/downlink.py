import logging
import os
import socket
import struct

from . import gsm
from .tchh import TchHRecepteur

_dcch_gen = [0]   # generation of calypso_dcch_cfg (IMM ASS), see CHANNEL RELEASE
# RA of the TI firmware's last RACHs (dsp/uplink.py, noter_rach) and time of the last IMM ASS
# retained: see _imm_ass_dcch.
_rach_ra = []
_imm_ass_retenue = [0.0]
IMM_ASS_GARDE_S = float(os.environ.get("PONT_IMM_ASS_GARDE", "2.0"))


def noter_rach(ra):
    """A RACH from the TI firmware: the mobile accepts the IMM ASS answering one of its last 3 (44.018 3.3.1.1.3)."""
    _rach_ra.append(ra)
    del _rach_ra[:-3]

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

    def l2(self, fn, chan, l2, tn=0, uplink=False, to_qemu=True):
        pkt = gsm.gsmtap_header(self.cfg.arfcn, fn, chan, tn, uplink) + bytes(l2)
        if not uplink and to_qemu:
            self.sock.sendto(pkt, (GSMTAP_HOST, self.cfg.gsmtap_port))
        if self.cfg.tap:
            self.sock.sendto(pkt, (GSMTAP_HOST, self.cfg.tap_port))

    def sch(self, fn):
        self.sock.sendto(b"SCH2" + struct.pack("<iii", self.cfg.bsic, fn, self.cfg.arfcn), (GSMTAP_HOST, self.cfg.sch_port))


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
        self._deciphered = {}
        self.rx_h = None        # TchHRecepteur of the current TCH/H, see _tch_h
        tch.on_close.append(self._tch_reset)

    def _tch_reset(self):
        self.tch_acc = []
        self.tch_last_fn = None
        self.sacch_acc = {}
        self._deciphered = {}
        self.rx_h = None

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
        acc = self.blocks.setdefault((tn, fn0), [])
        acc.append((fn, burst))
        self.stats.dl_bursts += 1
        if len(acc) < 4:
            return
        del self.blocks[(tn, fn0)]
        l2 = self._decode(acc, base in plan.ded_bases)
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
            if mt == gsm.RR_IMMEDIATE_ASSIGNMENT:
                self._imm_ass_dcch(l2, fn0)
        if mt in gsm.SI_TYPES:
            self.feed.l2(fn0, gsm.GSMTAP_BCCH, l2, tn)
        elif mt in gsm.CCCH_TYPES:
            # EMPTY PAGINGS DO NOT GO TO THE QEMU L1. The L1
            # (calypso_l1_grgsm.c, feed_agch) keeps ONLY ONE CCCH block - the
            # last received, valid for 100 frames. osmo-bts fills every free
            # PCH block with a PAGING REQUEST 1 without identity: a real paging
            # (the mobile's TMSI) would be overwritten ~50 ms later, and the
            # firmware would only see it if its read of its paging group fell
            # within the window. The Wireshark tap keeps everything.
            self.feed.l2(fn0, gsm.GSMTAP_CCCH, l2, tn,
                         to_qemu=not gsm.is_empty_paging(l2))

    def _clear(self, bursts):
        return [gsm.coded_from_burst(b) for _, b in bursts]

    def _ciphered(self, bursts):
        if len(self._deciphered) > 64:
            self._deciphered.clear()
        out = []
        for fn, b in bursts:
            d = self._deciphered.get(fn)
            if d is None:
                d = self._deciphered[fn] = gsm.coded_from_burst(self.cipher.apply(b, fn, False))
            out.append(d)
        return out

    def _decode(self, bursts, dedicated):
        # As in a real network: clear, then ciphered. The BTS enables downlink
        # ciphering only after the first ciphered uplink frame, so SI5/SI6 and
        # the first SDCCH frames arrive in clear even when the Kc is already
        # known. Decode in clear as long as it works, and lock the global
        # "downlink ciphered" state as soon as a block decodes only once
        # deciphered. All channels follow that state.
        if not dedicated or self.cipher.current() is None:
            return gsm.xcch_decode(self._clear(bursts))
        if not self.cipher.dl_active:
            l2 = gsm.xcch_decode(self._clear(bursts))
            if l2 is not None:
                return l2
        l2 = gsm.xcch_decode(self._ciphered(bursts))
        if l2 is not None:
            self.cipher.confirm_dl(bursts[0][0])
        return l2

    def _decode_tch(self, bursts):
        # Same rule for the TCH: speech follows the global state, a valid
        # FACCH (Fire CRC) serves as proof to switch the state.
        if self.cipher.current() is None:
            return gsm.tch_fr_decode(self._clear(bursts))
        if self.cipher.dl_active:
            return gsm.tch_fr_decode(self._ciphered(bursts))
        rc, fr = gsm.tch_fr_decode(self._clear(bursts))
        if rc == gsm.MACBLOCK_LEN:
            return rc, fr
        rc2, fr2 = gsm.tch_fr_decode(self._ciphered(bursts))
        if rc2 == gsm.MACBLOCK_LEN:
            self.cipher.confirm_dl(bursts[0][0])
            return rc2, fr2
        return rc, fr

    def _imm_ass_dcch(self, l2, fn):
        """TI firmware (Magnetite): no QEMU tap to tell the bench which dedicated channel the mobile
        goes to. The IMMEDIATE ASSIGNMENT (44.018 9.1.18) says it: octet 1 pseudo-length, 2 PD, 3 type,
        4 page mode, 5 chan_nr. SDCCH/4 = 0b00100SST, SDCCH/8 = 0b01SSSTTT.
        CALYPSO_PONT_IMM_DCCH=0 to disable; only with MS_MAGNETITE (the osmocom firmware has its tap).
        The mobile takes the FIRST one answering one of its RACHs and ignores the following ones. So the
        first one whose reference (octet 7, RA) is a RACH of the mobile is kept, then the others are
        ignored for PONT_IMM_ASS_GARDE s (the bridge reads the downlink ~30 frames before the mobile,
        which may still emit a RACH). Without a known RA (decoding failed), the last received wins."""
        if not os.environ.get("MS_MAGNETITE") or os.environ.get("CALYPSO_PONT_IMM_DCCH", "1") == "0":
            return
        if len(l2) < 5 or l2[1] != gsm.RR_PD:
            return
        cn = l2[4]
        if (cn >> 5) == 0b001:                             # SDCCH/4 + SACCH: 0b001SSTTT, subchannel 0..3
            kind, ss = 0, (cn >> 3) & 3
        elif (cn >> 6) == 0b01:                            # SDCCH/8 + SACCH, subchannel 0..7
            kind, ss = 1, (cn >> 3) & 7
        else:
            return
        if _rach_ra and len(l2) > 7:
            import time
            ra = l2[7]
            if ra not in _rach_ra or time.monotonic() - _imm_ass_retenue[0] < IMM_ASS_GARDE_S:
                log.info("IMMEDIATE ASSIGNMENT (fn=%u) : SDCCH TS%d SS%d pour RA 0x%02x, ignoree (RACH du mobile : %s)",
                         fn, cn & 7, ss, ra, " ".join("0x%02x" % r for r in _rach_ra) or "-")
                return
            _imm_ass_retenue[0] = time.monotonic()
            _rach_ra.clear()
        from .state import ecrire_dcch
        _dcch_gen[0] += 1                                  # cancels a pending deferred release
        ecrire_dcch(kind, ss, cn)
        log.info("IMMEDIATE ASSIGNMENT (fn=%u) : SDCCH/%d TS%d SS%d -> calypso_dcch_cfg (firmware TI)",
                 fn, 8 if kind else 4, cn & 7, ss)

    def _rr_downlink(self, l2, fn):
        off, mt = gsm.rr_message_type(l2)
        if mt == gsm.RR_ASSIGNMENT_COMMAND and len(l2) > off + 4:
            b0, b1, b2 = l2[off + 2], l2[off + 3], l2[off + 4]
            if (b1 >> 4) & 1:
                log.warning("ASSIGNMENT COMMAND avec saut de frequence : TCH non arme (fn=%u)", fn)
                return
            ct = gsm.chan_nr_tch(b0)
            half, ss = (ct[0], ct[1]) if ct else (False, 0)
            self.tch.arm(b0 & 0x07, (b1 >> 5) & 0x07, ((b1 & 0x03) << 8) | b2,
                         half, ss, gsm.assignment_chan_mode(l2, off))
        elif mt == gsm.RR_CHANNEL_RELEASE:
            self.tch.release_requested("CHANNEL RELEASE")
            self._liberer_dcch_ti(fn, "CHANNEL RELEASE")

    def _liberer_dcch_ti(self, fn, quoi):
        """TI firmware (Magnetite): no QEMU tap to say the mobile left the dedicated channel; the bridge
        itself releases calypso_dcch_cfg (and the TCH) after the CHANNEL RELEASE."""
        if not os.environ.get("MS_MAGNETITE") or os.environ.get("CALYPSO_PONT_IMM_DCCH", "1") == "0":
            return
        # DEFERRED. The bridge reads the downlink ~30 frames BEFORE the mobile (DL margin
        # +28..+35): releasing immediately would cut the SDCCH at the BSP before the mobile has
        # received this CHANNEL RELEASE, leaving it on a dead channel until link loss (~13 s),
        # deaf to paging meanwhile.
        # PONT_DCCH_REL_DELAI (s, default 1.5); an IMM ASS in the meantime cancels the release.
        # Also called from the FACCH: the CHANNEL RELEASE of a call arrives on the TCH.
        import threading
        from .state import ecrire_dcch, DCCH_RELEASED
        gen = _dcch_gen[0]
        delai = float(os.environ.get("PONT_DCCH_REL_DELAI", "1.5"))
        def _liberer():
            if _dcch_gen[0] == gen:
                self.tch.close("%s, liberation differee (firmware TI)" % quoi)
                ecrire_dcch(DCCH_RELEASED, 0, 0)
                log.info("%s (fn=%u) : calypso_dcch_cfg libere apres %.1f s (firmware TI)", quoi, fn, delai)
        t = threading.Timer(delai, _liberer)
        t.daemon = True
        t.start()

    def _tch(self, tn, fn, burst):
        if gsm.is_dummy(burst):
            self.stats.dl_dummy += 1
            return
        if self.tch.half:
            self._tch_h(tn, fn, burst)
            return
        if fn % 26 == gsm.sacch_tf_frame(tn):
            self._tch_sacch(tn, fn, burst)
            return
        if not gsm.is_tch_carrier(fn):
            return
        if self.tch_last_fn is not None and fn != gsm.next_tch_carrier(self.tch_last_fn):
            self.tch_acc = []
        self.tch_last_fn = fn
        self.tch_acc.append((fn, burst))
        if len(self.tch_acc) > 8:
            del self.tch_acc[0]
        if len(self.tch_acc) < 8 or gsm.tch_burst_index(fn) % 4 != 3:
            return
        rc, fr = self._decode_tch(self.tch_acc)
        if rc == gsm.FR_BYTES:
            self.stats.tch_dl += 1
            self.ring.publish(fr, fn)
            # REFERENCE FOR THE DSP SPEECH. Each FR frame the bridge decodes
            # itself from the BTS bursts, with its BTS fn: tools/comparer_parole.py
            # compares it with what the ROM delivers in a_dd
            # (/dev/shm/calypso_add_dl.bin, montant.c) to count the wrong bits
            # per class. At most 4000 frames per session.
            self._noter_parole(fn, fr)
        elif rc == gsm.MACBLOCK_LEN:
            self.stats.tch_facch_dl += 1
            l2 = fr[:gsm.MACBLOCK_LEN]
            self.feed.l2(fn, gsm.GSMTAP_TCH_F, l2, tn)
            if gsm.rr_message_type(l2)[1] == gsm.RR_CHANNEL_RELEASE:
                self.tch.release_requested("CHANNEL RELEASE (FACCH)")
                self._liberer_dcch_ti(fn, "CHANNEL RELEASE (FACCH)")
        else:
            self.stats.tch_crc += 1

    def _decode_tch_h(self, items, odd):
        """Decoder for TchHRecepteur: items are (fn, burst) or None. Same ciphering rule as
        _decode_tch: global state first, a valid FACCH/H proves the downlink is ciphered."""
        def coder(chiffre):
            out = []
            for it in items:
                if it is None:
                    out.append(bytes(116))
                elif chiffre:
                    out.append(self._ciphered([it])[0])
                else:
                    out.append(gsm.coded_from_burst(it[1]))
            return out
        if self.cipher.current() is None:
            return gsm.tch_hr_decode(coder(False), odd)
        if self.cipher.dl_active:
            return gsm.tch_hr_decode(coder(True), odd)
        rc, data = gsm.tch_hr_decode(coder(False), odd)
        if rc == gsm.MACBLOCK_LEN:
            return rc, data
        rc2, data2 = gsm.tch_hr_decode(coder(True), odd)
        if rc2 == gsm.MACBLOCK_LEN:
            first = next(it for it in items if it is not None)
            self.cipher.confirm_dl(first[0])
            return rc2, data2
        return rc, data

    def _tch_h(self, tn, fn, burst):
        """TCH/H(ss) downlink monitor: SACCH/TH of our subchannel, FACCH/H (CHANNEL RELEASE)
        and GSM-HR speech counters. The speech itself is decoded by the DSP ROM."""
        ss = self.tch.ss
        if fn % 26 in (12, 25):
            if fn % 26 == gsm.sacch_t_frame(tn, ss):
                self._tch_sacch(tn, fn, burst)
            return
        if self.rx_h is None or self.rx_h.ss != ss:
            self.rx_h = TchHRecepteur(ss)
        res = self.rx_h.feed(fn, (fn, burst), self._decode_tch_h)
        if res is None:
            return
        rc, data = res
        if rc == gsm.HR_BYTES:
            self.stats.tch_dl += 1
        elif rc == gsm.MACBLOCK_LEN:
            self.stats.tch_facch_dl += 1
            self.feed.l2(fn, gsm.GSMTAP_TCH_H, data, tn)
            if gsm.rr_message_type(data)[1] == gsm.RR_CHANNEL_RELEASE:
                self.tch.release_requested("CHANNEL RELEASE (FACCH/H)")
                self._liberer_dcch_ti(fn, "CHANNEL RELEASE (FACCH/H)")
        else:
            self.stats.tch_crc += 1

    def _noter_parole(self, fn, fr):
        n = getattr(self, "_parole_n", 0)
        if n >= 4000:
            return
        try:
            mode = "ab" if n else "wb"
            with open("/dev/shm/pont_tch_dl.bin", mode) as f:
                f.write(struct.pack("<I", fn & 0xffffffff) + bytes(fr[:gsm.FR_BYTES]))
        except OSError:
            return
        self._parole_n = n + 1

    def _tch_sacch(self, tn, fn, burst):
        start = gsm.sacch_t_block_base(tn, self.tch.ss if self.tch.half else None)
        block = fn - ((fn % 104 - start) % 104)
        acc = self.sacch_acc.setdefault(block, [])
        acc.append((fn, burst))
        if len(self.sacch_acc) > 4:
            for k in sorted(self.sacch_acc)[:-2]:
                del self.sacch_acc[k]
        if len(acc) < 4:
            return
        del self.sacch_acc[block]
        l2 = self._decode(acc, True)
        if l2 is None:
            self.stats.tch_crc += 1
            return
        self.stats.tch_sacch_dl += 1
        self.feed.l2(block, gsm.GSMTAP_TCH_ACCH, l2, tn)
