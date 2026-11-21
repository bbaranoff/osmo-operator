# `pont/` — le pont TRX entre osmo-bts et le DSP Calypso

`pont` est un paquet Python placé entre `osmo-bts-trx` (TRXD/TRXC en UDP) et le
DSP C54x émulé (`c54x_exe --arm`, BSP en UDP 6702). Il relaie les rafales
descendantes vers le DSP, envoie les rafales montantes de la ROM à la BTS au bon
numéro de trame, gère le Kc et pilote l'horloge de la BTS sur celle du DSP.
Repris d'[osmo-operator](https://github.com/bbaranoff/osmo-operator) et réduit
au seul montage DSP.

`vsp_audio.py` est un second programme, indépendant du pont TRX : il relie le
port voix SP0 modélisé du DSP (`CALYPSO_VSP=1`) à PulseAudio.

## Points d'entrée

| Programme | Lancé par | Rôle |
|---|---|---|
| `pont_dsp.py` (`pont.dsp.main`) | `c54x_exe/run.sh` (`PONT_PY`), étape 5 | pont TRX ↔ BSP du DSP, `--dsp-port 6702` |
| `python3 -m pont.vsp_audio` | `c54x_exe/run.sh`, étape 5b, depuis le paquet de `PONT_PY` | `gsm_mic.monitor` → `calypso_pcm_ul` ; `calypso_pcm_dl` → `gsm_audio` |

`pont_dsp.py` pose avant l'import `PONT_UL_RETARD_MAX=26`, `PONT_KC_RETENTION=1`
et `PONT_DSP_COPIES=6762` ; une variable déjà définie par l'opérateur l'emporte
toujours (`setdefault`). La copie vers 6762 sert à une instance rssi
d'osmo-operator : ici elle part vers un port vide, sans effet.

## Ligne de commande (`config.py`)

| Option | Variable | Défaut | Rôle |
|---|---|---|---|
| `--arfcn` | `PONT_ARFCN` | 514 | |
| `--bsic` | `PONT_BSIC` | 7 | |
| `--trx-bind` | `PONT_TRX_BIND` | 127.0.0.1 | adresse côté TRX |
| `--trx-base` | `PONT_TRX_BASE` | 5700 | port TRX de base |
| `--dsp-port` | `PONT_DSP_PORT` | 0 | port UDP du BSP du C54x (6702) ; 0 = coupé |
| `--bsc-cfg` | `PONT_BSC_CFG` | `/etc/osmocom/osmo-bsc.cfg` | plan des timeslots lu dans la config du BSC |
| `--no-tap` | `PONT_TAP=0` | actif | sortie GSMTAP (`PONT_TAP_PORT`, 4729) |
| `--no-record` | `PONT_AIRREC=0` | actif | enregistrement I/Q |

## Organisation

| Module | Rôle |
|---|---|
| `trx.py` | sockets TRXD/TRXC, réponses TRXC (dont `NOMTXPOWER`), `Clock`, `Transmitter` (ordonnancement montant) |
| `downlink.py` | décodage descendant de contrôle, `Feeder`, garde IMMEDIATE ASSIGNMENT |
| `uplink.py` | codage montant, `TchScheduler`, FACCH |
| `cipher.py` | flux A5, Kc lu dans `/dev/shm/calypso_kc_l1`, règle de rétention |
| `state.py` | automates `Dedicated` / `Tch` |
| `gsm.py` | plans de canaux (SDCCH/8, TCH), codage xCCH (libosmocoding par ctypes) |
| `record.py` | enregistrement I/Q |
| `stats.py` | compteurs et ligne `STATS` périodique |
| `config.py` | options et variables d'environnement |
| `dsp/` | spécialisations du montage DSP : `clock.py`, `dedicated.py`, `downlink.py`, `tch.py`, `trx.py`, `uplink.py` |
| `__init__.py` | briques communes chargées par `dsp/` |
| `vsp_audio.py` | port voix du DSP ↔ PulseAudio |

## Interface en mémoire partagée

Le pont, la layer 1 du firmware (dans QEMU) et `c54x_exe` échangent leur état
par `/dev/shm` :

| Fichier | Écrit par | Contenu |
|---|---|---|
| `calypso_kc_l1` | layer 1 (`d_a5mode` et `a_kc[4]` de la NDB, résolus par le DWARF du firmware) | le Kc réellement chargé dans le DSP |
| `calypso_dcch_cfg` | layer 1 | canal dédié courant (`chan_nr`, type, sous-slot, `seq` ; types 2/3 = TCH/F, TCH/H) ; `0xFF` termine la connexion |
| `calypso_tch_cfg` | le pont | annonce de TCH à `c54x_exe` ; `seq+1, tn=0` revient au SDCCH sans perdre le Kc |
| `calypso_sdcch_ul` | layer 1 | blocs L2 SDCCH/SACCH montants ; jamais un FACCH |
| `calypso_tch_facch_ul` | layer 1 | blocs FACCH montants (slot unique, `seq` global ; le curseur est recalé à chaque nouveau canal pour ne jamais rejouer un bloc périmé) |
| `calypso_xcch_ul_rom` | `c54x_exe` | anneau des rafales SDCCH/SACCH montantes émises par la ROM, avec le flux A5 qu'elle a appliqué |
| `calypso_tx_rom` | `c54x_exe` | rafales montantes finales de la ROM (`PONT_UL_RAW=1`) |
| `calypso_pcm_ul`, `calypso_pcm_dl` | `vsp_audio.py` / `c54x_exe` | anneaux PCM 8 kHz du port voix |

