# =============================================================================
#  lib/audio.sh - la chaine audio d'osmo-operator (PulseAudio + pont GAPK)
# =============================================================================
#
#  CE FICHIER EST UNE EXTRACTION, PAS UNE REECRITURE.
#  ensure_pulse / ensure_host_audio / ensure_gapk viennent telles quelles de
#  start-direct.sh.legacy (L566-722). Aucune ligne n'a ete retouchee.
#
#  POURQUOI LES PRESERVER.
#  Le mode `qemu` de start-direct.sh appelait ensure_gapk JUSTE AVANT de passer
#  la main a qosmo-grgsm/start-clean.sh (legacy L1077). C'est ce qui branche le RTP
#  du MGW sur le sink `gsm_audio` : sans lui, la pile monte, l'appel s'etablit,
#  et personne n'entend rien. Le chemin `qemu` devant continuer a marcher a
#  l'identique, cette precondition devait survivre au decoupage - on la deplace,
#  on ne la reinvente pas.
#
#  CE FICHIER NE FAIT RIEN AU SOURCE : il ne definit que des fonctions.
#  Appelant attendu : run_modules/25-audio.sh.
#
#  AUDIO=0 desactive toute la mise en place, exactement comme dans l'original.
# -----------------------------------------------------------------------------

: "${HERE:=/opt/GSM/osmo-operator}"
: "${LOG_DIR:=/root}"
: "${AUDIO:=1}"
: "${PULSE_SOCK:=/var/run/pulse/native}"
# L'original colorait ses messages ; sous `set -u` une couleur non definie
# ferait echouer la fonction avant meme d'avoir agi. On les neutralise.
RED='' GREEN='' YELLOW='' CYAN='' NC='' BOLD=''

# Les DEUX null-sinks de la chaine GSM, declares au meme endroit : gsm_audio
# (= alsa gsm_out, la voix qui SORT) et gsm_mic (= alsa gsm_in via
# gsm_mic.monitor, le micro silencieux qui ENTRE).
#
# [2026-08-12] gsm_mic n'etait cree QUE par scripts/pulse-gsm-setup.sh, que
# run.sh appelle ligne 422 - soit APRES osmo-start.sh (ligne 307). Un HLR qui ne
# demarre pas fait `exit 1` dans osmo-start.sh, le `set -euo pipefail` de run.sh
# tue tout, et le sink n'est jamais cree. Or gapk_io ABANDONNE LES DEUX SENS
# quand la capture echoue :
#     pq_alsa.c:168  Couldn't init ALSA device 'gsm_in': Input/output error
#     gapk_io.c:468  Failed to initialize GAPK I/O
# → appel parfaitement etabli mais TOTALEMENT muet, et l'erreur est enterree
# dans mobile.log. C'est le "ca marche sur un PC, pas sur l'autre" : le tirage
# au sort, c'est de savoir si le HLR est monte avant.
#
# Les deux sinks sont desormais SOLIDAIRES - ici, dans system.pa et dans le
# Dockerfile. Aucun ordre de script ne peut plus en perdre un.
# [2026-09-09] osmo_tts_off : un sink poubelle pour speech-dispatcher. Sur le
# banc, une appli du bureau declenche parfois la synthese vocale ; sans voix
# installee, le module « dummy » de speech-dispatcher joue son message factice
# (dummy-message.wav : 29 s, voix grave, 83 % de l energie sous 300 Hz, niveau
# 100 %) dans les haut-parleurs - par-dessus l appel en cours. Mesure : « voix
# saturee, grave », par intermittence, sur le 600. Une fois le flux deplace ici,
# module-stream-restore le renvoie ici a chaque apparition.
GSM_SINKS="gsm_audio:GSM_Audio gsm_mic:GSM_Mic osmo_tts_off:TTS_off"

load_gsm_sinks() {
    local entry name desc
    for entry in $GSM_SINKS; do
        name="${entry%%:*}"; desc="${entry##*:}"
        pactl list short sinks 2>/dev/null | grep -qw "$name" || \
            pactl load-module module-null-sink sink_name="$name" \
                format=s16le rate=8000 channels=1 \
                sink_properties=device.description="$desc" >/dev/null 2>&1 || true
    done
}

# ── Loopback local : gsm_audio.monitor → la carte son de la machine ──────────
# [2026-08-14] CE MAILLON N'EXISTAIT NULLE PART. Le commentaire de ensure_pulse
# ("en local l'hote entend via le module-loopback vers ses enceintes") le
# SUPPOSE deja present, mais aucun chemin du depot ne le chargeait :
#   - enable_user_loopback() de start.sh n'est appelee par personne ;
#   - network/loopback.sh n'est lance que sciemment, a la main.
# Resultat mesure dans la VM osmo-egprs : gsm_audio RUNNING (mobile ecrit
# dedans), gsm_audio.monitor IDLE (personne ne lit), sortie ALSA SUSPENDED,
# /proc/asound/card0/pcm0p/sub0/status = "closed". Appel etabli, zero son.
# gsm_audio est un module-null-sink : sans consommateur, la voix descendante est
# jetee PAR CONSTRUCTION. Ce n'est pas une panne, c'est un maillon manquant.
#
# ⚠️ Le choix du sink n'est pas cosmetique : reboucler sur gsm_audio ou gsm_mic
# recree la boucle fermee du 08/08 (cf. ensure_gapk : "les mobiles ecrivent
# dans gsm_out, on les rejouerait dans leur propre uplink"). On exclut donc
# explicitement les deux null-sinks et on ne garde qu'une sortie materielle.
# [2026-09-09] 40 ms et pas 20. PulseAudio repondait « Configured latency of
# 20.00 ms is smaller than minimum latency, using minimum instead » puis
# « Doing resync » a repetition : la latence minimale de ces sinks est de
# 26 ms, un bouclage qui en demande 20 se resynchronise sans arret et jette
# des echantillons (journal : « drop sink », « drop source »). 40 ms passe
# au-dessus du plancher, et 20 ms de plus sont inaudibles sur un appel.
LOOPBACK_LATENCY_MSEC="${LOOPBACK_LATENCY_MSEC:-40}"

