# 15-fin.sh - partie de start.sh (lignes 3443-3454 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
[ $DRY -eq 1 ] || audio_start
say_begin "Transmission a run.sh"
if [ $DRY -eq 1 ]; then
    say_end " -- " "$C_DIM" "Transmission a run.sh" "dry-run"
    printf '  commande : CALYPSO_PROFILE=%s bash %s %s\n' \
        "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
    exit 0
fi
say_end " OK " "$C_OK" "Transmission a run.sh" "profil=$CALYPSO_PROFILE"
# Hand-off total : ce processus devient run.sh
exec bash "$RUN_SH" "${RUN_ARGS[@]}"
