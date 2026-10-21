# 12-pcap-softsim.sh - partie de start.sh (lignes 2391-2943 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
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
    # ── PLAN LOCAL HORS WAN ─────────────────────────────────────────────────
    # [2026-08-31] --local n etait JAMAIS passe. set-node-id.sh prenait donc
    # toujours le plan WAN, MID=<noeud><op> :
    #     noeud 1 / op 2 -> 1.12.2      noeud 1 / op 3 -> 1.13.2
    # alors que le hub et la topologie du banc attendent le plan LOCAL,
    # MID=<op> :
    #     op 2 -> 1.2.2                 op 3 -> 1.3.2
    # Les conteneurs s enregistraient donc en 1.12.2 / 1.13.2 (visible cote hub
    # sous as-rkm-1250 / as-rkm-1350, ACTIFS), pendant que les AS statiques
    # as-op2 / as-op3 attendaient en 1.2.2 / 1.3.2 et restaient AS_DOWN.
    # Consequence : tout le monde attache, personne routable - les routes vers
    # 1.2.2 et 1.3.2 sortaient PROHIB chez le natif. Rien ne signalait le
    # desaccord de plan : les deux cotes avaient raison, chacun dans le sien.
    #
    # Le plan WAN n a de sens qu ENTRE MACHINES. Sans WAN, une seule machine
    # porte tout : c est le plan local qui vaut, et c est deja celui du natif.
    if [ "${WAN_MESH:-0}" != "1" ] && [ -z "${WAN_NODES:-}" ]; then
        setid_args+=(--local)
    fi
    [ -n "$HUB_IP" ] && setid_args+=(--hub-ip "$HUB_IP")
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Identite SS7 du noeud $NODE_ID" "dry-run"
        bash "$SETID" "${setid_args[@]}" --dry-run 2>&1 | sed 's/^/  /'
    elif bash "$SETID" "${setid_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-node-id.log" 2>&1; then
        say_end " OK " "$C_OK" "Identite SS7" "noeud $NODE_ID · PC $(_pc_affiche "$NODE_ID" "$NODE_OP") · mode $NODE_MODE"
        # Ce qui a REELLEMENT ete ecrit, relu dans le fichier. Jusqu'ici il
        # fallait deduire l'identite d'un routing-key pour savoir si elle avait
        # pris - et une regeneration ulterieure pouvait l'effacer sans bruit.
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
    # Le numero de noeud vaut aussi pour la voix et les SMS : c'est le meme noeud.
    WAN_NODE_ID="$NODE_ID"
fi

# --- 7bis. WAN a N noeuds ------------------------------------------------------
# ICI et pas apres : ce processus va devenir run.sh (exec), il n'y a pas d'apres.
# Asterisk n'est pas encore lance - setup-wan-mesh.sh le voit, ecrit la conf et
# ne redemarre rien ; run.sh demarrera Asterisk avec le WAN deja en place.
#
# Sur vis-a-vis des gabarits : en natif rien ne reinstalle /etc/asterisk au
# demarrage (install_configs_native n'a aucun appelant, run_modules/08-gabarits.sh
# n'existe pas), donc le bloc WAN ecrit ici survit a run.sh. Si un module de
# gabarits revient un jour, il faudra rejouer le WAN APRES lui.
if [ -r "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" ] && [ "$WAN_MESH" -eq 0 ]; then
    # Table figee dans l'image (ISO construite avec --wan) : WAN_AUTO=1 dit
    # "ce systeme EST un noeud", on n'oblige pas a retaper l'option.
    if grep -q '^WAN_AUTO=1' "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null; then
        WAN_MESH=1
        WAN_AUTO_KEEP=1
        printf '  %sWAN%s        table figee dans %s (WAN_AUTO=1)\n' \
            "$C_DIM" "$C_Z" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    fi
fi

# ── PAYLOAD ISM : le texte des SMS par radio, le reste par IP ─────────────────
# [2026-10-14] N'intervient qu'au demarrage. Ecrit (si un backend est donne) la
# section [payload] des sms-routing.conf via network/setup-payload-ism.sh, puis
# exporte PAYLOAD_ISM : le relais SMS (scripts/sms-interop-relay.py) met alors un
# jeton dans le TCP inter-noeud et fait voyager le texte sur la radio ISM. Sans
# backend, on reutilise la section deja ecrite par setup-payload-ism.sh.
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