# ── L AFFECTATION DES HAUT-PARLEURS ET DU MICRO : UN SEUL ENDROIT ───────────
# [2026-09-09] TROIS SCRIPTS SE DISPUTAIENT LES MEMES ROUTES. Le son du banc a
# deux modes : SANS telephone postmarketOS, l hote ecoute le descendant par un
# module-loopback direct (gsm_audio.monitor -> haut-parleurs) ; AVEC la VM, la
# voix doit passer PAR ELLE (carte « pont » 0x12 <-> carte « combine » 0x13,
# tools/osmo-pmos-setup.sh) et ce bouclage direct doit disparaitre, sinon on
# entend deux fois - le direct, puis la VM 500 ms plus tard - « voix pourrie ».
# Or scripts/audio-chain.sh (au boot, ExecStartPost de pulseaudio) et
# ensure_pulse (start-direct) reposaient le bouclage direct sans regarder si
# la VM etait la, pendant qu osmo-pmos-setup le retirait : le dernier passe
# gagnait. Et chacun choisissait « les haut-parleurs » a sa facon (sink par
# defaut, premiere carte alsa, osmo_hp_ec...), alors que le sink par defaut
# MEMORISE (osmo_hp_ec) n existe pas au boot - l annuleur d echo n arrivait
# qu avec la VM - et que les flux QEMU « combine » se posaient donc sur la
# carte brute, sans annuleur, le temps que le setup les deplace.
#
# Desormais :
#   audio_hw_sink / audio_hw_source   la carte son materielle (defaut si c en
#                                     est une, sinon la premiere alsa_*, HDMI
#                                     exclu) ;
#   audio_hp_sink / audio_mic_source  CE QUE L OPERATEUR ENTEND / DIT : l
#                                     annuleur d echo (osmo_hp_ec / osmo_mic_ec)
#                                     s il est charge, sinon le materiel ;
#   ensure_echo_cancel                charge cet annuleur (webrtc, sans AGC
#                                     analogique, micro a 25 %) et en fait le
#                                     defaut - au boot comme avec la VM ;
#   pmos_vm_audio_present             la VM postmarketOS a ses cartes son ici
#                                     (flux QEMU media.name=combine) ;
#   remove_direct_loopbacks           retire les bouclages directs ;
#   ensure_local_loopback / _mic      ne posent le direct QUE sans VM, vers
#                                     audio_hp_sink / depuis audio_mic_source,
#                                     et remplacent un bouclage pose vers une
#                                     autre sortie (la carte brute d avant l
#                                     annuleur, par exemple).
# osmo-pmos-qemu charge l annuleur AVANT de lancer QEMU et nomme ses sorties
# a la carte « combine » (OSMO_PMOS_HP / OSMO_PMOS_MIC, patch pmbootstrap) ;
# osmo-pmos-setup et l arret de la VM (pmos_stop) passent par ces fonctions.
# AUDIO_ECHO_CANCEL=0 pour se passer de l annuleur (les HP = la carte brute).
EC_AEC_ARGS='aec_args="analog_gain_control=0 digital_gain_control=1 noise_suppression=1 high_pass_filter=1"'
: "${EC_MIC_VOLUME:=25%}"

audio_hw_sink() {
    local d; d="$(pactl get-default-sink 2>/dev/null || true)"
    case "$d" in alsa_output.*) echo "$d"; return 0 ;; esac
    pactl list short sinks 2>/dev/null \
        | awk '$2 ~ /^alsa_output/ && $2 !~ /hdmi/ { print $2; exit }'
}
audio_hw_source() {
    local d; d="$(pactl get-default-source 2>/dev/null || true)"
    case "$d" in alsa_input.*) echo "$d"; return 0 ;; esac
    pactl list short sources 2>/dev/null \
        | awk '$2 ~ /^alsa_input/ && $2 !~ /\.monitor$/ { print $2; exit }'
}
audio_hp_sink() {
    pactl list short sinks 2>/dev/null | awk '$2 == "osmo_hp_ec" { f=1 } END { exit !f }' \
        && { echo osmo_hp_ec; return 0; }
    audio_hw_sink
}
audio_mic_source() {
    pactl list short sources 2>/dev/null | awk '$2 == "osmo_mic_ec" { f=1 } END { exit !f }' \
        && { echo osmo_mic_ec; return 0; }
    audio_hw_source
}

