# Installing c54x_exe (the Calypso DSP, TI mask ROM) and the DSP bridge

> Version of 2026-10-03. Back: [Telephone-emule](Telephone-emule.md). Prerequisite: [qosmo](Installer-qosmo.md).
> The repository ships its own installer, `c54x_exe/install.sh`: it is also what the
> `Dockerfile` (stage `l1`), `Dockerfile.run`, `start-docker.sh`, the ISO and `install.sh --telephone` call.
> The manual commands below are **what the script does**, step by step.
> `Dockerfile:N` numbers refer to the Dockerfile at commit `4266c8b`, back when it still
> carried these commands.

`c54x_exe` (`https://github.com/bbaranoff/c54x_exe`) runs the **original mask ROM of the
TMS320C54x** found in Calypso basebands, as a Linux process. In the DSP setup, the osmocom-bb
firmware under QEMU talks to it through the real shared API RAM, frame by frame
(`c54x_exe/README.md:1-9`). It does not contain the C54x core: it **compiles qosmo's sources**
(`Makefile:1-7`, `README.md:57-61`).

## With the installer

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
./install.sh --check      # qosmo cloned? libosmocoding seen by pkg-config? ROM? — changes NOTHING
sudo ./install.sh         # make, ROM into /opt/GSM and rom/, then c54x_exe --trames 200
```

| step | does | Dockerfile line | already done if |
|---|---|---|---|
| `build` | `make QOSMO=…` (with `--portable`: `CFLAGS` without `-march=native`); `ldd` check | 733-735 | — (the Makefile recompiles on every call, `Makefile:46-52`) |
| `rom` | copies an **already verified** ROM found on the machine, otherwise `rom/fetch-rom.sh --dest …` (download, conversion, checksum) | 736 | all 6 ROMs + `Registers` present and matching `rom/SHA256SUMS.3606` in every destination |
| `verify` | `c54x_exe --rom-dir … --trames 200`: « N sections chargees » ("N sections loaded") then « bilan sur 200 trames » ("summary over 200 frames") | — | — |

Options (and variable): `--qosmo DIR` (`QOSMO`, default `$GSM_ROOT/qosmo`), `--rom-dir DIR`
repeatable (`ROM_DIR`, default `$GSM_ROOT` **and** the repo's `rom/`, like `Dockerfile:736`),
`--portable` (`PORTABLE=1`, the `CFLAGS` from `Dockerfile:735`), `--dest DIR` (copies the repo
without `.git` or binaries into `DIR` and builds there: **the binary in service is not overwritten**),
`--only`, `--skip`, `--reinstall`, `--with-deps`, `-v`. Logs: `/tmp/c54x_exe-install/<step>.log`.

Without root: `ROM_DIR=$HOME/calypso-rom ./install.sh`, then run `c54x_exe --rom-dir $HOME/calypso-rom`
(the binary's default is `/opt/GSM`, `src/main.c:79`).

The `--trames 200` check runs without `--arm`: **private** API RAM, no `/dev/shm`, no socket, no
`/tmp/c54x-pont` (verified in a private mount namespace) — it does not disturb a running bench.

Typical failure, spelled out:

```
[FAIL] Compilation de c54x_exe (sources de qosmo) (manque : libosmocoding + libosmocore vus de pkg-config)
       → export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig  (libosmocore est en /usr/local, Dockerfile:92-94)
```

("manque" = "missing": libosmocore lives in `/usr/local`.)

## What the script does, by hand

### Prerequisites

- qosmo cloned (default `/opt/GSM/qosmo`) — [Installer-qosmo](Installer-qosmo.md).
- gcc, make, pkg-config, **libosmocore + libosmocoding** visible to pkg-config (`Makefile:14`).
  Check before compiling (the Makefile hides the error, `2>/dev/null`):
  ```bash
  pkg-config --cflags --libs libosmocoding libosmocore
  ```
  If empty: `export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` (the Dockerfile's value, `Dockerfile:92-94`).
- python3 + curl or wget for the ROM (`rom/fetch-rom.sh:47-52`).
- For the bridge: python3, `python3-numpy` (`pont/record.py:6`), `libosmocoding.so` and `libosmogsm.so`
  loaded through ctypes (`pont/gsm.py:50,59`) — so `ldconfig` must be up to date if libosmocore is in `/usr/local`.

### Build (`build` step)

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
make                                  # or: make QOSMO=/path/to/qosmo   (README.md:63-68)
```

