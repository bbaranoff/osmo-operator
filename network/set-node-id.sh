#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/set-node-id.sh - donne a CETTE machine son identite de noeud SS7
#
# Une seule ISO pour tous les noeuds : le numero se choisit au demarrage, pas a
# la construction. Ce script reecrit ce qui, dans les configs Osmocom, designe
# le noeud - c'est-a-dire ses POINT CODES et ses routing contexts.
#
#   plan local (une machine)   1.<op>.<role>          op×100 + {10,20,30,50}
#   plan WAN   (N machines)    1.<noeud><op>.<role>    noeud×1000 + op×100 + ...
#
# Pourquoi ca ne peut pas rester le plan local : la formule se recalcule a
# l'identique sur chaque machine. Trois noeuds attaches au meme inter-STP y
# presenteraient trois fois 1.11.2. Un point code est une ADRESSE - deux
# equipements qui partagent la leur, ce n'est pas un doublon de nom, c'est du
# routage faux, et le hub n'a aucun moyen de s'en apercevoir.
#
# Trois fichiers portent cette identite, et ils doivent rester d'accord :
#   osmo-stp.cfg   son propre PC, son routing-key, son ASP vers le hub
#   osmo-msc.cfg   son PC, son routing-key, et le PC du BSC qu'il appelle
#   osmo-bsc.cfg   son PC, son routing-key, et le PC du MSC qu'il appelle
# En rater un donne un coeur qui demarre et des appels qui n'aboutissent pas.
#
# Idempotent : il lit l'etat courant et le remplace. Passer --node 2 apres
# --node 1 fonctionne, il n'y a pas d'etat a nettoyer entre les deux.
#
# Usage :
#   sudo network/set-node-id.sh --node 3 [--op 1] [--hub-ip 192.168.1.49]
#   sudo network/set-node-id.sh --show          etat actuel, sans rien modifier
#   sudo network/set-node-id.sh --node 3 --local   plan local (annule le plan WAN)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# wan_detect_local_ip vit ici : c'est la meme regle de choix d'adresse que celle
# qu'appliquent start.sh et start-direct.sh. La dupliquer, c'est se garantir
# qu'un jour les deux ne designeront plus la meme carte.
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/wan-nodes.sh"

NODE=""
OP=1
HUB_IP=""
MODE=""            # docker | native - l'adressage n'est pas le meme
LOCAL_IP=""        # adresse source de l'ASP ; "auto" = detectee
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
SHOW=0
LOCAL_PLAN=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --node)     NODE="${2:-}"; shift ;;
        --node=*)   NODE="${1#*=}" ;;
        --op)       OP="${2:-1}"; shift ;;
        --op=*)     OP="${1#*=}" ;;
        --local-ip)   LOCAL_IP="${2:-}"; shift ;;
        --local-ip=*) LOCAL_IP="${1#*=}" ;;
        --hub-ip)   HUB_IP="${2:-}"; shift ;;
        --hub-ip=*) HUB_IP="${1#*=}" ;;
        --conf-dir)   CONF_DIR="${2:-}"; shift ;;
        --conf-dir=*) CONF_DIR="${1#*=}" ;;
        --mode)     MODE="${2:-}"; shift ;;
        --mode=*)   MODE="${1#*=}" ;;
        --docker)   MODE="docker" ;;
        --native)   MODE="native" ;;
        --show)     SHOW=1 ;;
        --local)    LOCAL_PLAN=1 ;;
        --dry-run)  DRY=1 ;;
        -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

STP="$CONF_DIR/osmo-stp.cfg"
MSC="$CONF_DIR/osmo-msc.cfg"
BSC="$CONF_DIR/osmo-bsc.cfg"

# ── Lecture de l'identite en place ──────────────────────────────────────────
# Le premier point-code d'un fichier est CELUI DU DEMON ; ceux qui suivent, a
# l'interieur d'un bloc "sccp-address", designent ses pairs. C'est cette
# distinction qui structure toute la reecriture.
own_pc() { awk '/^cs7 instance/{c=1} c && /^ *point-code /{print $2; exit}' "$1" 2>/dev/null; }

