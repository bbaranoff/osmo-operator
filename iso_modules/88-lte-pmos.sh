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
#     CACHE VIDE : srsRAN et Open5GS sont COMPILES ICI, dans le chroot, par le
#     meme tools/osmo-lte-install.sh --build (voir le bloc plus bas), et les
#     .deb produits repartent dans le cache de l hote. OSMO_ISO_LTE_BUILD=0
#     refuse ce rattrapage.
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
# [2026-09-09] CE QUE LE LIVE A APPRIS - l ISO du 3953233 avait TOUT (binaires,
# lanceurs, pmbootstrap, noyau PPP, image de reference), et ni la 4G ni le
# telephone ne marchaient :
#   - open5gs-mmed (et hssd, pcrfd, smfd) mourait a l init : PAS de
#     etc/freeDiameter/*.conf ni de etc/open5gs/tls/. Open5GS les pose par un
#     script meson qui ne fait RIEN sous DESTDIR, et osmo-deb pack installe
#     sous DESTDIR : le .deb n a que bin/ et lib/. Les yaml, osmo-lte-install
#     les reposait ; freeDiameter, personne. Sans MME, pas de S1AP : srsUE
#     recevait ConnectionReject, jamais d attach. Les .conf sont maintenant
#     dans le depot (configs/open5gs/freeDiameter), poses avec des certificats
#     par osmo-lte-install --configs ; le controle final les exige ET fait
#     demarrer open5gs-mmed 3 s dans le chroot.
#   - l icone du telephone lancait « pmbootstrap qemu » en root (la session
#     de l ISO est root) : « Do not run pmbootstrap as root! ». Et aucun
#     compte n avait de ~/.config/pmbootstrap_v3.cfg : le gabarit n etait
#     que dans /etc/skel, rempli APRES la creation des comptes (84-comptes).
#     Les lanceurs passent --as-root en root, le cfg est ecrit dans /root et
#     /home/osmocom ici, et osmo-pmos-qemu enchaine osmo-pmos-build quand
#     l image n est pas encore la.
#   - pmbootstrap exige kpartx, absent de l ISO (PKGS de 80-chroot.sh).
#   - le premier clic clonait pmaports en entier depuis GitLab, et le clone
#     echouait presque a chaque fois : le commit du noyau est pose ICI dans
#     /opt/user_interface/pmos/pmaports (fetch --depth 1, 110 Mo), et
#     osmo-pmos-build le copie au lieu de cloner.
#   - le son : la VM nue (sans modem) sortait sur la carte PONT, inaudible ;
#     osmo-pmos-qemu appelle osmo-pmos-setup --voix des que le SSH repond,
#     et le disque est bootindex=0 (patch pmbootstrap) - plus de detour PXE.
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
# [2026-09-09] freeDiameter : les .conf du depot (le .deb n en a pas, voir mme.conf).
[ -d "$DIR/configs/open5gs/freeDiameter" ] && cp -a "$DIR/configs/open5gs/freeDiameter" "$_rt/configs/open5gs/"
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
# paquets qui manqueraient encore (et enable mongod). Puis les .deb du cache.
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --deps --debs 2>&1 | sed 's/^/  /'

