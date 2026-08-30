#!/usr/bin/env bash
# =============================================================================
# network/osmo-ip-plan.sh - QUI PORTE LES ADRESSES PRIVEES DU NOEUD, ET OU
# =============================================================================
#
# CE QUI NE MARCHAIT PAS
# ----------------------
# Les adresses privees du noeud (192.168.<noeud+1>.1 et .10) etaient posees par
# systemd-networkd, dans 20-dhcp.network, sous un [Match] Name=en* eth*. Deux
# consequences, et la seconde est la vraie :
#
#   1. TOUTES les cartes qui repondent au motif recoivent les deux adresses.
#      Une machine a deux cartes se retrouve avec la meme /32 des deux cotes.
#   2. Surtout, le motif ne dit RIEN de la carte qui porte reellement le
#      reseau. Sur une VM a plusieurs interfaces, "en*" designe aussi bien le
#      NAT que le pont ; l'adresse se posait donc regulierement sur une carte
#      qui ne mene nulle part, pendant que celle qui a la route par defaut ne
#      l'avait pas. Un pair qui visait 192.168.2.10 ne trouvait personne, et
#      "ip addr" montrait pourtant l'adresse presente - sur l'autre carte.
#
# systemd-networkd ne sait pas exprimer "la carte qui a la route par defaut" :
# c'est une propriete d'EXECUTION, pas de configuration. D'ou ce script, appele
# au demarrage et a chaque changement de lien.
#
# LE REPLI, ET POURQUOI IL EXISTE
# -------------------------------
# Quand AUCUNE carte ne fournit Internet - VM sans reseau, cable debranche,
# DHCP muet - il n'y a aucun endroit sensé ou poser une adresse de segment. On
# ne la pose alors pas dans le vide : on met 127.0.0.66/32 sur la boucle
# locale. Les configurations qui nomment une adresse privee trouvent ainsi
# TOUJOURS quelque chose de local et de joignable, les demons demarrent, et le
# banc tourne en autarcie au lieu d'echouer au bind sur une adresse absente.
#
# DOCKER OU NATIF
# ---------------
# Le plan d'adressage n'est pas le meme des deux cotes, et prendre l'un pour
# l'autre donne des demons qui se lient a des adresses qui n'existent pas ici :
#   docker  le conteneur a son adresse sur le bridge avant que les demons ne
#           demarrent, et le backbone est 172.20.0.x. On ne touche a rien :
#           c'est docker qui adresse.
#   natif   l'adresse vient du DHCP, elle peut manquer au lancement, et le
#           segment prive du noeud est 192.168.<noeud+1>.x.
# La detection reprend celle de start-direct.sh, au mot pres : /.dockerenv ET
# /etc/docker-entrypoint-cmd (le couple qui identifie un conteneur DE CE DEPOT),
# puis le cgroup en repli.
#
# Usage :   osmo-ip-plan.sh [--apply|--show] [--node N]
# -----------------------------------------------------------------------------
set -uo pipefail

ACTION=apply
NODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  ACTION=apply ;;
        --show)   ACTION=show ;;
        --node)   NODE="${2:-}"; shift ;;
        --node=*) NODE="${1#*=}" ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

LOOPBACK_FALLBACK="${OSMO_PRIV_FALLBACK:-127.0.0.66}"

# ── docker ou natif ─────────────────────────────────────────────────────────
detect_runtime_env() {
    if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then echo docker; return; fi
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        echo docker; return
    fi
    echo native
}

# ── le noeud ────────────────────────────────────────────────────────────────
resolve_node() {
    local n="${NODE:-${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}}"
    [ -n "$n" ] || n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
                        /etc/osmo-role 2>/dev/null)"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' /etc/osmocom/radio-plan.env 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}

# ── LA carte qui fournit Internet ───────────────────────────────────────────
# "ip route get" repond ce que le NOYAU ferait vraiment : c'est la seule
# reponse qui ne devine pas. On essaie une adresse publique, puis la passerelle
# par defaut - un banc coupe d'Internet garde en general sa route par defaut.
uplink_dev() {
    local d
    d="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    [ -n "$d" ] || d="$(ip route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    # lo ne fournit rien : si la route par defaut y mene, c'est qu'il n'y en a pas.
    [ "$d" = "lo" ] && d=""
    printf '%s' "$d"
}

# ── CE QUE LES CONFIGS EXIGENT, PAS CE QU'ON SUPPOSE ────────────────────────
# Le plan prive (192.168.<noeud+1>.x) est une convention ; ce qui compte, c'est
# l'adresse que chaque demon va REELLEMENT essayer de lier. Elle est ecrite dans
# /etc/osmocom, et elle peut venir d'un autre generateur que le notre :
# qemu-src/run_modules/08-gabarits.sh passe op_private_ip() a
# apply_config_templates, donc 192.168.2.10, quand la recette native de l'ISO
# passe 127.0.0.2. Deux verites, et le demon suit la sienne :
#     osmo-ggsn : « gtp bind-ip 192.168.2.10 » -> bind sur une adresse absente
#     osmo-sgsn : « listen 192.168.2.10 23000 » -> idem
# On EXTRAIT donc les adresses des fichiers au lieu de les recalculer : la
# machine finit par porter ce que ses configs demandent, quel que soit celui
# qui les a ecrites.
#
# ATTENTION A CE QU ON NE PREND PAS : « ip dns 0/1 » (serveurs annonces a
# l'abonne), « remote-ip », « ggsn 0 remote-ip » designent des adresses
# DISTANTES. Les poser localement ferait repondre la machine a la place du pair.
addrs_des_configs() {
    local d="${OSMOCOM_CFG:-/etc/osmocom}"
    [ -d "$d" ] || return 0
    {
        sed -n 's/^[[:space:]]*gtp[[:space:]]\+bind-ip[[:space:]]\+\([0-9.]*\).*/\1/p'  "$d"/osmo-ggsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\([0-9.]*\).*/\1/p' "$d"/osmo-sgsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9.]*\)[[:space:]]\+[0-9]*.*/\1/p' "$d"/osmo-sgsn.cfg 2>/dev/null
        sed -n 's/^[[:space:]]*local-addr[[:space:]]\+\([0-9.]*\).*/\1/p'                 "$d"/osmo-upf.cfg  2>/dev/null
    } | sort -u | while read -r a; do
        case "$a" in
            ''|0.0.0.0|127.*) continue ;;      # deja la, ou « toutes les cartes »
        esac
        printf '%s\n' "$a"
    done
}

