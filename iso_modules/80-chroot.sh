#!/bin/bash
# iso_modules/80-chroot.sh - etape 8 : configuration du rootfs dans le chroot (apt, noyau, bureau)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

echo -e "${GREEN}[8/9] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
# ── LE CACHE APT DU CHROOT EST PERSISTANT ───────────────────────────────────
# [2026-09-04] Chaque passe retelechargeait ~700 paquets (le hub, la normale,
# et toute reconstruction). Le repertoire ou apt (et apt-fast, DLDIR) range ses
# .deb est un bind du cache de l hote, ISO_DEB_CACHE/apt-archives : telecharge
# une fois, reutilise par toutes les passes et les builds suivants. Il est
# demonte AVANT le squashfs (les .deb ne partent pas dans l ISO), et le
# chroot ne fait plus "apt-get clean" quand il est monte - ce serait vider le
# cache de l hote. --no-cache : pas de bind, comportement d avant.
ISO_APT_CACHE_BOUND=0
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    mkdir -p "$ISO_DEB_CACHE/apt-archives/partial" "$ROOTFS/var/cache/apt/archives"
    if mount --bind "$ISO_DEB_CACHE/apt-archives" "$ROOTFS/var/cache/apt/archives"; then
        ISO_APT_CACHE_BOUND=1
        echo -e "  ${GREEN}cache apt du chroot : $ISO_DEB_CACHE/apt-archives ($(du -sh "$ISO_DEB_CACHE/apt-archives" | cut -f1), $(find "$ISO_DEB_CACHE/apt-archives" -maxdepth 1 -name '*.deb' | wc -l) paquets)${NC}"
    fi
fi
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

# L installeur apt-fast, le meme que celui du Dockerfile, dans le rootfs.
install -m755 "$DIR/packaging/apt-fast-install.sh" "$ROOTFS/usr/local/sbin/apt-fast-install"

# ISO_ROLE passe par l environnement : le script est en quotes simples, rien n y
# est substitue a l ecriture - c est voulu (aucune surprise d expansion), donc la
# seule facon de lui dire quelle image on construit est de le lui passer.
chroot "$ROOTFS" env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                   ISO_ROLE="$ISO_ROLE" ISO_LITE="$ISO_LITE" ISO_APT_CACHE_BOUND="$ISO_APT_CACHE_BOUND" \
                   ISO_ARCH="$ISO_ARCH" ISO_MIRROR="$ISO_MIRROR" \
                   ISO_DESKTOP="$ISO_DESKTOP" OSMO_ISO_KB="$OSMO_ISO_KB" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"

# ── apt/dpkg rapides ────────────────────────────────────────────────────────
# Ce rootfs est jetable : il est fabrique, empaquete en squashfs, puis efface.
# Les garanties de durabilite que dpkg paie a chaque fichier - un fsync par
# fichier deballe - n ont donc aucune valeur ici, et elles dominent le temps de
# construction. force-unsafe-io les coupe : c est le reglage qu utilisent les
# images Docker officielles, pour la meme raison.
#
# Le reste ne joue pas sur la durabilite mais sur ce qui est TELECHARGE :
#   Languages=none    supprime les traductions de descriptions (inutiles ici)
#   Pipeline-Depth    plusieurs requetes en vol au lieu d une a la fois
#   Retries           un miroir qui bronche ne fait plus echouer la construction
#                     entiere - ce chroot tourne sous set -e
mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/02-unsafe-io
# Les reglages de telechargement (Languages, Retries, Pipeline, Use-Pty) sont
# poses par apt-fast-install, plus bas, dans /etc/apt/apt.conf.d/90osmo-operator
# - les memes que dans l image docker et sur l hote.

APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

# ${ISO_SUITE} vient de l environnement du chroot (export plus haut) ; le
# heredoc est NON quote pour que la substitution ait lieu ici.
_S="${ISO_SUITE:-noble}"
# Le miroir suit l architecture (arm64 : ports.ubuntu.com). restricted en plus
# sur arm64 : linux-firmware-raspi (start4.elf, le firmware de demarrage du Pi)
# y est range.
_M="${ISO_MIRROR:-http://archive.ubuntu.com/ubuntu}"
_C="main universe multiverse"
[ "${ISO_ARCH:-amd64}" = "arm64" ] && _C="$_C restricted"
# ── GIT : plus de forcage HTTP/1.1 ──────────────────────────────────────────
# [2026-09-03] RETIRE, ici comme dans le Dockerfile et update.sh. Le reglage
# http.version=HTTP/1.1 datait d un incident de reseau ("expected flush after
# ref listing") ; il ralentissait tous les clones de l image. Si une machine
# retombe dessus, c est un reglage LOCAL a poser sur elle :
#     git config --global http.version HTTP/1.1
git config --system --unset http.version 2>/dev/null || true

cat > /etc/apt/sources.list <<SOURCES
deb $_M $_S           $_C
deb $_M $_S-updates    $_C
deb $_M $_S-security   $_C
SOURCES

# ── Les certificats D ABORD ─────────────────────────────────────────────────
# Installer ca-certificates ne suffit pas : c est update-ca-certificates qui
# deballe /usr/share/ca-certificates/* dans /etc/ssl/certs et fabrique le
# ca-certificates.crt que lisent OpenSSL, curl, git, apt (https) et snap. Dans
# un chroot le postinst ne le fait pas toujours, et le rootfs sortait avec un
# magasin vide : "certificate verify failed" partout, et le message accuse le
# reseau. On le fait ICI, avant le premier octet TLS (la cle NodeSource
# ci-dessous), et plus jamais apres : un --reinstall du paquet en fin de chroot
# ne faisait que rejouer ce meme appel, une resolution apt de plus pour rien.
# --fresh : on repart du magasin du paquet plutot que d un etat herite du
# debootstrap, dont on ne sait pas ce qu il contient.
update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates || true

