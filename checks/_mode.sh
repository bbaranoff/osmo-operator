# =============================================================================
#  checks/_mode.sh - une seule regle de detection docker/natif, pour tous
#                    les scripts de checks/
#  Bibliotheque : a SOURCER, jamais a executer dans une boucle de tests.
# =============================================================================
#
#  POURQUOI CE FICHIER EXISTE
#  --------------------------
#  Le lab vit dans deux mondes, et les checks doivent dire la verite dans les
#  deux :
#
#    docker - un conteneur osmo-operator-N par operateur sur le reseau
#             gsm-inter (172.20.0.0/24), le hub SS7 est le conteneur
#             osmo-inter-stp (172.20.0.10) ; on atteint tout par "docker exec".
#    natif  - ISO, VM ou machine nue : un seul operateur (sauf topologie netns),
#             tout tourne ici, les VTY sont sur 127.0.0.1, les configs dans
#             /etc/osmocom, les demons sont des units systemd ou des processus.
#
#  Les PORTS VTY sont les MEMES dans les deux mondes - seul l'hote change :
#      osmo-stp 4239 · osmo-msc 4254 · osmo-bsc 4242 · osmo-hlr 4258
#      osmo-sgsn 4245 · osmo-ggsn 4260 · osmo-mgw 4243 · mobile/BB 4247
#
#  Avant ce fichier, la meme detection etait recopiee dans cinq scripts, avec
#  cinq variantes : deux d'entre elles employaient "docker ps | grep -q", qui
#  rend 141 sous "set -o pipefail" (grep sort au premier match, le producteur
#  prend un SIGPIPE) - l'inter-STP etait alors declare absent alors qu'il
#  tournait, de facon intermittente. Une seule regle, ecrite une fois, corrigee
#  une fois.
#
#  CONTRAT
#  -------
#   • le fichier ne definit QUE des fonctions et des variables ": =" ;
#     il n'affiche rien, ne pose aucune couleur, ne compte aucun PASS/FAIL :
#     chaque check garde ses ok/fail/warn/skip, donc son format de sortie et
#     son code de retour ;
#   • les sondes rendent 0 = vrai, non-0 = faux ;
#   • sourcable deux fois sans effet de bord (garde OSMO_MODE_LIB_LOADED) ;
#   • aucun "grep -q" en fin de pipeline, aucun "awk ... exit" au milieu d'un
#     tube : sous "set -o pipefail" ces deux formes rendent 141 ;
#   • compatible "set -euo pipefail" chez l'appelant.
#
#  DEUX QUESTIONS DIFFERENTES - POURQUOI start-direct.sh GARDE SA DETECTION
#  ----------------------------------------------------------------------
#  start-direct.sh:159 a sa propre detect_runtime_env(), et elle N'EST PAS un
#  doublon de osmo_mode() : les deux fonctions repondent a deux questions qui
#  n'ont pas la meme reponse.
#
#    detect_runtime_env()  "ou est-ce que JE tourne ?"  → docker | vm | bare
#        Question de l'INTERIEUR du noeud. Elle decide du PLAN D'ADRESSAGE :
#        en docker l'inter-STP est 172.20.0.10 et le noeud a deja son IP ; en
#        VM/ISO l'inter-STP est une autre machine (192.168.1.49 sur le banc, ou une host-only selon le montage) et l'adresse
#        arrive par DHCP, donc peut manquer au lancement.
#
#    osmo_mode()           "comment j'ATTEINS les noeuds d'ici ?" → docker | native
#        Question de PILOTAGE. Elle decide entre "docker exec" et "executer
#        ici".
#
#  Elles se CONTREDISENT volontairement dans un cas, et c'est la preuve qu'il ne
#  faut pas les fusionner : DANS un conteneur du depot, detect_runtime_env rend
#  "docker" (le plan d'adressage est bien celui de docker) alors qu'osmo_mode
#  rend "native" - car "docker exec" vers soi-meme n'a aucun sens, meme
#  quand le socket est monte. Un script qui prendrait l'une pour l'autre
#  s'enverrait des commandes a lui-meme par le demon docker.
#
#  Ce qui EST partage, en revanche, c'est la convention aval : start-direct.sh
#  transmet "--$NODE_MODE" (--docker / --native) a network/setup-wan-mesh.sh
#  (start-direct.sh:756), et c'est exactement ce que consomme osmo_mode_force().
#  Les deux vocabulaires coincident ; seules les fonctions restent distinctes.
#
#  DESIGNER UN NOEUD - <op>
#  -----------------------
#  Toutes les fonctions d'execution prennent en premier argument un <op>, qui
#  accepte indifferemment :
#      3                    le numero d'operateur (forme normale)
#      osmo-operator-3      l'etiquette (ce que rendent osmo_ops/osmo_node)
#      hub | osmo-inter-stp le hub SS7
#  En docker c'est le nom du conteneur ; en natif c'est cette machine, avec le
#  prefixe "ip netns exec osmo-opN" si et seulement si l'espace de noms
#  existe (topologie multi-operateur native, run_modules/12-netns.sh).
#
#  L'ETIQUETTE osmo-operator-N EST CONSERVEE EN NATIF. Ce n'est pas une
#  coquetterie : checks/vty-debug-dump.sh ecrit "container=osmo-operator-N"
#  dans son dump, et checks/operator_summary.sh y accroche quinze extractions.
#  L'etiquette est une cle de correlation, pas un objet interrogeable.
#
#  SOURCING (le meme bloc partout ; marche depuis le depot et depuis /opt) :
#      _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#      for _c in "$_here/_mode.sh" /opt/GSM/osmo_egprs/checks/_mode.sh; do
#          [ -r "$_c" ] && { . "$_c"; break; }
#      done
#      command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }
# =============================================================================

