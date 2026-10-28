# 12-pcap-softsim.sh - part of start.sh (SS7 node identity, WAN mesh,
# inter-STP hub, local-ip of the ASP, tcpdump ring wrapper, softSIM stop)
# Sourced by start.sh in the main shell: same order, same variables.
if [ -n "$NODE_ID" ]; then
    if ! [[ "$NODE_ID" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--node" "un chiffre de 1 a 9"; exit 2
    fi
    SETID="$HERE/network/set-node-id.sh"
    if [ ! -r "$SETID" ]; then
        say_end " KO " "$C_KO" "--node" "network/set-node-id.sh absent"; exit 1
    fi
    say_begin "Identite SS7 du noeud $NODE_ID"
    setid_args=(--node "$NODE_ID" --op "$NODE_OP" --mode "$NODE_MODE")
    # ── LOCAL PLAN OUTSIDE THE WAN ──────────────────────────────────────────
    # set-node-id.sh knows two plans: the WAN plan, MID=<node><op>
    # (node 1 / op 2 -> 1.12.2), and the LOCAL plan, MID=<op> (op 2 -> 1.2.2),
    # which is what the hub and the bench topology expect on a single host.
    # The WAN plan only makes sense BETWEEN MACHINES; without a WAN, one
    # machine carries everything and the local plan applies.
    if [ "${WAN_MESH:-0}" != "1" ] && [ -z "${WAN_NODES:-}" ]; then
        setid_args+=(--local)
    fi
    [ -n "$HUB_IP" ] && setid_args+=(--hub-ip "$HUB_IP")
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Identite SS7 du noeud $NODE_ID" "dry-run"
        bash "$SETID" "${setid_args[@]}" --dry-run 2>&1 | sed 's/^/  /'
    elif bash "$SETID" "${setid_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-node-id.log" 2>&1; then
        say_end " OK " "$C_OK" "Identite SS7" "noeud $NODE_ID · PC $(_pc_affiche "$NODE_ID" "$NODE_OP") · mode $NODE_MODE"
        # What was ACTUALLY written, re-read from the file.
        _pc_now="$(awk "/^cs7 instance/{c=1} c && /^ *point-code /{print \$2; exit}" \
                   "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
        _hub_now="$(awk "/asp asp-to-inter/{f=1} f&&/remote-ip/{print \$2; exit}" \
                   "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
        printf "  %sSS7%s        point-code %s   inter-STP %s\n" \
            "${C_DIM:-}" "${C_Z:-}" "${_pc_now:-?}" "${_hub_now:-?}"
    else
        say_end " KO " "$C_KO" "Identite SS7" "voir ${LOG_DIR:-/tmp}/set-node-id.log"
        exit 1
    fi
    # The node number also applies to voice and SMS: it is the same node.
    WAN_NODE_ID="$NODE_ID"
fi

# --- 7bis. N-node WAN ----------------------------------------------------------
# HERE and not later: this process becomes run.sh (exec), there is no later.
# Asterisk is not started yet - setup-wan-mesh.sh sees it, writes the conf and
# restarts nothing; run.sh will start Asterisk with the WAN already in place.
#
# Regarding the templates: natively nothing reinstalls /etc/asterisk at start
# (install_configs_native has no caller from run.sh), so the WAN block written
# here survives run.sh. A template module, if any, must be followed by the
# WAN block, not preceded by it.
if [ -r "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" ] && [ "$WAN_MESH" -eq 0 ]; then
    # Table frozen in the image (ISO built with --wan): WAN_AUTO=1 says
    # "this system IS a node", the option need not be typed again.
    if grep -q '^WAN_AUTO=1' "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null; then
        WAN_MESH=1
        WAN_AUTO_KEEP=1
        printf '  %sWAN%s        table figee dans %s (WAN_AUTO=1)\n' \
            "$C_DIM" "$C_Z" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    fi
fi

# ── ISM PAYLOAD: the SMS text over radio, the rest over IP ────────────────────
# Only at start. Writes (if a backend is given) the [payload] section of
# sms-routing.conf via network/setup-payload-ism.sh, then exports
# PAYLOAD_ISM: the SMS relay (scripts/sms-interop-relay.py) then puts a token
# in the inter-node TCP and carries the text over the ISM radio. Without a
# backend, the section already written by setup-payload-ism.sh is reused.
if [ "${PAYLOAD_ISM:-0}" -eq 1 ] && [ "$ACTION" = "start" ]; then
    PISM_SH="$HERE/network/setup-payload-ism.sh"
    export PAYLOAD_ISM=1
    if [ "$DRY" -eq 1 ]; then
        say_begin "Payload ISM"
        if [ -n "$PAYLOAD_ISM_LINK" ]; then
            printf '  [dry-run] %s --%s%s\n' "$PISM_SH" "$PAYLOAD_ISM_LINK" \
                "$([ "$PAYLOAD_ISM_LINK" = serial ] && echo " ${ISM_SERIAL:-/dev/ttyUSB0}")"
        else
            printf '  [dry-run] section [payload] deja en place (sms-routing.conf)\n'
        fi
        say_end " -- " "$C_DIM" "Payload ISM" "dry-run"
    elif [ -n "$PAYLOAD_ISM_LINK" ]; then
        say_begin "Payload ISM ($PAYLOAD_ISM_LINK)"
        pism_args=("--$PAYLOAD_ISM_LINK")
        case "$PAYLOAD_ISM_LINK" in
            serial) pism_args=(--serial "${ISM_SERIAL:-/dev/ttyUSB0}" --baud "${ISM_SERIAL_BAUD:-9600}") ;;
            fifo)   pism_args=(--fifo --tx "${ISM_TX:-/tmp/osmo_ism_tx}" --rx "${ISM_RX:-/tmp/osmo_ism_rx}") ;;
            exec)   pism_args=(--exec ${ISM_TX_CMD:+--tx-cmd "$ISM_TX_CMD"} ${ISM_RX_CMD:+--rx-cmd "$ISM_RX_CMD"}) ;;
        esac
        if [ -r "$PISM_SH" ] && bash "$PISM_SH" "${pism_args[@]}" \
                > "${LOG_DIR:-/tmp}/payload-ism.log" 2>&1; then
            say_end " OK " "$C_OK" "Payload ISM" "texte des SMS par radio ($PAYLOAD_ISM_LINK), signalisation par IP"
        else
            say_end " KO " "$C_KO" "Payload ISM" "voir ${LOG_DIR:-/tmp}/payload-ism.log ; le relais retombera sur IP"
        fi
    else
        say_begin "Payload ISM"
        if grep -rqs '^\[payload\]' /etc/osmocom/sms-routing.conf 2>/dev/null; then
            say_end " OK " "$C_OK" "Payload ISM" "section [payload] en place (sms-routing.conf)"
        else
            say_end " -- " "$C_DIM" "Payload ISM" "aucune section [payload] : lance d'abord $PISM_SH --serial|--exec|..."
        fi
    fi
