#!/bin/bash
# =============================================================================
# checks/check_all.sh -- lance TOUS les checks du banc, dans le bon ordre,
#                        et rend UN verdict.
#
# POURQUOI CE FICHIER EXISTE
# --------------------------
# checks/ contient huit scripts qui ne se recouvrent pas : global_check voit
# les demons, ss7_check voit la signalisation, diag-* voit l'interco d'un cote
# ou de l'autre, wan_ss7_check voit ce qui passe entre machines, annuaire voit
# les abonnes. Pris un par un ils sont justes ; pris a la main ils sont
# oublies, lances dans le desordre, ou lances sur le mauvais noeud - et le
# diagnostic finit par dependre de qui tape la commande.
#
# Ce script tape la commande. Il choisit CE QUI A UN SENS ICI (le mode et le
# role decident), execute dans l'ordre du plus general au plus fin, garde tout
# dans un journal, et termine par un tableau : une ligne par check, un verdict,
# un code de retour.
#
# CE QU'IL NE FAIT PAS
#   - il ne modifie rien, ne redemarre rien : tous les checks appeles sont en
#     lecture seule (seul --dump touche au niveau de log des demons, et il est
#     donc optionnel, jamais par defaut) ;
#   - il ne reimplemente aucun test : chaque verdict vient du script d'origine,
#     jamais d'une seconde lecture des VTY faite ici.
#
# CHOIX DES CHECKS - CE QUI EST LANCE, ET QUAND
#   mode           tous les checks respectent --docker/--native ; l'option est
#                  transmise telle quelle, donc un seul monde est regarde.
#   diag-interstp  seulement si un inter-STP est INTERROGEABLE ICI (conteneur
#                  osmo-inter-stp, ou OSMO_ROLE=interstp) : sur un noeud
#                  operateur le hub est une autre machine, son VTY n'ecoute que
#                  sur sa boucle locale, et le lancer produirait un "hub muet"
#                  qui se lit comme une panne.
#   diag-stp-oper. l'exact symetrique : seulement quand ce noeud n'est PAS le
#                  hub et qu'il a un /etc/osmo-role (donc un montage WAN).
#   wan_ss7_check  seulement si /etc/osmo-wan.conf existe : sans plan WAN il
#                  n'y a pas de "entre noeuds" a verifier.
#   annuaire       seulement si les fiches existent (var/tmp ou /etc/osmocom).
#   dump + resume  jamais par defaut : vty-debug-dump.sh passe les demons en
#                  DEBUG et ecrit plusieurs Mo. --dump les active tous les deux,
#                  le resume relisant le dump que le premier vient d'ecrire.
#
# COMMENT EST RENDU LE VERDICT D'UN CHECK
# Les scripts de checks/ n'ont pas tous la meme convention, et on ne la leur
# impose pas apres coup :
#   rc    global_check.sh / ss7_check.sh rendent le NOMBRE d'echecs ;
#   rcb   wan_ss7_check.sh rend 0 ou 1 ;
#   motif diag-*.sh et annuaire.sh rendent toujours 0 - leur verdict est dans
#         leur derniere section ("INTERCO SS7 : DOWN"), on l'y lit, sur la
#         sortie DEBARRASSEE des couleurs.
#
# Usage :
#   sudo ./checks/check_all.sh [options]
#     --quick|-q        transmis a global_check / ss7_check (passage rapide)
#     --verbose|-v      transmis aux checks qui le comprennent
#     --op=N            limiter a un operateur (global_check, annuaire)
#     --docker|--native forcer le monde ; sans option, detection automatique
#     --dump            ajouter vty-debug-dump.sh puis operator_summary.sh
#     --only=a,b        ne lancer que ces checks (voir --list)
#     --skip=a,b        lancer tous les checks sauf ceux-la
#     --list            afficher les checks, leur cle et leur applicabilite
#     --out FICHIER     journal complet (defaut /tmp/osmo-check-all-<date>.txt)
#     --no-log          ne rien ecrire sur disque
#     --timeout N       delai maximum par check, en secondes (defaut 300)
#     --no-color        sortie sans couleur
#
# Code de retour : nombre de checks en echec (0 = tout va bien), 125 au plus.
# =============================================================================

set -u

