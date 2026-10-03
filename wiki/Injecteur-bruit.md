# Injecteur de bruit (sens descendant)

> Version du 2026-10-03. Retour : [Home](Home.md) · [Lancer-a-la-main](Lancer-a-la-main.md).

Les bursts que reçoit le téléphone émulé sont **parfaits** : bits durs tirés tels quels de la BTS,
modulés sans bruit. Pour éprouver la couche 1 (DSP C54x ou L1 gr-gsm), le banc a deux injecteurs,
**inactifs par défaut** :

| | Où | Activation | Quoi |
|---|---|---|---|
| **bruit physique** (C) | cœur C54x, `c54x_bsp_load()` (`qosmo/hw/arm/calypso/l1-dsp/calypso_c54x.c`) | `BRUIT_SNR_DB=<dB>` **sans** `BRUIT_MODE` (→ `CALYPSO_BSP_SNR_DB` sur `c54x_exe`) | AWGN sur **tous** les I/Q descendants, après la modulation réglée du BSP, déterministe par trame |
| **injecteur** (Python) | proxy UDP entre le pont et la couche 1 : `qosmo/tools/injecteur_bruit.py` | `BRUIT_MODE=ber\|souple\|iq\|relais` | bits inversés, AWGN + décision dure, ou I/Q GMSK bruité (expérimental) |

Le bruit physique est le plus réaliste en montage DSP. L'injecteur sert à doser un **taux d'erreur
binaire** précis, des **rafales**, des **effacements**, et c'est le seul moyen d'abîmer le flux en
montage gr-gsm.

## Où l'injecteur s'intercale

```
montage dsp   osmo-bts-trx ─TRXD 5702─▶ pont_dsp.py ─udp 6702─▶ [injecteur 127.0.0.1:6702] ─udp 16702─▶ BSP de c54x_exe
                                        (inchangé)              ◀── montant relayé tel quel ──         (CALYPSO_BSP_PORT=16702)

montage grgsm osmo-bts-trx ─TRXD 5702─▶ pont.py ─GSMTAP 14730─▶ [injecteur 127.0.0.1:14730] ─udp 4730─▶ L1 gr-gsm de QEMU
                                        (PONT_GSMTAP_PORT)
```

- **dsp** : format `[tn, fn BE32, att, 0, 0]` + 148 octets de bits **durs** 0/1
  (`pont/trx.py` `Trx.run_data`, `calypso_bsp.c` `bsp_trxd_readable`). Le BSP est déplacé sur
  `BRUIT_PORT_DSP` (16702) par `CALYPSO_BSP_PORT` ; le pont ne change pas. Le BSP apprend son pair
  montant sur l'émetteur du descendant : ses éventuels bursts montants arrivent donc à l'injecteur,
  qui les rend **sans modification** au pont (5702), depuis 6702, l'adresse qu'ils avaient avant.
- **grgsm** : QEMU écoute `127.0.0.1:4730` **en dur** (`calypso_l1_grgsm.c`). C'est donc le pont qui
  vise ailleurs : `PONT_GSMTAP_PORT` (`pont/config.py`, 4730 par défaut), que `pont/pont.py` pose
  lui-même à `BRUIT_PORT_GRGSM` (14730) quand `BRUIT_MODE` vaut `ber` ou `relais`. Le flux est un
  en-tête GSMTAP de 16 octets + le **bloc L2 déjà décodé** (23 octets) : ni bursts, ni valeurs
  souples. Le SCH (4731) et la parole TCH (`/dev/shm/calypso_tch_dl`) ne passent pas par là.

## Activer

Tout passe par l'environnement, comme le reste du banc :

