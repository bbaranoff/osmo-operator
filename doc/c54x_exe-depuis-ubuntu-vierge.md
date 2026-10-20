# c54x_exe depuis une Ubuntu 24.04 vierge

Oct 20, 2026 · Bastien Baranoff

## Ce que montre cette page

En une vingtaine de minutes, le cœur TMS320C54x émulé de `c54x_exe` charge la mask-ROM TI d'un vrai Calypso et l'exécute, sans QEMU, sans ARM, sans réseau GSM.

C'est le hello world du DSP : il prouve que le cœur exécute du vrai code TI. Il ne prouve pas que le DSP décode quoi que ce soit, puisque aucun burst n'est injecté. Le montage complet (ARM sous QEMU, BTS, pont, appel voix) est décrit en fin de page et vit dans [osmo-operator](https://github.com/bbaranoff/osmo-operator).

Tout se fait en root ou avec `sudo` ; les chemins `/opt/GSM/…` sont ceux que les Makefile et les scripts attendent par défaut.

## 1. Prérequis (Ubuntu 24.04)

Une ligne `apt` suffit : le compilateur, `git`, `curl` pour les ROM, et `libosmocore` (qui contient `libosmocoding`, utilisée par `calypso_bsp.c`).

```bash
sudo apt update
sudo apt install -y build-essential git curl pkg-config libosmocore-dev
sudo mkdir -p /opt/GSM
```

Vérifier que `libosmocoding` est bien là :

```bash
pkg-config --modversion libosmocoding
```

Si `pkg-config` ne la trouve pas, la version de `libosmocore` du dépôt Ubuntu est trop ancienne ou incomplète ; installer alors `libosmocore-dev` depuis le dépôt nightly d'Osmocom (voir [osmocom.org](https://osmocom.org/projects/cellular-infrastructure/wiki/Binary_Packages)).

## 2. Les sources de qosmo

`c54x_exe` ne recopie pas le cœur C54x : il compile directement les sources de [qosmo](https://github.com/bbaranoff/qosmo) (`calypso_c54x.c` et ses voisins) avec ~120 lignes de doublures d'en-têtes QEMU. Il faut donc le dépôt sur disque, mais pas le construire.

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/qosmo
```

Aucun `configure`, aucun `make` ici. Si qosmo est ailleurs que `/opt/GSM/qosmo`, passer `QOSMO=/chemin` au `make` de l'étape suivante.

## 3. Cloner et compiler c54x_exe

La compilation prend moins d'une minute et produit un seul binaire, `c54x_exe`, à la racine du dépôt.

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/c54x_exe
cd c54x_exe
make QOSMO=/opt/GSM/qosmo \
     CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args \
             -Wno-unused-function -Wno-unused-variable \
             -Wno-unused-but-set-variable -Wno-sign-compare"
```

Ce `CFLAGS` est celui du Dockerfile d'osmo-operator : il garde les erreurs de format bloquantes et rend muets les avertissements de variables inutilisées, nombreux dans les sources QEMU reprises telles quelles. Un `make` nu marche aussi mais sort beaucoup plus de bruit.

`make` reconstruit le binaire à chaque appel (cible `.PHONY`) ; pas besoin de `make clean` après un changement dans qosmo.

Vérifier :

```bash
./c54x_exe --help | head
```

## 4. Les ROM DSP, depuis FreeCalypso

La mask-ROM du C54x n'est pas dans le dépôt : elle vient du dump publié par le projet [FreeCalypso](https://www.freecalypso.org/) (Mychaela Falconia), sur son FTP public. Le script `rom/fetch-rom.sh` la télécharge et la découpe en 7 sections au format attendu par `--rom-dir`.

```bash
cd /opt/GSM/c54x_exe
export FREECALYPSO_URL=ftp://ftp.freecalypso.org/pub/GSM/Calypso
bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom
curl -fsS --retry 2 -o /opt/GSM/calypso_dsp.txt "$FREECALYPSO_URL/dsp-rom-3606-dump.txt"
cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt
```

`3606` est la version de ROM DSP du Calypso des Motorola C1xx ; c'est aussi la valeur que la L1 DSP écrit dans l'API RAM au boot, ce qui permettra de vérifier plus loin que la bonne ROM tourne.

Après le script, `/opt/GSM` doit contenir exactement ces 7 fichiers :

```bash
ls -l /opt/GSM/calypso_dsp.*.bin
# calypso_dsp.PROM0.bin  calypso_dsp.PROM1.bin  calypso_dsp.PROM2.bin
# calypso_dsp.PROM3.bin  calypso_dsp.DROM.bin   calypso_dsp.PDROM.bin
# calypso_dsp.Registers.bin
```

Si `curl` refuse le FTP (certaines builds le compilent sans), le dump se télécharge à la main depuis le même répertoire sur ftp.freecalypso.org et se passe à `fetch-rom.sh` en local.

## 5. Premier run : la ROM tourne

```bash
cd /opt/GSM/c54x_exe
./c54x_exe --trames 200
```

`--trames 200` fait tourner le DSP sur 200 trames TDMA (une trame = 4,615 ms de temps GSM), avec le budget d'instructions par défaut de 2300 par trame en mode autonome. Sans option, seules les erreurs du cœur passent sur stderr ; le bilan final dit combien de lignes ont été masquées et avec quel niveau `-v` les voir.

Ce qu'on doit voir, dans l'ordre :

1. Les 7 sections de ROM chargées depuis `/opt/GSM` (ou `--rom-dir`).
2. `c54x_reset()` : la ROM repart de `0xff80`, son vecteur de reset.
3. Des lignes `BRANCH-TRACE` autour de `PC=0xb41f` : c'est la boucle d'attente de la ROM TI, du vrai code que le cœur exécute.
4. Un bilan de fin avec `a_sch[3] = 0x771a`.

Pour voir une ligne par trame :

```bash
./c54x_exe --trames 50 --verbeux
```

Et pour les traces du cœur, `-v` à `-vvvvvv` (voir `--help`).

## 6. Lire le résultat

`a_sch[3] = 0x771a` est une valeur constante d'un run à l'autre : la ROM a booté, s'est parquée en IDLE et a laissé cet état dans sa fenêtre API. C'est la preuve que le cœur exécute fidèlement la ROM jusque-là.

Ce que ça ne prouve pas : le décodage. L'API RAM est vierge, aucun burst n'arrive, le DSP tourne à vide. Un décodeur dont la sortie ne dépend pas de l'entrée ne décode pas ; faire varier l'entrée demande le montage complet de la section 8.

Point de repère utile : le README de `qemu-calypso` donne `0xf8d8` pour ce même mot. La différence vient de l'entrée (QEMU fournit une API RAM initialisée par l'ARM, ici elle est vide), pas d'un bug : deux entrées différentes, deux constantes différentes.

## 7. Erreurs classiques

| Symptôme | Cause | Remède |
| --- | --- | --- |
| `make` : `qemu/osdep.h` ou `calypso_c54x.c` introuvable | qosmo n'est pas à `/opt/GSM/qosmo` | `make QOSMO=/chemin/vers/qosmo` |
| `make` : `osmocom/coding/...` introuvable | `libosmocore-dev` absent ou trop vieux | section 1, dépôt nightly Osmocom |
| `fetch-rom.sh` échoue ou `curl: (1) Protocol "ftp" not supported` | `curl` compilé sans FTP, ou pare-feu | télécharger à la main, puis `fetch-rom.sh` sur le fichier local |
| `c54x_exe` : ROM introuvable | les `.bin` ne sont pas dans `/opt/GSM` | `--rom-dir /chemin` ou refaire la section 4 |
| Le bilan ne montre pas `0x771a` | mauvaise ROM, ou sections mal découpées | comparer `rom/calypso_dsp.txt` au dump 3606 ; refaire la section 4 |
| `PC=0xb41f` n'apparaît jamais, le cœur sort en erreur | régression dans qosmo | `cd /opt/GSM/qosmo && git log -3`, remonter au commit du README |

## 8. La suite : injecter des bursts

Pour que le DSP décode vraiment, il faut l'ARM (le firmware `layer1.highram.elf` d'osmocom-bb sous QEMU `qosmo`), une BTS et le pont qui lui livre des bursts. Deux chemins :

