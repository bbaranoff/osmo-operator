# `start-direct.sh` — étape par étape

`start-direct.sh` prépare, `run.sh` exécute. Ce document suit le script phase par
phase : ce qu'il lit, ce qu'il décide, ce qu'il écrit, et à quel moment votre
variable est prise en compte — ou écrasée.

```
ligne de commande ─► coeur.env ─► globals.conf ─► environment/load.env ─► profil
        │                                                                     │
        └──────── résolution run.sh / fork / lanceur QEMU ◄───────────────────┘
                              │
                   génération mobile_*.cfg
                              │
            --stop / --status / --list ? ─── délégué à run.sh, fin
                              │
              --regen / --node / --wan / --menu (identité SS7, table WAN)
                              │
                  arrêt systématique de la pile
                              │
             dashboard :8080, raccord oFono, exec run.sh ─► tmux « calypso »
```

---

## 0. Où on est, et un garde-fou retiré

Le script se place dans son propre répertoire (`HERE`). Il ne vérifie **plus**
qu'il tourne dans Docker (garde retirée le 2026-08-14 : sur l'ISO il n'y a pas de
Docker et c'était le seul lanceur utilisable). Conséquence connue : lancé par
erreur sur un hôte Docker, il meurt sur « `run.sh` introuvable », qui ne désigne
pas la vraie cause. Sur un hôte avec Docker, le lanceur est `./start.sh`.

## 1. Chargement de l'environnement

Dans cet ordre, et **l'ordre décide de qui gagne** (détail : [Environnement.md](Environnement.md)) :

1. **`/etc/osmocom/coeur.env`** (`OSMOCOM_CFG` pour déplacer) — écrit par
   `build-iso.sh`, porte `N_MS`. Chargé ici et pas par `~/.bashrc`, sinon
   l'icône, systemd et `start-multi.sh` ne le voyaient pas : le HLR n'avait que
   100101 et le second mobile se faisait créer à la volée sans Ki, injoignable.
   Le fichier utilise `:=` : un `N_MS=3` posé dans l'environnement gagne.