```bash
# DSP (défaut de start-direct.sh) : 1 % de bits inversés
BRUIT_MODE=ber BRUIT_BER=0.01 ./start-direct.sh --dsp

# DSP : erreurs en rafales de 40 bits, même taux moyen, rejouable
BRUIT_MODE=ber BRUIT_BER=0.01 BRUIT_RAFALES=40 BRUIT_GRAINE=7 ./start-direct.sh --dsp

# DSP : bruit physique du cœur à 12 dB (pas d'injecteur)
BRUIT_SNR_DB=12 ./start-direct.sh --dsp

# gr-gsm : 10 % de blocs perdus (= échecs CRC côté L1)
BRUIT_MODE=relais BRUIT_PERTE=0.1 ./start-direct.sh --grgsm

# banc du téléphone seul
MODE=dsp PONT=1 BRUIT_MODE=souple BRUIT_SNR_DB=6 /opt/GSM/c54x_exe/run.sh
```

- **`start-direct.sh --dsp`** : le plan de qosmo tourne sans `qemu` (le module `38-bruit` se saute),
  puis `c54x_exe/run.sh` reçoit les `BRUIT_*` et intercale l'injecteur : **étape b**, entre le DSP
  (étape 1) et QEMU ; `--step b` la joue seule.
- **`start-direct.sh --grgsm`** : `qosmo/run_modules/38-bruit.sh` (avant `40-qemu`) lance l'injecteur ;
  `pont.py`, lancé par `start-direct.sh` avec le même environnement, vise 14730.
- **À la main** : `python3 /opt/GSM/qosmo/tools/injecteur_bruit.py --help`.

| Variable | Défaut | Effet |
|---|---|---|
| `BRUIT_MODE` | *(vide = rien)* | `ber`, `souple`, `iq` (dsp seulement, expérimental), `relais` |
| `BRUIT_BER` | 0 | taux d'inversion moyen, 0..1 (`ber`) |
| `BRUIT_RAFALES` | — | longueur moyenne d'une rafale en bits (Gilbert-Elliott, taux 0,5 dans la rafale ; `--ber-rafale` pour le changer) |
| `BRUIT_SNR_DB` | — | SNR en dB, P/(2σ²) par échantillon complexe (`souple`, `iq`) ; **seul** : bruit physique du cœur |
| `BRUIT_PERTE` | 0 | effacement : burst remplacé par des bits aléatoires (dsp, cadence du BSP gardée) ; bloc non transmis (grgsm) |
| `BRUIT_TN` | tous | intervalles à dégrader, ex. `0` ou `1,2` |
| `BRUIT_GRAINE` | tirée et écrite au journal | même graine + mêmes trames = mêmes erreurs ; seule, devient `CALYPSO_BSP_BRUIT_GRAINE` |
| `BRUIT_STATS` | 10 | période des statistiques (s) |
| `BRUIT_OPTS` | — | options passées telles quelles (ex. `--forcer-iq`, `--amp 20000`) |
| `BRUIT_PORT_DSP` / `BRUIT_PORT_GRGSM` | 16702 / 14730 | ports déplacés |
| `BRUIT_CIBLE` | auto | qosmo seulement : L1 du QEMU (`auto` lit `build/meson-info`) |
| `BRUIT_PY` | `qosmo/tools/injecteur_bruit.py` | c54x_exe se replie sur `c54x_exe/tools/injecteur_bruit.py` (lien) |

## Les modes

- **`ber`** — inversion de bits indépendants (taux `BRUIT_BER`), ou en rafales. En dsp ce sont les
  bits durs que le BSP module ensuite : le DSP voit un signal propre portant de mauvais bits. En
  grgsm ce sont des bits du bloc L2 **après décodage** : rien ne les détecte plus (ni code correcteur
  ni CRC), ce n'est pas physique ; `BRUIT_PERTE` est le modèle réaliste (échec CRC).
- **`souple`** — vérifié le 2026-10-03 : aucun des deux flux ne porte de valeurs souples. Sur bits
  durs : modulation antipodale ±1, AWGN à `BRUIT_SNR_DB`, décision dure ; le taux obtenu,
  Q(√(2·snr)), est annoncé au démarrage (5 dB → 6,0·10⁻³). La sortie reste en 0/1, le seul format
  que le BSP sait lire. Un flux int8 souple (convention TRXD, +127 = 1) serait bruité et gardé
  souple. Refusé en grgsm.
