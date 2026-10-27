# SS7 console — quick start

Everything lives in `navigation/`. No dependency beyond the distribution's
python3. Nothing is hard-coded: point codes, hub, ports and subscribers are read
from the containers and from the repository's configurations.

## 1. In thirty seconds

    cd /opt/GSM/osmo-operator
    sudo ./launch/start-docker.sh --wan --operators 2 --hub-ip 192.168.1.49   # the lab
    ./ss7-console.py                                                          # the diagram

The diagram opens. Move with the **arrow keys**, open with **Enter**, go back
with **Escape**. `q` quits.

## 2. Keys

| Key | Effect |
|---|---|
| arrows | move from box to box, in the space of the diagram |
| Enter | open the menu of the selected element |
| Escape | go back; **inside a VTY: close THIS VTY** and return to the diagram |
| Tab | next element |
| `v` | open the element's VTY directly |
| `s` | SS7 scripts (MAP operations) |
| `a` | SS7 audit (DAUD) of a point code |
| `c` | connect / disconnect the console's M3UA link |
| `j` | M3UA link journal |
| `r` | reload the topology |
| `?` | help |

Inside a VTY: `Enter` sends, up/down replay the history, PageUp/PageDown
scroll, `Escape` closes the session. Other VTYs stay open: one session per
port, independent.

## 3. What the diagram shows

    SS7 CONSOLE ---M3UA--- INTER-STP (hub)
                                |
                +---------------+---------------+
             OP1 - STP                       OP2 - STP
             1.11.2                          1.21.2
                |                               |
       STP  MSC/VLR  HLR  BSC  BTS  MGW  SGSN  GGSN  ...

Each service box carries its VTY port. Colours follow the family: SS7, core,
subscribers, radio, media, data.

## 4. Without the interface: the command line

    ./ss7-console.py list                 inventory (PC, hub, SCCP, VTY)
    ./ss7-console.py ops                  catalogue of MAP operations
    ./ss7-console.py vty 1 4258 "show subscribers all"
    ./ss7-console.py audit 1.11.1         the SS7 "ping" (DAUD -> DAVA/DUNA)
    ./ss7-console.py map sri-sm --pc 1.11.6 msisdn=600101 sc_addr=600999
    ./ss7-console.py serve                MAP responder (simulated HLR)

`vty <n>` accepts the operator number or the container name.

## 5. MAP operations

| Key | Operation | Opcode | Target SSN |
|---|---|---|---|
| `sri-sm` | sendRoutingInfoForSM | 45 | 6 (HLR) |
| `sri` | sendRoutingInfo | 22 | 6 |
| `ati` | anyTimeInterrogation | 71 | 6 |
| `sai` | sendAuthenticationInfo | 56 | 6 |
| `send-imsi` | sendIMSI | 58 | 6 |
| `psi` | provideSubscriberInfo | 70 | 7 (VLR) |
| `ul` | updateLocation | 2 | 6 |
| `raw` | raw invoke (opcode + hex parameter) | - | - |

The console is a **real** SS7 point: it attaches to the inter-STP over M3UA on
SCTP, dynamically registers a routing key for its point code (RKM), goes
ASP_ACTIVE, then sends TCAP/MAP that crosses the hub like the operators'
traffic. Each send can be exported as a standalone Python script
(`navigation/scripts/<operation>-<timestamp>.py`).

## 6. The responder: a complete MAP round trip

Osmocom makes MSC and HLR talk **GSUP**, not MAP: an SRI-SM sent to the real HLR
finds nobody. The responder fills that gap by answering with the data of the
REAL HLR (read over VTY), through the real hub.

    # terminal A
    ./ss7-console.py serve
    # terminal B
    ./ss7-console.py map sri-sm --pc 1.11.6 msisdn=600101 sc_addr=600999

    result (opcode 45):
       IMSI                         001010001000001
       Service node                 +600101

## 7. Diagnostics and tests

    ./navigation/ss7-diag.py             full SS7 diagnostic
    ./navigation/ss7-diag.py --rapide    without M3UA or MAP
    ./navigation/test-console.sh         runs EVERY command, one log per test

`ss7-diag.py` checks, in the order a failure is read: environment (SCTP),
topology inherited from the configs, STP/MSC/BSC/HLR of each operator, SCTP
association to the hub, attachment of the console as ASP, audit of all known
point codes, then a real MAP round trip. The exit code is the number of
failures.

`test-console.sh` writes one file per command in
`navigation/logs/<timestamp>/` (override with `LOGDIR`), plus a `rapport.txt`.

## 8. Lab behaviour to know about

- **The M3UA link from the host only lives a few seconds.** The inter-STP stops
  serving an association coming from the host after ~3 s, and the SCTP
  association expires around 35 s. The console renews it by itself before each
  exchange (~0.3 s): invisible, but it explains an occasional "no answer"
  followed by a second attempt that works.
- **The hub refuses the "Service Indicators" parameter** in a routing key
  (registration status 9). It is therefore omitted.
- **The console proposes its own routing context**: otherwise the hub returns
  the same context to two different ASPs and, in `traffic-mode override`, the
  last one attached steals the first one's traffic (the first destination goes
  DUNA).
- **DATA goes out on SCTP stream 1**: stream 0 is reserved for management, and
  a DATA on it is refused ("Invalid Stream Identifier").
- **Point codes are in ITU 3-8-3 format**: `a.b.c` with a and c from 0 to 7,
  b from 0 to 255. `1.11.60` does not exist: it would be received as `1.15.4`.
- The console's point codes (`1.11.7`, `1.11.6`...) leave dynamic `PROHIB`
  routes in the operator STPs when it closes: this is normal, they go back to
  `avail` when it returns.

## 9. Modules

| File | Role |
|---|---|
| `topo.py` | inventory: containers, env, `/etc/osmocom/*.cfg`, VTY ports |
| `vty.py` | persistent VTY sessions through `docker exec` |
| `diagram.py` | the diagram and arrow-key spatial navigation |
| `tui.py` | the curses interface (diagram, menus, forms, VTY) |
| `ber.py` | minimal BER/DER |
| `sccp.py` | SCCP UDT/UDTS, addresses, global titles, TBCD |
| `tcap.py` | TCAP begin/end, invoke, returnResult, returnError, AARQ/AARE |
| `mapops.py` | MAP catalogue: encoders, decoders, errors |
| `m3ua.py` | M3UA ASP over SCTP: ASPUP, RKM, ASPAC, DATA, heartbeat |
| `ss7.py` | the layer that ties everything together, and the readable report |
| `responder.py` | MAP responder backed by the real HLR |
| `quickcmd.py` | useful VTY commands, per daemon |
| `ss7-console.py` | entry point (diagram + sub-commands); `./ss7-console.py` at the repository root wraps it |
| `ss7-diag.py` | full diagnostic |
| `test-console.sh` | test of each command, with logs |

## 10. Troubleshooting

| Symptom | Probable cause |
|---|---|
| `aucun inter-STP connu` (no known inter-STP) | lab stopped, or `--hub-ip` never given to `start-docker.sh` |
| `le conteneur ... ne tourne pas` (container not running) | `docker ps` no longer sees it |
| `VTY ... injoignable` (VTY unreachable) | the daemon is not running in that container |
| `Aucune reponse` (no answer) to a MAP | nobody listens on that SSN: run `serve` |
| arrows have no effect | terminal in normal cursor mode (handled), otherwise `TERM=xterm` |
| `DUNA` on a point code | the ASP of that destination is not attached to the hub |
