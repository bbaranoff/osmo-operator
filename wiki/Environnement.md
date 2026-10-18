# Environment — who wins, and what reaches QEMU

The test bench is driven by environment variables, at three levels:
`start-native.sh` (the preparer), `run.sh` + `run_modules/` (the orchestrator of the
fork), and QEMU itself (the `calypso` machine, which reads its `CALYPSO_*` at boot).
A variable set in the wrong place, or with the wrong idiom, is silently reset to its
default before reaching the last level. This document says where it is read, by whom,
and how to check what QEMU **actually** saw.

---

## 1. Load order

```
1. command line           VAR=x ./start-native.sh          always wins (except § 2)
2. /etc/osmocom/coeur.env N_MS                             `:=`, cannot override anything
3. options                --profile --dsp --node --wan …
4. globals.conf           26 network variables             `=`, but a non-empty caller wins (§ 2)
5. environment/load.env
     modes.env            the profile                      `:=`
     paths.env            where things are                 `:=`
     coeur/radio/reseau/debug.env, then bsp/dsp/fbsb/shunt/rf/armdsp/opcodes.env
     calypso.env          the old monolith                 `:=`, supplies only the rest
6. start-native.sh defaults     RUN_DIR, LOG_DIR, ENCRYPTION, CALYPSO_BRIDGE, MS_COUNT, HOST_IP
7. exec run.sh            the whole environment, intact
8. run_modules/40-qemu.sh → C launcher → QEMU   the manifest is written here
```

All environment files use `: "${VAR:=value}"` — "if not already
set". So **the first one to set a value wins**, and that first one is the
command line.

## 2. The exception: `globals.conf`

`globals.conf` uses `VAR=value` (not `:=`). On the 26 variables it
declares — identity (MCC, MNC, OP_NAME), security (ENCRYPTION, SIM_ALGO, KI, IMSI,
IMEI), radio (ARFCN, BAND, BSIC, LAC, CELL_ID, IPA_UNIT_ID, MS_MAX_POWER,
RXLEV_ACCESS_MIN, CELL_RESEL_HYST), GPRS (BVCI, NSEI, NSVCI, APN), SMS_SC,
MS_COUNT, N_OPERATORS, HOST_IP — it would overwrite the environment if it were
sourced on its own.
Since 2026-09-22, `start-native.sh` sets aside those of these variables that the
caller has set **non-empty**, sources the file (`set -a`), then puts them back,
and prints "globals.conf surchargé par l'environnement : …" (globals.conf
overridden by the environment). The command line therefore also wins on these 26
variables; an empty value always means "computed" and overrides nothing. Only
`start-native.sh` applies this rule, and the header of `globals.conf` still says
the opposite ("écrasent leur homonyme dans l'environnement" — they overwrite
their namesake in the environment).

Everything it does not declare (`CALYPSO_*`, `MODE`, `LOG_DIR`, `QEMU_*`…) passes
through intact. To change one of its 26 values:

```bash
vim globals.conf
./generate_configs.sh ARFCN=520      # rewrites the line
./generate_configs.sh --force        # regenerates the whole file
```

An empty field = computed (often from the operator number). Only pin the
`[auto/operator]` fields if `N_OPERATORS=1`, otherwise the operators step on
each other.

Concrete case: `ENCRYPTION`. `ENCRYPTION="a5 0" ./start-native.sh --dsp` gives
a5 0; before 2026-09-22 it gave a5 1, silently. With nothing on the command
line, the value comes from `globals.conf`; the script's `: "${ENCRYPTION:=a5 1}"`
is only a fallback for the bare ISO or a container without `globals.conf`.

## 3. `:=` versus `=` in your own files

| Syntax | Effect |
|---|---|
| `: "${VAR:=value}"` | default; the command line wins |
| `VAR=value` | **locks it**; no one can override |

Use `=` only for what must never be overridden. A `=` slipped into a per-domain
file is the classic cause of "my variable has no effect".

## 4. The four gate idioms — `=0` doesn't turn everything off

The QEMU code (`hw/arm/calypso/`) reads its variables in four ways. How to
**turn off** a variable depends on the idiom, not on the value:

| Idiom in the code | Active when | To turn off |
|---|---|---|
| `getenv("X") ? 1 : 0` | the variable **exists**, even at `0` | **`unset X`** |
| `atoi(getenv("X")) > 0` | value > 0 | `X=0` |
| `*e == '1'` | exactly `"1"` | any other value |
| default ON + `X_OFF` | by default | set `X_OFF` |

So `FB_ENERGY=0 ./start-native.sh` can leave `FB_ENERGY` **active**. Check the
idiom at the read site (`grep -rn '"X"' hw/arm/calypso/`) or in the reference of
the 312 variables: `hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md`
(default, measured effect, mode, idiom, category, dependencies).

## 5. Variables that set other variables

Some variables are **profiles**: `CALYPSO_NATIVE_HELPED=1` also turns on
`FB_CORR_ENTRY`, `FB_ENERGY` and `FB_IQ_*`. Removing one of them from the command
line does not remove it — it reverts to its default, set by the profile.

## 6. The truth is the manifest

Neither the command line, nor `env`, nor the files say what QEMU saw.
At boot, the `calypso` machine writes a manifest to its log:

```bash
grep "calypso-manifest" /root/qemu.log          # or /var/log/osmocom/qemu.log
```

This is the only reliable source. If a variable is not there at the expected
value, it was reset somewhere between 1 and 8 — walk back up the chain in § 1.

## 7. What reaches QEMU

