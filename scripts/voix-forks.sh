#!/bin/bash
# =============================================================================
#  scripts/voix-forks.sh - les deux reglages de la voix qui vivent dans les FORKS
# =============================================================================
#
#  [2026-09-09] POURQUOI CE SCRIPT EXISTE.
#  La voix du banc depend de deux lignes qui ne sont PAS dans osmo-operator :
#  elles sont dans qosmo-grgsm et qosmo-dsp, deux depots que la mise a jour
#  resynchronise par « git reset --hard FETCH_HEAD ». Tout correctif pose a la
#  main dans ces arbres disparait au prochain demarrage. On les repose donc,
#  apres chaque fetch, depuis ici - et ce fichier est le SEUL a savoir comment.
#
#  1. « io-tch-format rtp » dans cfgs/mobile_group1.cfg.
#     C est le gabarit que run.sh (run_modules/20-mobile-cfg.sh) RECOPIE
#     par-dessus ~/.osmocom/bb/mobile_group1.cfg a chaque demarrage - il
#     ecrase donc ce que start-direct.sh a genere. Sans cette ligne, le mobile
#     lit et ecrit ses trames TCH dans la disposition Texas Instruments des
#     vrais Calypso, alors que pont.py les code avec libosmocoding, c est-a-dire
#     en disposition RTP/RFC3551 (33 octets ouverts par la signature 0xD). Les
#     deux bouts ne se comprennent DANS AUCUN SENS, aucun compteur ne bronche,
#     et la voix sort robotisee. Constate le 09/09 : les TROIS configurations
#     du banc tournaient sans elle.
#
#  2. CALYPSO_PULSE_LATENCY_MSEC dans run_modules/70-l2.sh et
#     68-sidecar-mobile.sh. Le mobile ecrit une trame GSM (160 echantillons,
#     20 ms) par snd_pcm_writei ; si le tampon du greffon ALSA-PulseAudio est
#     trop court, chaque ecriture rend -EPIPE, et pq_alsa.c y repond par un
#     snd_pcm_prepare() muet qui DEMONTE ET REMONTE le flux PulseAudio.
#     Mesure du 09/09, ecrivain cadence a 20 ms comme le mobile, 10 s :
#         80 ms -> 16 remontages   120 -> 19   160 -> 1   200 -> 0   240 -> 0
#     Pendant un appel reel : 50 par seconde. start-direct.sh exporte 320, ce
#     qui suffit ; on aligne le defaut des forks pour qui lance run.sh seul.
#
#  Appelants : update.sh (osmo_poser_voix_forks), le service osmo-update
#  genere par iso_modules/81-cloture-systeme.sh (juste apres le fetch), et
#  iso_modules/70-scripts.sh (sur le ROOTFS, a la construction de l ISO).
#
#  Usage : voix-forks.sh [prefixe]     (prefixe = un ROOTFS, vide par defaut)
#  Idempotent, sans effet si les forks sont absents, toujours exit 0.
#
#  JUGE : `grep io-tch-format ~/.osmocom/bb/mobile_group1.cfg` apres un
#  demarrage ; et pendant un appel etabli, l index du sink-input du mobile doit
#  rester FIXE (`pactl list short sink-inputs`, deux releves a 1 s d intervalle).
# -----------------------------------------------------------------------------
set -u
ROOT="${1:-}"
VOIX_LATENCE="${CALYPSO_PULSE_LATENCY_MSEC_DEFAUT:-320}"
VOIX_TCH_FORMAT="${MS_TCH_FORMAT:-rtp}"

voix_forks_poser() {
    local f n fait=0
    for f in "$ROOT/opt/GSM/qosmo-grgsm/cfgs/mobile_group1.cfg" \
             "$ROOT/opt/GSM/qosmo-dsp/cfgs/mobile_group1.cfg"; do
        [ -f "$f" ] || continue
        grep -q '^[[:space:]]*io-tch-format' "$f" && continue
        # Juste apres « io-handler », dans le bloc tch-voice, meme indentation.
        if sed -i '/^[[:space:]]*tch-voice[[:space:]]*$/,/^[[:space:]]*no shutdown/ s/^\([[:space:]]*\)io-handler\(.*\)$/\1io-handler\2\n\1io-tch-format '"$VOIX_TCH_FORMAT"'/' "$f" \
           && grep -q "io-tch-format ${VOIX_TCH_FORMAT}" "$f"; then
            echo "  [voix] ${f#"$ROOT"} : io-tch-format ${VOIX_TCH_FORMAT} repose (voix robotisee sinon)"; fait=1
        else
            echo "  [voix] ${f#"$ROOT"} : io-tch-format NON pose - a regarder a la main" >&2
        fi
    done
    for f in "$ROOT/opt/GSM/qosmo-grgsm/run_modules/70-l2.sh" \
             "$ROOT/opt/GSM/qosmo-grgsm/run_modules/68-sidecar-mobile.sh" \
             "$ROOT/opt/GSM/qosmo-dsp/run_modules/70-l2.sh" \
             "$ROOT/opt/GSM/qosmo-dsp/run_modules/68-sidecar-mobile.sh"; do
        [ -f "$f" ] || continue
        n="$(sed -n 's/^: "${CALYPSO_PULSE_LATENCY_MSEC:=\([0-9]*\)}"/\1/p' "$f" | head -1)"
        [ -n "$n" ] || continue
        [ "$n" -ge "$VOIX_LATENCE" ] 2>/dev/null && continue
        sed -i "s|^: \"\${CALYPSO_PULSE_LATENCY_MSEC:=[0-9]*}\"|: \"\\\${CALYPSO_PULSE_LATENCY_MSEC:=${VOIX_LATENCE}}\"|" "$f" \
            && { echo "  [voix] ${f#"$ROOT"} : tampon du mobile ${n} -> ${VOIX_LATENCE} ms (flux PulseAudio remonte sinon)"; fait=1; }
    done
    return 0
}
voix_forks_poser
exit 0
