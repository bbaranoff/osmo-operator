#!/bin/bash
# secours/build-secours.sh - LA CLE DE SECOURS (mini ISO, ~150 Mo).
#
#   sudo secours/build-secours.sh [--output=FICHIER.iso] [--version=v0.2-1]
#
# Ce qu elle est : un systeme qui demarre d une cle USB, HORS LIGNE (aucun
# pilote reseau dans l image : il n y a rien pour envoyer quoi que ce soit), et
# qui lance tout seul la procedure de secours du poste securise
# (secours/osmo-secours) quand l alarme a sonne. Elle ne fait confiance a rien
# de ce qui est sur le disque suspect : ses outils viennent du depot, au
# commit ou elle a ete construite.
#
# COMMENT, ET POURQUOI AINSI :
#   - le DEMARRAGE est la chaine signee d Ubuntu (shim, GRUB, noyau) : elle
#     passe le Secure Boot du poste sans toucher au BIOS (un noyau Alpine n est
#     signe par personne que le firmware connaisse) ;
#   - TOUT LE RESTE est Alpine 3.24 (musl, busybox), dans l initramfs : petit,
#     et chaque paquet est verifie avec les cles d Alpine EPINGLEES dans
#     secours/keys (pas celles que le miroir enverrait) ;
#   - les modules du noyau sont ceux d Ubuntu (signes : le noyau en Secure
#     Boot refuse les autres), SANS drivers/net ni net/ : meme branchee sur un
#     reseau, la cle ne peut pas parler.
# UEFI seulement (le poste securise est UEFI).
#
# Hote : Ubuntu noble (ce poste, ou le runner GitHub : workflow
# build-secours.yml). Il faut root, curl, apt-get download, dpkg-deb, cpio,
# zstd, mtools, xorriso, mkfs.vfat, depmod.
set -euo pipefail

ROUGE='\033[1;31m'; VERT='\033[1;32m'; CYAN='\033[0;36m'; FIN='\033[0m'
dire() { echo -e "${VERT}[secours]${FIN} $*"; }
mourir() { echo -e "${ROUGE}[secours] $*${FIN}" >&2; exit 1; }

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$DEPOT/secours"
VERSION="${OSMO_SECOURS_VERSION:-$(git -C "$DEPOT" describe --tags --always 2>/dev/null || echo dev)}"
OUT=""
for a in "$@"; do
    case "$a" in
        --output=*)  OUT="${a#*=}" ;;
        --version=*) VERSION="${a#*=}" ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) mourir "argument inconnu : $a" ;;
    esac
done
OUT="${OUT:-$PWD/osmo-secours-$VERSION.iso}"
[ "$(id -u)" = 0 ] || mourir "root requis (sudo)"

ALPINE_MIROIR="${ALPINE_MIROIR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCHE="${ALPINE_BRANCHE:-v3.24}"
M="$ALPINE_MIROIR/$ALPINE_BRANCHE"

for t in curl apt-get dpkg-deb cpio zstd mcopy mmd xorriso mkfs.vfat depmod; do
    command -v "$t" >/dev/null || mourir "outil manquant : $t (apt-get install curl cpio zstd mtools xorriso dosfstools kmod)"
done

WORK="$(mktemp -d "${OSMO_SECOURS_WORK:-/var/tmp}/osmo-secours-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
R="$WORK/racine"          # le systeme de la cle (devient l initramfs)
ISO="$WORK/iso"           # ce que porte l ISO
mkdir -p "$R/etc/apk/keys" "$ISO/boot/grub" "$ISO/.disk" "$WORK/deb" "$WORK/k"

