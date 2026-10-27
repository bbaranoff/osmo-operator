#!/bin/bash
# =============================================================================
# osmo-lte.sh - THE BENCH 4G: Open5GS (the core), srsENB and srsUE on the
# ZeroMQ radio, started IN ORDER AND ON TIME.
#
# WHY A LAUNCHER, when three command lines are enough. Because the three
# lines have two traps:
#
#   1. "fail_on_disconnect=true" on the eNB. It is the argument of the doc,
#      and it does what it says: when the eNB receives NO sample from the UE
#      for 2000 ms (ZMQ_TIMEOUT_MS, rf_zmq_imp_trx.h), its radio STOPS. The
#      process stays, the S1 to the core stays, but nothing goes out on ZeroMQ
#      any more (a hundred bytes each way, the ZMTP handshake and nothing
#      else). An srsUE started ONE MINUTE after the eNB finds a dead radio:
#      "Attaching UE..." and never "Found Cell". Here the UE starts half a
#      second after the eNB.
#
#   2. The SIB3. sib.conf programs the SIBs sent through "si_mapping_info";
#      putting [ 7 ] (the SIB7, the GERAN list of the CSFB) INSTEAD of [ 3 ]
#      removes the SIB3. srsUE only deems a cell "suitable" IF it has the
#      SIB3 (srsue rrc.cc, cell_selection_criteria: has_sib3()): "Failed to
#      configure serving cell", T3410 expires, five attempts, nothing. It
#      must be [ 3, 7 ] - checked before starting.
#
# THE CORE IS OPEN5GS (tools/osmo-epc.sh: mongod, ogstun, the eight daemons,
# the SGs to OsmoMSC for the CSFB). The MME listens for the S1 on 127.0.0.2 -
# that is what enb.conf says (mme_addr). And the "ue1" netns of the UE lives
# in /run: it disappears at reboot, it is recreated here.
#
# THE CONFIGS ARE THOSE OF THE REPOSITORY (configs/srsran/*.conf, user_db.csv),
# installed in root's ~/.config/srsran by tools/osmo-lte-install.sh. They
# carry the ZeroMQ radio (device_name / device_args: ports 2000/2001,
# base_srate 11.52e6): they are NOT repeated on the command line, except
# OSMO_LTE_SRATE to force another rate. The srs* are started FROM this
# directory: sib.conf / rr.conf / rb.conf are resolved there, and the .ctxt
# (the NAS context srsue saves in its cwd) lives there too.
#
#   osmo-lte start      core (osmo-epc), then eNB, then UE (refused if one already runs)
#   osmo-lte start-gui  THE SAME LAUNCH, WITH THE srsGUI TRACES ON SCREEN
#                       (constellation, spectrum, PDSCH): --gui.enable on the eNB
#                       and the UE, and a DISPLAY. Never through systemd - a
#                       system unit has no screen; it is a direct launch.
#   osmo-lte traces     THE TRACES ALONE: restarts eNB and UE with srsGUI, WITHOUT
#                       touching the Open5GS core (which stays up, subscribers
#                       included). srsGUI is not a separate app: these are Qt
#                       windows opened by srsenb/srsue themselves (--gui.enable),
#                       they cannot be attached to an already running eNB - hence
#                       the restart of the radio, and of the radio only.
#                       Nothing running? Then it is a full start-gui.
#   osmo-lte stop       stops eNB and UE (the core stays: "osmo-epc stop")
#   osmo-lte restart    stop then start
#                       start / stop / restart without root: the script
#                       RE-RUNS ITSELF through pkexec (sudo fallback) instead
#                       of refusing - "osmo-lte stop" typed in a session
#                       terminal does stop the 4G.
#   osmo-lte status     processes, S1, ZeroMQ throughput, UE address
#   osmo-lte log        the logs, live
#   osmo-lte toggle     THE ICON: the osmo-lte service (systemd) - starts it if
#                       stopped, stops it if running (pkexec without root).
#                       "running" = the service active OR the daemons (srsenb,
#                       srsue, open5gs-mmed) up: a 4G started by "sudo osmo-lte
#                       start" or start-gui, unknown to the unit, is also
#                       stopped by the icon. The stop turns EVERYTHING off (eNB,
#                       UE, core).
#   osmo-lte up|down    the service, explicitly (right-click Actions)
#   osmo-lte journal    journalctl -u osmo-lte -f
#   osmo-lte install    installs the configs and the launchers (tools/osmo-lte-install.sh)
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
SRS_DIR="${OSMO_SRSRAN_DIR:-/root/.config/srsran}"
NETNS="${OSMO_LTE_NETNS:-ue1}"
ZMQ_ENB="${OSMO_ZMQ_PORT:-2000}"
ZMQ_UE="${OSMO_ZMQ_PORT_UE:-2001}"
SRATE="${OSMO_LTE_SRATE:-}"           # vide = ce que disent enb.conf / ue.conf
LOGDIR="${OSMO_LTE_LOGDIR:-/tmp}"
BUILD="${OSMO_SRSRAN_BUILD:-/opt/LTE/srsRAN_4G/build}"
EPC="${OSMO_EPC:-/usr/local/bin/osmo-epc}"
[ -x "$EPC" ] || EPC="$REPO/tools/osmo-epc.sh"
MME_S1="${OSMO_LTE_MME:-127.0.0.2}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

