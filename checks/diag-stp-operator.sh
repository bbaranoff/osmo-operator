#!/bin/bash
# =============================================================================
# diag-stp-operator.sh -- diagnostic SS7/interco vu d'un noeud operateur
#
# Lit le role et le plan WAN, compare la conf sur disque a ce que le demon
# osmo-stp fait tourner reellement (VTY), teste le transport SCTP vers
# l'inter-STP, et rend un verdict clair : interco UP / DOWN + la cause.
#
# Ne modifie rien. Ne redemarre rien. Lecture seule.
#
# Usage : sudo ./diag-stp-operator.sh [--node N] [--hub-ip IP] [--no-color]
# =============================================================================
set -uo pipefail

ROLE_FILE=/etc/osmo-role
WAN_FILE=/etc/osmo-wan.conf
CONF_DIR=/etc/osmocom
STP_CFG="$CONF_DIR/osmo-stp.cfg"
MSC_CFG="$CONF_DIR/osmo-msc.cfg"
BSC_CFG="$CONF_DIR/osmo-bsc.cfg"
VTY_PORT=4239
M3UA_PORT=2908

NODE=""; HUB_IP=""; USE_COLOR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE="${2:-}"; shift ;;
    --hub-ip) HUB_IP="${2:-}"; shift ;;
    --no-color) USE_COLOR=0 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done

if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; C=$'\033[0;36m'; B=$'\033[1m'; Z=$'\033[0m'
else G=; R=; Y=; C=; B=; Z=; fi
OK="${G}[ OK ]${Z}"; KO="${R}[FAIL]${Z}"; WARN="${Y}[WARN]${Z}"; NA="[ -- ]"
PROB=0
hr(){ printf '%s\n' "-------------------------------------------------------------------------"; }
head(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }

# ---- identite ---------------------------------------------------------------
getv(){ awk -F= -v k="$1" '$1==k{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "$ROLE_FILE" 2>/dev/null; }
[ -z "$NODE" ]   && NODE="$(getv OSMO_WAN_NODE)"
[ -z "$HUB_IP" ] && HUB_IP="$(getv OSMO_HUB_IP)"
ROLE="$(getv OSMO_ROLE)"
[ -z "$NODE" ] && NODE="?"

# IP locale de ce noeud, depuis la table WAN si dispo
SELF_IP=""
if [ -r "$WAN_FILE" ]; then
  wl="$(awk -F\" '/WAN_NODES=/{print $2}' "$WAN_FILE" 2>/dev/null)"
  for tok in $wl; do
    id="${tok%%:*}"; rest="${tok#*:}"; ip="${rest%%:*}"
    [ "$id" = "$NODE" ] && SELF_IP="$ip"
  done
fi

head "IDENTITE"
printf '  hostname     : %s\n' "$(hostname)"
printf '  role         : %s%s%s   noeud : %s%s%s\n' "$C" "${ROLE:-?}" "$Z" "$C" "$NODE" "$Z"
printf '  inter-STP    : %s%s%s   ce noeud (WAN) : %s%s%s\n' "$C" "${HUB_IP:-?}" "$Z" "$C" "${SELF_IP:-?}" "$Z"
if [ "$ROLE" != "operator" ]; then
  printf '  %s ce n est pas un noeud operateur (role=%s) -- utilise diag-interstp.sh\n' "$WARN" "${ROLE:-?}"
fi

# plan attendu pour ce noeud
if [ "$NODE" != "?" ]; then
  EXP_PC="1.${NODE}1.2"; EXP_MSC="1.${NODE}1.1"; EXP_BSC="1.${NODE}1.3"
  EXP_RK=$(( NODE*1000 + 150 ))
else
  EXP_PC=""; EXP_MSC=""; EXP_BSC=""; EXP_RK=""
fi

# ---- conf sur disque --------------------------------------------------------
head "CONF SUR DISQUE ($STP_CFG)"
f_pc="$(awk '/^cs7 instance/{c=1} c&&/^ *point-code /{print $2; exit}' "$STP_CFG" 2>/dev/null)"
f_rip="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$STP_CFG" 2>/dev/null)"
f_lip="$(awk '/asp asp-to-inter/{f=1} f&&/local-ip/{print $2; exit}' "$STP_CFG" 2>/dev/null)"
f_rk="$(awk '/as as-inter/{f=1} f&&/routing-key/{print $2; exit}' "$STP_CFG" 2>/dev/null)"
f_shut="$(awk '/asp asp-to-inter/{f=1} f&&/^ *no shutdown/{print "no"; exit} f&&/^ *shutdown/{print "yes"; exit} f&&/^ *as /{exit}' "$STP_CFG" 2>/dev/null)"
m_pc="$(awk '/^cs7 instance/{c=1} c&&/^ *point-code /{print $2; exit}' "$MSC_CFG" 2>/dev/null)"
b_pc="$(awk '/^cs7 instance/{c=1} c&&/^ *point-code /{print $2; exit}' "$BSC_CFG" 2>/dev/null)"

