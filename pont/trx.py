import heapq
import logging
import socket
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")


class Clock:
    def __init__(self):
        self.t0 = time.monotonic()

    def fn(self):
        return int((time.monotonic() - self.t0) / gsm.FRAME_DUR) % gsm.HYPERFRAME

    def time_of(self, fn):
        cur = self.fn()
        delta = (fn - cur) % gsm.HYPERFRAME
        if delta > gsm.HYPERFRAME // 2:
            delta -= gsm.HYPERFRAME
        return self.t0 + (cur + delta) * gsm.FRAME_DUR

    def sleep_until_fn(self, fn):
        dt = self.time_of(fn) - time.monotonic()
        if dt > 0:
            time.sleep(dt)


def _udp(bind_host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind_host, port))
    return s


class Trx:
    def __init__(self, cfg, clock, stats, cipher, record):
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.cipher = cipher
        self.record = record
        self.sk_clck = _udp(cfg.trx_bind, cfg.trx_base)
        self.sk_ctrl = _udp(cfg.trx_bind, cfg.trx_base + 1)
        self.sk_data = _udp(cfg.trx_bind, cfg.trx_base + 2)
        self.bts_data = None
        self.bts_clck = None

    def run_ctrl(self):
        while True:
            data, addr = self.sk_ctrl.recvfrom(1500)
            req = data.decode("latin1").strip("\0").strip()
            if not req.startswith("CMD"):
                continue
            parts = req.split()
            cmd = parts[1] if len(parts) > 1 else ""
            args = (" " + " ".join(parts[2:])) if len(parts) > 2 else ""
            self.sk_ctrl.sendto(("RSP %s 0%s" % (cmd, args)).encode() + b"\0", addr)
            if self.bts_clck is None:
                self.bts_clck = (addr[0], self.cfg.trx_base + 100)
                log.info("BTS %s : horloge armee vers le port %d", addr[0], self.bts_clck[1])
            if cmd not in ("SETPOWER", "NOHANDOVER"):
                log.info("CTRL %s%s", cmd, args)

    def run_clock(self):
        while True:
            if self.bts_clck:
                self.sk_clck.sendto(("IND CLOCK %u" % self.clock.fn()).encode() + b"\0", self.bts_clck)
            time.sleep(gsm.FRAME_DUR * self.cfg.clock_period)

    def run_data(self, on_burst):
        while True:
            data, addr = self.sk_data.recvfrom(2000)
            self.bts_data = addr
            if len(data) < 6 + 148:
                continue
            tn = data[0] & 0x07
            fn = struct.unpack_from(">L", data, 1)[0]
            on_burst(tn, fn, gsm.normalize_bits(data[6:154]))

    def send_ul(self, tn, fn, burst, cipher):
        if self.bts_data is None:
            return
        if cipher:
            burst = self.cipher.apply(burst, fn, True)
        hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([self.cfg.rssi & 0xFF]) + struct.pack(">h", 0)
        self.sk_data.sendto(hdr + bytes(255 if b else 0 for b in burst), self.bts_data)
        self.stats.ul_sent += 1
        if self.record:
            self.record.feed_ul(fn, tn, burst)


class Transmitter(threading.Thread):
    def __init__(self, cfg, clock, trx, stats):
        super().__init__(name="tx", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.trx = trx
        self.stats = stats
        self.cond = threading.Condition()
        self.heap = []
        self.seq = 0

    def schedule(self, tn, fn_air, burst, cipher):
        post = self.clock.time_of((fn_air - self.cfg.ul_fn_advance) % gsm.HYPERFRAME)
        with self.cond:
            self.seq += 1
            heapq.heappush(self.heap, (post, self.seq, tn, fn_air, burst, cipher))
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while not self.heap:
                    self.cond.wait()
                post = self.heap[0][0]
                dt = post - time.monotonic()
                if dt > 0:
                    self.cond.wait(dt)
                    continue
                _, _, tn, fn_air, burst, cipher = heapq.heappop(self.heap)
            cur = self.clock.fn()
            off = (fn_air - (cur + self.cfg.ul_fn_advance) + gsm.HYPERFRAME // 2) % gsm.HYPERFRAME - gsm.HYPERFRAME // 2
            if abs(off) > self.cfg.window_tol:
                self.stats.ul_late += 1
                continue
            self.trx.send_ul(tn, fn_air, burst, cipher)
