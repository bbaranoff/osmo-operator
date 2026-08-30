#!/bin/bash
# =============================================================================
# network/set_ip_vm.sh - rend une VM capable de joindre les conteneurs docker
#
# Le probleme, en une ligne : l'ISO pose sur le NIC des adresses du plan docker
# (172.20.0.1/24, 172.20.0.11/24, 172.20.1.10/24) heritees du temps ou tout
# tournait sur une seule machine. Sur un banc ou les conteneurs vivent sur un
# HOTE a part, ces adresses mentent :
#
#   1. le /24 fait croire que 172.20.0.0/24 est sur le lien local. La VM l'ARP
#      donc sur le LAN au lieu de le router, et
#          ip route add 172.20.0.0/24 via <hote>
#      est refuse d'un "RTNETLINK answers: File exists".
#   2. 172.20.0.11 est l'adresse du PREMIER CONTENEUR operateur. La VM se
#      repond a elle-meme : la panne la plus deroutante du lot, puisque tout
#      "fonctionne" en local et que rien n'arrive jamais au conteneur.
#
# Ce script retire ce qui ment, garde ce qui sert, et pose la route. Tout est
# deduit a l'execution - interface, adresses presentes, reseaux - rien n'est
# ecrit en dur : la meme commande vaut sur les trois VM du banc.
#
# CE QU'IL NE FAIT PAS : casser une pile qui tourne. Une adresse sur laquelle un
# demon ecoute est signalee et CONSERVEE, sauf --force. Mieux vaut un routage
# incomplet qu'un osmo-stp qui ne redemarre plus.
#
# Usage :
#   sudo network/set_ip_vm.sh --via 192.168.1.101      l'hote qui porte docker
#   sudo network/set_ip_vm.sh                          --via demande, ou relu
#   sudo network/set_ip_vm.sh --status                 etat, sans rien changer
#   sudo network/set_ip_vm.sh --undo                   retire la route posee
#
#   --via ADRESSE      hote docker (routeur vers le backbone)
#   --docker-net CIDR  backbone des conteneurs (defaut 172.20.0.0/24)
#   --iface NOM        interface (defaut : celle de la route par defaut)
#   --keep ADRESSE     adresse a NE PAS retirer (repetable)
#   --force            retire meme les adresses sur lesquelles un demon ecoute
#   --hub-ip ADRESSE   ecrit l'inter-STP a viser dans osmo-stp.cfg, leve le
#                      shutdown de l'ASP, puis aligne la source sur la route
#                      qui y mene. Sans elle, on ne fait qu'aligner la source.
#   --no-stp           ne touche pas a osmo-stp.cfg (source de l'ASP)
#   --defaut           applique la configuration du banc sans rien demander.
#                      L'hote docker n'est PAS suppose : il est cherche sur le
#                      reseau lu sur l'interface - la seule machine qui sache
#                      joindre le backbone des conteneurs. --via le fixe.
#   --persist          rejoue au boot (unite systemd)
#   --dry-run          montre, n'applique pas
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOCKER_NET="172.20.0.0/24"
VIA=""
IFACE=""
FORCE=0
NO_STP=0
# --hub-ip : l'inter-STP que cet ASP doit viser. Sans elle, on ne fait
# qu'ALIGNER la source sur le remote-ip deja ecrit - ce qui ne vaut rien quand
# ce remote-ip est reste le defaut du gabarit (127.0.0.1) : on validerait une
# configuration qui ne joindra jamais personne. Avec elle, on ECRIT la
# destination, puis la source qui y mene.
HUB_IP=""
USE_DEFAULTS=0
# ── La configuration du banc, en un mot ─────────────────────────────────────
# --defaut applique ce qui est vrai sur toutes nos VM sans rien demander :
# l'hote qui porte docker, le backbone des conteneurs, et la persistance au
# boot (le live n'en a aucune, la route serait perdue au redemarrage).
# Chaque valeur reste surchargeable : --defaut --via X gagne sur le defaut.
DEFAULT_VIA=""                  # decouvert : voir discover_docker_host()
DEFAULT_DOCKER_NET="172.20.0.0/24"
DRY=0
PERSIST=0
ACTION="apply"
KEEP=()
STATE=/etc/osmo-docker-host          # memoire du --via, pour ne le taper qu'une fois

