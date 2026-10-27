# Installing the emulated phone on your own Osmocom stack

This page is for anyone who **already** has an Osmocom network (osmo-bsc,
osmo-msc, osmo-hlr, osmo-stp, osmo-mgw, installed from packages or from
source) and wants to connect an **emulated Calypso phone** to it, without the
ISO, without Docker and without the osmo-operator stack.

| Page | Contents |
|---|---|
| **Telephone-emule** (here) | overview, requirements for **your** network, installation order |
| [Installer-qosmo](Installer-qosmo.md) | QEMU, the Calypso machine (the ARM + osmocom-bb firmware) |
| [Installer-c54x_exe](Installer-c54x_exe.md) | the C54x DSP outside QEMU, its TI ROM, the `pont_dsp.py` bridge |
| [Installer-grgsm_exe](Installer-grgsm_exe.md) | the gr-gsm setup, and what "grgsm_exe" really means |
| [Lancer-a-la-main](Lancer-a-la-main.md) | the chain launched process by process, with commands unfolded |
| [installer-osmo-jusquau-dsp.ipynb](installer-osmo-jusquau-dsp.ipynb) | notebook: the whole Dockerfile replayed natively, from apt down to a call in the DSP |

## What runs on the phone side

```
 your network                              what you install here
 ───────────────                           ─────────────────────────────────────────────
 osmo-bsc / msc / hlr / stp / mgw
        │ Abis/IPA
 osmo-bts-trx ── TRXD/TRXC/CLK UDP 5700-5702 ──▶ pont_dsp.py ── UDP 6702 ──▶ c54x_exe (DSP + TI ROM)
 (5800-5802)                                    (osmo-operator/pont)          │ /dev/shm/calypso_api_ram
                                                                             │ /tmp/calypso_dsp.sock
                                       osmocon ◀── serial pty ── qosmo (QEMU -M calypso, CALYPSO_DSP_EXTERN=1)
                                          │ /tmp/osmocom_l2           └─ layer1.highram.elf (osmocom-bb)
                                       mobile (osmocom-bb, VTY 4347)
```

Two setups exist (`c54x_exe/LAUNCH.md`):

| setup | layer 1 | bridge | state |
|---|---|---|---|
| **dsp** (default) | `c54x_exe --arm`, real TI mask-ROM | `pont/pont_dsp.py --dsp-port 6702` | camps, LU, SMS MO/MT, MO/MT calls, A5/1; SB sync sometimes takes several tries |
| **grgsm** | gr-gsm compiled into QEMU | `pont/pont.py` | end to end, up to the voice call |

## What your network must provide

The phone is pinned to a specific cell and subscriber. Either your network
conforms to it, or you change the values on the phone side (right-hand column).

| Element | Expected | Where to change it on the phone side |
|---|---|---|
| BTS | **osmo-bts-trx** on the same machine (tested with osmo-bts 1.10.0) | — |
| TRX link | BTS config: `phy 0` / `osmotrx ip local 127.0.0.1` / `osmotrx ip remote 127.0.0.1`, **without** `base-port` (defaults 5800 local, 5700 remote); see `osmo-operator/configs/osmo-bts-trx.cfg` | `PONT_TRX_BIND`, `PONT_TRX_BASE` (`pont/config.py`) |
| Band, ARFCN | DCS1800; the bridge defaults to ARFCN **514** (`PONT_ARFCN`), the bench's `globals.conf` uses `ARFCN="1"`; the three (BSC, bridge, mobile) must agree | `PONT_ARFCN` + the `stick <ARFCN>` line of `c54x_exe/mobile_pont.cfg` |
| BSIC | **7** | `PONT_BSIC` (`pont/config.py`) |
| Timeslots of the BSC's first `bts` | TS0 `CCCH+SDCCH4`, TS1 `SDCCH8`, TS2-5 `TCH/F`, TS6-7 `PDCH` (`osmo-operator/configs/osmo-bsc.cfg`) | the bridge **reads** them from `PONT_BSC_CFG` (default `/etc/osmocom/osmo-bsc.cfg`, `pont/gsm.py`); if the file is unreadable, the table at left is assumed |
| PLMN | MCC 001, MNC 01 | `rplmn 001 01` in `mobile_pont.cfg` |
| Subscriber | IMSI `001010001000001`, COMP128v1, Ki `00112233445566778899aabbccdd0101` | `test-sim` in `mobile_pont.cfg` |

Provision the subscriber in osmo-hlr (same VTY commands as
`qosmo/run_modules/21-abonnes-hlr.sh`):

```
telnet 127.0.0.1 4258
enable
subscriber imsi 001010001000001 create
subscriber imsi 001010001000001 update msisdn 100101
subscriber imsi 001010001000001 update aud2g comp128v1 ki 00112233445566778899aabbccdd0101
```

The MSISDN `100101` is the bench's (numbering plan in [Home](Home.md)); use
your own.

**Ports and files the phone occupies** on the machine (do not use them in your
stack): UDP 5700-5702 (bridge), UDP 6702 (DSP), UDP 4730/4731 (gr-gsm L1,
grgsm setup), TCP 4347 (mobile VTY), TCP 1234 (QEMU gdbstub), TCP 44444 (gdb
console), `/tmp/osmocom_l2`, `/tmp/osmocom_sap`, `/tmp/ms_data`,
`/tmp/calypso_dsp.sock`, `/tmp/qemu-monitor-pont.sock`, `/dev/shm/calypso_*`,
`/dev/shm/pont.log`, `/tmp/c54x-pont/` (sources: `c54x_exe/run.sh`,
`c54x_exe/mobile_pont.cfg`, `pont/config.py`).

