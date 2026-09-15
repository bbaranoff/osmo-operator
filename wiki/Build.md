# Build — image Docker, ISO, paquets `.deb`, installation native

Quatre chemins, un seul moteur de compilation. Tout ce qui se compile (libosmocore,
osmo-*, gapk, QEMU et son arbre, osmocom-bb, le venv gr-gsm, le firmware) sort en
paquet `.deb` et reste **sur l'hôte**, dans `/var/cache/osmo-debs`. Le premier
build compile tout ; les suivants ne compilent que ce qui manque.

```
build.sh ──► image osmocom-nitb ──► start.sh / compose.sh      (Docker)
     │              │
     │              └──► build-iso.sh ──► ISO amd64 / .img arm64   (bootable)
     └──► /var/cache/osmo-debs ──► packaging/build-debs.sh ──► dpkg -i   (sans git)
install.sh ─────────────────────────────────────────────────►  natif Ubuntu 24.04
```

---

## 1. `build.sh` — l'image Docker

```bash
sudo ./build.sh [--no-cache] [--lite] [--stp] [--arch=arm64|--arm]
```

| Option | Effet |
|---|---|
| *(rien)* | image `osmocom-nitb` (Dockerfile) : cœur + BTS + QEMU Calypso + gr-gsm + Asterisk |
| `--lite` | image `osmocom-nitb:lite` (Dockerfile.lite) : sans les ateliers |
| `--stp` | image `osmocom-stp` (Dockerfile.stp) : l'inter-STP seul, arm64 possible |
| `--no-cache` | cache docker ignoré **et** `OSMO_DEB_REFRESH=1` : tout est recompilé, le cache `.deb` réécrit |
| `--arch=arm64`, `--arm` | cross-build arm64 (Raspberry Pi 4) |

Ce que fait le script, dans l'ordre :

1. `cd` dans le répertoire du script (le `.desktop` passe par pkexec qui démarre dans `/root` — sans ce `cd`, `docker build .` cherche `/root/Dockerfile`).
2. `/usr/local/sbin` dans le `PATH` : c'est là que `packaging/apt-fast-install.sh` pose `apt-fast` (aria2). Même installeur sur l'hôte, dans les images et dans le rootfs ISO.
3. Installe Docker + **compose v2 + buildx** — dépendance, pas option. `compose.yaml` décrit les services `nitb`, `run`, `lite`, `stp`. `docker build` reste le repli.
4. Recopie `/var/cache/osmo-debs` dans `.deb-cache/` (le contexte docker). L'image pose ces paquets par `dpkg` au lieu de recompiler.
5. Construit. Chaque dossier compilé dans l'image sort en `.deb` via `packaging/osmo-deb.sh`.
6. Ramène ce que l'image a produit dans le cache de l'hôte.

Variables :

| Variable | Défaut | Rôle |
|---|---|---|
| `OSMO_DEB_CACHE` | `/var/cache/osmo-debs` | où vit le cache |
| `OSMO_DEB_REFRESH` | `0` | `1` = recompiler et réécrire (ce que pose `--no-cache`) |

```bash
./compose.sh debs                     # le contenu du cache
sudo ./compose.sh build [--no-cache] [--lite] [--stp]   # = build.sh
sudo ./compose.sh up [--ms 2] [--phy faketrx] [--no-run]  # hub + osmo-operator-1, HLR alimenté
sudo ./compose.sh down | ps | logs | shell
```

Durée du premier build : 15-20 min (osmocom-bb + toolchain ARM + QEMU).

---

## 2. `build-iso.sh` — ISO bootable / image SD

```bash
sudo ./build-iso.sh [options]
```

**Sans option** : les quatre images amd64 — `interstp`, `operator` (normale), `lite`,
`desktop`. Un **seul** build docker (`osmocom-nitb`), puis chaque rootfs en
dérive : interstp ; normale, de zéro ; lite = copie de la normale, ateliers
retirés ; desktop = la normale + le bureau. Seule exception : `--role=interstp`
seul ne construit que `osmocom-stp`.

### Quoi construire

| Option | Effet |
|---|---|
| `--role=operator\|interstp` | une seule image |
| `--node=N` | ISO pré-affectée au nœud N (sinon le nœud se choisit au lancement, `start-direct.sh --node`) |
| `--lite` | image sans ateliers |
| `--desktop` | GNOME, Conky d'état du banc, icônes « Lancer le banc GSM », « multi-operator », « osmo-lte », « Pilotes graphiques » |
| `--all` | tout |
| `--arm` | image SD arm64 pour Raspberry Pi 4, base Armbian 24.04 (`osmo-operator-<…>-rpi4.img`) ; `--lite` accepté, `--desktop` et `--all` refusés |
| `--version=24.04\|22.04` | base Ubuntu |
| `--kb=fr` | clavier |
| `--output=fichier` | nom de l'ISO |

### D'où vient l'image Docker

