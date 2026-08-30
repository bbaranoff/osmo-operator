#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# checks/wan_ss7_check.sh - etat du WAN, et etat du SS7 VIS-A-VIS du WAN
#
# checks/ss7_check.sh verifie le SS7 D'UN noeud (inter-STP, ASP, routes). Ce
# script-ci repond a la question qui vient juste apres : "et entre noeuds ?"
#
# CE QU'IL FAUT SAVOIR AVANT DE LIRE LA SORTIE
# --------------------------------------------
# Le WAN d'osmo_egprs ne transporte PAS de SS7. Entre deux noeuds il n'y a que :
#     • SIP/RTP  (Asterisk ↔ Asterisk)  → la voix
#     • TCP 789x (sms-interop-relay)    → les SMS
# Le SS7/M3UA (osmo-stp, point codes 1.N.2, inter-STP 0.0.0) reste INTERNE a un
# noeud : l'ASP de chaque operateur pointe sur 172.20.0.10, une adresse du plan
# docker prive, injoignable depuis l'exterieur - et le catch-all "route 0.0.0
# 0.0.0 → as-inter" envoie tout PC inconnu vers CET inter-STP local.
#
# Ce n'est donc pas une panne a reparer, c'est la frontiere du montage : un
# appel inter-noeud est une TERMINAISON SIP, pas un relais MAP/ISUP. Ce script
# le VERIFIE au lieu de le supposer - et signale les deux cas ou l'on croit a
# tort avoir du SS7 inter-noeud :
#   1. deux noeuds qui reutilisent les MEMES point codes (ils le font tous :
#      1.1.2, 1.2.2... sont recalcules a l'identique sur chaque machine) ;
#   2. un port M3UA (2905/2908) expose sur l'interface publique.
#
# Usage : sudo checks/wan_ss7_check.sh [--verbose] [--conf /etc/osmo-wan.conf]
# ══════════════════════════════════════════════════════════════════════════════
set -u

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=0
CONF="/etc/osmo-wan.conf"
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1 ;;
        --conf)       CONF="${2:-}"; shift ;;
        --conf=*)     CONF="${1#*=}" ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    shift
done

