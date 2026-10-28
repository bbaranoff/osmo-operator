import heapq
import logging
import os
import socket
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

# THE BENCH CLOCK FOLLOWS THE DSP, NOT THE WALL.
#
# In the DSP setup the C54x is emulated: it costs ~5.8 ms per TDMA frame
# against 4.615 ms of real time. The BTS runs on the clock this file sends it
# (IND CLOCK, run_clock). With a wall clock it would emit 1.25 frames for each
# one the DSP consumes: the BSP would replay an ever older ring, the IMMEDIATE
# ASSIGNMENT would arrive after T3126 and the dedicated channel would yield
# incomplete blocks ("Dropping frame with 110 bit errors").
#
# c54x_exe publishes the BTS frame its BSP requests (calypso_bsp.c,
# bsp_horloge_publier). The clock is slaved to it IN FREQUENCY, not by
# re-alignment: the effective frame duration (self.dur) follows the measured
# DSP rate, with a proportional correction holding the phase lead at AVANCE
# frames.
#
# Why not a simple re-alignment of t0: Transmitter.run() drops any burst
# whose frame is more than window_tol (1 frame) away from the clock at send
# time; a clock stepping forward by a few frames leaves that window every
# time, so no SABM reaches the BTS, hence no UA, hence "MDL-ERROR-IND cause 1"
# and no location update. A slaved clock must stay CONTINUOUS: only its speed
# changes, and t0 is rebased at each change so that fn() never jumps.
#
# PONT_HORLOGE=0 falls back to the wall clock; a missing file (setup without
# DSP, gr-gsm layer 1) also leaves the clock free, with nothing to configure.
HORLOGE = "/dev/shm/calypso_horloge"
#
# LOOP TUNING. The loop must run faster (~1.3 Hz) than the rate at which the
# DSP speed itself moves: a slower loop (~0.07 Hz) lets the phase enter a
# limit cycle of +/- 100 frames, and each half-turn where the error goes
# negative puts the bridge BEHIND the requested frame -- frames skipped that
# way are counted NOWHERE (neither "tard" nor "manques" on the BSP side).
# Do NOT "fix" that by raising PONT_HORLOGE_AVANCE: it hides the limit cycle
# behind a margin without removing it, and delays the whole uplink as much.
# The values are read from the environment so they can be swept without
# editing the code.
HORLOGE_PERIODE = float(os.environ.get("PONT_HORLOGE_PERIODE", "0.05"))
HORLOGE_KP = float(os.environ.get("PONT_HORLOGE_KP", "1.0"))
HORLOGE_PHASE_N = float(os.environ.get("PONT_HORLOGE_PHASE_N", "100.0"))
# SLOWDOWN CEILING. PONT_HORLOGE_MAX (default 4) bounds the factor by which the
# slaved clock may slow below real time. With the full ARM asm trace
# (start-native.sh --assembly-logs, ASSEMBLY_LOGS_FLAGS=in_asm,exec,nochain)
# the ARM+DSP pair runs at 66 ms per frame, 14 times real time, and the bridge
# would otherwise run thousands of frames ahead, the BSP no longer finding the
# bursts; c54x_exe/run.sh sets 20 when ASSEMBLY_LOGS=1. The ceiling stays low
# in normal operation: after a DSP jolt the rate measured over 50 ms explodes
# and the clock must not collapse.
# Above 4, run_clock shortens the IND CLOCK period, see below.
HORLOGE_MAX = float(os.environ.get("PONT_HORLOGE_MAX", "4.0"))
# IND CLOCK with a slow clock, see run_clock: maximum lead left to the BTS
# before the IND (= requested pause, BTS limit 50), fn-advance of the BTS
# (osmotrx fn-advance), and safeguard if the BTS stops delivering
# (osmo-bts-trx cuts after TRX_LOSS_FRAMES = 400 frames without IND).
CLCK_PAUSE_MAX = int(os.environ.get("PONT_CLCK_PAUSE_MAX", "20"))
CLCK_BTS_FN_ADVANCE = int(os.environ.get("PONT_BTS_FN_ADVANCE", "2"))
CLCK_SANS_IND_MAX = int(os.environ.get("PONT_CLCK_SANS_IND_MAX", "300"))
# CEILING OF THE PAUSE REQUESTED FROM THE BTS. osmo-bts-trx (scheduler_trx.c) pauses its timer for
# N+1 frames when the IND says it is N frames ahead (N <= MAX_FN_SKEW = 50; beyond that it re-aligns,
# "GSM clock skew", harmlessly); if two expirations are then more than 50 frames apart (230.75 ms),
# it EXITS ("PC clock skew too high"). A pause of 46 to 50 frames plus one frame of jitter is enough
# to kill it. If the BTS lead falls in the dangerous zone (> CEILING and <= MAX_FN_SKEW + margin), the
# IND carries fn_bts - CEILING instead of fn_trx: the pause is bounded and the remaining lead is
# absorbed by the following INDs (bursts only arrive earlier, the BSP ring keeps them). 0 = no ceiling.
CLCK_PAUSE_PLAFOND = int(os.environ.get("PONT_CLCK_PAUSE_PLAFOND", "38"))
CLCK_SKEW_ZONE = int(os.environ.get("PONT_CLCK_SKEW_ZONE", "60"))   # beyond, the BTS re-aligns on its own


