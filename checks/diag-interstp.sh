#!/bin/bash
# =============================================================================
# checks/diag-interstp.sh - SS7 diagnostic as seen from the HUB (inter-STP)
#
# Answers one question: WHO is attached, and who is missing?
# What is attached is read from the hub itself (AS Name column and remote
# address of "show cs7 instance 0 asp"). /etc/osmo-wan.conf is only used for
# the roll call of absent nodes: a node missing from that table cannot be
# told apart from a node that is switched off.
#
# WHAT IT CHECKS
#   1. role and listen address (0.0.0.0 multi-homing is flagged)
#   2. daemon running, M3UA port listening
#   3. each AS declared by the hub: AS_ACTIVE / AS_DOWN, and attached ASPs
#   4. WAN table roll call: which expected address is seen nowhere
#   5. routes: PROHIB / UNAVAIL flagged
#   6. flapping: two measurements; renumbered dynamic ASPs reveal
#      associations that re-establish in a loop
#
# Read-only: changes nothing, restarts nothing.
#
# Usage: sudo ./checks/diag-interstp.sh [--watch] [--no-color]
#   --watch     second measurement at +10 s to detect flapping
# =============================================================================
set -uo pipefail

ROLE_FILE=/etc/osmo-role
WAN_FILE=/etc/osmo-wan.conf
CFG=/etc/osmocom/osmo-stp-interop.cfg
# The hub may have been moved off port 4239 (co-located with the operator
# STP, see start-interstp.sh): read its VTY port from its config.
VTY_PORT=4239
_hubp="$(sed -n 's/^ *bind 127\.0\.0\.1 \([0-9]*\)$/\1/p' "$CFG" 2>/dev/null | head -1)"
[ -n "$_hubp" ] && VTY_PORT="$_hubp"
M3UA_PORT=2908
WATCH=0; USE_COLOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --watch)    WATCH=1 ;;
    --no-color) USE_COLOR=0 ;;
    -h|--help)  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done

if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; C=$'\033[0;36m'; B=$'\033[1m'; Z=$'\033[0m'
else G=; R=; Y=; C=; B=; Z=; fi
OK="${G}[ OK ]${Z}"; KO="${R}[FAIL]${Z}"; WARN="${Y}[WARN]${Z}"
head(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }

vty(){ { printf 'enable\n'; for c in "$@"; do printf '%s\n' "$c"; done; sleep 0.6; } \
       | timeout 8 nc -q1 127.0.0.1 "$VTY_PORT" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }

getv(){ awk -F= -v k="$1" '$1==k{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "$ROLE_FILE" 2>/dev/null; }

# ---- identity ---------------------------------------------------------------
head "IDENTITE"
ROLE="$(getv OSMO_ROLE)"; SELF="$(getv OSMO_HUB_IP)"
printf '  hostname : %s\n' "$(hostname)"
printf '  role     : %s%s%s   adresse annoncee : %s%s%s\n' "$C" "${ROLE:-?}" "$Z" "$C" "${SELF:-?}" "$Z"
[ "$ROLE" = "interstp" ] || printf '  %s role=%s : ce script vise le HUB (voir diag-stp-operator.sh)\n' "$WARN" "${ROLE:-?}"

# effective listen address
LISTEN_IP="$(awk '/listen m3ua/{f=1} f&&/local-ip/{print $2; exit}' "$CFG" 2>/dev/null)"
LISTEN_PORT="$(awk '/listen m3ua/{print $3; exit}' "$CFG" 2>/dev/null)"
printf '  ecoute   : %s:%s\n' "${LISTEN_IP:-?}" "${LISTEN_PORT:-?}"
if [ "$LISTEN_IP" = "0.0.0.0" ]; then
  printf '  %s local-ip 0.0.0.0 : SCTP annonce TOUTES les adresses de la machine\n' "$WARN"
  printf '         dans son INIT (NAT, alias 172.20.x, host-only). Les noeuds tentent\n'
  printf '         des chemins morts et les ASP montent puis retombent, en boucle.\n'
  printf '         Corriger : set_stp_ip.sh --inter --ip <adresse du hub>\n'
fi

# ---- daemon -----------------------------------------------------------------
head "DEMON"
ST="$(systemctl is-active osmo-interstp 2>/dev/null)"
[ -z "$ST" ] && ST="$(systemctl is-active osmo-stp 2>/dev/null)"
if [ "$ST" = active ]; then printf '  %s service actif (%s)\n' "$OK" "$ST"
else printf '  %s service inactif (%s)\n' "$KO" "${ST:-inconnu}"; fi
if ss -Sanl 2>/dev/null | grep -q ":${LISTEN_PORT:-$M3UA_PORT} "; then
  printf '  %s port M3UA %s en ecoute (SCTP)\n' "$OK" "${LISTEN_PORT:-$M3UA_PORT}"
else
  printf '  %s port M3UA %s PAS en ecoute\n' "$KO" "${LISTEN_PORT:-$M3UA_PORT}"
fi

# ---- WAN table (only used for the roll call of absent nodes) ----------------
declare -A EXP_IP=()
NODES=""
if [ -r "$WAN_FILE" ]; then
  # Anchored at line start: the file's own comment line mentions
  # WAN_NODES="id:ip:prefix ..." and must not be parsed as an entry.
  spec="$(awk -F\" '/^WAN_NODES=/{print $2}' "$WAN_FILE" 2>/dev/null)"
  for tok in $spec; do
    id="${tok%%:*}"; rest="${tok#*:}"; ip="${rest%%:*}"
    EXP_IP[$id]="$ip"; NODES="$NODES $id"
  done
fi

# ---- AS / ASP ---------------------------------------------------------------
head "AS DECLARES PAR LE HUB"
AS_OUT="$(vty 'show cs7 instance 0 as all')"
ASP_OUT="$(vty 'show cs7 instance 0 asp')"

# Attachment is read where the hub declares it (AS Name column and remote
# address of its own output), never derived from the local WAN table. Column
# positions vary between libosmo-sigtran versions: the state and the address
# are matched by their form, not by their rank.
ASP_ROWS="$(printf '%s\n' "$ASP_OUT" | awk '
  /ASP_/ {
    st = ""; rem = ""
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^ASP_/) st = $i
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$/) rem = $i
    }
    sub(/:[0-9]+$/, "", rem)
    printf "%s|%s|%s|%s\n", $1, $2, (st == "" ? "?" : st), (rem == "" ? "?" : rem)
  }')"
