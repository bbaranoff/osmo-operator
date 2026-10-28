# pont/dsp/dedicated.py - calypso_dcch_cfg as written by the QEMU tap of the
# DSP setup (qosmo hw/arm/calypso/calypso_dcch_tap.c).
#
# The tap also announces the TCH: kind 2 = TCH/F, 3 = TCH/H. Dedicated.read
# (pont/state.py) keeps only bit 0 of the kind: a kind 2 would become there an
# SDCCH/4 on the TCH's TS -- the uplink SDCCH of an ASSIGNMENT FAILURE would
# then be scheduled on TS2.
#
# Here the TCH is noted separately and plan() keeps returning the LAST SDCCH as
# long as the connection lives: this is what DownlinkDsp, TrxDsp and UplinkDsp
# expect, and it is the right channel if the mobile comes back to it
# (ASSIGNMENT FAILURE). Only 0xFF (return to the common channels) ends the
# connection: UplinkDsp._poll_release therefore does not see the arrival on
# the TCH as a release.
# pont.py (grgsm) keeps state.Dedicated: its layer 1 never writes a kind 2.
import logging
import os
import struct
import time

from ..state import DCCH_CFG, DCCH_RELEASED, DCCH_TTL, Dedicated

log = logging.getLogger("pont")

DCCH_TCH_F = 2
DCCH_TCH_H = 3
# Kind 4 = PDCH (GPRS): the l1gprs_fw.c firmware is on a PDCH; the QEMU tap
# (calypso_dcch_tap.c) publishes it from the L1CTL_GPRS_DL_BLOCK_IND.
DCCH_PDCH = 4


class DedicatedDsp(Dedicated):
    def __init__(self):
        super().__init__()
        self._tch = None        # (kind, ss, tn): the firmware is on the TCH
        self._pdch = None       # tn: the firmware is on a PDCH (GPRS)

    def read(self):
        now = time.monotonic()
        if now < self._next:
            return self._value
        self._next = now + DCCH_TTL
        try:
            if self._fd is None:
                self._fd = os.open(DCCH_CFG, os.O_RDONLY)
            b = os.pread(self._fd, 16, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            return self._value
        if len(b) < 8:
            return self._value
        seq = struct.unpack_from("<I", b, 0)[0]
        if not seq or seq == self._seq:
            return self._value
        self._seq = seq
        genre, ss, tn = b[4], b[5] & 7, b[6] & 7
        if genre == DCCH_RELEASED:
            self._value = None
            self._tch = None
            self._pdch = None
        elif genre == DCCH_PDCH:
            self._pdch = tn
            log.info("canal dedie : PDCH TS=%d annonce par le firmware (GPRS)", tn)
        elif genre in (DCCH_TCH_F, DCCH_TCH_H):
            self._pdch_quitte("TCH", tn)
            self._tch = (genre, ss, tn)
            if self._value is None:
                log.info("canal dedie : TCH/%s TS=%d SS=%d annonce par le firmware, aucun SDCCH connu",
                         "F" if genre == DCCH_TCH_F else "H", tn, ss)
            else:
                log.info("canal dedie : TCH/%s TS=%d SS=%d annonce par le firmware "
                         "(SDCCH SS=%d TS=%d garde pour un retour)",
                         "F" if genre == DCCH_TCH_F else "H", tn, ss, self._value[1], self._value[2])
        else:
            self._pdch_quitte("SDCCH", tn)
            if self._tch is not None:
                log.info("canal dedie : le firmware a quitte le TCH TS=%d pour le SDCCH SS=%d TS=%d",
                         self._tch[2], ss, tn)
            self._tch = None
            self._value = (genre & 1, ss, tn)
        return self._value

    def _pdch_quitte(self, quoi, tn):
        # The firmware cannot be on a PDCH AND on an SDCCH/TCH: _pdch is cleared here,
        # otherwise tn_dedie() (dsp/uplink.py), which tests the PDCH first, would send the
        # ROM bursts of the dedicated channel on the PDCH's TS.
        if self._pdch is not None:
            log.info("canal dedie : le firmware a quitte le PDCH TS=%d pour un %s TS=%d", self._pdch, quoi, tn)
            self._pdch = None

    def tch(self):
        """(kind, ss, tn) if the firmware is on a TCH according to the tap, else None."""
        self.read()
        return self._tch

    def pdch(self):
        """tn if the firmware is on a PDCH (GPRS) according to the tap, else None."""
        self.read()
        return self._pdch
