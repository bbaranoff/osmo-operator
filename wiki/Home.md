# osmo-operator — Quick start & reference

A complete **GSM + LTE** operator in a single image, with the radio emulated end
to end down to the baseband (Calypso under QEMU), and a postmarketOS phone that
does data over 4G and voice/SMS over 2G on the same identity — a real handset's
CSFB, at the modem level. No SDR, no physical phone.

| Page | Contents |
|---|---|
| **Home** (here) | recommended quick start (the ISO), launching, reference |
| [Start-direct](Start-direct.md) | `start-direct.sh` step by step, options manual |
| [Resultats](Resultats.md) | reference `check_all.sh` runs, 1 and 3 operators, and how to read the deviations |
| [Build](Build.md) | `build.sh`, `build-iso.sh`, `.deb`, `install.sh` |
| [Environnement](Environnement.md) | which variable wins, what makes it all the way to QEMU |
| [Reference](Reference.md) | the old full README (in English): multi-PLMN architecture, SS7, SMS, voice, diagnostics |
| [Telephone-emule](Telephone-emule.md) | plug **only** the emulated phone (qosmo, c54x_exe, grgsm_exe) into **your own** Osmocom stack |
| [Lancer-a-la-main](Lancer-a-la-main.md) | the phone launched process by process, no script, with proof at every step |
| [SIM](SIM.md) | the bench's card in an Omnikey HID reader (sysmoISIM programmed by pySim) or softSIM, served to the mobile over SAP: `start-direct.sh --sap`, `tools/osmo-sim.sh` |
| [WAN](WAN.md) | linking two nodes (LAN or Internet via WireGuard): ports, SS7 hub, `--wan-nodes`, layer-by-layer checks, failures |
| [Payload-ISM](Payload-ISM.md) | SMS **text** between two nodes over an ISM-band radio link, everything else (SS7, SIP, addresses) over IP: `start-direct.sh --wan --payload-ism`, `network/setup-payload-ism.sh` |
| [Injecteur-bruit](Injecteur-bruit.md) | degrade the downlink between the bridge and layer 1 (bit flips, bursts, AWGN, I/Q): `BRUIT_MODE=…`, off by default |
| [installer-osmo-jusquau-dsp.ipynb](installer-osmo-jusquau-dsp.ipynb) | notebook: the Dockerfile replayed step by step natively, from apt to a call on the DSP |

---

## Recommended method: the desktop ISO (release)

> Everything the ISO contains, how it is built and installed, and each of its
> capabilities: see [ISO](ISO.md).