PASS=0; FAIL=0; WARN=0; SKIP=0
ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
skip() { echo -e "  ${YELLOW}-${NC} $*"; SKIP=$((SKIP+1)); }
info() { [ $VERBOSE -eq 1 ] && echo -e "    ${CYAN}│${NC} $*" || true; }
banner(){ echo ""; echo -e "${BOLD}$*${NC}"; printf '─%.0s' $(seq 1 64); echo ""; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   WAN - diagnostic voix / SMS / SS7 entre noeuds osmo_egprs      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 0. Table des noeuds ───────────────────────────────────────────────────────
banner "0. Table des noeuds WAN"
if [ ! -r "$SCRIPT_DIR/network/wan-nodes.sh" ]; then
    fail "network/wan-nodes.sh introuvable - depot incomplet"; exit 1
fi
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/network/wan-nodes.sh"

if ! wan_nodes_load "$CONF" 2>/dev/null; then
    fail "$CONF illisible - aucun WAN configure sur ce noeud"
    echo -e "     ${CYAN}sudo ./start.sh --wan${NC}  ou  ${CYAN}sudo ./start-direct.sh --wan${NC}"
    exit 1
fi
[ "${WAN_NODE_ID:-0}" = "0" ] && wan_nodes_detect_self 2>/dev/null
if wan_nodes_validate 2>/dev/null; then ok "table valide : ${WAN_NODE_COUNT} noeud(s)"
else fail "table incoherente (voir messages ci-dessus)"; fi
wan_nodes_summary

LOCAL_IND="$(wan_local_ind)"
REMOTES=(); for id in "${WAN_NODE_LIST[@]}"; do [ "$id" = "${WAN_NODE_ID:-0}" ] || REMOTES+=("$id"); done
if [ "${#REMOTES[@]}" -eq 0 ]; then
    warn "table a un seul noeud : aucun pair, rien a verifier cote WAN"
    echo -e "     ${CYAN}Ajoutez des noeuds : sudo ./start.sh --wan${NC}"
    exit 0
fi

# ── Mode ──────────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^osmo-operator-1$'; then
    MODE=docker
    N_OPS=$(docker ps --format '{{.Names}}' | grep -c '^osmo-operator-[0-9]*$')
else
    MODE=native; N_OPS=1
fi
info "mode=${MODE} operateurs locaux=${N_OPS}"

# ── Ce que porte un pair, et ou il ecoute ────────────────────────────────────
# Ces deux fonctions repliquent ce que network/setup-wan-mesh.sh a REELLEMENT
# ecrit dans les configs. Sans elles, ce controle bouclait sur le nombre
# d'operateurs LOCAUX et cherchait chez chaque pair autant de trunks que nous en
# avons : des qu'un pair en portait moins - le montage un noeud par conteneur,
# soit le banc courant - il sortait "trunk wan_n2_op2 ABSENT, relancez
# setup-wan-mesh.sh" et rendait 1. Un echec faux, avec un conseil qui n'y
# changeait rien : le trunk manquant n'a jamais eu lieu d'exister.
peer_nops() {   # $1 = id de noeud
    local n="${WAN_NOPS[$1]:-}"
    if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then echo "$n"; return; fi
    # Table sans le 4e champ (une table ecrite a la main, ou anterieure) : un
    # pair du backbone est un conteneur, donc un operateur ; ailleurs, on
    # suppose le pair monte comme nous. C'est la meme regle que node_nops dans
    # network/setup-wan-mesh.sh - il faut lire ce que le maillage a ecrit, pas
    # ce qu'on aurait souhaite qu'il ecrive.
    if peer_is_backbone "${WAN_IP[$1]:-}"; then echo 1; else echo "${N_OPS:-1}"; fi
}
# Un pair du backbone docker est joint a son adresse propre : le conteneur y
# ecoute sur 5060 et sur le port de base du relais SMS. Les 5080/5082 et 7891
# sont les ports PUBLIES sur l'hote, ils ne veulent rien dire de ce cote.
peer_is_backbone() { case "$1" in 172.20.0.*) return 0 ;; *) return 1 ;; esac; }

ast() { # $1=op  $2=commande
    if [ "$MODE" = docker ]; then docker exec "osmo-operator-$1" asterisk -rx "$2" 2>/dev/null
    else asterisk -rx "$2" 2>/dev/null; fi
}
inside() { # $1=op  $2=commande shell
    if [ "$MODE" = docker ]; then docker exec "osmo-operator-$1" bash -c "$2" 2>/dev/null
    else bash -c "$2" 2>/dev/null; fi
}

# ── 1. Joignabilite des pairs ─────────────────────────────────────────────────
banner "1. Pairs - joignabilite IP et ports WAN"
for r in "${REMOTES[@]}"; do
    rip="${WAN_IP[$r]}"
    if ping -c1 -W2 "$rip" >/dev/null 2>&1; then ok "node ${r} ${rip} repond au ping"
    else warn "node ${r} ${rip} ne repond pas au ping (ICMP filtre ? noeud eteint ?)"; fi
    for i in $(seq 1 "$(peer_nops "$r")"); do
        if peer_is_backbone "$rip"; then sip=5060; sms=7890
        else sip=$(( 5080 + (i - 1) * 2 )); sms=$(( 7890 + i - 1 )); fi
        if command -v nc >/dev/null 2>&1; then
            nc -z -w2 "$rip" "$sms" 2>/dev/null \
                && ok "node ${r} op${i} : relais SMS ${rip}:${sms} ouvert" \
                || warn "node ${r} op${i} : relais SMS ${rip}:${sms} ferme - SMS WAN KO dans ce sens"
        else skip "nc absent : test TCP ${rip}:${sms} impossible"; fi
        info "SIP attendu sur ${rip}:${sip}/udp (UDP : pas de test fiable sans trafic)"
    done
done

