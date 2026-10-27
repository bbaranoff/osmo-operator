#!/bin/bash
# =============================================================================
# start-multi.sh - MULTI-OPERATOR LAB: native + docker, linked over SS7
#
#   op 1  NATIVE  already running (start-native.sh)  PC 1.1.2
#   op 2  DOCKER  container                          PC 1.2.2   172.20.0.12
#   op 3  DOCKER  container                          PC 1.3.2   172.20.0.13
#   hub   DOCKER  inter-STP                          PC 0.0.0   172.20.0.10
#                                                    M3UA/SCTP 2908
#
# This script reimplements nothing. start-docker.sh already starts operator
# containers, sets up the hub (--hub-ip) and can DECLARE an operator without
# starting a container (--operator IP:PREFIX), which is the case of the
# already-running native operator. start-multi.sh only checks prerequisites,
# translates the topology into options and delegates.
#
# The topology comes from addition.sh: /etc/osmocom/osmo-multi.conf.
#
# Environment:
#   OSMO_MULTI_RESTART_NATIF=1  same as --restart-natif
#   OSMO_NO_TERM=1              never open a terminal or browser (systemd)
#
# Usage:
#   sudo ./launch/start-multi.sh              start the multi-operator lab
#   sudo ./launch/start-multi.sh --status     state of containers and hub
#   sudo ./launch/start-multi.sh --stop       stop the containers (native stays)
#   sudo ./launch/start-multi.sh --dry-run    print the command without running it
#   sudo ./launch/start-multi.sh --align      align the native SS7 identity only, start nothing
#   sudo ./launch/start-multi.sh --restart-natif
#                                      also stop and restart the native 2G
#                                      (by default it is KEPT if running and
#                                      STARTED if stopped)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Repository root (this script lives in launch/).
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"

# ── Native subscribers come from coeur.env, not ~/.bashrc ──────────────────
# Load N_MS and OPERATOR_ID from /etc/osmocom/coeur.env so a launch from the
# desktop icon or a systemd unit gets the right subscriber count (as
# start-native.sh does); ":=" lets a value already in the environment win.
if [ -f "${OSMOCOM_CFG:-/etc/osmocom}/coeur.env" ]; then
    set -a; . "${OSMOCOM_CFG:-/etc/osmocom}/coeur.env"; set +a
fi
ACTION="start"
# The native 2G is kept if running and started if missing. --restart-natif
# (or OSMO_MULTI_RESTART_NATIF=1) forces stop + restart.
RESTART_NATIF="${OSMO_MULTI_RESTART_NATIF:-0}"
for a in "$@"; do
    case "$a" in
        --status)  ACTION="status" ;;
        --stop)    ACTION="stop" ;;
        --dry-run) ACTION="dry" ;;
        # --align: ONLY align the native SS7 identity (aligner_natif), then exit.
        # The test bench (tests/modules/00-demarrage.sh) calls it BEFORE
        # start-native.sh so the native stack starts already aligned.
        --align)   ACTION="align" ;;
        --restart-natif) RESTART_NATIF=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    esac
done

# ── Launched from an icon: terminal and privileges ─────────────────────────
# The .desktop entry uses Terminal=false, so without this preamble a
# double-click would show nothing (e.g. the "root required" refusal).
# Test for a TTY, not $DISPLAY: that is the real difference between a manual
# launch and an icon launch.
# ONLY for starting the lab. --status, --dry-run and --help are read-only:
# re-running them in a graphical terminal would open a window on every call
# from a script or pipe, and their output would not reach the caller.
_multi_readonly=0
case " $* " in
    *" --status "*|*" --dry-run "*|*" --align "*|*" -h "*|*" --help "*) _multi_readonly=1 ;;
esac

# Check stdin AND stdout: a run from a real terminal with stdin redirected
# must not be mistaken for a double-click.
_multi_besoin=0
if [ "$_multi_readonly" = "0" ]; then
    { [ ! -t 0 ] || [ ! -t 1 ]; } && _multi_besoin=1
fi
# OSMO_NO_TERM=1: launched by systemd (osmo-multi.service), nobody is in
# front of a screen - open nothing, output goes to the journal.
if [ "$_multi_besoin" = "1" ] && [ "${OSMO_MULTI_TERM:-0}" != "1" ] && [ "${OSMO_NO_TERM:-0}" != "1" ]; then
    export OSMO_MULTI_TERM=1
    for _t in gnome-terminal xfce4-terminal konsole xterm; do
        command -v "$_t" >/dev/null 2>&1 || continue
        case "$_t" in
            gnome-terminal) exec "$_t" --title="osmo-operator multi-operateur" -- "$0" "$@" ;;
            *)              exec "$_t" -T "osmo-operator multi-operateur" -e "$0" "$@" ;;
        esac
    done
