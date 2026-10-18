# The osmo-operator ISO — full description, build, installation, capabilities

This page describes **everything the ISO is**: what it contains, how it is
built (`build-iso.sh` and its modules), how it boots, how it installs to a
disk, and everything it can do once booted.
It points to the repository files for each item; the
[Build](Build.md), [Start-native](Start-native.md) and [Environnement](Environnement.md)
pages detail the scripts themselves.

Reference state: **osmo-operator-desktop.iso v0.1-6** (tag `v0.1-6`, commit
`869f830`), plus the 2026-10-01 changes described below (DSP by default,
LUKS question on the console, GTK launchers).

---

## 1. At a glance

| Item | Value |
|---|---|
| Base | Ubuntu 24.04 (noble), kernel `linux-image-generic` 6.8.0-146 |
| Size (desktop) | ISO 6.5 GB · squashfs 6.3 GB (zstd -19, 41 % of 15.9 GB) · 314,178 files |
| Boot | hybrid ISO (dd to a USB stick, UEFI or BIOS), Secure Boot shim → grub → kernel, `toram` entry (9 GB RAM) |
| Live accounts | `root` autologin (pw `osmo`) · `osmocom` sudoer (pw `osmo`) · pmOS phone `147147` |
| Build | `sudo ./build-iso.sh --desktop`, ~2 h 15 on 16 cores; Docker image pulled from ghcr.io, no recompilation; minimal debootstrap + the build's `.deb`s (~41); ~1,650 packages in the chroot; dpkg integrity check before and after squashfs |
| 2G | Full bench (`launch.sh`, `osmo-banc`), 2 MS, A5/1, inter-operator SMS, MSC with SGs (CSFB) |
| Emulated baseband | QEMU `qosmo` (ARM7 + C54x DSP), 7 DSP ROMs, layer1 firmware for 10 boards, gdb/telnet, `c54x_exe`, `grgsm_exe` |
| 4G | portable srsENB/srsUE + srsGUI, Open5GS, freeDiameter TLS, MME SGsAP, HSS console `:9999`, subscribers in Mongo |
| Phone | postmarketOS VM 1.7 GB (PPP kernel), patched pmbootstrap, pmaports `9479a409e3` |
| Desktop | minimal GNOME, Firefox (Mozilla deb, fr, uBlock), Wireshark, Linphone (extension 100), Kodi, dino, oFono, Conky, Plymouth `osmo-bts`, web dashboard + tutorial |
| Audio | system-wide PulseAudio, PipeWire for screencast only, PCM `gsm_out`/`gsm_in` |
| Removed | avahi, Chromium, sssd masked, pipewire-pulse |
| Installation | Calamares (`osmo-install`), optional LUKS2-encrypted `/home`, `osmo-update` at boot |
| Services installed, not enabled | `osmo-banc`, `osmo-multi`, `osmo-lte` (`--banc`, `--multi`, `OSMO_ISO_LTE=1` at build time to enable them) |

---

## 2. Images produced

A single chain (`build-iso.sh` + `iso_modules/`) produces five images. With no
option, the four amd64 images are built back to back (`--all`).

| Image | File | Role | Contents |
|---|---|---|---|
| SS7 hub | `interstp.iso` | `--role=interstp`: the inter-STP alone (PC 0.0.0), no operator; rejects `--lite` and `--desktop` | `osmocom-stp` image (Dockerfile.stp), libosmocore/netif/sigtran only, `osmo-interstp.service` at boot |
| Operator | `osmo-operator.iso` | `--role=operator` (default): the full bench, no desktop | 2G stack, emulated baseband, 4G, dashboard, tools; text console |
| Lite | `osmo-operator-lite.iso` | `--lite`: the same minus the build workshops | `/opt/GSM` stripped of source trees (`iso_modules/87-lite.sh`, same rules as `Dockerfile.lite`) |
| Desktop | `osmo-operator-desktop.iso` | `--desktop`: + GNOME, Wireshark, Linphone, VLC, Calamares, Conky, Firefox (~2.5 GB more) | this is the image published in releases |
| Raspberry Pi 4 | `osmo-operator-…-rpi4.img` | `--arm`: arm64 SD image on an Armbian 24.04 base | no squashfs or GRUB, native compilation in the emulated chroot (`82-arm-natif.sh`), about ten hours the first time |

With `--node=N` (1 to 9), the name becomes `osmo-operator-N[-lite][-desktop].iso`
and the image carries the SS7 identity of node N. `--output=FILE` forces the name.

---

## 3. Getting it, booting, finding your way

### 3.1 Download

