#!/bin/bash
# sms-routing-setup.sh - Gestion complete du routage SMS inter-operateur
#
# Fonctions exportables appelees depuis start.sh :
#   sms_routing_generate  <op_id> <n_ops> <destdir> [op1_nms op2_nms ...]
#   sms_routing_validate  <conf_file>
#   sms_routing_summary   <n_ops>         [op1_nms op2_nms ...]
#
# Formules COMMUNES (identiques a run.sh, hlr-feed-subscribers.sh) :
#   MSISDN  = <noeud>00<op_id><ms_idx>       (100101, 100102, 100201...)
#   IMSI    = MCC(3) + MNC(2) + printf('%04d%06d', op_id, ms_idx)
#   KI      = 00 11 22 33 44 55 66 77 88 99 aa bb cc dd <ms_hex> <op_hex>
#
# Architecture de routage :
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │  MS (op1, ms1)  MSISDN=10001  envoie a  MSISDN=20002 (op2, ms2)   │
#   │    → proto-smsc-daemon (op1) → MO log                              │
#   │    → sms-interop-relay.py (op1) : lookup prefix 20002 → op2       │
#   │    → TCP 172.20.0.12:7890                                           │
#   │    → sms-interop-relay.py (op2) : MSISDN→IMSI via HLR VTY         │
#   │    → proto-smsc-sendmt (op2) → HLR (op2) → MS (op2, ms2)          │
#   └─────────────────────────────────────────────────────────────────────┘
#
# Usage autonome (test/debug) :
#   bash sms-routing-setup.sh generate 1 3 /tmp/sms-cfg 2 2 3
#   bash sms-routing-setup.sh validate /tmp/sms-cfg/sms-routing-op1.conf
#   bash sms-routing-setup.sh summary  3 2 2 3

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers internes
# ═══════════════════════════════════════════════════════════════════════════════

