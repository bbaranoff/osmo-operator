#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# launch.sh - DOUBLE-CLICK entry point of the osmo-operator bench.
#
# Brings up the complete workstation in one gesture:
#     1. wireshark    on udp/4729 (GSMTAP)         - root, only with OSMO_LAUNCH_APPS=1
#     2. linphone     the SIP softphone            - session user, only with OSMO_LAUNCH_APPS=1
#     3. firefox      on http://127.0.0.1:8080     - as soon as the dashboard answers
#     4. start.sh                                  - the bench, in the FOREGROUND
#
# The first three start in the background and cannot fail the launch: a
# missing tool is reported and the launch goes on. start.sh keeps the
# terminal: its output is what one wants to read.
#
# Three things separate a script that works in a terminal from one that works
# on double-click, and they are handled first:
#   1. NO TERMINAL. A .desktop starts without a tty: start.sh would write into
#      the void. With the systemd unit installed the launch becomes a service
#      start (notification + progress window); otherwise the script re-executes
#      itself inside a terminal window (tools/osmo-gtk-run.py --tty).
#   2. NO ROOT. The bench needs privileges (netns, systemd, captures). From an
#      icon: pkexec (graphical prompt), sudo as fallback.
#   3. THE WINDOW CLOSES BEFORE THE ERROR CAN BE READ. It is held at the end.
#
# Terminal usage (none of these detours apply):
#     sudo ./launch.sh [arguments passed to start.sh]
#
# Right-click actions (handled before any window, root through pkexec):
#     --service [args]   start osmo-banc.service (args -> OSMO_BANC_ARGS)
#     --service-suivi    same, following the unit journal (progress window)
#     --stop             stop the bench, native and container operators
#     --multi            start osmo-multi.service (multi-operator topology)
#     --multi-suivi      same, following the unit journal
#     --multi-stop       stop the multi-operator containers
#     --dashboard        open the dashboard in the browser
#     --console          attach to the bench tmux session in a window
#     --vty              open the MS VTY (telnet) in a window
#
# Environment:
#     GSMTAP_PORT (4729), OSMO_DASH_URL (http://127.0.0.1:8080),
#     OSMO_TUTORIAL_URL, OSMO_BANC_SERVICE (osmo-banc.service),
#     OSMO_MULTI_SERVICE (osmo-multi.service), OSMO_LAUNCH_LOCK,
#     OSMO_LAUNCH_APPS=1 (also start wireshark and linphone),
#     OSMO_LAUNCH_MENU=1 (keep the interactive whiptail menus of start.sh),
#     OSMO_LAUNCH_GTK=0 (no progress window, notifications only),
#     OSMO_LAUNCH_NO_SERVICE=1 (never go through the systemd unit from an icon),
#     OSMO_BANC_DIRECT=1 (run start.sh directly, bypassing the unit),
#     OSMO_LAUNCH_LOG (/var/log/osmo-launch.log, detached fallback),
#     OSMO_MS_VTY_PORT, TMUX_SESSION (calypso), HOST_PULSE_USER.
#     OSMO_LAUNCH_TERM / OSMO_TERM_TAKEN are internal re-exec flags.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TARGET="$DIR/start.sh"
GSMTAP_PORT="${GSMTAP_PORT:-4729}"
DASH_URL="${OSMO_DASH_URL:-http://127.0.0.1:8080}"
DASH_PORT="${DASH_URL##*:}"
# The tutorial opens as a SECOND TAB next to the dashboard. Served by the
# dashboard rather than file://: a single copy, and the URL works the same
# from another machine of the bench. See /usr/local/bin/osmo-tutorial.
TUTO_URL="${OSMO_TUTORIAL_URL:-${DASH_URL%/}/tutorial.html}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

[ -x "$TARGET" ] || { echo -e "${RED}start.sh introuvable ou non executable dans $DIR${NC}" >&2; exit 1; }

