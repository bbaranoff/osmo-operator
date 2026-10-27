# Installing grgsm_exe, and the gr-gsm setup

Back: [Telephone-emule](Telephone-emule.md). Prerequisite: [qosmo](Installer-qosmo.md).

The `grgsm_exe` repository ships its own installer, `grgsm_exe/install.sh`, also called by the
Docker images, the ISO build and `install.sh`. This page covers that repository (a bench tool)
and the gr-gsm layer-1 setup of the emulated phone, which does not need it.

## Three things carry this name

| Name | What it is | Makes the mobile camp? | Where |
|---|---|---|---|
| the **`grgsm_exe`** repository (`https://github.com/bbaranoff/grgsm_exE`) | qosmo's gr-gsm layer 1 (`calypso_l1_grgsm.c`) compiled **outside QEMU**, no ARM and no firmware: a bench and replay tool | no | `/opt/GSM/grgsm_exe` |
| the `/usr/local/bin/grgsm_exe` command | wrapper around `python3 pont/pont_dsp.py --no-record --dsp-port 6702`; `PONT_DSP_PORT=0 grgsm_exe` runs `pont/pont.py` instead | it is the **bridge** | outside the repositories, absent from a fresh install |
| the "grgsm_exe bridge" / `--grgsm` setup | gr-gsm L1 **inside** QEMU (qosmo built with `--enable-l1-grgsm`) + `pont/pont.py` | yes (the end-to-end chain: camp, LU, auth, A5/1, SMS, voice) | `osmo-operator/environment/paths.env`, `start.sh --grgsm` |

To connect a phone to the network with the gr-gsm setup you need the third one: qosmo +
firmware + osmocom-bb (see [Installer-qosmo](Installer-qosmo.md)) and the `pont/pont.py` bridge
from osmo-operator. The `grgsm_exe` repository is optional.

## 1. The grgsm_exe repository (bench tool)

Prerequisites: qosmo cloned (source), gcc, make. No Osmocom library (links only
`-lpthread -lm -lrt`).

With the installer:

```bash
git clone https://github.com/bbaranoff/grgsm_exE /opt/GSM/grgsm_exe
cd /opt/GSM/grgsm_exe
./install.sh --check         # qosmo source, cc, make -- changes nothing
./install.sh                 # make -B, then grgsm_exe --trames 50 run safely
```

| Step | Does |
|---|---|
| `build` | `make -B QOSMO=...`. `-B` is required because the binary is tracked by git: on a fresh clone it is newer than qosmo's sources and `make` alone would consider it up to date |
| `verify` | `grgsm_exe --trames 50`, expects "bilan sur 50 trames" (report over 50 frames) |

The check does not disturb a running bench: `grgsm_exe` takes UDP 4730/4731 with
`SO_REUSEADDR` and opens `/dev/shm/calypso_*` with `O_CREAT` + `ftruncate`, so as root the
installer runs it in private mount and network namespaces (`unshare`, fresh `/dev/shm`);
otherwise, if a bench is visible, the run is skipped and reported. Options: `--qosmo DIR`
(`QOSMO`), `--dest DIR` (build a copy), `--only`, `--skip`, `-v`; logs in
`/tmp/grgsm_exe-install/`.

By hand:

```bash
make -B                      # or: QOSMO=/path/to/qosmo make -B
./grgsm_exe --trames 5000
./grgsm_exe --verbeux
```

Check that it opens its inputs:

```
$ ss -ulnp | grep 473
127.0.0.1:4730   users:(("grgsm_exe",...))    # GSMTAP
127.0.0.1:4731   users:(("grgsm_exe",...))    # SCH
```

With nothing publishing on 4731 or in `/dev/shm`, `si_valid` stays false and the report says so.
**Do not run it at the same time as QEMU in the gr-gsm setup**: both take UDP 4730/4731.

## 2. The gr-gsm setup (full phone)

Nothing more to compile than for qosmo: the `qemu-system-arm` binary built with
`--enable-l1-grgsm` **is** layer 1. The bridge is `pont/pont.py` (python3, numpy, libosmocoding
through ctypes; no GNU Radio).

Launch through the c54x_exe repository's script, which handles both setups:

```bash
cd /opt/GSM/c54x_exe
MODE=grgsm PONT=1 PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
```

In the grgsm setup, `run.sh` skips step 1 (no c54x_exe), launches QEMU **without**
`CALYPSO_DSP_EXTERN`, waits for `backend gr-gsm` in qemu.log, then starts osmocon, mobile and
`pont/pont.py`. Process by process: [Lancer-a-la-main](Lancer-a-la-main.md), gr-gsm variant.

Expected:

| Line | File |
|---|---|
| `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731` | qemu.log |
| `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7` then `STATS fn=... \| DL bursts=N` | pont.log |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `la couche 1 gr-gsm ne s'est pas annoncee` (the gr-gsm layer 1 did not announce itself) | QEMU compiled without `--enable-l1-grgsm`, or launched with `CALYPSO_DSP_EXTERN=1` |
| `pont.py est le pont du montage grgsm : pour le DSP, lancer pont/pont_dsp.py` | `--dsp-port` passed to `pont.py`; it is the gr-gsm bridge, `pont_dsp.py` is the DSP one |
| `grgsm_exe` command not found | the wrapper is versioned nowhere; launch `python3 pont/pont.py` directly |
| 79 % CRC errors, LU failing | a bridge copied outside the repository (an old copy); always launch the one from the osmo-operator tree |

## Known issues

- `run.sh` uses `c54x_exe/mobile_pont.cfg` in both setups, and that file imposes
  `io-tch-format ti` (DSP frames). On gr-gsm the bridge encodes speech in **rtp** format; with
  `ti` the frames go through but the sound comes out robotic. For the gr-gsm setup, pass a config
  with `io-tch-format rtp` via `MOBILE_CFG=`. The bench config `osmo-operator/configs/mobile.cfg`
  is a template (`__..._` placeholders filled by `generate_configs.sh`): it must be filled in by
  hand (IMSI, Ki, `stick`, VTY) before use.
