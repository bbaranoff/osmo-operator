# =============================================================================
#  lib/gabarits.sh - le moteur de gabarits de configuration d'osmo_egprs
# =============================================================================
#
#  CE FICHIER EST UNE EXTRACTION, PAS UNE REECRITURE.
#  Les fonctions ci-dessous viennent telles quelles de start-direct.sh.legacy
#  (L65-76, L106-258, L499-511). Elles n'ont pas ete retouchees : le jour ou
#  un gabarit change, on veut pouvoir comparer ligne a ligne avec l'ancien.
#
#  POURQUOI LES SORTIR DU POINT D'ENTREE.
#  Elles sont la SEULE chose que start-direct.sh faisait et que personne
#  d'autre ne fait : substituer __ENCRYPTION__, __MCC__, __KI__, __ARFCN__ ...
#  dans configs/*.cfg puis les deposer dans /etc/osmocom, /etc/asterisk et
#  ~/.osmocom/bb. Sans elles, les demons du coeur demarrent sur les fichiers
#  qu'un run precedent a laisses - et `ENCRYPTION=a5 0` n'a aucun effet, en
#  silence. Le reste de start-direct.sh (lancer vingt processus) est repris
#  par le moteur ; ceci ne l'est pas, donc on le preserve a l'identique et on
#  le rend appelable depuis un module.
#
#  CE FICHIER NE FAIT RIEN AU SOURCE : il ne definit que des fonctions.
#  Le seul appelant attendu est run_modules/08-gabarits.sh.
#
#  DEPENDANCES D'ENVIRONNEMENT (posees par l'appelant, valeurs de l'ancien
#  script en defaut) : ENCRYPTION, HOST_IP, ALSA_OUTPUT, ALSA_INPUT.
#  Le repertoire courant doit etre celui d'osmo_egprs : les fonctions lisent
#  `configs/*.cfg` et `scripts/*` en chemin RELATIF, comme dans l'original.
# -----------------------------------------------------------------------------

: "${ENCRYPTION:=a5 0}"
: "${HOST_IP:=127.0.0.1}"
: "${ALSA_OUTPUT:=default}"
: "${ALSA_INPUT:=default}"