[ -n "${OSMO_MODE_LIB_LOADED:-}" ] && return 0
OSMO_MODE_LIB_LOADED=1

# Racine du depot : ce fichier est dans checks/, la racine est un cran au-dessus.
# Sert a retrouver globals.conf ; surchargeable pour les tests.
_osmo_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OSMO_REPO:=$(dirname "$_osmo_lib_here")}"
unset _osmo_lib_here

# Plan d'adressage de la dorsale inter-operateurs. La MEME valeur sert aux deux
# mondes : docker la pose avec "--network gsm-inter --ip", le natif
# multi-operateur la recree en netns (BACKBONE_NET, run_modules/12-netns.sh:47).
: "${OSMO_BACKBONE_NET:=172.20.0}"
: "${OSMO_NETNS_PREFIX:=${NETNS_PREFIX:-osmo-op}}"

# Prefixe de racine, mode natif seulement : permet de viser un arbre de test
# (OSMO_NATIVE_ROOT=/tmp/essai) au lieu du /etc de la machine. Vide en
# production. Meme role que NATIVE_ROOT dans network/setup-wan-mesh.sh.
: "${OSMO_NATIVE_ROOT:=}"

# Memo "quel client VTY ce noeud possede-t-il ?", pour ne pas relancer un
# "command -v nc" a chaque commande VTY (global_check en passe des dizaines).
# "-g" : la bibliotheque doit rester utilisable meme sourcee DEPUIS une
# fonction, ou un "declare" nu creerait une variable locale qui disparaitrait
# au retour.
declare -gA _OSMO_VTY_TOOL 2>/dev/null || declare -A _OSMO_VTY_TOOL

# =============================================================================
#  1. MODE
# =============================================================================

# osmo_in_container - tourne-t-on DANS un conteneur DE CE DEPOT ?
# /.dockerenv seul serait vrai dans n'importe quel conteneur ; on exige aussi
# /etc/docker-entrypoint-cmd, depose par scripts/entrypoint.sh. C'est le couple
# qu'emploient start.sh:20 et start-direct.sh:159.
osmo_in_container() {
    [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]
}

# Detection, du plus explicite au plus deduit.
_osmo_mode_detect() {
    # Dans un conteneur du depot, on EST le noeud : "docker exec" vers
    # soi-meme n'a pas de sens, meme si le socket docker est monte (c'est le cas
    # du conteneur du dashboard). C'est la regle de start-direct.sh:237.
    if osmo_in_container; then printf 'native\n'; return 0; fi

    # OSMO_NATIVE=1 est deja pose par l'ISO (services/osmo-egprs-web.service).
    if [ "${OSMO_NATIVE:-}" = "1" ]; then printf 'native\n'; return 0; fi

    # LA regle du depot (checks/wan_ss7_check.sh:88, network/setup-wan-mesh.sh:122) :
    # on ne se fie pas a la presence du binaire docker - l'hote du lab l'a, une
    # machine de dev aussi - mais a celle d'un conteneur operateur EN COURS.
    # On capture la liste AVANT de la filtrer : "docker ps | grep -q" rendrait
    # 141 sous pipefail.
    if command -v docker >/dev/null 2>&1; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        if grep -x 'osmo-operator-1' >/dev/null 2>&1 <<<"$names"; then
            printf 'docker\n'; return 0
        fi
    fi
    printf 'native\n'
}

# osmo_mode - ecrit "docker" ou "native". Memoise dans OSMO_MODE, qui fait
# aussi office d'entree : "OSMO_MODE=native ./checks/global_check.sh" force.
osmo_mode() {
    case "${OSMO_MODE:-}" in
        docker|native) : ;;
        *) OSMO_MODE="$(_osmo_mode_detect)" ;;
    esac
    printf '%s\n' "$OSMO_MODE"
}

osmo_is_docker() { [ "$(osmo_mode)" = docker ]; }
osmo_is_native() { [ "$(osmo_mode)" = native ]; }

# osmo_mode_force <docker|native|--docker|--native|--mode=X>
# A glisser tel quel dans la boucle "case" d'analyse des options de chaque
# script : l'explicite gagne toujours sur la detection. Rend 2 sur un argument
# qui n'est pas un mode (l'appelant sait alors que l'option ne le concerne pas).
osmo_mode_force() {
    local m="${1:-}"
    case "$m" in
        --mode=*) m="${m#*=}" ;;
        --docker) m=docker ;;
        --native) m=native ;;
    esac
    case "$m" in
        docker|native) OSMO_MODE="$m"; return 0 ;;
        *) return 2 ;;
    esac
}