# ── arm64 : LE DEPOT ARMBIAN (noble), en plus des ports Ubuntu ──────────────
# La base arm64 est Armbian 24.04 : le noyau bcm2711 d Armbian (rpi-6.18.y),
# ses device-trees, le paquet BSP rpi4b (les hooks qui tiennent /boot/firmware
# a jour, zram, resize, motd...), et son base-files (os-release Armbian). Le
# depot porte aussi les paquets Ubuntu du Pi (linux-firmware-raspi, rpi-eeprom,
# libraspberrypi-bin). Ecrit APRES les certificats (le depot est en https) et
# AVANT l unique apt-get update, cle dearmee dans /usr/share/keyrings : c est
# le format deb822 qu Armbian lui-meme utilise.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    curl -fsSL --retry 3 https://apt.armbian.com/armbian.key | gpg --dearmor -o /usr/share/keyrings/armbian.gpg
    cat > /etc/apt/sources.list.d/armbian.sources <<EOF
Types: deb
URIs: https://apt.armbian.com
Suites: $_S
Components: main $_S-utils $_S-desktop
Signed-By: /usr/share/keyrings/armbian.gpg
EOF
    # /boot/firmware doit EXISTER avant l installation du noyau : les hooks du
    # BSP (zzz-copy-new-files, zzz-update-initramfs, en bash -e) y copient sans
    # le creer, et update-initramfs echouerait avec eux - donc tout ce script.
    mkdir -p /boot/firmware
    echo "depot Armbian : https://apt.armbian.com $_S"
fi

# ── deb-src : AVANT l unique apt-get update ─────────────────────────────────
# Le build-dep gnuradio plus bas lit les index Sources. Ils etaient tires par
# un DEUXIEME apt-get update, juste pour lui ; en ecrivant deb-src.list ici, le
# seul update du chroot les ramene avec le reste. Le hub inter-STP n a pas de
# gr-gsm : lui faire tirer ~80 Mo d index Sources, c est du temps pour rien -
# il n a donc pas de deb-src, et pas de build-dep.
if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    sed -nE "s|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p" \
        /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list
fi

# ── NodeSource : AVANT l unique apt-get update, et nodejs dans PKGS ─────────
# Le dashboard tourne sous node 22, que jammy n a pas (12.22 dans les depots).
# L ancien chemin lancait le script setup_22.x de NodeSource, qui fait SON
# apt-get update, puis un apt-get install nodejs a part : deux resolutions de
# plus. On pose le depot a la main - cle ASCII dans /etc/apt/keyrings, apt 2.4
# la lit telle quelle, sans gpg --dearmor - et nodejs rejoint la liste unique.
# Si la cle ne se telecharge pas (pas de reseau vers NodeSource), on retombe
# plus bas sur le script officiel, comme avant.
NODE_VIA_APT=0
if ! command -v node >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            -o /etc/apt/keyrings/nodesource.asc; then
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        NODE_VIA_APT=1
    else
        echo "  WARN: cle NodeSource non telechargee - repli sur setup_22.x apres l install"
        rm -f /etc/apt/keyrings/nodesource.asc
    fi
fi

# ── UN SEUL apt update, puis apt-fast pour tout le reste ───────────────────
# [2026-09-02] Il y en avait trois dans ce chroot : celui-ci, un pour les
# deb-src du build-dep, un dans le script NodeSource. Tout ce qui ajoute une
# source est maintenant fait AVANT, et cet appel les lit toutes d un coup.
# [2026-09-03] apt-fast : le meme installeur que le Dockerfile
# (/usr/local/sbin/apt-fast-install, copie dans le rootfs avant ce chroot).
# Il pose aria2 et curl par apt-get - le seul apt-get qui reste - puis tout
# passe en parallele. Repli integre sur apt-get si GitHub est injoignable.
apt-get update -qq
/usr/local/sbin/apt-fast-install

# ── UN SEUL apt-get install ────────────────────────────────────────────────
# [2026-08-27] Il y en avait cinq a la suite. apt resout, telecharge puis
# configure a CHAQUE appel : cinq resolutions de dependances, cinq lots de
# telechargement qui ne se recouvrent pas, et dpkg qui reconfigure ce que le lot
# suivant vient de tirer. Un seul appel resout une fois, telecharge en parallele
# et deballe dans un seul ordre - c est le poste le plus lourd du chroot.
#
# L ordre compte encore : cet appel reste JUSTE APRES apt-get update, avant le
# build-dep. Ce chroot tourne sous set -e ; un build-dep qui echoue ne doit pas
# emporter avec lui les outils sans lesquels l ISO sort muette :
#   nc       le VTY est la seule source de verite sur l etat SS7 : tout le
#            depot l interroge par "nc 127.0.0.1 4239". Sans nc, les checks ne
#            se plaignent pas - ils affichent un diagnostic VIDE, qui se lit
#            comme "rien n est attache" alors que tout va bien.
#   socat    le transport VTY que run_modules/_lib/core.sh prend EN PREMIER, et
#            sans lequel 21-abonnes-hlr.sh se rabat sur telnet - qui ne rend pas
#            la main sur EOF de stdin, donc pas de provisionnement HLR.
#   tcpdump  les captures GSMTAP/M3UA. Sans lui, une capture lancee en arriere
#            plan echoue en silence et le pcap reste vide.
#   git      les trois depots embarques gardent leur .git : c est par lui qu on
#            les met a jour, sur la machine, sans les recloner.
#
# Deux listes, parce que les deux images ne font pas le meme metier. Le hub
# inter-STP ne fait que router du M3UA : ni radio, ni QEMU, ni audio, ni PBX.
# Lui installer asterisk, pulseaudio et ffmpeg, c est du poids et des services
# en plus pour rien.
# ca-certificates EN TETE de liste ; son magasin, lui, est regenere en tete de
# ce chroot (update-ca-certificates --fresh, voir plus haut) : le rootfs sort
# de debootstrap avec le paquet mais SANS /etc/ssl/certs peuple, et tout ce qui
# parle en TLS echouait sur "certificate verify failed".
# LE NOYAU : 6.8 (HWE), PAS 5.15 (GA). linux-image-generic sur jammy est fige a
# la serie 5.15 ; le materiel recent (NIC, USB3, SDR branches en direct) y perd
# des pilotes que la serie 6.8 porte. linux-image-generic-hwe-22.04 est le noyau
# d activation materielle officiel de jammy (6.8.0-138, meme depot main, meme
# cle Canonical - donc toujours signe pour Secure Boot) et tire
# linux-modules-extra en dependance. La detection plus bas [ls vmlinuz-star,
# sort -V, tail -1] choisit automatiquement le 6.8 pour l ISO.
# [2026-09-03] LES NOMS DEPENDENT DE LA SUITE. noble a renomme les
# bibliotheques dont l ABI portait un time_t (transition 64 bits) : libasound2
# -> libasound2t64, libgnutls30 -> libgnutls30t64, libdbi1 -> libdbi1t64,
# libsofia-sip-ua-glib3 -> libsofia-sip-ua-glib3t64 ; et c-ares s appelle
# libcares2. Le noyau : sur noble, linux-image-generic EST la serie 6.8 (GA),
# la meme que le HWE de jammy - pas besoin du HWE de noble (7.0). Verifie le
# 2026-09-03 sur ubuntu:24.04 (apt-cache policy) pour chacun de ces noms.
case "$_S" in
    noble) _KERNEL_PKG="linux-image-generic";           _T64="t64"; _CARES="libcares2" ;;
    *)     _KERNEL_PKG="linux-image-generic-hwe-22.04"; _T64="";    _CARES="libc-ares2" ;;
