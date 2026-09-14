#!/bin/bash
# iso_modules/21-docker-build.sh - iso_docker_build, passe parente --all, nom de sortie
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── UN SEUL build docker ────────────────────────────────────────────────────
# L image source de TOUTES les ISO est osmocom-nitb (Dockerfile), construite
# par build.sh - qui la passe par docker compose et par le cache .deb. Plus de
# Dockerfile.run ni de Dockerfile.lite ici : les configs sont injectees depuis
# ce depot (etape 2b), l elagage lite se fait sur le rootfs (etape 8c).
# Seule exception : --role=interstp demande SEUL. Le hub n a besoin que
# d osmo-stp et de trois bibliotheques : Dockerfile.stp, et on ne va pas au
# bout de la pile.
# ── LES IMAGES CANDIDATES, DANS L ORDRE ─────────────────────────────────────
# [2026-09-14] L EMPREINTE EST CELLE DE LA CI : la meme commande que
# .github/workflows/docker.yml (job `base`) et build-iso.yml (« Empreinte du
# contexte »), aux redirections pres, qui ne changent pas le calcul. C est tout l interet - si elle donne la meme
# valeur ici que sur le runner, l image publiee sous ce nom a ete construite a
# partir EXACTEMENT de ce qui est dans l arbre de travail, et la recompiler ne
# produirait rien d autre. Toucher a cette liste de chemins sans la toucher
# dans les deux workflows fait diverger les empreintes, et plus rien ne se
# tire : les trois doivent bouger ensemble.
#
# L ordre :
#   1. la reference EXPLICITE de --skip-build=REF - elle ne se discute pas ;
#   2. ghcr.io/<depot>/osmocom-nitb:base-<empreinte> - celle qui correspond
#      au commit, publiee par docker.yml ;
#   3. l image Docker Hub, qui ne suit PAS le commit : dernier recours, et
#      iso_docker_build previent avant de s en servir.
iso_pull_refs() {
    if [ "${ISO_SKIP_BUILD_GIVEN:-0}" = "1" ]; then echo "$ISO_PULL_IMAGE"; return 0; fi
    local _key _repo
    # EN CONDITION DE `if`, et ce n est pas du style : build-iso.sh tourne sous
    # `set -euo pipefail`, et une affectation depuis une pipeline qui echoue
    # (hors depot git, git ls-files sort en 128) arreterait tout le script sans
    # un mot - exactement le piege qui a coute le build du 13-09 dans
    # 86-finitions.sh. En condition, set -e laisse passer et _key reste vide.
    # Le 2>/dev/null est SUR git, pas sur le `if` : dans une commande simple les
    # expansions precedent les redirections, une redirection posee au bout ne
    # couvre donc pas la substitution - « fatal: not a git repository » sortait
    # quand meme, au milieu du build.
    if ! _key="$(cd "$DIR" && git ls-files -- Dockerfile packaging configs scripts services \
                              helpers opt-gsm tools patches 2>/dev/null \
                 | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"; then
        _key=""
    fi
    # Le depot vient de origin ; hors clone git (une archive deployee a la
    # main), on retombe sur le depot amont plutot que de ne rien proposer.
    _repo="$(cd "$DIR" && git config --get remote.origin.url 2>/dev/null || true)"
    _repo="${_repo%.git}"; _repo="${_repo##*github.com[:/]}"
    # Un `owner/nom` et rien d autre : une origin qui n est pas sur github.com
    # ressort telle quelle du decoupage ci-dessus (ssh, gitlab, un chemin
    # local), et on n en ferait qu une reference GHCR imaginaire.
    case "$_repo" in *[:@\ ]*|*/*/*) _repo="" ;; */*) ;; *) _repo="" ;; esac
    [ -n "$_repo" ] || _repo="bbaranoff/osmo-operator"
    # L empreinte est vide hors depot git : pas de reference GHCR a proposer.
    [ -n "$_key" ] && echo "ghcr.io/${_repo,,}/osmocom-nitb:base-${_key}"
    echo "$ISO_PULL_IMAGE"
}

