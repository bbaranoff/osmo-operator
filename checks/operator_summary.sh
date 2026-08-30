#!/bin/bash
# operator_summary.sh - Resume des caracteristiques principales de chaque operateur
#
# Analyse le dump produit par checks/vty-debug-dump.sh et en extrait, operateur
# par operateur, les quelques chiffres qui disent si le reseau vit : ASP actifs,
# routes SS7, abonnes HLR/VLR, etat des BTS, contextes PDP, appels en cours.
#
# DOUBLE MODE (docker / natif)
# ----------------------------
# Ce script ne parle a AUCUN demon : il lit un fichier. Le mode ne change donc
# pas ses quinze extractions - il change trois choses, et il faut les dire :
#
#   1. la GENERATION du dump (--live) : le generateur doit regarder le MEME
#      monde que nous, sinon on analyse le dump d'un autre lab. Le mode lui est
#      transmis par OSMO_MODE, y compris quand il a ete force ici.
#
#   2. l'INTER-STP : en docker c'est le conteneur osmo-inter-stp ; en natif
#      c'est soit cette machine (role interstp), soit une AUTRE machine - et
#      dans ce dernier cas son VTY n'est pas joignable d'ici, donc le dump n'en
#      contient rien. La section est alors IGNOREE, explicitement : un
#      "0 AS actif" fabrique se lirait comme une panne du coeur SS7.
#
#   3. l'etiquette "container=osmo-operator-N" du dump : en natif elle reste
#      la meme (checks/_mode.sh, osmo_node). C'est une CLE DE CORRELATION entre
#      les blocs du dump, pas un objet docker interrogeable - on ne la renomme
#      donc pas, sous peine de casser toutes les extractions ci-dessous.
#
# Le mode retenu est affiche en tete : un resume qui ne dit pas dans quel monde
# il a regarde n'est pas exploitable.
#
# Usage :
#   sudo ./operator_summary.sh [--dump=/chemin/dump.txt] [--live]
#                              [--docker|--native]

set -euo pipefail

# ── Bibliotheque commune de detection docker/natif ────────────────────────────
# Chemin relatif a CE fichier (jamais absolu) : le depot vit dans /home/... en
# developpement et dans /opt/GSM/osmo_egprs sur l'ISO.
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
DUMP_FILE=""
LIVE_MODE=0
TEMP_DUMP=""

# OSMO_MODE herite de l'environnement vaut choix explicite, au meme titre que
# --docker/--native : on le signale comme "force" dans l'en-tete.
MODE_FORCED=0
[ -n "${OSMO_MODE:-}" ] && MODE_FORCED=1

for arg in "$@"; do
    case "$arg" in
        --dump=*) DUMP_FILE="${arg#*=}" ;;
        --live)   LIVE_MODE=1 ;;
        --docker|--native|--mode=*)
            # osmo_mode_force rend 2 si l'argument n'est pas un mode : seul
            # "--mode=n'importe-quoi" peut encore echouer ici.
            if osmo_mode_force "$arg"; then
                MODE_FORCED=1
            else
                echo "Mode inconnu : ${arg} (attendu : --docker, --native)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [--dump=/chemin/dump.txt] [--live] [--docker|--native]"
            echo "  --dump   : Utilise un fichier de dump existant"
            echo "  --live   : Genere un dump live avant l'analyse"
            echo "  --docker : Force le mode conteneurs (osmo-operator-N)"
            echo "  --native : Force le mode natif (ISO, VM, machine nue)"
            echo "             sans option, le mode est detecte automatiquement"
            exit 0
            ;;
    esac
done

MODE="$(osmo_mode)"
if [ "$MODE_FORCED" -eq 1 ]; then MODE_SRC="force"; else MODE_SRC="detecte"; fi

# ── Helper d'affichage ────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo -e "$(printf '─%.0s' {1..70})"
}

print_row() {
    printf "  %-20s : %s\n" "$1" "$2"
}

print_section() {
    echo -e "\n  ${CYAN}${BOLD}$1${NC}"
}

