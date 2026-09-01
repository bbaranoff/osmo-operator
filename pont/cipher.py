import logging
import os
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

KC_PATH = "/dev/shm/calypso_kc_l1"
KC_TTL = 0.1


class Cipher:
    def __init__(self, retention, stats):
        self.retention = retention
        self.stats = stats
        self._lock = threading.Lock()
        self._fd = None
        self._cache = None
        self._next = 0.0
        self._held = None
        self.applied_dl = None

    def _read(self):
        now = time.monotonic()
        if now < self._next:
            return self._cache
        self._next = now + KC_TTL
        try:
            if self._fd is None:
                self._fd = os.open(KC_PATH, os.O_RDONLY)
            b = os.pread(self._fd, 32, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            self._cache = None
            return None
        if len(b) < 14:
            self._cache = None
            return None
        algo = b[4]
        kc = b[6:14]
        self._cache = (algo, kc) if 1 <= algo <= 3 and any(kc) else None
        return self._cache

    def current(self):
        with self._lock:
            key = self._read()
            if key:
                self._held = key
                return key
            if self.retention and self._held:
                return self._held
            return None

    def release(self, reason):
        with self._lock:
            if self._held is None:
                return
            self._held = None
        log.info("Kc lache (%s) : le lien repart en clair", reason)

    def apply(self, burst, fn, uplink):
        key = self.current()
        if not uplink:
            self.applied_dl = key
        if key is None:
            return burst
        dl, ul = gsm.a5_keystream(key[0], key[1], fn)
        if uplink:
            self.stats.a5_ul += 1
        else:
            self.stats.a5_dl += 1
        return gsm.a5_xor(burst, ul if uplink else dl)
