# osmo-operator

[![Build ISO](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml)

A complete **GSM + LTE operator on one machine**: an Osmocom core network (BTS, BSC, MSC, HLR, MGW, SMSC,
Asterisk) and **emulated Calypso phones**. The ARM runs under QEMU ([qosmo](https://github.com/bbaranoff/qosmo)) and the
TI C54x DSP runs outside it, executing the real mask ROM ([c54x_exe](https://github.com/bbaranoff/c54x_exe)). The phone
is either the OsmocomBB `layer1` + `mobile`, or a Motorola C139 running the **original TI firmware** (FreeCalypso
Magnetite). It camps, authenticates, ciphers, sends SMS and holds voice calls. No SDR and no physical phone: the
radio is emulated end to end, down to the baseband.

![The bench in action: CSFB call, I/Q spectra, srsUE, Wireshark, Linphone](test.png)

## Start here

| I want to… | Read |
|---|---|
| Boot a ready-made live image (fastest, nothing to build) | [iso](doc/README-iso.md) · [latest release](https://github.com/bbaranoff/osmo-operator/releases/latest) |
| Pick a mode and run it | [Modes](#modes) below · the **?** of the dock (`osmo-info`) · [lancer-les-modes.ipynb](wiki/lancer-les-modes.ipynb) |
| Install on Ubuntu 24.04 without Docker | [native](doc/README-native.md) · [installer-osmo-jusquau-dsp.ipynb](wiki/installer-osmo-jusquau-dsp.ipynb) |
| Run in Docker, or build the images | [docker](doc/README-docker.md) |
| Run on a Raspberry Pi 4 / arm64 | [arm](doc/README-arm.md) |
| Study the real C54x DSP on the mask ROM | [dsp](doc/README-dsp.md) |
| Run the original TI firmware (C139, Magnetite) | [magnetite](doc/magnetite.md) |
| Use the gr-gsm layer 1 | [grgsm](doc/README-grgsm.md) |
| Add 4G, CSFB and the postmarketOS phone | [lte](doc/README-lte.md) |
| Several operators, SS7 interconnect, a WAN between machines | [ss7](doc/README-ss7.md) · [WAN](wiki/WAN.md) |
| Drive the bench day to day: tmux, VTY, ports, Wireshark | [usage](doc/README-usage.md) |
| Check that the bench is healthy, reproduce a fault | [tests](doc/README-tests.md) |
| See how the pieces fit | [architecture](doc/README-architecture.md) · [all documents](doc/README-docs.md) |

## Modes

Everything goes through `./start.sh` (`start-native.sh` is the same script, kept as a link). `--regen` rebuilds
`/etc/osmocom` from the templates, `--no-attach` stays out of tmux, `./start.sh --help` lists every option.

| Command | What runs | State |
|---|---|---|
| `./start.sh --bts-classique --ms` | **Default** (red phone icon). `osmo-bts-trx` ↔ `pont/pont_dsp.py`; the phone runs osmocom-bb `layer1` + `mobile` on the DSP ROM | LU, SMS, calls |
| `./start.sh --bts-classique --ms-magnetite` | Same network, the phone is a C139 running the TI firmware; `--gapk` for voice on the host | LU, SMS; calls in A5/0 (`ENCRYPTION="a5 0" ./start.sh --regen …`) |
| `./start.sh --bts --ms --ts 2` | The Calypso of QEMU **is the BTS radio** (`trx` firmware + `transceiver`); a second Calypso camps on it over the air; one Calypso per timeslot | camps, LU; no call yet |
| `./start.sh --bts --ms --ts 2/1` | TS0 + TS1 on one Calypso TRX (default of `--bts`) | calls |
| `./start.sh --grgsm` | gr-gsm layer 1 instead of the DSP | end to end |
| `banc-rssi` | The osmocom-bb `rssi` app on a 4th Calypso, fed by the pont; screen `c123 --instance 4` | DL levels, sync, BCCH |
| `./start.sh --stop` | Stop the whole stack | |

Phone screens and keypads: `c123 --instance N` (1 = phone of `--bts-classique` or TRX of `--bts`, 2 = phone over
the air, 3 = second TRX, 4 = rssi). Nothing telecom starts at boot
([`services/80-osmo-operator.preset`](services/80-osmo-operator.preset)): starting a network is your gesture.

Quickest path from the ISO (password `osmo`):

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c --ignore-missing SHA256SUMS
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm -cpu host -smp 4
```

From a clone (native, or inside the container):

```bash
./start.sh --regen --bts-classique --ms   # first run: generate the configs, start, attach to tmux
./start.sh --stop
```

## Notebooks

| Notebook | What it does |
|---|---|
| [installer-osmo-jusquau-dsp.ipynb](wiki/installer-osmo-jusquau-dsp.ipynb) ([nbviewer](https://nbviewer.org/github/bbaranoff/osmo-operator/blob/main/wiki/installer-osmo-jusquau-dsp.ipynb)) | Fresh Ubuntu 24.04 to a call on the DSP, one cell per step with checks; optional Magnetite build |
| [lancer-les-modes.ipynb](wiki/lancer-les-modes.ipynb) ([nbviewer](https://nbviewer.org/github/bbaranoff/osmo-operator/blob/main/wiki/lancer-les-modes.ipynb)) | Each mode above: start, check, stop; the phone screens inline, keys, `banc-rssi` |
| [lancer-pas-a-pas.ipynb](wiki/lancer-pas-a-pas.ipynb) ([nbviewer](https://nbviewer.org/github/bbaranoff/osmo-operator/blob/main/wiki/lancer-pas-a-pas.ipynb)) | The bench process by process: HLR, MGW, MSC, BSC, BTS, QEMU, osmocon, mobile, pont |

How to run them (disposable container, VM, unattended `nbconvert`): [README-notebook](wiki/README-notebook.md).

## Supplements

What is not in the ISO installs with `sudo ./addition.sh` (a checklist window, or flags):

| Flag | Installs |
|---|---|
| `--multi` | Docker, the operator image, the SS7 multi-operator topology |
| `--opencl` · `--claude` · `--extras` · `--sim` | GPU OpenCL and A5 tools · Claude Code · games and media · PC/SC SIM tools |
| `--gnuarm` | the historic OsmocomBB toolchain, arm-elf-gcc 4.5.2 (`/root/gnuarm`) |
| `--magnetite` | Wine + TI TMS470, FreeCalypso Magnetite for the C139, the bench patches, the flash image |
| `--trx` | [osmocom-bb-trx](https://github.com/bbaranoff/osmocom-bb-trx): the Docker image and the `trx` firmware (TX) built with gnuarm |
| `--calypso-fw` | the bench's Calypso firmware (`layer1`, `rssi`) rebuilt with gnuarm (prebuilt in [firmware](https://github.com/bbaranoff/firmware)) |
| `--fernvale` | MediaTek MT6260: [fernly](https://github.com/bbaranoff/fernly), [fernvale-nuttx](https://github.com/bbaranoff/fernvale-nuttx), [osmocom-bb-mtk-layer1](https://github.com/bbaranoff/osmocom-bb-mtk-layer1) |
| `--simcom` | the [SIMCom](https://github.com/bbaranoff/simcom) documentation and SDKs |
| `--firmwares` | all the firmware supplements above |

## Wiki

| Page | Contents |
|---|---|
| [Home](wiki/Home.md) | quick start, launching, reference card |
| [Start-native](wiki/Start-native.md) | the launcher step by step, option manual |
| [Reference](wiki/Reference.md) | architecture, layer-1 chains, build graph, multi-PLMN SS7, diagnostics |
| [Build](wiki/Build.md) · [ISO](wiki/ISO.md) | `build.sh`, `build-iso.sh`, `.deb`, `install.sh`; what the ISO contains |
| [Environnement](wiki/Environnement.md) | which variables win, what reaches QEMU |
| [Resultats](wiki/Resultats.md) | reference `check_all.sh` runs and how to read the deviations |
| [Telephone-emule](wiki/Telephone-emule.md) | plug **only** the emulated phone into your own Osmocom stack |
| [Lancer-a-la-main](wiki/Lancer-a-la-main.md) | the phone started by hand, with proof at each step |
| [Installer-qosmo](wiki/Installer-qosmo.md) · [Installer-c54x_exe](wiki/Installer-c54x_exe.md) · [Installer-grgsm_exe](wiki/Installer-grgsm_exe.md) | building the QEMU fork and the two external layer 1s |
| [SIM](wiki/SIM.md) | a sysmoISIM in an Omnikey reader, or a softSIM, over SAP |
| [WAN](wiki/WAN.md) · [Payload-ISM](wiki/Payload-ISM.md) | linking nodes; SMS text over an ISM radio link |

## Other documents

| Document | Subject |
|---|---|
| [`pont/README.md`](pont/README.md) | A5 ciphering, Kc and SACCH: a measurement report |
| [`doc/magnetite.md`](doc/magnetite.md) | the TI firmware in qosmo: build, flash image, debugging |
| [`environment/README.md`](environment/README.md) | environment variables and path resolution |
| [`services/README.md`](services/README.md) | the systemd units shipped, and the boot policy |
| [`navigation/QUICKSTART.md`](navigation/QUICKSTART.md) | the SS7 console |
| [Components and their READMEs](doc/README-docs.md#components-and-their-readmes) | every Osmocom module and third-party component, with the local patches |

## Repositories and sites

| | |
|---|---|
| [qosmo](https://github.com/bbaranoff/qosmo) · [c54x_exe](https://github.com/bbaranoff/c54x_exe) · [grgsm_exe](https://github.com/bbaranoff/grgsm_exe) | the QEMU fork and the two external layer 1s |
| [firmware](https://github.com/bbaranoff/firmware) · [osmocom-bb-trx](https://github.com/bbaranoff/osmocom-bb-trx) | prebuilt Calypso firmware; osmocom-bb jolly/testing with TX |
| [osmo-egprs-web](https://github.com/bbaranoff/osmo-egprs-web) | the dashboard (http://127.0.0.1:8080) |
| [bbaranoff.github.io](https://bbaranoff.github.io) · [pl4y.store](https://pl4y.store) · [github.com/bbaranoff](https://github.com/bbaranoff) | the author's resources and projects |
| Upstream | [Osmocom](https://gitea.osmocom.org/) · [FreeCalypso](https://www.freecalypso.org/) · [Open5GS](https://open5gs.org/) · [srsRAN](https://www.srsran.com/) |

---

*osmo-operator is a teaching and research GSM bench: a full core network and emulated Calypso phones on one
machine, down to the DSP mask ROM, with multi-operator SS7 interconnect when you want it.*