AS_ROWS="$(printf '%s\n' "$AS_OUT" | awk '$1 ~ /^as-/ {print $1 "|" $2}')"

if [ -z "$AS_OUT" ]; then
  printf '  %s VTY injoignable sur 127.0.0.1:%s -- nc absent, ou demon arrete\n' "$KO" "$VTY_PORT"
elif [ -z "$AS_ROWS" ]; then
  printf '  %s aucun AS declare : conf du hub vide, ou autre instance cs7\n' "$KO"
else
  while IFS='|' read -r as_name as_state; do
    [ -n "$as_name" ] || continue
    if [ "$as_state" = AS_ACTIVE ]; then m="$OK"; else m="$KO"; fi
    printf '  %s %-12s %s\n' "$m" "$as_name" "${as_state:-?}"
    attache=0
    while IFS='|' read -r asp_name asp_as asp_state asp_rem; do
      [ "$asp_as" = "$as_name" ] || continue
      attache=1
      printf '         %-12s %-12s depuis %s\n' "$asp_name" "$asp_state" "$asp_rem"
    done <<< "$ASP_ROWS"
    [ "$attache" = 0 ] && printf '         aucun ASP rattache : noeud eteint, asp en shutdown, ou SCTP bloque\n'
  done <<< "$AS_ROWS"
  # NF: with no ASP at all, printf still emits an empty line whose empty
  # field 2 must not be reported as an orphan.
  orph="$(printf '%s\n' "$ASP_ROWS" | awk -F'|' 'NF && $2 !~ /^as-/ {printf "%s(%s) ", $1, $4}')"
  if [ -n "$orph" ]; then
    printf '  %s ASP connecte mais rattache a aucun AS : %s\n' "$WARN" "${orph% }"
    printf '         son routing context ne correspond a aucun AS du hub\n'
  fi
fi

head "APPEL DE LA TABLE WAN (${WAN_FILE})"
if [ -z "$ASP_OUT" ]; then
  printf '  %s pas de reponse VTY : rien a confronter a la table\n' "$KO"
elif [ -z "$NODES" ]; then
  printf '  %s table absente ou vide : impossible de dire qui manque a l appel,\n' "$WARN"
  printf '         la liste ci-dessus reste complete pour ce qui est attache\n'
else
  # An attached address missing from the table = node masked by NAT: the hub
  # sees the router's address, not the node's. Such a node must not be
  # declared absent just because it is masked.
  tab=" "
  for n in $NODES; do tab="$tab${EXP_IP[$n]} "; done
  hors=""
  for ip in $(printf '%s\n' "$ASP_ROWS" | awk -F'|' '$4 ~ /^[0-9]/ {print $4}' | sort -u); do
    case "$tab" in *" $ip "*) ;; *) hors="$hors $ip" ;; esac
  done
  # An address outside the table can mask only ONE node; without this count
  # a single masked ASP would downgrade every truly absent node to WARN.
  n_hors=0
  for _ in $hors; do n_hors=$(( n_hors + 1 )); done
  for n in $NODES; do
    if printf '%s\n' "$ASP_ROWS" | awk -F'|' -v ip="${EXP_IP[$n]}" '$4 == ip {f = 1} END {exit !f}'; then
      printf '  %s %-15s %-20s (noeud %s de la table)\n' "$OK" "${EXP_IP[$n]}" "attachee" "$n"
    elif [ "$n_hors" -gt 0 ]; then
      n_hors=$(( n_hors - 1 ))
      printf '  %s %-15s %-20s (noeud %s de la table)\n' "$WARN" "${EXP_IP[$n]}" "pas vue telle quelle" "$n"
    else
      printf '  %s %-15s %-20s (noeud %s de la table)\n' "$KO" "${EXP_IP[$n]}" "aucune association" "$n"
    fi
  done
  [ -n "$hors" ] && printf '  %s attachees hors table :%s -- masquage NAT probable\n' "$WARN" "$hors"