fi

# The flag only prevents a relaunch loop. It is REMOVED from the
# environment so it does not leak into start-docker.sh, the native shortcut
# or launch.sh. The value stays in a shell variable, which decides whether
# to keep the window open at the end.
_multi_own_window=0
[ "${OSMO_MULTI_TERM:-0}" = "1" ] && _multi_own_window=1
unset OSMO_MULTI_TERM

# Same for root: a read-only action must not ask for a password.
if [ "$_multi_readonly" = "0" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
                exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
                     OSMO_MULTI_TERM="$_multi_own_window" "$0" "$@"
            fi
            command -v sudo >/dev/null 2>&1 && exec sudo -E "$0" "$@"
        fi
fi

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - banc MULTI-OPERATEUR (SS7)         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── PREFLIGHT ───────────────────────────────────────────────────────────────
# Docker is NOT in the ISO (see addition.sh): its absence is NORMAL on the
# first launch. Say so and point to the add-on instead of letting docker
# answer "command not found".
manque() {
    echo -e "  ${RED}✗ $1${NC}"
    echo -e "    ${CYAN}→ sudo ${DIR}/addition.sh${NC}  (ou l icone ${BOLD}Supplements${NC} du bureau)"
    exit 1
}
command -v docker >/dev/null 2>&1 || manque "docker n est pas installe"
docker info >/dev/null 2>&1        || manque "le demon docker ne repond pas"

if [ ! -f "$MULTI_CONF" ]; then
    manque "topologie absente : $MULTI_CONF"
fi
# shellcheck disable=SC1090
. "$MULTI_CONF"

: "${MULTI_HUB_IP:=172.20.0.10}"
: "${MULTI_M3UA_PORT:=2908}"
: "${MULTI_OPS:=}"
: "${MULTI_IMAGE:=osmocom-run}"

# ── Read the native stack instead of assuming ──────────────────────────────
# The topology written by addition.sh says what the native operator SHOULD
# be; these two functions report what it IS (e.g. a running process may
# carry a container's point code).
#
# The point code depends on the chosen plan, and both exist:
#   LOCAL plan (set-node-id.sh --local) : 1.<op>.<role>        - one machine
#   WAN plan   (default)                : 1.<node><op>.<role>  - several
# On a single-machine lab the local plan applies, but the config may have
# been set otherwise: READ it, do not recompute it.
natif_pc() {
    awk '/^[[:space:]]*point-code[[:space:]]/{print $2; exit}' \
        /etc/osmocom/osmo-stp.cfg 2>/dev/null
}

# Address the native stack uses towards the hub: the local-ip of its ASP
# asp-to-inter. It must exist on the host - an unbindable local-ip is an ASP
# that never comes up, without a clear message.
natif_asp_ip() {
    local ip
    ip="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{a=1; next}
               a && /^[[:space:]]*local-ip[[:space:]]/{print $2; exit}' \
          /etc/osmocom/osmo-stp.cfg 2>/dev/null)"
    [ -n "$ip" ] || return 0
    # Check that the address exists HERE. An address missing from the machine
    # means an ASP that will never come up; show it in the column instead of
    # suggesting a healthy topology.
    if ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
         | grep -qx "$ip"; then
        printf '%s\n' "$ip"
    else
        printf '%s(absente!)\n' "$ip"
    fi
}

# ── A host process, not a container's ──────────────────────────────────────
# The host sees ALL processes, including those of containers, so a plain
# pgrep would mistake any container stack for the native one. The
# discriminator is the PID NAMESPACE: a container has its own, the host
# keeps its init's. More reliable than the cgroup, which depends on
# --cgroupns.
#
# `pgrep -x`, NOT `pgrep -f`: match the process NAME, not its command line
# (which would match e.g. `tail -F .../osmo-bsc.log`, an editor or the
# calling shell). An exact name also makes excluding our own PID
# unnecessary.
_ns_hote="$(readlink /proc/1/ns/pid 2>/dev/null)"
_est_natif() {          # $@ = noms EXACTS ; vrai si l un tourne hors conteneur
    local n p
    for n in "$@"; do
        for p in $(pgrep -x "$n" 2>/dev/null); do
            [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$_ns_hote" ] && return 0
        done
    done
    return 1
}

# ── ETAT ────────────────────────────────────────────────────────────────────
etat() {
    local spec idx mode ip pc _r
    echo -e "  ${BOLD}Topologie${NC} ($MULTI_CONF)"
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip pc _rctx <<< "$spec"
        if [ "$mode" = "native" ]; then ip="$(natif_asp_ip)"; fi
        printf '    op %-2s %-7s %-13s PC %-8s ' "$idx" "$mode" "${ip:-(hote)}" "$pc"
        if [ "$mode" = "native" ]; then
            if _est_natif osmo-bsc asterisk \
               || systemctl is-active --quiet asterisk 2>/dev/null; then
                _r="$(natif_pc)"
                if [ -n "$_r" ] && [ "$_r" != "$pc" ]; then
                    echo -e "${GREEN}actif${NC} ${YELLOW}(PC reel ${_r})${NC}"
                else
                    echo -e "${GREEN}actif${NC}"
                fi
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        else
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "osmo-operator-${idx}"; then
                echo -e "${GREEN}actif${NC}"
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        fi
    done
    printf '    hub  %-7s %-13s PC %-8s ' "docker" "$MULTI_HUB_IP" "${MULTI_HUB_PC:-0.0.0}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${MULTI_HUB_NAME:-osmo-inter-stp}"; then
        echo -e "${GREEN}actif${NC}"
    else
        echo -e "${YELLOW}arrete${NC}"
    fi
}

case "$ACTION" in
  status) etat; exit 0 ;;
  stop)
        for spec in $MULTI_OPS; do
            IFS=: read -r idx mode _ <<< "$spec"
            [ "$mode" = "docker" ] || continue
            docker rm -f "osmo-operator-${idx}" >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓${NC} osmo-operator-${idx} arrete"
        done
        docker rm -f "${MULTI_HUB_NAME:-osmo-inter-stp}" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} hub arrete"
        echo -e "  ${CYAN}i${NC} l operateur NATIF n est pas touche - ${BOLD}sudo ${DIR}/start-native.sh stop${NC} pour lui."
        exit 0 ;;
