# 11-regen-configs.sh - partie de start.sh (lignes 2123-2390 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
regen_configs_natif() {
    local node="$1" op="$2" hub="$3"
    local tmp rc=0

    # ── Le plan NATIF, celui de build-iso.sh, et non celui de docker ────────
    # 127.0.0.2 (__CONTAINER_IP__) porte le coeur : GGSN, SGSN, UPF, la nsvc du
    # BSC. Une adresse de boucle locale existe TOUJOURS et est prete avant tout
    # service ; une adresse de carte peut manquer au moment ou osmo-ggsn se lie,
    # et le bind echoue sans rapport visible avec le reseau.
    # 127.0.0.1 (__GATEWAY_IP__) recoit le gsmtap, la ou tshark capte deja.
    local core_ip="${OSMO_NATIVE_CORE_IP:-127.0.0.2}"
    local gw_ip="${OSMO_NATIVE_GW_IP:-127.0.0.1}"

    # ── L'identite SUIT LE NOEUD ────────────────────────────────────────────
    # 1.<noeud><op>.<role>, le plan de network/set-node-id.sh et de build-iso.sh
    # --node. Sans le noeud dans le point code, trois machines attachees au meme
    # hub y presentent trois fois 1.11.2 : un point code est une ADRESSE, et
    # deux equipements qui partagent la leur donnent du routage faux, silencieux.
    # Le routing context suit la meme regle : c'est lui que le hub lit pour
    # distinguer les AS, et la formule locale (op*100+50) rend la meme valeur
    # sur tous les noeuds.
    # Plan WAN seulement s'il y a un WAN (--wan, --wan-nodes). Un hote seul garde
    # le plan LOCAL 1.<op>.<role>, comme set-node-id.sh --local au demarrage :
    # sinon la regeneration reecrit 1.<noeud><op> a chaque relance, meme sans WAN.
    local mid="${node}${op}" wan_plan=0
    if [ "${WAN_MESH:-0}" = "1" ] || [ -n "${WAN_NODES:-}" ]; then wan_plan=1; else mid="$op"; fi
    local pc_msc="1.${mid}.1" pc_stp="1.${mid}.2" pc_bsc="1.${mid}.3"
    local shut="shutdown"
    [ -n "$hub" ] && shut="no shutdown"

    # ── Le PLMN : celui de la machine, pas celui de la table ────────────────
    # Relu dans osmo-msc.cfg installe. Reprendre les defauts de globals.conf
    # renommerait le reseau a chaque regeneration - OsmoDirect redevenait
    # OsmoQEMU - et un mobile deja provisionne ne reconnait plus sa cellule.
    local cfgdir="${OSMOCOM_CFG:-/etc/osmocom}"
    local mcc mnc opname
    mcc="$(awk '/^ *network country code /{print $4; exit}' "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    mnc="$(awk '/^ *mobile network code /{print $4; exit}'  "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    opname="$(awk '/^ *short name /{print $3; exit}'        "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    [ -n "$mcc" ]    || mcc="${MCC:-001}"
    [ -n "$mnc" ]    || mnc="${MNC:-01}"
    [ -n "$opname" ] || opname="${OP_NAME:-OsmoGSM}"

    # Le nombre de MS vient de coeur.env, ecrit par build-iso.sh : c'est lui qui
    # dit combien d'abonnes le HLR provisionne, donc combien de routes SMS il
    # faut. Au-dela, le relais rend "No route for destination".
    local n_ms="${N_MS:-}"
    if [ -z "$n_ms" ] && [ -r "$cfgdir/coeur.env" ]; then
        n_ms="$(awk -F'[:=}]' '/N_MS:=/{print $3; exit}' "$cfgdir/coeur.env" 2>/dev/null)"
    fi
    [ -n "$n_ms" ] || n_ms=2

    printf '  %splan natif%s coeur %s  gsmtap %s  PC %s  rctx %s  PLMN %s-%s (%s)  %s MS\n' \
        "${C_DIM:-}" "${C_Z:-}" "$core_ip" "$gw_ip" "$pc_stp" \
        "$(( node * 1000 + op * 100 + 50 ))" "$mcc" "$mnc" "$opname" "$n_ms"

    tmp="$(mktemp -d)" || return 1

    # ── La sauvegarde, AVANT d'ecrire ───────────────────────────────────────
    # Une regeneration ecrase des fichiers que quelqu'un a pu retoucher a la
    # main sur le banc. Qu'elle soit demandee ne veut pas dire qu'on accepte de
    # perdre l'etat d'avant sans trace.
    local sav="${LOG_DIR:-/tmp}/osmocom-avant-regen-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$sav" -C / etc/osmocom etc/asterisk 2>/dev/null && \
        printf '  %ssauvegarde%s %s\n' "${C_DIM:-}" "${C_Z:-}" "$sav"

    (
        cd "$HERE" || exit 1
        # AVANT de sourcer. lib/gabarits.sh fige ENCRYPTION a "a5 0" et HOST_IP
        # a 127.0.0.1 par ":=" des qu'ils sont vides, et gc_load tient ensuite
        # ces valeurs pour un choix de l'appelant : le banc repartait en clair
        # apres un --regen, sans un mot.
        : "${ENCRYPTION:=a5 1}"
        HOST_IP="$core_ip"
        # Le routing context et l'adresse source de l'ASP : les deux surcharges
        # que build-iso.sh pose pour un noeud de WAN. 0.0.0.0 parce que
        # l'adresse du noeud vient du DHCP et n'est pas forcement montee quand
        # osmo-stp demarre - se lier a une adresse absente echoue au lancement.
        if [ "$wan_plan" = "1" ]; then
            export RCTX_INTER_OVERRIDE=$(( node * 1000 + op * 100 + 50 ))
        else
            export RCTX_INTER_OVERRIDE=$(( op * 100 + 50 ))
        fi
        export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
        # _apply_node_ss7_addressing (appele en fin de apply_config_templates)
        # ne rejoue set-node-id.sh que s'il sait QUI il sert, et il ne le lit
        # que la.
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

        # Le noeud et la table WAN : c'est de la table que sms-routing.conf
        # tire l'adresse de chaque noeud, et du noeud qu'il tire les MSISDN
        # (<noeud>00<operateur><rang>).
        apply_native_post_patches "$tmp" "$op" "$n_ms" "$core_ip" \
            "$node" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1

        # ── bb/ RETIRE, et ce n'est pas un oubli ───────────────────────────
        # install_configs_native poserait $tmp/bb/mobile.cfg par-dessus
        # /root/.osmocom/bb/mobile.cfg. Or ce fichier a deja ete ECRIT plus haut
        # par generate_mobile_cfg, qui seul fixe le port VTY, les sockets L1CTL
        # et l'ARFCN de CHAQUE mobile. Le gabarit, lui, est fige sur l'operateur
        # 1 : le remettre ici rendait les deux mobiles au meme ARFCN et a la
        # meme VTY, et le second restait muet pour toujours.
        rm -rf "$tmp/bb"

        install_configs_native "$tmp" "" || exit 1
    ) || rc=1

    rm -rf "$tmp"
    return "$rc"
}