# ── QUI PORTE LA VOIX : L HOTE, OU LA VM ? ──────────────────────────────────
# [2026-09-09] PAR DEFAUT, L HOTE. Le telephone postmarketOS est l INTERFACE du
# banc (composer, decrocher, les SMS) ; il n a pas besoin de porter les
# echantillons. Le faire coutait cher et s entendait : micro -> QEMU -> Pulse
# de la VM -> module-loopback 400 ms -> QEMU -> gsm_mic, et autant au retour,
# soit ~800 ms d aller-retour, deux rythmes d horloge emules, et le
# rechantillonnage de deux cartes HDA a 44,1 kHz pour un signal telephonique a
# 8 kHz. Mesure et verdict de l operateur : « le son est bon sans pmOS ».
#
# Donc : la voix reste sur l hote (gsm_audio -> haut-parleurs, micro ->
# gsm_mic, 40 ms), et la VM garde ses cartes pour ce qui la regarde - sonnerie,
# notifications, l application Appels. Elle reste dans le trajet de la
# SIGNALISATION, qui est son vrai role.
#
# Pour remettre la voix DANS la VM (l ancien montage croise, si l on veut
# vraiment l entendre traverser le telephone) : OSMO_PMOS_VOIX_VM=1 au
# lancement d osmo-pmos-setup. Il pose alors les deux bouclages dans la VM et
# depose ce marqueur ; les fonctions ci-dessous retirent alors les bouclages
# directs de l hote, sans quoi la voix arriverait DEUX fois - en direct, puis
# par la VM 400 ms plus tard, ce qui etait le defaut du 09/09.
PMOS_VOIX_VM_MARQUEUR="${PMOS_VOIX_VM_MARQUEUR:-/run/osmo-pmos-voix-vm}"

# Vrai seulement si la VM porte VRAIMENT la voix : le marqueur ET le processus.
# Un marqueur oublie par une VM tuee sans menagement ne doit pas priver l hote
# de ses haut-parleurs.
pmos_vm_audio_present() {
    [ -f "$PMOS_VOIX_VM_MARQUEUR" ] || return 1
    pgrep -f 'qemu-system.*hdac[o]mbine' >/dev/null 2>&1 && return 0
    pactl list sink-inputs 2>/dev/null | grep -q 'media.name = "combine"'
}


remove_direct_loopbacks() {
    local m n=0
    for m in $(pactl list short modules 2>/dev/null \
               | awk '/module-loopback/ && (/source=gsm_audio\.monitor/ || /sink=gsm_mic([ \t]|$)/) { print $1 }'); do
        pactl unload-module "$m" >/dev/null 2>&1 && n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] && echo -e "  ${YELLOW}[audio] ${n} bouclage(s) direct(s) retire(s)${NC}"
    return 0
}

# [2026-09-08/09] L ANNULEUR D ECHO ENTRE LE MICRO ET LES HAUT-PARLEURS.
# Micro interne + haut-parleurs : l echo du 600 se reinjectait dans le micro
# (2 400 de crete HP coupe, 32 768 sature HP ouvert) : Larsen. Et l AGC
# analogique de webrtc, laisse par defaut, promenait le gain du micro de 100 %
# a 0 % d une minute a l autre (voix ecrasee, 93 % de l energie sous 300 Hz a
# l entree du GSM). Donc : webrtc sans AGC analogique, micro fixe a 25 % (il
# sature des 45 %), et un demutage explicite - module-device-restore rend
# parfois le module muet. Le volume d osmo_mic_ec est PARTAGE avec le micro
# materiel : meme valeur pour les deux.
ensure_echo_cancel() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_ECHO_CANCEL:-1}" = "1" ] || {
        echo -e "  ${YELLOW}[audio] annuleur d echo desactive (AUDIO_ECHO_CANCEL=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0
    local mic hp
    mic="$(audio_hw_source)"; hp="$(audio_hw_sink)"
    if [ -z "$mic" ] || [ -z "$hp" ]; then
        echo -e "  ${YELLOW}[audio] pas de micro ou de haut-parleur materiel - annuleur d echo ignore${NC}"; return 0
    fi
    # Le defaut (osmo_hp_ec / osmo_mic_ec) n est pose qu au CHARGEMENT : le
    # rejouer a chaque passage renvoyait vers l annuleur les flux que l
    # operateur venait de mettre ailleurs. Tout ce qui compte pour la chaine
    # GSM est epingle par nom - le defaut n est plus qu une affaire de bureau.
    if pactl list short modules 2>/dev/null | grep -q 'module-echo-cancel'; then
        echo -e "  ${GREEN}[audio] annuleur d echo deja en place (osmo_hp_ec / osmo_mic_ec)${NC}"
        return 0
    # [2026-09-09] 8000 Hz MONO, COMME TOUT LE RESTE DU BANC. Sans « rate », le
    # module se charge a 32000 Hz : c est ce que montrait « pactl list short
    # sinks » (osmo_hp_ec en float32le 1ch 32000Hz) alors que gsm_audio, gsm_mic
    # et osmo_tts_off sont tous en s16le 1ch 8000Hz. Chaque traversee de
    # l annuleur coutait donc deux reechantillonnages - 8000 -> 32000 a l entree,
    # 32000 -> 8000 a la sortie - visibles dans les flux :
    #     Loopback from Micro_sans_echo ... 1ch 32005Hz  -> sink gsm_mic (8000)
    # Le signal est de toute facon borne a 4 kHz par le GSM : les 32 kHz ne
    # portaient rien de plus. L annuleur webrtc accepte 8000/16000/32000/48000 ;
    # 8000 verifie a la main avant d etre pose ici (module charge, sinks lus en
    # « float32le 1ch 8000Hz », module decharge).
    elif pactl load-module module-echo-cancel aec_method=webrtc \
            rate=8000 channels=1 \
            source_master="$mic" sink_master="$hp" \
            source_name=osmo_mic_ec sink_name=osmo_hp_ec "$EC_AEC_ARGS" \
            source_properties=device.description=Micro_sans_echo \
            sink_properties=device.description=HP_sans_echo >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] annuleur d echo pose entre ${mic} et ${hp} (sans AGC analogique)${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec de l annuleur d echo - les HP restent ${hp}${NC}"; return 0
    fi
    pactl set-default-sink osmo_hp_ec >/dev/null 2>&1
    pactl set-default-source osmo_mic_ec >/dev/null 2>&1
    pactl set-sink-mute "$hp" 0 2>/dev/null;       pactl set-sink-mute osmo_hp_ec 0 2>/dev/null
    pactl set-source-mute "$mic" 0 2>/dev/null;    pactl set-source-volume "$mic" "$EC_MIC_VOLUME" 2>/dev/null
    pactl set-source-mute osmo_mic_ec 0 2>/dev/null; pactl set-source-volume osmo_mic_ec "$EC_MIC_VOLUME" 2>/dev/null
    return 0
}