show_state() {
    local f n
    printf '  %-16s %-10s %-12s %-16s %s\n' FICHIER "POINT CODE" "ROUTING-KEY" "ASP INTER-STP" "SOURCE"
    for f in "$STP" "$MSC" "$BSC"; do
        [ -r "$f" ] || { printf '  %-16s %s\n' "$(basename "$f")" "absent"; continue; }
        local pc rk asp
        pc="$(own_pc "$f")"
        rk="$(awk '/^ *routing-key /{print $2; exit}' "$f")"
        asp="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$f")"
        local src
        src="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$f")"
        printf '  %-16s %-10s %-12s %-16s %s\n' "$(basename "$f")" "${pc:--}" "${rk:--}" "${asp:--}" "${src:--}"
    done
}

if [ "$SHOW" = "1" ]; then
    [ -n "$MODE" ] || { [ -f /.dockerenv ] && MODE=docker || MODE=native; }
    echo -e "${BOLD}Identite SS7 de cette machine${NC}  (mode ${CYAN}${MODE}${NC})"
    show_state
    exit 0
fi

[[ "$NODE" =~ ^[1-9]$ ]] || { echo -e "${RED}--node : un chiffre de 1 a 9${NC}" >&2; exit 2; }
[[ "$OP"   =~ ^[1-9]$ ]] || { echo -e "${RED}--op : un chiffre de 1 a 9${NC}" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis (ecriture dans ${CONF_DIR}).${NC}" >&2; exit 1; }

for f in "$STP" "$MSC" "$BSC"; do
    [ -w "$f" ] || { echo -e "${RED}$f introuvable ou non modifiable${NC}" >&2; exit 1; }
done

# ── Le nouveau plan ─────────────────────────────────────────────────────────
if [ "$LOCAL_PLAN" = "1" ]; then
    MID="$OP"                       # 1.<op>.<role> - plan d'une machine isolee
    RBASE=$(( OP * 100 ))
else
    MID="${NODE}${OP}"              # 1.<noeud><op>.<role> - plan WAN
    RBASE=$(( NODE * 1000 + OP * 100 ))
fi
PC_MSC="1.${MID}.1"; PC_STP="1.${MID}.2"; PC_BSC="1.${MID}.3"
RCTX_MSC=$(( RBASE + 10 )); RCTX_STP=$(( RBASE + 20 ))
RCTX_BSC=$(( RBASE + 30 )); RCTX_INTER=$(( RBASE + 50 ))

# ── DOCKER OU VM : deux plans d'adressage, et le defaut de l'un est faux dans
# l'autre ──────────────────────────────────────────────────────────────────
#   docker : le hub est le conteneur osmo-inter-stp, 172.20.0.10, sur le reseau
#            gsm-inter. Le noeud y a deja son IP quand osmo-stp demarre.
#   VM/ISO : le hub est une machine a part, sur le LAN en acces par pont.
#            L'adresse du noeud vient du DHCP et n'est pas forcement montee au
#            lancement.
# Se tromper de defaut donne un ASP qui ne s'attache jamais, et le journal ne
# dit que "connection refused" - sans indiquer que l'adresse visee n'existe
# nulle part sur ce reseau-la.
#
# Le host-only VirtualBox (192.168.56.1) a longtemps servi de repli ici. Il est
# FAUX des que les VM sont en acces par pont : l'adresse n'existe sur aucun
# segment, et l'ASP la vise sans jamais rien atteindre. On DEMANDE donc
# l'adresse au lieu de la deviner, avec le hub du banc comme defaut. Une
# reponse VIDE est acceptee quand on ne la connait pas encore : dans ce cas le
# remote-ip deja present dans le fichier n'est pas touche - mieux vaut ne rien
# ecrire qu'ecrire une adresse fausse.
if [ -z "$MODE" ]; then
    if [ -f /.dockerenv ]; then MODE="docker"; else MODE="native"; fi
fi

: "${HUB_IP_DEFAULT:=192.168.1.49}"   # le hub du banc, en acces par pont

if [ -z "$HUB_IP" ]; then
    if [ -r /etc/osmo-role ]; then
        HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role)"
    fi
fi
if [ -z "$HUB_IP" ]; then
    case "$MODE" in
        docker) HUB_IP="${INTER_STP_IP:-172.20.0.10}" ;;
        *)
            # Interactif : on demande. Sinon (ISO, service, CI) on prend le
            # defaut du banc - un script non interactif ne peut pas repondre,
            # et rester bloque sur une lecture ne ferait qu'echouer plus tard.
            if [ -t 0 ] && [ "$DRY" != "1" ] && command -v _wan_ask >/dev/null 2>&1; then
                HUB_IP="$(_wan_ask "Inter-STP" \
                    "IP de l'inter-STP (vide si inconnue) :" "$HUB_IP_DEFAULT")" || exit 1
            else
                HUB_IP="$HUB_IP_DEFAULT"
            fi ;;
    esac
