#!/usr/bin/env python3
# tools/osmo-lora-voice.py - the LoRa VOICE LINK: raw GSM-HR frames in the KISS
# frames of an RNode (Heltec V3, TNC mode). No codec here, no IP on the air.
#
# Used by tools/osmo-hr-transcodeur.py --lora PORT: for a call toward the other
# node, the HR frames the MGW hands it (coded by the ROM vocoder of the phone,
# RTP passthrough in osmo-mgw) go on the air as they are, and the frames
# received go back to the MGW as RTP, decoded by the ROM vocoder of the other
# phone. Like TrFO in a real network: the network only transports.
#
# Why raw frames: RTP over IP is 50 packets/s x 73 bytes per direction (33 of
# GSM-FR + 40 of IP/UDP/RTP) = 29 kbit/s per direction on a 21.88 kbit/s
# half-duplex link shared by both nodes - measured: our RNode monopolises the
# air, the other node never transmits, Asterisk receives 0 packets. Here:
# 4 HR frames of 14 bytes + 3 bytes of header = 59 bytes every 80 ms per
# direction, ~5.9 kbit/s, about 68 % of the air for both directions.
#
# LoRa frame (payload of a KISS CMD_DATA frame):
#     'V' | seq (u8) | n (u8) | n x 14 bytes of HR canonical frame (TS 101 318)
#
#   python3 osmo-lora-voice.py --loop        self-test, no radio
#   python3 osmo-lora-voice.py --port /dev/ttyUSB0 --tx   sends a test pattern on the air
import argparse
import os
import select
import sys
import time
from collections import deque

# ── KISS (RNode, TNC mode) ────────────────────────────────────────────────
FEND, FESC, TFEND, TFESC, CMD_DATA = 0xC0, 0xDB, 0xDC, 0xDD, 0x00


def kiss_escape(data):
    return data.replace(bytes([FESC]), bytes([FESC, TFESC])).replace(bytes([FEND]), bytes([FESC, TFEND]))


def kiss_frame(data):
    return bytes([FEND, CMD_DATA]) + kiss_escape(data) + bytes([FEND])


class KissParser:
    """Feed raw serial bytes, get the payloads of the CMD_DATA frames."""

    def __init__(self):
        self.buf = bytearray()
        self.in_frame = False
        self.esc = False
        self.cmd = None

    def feed(self, data):
        out = []
        for b in data:
            if b == FEND:
                if self.in_frame and self.cmd == CMD_DATA and self.buf:
                    out.append(bytes(self.buf))
                self.in_frame, self.esc, self.cmd = True, False, None
                self.buf.clear()
                continue
            if not self.in_frame:
                continue
            if self.cmd is None:
                self.cmd = b
                continue
            if self.cmd != CMD_DATA:
                continue
            if self.esc:
                self.buf.append(FEND if b == TFEND else FESC if b == TFESC else b)
                self.esc = False
            elif b == FESC:
                self.esc = True
            else:
                self.buf.append(b)
        return out


# ── the voice frame ───────────────────────────────────────────────────────
MAGIC = 0x56   # 'V'
HR = 14        # HR canonical frame, TS 101 318
FRAME_MS = 0.020


def pack_voice(seq, frames):
    return bytes([MAGIC, seq & 0xFF, len(frames)]) + b"".join(frames)


def unpack_voice(data):
    if len(data) < 3 or data[0] != MAGIC:
        return None, []
    n = data[2]
    if len(data) < 3 + n * HR:
        return None, []
    return data[1], [bytes(data[3 + i * HR:3 + (i + 1) * HR]) for i in range(n)]