chk(){ # label got exp
  local label="$1" got="$2" exp="$3" m="$OK"
  if [ -n "$exp" ] && [ "$got" != "$exp" ]; then m="$KO"; PROB=$((PROB+1)); fi
  if [ -z "$got" ]; then m="$WARN"; got="(vide)"; fi
  printf '  %-26s %-16s %s\n' "$label" "$got" "$m$( [ -n "$exp" ]&&[ "$got" != "$exp" ]&&printf ' attendu %s' "$exp")"
}
chk "point-code STP"        "$f_pc"  "$EXP_PC"
chk "asp remote-ip (hub)"   "$f_rip" "$HUB_IP"
chk "asp local-ip (self)"   "$f_lip" "$SELF_IP"
chk "routing-key inter"     "$f_rk"  "$EXP_RK"
if [ "$f_shut" = "no" ]; then printf '  %-26s %-16s %s\n' "asp administratif" "no shutdown" "$OK"
elif [ "$f_shut" = "yes" ]; then printf '  %-26s %-16s %s\n' "asp administratif" "shutdown" "$KO"; PROB=$((PROB+1))
else printf '  %-26s %-16s %s\n' "asp administratif" "(indetermine)" "$WARN"; fi
chk "point-code MSC"        "$m_pc"  "$EXP_MSC"
chk "point-code BSC"        "$b_pc"  "$EXP_BSC"

# ---- services ---------------------------------------------------------------
head "SERVICES (systemd)"
for s in osmo-stp osmo-msc osmo-bsc osmo-hlr; do
  st="$(systemctl is-active "$s" 2>/dev/null)"
  m="$OK"; [ "$st" = active ] || { m="$KO"; PROB=$((PROB+1)); }
  printf '  %-14s %-10s %s\n' "$s" "${st:-inconnu}" "$m"
done

# ---- VTY : ce que le demon fait tourner reellement --------------------------
vty(){ # commands...
  { printf 'enable\n'; for c in "$@"; do printf '%s\n' "$c"; done; sleep 0.5; } \
    | timeout 6 nc -q1 127.0.0.1 "$VTY_PORT" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
}
head "VTY osmo-stp (etat RUNTIME, port $VTY_PORT)"
ASP="$(vty 'show cs7 instance 0 asp')"
if [ -z "$ASP" ]; then
  printf '  %s VTY injoignable -- osmo-stp est-il lance ?\n' "$KO"; PROB=$((PROB+1))
  r_state=""; r_rem=""
else
  line="$(printf '%s\n' "$ASP" | grep -E 'asp-to-inter' | head -1)"
  r_state="$(printf '%s' "$line" | awk '{print $3}')"
  r_rem="$(printf '%s' "$line" | awk '{print $8}')"
  printf '  asp-to-inter  etat=%s%s%s  remote=%s\n' "$C" "${r_state:-absent}" "$Z" "${r_rem:-?}"
  nact="$(printf '%s\n' "$ASP" | grep -c 'ASP_ACTIVE')"
  printf '  ASP locaux ACTIVE (MSC/HLR internes) : %s\n' "$nact"
  # derive interne : fichier corrige mais demon pas recharge
  if [ -n "$r_rem" ] && [ -n "$f_rip" ] && [ "$r_rem" != "${f_rip}:${M3UA_PORT}" ] && [ "${r_rem%:*}" != "$f_rip" ]; then
    printf '  %s DERIVE : disque remote=%s mais demon tourne remote=%s -> reload/restart requis\n' "$WARN" "$f_rip" "$r_rem"
    PROB=$((PROB+1))
  fi
fi

# ---- transport --------------------------------------------------------------
head "TRANSPORT vers inter-STP ${HUB_IP:-?}:$M3UA_PORT"
if [ -n "$HUB_IP" ]; then
  if ping -c1 -W2 "$HUB_IP" >/dev/null 2>&1; then printf '  %s ping %s\n' "$OK" "$HUB_IP"
  else printf '  %s ping %s injoignable\n' "$KO" "$HUB_IP"; PROB=$((PROB+1)); fi
fi
estab="$(ss -Sanp 2>/dev/null | grep -E "${HUB_IP//./\\.}:$M3UA_PORT" | grep -i estab)"
if [ -n "$estab" ]; then printf '  %s association SCTP ETABLIE\n' "$OK"; printf '    %s\n' "$estab"
else printf '  %s aucune association SCTP etablie vers le hub\n' "$KO"; fi

# ---- verdict ----------------------------------------------------------------
head "VERDICT"
if [ "$r_state" = "ASP_ACTIVE" ] && [ -n "$estab" ]; then
  printf '  %sINTERCO SS7 : UP%s  (asp-to-inter ACTIVE, SCTP etabli)\n' "$G$B" "$Z"
else
  printf '  %sINTERCO SS7 : DOWN%s\n' "$R$B" "$Z"
  echo   "  causes probables (par ordre) :"
  [ "$f_shut" = yes ] && echo "    - asp-to-inter en 'shutdown' dans la conf"
  { [ -n "$EXP_PC" ] && [ "$f_pc" != "$EXP_PC" ]; } && echo "    - point-code STP disque ($f_pc) != attendu ($EXP_PC)"
  { [ -n "$HUB_IP" ] && [ "$f_rip" != "$HUB_IP" ]; } && echo "    - remote-ip disque ($f_rip) != hub ($HUB_IP)"
  { [ -n "$r_rem" ] && [ "${r_rem%:*}" != "$f_rip" ]; } && echo "    - demon tourne une conf obsolete -> systemctl restart osmo-stp osmo-msc osmo-bsc"
  [ -z "$estab" ] && echo "    - pas de SCTP etabli (hub down, pare-feu, ou asp pas monte)"
  echo "  (rappel : ce script ne redemarre rien)"
fi
hr
exit 0
