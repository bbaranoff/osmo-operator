# SMS payload over ISM radio, the rest over IP (`--payload-ism`)

Between two machines running osmo-operator, `--wan` already carries the whole
inter-node link over IP: SS7 signaling, SIP voice, and the SMS relay
(`scripts/sms-interop-relay.py`) which carries the message text in a JSON over
TCP. The `--payload-ism` option keeps all of that over IP **except the SMS content**:
the text travels over an **ISM-band radio link** (433 / 868 / 915 MHz,
2.4 GHz, license-free), while the two relays still coordinate over TCP.

```
         IP (--wan): SS7, SIP, addresses, MSISDN, IMSI, SC-address, + a TOKEN
   ┌────────────────────────────────────────────────────────────────┐
Node 1                                                             Node 2
   │   SMS text ──────────────── ISM radio ──────────────────▶ SMS text
   └────────────────────────────────────────────────────────────────┘
```

## How it works

The SMS relay already extracts the text from the TPDU of a mobile-originated SMS to
reinject it as mobile-terminated on the other node. With `--payload-ism`:

1. **Transmission.** The relay draws a correlation token, transmits the text over the
   ISM radio stamped with that token, and sends over TCP only the token (plus the
   addresses). The TCP text field goes out empty.
2. **Reception.** The other relay receives the TCP JSON, sees `payload_via=ism`, and
   waits on the radio link for the text carrying that token before injecting the MT.

If the radio fails on transmission, the relay falls back to IP for that SMS (it never
stays silent). If the text does not arrive over radio within the timeout
(`recv_timeout`, 30 s by default), reception answers with an error.

The radio link is decoupled from the hardware: `scripts/ism_payload.py` talks to
the **data interface** of your radio, frames the text into a single JSON line with
a CRC32 (a truncated or corrupted frame is ignored), and correlates by token.

## The backends

You choose the backend with `network/setup-payload-ism.sh`, which writes the
`[payload]` section of `sms-routing.conf` (read by the relay).

| backend | for what | setup |
|---|---|---|
| `serial` | an ISM module on UART (LoRa, RFM69, CC1101, HC-12…) on `/dev/tty*` | `sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600` |
| `exec` | an SDR pipeline you provide (HackRF/LimeSDR/USRP + GNU Radio, rtl_433…) | `sudo ./network/setup-payload-ism.sh --exec --tx-cmd … --rx-cmd …` |
| `fifo` | two named pipes, to hook up your radio some other way (`socat`…) | `sudo ./network/setup-payload-ism.sh --fifo --tx /tmp/ism_tx --rx /tmp/ism_rx` |
| `loopback` | try the SMS chain **without radio**, on a single machine | `sudo ./network/setup-payload-ism.sh --loopback` |

For the `exec` backend, `setup-payload-ism.sh --exemples` drops two templates
`/opt/GSM/ism/ism_tx.sh` and `ism_rx.sh`: `ism_tx.sh` receives a frame (a JSON
line) on its standard input and must transmit it; `ism_rx.sh` must write each
received frame to its standard output. Until they are filled in with your
radio chain, the text does not get through.

## Launch

On **each** node, with the WAN already in place:

```bash
# 1. set up the radio link (once, or redone by start-direct)
sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600

# 2. launch the bench: WAN over IP + payload over ISM
sudo ./start-direct.sh --wan --payload-ism
```

`--payload-ism=serial` (or `=exec`, `=fifo`, `=loopback`) additionally writes the
`[payload]` section at launch, with the device/commands taken from the
environment: `ISM_SERIAL`, `ISM_SERIAL_BAUD`, `ISM_TX`, `ISM_RX`,
`ISM_TX_CMD`, `ISM_RX_CMD`. Without a backend, `--payload-ism` reuses the section
already written.

To go back to text over IP: `sudo ./network/setup-payload-ism.sh --off`.

## Verify without radio

```bash
python3 scripts/ism_payload.py --selftest                 # in-memory loop
python3 scripts/ism_payload.py --selftest --link fifo \
        --tx /tmp/ism_a --rx /tmp/ism_b                   # loop over pipes
sudo ./network/setup-payload-ism.sh --loopback            # full SMS chain, one node
```

The self-test sends three texts (including 140 bytes and accented characters) and checks the
rejection of a frame with a bad CRC.

## The `[payload]` section of `sms-routing.conf`

```ini
[payload]
mode = ism                 ; ism = text over radio; absent/other = text over IP
link = serial              ; serial | exec | fifo | loopback
serial = /dev/ttyUSB0      ; (serial) the UART device
; tx = /tmp/osmo_ism_tx    ; (fifo) transmit pipe
; rx = /tmp/osmo_ism_rx    ; (fifo) receive pipe
; tx_cmd = /opt/GSM/ism/ism_tx.sh   ; (exec) transmit command
; rx_cmd = /opt/GSM/ism/ism_rx.sh   ; (exec) receive command
recv_timeout = 30          ; wait for the text over radio before failing (s)
```

## Regulatory

Only transmit on an ISM band and power allowed where you are (433 and
868 MHz in Europe, 902-928 MHz in region 2, 2.4 GHz), or into a dummy load / Faraday
cage. It is your responsibility as the bench's operator.

## Files

| file | role |
|---|---|
| `scripts/ism_payload.py` | the ISM payload link: backends, frame + CRC, correlation by token, self-test |
| `scripts/sms-interop-relay.py` | SMS relay: token over TCP, text over radio when `[payload] mode=ism` |
| `network/setup-payload-ism.sh` | writes `[payload]`, sets the serial baud rate, drops the SDR templates, self-test |
| `start-direct.sh` | the `--payload-ism[=backend]` option |
