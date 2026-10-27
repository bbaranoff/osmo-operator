#!/usr/bin/env python3
# record_drain.py — drains the live FIFO iq_record.fifo -> record.cfile as a
# RING (128 MB, fseek wrap), OUTSIDE the qemu hot path. qemu only does a
# non-blocking write() to the FIFO; this (independent) process absorbs the
# stream and writes it to disk at its own pace. grgsm_decode -c reads
# record.cfile back offline => SI preserved.
#
# The FIFO is opened O_RDWR: it does not block at open AND never sees EOF (a
# write-end is kept here), so qemu (O_WRONLY|O_NONBLOCK) always finds a
# reader => its open succeeds and the stream flows.
#
# =============================================================================
# FULL, TRIGGERABLE CAPTURE — next to the ring, not in its place
# =============================================================================
# The ring above rewinds every 128 MB (~15.5 s): fine to replay the immediate
# past, unusable to capture a whole call. The full capture below NEVER
# rewinds.
#
# WHY A DEDICATED PIPE, and not a read of iq_record.fifo: a FIFO cannot be
# broadcast — two readers SHARE the bytes, neither sees them all. Draining
# iq_record.fifo here would steal part of the stream from the ring and break
# SI decoding. An 8th pipe is added to the relay (CALYPSO_RELAY_FIFOS), fed
# by qemu like the others.
# ⚠️ RELAY_NFIFO_MAX is 8 in qemu_wrap.c and 7 pipes are already declared:
# this pipe takes THE LAST SLOT. Adding a 9th requires raising the constant
# AND recompiling, otherwise it is SILENTLY ignored.
#
# ⚠️ NOT ON TMPFS. /dev/shm and /tmp are RAM. The stream is 1083333 samples/s
# x 8 B = 8.7 MB/s = 520 MB/min = 31 GB/h: a full capture on tmpfs exhausts
# the machine's memory in minutes. The default therefore points to the
# overlay (disk). Check `df -h` before a long capture.
#
# TRIGGER: the capture only writes AS LONG AS the trigger file exists.
#     touch /tmp/iq_full.trigger    -> starts (opens/truncates the .cfile)
#     rm    /tmp/iq_full.trigger    -> stops and CLOSES the file cleanly
# Without the trigger the pipe is still READ and discarded: otherwise the
# relay's memory ring fills up and qemu starts dropping whole frames for ALL
# pipes.
#
# CEILING: at CALYPSO_RECORD_FULL_MAX bytes the capture STOPS and SAYS SO. It
# does not rewind — a file silently biting its own tail is exactly what must
# be avoided here.
import os, sys, threading

FIFO = os.environ.get("CALYPSO_RECORD_FIFO", "/tmp/iq_record.fifo")
OUT  = os.environ.get("CALYPSO_RECORD_FILE", "/tmp/record.cfile")
RING = int(os.environ.get("CALYPSO_RECORD_RING", str(128 << 20)))   # 128 MB

FULL_ON      = os.environ.get("CALYPSO_RECORD_FULL", "0") == "1"
FULL_FIFO    = os.environ.get("CALYPSO_RECORD_FULL_FIFO", "/tmp/iq_full.fifo")
FULL_FILE    = os.environ.get("CALYPSO_RECORD_FULL_FILE", "/opt/GSM/captures/full.cfile")
FULL_TRIGGER = os.environ.get("CALYPSO_RECORD_FULL_TRIGGER", "/tmp/iq_full.trigger")
FULL_MAX     = int(os.environ.get("CALYPSO_RECORD_FULL_MAX", str(8 << 30)))   # 8 GB

def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()

def full_drain():
    """Full capture: always reads, only writes under trigger, never wraps."""
    if not os.path.exists(FULL_FIFO):
        os.mkfifo(FULL_FIFO, 0o666)
    os.makedirs(os.path.dirname(FULL_FILE) or ".", exist_ok=True)
    fd = os.open(FULL_FIFO, os.O_RDWR)       # same idiom as the ring: no block, no EOF
    log("[record-full] %s -> %s (plafond %d MB) — declencheur : %s"
        % (FULL_FIFO, FULL_FILE, FULL_MAX >> 20, FULL_TRIGGER))
    out = None
    w = 0
    plafond_dit = False
    while True:
        b = os.read(fd, 1 << 16)
        if not b:
            continue
        armed = os.path.exists(FULL_TRIGGER)
        if armed and out is None:
            out = open(FULL_FILE, "wb", buffering=1 << 20)
            w = 0
            plafond_dit = False
            log("[record-full] DEMARRE -> %s" % FULL_FILE)
        elif not armed and out is not None:
            out.flush(); out.close(); out = None
            log("[record-full] ARRETE : %s, %.1f MB (%.1f s d'IQ)"
                % (FULL_FILE, w / 1048576.0, w / 8666664.0))
        if out is None:
            continue                          # discarded, but READ: the relay does not clog
        if w + len(b) > FULL_MAX:
            if not plafond_dit:
                log("[record-full] PLAFOND %d MB atteint : capture ARRETEE (pas de "
                    "rembobinage). Retirer %s, vider %s, puis relancer."
                    % (FULL_MAX >> 20, FULL_TRIGGER, FULL_FILE))
                plafond_dit = True
            out.flush(); out.close(); out = None
            continue
        out.write(b)
        w += len(b)
        out.flush()

if not os.path.exists(FIFO):
    os.mkfifo(FIFO, 0o666)

if FULL_ON:
    threading.Thread(target=full_drain, daemon=True).start()
else:
    log("[record-full] inactif (CALYPSO_RECORD_FULL != 1)")

fd = os.open(FIFO, os.O_RDWR)            # O_RDWR: no blocking / no EOF
out = open(OUT, "wb", buffering=1 << 20)
w = 0
log("[record-drain] %s -> %s (ring %d MB)" % (FIFO, OUT, RING >> 20))
while True:
    b = os.read(fd, 1 << 16)            # 64 KB
    if not b:
        continue
    out.write(b)
    w += len(b)
    if w >= RING:                        # RING: rewind (grgsm reads again from 0)
        out.seek(0); w = 0
    out.flush()
