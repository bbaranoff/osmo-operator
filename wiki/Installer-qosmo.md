# Installing qosmo (QEMU Calypso) — and the osmocom-bb firmware

> Version of 2026-10-03. Back: [Telephone-emule](Telephone-emule.md).
> The repository ships its own installer, `qosmo/install.sh`: it is also what the
> `Dockerfile` (stage `qemu`), `Dockerfile.run`, `start-docker.sh` and `install.sh --telephone` call.
> The manual commands below are **what the script does**, step by step.
> `Dockerfile:N` numbers refer to the Dockerfile at commit `4266c8b`, back when it still
> carried these commands (it now calls the installer).

**qosmo** (`https://github.com/bbaranoff/qosmO`) is a QEMU fork that adds the `calypso`
machine: the TI Calypso SoC (ARM946) on which the **original, unpatched osmocom-bb
firmware** boots (`qosmo/README.md:1-5`). The same binary serves both setups: built
with `--enable-l1-grgsm`, it embeds the gr-gsm layer 1; started with `CALYPSO_DSP_EXTERN=1`, it
cuts it out and delegates to the external DSP `c54x_exe` (`osmo-operator/Dockerfile:679-682`).

It also contains the **sources** that `c54x_exe` and `grgsm_exe` compile
(`hw/arm/calypso/l1-dsp/`, `l1-grgsm/`, `contrib/hors-qemu/`): install it first.

## With the installer

```bash
git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo
cd /opt/GSM/qosmo
./install.sh --check          # prerequisites and state of each step — changes NOTHING
sudo ./install.sh --deps      # missing apt packages (the list: ./install.sh --print-deps)
sudo ./install.sh             # venv, configure, make, make install, /usr/local/bin, check
```

Steps (`./install.sh --list`), each with an "already done?" test, its prerequisites, the work
and an after-the-fact check — the contract of `osmo-operator/install_modules/_lib/inst.sh`:

| step | does | Dockerfile line | already done if |
|---|---|---|---|
| `venv` | `python3 -m venv ~/.venv-qemu` + `pip install tomli` | 694-696 | `tomli` importable in the venv |
| `configure` | `mkdir -p build && cd build && ../configure --target-list=arm-softmmu --enable-l1-grgsm --prefix=… --disable-werror --disable-docs` | 697-699 | `build/config.log` has **the same** options |
| `build` | `make -j$(nproc)` in `build/` (incremental) | 700 | — (always rerun, only rebuilds what changed) |
| `install` | `make install` (prefix `/opt/GSM/qemu-install`) | 701 | installed binary identical to `build/` |
| `bin` | copies `qemu-system-arm` and `qosmo` into `/usr/local/bin` | 702-703 | identical copies; *not applicable* if the directory is not writable |
| `verify` | `build/qemu-system-arm -M help` must list `calypso … (couche 1 : grgsm)` | — | — |