# ── Les gabarits : conserves, sauf --regen ──────────────────────────────────
# Par defaut on ne touche a rien : dans un conteneur, ce que start-docker.sh vient
# d'ecrire - point codes du noeud, inter-STP, ASP actif - ne doit pas etre
# remplace par les valeurs des gabarits, sans quoi l'identite SS7 est juste
# puis fausse 80 secondes plus tard, sans que rien ne l'annonce.
if [ "${REGEN_GABARITS:-0}" -eq 1 ]; then
    unset OSMO_NO_REGEN
    printf '  %sgabarits%s   regeneration demandee (--regen)\n' "${C_DIM:-}" "${C_Z:-}"

    # ── REGEN : ON ARRETE D ABORD ───────────────────────────────────────────
    # Regenerer /etc/osmocom sous une pile VIVANTE ne sert a rien et trompe :
    # les demons ont deja lu leur configuration, ils gardent l'ancienne en
    # memoire, et les fichiers neufs ne prennent effet qu'au demarrage suivant.
    # On lisait donc une conf juste sur le disque pendant que la pile tournait
    # sur la precedente -- le genre d'ecart qui se paie dix minutes plus tard.
    # Un --regen arrete donc la pile, puis regenere : l'etat est sans ambiguite.
    if [ -x "$RUN_SH" ] || [ -r "$RUN_SH" ]; then
        say_begin "Arret de la pile avant regeneration"
        banc_dsp_arreter >/dev/null 2>&1 || true
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
        say_end " OK " "$C_OK" "Arret de la pile avant regeneration"
        declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
        # Meme filet qu'au --stop : un python3 orphelin (pont, fake_trx, trxcon)
        # garde son port et fait echouer le demarrage suivant sur « port UDP
        # 5720 deja pris ». PORTEE : les python3 du banc seulement.
        if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
            killall_python -TERM && \
                say_end " OK " "$C_OK" "python3 du banc termines"
        fi
    fi

    # ── LE NOEUD, PAR DEFAUT 1 ──────────────────────────────────────────────
    # Une regeneration produit une identite COMPLETE, jamais un plan « sans
    # noeud ». Sans numero, apply_config_templates rendait le plan du gabarit -
    # point-code 1.1.2 pour toute machine - et deux noeuds du meme banc se
    # retrouvaient a la meme adresse SS7. On numerote donc toujours : le noeud
    # resolu plus haut (--node, l'environnement, /etc/osmo-role, la table WAN),
    # et 1 quand il n'y en a aucun. Les configurations s'incrementent alors
    # avec lui : PC 1.<noeud><op>.<role>, routing context <noeud>*1000+..., et
    # le segment prive 192.168.<noeud+1>.x.
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
    # cached_hub est LOCAL a ask_node_identity : le lire ici rendait le vide et,
    # sans inter-STP, l'ASP repartait en shutdown apres chaque regeneration.
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

    # ── LE HLR SUIT LA NUMEROTATION ─────────────────────────────────────────
    # Une regeneration change les MSISDN (<noeud>00<operateur><rang>) : ceux du
    # HLR datent du plan precedent. L'IMSI, lui, ne bouge pas - il ne porte pas
    # le noeud, precisement pour que le Ki et l'authentification restent
    # valables. L'etape d'abonnes ne peut donc pas se contenter de constater
    # que l'IMSI existe : elle relit desormais AUSSI le MSISDN
    # (run_modules/21-abonnes-hlr.sh, mod_abonnes_hlr_status) et rejoue
    # "subscriber ... update msisdn" quand il a change.
    #
    # On la force en plus ici : la pile vient d'etre arretee, le HLR repartira
    # avec run.sh, et l'etape doit s'executer meme si un cache d'etat la croit
    # deja faite. Sans ca, l'abonne s'attachait (IMSI connu) mais restait
    # injoignable, sans qu'une ligne ne dise que son numero avait change.
    FORCE=1
    printf '  %sHLR%s        abonnes a reapprovisionner : MSISDN %s..%s\n' \
        "${C_DIM:-}" "${C_Z:-}" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + 1 ))" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + ${N_MS:-2} ))"

    # Le noeud retenu vaut pour la suite du lancement : c'est celui qui vient
    # d'etre ecrit dans les fichiers. Le laisser vide ici, c'est laisser la
    # section « Identite SS7 » plus bas repartir sur une autre resolution et
    # reecrire par-dessus une identite differente de celle qu'on vient de poser.
    NODE_ID="$REGEN_NODE"
    NODE_OP="$REGEN_OP"
    [ -n "$REGEN_HUB" ] && HUB_IP="${HUB_IP:-$REGEN_HUB}"
    export OSMO_ROLE=operator
    export OSMO_WAN_NODE="$NODE_ID"
    [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
elif [ "${RUNTIME_ENV:-native}" = "docker" ]; then
    # DANS UN CONTENEUR seulement. Les configs y sont deja ecrites par start-docker.sh,
    # avec l'identite du noeud : les regenerer les remplace par les valeurs des
    # gabarits, et l'interco meurt.
    export OSMO_NO_REGEN=1
else
    # SUR UNE VM sans --regen : on CONSERVE ce qui est en place. C'est l'ISO qui
    # a genere ces fichiers a la construction, avec la meme recette que
    # regen_configs_natif ; les refaire a chaque demarrage ne changerait rien et
    # ecraserait toute retouche faite sur le banc. --regen est la pour ca, et il
    # le dit.
    if [ -n "$NODE_ID" ]; then
        export OSMO_ROLE=operator
        export OSMO_WAN_NODE="$NODE_ID"
        [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
    fi
fi

# --- 7ter. Identite de noeud (--node) -------------------------------------------
# AVANT le WAN et avant run.sh : les point codes sont lus par osmo-stp, osmo-msc
# et osmo-bsc a leur demarrage. Les changer apres ne servirait a rien.
#
# UNE SEULE SOURCE DE VERITE. start-docker.sh calcule deja l'identite d'un conteneur et
# la lui passe par l'environnement ; la recalculer ici en donnerait deux, et
# c'est la mauvaise qui gagnait. On reprend donc la sienne quand elle existe.
if [ -z "$NODE_ID" ] && [ -n "${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}" ]; then
    NODE_ID="${OSMO_WAN_NODE:-$WAN_NODE_ID}"
    [ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-}"
fi

# Sans identite alors que le WAN est demande, on ne part PAS en silence : la
# pile demarrerait avec les point codes du gabarit (1.1.2 pour tout le monde),
# deux noeuds porteraient la meme adresse SS7, et aucun ASP ne s'attacherait -
# sans qu'une seule ligne ne le signale.
# --wan FICHIER sans --node : ce noeud prend le premier numero que les fiches
# ne portent pas (les fiches disent qui est deja la, on dit qu'on l'a fait).
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

