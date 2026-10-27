#!/bin/bash
# iso_modules/88-lte-pmos.sh - step 8d: 4G (srsRAN ZeroMQ + Open5GS) and the
# smartphone UI (postmarketOS, PPP kernel) in the rootfs.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment variables:
#   OSMO_ISO_LTE_BUILD=0      do not compile srsRAN/Open5GS in the chroot when
#                             the .deb cache lacks them (ISO without 4G)
#   OSMO_ISO_PMOS_IMAGE=PATH  pmOS VM image (.img or .img.zst) to embed;
#                             'none' embeds nothing; default: look on the host
#   OSMO_PMOS_IMAGE_URL=URL   download the VM image (release asset) if none found
#   OSMO_PMOS_KERNEL_URL=URL  PPP kernel .deb to fetch when missing from the cache
#   OSMO_ISO_PMAPORTS=0       do not embed pmaports at the kernel commit
#   OSMO_ISO_LTE_REQUIRED=0   final check only reports, does not abort the build
#   OSMO_SRSRAN_ARCH          ISA baseline for srsRAN builds (default x86-64-v2)
#   OSMO_DEB_CACHE            host .deb cache (default /var/cache/osmo-debs)

# ── Step 8d: 4G and the phone ──────────────────────────────────────────────
# Sources used by this module:
#   - Binaries: .deb files from /var/cache/osmo-debs, placed by
#     50-injection-image.sh: osmo-build-libzmq, osmo-build-srsran
#     (/opt/LTE/srsRAN_4G, /usr/local/bin), osmo-build-open5gs (/opt/LTE/open5gs,
#     install/ prefix), osmo-build-pmos-kernel (/opt/user_interface/kernel/pmos),
#     osmo-build-pmbootstrap (/opt/user_interface/pmos/pmbootstrap, patched).
#     They come from packaging/snapshot-lte-debs.sh or from the Dockerfile (the
#     pmOS kernel only from the former). If the cache lacks srsRAN/Open5GS they
#     are compiled here in the chroot by tools/osmo-lte-install.sh --build.
#   - apt runtime packages: PKGS in 80-chroot.sh (MongoDB repo added there).
#   - Configs and launchers: tools/osmo-lte-install.sh and
#     tools/osmo-pmos-install.sh, run inside the chroot from THIS repository
#     (not the image's GitHub clone, which may lag behind).
#   - The VM image (5 GB sparse, ~2 GB zstd) is optional, see
#     OSMO_ISO_PMOS_IMAGE; without it osmo-pmos-build runs pmbootstrap install.
#
# Not for the hub (interstp) nor --arm (srsRAN and Open5GS are not built for
# arm64, and pmbootstrap would run an emulated x86 VM).
if [ "$ISO_ROLE" = "interstp" ] || [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

echo -e "${GREEN}[8d/9] La 4G (srsRAN ZeroMQ + Open5GS) et l UI smartphone (postmarketOS)...${NC}"

# ── /proc /sys /dev: bind-mounted for the duration of this module ─────────
# Everything below runs inside the chroot (dpkg, apt, srsRAN/Open5GS builds,
# final checks) and needs them; 86-finitions.sh has already unmounted them.
# They are unmounted at the end of the module, since 90-iso.sh builds the
# squashfs. Idempotent: already-mounted points are skipped, and only what was
# mounted here is unmounted.
_iso88_mnt=()
_iso88_up() {   # _iso88_up <host source> <mount point, relative to the rootfs>
    local _t="$ROOTFS$2"
    [ -d "$_t" ] || install -d "$_t" 2>/dev/null || return 0
    mountpoint -q "$_t" 2>/dev/null && return 0
    mount --bind "$1" "$_t" 2>/dev/null && _iso88_mnt=("$_t" "${_iso88_mnt[@]}")
    return 0
}
_iso88_down() {  # reverse mount order (/dev/pts before /dev)
    local _m
    for _m in "${_iso88_mnt[@]}"; do umount -l "$_m" 2>/dev/null || true; done
    _iso88_mnt=()
}
_iso88_up /proc    /proc
_iso88_up /sys     /sys
_iso88_up /dev     /dev
_iso88_up /dev/pts /dev/pts

# Chroot DNS for the git clones of --build: /etc/resolv.conf links to
# /run/systemd/resolve/stub-resolv.conf, which is empty at build time. /run is
# a tmpfs at boot, so this file does not survive into the live system.
install -d "$ROOTFS/run/systemd/resolve"
[ -s "$ROOTFS/run/systemd/resolve/stub-resolv.conf" ] || {
    grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -v '^nameserver 127\.' \
      || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
} > "$ROOTFS/run/systemd/resolve/stub-resolv.conf"

_rt="$ROOTFS/opt/GSM/osmo-operator"
install -d "$_rt/tools" "$_rt/configs/srsran" "$_rt/configs/open5gs" "$_rt/configs/pmos" "$_rt/patches" "$_rt/packaging"
# The local repository is authoritative (same rule as 85-installeur-bureau.sh).
for _f in osmo-lte.sh osmo-epc.sh osmo-lte-install.sh osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh \
          osmo-pmos-build.sh osmo-pmos-install.sh osmo-phonesim-banc.py at-cmd.py; do
    [ -f "$DIR/tools/$_f" ] && install -m755 "$DIR/tools/$_f" "$_rt/tools/"
done
install -m644 "$DIR"/configs/srsran/* "$_rt/configs/srsran/"
install -m644 "$DIR"/configs/open5gs/*.yaml "$DIR"/configs/open5gs/*.json "$_rt/configs/open5gs/" 2>/dev/null || true
[ -d "$DIR/configs/open5gs/dump" ] && cp -a "$DIR/configs/open5gs/dump" "$_rt/configs/open5gs/"
# freeDiameter .conf files come from the repo (the Open5GS .deb has none).
[ -d "$DIR/configs/open5gs/freeDiameter" ] && cp -a "$DIR/configs/open5gs/freeDiameter" "$_rt/configs/open5gs/"
install -m644 "$DIR"/configs/pmos/* "$_rt/configs/pmos/"
for _f in pmbootstrap-osmo-bench-qemu.patch pmaports-linux-postmarketos-stable-ppp.patch; do
    [ -f "$DIR/patches/$_f" ] && install -m644 "$DIR/patches/$_f" "$_rt/patches/"
done
for _f in build-pmos-kernel-deb.sh snapshot-lte-debs.sh osmo-deb.sh; do
    [ -f "$DIR/packaging/$_f" ] && install -m755 "$DIR/packaging/$_f" "$_rt/packaging/"
done
unset _f

# PPP pmOS kernel missing from the cache: fetch it from GitHub (Git LFS,
# bbaranoff/pmos_ppp_kernel) into the host cache and the rootfs.
if [ ! -e "$ROOTFS/opt/user_interface/kernel/pmos/APKINDEX.tar.gz" ]; then
    _kurl="${OSMO_PMOS_KERNEL_URL:-https://media.githubusercontent.com/media/bbaranoff/pmos_ppp_kernel/main/osmo-build-pmos-kernel_7.2.3.0+ppp~noble_amd64.deb}"
    _kdeb="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}/$(basename "$_kurl")"
    if [ ! -s "$_kdeb" ]; then
        echo -e "  ${CYAN}·${NC} noyau pmOS PPP : telechargement depuis GitHub ($_kurl)"
        install -d "$(dirname "$_kdeb")"
        curl -fsSL --retry 3 -o "$_kdeb.part" "$_kurl" && dpkg-deb --info "$_kdeb.part" >/dev/null 2>&1 \
            && mv -f "$_kdeb.part" "$_kdeb" || { rm -f "$_kdeb.part"; echo -e "  ${YELLOW}!${NC} noyau pmOS : telechargement impossible"; }
    fi
    if [ -s "$_kdeb" ]; then
        install -d "$ROOTFS/var/cache/osmo-debs"; cp -f "$_kdeb" "$ROOTFS/var/cache/osmo-debs/"
        chroot "$ROOTFS" dpkg -i --force-overwrite "/var/cache/osmo-debs/$(basename "$_kdeb")" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} noyau pmOS PPP pose depuis $(basename "$_kdeb")"
        [ "${ISO_EMBED_DEBS:-0}" = "1" ] || rm -f "$ROOTFS/var/cache/osmo-debs/$(basename "$_kdeb")"
    fi
    unset _kurl _kdeb
fi

# Report what the .deb files installed; warn but do not stop.
for _c in "srsenb:/usr/local/bin/srsenb" "Open5GS:/opt/LTE/open5gs/install/bin/open5gs-mmed" \
          "noyau pmOS PPP:/opt/user_interface/kernel/pmos/APKINDEX.tar.gz" \
          "pmbootstrap:/opt/user_interface/pmos/pmbootstrap/pmbootstrap.py"; do
    if [ -e "$ROOTFS/${_c#*:}" ]; then echo -e "  ${GREEN}✓${NC} ${_c%%:*} (.deb du build)"
    else echo -e "  ${YELLOW}!${NC} ${_c%%:*} absent du rootfs - pas de .deb dans /var/cache/osmo-debs (packaging/snapshot-lte-debs.sh sur la machine de reference, ou le Dockerfile)"; fi
done
unset _c

# The MongoDB repo is already configured by 80-chroot.sh: --deps only adds
# missing packages (and enables mongod), then the cached .deb files are installed.
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --deps --debs 2>&1 | sed 's/^/  /'

# ── No .deb: compile in the chroot ─────────────────────────────────────────
# The chroot has the -dev packages (PKGS in 80-chroot.sh), /proc /sys /dev and
# DNS, so the same --build used by the Dockerfile runs here. With OSMO_DEB=1 the
# build produces .deb files that are copied back to the host cache.
# OSMO_ISO_LTE_BUILD=0 disables this (ISO without 4G).
#
# A cached srsRAN .deb built with -march=native contains AVX instructions and
# would die with "Illegal instruction" on other CPUs. It is rejected here and
# rebuilt with a portable ISA baseline (see SRS_ARCH in tools/osmo-lte-install.sh).
_iso_srs_avx() {   # 0 = this binary will not run on every CPU
    [ -x "$ROOTFS/usr/local/bin/srsenb" ] || return 1
    command -v objdump >/dev/null 2>&1 || return 1
    objdump -d "$ROOTFS/usr/local/bin/srsenb" 2>/dev/null | grep -qE '%[yz]mm[0-9]'
}
if _iso_srs_avx; then
    echo -e "  ${YELLOW}!${NC} srsenb du cache .deb taille pour le CPU du build (AVX) : il ferait « Illegal instruction » ailleurs"
    rm -f "$ROOTFS"/usr/local/bin/srsenb "$ROOTFS"/usr/local/bin/srsue "$ROOTFS"/usr/local/bin/srsepc
    # Move the offending .deb aside in the host cache (renamed, not deleted; the
    # recovery glob below only takes *.deb) so the next ISO does not reuse it.
    for _sd in "${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"/osmo-build-srsran_*.deb; do
        [ -f "$_sd" ] || continue
        mv -f "$_sd" "$_sd.avx-natif" && echo -e "    ${CYAN}·${NC} $(basename "$_sd") ecarte -> $(basename "$_sd").avx-natif"
    done
    unset _sd
fi
unset -f _iso_srs_avx
if [ ! -x "$ROOTFS/usr/local/bin/srsenb" ] || [ ! -x "$ROOTFS/opt/LTE/open5gs/install/bin/open5gs-mmed" ]; then
    if [ "${OSMO_ISO_LTE_BUILD:-1}" = "1" ]; then
        echo -e "  ${YELLOW}!${NC} 4G absente du cache .deb : compilation dans le chroot (long)"
        install -d "$ROOTFS/var/cache/osmo-debs"
        [ -f "$DIR/packaging/osmo-deb.sh" ] && install -m755 "$DIR/packaging/osmo-deb.sh" "$ROOTFS/usr/local/sbin/osmo-deb"
        # OSMO_SRSRAN_ARCH: ISA baseline of the ISO binaries. The script default
        # (x86-64-v2) is right for an ISO; passed explicitly so a build can override it.
        chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive OSMO_DEB=1 OSMO_REPO=/opt/GSM/osmo-operator \
            OSMO_SRSRAN_ARCH="${OSMO_SRSRAN_ARCH:-x86-64-v2}" \
            bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --build 2>&1 | sed 's/^/  /' \
            || echo -e "  ${YELLOW}!${NC} compilation 4G echouee dans le chroot - ISO sans srsRAN/Open5GS"
        # Copy freshly built .deb files back to the host cache.
        _dc="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
        install -d "$_dc"
        for _d in "$ROOTFS"/var/cache/osmo-debs/osmo-build-*.deb; do
            [ -f "$_d" ] || continue
            [ -f "$_dc/$(basename "$_d")" ] || { cp -f "$_d" "$_dc/" && echo -e "  ${GREEN}✓${NC} $(basename "$_d") remis dans $_dc"; }
        done
        [ "${ISO_EMBED_DEBS:-0}" = "1" ] || rm -f "$ROOTFS"/var/cache/osmo-debs/osmo-build-*.deb
        unset _d _dc
    else
        echo -e "  ${YELLOW}!${NC} 4G absente et OSMO_ISO_LTE_BUILD=0 : ISO sans srsRAN/Open5GS"
    fi
fi

# Open5GS configs are only installed if the prefix exists: after the build.
chroot "$ROOTFS" env OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --configs --launchers 2>&1 | sed 's/^/  /'
chroot "$ROOTFS" env OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-pmos-install.sh 2>&1 | sed 's/^/  /'

# Default VM image: if OSMO_ISO_PMOS_IMAGE is unset, use the host's image
# (where osmo-pmos-build looks for it). A ready .zst is preferred, otherwise
# the raw pmbootstrap image is compressed. OSMO_ISO_PMOS_IMAGE=none embeds nothing.
if [ -z "${OSMO_ISO_PMOS_IMAGE:-}" ]; then
    for _cand in /opt/user_interface/pmos/image/qemu-amd64.img.zst \
                 "${OSMO_DEB_CACHE:-/var/cache/osmo-debs}/qemu-amd64.img.zst" \
                 "${OSMO_PMB_WORK:-/root/test}"/chroot_native/home/pmos/rootfs/qemu-amd64.img \
                 /home/*/test/chroot_native/home/pmos/rootfs/qemu-amd64.img; do
        [ -f "$_cand" ] || continue
        OSMO_ISO_PMOS_IMAGE="$_cand"
        echo -e "  ${CYAN}·${NC} image de la VM de reference trouvee sur l hote : $_cand"
        break
    done
    unset _cand
fi

# No image on the host (e.g. CI runner): download it from
# OSMO_PMOS_IMAGE_URL if set. The image is a release asset (too big for the
# Git LFS quota). Publish once from a reference machine:
#
#   gh release create pmos-image --repo bbaranoff/osmo-operator \
#       --title "postmarketOS - VM de reference (noyau PPP)" --notes "..." \
#       /opt/user_interface/pmos/image/qemu-amd64.img.zst
#
# Empty (default) = no download.
if [ -z "${OSMO_ISO_PMOS_IMAGE:-}" ] && [ -n "${OSMO_PMOS_IMAGE_URL:-}" ]; then
    _icache="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}/qemu-amd64.img.zst"
    echo -e "  ${CYAN}·${NC} image de la VM : telechargement depuis $OSMO_PMOS_IMAGE_URL"
    install -d "$(dirname "$_icache")"
    # zstd -t catches a 404 page or truncated download here rather than in the ISO.
    if curl -fsSL --retry 3 --retry-delay 5 -o "$_icache.part" "$OSMO_PMOS_IMAGE_URL" \
       && zstd -t "$_icache.part" >/dev/null 2>&1; then
        mv -f "$_icache.part" "$_icache"
        OSMO_ISO_PMOS_IMAGE="$_icache"
        echo -e "  ${GREEN}✓${NC} image recuperee ($(du -h "$_icache" | cut -f1)) - gardee dans $(dirname "$_icache") pour les ISO suivantes"
    else
        rm -f "$_icache.part"
        echo -e "  ${YELLOW}!${NC} image de la VM : telechargement impossible - ISO sans telephone pret (osmo-pmos-build le fera sur la machine)"
    fi
    unset _icache
fi
[ "${OSMO_ISO_PMOS_IMAGE:-}" = "none" ] && OSMO_ISO_PMOS_IMAGE=""
# Embed the VM image: the given one, or the host's (see above).
if [ -n "${OSMO_ISO_PMOS_IMAGE:-}" ]; then
    if [ -f "$OSMO_ISO_PMOS_IMAGE" ]; then
        install -d "$ROOTFS/opt/user_interface/pmos/image"
        case "$OSMO_ISO_PMOS_IMAGE" in
            *.zst) cp -f "$OSMO_ISO_PMOS_IMAGE" "$ROOTFS/opt/user_interface/pmos/image/qemu-amd64.img.zst" ;;
            *) zstd -T0 -3 --sparse -f -o "$ROOTFS/opt/user_interface/pmos/image/qemu-amd64.img.zst" "$OSMO_ISO_PMOS_IMAGE" ;;
        esac && echo -e "  ${GREEN}✓${NC} image de la VM embarquee ($(du -h "$ROOTFS/opt/user_interface/pmos/image/qemu-amd64.img.zst" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} OSMO_ISO_PMOS_IMAGE=$OSMO_ISO_PMOS_IMAGE introuvable - image non embarquee"
    fi