# =============================================================================
#  2. INVENTAIRE
# =============================================================================

# Lit une cle de globals.conf ("N_OPERATORS=3"). On lit le fichier avec awk
# directement : pas de tube, donc pas de piege pipefail.
_osmo_globals() {
    local k="${1:-}" f v
    for f in "${OSMO_GLOBALS:-}" "$OSMO_REPO/globals.conf" \
             /opt/GSM/osmo_egprs/globals.conf ./globals.conf; do
        [ -n "$f" ] && [ -r "$f" ] || continue
        v="$(awk -F= -v k="$k" '$1 == k { gsub(/[" \r\t]/, "", $2); if ($2 != "") print $2 }' "$f" | tail -1)"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

# osmo_ops - identifiants des operateurs presents, un par ligne, tries.
#   docker : les conteneurs osmo-operator-N en cours.
#   natif  : $OSMO_OP_IDS (pose par services/osmo-egprs-web.service), puis les
#            netns osmo-opN (multi-operateur natif), puis N_OPERATORS de
#            globals.conf, sinon 1. Aucun inventaire n'existe en natif : la vie
#            d'un noeud se deduit des demons, pas d'une liste de conteneurs.
osmo_ops() {
    local ids=""
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        ids="$(sed -n 's/^osmo-operator-\([0-9][0-9]*\)$/\1/p' <<<"$names")"
    else
        ids="$(tr ', ' '\n\n' <<<"${OSMO_OP_IDS:-}" | sed -n 's/^\([0-9][0-9]*\)$/\1/p')"
        if [ -z "$ids" ]; then
            ids="$(ip netns list 2>/dev/null | awk '{print $1}' \
                   | sed -n "s/^${OSMO_NETNS_PREFIX}\([0-9][0-9]*\)\$/\1/p")"
        fi
        if [ -z "$ids" ]; then
            local n; n="$(_osmo_globals N_OPERATORS || true)"
            case "$n" in ''|*[!0-9]*) n=1 ;; esac
            [ "$n" -ge 1 ] 2>/dev/null || n=1
            ids="$(seq 1 "$n")"
        fi
    fi
    [ -n "$ids" ] || return 0
    sort -n -u <<<"$ids" | sed '/^$/d'
}

# osmo_op_exists <id> - l'operateur existe-t-il ?
# Remplace "docker ps | grep osmo-operator-N" de global_check.sh:131, dont le
# motif n'etait pas ancre : "--op=1" y acceptait aussi osmo-operator-10.
osmo_op_exists() {
    local want="${1:-}" id
    case "$want" in ''|*[!0-9]*) return 2 ;; esac
    while read -r id; do
        [ "$id" = "$want" ] && return 0
    done <<<"$(osmo_ops)"
    return 1
}

# osmo_node <op> - etiquette du noeud : "osmo-operator-N" ou "osmo-inter-stp".
# En docker c'est le nom du conteneur ; en natif c'est un NOM D'AFFICHAGE, et
# c'est ce qui preserve mot pour mot la banniere "OPERATEUR 1 (osmo-operator-1)"
# et le champ "container=" du dump.
osmo_node() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf 'osmo-inter-stp\n' ;;
        osmo-operator-*)    printf '%s\n' "$1" ;;
        [0-9]*)             printf 'osmo-operator-%s\n' "$1" ;;
        *)                  printf '%s\n' "${1:-}" ;;
    esac
}

# Numero d'operateur d'un <op> ; vide pour le hub ou pour l'inconnu.
_osmo_id() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf '' ;;
        osmo-operator-*)    printf '%s\n' "${1##*-}" ;;
        [0-9]*)             printf '%s\n' "$1" ;;
        *)                  printf '' ;;
    esac
}

# osmo_hub - un inter-STP est-il interrogeable ICI ? Ecrit son etiquette si oui.
#   docker : le conteneur osmo-inter-stp tourne.
#   natif  : cette machine EST le hub - OSMO_ROLE=interstp dans /etc/osmo-role
#            (pose par build-iso.sh), ou la sonde de start-interstp.sh:100.
# Sur un noeud operateur natif le hub est une AUTRE machine : rc 1, et c'est
# osmo_hub_hint qui dit quoi faire. Un "0 AS actif" fabrique se lirait comme
# une panne.
osmo_hub() {
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        grep -x 'osmo-inter-stp' >/dev/null 2>&1 <<<"$names" || return 1
        printf 'osmo-inter-stp\n'; return 0
    fi
    if [ -r /etc/osmo-role ] \
       && grep -E '^OSMO_ROLE[[:space:]]*=[[:space:]]*interstp' /etc/osmo-role >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    if pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    return 1
}

