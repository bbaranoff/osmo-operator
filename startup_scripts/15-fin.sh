# 15-fin.sh - part of start.sh (hand-off to run.sh)
# Sourced by start.sh in the main shell: same order, same variables.
[ $DRY -eq 1 ] || audio_start
say_begin "Transmission a run.sh"
if [ $DRY -eq 1 ]; then
    say_end " -- " "$C_DIM" "Transmission a run.sh" "dry-run"
    printf '  commande : CALYPSO_PROFILE=%s bash %s %s\n' \
        "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
    exit 0
fi
say_end " OK " "$C_OK" "Transmission a run.sh" "profil=$CALYPSO_PROFILE"
# Full hand-off: this process becomes run.sh
exec bash "$RUN_SH" "${RUN_ARGS[@]}"