For a binary that must run on **a different CPU** than the build machine, drop `-march=native`
as the Dockerfile does (`Dockerfile:726-735`):

```bash
make QOSMO=/opt/GSM/qosmo \
  CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"
```

`make` recompiles **on every call** (a single cc command, no `.o`): this is intentional, the
sources come from another repository (`Makefile:42-52`).

### The DSP ROM (`rom` step)

Not in the repository. `rom/fetch-rom.sh` downloads the FreeCalypso 3606 dump, converts it
(`tools/dsp_txt2bin.py`) and checks `rom/SHA256SUMS.3606` (`README.md:113-119`). The binary reads
it from `--rom-dir`, default **`/opt/GSM`** (`src/main.c:79,105`). Dockerfile command (`:736`):

```bash
bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom
```

Expected (`fetch-rom.sh:46,57,65`):

```
telechargement : ftp://ftp.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
somme de controle verifiee (SHA256SUMS.3606)
ROM DSP 3606 ecrite dans /opt/GSM
ROM DSP 3606 ecrite dans /opt/GSM/c54x_exe/rom
```

(download / checksum verified / ROM written to.) Run again, it says `ROM DSP 3606 deja en place
et verifiee` ("already in place and verified"). Options: `--version 3311` (D-Sample),
`--force`, mirror via `FREECALYPSO_URL=` (`fetch-rom.sh:2-15,30`). The installer first copies
an already verified ROM found on the machine (what `cp c54x_exe/rom/*.bin /opt/GSM/` used to do in
`Dockerfile.run`): no network needed if it is there.

### Checking the DSP alone (`verify` step)

```bash
./c54x_exe --trames 200    # the ROM alone, no ARM: does it boot? (README.md:66)
./c54x_exe --help
```

Optional ISA test (`Makefile:54-61`): `make isa_test && ./isa_test tools/isa_tests.txt 2>/dev/null`.

## The DSP bridge

The bridge connecting your osmo-bts-trx to the DSP lives in **osmo-operator**, not here
(`README.md:82-83`, `run.sh:37-41`). The tree is enough, nothing to compile:

```bash
git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator
cd /opt/GSM/osmo-operator && python3 pont/pont_dsp.py --help
```

`pont_dsp.py` requires `--dsp-port 6702` (`pont/README.md` §0). It reads the timeslot table from
`PONT_BSC_CFG` (default `/etc/osmocom/osmo-bsc.cfg`): point it at **your** BSC config.

## Running

Against your already started stack (osmo-bts-trx included):

```bash
cd /opt/GSM/c54x_exe
PONT=1 INSNS=120000 CALYPSO_BSP_STREAM=1 CALYPSO_RHEA_DMA_XFER=1 \
  PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
./run.sh --status | --logs | --stop        # README.md:76-79
```

