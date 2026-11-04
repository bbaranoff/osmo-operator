#!/usr/bin/env python3
# tools/osmo-lora-voice.py - the LoRa VOICE LINK: raw GSM speech frames (FR 33
# bytes, or HR 14 bytes) in the KISS frames of an RNode (Heltec V3, TNC mode).
# No codec here, no IP on the air.
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
# air, the other node never transmits, Asterisk receives 0 packets.
#
# FR with silence suppression (default): 4 frames of 33 bytes + 4 of header =
# 136 bytes every 80 ms = 13.6 kbit/s WHILE ONE SIDE SPEAKS. The transcoder
# only sends the frames that carry speech (GSM 06.10 xmaxc, see fr_energy):
# a conversation alternates, the average stays under the link. HR: 4 x 14 + 4
# = 60 bytes / 80 ms = 6 kbit/s, both sides at once fit (~68 % of the air).
#
# LoRa frames (payload of a KISS CMD_DATA frame):
#     'V' | seq (u8) | n (u8) | len (u8) | n x len bytes of speech frame
#         len = 33 (GSM-FR, RFC 3551 payload) or 14 (GSM-HR canonical, TS 101 318)
#     'C' | seq (u8) | cmd (u8)      the SEMAPHORE of the channel, as on a train
#         radio in a tunnel: SEIZE (1) "I take the channel", RELEASE (2) "I give it
#         back". A voice frame also counts as a seizure (a lost SEIZE is harmless).
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
# Statistics the RNode firmware reports to the host (same encoding as RNS'
# RNodeInterface): channel time, PHY parameters, CSMA contention window.
CMD_STAT_CHTM, CMD_STAT_PHYPRM, CMD_STAT_CSMA = 0x25, 0x26, 0x28
CMD_ST_ALOCK, CMD_LT_ALOCK = 0x0B, 0x0C
CMD_READY = 0x0F   # host asks "room in your queue ?", firmware answers 1 (yes) / 0 (no)
RSSI_OFFSET = 157


def kiss_escape(data):
    return data.replace(bytes([FESC]), bytes([FESC, TFESC])).replace(bytes([FEND]), bytes([FESC, TFEND]))


def kiss_frame(data):
    return bytes([FEND, CMD_DATA]) + kiss_escape(data) + bytes([FEND])


class KissParser:
    """Feed raw serial bytes, get the payloads of the CMD_DATA frames."""

    STATS = (CMD_STAT_CHTM, CMD_STAT_PHYPRM, CMD_STAT_CSMA)

    def __init__(self):
        self.buf = bytearray()
        self.in_frame = False
        self.esc = False
        self.cmd = None
        self.radio = {}               # what the module says of itself (see _stat)
        self.ready = None             # last CMD_READY answer (None = never answered)
        self.ready_at = 0.0

    def _stat(self, cmd, b):
        r = self.radio
        if cmd == CMD_STAT_CHTM and len(b) == 11:
            r.update(airtime_short=(b[0] << 8 | b[1]) / 100.0, airtime_long=(b[2] << 8 | b[3]) / 100.0,
                     load_short=(b[4] << 8 | b[5]) / 100.0, load_long=(b[6] << 8 | b[7]) / 100.0,
                     rssi=b[8] - RSSI_OFFSET, noise=b[9] - RSSI_OFFSET)
        elif cmd == CMD_STAT_PHYPRM and len(b) == 12:
            r.update(symbol_ms=(b[0] << 8 | b[1]) / 1000.0, baud=b[2] << 8 | b[3],
                     preamble_symbols=b[4] << 8 | b[5], preamble_ms=b[6] << 8 | b[7],
                     csma_slot_ms=b[8] << 8 | b[9], csma_difs_ms=b[10] << 8 | b[11])
        elif cmd == CMD_STAT_CSMA and len(b) == 3:
            r.update(cw_band=b[0], cw_min=b[1], cw_max=b[2])

    def feed(self, data):
        out = []
        for b in data:
            if b == FEND:
                if self.in_frame and self.cmd == CMD_DATA and self.buf:
                    out.append(bytes(self.buf))
                elif self.in_frame and self.cmd in self.STATS and self.buf:
                    self._stat(self.cmd, bytes(self.buf))
                elif self.in_frame and self.cmd == CMD_READY:
                    self.ready = (self.buf[0] != 0) if self.buf else True
                    self.ready_at = time.monotonic()
                self.in_frame, self.esc, self.cmd = True, False, None
                self.buf.clear()
                continue
            if not self.in_frame:
                continue
            if self.cmd is None:
                self.cmd = b
                continue
            if self.cmd != CMD_DATA and self.cmd not in self.STATS and self.cmd != CMD_READY:
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
MAGIC_C = 0x43  # 'C'
SEIZE, RELEASE = 1, 2
HR = 14        # HR canonical frame, TS 101 318
FR = 33        # FR frame, RFC 3551 payload type 3 (GSM 06.10)
FRAME_MS = 0.020
STALE_S = 0.100   # a partial LoRa frame older than this is sent (end of a sentence)


