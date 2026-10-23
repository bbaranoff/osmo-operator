# The install notebook

← [README](../README.md) · Notebook: [installer-osmo-jusquau-dsp.ipynb](installer-osmo-jusquau-dsp.ipynb) · See also: [native](../doc/README-native.md), [docker](../doc/README-docker.md), [tests](../doc/README-tests.md)

`wiki/installer-osmo-jusquau-dsp.ipynb` builds the whole bench **step by step, in your browser**: from a
fresh Ubuntu 24.04 to a verified call on the emulated Calypso DSP (c54x_exe + TI mask ROM). Each step is
one cell, followed by a check cell, so you see every component being built and can stop and look at any
point.

It is a teaching path, not the fastest one. To simply get a working bench, use the [ISO](../doc/README-iso.md)
or the [Docker images](../doc/README-docker.md) built by `build.sh`.

| | |
|---|---|
| Target | Ubuntu 24.04 LTS (noble), x86_64, **fresh** |
| Disk | ~12 GB free under `/opt` |
| Time | ~1 h on 8 cores (Osmocom core 20–30 min, QEMU 10–15 min) |
| Network | gitea.osmocom.org, github.com, ftp.freecalypso.org, archive.ubuntu.com |

> **Do not run it on a machine that already has a bench installed** (the ISO, a previous native install).
> Every step ends in `make install` into `/usr/local` followed by `ldconfig`: it would overwrite the
> libraries your existing bench uses. Use a disposable container (below) or a fresh VM. Step 0 warns when
> it finds Osmocom already in `/usr/local`.

## Run it in a disposable container (recommended)

The container runs as root, so the notebook needs no sudo. `--privileged` is required by the later steps:
`setcap` (step 2), SCTP for osmo-stp, tun/GTP for the GGSN, `ip_forward`. `--shm-size` keeps
`/dev/shm/calypso_*` from filling Docker's 64 MB default.

On the host:

```bash
docker run -it --name nb-ubuntu --privileged --shm-size=2g -p 8888:8888 ubuntu:24.04 bash
```

In the container:

```bash
apt-get update && apt-get install -y python3-venv git
python3 -m venv /venv && /venv/bin/pip install -q jupyterlab
git clone https://github.com/bbaranoff/osmo-operator /nb
cd /nb && /venv/bin/jupyter lab --ip=0.0.0.0 --allow-root --no-browser \
  --LabApp.default_url=/lab/tree/wiki/installer-osmo-jusquau-dsp.ipynb
```

Open the `http://127.0.0.1:8888/lab/tree/…?token=…` URL it prints: the notebook opens directly. Run the
cells in order with **Shift+Enter** and read each check before moving on.

If SCTP is refused, load the module on the **host**: `sudo modprobe sctp`.

A bare `ubuntu:24.04` container is addressed like a native machine: `network/osmo-ip-plan.sh` adds the
node's private addresses itself (192.168.2.1 and 192.168.2.10, which osmo-ggsn and osmo-sgsn bind to).
Only an image built from this repository (`OSMO_IMAGE=1`, set by the Dockerfile) leaves addressing to
`start-docker.sh` / compose.

### Stop and resume

The container is named and not `--rm`, so a closed terminal or a crashed Jupyter does not lose the build
already done in `/opt/GSM`:

```bash
docker start -ai nb-ubuntu
cd /nb && /venv/bin/jupyter lab --ip=0.0.0.0 --allow-root --no-browser \
  --LabApp.default_url=/lab/tree/wiki/installer-osmo-jusquau-dsp.ipynb
```

Cells are idempotent: re-run the one you stopped at. When you are done: `docker rm nb-ubuntu`.

### Testing local changes

Step 1 clones osmo-operator from GitHub, so the notebook always installs the **pushed** version. To test
an edited notebook before pushing, mount your clone instead of cloning it:

```bash
cd /path/to/osmo-operator
docker run -it --name nb-ubuntu --privileged --shm-size=2g -p 8888:8888 \
  -v "$PWD/wiki:/nb" ubuntu:24.04 bash
# then, in the container, the same commands without the git clone, and
#   --LabApp.default_url=/lab/tree/installer-osmo-jusquau-dsp.ipynb
```

The notebook file is then edited in place on the host, but the patches, configs and scripts it uses still
come from GitHub.

## Run it on a fresh Ubuntu 24.04