Par défaut (amd64) **l'image est tirée, pas construite**, dans l'ordre :
`ghcr.io/<dépôt>/osmocom-nitb:base-<empreinte du dépôt>` → `:latest` du même dépôt
→ Docker Hub. `build.sh` ne tourne que si aucune ne répond. L'empreinte est celle
des workflows : quand elle correspond, l'image publiée a été bâtie sur exactement
cet arbre ; les deux autres références ne le garantissent pas, et le script le dit.
En arm64 rien n'est publié : compilation par défaut.

| Option | Variable | Effet |
|---|---|---|
| `--skip-build[=image:tag]` | `OSMO_ISO_SKIP_BUILD` | pull obligatoire, pas de repli sur `build.sh` ; `=image` impose la référence. `OSMO_ISO_SKIP_BUILD=0` = ne jamais tirer |
| `--build-docker` | `OSMO_ISO_BUILD_DOCKER=1` | l'inverse, **et il gagne** : construit même si un `--skip-build` traîne |
| `--no-cache` | | passe à `build.sh` |

### Ce qui voyage dans l'image

| Option | Variable | Effet |
|---|---|---|
| *(défaut)* | | les `.deb` du cache sont posés dans le rootfs par `dpkg`, puis le reste de l'image recopié ; les paquets restent dans `/var/cache/osmo-debs` de l'ISO |
| `--without-debs` | `OSMO_ISO_WITHOUT_DEBS=1` | les `.deb` servent à poser la pile, **n'y restent pas** |
| | `ISO_EMBED_DEBS=1` | embarque aussi les `.deb` de `packaging/build-debs.sh` |

### Ce qui démarre au boot

Les unités `osmo-banc.service`, `osmo-multi.service`, `osmo-lte.service` sont
**posées mais non activées** : une machine fraîchement installée démarre sur son
bureau. C'est l'opérateur qui lance (icône, `launch.sh`, `systemctl start osmo-banc`).

| Option | Variable | Effet |
|---|---|---|
| `--banc` | `OSMO_ISO_BANC=1` | active `osmo-banc` au boot |
| `--multi` | `OSMO_ISO_MULTI=1` | active `osmo-multi` (`Requires=osmo-banc`, docker) |
| | `OSMO_ISO_LTE=1` | active `osmo-lte` |

Sur une machine déjà installée : `OSMO_MULTI_ENABLE=1 ./addition.sh`. Options
durables du service : `OSMO_BANC_ARGS="--dsp"` dans `/etc/default/osmo-banc`.

### WAN dans l'ISO

```bash
sudo ./build-iso.sh --wan --wan-nodes="1:IP:IND 2:IP:IND …" --wan-id=N --wan-ops=N --hub-ip=IP
```

Pose `WAN_AUTO=1` dans `/etc/osmo-wan.conf` : le banc monte le WAN sans question.
Sans `--node`, **une seule ISO sert pour les neuf nœuds** — le numéro se déduit
des IP locales ou se passe à `start-direct.sh --node N`.

### Divers

| Variable | Rôle |
|---|---|
| `OSMO_ISO_WORK` | répertoire de travail, **sur disque** (pas `/tmp`, souvent un tmpfs → « No space left on device ») |
| `OSMO_ISO_VERSION` | = `--version` |

Le disque installé par Calamares : comptes de l'écran « Utilisateurs » + root
déverrouillé (plus de compte `osmocom` du live) ; LUKS proposé (LVM en manuel,
`lvm2` embarqué) ; page « Pilotes graphiques » = `apt install nvidia-driver-610`
si `lspci` voit une carte (réseau requis), et l'icône `tools/osmo-drivers.sh`
après coup. `/etc/osmocom/coeur.env` (écrit par l'ISO) porte `N_MS`.

---

## 3. `packaging/build-debs.sh` — installer sans git

```bash
./packaging/build-debs.sh          # osmo-operator, pont, qemu-calypso, calypso-firmware → packaging/dist/
sudo dpkg -i packaging/dist/*.deb  # refuse de s'installer par-dessus un clone git au même chemin
```

`packaging/snapshot-lte-debs.sh` fige Open5GS / srsRAN ; `build-pmos-kernel-deb.sh`
le noyau postmarketOS du téléphone (PPP vers le netns `ue1`).

---

## 4. `install.sh` — natif, Ubuntu 24.04 (noble)

```bash
sudo ./install.sh                  # toutes les étapes
./install.sh --list                # les étapes, sans rien faire
./install.sh --check               # ce qui est déjà en place
./install.sh --dry-run
sudo ./install.sh --reinstall      # rejoue tout : sources à jour, configs et raccourcis réécrits
sudo ./install.sh --only bureau    # une seule étape (deps, sources, build, binaires, configs, bureau…)
sudo ./install.sh --skip build     # toutes sauf une
```

Les étapes vivent dans `install_modules/`. `bureau` pose les mêmes fichiers que
l'ISO (`data/desktop/*.desktop`, `data/*.svg`) dans le menu et sur le bureau de
root et de l'utilisateur `sudo`. L'installation native **n'active pas** les
unités systemd. Le lancement reste `./start-direct.sh`, qui délègue à
`/opt/GSM/qosmo-grgsm/run.sh`.
