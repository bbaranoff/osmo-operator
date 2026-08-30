# Dockerfile — IMAGE DE BASE osmocom-nitb (COUCHE STABLE)
# ─────────────────────────────────────────────────────────────────────────────
# Tout ce qui est LONG et rarement modifie vit ici : la TOTALITE des paquets apt
# (une seule liste, plus aucun apt dans Dockerfile.run), la pile Osmocom
# compilee depuis les sources, osmocom-bb + le firmware Calypso, QEMU et son
# device IPC, gr-gsm/GNU Radio, le runtime Node et le dashboard web, la config
# PulseAudio, les units systemd, les repertoires, le prompt.
# ~11 Go et ~40 min de build : on ne la rebatit que quand une dependance change.
#
# L'iteration quotidienne se fait dans Dockerfile.run, qui repart de cette image
# (`FROM osmocom-nitb`) et n'y rafraichit que les scripts, les configs, le pont
# et les arbres git qemu-src / osmo_egprs — en secondes, pas en 40 minutes.
#
# Cette image reste AUTONOME : elle a son propre ENTRYPOINT et start-nitb.sh la
# lance seule. Ne pas retirer ses COPY de configs/scripts sous pretexte que
# Dockerfile.run les refait : le recouvrement est voulu des deux cotes.
FROM ubuntu:22.04 AS osmocom-nitb

# ROOT : ou vivent les sources dans l'image. Chemin FIXE et assume — dans un
# conteneur, il n'y a rien a rendre portable.
ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM

ENV container=docker \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib

# ── apt-fast : les téléchargements apt en parallèle ─────────────────────────
# Cette image installe plusieurs centaines de paquets ; apt les récupère un par
# un, apt-fast les met en parallèle via aria2. Le gain porte sur le
# téléchargement, pas sur dpkg — l'installation reste séquentielle.
#
# Repli explicite : si le réseau ou GitHub manque à ce moment, on pose un
# apt-fast qui appelle apt-get. Le build continue, plus lentement, au lieu
# d'échouer sur un outil qui n'est qu'une optimisation.
RUN apt-get update && apt-get install -y --no-install-recommends \
        aria2 curl ca-certificates \
    && { curl -fsSL -o /usr/local/sbin/apt-fast \
            https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast \
         && curl -fsSL -o /etc/apt-fast.conf \
            https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast.conf ; } \
    || printf '#!/bin/sh\nexec apt-get "$@"\n' > /usr/local/sbin/apt-fast \
    && chmod +x /usr/local/sbin/apt-fast \
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
RUN apt-fast update && apt-fast install -y --no-install-recommends \
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
    libasound2-dev libasound2 alsa-utils \
    # libgsm — codec GSM-FR natif (accélère gapk en mode gsmfr)
    libgsm1-dev libgsm1 \
    iptables iproute2 asterisk ffmpeg \
    # Sync build-iso : psmisc (pkill/killall, cleanup) + pulseaudio (chaîne audio gapk/parec)
    psmisc pulseaudio pulseaudio-utils binutils-arm-none-eabi \
    # Toolchains alternatives : osmocom-bb jolly/testing et fixeria/burst_ind ne
    # compilent qu'avec gcc-9 ; gcc-11 reste le compilateur par defaut du reste.
    # (Ex-bloc apt dedie, supprime : les `update-alternatives` plus bas echouaient
    #  « alternative path /usr/bin/gcc-9 doesn't exist » sans ces paquets.)
    gcc-9 g++-9 gcc-11 g++-11 \
    # log4cpp : etait installe a part avec le build-dep gnuradio (gr-gsm).
    liblog4cpp5-dev \
    # QEMU Calypso (fork bbaranoff/qemu) : venv + numpy/scipy pour l'outillage
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
    tcpdump tshark libcap2-bin

# Capture non-root pour le dashboard et tcpdump. Position OBLIGATOIRE : dumpcap
# n'existe qu'une fois wireshark-common installe (tire par tshark, juste au-dessus).
RUN setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"

