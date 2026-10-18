# Launching the emulated phone by hand, process by process

> Version of 2026-10-03. Back: [Telephone-emule](Telephone-emule.md). Runnable version, network included:
> [lancer-pas-a-pas.ipynb](lancer-pas-a-pas.ipynb).
>
> Each command is the one **built** by `c54x_exe/run.sh` (DSP setup, called by
> `osmo-operator/start-native.sh`), with variables **expanded** to the values `start-native.sh`
> sets in DSP mode. Line numbers cited are as of 2026-10-03. Based on `c54x_exe/LAUNCH.md`.

Convention: one terminal per process (or `&` + redirection as below). Logs go to
`/tmp/c54x-pont/`, like `run.sh` (`run.sh:42`).

```bash
mkdir -p /tmp/c54x-pont
```

## Common variables (DSP setup)

`start-native.sh` exports them before handing over to `c54x_exe/run.sh` (block « LE BANC DSP :
RÉGLAGES MESURÉS, PUIS PASSAGE DE MAIN », i.e. "DSP bench: measured settings, then hand-over");
`run.sh:57` derives `CALYPSO_PONT_LOCKSTEP=1` from them. They are inherited by **all** the
following processes:

```bash
export CALYPSO_BSP_STREAM=1        # one TS0 burst per frame, in FN order
export CALYPSO_RHEA_DMA_XFER=1     # without it: no SB, no BCCH, no SI
export CALYPSO_PONT_LOCKSTEP=1     # QEMU only advances the frame once the DSP is done (run.sh:50-57)
```

---

## Step 0 — your network (assumed installed)

The phone launches none of it. Bench order: STP, HLR, MGW, MSC, BSC (`qosmo/run_modules/10…14`),
then the BTS (`60-bts.sh`). With systemd, as `c54x_exe/run_real.sh` does:

```bash
for u in osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc; do systemctl is-active --quiet "$u" || systemctl start "$u"; done
systemctl restart osmo-bts-trx
```

Without systemd, start the BTS as `qosmo/run_modules/60-bts.sh:49` does:

```bash
osmo-bts-trx -c /etc/osmocom/osmo-bts-trx.cfg
```

**Move on when**: the BTS VTY answers (`telnet 127.0.0.1 4241`, osmo-bts default VTY port —
**TO BE CONFIRMED** for your config) and the BSC has accepted OML (`show bts 0` on the BSC VTY,
4242). The BTS is already sending its TRXC commands to 5701; nobody answers yet, which is
normal: the bridge (step 5) will receive them.

Check: `ss -ulnp | grep -E ':580[0-2]'` → osmo-bts-trx on 5800-5802 (osmo-bts-trx default;
`pont/trx.py:184` sends the clock back there).

---

## Step 1 — `c54x_exe --arm` (the DSP)

Clean up first (`run.sh:96-99`):

```bash
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /dev/shm/calypso_tch_cfg
```

Command (`run.sh:102`, with `INSNS=120000` from start-native.sh, `IQ=none`, `AMP=30000`, `VERB=-v`):

```bash
cd /opt/GSM/c54x_exe
CALYPSO_IQDUMP_FCCH=1 CALYPSO_BSP_ATTENTE_MS=40 \
  ./c54x_exe --arm --insns 120000 --iq none --amp 30000 -v > /tmp/c54x-pont/dsp.log 2>&1 &
echo $! > /tmp/c54x-pont/dsp.pid
```

- Publishes `/dev/shm/calypso_api_ram` and `/tmp/calypso_dsp.sock`; listens on **UDP 6702** (BSP) (`LAUNCH.md:42-45`).
- ROM read from `/opt/GSM` (`--rom-dir`, `src/main.c:105`).

**Move on when** (`run.sh:104`, 5 s wait):

```bash
test -S /tmp/calypso_dsp.sock && grep -a "en attente de l'ARM" /tmp/c54x-pont/dsp.log
# pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)
ss -ulnp | grep 6702
```

