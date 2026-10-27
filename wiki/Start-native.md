# `start-native.sh` — step by step

`start-native.sh` prepares, `run.sh` executes. The script itself is short: it
handles `--docker` (hand-over to `launch/start-docker.sh`) and then sources
`startup_scripts/*.sh` in order, in the same shell. This page follows those
phases: what each one reads, decides and writes, and at what point a variable
is taken into account or overwritten.

```
command line ─► coeur.env ─► globals.conf ─► environment/load.env ─► profile
        │                                                                 │
        └──────── resolve run.sh / fork / QEMU launcher ◄─────────────────┘
                              │
                   generate mobile_*.cfg
                              │
            --stop / --status / --list ? ─── delegated to run.sh, done
                              │
              --regen / --node / --wan / --menu (SS7 identity, WAN table)
                              │
                  stack always stopped first
                              │
             dashboard :8080, oFono hookup, exec run.sh ─► tmux « calypso »
```

---

## 0. Where it runs

The script moves into its own directory (`HERE`). It is the **native**
launcher (ISO, bare host, or inside a container); it does not check for
Docker. Started by mistake on a Docker host without `/opt/GSM/qosmo`, it dies
on « `run.sh` introuvable » (run.sh not found). On a host with Docker, use
`./start-native.sh --docker …` or `./launch/start-docker.sh` directly.

## 1. Loading the environment

In this order, and **the order decides who wins** (details:
[Environnement.md](Environnement.md)):

1. **`/etc/osmocom/coeur.env`** (`OSMOCOM_CFG` to move it): written by
   `build-iso.sh`, carries `N_MS`. Loaded here, not by `~/.bashrc`, so that the
   desktop icon, systemd and `start-multi.sh` see the same value. The file uses
   `:=`: an `N_MS=3` set in the environment wins.
2. **Command-line options** (`--profile`, `--dsp`, `--node`…).
3. **`globals.conf`**: the reference for the network variables (MCC, MNC,
   OP_NAME, ENCRYPTION, ARFCN, BAND, LAC, APN, MS_COUNT, N_OPERATORS,
   HOST_IP…), **except those the caller has already set to a non-empty
   value**: `start-native.sh` records them, reads the file, then sets them
   again, and prints « globals.conf surchargé par l'environnement : … ».
   `ENCRYPTION="a5 0" ./start-native.sh --dsp` does give a5 0. An empty value
   overrides nothing (empty = computed, often from the operator number). To
   change a value: `vim globals.conf` or `./generate_configs.sh ARFCN=520`.
4. **`environment/load.env`**: `modes.env` (the profile), `paths.env` (where
   things are), then the per-domain files. All with `:=`: the first one to set
   a value wins, hence the command line.
5. Minimal fallback if `load.env` is missing (bare ISO, bare container):
   `GSM_ROOT=/opt/GSM`, `CALYPSO_FORK=qosmo`, resolution of `OQC_ROOT`.
6. Remaining defaults: `RUN_DIR=/run/osmo-direct`, `LOG_DIR=$RUN_DIR/logs`
   (tmpfs: tmux scrollback depends on it), `ENCRYPTION="a5 1"` (fallback: the
   real value comes from `globals.conf`), `CALYPSO_BRIDGE=pont` (`none` with
   `--dsp`), `MS_COUNT=2`, `HOST_IP=127.0.0.1`.

## 2. Profile

Default: **`faketrx-qemu`** (alias `hybrid`): core + BTS#0 QEMU + BTS#1
faketrx. `--profile <name>` or the positional mode sets it; `CALYPSO_PROFILE`
or the legacy `MODE` set it from the environment (`MODE` wins if set). `--dsp`
does not touch the profile. An explicitly named profile always wins.