# ── ONE LAUNCH AT A TIME ─────────────────────────────────────────────────────
# A second launch would begin by stopping everything (one click = a fresh
# bench) and tear down the stack the first one is bringing up. Two ways of
# already being in the middle of a start-up, two tests:
#   1. another launch.sh holds the lock: a non-blocking flock on a descriptor
#      that SURVIVES the exec of start.sh, so it covers the whole start-up and
#      the kernel releases it when the process dies, even killed - nothing to
#      clean up, no stale lock after a power cut.
#   2. the osmo-banc unit is "activating": a bench started by systemd
#      (`systemctl start osmo-banc`, the "as a service" action of the icon, or
#      an image burnt with --banc) goes through no launch.sh and holds no lock.
# `--stop` is never blocked: it is the gesture that takes back control when a
# launch drags on.
LOCK_FILE="${OSMO_LAUNCH_LOCK:-/run/lock/osmo-launch.lock}"
verrou_pris() {
    command -v flock >/dev/null 2>&1 || return 0   # no flock: nothing is blocked
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>>"$LOCK_FILE" 2>/dev/null || return 0
    flock -n 9
}
banc_en_demarrage() {
    [ "$(systemctl is-active "${OSMO_BANC_SERVICE:-osmo-banc.service}" 2>/dev/null)" = activating ]
}
lancement_possible() {
    banc_en_demarrage && return 1
    verrou_pris
}
# The lock must die with the START-UP, not with the window: held by descriptor
# 9 it would otherwise live as long as the process, i.e. until someone presses
# Enter at "Fenetre maintenue ouverte" (or while attached to tmux), and a
# forgotten window would refuse every later click. It is released as soon as
# the bench is up.
verrou_liberer() { exec 9>&- 2>/dev/null || true; }

