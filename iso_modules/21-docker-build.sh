#!/bin/bash
# iso_modules/21-docker-build.sh - iso_docker_build, --all parent pass, output file name
# Sourced by build-iso.sh in numeric order (same shell, variables and
# functions); not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (that is how --arm skips a step).

# ── ONE docker build ───────────────────────────────────────────────────────
# The source image of ALL ISOs is osmocom-nitb (Dockerfile), built by build.sh
# (docker compose + .deb cache). Configs are injected from this repository
# (step 2b); lite pruning is done on the rootfs (step 8c).
# Only exception: --role=interstp requested ALONE. The hub only needs osmo-stp
# and three libraries: Dockerfile.stp, without building the full stack.
# ── CANDIDATE IMAGES, IN ORDER ─────────────────────────────────────────────
# The fingerprint is computed exactly like the CI: same command as
# .github/workflows/docker.yml (job `base`) and build-iso.yml (context
# fingerprint step). If it matches, the image published under that name was
# built from EXACTLY the working tree. The path list must be changed in all
# three places together, otherwise fingerprints diverge and nothing is pulled.
#
# Order:
#   1. the EXPLICIT --skip-build=REF reference, used alone;
#   1b. the Docker Hub image ($ISO_PULL_IMAGE, bastienbaranoff/norf_gsm:latest),
#      tagged osmocom-nitb like the others;
#   2. ghcr.io/<repo>/osmocom-nitb:base-<fingerprint> - matches the commit,
#      published by docker.yml;
#   3. ghcr.io/<repo>/osmocom-nitb:latest - latest image published by the same
#      workflow (public registry, no token needed); does not track the commit.
# Only 2 guarantees that the image matches the working tree; for 3,
# iso_docker_build warns before using it.
iso_pull_refs() {
    if [ "${ISO_SKIP_BUILD_GIVEN:-0}" = "1" ]; then echo "$ISO_PULL_IMAGE"; return 0; fi
    local _key _repo
    # Must be an `if` condition: build-iso.sh runs under `set -euo pipefail`,
    # and an assignment from a failing pipeline (outside a git repo, git ls-files
    # exits 128) would silently stop the script. As a condition, set -e lets it
    # through and _key stays empty.
    # The 2>/dev/null is ON git, not on the `if`: in a simple command expansions
    # happen before redirections, so a trailing redirection would not cover the
    # command substitution.
    if ! _key="$(cd "$DIR" && git ls-files -- Dockerfile packaging configs scripts services \
                              helpers opt-gsm tools patches 2>/dev/null \
                 | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"; then
        _key=""
    fi
    # Repository from origin; outside a git clone (hand-deployed archive), fall
    # back to the upstream repository.
    _repo="$(cd "$DIR" && git config --get remote.origin.url 2>/dev/null || true)"
    _repo="${_repo%.git}"; _repo="${_repo##*github.com[:/]}"
    # Accept only `owner/name`: an origin not on github.com (ssh, gitlab, local
    # path) comes out of the split above unchanged and would give a bogus GHCR
    # reference.
    case "$_repo" in *[:@\ ]*|*/*/*) _repo="" ;; */*) ;; *) _repo="" ;; esac
    [ -n "$_repo" ] || _repo="bbaranoff/osmo-operator"
    # The fingerprint is empty outside a git repo: no fingerprint reference, but
    # the same repository's latest is still valid.
    # Docker Hub FIRST: bastienbaranoff/norf_gsm:latest is the bench's reference
    # stack; GHCR is the fallback.
    echo "$ISO_PULL_IMAGE"
    [ -n "$_key" ] && echo "ghcr.io/${_repo,,}/osmocom-nitb:base-${_key}"
    echo "ghcr.io/${_repo,,}/osmocom-nitb:latest"
}

