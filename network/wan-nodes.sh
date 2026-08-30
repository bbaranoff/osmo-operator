#!/bin/bash
# =============================================================================
# network/wan-nodes.sh - la TABLE DES NOEUDS WAN, partagee par les 3 lanceurs
# =============================================================================
#
# Ce fichier ne definit que des fonctions et des variables : il est SOURCE par
#   start.sh          (hote docker, N operateurs par noeud)
#   start-direct.sh   (natif / ISO, 1 operateur par noeud)
#   build-iso.sh      (fige la table dans l'ISO)
#   network/setup-wan-mesh.sh  (l'applique a Asterisk / iptables / SMS)
#
# ── MODELE ───────────────────────────────────────────────────────────────────
# Un WAN = N noeuds. Un noeud = (id, ip publique, indicatif).
#
# L'INDICATIF est le prefixe telephonique du noeud, exactement comme un
# indicatif pays : depuis n'importe quel noeud, composer
#       <indicatif_cible><numero>
# joint <numero> sur le noeud qui porte cet indicatif. Le noeud emetteur
# retire l'indicatif avant de sortir sur le WAN ; le noeud d'arrivee recoit
# donc le numero nu, celui que son HLR et son dialplan connaissent deja.
#
# WAN_NODE_ID dit QUI est le noeud local. C'est la seule chose qui distingue
# "ce numero est chez moi" de "ce numero part sur le WAN" : sans lui, un
# noeud se renvoie ses propres appels a l'infini.
#
# ── POURQUOI UNE TABLE ET PAS UN COUPLE local/remote ─────────────────────────
# network/setup-wan-interop.sh (l'existant) ne connait QUE deux serveurs :
# LOCAL_IP et REMOTE_IP. Il reecrit a chaque appel le bloc "WAN INTEROP" de
# pjsip.conf/extensions.conf et remet a zero sa chaine iptables - le lancer en
# boucle sur trois pairs ne laisse donc que le DERNIER. D'ou cette table : on
# genere UN bloc qui contient tous les pairs, en un seul passage.
# -----------------------------------------------------------------------------

# Table : WAN_IP[id] / WAN_IND[id] / WAN_NOPS[id], plus la liste ordonnee des ids.
declare -A WAN_IP  2>/dev/null || true
declare -A WAN_IND 2>/dev/null || true
# WAN_NOPS[id] : combien d'operateurs porte le noeud id. WAN_OPS ne parle que du
# noeud LOCAL, donc tout ce qui genere le maillage devait SUPPOSER les autres
# identiques a soi. L'hote docker en porte deux, une VM un seul : depuis l'hote,
# on fabriquait donc vers la VM un trunk, un pattern _<indicatif>2XXXX et une
# route SMS que personne ne sert - de quoi laisser partir des appels qui
# n'arrivent nulle part. D'ou ce nombre par noeud, quatrieme champ de la table.
declare -A WAN_NOPS 2>/dev/null || true
WAN_NODE_LIST=()
: "${WAN_NODE_COUNT:=0}"
: "${WAN_NODE_ID:=0}"
: "${WAN_OPS:=1}"          # operateurs (PLMN) portes par CE noeud
: "${WAN_CONF_FILE:=/etc/osmo-wan.conf}"
# WAN_DOCKER_HOST : l'adresse LAN de l'hote qui porte docker, celle par laquelle
# une VM route vers le backbone des conteneurs. Elle est en DHCP et a deja
# change sous nos pieds (.101 puis .31) : elle se DECOUVRE a l'execution
# (network/set_ip_vm.sh) et ne se fige jamais ici - la table ne fait que la
# transporter d'une machine a l'autre.
: "${WAN_DOCKER_HOST:=}"

_wanc() { [ -t 1 ] && printf '\033[0;36m%s\033[0m' "$1" || printf '%s' "$1"; }
_wan_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
_wan_err()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; }

# ── Indicatifs par defaut ────────────────────────────────────────────────────
# 11/22/.../99 : un doublet par noeud, aucun n'est prefixe d'un autre (condition
# dure, cf. wan_nodes_validate) et il y en a exactement neuf - la borne des
# noeuds. Le doublet se lit aussi comme le numero du noeud, ce qui rend un
# journal d'appel dechiffrable sans la table sous les yeux.
_WAN_DEFAULT_IND=(11 22 33 44 55 66 77 88 99)
wan_default_ind() {
    local i=$1
    if [ "$i" -ge 1 ] && [ "$i" -le "${#_WAN_DEFAULT_IND[@]}" ]; then
        echo "${_WAN_DEFAULT_IND[$((i-1))]}"
    else
        echo $(( 100 + i ))
    fi
}

