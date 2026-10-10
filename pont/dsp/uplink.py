# pont/dsp/uplink.py - le montant du pont DSP.
#
# Les bandes laterales sont celles de c54x_exe (src/montant.c), memes chemins
# et meme format qu'en grgsm. Deux regles changent, parce qu'en DSP on sait
# d'ou vient chaque bloc et que la liberation se lit a l'heure du DSP.
import logging

from .. import gsm
from ..uplink import RELEASE_FALLBACK, Uplink

log = logging.getLogger("pont")

RR_ASSIGNMENT_FAILURE = 0x2f


class UplinkDsp(Uplink):
    def _route_sdcch(self, l2):
        """[2026-09-23] UN BLOC DE calypso_sdcch_ul N'EST JAMAIS UNE FACCH.

        En DSP, montant.c ne publie sur cette voie que les blocs des taches
        SDCCH (DUL/AUL, capture_sdcch_ul) ; ceux du TCH passent par
        calypso_tch_facch_ul (capture_tch_ul, TCHT). Uplink._route_sdcch les
        envoyait en FACCH des que tch.is_open() : l'ASSIGNMENT FAILURE de
        l'appel 1 du run de 12:22, emise sur TS1, partait donc sur TS2 et la
        BTS ne l'a jamais vue en SDCCH.
        Un tel bloc prouve au contraire que le mobile est sur le SDCCH : si un
        TCH est annonce et que c'est une ASSIGNMENT FAILURE, ou que le mobile
        etait deja passe sur le TCH, l'annonce est retiree (TchDsp.abandon ;
        c54x_exe rend TS1 au BSP s'il ne l'a pas deja fait sur la tache du
        firmware). Le bloc part toujours en SDCCH/SACCH."""
        if self.tch.active_tn() is not None:
            if gsm.rr_message_type(l2)[1] == RR_ASSIGNMENT_FAILURE:
                self.tch.abandon("ASSIGNMENT FAILURE sur le SDCCH")
            elif self.tch.is_open():
                self.tch.abandon("bloc montant du mobile sur le SDCCH")
        return False

    def _poll_release(self):
        """[2026-09-23] LE Kc N'EST PLUS LACHE A LA LIBERATION.

        La liberation se lit dans calypso_dcch_cfg, publiee quand le firmware
        relit la BCCH : a l'heure du DSP, en retard sur la BTS, qui chiffre
        encore le SDCCH. Uplink._poll_release lachait le Kc (et dl_active) a
        cet instant ; run de 12:22, apres la 4e session : blocs TS1/8
        80/1793 et TS1/40 40/897 en echec cote pont jusqu'a 12:34. Le Kc et
        dl_active tombent desormais a l'IMMEDIATE ASSIGNMENT suivante, decodee
        a l'heure de la BTS (Downlink._signalling), ou avec un nouveau Kc."""
        active = self.dedicated.plan() is not None
        if self.ded_active and not active:
            reason = "canal libere par le mobile"
        elif self.tch.release_overdue(RELEASE_FALLBACK):
            reason = "CHANNEL RELEASE sans liberation du mobile depuis %ds" % RELEASE_FALLBACK
        else:
            self.ded_active = active
            return
        self.ded_active = active
        self.tch.close(reason)
        log.info("%s : Kc garde jusqu'a la prochaine IMMEDIATE ASSIGNMENT (la BTS chiffre encore)", reason)