# [2026-10-15, revue] --interstp ne vaut que dans le WAN : sans --wan, il
# etait ignore sans un mot.
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
    # --regen-conf : on repart de zero. La table en place est mise de cote
    # (jamais perdue en silence) puis effacee, AVANT le moindre wan_nodes_load :
    # la suite du bloc la reconstruit depuis --wan-nodes, les fiches ou la
    # question, sans trainer les pairs eteints d'hier (routes PROHIB au STP).
    if [ "$REGEN_WAN_CONF" -eq 1 ]; then
        _wc="${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
        # La sauvegarde reste A COTE de la table : /tmp (LOG_DIR par defaut)
        # ne survit pas a un redemarrage, encore moins sur l'ISO en RAM.
        _sav="${_wc}.avant-regen-$(date +%Y%m%d-%H%M%S)"
        if [ "$DRY" -eq 1 ]; then
            [ -f "$_wc" ] && printf '  [dry-run] cp -p %s %s && rm -f %s\n' "$_wc" "$_sav" "$_wc"
        elif [ -f "$_wc" ]; then
            # Pas de sauvegarde, pas d'effacement : la table n'est jamais perdue en silence.
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
    # --virtualbox : segment host-only + VM + table, avant tout le reste.
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
        # ── --wan mynode1.conf : LA TABLE VIENT DES FICHES ──────────────────
        # [2026-09-04] Chaque ISO ecrit sa fiche au run (network/node-conf.sh) ;
        # on les importe par-dessus la table en place, on s'y ajoute avec
        # l'adresse locale, et le maillage habituel fait le reste. Pas de
        # question : tout ce qu'il fallait demander est dans les fiches.
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
        # --node DIT DEJA quel noeud est cette machine : c'est la meme notion
        # que --wan-id, vue depuis le SS7. S'en servir evite d'echouer sur une
        # detection par IP quand la table embarquee est plus ancienne que la
        # machine - le cas d'une ISO gravee avant le dernier plan d'adressage.
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
        # Une ISO diffusee sur N machines porte la MEME table : chaque machine
        # se reconnait a son IP plutot que d'exiger une image par noeud.
        wan_nodes_detect_self 2>/dev/null || true
        if [ "${WAN_NODE_COUNT:-0}" -lt 1 ] || [ "${WAN_NODE_ID:-0}" = "0" ]; then
            wan_nodes_prompt || exit 1
        fi
        # --node N : cette machine EST le noeud N. Sa ligne dans la table est
        # remise a l'adresse reelle, et la table reecrite - sans question.
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
        # --native / --docker : meme distinction que pour les point codes.
        if bash "$WAN_MESH_SH" "--$NODE_MODE" --id "$WAN_NODE_ID" \
                --nodes "$(wan_nodes_spec)" --ops 1 \
                --config "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" > "${LOG_DIR:-/tmp}/wan-mesh.log" 2>&1; then
            say_end " OK " "$C_OK" "WAN - noeud $WAN_NODE_ID, indicatif $(wan_local_ind)"
        else
            say_end " KO " "$C_KO" "WAN" "voir ${LOG_DIR:-/tmp}/wan-mesh.log"
        fi
    fi

    # --- 7quater. Inter-STP standalone (hub SS7 du WAN) -----------------------
    # Le hub est le seul point ou les noeuds se rejoignent en SS7 ; sans lui,
    # l'ASP de chaque STP reste en shutdown. Standalone : un osmo-stp a part,
    # avec sa propre config (start-interstp.sh), pas une pile du banc.
    # [2026-10-15, revue] Qui le lance, sans en lancer deux :
    #   --interstp       ce noeud, toujours ;
    #   auto (defaut)    seulement si l'adresse du hub est DEJA locale, ou si ce
    #                    noeud est le noeud 1 et que personne ne repond en M3UA
    #                    sur HUB_IP:2908. Deux noeuds qui demarrent ensemble ne
    #                    posent plus chacun l'adresse du hub (IP en double).
    #   --no-interstp    jamais.
    # « Present » se lit sur le port M3UA (SCTP 2908), pas au ping : un hote
    # quelconque a cette adresse, ou un hub arrete, repondaient au ping.
    INTERSTP_SH="$HERE/launch/start-interstp.sh"
    if [ -z "${HUB_IP:-}" ]; then
        HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"
        # Le defaut LAN ne vaut que pour un noeud natif ; en conteneur le hub est
        # sur le backbone docker (/etc/osmo-role, ou start-interstp.sh).
        [ -n "$HUB_IP" ] || { [ "$NODE_MODE" = native ] && HUB_IP="192.168.1.49"; }
    fi
    _m3ua_ecoute() {   # $1 IP : un hub repond-il en M3UA (SCTP) sur le port 2908 ?
        python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM,132); s.settimeout(2)