# OSMO_HUB_M3UA_PORT - port M3UA du hub inter-STP (helpers/create_interop.sh
# ecrit "listen m3ua 2908"). Les STP operateur, eux, ecoutent sur 2905.
: "${OSMO_HUB_M3UA_PORT:=2908}"

# _osmo_hub_ip_probe - demande aux noeuds operateur ou est leur hub. Deux
# sources, dans cet ordre :
#   1. OSMO_HUB_IP, injecte dans chaque conteneur par start.sh (-e OSMO_HUB_IP)
#      des que --hub-ip / --wan designe un inter-STP hors dorsale docker ;
#   2. le "remote-ip" de l'asp asp-to-inter dans /etc/osmocom/osmo-stp.cfg, qui
#      reste vrai meme sans environnement (conteneur relance a la main, ISO).
# Rend 1 sans rien ecrire si aucun noeud ne sait repondre.
_osmo_hub_ip_probe() {
    local op v=""
    for op in $(osmo_ops 2>/dev/null); do
        v="$(osmo_exec "$op" printenv OSMO_HUB_IP 2>/dev/null | tr -d "\r" | tail -1)"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
        v="$(osmo_exec "$op" cat /etc/osmocom/osmo-stp.cfg 2>/dev/null \
             | awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' | tr -d "\r")"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

# osmo_hub_ip - adresse du hub. Rien a dire → rc 1.
#   docker + hub local  : la dorsale, 172.20.0.10 ;
#   docker sans hub local : l'adresse WAN vue par les operateurs (--hub-ip) ;
#   natif : OSMO_HUB_IP de /etc/osmo-role (idiome de wan_ss7_check.sh:193),
#           puis, a defaut, la meme sonde par les noeuds.
# Le resultat est mis en cache : la sonde coute un "docker exec" par noeud, et
# les checks appellent cette fonction plusieurs fois par passage.
_OSMO_HUB_IP_CACHE=""
osmo_hub_ip() {
    if [ -n "$_OSMO_HUB_IP_CACHE" ]; then
        [ "$_OSMO_HUB_IP_CACHE" = "-" ] && return 1
        printf '%s\n' "$_OSMO_HUB_IP_CACHE"; return 0
    fi
    local v=""
    if [ "$(osmo_mode)" = docker ]; then
        if osmo_hub >/dev/null 2>&1; then
            printf '%s.10\n' "$OSMO_BACKBONE_NET"; return 0
        fi
    else
        [ -r /etc/osmo-role ] && \
            v="$(awk -F= '/^OSMO_HUB_IP=/ { gsub(/[ \r\t]/, "", $2); print $2 }' /etc/osmo-role 2>/dev/null | tail -1)"
    fi
    [ -n "$v" ] || v="$(_osmo_hub_ip_probe 2>/dev/null || true)"
    if [ -z "$v" ]; then _OSMO_HUB_IP_CACHE="-"; return 1; fi
    _OSMO_HUB_IP_CACHE="$v"
    printf '%s\n' "$v"
}

# osmo_hub_is_remote - rc 0 (et ecrit l'IP) quand un hub est CONFIGURE mais
# vit AILLEURS : c'est le cas WAN (--hub-ip / --wan), ou le noeud operateur
# natif. Une adresse de dorsale docker ou de boucle locale sans conteneur hub
# ne compte pas : la, le hub n'est pas distant, il est simplement absent.
osmo_hub_is_remote() {
    local ip
    osmo_hub >/dev/null 2>&1 && return 1
    ip="$(osmo_hub_ip 2>/dev/null)" || return 1
    [ -n "$ip" ] || return 1
    case "$ip" in
        "${OSMO_BACKBONE_NET}."*|127.*|localhost) return 1 ;;
    esac
    printf '%s\n' "$ip"
}

# osmo_hub_assoc [ip] [port] - combien de noeuds locaux ont une association
# SCTP ETABLIE vers le hub ? Le lien inter-STP est du M3UA sur SCTP : une
# sonde TCP ("nc -z" sur 2908) rend "Connection refused" meme quand le lien
# est parfaitement monte. C'est "ss --sctp" qui dit la verite, et il la dit
# depuis le NOEUD, pas depuis l'hote : le conteneur a sa propre pile reseau.
# Ecrit "etablies/total" ; rc 0 si au moins une, 1 si aucune, 2 si la sonde
# n'est pas praticable (ni ss, ni support --sctp, ni noeud interrogeable).
osmo_hub_assoc() {
    local ip="${1:-}" port="${2:-$OSMO_HUB_M3UA_PORT}" op out probed=0 n=0 tot=0 pat
    [ -n "$ip" ] || ip="$(osmo_hub_ip 2>/dev/null || true)"
    [ -n "$ip" ] || return 2
    pat="${ip//./\\.}:${port}"
    for op in $(osmo_ops 2>/dev/null); do
        tot=$((tot+1))
        out="$(osmo_exec "$op" ss -an --sctp 2>/dev/null || true)"
        [ -n "$out" ] || continue
        probed=1
        grep -qE "ESTAB.*[[:space:]]${pat}([[:space:]]|$)" <<<"$out" && n=$((n+1))
    done
    [ "$probed" -eq 1 ] || return 2
    printf '%s/%s\n' "$n" "$tot"
    [ "$n" -gt 0 ]
}