# ── 2. Asterisk - trunks WAN ──────────────────────────────────────────────────
banner "2. Asterisk - trunks WAN (voix)"
for i in $(seq 1 "$N_OPS"); do
    out="$(ast "$i" 'pjsip show endpoints')"
    if [ -z "$out" ]; then fail "op${i} : Asterisk ne repond pas"; continue; fi
    for r in "${REMOTES[@]}"; do
        for j in $(seq 1 "$(peer_nops "$r")"); do
            ep="wan_n${r}_op${j}"
            if echo "$out" | grep -q "$ep"; then
                state="$(ast "$i" "pjsip show aor $ep" | grep -iE 'Avail|Unavail|Contact' | head -3 | tr '\n' ' ')"
                if echo "$out" | grep -E "Endpoint:[[:space:]]+$ep" | grep -qi 'Unavailable'; then
                    warn "op${i} → ${ep} present mais Unavailable (pair injoignable)"
                else ok "op${i} → ${ep}"; fi
                info "$state"
            else
                fail "op${i} : trunk ${ep} ABSENT - relancez network/setup-wan-mesh.sh"
            fi
        done
    done
done

# ── 3. Dialplan - indicatifs ──────────────────────────────────────────────────
banner "3. Dialplan - un indicatif route par pair"
for i in $(seq 1 "$N_OPS"); do
    for r in "${REMOTES[@]}"; do
        ind="${WAN_IND[$r]}"
        if ast "$i" "dialplan show wan_out" | grep -q "_${ind}"; then
            ok "op${i} : indicatif ${ind} → node ${r} present dans [wan_out]"
        else
            fail "op${i} : indicatif ${ind} absent de [wan_out]"
        fi
    done
    ast "$i" "dialplan show gsm_in" | grep -q "_${LOCAL_IND}" \
        && ok "op${i} : indicatif local ${LOCAL_IND} traite en interne" \
        || warn "op${i} : indicatif local ${LOCAL_IND} non traite - un appel 'plein numero' echouera"
done

# ── 4. SMS - routes et strip ──────────────────────────────────────────────────
banner "4. SMS - routes WAN et retrait d'indicatif"
for i in $(seq 1 "$N_OPS"); do
    conf="$(inside "$i" 'cat /etc/osmocom/sms-routing.conf')"
    if [ -z "$conf" ]; then fail "op${i} : sms-routing.conf illisible"; continue; fi
    for r in "${REMOTES[@]}"; do
        ind="${WAN_IND[$r]}"
        line="$(echo "$conf" | grep -E "^${ind}[0-9]+ =" | head -1)"
        if [ -z "$line" ]; then
            fail "op${i} : aucune route SMS pour l'indicatif ${ind}"
        elif echo "$line" | grep -q 'strip='; then
            ok "op${i} : route SMS ${ind} avec strip - le HLR distant verra le numero nu"
        else
            fail "op${i} : route SMS ${ind} SANS strip= - le noeud distant cherchera "${ind}10001" dans son HLR et repondra "not found""
        fi
    done
    # Le relais doit savoir lire strip= : une conf correcte sur un relais qui
    # l'ignore est exactement aussi cassee qu'une conf sans strip.
    if inside "$i" 'grep -q lookup_strip /opt/GSM/osmo_egprs/scripts/sms-interop-relay.py 2>/dev/null || grep -q lookup_strip /etc/osmocom/sms-interop-relay.py 2>/dev/null || grep -rq lookup_strip /usr/local/bin 2>/dev/null'; then
        ok "op${i} : le relais SMS gere strip="
    else
        warn "op${i} : relais SMS sans lookup_strip - version anterieure, SMS WAN muets"
    fi
done

# ── 5. SS7 - ce qui traverse, ce qui ne traverse pas ──────────────────────────
banner "5. SS7 - portee reelle vis-a-vis du WAN"
echo -e "  ${CYAN}Attendu : le SS7 s'arrete au bord du noeud. On verifie que c'est bien${NC}"
echo -e "  ${CYAN}le cas, et qu'on ne croit pas avoir un lien SS7 inter-noeud.${NC}"
echo ""

