#!/usr/bin/env bash
# test-console.sh - passe en revue CHAQUE commande de la console SS7 et de ses
# outils, garde un journal par commande, et rend un rapport.
#
#   ./navigation/test-console.sh              tout, y compris le SS7 reel
#   ./navigation/test-console.sh --rapide     sans M3UA/MAP (lab a l'arret)
#   ./navigation/test-console.sh --dir CHEMIN journaux ailleurs
#
# Un test = une commande + un critere de reussite (motif attendu dans la
# sortie, ou code de retour). Chaque commande a SON fichier de journal, nomme
# par le numero et le nom du test : on peut relire exactement ce qui s'est
# passe sans relancer quoi que ce soit.
#
# Codes de sortie : 0 tout passe, sinon le nombre d'echecs.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
CONSOLE="$HERE/ss7-console.py"
DIAG="$HERE/ss7-diag.py"

RAPIDE=0
LOGDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rapide) RAPIDE=1 ;;
        --dir)    LOGDIR="${2:-}"; shift ;;
        --dir=*)  LOGDIR="${1#*=}" ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "argument inconnu : $1" >&2; exit 2 ;;
    esac
    shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
LOGDIR="${LOGDIR:-$HERE/logs/$STAMP}"
mkdir -p "$LOGDIR"
RAPPORT="$LOGDIR/rapport.txt"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
PASS=0; FAIL=0; SKIP=0; NUM=0