# ── Bibliotheque commune (detection docker/natif, inventaire, VTY) ────────────
# Chemin RELATIF a CE fichier : le depot vit en /home/.../osmo_egprs pendant le
# developpement et en /opt/GSM/osmo_egprs sur l'ISO ; un chemin absolu casserait
# l'un des deux.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/GSM/osmo_egprs/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Options ───────────────────────────────────────────────────────────────────
QUICK=0; VERBOSE=0; SPECIFIC_OP=""; WANT_DUMP=0
ONLY=""; SKIP_LIST=""; LIST_ONLY=0
LOGFILE=""; NO_LOG=0; TIMEOUT=300; USE_COLOR=1
MODE_FORCED=0; MODE_OPT=""

# OSMO_MODE pose dans l'environnement est deja une forme de forcage
# ("OSMO_MODE=native ./checks/check_all.sh") : on le signale comme tel, et on
# le transmet aux fils sous forme d'option pour qu'aucun d'eux ne redetecte.
case "${OSMO_MODE:-}" in docker|native) MODE_FORCED=1 ;; esac

while [ $# -gt 0 ]; do
    case "$1" in
        --quick|-q)   QUICK=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --op)         SPECIFIC_OP="${2:-}"; shift ;;
        --op=*)       SPECIFIC_OP="${1#*=}" ;;
        --dump)       WANT_DUMP=1 ;;
        --only)       ONLY="${2:-}"; shift ;;
        --only=*)     ONLY="${1#*=}" ;;
        --skip)       SKIP_LIST="${2:-}"; shift ;;
        --skip=*)     SKIP_LIST="${1#*=}" ;;
        --list)       LIST_ONLY=1 ;;
        --out)        LOGFILE="${2:-}"; shift ;;
        --out=*)      LOGFILE="${1#*=}" ;;
        --no-log)     NO_LOG=1 ;;
        --timeout)    TIMEOUT="${2:-}"; shift ;;
        --timeout=*)  TIMEOUT="${1#*=}" ;;
        --no-color)   USE_COLOR=0 ;;
        --docker|--native|--mode=*)
            osmo_mode_force "$1" || { echo "mode inconnu : $1" >&2; exit 1; }
            MODE_FORCED=1 ;;
        -h|--help)    sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "option inconnue : $1 (voir --help)" >&2; exit 1 ;;
    esac
    shift
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout attend un entier" >&2; exit 1 ;; esac

