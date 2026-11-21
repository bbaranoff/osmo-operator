# pont/dsp/trx.py - the Trx of the DSP bridge.
#
# The copy of every burst to the C54x BSP (UDP dsp_port, 8-byte header + 148
# bits 0/1) lives in Trx.run_data: pont.dsp.main refuses to start without
# --dsp-port, so that path is always taken here.
import os

from ..trx import Trx


class TrxDsp(Trx):
    # THE DSP DECIPHERS BY ITSELF. The mask-ROM programs the Calypso A5
    # coprocessor (XIO ports 0x2800..0x2818, see l1-dsp/calypso_a5.c) with
    # a_kc and a_a5fn, and applies the keystream to the demodulated burst.
    # Deciphering here as well would apply the keystream twice (= hand the
    # ciphered burst back to the decoder). The BSP therefore receives the
    # downlink as the BTS sent it. PONT_DSP_DECHIFFRE=1 deciphers here (core
    # without A5 model, or c54x_exe started with CALYPSO_A5=0).
    dechiffre_dl = os.environ.get("PONT_DSP_DECHIFFRE", "0") == "1"

    def _burst_dedie(self, tn, fn):
        """THE TCH IS DECIPHERED FROM THE ANNOUNCEMENT ON.

        Trx._burst_dedie only counts the TCH timeslot as dedicated once
        Tch.prove() has passed, that is after a first uplink frame of the
        mobile on the TCH. But osmo-bts ciphers the TCH in both directions
        from the channel activation on (osmo-bts-trx l1_if.c:479-483): between
        the firmware switch and prove(), the BSP would play ciphered bursts,
        and the first blocks of the BTS -- the UA answering the SABM of the
        ASSIGNMENT -- would be lost on the ROM side. Deciphering stays guarded
        by cipher.dl_active (Trx.run_data), confirmed on the SDCCH of the SAME
        session and reset at the IMMEDIATE ASSIGNMENT: a Kc kept from a
        previous session never touches a TCH in clear."""
        if self.tch is not None and tn == self.tch.active_tn():
            return True
        return super()._burst_dedie(tn, fn)