class Clock:
    def __init__(self):
        self.t0 = time.monotonic()
        self.dur = gsm.FRAME_DUR
        self._verrou = threading.Lock()
        self._asservie = os.environ.get("PONT_HORLOGE", "1") not in ("0", "", "no")
        self._avance = int(os.environ.get("PONT_HORLOGE_AVANCE", "12"))
        self._fd = None
        self._echeance = 0.0
        self._t_prec = None
        self._dsp_prec = None
        self._dit = False

    def _lire_dsp(self):
        """BTS frame the DSP requests, or None if it is not synchronised yet."""
        try:
            if self._fd is None:
                self._fd = os.open(HORLOGE, os.O_RDONLY)
            b = os.pread(self._fd, 16, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            return None
        if len(b) < 16:
            return None
        seq, cale, fn_bts, _tick = struct.unpack("<IIII", b)
        return fn_bts % gsm.HYPERFRAME if (seq and cale) else None

    def _reguler(self, now):
        """Called under lock, at most once per HORLOGE_PERIODE."""
        if now < self._echeance:
            return
        self._echeance = now + HORLOGE_PERIODE
        dsp = self._lire_dsp()
        if dsp is None:
            self._t_prec = self._dsp_prec = None
            return
        if not self._dit:
            self._dit = True
            log.info("horloge asservie au DSP (%s, avance visee %d trames, ralentissement max x%g)",
                     HORLOGE, self._avance, HORLOGE_MAX)
        t_prec, dsp_prec = self._t_prec, self._dsp_prec
        self._t_prec, self._dsp_prec = now, dsp
        if t_prec is None:
            return
        avancees = (dsp - dsp_prec) % gsm.HYPERFRAME
        if avancees <= 0 or avancees > gsm.HYPERFRAME // 2:
            return                                   # DSP stopped or re-aligned: keep the speed
        dur_dsp = (now - t_prec) / avancees          # measured DSP rate
        # Phase error, in frames, signed: > 0 = the bench clock is ahead.
        f = (now - self.t0) / self.dur
        ecart = (int(f) - (dsp + self._avance)) % gsm.HYPERFRAME
        if ecart > gsm.HYPERFRAME // 2:
            ecart -= gsm.HYPERFRAME
        cible = dur_dsp * (1.0 + HORLOGE_KP * ecart / HORLOGE_PHASE_N)
        cible = min(max(cible, gsm.FRAME_DUR * 0.5), gsm.FRAME_DUR * HORLOGE_MAX)
        dur = 0.7 * self.dur + 0.3 * cible
        self.t0 = now - f * dur                      # rebase: fn() stays continuous
        self.dur = dur

    def fn(self):
        now = time.monotonic()
        if not self._asservie:
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME
        with self._verrou:
            self._reguler(now)
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME

    def time_of(self, fn):
        now = time.monotonic()
        if self._asservie:
            with self._verrou:
                self._reguler(now)
                t0, dur = self.t0, self.dur
        else:
            t0, dur = self.t0, self.dur
        cur = int((now - t0) / dur)
        delta = (fn - cur) % gsm.HYPERFRAME
        if delta > gsm.HYPERFRAME // 2:
            delta -= gsm.HYPERFRAME
        return t0 + (cur + delta) * dur

    def sleep_until_fn(self, fn):
        dt = self.time_of(fn) - time.monotonic()
        if dt > 0:
            time.sleep(dt)


def _udp(bind_host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind_host, port))
    return s


