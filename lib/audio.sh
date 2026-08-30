# =============================================================================
#  lib/audio.sh - la chaine audio d'osmo_egprs (PulseAudio + pont GAPK)
# =============================================================================
#
#  CE FICHIER EST UNE EXTRACTION, PAS UNE REECRITURE.
#  ensure_pulse / ensure_host_audio / ensure_gapk viennent telles quelles de
#  start-direct.sh.legacy (L566-722). Aucune ligne n'a ete retouchee.
#
#  POURQUOI LES PRESERVER.
#  Le mode `qemu` de start-direct.sh appelait ensure_gapk JUSTE AVANT de passer
#  la main a qemu-src/start-clean.sh (legacy L1077). C'est ce qui branche le RTP
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

: "${HERE:=/opt/GSM/osmo_egprs}"
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
GSM_SINKS="gsm_audio:GSM_Audio gsm_mic:GSM_Mic"

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
LOOPBACK_LATENCY_MSEC="${LOOPBACK_LATENCY_MSEC:-20}"

ensure_local_loopback() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_LOCAL_LOOPBACK:-1}" = "1" ] || {
        echo -e "  ${YELLOW}[audio] loopback local desactive (AUDIO_LOCAL_LOOPBACK=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sources 2>/dev/null | grep -qw 'gsm_audio.monitor' || {
        echo -e "  ${YELLOW}[audio] gsm_audio.monitor absent - loopback local ignore${NC}"; return 0; }

    # Sortie materielle = le sink par defaut, SAUF si c'est un de nos null-sinks.
    local sink
    sink="$(pactl get-default-sink 2>/dev/null || true)"
    case "$sink" in
        ''|gsm_audio|gsm_mic|@*)
            sink="$(pactl list short sinks 2>/dev/null \
                    | awk '$2 != "gsm_audio" && $2 != "gsm_mic" { print $2; exit }')" ;;
    esac
    [ -n "$sink" ] || {
        echo -e "  ${YELLOW}[audio] aucune sortie materielle - loopback local ignore${NC}"; return 0; }

    # Idempotent : ne pas empiler un 2e loopback (voix doublee + echo).
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F 'source=gsm_audio.monitor' | grep -qF "sink=${sink}"; then
        echo -e "  ${GREEN}[audio] loopback local deja en place → ${sink}${NC}"
        return 0
    fi

    if pactl load-module module-loopback \
            source=gsm_audio.monitor sink="$sink" \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] loopback local charge : gsm_audio.monitor → ${sink} (${LOOPBACK_LATENCY_MSEC} ms)${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec du loopback local vers ${sink}${NC}"
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
    pkill -f "paplay --server=${relay}" 2>/dev/null || true          # idempotent
    [ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
    # parec lit le pulse LOCAL (gsm_audio.monitor) ; paplay pousse vers l'hote.
    # --latency-msec : capture courte (30ms) + lecture TAMPONNEE (250ms) pour
    # absorber la gigue (ordonnancement/TCP/2 horloges pulse) - sinon voix HACHEE.
    setsid env PULSE_SERVER="unix:${PULSE_SOCK}" sh -c '
      while true; do
        parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
          | paplay --server='"${relay}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
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
#   d'ou 2 process distincts. On NE TOUCHE NI qemu-src/run.sh NI osmo-bts-trx.cfg.
# ══════════════════════════════════════════════════════════════════════════