else
    echo -e "  ${CYAN}·${NC} image de la VM non embarquee (OSMO_ISO_PMOS_IMAGE=... pour l ajouter) : osmo-pmos-build la fera"
fi

# ── pmaports in the ISO, at the kernel commit ──────────────────────────────
# Fetch only the commit of the PPP kernel (kernel/pmos/pmaports.commit,
# --depth 1) with the origin/main ref pmbootstrap needs to read channels.cfg,
# into /opt/user_interface/pmos/pmaports; osmo-pmos-build copies it instead of
# cloning the full pmaports. Kept in the host cache (OSMO_DEB_CACHE).
# OSMO_ISO_PMAPORTS=0 disables it.
_pc="$(cat "$ROOTFS/opt/user_interface/kernel/pmos/pmaports.commit" 2>/dev/null || true)"
if [ "${OSMO_ISO_PMAPORTS:-1}" = "1" ] && [ -n "$_pc" ] && [ "$_pc" != inconnu ]; then
    _pcache="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}/pmaports-$_pc"
    if ! git -C "$_pcache" rev-parse --verify HEAD >/dev/null 2>&1; then
        echo -e "  ${CYAN}·${NC} pmaports : fetch du commit $_pc (GitLab, --depth 1)..."
        rm -rf "$_pcache"
        ( git init -q "$_pcache" && cd "$_pcache" \
          && git remote add origin https://gitlab.postmarketos.org/postmarketOS/pmaports.git \
          && git fetch -q --depth 1 origin "$_pc" && git checkout -q -B main FETCH_HEAD \
          && git update-ref refs/remotes/origin/main FETCH_HEAD ) \
          || { rm -rf "$_pcache"; echo -e "  ${YELLOW}!${NC} pmaports : fetch impossible (reseau ?) - le premier clic ira le chercher"; }
    fi
    if git -C "$_pcache" rev-parse --verify HEAD >/dev/null 2>&1; then
        rm -rf "$ROOTFS/opt/user_interface/pmos/pmaports"
        cp -a "$_pcache" "$ROOTFS/opt/user_interface/pmos/pmaports"
        echo -e "  ${GREEN}✓${NC} pmaports au commit ${_pc:0:10} dans /opt/user_interface/pmos/pmaports ($(du -sh "$_pcache" | cut -f1))"
    fi
    unset _pcache