while [ $# -gt 0 ]; do
    case "$1" in
        --via)          VIA="${2:-}"; shift ;;
        --via=*)        VIA="${1#*=}" ;;
        --docker-net)   DOCKER_NET="${2:-}"; shift ;;
        --docker-net=*) DOCKER_NET="${1#*=}" ;;
        --iface)        IFACE="${2:-}"; shift ;;
        --iface=*)      IFACE="${1#*=}" ;;
        --keep)         KEEP+=("${2:-}"); shift ;;
        --keep=*)       KEEP+=("${1#*=}") ;;
        --force)        FORCE=1 ;;
        --hub-ip)       HUB_IP="${2:-}"; shift ;;
        --hub-ip=*)     HUB_IP="${1#*=}" ;;
        --no-stp)       NO_STP=1 ;;
        --defaut|--default) USE_DEFAULTS=1 ;;
        --persist)      PERSIST=1 ;;
        --dry-run)      DRY=1 ;;
        --status)       ACTION="status" ;;
        --undo)         ACTION="undo" ;;
        -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

run() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }

# ── Trouver l'hote docker, sans le nommer ───────────────────────────────────
# Une adresse en dur ne survit pas au banc : il a suffi que l'hote passe de
# l'ethernet au wifi pour qu'il change d'adresse, et toutes les VM se sont mises
# a router vers une machine qui n'existait plus - aller sans retour, "connect
# failed" partout, sans qu'aucune configuration n'ait bouge.
#
# On le cherche donc par ce qu'il FAIT, pas par ce qu'il s'appelle : c'est la
# seule machine du LAN qui sait joindre le backbone des conteneurs. Pour chaque
# machine vivante, on pose la route a l'essai et on tente d'atteindre le premier
# conteneur ; celle qui repond est l'hote. La route est retiree si l'essai
# echoue - rien ne subsiste d'une tentative infructueuse.
discover_docker_host() {
    local prefix probe live c saved
    # Cette fonction POSE des routes pour trouver la bonne : elle ne passe pas
    # par run(), donc --dry-run modifiait quand meme la table de routage de la
    # machine. Un mode qui annonce "montre, n'applique pas" doit tenir parole.
    if [ "$DRY" = 1 ]; then
        echo -e "    [dry-run] decouverte sautee : elle pose des routes a l'essai - donnez --via" >&2
        return 1
    fi
    # Et sans root, "ip route replace" echoue silencieusement a chaque candidat :
    # la boucle allait au bout, VIA ressortait vide, et --defaut sortait en
    # "--via manquant" - un message qui designe la mauvaise cause. Le controle
    # de root n'arrive que cinquante lignes plus bas, trop tard pour celui-ci.
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "    decouverte impossible sans root (elle pose des routes a l'essai) - donnez --via" >&2
        return 1
    fi
    # Le reseau se lit sur l'interface, il n'est jamais suppose.
    [ -n "$LAN_IP" ] || return 1
    prefix="${LAN_IP%.*}"
    probe="$(echo "$DOCKER_NET" | cut -d. -f1-3).11"   # le premier conteneur

    echo -e "  ${CYAN}Recherche de l'hote docker sur ${prefix}.0/24...${NC}" >&2
    # 1. qui est vivant ? (en parallele, une seconde au total)
    live="$(for c in $(seq 1 254); do
                [ "${prefix}.${c}" = "$LAN_IP" ] && continue
                ping -c1 -W1 "${prefix}.${c}" >/dev/null 2>&1 && echo "${prefix}.${c}" &
            done; wait)"
    [ -n "$live" ] || return 1

    # 2. lequel route vers les conteneurs ?
    saved="$(ip -4 route show "$DOCKER_NET" 2>/dev/null | head -1)"
    for c in $live; do
        ip route replace "$DOCKER_NET" via "$c" 2>/dev/null || continue
        if ping -c1 -W1 "$probe" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} hote docker : ${CYAN}${c}${NC} (il joint ${probe})" >&2
            printf '%s' "$c"; return 0
        fi
    done
    # rien trouve : on remet ce qui etait la
    ip route del "$DOCKER_NET" 2>/dev/null || true
    [ -n "$saved" ] && ip route add $saved 2>/dev/null || true
    return 1
}