fi

# Vide assume : on ne reecrira pas le remote-ip. Le reste (point codes,
# routing-keys, local-ip) garde tout son sens et s'applique quand meme.
SET_HUB_IP=1
if [ -z "$HUB_IP" ]; then
    SET_HUB_IP=0
    echo -e "  ${YELLOW}Inter-STP inconnu : remote-ip laisse tel quel dans les fichiers.${NC}"
    echo -e "  ${YELLOW}Renseignez-le plus tard : --hub-ip ADRESSE, ou set_stp_ip.sh${NC}"
fi

# ── Adresse SOURCE de l'ASP vers le hub ─────────────────────────────────────
# En docker on n'y touche pas : le conteneur a son adresse avant que le demon ne
# demarre, et une source explicite evite que SCTP annonce plusieurs adresses
# (multi-homing) a un pair qui n'en attend qu'une.
#
# En VM, on INJECTE l'adresse reellement detectee sur le segment VirtualBox
# plutot que 0.0.0.0. La difference n'est pas cosmetique : avec 0.0.0.0, SCTP
# annonce TOUTES les adresses locales dans son INIT - y compris le NAT 10.0.2.15
# et les alias 172.20.x que l'ISO pose. Le hub tente alors de joindre des
# adresses qui, vues de lui, ne menent nulle part. Une adresse unique et juste
# vaut mieux qu'un multi-homing dont trois branches sur quatre sont mortes.
#
# On retombe sur 0.0.0.0 si aucune adresse n'est detectable - s'y lier vaut
# mieux que de se lier a une adresse absente, qui empeche osmo-stp de demarrer.
SET_LOCAL_IP=0
ASP_LOCAL_IP=""
if [ "$MODE" != "docker" ]; then
    SET_LOCAL_IP=1
    case "$LOCAL_IP" in
        "" | auto)
            # ── L'adresse qui ROUTE vers le hub, avant toute heuristique ────
            # Le noyau sait exactement quelle source il utilisera pour joindre
            # le hub : c'est ce que "ip route get" repond. Toute autre methode
            # devine - et devine mal des que la machine porte plusieurs
            # adresses privees. Une VM du banc en a trois (192.168.1.2 le pont,
            # 192.168.2.1 et .2.10 le plan prive de l'ISO) : l'heuristique
            # choisissait 192.168.2.1, une adresse que le hub ne peut pas
            # joindre en retour. L'ASP partait alors dans le vide et le journal
            # ne disait que "connect failed (-110)" - un timeout, sans indice
            # sur la source fautive.
            if [ -n "$HUB_IP" ]; then
                ASP_LOCAL_IP="$(ip route get "$HUB_IP" 2>/dev/null \
                                | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
                [ -n "$ASP_LOCAL_IP" ] && LOCAL_IP_SRC="route vers le hub"
            fi
            if [ -n "$ASP_LOCAL_IP" ]; then
                :
            elif ! command -v wan_detect_local_ip >/dev/null 2>&1; then
                echo -e "${RED}wan_detect_local_ip introuvable - network/wan-nodes.sh non charge${NC}" >&2
                exit 1
            else
                ASP_LOCAL_IP="$(wan_detect_local_ip || true)"
            fi
            if [ -n "$ASP_LOCAL_IP" ]; then
                [ -n "${LOCAL_IP_SRC:-}" ] || LOCAL_IP_SRC="detectee sur le segment"
            else
                ASP_LOCAL_IP="0.0.0.0"
                LOCAL_IP_SRC="aucune adresse detectee - repli"
            fi ;;
        *)  ASP_LOCAL_IP="$LOCAL_IP"; LOCAL_IP_SRC="imposee par --local-ip" ;;
    esac
fi

