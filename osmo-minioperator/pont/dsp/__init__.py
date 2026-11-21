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
        sys.exit("pont DSP: --dsp-port (or PONT_DSP_PORT) is required, 6702 for c54x_exe; "
                 "for the grgsm setup, run pont/pont.py")
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
    if os.environ.get("PONT_UL_RAW", "0") == "1":
        # single pipe: the ROM bursts leave through `transmitter`, the ones the host still
        # codes (RACH, SDCCH, FACCH, SACCH, speech) go to the sink. See dsp/uplink.py RomTxRing.
        from .uplink import TransmitterPuits
        uplink.tx_rom = transmitter
        uplink.tx = TransmitterPuits(stats, transmitter, tch)   # the TCH goes to the real Transmitter (UL_RAW_TCH)
        scheduler.tx = uplink.tx
        log.info("PONT_UL_RAW=1: uplink = final ROM bursts (calypso_tx_rom); host coding and A5 inactive")

    log.info("pont TRX : ports %d/%d/%d, ARFCN %d, BSIC %d, UL advance %d frames",
             cfg.trx_base, cfg.trx_base + 1, cfg.trx_base + 2, cfg.arfcn, cfg.bsic, cfg.ul_fn_advance)
    log.info("pont DSP: bursts to the BSP udp/%d, TCH switch follows the firmware (montant.c), "
             "max UL delay %d frames, Kc retention %s",
             cfg.dsp_port, cfg.ul_retard_max, "yes" if cfg.kc_retention else "no")
    for tn in sorted(timeslots):
        plan = plan_for(timeslots[tn])
        log.info("TS%d %-12s %s", tn, timeslots[tn], ("plan %s, %d subchannels" % (plan.name, plan.n_sub)) if plan else "")
    log.info("QEMU: no GSMTAP 4730/4731 (gr-gsm layer 1 disabled); GSMTAP tap %s",
             ("udp/%d" % cfg.tap_port) if cfg.tap else "off")

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
