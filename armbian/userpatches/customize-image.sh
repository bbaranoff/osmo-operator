#!/bin/bash
# armbian/userpatches/customize-image.sh - la pile osmo-operator posee dans l image Armbian
#
# Execute par armbian/build DANS LE CHROOT de l image (arguments : $RELEASE $LINUXFAMILY $BOARD
# $BUILD_DESKTOP), avec userpatches/overlay monte en /tmp/overlay. Ce que fait l ISO en plusieurs
# modules (50-injection-image, 80-chroot, 82-arm-natif, 84-comptes), ramene a l essentiel :
#   1. les paquets Ubuntu dont la pile a besoin a l execution (liste de 80-chroot.sh, sans noyau ni live)
#   2. dpkg -i des .deb du build docker (osmo-build-* : libosmocore, osmo-*, gapk, QEMU, osmocom-bb...)
#   3. l arbre /tmp/overlay/osmo/rootfs recopie sur / (/usr/local, /opt/GSM, /etc/osmocom, unites...)
#   4. ce qu un hote x86 ne peut pas produire, compile ICI (aarch64) : toast, lanceur qosmo,
#      c54x_exe / grgsm_exe, les .deb du banc (packaging/build-debs.sh)
#   5. comptes (root/osmo, osmocom/osmo), plus d assistant Armbian au premier login, services
# Le noyau, le firmware du Pi, l agrandissement de la racine : Armbian s en charge.
set -euo pipefail
RELEASE="${1:-}"; LINUXFAMILY="${2:-}"; BOARD="${3:-}"; BUILD_DESKTOP="${4:-}"
OV=/tmp/overlay/osmo
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
log() { echo "[osmo-customize] $*"; }
log "release=$RELEASE family=$LINUXFAMILY board=$BOARD desktop=$BUILD_DESKTOP overlay=$OV"
[ -d "$OV" ] || { log "pas d overlay $OV : image Armbian nue"; exit 0; }
[ -f "$OV/SOURCE" ] && log "pile : $(tr '\n' ' ' < "$OV/SOURCE")"
case "$RELEASE" in noble) ;; *) log "ATTENTION : les .deb du build visent noble, pas $RELEASE" ;; esac

# ── 1. paquets d execution ───────────────────────────────────────────────────
apt-get update
PKGS="ca-certificates openssl netcat-openbsd socat tcpdump git logrotate systemd-resolved build-essential wget
      libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev libc-ares2
      libgnutls30t64 libgnutls28-dev libmnl-dev libmnl0
      libortp-dev libdbi1t64 libdbd-sqlite3 sqlite3
      libfftw3-single3 libusb-1.0-0 libgsm1 libasound2t64
      libsofia-sip-ua-glib3t64 liburing2 libslirp0
      iproute2 iptables net-tools lksctp-tools
      tmux telnet expect whiptail lsb-release openssh-server sudo
      console-setup keyboard-configuration locales psmisc cryptsetup rsync
      python3 python3-venv python3-scapy tshark wireshark-common
      libasound2-plugins pulseaudio pulseaudio-utils alsa-utils
      binutils-arm-none-eabi gdb-multiarch asterisk ffmpeg
      libzmq5 libfftw3-dev cmake libpcsclite-dev meson ninja-build flex bison
      libgcrypt20-dev libssl-dev libidn-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev
      libtins-dev libc-ares-dev zstd kpartx"
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS || {
    log "apt : certains paquets manquent sur $RELEASE/arm64, on pose ce qui existe"
    for p in $PKGS; do apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || log "  absent : $p"; done
}

