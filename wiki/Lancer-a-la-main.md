# Launching the emulated phone by hand, process by process

Back: [Telephone-emule](Telephone-emule.md). Runnable version, network included:
[lancer-pas-a-pas.ipynb](lancer-pas-a-pas.ipynb).

Each command below is the one **built** by `c54x_exe/run.sh` (DSP setup, called by
`osmo-operator/start.sh`), with the variables **expanded** to the values `start.sh` sets in DSP
mode. The function names (`etape1` to `etape5`) are those of `run.sh`; details and expected
lines are in `c54x_exe/LAUNCH.md`.

Convention: one terminal per process (or `&` + redirection as below). Logs go to
`/tmp/c54x-pont/`, like `run.sh`.

```bash
mkdir -p /tmp/c54x-pont
```

## Common variables (DSP setup)

`start.sh` exports them before handing over to `c54x_exe/run.sh`; `run.sh` derives
`CALYPSO_PONT_LOCKSTEP=1` from `LOCKSTEP=1` (its default). They are inherited by **all** the
following processes:

```bash
export CALYPSO_BSP_STREAM=1        # one TS0 burst per frame, in FN order
export CALYPSO_RHEA_DMA_XFER=1     # without it: no SB, no BCCH, no SI
export CALYPSO_PONT_LOCKSTEP=1     # QEMU only advances the frame once the DSP is done
```

---

## Step 0: the network (assumed installed)

The phone launches none of it. Bench order: STP, HLR, MGW, MSC, BSC (`qosmo/run_modules/10...14`),
then the BTS (`60-bts.sh`). With systemd, as `c54x_exe/run_real.sh` does:

```bash
for u in osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc; do systemctl is-active --quiet "$u" || systemctl start "$u"; done
systemctl restart osmo-bts-trx
```

Without systemd, start the BTS as `qosmo/run_modules/60-bts.sh` does:

```bash
osmo-bts-trx -c /etc/osmocom/osmo-bts-trx.cfg
```

**Move on when**: the BTS VTY answers (`telnet 127.0.0.1 4241`, the osmo-bts default VTY port;
check your config) and the BSC has accepted OML (`show bts 0` on the BSC VTY, 4242). The BTS is
already sending its TRXC commands to 5701; nobody answers yet, which is normal: the bridge
(step 5) will receive them.

Check: `ss -ulnp | grep -E ':580[0-2]'` shows osmo-bts-trx on 5800-5802 (osmo-bts-trx default;
`pont/trx.py` sends the clock back there).

---

## Step 1: `c54x_exe --arm` (the DSP), `etape1`

Clean up first:

```bash
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /dev/shm/calypso_tch_cfg
```

Command (`INSNS=120000`, `IQ=none`, `AMP=30000`, `VERB=-v`):

```bash
cd /opt/GSM/c54x_exe
CALYPSO_IQDUMP_FCCH=1 CALYPSO_BSP_ATTENTE_MS=40 \
  ./c54x_exe --arm --insns 120000 --iq none --amp 30000 -v > /tmp/c54x-pont/dsp.log 2>&1 &
echo $! > /tmp/c54x-pont/dsp.pid
```

- Publishes `/dev/shm/calypso_api_ram` and `/tmp/calypso_dsp.sock`; listens on **UDP 6702** (BSP).
- ROM read from `/opt/GSM` (`--rom-dir` default).

**Move on when** (`run.sh` waits 5 s):

```bash
test -S /tmp/calypso_dsp.sock && grep -a "en attente de l'ARM" /tmp/c54x-pont/dsp.log
# pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)
ss -ulnp | grep 6702
```

("en attente de l'ARM" = waiting for the ARM.)

---

## Step 2: QEMU / qosmo (the ARM + osmocom-bb layer1), `etape2`

Command (`GDB=1`, `GDB_STUB=1234`, `MONITOR=/tmp/qemu-monitor-pont.sock`):

```bash
rm -f /tmp/qemu-monitor-pont.sock
CALYPSO_PONT_RETRY_DIV=64 CALYPSO_DSP_EXTERN=1 \
  /opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 -display none -parallel none \
    -serial pty -serial pty -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
    -gdb tcp:127.0.0.1:1234 \
    -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/qemu.log 2>&1 &
echo $! > /tmp/c54x-pont/qemu.pid
```

Optional gdb telnet console (`run.sh` starts it when `GDB=1`):

```bash
python3 /opt/GSM/qosmo/tools/gdb-telnet.py --port 44444 --stub 1234 \
  --elf /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/gdb.log 2>&1 &
```

**Move on when** (`run.sh` waits 10 s):