fi

# --interstp only applies in the WAN: without --wan, say so.
if [ "$INTERSTP" = "1" ] && [ "$WAN_MESH" -ne 1 ] && [ "$ACTION" = "start" ]; then
    printf '  %s!%s --interstp sans --wan : pas de WAN, pas de hub lance (./start-native.sh --wan --interstp)\n' "${C_KO:-}" "${C_Z:-}" >&2
fi
if [ "$WAN_MESH" -eq 1 ] && [ "$ACTION" = "start" ]; then
    WAN_LIB="$HERE/network/wan-nodes.sh"
    WAN_MESH_SH="$HERE/network/setup-wan-mesh.sh"
    if [ ! -r "$WAN_LIB" ] || [ ! -r "$WAN_MESH_SH" ]; then
        say_end " KO " "$C_KO" "WAN" "network/wan-nodes.sh ou setup-wan-mesh.sh absent"
        exit 1
    fi
    # shellcheck source=network/wan-nodes.sh
    . "$WAN_LIB"
    export WAN_AUTO_SAVE="$WAN_AUTO_KEEP"
    # --regen-conf: start from scratch. The table in place is set aside
    # (never lost silently) then erased, BEFORE any wan_nodes_load: the rest
    # of the block rebuilds it from --wan-nodes, the sheets or the prompt,
    # without dragging along stale peers (PROHIB routes at the STP).
    if [ "$REGEN_WAN_CONF" -eq 1 ]; then
        _wc="${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
        # The backup stays NEXT TO the table: /tmp (LOG_DIR by default) does
        # not survive a reboot, even less on the ISO in RAM.
        _sav="${_wc}.avant-regen-$(date +%Y%m%d-%H%M%S)"
        if [ "$DRY" -eq 1 ]; then
            [ -f "$_wc" ] && printf '  [dry-run] cp -p %s %s && rm -f %s\n' "$_wc" "$_sav" "$_wc"
        elif [ -f "$_wc" ]; then
            # No backup, no erasure: the table is never lost silently.
            if cp -p "$_wc" "$_sav" 2>/dev/null; then
                printf '  %sWAN%s        table mise de cote : %s\n' "$C_DIM" "$C_Z" "$_sav"
                rm -f "$_wc"
            else
                say_end " KO " "$C_KO" "WAN" "--regen-conf : sauvegarde impossible ($_sav), table laissee en place"
                exit 1
            fi
        fi
        printf '  %sWAN%s        table reconstruite de zero (--regen-conf)\n' "$C_DIM" "$C_Z"
        unset _wc _sav
    fi
    # --virtualbox: host-only segment + VM + table, before everything else.
    if [ "$VBOX_INTERCO" -eq 1 ] && [ -z "${WAN_NODES:-}" ]; then
        VB="$HERE/network/setup-vbox-interco.sh"
        [ -r "$VB" ] || { say_end " KO " "$C_KO" "WAN" "network/setup-vbox-interco.sh absent"; exit 1; }
        vb_args=(--host-node "$VBOX_HOST_NODE" --conf "${WAN_CONF_FILE:-/etc/osmo-wan.conf}")
        [ -n "$VBOX_NODES" ] && vb_args+=(--nodes "$VBOX_NODES")
        bash "$VB" "${vb_args[@]}" || exit 1
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        WAN_NODE_ID="$VBOX_HOST_NODE"
    fi

    if [ "${#WAN_IMPORT_FILES[@]}" -gt 0 ]; then
        # ── --wan mynode1.conf: THE TABLE COMES FROM THE SHEETS ─────────────
        # Each ISO writes its sheet at run time (network/node-conf.sh); they
        # are imported over the table in place, this node is added with its
        # local address, and the usual mesh does the rest. No prompt:
        # everything that had to be asked is in the sheets.
        . "$HERE/network/node-conf.sh"
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
        printf '  %sWAN%s        fiches de noeuds :\n' "$C_DIM" "$C_Z"
        for _nf in "${WAN_IMPORT_FILES[@]}"; do node_conf_import "$_nf" || exit 1; done
        [ -n "$NODE_ID" ] || { say_end " KO " "$C_KO" "WAN" "--wan FICHIER exige de connaitre ce noeud (--node N)"; exit 1; }
        WAN_NODE_ID="$NODE_ID"
        node_conf_self "$NODE_ID" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        wan_nodes_parse "$WAN_NODES" || exit 1
    elif [ -n "${WAN_NODES:-}" ]; then
        wan_nodes_parse "$WAN_NODES" || exit 1
        # --node ALREADY SAYS which node this machine is: the same notion as
        # --wan-id, seen from SS7. Using it avoids failing on IP detection
        # when the embedded table is older than the machine - an ISO burnt
        # before the latest addressing plan.
        if [ "${WAN_NODE_ID:-0}" = "0" ] && [ -n "$NODE_ID" ]; then
            WAN_NODE_ID="$NODE_ID"
            printf '  %sWAN%s        noeud %s (repris de --node)\n' "$C_DIM" "$C_Z" "$WAN_NODE_ID"
        fi
        [ "${WAN_NODE_ID:-0}" != "0" ] || wan_nodes_detect_self || {
            printf '  %sWAN%s : aucune IP locale dans la table - passez --wan-id N\n' "$C_KO" "$C_Z"
            printf '  %s      (ou --node N : le numero de noeud vaut pour les deux)%s\n' "$C_DIM" "$C_Z"
            exit 1; }
    else
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
        # An ISO deployed on N machines carries the SAME table: each machine
        # recognises itself by its IP rather than requiring one image per node.
        wan_nodes_detect_self 2>/dev/null || true
        if [ "${WAN_NODE_COUNT:-0}" -lt 1 ] || [ "${WAN_NODE_ID:-0}" = "0" ]; then
            wan_nodes_prompt || exit 1
        fi
        # --node N: this machine IS node N. Its line in the table is reset to
        # the real address, and the table rewritten - without a prompt.
        if [ -n "$NODE_ID" ] && [ "$WAN_MESH" -eq 1 ]; then
            wan_self_refresh "$NODE_ID" "${HUB_IP:-${OSMO_HUB_IP:-}}" || exit 1
        fi
    fi
    wan_nodes_validate || exit 1
    printf '\n'
    wan_nodes_summary
    printf '\n'
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] %s --native --id %s\n' "$WAN_MESH_SH" "$WAN_NODE_ID"
    else
        say_begin "WAN - application de la table"
        # --native / --docker: same distinction as for the point codes.
        if bash "$WAN_MESH_SH" "--$NODE_MODE" --id "$WAN_NODE_ID" \
                --nodes "$(wan_nodes_spec)" --ops 1 \
                --config "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" > "${LOG_DIR:-/tmp}/wan-mesh.log" 2>&1; then
            say_end " OK " "$C_OK" "WAN - noeud $WAN_NODE_ID, indicatif $(wan_local_ind)"
        else
            say_end " KO " "$C_KO" "WAN" "voir ${LOG_DIR:-/tmp}/wan-mesh.log"
        fi
    fi

    # --- 7quater. Standalone inter-STP (SS7 hub of the WAN) -------------------
    # The hub is the only point where the nodes meet in SS7; without it, the
    # ASP of each STP stays in shutdown. Standalone: a separate osmo-stp with
    # its own config (start-interstp.sh), not a bench stack.
    # Who launches it, without launching two:
    #   --interstp       this node, always;
    #   auto (default)   only if the hub address is ALREADY local, or if this
    #                    node is node 1 and nobody answers in M3UA on
    #                    HUB_IP:2908. Two nodes starting together do not each
    #                    take the hub address (duplicate IP).
    #   --no-interstp    never.
    # "Present" is read on the M3UA port (SCTP 2908), not by ping: any host
    # at that address, or a stopped hub, answers the ping.
    INTERSTP_SH="$HERE/launch/start-interstp.sh"
    if [ -z "${HUB_IP:-}" ]; then
        HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"
        # The LAN default only applies to a native node; in a container the
        # hub is on the docker backbone (/etc/osmo-role, or start-interstp.sh).
        [ -n "$HUB_IP" ] || { [ "$NODE_MODE" = native ] && HUB_IP="192.168.1.49"; }
    fi
    _m3ua_ecoute() {   # $1 IP: does a hub answer in M3UA (SCTP) on port 2908?
        python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM,132); s.settimeout(2)
