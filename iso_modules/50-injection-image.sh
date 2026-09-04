#!/bin/bash
# iso_modules/50-injection-image.sh - etape 5 : .deb du build puis docker cp de l image
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 5 : LES .deb DU BUILD DOCKER D ABORD, puis le reste de l image ────
# [2026-09-03] Ce que l image a compile est sorti en paquets (packaging/
# osmo-deb.sh) : libosmocore et les osmo-*, gapk, QEMU et son arbre, osmocom-bb,
# le venv gr-gsm, le firmware. On les pose dans le rootfs par dpkg, comme sur
# n importe quelle machine, et on ne recopie de l image que ce qui n est pas
# en paquet (scripts, configs, unites, node, le depot, les ateliers restants).
# Source des paquets : le cache de l HOTE (/var/cache/osmo-debs, que build.sh
# alimente), sinon le cache embarque dans l image. Seuls ceux de la suite du
# rootfs (~noble) sont pris. Sans paquet, on retombe sur le docker cp complet.
if [ "$OSMO_ISO_INHERITED" = "1" ]; then
    echo -e "${GREEN}[5/9] Injection : rootfs herite, deja fait${NC}"
else
echo -e "${GREEN}[5/9] Injection stack Osmocom (paquets .deb du build, puis image)...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
ISO_DEB_HOST_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
_iso_debs="$WORK/debs-build"; mkdir -p "$_iso_debs"
# Suite ET architecture : le cache de l hote porte les paquets des deux
# architectures cote a cote (..._amd64.deb, ..._arm64.deb).
cp -f "$ISO_DEB_HOST_CACHE"/osmo-build-*"~${ISO_SUITE}_${ISO_ARCH}.deb" "$_iso_debs/" 2>/dev/null || true
if ! ls "$_iso_debs"/*.deb >/dev/null 2>&1; then
    docker cp "$CID:/var/cache/osmo-debs/." "$_iso_debs/" 2>/dev/null || true
    find "$_iso_debs" -name '*.deb' ! -name "*~${ISO_SUITE}_${ISO_ARCH}.deb" -delete 2>/dev/null || true
fi
# Le hub n a besoin que du STP : libosmocore, libosmo-netif, libosmo-sigtran.
if [ "$ISO_ROLE" = "interstp" ]; then
    find "$_iso_debs" -name '*.deb' ! -name 'osmo-build-libosmocore_*' \
        ! -name 'osmo-build-libosmo-netif_*' ! -name 'osmo-build-libosmo-sigtran_*' -delete 2>/dev/null || true
fi
ISO_DEBS_USED=0
_ndebs=$(find "$_iso_debs" -maxdepth 1 -name '*.deb' | wc -l)
if [ "$_ndebs" -gt 0 ]; then
    # Poses via un repertoire DANS le rootfs (dpkg lit ses paquets sous la
    # racine), retire ensuite : les paquets ne voyagent dans l ISO que sur
    # ISO_EMBED_DEBS=1 - un arbre QEMU en zstd dans une image qui tient en RAM,
    # ca ne va pas de soi.
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
# /opt/GSM : tout, SAUF les arbres que les paquets viennent de poser (osmocom-bb,
# qosmo-grgsm, qemu-install, firmware) - et rien du tout pour le hub, qui n en
# lit pas une ligne (le depot lui-meme est clone a l etape 5a).
if [ "$ISO_ROLE" != "interstp" ]; then
    _excl=()
    if [ "$ISO_DEBS_USED" = "1" ]; then
        for _t in osmocom-bb qosmo-grgsm qosmo-dsp qemu-install qemu-dsp-install firmware; do
            [ -d "$ROOTFS/opt/GSM/$_t" ] && _excl+=("--exclude=GSM/$_t" "--exclude=GSM/$_t/*")
        done
    fi
    mkdir -p "$ROOTFS/opt"
    docker cp "$CID:/opt/GSM" - 2>/dev/null | tar -x -C "$ROOTFS/opt" "${_excl[@]+"${_excl[@]}"}" 2>/dev/null || true
fi
# venv python (gr-gsm + bridges) attendu par /opt/GSM/qosmo-grgsm/start-clean.sh
# - en paquet (grgsm-venv) quand le cache l a, depuis l image sinon.
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


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
