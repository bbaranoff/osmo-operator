# FreeCalypso Magnetite in qosmo (the original TI firmware, Motorola C139)

The original ARM firmware (TI TCS211, rebuilt by Mychaela Falconia's FreeCalypso
Magnetite project) runs in the repository's Calypso emulator (qosmo) in place of
the osmocom-bb `layer1`: Nucleus, the TI GSM L2/L3 stack, the BMI user interface
and the RVTMUX traces. The emulated phone is a **C139** (96x64 colour screen on
uWire, same Compal keypad as the C123), because it is the only Mot C1xx target
for which Magnetite has a configuration with a user interface (`c139
hybrid-ui-vo`); the C11x/C123 target only has an AT pseudo-modem.

← [README](../README.md) · Related: [README-dsp](README-dsp.md), [README-architecture](README-architecture.md)

## Install

```bash
sudo ./addition.sh --magnetite
```

This installs Wine and the TI TMS470 environment, clones FreeCalypso Magnetite
and the FreeCalypso host tools, applies the bench patch, builds the firmware and
assembles the flash image (logic in `tools/osmo-firmwares-install.sh`).
`./addition.sh --status` shows whether the image is present.

## Sources and toolchain

Magnetite does **not** build with gcc (nor with `/root/gnuarm`): the whole tree
(sources, `.s` files in TI syntax, COFF `.lib` blobs, Nucleus) requires the TI
TMS470 1.22e compiler, a Windows binary run under Wine.

| path | content |
|---|---|
| `/opt/GSM/fc-magnetite` | Magnetite source tree (`freecalypso-env/` included) |
| `/opt/GSM/fc-host-tools` | FreeCalypso host tools: `rvinterf`, `fc-shell`, `fc-fsio` |
| `/opt/GSM/fc-wine-dl` | the TI Wine environment archive (`installed-env.tar.xz`), `nowhine.c` |
| `/opt/GSM/fc-dl` | the Compal boot loader `compal-flash-boot-for-fc.bin` |
| `/opt/GSM/firmware/magnetite/c139-flash.img` | the 4 MiB flash image used by the bench |

Manual build, equivalent to what the installer does:

```bash
dpkg --add-architecture i386 && apt-get update && apt-get install -y wine wine64 wine32:i386
# TI environment (compiler, cygwin, perl, java): freecalypso-env/installed-env.tar.xz
mkdir -p ~/.wine/drive_c && tar xJf installed-env.tar.xz -C ~/.wine/drive_c && wineboot -u
gcc -O2 -o /usr/local/bin/nowhine nowhine.c      # wrapper that silences Wine's warnings
cd /opt/GSM/fc-magnetite && patch -p1 < /opt/GSM/osmo-operator/patches/fc-magnetite-banc.patch
(cd helpers && make) && ./configure.sh c139 hybrid-ui-vo
cd build-c139-hybrid-ui-vo && make               # no -j: parallel cl470 runs clobber each other's temp files
```

The installer builds the bench variant with `DWNLD 0` in `config/swconfig.cfg`
(directory `build-c139-hybrid-ui-vo-nopatch`); `FC_MAGNETITE_DWNLD=1` builds the
original configuration, and `OSMO_FW_REFAIRE=1` forces a rebuild. The output is
`fwimage.bin` (2 MB, flashed at 0x10000) and `flash-script`.

Bench patches (in [`patches/`](../patches/)):

| patch | applies to | purpose |
|---|---|---|
| `fc-magnetite-banc.patch` | fc-magnetite | all bench changes in one file (forced ARFCN, automatic registration, SMS, MMI) |
| `fc-magnetite-alr-arfcn-forced.patch` | fc-magnetite | forced default ARFCN in ALR cell selection (`ARFCN_FORCED`) |
| `magnetite-sms-msginfo-doublefree.patch` | fc-magnetite | SMS message-info double free in the BMI |
| `magnetite-parole-ul-au-go.patch` | c54x_exe | uplink speech capture for the TI firmware on the DSP bench |

## The flash image

On a C1xx the boot ROM is out of circuit: the CPU starts at 0 in flash, where
the Compal boot loader (FreeCalypso build `compal-flash-boot-for-fc.bin`, 8 KB)
jumps to 0x10058. The 4 MiB image is laid out as:

```
img = 0xFF * 4 MiB ; img[0:8192] = compal-flash-boot-for-fc.bin ; img[0x10000:] = fwimage.bin
```

The firmware's flash file system (FFS: IMEI, afcparams, rfcap, configuration)
lives at 0x3C0000 (3 sectors of 64 KB). When the installer updates an existing
image it only rewrites the firmware area, keeps the boot loader and FFS, and
saves the previous image as `c139-flash.img.avant-supplement`.

## Emulation support in qosmo

