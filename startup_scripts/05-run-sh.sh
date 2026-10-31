# 05-run-sh.sh - part of start.sh (run.sh resolution, DSP bench, audio)
# Sourced by start.sh in the main shell: same order, same variables.
: "${MS_COUNT:=2}"
: "${HOST_IP:=127.0.0.1}"
mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb 2>/dev/null || true
# --- 2. path / binary detection -----------------------------------------------
say_begin "Resolution de run.sh"
# Order: explicit RUN_SH > resolved OQC_ROOT > historical path, so that RUN_SH
# can be overridden like everything else ("the command line always wins").
# THE DSP BENCH ADDS TO THE PIPELINE, IT DOES NOT REPLACE IT.
# RUN_SH stays the fork's one and brings everything up as usual (core, BTS,
# side-car and tmux are in the fork's run_modules); only the four modules of
# the Calypso chain that c54x_exe provides are removed from it (qemu, pty,
# osmocon, l2 - steps 2, 3 and 4 of its run.sh). The DSP bench is started
# right after, with its five steps.
# BANC_DSP=<path> to designate another one; BANC_DSP=none disables it.
DSP_BANC=0
DSP_MODULES_RETIRES="qemu,pty,osmocon,l2"
: "${BANC_DSP:=$GSM_ROOT/c54x_exe/run.sh}"
# Multithreading (default; --no-multithreading turns it off): c54x_exe --plan
# runs its jobs one process per CPU core (src/multi.c). Off = COEURS=1, read by
# c54x_exe --plan and balayage.sh. An explicit COEURS still wins.
if [ "${MULTITHREADING:-1}" = 1 ]; then
    : "${COEURS:=0}"
else
    : "${COEURS:=1}"
fi
export COEURS
if [ "${DSP_MODE:-0}" = 1 ] && [ "$BANC_DSP" != none ] && [ -x "$BANC_DSP" ]; then
    DSP_BANC=1
elif [ "${DSP_MODE:-0}" = 1 ] && [ "$BANC_DSP" != none ]; then
    # The default is the DSP, but without its bench: say so, and the gr-gsm
    # chain takes over (CALYPSO_BRIDGE stays `pont`).
    printf '  %s!%s banc DSP absent (%s) - couche 1 gr-gsm a la place\n' "${C_KO:-}" "${C_Z:-}" "$BANC_DSP" >&2
fi
if [ "$DSP_BANC" = 1 ]; then
    : "${CALYPSO_BRIDGE:=none}"
fi
: "${CALYPSO_BRIDGE:=pont}"
: "${RUN_SH:=${OQC_ROOT:+$OQC_ROOT/run.sh}}"
: "${RUN_SH:=$GSM_ROOT/${CALYPSO_FORK:-qosmo}/run.sh}"
if [ ! -x "$RUN_SH" ]; then
    say_end "FAIL" "$C_KO" "Resolution de run.sh" "$RUN_SH introuvable ou non executable"
    printf '       %s→ Verifiez que %s existe et est executable%s\n' "$C_DIM" "$RUN_SH" "$C_Z"
    printf '       %s→ run.sh vit dans /opt/GSM/qosmo (repris de l ancien qosmo-grgsm)%s\n' "$C_DIM" "$C_Z"
    exit 1
fi
say_end " OK " "$C_OK" "Resolution de run.sh" "$RUN_SH"
RUN_ROOT="$(dirname "$RUN_SH")"

# ── THE DSP BENCH: ITS VOCABULARY ──────────────────────────────────────────
# c54x_exe/run.sh only takes --stop | --status | --logs | --step N, nothing
# else: passing it --profile makes it exit on "option inconnue".
# The core network, the BTS and the side-car stay brought up by the fork's
# plan; this bench only provides the Calypso chain (its five steps).
# STOPPING DOES NOT REQUIRE --dsp. DSP_BANC is 0 when --dsp is not typed
# again, but c54x_exe, QEMU, osmocon, the mobile and pont.py would still hold
# the ports 5700-5702 and /tmp/calypso_dsp.sock. So the bench is stopped as
# soon as it exists; its --stop does no harm when it is not running.
#
# ⚠️ EXPLICIT MODE=dsp ON EVERY CALL. start-native exports its own MODE (the
# profile: "faketrx-qemu"), and c54x_exe/run.sh reads the SAME variable to
# choose dsp|grgsm. Without it, it exits on
#     [run] ECHEC : MODE=faketrx-qemu inconnu (dsp|grgsm)
# and the bench is not stopped - silently, since the caller ignores its
# return code. Two scripts, two meanings for the same name: the bench's one
# is not renamed (run_real.sh and habits use it), the value is set each time.
# PulseAudio lightened at every start: speech-dispatcher stopped, speex
# canceller instead of webrtc, osmo_rec in 8 kHz mono (lib/audio.sh,
# alleger_audio). audio-chain.sh is idempotent; AUDIO_ALLEGER=0 to leave
# everything alone, AUDIO_AEC_METHOD=webrtc to keep the webrtc canceller.
audio_start() {
    [ -f "$HERE/scripts/audio-chain.sh" ] || return 0
    say_begin "Audio (PulseAudio allege)"
    if bash "$HERE/scripts/audio-chain.sh" 5 >/tmp/osmo-audio-chain.log 2>&1; then
        say_end " OK " "$C_OK" "Audio (PulseAudio allege)" "journal /tmp/osmo-audio-chain.log"
    else
        say_end " !! " "$C_KO" "Audio (PulseAudio allege)" "voir /tmp/osmo-audio-chain.log"
    fi
}