# ── La source d ENREGISTREMENT : ce qu on entend + ce qu on dit ─────────────
# [2026-09-09] « pourquoi j ai pas l enregistrement ». L enregistreur d ecran
# (extension EasyScreenCast, menu « audio source ») ne sait capter qu une
# SOURCE PulseAudio. Or un appel ne vit pas sur une source : le descendant va
# dans des sinks (gsm_audio, puis les haut-parleurs), et seul le micro est une
# source. Resultat : « No audio source » enregistre le silence, et choisir le
# micro n enregistre que la voix de l operateur, jamais le correspondant.
#
# On fabrique donc UN sink poubelle, osmo_rec, alimente par les deux cotes :
#   - le moniteur des haut-parleurs de l operateur (tout ce qu il ENTEND, que
#     la voix vienne du bouclage direct ou du telephone postmarketOS) ;
#   - son micro (tout ce qu il DIT).
# Son moniteur, osmo_rec.monitor, apparait alors dans le menu de l enregistreur
# sous « Enregistrement_appel » : un seul choix, et l appel entier est dedans.
# 48 kHz stereo : c est une piste video, pas du GSM ; PulseAudio reechantillonne
# les 8 kHz une fois pour toutes, ici, hors du chemin de la voix.
# AUDIO_RECORD_MIX=0 pour ne pas la creer.
ensure_record_mix() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_RECORD_MIX:-1}" = "1" ] || return 0
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sinks 2>/dev/null | grep -qw osmo_rec \
        || pactl load-module module-null-sink sink_name=osmo_rec \
               format=s16le rate=48000 channels=2 \
               sink_properties=device.description=Enregistrement_appel >/dev/null 2>&1 \
        || { echo -e "  ${YELLOW}[audio] sink osmo_rec impossible - enregistrement non prepare${NC}"; return 0; }

    local hp mic src
    hp="$(audio_hp_sink)"; mic="$(audio_mic_source)"
    for src in ${hp:+${hp}.monitor} ${mic:-}; do
        # Idempotent, et epingle comme les autres (cf. le bloc dont_move).
        pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
            | grep -F "source=${src}" | grep -qF 'sink=osmo_rec' && continue
        pactl load-module module-loopback source="$src" sink=osmo_rec \
            sink_dont_move=true source_dont_move=true \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1
    done
    echo -e "  ${GREEN}[audio] source d enregistrement prete : osmo_rec.monitor (Enregistrement_appel)${NC}"
    # L enregistreur d ecran s en souvient par son nom d application
    # (module-stream-restore) : on le deplace une fois, il y revient ensuite.
    local so
    for so in $(pactl list source-outputs 2>/dev/null \
                | awk '/Source Output #/{id=$3} /application.name = ".*[Ss]creen[Cc]ast|.*Shell.Screencast/{print id}' | tr -d '#'); do
        pactl move-source-output "$so" osmo_rec.monitor 2>/dev/null \
            && echo -e "  ${GREEN}[audio] enregistreur d ecran bascule sur osmo_rec.monitor${NC}"
    done
    return 0
}

ensure_local_loopback() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_LOCAL_LOOPBACK:-1}" = "1" ] || {
        echo -e "  ${YELLOW}[audio] loopback local desactive (AUDIO_LOCAL_LOOPBACK=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sources 2>/dev/null | grep -qw 'gsm_audio.monitor' || {
        echo -e "  ${YELLOW}[audio] gsm_audio.monitor absent - loopback local ignore${NC}"; return 0; }

    # Avec le telephone postmarketOS, la voix passe par la VM : pas de direct.
    if pmos_vm_audio_present; then
        echo -e "  ${GREEN}[audio] telephone postmarketOS en place - l ecoute passe par la VM, pas de bouclage direct${NC}"
        remove_direct_loopbacks
        return 0
    fi

    local sink
    sink="$(audio_hp_sink)"
    [ -n "$sink" ] || {
        echo -e "  ${YELLOW}[audio] aucune sortie materielle - loopback local ignore${NC}"; return 0; }

    # Idempotent : ne pas empiler un 2e loopback (voix doublee + echo)...
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F 'source=gsm_audio.monitor' | grep -F "sink=${sink}" | grep -qF 'sink_dont_move=true'; then
        echo -e "  ${GREEN}[audio] loopback local deja en place → ${sink}${NC}"
        return 0
    fi
    # ...et ne pas en garder un vers une AUTRE sortie (la carte brute posee
    # avant l annuleur d echo, par exemple).
    local m
    for m in $(pactl list short modules 2>/dev/null \
               | awk '/module-loopback/ && /source=gsm_audio\.monitor/ { print $1 }'); do
        pactl unload-module "$m" >/dev/null 2>&1
    done

    # [2026-09-09] EPINGLE. PulseAudio 16 deplace tout flux non epingle vers le
    # nouveau peripherique par defaut (set-default-sink / GNOME « Sortie ») :
    # mesure - un clic dans les reglages son et ce bouclage lisait le MICRO
    # (source par defaut) pour le jouer dans la carte brute (sink par defaut).
    # Larsen, plus rien sur gsm_audio, « son pourri ». dont_move le rend sourd
    # aux changements de defaut : il ne bouge que si on le decharge.
    if pactl load-module module-loopback \
            source=gsm_audio.monitor sink="$sink" \
            sink_dont_move=true source_dont_move=true \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] loopback local charge : gsm_audio.monitor → ${sink} (${LOOPBACK_LATENCY_MSEC} ms)${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec du loopback local vers ${sink}${NC}"
    fi
}

