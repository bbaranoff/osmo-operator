# `pont/` — the TRX bridge between osmo-bts and the emulated Calypso

`pont` is a Python package that sits between `osmo-bts-trx` (TRXD/TRXC on UDP)
and the emulated phone's layer 1. It decodes the downlink bursts, applies or
undoes A5 ciphering, feeds the layer 1, and encodes and sends the uplink
bursts back to the BTS at the right frame number. It also records I/Q for the
spectrum panel and publishes GSMTAP for Wireshark.

## Entry points

| Entry point | Mount | Defaults set before the import |
|---|---|---|
| `pont.py` | grgsm (gr-gsm layer 1 inside QEMU, GSMTAP 4730/4731) | `PONT_UL_RETARD_MAX=0`; refuses `--dsp-port` |
| `pont_dsp.py` (`pont.dsp.main`) | DSP (`c54x_exe --arm`); `--dsp-port 6702` (or `PONT_DSP_PORT`) mandatory | `PONT_UL_RETARD_MAX=26`, `PONT_KC_RETENTION=1`, `PONT_DSP_COPIES=6762` |

`pont_dsp.py` is launched by `c54x_exe/run.sh` (`PONT_PY`), hence by
`start-native.sh` on the DSP bench (the default). A variable set by the
operator always wins over these defaults (`setdefault`).

With `BRUIT_MODE=ber` or `relais`, `pont.py` targets `BRUIT_PORT_GRGSM`
(14730) instead of 4730 so that `qosmo/tools/injecteur_bruit.py` can sit in
between.

## Command line (`pont/config.py`)