- **`iq`** — **EXPÉRIMENTAL**. Bits → GMSK BT=0,3 à 4 échantillons/symbole (même table et même
  instant que `calypso_gmsk.c` : identique à l'échantillon près aux points que garde le BSP), +AWGN,
  envoyé en I/Q int16 (`IQ_PASSTHROUGH`, décimation par 4). Contourne la modulation réglée du BSP :
  le SCH n'a pas son `sb_moduler()` (instant 0,35, élargissement 1,0) ; seul `gmsk_elargir(0,3)` des
  NB est imité (`--iq-elargir`). **Refusé avec `CALYPSO_BSP_STREAM=1`**, le défaut de
  `start-direct.sh --dsp` : en STREAM le BSP range les 148 premiers octets du paquet comme des bits
  *avant* de regarder s'il s'agit d'I/Q. numpy requis.
- **`relais`** — rien d'altéré (sauf `BRUIT_PERTE`) : vérifie que l'intercalation seule ne change rien.

## Lire ce qu'il fait

Journal : `/tmp/c54x-pont/bruit.log` (c54x_exe, rangé dans `archives/` à l'arrêt) ou
`$LOG_DIR/bruit.log` (qosmo). Démarrage (réglages, graine, `PRET ecoute=… vers=…`), puis toutes les
`BRUIT_STATS` secondes :

```
STATS t=10s DL recus=17330 relayes=17330 alteres=17330 effaces=0 hors_tn=0 autres=0 iq_deja=0 iq_produits=0 souples=0 | bits=2564840 inverses=25650 BER=1.000e-02 | UL relayes=0 sans_dest=0 | erreurs_envoi=0 | 1733 pq/s
```

`kill -USR1 <pid>` force une ligne ; `SIGTERM` écrit le `BILAN` et sort. `./run.sh --status`
(c54x_exe) montre la dernière ligne. Arrêt : `c54x_exe/run.sh --stop` ou `qosmo/run.sh --stop` (et le
teardown de qosmo le compte parmi les restes à tuer).

## Limites

- L'injecteur ne peut pas s'intercaler devant un `c54x_exe` déjà démarré **sur 6702** :
  `run.sh` le dit et continue sans bruit (`./run.sh --stop` d'abord). Une configuration refusée
  (ex. `iq` sous STREAM, `souple` en grgsm) arrête `c54x_exe/run.sh` **avant** tout lancement.
- `--rafales` : l'état du canal suit l'ordre d'arrivée ; seul le mode indépendant est déterministe
  par (graine, fn, tn) quel que soit l'ordre.
- Le bruit `iq`, comme `CALYPSO_BSP_SNR_DB`, est écrêté en int16 : à l'amplitude 30000 il ne reste
  que 2767 de marge (≈ 22 % d'échantillons écrêtés à 10 dB, 3 % à 20 dB) ; l'injecteur l'annonce,
  `--amp` plus bas l'évite.
- En grgsm l'injecteur ne voit que la signalisation (GSMTAP) : la parole TCH et le SCH lui échappent.
- Coût : ~6 µs par burst en `ber`/`souple`, ~85 µs en `iq`, pour ~1733 bursts/s.

## Vérifié

Banc de test sur le loopback (ports 47xxx, jamais ceux du banc) : BER mesuré 1,005·10⁻² pour 10⁻²
(3 M bits), rafales 0,997·10⁻² avec 9 % de bursts touchés (77 % en indépendant), `souple` 5 dB
5,96·10⁻³ pour 5,95·10⁻³ théorique, effacements 9,9 % pour 10 %, grgsm 1,98·10⁻³ pour 2·10⁻³ et
19,8 % de blocs perdus pour 20 %, en-têtes intacts, montant rendu octet pour octet depuis le port
d'écoute, même graine = mêmes erreurs (même dans l'ordre inverse), modulateur `iq` identique à
`gmsk_moduler()` compilé depuis la source C, SNR mesuré −0,01 dB pour 0 dB, refus `iq` sous STREAM,
arrêt propre sur SIGTERM.
