#!/bin/bash
# iso_modules/88-lte-pmos.sh - etape 8d : la 4G (srsRAN ZeroMQ + Open5GS) et
# l UI smartphone (postmarketOS, noyau PPP) dans le rootfs
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 8d : LA 4G ET LE TELEPHONE, DEPUIS LE NATIF ───────────────────────
# [2026-09-08] Jusqu ici l ISO n avait NI srsRAN, NI Open5GS, NI le noyau
# postmarketOS PPP : tout vivait hors depot sur la machine de reference
# (/opt/LTE, /root/open5gs, ~nirvana/test). Ce module les pose, a partir de
# ce que les etapes precedentes ont deja mis dans le rootfs :
#
#   - LES BINAIRES viennent des .deb de /var/cache/osmo-debs, poses par
#     50-injection-image.sh avec tous les osmo-build-* :
#       osmo-build-libzmq, osmo-build-srsran (-> /opt/LTE/srsRAN_4G, /usr/local/bin),
#       osmo-build-open5gs (-> /opt/LTE/open5gs, prefixe install/),
#       osmo-build-pmos-kernel (-> /opt/user_interface/kernel/pmos),
#       osmo-build-pmbootstrap (-> /opt/user_interface/pmos/pmbootstrap, patche).
#     Ils sont produits soit par packaging/snapshot-lte-debs.sh (le natif,
#     photographie), soit par le Dockerfile (compiles depuis les sources) -
#     le noyau pmOS n a que le premier chemin (pmbootstrap, hors docker).
#   - LES PAQUETS apt (runtime) sont dans PKGS de 80-chroot.sh, et le depot
#     MongoDB y est ajoute avant l unique apt-get update.
#   - LES CONFIGS ET LANCEURS sont ceux du depot : tools/osmo-lte-install.sh
#     (configs/srsran -> /root/.config/srsran, configs/open5gs -> le prefixe,
#     osmo-lte / osmo-epc) et tools/osmo-pmos-install.sh (/opt/user_interface/
#     pmos : bin/, patches/, gabarit pmbootstrap, lanceurs et .desktop).
#     Les deux tournent DANS le chroot, depuis CE depot (pas le clone GitHub
#     de l image, qui peut etre en retard).
#   - L IMAGE DE LA VM (5 Go creux, ~2 Go en zstd) n est PAS embarquee par
#     defaut : OSMO_ISO_PMOS_IMAGE=/chemin/qemu-amd64.img.zst la range dans
#     /opt/user_interface/pmos/image/, et osmo-pmos-build la decompresse au
#     lieu de faire « pmbootstrap install ».
#
# Le hub (interstp) n a pas de 4G. --arm non plus (srsRAN et Open5GS ne sont
# pas compiles pour arm64, pmbootstrap y ferait une VM x86 emulee).
if [ "$ISO_ROLE" = "interstp" ] || [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

echo -e "${GREEN}[8d/9] La 4G (srsRAN ZeroMQ + Open5GS) et l UI smartphone (postmarketOS)...${NC}"
_rt="$ROOTFS/opt/GSM/osmo-operator"
install -d "$_rt/tools" "$_rt/configs/srsran" "$_rt/configs/open5gs" "$_rt/configs/pmos" "$_rt/patches" "$_rt/packaging"
# Le depot local fait foi (meme regle que 85-installeur-bureau.sh).
for _f in osmo-lte.sh osmo-epc.sh osmo-lte-install.sh osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh \
          osmo-pmos-build.sh osmo-pmos-install.sh osmo-phonesim-banc.py at-cmd.py; do
    [ -f "$DIR/tools/$_f" ] && install -m755 "$DIR/tools/$_f" "$_rt/tools/"
done
install -m644 "$DIR"/configs/srsran/* "$_rt/configs/srsran/"
install -m644 "$DIR"/configs/open5gs/*.yaml "$DIR"/configs/open5gs/*.json "$_rt/configs/open5gs/" 2>/dev/null || true
[ -d "$DIR/configs/open5gs/dump" ] && cp -a "$DIR/configs/open5gs/dump" "$_rt/configs/open5gs/"
install -m644 "$DIR"/configs/pmos/* "$_rt/configs/pmos/"
for _f in pmbootstrap-osmo-bench-qemu.patch pmaports-linux-postmarketos-stable-ppp.patch; do
    [ -f "$DIR/patches/$_f" ] && install -m644 "$DIR/patches/$_f" "$_rt/patches/"
done
for _f in build-pmos-kernel-deb.sh snapshot-lte-debs.sh osmo-deb.sh; do
    [ -f "$DIR/packaging/$_f" ] && install -m755 "$DIR/packaging/$_f" "$_rt/packaging/"
done
unset _f

# Le noyau pmOS PPP absent du cache : GitHub (Git LFS, bbaranoff/pmos_ppp_kernel)
# le fournit - dans le cache de l hote, pour la prochaine fois, et dans le rootfs.
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

# Ce que les .deb ont pose (ou pas) : on le dit, on ne s arrete pas.
for _c in "srsenb:/usr/local/bin/srsenb" "Open5GS:/opt/LTE/open5gs/install/bin/open5gs-mmed" \
          "noyau pmOS PPP:/opt/user_interface/kernel/pmos/APKINDEX.tar.gz" \
          "pmbootstrap:/opt/user_interface/pmos/pmbootstrap/pmbootstrap.py"; do
    if [ -e "$ROOTFS/${_c#*:}" ]; then echo -e "  ${GREEN}✓${NC} ${_c%%:*} (.deb du build)"
    else echo -e "  ${YELLOW}!${NC} ${_c%%:*} absent du rootfs - pas de .deb dans /var/cache/osmo-debs (packaging/snapshot-lte-debs.sh sur la machine de reference, ou le Dockerfile)"; fi
done
unset _c

# Le depot MongoDB de 80-chroot.sh est deja la : --deps ne fait ici que les
# paquets qui manqueraient encore (et enable mongod). Puis configs, lanceurs.
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --deps --debs --configs --launchers 2>&1 | sed 's/^/  /'
chroot "$ROOTFS" env OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-pmos-install.sh 2>&1 | sed 's/^/  /'

# [2026-09-08] L IMAGE DE REFERENCE, PAR DEFAUT. Le build du soir avait ete
# lance sans OSMO_ISO_PMOS_IMAGE : l ISO avait srsRAN, Open5GS, le noyau PPP
# et pmbootstrap, mais PAS le telephone - le premier osmo-pmos retombait sur
# un « pmbootstrap install » complet (long, reseau). La machine de reference
# porte pourtant l image prete a l endroit meme ou osmo-pmos-build la cherche
# (/opt/user_interface/pmos/image). Si la variable n est pas donnee, on prend
# donc celle de l hote : l ISO devient ce qu est le disque. Le .zst pret est
# prefere ; a defaut l image brute de pmbootstrap, compressee au passage.
# OSMO_ISO_PMOS_IMAGE=none pour ne rien embarquer.
if [ -z "${OSMO_ISO_PMOS_IMAGE:-}" ]; then
    for _cand in /opt/user_interface/pmos/image/qemu-amd64.img.zst \
                 "${OSMO_PMB_WORK:-/root/test}"/chroot_native/home/pmos/rootfs/qemu-amd64.img \
                 /home/*/test/chroot_native/home/pmos/rootfs/qemu-amd64.img; do
        [ -f "$_cand" ] || continue
        OSMO_ISO_PMOS_IMAGE="$_cand"
        echo -e "  ${CYAN}·${NC} image de la VM de reference trouvee sur l hote : $_cand"
        break
    done
    unset _cand
fi
[ "${OSMO_ISO_PMOS_IMAGE:-}" = "none" ] && OSMO_ISO_PMOS_IMAGE=""
# L image de la VM : celle donnee, ou celle de l hote (voir ci-dessus).
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

# Le compte de session lancera pmbootstrap : /opt/user_interface doit lui
# etre lisible, et le gabarit de config est pose dans /etc/skel pour qu un
# compte cree par Calamares le trouve (shellprocess-osmo.conf y met les
# chemins de SON home).
chroot "$ROOTFS" chmod -R a+rX /opt/user_interface 2>/dev/null || true
install -d "$ROOTFS/etc/skel/.config"
install -m644 "$DIR/configs/pmos/pmbootstrap_v3.cfg" "$ROOTFS/etc/skel/.config/pmbootstrap_v3.cfg.osmo"

# Lite : les objets de compilation de /opt/LTE ne servent pas a tourner.
if [ "$ISO_LITE" = "1" ]; then
    _before=$(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)
    find "$ROOTFS/opt/LTE/srsRAN_4G/build" "$ROOTFS/opt/LTE/open5gs/build" -name '*.o' -delete 2>/dev/null || true
    rm -rf "$ROOTFS/opt/LTE/libzmq" "$ROOTFS/opt/LTE/czmq" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} lite : /opt/LTE ${_before:-?} -> $(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)"
fi
unset _rt _before


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
