# Installing grgsm_exe — and the gr-gsm setup

> Version of 2026-10-03. Back: [Telephone-emule](Telephone-emule.md).
> The repo carries its own installer, `grgsm_exe/install.sh` (also called by the `Dockerfile`, stage
> `l1`, `Dockerfile.run`, `start-docker.sh`, the ISO and `install.sh --telephone`). The
> `Dockerfile:N` numbers refer to the Dockerfile at commit `4266c8b`.

## First: three things carry this name

| Name | What it is | Makes the mobile camp? | Source |
|---|---|---|---|
| the **`grgsm_exe`** repo (`https://github.com/bbaranoff/grgsm_exE`) | qosmo's gr-gsm layer 1 (`calypso_l1_grgsm.c`) compiled **outside QEMU**, 118 KB, no ARM and no firmware: "the L1 writes into the void" | **no** — a bench and replay tool | `grgsm_exe/README.md:1-42` |
| the `/usr/local/bin/grgsm_exe` command | wrapper = `python3 pont/pont_dsp.py --no-record --dsp-port 6702`; `PONT_DSP_PORT=0 grgsm_exe` = `pont/pont.py` | it is the **bridge** | `c54x_exe/LAUNCH.md:142-158`; **outside the repo**, absent from a fresh install |
| "grgsm_exe bridge" / the `--grgsm` setup | gr-gsm L1 **inside** QEMU (qosmo `--enable-l1-grgsm`) + `pont/pont.py` | **yes** (the historical chain) | `osmo-operator/environment/paths.env:24-27`, `start-native.sh:111` |

To connect a phone to your network with the gr-gsm setup, you need the **third** one:
qosmo + firmware + osmocom-bb (already done in [Installer-qosmo](Installer-qosmo.md)) and the
`pont/pont.py` bridge from osmo-operator. The `grgsm_exe` repo is optional.

## 1. The grgsm_exe repo (bench tool)

Prerequisites: qosmo cloned (source), gcc. No Osmocom library (`Makefile:12`: `-lpthread -lm -lrt`).

With the installer:

```bash
git clone https://github.com/bbaranoff/grgsm_exE /opt/GSM/grgsm_exe
cd /opt/GSM/grgsm_exe
./install.sh --check         # qosmo source, cc, make — changes NOTHING
./install.sh                 # make -B, then grgsm_exe --trames 50 run safely
```

| step | does | Dockerfile line |
|---|---|---|
| `build` | `make -B QOSMO=…` — `-B` because the binary is **tracked by git**: on clone it is newer than qosmo's sources and `make` alone concluded "à jour" (up to date) (`Dockerfile.run:189` did `clean all`) | 745-746 |
| `verify` | `grgsm_exe --trames 50` → "bilan sur 50 trames" (report over 50 frames) | — |

The check does not disturb a running bench: grgsm_exe takes UDP 4730/4731 with
`SO_REUSEADDR` and opens `/dev/shm/calypso_*` with `O_CREAT` + `ftruncate` (`calypso_l1_grgsm.c`);
as root it therefore runs in **private** mount and network namespaces (`unshare`, a fresh `/dev/shm`);
otherwise, if a bench is visible, the run is skipped and says so. Options: `--qosmo DIR`
(`QOSMO`), `--dest DIR` (build a copy), `--only`, `--skip`, `-v`; logs in
`/tmp/grgsm_exe-install/`.

By hand (what the script does):

```bash
make -B                      # QOSMO=/path/to/qosmo make -B   (README.md:41-42)
./grgsm_exe --trames 5000    # README.md:6-10
./grgsm_exe --verbeux
```

Check that it opens its inputs (`README.md:21-27`):

```
$ ss -ulnp | grep 473
127.0.0.1:4730   users:(("grgsm_exe",...))    # GSMTAP
127.0.0.1:4731   users:(("grgsm_exe",...))    # SCH
```

With nothing publishing on 4731 or in `/dev/shm`, `si_valid` stays false and the report says so
(`README.md:38-39`). **Do not run it at the same time as QEMU in the gr-gsm setup**: both
take UDP 4730/4731 (deduced from `README.md:24-27` and `LAUNCH.md:87-88`).

## 2. The gr-gsm setup (full phone)

Nothing more to compile than for qosmo: the `qemu-system-arm` binary built with `--enable-l1-grgsm`
**is** layer 1. The bridge is `pont/pont.py` (python3, numpy, libosmocoding — no GNU Radio,
`pont/gsm.py:50,59`).

Launch via the c54x_exe repo's script (it handles both setups, `run.sh:4-13`):

```bash
cd /opt/GSM/c54x_exe
MODE=grgsm PONT=1 PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
```

In the grgsm setup, `run.sh` skips step 1 (no c54x_exe), launches QEMU **without**
`CALYPSO_DSP_EXTERN`, waits for `backend gr-gsm` in qemu.log (`run.sh:146-147`), then osmocon,
mobile, and `pont/pont.py` (`run.sh:37-38`).

Expected:

| Line | File | Source |
|---|---|---|
| `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731` | qemu.log | `calypso_l1_grgsm.c:1207`, `LAUNCH.md:95` |
| `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7` then `STATS fn=… \| DL bursts=N` | pont.log | `LAUNCH.md:157-158` |

**Watch out for the mobile config**: `run.sh` uses `mobile_pont.cfg` in both setups
(`run.sh:33`), and that file imposes `io-tch-format ti` (DSP frames). On gr-gsm, it is the bridge that
encodes speech in **rtp** format; with `ti` "les trames passent […] et le son sort robotisé" (the
frames go through […] and the sound comes out robotic) (`mobile_pont.cfg`, the `io-tch-format`
comment). For the gr-gsm setup, use the bench config `osmo-operator/configs/mobile.cfg` (copied to
`/root/.osmocom/bb/mobile.cfg`, `Dockerfile:1170`) via `MOBILE_CFG=` — **TO CONFIRM**: this config
contains `__…__` templates filled in by `generate_configs.sh`; it must then be filled in by hand
(IMSI, Ki, `stick`, VTY).

## Troubleshooting

| Symptom | Cause / fix | Source |
|---|---|---|
| `la couche 1 gr-gsm ne s'est pas annoncee` (the gr-gsm layer 1 did not announce itself) | QEMU compiled without `--enable-l1-grgsm`, or launched with `CALYPSO_DSP_EXTERN=1` | `run.sh:147`, `Dockerfile:698` |
| `pont.py est le pont du montage grgsm : pour le DSP, lancer pont/pont_dsp.py` (pont.py is the grgsm-setup bridge: for the DSP, launch pont/pont_dsp.py) | `--dsp-port` passed to pont.py | `pont/pont.py:25-26` |
| `grgsm_exe` command not found | the wrapper is versioned nowhere (`LAUNCH.md:28`); launch `python3 pont/pont.py` directly | — |
| 79% CRC KO, LU failing | bridge from outside the repo (an old copy); always launch the one from the osmo-operator tree | `start-native.sh`, block "LE PONT VIENT DU DEPOT" (the bridge comes from the repo) |
