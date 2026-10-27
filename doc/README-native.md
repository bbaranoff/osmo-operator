# osmo-operator — native install (no Docker)

The repository installs directly on Ubuntu 24.04 (noble, the same base as the
Dockerfile). The launcher, `start-native.sh` (a symlink to `start.sh`), is the
same one used inside the container and on the ISO.

← [README](../README.md) · Details: [wiki/Start-native](../wiki/Start-native.md), [wiki/Build](../wiki/Build.md), [wiki/Environnement](../wiki/Environnement.md), [wiki/Lancer-a-la-main](../wiki/Lancer-a-la-main.md)

## Install

**The complete native path is the notebook**
[`wiki/installer-osmo-jusquau-dsp.ipynb`](../wiki/installer-osmo-jusquau-dsp.ipynb):
on a fresh Ubuntu 24.04 it builds everything (apt dependencies, Osmocom core,
SMSC, osmocom-bb, firmware, qosmo, c54x_exe, runtime setup) and ends with a
verified call on the DSP. How to run it (disposable container, fresh 24.04,
unattended): [wiki/README-notebook](../wiki/README-notebook.md). The same
steps as plain text: [doc/install-from-scratch](install-from-scratch.md).

`install.sh` is a step engine (`install_modules/NN-<step>.sh`): `prereqs`,
`deps` (apt packages extracted from the Dockerfile), `user` (the `osmocom`
account), `sources`, `patches` (`tools/osmo-patches-apply.sh`), `build`,
`binaires`, `configs`, `bureau` (desktop icons and shortcuts, the same files as
the ISO), `verify`. `GSM_ROOT` (default `/opt/GSM`) receives sources and
binaries.

```bash
sudo ./install.sh                  # every step
./install.sh --list                # show the steps, do nothing
./install.sh --dry-run             # walk through with no side effects
./install.sh --check               # what is already in place
sudo ./install.sh --only deps      # one step
sudo ./install.sh --skip build     # every step but this one
sudo ./install.sh --reinstall      # replay everything, even what is already there
sudo ./install.sh --only bureau    # desktop icons and shortcuts only
```

To install the pieces one by one instead: [wiki/Installer-qosmo](../wiki/Installer-qosmo.md),
[wiki/Installer-grgsm_exe](../wiki/Installer-grgsm_exe.md),
[wiki/Installer-c54x_exe](../wiki/Installer-c54x_exe.md). The supplements
(gnuarm toolchain, Magnetite, extra firmware, 4G…) are `sudo ./addition.sh`
([README](../README.md#supplements)).

## Start and stop

```bash
./start-native.sh --regen     # first run: regenerate configs from the templates
./start-native.sh             # start the bench (delegates to /opt/GSM/qosmo/run.sh)
./start-native.sh --status    # what is running
./start-native.sh --stop      # stops the stack AND the DSP bench, with or without --dsp
```

Every start stops the stack first: there is no hot restart. `--force` only
restarts modules that are already running instead of skipping them.
`--no-attach` starts without attaching to tmux (`CALYPSO_NO_ATTACH=1`), which
is what `osmo-banc.service` uses (`OSMO_BANC_ARGS` in `/etc/default/osmo-banc`).

## Choosing what runs

The layer 1 (who demodulates the air interface):

```bash
./start-native.sh --dsp       # real C54x mask ROM (default)        → README-dsp
./start-native.sh --grgsm     # gr-gsm layer 1                      → README-grgsm
./start-native.sh --menu      # ask interactively
```

The radio setup (see the [modes table](../README.md#modes)): `--bts-classique`
(`osmo-bts-trx` on the bridge, default), `--bts` (the Calypso is the BTS
radio) with `--ts 1|2|2/1`, `--ms` / `--ms-magnetite` (the phone), and the
vocoder, `--vocoder-rom` (default) or `--gapk`.

The profile (how many base stations come up, and how):

| profile | stack |
|---|---|
| `faketrx-qemu` (default) | core + BTS#0 QEMU + BTS#1 faketrx (also `hybrid`) |
| `faketrx` | core + `fake_trx` + `trxcon` + `mobile` |
| `qemu` | the Calypso QEMU pipeline alone |
| `noproc` | core only (also `core`) |

```bash
./start-native.sh faketrx
./start-native.sh --profile qemu
./start-native.sh --list        # show the plan without running it
./start-native.sh --dry-run     # walk through it with no side effects
```

The layer-2 client of the Calypso: `--mobile` (default), `--ccch_scan`,
`--bcch_scan`, `--cell_log`. Identity and network options (`--node`, `--op`,
`--hub-ip`, `--wan`) are in [README-ss7](README-ss7.md). A real SIM card in an
Omnikey reader or the softSIM (`--sap`, `--sap=pcsc`, `--sap=sim`, `--no-sap`)
is in [wiki/SIM](../wiki/SIM.md). `./start-native.sh --help` lists everything.

## The `qosmo` launcher

`run_modules/40-qemu.sh` does not call `qemu-system-arm` directly: it calls
the C launcher `qosmo`, installed next to it by `ninja install`. The launcher
knows which layer 1 its QEMU was built with.

```bash
qosmo -k /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
qosmo --help
```

Defaults: `-M calypso`, `-cpu arm946`, `-gdb tcp::1234`, `-serial pty -serial pty`,
a unix monitor, L1CTL on `/tmp/osmocom_l2`, TRXDv0 on `0.0.0.0:6702`.
`start-native.sh` resolves it (`--launcher <bin>` or `QOSMO_LAUNCHER`), builds
it if the source is there and the binary is not, and falls back to the plain
`qemu-system-arm` command line without it.

## Variables

Which variable wins (command line, environment, `/etc/osmo-role`, defaults) and
what actually reaches QEMU: [wiki/Environnement](../wiki/Environnement.md) and
[`environment/README.md`](../environment/README.md). The network settings
(ARFCN, PLMN, …) are in `globals.conf`, applied by `generate_configs.sh`.
Systemd units: [`services/README.md`](../services/README.md).

Using the running bench (tmux, VTY, Wireshark): [README-usage](README-usage.md).

## Known issues

- `install.sh` does not build the Osmocom core, qosmo, c54x_exe or the
  firmware, so on a stock 24.04 its `verify` step ends with "demons absents".
  Use the notebook for a complete native build; the notebook reuses the
  `deps`, `user` and `configs` steps of `install.sh`.