fi
unset _pc

# The session account runs pmbootstrap: /opt/user_interface must be readable,
# and the config template goes to /etc/skel for accounts created by Calamares
# (shellprocess-osmo.conf fills in the paths of their home).
chroot "$ROOTFS" chmod -R a+rX /opt/user_interface 2>/dev/null || true
install -d "$ROOTFS/etc/skel/.config"
install -m644 "$DIR/configs/pmos/pmbootstrap_v3.cfg" "$ROOTFS/etc/skel/.config/pmbootstrap_v3.cfg.osmo"
# Existing accounts too: root and osmocom are created by 84-comptes.sh before
# this module, so /etc/skel does not apply. Same substitution as
# shellprocess-osmo.conf (work dir ~/.local/var/pmbootstrap).
for _h in /root /home/osmocom; do
    [ -d "$ROOTFS$_h" ] || continue
    [ -s "$ROOTFS$_h/.config/pmbootstrap_v3.cfg" ] && continue
    install -d "$ROOTFS$_h/.config"
    sed "s#@WORK@#$_h/.local/var/pmbootstrap#g; s#@APORTS@#$_h/.local/var/pmbootstrap/cache_git/pmaports#g" \
        "$DIR/configs/pmos/pmbootstrap_v3.cfg" > "$ROOTFS$_h/.config/pmbootstrap_v3.cfg"
