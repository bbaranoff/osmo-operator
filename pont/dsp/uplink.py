# pont/dsp/uplink.py - le montant du pont DSP.
#
# Les bandes laterales sont celles de c54x_exe (src/montant.c), memes chemins
# et meme format qu'en grgsm. Deux regles changent, parce qu'en DSP on sait
# d'ou vient chaque bloc et que la liberation se lit a l'heure du DSP.
import collections
import logging
import os
import struct
import time

from .. import gsm
from ..uplink import POLL, RELEASE_FALLBACK, Uplink

log = logging.getLogger("pont")

RR_ASSIGNMENT_FAILURE = 0x2f

# [2026-10-03] Bursts xCCH montants emis par la ROM DSP, publies par c54x_exe (src/pont.c,
# tx_rom_publier) : la ROM copie chaque burst du tampon entrelace 0x4280 vers data[0x3f8a] a sa
# trame d'emission. Anneau : en-tete w(u32, nombre ecrit) n(u32, cases) ; case de 1024 octets :
# seq(u32) fn_burst0(u32) l2(23) .(1), 4 x 116 ubits (57 donnees, hl, hu, 57 donnees), puis 4 x 116
# ubits du flux de cle A5 montant que la ROM XORe sur la rafale en mode chiffre (data[0x3f9b],
# calypso_a5.c). La ROM chiffre a l'heure du DSP (12 a ~200 trames apres la BTS) : on defait son XOR et
# le pont rechiffre au fn de l'air (Cipher.apply), comme pour un bloc code par l'hote.
SB_XCCH_UL_ROM = "/dev/shm/calypso_xcch_ul_rom"
ROM_SLOT = 1024
# Les bursts de la ROM sortent 1 a ~5 trames apres la publication du L2 par montant.c (codage
# puis une trame par burst). Au-dela, le bloc part code par l'hote. PONT_UL_ROM=0 : toujours l'hote.
ROM_ATTENTE = float(os.environ.get("PONT_UL_ROM_ATTENTE", "0.12"))

# [2026-10-04] LE TUYAU UNIQUE : LES BURSTS MONTANTS FINAUX DE LA ROM, TELS QUELS, A SON NUMERO DE TRAME.
#
# c54x_exe (src/tsp_tx.c, pont.c tx_tsp_publier) publie dans calypso_tx_rom chaque burst que la ROM
# a fini de construire dans son script TSP pour l'ABB : sequence d'apprentissage, queues, inversion
# I/Q et chiffrement A5 deja appliques par la ROM, 148 bits, avec le numero de trame que l'ARM lui a
# donne pour ce burst (= celui du chiffrement : dsp_tester tx-sdcch-a5, 24/24). Avec PONT_UL_RAW=1 le
# pont les envoie a la BTS tels quels, a ce fn, sans codage ni A5 cote hote : RACH sur TS0, bursts
# normaux sur le TN du canal dedie (TCH si ouvert, sinon le SDCCH annonce). La BTS accepte un burst
# montant quel que soit son retard (osmo-bts trx_sched_ul_burst ne rejette pas sur le fn) ; le
# chemin hote classique continue de tourner pour les journaux, les stats et l'etat (GSMTAP), mais
# ses bursts vont dans un puits (Transmitter remplace par TransmitterPuits). PONT_UL_RAW_DECAL=<n>
# ajoute n trames au fn de la ROM (0 par defaut : la ROM chiffre a ce fn, la BTS dechiffre a ce fn).
SB_TX_ROM = "/dev/shm/calypso_tx_rom"
TX_ROM_SLOT = 160
UL_RAW = os.environ.get("PONT_UL_RAW", "0") == "1"
UL_RAW_DECAL = int(os.environ.get("PONT_UL_RAW_DECAL", "0"))
# [2026-10-04 soir] LE TCH RESTE A L'HOTE. Avec montant.c qui laisse B_BLUD a la ROM, la ROM emet bien
# le SABM FACCH et la SACCH/T sur le TS2 (appel de 19:18 : SABM recu par la BTS, connect ack), mais
# AUCUN burst de parole (rejeu : 1290 trames a_du consommees, zero burst hl=hu=0 ; le serialiseur
# `cc 0x8900,tc` de 0x8726 n'est jamais appele pour la parole). Envoyer le TCH de la ROM, c'est donc
# couper la voix montante ; melanger bursts ROM et hote sur le meme TCH casse la FACCH (osmo-bts
# decode au bid 3 de chaque burst recu et decale son tampon a chaque bid 0). Tant que la ROM n'emet
# pas la parole : RACH et SDCCH/SACCH par la ROM, le TCH entier (FACCH, SACCH/T, parole) par l'hote.
# PONT_UL_RAW_TCH=1 : tout par la ROM (voix montante coupee).
UL_RAW_TCH = os.environ.get("PONT_UL_RAW_TCH", "0") == "1"