# ── PAS DE .deb : ON COMPILE DANS LE CHROOT ─────────────────────────────────
# [2026-09-09] L ISO n avait qu UN chemin vers ses binaires 4G : les .deb du
# build docker (ou du snapshot natif). Le jour ou le Dockerfile est tombe -
# cmake de srsRAN, « Could NOT find MbedTLS », deps apt absentes de l image -
# le cache est reste vide et l ISO est sortie SANS srsRAN ni Open5GS, avec
# pour seule trace le « ! absent du rootfs » ci-dessus. Une ISO muette sur sa
# 4G, c est un banc qu on decouvre casse a l usage.
#
# Le chroot a tout ce qu il faut pour compiler : les -dev sont dans PKGS de
# 80-chroot.sh (libmbedtls-dev, libzmq3-dev, libconfig++-dev, boost, meson,
# flex, bison, libmongoc-dev...), --deps vient de repasser, et /proc /sys /dev
# et le resolv.conf de l hote y sont montes (git clone possible). On rejoue
# donc le MEME script que le Dockerfile et que le natif : --build.
#
# OSMO_DEB=1 : la compilation sort en .deb, qu on RAMENE dans le cache de
# l hote - la prochaine ISO (et le prochain docker) ne recompileront pas.
# OSMO_ISO_LTE_BUILD=0 pour refuser ce rattrapage (build court, ISO sans 4G).
if [ ! -x "$ROOTFS/usr/local/bin/srsenb" ] || [ ! -x "$ROOTFS/opt/LTE/open5gs/install/bin/open5gs-mmed" ]; then
    if [ "${OSMO_ISO_LTE_BUILD:-1}" = "1" ]; then
        echo -e "  ${YELLOW}!${NC} 4G absente du cache .deb : compilation dans le chroot (long)"
        install -d "$ROOTFS/var/cache/osmo-debs"
        [ -f "$DIR/packaging/osmo-deb.sh" ] && install -m755 "$DIR/packaging/osmo-deb.sh" "$ROOTFS/usr/local/sbin/osmo-deb"
        chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive OSMO_DEB=1 OSMO_REPO=/opt/GSM/osmo-operator \
            bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --build 2>&1 | sed 's/^/  /' \
            || echo -e "  ${YELLOW}!${NC} compilation 4G echouee dans le chroot - ISO sans srsRAN/Open5GS"
        # Les .deb fraichement produits repartent dans le cache de l hote.
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

# Les configs Open5GS ne se posent que si le prefixe existe : APRES le build.
chroot "$ROOTFS" env OSMO_REPO=/opt/GSM/osmo-operator \
    bash /opt/GSM/osmo-operator/tools/osmo-lte-install.sh --configs --launchers 2>&1 | sed 's/^/  /'
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

# [2026-09-13] ET SUR UN RUNNER GITHUB ? Aucune machine de reference : pas de
# /opt/user_interface/pmos/image, pas de dossier de travail pmbootstrap - la
# boucle ci-dessus ne trouve rien et l ISO de la CI sort sans telephone pret.
# Meme remede que pour le noyau (plus haut), mais PAS par Git LFS : 1,7 Go
# creveraient le quota LFS (1 Go de stockage et 1 Go de trafic par mois). Un
# ASSET DE RELEASE n a pas de quota de trafic et plafonne a 2 Gio par fichier -
# l image y tient. Publier une fois, depuis la machine de reference :
#
#   gh release create pmos-image --repo bbaranoff/osmo-operator \
#       --title "postmarketOS - VM de reference (noyau PPP)" --notes "..." \
#       /opt/user_interface/pmos/image/qemu-amd64.img.zst
#
# puis OSMO_PMOS_IMAGE_URL=<url de l asset> au build (le workflow le passe).
# Vide = on ne telecharge rien : c est le defaut, l image pese trois fois son
# poids dans un build --all (operator, lite, desktop).
if [ -z "${OSMO_ISO_PMOS_IMAGE:-}" ] && [ -n "${OSMO_PMOS_IMAGE_URL:-}" ]; then
    _icache="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}/qemu-amd64.img.zst"
    echo -e "  ${CYAN}·${NC} image de la VM : telechargement depuis $OSMO_PMOS_IMAGE_URL"
    install -d "$(dirname "$_icache")"
    # zstd -t : un 404 ou une coupure donnent un fichier bien forme pour curl et
    # illisible pour zstd - c est ici qu on veut le savoir, pas dans l ISO.
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

# ── PMAPORTS DANS L ISO, AU COMMIT DU NOYAU ─────────────────────────────────
# [2026-09-09] Le premier clic sur le telephone clonait pmaports EN ENTIER
# depuis GitLab (des centaines de Mo) ; depuis le live, deux essais sur trois
# ont echoue, et git efface tout a l echec : « ca me clone a chaque fois et
# ca boot pas ». On pose donc ici le SEUL commit qu il faut - celui du noyau
# PPP (kernel/pmos/pmaports.commit), fetch --depth 1, quelques dizaines de
# Mo, avec la ref origin/main que pmbootstrap exige pour lire channels.cfg -
# dans /opt/user_interface/pmos/pmaports ; osmo-pmos-build le COPIE dans
# le dossier de travail du compte au lieu de cloner. Garde dans le cache de
# l hote (OSMO_DEB_CACHE) pour les ISO suivantes. OSMO_ISO_PMAPORTS=0 pour
# s en passer.
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