iso_docker_build() {
    local role="$1"
    if [ "${OSMO_ISO_IMAGE_READY:-0}" = "1" ]; then
        echo -e "${GREEN}[1/9] Image docker : deja construite par la passe parente${NC}"; return 0
    fi
    # ── TIRER PLUTOT QUE CONSTRUIRE ─────────────────────────────────────
    # L image tiree est taguee du nom que build.sh aurait produit (osmocom-nitb,
    # ou osmocom-nitb:arm64 en --arm) pour que 31-image-source et toute la
    # suite n y voient aucune difference ; OSMO_ISO_SRC_IMAGE empeche en plus
    # une image locale du meme nom de s inviter.
    #
    # DEUX GARDES avant meme d essayer, et elles ne valent que pour le DEFAUT :
    # un --skip-build ecrit a la main passe outre les deux.
    #   arm64    rien n est publie pour cette architecture ; un pull amd64 sur
    #            une cible arm64 donnerait un rootfs inutilisable.
    #   interstp le hub seul se construit en MINUTES depuis Dockerfile.stp
    #            (osmo-stp et trois bibliotheques). Lui faire tirer les ~11 Go
    #            de l image de base pour en extraire quatre binaires serait
    #            plus long que de la compiler.
    local _try_pull=0
    if [ "${ISO_SKIP_BUILD:-0}" = "1" ] && [ "${ISO_FORCE_BUILD:-0}" != "1" ]; then
        if [ "${ISO_SKIP_BUILD_GIVEN:-0}" = "1" ]; then _try_pull=1
        elif [ "${ISO_ARCH:-amd64}" = "amd64" ] && [ "$role" != "interstp" ]; then _try_pull=1
        fi
    fi
    if [ "$_try_pull" = "1" ]; then
        local _local="osmocom-nitb${ISO_IMG_TAG}" _ref _got=""
        echo -e "${GREEN}[1/9] Image docker : on TIRE avant de construire${NC}"
        for _ref in $(iso_pull_refs); do
            # DEJA LA ? On ne tire pas. Le registre n est pas toujours joignable
            # par celui qui execute : sur un runner, docker/login-action ecrit
            # les identifiants dans le ~/.docker du compte runner, et
            # build-iso.sh tourne sous sudo - un pull GHCR y repartirait sans
            # jeton. L image ayant ete tiree en amont, il n y a rien a chercher.
            if docker image inspect "$_ref" >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} ${CYAN}${_ref}${NC} deja presente localement"
                _got="$_ref"; break
            fi
            # manifest inspect AVANT le pull : il coute un aller-retour HTTP la
            # ou un pull rate peut passer des minutes a recommencer des couches.
            if docker manifest inspect "$_ref" >/dev/null 2>&1; then
                echo -e "  ${CYAN}pull${NC} ${_ref} (linux/${ISO_ARCH:-amd64})..."
                if docker pull --platform "linux/${ISO_ARCH:-amd64}" "$_ref"; then
                    _got="$_ref"; break
                fi
            fi
            echo -e "  ${YELLOW}!${NC} ${_ref} : indisponible"
        done
        if [ -n "$_got" ]; then
            # Le dernier recours ne suit pas le commit : on ne le laisse pas
            # passer en silence. Une ISO batie sur cette image peut porter une
            # pile differente de l arbre de travail - ce qui s explique cinq
            # minutes apres le build, et jamais trois semaines apres.
            # `if`, et pas « [ ... ] && [ ... ] && echo » : une chaine && dont
            # le premier test est faux rend 1, et ce depot s est deja fait
            # arreter par une ligne de cette forme sous set -e.
            if [ "$_got" = "$ISO_PULL_IMAGE" ] && [ "${ISO_SKIP_BUILD_GIVEN:-0}" != "1" ]; then
                echo -e "  ${YELLOW}!${NC} aucune image ne correspond a l'empreinte du depot : ${CYAN}${_got}${NC} ne suit pas ce commit (${CYAN}--build-docker${NC} pour compiler l'arbre de travail)"
            fi
            docker tag "$_got" "$_local"
            export OSMO_ISO_SRC_IMAGE="$_local"
            echo -e "  ${GREEN}✓${NC} image ${_local} prete ($(docker image inspect "$_local" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f Mo", $1/1048576}'))"
            return 0
        fi
        # Demande a la main, le pull etait la consigne : ne pas y arriver est
        # une erreur. Par defaut, ce n etait qu un raccourci - on compile.
        if [ "${ISO_SKIP_BUILD_GIVEN:-0}" = "1" ]; then
            echo -e "${RED}--skip-build : aucune image joignable (${ISO_PULL_IMAGE})${NC}" >&2; exit 1
        fi
        echo -e "  ${YELLOW}!${NC} aucune image publiee joignable - construction locale"
    fi
    if [ "$role" = "interstp" ]; then
        echo -e "${GREEN}[1/9] Hub seul : construction de ${CYAN}osmocom-stp${NC}${GREEN} (Dockerfile.stp)...${NC}"
        echo -e "  ${CYAN}osmo-stp + libosmocore + libosmo-netif + libosmo-sigtran. Rien d'autre.${NC}"
        if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
            # arm64 : buildx --platform, image taguee :arm64, cache .deb de l hote
            # dans le contexte comme le fait build.sh (osmo-deb y lit les paquets
            # de SON architecture, les amd64 qui y trainent ne le derangent pas).
            mkdir -p "$DIR/.deb-cache"; cp -f "${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"/osmo-build-*_arm64.deb "$DIR/.deb-cache/" 2>/dev/null || true
            docker buildx build --platform linux/arm64 --load $NO_CACHE \
                --build-arg "OSMO_DEB_REFRESH=$([ -n "$NO_CACHE" ] && echo 1 || echo 0)" \
                -f "$DIR/Dockerfile.stp" -t "osmocom-stp${ISO_IMG_TAG}" "$DIR" \
                || { echo -e "${RED}Echec de la construction d'osmocom-stp${ISO_IMG_TAG}${NC}"; exit 1; }
        elif docker compose version >/dev/null 2>&1; then
            ( cd "$DIR" && OSMO_DEB_REFRESH="$([ -n "$NO_CACHE" ] && echo 1 || echo 0)" \
              docker compose -f "$DIR/compose.yaml" build $NO_CACHE stp ) \
                || { echo -e "${RED}Echec de la construction d'osmocom-stp${NC}"; exit 1; }
        else
            docker build $NO_CACHE -f "$DIR/Dockerfile.stp" -t osmocom-stp "$DIR" \
                || { echo -e "${RED}Echec de la construction d'osmocom-stp${NC}"; exit 1; }
        fi
        echo -e "  ${GREEN}✓${NC} osmocom-stp${ISO_IMG_TAG} construite ($(docker image inspect "osmocom-stp${ISO_IMG_TAG}" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f Mo", $1/1048576}'))"
        return 0
    fi
    echo -e "${GREEN}[1/9] Execution de build.sh (image osmocom-nitb${ISO_IMG_TAG}, docker compose + cache .deb)...${NC}"
    if [ -f "$DIR/build.sh" ]; then
        # --arch=arm64 : build.sh passe par buildx --platform linux/arm64 et tague
        # l image osmocom-nitb:arm64. Le reste (apt-fast, docker, sctp, toast, le
        # cache .deb) est identique.
        bash "$DIR/build.sh" $NO_CACHE $([ "${ISO_ARCH:-amd64}" = "arm64" ] && echo "--arch=arm64")
    else
        echo -e "${YELLOW}build.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
        if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
            # --target : Dockerfile finit par l etape `debs` (cache .deb pour
            # la CI), pas par osmocom-nitb. Sans lui, image vide.
            docker buildx build --platform linux/arm64 --load $NO_CACHE \
                --target osmocom-nitb -t "osmocom-nitb${ISO_IMG_TAG}" "$DIR"
        else
            docker build $NO_CACHE --target osmocom-nitb -t osmocom-nitb "$DIR"
        fi
    fi
    echo -e "  ${GREEN}✓${NC} image osmocom-nitb${ISO_IMG_TAG} prete"
}

