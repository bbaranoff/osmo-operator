# Dockerfile — IMAGE DE BASE osmocom-nitb (COUCHE STABLE)
# ─────────────────────────────────────────────────────────────────────────────
# Tout ce qui est LONG et rarement modifie vit ici : la TOTALITE des paquets apt
# (une seule liste, plus aucun apt dans Dockerfile.run), la pile Osmocom
# compilee depuis les sources, osmocom-bb + le firmware Calypso, QEMU et son
# device IPC, gr-gsm/GNU Radio, le runtime Node et le dashboard web, la config
# PulseAudio, les units systemd, les repertoires, le prompt.
# ~11 Go et ~40 min de build : on ne la rebatit que quand une dependance change.
#
# [2026-09-03] BASE ubuntu:24.04 (noble) - python 3.12, gcc 13 par defaut,
# bibliotheques renommees *t64 (libasound2t64, libgnutls30t64...). L ISO
# (build-iso.sh) part du MEME noble : le venv /root/.env et les .so de
# /usr/local sont copies tels quels dans le rootfs, ils doivent trouver la
# meme glibc et le meme python. Changer la base ici, c est la changer la-bas.
#
# CACHE .deb - packaging/osmo-deb.sh. Chaque dossier compile ci-dessous sort en
# paquet .deb dans /var/cache/osmo-debs (COPY depuis .deb-cache/, que build.sh
# synchronise avec /var/cache/osmo-debs de l HOTE). Au rebuild, `osmo-deb
# install` pose le paquet et saute le clone + la compilation ; `osmo-deb pack`
# et `osmo-deb snapshot` fabriquent le paquet la premiere fois. build.sh
# --no-cache passe OSMO_DEB_REFRESH=1 : tout est recompile et le cache reecrit.
#
# L'iteration quotidienne se fait dans Dockerfile.run, qui repart de cette image
# (`FROM osmocom-nitb`) et n'y rafraichit que les scripts, les configs, le pont
# et les arbres git qosmo-grgsm / osmo-operator — en secondes, pas en 40 minutes.
#
# Cette image reste AUTONOME : elle a son propre ENTRYPOINT et start-nitb.sh la
# lance seule. Ne pas retirer ses COPY de configs/scripts sous pretexte que
# Dockerfile.run les refait : le recouvrement est voulu des deux cotes.
FROM ubuntu:24.04 AS osmocom-nitb

# ROOT : ou vivent les sources dans l'image. Chemin FIXE et assume — dans un
# conteneur, il n'y a rien a rendre portable.
ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM

ENV container=docker \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    GIT_TERMINAL_PROMPT=0

