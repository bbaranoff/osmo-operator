# pont/dsp/uplink.py - le montant du pont DSP.
#
# Les bandes laterales sont celles de c54x_exe (src/montant.c), memes chemins
# et meme format qu'en grgsm. Deux regles changent, parce qu'en DSP on sait
# d'ou vient chaque bloc et que la liberation se lit a l'heure du DSP.
import logging
import os
import struct
import time

from .. import gsm
from ..uplink import RELEASE_FALLBACK, Uplink

log = logging.getLogger("pont")

RR_ASSIGNMENT_FAILURE = 0x2f

# [2026-10-03] Bursts xCCH montants emis par la ROM DSP, publies par c54x_exe (src/pont.c,
# tx_rom_publier) : la ROM copie chaque burst du tampon entrelace 0x4280 vers data[0x3f8a] a sa
# trame d'emission. Anneau : en-tete w(u32, nombre ecrit) n(u32, cases) ; case de 512 octets :
# seq(u32) fn_burst0(u32) l2(23) .(1), 4 x 116 ubits (57 donnees, hl, hu, 57 donnees), puis 4 x 116
# ubits du flux de cle A5 montant que la ROM XORe sur la rafale en mode chiffre (data[0x3f9b],
# calypso_a5.c). La ROM chiffre a l'heure du DSP (12 a ~200 trames apres la BTS) : on defait son XOR et
# le pont rechiffre au fn de l'air (Cipher.apply), comme pour un bloc code par l'hote.
SB_XCCH_UL_ROM = "/dev/shm/calypso_xcch_ul_rom"
ROM_SLOT = 1024
# Les bursts de la ROM sortent 1 a ~5 trames apres la publication du L2 par montant.c (codage
# puis une trame par burst). Au-dela, le bloc part code par l'hote. PONT_UL_ROM=0 : toujours l'hote.
ROM_ATTENTE = float(os.environ.get("PONT_UL_ROM_ATTENTE", "0.12"))


class RomXcchRing:
    def __init__(self):
        self.fd = None
        self.vus = set()
        self.dechiffres = 0     # blocs que la ROM avait chiffres (XOR defait ici)

    def chercher(self, l2):
        """Les 4 bursts (116 ubits chacun) du bloc le plus recent dont les bits REDECODES donnent
        `l2` ; (None, n_ko) sinon. n_ko = blocs ROM recents qui ne redecodent pas (CRC faux)."""
        try:
            if self.fd is None:
                self.fd = os.open(SB_XCCH_UL_ROM, os.O_RDONLY)
            hdr = os.pread(self.fd, 8, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return None, 0
        if len(hdr) < 8:
            return None, 0
        w, n = struct.unpack("<II", hdr)
        ko = 0
        for seq in range(w, max(0, w - n), -1):
            case = os.pread(self.fd, ROM_SLOT, 8 + ((seq - 1) % n) * ROM_SLOT)
            if len(case) < 32 + 8 * 116 or struct.unpack_from("<I", case, 0)[0] != seq or seq in self.vus:
                continue
            bits = case[32:32 + 4 * 116]
            flux = case[32 + 4 * 116:32 + 8 * 116]
            coded = [bits[k * 116:(k + 1) * 116] for k in range(4)]
            dec = gsm.xcch_decode(coded)
            chiffre = False
            if dec is None and any(flux):
                coded = [bytes(a ^ b for a, b in zip(bits[k * 116:(k + 1) * 116], flux[k * 116:(k + 1) * 116]))
                         for k in range(4)]
                dec = gsm.xcch_decode(coded)
                chiffre = True
            if dec is None:
                ko += 1
                continue
            if bytes(dec[:gsm.MACBLOCK_LEN]) == bytes(l2[:gsm.MACBLOCK_LEN]):
                self.dechiffres += chiffre
                self.vus.add(seq)
                if len(self.vus) > 64:
                    self.vus = set(x for x in self.vus if x > w - n)
                return [gsm.burst_from_coded(c) for c in coded], ko
        return None, ko


class UplinkDsp(Uplink):
    rom = None
    rom_attente = None

    def _bursts_xcch(self, l2):
        """[2026-10-03] LES BURSTS MONTANTS SDCCH/SACCH SONT CEUX DE LA ROM.

        La ROM du DSP fait le codage canal (FIRE, convolutif, entrelacement) ; c54x_exe publie les
        bursts qu'elle emet (data[0x3f8a]) dans calypso_xcch_ul_rom. On les prend s'ils se
        redecodent en ce L2 ; tant qu'ils ne sont pas sortis (ROM_ATTENTE), le bloc attend ; au-dela,
        ou si PONT_UL_ROM=0, il est code par l'hote comme avant (compteur xCCH ul hote)."""
        if os.environ.get("PONT_UL_ROM", "1") == "0":
            return Uplink._bursts_xcch(self, l2)
        if self.rom is None:
            self.rom = RomXcchRing()
        cle = bytes(l2[:gsm.MACBLOCK_LEN])
        if self.rom_attente is None or self.rom_attente[0] != cle:
            self.rom_attente = (cle, time.monotonic())
        bursts, ko = self.rom.chercher(l2)
        if bursts is not None:
            self.rom_attente = None
            self.stats.xcch_ul_rom += 1
            if self.stats.xcch_ul_rom <= 3 or self.rom.dechiffres == 1 and not getattr(self, "_dech_dit", False):
                self._dech_dit = self.rom.dechiffres > 0
                log.info("xCCH montant : bursts de la ROM (0x3f8a) pour %s%s", cle[:6].hex(" "),
                         " (chiffres par la ROM, XOR A5 defait, rechiffres par le pont au fn de l'air)"
                         if self.rom.dechiffres else "")
            return bursts
        if time.monotonic() - self.rom_attente[1] < ROM_ATTENTE:
            return None
        self.rom_attente = None
        self.stats.xcch_ul_rom_ko += ko
        if self.stats.xcch_ul_hote < 5:
            log.info("xCCH montant : pas de bursts ROM pour %s apres %.0f ms (%d bloc(s) ROM sans CRC), code par l'hote",
                     cle[:6].hex(" "), ROM_ATTENTE * 1000, ko)
        return Uplink._bursts_xcch(self, l2)

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