# osmo_hub_hint - phrase prete pour skip(), quand le hub existe mais est
# ailleurs. Le VTY Osmocom n'ecoute que sur 127.0.0.1 (aucune conf du depot ne
# pose de "bind" sous "line vty") : depuis un noeud operateur, l'etat des AS
# et des ASP du hub n'est PAS observable. La commande citee existe deja.
osmo_hub_hint() {
    local ip
    ip="$(osmo_hub_ip 2>/dev/null || true)"
    if [ -n "$ip" ]; then
        printf 'hub distant %s : VTY 4239 non joignable depuis ce noeud - lancez ./start-interstp.sh --status sur le hub\n' "$ip"
    else
        printf 'aucun inter-STP local, et aucune adresse de hub connue ici (OSMO_HUB_IP, --hub-ip) - hub non interrogeable\n'
    fi
}

# =============================================================================
#  3. EXECUTION SUR UN NOEUD
# =============================================================================

# Prefixe netns du mode natif. Vide en mono-operateur : la dorsale et les
# espaces de noms ne sont crees que si N_OPERATORS > 1.
_osmo_ns_cmd() {
    local id ns
    id="$(_osmo_id "${1:-}")"
    [ -n "$id" ] || return 0
    ns="${OSMO_NETNS_PREFIX}${id}"
    if [ -e "/run/netns/$ns" ] || [ -e "/var/run/netns/$ns" ]; then
        printf 'ip netns exec %s' "$ns"
    fi
}

# osmo_exec <op> <argv...> - substitution 1:1 de "docker exec "$container" ...".
osmo_exec() {
    local op="${1:-}"; shift || return 2
    [ $# -ge 1 ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        local c; c="$(osmo_node "$op")"
        [ -n "$c" ] || return 2
        docker exec "$c" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns doit etre decoupe en mots (ip netns exec X)
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# Idem, mais l'entree standard est transmise au noeud ("docker exec -i").
# Interne : reserve au dialogue VTY, ou le tube est l'entree de nc/telnet.
_osmo_exec_in() {
    local op="${1:-}"; shift || return 2
    if [ "$(osmo_mode)" = docker ]; then
        docker exec -i "$(osmo_node "$op")" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# osmo_cat <op> <chemin> - contenu d'un fichier du noeud (conf, marqueur...).
osmo_cat() {
    local op="${1:-}" path="${2:-}"
    [ -n "$path" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        docker exec "$(osmo_node "$op")" cat "$path" 2>/dev/null
    else
        cat "${OSMO_NATIVE_ROOT}${path}" 2>/dev/null
    fi
}

# osmo_ast <op> <commande CLI> - asterisk -rx, identique dans les deux mondes.
osmo_ast() {
    local op="${1:-}" cli="${2:-}"
    [ -n "$cli" ] || return 2
    osmo_exec "$op" asterisk -rx "$cli" 2>/dev/null
}

# osmo_running <op> <demon> - ce demon tourne-t-il sur ce noeud ?
#
# En natif il faut les DEUX formes : sur l'ISO les demons sont des units
# (services/osmo-bts-trx.service...) mais core_svc_start retombe sur un lancement
# detache quand systemd est absent - auquel cas seul pgrep repond.
#
# Le repli "pgrep -f" n'est pas decoratif : /proc/PID/comm est TRONQUE a 15
# caracteres, donc "pgrep -x osmo-sip-connector" (18) ne trouve jamais rien,
# quand bien meme le demon tourne. On retente alors sur la ligne de commande.
#
# Limite assumee du natif multi-operateur : "ip netns exec" n'isole pas les
# PID, la reponse porte donc sur la machine, pas sur l'operateur.
osmo_running() {
    local op="${1:-}" name="${2:-}"
    [ -n "$name" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        osmo_exec "$op" pgrep -x "$name" >/dev/null 2>&1 && return 0
        osmo_exec "$op" pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
        return $?
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" 2>/dev/null && return 0
    fi
    pgrep -x "$name" >/dev/null 2>&1 && return 0
    pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
}

# osmo_sock <op> <chemin> - socket UNIX en ecoute ?
# L'ORDRE EST OBLIGATOIRE : on interroge ss AVANT le test de fichier. Sous
# PrivateTmp, /tmp/msc_mncc EXISTE sans etre visible par "test -S" (constate,
# run_modules/13-msc.sh:14) ; un "test -S" seul donnerait un "voix
# impossible" mensonger.
# awk lit TOUTE son entree (pas d'"exit" au milieu du tube) : sous pipefail,
# un awk qui sort tot ferait mourir ss en SIGPIPE et rendrait 141.
osmo_sock() {
    local op="${1:-}" p="${2:-}" out
    [ -n "$p" ] || return 2
    out="$(osmo_exec "$op" ss -xlH 2>/dev/null || true)"
    awk -v w="$p" '{ for (i = 1; i <= NF; i++) if ($i == w) f = 1 } END { exit !f }' <<<"$out" && return 0
    osmo_exec "$op" test -S "$p" 2>/dev/null
}

# osmo_port <op> <port> [tcp|udp|sctp] - ce port est-il en ecoute sur le noeud ?
# Remplace le "ss -tlnp | grep -c ':7890'" de global_check.sh:493 : pas de
# tube fragile, et ":7890" ne peut plus se confondre avec 17890 ou 78901.
osmo_port() {
    local op="${1:-}" port="${2:-}" proto="${3:-tcp}" out
    local -a opts
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    case "$proto" in
        tcp)  opts=(-H -ltn) ;;
        udp)  opts=(-H -lun) ;;
        sctp) opts=(-H -ln --sctp) ;;
        *)    return 2 ;;
    esac
    out="$(osmo_exec "$op" ss "${opts[@]}" 2>/dev/null || true)"
    # Le 4e champ de ss est "adresse:port" local, pour tcp, udp et sctp.
    awk -v want="$port" '
        { a = $4
          if (a == "" || match(a, /:[0-9]+$/) == 0) next
          if (substr(a, RSTART + 1) == want) f = 1 }
        END { exit !f }' <<<"$out"
}

# osmo_host <op> - l'hote a joindre pour ce noeud DEPUIS ICI (relais SMS, SIP,
# M3UA...). Ce n'est PAS l'hote du VTY : celui-ci est toujours 127.0.0.1 vu de
# l'interieur du noeud, et osmo_vty s'en charge.
#   docker           : l'IP du conteneur sur la dorsale (172.20.0.1N, .10 = hub)
#   natif + netns    : la meme dorsale, recreee en netns
#   natif mono-op    : 127.0.0.1 - il n'y a ni pont gsm-inter ni 172.20.0.0/24
#   hub natif        : OSMO_HUB_IP de /etc/osmo-role, sinon 127.0.0.1
osmo_host() {
    local op="${1:-}" id
    case "$op" in
        hub|osmo-inter-stp)
            if [ "$(osmo_mode)" = docker ]; then
                printf '%s.10\n' "$OSMO_BACKBONE_NET"
            else
                local h; h="$(osmo_hub_ip 2>/dev/null || true)"
                printf '%s\n' "${h:-127.0.0.1}"
            fi
            return 0 ;;
    esac
    id="$(_osmo_id "$op")"
    if [ -n "$id" ] && { [ "$(osmo_mode)" = docker ] || [ -n "$(_osmo_ns_cmd "$op")" ]; }; then
        printf '%s.%s\n' "$OSMO_BACKBONE_NET" "$((10 + id))"
    else
        printf '127.0.0.1\n'
    fi
}