try: s.connect((sys.argv[1],2908)); sys.exit(0)
except Exception: sys.exit(1)' "$1" 2>/dev/null
    }
    if [ "$INTERSTP" != "0" ] && [ -n "${HUB_IP:-}" ] && [ -r "$INTERSTP_SH" ]; then
        hub_local=0; hub_up=0; hub_owned=0
        ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$HUB_IP" && hub_local=1
        _m3ua_ecoute "$HUB_IP" && hub_up=1
        # hub_owned : l'adresse repond au ping mais pas en M3UA, et n'est pas a nous -- une AUTRE
        # machine la tient ; la poser ici ferait un conflit d'IP sur le LAN (repris d'origin/main).
        if [ "$hub_up" = 0 ] && [ "$hub_local" = 0 ] && ping -c1 -W1 "$HUB_IP" >/dev/null 2>&1; then hub_owned=1; fi
        lancer=0
        if [ "$INTERSTP" = "1" ]; then lancer=1
        elif [ "$hub_up" = 1 ] && [ "$hub_local" = 0 ]; then lancer=0
        elif [ "$hub_local" = 1 ]; then lancer=1
        elif [ "${WAN_NODE_ID:-0}" = "1" ] && [ "$hub_owned" = 0 ]; then lancer=1
        fi
        if [ "$lancer" = 1 ]; then
            # Les noeuds avec LEUR numero (id:ip) : une table 1,3 reste 1,3 sur le hub.
            ips=""
            for id in "${WAN_NODE_LIST[@]}"; do ips="${ips}${id}:${WAN_IP[$id]} "; done
            if [ "$DRY" -eq 1 ]; then
                printf '  [dry-run] %s --no-save --ops 1 --ip %s --ips "%s"\n' "$INTERSTP_SH" "$HUB_IP" "$ips"
            else
                say_begin "Inter-STP standalone ($HUB_IP)"
                # --no-save : la table WAN de CE noeud (WAN_AUTO=1, son numero,
                # ses indicatifs) vient d'etre ecrite par setup-wan-mesh.sh ;
                # le hub ne la reecrit pas.
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

    # --- 7quinquies. Adressage SS7 du noeud (set_stp_ip.sh) -------------------
    # setup-wan-mesh.sh monte la VOIX et les SMS entre noeuds ; il ne touche pas
    # au SS7. Sans ce qui suit, --wan donnait un WAN ou les appels passaient mais
    # ou l'ASP inter-STP visait encore 127.0.0.1, en shutdown : l'interco SS7 ne
    # montait jamais, et rien dans la sortie ne disait pourquoi.
    #
    # set_stp_ip.sh est le seul a ecrire d'un coup les trois configs, la table
    # WAN et /etc/osmo-role. On lui passe --no-ip : l'adresse locale est deja
    # posee (DHCP ou bloc WAN ci-dessus), et --restart serait absurde ici
    # puisque run.sh va demarrer la pile juste apres, avec les fichiers corriges.
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
            # </dev/null : appel automatique, jamais interactif (set_stp_ip.sh
            # demande l'adresse du hub quand elle manque - ici, personne ne
            # repondrait et le lancement resterait fige).
            if bash "$STP_IP_SH" "${stp_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-stp-ip.log" 2>&1; then
                say_end " OK " "$C_OK" "Adressage SS7" "noeud $WAN_NODE_ID -> inter-STP ${hub_ip:-?}"
            else
                # Non fatal : la pile locale tourne tres bien sans interco. On le
                # DIT, plutot que de laisser croire a un WAN complet.
                say_end " ~~ " "$C_SK" "Adressage SS7" "echec - voir ${LOG_DIR:-/tmp}/set-stp-ip.log"
            fi
        fi
    fi
fi