# Le compte de session lancera pmbootstrap : /opt/user_interface doit lui
# etre lisible, et le gabarit de config est pose dans /etc/skel pour qu un
# compte cree par Calamares le trouve (shellprocess-osmo.conf y met les
# chemins de SON home).
chroot "$ROOTFS" chmod -R a+rX /opt/user_interface 2>/dev/null || true
install -d "$ROOTFS/etc/skel/.config"
install -m644 "$DIR/configs/pmos/pmbootstrap_v3.cfg" "$ROOTFS/etc/skel/.config/pmbootstrap_v3.cfg.osmo"
# [2026-09-09] ET DANS LES COMPTES QUI EXISTENT DEJA. /etc/skel ne sert qu aux
# comptes crees APRES : root et osmocom le sont par 84-comptes.sh, avant ce
# module - sur l ISO aucun des deux n avait de ~/.config/pmbootstrap_v3.cfg,
# et la session s ouvre sur root. Meme substitution que shellprocess-osmo.conf
# (dossier de travail ~/.local/var/pmbootstrap).
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

# Lite : les objets de compilation de /opt/LTE ne servent pas a tourner.
if [ "$ISO_LITE" = "1" ]; then
    _before=$(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)
    find "$ROOTFS/opt/LTE/srsRAN_4G/build" "$ROOTFS/opt/LTE/open5gs/build" -name '*.o' -delete 2>/dev/null || true
    rm -rf "$ROOTFS/opt/LTE/libzmq" "$ROOTFS/opt/LTE/czmq" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} lite : /opt/LTE ${_before:-?} -> $(du -sh "$ROOTFS/opt/LTE" 2>/dev/null | cut -f1)"
fi
unset _rt _before

# ── LE CONTROLE FINAL : L ISO DOIT ETRE PRETE A L EMPLOI, 2G + 4G + TELEPHONE ─
# [2026-09-09] Jusqu ici ce module ne faisait que DIRE ce qui manquait (les
# « ! absent du rootfs » plus haut) et l ISO sortait quand meme - une ISO ou
# l icone « 4G du banc » ne lancait rien, ou Open5GS n avait pas de mme.yaml
# (donc pas de SGs, donc pas de CSFB), ou mongod manquait (le HSS meurt a
# l init, l attach echoue). Or ce qu on attend d elle est simple : l
# operateur clique « Lancer le banc GSM », puis « 4G du banc », puis « le
# telephone pmOS », et ca marche. On verifie donc ICI, dans le rootfs, chaque
# maillon de ces trois gestes, et on ARRETE le build s il en manque un :
# mieux vaut une heure de build perdue qu une cle qui ment.
# OSMO_ISO_LTE_REQUIRED=0 pour ne faire que l inventaire (ISO sans 4G assumee).
echo -e "  ${CYAN}·${NC} controle final : 2G + 4G + telephone dans le rootfs"
_ko=0
_chk() {  # _chk <libelle> <test chroot...>
    local l="$1"; shift
    if chroot "$ROOTFS" "$@" >/dev/null 2>&1; then echo -e "      ${GREEN}✓${NC} $l"
    else echo -e "      ${RED}✗${NC} $l"; _ko=$((_ko + 1)); fi
}
# La 2G : le banc, son unite, et le SGs d osmo-msc (l attach combine, le CSFB)
_chk "2G  launch.sh (icone « Lancer le banc GSM »)"       test -x /opt/GSM/osmo-operator/launch.sh
_chk "2G  osmo-banc.service"                               test -s /etc/systemd/system/osmo-banc.service
_chk "2G  osmo-msc.cfg : section sgs (CSFB)"               grep -q '^sgs' /etc/osmocom/osmo-msc.cfg
# La 4G : binaires, configs (dont le SGs cote MME), lanceurs, unite, MongoDB
_chk "4G  srsenb / srsue"                                  bash -c 'test -x /usr/local/bin/srsenb && test -x /usr/local/bin/srsue'
# ── ET LEURS BIBLIOTHEQUES SONT-ELLES TOUTES LA ? ───────────────────────────
# [2026-09-10] srsRAN est desormais compile avec ENABLE_GUI=ON : srsenb et
# srsue se LIENT a libsrsgui (srsGUI, /usr/local/lib), posee avant eux par
# osmo-build-srsgui. Une image qui aurait les binaires SANS la bibliotheque
# donnerait « error while loading shared libraries: libsrsgui.so » au premier
# clic sur l icone 4G - et rien avant. Le `ldd` couvre srsgui comme le reste.
_chk "4G  srsenb / srsue : bibliotheques toutes resolues" \
    bash -c 'for b in srsenb srsue; do ldd /usr/local/bin/$b 2>/dev/null | grep -q "not found" && exit 1; done; exit 0'
