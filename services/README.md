# `services/` — systemd units

The project's units. They are installed by the `Dockerfile` (image), by
`build-iso.sh` (bootable media) and by `addition.sh`; the native install
(`install.sh`) does not enable them. `80-osmo-operator.preset` disables them
all at boot: a freshly installed machine boots to its desktop, and the
operator starts the bench (desktop icon, `launch.sh`, or `systemctl`).

| Unit | Role |
|---|---|
| `osmo-banc.service` | the standalone GSM bench (`start.sh`); stack in the tmux session `calypso` |
| `osmo-multi.service` | the multi-operator bench (`launch/start-multi.sh`: native + containers + inter-STP); `After=osmo-banc`, docker required |
| `osmo-lte.service` | the bench's 4G (Open5GS + srsENB + srsUE over ZeroMQ, `tools/osmo-lte.sh start`) |
| `osmo-egprs-dsp.service` | the EGPRS workflow (`scripts/egprs-dsp.sh start`): virtual EGPRS cell + `osmo-pcu` + osmocom-bb GPRS modem on top of the DSP bench; `Requires=osmo-banc` |
| `osmo-dsp-rom-max.service` | on demand: the "ROM does the maximum" workflow (`scripts/dsp-rom-max.sh run`) |
| `osmo-bts-trx.service` | base station, TRX transceiver (`/etc/osmocom/osmo-bts-trx.cfg`) |
| `osmo-egprs-web.service` | web operations console (dashboard, port 8080) |
| `osmo-egprs-web-install.service` | installs/refreshes the dashboard runtime, unit and TLS certificate (`/opt/GSM/osmo-egprs-web/install-web-service.sh`) |
| `osmo-reglages.service` | settings web page for the Osmocom stack (`tools/osmo-reglages.py`, http://127.0.0.1:8090/) |
| `osmo-supplements.service` | first boot: installs the supplements chosen in the installer (`tools/osmo-supplements-firstboot.sh`) |
| `open5gs-webui.service` | Open5GS WebUI, 4G subscriber console (port 9999, MongoDB) |
| `80-osmo-operator.preset` | systemd preset: all project units disabled at boot |

The units under `contrib/systemd/` belong to upstream QEMU and are not part of
this directory.

## Starting the bench

```bash
systemctl start osmo-banc         # one session
systemctl enable --now osmo-banc  # and at every boot
```

To build an image that enables them anyway: `./build-iso.sh --banc --multi`
(or `OSMO_ISO_BANC=1 OSMO_ISO_MULTI=1`); on an already installed machine,
`OSMO_MULTI_ENABLE=1 ./addition.sh`.

Taking over a bench started as a service:

```bash
tmux attach -t calypso            # Ctrl-b d detaches, the bench keeps running
journalctl -u osmo-banc -f        # output of start.sh / run.sh
systemctl restart osmo-banc       # a fresh bench; launch.sh (icon) does the same then attaches
systemctl start osmo-multi        # adds the containers + inter-STP (docker required)
```

Persistent options: `OSMO_BANC_ARGS` in `/etc/default/osmo-banc`
(`OSMO_MULTI_ARGS` in `/etc/default/osmo-multi`, `DSP_ROM_MAX_ARGS` in
`/etc/default/osmo-dsp-rom-max`). The DSP bench is the default;
`OSMO_BANC_ARGS="--grgsm"` selects the gr-gsm layer 1. `launch.sh --dsp` sets
them for the session via `systemctl set-environment`. With the DSP bench,
osmo-banc also runs `c54x_exe/run.sh` after the fork's plan (hand-off by
`exec`); `systemctl stop` / `./start-native.sh --stop` stop the DSP bench as
well.

Installing a unit by hand:

```bash
sudo cp services/osmo-bts-trx.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now osmo-bts-trx
```

## `osmo-egprs-dsp` — the EGPRS workflow

`scripts/egprs-dsp.sh` brings packet data up on the bench step by step:
preflight (TI ROM 7/7, `c54x_exe`, `modem`), GPRS configs in `/etc/osmocom`
(`configs/gprs/`, BTS 2 re-inserted into `osmo-bsc.cfg` after each `--regen`),
`osmo-banc` (DSP chain), the modem's subscriber in the HLR, the virtual EGPRS
cell (`osmo-bts-virtual` + `osmo-pcu` on `/tmp/pcu_bts3`), then the modem
(`virtphy` + `modem`): GPRS attach, PDP context, ping to `apn0` from the
`msgprs` netns. The daemons are transient units (`systemd-run`):
`osmo-bts-virtual-gprs`, `osmo-pcu-gprs`, `osmo-virtphy-gprs`,
`osmo-modem-gprs`.

```bash
systemctl enable --now osmo-egprs-dsp     # at boot, after osmo-banc
scripts/egprs-dsp.sh check                # preflight + configs, launches nothing
scripts/egprs-dsp.sh status               # units, SGSN mm-context and pdp-context, PCU TBFs
scripts/egprs-dsp.sh stop [--all]         # the cell and the modem (--all: the bench too)
scripts/egprs-dsp.sh start --l1 auto|virtphy|dsp [--no-banc] [--regen-gprs]
journalctl -u osmo-egprs-dsp -u osmo-modem-gprs -u osmo-pcu-gprs -f
```

Known limitation: the standard Calypso `layer1` firmware does not handle
`L1CTL_GPRS_*` (no PDCH on the emulated ARM), so the script puts the modem on
`virtphy`, in the same PLMN/LAC/RA as the DSP mobile camped on BTS 0.
`EGPRS_L1=dsp` (or `--l1 dsp`) prepares the other path (`modem` instead of
`mobile` in `c54x_exe/run.sh` through `MOBILE=`/`MOBILE_CFG=` in
`/etc/default/osmo-banc`) for a firmware with PDCH support
(`layer1.highram.gprs.elf`, built by `sudo ./addition.sh --calypso-fw`). The
Calypso ROM only modulates GMSK: GPRS CS-1..4 at best on the C54x, 8-PSK stays
with the virtual modem.

## `osmo-dsp-rom-max` — the ROM does the maximum

`scripts/dsp-rom-max.sh run` writes the "ROM max" profile into
`/etc/default/osmo-banc` (RACH, uplink SDCCH/SACCH and final bursts by the ROM,
downlink A5 by the ROM, nothing canned), restarts `osmo-banc` on the DSP
bench, runs the ladder of `/opt/GSM/tests/banc-max.sh --dsp --continue` (LU,
SMS, call, coverage) and reads back `couverture.txt`: what the ROM did, what
stayed on the host despite the profile, and what has no ROM path yet (uplink
FACCH and SACCH-in-TCH, uplink speech, uplink A5 at the air fn, vocoding).
`--fw-gprs` (default) uses the `layer1.highram.gprs.elf` firmware (PDCH,
`L1CTL_GPRS_*`); the original firmware is used when it is absent.
The unit is installed but not enabled: the profile persists, the campaign is
launched on demand.

```bash
systemctl start osmo-dsp-rom-max          # or: scripts/dsp-rom-max.sh run
scripts/dsp-rom-max.sh report             # read the last report
scripts/dsp-rom-max.sh profile            # write the profile only
scripts/dsp-rom-max.sh run --no-restart --only=camp,attache,couverture
```
