# pont/dsp/clock.py - the DSP bridge clock: the advance follows the BTS.
#
# THE BTS ADVANCE IS CARRIED DYNAMICALLY OVER TO THE DSP.
#
# Clock (pont/trx.py) slaves the bench clock to "frame requested by the DSP
# + PONT_HORLOGE_AVANCE (12)". The BTS is the one transmitting, and its downlink
# bursts leave `osmotrx fn-advance` frames BEFORE that clock (2 by default),
# plus its jolts: "We missed 6 timers", "5 FN slower than TRX", then a block of
# catch-up. The margin actually useful to the BSP -- last frame received from
# the BTS minus frame requested by the DSP -- is 12 + fn-advance - jitter, which
# can fall below zero: frames without a burst are played as erasures, and a
# lost UA or FACCH block means "I frame ignored in state SABM_SENT" (the UA is
# missing, the following I frames arrive) or T200 on the assignment FACCH.
#
# ClockDsp measures at each regulation the real advance of the BTS over the
# clock (last downlink frame received - clock frame), keeps its MINIMUM over a
# sliding window (the BTS stalls are the dips), and sets
#     advance = PONT_MARGE_DL - min_BTS_advance
# so that "last frame received - frame requested" stays >= PONT_MARGE_DL.
# Changing `osmotrx fn-advance` live on the BTS is followed without a restart.
# The advance is bounded to [PONT_AVANCE_MIN, PONT_AVANCE_MAX]: beyond that the
# uplink leaves correspondingly later (Transmitter, PONT_UL_RETARD_MAX).
# PONT_MARGE_DL=0 falls back to Clock's fixed advance.
# Default 16: a margin of 8 doubles the frames without a burst (the 50 ms
# sampling does not see the worst BTS dips).
#
# THE BTS ADVANCE IS MEASURED AGAINST THE TARGET POINT, NOT THE CLOCK.
# Measured against the real clock (last received - clock), it would assume
# clock == DSP + advance. That is false as soon as the DSP waits for the BTS
# (CALYPSO_BSP_ATTENTE_MS): the DSP then sticks to the last received frame, the
# clock trails ~15 frames behind its target, the "BTS advance" read goes up and
# the target advance falls to the floor, leaving a holed downlink SDCCH (lost UA,
# the mobile repeats its SABM). So the measure is last received - (DSP +
# advance): the real margin, minus the advance already requested -- a closed
# loop on what must be held. Floor at 10 (the fixed advance 12 held at 1.6 %).
import collections
import logging
import os
import time

from .. import gsm
from ..trx import Clock

log = logging.getLogger("pont")

MARGE_DL = int(os.environ.get("PONT_MARGE_DL", "16"))
AVANCE_MIN = int(os.environ.get("PONT_AVANCE_MIN", "10"))
AVANCE_MAX = int(os.environ.get("PONT_AVANCE_MAX", "40"))
FENETRE_S = float(os.environ.get("PONT_MARGE_FENETRE", "3.0"))


class ClockDsp(Clock):
    def __init__(self):
        super().__init__()
        self._fn_dl = None                  # last downlink frame received from the BTS
        self._mesures = collections.deque() # (time, BTS advance over the clock)
        self._avance_dite = None

    def note_dl(self, fn):
        """Called by the TRXD thread on each downlink burst (no lock: a single
        integer assignment)."""
        prec = self._fn_dl
        if prec is None or 0 < (fn - prec) % gsm.HYPERFRAME < gsm.HYPERFRAME // 2:
            self._fn_dl = fn

    def _reguler(self, now):
        du = now >= self._echeance
        super()._reguler(now)                   # refreshes _dsp_prec (requested frame)
        dsp = self._dsp_prec
        if MARGE_DL > 0 and du and dsp is not None and self._fn_dl is not None:
            # BTS advance over the TARGET point (DSP + advance), not over the
            # real clock -- see the file header.
            avance_bts = (self._fn_dl - dsp - self._avance) % gsm.HYPERFRAME
            if avance_bts > gsm.HYPERFRAME // 2:
                avance_bts -= gsm.HYPERFRAME
            m = self._mesures
            m.append((now, avance_bts))
            while m and now - m[0][0] > FENETRE_S:
                m.popleft()
            creux = min(a for _, a in m)
            avance = min(max(MARGE_DL - creux, AVANCE_MIN), AVANCE_MAX)
            if avance != self._avance:
                self._avance = avance
                if self._avance_dite is None or abs(avance - self._avance_dite) >= 3:
                    self._avance_dite = avance
                    log.info("horloge : avance BTS mesuree %+d trames (creux sur %.0f s), "
                             "avance visee %d pour une marge DL >= %d",
                             creux, FENETRE_S, avance, MARGE_DL)
        self._mesurer_marge(now)

    def _mesurer_marge(self, now):
        """REAL margin seen by the BSP: last frame received - frame requested
        by the DSP (calypso_horloge). Logged every 10 s (min/mean): this is
        what must stay > 0, not the target advance."""
        dsp = self._dsp_prec
        if dsp is None or self._fn_dl is None:
            return
        marge = (self._fn_dl - dsp) % gsm.HYPERFRAME
        if marge > gsm.HYPERFRAME // 2:
            marge -= gsm.HYPERFRAME
        st = getattr(self, "_marges", None)
        if st is None:
            st = self._marges = [now, marge, 0, 0]
        st[1] = min(st[1], marge)
        st[2] += marge
        st[3] += 1
        if now - st[0] >= 10.0:
            log.info("horloge : marge DL reelle (recu - reclame par le DSP) min %+d moy %+.1f "
                     "sur %d mesures, avance visee %d", st[1], st[2] / st[3], st[3], self._avance)
            self._marges = [now, marge, 0, 0]
