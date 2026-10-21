# 10-identite-noeud.sh - partie de start.sh (lignes 1912-2122 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
case "$ACTION" in
    list)
        if [ "$DSP_BANC" = 1 ]; then
            printf '  %sbanc DSP%s   %s retire du plan : %s ; %s les reprend (5 etapes)\n' \
                "$C_DIM" "$C_Z" "$RUN_SH" "$DSP_MODULES_RETIRES" "$BANC_DSP"
        fi
        # [2026-10-18] Sans --restart : run.sh garde la DERNIERE action lue, et
        # RUN_ARGS finit par --restart. `--list` arretait donc la pile en cours
        # et la relancait au lieu d'afficher le plan.
        _list_args=()
        for _a in "${RUN_ARGS[@]}"; do [ "$_a" = "--restart" ] || _list_args+=("$_a"); done
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --list "${_list_args[@]}"
        ;;
    genconf)
        # ── LA FICHE DU NOEUD, SANS LANCER ──────────────────────────────
        # [2026-09-04] La meme que celle ecrite par le run (juste avant run.sh) :
        # identite resolue comme au lancement (--node, environnement,
        # /etc/osmo-role, table WAN), table WAN relue si elle existe.
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
        banc_dsp_arreter          # QEMU, osmocon, mobile, pont : a lui
        banc_dsp_arreter_instances
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE"
        # les serveurs SAP de softSIM (--sap) et leur socket
        for _p in $(ps -eo pid,args | awk '/[d]emo_server\.rb/ {print $1}'); do kill -TERM "$_p" 2>/dev/null || true; done
        rm -f "${SAP_SOCK:-/tmp/osmocom_sap}" 2>/dev/null; unset _p
        say_end " OK " "$C_OK" "Arret de la pile via run.sh"
        purge_sessions_tmux
        # ── LE TABLEAU DE BORD S ARRETE AVEC LE BANC ──────────────────────
        # [2026-09-04] Il survivait a tous les arrets : ni run.sh --stop ni la
        # purge tmux ne le connaissent, son unite est WantedBy=multi-user.target
        # et killall_python ne voit pas un serveur node. On se retrouvait avec
        # :8080 qui repond DEVANT UNE PILE MORTE - l etat le plus trompeur qui
        # soit, puisqu il se lit comme "le banc tourne".
        # PartOf=osmo-banc.service couvre `systemctl stop|restart osmo-banc` ;
        # ceci couvre le geste direct, par lequel passent le bouton « Arreter »
        # du bureau, launch.sh --stop et start-multi.sh --stop.
        # --no-block : on n attend pas systemd, et surtout on ne peut pas se
        # bloquer quand cet arret est lui-meme l ExecStop de osmo-banc.
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            systemctl --no-block stop osmo-egprs-web.service 2>/dev/null || true
        else
            pkill -f "osmo-egprs-web/server.js" 2>/dev/null || true
        fi
        # Filet identique a celui de run.sh, pose ici aussi : on peut arreter par
        # ce script sans passer par l'autre, et un fake_trx.py orphelin suffit a
        # faire echouer le run suivant sur « port UDP 5720 deja pris ».
        # run.sh le fait deja de son cote ; le repeter ne coute rien et couvre le
        # cas ou RUN_SH est introuvable ou sort en erreur.
        # PORTEE : les python3 DU BANC seulement (voir killall_python).
        # CALYPSO_STOP_KILL_PYTHON=0 le desactive.
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
        # Le banc DSP n'a pas de --check-paths : ses cinq etapes verifient
        # chacune son binaire et sortent en nommant ce qui manque. On montre
        # donc ce qu'elles vont chercher, plutot que d'inventer une reponse.
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
# --- 7bis-menu. Ce qui manque, demande UNE fois, avec le cache en defaut ------
# Les trois valeurs qui decident de l'identite SS7 - numero de noeud, operateur,
# adresse du hub - se deduisent la plupart du temps : environnement transmis par
# start-docker.sh, /etc/osmo-role fige dans l'image, table WAN. Quand la deduction ne
# donne rien, la pile demarrait quand meme et gardait les point codes du
# gabarit : 1.1.2 partout, ASP vers 127.0.0.1, interco morte sans un mot.
#
# On demande donc - mais seulement ce qui manque, et en proposant ce que le
# cache sait deja. Sans terminal, rien n'est demande : les defauts s'appliquent,
# une ISO qui demarre seule ne peut pas rester bloquee sur une question.
ask_node_identity() {
    # NO_MENU=1 est ce que start-docker.sh pose devant le lanceur quand les choix ont
    # deja ete faits sur l'hote. Aujourd'hui la garde tty juste en dessous
    # suffit (start-docker.sh lance par docker exec -d, sans terminal) : ce test ne
    # repare donc aucune panne observable, il aligne l'identite SS7 sur la
    # meme convention que les menus de pile de start-docker.sh, pour le jour ou le
    # lanceur automatique aura un terminal.
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ -t 0 ] || return 0
    [ "$DRY" -eq 1 ] && return 0

    local cached_node cached_src cached_hub
    IFS='|' read -r cached_node cached_src <<< "$(detect_node_id)"

    # L'ENVIRONNEMENT NE SE DEMANDE PAS. C'est ainsi que start-docker.sh transmet le
    # noeud a un conteneur : la reponse est deja connue, et la question n'a pas
    # de sens - pire, dans un conteneur ou personne ne lit le terminal, elle
    # repart vide. L'identite n'etait alors PAS appliquee, la pile regenerait
    # ses configs par defaut (point-code 1.1.2, ASP vers le hub docker, en
    # shutdown) et ecrasait celle que start-docker.sh venait d'ecrire. Le fichier
    # portait les bonnes valeurs juste avant, les mauvaises juste apres.
    # Le rattrapage qui se trouvait ici ne servait plus a rien : il exigeait un
    # NODE_ID vide, alors que la resolution du noeud, bien plus haut, l'a deja
    # rempli depuis cette meme source. NODE_ID et HUB_IP sont donc repris de
    # l'environnement la-bas, une fois, et pas ici.
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

