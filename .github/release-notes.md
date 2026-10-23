[![Build ISO](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml/badge.svg)](https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml)

## osmo-operator-desktop.iso · v0.1-9

Live ISO password: **`osmo`** · postmarketOS phone password: **`147147`**

A complete GSM + LTE operator on one live image, with a GNOME desktop. No SDR and no physical phone: the radio is
emulated end to end, down to the baseband. The Calypso's ARM runs under QEMU
([qosmo](https://github.com/bbaranoff/qosmo)), its TI C54x DSP runs the real mask ROM
([c54x_exe](https://github.com/bbaranoff/c54x_exe)).

### Download

**Download every `.part-NN` file**, not just the first one (GitHub caps release files at 2 GiB). Then:

```sh
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c --ignore-missing SHA256SUMS
```

![LAB GSM: the osmo-operator desktop wallpaper](https://raw.githubusercontent.com/bbaranoff/osmo-operator/main/configs/gsm-lab-wallpaper.png)

### New in 0.1-9

**Phones and radio**
- **Classic BTS is the default**: `./start.sh --bts-classique --ms`. `osmo-bts-trx` talks to `pont/pont_dsp.py`; the
  emulated phone runs osmocom-bb `layer1` + `mobile` on the DSP mask ROM. The red phone icon starts exactly this.
- **The original TI firmware**: `--ms-magnetite` boots a Motorola C139 running FreeCalypso Magnetite (TI L2/L3 and
  UI, colour screen and keypad in `c123`). It camps, registers, sends and receives SMS; calls work in A5/0, voice on
  the host with `--gapk`. Build: `sudo ./addition.sh --magnetite` ([doc/magnetite.md](https://github.com/bbaranoff/osmo-operator/blob/main/doc/magnetite.md)).
- **The Calypso as the BTS radio**: `--bts` runs the `trx` firmware in QEMU; `--ms` adds a second Calypso that
  camps on it over the air; `--ts 1 | 2 | 2/1` chooses the timeslots.
- **`banc-rssi`**: the osmocom-bb `rssi` app on a fourth Calypso, fed by the pont in classic BTS mode, with a
  realistic air: the cell only on its ARFCN, -60 dBm downlink, noise elsewhere, AGC, BCCH decoded.
- **Voice**: `--vocoder-rom` (the FR codec of the DSP ROM, default) or `--gapk` (host vocoder, keeps real time).
- C123 and C139 screens and keypads in QEMU: `c123 --instance N`.

**Robustness**
- BTS#0 runs under a watchdog: an `osmo-bts-trx` exit on "PC clock skew too high" restarts it after 3 s.
- The pont caps the pause it asks of the BTS (`PONT_CLCK_PAUSE_PLAFOND`), the root cause of those exits.
- **Nothing telecom starts at boot** (systemd preset `80-osmo-operator.preset`): the bench, the Osmocom core, the
  BTS, Asterisk, oFono, Open5GS and srsRAN wait for you. Web consoles, sound and network addressing still start.

**Desktop and docs**
- The **?** at the top of the dock opens the help page (modes, modules, notebooks, repositories, references),
  served by the dashboard so that the snap Firefox can open it.
- A new Plymouth boot screen: flat 2D, an antenna and its circles.
- Settings page for the whole stack: http://127.0.0.1:8090 (`globals.conf`, Osmocom configs, Calypso instances).
- Notebooks: [install](https://github.com/bbaranoff/osmo-operator/blob/main/wiki/installer-osmo-jusquau-dsp.ipynb),
  [run each mode](https://github.com/bbaranoff/osmo-operator/blob/main/wiki/lancer-les-modes.ipynb),
  [process by process](https://github.com/bbaranoff/osmo-operator/blob/main/wiki/lancer-pas-a-pas.ipynb).
- The launcher is now `start.sh` (`start-native.sh` stays as a link).

**Supplements** (`sudo ./addition.sh`, not in the ISO)
- `--gnuarm` (arm-elf-gcc 4.5.2), `--magnetite` (Wine + TI TMS470), `--trx`
  ([osmocom-bb-trx](https://github.com/bbaranoff/osmocom-bb-trx) image + TX firmware), `--calypso-fw` (the bench
  firmware rebuilt with gnuarm), `--fernvale` (MediaTek MT6260: fernly, NuttX, MTK layer 1), `--simcom`
  (SIMCom docs and SDKs), `--firmwares` (all of them).

**Known limits**
- Magnetite: calls need A5/0 (with A5/1 the FACCH is decoded too early).
- `--bts --ts 2`: camps and registers, no call yet (the second TRX is not frame-aligned); `--ts 2/1` calls.
- `banc-rssi`: the uplink per-timeslot view does not show the phone yet.
- The ROM vocoder costs real time on slow hosts: use `--gapk`. Do not compile while a bench runs.

### What's inside

- **2G (Osmocom)**: osmo-stp, osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn, osmo-pcu, osmo-mgw; two cells in
  LAC 1 (cell 6001 BSIC 7, cell 6012 BSIC 8); GPRS/EDGE; voice through osmo-sip-connector and Asterisk; SMS over
  GSUP and SMPP; deterministic RAND for reproducible runs; live GSMTAP for Wireshark.
- **The DSP**: a TMS320C54x emulated outside QEMU on the dumped mask ROM, sharing the API RAM with the ARM and
  stepping one TDMA frame at a time.
- **4G (Open5GS + srsRAN)** over ZMQ, PLMN 001/01, null NAS ciphering for analysis; **CSFB** through SGs between
  the MME and osmo-msc.
- **postmarketOS phone**: data on 4G, voice and SMS on 2G under one identity, oFono on a virtual AT modem.

### Running the image

x86_64, **8 GB of RAM and 4 cores** minimum; in a VM, enable nested virtualization.

```sh
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm \
  -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

VirtualBox or VMware: Linux / Ubuntu 64-bit, 8 GB, 4 CPUs, nested VT-x/AMD-V ticked, the ISO in the optical drive.
USB stick: `sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync` (Rufus: DD mode).

### Getting started

| Dock | Starts |
|---|---|
| **?** | this help: every mode, module, notebook and repository |
| red phone | the 2G bench, `./start.sh --bts-classique --ms` |
| signal bars | 4G: Open5GS, srsENB, srsUE and SGs |
| phone | the postmarketOS VM (start it last) |

Other modes from a terminal: `cd /opt/GSM/osmo-operator && sudo ./start.sh --help`. Health check:
`checks/diag-stp-operator.sh`. Documentation: [README](https://github.com/bbaranoff/osmo-operator#readme) ·
[wiki](https://github.com/bbaranoff/osmo-operator/blob/main/wiki/Home.md) ·
[bbaranoff.github.io](https://bbaranoff.github.io) · [pl4y.store](https://pl4y.store).