| Option | Env var | Default | Role |
|---|---|---|---|
| `--arfcn` | `PONT_ARFCN` | 514 | |
| `--bsic` | `PONT_BSIC` | 7 | |
| `--trx-bind` | `PONT_TRX_BIND` | 127.0.0.1 | TRX side bind address |
| `--trx-base` | `PONT_TRX_BASE` | 5700 | TRX base port |
| `--dsp-port` | `PONT_DSP_PORT` | 0 | UDP port of the C54x BSP (6702); 0 = off |
| `--bsc-cfg` | `PONT_BSC_CFG` | `/etc/osmocom/osmo-bsc.cfg` | timeslot plan read from the BSC config |
| `--no-tap` | `PONT_TAP=0` | tap on | GSMTAP output (`PONT_TAP_PORT`, 4729) |
| `--no-record` | `PONT_AIRREC=0` | record on | I/Q recording (and the panel's FFT) |

## Package layout

| Module | Role |
|---|---|
| `__init__.py` | `main()` of the grgsm mount: threads, signals, reporter |
| `config.py` | options and environment variables |
| `trx.py` | TRXD/TRXC sockets, `Clock` (DSP-slaved clock), `Transmitter` (uplink scheduling), copies to other BSPs |
| `downlink.py` | downlink decoding, `Feeder` (towards layer 1), IMMEDIATE ASSIGNMENT guard |
| `uplink.py` | uplink encoding, `TchScheduler`, FACCH handling |
| `cipher.py` | A5 keystream, Kc from `/dev/shm/calypso_kc_l1`, retention rule |
| `state.py` | `Dedicated` / `Tch` state machines |
| `gsm.py` | channel plans (SDCCH/8, TCH), xCCH coding |
| `record.py` | I/Q recording to files and FIFOs |
| `stats.py` | counters and the periodic STATS line |
| `dsp/` | subclasses for the DSP mount: `clock.py`, `dedicated.py`, `downlink.py`, `tch.py`, `trx.py`, `uplink.py` |
| `air.py`, `airmesh.py` | burst relays between Calypso instances (BTS mode, multi-node air mesh) |
| `voix_hote.py`, `vsp_audio.py` | host-side speech coding (`PONT_VOIX_HOTE=1`) and the modelled voice port (`CALYPSO_VSP=1`) |
| `pont.py`, `pont_dsp.py` | entry points |

## Shared memory interface

The bridge, the firmware shunt in QEMU and `c54x_exe` exchange state through
`/dev/shm`:

| File | Writer | Content |
|---|---|---|
| `calypso_kc_l1` | the layer 1 (from `d_a5mode` and `a_kc[4]` in the NDB, resolved from the firmware DWARF) | the Kc actually loaded into the DSP; the bridge reads it first and falls back on the historical file only if it is absent, never a mix of the two |
| `calypso_dcch_cfg` | layer 1 | current dedicated channel (`chan_nr`, kind, sub-slot, `seq`; kinds 2/3 = TCH/F, TCH/H on the DSP mount); `0xFF` ends the connection |
| `calypso_tch_cfg` | the bridge | TCH announcement to `c54x_exe`; `seq+1, tn=0` returns to the SDCCH without dropping the Kc |
| `calypso_sdcch_ul` | layer 1 | uplink SDCCH/SACCH L2 blocks; never a FACCH |
| `calypso_tch_facch_ul` | layer 1 | uplink FACCH blocks (single slot with a process-wide `seq`; the bridge resyncs its cursor at each new channel epoch so a stale block is never replayed) |
| `calypso_xcch_ul_rom` | `c54x_exe` | ring of uplink SDCCH/SACCH bursts as emitted by the ROM, with the uplink A5 stream it XORed (header `w`(u32) `n`(u32), 1024-byte slots `seq fn l2[23] . bits[4x116] flux[4x116]`) |
| `calypso_tx_rom` | `c54x_exe` | final uplink bursts of the ROM (`PONT_UL_RAW=1`) |

Kc byte order: the firmware stores the key reversed and by words
(`a_kc[0] = key[7] | key[6]<<8` ... `a_kc[3] = key[1] | key[0]<<8`); both
inversions are undone when reading.

## Ciphering rules

- The end of life of a Kc is a **network event**, not a local state. The key
  is released on IMMEDIATE ASSIGNMENT (the only grant of a new channel, which
  always starts in clear), CHANNEL RELEASE on SDCCH and CHANNEL RELEASE on
  FACCH. It is not released on SABM, on a layer-1 `algo=0` (the firmware
  reloads `dsp_load_ciph_param(0, NULL)` at every resynchronisation, including
  during the SDCCH to TCH switch) nor on `DM_EST_REQ` (also used to open SAPI 3
  on an already ciphered channel).
- `PONT_KC_RETENTION` (default 1) keeps the key over the window where the
  local layer 1 is in clear while the network still ciphers.
- The C0 dummy burst (`osmo-bts` fills every idle timeslot of C0) is filtered
  before `a5_apply` on both the xCCH and the TCH paths: a dummy burst is never
  ciphered, and counting it as a CRC failure inflates the error rate on a
  healthy radio. `ne=0` with `rc=-1` on the TCH is the signature of a constant
  input, not of noise.
- A dedicated channel identity (`chan_nr`) is not an instance: the BSC
  reallocates the same sub-slot, so the identity is forgotten when the channel
  ends, and the next establishment is learnt even with an equal `chan_nr`.
- The DCCH guard (which removes the camp's SI from `a_cd` during a dedicated
  channel) is armed by the downlink (`set_dcch_active`) and kept alive by the
  dedicated uplink (`d_task_u` in {12 DUL, 13 TCHT, 14 TCHA}); its TTL (~2 s)
  returns the camp to the mobile at the end of the channel.
- `CALYPSO_CANNED` takes a token list (`FBDET,TOA,PM,SNR,ANGLE,CRC | FULL |
  ALL | NONE`) or a boolean (`1/ON/YES/TRUE`, `0/OFF/NO/FALSE`).

## DSP mount (`pont_dsp.py`, `pont/dsp/`)

Same building blocks as grgsm, but the dedicated state follows the DSP instead
of the bridge's own decoding, because the BSP plays frames at the C54x's time,
12 to ~200 frames after the bridge:

- **Downlink A5 is done by the DSP.** The mask ROM programs the Calypso XIO
  coprocessor (ports `0x2800..0x2818`, modelled in
  `qosmo/hw/arm/calypso/l1-dsp/calypso_a5.c`, compiled into c54x_exe) with
  `a_kc` and `a_a5fn`. The bridge does not apply the stream to the downlink;
  `PONT_DSP_DECHIFFRE=1` makes it do so again (with `CALYPSO_A5=0` on
  c54x_exe). The uplink stays ciphered by the bridge, at the air fn.
- **`TchDsp`**: the ASSIGNMENT COMMAND is an announcement; c54x_exe switches
  the BSP at the first TCHT/TCHA/TCHD task set by the firmware. `abandon()`
  returns to the SDCCH without dropping the Kc.
- **`UplinkDsp`**: uplink SDCCH/SACCH bursts come from the ROM
  (`calypso_xcch_ul_rom`); the bridge re-decodes them, undoes the ROM's XOR if
  needed (it ciphers at the DSP's time), compares with the L2 of
  `calypso_sdcch_ul`, then sends and re-ciphers at the air fn. Without ROM
  bursts after `PONT_UL_ROM_ATTENTE` (0.12 s): host coding. STATS line:
  `xCCH ul rom= hote= rom_ko=`. A block of `calypso_sdcch_ul` is never a FACCH;
  an ASSIGNMENT FAILURE, or an SDCCH block while the mobile was on the TCH,
  withdraws the announcement. The Kc is kept after the release until the next
  IMMEDIATE ASSIGNMENT.
- **`DedicatedDsp`**: `plan()` always returns the last SDCCH while the
  connection lives; only `0xFF` ends it.
- **`TrxDsp`**: the TCH timeslot counts as dedicated from the announcement
  (osmo-bts ciphers the TCH from activation), under the `cipher.dl_active`
  guard.
- **`ClockDsp`**, closed-loop clock: advance = `PONT_MARGE_DL` (16) minus the
  minimum BTS advance over `PONT_MARGE_FENETRE` (3 s), bounded to
  [`PONT_AVANCE_MIN` 10, `PONT_AVANCE_MAX` 40]. The BTS advance is measured on
  the targeted point (DSP + advance). A "marge DL reelle ... min ... moy" line
  every 10 s in `pont.log` must stay > 0. `PONT_MARGE_DL=0` returns to the
  fixed advance of `Clock`.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `PONT_KC_RETENTION` | 1 | keep the Kc until the next network release event; 0 to compare |
| `PONT_DSP_DECHIFFRE` | 0 | DSP: the bridge deciphers the DL (with `CALYPSO_A5=0` on c54x_exe) |
| `PONT_DSP_COPIES` | `6762` (pont_dsp.py) | extra BSP UDP ports receiving a copy of the downlink (banc-rssi instance); empty = none |
| `PONT_DSP_COPIES_UL` | 1 | also copy the uplink to those ports (marker 0xA5 at byte 6) |
| `PONT_UL_ROM` | 1 | DSP: uplink SDCCH/SACCH bursts from the ROM; 0 = coded by the bridge |
| `PONT_UL_ROM_ATTENTE` | 0.12 | DSP: maximum wait (s) for a block's ROM bursts before host fallback |
| `PONT_UL_RAW` | 0 | DSP: uplink = the ROM's final bursts (`calypso_tx_rom`); host coding and A5 inactive |
| `PONT_UL_RAW_TCH` | 0 | with `PONT_UL_RAW=1`: 1 = TCH by the ROM too (uplink speech cut) |
| `PONT_UL_RAW_DCCH_HOTE` | 0 | with `PONT_UL_RAW=1`: SDCCH/SACCH still coded by the host |
| `PONT_UL_RAW_SACCH_T`, `PONT_UL_RAW_DECAL` | 0 | raw-mode SACCH/T handling and burst offset |
| `PONT_UL_TN_DEFAUT` | unset | default uplink timeslot |
| `PONT_PDCH_FILTRE` | 1 | filter PDCH bursts on the uplink |
| `PONT_UL_RETARD_MAX` | 0 (grgsm), 26 (DSP) | maximum lateness (frames) of an uplink burst still sent; 0 = drop |
| `PONT_UL_FN_ADVANCE` | 3 | uplink frame advance |
| `PONT_WINDOW_TOL`, `PONT_WINDOW_ESSAIS` | 1, 12 | tolerance and re-waits of an uplink burst woken too early |
| `PONT_HORLOGE` | 1 | 0 = wall clock instead of the DSP-slaved clock |
| `PONT_HORLOGE_AVANCE` / `_PERIODE` / `_KP` / `_PHASE_N` / `_MAX` | 12, 0.05 s, 1.0, 100, 4 | clock servo: fixed advance, period, gain, phase, maximum factor |
| `PONT_MARGE_DL`, `PONT_AVANCE_MIN`, `PONT_AVANCE_MAX`, `PONT_MARGE_FENETRE` | 16, 10, 40, 3 s | `ClockDsp` |
| `PONT_CLCK_PERIOD_FN`, `PONT_CLCK_PAUSE_MAX`, `PONT_CLCK_PAUSE_PLAFOND`, `PONT_CLCK_SANS_IND_MAX`, `PONT_CLCK_SKEW_ZONE`, `PONT_BTS_FN_ADVANCE` | 51, 20, 38, 300, 60, 2 | TRXC CLOCK handling |
| `PONT_FACCH_SKIP` | 0 | 1 = also skip the pending FACCH when switching to the TCH |
| `PONT_FACCH_TOUT` | 0 | 1 = send every uplink FACCH block without filtering |
| `PONT_IMM_ASS_GARDE` | 2.0 | s: guard after an IMMEDIATE ASSIGNMENT (Magnetite mobile, `CALYPSO_PONT_IMM_DCCH=0` to disable) |
| `PONT_DCCH_REL_DELAI` | 1.5 | s: delay before a channel release takes effect |
| `PONT_TCH_ABANDON_GRACE` | 2.0 | s: grace before a TCH announcement is abandoned |
| `PONT_GSMTAP_PORT` | 4730 | gr-gsm layer 1 GSMTAP target (14730 with the noise injector) |
| `PONT_TAP`, `PONT_TAP_PORT` | 1, 4729 | GSMTAP for Wireshark |
| `PONT_RSSI` | 60 | RSSI reported to the BTS |
| `PONT_AIRREC`, `PONT_AIRREC_UL` | 1, 1 | I/Q recording DL / UL |
| `PONT_AIRREC_DL_PATH`, `PONT_AIRREC_UL_PATH` | `/root/record.cfile`, `/root/record_ul.cfile` | recording files |
| `PONT_AIRREC_DL_FIFO`, `PONT_AIRREC_UL_FIFO` | `/tmp/iq_fft.fifo`, `/tmp/iq_fft_ms.fifo` | FIFOs for the FFT panel |
| `PONT_AIRREC_MAX_MB`, `PONT_AIRREC_MINFREE_MB`, `PONT_AIRREC_OSR` | 4096, 8192, 4 | file recording stops below the free-space threshold |
| `PONT_VOIX_HOTE`, `PONT_VOIX_SHM_UL`, `PONT_VOIX_SHM_DL` | 0, `/dev/shm/pont_voix_ul`, `/dev/shm/pont_voix_dl` | host-side speech coding for the Magnetite C139 |
| `CALYPSO_CANNED` | | `NONE` = nothing canned, everything real |

Counters: `ne` is the number of bit errors, `nb` the **total** number of bits
(378 for TCH/FS, constant). `ne=0` with `rc=-1` indicates a constant input,
not a healthy radio.

## Reproducible experiment

`scripts/banc-repro.sh` freezes the whole sequence: detached start
(`CALYPSO_NO_ATTACH=1`), camp waited for by **querying** the VTY (`show ms` ->
`C3`), N identical calls, a verdict per call computed on that call's slice of
`pont.log` alone, timestamped collection in `/root/repro-<stamp>/` with a
`resume.txt`.

```
scripts/banc-repro.sh --calls 4                 # with restart
scripts/banc-repro.sh --no-restart --calls 3    # on the running stack
scripts/banc-repro.sh --dest 600                # called number (default 600)
PONT_KC_RETENTION=0 scripts/banc-repro.sh       # A/B of a setting
```

Three calls are enough to tell an intermittent fault from a positional one.

## Known issues

- **`unsupported SAPI` on the mobile side**: a few per run remain (not the
  SACCH L1 header, not the camp's SI; both checked). Does not block calls.
  Possible leads: another writer of `a_cd`, or the firmware re-reading a stale
  block for lack of refresh (`B_BLUD`).
- **Residual CRC failures** on the ciphered SDCCH and on the SACCH, not
  isolated.
- **B_BFI** set on every speech frame delivered by the ROM while FR stays
  intelligible; signal path or C54x core, not decided.
- **Occasional LOS** on a TCH call: the TCH's SACCH is lost entirely for ~15 s;
  the next call is clean. Cause unknown.
- **Downlink SACCH of the SDCCH/8**: about half of the blocks discarded by the
  mobile during an LU; suspect the BSP's SACCH/8 table (alternation over two
  51-multiframes).
- **UI SAPI 0 on the TCH** ("unimplemented Abis RLL message" at the BSC), not
  blocking.
- **Clock**: the targeted advance sometimes reaches `PONT_AVANCE_MAX`; the
  real DL margin can touch 0 right after a LOS.
- `_TBL_SOFT` holds two encodings (`0x01` and `0xFF` both map to `-127`);
  harmless as long as the DL TRXD arrives as hard bits `0x00/0x01`.
- Not anomalies: CRC failures of the bridge's downlink TCH monitor at the start
  and end of a call (the BTS puts nothing on the TCH while RTP does not flow).