Ordre des octets du Kc : le firmware range la clé inversée et par mots
(`a_kc[0] = key[7] | key[6]<<8` … `a_kc[3] = key[1] | key[0]<<8`) ; les deux
inversions sont défaites à la lecture.

## Règles de chiffrement

- La fin de vie d'un Kc est un **événement réseau**, pas un état local. La clé
  est libérée sur IMMEDIATE ASSIGNMENT (seule attribution d'un nouveau canal,
  qui commence toujours en clair), sur CHANNEL RELEASE en SDCCH et sur CHANNEL
  RELEASE en FACCH. Elle n'est libérée ni sur SABM, ni sur un `algo=0` de la
  layer 1 (le firmware recharge `dsp_load_ciph_param(0, NULL)` à chaque
  resynchronisation, y compris au passage SDCCH → TCH), ni sur `DM_EST_REQ`
  (aussi utilisé pour ouvrir le SAPI 3 sur un canal déjà chiffré).
- `PONT_KC_RETENTION` (1 par défaut) garde la clé pendant la fenêtre où la
  layer 1 locale est en clair alors que le réseau chiffre encore.
- La rafale de bourrage de C0 (osmo-bts remplit chaque timeslot libre de C0)
  est filtrée avant `a5_apply` : elle n'est jamais chiffrée, et la compter comme
  un échec CRC gonfle le taux d'erreur d'une radio saine.
- L'identité d'un canal dédié (`chan_nr`) n'est pas une instance : le BSC
  réattribue le même sous-slot, donc l'identité est oubliée à la fin du canal
  et l'établissement suivant est appris même à `chan_nr` égal.
- La garde DCCH (qui retire les SI du camp de `a_cd` pendant un canal dédié)
  est armée par le descendant (`set_dcch_active`) et entretenue par le montant
  dédié (`d_task_u` dans {12 DUL, 13 TCHT, 14 TCHA}) ; son TTL (~2 s) rend le
  camp au mobile en fin de canal.

## Montage DSP (`pont_dsp.py`, `dsp/`)

L'état dédié suit le DSP et non le décodage propre du pont, car le BSP joue
les trames au temps du C54x, de 12 à ~200 trames après le pont :

- **L'A5 descendant est fait par le DSP.** La mask-ROM programme le
  coprocesseur XIO du Calypso (ports `0x2800..0x2818`, modélisé dans
  `qosmo/hw/arm/calypso/l1-dsp/calypso_a5.c`, compilé dans c54x_exe) avec
  `a_kc` et `a_a5fn`. Le pont n'applique pas le flux au descendant ;
  `PONT_DSP_DECHIFFRE=1` le lui fait refaire (avec `CALYPSO_A5=0` côté
  c54x_exe).
- **`TchDsp`** : l'ASSIGNMENT COMMAND est une annonce ; c54x_exe bascule le BSP
  à la première tâche TCHT/TCHA/TCHD posée par le firmware. `abandon()` revient
  au SDCCH sans perdre le Kc.
- **`UplinkDsp`** : les rafales SDCCH/SACCH montantes viennent de la ROM
  (`calypso_xcch_ul_rom`) ; le pont les redécode, défait le XOR de la ROM si
  besoin (elle chiffre au temps du DSP), compare au L2 de `calypso_sdcch_ul`,
  puis envoie et rechiffre au fn de l'air. Sans rafales ROM après
  `PONT_UL_ROM_ATTENTE` (0,12 s) : codage par l'hôte. Ligne STATS :
  `xCCH ul rom= hote= rom_ko=`.
- **`DedicatedDsp`** : `plan()` renvoie toujours le dernier SDCCH tant que la
  connexion vit ; seul `0xFF` la termine.
- **`TrxDsp`** : le timeslot TCH compte comme dédié dès l'annonce (osmo-bts
  chiffre la TCH dès l'activation), sous la garde `cipher.dl_active`.
- **`ClockDsp`**, horloge en boucle fermée : avance = `PONT_MARGE_DL` (16) moins
  l'avance minimale de la BTS sur `PONT_MARGE_FENETRE` (3 s), bornée à
  [`PONT_AVANCE_MIN` 10, `PONT_AVANCE_MAX` 40]. Une ligne « marge DL reelle …
  min … moy » toutes les 10 s dans `pont.log` doit rester > 0.

## Variables d'environnement

`run-dsp.sh` pose `PONT_UL_RAW_TCH=1` (parole montante par la ROM) ; le reste
est aux valeurs par défaut.