# ── Micro local : la carte son de la machine → gsm_mic ─────────────────
# [2026-08-31] SYMETRIQUE de ensure_local_loopback, et il manquait pareil. Le
# montant (ce que le mobile EMET vers le reseau) part de gsm_in, c'est-a-dire de
# gsm_mic.monitor - un null-sink que PERSONNE n'alimentait depuis la machine.
# Le seul producteur etait la console web : le navigateur capturait le micro,
# poussait les echantillons a /opt/GSM/osmo-egprs-web/server.js, qui les
# reinjectait via `pacat --playback -d gsm_mic`. Chemin mesure le 31/08 :
# 3 a 4 secondes de retard sur la voix montante, alors que TOUT le trajet
# PulseAudio tient sous 100 ms (pacat 45 ms, capture du mobile 0 us, loopback
# descendant 20 ms). Le tampon n'est donc pas dans PulseAudio mais dans le
# transport navigateur -> node -> socket, qu'aucun reglage pulse n'atteint.
# Un module-loopback depuis la carte son supprime ce transport au lieu de
# l'accelerer : le micro alimente gsm_mic directement, en 20 ms.
#
# ⚠️ DEUX SOURCES A NE JAMAIS PRENDRE ICI :
#   - gsm_audio.monitor : c'est le DESCENDANT. Le rejouer dans le montant, c'est
#     exactement la boucle fermee du 08/08 (RMS x11 en 10 s) que le commentaire
#     d'/etc/asound.conf documente. On ne garde qu'une entree MATERIELLE.
#   - gsm_mic.monitor : le sink qu'on alimente - il se recopierait sur lui-meme.
#
# ⚠️ Boucle ACOUSTIQUE : le descendant sort sur les enceintes (loopback
# ci-dessus) et le micro les reentend. Au casque c'est sans objet ; sur
# haut-parleurs, couper l'un des deux ou baisser le volume.
AUDIO_LOCAL_MIC="${AUDIO_LOCAL_MIC:-1}"

ensure_local_mic() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "$AUDIO_LOCAL_MIC" = "1" ] || {
        echo -e "  ${YELLOW}[audio] micro local desactive (AUDIO_LOCAL_MIC=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sinks 2>/dev/null | grep -qw 'gsm_mic' || {
        echo -e "  ${YELLOW}[audio] sink gsm_mic absent - micro local ignore${NC}"; return 0; }

    # Avec le telephone postmarketOS, c est la VM qui alimente gsm_mic.
    if pmos_vm_audio_present; then
        echo -e "  ${GREEN}[audio] telephone postmarketOS en place - le micro passe par la VM, pas de bouclage direct${NC}"
        remove_direct_loopbacks
        return 0
    fi

    # Entree = le micro de l operateur (annuleur d echo s il est la, sinon le
    # materiel) - jamais un .monitor (voir l avertissement ci-dessus).
    local src
    src="$(audio_mic_source)"
    [ -n "$src" ] || {
        echo -e "  ${YELLOW}[audio] aucune entree materielle - micro local ignore${NC}"; return 0; }

    # Idempotent : un 2e loopback doublerait la voix montante...
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F "source=${src}" | grep -F 'sink=gsm_mic' | grep -qF 'sink_dont_move=true'; then
        echo -e "  ${GREEN}[audio] micro local deja en place : ${src} → gsm_mic${NC}"
        return 0
    fi
    # ...et pas un depuis une AUTRE entree.
    local m
    for m in $(pactl list short modules 2>/dev/null \
               | awk '/module-loopback/ && /sink=gsm_mic([ \t]|$)/ { print $1 }'); do
        pactl unload-module "$m" >/dev/null 2>&1
    done

    if pactl load-module module-loopback \
            source="$src" sink=gsm_mic \
            sink_dont_move=true source_dont_move=true \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] micro local charge : ${src} → gsm_mic (${LOOPBACK_LATENCY_MSEC} ms)${NC}"
        echo -e "  ${CYAN}       → la console web n'est plus necessaire pour parler.${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec du micro local depuis ${src}${NC}"
    fi
}

# Post-condition : les PCM que `mobile` va reellement ouvrir s'ouvrent-ils ?
# Tester le sink avec `pactl list sinks` ne suffit pas - c'est le mapping ALSA
# de /etc/asound.conf qui casse (gsm_in → gsm_mic.monitor). On ouvre pour de
# vrai, 1 s de chaque cote, et on gueule si ca rate. Sans ca la panne est
# silencieuse jusqu'au premier appel muet.
assert_audio_devices() {
    command -v aplay >/dev/null 2>&1 || return 0
    local ko=0
    timeout 5 aplay  -D gsm_out -f S16_LE -r 8000 -c 1 -d 1 /dev/zero >/dev/null 2>&1 || {
        echo -e "  ${RED}[audio] KO : lecture 'gsm_out' impossible (sink gsm_audio ?)${NC}"; ko=1; }
    timeout 5 arecord -D gsm_in  -f S16_LE -r 8000 -c 1 -d 1 /dev/null  >/dev/null 2>&1 || {
        echo -e "  ${RED}[audio] KO : capture 'gsm_in' impossible (sink gsm_mic ?)${NC}"; ko=1; }
    if [ "$ko" = "1" ]; then
        echo -e "  ${RED}       → gapk_io va echouer et l'appel sera MUET DANS LES DEUX SENS.${NC}"
        echo -e "  ${RED}       → pactl list short sinks  (attendu : gsm_audio ET gsm_mic)${NC}"
        return 1
    fi
    echo -e "  ${GREEN}[audio] gsm_out (lecture) + gsm_in (capture) ouverts - chaine OK${NC}"
    return 0
}