| file | what it provides for Magnetite |
|---|---|
| `hw/arm/calypso/calypso_uwire.c` | uWire controller at 0xFFFE4000 + C139 screen (9-bit words on CS0, window 0x10-0x15, RGB565); publishes `/dev/shm/calypso_lcd` with the magic `C139LCD`; property `c139-lcd`, set by `CALYPSO_LCD=c139` |
| `hw/arm/calypso/calypso_mb.c` | without `-kernel` and with `-drive if=pflash`: no fake vectors, boot at 0; 16-bit flash identified as Intel 0x0089 / 0x88C4 (28F320C3B, the C139 part recognised by `ffs/board/dev.c`) |
| `hw/arm/calypso/calypso_soc.c` | flash boot: writing CNTL_ARM_CLK does not remap IRAM at 0 |
| `hw/ssi/calypso_spi.c` | real TWL3025 framing (bit 0 read, register in bits 5..1, data in 15..6, answer in RX_LSB), STATUS = RE_ST and WE_ST, VRPCSTS = ONBSTS (ON button released), VRPCSIM returns RSIMRSU |
| `hw/arm/calypso/calypso_trx.c` | the TDMA frame IRQ (Nucleus tick) starts on the first `TP_Enable`, since TI never writes TPU_INT_CTRL |
| `hw/arm/calypso/calypso_sim.c` | ATR in manual mode, TX interrupt one character time after each byte (`CALYPSO_SIM_US_OCTET`, default 1040 µs), T=0 procedure byte, GSM 11.11 SELECT answers; a silence of more than 500 ms inside an APDU resynchronises it |
| `hw/char/calypso_uart.c` | RX wake-up interrupt (SCR[4] / SSR[1]) of the TI driver; no romload stub in flash boot; `CALYPSO_UART_DEBUG=1` traces IER/SCR/RX |
| `target/arm/tcg/translate.c`, `target/arm/tcg/hflags.c` | ARMv4T behaviour: BX to ARM state ignores bit 1; no alignment fault (the TI flash driver writes a halfword at odd address 0x5555) |

The CPU must be **ti925t** (ARMv4T). With arm946 (ARMv5) the `pop {pc}` of TI's
Thumb trampolines interworks to ARM state and crashes on the first call.

## Running

Standalone, with the qosmo gr-gsm layer 1 (no DSP):

```bash
scripts/magnetite-c139.sh start        # QEMU + rvinterf; RUNDIR /dev/shm/magnetite; persistent working flash
scripts/magnetite-c139.sh gtk          # the window: C139 photo, colour screen, clickable keys
scripts/magnetite-c139.sh traces       # rvinterf.log (decoded L1, GPF, Riviera traces)
scripts/magnetite-c139.sh fsio ls /    # fc-fsio on the rvinterf socket (also: shell → fc-shell)
scripts/magnetite-c139.sh status | log
scripts/magnetite-c139.sh stop
```

| variable | effect |
|---|---|
| `QEMU` | QEMU binary (default `/opt/GSM/qosmo/build/qemu-system-arm`) |
| `FLASH` | source flash image (default `/opt/GSM/firmware/magnetite/c139-flash.img`) |
| `RUNDIR` | run directory (default `/dev/shm/magnetite`) |
| `FLASH_RESET=1` | restart from the pristine image (empty FFS); a newer source image also replaces the working copy |
| `RVINTERF=0` | do not start rvinterf (otherwise traces go to `$RUNDIR/rvinterf.log`, socket `$RUNDIR/rvinterf.sock`) |
| `QEMU_CPU` | default `ti925t` |
| `QEMU_DEBUG=1`, `QEMU_DEBUG_FLAGS` | `-d` flags (default `guest_errors,unimp`) into `qemu-debug.log` |
| `QEMU_GDB=1`, `QEMU_GDB_PORT`, `QEMU_GDB_WAIT=1` | gdb stub on `tcp::1240` (gdb-multiarch, addresses from `fwimage.map`); `-S` to freeze at start |
| `QEMU_TRACE` | QEMU trace pattern, e.g. `'pflash_*'` |
| `CALYPSO_LCD_DEBUG=1` | LCD commands on stderr |

On the DSP bench (c54x_exe, emulated DSP ROM): `c54x_exe/run.sh` with
`FIRMWARE_FLASH=/opt/GSM/firmware/magnetite/c139-flash.img` (CPU ti925t,
`CALYPSO_LCD=c139`, rvinterf at step 3 instead of osmocon, no `mobile` at
step 4; air link or bridge unchanged). `start-native.sh --ms-magnetite` sets
this up: like `--ms`, but the phone is Magnetite. With `--bts --ms-magnetite`
the BTS is instance 1 and the Magnetite C139 is instance 2 over the air; the
flash image is only given to the phone, the BTS TRX keeps the `trx` firmware.
With `--gapk`, voice is coded by the bridge (there is no L2/L3 mobile for GAPK).

The window: `tools/osmo-c123-gtk.py --modele c139 [--instance N]`; the model is
otherwise picked automatically from the shared screen's magic, and the window
switches to C139 by itself when it changes. Photo `data/c139.jpg` (Raimond
Spekking, Wikimedia Commons, CC BY-SA 4.0, credit in `data/c139.txt`), key zones
`data/c139-zones.json` (`--calibrate` to redo them).

## Debugging

- Breakpoints disturb the firmware; prefer `QEMU_DEBUG_FLAGS=int,in_asm`, or
  dump the Nucleus task list from the monitor (`TCD_Created_Tasks_List` at
  0x80cd60).
- `QEMU_TRACE='pflash_*'` traces flash programming.
- `fc-fsio` / `fc-shell` work over ETM through rvinterf.

## Known issues

- Calls only work with ciphering off (`ENCRYPTION="a5 0" ./start.sh --regen …`).
- Formatting the FFS with `fc-fsio format /` erases and programs the 3 blocks,
  then the firmware ends in `os_SystemError`.
- The DSP patch download of the TI L1 (`DWNLD 1`) fails under emulation
  (`LA_LoadPage`), hence the `DWNLD 0` bench build. `L1_DYN_DSP_DWNLD` stays at 1
  (`l1audio_async.c` does not compile with 0).
