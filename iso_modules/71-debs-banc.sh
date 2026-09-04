#!/bin/bash
# iso_modules/71-debs-banc.sh - etape 7c : .deb du banc embarques
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 7c : les paquets .deb du banc, EMBARQUES dans l image ─────────────
# packaging/build-debs.sh fabrique un .deb par composant (osmo-operator, pont,
# qemu-calypso, calypso-firmware) depuis les arbres que cette ISO embarque de
# toute facon. On les range dans /var/cache/osmo-debs : une machine installee
# depuis l ISO, ou n importe quelle autre, peut alors faire
#     dpkg -i /var/cache/osmo-debs/*.deb
# et obtenir le banc sans Docker ni git. L ISO elle-meme continue de tourner
# sur les arbres complets (le depot et qosmo-grgsm avec leur .git : c est un
# atelier) - les paquets ne les remplacent pas, ils voyagent avec.
# Non fatal : sans dpkg-deb ou sans qemu construit, l image sort sans eux.
# --arm : build-debs.sh compile le lanceur C et lit les binaires par ldd - sur
# l hote ce serait du x86 etiquete arm64. Il tourne DANS le chroot, apres l apt
# de l etape 8 (82-arm-natif).
if [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then
    echo -e "  ${CYAN}·${NC} paquets .deb du banc : fabriques dans le chroot ${ISO_ARCH} plus loin"
elif [ -x "$DIR/packaging/build-debs.sh" ] && command -v dpkg-deb >/dev/null 2>&1; then
    echo -e "${GREEN}[7c/9] Paquets .deb du banc...${NC}"
    _DEBS="$WORK/debs"
    if OSMO_OPERATOR_SRC="$DIR" QOSMO_SRC="$ROOTFS/opt/GSM/qosmo-grgsm" \
       FIRMWARE_SRC="$ROOTFS/opt/GSM/firmware" \
       "$DIR/packaging/build-debs.sh" --out "$_DEBS" >"$WORK/build-debs.log" 2>&1; then
        install -d "$ROOTFS/var/cache/osmo-debs"
        cp -f "$_DEBS"/*.deb "$ROOTFS/var/cache/osmo-debs/"
        echo -e "  ${GREEN}✓${NC} $(ls "$_DEBS"/*.deb | wc -l) paquets dans ${CYAN}/var/cache/osmo-debs${NC} ($(du -sh "$_DEBS" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} paquets .deb non construits (voir $WORK/build-debs.log) - l image sort sans eux"
    fi
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