esac

# ── The image ───────────────────────────────────────────────────────────────
# Image name: osmocom-run, NOT "osmo-operator" (the repository name).
# build.sh produces osmocom-nitb (Dockerfile, ~11 GB), then Dockerfile.run
# derives osmocom-run from it; start-docker.sh runs osmocom-run.
# If missing, pull it from norf_gsm on Docker Hub first (published with
# Dockerfile.run already applied). Deriving it locally from osmocom-nitb
# (a few seconds) is the fallback when there is no network or Hub.
: "${MULTI_HUB_RUN_IMAGE:=bastienbaranoff/norf_gsm:latest}"
if [ "$ACTION" != align ] && ! docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
    echo -e "  ${CYAN}→${NC} image '$MULTI_IMAGE' absente : docker pull ${MULTI_HUB_RUN_IMAGE}"
    docker pull "$MULTI_HUB_RUN_IMAGE" && docker tag "$MULTI_HUB_RUN_IMAGE" "$MULTI_IMAGE" \
        || echo -e "  ${YELLOW}!${NC} pull ${MULTI_HUB_RUN_IMAGE} impossible - repli sur la derivation locale"
fi
if [ "$ACTION" != align ] && ! docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
    if docker image inspect osmocom-nitb >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} image '$MULTI_IMAGE' absente, base osmocom-nitb presente : derivation (Dockerfile.run)"
        ( cd "$DIR" && docker build --build-arg QEMU_CACHE_BUST=$(date +%s) \
                           -f Dockerfile.run -t "$MULTI_IMAGE" . ) \
            || manque "derivation de l image '$MULTI_IMAGE' echouee"
    else
        manque "image '$MULTI_IMAGE' absente"
    fi
fi

# ── Native-to-hub link ─────────────────────────────────────────────────────
# The native /etc/osmocom/osmo-stp.cfg declares
#       asp asp-to-inter 2908 2910 m3ua
#        remote-ip 127.0.0.1
# start-docker.sh publishes the hub's 2908 in SCTP on loopback
# (docker run -p 127.0.0.1:2908:2908/sctp), so this remote-ip is valid
# without touching the regenerated configs. Pointing the native ASP at
# 172.20.0.10 instead would break whenever the docker bridge is down.

# ── How many containers ────────────────────────────────────────────────────
# Those marked "docker" in the table, not a fixed count: the topology is
# the only source.
N_DOCKER=0
for spec in $MULTI_OPS; do
    IFS=: read -r idx mode _ <<< "$spec"
    [ "$mode" = "docker" ] && N_DOCKER=$((N_DOCKER + 1))
done
[ "$N_DOCKER" -ge 1 ] || { echo -e "  ${RED}✗ aucun operateur docker dans la topologie${NC}"; exit 1; }

