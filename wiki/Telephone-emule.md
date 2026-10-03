# Installer le téléphone émulé sur sa propre pile Osmocom

> Version du 2026-10-03. Chaque commande vient d'un script ou d'un README des dépôts, la
> source est citée. Ce qui n'a pas pu être vérifié est marqué **À CONFIRMER**.

Cette page s'adresse à qui a **déjà** un réseau Osmocom (osmo-bsc, osmo-msc, osmo-hlr,
osmo-stp, osmo-mgw, installés par paquets ou depuis les sources) et veut y brancher un
**téléphone Calypso émulé**, sans l'ISO, sans Docker et sans la pile d'osmo-operator.

| Page | Contenu |
|---|---|
| **Telephone-emule** (ici) | vue d'ensemble, prérequis de **votre** réseau, ordre d'installation |
| [Installer-qosmo](Installer-qosmo.md) | QEMU, machine Calypso (l'ARM + firmware osmocom-bb) |
| [Installer-c54x_exe](Installer-c54x_exe.md) | le DSP C54x hors QEMU, sa ROM TI, le pont `pont_dsp.py` |
| [Installer-grgsm_exe](Installer-grgsm_exe.md) | le montage gr-gsm, et ce que désigne vraiment « grgsm_exe » |
| [Lancer-a-la-main](Lancer-a-la-main.md) | la chaîne lancée processus par processus, commandes dépliées |
| [installer-osmo-jusquau-dsp.ipynb](installer-osmo-jusquau-dsp.ipynb) | notebook : tout le Dockerfile rejoué en natif, de apt jusqu'à un appel en DSP |

## Ce qui tourne côté téléphone

```
 votre réseau                              ce que vous installez ici
 ───────────────                           ─────────────────────────────────────────────
 osmo-bsc / msc / hlr / stp / mgw
        │ Abis/IPA
 osmo-bts-trx ── TRXD/TRXC/CLK UDP 5700-5702 ──▶ pont_dsp.py ── UDP 6702 ──▶ c54x_exe (DSP + ROM TI)
 (5800-5802)                                    (osmo-operator/pont)          │ /dev/shm/calypso_api_ram
                                                                             │ /tmp/calypso_dsp.sock
                                       osmocon ◀── pty série ── qosmo (QEMU -M calypso, CALYPSO_DSP_EXTERN=1)
                                          │ /tmp/osmocom_l2           └─ layer1.highram.elf (osmocom-bb)
                                       mobile (osmocom-bb, VTY 4347)
```

Schéma repris de `c54x_exe/README.md:25-35`. Deux montages existent (`c54x_exe/LAUNCH.md:6-9`) :

| montage | couche 1 | pont | état (2026-10-03) |
|---|---|---|---|
| **dsp** (défaut depuis le 2026-10-01) | `c54x_exe --arm`, vraie mask-ROM TI | `pont/pont_dsp.py --dsp-port 6702` | camp, LU, SMS MO/MT, appels MO/MT, A5/1 (`c54x_exe/README.md:11-21`) ; sync SB parfois en plusieurs essais |
| **grgsm** | gr-gsm compilée dans QEMU | `pont/pont.py` | la chaîne historique, « va jusqu'à l'appel voix » (`wiki/Home.md`, options) |

## Ce que votre réseau doit fournir

Le téléphone est figé sur une cellule et un abonné précis. Soit votre réseau s'y conforme,
soit vous changez les valeurs côté téléphone (colonne de droite).

| Élément | Attendu | Où le changer côté téléphone |
|---|---|---|
| BTS | **osmo-bts-trx** sur la même machine (testé : osmo-bts 1.10.0, `osmo-operator/Dockerfile:272`) | — |
| Liaison TRX | config BTS : `phy 0` / `osmotrx ip local 127.0.0.1` / `osmotrx ip remote 127.0.0.1`, **sans** `base-port` (défauts 5800 local, 5700 distant) — `osmo-operator/configs/osmo-bts-trx.cfg:28-34` | `PONT_TRX_BIND`, `PONT_TRX_BASE` (`pont/config.py:48-49`) |
| Bande, ARFCN | DCS1800, ARFCN **514** | `PONT_ARFCN` + ligne `stick 514` de `c54x_exe/mobile_pont.cfg` |
| BSIC | **7** | `PONT_BSIC` (`pont/config.py:47`) |
| Timeslots du 1er `bts` du BSC | TS0 `CCCH+SDCCH4`, TS1 `SDCCH8`, TS2-7 `TCH/F` (`osmo-operator/configs/osmo-bsc.cfg:236-262`) | le pont les **lit** dans `PONT_BSC_CFG` (défaut `/etc/osmocom/osmo-bsc.cfg`, `pont/gsm.py:223-242`) ; fichier illisible → table ci-contre par défaut |
| PLMN | MCC 001, MNC 01 | `rplmn 001 01` dans `mobile_pont.cfg` |
| Abonné | IMSI `001010001000001`, COMP128v1, Ki `00112233445566778899aabbccdd0101` | `test-sim` dans `mobile_pont.cfg` |

Provisionner l'abonné dans osmo-hlr (mêmes commandes VTY que `qosmo/run_modules/21-abonnes-hlr.sh:73-75`) :

```
telnet 127.0.0.1 4258
enable
subscriber imsi 001010001000001 create
subscriber imsi 001010001000001 update msisdn 100101
subscriber imsi 001010001000001 update aud2g comp128v1 ki 00112233445566778899aabbccdd0101
```

Le MSISDN `100101` est celui du banc (`wiki/Home.md`, plan de numérotation) ; mettez le vôtre.

**Ports et fichiers que le téléphone occupe** sur la machine (à ne pas prendre dans votre pile) :
UDP 5700-5702 (pont), UDP 6702 (DSP), UDP 4730/4731 (L1 gr-gsm, montage grgsm), TCP 4347 (VTY mobile),
TCP 1234 (gdbstub QEMU), TCP 44444 (console gdb), `/tmp/osmocom_l2`, `/tmp/osmocom_sap`, `/tmp/ms_data`,
`/tmp/calypso_dsp.sock`, `/tmp/qemu-monitor-pont.sock`, `/dev/shm/calypso_*`, `/dev/shm/pont.log`,
`/tmp/c54x-pont/` (sources : `c54x_exe/run.sh:42-62`, `c54x_exe/mobile_pont.cfg`, `pont/config.py`).

## Ordre d'installation

Tout se fait sous une racine commune, `/opt/GSM` par défaut (chemins codés dans les Makefiles et
`run.sh`, tous surchargeables : `QOSMO=`, `FIRMWARE_ELF=`, `OSMOCON=`…).

1. **Dépendances système** — sous-ensemble de la liste du Dockerfile (`osmo-operator/Dockerfile:156-205`)
   utile au téléphone ; voir chaque page.
2. **libosmocore** (avec libosmocoding) — vous l'avez déjà si votre pile est compilée ; sinon paquets
   `libosmocore-dev` du dépôt Osmocom (**À CONFIRMER** : versions ; le banc utilise 1.12.1, `Dockerfile:261`).
3. **osmo-gapk** puis **osmocom-bb** (osmocon, mobile) et le **firmware** prébuilt — voir [Installer-qosmo](Installer-qosmo.md#firmware-et-osmocom-bb).
4. **qosmo** — [Installer-qosmo](Installer-qosmo.md).
5. **c54x_exe + ROM DSP + pont** — [Installer-c54x_exe](Installer-c54x_exe.md).
6. (optionnel) **montage gr-gsm / grgsm_exe** — [Installer-grgsm_exe](Installer-grgsm_exe.md).
7. **Lancer** : `PONT=1 ./run.sh` dans `c54x_exe` (`c54x_exe/README.md:76-78`) ou à la main,
   [Lancer-a-la-main](Lancer-a-la-main.md).

## La preuve que ça marche

Dans l'ordre (détails dans [Lancer-a-la-main](Lancer-a-la-main.md)) :

| Étape | Ligne attendue | Fichier |
|---|---|---|
| DSP prêt | `pont : en attente de l'ARM sur /tmp/calypso_dsp.sock` | `/tmp/c54x-pont/dsp.log` |
| QEMU relié au DSP | `[trx] pont DSP : API RAM partagee ...` | `/tmp/c54x-pont/qemu.log` |
| firmware chargé | `Received branch ack, your code is running now!` | `/tmp/c54x-pont/osmocon.log` |
| pont prêt | `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7` | `/tmp/c54x-pont/pont.log` (lien vers `/dev/shm/pont.log`) |
| BTS vue par le pont | `BTS 127.0.0.1 : horloge armee vers le port 5800` (`pont/trx.py:185`) | idem |
| cellule lue | `New SYSTEM INFORMATION ...`, `lai=001-01-<LAC>` (`c54x_exe/run_real.sh`) | `/tmp/c54x-pont/mobile.log` |
| camp | `C3 camped normally` dans `show ms` (`tests/modules/60-camp.sh:10`) | VTY 4347 |
| LU | `LOCATION UPDATING ACCEPT` (`run_real.sh`) ; `MM idle, normal service` | `mobile.log` / `show ms` |
| appel | `call 1 600` puis `call control state: ACTIVE` (`tests/modules/_lib.sh:48,83`) | VTY 4347 |

`c54x_exe/run_real.sh` automatise ces contrôles contre une pile lancée par **systemd**
(`systemctl start osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc`, `systemctl restart osmo-bts-trx`) et
imprime un verdict `VRAI : lai=… = la config du reseau`. Il lit MCC/MNC dans `/etc/osmocom/osmo-msc.cfg`
et LAC/BSIC dans `/etc/osmocom/osmo-bsc.cfg` : à adapter si vos configs sont ailleurs.

## À CONFIRMER (globalement)

- Compatibilité avec un osmo-bts-trx **différent de 1.10.0** (négociation TRXD : le pont répond à
  `SETFORMAT` en écho, `pont/trx.py:182`, et ne lit que du TRXD v0, `trx.py:199`).
- Les patchs `osmo-bts/hlr/msc-force-rand-toy` du banc (`Dockerfile:358-414`) ne sont **pas**
  nécessaires au téléphone (ils rendent le RAND reproductible) — non testé sans.
- Un osmo-bts-trx **sur une autre machine** que le téléphone : non prévu (le pont renvoie l'horloge à
  l'IP d'origine de la commande CTRL, `trx.py:184`, ça pourrait marcher avec `PONT_TRX_BIND=0.0.0.0`).
- Audio en appel : `mobile_pont.cfg` utilise ALSA `gsm_out`/`gsm_in`, définis par
  `osmo-operator/configs/asound.conf` (greffon `libasound2-plugins` + PulseAudio). Sans eux,
  comportement du mobile en appel non vérifié.
