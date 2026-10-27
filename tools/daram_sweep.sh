#!/bin/bash
# tools/daram_sweep.sh - sweep CALYPSO_BSP_DARAM_ADDR in full mode and compare
# the activity of the FB-det correlator (fb0_att / snr / toa / pm).
# Goal: decide empirically which DARAM area unblocks the FB-det.
#
# Robust: run.sh is started NO_ATTACH IN THE FOREGROUND (it returns on its own
# after starting qemu, which survives orphaned). run.sh is NOT backgrounded
# with & (that breaks the log pipe and qemu dies). qemu is checked to be alive
# before measuring; otherwise it is reported.
#
# Usage (container): /opt/GSM/daram_sweep.sh
# Env: ADDRS (default "0x0080 0x2a00 0x0060"), SETTLE (post-boot wait, 50s)
set -u
RUN=/opt/GSM/qosmo-grgsm/run.sh
QLOG=/root/qemu.log
ADDRS="${ADDRS:-0x0080 0x2a00 0x0060}"
SETTLE="${SETTLE:-50}"
# Emulation profile of the sweep. The profiles in environment/modes.env are
# empty | shunt_legit | shunt_legit_no_inject | native | native_twl |
# native_twl_host_demod | native_helped.
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
    # run.sh NO_ATTACH returns on its own after the launch (~30-60s). timeout = safety net.
    echo "  launch run.sh (NO_ATTACH, avant-plan, le boot prend ~30-60s)..."
    timeout 150 env CALYPSO_NO_ATTACH=1 CALYPSO_MODE="$MODE" CALYPSO_ICOUNT=off \
      CALYPSO_NO_RESTART=1 CALYPSO_BSP_DARAM_ADDR="$a" "$RUN" \
      </dev/null >"/tmp/sweep_$a.out" 2>&1
    rc_run=$?
    # Check that the profile was actually applied: with an unknown mode run.sh
    # aborts at its second module, the previous qemu (restarted by the
    # supervision) keeps writing to the SAME log, and the sweep would measure
    # that instance instead.
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
        # stop early once non-trivial FB data has been seen
        grep -qa "real DSP path" "$QLOG" 2>/dev/null && [ "$i" -ge 4 ] && break
    done

    fb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "fb0_att=[0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1)
    sb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "sb_att=[0-9]+"  | grep -oE "[0-9]+" | sort -n | tail -1)
    # Two FBSB line formats are accepted: the correlator writes
    #   data[](det=0 toa=0 pm=0 ang=0 snr=0x0000) api[](...)
    # or "last(snr=... toa=... ang=... pm=...)". Matching only one of them
    # would report "non0=0 / 1er_corr=none" for every address, including those
    # where the correlator sees the I/Q well.
    NUL='(det=0 toa=0 pm=0 ang=0 snr=0x0000)|snr=0 toa=0 ang=0 pm=0'
    nz=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avcE "$NUL")
    best=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avE "$NUL" \
             | grep -oE "(data\[\]\(det=[0-9-]+ toa=[0-9-]+ pm=[0-9-]+ ang=[0-9-]+ snr=0x[0-9a-fA-F]+\))|(last\(snr=[0-9-]+ toa=[0-9-]+ ang=[0-9-]+ pm=[0-9a-fx]+\))" \
             | head -1)
    # Total number of hits: the detection rate matters as much as the first
    # success (19 % is not enough to lock the synchronisation).
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
