#!/bin/bash
# ss7_check.sh - Verification SS7 pour architecture Inter-STP central
#
# Architecture cible :
#   - Inter-STP (0.23.0) central
#   - Chaque operateur a STP local (N.23.2) avec route par defaut vers inter-STP
#   - Routes dynamiques apprises via M3UA
#
# Ce qui est verifie :
#   1. Inter-STP : AS actifs pour chaque operateur
#   2. Inter-STP : ASP connectes
#   3. Inter-STP : pas de PROHIB
#   4. Chaque operateur : ASP actif vers inter-STP
#   5. Chaque operateur : routes locales (MSC/BSC) actives
#   6. Chaque operateur : route par defaut (0.0.0/0) vers inter-STP
#   7. Matrice de connectivite basique
#
# DOUBLE MODE - docker ET natif (ISO, VM, machine nue)
# ----------------------------------------------------
# Toute la mecanique de detection et d'acces aux noeuds vit dans checks/_mode.sh ;
# ici on ne fait qu'appeler ses fonctions. Les deux mondes :
#
#   docker : un conteneur osmo-operator-N par operateur, hub = conteneur
#            osmo-inter-stp ; on atteint tout par "docker exec".
#   natif  : un seul operateur (sauf topologie netns), les VTY sont sur
#            127.0.0.1 de CETTE machine. Le hub, lui, est SOIT cette machine
#            (OSMO_ROLE=interstp dans /etc/osmo-role), SOIT une AUTRE machine du
#            WAN - et dans ce second cas son VTY n'est PAS observable d'ici : le
#            VTY Osmocom n'ecoute que sur la boucle locale. On l'annonce alors
#            "ignore", on ne fabrique pas un "0 AS actif" qui se lirait comme
#            une panne alors que le hub tourne tres bien ailleurs.
#
# Les PORTS VTY sont les memes dans les deux mondes (4239 STP, 4254 MSC,
# 4242 BSC, 4258 HLR) : seul l'hote change, et c'est _mode.sh qui s'en occupe.
#
# Usage :
#   sudo ./ss7_check.sh [--verbose] [--quick] [--docker|--native]

set -u

# ── Bibliotheque commune (detection docker/natif, VTY, inventaire) ────────────
# Chemin RELATIF au script : le depot tourne aussi bien depuis un clone que
# depuis /opt/GSM/osmo_egprs sur l'ISO, et checks/ est copie en entier par
# build-iso.sh - la bibliotheque est donc toujours a cote de ce fichier.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo_egprs/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
VERBOSE=0
QUICK=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quick|-q)   QUICK=1 ;;
        # --docker / --native / --mode=X : forcer le monde au lieu de le
        # detecter. osmo_mode_force rend 2 si l'argument n'est pas un mode, ce
        # qui ne peut pas arriver ici puisque le motif du case l'a deja filtre.
        --docker|--native|--mode=*)
            osmo_mode_force "$arg" || { echo "mode inconnu : $arg" >&2; exit 1; } ;;
        -h|--help)
            echo "Usage : $0 [--verbose|-v] [--quick|-q] [--docker|--native]"
            echo "  --docker / --native : force le mode ; sans option, detection automatique."
            exit 0 ;;
    esac
done

INTER_STP="osmo-inter-stp"
PASS=0
FAIL=0
WARN=0
SKIP=0

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
skip() { echo -e "  ${YELLOW}-${NC} $*"; SKIP=$((SKIP+1)); }
info() { [[ $VERBOSE -eq 1 ]] && echo -e "    ${CYAN}│${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}$*${NC}"
    echo -e "$(printf '─%.0s' {1..60})"
}

# ── Fonction VTY ──────────────────────────────────────────────────────────────
# Meme contrat qu'avant : rend 1 sans rien ecrire si le VTY ne repond pas,
# sinon la sortie nettoyee. Le dialogue lui-meme (nc/telnet, docker exec ou
# local, netns) est dans osmo_vty ; on garde ICI les temporisations de ce
# script - les changer changerait la QUANTITE de sortie capturee, donc les
# "grep -c" qui la comptent juste en dessous.
: "${OSMO_VTY_OPEN:=1}"    # sleep avant d'ecrire   (valeur historique de ss7_check)
: "${OSMO_VTY_READ:=1.5}"  # sleep de lecture       (idem)
: "${OSMO_VTY_Q:=1}"       # nc -q1                 (idem)