# =============================================================================
#  4. VTY
# =============================================================================

# Quel client VTY ce noeud possede-t-il ? nc de preference, telnet en repli.
# L'ISO installe netcat-openbsd ET telnet (build-iso.sh:693) mais PAS socat :
# ne pas s'appuyer sur socat comme le fait core_vty_ask de run_modules/.
# Le diagnostic est ecrit UNE FOIS par noeud, sur stderr, pour ne pas polluer la
# sortie du check ni la repeter a chaque commande.
_osmo_vty_tool() {
    local op="${1:-}" key tool
    key="$(osmo_node "$op")"
    tool="${_OSMO_VTY_TOOL[$key]:-}"
    if [ -z "$tool" ]; then
        if osmo_exec "$op" sh -c 'command -v nc' >/dev/null 2>&1; then
            tool=nc
        elif osmo_exec "$op" sh -c 'command -v telnet' >/dev/null 2>&1; then
            tool=telnet
        else
            tool=none
            printf 'checks/_mode.sh : aucun client VTY sur %s - installez netcat-openbsd ou telnet (apt-get install -y netcat-openbsd telnet)\n' \
                   "$key" >&2
        fi
        _OSMO_VTY_TOOL[$key]="$tool"
    fi
    [ "$tool" = none ] && return 1
    printf '%s\n' "$tool"
}

# osmo_vty_up <op> <port> - le VTY repond-il ?
# Remplace les cinq copies de "docker exec ... echo >/dev/tcp/127.0.0.1/PORT".
# En natif on essaie d'abord la sonde PASSIVE (ss) : elle n'ouvre ni ne referme
# de session VTY. Si elle ne voit rien (ss absent, /proc restreint), on retombe
# sur la sonde active - pas de faux negatif.
osmo_vty_up() {
    local op="${1:-}" port="${2:-}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" != docker ] && command -v ss >/dev/null 2>&1; then
        osmo_port "$op" "$port" tcp && return 0
    fi
    osmo_exec "$op" bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null
}