done
chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom/.config 2>/dev/null || true
unset _h
echo -e "  ${GREEN}✓${NC} pmbootstrap_v3.cfg : /root, /home/osmocom, /etc/skel"

# Lite: build objects in /opt/LTE are not needed at runtime.
if [ "$ISO_LITE" = "1" ]; then
    _before=$(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)
    find "$ROOTFS/opt/LTE/srsRAN_4G/build" "$ROOTFS/opt/LTE/open5gs/build" -name '*.o' -delete 2>/dev/null || true
    rm -rf "$ROOTFS/opt/LTE/libzmq" "$ROOTFS/opt/LTE/czmq" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} lite : /opt/LTE ${_before:-?} -> $(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)"
fi
unset _rt _before

# ── Final check: the ISO must be ready to use, 2G + 4G + phone ────────────
# Verify in the rootfs every link needed to launch the GSM bench, the 4G and
# the pmOS phone, and abort the build if one is missing.
# OSMO_ISO_LTE_REQUIRED=0 only reports (ISO without 4G accepted).
echo -e "  ${CYAN}·${NC} controle final : 2G + 4G + telephone dans le rootfs"
_ko=0
_chk() {  # _chk <label> <chroot test command...>
    local l="$1"; shift
    if chroot "$ROOTFS" "$@" >/dev/null 2>&1; then echo -e "      ${GREEN}✓${NC} $l"
    else echo -e "      ${RED}✗${NC} $l"; _ko=$((_ko + 1)); fi
}
# 2G: the bench, its unit, and osmo-msc SGs (combined attach, CSFB)
_chk "2G  launch.sh (icone « Lancer le banc GSM »)"       test -x /opt/GSM/osmo-operator/launch.sh
_chk "2G  osmo-banc.service"                               test -s /etc/systemd/system/osmo-banc.service
_chk "2G  osmo-msc.cfg : section sgs (CSFB)"               grep -q '^sgs' /etc/osmocom/osmo-msc.cfg
# 4G: binaries, configs (incl. MME SGs), launchers, unit, MongoDB
_chk "4G  srsenb / srsue"                                  bash -c 'test -x /usr/local/bin/srsenb && test -x /usr/local/bin/srsue'
# ── Are all their libraries present? ──────────────────────────────────────
# srsRAN is built with ENABLE_GUI=ON and links to libsrsgui (/usr/local/lib).
_chk "4G  srsenb / srsue : bibliotheques toutes resolues" \
    bash -c 'for b in srsenb srsue; do ldd /usr/local/bin/$b 2>/dev/null | grep -q "not found" && exit 1; done; exit 0'
