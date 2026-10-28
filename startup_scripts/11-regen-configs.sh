# 11-regen-configs.sh - part of start.sh (--regen: native regeneration of
# /etc/osmocom and /etc/asterisk, node identity before the WAN)
# Sourced by start.sh in the main shell: same order, same variables.
regen_configs_natif() {
    local node="$1" op="$2" hub="$3"
    local tmp rc=0

    # ── The NATIVE plan, the one of build-iso.sh, not docker's ──────────────
    # 127.0.0.2 (__CONTAINER_IP__) carries the core: GGSN, SGSN, UPF, the BSC
    # nsvc. A loopback address ALWAYS exists and is ready before any service;
    # a NIC address may be missing when osmo-ggsn binds, and the bind fails
    # with no visible relation to the network.
    # 127.0.0.1 (__GATEWAY_IP__) receives the gsmtap, where tshark captures.
    local core_ip="${OSMO_NATIVE_CORE_IP:-127.0.0.2}"
    local gw_ip="${OSMO_NATIVE_GW_IP:-127.0.0.1}"

    # ── The identity FOLLOWS THE NODE ───────────────────────────────────────
    # 1.<node><op>.<role>, the plan of network/set-node-id.sh and of
    # build-iso.sh --node. Without the node in the point code, three machines
    # attached to the same hub would present 1.11.2 three times: a point code
    # is an ADDRESS, and two devices sharing one give silent, wrong routing.
    # The routing context follows the same rule: it is what the hub reads to
    # tell the ASs apart, and the local formula (op*100+50) yields the same
    # value on every node.
    # WAN plan only when there is a WAN (--wan, --wan-nodes). A single host
    # keeps the LOCAL plan 1.<op>.<role>, like set-node-id.sh --local at
    # startup.
    local mid="${node}${op}" wan_plan=0
    if [ "${WAN_MESH:-0}" = "1" ] || [ -n "${WAN_NODES:-}" ]; then wan_plan=1; else mid="$op"; fi
    local pc_msc="1.${mid}.1" pc_stp="1.${mid}.2" pc_bsc="1.${mid}.3"
    local shut="shutdown"
    [ -n "$hub" ] && shut="no shutdown"

    # ── The PLMN: the machine's, not the table's ────────────────────────────
    # Re-read from the installed osmo-msc.cfg. Taking the globals.conf
    # defaults would rename the network at every regeneration, and a mobile
    # already provisioned would no longer recognise its cell.
    local cfgdir="${OSMOCOM_CFG:-/etc/osmocom}"
    local mcc mnc opname
    mcc="$(awk '/^ *network country code /{print $4; exit}' "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    mnc="$(awk '/^ *mobile network code /{print $4; exit}'  "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    opname="$(awk '/^ *short name /{print $3; exit}'        "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    [ -n "$mcc" ]    || mcc="${MCC:-001}"
    [ -n "$mnc" ]    || mnc="${MNC:-01}"
    [ -n "$opname" ] || opname="${OP_NAME:-OsmoGSM}"

    # The number of MS comes from coeur.env, written by build-iso.sh: it says
    # how many subscribers the HLR provisions, hence how many SMS routes are
    # needed. Beyond that, the relay returns "No route for destination".
    local n_ms="${N_MS:-}"
    if [ -z "$n_ms" ] && [ -r "$cfgdir/coeur.env" ]; then
        n_ms="$(awk -F'[:=}]' '/N_MS:=/{print $3; exit}' "$cfgdir/coeur.env" 2>/dev/null)"
    fi
    [ -n "$n_ms" ] || n_ms=2

    printf '  %splan natif%s coeur %s  gsmtap %s  PC %s  rctx %s  PLMN %s-%s (%s)  %s MS\n' \
        "${C_DIM:-}" "${C_Z:-}" "$core_ip" "$gw_ip" "$pc_stp" \
        "$(( node * 1000 + op * 100 + 50 ))" "$mcc" "$mnc" "$opname" "$n_ms"

    tmp="$(mktemp -d)" || return 1

    # ── The backup, BEFORE writing ──────────────────────────────────────────
    # A regeneration overwrites files that someone may have edited by hand on
    # the bench; the previous state is kept as an archive.
    local sav="${LOG_DIR:-/tmp}/osmocom-avant-regen-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$sav" -C / etc/osmocom etc/asterisk 2>/dev/null && \
        printf '  %ssauvegarde%s %s\n' "${C_DIM:-}" "${C_Z:-}" "$sav"

    (
        cd "$HERE" || exit 1
        # BEFORE sourcing. lib/gabarits.sh pins ENCRYPTION to "a5 0" and
        # HOST_IP to 127.0.0.1 with ":=" when they are empty, and gc_load then
        # treats those values as the caller's choice.
        : "${ENCRYPTION:=a5 1}"
        HOST_IP="$core_ip"
        # The routing context and the ASP source address: the two overrides
        # build-iso.sh sets for a WAN node. 0.0.0.0 because the node address
        # comes from DHCP and is not necessarily up when osmo-stp starts -
        # binding to an absent address fails at launch.
        if [ "$wan_plan" = "1" ]; then
            export RCTX_INTER_OVERRIDE=$(( node * 1000 + op * 100 + 50 ))
        else
            export RCTX_INTER_OVERRIDE=$(( op * 100 + 50 ))
        fi
        export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
        # _apply_node_ss7_addressing (called at the end of
        # apply_config_templates) only replays set-node-id.sh if it knows WHO
        # it serves, and it reads that only here.
        export OSMO_ROLE=operator OSMO_WAN_NODE="$node"
        [ -n "$hub" ] && export OSMO_HUB_IP="$hub"
        unset OSMO_NO_REGEN

        # shellcheck source=lib/gabarits.sh
        . "$HERE/lib/gabarits.sh" || exit 1

        apply_config_templates "$tmp" \
            "$core_ip" "$gw_ip" \
            "$op" "$pc_msc" "$pc_stp" "$pc_bsc" \
            "$mcc" "$mnc" "$opname" \
            "${hub:-127.0.0.1}" "$shut" "1" || exit 1

        # The node and the WAN table: sms-routing.conf takes each node's
        # address from the table, and the MSISDNs (<node>00<operator><rank>)
        # from the node.
        apply_native_post_patches "$tmp" "$op" "$n_ms" "$core_ip" \
            "$node" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1

        # ── bb/ REMOVED on purpose ─────────────────────────────────────────
        # install_configs_native would put $tmp/bb/mobile.cfg over
        # /root/.osmocom/bb/mobile.cfg. That file is already WRITTEN above by
        # generate_mobile_cfg, which alone sets the VTY port, the L1CTL
        # sockets and the ARFCN of EACH mobile. The template is frozen on
        # operator 1: installing it here would put both mobiles on the same
        # ARFCN and the same VTY.
        rm -rf "$tmp/bb"

        install_configs_native "$tmp" "" || exit 1
    ) || rc=1

    rm -rf "$tmp"
    return "$rc"
}