ensure_pulse() {
    [ "${AUDIO:-1}" = "1" ] || { echo -e "  ${YELLOW}[audio] desactive (AUDIO=0)${NC}"; return 0; }

    # 0. Mapping ALSA gsm_out/gsm_in → sink PulseAudio gsm_audio (REQUIS cote hote
    #    en mode natif). Sans /etc/asound.conf, le `mobile` (io-handler gapk,
    #    alsa-output-dev gsm_out) ouvre un PCM ALSA inexistant → "Unknown PCM
    #    gsm_out" → l'audio TCH n'est jamais decode vers gsm_audio → silence
    #    navigateur. Le sink seul ne suffit pas : ce mapping doit exister.
    if [ -f "$HERE/configs/asound.conf" ] && ! cmp -s "$HERE/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        cp -f "$HERE/configs/asound.conf" /etc/asound.conf \
            && echo -e "  ${GREEN}[audio] /etc/asound.conf deploye (ALSA gsm_out/gsm_in → pulse gsm_audio)${NC}"
    fi

    export PULSE_SERVER="unix:${PULSE_SOCK}"
    if pactl info >/dev/null 2>&1; then
        # PulseAudio deja actif (service osmo-pulse au boot, ou un 'fake' solo
        # precedent). Le sink gsm_audio n'est PAS forcement charge dans CE demon
        # -> on le (re)charge a la volee s'il manque. SANS ca : l'audio ne marchait
        # qu'apres un 'fake' solo (qui avait pose le sink) - c'est le maillon qui
        # manquait a fake+qemu pour avoir l'audio de lui-meme.
        load_gsm_sinks
        # Dedoublonnage : sur une PipeWire/Pulse PARTAGEE entre containers, chaque
        # ensure_pulse charge son propre module-null-sink gsm_audio → doublons.
        # parec (flux /audio du dashboard) lit alors le monitor d'un sink que gapk
        # n'alimente PAS → audio muet pour les clients distants (navigateur/Windows ;
        # en local l'hote entend via le module-loopback vers ses enceintes, d'ou
        # "ca marche sur Linux mais pas sur Windows"). On garde UN seul gsm_audio
        # (le 1er module) et on decharge les suivants.
        # (le dedoublonnage vaut pour gsm_mic autant que pour gsm_audio : un
        #  gsm_mic en double et gapk capture le monitor du mauvais sink)
        local _entry _name
        for _entry in $GSM_SINKS; do
            _name="${_entry%%:*}"
            pactl list short modules 2>/dev/null \
                | awk -v s="$_name" '/module-null-sink/ && $0 ~ ("sink_name=" s "([ \t]|$)") {print $1}' \
                | tail -n +2 \
                | while read -r _m; do [ -n "$_m" ] && pactl unload-module "$_m" >/dev/null 2>&1 \
                    && echo -e "  ${YELLOW}[audio] sink ${_name} en double decharge (module $_m)${NC}"; done
        done
        echo -e "  ${GREEN}[audio] PulseAudio deja actif (sinks gsm_audio + gsm_mic uniques assures)${NC}"
        assert_audio_devices || true
        ensure_local_loopback
        ensure_local_mic
        ensure_record_mix
        return 0
    fi

    # 1. Installer pulseaudio si absent (le binaire demon, pas que les clients)
    if ! command -v pulseaudio >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "  ${YELLOW}[audio] installation pulseaudio...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                pulseaudio pulseaudio-utils alsa-utils >/dev/null 2>&1 || true
        fi
    fi
    command -v pulseaudio >/dev/null 2>&1 || {
        echo -e "  ${YELLOW}[audio] pulseaudio indisponible - audio ignore${NC}"; return 0; }

    # 2. Config system.pa : acces anonyme + les DEUX sinks null (idempotent).
    #    Les declarer ici plutot que de compter sur un load-module au runtime
    #    est ce qui rend la chaine robuste : ils existent des le demarrage du
    #    demon, y compris si le demon redemarre tout seul plus tard.
    local sp=/etc/pulse/system.pa
    if [ -f "$sp" ]; then
        grep -q 'auth-anonymous=1' "$sp" || sed -i \
            's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' "$sp"
        local _entry _name _desc
        for _entry in $GSM_SINKS; do
            _name="${_entry%%:*}"; _desc="${_entry##*:}"
            grep -q "sink_name=${_name}\b" "$sp" || \
                echo "load-module module-null-sink sink_name=${_name} format=s16le rate=8000 channels=1 sink_properties=device.description=${_desc}" >> "$sp"
        done
    fi

    # 3. (Re)demarrer le demon systeme - SERIALISE
    mkdir -p /var/run/pulse "$LOG_DIR"
    # ensure_pulse est appele en parallele (flux principal + ensure_gapk via la
    # session tmux 'gapk') → deux 'pulseaudio --system' se lancaient en meme
    # temps et se disputaient /var/run/pulse/native → "bind(): Address already
    # in use" → le module socket echoue → demon mort → injoignable.
    # flock garantit UN SEUL (re)demarrage a la fois ; un demon residuel detenant
    # un socket perime (parfois sous un autre uid) est tue et le socket efface
    # par root avant le bind.
    (
        flock 9
        if ! pactl info >/dev/null 2>&1; then
            pkill -x pulseaudio 2>/dev/null || true
            local _k=10
            while pgrep -x pulseaudio >/dev/null 2>&1 && [ $_k -gt 0 ]; do sleep 0.3; ((_k--)) || true; done
            pkill -9 -x pulseaudio 2>/dev/null || true
            rm -f /var/run/pulse/pid /var/run/pulse/native 2>/dev/null || true
            chown -R pulse:pulse /var/run/pulse 2>/dev/null || true
            pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 \
                --log-target="file:${LOG_DIR}/pulse-system.log" >/dev/null 2>&1 || true
            local r=10
            while [ $r -gt 0 ]; do pactl info >/dev/null 2>&1 && break; sleep 1; ((r--)) || true; done
        fi
    ) 9>/run/osmo-pulse.lock

    if pactl info >/dev/null 2>&1; then
        load_gsm_sinks
        echo -e "  ${GREEN}[audio] PulseAudio pret (sinks gsm_audio + gsm_mic) @ ${PULSE_SOCK}${NC}"
        assert_audio_devices || true
        ensure_local_loopback
        ensure_local_mic
        ensure_record_mix
    else
        echo -e "  ${YELLOW}[audio] PulseAudio injoignable - audio degrade${NC}"
        echo -e "  ${YELLOW}        → voir ${LOG_DIR}/pulse-system.log${NC}"
    fi
}

