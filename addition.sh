#!/bin/bash
# =============================================================================
# addition.sh - supplements that are not shipped in the ISO
#
# Companion to update.sh, launched the same way: a GTK desktop icon
# (osmo-addition-anim), or by hand.
#
# Why docker is not in the image:
# The ISO is a NATIVE node: it carries the full bench without containers, so
# it needs docker for nothing. Embedding it would cost ~500 MB and the daemon
# would run permanently on a bench that does not use it - with its bridge,
# its iptables rules and its MASQUERADE, on a machine whose whole point is to
# route GSM by hand.
# Docker serves only ONE scenario: the multi-operator (start-multi.sh), where
# operators 2 and 3 and the inter-STP run in containers beside the native one.
# It is a supplement, installed as such - here.
#
# Usage:
#   sudo ./addition.sh            GTK window: "Docker container and SS7
#                                 multioperator", then a second window with
#                                 radio buttons: DOWNLOADED or BUILT image
#                                 (exclusive). osmocom-run is derived right
#                                 after, then osmo-multi.service STARTS: on
#                                 exit, osmo-operator-2, -3 and the hub are
#                                 running (OSMO_MULTI_START=0: install without
#                                 launching).
#   sudo ./addition.sh --multi    the same, without the window: DOWNLOADED
#                                 image (docker pull ghcr.io/<repo>/osmocom-nitb,
#                                 tagged osmocom-nitb)
#   sudo ./addition.sh --multi-build
#                                 the same. This flag no longer COMPILES: it
#                                 also pulls the image from the repo, which
#                                 the CI publishes from the same Dockerfile.
#                                 To really compile (modified Dockerfile,
#                                 nothing published):
#                                   OSMO_ADDITION_BUILD_LOCAL=1 ... --multi-build
#   sudo ./addition.sh --docker   the container engine only   (troubleshooting)
#   sudo ./addition.sh --image    the operator image only, downloaded (troubleshooting)
#   sudo ./addition.sh --build    the operator image only, from the repo   (troubleshooting)
#   sudo ./addition.sh --opencl   the OpenCL stack only (GPU compute)
#   sudo ./addition.sh --claude   Claude Code (assistant CLI) only
#   sudo ./addition.sh --extras   Games + media (Doom, Quake III, Kodi,
#                                 YouTube+uBlock, Wireshark root, Linphone)
#   sudo ./addition.sh --gnuarm   the legacy arm-elf-gcc 4.5.2 toolchain (/root/gnuarm),
#                                 copied from the osmocom-bb-trx Docker image
#   sudo ./addition.sh --magnetite Wine + TI TMS470, FreeCalypso Magnetite C139
#                                 (sources, bench patches, flash image)
#   sudo ./addition.sh --trx      osmocom-bb-trx: published Docker image + trx
#                                 (TX) firmware built with gnuarm
#   sudo ./addition.sh --calypso-fw bench osmocom-bb rebuilt with gnuarm (cd src && make):
#                                 layer1 GPRS, rssi (OSMO_FW_INSTALLER=1: install them)
#   sudo ./addition.sh --fernvale fernly, fernvale-nuttx, layer1 MTK (MT6260)
#   sudo ./addition.sh --simcom   SIMCom documentation and SDK (~3.4 GB)
#   sudo ./addition.sh --firmwares the previous six
#   sudo ./addition.sh --status   only reports what is present
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
# Image name: osmocom-run, NOT "osmo-operator". build.sh produces osmocom-nitb
# (Dockerfile, ~11 GB), then Dockerfile.run derives osmocom-run, which is the
# one start-docker.sh runs (docker inspect osmo-operator-1 --format
# {{.Config.Image}} returns osmocom-run). "osmo-operator" is the REPO name, not
# the image name, so probing for it would always report the image as absent.
MULTI_IMAGE="${MULTI_IMAGE:-osmocom-run}"
# Base image and its origin. osmocom-nitb is what build.sh compiles. It is
# PULLED and tagged osmocom-nitb; start-docker.sh then derives osmocom-run from
# it via Dockerfile.run, exactly as after a local build.
#
# The source is GHCR, not Docker Hub: .github/workflows/docker.yml publishes
# the image on every push to ghcr.io/<repo>/osmocom-nitb - the SAME stack, built
# by the CI from the SAME Dockerfile, following the repo instead of a manually
# maintained Hub account. bastienbaranoff/norf_gsm stays reachable via HUB_IMAGE.
#   :latest      the latest published (default)
#   :base-<sha>  a precise context fingerprint, to pin
BASE_IMAGE="${BASE_IMAGE:-osmocom-nitb}"
HUB_IMAGE="${HUB_IMAGE:-ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest}"

