# L'ISO osmo-operator — description complète, build, installation, capacités

Cette page décrit **tout ce que l'ISO est** : ce qu'elle contient, comment elle
se fabrique (`build-iso.sh` et ses modules), comment elle démarre, comment elle
s'installe sur un disque, et tout ce qu'elle sait faire une fois démarrée.
Elle renvoie aux fichiers du dépôt pour chaque point ; les pages
[Build](Build.md), [Start-direct](Start-direct.md) et [Environnement](Environnement.md)
détaillent les scripts eux-mêmes.

État de référence : **osmo-operator-desktop.iso v0.1-6** (tag `v0.1-6`, commit
`869f830`), plus les changements du 2026-10-01 décrits plus bas (DSP par défaut,
question LUKS sur la console, lanceurs GTK).

---

## 1. En bref

| Élément | Valeur |
|---|---|
| Base | Ubuntu 24.04 (noble), noyau `linux-image-generic` 6.8.0-146 |
| Taille (desktop) | ISO 6,5 Go · squashfs 6,3 Go (zstd -19, 41 % de 15,9 Go) · 314 178 fichiers |
| Boot | ISO hybride (dd sur clé, UEFI ou BIOS), Secure Boot shim → grub → noyau, entrée `toram` (9 Go de RAM) |
| Comptes live | `root` autologin (mdp `osmo`) · `osmocom` sudoer (mdp `osmo`) · téléphone pmOS `147147` |
| Build | `sudo ./build-iso.sh --desktop`, ~2 h 15 sur 16 cœurs ; image Docker tirée de ghcr.io sans recompilation ; debootstrap minimal + les `.deb` du build (~41) ; ~1 650 paquets en chroot ; contrôle d'intégrité dpkg avant et après squashfs |
| 2G | Banc complet (`launch.sh`, `osmo-banc`), 2 MS, A5/1, SMS inter-opérateurs, MSC avec SGs (CSFB) |
| Baseband émulé | QEMU `qosmo` (ARM7 + DSP C54x), 7 ROMs DSP, firmware layer1 pour 10 cartes, gdb/telnet, `c54x_exe`, `grgsm_exe` |
| 4G | srsENB/srsUE portables + srsGUI, Open5GS, freeDiameter TLS, MME SGsAP, console HSS `:9999`, abonnés dans Mongo |
| Téléphone | VM postmarketOS 1,7 Go (noyau PPP), pmbootstrap patché, pmaports `9479a409e3` |
| Bureau | GNOME minimal, Firefox (deb Mozilla, fr, uBlock), Wireshark, Linphone (poste 100), Kodi, dino, oFono, Conky, Plymouth `osmo-bts`, tableau de bord web + tutoriel |
| Audio | PulseAudio système, PipeWire pour le screencast seul, PCM `gsm_out`/`gsm_in` |
| Retiré | avahi, Chromium, sssd masqué, pipewire-pulse |
| Installation | Calamares (`osmo-install`), `/home` chiffré LUKS2 optionnel, `osmo-update` au boot |
| Services posés, non activés | `osmo-banc`, `osmo-multi`, `osmo-lte` (`--banc`, `--multi`, `OSMO_ISO_LTE=1` au build pour les activer) |

---

## 2. Les images produites

Une même chaîne (`build-iso.sh` + `iso_modules/`) produit cinq images. Sans
option, les quatre images amd64 sont construites à la suite (`--all`).

| Image | Fichier | Rôle | Contenu |
|---|---|---|---|
| Hub SS7 | `interstp.iso` | `--role=interstp` : l'inter-STP seul (PC 0.0.0), aucun opérateur ; refuse `--lite` et `--desktop` | image `osmocom-stp` (Dockerfile.stp), libosmocore/netif/sigtran seulement, `osmo-interstp.service` au boot |
| Opérateur | `osmo-operator.iso` | `--role=operator` (défaut) : le banc complet, sans bureau | pile 2G, baseband émulé, 4G, dashboard, outils ; console texte |
| Lite | `osmo-operator-lite.iso` | `--lite` : le même moins les ateliers de compilation | `/opt/GSM` élagué des arbres de sources (`iso_modules/87-lite.sh`, mêmes règles que `Dockerfile.lite`) |
| Desktop | `osmo-operator-desktop.iso` | `--desktop` : + GNOME, Wireshark, Linphone, VLC, Calamares, Conky, Firefox (~2,5 Go de plus) | c'est l'image publiée en release |
| Raspberry Pi 4 | `osmo-operator-…-rpi4.img` | `--arm` : image SD arm64 sur base Armbian 24.04 | pas de squashfs ni de GRUB, compilation native dans le chroot émulé (`82-arm-natif.sh`), une dizaine d'heures la première fois |

Avec `--node=N` (1 à 9), le nom devient `osmo-operator-N[-lite][-desktop].iso`
et l'image porte l'identité SS7 du nœud N. `--output=FICHIER` force le nom.

---

## 3. Obtenir, démarrer, se repérer

### 3.1 Télécharger

La [dernière release](https://github.com/bbaranoff/osmo-operator/releases/latest)
livre l'ISO desktop **en morceaux de 1 900 Mo** (GitHub plafonne un fichier de
release à 2 Gio) :

```bash
cat osmo-operator-desktop.iso.part-* > osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
```

### 3.2 Prérequis machine

x86_64, **8 Go de RAM et 4 cœurs minimum**. Le banc fait tourner deux QEMU (le
Calypso et la VM postmarketOS) : en machine virtuelle, activer la
virtualisation imbriquée. Sur matériel réel, KVM est là directement.

### 3.3 Démarrer

- **QEMU** : `qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080`
- **VirtualBox** : VM Linux/Ubuntu 64 bits, 8 Go, 4 CPU, 3D désactivée, *VT-x/AMD-V imbriqué* coché, NAT avec redirection 8080 → 8080.
- **VMware** : VM depuis l'ISO, *Virtualize Intel VT-x/EPT* coché, ignorer l'installation facile.
- **Clé USB** : `sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync` (Rufus en mode *Image DD* sous Windows). UEFI ou BIOS, au choix.

### 3.4 Le menu GRUB (`iso_modules/90-iso.sh`)

