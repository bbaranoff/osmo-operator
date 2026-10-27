#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# tools/grgsm_relay_decode.py - gr-gsm decoder on the relayed CONTINUOUS I/Q
# (full-grgsm mode). Reads the BTS I/Q relayed by calypso-ipc-device (UDP 5810,
# fc32), feeds it to the complete gr-gsm receiver (gsm.receiver: FCCH/SCH
# sync + GMSK demod), decodes the BCCH/CCCH and sends the L2 as GSMTAP to
# the shunt listener (4730) -> feed_si -> a_cd -> the mobile (on osmocon) camps.
#
# It is a DECODER (not a transceiver): no trxcon needed. The chain is the one
# of grgsm_decode but with a UDP source instead of a file.
#
#   udp_source(5810, fc32) -> lpf -> gsm.receiver(osr) -> C0 bursts ->
#       gsm_bcch_ccch_demapper -> control_channels_decoder -> GSMTAP(4730)
#
# osr MUST match the SPS of osmo-trx (tx-sps=1 -> osr=1). If the sync does not
# lock at osr=1, switch osmo-trx to SPS=4 and CALYPSO_TRX_OSR=4.
import os, sys

from gnuradio import gr, network, filter
from gnuradio.filter import firdes
from gnuradio.fft import window
from gnuradio import gsm

# OSR = oversampling seen by gsm.receiver. It needs ~4 to lock the FCCH/SCH
# and the GMSK timing recovery. The relayed I/Q is at 1 SPS (osmo-trx
# tx-sps=1) -> it is RESAMPLED 1->OSR in the flowgraph (no device surgery,
# no SPS=4 on the osmo-trx side).
OSR        = int(os.environ.get("CALYPSO_TRX_OSR", "4"))
IN_SPS     = int(os.environ.get("CALYPSO_TRX_IN_SPS", "1"))   # SPS du relais (osmo-trx)
SYM_RATE   = 1625000.0 / 6.0                       # 270833.33 Hz
SAMP_RATE  = SYM_RATE * OSR                         # rate après resampling
RX_PORT    = int(os.environ.get("CALYPSO_TRX_IQ_RX_PORT", "5810"))
GSMTAP_HOST = os.environ.get("GSMTAP_HOST", "127.0.0.1")
GSMTAP_PORT = int(os.environ.get("CALYPSO_SHUNT_GSMTAP_PORT", "4730"))
TS         = int(os.environ.get("TS", "0"))

tb = gr.top_block("grgsm relay decode")

# Source: relayed continuous I/Q (fc32, 625 samples/datagram = 5000 B). src_zeros
# -> continuous stream when there is no data (the receiver does not stall).
src = network.udp_source(gr.sizeof_gr_complex, 1, RX_PORT,
                         0, 5000, False, True, False)

# Resampling 1->OSR (IN_SPS->OSR): gives gsm.receiver the ~4 SPS it expects.
resamp = filter.rational_resampler_ccc(interpolation=OSR, decimation=IN_SPS)

lpf = filter.fir_filter_ccf(1, firdes.low_pass(
    1, SAMP_RATE, 125e3, 5e3, window.WIN_HAMMING, 6.76))

rx  = gsm.receiver(OSR, [0], [])              # cell_allocation [0], tseq []
dm  = gsm.gsm_bcch_ccch_demapper(TS)
dec = gsm.control_channels_decoder()
snk = network.socket_pdu("UDP_CLIENT", GSMTAP_HOST, str(GSMTAP_PORT), 10000)

tb.connect((src, 0), (resamp, 0))
tb.connect((resamp, 0), (lpf, 0))
tb.connect((lpf, 0), (rx, 0))
tb.msg_connect((rx, 'C0'), (dm, 'bursts'))
tb.msg_connect((dm, 'bursts'), (dec, 'bursts'))
tb.msg_connect((dec, 'msgs'), (snk, 'pdus'))

print("[grgsm-relay-decode] I/Q udp:%d (osr=%d, %.0f Hz) -> GSMTAP %s:%d -> feed_si"
      % (RX_PORT, OSR, SAMP_RATE, GSMTAP_HOST, GSMTAP_PORT), flush=True)

tb.start()
try:
    tb.wait()
except KeyboardInterrupt:
    tb.stop(); tb.wait()