# ── Couleurs ──────────────────────────────────────────────────────────────────
if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
    GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m';   BOLD=$'\033[1m';    DIM=$'\033[2m'; NC=$'\033[0m'
else
    GREEN=; CYAN=; YELLOW=; RED=; BOLD=; DIM=; NC=
fi

banner() {
    echo ""
    echo "${BOLD}$*${NC}"
    printf '%s\n' "$(printf '─%.0s' $(seq 1 74))"
}

# ── Mode, role, inventaire ────────────────────────────────────────────────────
MODE="$(osmo_mode)"
[ "$MODE_FORCED" -eq 1 ] && MODE_SRC="force" || MODE_SRC="detecte"

# L'option de mode transmise aux fils. On la transmet TOUJOURS, meme quand elle
# a ete detectee ici : sans elle chaque fils refait la detection, et deux
# detections successives sur un hote qui a docker installe mais fait tourner le
# lab en natif peuvent ne pas tomber d'accord. Un rapport dont les moities
# regardent deux mondes differents n'est pas un rapport.
MODE_OPT="--$MODE"

HUB_LOCAL=0; HUB_LABEL=""
if HUB_LABEL="$(osmo_hub 2>/dev/null)"; then HUB_LOCAL=1; else HUB_LABEL=""; fi

ROLE=""
[ -r /etc/osmo-role ] && \
    ROLE="$(awk -F= '/^OSMO_ROLE=/ { gsub(/[ \r\t]/, "", $2); print $2 }' /etc/osmo-role 2>/dev/null | tail -1)"

OPS="$(osmo_ops 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
N_OPS="$(printf '%s\n' "$OPS" | wc -w | tr -d ' ')"

# Les fiches d'abonnes ne sont pas au meme endroit selon d'ou l'on regarde :
# start.sh les ecrit sur l'HOTE dans /var/tmp et en pose une copie dans
# /etc/osmocom de chaque conteneur. Meme regle que checks/annuaire.sh.
ANNU_FOUND=0
for f in "${OSMO_ANNUAIRE:-}" /var/tmp/osmo-annuaire.csv /etc/osmocom/annuaire.csv; do
    [ -n "$f" ] && [ -r "$f" ] && { ANNU_FOUND=1; break; }
done

# ── Journal ───────────────────────────────────────────────────────────────────
# Le journal recoit la sortie SANS les couleurs : un rapport qu'on envoie par
# mail ou qu'on relit six mois plus tard ne doit pas etre truffe d'echappements.
# Le terminal, lui, garde les siennes.
STRIP_ANSI='s/\x1b\[[0-9;]*[a-zA-Z]//g'
if [ "$NO_LOG" -eq 0 ]; then
    [ -n "$LOGFILE" ] || LOGFILE="/tmp/osmo-check-all-$(date '+%Y%m%d-%H%M%S').txt"
    if : >"$LOGFILE" 2>/dev/null; then :; else
        echo "${YELLOW}journal impossible a ecrire (${LOGFILE}) - on continue sans${NC}" >&2
        NO_LOG=1; LOGFILE=""
    fi
else
    LOGFILE=""
fi
journal() { [ -n "$LOGFILE" ] && printf '%s\n' "$*" | sed "$STRIP_ANSI" >>"$LOGFILE"; return 0; }

# ── Le catalogue ──────────────────────────────────────────────────────────────
# Un enregistrement par check :  cle | script | verdict | description
#   verdict = rc     le script rend le NOMBRE d'echecs (global_check, ss7_check)
#             rcb    le script rend 0 ou non-0 (wan_ss7_check)
#             motif  le script rend toujours 0 : le verdict se lit dans sa
#                    sortie, motif donne apres ':' (diag-*, annuaire)
#             info   sortie informative, jamais en echec (dump, resume)
# L'ordre est celui du diagnostic : d'abord ce qui tourne, puis la
# signalisation locale, puis l'interco, puis le WAN, puis les abonnes.
CATALOGUE=(
  "global|global_check.sh|rc|etat de tous les demons (STP, HLR, MSC, BSC, BTS, PCU, SGSN, GGSN, MGW)"
  "ss7|ss7_check.sh|rc|signalisation SS7 : AS, ASP, routes, catch-all vers l inter-STP"
  "interstp|diag-interstp.sh|motif:INTERCO SS7 : (DOWN|PARTIELLE)|indeterminable|interco vue du HUB : qui est attache, qui manque"
  "operator|diag-stp-operator.sh|motif:INTERCO SS7 : DOWN|interco vue du NOEUD : conf disque vs demon, SCTP vers le hub"
  "wan|wan_ss7_check.sh|rcb|entre noeuds : SIP/RTP, relais SMS, point codes, iptables"
  "annuaire|annuaire.sh|motif:\\[FAIL\\]|abonnes : IMSI, MSISDN, cles Ki, attachement, annuaire SS7"
  "dump|vty-debug-dump.sh|info|dump DEBUG de tous les VTY (--dump seulement)"
  "resume|operator_summary.sh|info|resume par operateur, lu sur le dump (--dump seulement)"
)

champ() { printf '%s' "$1" | cut -d'|' -f"$2"; }
# Le motif peut contenir des '|' (alternative regex) : il occupe donc tout ce
# qui est entre le 3e champ et le DERNIER, la description etant le dernier.
verdict_de()     { printf '%s' "${1#*|*|}" | sed 's/|[^|]*$//'; }
description_de() { printf '%s' "$1" | awk -F'|' '{print $NF}'; }

# applicable <cle> - ce check a-t-il un sens ici ? Ecrit la raison si non.
applicable() {
    case "$1" in
        global|ss7) return 0 ;;
        interstp)
            [ "$HUB_LOCAL" -eq 1 ] && return 0
            printf 'aucun inter-STP interrogeable ici (%s)' "$(osmo_hub_hint 2>/dev/null || echo 'hub distant ou absent')"
            return 1 ;;
        operator)
            [ "$HUB_LOCAL" -eq 1 ] && { printf 'ce noeud EST le hub - voir le check interstp'; return 1; }
            [ -r /etc/osmo-role ] && return 0
            printf '/etc/osmo-role absent : pas de montage WAN sur ce noeud'
            return 1 ;;
        wan)
            [ -r /etc/osmo-wan.conf ] && return 0
            printf '/etc/osmo-wan.conf absent : aucun plan WAN a verifier'
            return 1 ;;
        annuaire)
            [ "$ANNU_FOUND" -eq 1 ] && return 0
            printf 'aucune fiche (osmo-annuaire.csv) : banc lance sans annuaire'
            return 1 ;;
        dump|resume)
            [ "$WANT_DUMP" -eq 1 ] && return 0
            printf 'non demande (--dump)'
            return 1 ;;
    esac
    return 0
}

