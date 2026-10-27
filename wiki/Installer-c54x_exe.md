# Installing c54x_exe (the Calypso DSP on the TI mask ROM) and the DSP bridge

Back: [Telephone-emule](Telephone-emule.md). Prerequisite: [qosmo](Installer-qosmo.md).

`c54x_exe` (`https://github.com/bbaranoff/c54x_exe`) runs the **original mask ROM of the
TMS320C54x** found in Calypso basebands as a Linux process. In the DSP setup, the osmocom-bb
firmware under QEMU talks to it through the shared API RAM, frame by frame. The repository
does not contain the C54x core itself: it **compiles qosmo's sources**
(`qosmo/hw/arm/calypso/l1-dsp/`), so qosmo must be cloned first. The repository ships its own
installer, `c54x_exe/install.sh`, which is also what the Docker images, the ISO build and
`install.sh` call. The manual commands below are what the installer does, step by step.

## With the installer

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
./install.sh --check      # qosmo cloned? libosmocoding seen by pkg-config? ROM? -- changes nothing
sudo ./install.sh         # make, ROM into /opt/GSM and rom/, then c54x_exe --trames 200
```

| Step | Does | Already done if |
|---|---|---|
| `build` | `make QOSMO=...` (with `--portable`: `CFLAGS` without `-march=native`); `ldd` check | never skipped: the Makefile recompiles on every call |
| `rom` | copies an already verified ROM found on the machine, otherwise `rom/fetch-rom.sh --dest ...` (download, conversion, checksum) | all ROM files + `Registers` present and matching `rom/SHA256SUMS.3606` in every destination |
| `verify` | `c54x_exe --rom-dir ... --trames 200`: "N sections chargees" then "bilan sur 200 trames" | never skipped |

Options (and equivalent variable):

| Option | Variable | Default | Role |
|---|---|---|---|
| `--qosmo DIR` | `QOSMO` | `$GSM_ROOT/qosmo` | the sources to compile |
| `--rom-dir DIR` (repeatable) | `ROM_DIR` | `$GSM_ROOT` **and** the repo's `rom/` | where the ROM is written |
| `--portable` | `PORTABLE=1` | off | `CFLAGS` without `-march=native`, for a binary that travels |
| `--dest DIR` | | | copies the repo without `.git` or binaries into `DIR` and builds there: the binary in service is not overwritten |
| `--only STEPS`, `--skip STEPS`, `--reinstall`, `--with-deps`, `-v` | | | step selection, replay, apt packages, verbose |

Logs: `/tmp/c54x_exe-install/<step>.log`.

Without root: `ROM_DIR=$HOME/calypso-rom ./install.sh`, then run
`c54x_exe --rom-dir $HOME/calypso-rom` (the binary's default ROM directory is `/opt/GSM`).

The `--trames 200` check runs without `--arm`: private API RAM, no `/dev/shm`, no socket, no
`/tmp/c54x-pont` (it runs in a private mount namespace), so it does not disturb a running bench.

Typical failure:

```
[FAIL] Compilation de c54x_exe (sources de qosmo) (manque : libosmocoding + libosmocore vus de pkg-config)
       -> export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
```

("manque" = missing: libosmocore is installed under `/usr/local`.)

## What the installer does, by hand

### Prerequisites

- qosmo cloned (default `/opt/GSM/qosmo`), see [Installer-qosmo](Installer-qosmo.md).
- gcc, make, pkg-config, **libosmocore + libosmocoding** visible to pkg-config. Check before
  compiling (the Makefile hides the pkg-config error):
  ```bash
  pkg-config --cflags --libs libosmocoding libosmocore
  ```
  If empty: `export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig`.
- python3 + curl or wget for the ROM download.
- For the bridge: python3, `python3-numpy`, `libosmocoding.so` and `libosmogsm.so` loaded through
  ctypes (`pont/gsm.py`), so `ldconfig` must be up to date when libosmocore lives in `/usr/local`.

### Build (`build` step)

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
make                                  # or: make QOSMO=/path/to/qosmo
```

For a binary that must run on a different CPU than the build machine, drop `-march=native`:

```bash
make QOSMO=/opt/GSM/qosmo \
  CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"
```

`make` recompiles on every call (a single cc command, no `.o`): this is intentional, the sources
come from another repository.

### The DSP ROM (`rom` step)

The ROM is not in the repository. `rom/fetch-rom.sh` downloads the FreeCalypso 3606 dump,
converts it (`tools/dsp_txt2bin.py`) and checks `rom/SHA256SUMS.3606`. The binary reads it from
`--rom-dir`, default `/opt/GSM`.

```bash
bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom
```

Expected output:

```
telechargement : ftp://ftp.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
somme de controle verifiee (SHA256SUMS.3606)
ROM DSP 3606 ecrite dans /opt/GSM
ROM DSP 3606 ecrite dans /opt/GSM/c54x_exe/rom
```

(download / checksum verified / ROM written to.) Run again, it answers `ROM DSP 3606 deja en
place et verifiee` (already in place and verified). Options: `--version 3311` (D-Sample),
`--force`, mirror via `FREECALYPSO_URL=`. The installer first copies an already verified ROM
found on the machine, so no network is needed when one is present.

### Checking the DSP alone (`verify` step)

```bash
./c54x_exe --trames 200    # the ROM alone, no ARM: does it boot?
./c54x_exe --help
```