esac
# ── arm64 / Raspberry Pi 4 : ARMBIAN, pas de live-boot ──────────────────────
# Exactement ce que le build Armbian pose pour rpi4b (config/sources/families/
# bcm2711.conf) : linux-image-current-bcm2711 (noyau rpi-6.18.y, vmlinuz dans
# /boot, dtb + overlays sous /usr/lib/linux-image-<ver>), linux-dtb-current-
# bcm2711, armbian-bsp-cli-rpi4b-current (les hooks /etc/kernel/postinst.d qui
# recopient noyau, dtb et firmware dans /boot/firmware, le resize au premier
# boot, zram, motd, armbian-config), armbian-firmware ; et les paquets Ubuntu
# du Pi que le depot Armbian porte : linux-firmware-raspi (start4.elf,
# fixup4.dat - le GPU les charge avant le noyau), rpi-eeprom, libraspberrypi-
# bin (vcgencmd), raspi-config. Pas de u-boot sur le Pi 4 : le firmware charge
# vmlinuz directement (config.txt, ecrit par 82-arm-natif). build-essential et
# wget : toast et les lanceurs se compilent dans ce chroot (l hote ne sait pas
# produire de l aarch64), et osmo-update recompile les lanceurs sur la machine.
# PAS de live-boot : la racine est une ext4 sur la carte SD, montee par
# l initramfs standard (root=LABEL=armbi_root dans cmdline.txt).
_LIVE_PKGS="live-boot live-boot-initramfs-tools"
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    _KERNEL_PKG="linux-image-current-bcm2711 linux-dtb-current-bcm2711 armbian-bsp-cli-rpi4b-current armbian-firmware
      linux-firmware-raspi rpi-eeprom libraspberrypi-bin raspi-config build-essential wget"
    _LIVE_PKGS=""
fi
PKGS="ca-certificates openssl netcat-openbsd socat tcpdump git logrotate
      $_KERNEL_PKG initramfs-tools
      $_LIVE_PKGS
      libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev $_CARES
      libgnutls30${_T64} libgnutls28-dev libmnl-dev libmnl0
      libortp-dev libdbi1${_T64} libdbd-sqlite3 sqlite3
      libfftw3-single3 libusb-1.0-0
      libgsm1 libasound2${_T64}
      libsofia-sip-ua-glib3${_T64}
      liburing2 libslirp0
      iproute2 iptables net-tools lksctp-tools
      tmux telnet expect whiptail
      lsb-release openssh-server sudo
      console-setup keyboard-configuration locales
      psmisc
      python3 python3-venv python3-scapy
      tshark wireshark-common"
[ "$NODE_VIA_APT" = "1" ] && PKGS="$PKGS nodejs"

if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    # Radio, emulation Calypso, audio, PBX : le noeud operateur seulement.
    PKGS="$PKGS
      libasound2-plugins pulseaudio pulseaudio-utils alsa-utils
      binutils-arm-none-eabi gdb-multiarch
      asterisk
      ffmpeg"

    # ── En-tetes de build QEMU : l ISO NORMALE SEULEMENT ────────────────────
    # L image normale embarque /opt/GSM/qosmo-grgsm avec son .git ET son build/ :
    # c est un atelier, on y developpe l emulation Calypso et on doit pouvoir
    # relancer "make -C build qemu-system-arm" sur la machine. Or les runtimes
    # seuls (liburing2, libslirp0, libpixman-1-0) ne suffisent pas : ninja
    # reclame le lien de developpement .so ET l en-tete.
    #
    # MESURE DU 2026-08-27, sur l ISO telle que construite jusqu ici :
    #   ninja: error: "/usr/lib/x86_64-linux-gnu/libpixman-1.so" missing
    #   include/block/aio.h:18: fatal error: liburing.h: No such file
    # -> la recompilation etait IMPOSSIBLE sur la machine, alors que tout
    # l atelier (sources, .git, build/ deja peuple) etait la pour ca.
    #
    # La LITE, elle, n est pas un atelier : elle part de Dockerfile.lite, qui
    # elague justement les chaines de compilation. Trois paquets -dev de plus
    # y seraient du poids sans usage - d ou le test sur ISO_LITE.
    if [ "${ISO_LITE:-0}" != "1" ]; then
        PKGS="$PKGS
      liburing-dev libslirp-dev libpixman-1-dev"
    fi
fi

apt-fast install -y $APT_OPTS --no-install-recommends $PKGS

# build-dep gnuradio : tire toutes les deps de GNU Radio (boost, fftw, gmp,
# log4cpp, volk...) dont depend le gnuradio/gr-gsm custom de /usr/local. Les
# index Sources sont deja la : deb-src.list a ete ecrit avant l unique
# apt-get update. Le hub n a pas de gr-gsm, donc pas de deb-src ni de build-dep.
if [ -s /etc/apt/sources.list.d/deb-src.list ]; then
    apt-fast build-dep -y $APT_OPTS gnuradio || echo "WARN: apt build-dep gnuradio a echoue"
