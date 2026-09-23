# Environnement — qui gagne, et ce qui arrive jusqu'à QEMU

Le banc est piloté par des variables d'environnement, à trois étages :
`start-direct.sh` (le préparateur), `run.sh` + `run_modules/` (l'orchestrateur du
fork), et QEMU lui-même (la machine `calypso`, qui lit ses `CALYPSO_*` au boot).
Une variable posée au mauvais endroit, ou avec le mauvais idiome, est reposée
silencieusement à son défaut avant d'arriver au dernier étage. Ce document dit
où elle est lue, par qui, et comment vérifier ce que QEMU a **réellement** vu.

---

## 1. L'ordre de chargement

```
1. ligne de commande      VAR=x ./start-direct.sh          gagne toujours (sauf § 2)
2. /etc/osmocom/coeur.env N_MS                             `:=`, ne peut rien écraser
3. options                --profile --dsp --node --wan …
4. globals.conf           26 variables réseau              `=`, mais l'appelant non vide gagne (§ 2)
5. environment/load.env
     modes.env            le profil                        `:=`
     paths.env            où sont les choses               `:=`
     coeur/radio/reseau/debug.env, puis bsp/dsp/fbsb/shunt/rf/armdsp/opcodes.env
     calypso.env          l'ancien monolithe               `:=`, ne fournit que le reste
6. défauts de start-direct.sh   RUN_DIR, LOG_DIR, ENCRYPTION, CALYPSO_BRIDGE, MS_COUNT, HOST_IP
7. exec run.sh            tout l'environnement, intact
8. run_modules/40-qemu.sh → lanceur C → QEMU   le manifeste est écrit ici
```

Tous les fichiers d'environnement utilisent `: "${VAR:=valeur}"` — « si pas déjà
défini ». Donc **le premier qui pose une valeur gagne**, et ce premier est la
ligne de commande.

## 2. L'exception : `globals.conf`