This is the path that works without compiling or configuring anything: the
[latest release](https://github.com/bbaranoff/osmo-operator/releases/latest)
ships `osmo-operator-desktop.iso`, a GNOME live system with Wireshark, Linphone,
the I/Q spectra and the three launchers in the dock.

### 1. Download and reassemble

GitHub caps a release file at 2 GiB, so the image ships in pieces.
**Download all four `part-*`**, then:

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
```

### 2. Requirements

x86_64, **8 GB of RAM and 4 cores minimum**. The live root is a tmpfs
(~6 GB with `toram`): logs and captures there are capped and purged at every
boot. The bench runs **two QEMUs** (the Calypso and the pmOS VM): inside a
virtual machine, enable **nested virtualization**, otherwise the pmOS VM falls
back to software emulation and becomes very slow. On real hardware KVM is
available directly: that is the most comfortable setup.

### 3. Launch

**QEMU**

```bash
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm \
  -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

**VirtualBox** — new Linux / Ubuntu 64-bit VM, 8 GB, 4 CPUs, 3D disabled.
System → Processor: tick *Enable Nested VT-x/AMD-V* (if greyed out:
`VBoxManage modifyvm "<nom>" --nested-hw-virt on`). Attach the ISO to the optical
drive, no disk. NAT network: port forward host 8080 → guest 8080.

**VMware** (Workstation / Player / Fusion) — VM from the ISO, Linux / Ubuntu
64-bit, 8 GB, 4 cores, tick *Virtualize Intel VT-x/EPT or AMD-V/RVI*, skip
easy install.

**USB stick** — the ISO is hybrid:

```bash
sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

On Windows, Rufus in *DD Image* mode. UEFI or BIOS boot, either works.

### 4. Start the bench

Nothing starts at boot: the machine lands on its desktop. Three launchers in
the dock, 2G and 4G independent and in any order, **the smartphone last**:

| Launcher | Starts |
|---|---|
| **2G** — the red handset | osmo-stp / bsc / msc / hlr / sgsn / ggsn / pcu, the Calypso under QEMU, both BTSs, both osmocom-bb mobiles, Asterisk, the SMSC |
| **4G** — the signal bars | open5gs, srsENB + srsUE over ZMQ, the SGs interface to the MSC (CSFB) |
| **Smartphone** — phone icon | the postmarketOS VM: oFono on the virtual modem, data over 4G, voice and SMS over 2G |

Passwords: live **`osmo`**, pmOS phone **`147147`**.

Check that everything is up: `checks/diag-stp-operator.sh`, or the full check
`bash ./checks/check_all.sh` (reference result for a standalone native node
in [Resultats](Resultats.md): everything
passes, only the SS7 interconnect is *down* for lack of an inter-STP — that is expected).

### 5. Make a call

The two provisioned subscribers are **100101** and **100102**, one per cell;
`100`/`200` are the Linphones, `600` the echo test. An incoming call to the
smartphone is paged by the MME, the UE falls back to the BTS (CSFB), voice goes
over 2G; the speedtest, on the other hand, goes over 4G. Everything is visible in
Wireshark (GSMTAP, cleartext NAS, SGs, M3UA).

---

## Other paths

| Path | When | See |
|---|---|---|
| **Docker** — `docker pull bastienbaranoff/norf_gsm`, `sudo ./start.sh` | N operators interconnected through an inter-STP, on an existing host | [README-docker](../doc/README-docker.md) |
| **Native** — `sudo ./install.sh` then `./start-direct.sh` | a dedicated Ubuntu 24.04 machine, no container | [Build § install.sh](Build.md#4-installsh--native-ubuntu-2404-noble) |
| **Build the ISO yourself** — `sudo ./build-iso.sh` | modify the image, pre-wired WAN, arm64 for the hub | [Build § build-iso.sh](Build.md#2-build-isosh--bootable-iso--sd-image) |
| **Install to disk** — Calamares from the live system | keep the bench, LUKS, NVIDIA drivers | [Build](Build.md) |

---

## Reference

### What is in the image (v0.1-3)

`/etc/os-release`: `IMAGE_VERSION="OSMO_EGPRS_V2"` — `/etc/osmo-role`:
`OSMO_ROLE=operator`, `OSMO_LITE=0`.

**2G / GSM — Osmocom**

- Core: osmo-stp (M3UA, SCTP :2905), osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn (GTPv1-C/U), osmo-pcu, osmo-mgw (MGCP :2427).
- Two DCS1800 cells, LAC 1: BTS 0 (Cell ID 6001, BSIC 7) and BTS 1 (Cell ID 6012, BSIC 8), each on its own osmo-bts-trx.
- Layer 1: `qemu-system-arm -M calypso -cpu arm946` runs `layer1.highram.elf`, loaded by osmocon as on a C123; `pont.py` converts bursts to I/Q for `fake_trx.py`, then trxcon and two `mobile` (osmocom-bb).
- GPRS/EDGE: BSSGP/NS to the PCU, PDP contexts through osmo-ggsn.
- Voice: external MNCC → Asterisk (SIP :5060, FR/HR) via osmo-sip-connector.
- SMS: SMS-over-GSUP → proto-smsc-daemon, SMPP :2775 with a test ESME, inter-operator relay :7890.
- A3A8 authentication with deterministic RAND (`*-force-rand-toy` patches): reproducible from one boot to the next.
- Live GSMTAP in Wireshark.

**4G / LTE — open5gs + srsRAN**

- open5gs core (MME, SGW-C/U, SMF, UPF, PCRF, HSS…) on dedicated loopbacks; Prometheus :9090, WebUI :9999, MongoDB behind the HSS.
- PLMN 001/01, TAC 7. NAS security with null ciphering (EIA2/EIA1 + EEA0), on purpose: the NAS reads in cleartext.
- srsENB 10 MHz, EARFCN 3350, band 7; srsUE connected over ZMQ. Milenage subscriber IMSI 001010001000001. The UE has an IP in a netns and goes out through NAT.

**CSFB**

- SGs interface osmo-msc ↔ MME (:29118), TAI table (001-01, TAC 7) → LAI (001-01, LAC 1): the VLR files the subscriber under LAC 1 while it is on LTE.
- Combined EPS+IMSI attach; incoming call paged by the MME, the UE falls back to the BTS.

**postmarketOS**

- x86_64 VM, patched kernel (`CONFIG_PPP`, missing from upstream `linux-postmarketos-stable`) shipped prebuilt (Git LFS) in `/opt/user_interface/kernel/pmos/`.
- 4G data: NetworkManager → pppd (`ATD*99***1#`) → virtio-console `osmo.data` → `osmo-phonesim-banc.py` → UE netns → srsUE → srsENB → UPF → Internet.
- 2G voice/SMS: second virtio-console `osmo.modem`, `osmo-phonesim-banc.py` plays the 27.007 AT modem (state read from the bsc, msc and mobile VTYs), oFono drives it.
- Audio: two full-duplex PulseAudio chains (intel-hda) — a GAPK bridge to the osmocom-bb mobile, and a chain with echo cancellation. Slimmed down at every start (speech-dispatcher stopped, `osmo_rec` at 8 kHz mono, stream-restore without device restore). webrtc canceller by default, its `aec_args` passed as a single argument — without that the AGC muted the mic; `AUDIO_AEC_METHOD=speex` is still available.

### Ports and access

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 4239 | osmo-stp VTY | | 8080 | bench dashboard |
| 4242 | osmo-bsc VTY | | 8081 | I/Q spectra (fft-web) |
| 4243 | osmo-mgw VTY | | 9090 | open5gs Prometheus |
| 4254 | osmo-msc VTY | | 9999 | open5gs WebUI |
| 4258 | osmo-hlr VTY | | 5060 | Asterisk SIP |
| 4729 | GSMTAP (Wireshark) | | 2775 | SMPP |
| 2905 | local M3UA | | 7890 | inter-op SMS relay |
| 2908 | inter-STP M3UA | | 29118 | SGs (MSC ↔ MME) |

```bash
tmux attach -t calypso          # the 2G stack; Ctrl-b d detaches
journalctl -u osmo-banc -f      # if started as a service
./start-direct.sh --status | --stop
./ss7-console.py                # browsable SS7 diagram, built-in VTYs
```

### Numbering plan

| Number | Use |
|---|---|
| `100101`, `100102` | the bench's two subscribers (one per cell) |
| `N0001`…`N9999` | subscribers of operator N (multi-op) |
| `100` / `200` | Linphone A / B |
| `600` | echo test |
| `9XXXXX` | inter-op breakout from a softphone |

### Most useful options

| Command | Effect |
|---|---|
| `./start-direct.sh --list` | the plan, without launching |
| `./start-direct.sh --menu` | asks the questions instead of guessing |
| `./start-direct.sh --regen` | regenerates the configs from the templates |
| `./start-direct.sh` | C54x DSP bench (c54x_exe, TI mask ROM), **the default** since 2026-10-01: the mobile camps and does its LU |
| `./start-direct.sh --grgsm` | gr-gsm layer 1 inside QEMU (the old default): the stack goes all the way to a voice call |
| `./start-direct.sh --node 2 --hub-ip IP` | this node = node 2 of a WAN, ASP towards the inter-STP |
| `./start-direct.sh --wan` | N-node WAN, interactive questions |
| `./generate_configs.sh ARFCN=520` | changes a value in `globals.conf` |
| `sudo ./build-iso.sh --desktop` | rebuild the desktop ISO |
| `bash ./checks/check_all.sh` | full check, log in `/tmp` |

### Files worth knowing

| File | Role |
|---|---|
| `globals.conf` | the network configuration; a non-empty variable set on the command line overrides it (since 2026-09-22) |
| `environment/load.env` | the loading order of profiles and defaults |
| `/etc/osmocom/coeur.env` | `N_MS`, written by the ISO |
| `/etc/osmo-wan.conf`, `/etc/osmo-role` | WAN table, node role |
| `/etc/default/osmo-banc` | `OSMO_BANC_ARGS="--grgsm"` to make the service start in gr-gsm (DSP otherwise) |
| `/var/log/osmocom/{qemu,bridge,run.sh}.log` | QEMU, bridge, orchestration |
| `/tmp/c54x-pont/`, `/dev/shm/pont.log` | DSP bench: links to its logs (real files at the dashboard paths), bridge log |
| `pont/README.md` | read it **before** hunting for a radio fault in a CRC counter |
