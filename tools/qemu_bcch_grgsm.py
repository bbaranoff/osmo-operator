#!/usr/bin/env python3
"""
tools/qemu_bcch_grgsm.py - gr-gsm bridge: DL I/Q of the BTS (qemu tee) -> bursts ->
gr-gsm demapper + decoder -> GSMTAP -> the qemu shunt (4730) -> a_cd -> the mobile camps.

The REAL signal of the BTS, demodulated and decoded by the official gr-gsm chain
(gsm_bcch_ccch_demapper + control_channels_decoder, the same code as
grgsm_decode).

Chain:
  UDP I/Q (qemu BSP tee, port 6703)  --parse TRXD (8 hdr + 148 cs16)-->
    --differential GMSK demod (1 SPS)-->  148 hard bits
    --gsmtap_hdr(UM_BURST) + 148 bytes-->  posted to the gr-gsm demapper
    --gsm_bcch_ccch_demapper (assembles 4 bursts of the 51-MF)-->
    --control_channels_decoder (deinterleave+Viterbi+FIRE)-->  GSMTAP L2
    --network.socket_pdu(UDP_CLIENT 127.0.0.1:4730)-->  shunt feed_si -> a_cd

The demod produces the 148 bits of the complete burst (3 tail | 57 | 1 | 26 train |
1 | 57 | 3 tail); the gr-gsm decoder extracts/corrects on its own. If nothing ever
decodes (the decoder is silent on CRC fail), invert BIT_SIGN.

Usage : source /root/.env/bin/activate ; python tools/qemu_bcch_grgsm.py
Env   : IQ_TEE_PORT(6703) GSMTAP_HOST/PORT(127.0.0.1/4730) ARFCN(1)
        TS(0) BIT_SIGN(1)
"""
import os, socket, struct
import numpy as np
from gnuradio import gr, gsm, network

IQ_TEE_PORT = int(os.environ.get("IQ_TEE_PORT", "6703"))
GSMTAP_HOST = os.environ.get("GSMTAP_HOST", "127.0.0.1")
GSMTAP_PORT = int(os.environ.get("GSMTAP_PORT", "4730"))
ARFCN       = int(os.environ.get("ARFCN", "1"))
TS          = int(os.environ.get("TS", "0"))
BIT_SIGN    = int(os.environ.get("BIT_SIGN", "1"))

# --- gsmtap.h (gr-gsm) ---
GSMTAP_VERSION       = 0x02
GSMTAP_TYPE_UM_BURST = 0x03
GSMTAP_BURST_NORMAL  = 0x06
BURST_SIZE           = 148

# The 8 GSM training sequences (26 bits) - to validate the live demod.
ALL_TSC = [
    "00100101110000100010010111", "00101101110111100010110111",
    "01000011101110100100001110", "01000111101101000100011110",
    "00011010111001000001101011", "01001110101100000100111010",
    "10100111110110001010011111", "11101111000100101110111100",
]
dbg_tsc = [0]   # counter of instrumented BCCH bursts (mutable)
dbg_dump = []   # raw BCCH bursts waiting to be dumped (mutable)

def demod_burst(iq):
    """iq: np.complex (>=148) -> string of 148 hard bits '0'/'1', or None.

    GMSK demod validated end to end on a real capture (26/26 TSC, FIRE CRC ok):
      - derotation -pi/2 per sample  (y = s * exp(-j pi/2 k))
      - slicer on imag(y)>0
      - polarity inversion (BIT_SIGN=1 -> invert; -1 -> no)
      - left shift by 1 bit: the osmo-trx burst arrives with TSC@62,
        gr-gsm expects TSC@61 (3 tail|57|1|26 TSC@61..86|1|57|3 tail).
    """
    if len(iq) < BURST_SIZE:
        return None
    s = iq[:BURST_SIZE].astype(np.complex64)
    k = np.arange(BURST_SIZE)
    y = s * np.exp(-1j * np.pi / 2.0 * k)  # derotation -pi/2
    bits = (y.imag > 0).astype(int)
    if BIT_SIGN > 0:
        bits = 1 - bits                    # polarity (real capture: inverted)
    bits = np.concatenate([bits[1:], [bits[-1]]])  # shift -1 -> TSC@61
    return "".join(str(b) for b in bits)

def decode_block(fns, datas):
    """One-shot run: burst_source(4 BCCH bursts) -> demapper -> decoder ->
    socket_pdu(GSMTAP 4730). Official gr-gsm, no _post. fns/datas = parallel
    lists (frame numbers + strings of 148 bits)."""
    tb  = gr.top_block("bcch block")
    src = gsm.burst_source(fns, [TS] * len(fns), datas)
    src.set_arfcn(ARFCN)
    dm  = gsm.gsm_bcch_ccch_demapper(TS)
    dec = gsm.control_channels_decoder()
    snk = network.socket_pdu("UDP_CLIENT", GSMTAP_HOST, str(GSMTAP_PORT), 10000)
    tb.msg_connect((src, "out"), (dm, "bursts"))
    tb.msg_connect((dm, "bursts"), (dec, "bursts"))
    tb.msg_connect((dec, "msgs"), (snk, "pdus"))
    tb.start()
    tb.wait()                              # burst_source emits then posts 'done'

