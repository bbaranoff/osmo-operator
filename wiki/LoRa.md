# The voice of inter-node calls on a LoRa radio link (`--lora`)

Between two osmo-operator nodes, `--wan` carries the whole inter-node link over IP
(WireGuard `wg0`, 10.99.0.1 ↔ 10.99.0.2). `--lora` keeps the **signalling** there (SS7 M3UA,
SIP) and sends the **voice** of the calls between the two nodes over a **LoRa radio link**
— two Heltec LoRa32 v3 (SX1262) under the RNode firmware — as the **raw GSM speech frames**
coded by the ROM vocoder of the phone (full-rate by default). No IP on the air, no codec in
the network: like TrFO in a real network, osmo-mgw is in RTP passthrough and the network
only transports. The frames are decoded by the ROM vocoder of the phone on the other node.
Two things make full-rate fit the link: only the frames that **carry speech** go on the air,
and a **semaphore** lets one side speak at a time, like a train radio in a tunnel.

```
            wg0 (WireGuard, IP): SS7, SIP — signalling, addresses, numbers
   +------------------------------------------------------------------+
Node 1                                                               Node 2
MS1 ~Um~ BTS → MGW ─HR RTP─▶ transcoder ═══ LoRa 868 MHz ═══ transcoder ─HR RTP─▶ MGW → BTS ~Um~ MS2
 (ROM vocoder codes)        (KISS frames of the RNode, 4 HR frames each)        (ROM vocoder decodes)
```

## Why not RTP over IP on the link

LoRa at SF7 / 500 kHz is **21.88 kbit/s on the air, half-duplex, shared by both nodes**.
Measured with RTP over IP (`LORA_MODE=ip`, `tnc0`): GSM-FR is 50 packets/s × 73 bytes
(33 of voice + 40 of IP/UDP/RTP) = 29 kbit/s per direction; our RNode monopolised the air
(49 packets/s, ~30 ms each), the other node never got to transmit, Asterisk received 0
packets. The headers weigh more than the voice.

| On the air | per direction | both | fits in 21.88 kbit/s |
|---|---|---|---|
| RTP/IP full-rate | 29 kbit/s | 58 | no |
| raw GSM-FR frames (33 B / 20 ms), both sides at once | 13.6 kbit/s | 27 | no |
| **raw GSM-FR frames, speech only, one talker at a time (default)** | 13.6 kbit/s while speaking | one side | **yes** |
| raw GSM-HR frames (14 B / 20 ms), 4 per LoRa frame (`--hr`) | 6 kbit/s | 12 | yes, ~68 % of the air, both at once |
| Um bursts (TRXD) | > 250 kbit/s | | no, and the GSM timing would not survive |

A LoRa frame is `'V' | seq | n | len | n × len bytes` (4 frames of 33 = 136 bytes per 80 ms).
The receiver plays the frames at 20 ms after a jitter buffer of one LoRa frame (3 at most).
One call at a time on the link; a second inter-node call stays on IP (and is thus silent).