_root() { [ "$(id -u)" -eq 0 ] && return 0; _err "il faut root (netns, tun, SCTP) : sudo $0 $*"; return 1; }

# THE ICON GESTURE. The 4G lives in services/osmo-lte.service (Open5GS + eNB
# + UE); the desktop icon (data/desktop/osmo-lte.desktop) calls "osmo-lte
# toggle": one click starts, the next one stops. From a session without
# root, pkexec opens the password window (sudo fallback); the result goes
# out as a notification, there is no terminal.
SVC="${OSMO_LTE_SERVICE:-osmo-lte.service}"
ICONE=/usr/share/osmo-operator/icons/osmo-lte.svg
_notif() { command -v notify-send >/dev/null 2>&1 && notify-send -i "$ICONE" "4G du banc" "$1" 2>/dev/null || true; _say "$1"; }
_lte_debout() {
    case "$(systemctl is-active "$SVC" 2>/dev/null)" in active|activating) return 0 ;; esac
    local d
    for d in srsenb srsue open5gs-mmed; do pgrep -x "$d" >/dev/null 2>&1 && return 0; done
    return 1
}
# What _svc does AS ROOT, in a single pass (a single password window): the
# unit, then what it did not carry.
_svc_root() {
    local act="$1" rc=0
    case "$act" in
        start)
            # the unit log scrolls during the start: it is what the launch
            # window reads ([n/4] markers of lte_start)
            journalctl -u "$SVC" -f -n 0 -o cat 2>/dev/null & local _j=$!
            systemctl start "$SVC"; rc=$?
            sleep 1; kill "$_j" 2>/dev/null; wait "$_j" 2>/dev/null ;;
        stop)
            case "$(systemctl is-active "$SVC" 2>/dev/null)" in
                active|activating) systemctl stop "$SVC"; rc=$? ;;
            esac
            # a 4G started outside the unit (sudo osmo-lte start, start-gui):
            # turned off the same way - eNB, UE, then the core
            if _lte_debout; then
                lte_stop || rc=1
                "$EPC" stop || rc=1
            fi ;;
    esac
    return "$rc"
}
_svc() {
    local act="$1" rc
    if [ "$act" = toggle ]; then
        if _lte_debout; then act=stop; else act=start; fi
    fi
    [ "$act" = start ] && _notif "demarrage de la 4G (Open5GS, eNB, UE)... une trentaine de secondes"
    if [ "$(id -u)" -eq 0 ]; then _svc_root "$act"; rc=$?
    elif command -v pkexec >/dev/null 2>&1; then pkexec /bin/bash "$0" _svc-root "$act"; rc=$?
    else sudo /bin/bash "$0" _svc-root "$act"; rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        [ "$act" = start ] && _notif "4G en marche : UE attache dans $NETNS (osmo-lte status)" || _notif "4G arretee (eNB, UE et coeur)"
    else
        _notif "echec ($act, code $rc) - journalctl -u $SVC"
    fi
    return "$rc"
}

# start / stop / restart WITHOUT root: re-run elevated, DISPLAY kept (pkexec
# clears it, and the icon / the session terminal have one).
_eleve() {
    [ "$(id -u)" -eq 0 ] && return 0
    _say "elevation (pkexec) pour « $* »"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec /usr/bin/env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" /bin/bash "$0" "$@"
    fi
    exec sudo /bin/bash "$0" "$@"
}

