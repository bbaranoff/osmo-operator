# syntax=docker/dockerfile:1
# Dockerfile - osmocom-nitb base image (stable layer)
# ─────────────────────────────────────────────────────────────────────────────
# Everything long and rarely changed lives here: the full apt package list (one
# list, no apt in Dockerfile.run), the Osmocom stack built from source,
# osmocom-bb + the Calypso firmware, QEMU and its IPC device, gr-gsm/GNU Radio,
# the Node runtime and the web dashboard, the PulseAudio config, the systemd
# units, the directories and the prompt. Roughly 11 GB and 40 min to build;
# rebuilt only when a dependency changes.
#
# Base ubuntu:24.04 (noble): python 3.12, gcc 13 default, *t64-renamed libraries
# (libasound2t64, libgnutls30t64...). The ISO (build-iso.sh) starts from the
# SAME noble: /root/.env and the /usr/local .so files are copied as-is into the
# rootfs and must find the same glibc and python. Changing the base here changes
# it there too.
#
# .deb cache (packaging/osmo-deb.sh): each directory built below is emitted as a
# .deb in /var/cache/osmo-debs (COPY from .deb-cache/, which build.sh keeps in
# sync with /var/cache/osmo-debs on the host). On rebuild, `osmo-deb install`
# lays the package down and skips the clone + compilation; `osmo-deb pack` and
# `osmo-deb snapshot` build the package the first time. build.sh --no-cache sets
# OSMO_DEB_REFRESH=1: everything is recompiled and the cache rewritten. Sources
# stay in /opt/GSM: `osmo-deb pack` embeds the current tree (/opt/GSM/<name>,
# .git included) in the package, so a cache rebuild yields the same image with
# its source trees, not an image where only /usr/local survives.
#
# Daily iteration happens in Dockerfile.run, which starts from this image
# (`FROM osmocom-nitb`) and only refreshes the scripts, configs, bridge and the
# qosmo / osmo-operator git trees.
#
# This image is self-contained: it has its own ENTRYPOINT and start-nitb.sh runs
# it standalone. Do not remove its config/script COPYs because Dockerfile.run
# redoes them: the overlap is intentional on both sides.

# ─────────────────────────────────────────────────────────────────────────────
# The build is a graph, not a chain - BuildKit stages
# ─────────────────────────────────────────────────────────────────────────────
# Four of the five long compilations have no dependency between them (the
# Osmocom stack, QEMU/qosmo, the GNU Radio venv, the 4G srsRAN + Open5GS), so
# they build in parallel:
#
#                  base   (apt, apt-fast, osmo-deb, configs)
#                    |
#         +----------+--------+---------+
#         |          |        |         |
#     osmo-core    qemu      lte      node          <- in parallel
#         |          |
#    +----+-----+    |
#    |    |     |    |
#   bb  grgsm-  +----+
#    |  venv    |
#    |    |    l1     (bb: osmocom-bb — l1: c54x_exe + grgsm_exe)
#    |    |     |
#    +----+-----+
#         |
#     osmocom-nitb      (assembly: dpkg -i, then configs)
#           |
#         debs          (FROM scratch: the .deb cache for CI)
#
# What makes the split possible: packaging/osmo-deb.sh. Each block is emitted as
# a .deb that contains BOTH the installed files AND the /opt/GSM source tree
# (cmd_pack). A parallel stage therefore exports its .deb files, and the
# assembly lays them back with `dpkg -i`.
#
# Three stages are NOT parallel to osmo-core, by design - all three link to
# libosmocore one way or another:
#   - osmocom-bb : `make nofirmware` links mobile/trxcon to libosmocore;
#   - c54x_exe   : its Makefile runs `pkg-config --libs libosmocoding libosmocore`;
#   - gr-gsm     : its CMakeLists looks for libosmocore/libosmocoding/libosmogsm.
# They do run in parallel WITH EACH OTHER once osmo-core is finished.
#
# Invariant: --target osmocom-nitb (build.sh, compose.yaml) is MANDATORY, since
# `debs` is always the last stage of the file.
# ─────────────────────────────────────────────────────────────────────────────


FROM ubuntu:24.04 AS base

# ROOT: where the sources live in the image. Fixed path; nothing to make
# portable inside a container.
ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM

# OSMO_IMAGE=1 marks "image of this repo, its network is set up by
# start-docker.sh / compose": network/osmo-ip-plan.sh then touches no address.
# A plain ubuntu:24.04 container lacks it and addresses itself like a native.
ENV container=docker \
    OSMO_IMAGE=1 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    GIT_TERMINAL_PROMPT=0

# ── apt-fast: parallel apt downloads ─────────────────────────────────────────
# This image installs several hundred packages; apt fetches them one by one,
# apt-fast parallelises the downloads via aria2 (the gain is on the download,
# not on dpkg - installation stays sequential).
#
# One installer for all environments: packaging/apt-fast-install.sh (this image,
# Dockerfile.stp, the ISO chroot, the host via build.sh). It also writes
# /etc/apt/apt.conf.d/90osmo-operator with the shared download settings.
# Built-in fallback: without GitHub, apt-fast calls apt-get and the build
# continues, more slowly.
#
# Build apt cache: every apt step in this file mounts /var/cache/apt/archives as
# a BuildKit cache (id osmo-apt-archives, shared with Dockerfile.stp), so a
# rebuild re-downloads only what changed. apt-fast-install removes docker-clean
# and sets Keep-Downloaded-Packages, otherwise apt would delete freshly
# installed packages. Requires BuildKit (docker compose or docker-buildx, which
# build.sh installs); the legacy builder does not understand --mount.
COPY packaging/apt-fast-install.sh /usr/local/sbin/apt-fast-install
# Ubuntu mirror measured by build.sh (packaging/apt-mirror.sh): empty = the base
# image sources (archive.ubuntu.com), which may be unusably slow from the host
# without apt saying so.
ARG OSMO_UBUNTU_MIRROR=
ENV DEBIAN_FRONTEND=noninteractive

# 1. System dependencies - ALL of them here. One list, one place to evolve it;
#    the runtime image (Dockerfile.run) needs no apt.
#
# tshark pulls wireshark-common, which asks a debconf question (non-root
# capture) that would block a non-interactive build: answered in advance.
#
# External coupling: install_modules/10-deps.sh EXTRACTS this list from the
# Dockerfile (the list is authoritative here) and must accept both `apt-get` and
# `apt-fast`. Do not revert this list to apt-get to work around that extractor.
RUN echo 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections
# deb-src BEFORE the single `apt-fast update`: the gnuradio build-dep (gr-gsm,
# end of the block below) reads the Sources indexes. Noble writes its sources in
# deb822 (ubuntu.sources, "Types: deb"); the old /etc/apt/sources.list (jammy)
# is still handled in case the base changes (gnuradio is in universe: all
# components).
RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -nE 's|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p' \
            /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list; \
    fi