# ══ La regeneration des configurations, POUR DE VRAI ═══════════════════════
# CE QUE --regen FAISAIT JUSQU'ICI : RIEN.
# Il levait OSMO_NO_REGEN et comptait sur run_modules/08-gabarits.sh pour
# rejouer apply_config_templates au demarrage. Ce module N'EXISTE PAS - il n'a
# jamais existe dans run_modules/ - et run.sh ne genere aucune configuration.
# Le message « regeneration demandee » s'affichait, la pile s'arretait, et pas
# un octet de /etc/osmocom ne changeait. Le seul effet reel de l'option etait
# d'arreter le banc.
#
# CE QU'IL FAIT MAINTENANT : la meme chose que start-docker.sh cote docker, et que
# build-iso.sh a la construction - c'est-a-dire la sequence complete :
#
#   1. apply_config_templates      substitue configs/*.cfg et *.conf dans un
#                                  repertoire NEUF (jamais en place : une
#                                  substitution a moitie faite sur /etc/osmocom
#                                  laisse un banc qui ne demarre plus) ;
#   2. apply_native_post_patches   la recette NATIVE de l'ISO - sms-routing par
#                                  MS reel, SGSN/MSC sur l'adresse locale du
#                                  coeur, run.sh degraisse ;
#   3. install_configs_native      pose le resultat dans /etc/osmocom et
#                                  /etc/asterisk.
#
# EN SOUS-SHELL. lib/gabarits.sh charge globals.conf et pose une trentaine de
# variables - MCC, ARFCN, HOST_IP, N_OPERATORS, KI... - qui portent ici un tout
# autre sens (HOST_IP est l'adresse du banc pour le lanceur, l'adresse interne
# du coeur pour les gabarits). Les laisser fuir, c'est changer le plan radio
# d'un run parce qu'on a demande une regeneration.
#
#   $1 numero de noeud   $2 numero d'operateur   $3 inter-STP (peut etre vide)
# ── LE POINT CODE AFFICHE SUIT LE PLAN REELLEMENT APPLIQUE ──────────────────
# [2026-08-31] Ces bandeaux calculaient toujours 1.<noeud><op>.x, la formule du
# plan WAN, alors que set-node-id.sh recoit --local hors WAN et ecrit
# 1.<op>.x. On lisait donc, dans la meme sortie :
#     [ OK ] Identite SS7 (noeud 1 · PC 1.13.x · mode docker)
#       SS7  point-code 1.3.2
# deux valeurs contradictoires pour la meme chose - la premiere fausse. Sur un
# banc ou le desaccord de plan a justement coute une demi-journee, un bandeau
# qui annonce le mauvais plan est exactement ce qu il ne faut pas.
_pc_affiche() {   # $1 = noeud, $2 = operateur
    if [ "${WAN_MESH:-0}" != "1" ] && [ -z "${WAN_NODES:-}" ]; then
        printf '1.%s.x' "$2"          # plan local, celui qu on applique
    else
        printf '1.%s%s.x' "$1" "$2"   # plan WAN, entre machines
    fi
}