# ── THE "WITH TRACES" MODE (srsGUI) ─────────────────────────────────────────
# srsRAN is built with ENABLE_GUI=ON (srsGUI, installed before it by
# tools/osmo-lte-install.sh): srsenb and srsue CAN trace their constellation,
# their spectrum and their PDSCH in real time. They only DO it when asked -
# "[gui] enable" of enb.conf/ue.conf is false, and it is not changed: the
# bench 4G normally starts through a systemd service, which has no screen,
# and a Qt window that cannot open would make a working start fail.
#
# Hence TWO modes, and the normal mode stays EXACTLY what it was:
#     "start"      what the service does, nothing on screen
#     "start-gui"  the same launch + --gui.enable=1 on both
#   (these two labels deliberately do not begin with "osmo-lte start": the
#    help at the bottom of the file is a `sed` range on that pattern, and a
#    second occurrence would make it print the whole script.)
# The only difference in lte_start is an empty array when GUI=0.
GUI=0

# Qt needs an X server and a cookie. The traces mode is started from the
# desktop (icon, session terminal) but RUNS AS ROOT: DISPLAY and XAUTHORITY
# do not always follow (pkexec clears the environment, sudo too depending on
# env_reset). They are recovered: the X socket of the running server, and
# the cookie of the ACTIVE graphical session.
_display_ou_rien() {
    if [ -z "${DISPLAY:-}" ]; then
        local s n=""
        for s in /tmp/.X11-unix/X*; do
            [ -S "$s" ] || continue
            n="${s##*/X}"; break
        done
        [ -n "$n" ] || { _err "aucun serveur X (/tmp/.X11-unix vide) : le mode traces demande un ecran - « $0 start » sans traces"; return 1; }
        export DISPLAY=":$n"
        _say "DISPLAY absent : on prend $DISPLAY"
    fi
    if [ -z "${XAUTHORITY:-}" ] || [ ! -r "${XAUTHORITY:-}" ]; then
        local uid f
        uid="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ / active / {print $2; exit}')"
        [ -n "$uid" ] || uid="$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $2}')"
        for f in "/run/user/$uid/gdm/Xauthority" "/run/user/$uid/.Xauthority" \
                 "$(getent passwd "${uid:-0}" | cut -d: -f6)/.Xauthority"; do
            [ -n "$uid" ] || break
            [ -r "$f" ] && { export XAUTHORITY="$f"; break; }
        done
    fi
    # Qt would follow WAYLAND_DISPLAY if it lingers in the environment, and
    # would fail as root on the user's wayland socket: xcb is imposed.
    export QT_QPA_PLATFORM=xcb
    # An srsenb not linked to srsGUI accepts --gui.enable without showing
    # anything: say it rather than let the user search.
    local b
    b="$(_bin srsenb 2>/dev/null)"
    if [ -n "$b" ] && ! ldd "$b" 2>/dev/null | grep -q libsrsgui; then
        _warn "srsenb n est pas lie a srsGUI : aucune trace ne s affichera - « osmo-lte-install --build »"
    fi
    return 0
}

# The traces mode is started from the session, not from systemd: it is the
# one that fetches root, taking the screen along (same gesture as the bench
# icon, launch/osmo-launch.sh: pkexec env DISPLAY=... XAUTHORITY=...).
_root_avec_display() {
    local act="${1:-start-gui}"
    [ "$(id -u)" -eq 0 ] && return 0
    _display_ou_rien || return 1
    _say "elevation (pkexec) en gardant $DISPLAY"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec /usr/bin/env DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" \
             QT_QPA_PLATFORM=xcb "$0" "$act"
    fi
    exec sudo DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" QT_QPA_PLATFORM=xcb "$0" "$act"
}

# The installed binary first, the local build otherwise.
_bin() {
    local n="$1"
    command -v "$n" 2>/dev/null && return 0
    for f in "$BUILD/srs${n#srs}/src/$n" "$BUILD/$n/src/$n"; do [ -x "$f" ] && { echo "$f"; return 0; }; done
    return 1
}

# The SIB3 must be programmed (trap no. 2 of the header).
_verifier_sib() {
    local sib="$SRS_DIR/sib.conf"
    [ -f "$sib" ] || { _warn "pas de $sib : srsENB prendra ses valeurs par defaut"; return 0; }
    local map
    map="$(grep -oE 'si_mapping_info\s*=\s*\[[^]]*\]' "$sib" | head -1)"
    if [ -n "$map" ] && ! printf '%s' "$map" | grep -qE '\[\s*(3|[0-9]+\s*,\s*)*3(\s*,|\s*\])'; then
        _err "sib.conf : « $map » ne programme pas le SIB3 - srsUE ne s attachera jamais (il faut [ 3, 7 ])"
        return 1
    fi
    _ok "sib.conf : $map"
}