`globals.conf` utilise `VAR=valeur` (pas `:=`). Sur les 26 variables qu'il
déclare — identité (MCC, MNC, OP_NAME), sécurité (ENCRYPTION, SIM_ALGO, KI, IMSI,
IMEI), radio (ARFCN, BAND, BSIC, LAC, CELL_ID, IPA_UNIT_ID, MS_MAX_POWER,
RXLEV_ACCESS_MIN, CELL_RESEL_HYST), GPRS (BVCI, NSEI, NSVCI, APN), SMS_SC,
MS_COUNT, N_OPERATORS, HOST_IP — il écraserait l'environnement s'il était
sourcé seul.
Depuis le 2026-09-22, `start-direct.sh` met de côté celles de ces variables que
l'appelant a posées **non vides**, source le fichier (`set -a`), puis les repose,
et imprime « globals.conf surchargé par l'environnement : … ». La ligne de
commande gagne donc aussi sur ces 26 variables ; un vide signifie toujours
« calculé » et ne surcharge rien. Seul `start-direct.sh` applique cette règle,
et l'en-tête de `globals.conf` dit encore l'inverse (« écrasent leur homonyme
dans l'environnement »).

Tout ce qu'il ne déclare pas (`CALYPSO_*`, `MODE`, `LOG_DIR`, `QEMU_*`…) le
traverse intact. Pour changer une de ses 26 valeurs :

```bash
vim globals.conf
./generate_configs.sh ARFCN=520      # réécrit la ligne
./generate_configs.sh --force        # régénère le fichier entier
```

Un champ vide = calculé (souvent depuis le numéro d'opérateur). Ne figez les
champs `[auto/opérateur]` que si `N_OPERATORS=1`, sinon les opérateurs se
marchent dessus.

Cas concret : `ENCRYPTION`. `ENCRYPTION="a5 0" ./start-direct.sh --dsp` donne
a5 0 ; avant le 2026-09-22 il donnait a5 1, en silence. Sans rien sur la ligne de
commande, la valeur vient de `globals.conf` ; le `: "${ENCRYPTION:=a5 1}"` du
script n'est qu'un repli pour l'ISO nue ou un conteneur sans `globals.conf`.

## 3. `:=` contre `=` dans vos propres fichiers

| Écriture | Effet |
|---|---|
| `: "${VAR:=valeur}"` | défaut ; la ligne de commande gagne |
| `VAR=valeur` | **verrouille** ; personne ne peut surcharger |

N'utilisez `=` que pour ce qui ne doit jamais l'être. Un `=` glissé dans un fichier
par domaine est la cause classique de « ma variable n'a aucun effet ».

## 4. Les quatre idiomes de gate — `=0` ne coupe pas tout

Le code QEMU (`hw/arm/calypso/`) lit ses variables de quatre façons. La manière
de **couper** une variable dépend de l'idiome, pas de la valeur :

| Idiome dans le code | Actif quand | Pour couper |
|---|---|---|
| `getenv("X") ? 1 : 0` | la variable **existe**, même à `0` | **`unset X`** |
| `atoi(getenv("X")) > 0` | valeur > 0 | `X=0` |
| `*e == '1'` | exactement `"1"` | toute autre valeur |
| défaut ON + `X_OFF` | par défaut | poser `X_OFF` |

Donc `FB_ENERGY=0 ./start-direct.sh` peut laisser `FB_ENERGY` **actif**. Vérifiez
l'idiome au site de lecture (`grep -rn '"X"' hw/arm/calypso/`) ou dans la
référence des 312 variables : `hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md`
(défaut, effet mesuré, mode, idiome, catégorie, dépendances).

## 5. Les variables qui en reposent d'autres

Certaines variables sont des **profils** : `CALYPSO_NATIVE_HELPED=1` allume aussi
`FB_CORR_ENTRY`, `FB_ENERGY` et `FB_IQ_*`. Retirer l'une d'elles de la ligne de
commande ne la supprime pas — elle revient à son défaut, posé par le profil.

## 6. La vérité est le manifeste

Ni la ligne de commande, ni `env`, ni les fichiers ne disent ce que QEMU a vu.
Au boot, la machine `calypso` écrit un manifeste dans son journal :

```bash
grep "calypso-manifest" /root/qemu.log          # ou /var/log/osmocom/qemu.log
```

C'est la seule source fiable. Si une variable n'y est pas à la valeur attendue,
elle a été reposée quelque part entre 1 et 8 — remontez la chaîne du § 1.

## 7. Ce qui passe jusqu'à QEMU

| Variable | Défaut | Lu par | Rôle |
|---|---|---|---|
| `CALYPSO_PROFILE` / `MODE` | `faketrx-qemu` (script), `core` (modes.env) | modes.env, run.sh | le profil ; `MODE` gagne s'il est posé |
| `CALYPSO_FORK` | `qosmo-grgsm` | paths.env, start-direct | `--dsp` ne le change plus ; qosmo-dsp n'est plus construit depuis le 17/09, reste accessible à la main (`CALYPSO_FORK=qosmo-dsp`) |
| `OQC_ROOT` | `../<fork>` sinon `$GSM_ROOT/<fork>` | start-direct | l'arbre du fork ; `OQC_ROOT=/chemin ./start-direct.sh` |
| `RUN_SH` | `$OQC_ROOT/run.sh` | start-direct | le `run.sh` exécuté (surchargeable depuis le 2026-08-08) |
| `QOSMO_LAUNCHER` | `/usr/local/bin/<fork>` | 40-qemu.sh | le lanceur C ; absent → `qemu-system-arm` historique |
| `CALYPSO_BRIDGE` | `pont` (`none` avec `--dsp`) | run.sh | `none` = QEMU + BTS seuls ; avec `--dsp`, c'est `c54x_exe/run.sh` qui lance `pont_dsp.py` ; **jamais `ipc`** sur qosmo-dsp (veut dire MS#1 via osmo-trx-ms-ipc, firmware non lancé) |
| `CALYPSO_NO_ATTACH` | | start-direct | `1` = ne pas s'attacher au tmux (`osmo-banc.service`) |
| `CALYPSO_LANG` | | run.sh | langue des messages |
| `CALYPSO_FIXES` | | QEMU (fixes.env) | le sas des correctifs en attente de validation |
| `QEMU_BIN` | `$GSM_ROOT/qemu/build/qemu-system-arm` | 40-qemu.sh | binaire (sans lanceur) |
| `QEMU_FW` | `$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf` | lanceur | firmware ARM |
| `QEMU_DSP_ROM` | `$GSM_ROOT/calypso_dsp.txt` | lanceur (`-dsp`) | mask-ROM C54x |
| `QEMU_BRIDGE` | `$OQC_ROOT/bridge.py` | run.sh | le pont (historique) |
| `QEMU_L1CTL_SOCK` | `/tmp/osmocom_l2` | lanceur, mobile | socket L1CTL |
| `QEMU_MON_SOCK` | `/tmp/qemu-calypso-mon.sock` | lanceur | moniteur HMP |
| `RUN_DIR` / `LOG_DIR` | `/run/osmo-direct` / `$RUN_DIR/logs` | tout | tmpfs — le défilement tmux en dépend |
| `GSM_ROOT` | `/opt/GSM` | paths.env | racine de l'installation |
| `N_MS` | `1` (coeur.env) | 21-abonnes-hlr.sh | abonnés provisionnés dans le HLR |
| `MS_COUNT` | `2` | start-direct, globals | mobiles lancés |
| `PHY_MODE` | `faketrx` | run.sh (Docker) | `faketrx` / `virtphy` / `qemu` ; `qemu` force `N_MS=1` |
| `OSMO_STP`, `OSMO_MSC`, … | nom nu (PATH) | paths.env | binaires Osmocom ; vide = paquets |

Banc DSP (`--dsp`) : ces variables sont lues par **c54x_exe** et son `run.sh`,
pas par QEMU — elles n'apparaissent donc pas dans le manifeste `calypso`.

| Variable | Défaut | Lu par | Rôle |
|---|---|---|---|
| `BANC_DSP` | `$GSM_ROOT/c54x_exe/run.sh` | start-direct | le banc lancé après le plan du fork ; `none` pour le couper |
| `INSNS` | `120000` (start-direct), `80000` (c54x_exe/run.sh seul) | c54x_exe (`--insns`) | plafond d'instructions DSP par trame |
| `LOCKSTEP` | `1` | c54x_exe/run.sh | QEMU n'avance la trame que quand le DSP a fini la précédente |
| `IQ` | `none` | c54x_exe/run.sh | pas de cellule synthétique : les bursts viennent de la BTS |
| `CALYPSO_BSP_STREAM` | `1` | c54x_exe (`src/pont.c`) | un burst TS0 par trame, dans l'ordre des FN |
| `CALYPSO_RHEA_DMA_XFER` | `1` | c54x_exe (`src/pont.c`) | sans lui la page API n'est jamais remplie |

Les domaines fins (`bsp.env`, `dsp.env`, `fbsb.env`, `shunt.env`, `rf.env`,
`armdsp.env`, `opcodes.env`) portent 311 variables dont **116 béquilles** :
contournements de branches non implémentées, chacune annotée `@BEQUILLE` à son
site de lecture avec ce qu'elle masque et la condition qui la rendrait inutile
(`grep -rn "@BEQUILLE" hw/arm/calypso/`). `crutches.env` ne se touche que pour
diagnostiquer ; `debug.env` (sondes, traces) est sans effet sur l'émulation et se
modifie librement.

## 8. Recette de vérification

```bash
./start-direct.sh --list                           # le plan : profil, fork, run.sh, lanceur
./start-direct.sh --dry-run --verbose              # déroule, sans lancer
./start-direct.sh --check-paths                    # les dépendances déclarées
X=1 ./start-direct.sh && grep calypso-manifest /var/log/osmocom/qemu.log   # ce que QEMU a vu
grep -rn '"X"' /opt/GSM/qosmo-grgsm/hw/arm/calypso/   # l'idiome de lecture
```

Si `X` n'est pas dans le manifeste : soit `globals.conf` la déclare (§ 2), soit un
fichier la pose en `=` (§ 3), soit un profil la repose (§ 5), soit elle n'est lue
que par l'autre fork.
