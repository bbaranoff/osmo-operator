import gc
import logging
import signal
import sys
import threading
import time

from . import config as _config
from .cipher import Cipher
from .downlink import Downlink, Feeder
from .gsm import load_timeslots, plan_for
from .record import Recorder
from .state import Dedicated, Tch
from .stats import Reporter, Stats
from .trx import Clock, Transmitter, Trx
from .uplink import TchScheduler, Uplink

log = logging.getLogger("pont")


def _guarded(name, fn):
    def run():
        while True:
            try:
                fn()
                log.warning("thread %s termine", name)
                return
            except Exception:
                log.exception("thread %s : exception, relance dans 1 s", name)
                time.sleep(1)
    return threading.Thread(target=run, name=name, daemon=True)


def main(argv=None):
    cfg = _config.parse(argv)
    logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                        format="%(asctime)s [pont] %(message)s", datefmt="%H:%M:%S")
    gc.disable()
    gc.freeze()

    stats = Stats()
    clock = Clock()
    cipher = Cipher(cfg.kc_retention, stats)
    dedicated = Dedicated()
    tch = Tch(stats)
    record = Recorder(cfg, clock) if cfg.record else None
    trx = Trx(cfg, clock, stats, cipher, record)
    transmitter = Transmitter(cfg, clock, trx, stats)
    feeder = Feeder(cfg, stats)
    timeslots = load_timeslots(cfg.bsc_cfg)
    downlink = Downlink(cfg, stats, cipher, dedicated, tch, feeder, record, timeslots)
    uplink = Uplink(cfg, clock, stats, dedicated, tch, transmitter, feeder, cipher)
    scheduler = TchScheduler(cfg, clock, stats, tch, uplink, transmitter)

    log.info("pont TRX : ports %d/%d/%d, ARFCN %d, BSIC %d, avance UL %d trames",
             cfg.trx_base, cfg.trx_base + 1, cfg.trx_base + 2, cfg.arfcn, cfg.bsic, cfg.ul_fn_advance)
    for tn in sorted(timeslots):
        plan = plan_for(timeslots[tn])
        log.info("TS%d %-12s %s", tn, timeslots[tn], ("plan %s, %d sous-voies" % (plan.name, plan.n_sub)) if plan else "")
    log.info("QEMU : GSMTAP udp/%d, SCH udp/%d ; tap GSMTAP %s", cfg.gsmtap_port, cfg.sch_port,
             ("udp/%d" % cfg.tap_port) if cfg.tap else "coupe")

    threads = [
        _guarded("ctrl", trx.run_ctrl),
        _guarded("clock", trx.run_clock),
        _guarded("data", lambda: trx.run_data(downlink.dispatch)),
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
