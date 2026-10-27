#!/bin/bash
# iso_modules/71-debs-banc.sh - step 7c: bench .debs embedded in the image
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment: ISO_WITH_DEBS=0 (--without-debs) skips this step.

# ── Step 7c: the bench .deb packages, EMBEDDED in the image ──────────────────
# packaging/build-debs.sh builds one .deb per component (osmo-operator, pont,
# qemu-calypso, calypso-firmware) from the trees this ISO embeds anyway. They
# are stored in /var/cache/osmo-debs: a machine installed from the ISO, or any
# other, can then run
#     dpkg -i /var/cache/osmo-debs/*.deb
# and get the bench without Docker or git. The ISO itself keeps running on the
# full trees (the repo and qosmo with their .git) - the packages travel along,
# they do not replace them.
# Non-fatal: without dpkg-deb or without a built qemu, the image ships without them.
# --arm: build-debs.sh compiles the C launcher and reads binaries with ldd - on
# the host that would be x86 labelled arm64. It runs INSIDE the chroot, after
# the apt of step 8 (82-arm-natif).
if [ "${ISO_WITH_DEBS:-1}" = "0" ]; then
    echo -e "  ${CYAN}·${NC} --without-debs : aucun paquet .deb embarque dans l'image"
elif [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then
    echo -e "  ${CYAN}·${NC} paquets .deb du banc : fabriques dans le chroot ${ISO_ARCH} plus loin"
elif [ -x "$DIR/packaging/build-debs.sh" ] && command -v dpkg-deb >/dev/null 2>&1; then
    echo -e "${GREEN}[7c/9] Paquets .deb du banc...${NC}"
    _DEBS="$WORK/debs"
    if OSMO_OPERATOR_SRC="$DIR" QOSMO_SRC="$ROOTFS/opt/GSM/qosmo" \
       FIRMWARE_SRC="$ROOTFS/opt/GSM/firmware" \
       "$DIR/packaging/build-debs.sh" --out "$_DEBS" >"$WORK/build-debs.log" 2>&1; then
        install -d "$ROOTFS/var/cache/osmo-debs"
        cp -f "$_DEBS"/*.deb "$ROOTFS/var/cache/osmo-debs/"
        echo -e "  ${GREEN}✓${NC} $(ls "$_DEBS"/*.deb | wc -l) paquets dans ${CYAN}/var/cache/osmo-debs${NC} ($(du -sh "$_DEBS" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} paquets .deb non construits (voir $WORK/build-debs.log) - l image sort sans eux"
    fi
fi


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
