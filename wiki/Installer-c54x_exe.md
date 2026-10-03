# Installer c54x_exe (le DSP Calypso, mask-ROM TI) et le pont DSP

> Version du 2026-10-03. Retour : [Telephone-emule](Telephone-emule.md). Prérequis : [qosmo](Installer-qosmo.md).
> Le dépôt porte son installeur, `c54x_exe/install.sh` : c'est lui qu'appellent aussi le
> `Dockerfile` (stage `l1`), `Dockerfile.run`, `start.sh`, l'ISO et `install.sh --telephone`.
> Les commandes manuelles plus bas sont **ce que fait le script**, étape par étape.
> Les numéros `Dockerfile:N` renvoient au Dockerfile du commit `4266c8b`, quand il portait
> encore ces commandes.

`c54x_exe` (`https://github.com/bbaranoff/c54x_exe`) exécute la **ROM masquée d'origine du
TMS320C54x** des basebands Calypso, comme un processus Linux. En montage DSP, le firmware
osmocom-bb sous QEMU lui parle par la vraie API RAM partagée, trame par trame
(`c54x_exe/README.md:1-9`). Il ne contient pas le cœur C54x : il **compile les sources de qosmo**
(`Makefile:1-7`, `README.md:57-61`).

## Avec l'installeur

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
./install.sh --check      # qosmo cloné ? libosmocoding vu de pkg-config ? ROM ? — ne modifie RIEN
sudo ./install.sh         # make, ROM en /opt/GSM et rom/, puis c54x_exe --trames 200
```

| étape | fait | ligne du Dockerfile | déjà fait si |
|---|---|---|---|
| `build` | `make QOSMO=…` (avec `--portable` : `CFLAGS` sans `-march=native`) ; contrôle `ldd` | 733-735 | — (le Makefile recompile à chaque appel, `Makefile:46-52`) |
| `rom` | recopie une ROM **déjà vérifiée** trouvée sur la machine, sinon `rom/fetch-rom.sh --dest …` (téléchargement, conversion, somme) | 736 | les 6 ROM + `Registers` présentes et conformes à `rom/SHA256SUMS.3606` dans chaque destination |
| `verify` | `c54x_exe --rom-dir … --trames 200` : « N sections chargees » puis « bilan sur 200 trames » | — | — |

Options (et variable) : `--qosmo DIR` (`QOSMO`, défaut `$GSM_ROOT/qosmo`), `--rom-dir DIR`
répétable (`ROM_DIR`, défaut `$GSM_ROOT` **et** `rom/` du dépôt, comme `Dockerfile:736`),
`--portable` (`PORTABLE=1`, les `CFLAGS` de `Dockerfile:735`), `--dest DIR` (copie le dépôt sans
`.git` ni binaires dans `DIR` et y construit : **le binaire en service n'est pas réécrit**),
`--only`, `--skip`, `--reinstall`, `--with-deps`, `-v`. Journaux : `/tmp/c54x_exe-install/<étape>.log`.

Sans root : `ROM_DIR=$HOME/calypso-rom ./install.sh`, puis lancer `c54x_exe --rom-dir $HOME/calypso-rom`
(le défaut du binaire est `/opt/GSM`, `src/main.c:79`).

Le contrôle `--trames 200` tourne sans `--arm` : API RAM **privée**, ni `/dev/shm`, ni socket, ni
`/tmp/c54x-pont` (vérifié dans un espace de montage privé) — il ne dérange pas un banc en marche.

Échec typique, explicite :

```
[FAIL] Compilation de c54x_exe (sources de qosmo) (manque : libosmocoding + libosmocore vus de pkg-config)
       → export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig  (libosmocore est en /usr/local, Dockerfile:92-94)
```

## Ce que fait le script, à la main

### Prérequis

- qosmo cloné (défaut `/opt/GSM/qosmo`) — [Installer-qosmo](Installer-qosmo.md).
- gcc, make, pkg-config, **libosmocore + libosmocoding** visibles de pkg-config (`Makefile:14`).
  Contrôle avant de compiler (le Makefile masque l'erreur, `2>/dev/null`) :
  ```bash
  pkg-config --cflags --libs libosmocoding libosmocore
  ```
  Si vide : `export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` (valeur du Dockerfile, `Dockerfile:92-94`).
- python3 + curl ou wget pour la ROM (`rom/fetch-rom.sh:47-52`).
- Pour le pont : python3, `python3-numpy` (`pont/record.py:6`), `libosmocoding.so` et `libosmogsm.so`
  chargées par ctypes (`pont/gsm.py:50,59`) — donc `ldconfig` à jour si libosmocore est en `/usr/local`.

### Compiler (étape `build`)

```bash
git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe
cd /opt/GSM/c54x_exe
make                                  # ou : make QOSMO=/chemin/vers/qosmo   (README.md:63-68)
```

Pour un binaire qui doit tourner sur **un autre CPU** que celui du build, retirer `-march=native`
comme le Dockerfile (`Dockerfile:726-735`) :

```bash
make QOSMO=/opt/GSM/qosmo \
  CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"
