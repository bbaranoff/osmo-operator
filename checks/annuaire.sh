#!/bin/bash
# =============================================================================
# checks/annuaire.sh -- bench subscriber directory, cross-checked with the network
#
# Gathers in one page what is otherwise spread over several tools: does
# subscriber 20001 exist, does it have a key, is it attached, and which
# machine serves it. Sources:
#
#   data/*.txt  -> annuaire.csv    identities generated at startup
#   hlr.db                          does the subscriber exist, does it have a key
#   osmo-msc VTY                    is it ATTACHED right now
#   annuaire-ss7.csv + STP VTY      which machine serves it, under which PC
#
# OUTPUT
#   1. subscribers: IMSI, MSISDN, name, operator, country, key, attach state
#   2. inconsistencies: a record without subscriber, a subscriber without
#      record, a subscriber without key - the latter makes osmo-msc request
#      auth vectors, get none, and reject the phone as if the SIM were wrong
#   3. SS7 directory: point code, routing context, hub, and the current
#      STP view
#
# Read-only: modifies nothing, restarts nothing.
#
# Usage: ./checks/annuaire.sh [--op N] [--ss7] [--abo] [--no-color]
#   --op N      a single operator (default: all running ones)
#   --ss7       SS7 section only
#   --abo       subscriber section only
#   --no-color  plain output
# Env: OSMO_ANNUAIRE, OSMO_ANNUAIRE_SS7 override the directory CSV paths.
# =============================================================================
set -uo pipefail

ONLY_OP=""; WANT_ABO=1; WANT_SS7=1; USE_COLOR=1

# Directory files: start-docker.sh writes them on the HOST in /var/tmp and
# copies them into /etc/osmocom of each container. Use the first one found.
_premier(){ for f in "$@"; do [ -r "$f" ] && { printf '%s' "$f"; return 0; }; done; printf '%s' "$1"; }
ANNU="${OSMO_ANNUAIRE:-$(_premier /var/tmp/osmo-annuaire.csv /etc/osmocom/annuaire.csv)}"
ANNU_SS7="${OSMO_ANNUAIRE_SS7:-$(_premier /var/tmp/osmo-annuaire-ss7.csv /etc/osmocom/annuaire-ss7.csv)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --op)       ONLY_OP="${2:-}"; shift ;;
    --op=*)     ONLY_OP="${1#*=}" ;;
    --ss7)      WANT_ABO=0 ;;
    --abo)      WANT_SS7=0 ;;
    --no-color) USE_COLOR=0 ;;
    -h|--help)  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done

if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; C=$'\033[0;36m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'
else G=; R=; Y=; C=; B=; D=; Z=; fi
OK="${G}[ OK ]${Z}"; KO="${R}[FAIL]${Z}"; WARN="${Y}[WARN]${Z}"
head(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }

# ── Where are we running? ──────────────────────────────────────────────────
# On the host, query the containers; inside a container, query itself.
if [ -f /.dockerenv ]; then
  MODE=local
  IN(){ shift; bash -c "$*" 2>/dev/null; }          # $1 ignore
  OPS="${OPERATOR_ID:-1}"
else
  MODE=docker
  IN(){ local c="$1"; shift; docker exec "$c" bash -c "$*" 2>/dev/null; }
  OPS="$(docker ps --format '{{.Names}}' 2>/dev/null | sed -n 's/^osmo-operator-\([0-9]\+\)$/\1/p' | sort -n | tr '\n' ' ')"
fi
[ -n "$ONLY_OP" ] && OPS="$ONLY_OP"
[ -n "${OPS// /}" ] || { printf '%s aucun operateur en service\n' "$KO"; exit 1; }
ct(){ [ "$MODE" = docker ] && echo "osmo-operator-$1" || echo local; }

# ── Directory records, read once ────────────────────────────────────────────
# Missing is not an error: the directory is created by start-docker.sh, and a
# manually set up bench has none. Report it and continue; HLR and SS7 sections
# still work without it.
if [ -r "$ANNU" ]; then
  printf '%s fiches abonnes : %s (%s lignes)\n' "$OK" "$ANNU" "$(( $(wc -l < "$ANNU") - 1 ))"
else
  printf '%s pas de fiches abonnes (%s) - les noms manqueront\n' "$WARN" "$ANNU"
fi
if [ -r "$ANNU_SS7" ]; then
  printf '%s annuaire SS7    : %s (%s lignes)\n' "$OK" "$ANNU_SS7" "$(( $(wc -l < "$ANNU_SS7") - 1 ))"
else
  printf '%s pas d annuaire SS7 (%s)\n' "$WARN" "$ANNU_SS7"
fi

fiche(){   # $1 = msisdn, $2 = champ (7=nom 3=operateur 4=pays 8=adresse 1=imsi)
  [ -r "$ANNU" ] || return 1
  awk -F';' -v n="$1" -v f="$2" 'NR>1 && $2==n {print $f; exit}' "$ANNU"
}