dire() { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$RAPPORT"; }

# essai <nom> <motif attendu|-> <commande...>
#   motif "-" : on ne juge que le code de retour.
essai() {
    local nom="$1" motif="$2"; shift 2
    NUM=$((NUM + 1))
    local fichier
    fichier="$(printf '%02d-%s.log' "$NUM" "$nom")"
    local chemin="$LOGDIR/$fichier"
    {
        echo "# test   : $nom"
        echo "# commande : $*"
        echo "# attendu : ${motif}"
        echo "# date   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ---------------------------------------------------------------"
    } > "$chemin"
    local debut fin rc
    debut=$(date +%s)
    timeout 240 "$@" >> "$chemin" 2>&1
    rc=$?
    fin=$(date +%s)
    echo "# ---------------------------------------------------------------" >> "$chemin"
    echo "# code de retour : $rc   duree : $((fin - debut)) s" >> "$chemin"

    if [ "$rc" -eq 124 ]; then
        FAIL=$((FAIL + 1))
        dire "  ${R}✗${N} ${nom} — delai depasse (240 s)   ${C}${fichier}${N}"
        return
    fi
    if [ "$motif" = "-" ]; then
        if [ "$rc" -eq 0 ]; then
            PASS=$((PASS + 1)); dire "  ${G}✓${N} ${nom}   ${C}${fichier}${N}"
        else
            FAIL=$((FAIL + 1)); dire "  ${R}✗${N} ${nom} — code $rc   ${C}${fichier}${N}"
        fi
        return
    fi
    if grep -qE "$motif" "$chemin"; then
        PASS=$((PASS + 1)); dire "  ${G}✓${N} ${nom}   ${C}${fichier}${N}"
    else
        FAIL=$((FAIL + 1))
        dire "  ${R}✗${N} ${nom} — motif absent : ${motif}   ${C}${fichier}${N}"
    fi
}

ignore() { NUM=$((NUM + 1)); SKIP=$((SKIP + 1)); dire "  ${Y}-${N} $1"; }

titre() { dire ""; dire "${B}$1${N}"; dire "----------------------------------------------------------------------"; }

# ── le lab est-il debout ? ────────────────────────────────────────────────────
CONTENEURS="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^osmo-' || true)"
HUB=""
if [ "${CONTENEURS:-0}" -gt 0 ]; then
    HUB="$(docker exec "$(docker ps --format '{{.Names}}' | grep '^osmo-operator-' | head -1)" \
           printenv OSMO_HUB_IP 2>/dev/null | tr -d '\r')"
fi

dire ""
dire "${C}======================================================================${N}"
dire "${C}  TEST DE LA CONSOLE SS7 - $(date '+%Y-%m-%d %H:%M:%S')${N}"
dire "${C}======================================================================${N}"
dire "  depot      : $REPO"
dire "  journaux   : $LOGDIR"
dire "  conteneurs : ${CONTENEURS:-0}   hub : ${HUB:-aucun}"
[ "$RAPIDE" = "1" ] && dire "  mode       : rapide (ni M3UA ni MAP)"

titre "1. LE PAQUET S'IMPORTE"
essai "import-modules" "modules ok" python3 -c "
import sys; sys.path.insert(0, '$REPO')
from navigation import ber, sccp, tcap, mapops, m3ua, ss7, topo, vty, diagram, quickcmd, responder
print('modules ok')"
essai "encodage-ber-sccp" "encodage ok" python3 -c "
import sys; sys.path.insert(0, '$REPO')
from navigation import sccp, tcap, mapops, ber
a = sccp.Address(pc='1.11.2', ssn=6)
assert sccp.Address.decode(a.encode()).pc == '1.11.2'
assert sccp.pc_to_int('1.11.2') == (1 << 11) | (11 << 3) | 2
assert sccp.untbcd(sccp.tbcd('600101')) == '600101'
u = sccp.udt(a, sccp.Address(pc='1.11.7', ssn=8), b'\x62\x03\x48\x01\x01')
d = sccp.decode(u); assert d.kind == 'UDT' and d.called.ssn == 6
m = tcap.parse(tcap.begin(b'\x01\x02\x03\x04', tcap.invoke(1, 45, b''), mapops.AC['shortMsgGateway']))
assert m.kind == 'begin' and m.components[0].opcode == 45
print('encodage ok')"
essai "aide-console" "usage: ss7-console" "$CONSOLE" --help
essai "aide-diag" "usage: ss7-diag" "$DIAG" --help

titre "2. INVENTAIRE ET CATALOGUE"
essai "console-ops" "sendRoutingInfoForSM" "$CONSOLE" ops
essai "console-list" "Hub inter-STP" "$CONSOLE" --no-probe list
essai "console-list-sonde" "Hub inter-STP" "$CONSOLE" list

titre "3. VTY (un test par demon)"
if [ "${CONTENEURS:-0}" -gt 0 ]; then
    essai "vty-stp"   "Routing|AS Name"   "$CONSOLE" vty 1 4239 "show cs7 instance 0 as all"
    essai "vty-stp-route" "Routing table" "$CONSOLE" vty 1 4239 "show cs7 instance 0 route"
    essai "vty-msc"   "IMSI|Subscriber"   "$CONSOLE" vty 1 4254 "show subscriber cache"
    essai "vty-hlr"   "IMSI|MSISDN"       "$CONSOLE" vty 1 4258 "show subscribers all"
    essai "vty-hlr-gsup" "VLR|GSUP|from"  "$CONSOLE" vty 1 4258 "show gsup-connections"
    essai "vty-bsc"   "BTS|bts"           "$CONSOLE" vty 1 4242 "show bts"
    essai "vty-inconnu-propre" "injoignable" "$CONSOLE" vty 1 4299 "show version"
else
    ignore "VTY : aucun conteneur ne tourne"
fi

titre "4. SS7 REEL (M3UA, DAUD, MAP)"
if [ "$RAPIDE" = "1" ]; then
    ignore "M3UA et MAP : mode rapide"
elif [ -z "$HUB" ]; then
    ignore "M3UA et MAP : aucun hub connu (lab arrete ?)"
else
    essai "m3ua-audit-stp" "JOIGNABLE|DAVA" "$CONSOLE" audit 1.11.2
    essai "m3ua-audit-msc" "JOIGNABLE|DAVA" "$CONSOLE" audit 1.11.1
    essai "m3ua-audit-inconnu" "INACCESSIBLE|DUNA|aucune reponse" "$CONSOLE" audit 7.255.7
    essai "map-sans-destination" "point code|global title" "$CONSOLE" map sri-sm msisdn=600101
    essai "map-operation-inconnue" "operation inconnue" "$CONSOLE" map pas-une-op --pc 1.11.2
    # Aller-retour complet : le repondeur repond a l'emetteur a travers le hub.
    essai "map-aller-retour" "IMSI" "$DIAG" --no-probe
fi

titre "5. DIAGNOSTIC COMPLET"
essai "diag-rapide" "RESUME" "$DIAG" --rapide --no-probe --log "$LOGDIR/diag-rapide.txt"
if [ "$RAPIDE" != "1" ] && [ -n "$HUB" ]; then
    essai "diag-complet" "RESUME" "$DIAG" --log "$LOGDIR/diag-complet.txt"
else
    ignore "diagnostic complet : lab a l'arret ou mode rapide"
fi

titre "6. LE SCHEMA (interface aux fleches)"
essai "schema-rendu" "INTER-STP" python3 -c "
import sys; sys.path.insert(0, '$REPO')
from navigation import topo, diagram
t = topo.discover(probe=False)
lignes, boites = diagram.build(t)
print('\n'.join(lignes))
print('%d boites' % len(boites))
assert boites, 'aucune boite'
i = 0
for direction in ((0, 1), (1, 0), (0, -1), (-1, 0)):
    i = diagram.navigate(boites, i, direction)
print('navigation ok')"
essai "schema-navigation" "navigation ok" python3 -c "
import sys; sys.path.insert(0, '$REPO')
from navigation import topo, diagram
t = topo.discover(probe=False)
_, boites = diagram.build(t)
vus = set()
i = 0
for _ in range(40):
    for d in ((0,1),(1,0),(0,-1),(-1,0)):
        i = diagram.navigate(boites, i, d); vus.add(i)
assert len(vus) >= min(3, len(boites))
print('navigation ok')"

titre "RESUME"
dire "  ${G}${PASS} reussi(s)${N}   ${R}${FAIL} echec(s)${N}   ${Y}${SKIP} ignore(s)${N}"
dire "  journaux : ${C}${LOGDIR}${N}  (un fichier par commande)"
dire "  rapport  : ${C}${RAPPORT}${N}"
dire ""
exit "$FAIL"
