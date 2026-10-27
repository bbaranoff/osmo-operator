#!/usr/bin/env python3
# Bridge: grgsm_decode -v (DECODES the real SI of the continuous stream) ->
# parses the SI lines (PD=0x06) -> GSMTAP 16B + L2 -> 4730 (shunt feed_si ->
# DATA_IND -> mobile). The real SCH (grgsm patch) -> UDP 4731 (feed_sb).
#
# FN HANDLING:
#   - the real FN comes from the SCHBSIC <bsic> <fn> <toa> lines (reliable
#     clock), or from an explicit "FN: <n>" if grgsm -v prints one.
#   - it is written in the frame_number field of the GSMTAP sent to feed_si.
#   - reminder, 51-multiframe non-combined BCCH TS0 DL (FN % 51):
#       0,10,20,30,40 = FCCH | 1,11,21,31,41 = SCH | 2-5 = BCCH
#       6-9,12-19,22-29,32-39,42-49 = CCCH (PCH/AGCH) | 50 = idle
#     -> 31 = SCH position, 32 = start of a CCCH block, 51 = multiframe length.
import subprocess, socket, struct, re, sys, os, threading, time

ARFCN = int(os.environ.get("CALYPSO_CCCH_ARFCN", "514"))
CF = sys.argv[1] if len(sys.argv) > 1 else "/tmp/iq_grgsm.fifo"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

SI = {0x1b:"SI3",0x1a:"SI2",0x1c:"SI4",0x19:"SI1",0x1d:"SI2bis",0x1e:"SI2ter",0x06:"RR"}  # NB: 0x21 = PAGING (not SI13=0x00)
# CCCH/AGCH downlink (GATE 3a): the IMM ASSIGN must be forwarded to the mobile,
# not only the SIs. gr-gsm decodes it (06 3f).
CCCH = {0x3f:"IMM-ASSIGN", 0x39:"IMM-ASSIGN-EXT", 0x3a:"IMM-ASSIGN-REJ"}
# Paging Request (PCH): type1=0x21 (== GSM48_MT_RR_PAG_REQ_1, NOT SI13), type2=0x22, type3=0x24.
PAGING = {0x21:"PAG-REQ-1", 0x22:"PAG-REQ-2", 0x24:"PAG-REQ-3"}
GSMTAP_BCCH = 0x01
GSMTAP_AGCH = 0x04
GSMTAP_SDCCH4 = 0x07
GSMTAP_SACCH  = 0x07 | 0x80   # SDCCH/4 + ACCH = dedicated SACCH SS0 (real SI5/SI6)

def fn51_role(fn):
    m = fn % 51
    if m in (0,10,20,30,40): return "FCCH"
    if m in (1,11,21,31,41): return "SCH"
    if m in (2,3,4,5):       return "BCCH"
    if m == 50:              return "idle"
    return "CCCH"

def gsmtap(fn, chan, l2):
    # v2, hdr_len=4 (16B), type=UM(1), ts=0, arfcn, signal_dbm=0 (NOTHING injected),
    # snr=0, frame_number=fn (REAL, decoded), sub_type=chan, antenna=0, sub_slot=0, res=0
    hdr = struct.pack(">BBBBHbbIBBBB", 2, 4, 0x01, 0, ARFCN & 0xffff,
                      0, 0, fn & 0xffffffff, chan, 0, 0, 0)
    return hdr + l2

n = 0; nsch = 0; nsd = 0; nsa = 0; last_fn = 0; last_sd_fn = -1; last_sa_fn = -1

