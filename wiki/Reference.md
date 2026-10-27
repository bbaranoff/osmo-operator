# osmo-operator — reference

osmo-operator is a complete GSM operator (Osmocom core, BTS, Asterisk, SMSC)
plus an **emulated Calypso handset** on one machine: no radio hardware, no SIM
card, no phone. The handset runs the real OsmocomBB `layer1` firmware on an
emulated TI Calypso baseband, camps on the cell, authenticates, ciphers, sends
SMS and holds a voice call. The same bench also ships as a live ISO with a 4G
core (open5gs + srsRAN, CSFB) and a postmarketOS phone VM, and can be meshed
with other machines over SS7. This page is the full reference; the top-level
[README](../README.md) is the index.

**Contents**

- [1. The live ISO](#1-the-live-iso)
- [2. Quick start from source](#2-quick-start-from-source)
- [3. The layer-1 chains](#3-the-layer-1-chains)
- [4. Profiles](#4-profiles)
- [5. Building the images](#5-building-the-images)
- [6. Daily use](#6-daily-use)
- [7. Diagnosing the radio side](#7-diagnosing-the-radio-side)
- [8. The qosmo launcher](#8-the-qosmo-launcher)
- [9. One PLMN](#9-one-plmn)
- [10. PHY modes](#10-phy-modes)
- [11. Multi-operator and SS7](#11-multi-operator-and-ss7)
- [12. Other extensions](#12-other-extensions)
- [13. Related documents](#13-related-documents)
- [Known issues](#known-issues)

---

## 1. The live ISO

[![Build ISO](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml)

Download links and checksums: [doc/README-iso.md](../doc/README-iso.md). The
GitHub release ships the image in `.part-NN` pieces (release files are capped at
2 GiB):

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c --ignore-missing SHA256SUMS
```

| | |
|---|---|
| **Live ISO password** | `osmo` |
| **postmarketOS phone password** | `147147` |
| **Minimum host** | x86_64, 8 GB RAM, 4 cores, nested virtualization in a VM |
| **Image identity** | `IMAGE_VERSION="OSMO_EGPRS_V2"` · `OSMO_ROLE=operator` · `OSMO_LITE=0` |

### 1.1 Run the image

The live root is a tmpfs (~6 GB in `toram` mode); logs and captures are bounded
and purged at every boot. The bench runs two QEMUs (Calypso + pmOS): in a VM,
**enable nested virtualization**, otherwise the phone VM falls back to software
emulation and becomes very slow.

**QEMU**

```sh
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm \
  -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

**VirtualBox**

1. New VM: Linux / Ubuntu 64-bit, 8 GB, 4 CPUs, 3D off.
2. System → Processor: tick *Nested VT-x/AMD-V*
   (if greyed out: `VBoxManage modifyvm "<name>" --nested-hw-virt on`).
3. ISO on the optical drive, no disk needed.
4. NAT port forward: host 8080 → guest 8080.

**VMware**: new VM from the ISO, Linux / Ubuntu 64-bit, 8 GB, 4 cores, tick
*Virtualize Intel VT-x/EPT or AMD-V/RVI*, skip Easy Install.

**USB stick** (hybrid ISO, boots UEFI or BIOS; on Windows use Rufus in
*DD Image* mode):

```sh
sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 1.2 Getting started

Three launchers are pinned in the dock. 2G and 4G are independent and can start
in any order; **launch the smartphone last**, once both networks are up.

| | Launcher | What it starts |
|:---:|---|---|
| <img src="https://raw.githubusercontent.com/bbaranoff/osmo-operator/main/data/osmo-launch.svg" width="32"> | **2G** — the red handset | The GSM core and the emulated radio: osmo-stp / bsc / msc / hlr / sgsn / ggsn / pcu, the Calypso under QEMU, the two BTS and the two osmocom-bb mobiles, Asterisk, the SMSC. |
| <img src="https://raw.githubusercontent.com/bbaranoff/osmo-operator/main/data/osmo-lte.svg" width="32"> | **4G** — the signal bars | open5gs, srsENB and srsUE over ZMQ, and the SGs interface to the MSC (CSFB). |
| 📱 | **Smartphone** — the Adwaita phone icon | The postmarketOS VM: oFono on the virtual modem, data on 4G, voice and SMS on 2G. |

From a terminal:

```sh
cd /opt/GSM/osmo-operator && sudo ./start-native.sh --dsp   # 2G handset on the Calypso DSP
sudo ./start-native.sh --menu                               # ask interactively
checks/diag-stp-operator.sh                                 # check that everything is in place
```

### 1.3 What's inside

**2G / GSM (Osmocom)**

- Full core: osmo-stp (M3UA, SCTP :2905), osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn (GTPv1-C/U), osmo-pcu, osmo-mgw (MGCP :2427).
- Two DCS1800 cells in LAC 1: BTS 0 (Cell ID 6001, BSIC 7) and BTS 1 (Cell ID 6012, BSIC 8), each on its own osmo-bts-trx.
- **A real emulated Calypso as layer 1**: `qemu-system-arm -M calypso -cpu arm946` ([qosmo](https://github.com/bbaranoff/qosmO)) runs `layer1.highram.elf`, loaded by `osmocon` exactly as on a C123. `pont/pont.py` turns bursts into I/Q for `fake_trx.py`, then `trxcon` and two osmocom-bb `mobile` instances on the terminal side.
- GPRS/EDGE: BSSGP/NS to the PCU, PDP contexts through osmo-ggsn.
- Voice: external MNCC → Asterisk (SIP :5060, FR/HR) via osmo-sip-connector.
- SMS: SMS-over-GSUP → proto-smsc-daemon, SMPP :2775 with a test ESME, inter-operator relay :7890.
- A3A8 with deterministic RAND (`*-force-rand-toy` patches): the bench is reproducible from one boot to the next.
- Live GSMTAP capture, ready for Wireshark.

**The DSP (the Calypso's TMS320C54x on TI's real mask ROM)**

- `./start-native.sh --dsp` (the default) hands layer 1 to the baseband's own DSP: a C54x core emulated outside QEMU ([c54x_exe](https://github.com/bbaranoff/c54x_exe)), running the mask ROM dumped from a real Calypso (PROM0-3, DROM, PDROM). `--grgsm` uses gr-gsm ([grgsm_exe](https://github.com/bbaranoff/grgsm_exE)) instead.
- ARM (QEMU) and DSP share the API RAM through `/dev/shm/calypso_api_ram` and run in lockstep, one TDMA frame at a time, over `/tmp/calypso_dsp.sock`. Downlink bursts reach the DSP's serial port (BSP) over UDP 6702 via `pont/pont_dsp.py`.
- The ROM does FCCH/SCH acquisition, BCCH decoding (SI1-4), camping, location update, SMS MO/MT, MO/MT calls with A5/1, speech audible both ways. Limitations: see [Known issues](#known-issues).

**4G / LTE (open5gs + srsRAN)**

- open5gs core (MME, SGW-C/U, SMF, UPF, PCRF, HSS…) on dedicated loopbacks, Prometheus :9090, WebUI :9999, MongoDB behind the HSS.
- PLMN 001/01, TAC 7. NAS null ciphering (EIA2/EIA1 + EEA0) on purpose: NAS reads in clear in Wireshark.
- srsENB (10 MHz, EARFCN 3350, band 7) and srsUE over ZMQ, no SDR. Milenage test subscriber IMSI 001010001000001; the UE gets an IP in a netns and reaches the Internet through NAT.

**CSFB**

- SGs between osmo-msc and the MME (:29118), mapping `TAI (001-01, TAC 7) → LAI (001-01, LAC 1)`.
- Combined EPS+IMSI attach: an incoming call is paged by the MME and the UE falls back to the BTS.
- Two subscribers (100101, 100102), one per cell, wired for an inter-cell call with fallback.

**postmarketOS (the phone)**

- x86_64 pmOS VM with a patched kernel (`CONFIG_PPP` enabled); prebuilt kernel in `/opt/user_interface/kernel/pmos/`.
- 4G data: NetworkManager → pppd (`ATD*99***1#`) → virtio-console `osmo.data` → `osmo-phonesim-banc.py` → UE netns → srsUE → srsENB → UPF → Internet.
- 2G voice and SMS: virtio-console `osmo.modem`, where `osmo-phonesim-banc.py` plays a 27.007 AT modem driven by oFono.
- Audio: two duplex PulseAudio chains (GAPK bridge to the osmocom-bb mobile, and an echo-cancelled chain).
- Result: data on 4G, voice and SMS on 2G, same identity — a CSFB handset's behaviour at modem level.

---

## 2. Quick start from source

### 2.1 From the published Docker image

```bash
sudo docker pull ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./launch/start-docker.sh
```

Then enter the container and bring the stack up:

```bash
sudo docker exec -ti osmo-operator-1 bash

cd /opt/GSM/osmo-operator
./start-native.sh --regen     # regenerate configs from the templates (first run)
./start-native.sh --stop      # make sure nothing is left over
./start-native.sh             # start the bench
```

`start-native.sh` attaches to tmux at the end: a live GSM network with a mobile
camped on it.

### 2.2 Native, without Docker

The repository installs directly on Ubuntu 24.04 (noble, the same base as the
Dockerfile):

```bash
sudo ./install.sh                  # everything: deps, sources, build, binaries, configs, desktop
./install.sh --list                # show the steps, do nothing
./install.sh --check               # what is already in place
sudo ./install.sh --reinstall      # replay everything
sudo ./install.sh --only bureau    # desktop icons and shortcuts only
```

The launcher is the same `./start-native.sh`, which delegates to
`/opt/GSM/qosmo/run.sh`. On a host with Docker, `./start-native.sh --docker …`
hands over to `launch/start-docker.sh`.

### 2.3 Stopping

```bash
./start-native.sh --stop      # stops the stack AND the DSP bench, with or without --dsp
./start-native.sh --status    # what is running
```

---

## 3. The layer-1 chains

Both chains run the same core network, the same BTS and the same `mobile`;
they differ in **who demodulates the air interface**.

| | **`--grgsm`** | **`--dsp`** (default) |
|---|---|---|
| Layer 1 | gr-gsm inside QEMU + `grgsm_exe` bridge | real TI mask-ROM C54x, **outside** QEMU |
| QEMU's job | ARM7 + gr-gsm layer 1 | ARM7 only (`CALYPSO_DSP_EXTERN=1`) |
| Bridge | `pont/pont.py` | `pont/pont_dsp.py` |
| Status | end to end: camping, LU, auth, A5/1, SMS, voice call | camping, SI1-4, LU, SMS, calls; every speech frame is flagged `B_BFI` |
| Use it for | getting work done | studying the real DSP |

```bash
./start-native.sh             # real C54x mask ROM (default)
./start-native.sh --dsp       # the same, explicitly
./start-native.sh --grgsm     # gr-gsm layer 1
```

### 3.1 Three trees, one QEMU

| tree | what it is |
|---|---|
| [`/opt/GSM/qosmo`](https://github.com/bbaranoff/qosmO) | the QEMU fork: `-M calypso`, ARM7TDMI + platform. Carries `run.sh`, `run_modules/`, `cfgs/`. The layer 1 is a `configure` option: `--enable-l1-grgsm` or `--enable-l1-dsp`. |
| [`/opt/GSM/c54x_exe`](https://github.com/bbaranoff/c54x_exe) | the TMS320C54x running **outside** QEMU on the real TI mask ROM (`rom/calypso_dsp.*.bin`). Compiles `qosmo`'s sources, does not copy them. |
| [`/opt/GSM/grgsm_exe`](https://github.com/bbaranoff/grgsm_exE) | the gr-gsm layer 1 outside QEMU. |

`qemu-system-arm -M help` names the layer 1 actually linked in:

| configure | `-M help` shows |
|---|---|
| (nothing) | `couche 1 : aucune` |
| `--enable-l1-grgsm` | `couche 1 : grgsm` |
| `--enable-l1-dsp` | `couche 1 : c54x` |

### 3.2 The gr-gsm chain

```mermaid
flowchart LR
    mobile["mobile (layer23)"] -->|L1CTL| osmocon
    osmocon -->|romload, serial pty| QEMU
    subgraph QEMU["qosmo (-M calypso)"]
        ARM["ARM7<br/>layer1.highram.elf"]
        L1G["gr-gsm layer 1"]
        ARM <--> L1G
    end
    QEMU <-->|"GSMTAP 4730 / SCH 4731"| PONT["pont/pont.py"]
    PONT <-->|"TRXD 5700-5702"| BTS["osmo-bts-trx"]
    BTS -->|Abis/IP| BSC
    BSC --> CORE["MSC / HLR / MGW / Asterisk"]
```

### 3.3 The DSP chain (`--dsp`)

`--dsp` does **not** select a different QEMU. The stack comes up exactly as in
gr-gsm mode (core, BTS, side-car, tmux) and only the four Calypso modules
(`qemu`, `pty`, `osmocon`, `l2`) are handed over to `c54x_exe/run.sh`, which
runs five steps of its own:

```
1. c54x_exe --arm     the DSP: /tmp/calypso_dsp.sock + shared API RAM,
                      DL bursts on UDP 6702
2. qemu-system-arm    the ARM + osmocom-bb layer1, gr-gsm layer 1 cut out
3. osmocon            romload on the serial pty, L1CTL relay
4. mobile             osmocom-bb layers 2/3
5. pont_dsp.py        TRXD 5700-5702 facing osmo-bts-trx, bursts down to the
                      DSP, uplink through the /dev/shm side-bands
```

```bash
./start-native.sh --dsp                   # the full stack, then the DSP bench
MODE=dsp PONT=1 /opt/GSM/c54x_exe/run.sh  # the mobile chain alone, no network
BANC_DSP=none ./start-native.sh --dsp     # the stack only, no DSP bench
```

`--dsp` starts **no bridge of its own**: `c54x_exe/run.sh` runs its own on
5700-5702 (step 5). A second one on the same ports would die on *Address already
in use*. Step details and variables: [Start-native](Start-native.md) § 8-dsp.

### 3.4 The Calypso as the BTS transceiver (`--bts` / `--osmo-trx`)

A third shape of the DSP chain: the emulated phone no longer camps on BTS#0, it
*is* BTS#0's radio. QEMU boots `trx.highram.elf` (the `trx` app of the
transceiver branch, tree `/opt/GSM/osmocom-bb-transceiver`), and the host app
`transceiver` from the same tree replaces both `mobile` and the bridge: it talks
L1CTL to the phone through osmocon and exposes the TRXD UDP interface
(5700-5702) that `osmo-bts-trx` expects. The rest of the stack (BSC, MSC,
side-car) comes up unchanged.

```
./start-native.sh --bts               # alias of --osmo-trx; implies --dsp; c54x_exe/run.sh runs with OSMO_TRX=1
./start-native.sh --bts --ms          # the BTS radio, then the second phone over the air (INSTANCE=2, see 3.6)
./start-native.sh --bts --ms --ts 2   # one Calypso TRX per timeslot: TS1 (TCH/F) served by a 3rd QEMU (OSMO_TRX_TS1=1, transceiver -2); --ts 1 = TS0 only
sudo armbian/build-armbian.sh         # SD image via github.com/armbian/build; --prepare, --no-stack, --board=
```

(`--ms` alone, or no option, is the usual mobile + bridge setup.)

What changes in `c54x_exe/run.sh` with `OSMO_TRX=1`: step 2 loads
`trx.highram.elf`, step 4 launches `transceiver` instead of `mobile`, step 4b
relaunches `osmo-bts-trx` when BTS#0 is absent (`OSMO_TRX_BTS_RELANCE=0` to
disable; it exits whenever its transceiver disappears, so wait for the old
process to finish its shutdown before `banc-trx`), step 5 (the bridge) is
skipped because the transceiver holds the same ports, and step 5b starts the
VSP audio bridge (`pont.vsp_audio`).

Variables: `OSMO_TRX_TS_MASK` / `OSMO_TRX_TX_MASK` (RX and TX timeslot masks;
`-m` only sets RX, `-M` sets TX), `OSMO_TRX_TCH=1` (default: one phone serving
TS0 and TS1, masks `0x03`, `CALYPSO_TRX_TX_SLOTS=2`), `OSMO_TRX_TS1=1` (a
second phone serves TS1: `INSTANCE=3`, `OSMO_TRX_PHONE=2`, `transceiver -2 -L
/tmp/osmocom_l2_3`), `OSMO_TRX_ARGS` and `TRANSCEIVER` (override the arguments
and the binary), `CALYPSO_BSP_TRX`, `CALYPSO_BSP_TRX_DELTA`,
`CALYPSO_BSP_TRX_OFFSET` (uplink frame-number calibration of the BSP),
`CALYPSO_BSP_TRX_UL=0` (disable the uplink bit prosthesis),
`MONTANT_ROM_TX_SB_RECODE` (SCH re-encoding, on by default in TRX mode).

The host app needs `patches/osmocom-bb-transceiver-qemu-bench.patch`, applied
by the Dockerfile and by `install_modules/40-patches.sh`: `--no-sync` (BTS mode
as soon as the phone resets, there is no cell to FBSB on inside QEMU),
`--ts-mask`, `--l1ctl`/`--base-port`, `-L PATH`, and `SETTSC`, `SETFORMAT`
(TRXD v0 answered) and `NOMTXPOWER` acknowledged, since `osmo-bts-trx` 1.10
treats them as critical. The firmware side of the patch: single TX window per
mask, `BTS_RX_LAG` margin, TA/AFC loops removed from the BTS sync task,
idempotent `BTS_MODE`.

Configuration that goes with it: `configs/osmo-bts-trx.cfg` has
`osmotrx fn-advance 20` / `rts-advance 5`; `configs/osmo-bsc.cfg` gets
`timeslot 1 phys_chan_config TCH/F` (`__TS1_PCHAN_BTS0__`, set by
`generate_configs.sh` when `OSMO_TRX=1`; `SDCCH8` otherwise) so the SDCCH comes
from the SDCCH/4 of TS0. Restart osmo-bsc for a config change to apply.

Logs: `/tmp/c54x-pont/dsp.log` (`[rom-tx] ... NB n, SB n, FB n`, `[ts0] mode
TRX`, `[rom-tx] SB recode`, `[ts0] prothese montante`), `osmocon.log`
(`STALE BURST` means bursts arriving outside their window).

### 3.5 The C123 screen and keypad under QEMU

`qosmo` emulates three SoC devices (`hw/arm/calypso/`): `calypso_armio.c` (the
ARMIO block at 0xFFFE4800: the 5x5 key matrix, IRQ 8), `calypso_i2c_ctrl.c`
(the I2C controller at 0xFFFE2800) and `calypso_st7558.c` (the 96x65 LCD, I2C
slave 0x3c). Any firmware app that draws and reads keys works: `rssi`, `menu`,
`hello_world`, `trx`.

- The screen is published in `/dev/shm/calypso_lcd` (`CALYPSO_LCD_SHM`) on
  every flush, and also on the QEMU graphic console (`-display sdl`).
- Keys arrive on the Unix datagram socket `/tmp/calypso_keys.sock`
  (`CALYPSO_KEYS_SOCK`): `press 5`, `release 5`, `tap menu 200`. Key names:
  `0`-`9`, `star`, `hash`, `menu`, `lsb`, `rsb`, `up`, `down`, `left`,
  `right`, `ok`, `power`. `CALYPSO_KEYS_DEBUG=1` traces them on stderr.
- `tools/osmo-c123-gtk.py` (run with `/usr/bin/python3`) shows the photo of
  the phone from `data/c123.jpg`, overlays the live LCD in the `lcd` zone of
  `data/c123-zones.json` and sends a press/release for each key clicked; the
  PC keyboard works too. `--calibrate` redraws the zones with the mouse.

```
FIRMWARE_APP=rssi bash /opt/GSM/c54x_exe/run.sh     # steps 1-3 only: DSP, QEMU, osmocon
/usr/bin/python3 tools/osmo-c123-gtk.py              # the phone window
echo "tap menu" | socat - UNIX-SENDTO:/tmp/calypso_keys.sock   # or by hand
```

### 3.6 Two Calypsos and the air between them

With `--bts` the emulated phone is the BTS radio, so a second emulated phone is
needed to be the mobile. `c54x_exe/run.sh INSTANCE=2` runs a complete second
chain (DSP, QEMU, osmocon, mobile) next to the first. It re-executes itself in
a private mount namespace where `/dev/shm` is the host's `/dev/shm/calypso2`,
so the hard-coded `/dev/shm/...` paths of c54x_exe and qosmo are unchanged; the
host's real `/dev/shm` stays readable at `/run/calypso-shm-hote`. Everything
else is shifted: `/tmp/c54x-pont2`, `/tmp/osmocom_l2_2`,
`/tmp/calypso_dsp2.sock`, gdb 1235/44445, keypad socket
`/tmp/calypso_keys2.sock`, BSP UDP port 6712, mobile VTY +100 (a derived copy
of `mobile_pont.cfg`).

The air is `pont/air.py`: each c54x_exe publishes the bursts its ROM emits in
the ring `calypso_tx_rom` (including the SB, dummy and FB bursts of a BTS, one
per frame in TRX mode), and each BSP accepts bursts in TRXDv0 over UDP. The
relay feeds A's ring to B's BSP and B's ring to A's BSP, tags bursts with their
timeslot, decodes the ASSIGNMENT COMMAND on the TS0 SDCCH/4
(`pont.gsm.xcch_decode`) to announce the TCH to the mobile's c54x_exe
(`calypso_tch_cfg`), and keeps relayed frame numbers continuous across a
restart of `banc-trx`. It is step 5 of instance 2 (`AIR=1`), in place of the
bridge, which must not touch 5700. With `OSMO_TRX_TS1=1`, `air.py` gets a third
endpoint (`--c-ring`, `--c-port`) for phone 2.

```
banc-trx          # instance 1: the BTS radio (restart it after a rebuild of c54x_exe or trx.highram)
banc-mobile       # instance 2: the mobile, plus the air; banc-mobile-stop / -status / -logs
c123-2            # its screen and keypad
```

The two instances are not slaved to each other: each runs real time (4.62 ms
per frame) and the mobile's BSP waits up to 40 ms for a late frame. Logs:
`/tmp/c54x-pont2/air.log` (`A->B n (NB SB DUMMY FB)`),
`/tmp/c54x-pont2/dsp.log`, `/tmp/c54x-pont2/mobile.log`. Over this path the
mobile does its location update and holds a call (`call 1 600` from the
mobile's VTY, echo test audible both ways).

---

## 4. Profiles

The layer-1 flag is independent of the **profile**, which chooses how many
base stations come up and how:

| profile | stack |
|---|---|
| `faketrx-qemu` (default) | core + BTS#0 QEMU + BTS#1 faketrx (alias `hybrid`) |
| `faketrx` | core + `fake_trx` + `trxcon` + `mobile` |
| `qemu` | the Calypso QEMU pipeline alone (alias `calypso`) |
| `noproc` | core only (alias `core`) |
| `virtphy` | core + osmo-bts-virtual + virtphy + mobile |
| `hw` | physical SDR |
| `virtual` | SS7 multi-operator via `ip netns` |

```bash
./start-native.sh faketrx
./start-native.sh --profile qemu
./start-native.sh --list        # show the plan without running it
./start-native.sh --dry-run     # walk through it with no side effects
```

---

## 5. Building the images

```bash
sudo ./build.sh                # build osmocom-nitb (apt-fast, compose v2, .deb cache)
sudo ./build.sh --no-cache     # recompile everything and rewrite the cache
sudo ./build.sh --arch=arm64   # cross-build through buildx + qemu-user-static
```

### 5.1 The build is a graph

`Dockerfile` is split into BuildKit stages, so independent compilations run
**at the same time**:

```
                 base   (apt, apt-fast, osmo-deb, configs)
                   |
        +----------+--------+---------+
    osmo-core    qemu      lte      node        <- IN PARALLEL
        |          |
   +----+-----+    |
  bb  grgsm-venv  l1
   +----+-----+---+
             |
       osmocom-nitb   (assembly)
             |
           debs       (FROM scratch: the .deb cache, for CI)
```

`bb`, `l1` and `grgsm-venv` depend on `osmo-core`: `osmocom-bb` links
`mobile`/`trxcon` against libosmocore, `c54x_exe` asks `pkg-config` for
`libosmocoding libosmocore`, and gr-gsm's CMake looks for both.

`--target osmocom-nitb` is **mandatory**: `debs` is the last stage in the file,
so without it Docker builds an empty image. `build.sh` and `compose.yaml` pass it.

### 5.2 The `.deb` cache

Everything the image compiles (libosmocore, osmo-\*, gapk, QEMU and its tree,
osmocom-bb, the gr-gsm venv, the firmware) comes out as a `.deb` through
`packaging/osmo-deb.sh` and stays **on the host**, in `/var/cache/osmo-debs`
(`OSMO_DEB_CACHE` to move it):

```bash
sudo ./build.sh              # 1st build: everything compiles, .deb go to the cache
sudo ./build.sh              # rebuild: dpkg -i, nothing compiles
sudo ./build.sh --no-cache   # recompile everything, rewrite the cache
./compose.sh debs            # what is in the cache
```

Each package carries **both** the installed files and the `/opt/GSM` source
tree, so a cached rebuild still gives a workshop you can read, patch and `make`
in.

Standalone `.deb`, to install without git:

```bash
./packaging/build-debs.sh          # -> packaging/dist/
sudo dpkg -i packaging/dist/*.deb  # refuses to install over a git clone at the same path
```

### 5.3 Docker Compose

```bash
sudo ./compose.sh build [--no-cache] [--lite] [--stp]
sudo ./compose.sh up [--ms 2] [--phy faketrx]    # hub + osmo-operator-1, HLR populated
sudo ./compose.sh down | ps | logs | shell
```

### 5.4 ISO images

`sudo ./build-iso.sh` does **one** docker build (`osmocom-nitb`) and derives
each rootfs from it: interstp, normal, lite (the normal one with the workshops
removed), desktop. On the installed disk the accounts are the ones from the
Calamares *Users* screen plus an unlocked root; LUKS is offered in the
partitioning choices; a *Graphics drivers* page offers `nvidia-driver-610`
when `lspci` sees a card. Details: [Build](Build.md), [ISO](ISO.md).

---

## 6. Daily use

### 6.1 tmux

```bash
docker exec -ti osmo-operator-1 tmux attach
docker exec -ti osmo-operator-1 tmux -S /tmp/osmocom_tmux attach -t osmocom
```

| key | window |
|---|---|
| `Ctrl-b 0` | faketrx |
| `Ctrl-b 1` | MS1 (trxcon + mobile) |
| `Ctrl-b 2` | Asterisk |
| `Ctrl-b 3` | SMSC (proto-smsc-daemon + relay) |
| `Ctrl-b w` | list all windows |
| `Ctrl-b d` | detach |

`--no-attach` starts without attaching; `osmo-banc.service` uses it.

### 6.2 VTY

| port | component |
|---|---|
| `4239` | OsmoSTP |
| `4242` | OsmoBSC |
| `4243` | OsmoMGW |
| `4254` | OsmoMSC |
| `4258` | OsmoHLR |
| `4247` / `4347` | MS#1 `mobile` (`--grgsm` / `--dsp`) |

```
OsmoMSC# show subscriber all
OsmoMSC# subscriber msisdn 10001 sms sender msisdn 10002 send Hello

OsmoHLR# subscriber imsi 001010000000001 show
OsmoHLR# show gsup-clients
```

Subscribers are provisioned automatically when the stack comes up, by
`qosmo/run_modules/21-abonnes-hlr.sh`, following the numbering plan; `--regen`
re-applies it.

### 6.3 Ports on the wire

| port | carries |
|---|---|
| `5700-5702` UDP | TRXD, between `osmo-bts-trx` and the bridge |
| `4729` UDP | GSMTAP, the Um interface |
| `4730` UDP | full SI set into the shunt (`opt-gsm/si_bridge.py`) |
| `4731` UDP | SCH BSIC/FN out of the gr-gsm receiver |
| `6702` UDP | DL bursts into the DSP BSP (`--dsp`) |
| `8080` TCP | the web dashboard (`osmo-egprs-web`) |
| `8081` TCP | the I/Q spectra (`fft-web/fft_web.py`) |

### 6.4 Wireshark

Started automatically on the Docker bridge with `sctp or udp port 4729`.

```
gsmtap                    # radio traffic (Um)
gsm_map                   # MAP messages
m3ua / sccp               # SS7, if you run multi-operator
```

### 6.5 Logs

Every component writes under `LOG_DIR`, which is `RUN_DIR/logs`:
`/run/user/<uid>/osmo-nitb/logs` when the launching user has an
`XDG_RUNTIME_DIR`, `/tmp/osmo-nitb/logs` otherwise (see
`environment/paths.env`). The directory is on tmpfs on purpose: tmux and the
desktop panel follow the files live, and tmpfs is the only filesystem here
where inotify works reliably. `run.sh --stop` archives the directory under
`../archives/<timestamp>`, truncates oversized archives and prunes old ones.

`mobile.log` is the journal of osmocom-bb `mobile` (MS#1), written by qosmo's
`run_modules/70-l2.sh` or, with `--dsp`, by `c54x_exe/run.sh` under
`/tmp/c54x-pont`. Its format is fixed by the `log stderr` block that
`start-native.sh` guarantees in every generated `mobile.cfg`: colour per
subsystem, category prefix, the compact 17-digit timestamp
(`logging print extended-timestamp 1`, `YYYYMMDDhhmmssnnn`), and the seven
categories the bench follows in debug (mm, rr, cc, sms, plmn, sim, sap).
Readers strip the ANSI codes and the timestamp themselves: the desktop panel
(`tools/osmo-fft-snap.py`), `qosmo/tools/rapport-run.sh`,
`scripts/banc-repro.sh`, `/opt/GSM/tests/banc-max.sh`.

`start-native.sh` publishes at start and removes at stop:

| path | holds |
|---|---|
| `/run/osmo-banc/ms1-vty` | the VTY port of MS#1 (4247, 4347 with `--dsp`) |
| `/run/osmo-banc/mobile-log` | the absolute path of `mobile.log` |

Both are also pushed into systemd's environment (`OSMO_BB1_VTY_PORT`,
`OSMO_MOBILE_LOG`). Setting `OSMO_MOBILE_LOG` by hand overrides the published
path for the panel.

---

## 7. Diagnosing the radio side

**Read [`pont/README.md`](../pont/README.md) before chasing a radio fault
through a CRC counter.** The causes documented there (overwritten Kc, the SACCH
L1 header, C0 filling, an inert `CALYPSO_CANNED`) *all* present themselves as
"the bridge has CRC errors".

```bash
./start-native.sh --check-paths     # verify the declared dependencies
./start-native.sh --verbose         # show the modules' output
```

Logs (`$LOG_DIR`, see 6.5; `/var/log/osmocom` holds the SMSC and side-car logs):

```
$LOG_DIR/qemu.log        # ARM/DSP emulation, BSP, IRQ
$LOG_DIR/bridge.log      # QEMU ticks, IND CLOCK, DL/UL bursts
$LOG_DIR/run.sh.log      # orchestration
```

| symptom | likely cause | check |
|---|---|---|
| `bridge: timeout` | QEMU never started the TPU/DSP | `grep TINT0 $LOG_DIR/qemu.log` |
| `FBSB result=255` (no cell) | layer 1 is not detecting the FB | `grep "IMR change" $LOG_DIR/qemu.log \| wc -l` |
| `osmo-bts-trx: PC clock skew too high` | the bridge stopped sending `IND CLOCK` | restart the bridge |
| `/tmp/osmocom_l2` never created | the firmware is not booting | `head -50 $LOG_DIR/qemu.log` |
| *Address already in use* on 5700 | two bridges: a `--dsp` run left one behind | `./start-native.sh --stop` |

QEMU monitor:

```bash
docker exec -ti osmo-operator-1 socat - unix-connect:/tmp/qemu-calypso-mon.sock
```

`--assembly-logs` gives a trace of the emulated ARM (`-d in_asm`: each block
once, when it is translated). `ASSEMBLY_LOGS_FLAGS=in_asm,exec,nochain` also
logs every execution; that makes the ARM ~150 times slower. The bridge clock
then follows the DSP down to `PONT_HORLOGE_MAX` times real time (4 by default,
16 when `ASSEMBLY_LOGS=1`, see `pont/trx.py`; the trace itself goes to
`/var/tmp/c54x-pont`, not the tmpfs), but the wall-clock timers of `mobile`
(T3210) and of the core network (T3101) still run, so the attach may time out:
use it to chase the firmware, not to measure the network.

---

## 8. The qosmo launcher

`40-qemu.sh` does not call `qemu-system-arm` directly: it calls the C launcher
`qosmo` (`qosmo/tools/qosmo-launch`), installed next to it by `ninja install`.
The launcher knows which layer 1 the QEMU it starts was built with, because
`QOSMO_DSP` follows the `configure` option.

```bash
qosmo -k /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
qosmo --help
```

Defaults: `-M calypso`, `-cpu arm946`, `-gdb tcp::1234`, `-serial pty -serial
pty`, a unix monitor, L1CTL on `/tmp/osmocom_l2`, TRXDv0 on `0.0.0.0:6702`. It
reads `l1s`/`last_rach` out of the ELF (no `nm` needed), relays QEMU's output
unchanged, and publishes stable links to the ptys under `<RUN_DIR>/`.

`start-native.sh` resolves it (`--launcher <bin>`, or `QOSMO_LAUNCHER`), builds
it if the source is there and the binary is not, and passes it to `run.sh`.
Without a launcher, `40-qemu.sh` falls back to the plain `qemu-system-arm`
command line.

---

## 9. One PLMN

Every simulated operator is the standard Osmocom stack, all components in a
single container talking over `127.0.0.1`.

```mermaid
flowchart LR
    UE --> BTS
    BTS -->|Abis/IP| BSC
    BSC -->|SCCP via STP| MSC
    MSC -->|GSUP| HLR
    MSC -->|MGCP| MGW
    MSC -->|MNCC| Asterisk
```

The local STP is the intra-PLMN signalling hub. It listens on `127.0.0.1:2905`
immediately, without waiting for the Docker interface.

### 9.1 SMS

```mermaid
sequenceDiagram
    participant MS_A as MS (sender)
    participant MSC as MSC (sms-over-gsup)
    participant HLR as HLR
    participant SMSC as proto-smsc-daemon
    participant MS_B as MS (recipient)

    MS_A->>MSC: SMS MO
    MSC->>HLR: GSUP MO-forwardSM
    HLR->>SMSC: GSUP MO-forwardSM
    SMSC->>HLR: GSUP MT-forwardSM
    HLR->>MSC: GSUP MT-forwardSM
    MSC->>MS_B: SMS MT
```

### 9.2 Voice

```
MS → BTS → BSC → MSC → MNCC → Asterisk → MNCC → MSC → BSC → BTS → MS
                              ↕ MGCP
                            OsmoMGW (RTP)
```

### 9.3 Numbering

| number | use |
|---|---|
| `N0001`…`N9999` | GSM subscribers of operator N |
| `100` / `200` | local softphones |
| `600` | echo test |
| `9XXXXX` | inter-operator out from a softphone |

The first digit of `NXXXX` identifies the operator. The `[gsm_in]` dialplan
(`configs/extensions.conf`) works out whether the destination is local or
inter-op.

---

## 10. PHY modes

For the MS side, selected through `PHY_MODE` inside the container before
calling `run.sh`:

| `PHY_MODE` | stack | use |
|---|---|---|
| `faketrx` (default) | `fake_trx` → `trxcon` → `mobile` | multi-MS, fast, no DSP |
| `virtphy` | `osmo-bts-virtual` ↔ `virtphy` ↔ `mobile` | multi-MS over UDP multicast |
| `qemu` | `osmo-bts-trx` ↔ bridge ↔ Calypso QEMU ↔ `mobile` | emulated baseband, 1 MS |

`PHY_MODE=qemu` forces `N_MS=1`: the bridge uses fixed UDP ports, so one
emulated Calypso per container. For several virtual handsets, run several
containers.

---

## 11. Multi-operator and SS7

The bench also runs **N operators (1 to 9)**, each with its own core network in
its own container, joined by a central Inter-STP that routes M3UA/SCCP between
them. No configuration file is edited by hand: pjsip, dialplan, SMS routing and
the inter-STP config are all generated from N.

```bash
sudo ./launch/start-docker.sh          # choose bridge mode, enter N operators
sudo ./launch/start-docker.sh stop
```

### 11.1 Topology

```mermaid
flowchart LR
    subgraph "osmo-operator-1"
        BSC_A["BSC 1.23.3"]
        MSC_A["MSC 1.23.1"]
        STP_A["STP 1.23.2"]
        BSC_A -->|127.0.0.1:2905| STP_A
        MSC_A -->|127.0.0.1:2905| STP_A
    end
    subgraph "osmo-operator-2"
        BSC_B["BSC 2.23.3"]
        MSC_B["MSC 2.23.1"]
        STP_B["STP 2.23.2"]
        BSC_B -->|127.0.0.1:2905| STP_B
        MSC_B -->|127.0.0.1:2905| STP_B
    end
    subgraph "osmo-inter-stp"
        INTER["Inter-STP 0.23.0"]
    end
    STP_A <-->|"RCTX 150 / :2908"| INTER
    STP_B <-->|"RCTX 250 / :2908"| INTER
```

### 11.2 Addressing

| Docker network | range | role |
|---|---|---|
| `gsm-inter` | `172.20.0.0/24` | interop backbone (inter-STP M3UA) |
| `gsm-net-opN` | `172.20.N.0/24` | operator N private network |

Operator N → backbone `172.20.0.(10+N)`, private `172.20.N.10`. The Inter-STP
is at `172.20.0.10`.

### 11.3 Point codes and routing contexts

ITU 14-bit, `zone.network.node`:

| node | point code | | RCTX | formula |
|---|---|---|---|---|
| Inter-STP | `0.23.0` | | `rctx_msc` | `N×100+10` |
| MSC OpN | `N.23.1` | | `rctx_stp` | `N×100+20` |
| STP OpN | `N.23.2` | | `rctx_bsc` | `N×100+30` |
| BSC OpN | `N.23.3` | | **`rctx_inter`** | **`N×100+50`** |

`rctx_inter` must match in the operator's `osmo-stp.cfg` and be consistent with
the connection to the inter-STP. The inter-STP uses **AS without a routing
key** (catch-all per operator); routing is on the DPC alone.

### 11.4 Message path

```mermaid
flowchart LR
    MSC_A["MSC Op1<br/>1.23.1"] -->|"SCTP 127.0.0.1:2905"| STP_A["STP Op1<br/>1.23.2"]
    STP_A -->|"catch-all → as-inter<br/>172.20.0.10:2908"| INTER["Inter-STP<br/>0.23.0"]
    INTER -->|"DPC 2.23.x → as-op2"| STP_B["STP Op2<br/>2.23.2"]
    STP_B -->|"DPC 2.23.1 → dyn"| MSC_B["MSC Op2<br/>2.23.1"]
```

### 11.5 Generated configuration

`apply_config_templates()` in `launch/start-docker.sh` resolves every
N-dependent placeholder in a **single `sed` pass** (`__PC_MSC__`,
`__RCTX_INTER__`, `__ARFCN__` = `512+N×2`, `__CONTAINER_IP__`, …), then appends
the sections that depend on the *total* number of operators: N-1 PJSIP trunks,
the `[interop_out]` dialplan, the SMS routing table, and N AS + N×3 SS7 routes
in the inter-STP config.

Startup order matters: the Inter-STP must be listening on `:2908` **before**
the operator STPs try to connect.

### 11.6 Inter-operator SMS and voice

`scripts/sms-interop-relay.py` watches the `proto-smsc-daemon` MO log, parses
the GSM 03.40 TPDU, looks up `sms-routing.conf` (longest-prefix match) and
forwards over TCP 7890 to the target operator's relay, which resolves
MSISDN→IMSI on the HLR VTY and calls `proto-smsc-sendmt`.

Voice crosses on a SIP trunk between the operators' Asterisk instances. The
`[interop_out]` dialplan routes on the first digit of the dialled number.

### 11.7 Diagnosing PROHIB routes

```bash
sudo docker ps | grep inter-stp
sudo docker exec osmo-operator-1 sh -c 'echo "show cs7 instance 0 asp"   | telnet 127.0.0.1 4239'
sudo docker exec osmo-inter-stp  sh -c 'echo "show cs7 instance 0 asp"   | telnet 127.0.0.1 4239'
sudo docker exec osmo-operator-1 sh -c 'echo "show cs7 instance 0 route" | telnet 127.0.0.1 4239'
sudo docker exec osmo-operator-1 ping -c1 172.20.0.10
```

A healthy operator STP route table:

```
N.23.1/14   as-dyn-…  avail  avail  dyn   ← MSC (dynamic)
N.23.3/14   as-dyn-…  avail  avail  dyn   ← BSC (dynamic)
0.0.0/0     as-inter  avail  avail        ← catch-all to the inter-STP
```

| symptom | likely cause | fix |
|---|---|---|
| route `0.0.0/0` PROHIB | inter-STP down, or wrong IP | check `INTER_STP_IP` and the backbone IP |
| no dynamic routes | MSC/BSC not reaching the local STP | check the ASPs point at `127.0.0.1` |
| ASP DOWN on the inter-STP | Docker race condition | `docker restart` the operator |

### 11.8 WAN, mesh and multi-machine

Beyond a single host, `start-native.sh` also meshes several machines
(procedure: [WAN](WAN.md)):

```bash
./start-native.sh --wan                   # interactive: N nodes, IPs, prefixes
./start-native.sh --wan mynode1.conf       # from other nodes' cards
./start-native.sh --wan-nodes "1:IP:IND …" # scriptable
./start-native.sh --gen-conf               # write this node's card, start nothing
./start-native.sh --virtualbox=3           # mesh with VirtualBox VMs
./start-native.sh --air-mesh               # mesh the BURSTS: a shared radio medium,
                                           # a mobile can hear and pick another node's BTS
```

`--node N` picks the node number **at launch**, not at build time, so one ISO
serves all nine nodes.

---

## 12. Other extensions

- **4G (srsRAN + Open5GS)**: shipped in `/opt/LTE`, launched with `osmo-lte`
  and `osmo-epc`. CSFB to the 2G core through SGs.
- **Web dashboard**: `osmo-egprs-web` on `:8080`, started by
  `systemctl restart osmo-egprs-web`.
- **postmarketOS handset UI**: a patched `pmbootstrap` in
  `/opt/user_interface/pmos`.
- **SIM in a PC/SC reader or software SIM**: `--sap`, see [SIM](SIM.md).

---

## 13. Related documents

| document | subject |
|---|---|
| [`pont/README.md`](../pont/README.md) | A5 ciphering, Kc and SACCH: the measurement report behind the bridge's CRC counters |
| [`wiki/`](Home.md) | Home, Build, Environment, Start-native, Results, SIM, WAN: using the bench day to day |
| [`environment/README.md`](../environment/README.md) | environment variables and path resolution |
| [`services/README.md`](../services/README.md) | the systemd units shipped |
| [`navigation/QUICKSTART.md`](../navigation/QUICKSTART.md) | getting started |
| [`qosmo/README.md`](https://github.com/bbaranoff/qosmO) | the QEMU fork |
| [`c54x_exe/README.md`](https://github.com/bbaranoff/c54x_exe) | the DSP emulator and its state |

---

## Known issues

- **DSP chain (`--dsp`)**: every TCH/F downlink frame is flagged BFI even
  though speech stays intelligible; SACCH occasionally drops a call; the SB
  window is rarely armed, so sync may take several tries; the DSP needs
  4.3–4.6 ms of host time per 4.62 ms frame.
- **TRX mode (`--bts`)**: the SCH encoded by the DSP extension code comes out
  half wrong on `c54x_exe` (a C54x instruction of that loop is emulated
  wrongly, still to find); `c54x_exe` re-encodes the SCH before publishing it
  as a workaround (`MONTANT_ROM_TX_SB_RECODE`). The extcode's normal-burst
  demodulator likewise yields nothing on `c54x_exe`; the BSP writes the exact
  uplink bits into the result page instead (`CALYPSO_BSP_TRX_UL`). The trx
  firmware prints `DSP Error Status: 24` (DMA_PROG|DMA_TASK) every frame;
  harmless so far. SMS and calls between two Calypsos over `pont/air.py` beyond
  the echo test are not exercised.
- `osmo-bts-trx` exits whenever its transceiver disappears ("No more clock from
  transceiver"), i.e. after every `banc-stop`; `c54x_exe/run.sh` relaunches it
  at step 4b.
- `--assembly-logs` with `exec` tracing makes the attach time out on the
  network side (wall-clock timers keep running).
