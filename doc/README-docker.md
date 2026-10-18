# osmo-operator — Docker

Run the bench in containers, or build the images yourself. Docker is also how
several operators run side by side on one host ([README-ss7](README-ss7.md)).

← [README](../README.md) · Details: [wiki/Build](../wiki/Build.md), [wiki/Environnement](../wiki/Environnement.md), [wiki/Reference §3](../wiki/Reference.md#3-building-the-images)

## Run the published image

```bash
sudo docker pull ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./launch/start-docker.sh
```

Then enter the container and bring the stack up:

```bash
sudo docker exec -ti osmo-operator-1 bash

cd /opt/GSM/osmo-operator
./start-native.sh --regen     # regenerate configs from the templates (first run)
./start-native.sh --stop      # make sure nothing is left over
./start-native.sh             # start the bench
```

`start-native.sh` attaches to tmux at the end: you are looking at a live GSM
network with a mobile camped on it. Re-attach later with:

```bash
docker exec -ti osmo-operator-1 tmux -S /tmp/osmocom_tmux attach -t osmocom
```

Everything `start-native.sh` does is the same as in native mode:
[README-native](README-native.md).

## Build the images

```bash
sudo ./build.sh                # build osmocom-nitb (apt-fast, compose v2, .deb cache)
sudo ./build.sh --no-cache     # recompile everything and rewrite the cache
sudo ./build.sh --lite         # without the workshops
sudo ./build.sh --stp          # osmocom-stp: the inter-STP alone (Dockerfile.stp)
sudo ./build.sh --arch=arm64   # cross-build, see README-arm
```

### The build is a graph, not a chain

`Dockerfile` is split into BuildKit stages, so the long compilations that do not
depend on each other run **at the same time**:

```
                 base   (apt, apt-fast, osmo-deb, configs)
                   |
        +----------+--------+---------+
    osmo-core    qemu      lte      node        <- IN PARALLEL
        |          |
   +----+-----+    |
  bb  grgsm-venv  l1
   +----+-----+---+
             |
       osmocom-nitb   (assembly)
             |
           debs       (FROM scratch: the .deb cache, for CI)
```

`bb`, `l1` and `grgsm-venv` are deliberately **not** parallel to `osmo-core`:
they link against libosmocore. `--target osmocom-nitb` is **mandatory**
(`debs` is the last stage, so without it Docker builds an empty image).
`build.sh` and `compose.yaml` already pass it.

### The `.deb` cache

Everything the image compiles comes out as a `.deb` through
`packaging/osmo-deb.sh` and stays **on the host**, in `/var/cache/osmo-debs`
(`OSMO_DEB_CACHE` to move it). The second build installs with `dpkg -i` and
compiles nothing. Each package carries both the installed files and the
`/opt/GSM` source tree, so a cached rebuild still gives you a workshop you can
read, patch and `make` in.

```bash
./compose.sh debs                  # what is in the cache
./packaging/build-debs.sh          # standalone .deb -> packaging/dist/
sudo dpkg -i packaging/dist/*.deb  # refuses to install over a git clone at the same path
```

## Docker Compose

```bash
sudo ./compose.sh build [--no-cache] [--lite] [--stp]
sudo ./compose.sh up [--ms 2] [--phy faketrx]    # hub + osmo-operator-1, HLR populated
sudo ./compose.sh down | ps | logs | shell
```

## PHY modes (mobile side, in a container)

Selected through `PHY_MODE` inside the container before calling `run.sh`:

| `PHY_MODE` | stack | use |
|---|---|---|
| `faketrx` (default) | `fake_trx` → `trxcon` → `mobile` | multi-MS, fast, no DSP |
| `virtphy` | `osmo-bts-virtual` ↔ `virtphy` ↔ `mobile` | multi-MS over UDP multicast |
| `qemu` | `osmo-bts-trx` ↔ bridge ↔ Calypso QEMU ↔ `mobile` | emulated baseband, 1 MS |

`PHY_MODE=qemu` forces `N_MS=1`: the bridge uses fixed UDP ports, so one
emulated Calypso per container. For several virtual handsets, run several
containers.

## Several operators

`sudo ./launch/start-docker.sh` asks for a bridge mode and N operators (1 to 9), each in its
own container, joined by an inter-STP container. See [README-ss7](README-ss7.md).

## CI images

`.github/workflows/docker.yml` publishes the amd64 base to GHCR
(`osmocom-nitb:base-<fingerprint>`), and `docker-arm.yml` the arm64 one
(`base-arm64-<fingerprint>`). An unchanged base (same fingerprint) is not
rebuilt.
