# Installing qosmo (QEMU Calypso), and the osmocom-bb firmware

Back: [Telephone-emule](Telephone-emule.md).

**qosmo** (`https://github.com/bbaranoff/qosmO`) is a QEMU fork that adds the `calypso`
machine: the TI Calypso SoC (ARM946) on which the **original, unpatched osmocom-bb firmware**
boots. The same binary serves both layer-1 setups: built with `--enable-l1-grgsm` it embeds the
gr-gsm layer 1; started with `CALYPSO_DSP_EXTERN=1` it cuts that layer out and delegates to the
external DSP `c54x_exe`. It also contains the **sources** that `c54x_exe` and `grgsm_exe` compile
(`hw/arm/calypso/l1-dsp/`, `l1-grgsm/`, `contrib/hors-qemu/`), so install it first. The
repository ships its own installer, `qosmo/install.sh`, also used by the Docker images and
`install.sh`; the manual commands below are what it does, step by step.

## With the installer

```bash
git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo
cd /opt/GSM/qosmo
./install.sh --check          # prerequisites and state of each step -- changes nothing
sudo ./install.sh --deps      # missing apt packages (the list: ./install.sh --print-deps)
sudo ./install.sh             # venv, configure, make, make install, /usr/local/bin, check
```

Steps (`./install.sh --list`), each with an "already done?" test, prerequisites, the work and an
after-the-fact check (the contract of `osmo-operator/install_modules/_lib/inst.sh`):

| Step | Does | Already done if |
|---|---|---|
| `venv` | `python3 -m venv ~/.venv-qemu` + `pip install tomli` | `tomli` importable in the venv |
| `configure` | `mkdir -p build && cd build && ../configure --target-list=arm-softmmu --enable-l1-grgsm --prefix=... --disable-werror --disable-docs` | `build/config.log` has the same options |
| `build` | `make -j$(nproc)` in `build/` (incremental) | always rerun, only rebuilds what changed |
| `install` | `make install` (prefix `/opt/GSM/qemu-install`) | installed binary identical to `build/` |
| `bin` | copies `qemu-system-arm` and `qosmo` into `/usr/local/bin` | identical copies; *not applicable* if the directory is not writable |
| `verify` | `build/qemu-system-arm -M help` must list `calypso ... (couche 1 : grgsm)` | never skipped |

Options (and equivalent variable):

| Option | Variable | Default | Role |
|---|---|---|---|
| `--prefix DIR` | `PREFIX` | `$GSM_ROOT/qemu-install` | where `make install` puts QEMU |
| `--build-dir DIR` | `BUILD_DIR` | `$QOSMO/build` | build out of tree; never run `configure` from the source root, it wipes a `build/` it created |
| `--venv DIR\|none` | `VENV` | `~/.venv-qemu` | venv for configure (`tomli`); `none` = system python |
| `--bin-dir DIR\|none` | `BIN_DIR` | `/usr/local/bin` | copy of the binaries; `none` = no copy |
| `--destdir DIR` | `DESTDIR` | empty | install under another root (ISO rootfs) |
| `--cc NAME` | `QOSMO_CC` | empty | forced compiler, e.g. `gcc-13` when `build/` was configured with it |
| `-j N`, `--only STEPS`, `--skip STEPS`, `--reinstall`, `--with-deps`, `-v` | | | parallelism, step selection, replay, apt packages, output on screen |

Without `-v`, one log per step goes to `/tmp/qosmo-install/`, whose tail is shown on failure.
`GSM_ROOT` (default `/opt/GSM`) sets the default prefix.

Without root: `./install.sh` works if you own `/opt/GSM`; the `bin` step is then *not
applicable* (binaries left in `$PREFIX/bin`), or use `--prefix ~/qemu-calypso --bin-dir none`.

## What the installer does, by hand

### Prerequisites

Ubuntu 24.04 (the bench base). Packages (`./install.sh --print-deps`):

```bash
sudo apt-get install -y --no-install-recommends \
  build-essential git pkg-config python3 python3-venv python3-pip \
  libglib2.0-dev libpixman-1-dev libslirp-dev ninja-build socat
```

`socat` is used to query the QEMU monitor (`qosmo/run_modules/40-qemu.sh`).
`./install.sh --check` checks what matters for `configure` (cc, make, ninja, pkg-config,
`glib-2.0` and `pixman-1` as seen by pkg-config, the `venv`/`ensurepip` module): a package
installed some other way is only a note.

### Build

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

The `bin` step then copies the binaries into the PATH:

```bash
sudo cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm
sudo cp /opt/GSM/qemu-install/bin/qosmo           /usr/local/bin/qosmo
```

> **Keep the tree and `build/`.** The launchers use `/opt/GSM/qosmo/build/qemu-system-arm`
> (`c54x_exe/run.sh`, `qosmo/environnement/bench.env`), and c54x_exe/grgsm_exe compile the
> sources from this tree.

Other configure variants (`qosmo/README.md`): no option (bare platform), `--enable-l1-dsp`
(C54x **inside** QEMU, not used by the bench). The bench only uses `--enable-l1-grgsm`.

### Check

```bash
./install.sh --only verify    # -M help must list "calypso ... (couche 1 : grgsm)"
ls -la /opt/GSM/qosmo/build/qemu-system-arm
/opt/GSM/qosmo/build/qemu-system-arm -M help | grep calypso
qosmo -V          # C launcher (tools/qosmo/qosmo.c): "qosmo <version> (<tree>)"
```

