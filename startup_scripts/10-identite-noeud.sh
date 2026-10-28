# 10-identite-noeud.sh - part of start.sh (list/genconf/stop/status actions,
# node identity prompt, point-code display)
# Sourced by start.sh in the main shell: same order, same variables.
case "$ACTION" in
    list)
        if [ "$DSP_BANC" = 1 ]; then
            printf '  %sbanc DSP%s   %s retire du plan : %s ; %s les reprend (5 etapes)\n' \
                "$C_DIM" "$C_Z" "$RUN_SH" "$DSP_MODULES_RETIRES" "$BANC_DSP"
        fi
        # Without --restart: run.sh keeps the LAST action read, and RUN_ARGS
        # ends with --restart, which would stop and relaunch the stack instead
        # of printing the plan.
        _list_args=()
        for _a in "${RUN_ARGS[@]}"; do [ "$_a" = "--restart" ] || _list_args+=("$_a"); done
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --list "${_list_args[@]}"
        ;;
    genconf)
        # ── THE NODE SHEET, WITHOUT LAUNCHING ───────────────────────────
        # The same one the run writes (just before run.sh): identity resolved
        # as at launch (--node, environment, /etc/osmo-role, WAN table), WAN
        # table re-read if it exists.
        . "$HERE/network/wan-nodes.sh"; . "$HERE/network/node-conf.sh"
        _gc_node="$NODE_ID"
        if [ -z "$_gc_node" ]; then
            _gc="$(detect_node_id)"; _gc_node="${_gc%%|*}"
        fi
        _gc_node="${_gc_node:-1}"
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
        _gc_hub="${HUB_IP:-${OSMO_HUB_IP:-}}"
        [ -n "$_gc_hub" ] || _gc_hub="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role 2>/dev/null | tr -d ' \r')"
        _gc_out="${GEN_CONF_OUT:-$(node_conf_path "$_gc_node")}"
        if node_conf_write "$_gc_out" "$_gc_node" "${NODE_OP:-1}" "$_gc_hub"; then
            say_end " OK " "$C_OK" "Fiche du noeud $_gc_node" "$_gc_out"
            printf '  %ssur un autre noeud :%s  ./start-native.sh --wan %s\n' "${C_DIM:-}" "${C_Z:-}" "$(basename "$_gc_out")"
            exit 0
        fi
        say_end " KO " "$C_KO" "Fiche du noeud" "ecriture impossible : $_gc_out"; exit 1
        ;;
    stop)
        rm -f /run/osmo-banc/ms1-vty /run/osmo-banc/mobile-log 2>/dev/null
        command -v systemctl >/dev/null 2>&1 && systemctl unset-environment OSMO_BB1_VTY_PORT OSMO_MOBILE_LOG 2>/dev/null || true
        say_begin "Arret de la pile via run.sh"
        banc_dsp_arreter          # QEMU, osmocon, mobile, bridge: its job
        banc_dsp_arreter_instances
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE"
        # the softSIM SAP servers (--sap) and their socket
        for _p in $(ps -eo pid,args | awk '/[d]emo_server\.rb/ {print $1}'); do kill -TERM "$_p" 2>/dev/null || true; done
        rm -f "${SAP_SOCK:-/tmp/osmocom_sap}" 2>/dev/null; unset _p
        say_end " OK " "$C_OK" "Arret de la pile via run.sh"
        purge_sessions_tmux
        # ── THE DASHBOARD, OPTIONALLY STOPPED WITH THE BENCH ─────────────
        # Neither run.sh --stop nor the tmux purge know the dashboard (a node
        # server, WantedBy=multi-user.target), and killall_python does not see
        # it. PartOf=osmo-banc.service covers `systemctl stop|restart
        # osmo-banc`; this covers the direct call, used by the desktop
        # "Arreter" button, launch.sh --stop and start-multi.sh --stop.
        # --no-block: do not wait for systemd, and never block when this stop
        # is itself the ExecStop of osmo-banc.
        # By default the dashboard (:8080) stays online with the bench
        # stopped; CALYPSO_DASHBOARD_SUIT_BANC=1 stops it with the bench.
        if [ "${CALYPSO_DASHBOARD_SUIT_BANC:-0}" != 1 ]; then
            :
        elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            systemctl --no-block stop osmo-egprs-web.service 2>/dev/null || true
        else
            pkill -f "osmo-egprs-web/server.js" 2>/dev/null || true
        fi
        # Same safety net as run.sh, applied here too: this script can stop
        # the stack without going through the other, and an orphan
        # fake_trx.py is enough to make the next run fail on "UDP port 5720
        # already in use". Repeating it costs nothing and covers the case
        # where RUN_SH is missing or exits with an error.
        # SCOPE: the BENCH's python3 only (see killall_python).
        # CALYPSO_STOP_KILL_PYTHON=0 disables it.
        if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
            if killall_python -9; then
                say_end " OK " "$C_OK" "python3 du banc termines"
            fi
        fi
        exit 0
        ;;
    status)
        if [ "$DSP_BANC" = 1 ]; then
            printf '\n  %sbanc DSP%s  %s\n' "$C_DIM" "$C_Z" "$BANC_DSP"
            banc_dsp --status
            printf '\n'
        fi
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --status --profile "$CALYPSO_PROFILE"
        ;;
    checkpaths)
        # The DSP bench has no --check-paths: each of its five steps checks
        # its own binary and exits naming what is missing. So show what they
        # will look for, rather than inventing an answer.
        if [ "$DSP_BANC" = 1 ]; then
            printf '  %sbanc DSP%s   %s\n' "$C_DIM" "$C_Z" "$BANC_DSP"
            for f in "$(dirname "$BANC_DSP")/c54x_exe" "$GSM_ROOT/qosmo/build/qemu-system-arm" \
                     "${FIRMWARE_ELF:-$GSM_ROOT/firmware/board/compal_e88/$([ "${OSMO_TRX:-0}" = 1 ] && echo trx || echo layer1).highram.elf}" \
                     "$GSM_ROOT/osmocom-bb/src/host/osmocon/osmocon" \
                     "$([ "${OSMO_TRX:-0}" = 1 ] && echo "$GSM_ROOT/osmocom-bb-transceiver/src/host/layer23/src/transceiver/transceiver" || echo "$HERE/pont/pont_dsp.py")"; do
                [ -e "$f" ] && printf '   OK   %s\n' "$f" || printf '   KO   %s (absent)\n' "$f"
            done
            printf '\n'
        fi
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --check-paths
        ;;