RUNTIME="$(detect_runtime_env)"
NODE="$(resolve_node)"
PRIV_BASE=$(( NODE + 1 ))
PRIV_GW="192.168.${PRIV_BASE}.1"
PRIV_IP="192.168.${PRIV_BASE}.10"
DEV="$(uplink_dev)"

if [ "$ACTION" = show ] || [ "${OSMO_IP_PLAN_VERBOSE:-1}" = 1 ]; then
    printf 'osmo-ip-plan : runtime=%s noeud=%s prive=%s,%s carte=%s\n' \
        "$RUNTIME" "$NODE" "$PRIV_GW" "$PRIV_IP" "${DEV:-aucune}"
fi
[ "$ACTION" = show ] && exit 0

# ── DOCKER : on ne touche a rien ────────────────────────────────────────────
if [ "$RUNTIME" = docker ]; then
    echo "osmo-ip-plan : conteneur - l'adressage appartient a docker, rien a poser"
    exit 0
fi

# ── On retire d'abord les adresses de PARTOUT ───────────────────────────────
# Sans ce nettoyage, changer de carte (cable debranche, Wi-Fi qui prend le
# relais) laissait l'ancienne adresse en place sur l'ancienne carte : deux
# interfaces revendiquaient la meme /32 et le noyau choisissait la source par
# ordre d'apparition, pas par route.
for a in "$PRIV_GW" "$PRIV_IP" "$LOOPBACK_FALLBACK"; do
    while read -r ifn; do
        [ -n "$ifn" ] || continue
        ip addr del "${a}/32" dev "$ifn" 2>/dev/null || true
    done < <(ip -o -4 addr show 2>/dev/null | awk -v a="$a" '$4 ~ "^"a"/" {print $2}')
done

# L'union du plan du noeud et de ce que les configs reclament. Les doublons
# tombent au tri ; « ip addr add » d'une adresse deja posee est sans effet.
BESOINS="$(printf '%s\n%s\n%s\n' "$PRIV_GW" "$PRIV_IP" "$(addrs_des_configs)" | sed '/^$/d' | sort -u)"

if [ -n "$DEV" ]; then
    _pose=""
    for a in $BESOINS; do
        # Deja portee par une carte quelconque : on n'y touche pas. Reposer une
        # adresse ailleurs ferait deux interfaces sur la meme /32.
        if ip -o -4 addr show 2>/dev/null | awk '{print $4}' | grep -qx "${a}/32\|${a}/[0-9]*"; then
            continue
        fi
        ip -o -4 addr show 2>/dev/null | awk -F'[ /]+' '{print $4}' | grep -qx "$a" && continue
        ip addr add "${a}/32" dev "$DEV" 2>/dev/null && _pose="$_pose $a"
    done
    if [ -n "$_pose" ]; then
        echo "osmo-ip-plan :${_pose} pose(s) en /32 sur ${DEV} (carte qui fournit Internet)"
    else
        echo "osmo-ip-plan : rien a poser, tout est deja la (${DEV})"
    fi
else
    # ── REPLI : la boucle locale ────────────────────────────────────────────
    # Aucune carte ne mene nulle part. Poser 192.168.x sur une interface au
    # hasard donnerait une adresse presente et injoignable - le pire des deux
    # mondes, parce que tout a l'air en place. Une adresse de boucle, elle, est
    # honnete : locale, joignable, et elle ne pretend rien.
    # Sur lo, une adresse absente empeche un demon de demarrer tout autant que
    # sur une carte : on y pose donc AUSSI ce que les configs reclament, plutot
    # que le seul repli. Le banc tourne alors en autarcie, complet.
    ip addr add "${LOOPBACK_FALLBACK}/32" dev lo 2>/dev/null || true
    for a in $BESOINS; do
        ip -o -4 addr show 2>/dev/null | awk -F'[ /]+' '{print $4}' | grep -qx "$a" && continue
        ip addr add "${a}/32" dev lo 2>/dev/null || true
    done
    echo "osmo-ip-plan : aucune carte ne fournit Internet - ${LOOPBACK_FALLBACK}/32 + $(echo $BESOINS) sur lo"
fi
exit 0