try: s.connect((sys.argv[1],2908)); sys.exit(0)
except Exception: sys.exit(1)' "$1" 2>/dev/null
    }
    if [ "$INTERSTP" != "0" ] && [ -n "${HUB_IP:-}" ] && [ -r "$INTERSTP_SH" ]; then
        hub_local=0; hub_up=0; hub_owned=0
        ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$HUB_IP" && hub_local=1
        _m3ua_ecoute "$HUB_IP" && hub_up=1
        # hub_owned: the address answers the ping but not in M3UA, and is not
        # ours - ANOTHER machine holds it; taking it here would create an IP
        # conflict on the LAN.
        if [ "$hub_up" = 0 ] && [ "$hub_local" = 0 ] && ping -c1 -W1 "$HUB_IP" >/dev/null 2>&1; then hub_owned=1; fi
        lancer=0
        if [ "$INTERSTP" = "1" ]; then lancer=1
        elif [ "$hub_up" = 1 ] && [ "$hub_local" = 0 ]; then lancer=0
        elif [ "$hub_local" = 1 ]; then lancer=1
        elif [ "${WAN_NODE_ID:-0}" = "1" ] && [ "$hub_owned" = 0 ]; then lancer=1
        fi
        if [ "$lancer" = 1 ]; then
            # The nodes with THEIR number (id:ip): a 1,3 table stays 1,3 on the hub.
            ips=""
            for id in "${WAN_NODE_LIST[@]}"; do ips="${ips}${id}:${WAN_IP[$id]} "; done
            if [ "$DRY" -eq 1 ]; then
                printf '  [dry-run] %s --no-save --ops 1 --ip %s --ips "%s"\n' "$INTERSTP_SH" "$HUB_IP" "$ips"
            else
                say_begin "Inter-STP standalone ($HUB_IP)"
                # --no-save: the WAN table of THIS node (WAN_AUTO=1, its number,
                # its prefixes) has just been written by setup-wan-mesh.sh;
                # the hub does not rewrite it.
                if bash "$INTERSTP_SH" --no-save --ops 1 \
                        --ip "$HUB_IP" --ips "$ips" > "${LOG_DIR:-/tmp}/interstp.log" 2>&1; then
                    say_end " OK " "$C_OK" "Inter-STP" "hub $HUB_IP:2908, $WAN_NODE_COUNT noeud(s)"
                else
                    say_end " KO " "$C_KO" "Inter-STP" "voir ${LOG_DIR:-/tmp}/interstp.log"
                fi
            fi
        elif [ "$hub_up" = 1 ]; then
            say_end " -- " "$C_DIM" "Inter-STP" "hub $HUB_IP deja en service (M3UA 2908) - non relance"
        elif [ "$hub_owned" = 1 ]; then
            say_end " KO " "$C_KO" "Inter-STP" "$HUB_IP repond au ping mais pas en SCTP 2908 : lancer start-interstp.sh SUR cette machine-la"
        else
            say_end " -- " "$C_DIM" "Inter-STP" "hub $HUB_IP muet, non lance ici (noeud ${WAN_NODE_ID:-?}, pas le 1) - --interstp pour le forcer"
        fi
    fi

    # --- 7quinquies. SS7 addressing of the node (set_stp_ip.sh) ---------------
    # setup-wan-mesh.sh sets up VOICE and SMS between nodes; it does not touch
    # SS7. Without what follows, the inter-STP ASP would still target
    # 127.0.0.1, in shutdown, and the SS7 interconnection would never come up.
    #
    # set_stp_ip.sh is the only one that writes the three configs, the WAN
    # table and /etc/osmo-role in one go. It gets --no-ip: the local address
    # is already set (DHCP or WAN block above), and --restart would be absurd
    # here since run.sh starts the stack right after, with the corrected files.
    STP_IP_SH="$HERE/set_stp_ip.sh"
    if [ -r "$STP_IP_SH" ] && [ "${WAN_NODE_ID:-0}" != "0" ]; then
        self_ip="${WAN_IP[$WAN_NODE_ID]:-}"
        hub_ip="$HUB_IP"
        [ -n "$hub_ip" ] || hub_ip="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"

        stp_args=(--operator --node "$WAN_NODE_ID" --no-ip --conf-dir "${OSMOCOM_CFG:-/etc/osmocom}")
        [ -n "$self_ip" ] && stp_args+=(--ip "$self_ip")
        [ -n "$hub_ip" ]  && stp_args+=(--hub-ip "$hub_ip")

        if [ "$DRY" -eq 1 ]; then
            printf '  [dry-run] %s %s\n' "$STP_IP_SH" "${stp_args[*]}"
        else
            say_begin "Adressage SS7 - inter-STP ${hub_ip:-?}"
            # </dev/null: automatic call, never interactive (set_stp_ip.sh asks
            # for the hub address when it is missing - here nobody would
            # answer and the launch would hang).
            if bash "$STP_IP_SH" "${stp_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-stp-ip.log" 2>&1; then
                say_end " OK " "$C_OK" "Adressage SS7" "noeud $WAN_NODE_ID -> inter-STP ${hub_ip:-?}"
            else
                # Non fatal: the local stack runs fine without interconnection.
                # SAY it, rather than suggesting a complete WAN.
                say_end " ~~ " "$C_SK" "Adressage SS7" "echec - voir ${LOG_DIR:-/tmp}/set-stp-ip.log"
            fi
        fi
    fi