**Speech gate (VAD).** A GSM 06.10 frame carries the quantised block maximum of its residual
(`xmaxc`, four 6-bit fields) that can be read without decoding: 0-3 in the pauses, 12-40 in
speech (measured on Asterisk's announcements). Frames under the threshold (`--vad 8`) are not
sent, with a 160 ms hangover so word endings are not clipped; the last partial LoRa frame of a
sentence is flushed after 100 ms. While one side listens it sends nothing at all.

**Semaphore.** The first side with speech sends `SEIZE` (`'C' | seq | 1`) and holds the
channel; the other side drops its own frames and listens until `RELEASE` (`'C' | seq | 2`,
sent after 400 ms of silence) or 1.5 s without any frame (a lost RELEASE). If both seize at
once, the node started with `--priority` (node 1) keeps the channel, the other yields. The
transcoder logs every transition (`canal : FREE -> MINE (parole, SEIZE envoye)`).
Verified in loopback between two transcoders fed with real speech: while A speaks, B's 126
frames are dropped and B receives all of A's; after A's RELEASE, B speaks and A receives.

## What the stock RNode firmware allows: store-and-forward

Measured A/B between the two Heltec (both directions, 10 s at 12.5 LoRa frames/s of 136
bytes): **~2 LoRa frames/s get on the air**, whatever is written to the module, with the
module reporting CSMA band 2. The RNode firmware widens its CSMA contention window with its
own airtime (band 1 up to 7 %, then 15-29, 30-44, 45-59 slots of 24 ms before each packet),
flushes its queue in bursts and silently drops what overflows. That is 2.2 kbit/s of goodput:
no GSM codec fits live (FR 13.6 kbit/s, HR 6). The CSMA parameters are compile-time
constants of the firmware.

So the talkie is **store-and-forward** (`--ptt manual`, the default): `take` in the mobile's
VTY records what the phone says (ROM vocoder frames, 60 s at most), `release` sends the
recording as one message — SEIZE, then the LoRa frames at the pace the module accepts
(`CMD_READY` polled before each one), then RELEASE — and the other node plays the whole
message to its phone when the RELEASE arrives. 5 s of speech is 63 LoRa frames, about 30 s
on the air. `--ptt live` keeps the frames going out in real time while the channel is held
(choppy with the stock firmware); `--ptt auto` is the VOX.

## One command

```bash
sudo ./start.sh --lora 1 --bts-classique --ms      # node 1
sudo ./start.sh --lora 2 --bts-classique --ms      # node 2
sudo ./start.sh --lora 1 --lora-port=/dev/ttyUSB1  # serial port of the RNode (default: first CP210x / CH9102)
```

`--lora N` adds `--no-sidecar`, `--wan --node N --hub-ip 10.99.0.1` and the WAN table
`1:10.99.0.1:11 2:10.99.0.2:22` (`LORA_WAN_NODES` for another plan), then starts
`tools/osmo-hr-transcodeur.py --lora PORT --codec fr` (`--priority` on node 1; `--codec hr`
with `--hr`). The transcoder sits on the SIP leg between osmo-sip-connector and Asterisk; for
a call **with the other node** it puts the speech frames of the MGW on the air instead of
handing them to Asterisk, and gives Asterisk a media-less FR leg (Asterisk still routes the
call over the trunk, so the signalling is unchanged). Without `--hr`, local calls are left
untouched (no transcoding at all). A call is "with the other node" when:

- **outgoing**: the number dialled starts with the code of another node of `/etc/osmo-wan.conf`
  (`22200101` from node 1);
- **incoming**: the INVITE from Asterisk carries `X-Osmo-WAN`, set by the `[wan_in]` dialplan
  (`network/setup-wan-mesh.sh`, pre-dial handler `[wan-hdr]`).

With `--hr`, local calls keep the HR ↔ FR transcoding by libosmogapk (Asterisk knows no HR).

The RNode must not be held by `tncattach`: `--lora` removes `tnc0` if present. The SMS relay
stays on wg0.

## The old plan: IP on the link (`LORA_MODE=ip`)

`LORA_MODE=ip ./start.sh --lora N` attaches the RNode as `tnc0` (`network/setup-lora-link.sh`,
`tncattach`, 10.200.0.N/24) and routes the payload flows (RTP, SMS relay) through it with
`network/setup-lora-payload.sh` (fwmark 0x10, DNAT to the LoRa peer). It validates the IP
path and carries SMS; voice does not fit, see above.

```bash
./network/setup-lora-link.sh --info               # rnodeconf -i: frequency, bandwidth, SF, power
sudo ./network/setup-lora-link.sh up --node 1
./network/setup-lora-link.sh --status              # tnc0, route, TX/RX counters
sudo ./network/setup-lora-link.sh --off
```

Parameters of the verified modules (set with `rnodeconf`): 868.0 MHz, bandwidth 500 kHz, SF7,
CR5, 17 dBm, **21.88 kbit/s on the air** (SF7 is the fastest the RNode firmware offers).

## Self-tests

```bash
/root/.env/bin/python3 tools/osmo-lora-voice.py --loop     # KISS + framing + 20 ms playout, no radio
/root/.env/bin/python3 tools/osmo-lora-voice.py --tx       # sends a test pattern on the air for 4 s
```

## What gets installed

`tncattach` (markqvist, tag 0.1.9) compiled from source, `rns` 1.5.7 (`rnodeconf`, `rnsd`,
`rnstatus`, pyserial) in the venv `/root/.env` with symlinks in `/usr/local/bin`, and
`wireguard-tools` in the apt list: by the Dockerfile and by `install.sh`
(`install_modules/50-build.sh`). The two nodes also need `wg0` ([WAN](WAN.md)).