# osmo_vty <op> <port> <commande>... - envoie les commandes au VTY, rend la
# sortie BRUTE sur stdout (banniere et invite comprises : c'est osmo_vty_clean
# qui filtre, et les scripts n'ont pas tous le meme filtre).
#
# Rend 1 SANS RIEN ECRIRE si le VTY ne repond pas, ou si le noeud n'a ni nc ni
# telnet : c'est le contrat des vty_cmd() actuelles, que les checks utilisent
# pour distinguer "service muet" de "service sans reponse a cette commande".
# La sonde prealable est celle d'osmo_vty_up (une connexion TCP ouverte puis
# refermee, comme aujourd'hui).
#
# L'appelant fournit ses propres "enable" / "end" : la bibliotheque
# n'invente aucune commande.
#
# LES TEMPORISATIONS SONT DES PARAMETRES, par variables d'environnement, parce
# que chaque script a les siennes et que les changer changerait la QUANTITE de
# sortie capturee - donc les "grep -c" qui la comptent :
#     OSMO_VTY_OPEN  attente avant d'ecrire (0.5 ; ss7_check : 1)
#     OSMO_VTY_READ  attente de lecture     (2   ; ss7_check : 1.5)
#     OSMO_VTY_Q     nc -q<N>               (1   ; vty-debug-dump : 2)
# Le VTY Osmocom ignore ce qui arrive avant la fin de sa negociation telnet :
# ces sleep cadencent le DIALOGUE, ce ne sont pas des barrieres d'attente.
osmo_vty() {
    local op="${1:-}" port="${2:-}"
    [ $# -ge 3 ] || return 2
    shift 2
    case "$port" in ''|*[!0-9]*) return 2 ;; esac

    osmo_vty_up "$op" "$port" || return 1

    local body="" c
    for c in "$@"; do body="${body}${c}"$'\n'; done

    local tool
    tool="$(_osmo_vty_tool "$op")" || return 1

    local open="${OSMO_VTY_OPEN:-0.5}" read_s="${OSMO_VTY_READ:-2}" q="${OSMO_VTY_Q:-1}"

    # nc/telnet ferment souvent avant d'avoir tout lu : le sous-shell producteur
    # prend alors un SIGPIPE et le tube rend 141. "|| true" garde la fonction
    # utilisable sous "set -euo pipefail".
    if [ "$tool" = nc ]; then
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" nc "-q${q}" 127.0.0.1 "$port" 2>/dev/null || true
    else
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" telnet 127.0.0.1 "$port" 2>/dev/null || true
    fi
    return 0
}

# osmo_vty_clean [motif supplementaire] - filtre stdin→stdout : retire banniere,
# invite et lignes vides. Le motif de base et L'ORDRE des filtres sont ceux des
# scripts, au caractere pres : y toucher changerait leur sortie.
# global_check.sh et ss7_check.sh filtrent en plus "Free Software lives", que
# vty-debug-dump.sh garde - d'ou l'argument optionnel :
#     osmo_vty_clean 'Free Software lives'
osmo_vty_clean() {
    local extra="${1:-}"
    local re="^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete|% Error|\
Connection closed)"
    [ -n "$extra" ] && re="${re%)}|${extra})"
    grep -vE "$re" | sed 's/\r//' | grep -v '^[[:space:]]*$' || true
}

# osmo_vty_interactive <op> <port> [hote] - ouvre une session VTY INTERACTIVE
# (un humain devant le clavier), la ou osmo_vty envoie des commandes et rend la
# sortie. Substitution 1:1 de "docker exec -ti <conteneur> telnet <ip> <port>".
# L'hote reste un PARAMETRE parce que les groupes Baseband ecoutent sur
# 127.0.0.1, 127.0.0.2... (tools/vty-menu.sh:79) : c'est la seule cible VTY du
# depot qui ne soit pas 127.0.0.1.
osmo_vty_interactive() {
    local op="${1:-}" port="${2:-}" host="${3:-127.0.0.1}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" = docker ]; then
        docker exec -ti "$(osmo_node "$op")" telnet "$host" "$port"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns doit etre decoupe en mots (ip netns exec X)
    if [ -n "$ns" ]; then $ns telnet "$host" "$port"; else telnet "$host" "$port"; fi
}

# osmo_vty_target <op> - "cible" a remettre a un client VTY qui N'EST PAS du
# bash et ne peut donc pas sourcer cette bibliotheque.
#
# Le cas existe et il est unique : tools/vty-connect.exp est ecrit en expect. La
# bibliotheque ne l'atteindra jamais ; le mode doit donc etre decide cote bash
# (tools/vty-menu.sh) et lui etre passe en ARGUMENT. La convention est :
#     docker → le nom du conteneur, qui devient "docker exec -ti <nom> telnet"
#     natif  → "-", qui devient un "telnet" direct
# "-" plutot que la chaine vide : une chaine vide se perd dans un [lindex]
# expect comme dans un "$@" bash, et l'on ne distingue plus "natif" de
# "argument oublie".
osmo_vty_target() {
    if [ "$(osmo_mode)" = docker ]; then osmo_node "${1:-}"; else printf -- '-\n'; fi
}

