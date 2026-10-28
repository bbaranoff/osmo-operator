# pont/dsp/uplink.py - the uplink of the DSP bridge.
#
# The side bands are those of c54x_exe (src/montant.c), same paths and same
# format as in grgsm. Two rules differ, because in DSP mode the origin of each
# block is known and the release is read at the DSP's time.
import collections
import logging
import os
import struct
import time

from .. import gsm
from ..uplink import POLL, RELEASE_FALLBACK, Uplink

log = logging.getLogger("pont")

RR_ASSIGNMENT_FAILURE = 0x2f

# Uplink xCCH bursts emitted by the DSP ROM, published by c54x_exe (src/pont.c,
# tx_rom_publier): the ROM copies each burst from the interleaved buffer 0x4280 to data[0x3f8a]
# at its transmit frame. Ring: header w(u32, number written) n(u32, slots); 1024-byte slot:
# seq(u32) fn_burst0(u32) l2(23) .(1), 4 x 116 ubits (57 data, hl, hu, 57 data), then 4 x 116
# ubits of the uplink A5 keystream the ROM XORs onto the burst in ciphered mode (data[0x3f9b],
# calypso_a5.c). The ROM ciphers at the DSP's time (12 to ~200 frames after the BTS): its XOR is
# undone and the bridge re-ciphers at the air fn (Cipher.apply), as for a host-coded block.
SB_XCCH_UL_ROM = "/dev/shm/calypso_xcch_ul_rom"
ROM_SLOT = 1024
# The ROM's bursts come out 1 to ~5 frames after montant.c publishes the L2 (coding, then one
# frame per burst). Beyond that, the block leaves host-coded. PONT_UL_ROM=0: always the host.
ROM_ATTENTE = float(os.environ.get("PONT_UL_ROM_ATTENTE", "0.12"))

# THE SINGLE PIPE: THE ROM'S FINAL UPLINK BURSTS, AS IS, AT ITS FRAME NUMBER.
#
# c54x_exe (src/tsp_tx.c, pont.c tx_tsp_publier) publishes in calypso_tx_rom each burst the ROM
# has finished building in its TSP script for the ABB: training sequence, tails, I/Q inversion
# and A5 ciphering already applied by the ROM, 148 bits, with the frame number the ARM gave it
# for this burst (= the ciphering one: dsp_tester tx-sdcch-a5, 24/24). With PONT_UL_RAW=1 the
# bridge sends them to the BTS as is, at that fn, without host-side coding or A5: RACH on TS0,
# normal bursts on the TN of the dedicated channel (TCH if open, else the announced SDCCH). The
# BTS accepts an uplink burst whatever its lateness (osmo-bts trx_sched_ul_burst does not reject
# on fn); the classic host path keeps running for logs, stats and state (GSMTAP), but its bursts
# go to a sink (Transmitter replaced by TransmitterPuits). PONT_UL_RAW_DECAL=<n> adds n frames
# to the ROM's fn (0 by default: the ROM ciphers at this fn, the BTS deciphers at this fn).
SB_TX_ROM = "/dev/shm/calypso_tx_rom"
TX_ROM_SLOT = 160
UL_RAW = os.environ.get("PONT_UL_RAW", "0") == "1"
PDCH_FILTRE = os.environ.get("PONT_PDCH_FILTRE", "1") != "0"
# B5: uplink SACCH/T by the ROM. 0 (default) = measurement only (fn lateness,
# available ROM blocks).
UL_RAW_SACCH_T = os.environ.get("PONT_UL_RAW_SACCH_T", "0") == "1"
UL_RAW_DECAL = int(os.environ.get("PONT_UL_RAW_DECAL", "0"))
# THE TCH STAYS WITH THE HOST. With montant.c leaving B_BLUD to the ROM, the ROM does emit the
# SABM FACCH and the SACCH/T on the TCH, but NO speech burst (the `cc 0x8900,tc` serialiser of
# 0x8726 is never called for speech). Sending the ROM's TCH would therefore cut the uplink voice;
# mixing ROM and host bursts on the same TCH breaks the FACCH (osmo-bts decodes at bid 3 of each
# received burst and shifts its buffer at each bid 0). As long as the ROM does not emit speech:
# RACH and SDCCH/SACCH by the ROM, the whole TCH (FACCH, SACCH/T, speech) by the host.
# PONT_UL_RAW_TCH=1: everything by the ROM (uplink voice cut).
UL_RAW_TCH = os.environ.get("PONT_UL_RAW_TCH", "0") == "1"
# GRACE DELAY BEFORE ABANDONING THE TCH ON AN UPLINK SDCCH BLOCK (seconds).
# Right after the SABM FACCH, a block may still show up on the SDCCH path: it is the tail of
# the firmware's SDCCH task (ABORT after CAS_C), not a return to the SDCCH. Abandoning the TCH
# on it would leave the SABM uncoded in FACCH ("DL: >N200 of SABM" -> RR ASSIGNMENT FAILURE ->
# MSC "Assignment Failure, releasing call"), so during this delay such a block is ignored. A
# real return is announced by an ASSIGNMENT FAILURE, handled before and without delay.
TCH_ABANDON_GRACE = float(os.environ.get("PONT_TCH_ABANDON_GRACE", "2.0"))
# Magnetite (TI firmware): the ROM does not emit its bursts through the TSP script read by
# calypso_tx_rom, except the RACH that c54x_exe publishes there itself (tx_rach_vers_air). The SABM
# and the SACCH, captured in a_cu by montant.c (calypso_sdcch_ul), would go to the sink.
# PONT_UL_RAW_DCCH_HOTE=1: SDCCH and SACCH coded by the host and sent to the BTS, the rest of the
# ROM pipe unchanged.
UL_RAW_DCCH_HOTE = os.environ.get("PONT_UL_RAW_DCCH_HOTE", "0") == "1"
UL_TN_DEFAUT = int(os.environ["PONT_UL_TN_DEFAUT"]) if os.environ.get("PONT_UL_TN_DEFAUT", "") != "" else None