# ── 2. les .deb du build docker ──────────────────────────────────────────────
if ls "$OV"/debs/*.deb >/dev/null 2>&1; then
    install -d /var/cache/osmo-debs
    cp -f "$OV"/debs/*.deb /var/cache/osmo-debs/
    dpkg -i --force-overwrite /var/cache/osmo-debs/osmo-build-*.deb || apt-get install -y -f
    ldconfig
    log "$(ls /var/cache/osmo-debs/*.deb | wc -l) paquets du build poses"
else
    log "pas de .deb du build dans l overlay : tout vient de l arbre rootfs/"
fi

# ── 3. l arbre de l image docker ─────────────────────────────────────────────
if [ -d "$OV/rootfs" ]; then
    cp -a "$OV/rootfs/." /
    ldconfig
    log "arbre recopie : $(du -sh "$OV/rootfs" | cut -f1) (/usr/local, /opt/GSM, /etc/osmocom, unites)"
fi

# ── 4. compilation native (aarch64) ──────────────────────────────────────────
if [ ! -x /usr/local/bin/toast ]; then
    ( set -e; cd /opt/GSM
      wget -qO gsm-1.0.24.tar.gz https://www.quut.com/gsm/gsm-1.0.24.tar.gz
      tar xzf gsm-1.0.24.tar.gz && rm -f gsm-1.0.24.tar.gz && cd gsm-1.0-pl24
      make >/dev/null 2>&1 || true; [ -x bin/toast ] || make toast >/dev/null 2>&1
      for b in toast untoast tcat; do [ -e "bin/$b" ] && install -m755 "bin/$b" "/usr/local/bin/$b"; done
    ) && log "toast compile" || log "toast non compile (on continue)"
fi
for fork in qosmo; do
    if [ -d "/opt/GSM/$fork/tools/qosmo-launch" ]; then
        make -s -C "/opt/GSM/$fork/tools/qosmo-launch" ALIAS="$fork" "$fork" && install -Dm755 "/opt/GSM/$fork/tools/qosmo-launch/$fork" "/usr/local/bin/$fork" \
            && log "lanceur /usr/local/bin/$fork compile" || log "lanceur $fork : echec (run.sh appellera qemu-system-arm directement)"
    fi
done
for e in c54x_exe grgsm_exe; do
    [ -d "/opt/GSM/$e" ] && { make -s -B -C "/opt/GSM/$e" && log "$e compile" || log "$e : compilation echouee"; }
done
/usr/local/bin/qemu-system-arm --version >/dev/null 2>&1 && log "qemu-system-arm (aarch64) s execute" || log "qemu-system-arm absent ou KO"
if [ -x /opt/GSM/osmo-operator/packaging/build-debs.sh ]; then
    install -d /var/cache/osmo-debs
    env OSMO_OPERATOR_SRC=/opt/GSM/osmo-operator QOSMO_SRC=/opt/GSM/qosmo bash /opt/GSM/osmo-operator/packaging/build-debs.sh --out /var/cache/osmo-debs \
        && log ".deb du banc construits dans /var/cache/osmo-debs" || log ".deb du banc non construits (l image sort sans eux)"
fi

# ── 5. comptes, premier login, services ──────────────────────────────────────
id -u osmocom >/dev/null 2>&1 || useradd -m -s /bin/bash -c 'Compte osmocom (non privilegie)' osmocom
echo 'osmocom:osmo' | chpasswd
echo 'root:osmo'    | chpasswd
usermod -aG sudo,audio,dialout,plugdev osmocom 2>/dev/null || true
rm -f /root/.not_logged_in_yet            # pas d assistant Armbian au premier login : les comptes sont poses
for u in osmo-egprs-web osmo-pulse; do systemctl enable "$u" 2>/dev/null || true; done
for u in osmo-banc osmo-multi; do        # poses, pas actives : OSMO_IMAGE_BANC=1 / OSMO_IMAGE_MULTI=1 dans l overlay pour les activer
    v="OSMO_IMAGE_${u#osmo-}"; v="${v^^}"
    [ -f "$OV/$v" ] && systemctl enable "$u" 2>/dev/null && log "$u active au boot"
done
apt-get clean; rm -rf /var/lib/apt/lists/*
log "termine"