vty_cmd() {
    local node="$1"
    local port="$2"
    local cmd="$3"

    local raw_output
    raw_output=$(osmo_vty "$node" "$port" enable "$cmd" end) || return 1

    # Filtrer les lignes de banniere/prompt (motif et ordre identiques a avant).
    printf '%s\n' "$raw_output" | osmo_vty_clean 'Free Software lives'
    return 0
}

# ── Verification rapide de disponibilite VTY ──────────────────────────────────
vty_available() {
    osmo_vty_up "$1" "$2"
}

# ── Detection du monde et inventaire ──────────────────────────────────────────
MODE="$(osmo_mode)"

# Operateurs : conteneurs osmo-operator-N en docker ; en natif, OSMO_OP_IDS,
# puis les netns osmo-opN, puis N_OPERATORS de globals.conf, sinon 1.
mapfile -t OPS < <(osmo_ops)
N_OPS=${#OPS[@]}

# Hub : conteneur osmo-inter-stp en docker ; en natif, cette machine SI elle
# porte le role interstp. Sur un noeud operateur natif, le hub est ailleurs :
# osmo_hub rend 1 et osmo_hub_hint dit quoi lancer, et ou.
HAS_INTER_STP=0
HUB_NODE="$INTER_STP"
if HUB_NODE="$(osmo_hub)"; then
    HAS_INTER_STP=1
else
    HUB_NODE="$INTER_STP"
fi

# HUB_REMOTE_IP - adresse du hub quand il ne tourne PAS ici : WAN docker
# (start.sh --wan/--hub-ip injecte OSMO_HUB_IP dans les conteneurs), ou noeud
# operateur natif. Vide si le hub est local, ou si aucune adresse n'est connue.
HUB_REMOTE_IP="$(osmo_hub_is_remote 2>/dev/null || true)"

# HUB_EXPECTED - "un hub devrait exister" (≠ "je peux l'interroger").
# Un hub distant reste attendu des qu'une adresse est connue - OSMO_HUB_IP de
# /etc/osmo-role en natif, l'adresse --hub-ip vue par les conteneurs en docker
# WAN : la route par defaut du STP local vers ce hub, elle, est parfaitement
# verifiable d'ici, meme si l'etat interne du hub ne l'est pas. En docker SANS
# WAN les deux notions se confondent toujours : pas de conteneur, pas de hub.
HUB_EXPECTED=$HAS_INTER_STP
if [ "$HUB_EXPECTED" -eq 0 ] && [ -n "$HUB_REMOTE_IP" ]; then
    HUB_EXPECTED=1
fi

# Nombre d'AS/ASP attendus sur le hub. En docker c'est le nombre d'operateurs
# LOCAUX, qui sont exactement ceux qui s'attachent au hub. En natif le hub sert
# des operateurs DISTANTS : aucun inventaire local ne dit combien il devrait y
# en avoir - on juge alors sur la presence, pas sur un total invente.
EXPECT_AS=0
[ "$MODE" = docker ] && EXPECT_AS=$N_OPS

if osmo_is_docker; then
    MODE_LABEL="docker (conteneurs osmo-operator-N)"
elif osmo_in_container; then
    MODE_LABEL="natif (dans le conteneur ${HOSTNAME:-?})"
else
    MODE_LABEL="natif (cette machine)"
fi

# Ligne de cadre : la largeur est calculee en CARACTERES (${#s}) et non en
# octets - "printf %-58s" compte les octets et decale d'un cran par accent.
boxline() {
    local s="$1" n
    n=$(( 58 - ${#s} )); [ "$n" -lt 0 ] && n=0
    echo -e "${CYAN}║${s}$(printf '%*s' "$n" '')║${NC}"
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
boxline "          SS7 Health Check - $(date '+%H:%M:%S')"
boxline "          mode : ${MODE_LABEL}"
if [ -n "$HUB_REMOTE_IP" ]; then
    boxline "          ${N_OPS} operateur(s)  inter-stp : distant ${HUB_REMOTE_IP}"
else
    boxline "          ${N_OPS} operateur(s)  inter-stp=${HAS_INTER_STP}"
fi
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

if [ "$N_OPS" -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ] && [ -z "$HUB_REMOTE_IP" ]; then
    if [ "$MODE" = docker ]; then
        echo -e "${RED}Aucun container trouve${NC}"
    else
        echo -e "${RED}Aucun operateur ni inter-STP sur cette machine${NC}"
    fi
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 1 : Inter-STP (hub central)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ]; then
    banner "INTER-STP (hub SS7) - 0.23.0"

    if ! vty_available "$HUB_NODE" 4239; then
        fail "VTY inter-STP (4239) inaccessible"
    else
        ok "VTY accessible"

        # Verifier que l'inter-STP voit tous les operateurs comme AS
        as_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 as all")
        n_as_total=$(echo "$as_output" | grep -cE 'as-op[0-9]+' || true)
        n_as_active=$(echo "$as_output" | grep -cE 'AS_ACTIVE' || true)
        info "AS declares sur le hub : ${n_as_total}"

        if [ "$EXPECT_AS" -gt 0 ]; then
            if [ "$n_as_active" -eq "$EXPECT_AS" ]; then
                ok "AS : ${n_as_active}/${EXPECT_AS} actifs (tous)"
            elif [ "$n_as_active" -gt 0 ]; then
                warn "AS : ${n_as_active}/${EXPECT_AS} actifs"
            else
                fail "AS : aucun actif"
            fi
        elif [ "$n_as_active" -gt 0 ]; then
            # Natif : les operateurs sont des machines distantes, le total
            # attendu n'est pas connaissable d'ici.
            ok "AS : ${n_as_active} actif(s) (total attendu inconnu en natif)"
        else
            fail "AS : aucun actif"
        fi

        # Verifier les ASP connectes
        asp_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 asp")
        n_asp_active=$(echo "$asp_output" | grep -cE 'ASP_ACTIVE' || true)

        if [ "$EXPECT_AS" -gt 0 ]; then
            if [ "$n_asp_active" -eq "$EXPECT_AS" ]; then
                ok "ASP : ${n_asp_active}/${EXPECT_AS} connectes (tous)"
            else
                warn "ASP : ${n_asp_active}/${EXPECT_AS} connectes"
            fi
        elif [ "$n_asp_active" -gt 0 ]; then
            ok "ASP : ${n_asp_active} connecte(s) (total attendu inconnu en natif)"
        else
            warn "ASP : aucun connecte"
        fi

        # Verifier l'absence de PROHIB (routes bloquees)
        route_output=$(vty_cmd "$HUB_NODE" 4239 "show cs7 instance 0 route")
        n_prohib=$(echo "$route_output" | grep -ciE 'prohib' || true)

        if [ "$n_prohib" -eq 0 ]; then
            ok "Routes : aucun PROHIB"
        else
            fail "Routes : ${n_prohib} PROHIB detectees"
        fi
    fi
elif [ -n "$HUB_REMOTE_IP" ]; then
    # Hub DISTANT (WAN) : "conteneur absent" serait un contresens - le hub
    # tourne, ailleurs. Ce qui est observable d'ici, c'est le LIEN vers lui.
    banner "INTER-STP (hub distant ${HUB_REMOTE_IP})"

    # Le lien operateur → hub est du M3UA sur SCTP (osmo-stp.cfg : "asp
    # asp-to-inter 2908 2910 m3ua"). Une sonde TCP sur 2908 rendrait
    # "Connection refused" sur un lien parfaitement monte : c'est l'association
    # SCTP, vue depuis les noeuds, qui fait foi.
    hub_assoc="$(osmo_hub_assoc "$HUB_REMOTE_IP" 2>/dev/null)" && hub_rc=0 || hub_rc=$?
    case "$hub_rc" in
        0) ok "Lien M3UA/SCTP → ${HUB_REMOTE_IP}:${OSMO_HUB_M3UA_PORT} : ${hub_assoc} noeud(s) associe(s)" ;;
        1) fail "Aucune association SCTP vers ${HUB_REMOTE_IP}:${OSMO_HUB_M3UA_PORT} (${hub_assoc}) - hub arrete, filtre, ou ASP shutdown" ;;
        *) skip "Association SCTP vers ${HUB_REMOTE_IP} non sondable ici (ss --sctp absent des noeuds)" ;;
    esac

    # Pas de faux echec sur l'etat INTERNE du hub : son VTY n'ecoute que sur SA
    # boucle locale. La phrase vient de _mode.sh et nomme l'IP reelle.
    skip "$(osmo_hub_hint)"
else
    banner "INTER-STP"
    if [ "$MODE" = docker ]; then
        skip "Container ${INTER_STP} absent"
    else
        # Pas de faux echec : le hub est peut-etre parfaitement vivant, mais son
        # VTY n'ecoute que sur SA boucle locale. La phrase vient de _mode.sh et
        # nomme l'IP reelle du hub quand /etc/osmo-role la donne.
        skip "$(osmo_hub_hint)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 2 : Chaque operateur
# ══════════════════════════════════════════════════════════════════════════════
for op in ${OPS[@]+"${OPS[@]}"}; do
    op_id="$op"
    # osmo_node garde l'etiquette "osmo-operator-N" meme en natif : c'est le
    # nom d'affichage que les autres checks correlent.
    container="$(osmo_node "$op")"
    banner "OPERATEUR ${op_id} (${container}) - STP ${op_id}.23.2"

    # ── STP local (4239) ─────────────────────────────────────────────────
    echo -e "  ${BOLD}STP local :${NC}"
    if ! vty_available "$op" 4239; then
        fail "STP VTY (4239) inaccessible"
    else
        # Verifier la connexion vers l'inter-STP
        as_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 as all")
        inter_state=$(echo "$as_out" | grep -oP 'as-inter\s+\K(AS_\w+)' || echo "ABSENT")

        if [[ "$inter_state" == "AS_ACTIVE" ]]; then
            ok "as-inter → hub : ACTIVE"
        elif [[ "$inter_state" == "ABSENT" ]] && [ "$HUB_EXPECTED" -eq 1 ]; then
            fail "as-inter absent (pas de connexion au hub)"
        elif [[ "$inter_state" == "ABSENT" ]]; then
            skip "as-inter : ignore (aucun inter-STP connu depuis ce noeud)"
        else
            warn "as-inter : ${inter_state}"
        fi

        # Verifier les ASP locaux (MSC/BSC)
        asp_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 asp")
        n_asp_ok=$(echo "$asp_out" | grep -cE 'ASP_ACTIVE' || true)

        if [ "$n_asp_ok" -ge 2 ]; then
            ok "ASP locaux : au moins 2 actifs (MSC+BSC)"
        elif [ "$n_asp_ok" -eq 1 ]; then
            warn "ASP locaux : 1 seul actif (manque MSC ou BSC)"
        else
            fail "ASP locaux : aucun actif"
        fi

        # Verifier la route par defaut vers l'inter-STP (element cle).
        # Verifiable des qu'un hub est ATTENDU : le hub distant d'un lab natif
        # se voit dans la table de routage du STP local, meme si son VTY a lui
        # est hors de portee.
        route_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 route")
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0.*avail' || true)

        if [ "$has_default" -gt 0 ] && [ "$HUB_EXPECTED" -eq 1 ]; then
            ok "Route par defaut → inter-STP : presente et avail"
        elif [ "$HUB_EXPECTED" -eq 1 ]; then
            fail "Route par defaut → inter-STP absente ou non avail"
        elif [ "$MODE" != docker ]; then
            skip "Route par defaut → inter-STP : ignore (natif, aucun hub declare ici)"
        fi

        # Verifier l'absence de PROHIB
        n_prohib=$(echo "$route_out" | grep -ciE 'prohib' || true)
        if [ "$n_prohib" -gt 0 ]; then
            fail "Routes PROHIB detectees : ${n_prohib}"
        fi

        # Compter les routes dynamiques (juste pour info)
        n_dyn=$(echo "$route_out" | grep -c 'dyn' || true)
        info "Routes dynamiques apprises : ${n_dyn} (normal: devrait augmenter avec le nombre d'operateurs)"
    fi

    # En mode quick, on passe au prochain operateur
    if [ "$QUICK" -eq 1 ]; then
        continue
    fi

    # ── MSC (4254) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}MSC :${NC}"
    if ! vty_available "$op" 4254; then
        fail "MSC VTY (4254) inaccessible"
    else
        msc_asp=$(vty_cmd "$op" 4254 "show cs7 instance 0 asp")
        msc_active=$(echo "$msc_asp" | grep -cE 'ASP_ACTIVE' || true)
        [ "$msc_active" -gt 0 ] && ok "MSC→STP : ASP_ACTIVE" || fail "MSC→STP : pas de ASP actif"

        # SCCP - osmo_qgrep, et non "grep -q" : en bout de tube, grep -q sort
        # au premier match et tue le producteur en SIGPIPE (141 sous pipefail).
        msc_sccp=$(vty_cmd "$op" 4254 "show cs7 instance 0 sccp users")
        echo "$msc_sccp" | osmo_qgrep -E 'SSN 254' && ok "SCCP SSN 254 (MSC-A) enregistre" || fail "SCCP SSN 254 absent"
    fi

    # ── BSC (4242) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}BSC :${NC}"
    if ! vty_available "$op" 4242; then
        fail "BSC VTY (4242) inaccessible"
    else
        bsc_asp=$(vty_cmd "$op" 4242 "show cs7 instance 0 asp")
        bsc_active=$(echo "$bsc_asp" | grep -cE 'ASP_ACTIVE' || true)
        [ "$bsc_active" -gt 0 ] && ok "BSC→STP : ASP_ACTIVE" || fail "BSC→STP : pas de ASP actif"

        # SCCP
        bsc_sccp=$(vty_cmd "$op" 4242 "show cs7 instance 0 sccp users")
        echo "$bsc_sccp" | osmo_qgrep -E 'SSN 254' && ok "SCCP SSN 254 (BSC) enregistre" || fail "SCCP SSN 254 absent"

        # BTS state (optionnel)
        bsc_bts=$(vty_cmd "$op" 4242 "show bts 0" 2>/dev/null || echo "")
        if echo "$bsc_bts" | osmo_qgrep -E "Oper 'Enabled'.*Avail 'OK'"; then
            ok "BTS 0 : OK"
        fi
    fi

    # ── HLR (4258) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}HLR :${NC}"
    if ! vty_available "$op" 4258; then
        fail "HLR VTY (4258) inaccessible"
    else
        hlr_gsup=$(vty_cmd "$op" 4258 "show gsup-connections")
        vlr_conn=$(echo "$hlr_gsup" | grep -cE "VLR" || true)
        [ "$vlr_conn" -gt 0 ] && ok "GSUP : VLR connecte" || fail "GSUP : VLR absent"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 3 : Matrice de connectivite simple
# ══════════════════════════════════════════════════════════════════════════════
# La matrice croise les operateurs LOCAUX entre eux via le hub : elle a du sens
# des qu'un hub est ATTENDU (local, ou distant en WAN - le trafic op1↔op2 le
# traverse dans les deux cas) et qu'il y a plus d'un operateur ici. Sur un
# mono-operateur elle se reduirait a une case "self" - on l'annonce ignoree
# plutot que de la dessiner vide, et on renvoie vers le check qui, lui, sait
# regarder entre machines.
if [ "$HUB_EXPECTED" -eq 1 ] && [ "$N_OPS" -gt 1 ]; then
    if [ -n "$HUB_REMOTE_IP" ]; then
        banner "MATRICE DE CONNECTIVITE (via inter-STP distant ${HUB_REMOTE_IP})"
    else
        banner "MATRICE DE CONNECTIVITE (via inter-STP)"
    fi

    printf "  %-8s" ""
    for j in "${OPS[@]}"; do printf "  Op%-3s" "$j"; done
    echo ""

    for op in "${OPS[@]}"; do
        src_id="$op"
        printf "  Op%-5s" "${src_id}"

        # On ne teste que la connectivite de base : l'operateur a-t-il une route par defaut ?
        route_out=$(vty_cmd "$op" 4239 "show cs7 instance 0 route" 2>/dev/null || echo "")
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0.*avail' || true)

        for j in "${OPS[@]}"; do
            if [ "$j" -eq "$src_id" ]; then
                printf "  ${CYAN}%-5s${NC}" "self"
            elif [ "$has_default" -gt 0 ]; then
                # Si route par defaut, on suppose que la connectivite est possible via l'inter-STP
                printf "  ${GREEN}%-5s${NC}" "via"
            else
                printf "  ${RED}%-5s${NC}" "FAIL"
                FAIL=$((FAIL+1))
            fi
        done
        echo ""
    done
    echo ""
    echo "  Note: 'via' signifie que l'operateur a une route par defaut vers l'inter-STP"
    echo "  Les routes dynamiques specifiques sont apprises au fur et a mesure"
elif [ "$MODE" != docker ]; then
    banner "MATRICE DE CONNECTIVITE (via inter-STP)"
    skip "ignore (natif) : ${N_OPS} operateur(s) local(aux) - la connectivite entre operateurs passe par le WAN, voir checks/wan_ss7_check.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RESUME
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "$(printf '═%.0s' {1..60})"

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}SS7 OK${NC}  -  ${GREEN}${PASS} pass${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
elif [ "$FAIL" -le 3 ]; then
    echo -e "  ${YELLOW}${BOLD}SS7 DEGRADE${NC}  -  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
else
    echo -e "  ${RED}${BOLD}SS7 KO${NC}  -  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
fi
echo -e "$(printf '═%.0s' {1..60})"
echo ""

exit "$FAIL"