```bash
grep -a "label serial0" /tmp/c54x-pont/qemu.log          # char device redirected to /dev/pts/N (label serial0)
grep -a "pont DSP : API RAM partagee" /tmp/c54x-pont/qemu.log
```

("API RAM partagee" = shared API RAM.) Then extract the modem pty:

```bash
sed -n 's/.*redirected to \(\/dev\/pts\/[0-9]*\) (label serial0).*/\1/p' /tmp/c54x-pont/qemu.log | head -1 > /tmp/c54x-pont/modem.pty
cat /tmp/c54x-pont/modem.pty
```

On the DSP side, `RESET #1 ... pc=0xff80` then `DSP boote (premier IDLE)` (DSP booted, first
IDLE) show up once the firmware is loaded (step 3). Other expected QEMU lines:
`[trx] pont DSP : RESET_DSP relache par le firmware -> PONT_RESET`,
`[trx] pont DSP : le TDMA du firmware prend le relais du timer de boot`.

Check the machine: `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock`
answers `VM status: running`.

---

## Step 3: `osmocon` (romload + L1CTL relay), `etape3`

```bash
rm -f /tmp/osmocom_l2
stdbuf -oL -eL /opt/GSM/osmocom-bb/src/host/osmocon/osmocon -m romload -i 100 \
  -p "$(cat /tmp/c54x-pont/modem.pty)" -s /tmp/osmocom_l2 \
  /opt/GSM/firmware/board/compal_e88/layer1.highram.bin > /tmp/c54x-pont/osmocon.log 2>&1 &
echo $! > /tmp/c54x-pont/osmocon.pid
```

**Move on when** (`run.sh` waits 30 s):

```bash
grep -a "your code is running now" /tmp/c54x-pont/osmocon.log
# Received ident ack / Progress: 100% / Received branch ack, your code is running now!
test -S /tmp/osmocom_l2
```

The firmware's last printf can also be read from the monitor:
`printf 'xp /96bx 0x008305f0\n' | nc -U /tmp/qemu-monitor-pont.sock` shows
`DSP API Version: 0x4e2a 0x491a`.

---

## Step 4: `mobile` (layers 2/3), `etape4`

Command (`L23_SYNC_RETRIES_SELECTION=8` in DSP mode):

```bash
ss -ltn | grep -q ':4347 ' && echo "VTY 4347 deja prise"      # already taken
L23_SYNC_RETRIES_SELECTION=8 stdbuf -oL mobile -c /opt/GSM/c54x_exe/mobile_pont.cfg \
  > /tmp/c54x-pont/mobile.log 2>&1 &
echo $! > /tmp/c54x-pont/mobile.pid
```

**Move on when**: the process is still alive after 2 s; within 5 s, on the osmocon side:
`L1CTL_PM_REQ`, `L1CTL_RESET_REQ: FULL!`, `L1CTL_FBSB_REQ (arfcn=514 ...)`. Without the bridge,
`FBSB RESP: result=255` in a loop is expected.

Check: `telnet 127.0.0.1 4347` then `show ms`.

---

## Step 5: `pont_dsp.py` (BTS to DSP), `etape5`

The bridge is started from the osmo-operator root with `--dsp-port 6702`. `run.sh` adds
`--no-record` only when `PONT_AIRREC=0` (I/Q recording is on by default):

```bash
cd /opt/GSM/osmo-operator
PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg PONT_ARFCN=514 PONT_BSIC=7 \
  python3 pont/pont_dsp.py --dsp-port 6702 > /tmp/c54x-pont/pont.log 2>&1 &
echo $! > /tmp/c54x-pont/pont.pid
```

`PONT_BSC_CFG`, `PONT_ARFCN`, `PONT_BSIC` are shown at their defaults (`pont/config.py`): adapt
them to your cell. I/Q recording writes to `/root/record.cfile` by default; add `--no-record`
if you do not want it.

**Move on when** (`run.sh` waits 10 s):

```bash
grep -a "pont TRX : ports" /tmp/c54x-pont/pont.log
# pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7, avance UL 3 trames
grep -a "horloge armee" /tmp/c54x-pont/pont.log     # BTS 127.0.0.1 : horloge armee vers le port 5800
grep -a "CTRL " /tmp/c54x-pont/pont.log | head      # TRXC commands from the BTS (POWERON, RXTUNE...)
```

("horloge armee" = clock armed.) Then `STATS fn=... | DL bursts=N` lines with N growing.