# ── The templates: kept, except with --regen ────────────────────────────────
# By default nothing is touched: in a container, what start-docker.sh has just
# written - node point codes, inter-STP, active ASP - must not be replaced by
# the template values.
if [ "${REGEN_GABARITS:-0}" -eq 1 ]; then
    unset OSMO_NO_REGEN
    printf '  %sgabarits%s   regeneration demandee (--regen)\n' "${C_DIM:-}" "${C_Z:-}"

    # ── REGEN: STOP FIRST ───────────────────────────────────────────────────
    # Regenerating /etc/osmocom under a LIVE stack is useless and misleading:
    # the daemons have already read their configuration, keep the old one in
    # memory, and the new files only take effect at the next start. A --regen
    # therefore stops the stack, then regenerates: the state is unambiguous.
    if [ -x "$RUN_SH" ] || [ -r "$RUN_SH" ]; then
        say_begin "Arret de la pile avant regeneration"
        banc_dsp_arreter >/dev/null 2>&1 || true
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
        say_end " OK " "$C_OK" "Arret de la pile avant regeneration"
        declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
        # Same safety net as --stop: an orphan python3 (bridge, fake_trx,
        # trxcon) keeps its port and makes the next start fail on "UDP port
        # 5720 already in use". SCOPE: the bench's python3 only.
        if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
            killall_python -TERM && \
                say_end " OK " "$C_OK" "python3 du banc termines"
        fi
    fi

    # ── THE NODE, 1 BY DEFAULT ──────────────────────────────────────────────
    # A regeneration produces a COMPLETE identity, never a plan "without a
    # node" (without a number, apply_config_templates would yield the
    # template plan - point code 1.1.2 for every machine). So always number:
    # the node resolved above (--node, environment, /etc/osmo-role, WAN
    # table), and 1 when there is none. The configurations follow it: PC
    # 1.<node><op>.<role>, routing context <node>*1000+..., and the private
    # segment 192.168.<node+1>.x.
    REGEN_NODE="${NODE_ID:-1}"
    if ! [[ "$REGEN_NODE" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--regen" "numero de noeud invalide : $REGEN_NODE (1 a 9)"
        exit 2
    fi
    REGEN_OP="${NODE_OP:-1}"
    if ! [[ "$REGEN_OP" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--regen" "numero d'operateur invalide : $REGEN_OP (1 a 9)"
        exit 2
    fi
    # cached_hub is LOCAL to ask_node_identity: the hub is re-read from the
    # environment and /etc/osmo-role here, otherwise the ASP would be left in
    # shutdown after each regeneration.
    REGEN_HUB="${HUB_IP:-${OSMO_HUB_IP:-}}"
    [ -n "$REGEN_HUB" ] || REGEN_HUB="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
        "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"

    say_begin "Regeneration des configurations (noeud $REGEN_NODE, operateur $REGEN_OP)"
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Regeneration des configurations" "dry-run"
    elif regen_configs_natif "$REGEN_NODE" "$REGEN_OP" "$REGEN_HUB"; then
        say_end " OK " "$C_OK" "Regeneration des configurations" \
            "/etc/osmocom + /etc/asterisk  ·  PC $(_pc_affiche "$REGEN_NODE" "$REGEN_OP")"
    else
        say_end " KO " "$C_KO" "Regeneration des configurations" \
            "echec - les fichiers d'avant sont dans ${LOG_DIR:-/tmp}"
        exit 1
    fi

    # ── THE HLR FOLLOWS THE NUMBERING ───────────────────────────────────────
    # A regeneration changes the MSISDNs (<node>00<operator><rank>): those in
    # the HLR date from the previous plan. The IMSI does not move - it does
    # not carry the node, precisely so that the Ki and authentication stay
    # valid. The subscriber step therefore also re-reads the MSISDN
    # (run_modules/21-abonnes-hlr.sh, mod_abonnes_hlr_status) and replays
    # "subscriber ... update msisdn" when it changed.
    #
    # It is also forced here: the stack has just been stopped, the HLR will
    # restart with run.sh, and the step must run even if a state cache
    # believes it already done.
    FORCE=1
    printf '  %sHLR%s        abonnes a reapprovisionner : MSISDN %s..%s\n' \
        "${C_DIM:-}" "${C_Z:-}" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + 1 ))" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + ${N_MS:-2} ))"

    # The chosen node holds for the rest of the launch: it is the one just
    # written into the files. Leaving it empty here would let the "SS7
    # identity" section below resolve differently and overwrite the identity
    # just applied.
    NODE_ID="$REGEN_NODE"
    NODE_OP="$REGEN_OP"
    [ -n "$REGEN_HUB" ] && HUB_IP="${HUB_IP:-$REGEN_HUB}"
    export OSMO_ROLE=operator
    export OSMO_WAN_NODE="$NODE_ID"
    [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
elif [ "${RUNTIME_ENV:-native}" = "docker" ]; then
    # IN A CONTAINER only. The configs are already written there by
    # start-docker.sh, with the node identity: regenerating them would replace
    # them with the template values, and the interconnection would die.
    export OSMO_NO_REGEN=1
else
    # ON A VM without --regen: KEEP what is in place. The ISO generated these
    # files at build time, with the same recipe as regen_configs_natif;
    # redoing them at every start would change nothing and would overwrite
    # any edit made on the bench. --regen exists for that.
    if [ -n "$NODE_ID" ]; then
        export OSMO_ROLE=operator
        export OSMO_WAN_NODE="$NODE_ID"
        [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
    fi
fi

# --- 7ter. Node identity (--node) -----------------------------------------------
# BEFORE the WAN and before run.sh: the point codes are read by osmo-stp,
# osmo-msc and osmo-bsc at their start. Changing them afterwards is useless.
#
# A SINGLE SOURCE OF TRUTH. start-docker.sh already computes a container's
# identity and passes it through the environment; it is reused when present
# rather than recomputed here.
if [ -z "$NODE_ID" ] && [ -n "${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}" ]; then
    NODE_ID="${OSMO_WAN_NODE:-$WAN_NODE_ID}"
    [ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-}"
fi

# No identity while the WAN is requested: do NOT start silently. The stack
# would start with the template point codes (1.1.2 for everybody), two nodes
# would carry the same SS7 address, and no ASP would attach.
# --wan FILE without --node: this node takes the first number the sheets do
# not carry (the sheets say who is already there).
if [ -z "$NODE_ID" ] && [ "${#WAN_IMPORT_FILES[@]}" -gt 0 ]; then
    _used=" $(sed -n 's/^OSMO_NODE_ID=//p' "${WAN_IMPORT_FILES[@]}" 2>/dev/null | tr -d '" ' | tr '\n' ' ') "
    for _cand in 1 2 3 4 5 6 7 8 9; do
        case "$_used" in *" $_cand "*) ;; *) NODE_ID="$_cand"; break ;; esac
    done
    NODE_ID_SRC="premier numero libre d'apres les fiches"
    printf '  %sIdentite%s   noeud %s (%s ; --node N pour choisir)\n' "${C_DIM:-}" "${C_Z:-}" "$NODE_ID" "$NODE_ID_SRC"
fi
if [ -z "$NODE_ID" ] && [ "${WAN_MESH:-0}" -eq 1 ]; then
    say_end " KO " "$C_KO" "Identite SS7" "WAN demande mais aucun noeud : --node N, ou WAN_NODE_ID"
    exit 1
fi