def handle_line(line):
    global n, nsch, nsd, nsa, last_fn, last_sd_fn, last_sa_fn
    # --- real SCH: "SCHBSIC <bsic> <fn> <toa>" -> 4731 + FN clock ---
    msch = re.search(r"SCHBSIC\s+(\d+)\s+(\d+)\s+(-?\d+)", line)
    if msch:
        bsic, fn, toa = int(msch.group(1)), int(msch.group(2)), int(msch.group(3))
        last_fn = fn
        s.sendto(b"SCH1" + struct.pack("<iii", bsic, fn, toa), ("127.0.0.1", 4731))
        nsch += 1
        if nsch <= 10 or nsch % 100 == 0:
            print("[si-bridge] SCH -> 4731 : BSIC=%d (ncc=%d bcc=%d) FN=%d (%%51=%d %s) TOA=%d  #%d"
                  % (bsic,(bsic>>3)&7,bsic&7,fn,fn%51,fn51_role(fn),toa,nsch), flush=True)
        return
    # --- optional explicit FN in the -v line ---
    mfn = re.search(r"\bFN[:=]?\s*(\d+)", line)
    if mfn: last_fn = int(mfn.group(1))
    # --- SI hex line ---
    lstr = line.strip()
    m = re.search(r":\s+([0-9a-fA-F][0-9a-fA-F ]+)$", lstr)
    if not m: return
    try: by = bytes(int(x,16) for x in m.group(1).split())
    except: return
    if len(by) >= 3 and by[1] == 0x06 and (by[2] in SI or by[2] in CCCH or by[2] in PAGING):
        mline_fn = re.match(r"^\s*(\d+)\b", lstr)
        si_fn = int(mline_fn.group(1)) if mline_fn else last_fn
        L2 = (by[:23] + b"\x2b"*23)[:23]
        # IMM ASSIGN (AGCH) AND Paging Request (PCH) -> same AGCH/PCH path on the
        # shunt side (feed_agch -> CCCH block -> firmware chan_nr=0x90 ->
        # gsm48_rr_rx_pch_agch, which dispatches IMM-ASS vs PAGING by msg type).
        # SI -> BCCH.
        is_ccch = (by[2] in CCCH) or (by[2] in PAGING)
        chan = GSMTAP_AGCH if is_ccch else GSMTAP_BCCH
        s.sendto(gsmtap(si_fn, chan, L2), ("127.0.0.1", 4730))
        n += 1
        name = CCCH.get(by[2]) or PAGING.get(by[2]) or SI.get(by[2])
        if is_ccch or n <= 20 or n % 50 == 0:
            print("[si-bridge] %s (mt=0x%02x) FN=%d (%%51=%d %s) -> %s (4730)  #%d"
                  % (name, by[2], si_fn, si_fn%51, fn51_role(si_fn),
                     "feed_agch/PCH" if is_ccch else "feed_si", n), flush=True)
    # --- SDCCH/4 SS0 DL (#2): LAPDm (UA/AUTH), not RR -> gate fn%51 in {22-25} ---
    mfn_sd = re.match(r"^\s*(\d+)\b", lstr)
    sd_fn = int(mfn_sd.group(1)) if mfn_sd else last_fn
    if len(by) >= 3 and (sd_fn % 51) in (22, 23, 24, 25):
        L2 = (by[:23] + b"\x2b"*23)[:23]
        # DEDUP BY FN: gr-gsm may re-decode the SAME on-air block (same FN) ->
        # that duplicate must be skipped. BUT the BTS legitimately RE-SENDS the
        # SAME content (byte-identical UA) on a DIFFERENT FN in answer to a
        # SABM T200 retransmission of the mobile: that re-UA MUST be forwarded,
        # otherwise the mobile never confirms (missed UA -> SABM loop -> "SABM
        # not expected in timer recovery"). A dedup by content would DROP that
        # legitimate re-UA. Dedup is therefore by decoded FN (sd_fn): grgsm
        # emits each on-air FN ONCE (monotonic FN) -> dedup-by-FN removes the
        # re-decode (same FN) AND forwards the BTS re-send (distinct FN, same
        # content). LAPDm fill (UI c=0x03) is always skipped.
        ctrl = by[1] if len(by) > 1 else 0
        is_fill = (ctrl == 0x03)
        if (not is_fill) and sd_fn != last_sd_fn:
            last_sd_fn = sd_fn
            s.sendto(gsmtap(sd_fn, GSMTAP_SDCCH4, L2), ("127.0.0.1", 4730))
            nsd += 1
            if nsd <= 20 or nsd % 50 == 0:
                print("[si-bridge] SDCCH/4 SS0 DL (a0=0x%02x c=0x%02x) FN=%d (%%51=%d) -> feed_sdcch (4730)  #%d [new]"
                      % (by[0], ctrl, sd_fn, sd_fn%51, nsd), flush=True)
            # TCH ARMING: the ASSIGNMENT COMMAND goes through this same DL block.
            check_assignment(by, sd_fn)
    # --- SACCH (SDCCH/4 SS0) DL: REAL SI5(0x1d)/SI6(0x1e) -> feed_sacch ---
    # SACCH SS0 slots (combined CCCH+SDCCH/4): fn%51 in {42-45}. grgsm gives the
    # 23-byte block = [L1 hdr 2][LAPDm: 03 03 len 06 mt L3...]. The RR header
    # "06 1d"/"06 1e" is detected and the block forwarded AS IS to the shunt
    # (sub_type 0x87 = SDCCH4|ACCH) -> REAL feed_sacch.
    if len(by) >= 8 and (sd_fn % 51) in (42, 43, 44, 45):
        mt_sa = None
        for off in range(2, min(9, len(by) - 1)):
            if by[off] == 0x06 and by[off + 1] in (0x1d, 0x1e):
                mt_sa = by[off + 1]; break
        if mt_sa is not None and sd_fn != last_sa_fn:
            last_sa_fn = sd_fn
            L2 = (by[:23] + b"\x2b" * 23)[:23]
            s.sendto(gsmtap(sd_fn, GSMTAP_SACCH, L2), ("127.0.0.1", 4730))
            nsa += 1
            if nsa <= 20 or nsa % 50 == 0:
                print("[si-bridge] SACCH SI%d (mt=0x%02x) FN=%d (%%51=%d) -> feed_sacch REEL (4730)  #%d"
                      % (5 if mt_sa == 0x1d else 6, mt_sa, sd_fn, sd_fn % 51, nsa), flush=True)

