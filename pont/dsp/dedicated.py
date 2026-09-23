# pont/dsp/dedicated.py - calypso_dcch_cfg tel que l'ecrit le tap QEMU du
# montage DSP (qosmo hw/arm/calypso/calypso_dcch_tap.c).
#
# [2026-09-23] Le tap annonce maintenant aussi le TCH : genre 2 = TCH/F,
# 3 = TCH/H. Il ne connaissait que le SDCCH, et pendant tout un appel le
# fichier disait encore SDCCH/8 TS1. Dedicated.read (pont/state.py) ne garde
# que le bit 0 du genre : un genre 2 y deviendrait un SDCCH/4 sur le TS du TCH
# -- le montant SDCCH d'une ASSIGNMENT FAILURE serait alors planifie sur TS2.
#
# Ici le TCH est note a part et plan() continue de rendre le DERNIER SDCCH tant
# que la connexion vit : c'est exactement ce que voyaient DownlinkDsp, TrxDsp et
# UplinkDsp quand le tap ignorait le TCH (aucun changement de comportement), et
# c'est le bon canal si le mobile y revient (ASSIGNMENT FAILURE). Seul 0xFF
# (retour sur les voies communes) termine la connexion : UplinkDsp._poll_release
# ne voit donc pas l'arrivee sur le TCH comme une liberation.
# pont.py (grgsm) garde state.Dedicated : sa couche 1 n'ecrit jamais de genre 2.
import logging
import os
import struct
import time

from ..state import DCCH_CFG, DCCH_RELEASED, DCCH_TTL, Dedicated

log = logging.getLogger("pont")

DCCH_TCH_F = 2
DCCH_TCH_H = 3


class DedicatedDsp(Dedicated):
    def __init__(self):
        super().__init__()
        self._tch = None        # (genre, ss, tn) : le firmware est sur le TCH

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
        elif genre in (DCCH_TCH_F, DCCH_TCH_H):
            self._tch = (genre, ss, tn)
            if self._value is None:
                log.info("canal dedie : TCH/%s TS=%d SS=%d annonce par le firmware, aucun SDCCH connu",
                         "F" if genre == DCCH_TCH_F else "H", tn, ss)
            else:
                log.info("canal dedie : TCH/%s TS=%d SS=%d annonce par le firmware "
                         "(SDCCH SS=%d TS=%d garde pour un retour)",
                         "F" if genre == DCCH_TCH_F else "H", tn, ss, self._value[1], self._value[2])
        else:
            if self._tch is not None:
                log.info("canal dedie : le firmware a quitte le TCH TS=%d pour le SDCCH SS=%d TS=%d",
                         self._tch[2], ss, tn)
            self._tch = None
            self._value = (genre & 1, ss, tn)
        return self._value

    def tch(self):
        """(genre, ss, tn) si le firmware est sur un TCH d'apres le tap, sinon None."""
        self.read()
        return self._tch