# The configs: those of ~/.config/srsran, else those of the repository, installed.
_configs() {
    [ -f "$SRS_DIR/enb.conf" ] && [ -f "$SRS_DIR/ue.conf" ] && return 0
    [ -d "$REPO/configs/srsran" ] || { _err "pas de configs srsRAN ($SRS_DIR, ni $REPO/configs/srsran)"; return 1; }
    mkdir -p "$SRS_DIR"
    cp -n "$REPO/configs/srsran/"* "$SRS_DIR/"
    _ok "configs srsRAN posees depuis le depot dans $SRS_DIR"
}

lte_tourne() { pgrep -x "$1" >/dev/null 2>&1; }

lte_start() {
    _root start || return 1
    local enb ue
    enb="$(_bin srsenb)" || { _err "srsenb introuvable (dpkg -i osmo-build-srsran, ou osmo-lte-install --build)"; return 1; }
    ue="$(_bin srsue)"   || { _err "srsue introuvable"; return 1; }
    for p in srsenb srsue; do
        lte_tourne "$p" && { _err "$p tourne deja (pid $(pgrep -x "$p" | head -1)) - « $0 restart » pour repartir propre"; return 1; }
    done
    _configs || return 1
    _verifier_sib || return 1
    # the desktop follows: the antenna rises in the wallpaper (tools/osmo-fond.py
    # re-runs itself under the desktop user; the return to the city, at stop,
    # is done by osmo-panel.py when nothing runs any more)
    [ -x "$REPO/tools/osmo-fond.py" ] && ("$REPO/tools/osmo-fond.py" antenne >/dev/null 2>&1 &)
    ip netns list 2>/dev/null | grep -qw "$NETNS" || { ip netns add "$NETNS" && _ok "espace reseau $NETNS cree"; }

    # The "[n/4]" markers: the desktop launch window (tools/osmo-gtk-run.py
    # --progress) uses them as its progress bar.
    echo "[1/4] coeur Open5GS"
    # The core: Open5GS, through osmo-epc (idempotent: what already runs stays).
    "$EPC" start | sed 's/^/  /'
    for _ in $(seq 1 20); do ss -Sln 2>/dev/null | grep -q "$MME_S1:36412 " && break; sleep 0.25; done
    ss -Sln 2>/dev/null | grep -q "$MME_S1:36412 " && _ok "MME : S1 en ecoute sur $MME_S1" \
        || _warn "MME : le S1 n ecoute pas sur $MME_S1 (voir « osmo-epc status », osmo-epc log mme)"

    export HOME=/root                      # srs* lisent ~/.config/srsran : celui de root
    cd "$SRS_DIR" || return 1              # sib.conf & co. relatifs, et le .ctxt de srsue
    rm -f .ctxt                            # un vieux contexte fait echouer l attach apres un redemarrage du coeur

    # The traces: nothing at all when GUI=0 - the normal mode is intact.
    local -a gui_opt=()
    [ "$GUI" = 1 ] && gui_opt=(--gui.enable=1)
    local -a enb_rf=() ue_rf=()
    if [ -n "$SRATE" ]; then
        enb_rf=(--rf.device_name=zmq --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:$ZMQ_ENB,rx_port=tcp://localhost:$ZMQ_UE,id=enb,base_srate=$SRATE")
        ue_rf=(--rf.device_name=zmq --rf.device_args="tx_port=tcp://*:$ZMQ_UE,rx_port=tcp://localhost:$ZMQ_ENB,id=ue,base_srate=$SRATE")
    fi
    echo "[2/4] station de base srsENB"
    # The eNB, and the UE right behind: see trap no. 1.
    setsid "$enb" "$SRS_DIR/enb.conf" "${enb_rf[@]}" "${gui_opt[@]}" \
        --log.filename="$LOGDIR/osmo-lte-enb.log" >"$LOGDIR/osmo-lte-enb.console" 2>&1 </dev/null &
    sleep 0.5
    echo "[3/4] mobile srsUE"
    setsid "$ue" "$SRS_DIR/ue.conf" "${ue_rf[@]}" "${gui_opt[@]}" \
        --gw.netns="$NETNS" --log.filename="$LOGDIR/osmo-lte-ue.log" >"$LOGDIR/osmo-lte-ue.console" 2>&1 </dev/null &
    _ok "srsENB puis srsUE lances (ZeroMQ $ZMQ_ENB/$ZMQ_UE, UE dans $NETNS${SRATE:+, base_srate $SRATE})${gui_opt:+ ${GREEN}avec les traces srsGUI sur $DISPLAY${NC}}"

    echo "[4/4] attach du mobile"
    _say "attente de l attach (30 s max)..."
    local i ip
    for i in $(seq 1 60); do
        ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
        [ -n "$ip" ] && break
        sleep 0.5
    done
    if [ -n "$ip" ]; then
        _ok "UE attache : $ip (tun_srsue dans $NETNS) en $((i / 2)) s"
    else
        _err "pas d attach en 30 s - voir $LOGDIR/osmo-lte-ue.console et « $0 status »"
        grep -E "Found|Attach|fail|Reject" "$LOGDIR/osmo-lte-ue.console" | tail -4 | sed 's/^/      /'
        return 1
    fi
}

lte_stop() {
    _root stop || return 1
    local p n=0
    for p in srsue srsenb; do
        if lte_tourne "$p"; then pkill -x "$p"; n=$((n + 1)); fi
    done
    sleep 2
    for p in srsue srsenb; do lte_tourne "$p" && pkill -9 -x "$p"; done
    [ "$n" -gt 0 ] && _ok "$n processus srs* arrete(s)" || _say "rien ne tournait"
    # The S1 takes a moment to close on the SCTP side; the next eNB needs it.
    sleep 1
}

lte_status() {
    echo -e "\033[1msrsRAN sur ZeroMQ + Open5GS - la 4G du banc\033[0m"
    local p
    for p in open5gs-mmed srsenb srsue; do
        lte_tourne "$p" && _ok "$p : pid $(pgrep -x "$p" | head -1)" || _warn "$p : arrete"
    done
    ss -San 2>/dev/null | grep -q "ESTAB.*:36412" && _ok "S1 : eNB associe au MME" || _warn "S1 : pas d association eNB-MME"
    # The eNB -> UE samples leave from the local socket :$ZMQ_ENB of the eNB
    # (bytes_sent); what it RECEIVES is only the UE requests.
    local a b
    a="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
    if [ -n "$a" ]; then
        sleep 1
        b="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
        local ko=$(( (${b:-0} - a) / 1024 ))
        if [ "$ko" -gt 100 ]; then _ok "ZeroMQ : $ko Ko/s d echantillons eNB -> UE"
        else _warn "ZeroMQ : $ko Ko/s - la radio de l eNB est morte (fail_on_disconnect) : « $0 restart »"; fi
    else
        _warn "ZeroMQ : aucun lien eNB <-> UE"
    fi
    local ip
    ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
    [ -n "$ip" ] && _ok "UE : attache, $ip dans $NETNS" || _warn "UE : pas attache (pas de tun_srsue dans $NETNS)"
}

case "${1:-status}" in
    start|stop|restart) _eleve "$@" ;;      # hors root : on repasse ici en root