# === STAGE 3: DL DECIPHERING — TWO grgsm THAT HAND OVER TO EACH OTHER =========
# The CLEAR grgsm is NEVER killed: killing it to restart with -k at CIPHER MODE
# would remove the FIFO reader and freeze the ipc-device (DL FIFO full ->
# osmo-trx SETPOWER no-response -> feed_iq frozen -> no LU accept). Two
# processes run in parallel, each on ITS FIFO (both fed by the ipc-device relay):
#   - CLEAR grgsm    on CF (iq_grgsm.fifo): decodes establishment/ID/AUTH(RAND)/
#     CIPHER MODE COMMAND. Only outputs CRC-valid frames -> goes quiet by itself
#     on the dedicated channel once the DL is ciphered.
#   - CIPHERED grgsm on CIPH_CF (-e -k): spawned as soon as a Kc appears
#     (RAND->cipher window: it has time to lock FCCH/SCH BEFORE the DL turns
#     ciphered), decodes the ciphered dedicated channel (LU ACCEPT...). Killed
#     only at release (Kc erased).
# Both outputs are merged by handle_line (under lock): grgsm's CRC sorts them
# out, dedup by FN avoids duplicates. ZERO reader gap on the clear FIFO -> the
# ipc-device does not freeze. The churn (spawn/kill) of the ciphered grgsm is
# harmless thanks to the non-blocking ipc-device writer (relay_fifo_writer).
CIPH_CF = os.environ.get("CALYPSO_CIPH_FIFO", "/tmp/iq_grgsm_ciph.fifo")
_hl_lock = threading.Lock()