class RomTxRing:
    """Reader of calypso_tx_rom: (seq, fn, type, tsc, bits[148]) in write order."""
    def __init__(self):
        self.fd = None
        self.seq = 0            # last seq consumed

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
            fn, typ, tsc, _off, drap = struct.unpack_from("<IBBBB", case, 4)
            # flag bit 7: burst ciphered by the ROM (c54x_exe pont.c tx_tsp_publier)
            out.append((seq, fn, typ, tsc, bytes(case[12:12 + 148]), bool(drap & 0x80)))
        self.seq = w
        return out


def classe_tch(fn, burst):
    """Uplink burst of a TCH/F: 'S' SACCH/T (fn%26 = 12, or 25 depending on the TN),
    'F' FACCH (a stealing flag set: bits 60 / 87, either side of the TSC -- same place
    in the ROM's bursts), 'P' speech otherwise."""
    if fn % 26 in (12, 25):
        return "S"
    try:
        if burst[60] or burst[87]:
            return "F"
    except (IndexError, TypeError):
        pass
    return "P"


class TransmitterPuits:
    """Sink for host-coded bursts when PONT_UL_RAW=1: nothing leaves, except those of the TCH
    (PONT_UL_RAW_TCH=0, see UL_RAW_TCH), which go to the real Transmitter."""
    def __init__(self, stats, vrai=None, tch=None):
        self.stats = stats
        self.vrai = vrai
        self.tch = tch
        self.n = 0

    def schedule(self, tn, fn_air, burst, cipher, essais=0):
        if not UL_RAW_TCH and self.vrai is not None and self.tch is not None and tn == self.tch.active_tn():
            self.stats.air_hote_tch += 1
            self.stats.tch_ul_hote[classe_tch(fn_air, burst)] += 1
            if cipher:
                self.stats.a5_ul_hote_tch += 1
            return self.vrai.schedule(tn, fn_air, burst, cipher, essais)
        self.n += 1
        self.stats.air_puits += 1