# =============================================================================
#  5. CATEGORIE A - REFUSER PROPREMENT QUAND DOCKER MANQUE
# =============================================================================
#
#  Certains scripts ne se convertissent pas : ils PILOTENT docker par nature -
#  ils construisent une image, creent un reseau 172.20.N.0/24, lancent un
#  conteneur. En natif il n'y a ni image, ni reseau a creer, ni conteneur : le
#  noeud, c'est la machine. Les convertir reviendrait a reecrire start-direct.sh
#  et start-interstp.sh, qui existent deja - le depot a deja paye ce prix
#  ailleurs (cf. l'en-tete de start-nitb.sh : 4 copies divergentes de
#  si_bridge.py, 3 de gapk-start.sh).
#
#  Ce qui leur manque, c'est un REFUS. build-iso.sh embarque start.sh,
#  build.sh et launch/osmo-launch.sh sur une ISO ou build-iso.sh:707 garantit
#  qu'il n'y a PAS de docker : aujourd'hui ces scripts y meurent en 127 sur
#  "docker: command not found", apres avoir deja touche l'hote, sans nommer
#  l'alternative qui, elle, est installee juste a cote.

# osmo_docker_ok - docker est-il REELLEMENT utilisable depuis ici ?
# Le binaire ne suffit pas : une machine de dev l'a souvent sans demon actif, et
# "docker build" y echoue alors sur un message de socket. On interroge le
# demon. Aucun tube : pas de piege pipefail.
osmo_docker_ok() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

# osmo_require_docker [ligne d'alternative...] - refus propre, puis exit 3.
# Rend 0 (et ne dit rien) si docker est utilisable : s'appelle donc en tete de
# script sans condition.
#
# Le message suit le gabarit de launch/start-oqc.sh:41-51, le meilleur du
# depot : dire CE QUI MANQUE, POURQUOI ce script ne peut pas s'en passer, et
# SURTOUT quoi lancer a la place, par son nom exact. Sans les alternatives
# fournies en argument, on cite les deux du depot.
#
# Sortie sur stderr, code 3 : distinct de 1 (echec d'execution) et de 2 (mauvais
# argument), pour qu'un appelant puisse reconnaitre "mauvais monde" sans lire
# le texte.
osmo_require_docker() {
    osmo_docker_ok && return 0
    {
        printf '\n%s\n\n' "Docker n'est pas utilisable sur cette machine."
        if command -v docker >/dev/null 2>&1; then
            printf '%s\n' "  Le binaire docker est la, mais le demon ne repond pas."
            printf '%s\n' "  → sudo systemctl start docker, puis relancer ce script."
        else
            printf '%s\n' "  La commande docker est absente - c'est le cas normal sur l'ISO,"
            printf '%s\n' "  en VM et sur une machine nue : la pile y est installee en dur."
        fi
        printf '\n%s\n' "Ce script pilote docker (images, reseaux, conteneurs). Il n'a pas"
        printf '%s\n' "d'equivalent natif a ecrire : l'equivalent EXISTE DEJA, et il a un nom."
        printf '%s\n\n' "Lancez plutot :"
        if [ $# -gt 0 ]; then
            local _l; for _l in "$@"; do printf '  %s\n' "$_l"; done
        else
            printf '  %s\n' "./start-direct.sh     - la pile complete de CE noeud (un operateur)"
            printf '  %s\n' "./start-interstp.sh   - le hub SS7 inter-operateurs"
        fi
        printf '\n%s\n' "Sur l'ISO ces deux-la sont deja dans le PATH : osmo-start-direct."
        printf '%s\n\n' "Pour verifier l'etat sans rien demarrer : ./checks/global_check.sh"
    } >&2
    exit 3
}

# =============================================================================
#  6. DIVERS
# =============================================================================

# osmo_qgrep <args...> - "grep -q" sans le piege.
# "cmd | grep -q motif" : grep sort a la PREMIERE correspondance, le
# producteur recoit un SIGPIPE et meurt en 141 - et sous "set -o pipefail"
# c'est 141 que rend le tube. "trouve" se lit alors "pas trouve", de facon
# intermittente, selon que la sortie tenait dans le tampon du tube. Ici grep lit
# toute son entree et on jette sa sortie. Copie conforme de qgrep()
# (network/setup-wan-mesh.sh:69).
osmo_qgrep() { grep "$@" >/dev/null; }

# =============================================================================
#  Execute au lieu d'etre source : on ne fait rien de destructeur, on affiche
#  ce que la bibliotheque VOIT. Sert de test rapide, et evite qu'un futur
#  "for f in checks/*.sh; do $f; done" ne tombe dans le vide.
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'mode      : %s\n' "$(osmo_mode)"
    printf 'operateurs: %s\n' "$(osmo_ops | tr '\n' ' ')"
    if hub="$(osmo_hub)"; then
        printf 'inter-STP : %s (interrogeable ici)\n' "$hub"
    else
        printf 'inter-STP : %s\n' "$(osmo_hub_hint)"
    fi
    printf 'hote op.1 : %s\n' "$(osmo_host 1)"
    exit 0
fi