class RomTxRing:
    """Lecteur de calypso_tx_rom : (seq, fn, type, tsc, bits[148]) dans l'ordre d'ecriture."""
    def __init__(self):
        self.fd = None
        self.seq = 0            # dernier seq consomme

    def nouveaux(self):
        try:
            if self.fd is None:
                self.fd = os.open(SB_TX_ROM, os.O_RDONLY)
            hdr = os.pread(self.fd, 8, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return []
        if len(hdr) < 8:
            return []
        w, n = struct.unpack("<II", hdr)
        if w <= self.seq:
            return []
        debut = max(self.seq + 1, w - n + 1)
        out = []
        for seq in range(debut, w + 1):
            case = os.pread(self.fd, TX_ROM_SLOT, 8 + ((seq - 1) % n) * TX_ROM_SLOT)
            if len(case) < TX_ROM_SLOT or struct.unpack_from("<I", case, 0)[0] != seq:
                continue
            fn, typ, tsc = struct.unpack_from("<IBB", case, 4)
            out.append((seq, fn, typ, tsc, bytes(case[12:12 + 148])))
        self.seq = w
        return out


class TransmitterPuits:
    """Puits pour les bursts codes par l'hote quand PONT_UL_RAW=1 : rien ne part, sauf ceux du TCH
    (PONT_UL_RAW_TCH=0, voir UL_RAW_TCH), qui vont au vrai Transmitter."""
    def __init__(self, stats, vrai=None, tch=None):
        self.stats = stats
        self.vrai = vrai
        self.tch = tch
        self.n = 0

    def schedule(self, tn, fn_air, burst, cipher, essais=0):
        if not UL_RAW_TCH and self.vrai is not None and self.tch is not None and tn == self.tch.active_tn():
            return self.vrai.schedule(tn, fn_air, burst, cipher, essais)
        self.n += 1



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

    def run(self):
        """[2026-10-04] PONT_UL_RAW=1 : voir RomTxRing. Les _poll_* continuent (journaux, stats, etat),
        leurs bursts vont au puits ; ceux de la ROM partent par self.tx_rom.trx.send_ul, TOUT DE SUITE :
        leur fn est definitif (c'est celui du chiffrement de la ROM), la BTS les range par fn quel que
        soit leur retard (osmo-bts trx_sched_ul_burst), et la fenetre du Transmitter (PONT_UL_RETARD_MAX,
        26 trames) en jetait une partie des que l'avance BTS depassait ~23 trames (run de 17:36 : tard=702
        sur 2000). Le canal dedie est relu de force (refresh) quand un burst normal arrive sans TN connu
        -- le cache de 100 ms faisait perdre les premiers bursts du SDCCH, donc le SABM -- et les bursts
        attendent jusqu'a 0,3 s que le TN soit connu."""
        if not UL_RAW:
            return Uplink.run(self)
        ring = RomTxRing()
        n = {0: 0, 1: 0, 2: 0}
        attente = collections.deque()
        perdus = 0
        log.info("PONT_UL_RAW=1 : bursts montants = ceux de la ROM (%s), emis a son fn%s, sans codage ni A5 cote hote",
                 SB_TX_ROM, (" %+d" % UL_RAW_DECAL) if UL_RAW_DECAL else "")

        def tn_dedie():
            # [2026-10-04, run de 18:19] Le TN est celui ou le FIRMWARE est, d'apres le tap QEMU
            # (calypso_dcch_cfg) : des l'ASSIGNMENT COMMAND il passe sur le TCH et y envoie le SABM
            # FACCH, l'ASSIGNMENT COMPLETE, la parole ; plan() garde le SDCCH « pour un retour » et
            # tch.is_open() n'est vrai qu'apres la preuve cote pont -- les premiers bursts du TCH
            # partaient donc sur le TS du SDCCH et l'assignation echouait (ASSIGNMENT FAILURE cause 1).
            tchf = self.dedicated.tch()
            if tchf is None:
                self.dedicated.refresh()
                tchf = self.dedicated.tch()
            if tchf is not None:
                return tchf[2]
            if self.tch.is_open() and self.tch.active_tn() is not None:
                return self.tch.active_tn()
            ded = self.dedicated.plan()
            if ded is None:
                self.dedicated.refresh()
                ded = self.dedicated.plan()
            return ded[2] if ded else None

        tch_dit = set()
        tch_rom = [0]

        def envoyer(seq, fn, typ, tsc, bits, tn):
            if typ != 1 and not UL_RAW_TCH and tn == self.tch.active_tn():
                tch_rom[0] += 1          # voir UL_RAW_TCH : le TCH est code et emis par l'hote
                if tch_rom[0] == 1:
                    log.info("bursts ROM du TCH TS%d non emis : FACCH, SACCH/T et parole restent codes par l'hote "
                             "(PONT_UL_RAW_TCH=0), la ROM n'emet pas encore la parole montante", tn)
                return
            self.tx_rom.trx.send_ul(tn, (fn + UL_RAW_DECAL) % gsm.HYPERFRAME, list(bits), False)
            if typ != 1 and self.dedicated.tch() is not None and tn not in tch_dit:
                tch_dit.add(tn)
                log.info("bursts ROM sur le TCH TS%d : parole, FACCH et SACCH montants codes et chiffres par la ROM", tn)
            k = typ if typ in n else 0
            n[k] += 1
            total = n[0] + n[1] + n[2]
            if total <= 5 or (typ == 1 and n[1] <= 5) or total % 1000 == 0:
                log.info("burst ROM #%d %s fn=%u TS%d%s (RACH %d, NB %d, ? %d, attendus %d, perdus %d)", seq,
                         "RACH" if typ == 1 else "NB" if typ == 2 else "?", fn, tn,
                         (" TSC%d" % tsc) if typ == 2 else "", n[1], n[2], n[0], len(attente), perdus)

        while True:
            self._poll_release()
            self._poll_rach()
            self._poll_sdcch()
            self._poll_facch()
            self._poll_sacch()
            self._poll_voice()
            if attente:
                tn = tn_dedie()
                now = time.monotonic()
                while attente:
                    seq, fn, typ, tsc, bits, t0 = attente[0]
                    if tn is not None:
                        attente.popleft()
                        envoyer(seq, fn, typ, tsc, bits, tn)
                    elif now - t0 > 0.3:
                        attente.popleft()
                        perdus += 1
                        if perdus <= 5:
                            log.info("burst ROM #%d fn=%u (TSC %d) : aucun canal dedie connu apres 300 ms, perdu", seq, fn, tsc)
                    else:
                        break
            for seq, fn, typ, tsc, bits in ring.nouveaux():
                if typ == 1:
                    envoyer(seq, fn, typ, tsc, bits, 0)
                    continue
                tn = tn_dedie()
                if tn is None:
                    attente.append((seq, fn, typ, tsc, bits, time.monotonic()))
                    continue
                envoyer(seq, fn, typ, tsc, bits, tn)
            time.sleep(POLL)
