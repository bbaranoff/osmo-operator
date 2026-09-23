# pont/dsp/trx.py - le Trx du pont DSP.
#
# La copie de chaque burst vers le BSP du C54x (UDP dsp_port, 8 octets
# d'en-tete + 148 bits 0/1) reste dans Trx.run_data : pont.dsp.main refuse de
# demarrer sans --dsp-port, donc ce chemin y est toujours pris.
from ..trx import Trx


class TrxDsp(Trx):
    def _burst_dedie(self, tn, fn):
        """[2026-09-23] LE TCH EST DECHIFFRE DES L'ANNONCE.

        Trx._burst_dedie ne comptait l'intervalle du TCH comme dedie qu'une
        fois Tch.prove() passe, c'est-a-dire apres une premiere trame montante
        du mobile sur le TCH. Or osmo-bts chiffre le TCH dans les deux sens
        des l'activation du canal (osmo-bts-trx l1_if.c:479-483) : entre la
        bascule du firmware et prove(), le BSP jouait des bursts TS2 chiffres,
        et les premiers blocs de la BTS -- l'UA qui repond au SABM de
        l'ASSIGNMENT -- etaient perdus cote ROM (appel 1 du run de 12:22).
        Le dechiffrement reste garde par cipher.dl_active (Trx.run_data),
        confirme sur le SDCCH de la MEME session et remis a zero a l'IMMEDIATE
        ASSIGNMENT : un Kc retenu d'une session precedente ne touche jamais un
        TCH en clair."""
        if self.tch is not None and tn == self.tch.active_tn():
            return True
        return super()._burst_dedie(tn, fn)