2. **Options de la ligne de commande** (`--profile`, `--dsp`, `--node`…).
3. **`globals.conf`** — **fait autorité sur ses 26 variables réseau** (MCC,
   MNC, OP_NAME, ENCRYPTION, ARFCN, BAND, LAC, APN, MS_COUNT, N_OPERATORS,
   HOST_IP…) : elles écrasent leur homonyme de l'environnement. Tout le reste
   passe intact. Champ vide = calculé (souvent depuis le numéro d'opérateur).
   Modifier : `vim globals.conf` ou `./generate_configs.sh ARFCN=520`.
4. **`environment/load.env`** — `modes.env` (le profil), `paths.env` (où sont
   les choses), puis les fichiers par domaine. Tout en `:=` : le premier qui
   pose une valeur gagne, donc la ligne de commande.
5. Repli minimal si `load.env` manque (ISO nue, conteneur nu) : `GSM_ROOT=/opt/GSM`,
   `CALYPSO_FORK=qosmo-grgsm`, résolution d'`OQC_ROOT`.
6. Défauts restants : `RUN_DIR=/run/osmo-direct`, `LOG_DIR=$RUN_DIR/logs`
   (tmpfs — le défilement tmux en dépend), `ENCRYPTION="a5 1"` (repli : la
   valeur réelle vient de `globals.conf`), `CALYPSO_BRIDGE=pont` (`none` avec
   `--dsp`), `MS_COUNT=2`, `HOST_IP=127.0.0.1`.

## 2. Profil

Défaut : **`faketrx-qemu`** (alias `hybrid`) — cœur + BTS#0 QEMU + BTS#1 faketrx.
`--profile <nom>` ou le mode en positionnel le fixe ; `CALYPSO_PROFILE` ou
l'historique `MODE` le fixent depuis l'environnement (`MODE` gagne s'il est posé).
`--dsp` ne choisit `qemu` que si personne n'a choisi avant lui.

| Profil | Ce qui tourne |
|---|---|
| `faketrx-qemu` / `hybrid` | cœur + osmo-bts-trx ← QEMU Calypso + fake_trx/trxcon/mobile |
| `faketrx` | cœur + fake_trx + trxcon + mobile ; pas de QEMU |
| `virtphy` | cœur + osmo-bts-virtual + virtphy + mobile |
| `qemu` / `calypso` | le pipeline Calypso seul, cœur en no-process |
| `core` / `noproc` | STP + HLR + MSC + MGW + BSC (+ Asterisk), aucune radio |
| `hw` | SDR physique |
| `virtual` | multi-opérateurs SS7 par `ip netns` (`N_OPERATORS`) |

## 3. Résolution de `run.sh` et du lanceur QEMU

Ordre : `RUN_SH` explicite > `OQC_ROOT` résolu > `$GSM_ROOT/<fork>/run.sh`.
`OQC_ROOT` est cherché **à côté du dépôt** (`../qosmo-grgsm`) puis sous
`/opt/GSM`. Si `run.sh` n'est pas exécutable : FAIL, avec le chemin testé.

Le lanceur C (`--launcher <bin>`, `QOSMO_LAUNCHER`, défaut `/usr/local/bin/<fork>`)
est compilé s'il manque et que `<fork>/tools/qosmo-launch` est là. Sans lanceur,
`40-qemu.sh` retombe sur la ligne `qemu-system-arm` historique.

## 4. Validation des chemins

`--check-paths` s'arrête ici après avoir vérifié chaque dépendance déclarée
(binaires Osmocom, firmware `layer1.highram.elf`, ROM `calypso_dsp.txt`, pont).

## 5. Génération des `mobile_*.cfg`

`mobile_group1.cfg` (MS#1, derrière QEMU) et le MS#2 (faketrx) sont écrits dans
`$OQC_ROOT/cfgs/` depuis les gabarits, avec IMSI/Ki/IMEI de `globals.conf` (ou
calculés par opérateur). Le client de couche 2 est `mobile` par défaut ;
`--ccch_scan`, `--bcch_scan`, `--cell_log` le **remplacent** (ils prennent sa
socket L1CTL et sa VTY — exclusifs).

## 6. Résumé

Le plan est imprimé : profil, fork, `run.sh`, lanceur, pont, nombre de MS,
chiffrement, ARFCN. `--list` s'arrête là (délégué à `run.sh --list`) ;
`--dry-run` continue sans effet de bord.

## 7. Actions déléguées

`--stop` et `--status` sont transmis à `run.sh` et le script sort.

### 7-menu. `--menu`

Pose **une fois** les choix que le script aurait devinés : profil, nœud,
opérateur, inter-STP, WAN, régénération. Les valeurs proposées sont celles du
lancement automatique : valider sans rien changer = ne pas passer l'option.
Sans terminal, ignoré.

### 7-regen. `--regen`

Par défaut les configs en place sont **conservées** : `run.sh` les régénérerait
au démarrage et effacerait l'identité SS7 posée juste avant. `--regen` arrête la
pile, puis réécrit tout depuis les gabarits (nœud et opérateur courants).

### 7-node. `--node N` / `--op N` / `--hub-ip`

Le numéro de nœud (1 à 9) se **déduit** : environnement, puis `/etc/osmo-role`,
puis la table WAN comparée aux adresses locales. `--node` force. Le script réécrit
l'identité SS7 (point codes `1.<nœud><op>.<rôle>`, routing contexts) et pointe
l'ASP sur l'inter-STP (`--hub-ip`, sinon déduit : docker ou VM). C'est ce qui
permet une ISO unique pour les neuf nœuds.

### 7-wan. `--wan`

Jamais par défaut (`WAN_AUTO=1` dans `/etc/osmo-wan.conf`, posé par une ISO
`--wan`, l'active). Trois formes :

```bash
./start-direct.sh --wan                                  # questions : nœuds, IP, indicatifs, mon numéro
./start-direct.sh --wan-nodes "1:IP:IND 2:IP:IND" --wan-id 2   # scriptable
./start-direct.sh --wan mynode1.conf --wan mynode3.conf  # depuis les fiches des autres nœuds
./start-direct.sh --gen-conf [FICHIER]                   # écrit MA fiche, ne lance rien
```

La table (`--wan-conf`, défaut `/etc/osmo-wan.conf`) est appliquée, l'adressage
SS7 vers l'inter-STP posé, le maillage SIP + SMS généré. Composer
`<indicatif><numéro>` joint ce numéro sur le nœud correspondant. Le profil reste
`faketrx-qemu`.

`--air-mesh[=PORT]` maille en plus les **bursts** : le milieu radio devient
commun, un mobile peut entendre et choisir la BTS d'un autre nœud (pairs de la
table WAN, portée dans `data/air-mesh.txt`, deux mobiles de plus — `pont/airmesh.py`).

`--virtualbox[=N]` monte le segment et N−1 VM avant le WAN ; refuse de tourner
**dans** une VM (`--vbox-node N` = numéro de cette machine).

### 7-tcpdump

Un wrapper tcpdump est posé pour les captures GSMTAP (`udp/4729`) et M3UA.

### 7-arrêt

**Arrêt systématique de la pile avant démarrage** (`run.sh --stop`). Il n'y a
pas de « relance à chaud » : `--force` relance seulement les modules déjà
démarrés au lieu de les sauter.

## 8. Lancement

1. Adresses privées du nœud imprimées.
2. **Tableau de bord** sur `:8080` (Firefox l'ouvre depuis `launch.sh`) ; les
   spectres I/Q sur `:8081` (`fft-web/fft_web.py`).
3. **Raccord mobile oFono** — le téléphone physique (postmarketOS, PPP) ou le
   QEMU Android voit le banc comme un modem.
4. **Transmission à `run.sh`** : `exec`, avec le profil et tout l'environnement.
   Toute variable `CALYPSO_*` passée en préfixe arrive **intacte** jusqu'à
   `run.sh`, ses `run_modules/` et QEMU (`CALYPSO_LANG=en`, `CALYPSO_NO_ATTACH=1`,
   `CALYPSO_BRIDGE=none`…).

`run.sh` ouvre le tmux `calypso` : `osmo-bts-trx` → QEMU (PTY + moniteur) →
attente de `/tmp/osmocom_l2` → pont → attente des ticks UDP 6700 → `mobile`, puis
le cœur, Asterisk, SMSC. Sauf `--no-attach` / `CALYPSO_NO_ATTACH=1` (ce que pose
`osmo-banc.service` : personne devant), le script s'attache au tmux.

---

## Manuel court

```
./start-direct.sh [options] [mode]

Modes : faketrx-qemu (défaut) | faketrx | qemu | noproc | core | hybrid

Choix de la pile
  --dsp                fork qosmo-dsp : le DSP C54x décode lui-même (le mobile ne campe pas encore)
  --grgsm              fork qosmo-grgsm (défaut)
  --launcher <bin>     lanceur C de QEMU (défaut /usr/local/bin/<fork>)
  --profile <nom>      force le profil
  --mobile | --ccch_scan | --bcch_scan | --cell_log   client de couche 2 (exclusifs)

Cycle de vie
  --list  --dry-run  --stop  --status  --force  --verbose  --no-attach  --check-paths
  --regen              régénère les configs depuis les gabarits (sinon conservées)
  --menu               pose les questions au lieu de deviner

Topologie
  --node N  --op N  --hub-ip IP
  --wan | --wan FICHE… | --wan-nodes "…" | --wan-id N | --wan-conf FICHIER | --gen-conf [F]
  --air-mesh[=PORT]  --virtualbox[=N]  --vbox-node N
```

Reprendre la main :

```bash
tmux attach -t calypso         # Ctrl-b d détache, le banc continue
journalctl -u osmo-banc -f     # si lancé en service
./start-direct.sh --status
./start-direct.sh --stop
```

Logs : `$LOG_DIR` (`/run/osmo-direct/logs`, tmpfs) ; QEMU : `/var/log/osmocom/qemu.log`,
pont : `/var/log/osmocom/bridge.log`, orchestration : `/var/log/osmocom/run.sh.log`.