# Ligne de la boite d'en-tete, calee sur les 58 colonnes du filet ╔══╗.
box_line() {
    local txt="$1" pad
    pad=$(( 58 - 5 - ${#txt} ))
    [ "$pad" -ge 0 ] || pad=0
    echo -e "${CYAN}║     ${txt}$(printf '%*s' "$pad" '')║${NC}"
}

# ── Extraction de donnees depuis le dump ──────────────────────────────────────
#
# PIEGE PIPEFAIL, valable pour TOUTES les extractions de ce fichier : sous
# "set -o pipefail", un grep qui ne trouve rien (rc 1) ou un "head -1" qui
# sort tot (le producteur meurt en SIGPIPE, rc 141) fait echouer le tube entier,
# donc l'affectation "var=$(...)", donc - sous "set -e" - le script lui-meme.
# Sur un dump vide ou partiel (mode natif ou tout est absent, dump produit
# ailleurs) le resume s'interrompait sans un mot. D'ou les "|| true" : ils ne
# masquent aucune erreur, ils disent "rien trouve = zero", ce que wc et grep -c
# ont deja ecrit sur leur sortie.

extract_value() {
    local container="$1"
    local pattern="$2"
    local default="${3:-?}"

    grep -A20 "\[.*\] port=.* container=${container}" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | head -1 \
        | sed -E 's/^[[:space:]]+//' \
        || echo "$default"
}

extract_count() {
    local container="$1"
    local section="$2"
    local pattern="$3"

    grep -A50 "\[.*\] port=.* container=${container}.*$section" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | wc -l \
        | tr -d ' ' \
        || true
}

extract_subscriber_count() {
    local container="$1"
    local count

    count=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1 || true)

    echo "${count:-0}"
}

# Renseigne BTS_STATE, OML_OK et RSL_OK - des variables GLOBALES, a dessein.
# La version precedente ecrivait l'etat sur stdout ET posait OML_OK/RSL_OK dans
# la foulee ; appelee en "$( )" elle tournait dans un SOUS-SHELL, ou ces deux
# affectations mouraient avec lui : les lignes OML et RSL affichaient
# "✗ deconnecte" meme quand le dump montrait des liens connectes. On renseigne
# donc les trois au meme endroit, sans substitution de commande.
extract_bts_info() {
    local container="$1"
    local bts_id="$2"
    local bts_block oper avail oml rsl

    bts_block=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -A20 "bts ${bts_id}" \
        | sed -n '/bts [0-9]/,/^$/p' || true)

    oper=$(echo "$bts_block" | grep -c "Oper 'Enabled'" || true)
    avail=$(echo "$bts_block" | grep -c "Avail 'OK'" || true)
    oml=$(echo "$bts_block" | grep -c "OML Link state: connected" || true)
    rsl=$(echo "$bts_block" | grep -c "RSL State: connected" || true)

    if [ "$oper" -gt 0 ] && [ "$avail" -gt 0 ]; then
        BTS_STATE="OK"
    elif [ "$oper" -gt 0 ]; then
        BTS_STATE="Enabled"
    else
        BTS_STATE="Down"
    fi

    # Renseigne aussi OML/RSL pour info
    [ "$oml" -gt 0 ] && OML_OK=1 || OML_OK=0
    [ "$rsl" -gt 0 ] && RSL_OK=1 || RSL_OK=0
}

extract_asp_state() {
    local container="$1"
    local component="$2"  # STP, MSC, BSC

    local asp_block=""
    if [ "$component" = "STP" ]; then
        asp_block=$(grep -A30 "\[OsmoSTP\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "MSC" ]; then
        asp_block=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "BSC" ]; then
        asp_block=$(grep -A30 "\[OsmoBSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    fi

    echo "$asp_block" | grep -c "ASP_ACTIVE" || true
}

# ── Generation d'un dump live si demande ──────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ]; then
    echo -e "${CYAN}Generation d'un dump live (mode ${MODE})...${NC}"
    TEMP_DUMP="/tmp/vty-live-$$.txt"

    # Le generateur est cherche A COTE DE NOUS (BASH_SOURCE), plus dans le
    # repertoire courant : "./vty-debug-dump.sh" n'existait que si l'on avait
    # fait "cd checks/" au prealable, ce qui n'est pas le cas depuis l'ISO.
    DUMPER="$_here/vty-debug-dump.sh"
    [ -x "$DUMPER" ] || DUMPER="./vty-debug-dump.sh"

    # OSMO_MODE est transmis explicitement : le generateur doit interroger le
    # meme monde que celui qu'on analysera, meme si --native/--docker a force
    # un mode qu'il n'aurait pas detecte seul.
    if ! OSMO_MODE="$MODE" "$DUMPER" --out "$TEMP_DUMP" > /dev/null; then
        echo -e "${RED}Echec de la generation du dump (${DUMPER}, mode ${MODE}).${NC}" >&2
        if [ "$MODE" = native ]; then
            echo "  Mode natif : verifiez que les demons tournent (VTY 4239/4254/4242/4258...)." >&2
        else
            echo "  Mode docker : verifiez que les conteneurs osmo-operator-N sont en cours." >&2
        fi
        rm -f "$TEMP_DUMP"
        exit 1
    fi
    DUMP_FILE="$TEMP_DUMP"
    echo -e "${GREEN}✓ Dump genere : $DUMP_FILE${NC}"
fi

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo -e "${RED}Erreur : fichier de dump non specifie ou introuvable${NC}"
    echo "Utilisez --dump=/chemin/vers/dump.txt ou --live pour generer un dump"
    exit 1
fi

# ── Detection des noeuds presents DANS LE DUMP ─────────────────────────────────
# "container=osmo-operator-N" est ecrit par vty-debug-dump.sh dans les deux
# mondes : en docker c'est le nom du conteneur, en natif l'etiquette rendue par
# osmo_node(). On lit donc le dump de la meme facon des deux cotes.
mapfile -t CONTAINERS < <(
    grep -E "container=osmo-operator-[0-9]+" "$DUMP_FILE" \
        | sed -E 's/.*container=([^ ]+).*/\1/' \
        | sort -u
)

INTER_STP=$(grep -E "container=osmo-inter-stp" "$DUMP_FILE" \
    | sed -E 's/.*container=([^ ]+).*/\1/' \
    | head -1 || true)

N_OPS=${#CONTAINERS[@]}

# ── En-tete ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Resume Operateurs - $(date '+%Y-%m-%d %H:%M')              ║${NC}"
echo -e "${CYAN}║     ${N_OPS} operateur(s) trouve(s)                             ║${NC}"
box_line "Mode : ${MODE} (${MODE_SRC})"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

# Dump muet : on le dit. Le comparer a l'inventaire vivant distingue "rien ne
# tourne" de "le dump vient d'ailleurs / est partiel" - deux pannes tres
# differentes, surtout en natif ou aucun "docker ps" ne peut trancher.
if [ "$N_OPS" -eq 0 ]; then
    live_ops="$(osmo_ops 2>/dev/null | tr '\n' ' ' || true)"
    live_ops="${live_ops% }"
    echo ""
    echo -e "  ${YELLOW}Aucun bloc "container=osmo-operator-N" dans ce dump.${NC}"
    print_row "Operateurs vus ici" "${live_ops:-aucun} (mode ${MODE})"
    print_row "Dump" "vide, partiel, ou produit sur un autre noeud"
fi

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ -n "$INTER_STP" ]; then
    print_header "INTER-STP HUB (${INTER_STP})"

    asp_count=$(extract_asp_state "$INTER_STP" "STP")
    print_row "ASP actifs" "$asp_count"

    # Routes
    routes=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l || true)
    print_row "Routes configurees" "$routes"

    # AS
    as_count=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -c "AS_ACTIVE" || true)
    print_row "AS actifs" "$as_count"