# NO --wan here: --wan is the MULTI-MACHINE mode (reads/writes
# /etc/osmo-wan.conf, renumbers point codes as 1.<node><op>.<role>, expects
# a hub at a routable address). On ONE machine the default already points
# each operator's ASP at the local hub 172.20.0.10 with a catch-all
# "route 0.0.0 0.0.0 -> as-inter" (see checks/wan_ss7_check.sh).
#
# Environment passed to start-docker.sh:
#   WAN_NODE_ID          node number (MCC), from the topology (MULTI_NODE).
#   OSMO_QUICK=1         reuse the docker cache (no --no-cache rebuild).
#   OSMO_NO_BUILD=1      image already checked/derived above; do not rebuild.
#   OSMO_NONINTERACTIVE=1  whiptail dialogs return their default instead of
#                        waiting (nobody sees them after an icon click).
#   HANDOFF_MODE=faketrx-qemu  mixed radio: one faketrx + one QEMU Calypso
#                        per operator, same setup as the native stack.
#   OSMO_SKIP_CHECKS=1   skip start-docker.sh's final checks; verifier()
#                        below runs them with the topology.
#   OP_ID_BASE=2         containers take ranks 2 and up; 1 is the native.
#   OSMO_NO_ATTACH=1     do not attach to a container's tmux; return so
#                        verifier() can run.
# --operators: the explicit start-docker.sh flag (preferred over
# OPERATOR_COUNT_HINT); it is parsed last, wins, and shows the intent in
# the printed command.
CMD=(env "WAN_NODE_ID=${MULTI_NODE:-1}" "OSMO_QUICK=1" "OSMO_NO_BUILD=1" "OSMO_NONINTERACTIVE=1" "HANDOFF_MODE=faketrx-qemu" "OSMO_SKIP_CHECKS=1"
     "OP_ID_BASE=2" "OSMO_NO_ATTACH=1"
     "$DIR/launch/start-docker.sh" virtual --operators "$N_DOCKER")

echo -e "  ${BOLD}Topologie${NC} : ${N_DOCKER} conteneur(s) + 1 natif + hub ${MULTI_HUB_IP}"
echo -e "  ${CYAN}→${NC} ${CMD[*]}"
echo

if [ "$ACTION" = "dry" ]; then
    echo -e "  ${YELLOW}--dry-run : rien n a ete lance.${NC}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── Enter the repository before calling start-docker.sh ───────────────────
# start-docker.sh calls its helpers by RELATIVE path (./helpers/prepare_host.sh);
# an icon launch starts in $HOME.
cd "$DIR" || { echo -e "${RED}Impossible d entrer dans $DIR${NC}"; exit 1; }

# ── Align the native SS7 identity before starting ─────────────────────────
# start-docker.sh numbers ITS containers 1..N: with 2 containers it produces
# point codes 1.1.2 and 1.2.2. A native stack left at its default also
# uses 1.1.2 - two devices with the same SS7 address.
#
# So the native stack is repointed to the rank given by the topology, BEFORE
# starting the containers. Two flags matter:
#   --local   single-machine plan, MID=<op> -> 1.<op>.<role>. WITHOUT it,
#             set-node-id.sh uses the WAN plan (MID=<node><op>) and yields
#             1.13.2 instead of 1.3.2.
#   --hub-ip  otherwise the ASP is repointed to 192.168.1.49, the default
#             WAN hub, which does not exist here.
# ── The native identity is more than the point code ───────────────────────
# set-node-id.sh only changes point codes. start-native.sh derives the rest
# of its operator from OPERATOR_ID (/etc/osmocom/coeur.env):
#     MS_OP_ID  = OPERATOR_ID
#     ms_imsi() = MCC MNC <op, 4 digits> <ms, 6 digits>  -> IMSI
#     MSISDN    = 100<op><ms>
#     MS_ARFCN1 = 512 + MS_OP_ID * 2                     -> ARFCN
# A native stack realigned to operator 3 but left at OPERATOR_ID=1 would
# share subscribers (MSISDN, IMSI) and ARFCN with container osmo-operator-1.
_aligner_coeur_env() {
    local idx="$1" f="/etc/osmocom/coeur.env"
    [ -f "$f" ] || return 0
    if grep -qE '^[[:space:]]*:[[:space:]]*"\$\{OPERATOR_ID:=' "$f"; then
        sed -i -E "s|^([[:space:]]*:[[:space:]]*\"\\\$\\{OPERATOR_ID:=)[0-9]+(\\}\")|\\1${idx}\\2|" "$f"
        grep -qE "OPERATOR_ID:=${idx}\\}" "$f" \
            || echo -e "  ${GREEN}✓${NC} coeur.env : OPERATOR_ID=${idx} (IMSI, MSISDN et ARFCN du natif suivent)"
    else
        echo ": \"\${OPERATOR_ID:=${idx}}\"" >> "$f"
        echo -e "  ${GREEN}✓${NC} coeur.env : OPERATOR_ID=${idx} ajoute"
    fi
}