class LoraLink:
    """send(hr14) packs `frames` frames per LoRa frame; poll() returns the received
    frames due for playout, one every 20 ms, after a jitter buffer of one LoRa frame."""

    def __init__(self, port, baud=115200, frames=4, loop=False):
        self.port, self.frames, self.loop = port, frames, loop
        self.ser = None
        if not loop:
            import serial
            self.ser = serial.Serial(port, baud, timeout=0)
        self.parser = KissParser()
        self.tx_frames = []
        self.seq_tx = 0
        self.rx = deque()
        self.rx_last_seq = None
        self.playing = False
        self.next_play = 0.0
        self.loop_q = deque()
        self.n = dict(tx=0, rx=0, lost=0, drop=0)

    def fileno(self):
        return self.ser.fileno() if self.ser else None

    def describe(self):
        return "boucle locale" if self.loop else "%s (KISS, %d trames HR / trame LoRa)" % (self.port, self.frames)

    # ── TX ──
    def send(self, hr14):
        self.tx_frames.append(bytes(hr14[:HR]))
        if len(self.tx_frames) >= self.frames:
            self.flush()

    def flush(self):
        if not self.tx_frames:
            return
        f = kiss_frame(pack_voice(self.seq_tx, self.tx_frames))
        self.seq_tx += 1
        self.tx_frames = []
        self.n["tx"] += 1
        if self.ser:
            self.ser.write(f)
        else:
            self.loop_q.append(f)

    # ── RX ──
    def _on_frame(self, payload):
        seq, frames = unpack_voice(payload)
        if seq is None:
            return
        self.n["rx"] += 1
        if self.rx_last_seq is not None:
            lost = (seq - self.rx_last_seq - 1) % 256
            if 0 < lost < 128:
                self.n["lost"] += lost
        self.rx_last_seq = seq
        self.rx.extend(frames)
        while len(self.rx) > 3 * self.frames:        # jitter buffer bound: 3 LoRa frames
            self.rx.popleft()
            self.n["drop"] += 1
        if not self.playing and len(self.rx) >= self.frames:
            self.playing = True
            self.next_play = time.monotonic()

    def read_serial(self):
        if self.ser:
            data = self.ser.read(4096)
            if data:
                for p in self.parser.feed(data):
                    self._on_frame(p)
        while self.loop_q:
            for p in self.parser.feed(self.loop_q.popleft()):
                self._on_frame(p)

    def poll(self):
        """Frames to play now (0, 1 or, after a stall, several)."""
        self.read_serial()
        out = []
        if not self.playing:
            return out
        now = time.monotonic()
        while now >= self.next_play:
            if not self.rx:
                self.playing = False             # underrun: wait for a full LoRa frame
                break
            self.next_play += FRAME_MS
            out.append(self.rx.popleft())
        return out

    def timeout(self):
        """Seconds until the next playout, for select()."""
        if not self.playing:
            return FRAME_MS
        return max(0.0, min(FRAME_MS, self.next_play - time.monotonic()))

    def stats(self, reset=True):
        s = dict(self.n)
        s["buffer"] = len(self.rx)
        if reset:
            for k in self.n:
                self.n[k] = 0
        return s

    def close(self):
        self.flush()
        if self.ser:
            self.ser.close()


# ── self-test ─────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--frames", type=int, default=4)
    ap.add_argument("--loop", action="store_true", help="sans radio : ce qu'on emet revient")
    ap.add_argument("--tx", action="store_true", help="emet 50 trames HR/s de motif pendant --seconds")
    ap.add_argument("--seconds", type=float, default=4)
    a = ap.parse_args()
    # KISS round trip
    raw = bytes(range(256)) * 2
    assert KissParser().feed(kiss_frame(raw)) == [raw], "KISS escape/unescape"
    seq, fr = unpack_voice(pack_voice(300, [bytes([i] * HR) for i in range(4)]))
    assert seq == 44 and fr == [bytes([i] * HR) for i in range(4)]
    print("KISS + trame voix : OK (%d octets par trame LoRa de %d)" % (3 + a.frames * HR, a.frames))
    link = LoraLink(a.port, a.baud, a.frames, loop=a.loop)
    if not (a.loop or a.tx):
        print("lien %s : rien a faire (--loop ou --tx)" % link.describe())
        return
    t0 = time.monotonic()
    n_in = n_out = 0
    next_tx = t0
    last = None
    gaps = []
    while time.monotonic() - t0 < a.seconds:
        now = time.monotonic()
        if now >= next_tx:
            link.send(bytes([n_in & 0xFF]) * HR)
            n_in += 1
            next_tx += FRAME_MS
        for f in link.poll():
            n_out += 1
            if last is not None:
                gaps.append(now - last)
            last = now
            assert len(f) == HR
        time.sleep(0.002)
    link.flush()
    s = link.stats()
    if a.loop:
        g = sorted(gaps)
        print("boucle : %d trames HR envoyees, %d rejouees, LoRa tx %d rx %d, perdues %d, jetees %d, "
              "ecart entre trames rejouees : median %.1f ms, max %.1f ms" % (
                  n_in, n_out, s["tx"], s["rx"], s["lost"], s["drop"],
                  1000 * g[len(g) // 2] if g else 0, 1000 * g[-1] if g else 0))
        ok = n_out >= n_in - 2 * a.frames and s["lost"] == 0
        print("VERDICT :", "OK" if ok else "ECHEC")
        sys.exit(0 if ok else 1)
    else:
        print("emis sur l'air : %d trames LoRa (%d trames HR) en %.0f s ; recu : %d trames LoRa" % (
            s["tx"], n_in, a.seconds, s["rx"]))
    link.close()


if __name__ == "__main__":
    main()
