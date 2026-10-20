# Installation depuis zero (generee depuis le Dockerfile)

> Fichier genere par `tools/dockerfile-to-install-md.sh` le 2026-10-20 depuis `Dockerfile`. Ne pas editer a la main : corriger le Dockerfile ou le script, puis regenerer.

## Comment lire cette page

Le Dockerfile d'osmo-operator est la description complete et testee de l'installation. Cette page le rejoue
etape par etape sur une machine nue (Ubuntu 24.04, en root), sans Docker :

- chaque `FROM ... AS <nom>` du Dockerfile est un chapitre ; sur une seule machine les etapes se suivent
  simplement, les `COPY --from=<etape>` ne sont plus necessaires (tout est deja en place) ;
- chaque `RUN` est un bloc bash a coller tel quel dans un shell root, dans l'ordre ;
- chaque `ARG`/`ENV` devient un `export` a poser avant les blocs qui suivent (les `ARG` ne traversent pas
  un `FROM` dans Docker, ici on les garde dans le shell) ;
- chaque `COPY` devient un `cp` depuis une copie du depot osmo-operator (`$REPO`, par defaut `/opt/GSM/osmo-operator`).

Le cache de paquets `.deb` (`osmo-deb install <nom> <version>`) est une optimisation du build Docker :
sans cache, la commande echoue et la branche `if ! osmo-deb install ...; then ... fi` compile depuis les
sources, ce qui est exactement ce qu'on veut sur une machine nue. `osmo-deb pack` emballe ensuite le
resultat (`make install`) ; sans `/var/cache/osmo-debs` il se contente d'installer.

```bash
export REPO=/opt/GSM/osmo-operator      # copie du depot (git clone https://github.com/bbaranoff/osmo-operator)
export ROOT=/opt/GSM
mkdir -p "$ROOT"
```

## Sommaire

