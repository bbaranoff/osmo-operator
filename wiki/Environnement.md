# Environment — who wins, and what reaches QEMU

The test bench is driven by environment variables, at three levels:
`start-native.sh` (the preparer), `run.sh` + `run_modules/` (the orchestrator
of the emulation tree), and QEMU itself (the `calypso` machine, which reads its
`CALYPSO_*` at boot). A variable set in the wrong place, or with the wrong
idiom, is silently reset to its default before reaching the last level. This
page says where each one is read, by whom, and how to check what QEMU
**actually** saw.

---

## 1. Load order

```
1. command line           VAR=x ./start-native.sh          always wins
2. /etc/osmocom/coeur.env N_MS                             `:=`, cannot override anything
3. options                --profile --dsp --node --wan …
4. globals.conf           26 network variables             `=`, but a non-empty caller wins (§ 2)
5. environment/load.env
     modes.env            the profile                      `:=`
     paths.env            where things are                 `:=`
     coeur/radio/reseau/debug.env                          optional, if present
     $OQC_ROOT/environnement/paths.env                     the emulation tree's paths
6. start-native.sh defaults     RUN_DIR, LOG_DIR, ENCRYPTION, CALYPSO_BRIDGE, MS_COUNT, HOST_IP
7. exec run.sh            the whole environment, intact
8. run_modules/40-qemu.sh → C launcher → QEMU   the manifest is written here
```

All environment files use `: "${VAR:=value}"` — "if not already set". So
**the first one to set a value wins**, and that first one is the command line.

## 2. The exception: `globals.conf`

`globals.conf` uses `VAR=value` (not `:=`). On the 26 variables it declares —
identity (MCC, MNC, OP_NAME), security (ENCRYPTION, SIM_ALGO, KI, IMSI, IMEI),
radio (ARFCN, BAND, BSIC, LAC, CELL_ID, IPA_UNIT_ID, MS_MAX_POWER,
RXLEV_ACCESS_MIN, CELL_RESEL_HYST), GPRS (BVCI, NSEI, NSVCI, APN), SMS_SC,
MS_COUNT, N_OPERATORS, HOST_IP — it would overwrite the environment if it were
sourced on its own. `start-native.sh` sets aside those of these variables
that the caller has set **non-empty**, sources the file (`set -a`), then puts
them back, and prints "globals.conf surchargé par l'environnement : …". The
command line therefore also wins on these 26 variables; an empty value always
means "computed" and overrides nothing. Only `start-native.sh` applies this
rule (`generate_configs.sh` does not).

Everything it does not declare (`CALYPSO_*`, `MODE`, `LOG_DIR`, `QEMU_*`…)
passes through intact. To change one of its 26 values:

```bash
vim globals.conf
./generate_configs.sh ARFCN=520      # rewrites the line
./generate_configs.sh --force        # regenerates the whole file
```

An empty field = computed (often from the operator number). Only pin the
`[auto/operator]` fields if `N_OPERATORS=1`, otherwise the operators step on
each other.

Example: `ENCRYPTION="a5 0" ./start-native.sh --dsp` gives a5 0. With nothing
on the command line, the value comes from `globals.conf`; the script's
`: "${ENCRYPTION:=a5 1}"` is only a fallback for the bare ISO or a container
without `globals.conf`.

## 3. `:=` versus `=` in your own files

| Syntax | Effect |
|---|---|
| `: "${VAR:=value}"` | default; the command line wins |
| `VAR=value` | **locks it**; no one can override |

Use `=` only for what must never be overridden. A `=` slipped into a
per-domain file is the classic cause of "my variable has no effect".

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
idiom at the read site: `grep -rn '"X"' /opt/GSM/qosmo/hw/arm/calypso/`.

## 5. Variables that set other variables

Some variables are **profiles**: `CALYPSO_NATIVE_HELPED=1` also turns on
`FB_CORR_ENTRY`, `FB_ENERGY` and `FB_IQ_*`. Removing one of them from the
command line does not remove it — it reverts to its default, set by the
profile.

## 6. The truth is the manifest

Neither the command line, nor `env`, nor the files say what QEMU saw. At boot,
the `calypso` machine writes a manifest to its log:

```bash
grep "calypso-manifest" /var/log/osmocom/qemu.log
```

This is the only reliable source. If a variable is not there at the expected
value, it was reset somewhere between 1 and 8 — walk back up the chain in § 1.

## 7. What reaches QEMU

