#!/bin/bash
# global_check.sh - Verification complete de tous les composants Osmocom
#
# Verifie pour chaque operateur :
#   - STP (4239) : ASP, AS, routes
#   - HLR (4258) : connexions GSUP, abonnes
#   - MSC (4254) : ASP, SCCP, subscribers
#   - BSC (4242) : ASP, SCCP, BTS, OML/RSL
#   - BTS (4241) : etat des transceivers, LCHAN
#   - PCU (4240) : BTS, TBF, MS (si GPRS actif)
#   - SGSN (4245) : MM context, PDP context (si GPRS)
#   - GGSN (4260) : PDP context, APN (si GPRS)
#   - MGW (4243) : endpoints MGCP
#   - SIP connector (4255) : etat (si present)
#   - Services : SMS relay, MNCC socket, Asterisk
#
# DOUBLE MODE - docker ou natif
#   docker : chaque operateur est un conteneur osmo-operator-N ; on l'interroge
#            par "docker exec" ; l'inter-STP est le conteneur osmo-inter-stp.
#   natif  : ISO, VM ou machine nue ; un seul operateur, les demons tournent
#            ici, les VTY sont sur 127.0.0.1 (memes ports), les configs dans
#            /etc/osmocom.
# Le mode est DETECTE (checks/_mode.sh) et affiche en tete de sortie : un
# diagnostic qui ne dit pas dans quel monde il a regarde est inexploitable.
# --docker / --native forcent, quand la detection ne peut pas trancher (hote
# qui a docker installe mais fait tourner le lab en natif, par exemple).
#
# Usage :
#   sudo ./global_check.sh [--verbose] [--quick] [--op=N] [--docker|--native]

set -u

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Bibliotheque de mode (docker | natif) ─────────────────────────────────────
# Chemin RELATIF au script : le depot vit en /home/.../osmo_egprs pendant le
# developpement et en /opt/GSM/osmo_egprs sur l'ISO ; un chemin absolu casserait
# l'un des deux. Le second candidat couvre le cas d'un appel par lien
# symbolique, ou dirname ne pointe pas sur checks/.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo_egprs/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
VERBOSE=0
QUICK=0
SPECIFIC_OP=""
MODE_FORCED=0

# OSMO_MODE pose dans l'environnement est deja une forme de forcage
# ("OSMO_MODE=native ./checks/global_check.sh") : on le signale comme tel.
case "${OSMO_MODE:-}" in docker|native) MODE_FORCED=1 ;; esac

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quick|-q)   QUICK=1 ;;
        --op=*)       SPECIFIC_OP="${arg#*=}" ;;
        # osmo_mode_force rend 2 si l'argument n'est pas un mode : ici il en est
        # toujours un, le "|| true" ne sert qu'a survivre a un futur set -e.
        --docker|--native|--mode=*) osmo_mode_force "$arg" && MODE_FORCED=1 || true ;;
    esac
done

MODE="$(osmo_mode)"

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
    echo -e "$(printf '─%.0s' {1..70})"
}

section() {
    echo -e "\n  ${CYAN}${BOLD}$*${NC}"
}

# ── Fonction VTY ──────────────────────────────────────────────────────────────
# Meme signature qu'avant - premier argument : l'ETIQUETTE du noeud
# (osmo-operator-N), que osmo_vty traduit en "docker exec" ou en execution
# locale selon le mode. Les temporisations reproduisent a l'identique celles de
# l'ancienne implementation (0.5 / 2 / nc -q1) : les changer changerait la
# QUANTITE de sortie capturee, donc les "grep -c" qui la comptent plus bas.
vty_cmd() {
    local node="$1"
    local port="$2"
    local cmd="$3"
    local timeout="${4:-2}"

    local raw_output
    raw_output=$(OSMO_VTY_OPEN=0.5 OSMO_VTY_READ="$timeout" OSMO_VTY_Q=1 \
                 osmo_vty "$node" "$port" enable "$cmd" end) || return 1

    # Filtrage identique a l'ancien (motif et ordre des filtres) ; "Free
    # Software lives" en supplement, comme avant.
    printf '%s\n' "$raw_output" | osmo_vty_clean 'Free Software lives'
    return 0
}

