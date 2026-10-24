#!/bin/bash
# armbian/build-armbian.sh - l image SD arm64 par le framework OFFICIEL github.com/armbian/build
#
# [2026-10-20] Jusqu ici l image Pi sortait de build-iso.sh --arm : debootstrap, noyau et BSP rpi4b
# pris sur apt.armbian.com, partition firmware et .img assembles a la main (iso_modules/82-arm-natif,
# 92-rpi-image). Ici c est Armbian lui-meme qui fabrique le noyau, le BSP, le u-boot/firmware, le
# rootfs et l image ; nous ne faisons qu y POSER LA PILE, par le mecanisme prevu pour cela :
#     userpatches/customize-image.sh   execute dans le chroot de l image (sous qemu-user sur un hote x86)
#     userpatches/overlay/             monte en /tmp/overlay dans ce chroot
#
# La pile vient de l IMAGE DOCKER arm64 du projet (Dockerfile, build.sh --arch=arm64 : osmocom-nitb:arm64,
# ou la base publiee ghcr.io/<depot>/osmocom-nitb:base-arm64-<empreinte>) : exactement ce que
# iso_modules/50-injection-image.sh prend pour l ISO - les .deb du build (osmo-build-*), /usr/local,
# /opt/GSM, /etc/osmocom, les unites systemd. Elle est exportee dans l overlay par docker cp.
# Ce qu un hote x86 ne peut pas produire (toast, lanceur qosmo, c54x_exe/grgsm_exe, .deb du banc) est
# compile DANS le chroot par customize-image.sh, comme le faisait 82-arm-natif.sh.
#
#   sudo ./build-armbian.sh                       rpi4b, branche current, noble : clone, overlay, compile
#   sudo ./build-armbian.sh --prepare             tout sauf compile.sh (verifier userpatches/ et l overlay)
#   sudo ./build-armbian.sh --no-stack            une Armbian nue (pas d overlay, pas de customize)
#   sudo ./build-armbian.sh --board=orangepi5 --branch=edge --release=noble
#   sudo ./build-armbian.sh --image=osmocom-nitb:arm64      l image Docker qui fournit la pile
#
# [2026-10-24] LES CIBLES : --board= prend une carte, une liste (virgules) ou un groupe :
#   rpi4                  rpi4b (Raspberry Pi 4)
#   opi5                  TOUTES les Orange Pi 5 d Armbian : orangepi5, orangepi5b, orangepi5-plus,
#                         orangepi5pro, orangepi5-max, orangepi5-ultra (la Max et l Ultra ont chacune
#                         leur fichier de carte : ce ne sont pas des variantes de orangepi5.conf)
#   all                   rpi4 + opi5
# Une image par carte, construites l une apres l autre (meme overlay). La branche noyau est choisie
# PAR CARTE : --branch si la carte la propose (KERNEL_TARGET de config/boards/<carte>.*), sinon
# current, sinon la premiere qu elle propose (orangepi5b n a que edge et vendor). Les cartes .csc
# (communautaires : 5b, 5 Pro, 5 Max, 5 Ultra) se construisent avec EXPERT=yes.
#   --desktop             bureau GNOME (DESKTOP_ENVIRONMENT=gnome, DESKTOP_TIER=minimal, via
#                         armbian/configng) + le bureau du banc (fond, Conky, encart, icones, c123)
#   --banc / --multi      osmo-banc.service / osmo-multi.service actives au boot
#   --build-image         sans image Docker arm64 de la pile, la construire (build.sh --arch=arm64)
#                         au lieu d echouer
#   --armbian-dir=/chemin   le clone d armbian/build         [/opt/GSM/armbian-build]
#   --update                git pull du clone avant de construire
#   --install-deps          apt install qemu-user-static binfmt-support si l aarch64 n est pas emulable
#   --dry-run               affiche ce qui serait fait
#
# Prerequis hote : docker (compile.sh se met lui-meme dans un conteneur sur un hote non Ubuntu/x86),
# git, et l emulation aarch64 (qemu-user-static + binfmt) pour que le chroot de customize-image.sh
# tourne sur un hote x86. Sur un hote arm64 rien n est emule.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