def pack_voice(seq, frames):
    ln = len(frames[0]) if frames else 0
    return bytes([MAGIC, seq & 0xFF, len(frames), ln]) + b"".join(frames)


def pack_control(seq, cmd):
    return bytes([MAGIC_C, seq & 0xFF, cmd])


def unpack_control(data):
    """(seq, cmd) of a control frame, else (None, None)."""
    if len(data) == 3 and data[0] == MAGIC_C and data[2] in (SEIZE, RELEASE):
        return data[1], data[2]
    return None, None


def unpack_voice(data):
    if len(data) < 4 or data[0] != MAGIC:
        return None, []
    n, ln = data[2], data[3]
    if ln == 0 or len(data) < 4 + n * ln:
        return None, []
    return data[1], [bytes(data[4 + i * ln:4 + (i + 1) * ln]) for i in range(n)]


# ── speech detection on a GSM-FR frame, without decoding it ──────────────
# GSM 06.10 packs, after the 4-bit signature and the 8 LARc (36 bits), four
# sub-frames of 56 bits: Nc (7) bc (2) Mc (2) xmaxc (6) 13 x xMc (3). xmaxc is
# the quantised block maximum of the residual: 0 for digital silence, a few
# units for background noise, 20 to 60 for speech.
def _bits(frame, off, n):
    v = 0
    for i in range(n):
        b = off + i
        v = (v << 1) | ((frame[b >> 3] >> (7 - (b & 7))) & 1)
    return v


def fr_xmaxc(frame):
    return [_bits(frame, 40 + 56 * i + 11, 6) for i in range(4)]


def fr_energy(frame):
    """Max of the four xmaxc (0..63) of an FR frame; -1 if it is not one."""
    if len(frame) != FR or (frame[0] >> 4) != 0xD:
        return -1
    return max(fr_xmaxc(frame))


class Vad:
    """Speech gate on FR frames: a frame passes if its energy is above the
    threshold, or within `hangover` frames after one that was (word endings)."""

    def __init__(self, threshold=12, hangover=8):
        self.threshold, self.hangover = threshold, hangover
        self.remaining = 0
        self.n_speech = self.n_silence = 0

    def speech(self, frame):
        e = fr_energy(frame)
        if e < 0 or e >= self.threshold:
            self.remaining = self.hangover
            self.n_speech += 1
            return True
        if self.remaining > 0:
            self.remaining -= 1
            self.n_speech += 1
            return True
        self.n_silence += 1
        return False


