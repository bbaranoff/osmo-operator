#!/bin/bash
# iso_modules/30-image-configs.sh - etape 1 (build docker) et 2 (configs via start.sh)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 1 : LE build docker (une fois ; voir iso_docker_build) ─────────────
iso_docker_build "$ISO_ROLE"

load_start_lib() {
    local src="$DIR/start.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # La lib vit dans $WORK, pas dans le depot : sans ca, la resolution par
    # BASH_SOURCE de start.sh chercherait generate_configs.sh a cote de la copie.
    export OSMO_REPO_DIR="$DIR"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Etape 2 : la bibliotheque de start.sh (apply_config_templates) ───────────
# [2026-09-03] Plus de build_run_image ni de Dockerfile.lite ici : une seule
# image docker (etape 1), les configs viennent de ce depot, l elagage lite se
# fait sur le rootfs (etape 8c). load_start_lib reste necessaire : c est lui qui
# apporte apply_config_templates.
load_start_lib
echo -e "${GREEN}[2/9] Image source : ${CYAN}$([ "$ISO_ROLE" = "interstp" ] && [ "${OSMO_ISO_ALL_RUN:-0}" != "1" ] && echo osmocom-stp || echo osmocom-nitb)${NC}"

echo -e "${GREEN}[2b/9] Preparation de l'image source de l'ISO...${NC}"

ISO_N_MS=2
ISO_OP_ID=1         # operateur unique de l'ISO (PLMN 001-01)
ENCRYPTION="a5 1"   # A5/1 par defaut dans l'ISO -- la valeur suit enfin le commentaire

# L'ISO tourne en NATIF, sans bridge docker. Les 172.20.0.x existaient quand
# meme : 20-dhcp.network (plus bas) les alias sur le NIC par defaut. Mais faire
# ecouter le coeur dessus le rend tributaire de ce NIC - s'il est absent (VM
# sans carte), nomme hors de "en* eth*", ou simplement pas encore configure
# par systemd-networkd quand osmo-ggsn demarre, le bind echoue. La boucle
# locale, elle, est toujours la et prete avant tout service.
# Concerne : osmo-ggsn (gtp bind-ip), osmo-sgsn (ggsn remote-ip), osmo-upf
# (local-addr), osmo-bsc (gprs nsvc remote ip) et le log gsmtap, que l'on
# ramene ainsi sur 127.0.0.1 ou tshark capte deja.
# 127.0.0.2 et non .1 : c'est deja l'adresse que le bloc de patch plus bas
# impose aux MEMES services (gtp local-ip, gsup remote-ip, listen 23000, HLR
# remote-ip). Tant que __CONTAINER_IP__ valait 127.0.0.1, la substitution du
# gabarit et le patch qui la suit divergeaient - le GGSN pouvait annoncer une
# adresse et ecouter sur l'autre. C'est aussi ce qui remplace les 172.20.1.x
# d'avant : une adresse de boucle locale existe toujours, une adresse de NIC
# peut manquer au moment ou le service demarre.
ISO_PRIV_BASE=$(( ${ISO_NODE:-1} + 1 ))
ISO_PRIV_GW="192.168.${ISO_PRIV_BASE}.1"
ISO_PRIV_IP="192.168.${ISO_PRIV_BASE}.10"

# ── L ADRESSE DE BASE EST CELLE DU SEGMENT PRIVE, PLUS LA BOUCLE LOCALE ─────
# ip1 valait 127.0.0.2. Une boucle locale a l avantage d exister toujours, mais
# elle ne se voit que de la machine : deux noeuds ne peuvent rien se dire, et
# surtout SGSN et GGSN se retrouvaient sur LA MEME adresse. Or les deux ouvrent
# le meme socket GTP :
#     osmo-ggsn : gtp bind-ip  127.0.0.2  -> prend 2123/2152/3386 en premier
#     osmo-sgsn : gtp local-ip 127.0.0.2  -> « bind failed: Address already in
#                 use », « FATAL Cannot bind/listen on GTP socket », et systemd
#                 le relance en boucle (compteur a 58 sur le banc).
# Le packet attach restait alors en « [ .. ] » pour toujours, sans qu aucun
# journal du lanceur ne le dise - c est celui du demon qui parle.
#
# Le plan du noeud donne DEUX adresses, c est exactement ce qu il faut :
#     .10  ip1  le coeur : GGSN, NS/Gb du SGSN, UPF, nsvc du BSC
#     .1   gw prive       le point GTP du SGSN, a lui seul
# Elles sont posees en /32 par network/osmo-ip-plan.sh avant que run.sh ne
# demarre quoi que ce soit, et son repli les pose sur `lo` quand aucune carte
# ne fournit Internet : l argument « une boucle locale existe toujours » reste
# donc vrai, sans l inconvenient de l adresse unique.
HOST_IP="$ISO_PRIV_IP"     # ip1 : __CONTAINER_IP__ - ggsn/sgsn-NS/upf/bsc-nsvc
SGSN_GTP_IP="$ISO_PRIV_GW" # le point GTP du SGSN, distinct du GGSN
GATEWAY_IP="127.0.0.1"     # gw  : __GATEWAY_IP__  - log gsmtap + dns 0 du ggsn
# HLR et GSUP restent sur la boucle locale : c est un plan de controle interne
# au noeud, que personne n appelle de l exterieur, et osmo-hlr.cfg y fige son
# « bind ip 127.0.0.2 ». Les deplacer demanderait de bouger les deux ensemble
# sans rien y gagner.
HLR_IP="127.0.0.2"

# ── Le segment prive de ce noeud : 192.168.<noeud+1>.x ──────────────────────
# Meme plan que le cote docker (start.sh : op_private_*), pour qu'une VM et un
# conteneur du meme rang se decrivent pareil. Le +1 laisse 192.168.1.0/24 au
# LAN du banc - un noeud qui s'y poserait entrerait en collision avec les VM et
# le hub SS7.
#
# Ces adresses REMPLACENT les 172.20.x heritees du plan docker. Elles ne
# revendiquent rien (/32) : le but n'est pas de creer un segment - une VM n'a
# pas de BTS derriere une carte - mais de donner un point d'attache stable aux
# configurations qui nomment encore une adresse privee.
# __INTER_STP_IP__ : ASP vers le STP d'un autre operateur. Inerte ici - l'ISO
# n'a qu'un operateur et passe inter_stp_shutdown=shutdown a apply_config_
# templates - mais on ne laisse pas une IP docker morte dans les configs.
INTER_STP_IP="127.0.0.1"   # ip2 : inter-operateur (ASP shutdown sur l'ISO)

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  Inter-STP  : ${CYAN}${INTER_STP_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"

TEMP_CONFIG="$(mktemp -d)"

# ── Point codes et rattachement SS7 ──────────────────────────────────────────
# Hors WAN : le plan historique, 1.<op>.<role>, et l'ASP inter-STP coupe -
# l'ISO n'a qu'un operateur, il n'a personne a qui parler en SS7.
#
# Avec --node N : le noeud entre DANS le point code, 1.<noeud><op>.<role>.
# Sans ca, trois ISO attachees au meme hub y presenteraient trois fois 1.11.2.
# Un point code est une adresse : deux equipements avec la meme, ce n'est pas
# un conflit de nom, c'est du routage faux - et silencieux.
ISO_PC_MSC="1.1.1"; ISO_PC_STP="1.1.2"; ISO_PC_BSC="1.1.3"
ISO_INTER_SHUT="shutdown"
ISO_INTER_IP="$INTER_STP_IP"
if [ -n "$ISO_NODE" ]; then
    ISO_PC_MSC="1.${ISO_NODE}${ISO_OP_ID}.1"
    ISO_PC_STP="1.${ISO_NODE}${ISO_OP_ID}.2"
    ISO_PC_BSC="1.${ISO_NODE}${ISO_OP_ID}.3"
    ISO_INTER_IP="$ISO_HUB_IP"
    ISO_INTER_SHUT="no shutdown"
    # RCTX unique lui aussi : le hub identifie chaque AS par son routing context.
    export RCTX_INTER_OVERRIDE=$(( ISO_NODE * 1000 + ISO_OP_ID * 100 + 50 ))
    # local-ip de l'ASP laissee a 0.0.0.0 : l'adresse du noeud vient du DHCP et
    # n'est pas forcement montee quand osmo-stp demarre. Se lier a une adresse
    # absente echoue au lancement, sans rapport visible avec le reseau.
    export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
    echo -e "  Noeud WAN  : ${CYAN}${ISO_NODE}${NC}  PC ${CYAN}${ISO_PC_STP}${NC}  hub ${CYAN}${ISO_HUB_IP}${NC}  rctx ${RCTX_INTER_OVERRIDE}"
fi

apply_config_templates "$TEMP_CONFIG" \
    "$HOST_IP" "$GATEWAY_IP" \
    "1" "$ISO_PC_MSC" "$ISO_PC_STP" "$ISO_PC_BSC" \
    "001" "01" "OsmoGSM" \
    "$ISO_INTER_IP" "$ISO_INTER_SHUT" "1"

# ── Role inter-STP : la config du hub, pour N noeuds ────────────────────────
if [ "$ISO_ROLE" = "interstp" ]; then
    _hub_nodes=3
    if [ -n "$ISO_WAN_NODES" ]; then
        _hub_nodes=$(printf '%s' "${ISO_WAN_NODES//,/ }" | wc -w)
    fi
    bash "$DIR/helpers/create_interop.sh" --wan "$_hub_nodes" "${ISO_WAN_OPS:-1}" \
        "$TEMP_CONFIG/osmocom/osmo-stp-interop.cfg" || exit 1
    echo -e "  ${GREEN}✓${NC} hub SS7 pour ${CYAN}${_hub_nodes}${NC} noeud(s) × ${ISO_WAN_OPS:-1} operateur(s)"
fi

# ── Les retouches NATIVES ────────────────────────────────────────────────────
# APRES apply_config_templates, et non avant : celui-ci ecrase systematiquement
# sms-routing.conf, osmo-sgsn.cfg et osmo-msc.cfg avec ce que disent les
# gabarits - c'est-a-dire le plan DOCKER.
#
# Cette recette vivait ICI, en deux morceaux (le sms-routing juste apres la
# substitution, les sed du SGSN et du MSC trois cents lignes plus bas), et
# NULLE PART ailleurs. Une ISO en sortait juste ; une machine qui regenerait
# ses configs ensuite - ./start-direct.sh --regen - en sortait fausse, sans
# qu'un seul message ne le dise. Elle est desormais dans generate_configs.sh,
# une fois, et les deux chemins l'appellent (voir apply_native_post_patches).
# La table WAN telle que cette ISO l'embarquera : c'est elle qui donne a
# sms-routing.conf l'adresse de CHAQUE noeud. Sans elle (ISO d'un banc isole),
# le generateur n'ecrit que notre propre entree.
ISO_WAN_TMP=""
if [ -n "$ISO_WAN_NODES" ]; then
    ISO_WAN_TMP="$(mktemp -p "$WORK")"
    printf 'WAN_NODES="%s"\n' "$ISO_WAN_NODES" > "$ISO_WAN_TMP"
fi
apply_native_post_patches "$TEMP_CONFIG" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}" "$SGSN_GTP_IP" "$HLR_IP"
echo -e "  ${GREEN}✓${NC} retouches natives : sms-routing (${CYAN}${ISO_N_MS}${NC} route(s) MS), GGSN/NS ${CYAN}${HOST_IP}${NC}, GTP SGSN ${CYAN}${SGSN_GTP_IP}${NC}, HLR ${CYAN}${HLR_IP}${NC}"