if [ "$ISO_ALL" = "1" ] || { [ "${ISO_ARCH:-amd64}" = "amd64" ] && [ "$ISO_ROLE_GIVEN" = "0" ] && [ "$OUTPUT_SET" = "0" ] \
   && [ -z "$ISO_NODE" ] && [ "$ISO_LITE" = "0" ] && [ "$ISO_DESKTOP" = "0" ]; }; then
    _N="QUATRE"   # [2026-08-29] --all par defaut : les QUATRE images, desktop incluse
    echo -e "${CYAN}${BOLD}══ Construction des ${_N} images ══${NC}"
    echo -e "  1. ${CYAN}interstp.iso${NC}               le hub SS7 (PC 0.0.0)"
    echo -e "  2. ${CYAN}osmo-operator.iso${NC}          un noeud - son numero se choisit au demarrage :"
    echo -e "     ${CYAN}./start-direct.sh --node N${NC}   (N de 1 a 9)"
    echo -e "  3. ${CYAN}osmo-operator-lite.iso${NC}     le meme noeud, sans les ateliers de compilation"
    echo -e "  4. ${CYAN}osmo-operator-desktop.iso${NC}  le meme noeud, avec GNOME, wireshark et linphone"
    echo ""

    # --all et --desktop RETIRES des arguments repasses aux passes filles.
    # Les laisser ferait rentrer chaque passe dans ce meme bloc : une recursion
    # sans fond, qui ne produirait jamais la moindre ISO.
    SUB_ARGS=()
    for _a in "$@"; do
        case "$_a" in --all|--desktop) ;; *) SUB_ARGS+=("$_a") ;; esac
    done
    set -- "${SUB_ARGS[@]+"${SUB_ARGS[@]}"}"

    # ── [2026-09-03] UNE SEULE FOIS : apt sur l hote, build docker ───────────
    iso_host_packages
    iso_docker_build operator
    export OSMO_ISO_HOST_READY=1 OSMO_ISO_IMAGE_READY=1 OSMO_ISO_ALL_RUN=1

    # ── L ORDRE : interstp, normal, lite, desktop - et le rootfs se transmet ──
    # Le hub d abord : petit, independant, un echec se voit en minutes. Puis la
    # NORMALE, construite de zero (debootstrap + apt + injection) : c est elle
    # qui coute. Les deux autres REPRENNENT SON ROOTFS au lieu de le refaire :
    #   lite     = une COPIE de la normale, dont on RETIRE les ateliers (elle
    #              enleve, elle vient donc apres la normale, jamais avant) ;
    #   desktop  = la normale elle-meme (deplacee), a laquelle on AJOUTE la
    #              difference apt : le bureau, l installeur, les snaps.
    # apt est idempotent : sur un rootfs herite, la liste commune coute quelques
    # secondes de resolution, seul le delta est telecharge.
    _KEEP="$WORK"; mkdir -p "$_KEEP"
    _all_fail() { echo -e "${RED}Echec de $1${NC}" >&2; rm -rf "$_KEEP"; exit 1; }
    "$0" --role=interstp "$@" || _all_fail interstp.iso
    OSMO_ISO_ROOTFS_KEEP="$_KEEP/rootfs-normal" \
        "$0" --role=operator --output=osmo-operator.iso "$@" || _all_fail osmo-operator.iso
    [ -d "$_KEEP/rootfs-normal" ] || _all_fail "osmo-operator.iso (rootfs non transmis)"
    OSMO_ISO_ROOTFS_FROM="$_KEEP/rootfs-normal" OSMO_ISO_ROOTFS_MODE=copy \
        "$0" --role=operator --lite --output=osmo-operator-lite.iso "$@" || _all_fail osmo-operator-lite.iso
    _ISOS=("$(pwd)/interstp.iso" "$(pwd)/osmo-operator.iso" "$(pwd)/osmo-operator-lite.iso")
    OSMO_ISO_ROOTFS_FROM="$_KEEP/rootfs-normal" OSMO_ISO_ROOTFS_MODE=move \
        "$0" --role=operator --desktop --output=osmo-operator-desktop.iso "$@" || _all_fail osmo-operator-desktop.iso
    _ISOS+=("$(pwd)/osmo-operator-desktop.iso")
    rm -rf "$_KEEP"
    echo -e "${GREEN}${BOLD}═══ Les ${_N} images sont pretes ═══${NC}"
    ls -lh "${_ISOS[@]}" 2>/dev/null | sed 's/^/  /'
    exit 0
