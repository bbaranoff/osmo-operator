# Build — Docker image, ISO, `.deb` packages, native install

Four paths, one build engine. Everything that gets compiled (libosmocore,
osmo-*, gapk, QEMU and its tree, osmocom-bb, the gr-gsm venv, the firmware) comes
out as a `.deb` package and stays **on the host**, in `/var/cache/osmo-debs`. The first
build compiles everything; later ones only compile what is missing.

```
build.sh ──► image osmocom-nitb ──► start-docker.sh / compose.sh      (Docker)
     │              │
     │              └──► build-iso.sh ──► ISO amd64 / .img arm64   (bootable)
     └──► /var/cache/osmo-debs ──► packaging/build-debs.sh ──► dpkg -i   (no git)
install.sh ─────────────────────────────────────────────────►  native Ubuntu 24.04
```

---

## 1. `build.sh` — the Docker image

```bash
sudo ./build.sh [--no-cache] [--lite] [--stp] [--arch=arm64|--arm]
```

| Option | Effect |
|---|---|
| *(none)* | `osmocom-nitb` image (Dockerfile): core + BTS + QEMU Calypso + gr-gsm + Asterisk |
| `--lite` | `osmocom-nitb:lite` image (Dockerfile.lite): without the workshops |
| `--stp` | `osmocom-stp` image (Dockerfile.stp): the inter-STP alone, arm64 possible |
| `--no-cache` | docker cache ignored **and** `OSMO_DEB_REFRESH=1`: everything is recompiled, the `.deb` cache rewritten |
| `--arch=arm64`, `--arm` | arm64 cross-build (Raspberry Pi 4) |

What the script does, in order:

1. `cd` into the script's directory (the `.desktop` goes through pkexec, which starts in `/root` — without this `cd`, `docker build .` looks for `/root/Dockerfile`).
2. `/usr/local/sbin` in the `PATH`: that is where `packaging/apt-fast-install.sh` puts `apt-fast` (aria2). Same installer on the host, in the images and in the ISO rootfs.
3. Installs Docker + **compose v2 + buildx** — a dependency, not an option. `compose.yaml` describes the `nitb`, `run`, `lite`, `stp` services. `docker build` remains the fallback.
4. Copies `/var/cache/osmo-debs` into `.deb-cache/` (the docker context). The image installs these packages with `dpkg` instead of recompiling.
5. Builds. Every directory compiled in the image comes out as a `.deb` via `packaging/osmo-deb.sh`.
6. Brings what the image produced back into the host cache.

Variables:

| Variable | Default | Role |
|---|---|---|
| `OSMO_DEB_CACHE` | `/var/cache/osmo-debs` | where the cache lives |
| `OSMO_DEB_REFRESH` | `0` | `1` = recompile and rewrite (what `--no-cache` sets) |

```bash
./compose.sh debs                     # cache contents
sudo ./compose.sh build [--no-cache] [--lite] [--stp]   # = build.sh
sudo ./compose.sh up [--ms 2] [--phy faketrx] [--no-run]  # hub + osmo-operator-1, HLR populated
sudo ./compose.sh down | ps | logs | shell
```

First build time: 15-20 min (osmocom-bb + ARM toolchain + QEMU).

---

## 2. `build-iso.sh` — bootable ISO / SD image

```bash
sudo ./build-iso.sh [options]
```

**No option**: the four amd64 images — `interstp`, `operator` (normal), `lite`,
`desktop`. A **single** docker build (`osmocom-nitb`), then each rootfs derives
from it: interstp; normal, from scratch; lite = copy of normal with the workshops
removed; desktop = normal + the desktop. Only exception: `--role=interstp`
alone builds only `osmocom-stp`.

### What to build

| Option | Effect |
|---|---|
| `--role=operator\|interstp` | a single image |
| `--node=N` | ISO pre-assigned to node N (otherwise the node is chosen at launch, `start-native.sh --node`) |
| `--lite` | image without workshops |
| `--desktop` | GNOME, bench status Conky, icons « Lancer le banc GSM », « multi-operator », « osmo-lte », « Pilotes graphiques » |
| `--all` | everything |
| `--arm` | arm64 SD image for Raspberry Pi 4, Armbian 24.04 base (`osmo-operator-<…>-rpi4.img`); `--lite` accepted, `--desktop` and `--all` refused |
| `--version=24.04\|22.04` | Ubuntu base |
| `--kb=fr` | keyboard |
| `--output=fichier` | ISO file name |

### Where the Docker image comes from

By default (amd64) **the image is pulled, not built**, in this order:
`ghcr.io/<dépôt>/osmocom-nitb:base-<empreinte du dépôt>` → `:latest` from the same repo
→ Docker Hub. `build.sh` only runs if none of them answers. The fingerprint is the
workflows' one: when it matches, the published image was built from exactly
this tree; the other two references don't guarantee that, and the script says so.
On arm64 nothing is published: it compiles by default.