elif osmo_is_native; then
    # Rien sur le hub dans le dump, et nous sommes en natif : soit cette machine
    # EST le hub et le dump est plus vieux qu'elle, soit le hub est une AUTRE
    # machine, dont le VTY 4239 n'ecoute que sur son propre 127.0.0.1 - il n'est
    # donc PAS observable d'ici. On l'ignore visiblement au lieu d'afficher des
    # compteurs a zero qui se liraient comme un coeur SS7 mort.
    print_header "INTER-STP HUB - ignore (natif)"
    if hub_here="$(osmo_hub)"; then
        print_row "Hub local" "${hub_here} present ici, mais absent du dump"
        print_row "Pour l'inclure" "relancez avec --live"
    else
        print_row "Hub" "$(osmo_hub_hint)"
    fi

elif hub_remote="$(osmo_hub_is_remote 2>/dev/null)"; then
    # WAN : le hub vit sur une AUTRE machine (--hub-ip / OSMO_HUB_IP), il ne
    # peut donc pas figurer dans un dump pris ici, et son VTY 4239 n'ecoute que
    # sur sa propre boucle locale. Ce qui est observable d'ici, c'est le LIEN
    # vers lui : l'association SCTP que chaque noeud tient ouverte.
    print_header "INTER-STP HUB - distant (${hub_remote})"
    hub_assoc="$(osmo_hub_assoc "$hub_remote" 2>/dev/null)" && hub_rc=0 || hub_rc=$?
    case "$hub_rc" in
        0) print_row "Lien M3UA/SCTP" "${hub_assoc} noeud(s) associe(s) a ${hub_remote}:${OSMO_HUB_M3UA_PORT}" ;;
        1) print_row "Lien M3UA/SCTP" "aucune association vers ${hub_remote}:${OSMO_HUB_M3UA_PORT}" ;;
        *) print_row "Lien M3UA/SCTP" "non sondable ici (ss --sctp absent des noeuds)" ;;
    esac
    print_row "Etat interne" "$(osmo_hub_hint)"

elif hub_here="$(osmo_hub)"; then
    # Mode docker : le conteneur tourne mais ne figure pas dans le dump - le
    # dump est donc anterieur au hub. Sans conteneur hub, on ne dit rien, comme
    # avant : il n'y a simplement pas d'inter-STP dans ce lab.
    print_header "INTER-STP HUB (${hub_here})"
    print_row "Etat" "conteneur en cours, mais absent du dump"
    print_row "Pour l'inclure" "relancez avec --live"