```

`make` recompile **à chaque appel** (une seule commande cc, pas de `.o`) : c'est voulu, les sources
viennent d'un autre dépôt (`Makefile:42-52`).

### La ROM du DSP (étape `rom`)

Pas dans le dépôt. `rom/fetch-rom.sh` télécharge le dump FreeCalypso 3606, le convertit
(`tools/dsp_txt2bin.py`) et vérifie `rom/SHA256SUMS.3606` (`README.md:113-119`). Le binaire la lit
dans `--rom-dir`, défaut **`/opt/GSM`** (`src/main.c:79,105`). Commande du Dockerfile (`:736`) :

```bash
bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom
```

Attendu (`fetch-rom.sh:46,57,65`) :

```
telechargement : ftp://ftp.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt
somme de controle verifiee (SHA256SUMS.3606)
ROM DSP 3606 ecrite dans /opt/GSM
ROM DSP 3606 ecrite dans /opt/GSM/c54x_exe/rom
```

Relancé, il dit `ROM DSP 3606 deja en place et verifiee`. Options : `--version 3311` (D-Sample),
`--force`, miroir par `FREECALYPSO_URL=` (`fetch-rom.sh:2-15,30`). L'installeur recopie d'abord
une ROM déjà vérifiée trouvée sur la machine (ce que faisait `cp c54x_exe/rom/*.bin /opt/GSM/` dans
`Dockerfile.run`) : pas de réseau si elle est là.

### Vérifier le DSP seul (étape `verify`)

```bash
./c54x_exe --trames 200    # la ROM seule, sans ARM : boote-t-elle ? (README.md:66)
./c54x_exe --help
```

Test d'ISA optionnel (`Makefile:54-61`) : `make isa_test && ./isa_test tools/isa_tests.txt 2>/dev/null`.

## Le pont DSP

Le pont qui relie votre osmo-bts-trx au DSP est dans **osmo-operator**, pas ici
(`README.md:82-83`, `run.sh:37-41`). Il suffit de l'arbre, rien à compiler :

```bash
git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator
cd /opt/GSM/osmo-operator && python3 pont/pont_dsp.py --help
```

`pont_dsp.py` exige `--dsp-port 6702` (`pont/README.md` §0). Il lit la table des timeslots dans
`PONT_BSC_CFG` (défaut `/etc/osmocom/osmo-bsc.cfg`) : pointez-le sur **votre** config BSC.

## Lancer

Contre votre pile déjà démarrée (osmo-bts-trx compris) :

```bash
cd /opt/GSM/c54x_exe
PONT=1 INSNS=120000 CALYPSO_BSP_STREAM=1 CALYPSO_RHEA_DMA_XFER=1 \
  PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg ./run.sh
./run.sh --status | --logs | --stop        # README.md:76-79
```

- `PONT=1` : sans lui, pas de pont, aucun burst n'arrive (`run.sh:197-198`).
- `INSNS=120000`, `CALYPSO_BSP_STREAM=1`, `CALYPSO_RHEA_DMA_XFER=1` : ce que pose `start-direct.sh`
  avant de passer la main à ce `run.sh` (bloc « LE BANC DSP : RÉGLAGES MESURÉS ») ; le défaut de
  `run.sh:49` est 16000, « TCH mesuré jusqu'à 87000 insn/trame ». `CALYPSO_RHEA_DMA_XFER` : « sans lui la
  page API n'est jamais remplie : pas de SB, pas de BCCH, pas de SI ».
- Autres variables : `MODE`, `LOCKSTEP` (1), `VERB`, `IQ`, `AMP`, `QOSMO`, `FIRMWARE_ELF`, `FIRMWARE_BIN`,
  `OSMOCON`, `MOBILE`, `MOBILE_CFG`, `PONT_PY`, `RUNDIR`, `L2_SOCK`, `C54X_BIN` (`run.sh:19-21`, `README.md:144`).
- Journaux : `/tmp/c54x-pont/{dsp,qemu,osmocon,mobile,pont}.log`, sessions archivées dans
  `/tmp/c54x-pont/archives/<date>/` (`run.sh:249-270`).

Le détail processus par processus : [Lancer-a-la-main](Lancer-a-la-main.md).

Variante tout-en-un pour une pile **systemd** : `./run_real.sh [--secondes N]` (démarre
`osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc`, redémarre `osmo-bts-trx`, lance `run.sh` avec
`INSNS=60000`, observe 120 s et imprime un verdict). `./run_real.sh --stop`.

## Ce qui prouve que ça marche

| Ligne | Fichier | Source |
|---|---|---|
| `pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)` | dsp.log | `src/pont.c:2114` |
| `pont : RESET #1 (DL_STATUS=...) fn=... pc=0xff80` puis `pont : DSP boote (premier IDLE)` | dsp.log | `src/pont.c:1608,1921`, `LAUNCH.md:97` |
| `[trx] pont DSP : API RAM partagee (...) + socket /tmp/calypso_dsp.sock` | qemu.log | `qosmo/hw/arm/calypso/calypso_trx.c:318` |
| `[montant] RACH ra=0x.. bsic=..` ; `pont.log` passe de `rach=0` à `rach=N` | dsp.log / pont.log | `LAUNCH.md:66-67` |
| `[montant] TCH : le firmware poste la tache 13 a fn=..., BSP bascule sur TS2` | dsp.log (en appel) | `LAUNCH.md:68-69` |

## Dépannage

| Symptôme | Cause / remède | Source |
|---|---|---|
| link échoue sur `gsm0503_*` | pkg-config ne trouve pas libosmocoding (erreur masquée) | `Makefile:14` |
| `Illegal instruction` au lancement | binaire `-march=native` venu d'une autre machine : recompiler ici (`./install.sh`), ou `--portable` pour un binaire qui voyage | `Dockerfile:726-728`, `iso_modules/52-qemu.sh` |
| `c54x_exe n'a pas ouvert /tmp/calypso_dsp.sock` | ROM absente de `--rom-dir` ? `./install.sh --only rom` (ou `rom/fetch-rom.sh --dest /opt/GSM`) ; voir dsp.log | `run.sh:104` |
| reconstruire sans toucher au binaire d'un banc qui tourne | `./install.sh --dest /tmp/c54x-neuf` puis comparer / remplacer à l'arrêt | `install.sh --dest` |
| `somme de controle differente` | dump modifié ou mauvaise version | `fetch-rom.sh:55-56` |
| `QEMU n'a pas rejoint le DSP` | QEMU sans `CALYPSO_DSP_EXTERN=1`, ou DSP pas encore prêt | `run.sh:144-145` |
| `pont.py ne s'est pas annonce` | `PONT_PY` hérité pointant sur `pont.py` (gr-gsm) : `env -u PONT_PY` | `run.sh:206`, `start-direct.sh` `banc_dsp()` |
| `FBSB RESP: result=255` en boucle | pas de pont ou pas de BTS : normal sans réseau | `LAUNCH.md:138` |
| `DL bursts=0` | aucun BTS n'émet vers 5700-5702 : vérifier la section `phy` de votre osmo-bts-trx | `LAUNCH.md:157-158` |
| SB décodé une fois sur trois à cinq | limite connue ; `L23_SYNC_RETRIES_SELECTION=8` posé par run.sh | `README.md:17-19`, `run.sh:183-189` |
| `le port VTY 4347 ... deja pris` | autre mobile ; changer `bind 127.0.0.1` de la cfg | `run.sh:177-181` |
| état sale après un crash | `./run.sh --stop` purge sockets et `/dev/shm/calypso_*` | `run.sh:210-237` |

## À CONFIRMER

- (corrigé le 2026-10-03) `GDB_TELNET_PY` pointait sur `/opt/GSM/qosmo-dsp/tools/gdb-telnet.py`
  (dépôt disparu) : `run.sh:48` prend désormais `$QOSMO/tools/gdb-telnet.py`, la console
  `telnet 0 44444` démarre avec l'étape 2 (`GDB=0` pour s'en passer).
- `mobile_pont.cfg` envoie le GSMTAP vers `172.20.0.1` (passerelle docker du banc) : à remplacer par
  `127.0.0.1` hors conteneur.
- Valeur `INSNS` à retenir (16000 / 60000 / 80000 / 120000 selon la source).