esac
case "${1:-status}" in
    start)   lte_start ;;
    start-gui|gui|start-display)
        # The traces mode: root WITH the screen, then the normal launch + GUI=1.
        _root_avec_display || exit 1
        _display_ou_rien || exit 1
        GUI=1
        lte_start ;;
    traces|gui-seul)
        # The traces without restarting the whole 4G: only the radio restarts
        # with srsGUI; lte_start leaves the core as is (osmo-epc start is
        # idempotent). Started outside the unit: "osmo-lte down" / the icon
        # know how to stop a radio started this way (_svc_root).
        _root_avec_display traces || exit 1
        _display_ou_rien || exit 1
        GUI=1
        if lte_tourne srsenb || lte_tourne srsue; then
            _say "radio relancee avec les traces srsGUI - le coeur Open5GS reste debout"
            lte_stop
        fi
        lte_start ;;
    stop)    lte_stop ;;
    restart) lte_stop; lte_start ;;
    status)  lte_status ;;
    log)     exec tail -F "$LOGDIR"/osmo-lte-{enb,ue}.console ;;
    toggle|bascule) _svc toggle ;;
    _svc-root) _root _svc-root || exit 1; _svc_root "$2" ;;
    up)      _svc start ;;
    down)    _svc stop ;;
    journal) exec journalctl -u "$SVC" -f --no-pager ;;
    install) shift; exec bash "$REPO/tools/osmo-lte-install.sh" "$@" ;;
    *)       sed -n '/^#   osmo-lte start/,/^#   osmo-lte install/p' "$0" | sed 's/^# \{0,2\}//'; exit 2 ;;
esac
