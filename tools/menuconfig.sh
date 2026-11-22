#!/bin/bash
# tools/menuconfig.sh - du .config (Kconfig) a la commande de build
# =============================================================================
#
#   make menuconfig | ./build.sh --menuconfig     le menu (Kconfig, kconfiglib)
#   make build      | ./build.sh --config         build depuis .config, sans menu
#   tools/menuconfig.sh --print   [--file=F]      la commande que .config donne
#   tools/menuconfig.sh --defconfig [--file=F]    = make defconfig
#   make tree           | tools/menuconfig.sh --tree   arbres de dependances
#
# Le menu lui-meme est le Kconfig du depot (Kconfig, kconfig/*) lu par
# kconfiglib (tools/kconfig/) : depends on, select, imply, choice, range,
# aide de chaque option avec ses dependances. Ce script ne fait que lire le
# .config qu'il ecrit et appeler le script de build.
#
# Le menu : l'ARCHITECTURE, puis la CIBLE (selon l'architecture), puis les
# MODULES (selon la cible) :
#   iso       build-iso.sh   ISO live amd64 ou images SD arm64
#   docker    build.sh       images osmocom-nitb / lite / stp / run (BuildKit bake)
#   native    sur l'hote     install.sh (install_modules/), make c54x_exe,
#                            make debs / release
# puis leurs modules. Le .config est au format du noyau (CONFIG_X=y,
# "# CONFIG_X is not set", CONFIG_S="texte") ; on appelle le script de build
# avec ses options ordinaires.
#
# Chemins : relatifs au depot par defaut (../c54x_exe, .cache/freecalypso, .),
# tous reglables dans le sous-menu Chemins. Un chemin relatif s'entend depuis
# la racine du depot ; il est rendu absolu au moment de l'appel.
# =============================================================================
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
REPO="$(pwd)"
CONFIG_FILE=".config"
MODE=menu
for a in "$@"; do
    case "$a" in
        --build)       MODE=build ;;
        --print)       MODE=print ;;
        --defconfig)   MODE=defconfig ;;
        --tree)        MODE=tree ;;
        --file=*)      CONFIG_FILE="${a#*=}" ;;
        -h|--help)     sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "menuconfig : option inconnue $a" >&2; exit 2 ;;
    esac
done

. "$REPO/tools/features.sh"; feat_load
BENCH_DEBS=(osmo-operator pont qemu-calypso calypso-firmware)
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
# The --fast packages (build.sh FAST_DEBS), short names.
FAST_DEB_LIST=(qosmo grgsm-exe grgsm-venv calypso-firmware c54x-exe-norom)
declare -A FAST_DEB_DESC=(
    [qosmo]="QEMU Calypso (qosmo)"
    [grgsm-exe]="grgsm_exe"
    [grgsm-venv]="GNU Radio + gr-gsm (/root/.env)"
    [calypso-firmware]="firmwares Calypso (osmocom-bb)"
    [c54x-exe-norom]="c54x_exe sans ROM (ROM prise a FreeCalypso)"
)

