#!/bin/bash
# =============================================================================
# checks/annuaire.sh -- l'annuaire du banc, confronte a ce que le reseau en sait
#
# Le banc ne rend que des nombres : 001020002000001, 20001, 1.21.2, rctx 2150.
# Chacun est juste, aucun ne se retient, et il faut trois fenetres pour savoir
# si l'abonne 20001 existe, s'il a une cle, s'il est attache, et sur quelle
# machine. Ce script rassemble les quatre sources en une page :
#
#   data/*.txt  -> annuaire.csv    l'etat civil invente au lancement
#   hlr.db                          l'abonne existe-t-il, a-t-il une cle
#   VTY osmo-msc                    est-il ATTACHE, maintenant
#   annuaire-ss7.csv + VTY stp      quelle machine le sert, et sous quel PC
#
# CE QU'IL MONTRE
#   1. les abonnes : IMSI, MSISDN, nom, operateur, pays, cle, attachement
#   2. les incoherences : une fiche sans abonne, un abonne sans fiche, un
#      abonne sans cle - ce dernier etant le plus couteux, parce qu'il n'a
#      l'air de rien : osmo-msc le trouve, reclame ses vecteurs, n'obtient
#      rien, et rejette le mobile en accusant la carte SIM
#   3. l'annuaire SS7 : quel point code, quel routing context, quel hub, et
#      ce que le STP en dit en ce moment
#
# Ne modifie rien. Ne redemarre rien. Lecture seule.
#
# Usage : ./checks/annuaire.sh [--op N] [--ss7] [--no-color]
#   --op N      un seul operateur (defaut : tous ceux qui tournent)
#   --ss7       la section SS7 seule
#   --abo       la section abonnes seule
# =============================================================================
set -uo pipefail

ONLY_OP=""; WANT_ABO=1; WANT_SS7=1; USE_COLOR=1

# Les fiches ne sont pas au meme endroit selon d'ou l'on regarde : start.sh les
# ecrit sur l'HOTE dans /var/tmp, et en pose une copie dans /etc/osmocom de
# chaque conteneur (elle voyage avec la pile). Lance depuis un conteneur, ce
# script ne trouvait donc rien et annoncait "pas de fiches" sur un banc qui en
# avait. On prend la premiere qui existe.
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

# ── Ou tourne-t-on ? ─────────────────────────────────────────────────────────
# Sur l'hote on interroge les conteneurs ; dans un conteneur, soi-meme. Le
# meme script sert donc des deux cotes, et c'est voulu : un diagnostic qu'on ne
# peut lancer que d'un seul endroit ne sert qu'a la moitie des pannes.
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

# ── Les fiches, lues une fois ───────────────────────────────────────────────
# Absent n'est pas une erreur : l'annuaire nait au lancement de start.sh, et un
# banc monte a la main n'en a pas. On le dit et on continue - la partie HLR et
# la partie SS7 restent lisibles sans lui.
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

# ═══════════════════════════ 1. LES ABONNES ═════════════════════════════════
if [ "$WANT_ABO" = 1 ]; then
for op in $OPS; do
  C_NAME="$(ct "$op")"
  head "ABONNES - operateur ${op} (${C_NAME})"

  # Le HLR fait foi sur l'existence et sur la cle. On lit la base plutot que le
  # VTY : "subscriber show" ne parle que d'un abonne a la fois, et il en faut
  # la liste. La colonne cle vient de auc_2g - un abonne sans ligne la-dedans
  # ne peut pas s'authentifier, quoi qu'en dise sa fiche.
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

  # Qui est ATTACHE, maintenant. C'est le cache d'abonnes du VLR : il ne
  # contient que ce qui s'est presente au reseau. Un abonne provisionne mais
  # jamais vu n'y figure pas - et c'est exactement l'information qui manque
  # quand "tout a l'air bon" dans le HLR.
  # "show subscriber all" n'existe PAS sur osmo-msc (il repond "% Unknown
  # command." et la sortie, non vide, passait pour une liste : tout le monde
  # ressortait non attache). Les formes valides sont : cache, imsi, msisdn, tmsi.
  att="$(IN "$C_NAME" 'exec 9<>/dev/tcp/127.0.0.1/4254 2>/dev/null || exit 0
      { printf "enable\n"; printf "show subscriber cache\n"; sleep 0.5; } >&9
      timeout 3 cat <&9' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
  case "$att" in *"Unknown command"*) att="" ;; esac

  # Les codes ANSI comptent dans la largeur d'un %-Ns : on remplit d'abord le
  # texte nu, on colore ensuite. Sans cela chaque cellule coloree decale la
  # ligne d'une dizaine de caracteres et la table devient illisible.
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
    printf '  %s %s abonne(s) sans fiche : le HLR les connait, l annuaire non (banc relance sans start.sh ?)\n' "$WARN" "$n_sans_fiche"

  # Le mobile presente-t-il un IMSI que le HLR connait ? C'est la question que
  # personne ne pose, et la reponse est non plus souvent qu'on ne croit : les
  # deux valeurs sont ecrites par deux scripts differents.
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

# ═══════════════════════════ 2. L ANNUAIRE SS7 ══════════════════════════════
if [ "$WANT_SS7" = 1 ] && [ -r "$ANNU_SS7" ]; then
  head "ANNUAIRE SS7"
  printf '  %-5s %-16s %-12s %-9s %-9s %-9s %-6s %s\n' \
         NOEUD OPERATEUR PAYS PC_MSC PC_STP PC_BSC RCTX HUB
  awk -F';' 'NR>1 {printf "  %-5s %-16s %-12s %-9s %-9s %-9s %-6s %s\n", $1,$2,$3,$6,$7,$8,$12,$13}' "$ANNU_SS7"

  # Et ce que le STP en dit MAINTENANT. Un point code ecrit dans un fichier ne
  # prouve rien : c'est l'AS actif qui prouve que la machine parle.
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