Follow the *Before opening the notebook* cell: Jupyter in a venv (Ubuntu 24.04 refuses `pip install`
outside one), and sudo unlocked **in the terminal that starts Jupyter**, because a notebook cannot answer a
password prompt:

```bash
sudo apt-get install -y python3-venv git
python3 -m venv ~/.venv-jupyter && ~/.venv-jupyter/bin/pip install jupyterlab
sudo -v
~/.venv-jupyter/bin/jupyter lab
```

`sudo -v` only lasts 15 minutes without a sudo call, and the QEMU build alone can run longer. For a full
run, prefer a temporary `NOPASSWD` rule (`sudo visudo -f /etc/sudoers.d/osmo-nb`) and remove it afterwards.

## Run it unattended and keep the outputs

To execute every cell without the browser and save the result with all its outputs:

```bash
/venv/bin/jupyter nbconvert --to notebook --execute \
  --ExecutePreprocessor.timeout=-1 --output executed.ipynb installer-osmo-jusquau-dsp.ipynb
/venv/bin/jupyter nbconvert --to html executed.ipynb     # readable in any browser
```

It prints nothing while it runs and stops at the first failing cell with a `CellExecutionError` showing
that cell and its error.

## The steps

| Step | What it does | Needed for the DSP call |
|---|---|---|
| 0 | `/opt/GSM`, the shared environment file, sudo check | yes |
| 1 | clone osmo-operator, apt dependencies and the `osmocom` account through `install.sh` | yes |
| 1b | GNU Radio build dependencies | no (gr-gsm chain only) |
| 2 | capture capabilities for `dumpcap` | yes |
| 3 | the Osmocom core, same versions and options as the Dockerfile, with the force-rand-toy patches | yes |
| 4 | osmo-gapk, before osmocom-bb | yes |
| 5 | the SMSC (gsup-smsc-proto, sms-coding-utils) | for SMS |
| 6 | osmocom-bb host tools: osmocon, mobile, trxcon | yes |
| 7 | prebuilt Calypso firmware | yes |
| 7b | the transceiver tree, `trx` firmware and host `transceiver` (`./start.sh --bts`) | no |
| 8 | qosmo, the Calypso QEMU | yes |
| 9 | c54x_exe and the DSP ROM from FreeCalypso | yes |
| 9b | FreeCalypso Magnetite for the C139 (TMS470 under Wine), its flash image, rvinterf (`--ms-magnetite`) | no |
| 10 | grgsm_exe | no |
| 11 | runtime setup: configs, run-time scripts, directories | yes |
| 11b | audio sinks | only to hear the call |
| 12 | start the network, the BTS, then the DSP bench: `./start.sh --bts-classique --ms`, or the Magnetite / `--bts` variants | yes |
| 13 | camp, location update, call to 600 (echo test) | yes |
| 14 | full test ladder from [bbaranoff/tests](https://github.com/bbaranoff/tests) | no |
| 15 | stop | — |

The launcher is `./start.sh` since 2026-10-21; `start-native.sh` is a symlink to it and still works.

To start the bench **process by process** instead of through `start.sh`, run the companion
notebook [lancer-pas-a-pas.ipynb](lancer-pas-a-pas.ipynb) once the install is done: it installs nothing,
starts the network daemons one by one, then the emulated phone (DSP, QEMU, osmocon, mobile, bridge), and
checks each one before the next, with optional sections on the `--bts` variant (12b), the classic BTS
seen from the bridge (12a) and the rssi application (`banc-rssi`, last section). The same steps as a page:
[Lancer-a-la-main](Lancer-a-la-main.md).

## Troubleshooting

**A cell hangs with no output.** It is probably waiting for a sudo password it can never receive. Interrupt
the kernel, run `sudo -v` (or add the `NOPASSWD` rule) in the terminal that started Jupyter, and re-run the
cell.

**`configure: error: Package requirements (…) were not met`.** A `-dev` package is missing (for example
`sqlite3` → `libsqlite3-dev` for osmo-hlr). Install it, then re-run the cell. On a fresh system this means
the apt list of step 1 is incomplete: please open an issue.

**Step 11b prints "no audio server reachable".** Expected in a container or on a server. The core, camp,
location update, SMS and call set-up do not need audio.

**Binder or Colab.** They can display the notebook but cannot run it to the end: Binder gives no root and
about 2 GB of RAM, Colab runs Ubuntu 22.04 without `--privileged` or SCTP.