esac
# --- 7bis-menu. What is missing, asked ONCE, with the cache as default --------
# The three values that decide the SS7 identity - node number, operator, hub
# address - are deduced most of the time: environment passed by
# start-docker.sh, /etc/osmo-role frozen in the image, WAN table. When the
# deduction yields nothing, the stack would otherwise keep the template's point
# codes (1.1.2 everywhere, ASP towards 127.0.0.1) and the interconnection
# would be dead silently.
#
# So ask - but only for what is missing, proposing what the cache already
# knows. Without a terminal nothing is asked: the defaults apply, an ISO that
# boots on its own cannot stay blocked on a question.
ask_node_identity() {
    # NO_MENU=1 is what start-docker.sh sets in front of the launcher when
    # the choices were already made on the host. The tty guard just below
    # covers it today (start-docker.sh launches via docker exec -d, without a
    # terminal); this test aligns the SS7 identity on the same convention as
    # the stack menus of start-docker.sh, for an automatic launcher that has
    # a terminal.
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ -t 0 ] || return 0
    [ "$DRY" -eq 1 ] && return 0

    local cached_node cached_src cached_hub
    IFS='|' read -r cached_node cached_src <<< "$(detect_node_id)"

    # THE ENVIRONMENT IS NEVER ASKED FOR. That is how start-docker.sh passes
    # the node to a container: the answer is already known, and in a container
    # where nobody reads the terminal the question would come back empty.
    # NODE_ID and HUB_IP are taken from the environment by the node
    # resolution, much higher up, once - not here.
    cached_hub="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"
    [ -n "$cached_hub" ] || cached_hub="172.20.0.10"

    if command -v whiptail >/dev/null 2>&1; then
        [ -n "$NODE_ID" ] || NODE_ID="$(whiptail --title "Identite du noeud" \
            --inputbox "Numero de ce noeud (1-9)${cached_src:+   [$cached_src]}\nVide = ne pas toucher a l'identite SS7." \
            11 66 "${cached_node:-}" 3>&1 1>&2 2>&3)" || NODE_ID=""
        if [ -n "$NODE_ID" ] && [ -z "$HUB_IP" ]; then
            HUB_IP="$(whiptail --title "Inter-STP" \
                --inputbox "Adresse du hub SS7 (PC 0.0.0)\nVide = laisser le remote-ip deja present." \
                11 66 "$cached_hub" 3>&1 1>&2 2>&3)" || HUB_IP=""
        fi
    else
        if [ -z "$NODE_ID" ]; then
            printf '  Numero de ce noeud (1-9)%s [%s] : ' \
                "${cached_src:+ - $cached_src}" "${cached_node:-aucun}"
            read -r NODE_ID || NODE_ID=""
            [ -n "$NODE_ID" ] || NODE_ID="${cached_node:-}"
        fi
        if [ -n "$NODE_ID" ] && [ -z "$HUB_IP" ]; then
            printf '  Adresse de l inter-STP [%s] : ' "$cached_hub"
            read -r HUB_IP || HUB_IP=""
            [ -n "$HUB_IP" ] || HUB_IP="$cached_hub"
        fi
    fi
}
ask_node_identity

# ══ Configuration regeneration (--regen) ═══════════════════════════════════
# --regen does the same thing as start-docker.sh on the docker side, and as
# build-iso.sh at build time - that is, the full sequence:
#
#   1. apply_config_templates      substitutes configs/*.cfg and *.conf into a
#                                  NEW directory (never in place: a half-done
#                                  substitution on /etc/osmocom leaves a bench
#                                  that no longer starts);
#   2. apply_native_post_patches   the NATIVE recipe of the ISO - sms-routing
#                                  by real MS, SGSN/MSC on the core's local
#                                  address, trimmed run.sh;
#   3. install_configs_native      installs the result into /etc/osmocom and
#                                  /etc/asterisk.
#
# IN A SUBSHELL. lib/gabarits.sh loads globals.conf and sets about thirty
# variables - MCC, ARFCN, HOST_IP, N_OPERATORS, KI... - which carry a
# different meaning here (HOST_IP is the bench address for the launcher, the
# core's internal address for the templates). Letting them leak would change
# the radio plan of a run because a regeneration was requested.
#
#   $1 node number   $2 operator number   $3 inter-STP (may be empty)
# ── THE DISPLAYED POINT CODE FOLLOWS THE PLAN ACTUALLY APPLIED ──────────────
# set-node-id.sh receives --local outside WAN and writes 1.<op>.x; the WAN
# plan between machines is 1.<node><op>.x. The banner uses the same rule so
# that it never announces a plan other than the one applied.
_pc_affiche() {   # $1 = node, $2 = operator
    if [ "${WAN_MESH:-0}" != "1" ] && [ -z "${WAN_NODES:-}" ]; then
        printf '1.%s.x' "$2"          # local plan, the one applied
    else
        printf '1.%s%s.x' "$1" "$2"   # WAN plan, between machines
    fi
}