# ── La configuration ─────────────────────────────────────────────────────────
declare -A C
cfg_defaults() {
    C=(
        [TARGET]=docker
        [ARCH]="$HOST_ARCH"
        [NO_CACHE]=n
        # groupes de l'image docker et modules de l'ISO : "all" ou la liste cochee
        [FEATURES]=all
        [ISO_MODULES]=all
        # debs
        [DEBS_ONLY]="${BENCH_DEBS[*]}"
        [DEBS_IMAGE]=n
        [DEBS_RELEASE]=n
        [DEBS_RELEASE_TAG]=""
        # docker
        [DOCKER_FAST]=n
        [DOCKER_FAST_DEBS]="${FAST_DEB_LIST[*]}"
        [DOCKER_LITE]=n
        [DOCKER_STP]=n
        [DOCKER_RUN_ONLY]=n
        # iso
        [ISO_IMAGE]=all
        [ISO_NODE]=""
        [ISO_UBUNTU]=24.04
        [ISO_KB]=fr
        [ISO_BANC]=n
        [ISO_MULTI]=n
        [ISO_SOFTSIM]=y
        [ISO_WITH_DEBS]=y
        [ISO_SOURCE]=pull
        [ISO_PULL_IMAGE]=""
        [ISO_WAN]=n
        [ISO_WAN_NODES]=""
        [ISO_WAN_ID]=""
        [ISO_WAN_OPS]=1
        [ISO_HUB_IP]=172.20.0.10
        [ISO_BOARD]=all
        [ISO_OUTPUT]=""
        # c54x_exe
        [C54X_ROM]=y
        [C54X_NATIVE]=n
        [C54X_EXTRA]=""
        # avance
        [BACKEND]=bake
        [PROGRESS]=auto
        [UBUNTU_MIRROR]=""
        # chemins (relatifs : depuis la racine du depot)
        [DEB_CACHE]=/var/cache/osmo-debs
        [FREECALYPSO_CACHE]=.cache/freecalypso
        [ISO_WORK]=/var/tmp
        [OUTPUT_DIR]=.
        [C54X_DIR]=../c54x_exe
        [QOSMO_DIR]=../qosmo
        [FIRMWARE_DIR]=../firmware
        [ROM_DIR]=..
        [DEBS_OUT]=packaging/dist
    )
}

is_bool() { case "${C[$1]}" in y|n) return 0 ;; esac; return 1; }