**Le banc complet.** Il pose tout, dans les mêmes chemins `/opt/GSM/…` que cette page :

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./install.sh
sudo ./start-direct.sh --dsp
```

Le `--dsp` remplace la couche 1 gr-gsm par `c54x_exe` ; `--menu` pose la même question interactivement. Le [wiki d'osmo-operator](https://github.com/bbaranoff/osmo-operator/wiki) décrit les options, les ports et le plan de numérotation.

**Exe par exe.** Pour voir chaque étape produire son log : le DSP (`c54x_exe --arm -v`), puis QEMU avec `CALYPSO_DSP_EXTERN=1`, puis `osmocon`, puis `mobile`. La séquence, avec les lignes de journal attendues à chaque pas, est dans [LAUNCH.md](https://github.com/bbaranoff/c54x_exe/blob/main/LAUNCH.md) et le [README de c54x_exe](https://github.com/bbaranoff/c54x_exe#readme).

À partir de là, `a_sch` change avec l'entrée, et la question « est-ce que ça décode ? » a une réponse mesurable.

## 9. Le firmware Calypso : la toolchain arm-elf (gnuarm)

Le firmware d'osmocom-bb (`layer1.highram.elf`, `trx.highram.elf`...) se compile avec la toolchain historique `arm-elf` (gcc 4.5.2, binutils 2.21.1, newlib 1.19) du [gnu-arm-installer](https://github.com/axilirator/gnu-arm-installer), installée dans `/root/gnuarm/install`. Sur Ubuntu 24.04 son `cc1` réclame `libmpfr.so.4`, que le système ne fournit plus (il a `libmpfr.so.6`) ; un lien suffit :

```bash
ln -sf /usr/lib/x86_64-linux-gnu/libmpfr.so.6 /usr/local/lib/libmpfr.so.4 && ldconfig
/root/gnuarm/install/bin/arm-elf-gcc --version      # gcc 4.5.2
```

L'arbre `osmocom-bb-transceiver` (branche jolly/testing, appli `trx`) se compile aussi avec le `arm-none-eabi-gcc` du système, avec les adaptations de `patches/osmocom-bb-transceiver-qemu-bench.patch` (préfixe, édition de liens par gcc, `-fcommon`, `solve_envs.py` en python 3) :

```bash
cd /opt/GSM/osmocom-bb-transceiver/src/target/firmware
make BOARDS=compal_e88 APPLICATIONS=trx ENVIRONMENTS=highram CROSS_COMPILE=arm-none-eabi-
cp board/compal_e88/trx.highram.{elf,bin} /opt/GSM/firmware/board/compal_e88/
```

Tous les patchs appliqués aux arbres osmocom-bb (mobile, transceiver, burst-ind) sont dans `patches/` d'osmo-operator et appliqués par le Dockerfile et `install_modules/40-patches.sh`.