# ── 0. DIRECT ACTIONS (right-click menu): no window, talk to systemd only ────
# The report goes through a desktop notification, the only place the operator
# looks when there is no terminal. `systemctl restart` returns at the end of
# the start-up (up to TimeoutStartSec=900), which allows announcing a real
# result rather than a "started" with no follow-up.
case "${1:-}" in --service|--service-suivi|--stop|--dashboard|--console|--vty|--multi|--multi-suivi|--multi-stop) _bloc_direct=1 ;; *) _bloc_direct=0 ;; esac
if [ "$_bloc_direct" = "1" ]; then
    # Root WITHOUT a terminal: pkexec asks for the password in a desktop
    # window. No sudo fallback here: sudo would need a terminal, which is
    # precisely what these actions promise not to open.
    if [ "$(id -u)" -ne 0 ] && command -v pkexec >/dev/null 2>&1 \
       && [ -n "${DISPLAY:-}" ]; then
        exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
             "$0" "$@"
    fi
    _action="$1"; shift
    _svc="${OSMO_BANC_SERVICE:-osmo-banc.service}"
    _icon=/usr/share/osmo-operator/icons/osmo-launch.svg
    _note() {
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -i "$_icon" "Banc GSM" "$1" 2>/dev/null || true
        fi
        echo -e "  ${CYAN}→${NC} $1"
    }

    # ── The container operators ──────────────────────────────────────────────
    # The docker operators of the multi (osmo-operator-2, -3, the osmo-inter-stp
    # hub) run in their own cgroups (/system.slice/docker-<id>.scope), out of
    # reach of `systemctl stop osmo-banc`. osmo-multi.service propagates the
    # stop only while it is active: once "failed" (killed during start-up)
    # nothing holds the containers any more. So the unit is stopped when it
    # exists, THEN whatever remains is swept with the same filter
    # launch/start-docker.sh applies at the start of a run (a container of a
    # previous topology would escape `start-multi.sh --stop`).
    _arret_multi() {
        local _m="${OSMO_MULTI_SERVICE:-osmo-multi.service}"
        if systemctl cat "$_m" >/dev/null 2>&1; then
            timeout 200 systemctl stop "$_m" >/dev/null 2>&1 || true
            systemctl reset-failed "$_m" 2>/dev/null || true
        fi
        command -v docker >/dev/null 2>&1 || return 0
        local _c
        _c="$(docker ps -q --filter name=osmo- 2>/dev/null)" || return 0
        [ -n "$_c" ] || return 0
        _note "Arret des operateurs en conteneur..."
        # shellcheck disable=SC2086  # a list of IDs, one per line
        docker rm -f $_c >/dev/null 2>&1 || true
    }

    # ── Multi-operator: the icon starts the unit, and says so ────────────────
    # `systemctl start osmo-multi.service` returns 0 in two cases that are
    # indistinguishable from a click: a ConditionPathExists not met (the unit
    # is SKIPPED, not failed - the normal case on a fresh ISO before the
    # "Supplements" icon ran) and a unit already active (RemainAfterExit=yes).
    # The conditions are therefore tested HERE, what is missing is named, and
    # the result is announced by notification.
    _svcm="${OSMO_MULTI_SERVICE:-osmo-multi.service}"
    # ── Followed launch: the action plus the unit journal streaming ──────────
    # What the desktop launch window (osmo-gtk-run.py --progress) executes:
    # `systemctl start` shows nothing, the bench writes to its unit journal.
    # The journal is followed in parallel and the window reads the "[n/10]"
    # markers of run.sh for its progress bar. Lock, notifications and return
    # code are those of --service / --multi.
    if [ "$_action" = "--service-suivi" ] || [ "$_action" = "--multi-suivi" ]; then
        if [ "$_action" = "--service-suivi" ]; then _u="$_svc"; _sub=--service; else _u="$_svcm"; _sub=--multi; fi
        journalctl -u "$_u" -f -n 0 -o cat 2>/dev/null & _j=$!
        "$0" "$_sub" "$@"; _rc=$?
        sleep 1; kill "$_j" 2>/dev/null; wait "$_j" 2>/dev/null
        exit "$_rc"
    fi
    if [ "$_action" = "--multi-stop" ]; then
        _note "Arret du multi-operateur..."
        _arret_multi
        systemctl reset-failed "$_svcm" 2>/dev/null || true
        _note "Multi-operateur arrete (le natif reste a osmo-banc)."
        exit 0
    fi
    if [ "$_action" = "--multi" ]; then
        if ! systemctl cat "$_svcm" >/dev/null 2>&1; then
            _note "Unite $_svcm absente : lancez d abord l icone « Supplements »."
            exit 1
        fi
        # The same paths as the ConditionPathExists of the unit, checked HERE
        # rather than trusting the systemctl return code.
        if [ ! -f "$DIR/launch/start-multi.sh" ]; then
            _note "start-multi.sh introuvable dans $DIR - depot incomplet."
            exit 1
        fi
        if [ ! -f /etc/osmocom/osmo-multi.conf ]; then
            _note "Pas de topologie multi-operateur (/etc/osmocom/osmo-multi.conf) : l unite serait sautee en silence. Lancez l icone « Supplements » (addition.sh), qui installe docker, l image et cette topologie."
            exit 1
        fi
        case "$(systemctl is-active "$_svcm" 2>/dev/null)" in
            active)     _note "Le multi-operateur tourne deja. Journal : journalctl -u ${_svcm%.service} -f"; exit 0 ;;
            activating) _note "Le multi-operateur demarre deja - journalctl -u ${_svcm%.service} -f"; exit 0 ;;
        esac
        systemctl reset-failed "$_svcm" 2>/dev/null || true
        _note "Demarrage de $_svcm - comptez plusieurs minutes (images, conteneurs, HLR)."
        # `start`, not `restart`: ExecStop tears the containers down, and a
        # restart on an already running unit would cost a useless teardown.
        if systemctl start "$_svcm"; then
            # Type=oneshot + conditions: a 0 does not prove that it ran.
            if [ "$(systemctl is-active "$_svcm" 2>/dev/null)" = active ]; then
                _note "Multi-operateur en service. Journal : journalctl -u ${_svcm%.service} -f"
                exit 0
            fi
            _note "Unite sautee (condition non remplie) - systemctl status ${_svcm%.service}"
            exit 1
        fi
        _note "Echec de $_svcm - journalctl -u ${_svcm%.service} -n 80"
        exit 1
    fi

    # ── The dashboard ────────────────────────────────────────────────────────
    # Firefox FIRST, not xdg-open: it is the browser of the image, and a second
    # invocation adds a tab to the existing window instead of opening another
    # one. xdg-open is only the fallback.
    if [ "$_action" = "--dashboard" ]; then
        _u="${OSMO_DASH_URL:-http://127.0.0.1:8080}"
        if command -v firefox >/dev/null 2>&1; then
            setsid firefox "$_u" >/dev/null 2>&1 &
        elif command -v xdg-open >/dev/null 2>&1; then
            setsid xdg-open "$_u" >/dev/null 2>&1 &
        else
            _note "Aucun navigateur - ouvrez $_u a la main."; exit 1
        fi
        exit 0
    fi

    # ── The MS console (VTY) ─────────────────────────────────────────────────
    # telnet, as the Osmocom documentation says: the VTY expects a line-mode
    # terminal. Opened in a GTK window of the bench (VTE terminal inside,
    # tools/osmo-gtk-run.py); no favourite opens a gnome-terminal.
    if [ "$_action" = "--vty" ]; then
        # 4247, or 4347 in --dsp: start.sh publishes the real port in
        # /run/osmo-banc/ms1-vty; without the file, look at who listens
        # (4347 first, then 4247).
        _p="${OSMO_MS_VTY_PORT:-}"
        [ -z "$_p" ] && [ -r /run/osmo-banc/ms1-vty ] && _p="$(tr -dc 0-9 < /run/osmo-banc/ms1-vty)"
        if [ -z "$_p" ]; then
            if ss -ltnH "( sport = :4347 )" 2>/dev/null | grep -q .; then _p=4347; else _p=4247; fi
        fi
        _c="telnet 127.0.0.1 $_p || { echo; echo 'VTY 127.0.0.1:$_p injoignable - banc arrete ?'; exit 1; }"
        exec python3 "$(dirname "$(readlink -f "$0")")/tools/osmo-gtk-run.py" --tty \
             --title "Console du mobile (VTY $_p)" -- bash -c "$_c"
        _note "Aucune fenetre possible - tapez : telnet 127.0.0.1 $_p"
        exit 1
    fi

    # ── The bench console ────────────────────────────────────────────────────
    # This one, AND ONLY THIS ONE, opens a terminal: `tmux attach` is an
    # interactive session and has nowhere else to live. The bench launch
    # itself no longer opens one (see "ONE CLICK = ONE SERVICE" below).
    if [ "$_action" = "--console" ]; then
        _sess="${TMUX_SESSION:-calypso}"
        if ! tmux has-session -t "$_sess" 2>/dev/null; then
            _note "Pas de session « $_sess » : le banc ne tourne pas."
            exit 1
        fi
        exec python3 "$(dirname "$(readlink -f "$0")")/tools/osmo-gtk-run.py" --tty \
             --title "Console du banc (tmux $_sess)" -- tmux attach -t "$_sess"
        _note "Aucune fenetre possible - tapez : tmux attach -t $_sess"
        exit 1
    fi

    # ── Stop ─────────────────────────────────────────────────────────────────
    # A stop has nothing to show: it is done here, before any window.
    if [ "$_action" = "--stop" ]; then
        _etat="$(systemctl is-active "$_svc" 2>/dev/null || true)"
        if systemctl cat "$_svc" >/dev/null 2>&1; then
            _note "Arret de $_svc..."
            timeout 200 systemctl stop "$_svc" || true
        fi
        # ExecStop only runs when the unit was active or activating. When it
        # is "failed" (start.sh exited with an error) systemd has already
        # killed its cgroup, but the core (osmo-stp, hlr, msc, bsc...) lives
        # in ITS OWN units, started by run.sh through systemctl: they stay up.
        # Tear down by hand what ExecStop had no chance to tear down.
        case "$_etat" in
            active|activating|reloading) ;;   # ExecStop did the work
            *)
                [ -x "$TARGET" ] && timeout 120 "$TARGET" --stop >/dev/null 2>&1 || true
                # The two units that the second ExecStop of osmo-banc.service
                # stops: they are NOT in the bench cgroup and would survive a
                # stop through this path.
                systemctl stop osmo-egprs-web.service osmo-hlr.service 2>/dev/null || true
                ;;
        esac
        # The native stack is down; the container operators depend on none of
        # these paths (see _arret_multi).
        _arret_multi
        # Otherwise the unit stays "failed" and the next start begins from a
        # failed state.
        systemctl reset-failed "$_svc" 2>/dev/null || true
        _note "Banc arrete."
        exit 0
    fi

    if ! systemctl cat "$_svc" >/dev/null 2>&1; then
        _note "Unite $_svc absente : utilisez « Lancer le banc GSM »."
        exit 1
    fi
    # Same guard as the windowed launch: two start-ups at once tear each
    # other down.
    if ! lancement_possible; then
        _note "Un lancement est deja en cours - rien de fait. journalctl -u ${_svc%.service} -f"
        exit 1
    fi
    # The right-click options (--dsp...) reach the unit as in
    # banc_unit_restart: same mechanism, same scope (until reboot).
    if [ $# -gt 0 ]; then
        systemctl set-environment OSMO_BANC_ARGS="$*" 2>/dev/null || true
    else
        systemctl unset-environment OSMO_BANC_ARGS 2>/dev/null || true
    fi
    systemctl reset-failed "$_svc" 2>/dev/null || true
    _note "Demarrage de $_svc - comptez plusieurs minutes."
    if systemctl restart "$_svc"; then
        _note "Banc demarre. Console : tmux attach -t calypso"
        exit 0
    fi
    _note "Echec de $_svc - journalctl -u ${_svc%.service} -n 80"
    exit 1
fi

# ── ONE CLICK = ONE SERVICE; A SECOND CLICK = A NOTIFICATION THAT SAYS WHY ───
# From an icon (neither stdin nor stdout on a terminal) the launch goes
# through the service: systemd brings the bench up, a progress window or a
# notification announces the result, no terminal opens. This is exactly the
# "start the bench as a service" right-click action: a single path.
#
# A second click must not open anything either, but it must be SEEN: it
# answers with a desktop notification.
#
# A manual launch from a terminal keeps that terminal; the boxed lock warning
# further down is displayed there.
if { [ ! -t 0 ] || [ ! -t 1 ]; } \
   && [ "${OSMO_LAUNCH_TERM:-0}" != "1" ] && [ "${OSMO_TERM_TAKEN:-0}" != "1" ] \
   && [ "${OSMO_LAUNCH_NO_SERVICE:-0}" != "1" ] \
   && systemctl cat "${OSMO_BANC_SERVICE:-osmo-banc.service}" >/dev/null 2>&1; then
    if lancement_possible; then
        # WITH A WINDOW, WITHOUT A SHELL: the launch is shown in the bench
        # progress window (tools/osmo-gtk-run.py --progress: bar, step,
        # collapsed console). OSMO_LAUNCH_GTK=0 falls back to notifications.
        _gtk="$(dirname "$(readlink -f "$0")")/tools/osmo-gtk-run.py"
        if [ "${OSMO_LAUNCH_GTK:-1}" != 0 ] && [ -n "${DISPLAY:-}" ] && [ -x "$_gtk" ]; then
            # The lock is released HERE: the --service started inside the
            # window (as root) takes it again; held by the window, it would
            # refuse that very launch.
            verrou_liberer
            exec python3 "$_gtk" --progress --root --title "Banc GSM 2G" \
                 --icon /usr/share/osmo-operator/icons/osmo-launch.svg -- "$0" --service-suivi "$@"
        fi
        # The lock taken here survives the exec: the same process holds the
        # start-up under its other name.
        exec "$0" --service "$@"
    fi
    # Lock held: say so, and stop here. No window.
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i /usr/share/osmo-operator/icons/osmo-launch.svg "Banc GSM" \
            "Un lancement est deja en cours. Rien de fait - suivez-le avec journalctl -u osmo-banc -f." \
            2>/dev/null || true
    fi
    echo "Un lancement est deja en cours - rien de fait." >&2
    exit 1
fi

# ── 1. A terminal, if there is none - OR if it is not ours ───────────────────
# The test is the presence of a TTY on stdin AND stdout, not $DISPLAY: that is
# the real difference between "run by hand" and "run from an icon".
# OSMO_LAUNCH_TERM marks the re-exec round so as not to loop.
# An INHERITED tty is not ours: called by another launcher (start-multi.sh,
# which brings the native stack up BEFORE its containers) start.sh would write
# over its output. OSMO_TERM_TAKEN=1 says "this terminal is already busy": a
# window of our own is opened, tty or not.
_lt_besoin=0
{ [ ! -t 0 ] || [ ! -t 1 ]; } && _lt_besoin=1
[ "${OSMO_TERM_TAKEN:-0}" = "1" ] && _lt_besoin=1
if [ "$_lt_besoin" = "1" ] && [ "${OSMO_LAUNCH_TERM:-0}" != "1" ]; then
    export OSMO_LAUNCH_TERM=1
    unset OSMO_TERM_TAKEN            # the window opened here IS ours
    # The window is the bench one (GTK + VTE terminal, tools/osmo-gtk-run.py).
    exec python3 "$(dirname "$(readlink -f "$0")")/tools/osmo-gtk-run.py" --tty \
         --title "Banc GSM" -- "$0" "$@"
    # NO window possible. The caller's terminal is not taken over (that is
    # the failure this guard prevents): detach, and send the output to a log
    # rather than into the void.
    _lt_log="${OSMO_LAUNCH_LOG:-/var/log/osmo-launch.log}"
    echo -e "${YELLOW}Aucun emulateur de terminal - lancement detache, journal : ${_lt_log}${NC}" >&2
    exec setsid "$0" "$@" </dev/null >>"$_lt_log" 2>&1
fi

# The flag has done its job: REMOVE it from the environment, or it would reach
# start.sh and every descendant that calls this script back, which would then
# believe it already has its window. The value stays in a shell variable, for
# holding the window at the end.
_own_window=0
[ "${OSMO_LAUNCH_TERM:-0}" = "1" ] && _own_window=1
unset OSMO_LAUNCH_TERM

# ── 2. Privileges ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        # pkexec scrubs the environment: DISPLAY and XAUTHORITY are passed
        # again by hand, otherwise nothing graphical can open afterwards.
        exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
             OSMO_LAUNCH_TERM="$_own_window" "$0" "$@"
    fi
    command -v sudo >/dev/null 2>&1 && exec sudo -E "$0" "$@"
    echo -e "${RED}Root requis et ni pkexec ni sudo disponibles.${NC}" >&2
    exit 1
fi

# ── The user of the graphical session ────────────────────────────────────────
# Same criterion as helpers/prepare_host.sh and launch/start-docker.sh: the
# account NAME says nothing, the presence of its pulse socket does. On the
# --desktop ISO the session is opened as root (gdm3 AutomaticLogin=root), so
# "root" is a valid answer here, not an error.
session_user() {
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
GUI_USER="$(session_user)"
GUI_UID="$(id -u "$GUI_USER" 2>/dev/null || echo 0)"
GUI_HOME="$(getent passwd "$GUI_USER" 2>/dev/null | cut -d: -f6)"
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${GUI_HOME:-/root}/.Xauthority}"

# Starts a graphical application under the session account. `setsid` detaches
# it: it survives the closing of this terminal, and its return code cannot
# bring launch.sh down.
gui_run() {
    setsid sudo -u "$GUI_USER" \
        env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${GUI_UID}/bus" \
        "$@" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# ── The 2x2 tiling ───────────────────────────────────────────────────────────
# Each application takes ONE QUARTER of the screen:
#
#        +---------------------+---------------------+
#        |  bench terminal     |  firefox / dashboard|
#        |  (start.sh)         |  127.0.0.1:8080     |
#        +---------------------+---------------------+
#        |  wireshark          |  linphone           |
#        |  udp/4729 GSMTAP    |  extensions 100/200 |
#        +---------------------+---------------------+
#
# wmctrl talks EWMH, which Mutter exposes under X11 (the ISO forces X11:
# WaylandEnable=false in gdm3/custom.conf). Under Wayland nothing answers and
# the tiling is simply ignored, without breaking the launch.
#
# The maximized states are removed BEFORE setting the geometry: a maximized
# window accepts the order and ignores it.
tile_windows() {
    command -v wmctrl  >/dev/null 2>&1 || { echo -e "  ${YELLOW}○${NC} wmctrl absent - fenetres non pavees"; return 0; }
    command -v xdpyinfo >/dev/null 2>&1 || { echo -e "  ${YELLOW}○${NC} xdpyinfo absent - fenetres non pavees"; return 0; }

    local sw sh qw qh
    sw="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[1]; exit}')"
    sh="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[2]; exit}')"
    [ -n "$sw" ] && [ -n "$sh" ] || return 0
    qw=$(( sw / 2 )); qh=$(( sh / 2 ))

    # $1 = WM_CLASS pattern (case-insensitive), $2 = x, $3 = y
    place() {
        local pat="$1" x="$2" y="$3" i id
        for i in $(seq 1 90); do
            id="$(wmctrl -l -x 2>/dev/null | grep -iE "$pat" | awk '{print $1; exit}')"
            [ -n "$id" ] && break
            sleep 1
        done
        [ -n "$id" ] || return 0
        wmctrl -i -r "$id" -b remove,maximized_vert,maximized_horz 2>/dev/null || true
        wmctrl -i -r "$id" -e "0,${x},${y},${qw},${qh}" 2>/dev/null || true
    }

    place 'gnome-terminal|xfce4-terminal|konsole|xterm'  0    0
    place 'firefox|navigator'                          "$qw" 0
    place 'wireshark'                                   0   "$qh"
    place 'linphone'                                   "$qw" "$qh"
}

# ── The bench is a systemd unit when it exists ───────────────────────────────
# services/osmo-banc.service starts the bench without a terminal and keeps it
# in the tmux session "calypso" (installed but not enabled at boot: this
# script or the icon starts it). When the unit is installed this script does
# not run start.sh itself: it (re)starts the unit, opens the desktop
# applications, then ATTACHES to tmux in its terminal. Running start.sh by
# hand on top would kill the service processes behind systemd's back.
#
# The arguments (--dsp, --op 2, --regen...) reach the unit through
# OSMO_BANC_ARGS (systemctl set-environment: until reboot, then
# /etc/default/osmo-banc applies). Without arguments a leftover is cleared.
#
# OSMO_BANC_DIRECT=1 ./launch.sh bypasses the unit (manual debugging).
BANC_UNIT="${OSMO_BANC_SERVICE:-osmo-banc.service}"
banc_unit_present() {
    [ "${OSMO_BANC_DIRECT:-0}" = "1" ] && return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl cat "$BANC_UNIT" >/dev/null 2>&1
}
# The stop lives at the top of the file ("Stop" block), before any window:
# `launch.sh --stop` never reaches this point.
# Follows the unit journal during the start-up: the output of start.sh /
# run.sh, in this terminal.
banc_unit_restart() {
    if [ $# -gt 0 ]; then
        systemctl set-environment OSMO_BANC_ARGS="$*" 2>/dev/null || true
        echo -e "  ${CYAN}→${NC} options : ${CYAN}$*${NC} (OSMO_BANC_ARGS, jusqu au reboot)"
    else
        systemctl unset-environment OSMO_BANC_ARGS 2>/dev/null || true
    fi
    echo -e "  ${CYAN}→${NC} redemarrage de ${BANC_UNIT} (un clic = un banc neuf)"
    journalctl -u "${BANC_UNIT%.service}" -f -n 0 -o cat 2>/dev/null &
    local _jpid=$!
    systemctl restart "$BANC_UNIT"; local rc=$?
    sleep 1; kill "$_jpid" 2>/dev/null; wait "$_jpid" 2>/dev/null
    if [ "$rc" -ne 0 ]; then
        echo -e "  ${RED}✗${NC} ${BANC_UNIT} en echec (rc=$rc) - journalctl -u ${BANC_UNIT%.service} -n 80"
        systemctl status --no-pager -n 20 "$BANC_UNIT" 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓${NC} banc demarre par ${BANC_UNIT}"
    fi
    return "$rc"
}

# The lock (see its block at the top of the file). Here and not earlier:
# `--stop` must pass, and privileges must be settled - a flock taken before
# the sudo re-exec would be held by a process that disappears at once.
if [ "${1:-}" != "--stop" ] && ! lancement_possible; then
    echo
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  UN LANCEMENT EST DEJA EN COURS                            |${NC}"
    echo -e "${YELLOW}|  Cette fenetre ne lancera RIEN.                            |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo
    echo -e "  Le banc met plusieurs minutes a monter (QEMU, Calypso, mobiles)."
    echo -e "  Un second lancement ARRETERAIT le premier : un clic = un banc"
    echo -e "  neuf, et le neuf commence par demonter celui d avant."
    echo
    echo -e "  Suivre le demarrage   : ${CYAN}journalctl -u osmo-banc -f${NC}"
    echo -e "  Console du banc       : ${CYAN}tmux attach -t calypso${NC}"
    echo -e "  Vraiment recommencer  : clic droit sur l icone, ${CYAN}Arreter le banc${NC},"
    echo -e "                          puis relancer."
    echo
    command -v notify-send >/dev/null 2>&1 && \
        notify-send -i /usr/share/osmo-operator/icons/osmo-launch.svg "Banc GSM" \
            "Un lancement est deja en cours - cette fenetre ne fera rien." 2>/dev/null || true
    if [ "$_own_window" = "1" ]; then
        echo "Entree pour fermer."
        read -r _ || true
    fi
    exit 1
fi

# ── Stop everything before relaunching ───────────────────────────────────────
# One click = a FRESH bench: the Osmocom daemons do not re-read their
# configuration while running (not even on SIGHUP), so a launch on top of a
# running bench would change almost nothing. The NATIVE stack is stopped
# (start.sh --stop, which tears radio and core down cleanly). Nothing here
# may fail the launch, hence the || true.
tout_arreter() {
    # With the unit, the stop is done by `systemctl restart` further down.
    banc_unit_present && return 0
    echo -e "  ${CYAN}→${NC} arret du banc en place (un clic = un banc neuf)"
    if [ -x "$DIR/start.sh" ]; then
        timeout 120 "$DIR/start.sh" --stop >/dev/null 2>&1 || true
        echo -e "    ${GREEN}✓${NC} pile native arretee"
    fi
    # The containers are NOT touched here: launch/start-docker.sh already does
    # `docker rm -f $(docker ps -aq --filter name=osmo-)` at the start of a
    # run, and a click on the red phone, which only brings the native stack
    # up, must not sweep the multi-operator containers next to it.
    # The audio bridges survive the containers (setsid): without this a relay
    # would pile up at every relaunch and the sound would double.
    pkill -f 'paplay --server=tcp:' 2>/dev/null || true
}

tout_arreter

# ── Are the operating tools wanted? ──────────────────────────────────────────
# OSMO_LAUNCH_APPS=0 (default): neither wireshark nor linphone. They are tools
# one opens WHEN needed, from their own icon; they are not part of the
# start-up. It is also what start-multi.sh asks for when it triggers this
# launcher to bring the native stack back up. OSMO_LAUNCH_APPS=1 opens them.
#
# FIREFOX IS NOT CONCERNED, deliberately: the browser carries the native
# dashboard and the tutorial, and start-multi.sh ADDS the container dashboard
# tabs to it. Firefox does not duplicate itself: a second invocation adds
# tabs to the existing window.
OSMO_LAUNCH_APPS="${OSMO_LAUNCH_APPS:-0}"
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}i${NC} wireshark et linphone non lances (OSMO_LAUNCH_APPS=1 pour les avoir)"
fi

# ── 1. WIRESHARK on udp/4729 ─────────────────────────────────────────────────
# As ROOT, not as $GUI_USER: capturing on `any` needs CAP_NET_RAW. -k starts
# the capture at once (otherwise it opens on the interface chooser and
# nothing is captured until a click). "not requested" and "not installed" are
# reported separately.
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}○${NC} wireshark : non demande (mode banc seul)"
elif command -v wireshark >/dev/null 2>&1; then
    setsid wireshark -k -i any -f "udp port ${GSMTAP_PORT}" \
        </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} wireshark : capture GSMTAP sur ${CYAN}udp/${GSMTAP_PORT}${NC}"