# ── Will they run on the operator's machine? ──────────────────────────────
# An AVX (%ymm) or AVX512 (%zmm) instruction in srsenb/srsue ties the ISO to
# the build CPU: treated as an error. Checked from the host (objdump on the
# rootfs; the ISO has no binutils). Skipped with a notice if objdump is missing.
if command -v objdump >/dev/null 2>&1; then
    if objdump -d "$ROOTFS/usr/local/bin/srsenb" 2>/dev/null | grep -qE '%[yz]mm[0-9]' \
       || objdump -d "$ROOTFS/usr/local/bin/srsue" 2>/dev/null | grep -qE '%[yz]mm[0-9]'; then
        echo -e "      ${RED}✗${NC} 4G  srsenb / srsue portables (pas d AVX du CPU du build)"
        echo -e "          recompiler : OSMO_SRSRAN_ARCH=x86-64-v2, cf. tools/osmo-lte-install.sh"
        _ko=$((_ko + 1))
    else
        echo -e "      ${GREEN}✓${NC} 4G  srsenb / srsue portables (pas d AVX du CPU du build)"
    fi
else
    echo -e "      ${CYAN}·${NC} 4G  objdump absent de l hote : portabilite ISA de srsenb non verifiee"
fi
# Real-time traces (srsGUI) are optional: only reported.
if chroot "$ROOTFS" bash -c 'ldd /usr/local/bin/srsenb 2>/dev/null | grep -q libsrsgui' 2>/dev/null; then
    echo -e "      ${GREEN}✓${NC} 4G  srsGUI : traces temps reel armees (srsenb lie a libsrsgui)"