("en attente de l'ARM" = "waiting for the ARM".)

---

## Step 2 — QEMU / qosmo (the ARM + osmocom-bb layer1)

Command (`run.sh:121-136`, `GDB=1`, `GDB_STUB=1234`, `MONITOR=/tmp/qemu-monitor-pont.sock`):

```bash
rm -f /tmp/qemu-monitor-pont.sock
CALYPSO_PONT_RETRY_DIV=64 CALYPSO_DSP_EXTERN=1 \
  /opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 -display none -parallel none \
    -serial pty -serial pty -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
    -gdb tcp:127.0.0.1:1234 \
    -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/qemu.log 2>&1 &
echo $! > /tmp/c54x-pont/qemu.pid
```

Optional gdb console (`run.sh:138-142`) — the default path in `run.sh:48` is dead, use qosmo's:

```bash
python3 /opt/GSM/qosmo/tools/gdb-telnet.py --port 44444 --stub 1234 \
  --elf /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/gdb.log 2>&1 &
```

**Move on when** (`run.sh:143-145`, 10 s wait):

```bash
grep -a "label serial0" /tmp/c54x-pont/qemu.log          # char device redirected to /dev/pts/N (label serial0)
grep -a "pont DSP : API RAM partagee" /tmp/c54x-pont/qemu.log
```

("API RAM partagee" = "shared API RAM".) Then extract the modem pty (`run.sh:149`):

```bash
sed -n 's/.*redirected to \(\/dev\/pts\/[0-9]*\) (label serial0).*/\1/p' /tmp/c54x-pont/qemu.log | head -1 > /tmp/c54x-pont/modem.pty
cat /tmp/c54x-pont/modem.pty
```

