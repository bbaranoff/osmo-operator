# osmo-operator — using the bench

Day-to-day handling of a running bench: tmux, VTY, numbers, ports, Wireshark.

← [README](../README.md) · Details: [wiki/Home](../wiki/Home.md), [wiki/Start-direct](../wiki/Start-direct.md), [README-architecture](README-architecture.md)

## tmux

```bash
tmux -S /tmp/osmocom_tmux attach -t osmocom                       # native / ISO
docker exec -ti osmo-operator-1 tmux -S /tmp/osmocom_tmux attach -t osmocom   # Docker
```

| key | window |
|---|---|
| `Ctrl-b 0` | faketrx |
| `Ctrl-b 1` | MS1 (trxcon + mobile) |
| `Ctrl-b 2` | Asterisk |
| `Ctrl-b 3` | SMSC (proto-smsc-daemon + relay) |
| `Ctrl-b w` | list all windows |
| `Ctrl-b d` | detach |

## VTY

| port | component |
|---|---|
| `4239` | OsmoSTP |
| `4241` | OsmoBTS |
| `4242` | OsmoBSC |
| `4243` | OsmoMGW |
| `4254` | OsmoMSC |
| `4258` | OsmoHLR |
| `4247` / `4347` | osmocom-bb mobile (gr-gsm / DSP) |

```
OsmoMSC# show subscriber all
OsmoMSC# subscriber msisdn 100101 sms sender msisdn 100102 send Hello

OsmoHLR# subscriber imsi 001010001000001 show
OsmoHLR# show gsup-clients
```

Subscribers are provisioned automatically at start-up by
`run_modules/21-abonnes-hlr.sh`, following the numbering plan. `--regen`
re-applies it.

## Numbers

| number | use |
|---|---|
| `<node>00<op><ms>` (e.g. `100101`) | GSM subscribers |
| `600` | echo test |
| `*#100#` / `*#101#` | USSD: own MSISDN / own IMSI |
| `<prefix><number>` (e.g. `2220011`) | a subscriber on another WAN node ([README-ss7](README-ss7.md)) |

## Ports on the wire

| port | carries |
|---|---|
| `2905` SCTP | M3UA, local STP |
| `2908` SCTP | M3UA, inter-STP |
| `2427` UDP | MGCP (MGW) |
| `5060` UDP | SIP (Asterisk) |
| `2775` TCP | SMPP |
| `7890` TCP | inter-operator SMS relay |
| `5700-5702` UDP | TRXD, between `osmo-bts-trx` and the bridge |
| `4729` UDP | GSMTAP, the Um interface |
| `4730` UDP | full SI set into the shunt (`si_bridge.py`) |
| `4731` UDP | SCH BSIC/FN out of the gr-gsm receiver |
| `6702` UDP | DL bursts into the DSP BSP (`--dsp`) |
| `8080` TCP | the web dashboard (`osmo-egprs-web`) |

## Wireshark

Started automatically with `sctp or udp port 4729`. Useful filters:

```
gsmtap                    # radio traffic (Um)
gsm_a.dtap                # MM / CC / SMS layer 3
gsm_map                   # MAP
m3ua / sccp               # SS7, multi-operator
```

A tcpdump wrapper is installed for GSMTAP (`udp/4729`) and M3UA captures.
`tools/osmo-wireshark-root.sh` opens Wireshark with capture rights.

## Sending things by hand

```bash
scripts/send-mt-sms.sh                  # an MT SMS to a mobile
tools/at-cmd.py                         # AT commands to the emulated phone's modem
```

## Dashboard

`osmo-egprs-web` on `:8080` (`systemctl restart osmo-egprs-web`). The desktop
also runs a conky status panel (`tools/conky-osmo-status.sh`).
