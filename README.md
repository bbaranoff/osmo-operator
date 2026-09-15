# osmo-operator — banc GSM/LTE pédagogique, multi-PLMN, sans matériel

Un réseau mobile complet sur une seule machine : couche radio visible (spectres
I/Q), signalisation lisible (SS7/M3UA, GSUP, Abis), services qui marchent au
bout (appel, SMS, data 2G/4G, CSFB). Le mobile est un **vrai firmware OsmocomBB
sur un baseband TI Calypso émulé dans QEMU** (ARM7 + DSP C54x) ; le cœur est la
pile Osmocom ; la 4G est Open5GS + srsRAN en ZeroMQ. Tout tient dans une image
Docker, une ISO bootable, ou une installation native Ubuntu 24.04.

De 1 à 9 opérateurs interconnectés par un inter-STP central, configuration SS7
générée automatiquement — un « DHCP pour SS7 ».

```
UE (QEMU Calypso / fake_trx / SDR) ─ BTS ─ BSC ─ STP ─ MSC ─ HLR
                                                 │      ├─ MGW (RTP)
                                                 │      └─ Asterisk (voix, SIP, trunks)
                                            inter-STP ─ autres opérateurs
```

| Je veux… | Lire |
|---|---|
| démarrer sans rien compiler (**méthode conseillée**) | [wiki/Home.md](wiki/Home.md) — l'ISO desktop de la release |
| démarrer en Docker ou en natif | [Démarrage rapide](#démarrage-rapide) |
| construire l'image, l'ISO, les `.deb` | [wiki/Build.md](wiki/Build.md) |
| comprendre ce que fait `start-direct.sh`, étape par étape | [wiki/Start-direct.md](wiki/Start-direct.md) |
| savoir quelle variable gagne, et pourquoi QEMU ne voit pas la mienne | [wiki/Environnement.md](wiki/Environnement.md) |
| interconnecter N opérateurs (SS7, SMS, voix) | [§ Architecture](#architecture-multi-plmn) |
| savoir si mon banc est sain | [§ État du banc](#état-du-banc--checkscheck_allsh-en-natif) et [wiki/Resultats.md](wiki/Resultats.md) |
| diagnostiquer un PROHIB, un CRC, un mobile qui ne campe pas | [§ Diagnostic](#diagnostic) et [`pont/README.md`](pont/README.md) |

---

## Démarrage rapide

### A. Image Docker publiée (le plus court)

```bash
sudo docker pull bastienbaranoff/norf_gsm
sudo docker tag bastienbaranoff/norf_gsm osmocom-nitb
git clone https://github.com/bbaranoff/osmo-operator
cd osmo-operator
sudo ./start.sh                  # mode single, ou bridge : N opérateurs
sudo docker exec -ti osmo-operator-1 bash
cd /opt/GSM/osmo-operator
./start-direct.sh --regen        # première fois : génère les configs
./start-direct.sh --stop
./start-direct.sh
```

### B. Installation native (Ubuntu 24.04, sans Docker)

```bash
sudo ./install.sh                # deps, sources, build, binaires, configs, bureau
sudo ./start-direct.sh           # ou l'icône « Lancer le banc GSM »
```

### C. ISO bootable — la méthode conseillée

La [release](https://github.com/bbaranoff/osmo-operator/releases/latest) livre
`osmo-operator-desktop.iso` en quatre morceaux (limite GitHub 2 Gio) :

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

8 Go / 4 cœurs, virtualisation imbriquée en VM. VirtualBox, VMware, clé USB,
lanceurs du dock et mots de passe : [wiki/Home.md](wiki/Home.md). Pour la
construire soi-même : `sudo ./build-iso.sh --desktop`.

Au boot, la machine arrive sur son bureau ; le banc **n'est pas** lancé tout
seul. Icône « Lancer le banc GSM », ou `systemctl start osmo-banc`.

---

## État du banc — `checks/check_all.sh` en natif

Deux runs de référence le 2026-09-15, détail et lecture dans
[wiki/Resultats.md](wiki/Resultats.md) :

| Topologie | global | ss7 | interco | Verdict |
|---|---|---|---|---|
| 1 opérateur natif, sans hub | 29 pass / 0 fail / 1 warn | OK | `operator` ECHEC : pas d'inter-STP, **attendu** | **sain** |
| 3 opérateurs (Op1 natif, Op2/Op3 conteneurs) + inter-STP | 88 pass / 0 fail / 5 warn | **31 pass / 0 warn**, matrice 3×3 complète, `as-inter` ACTIVE partout | `interstp` ECHEC « aucun AS actif » : **faux négatif** du script (il lit la VTY d'Op1 au lieu du hub en topologie hybride) | **sain, interco UP** |

Ce qui reste à traiter, dans les deux cas : **GGSN 0 APN** (bloque la data 2G
uniquement — `APN=internet` dans `globals.conf`, puis `--regen`) et, à trois
opérateurs, **SGSN 0 NS entity** sur Op2/Op3 (leur PCU n'a pas ouvert de NS-VC).
Le warn « abonnés sans fiche » est cosmétique (banc relancé sans `start.sh`).

```bash
bash ./checks/check_all.sh                       # tout
./checks/check_all.sh --only=interstp --verbose  # un seul check, en détail
./checks/check_all.sh --dump                     # + vty-debug-dump et operator_summary
```

---

## `start-direct.sh` — le lanceur

`start-direct.sh` ne démarre aucun démon lui-même. C'est un **préparateur** : il
charge l'environnement, détecte les binaires et le fork Calypso, choisit un
profil, génère les `mobile_*.cfg`, exporte ce qu'il faut et **exécute `run.sh`**
du fork choisi (`qosmo-grgsm` par défaut, `qosmo-dsp` avec `--dsp`). Toute la
logique GSM vit ensuite dans ce `run.sh` et ses `run_modules/`, dans un tmux
nommé `calypso`.

Le profil par défaut est `faketrx-qemu` (alias `hybrid`) : le cœur, une BTS#0
servie par le Calypso QEMU et une BTS#1 servie par `fake_trx` + `trxcon` — donc
un mobile émulé « réel » et un mobile logiciel, dans la même cellule voisine.
`faketrx` seul se passe de QEMU, `qemu` ne lance que le pipeline Calypso,
`core`/`noproc` ne lance que le cœur.

La règle qui gouverne tout le script : **la ligne de commande gagne toujours**.
`VAR=x ./start-direct.sh` passe devant `environment/load.env`, qui passe devant
les profils, qui passent devant les défauts par domaine. Une seule exception,
documentée : `globals.conf` fait autorité **sur les 26 variables réseau qu'il
déclare** (MCC, MNC, ARFCN, ENCRYPTION…) et sur elles seules ; tout le reste
(`CALYPSO_*`, `MODE`, `LOG_DIR`…) le traverse intact et arrive jusqu'à QEMU.
Le détail, les idiomes de gate et le manifeste : [wiki/Environnement.md](wiki/Environnement.md).

```bash
./start-direct.sh --list                  # le plan, sans rien lancer
./start-direct.sh --dry-run --verbose     # déroule sans effet de bord
./start-direct.sh --menu                  # pose les questions au lieu de deviner
./start-direct.sh --dsp                   # fork qosmo-dsp : le vrai DSP C54x décode
./start-direct.sh --wan --node 2          # ce nœud = 2 d'un WAN à N nœuds
./start-direct.sh --stop | --status
CALYPSO_BRIDGE=none ./start-direct.sh     # QEMU + BTS, sans pont
CALYPSO_NO_ATTACH=1 ./start-direct.sh     # ce que pose osmo-banc.service
```

Étape par étape, avec ce que chaque phase écrit et où : [wiki/Start-direct.md](wiki/Start-direct.md).

### Les autres portes d'entrée

| Script | Rôle |
|---|---|
| `launch.sh` | le double-clic : wireshark (GSMTAP 4729), Linphone, Firefox sur le dashboard, puis `start-direct.sh` au premier plan, via pkexec |
| `start.sh` | Docker : single ou bridge N opérateurs, crée les réseaux, l'inter-STP, les conteneurs |
| `start-multi.sh` | le banc multi-opérateur (`osmo-multi.service`, `Requires=osmo-banc`) |
| `start-interstp.sh` | l'inter-STP seul (image `osmocom-stp`, arm64 possible) |
| `compose.sh` | `build | up [--ms N] [--phy faketrx] | down | ps | logs | shell | debs` |
| `tools/osmo-lte.sh` | la 4G : Open5GS + srsENB + srsUE (netns `ue1`), `osmo-lte.service`, icône « osmo-lte toggle » |

---

## Architecture multi-PLMN

Chaque opérateur N est un conteneur avec la pile complète, tout en `127.0.0.1`
(le STP écoute avant que l'interface Docker soit attachée — c'est le fix de la
race condition). Seul le lien STP↔inter-STP traverse le réseau Docker.

| Réseau | Plage | Rôle |
|---|---|---|
| `gsm-inter` | `172.20.0.0/24` | backbone M3UA ; inter-STP en `.10`, opérateur N en `.(10+N)` |
| `gsm-net-opN` | `172.20.N.0/24` | privé opérateur N (GSMTAP, GPRS) ; conteneur en `172.20.N.10` |

### Point codes et routing contexts (ITU 14 bits, `zone.network.node`)

| Nœud | PC | RCTX |
|---|---|---|
| inter-STP | `0.23.0` | — |
| MSC OpN | `N.23.1` | `N×100+10` |
| STP OpN | `N.23.2` | `N×100+20` (registration), **`N×100+50` vers l'inter-STP** |
| BSC OpN | `N.23.3` | `N×100+30` |

L'inter-STP n'a **pas de routing-key** : un AS `as-opN` en `traffic-mode override`
par opérateur, et le routage se fait sur le DPC (`route N.23.x → as-opN`). Le
RCTX inter (`N×100+50`) doit être identique dans `osmo-stp.cfg` de l'opérateur et
dans `osmo-stp-interop.cfg` — c'est la première chose à vérifier sur un PROHIB.

Chemin d'un message : `MSC Op1 → STP Op1 (127.0.0.1:2905) → catch-all as-inter →
inter-STP 172.20.0.10:2908 → DPC 2.23.x → as-op2 → STP Op2 → route dynamique → MSC Op2`.

### Génération dynamique

Aucun fichier ne contient de valeur figée pour un nombre d'opérateurs. Au
démarrage, `apply_config_templates()` résout en un seul `sed` :

| Placeholder | Formule | N=2 |
|---|---|---|
| `__PC_MSC__` / `__PC_STP__` / `__PC_BSC__` | `N.23.1` / `.2` / `.3` | `2.23.1`… |
| `__RCTX_MSC__` / `__RCTX_BSC__` / `__RCTX_INTER__` | `N×100+10` / `+30` / `+50` | `210` / `230` / `250` |
| `__ARFCN__` | `512+N×2` | `516` |
| `__INTER_LOCAL_IP__` / `__CONTAINER_IP__` | `172.20.0.(10+N)` / `172.20.N.10` | `172.20.0.12` / `172.20.2.10` |

puis appende, selon N total : les N−1 trunks PJSIP `[interop_trunk_opX]`, le
contexte `[interop_out]` du dialplan, `sms-routing.conf`, et `osmo-stp-interop.cfg`
(N AS, N×3 routes). L'inter-STP doit écouter sur `:2908` **avant** les opérateurs.

### SMS

Intra-opérateur : `MS → MSC (sms-over-gsup) → HLR → proto-smsc-daemon → HLR → MSC → MS`.
Inter-opérateur : `sms-interop-relay.py` lit le log MO du SMSC, parse le TPDU
GSM 03.40, fait un longest-prefix match dans `sms-routing.conf` et pousse un JSON
`{dest, text, from}` en TCP `:7890` au relay de l'opérateur cible, qui résout
MSISDN→IMSI par la VTY du HLR et injecte via `proto-smsc-sendmt`.

### Voix

Intra : `MS → BTS → BSC → MSC → MNCC → Asterisk → MNCC → MSC → … → MS`, RTP par OsmoMGW (MGCP).
Inter : trunk SIP `172.20.0.(10+X) ↔ 172.20.0.(10+Y)` entre les Asterisk. Le
dialplan route sur le **premier chiffre** du numéro : chiffre N = opérateur N.

| Numéro | Usage |
|---|---|
| `N0001`…`N9999` | abonnés GSM de l'opérateur N |
| `100` / `200` | Linphone A / B (softphones locaux) |
| `600` | echo test |
| `9XXXXX` | sortie inter-op depuis un softphone |

---

## Le mobile : trois PHY

| `PHY_MODE` / profil | Pile | Usage |
|---|---|---|
| `faketrx` | `fake_trx → trxcon → mobile` | multi-MS, rapide, pas de DSP |
| `virtphy` | `osmo-bts-virtual ↔ virtphy ↔ mobile` | multi-MS par multicast UDP |
| `qemu` (`calypso`) | `osmo-bts-trx ↔ pont ↔ QEMU Calypso ↔ mobile` | baseband émulé ARM7 + DSP, 1 MS par conteneur |

En mode QEMU, la machine `calypso` exécute le vrai `layer1.highram.elf`
(compilé dans l'image avec `gcc-arm-none-eabi`) ; le DSP charge `calypso_dsp.txt`,
la mask-ROM dumpée d'un téléphone ; `mobile` se connecte au socket L1CTL
`/tmp/osmocom_l2` publié par la PTY série du firmware (sercomm DLCI 5). QEMU est
maître d'horloge TDMA (ticks UDP 6700) ; le pont synthétise les `IND CLOCK` pour
le BTS et relaie les bursts entre TRX (5700-5702) et BSP (6702).

Deux forks, même interface `run.sh` :

- **`qosmo-grgsm`** (défaut) — couche 1 gr-gsm, sans C54x. Va de bout en bout :
  camping, LU, COMP128v1, A5/1, SMS, appel voix. C'est la démo.
- **`qosmo-dsp`** (`--dsp`) — le DSP C54x émulé exécute la mask-ROM TI et
  décode lui-même. Le FB est acquis, le décodage SCH ne passe pas encore
  (`a_sch[0]=0x8100`, CRC faux) : **le mobile ne campe pas**. C'est le banc de
  travail. Pas de pont par défaut (`CALYPSO_BRIDGE=none`) : son transceiver est
  `osmo-trx-ipc`.

Depuis le 2026-09-03, QEMU n'est plus appelé directement mais par un lanceur C
compilé dans chaque fork (`tools/qosmo-launch`, installé en
`/usr/local/bin/qosmo-grgsm` ou `qosmo-dsp`) : mêmes défauts (`-M calypso`,
`-cpu arm946`, `-gdb tcp::1234`, deux `-serial pty`, moniteur unix, L1CTL,
TRXDv0 `0.0.0.0:6702`, IQ tee `127.0.0.1:6703`), lecture de `l1s`/`last_rach`
dans l'ELF, liens stables vers les pty sous `<RUN_DIR>/modem.pty`, et `-o` pour
lancer `osmocon` lui-même.

---

## Accès et diagnostic

```bash
tmux attach -t calypso                               # natif / ISO
sudo docker exec -ti osmo-operator-1 tmux attach     # Docker ; inter-STP : -t stp
journalctl -u osmo-banc -f
./ss7-console.py                                     # schéma SS7 navigable, VTY intégrées
```

| VTY | Port | | tmux | Fenêtre |
|---|---|---|---|---|
| OsmoSTP | 4239 | | `Ctrl-b 0` | faketrx |
| OsmoBSC | 4242 | | `Ctrl-b 1` | MS1 |
| OsmoMGW | 4243 | | `Ctrl-b 2` | Asterisk |
| OsmoMSC | 4254 | | `Ctrl-b 3` | SMSC + relay |
| OsmoHLR | 4258 | | `Ctrl-b w` / `d` | liste / détacher |

Wireshark démarre sur `sctp or udp port 4729` ; filtres utiles : `m3ua`, `sccp`,
`gsm_map`, `gsmtap`, `sctp.srcport == 2908`.

### Diagnostic

| Symptôme | Cause probable | Vérifier |
|---|---|---|
| route `0.0.0/0` PROHIB | inter-STP absent, ou `INTER_STP_IP`/backbone faux | `docker ps \| grep inter-stp` ; `show cs7 instance 0 asp` sur 4239 des deux côtés |
| pas de routes dynamiques | MSC/BSC ne joignent pas le STP | ASP pointent bien sur `127.0.0.1` ? |
| ASP DOWN sur l'inter-STP | race Docker | `docker restart osmo-operator-N` |
| `bridge: timeout … UDP 6700` | QEMU n'a pas démarré TPU/DSP | `grep TINT0 /var/log/osmocom/qemu.log` |
| `FBSB result=255` | le DSP ne voit pas le FB | `grep "IMR change" qemu.log \| wc -l` ; `qemu/SESSION_STATUS.md` |
| `PC clock skew too high` | plus d'`IND CLOCK` | relancer le pont |
| `/tmp/osmocom_l2` jamais créé | le firmware ne boote pas | `head -50 qemu.log` (MVPD / PROM0) |
| « le pont a des CRC » | Kc écrasé, en-tête L1 du SACCH, remplissage de C0, `CALYPSO_CANNED` inopérant | [`pont/README.md`](pont/README.md) **avant** de chercher dans un compteur |

Scripts prêts : `checks/check_all.sh`, `checks/ss7_check.sh`,
`checks/diag-stp-operator.sh`, `scripts/call-diag.sh`, `scripts/audio-diag.sh`.

---

## Arborescence

| Dossier | Contenu |
|---|---|
| `environment/` | la configuration par domaine, `load.env` en tête — [README](environment/README.md) |
| `pont/` | le transceiver-pont TRX-UDP (Python) : `pont.py`, `airmesh.py`, `cipher.py` — [README](pont/README.md) |
| `navigation/` | la console SS7 (`ss7-console.py`, TUI, VTY, MAP) — [QUICKSTART](navigation/QUICKSTART.md) |
| `scripts/` | `run.sh`, `entrypoint.sh`, relay SMS, diag audio/appel |
| `checks/` | vérifications SS7 / opérateur / inter-STP |
| `services/` | unités systemd, **posées mais non activées** — [README](services/README.md) |
| `packaging/` | `.deb` par composant, cache `/var/cache/osmo-debs`, apt-fast |
| `iso_modules/`, `install_modules/` | étapes de `build-iso.sh` et `install.sh` |
| `fft-web/` | les deux spectres I/Q (MS + BTS) sur une page, port 8081 |
| `configs/`, `data/`, `patches/` | gabarits Osmocom/Asterisk, bureau et icônes, patches |
| `wiki/` | [Home](wiki/Home.md) · [Resultats](wiki/Resultats.md) · [Build](wiki/Build.md) · [Start-direct](wiki/Start-direct.md) · [Environnement](wiki/Environnement.md) |

Documentation complète des 312 variables Calypso :
`hw/arm/calypso/doc/VARIABLES_ENVIRONNEMENT.md` dans le fork QEMU.

---

*osmo-operator — plateforme pédagogique télécom multi-PLMN. Ubuntu 24.04, Docker ou natif, amd64 et arm64 (Raspberry Pi 4 pour l'inter-STP / lite).*
