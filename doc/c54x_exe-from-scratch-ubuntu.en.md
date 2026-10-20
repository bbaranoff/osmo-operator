# c54x_exe from a clean Ubuntu 24.04

Oct 20, 2026 · Bastien Baranoff

## What this page shows

In about twenty minutes, the emulated TMS320C54x core of `c54x_exe` loads the TI mask ROM of a real Calypso and runs it, without QEMU, without the ARM, without a GSM network.

This is the DSP's hello world: it proves the core executes real TI code. It does not prove the DSP decodes anything, since no burst is injected. The full setup (ARM under QEMU, BTS, bridge, voice call) is described at the end of the page and lives in [osmo-operator](https://github.com/bbaranoff/osmo-operator).

Everything runs as root or with `sudo`; the `/opt/GSM/…` paths are the ones the Makefiles and scripts expect by default.

## 1. Prerequisites (Ubuntu 24.04)

One `apt` line is enough: the compiler, `git`, `curl` for the ROMs, and `libosmocore` (which contains `libosmocoding`, used by `calypso_bsp.c`).

```bash
sudo apt update
sudo apt install -y build-essential git curl pkg-config libosmocore-dev
sudo mkdir -p /opt/GSM
```

Check that `libosmocoding` is there:

```bash
pkg-config --modversion libosmocoding
```

