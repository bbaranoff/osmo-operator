import argparse
import os
from dataclasses import dataclass


def _env(name, default):
    return os.environ.get(name, default)


def _flag(name, default):
    return _env(name, default) not in ("0", "", "no")


@dataclass(frozen=True)
class Config:
    trx_bind: str
    trx_base: int
    arfcn: int
    bsic: int
    ul_fn_advance: int
    window_tol: int
    rssi: int
    gsmtap_port: int
    sch_port: int
    tap: bool
    tap_port: int
    bsc_cfg: str
    clock_period: int
    kc_retention: bool
    record: bool
    record_ul: bool
    record_dl_path: str
    record_ul_path: str
    record_dl_fifo: str
    record_ul_fifo: str
    record_max_mb: int
    record_min_free_mb: int
    record_osr: int


def parse(argv=None):
    p = argparse.ArgumentParser(prog="pont", description="Pont TRX entre le BTS et la couche 1 gr-gsm de QEMU")
    p.add_argument("--arfcn", type=int, default=int(_env("PONT_ARFCN", "514")))
    p.add_argument("--bsic", type=int, default=int(_env("PONT_BSIC", "7")))
    p.add_argument("--trx-bind", default=_env("PONT_TRX_BIND", "127.0.0.1"))
    p.add_argument("--trx-base", type=int, default=int(_env("PONT_TRX_BASE", "5700")))
    p.add_argument("--bsc-cfg", default=_env("PONT_BSC_CFG", "/etc/osmocom/osmo-bsc.cfg"))
    p.add_argument("--no-tap", action="store_true", default=not _flag("PONT_TAP", "1"))
    p.add_argument("--no-record", action="store_true", default=not _flag("PONT_AIRREC", "1"))
    a = p.parse_args(argv)
    return Config(
        trx_bind=a.trx_bind,
        trx_base=a.trx_base,
        arfcn=a.arfcn,
        bsic=a.bsic,
        ul_fn_advance=int(_env("PONT_UL_FN_ADVANCE", "3")),
        window_tol=int(_env("PONT_WINDOW_TOL", "1")),
        rssi=int(_env("PONT_RSSI", "60")),
        gsmtap_port=4730,
        sch_port=4731,
        tap=not a.no_tap,
        tap_port=int(_env("PONT_TAP_PORT", "4729")),
        bsc_cfg=a.bsc_cfg,
        clock_period=int(_env("PONT_CLCK_PERIOD_FN", "51")),
        kc_retention=_flag("PONT_KC_RETENTION", "1"),
        record=not a.no_record,
        record_ul=_flag("PONT_AIRREC_UL", "1"),
        record_dl_path=_env("PONT_AIRREC_DL_PATH", "/root/record.cfile"),
        record_ul_path=_env("PONT_AIRREC_UL_PATH", "/root/record_ul.cfile"),
        record_dl_fifo=_env("PONT_AIRREC_DL_FIFO", "/tmp/iq_fft.fifo"),
        record_ul_fifo=_env("PONT_AIRREC_UL_FIFO", "/tmp/iq_fft_ms.fifo"),
        record_max_mb=int(_env("PONT_AIRREC_MAX_MB", "4096")),
        record_min_free_mb=int(_env("PONT_AIRREC_MINFREE_MB", "8192")),
        record_osr=int(_env("PONT_AIRREC_OSR", "4")),
    )