| Entrée | Ligne du noyau | Usage |
|---|---|---|
| Lecture depuis le médium (défaut) | `boot=live quiet` | la clé reste branchée, racine en overlay tmpfs |
| En RAM | `boot=live toram=filesystem.squashfs` | copie le squashfs seul en RAM (annoncé : 9 Go), la clé peut être retirée |
| Persistance | `boot=live persistence persistence-encryption=none quiet` | partition `persistence` sur la clé pour garder les changements |

La clé live démarre **sans** `splash` : Plymouth ne s'y montre pas. Le thème
`osmo-bts` (pylône, mobile et ondes) apparaît sur un disque installé, où GRUB
démarre en `quiet splash`.

### 3.5 Secure Boot (`iso_modules/91-secure-boot.sh`)

L'ISO est assemblée par xorriso avec le **shim signé Canonical** et le GRUB
signé (`shim-signed`, `grub-efi-amd64-signed`), plus un `/.disk/info` pour que
le GRUB signé retrouve le médium. La chaîne shim → grub → noyau Ubuntu est
complète : l'image démarre Secure Boot actif. Sans ces paquets sur l'hôte de
build, l'ISO sort non signée et le build le dit.

### 3.6 Le live : espace, journaux, réseau (`83-espace-ram.sh`, `81-cloture-systeme.sh`)

- `/dev/shm` et `/tmp` sont bornés en pourcentage de la RAM ; les cfiles I/Q,
  journaux et captures y vivent et sont purgés à chaque démarrage. Un wrapper
  `tcpdump` écrit en anneau de pcap.
- Aucune attente réseau au boot : les unités `*-wait-online` sont masquées,
  l'arrêt est plafonné à 30 s. DNS par le stub `systemd-resolved` avec un
  `resolv.conf` de secours. NetworkManager ignore `apn*`, `tun*`, `veth*`,
  `docker*`.
- `osmo-ip-plan.service` dérive les adresses privées du nœud ; `osmo-qemu-link`
  relie `QEMU_BIN` et recompile le lanceur `qosmo` si besoin.