# Set to 1 when the native point code has just changed: its daemons keep
# the old one in memory and MUST restart (see tout_arreter).
NATIF_REALIGNE=0
aligner_natif() {
    local idx pc spec reel
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode _ip pc _rctx <<< "$spec"
        [ "$mode" = "native" ] || continue
        # coeur.env is aligned FIRST and UNCONDITIONALLY: point codes
        # (set-node-id.sh) and subscriber plan (OPERATOR_ID) are independent, and
        # the early "already at the right PC" exit below must not skip it.
        _aligner_coeur_env "$idx"
        reel="$(natif_pc)"
        [ -n "$reel" ] || return 0
        [ "$reel" = "$pc" ] && { echo -e "  ${GREEN}✓${NC} natif deja en PC ${pc} (op ${idx})"; return 0; }
        echo -e "  ${CYAN}→${NC} natif en PC ${reel}, attendu ${pc} : realignement sur l operateur ${idx}"
        if [ -x "$DIR/network/set-node-id.sh" ] || [ -r "$DIR/network/set-node-id.sh" ]; then
            if bash "$DIR/network/set-node-id.sh" --node "${MULTI_NODE:-1}" --op "$idx" \
                    --local --hub-ip 127.0.0.1 >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} natif realigne : PC $(natif_pc)"
                echo -e "  ${YELLOW}!${NC} les demons natifs gardent l ancienne identite en memoire :"
                echo -e "    ils seront arretes et relances pour qu ils la relisent."
                NATIF_REALIGNE=1
            else
                echo -e "  ${RED}✗${NC} realignement du natif echoue - voir network/set-node-id.sh"
            fi
        fi
        return 0
    done
}
aligner_natif

# ── --align: stop here ──────────────────────────────────────────────────────
# Nothing is started or stopped: the native stack reads its config when
# start-native.sh starts it right after (hence the bench calls --align first).
if [ "$ACTION" = "align" ]; then
    if [ "$NATIF_REALIGNE" = 1 ]; then
        echo -e "  ${CYAN}i${NC} --align : identite posee ; le natif la lira a son prochain demarrage (rien relance ici)"
    else
        echo -e "  ${GREEN}✓${NC} --align : identite du natif deja en place, rien a faire"
    fi
    exit 0
fi

# ── Native 2G stays up; containers restart from scratch ───────────────────
# Osmocom daemons do NOT reload their configuration live (kill -HUP does not
# help): a full stop is required after a point code change.
#
# The native stack is only restarted when needed:
#   - native running and already aligned -> KEPT as is;
#   - native stopped                     -> started by lancer_natif_si_absent;
#   - native realigned (aligner_natif)   -> stop + restart, no choice;
#   - --restart-natif                    -> stop + restart, on request.
#
# Stopping delegates to run.sh --stop, which tears down radio and core
# cleanly. Nothing here may fail the launch: what is already stopped is
# fine, hence the || true.
# ── The native stack is a systemd unit when installed ─────────────────────
# osmo-banc.service holds the native stack (services/osmo-banc.service).
# Stopping it with start-native.sh --stop behind systemd's back would leave
# the unit "active (exited)" on a dead stack, and the desktop shortcut needs
# a graphical session the service does not have. When the unit is
# installed, stop and (re)start it instead.
BANC_UNIT="${OSMO_BANC_SERVICE:-osmo-banc.service}"
_banc_unit_present() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl cat "$BANC_UNIT" >/dev/null 2>&1
}

arreter_natif() {
    if _banc_unit_present; then
        # The native stack is restarted right after by lancer_natif_si_absent;
        # here we only stop it cleanly (ExecStop = start-native.sh --stop).
        timeout 200 systemctl stop "$BANC_UNIT" >/dev/null 2>&1 || true
        echo -e "    ${GREEN}✓${NC} pile native arretee (${BANC_UNIT})"
    elif [ -x "$DIR/start-native.sh" ]; then
        timeout 120 "$DIR/start-native.sh" --stop >/dev/null 2>&1 || true
        echo -e "    ${GREEN}✓${NC} pile native arretee"
    fi
}