class Trx:
    def __init__(self, cfg, clock, stats, cipher, record, dedicated=None, tch=None):
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.cipher = cipher
        self.record = record
        self.dedicated = dedicated
        self.tch = tch
        self.sk_clck = _udp(cfg.trx_bind, cfg.trx_base)
        self.sk_ctrl = _udp(cfg.trx_bind, cfg.trx_base + 1)
        self.sk_data = _udp(cfg.trx_bind, cfg.trx_base + 2)
        self.bts_data = None
        self.bts_clck = None
        self.fn_bts_vu = None          # fn of the last downlink burst received from the BTS (run_data)
        self._clck_t = 0.0             # last IND CLOCK: time, BTS fn seen, requested lead
        self._clck_vu = None
        self._clck_avance = 0
        self._clck_lent = False
        # COPIES OF THE DOWNLINK to other BSPs (PONT_DSP_COPIES, comma-separated UDP ports): a
        # Calypso listening to the cell without being the bridge's mobile, e.g. the rssi app of
        # instance 4 (banc-rssi, BSP udp 6762) with a classic BTS. Separate socket: a port without
        # a listener (rssi not started) must not change anything on the mobile's path.
        self.dsp_copies = [int(p) for p in os.environ.get("PONT_DSP_COPIES", "").replace(",", " ").split()
                           if p.isdigit() and int(p) != cfg.dsp_port]
        self.sk_copies = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) if self.dsp_copies else None
        self.copies_ul = os.environ.get("PONT_DSP_COPIES_UL", "1") != "0"

    def run_ctrl(self):
        while True:
            data, addr = self.sk_ctrl.recvfrom(1500)
            req = data.decode("latin1").strip("\0").strip()
            if not req.startswith("CMD"):
                continue
            parts = req.split()
            cmd = parts[1] if len(parts) > 1 else ""
            args = (" " + " ".join(parts[2:])) if len(parts) > 2 else ""
            self.sk_ctrl.sendto(("RSP %s 0%s" % (cmd, args)).encode() + b"\0", addr)
            if self.bts_clck is None:
                self.bts_clck = (addr[0], self.cfg.trx_base + 100)
                log.info("BTS %s : horloge armee vers le port %d", addr[0], self.bts_clck[1])
            if cmd not in ("SETPOWER", "NOHANDOVER"):
                log.info("CTRL %s%s", cmd, args)

    def run_clock(self):
        # IND CLOCK WHEN THE CLOCK IS SLOW: WAIT FOR THE BTS TO RESUME.
        # osmo-bts-trx (scheduler_trx.c) advances its frames at its own wall
        # rate between two IND CLOCKs. At each IND it measures
        # elapsed_fn = fn_trx - fn_bts; if negative, it PAUSES its timer for
        # -elapsed_fn frames ("We were N FN faster than TRX, compensating"), and
        # that pause is RE-ARMED FROM NOW by any IND received while it runs. Its
        # timer kills the BTS if two expirations are more than MAX_FN_SKEW = 50
        # frames apart ("PC clock skew too high"). With the fixed period of 51
        # frames and k <= 4 the pause is 38 frames and ends 13 frames before
        # the next IND; at k=14 it would be 47 frames, 3 frames from the next
        # IND: untenable.
        # Rule. As long as the fixed-period pause, period x (1 - 1/k), stays
        # under CLCK_PAUSE_MAX (k <= ~1.9), nothing changes: one IND every 51
        # frames, the pause ends well before the next. Beyond that, an IND is
        # sent only when (1) the pause requested by the previous one has
        # elapsed AND the BTS has started delivering bursts again (fn seen by
        # run_data advances), and (2) the BTS is CLCK_PAUSE_MAX frames ahead of
        # the clock again. After a pause N the lead is still N (1 - 1/k): the
        # BTS only runs a few frames before the next IND, the requested pause
        # stays ~CLCK_PAUSE_MAX whatever k and is never re-armed. No return to
        # the fixed period in this regime: it would let the lead climb to
        # 40-100 frames.
        # Downlink bursts carry fn_bts + clock_advance (osmotrx fn-advance,
        # 2 by default: main.c).
        periode = self.cfg.clock_period
        pause_max = CLCK_PAUSE_MAX
        fn_adv = CLCK_BTS_FN_ADVANCE
        demi = gsm.HYPERFRAME // 2
        lent = False
        while True:
            now = time.monotonic()
            if self.bts_clck:
                fn_trx = self.clock.fn()
                k = self.clock.dur / gsm.FRAME_DUR
                vu = self.fn_bts_vu
                attente = (now - self._clck_t) / gsm.FRAME_DUR
                lent = k > 1.0 and vu is not None and periode * (1.0 - 1.0 / k) > pause_max
                if lent != self._clck_lent:
                    self._clck_lent = lent
                    if lent:
                        log.info("IND CLOCK : horloge lente (x%.1f), on attend la reprise de la BTS entre deux IND "
                                 "(pause max %d trames)", k, pause_max)
                    else:
                        log.info("IND CLOCK : horloge x%.1f, retour a la periode fixe de %d trames", k, periode)
                if not lent:
                    envoyer = attente >= periode
                    avance = 0
                else:
                    avance = ((vu - fn_adv - fn_trx) + demi) % gsm.HYPERFRAME - demi
                    # BTS resumed: bursts arrive again. One or two may be in flight
                    # right after the IND, hence the awaited pause (or 3 bursts, if
                    # the BTS re-aligned without a pause: "GSM clock skew", or the
                    # previous IND was sent before its first burst).
                    if self._clck_vu is None:
                        livre = 3
                    else:
                        livre = ((vu - self._clck_vu) + demi) % gsm.HYPERFRAME - demi
                    reprise = livre >= 3 or (livre >= 1 and attente >= self._clck_avance)
                    envoyer = (reprise and avance >= pause_max) or attente >= CLCK_SANS_IND_MAX
                if envoyer:
                    fn_ind = fn_trx
                    if CLCK_PAUSE_PLAFOND > 0 and vu is not None:
                        av_bts = ((vu - fn_adv - fn_trx) + demi) % gsm.HYPERFRAME - demi
                        if CLCK_PAUSE_PLAFOND < av_bts <= CLCK_SKEW_ZONE:
                            fn_ind = (fn_trx + av_bts - CLCK_PAUSE_PLAFOND) % gsm.HYPERFRAME
                            self._clck_bornees = getattr(self, "_clck_bornees", 0) + 1
                            if self._clck_bornees <= 20 or self._clck_bornees % 100 == 0:
                                log.warning("IND CLOCK : BTS %d trames devant, pause bornee a %d (fn %u au lieu de %u, "
                                            "%d fois)", av_bts, CLCK_PAUSE_PLAFOND, fn_ind, fn_trx, self._clck_bornees)
                    self.sk_clck.sendto(("IND CLOCK %u" % fn_ind).encode() + b"\0", self.bts_clck)
                    self._clck_t = now
                    self._clck_vu = vu
                    self._clck_avance = max(avance, 0)
                    self.stats_clck(avance)
            # Slaved clock (k > 1): poll every frame, otherwise the first lead
            # measurement after start-up comes 51 frames too late (lead 47 at
            # k=14, pause > 50: BTS stopped from the start).
            # In the slow regime, every half frame: the equilibrium pause is
            # r (k - 1), r being the detection delay of the resume (~1.5 frame
            # when polling per frame, i.e. 30 frames at k=20; ~1 per half frame).
            if lent:
                time.sleep(gsm.FRAME_DUR / 2)
            else:
                time.sleep(gsm.FRAME_DUR if self.clock.dur > gsm.FRAME_DUR else gsm.FRAME_DUR * periode)

    def stats_clck(self, avance):
        """Count the IND CLOCKs sent with a slow clock; log the long pauses."""
        if not self._clck_lent:
            return
        self._clck_n = getattr(self, "_clck_n", 0) + 1
        if avance > CLCK_PAUSE_MAX + 10 and getattr(self, "_clck_longues", 0) < 20:
            self._clck_longues = getattr(self, "_clck_longues", 0) + 1
            log.warning("IND CLOCK : la BTS avait %d trames d'avance (pause demandee > %d, limite BTS 50)",
                        avance, CLCK_PAUSE_MAX)

    def run_data(self, on_burst):
        while True:
            data, addr = self.sk_data.recvfrom(2000)
            self.bts_data = addr
            if len(data) < 6 + 148:
                continue
            tn = data[0] & 0x07
            fn = struct.unpack_from(">L", data, 1)[0]
            self.fn_bts_vu = fn            # where the BTS is (run_clock, slow clock)
            bits = gsm.normalize_bits(data[6:154])
            if self.cfg.dsp_port:
                # The same burst, as the DSP's BSP expects it
                # (calypso_bsp.c bsp_trxd_readable): 8 header bytes
                # [tn, fn BE32, attenuation, 0, 0] then 148 bits 0/1. The BSP
                # converts them itself to I/Q (cos table) and puts them in DARAM.
                #
                # THE DOWNLINK OF THE DEDICATED CHANNEL IS DECIPHERED HERE.
                # send_ul() CIPHERS the uplink (the bridge stands in for the
                # DSP's transmit path), and there is no A5 in the Calypso model
                # -- `d_a5mode` only exists in l1-grgsm/, nothing in l1-dsp/ --
                # so nobody else deciphers the downlink. A5 is symmetric:
                # applying the stream to the downlink deciphers it.
                # ONLY on the dedicated timeslot: the BCCH and the CCCH are
                # never ciphered, touching them would destroy camping.
                bits_dsp = bits
                if self.dechiffre_dl and self.cipher.dl_active and self._burst_dedie(tn, fn):
                    bits_dsp = self.cipher.apply(bits, fn, False)
                hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([data[5] if len(data) > 5 else 0, 0, 0])
                paquet = hdr + bytes(1 if b else 0 for b in bits_dsp)
                self.sk_data.sendto(paquet, ("127.0.0.1", self.cfg.dsp_port))
                for port in self.dsp_copies:
                    try:
                        self.sk_copies.sendto(paquet, ("127.0.0.1", port))
                    except OSError:
                        pass
            on_burst(tn, fn, bits)

    # Decipher the downlink before passing it to the BSP: yes for the gr-gsm
    # shunt, no in the DSP setup (TrxDsp) where the ROM does it itself.
    dechiffre_dl = True

    def _burst_dedie(self, tn, fn):
        """True if THIS burst belongs to the mobile's dedicated channel.

        Testing the timeslot alone (`tn == tn_dedie`) is not enough: in
        CCCH+SDCCH/4 the dedicated channel lives on TS0, which ALSO carries the
        FCCH, the SCH, the BCCH and the CCCH -- never ciphered, by definition:
        the mobile must be able to read them before it has a key. XORing all
        of TS0 towards the DSP would undo camping under the ongoing
        transaction. The same sorting as Downlink._signalling is done here: the
        block must be the one of the mobile's subchannel `ss`, SDCCH or SACCH.
        The read is cached by Dedicated (DCCH_TTL), so this can be called on
        every burst."""
        if self.tch is not None and self.tch.is_open():
            # On an assigned TCH the whole timeslot belongs to the transaction
            # (traffic, FACCH and SACCH): no subchannel to sort.
            if tn == self.tch.active_tn():
                return True
        if self.dedicated is None:
            return False
        ded = self.dedicated.plan()
        if ded is None:
            return False
        plan, ss, tn_ded = ded
        if tn != tn_ded:
            return False
        m51 = fn % 51
        base = next((b for b in plan.ded_bases if b <= m51 <= b + 3), None)
        if base is None:
            return False
        ss %= plan.n_sub
        if base in plan.sdcch_dl:
            return base == plan.sdcch_dl[ss]
        return (fn - (m51 - base)) % 102 == plan.sacch_dl102[ss]

    def send_ul(self, tn, fn, burst, cipher):
        if self.bts_data is None:
            return
        if cipher:
            burst = self.cipher.apply(burst, fn, True)
        hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([self.cfg.rssi & 0xFF]) + struct.pack(">h", 0)
        self.sk_data.sendto(hdr + bytes(255 if b else 0 for b in burst), self.bts_data)
        self.stats.ul_sent += 1
        # The UPLINK also goes to the copies (PONT_DSP_COPIES), marked 0xA5 at byte 6: the BSP
        # (calypso_bsp.c, CALYPSO_AIR_NIVEAUX) files it separately and only plays it in a window tuned
        # to the uplink frequency (rssi, UL view). PONT_DSP_COPIES_UL=0 disables it.
        if self.dsp_copies and self.copies_ul:
            paquet = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([0, 0xA5, 0]) + bytes(1 if b else 0 for b in burst)
            for port in self.dsp_copies:
                try:
                    self.sk_copies.sendto(paquet, ("127.0.0.1", port))
                except OSError:
                    pass
        if self.record:
            self.record.feed_ul(fn, tn, burst)