else
    echo -e "      ${CYAN}·${NC} 4G  srsGUI absent : srsenb sans traces temps reel (« osmo-lte-install --build »)"
fi
_chk "4G  open5gs-mmed / open5gs-hssd"                     bash -c 'test -x /opt/LTE/open5gs/install/bin/open5gs-mmed && test -x /opt/LTE/open5gs/install/bin/open5gs-hssd'
_chk "4G  mme.yaml du depot avec sgsap (CSFB)"             grep -q '^  sgsap:' /opt/LTE/open5gs/install/etc/open5gs/mme.yaml
_chk "4G  freeDiameter mme/hss/pcrf/smf.conf (S6a, Gx)"   bash -c 'for n in mme hss pcrf smf; do test -s /opt/LTE/open5gs/install/etc/freeDiameter/$n.conf || exit 1; done'
_chk "4G  TLS freeDiameter (ca + mme/hss/pcrf/smf)"       bash -c 'for n in ca mme hss pcrf smf; do test -s /opt/LTE/open5gs/install/etc/open5gs/tls/$n.crt || exit 1; done'
# Does the MME start? 3 s in the foreground in the chroot catches missing
# configs or libraries. A port already in use on the host (its own 4G running)
# is not an ISO fault: reported without failing.
_o="$(chroot "$ROOTFS" timeout 3 /opt/LTE/open5gs/install/bin/open5gs-mmed -c /opt/LTE/open5gs/install/etc/open5gs/mme.yaml 2>&1 || true)"
rm -f "$ROOTFS/opt/LTE/open5gs/install/var/log/open5gs/mme.log"
if echo "$_o" | grep -aq 'Address already in use'; then
    echo -e "      ${CYAN}·${NC} 4G  open5gs-mmed : port deja pris sur l hote (sa 4G tourne ?) - demarrage non teste"