# grgsm_decode HARD-CODES the GSMTAP UDP port 4729 (socket_pdu UDP_SERVER+CLIENT,
# no option). Two instances -> "bind: Address already in use" -> the 2nd crashes
# (silently, stderr=DEVNULL) -> never any ciphered decode. STDOUT (-v) is read,
# not 4729 -> a COPY is patched for the ciphered grgsm on a free port (4799).
# Generated at startup -> reproducible, survives a reclone of the container.
import shutil
def make_ciph_binary():
    src = shutil.which("grgsm_decode")
    if not src:
        return "grgsm_decode"
    dst = "/tmp/grgsm_decode_ciph"
    try:
        with open(src) as f:
            code = f.read()
        code = code.replace('"4729"', '"4799"')   # unique GSMTAP port (no conflict with the clear one)
        with open(dst, "w") as f:
            f.write(code)
        os.chmod(dst, 0o755)
        print("[si-bridge] grgsm chiffre patche -> %s (GSMTAP 4729->4799)" % dst, flush=True)
        return dst
    except Exception as e:
        print("[si-bridge] patch grgsm chiffre echoue (%s) -> fallback partage 4729" % e, flush=True)
        return src
GRGSM_CIPH = make_ciph_binary()

def spawn_grgsm(fifo, algo=0, kc_hex=None, binary="grgsm_decode", errlog=None):
    cmd = [binary, "-m", "BCCH_SDCCH4", "-t", "0", "-a", str(ARFCN),
           "-c", fifo, "-s", "1083333", "-v"]
    if kc_hex and algo in (1, 2, 3):
        cmd += ["-e", str(algo), "-k", kc_hex]
    err = open(errlog, "w") if errlog else subprocess.DEVNULL
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err, text=True)

# =============================================================================
# TCH ARMING: ASSIGNMENT COMMAND -> calypso_tch_cfg -> 3rd grgsm_decode
# =============================================================================
# Without it the failure cascades SILENTLY: calypso_tch_cfg stays at 0 bytes ->
#   no `grgsm_decode -m TCHF` -> no dedicated GSMTAP -> feed_tch_sacch NEVER
#   called -> the TCH SACCH is not fed -> the MS reads the camping SI5/SI6
#   there (a_cd is SHARED camp<->TCH, with TWO header conventions) -> "Short
#   header message type 0x07 unsupported" once a second, from ~30 s after
#   the ASSIGNMENT.
#
# FILE CONTRACT — as read by its CONSUMER (qemu_wrap.c calypso_tch_cfg_read),
# never guessed:
#   0..3 seq uint32 LE (≠0)   4 TN   5 TSC   6..7 ARFCN uint16 LE   (16 B)
# The seq is written LAST: atomic publication, the reader never sees a
# half-written record.
#
# CHECKS: calypso_tch_cfg not empty; a live `-m TCHF` process;
#         `feed_tch_sacch` > 0 in qemu.log; `Short header 0x07` = 0.
TCH_CFG_PATH = "/dev/shm/calypso_tch_cfg"
TCH_FIFO     = os.environ.get("CALYPSO_TCH_FIFO", "/tmp/iq_grgsm_tch.fifo")
TCH_SPEECH   = "/dev/shm/calypso_tch_speech.gsm"
_tch_proc = None
_tch_cur  = None          # (tn, tsc, arfcn) currently armed
_tch_seq  = 0

