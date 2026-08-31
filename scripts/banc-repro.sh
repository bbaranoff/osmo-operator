#!/bin/bash
# =============================================================================
#  banc-repro.sh — UNE EXPERIENCE REPRODUCTIBLE, DU DEMARRAGE AU VERDICT
# =============================================================================
#  POURQUOI CE SCRIPT EXISTE. Le defaut qu'on chasse est INTERMITTENT : sur une
#  serie d'appels, certains aboutissent et d'autres non. Diagnostiquer ca demande
#  de rejouer la meme sequence apres chaque changement, et de comparer des
#  journaux comparables. Fait a la main, chaque iteration coute plusieurs minutes
#  et produit des runs qui ne se comparent pas (nombre d'appels different, delais
#  differents, journaux qui se melangent avec les precedents).
#
#  Ce script fige la sequence : demarrage detache, attente du camp, N appels
#  identiques, collecte horodatee, verdict par appel.
#
#  IL NE CORRIGE RIEN ET NE DEVINE RIEN. Il produit une mesure.
#
#  Usage :
#     scripts/banc-repro.sh                      3 appels, avec redemarrage
#     scripts/banc-repro.sh --calls 5            5 appels
#     scripts/banc-repro.sh --no-restart         reutilise la pile en cours
#     scripts/banc-repro.sh --dest 600           numero appele (defaut 600)
#
#  Sortie : un repertoire /root/repro-<horodatage>/ contenant tous les journaux
#  du run et un resume.txt. Rien n'est ecrase d'un run a l'autre.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLS=3
DEST=600
RESTART=1
VTY=4247                 # MS#1 ; MS#2 est sur 4248
CALL_S=20                # duree d'un appel
GAP_S=10                 # silence entre deux appels (le canal doit se liberer)
BOOT_MAX=180             # attente maximale du camp

while [ $# -gt 0 ]; do
    case "$1" in
        --calls)      CALLS="${2:?}"; shift ;;
        --dest)       DEST="${2:?}"; shift ;;
        --vty)        VTY="${2:?}"; shift ;;
        --call-s)     CALL_S="${2:?}"; shift ;;
        --gap-s)      GAP_S="${2:?}"; shift ;;
        --no-restart) RESTART=0 ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/repro-$STAMP"
mkdir -p "$OUT"
LOGDIR=/run/user/0/osmo-nitb/logs

say() { printf '  %s\n' "$*"; }

# ── VTY : une commande, une reponse ─────────────────────────────────────────
# `enable` puis la commande. On laisse une seconde au demon pour repondre : nc
# ferme des que stdin se termine, et sans cette pause la commande part mais la
# reponse n'est jamais lue (symptome : "aucune sortie" sur une commande qui a
# pourtant bien ete executee).
vty() {
    { printf 'enable\n%s\n' "$1"; sleep 1; } | timeout 6 nc 127.0.0.1 "$VTY" 2>/dev/null
}

# ── 1. Demarrage ────────────────────────────────────────────────────────────
# CALYPSO_NO_ATTACH=1 : run.sh ne s'attache pas a tmux a la fin (run.sh:262).
# Sans ca le script resterait bloque sur une session interactive.
if [ "$RESTART" = 1 ]; then
    say "arret de la pile en cours"
    ( cd "$HERE" && CALYPSO_NO_ATTACH=1 ./start-direct.sh --stop ) >"$OUT/stop.log" 2>&1
    sleep 3
    say "demarrage detache (CALYPSO_NO_ATTACH=1)"
    ( cd "$HERE" && CALYPSO_NO_ATTACH=1 setsid ./start-direct.sh ) >"$OUT/start.log" 2>&1 &
else
    say "pile en cours reutilisee (--no-restart)"
fi

# ── 2. Attendre le camp, ne pas le supposer ─────────────────────────────────
# On interroge le VTY plutot que d'attendre un delai fixe : selon la machine, le
# camp arrive en 40 s ou en 2 min, et un sleep fige donne soit du gaspillage soit
# des appels lances avant que le mobile ne soit pret — donc des "echecs" qui ne
# mesurent que notre impatience.
say "attente du camp (C3), maximum ${BOOT_MAX}s"
camp=0
for i in $(seq 1 "$BOOT_MAX"); do
    if vty "show ms" 2>/dev/null | grep -q "C3 camped normally"; then camp=1; break; fi
    sleep 1
