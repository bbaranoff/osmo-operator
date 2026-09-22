import heapq
import logging
import os
import socket
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

# [2026-09-22] L'HORLOGE DU BANC SUIT LE DSP, PAS LE MUR.
#
# En montage DSP le C54x est emule : il coute ~5,8 ms par trame TDMA contre
# 4,615 ms de temps reel. La BTS, elle, tourne sur l'horloge que ce fichier lui
# envoie (IND CLOCK, run_clock). Avec une horloge murale elle emettait 1,25
# trame pour chacune que le DSP consommait : le BSP rejouait un anneau de plus
# en plus vieux (mesure du 2026-09-22 : pont a fn=99674 pendant que le BSP
# jouait la trame BTS 80410, soit 87 s de retard au bout de huit minutes),
# l'IMMEDIATE ASSIGNMENT arrivait apres T3126 et le canal dedie sortait des
# blocs incomplets (« Dropping frame with 110 bit errors »).
#
# c54x_exe publie la trame BTS que son BSP reclame (calypso_bsp.c,
# bsp_horloge_publier). On s'y asservit EN FREQUENCE, pas par recalage : la
# duree effective d'une trame (self.dur) suit la cadence mesuree du DSP, avec
# une correction proportionnelle qui tient l'avance de phase a AVANCE trames.
#
# Pourquoi pas un simple recalage de t0 : essaye d'abord, mesure immediate --
# « UL bursts=11 tard=232 ». Transmitter.run() jette tout burst dont la trame
# s'ecarte de plus de window_tol (1 trame) de l'horloge au moment de l'envoi ;
# une horloge qui avance par a-coups de quelques trames sort de cette fenetre a
# chaque fois. Plus un seul SABM n'arrivait a la BTS, donc plus de UA, donc
# « MDL-ERROR-IND cause 1 » et plus aucune mise a jour de localisation. Une
# horloge asservie doit rester CONTINUE : on ne change que sa vitesse, et on
# rebase t0 a chaque changement pour que fn() ne saute pas.
#
# PONT_HORLOGE=0 revient a l'horloge murale ; le fichier absent (montage sans
# DSP, couche 1 gr-gsm) laisse aussi l'horloge libre, sans rien a configurer.
HORLOGE = "/dev/shm/calypso_horloge"
HORLOGE_PERIODE = 0.25      # entre deux mesures de la cadence du DSP
HORLOGE_KP = 1.0            # correction de phase, en trames de periode par trame d'ecart
HORLOGE_PHASE_N = 400.0     # l'ecart de phase est rattrape en ~N trames


class Clock:
    def __init__(self):
        self.t0 = time.monotonic()
        self.dur = gsm.FRAME_DUR
        self._verrou = threading.Lock()
        self._asservie = os.environ.get("PONT_HORLOGE", "1") not in ("0", "", "no")
        self._avance = int(os.environ.get("PONT_HORLOGE_AVANCE", "12"))
        self._fd = None
        self._echeance = 0.0
        self._t_prec = None
        self._dsp_prec = None
        self._dit = False

    def _lire_dsp(self):
        """Trame BTS que le DSP reclame, ou None s'il n'est pas encore cale."""
        try:
            if self._fd is None:
                self._fd = os.open(HORLOGE, os.O_RDONLY)
            b = os.pread(self._fd, 16, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            return None
        if len(b) < 16:
            return None
        seq, cale, fn_bts, _tick = struct.unpack("<IIII", b)
        return fn_bts % gsm.HYPERFRAME if (seq and cale) else None

    def _reguler(self, now):
        """Appele sous verrou, au plus une fois par HORLOGE_PERIODE."""
        if now < self._echeance:
            return
        self._echeance = now + HORLOGE_PERIODE
        dsp = self._lire_dsp()
        if dsp is None:
            self._t_prec = self._dsp_prec = None
            return
        if not self._dit:
            self._dit = True
            log.info("horloge asservie au DSP (%s, avance visee %d trames)", HORLOGE, self._avance)
        t_prec, dsp_prec = self._t_prec, self._dsp_prec
        self._t_prec, self._dsp_prec = now, dsp
        if t_prec is None:
            return
        avancees = (dsp - dsp_prec) % gsm.HYPERFRAME
        if avancees <= 0 or avancees > gsm.HYPERFRAME // 2:
            return                                   # DSP arrete ou recale : on garde la vitesse
        dur_dsp = (now - t_prec) / avancees          # cadence mesuree du DSP
        # Ecart de phase, en trames, signe : > 0 = l'horloge du banc devance.
        f = (now - self.t0) / self.dur
        ecart = (int(f) - (dsp + self._avance)) % gsm.HYPERFRAME
        if ecart > gsm.HYPERFRAME // 2:
            ecart -= gsm.HYPERFRAME
        cible = dur_dsp * (1.0 + HORLOGE_KP * ecart / HORLOGE_PHASE_N)
        cible = min(max(cible, gsm.FRAME_DUR * 0.5), gsm.FRAME_DUR * 4.0)
        dur = 0.7 * self.dur + 0.3 * cible
        self.t0 = now - f * dur                      # rebase : fn() reste continue
        self.dur = dur

    def fn(self):
        now = time.monotonic()
        if not self._asservie:
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME
        with self._verrou:
            self._reguler(now)
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME

    def time_of(self, fn):
        now = time.monotonic()
        if self._asservie:
            with self._verrou:
                self._reguler(now)
                t0, dur = self.t0, self.dur
        else:
            t0, dur = self.t0, self.dur
        cur = int((now - t0) / dur)
        delta = (fn - cur) % gsm.HYPERFRAME
        if delta > gsm.HYPERFRAME // 2:
            delta -= gsm.HYPERFRAME
        return t0 + (cur + delta) * dur

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
            bits = gsm.normalize_bits(data[6:154])
            if self.cfg.dsp_port:
                # [2026-09-17] Le meme burst, tel que le BSP du DSP l'attend
                # (calypso_bsp.c bsp_trxd_readable) : 8 octets d'en-tete
                # [tn, fn BE32, attenuation, 0, 0] puis 148 bits 0/1. Le BSP les
                # convertit lui-meme en I/Q (table cos) et les depose en DARAM.
                hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([data[5] if len(data) > 5 else 0, 0, 0])
                self.sk_data.sendto(hdr + bytes(1 if b else 0 for b in bits), ("127.0.0.1", self.cfg.dsp_port))
            on_burst(tn, fn, bits)

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