# --- 7quater-bis. Hub SS7 local (banc autonome) -----------------------------
# [2026-10-15] LE RESTART POSE LE SS7. Hors WAN, le STP local garde un ASP
# « asp-to-inter » vers un inter-STP que personne ne lancait : as-inter
# AS_DOWN, barreau ss7 en echec a chaque restart. Si l'adresse de ce hub
# (remote-ip de asp-to-inter) est portee par CETTE machine et que rien n'y
# repond en M3UA (SCTP 2908), on le lance ici, avant run.sh : l'ASP du STP
# s'y attache des son demarrage. Noeud et operateur viennent de la
# routing-key de as-inter (rctx = noeud*1000 + op*100 + 50). Un hub distant n'est
# jamais touche ; un hub local deja en service ne l'est que s'il porte encore
# les noeuds d'un WAN precedent (voir plus bas) ; --no-interstp coupe, --no-save garde
# la table WAN. Meme logique que tests/modules/33-ss7.sh.
if [ "$ACTION" = "start" ] && [ "$WAN_MESH" -ne 1 ] && [ "$INTERSTP" != "0" ]; then
    _stp_cfg="${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg"
    _hub="$(awk '/^ *asp asp-to-inter /{f=1;next} f&&/^ *remote-ip /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
    _rctx="$(awk '/^ *as as-inter /{f=1;next} f&&/^ *routing-key /{print $2; exit} f&&/^ (asp|as) /{exit}' "$_stp_cfg" 2>/dev/null)"
    if [ -n "$_hub" ] && [[ "$_rctx" =~ ^[0-9]+$ ]] && [ -r "$HERE/launch/start-interstp.sh" ] \
       && ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$_hub"; then
        _noeud=$(( _rctx / 1000 )); _op=$(( (_rctx / 100) % 10 ))
        # [2026-10-18] Un hub DEJA en service n'etait jamais touche - y compris
        # quand il tournait encore avec la table d'un WAN precedent : il declarait
        # les AS des autres noeuds (as-n2op1, rctx 2150...), sans ASP puisque ces
        # noeuds ne s'y attachent plus, et les annoncait PROHIB a notre STP
        # (route « 1.21.2 ... PROHIB dyn », global_check en echec). Vider les
        # tables du STP n'y peut rien : la route est dynamique, le hub la
        # re-annonce. Hors WAN, un hub local qui porte d'autres routing-keys que
        # la notre est donc relance avec notre seul noeud.
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

# --- 7quater-ter. La local-ip de l'ASP suit l'adresse du jour ---------------
# [2026-10-16] L'ASP asp-to-inter part d'une local-ip ecrite en dur dans
# osmo-stp.cfg. Un bail DHCP qui change l'adresse du noeud, et ce bind echoue
# en silence : as-inter reste AS_DOWN, l'interco SS7 ne monte pas et rien ne le
# dit. A CHAQUE start on recalcule l'adresse locale (STP_LOCAL_IP) et on la
# reecrit si elle a bouge, avant que run.sh ne demarre la pile. En WAN c'est
# set_stp_ip.sh qui s'en charge (7quinquies) ; ici, le cas autonome.
#   STP_LOCAL_IP = la patte locale qui route vers le hub (remote-ip de l'ASP) ;
#   au besoin (hub injoignable) l'OSMO_NODE_IP du mynode<N>.conf (N = noeud de
#   la routing-key, rctx = noeud*1000 + op*100 + 50).
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
                # Borne au bloc asp-to-inter : les local-ip 127.0.0.x du listener
                # local ne sont pas touchees.
                sed -i "/^ *asp asp-to-inter /,/^ *as /{s/^\( *local-ip *\).*/\1$STP_LOCAL_IP/}" "$_stp_cfg"
                say_end " OK " "$C_OK" "Adresse SS7 locale" "local-ip ${_lo_now:-?} -> $STP_LOCAL_IP"
            fi
        fi
    fi
fi