BOARD=rpi4b; BRANCH=current; RELEASE=noble
ARMBIAN_DIR="${ARMBIAN_DIR:-/opt/GSM/armbian-build}"
ARMBIAN_GIT="${ARMBIAN_GIT:-https://github.com/armbian/build}"
IMAGE=""; PREPARE=0; NO_STACK=0; UPDATE=0; INSTALL_DEPS=0; DRY=0
DESKTOP=0; BANC=0; MULTI=0; BUILD_IMAGE=0; BRANCH_GIVEN=0
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
for arg in "$@"; do
    case "$arg" in
        --board=*)       BOARD="${arg#*=}" ;;
        --branch=*)      BRANCH="${arg#*=}"; BRANCH_GIVEN=1 ;;
        --desktop)       DESKTOP=1 ;;
        --banc)          BANC=1 ;;
        --multi)         MULTI=1 ;;
        --build-image)   BUILD_IMAGE=1 ;;
        --release=*)     RELEASE="${arg#*=}" ;;
        --image=*)       IMAGE="${arg#*=}" ;;
        --armbian-dir=*) ARMBIAN_DIR="${arg#*=}" ;;
        --prepare)       PREPARE=1 ;;
        --no-stack)      NO_STACK=1 ;;
        --update)        UPDATE=1 ;;
        --install-deps)  INSTALL_DEPS=1 ;;
        --dry-run)       DRY=1 ;;
        -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
        *) echo "option inconnue : $arg" >&2; sed -n '2,46p' "$0" >&2; exit 2 ;;
    esac
done
say()  { printf '\033[1;32m[armbian]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[armbian] !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[armbian] ECHEC\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  + $*"; else "$@"; fi; }

# ── 1. l hote ────────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || [ "$DRY" = 1 ] || die "a lancer en root (compile.sh d Armbian l exige) : sudo $0 $*"
command -v git >/dev/null    || die "git absent"
command -v docker >/dev/null || warn "docker absent : compile.sh ne pourra pas se conteneuriser (il faut alors un hote Ubuntu avec ses dependances)"
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "$HOST_ARCH" != arm64 ] && [ "$NO_STACK" = 0 ]; then
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        if [ "$INSTALL_DEPS" = 1 ]; then
            say "emulation aarch64 absente : apt install qemu-user-static binfmt-support"
            run apt-get install -y qemu-user-static binfmt-support
        elif [ "$DRY" = 1 ] || [ "$PREPARE" = 1 ]; then
            warn "pas d emulation aarch64 sur cet hote $HOST_ARCH : avant compile.sh, sudo $REPO/build.sh --arm (pose tous les paquets hote) ou --install-deps"
        else
            die "pas d emulation aarch64 sur cet hote $HOST_ARCH (/proc/sys/fs/binfmt_misc/qemu-aarch64 absent) : customize-image.sh ne pourrait pas tourner dans le chroot arm64. sudo $REPO/build.sh --arm pose tous les paquets hote (ou --install-deps)"
        fi
    fi
fi
OPI5_BOARDS="orangepi5 orangepi5b orangepi5-plus orangepi5pro orangepi5-max orangepi5-ultra"
BOARDS=""
for b in ${BOARD//,/ }; do
    case "$b" in
        rpi4|rpi4b) BOARDS="$BOARDS rpi4b" ;;
        opi5|orangepi5-all) BOARDS="$BOARDS $OPI5_BOARDS" ;;
        all)        BOARDS="$BOARDS rpi4b $OPI5_BOARDS" ;;
        *)          BOARDS="$BOARDS $b" ;;
    esac
done
BOARDS=$(echo $BOARDS | tr ' ' '\n' | awk '!vu[$0]++' | tr '\n' ' ')
say "hote $HOST_ARCH ($(nproc) coeurs) ; cartes : $BOARDS; RELEASE=$RELEASE ; bureau=$([ "$DESKTOP" = 1 ] && echo gnome || echo non) ; clone $ARMBIAN_DIR"

# ── 2. le framework ──────────────────────────────────────────────────────────
if [ ! -f "$ARMBIAN_DIR/compile.sh" ]; then
    say "clone de $ARMBIAN_GIT (branche main, depth 1) -> $ARMBIAN_DIR"
    run git clone --depth 1 --branch main "$ARMBIAN_GIT" "$ARMBIAN_DIR"