# ── Verification rapide de disponibilite VTY ──────────────────────────────────
# En natif, osmo_vty_up sonde d'abord avec ss (passif, n'ouvre pas de session
# VTY) et ne retombe sur la connexion TCP que si ss ne voit rien.
vty_available() {
    osmo_vty_up "$1" "$2"
}

# ── Detection des operateurs ──────────────────────────────────────────────────
# docker : les conteneurs osmo-operator-N en cours.
# natif  : $OSMO_OP_IDS, sinon les netns osmo-opN, sinon N_OPERATORS de
#          globals.conf, sinon 1 - il n'existe pas d'inventaire en natif.
if [ -n "$SPECIFIC_OP" ]; then
    # osmo_op_exists est ANCRE, contrairement a l'ancien "docker ps | grep
    # osmo-operator-N" : "--op=1" acceptait aussi osmo-operator-10.
    if ! osmo_op_exists "$SPECIFIC_OP"; then
        echo -e "${RED}Operateur ${SPECIFIC_OP} non trouve (mode ${MODE})${NC}"
        exit 1
    fi
    OP_IDS=("$SPECIFIC_OP")
else
    mapfile -t OP_IDS < <(osmo_ops)
fi

N_OPS=${#OP_IDS[@]}

# Une ligne de l'encadre, remplie a la largeur exacte (58 colonnes). Le texte
# passe ici reste en ASCII : sous une locale C, ${#t} compterait les octets
# d'un caractere accentue et le cadre se decalerait.
box_line() {
    # Deux instructions, pas une : dans "local t="$1" pad=$(( ... ${#t} ))"
    # l'arithmetique est developpee AVANT l'affectation de t, ce qui donne
    # "variable sans liaison" sous set -u.
    local t="$1"
    local pad=$(( 58 - 5 - ${#t} ))
    [ "$pad" -lt 0 ] && pad=0
    printf "${CYAN}║     %s%*s║${NC}\n" "$t" "$pad" ""
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Global Health Check - $(date '+%Y-%m-%d %H:%M:%S')            ║${NC}"
echo -e "${CYAN}║     ${N_OPS} operateur(s) a verifier                              ║${NC}"
# Le mode fait partie du diagnostic : sans lui, un "service DOWN" ne dit pas
# s'il a ete cherche dans un conteneur ou sur cette machine.
if [ "$MODE_FORCED" -eq 1 ]; then
    box_line "mode : ${MODE} (force)"
else
    box_line "mode : ${MODE} (detecte)"
fi
if [ "$MODE" = native ]; then
    box_line "natif : demons locaux, VTY sur 127.0.0.1"
else
    box_line "docker : conteneurs osmo-operator-N"
fi
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

if [ "$N_OPS" -eq 0 ]; then
    # En natif osmo_ops rend toujours au moins "1" : ce cas est donc celui de
    # docker sans conteneur en cours. On le dit, plutot que de laisser croire a
    # une panne des services.
    echo -e "${RED}Aucun operateur trouve (mode ${MODE})${NC}"
    [ "$MODE" = docker ] && echo -e "     ${CYAN}aucun conteneur osmo-operator-N en cours - sudo ./start.sh${NC}"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Pour chaque operateur
# ══════════════════════════════════════════════════════════════════════════════
for op_id in "${OP_IDS[@]}"; do
    # osmo_node rend "osmo-operator-N" dans les DEUX modes : en docker c'est
    # le nom du conteneur, en natif un nom d'affichage. La banniere et les
    # champs "container=" que relit operator_summary.sh sont preserves.
    container="$(osmo_node "$op_id")"
    banner "OPERATEUR ${op_id} (${container})"

    # =========================================================================
    # 1. STP (port 4239)
    # =========================================================================
    section "STP (Signalisation)"

    if ! vty_available "$container" 4239; then
        fail "STP VTY (4239) inaccessible - service DOWN"
    else
        # ASP locaux
        asp_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 asp")
        n_asp=$(echo "$asp_out" | grep -c 'ASP_ACTIVE' || true)
        
        if [ "$n_asp" -ge 2 ]; then
            ok "ASP actifs : ${n_asp} (MSC+BSC ok)"
        elif [ "$n_asp" -eq 1 ]; then
            warn "ASP actifs : 1 seul (manque MSC ou BSC)"
        else
            fail "ASP actifs : aucun"
        fi

        # AS locaux
        as_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 as all")
        n_as=$(echo "$as_out" | grep -c 'AS_ACTIVE' || true)
        
        if [ "$n_as" -ge 2 ]; then
            ok "AS actifs : ${n_as}"
        else
            warn "AS actifs : ${n_as}"
        fi

        # Routes (pas de PROHIB)
        route_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 route")
        n_prohib=$(echo "$route_out" | grep -ciE 'prohib' || true)
        
        if [ "$n_prohib" -eq 0 ]; then
            ok "Routes : aucun PROHIB"
        else
            fail "Routes : ${n_prohib} PROHIB detectes"
        fi

        # Route par defaut vers inter-STP.
        # L'inter-STP est un conteneur en docker (osmo-inter-stp, 172.20.0.10).
        # En natif il n'existe que si CETTE machine tient ce role, ou s'il est
        # sur une autre machine du WAN : dans ce cas l'absence de route
        # catch-all n'est pas une anomalie, c'est la topologie. On l'ignore
        # explicitement au lieu de fabriquer un avertissement.
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0.*avail' || true)
        if [ "$has_default" -gt 0 ]; then
            ok "Route par defaut → inter-STP : presente"
        elif osmo_is_native && ! osmo_hub >/dev/null 2>&1; then
            skip "Route par defaut → inter-STP - ignore (natif) : $(osmo_hub_hint)"
        else
            warn "Route par defaut → inter-STP : absente"
        fi
    fi

    # =========================================================================
    # 2. HLR (port 4258)
    # =========================================================================
    section "HLR (Abonnes)"

    if ! vty_available "$container" 4258; then
        fail "HLR VTY (4258) inaccessible - service DOWN"
    else
        # Connexions GSUP
        gsup_out=$(vty_cmd "$container" 4258 "show gsup-connections")
        vlr_conn=$(echo "$gsup_out" | grep -c "VLR" || true)
        smsc_conn=$(echo "$gsup_out" | grep -c "SMSC" || true)

        [ "$vlr_conn" -gt 0 ] && ok "GSUP : VLR connecte" || fail "GSUP : VLR absent"
        [ "$smsc_conn" -gt 0 ] && ok "GSUP : SMSC connecte" || warn "GSUP : SMSC absent"

        # Nombre d'abonnes
        sub_out=$(vty_cmd "$container" 4258 "show subscriber count")
        sub_count=$(echo "$sub_out" | grep -oE '[0-9]+' | head -1)
        info "Abonnes dans HLR : ${sub_count:-0}"
    fi

    # =========================================================================
    # 3. MSC (port 4254)
    # =========================================================================
    section "MSC (Commutation)"

    if ! vty_available "$container" 4254; then
        fail "MSC VTY (4254) inaccessible - service DOWN"
    else
        # ASP vers STP
        msc_asp=$(vty_cmd "$container" 4254 "show cs7 instance 0 asp")
        msc_active=$(echo "$msc_asp" | grep -c 'ASP_ACTIVE' || true)
        [ "$msc_active" -gt 0 ] && ok "MSC→STP : ASP_ACTIVE" || fail "MSC→STP : pas de ASP actif"

        # SCCP
        msc_sccp=$(vty_cmd "$container" 4254 "show cs7 instance 0 sccp users")
        if echo "$msc_sccp" | grep -qE 'SSN 254'; then
            ok "SCCP SSN 254 (MSC-A) enregistre"
        else
            fail "SCCP SSN 254 absent"
        fi

        # Subscribers VLR
        vlr_out=$(vty_cmd "$container" 4254 "show subscriber count")
        vlr_count=$(echo "$vlr_out" | grep -oE '[0-9]+' | head -1 || echo "0")
        info "Subscribers dans VLR : ${vlr_count}"
    fi

    # =========================================================================
    # 4. BSC (port 4242)
    # =========================================================================
    section "BSC (Controleur BTS)"

    if ! vty_available "$container" 4242; then
        fail "BSC VTY (4242) inaccessible - service DOWN"
    else
        # ASP vers STP
        bsc_asp=$(vty_cmd "$container" 4242 "show cs7 instance 0 asp")
        bsc_active=$(echo "$bsc_asp" | grep -c 'ASP_ACTIVE' || true)
        [ "$bsc_active" -gt 0 ] && ok "BSC→STP : ASP_ACTIVE" || fail "BSC→STP : pas de ASP actif"

        # SCCP
        bsc_sccp=$(vty_cmd "$container" 4242 "show cs7 instance 0 sccp users")
        echo "$bsc_sccp" | grep -qE 'SSN 254' && ok "SCCP SSN 254 (BSC) enregistre" || fail "SCCP SSN 254 absent"

        # BTS 0 etat
        bts_out=$(vty_cmd "$container" 4242 "show bts 0")
        
        if echo "$bts_out" | grep -qE "Oper 'Enabled'.*Avail 'OK'"; then
            ok "BTS 0 : Enabled / OK"
        elif echo "$bts_out" | grep -qE "Oper 'Enabled'"; then
            warn "BTS 0 : Enabled mais Avail != OK"
        else
            fail "BTS 0 : pas Enabled"
        fi

        # OML dans show bts 0
        oml_up=$(echo "$bts_out" | grep -c 'OML Link state: connected' || true)
        [ "$oml_up" -gt 0 ] && ok "OML : connecte" || fail "OML : deconnecte"

        # RSL : verifier dans show trx 0 0 (pas dans show bts 0)
        trx_out=$(vty_cmd "$container" 4242 "show trx 0 0")
        rsl_up=$(echo "$trx_out" | grep -c 'RSL State: connected' || true)
        
        if [ "$rsl_up" -gt 0 ]; then
            ok "RSL : connecte (TRX 0)"
        else
            # Fallback : verifier si c'est mentionne ailleurs
            rsl_alt=$(echo "$bts_out" | grep -c 'RSL' || true)
            if [ "$rsl_alt" -gt 0 ]; then
                warn "RSL : statut ambigu (verifier manuellement)"
            else
                fail "RSL : deconnecte"
            fi
        fi

        # Nombre de BTS
        n_bts=$(vty_cmd "$container" 4242 "show bts all" | grep -c '^bts' || true)
        info "BTS configurees : ${n_bts}"
    fi

    # =========================================================================
    # 5. BTS (Station de base)
    # =========================================================================
    section "BTS (Station de base)"

    if ! vty_available "$container" 4242; then
        skip "BSC VTY (4242) inaccessible - impossible de verifier les BTS"
    else
        # Verifier BTS 0 directement
        bts0_out=$(vty_cmd "$container" 4242 "show bts 0")
        
        if [ -z "$bts0_out" ]; then
            fail "Impossible d'obtenir les informations de BTS 0"
        else
            # Verifier que la BTS existe (presence du nom)
            if echo "$bts0_out" | grep -q "BTS 0 is of osmo-bts type"; then
                ok "BTS 0 : configuree"
                
                # Etat operationnel
                if echo "$bts0_out" | grep -q "Oper 'Enabled'.*Avail 'OK'"; then
                    ok "BTS 0 : operationnelle (Enabled/OK)"
                elif echo "$bts0_out" | grep -q "Oper 'Enabled'"; then
                    warn "BTS 0 : Enabled mais Avail != OK"
                else
                    fail "BTS 0 : pas Enabled"
                fi
                
                # OML
                if echo "$bts0_out" | grep -q "OML Link state: connected"; then
                    ok "OML : connecte"
                else
                    fail "OML : deconnecte"
                fi
                
                # RSL (present dans les statistiques en bas)
                if echo "$bts0_out" | grep -q "Number of RSL links connected.* 1"; then
                    ok "RSL : connecte"
                elif echo "$bts0_out" | grep -q "Number of RSL links connected.* [1-9]"; then
                    ok "RSL : connecte (${BASH_REMATCH[1]})"
                else
                    # Verifier via TRX
                    trx0_out=$(vty_cmd "$container" 4242 "show trx 0 0" 2>/dev/null)
                    if echo "$trx0_out" | grep -q "RSL State: connected"; then
                        ok "RSL : connecte (TRX 0)"
                    else
                        fail "RSL : deconnecte"
                    fi
                fi
                
                # ARFCN
                arfcn=$(echo "$bts0_out" | grep -oE 'ARFCNs: [0-9]+' | head -1)
                [ -n "$arfcn" ] && info "$arfcn"
                
                # Uptime
                uptime=$(echo "$bts0_out" | grep "Seconds of uptime" | grep -oE '[0-9]+ s')
                [ -n "$uptime" ] && info "Uptime : ${uptime}"
                
                # Verifier s'il y a d'autres BTS
                n_bts=$(vty_cmd "$container" 4242 "show bts all" | grep -c '^bts' || true)
                if [ "$n_bts" -gt 1 ]; then
                    ok "BTS multiples : ${n_bts} (BTS 0 OK)"
                fi
            else
                fail "BTS 0 non trouvee dans la configuration"
            fi
        fi
    fi
    # =========================================================================
    # 6. PCU (port 4240) - GPRS
    # =========================================================================
    section "PCU (Controleur paquets)"

    if ! vty_available "$container" 4240; then
        skip "PCU VTY (4240) - non disponible (GPRS peut-etre desactive)"
    else
        # BTS
        pcu_bts=$(vty_cmd "$container" 4240 "show bts all")
        if [ -n "$pcu_bts" ]; then
            ok "PCU : connecte aux BTS"
        else
            warn "PCU : aucune BTS"
        fi

        # TBF
        tbf_out=$(vty_cmd "$container" 4240 "show tbf all")
        tbf_count=$(echo "$tbf_out" | grep -c 'TBF' || true)
        info "TBF actifs : ${tbf_count}"
    fi

    # =========================================================================
    # 7. SGSN (port 4245) - Core paquets
    # =========================================================================
    section "SGSN (Serving GPRS)"

    if ! vty_available "$container" 4245; then
        skip "SGSN VTY (4245) - non disponible (GPRS peut-etre desactive)"
    else
        # MM context
        mm_out=$(vty_cmd "$container" 4245 "show mm-context all")
        mm_count=$(echo "$mm_out" | grep -c 'IMSI' || true)
        info "MM contexts : ${mm_count}"

        # PDP context
        pdp_out=$(vty_cmd "$container" 4245 "show pdp-context all")
        pdp_count=$(echo "$pdp_out" | grep -c 'PDP' || true)
        info "PDP contexts : ${pdp_count}"

        # NS entities
        ns_out=$(vty_cmd "$container" 4245 "show ns entities")
        ns_count=$(echo "$ns_out" | grep -c 'NSVC' || true)
        [ "$ns_count" -gt 0 ] && ok "NS entities : ${ns_count}" || warn "NS entities : 0"
    fi

    # =========================================================================
    # 8. GGSN (port 4260) - Gateway GPRS
    # =========================================================================
    section "GGSN (Gateway GPRS)"

    if ! vty_available "$container" 4260; then
        skip "GGSN VTY (4260) - non disponible (GPRS peut-etre desactive)"
    else
        # PDP contexts
        ggsn_pdp=$(vty_cmd "$container" 4260 "show pdp-context all")
        ggsn_count=$(echo "$ggsn_pdp" | grep -c 'PDP' || true)
        info "PDP contexts GGSN : ${ggsn_count}"

        # APN
        apn_out=$(vty_cmd "$container" 4260 "show apn all")
        apn_count=$(echo "$apn_out" | grep -c 'APN' || true)
        [ "$apn_count" -gt 0 ] && ok "APN configures : ${apn_count}" || warn "APN configures : 0"
    fi

    # =========================================================================
    # 9. MGW (port 4243) - Media Gateway
    # =========================================================================
    section "MGW (Media Gateway)"

    if ! vty_available "$container" 4243; then
        fail "MGW VTY (4243) inaccessible"
    else
        # Endpoints
        ep_out=$(vty_cmd "$container" 4243 "show mgcp endpoint all")
        ep_count=$(echo "$ep_out" | grep -c 'Endpoint' || true)
        info "Endpoints MGCP : ${ep_count}"

        # Connexions actives
        conn_out=$(vty_cmd "$container" 4243 "show mgcp stats")
        if echo "$conn_out" | grep -qE "active calls.*[1-9]"; then
            ok "MGW : appels actifs"
        else
            info "MGW : aucun appel actif"
        fi
    fi

    # =========================================================================
    # 10. SIP connector (port 4255)
    # =========================================================================
    section "SIP connector (Voix)"

    if ! vty_available "$container" 4255; then
        skip "SIP connector VTY (4255) - non disponible"
    else
        ok "SIP connector : accessible"
        # Pas beaucoup de commandes show utiles dans osmo-sip-connector
    fi

    # =========================================================================
    # 11. Services
    # =========================================================================
    section "Services"

    # MNCC socket - osmo_sock interroge ss AVANT "test -S" : sous PrivateTmp
    # (unit systemd de l'ISO) le socket existe sans etre visible par test -S, et
    # un "voix impossible" mensonger en decoulerait.
    if osmo_sock "$container" /tmp/msc_mncc; then
        ok "MNCC socket present (MSC ↔ SIP connector)"
    else
        fail "MNCC socket absent - voix impossible"
    fi

    # SMS relay - awk sur le port exact, et non "grep -c :7890" qui aurait
    # aussi accepte 17890.
    if osmo_port "$container" 7890 tcp; then
        ok "SMS relay : ecoute sur port 7890"
    else
        warn "SMS relay : non detecte"
    fi

    # Asterisk
    if osmo_running "$container" asterisk; then
        ok "Asterisk : en cours d'execution"

        # Verification rapide Asterisk
        ast_out=$(osmo_ast "$container" "core show channels" || true)
        channels=$(echo "$ast_out" | grep -c "active channels" || true)
        info "Asterisk : ${channels} canaux actifs"
    else
        warn "Asterisk : non detecte"
    fi

    # Verification des processus cles
    section "Processus"

    # En natif, osmo_running essaie systemctl PUIS pgrep -x PUIS pgrep -f : les
    # demons sont des units sur l'ISO mais des processus detaches quand systemd
    # est absent, et /proc/PID/comm est tronque a 15 caracteres ("pgrep -x
    # osmo-sip-connector" ne trouve jamais rien).
    if [ "$MODE" = native ] && [ "$N_OPS" -gt 1 ]; then
        info "natif multi-operateur : ip netns exec n'isole pas les PID, ces etats portent sur la machine"
    fi

    for proc in osmo-stp osmo-hlr osmo-msc osmo-bsc osmo-bts-trx osmo-mgw osmo-sip-connector; do
        if osmo_running "$container" "$proc"; then
            ok "$proc : en cours"
        else
            # Certains processus peuvent ne pas etre presents selon configuration
            skip "$proc : non trouve"
        fi
    done

    echo ""
done

# ══════════════════════════════════════════════════════════════════════════════
# RESUME GLOBAL
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "$(printf '═%.0s' {1..70})"
echo -e "  ${BOLD}RESUME GLOBAL${NC}"
echo -e "$(printf '═%.0s' {1..70})"

TOTAL=$((PASS + FAIL + WARN + SKIP))

echo -e "  ${CYAN}mode   : ${MODE}${NC}  (${N_OPS} operateur(s))"
echo -e "  ${GREEN}✓ PASS : ${PASS}${NC}"
echo -e "  ${RED}✗ FAIL : ${FAIL}${NC}"
echo -e "  ${YELLOW}⚠ WARN : ${WARN}${NC}"
echo -e "  ${YELLOW}- SKIP : ${SKIP}${NC}"
echo -e "$(printf '─%.0s' {1..70})"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}TOUT EST OK${NC}  -  Tous les composants fonctionnent"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}FONCTIONNEL AVEC AVERTISSEMENTS${NC}  -  Verifier les warnings"
else
    echo -e "  ${RED}${BOLD}PROBLEMES DETECTES${NC}  -  ${FAIL} test(s) en echec"
fi
echo -e "$(printf '═%.0s' {1..70})"
echo ""

exit "$FAIL"
