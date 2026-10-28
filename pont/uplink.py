import collections
import ctypes
import logging
import os
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

SB_RACH = "/dev/shm/calypso_rach"
SB_SDCCH_UL = "/dev/shm/calypso_sdcch_ul"
SB_FACCH_UL = "/dev/shm/calypso_tch_facch_ul"
SB_SACCH_UL = "/dev/shm/calypso_tch_sacch_ul"
SB_TCH_UL = "/dev/shm/calypso_tch_ul"
TCH_UL_SLOT = 64
TCH_UL_FR_OFS = 16
POLL = gsm.FRAME_DUR / 8
TX_BURSTS = 24
BPLEN = 116
RELEASE_FALLBACK = 20.0
# How long to keep an uplink SDCCH block while waiting to know the dedicated
# channel (see _poll_sdcch).
SDCCH_ATTENTE = 1.0


class Sideband:
    def __init__(self, path, size):
        self.path = path
        self.size = size
        self.fd = None
        self.seq = 0

    def read(self):
        try:
            if self.fd is None:
                self.fd = os.open(self.path, os.O_RDONLY)
            return os.pread(self.fd, self.size, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return b""

    def new_record(self):
        b = self.read()
        if len(b) < self.size:
            return None
        seq = struct.unpack_from("<I", b, 0)[0]
        if not seq or seq == self.seq:
            return None
        self.seq = seq
        return b

    def skip_pending(self):
        b = self.read()
        if len(b) >= 4:
            self.seq = struct.unpack_from("<I", b, 0)[0]


class TchUplinkRing:
    def __init__(self):
        self.fd = None
        self.last = 0

    def drain(self):
        try:
            if self.fd is None:
                self.fd = os.open(SB_TCH_UL, os.O_RDONLY)
            hdr = os.pread(self.fd, 8, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return [], 0
        if len(hdr) < 8:
            return [], 0
        w, n = struct.unpack("<II", hdr)
        if not w or not n:
            return [], 0
        lost = 0
        if self.last == 0:
            self.last = w
        elif (w - self.last) > n:
            lost = (w - self.last) - n
            self.last = w - n
        frames = []
        while self.last < w:
            self.last += 1
            sl = os.pread(self.fd, TCH_UL_SLOT, 8 + ((self.last - 1) % n) * TCH_UL_SLOT)
            if len(sl) >= TCH_UL_FR_OFS + gsm.FR_BYTES:
                frames.append(sl[TCH_UL_FR_OFS:TCH_UL_FR_OFS + gsm.FR_BYTES])
        return frames, lost


class Uplink(threading.Thread):
    def __init__(self, cfg, clock, stats, dedicated, tch, transmitter, feeder, cipher):
        super().__init__(name="uplink", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.dedicated = dedicated
        self.tch = tch
        self.cipher = cipher
        self.ded_active = False
        self.tx = transmitter
        self.feed = feeder
        self.sb_rach = Sideband(SB_RACH, 12)
        self.sb_sdcch = Sideband(SB_SDCCH_UL, 39)
        self.sb_facch = Sideband(SB_FACCH_UL, 39)
        self.sb_sacch = Sideband(SB_SACCH_UL, 39)
        self.ring = TchUplinkRing()
        self.q_lock = threading.Lock()
        self.q_facch = collections.deque(maxlen=8)
        self.q_voice = collections.deque(maxlen=4)
        self.sacch_l2 = None
        self.tch_epoch = -1
        self.sdcch_attente = None
        for sb in (self.sb_rach, self.sb_sdcch, self.sb_facch, self.sb_sacch):
            sb.skip_pending()

    def _next_fn(self, min_advance, accept):
        start = self.clock.fn() + min_advance
        for k in range(104):
            fn = (start + k) % gsm.HYPERFRAME
            if accept(fn):
                return fn
        return start % gsm.HYPERFRAME

    def _queue_facch(self, l2, ouverture=False):
        # A SAPI 0 UI ON THE TCH IS A BLOCK THAT IS NOT A FACCH.
        # A block whose first octet has the EA bit at 0 is not a LAPDm address:
        # lapdm.c:995 takes the frame for a short header (Bter) and passes it
        # up AS IS as UNIT DATA IND ("SAPI=0 UNIT DATA INDICATION:
        # unimplemented" at the BSC). That is the shape of an uplink SACCH
        # block: L1 header first (power, TA) -- 08 00 01 03 49 ... at power 8.
        # A FACCH is always format B and SAPI 0: address 0x01 or 0x03.
        # Any other block is discarded here, octets logged to find its source.
        # PONT_FACCH_TOUT=1 restores unfiltered sending.
        if l2[0] not in (0x01, 0x03) and os.environ.get("PONT_FACCH_TOUT", "0") != "1":
            log.info("FACCH montante ECARTEE (pas une adresse SAPI 0) : %s",
                     bytes(l2[:gsm.MACBLOCK_LEN]).hex(" "))
            return
        # Non-I frames (SABM, RR, REJ, DISC...) are rare: they are logged, as
        # is the first FACCH of each TCH.
        if (l2[1] & 0x01) or ouverture:
            log.info("FACCH montante %s : %s", "non-I" if l2[1] & 0x01 else "I (ouverture)",
                     bytes(l2[:gsm.MACBLOCK_LEN]).hex(" "))
        with self.q_lock:
            self.q_facch.append(bytes(l2[:gsm.MACBLOCK_LEN]))
        self.stats.facch_ul += 1
        self.feed.l2(self.clock.fn(), gsm.GSMTAP_TCH_F, l2[:gsm.MACBLOCK_LEN], self.tch.active_tn() or 0, True)

    def _poll_rach(self):
        b = self.sb_rach.new_record()
        if b is None:
            return
        _, ra, bsic, fn = struct.unpack_from("<IBBxxI", b, 0)
        burst = gsm.rach_burst(ra, bsic)
        self.tx.schedule(0, self._next_fn(4, lambda f: f % 51 in gsm.RACH_SLOTS_51), burst, False)
        self.stats.rach += 1

    def _route_sdcch(self, l2):
        """True if the uplink SDCCH block leaves as FACCH (consumed here).

        Split out of _poll_sdcch so that the DSP bridge (pont/dsp/uplink.py)
        can override it; the grgsm setup keeps this code."""
        tn_tch = self.tch.active_tn()
        if tn_tch is not None and not self.tch.is_open():
            if gsm.rr_message_type(l2)[1] == gsm.RR_ASSIGNMENT_COMPLETE:
                self.tch.prove("ASSIGNMENT COMPLETE")
                self._queue_facch(l2)
                return True
        elif self.tch.is_open():
            self._queue_facch(l2)
            return True
        return False

    def _poll_sdcch(self):
        b = self.sb_sdcch.new_record()
        if b is not None:
            l2 = b[16:39]
            if self._route_sdcch(l2):
                return
            # The block WAITS for the channel to be known, it is not dropped.
            # Layer 1 publishes the SABM at the very moment it emits it, and
            # the dedicated channel is read here at most every DCCH_TTL
            # seconds: the first block of a connection would fall in that
            # window. The channel is re-read right away and the block is kept
            # for a moment if it is not armed yet.
            self.sdcch_attente = (l2, time.monotonic())
            self.dedicated.refresh()
        if self.sdcch_attente is None:
            return
        l2, depuis = self.sdcch_attente
        ded = self.dedicated.plan()
        if ded is None:
            if time.monotonic() - depuis > SDCCH_ATTENTE:
                log.info("SDCCH montant : aucun canal dedie apres %.1f s, bloc abandonne",
                         SDCCH_ATTENTE)
                self.sdcch_attente = None
            return
        plan, ss, tn = ded
        bursts = self._bursts_xcch(l2)
        if bursts is None:
            return          # the DSP setup is still waiting for the ROM's bursts (pont/dsp/uplink.py)
        self.sdcch_attente = None

        # SDCCH or SACCH? Layer 1 cannot tell: the firmware puts both in the
        # SAME a_cu buffer with the SAME task word (prim_tx_nb.c:118,
        # dsp_load_tx_task(DUL_DSP_TASK) in both cases); only its internal
        # MF_F_SACCH flag separates them, and it never reaches the RAM API. So
        # it is decided here, on the SHAPE of the block: an SDCCH block starts
        # with the LAPDm address (0x01 or 0x03), a SACCH block with its two L1
        # header octets (ordered power, TA), the address only coming at
        # position 2.
        #
        # The two kinds of block seen on the SDCCH path:
        #   01 3f 49 05 08 70 ...  -> SABM + LOCATION UPDATING REQUEST
        #   07 00 01 03 49 06 15   -> L1 header (pwr 7, TA 0) + MEASUREMENT REPORT
        # Sending the second on the uplink SDCCH frames would leave the uplink
        # SACCH empty: the BTS would see nothing on its slow link and drop the
        # channel a few seconds after establishment.
        #
        # SAPI 3: its LAPDm address is 0x0d / 0x0f, and a SAPI 3 frame without
        # information (UA, SABM, RR, DISC) carries at position 2 a length
        # indicator L=0, i.e. 0x01 -- exactly what the test above would take
        # for the SAPI 0 address of a SACCH block, e.g.
        #   0f 73 01 2b 2b ...     -> UA SAPI 3 (answer to the BTS's SABM)
        # Sent on the uplink SACCH, the BTS would decode it as "Unknown (SS)",
        # never establish SAPI 3, and the SMS CP-DATA would not leave.
        # Octet 0 = 0x0d / 0x0f is ambiguous (power 13 / 15 of a SACCH
        # header): SACCH is chosen only if the SACCH reading holds up --
        # TA <= 63 (6 bits) and a real LAPDm control field at position 3, not
        # the 0x2b padding that follows an empty SAPI 3 frame.
        sacch = l2[0] not in (0x01, 0x03) and l2[2] in (0x01, 0x03)
        if sacch and l2[0] in (0x0d, 0x0f):
            sacch = l2[1] <= 63 and l2[3] != 0x2b
        if sacch:
            base = (plan.sacch_dl102[ss % plan.n_sub] + 15) % 102
            fn0 = self._next_fn(4, lambda f: f % 102 == base)
            self.feed.l2(self.clock.fn(), gsm.GSMTAP_SACCH, l2, tn, True)
            self.stats.sacch_ul += 1
        else:
            base = plan.ul_base(ss)
            fn0 = self._next_fn(4, lambda f: f % 51 == base)
            self.feed.l2(self.clock.fn(), gsm.GSMTAP_SDCCH4, l2, tn, True)
        for j, burst in enumerate(bursts):
            self.tx.schedule(tn, (fn0 + j) % gsm.HYPERFRAME, burst, True)

    def _bursts_xcch(self, l2):
        """The 4 bursts of an uplink SDCCH/SACCH block. Coded here by the host; the DSP bridge
        (pont/dsp/uplink.py) takes the ROM's. None = not ready yet, the block stays pending
        and _poll_sdcch presents it again on the next turn."""
        self.stats.xcch_ul_hote += 1
        return gsm.xcch_encode(l2)

    def _poll_facch(self):
        tn = self.tch.active_tn()
        if tn is None:
            self.tch_epoch = -1
            return
        if self.tch_epoch != self.tch.seq:
            # DO NOT DROP THE FIRST FACCH AFTER ARMING.
            #
            # `skip_pending()` moves the cursor past EVERYTHING already written
            # in the side band. `tch.seq` is incremented by `tch.arm()`, called
            # when the bridge decodes the downlink ASSIGNMENT COMMAND -- and the
            # ASSIGNMENT COMPLETE is precisely THE FIRST thing the mobile emits
            # on the new TCH, so skipping the FACCH here would mark it "already
            # seen" and the BSC would end in "Assignment failed in state
            # WAIT_RR_ASS_COMPLETE, cause EQUIPMENT FAILURE: Timeout".
            #
            # The skip is kept for the SACCH (a stale measurement report is
            # useless) but the pending FACCH is PROCESSED. The residual risk --
            # replaying a FACCH of the previous session -- is bounded to one
            # block, which LAPDm rejects.
            # PONT_FACCH_SKIP=1 skips the pending FACCH as well.
            self.tch_epoch = self.tch.seq
            self.sb_sacch.skip_pending()
            if os.environ.get("PONT_FACCH_SKIP", "0") == "1":
                self.sb_facch.skip_pending()
                return
        b = self.sb_facch.new_record()
        if b is None:
            return
        l2 = b[16:39]
        # A block that is not a FACCH (see _queue_facch) does not open the TCH.
        if l2[0] not in (0x01, 0x03) and os.environ.get("PONT_FACCH_TOUT", "0") != "1":
            self._queue_facch(l2)
            return
        ouverture = not self.tch.is_open()
        self.tch.prove("FACCH montante%s" % (", ASSIGNMENT COMPLETE" if gsm.rr_message_type(l2)[1] == gsm.RR_ASSIGNMENT_COMPLETE else ""))
        self._queue_facch(l2, ouverture)

    def _poll_sacch(self):
        b = self.sb_sacch.new_record()
        if b is None:
            return
        self.sacch_l2 = bytes(b[16:39])
        self.stats.sacch_ul += 1

    def _poll_release(self):
        active = self.dedicated.plan() is not None
        if self.ded_active and not active:
            reason = "canal libere par le mobile"
        elif self.tch.release_overdue(RELEASE_FALLBACK):
            reason = "CHANNEL RELEASE sans liberation du mobile depuis %ds" % RELEASE_FALLBACK
        else:
            self.ded_active = active
            return
        self.ded_active = active
        self.tch.close(reason)
        self.cipher.release(reason)

    def _poll_voice(self):
        if not self.tch.is_open():
            return
        frames, lost = self.ring.drain()
        self.stats.tch_ul_dropped += lost
        for fr in frames:
            with self.q_lock:
                if len(self.q_voice) == self.q_voice.maxlen:
                    self.stats.tch_ul_dropped += 1
                self.q_voice.append(bytes(fr))
            self.stats.tch_ul += 1

    def run(self):
        while True:
            self._poll_release()
            self._poll_rach()
            self._poll_sdcch()
            self._poll_facch()
            self._poll_sacch()
            self._poll_voice()
            time.sleep(POLL)


class TchScheduler(threading.Thread):
    def __init__(self, cfg, clock, stats, tch, uplink, transmitter):
        super().__init__(name="tch-tx", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.tch = tch
        self.uplink = uplink
        self.tx = transmitter
        self.buf = (gsm.ubit * (TX_BURSTS * BPLEN))()
        self.mask = 0
        self.sent_sacch_block = None
        tch.on_close.append(self._reset)

    def _reset(self):
        ctypes.memset(self.buf, 0, TX_BURSTS * BPLEN)
        self.mask = 0
        self.sent_sacch_block = None
        with self.uplink.q_lock:
            self.uplink.q_facch.clear()
            self.uplink.q_voice.clear()

    def _load_block(self):
        ctypes.memmove(self.buf, ctypes.byref(self.buf, 4 * BPLEN), 20 * BPLEN)
        ctypes.memset(ctypes.byref(self.buf, 20 * BPLEN), 0, 4 * BPLEN)
        self.mask = (self.mask << 4) & 0xFFFFFFFF
        with self.uplink.q_lock:
            facch = self.uplink.q_facch.popleft() if self.uplink.q_facch else None
            voice = self.uplink.q_voice.popleft() if self.uplink.q_voice else None
        gsm.tch_fr_encode_into(self.buf, facch if facch is not None else voice)

    def _sacch(self, tn, fn_air):
        if not gsm.sacch_tf_block_start(fn_air, tn):
            return
        block = fn_air - (fn_air % 104)
        if self.uplink.sacch_l2 is None or self.sent_sacch_block == block:
            return
        self.sent_sacch_block = block
        for j, burst in enumerate(gsm.xcch_encode(self.uplink.sacch_l2)):
            self.tx.schedule(tn, (fn_air + 26 * j) % gsm.HYPERFRAME, burst, True)

    def run(self):
        fn_air = None
        while True:
            tn = self.tch.active_tn()
            if tn is None or not self.tch.is_open():
                fn_air = None
                time.sleep(0.05)
                continue
            if fn_air is None:
                fn_air = (self.clock.fn() + self.cfg.ul_fn_advance + 1) % gsm.HYPERFRAME
            else:
                fn_air = (fn_air + 1) % gsm.HYPERFRAME
            self.clock.sleep_until_fn((fn_air - self.cfg.ul_fn_advance) % gsm.HYPERFRAME)
            self._sacch(tn, fn_air)
            if not gsm.is_tch_carrier(fn_air):
                continue
            bid = gsm.tch_burst_index(fn_air) % 4
            if bid == 0:
                self._load_block()
            elif not (self.mask & 0x01):
                continue
            base = bid * BPLEN
            burst = gsm.burst_from_coded(bytes(self.buf)[base:base + BPLEN])
            self.mask |= 1 << bid
            self.tx.schedule(tn, fn_air, burst, True)
            self.stats.tch_ul_bursts += 1