- `osmo-update.service` fait un `git fetch` à avance rapide des dépôts
  embarqués à chaque démarrage (jamais de reclone, jamais d'apt), journal dans
  `/var/log/osmo-update.log`.
- À l'ouverture d'un shell interactif, une animation « SMS delivered » tourne
  une fois (`/usr/local/sbin/osmo-sms.sh`, l'ancien `update.sh`) et repose les
  icônes.

### 3.7 Comptes et sessions (`84-comptes.sh`)

| Compte | Mot de passe | Rôle |
|---|---|---|
| `root` | `osmo` | compte de travail du banc : autologin sur tty1, ttyS0 (ttyAMA0 sur Pi) et dans GDM |
| `osmocom` | `osmo` | non privilégié, sudoer (sudo, adm, dialout, audio, video, pulse-access, docker) ; session au choix après déconnexion |
| `linphone_A` | — | compte SIP pré-provisionné : poste **100**, UDP vers 127.0.0.1:5060 |
| pmOS `user` | `147147` | écran Phosh, compte et ssh de la VM postmarketOS |

Le banc tourne en root. Les icônes élèvent par `pkexec`, la ligne de commande
par `sudo`.

---

## 4. Ce que contient l'image

### 4.1 Arborescence utile

| Chemin | Contenu |
|---|---|
| `/opt/GSM/osmo-operator` | **le dépôt complet, avec son `.git`** (clone de la branche `main` au build, `51-depot.sh`) : scripts, configs, services, outils, wiki |
| `/opt/GSM/qosmo` | QEMU fork Calypso (`run.sh`, `run_modules/`), lanceur C `tools/qosmo-launch` |
| `/opt/GSM/c54x_exe` | le DSP TMS320C54x hors QEMU, mask-ROM TI dans `rom/`, son `run.sh` (5 étapes) |
| `/opt/GSM/grgsm_exe` | la couche 1 gr-gsm hors QEMU |
| `/opt/GSM/firmware/board/compal_e88/` | firmware OsmocomBB `layer1.highram.elf` et les dix cartes |
| `/opt/GSM/osmocom-bb` | osmocon, mobile, trxcon |
| `/opt/user_interface/pmos/` | pmbootstrap patché, noyau PPP, image de la VM `image/qemu-amd64.img.zst` (si embarquée), lanceurs `bin/` |
| `/etc/osmocom/` | configs Osmocom générées (PLMN 001-01, A5/1, 2 MS), `coeur.env` (`N_MS`, `OPERATOR_ID`), `osmo-multi.conf` après les suppléments |
| `/etc/asterisk/`, `/etc/asound.conf` | PBX voix, PCM `gsm_out`/`gsm_in` |
| `/var/cache/osmo-debs/` | les `.deb` du banc (osmo-operator, pont, qemu-calypso, calypso-firmware) pour une installation sans git |
| `/usr/share/osmo-operator/` | `info.html` (page Info), icônes SVG |
| `/var/log/osmocom/` | `qemu.log`, `bridge.log`, `run.sh.log` |

### 4.2 Paquets et chaîne logicielle (`80-chroot.sh`, `50-injection-image.sh`, `81-cloture-systeme.sh`)

- Base : `debootstrap --variant=minbase` noble, systemd, dbus, kmod, zstd,
  curl, iproute2, `live-boot`, noyau generic, libs Osmocom, tshark, openssh,
  cryptsetup.
- Banc : asterisk, pulseaudio, ffmpeg, MongoDB 8.0, NodeSource (dashboard),
  dépendances srsRAN et Open5GS, `build-dep gnuradio`, venv `/root/.env`.
- **Les binaires compilés viennent de l'image Docker `osmocom-nitb`** sous
  forme de `.deb` (`osmo-build-*~noble_amd64.deb`) installés par `dpkg -i`,
  puis `/usr/local/*`, `/opt/GSM`, `/root/.env`, `/opt/node`, `/etc/osmocom`,
  `/etc/asterisk` et les unités `osmo-*.service` sont copiés du conteneur.
- **Clôture `ldd`** : chaque `.so` utilisé dans l'image Docker est copié dans
  le rootfs ; `/usr/local/lib` passe en tête de `ldconfig`. L'environnement qui
  marche est celui de l'image, pas une version apt différente.
- Desktop : `ubuntu-desktop-minimal`, wireshark, linphone-desktop, vlc,
  calamares, conky, `python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-vte-2.91`, Firefox
  depuis packages.mozilla.org, GDM en autologin root sans Wayland.
- Contrôle d'intégrité : le rootfs est vérifié contre dpkg **avant** la
  compression, puis le squashfs est relu et revérifié (`90-iso.sh`).

---

## 5. Les capacités, une par une

Règle générale : **rien en 2G/4G ne démarre tout seul au boot**. Démarrer est
le geste de l'opérateur, par l'icône, la barre du bas, la ligne de commande ou
`systemctl`. Les unités sont posées et prêtes.

### 5.1 Le banc 2G autonome

Pile Osmocom complète en natif, un opérateur (PLMN 001/01), deux cellules
DCS1800 (ARFCN 514, LAC 1 ; BTS0 Cell ID 6001 BSIC 7, BTS1 Cell ID 6012 BSIC 8),
abonnés `100101` et `100102`.

- Composants : osmo-stp, osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn
  (GTPv1), osmo-pcu (GPRS/EDGE), osmo-mgw, Asterisk (voix MNCC via
  osmo-sip-connector, SIP :5060), SMSC (SMS-over-GSUP, SMPP :2775, relais
  inter-opérateurs :7890). Auth A3A8 à RAND déterministe. GSMTAP :4729 en
  direct pour Wireshark.
- Lancer : icône rouge **« Lancer le banc GSM »** (`launch.sh`, qui démarre
  `osmo-banc.service` et le dit par notification) ; barre du bas, groupe
  **Banc**, **run standalone** ; `sudo ./start-direct.sh` en premier plan ;
  `systemctl start osmo-banc`. La pile vit dans tmux : `tmux attach -t calypso`.
- Arrêter : clic droit **Arrêter le banc**, `./start-direct.sh --stop`
  (démonte aussi le banc DSP, sans retaper `--dsp`), `systemctl stop osmo-banc`.
- Sources : `start-direct.sh` (délègue à `/opt/GSM/qosmo/run.sh`),
  `launch.sh`, `services/osmo-banc.service`, `configs/*.cfg`,
  `generate_configs.sh`.

### 5.2 Deux chaînes de couche 1 : DSP (défaut) et gr-gsm

| | **DSP** `--dsp` (défaut depuis le 2026-10-01) | **gr-gsm** `--grgsm` |
|---|---|---|
| Qui démodule | le vrai TMS320C54x sur la mask-ROM TI, **hors** QEMU (`/opt/GSM/c54x_exe`) | un décodeur gr-gsm dans QEMU + pont `grgsm_exe` |
| QEMU | ARM7 seul (`CALYPSO_DSP_EXTERN=1`) | ARM7 + couche 1 gr-gsm |
| Pont TRX | `pont/pont_dsp.py` lancé par `c54x_exe/run.sh` (TRXD 5700-5702, bursts DL UDP 6702) | `pont/pont.py` |
| Résultat | le mobile acquiert FB/SB, décode SI1-4, campe, fait sa mise à jour de localisation ; VTY mobile :4347 | de bout en bout : camp, LU, auth, A5/1, SMS, appel voix ; VTY :4247 |

Le défaut vit en tête de `start-direct.sh` (`DSP_MODE=1`) et vaut pour tout
ce qui lance le banc (icône, service, barre, natif du multi). Si `c54x_exe`
manque, le banc le dit et retombe sur gr-gsm avec son pont. Clic droit de
l'icône : **« Lancer en mode gr-gsm »**. Durable : `OSMO_BANC_ARGS="--grgsm"`
dans `/etc/default/osmo-banc`.

### 5.3 Le baseband émulé Calypso

- QEMU fork **qosmo** (`-M calypso`, ARM7TDMI/arm946) exécute le firmware
  OsmocomBB réel `layer1.highram.elf`, chargé par osmocon comme sur un C123.
  Sept ROMs DSP, firmware pour dix cartes compal.
- Lanceur C `qosmo` (`/usr/local/bin/qosmo`) : `-gdb tcp::1234`, `-serial pty`
  publié en `<RUN_DIR>/modem.pty`, monitor unix, L1CTL `/tmp/osmocom_l2`.
- Debug : gdb sur :1234 (`target remote :1234` sur l'ELF layer1),
  monitor `socat - unix-connect:/tmp/qemu-calypso-mon.sock`,
  `--assembly-logs` pour la trace asm de l'ARM.
- Manuel : `qosmo -k …/layer1.highram.elf`, `MODE=dsp PONT=1 /opt/GSM/c54x_exe/run.sh`.

### 5.4 Profils et options de `start-direct.sh`

- Profils : `faketrx-qemu` (défaut, alias `hybrid` : cœur + BTS0 QEMU + BTS1
  fake_trx + MS#2), `faketrx`, `qemu` (Calypso seul), `noproc`/`core` (cœur seul).
- `--menu` pose les questions (couche 1, topologie seul/hybride, profil, nœud,
  WAN, régénération) au lieu de deviner.
- `--node N` (1-9) : l'identité SS7 du nœud (point codes `1.<nœud><op>.<rôle>`,
  routing contexts), ASP vers l'inter-STP ; `--op N`, `--hub-ip ADR`.
- `--wan`, `--wan FICHIER`, `--wan-nodes "1:IP:IND …"`, `--wan-id`,
  `--gen-conf`, `--air-mesh[=PORT]` (milieu radio commun inter-nœuds) :
  maillage de 1 à 9 nœuds. `--virtualbox[=N]` monte le WAN entre l'hôte et
  N-1 VM VirtualBox (`tools/vbox-wan-lab.sh`).
- `--regen`, `--list`, `--dry-run`, `--status`, `--check-paths`, `--force`,
  `--verbose`, `--launcher <bin>`, clients L2 exclusifs `--mobile`,
  `--ccch_scan`, `--bcch_scan`, `--cell_log`.
- Variables : `ENCRYPTION="a5 1"`, `MS_COUNT=2`, `CALYPSO_BRIDGE`,
  `BANC_DSP`, et toute variable de `globals.conf` posée non vide sur la ligne
  de commande (voir [Environnement](Environnement.md)).

### 5.5 Le multi-opérateur SS7 (Docker) et les suppléments

Pas dans l'ISO : l'icône **« Supplements »** (`addition.sh`, fenêtre à cocher,
dans une fenêtre GTK du banc) installe ce qui manque.

- **`--multi`** : docker.io, l'image opérateur tirée de
  `ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest` puis dérivée en
  `osmocom-run` (Dockerfile.run), la topologie `/etc/osmocom/osmo-multi.conf`
  (op1 **natif** PC 1.1.2 + op2/op3 **docker** 172.20.0.12/.13 PC 1.2.2/1.3.2 +
  hub `osmo-inter-stp` 172.20.0.10, M3UA :2908), `osmo-multi.service` et
  l'icône antenne **« multi-operator »**. Il termine par une session du banc
  multi via `launch.sh --multi`, le même chemin que l'icône
  (`OSMO_MULTI_START=0` pour poser sans lancer). `addition.sh --status` montre
  docker, l'image, la topologie, l'unité et l'icône.
- Lancer ensuite : icône antenne, barre **run multi**, `systemctl start osmo-multi`,
  `sudo ./start-multi.sh` (`--status`, `--stop`, `--dry-run`). Le natif est
  tenu par `osmo-banc` et relancé au besoin par `start-multi.sh`.
- **`--opencl`** : pile OpenCL (ocl-icd, clinfo, pocl, pilote Intel/Mesa/NVIDIA
  détecté) et les outils clonés dans `/root` : **deka**, a51_tools,
  dst80_reversing, tea1-cracker. Icône **deka**, barre **run deka**.
- **`--claude`** : Claude Code (installeur natif, binaire autonome). L'icône
  **Claude** s'auto-installe au premier clic.
- **`--extras`** : Doom (freedoom), Quake III (OpenArena), Kodi, YouTube
  (Firefox + uBlock), Wireshark root, Linphone, rangés dans les dossiers Jeux,
  Media, Telephone, Outils de la barre.

### 5.6 La 4G (srsRAN + Open5GS) et le CSFB

- Cœur **Open5GS** complet sur loopbacks (MME, SGW-C/U, SMF, UPF, PCRF, HSS,
  NRF…), MongoDB derrière le HSS, **freeDiameter** avec certificats TLS posés,
  Prometheus :9090, **WebUI :9999** (`open5gs-webui.service`, Next.js) pour les
  abonnés.
- Radio **srsENB** (10 MHz, EARFCN 3350, bande 7) et **srsUE** reliés en
  **ZeroMQ** (:2000/:2001), binaires portables (sans AVX du CPU de build),
  **srsGUI** pour les traces temps réel (`osmo-lte start-gui`). Abonné milenage
  IMSI 001010001000001, UE dans un netns `ue1`, data par `ogstun`
  (10.45.0.0/16) avec NAT vers Internet.
- **CSFB** : interface SGs entre osmo-msc et le MME (:29118), table
  TAI (001-01, TAC 7) → LAI (001-01, LAC 1).
- Lancer : icône **« 4G du banc »** (`osmo-lte toggle` → `osmo-lte.service`) ;
  `osmo-lte start|stop|status|up|down|log|journal|start-gui` ; cœur seul
  `osmo-epc start|stop|status`. Journal et état dans des fenêtres GTK du banc.
- Sources : `tools/osmo-lte.sh`, `tools/osmo-epc.sh`, `tools/osmo-lte-install.sh`,
  `configs/srsran/`, `configs/open5gs/`, `services/osmo-lte.service`,
  `iso_modules/88-lte-pmos.sh`.

### 5.7 Le téléphone postmarketOS

- VM x86_64 postmarketOS/Phosh (1,7 Go compressés), noyau patché avec PPP,
  pmbootstrap patché (port série du modem, cartes son, taille d'écran).
- **Data 4G** : NetworkManager → pppd (`ATD*99***1#`) → virtio-console
  `osmo.data` → `osmo-phonesim-banc.py` → netns UE → srsUE → srsENB → UPF →
  Internet. **Voix et SMS 2G** : virtio-console `osmo.modem`, le modem AT
  27.007 est joué par `osmo-phonesim-banc.py` d'après les VTY bsc/msc/mobile ;
  oFono le pilote côté VM.
- Lancer : icône **Téléphone** (`osmo-pmos up`), formats **smartphone**
  (720x1440) et **tablette** (1280x800) (`osmo-pmos-qemu`), actions état,
  arrêt, rebrancher le modem (`osmo-pmos-setup`), VM seule sans modem.
- **L'image** : `osmo-pmos-build` décompresse
  `/opt/user_interface/pmos/image/qemu-amd64.img.zst` au premier lancement. Si
  elle manque ou est corrompue (`zstd -t`), elle est reprise sur la release
  GitHub `pmos-image` (reprise possible, archive vérifiée) ; sinon
  `pmbootstrap install` la construit. `OSMO_PMOS_IMAGE_URL` change l'adresse.
- Sources : `tools/osmo-pmos*.sh`, `tools/osmo-phonesim-banc.py`,
  `tools/osmo-ofono-bridge.py`, `iso_modules/88-lte-pmos.sh`.

### 5.8 Le bureau

- **GNOME** minimal, session root, dock avec les favoris : Firefox, Fichiers,
  Claude, Lancer le banc, Installer, Tutoriel, Info, Supplements,
  multi-operator, Update, Paint, deka, Linphone, Wireshark, Téléphone, 4G.
- **Aucun favori n'ouvre de terminal.** Tout passe par `tools/osmo-gtk-run.py` :
  une fenêtre GTK du banc qui montre la sortie de la commande (journal
  copiable) ou, pour ce qui est interactif ou anime la ligne, un terminal VTE
  dans la fenêtre. Elle dit quand c'est fini et avec quel statut.
- **Barre du bas** (`tools/osmo-launcher.py`) : groupes Banc (run standalone,
  run multi, run deka, Dashboard, tmux, VTY), Jeux, Media, Telephone, Outils ;
  les « run » tournent en fond avec leur journal déplié dans la barre ; le
  grand **?** rouge ouvre la page Info.
- **Encart** (`tools/osmo-panel.py`, `osmo-fft-snap.py`) : l'illustration
  devient le spectre I/Q et le `mobile.log` quand le banc tourne ; bandeau
  haut (`osmo-topzone.py`, `configs/conky/labgsm.html`) alimenté par
  `osmo-ts-probe.py` : 8 timeslots, démons, abonnés, appels, uptime.
- **Conky** d'état en haut à droite (machine, opérateur sélectionné,
  `Ctrl+AltGr+←/→` ou `osmo-op --next`).
- **Tableau de bord web** :8080 (`osmo-egprs-web.service`, HTTPS auto-signé
  sur :80, capture GSMTAP/SCTP), **tutoriel** (`osmo-tutorial`), **page Info**
  (`osmo-info`, `configs/info.html`), spectres I/Q `fft-web` :8081.
- Applications : Firefox (seul navigateur, politique micro et certificat posée
  au boot), **Wireshark en root** (`osmo-wireshark-root`, filtres 2G/4G/appel/
  SMS/data), **Linphone** poste 100, Kodi, dino, oFono, Paint (overlay),
  Pilotes graphiques (`tools/osmo-drivers.sh`, NVIDIA par `ubuntu-drivers`).
- **Plymouth** `osmo-bts` : pylône, mobile et ondes (anneaux), rien d'autre
  (aperçu : `wiki/plymouth-osmo-bts.gif`). Généré au build par
  `tools/plymouth-render.py` (`86-finitions.sh`).
- Fond d'écran : `/usr/share/backgrounds/gsm-lab-wallpaper.jpg`
  (`tools/wallpaper-render.py`).

### 5.9 Audio

- **PulseAudio système** (`osmo-pulse.service`, socket `/run/pulse/native`,
  sink `gsm_audio`) : osmo-gapk → ALSA `gsm_out` → sink null → monitor →
  loopback ; PCM `gsm_out`/`gsm_in` dans `/etc/asound.conf`, que `mobile`
  ouvre. Deux chaînes duplex pour le téléphone pmOS (pont GAPK, annulation
  d'écho).
- **PipeWire** gardé **pour le screencast GNOME seulement** ;
  `pipewire-pulse` purgé et masqué.
- Sources : `iso_modules/82-services.sh`, `scripts/pulse-gsm-setup.sh`,
  `scripts/audio-chain.sh` (PulseAudio allégé à chaque start).

### 5.10 Diagnostics

`bash ./checks/check_all.sh` lance tout et rend un verdict (journal dans
`/tmp`) : `global_check.sh` (STP/HLR/MSC/BSC par opérateur), `ss7_check.sh`
(matrice inter-STP), `diag-stp-operator.sh`, `diag-interstp.sh`,
`wan_ss7_check.sh`, `annuaire.sh` (abonnés), `operator_summary.sh`,
`vty-debug-dump.sh`. `./ss7-console.py` : schéma SS7 navigable avec les VTY
intégrées. `./start-direct.sh --status` dit ce qui tourne.

### 5.11 Ports, VTY, réseau

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 4239 | VTY osmo-stp | | 8080 | tableau de bord du banc |
| 4242 | VTY osmo-bsc | | 8081 | spectres I/Q (fft-web) |
| 4243 | VTY osmo-mgw | | 9090 | Prometheus Open5GS |
| 4245 | VTY osmo-sgsn | | 9999 | WebUI Open5GS (HSS) |
| 4254 | VTY osmo-msc | | 5060 | Asterisk SIP |
| 4258 | VTY osmo-hlr | | 2775 | SMPP |
| 4260 | VTY osmo-ggsn | | 7890 | relais SMS inter-op |
| 4247 / 4248 | VTY mobile 1 / 2 (gr-gsm) | | 29118 | SGs (MSC ↔ MME) |
| 4347 | VTY mobile (banc DSP) | | 2905 / 2908 | M3UA local / inter-STP |
| 4729 | GSMTAP (Wireshark) | | 5700-5702 | TRXD (pont ↔ osmo-bts-trx) |
| 4730 / 4731 | SI / SCH décodés | | 6702 | bursts DL vers le DSP |
| 1234 | gdb QEMU | | 2000 / 2001 | ZeroMQ srsENB ↔ srsUE |

Réseau : interco docker `gsm-inter` 172.20.0.0/24 et `gsm-net-opN`
172.20.N.0/24 ; IP privée du nœud `192.168.<N+1>.10` ; LTE `ogstun`
10.45.0.0/16. Plan de numérotation : `100101`/`100102` (les deux abonnés),
`N0001`…`N9999` (opérateur N en multi), `100`/`200` (Linphone), `600` (écho),
`9XXXXX` (sortie inter-op).

### 5.12 Ce qui a été retiré, et pourquoi

| Retiré | Raison | Source |
|---|---|---|
| avahi (daemon, utils, autoipd, libnss-mdns) | pas de mDNS sur un banc ; purgé et masqué | `80-chroot.sh` |
| Chromium | Firefox seul navigateur, démarre en root sans intermédiaire | `86-finitions.sh` |
| sssd | masqué, pas désinstallé (aucun domaine) : `systemctl unmask sssd` le rend | `86-finitions.sh` |
| pipewire-pulse | PulseAudio système à la place ; pipewire gardé pour le screencast | `80-chroot.sh` |
| icône `osmo-dsp` | le DSP est le défaut, le clic droit propose gr-gsm | `85-installeur-bureau.sh` |
| `osmo-trust-desktop` et les icônes sur le bureau | les lanceurs sont dans le dock et le menu | `85-installeur-bureau.sh` |

---

## 6. Installer sur un disque

### 6.1 Lancer l'installateur

Icône **« Installer »** du dock, ou `osmo-install` (`/usr/local/bin`, écrit
par `85-installeur-bureau.sh`). Il repasse root par `pkexec`, retrouve le
squashfs quel que soit le mode de boot (médium, `toram`, loop) et le monte à un
chemin stable (`/run/osmo-install-src/live/filesystem.squashfs`), démonte une
cible restée montée d'un essai précédent, régénère la page des miroirs apt
classés par rapidité (`packaging/apt-mirror.sh --list`), puis ouvre Calamares
avec la configuration du dépôt (`installer/calamares/`, copiée dans
`/etc/calamares` au build).

### 6.2 Les écrans (`installer/calamares/settings.conf`)

Bienvenue (20 Go, 2 Go de RAM, root obligatoire) → Emplacement
(Europe/Paris) → Clavier (pc105) → Partitions → Utilisateurs → Pilotes
graphiques → Miroir Ubuntu → Résumé → Installer → Terminer. Le diaporama
pendant la copie reprend la fiche de l'image (`branding/osmo/show.qml`).

### 6.3 Partitionnement (`modules/partition.conf`)

- Table **GPT**, ext4, ESP de 300 Mio sur `/boot/efi`, pas de swap par
  défaut (`swapfile` au choix).
- Disposition automatique : **« osmo-egprs » sur `/`** (50 %, 25 Gio
  minimum, **jamais chiffrée**) et **« crypthome » sur `/home`** (le reste,
  5 Gio minimum).
- **Cocher « chiffrer » chiffre `/home` seul**, en LUKS2 : la racine reste
  lisible, les secrets (profils, trousseaux, cookies) sont sur le volume
  chiffré. Partitionnement manuel autorisé.

### 6.4 Comptes et pilotes

- Utilisateurs : le compte créé est sudoer (sudo, adm, dialout, audio, video,
  pulse-access, docker…), en autologin GDM ; le mot de passe root est demandé
  (`setRootPassword`), aucune exigence de complexité ; le nom `root` est
  interdit.
- Pilotes graphiques : défaut nouveau (libre) ; option **NVIDIA 610
  propriétaire**, installée dans la cible seulement si `lspci` voit une carte
  10de et si le réseau répond (`apt-get install nvidia-driver-610`, puis
  `update-initramfs`).
- Miroir : celui de la clé live ou un miroir mesuré.

### 6.5 Ce que l'installateur fait dans la cible (`modules/shellprocess-osmo.conf`)

1. Déverrouille root (`passwd -u root`).
2. Supprime le compte `osmocom` de la clé live (sauf si c'est le nom choisi).
3. `crypthome-postinstall <utilisateur>` : raccorde le `/home` chiffré (voir 6.7).
4. Retire les autologin root de tty1 et ttyS0.
5. GDM : `AutomaticLogin=<utilisateur>` ; la règle PAM qui refuse root à
   l'écran de connexion est rétablie.
6. Copie les lanceurs de `/etc/skel` sur le bureau de l'utilisateur.
7. Pose et active `osmo-egprs-web.service`.
8. Retire les icônes `osmo-install` et `calamares` du menu.
9. Génère `~/.config/pmbootstrap_v3.cfg` pour l'utilisateur.
10. Purge `live-boot`, refait l'initramfs.

GRUB : `/EFI/ubuntu` (prefixe compilé dans le GRUB signé), `GRUB_TIMEOUT 5`,
os-prober actif, `GRUB_ENABLE_CRYPTODISK=y`, ligne du noyau héritée de la clé
(`quiet splash`). fstab : `noatime`, `discard` sur SSD.

### 6.6 Après installation : comptes et services

| | Clé live | Disque installé |
|---|---|---|
| Session GDM | root, automatique | l'utilisateur créé, automatique |
| root | mdp `osmo` | mdp choisi à l'installation, déverrouillé |
| `osmocom` | sudoer, mdp `osmo` | supprimé |
| `osmo-egprs-web` | actif | actif |
| `osmo-banc`, `osmo-multi`, `osmo-lte` | posés, non activés | posés, non activés |

Activer un banc à chaque démarrage : `systemctl enable --now osmo-banc`
(ou `osmo-multi`, `osmo-lte`). Au build : `--banc`, `--multi`,
`OSMO_ISO_LTE=1`. Sur disque pour le multi : `OSMO_MULTI_ENABLE=1 ./addition.sh`.

### 6.7 Le `/home` chiffré au quotidien (`configs/crypthome/`)

- **Au démarrage**, `unlock-home.service` pose une seule question, sur la
  console texte, après avoir quitté Plymouth :
  `decrypt /home -passphrase- or Enter`. La phrase (tapée en `*`) ouvre le
  volume et la session de l'utilisateur. **Entrée à vide, délai de 60 s,
  trois phrases refusées, disque absent ou montage raté : la machine démarre
  quand même**, sur une session **root éphémère** (GDM passe sur root pour ce
  démarrage seul ; `/root` est recouvert d'un overlay dont les écritures vont
  dans un tmpfs). Le boot n'est jamais bloqué.
- `CRYPTHOME_PROMPT=plymouth` dans `/etc/default/crypthome` remet la question
  dans le thème Plymouth (à réserver aux machines où son clavier répond ; sur
  un portable Intel + NVIDIA il ne prenait aucune touche).
- Après coup : `unlock-home` / `lock-home` dans un terminal ; les
  applications à secrets (Firefox, Thunderbird, KeePassXC…) tournent sous le
  propriétaire du volume par `run-as-owner` quand il est ouvert, sous root
  sinon (`refresh-owner-apps` redirige les lanceurs).
- Second disque ajouté plus tard : `/root/init-crypthome.sh` (LUKS2,
  recopie `rsync`, crypttab/fstab en `noauto`, service activé, l'ancien
  `/home` mis de côté dans `/var/backups/home-avant-chiffrement-*` au
  redémarrage suivant).

### 6.8 Mettre à jour une machine installée

- `osmo-update` (au boot, ou à la main) : `git fetch` à avance rapide de
  `/opt/GSM/osmo-operator` et des dépôts embarqués. Pas de paquets.
- Ce qui est posé **hors** du dépôt par le build (unités dans
  `/etc/systemd/system`, `unlock-home` dans `/usr/local/sbin`, lanceurs
  `osmo-*-anim`) se repose à la main depuis `services/` et
  `configs/crypthome/`, ou par une réinstallation.
- `addition.sh` et `update.sh` réécrivent les `.desktop` qu'ils possèdent.

---

## 7. Construire l'ISO

### 7.1 D'où viennent les morceaux

```
image Docker osmocom-nitb (compilée par build.sh, ou TIRÉE de ghcr.io)
        │  .deb osmo-build-*  +  /usr/local, /opt/GSM, venv, configs
        ▼
debootstrap minbase noble ──► rootfs ──► chroot (paquets apt, bureau, 4G, pmOS…)
        │                                   │
        │   clone GitHub de osmo-operator ──┘  (51-depot.sh : branche main)
        ▼
squashfs zstd -19 ──► ISO hybride xorriso + shim/grub signés (ou image SD arm64)
```

- **L'image Docker n'est pas reconstruite par défaut** (amd64). Ordre du
  pull : `ghcr.io/<dépôt>/osmocom-nitb:base-<empreinte>` (l'empreinte est le
  sha256 des fichiers suivis dans Dockerfile, packaging, configs, scripts,
  services, helpers, opt-gsm, tools, patches : quand elle correspond, l'image
  publiée a été bâtie sur exactement cet arbre), puis `:latest` du dépôt, puis
  l'image Docker Hub. `build.sh` ne tourne que si aucune ne répond,
  ou avec `--build-docker`.
- **Le dépôt gravé dans l'ISO est un clone de la branche `main` sur GitHub**,
  pas l'arbre local : il faut pousser avant de graver. Pour graver l'arbre
  local, `OSMO_EGPRS_REPO=/chemin/du/depot OSMO_EGPRS_BRANCH=<branche>`.
- **Les modules `iso_modules/` et `build-iso.sh`, eux, sont lus depuis
  l'arbre local** au moment du build.

### 7.2 Prérequis hôte (`iso_modules/20-hote.sh`)

Ubuntu 24.04 en root, docker (installé s'il manque), et les paquets posés par
le module : debootstrap, git, rsync, zstd, xz, cpio, gcc, make, python3-pil,
python3-yaml, kpartx, dosfstools, mtools ; en amd64 squashfs-tools, xorriso,
grub-pc-bin, grub-efi-amd64-bin et -signed, shim-signed, isolinux,
syslinux-utils ; en arm64 qemu-user-static, binfmt-support, docker-buildx.
`OSMO_ISO_HOST_READY=1` saute cette étape. Aucun contrôle d'espace disque
n'est fait : prévoir large dans `/var/tmp` (le répertoire de travail est
`/var/tmp/iso-build-<pid>`, jamais `/tmp`, souvent un tmpfs : rootfs, squashfs
et ISO y tiennent ensemble) et pour le store docker (image de base ~11 Go).

### 7.3 La commande

```bash
sudo ./build-iso.sh --desktop                 # l'image publiée
sudo ./build-iso.sh                           # les quatre images amd64
sudo ./build-iso.sh --role=operator --node=2  # l'opérateur du nœud 2
sudo ./build-iso.sh --arm --lite              # image SD Raspberry Pi 4
```

| Option | Variable | Effet |
|---|---|---|
| `--role=operator\|interstp` | `ISO_ROLE` | banc ou hub SS7 |
| `--node=N` | `ISO_NODE`, `ISO_WAN_ID` | identité du nœud 1-9, nom `osmo-operator-N` |
| `--lite`, `--desktop`, `--all` | `ISO_LITE`, `ISO_DESKTOP`, `ISO_ALL` | voir §2 |
| `--arm` / `--arch=arm64` | `ISO_ARCH` | Raspberry Pi 4 (Armbian, ports.ubuntu.com) |
| `--banc`, `--multi` | `OSMO_ISO_BANC`, `OSMO_ISO_MULTI` | activer l'unité au boot de l'image |
| `--version=24.04\|22.04` | `ISO_UBUNTU`, `ISO_SUITE` | noble (défaut) ou jammy |
| `--kb=fr` | `OSMO_ISO_KB` | disposition clavier (demandée au terminal sinon) |
| `--output=FICHIER` | `OUTPUT` | nom de sortie |
| `--no-cache` | `NO_CACHE` | recompilation complète, `.deb` refaits |
| `--skip-build[=image:tag]` | `ISO_SKIP_BUILD`, `ISO_PULL_IMAGE` | pull obligatoire, sans repli sur build.sh |
| `--build-docker` | `ISO_FORCE_BUILD` | construire l'image localement |
| `--without-debs` | `ISO_WITH_DEBS` | pas de `.deb` du banc dans l'image |
| `--wan`, `--wan-nodes=`, `--wan-id=`, `--wan-ops=`, `--hub-ip=` | `ISO_WAN*`, `ISO_HUB_IP` | table WAN gravée dans `/etc/osmo-wan.conf` |

Autres variables : `OSMO_ISO_WORK` (répertoire de travail), `OSMO_DEB_CACHE`
(`/var/cache/osmo-debs`), `OSMO_ISO_LTE=1`, `OSMO_ISO_PMOS_IMAGE`
(`/chemin/qemu-amd64.img.zst` ou `none`), `OSMO_PMOS_IMAGE_URL`,
`OSMO_ISO_LTE_BUILD=0` (pas de compilation 4G si les `.deb` manquent),
`OSMO_EGPRS_REPO`/`OSMO_EGPRS_BRANCH`, `OSMO_WEB_REPO` (dashboard).

### 7.4 La chaîne des modules (`iso_modules/`)

Tous sont sourcés dans le même shell, dans l'ordre numérique ; un module qui
n'a rien à faire sort par `return` (c'est ainsi que `--arm` saute une étape).

| Module | Ce qu'il fait |
|---|---|
| `00-options.sh` | options, aide, suite, miroir, contrôle root |
| `10-clavier.sh` | disposition clavier (menu si terminal, sinon `fr`) |
| `20-hote.sh` | paquets de l'hôte, docker, outils, binfmt arm64 |
| `21-docker-build.sh` | pull ou build de l'image Docker, passes filles de `--all`, noms de sortie |
| `22-wan-table.sh` | table WAN, `trap cleanup`, vérification des outils |
| `30-image-configs.sh` | configs Osmocom générées depuis les gabarits (`start.sh`), patches natifs |
| `31-image-source.sh` | image source, contrôle de suite, injection de `/etc/osmocom` et `/etc/asterisk` |
| `40-rootfs.sh` | `debootstrap --variant=minbase` (cache `~/.cache/osmo-iso-debs`), ou rootfs hérité |
| `50-injection-image.sh` | `.deb` du build par `dpkg -i`, copie de `/usr/local`, `/opt/GSM`, venv, node, unités |
| `51-depot.sh` | clone de osmo-operator et des tests, `coeur.env` |
| `51-shannon.sh` | clone de `bbaranoff/firmwire` (`/opt/GSM/FirmWire`) et `bbaranoff/shannon_ghidra_proj` (`/opt/GSM/shannon_ghidra_proj`) |
| `52-qemu.sh` | qosmo, c54x_exe, grgsm_exe, ROMs DSP, firmware, qemu-system-arm, lanceur `qosmo`, toast/untoast |
| `60-dashboard.sh` | osmo-egprs-web (natif, sans docker), tutoriel, unité activée |
| `70-scripts.sh` | liens `/usr/local/bin`, `osmo-wan.conf`, NetworkManager |
| `71-debs-banc.sh` | `packaging/build-debs.sh` → `/var/cache/osmo-debs` du rootfs |
| `80-chroot.sh` | dépôts apt (NodeSource, MongoDB, Armbian), noyau, paquets, venv, bureau, Firefox, GDM, gsettings, `update-initramfs` |
| `81-cloture-systeme.sh` | clôture `ldd` depuis l'image, réseau sans attente, DNS, `osmo-ip-plan`, `osmo-qemu-link`, `osmo-update`, animation SMS |
| `82-arm-natif.sh` | `--arm` : compilation native dans le chroot arm64 |
| `82-services.sh` | marqueur de rôle, os-release, Asterisk, audio (PulseAudio système, `asound.conf`), unités posées non activées, WebUI Open5GS |
| `83-espace-ram.sh` | fstab, `/tmp` et `/dev/shm` en % de RAM, journal, logrotate, tcpdump en anneau, ssh, purge |
| `84-comptes.sh` | root et osmocom, autologin console et GDM, compte Linphone |
| `85-installeur-bureau.sh` | Calamares (`/etc/calamares`), `osmo-install`, icônes, lanceurs GTK (`osmo-*-anim`), page Info |
| `86-finitions.sh` | live-boot `toram` corrigé, sssd masqué, Chromium retiré, micro Firefox, bannière screenfetch, Plymouth `osmo-bts` |
| `87-lite.sh` | élagage `--lite` de `/opt/GSM` |
| `88-lte-pmos.sh` | srsRAN + Open5GS (depuis les `.deb`, sinon compilation), freeDiameter, pmbootstrap, noyau PPP, image de la VM, contrôle final 2G + 4G + téléphone |
| `89-home-chiffre.sh` | outils crypthome, `unlock-home.service`, trousseau de root sur le volume chiffré, lanceurs sous `run-as-owner` |
| `90-iso.sh` | contrôle dpkg, squashfs zstd -19, noyau, menu GRUB, `/.disk/info`, relecture du squashfs |
| `91-secure-boot.sh` | ISO xorriso avec shim et GRUB signés (ou `grub-mkrescue` non signé) |
| `92-rpi-image.sh` | `--arm` : image SD (partition boot + ext4 Armbian) |
| `99-fin.sh` | rootfs transmis à la passe suivante (`--all`), résumé |

### 7.5 La CI (`.github/workflows/build-iso.yml`)

- Déclencheurs : push d'un tag `v*` ou `iso-*`, ou lancement manuel avec
  les entrées `release`, `no_cache`, `build_docker`, `mode`
  (all, stp, base, lite, desktop) et `pmos_image` (embarque la VM
  postmarketOS, +1,7 Go par ISO).
- Un seul job sur `ubuntu-24.04` (6 h maximum) : nettoyage du runner, docker
  déplacé sur `/mnt`, cache des `.deb` par empreinte
  (`osmo-debs-noble-g2-<empreinte>`). Si `ghcr.io/…/osmocom-nitb:base-<empreinte>`
  existe, elle est tirée (`--skip-build=REF`) ; sinon `--build-docker`.
- Sorties : `SHA256SUMS`, `MD5SUMS`, découpage des fichiers de plus de
  2 Gio en `*.iso.part-NN` (1 900 Mo) avec `PARTS.sha256`, artefact 14 jours,
  release GitHub (`softprops/action-gh-release`) avec les notes de
  `.github/release-notes.md`, pré-release sauf sur un tag `v*`.

### 7.6 Durées et tailles

| | |
|---|---|
| Build desktop, image Docker tirée | ~2 h 15 sur 16 cœurs |
| Compilation Docker complète (`--build-docker`) | 1 h 23 en CI (`wiki/Build.md` annonce 15-20 min sur une machine de référence) |
| ISO desktop | 6,5 Go (4 morceaux en release) |
| Desktop vs operator | +2,5 Go |
| Image Docker de base | ~11 Go |
| `--arm` première fois | une dizaine d'heures (émulation) |

---

## 8. Fichiers à connaître

| Fichier | Rôle |
|---|---|
| `build-iso.sh`, `iso_modules/` | la chaîne de build |
| `installer/calamares/` | l'installateur (modules, habillage, diaporama) |
| `configs/crypthome/` | `/home` chiffré : `unlock-home`, `crypthome-postinstall`, `init-crypthome.sh`, `run-as-owner` |
| `configs/plymouth/osmo-bts/`, `tools/plymouth-render.py` | le thème de démarrage, généré |
| `services/*.service` | `osmo-banc`, `osmo-multi`, `osmo-lte`, `osmo-egprs-web`, `open5gs-webui` |
| `data/desktop/*.desktop` | les icônes du dock ; `tools/osmo-gtk-run.py` les fenêtres |
| `/etc/default/osmo-banc`, `/etc/default/osmo-multi`, `/etc/default/osmo-lte` | options durables des services |
| `/etc/default/crypthome` | UUID, propriétaire, délai, `CRYPTHOME_PROMPT` |
| `/etc/osmocom/coeur.env`, `/etc/osmo-wan.conf`, `/etc/osmo-role` | nœud, WAN, rôle de l'image |
| `/var/log/osmocom/`, `journalctl -u osmo-banc` | journaux du banc |
| `addition.sh` | les suppléments (docker/multi, OpenCL/deka, Claude, extras) |
| `checks/check_all.sh`, `ss7-console.py` | diagnostics |