| Option | Variable | Effect |
|---|---|---|
| `--skip-build[=image:tag]` | `OSMO_ISO_SKIP_BUILD` | pull mandatory, no fallback to `build.sh`; `=image` forces the reference. `OSMO_ISO_SKIP_BUILD=0` = never pull |
| `--build-docker` | `OSMO_ISO_BUILD_DOCKER=1` | the opposite, **and it wins**: builds even if a `--skip-build` is lying around |
| `--no-cache` | | passed to `build.sh` |

### What travels in the image

| Option | Variable | Effect |
|---|---|---|
| *(default)* | | the cached `.deb`s are installed into the rootfs with `dpkg`, then the rest of the image is copied; the packages stay in the ISO's `/var/cache/osmo-debs` |
| `--without-debs` | `OSMO_ISO_WITHOUT_DEBS=1` | the `.deb`s are used to install the stack but **do not stay** |
| | `ISO_EMBED_DEBS=1` | also embeds the `.deb`s from `packaging/build-debs.sh` |

### What starts at boot

The `osmo-banc.service`, `osmo-multi.service`, `osmo-lte.service` units are
**installed but not enabled**: a freshly installed machine boots to its
desktop. The operator starts things (icon, `launch.sh`, `systemctl start osmo-banc`).

| Option | Variable | Effect |
|---|---|---|
| `--banc` | `OSMO_ISO_BANC=1` | enables `osmo-banc` at boot |
| `--multi` | `OSMO_ISO_MULTI=1` | enables `osmo-multi` (`Requires=osmo-banc`, docker) |
| | `OSMO_ISO_LTE=1` | enables `osmo-lte` |

On an already installed machine: `OSMO_MULTI_ENABLE=1 ./addition.sh`. Persistent
service options: `OSMO_BANC_ARGS="--grgsm"` in `/etc/default/osmo-banc` (DSP has been the default since 2026-10-01).

### WAN in the ISO

```bash
sudo ./build-iso.sh --wan --wan-nodes="1:IP:IND 2:IP:IND …" --wan-id=N --wan-ops=N --hub-ip=IP
```

Sets `WAN_AUTO=1` in `/etc/osmo-wan.conf`: the bench brings up the WAN without asking.
Without `--node`, **a single ISO serves all nine nodes** — the number is deduced
from the local IPs or passed with `start-native.sh --node N`.

### Miscellaneous

| Variable | Role |
|---|---|
| `OSMO_ISO_WORK` | working directory, **on disk** (not `/tmp`, often a tmpfs → « No space left on device ») |
| `OSMO_ISO_VERSION` | = `--version` |

The disk installed by Calamares: accounts from the « Utilisateurs » (Users) screen + root
unlocked (no more `osmocom` account from the live system); LUKS offered (LVM in manual mode,
`lvm2` included); the « Pilotes graphiques » (Graphics drivers) page = `apt install nvidia-driver-610`
if `lspci` sees a card (network required), and the `tools/osmo-drivers.sh` icon
afterwards. `/etc/osmocom/coeur.env` (written by the ISO) carries `N_MS`.

---

## 3. `packaging/build-debs.sh` — installing without git

```bash
./packaging/build-debs.sh          # osmo-operator, pont, qemu-calypso, calypso-firmware → packaging/dist/
sudo dpkg -i packaging/dist/*.deb  # refuses to install over a git clone at the same path
```

The `pont` package ships `pont.py` and `pont_dsp.py` (executables) and the
`pont/dsp/` subpackage since 2026-09-23.

`packaging/snapshot-lte-debs.sh` freezes Open5GS / srsRAN; `build-pmos-kernel-deb.sh`
the phone's postmarketOS kernel (PPP to the `ue1` netns).

---

## 4. `install.sh` — native, Ubuntu 24.04 (noble)

```bash
sudo ./install.sh                  # all steps
./install.sh --list                # the steps, without doing anything
./install.sh --check               # what is already in place
./install.sh --dry-run
sudo ./install.sh --reinstall      # replays everything: sources updated, configs and shortcuts rewritten
sudo ./install.sh --only bureau    # a single step (deps, sources, build, binaires, configs, bureau…)
sudo ./install.sh --skip build     # all but one
```

The steps live in `install_modules/`. `bureau` installs the same files as
the ISO (`data/desktop/*.desktop`, `data/*.svg`) in the menu and on the desktop of
root and of the `sudo` user. The native install **does not enable** the
systemd units. Launching is still `./start-native.sh`, which delegates to
`/opt/GSM/qosmo/run.sh`.

The emulated phone (steps `firmware`, `qosmo`, `c54x`, `grgsm-exe` — group `calypso`,
`install_modules/45-calypso.sh`) goes through each repository's installer (`qosmo/install.sh`,
`c54x_exe/install.sh`, `grgsm_exe/install.sh`, the same ones the Dockerfile and the ISO call);
`sudo ./install.sh --telephone` installs it alone on your own Osmocom stack — see
[Telephone-emule](Telephone-emule.md).