# ── Serialisation "id:ip:indicatif[:operateurs] ..." ─────────────────────────
# Le nombre d'operateurs doit repasser par ici, sinon il ne survit pas au
# premier aller-retour : wan_nodes_save serialise avec cette fonction, et une
# table relue annoncait alors 1 operateur partout, y compris pour le noeud qui
# venait d'en declarer deux. Il n'est ecrit que lorsqu'il dit autre chose que 1,
# pour que tout ce qui lit deja WAN_NODES a trois champs (build-iso.sh,
# set_stp_ip.sh, les diagnostics) continue de voir la table qu'il connait.
wan_nodes_spec() {
    local id out="" nops
    for id in "${WAN_NODE_LIST[@]}"; do
        out="${out}${out:+ }${id}:${WAN_IP[$id]}:${WAN_IND[$id]}"
        nops="${WAN_NOPS[$id]:-1}"
        [ "$nops" = "1" ] || out="${out}:${nops}"
    done
    printf '%s' "$out"
}

wan_nodes_parse() {
    local spec="${1:-}" entry id rest ip ind nops
    WAN_IP=(); WAN_IND=(); WAN_NOPS=(); WAN_NODE_LIST=()
    spec="${spec//,/ }"
    for entry in $spec; do
        [ -n "$entry" ] || continue
        case "$entry" in
            *:*:*) ;;
            *) _wan_err "entree noeud invalide : '$entry' (attendu id:ip:indicatif[:operateurs])"; return 1 ;;
        esac
        id="${entry%%:*}"; rest="${entry#*:}"
        ip="${rest%%:*}";  ind="${rest#*:}"
        ind="${ind%%:*}"
        # Quatrieme champ optionnel. Toutes les tables ecrites avant lui - celle
        # de l'ISO, celle deja posee dans /etc/osmo-wan.conf - n'ont que trois
        # champs : elles doivent continuer de se lire, un noeud sans nombre
        # portant un operateur, ce qui est le cas d'une VM.
        nops=1
        case "$entry" in
            *:*:*:*) nops="${rest#*:}"; nops="${nops#*:}"; nops="${nops%%:*}" ;;
        esac
        [ -n "$nops" ] || nops=1
        # Un champ present mais illisible n'est pas rabattu en silence sur 1 :
        # ce serait un maillage prive des operateurs 2..n sans un mot dans le
        # journal - le genre de panne qu'on cherche longtemps.
        if ! [[ "$nops" =~ ^[1-9][0-9]*$ ]]; then
            _wan_err "noeud $id : '$nops' operateurs - attendu un entier >= 1"; return 1
        fi
        WAN_IP[$id]="$ip"; WAN_IND[$id]="$ind"; WAN_NOPS[$id]="$nops"
        WAN_NODE_LIST+=("$id")
    done
    WAN_NODE_COUNT=${#WAN_NODE_LIST[@]}
    [ "$WAN_NODE_COUNT" -gt 0 ] || { _wan_err "table de noeuds vide"; return 1; }
    return 0
}