> **Noise (optional)**: to degrade the downlink, start `c54x_exe` with `CALYPSO_BSP_PORT=16702`
> and `python3 /opt/GSM/qosmo/tools/injecteur_bruit.py --cible dsp --mode ber --ber 0.01`
> **before** this bridge (the injector takes 6702); `run.sh` does it with `BRUIT_MODE=...`.

---

## Step 6: check the service

| What | Command | Expected |
|---|---|---|
| SI read | `grep -a "New SYSTEM INFORMATION" /tmp/c54x-pont/mobile.log` | SI 1, 2, 3, 4... |
| LAI | `grep -aoE "lai=[0-9]+-[0-9]+-[0-9]+" /tmp/c54x-pont/mobile.log \| tail -1` | `lai=001-01-<your LAC>` |
| RACH sent | `grep -a "\[montant\] RACH" /tmp/c54x-pont/dsp.log`; `grep -ao 'UL bursts=[0-9]* tard=[0-9]* rach=[0-9]*' /tmp/c54x-pont/pont.log` | `rach` > 0 |
| camp | `show ms` (VTY 4347) | `C3 camped normally` (`tests/modules/60-camp.sh`) |
| LU | `grep -a "LOCATION UPDATING ACCEPT" mobile.log`; `show ms` | `MM idle, normal service`; IMSI in `show subscriber cache` (MSC VTY 4254) |
| call | VTY 4347: `enable`, `call 1 600` (600 = the bench echo; otherwise your number) | `call control state: ACTIVE` in `show ms`; `call 1 hangup` |
| A5/1 | `dsp.log`: `[montant] TCH : le firmware poste la tache 13 ...` | |

## Stop and clean up

Reverse order: bridge, mobile, osmocon, gdb, QEMU, DSP, then purge (what `run.sh --stop` does):

```bash
for n in pont mobile osmocon gdb qemu dsp; do kill "$(cat /tmp/c54x-pont/$n.pid 2>/dev/null)" 2>/dev/null; done
sleep 1
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /tmp/osmocom_l2 /tmp/qemu-monitor-pont.sock \
      /tmp/c54x-pont/modem.pty /tmp/osmocom_sap /tmp/ms_data /dev/shm/calypso_horloge \
      /dev/shm/calypso_rach /dev/shm/calypso_sdcch_ul /dev/shm/calypso_tch_facch_ul \
      /dev/shm/calypso_tch_sacch_ul /dev/shm/calypso_tch_ul /dev/shm/calypso_tch_cfg
```

Why each file matters: a leftover `/tmp/ms_data` makes the next mobile's bind fail silently; a
leftover `calypso_horloge` slaves the bridge to a dead session.

---

## Variant: gr-gsm setup, by hand

Same steps **without step 1** and without the three `export`s at the top:

- **Step 2**: the same QEMU command **without** `CALYPSO_DSP_EXTERN=1` or `CALYPSO_PONT_*`;
  wait for `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731` in qemu.log. QEMU then listens
  on UDP 4730/4731.
- **Step 3**: identical.
- **Step 4**: `mobile -c <cfg>` **without** `L23_SYNC_RETRIES_SELECTION`; config with
  `io-tch-format rtp` (see [Installer-grgsm_exe](Installer-grgsm_exe.md), Known issues).
- **Step 5**: `cd /opt/GSM/osmo-operator && python3 pont/pont.py > /tmp/c54x-pont/pont.log 2>&1 &`
  (`pont.py` rejects `--dsp-port`). In the full bench, `start.sh` waits until osmo-bts-trx is
  (re)seen, then runs `setsid python3 -u pont/pont.py` logging to `/dev/shm/pont.log`.
- Expected on the bridge side: `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7`, then
  `STATS fn=... | DL bursts=N`.

## Mapping to the scripts

| Step | `c54x_exe/run.sh` | `qosmo/run_modules` (gr-gsm setup via `start.sh`) |
|---|---|---|
| DSP | `etape1` | none |
| QEMU | `etape2` | `40-qemu.sh` (via the `/usr/local/bin/qosmo` launcher if present) |
| osmocon | `etape3` | `50-osmocon.sh` (plus `-d tr`) |
| mobile | `etape4` | `70-l2.sh` (`mobile -c $cfg -d $CALYPSO_MOBILE_DEBUG`) |
| bridge | `etape5` | `start.sh`, `CALYPSO_BRIDGE=pont` |
| BTS | none (your network) | `60-bts.sh` |

In DSP mode, `start.sh` plays qosmo's plan **without** `qemu,pty,osmocon,l2`
(`DSP_MODULES_RETIRES`) then `exec`s `c54x_exe/run.sh`: that is exactly step 0 (qosmo's plan
brings up the network and the BTS) followed by steps 1 to 5.