| Profile | What runs |
|---|---|
| `faketrx-qemu` / `hybrid` | core + osmo-bts-trx ← QEMU Calypso + fake_trx/trxcon/mobile |
| `faketrx` | core + fake_trx + trxcon + mobile; no QEMU |
| `virtphy` | core + osmo-bts-virtual + virtphy + mobile |
| `qemu` / `calypso` | the Calypso pipeline alone, core in no-process |
| `core` / `noproc` | STP + HLR + MSC + MGW + BSC (+ Asterisk), no radio |
| `hw` | physical SDR |
| `virtual` | SS7 multi-operator via `ip netns` (`N_OPERATORS`) |

## 3. Resolving `run.sh` and the QEMU launcher

Order: explicit `RUN_SH` > resolved `OQC_ROOT` > `$GSM_ROOT/<fork>/run.sh`.
`OQC_ROOT` is looked up **next to the repository** (`../qosmo`) then under
`/opt/GSM`. If `run.sh` is not executable: FAIL, with the path tried.

The C launcher (`--launcher <bin>`, `QOSMO_LAUNCHER`, default
`/usr/local/bin/<fork>`) is compiled if missing and `<fork>/tools/qosmo-launch`
is present. Without a launcher, `40-qemu.sh` falls back to the plain
`qemu-system-arm` command line.

## 4. Path validation

`--check-paths` stops here after checking every declared dependency (Osmocom
binaries, `layer1.highram.elf` firmware, `calypso_dsp.txt` ROM, bridge).

## 5. Generating `mobile_*.cfg`

`mobile_group1.cfg` (MS#1, behind QEMU) and MS#2 (faketrx) are written to
`$OQC_ROOT/cfgs/` from the templates, with IMSI/Ki/IMEI from `globals.conf`
(or computed per operator). The layer 2 client is `mobile` by default;
`--ccch_scan`, `--bcch_scan`, `--cell_log` **replace** it (they take its
L1CTL socket and its VTY: mutually exclusive).

## 6. Summary

The plan is printed: profile, fork, `run.sh`, launcher, bridge, number of MSs,
ciphering, ARFCN. `--list` stops there (delegated to `run.sh --list`);
`--dry-run` continues without side effects.

## 7. Delegated actions

`--stop` and `--status` are passed to `run.sh` and the script exits.

### 7-menu. `--menu`

Asks **once** for the choices the script would otherwise have guessed:
profile, node, operator, inter-STP, WAN, regeneration. The proposed values are
those of the automatic launch: accepting without changing anything = not
passing the option. Ignored without a terminal.

### 7-regen. `--regen`

By default the existing configs are **kept** (regenerating them at startup
would erase the SS7 identity set just before). `--regen` stops the stack, then
rewrites everything from the templates (current node and operator).

### 7-node. `--node N` / `--op N` / `--hub-ip`

The node number (1 to 9) is **deduced**: environment, then `/etc/osmo-role`,
then the WAN table compared against the local addresses. `--node` forces it.
The script rewrites the SS7 identity (point codes `1.<node><op>.<role>`,
routing contexts) and points the ASP at the inter-STP (`--hub-ip`, otherwise
deduced: docker or VM). This is what makes a single ISO possible for all nine
nodes.

### 7-wan. `--wan`

Never on by default. A `--wan` on the command line applies the WAN **for that
run only**: the table it writes keeps `WAN_AUTO=0`, so the next plain start
has no WAN. Only an ISO built with `--wan` sets `WAN_AUTO=1` in
`/etc/osmo-wan.conf`, which brings the WAN up at every start (and stays 1 when
the table is rewritten). To make a machine a permanent node by hand, set
`WAN_AUTO=1` in that file; to stop it, set `WAN_AUTO=0`. Three forms:

```bash
./start-native.sh --wan                                  # questions: nodes, IPs, prefixes, my number
./start-native.sh --wan-nodes "1:IP:IND 2:IP:IND" --wan-id 2   # scriptable
./start-native.sh --wan mynode1.conf --wan mynode3.conf  # from the other nodes' cards
./start-native.sh --gen-conf [FILE]                      # writes MY card, launches nothing
```

`--regen-conf` rebuilds the table from scratch (the old one is backed up next
to it): use it when a powered-off peer leaves a PROHIB route on the STP. Full
procedure for two nodes, LAN or Internet: [WAN](WAN.md).

The table (`--wan-conf`, default `/etc/osmo-wan.conf`) is applied, the SS7
addressing towards the inter-STP set up, the SIP + SMS mesh generated. Dialing
`<prefix><number>` reaches that number on the matching node. The profile stays
`faketrx-qemu`.

`--air-mesh[=PORT]` additionally meshes the **bursts**: the radio medium
becomes shared, a mobile can hear and pick another node's BTS (peers from the
WAN table, range in `data/air-mesh.txt`, two extra mobiles, `pont/airmesh.py`).