fi

case "${ISO_ROLE:-operator}" in
    interstp)
        ISO_ROLE="interstp"
        [ "$OUTPUT_SET" = "1" ] || OUTPUT="interstp.iso"
        # Le hub n'a pas d'atelier a elaguer : son image (Dockerfile.stp) ne
        # porte que osmo-stp et quatre bibliotheques. --lite n'y veut rien dire,
        # et l'accepter en silence produirait une "lite" identique a l'autre.
        [ "$ISO_LITE" = "1" ] && { echo "--lite ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # Meme raison pour le bureau : le hub tourne sans ecran, en salle
        # machine ou en VM sans console graphique. Un GNOME dessus, c'est 2,5 Go
        # et une pile X de plus sur la seule image qui n'affiche jamais rien.
        [ "$ISO_DESKTOP" = "1" ] && { echo "--desktop ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # Le hub dessert N noeuds : sans table WAN on ne sait pas combien.
        ISO_WAN=1 ;;
    operator|"")
        ISO_ROLE="operator"
        if [ -n "$ISO_NODE" ]; then
            [[ "$ISO_NODE" =~ ^[1-9]$ ]] || { echo "--node : 1 a 9" >&2; exit 2; }
            if [ "$OUTPUT_SET" = "0" ]; then
                _sfx=""
                [ "$ISO_LITE" = "1" ]    && _sfx="${_sfx}-lite"
                [ "$ISO_DESKTOP" = "1" ] && _sfx="${_sfx}-desktop"
                OUTPUT="osmo-operator-${ISO_NODE}${_sfx}.iso"
            fi
            ISO_WAN_ID="${ISO_WAN_ID:-$ISO_NODE}"
            ISO_WAN=1
        elif [ "$ISO_LITE" = "1" ] || [ "$ISO_DESKTOP" = "1" ]; then
            if [ "$OUTPUT_SET" = "0" ]; then
                _sfx=""
                [ "$ISO_LITE" = "1" ]    && _sfx="${_sfx}-lite"
                [ "$ISO_DESKTOP" = "1" ] && _sfx="${_sfx}-desktop"
                OUTPUT="osmo-operator${_sfx}.iso"
            fi
        fi ;;
    *) echo "--role inconnu : $ISO_ROLE (operator|interstp)" >&2; exit 2 ;;
esac
# --arm : une image SD, pas une ISO. Le nom suit la meme regle (role, noeud,
# -lite), avec -rpi4.img a la place de .iso - sauf --output=, respecte tel quel.
if [ "${ISO_ARCH:-amd64}" = "arm64" ] && [ "$OUTPUT_SET" != "1" ]; then
    OUTPUT="${OUTPUT%.iso}-rpi4.img"
fi
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