| Variable | Default | Read by | Role |
|---|---|---|---|
| `CALYPSO_PROFILE` / `MODE` | `faketrx-qemu` (script), `core` (modes.env) | modes.env, run.sh | the profile; `MODE` wins if set |
| `CALYPSO_FORK` | `qosmo` | paths.env, start-native | name of the emulation tree |
| `OQC_ROOT` | `../<fork>` else `$GSM_ROOT/<fork>` | start-native | the emulation tree; `OQC_ROOT=/path ./start-native.sh` |
| `RUN_SH` | `$OQC_ROOT/run.sh` | start-native | the `run.sh` that is run |
| `QOSMO_LAUNCHER` | `/usr/local/bin/<fork>` | 40-qemu.sh | the C launcher; absent → `qemu-system-arm` |
| `CALYPSO_BRIDGE` | `pont` (`none` with `--dsp`) | run.sh | `none` = QEMU + BTS only; with `--dsp`, `c54x_exe/run.sh` launches `pont_dsp.py` |
| `CALYPSO_NO_ATTACH` | | start-native | `1` = do not attach to the tmux (`osmo-banc.service`) |
| `CALYPSO_LANG` | | run.sh | language of the messages |
| `QEMU_BIN` | `$OQC_ROOT/build/qemu-system-arm` | 40-qemu.sh | binary (without launcher) |
| `QEMU_FW` | `$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf` | launcher | ARM firmware |
| `QEMU_DSP_ROM` | `$GSM_ROOT/calypso_dsp.txt` | launcher (`-dsp`) | C54x mask ROM |
| `QEMU_L1CTL_SOCK` | `/tmp/osmocom_l2` | launcher, mobile | L1CTL socket |
| `QEMU_MON_SOCK` | `/tmp/qemu-calypso-mon.sock` | launcher | HMP monitor |
| `RUN_DIR` / `LOG_DIR` | `/run/user/<uid>/osmo-nitb` / `$RUN_DIR/logs` | everything | tmpfs — the tmux scrollback depends on it |
| `GSM_ROOT` | `/opt/GSM` | paths.env | root of the installation |
| `N_MS` | `1` (coeur.env) | 21-abonnes-hlr.sh | subscribers provisioned in the HLR |
| `MS_COUNT` | `2` | start-native, globals | mobiles launched |
| `PHY_MODE` | `faketrx` | run.sh (Docker) | `faketrx` / `virtphy` / `qemu`; `qemu` forces `N_MS=1` |
| `OSMO_STP`, `OSMO_MSC`, … | bare name (PATH) | paths.env | Osmocom binaries; empty = packages |

DSP bench (`--dsp`, the default): these variables are read by **c54x_exe** and
its `run.sh`, not by QEMU — so they do not appear in the `calypso` manifest.

| Variable | Default | Read by | Role |
|---|---|---|---|
| `BANC_DSP` | `$GSM_ROOT/c54x_exe/run.sh` | start-native | the bench launched after the emulation tree's plan; `none` to turn it off |
| `INSNS` | `120000` | c54x_exe (`--insns`) | DSP instruction ceiling per frame |
| `LOCKSTEP` | `1` | c54x_exe/run.sh | QEMU only advances the frame once the DSP has finished the previous one (`CALYPSO_PONT_LOCKSTEP=1`); `0` = wall clock |
| `IQ` | `none` | c54x_exe/run.sh | no synthetic cell: the bursts come from the BTS |
| `CALYPSO_BSP_STREAM` | `1` (start-native) | c54x_exe (`calypso_bsp.c` from `qosmo/hw/arm/calypso/l1-dsp`) | one TS0 burst per frame, in FN order; `IQ` other than `none` is refused with it |
| `CALYPSO_RHEA_DMA_XFER` | `1` (start-native) | nobody (the DMA2 transfer is unconditional); `src/pont.c` only prints it | Known limitation: dead variable |

Workarounds for unimplemented emulator branches are annotated `@BEQUILLE` at
their read site, with what they hide and the condition that would make them
unnecessary: `grep -rn "@BEQUILLE" /opt/GSM/qosmo/hw/arm/calypso/`. The
emulation tree's own variables are described in
`/opt/GSM/qosmo/environnement/README.md`.

## 8. Verification recipe

```bash
./start-native.sh --list                           # the plan: profile, tree, run.sh, launcher
./start-native.sh --dry-run --verbose              # unrolls it, without launching
./start-native.sh --check-paths                    # the declared dependencies
X=1 ./start-native.sh && grep calypso-manifest /var/log/osmocom/qemu.log   # what QEMU saw
grep -rn '"X"' /opt/GSM/qosmo/hw/arm/calypso/      # the read idiom
```

If `X` is not in the manifest: either `globals.conf` declares it (§ 2), or a
file sets it with `=` (§ 3), or a profile resets it (§ 5), or it is only read
by c54x_exe (§ 7).