The machine description says which layer 1 is compiled in (`hw/arm/calypso/calypso_mb.c`):
`couche 1 : grgsm` (layer 1: grgsm) is expected.

Starting the machine (needs the firmware, next section), grgsm setup (no `CALYPSO_DSP_EXTERN`):

```bash
/opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 \
  -display none -parallel none -serial pty -serial pty \
  -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
  -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
```

Expected on stderr:

```
char device redirected to /dev/pts/N (label serial0)
[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731
```

and `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock` answers
`VM status: running`. Stop with Ctrl-C.

## Firmware and osmocom-bb

QEMU runs `layer1.highram.elf`; osmocon loads `layer1.highram.bin` via romload; the mobile
speaks L1CTL through osmocon. All three pieces come from osmocom-bb.

**Prebuilt firmware**: the tree `https://github.com/bbaranoff/firmware` (packaged as the
`calypso-firmware` `.deb` by `packaging/build-debs.sh`), nothing to compile:

```bash
git clone --depth 1 https://github.com/bbaranoff/firmware /opt/GSM/firmware
ls /opt/GSM/firmware/board/compal_e88/layer1.highram.{elf,bin}
```

**Rebuilding the firmware** (optional): `sudo ./addition.sh --gnuarm` installs the gnuarm
toolchain (arm-elf-gcc 4.5.2 in `/root/gnuarm/install/bin`, added to PATH by
`/etc/profile.d/97-osmo-gnuarm.sh`); `sudo ./addition.sh --calypso-fw` then recompiles
osmocom-bb (pinned `eac4eed1` + `patches/osmocom-bb-*.patch`) with `cd /opt/GSM/osmocom-bb/src && make`.
With `OSMO_FW_INSTALLER=1`, the layer1 and rssi highram elf+bin are copied into
`/opt/GSM/firmware/board/compal_e88` (layer1 also as `layer1.highram.gprs.*`). The GPRS layer1
(PDCH) exists only as `layer1.highram.bin`, loaded through `loader.compalram.bin`: with GPRS it
no longer fits the 64 KiB the Compal boot loader accepts, so no compalram variant is built.

**osmo-gapk, before osmocom-bb** (the bench mobile uses `tch-voice io-handler gapk`,
`c54x_exe/mobile_pont.cfg`); package `libasound2-dev` required:

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk
cd osmo-gapk && autoreconf -fi && ./configure --enable-alsa && make -j"$(nproc)" && sudo make install && sudo ldconfig
```

**osmocom-bb, host tools only** (requires libosmocore installed). The bench patches
(`patches/osmocom-bb-*.patch`) are applied by `tools/osmo-patches-apply.sh` (idempotent;
`OSMO_PATCHES_ONLY=osmocom-bb` restricts it to this tree):

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/phone-side/osmocom-bb
OSMO_PATCHES_ONLY=osmocom-bb /opt/GSM/osmo-operator/tools/osmo-patches-apply.sh
cd osmocom-bb/src && make nofirmware
sudo install -m755 host/layer23/src/mobile/mobile /usr/local/bin/mobile
```

`osmocon` stays in the tree: `/opt/GSM/osmocom-bb/src/host/osmocon/osmocon` (path expected by
`c54x_exe/run.sh` and `qosmo/environnement/bench.env`).

Check: `ls /opt/GSM/osmocom-bb/src/host/osmocon/osmocon && mobile -h`.

## Useful variables

| Variable | Default | Role |
|---|---|---|
| `CALYPSO_DSP_EXTERN=1` | unset | cuts out the gr-gsm L1, shares the API RAM with `c54x_exe` |
| `CALYPSO_PONT_LOCKSTEP=1` | set by `run.sh` when `LOCKSTEP=1` | QEMU waits for the DSP on every frame |
| `CALYPSO_PONT_RETRY_DIV` | 64 (`run.sh`) | retry rate towards the DSP |
| `CALYPSO_GDB_PORT` | 1234 | ARM gdbstub (`off` to disable) |

The other `CALYPSO_*` variables are documented in `qosmo/environnement/README.md` and in the
headers of `qosmo/run_modules/*.sh`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| CPU at 0, crash at `0x840000`, osmocon loads nothing | missing `-kernel` |
| `QEMU a demarre puis s'est arrete` (QEMU started then stopped) | invalid machine or firmware; see the tail of `qemu.log` |
| SDL "parallel0" window grabbing the keyboard | forgot `-display none -parallel none` |
| `binaire QEMU absent` (QEMU binary missing) | build not done: `./install.sh --only build` (or `ninja -C build qemu-system-arm`) |
| `[FAIL] configure ... manque : glib-2.0 vu de pkg-config` | missing `-dev` package: `sudo ./install.sh --deps` |
| `[SKIP] qemu-system-arm et qosmo dans le PATH (... non inscriptible)` | not root: binaries stay in `$PREFIX/bin`, or use `--bin-dir DIR` |
| ninja fails on the very first unit in a `build/` that came from an image | `build/` configured with gcc-13, `cc` = gcc-11: `./install.sh --only build --cc gcc-13` |
| `/usr/local/bin/qosmo-grgsm` instead of `qosmo` | the `make -C tools/qosmo-launch install` fallback of `start.sh` (unversioned directory); use `make install` in `build/` |
| `osmocon` stuck mid-download | an osmocon killed during romload leaves the UART stub mid-block: restart QEMU, then osmocon |