- `PONT=1`: without it, no bridge, no burst arrives (`run.sh:197-198`).
- `INSNS=120000`, `CALYPSO_BSP_STREAM=1`, `CALYPSO_RHEA_DMA_XFER=1`: what `start-native.sh` sets
  before handing over to this `run.sh` (block « LE BANC DSP : RÉGLAGES MESURÉS », "DSP bench:
  measured settings"); the default in `run.sh:49` is 16000, "TCH measured up to 87000 insn/frame".
  `CALYPSO_RHEA_DMA_XFER`: "without it the API page is never filled: no SB, no BCCH, no SI".
- Other variables: `MODE`, `LOCKSTEP` (1), `VERB`, `IQ`, `AMP`, `QOSMO`, `FIRMWARE_ELF`, `FIRMWARE_BIN`,
  `OSMOCON`, `MOBILE`, `MOBILE_CFG`, `PONT_PY`, `RUNDIR`, `L2_SOCK`, `C54X_BIN` (`run.sh:19-21`, `README.md:144`).
- Logs: `/tmp/c54x-pont/{dsp,qemu,osmocon,mobile,pont}.log`, sessions archived in
  `/tmp/c54x-pont/archives/<date>/` (`run.sh:249-270`).

Process-by-process details: [Lancer-a-la-main](Lancer-a-la-main.md).

All-in-one variant for a **systemd** stack: `./run_real.sh [--secondes N]` (starts
`osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc`, restarts `osmo-bts-trx`, runs `run.sh` with
`INSNS=60000`, watches for 120 s and prints a verdict). `./run_real.sh --stop`.

## What proves it works

| Line | File | Source |
|---|---|---|
| `pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)` | dsp.log | `src/pont.c:2114` |
| `pont : RESET #1 (DL_STATUS=...) fn=... pc=0xff80` then `pont : DSP boote (premier IDLE)` | dsp.log | `src/pont.c:1608,1921`, `LAUNCH.md:97` |
| `[trx] pont DSP : API RAM partagee (...) + socket /tmp/calypso_dsp.sock` | qemu.log | `qosmo/hw/arm/calypso/calypso_trx.c:318` |
| `[montant] RACH ra=0x.. bsic=..` ; `pont.log` goes from `rach=0` to `rach=N` | dsp.log / pont.log | `LAUNCH.md:66-67` |
| `[montant] TCH : le firmware poste la tache 13 a fn=..., BSP bascule sur TS2` | dsp.log (during a call) | `LAUNCH.md:68-69` |

## Troubleshooting

| Symptom | Cause / fix | Source |
|---|---|---|
| link fails on `gsm0503_*` | pkg-config cannot find libosmocoding (error hidden) | `Makefile:14` |
| `Illegal instruction` at startup | `-march=native` binary from another machine: rebuild here (`./install.sh`), or `--portable` for a binary that travels | `Dockerfile:726-728`, `iso_modules/52-qemu.sh` |
| `c54x_exe n'a pas ouvert /tmp/calypso_dsp.sock` ("did not open") | ROM missing from `--rom-dir`? `./install.sh --only rom` (or `rom/fetch-rom.sh --dest /opt/GSM`); see dsp.log | `run.sh:104` |
| rebuild without touching the binary of a running bench | `./install.sh --dest /tmp/c54x-neuf` then compare / replace once stopped | `install.sh --dest` |
| `somme de controle differente` ("checksum mismatch") | modified dump or wrong version | `fetch-rom.sh:55-56` |
| `QEMU n'a pas rejoint le DSP` ("QEMU did not join the DSP") | QEMU without `CALYPSO_DSP_EXTERN=1`, or DSP not ready yet | `run.sh:144-145` |
| `pont.py ne s'est pas annonce` ("pont.py did not announce itself") | inherited `PONT_PY` pointing at `pont.py` (gr-gsm): `env -u PONT_PY` | `run.sh:206`, `start-native.sh` `banc_dsp()` |
| `FBSB RESP: result=255` in a loop | no bridge or no BTS: normal without a network | `LAUNCH.md:138` |
| `DL bursts=0` | no BTS is transmitting to 5700-5702: check the `phy` section of your osmo-bts-trx | `LAUNCH.md:157-158` |
| SB decoded only one time in three to five | known limitation; `L23_SYNC_RETRIES_SELECTION=8` set by run.sh | `README.md:17-19`, `run.sh:183-189` |
| `le port VTY 4347 ... deja pris` ("already taken") | another mobile; change `bind 127.0.0.1` in the cfg | `run.sh:177-181` |
| dirty state after a crash | `./run.sh --stop` purges sockets and `/dev/shm/calypso_*` | `run.sh:210-237` |

## TO BE CONFIRMED

- (fixed on 2026-10-03) `GDB_TELNET_PY` pointed at `/opt/GSM/qosmo-dsp/tools/gdb-telnet.py`
  (repository gone): `run.sh:48` now uses `$QOSMO/tools/gdb-telnet.py`, and the
  `telnet 0 44444` console starts with step 2 (`GDB=0` to do without it).
- `mobile_pont.cfg` sends GSMTAP to `172.20.0.1` (the bench's docker gateway): replace with
  `127.0.0.1` outside a container.
- Which `INSNS` value to keep (16000 / 60000 / 80000 / 120000 depending on the source).