elif echo "$_o" | grep -aqE 'FATAL|error while loading shared'; then
    echo -e "      ${RED}✗${NC} 4G  open5gs-mmed demarre (3 s au premier plan)"
    echo "$_o" | grep -aE 'FATAL|error while loading' | grep -v backtrace | head -2 | sed 's/^/          /'
    _ko=$((_ko + 1))
else
    echo -e "      ${GREEN}✓${NC} 4G  open5gs-mmed demarre (3 s au premier plan)"
fi
unset _o
_chk "4G  configs srsRAN (/root/.config/srsran)"           bash -c 'test -s /root/.config/srsran/enb.conf && test -s /root/.config/srsran/ue.conf && test -s /root/.config/srsran/user_db.csv'
_chk "4G  osmo-lte / osmo-epc"                             bash -c 'test -x /usr/local/bin/osmo-lte && test -x /usr/local/bin/osmo-epc'
# Phone data path: docker sets FORWARD to DROP; the DOCKER-USER rules from
# osmo-epc (setup_forward), osmo-pmos-qemu (pmos_forward) and the bench modem
# (PPP session) are required for traffic to leave the host.
_chk "4G  FORWARD ogstun : osmo-epc, osmo-pmos-qemu, phonesim" bash -c 'grep -q "^setup_forward()" /opt/GSM/osmo-operator/tools/osmo-epc.sh && grep -q "^pmos_forward()" /opt/GSM/osmo-operator/tools/osmo-pmos-qemu.sh && grep -q "DOCKER-USER" /opt/GSM/osmo-operator/tools/osmo-phonesim-banc.py'
_chk "4G  osmo-lte.service + osmo-lte.desktop"             bash -c 'test -s /etc/systemd/system/osmo-lte.service && test -s /usr/share/applications/osmo-lte.desktop'
_chk "4G  mongod + mongosh + mongorestore (abonnes HSS)"   bash -c 'command -v mongod && command -v mongosh && command -v mongorestore'
_chk "4G  abonnes du depot (dump mongo + subscribers.json)" bash -c 'test -s /opt/GSM/osmo-operator/configs/open5gs/dump/open5gs/subscribers.bson && test -s /opt/GSM/osmo-operator/configs/open5gs/subscribers.json'
# Phone: patched pmbootstrap, PPP kernel, launcher and icon
_chk "pmOS pmbootstrap (/opt/user_interface/pmos)"         test -s /opt/user_interface/pmos/pmbootstrap/pmbootstrap.py
_chk "pmOS noyau PPP (APKINDEX)"                           test -s /opt/user_interface/kernel/pmos/APKINDEX.tar.gz
_chk "pmOS osmo-pmos + osmo-pmos.desktop"                  bash -c 'test -x /usr/local/bin/osmo-pmos && test -s /usr/share/applications/osmo-pmos.desktop'
_chk "pmOS pmbootstrap_v3.cfg de root (la session de l ISO)" test -s /root/.config/pmbootstrap_v3.cfg
if [ -d "$ROOTFS/home/osmocom" ]; then
    _chk "pmOS pmbootstrap_v3.cfg d osmocom"                bash -c 'test -s /home/osmocom/.config/pmbootstrap_v3.cfg && ! grep -q @WORK@ /home/osmocom/.config/pmbootstrap_v3.cfg'