The [latest release](https://github.com/bbaranoff/osmo-operator/releases/latest)
ships the desktop ISO **in 1,900 MB parts** (GitHub caps a release file
at 2 GiB):

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
```

### 3.2 Machine requirements

x86_64, **8 GB of RAM and 4 cores minimum**. The bench runs two QEMUs (the
Calypso and the postmarketOS VM): in a virtual machine, enable nested
virtualization. On real hardware, KVM is available directly.

### 3.3 Booting

- **QEMU**: `qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080`
- **VirtualBox**: Linux/Ubuntu 64-bit VM, 8 GB, 4 CPUs, 3D disabled, *nested VT-x/AMD-V* checked, NAT with port forwarding 8080 → 8080.
- **VMware**: VM from the ISO, *Virtualize Intel VT-x/EPT* checked, skip Easy Install.
- **USB stick**: `sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync` (Rufus in *DD Image* mode on Windows). UEFI or BIOS, either works.

### 3.4 The GRUB menu (`iso_modules/90-iso.sh`)

| Entry | Kernel line | Use |
|---|---|---|
| Run from medium (default) | `boot=live quiet` | the stick stays plugged in, root on a tmpfs overlay |
| In RAM | `boot=live toram=filesystem.squashfs` | copies only the squashfs to RAM (stated: 9 GB), the stick can be removed |
| Persistence | `boot=live persistence persistence-encryption=none quiet` | `persistence` partition on the stick to keep changes |

The live stick boots **without** `splash`: Plymouth does not show there. The
`osmo-bts` theme (mast, handset and waves) appears on an installed disk, where
GRUB boots with `quiet splash`.

### 3.5 Secure Boot (`iso_modules/91-secure-boot.sh`)

The ISO is assembled by xorriso with the **Canonical-signed shim** and the
signed GRUB (`shim-signed`, `grub-efi-amd64-signed`), plus a `/.disk/info` so
the signed GRUB can find the medium. The shim → grub → Ubuntu kernel chain is
complete: the image boots with Secure Boot on. Without these packages on the
build host, the ISO comes out unsigned and the build says so.

### 3.6 The live system: space, logs, network (`83-espace-ram.sh`, `81-cloture-systeme.sh`)

- `/dev/shm` and `/tmp` are capped as a percentage of RAM; I/Q cfiles, logs
  and captures live there and are purged at every boot. A `tcpdump` wrapper
  writes a pcap ring buffer.
- No network wait at boot: the `*-wait-online` units are masked, shutdown is
  capped at 30 s. DNS through the `systemd-resolved` stub with a fallback
  `resolv.conf`. NetworkManager ignores `apn*`, `tun*`, `veth*`, `docker*`.
- `osmo-ip-plan.service` derives the node's private addresses; `osmo-qemu-link`
  links `QEMU_BIN` and rebuilds the `qosmo` launcher if needed.
- `osmo-update.service` does a fast-forward `git fetch` of the embedded
  repositories at every boot (never a reclone, never apt), log in
  `/var/log/osmo-update.log`.
- When an interactive shell opens, an "SMS delivered" animation runs once
  (`/usr/local/sbin/osmo-sms.sh`, formerly `update.sh`) and reinstalls the
  icons.

### 3.7 Accounts and sessions (`84-comptes.sh`)

| Account | Password | Role |
|---|---|---|
| `root` | `osmo` | the bench's working account: autologin on tty1, ttyS0 (ttyAMA0 on Pi) and in GDM |
| `osmocom` | `osmo` | unprivileged, sudoer (sudo, adm, dialout, audio, video, pulse-access, docker); session selectable after logout |
| `linphone_A` | — | pre-provisioned SIP account: extension **100**, UDP to 127.0.0.1:5060 |
| pmOS `user` | `147147` | Phosh screen, account and ssh of the postmarketOS VM |

The bench runs as root. Icons elevate via `pkexec`, the command line via
`sudo`.

---

## 4. What the image contains

### 4.1 Useful tree

| Path | Contents |
|---|---|
| `/opt/GSM/osmo-operator` | **the full repository, with its `.git`** (clone of the `main` branch at build time, `51-depot.sh`): scripts, configs, services, tools, wiki |
| `/opt/GSM/qosmo` | Calypso QEMU fork (`run.sh`, `run_modules/`), C launcher `tools/qosmo-launch` |
| `/opt/GSM/c54x_exe` | the TMS320C54x DSP outside QEMU, TI mask ROM in `rom/`, its `run.sh` (5 steps) |
| `/opt/GSM/grgsm_exe` | the gr-gsm layer 1 outside QEMU |
| `/opt/GSM/firmware/board/compal_e88/` | OsmocomBB firmware `layer1.highram.elf` and the ten boards |
| `/opt/GSM/osmocom-bb` | osmocon, mobile, trxcon |
| `/opt/user_interface/pmos/` | patched pmbootstrap, PPP kernel, VM image `image/qemu-amd64.img.zst` (if embedded), `bin/` launchers |
| `/etc/osmocom/` | generated Osmocom configs (PLMN 001-01, A5/1, 2 MS), `coeur.env` (`N_MS`, `OPERATOR_ID`), `osmo-multi.conf` after the add-ons |
| `/etc/asterisk/`, `/etc/asound.conf` | voice PBX, PCM `gsm_out`/`gsm_in` |
| `/var/cache/osmo-debs/` | the bench `.deb`s (osmo-operator, bridge, qemu-calypso, calypso-firmware) for a git-less install |
| `/usr/share/osmo-operator/` | `info.html` (Info page), SVG icons |
| `/var/log/osmocom/` | `qemu.log`, `bridge.log`, `run.sh.log` |

### 4.2 Packages and software chain (`80-chroot.sh`, `50-injection-image.sh`, `81-cloture-systeme.sh`)

- Base: `debootstrap --variant=minbase` noble, systemd, dbus, kmod, zstd,
  curl, iproute2, `live-boot`, generic kernel, Osmocom libs, tshark, openssh,
  cryptsetup.
- Bench: asterisk, pulseaudio, ffmpeg, MongoDB 8.0, NodeSource (dashboard),
  srsRAN and Open5GS dependencies, `build-dep gnuradio`, venv `/root/.env`.
- **The compiled binaries come from the `osmocom-nitb` Docker image** as
  `.deb`s (`osmo-build-*~noble_amd64.deb`) installed with `dpkg -i`,
  then `/usr/local/*`, `/opt/GSM`, `/root/.env`, `/opt/node`, `/etc/osmocom`,
  `/etc/asterisk` and the `osmo-*.service` units are copied from the container.
- **`ldd` closure**: every `.so` used in the Docker image is copied into the
  rootfs; `/usr/local/lib` goes first in `ldconfig`. The environment that
  works is the image's, not a different apt version.
- Desktop: `ubuntu-desktop-minimal`, wireshark, linphone-desktop, vlc,
  calamares, conky, `python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-vte-2.91`, Firefox
  from packages.mozilla.org, GDM with root autologin, no Wayland.
- Integrity check: the rootfs is verified against dpkg **before**
  compression, then the squashfs is read back and re-verified (`90-iso.sh`).

---

## 5. Capabilities, one by one

General rule: **nothing 2G/4G starts by itself at boot**. Starting is the
operator's call, via the icon, the bottom bar, the command line or
`systemctl`. The units are installed and ready.

### 5.1 The standalone 2G bench

Full native Osmocom stack, one operator (PLMN 001/01), two DCS1800 cells
(ARFCN 514, LAC 1; BTS0 Cell ID 6001 BSIC 7, BTS1 Cell ID 6012 BSIC 8),
subscribers `100101` and `100102`.

- Components: osmo-stp, osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn
  (GTPv1), osmo-pcu (GPRS/EDGE), osmo-mgw, Asterisk (MNCC voice via
  osmo-sip-connector, SIP :5060), SMSC (SMS-over-GSUP, SMPP :2775,
  inter-operator relay :7890). A3A8 auth with deterministic RAND. Live GSMTAP
  :4729 for Wireshark.
- Start: red icon **"Lancer le banc GSM"** (Start the GSM bench; `launch.sh`,
  which starts `osmo-banc.service` and reports it by notification); bottom bar,
  **Banc** group, **run standalone**; `sudo ./start-native.sh` in the
  foreground; `systemctl start osmo-banc`. The stack lives in tmux:
  `tmux attach -t calypso`.
- Stop: right-click **Arrêter le banc** (Stop the bench), `./start-native.sh --stop`
  (also tears down the DSP bench, no need to repeat `--dsp`), `systemctl stop osmo-banc`.
- Sources: `start-native.sh` (delegates to `/opt/GSM/qosmo/run.sh`),
  `launch.sh`, `services/osmo-banc.service`, `configs/*.cfg`,
  `generate_configs.sh`.

### 5.2 Two layer-1 chains: DSP (default) and gr-gsm

| | **DSP** `--dsp` (default since 2026-10-01) | **gr-gsm** `--grgsm` |
|---|---|---|
| Who demodulates | the real TMS320C54x on the TI mask ROM, **outside** QEMU (`/opt/GSM/c54x_exe`) | a gr-gsm decoder in QEMU + `grgsm_exe` bridge |
| QEMU | ARM7 only (`CALYPSO_DSP_EXTERN=1`) | ARM7 + gr-gsm layer 1 |
| TRX bridge | `pont/pont_dsp.py` started by `c54x_exe/run.sh` (TRXD 5700-5702, DL bursts UDP 6702) | `pont/pont.py` |
| Result | the mobile acquires FB/SB, decodes SI1-4, camps, does its location update; mobile VTY :4347 | end to end: camp, LU, auth, A5/1, SMS, voice call; VTY :4247 |

The default lives at the top of `start-native.sh` (`DSP_MODE=1`) and applies to
everything that starts the bench (icon, service, bar, multi's native operator).
If `c54x_exe` is missing, the bench says so and falls back to gr-gsm with its
bridge. Icon right-click: **"Lancer en mode gr-gsm"** (Start in gr-gsm mode).
Persistent: `OSMO_BANC_ARGS="--grgsm"` in `/etc/default/osmo-banc`.

### 5.3 The emulated Calypso baseband

- QEMU fork **qosmo** (`-M calypso`, ARM7TDMI/arm946) runs the real OsmocomBB
  firmware `layer1.highram.elf`, loaded by osmocon as on a C123.
  Seven DSP ROMs, firmware for ten compal boards.
- C launcher `qosmo` (`/usr/local/bin/qosmo`): `-gdb tcp::1234`, `-serial pty`
  published as `<RUN_DIR>/modem.pty`, unix monitor, L1CTL `/tmp/osmocom_l2`.
- Debug: gdb on :1234 (`target remote :1234` against the layer1 ELF),
  monitor `socat - unix-connect:/tmp/qemu-calypso-mon.sock`,
  `--assembly-logs` for the ARM asm trace.
- Manual: `qosmo -k …/layer1.highram.elf`, `MODE=dsp PONT=1 /opt/GSM/c54x_exe/run.sh`.

### 5.4 `start-native.sh` profiles and options

- Profiles: `faketrx-qemu` (default, alias `hybrid`: core + BTS0 QEMU + BTS1
  fake_trx + MS#2), `faketrx`, `qemu` (Calypso only), `noproc`/`core` (core only).
- `--menu` asks the questions (layer 1, standalone/hybrid topology, profile,
  node, WAN, regeneration) instead of guessing.
- `--node N` (1-9): the node's SS7 identity (point codes `1.<node><op>.<role>`,
  routing contexts), ASP towards the inter-STP; `--op N`, `--hub-ip ADDR`.
- `--wan`, `--wan FILE`, `--wan-nodes "1:IP:IND …"`, `--wan-id`,
  `--gen-conf`, `--air-mesh[=PORT]` (shared inter-node radio medium):
  mesh of 1 to 9 nodes. `--virtualbox[=N]` sets up the WAN between the host
  and N-1 VirtualBox VMs (`tools/vbox-wan-lab.sh`).
- `--regen`, `--list`, `--dry-run`, `--status`, `--check-paths`, `--force`,
  `--verbose`, `--launcher <bin>`, exclusive L2 clients `--mobile`,
  `--ccch_scan`, `--bcch_scan`, `--cell_log`.
- Variables: `ENCRYPTION="a5 1"`, `MS_COUNT=2`, `CALYPSO_BRIDGE`,
  `BANC_DSP`, and any `globals.conf` variable set non-empty on the command
  line (see [Environnement](Environnement.md)).

### 5.5 SS7 multi-operator (Docker) and the add-ons

Not in the ISO: the **"Supplements"** icon (`addition.sh`, checkbox window,
inside a bench GTK window) installs what is missing.

- **`--multi`**: docker.io, the operator image pulled from
  `ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest` then derived into
  `osmocom-run` (Dockerfile.run), the topology `/etc/osmocom/osmo-multi.conf`
  (op1 **native** PC 1.1.2 + op2/op3 **docker** 172.20.0.12/.13 PC 1.2.2/1.3.2 +
  hub `osmo-inter-stp` 172.20.0.10, M3UA :2908), `osmo-multi.service` and the
  antenna icon **"multi-operator"**. It ends by starting a multi bench session
  via `launch.sh --multi`, the same path as the icon (`OSMO_MULTI_START=0` to
  install without starting). `addition.sh --status` shows docker, the image,
  the topology, the unit and the icon.
- Then start: antenna icon, bar **run multi**, `systemctl start osmo-multi`,
  `sudo ./launch/start-multi.sh` (`--status`, `--stop`, `--dry-run`). The native
  operator is held by `osmo-banc`: `start-multi.sh` **keeps** it if already
  running and **starts** it if stopped (it only restarts it if its point code
  was just realigned, or with `--restart-natif`).
- **`--opencl`**: OpenCL stack (ocl-icd, clinfo, pocl, detected Intel/Mesa/NVIDIA
  driver) and the tools cloned into `/root`: **deka**, a51_tools,
  dst80_reversing, tea1-cracker. **deka** icon, bar **run deka**.
- **`--claude`**: Claude Code (native installer, standalone binary). The
  **Claude** icon self-installs on first click.
- **`--extras`**: Doom (freedoom), Quake III (OpenArena), Kodi, YouTube
  (Firefox + uBlock), Wireshark as root, Linphone, filed in the bar's Jeux,
  Media, Telephone, Outils folders.

### 5.6 4G (srsRAN + Open5GS) and CSFB

- Full **Open5GS** core on loopbacks (MME, SGW-C/U, SMF, UPF, PCRF, HSS,
  NRF…), MongoDB behind the HSS, **freeDiameter** with TLS certificates installed,
  Prometheus :9090, **WebUI :9999** (`open5gs-webui.service`, Next.js) for
  subscribers.
- **srsENB** radio (10 MHz, EARFCN 3350, band 7) and **srsUE** linked over
  **ZeroMQ** (:2000/:2001), portable binaries (no build-CPU AVX),
  **srsGUI** for real-time traces (`osmo-lte start-gui`). Milenage subscriber
  IMSI 001010001000001, UE in a `ue1` netns, data via `ogstun`
  (10.45.0.0/16) with NAT to the Internet.
- **CSFB**: SGs interface between osmo-msc and the MME (:29118), mapping
  TAI (001-01, TAC 7) → LAI (001-01, LAC 1).
- Start: **"4G du banc"** icon (Bench 4G; `osmo-lte toggle` → `osmo-lte.service`);
  `osmo-lte start|stop|status|up|down|log|journal|start-gui`; core only
  `osmo-epc start|stop|status`. Log and status in bench GTK windows.
- Sources: `tools/osmo-lte.sh`, `tools/osmo-epc.sh`, `tools/osmo-lte-install.sh`,
  `configs/srsran/`, `configs/open5gs/`, `services/osmo-lte.service`,
  `iso_modules/88-lte-pmos.sh`.

### 5.7 The postmarketOS phone

- x86_64 postmarketOS/Phosh VM (1.7 GB compressed), kernel patched with PPP,
  patched pmbootstrap (modem serial port, sound cards, screen size).
- **4G data**: NetworkManager → pppd (`ATD*99***1#`) → virtio-console
  `osmo.data` → `osmo-phonesim-banc.py` → UE netns → srsUE → srsENB → UPF →
  Internet. **2G voice and SMS**: virtio-console `osmo.modem`, the 27.007 AT
  modem is played by `osmo-phonesim-banc.py` based on the bsc/msc/mobile VTYs;
  oFono drives it on the VM side.
- Start: **Téléphone** icon (`osmo-pmos up`), **smartphone** (720x1440) and
  **tablet** (1280x800) formats (`osmo-pmos-qemu`), status, stop and
  reconnect-modem actions (`osmo-pmos-setup`), VM alone without modem.
- **The image**: `osmo-pmos-build` decompresses
  `/opt/user_interface/pmos/image/qemu-amd64.img.zst` on first launch. If it
  is missing or corrupt (`zstd -t`), it is fetched from the GitHub release
  `pmos-image` (resumable, archive verified); otherwise
  `pmbootstrap install` builds it. `OSMO_PMOS_IMAGE_URL` changes the URL.
- Sources: `tools/osmo-pmos*.sh`, `tools/osmo-phonesim-banc.py`,
  `tools/osmo-ofono-bridge.py`, `iso_modules/88-lte-pmos.sh`.

### 5.8 The desktop

- Minimal **GNOME**, root session, dock with the favorites: Firefox, Files,
  Claude, Lancer le banc, Installer, Tutoriel, Info, Supplements,
  multi-operator, Update, Paint, deka, Linphone, Wireshark, Téléphone, 4G.
  The **multi-operator** icon is installed only by the add-ons
  (`addition.sh --multi`): before that, it does not exist and the dock does not show it.
- **No favorite opens a terminal or a shell.** Everything goes through
  `tools/osmo-gtk-run.py`. Since 2026-10-12, launches (2G, multi, 4G, add-ons,
  Update, deka, pmOS phone, drivers) open in `--progress` mode: a small window
  with a **progress bar** (driven by the `[n/m]` markers the scripts print:
  `run.sh` [n/10], `osmo-lte` [n/4], `osmo-pmos` [n/3]; otherwise the bar
  pulses), the current step, the last line, and a **"console"** button that
  expands the full output (VTE terminal, the command runs in a
  pseudo-terminal). A failure expands the console automatically. Only Claude
  and oFono, being interactive, keep a terminal in the window. The systemd
  unit's journal scrolls in the window for 2G and multi
  (`launch.sh --service-suivi`, `--multi-suivi`) and 4G (`osmo-lte up|toggle`).
- **Mobile VTY port**: 4247, or **4347 with `--dsp`**. `start-native.sh`
  publishes the actual port in `/run/osmo-banc/ms1-vty` and in the systemd
  environment (`OSMO_BB1_VTY_PORT`, read by the `osmo-egprs-web` dashboard on
  restart); `launch.sh --vty`, the panel and `vty-menu.sh` read it.
- **Bottom bar** (`tools/osmo-launcher.py`): **removed from the desktop** on
  2026-10-12 (bench decision). The file remains; `OSMO_LAUNCHER=1` in the
  session environment brings it back (Banc, Jeux, Media, Telephone, Outils
  groups, "run" logs).
- **Panel** (`tools/osmo-panel.py`, `osmo-fft-snap.py`): the illustration
  becomes the I/Q spectrum and `mobile.log` while the bench runs; top banner
  (`osmo-topzone.py`, `configs/conky/labgsm.html`) fed by
  `osmo-ts-probe.py`: 8 timeslots, daemons, subscribers, calls, uptime.
- Status **Conky** at the top right (machine, selected operator,
  `Ctrl+AltGr+←/→` or `osmo-op --next`). Redone on 2026-10-12: dark
  translucent plate with rounded corners (`configs/conky/osmo-conky.lua`, Cairo),
  Ubuntu font throughout, colors by kind of information, ● dots and a smiley
  per bench state (green ☺ if running, grey ☹ otherwise). It is **on screen
  only while a bench runs**: `osmo-panel.py` fades it in and out (X11 window
  opacity, xdotool) together with the panel.
- **Central panel** (`tools/osmo-panel.py`, spectrum + log, Dashboard /
  tmux / VTY / ZMQ buttons): **appears only while a bench runs** - a 2G
  (native, container, hub) or a 4G (Open5GS, srsENB, srsUE). With the bench
  stopped, the desktop shows only the background. `OSMO_PANEL_TOUJOURS=1`
  keeps it on screen.
- **Web dashboard** :8080 (`osmo-egprs-web.service`, self-signed HTTPS
  on :80, GSMTAP/SCTP capture), **tutorial** (`osmo-tutorial`), **Info page**
  (`osmo-info`, `configs/info.html`), I/Q spectra `fft-web` :8081.
- Applications: Firefox (only browser, microphone and certificate policy set
  at boot), **Wireshark as root** (`osmo-wireshark-root`, 2G/4G/call/SMS/data
  filters), **Linphone** extension 100, Kodi, dino, oFono, Paint (overlay),
  graphics drivers (`tools/osmo-drivers.sh`, NVIDIA via `ubuntu-drivers`).
- **Plymouth** `osmo-bts`: mast, handset and waves (rings), nothing else
  (preview: `wiki/plymouth-osmo-bts.gif`). Generated at build time by
  `tools/plymouth-render.py` (`86-finitions.sh`).
- **Two-state** wallpaper (`tools/osmo-fond.py`, `osmo-fond ville|antenne`):
  at rest `/usr/share/backgrounds/gsm-lab-ville.jpg` (the waterfront city,
  no antenna — the schema default); as soon as a 2G or 4G starts, a fade
  (~2.4 s, Pillow intermediate frames + GNOME Shell cross-fade) to
  `gsm-lab-antenne.jpg` (the same city, mast raised), and back on stop.
  Triggered by `osmo-panel.py` when it sees the bench come up or go down, by
  `osmo-lte start` and, if the bottom bar is active, on clicking *run standalone*.
  Likewise, the top zone carries only the **Telecom Operator** title while
  nothing runs, and fades to the LAB GSM banner on launch
  (`$XDG_RUNTIME_DIR/osmo-banc.etat`, read by `osmo-topzone.py`). The low-poly
  landscape `gsm-lab-fond.jpg` and `gsm-lab-wallpaper.jpg`
  (`tools/paysage-render.py`) remain installed, but are not the default.

### 5.9 Audio

- **System-wide PulseAudio** (`osmo-pulse.service`, socket `/run/pulse/native`,
  sink `gsm_audio`): osmo-gapk → ALSA `gsm_out` → null sink → monitor →
  loopback; PCM `gsm_out`/`gsm_in` in `/etc/asound.conf`, which `mobile`
  opens. Two duplex chains for the pmOS phone (GAPK bridge, echo
  cancellation).
- **PipeWire** kept **for GNOME screencast only**;
  `pipewire-pulse` purged and masked.
- Sources: `iso_modules/82-services.sh`, `scripts/pulse-gsm-setup.sh`,
  `scripts/audio-chain.sh` (slimmed-down PulseAudio on every start).

### 5.10 Diagnostics

`bash ./checks/check_all.sh` runs everything and gives a verdict (log in
`/tmp`): `global_check.sh` (STP/HLR/MSC/BSC per operator), `ss7_check.sh`
(inter-STP matrix), `diag-stp-operator.sh`, `diag-interstp.sh`,
`wan_ss7_check.sh`, `annuaire.sh` (subscribers), `operator_summary.sh`,
`vty-debug-dump.sh`. `./ss7-console.py`: navigable SS7 diagram with
built-in VTYs. `./start-native.sh --status` tells what is running.

### 5.11 Ports, VTY, network

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 4239 | VTY osmo-stp | | 8080 | bench dashboard |
| 4242 | VTY osmo-bsc | | 8081 | I/Q spectra (fft-web) |
| 4243 | VTY osmo-mgw | | 9090 | Prometheus Open5GS |
| 4245 | VTY osmo-sgsn | | 9999 | WebUI Open5GS (HSS) |
| 4254 | VTY osmo-msc | | 5060 | Asterisk SIP |
| 4258 | VTY osmo-hlr | | 2775 | SMPP |
| 4260 | VTY osmo-ggsn | | 7890 | inter-op SMS relay |
| 4247 / 4248 | VTY mobile 1 / 2 (gr-gsm) | | 29118 | SGs (MSC ↔ MME) |
| 4347 | VTY mobile (DSP bench) | | 2905 / 2908 | M3UA local / inter-STP |
| 4729 | GSMTAP (Wireshark) | | 5700-5702 | TRXD (bridge ↔ osmo-bts-trx) |
| 4730 / 4731 | decoded SI / SCH | | 6702 | DL bursts to the DSP |
| 1234 | gdb QEMU | | 2000 / 2001 | ZeroMQ srsENB ↔ srsUE |

Network: docker interconnect `gsm-inter` 172.20.0.0/24 and `gsm-net-opN`
172.20.N.0/24; node private IP `192.168.<N+1>.10`; LTE `ogstun`
10.45.0.0/16. Numbering plan: `100101`/`100102` (the two subscribers),
`N0001`…`N9999` (operator N in multi), `100`/`200` (Linphone), `600` (echo),
`9XXXXX` (inter-op outgoing).

### 5.12 What was removed, and why

| Removed | Reason | Source |
|---|---|---|
| avahi (daemon, utils, autoipd, libnss-mdns) | no mDNS on a bench; purged and masked | `80-chroot.sh` |
| Chromium | Firefox is the only browser, starts as root with no wrapper | `86-finitions.sh` |
| sssd | masked, not uninstalled (no domain): `systemctl unmask sssd` restores it | `86-finitions.sh` |
| pipewire-pulse | system-wide PulseAudio instead; pipewire kept for screencast | `80-chroot.sh` |
| `osmo-dsp` icon | DSP is the default, right-click offers gr-gsm | `85-installeur-bureau.sh` |
| `osmo-trust-desktop` and the desktop icons | launchers are in the dock and the menu | `85-installeur-bureau.sh` |

---

## 6. Installing to a disk

### 6.1 Starting the installer

The dock's **"Installer"** icon, or `osmo-install` (`/usr/local/bin`, written
by `85-installeur-bureau.sh`). It re-elevates to root via `pkexec`, finds the
squashfs whatever the boot mode (medium, `toram`, loop) and mounts it at a
stable path (`/run/osmo-install-src/live/filesystem.squashfs`), unmounts a
target left mounted by a previous attempt, regenerates the apt mirror page
ranked by speed (`packaging/apt-mirror.sh --list`), then opens Calamares
with the repository's configuration (`installer/calamares/`, copied to
`/etc/calamares` at build time).

### 6.2 The screens (`installer/calamares/settings.conf`)

Welcome (20 GB, 2 GB RAM, root required) → Location
(Europe/Paris) → Keyboard (pc105) → Partitions → Users → Graphics
drivers → Ubuntu mirror → Summary → Install → Finish. The slideshow
during the copy reproduces the image's spec sheet (`branding/osmo/show.qml`).

### 6.3 Partitioning (`modules/partition.conf`)

- **GPT** table, ext4, 300 MiB ESP on `/boot/efi`, no swap by
  default (`swapfile` optional).
- Automatic layout: **"osmo-egprs" on `/`** (50 %, 25 GiB
  minimum, **never encrypted**) and **"crypthome" on `/home`** (the rest,
  5 GiB minimum).
- **Ticking "encrypt" encrypts `/home` only**, with LUKS2: the root stays
  readable, secrets (profiles, keyrings, cookies) live on the encrypted
  volume. Manual partitioning allowed.

### 6.4 Accounts and drivers

- Users: the created account is a sudoer (sudo, adm, dialout, audio, video,
  pulse-access, docker…), with GDM autologin; the root password is asked for
  (`setRootPassword`), no complexity requirement; the name `root` is
  forbidden.
- Graphics drivers: nouveau (free) by default; option **NVIDIA 610
  proprietary**, installed in the target only if `lspci` sees a 10de card
  and the network responds (`apt-get install nvidia-driver-610`, then
  `update-initramfs`).
- Mirror: the live stick's one or a measured mirror.

### 6.5 What the installer does in the target (`modules/shellprocess-osmo.conf`)

1. Unlocks root (`passwd -u root`).
2. Deletes the live stick's `osmocom` account (unless it is the chosen name).
3. `crypthome-postinstall <user>`: wires up the encrypted `/home` (see 6.7).
4. Removes the root autologins on tty1 and ttyS0.
5. GDM: `AutomaticLogin=<user>`; the PAM rule refusing root at the login
   screen is restored.
6. Copies the launchers from `/etc/skel` to the user's desktop.
7. Installs and enables `osmo-egprs-web.service`.
8. Removes the `osmo-install` and `calamares` icons from the menu.
9. Generates `~/.config/pmbootstrap_v3.cfg` for the user.
10. Purges `live-boot`, rebuilds the initramfs.

GRUB: `/EFI/ubuntu` (prefix compiled into the signed GRUB), `GRUB_TIMEOUT 5`,
os-prober enabled, `GRUB_ENABLE_CRYPTODISK=y`, kernel line inherited from the
stick (`quiet splash`). fstab: `noatime`, `discard` on SSD.

### 6.6 After installation: accounts and services

| | Live stick | Installed disk |
|---|---|---|
| GDM session | root, automatic | the created user, automatic |
| root | pw `osmo` | pw chosen at install, unlocked |
| `osmocom` | sudoer, pw `osmo` | deleted |
| `osmo-egprs-web` | active | active |
| `osmo-banc`, `osmo-multi`, `osmo-lte` | installed, not enabled | installed, not enabled |

Enable a bench at every boot: `systemctl enable --now osmo-banc`
(or `osmo-multi`, `osmo-lte`). At build time: `--banc`, `--multi`,
`OSMO_ISO_LTE=1`. On disk for multi: `OSMO_MULTI_ENABLE=1 ./addition.sh`.

### 6.7 Living with the encrypted `/home` (`configs/crypthome/`)

- **At boot**, `unlock-home.service` asks a single question, on the text
  console, after leaving Plymouth:
  `decrypt /home -passphrase- or Enter`. The passphrase (echoed as `*`) opens
  the volume and the user's session. **Empty Enter, 60 s timeout, three
  rejected passphrases, missing disk or failed mount: the machine boots
  anyway**, into an **ephemeral root** session (GDM switches to root for this
  boot only; `/root` is covered by an overlay whose writes go to a tmpfs).
  Boot is never blocked.
- `CRYPTHOME_PROMPT=plymouth` in `/etc/default/crypthome` puts the question
  back in the Plymouth theme (only for machines where its keyboard input
  works; on an Intel + NVIDIA laptop it took no keystrokes).
- Afterwards: `unlock-home` / `lock-home` in a terminal; apps holding
  secrets (Firefox, Thunderbird, KeePassXC…) run as the volume owner via
  `run-as-owner` when it is open, as root otherwise (`refresh-owner-apps`
  redirects the launchers).
- Second disk added later: `/root/init-crypthome.sh` (LUKS2, `rsync` copy,
  crypttab/fstab with `noauto`, service enabled, the old `/home` set aside in
  `/var/backups/home-avant-chiffrement-*` at the next reboot).

### 6.8 Updating an installed machine

- `osmo-update` (at boot, or by hand): fast-forward `git fetch` of
  `/opt/GSM/osmo-operator` and the embedded repositories. No packages.
- What the build installs **outside** the repository (units in
  `/etc/systemd/system`, `unlock-home` in `/usr/local/sbin`, `osmo-*-anim`
  launchers) is reinstalled by hand from `services/` and
  `configs/crypthome/`, or by reinstalling.
- `addition.sh` and `update.sh` rewrite the `.desktop` files they own.

---

## 7. Building the ISO

### 7.1 Where the pieces come from

```
Docker image osmocom-nitb (compiled by build.sh, or PULLED from ghcr.io)
        │  .deb osmo-build-*  +  /usr/local, /opt/GSM, venv, configs
        ▼
debootstrap minbase noble ──► rootfs ──► chroot (apt packages, desktop, 4G, pmOS…)
        │                                   │
        │   GitHub clone of osmo-operator ──┘  (51-depot.sh: main branch)
        ▼
squashfs zstd -19 ──► hybrid xorriso ISO + signed shim/grub (or arm64 SD image)
```

- **The Docker image is not rebuilt by default** (amd64). Pull order:
  `ghcr.io/<repo>/osmocom-nitb:base-<fingerprint>` (the fingerprint is the
  sha256 of the tracked files in Dockerfile, packaging, configs, scripts,
  services, helpers, opt-gsm, tools, patches: when it matches, the published
  image was built from exactly this tree), then the repo's `:latest`, then
  the Docker Hub image. `build.sh` runs only if none responds,
  or with `--build-docker`.
- **The repository burned into the ISO is a clone of the `main` branch on
  GitHub**, not the local tree: push before burning. To burn the local tree,
  `OSMO_EGPRS_REPO=/chemin/du/depot OSMO_EGPRS_BRANCH=<branche>`.
- **The `iso_modules/` modules and `build-iso.sh`, however, are read from the
  local tree** at build time.

### 7.2 Host requirements (`iso_modules/20-hote.sh`)

Ubuntu 24.04 as root, docker (installed if missing), and the packages the
module installs: debootstrap, git, rsync, zstd, xz, cpio, gcc, make, python3-pil,
python3-yaml, kpartx, dosfstools, mtools; on amd64 squashfs-tools, xorriso,
grub-pc-bin, grub-efi-amd64-bin and -signed, shim-signed, isolinux,
syslinux-utils; on arm64 qemu-user-static, binfmt-support, docker-buildx.
`OSMO_ISO_HOST_READY=1` skips this step. No disk space check is done: leave
plenty of room in `/var/tmp` (the work directory is
`/var/tmp/iso-build-<pid>`, never `/tmp`, often a tmpfs: rootfs, squashfs
and ISO must fit there together) and for the docker store (base image ~11 GB).

### 7.3 The command

```bash
sudo ./build-iso.sh --desktop                 # the published image
sudo ./build-iso.sh                           # the four amd64 images
sudo ./build-iso.sh --role=operator --node=2  # the operator for node 2
sudo ./build-iso.sh --arm --lite              # Raspberry Pi 4 SD image
```

| Option | Variable | Effect |
|---|---|---|
| `--role=operator\|interstp` | `ISO_ROLE` | bench or SS7 hub |
| `--node=N` | `ISO_NODE`, `ISO_WAN_ID` | node identity 1-9, name `osmo-operator-N` |
| `--lite`, `--desktop`, `--all` | `ISO_LITE`, `ISO_DESKTOP`, `ISO_ALL` | see §2 |
| `--arm` / `--arch=arm64` | `ISO_ARCH` | Raspberry Pi 4 (Armbian, ports.ubuntu.com) |
| `--banc`, `--multi` | `OSMO_ISO_BANC`, `OSMO_ISO_MULTI` | enable the unit at the image's boot |
| `--version=24.04\|22.04` | `ISO_UBUNTU`, `ISO_SUITE` | noble (default) or jammy |
| `--kb=fr` | `OSMO_ISO_KB` | keyboard layout (asked in the terminal otherwise) |
| `--output=FILE` | `OUTPUT` | output name |
| `--no-cache` | `NO_CACHE` | full recompilation, `.deb`s rebuilt |
| `--skip-build[=image:tag]` | `ISO_SKIP_BUILD`, `ISO_PULL_IMAGE` | pull required, no fallback to build.sh |
| `--build-docker` | `ISO_FORCE_BUILD` | build the image locally |
| `--without-debs` | `ISO_WITH_DEBS` | no bench `.deb`s in the image |
| `--wan`, `--wan-nodes=`, `--wan-id=`, `--wan-ops=`, `--hub-ip=` | `ISO_WAN*`, `ISO_HUB_IP` | WAN table burned into `/etc/osmo-wan.conf` |

Other variables: `OSMO_ISO_WORK` (work directory), `OSMO_DEB_CACHE`
(`/var/cache/osmo-debs`), `OSMO_ISO_LTE=1`, `OSMO_ISO_PMOS_IMAGE`
(`/chemin/qemu-amd64.img.zst` or `none`), `OSMO_PMOS_IMAGE_URL`,
`OSMO_ISO_LTE_BUILD=0` (no 4G compilation if the `.deb`s are missing),
`OSMO_EGPRS_REPO`/`OSMO_EGPRS_BRANCH`, `OSMO_WEB_REPO` (dashboard).

### 7.4 The module chain (`iso_modules/`)

All are sourced in the same shell, in numeric order; a module with nothing
to do exits via `return` (that is how `--arm` skips a step).

| Module | What it does |
|---|---|
| `00-options.sh` | options, help, suite, mirror, root check |
| `10-clavier.sh` | keyboard layout (menu if terminal, otherwise `fr`) |
| `20-hote.sh` | host packages, docker, tools, arm64 binfmt |
| `21-docker-build.sh` | pull or build of the Docker image, child passes of `--all`, output names |
| `22-wan-table.sh` | WAN table, `trap cleanup`, tool checks |
| `30-image-configs.sh` | Osmocom configs generated from templates (`start-docker.sh`), native patches |
| `31-image-source.sh` | source image, suite check, injection of `/etc/osmocom` and `/etc/asterisk` |
| `40-rootfs.sh` | `debootstrap --variant=minbase` (cache `~/.cache/osmo-iso-debs`), or inherited rootfs |
| `50-injection-image.sh` | build `.deb`s via `dpkg -i`, copy of `/usr/local`, `/opt/GSM`, venv, node, units |
| `51-depot.sh` | clone of osmo-operator and the tests, `coeur.env` |
| `51-shannon.sh` | clone of `bbaranoff/firmwire` (`/opt/GSM/FirmWire`) and `bbaranoff/shannon_ghidra_proj` (`/opt/GSM/shannon_ghidra_proj`) |
| `52-qemu.sh` | qosmo, c54x_exe, grgsm_exe, DSP ROMs, firmware, qemu-system-arm, `qosmo` launcher, toast/untoast |
| `60-dashboard.sh` | osmo-egprs-web (native, no docker), tutorial, unit enabled |
| `70-scripts.sh` | `/usr/local/bin` links, `osmo-wan.conf`, NetworkManager |
| `71-debs-banc.sh` | `packaging/build-debs.sh` → rootfs `/var/cache/osmo-debs` |
| `80-chroot.sh` | apt repos (NodeSource, MongoDB, Armbian), kernel, packages, venv, desktop, Firefox, GDM, gsettings, `update-initramfs` |
| `81-cloture-systeme.sh` | `ldd` closure from the image, no-wait network, DNS, `osmo-ip-plan`, `osmo-qemu-link`, `osmo-update`, SMS animation |
| `82-arm-natif.sh` | `--arm`: native compilation in the arm64 chroot |
| `82-services.sh` | role marker, os-release, Asterisk, audio (system-wide PulseAudio, `asound.conf`), units installed not enabled, Open5GS WebUI |
| `83-espace-ram.sh` | fstab, `/tmp` and `/dev/shm` as % of RAM, journal, logrotate, ring-buffer tcpdump, ssh, purge |
| `84-comptes.sh` | root and osmocom, console and GDM autologin, Linphone account |
| `85-installeur-bureau.sh` | Calamares (`/etc/calamares`), `osmo-install`, icons, GTK launchers (`osmo-*-anim`), Info page |
| `86-finitions.sh` | fixed live-boot `toram`, sssd masked, Chromium removed, Firefox microphone, screenfetch banner, Plymouth `osmo-bts` |
| `87-lite.sh` | `--lite` pruning of `/opt/GSM` |
| `88-lte-pmos.sh` | srsRAN + Open5GS (from the `.deb`s, otherwise compiled), freeDiameter, pmbootstrap, PPP kernel, VM image, final 2G + 4G + phone check |
| `89-home-chiffre.sh` | crypthome tools, `unlock-home.service`, root keyring on the encrypted volume, launchers under `run-as-owner` |
| `90-iso.sh` | dpkg check, squashfs zstd -19, kernel, GRUB menu, `/.disk/info`, squashfs read-back |
| `91-secure-boot.sh` | xorriso ISO with signed shim and GRUB (or unsigned `grub-mkrescue`) |
| `92-rpi-image.sh` | `--arm`: SD image (boot partition + Armbian ext4) |
| `99-fin.sh` | rootfs handed to the next pass (`--all`), summary |

### 7.5 CI (`.github/workflows/build-iso.yml`)

- Triggers: push of a `v*` or `iso-*` tag, or manual dispatch with the
  inputs `release`, `no_cache`, `build_docker`, `mode`
  (all, stp, base, lite, desktop) and `pmos_image` (embeds the postmarketOS
  VM, +1.7 GB per ISO).
- A single job on `ubuntu-24.04` (6 h max): runner cleanup, docker moved to
  `/mnt`, `.deb` cache keyed by fingerprint
  (`osmo-debs-noble-g2-<empreinte>`). If `ghcr.io/…/osmocom-nitb:base-<empreinte>`
  exists, it is pulled (`--skip-build=REF`); otherwise `--build-docker`.
- Outputs: `SHA256SUMS`, `MD5SUMS`, files over 2 GiB split into
  `*.iso.part-NN` (1,900 MB) with `PARTS.sha256`, 14-day artifact,
  GitHub release (`softprops/action-gh-release`) with the notes from
  `.github/release-notes.md`, pre-release except on a `v*` tag.

### 7.6 Durations and sizes

| | |
|---|---|
| Desktop build, Docker image pulled | ~2 h 15 on 16 cores |
| Full Docker compilation (`--build-docker`) | 1 h 23 in CI (`wiki/Build.md` states 15-20 min on a reference machine) |
| Desktop ISO | 6.5 GB (4 parts in the release) |
| Desktop vs operator | +2.5 GB |
| Base Docker image | ~11 GB |
| `--arm` first time | about ten hours (emulation) |

---

## 8. Files to know

| File | Role |
|---|---|
| `build-iso.sh`, `iso_modules/` | the build chain |
| `installer/calamares/` | the installer (modules, branding, slideshow) |
| `configs/crypthome/` | encrypted `/home`: `unlock-home`, `crypthome-postinstall`, `init-crypthome.sh`, `run-as-owner` |
| `configs/plymouth/osmo-bts/`, `tools/plymouth-render.py` | the boot theme, generated |
| `services/*.service` | `osmo-banc`, `osmo-multi`, `osmo-lte`, `osmo-egprs-web`, `open5gs-webui` |
| `data/desktop/*.desktop` | the dock icons; `tools/osmo-gtk-run.py` the windows |
| `/etc/default/osmo-banc`, `/etc/default/osmo-multi`, `/etc/default/osmo-lte` | persistent service options |
| `/etc/default/crypthome` | UUID, owner, timeout, `CRYPTHOME_PROMPT` |
| `/etc/osmocom/coeur.env`, `/etc/osmo-wan.conf`, `/etc/osmo-role` | node, WAN, image role |
| `/var/log/osmocom/`, `journalctl -u osmo-banc` | bench logs |
| `addition.sh` | the add-ons (docker/multi, OpenCL/deka, Claude, extras) |
| `checks/check_all.sh`, `ss7-console.py` | diagnostics |