SHELL ["/bin/bash", "-c"]
COPY configs/*conf /etc/asterisk/

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
    if [ "$name" = "libosmocore" ]; then \
        GIT_URL="https://github.com/osmocom/$name"; \
    elif [[ "$name" =~ "libosmo" ]]; then \
        GIT_URL="https://gitea.osmocom.org/osmocom/$name"; \
    else \
        GIT_URL="https://gitea.osmocom.org/cellular-infrastructure/$name"; \
    fi && \
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
    make install && \
    ldconfig; \
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
RUN git -C ${ROOT}/osmo-trx apply /tmp/osmo-trx-ipc-ts-frame-align.patch \
    && git -C ${ROOT}/osmo-trx apply /tmp/osmo-trx-rach-per-ra-table.patch \
    && cd ${ROOT}/osmo-trx \
    && autoreconf -fi \
    && ./configure --with-ipc \
    && make -j$(nproc) \
    && make install \
    && ldconfig

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
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk && \
    cd osmo-gapk && \
    autoreconf -fi && \
    ./configure --enable-alsa && \
    make -j$(nproc) && \
    make install && \
    ldconfig

    
# ── Calypso build ─────────────────────────────

# ── Patch osmocon : filtre Kc (chiffrement A5/1) ──────────────────────────────
# osmocon capte L1CTL_CRYPTO_REQ (mobile->L1) et ecrit /dev/shm/calypso_kc =
# SEULE source du Kc pour le chiffrement : UL (qemu_wrap osmo_a5) + DL (si_bridge
# grgsm -k). Sans ce patch : pas de Kc -> aucun chiffrement. NE TOUCHE PAS au
# firmware. Patch maintenu dans patches/ (regenere si osmocon.c change).
COPY patches/osmocom-bb-osmocon-kc-filter.patch /tmp/osmocom-bb-osmocon-kc-filter.patch
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
    git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-osmocon-kc-filter.patch && \
    cd osmocom-bb/src && \
    # Build complet : firmware (layer1.bin/.elf pour Calypso) + outils host
    # (mobile, trxcon, virtphy, ccch_scan). Le firmware est nécessaire pour
    # le mode PHY_MODE=qemu où QEMU émule un Calypso et exécute layer1.
    make nofirmware

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
RUN git clone https://github.com/bbaranoff/firmware /opt/GSM/firmware
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
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/themwi/gsup-smsc-proto && \
    cd gsup-smsc-proto && \
    ./configure --with-osmo=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# ── sms-coding-utils : encodage/décodage SMS PDU (GSM 03.40) ──────────────────
# sms-encode-text, gen-sms-deliver-pdu, sms-pdu-decode, etc.
RUN cd ${ROOT} && \
    wget -q https://www.freecalypso.org/pub/GSM/FreeCalypso/sms-coding-utils-latest.tar.bz2 && \
    tar xf sms-coding-utils-latest.tar.bz2 && \
    cd sms-coding-utils-r1 && \
    ./configure && \
    make -j$(nproc) && \
    make install INSTDIR=/usr/local/bin

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

# Build QEMU fork bbaranoff/qemu (cible arm-softmmu, machine "calypso")
RUN cd /opt/GSM \
    && git clone https://github.com/bbaranoff/qemu.git /opt/GSM/qemu-src \
    && cd /opt/GSM/qemu-src \
    && git checkout RELEASE-0.1 \
    && python3 -m venv /root/.venv-qemu \
    && . /root/.venv-qemu/bin/activate \
    && pip install --no-cache-dir tomli \
    && mkdir build && cd build \
    && ../configure --target-list=arm-softmmu --prefix=/opt/GSM/qemu-install --disable-werror \
    && make -j$(nproc) \
    && make install \
    && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm

# Layout stable attendu par scripts/run.sh : /opt/GSM/qemu/{build,bridge.py,sercomm_udp.py,...}
RUN mkdir -p /opt/GSM/qemu/build \
    && cp /opt/GSM/qemu-src/*.py /opt/GSM/qemu/ 2>/dev/null || true \
    && ln -sf /usr/local/bin/qemu-system-arm /opt/GSM/qemu/build/qemu-system-arm \
    && ln -sf /opt/GSM/qemu-src/calypso_dsp.txt /opt/GSM/calypso_dsp.txt

# ROM DSP binaire, derivee du .txt symlinke juste au-dessus (ex-Dockerfile.run).
# Semantique inchangee : elle etait deja generee AVANT le `git pull` de qemu-src
# de l'image run. Pour un /opt/GSM/calypso_dsp a jour il faudrait la rejouer
# APRES ce pull — ce n'est pas l'objet de ce decoupage.
RUN python3 /opt/GSM/qemu-src/tools/dsp_txt2bin.py /opt/GSM/qemu-src/calypso_dsp.txt /opt/GSM/calypso_dsp

# Build le DEVICE IPC calypso-ipc-device (tools/) — le Dockerfile ne le buildait
# PAS → binaire potentiellement absent/périmé au runtime. CRITIQUE : le 4 SPS
# dépend de info_cnf compilé avec CALYPSO_TRX_OSR=4 (sinon il s'annonce 1 SPS →
# osmo-trx alloue buffer_size=1250 → troncature → OML BTS meurt → pas de camping).
RUN cd /opt/GSM/qemu-src/tools/calypso-ipc-device && make clean && make -j"$(nproc)"

# ── gr-gsm : GNU Radio 3.10 + gr-osmosdr + gr-gsm dans le venv /root/.env ────
# (= moteur de démod du SI réel utilisé par si_bridge.py / grgsm_decode).
# Deps GNU Radio via apt build-dep : on génère les lignes deb-src à partir des
# deb, avec TOUS les composants (main restricted universe multiverse — gnuradio
# est dans universe), pour chaque suite (jammy, -updates, -security, -backports).
RUN sed -nE 's|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p' \
        /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list \
    && apt-get update \
    && apt-get build-dep -y gnuradio \
    && rm -rf /var/lib/apt/lists/*

# On TÉLÉCHARGE et on exécute CE script (le gist, pinné au commit fcdb409).
RUN curl -fsSL https://gist.githubusercontent.com/bbaranoff/3683811057933af0954b661821e950d1/raw/fcdb4092483ec383440b67fc002db0c158384bab/build.sh | bash

# ── Patch gr-gsm : le receiver poste le BSIC/FN du SCH (decode_sch) sur le port
# `measurements` ET sur stdout ("SCHBSIC <bsic> <fn>"). Le shunt DSP le recoit
# (si_bridge.py parse le stdout de grgsm_decode -> UDP 4731 -> feed_sb) et encode
# le VRAI BSIC dans dispatch_sb (remplace SHUNT_CANNED_BSIC 63). Applique APRES le
# gist (qui clone+build gr-gsm propre), puis recompile/reinstalle dans le venv.
# Patch maintenu dans patches/ (regenere a chaque changement gr-gsm).
COPY patches/grgsm-receiver-publish-bsic-fn.patch /tmp/grgsm-receiver-publish-bsic-fn.patch
RUN git -C /opt/GSM/gr-gsm apply /tmp/grgsm-receiver-publish-bsic-fn.patch \
    && cd /opt/GSM/gr-gsm/build \
    && make -j"$(nproc)" \
    && make install

# Dernier maillon de la chaine venv/gr-gsm (ex-Dockerfile.run). Le venv ~/.env
# est cree par le gist ci-dessus : ces deux lignes ne peuvent pas remonter plus
# haut. matplotlib est consomme par tools/fft_global.sh et tools/matrix.sh.
RUN echo 'source ~/.env/bin/activate' >> ~/.bashrc
RUN . ~/.env/bin/activate && pip install matplotlib

# ── scripts bridge camping -> /opt/GSM (sinon /opt/GSM/qemu-src/run.sh casse) :
# si_bridge.py (full SI set -> 4730 -> shunt feed_si), si_bridge_loop.sh,
# record_drain.py (iq_record.fifo -> record.cfile), grgsm_fft_live.py.
COPY opt-gsm/. /opt/GSM/

# ── libosmo-dsp (dépendance transceiver/burst_ind) ──────────────────────────
RUN cd /opt/GSM \
    && git clone https://gitea.osmocom.org/sdr/libosmo-dsp.git \
    && cd libosmo-dsp \
    && autoreconf -fi \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && ldconfig

# ── si_bridge.py : la version qemu-src ecrase celle du depot ─────────────────
# Ex-Dockerfile.run. ⚠️ ORDRE CRITIQUE : ce `cp` DOIT rester APRES
# `COPY opt-gsm/. /opt/GSM/` ci-dessus. Place avant, c'est opt-gsm/si_bridge.py
# (version du depot) qui reprendrait le dessus et le demodulateur du SI reel
# changerait EN SILENCE — panne visible seulement par un camping qui ne se fait
# plus, sans message.
# Comportement identique a avant le decoupage : c'est la version qemu-src qui
# est en place dans l'image. Quelle copie fait foi (opt-gsm/si_bridge.py du
# depot ou qemu-src/opt-gsm-scripts/si_bridge.py) reste un arbitrage A TRANCHER
# — cf. start-nitb.sh l.7 : « 4 copies de si_bridge.py, toutes divergentes ».
RUN cp /opt/GSM/qemu-src/opt-gsm-scripts/si_bridge.py /opt/GSM/si_bridge.py

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
# /etc/osmocom/osmo_egprs — masque au runtime par le montage de start.sh l.505,
# et surtout PAS la ou Dockerfile.run va faire son `git pull`. Deux arbres, deux
# HEAD, un seul utilise. /opt/GSM/osmo_egprs est le chemin nominal, teste en
# premier par build-iso.sh l.964 et update.sh l.329.
# ⚠️ `git checkout RELEASE-0.1` TOUT COURT NE MARCHE PAS ICI : le depot porte
# AUSSI un tag nomme RELEASE-0.1 (457ff2e, la pointe de main). Git resout
# refs/tags/ AVANT le DWIM vers refs/remotes/origin/, donc on atterrissait sur
# le TAG en HEAD detache — pas sur la branche (2ca6e24) — et le `git pull` de
# Dockerfile.run l.125 mourait sur « You are not currently on a branch ».
# `-B <branche> origin/<branche>` est explicite : jamais ambigu, et pose le
# suivi amont dont le pull a besoin.
RUN git clone https://github.com/bbaranoff/osmo_egprs /opt/GSM/osmo_egprs && cd /opt/GSM/osmo_egprs && git checkout -B RELEASE-0.1 origin/RELEASE-0.1

# osmocom-bb jolly/testing → transceiver (BTS soft-SDR pour Calypso)
RUN git clone --branch jolly/testing --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-transceiver \
    && cd /opt/GSM/osmocom-bb-transceiver/src \
    && make HOST_layer23_CONFARGS=--enable-transceiver nofirmware -j$(nproc) \
    && cp /opt/GSM/osmocom-bb-transceiver/src/host/layer23/src/transceiver/transceiver \
       /usr/local/bin/transceiver

# osmocom-bb fixeria/burst_ind → ccch_scan / bcch_scan / cell_log
RUN git clone --branch fixeria/burst_ind --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-burst_ind \
    && cd /opt/GSM/osmocom-bb-burst_ind/src \
    && make nofirmware -j$(nproc) \
    && cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/ccch_scan \
       /usr/local/bin/ccch_scan \
    && cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/bcch_scan \
       /usr/local/bin/bcch_scan 2>/dev/null || true \
    && cp /opt/GSM/osmocom-bb-burst_ind/src/host/layer23/src/misc/cell_log \
       /usr/local/bin/cell_log 2>/dev/null || true

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
      git clone https://github.com/bbaranoff/osmo-egprs-web /opt/GSM/osmo-egprs-web; \
    fi
# Compatibilite : tout ce qui nomme encore l'ancien chemin le retrouve.
RUN ln -sfn /opt/GSM/osmo-egprs-web /opt/osmo-egprs-web

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
# Dépendances JS (ws) — node_modules est versionné dans le repo, on (re)installe
# pour garantir la cohérence ; non-fatal si déjà présent / réseau absent.
RUN cd /opt/GSM/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund || true
# Unit systemd (fichier versionné dans le repo osmo-nitb-for-calypso, source unique).
# Le START reste géré par start-direct.sh (`systemctl restart osmo-egprs-web`).
COPY services/osmo-egprs-web.service /etc/systemd/system/osmo-egprs-web.service
RUN ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service

RUN cd /opt/GSM/osmo-egprs-web && git pull

# ── Dashboard web : install-web-service.sh joue AU BOOT ───────────────────────
# [2026-08-12] Remplace le geste manuel `bash /opt/GSM/osmo-egprs-web/install-web-service.sh`
# qu'il fallait refaire dans chaque conteneur pour armer le HTTPS.
#
# Ce qui reste au BUILD (deja plus haut) : node, `npm install`, le unit du
# service. Ce qui passe au BOOT : le certificat TLS auto-signe — une cle privee
# generee au build serait la meme pour tous ceux qui tirent l'image. Le detail
# du raisonnement est dans services/osmo-egprs-web-install.service.
#
# ⚠️ ORDRE : ce bloc DOIT rester APRES le `RUN cd /opt/GSM/osmo-egprs-web && git pull`
# ci-dessus. La COPY ci-dessous modifie un fichier suivi par ce depot ; placee
# avant, le `git pull` echouerait (« local changes would be overwritten »).
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
# [2026-08-12] REJOUER L'INSTALL WEB APRES LE PULL.
# Le `npm install` plus haut (le premier des deux) tourne AVANT le `git pull` de
# /opt/GSM/osmo-egprs-web ci-dessus : si le
# pull rapatrie un package.json avec une dependance en plus, node_modules reste
# a l'etat d'avant et le dashboard tombe au demarrage sur un `Cannot find
# module` — au boot, dans le journal systemd, loin du build qui l'a cause. On
# rejoue donc les dependances APRES le pull.
# Non fatal (`|| true`) : node_modules est versionne dans le depot, un build
# hors-ligne reste valable. Mais la sortie est conservee, pas avalee.
RUN cd /opt/GSM/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund || true
# Le reste de install-web-service.sh (certificat TLS + unit + enable) est joue AU
# BOOT par osmo-egprs-web-install.service — cf. le commentaire de ce unit : ni
# les `systemctl` ni la generation d'une cle privee n'ont leur place au build.
COPY services/osmo-egprs-web-install.service /etc/systemd/system/osmo-egprs-web-install.service
RUN ln -sf /etc/systemd/system/osmo-egprs-web-install.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web-install.service

# --- Metadonnees de l'image ---------------------------------------------------
# Regroupees a la fin : elles decrivent le conteneur qui tournera, pas une etape
# de construction. SIGRTMIN+3 est le signal d'arret propre de systemd.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
CMD ["/bin/bash"]