fi
_chk "pmOS lanceurs en root (--as-root dans osmo-pmos-qemu)" grep -q 'as-root' /opt/user_interface/pmos/bin/osmo-pmos-qemu.sh
_chk "pmOS kpartx + losetup + git (pmbootstrap les exige)"   bash -c 'command -v kpartx && command -v losetup && command -v git'
if [ "${OSMO_ISO_PMAPORTS:-1}" = "1" ]; then
    _chk "pmOS pmaports au commit du noyau (pas de clone au premier clic)" bash -c 'test -f /opt/user_interface/pmos/pmaports/device/main/linux-postmarketos-stable/config-stable.x86_64'
fi
if [ "$_ko" -gt 0 ]; then
    if [ "${OSMO_ISO_LTE_REQUIRED:-1}" = "1" ]; then
        echo -e "  ${RED}✗ $_ko maillon(s) manquant(s) : cette ISO ne serait PAS prete a l emploi (2G + 4G + telephone).${NC}" >&2
        echo -e "    Corrige ci-dessus, ou OSMO_ISO_LTE_REQUIRED=0 pour sortir l ISO quand meme." >&2
        _iso88_down
        exit 1
    fi
    echo -e "  ${YELLOW}!${NC} $_ko maillon(s) manquant(s), ISO sortie quand meme (OSMO_ISO_LTE_REQUIRED=0)"
else
    echo -e "  ${GREEN}✓${NC} prete a l emploi : banc 2G, 4G et telephone au complet"
fi
unset _ko; unset -f _chk

# Unmount what was mounted above, otherwise the squashfs of 90-iso.sh would
# include the host's /proc and /sys.
_iso88_down; unset _iso88_mnt; unset -f _iso88_up _iso88_down


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
