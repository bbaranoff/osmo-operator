# 13-adresses.sh - part of start.sh (pre-start stop, PCU socket, APN NAT,
# private addresses, dashboard, node sheet, oFono modem, SAP)
# Sourced by start.sh in the main shell: same order, same variables.
if [ "$DRY" -eq 0 ] && [ "${CALYPSO_NO_AUTOSTOP:-0}" != 1 ]; then
    say_begin "Arret de la pile avant demarrage"
    banc_dsp_arreter >/dev/null 2>&1 || true
    banc_dsp_arreter_instances
    bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
    declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
    if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
        killall_python -TERM || true
    fi
    # SAP: the softSIM servers (demo_server.rb) and their socket.
    # CALYPSO_STOP_KILL_SOFTSIM=0 disables it.
    if [ "${CALYPSO_STOP_KILL_SOFTSIM:-1}" != 0 ]; then
        kill_softsim || true
    fi
    say_end " OK " "$C_OK" "Arret de la pile avant demarrage"
fi

# --- 7sexies. PCU socket (BTS <-> osmo-pcu) ------------------------------------
# The sockets of a previous run stay on disk; the PCU must find the main
# BTS socket (/tmp/pcu_bts). The harness removes the orphans before launch and
# prints the state, so that a mute GPRS can be read.
PCU_SOCK_SH="$HERE/network/pcu-socket.sh"
if [ "$DRY" -eq 0 ] && [ -r "$PCU_SOCK_SH" ]; then
    say_begin "Socket PCU"
    if bash "$PCU_SOCK_SH" --fix > "${LOG_DIR:-/tmp}/pcu-socket.log" 2>&1; then
        say_end " OK " "$C_OK" "Socket PCU" "voir ${LOG_DIR:-/tmp}/pcu-socket.log"
    else
        say_end " KO " "$C_KO" "Socket PCU" "suppression d'un orphelin impossible - voir ${LOG_DIR:-/tmp}/pcu-socket.log"
    fi
fi

# --- 7septies. APN Internet egress (NAT apn0 -> routing NIC) -------------------
APN_NAT_SH="$HERE/network/apn-nat.sh"
if [ "$DRY" -eq 0 ] && [ -r "$APN_NAT_SH" ]; then
    say_begin "Sortie Internet APN (NAT)"
    if bash "$APN_NAT_SH" > "${LOG_DIR:-/tmp}/apn-nat.log" 2>&1; then
        say_end " OK " "$C_OK" "Sortie Internet APN" "voir ${LOG_DIR:-/tmp}/apn-nat.log"
    else
        say_end " KO " "$C_KO" "Sortie Internet APN" "voir ${LOG_DIR:-/tmp}/apn-nat.log"
    fi
fi

# --- 8. launch: exec run.sh ---------------------------------------------------
# ── THE ADDRESSES THE CONFIGS REQUIRE MUST EXIST ────────────────────────────
# A daemon that binds to an absent address does not start, and says so in ITS
# log, not ours:
#     osmo-ggsn: "gtp bind-ip 192.168.2.10" -> address not found locally
#     osmo-sgsn: "listen 192.168.2.10 23000" -> same
# These addresses come from the template generator (op_private_ip), not from
# the network: nothing else sets them.
#
# osmo-ip-plan.sh EXTRACTS them from the configs rather than recomputing them
# (the plan may come from another generator), picks the NIC that really
# provides Internet, and falls back to loopback when none leads anywhere. It
# does nothing in an image of this repo (OSMO_IMAGE=1): there, start-docker.sh
# / compose does the addressing. Any other container is treated as native.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    IPPLAN="$HERE/network/osmo-ip-plan.sh"
    if [ -r "$IPPLAN" ]; then
        say_begin "Adresses privees du noeud"
        _ipout="$(OSMOCOM_CFG="${OSMOCOM_CFG:-/etc/osmocom}" \
                  OSMO_WAN_NODE="${NODE_ID:-${OSMO_WAN_NODE:-}}" \
                  bash "$IPPLAN" --apply 2>&1)" || true
        say_end " OK " "$C_OK" "Adresses privees du noeud" \
            "$(printf '%s' "$_ipout" | tail -1 | sed 's/^osmo-ip-plan : //')"
    fi
fi