# Le hub change la donne : s'il y en a un, le SS7 TRAVERSE, et ce sont les
# point codes qu'il faut verifier - pas leur absence.
HUB_IP=""
[ -r /etc/osmo-role ] && HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role)"
# En docker, /etc/osmo-role n'existe pas sur l'hote : l'adresse du hub est
# injectee dans les conteneurs par start.sh (-e OSMO_HUB_IP, cf. --hub-ip).
# Sans ce repli, un hub WAN parfaitement declare passait pour "un lien non
# maitrise" faute d'etre reconnu comme LE hub.
if [ -z "$HUB_IP" ]; then
    for _i in $(seq 1 "$N_OPS"); do
        HUB_IP="$(inside "$_i" 'printenv OSMO_HUB_IP' | tr -d '\r' | tail -1)"
        [ -n "$HUB_IP" ] && break
    done
fi

# 5a - ou pointe l'ASP local ?
for i in $(seq 1 "$N_OPS"); do
    cfg="$(inside "$i" 'cat /etc/osmocom/osmo-stp.cfg')"
    if [ -z "$cfg" ]; then skip "op${i} : osmo-stp.cfg illisible"; continue; fi
    remote="$(echo "$cfg" | awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}')"
    shut="$(echo "$cfg" | awk '/asp asp-to-inter/{f=1} f&&/shutdown/{print $0; exit}')"
    pc="$(echo "$cfg" | awk '/^ point-code/{print $2; exit}')"
    if [ -n "$HUB_IP" ] && [ "$remote" = "$HUB_IP" ]; then
        if echo "$shut" | grep -q 'no shutdown'; then
            ok "op${i} : ASP → hub inter-STP ${remote} (actif) - le SS7 traverse le WAN, PC ${pc}"
        else
            fail "op${i} : ASP → hub ${remote} mais ${BOLD}shutdown${NC} - aucun SS7 ne passera"
        fi
        # Un hub joignable ou non, ca ne se devine pas depuis la config. Mais
        # le lien est du M3UA sur SCTP : "nc -z" (TCP) rend "Connection
        # refused" sur un hub parfaitement vivant. La preuve, c'est
        # l'association SCTP ETABLIE, vue depuis le noeud lui-meme.
        assoc="$(inside "$i" "ss -an --sctp" | grep -E "ESTAB.*[[:space:]]${remote//./\\.}:2908([[:space:]]|\$)" || true)"
        if [ -n "$assoc" ]; then
            ok "op${i} : association SCTP etablie vers le hub ${remote}:2908"
        elif inside "$i" "ss -an --sctp" | grep -q .; then
            fail "op${i} : aucune association SCTP vers ${remote}:2908 - l'ASP est DOWN"
            echo -e "     ${CYAN}Sur le noeud inter-STP : ./start-interstp.sh --status${NC}"
        else
            skip "op${i} : ss --sctp indisponible - lien vers ${remote}:2908 non verifiable"
        fi
    else
        case "$remote" in
            172.2[0-9].*|127.*)
                ok "op${i} : ASP inter-STP → ${remote} (docker local) - le SS7 reste dans le noeud"
                [ "${#REMOTES[@]}" -ge 1 ] && info "pas de hub commun : voix et SMS traversent, le SS7 non" ;;
            "") skip "op${i} : pas d'ASP inter-STP declare" ;;
            *)  warn "op${i} : ASP inter-STP → ${remote} - M3UA sur un lien non maitrise ? (pas de chiffrement SCTP ici)" ;;
        esac
    fi
done

