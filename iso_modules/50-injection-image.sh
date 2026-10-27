#!/bin/bash
# iso_modules/50-injection-image.sh - step 5: build .debs first, then docker cp of the image
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment:
#   OSMO_DEB_CACHE=<dir>  host cache of the build .debs (default /var/cache/osmo-debs)
#   ISO_EMBED_DEBS=1      keep the .debs in the ISO (/var/cache/osmo-debs)

# ── Step 5: the .debs OF THE DOCKER BUILD first, then the rest of the image ──
# What the image compiled is packaged (packaging/osmo-deb.sh): libosmocore and
# the osmo-*, gapk, QEMU and its tree, osmocom-bb, the gr-gsm venv, the
# firmware. They are installed into the rootfs with dpkg; only what is not
# packaged is copied from the image (scripts, configs, units, node, the repo).
# Package source: the HOST cache (/var/cache/osmo-debs, fed by build.sh), else
# the cache embedded in the image. Only those of the rootfs suite/arch are
# taken. Without packages, the full docker cp is used.
if [ "$OSMO_ISO_INHERITED" = "1" ]; then
    echo -e "${GREEN}[5/9] Injection : rootfs herite, deja fait${NC}"
else
echo -e "${GREEN}[5/9] Injection stack Osmocom (paquets .deb du build, puis image)...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
ISO_DEB_HOST_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
_iso_debs="$WORK/debs-build"; mkdir -p "$_iso_debs"
# Suite AND architecture: the host cache holds the packages of both
# architectures side by side (..._amd64.deb, ..._arm64.deb).
cp -f "$ISO_DEB_HOST_CACHE"/osmo-build-*"~${ISO_SUITE}_${ISO_ARCH}.deb" "$_iso_debs/" 2>/dev/null || true
if ! ls "$_iso_debs"/*.deb >/dev/null 2>&1; then
    docker cp "$CID:/var/cache/osmo-debs/." "$_iso_debs/" 2>/dev/null || true
    find "$_iso_debs" -name '*.deb' ! -name "*~${ISO_SUITE}_${ISO_ARCH}.deb" -delete 2>/dev/null || true
fi
# The hub only needs the STP: libosmocore, libosmo-netif, libosmo-sigtran.
if [ "$ISO_ROLE" = "interstp" ]; then
    find "$_iso_debs" -name '*.deb' ! -name 'osmo-build-libosmocore_*' \
        ! -name 'osmo-build-libosmo-netif_*' ! -name 'osmo-build-libosmo-sigtran_*' -delete 2>/dev/null || true
fi
ISO_DEBS_USED=0
_ndebs=$(find "$_iso_debs" -maxdepth 1 -name '*.deb' | wc -l)
if [ "$_ndebs" -gt 0 ]; then
    # Installed from a directory INSIDE the rootfs (dpkg reads its packages
    # under the root), removed afterwards: the packages only travel in the ISO
    # with ISO_EMBED_DEBS=1 (a zstd QEMU tree in an image that fits in RAM
    # is not a given).
    install -d "$ROOTFS/var/cache/osmo-debs"
    cp -f "$_iso_debs"/*.deb "$ROOTFS/var/cache/osmo-debs/"
    if chroot "$ROOTFS" sh -c 'dpkg -i --force-overwrite /var/cache/osmo-debs/osmo-build-*.deb' \
           > "$WORK/dpkg-debs.log" 2>&1; then
        chroot "$ROOTFS" ldconfig 2>/dev/null || true
        ISO_DEBS_USED=1
        echo -e "  ${GREEN}✓${NC} ${_ndebs} paquets du build docker poses par dpkg ($(du -sh "$_iso_debs" | cut -f1))"
    else
        echo -e "  ${YELLOW}⚠${NC} dpkg -i des paquets du build a echoue (voir $WORK/dpkg-debs.log) - repli sur l image" >&2
        tail -5 "$WORK/dpkg-debs.log" | sed 's/^/     /' >&2
    fi
    [ "${ISO_EMBED_DEBS:-0}" = "1" ] || rm -rf "$ROOTFS/var/cache/osmo-debs"
else
    echo -e "  ${CYAN}aucun paquet .deb du build pour ${ISO_SUITE} (cache ${ISO_DEB_HOST_CACHE}) - tout vient de l image${NC}"
fi
docker cp "$CID:/usr/local/bin/." "$ROOTFS/usr/local/bin/"  2>/dev/null||true
docker cp "$CID:/usr/local/lib/." "$ROOTFS/usr/local/lib/"  2>/dev/null||true
docker cp "$CID:/usr/local/include/." "$ROOTFS/usr/local/include/" 2>/dev/null||true
docker cp "$CID:/usr/local/sbin/." "$ROOTFS/usr/local/sbin/" 2>/dev/null||true
# /opt/GSM: everything EXCEPT the trees the packages just installed (osmocom-bb,
# qosmo, qemu-install, firmware) - and nothing at all for the hub, which does
# not read any of it (the repo itself is cloned at step 5a).
if [ "$ISO_ROLE" != "interstp" ]; then
    _excl=()
    if [ "$ISO_DEBS_USED" = "1" ]; then
        for _t in osmocom-bb qosmo c54x_exe grgsm_exe qemu-install firmware; do
            [ -d "$ROOTFS/opt/GSM/$_t" ] && _excl+=("--exclude=GSM/$_t" "--exclude=GSM/$_t/*")
        done
    fi
    mkdir -p "$ROOTFS/opt"
    docker cp "$CID:/opt/GSM" - 2>/dev/null | tar -x -C "$ROOTFS/opt" "${_excl[@]+"${_excl[@]}"}" 2>/dev/null || true
fi
# Python venv (gr-gsm + bridges) expected by the bridge (grgsm_exe, pont/*.py)
# - as a package (grgsm-venv) when the cache has it, from the image otherwise.
[ -d "$ROOTFS/root/.env" ] || docker cp "$CID:/root/.env" "$ROOTFS/root/" 2>/dev/null||true
[ -d "$ROOTFS/root/.venv-qemu" ] || docker cp "$CID:/root/.venv-qemu" "$ROOTFS/root/" 2>/dev/null||true
docker cp "$CID:/opt/node"            "$ROOTFS/opt/"        2>/dev/null||true
docker cp "$CID:/etc/osmocom/."       "$ROOTFS/etc/osmocom/" 2>/dev/null||true
docker cp "$CID:/etc/asterisk/."      "$ROOTFS/etc/asterisk/" 2>/dev/null||true
for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
    docker cp "$CID:/lib/systemd/system/${svc}.service" "$ROOTFS/lib/systemd/system/" 2>/dev/null||true
done
docker rm "$CID" &>/dev/null
echo -e "  ${GREEN}✓${NC} binaires + libs + configs injectes"
fi


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
