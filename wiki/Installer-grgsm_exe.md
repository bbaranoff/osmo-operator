# Installer grgsm_exe — et le montage gr-gsm

> Version du 2026-10-03. Retour : [Telephone-emule](Telephone-emule.md).

## D'abord : trois choses portent ce nom

| Nom | Ce que c'est | Fait camper le mobile ? | Source |
|---|---|---|---|
| dépôt **`grgsm_exe`** (`https://github.com/bbaranoff/grgsm_exE`) | la couche 1 gr-gsm de qosmo (`calypso_l1_grgsm.c`) compilée **hors QEMU**, 118 Ko, sans ARM ni firmware : « la L1 écrit dans le vide » | **non** — outil de banc et de rejeu | `grgsm_exe/README.md:1-42` |
| commande `/usr/local/bin/grgsm_exe` | enveloppe = `python3 pont/pont_dsp.py --no-record --dsp-port 6702` ; `PONT_DSP_PORT=0 grgsm_exe` = `pont/pont.py` | c'est le **pont** | `c54x_exe/LAUNCH.md:142-158` ; **hors dépôt**, absente d'une installation fraîche |
| « pont grgsm_exe » / montage `--grgsm` | L1 gr-gsm **dans** QEMU (qosmo `--enable-l1-grgsm`) + `pont/pont.py` | **oui** (la chaîne historique) | `osmo-operator/environment/paths.env:24-27`, `start-direct.sh:111` |

Pour brancher un téléphone sur votre réseau en montage gr-gsm, il vous faut la **troisième** :
qosmo + firmware + osmocom-bb (déjà faits sur [Installer-qosmo](Installer-qosmo.md)) et le pont
`pont/pont.py` d'osmo-operator. Le dépôt `grgsm_exe` est optionnel.

## 1. Le dépôt grgsm_exe (outil de banc)

Prérequis : qosmo cloné (sources), gcc. Aucune bibliothèque Osmocom (`Makefile:12` : `-lpthread -lm -lrt`).

```bash
git clone https://github.com/bbaranoff/grgsm_exE /opt/GSM/grgsm_exe
cd /opt/GSM/grgsm_exe
make                         # QOSMO=/chemin/vers/qosmo make   (README.md:41-42, Dockerfile:743-747)
./grgsm_exe --trames 5000    # README.md:6-10
./grgsm_exe --verbeux
```

Vérifier qu'il ouvre ses entrées (`README.md:21-27`) :

```
$ ss -ulnp | grep 473
127.0.0.1:4730   users:(("grgsm_exe",...))    # GSMTAP
127.0.0.1:4731   users:(("grgsm_exe",...))    # SCH
```

Sans rien qui publie sur 4731 ou dans `/dev/shm`, `si_valid` reste faux et le bilan le dit
(`README.md:38-39`). **Ne pas le lancer en même temps que QEMU en montage gr-gsm** : les deux
prennent UDP 4730/4731 (déduit de `README.md:24-27` et `LAUNCH.md:87-88`).

## 2. Le montage gr-gsm (téléphone complet)

Rien de plus à compiler que pour qosmo : le binaire `qemu-system-arm` compilé avec `--enable-l1-grgsm`
**est** la couche 1. Le pont est `pont/pont.py` (python3, numpy, libosmocoding — pas de GNU Radio,
`pont/gsm.py:50,59`).

Lancement par le script du dépôt c54x_exe (il gère les deux montages, `run.sh:4-13`) :

```bash
cd /opt/GSM/c54x_exe
MODE=grgsm PONT=1 PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
```

En montage grgsm, `run.sh` saute l'étape 1 (pas de c54x_exe), lance QEMU **sans**
`CALYPSO_DSP_EXTERN`, attend `backend gr-gsm` dans qemu.log (`run.sh:146-147`), puis osmocon,
mobile, et `pont/pont.py` (`run.sh:37-38`).

Attendu :

| Ligne | Fichier | Source |
|---|---|---|
| `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731` | qemu.log | `calypso_l1_grgsm.c:1207`, `LAUNCH.md:95` |
| `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7` puis `STATS fn=… \| DL bursts=N` | pont.log | `LAUNCH.md:157-158` |

**Attention à la config du mobile** : `run.sh` prend `mobile_pont.cfg` dans les deux montages
(`run.sh:33`), or ce fichier impose `io-tch-format ti` (trames du DSP). En gr-gsm, c'est le pont qui
code la parole en format **rtp** ; avec `ti` « les trames passent […] et le son sort robotisé »
(`mobile_pont.cfg`, commentaire `io-tch-format`). Pour le montage gr-gsm, utiliser la config du banc
`osmo-operator/configs/mobile.cfg` (copiée en `/root/.osmocom/bb/mobile.cfg`, `Dockerfile:1170`) via
`MOBILE_CFG=` — **À CONFIRMER** : cette config contient des gabarits `__…__` remplis par
`generate_configs.sh` ; il faut alors la remplir à la main (IMSI, Ki, `stick`, VTY).

## Dépannage

| Symptôme | Cause / remède | Source |
|---|---|---|
| `la couche 1 gr-gsm ne s'est pas annoncee` | QEMU compilé sans `--enable-l1-grgsm`, ou lancé avec `CALYPSO_DSP_EXTERN=1` | `run.sh:147`, `Dockerfile:698` |
| `pont.py est le pont du montage grgsm : pour le DSP, lancer pont/pont_dsp.py` | `--dsp-port` passé à pont.py | `pont/pont.py:25-26` |
| commande `grgsm_exe` introuvable | l'enveloppe n'est versionnée nulle part (`LAUNCH.md:28`) ; lancer `python3 pont/pont.py` directement | — |
| 79 % de CRC KO, LU en échec | pont hors dépôt (copie ancienne) ; toujours lancer celui de l'arbre osmo-operator | `start-direct.sh` bloc « LE PONT VIENT DU DEPOT » |
