# pont/dsp/downlink.py - le descendant du pont DSP, sans les sorties grgsm.
#
# [2026-09-23] En montage DSP, QEMU tourne sous CALYPSO_DSP_EXTERN=1 : la
# couche 1 gr-gsm y est desactivee, et c'est la seule a ecouter le GSMTAP
# udp/4730, le SCH udp/4731 et l'anneau de parole /dev/shm/calypso_tch_dl
# (calypso_l1_grgsm.c:34). Le DSP recoit, lui, les bursts bruts (Trx.run_data
# -> udp/6702). On garde le tap Wireshark (udp/4729) ; le decodage local du
# pont (statistiques, confirmation du chiffrement, ASSIGNMENT COMMAND, CHANNEL
# RELEASE) est inchange.
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
