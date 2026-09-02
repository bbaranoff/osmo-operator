import logging
import os
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

DCCH_CFG = "/dev/shm/calypso_dcch_cfg"
TCH_CFG = "/dev/shm/calypso_tch_cfg"
DCCH_TTL = 0.1
DCCH_RELEASED = 0xFF


class Dedicated:
    def __init__(self):
        self._fd = None
        self._next = 0.0
        self._value = None
        self._seq = 0

    def read(self):
        now = time.monotonic()
        if now < self._next:
            return self._value
        self._next = now + DCCH_TTL
        try:
            if self._fd is None:
                self._fd = os.open(DCCH_CFG, os.O_RDONLY)
            b = os.pread(self._fd, 16, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            return self._value
        if len(b) < 8:
            return self._value
        seq = struct.unpack_from("<I", b, 0)[0]
        if not seq or seq == self._seq:
            return self._value
        self._seq = seq
        self._value = None if b[4] == DCCH_RELEASED else (b[4] & 1, b[5] & 7, b[6] & 7)
        return self._value

    def plan(self):
        v = self.read()
        if v is None:
            return None
        kind, ss, tn = v
        return (gsm.PLAN_SDCCH8 if kind else gsm.PLAN_SDCCH4), ss, tn


class Tch:
    def __init__(self, stats):
        self.stats = stats
        self.lock = threading.Lock()
        self.tn = None
        self.tsc = 0
        self.open = False
        self.seq = 0
        self.on_close = []
        self.release_seen = None

    def arm(self, tn, tsc, arfcn):
        with self.lock:
            self.seq += 1
            self.tn = tn
            self.tsc = tsc
            self.open = False
            self._write_cfg(tn, tsc, arfcn, self.seq)
        log.info("ASSIGNMENT COMMAND : TCH TN=%d TSC=%d ARFCN=%d arme, en attente du mobile", tn, tsc, arfcn)

    def prove(self, source):
        with self.lock:
            if self.tn is None or self.open:
                return
            self.open = True
            tn = self.tn
        log.info("le mobile est sur le TCH TN=%d (%s) : montant TCH ouvert", tn, source)

    def release_requested(self, reason):
        with self.lock:
            if self.release_seen is not None:
                return
            self.release_seen = time.monotonic()
            tn = self.tn
        if tn is None:
            log.info("%s : en attente de la liberation du canal par le mobile", reason)
        else:
            log.info("%s : TCH TN=%d maintenu jusqu'a la liberation par le mobile", reason, tn)

    def release_overdue(self, delay):
        with self.lock:
            return self.release_seen is not None and time.monotonic() - self.release_seen > delay

    def close(self, reason):
        with self.lock:
            self.release_seen = None
            if self.tn is None:
                return
            tn = self.tn
            self.tn = None
            self.open = False
            self._write_cfg(0, 0, 0, 0)
        log.info("TCH TN=%d ferme (%s)", tn, reason)
        for cb in self.on_close:
            cb()

    def active_tn(self):
        return self.tn

    def is_open(self):
        return self.open and self.tn is not None

    @staticmethod
    def _write_cfg(tn, tsc, arfcn, seq):
        buf = bytearray(16)
        buf[4] = tn & 0xff
        buf[5] = tsc & 0xff
        buf[6:8] = int(arfcn).to_bytes(2, "little")
        buf[0:4] = int(seq).to_bytes(4, "little")
        fd = os.open(TCH_CFG, os.O_CREAT | os.O_WRONLY, 0o644)
        try:
            os.pwrite(fd, bytes(buf), 0)
        finally:
            os.close(fd)