# args_de <cle> - les options a passer, chaque script n'ayant pas les memes.
args_de() {
    local a=("$MODE_OPT")
    case "$1" in
        global)
            [ "$QUICK" -eq 1 ]        && a+=(--quick)
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose)
            [ -n "$SPECIFIC_OP" ]     && a+=("--op=$SPECIFIC_OP") ;;
        ss7)
            [ "$QUICK" -eq 1 ]        && a+=(--quick)
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose) ;;
        interstp)
            # diag-interstp.sh et diag-stp-operator.sh sont anterieurs a
            # _mode.sh : ils lisent /etc/osmo-role et les VTY locaux, et ne
            # connaissent ni --docker ni --native. Leur passer MODE_OPT les
            # ferait sortir en "option inconnue".
            a=()
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        operator)
            a=()
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        wan)
            a=()
            [ "$VERBOSE" -eq 1 ]      && a+=(--verbose) ;;
        annuaire)
            a=()
            [ -n "$SPECIFIC_OP" ]     && a+=(--op "$SPECIFIC_OP")
            [ "$USE_COLOR" -eq 0 ]    && a+=(--no-color) ;;
        dump)
            a+=(--out "$DUMP_OUT") ;;
        resume)
            a+=("--dump=$DUMP_OUT") ;;
    esac
    printf '%s\n' "${a[@]:-}"
}

# ── --list : dire ce qui serait fait, sans rien faire ─────────────────────────
if [ "$LIST_ONLY" -eq 1 ]; then
    echo "${BOLD}checks disponibles${NC}   (mode ${MODE}, ${MODE_SRC})"
    echo ""
    printf '  %-10s %-24s %s\n' CLE SCRIPT ETAT
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    for e in "${CATALOGUE[@]}"; do
        k="$(champ "$e" 1)"; s="$(champ "$e" 2)"
        if raison="$(applicable "$k")"; then
            printf '  %-10s %-24s %slance%s\n' "$k" "$s" "$GREEN" "$NC"
        else
            printf '  %-10s %-24s %signore%s - %s\n' "$k" "$s" "$DIM" "$NC" "$raison"
        fi
        printf '  %-10s %-24s %s%s%s\n' "" "" "$DIM" "$(description_de "$e")" "$NC"
    done
    echo ""
    exit 0
fi

# ── En-tete ───────────────────────────────────────────────────────────────────
DUMP_OUT="/tmp/osmo-check-all-dump-$(date '+%Y%m%d-%H%M%S').txt"
DATE_DEB="$(date '+%Y-%m-%d %H:%M:%S')"

en_tete() {
    echo "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║   osmo_egprs - CHECK COMPLET du banc                                     ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo "${NC}"
    printf '  date       : %s\n' "$DATE_DEB"
    printf '  machine    : %s\n' "$(hostname 2>/dev/null || echo '?')"
    printf '  mode       : %s%s%s (%s)\n' "$CYAN" "$MODE" "$NC" "$MODE_SRC"
    printf '  operateurs : %s   (%s)\n' "${N_OPS:-0}" "${OPS:-aucun}"
    if [ "$HUB_LOCAL" -eq 1 ]; then
        printf '  inter-STP  : %s%s%s (interrogeable ici)\n' "$GREEN" "$HUB_LABEL" "$NC"
    else
        printf '  inter-STP  : %s\n' "$(osmo_hub_hint 2>/dev/null || echo 'non interrogeable ici')"
    fi
    [ -n "$ROLE" ] && printf '  role       : %s\n' "$ROLE"
    [ -n "$LOGFILE" ] && printf '  journal    : %s\n' "$LOGFILE"
    # Les VTY Osmocom ecoutent sur la boucle locale et docker exige le socket :
    # sans droits, la moitie des checks rendront "muet" pour une raison qui n'a
    # rien a voir avec le reseau. On le dit AVANT, pas apres.
    [ "$(id -u)" -ne 0 ] && printf '  %s! lance sans root : certains checks seront incomplets (sudo recommande)%s\n' "$YELLOW" "$NC"
}
en_tete
en_tete_txt="$(en_tete 2>&1)"
journal "$en_tete_txt"

# ── Execution ─────────────────────────────────────────────────────────────────
NB_OK=0; NB_KO=0; NB_IGN=0
RES_CLE=(); RES_ETAT=(); RES_RC=(); RES_DUREE=(); RES_NOTE=()