def _tch_write_cfg(tn, tsc, arfcn):
    """Publish TN/TSC/ARFCN. seq last = atomic publication."""
    global _tch_seq
    _tch_seq += 1
    buf = bytearray(16)
    buf[4] = tn & 0xff
    buf[5] = tsc & 0xff
    buf[6:8] = int(arfcn).to_bytes(2, "little")
    buf[0:4] = _tch_seq.to_bytes(4, "little")
    fd = os.open(TCH_CFG_PATH, os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        os.pwrite(fd, bytes(buf), 0)
    finally:
        os.close(fd)

def make_tch_binary():
    """Patched copy of grgsm_decode for the TCH — TWO ports to fix.

    grgsm_decode hard-codes 127.0.0.1:4729 TWICE (l.122-123):
      - l.122 UDP_SERVER: only there to avoid ICMP port-unreachable. Two
        instances -> "bind: Address already in use" -> the 2nd DIES, so
        feed_tch_sacch = 0 and the dedicated SACCH stays silent.
      - l.123 UDP_CLIENT: the REAL GSMTAP output. In TCHF mode, tch_f_decoder
        AND cch_decoder publish there (l.213-214).
    The server is therefore bound on a free port, and the client pointed
    straight at 4730, which the shunt listens on: it dispatches by sub_type —
    TCH_F (0x02) -> feed_facch, TCH_ACCH (0x82) -> feed_tch_sacch
    (calypso_dsp_shunt.c:3126-3134). No stdout parsing: data goes from the
    decoder to the shunt directly.
    ⚠️ TARGETED replacements line by line: a global `replace("4729","4730")`
    would bind the server on 4730 and conflict with the shunt.
    """
    src = shutil.which("grgsm_decode")
    if not src:
        return "grgsm_decode"
    dst = "/tmp/grgsm_decode_tch"
    try:
        with open(src) as f:
            code = f.read()
        a = '"UDP_SERVER", "127.0.0.1", "4729"'
        b = '"UDP_CLIENT", "127.0.0.1", "4729"'
        if a not in code or b not in code:
            print("[si-bridge] grgsm TCH : motifs de port introuvables -> "
                  "fallback non patche (conflit 4729 probable)", flush=True)
            return src
        code = code.replace(a, '"UDP_SERVER", "127.0.0.1", "4739"')
        code = code.replace(b, '"UDP_CLIENT", "127.0.0.1", "4730"')
        with open(dst, "w") as f:
            f.write(code)
        os.chmod(dst, 0o755)
        print("[si-bridge] grgsm TCH patche -> %s (bind 4739, GSMTAP -> 4730)" % dst,
              flush=True)
        return dst
    except Exception as e:
        print("[si-bridge] patch grgsm TCH echoue (%s)" % e, flush=True)
        return src
GRGSM_TCH = make_tch_binary()

def _tch_spawn(tn, arfcn):
    """3rd decoder, on the dedicated IQ pipe (fed by CALYPSO_RELAY_FIFOS)."""
    cmd = [GRGSM_TCH, "-m", "TCHF", "-t", str(tn), "-a", str(arfcn),
           "-c", TCH_FIFO, "-s", "1083333", "-v", "-d", "FR", "-o", TCH_SPEECH]
    try:
        err = open("/tmp/osmo-nitb/logs/grgsm_decode_tch.log", "w")
    except Exception:
        err = subprocess.DEVNULL
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=err, text=True)

def arm_tch(tn, tsc, arfcn):
    global _tch_proc, _tch_cur
    cfg = (tn, tsc, arfcn)
    vivant = _tch_proc is not None and _tch_proc.poll() is None
    if cfg == _tch_cur and vivant:
        return                                   # already armed on this config
    if _tch_proc is not None and vivant:
        try: _tch_proc.terminate()
        except Exception: pass
    _tch_write_cfg(tn, tsc, arfcn)
    _tch_proc = _tch_spawn(tn, arfcn)
    _tch_cur = cfg
    print("[si-bridge] TCH arme : TN=%d TSC=%d ARFCN=%d -> %s + grgsm -m TCHF (pid %s)"
          % (tn, tsc, arfcn, TCH_CFG_PATH, _tch_proc.pid), flush=True)

