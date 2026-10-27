# pont/dsp - the bridge of the DSP setup (c54x_exe --arm, C54x BSP on udp/6702).
#
# The dedicated state of the pont/ package (TCH, ciphering, Kc) lives at the
# bridge's time, that is the BTS's. In DSP mode the BSP plays the frames at
# the C54x's time, 12 to ~200 frames later: a decision taken at decoding time
# would hit frames the mobile has not heard yet. This sub-package assembles
# the same building blocks with DSP-specific subclasses:
#   ClockDsp    the clock advance follows the real advance of the BTS
#               (osmotrx fn-advance and its jolts), measured continuously.
#   TchDsp      the ASSIGNMENT COMMAND is only an announcement; c54x_exe
#               switches the BSP on the firmware's TCH task (montant.c);
#               abandon() gives the SDCCH back after an ASSIGNMENT FAILURE.
#   TrxDsp      the TCH timeslot is deciphered from the announcement on.
#   UplinkDsp   an uplink SDCCH block is never a FACCH; the Kc is not
#               dropped at the release seen by the mobile.
#   FeederDsp,
#   DownlinkDsp no GSMTAP 4730/4731 nor calypso_tch_dl ring (grgsm).
# pont/__init__.py (and so pont.py, the grgsm setup) never imports this
# sub-package.
import gc
import logging
import os
import signal
import sys
import time

from .. import _guarded
from .. import config as _config
from ..cipher import Cipher
from ..gsm import load_timeslots, plan_for
from ..record import Recorder
from ..stats import Reporter, Stats
from ..trx import Transmitter
from ..uplink import TchScheduler
from .clock import ClockDsp
from .dedicated import DedicatedDsp
from .downlink import DownlinkDsp, FeederDsp
from .tch import TchDsp
from .trx import TrxDsp
from .uplink import UplinkDsp

log = logging.getLogger("pont")


def main(argv=None):
    cfg = _config.parse(argv)
    if not cfg.dsp_port:
        sys.exit("pont DSP : --dsp-port (ou PONT_DSP_PORT) est obligatoire, 6702 pour c54x_exe ; "
                 "pour le montage grgsm, lancer pont/pont.py")
    logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                        format="%(asctime)s [pont] %(message)s", datefmt="%H:%M:%S")
    gc.disable()
    gc.freeze()

    stats = Stats()
    clock = ClockDsp()
    cipher = Cipher(cfg.kc_retention, stats)
    dedicated = DedicatedDsp()     # TCH kinds from the tap, see dsp/dedicated.py
    tch = TchDsp(stats)
    record = Recorder(cfg, clock) if cfg.record else None
    trx = TrxDsp(cfg, clock, stats, cipher, record, dedicated, tch)
    transmitter = Transmitter(cfg, clock, trx, stats)
    feeder = FeederDsp(cfg, stats)
    timeslots = load_timeslots(cfg.bsc_cfg)
    downlink = DownlinkDsp(cfg, stats, cipher, dedicated, tch, feeder, record, timeslots)
    uplink = UplinkDsp(cfg, clock, stats, dedicated, tch, transmitter, feeder, cipher)
    scheduler = TchScheduler(cfg, clock, stats, tch, uplink, transmitter)
    if os.environ.get("PONT_VOIX_HOTE", "0") == "1":
        # the Magnetite voice by the host (libgsm), see pont/voix_hote.py
        from ..voix_hote import VoixHote
        voix = VoixHote(uplink, tch, stats)
        downlink.ring = voix
        voix.start()
    if os.environ.get("PONT_UL_RAW", "0") == "1":
        # single pipe: the ROM bursts leave through `transmitter`, the ones the host still
        # codes (RACH, SDCCH, FACCH, SACCH, speech) go to the sink. See dsp/uplink.py RomTxRing.
        from .uplink import TransmitterPuits
        uplink.tx_rom = transmitter
        uplink.tx = TransmitterPuits(stats, transmitter, tch)   # the TCH goes to the real Transmitter (UL_RAW_TCH)
        scheduler.tx = uplink.tx
        log.info("PONT_UL_RAW=1 : montant = bursts finaux de la ROM (calypso_tx_rom) ; codage et A5 hote inactifs")

    log.info("pont TRX : ports %d/%d/%d, ARFCN %d, BSIC %d, avance UL %d trames",
             cfg.trx_base, cfg.trx_base + 1, cfg.trx_base + 2, cfg.arfcn, cfg.bsic, cfg.ul_fn_advance)
    log.info("pont DSP : bursts vers le BSP udp/%d, bascule TCH suivie par le firmware (montant.c), "
             "retard UL max %d trames, retention Kc %s",
             cfg.dsp_port, cfg.ul_retard_max, "oui" if cfg.kc_retention else "non")
    for tn in sorted(timeslots):
        plan = plan_for(timeslots[tn])
        log.info("TS%d %-12s %s", tn, timeslots[tn], ("plan %s, %d sous-voies" % (plan.name, plan.n_sub)) if plan else "")
    log.info("QEMU : pas de GSMTAP 4730/4731 (couche 1 gr-gsm desactivee) ; tap GSMTAP %s",
             ("udp/%d" % cfg.tap_port) if cfg.tap else "coupe")

    def _dl(tn, fn, bits):
        clock.note_dl(fn)       # real advance of the BTS, see dsp/clock.py
        downlink.dispatch(tn, fn, bits)

    threads = [
        _guarded("ctrl", trx.run_ctrl),
        _guarded("clock", trx.run_clock),
        _guarded("data", lambda: trx.run_data(_dl)),
        transmitter, uplink, scheduler,
        Reporter(stats, clock, dedicated, record),
    ]
    if record:
        signal.signal(signal.SIGUSR1, record.split)
        threads.append(record)
    for t in threads:
        t.start()
    while True:
        time.sleep(3600)