fi

# --- 7quater-bis. Local SS7 hub (standalone bench) --------------------------
# Outside the WAN, the local STP keeps an ASP "asp-to-inter" towards an
# inter-STP. If that hub's address (remote-ip of asp-to-inter) is carried by
# THIS machine and nothing answers in M3UA (SCTP 2908), it is launched here,
# before run.sh: the STP's ASP attaches to it from its start. Node and
# operator come from the routing-key of as-inter (rctx = node*1000 + op*100 +
# 50). A remote hub is never touched; a local hub already in service is only
# touched if it still carries the nodes of a previous WAN (see below);
# --no-interstp disables, --no-save keeps the WAN table. Same logic as
# tests/modules/33-ss7.sh.
if [ "$ACTION" = "start" ] && [ "$WAN_MESH" -ne 1 ] && [ "$INTERSTP" != "0" ]; then
    _stp_cfg="${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg"
    _hub="$(awk '/^ *asp asp-to-inter /{f=1;next} f&&/^ *remote-ip /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
    _rctx="$(awk '/^ *as as-inter /{f=1;next} f&&/^ *routing-key /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
    if [ -n "$_hub" ] && [[ "$_rctx" =~ ^[0-9]+$ ]] && [ -r "$HERE/launch/start-interstp.sh" ] \
       && ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$_hub"; then
        _noeud=$(( _rctx / 1000 )); _op=$(( (_rctx / 100) % 10 ))
        # A hub still running with the table of a previous WAN declares the
        # ASs of the other nodes (as-n2op1, rctx 2150...), without ASP since
        # those nodes no longer attach, and announces them PROHIB to our STP
        # (dynamic route, re-announced by the hub). Outside the WAN, a local
        # hub carrying routing-keys other than ours is therefore relaunched
        # with our node only.
        _hub_cfg="${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp-interop.cfg"
        _hub_autres="$(awk -v k="$_rctx" '/^ *routing-key /{ if ($2 != k) print $2 }' "$_hub_cfg" 2>/dev/null | tr '\n' ' ')"
        if python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM,132); s.settimeout(2)