# ── _trust_desktop: make a desktop shortcut VISIBLE to DING ─────────────────
# DING shows a .desktop with its name and icon only if it is executable, owned
# by the desktop user, AND carries metadata::trusted. That attribute does NOT
# live in the file: it is written in the SESSION's gvfs metadata, so gio must
# talk to THAT user's bus.
#
# addition.sh is launched by `pkexec env DISPLAY=... XAUTHORITY=... `
# (osmo-addition-anim); pkexec CLEANS the environment and passes neither
# XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS, so `gio set metadata::trusted`
# has no bus to reach. We rebuild the env from the desktop owner's UID and run
# gio AS that user.
_trust_desktop() {
    local f="$1" home="$2" pos="${3:-}" owner uid bus
    [ -f "$f" ] || return 1
    owner="$(stat -c '%U' "$home" 2>/dev/null)"; [ -n "$owner" ] || owner=root
    uid="$(id -u "$owner" 2>/dev/null)" || return 1
    chown "$owner" "$f" 2>/dev/null || true
    chmod +x "$f" 2>/dev/null || true
    bus="/run/user/$uid/bus"
    # Active session for this owner: set the attributes RIGHT NOW. Otherwise (no
    # bus), osmo-trust-desktop (autostart) sets trusted at the next login, and
    # the icon then appears without intervention.
    # pos "x,y" (optional): place the icon on the desktop via DING.
    if [ -S "$bus" ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            gio set -t string "$f" metadata::trusted true 2>/dev/null || true
        [ -n "$pos" ] && runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            gio set -t string "$f" metadata::nautilus-icon-position "$pos" 2>/dev/null || true
    fi
    return 0
}

# ── Desktops to serve: /root AND the graphical session's ────────────────────
# Find the GRAPHICAL SESSION account, in this order:
#   0. OSMO_COMPTE: the account created by the installer, passed by
#      osmo-supplements-firstboot.sh. At first boot nobody is logged in yet:
#      without it, neither docker group nor icon for that account.
#   1. SUDO_USER   (sudo)
#   2. PKEXEC_UID  (the icon, pkexec)
#   3. the owner of an active session bus (/run/user/*/bus) - systemd, root
#      shell, autologin: the only proof that a session exists.
# SUDO_USER exists ONLY under sudo, and these scripts are launched by an icon
# (pkexec, which sets PKEXEC_UID), a systemd unit, or a root shell - so relying
# on SUDO_USER alone would leave the installer's account with a bare desktop.
# /root is ALWAYS served: the live key opens its session as root.
_comptes_session() {
    local u uid bus
    for u in "${OSMO_COMPTE:-}" "${SUDO_USER:-}" \
             "$([ -n "${PKEXEC_UID:-}" ] && getent passwd "$PKEXEC_UID" | cut -d: -f1)"; do
        [ -n "$u" ] && [ "$u" != root ] || continue
        getent passwd "$u" >/dev/null 2>&1 && { printf '%s\n' "$u"; return 0; }
    done
    for bus in /run/user/*/bus; do
        [ -S "$bus" ] || continue
        uid="${bus#/run/user/}"; uid="${uid%/bus}"
        [ "$uid" = 0 ] && continue
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && printf '%s\n' "$u"
    done
}

_bureau_homes() {
    local homes=(/root) u uh
    while read -r u; do
        [ -n "$u" ] || continue
        uh="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
        [ -n "$uh" ] && [ -d "$uh" ] && homes+=("$uh")
    done < <(_comptes_session)
    printf '%s\n' "${homes[@]}"
}

# ── The session account must be able to talk to docker ──────────────────────
# The Conky and the desktop panel run under the SESSION account. If it is in no
# docker group, every probe (`docker exec ... pgrep`) returns "permission denied
# while trying to connect to the docker API", so the bench reads as stopped even
# while the operators run. Add the account to the docker group; it only takes
# effect at the next login, which is reported rather than left looking broken.
_docker_groupe_session() {
    getent group docker >/dev/null 2>&1 || return 0
    local u
    while read -r u; do
        [ -n "$u" ] || continue
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker && continue
        usermod -aG docker "$u" 2>/dev/null || continue
        echo -e "  ${GREEN}✓${NC} ${BOLD}$u${NC} ajoute au groupe ${BOLD}docker${NC} (le Conky et l encart voient les conteneurs)"
        echo -e "    ${YELLOW}!${NC} effectif au prochain login de $u"
    done < <(_comptes_session)
}

DO_DOCKER=0; DO_IMAGE=0; DO_MULTI=0; DO_OPENCL=0; DO_CLAUDE=0; STATUS_ONLY=0; ANY_FLAG=0
DO_BUILD=0; DO_EXTRAS=0; DO_SIM=0
DO_GNUARM=0; DO_MAGNETITE=0; DO_TRX=0; DO_FERNVALE=0; DO_SIMCOM=0; DO_CALFW=0
for a in "$@"; do
    case "$a" in
        --docker) DO_DOCKER=1; ANY_FLAG=1 ;;
        --image)  DO_IMAGE=1;  ANY_FLAG=1 ;;
        --build)  DO_IMAGE=1;  DO_BUILD=1; ANY_FLAG=1 ;;
        --multi)  DO_MULTI=1;  ANY_FLAG=1 ;;
        --multi-build) DO_MULTI=1; DO_BUILD=1; ANY_FLAG=1 ;;
        --opencl) DO_OPENCL=1; ANY_FLAG=1 ;;
        --claude) DO_CLAUDE=1; ANY_FLAG=1 ;;
        --extras) DO_EXTRAS=1; ANY_FLAG=1 ;;
        --sim)    DO_SIM=1;    ANY_FLAG=1 ;;
        --gnuarm)    DO_GNUARM=1;    ANY_FLAG=1 ;;
        --magnetite) DO_MAGNETITE=1; ANY_FLAG=1 ;;
        --trx)       DO_TRX=1;       ANY_FLAG=1 ;;
        --calypso-fw) DO_CALFW=1;    ANY_FLAG=1 ;;
        --fernvale)  DO_FERNVALE=1;  ANY_FLAG=1 ;;
        --simcom)    DO_SIMCOM=1;    ANY_FLAG=1 ;;
        --firmwares) DO_GNUARM=1; DO_MAGNETITE=1; DO_TRX=1; DO_CALFW=1; DO_FERNVALE=1; DO_SIMCOM=1; ANY_FLAG=1 ;;
        --all)    DO_DOCKER=1; DO_IMAGE=1; DO_MULTI=1; DO_OPENCL=1; DO_CLAUDE=1; DO_EXTRAS=1; DO_SIM=1; ANY_FLAG=1 ;;
        --status) STATUS_ONLY=1; ANY_FLAG=1 ;;
        -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    esac
done

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - supplements (hors ISO)             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

etat() {
    local ok_d=0 ok_r=0 ok_i=0 ok_m=0 ok_u=0 ok_k=0
    command -v docker >/dev/null 2>&1 && ok_d=1
    [ "$ok_d" = "1" ] && docker info >/dev/null 2>&1 && ok_r=1
    [ "$ok_r" = "1" ] && docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1 && ok_i=1
    [ -f "$MULTI_CONF" ] && ok_m=1
    # Report the same conditions launch.sh --multi requires: the
    # osmo-multi.service unit, start-multi.sh and the topology. Read here what
    # the icon checks at click time.
    systemctl cat osmo-multi.service >/dev/null 2>&1 && ok_u=1
    [ -f /usr/share/applications/osmo-multi.desktop ] && ok_k=1
    local ok_cl=0
    # clinfo returning at least one platform is the only proof the OpenCL stack
    # is USABLE. Installed packages prove nothing - an ICD with no driver behind
    # it leaves "Number of platforms 0".
    command -v clinfo >/dev/null 2>&1 \
        && [ "$(clinfo -l 2>/dev/null | grep -c Platform)" -gt 0 ] && ok_cl=1
    local ok_cc=0
    # claude answering --version is the only proof it is USABLE. The binary
    # installed without node behind it (broken npm install) exits with an error.
    command -v claude >/dev/null 2>&1 \
        && claude --version >/dev/null 2>&1 && ok_cc=1
    [ "$ok_d" = "1" ] && echo -e "  docker installe      : ${GREEN}oui${NC}"      || echo -e "  docker installe      : ${YELLOW}non${NC}"
    [ "$ok_r" = "1" ] && echo -e "  demon actif          : ${GREEN}oui${NC}"      || echo -e "  demon actif          : ${YELLOW}non${NC}"
    [ "$ok_i" = "1" ] && echo -e "  image operateur      : ${GREEN}presente${NC}" || echo -e "  image operateur      : ${YELLOW}absente${NC}"
    [ "$ok_m" = "1" ] && echo -e "  topologie SS7        : ${GREEN}posee${NC}"    || echo -e "  topologie SS7        : ${YELLOW}absente${NC}"
    [ "$ok_u" = "1" ] && echo -e "  osmo-multi.service   : ${GREEN}pose${NC} ($(systemctl is-active osmo-multi.service 2>/dev/null || echo inactive))" || echo -e "  osmo-multi.service   : ${YELLOW}absent${NC}"
    [ "$ok_k" = "1" ] && echo -e "  icone multi-operator : ${GREEN}posee${NC}"    || echo -e "  icone multi-operator : ${YELLOW}absente${NC}"
    [ -x "$DIR/launch/start-multi.sh" ] || echo -e "  start-multi.sh       : ${YELLOW}absent de $DIR${NC}"
    [ "$ok_cl" = "1" ] && echo -e "  OpenCL               : ${GREEN}operationnel${NC}" || echo -e "  OpenCL               : ${YELLOW}absent${NC}"
    [ "$ok_cc" = "1" ] && echo -e "  Claude Code          : ${GREEN}operationnel${NC}" || echo -e "  Claude Code          : ${YELLOW}absent${NC}"
    # phone firmwares (tools/osmo-firmwares-install.sh)
    _fw_etat() { [ -e "$2" ] && echo -e "  $(printf '%-20s' "$1") : ${GREEN}present${NC}" || echo -e "  $(printf '%-20s' "$1") : ${YELLOW}absent${NC}"; }
    _fw_etat "gnuarm"            /root/gnuarm/install/bin/arm-elf-gcc
    _fw_etat "Magnetite C139"    /opt/GSM/firmware/magnetite/c139-flash.img
    _fw_etat "firmware trx (TX)" /opt/GSM/osmocom-bb-trx/src/target/firmware/board/compal_e88/trx.highram.bin
    _fw_etat "layer1 GPRS (gnuarm)" /opt/GSM/osmocom-bb/src/target/firmware/board/compal_e88/layer1.highram.bin
    _fw_etat "Fernvale fernly"   /opt/GSM/fernly/build/firmware.bin
    _fw_etat "Fernvale NuttX"    /opt/GSM/fernvale-nuttx/nuttx/nuttx.bin
    _fw_etat "layer1 MTK"        /opt/GSM/osmocom-bb-mtk-layer1/src/target/firmware/board/fernvale/layer1.mt6260.bin
    _fw_etat "SIMCom"            /opt/GSM/simcom/.git
    { command -v docker >/dev/null 2>&1 && docker image inspect "${OSMOCOM_BB_TRX_IMAGE:-ghcr.io/bbaranoff/osmocom-bb-trx:main}" >/dev/null 2>&1; } \
        && echo -e "  image osmocom-bb-trx : ${GREEN}presente${NC}" || echo -e "  image osmocom-bb-trx : ${YELLOW}absente${NC}"
}

[ "$STATUS_ONLY" = "1" ] && { etat; exit 0; }

# ── osmo-* units: User=osmocom -> the SESSION account ───────────────────────
# The upstream .service files (osmo-bsc/bts-trx/bts-virtual/msc) set
# User=osmocom / Group=osmocom. In native post-live the osmocom account does
# not exist (the image removes it, see iso_modules/52-qemu.sh): the daemons die
# with 217/USER and Restart=always -> a blocking, SILENT crash-loop, and run.sh
# aborts ("OsmoMSC started but never ready"). Reassign these units to the
# SESSION account via a drop-in /etc/systemd/system/<unit>.d/ - do NOT touch the
# upstream .service that a package update would rewrite. With no session (chroot
# build): root, like 52-qemu.sh. Mirrored by update.sh (for already-installed
# machines) and 52-qemu.sh (live image -> root).
_osmo_unites_user_session() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local u grp unit base d n=0
    u="$(_comptes_session | head -1)"
    [ -n "$u" ] && getent passwd "$u" >/dev/null 2>&1 || u=root
    grp="$(id -gn "$u" 2>/dev/null || echo "$u")"
    for unit in /lib/systemd/system/osmo-*.service /etc/systemd/system/osmo-*.service; do
        [ -f "$unit" ] || continue
        grep -qE '^(User|Group)=osmocom$' "$unit" || continue
        base="$(basename "$unit")"; d="/etc/systemd/system/$base.d"
        mkdir -p "$d"
        printf '[Service]\nUser=%s\nGroup=%s\n' "$u" "$grp" > "$d/00-session-user.conf"
        n=$((n+1))
    done
    [ "$n" -gt 0 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    # The osmocom state/log directories are owned by root/osmocom: without this
    # chown the daemon (now User=$u) cannot create /var/log/osmocom/*.log
    # -> "Unable to create file" -> .cfg parse fails -> status=1.
    for _d in /var/log/osmocom /var/lib/osmocom /run/osmocom; do
        [ -e "$_d" ] && chown -R "$u:$grp" "$_d" 2>/dev/null || true
    done
    # break any running crash-loop: restart the units that were running/looping
    for base in osmo-msc osmo-bsc osmo-bts-trx osmo-bts-virtual; do
        systemctl cat "$base" >/dev/null 2>&1 || continue
        systemctl reset-failed "$base" 2>/dev/null || true
        systemctl try-restart "$base" 2>/dev/null || true
    done
    echo -e "  ${GREEN}\u2713${NC} unites osmo-* rendues au compte de session ${BOLD}$u${NC} (sinon User=osmocom introuvable -> 217/USER)"
    return 0
}
_osmo_unites_user_session

# ── The choice ──────────────────────────────────────────────────────────────
# Launched by the icon, this window is the ONLY interface: without it a
# double-click would go straight to a multi-hundred-MB apt-get and an Osmocom
# compilation without asking anything.
#
# Two choices are offered. The multi-operator is one supplement that ENTAILS
# docker and the operator image (the implication just below sets DO_DOCKER=1 and
# DO_IMAGE=1): docker without an image, or an 11 GB image without the topology,
# are useless on their own, so they are not offered separately. OpenCL is a
# genuinely INDEPENDENT supplement: it entails nothing and nothing entails it.
# The --docker / --image / --opencl flags remain for console troubleshooting.
if [ "$ANY_FLAG" = "0" ]; then
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        # --print-column=2 is NOT optional: zenity defaults to column 1, which
        # for a --checklist is the CHECKBOX - we would get a list of "TRUE"
        # instead of the choices. We print column 2, hidden, which carries the
        # KEY ("multi", "opencl"): the displayed label can then change without
        # breaking the tests below.
        # --separator: the default "|" travels badly through the tests below; we
        # pick a character that appears in no label.
        _choix=$(zenity --list --checklist --width=680 --height=340 \
            --title="osmo-operator - supplements" \
            --text="Supplements qui ne sont PAS dans l ISO.\nUne connexion Internet est necessaire." \
            --ok-label="Installer" --cancel-label="Fermer" \
            --separator="~" \
            --column="" --column="cle" --column="Supplement" \
            --hide-column=2 --print-column=2 \
            TRUE  multi  "Docker container and SS7 multioperator - docker.io, l image operateur (telechargee du hub OU compilee sur place : le choix vient ensuite), et la topologie op1 natif + op2/op3 docker + inter-STP" \
            FALSE opencl "OpenCL (calcul GPU) - runtime ICD, clinfo, le pilote de la carte detectee (Intel / Mesa-AMD, pocl en repli), et les outils deka / a51_tools / dst80_reversing / tea1-cracker clones dans /root" \
            FALSE claude "Claude Code (CLI de l assistant IA) - installeur natif claude.ai/install.sh (binaire autonome, sans npm) ; lance ensuite avec la commande claude" \
            FALSE firmwares "Firmwares telephone - gnuarm (arm-elf-gcc 4.5.2), FreeCalypso Magnetite C139 (Wine + TI TMS470), osmocom-bb-trx (image Docker + firmware trx TX), Fernvale MT6260 (fernly, NuttX, layer1 MTK), documentation SIMCom ; long (plusieurs Go, compilations)" \
            FALSE extras "Jeux + media - Doom (freedoom + chocolate-doom), Quake III (OpenArena), Kodi, YouTube (Firefox + uBlock Origin), Wireshark (root), Linphone ; ranges dans les dossiers Jeux / Media / Telephone / Outils et lancables depuis l encart du bureau" \
            2>/dev/null) || { echo "Annule."; exit 0; }
        [ -n "$_choix" ] || { echo "Rien de selectionne."; exit 0; }
        case "$_choix" in *multi*)  DO_MULTI=1  ;; esac
        # Image origin: a second window, with RADIO BUTTONS. Two sources,
        # exclusive by construction - a radiolist returns a single value, so
        # there is no "both" to resolve afterwards as with checkboxes.
        if [ "$DO_MULTI" = "1" ]; then
            _orig=$(zenity --list --radiolist --width=680 --height=260 \
                --title="osmo-operator - image operateur" \
                --text="D ou vient l image operateur (osmocom-nitb, ~11 Go) ?" \
                --ok-label="Continuer" --cancel-label="Fermer" \
                --column="" --column="cle" --column="Origine" \
                --hide-column=2 --print-column=2 \
                TRUE  dl    "LE DEPOT (GHCR) - ${HUB_IMAGE}, publiee par la CI a chaque push" \
                FALSE hub   "DOCKER HUB - bastienbaranoff/norf_gsm, la pile publiee a la main" \
                2>/dev/null) || { echo "Annule."; exit 0; }
            # The two choices are two sources, not "pull or build". A local
            # build is still available but requested explicitly
            # (OSMO_ADDITION_BUILD_LOCAL=1), not via a radio button.
            case "$_orig" in
                hub)   DO_BUILD=0; HUB_IMAGE="bastienbaranoff/norf_gsm"; HUB_IS_RUN=1 ;;
                dl)    DO_BUILD=0 ;;
                *)     echo "Aucune origine choisie."; exit 0 ;;
            esac
        fi
        case "$_choix" in *opencl*) DO_OPENCL=1 ;; esac
        case "$_choix" in *claude*) DO_CLAUDE=1 ;; esac
        case "$_choix" in *extras*) DO_EXTRAS=1 ;; esac
        case "$_choix" in *firmwares*) DO_GNUARM=1; DO_MAGNETITE=1; DO_TRX=1; DO_CALFW=1; DO_FERNVALE=1; DO_SIMCOM=1 ;; esac
    else
        # Console without zenity: default to the icon's supplement.
        DO_MULTI=1
    fi
fi

# The multi-operator ENTAILS its dependencies: without engine or image the
# topology would be useless and start-multi.sh would come back here.
if [ "$DO_MULTI" = "1" ]; then DO_DOCKER=1; DO_IMAGE=1; fi
# osmocom-bb-trx: the host side is a Docker image, so it needs the engine.
# gnuarm too: the arm-elf-gcc toolchain is no longer rebuilt, it is copied from
# that same image (tools/osmo-firmwares-install.sh). The bench Calypso firmware
# (--calypso-fw) requires it.
if [ "$DO_TRX$DO_GNUARM$DO_CALFW" != "000" ]; then DO_DOCKER=1; fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── OPENCL ──────────────────────────────────────────────────────────────────
# Independent supplement: nothing here entails docker and docker does not entail
# this. It serves GPU compute - heavy SDR-side processing (correlation, wide
# FFTs) and anything a user wants to run alongside.
#
# An OpenCL stack has two halves, and the classic mistake is to install only
# one. The "runtime" (ocl-icd) is just a dispatcher: it reads
# /etc/OpenCL/vendors/*.icd and loads the VENDOR library named there. Without a
# vendor ICD, everything installs without error and clinfo returns
#     Number of platforms   0
# which looks like unsupported hardware when only a package is missing. So we
# install the dispatcher AND the driver of the card actually present, read from
# lspci.
#
# pocl is installed in all cases: it is a CPU implementation. It does not
# replace a GPU, but it guarantees an OpenCL program always finds a platform -
# including in a VM or on a bench with no dedicated graphics card, where the
# total absence of a platform makes the code fail with a CL_PLATFORM_NOT_FOUND_KHR.
#
# NVIDIA is the special case: its OpenCL ICD is not a standalone package, it
# ships with the proprietary driver (libnvidia-compute-xxx, pulled by
# nvidia-driver-xxx). We install the driver and the ICD comes with it. It is a
# proprietary graphics driver on a machine whose display depends on it: a REBOOT
# is usually needed for it to take effect, which is stated clearly.
#
# The version is pinned: nvidia-driver-610, not `ubuntu-drivers install` (which
# queried the repos and decided on its own, so the installed driver varied
# between machines). OSMO_NVIDIA_DRIVER selects a different one.
if [ "$DO_OPENCL" = "1" ]; then
    echo -e "  ${CYAN}→${NC} installation de la pile OpenCL ..."
    export DEBIAN_FRONTEND=noninteractive

    # lvm2: NOT part of OpenCL, but deka (installed with this supplement) mounts
    # its tables on LVM volumes - without vgchange, deka-start.sh mounts nothing.
    # Installed here, with deka.
    # swig4.1 + python3-dev: build deka's native modules (_delta.so,
    # _libvankus.so) below. build-essential is pulled elsewhere.
    # swig4.1 and NOT swig: the noble `swig` metapackage pulls swig 4.2, under
    # which deka's interfaces no longer build. 4.1 is in the distribution
    # (noble/universe, package swig4.1): name it explicitly.
    _cl_pkgs="ocl-icd-libopencl1 ocl-icd-opencl-dev opencl-headers clinfo pocl-opencl-icd lvm2 swig4.1 python3-dev"
    _vga="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' || true)"
    _nvidia=0
    case "$_vga" in
        *[Ii]ntel*)   _cl_pkgs="$_cl_pkgs intel-opencl-icd" ;;
    esac
    case "$_vga" in
        *AMD*|*ATI*|*[Rr]adeon*) _cl_pkgs="$_cl_pkgs mesa-opencl-icd" ;;
    esac
    case "$_vga" in
        *NVIDIA*|*nVidia*) _nvidia=1 ;;
    esac
    echo -e "      paquets : ${BOLD}${_cl_pkgs}${NC}"

    apt-get update || { echo -e "  ${RED}✗ apt-get update a echoue - pas de reseau ?${NC}"
                        echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
                        exit 1; }
    # Package by package, non-fatal: a vendor ICD missing from the mirror must
    # not take the runtime down with it - the CPU stack stays usable.
    for _p in $_cl_pkgs; do
        apt-get install -y "$_p" >/dev/null 2>&1 \
            && echo -e "      ${GREEN}✓${NC} $_p" \
            || echo -e "      ${YELLOW}!${NC} $_p non installe (absent du miroir ?)"
    done

    # pyopencl: the Python OpenCL binding, installed in the VENV /root/.env - the
    # same one start-clean.sh (qosmo-grgsm) and root's profile activate, and
    # where gr-gsm already lives. Installed with the VENV pip
    # (/root/.env/bin/python3), not the system pip, otherwise the module would
    # not be visible to code running under that venv. opencl-headers +
    # ocl-icd-opencl-dev (installed above) provide the headers and libOpenCL.so
    # pyopencl needs. Non-fatal.
    if [ -x /root/.env/bin/python3 ]; then
        echo -e "  ${CYAN}→${NC} pyopencl dans le venv ${BOLD}/root/.env${NC} ..."
        if /root/.env/bin/python3 -m pip install --no-cache-dir --disable-pip-version-check pyopencl >/dev/null 2>&1; then
            echo -e "      ${GREEN}✓${NC} pyopencl"
        else
            echo -e "      ${YELLOW}!${NC} pyopencl non installe (voir : /root/.env/bin/python3 -m pip install pyopencl)"
        fi
    else
        echo -e "  ${YELLOW}!${NC} venv /root/.env absent - pyopencl non pose (attendu sur l ISO)"
    fi

    # The only check that matters: does a platform respond?
    if command -v clinfo >/dev/null 2>&1; then
        _np="$(clinfo -l 2>/dev/null | grep -c Platform || true)"
        if [ "${_np:-0}" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} OpenCL operationnel - ${BOLD}${_np}${NC} plateforme(s) :"
            clinfo -l 2>/dev/null | sed 's/^/      /'
        else
            echo -e "  ${YELLOW}!${NC} paquets poses, mais aucune plateforme OpenCL ne repond."
            echo -e "      Voir : ${BOLD}ls /etc/OpenCL/vendors/${NC} puis ${BOLD}clinfo${NC}"
        fi
    fi

    if [ "$_nvidia" = "1" ]; then
        echo -e "  ${CYAN}→${NC} carte ${BOLD}NVIDIA${NC} detectee : installation du pilote (ICD OpenCL inclus) ..."
        # Kernel headers first. The NVIDIA driver builds its module via DKMS
        # against the RUNNING kernel: without linux-headers-$(uname -r), dkms
        # and build-essential, the module build fails and the install errors
        # out (often silently: the package installs, but nvidia.ko does not
        # exist and OpenCL stays absent). Install them first.
        _kver="$(uname -r)"
        echo -e "      ${CYAN}→${NC} pre-requis DKMS : linux-headers-${_kver}, dkms, build-essential"
        apt-get install -y "linux-headers-${_kver}" dkms build-essential >/dev/null 2>&1 \
            || echo -e "      ${YELLOW}!${NC} headers/dkms : installation partielle (headers absents du miroir ?)"
        # linux-headers-generic as a safety net: keeps the headers aligned with
        # the meta-kernel for later kernel updates.
        apt-get install -y linux-headers-generic >/dev/null 2>&1 || true
        _nvdrv="${OSMO_NVIDIA_DRIVER:-nvidia-driver-610}"
        echo -e "      ${CYAN}→${NC} ${BOLD}apt install ${_nvdrv}${NC}"
        if apt-get install -y "$_nvdrv"; then
            echo -e "  ${GREEN}✓${NC} pilote NVIDIA installe : ${BOLD}$(dpkg-query -W -f='${Version}' "$_nvdrv" 2>/dev/null)${NC}"
        else
            echo -e "  ${YELLOW}!${NC} ${BOLD}${_nvdrv}${NC} non installe - il est dans multiverse :"
            echo -e "      ${BOLD}sudo add-apt-repository multiverse && sudo apt install ${_nvdrv}${NC}"
        fi
        # ── Secure Boot: sign the NVIDIA modules (MOK) ───────────────────────
        # Under Secure Boot, the kernel REFUSES a module not signed by a trusted
        # key: nvidia.ko built by DKMS is signed by no one, and the driver stays
        # silent (nvidia-smi: "NVIDIA-SMI has failed..."). Generate a MOK key
        # (once), SIGN the current kernel's nvidia*.ko modules, then PROPOSE the
        # key for enrollment (mokutil) - to be CONFIRMED at the next reboot in
        # the blue MOK Manager screen. Outside Secure Boot or with no module:
        # skip. Standard Ubuntu location: /var/lib/shim-signed/mok.
        if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
            echo -e "  ${CYAN}→${NC} Secure Boot actif : signature MOK des modules NVIDIA ..."
            apt-get install -y --no-install-recommends openssl mokutil zstd xz-utils >/dev/null 2>&1 || true
            _mokdir=/var/lib/shim-signed/mok
            _mokkey="$_mokdir/MOK.priv"; _mokder="$_mokdir/MOK.der"
            _mokpw="${OSMO_MOK_PASSWORD:-osmo-operator}"
            mkdir -p "$_mokdir"
            if [ ! -s "$_mokkey" ] || [ ! -s "$_mokder" ]; then
                if openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
                        -keyout "$_mokkey" -outform DER -out "$_mokder" \
                        -subj "/CN=osmo-operator NVIDIA MOK/" >/dev/null 2>&1; then
                    chmod 600 "$_mokkey"
                    echo -e "      ${GREEN}✓${NC} cle MOK generee : $_mokder"
                else
                    echo -e "      ${YELLOW}!${NC} generation cle MOK echouee (openssl ?)"
                fi
            else
                echo -e "      ${CYAN}→${NC} cle MOK existante reutilisee : $_mokder"
            fi
            _kver="$(uname -r)"
            _signfile="/usr/src/linux-headers-${_kver}/scripts/sign-file"
            [ -x "$_signfile" ] || _signfile="/lib/modules/${_kver}/build/scripts/sign-file"
            if [ -x "$_signfile" ] && [ -s "$_mokkey" ] && [ -s "$_mokder" ]; then
                _signed=0
                while IFS= read -r _ko; do
                    case "$_ko" in
                        *.ko)     "$_signfile" sha256 "$_mokkey" "$_mokder" "$_ko" 2>/dev/null && _signed=$((_signed+1)) ;;
                        *.ko.xz)  xz -d "$_ko"        && "$_signfile" sha256 "$_mokkey" "$_mokder" "${_ko%.xz}"  2>/dev/null && xz -q "${_ko%.xz}"          && _signed=$((_signed+1)) ;;
                        *.ko.zst) zstd -q -d --rm "$_ko" && "$_signfile" sha256 "$_mokkey" "$_mokder" "${_ko%.zst}" 2>/dev/null && zstd -q --rm "${_ko%.zst}" && _signed=$((_signed+1)) ;;
                        *.ko.gz)  gunzip "$_ko"      && "$_signfile" sha256 "$_mokkey" "$_mokder" "${_ko%.gz}"  2>/dev/null && gzip "${_ko%.gz}"           && _signed=$((_signed+1)) ;;
                    esac
                done < <(find "/lib/modules/${_kver}" -name 'nvidia*.ko*' 2>/dev/null)
                depmod -a "${_kver}" 2>/dev/null || true
                echo -e "      ${GREEN}✓${NC} ${_signed} module(s) NVIDIA signe(s) (noyau ${_kver})"
            else
                echo -e "      ${YELLOW}!${NC} sign-file absent (linux-headers-${_kver} ?) - modules NON signes"
            fi
            if mokutil --test-key "$_mokder" >/dev/null 2>&1; then
                echo -e "      ${GREEN}✓${NC} cle MOK deja enrolee dans le firmware"
            elif printf '%s\n%s\n' "$_mokpw" "$_mokpw" | mokutil --import "$_mokder" >/dev/null 2>&1; then
                echo -e "  ${YELLOW}!${NC} MOK proposee a l enrolement. AU PROCHAIN REDEMARRAGE, l ecran bleu"
                echo -e "      ${BOLD}MOK Manager${NC} : Enroll MOK -> Continue -> mot de passe = ${BOLD}${_mokpw}${NC}"
            else
                echo -e "      ${YELLOW}!${NC} mokutil --import echoue (deja en attente ? droits root ?)"
            fi
        fi
        echo -e "  ${YELLOW}!${NC} un ${BOLD}redemarrage${NC} est generalement necessaire pour que le pilote"
        echo -e "      NVIDIA (et donc son OpenCL) soit actif - ${BOLD}clinfo${NC} le confirmera ensuite."
    fi

    # ── The tools that run on OpenCL ─────────────────────────────────────────
    # deka, a51_tools, dst80_reversing, tea1-cracker: four compute repositories
    # that use the GPU. They GO WITH OpenCL, so they are installed here with it,
    # not in the ISO: the image stays a GSM node, these are a compute supplement.
    # Cloned into /root. Idempotent: if a repo is already there, update it (git
    # pull) instead of re-cloning. Non-fatal - an unreachable repo (private,
    # network) does not stop the rest.
    echo -e "  ${CYAN}→${NC} outils OpenCL (deka, a51_tools, dst80_reversing, tea1-cracker) dans /root ..."
    # Non-interactive, otherwise the window hangs. On a private or absent repo,
    # git asks for credentials on the terminal and waits INDEFINITELY - launched
    # by the icon, there is no one to answer. GIT_TERMINAL_PROMPT=0 makes it fail
    # cleanly (no prompt), and the message below says what to do.
    export GIT_TERMINAL_PROMPT=0
    for _rt in "deka=https://github.com/bbaranoff/deka" \
               "a51_tools=https://github.com/bbaranoff/a51_tools" \
               "dst80_reversing=https://github.com/bbaranoff/dst80_reversing" \
               "tea1-cracker=https://github.com/bbaranoff/tea1-cracker"; do
        _name="${_rt%%=*}"; _url="${_rt#*=}"; _dst="/root/$_name"
        # Capture git's output and SHOW it on failure.
        GIT="git"
        if [ -d "$_dst/.git" ]; then
            if _err=$($GIT -C "$_dst" pull --ff-only 2>&1); then
                echo -e "      ${GREEN}✓${NC} $_name a jour ($(git -C "$_dst" log -1 --format='%h'))"
            else
                echo -e "      ${YELLOW}!${NC} $_name : git pull a echoue - $(echo "$_err" | tail -1)"
            fi
        elif _err=$($GIT clone --depth 1 "$_url" "$_dst" 2>&1); then
            echo -e "      ${GREEN}✓${NC} $_name clone ($(git -C "$_dst" log -1 --format='%h'))"
        else
            echo -e "      ${YELLOW}!${NC} $_name : clone impossible - $_url"
            echo -e "        ${YELLOW}git:${NC} $(echo "$_err" | tail -1)"
        fi
    done

    # ── deka: build the native modules (make) ────────────────────────────────
    # deka imports _delta.so and _libvankus.so, produced by SWIG + gcc from
    # delta.c / libvankus.c (see its Makefile). Without this make, the workers
    # import missing modules and deka computes nothing. Requires: swig4.1 and
    # the python3 headers. Non-fatal: a failure is reported without stopping.
    if [ -f /root/deka/Makefile ]; then
        echo -e "  ${CYAN}→${NC} deka : compilation des modules natifs (make) ..."
        apt-get install -y --no-install-recommends swig4.1 python3-dev build-essential >/dev/null 2>&1 || true
        if ( cd /root/deka && make >/dev/null 2>&1 ) \
           && [ -e /root/deka/_delta.so ] && [ -e /root/deka/_libvankus.so ]; then
            echo -e "      ${GREEN}✓${NC} _delta.so + _libvankus.so construits"
        else
            echo -e "      ${YELLOW}!${NC} make deka a echoue (swig4.1 / python3-dev ?) - voir : cd /root/deka && make"
        fi
    fi

    # ── deka: an application ICON (not a service) ────────────────────────────
    # deka mounts tables and launches workers - this must NOT start at every
    # boot behind the user's back (the mount assumes the volume group present).
    # So we install an icon: the user clicks it when they want to start deka.
    # deka-start.sh remains the engine; the icon calls it with root rights
    # (pkexec) in a terminal, to see the output.
    if [ -d /root/deka ]; then
        echo -e "  ${CYAN}→${NC} deka : pose de l icone d application ..."
        # deka-start.sh lives in the repo: if it is there (up-to-date clone),
        # leave it alone. Write it only as a FALLBACK, for a clone that does not
        # have it yet.
        if [ ! -f /root/deka/deka-start.sh ]; then
        cat > /root/deka/deka-start.sh <<'DEKASTART'
#!/bin/bash
# deka-start.sh - montage des tables deka et lancement des workers.
# Pose par addition.sh (supplement OpenCL). Lance par l icone deka (pkexec), ou
# a la main : sudo /root/deka/deka-start.sh
#   1. vgchange -ay : active le groupe de volumes (sinon /dev/tables/* absent).
#   2. les 4 points de montage, puis les 4 volumes (1_10..31_40).
#   3. les 3 workers python, depuis /root/deka (delta.pyc y vit).
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOG=/var/log/deka.log
# Sortie a l ECRAN + copie dans le log (tee) : on veut VOIR les montages et les
# PID des workers, pas les chercher dans un fichier.
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) deka-start ==="
[ "$(id -u)" -eq 0 ] || { echo "root requis : sudo $0"; exit 1; }
PY="$(command -v python3.7 || command -v python3)"
[ -n "$PY" ] || { echo "aucun python3 trouve"; exit 1; }
vgchange -ay || echo "ATTENTION: vgchange -ay a echoue (groupe absent ?)"
mkdir -p /mnt1 /mnt2 /mnt3
monter() {
    local dev="$1" pt="$2"
    if mountpoint -q "$pt"; then echo "deja monte: $pt"; return 0; fi
    if [ ! -e "$dev" ]; then echo "ABSENT: $dev - non monte sur $pt"; return 1; fi
    mount "$dev" "$pt" && echo "monte: $dev -> $pt" || echo "ECHEC montage: $dev -> $pt"
}
monter /dev/tables/1_10  /mnt
monter /dev/tables/11_20 /mnt1
monter /dev/tables/21_30 /mnt2
monter /dev/tables/31_40 /mnt3
cd "$DIR" || exit 1
for w in paplon.py oclvankus.py delta_client.py; do
    [ -f "$w" ] || { echo "worker absent: $w"; continue; }
    echo "lancement: $PY $DIR/$w"
    "$PY" "$DIR/$w" >>"/var/log/deka-${w%.py}.log" 2>&1 &
    echo "  pid $!"
done
echo "deka-start termine."
DEKASTART
        chmod 755 /root/deka/deka-start.sh
        fi

        # The launcher: deka-start.sh needs root (vgchange, mount). From an icon
        # we are not root: pkexec elevates, and a terminal stays open to read the
        # output (mounts, worker PIDs). Same style as osmo-addition-anim.
        cat > /usr/local/bin/osmo-deka-anim <<'DEKAGUI'
#!/bin/bash
set -u
# osmo-deka-anim - deka dans une fenetre GTK du banc (terminal VTE dedans),
# en root par pkexec. [2026-10-01] Plus de gnome-terminal.
SCRIPT=/root/deka/deka-start.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="deka-start.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
exec python3 /opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --root --title "deka" -- "$SCRIPT" "$@"
DEKAGUI
        chmod 755 /usr/local/bin/osmo-deka-anim

        # Dedicated icon (data/deka.svg), set as an ABSOLUTE PATH in Icon= - a
        # theme name arriving after icon-theme.cache would show as a blank page.
        install -d /usr/share/osmo-operator/icons /usr/share/icons/hicolor/scalable/apps
        if [ -f "$DIR/data/deka.svg" ]; then
            install -m644 "$DIR/data/deka.svg" /usr/share/osmo-operator/icons/deka.svg
            install -m644 "$DIR/data/deka.svg" /usr/share/icons/hicolor/scalable/apps/deka.svg
        fi
        _deka_desktop=/usr/share/applications/deka.desktop
        cat > "$_deka_desktop" <<'DEKADSK'
[Desktop Entry]
Type=Application
Name=deka
Name[fr]=deka
Comment=Monte les tables et lance les workers deka
Comment[fr]=Monte les tables et lance les workers deka
Exec=/usr/local/bin/osmo-deka-anim
Icon=/usr/share/osmo-operator/icons/deka.svg
Terminal=false
Categories=System;Utility;
Keywords=deka;tables;workers;opencl;
Actions=Arreter;

[Desktop Action Arreter]
Name=Arreter deka
Name[fr]=Arreter deka
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --title "Arret deka" -- /root/deka/deka-start.sh --stop
DEKADSK
        chmod 644 "$_deka_desktop"
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        update-desktop-database /usr/share/applications 2>/dev/null || true

        # ── No deka icon on the desktop ───────────────────────────────────
        # deka stays launchable: the /usr/share/applications/deka.desktop entry
        # above puts it in the applications menu, and deka-start.sh is called
        # directly. No icon is imposed on the desktop.
        # Also remove any dropped by a previous run.
        for _h in /root /home/*; do
            for _dir in Bureau Desktop; do
                rm -f "$_h/$_dir/deka.desktop" 2>/dev/null || true
            done
        done
        echo -e "  ${GREEN}✓${NC} deka : dans le ${BOLD}menu des applications${NC} (aucune icone posee sur le bureau)"
    fi
fi

# ── Claude Code ───────────────────────────────────────────────────────────
# Independent supplement: Claude Code, the assistant CLI. Nothing here entails
# docker or OpenCL, and nothing entails it - it can be wanted on its own.
#
# We use the native installer (claude.ai/install.sh), not npm.
# @anthropic-ai/claude-code via npm requires node >= 18, but the node in the
# Ubuntu 22.04 repos is a v12, too old - the npm install would break, or would
# require a third-party repo (NodeSource) avoided here as get.docker.com is
# avoided below. The native installer drops a standalone binary (embedded node),
# without touching the system: the safest path.
#
# It installs into ~/.local/bin (so /root/.local/bin when run via sudo). We link
# that binary into /usr/local/bin so it is on everyone's PATH and the
# `command -v claude` probe sees it.
if [ "$DO_CLAUDE" = "1" ]; then
    echo -e "  ${CYAN}→${NC} installation de Claude Code ..."
    export DEBIAN_FRONTEND=noninteractive

    # curl + certificates: the installer requires them. Non-fatal in itself, but
    # warn early if the network is missing - nothing is pre-downloaded in the ISO.
    command -v curl >/dev/null 2>&1 || apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "  ${RED}✗ curl absent et non installable - pas de reseau ?${NC}"
        echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
        exit 1
    fi

    # Explicit HOME: launched by pkexec/sudo, $HOME may be missing or point
    # elsewhere; the installer drops into $HOME/.local/bin, we want to know where.
    _cc_home="${HOME:-/root}"
    if _out=$(HOME="$_cc_home" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1); then
        echo -e "      ${GREEN}✓${NC} installeur natif termine"
    else
        echo -e "      ${YELLOW}!${NC} installeur natif en echec - $(echo "$_out" | tail -1)"
    fi

    # Find the installed binary and link it onto the global PATH. Look at the
    # installer's known locations (~/.local/bin, then /root as fallback).
    _cc_bin=""
    for _c in "$_cc_home/.local/bin/claude" /root/.local/bin/claude "$_cc_home/.claude/bin/claude"; do
        [ -x "$_c" ] && { _cc_bin="$_c"; break; }
    done
    if [ -n "$_cc_bin" ] && [ ! -e /usr/local/bin/claude ]; then
        ln -sf "$_cc_bin" /usr/local/bin/claude
        echo -e "      ${GREEN}✓${NC} lien /usr/local/bin/claude -> $_cc_bin"
    fi

    # The only check that matters: does claude respond?
    if command -v claude >/dev/null 2>&1 && _ver=$(claude --version 2>/dev/null); then
        echo -e "  ${GREEN}✓${NC} Claude Code operationnel - ${BOLD}${_ver}${NC}"
        echo -e "      lancez-le avec la commande ${BOLD}claude${NC}"
    else
        echo -e "  ${YELLOW}!${NC} Claude Code pose, mais ne repond pas encore."
        echo -e "      Ouvrez un nouveau terminal (PATH), ou lancez ${BOLD}$_cc_home/.local/bin/claude${NC}"
    fi

    # ── Claude icon (data/claude.svg) ────────────────────────────────────────
    # Launcher osmo-claude-anim: opens a terminal that runs claude; if it is not
    # installed, it first runs this same supplement (--claude), then launches it.
    install -d /usr/share/osmo-operator/icons /usr/share/icons/hicolor/scalable/apps
    if [ -f "$DIR/data/claude.svg" ]; then
        install -m644 "$DIR/data/claude.svg" /usr/share/osmo-operator/icons/claude.svg
        install -m644 "$DIR/data/claude.svg" /usr/share/icons/hicolor/scalable/apps/claude.svg
    fi
    cat > /usr/local/bin/osmo-claude-anim <<'CLA'
#!/bin/bash
# osmo-claude-anim - Claude Code dans une fenetre GTK du banc (terminal VTE :
# claude est interactif de bout en bout). Pas dans l ISO : le premier clic
# l installe (addition.sh --claude, en root) puis l ouvre, dans la meme
# fenetre. [2026-10-01] Plus de gnome-terminal.
set -u
exec python3 /opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Claude" -- bash -lc '
if ! command -v claude >/dev/null 2>&1; then
    ADD=/opt/GSM/osmo-operator/addition.sh
    if [ -x "$ADD" ]; then
        if [ "$(id -u)" -ne 0 ] && command -v pkexec >/dev/null 2>&1; then
            pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" "$ADD" --claude
        else
            "$ADD" --claude
        fi
    fi
fi
if command -v claude >/dev/null 2>&1; then exec claude; fi
echo "Claude non installe - lancez le supplement (addition.sh --claude)."
exit 1'


CLA
    chmod 755 /usr/local/bin/osmo-claude-anim
    if [ -f "$DIR/data/desktop/claude.desktop" ]; then
        install -m644 "$DIR/data/desktop/claude.desktop" /usr/share/applications/claude.desktop
        sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/claude.svg|" /usr/share/applications/claude.desktop
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        update-desktop-database /usr/share/applications 2>/dev/null || true
        mapfile -t _homes < <(_bureau_homes)
        _cposee=0
        for _h in "${_homes[@]}"; do
            for _dir in Bureau Desktop; do
                [ -d "$_h/$_dir" ] || continue
                cp -f /usr/share/applications/claude.desktop "$_h/$_dir/claude.desktop" 2>/dev/null || continue
                _trust_desktop "$_h/$_dir/claude.desktop" "$_h" "110,0"
                touch "$_h/$_dir" 2>/dev/null || true
                _cposee=1
            done
        done
        [ "$_cposee" = "1" ] \
            && echo -e "  ${GREEN}✓${NC} icone ${BOLD}Claude${NC} posee sur le bureau (en haut a gauche)" \
            || echo -e "  ${GREEN}✓${NC} icone ${BOLD}Claude${NC} dans le menu des applications"
    fi
fi

# ── Docker ──────────────────────────────────────────────────────────────────
# docker.io from the Ubuntu repos, NOT the get.docker.com script: that one adds
# a third-party repo and replaces containerd, which on a frozen image costs at
# the first apt-get upgrade. The repo version is enough: we only run our own
# containers.
if [ "$DO_DOCKER" = "1" ]; then
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker deja installe ($(docker --version 2>/dev/null | head -1))"
    else
        echo -e "  ${CYAN}→${NC} installation de docker.io ..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || { echo -e "  ${RED}✗ apt-get update a echoue - pas de reseau ?${NC}"
                            echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
                            exit 1; }
        apt-get install -y docker.io || { echo -e "  ${RED}✗ installation de docker.io echouee${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} docker.io installe"
    fi
    # docker compose build goes through Bake and warns if buildx is missing. Non-fatal.
    if ! docker buildx version >/dev/null 2>&1; then
        apt-get install -y docker-buildx >/dev/null 2>&1 \
            || apt-get install -y docker-buildx-plugin >/dev/null 2>&1 || true
    fi
    systemctl enable --now docker 2>/dev/null || true
    # The socket takes a moment to respond after a first start: without this
    # wait, the next `docker info` fails and the install looks broken.
    for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} demon docker actif" \
        || { echo -e "  ${RED}✗ le demon docker ne repond pas${NC} - voir : systemctl status docker"; exit 1; }
    _docker_groupe_session
fi

# ── Operator image ──────────────────────────────────────────────────────────
# Two paths to obtain osmocom-nitb:
#   1. docker pull ${HUB_IMAGE} && docker tag ... osmocom-nitb  (default)
#      The already-compiled Osmocom stack, published on the hub: the download
#      replaces the compilation. The tag gives the result the name that
#      start-docker.sh (Dockerfile.run: FROM osmocom-nitb) and start-nitb.sh expect.
#   2. build.sh --no-cache  (--build / --multi-build / "compile" case)
#      --no-cache: rebuild the image CLEAN. The docker cache could keep layers
#      from a half-compiled Osmocom stack and replay them identically, so a
#      broken build stayed broken every time. Force a rebuild.
# --build / --multi-build no longer compile locally: they pull from GHCR, the
# same image the CI publishes from the same Dockerfile. Both flags still mean
# "take the image of THIS repo", as opposed to a Hub image.
# A real local build stays available - it is the only path once the Dockerfile
# has been MODIFIED and no CI has published yet:
#     sudo OSMO_ADDITION_BUILD_LOCAL=1 ./addition.sh --multi-build
_build_image() {
    if [ "${OSMO_ADDITION_BUILD_LOCAL:-0}" != "1" ]; then
        echo -e "  ${CYAN}→${NC} image du depot : ${BOLD}docker pull ${HUB_IMAGE}${NC}"
        echo -e "      (build local : ${BOLD}OSMO_ADDITION_BUILD_LOCAL=1${NC}, plusieurs dizaines de minutes)"
        _pull_image
        return $?
    fi
    [ -x "$DIR/build.sh" ] || { echo -e "  ${RED}✗ build.sh introuvable dans $DIR${NC}"; return 1; }
    echo -e "  ${CYAN}→${NC} construction de l image : ${BOLD}${DIR}/build.sh --no-cache${NC}"
    echo -e "      compilation Osmocom - comptez plusieurs dizaines de minutes."
    "$DIR/build.sh" --no-cache || { echo -e "  ${RED}✗ ${DIR}/build.sh a echoue${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image operateur construite (${BASE_IMAGE})"
}
_pull_image() {
    echo -e "  ${CYAN}→${NC} telechargement de l image : ${BOLD}docker pull ${HUB_IMAGE}${NC}"
    echo -e "      ~11 Go - selon le debit, quelques minutes a une heure."
    # GHCR serves PUBLIC images without authentication. If the repo package is
    # private, a token is needed: docker login ghcr.io -u <account> (classic
    # token with read:packages). The message says so rather than leaving the
    # operator facing a "denied" without explanation.
    docker pull "$HUB_IMAGE" || {
        echo -e "  ${RED}✗ docker pull ${HUB_IMAGE} a echoue${NC} - reseau, image absente, ou paquet prive."
        case "$HUB_IMAGE" in ghcr.io/*)
            echo -e "    Paquet prive ? ${BOLD}docker login ghcr.io -u <compte>${NC} (jeton avec read:packages)" ;;
        esac
        echo -e "    Autre image : ${BOLD}HUB_IMAGE=<ref> $0 --multi${NC}"
        echo -e "    Compiler sur place : ${BOLD}OSMO_ADDITION_BUILD_LOCAL=1 $0 --multi-build${NC}"
        return 1; }
    # norf_gsm is published from osmocom-run (Dockerfile.run already applied):
    # tag it osmocom-run directly, with no derivation.
    local _tag="$BASE_IMAGE"; [ "${HUB_IS_RUN:-0}" = 1 ] && _tag="$MULTI_IMAGE"
    docker tag "$HUB_IMAGE" "$_tag" || { echo -e "  ${RED}✗ docker tag ${HUB_IMAGE} ${_tag} a echoue${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image operateur tiree et taguee ${_tag}"
}
# The image the multi-operator runs is osmocom-run, NOT osmocom-nitb. Neither
# the pull nor build.sh produces it: Dockerfile.run (FROM osmocom-nitb) derives
# it in a few seconds. start-multi.sh probes osmocom-run and comes back here if
# it is missing. Same command as start-docker.sh (build_run_image, quick mode).
_derive_run_image() {
    echo -e "  ${CYAN}→${NC} derivation de l image d execution : ${BOLD}docker build -f Dockerfile.run -t ${MULTI_IMAGE}${NC}"
    ( cd "$DIR" && docker build --build-arg QEMU_CACHE_BUST=$(date +%s) \
                       -f Dockerfile.run -t "$MULTI_IMAGE" . ) \
        || { echo -e "  ${RED}✗ derivation de ${MULTI_IMAGE} echouee${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image d execution prete (${MULTI_IMAGE})"
}
# norf_gsm (the "hub" choice, or HUB_IMAGE set by the installer) IS osmocom-run.
case "$HUB_IMAGE" in *norf_gsm*) HUB_IS_RUN=1 ;; esac
if [ "$DO_IMAGE" = "1" ]; then
    if [ "$DO_BUILD" = "1" ]; then
        _build_image || exit 1
        _derive_run_image || exit 1
    elif docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} image operateur deja presente (${MULTI_IMAGE})"
    elif [ "${HUB_IS_RUN:-0}" != 1 ] && docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} image de base deja presente (${BASE_IMAGE})"
        _derive_run_image || exit 1
    else
        _pull_image || exit 1
        [ "${HUB_IS_RUN:-0}" = 1 ] || _derive_run_image || exit 1
    fi
fi

# ── Multi-operator topology ─────────────────────────────────────────────────
# Written HERE, once, and read back by start-multi.sh. It is not recomputed on
# both sides: two twin formulas always diverge in the end.
#
# The SS7 plan, as start-interstp.sh defines it:
#     PC   = 1.<node><op>.<role>       role 1=MSC 2=STP 3=BSC
#     RCTX = node*1000 + op*100 + 50
# On a single machine node is 1, so PC = 1.<op>.<role>.
#
#   op 1  NATIVE  - PC 1.1.2, that of start-native.sh, left as is
#   op 2  DOCKER  - PC 1.2.2, backbone 172.20.0.12
#   op 3  DOCKER  - PC 1.3.2, backbone 172.20.0.13
#
# The containers start at index 2, and this is controllable. OP_ID_BASE=2
# (start-docker.sh) starts the containers at index 2 and leaves index 1 to the
# native operator; name, backbone, point code, RCTX, private segment and
# published ports all follow. Otherwise osmo-operator-1 would get point code
# 1.1.2, the native one's - two devices at the same SS7 address, i.e. wrong
# routing (checks/wan_ss7_check.sh).
# The native operator reaches the hub via the bridge gateway: the host reaches
# 172.20.0.10 directly, with no NAT or route to add.
if [ "$DO_MULTI" = "1" ]; then
    install -d "$(dirname "$MULTI_CONF")"
    cat > "$MULTI_CONF" <<CONF
# osmo-multi.conf - topologie multi-operateur, ecrite par addition.sh.
# Relue par start-multi.sh. Ne pas editer a la main sans relire les deux.
MULTI_NODE=1
MULTI_HUB_NAME=osmo-inter-stp
MULTI_HUB_IP=172.20.0.10
MULTI_HUB_PC=0.0.0
MULTI_M3UA_PORT=2908
MULTI_NET_NAME=osmo-ss7
MULTI_NET_SUBNET=172.20.0.0/24
MULTI_NET_GW=172.20.0.1
MULTI_IMAGE=osmocom-run
# operateurs : "index:mode:backbone_ip:point_code:rctx"
MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:1.2.2:250 3:docker:172.20.0.13:1.3.2:350"
CONF
    echo -e "  ${GREEN}✓${NC} topologie SS7 ecrite : ${CYAN}${MULTI_CONF}${NC}"
    echo -e "      op1 ${BOLD}natif${NC} (1.1.2) + op2/op3 ${BOLD}docker${NC} (1.2.2 / 1.3.2) → hub 172.20.0.10"

    # ── L ICONE MULTI-OPERATOR : POSEE ICI, A LA FIN, ET PAS AVANT ────────────
    # L antenne bleue lance start-multi.sh, qui suppose docker, l image et la
    # topologie ci-dessus. La poser au build ISO (comme le telephone ou le
    # tutoriel) la faisait apparaitre sur le bureau des le premier boot, AVANT
    # que ce supplement n existe : un clic ne donnait rien. On la pose donc
    # seulement maintenant, une fois l install SS7 reellement faite - build-iso
    # et install_modules/80-bureau.sh ne la posent plus.
    _ico_dir=/usr/share/osmo-operator/icons
    _svg="$DIR/data/osmo-multi.svg"
    _dsk="$DIR/data/desktop/osmo-multi.desktop"

    # ── L UNITE D ABORD, L ICONE ENSUITE ────────────────────────────────────
    # [2026-09-04] L icone lance desormais `systemctl start osmo-multi.service`
    # et plus start-multi.sh : elle ne vaut donc que si l unite EXISTE. Sur une
    # ISO elle est posee au build (iso_modules/82-services.sh) ; sur une machine
    # ou ce depot a ete deroule a la main, non. On la pose ici, avec l icone qui
    # en depend - les deux vont ensemble ou ne vont pas du tout.
    #
    # POURQUOI PLUS DE TERMINAL. start-multi.sh se RELANCE lui-meme dans un
    # gnome-terminal quand il detecte qu il n en a pas (OSMO_MULTI_TERM) : un
    # clic sur l icone ouvrait donc une fenetre qui vivait le temps du
    # lancement, et dont la sortie etait perdue a la fermeture. Quand un
    # operateur ne demarrait pas, il n en restait aucune trace. L unite, elle,
    # pose OSMO_NO_TERM=1 : aucune fenetre, tout dans le journal
    # (`journalctl -u osmo-multi`), un etat lisible et un arret propre - comme
    # le mono-operateur, qui est une unite depuis le debut.
    for _u in osmo-banc osmo-multi; do
        [ -f "$DIR/services/$_u.service" ] || continue
        install -m644 "$DIR/services/$_u.service" "/etc/systemd/system/$_u.service"
    done
    systemctl daemon-reload 2>/dev/null || true
    # ── POSEES, PAS ACTIVEES ────────────────────────────────────────────────
    # [2026-09-05] `systemctl enable osmo-multi` etait fait ICI, et l ISO
    # activait osmo-banc de son cote : le supplement SS7 suffisait donc a ce
    # que la machine monte, a chaque demarrage, la pile radio ET les conteneurs
    # du multi - avant meme l ouverture de session, sur une configuration que
    # personne n avait choisie. Un banc se DEMARRE :
    #   systemctl start osmo-banc | osmo-multi     une session (ou l icone)
    #   systemctl enable --now osmo-multi          a chaque demarrage
    # OSMO_MULTI_ENABLE=1 ./addition.sh retablit l activation automatique.
    if [ -f /etc/systemd/system/osmo-multi.service ]; then
        if [ "${OSMO_MULTI_ENABLE:-0}" = "1" ]; then
            systemctl enable osmo-multi.service >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓${NC} ${BOLD}osmo-multi.service${NC} installe et active au demarrage (OSMO_MULTI_ENABLE=1)" \
                || echo -e "  ${YELLOW}!${NC} osmo-multi.service installe, activation KO (systemctl enable osmo-multi)"
        else
            systemctl disable osmo-multi.service >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓${NC} ${BOLD}osmo-multi.service${NC} installe, ${BOLD}non active${NC} au demarrage"
            echo -e "      ${CYAN}systemctl start osmo-multi${NC} pour une session · ${CYAN}systemctl enable --now osmo-multi${NC} a chaque boot"
        fi
    fi

    if [ -f "$_dsk" ]; then
        install -d "$_ico_dir" /usr/share/icons/hicolor/scalable/apps /usr/share/applications
        # SVG en CHEMIN ABSOLU dans Icon= (voir build-iso.sh) : un nom de theme
        # arrive apres icon-theme.cache s affiche en page blanche.
        if [ -f "$_svg" ]; then
            install -m644 "$_svg" "$_ico_dir/osmo-multi.svg"
            install -m644 "$_svg" /usr/share/icons/hicolor/scalable/apps/osmo-multi.svg
        fi
        install -m644 "$_dsk" /usr/share/applications/osmo-multi.desktop
        # Icon= suit l arbre reel. Exec=, lui, ne nomme plus l arbre : il appelle
        # `systemctl start osmo-multi.service`, et c est l UNITE qui porte le
        # chemin (posee juste au-dessus depuis $DIR/services/). Le sed sur Exec=
        # reste, sans effet sur la ligne actuelle, pour un .desktop ancien qui
        # nommerait encore start-multi.sh en dur.
        sed -i -e "s|^Exec=/opt/GSM/osmo-operator/|Exec=$DIR/|" \
               -e "s|^Icon=.*|Icon=$_ico_dir/osmo-multi.svg|" \
               /usr/share/applications/osmo-multi.desktop

        # Sur les bureaux de root et de l utilisateur sudo, en Bureau/ et
        # Desktop/. metadata::trusted pour que DING l affiche sans pastille ;
        # osmo-trust-desktop (au login) la repositionne et la trust aussi.
        mapfile -t _homes < <(_bureau_homes)
        _posee=0
        for _h in "${_homes[@]}"; do
            for _dir in Bureau Desktop; do
                [ -d "$_h/$_dir" ] || continue
                cp -f /usr/share/applications/osmo-multi.desktop "$_h/$_dir/osmo-multi.desktop" 2>/dev/null || continue
                _trust_desktop "$_h/$_dir/osmo-multi.desktop" "$_h"
                touch "$_h/$_dir" 2>/dev/null || true
                _posee=1
            done
        done
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
        [ "$_posee" = "1" ] \
            && echo -e "  ${GREEN}✓${NC} icone ${BOLD}multi-operator${NC} (antenne) posee sur le bureau" \
            || echo -e "  ${GREEN}✓${NC} icone ${BOLD}multi-operator${NC} dans le menu des applications"
    fi

    # ── LE BANC MULTI DEMARRE MAINTENANT : LES CONTENEURS EXISTENT EN SORTANT ──
    # [2026-10-01] L en-tete promettait « start-multi.sh demarre juste apres »
    # et RIEN ne le faisait : le supplement sortait avec une topologie, une
    # unite et une icone, mais aucun conteneur - osmo-operator-2 et -3
    # n existaient qu au premier clic sur l antenne, et un operateur qui venait
    # d « installer le multi » ne voyait rien dans docker ps. On termine donc
    # par UNE session du banc multi : `systemctl start`, pas `enable` -
    # l activation a chaque demarrage reste le geste de l operateur
    # (00-options.sh, 2026-09-14). OSMO_MULTI_START=0 pour poser sans lancer.
    # Le journal de l unite defile ici pendant le demarrage : c est lui qui
    # montre les conteneurs qui montent, et l erreur s il y en a une.
    #
    # [2026-10-01] PAR launch.sh --multi, LE MEME CHEMIN QUE L ICONE. Ce bloc
    # faisait son propre `systemctl start --no-block` : un deuxieme lanceur,
    # avec ses propres tests - et pas ceux de l icone. launch.sh --multi
    # verifie l unite, start-multi.sh et la topologie, nomme ce qui manque,
    # refuse un banc deja en route, demarre l unite (start, pas restart) et
    # annonce le resultat ; c est aussi ce que fait « run multi » de l encart
    # du bureau (tools/osmo-launcher.py). Ce que le supplement vient de poser
    # est donc teste par ce qui s en servira. Le natif que start-multi.sh
    # lance au passage (osmo-banc) part en DSP : c est le defaut de
    # start-native.sh depuis ce jour.
    if [ "${OSMO_MULTI_START:-1}" = "1" ] && [ -f /etc/systemd/system/osmo-multi.service ]; then
        echo -e "  ${CYAN}→${NC} demarrage du banc multi-operateur (${BOLD}launch.sh --multi${NC}, comme l icone) - comptez plusieurs minutes ..."
        journalctl -u osmo-multi -f -n 0 --no-pager -o cat 2>/dev/null &
        _jpid=$!
        # OSMO_LAUNCH_NO_SERVICE n a pas de sens ici (--multi est traite en
        # tete de launch.sh) ; on garde le terminal courant pour sa sortie.
        if "$DIR/launch.sh" --multi; then
            sleep 1; kill "$_jpid" 2>/dev/null; wait "$_jpid" 2>/dev/null
            echo -e "  ${GREEN}✓${NC} banc multi-operateur en service - conteneurs :"
            docker ps --format '      {{.Names}}  {{.Status}}' 2>/dev/null | grep -E 'osmo-operator-|osmo-inter-stp' \
                || echo -e "      ${YELLOW}!${NC} aucun conteneur osmo-operator-N visible (docker ps)"
        else
            sleep 1; kill "$_jpid" 2>/dev/null; wait "$_jpid" 2>/dev/null
            echo -e "  ${RED}✗${NC} launch.sh --multi n a pas abouti - ${BOLD}journalctl -u osmo-multi -n 80${NC}"
            echo -e "      a la main : ${BOLD}$DIR/launch.sh --multi${NC} (ou l icone multi-operator)"
        fi
    fi
fi

# ── LA SIM DU BANC (supplement independant) ──────────────────────────────────
# Lecteur PC/SC (pcscd, CCID : HID Omnikey), softSIM (le serveur SAP, Ruby) et
# pySim (lire / programmer une sysmoISIM). Meme code que l ISO (80-chroot.sh) :
# tools/osmo-sim-install.sh, qu on source ici. Ensuite : tools/osmo-sim.sh.
if [ "$DO_SIM" = "1" ]; then
    echo -e "${BOLD}== SIM : lecteur PC/SC, softSIM, pySim ==${NC}"
    if [ -f "$DIR/tools/osmo-sim-install.sh" ]; then
        # shellcheck source=tools/osmo-sim-install.sh
        . "$DIR/tools/osmo-sim-install.sh"
        REPO="$DIR" osmo_sim_install
    else
        echo -e "  ${YELLOW}!${NC} tools/osmo-sim-install.sh introuvable"
    fi
fi

# ── FIRMWARES TELEPHONE (supplement independant) ─────────────────────────────
# gnuarm, Magnetite C139, osmocom-bb-trx, Fernvale, SIMCom : tools/osmo-firmwares-install.sh.
# osmocom-bb-trx tire une image Docker : sans moteur, --trx ne pose que le firmware.
if [ "$DO_GNUARM$DO_MAGNETITE$DO_TRX$DO_CALFW$DO_FERNVALE$DO_SIMCOM" != "000000" ]; then
    if [ -f "$DIR/tools/osmo-firmwares-install.sh" ]; then
        # shellcheck source=tools/osmo-firmwares-install.sh
        . "$DIR/tools/osmo-firmwares-install.sh"
        export REPO="$DIR"
        [ "$DO_GNUARM" = "1" ]    && { osmo_gnuarm_install    || true; }
        [ "$DO_MAGNETITE" = "1" ] && { osmo_magnetite_install || true; }
        [ "$DO_TRX" = "1" ]       && { osmo_trx_install       || true; }
        [ "$DO_CALFW" = "1" ]     && { osmo_calypso_fw_install || true; }
        [ "$DO_FERNVALE" = "1" ]  && { osmo_fernvale_install  || true; }
        [ "$DO_SIMCOM" = "1" ]    && { osmo_simcom_install    || true; }
        echo -e "  ${CYAN}→${NC} journaux : ${BOLD}${OSMO_FW_LOG:-/var/log/osmo-firmwares}/${NC}"
    else
        echo -e "  ${YELLOW}!${NC} tools/osmo-firmwares-install.sh introuvable"
    fi
fi

# ── JEUX + MEDIA (supplement independant) ────────────────────────────────────
# Doom / Quake III / Kodi / YouTube+uBlock / Wireshark(root) / Linphone,
# ranges dans les dossiers Jeux / Media / Telephone / Outils et lancables depuis
# l encart du bureau. La logique est partagee avec l ISO (le natif) :
# tools/osmo-extras-install.sh, qu on source ici.
if [ "$DO_EXTRAS" = "1" ]; then
    echo -e "${BOLD}== Jeux + media ==${NC}"
    if [ -f "$DIR/tools/osmo-extras-install.sh" ]; then
        # shellcheck source=tools/osmo-extras-install.sh
        . "$DIR/tools/osmo-extras-install.sh"
        osmo_extras_install
    else
        echo -e "  ${YELLOW}!${NC} tools/osmo-extras-install.sh introuvable"
    fi
fi

# ── LA 4G (srsRAN ZeroMQ + Open5GS) ET L UI SMARTPHONE (postmarketOS) ────────
# [2026-09-08] Miroir aux trois chemins (addition.sh, update.sh, le build ISO :
# iso_modules/88-lte-pmos.sh). Tout est ecrit une fois dans
# tools/osmo-lte-install.sh (paquets, .deb du cache, configs du depot,
# lanceurs osmo-lte / osmo-epc ; --all compile dans /opt/LTE si les binaires
# manquent et qu aucun .deb n est la) et tools/osmo-pmos-install.sh
# (/opt/user_interface/pmos : scripts, pmbootstrap patche, gabarit ; kernel/ :
# le .deb du noyau PPP, de /var/cache/osmo-debs ou de GitHub). Non fatal.
# [2026-10-24] SAUF QUAND CLAUDE EST SEUL DEMANDE. « addition.sh --claude » (et
# l icone Claude, qui l appelle au premier clic) ne doit installer que Claude :
# ce bloc, lui, passait a chaque appel et lancait la 4G et postmarketOS
# (paquets, eventuelle compilation de /opt/LTE) pour un simple CLI.
if [ "$DO_CLAUDE" = "1" ] && [ "$DO_DOCKER$DO_IMAGE$DO_MULTI$DO_OPENCL$DO_EXTRAS$DO_SIM" = "000000" ] \
   && [ "$DO_GNUARM$DO_MAGNETITE$DO_TRX$DO_CALFW$DO_FERNVALE$DO_SIMCOM" = "000000" ]; then
    :
else
echo -e "${BOLD}== La 4G et le telephone ==${NC}"
if [ -f "$DIR/tools/osmo-lte-install.sh" ]; then
    # shellcheck source=tools/osmo-lte-install.sh
    . "$DIR/tools/osmo-lte-install.sh"
    osmo_lte_install --all || true
else
    echo -e "  ${YELLOW}!${NC} tools/osmo-lte-install.sh introuvable"
fi
if [ -f "$DIR/tools/osmo-pmos-install.sh" ]; then
    # shellcheck source=tools/osmo-pmos-install.sh
    . "$DIR/tools/osmo-pmos-install.sh"
    osmo_pmos_install || true
else
    echo -e "  ${YELLOW}!${NC} tools/osmo-pmos-install.sh introuvable"
fi
fi

echo
etat
echo
[ "$DO_MULTI" = "1" ] && \
    echo -e "  ${CYAN}→${NC} lancer : ${BOLD}sudo $DIR/launch/start-multi.sh${NC}  (ou l antenne bleue du bureau)"
[ "$DO_OPENCL" = "1" ] && \
    echo -e "  ${CYAN}→${NC} verifier OpenCL : ${BOLD}clinfo${NC}"
[ "$DO_EXTRAS" = "1" ] && \
    echo -e "  ${CYAN}→${NC} jeux + media : dossiers ${BOLD}Jeux / Media / Telephone / Outils${NC} et encart du bureau"
exit 0