Options (and equivalent variable): `--prefix DIR` (`PREFIX`, default `$GSM_ROOT/qemu-install`),
`--build-dir DIR` (`BUILD_DIR`, build out of tree — never in the source tree itself:
`configure` run from the root wipes a `build/` it created, `configure:16-45`),
`--venv DIR|none` (`VENV`, default `~/.venv-qemu`), `--bin-dir DIR|none` (`BIN_DIR`, default
`/usr/local/bin`), `--destdir DIR` (install under another root, like the ISO), `--cc gcc-13`
(forced compiler: an image's `build/` was configured with gcc-13, `Dockerfile.run`),
`-j N`, `--only STEPS`, `--skip STEPS`, `--reinstall`, `--with-deps`, `-v` (output on screen;
otherwise one log per step in `/tmp/qosmo-install/`, whose tail is shown on failure).
`GSM_ROOT` (default `/opt/GSM`) sets the default prefix.

Without root: `./install.sh` works if you own `/opt/GSM`; the `bin` step is then
*not applicable* (binaries left in `$PREFIX/bin`), or use `--prefix ~/qemu-calypso --bin-dir none`.

## What the script does, by hand

### Prerequisites

Ubuntu 24.04 (the bench base, `Dockerfile:11-15`). Packages (`./install.sh --print-deps`, taken
from `Dockerfile:159,166,189-190`):

```bash
sudo apt-get install -y --no-install-recommends \
  build-essential git pkg-config python3 python3-venv python3-pip \
  libglib2.0-dev libpixman-1-dev libslirp-dev ninja-build socat
```

`socat` is used to query the QEMU monitor (`qosmo/run_modules/40-qemu.sh:91-96`).
`./install.sh --check` checks what really matters for `configure` (cc, make, ninja,
pkg-config, `glib-2.0` and `pixman-1` as seen by pkg-config, the `venv`/`ensurepip` module): a
missing package that is installed some other way is only a note.

### Build

Taken from `osmo-operator/Dockerfile:691-705`:

```bash
sudo mkdir -p /opt/GSM && sudo chown "$USER" /opt/GSM
git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo
cd /opt/GSM/qosmo
python3 -m venv ~/.venv-qemu && . ~/.venv-qemu/bin/activate
pip install --no-cache-dir tomli
mkdir -p build && cd build
../configure --target-list=arm-softmmu --enable-l1-grgsm \
    --prefix=/opt/GSM/qemu-install --disable-werror --disable-docs
make -j"$(nproc)"
make install
```

The script (`bin` step) then copies the binaries into the PATH (`Dockerfile:702-703`):

```bash
sudo cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm
sudo cp /opt/GSM/qemu-install/bin/qosmo           /usr/local/bin/qosmo
```

> **Keep the tree and `build/`.** The launchers use `/opt/GSM/qosmo/build/qemu-system-arm`
> (`c54x_exe/run.sh:28`, `qosmo/environnement/bench.env:4`), and c54x_exe/grgsm_exe compile the
> sources from this tree. The Dockerfile carries the whole tree, build/ included (`Dockerfile:686-688`).

Documented configure variants (`qosmo/README.md:9-13`): no option (bare platform),
`--enable-l1-dsp` (C54x **inside** QEMU, not used by the current bench). The bench only uses
`--enable-l1-grgsm`.

### Check

```bash
./install.sh --only verify    # -M help must list « calypso … (couche 1 : grgsm) »
ls -la /opt/GSM/qosmo/build/qemu-system-arm
/opt/GSM/qosmo/build/qemu-system-arm -M help | grep calypso
qosmo -V          # C launcher: « qosmo <version> (<tree>) » (tools/qosmo/qosmo.c, option -V)
```

The machine description says which layer 1 is compiled in
(`hw/arm/calypso/calypso_mb.c:111`): `couche 1 : grgsm` ("layer 1: grgsm") expected.

Starting the machine (needs the firmware, next section) — command from
`c54x_exe/LAUNCH.md:75-79`, grgsm setup (without `CALYPSO_DSP_EXTERN`):

```bash
/opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 \
  -display none -parallel none -serial pty -serial pty \
  -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
  -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
```

Expected on stderr (`LAUNCH.md:89-96`):

```
char device redirected to /dev/pts/N (label serial0)
[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731
```

and `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock` → `VM status: running`
(`40-qemu.sh:93-95`). Stop with Ctrl-C.

## Firmware and osmocom-bb

QEMU runs `layer1.highram.elf`; osmocon loads `layer1.highram.bin` via romload; the mobile
speaks L1CTL through osmocon. All three pieces come from osmocom-bb.

**Prebuilt firmware** (`Dockerfile:585-588`; it is "the only place looked at", `Dockerfile:590-598`) —
a clone, nothing to compile. From osmo-operator: `sudo ./install.sh --only firmware`
(`install_modules/45-calypso.sh`); by hand:

```bash
git clone --depth 1 https://github.com/bbaranoff/firmware /opt/GSM/firmware
ls /opt/GSM/firmware/board/compal_e88/layer1.highram.{elf,bin}
```

**osmo-gapk, before osmocom-bb** (the bench mobile uses `tch-voice io-handler gapk`,
`c54x_exe/mobile_pont.cfg`) — `Dockerfile:445-452`:

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk
cd osmo-gapk && autoreconf -fi && ./configure --enable-alsa && make -j"$(nproc)" && sudo make install && sudo ldconfig
```

(package `libasound2-dev` required, `Dockerfile:169`.)

**osmocom-bb, host tools only** (`Dockerfile:548-558`) — requires libosmocore installed:

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/phone-side/osmocom-bb
git -C osmocom-bb apply /opt/GSM/osmo-operator/patches/osmocom-bb-clck-gen-frame-tolerance.patch   # optional: only touches fake_trx (Dockerfile:541-547)
cd osmocom-bb/src && make nofirmware
sudo install -m755 host/layer23/src/mobile/mobile /usr/local/bin/mobile    # Dockerfile:1145-1149
```

`osmocon` stays in the tree: `/opt/GSM/osmocom-bb/src/host/osmocon/osmocon` (path expected by
`c54x_exe/run.sh:31` and `qosmo/environnement/bench.env:10`).

Check: `ls /opt/GSM/osmocom-bb/src/host/osmocon/osmocon && mobile --version` (**TO BE CONFIRMED**:
mobile's `--version` option).

## Useful variables

| Variable | Default | Role | Source |
|---|---|---|---|
| `CALYPSO_DSP_EXTERN=1` | unset | cuts out the gr-gsm L1, shares the API RAM with `c54x_exe` | `LAUNCH.md:84-86` |
| `CALYPSO_PONT_LOCKSTEP=1` | set by run.sh if `LOCKSTEP=1` | QEMU waits for the DSP on every frame | `c54x_exe/run.sh:56-57` |
| `CALYPSO_PONT_RETRY_DIV` | 64 (run.sh) | retry rate towards the DSP | `run.sh:130-133` |
| `CALYPSO_GDB_PORT` | 1234 | ARM gdbstub (`off` to disable) | `40-qemu.sh:59` |

The ~300 `CALYPSO_*` variables are described in `qosmo/hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md`
(`qosmo/environnement/README.md:42-45`); the manifest actually applied is printed by QEMU
(`grep calypso-manifest qemu.log`).

## Troubleshooting

| Symptom | Cause / fix | Source |
|---|---|---|
| CPU at 0, crash at `0x840000`, osmocon loads nothing | missing `-kernel` | `LAUNCH.md:82-83` |
| `QEMU a démarré puis s'est arrêté` ("QEMU started then stopped") | invalid machine or firmware; see the tail of `qemu.log` | `40-qemu.sh:102-106` |
| SDL "parallel0" window grabbing the keyboard | forgot `-display none -parallel none` | `40-qemu.sh:60-67` |
| `binaire QEMU absent` ("QEMU binary missing") | build not done; `./install.sh --only build` (or `ninja -C build qemu-system-arm`) | `40-qemu.sh:10-11` |
| `[FAIL] configure … manque : glib-2.0 vu de pkg-config` | missing `-dev` package: `sudo ./install.sh --deps` | `install.sh --check` |
| `[SKIP] qemu-system-arm et qosmo dans le PATH (… non inscriptible)` | not root: binaries in `$PREFIX/bin`, or `--bin-dir DIR` | `install.sh`, `bin` step |
| ninja fails on the very first unit in a `build/` that came from an image | `build/` configured with gcc-13, `cc` = gcc-11: `./install.sh --only build --cc gcc-13` | `Dockerfile.run:171-175` |
| `/usr/local/bin/qosmo-grgsm` instead of `qosmo` | `make -C tools/qosmo-launch install` fallback in `start-native.sh` (unversioned directory); use `make install` in `build/` | `start-native.sh:692-694` |
| `osmocon` stuck mid-download | an osmocon killed during romload leaves the UART stub mid-block: restart QEMU, then osmocon | `LAUNCH.md:120-121` |