# ── L'interface : celle qui porte la route par defaut ───────────────────────
[ -n "$IFACE" ] || IFACE="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')"
[ -n "$IFACE" ] || { echo -e "${RED}Aucune interface par defaut - precisez --iface${NC}" >&2; exit 1; }

# ── L'adresse de la machine SUR LE LAN ──────────────────────────────────────
# Prise sur la route par defaut, pas dans la liste des adresses : depuis que
# l'ISO pose aussi le plan prive (192.168.<n>.1/32 et .10/32), un simple "la
# premiere qui n'est pas 172.20" tombait sur 192.168.2.1 - une adresse locale,
# sur aucun segment. La decouverte de l'hote balayait alors le mauvais reseau.
# La source de la route par defaut, elle, est par construction celle qui sort.
LAN_IP="$(ip route show default 2>/dev/null | awk '/^default/{print $9; exit}')"
[ -n "$LAN_IP" ] || LAN_IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
          | awk '$0 !~ /\/32/ {print $4}' | cut -d/ -f1 | grep -vE '^172\.20\.' | head -1)"

# ── --defaut : la table du banc, sans rien demander ─────────────────────────
# Ce bloc vient APRES la lecture de l'interface et de l'adresse LAN, et il doit
# y rester : discover_docker_host balaye le reseau lu sur l'interface. Tant
# qu'il etait place avant, LAN_IP n'existait pas encore et set -u tuait le
# sous-shell de la substitution - la recherche ne demarrait donc jamais, VIA
# restait vide, et --defaut ressortait sur "--via manquant" (code 2) alors que
# son role est justement de ne rien avoir a demander.
if [ "$USE_DEFAULTS" = "1" ]; then
    [ -n "$VIA" ] || VIA="$(awk -F= '/^OSMO_DOCKER_HOST=/{print $2}' "$STATE" 2>/dev/null | tr -d ' \r')"
    [ -n "$VIA" ] || VIA="$(discover_docker_host || true)"
    [ "$DOCKER_NET" = "172.20.0.0/24" ] && DOCKER_NET="$DEFAULT_DOCKER_NET"
    PERSIST=1
    echo -e "${CYAN}  --defaut : hote docker ${VIA}, backbone ${DOCKER_NET}, rejoue au boot${NC}"
fi

# Le prefixe du plan docker, pour reconnaitre les adresses a retirer :
# 172.20.0.0/24 -> "172.20." (on ratisse le /16, car l'ISO pose aussi 172.20.1.x)
DOCKER_PREFIX="$(echo "$DOCKER_NET" | cut -d. -f1-2)."

echo -e "${CYAN}${BOLD}== Adressage VM vers les conteneurs docker ==${NC}"
echo -e "  interface : ${CYAN}${IFACE}${NC}   adresse LAN : ${CYAN}${LAN_IP:-?}${NC}"
echo -e "  backbone  : ${CYAN}${DOCKER_NET}${NC}"

# ── Ce qui traine ───────────────────────────────────────────────────────────
mapfile -t STALE_ADDRS < <(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
    | awk '{print $4}' | grep "^${DOCKER_PREFIX}" || true)
mapfile -t STALE_ROUTES < <(ip -4 route show dev "$IFACE" 2>/dev/null \
    | awk '$1 ~ /^'"${DOCKER_PREFIX//./\\.}"'/ && /scope link/ {print $1}' || true)

