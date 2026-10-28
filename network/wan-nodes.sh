#!/bin/bash
# =============================================================================
# network/wan-nodes.sh - the WAN NODE TABLE, shared by the 3 launchers
# =============================================================================
#
# This file only defines functions and variables: it is SOURCED by
#   start-docker.sh          (docker host, N operators per node)
#   start-native.sh   (native / ISO, 1 operator per node)
#   build-iso.sh      (freezes the table into the ISO)
#   network/setup-wan-mesh.sh  (applies it to Asterisk / iptables / SMS)
#
# ── MODEL ────────────────────────────────────────────────────────────────────
# A WAN = N nodes. A node = (id, public ip, dialing code).
#
# The DIALING CODE is the node's telephone prefix, exactly like a country
# code: from any node, dialing
#       <target_code><number>
# reaches <number> on the node that carries that code. The sending node strips
# the code before going out on the WAN; the receiving node thus gets the bare
# number, the one its HLR and its dialplan already know.
#
# WAN_NODE_ID says WHICH node is the local one. It is the only thing that tells
# "this number is mine" from "this number leaves on the WAN": without it, a
# node would bounce its own calls back to itself forever.
#
# ── WHY A TABLE AND NOT A local/remote PAIR ──────────────────────────────────
# network/setup-wan-interop.sh only knows TWO servers: LOCAL_IP and REMOTE_IP.
# On every call it rewrites the "WAN INTEROP" block of pjsip.conf/
# extensions.conf and resets its iptables chain, so looping it over three
# peers leaves only the LAST one. Hence this table: ONE block containing all
# the peers is generated in a single pass.
# -----------------------------------------------------------------------------

# Table: WAN_IP[id] / WAN_IND[id] / WAN_NOPS[id], plus the ordered list of ids.
declare -A WAN_IP  2>/dev/null || true
declare -A WAN_IND 2>/dev/null || true
# WAN_NOPS[id]: how many operators node id carries. WAN_OPS only describes the
# LOCAL node, so the mesh generator would otherwise have to ASSUME the others
# are identical to itself. The docker host carries two, a VM only one: from the
# host, a trunk, a _<code>2XXXX pattern and an SMS route that nobody serves
# would be built toward the VM - letting calls leave that arrive nowhere.
# Hence this per-node count, fourth field of the table.
declare -A WAN_NOPS 2>/dev/null || true
WAN_NODE_LIST=()
: "${WAN_NODE_COUNT:=0}"
: "${WAN_NODE_ID:=0}"
: "${WAN_OPS:=1}"          # operators (PLMN) carried by THIS node
: "${WAN_CONF_FILE:=/etc/osmo-wan.conf}"
# WAN_DOCKER_HOST: the LAN address of the host carrying docker, the one through
# which a VM routes to the container backbone. It is DHCP-assigned and can
# change: it is DISCOVERED at run time (network/set_ip_vm.sh) and is never
# frozen here - the table only carries it from one machine to another.
: "${WAN_DOCKER_HOST:=}"

_wanc() { [ -t 1 ] && printf '\033[0;36m%s\033[0m' "$1" || printf '%s' "$1"; }
_wan_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
_wan_err()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; }

# ── Default dialing codes ────────────────────────────────────────────────────
# 11/22/.../99: one doublet per node, none is a prefix of another (hard
# condition, cf. wan_nodes_validate) and there are exactly nine - the node
# bound. The doublet also reads as the node number, which makes a call log
# readable without the table at hand.
_WAN_DEFAULT_IND=(11 22 33 44 55 66 77 88 99)
wan_default_ind() {
    local i=$1
    if [ "$i" -ge 1 ] && [ "$i" -le "${#_WAN_DEFAULT_IND[@]}" ]; then
        echo "${_WAN_DEFAULT_IND[$((i-1))]}"
    else
        echo $(( 100 + i ))
    fi
}