# 5b - le point code porte-t-il le numero de noeud ?
# Le plan local (1.<op>.<role>) se recalcule a l'identique partout : trois
# noeuds attaches au meme hub y presenteraient trois fois 1.1.2. Le plan WAN
# (1.<noeud><op>.<role>) leve l'ambiguite. On verifie lequel est en place.
if [ "${#REMOTES[@]}" -ge 1 ]; then
    pc_local="$(inside 1 'cat /etc/osmocom/osmo-stp.cfg' | awk '/^ point-code/{print $2; exit}')"
    expected="1.${WAN_NODE_ID}1.2"
    if [ "$pc_local" = "$expected" ]; then
        ok "point code ${pc_local} : le numero de noeud (${WAN_NODE_ID}) y est encode - pas de collision au hub"
    elif [ -n "$HUB_IP" ]; then
        fail "point code ${pc_local} attendu ${expected} : ce noeud entrerait en collision avec ses pairs sur le hub"
        echo -e "     ${CYAN}Reconstruire l'image : ./build-iso.sh --role operator --node ${WAN_NODE_ID}${NC}"
    else
        warn "point code ${pc_local} : plan local, identique sur tous les noeuds"
        echo -e "     ${CYAN}Sans effet tant qu'il n'y a pas de hub commun. Pour du SS7 inter-noeud :${NC}"
        echo -e "     ${CYAN}./build-iso.sh --role interstp   puis   --role operator --node N${NC}"
    fi
fi

# 5c - un port M3UA expose publiquement ?
LOCAL_IP="$(wan_local_ip)"
for port in 2905 2908; do
    if command -v ss >/dev/null 2>&1; then
        # M3UA tourne sur SCTP dans ce depot (osmo-stp.cfg : "listen m3ua ..."),
        # pas sur TCP : "ss -lntp" seul ne verrait RIEN et conclurait a tort
        # "aucun ecouteur". On regarde les deux transports.
        listen="$( { ss -lntp 2>/dev/null; ss -ln --sctp 2>/dev/null; } | grep ":${port} ")"
        if [ -z "$listen" ]; then
            ok "M3UA ${port} : aucun ecouteur sur l'hote"
        elif echo "$listen" | grep -qE '0\.0\.0\.0:'"${port}"'|\[::\]:'"${port}"; then
            warn "M3UA ${port} ecoute sur 0.0.0.0 - expose si le firewall ne le ferme pas"
            echo -e "     ${CYAN}iptables -A INPUT -p sctp --dport ${port} -j DROP${NC} (ou -p tcp selon le transport)"
        else
            ok "M3UA ${port} : ecoute restreinte ($(echo "$listen" | awk '{print $4}' | tr '\n' ' '))"
        fi
    else skip "ss absent : ecouteurs M3UA non verifies"; fi
done

# 5d - SS7 interne toujours sain ? (delegue au check existant)
if [ -x "$SCRIPT_DIR/checks/ss7_check.sh" ] && [ "$MODE" = docker ]; then
    echo ""
    echo -e "  ${CYAN}SS7 interne : checks/ss7_check.sh --quick${NC}"
else
    skip "SS7 interne : checks/ss7_check.sh (docker uniquement)"
fi

# ── 6. iptables ───────────────────────────────────────────────────────────────
banner "6. iptables - chaine WAN"
if iptables -t nat -L OSMO_WAN_MESH -n >/dev/null 2>&1; then
    n=$(iptables -t nat -S OSMO_WAN_MESH 2>/dev/null | grep -c '^-A')
    ok "chaine OSMO_WAN_MESH presente (${n} regle(s))"
    iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'OSMO_WAN_MESH' \
        && ok "chaine branchee sur PREROUTING" \
        || fail "chaine NON branchee sur PREROUTING - rien n'entre"
else
    if iptables -t nat -L OSMO_WAN_INTEROP -n >/dev/null 2>&1; then
        warn "chaine legacy OSMO_WAN_INTEROP active (2 serveurs, prefixe 66)"
    else
        fail "aucune chaine WAN - relancez network/setup-wan-mesh.sh sans --config-only"
    fi
fi

# ── Bilan ─────────────────────────────────────────────────────────────────────
echo ""
printf '─%.0s' $(seq 1 64); echo ""
echo -e "  ${GREEN}${PASS} ok${NC}   ${RED}${FAIL} echec${NC}   ${YELLOW}${WARN} avertissement${NC}   ${SKIP} ignore"
echo ""
[ "$FAIL" -eq 0 ] || exit 1