else
    echo -e "  ${YELLOW}○${NC} wireshark absent - capture GSMTAP ignoree"
fi

# ── 2. LINPHONE ──────────────────────────────────────────────────────────────
# The SIP account is pre-provisioned (configs/linphonerc, installed by the ISO
# build). Linphone does NOT re-read its config while running: if it is
# already up it is left as is rather than cutting a call in progress.
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}○${NC} linphone : non demande (mode banc seul)"
elif command -v linphone >/dev/null 2>&1; then
    if pgrep -x linphone >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} linphone : deja lance (laisse en place)"
    else
        gui_run linphone
        echo -e "  ${GREEN}✓${NC} linphone : lance (user=${CYAN}${GUI_USER}${NC})"
    fi
else
    echo -e "  ${YELLOW}○${NC} linphone absent"
fi

# ── 3. FIREFOX on the dashboard, WHEN IT ANSWERS ─────────────────────────────
# Opening the URL at once would give an error page (the dashboard is not up
# yet) that the user would have to reload by hand. The port is polled in the
# background, up to 180 s.
if command -v firefox >/dev/null 2>&1; then
    (
        for _i in $(seq 1 180); do
            if (exec 3<>"/dev/tcp/127.0.0.1/${DASH_PORT}") 2>/dev/null; then
                exec 3>&- 2>/dev/null
                # Two URLs on the same command line = two TABS in the same
                # window. A second `firefox <url>` would race with the browser
                # start-up and sometimes open a second window.
                gui_run firefox "$DASH_URL" "$TUTO_URL"
                exit 0
            fi
            sleep 1
        done
    ) &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} firefox : ouvrira ${CYAN}${DASH_URL}${NC} des que le dashboard repond"