# ── --status ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    echo ""
    if [ "${#STALE_ADDRS[@]}" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} aucune adresse ${DOCKER_PREFIX}x sur ${IFACE}"
    else
        echo -e "  ${YELLOW}adresses du plan docker encore posees :${NC}"
        for a in "${STALE_ADDRS[@]}"; do echo "    $a"; done
    fi
    cur="$(ip -4 route show "$DOCKER_NET" 2>/dev/null | head -1)"
    if echo "$cur" | grep -q " via "; then
        echo -e "  ${GREEN}✓${NC} route : ${cur}"
    elif [ -n "$cur" ]; then
        echo -e "  ${RED}✗${NC} route CONNECTEE (pas de via) : ${cur}"
        echo -e "     tant qu'elle existe, les conteneurs sont injoignables."
    else
        echo -e "  ${YELLOW}–${NC} aucune route vers ${DOCKER_NET}"
    fi
    exit 0
fi

[ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] \
    || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }

# ── --undo ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "undo" ]; then
    run ip route del "$DOCKER_NET" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route retiree" \
        || echo -e "  ${YELLOW}–${NC} pas de route a retirer"
    rm -f /etc/systemd/system/osmo-docker-route.service 2>/dev/null && \
        systemctl disable osmo-docker-route.service >/dev/null 2>&1
    exit 0
fi

# ── L'hote docker ───────────────────────────────────────────────────────────
# Memorise : on ne le tape qu'une fois par machine. Sans terminal et sans
# memoire, on s'arrete plutot que d'inventer une passerelle.
[ -n "$VIA" ] || VIA="$(awk -F= '/^OSMO_DOCKER_HOST=/{print $2}' "$STATE" 2>/dev/null | tr -d ' \r')"
if [ -z "$VIA" ] && [ -t 0 ]; then
    def=""
    [ -n "$LAN_IP" ] && def="${LAN_IP%.*}.101"
    printf '  Adresse de l hote qui porte docker [%s] : ' "${def:-?}"
    read -r VIA || VIA=""
    [ -n "$VIA" ] || VIA="$def"
fi
if [ -z "$VIA" ]; then
    echo -e "  ${RED}✗ --via manquant : j'ignore par ou joindre ${DOCKER_NET}${NC}" >&2
    exit 2