tout_arreter() {
    if _est_natif osmo-bsc asterisk; then
        if [ "$NATIF_REALIGNE" = 1 ]; then
            echo -e "  ${CYAN}→${NC} natif realigne : arret de la pile native pour qu elle relise sa config"
            arreter_natif
        elif [ "$RESTART_NATIF" = 1 ]; then
            echo -e "  ${CYAN}→${NC} --restart-natif : arret de la pile native"
            arreter_natif
        else
            echo -e "  ${GREEN}✓${NC} operateur natif (2G) deja en marche : on le garde tel quel"
        fi
    else
        echo -e "  ${CYAN}i${NC} operateur natif (2G) a l arret : il sera lance avant les conteneurs"
    fi
    # Containers are NOT touched here: start-docker.sh already runs
    # `docker rm -f $(docker ps -aq --filter name=osmo-)` at startup. Doing it
    # here would also wipe the multi-operator containers when called from
    # launch.sh, which only starts the native stack.
    # Audio bridges outlive the containers (setsid): kill them, otherwise one
    # more relay piles up on each restart and the audio doubles.
    pkill -f 'paplay --server=tcp:' 2>/dev/null || true
}

tout_arreter

# ── If the native stack is down, run its shortcut ─────────────────────────
# The native stack has its own launcher (desktop red phone -> launch.sh ->
# start-native.sh). Without it the hub would see only some of the expected
# ASPs and the final check would report DEGRADED.
#
# Start it BEFORE the containers: start-native.sh must set up its configs
# and core while the addressing plan is still free.
#
# Using the .desktop rather than launch.sh directly gives the same path as
# a user double-click: same terminal, same pkexec elevation.
NATIF_DESKTOP="${NATIF_DESKTOP:-/root/Desktop/osmo-launch.desktop}"

lancer_natif_si_absent() {
    _est_natif osmo-bsc asterisk && return 0

    if _banc_unit_present; then
        # systemctl start blocks until start-native.sh finishes (oneshot): when it
        # returns the core is already up. The wait below only matters if the unit
        # returned 0 without a core.
        echo -e "  ${YELLOW}!${NC} operateur natif a l arret - ${CYAN}systemctl start ${BANC_UNIT}${NC}"
        if ! systemctl start "$BANC_UNIT"; then
            echo -e "  ${RED}✗${NC} ${BANC_UNIT} n a pas demarre - journalctl -u ${BANC_UNIT%.service} -n 50"
            return 1
        fi
        _est_natif osmo-bsc asterisk && { echo -e "  ${GREEN}✓${NC} natif lance (${BANC_UNIT})"; return 0; }
        echo -n "  attente du natif "
        for i in $(seq 1 60); do
            _est_natif osmo-bsc asterisk && { echo -e " ${GREEN}✓${NC}"; return 0; }
            sleep 1; echo -n "."
        done
        echo -e " ${YELLOW}toujours absent apres 60 s - on continue quand meme${NC}"
        return 0
    fi

    echo -e "  ${YELLOW}!${NC} operateur natif a l arret - lancement de son raccourci"
    local d="$NATIF_DESKTOP"
    # Fallback locations: Desktop (French locale "Bureau"), then the menu.
    for _c in "$d" "${d%/Desktop/*}/Bureau/${d##*/}" "/usr/share/applications/${d##*/}"; do
        [ -f "$_c" ] && { d="$_c"; break; }
    done
    if [ ! -f "$d" ]; then
        echo -e "  ${RED}✗${NC} raccourci introuvable ($NATIF_DESKTOP)"
        echo -e "    ${CYAN}sudo ${DIR}/start-native.sh${NC}"
        return 1
    fi

    # gio launch is THE way to run a .desktop: it reads Exec, honours
    # Terminal= and goes through the session bus. gtk-launch as fallback (it
    # wants an application ID, not a path - hence basename without .desktop).
    # Last resort: extract Exec by hand.
    # OSMO_LAUNCH_APPS=0: the native stack is used as a STACK, not a
    # workstation; wireshark, linphone and firefox are already open elsewhere,
    # so launch.sh must not reopen them.
    export OSMO_LAUNCH_APPS=0
    # OSMO_TERM_TAKEN=1: the native stack gets its OWN window. Otherwise
    # launch.sh would take our tty as its own and start-native.sh would hold it
    # to the end. See launch.sh, guard "1. Un terminal".
    export OSMO_TERM_TAKEN=1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
    if command -v gio >/dev/null 2>&1 && gio launch "$d" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} raccourci lance : ${CYAN}${d}${NC}"
    elif command -v gtk-launch >/dev/null 2>&1 \
         && gtk-launch "$(basename "$d" .desktop)" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} raccourci lance (gtk-launch) : ${CYAN}${d}${NC}"
    else
        local _exec
        _exec="$(sed -n 's/^Exec=//p' "$d" | head -1 | sed 's/ *%[fFuUdDnNickvm]//g')"
        [ -n "$_exec" ] || { echo -e "  ${RED}✗${NC} pas de ligne Exec dans $d"; return 1; }
        echo -e "  ${YELLOW}○${NC} gio/gtk-launch indisponibles - execution directe : ${CYAN}${_exec}${NC}"
        setsid bash -c "$_exec" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi

    # Wait until it is really up: starting containers while the native stack
    # is coming up means competing for the same resources.
    echo -ne "  ${CYAN}→${NC} attente du natif"
    local i
    for i in $(seq 1 120); do
        _est_natif osmo-bsc asterisk && { echo -e " ${GREEN}✓${NC}"; return 0; }
        sleep 1; echo -n "."
    done
    echo -e " ${YELLOW}toujours absent apres 120 s - on continue quand meme${NC}"
    return 0
}
lancer_natif_si_absent