else
    echo -e "  ${YELLOW}○${NC} firefox absent - dashboard a ouvrir a la main sur ${DASH_URL}"
fi

# The tiling runs in the background: each window is placed as soon as it
# appears, without delaying the bench start-up.
tile_windows &
disown 2>/dev/null || true

# ── 4. THE BENCH, IN THE FOREGROUND ──────────────────────────────────────────
echo
cd "$DIR" || exit 1

# ── No input ─────────────────────────────────────────────────────────────────
# start.sh opens menu_interactif() (startup_scripts/06-banc-dsp-menu.sh):
# profile, SS7 node, operator, inter-STP - whiptail questions it skips only
# when no terminal is present ([ -t 0 ]), and launch.sh has just opened one.
# NO_MENU=1 (startup_scripts/06-banc-dsp-menu.sh and 10-identite-noeud.sh)
# makes the menus return without asking: node 1, operator 1, local hub, as
# launch/start-docker.sh already sets for its containers.
# OSMO_LAUNCH_MENU=1 ./launch.sh gives the questions back.
if banc_unit_present; then
    banc_unit_restart "$@"
    rc=$?
    # The bench runs in tmux: attach to it when a terminal is available.
    # Ctrl-b d detaches; the bench goes on without this terminal.
    if [ "$rc" -eq 0 ] && [ -t 1 ] && tmux has-session -t "${TMUX_SESSION:-calypso}" 2>/dev/null; then
        echo -e "  ${CYAN}connexion a la session tmux « ${TMUX_SESSION:-calypso} »  (Ctrl-b d pour detacher)${NC}"
        sleep 1
        verrou_liberer   # otherwise the tmux client would hold it while attached
        exec tmux attach -t "${TMUX_SESSION:-calypso}"
    fi
elif [ "${OSMO_LAUNCH_MENU:-0}" = "1" ]; then
    "$TARGET" "$@"
    rc=$?
else
    NO_MENU=1 "$TARGET" "$@"
    rc=$?
fi

verrou_liberer

echo
if [ "$rc" -eq 0 ]; then
    echo -e "${GREEN}=== start.sh termine (code 0) ===${NC}"
else
    echo -e "${RED}=== start.sh a ECHOUE (code $rc) ===${NC}"
fi
# Only in a window opened by this script: in a terminal, returning at once is
# the expected behaviour.
if [ "$_own_window" = "1" ]; then
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
