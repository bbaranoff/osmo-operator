# pont/dsp/downlink.py - the downlink of the DSP bridge, without the grgsm outputs.
#
# In the DSP setup, QEMU runs with CALYPSO_DSP_EXTERN=1: its gr-gsm layer 1 is
# disabled, and it is the only listener of the GSMTAP udp/4730, the SCH
# udp/4731 and the speech ring /dev/shm/calypso_tch_dl (calypso_l1_grgsm.c:34).
# The DSP receives the raw bursts instead (Trx.run_data -> udp/6702). The
# Wireshark tap (udp/4729) is kept; the bridge's local decoding (statistics,
# ciphering confirmation, ASSIGNMENT COMMAND, CHANNEL RELEASE) is the same.
from ..downlink import Downlink, Feeder


class FeederDsp(Feeder):
    def l2(self, fn, chan, l2, tn=0, uplink=False, to_qemu=True):
        super().l2(fn, chan, l2, tn, uplink, to_qemu=False)

    def sch(self, fn):
        pass


class _NullRing:
    def publish(self, fr33, fn):
        pass


class DownlinkDsp(Downlink):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.ring = _NullRing()
