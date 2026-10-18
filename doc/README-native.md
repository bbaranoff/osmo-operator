# osmo-operator — native install (no Docker)

The repository installs directly on Ubuntu 24.04 (noble, the same base as the
Dockerfile). The launcher, `start-direct.sh`, is the same one used inside the
container and on the ISO.

← [README](../README.md) · Details: [wiki/Start-direct](../wiki/Start-direct.md), [wiki/Build](../wiki/Build.md), [wiki/Environnement](../wiki/Environnement.md), [wiki/Lancer-a-la-main](../wiki/Lancer-a-la-main.md)

## Install

**The complete native path is the notebook**
[`wiki/installer-osmo-jusquau-dsp.ipynb`](../wiki/installer-osmo-jusquau-dsp.ipynb):
on a fresh Ubuntu 24.04 it builds everything (apt dependencies, Osmocom core,
SMSC, osmocom-bb, firmware, qosmo, c54x_exe, runtime setup) and ends with a
verified call on the DSP. Open it with Jupyter in a venv, after `sudo -v`
(instructions in its first cell).

`install.sh` covers only part of it: apt dependencies (extracted from the
Dockerfile), the `osmocom` account, osmocom-bb, gapk, libosmo-dsp, toast, the 4G,
configs and desktop icons. It does **not** build the Osmocom core, qosmo,
c54x_exe or the firmware, so on a stock 24.04 its last step fails with
"demons absents". The notebook reuses its `deps`, `user` and `configs` steps.

```bash
sudo ./install.sh                  # its steps: deps, sources, build, binaries, configs, desktop
./install.sh --list                # show the steps, do nothing
./install.sh --check               # what is already in place
sudo ./install.sh --only deps      # one step
sudo ./install.sh --only bureau    # desktop icons and shortcuts only
```

To install the pieces one by one instead: [wiki/Installer-qosmo](../wiki/Installer-qosmo.md),
[wiki/Installer-grgsm_exe](../wiki/Installer-grgsm_exe.md),
[wiki/Installer-c54x_exe](../wiki/Installer-c54x_exe.md).

## Start and stop

```bash
./start-direct.sh --regen     # first run: regenerate configs from the templates
./start-direct.sh             # start the bench (delegates to /opt/GSM/qosmo/run.sh)
./start-direct.sh --status    # what is running
./start-direct.sh --stop      # stops the stack AND the DSP bench, with or without --dsp
```

Every start stops the stack first: there is no hot restart. `--force` only
restarts modules that are already running instead of skipping them.
`--no-attach` starts without attaching to tmux, which is what
`osmo-banc.service` uses.

## Choosing what runs

The layer 1 (who demodulates the air interface):

```bash
./start-direct.sh --grgsm     # gr-gsm layer 1, works end to end   → README-grgsm
./start-direct.sh --dsp       # real C54x mask ROM (default)        → README-dsp
./start-direct.sh --menu      # ask interactively
```

The profile (how many base stations come up, and how):

| profile | stack |
|---|---|
| `faketrx-qemu` (default) | core + BTS#0 QEMU + BTS#1 faketrx (also `hybrid`) |
| `faketrx` | core + `fake_trx` + `trxcon` + `mobile` |
| `qemu` | the Calypso QEMU pipeline alone |
| `noproc` | core only (also `core`) |

```bash
./start-direct.sh faketrx
./start-direct.sh --profile qemu
./start-direct.sh --list        # show the plan without running it
./start-direct.sh --dry-run     # walk through it with no side effects
```

Identity and network options (`--node`, `--op`, `--hub-ip`, `--wan`) are in
[README-ss7](README-ss7.md). A real SIM card in an Omnikey reader (`--sap`) is
in [wiki/SIM](../wiki/SIM.md).

## The `qosmo` launcher

`40-qemu.sh` does not call `qemu-system-arm` directly: it calls the C launcher
`qosmo`, installed next to it by `ninja install`. The launcher knows which
layer 1 its QEMU was built with.

```bash
qosmo -k /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
qosmo --help
```

Defaults: `-M calypso`, `-cpu arm946`, `-gdb tcp::1234`, `-serial pty -serial pty`,
a unix monitor, L1CTL on `/tmp/osmocom_l2`, TRXDv0 on `0.0.0.0:6702`.
`start-direct.sh` resolves it (`--launcher <bin>` or `QOSMO_LAUNCHER`), builds
it if the source is there and the binary is not, and falls back to the plain
`qemu-system-arm` command line without it.

## Variables

Which variable wins (command line, environment, `/etc/osmo-role`, defaults) and
what actually reaches QEMU: [wiki/Environnement](../wiki/Environnement.md) and
[`environment/README.md`](../environment/README.md). Systemd units:
[`services/README.md`](../services/README.md).

Using the running bench (tmux, VTY, Wireshark): [README-usage](README-usage.md).
