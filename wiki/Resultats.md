# Reference results — `checks/check_all.sh`

Two runs on the same machine (Ubuntu 24.04, native, hostname `operator`),
on 2026-09-15. They serve as a baseline: a healthy bench produces these lines, and the
deviations commented here are known.

| | Run 1 — 17:57 | Run 2 — 18:12 |
|---|---|---|
| Topology | 1 native operator, **without** inter-STP | 3 operators (Op1 native + Op2/Op3 containers) + local inter-STP |
| `global` | OK — 29 pass / 0 fail / 1 warn / 1 skip (85 s) | OK — 88 pass / 0 fail / 5 warn / 0 skip (217 s) |
| `ss7` | OK — 7 pass / 1 warn / 3 skip | OK — **31 pass / 0 warn / 0 skip**, full 3×3 matrix |
| `interstp` | skipped (no hub) | **ECHEC** (FAIL) "aucun AS actif" (no active AS) — false negative, see § 2.3 |
| `operator` | ECHEC (FAIL) "INTERCO SS7 : DOWN" — expected without a hub | skipped (this node is the hub) |
| `annuaire` | skipped (no directory entry) | OK — 4 subscribers/op, 2 warn |
| `wan`, `dump`, `resume` | skipped | skipped |
| **Verdict** | **healthy** for a single node | **healthy**, interconnect operational; 1 diag bug, 2 warn to address |

---

## 1. Run 1 — single native node

The whole core is green: STP 2 ASP / 2 AS, no PROHIB; HLR with VLR and SMSC
over GSUP; MSC and BSC `ASP_ACTIVE`, SSN 254; BTS 0 Enabled/OK, OML + RSL; PCU
on BTS; SGSN 1 NS entity; SIP connector, MNCC, SMS relay `:7890`, Asterisk;
the seven daemons running.

`diag-stp-operator.sh` concludes "INTERCO SS7 : DOWN" with three causes:
`asp-to-inter` in `shutdown`, `remote-ip 127.0.0.1` ≠ hub `172.20.0.10`, no
SCTP. All three are the **same** cause: there is no inter-STP. The failure is
expected and disappears at run 2.

Only one real warn: **GGSN, 0 APN**.

## 2. Run 2 — three operators + inter-STP

### 2.1 What proves the interconnect works

- Each STP has **3 ASP / 3 AS** active (the third is `as-inter`) and a default
  route to the inter-STP "présente et avail" (present and avail).
- `ss7_check.sh`: hub `0.0.0` reachable, 3 AS / 3 ASP, no PROHIB; on all
  three operators `as-inter → hub : ACTIVE`; connectivity matrix
  Op1/Op2/Op3 all `via`, 31 pass, 0 warn.
- `annuaire.sh`: operators 2 and 3 at **3/3 AS active**, point codes
  `1.2.x` / `1.3.x`, RCTX 250 / 350, hub 172.20.0.10 — matching the README's
  formulas.

### 2.2 The warnings

| Warn | Where | Interpretation |
|---|---|---|
| GGSN: 0 APN configured | Op1, Op2, Op3 | same point as run 1: 2G data (SGSN → GGSN) does not bring up a PDP without an APN. `APN=internet` in `globals.conf` then `--regen`. 4G (Open5GS/ogstun) is not affected |
| SGSN: 0 NS entity | Op2, Op3 | the containers' PCU did not open its NS-VC to the SGSN (Op1, native, has 1). No effect on voice/SMS/SS7; to look at together with the previous point if 2G data is wanted on these operators |
| 2 subscribers without a directory entry | Op2, Op3 | the HLR knows `00101000N000001/2` (provisioned by the old IMSI scheme) in addition to the `0010N000N000001/2` that have an entry. The script says so: bench restarted without `start.sh`. Cosmetic |

### 2.3 The false negative of `diag-interstp.sh`

The report shows `interstp ECHEC — INTERCO SS7 : DOWN - aucun AS actif`
(FAIL — SS7 INTERCO: DOWN - no active AS), even though the same script has just
written three `[ OK ] … AS_ACTIVE` lines and `ss7_check.sh` validates the
interconnect end to end. Two clues in its output:

- `[FAIL] service inactif (inactive)` (service inactive): it queries `systemctl`
  for the hub's unit, which does not exist when the inter-STP is launched by
  `start-multi.sh` (the `osmo-inter-stp` container) and not by `osmo-interstp.service`.
- `== ASP ATTACHES ==` lists `asp-to-inter` (client to `127.0.0.1:2908`),
  `as-rkm-110` and `as-rkm-130`: these are the AS **of operator 1's STP**
  (RCTX 110 = MSC, 130 = BSC), not the hub's. The script read the VTY
  `127.0.0.1:4239`, which on a hybrid native + Docker node is Op1's,
  and found no `as-opN` — hence "aucun AS actif".

Conclusion: **the interconnect is UP**, the verdict is a defect in the script in
a hybrid topology (hub in a container, operator 1 native on the same host). To
fix in `checks/diag-interstp.sh`: target the VTY of the `osmo-inter-stp`
container (or `--hub-vty`) when `OSMO_ROLE=operator` and the hub is
"queryable here", and not count `systemctl` as a FAIL when the hub
is a container.

## 3. Replay

```bash
bash ./checks/check_all.sh                         # ~2 min alone, ~6 min with three operators
./checks/check_all.sh --only=interstp --verbose    # the check in detail
./checks/check_all.sh --dump                       # + vty-debug-dump and operator_summary
```

Full log: `/tmp/osmo-check-all-<date>.txt`.