fi

head "ASP ATTACHES"
if [ -n "$ASP_OUT" ]; then
  printf '%s\n' "$ASP_OUT" | grep -E 'asp-|ASP Name' | sed 's/^/  /' | cut -c1-160
else
  printf '  %s pas de reponse VTY\n' "$KO"
fi

# ---- routes -----------------------------------------------------------------
head "ROUTES"
RT="$(vty 'show cs7 instance 0 route')"
if [ -n "$RT" ]; then
  bad="$(printf '%s\n' "$RT" | grep -E 'PROHIB|UNAVAIL|INACC' || true)"
  n_ok="$(printf '%s\n' "$RT" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+/' || true)"
  printf '  %s routes declarees\n' "${n_ok:-0}"
  if [ -n "$bad" ]; then
    printf '  %s destinations interdites ou injoignables :\n' "$WARN"
    printf '%s\n' "$bad" | sed 's/^/    /'
    printf '    (TFP herite d un flapping : relancer osmo-stp sur le noeud concerne)\n'
  else
    printf '  %s aucune route PROHIB/UNAVAIL\n' "$OK"
  fi
else
  printf '  %s pas de reponse VTY\n' "$KO"
fi

# ---- flapping ---------------------------------------------------------------
if [ "$WATCH" = 1 ]; then
  head "FLAPPING (2e mesure a +10 s)"
  first="$(printf '%s\n' "$ASP_OUT" | grep -oE 'asp-dyn-[0-9]+' | sort -u | tr '\n' ' ')"
  printf '  t0    : %s\n' "${first:-aucun}"
  sleep 10
  second="$(vty 'show cs7 instance 0 asp' | grep -oE 'asp-dyn-[0-9]+' | sort -u | tr '\n' ' ')"
  printf '  t+10s : %s\n' "${second:-aucun}"
  if [ "$first" = "$second" ]; then
    printf '  %s ASP stables - pas de reetablissement en boucle\n' "$OK"
  else
    printf '  %s les ASP dynamiques ont change de numero : les associations se\n' "$KO"
    printf '         reetablissent en boucle. Cause habituelle : local-ip 0.0.0.0\n'
    printf '         cote hub (multi-homing vers des adresses injoignables).\n'
  fi
fi

# ---- verdict ----------------------------------------------------------------
head "VERDICT"
if [ -n "${AS_OUT:-}" ]; then
  # Two naming conventions coexist: as-n<node>op<op> in WAN mode and as-op<i>
  # otherwise (helpers/create_interop.sh); the verdict counts both.
  tot="$(printf '%s\n' "$AS_OUT" | grep -cE 'as-(n[0-9]+)?op[0-9]+' || true)"
  act="$(printf '%s\n' "$AS_OUT" | grep -E 'as-(n[0-9]+)?op[0-9]+' | grep -c 'AS_ACTIVE' || true)"
  if [ "${act:-0}" -gt 0 ] && [ "${act:-0}" = "${tot:-0}" ]; then
    printf '  %sINTERCO SS7 : UP%s  - %s/%s AS actifs\n' "$G$B" "$Z" "$act" "$tot"
  elif [ "${act:-0}" -gt 0 ]; then
    printf '  %sINTERCO SS7 : PARTIELLE%s - %s/%s AS actifs\n' "$Y$B" "$Z" "$act" "$tot"
    echo   "  les noeuds manquants : demon arrete, ASP en shutdown, ou adresse fausse."
    echo   "  sur le noeud : checks/diag-stp-operator.sh"
  else
    printf '  %sINTERCO SS7 : DOWN%s - aucun AS actif\n' "$R$B" "$Z"
    echo   "  a verifier, dans l ordre :"
    echo   "    - local-ip du hub (0.0.0.0 = multi-homing, voir plus haut)"
    echo   "    - les noeuds pointent-ils la bonne adresse ? (remote-ip)"
    echo   "    - leur ASP est-il en 'no shutdown' ?"
  fi
else
  printf '  %sindeterminable%s : le VTY du hub ne repond pas\n' "$R$B" "$Z"
fi
echo "-------------------------------------------------------------------------"
exit 0