echo -e "${BOLD}Noeud ${NODE} - operateur ${OP}${NC}   (mode ${CYAN}${MODE}${NC})"
echo -e "  STP ${CYAN}${PC_STP}${NC}   MSC ${CYAN}${PC_MSC}${NC}   BSC ${CYAN}${PC_BSC}${NC}"
echo -e "  routing-key : stp ${RCTX_STP} · msc ${RCTX_MSC} · bsc ${RCTX_BSC} · inter ${RCTX_INTER}"
[ "$LOCAL_PLAN" = "1" ] \
    && echo -e "  ${YELLOW}plan LOCAL : cette machine ne peut pas partager un hub avec une autre${NC}" \
    || echo -e "  ASP inter-STP → ${CYAN}${HUB_IP}${NC}$([ "$SET_LOCAL_IP" = "1" ] && echo "  depuis ${CYAN}${ASP_LOCAL_IP}${NC} (${LOCAL_IP_SRC})" || echo "  (source inchangee)")"
echo ""

# ── Reecriture ──────────────────────────────────────────────────────────────
# `own` = le point code du demon (au niveau cs7 instance).
# `peer` = celui qu'il declare dans ses blocs sccp-address.
# La distinction se fait sur le bloc courant, pas sur le numero de ligne : un
# fichier qui gagne une directive ne decale pas la reecriture.
rewrite() {  # $1=fichier  $2=own  $3=peer  $4=rctx  $5=1 si bloc asp inter-STP
    local f="$1" own="$2" peer="$3" rctx="$4" do_asp="$5"
    local tmp; tmp="$(mktemp)"
    awk -v own="$own" -v peer="$peer" -v rctx="$rctx" -v do_asp="$do_asp" -v hub="$HUB_IP" \
        -v set_hub="$SET_HUB_IP" \
        -v set_local="$SET_LOCAL_IP" -v localip="${ASP_LOCAL_IP:-0.0.0.0}" '
        /^cs7 instance/            { in_cs7=1 }
        /^ *sccp-address /         { sccp=1 }
        /^ *(as|asp|listen|route-table|network-indicator|xua) / { sccp=0 }
        /^!/                       { sccp=0 }
        /^ *asp asp-to-inter/      { in_asp=1; print; next }
        in_asp && /^ *(as|listen|route-table|!)/ { in_asp=0 }

        in_asp && do_asp && set_hub && /^ *remote-ip /   { sub(/remote-ip .*/, "remote-ip " hub); print; next }
        # local-ip de l ASP : l adresse SOURCE de la SCTP vers le hub. Elle vaut
        # 127.0.0.1 dans l image (tout etait local) ; la laisser ainsi ferait
        # partir la connexion de la boucle locale vers une adresse de segment -
        # elle n aboutirait jamais, et le seul symptome serait un ASP DOWN.
        # 0.0.0.0 : le noyau choisit la source selon la route.
        in_asp && do_asp && set_local && /^ *local-ip / { sub(/local-ip.*/, "local-ip " localip); print; next }
        in_asp && do_asp && /^ *shutdown[ \t]*$/ { sub(/shutdown/, "no shutdown"); print; next }

        /^ *point-code / {
            if (sccp && peer != "") { sub(/point-code .*/, "point-code " peer) }
            else if (in_cs7)        { sub(/point-code .*/, "point-code " own) }
            print; next
        }
        /^ *routing-key / { sub(/routing-key .*/, "routing-key " rctx " " own); print; next }
        { print }
    ' "$f" > "$tmp"

    if [ "$DRY" = "1" ]; then
        echo "  [dry-run] $f"; diff -u "$f" "$tmp" | sed -n '4,30p' | sed 's/^/    /'; rm -f "$tmp"
    else
        # cat plutot que mv : sur l'ISO comme dans un conteneur, ces fichiers
        # peuvent etre des points de montage, et rename() y echoue.
        cat "$tmp" > "$f"; rm -f "$tmp"
        echo -e "  ${GREEN}✓${NC} $(basename "$f")"
    fi
}

rewrite "$STP" "$PC_STP" ""        "$RCTX_INTER" "$([ "$LOCAL_PLAN" = "1" ] && echo 0 || echo 1)"
rewrite "$MSC" "$PC_MSC" "$PC_BSC" "$RCTX_MSC"   0
rewrite "$BSC" "$PC_BSC" "$PC_MSC" "$RCTX_BSC"   0

if [ "$DRY" != "1" ]; then
    echo ""
    show_state
    echo ""
    echo -e "  ${YELLOW}Les demons deja lances gardent l'ancienne identite :${NC} relancez la pile."
fi