fi

# ── Boucle sur les operateurs ─────────────────────────────────────────────────
# "${CONTAINERS[@]+...}" : sur un dump muet le tableau est vide, et sous
# "set -u" un ""${CONTAINERS[@]}"" nu casserait au lieu de ne rien faire.
for container in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
    # Le numero est le suffixe de l'etiquette ; la mapfile n'a laisse passer que
    # "osmo-operator-<chiffres>", donc pas de sous-shell ni de grep ici.
    op_id="${container##*-}"

    print_header "OPERATEUR ${op_id} (${container})"

    # ── STP local ────────────────────────────────────────────────────────
    print_section "SS7"

    # ASP actifs dans STP
    stp_asp=$(extract_asp_state "$container" "STP")
    print_row "ASP actifs (STP)" "$stp_asp"

    # Routes
    routes=$(grep -A50 "\[OsmoSTP\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l || true)
    print_row "Routes configurees" "$routes"

    # ── MSC ───────────────────────────────────────────────────────────────
    print_section "MSC"

    msc_asp=$(extract_asp_state "$container" "MSC")
    print_row "ASP actif" "$([ "$msc_asp" -gt 0 ] && echo "✓" || echo "✗")"

    # Subscribers VLR
    vlr_count=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A20 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1 || true)
    print_row "Subscribers VLR" "${vlr_count:-0}"

    # Transactions
    trans=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "transaction" || true)
    print_row "Transactions" "$trans"

    # ── BSC ───────────────────────────────────────────────────────────────
    print_section "BSC"

    bsc_asp=$(extract_asp_state "$container" "BSC")
    print_row "ASP actif" "$([ "$bsc_asp" -gt 0 ] && echo "✓" || echo "✗")"

    # BTS 0 etat
    OML_OK=0
    RSL_OK=0
    BTS_STATE="Down"
    extract_bts_info "$container" 0
    print_row "BTS 0 etat" "$BTS_STATE"
    print_row "  ├─ OML" "$([ "$OML_OK" -eq 1 ] && echo "✓ connecte" || echo "✗ deconnecte")"
    print_row "  └─ RSL" "$([ "$RSL_OK" -eq 1 ] && echo "✓ connecte" || echo "✗ deconnecte")"

    # Nombre de BTS total
    n_bts=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -c "^ bts [0-9]" || true)
    print_row "BTS totales" "$n_bts"

    # ── HLR ───────────────────────────────────────────────────────────────
    print_section "HLR"

    subs_count=$(extract_subscriber_count "$container")
    print_row "Abonnes" "$subs_count"

    # Connexions GSUP
    gsup=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "GSUP" || true)
    print_row "Connexions GSUP" "$gsup"

    # ── BTS (si disponible) ───────────────────────────────────────────────
    print_section "BTS (phy)"

    # LCHAN actifs
    lchan=$(grep -A30 "\[OsmoBTS\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "lchan" || true)
    print_row "LCHAN" "$lchan"

    # ── SGSN/GGSN (si GPRS actif) ─────────────────────────────────────────
    print_section "GPRS"

    # NS entities
    ns=$(grep -A30 "\[OsmoSGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "NS entity" || true)
    print_row "NS entities" "$ns"

    # PDP contexts
    pdp=$(grep -A30 "\[OsmoGGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "PDP context" || true)
    print_row "PDP contexts" "$pdp"

    # ── Services auxiliaires ─────────────────────────────────────────────
    print_section "Services"

    # SIP connector
    sip_logs=$(grep -A10 "\[OsmoSIPconn\]" "$DUMP_FILE" \
        | grep -c "container=${container}" || true)
    print_row "SIP connector" "$([ "$sip_logs" -gt 0 ] && echo "✓ actif" || echo "?")"

    # SMS relay port
    sms=$(grep -A10 "\[.*\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -c "port 7890" || true)
    print_row "SMS relay" "$([ "$sms" -gt 0 ] && echo "✓ actif" || echo "?")"

    # ── Statistiques rapides ─────────────────────────────────────────────
    print_section "Statistiques"

    # Appels actifs
    calls=$(grep -A20 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "call-leg" || true)
    print_row "Appels actifs" "$calls"

    # Paging
    paging=$(grep -A20 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "paging" || true)
    print_row "Paging actifs" "$paging"

done

# ── Nettoyage ─────────────────────────────────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ] && [ -n "$TEMP_DUMP" ]; then
    rm -f "$TEMP_DUMP"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Analyse terminee - Dump utilise : ${DUMP_FILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