# Parsed, never sourced: a .config is data. Kconfig writes the choices as
# hidden strings (CONFIG_TARGET="iso"...) and the lists as one bool per item:
#   FEAT_<ID>  ISO_MOD_<ID>  FAST_DEB_<X>  DEBS_PKG_<X>  C54X_TOOL_<X>
# A symbol absent from the file (unmet dependency) is "n".
declare -A K
cfg_load() {
    local f="$1" line k v
    [ -f "$f" ] || return 1
    K=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
            k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
            [[ "$v" =~ ^\"(.*)\"$ ]] && { v="${BASH_REMATCH[1]}"; v="${v//\\\"/\"}"; v="${v//\\\\/\\}"; }
            K[$k]="$v"
        elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            K[${BASH_REMATCH[1]}]=n
        fi
    done <"$f"
    # Old format (whiptail menu, CONFIG_FEATURES="all"...): make olddefconfig.
    [ -n "${K[FEATURES]+x}" ] && [ -z "${K[TARGET_DOCKER]+x}${K[TARGET_ISO]+x}" ] && \
        echo "menuconfig : $f est de l'ancien format : make olddefconfig (ou make menuconfig) le convertit" >&2
    for k in "${!C[@]}"; do
        if [ -n "${K[$k]+x}" ]; then C[$k]="${K[$k]}"
        elif is_bool "$k"; then C[$k]=n
        fi
    done
    kbool() { [ "${K[$1]:-n}" = y ]; }
    local i u out=()
    for i in $(feat_ids docker); do u="${i^^}"; kbool "FEAT_${u//-/_}" && out+=("$i"); done
    sel_put FEATURES "${out[*]}"
    out=(); for i in $(feat_ids iso); do u="${i^^}"; kbool "ISO_MOD_${u//-/_}" && out+=("$i"); done
    sel_put ISO_MODULES "${out[*]}"
    out=(); for i in "${FAST_DEB_LIST[@]}"; do u="${i^^}"; kbool "FAST_DEB_${u//-/_}" && out+=("$i"); done
    C[DOCKER_FAST_DEBS]="${out[*]}"
    out=(); for i in "${BENCH_DEBS[@]}"; do u="${i^^}"; kbool "DEBS_PKG_${u//-/_}" && out+=("$i"); done
    C[DEBS_ONLY]="${out[*]}"
    out=(); for i in isa_test dsp_tester layer1_tester; do kbool "C54X_TOOL_${i^^}" && out+=("$i"); done
    C[C54X_EXTRA]="${out[*]}"
    # int 0 = "absent" (Kconfig has no empty int)
    [ "${C[ISO_NODE]}" = 0 ] && C[ISO_NODE]=""
    [ "${C[ISO_WAN_ID]}" = 0 ] && C[ISO_WAN_ID]=""
    [ "${C[DEBS_RELEASE_TAG]}" = debs-banc ] && C[DEBS_RELEASE_TAG]=""
    return 0
}

# ── Selections (groupes docker, modules iso) ──────────────────────────────
# Stored as "all" or the list of selected ids; the menu works on the expanded
# list and folds it back to "all" when everything of that kind is selected.
sel_get() {   # $1 = FEATURES|ISO_MODULES -> expanded list
    local kind=docker; [ "$1" = ISO_MODULES ] && kind=iso
    [ "${C[$1]}" = all ] && feat_ids "$kind" | xargs || echo "${C[$1]}"
}
sel_put() {   # $1 = key, $2 = list (may contain other kinds: filtered)
    local kind=docker; [ "$1" = ISO_MODULES ] && kind=iso
    local i out=() n=0 t=0
    for i in $(feat_ids "$kind"); do t=$((t+1)); feat_has "$2" "$i" && { out+=("$i"); n=$((n+1)); }; done
    [ "$n" = "$t" ] && C[$1]=all || C[$1]="${out[*]}"
}
# Both kinds together (cross dependencies: lte-pmos needs the docker group lte).
sel_all() { echo "$(sel_get FEATURES) $(sel_get ISO_MODULES) $(feat_ids core | xargs)"; }
sel_toggle() {  # $1 = id : on -> off (+ dependents), off -> on (+ dependencies)
    local cur; cur="$(sel_all)"
    if feat_has "$cur" "$1"; then cur="$(feat_off "$cur" "$1")"; else cur="$(feat_on "$cur" "$1")"; fi
    sel_put FEATURES "$cur"; sel_put ISO_MODULES "$cur"
}
# Docker groups left out -> build.sh --without=a,b
feat_without() { local g out=(); for g in $(feat_ids docker); do feat_has "$(sel_get FEATURES)" "$g" || out+=("$g"); done; local IFS=,; echo "${out[*]}"; }

# A relative path is relative to the repository root.
abspath() { case "$1" in /*) realpath -m "$1" ;; *) realpath -m "$REPO/$1" ;; esac; }

# ── Validation (les "depends on" du Kconfig) ─────────────────────────────────
cfg_check() {
    local e=()
    if [ "${C[TARGET]}" = docker ]; then
        [ "${C[DOCKER_FAST]}" = y ] && [ "${C[ARCH]}" != amd64 ] \
            && e+=("--fast : amd64 seulement (les .deb de la release sont amd64)")
        [ "${C[DOCKER_FAST]}" = y ] && [ -z "${C[DOCKER_FAST_DEBS]}" ] \
            && e+=("--fast sans aucun .deb coche : decocher --fast ou cocher au moins un paquet")
    fi
    if [ "${C[TARGET]}" = iso ] && [ "${C[ARCH]}" = arm64 ]; then
        case "${C[ISO_IMAGE]}" in all|lite|interstp) e+=("arm64 : image operator ou desktop seulement (pas ${C[ISO_IMAGE]})") ;; esac
        [ "${C[ISO_UBUNTU]}" = 24.04 ] || e+=("arm64 : Ubuntu 24.04 seulement")
    fi
    if [ "${C[TARGET]}" = iso ] && [ "${C[ISO_SOURCE]}" = pull-strict ] && [ -z "${C[ISO_PULL_IMAGE]}" ] && [ "${C[ARCH]}" = arm64 ]; then
        e+=("arm64 + pull obligatoire : indiquer l'image a tirer (rien n'est publie par defaut)")
    fi
    [ "${C[TARGET]}" = native ] && [ "${K[NATIVE_INSTALL]:-n}${K[NATIVE_C54X]:-n}${K[NATIVE_DEBS]:-n}" = nnn ] \
        && e+=("natif : rien de coche (installation, c54x_exe ou .deb)")
    [ "${K[NATIVE_DEBS]:-n}" = y ] && [ -z "${C[DEBS_ONLY]}" ] && [ "${C[DEBS_IMAGE]}" != y ] \
        && e+=("debs : aucun paquet coche")
    [ "${K[NATIVE_DEBS]:-n}" = y ] && [ "${C[DEBS_RELEASE]}" = y ] && ! command -v gh >/dev/null 2>&1 \
        && e+=("release : gh (GitHub CLI) absent")
    [ "${#e[@]}" -eq 0 ] && return 0
    printf '%s\n' "${e[@]}"
    return 1
}

# ── Config -> commande ───────────────────────────────────────────────────────
# CMD_ENV: VAR=valeur passees par env ; CMD: la commande ; CMD_DIR: son cwd.
cfg_command() {
    CMD_ENV=(); CMD=(); CMD_DIR="$REPO"
    case "${C[TARGET]}" in
    docker)
        CMD=(./build.sh)
        if [ "${C[DOCKER_RUN_ONLY]}" = y ]; then
            CMD+=(--build-run)
        else
            CMD+=("--arch=${C[ARCH]}")
            [ "${C[DOCKER_FAST]}" = y ] && CMD+=(--fast)
            [ "${C[DOCKER_LITE]}" = y ] && CMD+=(--lite)
            [ "${C[DOCKER_STP]}" = y ]  && CMD+=(--stp)
            [ -n "$(feat_without)" ] && CMD+=("--without=$(feat_without)")
        fi
        [ "${C[NO_CACHE]}" = y ] && CMD+=(--no-cache)
        CMD_ENV+=("OSMO_BUILD_BACKEND=${C[BACKEND]}" "BUILDKIT_PROGRESS=${C[PROGRESS]}"
                  "OSMO_DEB_CACHE=$(abspath "${C[DEB_CACHE]}")"
                  "FREECALYPSO_CACHE=$(abspath "${C[FREECALYPSO_CACHE]}")")
        if [ "${C[DOCKER_FAST]}" = y ]; then
            local all=1 d
            for d in "${FAST_DEB_LIST[@]}"; do [[ " ${C[DOCKER_FAST_DEBS]} " == *" $d "* ]] || all=0; done
            [ "$all" = 1 ] && CMD_ENV+=("OSMO_FAST_DEBS=all") || CMD_ENV+=("OSMO_FAST_DEBS=${C[DOCKER_FAST_DEBS]}")
        fi
        [ -n "${C[UBUNTU_MIRROR]}" ] && CMD_ENV+=("OSMO_UBUNTU_MIRROR=${C[UBUNTU_MIRROR]}")
        ;;
    iso)
        CMD=("$REPO/build-iso.sh")
        CMD_DIR="$(abspath "${C[OUTPUT_DIR]}")"
        [ "${C[ARCH]}" = arm64 ] && CMD+=(--arm "--board=${C[ISO_BOARD]}")
        case "${C[ISO_IMAGE]}" in
            all)      CMD+=(--all) ;;
            operator) CMD+=(--role=operator) ;;
            lite)     CMD+=(--role=operator --lite) ;;
            desktop)  CMD+=(--role=operator --desktop) ;;
            interstp) CMD+=(--role=interstp) ;;
        esac
        case "${C[ISO_IMAGE]}" in operator|lite|desktop)
            [ -n "${C[ISO_NODE]}" ] && CMD+=("--node=${C[ISO_NODE]}") ;;
        esac
        [ "${C[ISO_IMAGE]}" != all ] && [ -n "${C[ISO_OUTPUT]}" ] && CMD+=("--output=${C[ISO_OUTPUT]}")
        CMD+=("--version=${C[ISO_UBUNTU]}" "--kb=${C[ISO_KB]}")
        [ "${C[ISO_BANC]}" = y ]    && CMD+=(--banc)    || CMD+=(--no-banc)
        [ "${C[ISO_MULTI]}" = y ]   && CMD+=(--multi)   || CMD+=(--no-multi)
        [ "${C[ISO_SOFTSIM]}" = y ] && CMD+=(--softsim) || CMD+=(--no-softsim)
        [ "${C[ISO_WITH_DEBS]}" = y ] && CMD+=(--with-debs) || CMD+=(--without-debs)
        case "${C[ISO_SOURCE]}" in
            build)       CMD+=(--build-docker) ;;
            pull-strict) if [ -n "${C[ISO_PULL_IMAGE]}" ]; then CMD+=("--skip-build=${C[ISO_PULL_IMAGE]}"); else CMD+=(--skip-build); fi ;;
        esac
        if [ "${C[ISO_WAN]}" = y ]; then
            CMD+=(--wan "--wan-ops=${C[ISO_WAN_OPS]}" "--hub-ip=${C[ISO_HUB_IP]}")
            [ -n "${C[ISO_WAN_NODES]}" ] && CMD+=("--wan-nodes=${C[ISO_WAN_NODES]}")
            [ -n "${C[ISO_WAN_ID]}" ]    && CMD+=("--wan-id=${C[ISO_WAN_ID]}")
        fi
        [ -n "$(feat_without)" ] && CMD+=("--without=$(feat_without)")
        [ "${C[ISO_MODULES]}" != all ] && CMD+=("--modules=$(echo ${C[ISO_MODULES]} | tr ' ' ,)")
        [ "${C[NO_CACHE]}" = y ] && CMD+=(--no-cache)
        CMD_ENV+=("OSMO_ISO_WORK=$(abspath "${C[ISO_WORK]}")"
                  "OSMO_DEB_CACHE=$(abspath "${C[DEB_CACHE]}")"
                  "FREECALYPSO_CACHE=$(abspath "${C[FREECALYPSO_CACHE]}")"
                  "OSMO_BUILD_BACKEND=${C[BACKEND]}" "BUILDKIT_PROGRESS=${C[PROGRESS]}"
                  "OSMO_APT_RELEASE=${C[DEBS_RELEASE_TAG]:-debs-banc}"
                  # The .config goes into the image (/etc/osmocom/build.config):
                  # start.sh --configure offers what was built, like /proc/config.gz.
                  "OSMO_BUILD_CONFIG=$(abspath "$CONFIG_FILE")")
        [ -n "${C[UBUNTU_MIRROR]}" ] && CMD_ENV+=("OSMO_UBUNTU_MIRROR=${C[UBUNTU_MIRROR]}")
        ;;
    native)
        # Several steps, in order, each one only if checked: install.sh
        # (modules left out -> --skip), c54x_exe, the .debs. One shell runs
        # them so that the first failure stops the chain.
        local steps=() q x
        if [ "${K[NATIVE_INSTALL]:-n}" = y ]; then
            local skip=() m u
            for m in $(ls "$REPO"/install_modules/[0-9][0-9]-*.sh 2>/dev/null); do
                m="$(sed -n 's/^INST_REGISTER \([^ ]*\) .*/\1/p' "$m" | head -1)"
                [ -n "$m" ] && [ "$m" != prereqs ] || continue
                u="${m^^}"; u="${u//-/_}"
                [ "${K[NATIVE_MOD_$u]:-n}" = y ] || skip+=("$m")
            done
            q="$(printf %q "$REPO/install.sh")"
            [ "${#skip[@]}" -gt 0 ] && q+=" --skip $(IFS=,; echo "${skip[*]}")"
            [ "${K[NATIVE_REINSTALL]:-n}" = y ] && q+=" --reinstall"
            steps+=("$q")
        fi
        if [ "${K[NATIVE_C54X]:-n}" = y ]; then
            q="make -C $(printf %q "$REPO") c54x_exe"
            [ "${C[C54X_ROM]}" = y ] && q+=" c54x_exe-rom"
            for x in ${C[C54X_EXTRA]}; do q+=" c54x_exe-$x"; done
            for x in "C54X_DIR=$(abspath "${C[C54X_DIR]}")" "QOSMO=$(abspath "${C[QOSMO_DIR]}")" \
                     "FREECALYPSO_CACHE=$(abspath "${C[FREECALYPSO_CACHE]}")" \
                     "C54X_NATIVE=${C[C54X_NATIVE]}" "ROM_DIR=$(abspath "${C[ROM_DIR]}")"; do q+=" $(printf %q "$x")"; done
            steps+=("$q")
        fi
        if [ "${K[NATIVE_DEBS]:-n}" = y ]; then
            q="make -C $(printf %q "$REPO")"
            if [ "${C[DEBS_RELEASE]}" = y ]; then q+=" release"; else q+=" debs"; fi
            [ "${C[DEBS_IMAGE]}" = y ] && q+=" debs-image"
            for x in "DEBS_ONLY=${C[DEBS_ONLY]}" "DEBS_OUT=$(abspath "${C[DEBS_OUT]}")" \
                     "QOSMO=$(abspath "${C[QOSMO_DIR]}")" "FIRMWARE_DIR=$(abspath "${C[FIRMWARE_DIR]}")" \
                     ${C[DEBS_RELEASE_TAG]:+"RELEASE_TAG=${C[DEBS_RELEASE_TAG]}"}; do q+=" $(printf %q "$x")"; done
            steps+=("$q")
        fi
        # the build's .config on the host: start.sh --configure reads it
        steps+=("install -D -m644 $(printf %q "$(abspath "$CONFIG_FILE")") /etc/osmocom/build.config")
        CMD=(bash -c "set -e; $(printf '%s; ' "${steps[@]}")")
        ;;
    esac
}

cmd_string() {
    local s="" x
    [ "$CMD_DIR" != "$REPO" ] && s="cd $(printf %q "$CMD_DIR") && "
    case "${C[TARGET]}" in docker|iso|native) [ "$(id -u)" -ne 0 ] && s+="sudo " ;; esac
    [ "${#CMD_ENV[@]}" -gt 0 ] && s+="env "
    for x in "${CMD_ENV[@]}" "${CMD[@]}"; do s+="$(printf %q "$x") "; done
    echo "${s% }"
}

cfg_run() {
    local msg
    if ! msg="$(cfg_check)"; then
        echo "Configuration invalide :" >&2; echo "$msg" | sed 's/^/  - /' >&2; return 2
    fi
    cfg_command
    echo "+ $(cmd_string)"
    mkdir -p "$CMD_DIR" && cd "$CMD_DIR" || return 1
    local pre=()
    case "${C[TARGET]}" in docker|iso|native) [ "$(id -u)" -ne 0 ] && pre=(sudo) ;; esac
    exec "${pre[@]}" env "${CMD_ENV[@]}" "${CMD[@]}"
}

# The dependency trees: each id with what it needs (indented), and what
# needs it ("requis par").
print_tree() {
    local k i r
    for k in docker iso core; do
        case $k in docker) echo "== Groupes de l'image docker ==" ;; iso) echo; echo "== Modules facultatifs de l'ISO ==" ;;
                   core) echo; echo "== Modules obligatoires de l'ISO ==" ;; esac
        for i in $(feat_ids $k); do
            feat_tree "$i" "  "
            r="$(feat_rdeps "$i" | xargs)"; [ -n "$r" ] && echo "      requis par : $r"
        done
    done
}

# ── Modes sans menu ──────────────────────────────────────────────────────────
cfg_defaults
case "$MODE" in
    defconfig) exec make -s -C "$REPO" defconfig KCONFIG_CONFIG="$(abspath "$CONFIG_FILE")" ;;
    tree) print_tree; exit 0 ;;
    print|build)
        cfg_load "$CONFIG_FILE" || { echo "$CONFIG_FILE absent : make menuconfig (ou make defconfig)" >&2; exit 1; }
        if [ "$MODE" = print ]; then
            msg="$(cfg_check)" || { echo "$msg" | sed 's/^/# INVALIDE : /'; }
            cfg_command; cmd_string; exit 0
        fi
        cfg_run; exit $? ;;
esac

# ── Le menu : le Kconfig du depot (make menuconfig) ─────────────────────────
exec make -s -C "$REPO" menuconfig KCONFIG_CONFIG="$(abspath "$CONFIG_FILE")"
