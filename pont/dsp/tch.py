# pont/dsp/tch.py - the TCH as seen by the DSP bridge: an ANNOUNCEMENT, not a switch.
#
# In the DSP setup, /dev/shm/calypso_tch_cfg is read by c54x_exe
# (src/montant.c, scruter_tch). The BSP plays the frames at the DSP's time,
# 12 to ~200 frames later than the BTS: switching the BSP on the TCH as soon
# as the bridge decodes the ASSIGNMENT COMMAND would replace every frame not
# yet played -- the ASSIGNMENT COMMAND included, and TS0 with it -- by bursts
# of the TCH timeslot. c54x_exe therefore only switches at the first TCH task
# set by the firmware (montant.c, suivre_tache_tch); the write done here is
# only an announcement (timeslot, TSC).
#
# Same file, same format, same write moment as Tch.arm: the grgsm L1
# (calypso_l1_grgsm.c poll_tch_cfg) is not concerned, pont.py does not use
# this class. The only extra case, non-zero seq with tn=0, is the abandon.
import logging

from ..state import Tch

log = logging.getLogger("pont")


class TchDsp(Tch):
    def arm(self, tn, tsc, arfcn):
        with self.lock:
            self.seq += 1
            self.tn = tn
            self.tsc = tsc
            self.open = False
            self._write_cfg(tn, tsc, arfcn, self.seq)
        log.info("ASSIGNMENT COMMAND : TCH TN=%d TSC=%d ARFCN=%d annonce au DSP, "
                 "bascule du BSP a la premiere tache TCH du firmware", tn, tsc, arfcn)

    def abandon(self, reason):
        """The mobile stayed (or came back) on the SDCCH: withdraw the announcement.

        seq+1 with tn=0: c54x_exe gives the SDCCH back to the BSP WITHOUT
        dropping the Kc (the SDCCH still lives, the BTS still ciphers it).
        seq=0 remains the complete release (Tch.close)."""
        with self.lock:
            if self.tn is None:
                return
            tn = self.tn
            self.seq += 1
            self.tn = None
            self.open = False
            self.open_since = None
            self.release_seen = None
            self._write_cfg(0, 0, 0, self.seq)
        log.info("TCH TN=%d abandonne (%s) : retour sur le SDCCH", tn, reason)
        for cb in self.on_close:
            cb()