iso_docker_build() {
    local role="$1"
    if [ "${OSMO_ISO_IMAGE_READY:-0}" = "1" ]; then
        echo -e "${GREEN}[1/9] Image docker : deja construite par la passe parente${NC}"; return 0
    fi
    # ── PULL RATHER THAN BUILD ─────────────────────────────────────────────
    # The pulled image is tagged with the name build.sh would produce
    # (osmocom-nitb, or osmocom-nitb:arm64 with --arm) so 31-image-source and the
    # rest see no difference; OSMO_ISO_SRC_IMAGE also prevents a local image of
    # the same name from being used.
    #
    # TWO GUARDS, applying only to the DEFAULT (an explicit --skip-build
    # overrides both):
    #   arm64    nothing is published for this architecture; an amd64 pull on an
    #            arm64 target would give an unusable rootfs.
    #   interstp the hub alone builds in MINUTES from Dockerfile.stp (osmo-stp and
    #            three libraries), faster than pulling the ~11 GB base image.
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
            # ALREADY PRESENT? Do not pull. The registry may not be reachable for the
            # current user: on a runner, docker/login-action writes credentials to the
            # runner account's ~/.docker while build-iso.sh runs under sudo, so a GHCR
            # pull would have no token. The image was pulled upstream.
            if docker image inspect "$_ref" >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} ${CYAN}${_ref}${NC} deja presente localement"
                _got="$_ref"; break
            fi
            # manifest inspect BEFORE pulling: one HTTP round trip, whereas a failing
            # pull can spend minutes retrying layers.
            if docker manifest inspect "$_ref" >/dev/null 2>&1; then
                echo -e "  ${CYAN}pull${NC} ${_ref} (linux/${ISO_ARCH:-amd64})..."
                if docker pull --platform "linux/${ISO_ARCH:-amd64}" "$_ref"; then
                    _got="$_ref"; break
                fi
            fi
            echo -e "  ${YELLOW}!${NC} ${_ref} : indisponible"
        done
        if [ -n "$_got" ]; then
            # Anything that is not a fingerprint image does not track the commit: warn
            # (an ISO built on it may carry a stack different from the working tree).
            # The `:base-` pattern identifies the only images that match.
            # Use `if`, not "[ ... ] && [ ... ] && echo": a && chain whose first test is
            # false returns 1, which stops the script under set -e.
            # Except the Docker Hub image: it is first BY CHOICE, so no warning.
            if [ "${_got}" = "${_got#*:base-}" ] && [ "${_got}" != "${ISO_PULL_IMAGE}" ] \
               && [ "${ISO_SKIP_BUILD_GIVEN:-0}" != "1" ]; then
                echo -e "  ${YELLOW}!${NC} aucune image ne correspond a l'empreinte du depot : ${CYAN}${_got}${NC} ne suit pas ce commit (${CYAN}--build-docker${NC} pour compiler l'arbre de travail)"
            fi
            docker tag "$_got" "$_local"
            export OSMO_ISO_SRC_IMAGE="$_local"
            echo -e "  ${GREEN}✓${NC} image ${_local} prete ($(docker image inspect "$_local" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f Mo", $1/1048576}'))"
            return 0
        fi
        # Explicitly requested pull: failure is an error. Default: it was only a
        # shortcut, so build.
        if [ "${ISO_SKIP_BUILD_GIVEN:-0}" = "1" ]; then
            echo -e "${RED}--skip-build : aucune image joignable (${ISO_PULL_IMAGE})${NC}" >&2; exit 1
        fi
        echo -e "  ${YELLOW}!${NC} aucune image publiee joignable - construction locale"
    fi
    if [ "$role" = "interstp" ]; then
        echo -e "${GREEN}[1/9] Hub seul : construction de ${CYAN}osmocom-stp${NC}${GREEN} (Dockerfile.stp)...${NC}"
        echo -e "  ${CYAN}osmo-stp + libosmocore + libosmo-netif + libosmo-sigtran. Rien d'autre.${NC}"
        if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
            # arm64: buildx --platform, image tagged :arm64, host .deb cache copied into
            # the context as build.sh does (osmo-deb reads packages of ITS architecture;
            # stray amd64 ones do not matter).
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
        # --arch=arm64: build.sh uses buildx --platform linux/arm64 and tags the
        # image osmocom-nitb:arm64. Everything else (apt-fast, docker, sctp, toast,
        # .deb cache) is identical.
        bash "$DIR/build.sh" $NO_CACHE $([ "${ISO_ARCH:-amd64}" = "arm64" ] && echo "--arch=arm64")
    else
        echo -e "${YELLOW}build.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
        if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
            # --target: the Dockerfile ends with the `debs` stage (.deb cache for CI),
            # not osmocom-nitb. Without it the image would be empty.
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
    _N="QUATRE"  # --all by default: all FOUR images, desktop included
    echo -e "${CYAN}${BOLD}══ Construction des ${_N} images ══${NC}"
    echo -e "  1. ${CYAN}interstp.iso${NC}               le hub SS7 (PC 0.0.0)"
    echo -e "  2. ${CYAN}osmo-operator.iso${NC}          un noeud - son numero se choisit au demarrage :"
    echo -e "     ${CYAN}./start-native.sh --node N${NC}   (N de 1 a 9)"
    echo -e "  3. ${CYAN}osmo-operator-lite.iso${NC}     le meme noeud, sans les ateliers de compilation"
    echo -e "  4. ${CYAN}osmo-operator-desktop.iso${NC}  le meme noeud, avec GNOME, wireshark et linphone"
    echo ""

    # --all and --desktop are REMOVED from the arguments passed to child passes;
    # otherwise each pass would enter this same block (endless recursion).
    SUB_ARGS=()
    for _a in "$@"; do
        case "$_a" in --all|--desktop) ;; *) SUB_ARGS+=("$_a") ;; esac
    done
    set -- "${SUB_ARGS[@]+"${SUB_ARGS[@]}"}"

    # ── ONCE ONLY: host apt, docker build ─────────────────────────────────────
    iso_host_packages
    iso_docker_build operator
    export OSMO_ISO_HOST_READY=1 OSMO_ISO_IMAGE_READY=1 OSMO_ISO_ALL_RUN=1

    # ── ORDER: interstp, normal, lite, desktop - the rootfs is handed over ────
    # Hub first: small, independent, a failure shows in minutes. Then the NORMAL
    # image, built from scratch (debootstrap + apt + injection): the expensive
    # one. The other two REUSE ITS ROOTFS:
    #   lite     = a COPY of the normal rootfs with the build trees REMOVED (so it
    #              must come after the normal image);
    #   desktop  = the normal rootfs itself (moved), with the apt delta ADDED:
    #              desktop, installer, snaps.
    # apt is idempotent: on an inherited rootfs the common list costs a few
    # seconds of resolution, only the delta is downloaded.
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
        # The hub has no build trees to prune: its image (Dockerfile.stp) only has
        # osmo-stp and four libraries. --lite is meaningless here and is rejected.
        [ "$ISO_LITE" = "1" ] && { echo "--lite ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # Same for the desktop: the hub runs headless (server room or VM without a
        # graphical console).
        [ "$ISO_DESKTOP" = "1" ] && { echo "--desktop ne s'applique pas au hub (--role=interstp)" >&2; exit 2; }
        # The hub serves N nodes: it needs the WAN table to know how many.
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
# --arm: an SD image, not an ISO. Same naming rule (role, node, -lite), with
# -rpi4.img instead of .iso - except --output=, used as is.
if [ "${ISO_ARCH:-amd64}" = "arm64" ] && [ "$OUTPUT_SET" != "1" ]; then
    OUTPUT="${OUTPUT%.iso}-rpi4.img"
fi
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