s.connect((sys.argv[1],2908))' "$_hub" 2>/dev/null && [ -z "${_hub_autres// }" ]; then
            say_end " -- " "$C_DIM" "Hub SS7 local" "$_hub:2908 deja en service"
        elif [ "$DRY" -eq 1 ]; then
            printf '  [dry-run] start-interstp.sh --ip %s --ops %s --ips "%s:%s" --no-save\n' "$_hub" "$_op" "$_noeud" "$_hub"
        elif [ "$_noeud" -ge 1 ] && [ "$_noeud" -le 9 ] && [ "$_op" -ge 1 ]; then
            if [ -n "${_hub_autres// }" ]; then
                say_begin "Hub SS7 local ($_hub) - table perimee (rctx ${_hub_autres% }), relance avec le noeud $_noeud seul"
            else
                say_begin "Hub SS7 local ($_hub)"
            fi
            if bash "$HERE/launch/start-interstp.sh" --ip "$_hub" --ops "$_op" --ips "$_noeud:$_hub" --no-save \
                    > "${LOG_DIR:-/tmp}/interstp.log" 2>&1 < /dev/null; then
                say_end " OK " "$C_OK" "Hub SS7 local" "$_hub:2908, noeud $_noeud op $_op (rctx $_rctx)"
            else
                say_end " KO " "$C_KO" "Hub SS7 local" "voir ${LOG_DIR:-/tmp}/interstp.log"
            fi
        fi
    fi