elif [ "$UPDATE" = 1 ]; then
    say "mise a jour du clone"
    run git -C "$ARMBIAN_DIR" pull --ff-only
fi
# board_file CARTE : le fichier de carte d Armbian (.conf supportee, .csc communautaire, .wip)
board_file() {
    local e
    for e in conf csc wip tvb eos; do
        [ -f "$ARMBIAN_DIR/config/boards/$1.$e" ] && { echo "$ARMBIAN_DIR/config/boards/$1.$e"; return 0; }
    done
    return 1
}
# board_branch CARTE : --branch si la carte la propose, sinon current, sinon sa premiere branche
board_branch() {
    local f targets
    f=$(board_file "$1") || { echo "$BRANCH"; return; }
    targets=$(sed -n 's/^KERNEL_TARGET="\(.*\)".*/\1/p' "$f" | head -1)
    [ -n "$targets" ] || { echo "$BRANCH"; return; }
    case ",$targets," in
        *",$BRANCH,"*) echo "$BRANCH" ;;
        *",current,"*) [ "$BRANCH_GIVEN" = 1 ] && warn "$1 : pas de branche $BRANCH ($targets), current a la place" >&2; echo current ;;
        *) warn "$1 : pas de branche $BRANCH$([ "$BRANCH" = current ] || echo " ni current") ($targets), ${targets%%,*} a la place" >&2; echo "${targets%%,*}" ;;
    esac
}
if [ "$DRY" = 0 ]; then
    for b in $BOARDS; do
        board_file "$b" >/dev/null || die "carte inconnue d Armbian : $b (voir $ARMBIAN_DIR/config/boards/)"
    done
fi

# ── 3. userpatches : le script de personnalisation et l overlay ──────────────
UP="$ARMBIAN_DIR/userpatches"
OV="$UP/overlay/osmo"
run install -d "$UP" "$OV"
if [ "$NO_STACK" = 1 ]; then
    say "--no-stack : pas de customize-image.sh (Armbian nue)"
    run rm -f "$UP/customize-image.sh"
else
    run install -m755 "$HERE/userpatches/customize-image.sh" "$UP/customize-image.sh"
    say "userpatches/customize-image.sh pose"
fi

