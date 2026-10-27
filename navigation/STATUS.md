# Known issues

Open limitations of the lab, grouped by area. Fixed items are not listed:
what works is described in `navigation/QUICKSTART.md` (SS7 console),
`pont/README.md` (radio bridge) and the wiki.

## 1. Radio bench (`--dsp`, c54x_exe)

Mounts: grgsm (`--grgsm`, gr-gsm layer 1 inside QEMU) and DSP (`--dsp`, the
default: C54x mask ROM in c54x_exe). On the DSP bench the mobile camps, does its
LU, uses A5/1 on the downlink through the modelled XIO coprocessor, completes
TCH calls (echo 600, mobile to mobile) and MO/MT SMS. Open points, by
importance:

1. **B_BFI set on every speech frame** delivered by the ROM, although the FR
   speech stays intelligible (the firmware does not report the BFI). Signal
   path (BSP, I/Q, equalisation) or C54x core (Viterbi, re-encoding) not
   decided; speech quality not measured. TODO: compare bit by bit the 33 bytes
   delivered by the ROM with the frames sent by the BTS (MGW RTP or bridge
   decoding).
2. **Occasional LOS on a TCH call**: the SACCH of the TCH is lost entirely for
   ~15 s (`LOSS counter for ACCH` down to 0, then "LOS during dedicated
   mode"); the following call is clean. Cause unknown.
3. **Downlink SACCH of the SDCCH/8**: about half of the SACCH blocks are
   discarded by the mobile during an LU. Suspect: the 45.002 table of the BSP
   for SACCH/8 (alternation over two 51-multiframes). TODO: compare `fn % 102`
   of discarded blocks against accepted ones.
4. **UI SAPI 0 on the TCH**: the BSC logs "SAPI=0 UNIT DATA INDICATION:
   unimplemented Abis RLL message" on a fresh TCH lchan. Not located, not
   blocking.
5. **Bridge clock**: the targeted advance occasionally hits the ceiling
   (`PONT_AVANCE_MAX` 40) and the real DL margin can touch 0 right after a
   LOS. No loss associated so far. The "marge DL reelle" line printed every
   10 s in `pont.log` must stay > 0.
6. Minor: `MM_EVENT_NO_CELL_FOUND` after an MO SMS (resynchronisation), MSC
   "Duplicate DTAP" on a paging response.

Not anomalies: CRC failures of the bridge's downlink TCH monitor at the start
and end of a call (the BTS puts nothing on the TCH while RTP does not flow;
bridge decoding, independent of the DSP), and the `ko=` counter of the
`[a_dd]` probe (B_FIRE1, no defined meaning on speech).

## 2. SS7 console (`navigation/`)

- Responder limits: a single operator and a fixed SSN. TODO: several
  operators, choice of the SSN.
- Exported scripts (`navigation/scripts/`) cannot be replayed from the
  diagram yet.
- The M3UA link from the host is only served for a few seconds by the hub;
  the console renews it before each exchange (see QUICKSTART § 8).

## 3. Numbering and multi-node (WAN) configuration

Open findings of the numbering audit (point codes, subscribers, WAN prefixes,
network identifiers):

1. **ARFCN / BSIC / LAC / CI depend only on the operator**, not on the node
   (`generate_configs.sh`: `512 + op_id*2`, `(op_id*7) % 64`, `0x000<op>`):
   two nodes running the same operator number broadcast the same cell
   identity.
2. **`_gc_warn_perop` (`generate_configs.sh`) tests `N_OPERATORS`**, which
   `start-docker.sh` does not set, so the per-operator guard does not fire on
   the container path.
3. **The MGW RTP range (`rtp port-range 4002 16001`, `configs/osmo-mgw.cfg`)
   overlaps every service port** of the container, VTY ports included.
4. **`network/wan-nodes.sh`: `WAN_NOPS[id]` is always set** (default 1), so a
   peer declared without an operator count is always seen as carrying one
   operator.
5. Three divergent fallbacks for MCC/MNC (`start-native.sh`,
   `run_modules/21`, `scripts/sms-routing-setup.sh`).
6. Only two local SMS routes are generated whatever `OP_MS`.
7. No routing by global title: everything is PC/SSN 254.

TODO: index ARFCN / BSIC / LAC / CI by node in `generate_configs.sh`; set
`WAN_NOPS` only when the field exists; stop fixing operator 1 in
`checks/diag-stp-operator.sh`.

## 4. Verification commands

```bash
sudo ./launch/start-docker.sh --wan --operators 2 --hub-ip <hub>   # the lab
./navigation/ss7-diag.py        # expected: 2 distinct PCs and rctx per operator, no DUNA
./navigation/test-console.sh    # lab running: all sections must pass
```
