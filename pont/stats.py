import logging
import threading
import time

log = logging.getLogger("pont")


class Stats:
    def __init__(self):
        self.dl_bursts = 0
        self.dl_blocks = 0
        self.dl_crc_fail = 0
        self.dl_dummy = 0
        self.dl_skipped = 0
        self.ul_sent = 0
        self.ul_late = 0
        self.rach = 0
        self.tch_dl = 0
        self.tch_facch_dl = 0
        self.tch_sacch_dl = 0
        self.tch_crc = 0
        self.tch_ul = 0
        self.tch_ul_bursts = 0
        self.tch_ul_dropped = 0
        self.facch_ul = 0
        self.sacch_ul = 0
        self.a5_dl = 0
        self.a5_ul = 0
        # uplink xCCH blocks (SDCCH/SACCH of the SDCCH): bursts from the DSP ROM
        # (0x3f8a, pont/dsp/uplink.py) or coded by the host (gsm.xcch_encode); rom_ko = ROM
        # bursts present but which do not decode back to this L2.
        self.xcch_ul_rom = 0
        self.xcch_ul_hote = 0
        self.xcch_ul_rom_ko = 0
        # WHAT REALLY GOES TO THE ANTENNA, per path (PONT_UL_RAW=1).
        # The rach/xcch_ul_hote/a5_ul counters above also count the "ghost" host
        # path that ends in TransmitterPuits. air_* = bursts handed to the TRX.
        self.air_rom_rach = 0
        self.air_rom_xcch = 0      # ROM NBs outside TCH and PDCH (SDCCH/SACCH, ciphered by the ROM)
        self.air_rom_pdch = 0
        self.air_rom_tch = 0
        self.air_hote_tch = 0      # TCH coded by the host (PONT_UL_RAW_TCH=0)
        self.air_puits = 0         # host bursts dropped (never sent)
        # uplink TCH per sub-channel (dsp/uplink.py classe_tch): F FACCH, S SACCH/T, P speech.
        # rom = ROM bursts sent, rom_jete = ROM TCH bursts discarded (PONT_UL_RAW_TCH=0),
        # hote = bursts coded by the host and sent.
        self.tch_ul_rom = {"F": 0, "S": 0, "P": 0}
        self.tch_ul_rom_jete = {"F": 0, "S": 0, "P": 0}
        self.tch_ul_hote = {"F": 0, "S": 0, "P": 0}
        # uplink A5: rom = NB bursts marked ciphered by the coprocessor (calypso_a5.c),
        # hote_tch = TCH bursts ciphered by the bridge (cipher.py).
        self.a5_ul_rom = 0
        self.a5_ul_hote_tch = 0
        # ROM bursts of unknown type (sent), PDTCH blocks seen on the host SDCCH path
        # and dropped, xCCH blocks without ROM bursts in time and not recoded,
        # fn lateness ROM -> BTS clock of the TCH bursts (in frames).
        self.air_rom_inconnu = 0
        self.pdtch_ul_vu_hote = 0
        self.xcch_shadow_ko = 0
        self.tch_rom_retard_min = None
        self.tch_rom_retard_max = None
        self.sacch_t_rom_blocs = 0
        self.by_base = {}

    def block(self, tn, base, ok):
        st = self.by_base.setdefault((tn, base), [0, 0])
        st[0 if ok else 1] += 1


class Reporter(threading.Thread):
    def __init__(self, stats, clock, dedicated, record, period=5.0):
        super().__init__(name="stats", daemon=True)
        self.stats = stats
        self.clock = clock
        self.dedicated = dedicated
        self.record = record
        self.period = period

    def run(self):
        s = self.stats
        while True:
            time.sleep(self.period)
            log.info("STATS fn=%u | DL bursts=%d blocs=%d crc=%d dummy=%d hors_voie=%d | UL bursts=%d tard=%d rach=%d"
                     " | TCH dl=%d facch=%d sacch=%d crc=%d ul=%d bursts=%d perdus=%d | FACCH ul=%d SACCH ul=%d"
                     " | A5 dl=%d ul=%d | xCCH ul rom=%d hote=%d rom_ko=%d"
                     " | AIR rom rach=%d xcch=%d pdch=%d tch=%d | AIR hote tch=%d puits=%d"
                     " | TCH ul rom F=%d S=%d P=%d jete F=%d S=%d P=%d hote F=%d S=%d P=%d"
                     " | A5 ul rom=%d hote_tch=%d"
                     " | B inconnu=%d pdtch_hote_jete=%d xcch_ombre_ko=%d | TCH rom retard=%s..%s sacch_t_blocs=%d%s",
                     self.clock.fn(), s.dl_bursts, s.dl_blocks, s.dl_crc_fail, s.dl_dummy, s.dl_skipped,
                     s.ul_sent, s.ul_late, s.rach, s.tch_dl, s.tch_facch_dl, s.tch_sacch_dl, s.tch_crc,
                     s.tch_ul, s.tch_ul_bursts, s.tch_ul_dropped, s.facch_ul, s.sacch_ul, s.a5_dl, s.a5_ul,
                     s.xcch_ul_rom, s.xcch_ul_hote, s.xcch_ul_rom_ko,
                     s.air_rom_rach, s.air_rom_xcch, s.air_rom_pdch, s.air_rom_tch, s.air_hote_tch, s.air_puits,
                     s.tch_ul_rom["F"], s.tch_ul_rom["S"], s.tch_ul_rom["P"],
                     s.tch_ul_rom_jete["F"], s.tch_ul_rom_jete["S"], s.tch_ul_rom_jete["P"],
                     s.tch_ul_hote["F"], s.tch_ul_hote["S"], s.tch_ul_hote["P"],
                     s.a5_ul_rom, s.a5_ul_hote_tch,
                     s.air_rom_inconnu, s.pdtch_ul_vu_hote, s.xcch_shadow_ko,
                     "-" if s.tch_rom_retard_min is None else s.tch_rom_retard_min,
                     "-" if s.tch_rom_retard_max is None else s.tch_rom_retard_max, s.sacch_t_rom_blocs,
                     self.record.summary() if self.record else "")
            ded = self.dedicated.plan()
            if ded:
                plan, ss, tn = ded
                log.info("canal dedie : %s SS=%d TS=%d (DL fn%%51=%d, UL fn%%51=%d)",
                         plan.name, ss, tn, plan.sdcch_dl[ss % plan.n_sub], plan.ul_base(ss))
            if s.by_base:
                log.info("blocs par TS/base51 (ok/echec) : %s",
                         " ".join("TS%d/%d:%d/%d" % (k[0], k[1], v[0], v[1]) for k, v in sorted(s.by_base.items())))