# ── apt-fast : les téléchargements apt en parallèle ─────────────────────────
# Cette image installe plusieurs centaines de paquets ; apt les récupère un par
# un, apt-fast les met en parallèle via aria2. Le gain porte sur le
# téléchargement, pas sur dpkg — l'installation reste séquentielle.
#
# UN SEUL installeur pour tous les environnements : packaging/apt-fast-install.sh
# (cette image, Dockerfile.stp, le chroot de l ISO, l hote via build.sh). Il
# pose aussi /etc/apt/apt.conf.d/90osmo-operator, les reglages de
# telechargement communs. Repli integre : sans GitHub, apt-fast appelle apt-get
# et le build continue, plus lentement.
#
# LE CACHE APT DU BUILD. [2026-09-04] Chaque etape apt de ce fichier monte
# /var/cache/apt/archives en cache BuildKit (id osmo-apt-archives, partage avec
# Dockerfile.stp) : les .deb telecharges une fois y restent, sur l hote, dans le
# cache de BuildKit - une reconstruction ne retelecharge que ce qui a change.
# apt-fast-install retire docker-clean et pose Keep-Downloaded-Packages, sinon
# apt effacerait les paquets a peine installes. Necessite BuildKit (docker
# compose, ou docker-buildx : build.sh les installe) - le builder historique
# ne connait pas --mount.
COPY packaging/apt-fast-install.sh /usr/local/sbin/apt-fast-install
RUN --mount=type=cache,id=osmo-apt-archives,target=/var/cache/apt/archives,sharing=locked \
    chmod 755 /usr/local/sbin/apt-fast-install && apt-fast-install \
    && rm -rf /var/lib/apt/lists/*
ENV DEBIAN_FRONTEND=noninteractive

# 1. Dépendances système — TOUTES ici, y compris celles qu'installait
#    Dockerfile.run. Une seule liste, un seul endroit où la faire évoluer :
#    l'image d'exécution n'a plus à connaître apt du tout.
#
# tshark tire wireshark-common, qui pose une question debconf (capture non-root)
# et bloquerait un build non interactif : on y répond d'avance.
#
# ⚠️ COUPLAGE EXTERIEUR — install_modules/10-deps.sh EXTRAIT cette liste du
# Dockerfile (« la liste fait autorite dans le Dockerfile ») avec
#   awk '/^RUN apt-get update && apt-get install/,/[^\\]$/'
# Ce motif ne connait QUE `apt-get` : depuis le passage a apt-fast, il ne
# capture plus que le bloc d'amorcage (aria2 curl ca-certificates) et
# l'installation NATIVE (hors docker) repart avec une liste tronquee —
# inst_deps_verify echoue sur build-essential/libtalloc-dev/libsctp-dev.
# Le correctif est dans 10-deps.sh (accepter `apt-(get|fast)` dans l'awk ET
# dans le sed qui suit), pas ici : ne pas repasser cette liste en apt-get pour
# contourner le probleme.
RUN echo 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections
# deb-src AVANT l unique `apt-fast update` : le build-dep gnuradio (gr-gsm, fin
# du bloc ci-dessous) lit les index Sources. Il avait son propre RUN avec un
# deuxieme update + une deuxieme resolution apt : fusionne ici. Noble ecrit ses
# sources en deb822 (ubuntu.sources, ligne "Types: deb") ; l ancien
# /etc/apt/sources.list (jammy) reste gere au cas ou la base change (gnuradio
# est dans universe : tous les composants).
RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -nE 's|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p' \
            /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list; \
    fi
RUN --mount=type=cache,id=osmo-apt-archives,target=/var/cache/apt/archives,sharing=locked \
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
    # QEMU Calypso (fork bbaranoff/qosmo-grgsm) : venv + numpy/scipy pour l'outillage
    # DSP, glib/pixman/slirp pour la cible arm-softmmu, ninja pour meson, socat
    # pour les PTY de scripts/run.sh. (Ex-bloc apt-get juste avant le build QEMU.)
    python3-venv python3-pip python3-numpy python3-scipy \
    libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
    # Ex-Dockerfile.run — outillage d'exploitation du conteneur :
    #   telnet   -> repli VTY (run_modules/21-abonnes-hlr.sh) + transport dashboard
    #   whiptail -> menus de tools/vty-menu.sh et de start.sh
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

# Capture non-root pour le dashboard et tcpdump. Position OBLIGATOIRE : dumpcap
# n'existe qu'une fois wireshark-common installe (tire par tshark, juste au-dessus).
RUN setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"

# ── Le cache .deb : l outil, puis les paquets deja construits ────────────────
# .deb-cache/ est le miroir, dans le contexte de build, de /var/cache/osmo-debs
# de l hote (build.sh l y recopie avant, et ramene les nouveaux paquets apres).
# Vide au premier build : tout se compile et se met en cache. Plein ensuite :
# chaque etape ci-dessous pose son paquet et ne compile rien.
# OSMO_DEB_REFRESH=1 (build.sh --no-cache) : le cache est ignore et reecrit.
ARG OSMO_DEB_REFRESH=0
COPY packaging/osmo-deb.sh /usr/local/sbin/osmo-deb
COPY .deb-cache/ /var/cache/osmo-debs/
RUN chmod 755 /usr/local/sbin/osmo-deb && osmo-deb list || true

# ── git : plus de forçage HTTP/1.1 ───────────────────────────────────────────
# [2026-09-03] RETIRE. Le contournement http.version=HTTP/1.1 (contre "expected
# flush after ref listing", un flux HTTP/2 coupe par un intermediaire) etait
# pose ici en global et repete a chaque clone. Il n a plus lieu d etre : git
# parle HTTP/2 normalement, et forcer HTTP/1.1 ralentissait tous les clones
# pour un incident de reseau local. GIT_TERMINAL_PROMPT=0 (ENV, plus haut)
# reste : sans terminal, un clone qui veut un login doit ECHOUER net, pas
# attendre. postBuffer large pour les gros clones.
RUN git config --global http.postBuffer 524288000

SHELL ["/bin/bash", "-c"]
COPY configs/*conf /etc/asterisk/
# asound.conf DOIT AUSSI ETRE A LA RACINE. Le COPY ci-dessus le depose dans
# /etc/asterisk/ - ALSA ne regarde jamais la : il lit /etc/asound.conf (ou
# ~/.asoundrc). Sans ce second exemplaire, `aplay -D gsm_out` repond
#     ALSA lib pcm.c: (snd_pcm_open_noupdate) Unknown PCM gsm_out
# et le mobile du conteneur est MUET, sans qu aucun log ne parle d audio.
# start.sh l.469 monte bien celui de l hote (-v ...:/etc/asound.conf), mais un
# conteneur lance autrement - docker run a la main, diagnostic - n a rien.
COPY configs/asound.conf /etc/asound.conf

WORKDIR ${ROOT}

# 2. Création de l'utilisateur osmocom
RUN groupadd osmocom && useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom && \
    mkdir -p /var/lib/osmocom && chown osmocom:osmocom /var/lib/osmocom

# 3. Compilation de la pile Osmocom (Ordre respecté)
RUN for repo in \
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

# ── Patch osmo-trx IPC : alignement ts_initial sur la trame TDMA (fix RACH/LU) ──
# Le device IPC (calypso-ipc-device) commit des buffers RX a des timestamps
# multiples de 2500 (CALYPSO_SHM_BUFSIZE) ; sans arrondi, ts_initial%5000 valait
# 0 ou 2500 -> device-TN0 mappe sur osmo-TN4 -> la RACH (UL) ratait le slot
# TS0/RACH -> NOPE/-110 -> Location Update bloquee. Le patch arrondit ts_initial
# a la frontiere de trame (8*625=5000 @ 4 SPS). Patch maintenu dans patches/.
# ── Patch osmo-trx RACH UL : table de modulation per-RA (fix LU, no-hardcode) ──
# La vraie RA du mobile (d_rach@0x0474, plombee via /dev/shm/calypso_rach par QEMU)
# varie a chaque burst ; le device rejouait un RA=3 fixe -> request-reference de
# l'IMM ASSIGN jamais matchee -> LU en boucle. sigProcLib pre-genere la modulation
# Laurent EXACTE d'osmo-trx pour chaque RA 0x00..0x0f (-> /root/rach_ref_RA<nn>.cs16),
# le device selectionne le ref de la VRAIE RA. Ajoute aussi les logs RACH-DET
# (Transceiver.cpp) + le lien libosmocoding dans COMMON_LDADD (Makefile.am, requis
# pour gsm0503_rach_ext_encode). Touche Makefile.am -> autoreconf+configure requis.
COPY patches/osmo-trx-ipc-ts-frame-align.patch /tmp/osmo-trx-ipc-ts-frame-align.patch
COPY patches/osmo-trx-rach-per-ra-table.patch /tmp/osmo-trx-rach-per-ra-table.patch
# Meme nom de paquet que dans la boucle (osmo-trx), version 1.7.2+ipc : dpkg
# fait une mise a jour, les fichiers sont les memes. Si la boucle est sortie du
# cache, l arbre source n existe pas : on le reclone avant d appliquer les patchs.
RUN if ! osmo-deb install osmo-trx 1.7.2+ipc; then \
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

# ── Patch gapk : sonde sur la sortie ALSA (GAPK_ALSA_PROBE) ──────────────────
# Diagnostic pur, inerte tant que GAPK_ALSA_PROBE != 1. Tranche une question que
# rien d'autre ne permet de trancher : quand l'ecouteur du MS est muet, le PCM
# remis a snd_pcm_writei est-il deja nul (defaut en amont, dans la chaine gapk)
# ou non nul (defaut en aval, ALSA/PulseAudio) ? osmo_gapk_pq_execute ne
# journalise rien ici, car il ne se plaint que d'un retour negatif et
# pq_cb_alsa_output rend « succes » meme pour une ecriture vide.
# Patch maintenu dans patches/ (regenere si pq_alsa.c change).
#
# [2026-08-12] LE PATCH RESTE DANS LE DEPOT, LE BUILD NE L'APPLIQUE PLUS.
# Demande explicite : garder patches/gapk-pq-alsa-output-probe.patch versionne
# (il tranche encore la question amont/aval quand l'ecouteur est muet) mais ne
# plus le poser sur le gapk construit — un `git apply` dans le build casse
# l'image des que pq_alsa.c bouge en amont, et la sonde n'est plus la question
# du jour (descendant muet resolu par CALYPSO_PULSE_LATENCY_MSEC=80).
# POUR LE REMETTRE, deux gestes, dans cet ordre :
#   1. decommenter la ligne COPY ci-dessous ;
#   2. reinserer dans le RUN, entre le `git clone` et le `cd osmo-gapk` :
#        git -C ${ROOT}/osmo-gapk apply /tmp/gapk-pq-alsa-output-probe.patch && \
#      (elle ne peut pas rester en commentaire : une ligne `#` au milieu d'une
#       continuation `\` couperait la chaine shell du RUN).
# Verifier d'abord que le patch s'applique toujours :
#   git -C <clone gapk> apply --check patches/gapk-pq-alsa-output-probe.patch
# POUR L'APPLIQUER A CHAUD SANS REBUILD : le poser dans le conteneur sur un
# clone de gapk, puis reconstruire gapk seul.
# COPY patches/gapk-pq-alsa-output-probe.patch /tmp/gapk-pq-alsa-output-probe.patch
RUN if ! osmo-deb install osmo-gapk 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk && \
      cd osmo-gapk && \
      autoreconf -fi && \
      ./configure --enable-alsa && \
      make -j$(nproc) && \
      osmo-deb pack osmo-gapk 0.git make install && \
      ldconfig; \
    fi

    
# ── Calypso build ─────────────────────────────

# ── Patch osmocon : filtre Kc — RETIRE le 2026-08-30 ─────────────────────────
# Ce patch faisait ecrire /dev/shm/calypso_kc a osmocon, en espionnant
# L1CTL_CRYPTO_REQ au passage sur le lien serie. Il etait la SEULE source du Kc
# a l'epoque ; il ne l'est plus, et il faisait desormais plus de mal que de bien.
#
# POURQUOI ON LE RETIRE. Un espion voit passer la cle, mais pas sa fin de vie :
# il doit la DEVINER. Le patch la devinait sur DM_EST_REQ et DM_REL_REQ, et
# remettait le fichier a 32 zeros. L'intention est juste pour le RELEASE, fausse
# pour l'ESTABLISH -- le mobile emet aussi un DM_EST_REQ pour ouvrir un lien
# SUPPLEMENTAIRE sur un canal DEJA chiffre (le SAPI 3 du SMS). La cle
# disparaissait donc en pleine session chiffree.
#
# Pire, il y avait TROIS ecrivains sur ce fichier (osmocon, l1ctl_sock.c, le
# shunt DSP) sans le moindre arbitrage : le dernier qui ecrit gagne, et c'est
# l'effaceur. Mesure du 30/08 : fichier a 32 zeros, « A5=non » sur tout le canal
# dedie, premier appel mort.
#
# CE QUI LE REMPLACE. calypso_dsp_shunt.c publie /dev/shm/calypso_kc_l1 depuis
# d_a5mode et a_kc du NDB -- ce que le FIRMWARE a reellement charge dans le DSP
# (calypso/dsp.c:dsp_load_ciph_param). Ce n'est plus un espion qui devine, c'est
# l'etat de la couche 1, remis a zero par le firmware lui-meme quand il repart
# en clair. Et le fichier lui est PROPRE : plus de course a l'ecriture.
#
# Le patch reste dans patches/ a titre documentaire, il n'est plus applique.
# L arbre ENTIER part dans le paquet (snapshot) : trx_toolkit, osmocon et les
# binaires host sont lus dans l arbre au runtime, pas seulement dans /usr/local.
RUN if ! osmo-deb install osmocom-bb 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
      cd osmocom-bb/src && \
      # Build complet : firmware (layer1.bin/.elf pour Calypso) + outils host
      # (mobile, trxcon, virtphy, ccch_scan). Le firmware est nécessaire pour
      # le mode PHY_MODE=qemu où QEMU émule un Calypso et exécute layer1.
      make nofirmware && \
      osmo-deb snapshot osmocom-bb 0.git ${ROOT}/osmocom-bb; \
    fi

# ── Note historique — patch fake_trx TRXD v0 (RETIRE) ────────────────────────
# Conserve verbatim : il documente une panne vecue. Il flottait dans
# Dockerfile.run juste au-dessus du bloc firmware, avec lequel il n'a AUCUN
# rapport — voisinage accidentel, pas lien de cause a effet.
# ── Patch fake_trx : forcer TRXD v0 ─────────────────────────────────────────
# osmo-bts-trx 1.10+ négocie TRXD v1 via SETFORMAT, mais trxcon (OsmocomBB)
# ne supporte que v0. Le header v1 a 2 octets de plus → décalage des soft-bits
# → BER constant 55/456 sur chaque frame → FBSB_SEARCH échoue en boucle.
# Fix : forcer ver_req=0 dans la réponse SETFORMAT → le BTS reste en v0.
# (patch TRXD v0 retire : burst_fwd.py:66 re-encode deja par interface,
#  trxcon recoit du v0 quoi qu'il arrive -> le forcage etait inutile)

# ── Firmware Calypso prebuild (layer1.highram.*) — ex-Dockerfile.run ─────────
# `make nofirmware` ci-dessus ne construit justement PAS le firmware : on prend
# les binaires prebuild de bbaranoff/firmware et on les depose la ou le mode
# PHY_MODE=qemu les cherche. ORDRE IMPOSE : ce bloc exige A LA FOIS ce clone ET
# l'arbre /opt/GSM/osmocom-bb ci-dessus — le placer plus haut ferait echouer les
# cp et PHY_MODE=qemu partirait sans layer1.
# (Le `rm -rf /opt/GSM/firmware` qui precedait le clone dans Dockerfile.run est
#  supprime : ici le chemin n'existe pas encore, l'instruction etait morte.)
# GIT_TERMINAL_PROMPT=0 : sans terminal (docker build), un clone qui demande un
# login doit echouer NET (message clair) au lieu d attendre un identifiant que
# personne ne tapera. --depth 1 : on ne veut que les binaires prebuild, pas
# l historique. (Le -c http.version=HTTP/1.1 qui etait ici est retire.)
RUN if ! osmo-deb install calypso-firmware 0.git; then \
      GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
        https://github.com/bbaranoff/firmware /opt/GSM/firmware \
      && osmo-deb snapshot calypso-firmware 0.git /opt/GSM/firmware; \
    fi
# [2026-08-28] Les trois `cp` vers /opt/GSM/osmocom-bb/src/target/firmware qui
# suivaient sont SUPPRIMES. Ils entretenaient un deuxieme exemplaire du firmware
# que plus personne ne lit : depuis la normalisation, environnement/paths.env du
# depot qemu ne connait qu'un chemin, $GSM_ROOT/firmware, et c'est celui que
# QEMU (-kernel .elf) comme osmocon (romload .bin) recoivent.
# Verifie sur le banc 192.168.1.7 : les deux exemplaires etaient bit a bit
# identiques (md5 3363105f...), et seul /opt/GSM/firmware etait charge.
# Si vous recompilez le firmware dans osmocom-bb, deposez le resultat dans
# /opt/GSM/firmware : c'est desormais le seul endroit consulte.

# ── gsup-smsc-proto : SMSC externe connecté à OsmoHLR via GSUP ────────────────
# Programmes : proto-smsc-daemon (réception MO SMS + relai MT via GSUP)
#              proto-smsc-sendmt (injection MT SMS via socket UNIX local)
# Dépendances build : libosmocore, libosmogsm, libosmo-gsup-client
# [2026-09-03] Son Makefile de tete lance `make DESTDIR= install` dans daemon/
# et sendmt/ - DESTDIR force a vide, le staging d osmo-deb restait vide ("rien
# n a ete installe dans DESTDIR") alors que la compilation (gcc courant) etait
# bonne. On installe donc les deux sous-repertoires nous-memes, avec le DESTDIR
# qu osmo-deb pose : leurs Makefiles, eux, l honorent.
RUN if ! osmo-deb install gsup-smsc-proto 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/themwi/gsup-smsc-proto && \
      cd gsup-smsc-proto && \
      ./configure --with-osmo=/usr/local && \
      make -j$(nproc) && \
      osmo-deb pack gsup-smsc-proto 0.git \
        sh -c 'for i in daemon sendmt; do make -C "$i" DESTDIR="$DESTDIR" install || exit 1; done' && \
      ldconfig; \
    fi

# ── sms-coding-utils : encodage/décodage SMS PDU (GSM 03.40) ──────────────────
# sms-encode-text, gen-sms-deliver-pdu, sms-pdu-decode, etc.
# Son Makefile de tete pose `DESTDIR=` (vide) et le repasse aux sous-repertoires :
# une variable donnee SUR LA LIGNE DE COMMANDE de make l emporte et descend
# avec, d ou `make install DESTDIR=...` explicite (l ancien INSTDIR=... n existait
# dans aucun de ses Makefiles). bindir vaut /usr/local/bin par configure.
RUN if ! osmo-deb install sms-coding-utils 0.r1; then \
      cd ${ROOT} && \
      wget -q https://www.freecalypso.org/pub/GSM/FreeCalypso/sms-coding-utils-latest.tar.bz2 && \
      tar xf sms-coding-utils-latest.tar.bz2 && \
      cd sms-coding-utils-r1 && \
      ./configure && \
      make -j$(nproc) && \
      osmo-deb pack sms-coding-utils 0.r1 \
        sh -c 'mkdir -p "$DESTDIR/usr/local/bin" && make install DESTDIR="$DESTDIR"'; \
    fi

# 4. Installation des fichiers du projet
WORKDIR /etc/osmocom
COPY scripts/. /etc/osmocom/
COPY configs/*cfg /etc/osmocom/
RUN mv /etc/osmocom/run.sh /root/run.sh
# Copie des binaires vers /usr/bin pour systemd et installation des .service
# (La `COPY scripts/gapk-start.sh /etc/osmocom/gapk-start.sh` qui etait ici est
#  supprimee : `COPY scripts/. /etc/osmocom/` ci-dessus depose deja le fichier.
#  Le RUN ci-dessous reste : le symlink et /var/lib/gapk sont uniques.)
RUN chmod +x /etc/osmocom/gapk-start.sh && \
    ln -sf /etc/osmocom/gapk-start.sh /usr/local/bin/gapk-start.sh && \
    mkdir -p /var/lib/gapk

RUN cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    cp -f /usr/local/bin/proto-smsc-* /usr/bin/ || true && \
    cp -f /usr/local/bin/sms-* /usr/bin/ || true && \
    cp -f /usr/local/bin/gen-sms-* /usr/bin/ || true && \
    # Si tu as des fichiers .service dans configs/
    cp /etc/osmocom/configs/*.service /lib/systemd/system/ 2>/dev/null || true

# ── Vérification binaires proto-SMSC ──────────────────────────────────────────
# Ex-Dockerfile.run. Premier point du build ou les deux chemins testes sont
# peuples (produits par gsup-smsc-proto, recopies dans /usr/bin juste au-dessus).
RUN which proto-smsc-daemon && which proto-smsc-sendmt && \
    echo "proto-smsc binaries OK" || \
    echo "WARNING: proto-smsc binaries not found in PATH"

# 5. Fix Permissions & Systemd (Status 214/217)
RUN sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service && \
    chmod +x /etc/osmocom/*.sh

# Activation du service et nettoyage
# Les unites systemd vivent dans services/ ; elles doivent atterrir dans
# /etc/systemd/system/, seul repertoire ou systemd les cherche.
COPY services/osmo-bts-trx.service /etc/systemd/system/osmo-bts-trx.service
RUN systemctl enable osmo-bts-trx.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Binaires cote hote produits par osmocom-bb, deposes en une seule couche.
# `install -m755` plutot que `cp` : les droits sont explicites, pas herites.
RUN mkdir -p /root/.osmocom/bb/ \
    && install -m755 ${ROOT}/osmocom-bb/src/host/trxcon/src/trxcon           /usr/local/bin/trxcon \
    && install -m755 ${ROOT}/osmocom-bb/src/host/layer23/src/mobile/mobile   /usr/local/bin/mobile \
    && install -m755 ${ROOT}/osmocom-bb/src/host/virt_phy/src/virtphy        /usr/local/bin/virtphy
# ccch_scan n'est plus installe ici : la branche fixeria/burst_ind, en fin de
# fichier, ecrase de toute facon /usr/local/bin/ccch_scan par SA version (cp sans
# `|| true`, donc obligatoire). Le binaire de master ne survivait jamais — c'est
# la version burst_ind qui fait foi.

# Confort du shell interactif. Pas de `source` ici : chaque RUN est un shell neuf,
# ce serait sans effet — le fichier est lu a l'ouverture d'une session.
RUN echo "alias faketrx='python3 ${ROOT}/osmocom-bb/src/target/trx_toolkit/fake_trx.py'" >> ~/.bashrc
# Prompt : root(rouge)@(bleu)<nom-container=\h>(jaune)☎️<dossier courant>(vert)#
# \h = nom du container grâce à `docker run --hostname "$container_name"` (start.sh).
# [refactor] LE PS1 ETAIT DEFINI DEUX FOIS, avec deux formats DIFFERENTS : ici
# et dans Dockerfile.run. Bash lit ~/.bashrc de haut en bas -> c'est celui de
# Dockerfile.run qui gagnait, et le prompt reellement affiche etait
# `user@host:cwd☎️#`, pas celui decrit deux lignes plus haut. On ne garde QUE le
# gagnant, a l'identique, pour ne rien changer au prompt visible ; l'explication
# du `\h` ci-dessus reste vraie pour les deux formats.
# ── Prompt interactif (root rouge / hostname bleu / cwd vert / ☎️#) ───────────
RUN printf '%s\n' '' \
    '### calypso-prompt ###' \
    "export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️# '" \
    '### end calypso-prompt ###' >> /root/.bashrc
COPY configs/mobile.cfg /root/.osmocom/bb/mobile.cfg
RUN chmod +x /root/run.sh

# Répertoires pour le proto-SMSC + arborescence Asterisk (ex-Dockerfile.run,
# ou ce mkdir faisait doublon avec celui-ci ; seul le chmod 755 etait unique).
# Position : apres l'installation d'asterisk (liste apt) et apres WORKDIR /etc/osmocom.
RUN mkdir -p /var/log/osmocom /var/run/smsc \
        /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk \
        /root/.osmocom/bb && \
    chmod 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk \
        /var/run/asterisk /var/log/osmocom

# ── PulseAudio system-mode : config bakée au build ────────────────────────────
# (ex-Dockerfile.run — depend du paquet pulseaudio de la liste apt en tete ;
#  place ici, tard, pour ne pas invalider le cache des ~200 lignes de compilation.)
# Cause racine du warning "[audio] PulseAudio injoignable — audio dégradé" :
# le démon system-mode lancé au runtime tournait SANS auth-anonymous (le patch
# de start-direct.sh arrivait après son démarrage) → 'pactl' renvoyait
# "Access denied", et un 2e démon ne pouvait pas démarrer ("Daemon already
# running"). On bake ici la config pour que TOUT démon soit joignable dès son
# lancement : socket anonyme + null-sinks gsm_audio/gsm_mic + root dans
# pulse-access.
#
# [2026-08-12] gsm_mic AJOUTÉ ICI. Il n'était créé que par
# scripts/pulse-gsm-setup.sh, appelé tard dans run.sh (après osmo-start.sh) :
# un HLR qui rate coupe run.sh (set -e) et le sink n'existe jamais. Or
# configs/asound.conf fait pointer la CAPTURE gsm_in sur gsm_mic.monitor, et
# gapk_io abandonne lecture ET capture si la capture échoue → appel muet des
# deux côtés. Les deux sinks doivent naître avec le démon, pas avec un script.
RUN set -eux; \
    usermod -aG pulse-access root 2>/dev/null || true; \
    test -f /etc/pulse/system.pa; \
    sed -i 's|^#\?load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' /etc/pulse/system.pa; \
    grep -q 'auth-anonymous=1' /etc/pulse/system.pa \
      || echo 'load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native' >> /etc/pulse/system.pa; \
    grep -q 'sink_name=gsm_audio' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=gsm_audio format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Audio' >> /etc/pulse/system.pa; \
    grep -q 'sink_name=gsm_mic' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=gsm_mic format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Mic' >> /etc/pulse/system.pa; \
    sed -i 's|^load-module module-suspend-on-idle|#load-module module-suspend-on-idle|' /etc/pulse/system.pa; \
    mkdir -p /var/run/pulse && chown -R pulse:pulse /var/run/pulse

# ─────────────────────────────────────────────────────────────────────────────
# QEMU Calypso — RAN virtuel (baseband émulé)
# ─────────────────────────────────────────────────────────────────────────────
# Architecture :
#   - QEMU émule un SoC Calypso (ARM7TDMI + DSP TMS320C54x)
#   - L'ARM exécute le vrai firmware osmocom-bb layer1.highram.elf
#   - Le DSP charge le ROM réel (calypso_dsp.txt) au boot
#   - bridge.py relaie les bursts entre osmo-bts-trx (UDP 5700-5702)
#     et la BSP du DSP (UDP 6702), avec QEMU comme maître d'horloge TDMA
#   - Le mobile (layer23) se connecte directement au socket L1CTL
#     publié par le firmware via la PTY série de QEMU
#
# Voir scripts/run.sh PHY_MODE=qemu pour l'orchestration runtime.
# ─────────────────────────────────────────────────────────────────────────────

# (Le `apt-get install python3-venv python3-pip python3-numpy python3-scipy
#  libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build` qui etait ici
#  a ete fusionne dans la liste apt-fast en tete de fichier : une seule liste,
#  un seul endroit ou la faire evoluer. Aucun paquet perdu.)

# Build QEMU fork bbaranoff/qosmo-grgsm (cible arm-softmmu, machine "calypso")
# Snapshot de l arbre ENTIER, build/ compris : Dockerfile.run y refait `ninja`
# apres son git pull, et QEMU lit build/qemu-bundle pour se relocaliser (voir
# Dockerfile.lite). C est le plus gros paquet du cache (~1,5 Go d objets, bien
# moins une fois en zstd) - et c est aussi la compilation la plus longue.
RUN if ! osmo-deb install qosmo-grgsm 0.git; then \
      cd /opt/GSM \
      && git clone https://github.com/bbaranoff/qosmo-grgsm /opt/GSM/qosmo-grgsm \
      && cd /opt/GSM/qosmo-grgsm \
      && python3 -m venv /root/.venv-qemu \
      && . /root/.venv-qemu/bin/activate \
      && pip install --no-cache-dir tomli \
      && mkdir build && cd build \
      && ../configure --target-list=arm-softmmu --prefix=/opt/GSM/qemu-install --disable-werror \
      && make -j$(nproc) \
      && make install \
      && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm \
      && osmo-deb snapshot qosmo-grgsm 0.git /opt/GSM/qosmo-grgsm /opt/GSM/qemu-install \
             /root/.venv-qemu /usr/local/bin/qemu-system-arm; \
    fi

# Layout stable attendu par scripts/run.sh : /opt/GSM/qemu/{build,bridge.py,sercomm_udp.py,...}
RUN mkdir -p /opt/GSM/qemu/build \
    && cp /opt/GSM/qosmo-grgsm/*.py /opt/GSM/qemu/ 2>/dev/null || true \
    && ln -sf /usr/local/bin/qemu-system-arm /opt/GSM/qemu/build/qemu-system-arm \
    && ln -sf /opt/GSM/qosmo-grgsm/calypso_dsp.txt /opt/GSM/calypso_dsp.txt

# [2026-08-30] ETAPE SUPPRIMEE — « ROM DSP binaire, derivee du .txt ».
#   RUN python3 /opt/GSM/qosmo-grgsm/tools/dsp_txt2bin.py \
#       /opt/GSM/qosmo-grgsm/calypso_dsp.txt /opt/GSM/calypso_dsp
# L'amont bbaranoff/qosmo-grgsm a fusionne la PR #1 « sans-dsp » (merge a547b01),
# qui SUPPRIME tools/dsp_txt2bin.py — le seul generateur des sept
# calypso_dsp.{PROM0..3,DROM,PDROM,Registers}.bin. Le build mourait donc a cette
# etape sur « can't open file ... [Errno 2] », apres ~40 etapes.
# Rien dans ce depot ne consomme /opt/GSM/calypso_dsp (le binaire produit ici) :
# le runtime lit les DSP_PROM* de environnement/paths.env, et les gardes qui les
# exigeaient ont ete levees (run.sh --check-paths, run_modules/00-prereqs.sh,
# run_modules/40-qemu.sh, start-direct.sh). Le .txt reste symlinke juste au-dessus
# pour les outils d'analyse (tools/tic54x-dis.py, tests/test_calypso_milestones.py).

# Build le DEVICE IPC calypso-ipc-device (tools/) — le Dockerfile ne le buildait
# PAS → binaire potentiellement absent/périmé au runtime. CRITIQUE : le 4 SPS
# dépend de info_cnf compilé avec CALYPSO_TRX_OSR=4 (sinon il s'annonce 1 SPS →
# osmo-trx alloue buffer_size=1250 → troncature → OML BTS meurt → pas de camping).
# NON BLOQUANT pour la meme raison que la ROM DSP ci-dessus : si l'amont ne
# fournit pas le repertoire, on log et on continue au lieu de casser le build.
RUN if [ -d /opt/GSM/qosmo-grgsm/tools/calypso-ipc-device ]; then \
        cd /opt/GSM/qosmo-grgsm/tools/calypso-ipc-device \
        && make clean && make -j"$(nproc)"; \
    else \
        echo "[skip] calypso-ipc-device absent de qosmo-grgsm/tools"; \
    fi

# ─────────────────────────────────────────────────────────────────────────────
# qosmo-dsp — le SECOND fork QEMU : le vrai DSP C54x emule (start-direct.sh --dsp)
# ─────────────────────────────────────────────────────────────────────────────
# [2026-09-03] Il manquait a l image : build-iso.sh le reprenait de l HOTE
# (/opt/GSM/qosmo-dsp) et start-direct.sh --dsp echouait sur toute machine ou il
# n avait pas ete clone a la main. Meme recette que qosmo-grgsm : clone, venv
# partage (/root/.venv-qemu, tomli pour meson), cible arm-softmmu, puis :
#   - les 7 ROM du DSP (calypso_dsp.{PROM0..3,DROM,PDROM,Registers}.bin) dans
#     /opt/GSM, decoupees depuis calypso_dsp.txt par tools/dsp_txt2bin.py -
#     c est la que environnement/paths.env (DSP_ROM_DIR) les cherche ;
#   - le device IPC de CE fork (tools/calypso-ipc-device), distinct de celui
#     de qosmo-grgsm.
# Le prefix d installation est propre au fork (/opt/GSM/qemu-dsp-install) : les
# deux QEMU ne se marchent pas dessus, le lanceur qosmo-dsp prend
# build/qemu-system-arm de son arbre. Non fatal si le depot n est pas
# joignable : l image reste utilisable, seul --dsp manque.
RUN if ! osmo-deb install qosmo-dsp 0.git; then \
      if git clone https://github.com/bbaranoff/qosmo-dsp /opt/GSM/qosmo-dsp; then \
        cd /opt/GSM/qosmo-dsp \
        && . /root/.venv-qemu/bin/activate \
        && mkdir -p build && cd build \
        && ../configure --target-list=arm-softmmu --prefix=/opt/GSM/qemu-dsp-install --disable-werror \
        && make -j$(nproc) \
        && make install \
        && cd /opt/GSM/qosmo-dsp \
        && for s in PROM0 PROM1 PROM2 PROM3 DROM PDROM Registers; do \
             python3 tools/dsp_txt2bin.py calypso_dsp.txt "/opt/GSM/calypso_dsp.$s.bin" --section "$s" || exit 1; \
           done \
        && { [ ! -d tools/calypso-ipc-device ] || { make -C tools/calypso-ipc-device clean && make -C tools/calypso-ipc-device -j"$(nproc)"; }; } \
        && osmo-deb snapshot qosmo-dsp 0.git /opt/GSM/qosmo-dsp /opt/GSM/qemu-dsp-install \
             /opt/GSM/calypso_dsp.PROM0.bin /opt/GSM/calypso_dsp.PROM1.bin /opt/GSM/calypso_dsp.PROM2.bin \
             /opt/GSM/calypso_dsp.PROM3.bin /opt/GSM/calypso_dsp.DROM.bin /opt/GSM/calypso_dsp.PDROM.bin \
             /opt/GSM/calypso_dsp.Registers.bin; \
      else \
        echo "[warn] qosmo-dsp non clonable - l image n aura pas le mode --dsp"; \
      fi; \
    fi

# ── gr-gsm : GNU Radio 3.10 + gr-osmosdr + gr-gsm dans le venv /root/.env ────
# (= moteur de démod du SI réel utilisé par si_bridge.py / grgsm_decode).
# Les deps GNU Radio (apt build-dep) sont posees par l unique bloc apt en tete
# de fichier, deb-src compris : plus aucun apt ici.

# ── GNU Radio + gr-osmosdr + gr-gsm, en UN paquet : le venv /root/.env ────────
# On TÉLÉCHARGE et on exécute CE script (le gist, pinné au commit fcdb409). Il
# cree /root/.env et y installe les trois. Puis :
#
# Patch gr-gsm : le receiver poste le BSIC/FN du SCH (decode_sch) sur le port
# `measurements` ET sur stdout ("SCHBSIC <bsic> <fn>"). Le shunt DSP le recoit
# (si_bridge.py parse le stdout de grgsm_decode -> UDP 4731 -> feed_sb) et encode
# le VRAI BSIC dans dispatch_sb (remplace SHUNT_CANNED_BSIC 63). Applique APRES le
# gist (qui clone+build gr-gsm propre), puis recompile/reinstalle dans le venv.
# Patch maintenu dans patches/ (regenere a chaque changement gr-gsm).
#
# matplotlib est consomme par tools/fft_global.sh et tools/matrix.sh.
#
# Le paquet du cache (grgsm-venv) est le venv COMPLET, patch et matplotlib
# compris : c est pour cela que les trois etapes tiennent dans un seul RUN. Les
# arbres /opt/GSM/{gnuradio,gr-osmosdr,gr-gsm} ne sont pas dans le paquet - rien
# ne les lit au runtime (le venv porte ses .so avec un RPATH sur /root/.env).
COPY patches/grgsm-receiver-publish-bsic-fn.patch /tmp/grgsm-receiver-publish-bsic-fn.patch
RUN if ! osmo-deb install grgsm-venv 0.git; then \
      curl -fsSL https://gist.githubusercontent.com/bbaranoff/3683811057933af0954b661821e950d1/raw/fcdb4092483ec383440b67fc002db0c158384bab/build.sh | bash \
      && git -C /opt/GSM/gr-gsm apply /tmp/grgsm-receiver-publish-bsic-fn.patch \
      && cd /opt/GSM/gr-gsm/build \
      && make -j"$(nproc)" \
      && make install \
      && . ~/.env/bin/activate && pip install matplotlib \
      && osmo-deb snapshot grgsm-venv 0.git /root/.env /etc/ld.so.conf.d/gnuradio.conf; \
    fi && ldconfig

# Dernier maillon de la chaine venv/gr-gsm (ex-Dockerfile.run) : le profil de
# root active le venv.
RUN echo 'source ~/.env/bin/activate' >> ~/.bashrc

# ── scripts bridge camping -> /opt/GSM (sinon /opt/GSM/qosmo-grgsm/run.sh casse) :
# si_bridge.py (full SI set -> 4730 -> shunt feed_si), si_bridge_loop.sh,
# record_drain.py (iq_record.fifo -> record.cfile), grgsm_fft_live.py.
COPY opt-gsm/. /opt/GSM/

# ── libosmo-dsp (dépendance transceiver/burst_ind) ──────────────────────────
RUN if ! osmo-deb install libosmo-dsp 0.git; then \
      cd /opt/GSM \
      && git clone https://gitea.osmocom.org/sdr/libosmo-dsp.git \
      && cd libosmo-dsp \
      && autoreconf -fi \
      && ./configure \
      && make -j$(nproc) \
      && osmo-deb pack libosmo-dsp 0.git make install \
      && ldconfig; \
    fi


# ── GCC 9 pour osmocom-bb branches expérimentales (jolly/testing, burst_ind) ─
# gcc-9 et gcc-11 sont installés avec le reste, plus haut : ici on ne fait que
# déclarer les alternatives, dont l'ordre compte pour osmocom-bb.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11

RUN update-alternatives --set gcc /usr/bin/gcc-9

# Chemin EXPLICITE. Sans lui, ce clone heritait du WORKDIR /etc/osmocom (pose
# beaucoup plus haut, jamais remis a ${ROOT}) et atterrissait dans
# /etc/osmocom/osmo-operator — masque au runtime par le montage de start.sh l.505,
# et surtout PAS la ou Dockerfile.run va faire son `git pull`. Deux arbres, deux
# HEAD, un seul utilise. /opt/GSM/osmo-operator est le chemin nominal, teste en
# premier par build-iso.sh l.964 et update.sh l.329.
# On reste sur la branche par defaut du depot (main) : pas de checkout explicite,
# donc pas de ref a maintenir ici, et HEAD est attache — ce dont le `git pull`
# de Dockerfile.run a besoin.
RUN git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator

# osmocom-bb jolly/testing → transceiver (BTS soft-SDR pour Calypso)
# Seul le binaire est mis en cache : l arbre ne sert qu a le produire.
RUN if ! osmo-deb install osmocom-bb-transceiver 0.git; then \
      git clone --branch jolly/testing --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-transceiver \
      && cd /opt/GSM/osmocom-bb-transceiver/src \
      && make HOST_layer23_CONFARGS=--enable-transceiver nofirmware -j$(nproc) \
      && cp /opt/GSM/osmocom-bb-transceiver/src/host/layer23/src/transceiver/transceiver \
         /usr/local/bin/transceiver \
      && osmo-deb snapshot osmocom-bb-transceiver 0.git /usr/local/bin/transceiver; \
    fi

# osmocom-bb fixeria/burst_ind → ccch_scan / bcch_scan / cell_log
RUN if ! osmo-deb install osmocom-bb-burst-ind 0.git; then \
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
      && osmo-deb snapshot osmocom-bb-burst-ind 0.git \
           $(ls /usr/local/bin/ccch_scan /usr/local/bin/bcch_scan /usr/local/bin/cell_log 2>/dev/null); \
    fi

RUN update-alternatives --set gcc /usr/bin/gcc-11

# ═════════════════════════════════════════════════════════════════════════════
# Node.js + dashboard web osmo-egprs-web (ex-Dockerfile.run, chaine complete)
# ═════════════════════════════════════════════════════════════════════════════
# Place EN FIN DE FICHIER a dessein : aucune etape du build ne depend de Node,
# et la fin de fichier preserve le cache des couches longues de compilation.
# L'ORDRE INTERNE DE CETTE CHAINE EST CONTRAINT — voir les ⚠️ ci-dessous.
# /opt/GSM et pas /opt : c'est /opt/GSM que l'ISO recupere en bloc
# (docker cp "$CID:/opt/GSM"). Le dashboard vivait a cote, dans /opt, et devait
# donc etre reclone une seconde fois a la construction de l'image - deux
# sources pour le meme depot, qui n'avancaient pas ensemble.
RUN if [ ! -d "/opt/GSM/osmo-egprs-web/" ]; then \
      mkdir -p /opt/GSM && \
      git clone -b main https://github.com/bbaranoff/osmo-egprs-web /opt/GSM/osmo-egprs-web; \
    fi

# ── Runtime Node.js + service web osmo-egprs-web ──────────────────────────────
# Le dashboard /opt/GSM/osmo-egprs-web/server.js tourne en mode NATIF (telnet VTY
# local, pas de docker) et est servi sur :8080. Le DÉMARRAGE est géré par
# start-direct.sh (`systemctl restart osmo-egprs-web`) — ici on ne fait
# qu'INSTALLER le runtime + les dépendances + le unit (enable au boot).
#
# Node 22 (LTS « Jod ») — même famille majeure que l'ISO, qui installe
# nodesource setup_22.x (build-iso.sh). Garder les deux alignés : le dashboard
# est le même server.js des deux côtés.
ARG NODE_VERSION=v22.23.2
RUN curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
        -o /tmp/node.tar.xz && \
    mkdir -p /opt/node && \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && \
    rm -f /tmp/node.tar.xz && \
    ln -sf /opt/node/bin/node /usr/local/bin/node && \
    ln -sf /opt/node/bin/npm  /usr/local/bin/npm && \
    ln -sf /opt/node/bin/npx  /usr/local/bin/npx && \
    node --version
# Unit systemd (fichier versionné dans le repo osmo-nitb-for-calypso, source unique).
# Le START reste géré par start-direct.sh (`systemctl restart osmo-egprs-web`).
COPY services/osmo-egprs-web.service /etc/systemd/system/osmo-egprs-web.service
RUN ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service

# ── Dashboard web : install-web-service.sh joue AU BOOT ───────────────────────
# [2026-08-12] Remplace le geste manuel `bash /opt/GSM/osmo-egprs-web/install-web-service.sh`
# qu'il fallait refaire dans chaque conteneur pour armer le HTTPS.
#
# Ce qui reste au BUILD : node et le unit du service (plus haut), le
# `npm install` (juste en dessous). Ce qui passe au BOOT : le certificat TLS
# auto-signe — une cle privee generee au build serait la meme pour tous ceux qui tirent l'image. Le detail
# du raisonnement est dans services/osmo-egprs-web-install.service.
#
# ⚠️ ORDRE : ce bloc DOIT rester APRES le clone de /opt/GSM/osmo-egprs-web
# (haut de cette section) — la COPY ci-dessous ecrit dans ce depot.
#
# SOURCE UNIQUE DU UNIT. install-web-service.sh installe le unit en le copiant
# depuis /opt/GSM/osmo-egprs-web/osmo-egprs-web.service — la copie du depot
# osmo-egprs-web, qui avait DIVERGE de celle-ci (elle avait perdu
# `CAP_IFACE=any`, donc la capture du dashboard). On ecrase donc cette copie par
# services/osmo-egprs-web.service : les deux emplacements servent desormais le
# meme fichier, et le script ne peut plus reintroduire la regression.
COPY services/osmo-egprs-web.service /opt/GSM/osmo-egprs-web/osmo-egprs-web.service
# Fail-fast : si l'amont retire le script, on le sait au build, pas au boot par
# un HTTPS muet.
RUN test -s /opt/GSM/osmo-egprs-web/install-web-service.sh
# Dependances JS (ws) — UN SEUL `npm install`, apres le clone.
# Non fatal (`|| true`) : node_modules est versionne dans le depot, un build
# hors-ligne reste valable. Mais la sortie est conservee, pas avalee.
RUN cd /opt/GSM/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund || true
# ── L INSTALLATION EST JOUEE ICI, AU BUILD ──────────────────────────────────
# [2026-08-31] On se contentait de VERIFIER que le script existe (le `test -s`
# ci-dessus) et on remettait tout au boot. L unite arrivait donc dans l image
# telle que le gabarit la portait, avec son ExecStart fige — et dans un
# conteneur, ou node vit en /usr/local/bin et non /usr/bin, systemd sortait en
#     status=203/EXEC
# en boucle, sans que rien ne parle d un chemin.
#
# Le script sait resoudre node et poser l unite avec le bon chemin : on le
# joue donc au build, pour que l image contienne une unite deja juste.
#
# `|| true` : dans un build il n y a PAS de systemd. Le script le sait et ne
# s arrete pas dessus (voir son en-tete), mais ses `systemctl` echouent
# forcement ; les avaler ici evite qu un detail d environnement fasse tomber
# une image de 11 Go. Ce qui compte - le unit, le certificat, le runtime - est
# ecrit avant ces appels.
#
# ⚠️ ET IL N Y A PLUS DE REJEU AU BOOT. osmo-egprs-web-install.service a ete
# retire des trois chemins de deploiement, pour une raison simple : ce script
# TELECHARGE node quand il manque. Le laisser au demarrage faisait dependre
# d Internet un banc concu pour tourner isole - et un premier boot hors ligne
# repartait sans dashboard. Tout est desormais fige dans l image ; le
# demarrage ne fait plus que lancer osmo-egprs-web.service.
RUN bash /opt/GSM/osmo-egprs-web/install-web-service.sh || true

# --- Metadonnees de l'image ---------------------------------------------------
# Regroupees a la fin : elles decrivent le conteneur qui tournera, pas une etape
# de construction. SIGRTMIN+3 est le signal d'arret propre de systemd.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
CMD ["/bin/bash"]
