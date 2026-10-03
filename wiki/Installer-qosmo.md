# Installer qosmo (QEMU Calypso) — et le firmware osmocom-bb

> Version du 2026-10-03. Retour : [Telephone-emule](Telephone-emule.md).
> Le dépôt porte son installeur, `qosmo/install.sh` : c'est lui qu'appellent aussi le
> `Dockerfile` (stage `qemu`), `Dockerfile.run`, `start.sh` et `install.sh --telephone`.
> Les commandes manuelles plus bas sont **ce que fait le script**, étape par étape.
> Les numéros `Dockerfile:N` renvoient au Dockerfile du commit `4266c8b`, quand il portait
> encore ces commandes (il appelle désormais l'installeur).

**qosmo** (`https://github.com/bbaranoff/qosmO`) est un fork de QEMU qui ajoute la machine
`calypso` : le SoC TI Calypso (ARM946) sur lequel le **firmware osmocom-bb d'origine,
non patché**, boote (`qosmo/README.md:1-5`). Le même binaire sert aux deux montages : compilé
avec `--enable-l1-grgsm`, il embarque la couche 1 gr-gsm ; lancé avec `CALYPSO_DSP_EXTERN=1`, il
la coupe et délègue au DSP externe `c54x_exe` (`osmo-operator/Dockerfile:679-682`).

Il contient aussi les **sources** que compilent `c54x_exe` et `grgsm_exe`
(`hw/arm/calypso/l1-dsp/`, `l1-grgsm/`, `contrib/hors-qemu/`) : installez-le en premier.

## Avec l'installeur

```bash
git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo
cd /opt/GSM/qosmo
./install.sh --check          # prérequis et état de chaque étape — ne modifie RIEN
sudo ./install.sh --deps      # paquets apt manquants (la liste : ./install.sh --print-deps)
sudo ./install.sh             # venv, configure, make, make install, /usr/local/bin, contrôle
```

Étapes (`./install.sh --list`), chacune avec un « déjà fait ? », ses prérequis, le travail et un
contrôle après coup — le contrat de `osmo-operator/install_modules/_lib/inst.sh` :

| étape | fait | ligne du Dockerfile | déjà fait si |
|---|---|---|---|
| `venv` | `python3 -m venv ~/.venv-qemu` + `pip install tomli` | 694-696 | `tomli` importable dans le venv |
| `configure` | `mkdir -p build && cd build && ../configure --target-list=arm-softmmu --enable-l1-grgsm --prefix=… --disable-werror --disable-docs` | 697-699 | `build/config.log` porte **les mêmes** options |
| `build` | `make -j$(nproc)` dans `build/` (incrémental) | 700 | — (toujours rejoué, ne refait que ce qui a bougé) |
| `install` | `make install` (prefix `/opt/GSM/qemu-install`) | 701 | binaire installé identique à `build/` |
| `bin` | copie `qemu-system-arm` et `qosmo` dans `/usr/local/bin` | 702-703 | copies identiques ; *sans objet* si le dossier n'est pas inscriptible |
| `verify` | `build/qemu-system-arm -M help` doit lister `calypso … (couche 1 : grgsm)` | — | — |

Options (et variable équivalente) : `--prefix DIR` (`PREFIX`, défaut `$GSM_ROOT/qemu-install`),
`--build-dir DIR` (`BUILD_DIR`, construire hors de l'arbre — jamais l'arbre source lui-même :
`configure` lancé depuis la racine efface un `build/` qu'il a créé, `configure:16-45`),
`--venv DIR|none` (`VENV`, défaut `~/.venv-qemu`), `--bin-dir DIR|none` (`BIN_DIR`, défaut
`/usr/local/bin`), `--destdir DIR` (installer sous une autre racine, comme l'ISO), `--cc gcc-13`
(compilateur imposé : le `build/` d'une image a été configuré avec gcc-13, `Dockerfile.run`),
`-j N`, `--only ÉTAPES`, `--skip ÉTAPES`, `--reinstall`, `--with-deps`, `-v` (sortie à l'écran ;
sinon un journal par étape dans `/tmp/qosmo-install/`, dont la fin s'affiche en cas d'échec).
`GSM_ROOT` (défaut `/opt/GSM`) fixe le préfixe par défaut.

Sans root : `./install.sh` marche si `/opt/GSM` vous appartient ; l'étape `bin` est alors
*sans objet* (binaires laissés dans `$PREFIX/bin`), ou `--prefix ~/qemu-calypso --bin-dir none`.

## Ce que fait le script, à la main

### Prérequis

Ubuntu 24.04 (base du banc, `Dockerfile:11-15`). Paquets (`./install.sh --print-deps`, extraits
de `Dockerfile:159,166,189-190`) :

```bash
sudo apt-get install -y --no-install-recommends \
  build-essential git pkg-config python3 python3-venv python3-pip \
  libglib2.0-dev libpixman-1-dev libslirp-dev ninja-build socat
```

`socat` sert à interroger le moniteur QEMU (`qosmo/run_modules/40-qemu.sh:91-96`).
`./install.sh --check` contrôle ce qui compte vraiment au `configure` (cc, make, ninja,
pkg-config, `glib-2.0` et `pixman-1` vus de pkg-config, module `venv`/`ensurepip`) : un paquet
absent mais installé autrement n'est qu'une note.

### Compiler

Repris de `osmo-operator/Dockerfile:691-705` :

```bash
sudo mkdir -p /opt/GSM && sudo chown "$USER" /opt/GSM
git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo
cd /opt/GSM/qosmo
python3 -m venv ~/.venv-qemu && . ~/.venv-qemu/bin/activate
pip install --no-cache-dir tomli
mkdir -p build && cd build
../configure --target-list=arm-softmmu --enable-l1-grgsm \
    --prefix=/opt/GSM/qemu-install --disable-werror --disable-docs
make -j"$(nproc)"
make install
```

Le script (étape `bin`) copie ensuite les binaires dans le PATH (`Dockerfile:702-703`) :

```bash
sudo cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm
sudo cp /opt/GSM/qemu-install/bin/qosmo           /usr/local/bin/qosmo
```

> **Gardez l'arbre et `build/`.** Les lanceurs utilisent `/opt/GSM/qosmo/build/qemu-system-arm`
> (`c54x_exe/run.sh:28`, `qosmo/environnement/bench.env:4`), et c54x_exe/grgsm_exe compilent les
> sources de cet arbre. Le Dockerfile emporte l'arbre entier, build/ compris (`Dockerfile:686-688`).

Variantes de configure documentées (`qosmo/README.md:9-13`) : sans option (plateforme nue),
`--enable-l1-dsp` (C54x **dans** QEMU, non utilisé par le banc actuel). Le banc n'utilise que
`--enable-l1-grgsm`.

### Vérifier

```bash
./install.sh --only verify    # -M help doit lister « calypso … (couche 1 : grgsm) »
ls -la /opt/GSM/qosmo/build/qemu-system-arm
/opt/GSM/qosmo/build/qemu-system-arm -M help | grep calypso
qosmo -V          # lanceur C : « qosmo <version> (<arbre>) » (tools/qosmo/qosmo.c, option -V)
```

La description de la machine dit quelle couche 1 est compilée
(`hw/arm/calypso/calypso_mb.c:111`) : `couche 1 : grgsm` attendu.

Démarrage de la machine (nécessite le firmware, section suivante) — commande de
`c54x_exe/LAUNCH.md:75-79`, montage grgsm (sans `CALYPSO_DSP_EXTERN`) :

```bash
/opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 \
  -display none -parallel none -serial pty -serial pty \
  -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
  -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf
```

Attendu sur stderr (`LAUNCH.md:89-96`) :

```
char device redirected to /dev/pts/N (label serial0)
[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731
```

et `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock` → `VM status: running`
(`40-qemu.sh:93-95`). Arrêter avec Ctrl-C.

## Firmware et osmocom-bb

QEMU exécute `layer1.highram.elf` ; osmocon charge `layer1.highram.bin` par romload ; le mobile
parle L1CTL via osmocon. Ces trois pièces viennent d'osmocom-bb.

**Firmware prébuilt** (`Dockerfile:585-588` ; c'est « le seul endroit consulté », `Dockerfile:590-598`) —
un clone, rien à compiler. Depuis osmo-operator : `sudo ./install.sh --only firmware`
(`install_modules/45-calypso.sh`) ; à la main :

```bash
git clone --depth 1 https://github.com/bbaranoff/firmware /opt/GSM/firmware
ls /opt/GSM/firmware/board/compal_e88/layer1.highram.{elf,bin}
```

**osmo-gapk, avant osmocom-bb** (le mobile du banc utilise `tch-voice io-handler gapk`,
`c54x_exe/mobile_pont.cfg`) — `Dockerfile:445-452` :

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk
cd osmo-gapk && autoreconf -fi && ./configure --enable-alsa && make -j"$(nproc)" && sudo make install && sudo ldconfig
```

(paquet `libasound2-dev` requis, `Dockerfile:169`.)

**osmocom-bb, outils hôte seulement** (`Dockerfile:548-558`) — exige libosmocore installé :

```bash
cd /opt/GSM && git clone https://gitea.osmocom.org/phone-side/osmocom-bb
git -C osmocom-bb apply /opt/GSM/osmo-operator/patches/osmocom-bb-clck-gen-frame-tolerance.patch   # optionnel : ne touche que fake_trx (Dockerfile:541-547)
cd osmocom-bb/src && make nofirmware
sudo install -m755 host/layer23/src/mobile/mobile /usr/local/bin/mobile    # Dockerfile:1145-1149
```

`osmocon` reste dans l'arbre : `/opt/GSM/osmocom-bb/src/host/osmocon/osmocon` (chemin attendu par
`c54x_exe/run.sh:31` et `qosmo/environnement/bench.env:10`).

Vérifier : `ls /opt/GSM/osmocom-bb/src/host/osmocon/osmocon && mobile --version` (**À CONFIRMER** :
option `--version` de mobile).

## Variables utiles

| Variable | Défaut | Rôle | Source |
|---|---|---|---|
| `CALYPSO_DSP_EXTERN=1` | absent | coupe la L1 gr-gsm, partage l'API RAM avec `c54x_exe` | `LAUNCH.md:84-86` |
| `CALYPSO_PONT_LOCKSTEP=1` | posé par run.sh si `LOCKSTEP=1` | QEMU attend le DSP à chaque trame | `c54x_exe/run.sh:56-57` |
| `CALYPSO_PONT_RETRY_DIV` | 64 (run.sh) | cadence de relance vers le DSP | `run.sh:130-133` |
| `CALYPSO_GDB_PORT` | 1234 | gdbstub ARM (`off` pour couper) | `40-qemu.sh:59` |

Les ~300 variables `CALYPSO_*` sont décrites dans `qosmo/hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md`
(`qosmo/environnement/README.md:42-45`) ; le manifeste réellement appliqué est imprimé par QEMU
(`grep calypso-manifest qemu.log`).

## Dépannage

| Symptôme | Cause / remède | Source |
|---|---|---|
| CPU à 0, plantage en `0x840000`, osmocon ne charge rien | `-kernel` manquant | `LAUNCH.md:82-83` |
| `QEMU a démarré puis s'est arrêté` | machine ou firmware invalide ; voir la fin de `qemu.log` | `40-qemu.sh:102-106` |
| fenêtre SDL « parallel0 » qui prend le clavier | oublier `-display none -parallel none` | `40-qemu.sh:60-67` |
| `binaire QEMU absent` | build non fait ; `./install.sh --only build` (ou `ninja -C build qemu-system-arm`) | `40-qemu.sh:10-11` |
| `[FAIL] configure … manque : glib-2.0 vu de pkg-config` | paquet `-dev` absent : `sudo ./install.sh --deps` | `install.sh --check` |
| `[SKIP] qemu-system-arm et qosmo dans le PATH (… non inscriptible)` | pas root : binaires dans `$PREFIX/bin`, ou `--bin-dir DIR` | `install.sh`, étape `bin` |
| ninja échoue dès la première unité dans un `build/` venu d'une image | `build/` configuré avec gcc-13, `cc` = gcc-11 : `./install.sh --only build --cc gcc-13` | `Dockerfile.run:171-175` |
| `/usr/local/bin/qosmo-grgsm` au lieu de `qosmo` | repli `make -C tools/qosmo-launch install` de `start-direct.sh` (dossier non versionné) ; utiliser `make install` dans `build/` | `start-direct.sh:692-694` |
| `osmocon` bloqué à mi-téléchargement | un osmocon tué en plein romload laisse le stub UART à mi-bloc : relancer QEMU puis osmocon | `LAUNCH.md:120-121` |