class RomXcchRing:
    def __init__(self):
        self.fd = None
        self.vus = set()
        self.dechiffres = 0     # blocks the ROM had ciphered (XOR undone here)

    def chercher(self, l2):
        """The 4 bursts (116 ubits each) of the most recent block whose RE-DECODED bits give
        `l2`; (None, n_ko) otherwise. n_ko = recent ROM blocks that do not re-decode (bad CRC)."""
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
                self.n_ko = getattr(self, "n_ko", 0) + 1
                if self.n_ko <= 5:
                    log.info("xCCH ROM (0x3f8a) seq=%d : CRC faux en clair%s", seq,
                             " et apres XOR du flux A5" if any(flux) else ", aucun flux A5 joint")
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
        """THE UPLINK SDCCH/SACCH BURSTS ARE THE ROM'S.

        The DSP ROM does the channel coding (FIRE, convolutional, interleaving); c54x_exe publishes
        the bursts it emits (data[0x3f8a]) in calypso_xcch_ul_rom. They are taken if they re-decode
        to this L2; while they are not out yet (ROM_ATTENTE), the block waits; beyond that, or if
        PONT_UL_ROM=0, it is coded by the host (counter xCCH ul hote)."""
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
        if UL_RAW and not UL_RAW_DCCH_HOTE:
            # B2: under PONT_UL_RAW=1 the host copy would end in the sink, so it is not
            # coded. Empty list = _poll_sdcch keeps its effects (GSMTAP, sacch_ul, routing)
            # without scheduling anything. What goes on air is the ROM burst of calypso_tx_rom.
            self.stats.xcch_shadow_ko += 1
            if self.stats.xcch_shadow_ko <= 5:
                log.info("xCCH montant : %s sans bursts 0x3f8a apres %.0f ms (%d bloc(s) sans CRC) -- "
                         "non recode (PONT_UL_RAW=1, l'antenne a ceux de calypso_tx_rom)",
                         cle[:6].hex(" "), ROM_ATTENTE * 1000, ko)
            return []
        if self.stats.xcch_ul_hote < 5:
            log.info("xCCH montant : pas de bursts ROM pour %s apres %.0f ms (%d bloc(s) ROM sans CRC), code par l'hote",
                     cle[:6].hex(" "), ROM_ATTENTE * 1000, ko)
        return Uplink._bursts_xcch(self, l2)

    def _route_sdcch(self, l2):
        """A BLOCK FROM calypso_sdcch_ul IS NEVER A FACCH.

        In DSP mode, montant.c publishes on this path only the blocks of the
        SDCCH tasks (DUL/AUL, capture_sdcch_ul); those of the TCH go through
        calypso_tch_facch_ul (capture_tch_ul, TCHT). Uplink._route_sdcch would
        send them as FACCH as soon as tch.is_open(), on the TCH's TS.
        Such a block proves on the contrary that the mobile is on the SDCCH: if
        a TCH is announced and this is an ASSIGNMENT FAILURE, or the mobile had
        already moved to the TCH, the announcement is withdrawn (TchDsp.abandon;
        c54x_exe gives TS1 back to the BSP if it has not already done so on the
        firmware task). The block always leaves as SDCCH/SACCH.

        B1: on a PDCH, montant.c also publishes the GPRS a_cu blocks (DUL task)
        on this path. They are not SDCCH: they are dropped (counter pdtch_hote_jete).
        PONT_PDCH_FILTRE=0: keep them."""
        if PDCH_FILTRE and self.dedicated.pdch() is not None:
            self.stats.pdtch_ul_vu_hote += 1
            if self.stats.pdtch_ul_vu_hote == 1:
                log.info("voie SDCCH montante : blocs du PDCH TS%d (GPRS) jetes, la ROM les emet (PONT_PDCH_FILTRE=0 pour les garder)",
                         self.dedicated.pdch())
            return True
        if self.tch.active_tn() is not None:
            if gsm.rr_message_type(l2)[1] == RR_ASSIGNMENT_FAILURE:
                self.tch.abandon("ASSIGNMENT FAILURE sur le SDCCH")
            elif self.tch.is_open():
                age = self.tch.open_age()
                if age is not None and age < TCH_ABANDON_GRACE:
                    self._grace_vus = getattr(self, "_grace_vus", 0) + 1
                    if self._grace_vus <= 5:
                        log.info("bloc montant sur le SDCCH %.2f s apres l'ouverture du TCH : ignore (delai de grace "
                                 "%.1f s, PONT_TCH_ABANDON_GRACE) -- queue de la tache SDCCH du firmware, pas un retour",
                                 age, TCH_ABANDON_GRACE)
                    return False
                self.tch.abandon("bloc montant du mobile sur le SDCCH")
        return False

    def _poll_release(self):
        """THE Kc IS NOT DROPPED AT RELEASE.

        The release is read in calypso_dcch_cfg, published when the firmware
        goes back to the BCCH: at the DSP's time, behind the BTS, which still
        ciphers the SDCCH. Dropping the Kc (and dl_active) at that moment would
        leave the following SDCCH blocks undecodable. The Kc and dl_active fall
        at the next IMMEDIATE ASSIGNMENT, decoded at the BTS's time
        (Downlink._signalling), or with a new Kc."""
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
        """PONT_UL_RAW=1: see RomTxRing. The _poll_* keep running (logs, stats, state), their
        bursts go to the sink; the ROM's leave through self.tx_rom.trx.send_ul, IMMEDIATELY: their
        fn is final (it is the ROM's ciphering fn), the BTS files them by fn whatever their lateness
        (osmo-bts trx_sched_ul_burst), and the Transmitter window (PONT_UL_RETARD_MAX, 26 frames)
        would drop part of them once the BTS advance exceeds ~23 frames. The dedicated channel is
        force re-read (refresh) when a normal burst arrives without a known TN -- the 100 ms cache
        would lose the first SDCCH bursts, hence the SABM -- and bursts wait up to 0.3 s for the
        TN to be known."""
        if not UL_RAW:
            return Uplink.run(self)
        ring = RomTxRing()
        n = {0: 0, 1: 0, 2: 0}
        attente = collections.deque()
        perdus = 0
        log.info("PONT_UL_RAW=1 : bursts montants = ceux de la ROM (%s), emis a son fn%s, sans codage ni A5 cote hote",
                 SB_TX_ROM, (" %+d" % UL_RAW_DECAL) if UL_RAW_DECAL else "")

        def tn_dedie():
            # The TN is the one where the FIRMWARE is, according to the QEMU tap
            # (calypso_dcch_cfg): from the ASSIGNMENT COMMAND on it moves to the TCH and sends
            # there the SABM FACCH, the ASSIGNMENT COMPLETE, the speech; plan() keeps the SDCCH
            # "for a return" and tch.is_open() is only true once proven on the bridge side --
            # the first TCH bursts would otherwise leave on the SDCCH's TS.
            # PDCH (GPRS) first: the uplink PDTCH blocks coded by the ROM (DUL task of the
            # l1gprs_fw.c firmware) leave on the PDCH's TN, at their fn.
            pdch = self.dedicated.pdch()
            if pdch is not None:
                return pdch
            tchf = self.dedicated.tch()
            if tchf is None:
                self.dedicated.refresh()
                tchf = self.dedicated.tch()
                pdch = self.dedicated.pdch()
                if pdch is not None:
                    return pdch
            if tchf is not None:
                return tchf[2]
            if self.tch.is_open() and self.tch.active_tn() is not None:
                return self.tch.active_tn()
            ded = self.dedicated.plan()
            if ded is None:
                self.dedicated.refresh()
                ded = self.dedicated.plan()
            # Magnetite: no L1CTL tap, hence never a calypso_dcch_cfg. Its SDCCH bursts (TSC 7, 4
            # frames in a row, already in calypso_tx_rom with their fn) would be lost with "no known
            # dedicated channel". PONT_UL_TN_DEFAUT=<tn>: the timeslot to use without an
            # announcement (TS0, SDCCH/4).
            if ded is None and UL_TN_DEFAUT is not None:
                return UL_TN_DEFAUT
            return ded[2] if ded else None

        tch_dit = set()
        tch_rom = [0]

        def tn_tch():
            # TN of the TCH as the firmware sees it (QEMU tap), else the bridge's
            t = self.dedicated.tch()
            return t[2] if t is not None else self.tch.active_tn()

        def envoyer(seq, fn, typ, tsc, bits, tn, a5=False):
            st = self.stats
            est_tch = typ != 1 and tn is not None and tn == tn_tch()
            if est_tch:
                # B5: lateness of the ROM fn against the BTS clock (frames), and available SACCH/T
                r = (self.clock.fn() - fn) % gsm.HYPERFRAME
                if r > gsm.HYPERFRAME // 2:
                    r -= gsm.HYPERFRAME
                if st.tch_rom_retard_min is None or r < st.tch_rom_retard_min:
                    st.tch_rom_retard_min = r
                if st.tch_rom_retard_max is None or r > st.tch_rom_retard_max:
                    st.tch_rom_retard_max = r
                if classe_tch(fn, bits) == "S":
                    self._s_rom = getattr(self, "_s_rom", 0) + 1
                    st.sacch_t_rom_blocs = self._s_rom // 4
            if typ != 1 and not UL_RAW_TCH and tn == self.tch.active_tn():
                st.tch_ul_rom_jete[classe_tch(fn, bits)] += 1
                tch_rom[0] += 1          # see UL_RAW_TCH: the TCH is coded and emitted by the host
                if tch_rom[0] == 1:
                    log.info("bursts ROM du TCH TS%d non emis : FACCH, SACCH/T et parole restent codes par l'hote "
                             "(PONT_UL_RAW_TCH=0), la ROM n'emet pas encore la parole montante", tn)
                return
            self.tx_rom.trx.send_ul(tn, (fn + UL_RAW_DECAL) % gsm.HYPERFRAME, list(bits), False)
            if typ == 1:
                st.air_rom_rach += 1
                ra = gsm.rach_ra(bits, self.cfg.bsic)      # see downlink._imm_ass_dcch
                if ra is not None:
                    from ..downlink import noter_rach
                    noter_rach(ra)
                elif st.air_rom_rach <= 3:
                    log.info("RACH ROM #%d : RA illisible (BSIC %d), IMM ASS choisie sans reference", seq, self.cfg.bsic)
            elif tn == self.dedicated.pdch():
                st.air_rom_pdch += 1
            elif typ not in (1, 2):
                st.air_rom_inconnu += 1      # B4: emitted anyway (neighbour of the PDCH in GPRS)
                if st.air_rom_inconnu <= 5:
                    log.info("burst ROM #%d de type inconnu (%d) : TS%d fn=%u fn%%13=%d fn%%26=%d", seq, typ, tn,
                             fn, fn % 13, fn % 26)
            elif est_tch:
                st.air_rom_tch += 1
                st.tch_ul_rom[classe_tch(fn, bits)] += 1
            else:
                st.air_rom_xcch += 1
            if a5 and typ != 1:
                st.a5_ul_rom += 1
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
            if UL_RAW_DCCH_HOTE:
                # SDCCH and SACCH coded by the host, really sent (the RACH stays with the ROM)
                puits, self.tx = self.tx, self.tx_rom
                try:
                    self._poll_sdcch()
                    self._poll_sacch()
                finally:
                    self.tx = puits
                self._poll_facch()
            else:
                self._poll_sdcch()
                self._poll_facch()
                self._poll_sacch()
            self._poll_voice()
            if attente:
                tn = tn_dedie()
                now = time.monotonic()
                while attente:
                    seq, fn, typ, tsc, bits, a5, t0 = attente[0]
                    if tn is not None:
                        attente.popleft()
                        envoyer(seq, fn, typ, tsc, bits, tn, a5)
                    elif now - t0 > 0.3:
                        attente.popleft()
                        perdus += 1
                        if perdus <= 5:
                            log.info("burst ROM #%d fn=%u (TSC %d) : aucun canal dedie connu apres 300 ms, perdu", seq, fn, tsc)
                    else:
                        break
            for seq, fn, typ, tsc, bits, a5 in ring.nouveaux():
                if typ == 1:
                    envoyer(seq, fn, typ, tsc, bits, 0)
                    continue
                tn = tn_dedie()
                if tn is None:
                    attente.append((seq, fn, typ, tsc, bits, a5, time.monotonic()))
                    continue
                envoyer(seq, fn, typ, tsc, bits, tn, a5)
            time.sleep(POLL)