done
if [ "$camp" != 1 ]; then
    say "PAS DE CAMP apres ${BOOT_MAX}s — on s'arrete, les appels ne mesureraient rien"
    vty "show ms" > "$OUT/show-ms-echec.txt" 2>&1
    cp "$LOGDIR"/*.log "$OUT/" 2>/dev/null
    exit 1
fi
say "campe apres ${i}s"

# Marqueur : tout ce qui suit dans pont.log appartient a l'experience.
PONT_DEBUT=$(wc -l < /dev/shm/pont.log 2>/dev/null || echo 0)

# ── 3. Les appels ───────────────────────────────────────────────────────────
: > "$OUT/appels.txt"
for n in $(seq 1 "$CALLS"); do
    say "appel $n/$CALLS  -> $DEST"
    avant=$(wc -l < /dev/shm/pont.log 2>/dev/null || echo 0)
    vty "call 1 $DEST" > "$OUT/appel-$n-vty.txt" 2>&1
    sleep "$CALL_S"
    vty "call 1 hangup" >> "$OUT/appel-$n-vty.txt" 2>&1
    sleep 2

    # Verdict : dans la tranche de pont.log produite par CET appel, un
    # "DESARME (CHANNEL RELEASE" signe un TCH qui a vecu ; un "SANS ASSIGNMENT
    # COMPLETE" signe un mobile qui n'a pas bascule. On ne conclut pas d'apres
    # les compteurs cumulatifs, qui melangeraient les appels precedents.
    tranche=$(tail -n +$((avant + 1)) /dev/shm/pont.log 2>/dev/null)
    if printf '%s' "$tranche" | grep -q "SANS ASSIGNMENT COMPLETE"; then
        verdict=ECHEC
    elif printf '%s' "$tranche" | grep -q "DESARME (CHANNEL RELEASE"; then
        verdict=OK
    else
        verdict=INDETERMINE
    fi
    printf 'appel %d : %s\n' "$n" "$verdict" | tee -a "$OUT/appels.txt"
    printf '%s' "$tranche" > "$OUT/appel-$n-pont.log"
    sleep "$GAP_S"
done

# ── 4. Collecte ─────────────────────────────────────────────────────────────
say "collecte des journaux"
cp /dev/shm/pont.log            "$OUT/pont.log"            2>/dev/null
tail -n +$((PONT_DEBUT + 1)) /dev/shm/pont.log > "$OUT/pont-experience.log" 2>/dev/null
cp "$LOGDIR"/qemu.log           "$OUT/qemu.log"            2>/dev/null
cp "$LOGDIR"/qemu-tete.log      "$OUT/qemu-tete.log"       2>/dev/null
cp "$LOGDIR"/mobile.log         "$OUT/mobile.log"          2>/dev/null
journalctl -u osmo-bsc --since "-30min" --no-pager > "$OUT/osmo-bsc.log" 2>/dev/null
journalctl -u osmo-msc --since "-30min" --no-pager > "$OUT/osmo-msc.log" 2>/dev/null
for f in calypso_dcch_cfg calypso_kc_l1 calypso_tch_cfg; do
    [ -e "/dev/shm/$f" ] && od -A d -t x1 "/dev/shm/$f" > "$OUT/$f.hex" 2>/dev/null
done

# ── 5. Resume ───────────────────────────────────────────────────────────────
# Les compteurs de pont.py (STATS, DETAIL blocs) sont de VRAIS cumuls. Ceux du
# shunt sont des SHUNT_LOG limites en debit (ex. `if (++n <= 3 || n % 2000 == 0)`)
# : les compter donnerait un chiffre qui ne mesure rien. On ne met donc ici que
# ce qui est fiable, et on le dit.
{
    echo "=== experience $STAMP : $CALLS appels vers $DEST ==="
    cat "$OUT/appels.txt"
    echo
    echo "--- canaux dedies appris par le shunt (compteur reel, non limite) ---"
    grep -ac "DCCH #" "$OUT/qemu.log" 2>/dev/null
    grep -ah "DCCH #" "$OUT/qemu.log" 2>/dev/null | tail -5
    echo
    echo "--- pont : compteurs cumulatifs (FIABLES) ---"
    grep -a "STATS" "$OUT/pont.log" 2>/dev/null | tail -1
    grep -a "DETAIL blocs" "$OUT/pont.log" 2>/dev/null | tail -1
    grep -a "SOUS-VOIE ACTIVE" "$OUT/pont.log" 2>/dev/null | tail -1
    echo
    echo "--- reseau : echecs d'assignation ---"
    grep -ac "Assignment failed" "$OUT/osmo-bsc.log" 2>/dev/null
    echo
    echo "--- mobile : SAPI invalides ---"
    grep -ac "unsupported SAPI" "$OUT/mobile.log" 2>/dev/null
    echo
    echo "ATTENTION : les SHUNT_LOG du shunt sont limites en debit."
    echo "Ne pas utiliser 'grep -c' sur eux comme un compteur."
} > "$OUT/resume.txt" 2>&1

cat "$OUT/resume.txt"
say "tout est dans $OUT"
