# Résultats de référence — `checks/check_all.sh`

Deux exécutions sur la même machine (Ubuntu 24.04, natif, hostname `operator`),
le 2026-09-15. Elles servent d'étalon : un banc sain donne ces lignes-là, et les
écarts commentés ici sont connus.

| | Run 1 — 17:57 | Run 2 — 18:12 |
|---|---|---|
| Topologie | 1 opérateur natif, **sans** inter-STP | 3 opérateurs (Op1 natif + Op2/Op3 conteneurs) + inter-STP local |
| `global` | OK — 29 pass / 0 fail / 1 warn / 1 skip (85 s) | OK — 88 pass / 0 fail / 5 warn / 0 skip (217 s) |
| `ss7` | OK — 7 pass / 1 warn / 3 skip | OK — **31 pass / 0 warn / 0 skip**, matrice 3×3 complète |
| `interstp` | ignoré (aucun hub) | **ECHEC** « aucun AS actif » — faux négatif, voir § 2.3 |
| `operator` | ECHEC « INTERCO SS7 : DOWN » — attendu sans hub | ignoré (ce nœud est le hub) |
| `annuaire` | ignoré (pas de fiche) | OK — 4 abonnés/op, 2 warn |
| `wan`, `dump`, `resume` | ignorés | ignorés |
| **Verdict** | **sain** pour un nœud seul | **sain**, interco opérationnelle ; 1 bug de diag, 2 warn à traiter |

---

## 1. Run 1 — nœud natif seul

Tout le cœur est vert : STP 2 ASP / 2 AS, aucun PROHIB ; HLR avec VLR et SMSC
en GSUP ; MSC et BSC `ASP_ACTIVE`, SSN 254 ; BTS 0 Enabled/OK, OML + RSL ; PCU
sur BTS ; SGSN 1 NS entity ; SIP connector, MNCC, relay SMS `:7890`, Asterisk ;
les sept démons en cours.

`diag-stp-operator.sh` conclut « INTERCO SS7 : DOWN » avec trois causes :
`asp-to-inter` en `shutdown`, `remote-ip 127.0.0.1` ≠ hub `172.20.0.10`, pas de
SCTP. Les trois sont la **même** cause : il n'y a pas d'inter-STP. L'échec est
attendu et disparaît au run 2.

Un seul warn réel : **GGSN, 0 APN**.

## 2. Run 2 — trois opérateurs + inter-STP

### 2.1 Ce qui prouve que l'interco marche

- Chaque STP a **3 ASP / 3 AS** actifs (le troisième est `as-inter`) et une route
  par défaut vers l'inter-STP « présente et avail ».
- `ss7_check.sh` : hub `0.0.0` joignable, 3 AS / 3 ASP, aucun PROHIB ; sur les
  trois opérateurs `as-inter → hub : ACTIVE` ; matrice de connectivité
  Op1/Op2/Op3 toute en `via`, 31 pass, 0 warn.
- `annuaire.sh` : opérateurs 2 et 3 à **3/3 AS actifs**, point codes
  `1.2.x` / `1.3.x`, RCTX 250 / 350, hub 172.20.0.10 — conforme aux formules
  du README.

### 2.2 Les warn

| Warn | Où | Lecture |
|---|---|---|
| GGSN : 0 APN configuré | Op1, Op2, Op3 | même point qu'au run 1 : la data 2G (SGSN → GGSN) ne monte pas de PDP sans APN. `APN=internet` dans `globals.conf` puis `--regen`. La 4G (Open5GS/ogstun) n'est pas concernée |
| SGSN : 0 NS entity | Op2, Op3 | le PCU des conteneurs n'a pas ouvert son NS-VC vers le SGSN (Op1, natif, en a 1). Sans effet sur voix/SMS/SS7 ; à regarder avec le point précédent si la data 2G est voulue sur ces opérateurs |
| 2 abonnés sans fiche | Op2, Op3 | le HLR connaît `00101000N000001/2` (provisionnés par l'ancien schéma d'IMSI) en plus des `0010N000N000001/2` qui ont une fiche. Le script le dit : banc relancé sans `start.sh`. Cosmétique |

### 2.3 Le faux négatif de `diag-interstp.sh`

Le bilan affiche `interstp ECHEC — INTERCO SS7 : DOWN - aucun AS actif`, alors
que le même script vient d'écrire trois lignes `[ OK ] … AS_ACTIVE` et que
`ss7_check.sh` valide l'interco de bout en bout. Deux indices dans sa sortie :

- `[FAIL] service inactif (inactive)` : il interroge `systemctl` pour l'unité
  du hub, qui n'existe pas quand l'inter-STP est lancé par `start-multi.sh`
  (conteneur `osmo-inter-stp`) et non par `osmo-interstp.service`.
- `== ASP ATTACHES ==` liste `asp-to-inter` (client vers `127.0.0.1:2908`),
  `as-rkm-110` et `as-rkm-130` : ce sont les AS **du STP de l'opérateur 1**
  (RCTX 110 = MSC, 130 = BSC), pas ceux du hub. Le script a lu la VTY
  `127.0.0.1:4239`, qui sur un nœud hybride natif + Docker est celle d'Op1,
  et n'a trouvé aucun `as-opN` — d'où « aucun AS actif ».

Conclusion : **l'interco est UP**, le verdict est un défaut du script en
topologie hybride (hub en conteneur, opérateur 1 natif sur le même hôte). À
corriger dans `checks/diag-interstp.sh` : viser la VTY du conteneur
`osmo-inter-stp` (ou `--hub-vty`) quand `OSMO_ROLE=operator` et que le hub est
« interrogeable ici », et ne pas compter `systemctl` comme un FAIL quand le hub
est un conteneur.

## 3. Rejouer

```bash
bash ./checks/check_all.sh                         # ~2 min seul, ~6 min à trois opérateurs
./checks/check_all.sh --only=interstp --verbose    # le check en détail
./checks/check_all.sh --dump                       # + vty-debug-dump et operator_summary
```

Journal complet : `/tmp/osmo-check-all-<date>.txt`.
