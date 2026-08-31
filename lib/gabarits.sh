# =============================================================================
#  lib/gabarits.sh - le moteur de gabarits de configuration d'osmo-operator
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
#  Le repertoire courant doit etre celui d'osmo-operator : les fonctions lisent
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
# Sans cette distinction, qosmo-grgsm/run_modules/08-gabarits.sh appelait
# op_private_ip($OPERATOR_ID) et ecrivait 192.168.2.10 dans osmo-ggsn.cfg sur
# TOUTES les VM - operateur 1 partout - pendant que le plan de l'ISO reservait
# 192.168.<noeud+1>.x. Sur le noeud 1 les deux coincidaient et rien ne se
# voyait ; sur le noeud 2, le GGSN se liait a l'adresse du noeud 1.
# La bascule est ici, une fois, et les deux jumelles (start.sh, lib/gabarits.sh)
# en heritent.
_osmo_priv_index() {
    local op="${1:-1}"
    # [2026-08-31] L ORCHESTRATEUR N EST PAS DANS LE CONTENEUR QU IL CREE.
    # La detection ci-dessous demande "suis-je DANS un conteneur ?" et c est la
    # bonne question pour du code qui tourne a l interieur. Mais start.sh, lui,
    # provisionne les conteneurs DEPUIS L HOTE : il prenait donc la branche
    # VM/natif et rendait l index du NOEUD - 1 - pour tous les operateurs.
    # Les deux reseaux prives se retrouvaient sur 192.168.2.0/24, docker
    # refusait le second pour chevauchement, et la boucle s arretait net :
    #     ── Operateur 2 : ... Prive : 192.168.2.10
    #     ✗ Echec creation reseau gsm-net-op2 (192.168.2.0/24)
    # osmo-operator-2 n etait jamais cree, sans qu aucun message ne parle de
    # collision d adresses.
    # OSMO_PRIV_BY_OP=1 dit "je provisionne par operateur" ; start_bridge_mode
    # la pose. C est la seule chose que la detection ne pouvait pas deviner.
    [ "${OSMO_PRIV_BY_OP:-0}" = "1" ] && { printf '%s' "$op"; return; }
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
# ── PLUS AUCUN DECALAGE DE PORTS ────────────────────────────────────────────
# [2026-08-31] Il y avait ici une detection : "5060 est-il pris ? alors decale
# les publications de +100". Elle ne servait qu a une chose - eviter que le
# 5060 publie d un conteneur n entre en conflit avec l Asterisk du natif.
#
# On ne publie PLUS aucun port SIP/RTP pour les conteneurs : ils sont sur un
# bridge routable et se joignent en direct, a leur propre adresse, sur le port
# nominal (verifie : 172.20.0.12:5060 et 172.20.0.13:5060 repondent 401 depuis
# l hote, sans la moindre publication). Le conflit ayant disparu avec sa cause,
# le decalage n a plus d objet - et il tirait avec lui une sonde instantanee,
# donc une course : lancee juste apres l arret du banc, elle voyait 5060 libre,
# ne decalait rien, et le conteneur mourait quand le natif remontait.
#
# Les fonctions ci-dessous gardent leur forme (generate_configs.sh s en sert
# encore pour ecrire les configs) mais rendent desormais les valeurs NOMINALES.
# OSMO_PORT_OFFSET=N reste disponible pour qui voudrait retablir un decalage.
PORT_OFFSET="${OSMO_PORT_OFFSET:-0}"
# Le RTP suit la meme regle : plage nominale, 200 ports par operateur.
linphone_sip_port()  { echo $(( 5060  + ${PORT_OFFSET:-0}      + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + $1 * 200 - 1 )); }
# [2026-08-31] Les boucles de ce fichier enumeraient 1..N en dur, comme celles
# de start.sh avant leur decalage. Avec OP_ID_BASE=2 - les conteneurs prenant
# les rangs 2 et 3, le 1 restant au natif - l operateur 2 se fabriquait donc un
# trunk vers l "operateur 1" a 172.20.0.11, une adresse de dorsale que PERSONNE
# ne porte (le natif est sur l hote), et AUCUN trunk vers l operateur 3.
# Les appels inter-operateurs entre conteneurs ne pouvaient pas aboutir, et
# rien ne le disait : le trunk existe, il pointe simplement dans le vide.
# Les deux jumelles doivent donc partager la meme base.
generate_pjsip_interop_trunks() {
    local op_id=$1 n_operators=$2 remote_op remote_ip
    # ── LES OPERATEURS SOUS LA BASE SONT LES NATIFS ────────────────────────
    # [2026-08-31] La boucle partait DE la base. Avec OP_ID_BASE=2 - les
    # conteneurs prenant les rangs 2..N, le 1 restant au natif sur l hote -
    # op2 ne fabriquait qu un trunk vers op3 : RIEN vers le natif. Un appel
    # 100201 -> 100101 tombait dans le fourre-tout _X. de [interop_out] et
    # sortait en Congestion, sans qu une ligne dise que la route n existe pas.
    # Meme trou que sms-routing.conf, sur le chemin VOIX.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        # Un operateur sous la base est NATIF : il tourne sur l hote, pas dans
        # un conteneur. Vu d un conteneur, l hote est la passerelle du bridge
        # docker - la meme adresse que le pont audio et que sms-routing.conf.
        # NB : match=172.20.0.1 n avale pas les REGISTER Linphone, qui arrivent
        # par la meme passerelle : pjsip.conf pose endpoint_identifier_order=
        # username,ip,anonymous - le username passe avant l IP.
        if [ "$remote_op" -lt "${OP_ID_BASE:-1}" ]; then
            remote_ip="${INTER_NET_GATEWAY:-172.20.0.1}"
        else
            remote_ip=$(op_backbone_ip "$remote_op")
        fi
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
    # ── LES OPERATEURS SOUS LA BASE SONT LES NATIFS ────────────────────────
    # [2026-08-31] La boucle partait DE la base. Avec OP_ID_BASE=2 - les
    # conteneurs prenant les rangs 2..N, le 1 restant au natif sur l hote -
    # op2 ne fabriquait qu un trunk vers op3 : RIEN vers le natif. Un appel
    # 100201 -> 100101 tombait dans le fourre-tout _X. de [interop_out] et
    # sortait en Congestion, sans qu une ligne dise que la route n existe pas.
    # Meme trou que sms-routing.conf, sur le chemin VOIX.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done

    # ── LES SOFTPHONES AUSSI, ET SANS PREFIXE ───────────────────────────────
    # [2026-08-31] Depuis [internal], un Linphone ne pouvait joindre un autre
    # operateur qu'en composant 9 + numero (_9. du gabarit - dont l'exemple
    # « 920001 pour joindre 20001 sur Op2 » date d'ailleurs du plan a CINQ
    # chiffres, abandonne). Compose tel quel, 100201 tombait sur le fourre-tout
    # _X. de [internal] et partait au MSC LOCAL, qui le rendait en
    #     rx MNCC_SETUP_REQ for unknown subscriber number '100201'
    # avant de le ressortir par MNCC vers Asterisk. Le detour aboutissait, mais
    # il consommait une transaction MNCC pour rien et faisait dependre un appel
    # SIP->SIP du bon vouloir du MSC.
    # On declare donc la route explicitement. _<pfx><op>XX est PLUS SPECIFIQUE
    # que _X. : Asterisk la choisit d'office, sans qu'il faille toucher au
    # fourre-tout du gabarit. Gosub(sub-record) comme pour _9., sinon ces
    # appels-la seraient les seuls a ne pas etre enregistres.
    printf '[internal]\n\n'
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== SIP -> INTER-OP Op${remote_op}: \${EXTEN} - CallerID: \${CALLERID(all)} ===)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Goto(interop_out,\${EXTEN},1)

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
    # ── LES OPERATEURS SOUS LA BASE SONT LES NATIFS ─────────────────────────
    # [2026-08-31] start-multi.sh pose OP_ID_BASE=2 : les conteneurs prennent
    # les rangs 2..N et l'operateur 1 reste NATIF, sur l'hote. Comme la boucle
    # part de OP_ID_BASE, il n'apparaissait ni dans [operators] ni dans
    # [routes] - releve dans osmo-operator-2 : « 2 = ... / 3 = ... » et rien
    # pour le 1. Un SMS vers 100101 sortait donc en « No route for
    # destination », et le natif etait injoignable depuis tout le banc.
    # Il existe pourtant : il n'est simplement pas dans un conteneur. On le
    # pointe sur la passerelle du bridge docker, qui EST l'hote vu d'un
    # conteneur - la meme adresse que le pont audio (172.20.0.1).
    local _natif_gw="${INTER_NET_GATEWAY:-172.20.0.1}"
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do printf '%s = %s\n' "$i" "$_natif_gw"; done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"; done
    printf '\n[routes]\n'
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done
    done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
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
# ── LES ADRESSES DE CONTENEUR N ONT RIEN A FAIRE SUR L HOTE ─────────────────
# [2026-08-31] Les gabarits sont ecrits pour un CONTENEUR : ils posent
# l adresse de dorsale de l operateur (172.20.0.<10+N>) et la passerelle du
# bridge docker (172.20.0.1). Sur l hote, aucune des deux n existe.
#
# Ces corrections vivaient dans apply_native_post_patches (generate_configs.sh),
# que start-direct.sh appelle. Mais qosmo-grgsm/run_modules/08-gabarits.sh, lui,
# n appelle QUE apply_config_templates + install_configs_native, et ne source
# meme pas generate_configs.sh : il reappliquait donc les gabarits bruts a
# chaque demarrage du natif et REMETTAIT les adresses de conteneur. Le symptome
# etait un natif affiche en 172.20.0.11 et un ASP qui ne montait jamais, une
# seconde apres qu on ait corrige le fichier a la main.
# (Ce module ne s executait plus depuis un renommage de depot, ce qui cachait
# le probleme derriere un [SKIP] : il est reparu en le reparant.)
#
# On accroche donc ici, dans install_configs_native - le passage OBLIGE du
# natif, quel que soit l appelant. Idempotent : rejouer ne change rien.
_gab_fixups_natifs() {
    local src="$1" f

    # 1. osmo-stp.cfg : le local-ip de l ASP vers l inter-STP. 127.0.0.1 est la
    #    seule adresse dont on soit certain sur un hote. On ne touche QUE le
    #    local-ip qui suit « asp asp-to-inter » : ceux du bloc d ecoute
    #    au-dessus (127.0.0.1 / 127.0.0.2) sont corrects.
    f="$src/osmocom/osmo-stp.cfg"
    if [ -f "$f" ]; then
        awk '
            /^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/ { a = 1; print; next }
            a && /^[[:space:]]*local-ip[[:space:]]/ {
                sub(/local-ip[[:space:]]+.*/, "local-ip 127.0.0.1"); a = 0; print; next
            }
            /^[[:space:]]*(as|asp|cs7|listen)[[:space:]]/ && !/asp-to-inter/ { a = 0 }
            { print }
        ' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    fi

    # 2. mobile.cfg : la cible GSMTAP. 172.20.0.1 disparait avec le bridge, et
    #    les paquets partent alors dans le vide - Wireshark reste vide sur
    #    udp/4729 sans qu aucun message ne le dise.
    for f in "$src/osmocom/mobile.cfg" "$src/bb/mobile.cfg" "$src/bb/mobile_group1.cfg"; do
        [ -f "$f" ] || continue
        sed -i "/^gsmtap\$/,/^!\$/ s/^\([[:space:]]*remote-host[[:space:]]\+\).*/\1127.0.0.1/" "$f"
    done

    # 3. pjsip.conf : sur un hote plat il n y a pas de frontiere NAT a declarer.
    #    external_* fait REECRIRE Contact et SDP pour tout pair hors local_net -
    #    un Linphone du LAN recevait une adresse injoignable. Sans eux, pjsip
    #    repond avec l adresse de la socket, la bonne, par destination.
    f="$src/asterisk/pjsip.conf"
    if [ -f "$f" ]; then
        awk '
            /^\[transport-udp\]/ { t = 1; print; next }
            t && /^\[/            { t = 0 }
            t && /^[[:space:]]*external_(media|signaling)_address[[:space:]]*=/ { next }
            t && /^[[:space:]]*local_net[[:space:]]*=/ {
                if (!d) {
                    print "local_net=127.0.0.0/8"; print "local_net=10.0.0.0/8"
                    print "local_net=172.16.0.0/12"; print "local_net=192.168.0.0/16"
                    print "local_net=176.16.32.0/24"; d = 1
                }
                next
            }
            { print }
        ' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    fi

    # 4. sms-routing.conf : LE NATIF NE CONNAISSAIT QUE LUI-MEME.
    #    [2026-08-31] Releve sur l hote :
    #        [operators]   1 = 172.20.0.11
    #        [routes]      100101 = 1   100102 = 1
    #    Deux erreurs dans quatre lignes. 172.20.0.11 est l adresse de DORSALE
    #    DOCKER de l operateur 1 - elle n existe pas sur l hote, ou le natif
    #    tourne. Et aucun des autres operateurs n y figure : un SMS du natif
    #    vers 100201 sortait en « No route for destination ».
    #
    #    POURQUOI CE FICHIER ETAIT FAUX. apply_native_post_patches
    #    (generate_configs.sh) sait deja ecrire cette table - son propre
    #    commentaire decrit exactement le defaut. Mais elle n est appelee que
    #    par start-direct.sh --regen et build-iso.sh ; le demarrage ordinaire du
    #    natif passe par 08-gabarits.sh, qui ne fait qu appliquer les gabarits
    #    bruts. Le fichier repartait donc a chaque fois sur le fallback ecrit
    #    POUR UN CONTENEUR - le meme piege que les points 1 a 3 ci-dessus, d ou
    #    la correction au meme endroit : install_configs_native est le passage
    #    OBLIGE du natif, quel que soit l appelant.
    #
    #    LA SOURCE DE VERITE est osmo-multi.conf (ecrit par addition.sh) :
    #        MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:... 3:docker:..."
    #    On garde le keying par OPERATEUR, celui des conteneurs : sur un banc a
    #    une machine tout le monde est sur le noeud 1, un keying par noeud les
    #    confondrait. Sans osmo-multi.conf (mono-operateur), on ne touche a rien.
    f="$src/osmocom/sms-routing.conf"
    local mc="${OSMO_MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
    if [ -f "$f" ] && [ -r "$mc" ]; then
        local _ops _node _self _sc _id _mode _ip _e
        _ops="$(sed -n 's/^MULTI_OPS=//p' "$mc" | tr -d '"' | tail -1)"
        _node="$(sed -n 's/^MULTI_NODE=//p' "$mc" | tail -1)"; case "$_node" in [1-9]) ;; *) _node=1 ;; esac
        # Identite : on la RELIT, on ne la recalcule pas - c est elle qui dit
        # quel operateur ce natif est, et elle a pu etre realignee par
        # start-multi.sh (aligner_natif).
        _self="$(sed -n 's/^operator_id[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
        _sc="$(sed -n 's/^sc_address[[:space:]]*=[[:space:]]*//p'  "$f" | head -1)"
        case "$_self" in [1-9]*) ;; *) _self=1 ;; esac
        [ -n "$_sc" ] || _sc="1999001${_self}444"
        if [ -n "$_ops" ]; then
            {
                printf '# sms-routing.conf - natif, reecrit par _gab_fixups_natifs\n'
                printf '# Table issue de %s (MULTI_OPS). Cle = numero d operateur.\n' "$mc"
                printf '# MSISDN = <noeud>00<operateur><rang du MS sur 2 chiffres>\n\n'
                printf '[local]\noperator_id = %s\nsc_address  = %s\n\n[operators]\n' "$_self" "$_sc"
                for _e in $_ops; do
                    IFS=: read -r _id _mode _ip _ <<< "$_e"
                    [ -n "$_id" ] || continue
                    # Le natif, c est NOUS : 127.0.0.1 est la seule adresse dont
                    # on soit certain sur un hote (meme choix qu au point 1).
                    if [ "$_mode" = native ] || [ "$_id" = "$_self" ]; then _ip=127.0.0.1; fi
                    [ -n "$_ip" ] || continue
                    printf '%s = %s\n' "$_id" "$_ip"
                done
                printf '\n[routes]\n'
                for _e in $_ops; do
                    IFS=: read -r _id _mode _ip _ <<< "$_e"
                    [ -n "$_id" ] || continue
                    for _m in 1 2; do
                        printf '%s = %s\n' "$(( _node * 100000 + _id * 100 + _m ))" "$_id"
                    done
                done
                printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
            } > "$f.tmp" && mv -f "$f.tmp" "$f"
        fi
    fi

    # 5. LE CHEMIN VOIX INTER-OPERATEUR : trunks SIP + [interop_out].
    #    [2026-08-31] Meme trou que le point 4, sur la VOIX. Releve sur l hote :
    #        [interop_out] du natif :  _X.  ->  Congestion()   (et rien d autre)
    #        pjsip.conf              :  aucun interop_trunk_opN
    #    Un appel 100101 -> 100201 sortait donc du MSC ...
    #        rx MNCC_SETUP_REQ for unknown subscriber number '100201'
    #    ... passait a osmo-sip-connector, tombait sur le fourre-tout, et
    #    revenait en
    #        INVITE got status(503), releasing leg
    #    Les SMS passaient (point 4), pas les appels : deux chemins, deux tables,
    #    une seule des deux corrigee.
    #
    #    On NE REECRIT PAS la logique : generate_extensions_interop_out et
    #    generate_pjsip_interop_trunks (plus haut dans ce fichier) savent deja
    #    la produire. Elles etaient seulement appelees avec le nombre
    #    d operateurs du CONTENEUR courant - le natif se croyait donc seul.
    #    On les rejoue ici avec la topologie reelle, comme au point 4.
    #    OP_ID_BASE=1 : vu du natif, tous les distants sont des conteneurs et
    #    portent bien une adresse de dorsale ; c est l inverse du cas conteneur,
    #    ou le natif est celui qui n en a pas.
    local mc5="${OSMO_MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
    if [ -r "$mc5" ]; then
        local _ops5 _self5 _n5=0 _e5 _i5
        _ops5="$(sed -n 's/^MULTI_OPS=//p' "$mc5" | tr -d '"' | tail -1)"
        _self5="$(sed -n 's/^operator_id[[:space:]]*=[[:space:]]*//p' "$src/osmocom/sms-routing.conf" 2>/dev/null | head -1)"
        case "$_self5" in [1-9]*) ;; *) _self5=1 ;; esac
        for _e5 in $_ops5; do
            IFS=: read -r _i5 _ <<< "$_e5"
            case "$_i5" in [1-9]*) [ "$_i5" -gt "$_n5" ] && _n5="$_i5" ;; esac
        done
        # Marqueur d idempotence : rejouer install_configs_native ne doit pas
        # empiler les memes extensions (Asterisk refuserait les doublons avec
        # « already in use » et noierait le journal).
        local _mk5='; --- interop natif : ajoute par _gab_fixups_natifs ---'
        if [ "$_n5" -gt 1 ]; then
            f="$src/asterisk/extensions.conf"
            if [ -f "$f" ] && ! grep -qF "$_mk5" "$f"; then
                { printf '\n%s\n' "$_mk5"
                  OP_ID_BASE=1 generate_extensions_interop_out "$_self5" "$_n5"; } >> "$f"
            fi
            f="$src/asterisk/pjsip.conf"
            if [ -f "$f" ] && ! grep -qF "$_mk5" "$f"; then
                { printf '\n%s\n' "$_mk5"
                  OP_ID_BASE=1 generate_pjsip_interop_trunks "$_self5" "$_n5"; } >> "$f"
            fi
        fi
    fi
}

install_configs_native() {
    local src=$1 root="${2:-}"
    _gab_fixups_natifs "$src"
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