# ── THE DASHBOARD RESTARTS WITH THE BENCH ────────────────────────────────────
# Symmetric to the `stop)` action: the unit is PartOf=osmo-banc.service, but a
# direct launch does not go through osmo-banc, so it is restarted here. The
# dashboard also serves /psd, which tools/osmo-fft-snap.py polls for the
# wallpaper FFT. (fft-web/fft_web.py serves 8081: another server, not
# concerned by this block.)
# --no-block, as at stop: do not block on systemd. `restart` rather than
# `start`: an instance surviving from a previous run is taken over instead
# of serving the previous state.
# CALYPSO_NO_DASHBOARD=1 disables this start.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ] && [ "${CALYPSO_NO_DASHBOARD:-0}" != 1 ]; then
    say_begin "Tableau de bord (:8080)"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl --no-block restart osmo-egprs-web.service 2>/dev/null; then
            say_end " OK " "$C_OK" "Tableau de bord (:8080)" "osmo-egprs-web.service"
        else
            say_end " -- " "$C_KO" "Tableau de bord (:8080)" "unite absente ou refusee"
        fi
    elif [ -r /opt/GSM/osmo-egprs-web/server.js ] && command -v node >/dev/null 2>&1; then
        # Without systemd (container): direct launch, as osmo-launch.sh does.
        pkill -f "osmo-egprs-web/server.js" 2>/dev/null || true
        ( cd /opt/GSM/osmo-egprs-web && setsid node server.js \
            >>"${LOG_DIR:-/tmp}/web-dashboard.log" 2>&1 </dev/null & )
        say_end " OK " "$C_OK" "Tableau de bord (:8080)" "node server.js"
    else
        say_end " -- " "$C_KO" "Tableau de bord (:8080)" "ni systemd ni node/server.js"
    fi
fi

# ── THE NODE SHEET: THE RESULT OF THE RUN ────────────────────────────────────
# /etc/osmocom/mynode<N>.conf (network/node-conf.sh): what another node must
# know to reach this one (--wan mynode<N>.conf). Written here, once the SS7
# identity, the address and the prefix are definitively set.
# start-multi.sh rewrites it once the containers are up (--gen-conf).
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    . "$HERE/network/wan-nodes.sh" 2>/dev/null
    . "$HERE/network/node-conf.sh" 2>/dev/null
    _nc_node="${NODE_ID:-${WAN_NODE_ID:-}}"; [[ "${_nc_node:-0}" =~ ^[1-9]$ ]] || _nc_node=1
    [ "${WAN_NODE_COUNT:-0}" -gt 0 ] || wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
    _nc_out="$(node_conf_path "$_nc_node")"
    if node_conf_write "$_nc_out" "$_nc_node" "${NODE_OP:-1}" "${HUB_IP:-${OSMO_HUB_IP:-}}" 2>/dev/null; then
        say_end " OK " "$C_OK" "Fiche du noeud $_nc_node" "$_nc_out  (pour un autre noeud : --wan $(basename "$_nc_out"))"
    else
        say_end " -- " "$C_DIM" "Fiche du noeud" "non ecrite ($_nc_out)"
    fi
fi