Optional ISA test: `make isa_test && ./isa_test tools/isa_tests.txt 2>/dev/null`.

## The DSP bridge

The bridge connecting osmo-bts-trx to the DSP lives in **osmo-operator**, not in c54x_exe.
Nothing to compile:

```bash
git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator
cd /opt/GSM/osmo-operator && python3 pont/pont_dsp.py --help
```

`pont_dsp.py` requires `--dsp-port 6702` (see `pont/README.md`). It reads the timeslot table
from `PONT_BSC_CFG` (default `/etc/osmocom/osmo-bsc.cfg`): point it at your BSC config.

## Running

Against an already started stack (osmo-bts-trx included):

```bash
cd /opt/GSM/c54x_exe
PONT=1 CALYPSO_BSP_STREAM=1 CALYPSO_RHEA_DMA_XFER=1 \
  PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
./run.sh --status | --logs | --stop
```

- `PONT=1`: without it, no bridge, no burst arrives.
- `INSNS` (DSP instructions per frame): default 120000 in `run.sh`, which `start.sh` also sets
  in DSP mode. `CALYPSO_BSP_STREAM=1` (one TS0 burst per frame, in FN order) and
  `CALYPSO_RHEA_DMA_XFER=1` (without it the API page is never filled: no SB, no BCCH, no SI)
  are set by `start.sh` before it hands over to `run.sh`.
- `LOCKSTEP=1` (default): QEMU waits for the DSP on every frame (`CALYPSO_PONT_LOCKSTEP=1`).
- `GDB=1` (default): QEMU gdbstub on 1234 plus a telnet console on 44444 driven by
  `$QOSMO/tools/gdb-telnet.py` (`GDB_TELNET_PY` overrides the path; `GDB=0` disables both).
- Other variables: `MODE`, `VERB`, `IQ`, `AMP`, `QOSMO`, `FIRMWARE_ELF`, `FIRMWARE_BIN`,
  `OSMOCON`, `MOBILE`, `MOBILE_CFG`, `PONT_PY`, `RUNDIR`, `L2_SOCK`, `C54X_BIN`, `INSTANCE`
  (see the header of `run.sh` and `README.md`).
- Logs: `/tmp/c54x-pont/{dsp,qemu,osmocon,mobile,pont}.log`, sessions archived in
  `/tmp/c54x-pont/archives/<date>/`.

Process-by-process details: [Lancer-a-la-main](Lancer-a-la-main.md).

All-in-one variant for a **systemd** stack: `./run_real.sh [--secondes N]` starts
`osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc`, restarts `osmo-bts-trx`, runs `run.sh`, watches
for N seconds (120 by default) and prints a verdict. `./run_real.sh --stop` stops everything.

## What proves it works

| Line | File | Source |
|---|---|---|
| `pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)` | dsp.log | `src/pont.c` |
| `pont : RESET #1 (DL_STATUS=...) fn=... pc=0xff80` then `pont : DSP boote (premier IDLE)` | dsp.log | `src/pont.c`, `LAUNCH.md` |
| `[trx] pont DSP : API RAM partagee (...) + socket /tmp/calypso_dsp.sock` | qemu.log | `qosmo/hw/arm/calypso/calypso_trx.c` |
| `[montant] RACH ra=0x.. bsic=..`; `pont.log` goes from `rach=0` to `rach=N` | dsp.log / pont.log | `LAUNCH.md` |
| `[montant] TCH : le firmware poste la tache 13 a fn=..., BSP bascule sur TS2` | dsp.log (during a call) | `LAUNCH.md` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| link fails on `gsm0503_*` | pkg-config cannot find libosmocoding (error hidden by the Makefile): set `PKG_CONFIG_PATH` |
| `Illegal instruction` at startup | `-march=native` binary from another machine: rebuild here (`./install.sh`), or `--portable` for a binary that travels |
| `c54x_exe n'a pas ouvert /tmp/calypso_dsp.sock` (did not open the socket) | ROM missing from `--rom-dir`: `./install.sh --only rom` (or `rom/fetch-rom.sh --dest /opt/GSM`); see dsp.log |
| rebuild without touching the binary of a running bench | `./install.sh --dest /tmp/c54x-neuf`, then compare / replace once stopped |
| `somme de controle differente` (checksum mismatch) | modified dump or wrong `--version` |
| `QEMU n'a pas rejoint le DSP` (QEMU did not join the DSP) | QEMU started without `CALYPSO_DSP_EXTERN=1`, or DSP not ready yet |
| `pont.py ne s'est pas annonce` (pont.py did not announce itself) | inherited `PONT_PY` pointing at `pont.py` (gr-gsm bridge): `env -u PONT_PY` |
| `FBSB RESP: result=255` in a loop | no bridge or no BTS: normal without a network |
| `DL bursts=0` | no BTS is transmitting to 5700-5702: check the `phy` section of osmo-bts-trx |
| `le port VTY 4347 ... deja pris` (already taken) | another mobile is running; change `bind 127.0.0.1` in the cfg |
| dirty state after a crash | `./run.sh --stop` purges sockets and `/dev/shm/calypso_*` |

## Known issues

- The SB is decoded only one time in three to five; `run.sh` sets
  `L23_SYNC_RETRIES_SELECTION=8` in DSP mode to compensate.
- `mobile_pont.cfg` sends GSMTAP to `172.20.0.1` (the docker gateway of the containerised
  bench): replace it with `127.0.0.1` when running outside a container.