dans_liste() {   # dans_liste <aiguille> <a,b,c>
    local x; local IFS=','
    for x in $2; do [ "$x" = "$1" ] && return 0; done
    return 1
}

enregistre() {   # enregistre <cle> <etat> <rc> <duree> <note>
    RES_CLE+=("$1"); RES_ETAT+=("$2"); RES_RC+=("$3"); RES_DUREE+=("$4"); RES_NOTE+=("${5:-}")
}

for entree in "${CATALOGUE[@]}"; do
    cle="$(champ "$entree" 1)"
    script="$(champ "$entree" 2)"
    verdict="$(verdict_de "$entree")"
    desc="$(description_de "$entree")"
    chemin="$_here/$script"

    # --only / --skip d'abord : ce que l'utilisateur a exclu n'est meme pas
    # evalue, et n'apparait pas comme "ignore par le banc" - la distinction
    # compte, l'un est un choix, l'autre un constat.
    [ -n "$ONLY" ]      && { dans_liste "$cle" "$ONLY"      || continue; }
    [ -n "$SKIP_LIST" ] && { dans_liste "$cle" "$SKIP_LIST" && continue; }

    if ! raison="$(applicable "$cle")"; then
        banner "[$cle] $script"
        echo "  ${DIM}ignore${NC} - $raison"
        journal ""; journal "== [$cle] $script =="; journal "  ignore - $raison"
        NB_IGN=$((NB_IGN+1)); enregistre "$cle" IGNORE "-" "-" "$raison"
        continue
    fi

    if [ ! -x "$chemin" ]; then
        banner "[$cle] $script"
        echo "  ${RED}absent ou non executable${NC} : $chemin"
        journal ""; journal "== [$cle] $script =="; journal "  absent : $chemin"
        NB_KO=$((NB_KO+1)); enregistre "$cle" ABSENT "-" "-" "$chemin introuvable"
        continue
    fi

    mapfile -t opts < <(args_de "$cle")
    # args_de rend une ligne vide quand il n'y a aucune option : le tableau
    # contiendrait alors un argument vide, que certains scripts refusent.
    [ "${#opts[@]}" -eq 1 ] && [ -z "${opts[0]}" ] && opts=()

    banner "[$cle] $script ${DIM}${opts[*]:-}${NC}"
    echo "  ${DIM}${desc}${NC}"
    echo ""
    journal ""
    journal "════════════════════════════════════════════════════════════════════════"
    journal "== [$cle] $script ${opts[*]:-}"
    journal "   $desc"
    journal "════════════════════════════════════════════════════════════════════════"

    tmp="$(mktemp "${TMPDIR:-/tmp}/osmo-check-$cle-XXXXXX")"
    debut=$SECONDS
    # timeout : un VTY qui ne repond jamais (demon fige, docker exec suspendu)
    # bloquerait tout le rapport. On coupe, on le dit, on continue.
    # PIPESTATUS et non "set -o pipefail" : sous pipefail un "grep -q" en fin
    # de tube, dans l'un des fils, rendrait 141 (voir checks/_mode.sh).
    timeout "$TIMEOUT" "$chemin" "${opts[@]}" 2>&1 | tee "$tmp"
    rc="${PIPESTATUS[0]}"
    duree=$((SECONDS - debut))

    [ -n "$LOGFILE" ] && sed "$STRIP_ANSI" "$tmp" >>"$LOGFILE"
    propre="$(sed "$STRIP_ANSI" "$tmp")"
    rm -f "$tmp"

    etat=OK; note=""
    if [ "$rc" -eq 124 ]; then
        etat=TIMEOUT; note="coupe apres ${TIMEOUT}s"
    else
        case "$verdict" in
            rc)
                # global_check.sh et ss7_check.sh rendent le nombre d'echecs.
                if [ "$rc" -ne 0 ]; then etat=ECHEC; note="$rc test(s) en echec"; fi ;;
            rcb)
                if [ "$rc" -ne 0 ]; then etat=ECHEC; note="code de retour $rc"; fi ;;
            motif:*)
                # Le script rend toujours 0 : son verdict est dans sa sortie.
                # On retient la LIGNE entiere, pas le motif : "[FAIL]" tout seul
                # dans le bilan n'apprend rien, "[FAIL] operateur 1 : VTY STP
                # (4239) muet" dispense d'aller rouvrir le journal.
                m="${verdict#motif:}"
                nb="$(printf '%s\n' "$propre" | grep -Ec -- "$m")"
                if [ "${nb:-0}" -gt 0 ]; then
                    etat=ECHEC
                    note="$(printf '%s\n' "$propre" | grep -Em1 -- "$m" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-60)"
                    [ "$nb" -gt 1 ] && note="$note (+$((nb-1)))"
                fi ;;
            info)
                etat=INFO ;;
        esac
    fi

    case "$etat" in
        OK)      NB_OK=$((NB_OK+1));  echo ""; echo "  ${GREEN}→ $cle : OK${NC} (${duree}s)" ;;
        INFO)    NB_OK=$((NB_OK+1));  echo ""; echo "  ${CYAN}→ $cle : termine${NC} (${duree}s)" ;;
        TIMEOUT) NB_KO=$((NB_KO+1));  echo ""; echo "  ${RED}→ $cle : TIMEOUT${NC} - $note" ;;
        *)       NB_KO=$((NB_KO+1));  echo ""; echo "  ${RED}→ $cle : PROBLEMES${NC} - $note (${duree}s)" ;;
    esac
    journal "  → $cle : $etat ${note} (${duree}s, rc=$rc)"

    enregistre "$cle" "$etat" "$rc" "${duree}s" "$note"