# ── THE MOBILE LINK: oFONO = THE BENCH MODEM ────────────────────────────────
# The bench phone - the postmarketOS/Phosh VM - is the SAME subscriber as the
# osmocom-bb mobile: 100101. Its ModemManager only talks to an AT modem; this
# bench has no dongle, so the modem is written here. The VM connects directly
# to osmo-phonesim-banc.py (--connect mode, see tools/osmo-pmos.sh); oFono
# remains useful to the host - it provides osmo-call and osmo-sms-send, and a
# second AT modem for debugging.
#
#   tools/osmo-phonesim-banc.py   the bench AT modem, oFono side (TCP 12345,
#                                 phonesim plugin). It reads the network on
#                                 the osmo-bsc VTY, sends SMS through the
#                                 osmo-msc VTY, places calls through Asterisk,
#                                 and receives SMS as an SMPP ESME (port 2775).
#   tools/osmo-ril-atmodem.py     the AT modem that rild consumes, backed by
#                                 oFono. It publishes its pty in
#                                 /run/osmo-ril/at-pty.
#
# None of this is essential to the bench: if oFono is missing, say so and
# continue. The bench must start even without the Android phone.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ] && [ "${OSMO_RACCORD_MOBILE:-1}" = "1" ]; then
    say_begin "Raccord mobile (oFono)"
    _rm_detail=""
    if ! command -v ofonod >/dev/null 2>&1; then
        say_end " -- " "$C_DIM" "Raccord mobile (oFono)" "ofono absent - ignore"
    else
        # 1. oFono must know where to find the bench modem.
        if ! grep -q '^\[osmo\]' /etc/ofono/phonesim.conf 2>/dev/null; then
            printf '\n[osmo]\nAddress=127.0.0.1\nPort=12345\n' >> /etc/ofono/phonesim.conf
            _rm_detail="phonesim.conf pose"
        fi
        # 2. the AMI account: the modem originates calls through it (the
        #    Asterisk CLI has no "channel originate" here, the module
        #    res_clioriginate is not loaded - modules.conf is autoload=no).
        if [ -d /etc/asterisk/manager.d ] && [ ! -f /etc/asterisk/manager.d/osmo.conf ]; then
            install -m640 "$HERE/configs/manager-osmo.conf" \
                /etc/asterisk/manager.d/osmo.conf 2>/dev/null && \
                { chown asterisk:asterisk /etc/asterisk/manager.d/osmo.conf 2>/dev/null || true; }
            asterisk -rx "manager reload" >/dev/null 2>&1 || true
            _rm_detail="${_rm_detail:+$_rm_detail, }compte AMI pose"
        fi
        # 3. the bench modem, THEN oFono (the order matters: ofonod looks for
        #    the modem at startup and does not come back to it on its own).
        pgrep -f "$HERE/tools/osmo-phonesim-banc.py" >/dev/null 2>&1 || \
        # LAUNCHED OUTSIDE THE JOB TABLE.
        # `setsid` detaches the SESSION, not the job: bash would keep these
        # helpers in its table and report their death ("line NNNN: <pid>
        # Killed setsid ...") over the prompt after a --stop. `disown` is not
        # reliable in a non-interactive shell. The subshell is: bash sees only
        # IT as a job, it returns immediately with 0, and the grandchild is
        # adopted by init - nobody watches or signals it any more.
        # `</dev/null` as well: none of these helpers reads the terminal.
        # THE MOBILE VTY IS NOT ALWAYS 4247.
        # osmo-phonesim-banc.py falls back to OSMO_MOB_VTY_PORT=4247, the value
        # of /root/.osmocom/bb/mobile.cfg. In --dsp the running mobile is the
        # bench's (mobile_pont.cfg, VTY 4347): pass it the port actually
        # bound, read from the file.
            ( setsid env OSMO_MOB_VTY_PORT="${_ms1_vty:-4247}" \
                  "$HERE/tools/osmo-phonesim-banc.py" \
                  </dev/null >>/tmp/osmo-phonesim.log 2>&1 & )
        sleep 1
        systemctl restart ofono >/dev/null 2>&1 || true
        sleep 3
        # 4. power the modem on: oFono leaves it off until asked.
        /usr/bin/python3 - <<'PYON' >/dev/null 2>&1 || true
from gi.repository import Gio, GLib
import time
c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
for prop in ("Powered", "Online"):
    try:
        c.call_sync("org.ofono", "/osmo", "org.ofono.Modem", "SetProperty",
                    GLib.Variant("(sv)", (prop, GLib.Variant("b", True))),
                    None, Gio.DBusCallFlags.NONE, 25000, None)
    except GLib.Error:
        pass
    time.sleep(2)
PYON
        # 5. the virtual AT modem (the pty a RIL consumes, or a debugging
        #    modem for tools/at-cmd.py).
        #    /usr/bin/python3 HARD-CODED, not the "env python3" shebang: the
        #    bench PATH puts the venv (/root/.env/bin) first, whose interpreter
        #    has no GObject bindings; PyGObject is installed SYSTEM-side. Same
        #    reason as the PYON block above.
        pgrep -f "$HERE/tools/osmo-ril-atmodem.py" >/dev/null 2>&1 || \
        # LAUNCHED OUTSIDE THE JOB TABLE.
        # `setsid` detaches the SESSION, not the job: bash would keep these
        # helpers in its table and report their death ("line NNNN: <pid>
        # Killed setsid ...") over the prompt after a --stop. `disown` is not
        # reliable in a non-interactive shell. The subshell is: bash sees only
        # IT as a job, it returns immediately with 0, and the grandchild is
        # adopted by init - nobody watches or signals it any more.
        # `</dev/null` as well: none of these helpers reads the terminal.
            ( setsid /usr/bin/python3 "$HERE/tools/osmo-ril-atmodem.py" \
                  </dev/null >>/tmp/osmo-ril.log 2>&1 & )
        sleep 1
        if pgrep -f "$HERE/tools/osmo-phonesim-banc.py" >/dev/null 2>&1; then
            say_end " OK " "$C_OK" "Raccord mobile (oFono)" \
                "modem /osmo${_rm_detail:+ - $_rm_detail} ; pty RIL : /run/osmo-ril/at-pty"
        else
            say_end " -- " "$C_DIM" "Raccord mobile (oFono)" "modem du banc non demarre (cf. /tmp/osmo-phonesim.log)"
        fi
    fi