fi

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

# -- venv /root/.env : il doit EXISTER et porter tomli --------------------
# /root/.env est le venv que start-clean.sh (qosmo-grgsm) et le profil de root
# activent : le .bashrc pose plus bas fait
#     [ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
# Il arrive ici par un docker cp du CID vers /root/, suivi de || true : si
# l image de run ne le porte pas, ou si son bin/ pointe sur un interpreteur
# absent, le venv MANQUE et personne ne le dit -- le test du .bashrc echoue
# en silence et tout retombe sur le python3 systeme.
#
# python3 -m venv SANS --clear est REPARATEUR, pas destructeur : il recree
# bin/ et pyvenv.cfg, installe pip par ensurepip, et laisse
# lib/pythonX.Y/site-packages en place. On peut donc l appeler aussi bien
# sur le venv copie que sur un repertoire absent. C est aussi ce qui exige
# python3-venv dans PKGS : sans lui ensurepip n a pas ses roues, et la
# creation echoue.
#
# tomli : lecteur TOML entre dans la bibliotheque standard en 3.11 sous le
# nom tomllib, mais ABSENT de la 3.10 de jammy. Ce qui lit un TOML depuis
# le venv en depend donc explicitement - et le garde sur noble (3.12), ou il
# ne coute rien : le code importe tomli, pas tomllib.
python3 -m venv /root/.env
/root/.env/bin/python3 -m pip install -q --no-cache-dir --disable-pip-version-check tomli \
    || echo "WARN: pip a echoue pour tomli dans /root/.env"
if /root/.env/bin/python3 -c "import tomli" 2>/dev/null; then
    echo "  /root/.env : venv pret, tomli importable"
else
    echo "WARN: /root/.env sans tomli utilisable"
fi

# Docker NON installe dans le ISO (natif) : le lab tourne via start-direct.sh et le
# dashboard web via node natif. Le build sur le HOTE utilise le docker du HOTE pour
# extraire binaires/configs, mais le ISO final nembarque pas docker.

# Repli NodeSource : uniquement si la cle n a pas pu etre posee avant l update
# (voir NODE_VIA_APT plus haut). Le script officiel fait son propre update.
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/GSM/osmo-egprs-web/package.json ]; then
    cd /opt/GSM/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

# ── LE DASHBOARD S INSTALLE ICI, PAS AU PREMIER BOOT ────────────────────────
# install-web-service.sh est le script du depot osmo-egprs-web qui sait poser le
# dashboard : runtime node, dependances JS, unite systemd, certificat TLS et
# politique Firefox. Il n etait joue nulle part pendant la construction - on ne
# copiait que ses unites (etape 6) - et tout reposait donc sur
# osmo-egprs-web-install.service au premier demarrage. Quand cet oneshot
# echouait (il l a fait : l unite nommait /usr/local/bin/node, absent), l ISO
# livrait un dashboard sans TLS, donc sans micro, et rien ne le disait pendant
# le build.
#
# On le joue DONC ici, ou son echec se voit tout de suite. Les deux
# interrupteurs sont ceux que le script documente lui-meme, et ils sont faits
# pour ce cas :
#
#   WEB_NO_TLS=1   pas de certificat au build. Une cle privee fabriquee dans ce
#                  chroot serait IDENTIQUE dans toutes les ISO tirees de cette
#                  image : n importe qui pourrait se faire passer pour la
#                  console. Elle est posee sur la machine, au premier
#                  demarrage, avec ses vraies adresses - et la politique
#                  Firefox avec, puisqu elle nomme ces memes adresses.
#   WEB_NO_START=1 systemd ne tourne pas dans un chroot ; `systemctl restart`
#                  y echoue toujours, et le script est en `set -eu`. Sans cet
#                  interrupteur, la construction entiere s arreterait sur un
#                  service qui n avait aucune raison de demarrer la.
#
# Ce qui reste fait au build est justement ce qui n a pas besoin de la machine :
# node, node_modules, l unite. L oneshot du premier boot devient alors ce qu il
# aurait toujours du etre - un rattrapage idempotent, pas le seul chemin.
if [ -x /opt/GSM/osmo-egprs-web/install-web-service.sh ]; then
    echo "  [web] install-web-service.sh (sans TLS ni demarrage : chroot)"
    WEB_NO_TLS=1 WEB_NO_START=1 bash /opt/GSM/osmo-egprs-web/install-web-service.sh \
        || echo "  [web] WARN: install-web-service.sh a echoue - le dashboard peut manquer dans l ISO"
else
    echo "  [web] WARN: install-web-service.sh absent de /opt/GSM/osmo-egprs-web"
fi

