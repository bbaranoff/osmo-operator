# pont/dsp/clock.py - l'horloge du pont DSP : l'avance suit la BTS.
#
# [2026-09-23] L'AVANCE DE LA BTS EST REPORTEE EN DYNAMIQUE SUR LE DSP.
#
# Clock (pont/trx.py) asservit l'horloge du banc a « trame reclamee par le DSP
# + PONT_HORLOGE_AVANCE (12) ». C'est la BTS qui emet, elle, et ses bursts
# descendants partent `osmotrx fn-advance` trames AVANT cette horloge (2 par
# defaut), plus ses a-coups : « We missed 6 timers », « 5 FN slower than
# TRX », puis rattrapage d'un bloc. La marge vraiment utile au BSP -- derniere
# trame recue de la BTS moins trame que le DSP reclame -- valait donc
# 12 + fn-advance - gigue, et tombait sous zero : run de 13:41, 1000 trames
# sans burst (« le DSP COURT DEVANT le BTS », ecarts +1 a +6), chacune jouee en
# effacement. Tombee sur un UA ou une FACCH, c'est un bloc perdu : « I frame
# ignored in state SABM_SENT » (l'UA manque, les I suivantes arrivent),
# T200 sur la FACCH de l'assignation.
#
# ClockDsp mesure a chaque regulation l'avance reelle de la BTS sur l'horloge
# (derniere trame descendante recue - trame de l'horloge), en garde le MINIMUM
# sur une fenetre glissante (les calages de la BTS sont des creux), et pose
#     avance = PONT_MARGE_DL - avance_BTS_min
# pour que « derniere trame recue - trame reclamee » reste >= PONT_MARGE_DL.
# Changer `osmotrx fn-advance` a chaud sur la BTS est suivi sans rien relancer.
# L'avance est bornee [PONT_AVANCE_MIN, PONT_AVANCE_MAX] : au-dela, le montant
# part d'autant plus en retard (Transmitter, PONT_UL_RETARD_MAX).
# PONT_MARGE_DL=0 revient a l'avance fixe de Clock.
# Defaut 16 : 8 a d'abord ete essaye (run de 13:48) et a DOUBLE les trames sans
# burst (6 % contre 1,6 % avec l'avance fixe 12 + fn-advance 2, soit ~14) --
# l'echantillonnage toutes les 50 ms ne voit pas les pires creux de la BTS.
#
# [2026-09-23 19:06] L'AVANCE BTS SE MESURE SUR LE POINT VISE, PAS SUR L'HORLOGE.
# Mesuree contre l'horloge reelle (derniere recue - horloge), elle supposait
# horloge == DSP + avance. Faux des que le DSP attend la BTS
# (CALYPSO_BSP_ATTENTE_MS) : le DSP colle alors a la derniere trame recue,
# l'horloge traine ~15 trames derriere son but, l'« avance BTS » lue monte a
# +12 et l'avance visee tombe au plancher (4). Marge reelle min -3 moy +1.2,
# une attente de 40 ms echue sur six, trame du banc a 11,5 ms au lieu de 4,6,
# SDCCH descendant troue : UA perdu, le mobile repete son SABM (« SABM frame
# with information not allowed in this state » au BSC, « Dropping frame with
# ~96 bit errors » au mobile). On mesure donc derniere recue - (DSP + avance) :
# la marge reelle, moins l'avance deja demandee -- boucle fermee sur ce qu'on
# veut tenir. Plancher releve a 10 (l'avance fixe 12 tenait a 1,6 %).
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
        self._fn_dl = None                  # derniere trame descendante recue de la BTS
        self._mesures = collections.deque() # (instant, avance BTS sur l'horloge)
        self._avance_dite = None

    def note_dl(self, fn):
        """Appele par le fil TRXD a chaque burst descendant (sans verrou :
        une affectation d'entier)."""
        prec = self._fn_dl
        if prec is None or 0 < (fn - prec) % gsm.HYPERFRAME < gsm.HYPERFRAME // 2:
            self._fn_dl = fn

    def _reguler(self, now):
        du = now >= self._echeance
        super()._reguler(now)                   # rafraichit _dsp_prec (trame reclamee)
        dsp = self._dsp_prec
        if MARGE_DL > 0 and du and dsp is not None and self._fn_dl is not None:
            # Avance de la BTS sur le point VISE (DSP + avance), pas sur
            # l'horloge reelle -- voir l'en-tete, releve du 2026-09-23 19:06.
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
        """Marge REELLE vue par le BSP : derniere trame recue - trame reclamee
        par le DSP (calypso_horloge). Journalisee toutes les 10 s (min/moy) :
        c'est elle qui doit rester > 0, pas l'avance visee."""
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