## Installation order

Everything goes under a common root, `/opt/GSM` by default (paths hard-coded
in the Makefiles and `run.sh`, all overridable: `GSM_ROOT=`, `QOSMO=`,
`FIRMWARE_ELF=`, `OSMOCON=`…).

**Each repo carries its own installer** (`install.sh`), with the same contract
as `osmo-operator/install_modules/_lib/inst.sh`: `--check` (prerequisites,
changes nothing), `--list`, `--deps` / `--print-deps` (apt packages), `--only`
/ `--skip`, a log per step, a post-check. These are **the same scripts** the
Dockerfile (stages `qemu` and `l1`), `Dockerfile.run`, `start-docker.sh` and
the ISO call: a single list of commands per component.

### Component by component

1. **System dependencies**: each installer has its list: `./install.sh --print-deps`,
   `sudo ./install.sh --deps`.
2. **libosmocore** (with libosmocoding): you already have it if your stack is
   compiled; otherwise the `libosmocore-dev` packages from the Osmocom repo
   (the bench uses 1.12.1). `c54x_exe/install.sh --check` says right away
   whether pkg-config sees it.
3. **osmo-gapk**, then **osmocom-bb** (osmocon, mobile) and the prebuilt
   **firmware**: see [Installer-qosmo](Installer-qosmo.md#firmware-and-osmocom-bb).
   The bench's `patches/osmocom-bb-*.patch` are applied by
   `tools/osmo-patches-apply.sh` (`install_modules/40-patches.sh`); with the
   gnuarm toolchain in PATH (`sudo ./addition.sh --gnuarm`), the firmware
   rebuilds with `cd /opt/GSM/osmocom-bb/src && make`
   (`sudo ./addition.sh --calypso-fw`).
4. **qosmo**: `qosmo/install.sh`, [Installer-qosmo](Installer-qosmo.md).
5. **c54x_exe + DSP ROM + bridge**: `c54x_exe/install.sh`,
   [Installer-c54x_exe](Installer-c54x_exe.md).
6. (optional) **gr-gsm / grgsm_exe setup**: `grgsm_exe/install.sh`,
   [Installer-grgsm_exe](Installer-grgsm_exe.md).
7. **Launch**: `PONT=1 ./run.sh` in `c54x_exe` (`c54x_exe/README.md`) or by
   hand, [Lancer-a-la-main](Lancer-a-la-main.md).

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/qosmO    qosmo     && sudo qosmo/install.sh --with-deps
git clone https://github.com/bbaranoff/c54x_exe c54x_exe  && sudo c54x_exe/install.sh --with-deps
git clone https://github.com/bbaranoff/grgsm_exE grgsm_exe && grgsm_exe/install.sh      # optional
git clone --depth 1 https://github.com/bbaranoff/firmware firmware
```

## Proof that it works

In order (details in [Lancer-a-la-main](Lancer-a-la-main.md)):

| Step | Expected line | File |
|---|---|---|
| DSP ready | `pont : en attente de l'ARM sur /tmp/calypso_dsp.sock` (bridge: waiting for the ARM) | `/tmp/c54x-pont/dsp.log` |
| QEMU connected to the DSP | `[trx] pont DSP : API RAM partagee ...` (shared API RAM) | `/tmp/c54x-pont/qemu.log` |
| firmware loaded | `Received branch ack, your code is running now!` | `/tmp/c54x-pont/osmocon.log` |
| bridge ready | `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7` | `/tmp/c54x-pont/pont.log` (link to `/dev/shm/pont.log`) |
| BTS seen by the bridge | `BTS 127.0.0.1 : horloge armee vers le port 5800` (clock armed toward port 5800, `pont/trx.py`) | same |
| cell read | `New SYSTEM INFORMATION ...`, `lai=001-01-<LAC>` | `/tmp/c54x-pont/mobile.log` |
| camp | `C3 camped normally` in `show ms` (`/opt/GSM/tests/modules/60-camp.sh`) | VTY 4347 |
| LU | `LOCATION UPDATING ACCEPT`; `MM idle, normal service` | `mobile.log` / `show ms` |
| call | `call 1 600` then `call control state: ACTIVE` (`/opt/GSM/tests/modules/_lib.sh`) | VTY 4347 |

`c54x_exe/run_real.sh` automates these checks against a stack launched by
**systemd** (`systemctl start osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc`,
`systemctl restart osmo-bts-trx`) and prints a verdict `VRAI : lai=… = la
config du reseau` (TRUE: lai=… = the network config). It reads MCC/MNC from
`/etc/osmocom/osmo-msc.cfg` and LAC/BSIC from `/etc/osmocom/osmo-bsc.cfg`:
adapt if your configs are elsewhere.

## Known issues and untested cases

- Compatibility with an osmo-bts-trx **other than 1.10.0** is untested (TRXD
  negotiation: the bridge answers `SETFORMAT` with an echo and only reads
  TRXD v0, `pont/trx.py`).
- The bench's `osmo-bts/hlr/msc-force-rand-toy` patches (`patches/`) are
  **not** needed by the phone (they make the RAND reproducible), but the phone
  has not been tested without them.
- An osmo-bts-trx **on a different machine** from the phone is not planned
  for: the bridge returns the clock to the source IP of the CTRL command
  (`pont/trx.py`); it might work with `PONT_TRX_BIND=0.0.0.0`.
- Audio during a call: `mobile_pont.cfg` uses ALSA `gsm_out`/`gsm_in`, defined
  by `osmo-operator/configs/asound.conf` (the `libasound2-plugins` plugin +
  PulseAudio). Without them, the mobile's behaviour during a call is
  unverified.