class Transmitter(threading.Thread):
    def __init__(self, cfg, clock, trx, stats):
        super().__init__(name="tx", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.trx = trx
        self.stats = stats
        self.cond = threading.Condition()
        self.heap = []
        self.seq = 0

    def schedule(self, tn, fn_air, burst, cipher, essais=0):
        post = self.clock.time_of((fn_air - self.cfg.ul_fn_advance) % gsm.HYPERFRAME)
        with self.cond:
            self.seq += 1
            heapq.heappush(self.heap, (post, self.seq, tn, fn_air, burst, cipher, essais))
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while not self.heap:
                    self.cond.wait()
                post = self.heap[0][0]
                dt = post - time.monotonic()
                if dt > 0:
                    self.cond.wait(dt)
                    continue
                _, _, tn, fn_air, burst, cipher, essais = heapq.heappop(self.heap)
            cur = self.clock.fn()
            off = (fn_air - (cur + self.cfg.ul_fn_advance) + gsm.HYPERFRAME // 2) % gsm.HYPERFRAME - gsm.HYPERFRAME // 2
            # TOO EARLY IS NOT TOO LATE.
            # `post` is computed at queueing time, from the clock rate AT THAT
            # MOMENT. Since the clock follows the DSP (see Clock above), it no
            # longer advances at wall pace: the DSP stalls, the clock with it,
            # and the wake-up comes before the target frame has arrived. Such a
            # burst is early, not late: it is re-queued with a `post`
            # recomputed on the current clock; only a REALLY late burst is lost.
            if off > self.cfg.window_tol:
                if essais < self.cfg.window_essais:
                    self.schedule(tn, fn_air, burst, cipher, essais + 1)
                else:
                    self.stats.ul_late += 1
                continue
            if off < -self.cfg.window_tol:
                # LATE IS NOT LOST. osmo-bts-trx files an uplink burst by ITS
                # fn, compared with the last fn processed on the same logical
                # channel (scheduler.c, trx_sched_route_burst_ind); the arrival
                # time plays no part -- a real transceiver always delivers the
                # uplink after the fact. The lateness comes from the thread
                # wake-up (GIL shared with the I/Q recording) and from the
                # variations of the DSP-slaved clock, not from the BTS.
                # The burst is sent as long as it stays within the multiframe
                # (the BTS refuses beyond mf_period, "Too many contiguous TDMA
                # frames"). PONT_UL_RETARD_MAX=0 drops late bursts.
                self.stats.ul_late += 1
                if -off > self.cfg.ul_retard_max:
                    continue
            self.trx.send_ul(tn, fn_air, burst, cipher)
