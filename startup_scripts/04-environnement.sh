# 04-environnement.sh - part of start.sh (environment, encryption, TRX bridge)
# Sourced by start.sh in the main shell: same order, same variables.
say_begin "Chargement de l'environnement"
if [ -f "$HERE/environment/load.env" ]; then
    set -a; . "$HERE/environment/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "environment/load.env"
elif [ -f "$HERE/env/load.env" ]; then
    set -a; . "$HERE/env/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "env/load.env"
else
    # Minimal fallback (typical repository paths)
    : "${GSM_ROOT:=/opt/GSM}"
    : "${NITB_TREE:=$HERE}"
    # Same tree selection as environment/paths.env, replicated for the case
    # where load.env is missing (ISO, bare container). One QEMU tree: qosmo;
    # --dsp does not change tree, it hands the layer 1 to c54x_exe.
    : "${CALYPSO_FORK:=qosmo}"
    if [ -x "$HERE/../$CALYPSO_FORK/run.sh" ]; then
        : "${OQC_ROOT:=$(cd "$HERE/../$CALYPSO_FORK" && pwd)}"
    else
        : "${OQC_ROOT:=$GSM_ROOT/$CALYPSO_FORK}"
    fi
    say_end " OK " "$C_OK" "Chargement de l'environnement" "fallback minimal"
fi
: "${RUN_DIR:=/run/osmo-direct}"
# Fallback if load.env is missing. The logs stay under RUN_DIR (tmpfs): the
# tmux scrollback depends on it - cf. environment/paths.env.
: "${LOG_DIR:=$RUN_DIR/logs}"
# A5/1 by default: the encryption validated end to end on the model
# (Calypso ↔ BTS), and what start-docker.sh already imposes in its hand-off to
# this script, so that the direct launch and the start-docker.sh launch use
# the same encryption.
#
# WARNING: globals.conf is read BEFORE and is authoritative for this variable
# (its header says so). This ":=" is only a fallback when globals.conf is
# missing - the ISO, a bare container. The value that applies in practice
# comes from there.
: "${ENCRYPTION:=a5 1}"
# The default TRX bridge: a single transceiver (pont/pont.py) that presents
# itself to osmo-bts-trx as TRX-UDP, decodes the DL to GSMTAP 4730/4731 and
# encodes the UL. CALYPSO_BRIDGE is not declared in globals.conf (the
# CALYPSO_* "pass through, intact" according to its header): the environment
# really wins.
#   CALYPSO_BRIDGE=none ./start-native.sh   -> no bridge (QEMU + BTS only)
#
# TWO CHAINS, SELECTED BY --dsp / --grgsm. THE DEFAULT IS THE DSP (DSP_MODE=1
# in 01-defauts-options.sh). gr-gsm (qosmo + grgsm_exe) needs --grgsm: the
# layer 1 is then a gr-gsm decoder in QEMU, and that is the stack that goes
# end to end up to the voice call.
#
# `--dsp` does NOT designate a QEMU fork. The C54x runs OUTSIDE QEMU, in
# /opt/GSM/c54x_exe (TI mask-ROM, core emulated by l1-dsp), and QEMU is only
# the ARM, started with CALYPSO_DSP_EXTERN=1 from the /opt/GSM/qosmo tree.
# The five steps are in c54x_exe/run.sh:
#   1. c54x_exe --arm        the DSP, socket /tmp/calypso_dsp.sock + shared
#                            API RAM, DL bursts over UDP 6702
#   2. qemu-system-arm       the ARM + osmocom-bb layer1, gr-gsm layer 1 off
#   3. osmocon               romload on the serial pty, L1CTL relay
#   4. mobile                osmocom-bb layers 2/3
#   5. pont.py               TRXD 5700-5702 facing osmo-bts-trx, bursts to the
#                            DSP, uplink through the /dev/shm side-bands
# What it does: the mobile acquires FB and SB, decodes SI1-4 (lai=001-01-1),
# camps, and performs its location update.
#
# The DSP ROM is in /opt/GSM/c54x_exe/rom (and in /opt/GSM/calypso_dsp.*.bin,
# where c54x_exe reads it by default).
#
# --dsp: NO BRIDGE STARTED BY THIS SCRIPT. c54x_exe/run.sh starts its own
# (step 5) on 5700-5702; a second bridge on the same ports would die on
# "Address already in use" and leave a corpse at every start.
# `none` = nothing to start here. Do NOT use `ipc`: that value means
# "MS#1 through osmo-trx-ms-ipc, QEMU firmware not started".
# A value set by the operator is respected.
#
# The DSP being the default, `none` only applies if the DSP bench is REALLY
# started (DSP_BANC=1, decided right below): a missing c54x_exe falls back to
# gr-gsm, which needs its bridge.

