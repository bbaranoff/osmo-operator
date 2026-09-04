import logging
import os
import threading
import time

import numpy as np

from . import gsm

log = logging.getLogger("pont")

SAMPLES_PER_FRAME = 1250
SAMPLES_PER_SLOT_X4 = 625


class Direction:
    def __init__(self, name, path, fifo_path, max_bytes, min_free, osr, taps):
        self.name = name
        self.path = path
        self.fifo_path = fifo_path
        self.max_bytes = max_bytes
        self.min_free = min_free
        self.osr = osr
        self.taps = taps
        self.lock = threading.Lock()
        self.frames = {}
        self.fh = None
        self.bytes = 0
        self.off = False
        self.restart = False
        self.fifo_fd = None
        self.fifo_pending = b""
        self.fifo_retry = 0
        self.n_frames = 0
        self.n_bursts = 0
        self.n_fifo_drop = 0

    def feed(self, fn, tn, burst):
        if self.off:
            return
        with self.lock:
            self.frames.setdefault(fn, {})[tn] = burst

    def open(self):
        if self.fh is not None:
            self.fh.close()
            self.fh = None
        try:
            os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
            st = os.statvfs(os.path.dirname(self.path) or ".")
            if st.f_bavail * st.f_frsize < self.min_free:
                log.warning("enregistrement %s coupe : moins de %d Mo libres", self.name, self.min_free // 1048576)
                return False
            self.fh = open(self.path, "wb", buffering=1024 * 1024)
        except OSError as e:
            log.warning("enregistrement %s impossible (%s)", self.name, e)
            return False
        self.bytes = 0
        log.info("enregistrement %s -> %s (buffer roulant de %d Mo)", self.name, self.path, self.max_bytes // 1048576)
        return True

    def modulate(self, burst):
        nrz = 2.0 * np.frombuffer(bytes(burst), dtype=np.uint8).astype(np.float64) - 1.0
        prev = np.concatenate(([nrz[0]], nrz[:-1]))
        up = np.zeros(len(nrz) * self.osr)
        up[::self.osr] = nrz * prev
        phase = np.cumsum(np.convolve(up, self.taps, mode="same")) * (np.pi / 2.0)
        return np.exp(1j * phase).astype(np.complex64)

    def _fifo(self, octets):
        if not self.fifo_path:
            return
        if self.fifo_fd is None:
            if self.n_frames < self.fifo_retry:
                return
            self.fifo_retry = self.n_frames + 217
            try:
                if not os.path.exists(self.fifo_path):
                    os.mkfifo(self.fifo_path, 0o644)
                self.fifo_fd = os.open(self.fifo_path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                return
        data = self.fifo_pending + octets
        maxq = 3 * len(octets)
        if len(data) > maxq:
            data = data[len(data) - maxq:]
            self.n_fifo_drop += 1
        try:
            n = os.write(self.fifo_fd, data)
            self.fifo_pending = data[n:]
        except BlockingIOError:
            self.fifo_pending = data
        except OSError:
            os.close(self.fifo_fd)
            self.fifo_fd = None
            self.fifo_pending = b""

    def write_frame(self, fn, spf, step, blen, silence):
        # LE FIFO FFT NE DEPEND PAS DU DISQUE. [2026-09-04] fh est None quand
        # l'enregistrement fichier est coupe (moins de PONT_AIRREC_MINFREE_MB
        # libres : le cas de toute cle live, dont l'overlay tient en RAM). Le
        # FIFO n'etait alimente qu'ici, apres l'ecriture fichier : sans .cfile,
        # plus de spectre I/Q dans le dashboard ni dans le Conky, et le bouton
        # record du dashboard (qui lit CE fifo) restait muet. Le fichier reste
        # coupe faute de place - c'est voulu - mais les trames passent au FIFO.
        if self.off or (self.fh is None and not self.fifo_path):
            return
        with self.lock:
            slots = self.frames.pop(fn, None)
            if len(self.frames) > 512:
                self.frames.clear()
        if slots:
            frame = np.zeros(spf, dtype=np.complex64)
            for tn, burst in slots.items():
                o = tn * step
                frame[o:o + blen] = self.modulate(burst)
                self.n_bursts += 1
        else:
            frame = silence
        octets = frame.tobytes()
        self._fifo(octets)
        self.n_frames += 1
        if self.fh is None:
            return
        try:
            self.fh.write(octets)
        except OSError as e:
            # Le fichier se coupe, pas le FIFO : voir l'en-tete de la methode.
            log.warning("enregistrement %s : ecriture echouee (%s), coupe", self.name, e)
            try:
                self.fh.close()
            except OSError:
                pass
            self.fh = None
            return
        self.bytes += len(octets)
        if self.restart or self.bytes >= self.max_bytes:
            self.restart = False
            self.fh.flush()
            self.fh.seek(0)
            self.fh.truncate(0)
            self.bytes = 0


class Recorder(threading.Thread):
    def __init__(self, cfg, clock):
        super().__init__(name="record", daemon=True)
        self.cfg = cfg
        self.clock = clock
        osr = cfg.record_osr
        n = 4 * osr
        t = np.arange(-n, n + 1) / float(osr)
        g = np.exp(-2.0 * (np.pi ** 2) * (0.3 ** 2) * t ** 2 / np.log(2.0))
        taps = g / g.sum()
        max_bytes = cfg.record_max_mb * 1024 * 1024
        min_free = cfg.record_min_free_mb * 1024 * 1024
        self.dl = Direction("descendant", cfg.record_dl_path, cfg.record_dl_fifo, max_bytes, min_free, osr, taps)
        self.ul = Direction("montant", cfg.record_ul_path, cfg.record_ul_fifo, max_bytes, min_free, osr, taps)
        self.ul.off = not cfg.record_ul

    def feed_dl(self, fn, tn, burst):
        self.dl.feed(fn, tn, burst)

    def feed_ul(self, fn, tn, burst):
        self.ul.feed(fn, tn, burst)

    def split(self, *_):
        self.dl.restart = True
        self.ul.restart = True

    def summary(self):
        return " | IQ dl=%dtr/%dbu ul=%dtr/%dbu fifo_drop=%d/%d" % (
            self.dl.n_frames, self.dl.n_bursts, self.ul.n_frames, self.ul.n_bursts,
            self.dl.n_fifo_drop, self.ul.n_fifo_drop)

    def run(self):
        osr = self.cfg.record_osr
        if osr % 4:
            log.warning("enregistrement refuse : OSR=%d doit etre multiple de 4", osr)
            return
        # Un sens dont le fichier ne s'ouvre pas (place, droits) garde son FIFO :
        # il ne s'eteint (off) que s'il n'a pas de FIFO a servir non plus.
        if not self.dl.open() and not self.dl.fifo_path:
            self.dl.off = True
        if not self.ul.off and not self.ul.open() and not self.ul.fifo_path:
            self.ul.off = True
        if self.dl.off and self.ul.off:
            return
        spf = SAMPLES_PER_FRAME * osr
        step = (SAMPLES_PER_SLOT_X4 * osr) // 4
        blen = 148 * osr
        silence = np.zeros(spf, dtype=np.complex64)
        nxt = (self.clock.fn() + 2) % gsm.HYPERFRAME
        while True:
            d = (self.clock.fn() - nxt) % gsm.HYPERFRAME
            if d > gsm.HYPERFRAME // 2 or d < 2:
                time.sleep(gsm.FRAME_DUR / 2.0)
                continue
            if d > 650:
                with self.dl.lock:
                    self.dl.frames.clear()
                with self.ul.lock:
                    self.ul.frames.clear()
                nxt = (self.clock.fn() + 2) % gsm.HYPERFRAME
                continue
            self.dl.write_frame(nxt, spf, step, blen, silence)
            self.ul.write_frame(nxt, spf, step, blen, silence)
            nxt = (nxt + 1) % gsm.HYPERFRAME