# Les traces temps reel sont un bonus, pas une condition : on les ANNONCE.
if chroot "$ROOTFS" bash -c 'ldd /usr/local/bin/srsenb 2>/dev/null | grep -q libsrsgui' 2>/dev/null; then
    echo -e "      ${GREEN}✓${NC} 4G  srsGUI : traces temps reel armees (srsenb lie a libsrsgui)"
else
    echo -e "      ${CYAN}·${NC} 4G  srsGUI absent : srsenb sans traces temps reel (« osmo-lte-install --build »)"
fi
_chk "4G  open5gs-mmed / open5gs-hssd"                     bash -c 'test -x /opt/LTE/open5gs/install/bin/open5gs-mmed && test -x /opt/LTE/open5gs/install/bin/open5gs-hssd'
_chk "4G  mme.yaml du depot avec sgsap (CSFB)"             grep -q '^  sgsap:' /opt/LTE/open5gs/install/etc/open5gs/mme.yaml
_chk "4G  freeDiameter mme/hss/pcrf/smf.conf (S6a, Gx)"   bash -c 'for n in mme hss pcrf smf; do test -s /opt/LTE/open5gs/install/etc/freeDiameter/$n.conf || exit 1; done'
_chk "4G  TLS freeDiameter (ca + mme/hss/pcrf/smf)"       bash -c 'for n in ca mme hss pcrf smf; do test -s /opt/LTE/open5gs/install/etc/open5gs/tls/$n.crt || exit 1; done'
# Et le MME DEMARRE-T-IL ? 3 s au premier plan dans le chroot : une config
# absente ou une lib manquante se voient LA, pas au premier clic (c est
# exactement la panne du live du 2026-09-09). Un port deja pris sur l hote
# (sa propre 4G tourne) n est pas une faute de l ISO : on le dit, sans juger.
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
_chk "4G  osmo-lte.service + osmo-lte.desktop"             bash -c 'test -s /etc/systemd/system/osmo-lte.service && test -s /usr/share/applications/osmo-lte.desktop'
_chk "4G  mongod + mongosh + mongorestore (abonnes HSS)"   bash -c 'command -v mongod && command -v mongosh && command -v mongorestore'
_chk "4G  abonnes du depot (dump mongo + subscribers.json)" bash -c 'test -s /opt/GSM/osmo-operator/configs/open5gs/dump/open5gs/subscribers.bson && test -s /opt/GSM/osmo-operator/configs/open5gs/subscribers.json'
# Le telephone : pmbootstrap patche, le noyau PPP, le lanceur et son icone
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
        exit 1
    fi
    echo -e "  ${YELLOW}!${NC} $_ko maillon(s) manquant(s), ISO sortie quand meme (OSMO_ISO_LTE_REQUIRED=0)"
else
    echo -e "  ${GREEN}✓${NC} prete a l emploi : banc 2G, 4G et telephone au complet"
fi
unset _ko; unset -f _chk


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