# ── 1. apk statique, et les cles epinglees ──────────────────────────────────
dire "Alpine $ALPINE_BRANCHE : apk statique"
curl -fsSL -o "$WORK/idx.tgz" "$M/main/x86_64/APKINDEX.tar.gz"
tar xzf "$WORK/idx.tgz" -C "$WORK" APKINDEX 2>/dev/null
v="$(awk '$0=="P:apk-tools-static"{f=1} f&&/^V:/{print substr($0,3);exit}' "$WORK/APKINDEX")"
[ -n "$v" ] || mourir "apk-tools-static introuvable dans l index"
curl -fsSL -o "$WORK/apk.apk" "$M/main/x86_64/apk-tools-static-$v.apk"
mkdir -p "$WORK/apk"; tar xzf "$WORK/apk.apk" -C "$WORK/apk" 2>/dev/null
APK="$WORK/apk/sbin/apk.static"
[ -x "$APK" ] || mourir "apk.static absent du paquet"
cp "$S"/keys/*.rsa.pub "$R/etc/apk/keys/"

# ── 2. le systeme Alpine ────────────────────────────────────────────────────
PAQUETS="busybox busybox-binsh bash kmod cryptsetup e2fsprogs blkid lsblk findmnt
         mount umount losetup coreutils findutils grep sed gawk tar gzip zstd
         tpm2-tools tpm2-tss-tcti-device python3 openssl age rsync kbd-bkeymaps
         ncurses-terminfo-base"
dire "paquets (verifies avec secours/keys)"
# un script d installation peut echouer sans que le paquet manque (tpm2-tss-fapi
# pose une ACL sur un dossier dont on ne se sert pas) : on verifie ensuite que
# CHAQUE paquet est la, c est ce qui compte
"$APK" --arch x86_64 --root "$R" --initdb -X "$M/main" -X "$M/community" --no-cache \
    add $PAQUETS >"$WORK/apk.log" 2>&1 || true
for p in $PAQUETS; do
    "$APK" --root "$R" info -e "$p" >/dev/null 2>&1 || { tail -20 "$WORK/apk.log" >&2; mourir "paquet non installe : $p"; }
done
grep -q "UNTRUSTED" "$WORK/apk.log" && mourir "signature non reconnue par les cles epinglees (secours/keys)"
echo "${ALPINE_BRANCHE} $(cat "$R/etc/alpine-release" 2>/dev/null)" > "$WORK/alpine-version"

# ── 3. noyau et modules d Ubuntu (signes), chaine de demarrage signee ───────
dire "noyau Ubuntu signe, shim et GRUB signes"
KV="${OSMO_SECOURS_NOYAU:-$(LC_ALL=C apt-cache depends linux-image-generic 2>/dev/null | awk '/Depends: linux-image-[0-9]/{sub("linux-image-","",$2); print $2; exit}')}"
[ -n "$KV" ] || mourir "version du noyau introuvable (apt-get update ?)"
( cd "$WORK/deb" && apt-get download -q "linux-image-$KV" "linux-modules-$KV" "linux-modules-extra-$KV" \
      shim-signed grub-efi-amd64-signed >/dev/null ) || mourir "apt-get download a echoue (noyau $KV)"
for d in "$WORK"/deb/*.deb; do dpkg-deb -x "$d" "$WORK/k"; done
VMLINUZ="$WORK/k/boot/vmlinuz-$KV"
premier() { local f; for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 0; }
SHIM="$(premier "$WORK"/k/usr/lib/shim/shimx64.efi.signed.latest "$WORK"/k/usr/lib/shim/shimx64.efi.signed)"
MM="$(premier "$WORK"/k/usr/lib/shim/mmx64.efi.signed "$WORK"/k/usr/lib/shim/mmx64.efi)"
GRUB="$WORK/k/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed"
for f in "$VMLINUZ" "$SHIM" "$GRUB"; do [ -f "$f" ] || mourir "absent : $f"; done
if command -v sbverify >/dev/null; then
    sbverify --list "$VMLINUZ" 2>/dev/null | grep -q "Canonical" || mourir "le noyau n est pas signe par Canonical"
fi

# les modules, SANS RESEAU. Ce qui reste : stockage, chiffrement, TPM,
# clavier, USB, virtio (tests). drivers/net et net/ partent en entier : la cle
# n a aucun moyen de parler, meme si elle reconnaissait la carte.
mkdir -p "$R/lib/modules"
cp -a "$WORK/k/lib/modules/$KV" "$R/lib/modules/"
MD="$R/lib/modules/$KV/kernel"
for x in drivers/net net drivers/bluetooth drivers/nfc drivers/infiniband drivers/isdn drivers/atm \
         drivers/media drivers/staging drivers/gpu drivers/iio sound drivers/video/fbdev/nvidia \
         drivers/wireless drivers/uwb fs/nfs fs/nfsd fs/cifs fs/smb fs/ceph fs/9p fs/afs fs/coda; do
    rm -rf "${MD:?}/$x"
done
depmod -b "$R" "$KV"
# preuve, dans l image : aucun module reseau
if find "$MD" -name '*.ko*' | grep -qE '/(drivers/net|net)/'; then mourir "il reste des modules reseau"; fi

# ── 4. nos outils (ceux du depot, jamais ceux du disque suspect) ────────────
dire "outils du poste securise (depot $(git -C "$DEPOT" rev-parse --short HEAD 2>/dev/null || echo ?))"
install -d "$R/usr/local/sbin" "$R/etc/osmo-secours"
for t in osmo-empreinte osmo-total osmo-diffs; do
    install -m 0755 "$DEPOT/configs/crypthome/$t" "$R/usr/local/sbin/$t"
done
install -m 0755 "$S/osmo-secours" "$R/usr/local/sbin/osmo-secours"
install -D -m 0644 "$S/osmo-secours-controle.py" "$R/usr/local/lib/osmo-secours-controle.py"
install -m 0755 "$S/init" "$R/init"
{ echo "osmo-secours $VERSION"
  echo "depot $(git -C "$DEPOT" rev-parse HEAD 2>/dev/null || echo ?)"
  echo "alpine $(cat "$WORK/alpine-version")"
  echo "noyau $KV"
  echo "construite le $(date -u '+%F %T') UTC"; } > "$R/etc/osmo-secours/version"
# rien a garder du gestionnaire de paquets dans l image
rm -rf "$R/var/cache/apk" "$R/lib/apk/db/scripts.tar.gz" "$R/usr/share/man" "$R/usr/share/doc"
mkdir -p "$R"/{proc,sys,dev,run,tmp,mnt,media,var/lib/osmo-diffs}

# ── 5. initramfs ────────────────────────────────────────────────────────────
dire "initramfs"
( cd "$R" && find . | cpio -o -H newc --quiet ) | zstd -q -19 -T0 > "$ISO/boot/initrd.zst"
cp "$VMLINUZ" "$ISO/boot/vmlinuz"
echo "osmo-secours $VERSION" > "$ISO/.disk/info"

cat > "$ISO/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=5
set default=0
menuentry "osmo-secours - hors ligne (clavier fr)" {
    linux /boot/vmlinuz quiet loglevel=3 osmo.clavier=fr
    initrd /boot/initrd.zst
}
menuentry "osmo-secours - hors ligne (clavier us)" {
    linux /boot/vmlinuz quiet loglevel=3 osmo.clavier=us
    initrd /boot/initrd.zst
}
menuentry "osmo-secours - console serie (tests)" {
    linux /boot/vmlinuz console=ttyS0,115200 osmo.clavier=us osmo.serie=1
    initrd /boot/initrd.zst
}
GRUBCFG

# ── 6. ISO UEFI signee (meme disposition que iso_modules/91-secure-boot.sh) ─
dire "ISO (shim -> GRUB -> noyau, signes)"
cat > "$WORK/esp-grub.cfg" <<'ESPCFG'
search --no-floppy --file --set=osmodev /.disk/info
if [ -n "$osmodev" ]; then
    set root=$osmodev
    set prefix=($osmodev)/boot/grub
    configfile ($osmodev)/boot/grub/grub.cfg
fi
echo "osmo-secours : /.disk/info introuvable sur les disques vus par le firmware."
ESPCFG
ESP="$WORK/efi.img"
mkfs.vfat -F 16 -n SECOURSEFI -C "$ESP" 16384 >/dev/null
mmd   -i "$ESP" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
mcopy -i "$ESP" "$SHIM" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$GRUB" ::/EFI/BOOT/grubx64.efi
[ -n "$MM" ] && mcopy -i "$ESP" "$MM" ::/EFI/BOOT/mmx64.efi
mcopy -i "$ESP" "$WORK/esp-grub.cfg" ::/EFI/BOOT/grub.cfg
mcopy -i "$ESP" "$WORK/esp-grub.cfg" ::/EFI/ubuntu/grub.cfg
cp "$ESP" "$ISO/boot/efi.img"
mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs -quiet -r -J -joliet-long -V OSMO_SECOURS \
    -o "$OUT" \
    -e boot/efi.img -no-emul-boot \
    -append_partition 2 0xef "$ESP" -appended_part_as_gpt \
    "$ISO"
sha256sum "$OUT" | sed "s#  .*#  $(basename "$OUT")#" > "$OUT.sha256"
dire "fait : ${CYAN}$OUT${FIN} ($(du -h "$OUT" | cut -f1)) - $(cut -c1-16 "$OUT.sha256")..."
dire "sur une cle : sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
