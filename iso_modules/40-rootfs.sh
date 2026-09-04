#!/bin/bash
# iso_modules/40-rootfs.sh - etape 4 : debootstrap (ou rootfs herite)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 4 : Bootstrap rootfs minimal ─────────────────────────────────────
# ── Cache des .deb (accelere les rebuilds) ─────────────────────────────────
# ISO_DEB_CACHE=<dir absolu> : cache PERSISTANT que debootstrap reutilise
# (--cache-dir) au lieu de re-telecharger la base a chaque build (les lignes
# "I: Retrieving / I: Validating"). Vide ou --no-cache -> pas de cache.
ISO_DEB_CACHE="${ISO_DEB_CACHE:-$HOME/.cache/osmo-iso-debs}"
DEBOOTSTRAP_CACHE_OPT=""
if [ -n "$ISO_DEB_CACHE" ] && [ -z "$NO_CACHE" ]; then
    # Le cache est PAR ARCHITECTURE (arm64 dans son propre dossier) : un .deb
    # amd64 et son homonyme arm64 portent le meme nom de fichier sauf l arch, et
    # debootstrap ne verifie pas l architecture de ce qu il reprend du cache.
    _DBS_CACHE="$ISO_DEB_CACHE/debootstrap"
    [ "${ISO_ARCH:-amd64}" = "amd64" ] || _DBS_CACHE="$ISO_DEB_CACHE/debootstrap-$ISO_ARCH"
    mkdir -p "$_DBS_CACHE"
    DEBOOTSTRAP_CACHE_OPT="--cache-dir=$_DBS_CACHE"
    echo -e "  ${GREEN}cache .deb debootstrap : $_DBS_CACHE${NC}"
fi
# ── Rootfs HERITE d une passe precedente (--all : lite et desktop reprennent la
# normale) ou debootstrap de zero. Un rootfs herite est complet et configure :
# les etapes 5 (injection) sont sautees, les autres rejouent - elles ecrivent
# leurs fichiers, apt ne pose que le delta.
OSMO_ISO_INHERITED=0
if [ -n "${OSMO_ISO_ROOTFS_FROM:-}" ]; then
    [ -d "$OSMO_ISO_ROOTFS_FROM" ] || { echo -e "${RED}Rootfs herite introuvable : ${OSMO_ISO_ROOTFS_FROM}${NC}" >&2; exit 1; }
    rmdir "$ROOTFS" 2>/dev/null || true
    case "${OSMO_ISO_ROOTFS_MODE:-move}" in
        copy)
            echo -e "${GREEN}[4/9] Rootfs repris (COPIE) de ${CYAN}${OSMO_ISO_ROOTFS_FROM}${NC}..."
            # --reflink=auto : instantane sur btrfs/xfs, copie ordinaire ailleurs.
            cp -a --reflink=auto "$OSMO_ISO_ROOTFS_FROM" "$ROOTFS" ;;
        *)
            echo -e "${GREEN}[4/9] Rootfs repris (deplace) de ${CYAN}${OSMO_ISO_ROOTFS_FROM}${NC}..."
            mv "$OSMO_ISO_ROOTFS_FROM" "$ROOTFS" ;;
    esac
    OSMO_ISO_INHERITED=1
    echo -e "  ${GREEN}✓${NC} rootfs herite $(du -sh "$ROOTFS"|cut -f1) - debootstrap et injection sautes"
else
    # Le script debootstrap de la suite : sur un hote jammy, le paquet ne connait
    # pas noble. Les scripts Ubuntu sont tous le meme (gutsy) : on lie.
    _DBS=/usr/share/debootstrap/scripts
    if [ -d "$_DBS" ] && [ ! -e "$_DBS/$ISO_SUITE" ] && [ -e "$_DBS/gutsy" ]; then
        ln -s gutsy "$_DBS/$ISO_SUITE"
        echo -e "  ${YELLOW}debootstrap ne connaissait pas ${ISO_SUITE} : script gutsy lie${NC}"
    fi
    echo -e "${GREEN}[4/9] debootstrap $ISO_SUITE ($ISO_UBUNTU, ${ISO_ARCH}, minimal)...${NC}"
    # arm64 sur hote x86 : --foreign ne fait que TELECHARGER et DEPAQUETER (rien
    # ne s execute) ; la seconde etape configure les paquets dans le chroot, ou
    # qemu-aarch64-static, copie dans le rootfs, execute les binaires aarch64
    # via binfmt. Sur amd64 le drapeau est vide et debootstrap fait tout d un coup.
    _DBS_FOREIGN=""
    if [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then _DBS_FOREIGN="--foreign"; fi
    # zstd : noble met COMPRESS=zstd dans initramfs.conf, mais minbase ne pose
    # pas le binaire. Sans lui, mkinitramfs (declenche par linux-image dans le
    # chroot) avertit "No zstd in PATH, using gzip" et sort un initrd gzip, plus
    # gros et plus lent a ouvrir. Il doit etre la AVANT le kernel, donc ici.
    debootstrap $DEBOOTSTRAP_CACHE_OPT --arch="$ISO_ARCH" $_DBS_FOREIGN --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,zstd,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
        "$ISO_SUITE" "$ROOTFS" "$ISO_MIRROR"
    if [ -n "$_DBS_FOREIGN" ]; then
        install -m755 "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/qemu-aarch64-static"
        echo -e "  ${CYAN}debootstrap --second-stage (aarch64 sous qemu-user, plus lent)...${NC}"
        chroot "$ROOTFS" /debootstrap/debootstrap --second-stage >"$WORK/debootstrap-2nd.log" 2>&1 \
            || { echo -e "${RED}debootstrap --second-stage a echoue (voir $WORK/debootstrap-2nd.log)${NC}" >&2; tail -20 "$WORK/debootstrap-2nd.log" >&2; exit 1; }
    fi
    echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