# ── Validation ───────────────────────────────────────────────────────────────
# Refuse ce qui produirait un routage silencieusement faux, pas seulement ce
# qui est mal ecrit.
wan_nodes_validate() {
    local id other rc=0
    [ "${#WAN_NODE_LIST[@]}" -ge 1 ] || { _wan_err "table de noeuds vide"; return 1; }
    for id in "${WAN_NODE_LIST[@]}"; do
        # 1..9 : un chiffre. C'est ce qui garde <indicatif><operateur><MSISDN>
        # lisible et les patterns Asterisk sans ambiguite de longueur.
        [[ "$id" =~ ^[1-9]$ ]] \
            || { _wan_err "numero de noeud invalide : '$id' (1 a 9)"; rc=1; }
        [[ "${WAN_IP[$id]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { _wan_err "noeud $id : '${WAN_IP[$id]}' n'est pas une IPv4"; rc=1; }
        # ── L'INDICATIF NE DOIT PAS MORDRE SUR LE PLAN DE NUMEROTATION LOCAL ──
        # Les MSISDN du depot valent <noeud>00<op><ms> (100101, 200101...) :
        # six chiffres dont les deux premiers sont "<noeud>0". Un indicatif
        # "10" produirait donc "exten => _10." dans [gsm_in], qui avalerait
        # 100101 - l'abonne local deviendrait injoignable et l'appel partirait
        # sur le WAN. Un indicatif d'UN chiffre a le meme defaut, en pire.
        # Les defauts 11/22/.../99 passent tous cette regle ; c'est la regle
        # "^[1-9]0" ci-dessous qui ecarte 10, 20, ... 90.
        if ! [[ "${WAN_IND[$id]}" =~ ^[0-9]{2,4}$ ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' - 2 a 4 chiffres (1 chiffre entrerait en conflit avec les MSISDN locaux)"; rc=1
        elif [[ "${WAN_IND[$id]}" =~ ^[1-9]0 ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' commence comme un MSISDN local (<noeud>00<op><ms> → 100101, 200101...) - il capterait les appels locaux ; prenez ${WAN_IND[$id]:0:1}${WAN_IND[$id]:0:1} par exemple"; rc=1
        fi
    done
    # Indicatifs : uniques ET aucun prefixe d'un autre. Un indicatif 3 qui
    # prefixe un indicatif 33 rend les patterns Asterisk (_3. vs _33.) et le
    # longest-prefix du relais SMS dependants de l'ordre - donc imprevisibles.
    for id in "${WAN_NODE_LIST[@]}"; do
        for other in "${WAN_NODE_LIST[@]}"; do
            [ "$id" = "$other" ] && continue
            if [ "${WAN_IND[$id]}" = "${WAN_IND[$other]}" ]; then
                _wan_err "noeuds $id et $other partagent l'indicatif ${WAN_IND[$id]}"; rc=1
            elif [ "${WAN_IND[$other]#${WAN_IND[$id]}}" != "${WAN_IND[$other]}" ]; then
                _wan_err "indicatif ${WAN_IND[$id]} (noeud $id) est un prefixe de ${WAN_IND[$other]} (noeud $other)"; rc=1
            fi
            if [ "${WAN_IP[$id]}" = "${WAN_IP[$other]}" ]; then
                _wan_err "noeuds $id et $other partagent l'IP ${WAN_IP[$id]}"; rc=1
            fi
        done
    done
    if [ -n "${WAN_NODE_ID:-}" ] && [ "${WAN_NODE_ID:-0}" != "0" ]; then
        [ -n "${WAN_IP[$WAN_NODE_ID]:-}" ] \
            || { _wan_err "le noeud local ($WAN_NODE_ID) n'est pas dans la table"; rc=1; }
    fi
    return $rc
}

# ── Detection du noeud local par ses adresses ────────────────────────────────
# Une SEULE ISO peut alors servir les N machines : chacune se reconnait a son
# IP. Sans ca il faudrait fabriquer une image par noeud.
wan_nodes_detect_self() {
    local id addrs
    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    [ -n "$addrs" ] || return 1
    for id in "${WAN_NODE_LIST[@]}"; do
        if printf '%s\n' $addrs | grep -qx "${WAN_IP[$id]}"; then
            WAN_NODE_ID="$id"; return 0
        fi
    done
    return 1
}

# ── L'ADRESSE DE CE NOEUD SUR LE SEGMENT WAN ─────────────────────────────────
# "La premiere IP globale" est un mauvais critere sur une VM du banc : il y en
# a au moins trois, et deux sont des pieges.
#   • le NAT VirtualBox - toujours 10.0.2.x - sort vers Internet mais ne voit
#     aucun pair : un ASP lie dessus n'atteint jamais le hub ;
#   • les alias 172.20.0.1 / 172.20.0.11 / 172.20.1.10 que l'ISO pose elle-meme
#     sur le NIC (build-iso.sh, 20-dhcp.network) - ils appartiennent au plan
#     docker et n'existent sur aucun segment.
# La bonne adresse est celle de la carte "pont" VirtualBox. On la cherche dans
# cet ordre, du plus sur au plus deduit.
wan_detect_local_ip() {
    local addrs a

    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    [ -n "$addrs" ] || return 1

    # 1. La table fait foi - a condition que l'adresse soit reellement montee.
    #    Une table qui annonce une adresse absente est une table perimee, pas
    #    une source d'autorite.
    if [ "${WAN_NODE_ID:-0}" != "0" ] && [ -n "${WAN_IP[${WAN_NODE_ID}]:-}" ]; then
        for a in $addrs; do
            [ "$a" = "${WAN_IP[$WAN_NODE_ID]}" ] && { printf '%s' "$a"; return 0; }
        done
    fi

    # 2. La plage host-only de VirtualBox (192.168.56.0/21), la seule qu'il
    #    autorise sans /etc/vbox/networks.conf. C'est le segment du banc.
    for a in $addrs; do
        case "$a" in
            192.168.5[6-9].*|192.168.6[0-3].*) printf '%s' "$a"; return 0 ;;
        esac
    done

    # 3. Toute autre adresse en 192.168.x : c'est la carte "pont" (acces par
    #    pont / bridged adapter), celle qui met la VM sur le meme reseau que
    #    l'hote. C'est l'adresse par laquelle les pairs la joignent.
    for a in $addrs; do
        case "$a" in 192.168.*) printf '%s' "$a"; return 0 ;; esac
    done

    # 4. A defaut, la premiere adresse qui ne soit ni le NAT VirtualBox, ni un
    #    alias du plan docker, ni la boucle locale.
    for a in $addrs; do
        case "$a" in
            10.0.2.*|172.20.*|127.*|169.254.*) ;;
            *) printf '%s' "$a"; return 0 ;;
        esac
    done

    return 1
}

wan_local_ip()  { printf '%s' "${WAN_IP[${WAN_NODE_ID}]:-}"; }
wan_local_ind() { printf '%s' "${WAN_IND[${WAN_NODE_ID}]:-}"; }

# ── Saisie ───────────────────────────────────────────────────────────────────
# whiptail quand on en a un ET un terminal ; sinon `read`. Le mode "ni l'un ni
# l'autre" (cron, CI, docker exec -d) n'invente rien : il echoue en nommant
# les variables a poser.
_wan_ask() {   # titre  question  defaut
    local title="$1" q="$2" def="${3:-}" ans
    if [ -t 0 ] && [ -t 2 ] && command -v whiptail >/dev/null 2>&1 && [ -z "${WAN_NO_WHIPTAIL:-}" ]; then
        ans=$(whiptail --backtitle "osmo_egprs - WAN" --title "$title" \
                --inputbox "$q" 10 72 "$def" 3>&1 1>&2 2>&3) || return 1
    elif [ -t 0 ]; then
        printf '  %s [%s] : ' "$q" "$def" >&2
        read -r ans || return 1
    else
        _wan_err "pas de terminal : renseignez WAN_NODES / WAN_NODE_ID / WAN_OPS"
        return 1
    fi
    printf '%s' "${ans:-$def}"
}

# wan_nodes_prompt [nb_ops_local]
#   1. combien de noeuds
#   2. pour CHAQUE noeud : son IP publique, puis son indicatif
#   3. quel numero porte le noeud construit par ce lancement
wan_nodes_prompt() {
    local n i ip ind me auto_ip def_n
    def_n="${WAN_NODE_COUNT:-0}"; [ "$def_n" -lt 1 ] && def_n=3

    n=$(_wan_ask "WAN - noeuds" "Nombre de noeuds du WAN (1-9) :" "$def_n") || return 1
    [[ "$n" =~ ^[1-9]$ ]] \
        || { _wan_err "nombre de noeuds invalide : '$n' (1 a 9)"; return 1; }

    auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # ${x[@]+"${x[@]}"} : sous `set -u`, un tableau VIDE developpe sans cette
    # garde est une erreur fatale sur bash < 4.4 - et la premiere saisie part
    # justement d'une table vide.
    local -a old_list=(${WAN_NODE_LIST[@]+"${WAN_NODE_LIST[@]}"})
    local -A old_ip old_ind
    for i in "${old_list[@]}"; do old_ip[$i]="${WAN_IP[$i]}"; old_ind[$i]="${WAN_IND[$i]}"; done
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()

    for i in $(seq 1 "$n"); do
        ip=$(_wan_ask "WAN - noeud $i/$n" "IP publique du noeud $i :" "${old_ip[$i]:-}") || return 1
        ind=$(_wan_ask "WAN - noeud $i/$n" "Indicatif du noeud $i (prefixe d'appel) :" \
                       "${old_ind[$i]:-$(wan_default_ind "$i")}") || return 1
        WAN_IP[$i]="$ip"; WAN_IND[$i]="$ind"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$n"

    # Numero du noeud LOCAL. On propose celui dont l'IP est la notre.
    me="${WAN_NODE_ID:-0}"
    if [ "$me" = "0" ] && [ -n "$auto_ip" ]; then
        for i in "${WAN_NODE_LIST[@]}"; do [ "${WAN_IP[$i]}" = "$auto_ip" ] && me="$i"; done
    fi
    [ "$me" = "0" ] && me=1
    me=$(_wan_ask "WAN - ce noeud" "Numero du noeud construit par ce lancement (1-$n) :" "$me") || return 1
    [[ "$me" =~ ^[0-9]+$ ]] && [ -n "${WAN_IP[$me]:-}" ] \
        || { _wan_err "noeud local '$me' hors table"; return 1; }
    WAN_NODE_ID="$me"

    wan_nodes_validate || return 1
    return 0
}

# ── Persistance ──────────────────────────────────────────────────────────────
wan_nodes_save() {
    local f="${1:-$WAN_CONF_FILE}" host="${WAN_DOCKER_HOST:-}"
    mkdir -p "$(dirname "$f")"
    # L'hote docker n'est connu que de qui vient de le decouvrir. Comme ce
    # fichier est reecrit ENTIER a chaque sauvegarde, une sauvegarde faite par un
    # script qui ne l'a pas dans son environnement effacait l'adresse : la VM
    # perdait, sans rien dire, la seule indication de par ou joindre le
    # backbone. On relit donc celle qui est deja dans le fichier avant d'ecrire.
    if [ -z "$host" ] && [ -r "$f" ]; then
        host="$(sed -n 's/^WAN_DOCKER_HOST=//p' "$f" | tr -d "\"' " | tail -1)"
    fi
    cat > "$f" <<EOF
# /etc/osmo-wan.conf - table des noeuds WAN (genere par network/wan-nodes.sh)
# Format : WAN_NODES="id:ip:indicatif[:operateurs] ..."  (operateurs : defaut 1)
WAN_NODES="$(wan_nodes_spec)"
WAN_NODE_COUNT=${WAN_NODE_COUNT}
WAN_NODE_ID=${WAN_NODE_ID}
WAN_OPS=${WAN_OPS}
# WAN_AUTO=1 : les lanceurs appliquent le WAN sans qu'on repasse --wan.
WAN_AUTO=${WAN_AUTO:-0}
EOF
    # Ecrite seulement si on la connait : une ligne vide serait lue comme une
    # passerelle, et une passerelle vide ne se distingue pas d'une passerelle
    # fausse au moment de poser la route.
    if [ -n "$host" ]; then
        {
            printf '# Hote qui porte docker, par ou une VM route vers le backbone des\n'
            printf '# conteneurs. Adresse DHCP : elle se redecouvre, elle ne se fige pas.\n'
            printf 'WAN_DOCKER_HOST="%s"\n' "$host"
        } >> "$f"
    fi
    return 0
}

wan_nodes_load() {
    local f="${1:-$WAN_CONF_FILE}"
    [ -r "$f" ] || return 1
    # Le sourcing ramene WAN_NODES, le noeud local, et WAN_DOCKER_HOST quand le
    # fichier la porte - c'est par elle qu'une VM sait vers qui router 172.20.
    # shellcheck disable=SC1090
    . "$f"
    wan_nodes_parse "${WAN_NODES:-}" || return 1
    return 0
}

wan_nodes_summary() {
    local id tag
    printf '  Noeuds WAN : %s   (ce noeud : %s)\n' "$WAN_NODE_COUNT" "$(_wanc "${WAN_NODE_ID}")"
    for id in "${WAN_NODE_LIST[@]}"; do
        tag="   "; [ "$id" = "${WAN_NODE_ID}" ] && tag="◀ ce noeud"
        printf '    node %-2s  %-15s  indicatif %-4s %s\n' "$id" "${WAN_IP[$id]}" "${WAN_IND[$id]}" "$tag"
    done
    printf '    Composer %s + numero pour joindre le noeud correspondant.\n' \
        "$(_wanc "<indicatif>")"
}