"${CMD[@]}"
rc=$?

# ── Final check ─────────────────────────────────────────────────────────────
# start-docker.sh may return 0 while SS7 is not up: its exit code says the
# containers STARTED, not that the ASPs associated. Check the REAL state
# afterwards.
verifier() {
    local ko=0 spec idx mode nom _ip pc _rctx _pc_reel
    echo
    echo -e "  ${BOLD}── Verification ──${NC}"

    # 1. Are all four elements present?
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode _ip pc _rctx <<< "$spec"
        if [ "$mode" = "docker" ]; then
            nom="osmo-operator-${idx}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
                echo -e "    ${GREEN}✓${NC} conteneur ${nom}"
            else
                echo -e "    ${RED}✗${NC} conteneur ${nom} absent"; ko=1
            fi
        else
            if ! _est_natif osmo-bsc asterisk; then
                echo -e "    ${RED}✗${NC} operateur natif arrete - ${CYAN}sudo ${DIR}/start-native.sh --op ${idx}${NC}"; ko=1
            else
                # ── The native point code must match its rank ──
                # A native stack started without --op runs as operator 1 (PC 1.1.2), the
                # same as the FIRST container (start-docker.sh always numbers from 1). Both
                # sides start fine but SS7 routing is wrong, so check it explicitly.
                _pc_reel="$(natif_pc)"
                if [ -z "$_pc_reel" ]; then
                    echo -e "    ${YELLOW}?${NC} operateur natif actif, point code illisible (/etc/osmocom/osmo-stp.cfg)"
                elif [ "$_pc_reel" = "$pc" ]; then
                    echo -e "    ${GREEN}✓${NC} operateur natif (op ${idx}, PC ${_pc_reel})"
                else
                    echo -e "    ${RED}✗${NC} operateur natif en PC ${_pc_reel}, attendu ${pc}"
                    echo -e "      il tourne en operateur $(echo "$_pc_reel" | cut -d. -f2), rang deja pris par un CONTENEUR"
                    echo -e "      ${CYAN}sudo ${DIR}/start-native.sh --op ${idx}${NC}  (puis relancer ce script)"
                    ko=1
                fi
            fi
        fi
    done
    nom="${MULTI_HUB_NAME:-osmo-inter-stp}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
        echo -e "    ${GREEN}✓${NC} inter-STP ${nom}"
    else
        echo -e "    ${RED}✗${NC} inter-STP ${nom} absent"; ko=1
    fi

    # 2. Native M3UA entry point. Query `ss`, NOT /dev/tcp: M3UA runs over
    #    SCTP, where a TCP probe is silent; `ss -an` lists SCTP sockets.
    # awk by FIELDS, not a regex: `ss -an` aligns columns with a VARIABLE number
    # of spaces depending on address length. $1/$2/$5 are stable.
    if ss -an 2>/dev/null | awk -v p=":${MULTI_M3UA_PORT}" \
         '$1=="sctp" && $2=="LISTEN" && index($5,p)==length($5)-length(p)+1 {f=1} END{exit !f}'; then
        echo -e "    ${GREEN}✓${NC} M3UA en SCTP sur 127.0.0.1:${MULTI_M3UA_PORT} (l operateur natif peut s attacher)"
    else
        echo -e "    ${RED}✗${NC} rien n ecoute en SCTP sur le port ${MULTI_M3UA_PORT}"
        echo -e "      l ASP du natif (osmo-stp.cfg, remote-ip 127.0.0.1) ne trouvera personne"
        ko=1
    fi

    # 3. The repository's SS7 checker, which reads ASPs and routes.
    if [ -x "$DIR/checks/ss7_check.sh" ]; then
        echo -e "    ${CYAN}→${NC} checks/ss7_check.sh"
        "$DIR/checks/ss7_check.sh" || ko=1
    else
        echo -e "    ${YELLOW}○${NC} checks/ss7_check.sh absent - verification SS7 sautee"
    fi

    echo
    if [ "$ko" = "0" ]; then
        echo -e "  ${GREEN}${BOLD}Banc multi-operateur OPERATIONNEL.${NC}"
    else
        echo -e "  ${RED}${BOLD}Le banc n est PAS complet${NC} - voir les lignes ✗ ci-dessus."
        echo -e "  ${CYAN}→${NC} etat detaille : ${BOLD}sudo $0 --status${NC}"
    fi
    return "$ko"
}

