# Bootable ISO release

https://github.com/bbaranoff/osmo-operator/releases/tag/v0.1-3


# osmo-operator — a teaching GSM/LTE bench, multi-PLMN, no hardware required

A complete mobile network on a single machine: the radio layer is visible (I/Q
spectra), the signalling is readable (SS7/M3UA, GSUP, Abis), and the services
actually work end to end (calls, SMS, 2G/4G data, CSFB). The handset is **real
OsmocomBB firmware running on a TI Calypso baseband emulated in QEMU** (ARM7 +
C54x DSP); the core is the Osmocom stack; 4G is Open5GS + srsRAN over ZeroMQ.
Everything fits in a Docker image, a bootable ISO, or a native Ubuntu 24.04
install.

From 1 to 9 operators, interconnected through a central inter-STP, with the SS7
configuration generated automatically — think of it as "DHCP for SS7".

```
UE (QEMU Calypso / fake_trx / SDR) ─ BTS ─ BSC ─ STP ─ MSC ─ HLR
                                                 │      ├─ MGW (RTP)
                                                 │      └─ Asterisk (voice, SIP, trunks)
                                            inter-STP ─ other operators
```

| I want to… | Read |
|---|---|
| get started without compiling anything (**recommended**) | [wiki/Home.md](wiki/Home.md) — the desktop ISO from the release |
| get started with Docker or natively | [Quick start](#quick-start) |
| build the image, the ISO, the `.deb` packages | [wiki/Build.md](wiki/Build.md) |
| understand what `start-direct.sh` does, step by step | [wiki/Start-direct.md](wiki/Start-direct.md) |
| know which variable wins, and why QEMU can't see mine | [wiki/Environnement.md](wiki/Environnement.md) |
| interconnect N operators (SS7, SMS, voice) | [§ Architecture](#multi-plmn-architecture) |
| check whether my bench is healthy | [§ Bench status](#bench-status--checkscheck_allsh-native) and [wiki/Resultats.md](wiki/Resultats.md) |
| diagnose a PROHIB, a CRC error, a mobile that won't camp | [§ Troubleshooting](#troubleshooting) and [`pont/README.md`](pont/README.md) |

---

## Quick start

### A. Published Docker image (the shortest path)

```bash
sudo docker pull bastienbaranoff/norf_gsm
sudo docker tag bastienbaranoff/norf_gsm osmocom-nitb
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./start.sh                  # single mode, or bridge: N operators
sudo docker exec -ti osmo-operator-1 bash
cd /opt/GSM/osmo-operator
./start-direct.sh --regen        # first run: generates the configs
./start-direct.sh --stop
./start-direct.sh
```

### B. Native install (Ubuntu 24.04, no Docker)

```bash
sudo ./install.sh                # deps, sources, build, binaries, configs, desktop
sudo ./start-direct.sh           # or the "Launch the GSM bench" icon
```

### C. Bootable ISO — the recommended way

The [release](https://github.com/bbaranoff/osmo-operator/releases/latest) ships
`osmo-operator-desktop.iso` in four pieces (GitHub's 2 GiB limit):

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

8 GB / 4 cores, with nested virtualization when running inside a VM.
VirtualBox, VMware, USB stick, dock launchers and passwords: see
[wiki/Home.md](wiki/Home.md). To build it yourself: `sudo ./build-iso.sh --desktop`.

On boot, the machine lands on its desktop; the bench is **not** started
automatically. Use the "Launch the GSM bench" icon, or `systemctl start osmo-banc`.

---

## Bench status — `checks/check_all.sh` (native)

Two reference runs on 2026-09-15; full detail and interpretation in
[wiki/Resultats.md](wiki/Resultats.md):

| Topology | global | ss7 | interco | Verdict |
|---|---|---|---|---|
| 1 native operator, no hub | 29 pass / 0 fail / 1 warn | OK | `operator` FAIL: no inter-STP, **expected** | **healthy** |
| 3 operators (Op1 native, Op2/Op3 in containers) + inter-STP | 88 pass / 0 fail / 5 warn | **31 pass / 0 warn**, full 3×3 matrix, `as-inter` ACTIVE everywhere | `interstp` FAIL "no active AS": a **false negative** from the script (it reads Op1's VTY instead of the hub's in a hybrid topology) | **healthy, interconnect UP** |

What still needs attention, in both cases: **GGSN 0 APN** (blocks 2G data only —
set `APN=internet` in `globals.conf`, then `--regen`) and, with three operators,
**SGSN 0 NS entity** on Op2/Op3 (their PCU hasn't opened an NS-VC). The
"subscribers without a record" warning is cosmetic (bench restarted without
`start.sh`).

```bash
bash ./checks/check_all.sh                       # everything
./checks/check_all.sh --only=interstp --verbose  # a single check, in detail
./checks/check_all.sh --dump                     # + vty-debug-dump and operator_summary
```

---

## `start-direct.sh` — the launcher

`start-direct.sh` doesn't start any daemon itself. It is a **preparer**: it
loads the environment, detects the binaries and the Calypso fork, picks a
profile, generates the `mobile_*.cfg` files, exports what's needed and
**executes the `run.sh`** of the chosen fork (`qosmo-grgsm` by default,
`qosmo-dsp` with `--dsp`). From there on, all the GSM logic lives in that
`run.sh` and its `run_modules/`, inside a tmux session named `calypso`.

The default profile is `faketrx-qemu` (alias `hybrid`): the core, a BTS#0 served
by the QEMU Calypso and a BTS#1 served by `fake_trx` + `trxcon` — one "real"
emulated handset and one software handset, in the same neighbouring cell.
`faketrx` alone does without QEMU, `qemu` starts only the Calypso pipeline,
`core`/`noproc` start only the core.

One rule governs the whole script: **the command line always wins**.
`VAR=x ./start-direct.sh` overrides `environment/load.env`, which overrides the
profiles, which override the per-domain defaults. There is a single, documented
exception: `globals.conf` is authoritative **for the 26 network variables it
declares** (MCC, MNC, ARFCN, ENCRYPTION…) and for those alone; everything else
(`CALYPSO_*`, `MODE`, `LOG_DIR`…) passes through untouched and reaches QEMU.
Details, gate idioms and the manifest: [wiki/Environnement.md](wiki/Environnement.md).

```bash
./start-direct.sh --list                  # the plan, without launching anything
./start-direct.sh --dry-run --verbose     # walk through it, no side effects
./start-direct.sh --menu                  # ask instead of guessing
./start-direct.sh --dsp                   # qosmo-dsp fork: the real C54x DSP decodes
./start-direct.sh --wan --node 2          # this node = node 2 of an N-node WAN
./start-direct.sh --stop | --status
CALYPSO_BRIDGE=none ./start-direct.sh     # QEMU + BTS, no bridge
CALYPSO_NO_ATTACH=1 ./start-direct.sh     # what osmo-banc.service sets
```

Step by step, with what each phase writes and where: [wiki/Start-direct.md](wiki/Start-direct.md).

### The other entry points

| Script | Role |
|---|---|
| `launch.sh` | the double-click: Wireshark (GSMTAP 4729), Linphone, Firefox on the dashboard, then `start-direct.sh` in the foreground, via pkexec |
| `start.sh` | Docker: single or N-operator bridge; creates the networks, the inter-STP and the containers |
| `start-multi.sh` | the multi-operator bench (`osmo-multi.service`, `Requires=osmo-banc`) |
| `start-interstp.sh` | the inter-STP on its own (`osmocom-stp` image, arm64 possible) |
| `compose.sh` | `build | up [--ms N] [--phy faketrx] | down | ps | logs | shell | debs` |
| `tools/osmo-lte.sh` | 4G: Open5GS + srsENB + srsUE (netns `ue1`), `osmo-lte.service`, "osmo-lte toggle" icon |

---

## Multi-PLMN architecture

Each operator N is a container running the full stack, entirely on `127.0.0.1`
(the STP starts listening before the Docker interface is attached — that is
the fix for the race condition). Only the STP↔inter-STP link crosses the Docker
network.

| Network | Range | Role |
|---|---|---|
| `gsm-inter` | `172.20.0.0/24` | M3UA backbone; inter-STP at `.10`, operator N at `.(10+N)` |
| `gsm-net-opN` | `172.20.N.0/24` | operator N's private network (GSMTAP, GPRS); container at `172.20.N.10` |

### Point codes and routing contexts (ITU 14-bit, `zone.network.node`)

| Node | PC | RCTX |
|---|---|---|
| inter-STP | `0.23.0` | — |
| MSC OpN | `N.23.1` | `N×100+10` |
| STP OpN | `N.23.2` | `N×100+20` (registration), **`N×100+50` towards the inter-STP** |
| BSC OpN | `N.23.3` | `N×100+30` |

The inter-STP has **no routing key**: one `as-opN` AS in `traffic-mode override`
per operator, and routing is done on the DPC (`route N.23.x → as-opN`). The
inter RCTX (`N×100+50`) must be identical in the operator's `osmo-stp.cfg` and
in `osmo-stp-interop.cfg` — the first thing to check on a PROHIB.

Path of a message: `MSC Op1 → STP Op1 (127.0.0.1:2905) → catch-all as-inter →
inter-STP 172.20.0.10:2908 → DPC 2.23.x → as-op2 → STP Op2 → dynamic route → MSC Op2`.

### Dynamic generation

No file contains a value hard-coded for a given number of operators. At
startup, `apply_config_templates()` resolves everything in a single `sed`:

| Placeholder | Formula | N=2 |
|---|---|---|
| `__PC_MSC__` / `__PC_STP__` / `__PC_BSC__` | `N.23.1` / `.2` / `.3` | `2.23.1`… |
| `__RCTX_MSC__` / `__RCTX_BSC__` / `__RCTX_INTER__` | `N×100+10` / `+30` / `+50` | `210` / `230` / `250` |
| `__ARFCN__` | `512+N×2` | `516` |
| `__INTER_LOCAL_IP__` / `__CONTAINER_IP__` | `172.20.0.(10+N)` / `172.20.N.10` | `172.20.0.12` / `172.20.2.10` |

then appends, according to the total N: the N−1 PJSIP trunks
`[interop_trunk_opX]`, the `[interop_out]` dialplan context, `sms-routing.conf`,
and `osmo-stp-interop.cfg` (N AS, N×3 routes). The inter-STP must be listening
on `:2908` **before** the operators come up.

### SMS

Intra-operator: `MS → MSC (sms-over-gsup) → HLR → proto-smsc-daemon → HLR → MSC → MS`.
Inter-operator: `sms-interop-relay.py` reads the SMSC's MO log, parses the
GSM 03.40 TPDU, does a longest-prefix match in `sms-routing.conf` and pushes a
`{dest, text, from}` JSON over TCP `:7890` to the target operator's relay, which
resolves MSISDN→IMSI through the HLR's VTY and injects it via `proto-smsc-sendmt`.

### Voice

Intra: `MS → BTS → BSC → MSC → MNCC → Asterisk → MNCC → MSC → … → MS`, with RTP
handled by OsmoMGW (MGCP).
Inter: a SIP trunk `172.20.0.(10+X) ↔ 172.20.0.(10+Y)` between the Asterisk
instances. The dialplan routes on the **first digit** of the number: digit N =
operator N.

| Number | Use |
|---|---|
| `N0001`…`N9999` | GSM subscribers of operator N |
| `100` / `200` | Linphone A / B (local softphones) |
| `600` | echo test |
| `9XXXXX` | inter-operator outbound from a softphone |

---

## The handset: three PHYs

| `PHY_MODE` / profile | Stack | Use |
|---|---|---|
| `faketrx` | `fake_trx → trxcon → mobile` | multi-MS, fast, no DSP |
| `virtphy` | `osmo-bts-virtual ↔ virtphy ↔ mobile` | multi-MS over UDP multicast |
| `qemu` (`calypso`) | `osmo-bts-trx ↔ bridge ↔ QEMU Calypso ↔ mobile` | emulated ARM7 + DSP baseband, 1 MS per container |

In QEMU mode, the `calypso` machine runs the real `layer1.highram.elf`
(compiled in the image with `gcc-arm-none-eabi`); the DSP loads
`calypso_dsp.txt`, the mask ROM dumped from a phone; `mobile` connects to the
L1CTL socket `/tmp/osmocom_l2` exposed by the firmware's serial PTY (sercomm
DLCI 5). QEMU is the TDMA clock master (UDP ticks on 6700); the bridge
synthesizes the `IND CLOCK` messages for the BTS and relays bursts between the
TRX (5700-5702) and the BSP (6702).

Two forks, one `run.sh` interface:

- **`qosmo-grgsm`** (default) — gr-gsm layer 1, no C54x. Goes all the way:
  camping, LU, COMP128v1, A5/1, SMS, voice call. This is the demo.
- **`qosmo-dsp`** (`--dsp`) — the emulated C54x DSP runs the TI mask ROM and
  decodes on its own. The FB is acquired, but SCH decoding doesn't succeed yet
  (`a_sch[0]=0x8100`, bad CRC): **the mobile doesn't camp**. This is the
  workbench. No bridge by default (`CALYPSO_BRIDGE=none`): its transceiver is
  `osmo-trx-ipc`.

Since 2026-09-03, QEMU is no longer invoked directly but through a C launcher
compiled in each fork (`tools/qosmo-launch`, installed as
`/usr/local/bin/qosmo-grgsm` or `qosmo-dsp`): same defaults (`-M calypso`,
`-cpu arm946`, `-gdb tcp::1234`, two `-serial pty`, unix monitor, L1CTL,
TRXDv0 `0.0.0.0:6702`, IQ tee `127.0.0.1:6703`), reads `l1s`/`last_rach` from
the ELF, provides stable links to the PTYs under `<RUN_DIR>/modem.pty`, and
`-o` to start `osmocon` itself.

---

## Access and troubleshooting

```bash
tmux attach -t calypso                               # native / ISO
sudo docker exec -ti osmo-operator-1 tmux attach     # Docker; inter-STP: -t stp
journalctl -u osmo-banc -f
./ss7-console.py                                     # browsable SS7 diagram, built-in VTYs
```

| VTY | Port | | tmux | Window |
|---|---|---|---|---|
| OsmoSTP | 4239 | | `Ctrl-b 0` | faketrx |
| OsmoBSC | 4242 | | `Ctrl-b 1` | MS1 |
| OsmoMGW | 4243 | | `Ctrl-b 2` | Asterisk |
| OsmoMSC | 4254 | | `Ctrl-b 3` | SMSC + relay |
| OsmoHLR | 4258 | | `Ctrl-b w` / `d` | list / detach |

Wireshark starts on `sctp or udp port 4729`; useful filters: `m3ua`, `sccp`,
`gsm_map`, `gsmtap`, `sctp.srcport == 2908`.

### Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| route `0.0.0/0` PROHIB | inter-STP missing, or wrong `INTER_STP_IP`/backbone | `docker ps \| grep inter-stp`; `show cs7 instance 0 asp` on 4239, on both sides |
| no dynamic routes | MSC/BSC can't reach the STP | do the ASPs really point at `127.0.0.1`? |
| ASP DOWN on the inter-STP | Docker race | `docker restart osmo-operator-N` |
| `bridge: timeout … UDP 6700` | QEMU didn't start the TPU/DSP | `grep TINT0 /var/log/osmocom/qemu.log` |
| `FBSB result=255` | the DSP doesn't see the FB | `grep "IMR change" qemu.log \| wc -l`; `qemu/SESSION_STATUS.md` |
| `PC clock skew too high` | no more `IND CLOCK` | restart the bridge |
| `/tmp/osmocom_l2` never created | the firmware doesn't boot | `head -50 qemu.log` (MVPD / PROM0) |
| "the bridge has CRC errors" | overwritten Kc, SACCH L1 header, C0 filling, `CALYPSO_CANNED` not taking effect | [`pont/README.md`](pont/README.md) **before** digging through a counter |

Ready-made scripts: `checks/check_all.sh`, `checks/ss7_check.sh`,
`checks/diag-stp-operator.sh`, `scripts/call-diag.sh`, `scripts/audio-diag.sh`.

---

## Repository layout

| Directory | Contents |
|---|---|
| `environment/` | per-domain configuration, `load.env` first — [README](environment/README.md) |
| `pont/` | the TRX-UDP transceiver bridge (Python): `pont.py`, `airmesh.py`, `cipher.py` — [README](pont/README.md) |
| `navigation/` | the SS7 console (`ss7-console.py`, TUI, VTY, MAP) — [QUICKSTART](navigation/QUICKSTART.md) |
| `scripts/` | `run.sh`, `entrypoint.sh`, SMS relay, audio/call diagnostics |
| `checks/` | SS7 / operator / inter-STP checks |
| `services/` | systemd units, **installed but not enabled** — [README](services/README.md) |
| `packaging/` | one `.deb` per component, `/var/cache/osmo-debs` cache, apt-fast |
| `iso_modules/`, `install_modules/` | the steps of `build-iso.sh` and `install.sh` |
| `fft-web/` | both I/Q spectra (MS + BTS) on one page, port 8081 |
| `configs/`, `data/`, `patches/` | Osmocom/Asterisk templates, desktop and icons, patches |
| `wiki/` | [Home](wiki/Home.md) · [Resultats](wiki/Resultats.md) · [Build](wiki/Build.md) · [Start-direct](wiki/Start-direct.md) · [Environnement](wiki/Environnement.md) |

Full documentation of the 312 Calypso variables:
`hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md` in the QEMU fork.

---

*osmo-operator — a multi-PLMN telecom teaching platform. Ubuntu 24.04, Docker or native, amd64 and arm64 (Raspberry Pi 4 for the inter-STP / lite).*