fi

# --- 7quater-ter. The ASP local-ip follows the current address ----------------
# The asp-to-inter ASP binds to a local-ip written in osmo-stp.cfg. A DHCP
# lease that changes the node address makes that bind fail silently: as-inter
# stays AS_DOWN. At EVERY start the local address (STP_LOCAL_IP) is recomputed
# and rewritten if it moved, before run.sh starts the stack. In WAN,
# set_stp_ip.sh takes care of it (7quinquies); here, the standalone case.
#   STP_LOCAL_IP = the local leg that routes to the hub (remote-ip of the ASP);
#   if needed (hub unreachable) the OSMO_NODE_IP of mynode<N>.conf (N = node
#   of the routing-key, rctx = node*1000 + op*100 + 50).
if [ "$ACTION" = "start" ] && [ "$WAN_MESH" -ne 1 ]; then
    _stp_cfg="${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg"
    if [ -w "$_stp_cfg" ]; then
        _hub="$(awk '/^ *asp asp-to-inter /{f=1;next} f&&/^ *remote-ip /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
        _lo_now="$(awk '/^ *asp asp-to-inter /{f=1;next} f&&/^ *local-ip /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
        _rctx="$(awk '/^ *as as-inter /{f=1;next} f&&/^ *routing-key /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
        STP_LOCAL_IP=""
        [ -n "$_hub" ] && STP_LOCAL_IP="$(ip route get "$_hub" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
        if [ -z "$STP_LOCAL_IP" ] && [[ "$_rctx" =~ ^[0-9]+$ ]]; then
            _nconf="${OSMOCOM_CFG:-/etc/osmocom}/mynode$(( _rctx / 1000 )).conf"
            [ -r "$_nconf" ] && STP_LOCAL_IP="$(awk -F= '/^OSMO_NODE_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "$_nconf" 2>/dev/null)"
        fi
        if [ -n "$STP_LOCAL_IP" ] && [ "$STP_LOCAL_IP" != "$_lo_now" ]; then
            if [ "$DRY" -eq 1 ]; then
                printf '  [dry-run] osmo-stp.cfg local-ip %s -> %s\n' "${_lo_now:-?}" "$STP_LOCAL_IP"
            else
                say_begin "Adresse SS7 locale"
                # Bounded to the asp-to-inter block: the 127.0.0.x local-ip of
                # the local listener are not touched.
                sed -i "/^ *asp asp-to-inter /,/^ *as /{s/^\( *local-ip *\).*/\1$STP_LOCAL_IP/}" "$_stp_cfg"
                say_end " OK " "$C_OK" "Adresse SS7 locale" "local-ip ${_lo_now:-?} -> $STP_LOCAL_IP"
            fi
        fi
    fi