class LoraLink:
    """send(hr14) packs `frames` frames per LoRa frame; poll() returns the received
    frames due for playout, one every 20 ms, after a jitter buffer of one LoRa frame."""

    def __init__(self, port, baud=115200, frames=4, loop=False, frame_len=FR):
        self.port, self.frames, self.loop, self.frame_len = port, frames, loop, frame_len
        self.tx_oldest = 0.0
        self.ser = None
        if not loop:
            import serial
            self.ser = serial.Serial(port, baud, timeout=0)
        self.parser = KissParser()
        self.tx_frames = []
        self.seq_tx = 0
        self.rx = deque()
        self.rx_last_seq = None
        self.max_rx = 3 * frames      # jitter buffer bound (live); a whole message in store-and-forward
        self.hold_playout = False     # store-and-forward: keep the frames until release_playout()
        self.playing = False
        self.next_play = 0.0
        self.t_rx_frame = 0.0         # last LoRa voice frame received
        self.loop_q = deque()
        self.peer = None              # --loop: another LoraLink to feed instead of ourselves (2-party test)
        self.controls = deque()       # (seq, cmd) received, read by the transcoder
        self.events = deque()         # arrival order: ("ctl", cmd) or ("voice", n) - the semaphore needs the ORDER
        self.n = dict(tx=0, rx=0, lost=0, drop=0, ctl_tx=0, ctl_rx=0)

    def fileno(self):
        return self.ser.fileno() if self.ser else None

    def describe(self):
        codec = "FR" if self.frame_len == FR else "HR"
        where = "boucle locale" if self.loop else "%s (KISS)" % self.port
        return "%s, %d trames %s de %d octets par trame LoRa (%d octets)" % (
            where, self.frames, codec, self.frame_len, 4 + self.frames * self.frame_len)

    # ── TX ──
    def send(self, frame):
        if len(frame) != self.frame_len:
            return
        if not self.tx_frames:
            self.tx_oldest = time.monotonic()
        self.tx_frames.append(bytes(frame))
        if len(self.tx_frames) >= self.frames:
            self.flush()

    def flush(self):
        if not self.tx_frames:
            return
        f = kiss_frame(pack_voice(self.seq_tx, self.tx_frames))
        self.seq_tx += 1
        self.tx_frames = []
        self.n["tx"] += 1
        self._write(f)

    def send_control(self, cmd):
        """SEIZE / RELEASE, sent at once (after the voice frames waiting)."""
        self.flush()
        self._write(kiss_frame(pack_control(self.seq_tx, cmd)))
        self.seq_tx += 1
        self.n["ctl_tx"] += 1

    def _write(self, f):
        if self.ser:
            self.ser.write(f)
        elif self.peer is not None:
            self.peer.loop_q.append(f)
        else:
            self.loop_q.append(f)

    # ── RX ──
    def _on_frame(self, payload):
        cseq, cmd = unpack_control(payload)
        if cmd is not None:
            self.n["ctl_rx"] += 1
            self.controls.append((cseq, cmd))
            self.events.append(("ctl", cmd))
            self.rx_last_seq = cseq
            return
        seq, frames = unpack_voice(payload)
        if seq is None:
            return
        self.n["rx"] += 1
        if self.rx_last_seq is not None:
            lost = (seq - self.rx_last_seq - 1) % 256
            if 0 < lost < 128:
                self.n["lost"] += lost
        self.rx_last_seq = seq
        self.t_rx_frame = time.monotonic()
        self.events.append(("voice", len(frames)))
        self.rx.extend(frames)
        while len(self.rx) > self.max_rx:
            self.rx.popleft()
            self.n["drop"] += 1
        if not self.playing and not self.hold_playout and len(self.rx) >= self.frames:
            self.playing = True
            self.next_play = time.monotonic()

    def release_playout(self):
        """Store-and-forward: the message is complete, play it from the start."""
        if self.rx and not self.playing:
            self.playing = True
            self.next_play = time.monotonic()
        return len(self.rx)

    # ── flow control toward the module (store-and-forward sender) ──
    def query_ready(self):
        if self.ser:
            self.ser.write(bytes([FEND, CMD_READY, FEND]))
            self.parser.ready = None
        else:
            self.parser.ready, self.parser.ready_at = True, time.monotonic()

    def is_ready(self):
        return self.parser.ready

    def send_now(self, frames):
        """One LoRa frame of `frames` speech frames, written at once."""
        self._write(kiss_frame(pack_voice(self.seq_tx, list(frames))))
        self.seq_tx += 1
        self.n["tx"] += 1

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
        if self.tx_frames and time.monotonic() - self.tx_oldest >= STALE_S:
            self.flush()                     # end of a sentence: no 5th frame coming
        out = []
        now = time.monotonic()
        if not self.playing:
            # Leftovers of a sentence (fewer than `frames`, so never started):
            # play them once nothing more comes, instead of keeping them for the
            # next sentence where they would be stale and add latency.
            if self.rx and not self.hold_playout and now - self.t_rx_frame >= 2 * STALE_S:
                self.playing = True
                self.next_play = now
            else:
                return out
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

    def radio_stats(self):
        """The module's own view: airtime %, channel load %, RSSI/noise, CSMA window."""
        r = self.parser.radio
        if not r:
            return ""
        parts = []
        if "airtime_short" in r:
            parts.append("antenne %.1f %% (long %.1f %%), charge canal %.1f %% (long %.1f %%), RSSI %d, bruit %d" % (
                r["airtime_short"], r["airtime_long"], r["load_short"], r["load_long"], r["rssi"], r["noise"]))
        if "cw_band" in r:
            parts.append("CSMA cw %d (bande %d, %d..%d)%s" % (
                r["cw_band"], r["cw_band"], r["cw_min"], r["cw_max"],
                ", slot %d ms, DIFS %d ms" % (r["csma_slot_ms"], r["csma_difs_ms"]) if "csma_slot_ms" in r else ""))
        return " ; ".join(parts)

    def set_airtime_limits(self, short_pct, long_pct):
        """CMD_ST_ALOCK / CMD_LT_ALOCK: the firmware's airtime limits, in percent."""
        if not self.ser:
            return
        for cmd, pct in ((CMD_ST_ALOCK, short_pct), (CMD_LT_ALOCK, long_pct)):
            at = int(pct * 100)
            self.ser.write(bytes([FEND, cmd]) + kiss_escape(bytes([(at >> 8) & 0xFF, at & 0xFF])) + bytes([FEND]))

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
    ap.add_argument("--codec", choices=["fr", "hr"], default="fr")
    ap.add_argument("--loop", action="store_true", help="sans radio : ce qu'on emet revient")
    ap.add_argument("--tx", action="store_true", help="emet 50 trames parole/s de motif pendant --seconds (12,5 trames LoRa/s)")
    ap.add_argument("--rx", action="store_true", help="compte ce qui arrive de l'air, seconde par seconde, pendant --seconds")
    ap.add_argument("--seconds", type=float, default=4)
    a = ap.parse_args()
    # KISS round trip
    raw = bytes(range(256)) * 2
    assert KissParser().feed(kiss_frame(raw)) == [raw], "KISS escape/unescape"
    FL = FR if a.codec == "fr" else HR
    seq, fr = unpack_voice(pack_voice(300, [bytes([i] * FL) for i in range(4)]))
    assert seq == 44 and fr == [bytes([i] * FL) for i in range(4)]
    print("KISS + trame voix : OK (%d octets par trame LoRa de %d trames %s)" % (4 + a.frames * FL, a.frames, a.codec.upper()))
    link = LoraLink(a.port, a.baud, a.frames, loop=a.loop, frame_len=FL)
    if a.rx:
        t0 = time.monotonic(); last = 0; per_s = []; n_frames = 0; seqs = []
        while time.monotonic() - t0 < a.seconds:
            link.read_serial()
            while link.rx:
                link.rx.popleft(); n_frames += 1
            s = int(time.monotonic() - t0)
            if s != last:
                st = link.stats(); per_s.append(st["rx"]); seqs.append(st["lost"]); last = s
            time.sleep(0.005)
        print("recu par seconde (trames LoRa) : %s" % " ".join(str(x) for x in per_s))
        print("perdues par seconde (trous de numeros) : %s" % " ".join(str(x) for x in seqs))
        tot = sum(per_s); print("total : %d trames LoRa (%d trames parole) en %.0f s = %.1f LoRa/s ; perdues %d" % (
            tot, n_frames, a.seconds, tot / a.seconds, sum(seqs)))
        print("module : %s" % (link.radio_stats() or "pas de statistiques recues"))
        link.close(); return
    if not (a.loop or a.tx):
        print("lien %s : rien a faire (--loop, --tx ou --rx)" % link.describe())
        return
    t0 = time.monotonic()
    n_in = n_out = 0
    next_tx = t0
    last = None
    gaps = []
    while time.monotonic() - t0 < a.seconds:
        now = time.monotonic()
        if now >= next_tx:
            link.send(bytes([n_in & 0xFF]) * FL)
            n_in += 1
            next_tx += FRAME_MS
        for f in link.poll():
            n_out += 1
            if last is not None:
                gaps.append(now - last)
            last = now
            assert len(f) == FL
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
        print("emis sur l'air : %d trames LoRa (%d trames parole, %d octets chacune) en %.0f s ; recu : %d trames LoRa" % (
            s["tx"], n_in, 4 + a.frames * FL, a.seconds, s["rx"]))
        time.sleep(1.0); link.read_serial()
        print("module : %s" % (link.radio_stats() or "pas de statistiques recues"))
    link.close()


if __name__ == "__main__":
    main()