# --- 7sexies. Le wrapper tcpdump ---------------------------------------------
# La capture GSMTAP est lancee par run_modules/75-gsmtap.sh, dans qosmo : un
# autre depot, qu'on ne modifie pas. Elle ecrit un pcap NON BORNE, et la racine
# du live etant un tmpfs, une capture un peu chargee finit par remplir la RAM.
#
# Le wrapper y substitue un anneau. Il est aussi pose par build-iso.sh, mais une
# ISO deja gravee ne le connait pas, et un live sans persistance le perd a chaque
# reboot : le reposer ICI, a chaque demarrage de la pile, est ce qui le rend
# effectif sans reconstruire ni toucher a qosmo.
#
# DEUX PIEGES, DEUX PARADES - c'est tout l'objet de ce script :
#   -Z root : avec -C/-W, tcpdump cree les membres suivants de l'anneau APRES
#             avoir lache ses privileges. Sans lui : "Permission denied", et
#             AUCUNE capture - alors que sans -C il ouvrait le fichier avant.
#   le lien : avec -C/-W, tcpdump numerote (capture.pcap0, .pcap1...) ; le nom
#             exact demande n'existe jamais, et la barriere du module - un
#             "test -s <nom exact>" - conclut a un echec sur une capture qui
#             tourne. On maintient <nom exact> -> membre courant.
#
# OSMO_NO_PCAP_RING=1 saute l'installation.
install_pcap_wrapper() {
    local dst=/usr/local/bin/tcpdump tmp
    [ "${OSMO_NO_PCAP_RING:-0}" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ] || return 0
    command -v tcpdump >/dev/null 2>&1 || return 0
    # Le vrai binaire doit exister sous /usr/bin ou /usr/sbin ET etre un ELF :
    # un script a sa place (voir le garde-fou dans le wrapper) rendrait le
    # wrapper recursif. Dans ce cas on ne pose rien et on le dit.
    local real=/usr/bin/tcpdump; [ -x "$real" ] || real=/usr/sbin/tcpdump
    if [ ! -x "$real" ] || [ "$(head -c 2 "$real" 2>/dev/null)" = "#!" ]; then
        printf '  %s!%s pcap : %s n est pas le binaire tcpdump - anneau non arme (apt-get install --reinstall tcpdump)\n' \
            "${C_WARN:-}" "$C_Z" "$real" >&2
        return 0
    fi

    tmp="$(mktemp)" || return 0
    cat > "$tmp" <<'PCAPWRAP'
#!/bin/sh
# tcpdump - wrapper osmo-operator : impose un anneau aux captures sur fichier.
# Pose par start-native.sh et par build-iso.sh. Voir leurs commentaires.
# Reglable : OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump
# [2026-09-04] Si REAL est lui-meme un script (ce wrapper copie par-dessus le
# binaire dpkg, cf. iso_modules/52-qemu.sh), exec "$REAL" boucle a l'infini :
# aucune capture, et un `tcpdump --version` qui ne rend jamais la main.
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

# Rien a borner, ou l'appelant a deja choisi son anneau : on s'efface.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Le veilleur du lien. Lance AVANT l'exec : apres, ce processus EST tcpdump.
# $$ survit a l'exec, donc il suit exactement sa vie et s'arrete avec lui.
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

    # Le wrapper s'appelle "tcpdump" et vit dans /usr/local/bin, qui precede
    # /usr/bin : il ne doit donc JAMAIS s'installer par-dessus le vrai binaire,
    # sous peine de recursion infinie. On verifie ou pointe le vrai.
    case "$(command -v tcpdump)" in
        "$dst") ;;                       # deja le wrapper, on remplace
        /usr/bin/tcpdump|/usr/sbin/tcpdump|/bin/tcpdump) ;;
        *) rm -f "$tmp"; return 0 ;;     # emplacement inattendu : on s'abstient
    esac

    if cmp -s "$tmp" "$dst" 2>/dev/null; then
        rm -f "$tmp"                     # deja a jour, rien a dire
    else
        install -m 0755 "$tmp" "$dst" 2>/dev/null \
            && printf '  %spcap%s       anneau de capture arme (%s)\n' \
                 "$C_DIM" "$C_Z" "$dst"
        rm -f "$tmp"
    fi
}
[ "$DRY" -eq 1 ] || install_pcap_wrapper

# --- 7ter. ARRET SYSTEMATIQUE AVANT DEMARRAGE ---------------------------------
# Tout demarrage arrete d'abord la pile. Ce n'est pas de la prudence : sans cela
# le lanceur differe du pont part sur un etat ambigu.
#
# CE QUE CA CORRIGE. La barriere du pont attend osmo-bts-trx pour savoir que les
# ports 5700-5702 sont a lui. Si un run precedent tourne encore, son osmo-bts-trx
# est deja la : la barriere est franchie a l'instant meme, le pont binde EN PLEIN
# teardown de run.sh, qui le tue derriere (f:pont/pont.py est dans _td_patterns)
# -- et rien ne le relance. Symptome : « le pont n'a pas de bursts », sans un
# message pour le dire. La barriere attend desormais les deux fronts (disparition
# puis apparition), mais partir d'une pile arretee rend la question sans objet.
#
# Et cela libere les ports : un fake_trx ou un trxcon orphelin suffit a faire
# echouer le demarrage suivant sur « port UDP 5720 deja pris » -- constate le
# 27/08. Le killall couvre les processus Python que le registre ne connait pas.
#
# CALYPSO_NO_AUTOSTOP=1 desactive ce comportement.
# SAP : arrete les serveurs lances par start_sap (processus demo_server.rb de
# softSIM) et supprime le socket SAP. Le motif [d] evite de se trouver soi-meme.
kill_softsim() {
    local p sock="${SAP_SOCK:-/tmp/osmocom_sap}"
    for p in $(ps -eo pid,args | awk '/[d]emo_server\.rb/ {print $1}'); do
        kill -TERM "$p" 2>/dev/null || true
    done
    rm -f "$sock" 2>/dev/null || true
}

