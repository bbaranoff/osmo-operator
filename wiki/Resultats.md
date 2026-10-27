# Bench checks — `checks/check_all.sh`

`checks/check_all.sh` runs every read-only check of `checks/` in the right
order, on the right node, and returns one verdict: a table with one line per
check, a pass/warn/fail count and a return code. It modifies nothing and
restarts nothing (only `--dump` raises the daemons' log level, and it is never
on by default). This page describes what it runs and what a healthy bench
looks like.

## 1. Usage

```bash
sudo ./checks/check_all.sh                         # ~2 min on a single node, ~6 min with three operators
./checks/check_all.sh --only=interstp --verbose    # one check, in detail
./checks/check_all.sh --dump                       # + vty-debug-dump and operator_summary
./checks/check_all.sh --list                       # the checks and whether each one applies here
```

| option | effect |
|---|---|
| `--quick`, `-q` | passed to `global_check` / `ss7_check` (fast pass) |
| `--verbose`, `-v` | passed to the checks that understand it |
| `--op=N` | limit to one operator (`global_check`, `annuaire`) |
| `--docker` / `--native` | force the world to look at; auto-detected otherwise |
| `--dump` | add `vty-debug-dump.sh` then `operator_summary.sh` |
| `--only=a,b` | run only these checks |
| `--out FILE` | full log (default `/tmp/osmo-check-all-<date>.txt`) |

## 2. Which checks run

| check | script | runs when |
|---|---|---|
| `global` | `global_check.sh` | always: daemons, VTYs, BTS, PCU, SGSN, SIP connector, SMS relay |
| `ss7` | `ss7_check.sh` | always: ASP/AS state, routes, hub reachability, connectivity matrix |
| `interstp` | `diag-interstp.sh` | only if an inter-STP is queryable here (container `osmo-inter-stp`, or `OSMO_ROLE=interstp`) |
| `operator` | `diag-stp-operator.sh` | only when this node is not the hub and has `/etc/osmo-role` (a WAN setup) |
| `wan` | `wan_ss7_check.sh` | only if `/etc/osmo-wan.conf` exists |
| `annuaire` | `annuaire.sh` | only if subscriber directory entries exist (`/var/tmp` or `/etc/osmocom`) |
| `dump`, `resume` | `vty-debug-dump.sh`, `operator_summary.sh` | only with `--dump` |

Verdicts: `global_check.sh` / `ss7_check.sh` return the number of failures,
`wan_ss7_check.sh` returns 0 or 1, `diag-*.sh` and `annuaire.sh` always return
0 and their verdict is read from their last section (e.g. `INTERCO SS7 : DOWN`)
with the colours stripped.

## 3. What a healthy run looks like

**Single native node, no inter-STP**: `global` OK (about 30 pass, 0 fail),
`ss7` OK with a few skips, `interstp` skipped (no hub), `annuaire` skipped
(no directory entry), `wan`/`dump`/`resume` skipped. `operator` reports
`INTERCO SS7 : DOWN` (`asp-to-inter` in `shutdown`, `remote-ip 127.0.0.1`, no
SCTP): expected, there is no inter-STP to reach.

**Three operators (Op1 native + Op2/Op3 containers) + local inter-STP**:
`global` OK (about 90 pass), `ss7` OK with the full 3×3 connectivity matrix
(each STP has 3 ASP / 3 AS active, the third being `as-inter`, and a default
route to the inter-STP present and avail), `annuaire` OK (4 subscribers per
operator, point codes `1.2.x` / `1.3.x`, RCTX 250 / 350, hub 172.20.0.10),
`operator` skipped (this node is the hub).

Expected warnings:

| warning | meaning | action |
|---|---|---|
| `GGSN: 0 APN configured` | 2G data (SGSN → GGSN) cannot bring up a PDP context without an APN; 4G (Open5GS/ogstun) is not affected | `APN=internet` in `globals.conf`, then `--regen` |
| `SGSN: 0 NS entity` (container operators) | the containers' PCU did not open its NS-VC to the SGSN; no effect on voice/SMS/SS7 | only matters if 2G data is wanted on those operators |
| subscribers without a directory entry | the HLR also knows IMSIs provisioned by another numbering scheme (bench restarted without `start-docker.sh`) | cosmetic |

## Known issues

- **`diag-interstp.sh` false negative on a hybrid node** (hub in the
  `osmo-inter-stp` container, operator 1 native on the same host): the check
  reports `interstp ECHEC — INTERCO SS7 : DOWN - aucun AS actif` and
  `[FAIL] service inactif` even though `ss7_check.sh` validates the
  interconnect end to end. The script queries `systemctl` for a hub unit that
  does not exist when the hub is a container launched by `launch/start-multi.sh`,
  and reads the VTY `127.0.0.1:4239`, which is operator 1's STP, so it sees
  `asp-to-inter` / `as-rkm-*` and no `as-opN`. TODO: target the container's
  VTY when `OSMO_ROLE=operator` and the hub is queryable here, and do not count
  the missing systemd unit as a FAIL when the hub is a container.