# ── Serialisation "id:ip:code[:operators] ..." ───────────────────────────────
# The operator count must go through here, otherwise it does not survive the
# first round trip: wan_nodes_save serialises with this function, and a table
# read back would announce 1 operator everywhere. It is only written when it
# says something other than 1, so that everything already reading WAN_NODES
# with three fields (build-iso.sh, set_stp_ip.sh, the diagnostics) keeps
# seeing the table it knows.
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
        # Optional fourth field. Three-field tables (the ISO's, the one already
        # in /etc/osmo-wan.conf) must keep parsing: a node without a count
        # carries one operator, which is the case of a VM.
        nops=1
        case "$entry" in
            *:*:*:*) nops="${rest#*:}"; nops="${nops#*:}"; nops="${nops%%:*}" ;;
        esac
        [ -n "$nops" ] || nops=1
        # A field that is present but unreadable is not silently folded to 1:
        # that would be a mesh deprived of operators 2..n without a word in
        # the log.
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
# Rejects what would produce silently wrong routing, not only what is
# malformed.
wan_nodes_validate() {
    local id other rc=0
    [ "${#WAN_NODE_LIST[@]}" -ge 1 ] || { _wan_err "table de noeuds vide"; return 1; }
    for id in "${WAN_NODE_LIST[@]}"; do
        # 1..9: one digit. This keeps <code><operator><MSISDN> readable and
        # the Asterisk patterns free of length ambiguity.
        [[ "$id" =~ ^[1-9]$ ]] \
            || { _wan_err "numero de noeud invalide : '$id' (1 a 9)"; rc=1; }
        [[ "${WAN_IP[$id]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { _wan_err "noeud $id : '${WAN_IP[$id]}' n'est pas une IPv4"; rc=1; }
        # ── THE CODE MUST NOT OVERLAP THE LOCAL NUMBERING PLAN ──
        # The repo's MSISDNs are <node>00<op><ms> (100101, 200101...): six
        # digits whose first two are "<node>0". A code "10" would thus produce
        # "exten => _10." in [gsm_in], which would swallow 100101 - the local
        # subscriber would become unreachable and the call would leave on the
        # WAN. A ONE-digit code has the same flaw, worse.
        # The defaults 11/22/.../99 all pass this rule; the "^[1-9]0" rule
        # below is what rejects 10, 20, ... 90.
        if ! [[ "${WAN_IND[$id]}" =~ ^[0-9]{2,4}$ ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' - 2 a 4 chiffres (1 chiffre entrerait en conflit avec les MSISDN locaux)"; rc=1
        elif [[ "${WAN_IND[$id]}" =~ ^[1-9]0 ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' commence comme un MSISDN local (<noeud>00<op><ms> → 100101, 200101...) - il capterait les appels locaux ; prenez ${WAN_IND[$id]:0:1}${WAN_IND[$id]:0:1} par exemple"; rc=1
        fi
    done
    # Codes: unique AND none a prefix of another. A code 3 that prefixes a
    # code 33 makes the Asterisk patterns (_3. vs _33.) and the SMS relay's
    # longest-prefix match order-dependent - hence unpredictable.
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

# ── Local node detection by its addresses ────────────────────────────────────
# A SINGLE ISO can then serve the N machines: each recognises itself by its
# IP. Without this, one image per node would be needed.
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

# ── THIS NODE'S ADDRESS ON THE WAN SEGMENT ───────────────────────────────────
# "The first global IP" is a poor criterion on a bench VM: there are at least
# three, and two are traps.
#   • the VirtualBox NAT - always 10.0.2.x - reaches the Internet but sees no
#     peer: an ASP bound on it never reaches the hub;
#   • the aliases 172.20.0.1 / 172.20.0.11 / 172.20.1.10 that the ISO itself
#     puts on the NIC (build-iso.sh, 20-dhcp.network) - they belong to the
#     docker plan and exist on no segment.
# The right address is the VirtualBox "bridged" adapter's. It is searched in
# this order, from the surest to the most inferred.
wan_detect_local_ip() {
    local addrs a

    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    [ -n "$addrs" ] || return 1

    # 1. The table is authoritative - provided the address is really up.
    #    A table announcing an absent address is a stale table, not a source
    #    of authority.
    if [ "${WAN_NODE_ID:-0}" != "0" ] && [ -n "${WAN_IP[${WAN_NODE_ID}]:-}" ]; then
        for a in $addrs; do
            [ "$a" = "${WAN_IP[$WAN_NODE_ID]}" ] && { printf '%s' "$a"; return 0; }
        done
    fi

    # 2. The VirtualBox host-only range (192.168.56.0/21), the only one it
    #    allows without /etc/vbox/networks.conf. This is the bench segment.
    for a in $addrs; do
        case "$a" in
            192.168.5[6-9].*|192.168.6[0-3].*) printf '%s' "$a"; return 0 ;;
        esac
    done

    # 3. Any other 192.168.x address: this is the "bridged" adapter, the one
    #    that puts the VM on the same network as the host. This is the
    #    address through which the peers reach it.
    for a in $addrs; do
        case "$a" in 192.168.*) printf '%s' "$a"; return 0 ;; esac
    done

    # 4. Failing that, the first address that is neither the VirtualBox NAT,
    #    nor a docker-plan alias, nor the loopback.
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

# ── Update of THIS node in the table, without prompting ─────────────────────
# --node N says which node this machine is. Its address in the table may be
# stale (a table copied from another machine): it is replaced by the real
# LOCAL address - the one that routes to the hub if known, otherwise
# wan_detect_local_ip - then /etc/osmo-wan.conf is rewritten. The other nodes
# keep their entry: this script does not know where they are.
#   $1 = node number (1-9)   $2 = hub (optional)
wan_self_refresh() {
    local id="$1" hub="${2:-}" ip="" ind

    [[ "$id" =~ ^[1-9]$ ]] || { _wan_err "wan_self_refresh : noeud '$id' invalide"; return 1; }
    WAN_NODE_ID="$id"

    if [ -n "$hub" ]; then
        ip="$(ip route get "$hub" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
    fi
    [ -n "$ip" ] || ip="$(wan_detect_local_ip 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        _wan_err "noeud $id : aucune adresse locale detectee - table non reecrite"
        return 1
    fi

    ind="${WAN_IND[$id]:-$(wan_default_ind "$id")}"
    WAN_IP[$id]="$ip"
    WAN_IND[$id]="$ind"
    WAN_NOPS[$id]="${WAN_NOPS[$id]:-1}"
    case " ${WAN_NODE_LIST[*]:-} " in
        *" $id "*) ;;
        *) WAN_NODE_LIST+=("$id") ;;
    esac
    WAN_NODE_COUNT="${#WAN_NODE_LIST[@]}"

    wan_nodes_save "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || return 1
    printf '  \033[0;36mWAN\033[0m        noeud %s = %s (table reecrite : %s)\n' \
        "$id" "$ip" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    return 0
}

# ── Input ────────────────────────────────────────────────────────────────────
# whiptail when available AND a terminal is present; otherwise `read`. The
# "neither" mode (cron, CI, docker exec -d) invents nothing: it fails, naming
# the variables to set.
_wan_ask() {   # title  question  default
    local title="$1" q="$2" def="${3:-}" ans
    if [ -t 0 ] && [ -t 2 ] && command -v whiptail >/dev/null 2>&1 && [ -z "${WAN_NO_WHIPTAIL:-}" ]; then
        ans=$(whiptail --backtitle "osmo-operator - WAN" --title "$title" \
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

# wan_nodes_prompt [local_ops_count]
#   1. how many nodes
#   2. for EACH node: its public IP, then its dialing code
#   3. which number the node built by this run carries
wan_nodes_prompt() {
    local n i ip ind me auto_ip def_n
    def_n="${WAN_NODE_COUNT:-0}"; [ "$def_n" -lt 1 ] && def_n=3

    n=$(_wan_ask "WAN - noeuds" "Nombre de noeuds du WAN (1-9) :" "$def_n") || return 1
    [[ "$n" =~ ^[1-9]$ ]] \
        || { _wan_err "nombre de noeuds invalide : '$n' (1 a 9)"; return 1; }

    auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # ${x[@]+"${x[@]}"}: under `set -u`, an EMPTY array expanded without this
    # guard is a fatal error on bash < 4.4 - and the first input starts
    # precisely from an empty table.
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

    # LOCAL node number. The one whose IP is ours is proposed.
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
    # The docker host is only known to whoever just discovered it. Since this
    # file is rewritten WHOLE on every save, a save made by a script without it
    # in its environment would erase the address - the VM's only hint of how
    # to reach the backbone. The one already in the file is therefore read
    # back before writing.
    if [ -z "$host" ] && [ -r "$f" ]; then
        host="$(sed -n 's/^WAN_DOCKER_HOST=//p' "$f" | tr -d "\"' " | tail -1)"
    fi
    # WAN_AUTO_SAVE, when set, takes precedence over WAN_AUTO: reading the table
    # back (wan_nodes_load sources it) puts WAN_AUTO=1 into the shell, and every
    # later save would rewrite it. start-native.sh sets it: 1 only if WAN_AUTO=1
    # itself brought the WAN up (node of an ISO built with --wan), 0 for a
    # --wan typed by hand.
    cat > "$f" <<EOF
# /etc/osmo-wan.conf - WAN node table (generated by network/wan-nodes.sh)
# Format: WAN_NODES="id:ip:code[:operators] ..."  (operators: default 1)
WAN_NODES="$(wan_nodes_spec)"
WAN_NODE_COUNT=${WAN_NODE_COUNT}
WAN_NODE_ID=${WAN_NODE_ID}
WAN_OPS=${WAN_OPS}
# WAN_AUTO=1: the launchers apply the WAN without passing --wan again.
WAN_AUTO=${WAN_AUTO_SAVE:-${WAN_AUTO:-0}}
EOF
    # Written only when known: an empty line would be read as a gateway, and
    # an empty gateway cannot be told from a wrong one when the route is set.
    if [ -n "$host" ]; then
        {
            printf '# Host carrying docker, through which a VM routes to the container\n'
            printf '# backbone. DHCP address: it is rediscovered, never frozen.\n'
            printf 'WAN_DOCKER_HOST="%s"\n' "$host"
        } >> "$f"
    fi
    return 0
}

wan_nodes_load() {
    local f="${1:-$WAN_CONF_FILE}"
    [ -r "$f" ] || return 1
    # Sourcing brings back WAN_NODES, the local node, and WAN_DOCKER_HOST when
    # the file carries it - it is how a VM knows where to route 172.20.
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
