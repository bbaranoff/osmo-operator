# syntax=docker/dockerfile:1
# osmo-minioperator: Osmocom stack (debs) + qosmo + c54x_exe + osmocom-bb, DSP run.
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later

# BUILD_DEB=0 (default): qosmo and c54x_exe come from the release .debs
# (verified by SHA-256). BUILD_DEB=1: built from source at the pinned
# commits, then ./make-debs.sh rebuilds the .debs from the image.
# Global ARGs: each stage redeclares them without a value (an ARG does not cross a FROM).
ARG BUILD_DEB=0
ARG DEB_URL=https://github.com/bbaranoff/osmo-minioperator/releases/download/debs-2026-11-08-en

FROM ubuntu:24.04 AS base
ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM
ENV container=docker \
    OSMO_IMAGE=1 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    GIT_TERMINAL_PROMPT=0

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git gcc g++ make cmake autoconf automake libtool pkg-config \
      wget curl ca-certificates gnupg \
      python3 python3-dev python3-venv python3-pip python3-numpy python3-scipy \
      libglib2.0-dev libpixman-1-dev libslirp-dev socat ninja-build \
      iproute2 procps psmisc util-linux \
    && rm -rf /var/lib/apt/lists/*

# Osmocom binary repo (OBS). OSMO_ASC_URL (not *_KEY): avoids the BuildKit
# SecretsUsedInArgOrEnv warning; it is a PUBLIC signing key.
ARG OSMO_OBS=https://downloads.osmocom.org/packages/osmocom:/latest/xUbuntu_24.04
ARG OSMO_ASC_URL=https://obs.osmocom.org/projects/osmocom/public_key
RUN install -d /usr/share/osmocom-keyring \
    && curl -fsSL "${OSMO_ASC_URL}" -o /usr/share/osmocom-keyring/osmocom.asc \
    && echo "deb [signed-by=/usr/share/osmocom-keyring/osmocom.asc] ${OSMO_OBS}/ ./" \
         > /etc/apt/sources.list.d/osmocom.list

# libosmocore-dev: libosmocoding.pc + libosmocore.pc to link c54x_exe.
RUN apt-get update && apt-get install -y --no-install-recommends libosmocore-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.postBuffer 524288000
SHELL ["/bin/bash", "-c"]
WORKDIR ${ROOT}


FROM base AS tic54x
# objdump and gas tic54x for harvard.sh (ROM disassembly at PC, assembly on the P side).
# The tic54x target has left binutils since: take 2.21.1, verified by SHA-256 (same recipe
# as c54x_exe tools/toa23/reproduce.sh; the old C needs -std=gnu89).
ARG BU_URL=https://ftp.gnu.org/gnu/binutils/binutils-2.21.1.tar.bz2
ARG BU_SHA256=cdecfa69f02aa7b05fbcdf678e33137151f361313b2f3e48aba925f64eabf654
RUN apt-get update && apt-get install -y --no-install-recommends bzip2 texinfo && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 2 -o /tmp/bu.tar.bz2 "$BU_URL" \
    && echo "$BU_SHA256  /tmp/bu.tar.bz2" | sha256sum -c - \
    && tar xjf /tmp/bu.tar.bz2 -C /tmp && mkdir /tmp/bt && cd /tmp/bt \
    && /tmp/binutils-2.21.1/configure --target=tic54x-coff --disable-werror --disable-nls --disable-gdb \
         --disable-ld --disable-gold --disable-gprof --disable-sim MAKEINFO=true CFLAGS='-O1 -w -std=gnu89' >/dev/null \
    && make -j"$(nproc)" all-binutils all-gas MAKEINFO=true >/dev/null \
    && install -D binutils/objdump /out/build-tic54x/binutils/objdump \
    && install -D gas/as-new /out/build-tic54x/gas/as-new \
    && /out/build-tic54x/binutils/objdump --version | head -1


FROM base AS qemu
ARG ROOT=/opt/GSM
ARG BUILD_DEB
ARG DEB_URL
ARG QOSMO_DEB=qosmo_0.git20261108.9e18bf9e_amd64.deb
ARG QOSMO_DEB_SHA256=a5f2879bf0778395c9ba536ab190b2e374daf6264c5816a793fd477dee6036c1
# Pinned commit (verified: LU + ROM voice).
ARG QOSMO_REF=9e18bf9e5574ae2d277d84de787208ed7aa7f6e2
RUN if [ "$BUILD_DEB" = 1 ]; then \
      git clone https://github.com/bbaranoff/qosmO /opt/GSM/qosmo \
      && cd /opt/GSM/qosmo \
      && git checkout -q ${QOSMO_REF} \
      && python3 -m venv /root/.venv-qemu \
      && . /root/.venv-qemu/bin/activate \
      && pip install --no-cache-dir tomli \
      && mkdir -p build && cd build \
      && ../configure --target-list=arm-softmmu --enable-l1-grgsm \
             --prefix=/opt/GSM/qemu-install --disable-werror --disable-docs \
      && make -j"$(nproc)" \
      && make install \
      && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm \
      && cp /opt/GSM/qemu-install/bin/qosmo /usr/local/bin/qosmo; \
    else \
      curl -fsSL --retry 2 -o "/tmp/$QOSMO_DEB" "$DEB_URL/$QOSMO_DEB" \
      && echo "$QOSMO_DEB_SHA256  /tmp/$QOSMO_DEB" | sha256sum -c - \
      && apt-get update && apt-get install -y --no-install-recommends "/tmp/$QOSMO_DEB" \
      && rm -rf /var/lib/apt/lists/* "/tmp/$QOSMO_DEB"; \
    fi


FROM qemu AS c54x
ARG ROOT=/opt/GSM
ARG BUILD_DEB
ARG DEB_URL

# Osmocom network stack from the upstream .debs (osmo-stp included: SS7/M3UA).
# libosmo-csn1-dev + libosmo-gprs-*-dev: required by osmocom-bb (pkg-config).
RUN apt-get update && apt-get install -y --no-install-recommends \
      osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts osmo-pcu osmo-trx \
      osmo-sgsn osmo-ggsn osmo-sip-connector telnet \
      tmux gdb-multiarch ttyd \
      asterisk asterisk-core-sounds-en pulseaudio pulseaudio-utils \
      libosmo-csn1-dev libosmo-gprs-rlcmac-dev libosmo-gprs-llc-dev \
      libosmo-gprs-gmm-dev libosmo-gprs-sm-dev libosmo-gprs-sndcp-dev \
    && rm -rf /var/lib/apt/lists/*

# Prebuilt Calypso firmware (PHY_MODE=qemu: QEMU -kernel .elf, osmocon romload .bin).
# Pinned commit (verified: LU + ROM voice).
ARG FIRMWARE_REF=cb97f3f6a071726b52b6c7fd88f096b0d5bbfb48
RUN GIT_TERMINAL_PROMPT=0 git clone https://github.com/bbaranoff/firmware /opt/GSM/firmware \
    && git -C /opt/GSM/firmware checkout -q ${FIRMWARE_REF}

# c54x_exe: CFLAGS without -march=native (SIGILL on a CPU other than the build host).
# Pinned commit (verified: LU + ROM voice).
ARG C54X_EXE_REF=dadc7c73d6294dfafede78cb3774311313a7111d
# DSP ROM 3606 dump (published by FreeCalypso) + its SHA-256. ROM_MIRRORS: full
# URLs of the dump, tried in order; the first one with the right SHA-256
# wins. A single download: fetch-rom.sh then reads the local copy (file://).
ARG ROM_MIRRORS="https://gist.githubusercontent.com/bbaranoff/ba2746dd4fe6117475d95f791bf7df35/raw/16a4e486776315ecdf6c8972c58e877fa19785c5/calypso_dsp.txt https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env/dsp-rom-3606-dump.txt https://www.freecalypso.org/pub/GSM/Calypso/dsp-rom-3606-dump.txt"
ARG CALYPSO_DSP_SHA256=e35798f50fd0a29aa61cd53e417c010d7f172582c7bc055211daab8af1e05470
ARG C54X_DEB=c54x-exe_0.git20261108.dadc7c7_amd64.deb
ARG C54X_DEB_SHA256=1e9d98ad846ed62e1eb8c6cc8bb68bb23a9810997127d59630e5d1eb2b68f6cb
RUN if [ "$BUILD_DEB" = 1 ]; then \
      git clone https://github.com/bbaranoff/c54x_exe /opt/GSM/c54x_exe \
      && cd /opt/GSM/c54x_exe \
      && git checkout -q ${C54X_EXE_REF} \
      && make QOSMO=/opt/GSM/qosmo \
             CFLAGS="-O3 -g -Wall -Werror=format -Werror=format-extra-args -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare"; \
    else \
      curl -fsSL --retry 2 -o "/tmp/$C54X_DEB" "$DEB_URL/$C54X_DEB" \
      && echo "$C54X_DEB_SHA256  /tmp/$C54X_DEB" | sha256sum -c - \
      && apt-get update && apt-get install -y --no-install-recommends "/tmp/$C54X_DEB" \
      && rm -rf /var/lib/apt/lists/* "/tmp/$C54X_DEB"; \
    fi \
    && cd /opt/GSM/c54x_exe \
    && install -d /tmp/rom-src && ok=0 \
    && for url in $ROM_MIRRORS; do \
         echo "DSP ROM: trying $url"; \
         curl -fsSL --retry 2 -o /tmp/rom-src/dsp-rom-3606-dump.txt "$url" \
         && echo "${CALYPSO_DSP_SHA256}  /tmp/rom-src/dsp-rom-3606-dump.txt" | sha256sum -c - \
         && { ok=1; break; } || true; \
       done \
    && { [ "$ok" = 1 ] || { echo "DSP ROM: no valid mirror ($ROM_MIRRORS)" >&2; exit 1; }; } \
    && FREECALYPSO_URL=file:///tmp/rom-src bash rom/fetch-rom.sh --dest /opt/GSM --dest /opt/GSM/c54x_exe/rom \
    && mv /tmp/rom-src/dsp-rom-3606-dump.txt /opt/GSM/calypso_dsp.txt && rmdir /tmp/rom-src \
    && cp /opt/GSM/calypso_dsp.txt rom/calypso_dsp.txt

# osmocom-bb: make nofirmware in src/ (mobile, osmocon, trxcon). Pin eac4eed1
# (beyond it trxcon leaves make nofirmware). Expose `mobile` in the PATH.
ARG OSMOCOM_BB_REF=eac4eed1
RUN git clone https://gitea.osmocom.org/phone-side/osmocom-bb /opt/GSM/osmocom-bb \
    && git -C /opt/GSM/osmocom-bb checkout -q ${OSMOCOM_BB_REF} \
    && cd /opt/GSM/osmocom-bb/src \
    && make nofirmware \
    && ln -sf /opt/GSM/osmocom-bb/src/host/layer23/src/mobile/mobile /usr/local/bin/mobile

# Frozen configs (single operator) + DSP bridge + scripts.
COPY configs/ /opt/GSM/osmo-minioperator/configs/
COPY configs/asterisk/ /etc/asterisk/
COPY pont/ /opt/GSM/osmo-minioperator/pont/
COPY run-dsp.sh start.sh verif.sh consoles.sh echotest.py echo-tmux.sh /opt/GSM/osmo-minioperator/
RUN chmod +x /opt/GSM/osmo-minioperator/run-dsp.sh /opt/GSM/osmo-minioperator/start.sh /opt/GSM/osmo-minioperator/verif.sh \
             /opt/GSM/osmo-minioperator/consoles.sh \
    && install -d /etc/osmocom /var/lib/osmocom /var/log/osmocom /root/.osmocom/bb \
    && cp /opt/GSM/osmo-minioperator/configs/*.cfg /etc/osmocom/ \
    && cp /opt/GSM/osmo-minioperator/configs/mobile.cfg /root/.osmocom/bb/mobile.cfg

# osmocom:latest keeps only one version per package: pinning (pkg=ver) would break
# the build at the next release. So compare to the verified list and report it.
ARG STRICT_VERSIONS=0
RUN grep -v '^#' /opt/GSM/osmo-minioperator/configs/versions-verifiees.txt | sort > /tmp/v-ref \
    && dpkg-query -W -f '${Package} ${Version}\n' $(cut -d' ' -f1 /tmp/v-ref) | sort > /tmp/v-img \
    && cp /tmp/v-img /opt/GSM/osmo-minioperator/versions-image.txt \
    && if diff -u /tmp/v-ref /tmp/v-img; then echo "versions: identical to the verified ones"; \
       else echo "WARNING: versions differ from the 2026-11-08 verification (see above)"; \
            [ "$STRICT_VERSIONS" != 1 ]; fi \
    && rm -f /tmp/v-ref /tmp/v-img

# gdb console (consoles.sh): the layer1 ELF must have its symbols and sources.
# DW_AT_comp_dir = /opt/GSM/osmocom-bb/src/target/firmware; the ELF's sources
# are those of the firmware repo (same commit): substitute-path. The build fails otherwise.
RUN gdb-multiarch -q -nx -batch \
        -iex 'set substitute-path /opt/GSM/osmocom-bb/src/target/firmware /opt/GSM/firmware' \
        -ex 'list l1a_l23_handler' -ex 'info source' \
        /opt/GSM/firmware/board/compal_e88/layer1.highram.elf | tee /tmp/gdb-list.txt \
    && grep -q 'void l1a_l23_handler(void)' /tmp/gdb-list.txt \
    && grep -q 'Located in /opt/GSM/firmware/layer1/l23_api.c' /tmp/gdb-list.txt \
    && rm -f /tmp/gdb-list.txt

# harvard.sh: objdump and gas tic54x (tic54x stage) at the paths it expects.
COPY --from=tic54x /out/build-tic54x/ /opt/GSM/c54x_exe/build-tic54x/

# Audio: the host PulseAudio socket is mounted here by docker-run.sh.
ENV PULSE_SERVER=unix:/run/pulse/native

WORKDIR /opt/GSM/osmo-minioperator
ENTRYPOINT ["/opt/GSM/osmo-minioperator/start.sh"]
# Default: a shell, nothing starts (no tmux). tmux consoles: ./consoles.sh; echo test: ./echo-tmux.sh.
CMD ["/bin/bash"]