| Variable | Défaut | Effet |
|---|---|---|
| `PONT_NOMTXPOWER` | 23 | puissance nominale (dBm) renvoyée à `CMD NOMTXPOWER` ; sans valeur, osmo-bts-trx s'arrête |
| `PONT_KC_RETENTION` | 1 | garde le Kc jusqu'au prochain événement réseau ; 0 pour comparer |
| `PONT_DSP_DECHIFFRE` | 0 | le pont déchiffre le descendant (avec `CALYPSO_A5=0` côté c54x_exe) |
| `PONT_DSP_COPIES` | `6762` | ports BSP supplémentaires recevant une copie du descendant ; vide = aucun |
| `PONT_UL_ROM` | 1 | rafales SDCCH/SACCH montantes de la ROM ; 0 = codées par le pont |
| `PONT_UL_ROM_ATTENTE` | 0.12 | attente maximale (s) des rafales ROM d'un bloc avant repli hôte |
| `PONT_UL_RAW` | 0 (1 via `run.sh`) | montant = rafales finales de la ROM (`calypso_tx_rom`) |
| `PONT_UL_RAW_TCH` | 0 (1 via `run-dsp.sh`) | avec `PONT_UL_RAW=1` : la TCH aussi vient de la ROM |
| `PONT_UL_TN_DEFAUT` | non défini | timeslot montant par défaut |
| `PONT_UL_RETARD_MAX` | 26 | retard maximal (trames) d'une rafale montante encore envoyée |
| `PONT_UL_FN_ADVANCE` | 3 | avance de trame montante |
| `PONT_HORLOGE` | 1 | 0 = horloge murale au lieu de l'horloge asservie au DSP |
| `PONT_MARGE_DL`, `PONT_AVANCE_MIN`, `PONT_AVANCE_MAX`, `PONT_MARGE_FENETRE` | 16, 10, 40, 3 s | `ClockDsp` |
| `PONT_CLCK_PERIOD_FN`, `PONT_CLCK_PAUSE_MAX`, `PONT_CLCK_PAUSE_PLAFOND`, `PONT_CLCK_SANS_IND_MAX`, `PONT_CLCK_SKEW_ZONE`, `PONT_BTS_FN_ADVANCE` | 51, 20, 38, 300, 60, 2 | gestion de `IND CLOCK` (TRXC) |
| `PONT_DCCH_REL_DELAI` | 1.5 | s : délai avant qu'une libération de canal prenne effet |
| `PONT_TCH_ABANDON_GRACE` | 2.0 | s : grâce avant l'abandon d'une annonce de TCH |
| `PONT_TAP`, `PONT_TAP_PORT` | 1, 4729 | GSMTAP pour Wireshark |
| `PONT_RSSI` | 60 | RSSI rapporté à la BTS |
| `PONT_AIRREC`, `PONT_AIRREC_DL_PATH`, `PONT_AIRREC_UL_PATH` | 1, `/root/record.cfile`, `/root/record_ul.cfile` | enregistrement I/Q |
| `VSP_SOURCE`, `VSP_SINK` | `gsm_mic.monitor`, `gsm_audio` | `vsp_audio.py` : source micro et sortie haut-parleur PulseAudio |

Compteurs : `ne` est le nombre d'erreurs binaires, `nb` le nombre **total** de
bits (378 pour TCH/FS, constant). `ne=0` avec `rc=-1` signale une entrée
constante, pas une radio saine. Le compteur `crc` de la TCH descendante est le
décodage de contrôle du pont (référence écrite dans `/dev/shm/pont_tch_dl.bin`),
pas ce que reçoit le DSP.

## Vérification

`../verif.sh` donne un verdict en une commande : attachement, N appels au 600,
voix descendante et montante mesurées sur PulseAudio. Voir le README principal.

## Problèmes connus

- **`unsupported SAPI` côté mobile** : il en reste quelques-uns par run (ni
  l'en-tête L1 du SACCH, ni les SI du camp ; les deux vérifiés). Ne bloque pas
  les appels. Pistes : un autre écrivain de `a_cd`, ou le firmware qui relit un
  bloc périmé faute de rafraîchissement (`B_BLUD`).
- **Échecs CRC résiduels** sur le SDCCH chiffré et sur le SACCH, non isolés.
- **B_BFI** levé sur chaque trame vocale rendue par la ROM alors que le FR reste
  intelligible ; chemin du signal ou cœur C54x, non tranché.
- **LOS occasionnel** sur un appel TCH : le SACCH de la TCH est perdu ~15 s ;
  l'appel suivant est propre. Cause inconnue.
- **SACCH descendant du SDCCH/8** : environ la moitié des blocs rejetés par le
  mobile pendant un LU ; la table SACCH/8 du BSP est suspecte (alternance sur
  deux multitrames 51).
- **UI SAPI 0 sur la TCH** (« unimplemented Abis RLL message » au BSC), non
  bloquant.
- **Horloge** : l'avance visée atteint parfois `PONT_AVANCE_MAX` ; la marge DL
  réelle peut toucher 0 juste après un LOS.
- Pas des anomalies : échecs CRC du contrôle TCH descendant du pont en début et
  fin d'appel (la BTS ne met rien sur la TCH tant que le RTP ne circule pas).