| Variable | Default | Read by | Role |
|---|---|---|---|
| `CALYPSO_PROFILE` / `MODE` | `faketrx-qemu` (script), `core` (modes.env) | modes.env, run.sh | the profile; `MODE` wins if set |
| `CALYPSO_FORK` | `qosmo-grgsm` | paths.env, start-native | `--dsp` no longer changes it; qosmo-dsp has not been built since 17/09, still reachable by hand (`CALYPSO_FORK=qosmo-dsp`) |
| `OQC_ROOT` | `../<fork>` else `$GSM_ROOT/<fork>` | start-native | the fork's tree; `OQC_ROOT=/path ./start-native.sh` |
| `RUN_SH` | `$OQC_ROOT/run.sh` | start-native | the `run.sh` that is run (overridable since 2026-08-08) |
| `QOSMO_LAUNCHER` | `/usr/local/bin/<fork>` | 40-qemu.sh | the C launcher; absent → historical `qemu-system-arm` |
| `CALYPSO_BRIDGE` | `pont` (`none` with `--dsp`) | run.sh | `none` = QEMU + BTS only; with `--dsp`, it is `c54x_exe/run.sh` that launches `pont_dsp.py`; **never `ipc`** on qosmo-dsp (means MS#1 via osmo-trx-ms-ipc, firmware not launched) |
| `CALYPSO_NO_ATTACH` | | start-native | `1` = do not attach to the tmux (`osmo-banc.service`) |
| `CALYPSO_LANG` | | run.sh | language of the messages |
| `CALYPSO_FIXES` | | QEMU (fixes.env) | the airlock for fixes awaiting validation |
| `QEMU_BIN` | `$GSM_ROOT/qemu/build/qemu-system-arm` | 40-qemu.sh | binary (without launcher) |
| `QEMU_FW` | `$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf` | launcher | ARM firmware |
| `QEMU_DSP_ROM` | `$GSM_ROOT/calypso_dsp.txt` | launcher (`-dsp`) | C54x mask-ROM |
| `QEMU_BRIDGE` | `$OQC_ROOT/bridge.py` | run.sh | the bridge (historical) |
| `QEMU_L1CTL_SOCK` | `/tmp/osmocom_l2` | launcher, mobile | L1CTL socket |
| `QEMU_MON_SOCK` | `/tmp/qemu-calypso-mon.sock` | launcher | HMP monitor |
| `RUN_DIR` / `LOG_DIR` | `/run/osmo-direct` / `$RUN_DIR/logs` | everything | tmpfs — the tmux scrollback depends on it |
| `GSM_ROOT` | `/opt/GSM` | paths.env | root of the installation |
| `N_MS` | `1` (coeur.env) | 21-abonnes-hlr.sh | subscribers provisioned in the HLR |
| `MS_COUNT` | `2` | start-native, globals | mobiles launched |
| `PHY_MODE` | `faketrx` | run.sh (Docker) | `faketrx` / `virtphy` / `qemu`; `qemu` forces `N_MS=1` |
| `OSMO_STP`, `OSMO_MSC`, … | bare name (PATH) | paths.env | Osmocom binaries; empty = packages |

DSP bench (`--dsp`): these variables are read by **c54x_exe** and its `run.sh`,
not by QEMU — so they do not appear in the `calypso` manifest.

| Variable | Default | Read by | Role |
|---|---|---|---|
| `BANC_DSP` | `$GSM_ROOT/c54x_exe/run.sh` | start-native | the bench launched after the fork's plan; `none` to turn it off |
| `INSNS` | `120000` (start-native), `80000` (c54x_exe/run.sh alone) | c54x_exe (`--insns`) | DSP instruction ceiling per frame |
| `LOCKSTEP` | `1` | c54x_exe/run.sh | QEMU only advances the frame once the DSP has finished the previous one |
| `IQ` | `none` | c54x_exe/run.sh | no synthetic cell: the bursts come from the BTS |
| `CALYPSO_BSP_STREAM` | `1` (start-native; not set by `c54x_exe/run.sh` alone) | c54x_exe (`calypso_bsp.c` from `qosmo/hw/arm/calypso/l1-dsp`, compiled in; `src/pont.c` only displays it) | one TS0 burst per frame, in FN order |
| `CALYPSO_RHEA_DMA_XFER` | `1` (start-native) | **no one anymore** | gate removed from the core on 2026-09-18 (qosmo `cf34ab6`): the DMA2 transfer is unconditional; `src/pont.c` only prints the variable in its report. The real gate is `CALYPSO_RHEA_DMA` (default 1, `0` = old silent stub) |

The fine-grained domains (`bsp.env`, `dsp.env`, `fbsb.env`, `shunt.env`, `rf.env`,
`armdsp.env`, `opcodes.env`) carry 311 variables, of which **116 are crutches**:
workarounds for unimplemented branches, each annotated `@BEQUILLE` at its read
site with what it hides and the condition that would make it unnecessary
(`grep -rn "@BEQUILLE" hw/arm/calypso/`). `crutches.env` is touched only to
diagnose; `debug.env` (probes, traces) has no effect on the emulation and can be
modified freely.

## 8. Verification recipe

```bash
./start-native.sh --list                           # the plan: profile, fork, run.sh, launcher
./start-native.sh --dry-run --verbose              # unrolls it, without launching
./start-native.sh --check-paths                    # the declared dependencies
X=1 ./start-native.sh && grep calypso-manifest /var/log/osmocom/qemu.log   # what QEMU saw
grep -rn '"X"' /opt/GSM/qosmo-grgsm/hw/arm/calypso/   # the read idiom
```

If `X` is not in the manifest: either `globals.conf` declares it (§ 2), or a
file sets it with `=` (§ 3), or a profile resets it (§ 5), or it is only read
by the other fork.