# ── VARIANTE DESKTOP : bureau, wireshark en fenetre, linphone ──────────────
# Place ICI, et pas ailleurs : APRES le gros apt-get install (les deps communes
# sont deja la, apt ne les reresout pas), mais AVANT update-initramfs - le
# bureau tire plymouth et des modules qui doivent entrer dans l initrd - et
# avant le apt-get clean qui vide le cache.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo "  [desktop] ubuntu-desktop-minimal + wireshark + linphone-desktop"

    # AVEC les recommends, et c est tout le piege. ubuntu-desktop-minimal est un
    # metapaquet dont presque TOUT est en Recommends. Installe avec le
    # --no-install-recommends que le reste de ce chroot utilise, il tire
    # gnome-shell et a peu pres rien autour : ni gdm3, ni session, ni terminal.
    # On obtient un ecran noir au boot, pas un bureau - et le message
    # d installation, lui, dit "done".
    #
    # linphone (sans suffixe) est un paquet de TRANSITION vide sur jammy ; le
    # client graphique s appelle linphone-desktop. wireshark tire wireshark-qt.
    # wmctrl + x11-utils (xdpyinfo) : launch.sh s en sert pour paver les quatre
    # fenetres en quarts d ecran. Sans eux le lancement marche toujours, mais
    # les fenetres se posent ou le gestionnaire veut.
    #
    # [2026-09-02] UN SEUL appel pour le bureau ET l installeur (calamares, grub
    # signe, outils de partitionnement - voir le bloc suivant pour le detail de
    # chaque paquet). Il y en avait deux : deux resolutions, deux lots de
    # telechargement, et le premier avalait son echec ("|| echo WARN") - une
    # image DESKTOP sans bureau sortait avec "done". Ici l echec ARRETE le
    # build : sans bureau ou sans installeur, cette image ne sert a rien.
    apt-fast install -y $APT_OPTS \
        ubuntu-desktop-minimal wireshark linphone-desktop snapd \
        vlc \
        wmctrl x11-utils zenity librsvg2-common \
        calamares squashfs-tools rsync dosfstools efibootmgr os-prober \
        cryptsetup cryptsetup-initramfs lvm2 pciutils ubuntu-drivers-common \
        conky-all fonts-dejavu \
        grub2-common grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-pc-bin \
        qml-module-qtquick2 qml-module-qtquick-layouts \
        qml-module-qtquick-window2 qml-module-qtquick-controls

    # ── AVAHI : PURGE ─────────────────────────────────────────────────────
    # avahi n est demande NULLE PART dans ce depot : il arrive en Recommends de
    # ubuntu-desktop-minimal, que l on installe volontairement AVEC ses
    # recommends (sans eux, pas de gdm3 ni de session - voir plus haut). Il
    # repart donc explicitement, apres coup.
    #
    # Pourquoi on n en veut pas sur un banc GSM : avahi-daemon diffuse en
    # permanence du mDNS sur 224.0.0.251:5353 et sur TOUTE interface qui
    # apparait - y compris apn0 et les veth du plan docker. Sur une capture
    # GSMTAP ou une trace SIP, ce bruit periodique se mele au trafic qu on
    # cherche a lire. Il pose aussi un .local qui prend le pas sur la
    # resolution, ce qui n a aucun interet ici : tout est adresse en dur.
    #
    # --purge, et libnss-mdns avec : le paquet seul desinstalle laisserait la
    # ligne "mdns4_minimal" dans /etc/nsswitch.conf, et chaque resolution
    # paierait alors un aller-retour vers un service absent.
    apt-fast purge -y $APT_OPTS avahi-daemon avahi-utils avahi-autoipd libnss-mdns 2>/dev/null \
        || echo "  [desktop] avahi deja absent"
    apt-fast autoremove -y $APT_OPTS 2>/dev/null || true
    # Ceinture et bretelles : si une dependance future le reinstalle, il ne
    # demarrera pas pour autant.
    systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    # ⚠️ GUILLEMETS DOUBLES, ET AUCUNE APOSTROPHE - COMMENTAIRES COMPRIS.
    # Ce bloc entier est passe a bash -c en quotes SIMPLES : la moindre
    # apostrophe y ferme la chaine. Ce sed en portait deux ; la sequence se
    # terminait donc au milieu du chroot et bash sortait sur
    #     bash: -c: line 270: syntax error: unexpected end of file
    # apres avoir execute tout ce qui precedait - le message ne designe donc
    # meme pas la bonne ligne. Et `bash -n build-iso.sh` ne peut PAS le voir :
    # pour lui, ce bloc n est qu une chaine de caracteres.
    # Les guillemets doubles passent sans encombre ; le depot utilise \047
    # ailleurs quand une apostrophe est vraiment necessaire.
    sed -i "s/[[:space:]]*mdns4_minimal[[:space:]]*\[NOTFOUND=return\]//; s/[[:space:]]*mdns4//" \
        /etc/nsswitch.conf 2>/dev/null || true
    echo "  [desktop] avahi purge (mDNS retire du banc)"

    # ── L INSTALLEUR : CALAMARES, ET POURQUOI PAS UBIQUITY ─────────────────
    # Ubiquity est l installeur d Ubuntu et il est dans jammy (22.04.15). Il ne
    # peut pas servir ici : il lit l etat du systeme live par CASPER, alors que
    # cette image demarre avec LIVE-BOOT, celui de Debian (voir la liste PKGS
    # plus haut : live-boot, live-boot-initramfs-tools, pas casper). Ubiquity ne
    # trouverait ni le squashfs ni le point de montage du medium, et sortirait
    # avant la premiere question - sans dire que la cause est l initramfs.
    #
    # Calamares ne suppose rien : on lui DIT ou est le squashfs. Sa
    # configuration vit dans le depot (installer/calamares/), elle est copiee
    # dans le rootfs HORS de ce chroot - ces fichiers sont pleins
    # d apostrophes, et ce script-ci est en quotes simples.
    #
    # Les dependances ne sont pas facultatives, chacune couvre une etape :
    #   squashfs-tools  unpackfs, qui deverse le systeme sur le disque
    #   dosfstools      la partition EFI, formatee en FAT
    #   efibootmgr      l entree de demarrage UEFI
    #   os-prober       les autres systemes, pour le menu GRUB
    #   pciutils        lspci : la detection de la carte NVIDIA (osmo-install
    #   ubuntu-drivers  et contextualprocess@nvidia) ; ubuntu-drivers choisit
    #   -common         le pilote nvidia-driver-5xx recommande pour la carte
    #   conky-all       le tableau de bord Conky du banc (configs/conky/,
    #   fonts-dejavu    autostart GNOME pose plus bas) - live et disque installe
    #   lvm2            LVM dans le partitionnement manuel de Calamares (groupes
    #                   de volumes, LUKS sur LVM) ; son hook initramfs suit
    #   cryptsetup      LUKS : la case "Chiffrer le systeme" de l installeur
    #   (+ -initramfs)  (partition.conf) ; l initrd de la cible doit savoir
    #                   ouvrir la racine, et c est cryptsetup-initramfs qui
    #                   pose le hook - sans lui, disque chiffre = boot mort
    #   qml-module-*    le diaporama pendant la copie
    # L echec de CETTE etape ne doit PAS etre avale. calamares tire une longue
    # chaine de dependances Qt/KDE ; si le miroir en manque une, apt sort en
    # erreur - et un "|| echo WARN" laissait alors construire une image DESKTOP
    # SANS installeur, exactement le "calamares marche pas" observe (ni binaire
    # ni /etc/calamares dans le squashfs livre). Ces paquets sont dans l unique
    # apt-get install du bureau, plus haut ; ici on VERIFIE que le binaire est
    # bien la, sinon on arrete le build.
    # On est DANS le chroot (ce bloc tourne sous "chroot ... bash -c") : le
    # binaire est donc a /usr/bin/calamares, pas sous $ROOTFS (variable absente
    # ici). set -e est actif ; l apt-get du bureau n a pas de "|| echo" donc un
    # echec avorte deja - ce test attrape le cas ou apt sort 0 mais sans poser le
    # binaire (paquet recommande saute, etc.).
    if [ ! -x /usr/bin/calamares ]; then
        echo "ERREUR: calamares absent du rootfs apres apt-get - build DESKTOP interrompu." >&2
        echo "        (dependance Qt/KDE manquante au miroir ? relancer avec un cache .deb)" >&2
        exit 1
    fi

    # ── LES OUTILS QUE CALAMARES APPELLE, ET QU IL NE TIRE PAS ──────────────
    # unpackfs ne fait pas la copie lui-meme : il lance unsquashfs, puis RSYNC.
    # Le paquet calamares ne depend d aucun des deux. Sans rsync, l installeur
    # va jusqu au bout du partitionnement, puis s arrete sur
    # "rsync a echoue avec le code d erreur 127" - 127, c est "commande
    # introuvable", et rien dans le message ne le dit. Le disque cible reste
    # partitionne et vide. On verifie donc a la construction, pas sur le banc.
    for _t in rsync unsquashfs; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - unpackfs echouerait a l installation." >&2
            exit 1
        fi
    done

    # ── GRUB DOIT ETRE DANS LA CIBLE, PAS SEULEMENT SUR LA MACHINE DE BUILD ──
    # ISO_HOST_PKGS pose grub-efi-amd64-bin sur l HOTE, pour fabriquer l image
    # amorcable. Le module bootloader de calamares, lui, lance grub-install DANS
    # LE SYSTEME INSTALLE - c est-a-dire dans ce rootfs. Le rootfs n avait que
    # grub-common (grub-mkconfig, grub-probe) et PAS grub2-common, qui fournit
    # grub-install : l installation allait jusqu au bout de la copie, puis
    # s arretait sur
    #     "grub-install --target=x86_64-efi ... a renvoye le code d erreur 127"
    # 127 = commande introuvable, sur un disque deja partitionne et rempli.
    #
    # Les binaires SIGNES vont avec : bootloader.conf pose
    # efiBootloaderId=ubuntu precisement pour que le systeme installe reste
    # amorcable en Secure Boot, ce qui suppose shimx64 et grubx64 signes ici.
    for _t in grub-install grub-mkconfig grub-probe; do
        if ! command -v "$_t" >/dev/null 2>&1; then
            echo "ERREUR: $_t absent du rootfs - le module bootloader echouerait." >&2
            exit 1
        fi
    done
    for _f in /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
              /usr/lib/shim/shimx64.efi.signed; do
        if [ ! -e "$_f" ]; then
            echo "ERREUR: $_f absent - le systeme installe ne demarrerait pas en Secure Boot." >&2
            exit 1
        fi
    done

    # ── FIREFOX : LE SNAP, PAS LE DEB ──────────────────────────────────────
    # Sur jammy, "apt install firefox" (comme "apt install chromium-browser")
    # pose un paquet de TRANSITION vide dont le postinst appelle
    # "snap install ...". Dans un chroot, snapd ne tourne pas : le postinst
    # echoue, apt le signale a peine, et l image sort avec un binaire qui
    # n existe pas. On ne compte donc pas sur apt.
    #
    # On ne peut pas non plus "snap install" ici - meme raison. Ce qui marche
    # dans un chroot, c est TELECHARGER (snap download parle au magasin en
    # direct, il n a pas besoin du demon) et laisser l installation au premier
    # demarrage, quand snapd tourne pour de bon. Les .snap et leurs assertions
    # voyagent dans l image : l installation se fait alors HORS LIGNE, ce qui
    # compte pour un banc qui n a pas toujours Internet.
    # L unite qui les pose (osmo-firefox-snap.service) est ecrite HORS de ce
    # chroot : le script y est en quotes simples, une apostrophe de plus et
    # tout ce qui suit change de sens.
    apt-fast purge -y firefox chromium-browser 2>/dev/null || true
    mkdir -p /var/lib/osmo-snaps
    _snap_ok=1

    # ── LES DEPENDANCES SE LISENT DANS LE SNAP, ELLES NE SE DEVINENT PAS ────
    # L ancienne liste etait ecrite en dur : gtk-common-themes, gnome-42-2204,
    # et le navigateur. Elle etait FAUSSE, et l image sortait sans navigateur.
    # firefox 15x declare "base: core24" et reclame, par ses interfaces de
    # contenu, mesa-2404 (gpu-2404) et gnome-46-2404 - gnome-42-2204 est la
    # plateforme du monde core22, celle d AVANT : 557 Mo embarques que rien ne
    # monte. Sans core24 ni mesa-2404, "snap install firefox.snap" echoue hors
    # ligne, et le lanceur repond "firefox introuvable".
    #
    # On lit donc "base:" et les "default-provider:" DANS le .snap telecharge,
    # au lieu de les recopier : la prochaine bascule de base (core26...) se
    # fera toute seule. cups est volontairement ecarte - c est un fournisseur
    # d impression optionnel de 200 Mo, son absence ne bloque pas le demarrage.
    ( cd /var/lib/osmo-snaps && snap download firefox --basename=firefox ) \
        || { echo "  [desktop] WARN: snap download firefox a echoue"; _snap_ok=0; }

    #
    # Pas une seule apostrophe ici : ce bloc tourne dans un bash -c en quotes
    # simples (voir plus haut) - les programmes awk sont donc en guillemets,
    # avec \$2 echappe pour qu il arrive intact a awk.
    _base=""; _providers=""
    if [ -s /var/lib/osmo-snaps/firefox.snap ] && command -v unsquashfs >/dev/null; then
        unsquashfs -cat /var/lib/osmo-snaps/firefox.snap meta/snap.yaml \
            > /tmp/firefox-snap.yaml 2>/dev/null || true
        # || true : ce chroot tourne sous set -e, et grep qui ne retient rien
        # sort avec 1 - une liste vide ferait echouer la construction entiere.
        _base=$(awk "/^base:[[:space:]]/{print \$2; exit}" /tmp/firefox-snap.yaml) || true
        _providers=$(awk "/default-provider:[[:space:]]/{print \$2}" /tmp/firefox-snap.yaml \
                     | sort -u | grep -vx cups) || true
        rm -f /tmp/firefox-snap.yaml
    fi
    [ -n "$_base" ] || _base=core24
    [ -n "$_providers" ] || _providers="mesa-2404 gnome-46-2404 gtk-common-themes"
    echo "  [desktop] firefox : base=$_base, contenu=$(echo $_providers)"

    # snapd en tete : sur une base core2x, les snaps montent /snap/snapd et
    # refusent de demarrer sans lui.
    rm -f /var/lib/osmo-snaps/ordre; touch /var/lib/osmo-snaps/ordre
    for _sn in snapd "$_base" $_providers; do
        ( cd /var/lib/osmo-snaps && snap download "$_sn" --basename="$_sn" ) \
            && echo "$_sn" >> /var/lib/osmo-snaps/ordre \
            || { echo "  [desktop] WARN: snap download $_sn a echoue"; _snap_ok=0; }
    done
    # En dernier, et jamais en "[ ... ] && ..." : sous set -e, un test faux
    # en fin de bloc arreterait le chroot net.
    if [ -s /var/lib/osmo-snaps/firefox.snap ]; then
        echo firefox >> /var/lib/osmo-snaps/ordre
    fi
    systemctl enable osmo-firefox-snap 2>/dev/null || true
    if [ "$_snap_ok" = "1" ]; then
        echo "  [desktop] Firefox : snap embarque ($(du -sh /var/lib/osmo-snaps 2>/dev/null | cut -f1)), installe au premier boot"
    else
        echo "  [desktop] Firefox : snap NON embarque - installation depuis le magasin au premier boot (reseau requis)"
    fi

    systemctl set-default graphical.target

    # ── AUDIO DE SESSION : PIPEWIRE SUR NOBLE ──────────────────────────────
    # ubuntu-desktop-minimal de noble tire pipewire-pulse et wireplumber ; le
    # paquet pulseaudio reste installe (verifie par simulation apt le
    # 2026-09-03 : les deux cohabitent, rien n est retire) parce que le BANC
    # en a besoin en mode SYSTEME (gapk -> plugin ALSA pulse -> demon systeme,
    # unite ecrite plus bas dans ce script). Mais ses unites de SESSION
    # disputeraient le socket utilisateur a pipewire-pulse : on les masque,
    # la session GNOME garde PipeWire, comme sur tout noble.
    if [ "$_S" = "noble" ]; then
        systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
        echo "  [desktop] audio de session : pipewire-pulse (pulseaudio ne sert que le mode systeme du banc)"
    fi

    # ── NetworkManager : ACTIF ──────────────────────────────────────────────
    # Il etait masque pour laisser systemd-networkd seul maitre des interfaces.
    # Le cout etait un bureau sans reseau utilisable a la main : pas de choix de
    # Wi-Fi, pas de VPN, pas de bascule d interface - il fallait editer un
    # .network et redemarrer un service pour changer de carte.
    #
    # Les deux cohabitent a condition que chacun sache ce qui ne lui appartient
    # pas. systemd-networkd garde les interfaces du banc (apn0, les tun/veth du
    # coeur paquet) ; NetworkManager prend les cartes physiques. La regle qui le
    # dit - /etc/NetworkManager/conf.d/10-osmo-networkd.conf - est ecrite HORS
    # de ce chroot, dont le script est en quotes simples. Sans elle, les deux se
    # disputent la meme carte et c est l adresse qui saute au milieu d une
    # session M3UA.
    systemctl unmask NetworkManager NetworkManager-wait-online 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true

    # ── Autologin ──────────────────────────────────────────────────────────
    # ROOT, directement : il n y a plus de compte "osmocom" (supprime plus
    # haut - c etait un alias d UID 0 qui se faisait passer pour un compte
    # ordinaire). GDM, lui, refuse toute session pour l uid 0, et la regle
    # n est pas dans gdm3.conf mais dans PAM :
    #     auth required pam_succeed_if.so user != root quiet_success
    # Sans la neutraliser, autologin ou pas, on retombe sur l ecran de connexion
    # et AUCUN mot de passe ne passe - y compris le bon.
    sed -i "/pam_succeed_if.so user != root quiet_success/s/^/#/" \
        /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin 2>/dev/null || true
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<GDM
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=root
# X11 impose : sous VirtualBox/QEMU, la session Wayland de GNOME 42 tombe sur
# le pilote llvmpipe et rend un bureau inutilisable, quand elle demarre.
WaylandEnable=false
GDM

    # ── LA CONTREPARTIE DE LA SESSION ROOT : PIPEWIRE ───────────────────────
    # [2026-08-31] Le screencast de GNOME (Ctrl+Alt+Shift+R) ne faisait RIEN.
    # Seul le journal le disait :
    #     gnome-shell -> org.gnome.Shell.Screencast
    #     gjs: Failed to start recorder: Failed to start screen cast:
    #          Couldn t connect pipewire context
    # L enregistrement d ecran passe OBLIGATOIREMENT par PipeWire, et les unites
    # livrees par upstream portent ConditionUser=!root - pipewire.socket:3 et
    # pipewire.service:17. La session ouverte en root juste au-dessus n avait
    # donc jamais /run/user/0/pipewire-0, et gnome-shell aucun contexte ou
    # pousser ses images.
    #
    # C est la contrepartie directe du choix d AutomaticLogin=root : elle se
    # corrige ICI, a cote de lui, et pas ailleurs.
    #
    # Une affectation VIDE remet la liste de conditions a zero - c est la facon
    # systemd d annuler une condition heritee ; un "!=root" ne le ferait pas.
    # /etc/systemd/user/ vaut pour toutes les sessions, quel que soit le compte.
    #
    # RESERVE : PipeWire en root n est pas supporte upstream. wireplumber n etant
    # pas installe sur l image, PipeWire ne decouvre AUCUN peripherique audio et
    # ne dispute donc pas les cartes au `pulseaudio --system` du banc. Installer
    # wireplumber romprait cet equilibre : a ne pas faire sans le mesurer.
    for _pwu in pipewire.socket pipewire.service; do
        mkdir -p "/etc/systemd/user/${_pwu}.d"
        # GUILLEMETS DOUBLES : ce bloc est en quotes simples. Avec des
        # apostrophes, le printf recevait [Unit]nConditionUser=n sans aucun
        # retour a la ligne - le drop-in etait illisible et le correctif mort.
        printf "[Unit]\nConditionUser=\n" > "/etc/systemd/user/${_pwu}.d/10-allow-root.conf"
    done
    unset _pwu

    # L assistant de premier demarrage (langue, comptes en ligne, sondage) se
    # rejoue a CHAQUE boot sur un live sans persistance : il faut le desarmer,
    # sinon il est la premiere - et longtemps la seule - chose a l ecran.
    rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop
    for h in /root; do
        mkdir -p "$h/.config" && echo yes > "$h/.config/gnome-initial-setup-done"
    done

    # Verrouillage d ecran et mise en veille : desarmes. Une image de banc reste
    # affichee pendant qu on regarde une capture ou un appel courir ; et sur un
    # live, l ecran verrouille se rouvre avec un mot de passe que personne n a
    # choisi. La disposition clavier suit celle demandee au build (--kb).
    # printf et pas un heredoc : les valeurs gschema portent des apostrophes, et
    # ce chroot tourne dans un bash -c en quotes simples - d ou les \047.
    printf "[org.gnome.desktop.session]\nidle-delay=uint32 0\n\n[org.gnome.desktop.screensaver]\nlock-enabled=false\nidle-activation-enabled=false\n\n[org.gnome.settings-daemon.plugins.power]\nsleep-inactive-ac-type=\047nothing\047\nsleep-inactive-battery-type=\047nothing\047\n\n[org.gnome.desktop.input-sources]\nsources=[(\047xkb\047,\047%s\047)]\n" \
        "${OSMO_ISO_KB:-fr}" > /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    # ── Fond d ecran GSM LAB ────────────────────────────────────────────
    # PNG 1920x1080 fige au build (configs/gsm-lab-wallpaper.png, rendu depuis
    # la page bbaranoff.github.io), pose comme fond GNOME par DEFAUT de session
    # (live sans persistance : il faut le defaut de schema, pas un reglage
    # utilisateur). zoom : l image est en 16:9, elle remplit sans deformer.
    _WP=/opt/GSM/osmo-operator/configs/gsm-lab-wallpaper.png
    if [ -f "$_WP" ]; then
        install -Dm644 "$_WP" /usr/share/backgrounds/gsm-lab-wallpaper.png
        printf "\n[org.gnome.desktop.background]\npicture-uri=\047file:///usr/share/backgrounds/gsm-lab-wallpaper.png\047\npicture-uri-dark=\047file:///usr/share/backgrounds/gsm-lab-wallpaper.png\047\npicture-options=\047zoom\047\nprimary-color=\047#0d1b2a\047\n" \
            >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
        echo "  [desktop] fond d ecran GSM LAB pose"
    else
        echo "  [desktop] WARN: $_WP absent -- fond d ecran GNOME par defaut"
    fi
    # ── DOCK : LES FAVORIS DU BANC ──────────────────────────────────────
    # Meme raison que le fond d ecran : sur un live sans persistance, un
    # reglage utilisateur ne survit pas au boot. C est donc le DEFAUT DE SCHEMA
    # qu il faut poser, pas un gsettings dans une session.
    #
    # L ordre est celui du banc de reference, gauche a droite dans le dock :
    #   firefox · fichiers · aide · osmo-launch · deka · claude · linphone ·
    #   osmo-multi · wireshark
    #
    # Une entree qui designe un .desktop absent est IGNOREE par GNOME Shell,
    # sans erreur ni trou dans le dock : la liste peut donc citer deka.desktop
    # et claude.desktop meme sur une image ou ils ne sont pas installes.
    # firefox_firefox.desktop est la forme SNAP (le paquet deb serait
    # firefox.desktop) : c est le snap qui est installe ici.
    printf "\n[org.gnome.shell]\nfavorite-apps=[\047firefox_firefox.desktop\047, \047org.gnome.Nautilus.desktop\047, \047yelp.desktop\047, \047osmo-launch.desktop\047, \047osmo-dsp.desktop\047, \047deka.desktop\047, \047claude.desktop\047, \047linphone.desktop\047, \047osmo-multi.desktop\047, \047org.wireshark.Wireshark.desktop\047]\n" \
        >> /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    echo "  [desktop] favoris du dock poses (10 entrees)"

    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true

    echo "  [desktop] GNOME pret : autologin root, X11, NetworkManager actif, Firefox snap"
fi

# ── Les certificats : verification finale ───────────────────────────────────
# Le magasin a ete regenere EN TETE de ce chroot (update-ca-certificates
# --fresh, avant le premier acces TLS). On verifie seulement qu il est plein.
if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
    echo "  certificats : $(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt) autorites dans /etc/ssl/certs"
else
    echo "  WARN: /etc/ssl/certs/ca-certificates.crt vide - le TLS echouera dans l image"
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

# deb-src.list part avec le reste : les index Sources qu il fait telecharger
# pesent ~80 Mo, et sur un live en toram ils sont repris en RAM au premier
# "apt-get update" du boot. Ils n ont servi qu au build-dep gnuradio ci-dessus,
# qui est deja passe - et plus rien n installe de paquet au demarrage.
# Pas de "apt-get clean" quand /var/cache/apt/archives est le cache de l hote
# (bind, voir plus haut) : on ne retire que les index et les caches binaires.
if [ "${ISO_APT_CACHE_BOUND:-0}" = "1" ]; then
    rm -f /var/cache/apt/*.bin; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
else
    apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
fi
rm -f /etc/apt/sources.list.d/deb-src.list
'


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
