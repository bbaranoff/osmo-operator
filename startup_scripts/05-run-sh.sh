# 05-run-sh.sh - partie de start.sh (lignes 764-843 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
: "${MS_COUNT:=2}"
: "${HOST_IP:=127.0.0.1}"
mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb 2>/dev/null || true
# --- 2. detection des chemins / binaires --------------------------------------
say_begin "Resolution de run.sh"
# [2026-08-08] Le chemin etait cable en dur ICI, ce qui rendait MORTE toute la
# resolution de OQC_ROOT faite plus haut (trois candidats testes pour rien) et
# contredisait le contrat annonce en tete de fichier ("la ligne de commande
# gagne toujours") : RUN_SH etait la seule variable non surchargeable.
# Ordre : RUN_SH explicite > OQC_ROOT resolu > chemin historique.
# [2026-09-22] LE BANC DSP S'AJOUTE AU PIPELINE, IL NE LE REMPLACE PAS.
# Premiere version : --dsp mettait RUN_SH = c54x_exe/run.sh. La pile osmocom ne
# montait alors plus du tout -- le coeur, la BTS, le side-car et tmux sont dans
# les run_modules du fork, que ce run.sh-la ne connait pas. Rapport du banc :
# « il faut lancer la pile osmo aussi comme mode=grgsm ».
# Donc : RUN_SH reste celui du fork, il monte tout comme d'habitude, et on lui
# retire seulement les quatre modules de la chaine Calypso que c54x_exe assure
# (qemu, pty, osmocon, l2 — soit les etapes 2, 3 et 4 de son run.sh). Le banc
# DSP est lance juste apres, avec ses cinq etapes.
# BANC_DSP=<chemin> pour en designer un autre ; BANC_DSP=none le desactive.
DSP_BANC=0
DSP_MODULES_RETIRES="qemu,pty,osmocon,l2"
: "${BANC_DSP:=$GSM_ROOT/c54x_exe/run.sh}"
if [ "${DSP_MODE:-0}" = 1 ] && [ "$BANC_DSP" != none ] && [ -x "$BANC_DSP" ]; then
    DSP_BANC=1
elif [ "${DSP_MODE:-0}" = 1 ] && [ "$BANC_DSP" != none ]; then
    # Le defaut est le DSP, mais sans son banc : on le dit, et la chaine gr-gsm
    # prend le relais (CALYPSO_BRIDGE reste `pont`).
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

# ── LE BANC DSP : SON VOCABULAIRE ──────────────────────────────────────────
# c54x_exe/run.sh ne prend que --stop | --status | --logs | --step N, et rien
# d'autre : lui passer --profile le fait sortir sur « option inconnue ».
# Le coeur reseau, la BTS et le side-car restent montes par le plan du fork ;
# ce banc-ci n'assure que la chaine Calypso (ses cinq etapes).
# [2026-09-22] L'ARRET NE DEMANDE PAS --dsp.
# `./start-native.sh --stop` sans --dsp laissait c54x_exe, QEMU, osmocon, le
# mobile et pont.py debout : DSP_BANC vaut 0 quand --dsp n'est pas retape, et
# la pile paraissait arretee alors que cinq processus tenaient encore les ports
# 5700-5702 et /tmp/calypso_dsp.sock -- de quoi faire echouer le demarrage
# suivant sur un etat qu'on croit propre. On arrete donc le banc des qu'il
# existe ; son --stop ne fait rien de mal quand il ne tourne pas.
#
# ⚠️ MODE=dsp EXPLICITE A CHAQUE APPEL. start-native exporte son propre MODE
# (le profil : « faketrx-qemu »), et c54x_exe/run.sh lit la MEME variable pour
# choisir dsp|grgsm. Sans cela il sort sur
#     [run] ECHEC : MODE=faketrx-qemu inconnu (dsp|grgsm)
# et l'arret du banc ne se fait pas -- silencieusement, puisque l'appelant
# ignore son code de retour. Deux scripts, deux sens pour le meme nom : on ne
# renomme pas celui du banc (run_real.sh et les habitudes s'en servent), on
# pose la valeur a chaque fois.
# [2026-09-23] PulseAudio allege a chaque start : speech-dispatcher arrete,
# annuleur speex au lieu de webrtc, osmo_rec en 8 kHz mono (lib/audio.sh,
# alleger_audio). audio-chain.sh est idempotent ; AUDIO_ALLEGER=0 pour ne
# rien toucher, AUDIO_AEC_METHOD=webrtc pour garder l ancien annuleur.
audio_start() {
    [ -f "$HERE/scripts/audio-chain.sh" ] || return 0
    say_begin "Audio (PulseAudio allege)"
    if bash "$HERE/scripts/audio-chain.sh" 5 >/tmp/osmo-audio-chain.log 2>&1; then
        say_end " OK " "$C_OK" "Audio (PulseAudio allege)" "journal /tmp/osmo-audio-chain.log"
    else
        say_end " !! " "$C_KO" "Audio (PulseAudio allege)" "voir /tmp/osmo-audio-chain.log"
    fi
}