`--virtualbox[=N]` sets up the segment and N−1 VMs before the WAN; refuses to
run **inside** a VM (`--vbox-node N` = this machine's number).

### 7-tcpdump

A tcpdump wrapper is installed for GSMTAP (`udp/4729`) and M3UA captures.

### 7-stop

**The stack is always stopped before starting** (`run.sh --stop`). There is no
hot restart: `--force` only restarts modules that are already running instead
of skipping them.

## 8. Launch

1. The node's private addresses are printed.
2. **Dashboard** on `:8080` (Firefox opens it from `launch.sh`); the I/Q
   spectra on `:8081` (`fft-web/fft_web.py`).
3. **oFono mobile hookup**: the physical phone (postmarketOS, PPP) or the
   Android QEMU sees the bench as a modem.
4. **Audio (slimmed-down PulseAudio)**: runs `scripts/audio-chain.sh 5` (log
   `/tmp/osmo-audio-chain.log`): stops speech-dispatcher, switches `osmo_rec`
   to 8 kHz mono, loads `module-stream-restore` without `restore_device`.
   `AUDIO_ALLEGER=0`: don't slim down (the chain is set up anyway).
   `AUDIO_AEC_METHOD`: `webrtc` by default (`speex` possible).
   `AUDIO_PENDANT_APPEL=1`: the heavy chain is only set up between gapk-auto's
   « Endpoint actif » and « Endpoint disparu » (default 0).
   `audio-chain.sh --reinit`: start again from a clean chain without
   restarting PulseAudio.
5. **Hand-off to `run.sh`**: `exec`, with the profile and the whole
   environment. Any `CALYPSO_*` variable passed as a prefix reaches `run.sh`,
   its `run_modules/` and QEMU **untouched** (`CALYPSO_LANG=en`,
   `CALYPSO_NO_ATTACH=1`, `CALYPSO_BRIDGE=none`…).

`run.sh` opens the `calypso` tmux: `osmo-bts-trx` → QEMU (PTY + monitor) →
wait for `/tmp/osmocom_l2` → bridge → wait for UDP 6700 ticks → `mobile`, then
the core, Asterisk, SMSC. Unless `--no-attach` / `CALYPSO_NO_ATTACH=1` (which
`osmo-banc.service` sets), the script attaches to the tmux.

### 8-dsp. The DSP bench

With `--dsp` (the default), `RUN_SH` stays the fork's one and receives
`--skip qemu,pty,osmocon,l2 --no-attach`. Then `exec c54x_exe/run.sh`
(`BANC_DSP`, if executable) takes over with `MODE=dsp PONT=1`, `IQ=none`,
`INSNS=120000`, `LOCKSTEP=1`, `CALYPSO_BSP_STREAM=1`, set with `:=` so they can
be overridden. The five steps:

1. `c54x_exe --arm`: the DSP, socket `/tmp/calypso_dsp.sock`, shared API RAM,
   DL bursts on `udp/6702`;
2. `qemu-system-arm` from `/opt/GSM/qosmo` (`CALYPSO_DSP_EXTERN=1`): the ARM alone;
3. `osmocon`;
4. `mobile` (`mobile_pont.cfg`, VTY **4347**);
5. `pont/pont_dsp.py`.

`CALYPSO_BRIDGE` is `none`: it is not `start-native.sh` that starts the
bridge. `--stop`, `--regen` and the stop before starting also stop the DSP
bench, even without `--dsp`; `--status` and `--check-paths` show it (with
`--dsp`). The summary and oFono target VTY 4347 (`OSMO_MOB_VTY_PORT`).
`BANC_DSP=none`: the stack alone.

`--bts` (alias `--osmo-trx`) implies `--dsp` and runs `c54x_exe/run.sh` with
`OSMO_TRX=1`: the Calypso becomes BTS#0's transceiver; `--ms` adds the second
emulated phone and the air relay, `--ts 1|2` the timeslots served. See
[Reference](Reference.md) § 3.4-3.6.

Logs: the real files are at the dashboard paths
(`/run/user/0/osmo-nitb/logs/{qemu,osmocon,mobile}.log`, `/dev/shm/pont.log`),
with links in `/tmp/c54x-pont`. `--assembly-logs` (`ASSEMBLY_LOGS=1`,
`ASSEMBLY_LOGS_FLAGS`, `ASSEMBLY_LOGS_FILTRE`) writes
`/tmp/c54x-pont/qemu-asm.log`, but the bench then loses real time.

---

## Short manual

```
./start-native.sh [options] [mode]

Modes: faketrx-qemu (default) | faketrx | qemu | noproc | core | hybrid

Stack selection
  --dsp                (default) C54x DSP bench: the C54x runs outside QEMU (/opt/GSM/c54x_exe,
                       TI mask ROM) and decodes FCCH/SCH/BCCH itself; same profile and same
                       stack as grgsm, only qemu,pty,osmocon,l2 move to c54x_exe/run.sh
                       (BANC_DSP=none: the stack alone)
  --grgsm              gr-gsm layer 1 inside qosmo
  --bts | --osmo-trx   the Calypso as BTS#0's transceiver (implies --dsp)
  --ms                 with --bts: a second emulated phone as the mobile, over the air relay
  --ts N               with --bts: timeslots served (1 = TS0 only, 2 = TS0+TS1)
  --assembly-logs      ARM asm trace (/tmp/c54x-pont/qemu-asm.log); no more real time
  --sap, --softsim     SIM served over SAP (softSIM): the card in the PC/SC reader
                       (HID Omnikey) if one is inserted, otherwise the software SIM;
                       --sap=pcsc / --sap=sim force it, --no-sap (default): test SIM.
                       See [SIM](SIM.md).
  --launcher <bin>     QEMU C launcher (default /usr/local/bin/<fork>)
  --profile <name>     forces the profile
  --mobile | --ccch_scan | --bcch_scan | --cell_log   layer 2 client (mutually exclusive)

Lifecycle
  --list  --dry-run  --stop  --status  --force  --verbose  --no-attach  --check-paths
  --regen              regenerates the configs from the templates (kept otherwise)
  --menu               asks the questions instead of guessing
  --docker             hand over to launch/start-docker.sh with the remaining arguments

Topology
  --node N  --op N  --hub-ip IP  --interstp | --no-interstp
  --wan | --wan CARD… | --wan-nodes "…" | --wan-id N | --wan-conf FILE | --gen-conf [F] | --regen-conf
  --air-mesh[=PORT]  --virtualbox[=N]  --vbox-node N
```

Getting back in:

```bash
tmux attach -t calypso         # Ctrl-b d detaches, the bench keeps running
journalctl -u osmo-banc -f     # if started as a service
./start-native.sh --status
./start-native.sh --stop
```

Logs: `$LOG_DIR` (`/run/osmo-direct/logs`, tmpfs): `qemu.log`, `bridge.log`,
`run.sh.log`; with `--dsp`, `/tmp/c54x-pont/`.