fi
if ! [[ "$VIA" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo -e "  ${RED}✗ '${VIA}' n'est pas une IPv4${NC}" >&2; exit 2
fi
echo -e "  hote docker : ${CYAN}${VIA}${NC}"

# ── Ce script est pour les VM. Pas pour l'hote qui porte docker ─────────────
# Lance sur l'hote, il pose une route vers LUI-MEME et prend le pas sur la route
# connectee du bridge docker. Resultat immediat : "Destination Host Unreachable"
# vers ses propres conteneurs - alors qu'ils tournent tres bien.
#
# Deux signes le trahissent, et un seul suffit :
#   - --via est une adresse locale ;
#   - un bridge porte deja le reseau des conteneurs.
#
# Attention a ne pas confondre les deux facons de "porter" ce reseau :
#   un BRIDGE docker (br-xxxx, docker0)  -> c'est l'hote, on s'arrete ;
#   une carte ordinaire (enp0s3...)      -> ce sont justement les alias perimes
#                                           de l'ISO, et c'est notre travail.
# Un premier jet refusait les deux et bloquait donc sur la VM qu'il devait
# reparer.
_self=0
ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -qx "$VIA" && _self=1
_dev="$(ip -4 -o route show "$DOCKER_NET" 2>/dev/null | awk '/proto kernel/{print $3; exit}')"
_bridge=""
case "$_dev" in br-*|docker*|virbr*) _bridge="$_dev" ;; esac
if [ "$_self" = 1 ] || [ -n "$_bridge" ]; then
    echo ""
    echo -e "  ${RED}✗ Cette machine EST l'hote docker - rien a faire ici.${NC}" >&2
    [ "$_self" = 1 ] && echo -e "     ${VIA} est une de ses propres adresses." >&2
    [ -n "$_bridge" ] && echo -e "     ${DOCKER_NET} est deja porte par ${_bridge}." >&2
    echo -e "  ${YELLOW}Ce script se lance SUR LES VM${NC}, pour leur apprendre le chemin" >&2
    echo -e "  vers les conteneurs. Cote hote, c'est l'autre script :" >&2
    echo -e "     ${CYAN}sudo network/setup-docker-lan-route.sh --push \"<ip des VM>\"${NC}" >&2
    exit 2
fi
echo ""

# ── 1. Retirer ce qui ment ──────────────────────────────────────────────────
# Une adresse sur laquelle un demon ECOUTE n'est pas retiree : la supprimer
# ferait tomber le service qui s'y est lie, et le probleme deviendrait pire que
# celui qu'on corrige.
for a in ${STALE_ADDRS[@]+"${STALE_ADDRS[@]}"}; do
    ip_only="${a%%/*}"
    skip=0
    for k in ${KEEP[@]+"${KEEP[@]}"}; do [ "$k" = "$ip_only" ] && skip=1; done
    if [ "$skip" = 1 ]; then
        echo -e "  ${CYAN}–${NC} ${a} conservee (--keep)"; continue
    fi
    if [ "$FORCE" != 1 ] && ss -Hlnp 2>/dev/null | grep -q "[^0-9]${ip_only}:"; then
        echo -e "  ${YELLOW}⚠${NC} ${a} CONSERVEE : un demon y ecoute"
        echo -e "     (relancez la pile puis --force, ou --keep pour l'assumer)"
        continue
    fi
    # Une adresse qu'une CONFIG nomme, meme si rien n'ecoute encore. C'est le
    # cas au repos : la pile est arretee, aucun socket ouvert, et pourtant
    # osmo-ggsn.cfg dit "gtp bind-ip 172.20.1.10". La retirer donne, au
    # demarrage suivant, un service qui refuse de partir sur une adresse
    # "introuvable localement" - et le lien avec ce script est loin.
    if [ "$FORCE" != 1 ]; then
        _ref="$(grep -rlF "$ip_only" /etc/osmocom /etc/asterisk 2>/dev/null | head -3)"
        if [ -n "$_ref" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${a} CONSERVEE : nommee dans une configuration"
            printf '     %s\n' $_ref
            echo -e "     (corrigez la config - 127.0.0.1 convient en natif - puis --force)"
            continue
        fi
    fi
    run ip addr del "$a" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} ${a} retiree" \
        || echo -e "  ${YELLOW}–${NC} ${a} deja absente"
done

for r in ${STALE_ROUTES[@]+"${STALE_ROUTES[@]}"}; do
    run ip route del "$r" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route connectee ${r} retiree"
done

# ── 2. Poser la route ───────────────────────────────────────────────────────
# 'replace' plutot que 'add' : idempotent, et il ne bute pas sur un reste.
if run ip route replace "$DOCKER_NET" via "$VIA" dev "$IFACE"; then
    echo -e "  ${GREEN}✓${NC} ${DOCKER_NET} via ${CYAN}${VIA}${NC}"
else
    echo -e "  ${RED}✗${NC} route refusee - une adresse du plan docker subsiste ?"
    echo -e "     ${CYAN}ip -4 addr show dev ${IFACE} | grep ${DOCKER_PREFIX}${NC}"
    exit 1
fi

# ── 2bis. L'ASP doit partir de l'adresse qui ROUTE ──────────────────────────
# Poser la route ne suffit pas si osmo-stp se lie a une autre adresse. Une VM du
# banc en porte plusieurs - le pont, et le plan prive de l'ISO (192.168.<n>.1 et
# .10) - et l'auto-detection choisissait volontiers une adresse privee. Le hub
# ne peut alors pas repondre : l'association n'aboutit jamais et le journal ne
# dit que "connect failed (-110)", un timeout, sans nommer la source fautive.
#
# On aligne donc la source de l'ASP sur ce que le noyau utilisera reellement
# pour joindre le hub - la meme regle que network/set-node-id.sh.
STP_CFG="${STP_CFG:-/etc/osmocom/osmo-stp.cfg}"
if [ "${NO_STP:-0}" != "1" ] && [ -w "$STP_CFG" ]; then
    # --hub-ip fait autorite ; sinon on lit ce que le fichier declare deja.
    if [ -n "$HUB_IP" ]; then
        _hub="$HUB_IP"
        _cur_hub="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$STP_CFG")"
        if [ "$_cur_hub" != "$_hub" ]; then
            if [ "$DRY" = 1 ]; then
                echo -e "  [dry-run] ASP remote-ip ${_cur_hub:-?} -> ${_hub}"
            else
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *remote-ip \).*/\1${_hub}/" "$STP_CFG"
                # Un ASP en shutdown ne s'attache pas, meme bien adresse : on le
                # leve, sinon la correction reste sans effet visible.
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *\)shutdown[[:space:]]*$/\1no shutdown/" "$STP_CFG"
                echo -e "  ${GREEN}✓${NC} ASP : hub ${CYAN}${_hub}${NC} (etait ${_cur_hub:-aucun})"
            fi
        fi
    else
        _hub="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$STP_CFG")"
    fi
    # Un remote-ip en boucle locale n'est pas un hub : c'est le defaut du
    # gabarit, laisse par une regeneration qui a efface l'identite du noeud.
    # Aligner la source dessus validerait une configuration morte - "source
    # deja correcte (127.0.0.1)" sur un ASP qui ne joindra jamais personne.
    case "$_hub" in
        127.*|0.0.0.0|"")
            echo -e "  ${YELLOW}⚠${NC} ASP : remote-ip=${_hub:-vide} - ce n'est pas un hub."
            echo -e "     L'identite SS7 n'a pas ete appliquee : ${CYAN}./start-direct.sh --node N --hub-ip <hub>${NC}"
            _hub="" ;;
    esac
    if [ -n "$_hub" ]; then
        _src="$(ip route get "$_hub" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
        _cur="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$STP_CFG")"
        if [ -n "$_src" ] && [ "$_src" != "$_cur" ]; then
            if [ "$DRY" = 1 ]; then
                echo -e "  [dry-run] ASP local-ip ${_cur:-?} -> ${_src}"
            else
                sed -i "/asp asp-to-inter/,/^ *as / s/^\( *local-ip \).*/\1${_src}/" "$STP_CFG"
                echo -e "  ${GREEN}✓${NC} ASP : source ${CYAN}${_src}${NC} (etait ${_cur:-aucune}) vers le hub ${_hub}"
                if systemctl is-active osmo-stp >/dev/null 2>&1; then
                    systemctl restart osmo-stp \
                        && echo -e "  ${GREEN}✓${NC} osmo-stp relance pour prendre la nouvelle source"
                fi
            fi
        else
            echo -e "  ${GREEN}✓${NC} ASP : source deja correcte (${_cur:-aucune})"
        fi
    fi
