# osmo-operator — architecture

How the pieces fit: one PLMN on one machine, the emulated handset, and the
flows of a location update, an SMS and a call.

← [README](../README.md) · Details: [wiki/Reference](../wiki/Reference.md), [README-grgsm](README-grgsm.md), [README-dsp](README-dsp.md), [README-ss7](README-ss7.md), [README-lte](README-lte.md)

## The whole bench

```mermaid
flowchart TB
    subgraph HANDSET["emulated handset"]
        MOB["osmocom-bb mobile<br/>layers 2/3"]
        OSC["osmocon"]
        QEMU["qosmo: qemu-system-arm -M calypso<br/>layer1.highram.elf"]
        L1["layer 1<br/>gr-gsm (in QEMU) or C54x mask ROM (c54x_exe)"]
        MOB -->|L1CTL| OSC --> QEMU <--> L1
    end
    PONT["bridge<br/>pont.py / pont_dsp.py"]
    L1 <--> PONT
    subgraph RAN["radio access"]
        BTS0["osmo-bts-trx<br/>BTS 0, Cell 6001"]
        BTS1["BTS 1 (faketrx)<br/>Cell 6012"]
        BSC["osmo-bsc"]
        PCU["osmo-pcu"]
    end
    PONT <-->|"TRXD 5700-5702"| BTS0
    BTS0 -->|Abis/IP| BSC
    BTS1 -->|Abis/IP| BSC
    BTS0 --- PCU
    subgraph CORE["core network"]
        STP["osmo-stp :2905"]
        MSC["osmo-msc"]
        HLR["osmo-hlr"]
        MGW["osmo-mgw"]
        SGSN["osmo-sgsn"] --> GGSN["osmo-ggsn"]
        SIPC["osmo-sip-connector"] --> AST["Asterisk"]
        SMSC["proto-smsc-daemon"]
    end
    BSC -->|SCCP| STP
    MSC -->|SCCP| STP
    MSC -->|GSUP| HLR
    MSC -->|MGCP| MGW
    MSC -->|MNCC| SIPC
    HLR -->|GSUP| SMSC
    PCU -->|"Gb (NS/BSSGP)"| SGSN
    STP <-.->|"M3UA :2908, multi-operator"| INTER["inter-STP"]
    MSC <-.->|"SGs, CSFB"| MME["open5gs MME (4G)"]
```

Everything in one operator talks over `127.0.0.1`. The local STP listens on
`127.0.0.1:2905` straight away, without waiting for the Docker interface.

With `--bts`, the Calypso of QEMU runs the `trx` firmware and the host
`transceiver` application instead of `mobile` and the bridge: it is the radio
of BTS 0, and a second Calypso camps on it over the air (`pont/air.py`).

## Location update and authentication

```mermaid
sequenceDiagram
    participant MS as mobile
    participant BTS
    participant BSC
    participant MSC
    participant HLR
    MS->>BTS: RACH
    BTS->>MS: IMMEDIATE ASSIGNMENT (SDCCH)
    MS->>MSC: LOCATION UPDATING REQUEST
    MSC->>HLR: GSUP send auth info
    HLR-->>MSC: RAND, SRES, Kc (deterministic RAND on the bench)
    MSC->>MS: AUTHENTICATION REQUEST
    MS-->>MSC: AUTHENTICATION RESPONSE
    MSC->>BSC: CIPHER MODE COMMAND (A5/1, Kc)
    BSC->>MS: CIPHERING MODE COMMAND
    MS-->>BSC: CIPHERING MODE COMPLETE
    MSC->>HLR: GSUP update location
    MSC->>MS: LOCATION UPDATING ACCEPT (TMSI)
```

The A3A8 patches (`patches/*-force-rand-toy.patch`) make RAND deterministic,
so a run is reproducible from one boot to the next.

## SMS

```mermaid
sequenceDiagram
    participant A as MS (sender)
    participant MSC as MSC (sms-over-gsup)
    participant HLR
    participant SMSC as proto-smsc-daemon
    participant B as MS (recipient)
    A->>MSC: SMS MO
    MSC->>HLR: GSUP MO-forwardSM
    HLR->>SMSC: GSUP MO-forwardSM
    SMSC->>HLR: GSUP MT-forwardSM
    HLR->>MSC: GSUP MT-forwardSM
    MSC->>B: SMS MT
```

SMPP is on `:2775` with a test ESME. Between operators, `scripts/sms-interop-relay.py`
forwards over TCP 7890 ([README-ss7](README-ss7.md)).

## Voice

```mermaid
flowchart LR
    MS1["MS"] --> BTS1["BTS"] --> BSC1["BSC"] --> MSC
    MSC -->|MNCC| SIPC["osmo-sip-connector"] -->|"SIP :5060"| AST["Asterisk<br/>FR / HR"]
    AST --> SIPC2["osmo-sip-connector"] -->|MNCC| MSC2["MSC"] --> BSC2["BSC"] --> BTS2["BTS"] --> MS2["MS"]
    MSC <-->|MGCP| MGW["osmo-mgw (RTP)"]
```

`600` is the Asterisk echo test: what the mobile sends comes back to it
([README-tests](README-tests.md)). On the DSP chain the FR codec runs either in
the ROM (`--vocoder-rom`, default) or on the host with gapk (`--gapk`).

## GPRS / EDGE

BSSGP/NS from the PCU to osmo-sgsn, then PDP contexts through osmo-ggsn
(GTPv1-C/U). On the DSP chain the GPRS modem is brought up by
`scripts/egprs-dsp.sh` ([README-dsp](README-dsp.md#gprs--egprs-on-the-dsp-bench)).

## Where the code lives

| path | role |
|---|---|
| `start.sh` / `start-native.sh`, `startup_scripts/` | the launcher (native, container, ISO) |
| `launch/start-docker.sh`, `compose.sh` | Docker, multi-operator |
| `launch/start-interstp.sh`, `set_stp_ip.sh` | the SS7 hub and node addressing |
| `network/` | WAN table, mesh, firewall, VirtualBox, ISM |
| `lib/gabarits.sh`, `configs/`, `generate_configs.sh`, `globals.conf` | config templates and the network settings |
| `pont/` | the radio bridges (`pont.py`, `pont_dsp.py`, `air.py`, `airmesh.py`) |
| `scripts/` | run-time services and diagnostics (SMS relay, audio, call diag, EGPRS, Magnetite) |
| `checks/` | read-only health checks |
| `iso_modules/`, `build-iso.sh` | the ISO and SD image |
| `packaging/` | `.deb` cache and standalone packages |
| `/opt/GSM/qosmo` | QEMU fork, `run.sh`, `run_modules/`, `tmux_modules/` |
| `/opt/GSM/c54x_exe`, `/opt/GSM/grgsm_exe` | external layer 1s |

The full repository layout is in the [README](../README.md#repository-layout).