# ── 4. l overlay : la pile, exportee de l image Docker arm64 ─────────────────
if [ "$NO_STACK" = 0 ]; then
    if [ -z "$IMAGE" ]; then
        if docker image inspect osmocom-nitb:arm64 >/dev/null 2>&1; then
            IMAGE=osmocom-nitb:arm64
        else
            KEY=$(cd "$REPO" && git ls-files -- Dockerfile packaging configs scripts services helpers opt-gsm tools patches | sort | xargs sha256sum | sha256sum | cut -c1-16)
            REMOTE=$(cd "$REPO" && git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')
            GHCR="ghcr.io/${REMOTE:-bbaranoff/osmo-operator}/osmocom-nitb:base-arm64-$KEY"
            if [ "$DRY" = 0 ] && docker pull --platform linux/arm64 "$GHCR" >/dev/null 2>&1; then
                IMAGE="$GHCR"
            elif [ "$DRY" = 1 ]; then
                warn "aucune image Docker arm64 de la pile en local ($GHCR non testee en dry-run) : il faudra d abord sudo $REPO/build.sh --arch=arm64"
                IMAGE="osmocom-nitb:arm64"
            elif [ "$BUILD_IMAGE" = 1 ]; then
                say "aucune image Docker arm64 de la pile : build.sh --arch=arm64 (emule sur un hote x86 : ~10 h au premier build)"
                bash "$REPO/build.sh" --arch=arm64 || die "build.sh --arch=arm64 a echoue"
                if docker image inspect osmocom-nitb:arm64 >/dev/null 2>&1; then IMAGE=osmocom-nitb:arm64; else IMAGE=osmocom-nitb; fi
            else
                die "aucune image Docker arm64 de la pile : ni osmocom-nitb:arm64 en local, ni $GHCR. Sur cet hote : sudo $REPO/build.sh --arch=arm64 (emule, ~10 h au premier build) ou --build-image, ou lancer docker-arm.yml sur GitHub (runner arm64 natif) puis relancer ici."
            fi
        fi
    fi
    if [ "$DRY" = 0 ]; then
        ARCH=$(docker image inspect --format '{{.Architecture}}' "$IMAGE" 2>/dev/null || echo "?")
        [ "$ARCH" = arm64 ] || die "l image $IMAGE est $ARCH, pas arm64"
    fi
    say "pile : image Docker $IMAGE -> overlay $OV"
    if [ "$DRY" = 1 ]; then
        echo "  + docker create/cp -> $OV/debs/ et $OV/rootfs/ (usr/local, opt/GSM, opt/node, root/.env, etc/osmocom, etc/asterisk, lib/systemd/system)"
    else
        rm -rf "$OV"; install -d "$OV/debs" "$OV/rootfs/usr" "$OV/rootfs/opt" "$OV/rootfs/root" "$OV/rootfs/etc" "$OV/rootfs/lib/systemd/system"
        CID=$(docker create --platform linux/arm64 "$IMAGE" /bin/true)
        trap 'docker rm "$CID" >/dev/null 2>&1 || true' EXIT
        # les .deb du build : ceux de la suite cible, cache de l hote d abord, sinon ceux de l image
        cp -f "$DEB_CACHE"/osmo-build-*"~${RELEASE}_arm64.deb" "$OV/debs/" 2>/dev/null || true
        if ! ls "$OV/debs"/*.deb >/dev/null 2>&1; then
            docker cp "$CID:/var/cache/osmo-debs/." "$OV/debs/" 2>/dev/null || true
            find "$OV/debs" -name '*.deb' ! -name "*~${RELEASE}_arm64.deb" -delete 2>/dev/null || true
        fi
        NDEBS=$(find "$OV/debs" -name '*.deb' | wc -l)
        # L overlay est un ARBRE (rootfs/), recopie tel quel sur / par customize-image.sh : /usr/local
        # (binaires, libs), /opt/GSM sans les arbres que les .deb posent deja (meme liste que
        # 50-injection-image.sh), /opt/node, l environnement de root, /etc/osmocom, /etc/asterisk, les unites.
        docker cp "$CID:/usr/local" "$OV/rootfs/usr/"
        EXCL=()
        if [ "$NDEBS" -gt 0 ]; then
            for t in osmocom-bb qosmo c54x_exe grgsm_exe qemu-install firmware; do EXCL+=("--exclude=GSM/$t" "--exclude=GSM/$t/*"); done
        fi
        docker cp "$CID:/opt/GSM" - | tar -x -C "$OV/rootfs/opt" "${EXCL[@]+"${EXCL[@]}"}"
        docker cp "$CID:/opt/node" "$OV/rootfs/opt/" 2>/dev/null || true
        for d in .env .venv-qemu; do docker cp "$CID:/root/$d" "$OV/rootfs/root/" 2>/dev/null || true; done
        docker cp "$CID:/etc/osmocom" "$OV/rootfs/etc/" 2>/dev/null || true
        docker cp "$CID:/etc/asterisk" "$OV/rootfs/etc/" 2>/dev/null || true
        for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
            docker cp "$CID:/lib/systemd/system/$svc.service" "$OV/rootfs/lib/systemd/system/" 2>/dev/null || true
        done
        cp -f "$REPO"/services/*.service "$OV/rootfs/lib/systemd/system/" 2>/dev/null || true
        docker rm "$CID" >/dev/null; trap - EXIT
        # [2026-10-24] osmo-operator = CET arbre (fichiers suivis + non suivis, sans .git ni ignores),
        # comme l ISO qui fait foi sur le depot et non sur la copie de l image : le bureau (data/,
        # configs/, tools/) et les correctifs pas encore dans une image publiee.
        rm -rf "$OV/rootfs/opt/GSM/osmo-operator"; install -d "$OV/rootfs/opt/GSM/osmo-operator"
        (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) \
            | tar -xf - -C "$OV/rootfs/opt/GSM/osmo-operator"
        # le gardien de l encart et du Conky : le MEME que l ISO, extrait de 85-installeur-bureau.sh
        sed -n "/<<'PANEL'$/,/^PANEL$/p" "$REPO/iso_modules/85-installeur-bureau.sh" | sed '1d;$d' > "$OV/osmo-desktop-panel"
        [ -s "$OV/osmo-desktop-panel" ] || warn "osmo-desktop-panel non extrait de iso_modules/85-installeur-bureau.sh : pas de Conky au login"
        printf 'IMAGE=%s\nRELEASE=%s\nBOARDS=%s\nDESKTOP=%s\nDATE=%s\nNDEBS=%s\n' "$IMAGE" "$RELEASE" "$BOARDS" "$DESKTOP" "$(date -Is)" "$NDEBS" > "$OV/SOURCE"
        say "overlay pret : $NDEBS .deb, $(du -sh "$OV" | cut -f1)"
    fi
fi

# Les marqueurs que customize-image.sh lit dans l overlay (les services actives au boot)
if [ "$NO_STACK" = 0 ] && [ "$DRY" = 0 ]; then
    rm -f "$OV/OSMO_IMAGE_BANC" "$OV/OSMO_IMAGE_MULTI" "$OV/OSMO_ARM_GLAVA"
    [ "${OSMO_ARM_GLAVA:-0}" = 1 ] && : > "$OV/OSMO_ARM_GLAVA"
    [ "$BANC" = 1 ]  && : > "$OV/OSMO_IMAGE_BANC"
    [ "$MULTI" = 1 ] && : > "$OV/OSMO_IMAGE_MULTI"
fi

# ── 5. compile.sh, une fois par carte ────────────────────────────────────────
# Le bureau : armbian/build ne prend plus DESKTOP_ENVIRONMENT_CONFIG_NAME ni
# DESKTOP_APPGROUPS_SELECTED (lib/functions/configuration/config-desktop.sh) : le
# bureau vient des YAML de armbian/configng, choisi par DESKTOP_ENVIRONMENT + DESKTOP_TIER.
# GNOME minimal y tire gdm3, pulseaudio et Xorg - ce que le Conky et c123 attendent.
if [ "$DESKTOP" = 1 ]; then
    DESK=(BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_TIER=minimal)
else
    DESK=(BUILD_DESKTOP=no)
fi
IMGS=()
for b in $BOARDS; do
    br=$(board_branch "$b")
    CMD=(./compile.sh build "BOARD=$b" "BRANCH=$br" "RELEASE=$RELEASE" BUILD_MINIMAL=no "${DESK[@]}" KERNEL_CONFIGURE=no COMPRESS_OUTPUTIMAGE=sha,img)
    case "$(board_file "$b" 2>/dev/null)" in *.conf|"") ;; *) CMD+=(EXPERT=yes) ;; esac
    if [ "$PREPARE" = 1 ] || [ "$DRY" = 1 ]; then
        echo "  + (cd $ARMBIAN_DIR && ${CMD[*]})"
        continue
    fi
    say "[$b] compile.sh (long : noyau + rootfs + customize sous qemu-user) : ${CMD[*]}"
    t0=$(date +%s)
    (cd "$ARMBIAN_DIR" && "${CMD[@]}") || die "[$b] compile.sh a echoue"
    IMG=$(find "$ARMBIAN_DIR/output/images" -maxdepth 1 -name '*.img' -newermt "@$t0" 2>/dev/null | head -1)
    [ -n "$IMG" ] || die "[$b] pas de nouvelle image dans $ARMBIAN_DIR/output/images/"
    IMGS+=("$IMG")
    say "[$b] image : $IMG  ($(du -h "$IMG" | cut -f1))"
done
if [ "$PREPARE" = 1 ]; then
    say "--prepare : fini. Pour construire : les commandes ci-dessus, en root"
    exit 0
fi
[ "$DRY" = 1 ] && exit 0
say "images :"; for i in "${IMGS[@]}"; do echo "    $i"; done
say "flash : sudo dd if=<image> of=/dev/sdX bs=4M status=progress conv=fsync   (comptes : root/osmo, osmocom/osmo)"
