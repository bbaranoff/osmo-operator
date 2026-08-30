#!/bin/bash
# tools/daram_sweep.sh - balaye CALYPSO_BSP_DARAM_ADDR en full mode et compare
# l'activite du correlateur FB-det (fb0_att / snr / toa / pm).
# But : trancher empiriquement quelle zone DARAM debloque le FB-det.
#
# Robuste : run.sh est lance NO_ATTACH EN AVANT-PLAN (il rend la main seul
# apres avoir lance qemu, qui survit orphelin). On NE backgroude PAS run.sh
# avec & (ca cassait le pipe du log → qemu mourait). On verifie que qemu est
# vivant avant de mesurer ; sinon on le signale.
#
# Usage (conteneur) : /opt/GSM/daram_sweep.sh
# Env : ADDRS (defaut "0x0080 0x2a00 0x0060"), SETTLE (attente post-boot, 50s)
set -u
RUN=/opt/GSM/qemu-src/run.sh
QLOG=/root/qemu.log
ADDRS="${ADDRS:-0x0080 0x2a00 0x0060}"
SETTLE="${SETTLE:-50}"
# Profil d'emulation du balayage. "full" a disparu de environment/modes.env :
# les profils sont empty | shunt_legit | shunt_legit_no_inject | native |
# native_twl | native_twl_host_demod | native_helped.
MODE="${MODE:-${CALYPSO_MODE:-native}}"
declare -A R_FB R_SB R_NZ R_BEST R_ALIVE R_STATES R_TOT

kill_all() {
    tmux kill-session -t calypso 2>/dev/null
    for p in $(pgrep -f qemu-system-arm); do kill -9 "$p" 2>/dev/null; done
    pkill -9 -f osmo-bts-trx 2>/dev/null; pkill -9 -f osmo-trx-ipc 2>/dev/null
    pkill -9 -f "mobile" 2>/dev/null; pkill -9 -f osmocon 2>/dev/null
    sleep 4
}

for a in $ADDRS; do
    echo "############ DARAM_ADDR=$a (profil $MODE) ############ $(date +%H:%M:%S)"
    kill_all
    if pgrep -f qemu-system-arm >/dev/null; then
        echo "  !! un qemu survit a kill_all : la supervision le relance." >&2
        echo "     Arretez la pile (CALYPSO_NO_RESTART=1 ou ./run.sh --stop) avant le balayage." >&2
        exit 3
    fi
    : > "$QLOG"
    # run.sh NO_ATTACH rend la main seul apres le launch (~30-60s). timeout = filet.
    echo "  launch run.sh (NO_ATTACH, avant-plan, le boot prend ~30-60s)..."
    timeout 150 env CALYPSO_NO_ATTACH=1 CALYPSO_MODE="$MODE" CALYPSO_ICOUNT=off \
      CALYPSO_NO_RESTART=1 CALYPSO_BSP_DARAM_ADDR="$a" "$RUN" \
      </dev/null >"/tmp/sweep_$a.out" 2>&1
    rc_run=$?
    # Le profil a-t-il seulement ete applique ? Sans ce controle, un mode
    # inconnu faisait avorter run.sh a son deuxieme module, l'ancien qemu
    # (relance par la supervision) continuait d'ecrire dans le MEME journal,
    # et le balayage mesurait cette instance-la : les trois adresses rendaient
    # alors la meme "premiere detection", au caractere pres.
    if grep -qa "CALYPSO_MODE inconnu\|sequence aborted" "/tmp/sweep_$a.out"; then
        echo "  !! run.sh a avorte : profil '''$MODE''' refuse par environment/modes.env" >&2
        sed -n '''/valeurs :/,+2p''' "/tmp/sweep_$a.out" | sed "s/^/     /" >&2
        echo "     Relancez avec MODE=<profil valide> $0" >&2
        exit 2
    fi
    echo "  run.sh rendu (code=$?). qemu doit tourner orphelin. settle ${SETTLE}s..."
    alive=no
    for i in $(seq 1 $((SETTLE/5))); do
        sleep 5
        if pgrep -f qemu-system-arm >/dev/null; then alive=yes; else alive=no; fi
        # stop tot si on a deja du FB data non trivial
        grep -qa "real DSP path" "$QLOG" 2>/dev/null && [ "$i" -ge 4 ] && break
    done

    fb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "fb0_att=[0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1)
    sb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "sb_att=[0-9]+"  | grep -oE "[0-9]+" | sort -n | tail -1)
    # Le format des lignes FBSB a change : le correlateur s'ecrit desormais
    #   data[](det=0 toa=0 pm=0 ang=0 snr=0x0000) api[](...)
    # et non plus "last(snr=... toa=... ang=... pm=...)". Les deux motifs sont
    # acceptes : sans cela le balayage annoncait "non0=0 / 1er_corr=none" pour
    # TOUTES les adresses, y compris celles ou le correlateur voit tres bien
    # l'I/Q - un faux negatif qui condamnait la bonne zone DARAM.
    NUL='(det=0 toa=0 pm=0 ang=0 snr=0x0000)|snr=0 toa=0 ang=0 pm=0'
    nz=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avcE "$NUL")
    best=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avE "$NUL" \
             | grep -oE "(data\[\]\(det=[0-9-]+ toa=[0-9-]+ pm=[0-9-]+ ang=[0-9-]+ snr=0x[0-9a-fA-F]+\))|(last\(snr=[0-9-]+ toa=[0-9-]+ ang=[0-9-]+ pm=[0-9a-fx]+\))" \
             | head -1)
    # Combien de passages en tout : le taux de detection compte autant que le
    # premier succes (19 % ne suffit pas a verrouiller la synchro).
    tot=$(grep -ac "real DSP path" "$QLOG" 2>/dev/null)
    states=$(grep -aoE 'state=[A-Z0-9_]+' "$QLOG" 2>/dev/null | sort | uniq -c | tr '\n' ' ')
    qlines=$(wc -l < "$QLOG" 2>/dev/null)
    R_FB[$a]="${fb:-0}"; R_SB[$a]="${sb:-0}"; R_NZ[$a]="${nz:-0}"
    R_BEST[$a]="${best:-none}"; R_ALIVE[$a]="$alive"; R_STATES[$a]="${states:-<aucun>}"
    R_TOT[$a]="${tot:-0}"
    echo "  -> qemu_vivant=$alive  qemu.log=${qlines}l  fb0_att=${fb:-0}  sb_att=${sb:-0}  non0=${nz:-0}/${tot:-0}"
    echo "  -> etats: ${states:-<aucun>}"
    echo "  -> 1er correlateur non-nul: ${best:-none}"
done

kill_all
echo
echo "================= COMPARAISON ================="
printf "%-9s %-7s %-9s %-8s %-12s %s\n" "ADDR" "alive" "fb0_att" "sb_att" "non0/total" "1er_corr"
for a in $ADDRS; do
    printf "%-9s %-7s %-9s %-8s %-12s %s\n" \
      "$a" "${R_ALIVE[$a]}" "${R_FB[$a]}" "${R_SB[$a]}" \
      "${R_NZ[$a]}/${R_TOT[$a]}" "${R_BEST[$a]}"
done
echo
echo "Gagnant = fb0_att>0 et/ou non0>0 (correlateur voit l'I/Q). alive=no => boot KO."
