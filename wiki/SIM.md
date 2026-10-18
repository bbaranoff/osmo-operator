# SIM: the bench's card in an Omnikey HID reader, and softSIM

The bench mobile (`mobile`, osmocom-bb) has no card reader: its SIM is
either the **test SIM** from the config file (`sim test`, IMSI and Ki written
in the clear, the default), or a SIM **served over a socket** by the SAP
protocol (*SIM Access Profile*, `sim sap`). It is this second path that
`start-direct.sh --sap` sets up, with the SAP server from
[softSIM](https://gitea.osmocom.org/sim-card/softsim)
(Ruby), which can serve two things:

| type | what the mobile sees | when |
|---|---|---|
| **pcsc** | the **real card** in the PC/SC reader: a sysmoISIM-SJA5 in a HID OMNIKEY 6121 | a card is in the reader |
| **sim** | the **software SIM** `sim-op1.xml` (IMSI of MS#1, COMP128v1 with the HLR Ki) | no card |

`--sap` chooses on its own (pcsc if a card is present, otherwise sim); `--sap=pcsc`
(`--omnikey`) and `--sap=sim` force it. Without `--sap`, nothing changes: test SIM.

## 1. Install

```bash
sudo tools/osmo-sim-install.sh        # or: sudo ./addition.sh --sim
```

Installs, without breaking anything already present: `pcscd` + `libccid` (the PC/SC daemon and the
Omnikey's CCID driver), `pcsc-tools`/`opensc` (to see the reader and the ATR), Ruby +
`ruby-libxml` + the `smartcard` gem (softSIM as a reader), Osmocom's **pySim** in
`/opt/GSM/pysim-venv` (from its git: the "pySim" on PyPI is a different project),
and softSIM itself in `/opt/GSM/softsim` with the patches from `tools/softsim/`.
The ISO does the same (`iso_modules/51-softsim.sh` + `80-chroot.sh`,
`--no-softsim` to skip it).

Verified on 2026-10-14: OMNIKEY 6121 (USB `076b:6632`), sysmoISIM-SJA5, ATR
`3b9f96801f878031e073fe211b674a357530350265f8`, Ruby 3.2.3, smartcard gem 0.5.6, sysmo-usim-tool 190c95b.

## 2. View the card

```bash
tools/osmo-sim.sh lecteur     # the readers, the ATR, the card type, ICCID, IMSI
tools/osmo-sim.sh lire        # everything (pySim-read): PLMN, SMSP, ACC, services…
tools/osmo-sim.sh shell       # interactive pySim-shell (ADM1 passed if known)
```

## 3. Program the card to the bench's plan

The bench provisions its subscribers in osmo-hlr with a fixed plan
(`qosmo/run_modules/21-abonnes-hlr.sh`, `start-direct.sh` section `ms_imsi`):

| | MS#1 of operator 1 |
|---|---|
| IMSI | `001 01 0001 000001` → `001010001000001` |
| Ki | `00112233445566778899aabbccdd` + MS + operator → `…dd0101` |
| algorithm | COMP128v1 (`aud2g comp128v1`) |
| MSISDN | node×100000 + operator×100 + MS → `100101` |

For the card to register, it must carry **exactly** this identity:

```bash
tools/osmo-sim.sh programmer --dry-run          # shows, writes nothing
tools/osmo-sim.sh programmer --adm1 12345678    # writes (asks for confirmation)
tools/osmo-sim.sh programmer --ms 2 --op 1      # another MS of the plan
tools/osmo-sim.sh verifier                      # card = plan? HLR? ready for --sap?
```

What it writes goes through sysmocom's tool, **sysmo-usim-tool**
(`/opt/GSM/sysmo-usim-tool/sysmo-isim-tool.sja5.py`, installed by the installer): IMSI,
MNC length, Ki (2G/3G/4G5G), **2G algorithm COMP128v1** (3G Milenage), OPc;
then it reads back the algorithm and Ki (`-t -k`). It is the one that knows how to set the
algorithm: `pySim-prog` writes only the Ki and the card would stay in Milenage, the HLR would answer
*authentication failed*. Without the tool (or `OSMO_SIM_PYSIM_PROG=1`), it falls back to
`pySim-prog` (ICCID kept, IMSI, PLMN, name, SMSP, MSISDN, Ki) then `pySim-shell`
for the algorithm byte `0x11` in `DF.SYSTEM/EF.SIM_AUTH_KEY` (6f20) and
`ADF.USIM/EF.USIM_AUTH_KEY_2G` (af22).

Done on 2026-10-14 on card 8949440000001549193: `verifier` says "prête" (ready).

### The ADM1 key

Writing to a sysmoISIM requires the **ADM1 key of that card** (8 digits), which
sysmocom provides with the card (data file of the order). **Three wrong tries
block the card for good**: the script never guesses, it refuses without a
key. Where to put it, in the order it is looked for:

1. `--adm1 K` on the command line;
2. `OSMO_SIM_ADM1=K` in the environment;
3. `/etc/osmocom/sim-adm1` (`chmod 600`): one line, or `ICCID key` per line
   for several cards;
4. `~/.config/osmo/sim-adm1`.

### A card you don't want to reprogram

It keeps its IMSI and Ki: you must then declare them to the HLR.

```bash
tools/osmo-sim.sh hlr --creer --ki <card's Ki>     # subscriber created via the VTY (4258)
```

(`hlr` without `--creer` only says whether the HLR knows the IMSI read on the card.)

## 4. Launch

```bash
./start-direct.sh --sap            # card present → pcsc; otherwise software SIM
./start-direct.sh --sap=pcsc       # the card, mandatory
./start-direct.sh --dry-run --sap  # what would be done, without launching anything
```

`start_sap` runs **before** the stack: it launches `demo_server.rb` (softSIM) on
`/tmp/osmocom_sap` (`SAP_SOCK`), with log `/tmp/osmo-sap.log` (`SAP_LOG`,
`SAP_VERBOSITY=3`: connection, card ready, each timestamped APDU), and the mobile
connects to it at startup. The server serves the next client after a disconnect
(patch `0002`): a baseband restart requires nothing.

In DSP mode (the default), the MS#1 that runs is the one from c54x_exe
(`mobile_pont.cfg`, `sim test`): `--sap` derives
`/root/.osmocom/bb/mobile_pont_sap.cfg` from it (`sim sap`, `sap-socket`) and passes it to the
bench via `MOBILE_CFG`. In grgsm mode, it is `mobile.cfg` generated from
`configs/mobile.cfg` (`sim sap` in the template, reset to `sim test` without `--sap`)
that carries it; MS#2 stays on the test SIM.

`./start-direct.sh --stop` also stops the SAP server; a startup always relaunches it fresh
(it is killed with the rest in "Arrêt de la pile avant démarrage" — stopping the stack before startup).

Serve the card by hand, without the stack (to watch the APDUs):

```bash
tools/osmo-sim.sh sap              # foreground, Ctrl-C to stop
```

## 5. What the patches fix

| file | what |
|---|---|
| `tools/softsim/0001-simos-comp128v1-a38.patch` | software SIM: COMP128v1 with `SOFTSIM_KI` (any RAND from the HLR), READ RECORD, `--file` passed through, acceptance loop |
| `tools/softsim/0002-sap-serve-next-client.patch` | the server serves the next client instead of exiting |
| `tools/softsim/0003-sap-log-timestamps.patch` | APDUs named and timestamped (ms) in the log |
| `tools/softsim/0004-pcsc-disconnect-idempotent.patch` | pcsc mode: `disconnect` called twice per client (DISCONNECT_REQ then socket close) crashed the server on a null handle, the mobile could no longer reconnect |
| `tools/softsim/ruby_compat.rb` | Ruby ≥ 3.2: `File.exists?`, `Fixnum` |
| `tools/softsim/make_sim_op1.py` | `sim-op1.xml`: IMSI, valid ICCID, PLMN, SPN from the demo `sim.xml` |
| `patches/osmocom-bb-plmn-a6-reinsert.patch` | mobile: SIM reinserted without RPLMN (SAP reconnection), the PLMN search ended "unhandled" |
| `patches/osmocom-bb-sim-plmn-from-bcd.patch` | mobile: SIM PLMNsel/FPLMN read with the right function (000-00 before) |

The two osmocom-bb patches are applied by `install_modules/40-patches.sh`
(native) and the `Dockerfile`; `mobile` must be recompiled afterwards.
