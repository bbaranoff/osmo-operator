# osmo-operator — Quick start & référence

Un opérateur **GSM + LTE** complet sur une seule image, radio émulée de bout en
bout jusqu'au baseband (Calypso sous QEMU), avec un téléphone postmarketOS qui
fait de la data en 4G et de la voix/SMS en 2G sur la même identité — le CSFB
d'un vrai terminal, au niveau du modem. Ni SDR, ni téléphone physique.

| Page | Contenu |
|---|---|
| **Home** (ici) | quick start conseillé (l'ISO), lancement, référence |
| [Start-direct](Start-direct.md) | `start-direct.sh` étape par étape, manuel des options |
| [Resultats](Resultats.md) | les `check_all.sh` de référence, 1 et 3 opérateurs, et la lecture des écarts |
| [Build](Build.md) | `build.sh`, `build-iso.sh`, `.deb`, `install.sh` |
| [Environnement](Environnement.md) | qui gagne entre variables, ce qui arrive jusqu'à QEMU |
| [README](../README.md) | architecture multi-PLMN, SS7, SMS, voix, diagnostic |

---

## Méthode conseillée : l'ISO desktop (release)

C'est le chemin qui marche sans rien compiler ni configurer : la
[dernière release](https://github.com/bbaranoff/osmo-operator/releases/latest)
livre `osmo-operator-desktop.iso`, un live GNOME avec Wireshark, Linphone,
les spectres I/Q et les trois lanceurs dans le dock.

### 1. Télécharger et recombiner

GitHub plafonne un fichier de release à 2 Gio : l'image est livrée en morceaux.
**Télécharger les quatre `part-*`**, puis :

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
```

### 2. Prérequis

x86_64, **8 Go de RAM et 4 cœurs minimum**. La racine du live est un tmpfs
(~6 Go en `toram`) : journaux et captures y sont bornés et purgés à chaque
démarrage. Le banc fait tourner **deux QEMU** (le Calypso et la VM pmOS) : en
machine virtuelle, activer la **virtualisation imbriquée**, sinon la VM pmOS
tombe en émulation logicielle et devient très lente. Sur matériel réel, KVM est
là directement : c'est la configuration la plus confortable.

### 3. Lancer

**QEMU**

```bash
qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm \
  -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
```

**VirtualBox** — nouvelle VM Linux / Ubuntu 64-bit, 8 Go, 4 CPU, 3D désactivée.
Système → Processeur : cocher *VT-x/AMD-V imbriqué* (case grisée :
`VBoxManage modifyvm "<nom>" --nested-hw-virt on`). Attacher l'ISO au lecteur
optique, pas de disque. Réseau NAT : redirection hôte 8080 → invité 8080.

**VMware** (Workstation / Player / Fusion) — VM depuis l'ISO, Linux / Ubuntu
64-bit, 8 Go, 4 cœurs, cocher *Virtualize Intel VT-x/EPT or AMD-V/RVI*, ignorer
l'installation facile.

**Clé USB** — l'ISO est hybride :

```bash
sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Sous Windows, Rufus en mode *Image DD*. Démarrage UEFI ou BIOS, au choix.

### 4. Démarrer le banc

Rien ne se lance au boot : la machine arrive sur son bureau. Trois lanceurs dans
le dock, 2G et 4G indépendants et dans l'ordre qu'on veut, **le smartphone en
dernier** :

| Lanceur | Démarre |
|---|---|
| **2G** — le combiné rouge | osmo-stp / bsc / msc / hlr / sgsn / ggsn / pcu, le Calypso sous QEMU, les deux BTS, les deux mobiles osmocom-bb, Asterisk, le SMSC |
| **4G** — les barres de réseau | open5gs, srsENB + srsUE en ZMQ, l'interface SGs vers le MSC (le CSFB) |
| **Smartphone** — icône phone | la VM postmarketOS : oFono sur le modem virtuel, data en 4G, voix et SMS en 2G |

Mots de passe : live **`osmo`**, téléphone pmOS **`147147`**.

Vérifier que tout est en place : `checks/diag-stp-operator.sh`, ou le check
complet `bash ./checks/check_all.sh` (résultat de référence d'un nœud natif seul
dans le [README](../README.md#état-du-banc--checkscheck_allsh-en-natif) : tout
passe, seule l'interco SS7 est *down* faute d'inter-STP — c'est attendu).

### 5. Passer un appel

Les deux abonnés provisionnés sont **100101** et **100102**, un par cellule ;
`100`/`200` sont les Linphone, `600` l'echo test. Un appel entrant vers le
smartphone est pagé par le MME, l'UE redescend sur la BTS (CSFB), la voix passe
en 2G ; le speedtest, lui, passe en 4G. Tout se lit dans Wireshark (GSMTAP,
NAS en clair, SGs, M3UA).

---

## Les autres chemins

| Chemin | Quand | Voir |
|---|---|---|
| **Docker** — `docker pull bastienbaranoff/norf_gsm`, `sudo ./start.sh` | N opérateurs interconnectés par inter-STP, sur un hôte existant | [README § démarrage rapide](../README.md#démarrage-rapide) |
| **Natif** — `sudo ./install.sh` puis `./start-direct.sh` | une machine Ubuntu 24.04 dédiée, sans conteneur | [Build § install.sh](Build.md#4-installsh--natif-ubuntu-2404-noble) |
| **Construire l'ISO soi-même** — `sudo ./build-iso.sh` | modifier l'image, WAN pré-câblé, arm64 pour le hub | [Build § build-iso.sh](Build.md#2-build-isosh--iso-bootable--image-sd) |
| **Installer sur disque** — Calamares depuis le live | garder le banc, LUKS, pilotes NVIDIA | [Build](Build.md) |

---

## Référence

### Ce qu'il y a dans l'image (v0.1-3)

`/etc/os-release` : `IMAGE_VERSION="OSMO_EGPRS_V2"` — `/etc/osmo-role` :
`OSMO_ROLE=operator`, `OSMO_LITE=0`.

**2G / GSM — Osmocom**

- Cœur : osmo-stp (M3UA, SCTP :2905), osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn (GTPv1-C/U), osmo-pcu, osmo-mgw (MGCP :2427).
- Deux cellules DCS1800, LAC 1 : BTS 0 (Cell ID 6001, BSIC 7) et BTS 1 (Cell ID 6012, BSIC 8), chacune sur son osmo-bts-trx.
- Couche 1 : `qemu-system-arm -M calypso -cpu arm946` exécute `layer1.highram.elf`, chargé par osmocon comme sur un C123 ; `pont.py` convertit les bursts en I/Q pour `fake_trx.py`, puis trxcon et deux `mobile` (osmocom-bb).
- GPRS/EDGE : BSSGP/NS vers le PCU, contextes PDP via osmo-ggsn.
- Voix : MNCC externe → Asterisk (SIP :5060, FR/HR) via osmo-sip-connector.
- SMS : SMS-over-GSUP → proto-smsc-daemon, SMPP :2775 avec un ESME de test, relais inter-opérateurs :7890.
- Authentification A3A8 avec RAND déterministe (patches `*-force-rand-toy`) : reproductible d'un démarrage à l'autre.
- GSMTAP live dans Wireshark.

**4G / LTE — open5gs + srsRAN**

- Cœur open5gs (MME, SGW-C/U, SMF, UPF, PCRF, HSS…) sur loopbacks dédiées ; Prometheus :9090, WebUI :9999, MongoDB derrière le HSS.
- PLMN 001/01, TAC 7. Sécurité NAS en chiffrement nul (EIA2/EIA1 + EEA0), volontairement : le NAS se lit en clair.
- srsENB 10 MHz, EARFCN 3350, bande 7 ; srsUE relié en ZMQ. Abonné milenage IMSI 001010001000001. L'UE a une IP dans un netns et sort en NAT.

**CSFB**

- Interface SGs osmo-msc ↔ MME (:29118), table TAI (001-01, TAC 7) → LAI (001-01, LAC 1) : le VLR classe l'abonné en LAC 1 alors qu'il est sur la LTE.
- Attach combiné EPS+IMSI ; appel entrant pagé par le MME, l'UE redescend sur la BTS.

**postmarketOS**

- VM x86_64, noyau patché (`CONFIG_PPP`, absent du `linux-postmarketos-stable` amont) fourni prébuilt (Git LFS) dans `/opt/user_interface/kernel/pmos/`.
- Data 4G : NetworkManager → pppd (`ATD*99***1#`) → virtio-console `osmo.data` → `osmo-phonesim-banc.py` → netns UE → srsUE → srsENB → UPF → Internet.
- Voix/SMS 2G : seconde virtio-console `osmo.modem`, `osmo-phonesim-banc.py` joue le modem AT 27.007 (état lu sur les VTY de bsc, msc et mobile), oFono pilote.
- Audio : deux chaînes PulseAudio duplex (intel-hda) — pont GAPK vers le mobile osmocom-bb, et une chaîne avec annulation d'écho.

### Ports et accès

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 4239 | VTY osmo-stp | | 8080 | tableau de bord du banc |
| 4242 | VTY osmo-bsc | | 8081 | spectres I/Q (fft-web) |
| 4243 | VTY osmo-mgw | | 9090 | Prometheus open5gs |
| 4254 | VTY osmo-msc | | 9999 | WebUI open5gs |
| 4258 | VTY osmo-hlr | | 5060 | Asterisk SIP |
| 4729 | GSMTAP (Wireshark) | | 2775 | SMPP |
| 2905 | M3UA local | | 7890 | relais SMS inter-op |
| 2908 | M3UA inter-STP | | 29118 | SGs (MSC ↔ MME) |

```bash
tmux attach -t calypso          # la pile 2G ; Ctrl-b d détache
journalctl -u osmo-banc -f      # si lancée en service
./start-direct.sh --status | --stop
./ss7-console.py                # schéma SS7 navigable, VTY intégrées
```

### Plan de numérotation

| Numéro | Usage |
|---|---|
| `100101`, `100102` | les deux abonnés du banc (un par cellule) |
| `N0001`…`N9999` | abonnés de l'opérateur N (multi-op) |
| `100` / `200` | Linphone A / B |
| `600` | echo test |
| `9XXXXX` | sortie inter-op depuis un softphone |

### Options les plus utiles

| Commande | Effet |
|---|---|
| `./start-direct.sh --list` | le plan, sans lancer |
| `./start-direct.sh --menu` | pose les questions au lieu de deviner |
| `./start-direct.sh --regen` | régénère les configs depuis les gabarits |
| `./start-direct.sh --dsp` | fork qosmo-dsp : le vrai DSP C54x (le mobile ne campe pas encore) |
| `./start-direct.sh --node 2 --hub-ip IP` | ce nœud = 2 d'un WAN, ASP vers l'inter-STP |
| `./start-direct.sh --wan` | WAN à N nœuds, questions interactives |
| `./generate_configs.sh ARFCN=520` | change une valeur de `globals.conf` |
| `sudo ./build-iso.sh --desktop` | reconstruire l'ISO desktop |
| `bash ./checks/check_all.sh` | check complet, journal dans `/tmp` |

### Fichiers à connaître

| Fichier | Rôle |
|---|---|
| `globals.conf` | la configuration réseau, fait autorité sur ses 26 variables |
| `environment/load.env` | l'ordre de chargement des profils et défauts |
| `/etc/osmocom/coeur.env` | `N_MS`, écrit par l'ISO |
| `/etc/osmo-wan.conf`, `/etc/osmo-role` | table WAN, rôle du nœud |
| `/etc/default/osmo-banc` | `OSMO_BANC_ARGS="--dsp"` pour le service |
| `/var/log/osmocom/{qemu,bridge,run.sh}.log` | QEMU, pont, orchestration |
| `pont/README.md` | à lire **avant** de chercher une panne radio dans un compteur de CRC |