1. [base](#etape-1--base) (a partir de `ubuntu:24.04`)
2. [osmo-core](#etape-2--osmo-core) (a partir de `base`)
3. [bb](#etape-3--bb) (a partir de `osmo-core`)
4. [qemu](#etape-4--qemu) (a partir de `base`)
5. [l1](#etape-5--l1) (a partir de `qemu`)
6. [grgsm-venv](#etape-6--grgsm-venv) (a partir de `osmo-core`)
7. [node](#etape-7--node) (a partir de `base`)
8. [lte](#etape-8--lte) (a partir de `base`)
9. [osmocom-nitb](#etape-9--osmocom-nitb) (a partir de `base`)
10. [debs](#etape-10--debs) (a partir de `scratch`)


## Etape 1 : base

Dockerfile — IMAGE DE BASE osmocom-nitb (COUCHE STABLE)

Tout ce qui est LONG et rarement modifie vit ici : la TOTALITE des paquets apt (une seule liste, plus aucun apt dans Dockerfile.run), la pile Osmocom compilee depuis les sources, osmocom-bb + le firmware Calypso, QEMU et son device IPC, gr-gsm/GNU Radio, le runtime Node et le dashboard web, la config PulseAudio, les units systemd, les repertoires, le prompt. ~11 Go et ~40 min de build : on ne la rebatit que quand une dependance change.

[2026-09-03] BASE ubuntu:24.04 (noble) - python 3.12, gcc 13 par defaut, bibliotheques renommees *t64 (libasound2t64, libgnutls30t64...). L ISO (build-iso.sh) part du MEME noble : le venv /root/.env et les .so de /usr/local sont copies tels quels dans le rootfs, ils doivent trouver la meme glibc et le meme python. Changer la base ici, c est la changer la-bas.

CACHE .deb - packaging/osmo-deb.sh. Chaque dossier compile ci-dessous sort en paquet .deb dans /var/cache/osmo-debs (COPY depuis .deb-cache/, que build.sh synchronise avec /var/cache/osmo-debs de l HOTE). Au rebuild, `osmo-deb install` pose le paquet et saute le clone + la compilation ; `osmo-deb pack` et `osmo-deb snapshot` fabriquent le paquet la premiere fois. build.sh --no-cache passe OSMO_DEB_REFRESH=1 : tout est recompile et le cache reecrit. LES SOURCES RESTENT DANS /opt/GSM : `osmo-deb pack` embarque l arbre courant (/opt/GSM/<nom>, .git et objets compris) dans le paquet, et les snapshots nomment l arbre. Un rebuild depuis le cache redonne donc la meme image, avec ses ateliers - pas une image ou seul /usr/local subsiste.

L'iteration quotidienne se fait dans Dockerfile.run, qui repart de cette image (`FROM osmocom-nitb`) et n'y rafraichit que les scripts, les configs, le pont et les arbres git qosmo / osmo-operator — en secondes, pas en 40 minutes.

Cette image reste AUTONOME : elle a son propre ENTRYPOINT et start-nitb.sh la lance seule. Ne pas retirer ses COPY de configs/scripts sous pretexte que Dockerfile.run les refait : le recouvrement est voulu des deux cotes.

[2026-09-25] LE BUILD EST UN GRAPHE, PLUS UNE CHAINE — stages BuildKit

Ce fichier etait une seule cible de ~75 etapes : une chaine, donc un seul chemin d execution, meme sur une machine a 32 coeurs. Or quatre des cinq compilations longues n ont AUCUNE dependance entre elles - la pile Osmocom, QEMU (qosmo), le venv GNU Radio, la 4G (srsRAN + Open5GS). Elles s additionnaient pour rien.

```text
                 base   (apt, apt-fast, osmo-deb, configs)
                   |
        +----------+--------+---------+
        |          |        |         |
    osmo-core    qemu      lte      node          <- EN PARALLELE
        |          |
   +----+-----+    |
   |    |     |    |
  bb  grgsm-  +----+
   |  venv    |
   |    |    l1     (bb: osmocom-bb — l1: c54x_exe + grgsm_exe)
   |    |     |
   +----+-----+
        |
    osmocom-nitb      (assemblage : dpkg -i, puis configs)
          |
        debs          (FROM scratch : le cache .deb pour la CI)
```

CE QUI REND LE DECOUPAGE POSSIBLE : packaging/osmo-deb.sh. Chaque bloc sort deja en .deb qui contient A LA FOIS les fichiers installes ET l arbre de sources de /opt/GSM (cmd_pack, « L ARBRE DE SOURCES PART AVEC »). Un stage parallele n a donc pas a exporter un systeme de fichiers : il exporte ses .deb, et l assemblage les repose avec un `dpkg -i`. C est EXACTEMENT ce que fait deja iso_modules/50-injection-image.sh pour le rootfs de l ISO — le precedent existe dans ce depot, on le reutilise.

TROIS STAGES NE SONT PAS PARALLELES A osmo-core, et c est voulu — tous les trois se lient a libosmocore d une facon ou d une autre :

```text
  - osmocom-bb : `make nofirmware` lie mobile/trxcon a libosmocore ;
  - c54x_exe   : son Makefile fait `pkg-config --libs libosmocoding libosmocore` ;
  - gr-gsm     : son CMakeLists cherche libosmocore/libosmocoding/libosmogsm.
```

Les en sortir donnerait un build qui casse, pas un build plus rapide. Ils tournent en revanche EN PARALLELE ENTRE EUX, une fois osmo-core fini.

CE QUI NE CHANGE PAS : les versions, les patchs, les ./configure, le contenu de /opt/GSM, et --target osmocom-nitb (build.sh, compose.yaml) reste OBLIGATOIRE puisque `debs` est toujours la derniere etape du fichier.

_Dans Docker : `FROM ubuntu:24.04`. Sur une machine, on continue dans le meme systeme._

ROOT : ou vivent les sources dans l'image. Chemin FIXE et assume — dans un conteneur, il n'y a rien a rendre portable.

```bash
export DEBIAN_FRONTEND=noninteractive
```

```bash
export ROOT=/opt/GSM
```

OSMO_IMAGE=1 : « image de ce depot, son reseau est pose par start-docker.sh / compose » - network/osmo-ip-plan.sh ne touche alors a aucune adresse. Un conteneur quelconque (ubuntu:24.04 nu) ne l a pas et s adresse comme un natif.

```bash
export container=docker
export OSMO_IMAGE=1
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
export LD_LIBRARY_PATH=/usr/local/lib
export GIT_TERMINAL_PROMPT=0
```

#### ── apt-fast : les téléchargements apt en parallèle

Cette image installe plusieurs centaines de paquets ; apt les récupère un par un, apt-fast les met en parallèle via aria2. Le gain porte sur le téléchargement, pas sur dpkg — l'installation reste séquentielle.

UN SEUL installeur pour tous les environnements : packaging/apt-fast-install.sh (cette image, Dockerfile.stp, le chroot de l ISO, l hote via build.sh). Il pose aussi /etc/apt/apt.conf.d/90osmo-operator, les reglages de telechargement communs. Repli integre : sans GitHub, apt-fast appelle apt-get et le build continue, plus lentement.

LE CACHE APT DU BUILD. [2026-09-04] Chaque etape apt de ce fichier monte /var/cache/apt/archives en cache BuildKit (id osmo-apt-archives, partage avec Dockerfile.stp) : les .deb telecharges une fois y restent, sur l hote, dans le cache de BuildKit - une reconstruction ne retelecharge que ce qui a change. apt-fast-install retire docker-clean et pose Keep-Downloaded-Packages, sinon apt effacerait les paquets a peine installes. Necessite BuildKit (docker compose, ou docker-buildx : build.sh les installe) - le builder historique ne connait pas --mount.

```bash
mkdir -p "$(dirname /usr/local/sbin/apt-fast-install)" && cp -r "$REPO"/packaging/apt-fast-install.sh /usr/local/sbin/apt-fast-install
```

Le miroir Ubuntu mesure par build.sh (packaging/apt-mirror.sh) : vide = les sources de l image de base (archive.ubuntu.com), qui peut etre inutilisable depuis l hote (3 Ko/s le 2026-09-04) sans qu apt le dise.

```bash
export OSMO_UBUNTU_MIRROR=""
```

```bash
chmod 755 /usr/local/sbin/apt-fast-install && apt-fast-install \
    && rm -rf /var/lib/apt/lists/*
```

```bash
export DEBIAN_FRONTEND=noninteractive
```

#### 1. Dépendances système — TOUTES ici, y compris celles qu'installait

```text
   Dockerfile.run. Une seule liste, un seul endroit où la faire évoluer :
   l'image d'exécution n'a plus à connaître apt du tout.
```

tshark tire wireshark-common, qui pose une question debconf (capture non-root) et bloquerait un build non interactif : on y répond d'avance.

⚠️ COUPLAGE EXTERIEUR — install_modules/10-deps.sh EXTRAIT cette liste du Dockerfile (« la liste fait autorite dans le Dockerfile ») avec

```text
  awk '/^RUN apt-get update && apt-get install/,/[^\\]$/'
```

Ce motif ne connait QUE `apt-get` : depuis le passage a apt-fast, il ne capture plus que le bloc d'amorcage (aria2 curl ca-certificates) et l'installation NATIVE (hors docker) repart avec une liste tronquee — inst_deps_verify echoue sur build-essential/libtalloc-dev/libsctp-dev. Le correctif est dans 10-deps.sh (accepter `apt-(get|fast)` dans l'awk ET dans le sed qui suit), pas ici : ne pas repasser cette liste en apt-get pour contourner le probleme.

```bash
echo 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections
```

deb-src AVANT l unique `apt-fast update` : le build-dep gnuradio (gr-gsm, fin du bloc ci-dessous) lit les index Sources. Il avait son propre RUN avec un deuxieme update + une deuxieme resolution apt : fusionne ici. Noble ecrit ses sources en deb822 (ubuntu.sources, ligne "Types: deb") ; l ancien /etc/apt/sources.list (jammy) reste gere au cas ou la base change (gnuradio est dans universe : tous les composants).

```bash
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -nE 's|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p' \
            /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list; \
    fi
```

```bash
apt-fast update && apt-fast install -y --no-install-recommends \
    # Outils de build
    build-essential git gcc g++ make cmake autoconf automake libtool pkg-config wget curl \
    # Dépendances Osmocom Core & Network
    libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev liburing-dev asterisk-moh* \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev sqlite3 libc-ares-dev libgnutls28-dev \
    # Audio, Radio & SIP
    libortp-dev libfftw3-dev libusb-1.0-0-dev libsofia-sip-ua-dev libsofia-sip-ua-glib-dev \
    # Python & Outils système
    python3 python3-dev python3-scapy ca-certificates tmux systemd systemd-sysv \
    # Debug — gdb-multiarch pour attacher au gdb-stub QEMU (ARM Calypso)
    gdb-multiarch \
    # ALSA — requis par osmo-gapk pour l'I/O audio matériel
    # (libasound2t64 : nom noble de libasound2, transition time_t 64 bits)
    libasound2-dev libasound2t64 alsa-utils \
    # libgsm — codec GSM-FR natif (accélère gapk en mode gsmfr)
    libgsm1-dev libgsm1 \
    iptables iproute2 asterisk ffmpeg \
    # Sync build-iso : psmisc (pkill/killall, cleanup) + pulseaudio (chaîne audio gapk/parec)
    psmisc pulseaudio pulseaudio-utils binutils-arm-none-eabi \
    # Toolchains alternatives : osmocom-bb jolly/testing et fixeria/burst_ind ne
    # compilent qu'avec gcc-9 ; gcc-11 reste le compilateur par defaut du reste
    # (gcc-13 est celui de noble : il compile la pile Osmocom en tete de fichier,
    # les alternatives ci-dessous ne sont posees qu apres).
    # (Ex-bloc apt dedie, supprime : les `update-alternatives` plus bas echouaient
    #  « alternative path /usr/bin/gcc-9 doesn't exist » sans ces paquets.)
    gcc-9 g++-9 gcc-11 g++-11 \
    # log4cpp : etait installe a part avec le build-dep gnuradio (gr-gsm).
    liblog4cpp5-dev \
    # QEMU Calypso (bbaranoff/qosmO) : venv + numpy/scipy pour l'outillage
    # DSP, glib/pixman/slirp pour la cible arm-softmmu, ninja pour meson, socat
    # pour les PTY de scripts/run.sh. (Ex-bloc apt-get juste avant le build QEMU.)
    python3-venv python3-pip python3-numpy python3-scipy \
    libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
    # Ex-Dockerfile.run — outillage d'exploitation du conteneur :
    #   telnet   -> repli VTY (run_modules/21-abonnes-hlr.sh) + transport dashboard
    #   whiptail -> menus de tools/vty-menu.sh et de start-docker.sh
    #   xz-utils -> `tar -xJf` du tarball Node 22 (bloc dashboard, en fin de fichier)
    #   libasound2-plugins -> greffon ALSA->PulseAudio, EXIGE par configs/asound.conf
    #        (`type pulse` sur gsm_out, gsm_in ET pcm.!default) : sans lui, toute
    #        ouverture ALSA (gapk, mobile) echoue et l'audio est mort des 2 cotes
    #   tshark/tcpdump/libcap2-bin -> capture ; libcap2-bin fournit le setcap ci-dessous
    telnet nano whiptail xz-utils libasound2-plugins \
    tcpdump tshark libcap2-bin \
    # Deps GNU Radio 3.10 (gr-gsm, venv /root/.env plus bas) : meme resolution
    # apt que le reste, pas de second RUN apt. (Le && ferme la liste pour
    # l extracteur de install_modules/10-deps.sh.)
    && apt-fast build-dep -y gnuradio \
    && rm -rf /var/lib/apt/lists/*
```

Capture non-root pour le dashboard et tcpdump. Position OBLIGATOIRE : dumpcap n'existe qu'une fois wireshark-common installe (tire par tshark, juste au-dessus).

```bash
setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"
```

#### ── Le cache .deb : l outil, puis les paquets deja construits

.deb-cache/ est le miroir, dans le contexte de build, de /var/cache/osmo-debs de l hote (build.sh l y recopie avant, et ramene les nouveaux paquets apres). Vide au premier build : tout se compile et se met en cache. Plein ensuite : chaque etape ci-dessous pose son paquet et ne compile rien. OSMO_DEB_REFRESH=1 (build.sh --no-cache) : le cache est ignore et reecrit.

```bash
export OSMO_DEB_REFRESH=0
```

```bash
mkdir -p "$(dirname /usr/local/sbin/osmo-deb)" && cp -r "$REPO"/packaging/osmo-deb.sh /usr/local/sbin/osmo-deb
```

```bash
mkdir -p /var/cache/osmo-debs/ && cp -r "$REPO"/.deb-cache/ /var/cache/osmo-debs/
```

```bash
chmod 755 /usr/local/sbin/osmo-deb && osmo-deb list || true
```

#### ── git : plus de forçage HTTP/1.1

[2026-09-03] RETIRE. Le contournement http.version=HTTP/1.1 (contre "expected flush after ref listing", un flux HTTP/2 coupe par un intermediaire) etait pose ici en global et repete a chaque clone. Il n a plus lieu d etre : git parle HTTP/2 normalement, et forcer HTTP/1.1 ralentissait tous les clones pour un incident de reseau local. GIT_TERMINAL_PROMPT=0 (ENV, plus haut) reste : sans terminal, un clone qui veut un login doit ECHOUER net, pas attendre. postBuffer large pour les gros clones.

```bash
git config --global http.postBuffer 524288000
```

_Metadonnee Docker, sans equivalent sur une machine : `SHELL ["/bin/bash", "-c"]`._

```bash
mkdir -p /etc/asterisk/ && cp -r "$REPO"/configs/*conf /etc/asterisk/
```

asound.conf DOIT AUSSI ETRE A LA RACINE. Le COPY ci-dessus le depose dans /etc/asterisk/ - ALSA ne regarde jamais la : il lit /etc/asound.conf (ou ~/.asoundrc). Sans ce second exemplaire, `aplay -D gsm_out` repond

```text
    ALSA lib pcm.c: (snd_pcm_open_noupdate) Unknown PCM gsm_out
```

et le mobile du conteneur est MUET, sans qu aucun log ne parle d audio. start-docker.sh l.469 monte bien celui de l hote (-v ...:/etc/asound.conf), mais un conteneur lance autrement - docker run a la main, diagnostic - n a rien.

```bash
mkdir -p "$(dirname /etc/asound.conf)" && cp -r "$REPO"/configs/asound.conf /etc/asound.conf
```

```bash
cd ${ROOT}
```

#### 2. Création de l'utilisateur osmocom

```bash
groupadd osmocom && useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom && \
    mkdir -p /var/lib/osmocom && chown osmocom:osmocom /var/lib/osmocom
```


## Etape 2 : osmo-core

STAGE osmo-core — la pile Osmocom : 17 depots, 4 patchs, gapk, SMSC, libosmo-dsp

_Dans Docker : `FROM base`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

#### 3. Compilation de la pile Osmocom (Ordre respecté)

```bash
for repo in \
    libosmocore:1.12.1 \
    libosmo-netif:1.7.0 \
    libosmo-abis:2.1.0 \
    libosmo-sigtran:2.2.1 \
    libsmpp34:1.14.5 \
    libgtpnl:1.3.3 \
    osmo-hlr:1.9.2 \
    osmo-mgw:1.15.0 \
    osmo-ggsn:1.14.0 \
    osmo-sgsn:1.13.1 \
    osmo-msc:1.15.0 \
    osmo-bsc:1.14.0 \
    osmo-trx:1.7.2 \
    osmo-bts:1.10.0 \
    osmo-pcu:1.5.2 \
    osmo-sip-connector:1.7.2 \
    libosmo-gprs:0.2.1; \
    do \
    name=$(echo $repo | cut -d: -f1) && \
    version=$(echo $repo | cut -d: -f2) && \
    \
    if [[ "$name" =~ ^libosmo ]]; then \
        GIT_URL="https://gitea.osmocom.org/osmocom/$name"; \
    else \
        GIT_URL="https://gitea.osmocom.org/cellular-infrastructure/$name"; \
    fi && \
    \
    # Le paquet du cache d abord : s il est la, ni clone ni compilation.
    if osmo-deb install "$name" "$version"; then continue; fi && \
    \
    cd ${ROOT} && \
    git clone "$GIT_URL" && cd "$name" && \
    git checkout "$version" && \
    \
    autoreconf -fi && \
    EXTRA_FLAGS="" && \
    if [ "$name" = "libosmo-abis" ]; then EXTRA_FLAGS="--disable-dahdi"; fi && \
    if [ "$name" = "osmo-msc" ]; then EXTRA_FLAGS="--enable-smpp"; fi && \
    if [ "$name" = "osmo-mgw" ]; then EXTRA_FLAGS="--enable-alsa"; fi && \
    if [ "$name" = "osmo-trx" ]; then EXTRA_FLAGS="--with-ipc"; fi && \
    if [ "$name" = "osmo-bts" ]; then EXTRA_FLAGS="--enable-virtual --enable-trx"; fi && \
    if [ "$name" = "osmo-ggsn" ]; then EXTRA_FLAGS="--enable-gtp-linux"; fi && \
    \
    ./configure $EXTRA_FLAGS && \
    make -j$(nproc) && \
    # make install sous DESTDIR -> .deb dans le cache -> dpkg -i dans la racine
    osmo-deb pack "$name" "$version" make install && \
    ldconfig \
    || { echo "ECHEC build osmocom: $name"; exit 1; }; \
    done
```

#### ── Patch osmo-trx IPC : alignement ts_initial sur la trame TDMA (fix RACH/LU) ──

Le device IPC (calypso-ipc-device) commit des buffers RX a des timestamps multiples de 2500 (CALYPSO_SHM_BUFSIZE) ; sans arrondi, ts_initial%5000 valait 0 ou 2500 -> device-TN0 mappe sur osmo-TN4 -> la RACH (UL) ratait le slot TS0/RACH -> NOPE/-110 -> Location Update bloquee. Le patch arrondit ts_initial a la frontiere de trame (8*625=5000 @ 4 SPS). Patch maintenu dans patches/.

#### ── Patch osmo-trx RACH UL : table de modulation per-RA (fix LU, no-hardcode) ──

La vraie RA du mobile (d_rach@0x0474, plombee via /dev/shm/calypso_rach par QEMU) varie a chaque burst ; le device rejouait un RA=3 fixe -> request-reference de l'IMM ASSIGN jamais matchee -> LU en boucle. sigProcLib pre-genere la modulation Laurent EXACTE d'osmo-trx pour chaque RA 0x00..0x0f (-> /root/rach_ref_RA<nn>.cs16), le device selectionne le ref de la VRAIE RA. Ajoute aussi les logs RACH-DET (Transceiver.cpp) + le lien libosmocoding dans COMMON_LDADD (Makefile.am, requis pour gsm0503_rach_ext_encode). Touche Makefile.am -> autoreconf+configure requis.

```bash
mkdir -p "$(dirname /tmp/osmo-trx-ipc-ts-frame-align.patch)" && cp -r "$REPO"/patches/osmo-trx-ipc-ts-frame-align.patch /tmp/osmo-trx-ipc-ts-frame-align.patch
```

```bash
mkdir -p "$(dirname /tmp/osmo-trx-rach-per-ra-table.patch)" && cp -r "$REPO"/patches/osmo-trx-rach-per-ra-table.patch /tmp/osmo-trx-rach-per-ra-table.patch
```

Meme nom de paquet que dans la boucle (osmo-trx), version 1.7.2+ipc : dpkg fait une mise a jour, les fichiers sont les memes. Si la boucle est sortie du cache, l arbre source n existe pas : on le reclone avant d appliquer les patchs.

```bash
if ! osmo-deb install osmo-trx 1.7.2+ipc; then \
      { [ -d ${ROOT}/osmo-trx ] || { cd ${ROOT} \
          && git clone https://gitea.osmocom.org/cellular-infrastructure/osmo-trx \
          && git -C osmo-trx checkout 1.7.2; }; } \
      && git -C ${ROOT}/osmo-trx apply /tmp/osmo-trx-ipc-ts-frame-align.patch \
      && git -C ${ROOT}/osmo-trx apply /tmp/osmo-trx-rach-per-ra-table.patch \
      && cd ${ROOT}/osmo-trx \
      && autoreconf -fi \
      && ./configure --with-ipc \
      && make -j$(nproc) \
      && osmo-deb pack osmo-trx 1.7.2+ipc make install \
      && ldconfig; \
    fi
```

#### ── Patch osmo-bts RAND : forcer le defi d'authentification

osmo-bts relaie normalement l'AUTHENTICATION REQUEST du reseau telle quelle. Ce patch, dans rsl_rx_rll() (src/common/rsl.c), reecrit le RAND de cette trame quand la variable d'environnement RAND est posee sur le processus BTS :

```text
    RAND non defini -> rien de touche (comportement normal) ;
    RAND=0          -> RAND nul sur 16 octets (defi fixe COMP128v1,
                       defi fixe connu, Ki = prefixe connu
                       + 2 octets a retrouver) ;
    RAND=<hexa>     -> jusqu'a 16 octets lus en hexa, completes de zeros.
```

« seulement quand precise, mais force quand precise ». Ne touche que rsl.c, donc pas de Makefile.am : autoreconf/configure quand meme, l'arbre reclone arrive sans ./configure. Meme nom de paquet (osmo-bts), version 1.10.0+rand : dpkg fait une mise a jour. Patch maintenu dans patches/.

```bash
mkdir -p "$(dirname /tmp/osmo-bts-force-rand-toy.patch)" && cp -r "$REPO"/patches/osmo-bts-force-rand-toy.patch /tmp/osmo-bts-force-rand-toy.patch
```

```bash
if ! osmo-deb install osmo-bts 1.10.0+rand; then \
      { [ -d ${ROOT}/osmo-bts ] || { cd ${ROOT} \
          && git clone https://gitea.osmocom.org/cellular-infrastructure/osmo-bts \
          && git -C osmo-bts checkout 1.10.0; }; } \
      && git -C ${ROOT}/osmo-bts apply /tmp/osmo-bts-force-rand-toy.patch \
      && cd ${ROOT}/osmo-bts \
      && autoreconf -fi \
      && ./configure --enable-virtual --enable-trx \
      && make -j$(nproc) \
      && osmo-deb pack osmo-bts 1.10.0+rand make install \
      && ldconfig; \
    fi
```

#### ── Patch osmo-hlr RAND : forcer le RAND du vecteur d'auth

auc.c/auc_compute_vectors() : gate minimal. Si la variable d'environnement RAND est posee sur le process HLR, le RAND tire pour CHAQUE vecteur est force a 0 (16 octets) AVANT osmo_auth_gen_vec2 : SRES et Kc sont alors calcules sur RAND=0 (le HLR a le Ki). C'est l'etage indispensable pour une LU ACCEPTEE : osmo-msc envoie ce RAND et compare au SRES du meme vecteur -> match. Le seul gate osmo-msc (cote tx) donnerait un mismatch -> LU reject. RAND absent -> reseau normal. Ne touche pas Makefile.am ; autoreconf/configure quand meme (arbre reclone sans ./configure). Meme nom de paquet (osmo-hlr), version 1.9.2+rand : dpkg met a jour. Patch maintenu dans patches/.

```bash
mkdir -p "$(dirname /tmp/osmo-hlr-force-rand-toy.patch)" && cp -r "$REPO"/patches/osmo-hlr-force-rand-toy.patch /tmp/osmo-hlr-force-rand-toy.patch
```

```bash
if ! osmo-deb install osmo-hlr 1.9.2+rand; then \
      { [ -d ${ROOT}/osmo-hlr ] || { cd ${ROOT} \
          && git clone https://gitea.osmocom.org/cellular-infrastructure/osmo-hlr \
          && git -C osmo-hlr checkout 1.9.2; }; } \
      && git -C ${ROOT}/osmo-hlr apply /tmp/osmo-hlr-force-rand-toy.patch \
      && cd ${ROOT}/osmo-hlr \
      && autoreconf -fi \
      && ./configure \
      && make -j$(nproc) \
      && osmo-deb pack osmo-hlr 1.9.2+rand make install \
      && ldconfig; \
    fi
```

#### ── Patch osmo-msc RAND : forcer le defi d'authentification

gsm48_tx_mm_auth_req() (src/libmsc/gsm_04_08.c) : gate minimal. Si la variable d'environnement RAND est posee sur le processus MSC, le RAND de l'AUTH REQUEST descendante est force (0 sur 16 octets dans notre cas ; changer l'initialiseur forced_rand[] pour un autre RAND). RAND absent -> comportement normal du reseau. Ne touche pas Makefile.am ; autoreconf/configure quand meme (arbre reclone sans ./configure). Meme nom de paquet (osmo-msc), version 1.15.0+rand : dpkg met a jour. Patch maintenu dans patches/. Meme gate cote BSC (openbsc gsm_04_08.c).

```bash
mkdir -p "$(dirname /tmp/osmo-msc-force-rand-toy.patch)" && cp -r "$REPO"/patches/osmo-msc-force-rand-toy.patch /tmp/osmo-msc-force-rand-toy.patch
```

```bash
if ! osmo-deb install osmo-msc 1.15.0+rand; then \
      { [ -d ${ROOT}/osmo-msc ] || { cd ${ROOT} \
          && git clone https://gitea.osmocom.org/cellular-infrastructure/osmo-msc \
          && git -C osmo-msc checkout 1.15.0; }; } \
      && git -C ${ROOT}/osmo-msc apply /tmp/osmo-msc-force-rand-toy.patch \
      && cd ${ROOT}/osmo-msc \
      && autoreconf -fi \
      && ./configure --enable-smpp \
      && make -j$(nproc) \
      && osmo-deb pack osmo-msc 1.15.0+rand make install \
      && ldconfig; \
    fi
```

#### ── Patch gapk : sonde sur la sortie ALSA (GAPK_ALSA_PROBE)

Diagnostic pur, inerte tant que GAPK_ALSA_PROBE != 1. Tranche une question que rien d'autre ne permet de trancher : quand l'ecouteur du MS est muet, le PCM remis a snd_pcm_writei est-il deja nul (defaut en amont, dans la chaine gapk) ou non nul (defaut en aval, ALSA/PulseAudio) ? osmo_gapk_pq_execute ne journalise rien ici, car il ne se plaint que d'un retour negatif et pq_cb_alsa_output rend « succes » meme pour une ecriture vide. Patch maintenu dans patches/ (regenere si pq_alsa.c change).

[2026-08-12] LE PATCH RESTE DANS LE DEPOT, LE BUILD NE L'APPLIQUE PLUS. Demande explicite : garder patches/gapk-pq-alsa-output-probe.patch versionne (il tranche encore la question amont/aval quand l'ecouteur est muet) mais ne plus le poser sur le gapk construit — un `git apply` dans le build casse l'image des que pq_alsa.c bouge en amont, et la sonde n'est plus la question du jour (descendant muet resolu par CALYPSO_PULSE_LATENCY_MSEC, 240 depuis le 2026-09-09 : cf. start-native.sh, le tampon du greffon ALSA-PulseAudio). POUR LE REMETTRE, deux gestes, dans cet ordre :

```text
  1. decommenter la ligne COPY ci-dessous ;
  2. reinserer dans le RUN, entre le `git clone` et le `cd osmo-gapk` :
       git -C ${ROOT}/osmo-gapk apply /tmp/gapk-pq-alsa-output-probe.patch && \
     (elle ne peut pas rester en commentaire : une ligne `#` au milieu d'une
      continuation `\` couperait la chaine shell du RUN).
```

Verifier d'abord que le patch s'applique toujours :

```text
  git -C <clone gapk> apply --check patches/gapk-pq-alsa-output-probe.patch
```

POUR L'APPLIQUER A CHAUD SANS REBUILD : le poser dans le conteneur sur un clone de gapk, puis reconstruire gapk seul. COPY patches/gapk-pq-alsa-output-probe.patch /tmp/gapk-pq-alsa-output-probe.patch

```bash
if ! osmo-deb install osmo-gapk 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk && \
      cd osmo-gapk && \
      autoreconf -fi && \
      ./configure --enable-alsa && \
      make -j$(nproc) && \
      osmo-deb pack osmo-gapk 0.git make install && \
      ldconfig; \
    fi
```

#### ── gsup-smsc-proto : SMSC externe connecté à OsmoHLR via GSUP

Programmes : proto-smsc-daemon (réception MO SMS + relai MT via GSUP)

```text
             proto-smsc-sendmt (injection MT SMS via socket UNIX local)
```

Dépendances build : libosmocore, libosmogsm, libosmo-gsup-client [2026-09-03] Son Makefile de tete lance `make DESTDIR= install` dans daemon/ et sendmt/ - DESTDIR force a vide, le staging d osmo-deb restait vide ("rien n a ete installe dans DESTDIR") alors que la compilation (gcc courant) etait bonne. On installe donc les deux sous-repertoires nous-memes, avec le DESTDIR qu osmo-deb pose : leurs Makefiles, eux, l honorent.

```bash
if ! osmo-deb install gsup-smsc-proto 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/themwi/gsup-smsc-proto && \
      cd gsup-smsc-proto && \
      ./configure --with-osmo=/usr/local && \
      make -j$(nproc) && \
      osmo-deb pack gsup-smsc-proto 0.git \
        sh -c 'for i in daemon sendmt; do make -C "$i" DESTDIR="$DESTDIR" install || exit 1; done' && \
      ldconfig; \
    fi
```

#### ── sms-coding-utils : encodage/décodage SMS PDU (GSM 03.40)

sms-encode-text, gen-sms-deliver-pdu, sms-pdu-decode, etc. Son Makefile de tete pose `DESTDIR=` (vide) et le repasse aux sous-repertoires : une variable donnee SUR LA LIGNE DE COMMANDE de make l emporte et descend avec, d ou `make install DESTDIR=...` explicite (l ancien INSTDIR=... n existait dans aucun de ses Makefiles). bindir vaut /usr/local/bin par configure.

```bash
if ! osmo-deb install sms-coding-utils 0.r1; then \
      cd ${ROOT} && \
      wget -q https://www.freecalypso.org/pub/GSM/FreeCalypso/sms-coding-utils-latest.tar.bz2 && \
      tar xf sms-coding-utils-latest.tar.bz2 && \
      cd sms-coding-utils-r1 && \
      ./configure && \
      make -j$(nproc) && \
      osmo-deb pack sms-coding-utils 0.r1 \
        sh -c 'mkdir -p "$DESTDIR/usr/local/bin" && make install DESTDIR="$DESTDIR"'; \
    fi
```

#### ── libosmo-dsp (dépendance transceiver/burst_ind)

```bash
if ! osmo-deb install libosmo-dsp 0.git; then \
      cd /opt/GSM \
      && git clone https://gitea.osmocom.org/sdr/libosmo-dsp.git \
      && cd libosmo-dsp \
      && autoreconf -fi \
      && ./configure \
      && make -j$(nproc) \
      && osmo-deb pack libosmo-dsp 0.git make install \
      && ldconfig; \
    fi
```


## Etape 3 : bb

STAGE bb — osmocom-bb, le firmware Calypso et les deux branches gcc-9

_Dans Docker : `FROM osmo-core`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

#### ── Calypso build

#### ── Patch osmocon : filtre Kc — RETIRE le 2026-08-30

Ce patch faisait ecrire /dev/shm/calypso_kc a osmocon, en espionnant L1CTL_CRYPTO_REQ au passage sur le lien serie. Il etait la SEULE source du Kc a l'epoque ; il ne l'est plus, et il faisait desormais plus de mal que de bien.

POURQUOI ON LE RETIRE. Un espion voit passer la cle, mais pas sa fin de vie : il doit la DEVINER. Le patch la devinait sur DM_EST_REQ et DM_REL_REQ, et remettait le fichier a 32 zeros. L'intention est juste pour le RELEASE, fausse pour l'ESTABLISH -- le mobile emet aussi un DM_EST_REQ pour ouvrir un lien SUPPLEMENTAIRE sur un canal DEJA chiffre (le SAPI 3 du SMS). La cle disparaissait donc en pleine session chiffree.

Pire, il y avait TROIS ecrivains sur ce fichier (osmocon, l1ctl_sock.c, le shunt DSP) sans le moindre arbitrage : le dernier qui ecrit gagne, et c'est l'effaceur. Mesure du 30/08 : fichier a 32 zeros, « A5=non » sur tout le canal dedie, premier appel mort.

CE QUI LE REMPLACE. calypso_dsp_shunt.c publie /dev/shm/calypso_kc_l1 depuis d_a5mode et a_kc du NDB -- ce que le FIRMWARE a reellement charge dans le DSP (calypso/dsp.c:dsp_load_ciph_param). Ce n'est plus un espion qui devine, c'est l'etat de la couche 1, remis a zero par le firmware lui-meme quand il repart en clair. Et le fichier lui est PROPRE : plus de course a l'ecriture.

Le patch reste dans patches/ a titre documentaire, il n'est plus applique. L arbre ENTIER part dans le paquet (snapshot) : trx_toolkit, osmocon et les binaires host sont lus dans l arbre au runtime, pas seulement dans /usr/local. [2026-09-08] trx_toolkit/clck_gen.py : l horloge TDMA de fake_trx ne se remet a zero que pour un retard superieur a une trame (4,615 ms). Avant, un retard de 0,3 a 2 ms decalait la base de temps a chaque fois ; osmo-bts-trx compensait en boucle et la parole perdait des trames. Patch maintenu dans patches/, applique aussi par install_modules/40-patches.sh en natif. mobile : une SIM reinseree sans RPLMN (reconnexion SAP) restait en A6 et la recherche de PLMN finissait « unhandled » (patches/osmocom-bb-plmn-a6-reinsert.patch). PLMNsel / FPLMN lus avec osmo_plmn_to_bcd (ecriture) au lieu de from_bcd : 000-00 (patches/osmocom-bb-sim-plmn-from-bcd.patch). Les deux, aussi, par 40-patches.sh.

```bash
mkdir -p "$(dirname /tmp/osmocom-bb-clck-gen-frame-tolerance.patch)" && cp -r "$REPO"/patches/osmocom-bb-clck-gen-frame-tolerance.patch /tmp/osmocom-bb-clck-gen-frame-tolerance.patch
```

```bash
mkdir -p "$(dirname /tmp/osmocom-bb-plmn-a6-reinsert.patch)" && cp -r "$REPO"/patches/osmocom-bb-plmn-a6-reinsert.patch /tmp/osmocom-bb-plmn-a6-reinsert.patch
```

```bash
mkdir -p "$(dirname /tmp/osmocom-bb-sim-plmn-from-bcd.patch)" && cp -r "$REPO"/patches/osmocom-bb-sim-plmn-from-bcd.patch /tmp/osmocom-bb-sim-plmn-from-bcd.patch
```

```bash
if ! osmo-deb install osmocom-bb 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-clck-gen-frame-tolerance.patch && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-plmn-a6-reinsert.patch && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-sim-plmn-from-bcd.patch && \
      cd osmocom-bb/src && \
      # Build complet : firmware (layer1.bin/.elf pour Calypso) + outils host
      # (mobile, trxcon, virtphy, ccch_scan). Le firmware est nécessaire pour
      # le mode PHY_MODE=qemu où QEMU émule un Calypso et exécute layer1.
      make nofirmware && \
      osmo-deb snapshot osmocom-bb 0.git ${ROOT}/osmocom-bb; \
    fi
```

#### ── Note historique — patch fake_trx TRXD v0 (RETIRE)

Conserve verbatim : il documente une panne vecue. Il flottait dans Dockerfile.run juste au-dessus du bloc firmware, avec lequel il n'a AUCUN rapport — voisinage accidentel, pas lien de cause a effet.

#### ── Patch fake_trx : forcer TRXD v0

osmo-bts-trx 1.10+ négocie TRXD v1 via SETFORMAT, mais trxcon (OsmocomBB) ne supporte que v0. Le header v1 a 2 octets de plus → décalage des soft-bits → BER constant 55/456 sur chaque frame → FBSB_SEARCH échoue en boucle. Fix : forcer ver_req=0 dans la réponse SETFORMAT → le BTS reste en v0. (patch TRXD v0 retire : burst_fwd.py:66 re-encode deja par interface,

```text
 trxcon recoit du v0 quoi qu'il arrive -> le forcage etait inutile)
```

#### ── Firmware Calypso prebuild (layer1.highram.*) — ex-Dockerfile.run

`make nofirmware` ci-dessus ne construit justement PAS le firmware : on prend les binaires prebuild de bbaranoff/firmware et on les depose la ou le mode PHY_MODE=qemu les cherche. ORDRE IMPOSE : ce bloc exige A LA FOIS ce clone ET l'arbre /opt/GSM/osmocom-bb ci-dessus — le placer plus haut ferait echouer les cp et PHY_MODE=qemu partirait sans layer1. (Le `rm -rf /opt/GSM/firmware` qui precedait le clone dans Dockerfile.run est

```text
 supprime : ici le chemin n'existe pas encore, l'instruction etait morte.)
```

GIT_TERMINAL_PROMPT=0 : sans terminal (docker build), un clone qui demande un login doit echouer NET (message clair) au lieu d attendre un identifiant que personne ne tapera. --depth 1 : on ne veut que les binaires prebuild, pas l historique. (Le -c http.version=HTTP/1.1 qui etait ici est retire.)

```bash
if ! osmo-deb install calypso-firmware 0.git; then \
      GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
        https://github.com/bbaranoff/firmware /opt/GSM/firmware \
      && osmo-deb snapshot calypso-firmware 0.git /opt/GSM/firmware; \
    fi
```

[2026-08-28] Les trois `cp` vers /opt/GSM/osmocom-bb/src/target/firmware qui suivaient sont SUPPRIMES. Ils entretenaient un deuxieme exemplaire du firmware que plus personne ne lit : depuis la normalisation, environnement/paths.env du depot qemu ne connait qu'un chemin, $GSM_ROOT/firmware, et c'est celui que QEMU (-kernel .elf) comme osmocon (romload .bin) recoivent. Verifie sur le banc 192.168.1.7 : les deux exemplaires etaient bit a bit identiques (md5 3363105f...), et seul /opt/GSM/firmware etait charge. Si vous recompilez le firmware dans osmocom-bb, deposez le resultat dans /opt/GSM/firmware : c'est desormais le seul endroit consulte.

#### ── GCC 9 pour osmocom-bb branches expérimentales (jolly/testing, burst_ind) ─

gcc-9 et gcc-11 sont installés avec le reste, plus haut : ici on ne fait que déclarer les alternatives, dont l'ordre compte pour osmocom-bb.

```bash
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11
```

```bash
update-alternatives --set gcc /usr/bin/gcc-9
```

osmocom-bb jolly/testing → transceiver (BTS soft-SDR pour Calypso) Le binaire ET l arbre partent dans le paquet : les sources restent dans /opt/GSM au rebuild depuis le cache (voir l en-tete, CACHE .deb). [2026-10-19] patches/osmocom-bb-transceiver-qemu-bench.patch : l appli hote `transceiver` sert le Calypso EMULE (start-native.sh --osmo-trx, c54x_exe/run.sh OSMO_TRX=1) : --no-sync (pas de cellule a ecouter, mode BTS des le reset), --ts-mask (un seul timeslot), --l1ctl/--base-port, et SETTSC/SETFORMAT/ NOMTXPOWER acquiesces (osmo-bts-trx >= 1.3 les tient pour critiques). Applique aussi par install_modules/40-patches.sh en natif.

```bash
mkdir -p "$(dirname /tmp/osmocom-bb-transceiver-qemu-bench.patch)" && cp -r "$REPO"/patches/osmocom-bb-transceiver-qemu-bench.patch /tmp/osmocom-bb-transceiver-qemu-bench.patch
```

```bash
if ! osmo-deb install osmocom-bb-transceiver 0.git; then \
      git clone --branch jolly/testing --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-transceiver \
      && git -C /opt/GSM/osmocom-bb-transceiver apply /tmp/osmocom-bb-transceiver-qemu-bench.patch \
      && cd /opt/GSM/osmocom-bb-transceiver/src \
      && make HOST_layer23_CONFARGS=--enable-transceiver nofirmware -j$(nproc) \
      && cp /opt/GSM/osmocom-bb-transceiver/src/host/layer23/src/transceiver/transceiver \
         /usr/local/bin/transceiver \
      && osmo-deb snapshot osmocom-bb-transceiver 0.git /usr/local/bin/transceiver \
             /opt/GSM/osmocom-bb-transceiver; \
    fi
```

osmocom-bb fixeria/burst_ind → ccch_scan / bcch_scan / cell_log

```bash
if ! osmo-deb install osmocom-bb-burst-ind 0.git; then \
      git clone --branch fixeria/burst_ind --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-burst_ind \
      && cd /opt/GSM/osmocom-bb-burst_ind/src \
      && make nofirmware -j$(nproc) \
      && cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/ccch_scan \
         /usr/local/bin/ccch_scan \
      && { cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/bcch_scan \
         /usr/local/bin/bcch_scan 2>/dev/null || true; } \
      && { cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/cell_log \
         /usr/local/bin/cell_log 2>/dev/null || true; } \
      && osmo-deb snapshot osmocom-bb-burst-ind 0.git /opt/GSM/osmocom-bb-burst_ind \
           $(ls /usr/local/bin/ccch_scan /usr/local/bin/bcch_scan /usr/local/bin/cell_log 2>/dev/null); \
    fi
```

Retour au compilateur par defaut : ce stage ne sert qu a produire des .deb, mais le laisser sur gcc-9 piegerait quiconque en derive une etape.

```bash
update-alternatives --set gcc /usr/bin/gcc-11
```


## Etape 4 : qemu

STAGE qemu — le seul arbre QEMU : /opt/GSM/qosmo (--enable-l1-grgsm)

_Dans Docker : `FROM base`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

QEMU Calypso — RAN virtuel (baseband émulé)

Architecture :

```text
  - QEMU émule un SoC Calypso (ARM7TDMI + DSP TMS320C54x)
  - L'ARM exécute le vrai firmware osmocom-bb layer1.highram.elf
  - Le DSP charge le ROM réel (calypso_dsp.txt) au boot
  - bridge.py relaie les bursts entre osmo-bts-trx (UDP 5700-5702)
    et la BSP du DSP (UDP 6702), avec QEMU comme maître d'horloge TDMA
  - Le mobile (layer23) se connecte directement au socket L1CTL
    publié par le firmware via la PTY série de QEMU
```

Voir scripts/run.sh PHY_MODE=qemu pour l'orchestration runtime.

(Le `apt-get install python3-venv python3-pip python3-numpy python3-scipy

```text
 libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build` qui etait ici
 a ete fusionne dans la liste apt-fast en tete de fichier : une seule liste,
 un seul endroit ou la faire evoluer. Aucun paquet perdu.)
```

[2026-09-25] qosmo + c54x_exe + grgsm_exe — remplacent qosmo-grgsm et qosmo-dsp

Les deux forks QEMU sont retires (cf. start-native.sh, environment/paths.env) :

```text
  /opt/GSM/qosmo      UN seul arbre QEMU (bbaranoff/qosmO), --enable-l1-grgsm.
                      Il porte run.sh, run_modules, cfgs. Le meme binaire sert
                      au mode --dsp : CALYPSO_DSP_EXTERN=1 y coupe la L1 gr-gsm.
                      `ninja install` pose aussi le lanceur C `qosmo`.
  /opt/GSM/c54x_exe   le C54x HORS de QEMU (mask-ROM TI, sa ROM dans rom/).
                      Il compile les sources de /opt/GSM/qosmo : APRES qosmo.
  /opt/GSM/grgsm_exe  la couche 1 gr-gsm hors QEMU, memes sources qosmo.
```

Snapshot de l arbre qosmo ENTIER, build/ compris : QEMU_BIN pointe sur $OQC_ROOT/build/qemu-system-arm, et QEMU lit build/qemu-bundle pour se relocaliser (voir Dockerfile.lite). L ancien RUN « /opt/GSM/qemu/{build,*.py} » et calypso-ipc-device disparaissent avec qosmo-grgsm : plus rien ne les lit.

```bash
if ! osmo-deb install qosmo 0.git; then \
      git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo \
      && cd /opt/GSM/qosmo \
      && python3 -m venv /root/.venv-qemu \
      && . /root/.venv-qemu/bin/activate \
      && pip install --no-cache-dir tomli \
      && mkdir -p build && cd build \
      && ../configure --target-list=arm-softmmu --enable-l1-grgsm \
             --prefix=/opt/GSM/qemu-install --disable-werror --disable-docs \
      && make -j$(nproc) \
      && make install \
      && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm \
      && cp /opt/GSM/qemu-install/bin/qosmo /usr/local/bin/qosmo \
      && osmo-deb snapshot qosmo 0.git /opt/GSM/qosmo /opt/GSM/qemu-install \
             /root/.venv-qemu /usr/local/bin/qemu-system-arm /usr/local/bin/qosmo; \
    fi
```


## Etape 5 : l1

STAGE l1 — les deux couches 1 hors QEMU : c54x_exe et grgsm_exe

_Dans Docker : `FROM qemu`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

Elles compilent les sources de /opt/GSM/qosmo (deja la, ce stage en derive) et se lient a libosmocoding/libosmocore pour c54x_exe. On rapatrie donc /usr/local depuis osmo-core plutot que de faire deriver ce stage de lui : copier /usr/local (quelques centaines de Mo) coute bien moins que de copier l arbre de build de QEMU (~1,5 Go d objets) dans l autre sens.

_Copie entre etapes Docker (`--from=osmo-core /usr/local /usr/local`) : sur une seule machine, `/usr/local` est deja en place._

```bash
ldconfig
```

c54x_exe : le Makefile met -march=native dans CFLAGS - dans une image qui tourne sur d autres CPU que celui du build, c est un SIGILL au demarrage. On garde ses drapeaux, sans celui-la. La ROM est aussi posee en /opt/GSM/calypso_dsp.*.bin, le --rom-dir par defaut de c54x_exe. [2026-10-10] La ROM n est plus dans le depot c54x_exe : le `cp rom/...` tombait sur « cannot stat rom/calypso_dsp.txt ». rom/fetch-rom.sh telecharge le dump FreeCalypso 3606, le convertit en .bin et verifie SHA256SUMS.3606 ; calypso_dsp.txt, c est le dump brut lui-meme, qu il ne garde pas : on le telecharge a part.

```bash
export FREECALYPSO_URL=ftp://ftp.freecalypso.org/pub/GSM/Calypso
```

```bash
if ! osmo-deb install c54x-exe 0.git; then \
      git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe \
      && cd /opt/GSM/c54x_exe \
      && make QOSMO=/opt/GSM/qosmo \
             CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare" \
      && FREECALYPSO_URL="$FREECALYPSO_URL" bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom \
      && curl -fsS --retry 2 -o /opt/GSM/calypso_dsp.txt "$FREECALYPSO_URL/dsp-rom-3606-dump.txt" \
      && cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt \
      && osmo-deb snapshot c54x-exe 0.git /opt/GSM/c54x_exe \
             /opt/GSM/calypso_dsp.PROM0.bin /opt/GSM/calypso_dsp.PROM1.bin /opt/GSM/calypso_dsp.PROM2.bin \
             /opt/GSM/calypso_dsp.PROM3.bin /opt/GSM/calypso_dsp.DROM.bin /opt/GSM/calypso_dsp.PDROM.bin \
             /opt/GSM/calypso_dsp.Registers.bin /opt/GSM/calypso_dsp.txt; \
    fi
```

```bash
if ! osmo-deb install grgsm-exe 0.git; then \
      git clone https://github.com/bbaranoff/grgsm_exE /opt/GSM/grgsm_exe \
      && cd /opt/GSM/grgsm_exe \
      && make QOSMO=/opt/GSM/qosmo \
      && osmo-deb snapshot grgsm-exe 0.git /opt/GSM/grgsm_exe; \
    fi
```


## Etape 6 : grgsm-venv

STAGE grgsm-venv — GNU Radio 3.10 + gr-osmosdr + gr-gsm dans /root/.env

gr-gsm se lie a libosmocore/libosmocoding/libosmogsm (son CMakeLists les cherche par pkg-config) : ce stage DOIT donc partir d osmo-core, pas de base. Il reste parallele a `bb` et a `l1`, qui en derivent aussi.

_Dans Docker : `FROM osmo-core`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

#### ── gr-gsm : GNU Radio 3.10 + gr-osmosdr + gr-gsm dans le venv /root/.env

(= moteur de démod du SI réel utilisé par si_bridge.py / grgsm_decode). Les deps GNU Radio (apt build-dep) sont posees par l unique bloc apt en tete de fichier, deb-src compris : plus aucun apt ici.

#### ── GNU Radio + gr-osmosdr + gr-gsm, en UN paquet : le venv /root/.env

On TÉLÉCHARGE et on exécute CE script (le gist, pinné au commit fcdb409). Il cree /root/.env et y installe les trois. Puis :

Patch gr-gsm : le receiver poste le BSIC/FN du SCH (decode_sch) sur le port `measurements` ET sur stdout ("SCHBSIC <bsic> <fn>"). Le shunt DSP le recoit (si_bridge.py parse le stdout de grgsm_decode -> UDP 4731 -> feed_sb) et encode le VRAI BSIC dans dispatch_sb (remplace SHUNT_CANNED_BSIC 63). Applique APRES le gist (qui clone+build gr-gsm propre), puis recompile/reinstalle dans le venv. Patch maintenu dans patches/ (regenere a chaque changement gr-gsm).

matplotlib est consomme par tools/fft_global.sh et tools/matrix.sh.

Le paquet du cache (grgsm-venv) est le venv COMPLET, patch et matplotlib compris : c est pour cela que les trois etapes tiennent dans un seul RUN. Les arbres /opt/GSM/{gnuradio,gr-osmosdr,gr-gsm} ne sont pas dans le paquet - rien ne les lit au runtime (le venv porte ses .so avec un RPATH sur /root/.env).

```bash
mkdir -p "$(dirname /tmp/grgsm-receiver-publish-bsic-fn.patch)" && cp -r "$REPO"/patches/grgsm-receiver-publish-bsic-fn.patch /tmp/grgsm-receiver-publish-bsic-fn.patch
```

```bash
if ! osmo-deb install grgsm-venv 0.git; then \
      curl -fsSL https://gist.githubusercontent.com/bbaranoff/3683811057933af0954b661821e950d1/raw/fcdb4092483ec383440b67fc002db0c158384bab/build.sh | bash \
      && git -C /opt/GSM/gr-gsm apply /tmp/grgsm-receiver-publish-bsic-fn.patch \
      && cd /opt/GSM/gr-gsm/build \
      && make -j"$(nproc)" \
      && make install \
      && . ~/.env/bin/activate && pip install matplotlib \
      && osmo-deb snapshot grgsm-venv 0.git /root/.env /etc/ld.so.conf.d/gnuradio.conf; \
    fi && ldconfig
```


## Etape 7 : node

STAGE node — Node 22 et le dashboard web osmo-egprs-web

_Dans Docker : `FROM base`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

Node.js + dashboard web osmo-egprs-web (ex-Dockerfile.run, chaine complete)

Place EN FIN DE FICHIER a dessein : aucune etape du build ne depend de Node, et la fin de fichier preserve le cache des couches longues de compilation. L'ORDRE INTERNE DE CETTE CHAINE EST CONTRAINT — voir les ⚠️ ci-dessous. /opt/GSM et pas /opt : c'est /opt/GSM que l'ISO recupere en bloc (docker cp "$CID:/opt/GSM"). Le dashboard vivait a cote, dans /opt, et devait donc etre reclone une seconde fois a la construction de l'image - deux sources pour le meme depot, qui n'avancaient pas ensemble.

```bash
if [ ! -d "/opt/GSM/osmo-egprs-web/" ]; then \
      mkdir -p /opt/GSM && \
      git clone -b main https://github.com/bbaranoff/osmo-egprs-web /opt/GSM/osmo-egprs-web; \
    fi
```

#### ── Runtime Node.js + service web osmo-egprs-web

Le dashboard /opt/GSM/osmo-egprs-web/server.js tourne en mode NATIF (telnet VTY local, pas de docker) et est servi sur :8080. Le DÉMARRAGE est géré par start-native.sh (`systemctl restart osmo-egprs-web`) — ici on ne fait qu'INSTALLER le runtime + les dépendances + le unit (enable au boot).

Node 22 (LTS « Jod ») — même famille majeure que l'ISO, qui installe nodesource setup_22.x (build-iso.sh). Garder les deux alignés : le dashboard est le même server.js des deux côtés.

```bash
export NODE_VERSION=v22.23.2
```

Le tarball suit l architecture de l image (x64 sur amd64, arm64 sur un build --platform linux/arm64 pour le Raspberry Pi) : un node x64 dans une image arm64 ne se lancerait pas, et le dashboard avec lui.

```bash
case "$(uname -m)" in x86_64) _na=x64 ;; aarch64) _na=arm64 ;; *) echo "arch node inconnue: $(uname -m)" >&2; exit 1 ;; esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${_na}.tar.xz" \
        -o /tmp/node.tar.xz && \
    mkdir -p /opt/node && \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && \
    rm -f /tmp/node.tar.xz && \
    ln -sf /opt/node/bin/node /usr/local/bin/node && \
    ln -sf /opt/node/bin/npm  /usr/local/bin/npm && \
    ln -sf /opt/node/bin/npx  /usr/local/bin/npx && \
    node --version
```

Unit systemd (fichier versionné dans le repo osmo-nitb-for-calypso, source unique). Le START reste géré par start-native.sh (`systemctl restart osmo-egprs-web`).

```bash
mkdir -p "$(dirname /etc/systemd/system/osmo-egprs-web.service)" && cp -r "$REPO"/services/osmo-egprs-web.service /etc/systemd/system/osmo-egprs-web.service
```

```bash
ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service
```

#### ── Dashboard web : install-web-service.sh joue AU BOOT

[2026-08-12] Remplace le geste manuel `bash /opt/GSM/osmo-egprs-web/install-web-service.sh` qu'il fallait refaire dans chaque conteneur pour armer le HTTPS.

Ce qui reste au BUILD : node et le unit du service (plus haut), le `npm install` (juste en dessous). Ce qui passe au BOOT : le certificat TLS auto-signe — une cle privee generee au build serait la meme pour tous ceux qui tirent l'image. Le detail du raisonnement est dans services/osmo-egprs-web-install.service.

⚠️ ORDRE : ce bloc DOIT rester APRES le clone de /opt/GSM/osmo-egprs-web (haut de cette section) — la COPY ci-dessous ecrit dans ce depot.

SOURCE UNIQUE DU UNIT. install-web-service.sh installe le unit en le copiant depuis /opt/GSM/osmo-egprs-web/osmo-egprs-web.service — la copie du depot osmo-egprs-web, qui avait DIVERGE de celle-ci (elle avait perdu `CAP_IFACE=any`, donc la capture du dashboard). On ecrase donc cette copie par services/osmo-egprs-web.service : les deux emplacements servent desormais le meme fichier, et le script ne peut plus reintroduire la regression.

```bash
mkdir -p "$(dirname /opt/GSM/osmo-egprs-web/osmo-egprs-web.service)" && cp -r "$REPO"/services/osmo-egprs-web.service /opt/GSM/osmo-egprs-web/osmo-egprs-web.service
```

Fail-fast : si l'amont retire le script, on le sait au build, pas au boot par un HTTPS muet.

```bash
test -s /opt/GSM/osmo-egprs-web/install-web-service.sh
```

Dependances JS (ws) — UN SEUL `npm install`, apres le clone. Non fatal (`|| true`) : node_modules est versionne dans le depot, un build hors-ligne reste valable. Mais la sortie est conservee, pas avalee.

```bash
cd /opt/GSM/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund || true
```

#### ── L INSTALLATION EST JOUEE ICI, AU BUILD

[2026-08-31] On se contentait de VERIFIER que le script existe (le `test -s` ci-dessus) et on remettait tout au boot. L unite arrivait donc dans l image telle que le gabarit la portait, avec son ExecStart fige — et dans un conteneur, ou node vit en /usr/local/bin et non /usr/bin, systemd sortait en

```text
    status=203/EXEC
```

en boucle, sans que rien ne parle d un chemin.

Le script sait resoudre node et poser l unite avec le bon chemin : on le joue donc au build, pour que l image contienne une unite deja juste.

`|| true` : dans un build il n y a PAS de systemd. Le script le sait et ne s arrete pas dessus (voir son en-tete), mais ses `systemctl` echouent forcement ; les avaler ici evite qu un detail d environnement fasse tomber une image de 11 Go. Ce qui compte - le unit, le certificat, le runtime - est ecrit avant ces appels.

⚠️ ET IL N Y A PLUS DE REJEU AU BOOT. osmo-egprs-web-install.service a ete retire des trois chemins de deploiement, pour une raison simple : ce script TELECHARGE node quand il manque. Le laisser au demarrage faisait dependre d Internet un banc concu pour tourner isole - et un premier boot hors ligne repartait sans dashboard. Tout est desormais fige dans l image ; le demarrage ne fait plus que lancer osmo-egprs-web.service.

```bash
bash /opt/GSM/osmo-egprs-web/install-web-service.sh || true
```


## Etape 8 : lte

STAGE lte — la 4G du banc : srsRAN_4G (ZeroMQ) et Open5GS dans /opt/LTE

_Dans Docker : `FROM base`. Sur une machine, on continue dans le meme systeme._

ARG ne traverse pas un FROM : les stages qui appellent osmo-deb ou ${ROOT} doivent les redeclarer, sinon ROOT est vide et OSMO_DEB_REFRESH=1 (build.sh --no-cache) ne descend pas jusqu ici.

```bash
export ROOT=/opt/GSM
```

```bash
export OSMO_DEB_REFRESH=0
```

osmo-lte-install --configs lit $OSMO_REPO : ce stage a besoin du depot, et il ne derive pas de celui qui le clone. Le clone y est donc refait — c est quelques secondes, et l assemblage refait le sien, qui reste LA source pour le `git pull` de Dockerfile.run.

```bash
git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator
```

#### ── LA 4G DU BANC : srsRAN_4G (ZeroMQ) et Open5GS, dans /opt/LTE

[2026-09-08] DEUX CHEMINS VERS LES MEMES PAQUETS (voir packaging/ snapshot-lte-debs.sh) : le raccourci photographie le natif de la machine de reference en osmo-build-libzmq / osmo-build-srsran / osmo-build-open5gs, et le cache .deb les rend a `osmo-deb install` ci-dessous - rien n est alors compile. Cache vide : on compile depuis les sources, par le MEME script que le natif (tools/osmo-lte-install.sh --build, OSMO_DEB=1 -> osmo-deb pack). libzmq vient d Ubuntu (libzmq3-dev, pose par `--deps` ci-dessous) : le /opt/LTE/libzmq compile a la main n a de raison d etre que sur le natif. Open5GS : prefixe /opt/LTE/open5gs/install (bin, etc/open5gs, var/log) - pas /root.

LES CONFIGS ET LES LANCEURS AUSSI (`--configs --launchers`, en fin de RUN). [2026-09-09] Ils n etaient poses que dans l ISO (88-lte-pmos.sh) et en natif (addition.sh), « pas ici : l image docker n a pas de HOME de session a servir ». Faux pour le conteneur : il tourne en root, et /root/.config/srsran EST le HOME que srsenb/srsue lisent. L image sortait donc avec les binaires 4G mais sans mme.yaml (donc sans SGs, donc sans CSFB), sans enb.conf, et sans la commande osmo-lte : une 4G qu on ne pouvait pas lancer. Et le .deb Open5GS n apporte AUCUN yaml (ninja install sous DESTDIR ne pose pas les exemples : 128 fichiers, tous dans bin/ et lib/) - les configs du depot sont la seule source. Elles viennent du clone GitHub de /opt/GSM/ osmo-operator (ligne « git clone » plus haut) : ce qui est pousse est ce que le conteneur voit. Les abonnes (configs/open5gs/dump, subscribers.json) ne sont pas poses au build : osmo-epc start les restaure dans MongoDB.

⚠️ `--deps` D ABORD, TOUJOURS (pas seulement quand on compile). [2026-09-09] Le commentaire ci-dessus affirmait que libzmq3-dev etait « dans la liste apt plus haut » : il n y etait pas, ni lui ni libmbedtls-dev, libboost-program-options-dev, libconfig++-dev, meson, flex, bison, libmongoc. Le build tombait donc net des le cmake de srsRAN :

```text
    Could NOT find MbedTLS (missing: MBEDTLS_LIBRARIES MBEDTLS_INCLUDE_DIRS)
```

La liste apt du haut de ce fichier est celle de la pile Osmocom (et elle est RELUE par install_modules/10-deps.sh pour le natif) : la 4G a la sienne, tenue dans tools/osmo-lte-install.sh (lte_deps), une seule fois pour les trois chemins. On l appelle, on ne la recopie pas. Inconditionnel parce que ces paquets sont aussi le RUNTIME : les .deb du cache ne portent que les binaires (osmo-deb pack = un tar), pas leurs dependances - srsenb sorti du cache reclame quand meme libmbedtls, libzmq5, libconfig++ et boost_program_options. `--deps` tire aussi mongodb-org (base d abonnes du HSS/PCRF) et n est fatal sur aucun paquet.

```bash
mkdir -p "$(dirname /usr/local/sbin/osmo-lte-install)" && cp -r "$REPO"/tools/osmo-lte-install.sh /usr/local/sbin/osmo-lte-install
```

```bash
chmod 755 /usr/local/sbin/osmo-lte-install && \
    OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --deps && \
    { osmo-deb install libzmq 4.3.5+git || true; } && \
    { osmo-deb install srsgui 0.1+git || true; } && \
    SRS_DEB_VER="$(osmo-lte-install --srs-deb-version)" && \
    if ! osmo-deb install srsran "$SRS_DEB_VER"; then \
        OSMO_DEB=1 OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --build || { echo "ECHEC build srsRAN"; exit 1; }; \
    fi && \
    if ! osmo-deb install open5gs 2.8.0+git; then \
        OSMO_DEB=1 OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --build || { echo "ECHEC build Open5GS"; exit 1; }; \
    fi && \
    OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --configs --launchers && \
    ldconfig && test -x /usr/local/bin/srsenb && test -x /opt/LTE/open5gs/install/bin/open5gs-mmed \
    && test -s /opt/LTE/open5gs/install/etc/open5gs/mme.yaml && grep -q '^  sgsap:' /opt/LTE/open5gs/install/etc/open5gs/mme.yaml \
    && test -s /opt/LTE/open5gs/install/etc/freeDiameter/mme.conf && test -s /opt/LTE/open5gs/install/etc/open5gs/tls/mme.crt \
    && test -s /root/.config/srsran/enb.conf && test -x /usr/local/bin/osmo-lte && test -x /usr/local/bin/osmo-epc
```

#### ── L UI SMARTPHONE : pmbootstrap PATCHE, dans /opt/user_interface/pmos

Le telephone du banc est une VM postmarketOS lancee par pmbootstrap (patche pour le modem serie PCI, le son du banc, la taille d ecran, et le port 5038 qui n est pas un adb : patches/pmbootstrap-osmo-bench-qemu.patch). Le clone et le patch sont faits ici, une fois, et sortent en osmo-build-pmbootstrap : l ISO (50-injection-image.sh) le pose tel quel, tools/osmo-pmos-install.sh le trouve en place et n a plus rien a cloner. Le NOYAU PPP, lui, ne se construit pas ici (pmbootstrap, non root, montages de boucle) : il arrive par osmo-build-pmos-kernel (packaging/build-pmos-kernel-deb.sh, ou GitHub bbaranoff/pmos_ppp_kernel), pose par 88-lte-pmos.sh.

```bash
mkdir -p "$(dirname /tmp/pmbootstrap-osmo-bench-qemu.patch)" && cp -r "$REPO"/patches/pmbootstrap-osmo-bench-qemu.patch /tmp/pmbootstrap-osmo-bench-qemu.patch
```

```bash
if ! osmo-deb install pmbootstrap 0.git; then \
        mkdir -p /opt/user_interface/pmos && \
        git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git /opt/user_interface/pmos/pmbootstrap && \
        cd /opt/user_interface/pmos/pmbootstrap && \
        git apply /tmp/pmbootstrap-osmo-bench-qemu.patch && \
        grep -q osmo_bench_args pmb/commands/qemu.py && \
        osmo-deb snapshot pmbootstrap 0.git /opt/user_interface/pmos/pmbootstrap; \
    fi && test -f /opt/user_interface/pmos/pmbootstrap/pmbootstrap.py
```


## Etape 9 : osmocom-nitb

============================================================================ STAGE osmocom-nitb — L ASSEMBLAGE. C est l image publiee. ============================================================================ Rien ne se compile ici : on repose les .deb produits par les stages, puis on ajoute ce qu aucun paquet ne porte (Node, le dashboard, la 4G, le depot, les configs du contexte). Le nom osmocom-nitb reste sur CETTE etape : build.sh (compose_build) et compose.yaml passent --target osmocom-nitb.

_Dans Docker : `FROM base`. Sur une machine, on continue dans le meme systeme._

```bash
export ROOT=/opt/GSM
```

#### ── 1. Les paquets de tous les stages

bb DERIVE de osmo-core et l1 DERIVE de qemu : leur cache porte deja celui de leur parent, d ou cinq COPY et non sept.

_Copie entre etapes Docker (`--from=bb         /var/cache/osmo-debs/ /var/cache/osmo-debs/`) : sur une seule machine, `/var/cache/osmo-debs/` est deja en place._

_Copie entre etapes Docker (`--from=l1         /var/cache/osmo-debs/ /var/cache/osmo-debs/`) : sur une seule machine, `/var/cache/osmo-debs/` est deja en place._

_Copie entre etapes Docker (`--from=grgsm-venv /var/cache/osmo-debs/ /var/cache/osmo-debs/`) : sur une seule machine, `/var/cache/osmo-debs/` est deja en place._

_Copie entre etapes Docker (`--from=lte        /var/cache/osmo-debs/ /var/cache/osmo-debs/`) : sur une seule machine, `/var/cache/osmo-debs/` est deja en place._

(pas de COPY depuis `node` : ce stage n appelle jamais osmo-deb - Node est un

```text
 tarball et le dashboard un clone git. Son cache n est que celui de base.)
```

⚠️ L ORDRE DE POSE COMPTE POUR LES QUATRE PAQUETS PATCHES. osmo-trx, osmo-bts, osmo-hlr et osmo-msc existent en DEUX versions portant le MEME nom de paquet : celle de la boucle (osmo-trx 1.7.2) et la patchee (1.7.2+ipc). Dans la chaine lineaire d avant, la patchee etait posee apres, donc elle gagnait. Ici le glob les pose dans l ordre ASCII, ou « + » (0x2B) precede « ~ » (0x7E) : osmo-trx_1.7.2+ipc passe AVANT osmo-trx_1.7.2, et c est la version NON patchee qui finissait installee - RACH sans table per-RA, BTS/HLR/MSC sans le forcage du RAND, et une LU qui ne passe plus. Silencieux : le binaire est la, il est juste le mauvais. On repose donc les quatre explicitement, en dernier.

```bash
set -eux; \
    dpkg -i --force-overwrite /var/cache/osmo-debs/osmo-build-*.deb; \
    dpkg -i --force-overwrite \
        /var/cache/osmo-debs/osmo-build-osmo-trx_1.7.2+ipc~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-bts_1.10.0+rand~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-hlr_1.9.2+rand~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-msc_1.15.0+rand~*.deb; \
    ldconfig
```

#### ── 2. Ce qu aucun .deb ne porte

Node et le dashboard : le runtime est un tarball detarre dans /opt/node, le dashboard un clone git avec son node_modules. Ni l un ni l autre ne passe par osmo-deb, et install-web-service.sh a deja ete joue dans le stage node.

_Copie entre etapes Docker (`--from=node /opt/node                                      /opt/node`) : sur une seule machine, `/opt/node` est deja en place._

_Copie entre etapes Docker (`--from=node /opt/GSM/osmo-egprs-web                        /opt/GSM/osmo-egprs-web`) : sur une seule machine, `/opt/GSM/osmo-egprs-web` est deja en place._

_Copie entre etapes Docker (`--from=node /etc/systemd/system/osmo-egprs-web.service     /etc/systemd/system/osmo-egprs-web.service`) : sur une seule machine, `/etc/systemd/system/osmo-egprs-web.service` est deja en place._

```bash
ln -sf /opt/node/bin/node /usr/local/bin/node \
    && ln -sf /opt/node/bin/npm  /usr/local/bin/npm \
    && ln -sf /opt/node/bin/npx  /usr/local/bin/npx \
    && ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service \
    && node --version
```

Chemin EXPLICITE. Sans lui, ce clone heritait du WORKDIR /etc/osmocom (pose beaucoup plus haut, jamais remis a ${ROOT}) et atterrissait dans /etc/osmocom/osmo-operator — masque au runtime par le montage de start-docker.sh l.505, et surtout PAS la ou Dockerfile.run va faire son `git pull`. Deux arbres, deux HEAD, un seul utilise. /opt/GSM/osmo-operator est le chemin nominal, teste en premier par build-iso.sh l.964 et update.sh l.329. On reste sur la branche par defaut du depot (main) : pas de checkout explicite, donc pas de ref a maintenir ici, et HEAD est attache — ce dont le `git pull` de Dockerfile.run a besoin.

```bash
git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator
```

```bash
mkdir -p "$(dirname /usr/local/sbin/osmo-lte-install)" && cp -r "$REPO"/tools/osmo-lte-install.sh /usr/local/sbin/osmo-lte-install
```

```bash
chmod 755 /usr/local/sbin/osmo-lte-install
```

#### ── La 4G

/opt/LTE en entier, et pas seulement ce que portent les .deb : le prefixe d installation d Open5GS vit SOUS l arbre de sources (/opt/LTE/open5gs/install), et /opt/LTE n est pas sous /opt/GSM - osmo-deb pack n y ajoute donc aucune source (SRC_ROOT). Sans cette copie, l image aurait les binaires 4G sans un seul arbre pour les recompiler.

_Copie entre etapes Docker (`--from=lte /opt/LTE /opt/LTE`) : sur une seule machine, `/opt/LTE` est deja en place._

⚠️ `--deps` DOIT ETRE REJOUE ICI. Ce sont AUSSI les paquets de RUNTIME (libzmq5, libmbedtls, libconfig++, boost_program_options, mongodb-org...) et les .deb d osmo-deb ne declarent aucune dependance - leur en-tete le dit. Les poser dans le seul stage `lte` donnait une image ou srsenb et open5gs-mmed existent mais ne demarrent pas, faute de .so. Le montage du cache apt fait que rien n est retelecharge : les paquets sont deja dans le cache BuildKit, poses par le stage lte.

`--configs --launchers` ensuite, dans le meme ordre que le stage lte : les yaml d Open5GS, enb.conf et les deux lanceurs s ecrivent HORS de tout DESTDIR, donc aucun .deb ne les porte. Ils lisent /opt/GSM/osmo-operator, clone juste au-dessus.

```bash
OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --deps && \
    OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --configs --launchers && \
    ldconfig && test -x /usr/local/bin/srsenb \
    && test -x /opt/LTE/open5gs/install/bin/open5gs-mmed \
    && test -s /opt/LTE/open5gs/install/etc/open5gs/mme.yaml && grep -q '^  sgsap:' /opt/LTE/open5gs/install/etc/open5gs/mme.yaml \
    && test -s /opt/LTE/open5gs/install/etc/freeDiameter/mme.conf \
    && test -s /opt/LTE/open5gs/install/etc/open5gs/tls/mme.crt \
    && test -s /root/.config/srsran/enb.conf && test -x /usr/local/bin/osmo-lte && test -x /usr/local/bin/osmo-epc
```

Les alternatives gcc : elles ont ete DECLAREES dans le stage bb, qui ne transmet que ses .deb. On les redeclare ici pour que l image finale offre le meme choix, et on reste sur gcc-11 - le defaut d avant le decoupage.

```bash
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11 \
    && update-alternatives --set gcc /usr/bin/gcc-11
```

#### 4. Installation des fichiers du projet

```bash
cd /etc/osmocom
```

```bash
mkdir -p /etc/osmocom/ && cp -r "$REPO"/scripts/. /etc/osmocom/
```

```bash
mkdir -p /etc/osmocom/ && cp -r "$REPO"/configs/*cfg /etc/osmocom/
```

```bash
mv /etc/osmocom/run.sh /root/run.sh
```

Copie des binaires vers /usr/bin pour systemd et installation des .service (La `COPY scripts/gapk-start.sh /etc/osmocom/gapk-start.sh` qui etait ici est

```text
 supprimee : `COPY scripts/. /etc/osmocom/` ci-dessus depose deja le fichier.
 Le RUN ci-dessous reste : le symlink et /var/lib/gapk sont uniques.)
```

```bash
chmod +x /etc/osmocom/gapk-start.sh && \
    ln -sf /etc/osmocom/gapk-start.sh /usr/local/bin/gapk-start.sh && \
    mkdir -p /var/lib/gapk
```

```bash
cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    cp -f /usr/local/bin/proto-smsc-* /usr/bin/ || true && \
    cp -f /usr/local/bin/sms-* /usr/bin/ || true && \
    cp -f /usr/local/bin/gen-sms-* /usr/bin/ || true && \
    # Si tu as des fichiers .service dans configs/
    cp /etc/osmocom/configs/*.service /lib/systemd/system/ 2>/dev/null || true
```

#### ── Vérification binaires proto-SMSC

Ex-Dockerfile.run. Premier point du build ou les deux chemins testes sont peuples (produits par gsup-smsc-proto, recopies dans /usr/bin juste au-dessus).

```bash
which proto-smsc-daemon && which proto-smsc-sendmt && \
    echo "proto-smsc binaries OK" || \
    echo "WARNING: proto-smsc binaries not found in PATH"
```

#### 5. Fix Permissions & Systemd (Status 214/217)

```bash
sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service && \
    chmod +x /etc/osmocom/*.sh
```

Activation du service et nettoyage Les unites systemd vivent dans services/ ; elles doivent atterrir dans /etc/systemd/system/, seul repertoire ou systemd les cherche.

```bash
mkdir -p "$(dirname /etc/systemd/system/osmo-bts-trx.service)" && cp -r "$REPO"/services/osmo-bts-trx.service /etc/systemd/system/osmo-bts-trx.service
```

```bash
systemctl enable osmo-bts-trx.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service
```

Binaires cote hote produits par osmocom-bb, deposes en une seule couche. `install -m755` plutot que `cp` : les droits sont explicites, pas herites.

```bash
mkdir -p /root/.osmocom/bb/ \
    && install -m755 ${ROOT}/osmocom-bb/src/host/trxcon/src/trxcon           /usr/local/bin/trxcon \
    && install -m755 ${ROOT}/osmocom-bb/src/host/layer23/src/mobile/mobile   /usr/local/bin/mobile \
    && install -m755 ${ROOT}/osmocom-bb/src/host/virt_phy/src/virtphy        /usr/local/bin/virtphy
```

ccch_scan n'est plus installe ici : la branche fixeria/burst_ind, en fin de fichier, ecrase de toute facon /usr/local/bin/ccch_scan par SA version (cp sans `|| true`, donc obligatoire). Le binaire de master ne survivait jamais — c'est la version burst_ind qui fait foi. Confort du shell interactif. Pas de `source` ici : chaque RUN est un shell neuf, ce serait sans effet — le fichier est lu a l'ouverture d'une session.

```bash
echo "alias faketrx='python3 ${ROOT}/osmocom-bb/src/target/trx_toolkit/fake_trx.py'" >> ~/.bashrc
```

Prompt : root(rouge)@(bleu)<nom-container=\h>(jaune)☎️<dossier courant>(vert)# \h = nom du container grâce à `docker run --hostname "$container_name"` (start-docker.sh). [refactor] LE PS1 ETAIT DEFINI DEUX FOIS, avec deux formats DIFFERENTS : ici et dans Dockerfile.run. Bash lit ~/.bashrc de haut en bas -> c'est celui de Dockerfile.run qui gagnait, et le prompt reellement affiche etait `user@host:cwd☎️#`, pas celui decrit deux lignes plus haut. On ne garde QUE le gagnant, a l'identique, pour ne rien changer au prompt visible ; l'explication du `\h` ci-dessus reste vraie pour les deux formats.

#### ── Prompt interactif (root rouge / hostname bleu / cwd vert / ☎️#)

```bash
printf '%s\n' '' \
    '### calypso-prompt ###' \
    "export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️# '" \
    '### end calypso-prompt ###' >> /root/.bashrc
```

```bash
mkdir -p "$(dirname /root/.osmocom/bb/mobile.cfg)" && cp -r "$REPO"/configs/mobile.cfg /root/.osmocom/bb/mobile.cfg
```

```bash
chmod +x /root/run.sh
```

Répertoires pour le proto-SMSC + arborescence Asterisk (ex-Dockerfile.run, ou ce mkdir faisait doublon avec celui-ci ; seul le chmod 755 etait unique). Position : apres l'installation d'asterisk (liste apt) et apres WORKDIR /etc/osmocom.

```bash
mkdir -p /var/log/osmocom /var/run/smsc \
        /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk \
        /root/.osmocom/bb && \
    chmod 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk \
        /var/run/asterisk /var/log/osmocom
```

#### ── PulseAudio system-mode : config bakée au build

(ex-Dockerfile.run — depend du paquet pulseaudio de la liste apt en tete ;

```text
 place ici, tard, pour ne pas invalider le cache des ~200 lignes de compilation.)
```

Cause racine du warning "[audio] PulseAudio injoignable — audio dégradé" : le démon system-mode lancé au runtime tournait SANS auth-anonymous (le patch de start-native.sh arrivait après son démarrage) → 'pactl' renvoyait "Access denied", et un 2e démon ne pouvait pas démarrer ("Daemon already running"). On bake ici la config pour que TOUT démon soit joignable dès son lancement : socket anonyme + null-sinks gsm_audio/gsm_mic + root dans pulse-access.

[2026-08-12] gsm_mic AJOUTÉ ICI. Il n'était créé que par scripts/pulse-gsm-setup.sh, appelé tard dans run.sh (après osmo-start.sh) : un HLR qui rate coupe run.sh (set -e) et le sink n'existe jamais. Or configs/asound.conf fait pointer la CAPTURE gsm_in sur gsm_mic.monitor, et gapk_io abandonne lecture ET capture si la capture échoue → appel muet des deux côtés. Les deux sinks doivent naître avec le démon, pas avec un script.

```bash
set -eux; \
    usermod -aG pulse-access root 2>/dev/null || true; \
    test -f /etc/pulse/system.pa; \
    sed -i 's|^#\?load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' /etc/pulse/system.pa; \
    grep -q 'auth-anonymous=1' /etc/pulse/system.pa \
      || echo 'load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native' >> /etc/pulse/system.pa; \
    grep -q 'sink_name=gsm_audio' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=gsm_audio format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Audio' >> /etc/pulse/system.pa; \
    grep -q 'sink_name=gsm_mic' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=gsm_mic format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Mic' >> /etc/pulse/system.pa; \
    grep -q 'sink_name=osmo_tts_off' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=osmo_tts_off format=s16le rate=8000 channels=1 sink_properties=device.description=TTS_off' >> /etc/pulse/system.pa; \
    sed -i 's|^load-module module-suspend-on-idle|#load-module module-suspend-on-idle|' /etc/pulse/system.pa; \
    mkdir -p /var/run/pulse && chown -R pulse:pulse /var/run/pulse
```

Dernier maillon de la chaine venv/gr-gsm (ex-Dockerfile.run) : le profil de root active le venv.

```bash
echo 'source ~/.env/bin/activate' >> ~/.bashrc
```

#### ── scripts bridge camping -> /opt/GSM (sinon /opt/GSM/qosmo/run.sh casse)

si_bridge.py (full SI set -> 4730 -> shunt feed_si), si_bridge_loop.sh, record_drain.py (iq_record.fifo -> record.cfile), grgsm_fft_live.py.

```bash
mkdir -p /opt/GSM/ && cp -r "$REPO"/opt-gsm/. /opt/GSM/
```

#### Metadonnees de l'image

Regroupees a la fin : elles decrivent le conteneur qui tournera, pas une etape de construction. SIGRTMIN+3 est le signal d'arret propre de systemd.

_Metadonnee Docker, sans equivalent sur une machine : `STOPSIGNAL SIGRTMIN+3`._

_Metadonnee Docker, sans equivalent sur une machine : `ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]`._

_Metadonnee Docker, sans equivalent sur une machine : `CMD ["/bin/bash"]`._


## Etape 10 : debs

#### ── L'ETAPE `debs` : le cache .deb seul, rien d'autre

ATTENTION - `osmocom-nitb` N'EST PLUS LA DERNIERE ETAPE de ce fichier. Tout ce qui construit l'image doit donc dire `--target osmocom-nitb` : build.sh (compose_build), compose.yaml (build.target du service nitb), iso_modules/21-docker-build.sh, .github/workflows/docker.yml. Sans ce --target, docker batit `debs` et sort une image VIDE de 2 Go de paquets.

Pourquoi cette etape existe. En CI, l'image de base n'est plus chargee dans le docker du runner : elle part directement vers GHCR (buildx --push), parce que la materialiser localement demandait de tenir DEUX fois 11 Go et tuait le job en « exporting layers » (exit 143). Mais le workflow doit quand meme recuperer les .deb que le build vient de compiler, pour les rendre a actions/cache - et sans image locale, plus de `docker create` ni de `docker cp` (l'equivalent de debs_from_image, build.sh:306).

D'ou cette etape : une seconde passe `--target debs --output type=local` reutilise INTEGRALEMENT le cache de la premiere (meme builder, memes couches, tout en hit) et n'ecrit sur le disque du runner que /var/cache/osmo-debs - quelques Go de .deb au lieu de l'image entiere. Sur l'hote, build.sh continue de passer par debs_from_image : il a l'image sous la main, lui.

_Etape Docker sans contenu propre (image `scratch`) : rien a faire sur une machine._

_Copie entre etapes Docker (`--from=osmocom-nitb /var/cache/osmo-debs/ /`) : sur une seule machine, `/var/cache/osmo-debs/` est deja en place._


---

# Annexe : c54x_exe-depuis-ubuntu-vierge.md

_Contenu de `doc/c54x_exe-depuis-ubuntu-vierge.md`, repris tel quel._

## c54x_exe depuis une Ubuntu 24.04 vierge

Oct 20, 2026 · Bastien Baranoff

### Ce que montre cette page

En une vingtaine de minutes, le cœur TMS320C54x émulé de `c54x_exe` charge la mask-ROM TI d'un vrai Calypso et l'exécute, sans QEMU, sans ARM, sans réseau GSM.

C'est le hello world du DSP : il prouve que le cœur exécute du vrai code TI. Il ne prouve pas que le DSP décode quoi que ce soit, puisque aucun burst n'est injecté. Le montage complet (ARM sous QEMU, BTS, pont, appel voix) est décrit en fin de page et vit dans [osmo-operator](https://github.com/bbaranoff/osmo-operator).

Tout se fait en root ou avec `sudo` ; les chemins `/opt/GSM/…` sont ceux que les Makefile et les scripts attendent par défaut.

### 1. Prérequis (Ubuntu 24.04)

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

### 2. Les sources de qosmo

`c54x_exe` ne recopie pas le cœur C54x : il compile directement les sources de [qosmo](https://github.com/bbaranoff/qosmo) (`calypso_c54x.c` et ses voisins) avec ~120 lignes de doublures d'en-têtes QEMU. Il faut donc le dépôt sur disque, mais pas le construire.

```bash
cd /opt/GSM
git clone https://github.com/bbaranoff/qosmo
```

Aucun `configure`, aucun `make` ici. Si qosmo est ailleurs que `/opt/GSM/qosmo`, passer `QOSMO=/chemin` au `make` de l'étape suivante.

### 3. Cloner et compiler c54x_exe

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

### 4. Les ROM DSP, depuis FreeCalypso

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
## calypso_dsp.PROM0.bin  calypso_dsp.PROM1.bin  calypso_dsp.PROM2.bin
## calypso_dsp.PROM3.bin  calypso_dsp.DROM.bin   calypso_dsp.PDROM.bin
## calypso_dsp.Registers.bin
```

Si `curl` refuse le FTP (certaines builds le compilent sans), le dump se télécharge à la main depuis le même répertoire sur ftp.freecalypso.org et se passe à `fetch-rom.sh` en local.

### 5. Premier run : la ROM tourne

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

### 6. Lire le résultat

`a_sch[3] = 0x771a` est une valeur constante d'un run à l'autre : la ROM a booté, s'est parquée en IDLE et a laissé cet état dans sa fenêtre API. C'est la preuve que le cœur exécute fidèlement la ROM jusque-là.

Ce que ça ne prouve pas : le décodage. L'API RAM est vierge, aucun burst n'arrive, le DSP tourne à vide. Un décodeur dont la sortie ne dépend pas de l'entrée ne décode pas ; faire varier l'entrée demande le montage complet de la section 8.

Point de repère utile : le README de `qemu-calypso` donne `0xf8d8` pour ce même mot. La différence vient de l'entrée (QEMU fournit une API RAM initialisée par l'ARM, ici elle est vide), pas d'un bug : deux entrées différentes, deux constantes différentes.

### 7. Erreurs classiques

| Symptôme | Cause | Remède |
| --- | --- | --- |
| `make` : `qemu/osdep.h` ou `calypso_c54x.c` introuvable | qosmo n'est pas à `/opt/GSM/qosmo` | `make QOSMO=/chemin/vers/qosmo` |
| `make` : `osmocom/coding/...` introuvable | `libosmocore-dev` absent ou trop vieux | section 1, dépôt nightly Osmocom |
| `fetch-rom.sh` échoue ou `curl: (1) Protocol "ftp" not supported` | `curl` compilé sans FTP, ou pare-feu | télécharger à la main, puis `fetch-rom.sh` sur le fichier local |
| `c54x_exe` : ROM introuvable | les `.bin` ne sont pas dans `/opt/GSM` | `--rom-dir /chemin` ou refaire la section 4 |
| Le bilan ne montre pas `0x771a` | mauvaise ROM, ou sections mal découpées | comparer `rom/calypso_dsp.txt` au dump 3606 ; refaire la section 4 |
| `PC=0xb41f` n'apparaît jamais, le cœur sort en erreur | régression dans qosmo | `cd /opt/GSM/qosmo && git log -3`, remonter au commit du README |

### 8. La suite : injecter des bursts

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

### 9. Le firmware Calypso : la toolchain arm-elf (gnuarm)

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
