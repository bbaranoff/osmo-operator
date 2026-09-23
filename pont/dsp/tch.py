# pont/dsp/tch.py - le TCH vu du pont DSP : une ANNONCE, pas une bascule.
#
# [2026-09-23] En montage DSP, /dev/shm/calypso_tch_cfg est lu par c54x_exe
# (src/montant.c, scruter_tch). Jusqu'ici il y armait le BSP sur le TCH des
# que le pont decodait l'ASSIGNMENT COMMAND, a l'heure de la BTS, alors que le
# BSP joue les trames a l'heure du DSP, 12 a ~200 trames plus tard. Le BSP
# remplacait alors toutes les trames pas encore jouees -- l'ASSIGNMENT COMMAND
# comprise, et TS0 avec -- par des bursts du TS du TCH. Run de 12:22, appels 2
# et 3 : le mobile n'a jamais recu l'ASSIGNMENT COMMAND, 80-100 bit errors,
# LOS. Desormais c54x_exe ne bascule qu'a la premiere tache TCH posee par le
# firmware (montant.c, suivre_tache_tch) ; l'ecriture faite ici n'est plus
# qu'une annonce (intervalle, TSC).
#
# Meme fichier, meme format, meme moment d'ecriture que Tch.arm : la L1 grgsm
# (calypso_l1_grgsm.c poll_tch_cfg) n'est pas concernee, pont.py n'utilise pas
# cette classe. Le seul cas nouveau, seq non nul avec tn=0, est l'abandon.
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
        """Le mobile est reste (ou revenu) sur le SDCCH : retirer l'annonce.

        seq+1 avec tn=0 : c54x_exe rend le SDCCH au BSP SANS lacher le Kc (le
        SDCCH vit encore, la BTS le chiffre toujours). seq=0 reste la
        liberation complete (Tch.close)."""
        with self.lock:
            if self.tn is None:
                return
            tn = self.tn
            self.seq += 1
            self.tn = None
            self.open = False
            self.release_seen = None
            self._write_cfg(0, 0, 0, self.seq)
        log.info("TCH TN=%d abandonne (%s) : retour sur le SDCCH", tn, reason)
        for cb in self.on_close:
            cb()