fi

# ── THE DSP BENCH: MEASURED SETTINGS, THEN HAND-OFF ────────────────────────
# The values come from the bench (c54x_exe/run_real.sh; run.sh documents them
# one by one):
#   INSNS                    instruction budget per frame (see 14-demarrage.sh)
#   LOCKSTEP=1               QEMU only advances the frame once the DSP has
#                            finished the previous one; otherwise QEMU skips
#                            3 frames out of 4
#   IQ=none                  no synthetic cell: the bursts come from the real
#                            BTS, through pont.py
#   CALYPSO_BSP_STREAM=1     one TS0 burst per frame, in FN order
#   CALYPSO_RHEA_DMA_XFER=1  without it the API page is never filled: no SB,
#                            no BCCH, no SI
# Everything stays overridable: only what the operator did not set is set.

# ── SAP: THE SIM SERVED TO THE MOBILE OVER THE SAP SOCKET (--sap) ───────────
# demo_server.rb server of the softSIM repo (/opt/GSM/softsim, Ruby 3.2+ shim:
# File.exists?, Fixnum), launched BEFORE the stack: the mobile (sim sap)
# connects to it at startup and stays (patch 0002: the server serves the next
# client after a disconnection, so a baseband restart needs nothing).
#   type pcsc : the card in the PC/SC reader (HID Omnikey 6121,
#               sysmoISIM-SJA5; gem smartcard). The card must carry the
#               IMSI/Ki of MS#1 (or its subscriber must be in the HLR):
#               tools/osmo-sim.sh verifier.
#   type sim  : the software SIM sim-op1.xml, regenerated at every launch
#               (IMSI of MS#1; COMP128v1 with SOFTSIM_KI = Ki of MS#1, patch 0001).
# In DSP, the running MS#1 is c54x_exe's (mobile_pont.cfg, sim test):
# $BB_DIR/mobile_pont_sap.cfg (sim sap, sap-socket) is derived from it and
# the bench receives it through MOBILE_CFG (SAP_DSP_MOBILE_CFG). Variables:
# SOFTSIM_DIR, SAP_SOCK, SAP_TYPE, SAP_FILE, SAP_LOG, SAP_VERBOSITY, SOFTSIM_KI.
# The python that has pyscard: the pySim venv's (root's PATH starts with
# /root/.env, the bridge venv, without pyscard), otherwise the system's.
sap_python() {
    local p="${PYSIM_VENV:-/opt/GSM/pysim-venv}/bin/python3"
    [ -x "$p" ] || p=/usr/bin/python3
    printf '%s' "$p"
}
sap_carte_presente() {
    "$(sap_python)" - <<'PYSC' 2>/dev/null
import sys
try:
    from smartcard.System import readers
except Exception:
    sys.exit(2)
for r in readers():
    try:
        c = r.createConnection(); c.connect(); c.disconnect(); sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PYSC
}
sap_lecteur() {
    "$(sap_python)" -c 'from smartcard.System import readers; print(str(readers()[0]))' 2>/dev/null | sed "s/ \[.*//"
}
SAP_DSP_MOBILE_CFG=""
start_sap() {
    [ "${SAP_MODE:-0}" = 1 ] || return 0
    local sdir="${SOFTSIM_DIR:-/opt/GSM/softsim}" sock="${SAP_SOCK:-/tmp/osmocom_sap}"
    local log="${SAP_LOG:-/tmp/osmo-sap.log}" type="${SAP_TYPE:-auto}" file="" detail=""
    local shim=/usr/local/share/softsim/ruby_compat.rb
    [ -f "$shim" ] || shim="$HERE/tools/softsim/ruby_compat.rb"
    say_begin "SIM via SAP"
    if [ ! -f "$sdir/src/demo_server.rb" ] || ! command -v ruby >/dev/null 2>&1; then
        say_end " KO " "$C_KO" "SIM via SAP" "softSIM ou ruby absent ($sdir) : sudo $HERE/tools/osmo-sim-install.sh"
        return 1
    fi
    if [ "$type" = auto ]; then
        if sap_carte_presente; then type=pcsc; else type=sim; fi
    fi
    case "$type" in
        pcsc)
            if ! sap_carte_presente; then
                say_end " KO " "$C_KO" "SIM via SAP" "aucune carte dans un lecteur PC/SC (pcscd actif ? Omnikey branche ? tools/osmo-sim.sh lecteur)"
                return 1
            fi
            if ! ruby -e 'require "smartcard"' >/dev/null 2>&1; then
                say_end " KO " "$C_KO" "SIM via SAP" "gem smartcard absent : sudo $HERE/tools/osmo-sim-install.sh"
                return 1
            fi
            detail="carte du lecteur $(sap_lecteur)" ;;
        sim)
            file="${SAP_FILE:-$sdir/src/sim-op1.xml}"
            # the Ki of MS#1, the one 21-abonnes-hlr puts in the HLR (COMP128v1)
            export SOFTSIM_KI="${SOFTSIM_KI:-$(ms_ki 1 | tr -d ' ')}"
            detail="SIM logicielle $file (IMSI $(ms_imsi 1))" ;;
        *)
            say_end " KO " "$C_KO" "SIM via SAP" "SAP_TYPE=$type inconnu (pcsc, sim, auto)"
            return 1 ;;
    esac
    # In DSP: the "sim sap" copy of mobile_pont.cfg, for the bench only.
    if [ "${DSP_BANC:-0}" = 1 ]; then
        local _src="${MOBILE_CFG:-$(dirname "$BANC_DSP")/mobile_pont.cfg}" _dst="$BB_DIR/mobile_pont_sap.cfg"
        if [ -r "$_src" ]; then
            sed -e "s#^\([[:space:]]*\)sim \(test\|reader\)\$#\1sim sap#" \
                -e "s|^\([[:space:]]*\)sap-socket .*|\1sap-socket $sock|" \
                -e "s|^\([[:space:]]*\)stick [0-9]*\$|\1stick ${PLAN_ARFCN:-${ARFCN:-1}}|" "$_src" > "$_dst.tmp" \
                && mv -f "$_dst.tmp" "$_dst"
            grep -q "^[[:space:]]*sap-socket " "$_dst" \
                || sed -i "s|^\([[:space:]]*\)layer2-socket .*|&\n\1sap-socket $sock|" "$_dst"
            SAP_DSP_MOBILE_CFG="$_dst"
            detail="$detail ; MS#1 $_dst"
        else
            say_end " KO " "$C_KO" "SIM via SAP" "config du MS#1 du banc DSP illisible : $_src"
            return 1
        fi
    fi
    if [ $DRY -eq 1 ]; then
        say_end " -- " "$C_DIM" "SIM via SAP" "dry-run : type $type, ruby -r$shim demo_server.rb --unix $sock${file:+ --file $file} ($detail)"
        return 0
    fi
    # sim-op1.xml is regenerated at every launch: the server rewrites it at
    # every client disconnection, and an old file would keep the previous
    # ICCID / PLMN.
    if [ "$type" = sim ] && [ -z "${SAP_FILE:-}" ] && [ -f "$sdir/src/sim.xml" ] && [ -f "$HERE/tools/softsim/make_sim_op1.py" ]; then
        python3 "$HERE/tools/softsim/make_sim_op1.py" "$sdir/src/sim.xml" "$sdir/src/sim-op1.xml" \
            --imsi "$(ms_imsi 1)" >/dev/null 2>&1 || true
        [ -f "$file" ] || file="$sdir/src/sim.xml"
    fi
    rm -f "$sock"
    local args=(--type "$type" --socket unix --unix "$sock" --verbosity "${SAP_VERBOSITY:-3}")
    [ "$type" = sim ] && args+=(--file "$file")
    ( cd "$sdir/src" && nohup ruby -r"$shim" demo_server.rb "${args[@]}" >"$log" 2>&1 & )
    for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.2; done
    if [ -S "$sock" ]; then
        say_end " OK " "$C_OK" "SIM via SAP" "type $type : $detail ; socket $sock, journal $log"
    else
        say_end " KO " "$C_KO" "SIM via SAP" "pas de socket $sock : voir $log"
        return 1
    fi
}
start_sap || { echo "SAP demande (--sap) mais non lance" >&2; exit 1; }