done

# ── Bilan ─────────────────────────────────────────────────────────────────────
bilan() {
    echo ""
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    echo "  ${BOLD}BILAN - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    printf '  %-10s %-9s %-6s %-7s %s\n' CHECK ETAT RC DUREE COMMENTAIRE
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    local i coul
    for i in "${!RES_CLE[@]}"; do
        case "${RES_ETAT[$i]}" in
            OK)                coul="$GREEN" ;;
            INFO)              coul="$CYAN" ;;
            IGNORE)            coul="$DIM" ;;
            ECHEC|TIMEOUT|ABSENT) coul="$RED" ;;
            *)                 coul="$YELLOW" ;;
        esac
        printf '  %-10s %s%-9s%s %-6s %-7s %s\n' \
            "${RES_CLE[$i]}" "$coul" "${RES_ETAT[$i]}" "$NC" \
            "${RES_RC[$i]}" "${RES_DUREE[$i]}" "${RES_NOTE[$i]}"
    done
    printf '  %s\n' "$(printf '─%.0s' $(seq 1 72))"
    printf '  %s%d ok%s   %s%d en echec%s   %s%d ignore%s   (mode %s)\n' \
        "$GREEN" "$NB_OK" "$NC" "$RED" "$NB_KO" "$NC" "$DIM" "$NB_IGN" "$NC" "$MODE"
    echo ""
    if [ "$NB_KO" -eq 0 ] && [ "$NB_OK" -eq 0 ]; then
        # Tout ignore ou tout exclu : dire "BANC OK" ici serait un mensonge par
        # omission - rien n'a ete regarde.
        echo "  ${YELLOW}${BOLD}AUCUN CHECK N A TOURNE${NC} - tout etait ignore ou exclu (--list pour savoir pourquoi)"
    elif [ "$NB_KO" -eq 0 ]; then
        echo "  ${GREEN}${BOLD}BANC OK${NC} - ${NB_OK} check(s) passes, aucun en echec"
    else
        echo "  ${RED}${BOLD}PROBLEMES DETECTES${NC} - ${NB_KO} check(s) en echec"
        echo ""
        echo "  ${DIM}rejouer un seul check en detail :${NC}"
        for i in "${!RES_CLE[@]}"; do
            case "${RES_ETAT[$i]}" in
                ECHEC|TIMEOUT) echo "    ./checks/check_all.sh --only=${RES_CLE[$i]} --verbose" ;;
            esac
        done
    fi
    [ -n "$LOGFILE" ] && { echo ""; echo "  ${CYAN}journal complet :${NC} $LOGFILE"; }
    [ "$WANT_DUMP" -eq 1 ] && [ -s "$DUMP_OUT" ] && echo "  ${CYAN}dump VTY        :${NC} $DUMP_OUT"
    printf '%s\n' "$(printf '═%.0s' $(seq 1 74))"
    echo ""
}
bilan
journal "$(bilan)"

# Meme convention que global_check.sh / ss7_check.sh : le code de retour est le
# nombre d'echecs. Plafonne a 125 - au-dela, un code de sortie shell change de
# sens (126, 127 et 128+n sont reserves).
[ "$NB_KO" -gt 125 ] && NB_KO=125
exit "$NB_KO"