# ── Container dashboards as extra tabs ────────────────────────────────────
# launch.sh already opened Firefox on the NATIVE dashboard and the tutorial,
# and started Linphone and Wireshark: only the container consoles are
# missing, one per docker operator.
#
# Addresses come from the topology: adding an operator to osmo-multi.conf
# is enough to get its tab.
#
# Wait for each port to answer before opening: a container dashboard takes
# several seconds to come up, and a tab opened too early shows an error.
ouvrir_dashboards() {
    # ── OSMO_NO_TERM=1: no window, not even a tab ──
    # When run by osmo-multi.service (the desktop icon), do not pop up a
    # browser minutes after the click. The addresses are still PRINTED to the
    # journal (`journalctl -u osmo-multi`).
    if [ "${OSMO_NO_TERM:-0}" = "1" ]; then
        local _spec _idx _mode _ip _liste=""
        for _spec in $MULTI_OPS; do
            IFS=: read -r _idx _mode _ip _ <<< "$_spec"
            [ "$_mode" = "docker" ] && [ -n "$_ip" ] && _liste="$_liste http://${_ip}:8080"
        done
        echo -e "  ${CYAN}i${NC} OSMO_NO_TERM=1 : aucun onglet ouvert. Dashboards :${CYAN}${_liste}${NC}"
        return 0
    fi
    command -v firefox >/dev/null 2>&1 || return 0

    local spec idx mode ip urls="" i
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip _pc _rctx <<< "$spec"
        [ "$mode" = "docker" ] && [ -n "$ip" ] || continue
        for i in $(seq 1 60); do
            (exec 3<>"/dev/tcp/${ip}/8080") 2>/dev/null && { exec 3>&- 2>/dev/null; break; }
            sleep 1
        done
        if (exec 3<>"/dev/tcp/${ip}/8080") 2>/dev/null; then
            exec 3>&- 2>/dev/null
            urls="$urls http://${ip}:8080"
        else
            echo -e "  ${YELLOW}○${NC} dashboard op ${idx} (${ip}:8080) ne repond pas - onglet non ouvert"
        fi
    done
    [ -n "$urls" ] || return 0

    # Under the session user's account: Firefox already runs there and adds
    # the URLs as TABS to the existing window instead of opening a new one.
    local u uid home
    u="$(natif_session_user)"; uid="$(id -u "$u" 2>/dev/null || echo 0)"
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    # shellcheck disable=SC2086
    setsid sudo -u "$u" \
        env DISPLAY="${DISPLAY:-:0}" \
            XAUTHORITY="${XAUTHORITY:-${home:-/root}/.Xauthority}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        firefox $urls </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} onglets dashboards :${CYAN}${urls}${NC}"
}

# Graphical session user, same criterion as elsewhere: presence of its
# pulse socket, not its name (the ISO opens the session as root).
natif_session_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    echo "${SUDO_USER:-$(id -un)}"
}

# IN THE BACKGROUND: this function waits up to 60 s per container for port
# 8080. In the foreground it would block the checks for up to two minutes.
# Tabs open when they can; the checks start right away.
ouvrir_dashboards &
disown 2>/dev/null || true

echo
etat
verifier || rc=1

# ── The node sheet follows the multi-operator setup ───────────────────────
# The native stack wrote it with a single operator; rewrite it now that
# the containers are up (network/node-conf.sh counts the running
# osmo-operator-N). Other nodes import this sheet.
if [ "$ACTION" = "start" ] && [ -x "$DIR/start-native.sh" ]; then
    NO_MENU=1 "$DIR/start-native.sh" --gen-conf 2>/dev/null | grep -E "Fiche|mynode" || true
fi
# Window opened by us: keep it open, otherwise the summary disappears with it.
if [ "$_multi_own_window" = "1" ]; then
    echo
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
