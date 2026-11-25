#!/usr/bin/env python3
"""
osmo-dongle-call.py — appels voix par un dongle Huawei (test du dongle seul).

  tools/osmo-dongle-call.py dial 0612345678 --duration 20
  tools/osmo-dongle-call.py dial 0612345678 --play test_8k.wav --record out.raw
  tools/osmo-dongle-call.py answer --auto --record in.raw

Signalisation : ^ORIG (setup), ^CONF (alerting), ^CONN (connect), ^CEND (release + cause CC).
Audio : AT^DDSETEX=2 bascule la voix sur le port audio série du dongle,
PCM brut s16le 8 kHz mono, trames de 320 octets / 20 ms.
Lecture d'un enregistrement : aplay -f S16_LE -r 8000 -c 1 out.raw
"""
import argparse
import re
import sys
import threading
import time
import wave

import serial

from huawei_at import ATError, common_args, open_modem

FRAME = 320  # 20 ms @ 8 kHz s16


class Audio:
    def __init__(self, port, play=None, record=None):
        self.ser = serial.Serial(port, 115200, timeout=0.05)
        self.play, self.record = play, record
        self.stop = threading.Event()
        self.threads = []

    def start(self):
        if self.play:
            self.threads.append(threading.Thread(target=self._tx, daemon=True))
        if self.record:
            self.threads.append(threading.Thread(target=self._rx, daemon=True))
        for t in self.threads:
            t.start()

    def _tx(self):
        with wave.open(self.play, "rb") as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (8000, 1, 2):
                print("[AUDIO] le wav doit être 8 kHz mono 16 bits "
                      "(sox in.wav -r 8000 -c 1 -b 16 out.wav)", file=sys.stderr)
                return
            nxt = time.monotonic()
            while not self.stop.is_set():
                chunk = w.readframes(FRAME // 2)
                if not chunk:
                    break
                self.ser.write(chunk.ljust(FRAME, b"\0"))
                nxt += 0.020
                time.sleep(max(0, nxt - time.monotonic()))
        print("[AUDIO] fin de lecture")

    def _rx(self):
        with open(self.record, "wb") as f:
            while not self.stop.is_set():
                d = self.ser.read(FRAME)
                if d:
                    f.write(d)

    def close(self):
        self.stop.set()
        for t in self.threads:
            t.join(timeout=1)
        self.ser.close()


def setup_voice(m):
    m.cmd("AT+CLIP=1")
    m.try_cmd("AT+CRC=0")
    r = m.try_cmd("AT^CVOICE?")
    if r is None:
        print("[WARN] AT^CVOICE refusé : voix probablement désactivée dans ce firmware",
              file=sys.stderr)
    elif not any(re.search(r"\^CVOICE:\s*0", l) for l in r):
        m.try_cmd("AT^CVOICE=0")


def in_call(m, args, t_setup):
    """Boucle d'appel jusqu'à ^CEND, --duration ou Ctrl-C."""
    audio, t_conn = None, None
    try:
        while True:
            u = m.wait_urc(timeout=0.5)
            if t_conn and args.duration and time.time() - t_conn >= args.duration:
                print(f"[CALL] durée {args.duration}s atteinte, raccroche")
                m.try_cmd("AT+CHUP")
                args.duration = None
                continue
            if not u:
                continue
            if u.startswith("^ORIG"):
                print(f"[CALL] setup  ({u})")
            elif u.startswith("^CONF"):
                print(f"[CALL] alerting +{time.time() - t_setup:.2f}s")
            elif u.startswith("^CONN"):
                t_conn = time.time()
                print(f"[CALL] connecté +{t_conn - t_setup:.2f}s")
                if args.play or args.record:
                    m.try_cmd("AT^DDSETEX=2")
                    audio = Audio(args.audio_port, args.play, args.record)
                    audio.start()
            elif u.startswith("^CEND"):
                # ^CEND: call_id, durée, end_status, cc_cause
                f = [x.strip() for x in u.split(":", 1)[1].split(",")]
                cause = f[3] if len(f) > 3 else "?"
                print(f"[CALL] fin : durée={f[1] if len(f) > 1 else '?'}s "
                      f"end_status={f[2] if len(f) > 2 else '?'} cause_CC={cause}")
                return
            elif u in ("NO CARRIER", "BUSY", "NO ANSWER"):
                print(f"[CALL] {u}")
                return
    except KeyboardInterrupt:
        m.try_cmd("AT+CHUP")
    finally:
        if audio:
            audio.close()


def dial(m, args):
    t = time.time()
    m.cmd(f"ATD{args.number};", timeout=30)
    in_call(m, args, t)


def answer(m, args):
    print("[..] attente d'appel entrant, Ctrl-C pour arrêter")
    while True:
        u = m.wait_urc(timeout=1)
        if not u:
            continue
        if u.startswith("+CLIP"):
            mm = re.match(r'\+CLIP:\s*"([^"]*)"', u)
            print(f"[CALL] appelant : {mm.group(1) if mm else u}")
        elif u in ("RING", "+CRING: VOICE"):
            if args.auto:
                time.sleep(args.delay)
                t = time.time()
                m.cmd("ATA", timeout=15)
                in_call(m, args, t)
                if not args.loop:
                    return
            else:
                print("[CALL] ça sonne (--auto pour décrocher)")


def main():
    p = common_args(argparse.ArgumentParser(description=__doc__,
                                            formatter_class=argparse.RawDescriptionHelpFormatter))
    p.add_argument("--audio-port", default="/dev/ttyUSB1", help="port voix PCM du dongle")
    sub = p.add_subparsers(dest="action", required=True)
    d = sub.add_parser("dial")
    d.add_argument("number")
    a = sub.add_parser("answer")
    a.add_argument("--auto", action="store_true")
    a.add_argument("--delay", type=float, default=2.0, help="secondes avant ATA")
    a.add_argument("--loop", action="store_true", help="décrocher en boucle")
    for sp in (d, a):
        sp.add_argument("--duration", type=float, help="raccrocher après N s connectés")
        sp.add_argument("--play", help="wav 8 kHz mono 16 bits à injecter")
        sp.add_argument("--record", help="fichier PCM brut à enregistrer")
    args = p.parse_args()

    m = open_modem(args)
    try:
        setup_voice(m)
        dial(m, args) if args.action == "dial" else answer(m, args)
    except ATError as e:
        print(f"[ERR] {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        pass
    finally:
        m.close()


if __name__ == "__main__":
    main()