# ═══════════════════════════ 1. SUBSCRIBERS ═════════════════════════════════
if [ "$WANT_ABO" = 1 ]; then
for op in $OPS; do
  C_NAME="$(ct "$op")"
  head "ABONNES - operateur ${op} (${C_NAME})"

  # The HLR is authoritative for existence and key. Read the database rather
  # than the VTY ("subscriber show" handles one subscriber at a time). The key
  # column comes from auc_2g: a subscriber without a row there cannot authenticate.
  rows="$(IN "$C_NAME" 'command -v sqlite3 >/dev/null 2>&1 || exit 0
      sqlite3 -separator "|" /var/lib/osmocom/hlr.db "
        select s.imsi, coalesce(s.msisdn,\"\"),
               case when a.subscriber_id is null then \"non\" else \"oui\" end
        from subscriber s left join auc_2g a on a.subscriber_id = s.id
        order by s.imsi;"')"
  if [ -z "$rows" ]; then
    printf '  %s HLR illisible (sqlite3 absent, ou base vide)\n' "$KO"
    continue
  fi

  # Who is ATTACHED now: the VLR subscriber cache only holds subscribers that
  # have contacted the network; provisioned but never seen ones are absent.
  # osmo-msc has no "show subscriber all"; valid forms are cache, imsi, msisdn, tmsi.
  att="$(IN "$C_NAME" 'exec 9<>/dev/tcp/127.0.0.1/4254 2>/dev/null || exit 0
      { printf "enable\n"; printf "show subscriber cache\n"; sleep 0.5; } >&9
      timeout 3 cat <&9' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
  case "$att" in *"Unknown command"*) att="" ;; esac

  # ANSI codes count in a %-Ns width: pad the plain text first, then colorize,
  # otherwise each colored cell shifts the row.
  col(){ local t; printf -v t '%-*s' "$2" "$1"; printf '%s%s%s' "${3:-}" "$t" "${Z}"; }
  printf '  %-16s %-7s %-4s %-8s %-20s %-15s %s\n' \
         IMSI MSISDN CLE ETAT NOM OPERATEUR PAYS
  n_sans_cle=0; n_sans_fiche=0
  while IFS='|' read -r imsi msisdn cle; do
    [ -n "$imsi" ] || continue
    nom="$(fiche "$msisdn" 7)"; ope="$(fiche "$msisdn" 3)"; pays="$(fiche "$msisdn" 4)"
    if [ -z "$nom" ]; then nom="(pas de fiche)"; n_sans_fiche=$((n_sans_fiche+1)); nom_c="$D"; else nom_c=""; fi
    if printf '%s' "$att" | grep -q "$imsi"; then etat="attache"; etat_c="$G"; else etat="-"; etat_c="$D"; fi
    if [ "$cle" = non ]; then cle="NON"; cle_c="$R"; n_sans_cle=$((n_sans_cle+1)); else cle="oui"; cle_c="$G"; fi
    printf '  %-16s %-7s %s %s %s %-15s %s\n' \
           "$imsi" "${msisdn:-(aucun)}" \
           "$(col "$cle" 4 "$cle_c")" "$(col "$etat" 8 "$etat_c")" \
           "$(col "$nom" 20 "$nom_c")" "${ope:--}" "${pays:--}"
  done <<< "$rows"

  if [ "$n_sans_cle" -gt 0 ]; then
    printf '  %s %s abonne(s) SANS CLE : osmo-msc les trouve, reclame leurs vecteurs\n' "$KO" "$n_sans_cle"
    printf '         d authentification, n obtient rien, et rejette le mobile en\n'
    printf '         accusant la carte SIM. Reprovisionner : %ssubscriber imsi X update aud2g comp128v1 ki ...%s\n' "$C" "$Z"
  fi
  [ "$n_sans_fiche" -gt 0 ] && \
    printf '  %s %s abonne(s) sans fiche : le HLR les connait, l annuaire non (banc relance sans start-docker.sh ?)\n' "$WARN" "$n_sans_fiche"

  # Does the phone present an IMSI known to the HLR? Both values are written
  # by two different scripts and may disagree.
  for f in /root/.osmocom/bb/mobile.cfg /root/.osmocom/bb/mobile_faketrx_bts1.cfg; do
    msi="$(IN "$C_NAME" "awk '\$1==\"imsi\"{print \$2; exit}' $f")"
    [ -n "$msi" ] || continue
    if printf '%s\n' "$rows" | cut -d'|' -f1 | grep -qx "$msi"; then
      printf '  %s %-28s presente %s - connu du HLR\n' "$OK" "$(basename "$f")" "$msi"
    else
      printf '  %s %-28s presente %s - INCONNU du HLR : pas d attachement possible\n' "$KO" "$(basename "$f")" "$msi"
    fi
  done
done
fi

# ═══════════════════════════ 2. SS7 DIRECTORY ═══════════════════════════════
if [ "$WANT_SS7" = 1 ] && [ -r "$ANNU_SS7" ]; then
  head "ANNUAIRE SS7"
  printf '  %-5s %-16s %-12s %-9s %-9s %-9s %-6s %s\n' \
         NOEUD OPERATEUR PAYS PC_MSC PC_STP PC_BSC RCTX HUB
  awk -F';' 'NR>1 {printf "  %-5s %-16s %-12s %-9s %-9s %-9s %-6s %s\n", $1,$2,$3,$6,$7,$8,$12,$13}' "$ANNU_SS7"

  # Current STP view: an active AS proves the machine is actually talking,
  # a point code in a file does not.
  for op in $OPS; do
    C_NAME="$(ct "$op")"
    as_out="$(IN "$C_NAME" 'exec 9<>/dev/tcp/127.0.0.1/4239 2>/dev/null || exit 0
        { printf "enable\n"; printf "show cs7 instance 0 as all\n"; sleep 0.5; } >&9
        timeout 3 cat <&9' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
    if [ -z "$as_out" ]; then
      printf '  %s operateur %s : VTY STP (4239) muet\n' "$KO" "$op"
      continue
    fi
    act="$(printf '%s\n' "$as_out" | grep -c 'AS_ACTIVE' || true)"
    tot="$(printf '%s\n' "$as_out" | grep -cE '^as-' || true)"
    if [ "${act:-0}" -gt 0 ]; then
      printf '  %s operateur %s : %s/%s AS actifs\n' "$OK" "$op" "$act" "$tot"
    else
      printf '  %s operateur %s : aucun AS actif (%s declares)\n' "$KO" "$op" "$tot"
    fi
  done
fi

exit 0