On the DSP side you should see `RESET #1 ... pc=0xff80` then `DSP boote (premier IDLE)` ("DSP
booted (first IDLE)") (`LAUNCH.md:97`, `src/pont.c:1608,1921`); they may only show up once the
firmware is loaded (step 3) — exact timing **TO BE CONFIRMED**. Other expected QEMU lines
(`LAUNCH.md:89-96`):
`[trx] pont DSP : RESET_DSP relache par le firmware -> PONT_RESET`,
`[trx] pont DSP : le TDMA du firmware prend le relais du timer de boot`.

Check the machine: `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock` → `VM status: running`.

---

## Step 3 — `osmocon` (romload + L1CTL relay)

Command (`run.sh:161-164`):

```bash
rm -f /tmp/osmocom_l2
stdbuf -oL -eL /opt/GSM/osmocom-bb/src/host/osmocon/osmocon -m romload -i 100 \
  -p "$(cat /tmp/c54x-pont/modem.pty)" -s /tmp/osmocom_l2 \
  /opt/GSM/firmware/board/compal_e88/layer1.highram.bin > /tmp/c54x-pont/osmocon.log 2>&1 &
echo $! > /tmp/c54x-pont/osmocon.pid
```

**Move on when** (`run.sh:165`, 30 s wait; `LAUNCH.md:118-119`):

```bash
grep -a "your code is running now" /tmp/c54x-pont/osmocon.log
# Received ident ack / Progress: 100% / Received branch ack, your code is running now!
test -S /tmp/osmocom_l2
```

The firmware's last printf can also be read from the monitor (`LAUNCH.md:98-99`):
`printf 'xp /96bx 0x008305f0\n' | nc -U /tmp/qemu-monitor-pont.sock` → `DSP API Version: 0x4e2a 0x491a`.

---

## Step 4 — `mobile` (layers 2/3)

Command (`run.sh:177-191`, `L23_SYNC_RETRIES_SELECTION=8` in DSP mode):

```bash
ss -ltn | grep -q ':4347 ' && echo "VTY 4347 deja prise"      # run.sh:178-181
L23_SYNC_RETRIES_SELECTION=8 stdbuf -oL mobile -c /opt/GSM/c54x_exe/mobile_pont.cfg \
  > /tmp/c54x-pont/mobile.log 2>&1 &
echo $! > /tmp/c54x-pont/mobile.pid
```

**Move on when**: the process is still alive after 2 s (`run.sh:192-193`); within 5 s, on the
osmocon side: `L1CTL_PM_REQ`, `L1CTL_RESET_REQ: FULL!`, `L1CTL_FBSB_REQ (arfcn=514 …)` (`LAUNCH.md:135-137`).
Without the bridge: `FBSB RESP: result=255` in a loop, expected (`LAUNCH.md:138`).

Check: `telnet 127.0.0.1 4347` then `show ms`.

---

## Step 5 — `pont_dsp.py` (BTS ↔ DSP)

Command (`run.sh:200-206`: the bridge is started from the osmo-operator root, with
`--dsp-port 6702`, **without** `--no-record` since `PONT_AIRREC=1`):

```bash
cd /opt/GSM/osmo-operator
PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg PONT_ARFCN=514 PONT_BSIC=7 \
  python3 pont/pont_dsp.py --dsp-port 6702 > /tmp/c54x-pont/pont.log 2>&1 &
echo $! > /tmp/c54x-pont/pont.pid
```

`PONT_BSC_CFG`, `PONT_ARFCN`, `PONT_BSIC` are at their defaults here (`pont/config.py:46-52`);
adapt them to **your** cell. I/Q recording writes to `/root/record.cfile` by default
(`config.py:81`): add `--no-record` if you don't want it.

**Move on when** (`run.sh:206`, 10 s wait):

```bash
grep -a "pont TRX : ports" /tmp/c54x-pont/pont.log
# pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7, avance UL 3 trames
grep -a "horloge armee" /tmp/c54x-pont/pont.log     # BTS 127.0.0.1 : horloge armee vers le port 5800
grep -a "CTRL " /tmp/c54x-pont/pont.log | head      # TRXC commands from the BTS (POWERON, RXTUNE…)
```

("horloge armee" = "clock armed"), then `STATS fn=… | DL bursts=N` lines with N growing (`LAUNCH.md:157-158`).

> **Noise (optional)**: to degrade the downlink, start `c54x_exe` with `CALYPSO_BSP_PORT=16702`
> and `python3 /opt/GSM/qosmo/tools/injecteur_bruit.py --cible dsp --mode ber --ber 0.01` **before** this
> bridge (it takes 6702); `run.sh` does it with `BRUIT_MODE=…` (step b). See [Injecteur-bruit](Injecteur-bruit.md).

---

## Step 6 — check the service

| What | Command | Expected | Source |
|---|---|---|---|
| SI read | `grep -a "New SYSTEM INFORMATION" /tmp/c54x-pont/mobile.log` | SI 1, 2, 3, 4… | `run_real.sh` |
| LAI | `grep -aoE "lai=[0-9]+-[0-9]+-[0-9]+" /tmp/c54x-pont/mobile.log \| tail -1` | `lai=001-01-<your LAC>` | `run_real.sh` |
| RACH sent | `grep -a "\[montant\] RACH" /tmp/c54x-pont/dsp.log` ; `grep -ao 'UL bursts=[0-9]* tard=[0-9]* rach=[0-9]*' /tmp/c54x-pont/pont.log` | `rach` > 0 | `run_real.sh`, `LAUNCH.md:66-67` |
| camp | `show ms` (VTY 4347) | `C3 camped normally` | `tests/modules/60-camp.sh:10` |
| LU | `grep -a "LOCATION UPDATING ACCEPT" mobile.log` ; `show ms` | `MM idle, normal service` ; IMSI in `show subscriber cache` (MSC VTY 4254) | `run_real.sh`, `tests/modules/70-attache.sh:9-10` |
| call | VTY 4347: `enable`, `call 1 600` (600 = the bench echo; otherwise your number) | `call control state: ACTIVE` in `show ms` ; `call 1 hangup` | `tests/modules/_lib.sh:48,83`, `90-appel.sh:15,22` |
| A5/1 | `dsp.log` : `[montant] TCH : le firmware poste la tache 13 …` | | `LAUNCH.md:68-69` |

## Stop and clean up

Reverse order: bridge, mobile, osmocon, gdb, QEMU, DSP, then purge (`run.sh:210-237`):

```bash
for n in pont mobile osmocon gdb qemu dsp; do kill "$(cat /tmp/c54x-pont/$n.pid 2>/dev/null)" 2>/dev/null; done
sleep 1
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /tmp/osmocom_l2 /tmp/qemu-monitor-pont.sock \
      /tmp/c54x-pont/modem.pty /tmp/osmocom_sap /tmp/ms_data /dev/shm/calypso_horloge \
      /dev/shm/calypso_rach /dev/shm/calypso_sdcch_ul /dev/shm/calypso_tch_facch_ul \
      /dev/shm/calypso_tch_sacch_ul /dev/shm/calypso_tch_ul /dev/shm/calypso_tch_cfg
```

Why each file matters: a leftover `/tmp/ms_data` makes the next mobile's bind fail silently; a
leftover `calypso_horloge` slaves the bridge to a dead session (`run.sh:218-227`).

---

## Variant: gr-gsm setup, by hand

Same steps **without step 1** and without the three `export`s at the top (`run.sh:92-93,113`):

- **Step 2**: the same QEMU command **without** `CALYPSO_DSP_EXTERN=1` or `CALYPSO_PONT_*`;
  wait for `backend gr-gsm` in qemu.log (`run.sh:146-147`):
  `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731`. QEMU then listens on UDP 4730/4731.
- **Step 3**: identical.
- **Step 4**: `mobile -c <cfg>` **without** `L23_SYNC_RETRIES_SELECTION` (`run.sh:186-189`); config with
  `io-tch-format rtp` (see [Installer-grgsm_exe](Installer-grgsm_exe.md), **TO BE CONFIRMED**).
- **Step 5**: `cd /opt/GSM/osmo-operator && python3 pont/pont.py > /tmp/c54x-pont/pont.log 2>&1 &`
  (`run.sh:37-38,201-204`; rejects `--dsp-port`, `pont.py:25-26`). In the full bench,
  `start-native.sh` waits until osmo-bts-trx is (re)seen, then runs `setsid python3 -u pont/pont.py`
  to `/dev/shm/pont.log`.
- Expected on the bridge side: `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7`, then
  `STATS fn=… | DL bursts=N`.

## Mapping to the scripts

| Step | `c54x_exe/run.sh` | `qosmo/run_modules` (gr-gsm setup via start-native.sh) |
|---|---|---|
| DSP | `etape1` `:92-106` | — |
| QEMU | `etape2` `:108-153` | `40-qemu.sh:44-89` (via the `/usr/local/bin/qosmo` launcher if present) |
| osmocon | `etape3` `:155-170` | `50-osmocon.sh:36-42` (plus `-d tr`) |
| mobile | `etape4` `:172-195` | `70-l2.sh:65` (`mobile -c $cfg -d $CALYPSO_MOBILE_DEBUG`) |
| pont | `etape5` `:197-208` | `start-native.sh` block `CALYPSO_BRIDGE=pont` |
| BTS | — (your network) | `60-bts.sh:49` |

In DSP mode, `start-native.sh` plays qosmo's plan **without** `qemu,pty,osmocon,l2`
(`DSP_MODULES_RETIRES`, `start-native.sh:602`) then `exec`s `c54x_exe/run.sh`: that is exactly
step 0 (qosmo's plan brings up the network and the BTS) followed by steps 1 to 5.