def check_assignment(by, fn):
    """Detect an ASSIGNMENT COMMAND (RR PD=0x06, MT=0x2e) on the SDCCH DL.

    Channel Description 2 (GSM 04.08 10.5.2.5), 3 octets, decoded like
    libosmocore's `struct gsm48_chan_desc`:
        b0: chan_nr           -> TN = b0 & 0x07
        b1: tsc(3) h(1) arfcn_high(2) spare(2)
            TSC = (b1>>5)&7   H = (b1>>4)&1   ARFCN_high = b1 & 0x03
        b2: ARFCN_low         -> ARFCN = (ARFCN_high<<8) | b2   [if H=0]
    """
    for off in range(2, min(7, len(by) - 5)):
        if by[off] != 0x06 or by[off + 1] != 0x2e:
            continue
        b0, b1, b2 = by[off + 2], by[off + 3], by[off + 4]
        tn  = b0 & 0x07
        tsc = (b1 >> 5) & 0x07
        h   = (b1 >> 4) & 0x01
        if h:
            # ⚠️ EXPLICIT REFUSAL. This chain does NOT handle frequency hopping
            # (same limit on the UL injection side). Building an ARFCN from
            # the MAIO/HSN fields would silently give a WRONG number, and the
            # decoder would listen elsewhere with nothing to show for it.
            print("[si-bridge] ASSIGNMENT COMMAND avec SAUT DE FREQUENCE (H=1) : "
                  "TCH NON arme (chaine sans hopping). FN=%d" % fn, flush=True)
            return
        arfcn = ((b1 & 0x03) << 8) | b2
        print("[si-bridge] ASSIGNMENT COMMAND FN=%d -> chan_nr=0x%02x TN=%d TSC=%d ARFCN=%d"
              % (fn, b0, tn, tsc, arfcn), flush=True)
        arm_tch(tn, tsc, arfcn)
        return

def reader_loop(proc, tag):
    # raw log per grgsm (decipher diagnostic): /root/grgsm_clair.raw / _ciph.raw
    try: raw = open("/root/grgsm_%s.raw" % tag, "w")
    except Exception: raw = None
    for line in proc.stdout:
        if raw:
            try: raw.write(line); raw.flush()
            except Exception: pass
        with _hl_lock:
            handle_line(line)
    if raw:
        try: raw.close()
        except Exception: pass
    print("[si-bridge] grgsm %s termine (n=%d nsch=%d nsd=%d nsa=%d)"
          % (tag, n, nsch, nsd, nsa), flush=True)

def read_kc():
    try:
        with open("/dev/shm/calypso_kc", "rb") as f:
            b = f.read(32)
    except OSError:
        return (0, 0, None)
    if len(b) < 14:
        return (0, 0, None)
    seq = int.from_bytes(b[0:4], "little")
    if seq == 0:
        return (0, 0, None)
    return (seq, b[4], b[6:14].hex())

# --- CLEAR grgsm: always alive (watchdog respawn on crash), NEVER killed at cipher ---
clear = {"proc": None}
def ensure_clear():
    p = clear["proc"]
    if p is None or p.poll() is not None:
        clear["proc"] = spawn_grgsm(CF)
        threading.Thread(target=reader_loop, args=(clear["proc"], "clair"),
                         daemon=True).start()
        print("[si-bridge] grgsm CLAIR spawn sur %s (jamais tue au cipher)" % CF, flush=True)

ensure_clear()

# --- CIPHERED grgsm: spawned/killed by the Kc, ALWAYS on CIPH_CF (never on CF) ---
ciph = {"applied": (0, None), "proc": None}
while True:
    time.sleep(0.5)
    ensure_clear()                     # clear grgsm watchdog
    seq, algo, kc = read_kc()
    want = (algo, kc) if (seq and algo in (1, 2, 3)) else (0, None)
    if want == ciph["applied"]:
        continue
    # Kc state changed -> ONLY the ciphered grgsm is (re)cycled (on CIPH_CF)
    p = ciph["proc"]
    if p is not None:
        try: p.kill(); p.wait(timeout=2)
        except Exception: pass
        ciph["proc"] = None
    ciph["applied"] = want
    if want[0]:
        np = spawn_grgsm(CIPH_CF, algo=want[0], kc_hex=want[1], binary=GRGSM_CIPH,
                         errlog="/root/grgsm_ciph.err")
        ciph["proc"] = np
        threading.Thread(target=reader_loop, args=(np, "chiffre"),
                         daemon=True).start()
        print("[si-bridge] grgsm CHIFFRE spawn sur %s : A5/%d kc=%s (decipher DL)"
              % (CIPH_CF, want[0], want[1]), flush=True)
    else:
        print("[si-bridge] Kc efface -> grgsm chiffre arrete (clair seul)", flush=True)