# ── Bridge audio : osmo-gapk auto (chemin reseau MGW RTP → sink gsm_audio) ────
# gapk auto poll le VTY OsmoMGW (4243) et bridge le RTP de CHAQUE appel vers
# alsa://gsm_out (= sink null PulseAudio gsm_audio). C'est ce maillon qui rend
# l'audio des appels "reseau" (ex: 600 = echo-test Asterisk via MGW) audible
# dans le dashboard web : server.js capte gsm_audio.monitor → /audio (MP3).
# Lance en session tmux DETACHEE 'gapk' : survit aux 'exec' (start-clean.sh /
# tmux attach) des modes qemu/hybride et poll jusqu'a ce que le MGW soit up.
# Idempotent (relance la session), non-fatal. AUDIO=0 → desactive.
# Pont voix conteneur → hote : parec(gsm_audio.monitor) | paplay(--server=relai).
# run.sh (no-process) tente ce pont AVANT que PulseAudio soit pret (course →
# "PulseAudio injoignable apres 30s" → pont jamais lance → VOIX MUETTE dans docker).
# On le (re)lance ICI, apres ensure_pulse (sink gsm_audio garanti up). Idempotent,
# gated sur HOST_AUDIO_RELAY (pose par start.sh = tcp:<gw>:4713).
ensure_host_audio() {
    local relay="${HOST_AUDIO_RELAY:-}"
    [ -n "$relay" ] || return 0
    if ! pactl --server="$relay" info >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[host-audio] relai ${relay} injoignable - pont voix non lance${NC}"; return 0
    fi
    # ── UN SEUL PONT POUR TOUT LE BANC ──────────────────────────────────────
    # [2026-08-31] LE SON ETAIT ENTENDU EN DOUBLE A PARTIR DE DEUX OPERATEURS.
    # Le `pkill` plus bas s execute DANS le conteneur, qui a son propre espace de
    # PID : il ne voit JAMAIS le pont du voisin. Chaque operateur demarrait donc
    # le sien, et comme ils poussent tous vers le MEME PulseAudio d hote, on
    # entendait l appel deux fois a deux operateurs, trois fois a trois.
    # On interroge donc le SERVEUR PARTAGE, pas la table des processus locale :
    # un client deja connecte sous ce nom veut dire qu un pont tourne quelque
    # part, peu importe dans quel conteneur.
    #
    # ⚠️ scripts/run.sh (audio_bridge) porte le MEME garde-fou. Les deux copies
    # doivent garder LE MEME nom de client : c est par ce nom qu elles se voient.
    # C est precisement ce qui manquait ici - le correctif n avait ete pose que
    # sur run.sh, et cette copie-ci lancait un pont ANONYME, donc invisible au
    # garde-fou de l autre, qui en ajoutait un second.
    local _bridge_name="osmo-gsm-bridge"
    if pactl --server="$relay" list clients 2>/dev/null \
         | grep -q "application.name = \"${_bridge_name}\""; then
        echo -e "  ${GREEN}[host-audio] pont deja actif sur l hote (${relay}) - on n en ajoute pas un second${NC}"
        return 0
    fi
    # ── NI DOUBLON AVEC LE LOOPBACK DE L HOTE ───────────────────────────────
    # L hote charge deja son module-loopback gsm_audio.monitor -> carte son
    # (ensure_local_loopback, plus haut dans ce fichier). C est le MEME travail
    # que ce pont : meme source, meme sortie. Les deux ensemble, tout est entendu
    # DEUX FOIS - et le symptome survit a l arret d un conteneur, ce qui fait
    # chercher le doublon du mauvais cote. On garde le loopback : il est cote
    # hote et bien plus court (20 ms contre 250 ms pour le pont TCP).
    if pactl --server="$relay" list short modules 2>/dev/null \
         | grep -q 'source=gsm_audio.monitor'; then
        echo -e "  ${GREEN}[host-audio] loopback gsm_audio deja en place sur l hote - pont TCP inutile${NC}"
        return 0
    fi
    pkill -f "paplay --server=${relay}" 2>/dev/null || true          # idempotent (local)
    [ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
    # parec lit le pulse LOCAL (gsm_audio.monitor) ; paplay pousse vers l'hote.
    # --latency-msec : capture courte (30ms) + lecture TAMPONNEE (250ms) pour
    # absorber la gigue (ordonnancement/TCP/2 horloges pulse) - sinon voix HACHEE.
    # --client-name : c est LUI qui rend ce pont visible au garde-fou ci-dessus,
    # depuis n importe quel conteneur. Sans lui, chacun se croit seul.
    setsid env PULSE_SERVER="unix:${PULSE_SOCK}" sh -c '
      while true; do
        parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
          | paplay --server='"${relay}"' --client-name='"${_bridge_name}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
        sleep 1
      done' >"${LOG_DIR}/host-audio.log" 2>&1 &
    echo $! > /run/host-audio.pid
    echo -e "  ${GREEN}[host-audio] pont voix parec|paplay → hote (${relay})${NC}"
}

ensure_gapk() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    command -v tmux      >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] tmux absent - bridge audio non lance${NC}"; return 0; }
    command -v osmo-gapk >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] osmo-gapk absent - bridge audio non lance${NC}"; return 0; }
    ensure_pulse   # gapk ecrit dans alsa://gsm_out = sink gsm_audio (idempotent)
    local gapk_sh="/etc/osmocom/gapk-start.sh"; [ -x "$gapk_sh" ] || gapk_sh="$HERE/scripts/gapk-start.sh"
    [ -x "$gapk_sh" ] || { echo -e "  ${YELLOW}[gapk] gapk-start.sh introuvable - bridge audio non lance${NC}"; return 0; }
    tmux kill-session -t gapk 2>/dev/null || true
    # [2026-08-10] Le format etait code en dur a "gsmfr", un nom qui n'existe
    # pas dans osmo-gapk : les deux process mouraient a l'analyse des arguments
    # ("Unsupported format: gsmfr") et le pont n'a jamais rien transporte.
    # Le nom du GSM FR est "gsm". Le 3e argument est le peripherique de
    # CAPTURE : il doit rester gsm_in (moniteur du null-sink gsm_mic). Le
    # pointer sur gsm_out rebranche la boucle fermee du 08/08 - les mobiles
    # ecrivent dans gsm_out, on les rejouerait dans leur propre uplink.
    tmux new-session -d -s gapk \
        "GAPK_ALSA_DEV=gsm_out GAPK_ALSA_DEV_IN=gsm_in PULSE_SERVER=unix:${PULSE_SOCK} bash '$gapk_sh' auto gsm gsm_out gsm_in 2>&1 | tee ${LOG_DIR}/gapk-auto.log"
    # [2026-08-26] LA FENETRE "exited".
    # `tmux new-session -d` rend 0 des que le serveur a pris la commande, pas
    # quand celle-ci tourne. Si gapk-start.sh rend la main tout de suite - format
    # refuse, sink pas encore la, binaire absent - la fenetre reste affichee avec
    # "[exited]" en travers, et le message vert ci-dessous annonce quand meme un
    # pont audio en place. On attend donc une seconde, et on regarde.
    # La session morte est retiree : une fenetre "exited" au milieu des autres
    # fait chercher une panne dans la pile alors que c'est le pont audio, seul,
    # qui n'a pas demarre - et le journal, lui, dit pourquoi.
    sleep 1
    if tmux has-session -t gapk 2>/dev/null && \
       [ "$(tmux list-panes -t gapk -F '#{pane_dead}' 2>/dev/null | head -1)" != "1" ]; then
        echo -e "  ${GREEN}[gapk] auto lance (RTP MGW → sink gsm_audio) - tmux 'gapk', log ${LOG_DIR}/gapk-auto.log${NC}"
    else
        tmux kill-session -t gapk 2>/dev/null || true
        echo -e "  ${YELLOW}[gapk] mort au demarrage - pas de pont audio (fenetre retiree)${NC}"
        echo -e "         ${CYAN}tail -20 ${LOG_DIR}/gapk-auto.log${NC}"
    fi
    ensure_host_audio   # (re)lance le pont voix → hote maintenant que pulse+sink sont up
}

# ══════════════════════════════════════════════════════════════════════════
# Modes 1 operateur (host loopback + enp0s3) : noproc/faketrx/virtphy/qemu/combine
# ══════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════
# Mode HYBRIDE faketrx-qemu (Approche C) : 2 osmo-bts-trx, 1 coeur
#   BTS#0 = pipeline QEMU INTOUCHE (run.sh : osmo-trx-ipc 5700, ARFCN 514, Calypso)
#   BTS#1 = side-car : osmo-bts-trx (unit-id 6002, base-port 5820/5720) + fake_trx
#           (-P 5720 -p 6720) + trxcon + mobile osmocom-bb (ARFCN 516, IMSI ...0002)
#   Les 2 MS s'enregistrent sur le meme osmo-bsc/MSC/HLR → appel intra-MSC.
#   1 BTS = 1 horloge (clk_s par process osmo-bts-trx) → pas de conflit d'horloge :
#   une seule osmo-bts-trx 2-PHY est IMPOSSIBLE (clk_s partage, reset ping-pong),
#   d'ou 2 process distincts. On NE TOUCHE NI qosmo-grgsm/run.sh NI osmo-bts-trx.cfg.
# ══════════════════════════════════════════════════════════════════════════