_sms_op_backbone_ip() { echo "172.20.0.$((10 + $1))"; }
# MSISDN = <noeud>00<operateur><rang sur 2 chiffres> : le premier chiffre est
# l'adresse du noeud, c'est lui qui route. Le noeud vient du plan radio ecrit
# par generate_configs.sh, de l'environnement, ou vaut 1.
_sms_node_id() {
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' /etc/osmocom/radio-plan.env 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
_sms_op_msisdn()      { echo $(( $(_sms_node_id) * 100000 + $1 * 100 + $2 )); }   # op_id ms_idx
_sms_op_ms_imsi()     {                                   # mcc mnc op_id ms_idx
    local mcc=$1 mnc=$2 op=$3 ms=$4
    printf '%s%s%04d%06d' "$mcc" "$mnc" "$op" "$ms"
}
_sms_sc_address()     { printf '1999001%s444' "$1"; }    # op_id

_log_ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
_log_warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
_log_err()  { echo -e "  ${RED}✗${NC}  $*" >&2; }

# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_generate
#
# Genere configs/sms-routing-op<N>.conf pour chaque operateur.
# Le fichier de chaque operateur contient TOUTES les routes (locales + distantes)
# et est monte dans /etc/osmocom/sms-routing.conf du container.
#
# Usage :
#   sms_routing_generate <op_id> <n_ops> <destdir> [ms_counts...]
#   ms_counts : nombre de MS par operateur (1 valeur par operateur)
#               ex: "2 3 1" → op1=2MS, op2=3MS, op3=1MS
#
# Sortie :
#   <destdir>/sms-routing-op<op_id>.conf
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_generate() {
    local op_id="$1"
    local n_ops="$2"
    local destdir="$3"
    shift 3
    local ms_counts=("$@")   # tableau : ms_counts[0]=nMS_op1, [1]=nMS_op2, ...

    mkdir -p "$destdir"
    local outfile="${destdir}/sms-routing-op${op_id}.conf"

    # Valeurs par defaut si ms_counts non fourni
    local -a nms
    for i in $(seq 1 "$n_ops"); do
        nms[$i]=${ms_counts[$((i-1))]:-1}
    done

    local mcc="${MCC:-001}"

    cat > "$outfile" << HEADER
# ═══════════════════════════════════════════════════════════════════════════════
# sms-routing-op${op_id}.conf
# Genere par sms-routing-setup.sh - $(date '+%Y-%m-%d %H:%M:%S')
#
# Operateur local  : ${op_id}
# Nombre d'operat. : ${n_ops}
# MS par operateur : $(for i in $(seq 1 "$n_ops"); do printf 'Op%s=%s ' "$i" "${nms[$i]}"; done)
#
# Routage MSISDN :
#   MSISDN = <noeud> × 100000 + op_id × 100 + ms_idx
#   Regle longest-prefix match (prefixe le plus long l'emporte)
#
# ═══════════════════════════════════════════════════════════════════════════════

[local]
operator_id = ${op_id}
sc_address  = $(_sms_sc_address "$op_id")
hlr_vty_ip  = 127.0.0.1
hlr_vty_port = 4258
sendmt_socket = /tmp/sendmt_socket
mo_log = /var/log/osmocom/mo-sms-op${op_id}.log

[operators]
# operator_id = container_ip  (reseau backbone 172.20.0.0/24)
HEADER

    for i in $(seq 1 "$n_ops"); do
        printf '%s = %s\n' "$i" "$(_sms_op_backbone_ip "$i")" >> "$outfile"
    done

    cat >> "$outfile" << ROUTES_HEADER

[routes]
# Format : prefix = operator_id
# Longest-prefix match : le prefixe le plus long l'emporte.
# Strategie :
#   1. MSISDN exact de chaque MS          → routage precis (priorite max)
#   2. Prefixe court par operateur        → fallback pour MSISDN inconnus
#   3. Prefixes E.164 (+336XX...)           → routage international
#
ROUTES_HEADER

    # ── Routes exactes par MS (priorite maximale) ─────────────────────────────
    for i in $(seq 1 "$n_ops"); do
        local mnc; mnc=$(printf '%02d' "$i")
        printf '\n# ── Operateur %s (SC=%s) ──────────────────────────────────────\n' \
               "$i" "$(_sms_sc_address "$i")" >> "$outfile"
        printf '# %s MS declares\n' "${nms[$i]}" >> "$outfile"

        for ms in $(seq 1 "${nms[$i]}"); do
            local msisdn; msisdn=$(_sms_op_msisdn "$i" "$ms")
            local imsi; imsi=$(_sms_op_ms_imsi "$mcc" "$mnc" "$i" "$ms")
            # Commentaire IMSI pour tracabilite
            printf '%-8s = %s   # IMSI=%s\n' "$msisdn" "$i" "$imsi" >> "$outfile"
        done

        # Prefixe court de l'operateur (fallback MSISDN hors liste)
        local op_prefix="${i}0000"
        printf '# Fallback operateur %s (MSISDN inconnu)\n' "$i" >> "$outfile"
        printf '%-8s = %s\n' "$op_prefix" "$i" >> "$outfile"

        # Prefixe E.164 fictif : +336<op>X... (format francais simule)
        local e164_prefix; e164_prefix=$(printf '336%02d' "$i")
        printf '%-8s = %s   # E.164 +33 6%02d...\n' "$e164_prefix" "$i" "$i" >> "$outfile"
    done

    cat >> "$outfile" << ROUTES_FOOTER

[relay]
# Port TCP sur lequel ce relay ecoute les MT entrants d'autres operateurs.
port = 7890
# Timeout connexion vers un relay distant (secondes)
connect_timeout = 10
# Tentatives de reemission si le relay distant est indisponible
retry_count = 3
retry_delay = 5
ROUTES_FOOTER

    _log_ok "sms-routing-op${op_id}.conf → ${outfile}"
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_generate_all
#
# Genere les configs pour TOUS les operateurs en une seule passe.
# Appele depuis start.sh en mode bridge.
#
# Usage :
#   sms_routing_generate_all <n_ops> <destdir> [ms_counts...]
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_generate_all() {
    local n_ops="$1"
    local destdir="$2"
    shift 2
    local ms_counts=("$@")

    echo -e "${CYAN}${BOLD}── SMS Routing - generation configs (${n_ops} operateurs) ──${NC}"

    for i in $(seq 1 "$n_ops"); do
        sms_routing_generate "$i" "$n_ops" "$destdir" "${ms_counts[@]}"
    done

    echo -e "  ${GREEN}✓ Configs generees dans ${destdir}${NC}"
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_validate
#
# Verifie la coherence d'un fichier sms-routing.conf :
#   • Section [local] presente
#   • Section [operators] non vide
#   • Section [routes] non vide
#   • Aucune collision de prefixe exact entre deux operateurs differents
#   • MSISDN locaux routes vers l'operateur local
#
# Retourne 0 si OK, 1 si erreurs.
#
# Usage :
#   sms_routing_validate <conf_file>
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_validate() {
    local conf="$1"
    local errors=0

    echo -e "${CYAN}Validation : ${conf}${NC}"

    if [ ! -f "$conf" ]; then
        _log_err "Fichier introuvable : $conf"
        return 1
    fi

    # ── Sections obligatoires ─────────────────────────────────────────────────
    for section in local operators routes; do
        if ! grep -q "^\[${section}\]" "$conf"; then
            _log_err "Section manquante : [${section}]"
            errors=$(( errors + 1 ))
        fi
    done

    # ── operator_id dans [local] ──────────────────────────────────────────────
    local local_op
    local_op=$(awk '/^\[local\]/,/^\[/' "$conf" \
               | grep -E '^\s*operator_id\s*=' \
               | head -1 | cut -d= -f2 | tr -d ' ')
    if [ -z "$local_op" ]; then
        _log_err "[local] : operator_id manquant"
        errors=$(( errors + 1 ))
    else
        _log_ok "[local] operator_id = ${local_op}"
    fi

    # ── Au moins 1 operateur declare ─────────────────────────────────────────
    local op_count
    op_count=$(awk '/^\[operators\]/,/^\[/' "$conf" \
               | grep -cE '^\s*[0-9]+\s*=' || echo 0)
    if [ "$op_count" -eq 0 ]; then
        _log_err "[operators] : aucun operateur declare"
        errors=$(( errors + 1 ))
    else
        _log_ok "[operators] : ${op_count} operateur(s)"
    fi

    # ── Routes non vides ──────────────────────────────────────────────────────
    local route_count
    route_count=$(awk '/^\[routes\]/,/^\[/' "$conf" \
                  | grep -cE '^\s*[0-9]+\s*=' || echo 0)
    if [ "$route_count" -eq 0 ]; then
        _log_err "[routes] : aucune route definie"
        errors=$(( errors + 1 ))
    else
        _log_ok "[routes] : ${route_count} entree(s)"
    fi

    # ── Collision de prefixes : meme MSISDN → deux operateurs differents ─────
    local collision_count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue   # commentaire
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue   # vide
        [[ "$line" =~ ^\[ ]]           && continue   # section

        local prefix op
        prefix=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        op=$(echo "$line" | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')

        # Chercher si ce meme prefixe apparait avec un operateur different
        local other_op
        other_op=$(awk -v p="$prefix" -v o="$op" '
            /^\[routes\]/,/^\[/ {
                if ($0 ~ "^[[:space:]]*" p "[[:space:]]*=") {
                    split($0, a, "=")
                    gsub(/[[:space:]]/, "", a[2])
                    sub(/#.*/, "", a[2])
                    if (a[2] != o) { print a[2]; exit }
                }
            }' "$conf")

        if [ -n "$other_op" ]; then
            _log_err "Collision : prefixe ${prefix} → op${op} ET op${other_op}"
            collision_count=$(( collision_count + 1 ))
            errors=$(( errors + 1 ))
        fi
    done < <(awk '/^\[routes\]/,/^\[/' "$conf")

    [ "$collision_count" -eq 0 ] && _log_ok "Pas de collision de prefixes"

    # ── Routes MSISDN locaux → operateur local ────────────────────────────────
    if [ -n "$local_op" ]; then
        local wrong_local=0
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            [[ "$line" =~ ^\[ ]]           && continue

            local prefix op
            prefix=$(echo "$line" | cut -d= -f1 | tr -d ' ')
            op=$(echo "$line" | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')

            # Un MSISDN commencant par op_id devrait router vers op_id
            if [[ "$prefix" =~ ^${local_op}[0-9]* ]] && [ "$op" != "$local_op" ]; then
                _log_warn "MSISDN local ${prefix} route vers op${op} ≠ op${local_op}"
                wrong_local=$(( wrong_local + 1 ))
            fi
        done < <(awk '/^\[routes\]/,/^\[/' "$conf")
        [ "$wrong_local" -eq 0 ] && _log_ok "MSISDN locaux correctement routes"
    fi

    # ── Resultat ──────────────────────────────────────────────────────────────
    echo ""
    if [ "$errors" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}✓ Validation OK${NC}"
        return 0
    else
        echo -e "  ${RED}${BOLD}✗ ${errors} erreur(s)${NC}"
        return 1
    fi
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_summary
#
# Affiche la table de routage complete en format lisible (debug / audit).
# Montre tous les MSISDN enregistres et leur operateur cible.
#
# Usage :
#   sms_routing_summary <n_ops> [ms_counts...]
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_summary() {
    local n_ops="$1"
    shift
    local ms_counts=("$@")

    local mcc="${MCC:-001}"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                  SMS Routing - Table complete                   ║"
    printf "║  %d operateur(s)                                                 ║\n" "$n_ops"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # En-tete tableau
    printf "${BOLD}%-12s %-8s %-20s %-18s %-15s${NC}\n" \
           "MSISDN" "Op→" "IMSI" "Container IP" "SC-address"
    printf "%-12s %-8s %-20s %-18s %-15s\n" \
           "────────────" "────────" "────────────────────" "──────────────────" "───────────────"

    local total_ms=0
    for i in $(seq 1 "$n_ops"); do
        local n_ms=${ms_counts[$((i-1))]:-1}
        local mnc; mnc=$(printf '%02d' "$i")
        local container_ip; container_ip=$(_sms_op_backbone_ip "$i")
        local sc; sc=$(_sms_sc_address "$i")

        for ms in $(seq 1 "$n_ms"); do
            local msisdn; msisdn=$(_sms_op_msisdn "$i" "$ms")
            local imsi; imsi=$(_sms_op_ms_imsi "$mcc" "$mnc" "$i" "$ms")
            printf "%-12s ${CYAN}Op%-6s${NC} %-20s %-18s %-15s\n" \
                   "$msisdn" "$i" "$imsi" "$container_ip" "$sc"
            total_ms=$(( total_ms + 1 ))
        done

        # Ligne de separation entre operateurs
        [ "$i" -lt "$n_ops" ] && \
            printf "${YELLOW}%-12s %-8s %-20s %-18s %-15s${NC}\n" \
                   "──────────" "↓ Op$((i+1))" "" "" ""
    done

    echo ""
    printf "${BOLD}Total : %d MS  |  %d operateur(s)${NC}\n" "$total_ms" "$n_ops"

    echo ""
    echo -e "${CYAN}── Reseau inter-operateurs ──${NC}"
    for i in $(seq 1 "$n_ops"); do
        local n_ms=${ms_counts[$((i-1))]:-1}
        printf "  Op%-2s  %s  ← TCP 7890  (relay)  %d MS\n" \
               "$i" "$(_sms_op_backbone_ip "$i")" "$n_ms"
    done

    echo ""
    echo -e "${CYAN}── Exemple de flux SMS inter-op ──${NC}"
    if [ "$n_ops" -ge 2 ]; then
        local src_msisdn; src_msisdn=$(_sms_op_msisdn 1 1)
        local dst_msisdn; dst_msisdn=$(_sms_op_msisdn 2 1)
        printf "  %s (Op1) ──GSUP──► HLR(Op1) ──► proto-smsc-daemon\n" "$src_msisdn"
        printf "    ──► sms-interop-relay(Op1) [lookup %s → Op2]\n" "$dst_msisdn"
        printf "    ──TCP──► sms-interop-relay(Op2) @ %s:7890\n" "$(_sms_op_backbone_ip 2)"
        printf "    ──► HLR(Op2) VTY → IMSI lookup\n"
        printf "    ──► proto-smsc-sendmt(Op2) → MS\n"
    fi
    echo ""
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_mount_args
#
# Retourne les arguments -v Docker pour monter la config SMS du bon operateur.
# Utilise dans start_operator() de start.sh.
#
# Usage :
#   vol_args+=$(sms_routing_mount_args <op_id> <destdir>)
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_mount_args() {
    local op_id="$1"
    local destdir="$2"
    local conf="${destdir}/sms-routing-op${op_id}.conf"

    if [ -f "$conf" ]; then
        echo "-v ${conf}:/etc/osmocom/sms-routing.conf"
    else
        echo "" # pas de volume si le fichier n'existe pas encore
    fi
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_wait_ready
#
# Attend que le relay SMS d'un operateur soit pret (port TCP 7890 en ecoute).
# Appele optionnellement apres start_operator() pour s'assurer que le relay
# est disponible avant d'injecter des SMS de test.
#
# Usage :
#   sms_routing_wait_ready <container_name> [timeout_sec]
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_wait_ready() {
    local container="$1"
    local timeout="${2:-60}"
    local elapsed=0

    echo -ne "  Attente relay SMS (${container}) "

    while [ "$elapsed" -lt "$timeout" ]; do
        if docker exec "$container" \
           bash -c "ss -tlnp | grep -q ':7890'" 2>/dev/null; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done

    echo -e " ${YELLOW}timeout${NC}"
    return 1
}


# ═══════════════════════════════════════════════════════════════════════════════
# sms_routing_test_send
#
# Envoie un SMS de test entre deux MS de deux operateurs differents.
# Necessite que les containers soient demarres et les HLR alimentes.
#
# Usage :
#   sms_routing_test_send <src_container> <src_imsi> <dst_msisdn> <message>
#
# ═══════════════════════════════════════════════════════════════════════════════
sms_routing_test_send() {
    local src_container="$1"
    local src_imsi="$2"
    local dst_msisdn="$3"
    local message="$4"

    echo -e "${CYAN}Test SMS :${NC} ${src_container}  IMSI=${src_imsi} → MSISDN=${dst_msisdn}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${src_container}$"; then
        _log_err "Container ${src_container} non demarre"
        return 1
    fi

    docker exec "$src_container" bash -c "
        OPERATOR_ID=\${OPERATOR_ID:-1}
        SC_ADDRESS=\"\$(_sms_sc_address \$OPERATOR_ID)\" 2>/dev/null \
            || SC_ADDRESS=\"1999001\${OPERATOR_ID}444\"
        sms-encode-text '${message}' \
            | gen-sms-deliver-pdu \"\$SC_ADDRESS\" \
            | proto-smsc-sendmt \"\$SC_ADDRESS\" '${src_imsi}' /tmp/sendmt_socket
    " && _log_ok "SMS envoye" || _log_err "Echec envoi SMS"
}


# ═══════════════════════════════════════════════════════════════════════════════
# Point d'entree CLI (appel direct en ligne de commande)
# ═══════════════════════════════════════════════════════════════════════════════
_usage() {
    cat << 'EOF'
Usage: sms-routing-setup.sh <commande> [args...]

Commandes :
  generate <op_id> <n_ops> <destdir> [ms_counts...]
      Genere sms-routing-op<op_id>.conf dans <destdir>.
      ms_counts : nombre de MS par operateur (ex: 2 3 1 pour 3 ops).

  generate-all <n_ops> <destdir> [ms_counts...]
      Genere les configs pour TOUS les operateurs.

  validate <conf_file>
      Valide un fichier sms-routing.conf et affiche les erreurs.

  summary <n_ops> [ms_counts...]
      Affiche la table de routage complete (audit / debug).

  wait-ready <container_name> [timeout_sec]
      Attend que le relay SMS soit actif dans un container.

  test-send <container> <src_imsi> <dst_msisdn> <message>
      Envoie un SMS de test via proto-smsc-sendmt.

Variables d'environnement :
  MCC   : Mobile Country Code (defaut: 001)

Exemples :
  bash sms-routing-setup.sh generate-all 3 /tmp/sms-cfg 2 2 3
  bash sms-routing-setup.sh validate /tmp/sms-cfg/sms-routing-op1.conf
  bash sms-routing-setup.sh summary 2 2 3
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Execute directement (pas source)
    CMD="${1:-help}"; shift 2>/dev/null || true
    case "$CMD" in
        generate)      sms_routing_generate    "$@" ;;
        generate-all)  sms_routing_generate_all "$@" ;;
        validate)      sms_routing_validate     "$@" ;;
        summary)       sms_routing_summary      "$@" ;;
        wait-ready)    sms_routing_wait_ready   "$@" ;;
        test-send)     sms_routing_test_send    "$@" ;;
        help|-h|--help) _usage ;;
        *)
            echo -e "${RED}Commande inconnue : ${CMD}${NC}" >&2
            _usage; exit 1 ;;
    esac
fi