fi

# --- 7sexies. The tcpdump wrapper ---------------------------------------------
# The GSMTAP capture is launched by run_modules/75-gsmtap.sh, in qosmo:
# another repo, not modified. It writes an UNBOUNDED pcap, and the live root
# being a tmpfs, a busy capture ends up filling the RAM.
#
# The wrapper substitutes a ring. It is also installed by build-iso.sh, but
# an ISO already burnt does not know it, and a live without persistence loses
# it at each reboot: reinstalling it HERE, at every stack start, makes it
# effective without rebuilding or touching qosmo.
#
# TWO TRAPS, TWO COUNTERMEASURES - the whole point of this script:
#   -Z root : with -C/-W, tcpdump creates the next ring members AFTER
#             dropping its privileges. Without it: "Permission denied", and
#             NO capture - whereas without -C it opened the file before.
#   the link: with -C/-W, tcpdump numbers (capture.pcap0, .pcap1...); the
#             exact name requested never exists, and the module's barrier -
#             a "test -s <exact name>" - concludes failure on a running
#             capture. <exact name> -> current member is maintained.
#
# OSMO_NO_PCAP_RING=1 skips the installation.
install_pcap_wrapper() {
    local dst=/usr/local/bin/tcpdump tmp
    [ "${OSMO_NO_PCAP_RING:-0}" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ] || return 0
    command -v tcpdump >/dev/null 2>&1 || return 0
    # The real binary must exist under /usr/bin or /usr/sbin AND be an ELF: a
    # script in its place (see the guard in the wrapper) would make the
    # wrapper recursive. In that case install nothing and say so.
    local real=/usr/bin/tcpdump; [ -x "$real" ] || real=/usr/sbin/tcpdump
    if [ ! -x "$real" ] || [ "$(head -c 2 "$real" 2>/dev/null)" = "#!" ]; then
        printf '  %s!%s pcap : %s n est pas le binaire tcpdump - anneau non arme (apt-get install --reinstall tcpdump)\n' \
            "${C_WARN:-}" "$C_Z" "$real" >&2
        return 0
    fi

    tmp="$(mktemp)" || return 0
    cat > "$tmp" <<'PCAPWRAP'
#!/bin/sh
# tcpdump - osmo-operator wrapper: enforces a ring on file captures.
# Installed by start-native.sh and by build-iso.sh. See their comments.
# Tunable: OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump
# If REAL is itself a script (this wrapper copied over the dpkg binary, see
# iso_modules/52-qemu.sh), exec "$REAL" would loop forever: no capture, and a
# `tcpdump --version` that never returns.
if [ "$(head -c 2 "$REAL" 2>/dev/null)" = "#!" ]; then
    echo "tcpdump (wrapper) : $REAL n'est pas le vrai binaire - reinstallez le paquet tcpdump" >&2
    exit 127
fi

has_w=0; has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Nothing to bound, or the caller already chose its ring: step aside.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# The link watcher. Launched BEFORE the exec: afterwards this process IS
# tcpdump. $$ survives the exec, so it follows its life exactly and stops
# with it.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
PCAPWRAP

    # The wrapper is named "tcpdump" and lives in /usr/local/bin, which
    # precedes /usr/bin: it must therefore NEVER be installed over the real
    # binary, on pain of infinite recursion. Check where the real one points.
    case "$(command -v tcpdump)" in
        "$dst") ;;                       # already the wrapper, replace it
        /usr/bin/tcpdump|/usr/sbin/tcpdump|/bin/tcpdump) ;;
        *) rm -f "$tmp"; return 0 ;;     # unexpected location: do nothing
    esac

    if cmp -s "$tmp" "$dst" 2>/dev/null; then
        rm -f "$tmp"                     # already up to date, nothing to say
    else
        install -m 0755 "$tmp" "$dst" 2>/dev/null \
            && printf '  %spcap%s       anneau de capture arme (%s)\n' \
                 "$C_DIM" "$C_Z" "$dst"
        rm -f "$tmp"
    fi
}
[ "$DRY" -eq 1 ] || install_pcap_wrapper

