# osmo-operator — arm64 / Raspberry Pi 4

The same stack, built for arm64 and shipped as an **SD card image** for the
Raspberry Pi 4 (Armbian 24.04 base). It is not a live ISO: the root filesystem
is a persistent ext4.

← [README](../README.md) · Details: [wiki/ISO](../wiki/ISO.md), [wiki/Build](../wiki/Build.md)

## What you get, and what you don't

| | arm64 image |
|---|---|
| Format | `osmo-operator-<…>-rpi4.img`, MBR: FAT32 `RPICFG` (firmware, kernel, DTBs) + ext4 `armbi_root` |
| Base | Armbian 24.04, bcm2711 kernel and rpi4b BSP (apt.armbian.com) |
| 2G bench | yes: Osmocom core, Calypso QEMU, gr-gsm and DSP layer 1s, compiled natively for aarch64 |
| `--lite` | yes |
| Desktop (`--desktop`), installer, `--all` | no: refused by `build-iso.sh` for arm64 |
| 4G / CSFB / postmarketOS | no: srsRAN and Open5GS are not built for aarch64 (`88-lte-pmos.sh` exits early) |

## Flash and boot

```bash
sudo dd if=osmo-operator-<…>-rpi4.img of=/dev/sdX bs=4M status=progress conv=fsync
```

At first boot the root partition grows to fill the card (`osmo-grow-root`).
Then use the bench as in [README-native](README-native.md): `./start-native.sh`.

## Build it

On an x86 host, everything is emulated (qemu-user-static, `docker buildx
--platform linux/arm64`, `debootstrap --foreign`). It works, but **expect about
ten hours** for the first build. The `.deb` cache makes later builds short.

```bash
sudo ./build.sh --arch=arm64          # the arm64 Docker image only (tagged :arm64)
sudo ./build-iso.sh --arm --lite      # the SD image
```

On an arm64 host, `build.sh` and `iso_modules/40-rootfs.sh` see that target and
host match, and take the native path: no qemu-user, no buildx `--platform`.

What is specific to the arm64 build:

- `iso_modules/82-arm-natif.sh` compiles `toast`, the `qosmo` launcher,
  `c54x_exe` / `grgsm_exe` and the bench `.deb` **inside the arm64 chroot**.
  Doing it on the x86 host would silently put x86 binaries in the rootfs. It
  also installs the Pi firmware partition contents, with a hook that replays on
  every kernel update.
- `iso_modules/92-rpi-image.sh` assembles the image without mounting anything
  (`mke2fs -d`, `mcopy`, `sfdisk`, `dd`).

Host packages: `./build.sh --arm` installs everything the arm64 chain needs on the host (`qemu-user-static`, `binfmt-support`, `docker-buildx`, `debootstrap`, `mtools`, `dosfstools`, `e2fsprogs`, `kpartx`, ...).

## CI

- `.github/workflows/docker-arm.yml` builds the arm64 base image **natively**
  on an `ubuntu-24.04-arm` runner and publishes it to GHCR as
  `osmocom-nitb:base-arm64-<fingerprint>`.
- `.github/workflows/build-arm.yml` pulls that image and produces the SD image.
  It runs on tags `rpi-*` / `arm-*` or by hand. The emulated x86 path cannot
  finish within GitHub's 6-hour job limit, hence the native runner.

## Build it with the official Armbian framework (armbian/build)

`armbian/build-armbian.sh` builds the same image through
[github.com/armbian/build](https://github.com/armbian/build) instead of the
hand-made assembly of `build-iso.sh --arm`: Armbian produces the kernel, the
board support, the firmware partition and the `.img`; the stack is dropped in
through the framework's own hook, `userpatches/customize-image.sh`, with the
contents of the project's arm64 Docker image bind-mounted as `/tmp/overlay`.

```bash
sudo ./build.sh --arch=arm64                        # host packages (qemu-user, binfmt, buildx...) + the arm64 stack image, once
sudo armbian/build-armbian.sh                       # clone armbian/build, overlay, compile.sh
sudo armbian/build-armbian.sh --prepare             # everything but compile.sh (inspect userpatches/)
sudo armbian/build-armbian.sh --board=orangepi5 --branch=edge
```

Defaults: `BOARD=rpi4b BRANCH=current RELEASE=noble`, clone in
`/opt/GSM/armbian-build` (`--armbian-dir=`), image in its `output/images/`.
The stack source is `osmocom-nitb:arm64` if present, else the published
`ghcr.io/<repo>/osmocom-nitb:base-arm64-<fingerprint>`, else `--image=`.
`customize-image.sh` installs the runtime packages, `dpkg -i` the build `.deb`s,
copies `/usr/local`, `/opt/GSM`, `/etc/osmocom` and the units, compiles natively
what an x86 host cannot (toast, the qosmo launcher, `c54x_exe`/`grgsm_exe`, the
bench `.deb`s), sets the accounts (root/osmo, osmocom/osmo) and skips Armbian's
first-login wizard. `--no-stack` gives a bare Armbian image.