def udp_loop():
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind(("0.0.0.0", IQ_TEE_PORT))
    print(f"[grgsm] I/Q in udp:{IQ_TEE_PORT} -> GSMTAP {GSMTAP_HOST}:{GSMTAP_PORT} "
          f"arfcn={ARFCN} ts={TS}", flush=True)
    # NO filtering by mf: the demapper is fed with a COMPLETE 51-multiframe
    # (all positions). The gr-gsm demapper maps BCCH/CCCH itself by fn%51 and
    # extracts SI1/2/3/4 at the real scheduled position (TC).
    # (The demod produces noise at the FCCH/SCH positions, which the demapper ignores.)
    # Decoding is done per WINDOW of WINDOW_MF multiframes (not a single one): the
    # gr-gsm demapper needs a CONTIGUOUS run of several 51-multiframes to lock
    # its TC counter and extract the BCCH blocks. 1 isolated multiframe -> 0 decode.
    # 12 mf cover a complete TC cycle (0..7) -> SI1/2/3/4 included.
    WINDOW_MF = int(os.environ.get("WINDOW_MF", "12"))
    cur_mf  = None                         # current multiframe index (fn//51)
    fns, datas = [], []
    mf_count = 0
    npkt = nfed = ndec = 0
    while True:
        pkt, _ = rx.recvfrom(4096)
        npkt += 1
        if len(pkt) < 8 + BURST_SIZE * 4:
            if npkt <= 3:
                print(f"[grgsm] paquet court len={len(pkt)} (attendu>={8+BURST_SIZE*4})", flush=True)
            continue
        fn  = struct.unpack(">I", pkt[1:5])[0]
        raw = np.frombuffer(pkt[8:8 + BURST_SIZE * 4], dtype="<i2").astype(np.float32)
        bits = demod_burst(raw[0::2] + 1j * raw[1::2])
        if bits is None:
            continue
        nfed += 1
        if nfed <= 5 or nfed % 1000 == 0:
            print(f"[grgsm] burst #{nfed} fn={fn} mf={fn%51} pwr={np.mean(np.abs(raw)):.0f}", flush=True)
        # DEBUG: validates the demod on the live BCCH bursts (TSC7 @61). If the
        # match is not ~26/26, the demod is wrong on the current signal ->
        # explains 0 GSMTAP. Also compares the 8 TSCs to spot a shift.
        if (fn % 51) in (2, 3, 4, 5) and dbg_tsc[0] < 24:
            dbg_tsc[0] += 1
            mid = bits[61:87]
            best = max((sum(a == b for a, b in zip(mid, t)), i)
                       for i, t in enumerate(ALL_TSC))
            print(f"[grgsm][TSC] fn={fn} mf={fn%51} best TSC{best[1]}={best[0]}/26 "
                  f"(TSC7={sum(a==b for a,b in zip(mid, ALL_TSC[7]))}/26) mid={mid}", flush=True)
            # raw I/Q DUMP of the BCCH bursts for offline brute-force of the demod.
            dbg_dump.append((int(fn), raw.copy()))
            if len(dbg_dump) >= 8:
                import numpy as _np
                d = {}
                for i, (f, r) in enumerate(dbg_dump):
                    d[f"b{i}_iq"] = r.astype(_np.int16); d[f"b{i}_fn"] = f
                _np.savez("/opt/GSM/live_bursts.npz", **d)
                print(f"[grgsm][DUMP] 8 bursts BCCH live -> /opt/GSM/live_bursts.npz", flush=True)
                dbg_dump.clear()
        mfi = fn // 51
        if cur_mf is None:
            cur_mf = mfi
        if mfi != cur_mf:                  # new multiframe boundary
            mf_count += 1
            cur_mf = mfi
            if mf_count >= WINDOW_MF and fns:   # enough context -> decode the batch
                ndec += 1
                try:
                    decode_block(fns, datas)    # demapper -> GSMTAP (SI) if CRC ok
                    if ndec <= 5 or ndec % 20 == 0:
                        print(f"[grgsm] décode #{ndec} ({len(fns)} bursts / {mf_count} mf, "
                              f"fn {fns[0]}..{fns[-1]})", flush=True)
                except Exception as e:
                    print(f"[grgsm] decode_block err: {e}", flush=True)
                fns, datas = [], []
                mf_count = 0
        fns.append(fn)
        datas.append(bits)

def main():
    udp_loop()

if __name__ == "__main__":
    main()