# --- 7ter. SYSTEMATIC STOP BEFORE START ---------------------------------------
# Every start stops the stack first; otherwise the deferred bridge launcher
# starts from an ambiguous state.
#
# The bridge's barrier waits for osmo-bts-trx to know that ports 5700-5702
# are its own. If a previous run is still running, its osmo-bts-trx is
# already there: the barrier is crossed at once, the bridge binds IN THE
# MIDDLE of run.sh's teardown, which kills it (f:pont/pont.py is in
# _td_patterns) - and nothing relaunches it. The barrier waits for both edges
# (disappearance then appearance), but starting from a stopped stack makes
# the question moot.
#
# It also frees the ports: an orphan fake_trx or trxcon is enough to make the
# next start fail on "UDP port 5720 already in use". The killall covers the
# Python processes the registry does not know.
#
# CALYPSO_NO_AUTOSTOP=1 disables this behaviour.
# SAP: stops the servers launched by start_sap (softSIM demo_server.rb
# processes) and removes the SAP socket. The [d] pattern avoids matching
# itself.
kill_softsim() {
    local p sock="${SAP_SOCK:-/tmp/osmocom_sap}"
    for p in $(ps -eo pid,args | awk '/[d]emo_server\.rb/ {print $1}'); do
        kill -TERM "$p" 2>/dev/null || true
    done
    rm -f "$sock" 2>/dev/null || true
}