If `pkg-config` cannot find it, the `libosmocore` of the Ubuntu repository is too old or incomplete; install `libosmocore-dev` from the Osmocom nightly repository instead (see [osmocom.org](https://osmocom.org/projects/cellular-infrastructure/wiki/Binary_Packages)).

## 2. The qosmo sources

`c54x_exe` does not copy the C54x core: it compiles the [qosmo](https://github.com/bbaranoff/qosmo) sources directly (`calypso_c54x.c` and its neighbours) with ~120 lines of QEMU header stand-ins. The repository must be on disk, but it does not need to be built.

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/qosmo
```

No `configure`, no `make` here. If qosmo is somewhere other than `/opt/GSM/qosmo`, pass `QOSMO=/path` to the `make` of the next step.

## 3. Clone and build c54x_exe

The build takes less than a minute and produces a single binary, `c54x_exe`, at the root of the repository.

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/c54x_exe
cd c54x_exe
make QOSMO=/opt/GSM/qosmo \
     CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args \
             -Wno-unused-function -Wno-unused-variable \
             -Wno-unused-but-set-variable -Wno-sign-compare"
```

This `CFLAGS` is the one of the osmo-operator Dockerfile: it keeps format errors fatal and silences the unused-variable warnings, numerous in the QEMU sources taken as they are. A bare `make` works too but is much noisier.

`make` rebuilds the binary on every call (`.PHONY` target); no `make clean` is needed after a change in qosmo.

Check:

```bash
./c54x_exe --help | head
```

## 4. The DSP ROMs, from FreeCalypso

The C54x mask ROM is not in the repository: it comes from the dump published by the [FreeCalypso](https://www.freecalypso.org/) project (Mychaela Falconia) on its public FTP. The `rom/fetch-rom.sh` script downloads it and splits it into the 7 sections `--rom-dir` expects.

```bash
cd /opt/GSM/c54x_exe
export FREECALYPSO_URL=ftp://ftp.freecalypso.org/pub/GSM/Calypso
bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom
curl -fsS --retry 2 -o /opt/GSM/calypso_dsp.txt "$FREECALYPSO_URL/dsp-rom-3606-dump.txt"
cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt
```

`3606` is the DSP ROM version of the Calypso in the Motorola C1xx; it is also the value the DSP L1 writes into the API RAM at boot, which will later confirm that the right ROM is running.

After the script, `/opt/GSM` must contain exactly these 7 files:

```bash
ls -l /opt/GSM/calypso_dsp.*.bin
# calypso_dsp.PROM0.bin  calypso_dsp.PROM1.bin  calypso_dsp.PROM2.bin
# calypso_dsp.PROM3.bin  calypso_dsp.DROM.bin   calypso_dsp.PDROM.bin
# calypso_dsp.Registers.bin
```

If `curl` refuses FTP (some builds come without it), download the dump by hand from the same directory on ftp.freecalypso.org and give the local file to `fetch-rom.sh`.

## 5. First run: the ROM runs

```bash
cd /opt/GSM/c54x_exe
./c54x_exe --trames 200
```

`--trames 200` runs the DSP for 200 TDMA frames (one frame = 4.615 ms of GSM time), with the default budget of 2300 instructions per frame in standalone mode. Without options only core errors go to stderr; the final summary says how many lines were hidden and which `-v` level shows them.

What you should see, in order:

1. The 7 ROM sections loaded from `/opt/GSM` (or `--rom-dir`).
2. `c54x_reset()`: the ROM restarts at `0xff80`, its reset vector.
3. `BRANCH-TRACE` lines around `PC=0xb41f`: the TI ROM's wait loop, real code executed by the core.
4. A final summary with `a_sch[3] = 0x771a`.

For one line per frame:

```bash
./c54x_exe --trames 50 --verbeux
```

And for core traces, `-v` to `-vvvvvv` (see `--help`).

## 6. Reading the result

`a_sch[3] = 0x771a` is a constant from one run to the next: the ROM booted, parked itself in IDLE and left this state in its API window. It is the proof that the core executes the ROM faithfully up to that point.

What it does not prove: decoding. The API RAM is blank, no burst arrives, the DSP runs idle. A decoder whose output does not depend on its input does not decode; varying the input requires the full setup of section 8.

Useful reference: the `qemu-calypso` README gives `0xf8d8` for the same word. The difference comes from the input (QEMU provides an API RAM initialised by the ARM, here it is empty), not from a bug: two different inputs, two different constants.

## 7. Common errors

| Symptom | Cause | Fix |
| --- | --- | --- |
| `make`: `qemu/osdep.h` or `calypso_c54x.c` not found | qosmo is not at `/opt/GSM/qosmo` | `make QOSMO=/path/to/qosmo` |
| `make`: `osmocom/coding/...` not found | `libosmocore-dev` missing or too old | section 1, Osmocom nightly repository |
| `fetch-rom.sh` fails or `curl: (1) Protocol "ftp" not supported` | `curl` built without FTP, or a firewall | download by hand, then `fetch-rom.sh` on the local file |
| `c54x_exe`: ROM not found | the `.bin` files are not in `/opt/GSM` | `--rom-dir /path` or redo section 4 |
| The summary does not show `0x771a` | wrong ROM, or badly split sections | compare `rom/calypso_dsp.txt` with the 3606 dump; redo section 4 |
| `PC=0xb41f` never appears, the core exits with an error | regression in qosmo | `cd /opt/GSM/qosmo && git log -3`, go back to the README's commit |

## 8. Next: injecting bursts

For the DSP to really decode, you need the ARM (the osmocom-bb `layer1.highram.elf` firmware under the `qosmo` QEMU), a BTS and the bridge that delivers bursts to it. Two paths:

**The complete bench.** It installs everything, in the same `/opt/GSM/…` paths as this page:

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./install.sh
sudo ./start-direct.sh --dsp
```

`--dsp` replaces the gr-gsm layer 1 with `c54x_exe`; `--menu` asks the same question interactively. The [osmo-operator wiki](https://github.com/bbaranoff/osmo-operator/wiki) describes the options, the ports and the numbering plan.

**Executable by executable.** To watch each step produce its log: the DSP (`c54x_exe --arm -v`), then QEMU with `CALYPSO_DSP_EXTERN=1`, then `osmocon`, then `mobile`. The sequence, with the expected log lines at each step, is in [LAUNCH.md](https://github.com/bbaranoff/c54x_exe/blob/main/LAUNCH.md) and the [c54x_exe README](https://github.com/bbaranoff/c54x_exe#readme).

From there, `a_sch` changes with the input, and the question "does it decode?" has a measurable answer.

## 9. The Calypso firmware: the arm-elf toolchain (gnuarm)

The osmocom-bb firmware (`layer1.highram.elf`, `trx.highram.elf`...) is built with the historical `arm-elf` toolchain (gcc 4.5.2, binutils 2.21.1, newlib 1.19) from the [gnu-arm-installer](https://github.com/axilirator/gnu-arm-installer), installed in `/root/gnuarm/install`. On Ubuntu 24.04 its `cc1` asks for `libmpfr.so.4`, which the system no longer ships (it has `libmpfr.so.6`); a symlink is enough:

```bash
ln -sf /usr/lib/x86_64-linux-gnu/libmpfr.so.6 /usr/local/lib/libmpfr.so.4 && ldconfig
/root/gnuarm/install/bin/arm-elf-gcc --version      # gcc 4.5.2
```

The `osmocom-bb-transceiver` tree (jolly/testing branch, `trx` application) also builds with the system's `arm-none-eabi-gcc`, with the adaptations of `patches/osmocom-bb-transceiver-qemu-bench.patch` (prefix, linking through gcc, `-fcommon`, `solve_envs.py` ported to Python 3):

```bash
cd /opt/GSM/osmocom-bb-transceiver/src/target/firmware
make BOARDS=compal_e88 APPLICATIONS=trx ENVIRONMENTS=highram CROSS_COMPILE=arm-none-eabi-
cp board/compal_e88/trx.highram.{elf,bin} /opt/GSM/firmware/board/compal_e88/
```

Every patch applied to the osmocom-bb trees (mobile, transceiver, burst-ind) lives in `patches/` of osmo-operator and is applied by the Dockerfile and `install_modules/40-patches.sh`.
