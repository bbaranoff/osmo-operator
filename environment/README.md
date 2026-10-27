# `environment/` — bench configuration, by domain

The files in this directory define the environment of the native bench
(`start-native.sh` / `start.sh`): which profile runs, where the dependencies
live on this machine, and where runtime files go. Every file uses the `:=`
idiom ("set only if not already set"), so **the first writer wins**, and the
first writer is always the command line.

| File | Domain | Edit it? |
|---|---|---|
| `load.env` | single entry point; sources the other files in order | no |
| `modes.env` | ready-made profiles (`CALYPSO_PROFILE` / `MODE`) | yes, pick one |
| `paths.env` | where the dependencies are on **this** machine (installation paths) | yes, first thing to adjust |

Per-domain files `coeur.env`, `radio.env`, `reseau.env`, `debug.env` are
sourced by `load.env` if present; the repository does not ship them.

## How it is loaded

```bash
set -a ; . ./environment/load.env ; set +a      # done by startup_scripts/04-environnement.sh
```

Order, first writer wins:

1. the **command line** — `VAR=x ./start-native.sh` always wins;
2. `modes.env` — the chosen profile;
3. `paths.env` — where things are;
4. `coeur.env`, `radio.env`, `reseau.env`, `debug.env` (optional);
5. `$OQC_ROOT/environnement/paths.env` — the Calypso emulation tree's own
   paths (`FIRMWARE_ELF`, `DSP_PROM0..3`, `OSMOCON`, `QEMU_CFGS`...), sourced
   last by `paths.env` so nothing above is overridden.

`load.env` looks for the files in its own directory only: a copy of the tree
without `environment/` loads nothing.

## `modes.env` — profiles

`CALYPSO_PROFILE` is the profile; `MODE` (historical name) wins if set.

```bash
CALYPSO_PROFILE=faketrx ./run.sh
MODE=faketrx ./start-native.sh
```

| Profile | Aliases | Content |
|---|---|---|
| `core` | `noproc` | STP + HLR + MSC + MGW + BSC (+ Asterisk), no radio (default) |
| `faketrx` | | core + osmo-bts + fake_trx + trxcon + mobile, no QEMU |
| `virtphy` | | core + osmo-bts-virtual + virtphy + mobile |
| `calypso` | `qemu` | core in no-process mode + the Calypso emulation (delegated to `OQC_ROOT`) |
| `hybrid` | `faketrx-qemu` | core + live fake_trx + attached Calypso |
| `hw` | | physical SDR |
| `virtual` | | SS7 multi-operator over `ip netns`; `N_OPERATORS` (default 1) |

An unknown profile prints the list on stderr and continues.

## `paths.env` — installation paths

All overridable from the environment; check with `./run.sh --check-paths`.

| Variable | Default | Role |
|---|---|---|
| `GSM_ROOT` | `/opt/GSM` | installation root |
| `NITB_TREE` | this repository | `NITB_SCRIPTS`, `NITB_CONFIGS`, `NITB_HELPERS` derive from it |
| `CALYPSO_FORK` | `qosmo` | name of the Calypso emulation tree |
| `OQC_ROOT` | `../<fork>` next to this tree, else `$GSM_ROOT/<fork>` | the emulation tree (`run.sh`, `run_modules/`, `cfgs/`, `environnement/`) |
| `OSMO_STP`, `OSMO_HLR`, `OSMO_MSC`, `OSMO_MGW`, `OSMO_BSC`, `OSMO_SGSN`, `OSMO_GGSN`, `OSMO_PCU`, `OSMO_BTS_TRX`, `OSMO_BTS_VIRTUAL`, `OSMO_TRX_IPC`, `ASTERISK_BIN` | bare name | Osmocom binaries; a bare name is searched in `PATH` (package install) |
| `OSMOCOM_BB` | `$GSM_ROOT/osmocom-bb` | osmocom-bb tree; `MOBILE_BIN`, `TRXCON_BIN`, `VIRTPHY_BIN`, `FAKE_TRX` derive from it |
| `OSMOCOM_CFG` | `/etc/osmocom` | Osmocom configuration directory |
| `OSMOCOM_HOME` | `$HOME/.osmocom` | |
| `RUN_DIR` | `$XDG_RUNTIME_DIR/osmo-nitb`, else `/run/user/<real uid>/osmo-nitb`, else `/tmp/osmo-nitb` | PID files and monitor socket. Resolved from the real UID so that `sudo` and `sudo -i` launches see the same running stack |
| `LOG_DIR` | `$RUN_DIR/logs` | logs; must stay on a tmpfs (tmux follows them with `tail -F`, which needs inotify) |
| `QEMU_TREE` | `$OQC_ROOT` | the emulation tree as the shared modules name it |
| `QEMU_BIN` | `$OQC_ROOT/build/qemu-system-arm` | |
| `QOSMO_LAUNCHER` | `/usr/local/bin/<fork>` | C launcher (`tools/qosmo-launch`); `40-qemu.sh` falls back to `QEMU_BIN` if absent |

Two switches reduce the log volume if the tmpfs fills up:
`CALYPSO_INTM_TRANS=0` (about half of `qemu.log`) and `CALYPSO_MAILBOX=0`
(removes `mailbox.log`).

## Calypso emulation variables

The `CALYPSO_*` variables read by QEMU and by `c54x_exe` are described in the
emulation tree (`/opt/GSM/qosmo/environnement/README.md`, `bench.env`). The
only reliable view of what QEMU received is the manifest it writes at boot:

```bash
grep "calypso-manifest" /var/log/osmocom/qemu.log
```

Four gate idioms coexist in that code, so `=0` does not always turn a
variable off:

| Idiom | Active when | How to turn off |
|---|---|---|
| `getenv("X") ? 1 : 0` | the variable **exists**, even at `0` | `unset X` |
| `atoi(...) > 0` | value > 0 | `X=0` |
| `*e == '1'` | exactly `"1"` | any other value |
| default ON + `X_OFF` | by default | set `X_OFF` |

## `:=` versus `=`

In these files `: "${VAR:=value}"` lets the command line win; `VAR=value`
**locks** the value. Use `=` only for what must never be overridden.