# THE apt step of this image: apt-fast-install, then the MongoDB repository (key
# in armored form: apt reads it through signed-by, no gpg needed), then ONE
# `apt-fast install` for the Osmocom stack AND the 4G stack (was osmo-lte-install
# --deps, in the lte and osmocom-nitb stages). curl comes from apt-fast-install.
RUN --mount=type=cache,id=osmo-apt-archives,target=/var/cache/apt/archives,sharing=locked \
    chmod 755 /usr/local/sbin/apt-fast-install && apt-fast-install \
    && curl -fsSL --retry 3 -o /usr/share/keyrings/mongodb-server-8.0.asc https://www.mongodb.org/static/pgp/server-8.0.asc \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.asc] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list \
    && apt-fast update && apt-fast install -y --no-install-recommends \
    # Build tools
    build-essential git gcc g++ make cmake autoconf automake libtool pkg-config wget curl \
    # Osmocom core & network dependencies
    libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev liburing-dev asterisk-moh* \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev sqlite3 libc-ares-dev libgnutls28-dev \
    # Audio, radio & SIP
    libortp-dev libfftw3-dev libusb-1.0-0-dev libsofia-sip-ua-dev libsofia-sip-ua-glib-dev \
    # Python & system tools
    python3 python3-dev python3-scapy ca-certificates tmux systemd systemd-sysv \
    # Debug: gdb-multiarch to attach to the QEMU gdb-stub (ARM Calypso)
    gdb-multiarch \
    # ALSA: required by osmo-gapk for hardware audio I/O
    # (libasound2t64: noble name for libasound2, time_t 64-bit transition)
    libasound2-dev libasound2t64 alsa-utils \
    # libgsm: native GSM-FR codec (speeds up gapk in gsmfr mode)
    libgsm1-dev libgsm1 \
    iptables iproute2 asterisk ffmpeg \
    # build-iso sync: psmisc (pkill/killall, cleanup) + pulseaudio (gapk/parec audio chain)
    psmisc pulseaudio pulseaudio-utils binutils-arm-none-eabi \
    # Alternative toolchains: osmocom-bb jolly/testing and fixeria/burst_ind only
    # compile with gcc-9; gcc-11 is the default compiler for the rest (gcc-13 is
    # noble's and builds the Osmocom stack at the top of this file). These
    # packages are required by the update-alternatives calls below.
    gcc-9 g++-9 gcc-11 g++-11 \
    # log4cpp: used by gnuradio (gr-gsm)
    liblog4cpp5-dev \
    # QEMU Calypso (bbaranoff/qosmO): venv + numpy/scipy for the DSP tooling,
    # glib/pixman/slirp for the arm-softmmu target, ninja for meson, socat for
    # the scripts/run.sh PTYs.
    python3-venv python3-pip python3-numpy python3-scipy \
    libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
    # Container operation tooling:
    #   telnet   -> VTY fallback (run_modules/21-abonnes-hlr.sh) + dashboard transport
    #   whiptail -> menus of tools/vty-menu.sh and start-docker.sh
    #   xz-utils -> `tar -xJf` of the Node 22 tarball (dashboard block, end of file)
    #   libasound2-plugins -> ALSA->PulseAudio plugin, REQUIRED by configs/asound.conf
    #        (`type pulse` on gsm_out, gsm_in AND pcm.!default): without it any
    #        ALSA open (gapk, mobile) fails and audio is dead on both sides
    #   tshark/tcpdump/libcap2-bin -> capture; libcap2-bin provides the setcap below
    telnet nano whiptail xz-utils libasound2-plugins \
    tcpdump tshark libcap2-bin \
    # 4G (srsRAN ZeroMQ + srsGUI, Open5GS, MongoDB): the list of
    # tools/osmo-lte-install.sh (lte_deps), now installed here. Non-4G packages
    # already above are not repeated.
    libzmq5 libzmq3-dev libboost-program-options-dev libmbedtls-dev libconfig++-dev \
    lksctp-tools qtbase5-dev libqt5opengl5-dev libqwt-qt5-dev libboost-system-dev \
    libboost-thread-dev libboost-test-dev libgcrypt20-dev libidn-dev libmongoc-dev \
    libbson-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev \
    libtins-dev meson flex bison libssl-dev \
    mongodb-org mongodb-mongosh mongodb-database-tools \
    # GNU Radio 3.10 deps (gr-gsm, venv /root/.env below): same apt resolution as
    # the rest, no second RUN apt. (The && closes the list for the
    # install_modules/10-deps.sh extractor.)
    && apt-fast build-dep -y gnuradio \
    && rm -rf /var/lib/apt/lists/*

# Non-root capture for the dashboard and tcpdump. Position is MANDATORY: dumpcap
# only exists once wireshark-common is installed (pulled by tshark, above).
RUN setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"
# mongod starts at boot (was enabled by lte_deps); non-fatal, as before.
RUN systemctl enable mongod >/dev/null 2>&1 || true

# ── The .deb cache: the tool, then the already-built packages ────────────────
# .deb-cache/ is the build-context mirror of /var/cache/osmo-debs on the host
# (build.sh copies it in before, and brings new packages back after). Empty on
# the first build: everything compiles and is cached. Populated afterwards: each
# step below lays down its package and compiles nothing.
# OSMO_DEB_REFRESH=1 (build.sh --no-cache): the cache is ignored and rewritten.
ARG OSMO_DEB_REFRESH=0
COPY packaging/osmo-deb.sh /usr/local/sbin/osmo-deb
COPY .deb-cache/ /var/cache/osmo-debs/
RUN chmod 755 /usr/local/sbin/osmo-deb && osmo-deb list || true

# git: large postBuffer for big clones. GIT_TERMINAL_PROMPT=0 (ENV, above)
# makes a clone that wants a login fail fast rather than hang with no terminal.
RUN git config --global http.postBuffer 524288000

SHELL ["/bin/bash", "-c"]
COPY configs/*conf /etc/asterisk/
# asound.conf must ALSO be at the root. The COPY above puts it in /etc/asterisk/,
# which ALSA never reads: ALSA reads /etc/asound.conf (or ~/.asoundrc). Without
# this second copy, `aplay -D gsm_out` returns "Unknown PCM gsm_out" and the
# container mobile is silent. start-docker.sh mounts the host copy
# (-v ...:/etc/asound.conf), but a container started otherwise (plain docker
# run, diagnostics) has none.
COPY configs/asound.conf /etc/asound.conf

WORKDIR ${ROOT}

# 2. Create the osmocom user
RUN groupadd osmocom && useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom && \
    mkdir -p /var/lib/osmocom && chown osmocom:osmocom /var/lib/osmocom

# ────────────────────────────────────────────────────────────────────────────
# STAGE osmo-core — the Osmocom stack: 17 repos, 4 patches, gapk, SMSC, libosmo-dsp
# ────────────────────────────────────────────────────────────────────────────
FROM base AS osmo-core
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# 3. Build the Osmocom stack (order matters)
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
    # Cached package first: if present, neither clone nor compile.
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
    # make install under DESTDIR -> .deb in the cache -> dpkg -i into the root
    osmo-deb pack "$name" "$version" make install && \
    ldconfig \
    || { echo "ECHEC build osmocom: $name"; exit 1; }; \
    done

# ── osmo-trx IPC patch: align ts_initial on the TDMA frame boundary ──────────
# The IPC device (calypso-ipc-device) commits RX buffers at timestamps that are
# multiples of 2500 (CALYPSO_SHM_BUFSIZE). The patch rounds ts_initial to the
# frame boundary (8*625=5000 @ 4 SPS) so device-TN0 maps to osmo-TN0 and the UL
# RACH hits the TS0/RACH slot. Maintained in patches/.
# ── osmo-trx RACH UL patch: per-RA modulation table ──────────────────────────
# The mobile's real RA (d_rach@0x0474, fed via /dev/shm/calypso_rach by QEMU)
# varies per burst. sigProcLib pre-generates osmo-trx's exact Laurent modulation
# for each RA 0x00..0x0f (-> /root/rach_ref_RA<nn>.cs16) and the device selects
# the reference for the real RA. Also adds the RACH-DET logs (Transceiver.cpp)
# and the libosmocoding link in COMMON_LDADD (Makefile.am, required for
# gsm0503_rach_ext_encode). Touches Makefile.am -> autoreconf+configure needed.
COPY patches/osmo-trx-ipc-ts-frame-align.patch /tmp/osmo-trx-ipc-ts-frame-align.patch
COPY patches/osmo-trx-rach-per-ra-table.patch /tmp/osmo-trx-rach-per-ra-table.patch
# Same package name as in the loop (osmo-trx), version 1.7.2+ipc: dpkg does an
# upgrade. If the loop was served from the cache the source tree does not exist,
# so it is re-cloned before applying the patches.
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

# ── osmo-bts RAND patch: pin the authentication challenge (lab only) ─────────
# In rsl_rx_rll() (src/common/rsl.c), rewrites the RAND of the AUTHENTICATION
# REQUEST frame when the RAND environment variable is set on the BTS process:
#     RAND unset   -> nothing touched (normal behaviour);
#     RAND=0       -> 16-byte zero RAND;
#     RAND=<hex>   -> up to 16 bytes read as hex, zero-padded.
# Touches only rsl.c (no Makefile.am), but autoreconf/configure is still run
# because a re-cloned tree has no ./configure. Same package name (osmo-bts),
# version 1.10.0+rand: dpkg upgrades. Maintained in patches/.
COPY patches/osmo-bts-force-rand-toy.patch /tmp/osmo-bts-force-rand-toy.patch
RUN if ! osmo-deb install osmo-bts 1.10.0+rand; then \
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

# ── osmo-hlr RAND patch: pin the auth-vector RAND (lab only) ─────────────────
# In auc.c/auc_compute_vectors(): when the RAND environment variable is set on
# the HLR process, the RAND drawn for each vector is forced to 16 zero bytes
# before osmo_auth_gen_vec2, so SRES and Kc are computed over RAND=0 (the HLR
# holds Ki). This keeps the HLR and MSC vectors consistent. RAND unset -> normal
# network. No Makefile.am touched; autoreconf/configure still run (re-cloned
# tree has no ./configure). Same package name (osmo-hlr), version 1.9.2+rand:
# dpkg upgrades. Maintained in patches/.
COPY patches/osmo-hlr-force-rand-toy.patch /tmp/osmo-hlr-force-rand-toy.patch
RUN if ! osmo-deb install osmo-hlr 1.9.2+rand; then \
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

# ── osmo-msc RAND patch: pin the authentication challenge (lab only) ─────────
# In gsm48_tx_mm_auth_req() (src/libmsc/gsm_04_08.c): when the RAND environment
# variable is set on the MSC process, the RAND of the downlink AUTH REQUEST is
# forced (16 zero bytes here; change the forced_rand[] initialiser for another
# value). RAND unset -> normal network behaviour. No Makefile.am touched;
# autoreconf/configure still run (re-cloned tree has no ./configure). Same
# package name (osmo-msc), version 1.15.0+rand: dpkg upgrades. Maintained in
# patches/.
COPY patches/osmo-msc-force-rand-toy.patch /tmp/osmo-msc-force-rand-toy.patch
RUN if ! osmo-deb install osmo-msc 1.15.0+rand; then \
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

# ── gapk: ALSA-output probe patch (GAPK_ALSA_PROBE), NOT applied by the build ─
# patches/gapk-pq-alsa-output-probe.patch is a diagnostic (inert unless
# GAPK_ALSA_PROBE=1) that tells whether a silent MS listener is caused upstream
# (PCM already zero in the gapk chain) or downstream (ALSA/PulseAudio). It is
# kept versioned in patches/ but not applied here, so an upstream change to
# pq_alsa.c cannot break the image.
# To re-enable: apply it after the `git clone`, before `cd osmo-gapk`, in the
# RUN below (it cannot stay as a `#` line inside the `\` continuation), i.e.
#   git -C ${ROOT}/osmo-gapk apply /tmp/gapk-pq-alsa-output-probe.patch && \
# and add back:
#   COPY patches/gapk-pq-alsa-output-probe.patch /tmp/gapk-pq-alsa-output-probe.patch
# Check first with: git -C <gapk clone> apply --check patches/gapk-pq-alsa-output-probe.patch
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

# ── gsup-smsc-proto: external SMSC connected to OsmoHLR over GSUP ─────────────
# Programs: proto-smsc-daemon (MO SMS reception + MT relay over GSUP)
#           proto-smsc-sendmt (MT SMS injection over a local UNIX socket)
# Build deps: libosmocore, libosmogsm, libosmo-gsup-client
# The top-level Makefile forces DESTDIR= empty, so the two sub-directories are
# installed here directly with the DESTDIR that osmo-deb sets (their own
# Makefiles honour it).
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

# ── sms-coding-utils: SMS PDU encode/decode (GSM 03.40) ──────────────────────
# sms-encode-text, gen-sms-deliver-pdu, sms-pdu-decode, etc.
# The top-level Makefile sets DESTDIR= empty and passes it to sub-directories; a
# variable given on make's COMMAND LINE wins and propagates, hence the explicit
# `make install DESTDIR=...`. bindir is /usr/local/bin per configure.
RUN if ! osmo-deb install sms-coding-utils 0.r1; then \
      cd ${ROOT} && \
      wget -q https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env/sms-coding-utils-latest.tar.bz2 && \
      tar xf sms-coding-utils-latest.tar.bz2 && \
      cd sms-coding-utils-r1 && \
      ./configure && \
      make -j$(nproc) && \
      osmo-deb pack sms-coding-utils 0.r1 \
        sh -c 'mkdir -p "$DESTDIR/usr/local/bin" && make install DESTDIR="$DESTDIR"'; \
    fi

# ── libosmo-dsp (transceiver/burst_ind dependency) ──────────────────────────
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

# ────────────────────────────────────────────────────────────────────────────
# STAGE bb — osmocom-bb, the Calypso firmware and the two gcc-9 branches
# ────────────────────────────────────────────────────────────────────────────
FROM osmo-core AS bb
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# ── Calypso build ─────────────────────────────
#
# Three patches are applied to osmocom-bb and the WHOLE tree is snapshotted into
# the package: trx_toolkit, osmocon and the host binaries are read from the tree
# at runtime, not only from /usr/local. The same three patches are also applied
# natively by install_modules/40-patches.sh.
#   - clck-gen-frame-tolerance: fake_trx's TDMA clock only resets for a delay
#     larger than one frame (4.615 ms), so sub-frame jitter no longer drops
#     speech frames.
#   - plmn-a6-reinsert: a SIM re-inserted without RPLMN (SAP reconnect) no
#     longer stays in A6 with an "unhandled" PLMN search.
#   - sim-plmn-from-bcd: PLMNsel / FPLMN read with osmo_plmn_to_bcd instead of
#     from_bcd.
# patches/osmocom-bb-osmocon-kc-filter.patch is kept for reference but not
# applied (the Kc comes from calypso_dsp_shunt.c via /dev/shm/calypso_kc_l1).
COPY patches/osmocom-bb-clck-gen-frame-tolerance.patch /tmp/osmocom-bb-clck-gen-frame-tolerance.patch
COPY patches/osmocom-bb-plmn-a6-reinsert.patch /tmp/osmocom-bb-plmn-a6-reinsert.patch
COPY patches/osmocom-bb-sim-plmn-from-bcd.patch /tmp/osmocom-bb-sim-plmn-from-bcd.patch
# OSMOCOM_BB_REF: osmocom-bb is PINNED. Upstream a0a315e2 "trxcon/trx_if: migrate
# to libosmo-trx" removed trxcon from `make nofirmware` and made it require
# libosmo-trx, so a clone of HEAD no longer produces src/host/trxcon/src/trxcon.
# eac4eed1 is the bench tree the three patches are made against.
ARG OSMOCOM_BB_REF=eac4eed1
RUN if ! osmo-deb install osmocom-bb 0.git; then \
      cd ${ROOT} && \
      git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
      git -C ${ROOT}/osmocom-bb checkout -q ${OSMOCOM_BB_REF} && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-clck-gen-frame-tolerance.patch && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-plmn-a6-reinsert.patch && \
      git -C ${ROOT}/osmocom-bb apply /tmp/osmocom-bb-sim-plmn-from-bcd.patch && \
      cd osmocom-bb/src && \
      # Full build: firmware (layer1.bin/.elf for Calypso) + host tools (mobile,
      # trxcon, virtphy, ccch_scan). The firmware is needed for PHY_MODE=qemu,
      # where QEMU emulates a Calypso and runs layer1.
      make nofirmware && \
      osmo-deb snapshot osmocom-bb 0.git ${ROOT}/osmocom-bb; \
    fi

# ── Firmware Calypso prebuild (layer1.highram.*) ─────────────────────────────
# `make nofirmware` above does NOT build the firmware: the prebuilt binaries
# from bbaranoff/firmware are fetched and placed where PHY_MODE=qemu looks for
# them. Order is fixed: this block needs BOTH this clone AND the /opt/GSM/
# osmocom-bb tree above. GIT_TERMINAL_PROMPT=0 makes a login-prompting clone
# fail fast with no terminal; --depth 1 fetches only the prebuilt binaries, not
# the history.
RUN if ! osmo-deb install calypso-firmware 0.git; then \
      GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
        https://github.com/bbaranoff/firmware /opt/GSM/firmware \
      && osmo-deb snapshot calypso-firmware 0.git /opt/GSM/firmware; \
    fi
# The single firmware copy lives in /opt/GSM/firmware: that is what both QEMU
# (-kernel .elf) and osmocon (romload .bin) are given (qemu paths.env knows only
# $GSM_ROOT/firmware). If you recompile the firmware in osmocom-bb, place the
# result in /opt/GSM/firmware.

# ── GCC 9 for the experimental osmocom-bb branches (jolly/testing, burst_ind) ─
# gcc-9 and gcc-11 are installed with the rest, above; here we only declare the
# alternatives, whose order matters for osmocom-bb.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11

RUN update-alternatives --set gcc /usr/bin/gcc-9

# osmocom-bb jolly/testing -> transceiver (soft-SDR BTS for Calypso)
# Both the binary AND the tree go into the package, so the sources survive a
# cache rebuild (see the .deb cache note in the header).
# patches/osmocom-bb-transceiver-qemu-bench.patch: the host `transceiver` app
# serves the emulated Calypso (start-native.sh --osmo-trx, c54x_exe/run.sh
# OSMO_TRX=1): --no-sync (BTS mode from reset, no cell to listen to), --ts-mask
# (single timeslot), --l1ctl/--base-port, and SETTSC/SETFORMAT/NOMTXPOWER
# acknowledged (osmo-bts-trx >= 1.3 treats them as critical). Also applied
# natively by install_modules/40-patches.sh.
COPY patches/osmocom-bb-transceiver-qemu-bench.patch /tmp/osmocom-bb-transceiver-qemu-bench.patch
RUN if ! osmo-deb install osmocom-bb-transceiver 0.git; then \
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

# osmocom-bb fixeria/burst_ind -> ccch_scan / bcch_scan / cell_log
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
      && osmo-deb snapshot osmocom-bb-burst-ind 0.git /opt/GSM/osmocom-bb-burst_ind \
           $(ls /usr/local/bin/ccch_scan /usr/local/bin/bcch_scan /usr/local/bin/cell_log 2>/dev/null); \
    fi

# Back to the default compiler: this stage only produces .deb files, but leaving
# it on gcc-9 would trap anyone deriving a step from it.
RUN update-alternatives --set gcc /usr/bin/gcc-11

# ────────────────────────────────────────────────────────────────────────────
# STAGE qemu — the single QEMU tree: /opt/GSM/qosmo (--enable-l1-grgsm)
# ────────────────────────────────────────────────────────────────────────────
FROM base AS qemu
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# ─────────────────────────────────────────────────────────────────────────────
# QEMU Calypso — virtual RAN (emulated baseband)
# ─────────────────────────────────────────────────────────────────────────────
# Architecture:
#   - QEMU emulates a Calypso SoC (ARM7TDMI + DSP TMS320C54x)
#   - the ARM runs the real osmocom-bb firmware layer1.highram.elf
#   - the DSP loads the real ROM (calypso_dsp.txt) at boot
#   - bridge.py relays bursts between osmo-bts-trx (UDP 5700-5702) and the DSP
#     BSP (UDP 6702), with QEMU as the TDMA clock master
#   - the mobile (layer23) connects directly to the L1CTL socket published by
#     the firmware via QEMU's serial PTY
#
# See scripts/run.sh PHY_MODE=qemu for the runtime orchestration.
# ─────────────────────────────────────────────────────────────────────────────
# qosmo + c54x_exe + grgsm_exe
# ─────────────────────────────────────────────────────────────────────────────
#   /opt/GSM/qosmo      single QEMU tree (bbaranoff/qosmO), --enable-l1-grgsm.
#                       Carries run.sh, run_modules, cfgs. The same binary serves
#                       the --dsp mode: CALYPSO_DSP_EXTERN=1 disables the gr-gsm
#                       L1 there. `ninja install` also installs the C launcher
#                       `qosmo`.
#   /opt/GSM/c54x_exe   the C54x OUTSIDE QEMU (TI mask-ROM, its ROM in rom/).
#                       Builds the /opt/GSM/qosmo sources: AFTER qosmo.
#   /opt/GSM/grgsm_exe  the gr-gsm layer 1 outside QEMU, same qosmo sources.
# The WHOLE qosmo tree is snapshotted, build/ included: QEMU_BIN points at
# $OQC_ROOT/build/qemu-system-arm, and QEMU reads build/qemu-bundle to relocate
# itself (see Dockerfile.lite).
RUN if ! osmo-deb install qosmo 0.git; then \
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

# ────────────────────────────────────────────────────────────────────────────
# STAGE l1 — the two layer-1 builds outside QEMU: c54x_exe and grgsm_exe
# ────────────────────────────────────────────────────────────────────────────
FROM qemu AS l1
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# These build the /opt/GSM/qosmo sources (already present, this stage derives
# from qemu) and link to libosmocoding/libosmocore for c54x_exe. /usr/local is
# pulled from osmo-core rather than deriving this stage from it: copying
# /usr/local (a few hundred MB) is far cheaper than copying QEMU's build tree
# (~1.5 GB of objects) the other way.
COPY --from=osmo-core /usr/local /usr/local
RUN ldconfig

# c54x_exe: its Makefile puts -march=native in CFLAGS, which would SIGILL at
# startup on a CPU other than the build host's. We keep its flags without that
# one. The ROM is also placed at /opt/GSM/calypso_dsp.*.bin, c54x_exe's default
# --rom-dir. The ROM is not in the c54x_exe repo: rom/fetch-rom.sh downloads the
# FreeCalypso 3606 dump, converts it to .bin and verifies SHA256SUMS.3606;
# calypso_dsp.txt (the raw dump) is downloaded separately.
# dsp-rom-3606-dump.txt comes from the fc-magnetite repo (freecalypso-env/).
ARG FREECALYPSO_URL=https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env
RUN if ! osmo-deb install c54x-exe 0.git; then \
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

RUN if ! osmo-deb install grgsm-exe 0.git; then \
      git clone https://github.com/bbaranoff/grgsm_exE /opt/GSM/grgsm_exe \
      && cd /opt/GSM/grgsm_exe \
      && make QOSMO=/opt/GSM/qosmo \
      && osmo-deb snapshot grgsm-exe 0.git /opt/GSM/grgsm_exe; \
    fi

# ────────────────────────────────────────────────────────────────────────────
# STAGE grgsm-venv — GNU Radio 3.10 + gr-osmosdr + gr-gsm in /root/.env
# ────────────────────────────────────────────────────────────────────────────
# gr-gsm links to libosmocore/libosmocoding/libosmogsm (its CMakeLists finds
# them via pkg-config), so this stage MUST start from osmo-core, not base. It
# stays parallel to `bb` and `l1`, which also derive from osmo-core.
FROM osmo-core AS grgsm-venv
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# ── gr-gsm: GNU Radio 3.10 + gr-osmosdr + gr-gsm in the venv /root/.env ──────
# (= the real-SI demod engine used by si_bridge.py / grgsm_decode).
# The GNU Radio deps (apt build-dep) are installed by the single apt block at
# the top of the file, deb-src included: no apt here.
#
# The build downloads and runs the gist (pinned to commit fcdb409), which
# creates /root/.env and installs the three. Then:
#
# gr-gsm patch: the receiver publishes the SCH BSIC/FN (decode_sch) on the
# `measurements` port AND on stdout ("SCHBSIC <bsic> <fn>"). The DSP shunt reads
# it (si_bridge.py parses grgsm_decode's stdout -> UDP 4731 -> feed_sb) and
# encodes the REAL BSIC in dispatch_sb. Applied AFTER the gist (which clones and
# builds gr-gsm), then rebuilt/reinstalled in the venv. Maintained in patches/.
#
# matplotlib is used by tools/fft_global.sh and tools/matrix.sh.
# numpy STAYS at 1.x: the gist pins "numpy<2" (GNU Radio 3.10 is built against
# it), but a bare `pip install matplotlib` would pull the latest
# matplotlib/contourpy, which require numpy>=2. The same-line constraint makes
# pip pick a numpy-1-compatible matplotlib. The cached package is 1.git (the
# 0.git one carried a numpy-2 venv).
#
# The cached package (grgsm-venv) is the COMPLETE venv, patch and matplotlib
# included: that is why the three steps fit in one RUN. The
# /opt/GSM/{gnuradio,gr-osmosdr,gr-gsm} trees are not in the package - nothing
# reads them at runtime (the venv carries its .so with an RPATH on /root/.env).
COPY patches/grgsm-receiver-publish-bsic-fn.patch /tmp/grgsm-receiver-publish-bsic-fn.patch
RUN if ! osmo-deb install grgsm-venv 1.git; then \
      curl -fsSL https://gist.githubusercontent.com/bbaranoff/3683811057933af0954b661821e950d1/raw/fcdb4092483ec383440b67fc002db0c158384bab/build.sh | bash \
      && git -C /opt/GSM/gr-gsm apply /tmp/grgsm-receiver-publish-bsic-fn.patch \
      && cd /opt/GSM/gr-gsm/build \
      && make -j"$(nproc)" \
      && make install \
      && . ~/.env/bin/activate && pip install matplotlib "numpy<2" \
      && osmo-deb snapshot grgsm-venv 1.git /root/.env /etc/ld.so.conf.d/gnuradio.conf; \
    fi && ldconfig

# ────────────────────────────────────────────────────────────────────────────
# STAGE node - Node 22 and the osmo-egprs-web dashboard
# ────────────────────────────────────────────────────────────────────────────
FROM base AS node
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# ═════════════════════════════════════════════════════════════════════════════
# Node.js + osmo-egprs-web dashboard
# ═════════════════════════════════════════════════════════════════════════════
# No other build step depends on Node. The order inside this chain is
# constrained (see the ORDER notes below).
# Cloned under /opt/GSM because the ISO copies /opt/GSM as a whole
# (docker cp "$CID:/opt/GSM").
RUN if [ ! -d "/opt/GSM/osmo-egprs-web/" ]; then \
      mkdir -p /opt/GSM && \
      git clone -b main https://github.com/bbaranoff/osmo-egprs-web /opt/GSM/osmo-egprs-web; \
    fi

# ── Node.js runtime + osmo-egprs-web web service ──────────────────────────────
# /opt/GSM/osmo-egprs-web/server.js runs in native mode (local telnet VTY, no
# docker) and serves :8080. Startup is handled by start-native.sh
# (`systemctl restart osmo-egprs-web`); this only installs the runtime, the
# dependencies and the unit (enabled at boot).
#
# Node 22 (LTS "Jod"): same major version as the ISO (nodesource setup_22.x in
# build-iso.sh). Keep both aligned: the dashboard is the same server.js.
ARG NODE_VERSION=v22.23.2
# The tarball follows the image architecture (x64 on amd64, arm64 for a
# --platform linux/arm64 build for the Raspberry Pi).
RUN case "$(uname -m)" in x86_64) _na=x64 ;; aarch64) _na=arm64 ;; *) echo "arch node inconnue: $(uname -m)" >&2; exit 1 ;; esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${_na}.tar.xz" \
        -o /tmp/node.tar.xz && \
    mkdir -p /opt/node && \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && \
    rm -f /tmp/node.tar.xz && \
    ln -sf /opt/node/bin/node /usr/local/bin/node && \
    ln -sf /opt/node/bin/npm  /usr/local/bin/npm && \
    ln -sf /opt/node/bin/npx  /usr/local/bin/npx && \
    node --version
# systemd unit (single source: services/ in this repo). Start is still done by
# start-native.sh (`systemctl restart osmo-egprs-web`).
COPY services/osmo-egprs-web.service /etc/systemd/system/osmo-egprs-web.service
RUN ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service

# ── Web dashboard: install-web-service.sh ─────────────────────────────────────
# ORDER: this block must stay AFTER the /opt/GSM/osmo-egprs-web clone (top of
# this section); the COPY below writes into that repository.
#
# Single source for the unit: install-web-service.sh installs the unit from
# /opt/GSM/osmo-egprs-web/osmo-egprs-web.service, so that copy is overwritten
# with services/osmo-egprs-web.service (which carries `CAP_IFACE=any`, needed
# for the dashboard capture).
COPY services/osmo-egprs-web.service /opt/GSM/osmo-egprs-web/osmo-egprs-web.service
# Fail fast at build time if upstream removes the script.
RUN test -s /opt/GSM/osmo-egprs-web/install-web-service.sh
# JS dependencies (ws): a single `npm install`, after the clone. Non-fatal
# (`|| true`): node_modules is versioned in the repo, so an offline build works.
RUN cd /opt/GSM/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund || true
# ── The installation runs here, at build time ──────────────────────────────
# The script resolves the node path (/usr/local/bin in the container) and
# writes the unit with the correct ExecStart, so the image ships a working unit.
#
# `|| true`: there is no systemd during a build, so the script's `systemctl`
# calls fail; the unit, certificate and runtime are written before them.
#
# Nothing is replayed at boot: the script downloads node when it is missing,
# and the bench must work offline. Boot only starts osmo-egprs-web.service.
RUN bash /opt/GSM/osmo-egprs-web/install-web-service.sh || true

# ────────────────────────────────────────────────────────────────────────────
# STAGE lte - the bench's 4G: srsRAN_4G (ZeroMQ) and Open5GS in /opt/LTE
# ────────────────────────────────────────────────────────────────────────────
FROM base AS lte
# ARG does not cross a FROM: stages that call osmo-deb or use ${ROOT} must
# redeclare them, otherwise ROOT is empty and OSMO_DEB_REFRESH=1
# (build.sh --no-cache) does not reach this far.
ARG ROOT=/opt/GSM
ARG OSMO_DEB_REFRESH=0

# osmo-lte-install --configs reads $OSMO_REPO, so this stage needs its own
# clone of the repo. The assembly stage makes its own clone, which is the one
# Dockerfile.run `git pull`s.
RUN git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator

# ── The bench's 4G: srsRAN_4G (ZeroMQ) and Open5GS, in /opt/LTE ─────────────
# Two paths to the same packages (see packaging/snapshot-lte-debs.sh): the .deb
# cache provides osmo-build-libzmq / osmo-build-srsran / osmo-build-open5gs to
# `osmo-deb install` below, and nothing is compiled. With an empty cache, they
# are built from source by the same script as the native install
# (tools/osmo-lte-install.sh --build, OSMO_DEB=1 -> osmo-deb pack).
# libzmq comes from Ubuntu (libzmq3-dev, installed by `--deps`).
# Open5GS prefix: /opt/LTE/open5gs/install (bin, etc/open5gs, var/log).
#
# Configs and launchers too (`--configs --launchers`, at the end of the RUN):
# the container runs as root and /root/.config/srsran is what srsenb/srsue
# read. The Open5GS .deb carries no yaml; the repo configs (from the
# /opt/GSM/osmo-operator clone above) are the only source. Subscribers
# (configs/open5gs/dump, subscribers.json) are not installed at build time:
# `osmo-epc start` restores them into MongoDB.
#
# The 4G packages (runtime AND build) are in the top apt step of this file: the
# .debs carry only the binaries, not their dependencies (libmbedtls, libzmq5,
# libconfig++, boost_program_options, mongodb-org), so they stay installed.
COPY tools/osmo-lte-install.sh /usr/local/sbin/osmo-lte-install
RUN --mount=type=cache,id=osmo-apt-archives,target=/var/cache/apt/archives,sharing=locked \
    chmod 755 /usr/local/sbin/osmo-lte-install && \
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

# ── Smartphone UI: patched pmbootstrap, in /opt/user_interface/pmos ─────────
# The bench phone is a postmarketOS VM launched by pmbootstrap, patched for the
# PCI serial modem, bench audio, screen size and port 5038 (not adb):
# patches/pmbootstrap-osmo-bench-qemu.patch. Clone + patch are packaged as
# osmo-build-pmbootstrap: the ISO (50-injection-image.sh) installs it as-is and
# tools/osmo-pmos-install.sh finds it in place. The PPP kernel is not built
# here (pmbootstrap needs non-root and loop mounts): it comes from
# osmo-build-pmos-kernel (packaging/build-pmos-kernel-deb.sh, or GitHub
# bbaranoff/pmos_ppp_kernel), installed by 88-lte-pmos.sh.
COPY patches/pmbootstrap-osmo-bench-qemu.patch /tmp/pmbootstrap-osmo-bench-qemu.patch
RUN if ! osmo-deb install pmbootstrap 0.git; then \
        mkdir -p /opt/user_interface/pmos && \
        git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git /opt/user_interface/pmos/pmbootstrap && \
        cd /opt/user_interface/pmos/pmbootstrap && \
        git apply /tmp/pmbootstrap-osmo-bench-qemu.patch && \
        grep -q osmo_bench_args pmb/commands/qemu.py && \
        osmo-deb snapshot pmbootstrap 0.git /opt/user_interface/pmos/pmbootstrap; \
    fi && test -f /opt/user_interface/pmos/pmbootstrap/pmbootstrap.py

# ============================================================================
# STAGE osmocom-nitb - assembly. This is the published image.
# ============================================================================
# Nothing is compiled here: the .debs produced by the stages are installed,
# then what no package carries is added (Node, the dashboard, the 4G, the repo,
# the build-context configs). build.sh (compose_build) and compose.yaml pass
# --target osmocom-nitb.
FROM base AS osmocom-nitb
ARG ROOT=/opt/GSM

# ── 1. Packages from all stages ─────────────────────────────────────────────
# bb derives from osmo-core and l1 from qemu: their caches already include
# their parent's.
COPY --from=bb         /var/cache/osmo-debs/ /var/cache/osmo-debs/
COPY --from=l1         /var/cache/osmo-debs/ /var/cache/osmo-debs/
COPY --from=grgsm-venv /var/cache/osmo-debs/ /var/cache/osmo-debs/
COPY --from=lte        /var/cache/osmo-debs/ /var/cache/osmo-debs/
# (No COPY from `node`: that stage never calls osmo-deb.)

# Install order matters for the four patched packages. osmo-trx, osmo-bts,
# osmo-hlr and osmo-msc exist in two versions with the same package name
# (e.g. osmo-trx 1.7.2 and 1.7.2+ipc). The glob installs in ASCII order, where
# "+" sorts before "~", so the unpatched one would win; the patched four are
# therefore reinstalled explicitly, last.
RUN set -eux; \
    dpkg -i --force-overwrite /var/cache/osmo-debs/osmo-build-*.deb; \
    dpkg -i --force-overwrite \
        /var/cache/osmo-debs/osmo-build-osmo-trx_1.7.2+ipc~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-bts_1.10.0+rand~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-hlr_1.9.2+rand~*.deb \
        /var/cache/osmo-debs/osmo-build-osmo-msc_1.15.0+rand~*.deb; \
    ldconfig

# ── 2. What no .deb carries ─────────────────────────────────────────────────
# Node (tarball in /opt/node) and the dashboard (git clone with node_modules);
# install-web-service.sh already ran in the node stage.
COPY --from=node /opt/node                                      /opt/node
COPY --from=node /opt/GSM/osmo-egprs-web                        /opt/GSM/osmo-egprs-web
COPY --from=node /etc/systemd/system/osmo-egprs-web.service     /etc/systemd/system/osmo-egprs-web.service
RUN ln -sf /opt/node/bin/node /usr/local/bin/node \
    && ln -sf /opt/node/bin/npm  /usr/local/bin/npm \
    && ln -sf /opt/node/bin/npx  /usr/local/bin/npx \
    && ln -sf /etc/systemd/system/osmo-egprs-web.service \
        /etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service \
    && node --version

# Explicit destination path: /opt/GSM/osmo-operator is the nominal location,
# used by Dockerfile.run (`git pull`), build-iso.sh and update.sh.
# Default branch (main), no explicit checkout: HEAD stays attached, as the
# `git pull` in Dockerfile.run requires.
RUN git clone https://github.com/bbaranoff/osmo-operator /opt/GSM/osmo-operator

COPY tools/osmo-lte-install.sh /usr/local/sbin/osmo-lte-install
RUN chmod 755 /usr/local/sbin/osmo-lte-install

# ── 4G ──────────────────────────────────────────────────────────────────────
# All of /opt/LTE, not only what the .debs carry: the Open5GS install prefix
# lives under the source tree, and /opt/LTE is outside /opt/GSM so osmo-deb
# pack embeds no sources (SRC_ROOT). This keeps the source trees in the image.
COPY --from=lte /opt/LTE /opt/LTE

# The runtime packages (libzmq5, libmbedtls, libconfig++, mongodb-org...) are
# installed by the top apt step of this file: osmo-deb .debs declare no
# dependencies, so nothing is installed here.
#
# `--configs --launchers`, same order as in the lte stage: the Open5GS yaml,
# enb.conf and the two launchers are written outside any DESTDIR, so no .deb
# carries them. They read /opt/GSM/osmo-operator, cloned above.
RUN OSMO_REPO=/opt/GSM/osmo-operator osmo-lte-install --configs --launchers && \
    ldconfig && test -x /usr/local/bin/srsenb \
    && test -x /opt/LTE/open5gs/install/bin/open5gs-mmed \
    && test -s /opt/LTE/open5gs/install/etc/open5gs/mme.yaml && grep -q '^  sgsap:' /opt/LTE/open5gs/install/etc/open5gs/mme.yaml \
    && test -s /opt/LTE/open5gs/install/etc/freeDiameter/mme.conf \
    && test -s /opt/LTE/open5gs/install/etc/open5gs/tls/mme.crt \
    && test -s /root/.config/srsran/enb.conf && test -x /usr/local/bin/osmo-lte && test -x /usr/local/bin/osmo-epc

# gcc alternatives: declared in the bb stage, which only passes on its .debs;
# redeclared here, with gcc-11 as default.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11 \
    && update-alternatives --set gcc /usr/bin/gcc-11

# ── 3. Project files ────────────────────────────────────────────────────────
WORKDIR /etc/osmocom
COPY scripts/. /etc/osmocom/
COPY configs/*cfg /etc/osmocom/
RUN mv /etc/osmocom/run.sh /root/run.sh
# gapk-start.sh (copied by `COPY scripts/.` above): symlink + state directory.
RUN chmod +x /etc/osmocom/gapk-start.sh && \
    ln -sf /etc/osmocom/gapk-start.sh /usr/local/bin/gapk-start.sh && \
    mkdir -p /var/lib/gapk

RUN cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    cp -f /usr/local/bin/proto-smsc-* /usr/bin/ || true && \
    cp -f /usr/local/bin/sms-* /usr/bin/ || true && \
    cp -f /usr/local/bin/gen-sms-* /usr/bin/ || true && \
    # Install any .service files from configs/
    cp /etc/osmocom/configs/*.service /lib/systemd/system/ 2>/dev/null || true

# ── proto-SMSC binaries check ───────────────────────────────────────────────
# Built by gsup-smsc-proto, copied into /usr/bin just above. Warning only.
RUN which proto-smsc-daemon && which proto-smsc-sendmt && \
    echo "proto-smsc binaries OK" || \
    echo "WARNING: proto-smsc binaries not found in PATH"

# Permissions and systemd fixes (status 214/217: CPUScheduling and the
# osmocom user are not available in the container).
RUN sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service && \
    chmod +x /etc/osmocom/*.sh

# Enable services; units from services/ go to /etc/systemd/system/.
COPY services/osmo-bts-trx.service /etc/systemd/system/osmo-bts-trx.service
RUN systemctl enable osmo-bts-trx.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Host-side osmocom-bb binaries, installed in a single layer with explicit modes.
RUN mkdir -p /root/.osmocom/bb/ \
    && install -m755 ${ROOT}/osmocom-bb/src/host/trxcon/src/trxcon           /usr/local/bin/trxcon \
    && install -m755 ${ROOT}/osmocom-bb/src/host/layer23/src/mobile/mobile   /usr/local/bin/mobile \
    && install -m755 ${ROOT}/osmocom-bb/src/host/virt_phy/src/virtphy        /usr/local/bin/virtphy
# ccch_scan is installed from the fixeria/burst_ind branch, not from here.

# Interactive shell conveniences (read when a session starts).
RUN echo "alias faketrx='python3 ${ROOT}/osmocom-bb/src/target/trx_toolkit/fake_trx.py'" >> ~/.bashrc
# ── Interactive prompt (user red / hostname blue / cwd green / ☎️#) ─────────
# \h = container name, set by `docker run --hostname "$container_name"`
# (start-docker.sh).
RUN printf '%s\n' '' \
    '### calypso-prompt ###' \
    "export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️# '" \
    '### end calypso-prompt ###' >> /root/.bashrc
COPY configs/mobile.cfg /root/.osmocom/bb/mobile.cfg
RUN chmod +x /root/run.sh

# proto-SMSC directories + Asterisk tree.
RUN mkdir -p /var/log/osmocom /var/run/smsc \
        /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk \
        /root/.osmocom/bb && \
    chmod 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk \
        /var/run/asterisk /var/log/osmocom

# ── PulseAudio system mode: config baked at build time ──────────────────────
# Every daemon must be reachable from startup: anonymous socket, null sinks
# gsm_audio / gsm_mic / osmo_tts_off, root in pulse-access.
# gsm_mic must exist with the daemon: configs/asound.conf points the gsm_in
# capture at gsm_mic.monitor, and gapk_io drops both playback and capture if
# capture fails.
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
    grep -q 'sink_name=osmo_tts_off' /etc/pulse/system.pa \
      || echo 'load-module module-null-sink sink_name=osmo_tts_off format=s16le rate=8000 channels=1 sink_properties=device.description=TTS_off' >> /etc/pulse/system.pa; \
    sed -i 's|^load-module module-suspend-on-idle|#load-module module-suspend-on-idle|' /etc/pulse/system.pa; \
    mkdir -p /var/run/pulse && chown -R pulse:pulse /var/run/pulse

# root's shell profile activates the gr-gsm venv.
RUN echo 'source ~/.env/bin/activate' >> ~/.bashrc

# ── Camping bridge scripts -> /opt/GSM (required by /opt/GSM/qosmo/run.sh):
# si_bridge.py (full SI set -> 4730 -> shunt feed_si), si_bridge_loop.sh,
# record_drain.py (iq_record.fifo -> record.cfile), grgsm_fft_live.py.
COPY opt-gsm/. /opt/GSM/

# --- Image metadata ----------------------------------------------------------
# SIGRTMIN+3 is systemd's clean shutdown signal.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
CMD ["/bin/bash"]

# ── Stage `debs`: the .deb cache only ───────────────────────────────────────
# `osmocom-nitb` is NOT the last stage of this file: everything that builds the
# image must pass `--target osmocom-nitb` (build.sh compose_build, compose.yaml
# build.target, iso_modules/21-docker-build.sh, .github/workflows/docker.yml).
# Without it, docker builds `debs`: an image containing only ~2 GB of packages.
#
# Used by CI, where the image is pushed straight to GHCR without being loaded
# locally: a second pass `--target debs --output type=local` reuses the whole
# build cache and writes only /var/cache/osmo-debs to the runner disk, for
# actions/cache. On the host, build.sh uses debs_from_image instead.
FROM scratch AS debs
COPY --from=osmocom-nitb /var/cache/osmo-debs/ /