# Ces fonctions ont une JUMELLE dans start.sh : elles doivent dire la meme
# chose. C'est CETTE copie que lit une machine qui reclone le depot a chaque
# demarrage - donc celle qui compte sur une ISO. Tant qu'elle a garde l'ancien
# plan prive (172.20.<op>.x), les configs regenerees au boot liaient
# 172.20.1.10, une adresse que plus rien ne pose : osmo-ggsn et osmo-sgsn
# refusaient de demarrer ("adresse introuvable localement") et osmo-pcu tombait
# avec eux.
#
#   backbone  172.20.0.<10+op>   le segment partage avec l'inter-STP (.10)
#   prive     192.168.<op+1>.x   un segment par operateur ; le +1 laisse
#                                192.168.1.0/24 au LAN du banc.
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
# ── L'INDEX DU SEGMENT PRIVE : LE NOEUD OU L'OPERATEUR, SELON L'HOTE ────────
# 192.168.<index+1>.x, et tout le desaccord tenait a « index ».
#
#   DOCKER   un hote porte N conteneurs operateurs, chacun dans son netns. Ce
#            qui les distingue est le NUMERO D'OPERATEUR ; le noeud, lui, est
#            commun a tous les conteneurs de la machine. index = operateur.
#   VM/NATIF la machine EST le noeud et ne porte qu'un operateur. Ce qui la
#            distingue de ses voisines est le NUMERO DE NOEUD. index = noeud.
#
# Sans cette distinction, qemu-src/run_modules/08-gabarits.sh appelait
# op_private_ip($OPERATOR_ID) et ecrivait 192.168.2.10 dans osmo-ggsn.cfg sur
# TOUTES les VM - operateur 1 partout - pendant que le plan de l'ISO reservait
# 192.168.<noeud+1>.x. Sur le noeud 1 les deux coincidaient et rien ne se
# voyait ; sur le noeud 2, le GGSN se liait a l'adresse du noeud 1.
# La bascule est ici, une fois, et les deux jumelles (start.sh, lib/gabarits.sh)
# en heritent.
_osmo_priv_index() {
    local op="${1:-1}"
    # Meme detection que start-direct.sh : le couple /.dockerenv +
    # /etc/docker-entrypoint-cmd identifie un conteneur DE CE DEPOT ; le cgroup
    # sert de repli pour un conteneur quelconque.
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        printf '%s' "$op"; return
    fi
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
                        "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' "${OSMOCOM_CFG:-/etc/osmocom}/radio-plan.env" 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
op_private_ip()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).10"; }
op_private_gw()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).1"; }
op_private_net()  { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).0/24"; }
op_netns()        { echo "osmo-op$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }
linphone_sip_port()  { echo $(( 5060 + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }
generate_pjsip_interop_trunks() {
    local op_id=$1 n_operators=$2 remote_op remote_ip
    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        remote_ip=$(op_backbone_ip "$remote_op")
        cat <<EOF

[interop-identify-op${remote_op}]
type=identify
endpoint=interop_trunk_op${remote_op}
match=${remote_ip}

[interop_trunk_op${remote_op}]
type=endpoint
transport=transport-udp
context=interop_in
disallow=all
allow=gsm
allow=ulaw
aors=interop_trunk_op${remote_op}
direct_media=no
rtp_symmetric=yes
force_rport=yes
media_encryption=no

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}
generate_extensions_interop_out() {
    local op_id=$1 n_operators=$2 remote_op
    # Le prefixe porte le NOEUD : MSISDN = <noeud>00<operateur><rang>. Fige a
    # "600", le motif ne matchait plus rien des que le numero commencait par le
    # numero de noeud - les appels inter-operateurs sortaient en Congestion
    # sans qu'aucune ligne ne dise que c'est le motif qui n'accroche pas.
    local _pfx; _pfx="$(osmo_msisdn_pfx "$(osmo_node_id)")"
    printf '[interop_out]\n\n'
    # Un seul motif : les MSISDN font six chiffres, <noeud>00<operateur><rang>. Les
    # deux motifs _<op>XXXX / _<op>XXXXX visaient l'ancien plan a cinq chiffres,
    # ou le premier chiffre du numero ETAIT l'operateur - plus rien ne matchait.
    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done
    # PAS de fourre-tout _X. ici : le gabarit configs/extensions.conf en declare
    # deja un dans ce meme contexte. Deux extensions identiques dans un contexte
    # font refuser la seconde, avec six avertissements a chaque chargement :
    #     add_priority: Unable to register extension '_X.' priority 1
    #                   in 'interop_out', already in use
    # Rien ne cassait - le fourre-tout du gabarit restait en place - mais ces
    # lignes noyaient celles qui comptent.
}
_generate_sms_routing_conf_fallback() {
    # 'local i' n'est PAS cosmetique. Cette fonction est appelee, via
    # apply_config_templates, DEPUIS la boucle "for i in ..." qui demarre les
    # operateurs. Sans local, sa propre boucle ecrase la variable de l'appelant
    # et la laisse a n_operators : tous les conteneurs suivants calculaient
    # alors leurs ports avec le MEME indice, d'ou
    #     Bind for 0.0.0.0:5082 failed: port is already allocated
    # au deuxieme conteneur - et, avant l'erreur, deux operateurs annonces sur
    # les memes SIP/RTP/SMS.
    local i
    local op_id=$1 n_operators=$2 i j
    printf '# sms-routing.conf - Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    for i in $(seq 1 "$n_operators"); do printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"; done
    printf '\n[routes]\n'
    for i in $(seq 1 "$n_operators"); do
        # Les MSISDN EXACTS, pas un prefixe : un prefixe trop court avalait
        # les numeros voisins, un prefixe absent laissait le relais rejeter
        # tout SMS local avec "No route for destination" (2026-07-29).
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done   # MSISDN exacts <noeud>00<op><ms> (100101, 100102, 200101...)
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}
# [2026-08-03] apply_config_templates() a demenage dans generate_configs.sh :
# ce fichier en portait une copie, start.sh une autre. Une seule desormais, et
# ses valeurs (ARFCN, BSIC, KI, IMSI...) sont exposees dans globals.conf au lieu
# d'etre des formules enfouies dans la substitution.
_GAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -r "$_GAB_ROOT/generate_configs.sh" ] && . "$_GAB_ROOT/generate_configs.sh"

# ── Install configs natif. $1=src $2=prefix racine (/ ou /etc/netns/<ns>) ──
install_configs_native() {
    local src=$1 root="${2:-}"
    mkdir -p "${root}/etc/osmocom" "${root}/etc/asterisk" "$HOME/.osmocom/bb"
    cp -f "$src/osmocom"/*      "${root}/etc/osmocom/"  2>/dev/null || true
    cp -f "$src/asterisk"/*.conf "${root}/etc/asterisk/" 2>/dev/null || true
    [ -f "$src/bb/mobile.cfg" ]        && cp -f "$src/bb/mobile.cfg"        "$HOME/.osmocom/bb/mobile.cfg"
    [ -f "$src/bb/mobile_group1.cfg" ] && cp -f "$src/bb/mobile_group1.cfg" "$HOME/.osmocom/bb/mobile_group1.cfg"
    if [ -f configs/asound.conf ]; then
        cp -f configs/asound.conf "${root}/etc/asound.conf"
        ALSA_OUTPUT="gsm_out"; ALSA_INPUT="gsm_in"
    fi
}

detect_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    [ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    HOST_IP="${HOST_IP:-127.0.0.1}"
}

# ── Auto-attach tmux ────────────────────────────────────────────────────────
# run.sh tourne en arriere-plan et cree la session tmux 'osmocom'
# (socket /tmp/osmocom_tmux). On attend qu'elle soit prete (run.sh termine)
# puis on s'y attache dans le terminal courant. $1 = log run.sh a surveiller.
#   AUTO_ATTACH=0   → desactive (reste en arriere-plan, message manuel)
#   Desactive aussi si pas de TTY (scripte/bg) ou deja dans un tmux.