fi

[ "$DRY" = 1 ] || printf 'OSMO_DOCKER_HOST=%s\n' "$VIA" > "$STATE" 2>/dev/null || true

# ── 3. Au boot, si demande ──────────────────────────────────────────────────
# Un live sans persistance repart de l'ISO a chaque demarrage : sans unite, tout
# est a refaire. Elle rejoue simplement ce script, qui est idempotent.
if [ "$PERSIST" = 1 ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ "$DRY" = 1 ]; then
        echo "    [dry-run] unite osmo-docker-route.service"
    else
        cat > /etc/systemd/system/osmo-docker-route.service <<EOF
[Unit]
Description=osmo_egprs - route vers les conteneurs docker (${DOCKER_NET})
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${here}/set_ip_vm.sh --via ${VIA} --docker-net ${DOCKER_NET}
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable osmo-docker-route.service >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} rejoue au boot (osmo-docker-route.service)"
    fi
fi

# ── 4. Le controle qui compte ───────────────────────────────────────────────
echo ""
first="$(echo "$DOCKER_NET" | cut -d. -f1-3).11"
echo -e "  ${BOLD}Verifier :${NC} ${CYAN}ip route get ${first}${NC}   doit indiquer via ${VIA}"
if [ "$DRY" != 1 ]; then
    got="$(ip route get "$first" 2>/dev/null | head -1)"
    if echo "$got" | grep -q "via ${VIA}"; then
        echo -e "  ${GREEN}✓${NC} ${got}"
    else
        echo -e "  ${YELLOW}⚠${NC} ${got:-aucune reponse}"
    fi
fi
