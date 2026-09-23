# pont/dsp - le pont du montage DSP (c54x_exe --arm, BSP du C54x sur udp/6702).
#
# [2026-09-23] Le paquet pont/ servait tel quel aux deux montages, et tout son
# etat dedie (TCH, chiffrement, Kc) vivait a l'heure du pont, c'est-a-dire de
# la BTS. En DSP le BSP joue les trames a l'heure du C54x, 12 a ~200 trames
# plus tard : chaque decision prise au decodage frappait des trames que le
# mobile n'avait pas encore entendues. Ce sous-paquet assemble les memes
# briques avec des sous-classes propres au DSP :
#   ClockDsp    l'avance de l'horloge suit l'avance reelle de la BTS
#               (osmotrx fn-advance et ses a-coups), mesuree en continu.
#   TchDsp      l'ASSIGNMENT COMMAND n'est qu'une annonce ; c54x_exe bascule
#               le BSP sur la tache TCH du firmware (montant.c) ; abandon()
#               rend le SDCCH apres une ASSIGNMENT FAILURE.
#   TrxDsp      l'intervalle du TCH est dechiffre des l'annonce.
#   UplinkDsp   un bloc SDCCH montant n'est jamais une FACCH ; le Kc n'est
#               plus lache a la liberation vue par le mobile.
#   FeederDsp,
#   DownlinkDsp pas de GSMTAP 4730/4731 ni d'anneau calypso_tch_dl (grgsm).
# pont/__init__.py (et donc pont.py, le montage grgsm) n'importe jamais ce
# sous-paquet.
import gc
import logging
import signal
import sys
import time

from .. import _guarded
from .. import config as _config
from ..cipher import Cipher
from ..gsm import load_timeslots, plan_for
from ..record import Recorder
from ..state import Dedicated
from ..stats import Reporter, Stats
from ..trx import Transmitter
from ..uplink import TchScheduler
from .clock import ClockDsp
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
    dedicated = Dedicated()
    tch = TchDsp(stats)
    record = Recorder(cfg, clock) if cfg.record else None
    trx = TrxDsp(cfg, clock, stats, cipher, record, dedicated, tch)
    transmitter = Transmitter(cfg, clock, trx, stats)
    feeder = FeederDsp(cfg, stats)
    timeslots = load_timeslots(cfg.bsc_cfg)
    downlink = DownlinkDsp(cfg, stats, cipher, dedicated, tch, feeder, record, timeslots)
    uplink = UplinkDsp(cfg, clock, stats, dedicated, tch, transmitter, feeder, cipher)
    scheduler = TchScheduler(cfg, clock, stats, tch, uplink, transmitter)

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
        clock.note_dl(fn)       # avance reelle de la BTS, voir dsp/clock.py
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
