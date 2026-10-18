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

Host packages needed: `qemu-user-static`, `binfmt-support`, `docker-buildx`.

## CI

- `.github/workflows/docker-arm.yml` builds the arm64 base image **natively**
  on an `ubuntu-24.04-arm` runner and publishes it to GHCR as
  `osmocom-nitb:base-arm64-<fingerprint>`.
- `.github/workflows/build-arm.yml` pulls that image and produces the SD image.
  It runs on tags `rpi-*` / `arm-*` or by hand. The emulated x86 path cannot
  finish within GitHub's 6-hour job limit, hence the native runner.
