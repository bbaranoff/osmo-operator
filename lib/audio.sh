# =============================================================================
#  lib/audio.sh - the osmo-operator audio chain (PulseAudio + GAPK bridge)
# =============================================================================
#
#  ensure_pulse / ensure_host_audio / ensure_gapk set up the PulseAudio chain
#  used by the `mobile` and by the MGW RTP bridge. The `qemu` mode of
#  start-native.sh calls ensure_gapk right before handing over to
#  qosmo-grgsm/start-clean.sh: this is what connects the MGW RTP to the
#  `gsm_audio` sink; without it the stack comes up, the call is established,
#  and nobody hears anything.
#
#  THIS FILE DOES NOTHING WHEN SOURCED: it only defines functions.
#  Expected caller: run_modules/25-audio.sh.
#
#  AUDIO=0 disables the whole setup.
# -----------------------------------------------------------------------------

: "${HERE:=/opt/GSM/osmo-operator}"
: "${LOG_DIR:=/root}"
: "${AUDIO:=1}"
: "${PULSE_SOCK:=/var/run/pulse/native}"
# Messages are colored; under `set -u` an undefined color would make the
# function fail before doing anything, so the colors are neutralized here.
RED='' GREEN='' YELLOW='' CYAN='' NC='' BOLD=''

# The null-sinks of the GSM chain, declared in one place: gsm_audio (= alsa
# gsm_out, the outgoing voice) and gsm_mic (= alsa gsm_in through
# gsm_mic.monitor, the silent microphone that feeds in).
#
# Both sinks are always created together - here, in system.pa and in the
# Dockerfile - because gapk_io gives up BOTH directions when the capture fails:
#     pq_alsa.c:168  Couldn't init ALSA device 'gsm_in': Input/output error
#     gapk_io.c:468  Failed to initialize GAPK I/O
# which leaves a perfectly established but totally silent call, with the error
# buried in mobile.log.
# osmo_tts_off: a trash sink for speech-dispatcher. On the bench a desktop
# application sometimes triggers speech synthesis; without an installed voice
# the "dummy" module of speech-dispatcher plays its placeholder message
# (dummy-message.wav: 29 s, low voice, 83 % of the energy below 300 Hz, level
# 100 %) in the speakers, on top of the current call. Once the stream is moved
# here, module-stream-restore sends it back here each time it appears.
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

# ── Local loopback: gsm_audio.monitor → the machine's sound card ────────────
# gsm_audio is a module-null-sink: without a consumer the downlink voice is
# dropped by construction (gsm_audio RUNNING, gsm_audio.monitor IDLE, ALSA
# output SUSPENDED: call established, no sound). This loopback is that consumer.
#
# ⚠️ The sink choice matters: looping back onto gsm_audio or gsm_mic creates a
# closed loop (cf. ensure_gapk: the mobiles write into gsm_out, they would be
# replayed into their own uplink). Both null-sinks are therefore explicitly
# excluded and only a hardware output is kept.
# 40 ms and not 20: the minimum latency of these sinks is 26 ms. A loopback
# asking for 20 ms resyncs constantly and drops samples ("Configured latency
# of 20.00 ms is smaller than minimum latency", "Doing resync", "drop sink",
# "drop source"). 40 ms is above the floor and the extra 20 ms are inaudible
# on a call.
LOOPBACK_LATENCY_MSEC="${LOOPBACK_LATENCY_MSEC:-40}"

# ── Speaker and microphone assignment: one single place ────────────────────
# The bench audio has two modes: WITHOUT a postmarketOS phone, the host hears
# the downlink through a direct module-loopback (gsm_audio.monitor ->
# speakers); WITH the VM, the voice must go THROUGH IT ("bridge" card 0x12 <->
# "combine" card 0x13, tools/osmo-pmos-setup.sh) and the direct loopback must
# not exist, otherwise everything is heard twice (direct, then the VM 500 ms
# later). scripts/audio-chain.sh (at boot, ExecStartPost of pulseaudio),
# ensure_pulse (start-native) and osmo-pmos-setup all go through the functions
# below, so they agree on what "the speakers" are: the memorized default sink
# (osmo_hp_ec) does not exist at boot, the echo canceller must be loaded before
# the QEMU "combine" streams appear, otherwise they land on the raw card.
#
#   audio_hw_sink / audio_hw_source   the hardware sound card (the default if
#                                     it is one, otherwise the first alsa_*,
#                                     HDMI excluded);
#   audio_hp_sink / audio_mic_source  WHAT THE OPERATOR HEARS / SAYS: the echo
#                                     canceller (osmo_hp_ec / osmo_mic_ec) if
#                                     loaded, otherwise the hardware;
#   ensure_echo_cancel                loads that canceller (without analog
#                                     AGC, microphone at 25 %) and makes it
#                                     the default, at boot as with the VM;
#   pmos_vm_audio_present             the postmarketOS VM has its sound cards
#                                     here (QEMU streams media.name=combine);
#   remove_direct_loopbacks           removes the direct loopbacks;
#   ensure_local_loopback / _mic      install the direct loopback ONLY without
#                                     the VM, to audio_hp_sink / from
#                                     audio_mic_source, and replace a loopback
#                                     installed to another output (the raw
#                                     card from before the canceller, for
#                                     example).
# osmo-pmos-qemu loads the canceller BEFORE starting QEMU and names its outputs
# to the "combine" card (OSMO_PMOS_HP / OSMO_PMOS_MIC, pmbootstrap patch);
# osmo-pmos-setup and the VM shutdown (pmos_stop) go through these functions.
# AUDIO_ECHO_CANCEL=0 to do without the canceller (speakers = the raw card).
EC_AEC_ARGS='aec_args="analog_gain_control=0 digital_gain_control=1 noise_suppression=1 high_pass_filter=1"'
: "${AUDIO_AEC_METHOD:=speex}"
audio_aec_method() { echo "$AUDIO_AEC_METHOD"; }
# aec_args only apply to webrtc (see ensure_echo_cancel, aec_opts).
: "${EC_MIC_VOLUME:=25%}"
# The Acer PDM microphone does not saturate at 100 % (room noise ~70 rms) and
# is only a whisper at 25-50 % (~6 rms): it gets its own volume.
: "${EC_MIC_VOLUME_PDM:=100%}"

audio_hw_sink() {
    local d; d="$(pactl get-default-sink 2>/dev/null || true)"
    case "$d" in alsa_output.*) echo "$d"; return 0 ;; esac
    pactl list short sinks 2>/dev/null \
        | awk '$2 ~ /^alsa_output/ && $2 !~ /hdmi/ { print $2; exit }'
}
# THE INTERNAL DIGITAL MICROPHONE (PDM/DMIC) BEFORE THE JACK INPUT.
# On the Acer the default source is the analog jack input
# (alsa_input.pci-0000_04_00.6.analog-stereo): nothing plugged in, absolute
# zero (not even noise), and the echo canceller would attach to it, while the
# internal microphone is the acp_pdm_mach source, left SUSPENDED. The jack
# port reports "availability unknown", so there is no plug detection to rely
# on: the internal digital microphone is preferred by name.
# AUDIO_MIC_SOURCE=<source> forces another microphone (headset).
audio_hw_source() {
    if [ -n "${AUDIO_MIC_SOURCE:-}" ] && pactl list short sources 2>/dev/null \
            | awk -v s="$AUDIO_MIC_SOURCE" '$2 == s { f=1 } END { exit !f }'; then
        echo "$AUDIO_MIC_SOURCE"; return 0
    fi
    local p; p="$(pactl list short sources 2>/dev/null \
        | awk '$2 ~ /^alsa_input/ && $2 ~ /pdm|dmic/ && $2 !~ /\.monitor$/ { print $2; exit }')"
    [ -n "$p" ] && { echo "$p"; return 0; }
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

# ── Who carries the voice: the host, or the VM? ─────────────────────────────
# BY DEFAULT, THE HOST. The postmarketOS phone is the bench INTERFACE (dial,
# answer, SMS); it does not need to carry the samples. Doing so is expensive
# and audible: microphone -> QEMU -> VM Pulse -> module-loopback 400 ms ->
# QEMU -> gsm_mic, and as much on the way back, i.e. ~800 ms round trip, two
# emulated clocks, and the resampling of two HDA cards at 44.1 kHz for an
# 8 kHz telephone signal.
#
# So the voice stays on the host (gsm_audio -> speakers, microphone ->
# gsm_mic, 40 ms), and the VM keeps its cards for its own use - ringtone,
# notifications, the Calls application. It stays in the SIGNALLING path,
# which is its real role.
#
# To put the voice INSIDE the VM (the crossed setup, to hear it go through the
# phone): OSMO_PMOS_VOIX_VM=1 when starting osmo-pmos-setup. It then installs
# the two loopbacks in the VM and drops this marker; the functions below then
# remove the host's direct loopbacks, otherwise the voice would arrive TWICE -
# direct, then through the VM 400 ms later.
PMOS_VOIX_VM_MARQUEUR="${PMOS_VOIX_VM_MARQUEUR:-/run/osmo-pmos-voix-vm}"

# True only if the VM REALLY carries the voice: the marker AND the process.
# A marker left behind by a VM killed abruptly must not deprive the host of
# its speakers.
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

# THE ECHO CANCELLER BETWEEN THE MICROPHONE AND THE SPEAKERS.
# Internal microphone + speakers: the echo of the 600 feeds back into the
# microphone (2 400 peak with the speaker cut, 32 768 saturated with the
# speaker open): Larsen. The webrtc analog AGC, left at its default, moves the
# microphone gain from 100 % to 0 % from one minute to the next (crushed
# voice, 93 % of the energy below 300 Hz at the GSM input). Hence: no analog
# AGC, microphone fixed at 25 % (it saturates from 45 %), and an explicit
# unmute, since module-device-restore sometimes leaves the module muted. The
# osmo_mic_ec volume is SHARED with the hardware microphone: same value for
# both.
ensure_echo_cancel() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_ECHO_CANCEL:-1}" = "1" ] || {
        echo -e "  ${YELLOW}[audio] annuleur d echo desactive (AUDIO_ECHO_CANCEL=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0
    local mic hp aec_opts=()
    [ "$AUDIO_AEC_METHOD" = "webrtc" ] && aec_opts=("$EC_AEC_ARGS")
    mic="$(audio_hw_source)"; hp="$(audio_hw_sink)"
    if [ -z "$mic" ] || [ -z "$hp" ]; then
        echo -e "  ${YELLOW}[audio] pas de micro ou de haut-parleur materiel - annuleur d echo ignore${NC}"; return 0
    fi
    # The default (osmo_hp_ec / osmo_mic_ec) is only set at LOAD time: replaying
    # it on every pass would send back to the canceller the streams the
    # operator has just moved elsewhere. Everything that matters for the GSM
    # chain is pinned by name; the default is only a desktop matter.
    if pactl list short modules 2>/dev/null | grep -q 'module-echo-cancel'; then
        echo -e "  ${GREEN}[audio] annuleur d echo deja en place (osmo_hp_ec / osmo_mic_ec)${NC}"
        return 0
    # 8000 Hz MONO, LIKE THE REST OF THE BENCH. Without "rate" the module loads
    # at 32000 Hz (osmo_hp_ec in float32le 1ch 32000Hz) while gsm_audio,
    # gsm_mic and osmo_tts_off are all s16le 1ch 8000Hz; each pass through the
    # canceller would then cost two resamplings (8000 -> 32000 on input,
    # 32000 -> 8000 on output). The signal is bounded to 4 kHz by GSM anyway.
    # The webrtc canceller accepts 8000/16000/32000/48000.
    # SPEEX BY DEFAULT. webrtc (cancellation + noise reduction + high-pass)
    # costs PulseAudio 7 to 17 % of a core continuously, call or not. speex
    # cancels the echo for a fraction of that price and has no analog AGC that
    # would pump the microphone. AUDIO_AEC_METHOD=webrtc selects the webrtc
    # canceller and its aec_args.
    # aec_args is ONE argument (quotes included): an unquoted $(...) would
    # split it, pactl would ignore analog_gain_control=0 and the webrtc AGC
    # would bring the microphone down to 0 % (mute microphone during a call).
    elif pactl load-module module-echo-cancel aec_method="$(audio_aec_method)" \
            rate=8000 channels=1 \
            source_master="$mic" sink_master="$hp" \
            source_name=osmo_mic_ec sink_name=osmo_hp_ec "${aec_opts[@]}" \
            source_properties=device.description=Micro_sans_echo \
            sink_properties=device.description=HP_sans_echo >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] annuleur d echo ${AUDIO_AEC_METHOD} pose entre ${mic} et ${hp}${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec de l annuleur d echo - les HP restent ${hp}${NC}"; return 0
    fi
    pactl set-default-sink osmo_hp_ec >/dev/null 2>&1
    pactl set-default-source osmo_mic_ec >/dev/null 2>&1
    pactl set-sink-mute "$hp" 0 2>/dev/null;       pactl set-sink-mute osmo_hp_ec 0 2>/dev/null
    local vol="$EC_MIC_VOLUME"
    case "$mic" in *pdm*|*dmic*) vol="$EC_MIC_VOLUME_PDM" ;; esac
    pactl set-source-mute "$mic" 0 2>/dev/null;    pactl set-source-volume "$mic" "$vol" 2>/dev/null
    pactl set-source-mute osmo_mic_ec 0 2>/dev/null; pactl set-source-volume osmo_mic_ec "$vol" 2>/dev/null
    return 0
}

# ── The RECORDING source: what is heard + what is said ──────────────────────
# The screen recorder (EasyScreenCast extension, "audio source" menu) can only
# capture one PulseAudio SOURCE. A call does not live on a source: the
# downlink goes into sinks (gsm_audio, then the speakers), and only the
# microphone is a source. "No audio source" records silence, and choosing the
# microphone only records the operator's voice, never the other party.
#
# So ONE trash sink, osmo_rec, is built and fed by both sides:
#   - the monitor of the operator's speakers (everything he HEARS, whether the
#     voice comes from the direct loopback or from the postmarketOS phone);
#   - his microphone (everything he SAYS).
# Its monitor, osmo_rec.monitor, then shows up in the recorder menu as
# "Enregistrement_appel": one choice, and the whole call is in it.
# 8 kHz mono, like the rest of the chain. AUDIO_RECORD_MIX=0 not to create it.
# ── Lightening PulseAudio ────────────────────────────────────────────────
# Sources of permanent PulseAudio load (7-17 % of a core):
#   - speech-dispatcher (sd_dummy): a 44100 Hz stream never suspended towards
#     the sound card, hence a continuous 44.1 -> 48 kHz resampling for
#     nothing; started on demand by the desktop ("-s -t 0": never stops);
#   - the webrtc canceller (see ensure_echo_cancel);
#   - osmo_rec in 48 kHz stereo, fed by two 8 kHz mono loops.
# This stops the first one and MIGRATES an already running bench to
# speex / 8 kHz: unloading the canceller drops the loops pinned on it, so
# they are reinstalled. AUDIO_ALLEGER=0 to leave everything alone.
alleger_audio() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_ALLEGER:-1}" = "1" ] || return 0
    if pgrep -x speech-dispatch >/dev/null 2>&1 || pgrep -f '[/]usr/bin/speech-dispatcher' >/dev/null 2>&1; then
        pkill -f '[/]usr/bin/speech-dispatcher' 2>/dev/null
        pkill -f '[/]usr/lib/speech-dispatcher-modules/' 2>/dev/null
        echo -e "  ${GREEN}[audio] speech-dispatcher arrete (flux 44,1 kHz permanent vers les HP)${NC}"
    fi
    pactl info >/dev/null 2>&1 || return 0
    # module-stream-restore WITHOUT restore_device: otherwise it sends the
    # `mobile` (ALSA "default") back to the raw card where it once played,
    # outside the canceller - echo test: the speaker feeds back into the
    # microphone, Larsen rising during the call. Volumes stay memorized, the
    # device does not.
    local sr
    sr="$(pactl list short modules 2>/dev/null | awk '$2 == "module-stream-restore" && $0 !~ /restore_device=false/ {print $1; exit}')"
    if [ -n "$sr" ]; then
        pactl unload-module "$sr" >/dev/null 2>&1 \
            && pactl load-module module-stream-restore restore_device=false >/dev/null 2>&1 \
            && echo -e "  ${GREEN}[audio] module-stream-restore sans restauration de peripherique${NC}"
    fi
    local m refaire=0
    m="$(pactl list short modules 2>/dev/null | awk '/module-echo-cancel/ && /aec_method=webrtc/ {print $1; exit}')"
    if [ -n "$m" ] && [ "$AUDIO_AEC_METHOD" != "webrtc" ]; then
        pactl unload-module "$m" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}[audio] annuleur webrtc decharge -> ${AUDIO_AEC_METHOD}${NC}"
        refaire=1
    fi
    if pactl list short sinks 2>/dev/null | awk '$2 == "osmo_rec"' | grep -q 48000Hz; then
        for m in $(pactl list short modules 2>/dev/null | awk '/module-loopback/ && /sink=osmo_rec([ \t]|$)/ {print $1}') \
                 $(pactl list short modules 2>/dev/null | awk '/module-null-sink/ && /sink_name=osmo_rec([ \t]|$)/ {print $1}'); do
            pactl unload-module "$m" >/dev/null 2>&1
        done
        echo -e "  ${GREEN}[audio] osmo_rec 48 kHz stereo retire -> 8 kHz mono${NC}"
        refaire=1
    fi
    if [ "$refaire" = 1 ]; then
        ensure_echo_cancel
        ensure_local_loopback
        ensure_local_mic
        ensure_record_mix
    fi
    return 0
}

# ── REINIT: start from a clean chain without restarting PulseAudio ─────────
# scripts/audio-chain.sh --reinit. Unloads what the chain installs ON TOP of
# the GSM sinks - echo canceller, all the loops, osmo_rec - and stops
# speech-dispatcher; audio-chain.sh then reinstalls everything as at boot.
# gsm_audio, gsm_mic and osmo_tts_off stay: the `mobile` and gapk are
# connected to them (ALSA PCM gsm_out/gsm_in), unloading them would cut a
# call for good instead of one second.
reinit_audio() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    pactl info >/dev/null 2>&1 || return 0
    pkill -f '[/]usr/bin/speech-dispatcher' 2>/dev/null
    pkill -f '[/]usr/lib/speech-dispatcher-modules/' 2>/dev/null
    local m n=0
    for m in $(pactl list short modules 2>/dev/null | awk '/module-loopback/ {print $1}') \
             $(pactl list short modules 2>/dev/null | awk '/module-echo-cancel/ {print $1}') \
             $(pactl list short modules 2>/dev/null | awk '/module-null-sink/ && /sink_name=osmo_rec([ \t]|$)/ {print $1}'); do
        pactl unload-module "$m" >/dev/null 2>&1 && n=$((n + 1))
    done
    echo -e "  ${GREEN}[audio] ${n} module(s) de la chaine decharge(s)${NC}"
}

ensure_record_mix() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_RECORD_MIX:-1}" = "1" ] || return 0
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sinks 2>/dev/null | grep -qw osmo_rec \
        || pactl load-module module-null-sink sink_name=osmo_rec \
               format=s16le rate=8000 channels=1 \
               sink_properties=device.description=Enregistrement_appel >/dev/null 2>&1 \
        || { echo -e "  ${YELLOW}[audio] sink osmo_rec impossible - enregistrement non prepare${NC}"; return 0; }

    local hp mic src
    hp="$(audio_hp_sink)"; mic="$(audio_mic_source)"
    for src in ${hp:+${hp}.monitor} ${mic:-}; do
        # Idempotent, and pinned like the others (cf. the dont_move block).
        pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
            | grep -F "source=${src}" | grep -qF 'sink=osmo_rec' && continue
        pactl load-module module-loopback source="$src" sink=osmo_rec \
            sink_dont_move=true source_dont_move=true \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1
    done
    echo -e "  ${GREEN}[audio] source d enregistrement prete : osmo_rec.monitor (Enregistrement_appel)${NC}"
    # The screen recorder is remembered by its application name
    # (module-stream-restore): moved once, it comes back there afterwards.
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

    # With the postmarketOS phone the voice goes through the VM: no direct loopback.
    if pmos_vm_audio_present; then
        echo -e "  ${GREEN}[audio] telephone postmarketOS en place - l ecoute passe par la VM, pas de bouclage direct${NC}"
        remove_direct_loopbacks
        return 0
    fi

    local sink
    sink="$(audio_hp_sink)"
    [ -n "$sink" ] || {
        echo -e "  ${YELLOW}[audio] aucune sortie materielle - loopback local ignore${NC}"; return 0; }

    # Idempotent: do not stack a 2nd loopback (doubled voice + echo)...
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F 'source=gsm_audio.monitor' | grep -F "sink=${sink}" | grep -qF 'sink_dont_move=true'; then
        echo -e "  ${GREEN}[audio] loopback local deja en place → ${sink}${NC}"
        return 0
    fi
    # ...and do not keep one towards ANOTHER output (the raw card installed
    # before the echo canceller, for example).
    local m
    for m in $(pactl list short modules 2>/dev/null \
               | awk '/module-loopback/ && /source=gsm_audio\.monitor/ { print $1 }'); do
        pactl unload-module "$m" >/dev/null 2>&1
    done

    # PINNED. PulseAudio 16 moves any unpinned stream to the new default device
    # (set-default-sink / GNOME "Output"): one click in the sound settings and
    # this loopback would read the MICROPHONE (default source) to play it into
    # the raw card (default sink). dont_move makes it deaf to default changes:
    # it only moves if unloaded.
    if pactl load-module module-loopback \
            source=gsm_audio.monitor sink="$sink" \
            sink_dont_move=true source_dont_move=true \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] loopback local charge : gsm_audio.monitor → ${sink} (${LOOPBACK_LATENCY_MSEC} ms)${NC}"
    else
        echo -e "  ${YELLOW}[audio] echec du loopback local vers ${sink}${NC}"
    fi
}

# ── Local microphone: the machine's sound card → gsm_mic ───────────────
# SYMMETRIC to ensure_local_loopback. The uplink (what the mobile SENDS to
# the network) starts from gsm_in, i.e. from gsm_mic.monitor, a null-sink
# that nothing on the machine feeds by itself. The web console can feed it
# (the browser captures the microphone, pushes the samples to
# /opt/GSM/osmo-egprs-web/server.js, which reinjects them through
# `pacat --playback -d gsm_mic`), but the browser -> node -> socket transport
# adds 3 to 4 seconds of delay that no pulse setting can reach. A
# module-loopback from the sound card removes that transport: the microphone
# feeds gsm_mic directly, in 20 ms.
#
# ⚠️ TWO SOURCES NEVER TO USE HERE:
#   - gsm_audio.monitor: this is the DOWNLINK. Replaying it into the uplink is
#     a closed loop (RMS x11 in 10 s), as documented in /etc/asound.conf.
#     Only a HARDWARE input is kept.
#   - gsm_mic.monitor: the sink being fed - it would copy itself onto itself.
#
# ⚠️ ACOUSTIC loop: the downlink goes out on the speakers (loopback above)
# and the microphone hears them again. Irrelevant with a headset; on speakers,
# mute one of the two or lower the volume.
AUDIO_LOCAL_MIC="${AUDIO_LOCAL_MIC:-1}"

ensure_local_mic() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "$AUDIO_LOCAL_MIC" = "1" ] || {
        echo -e "  ${YELLOW}[audio] micro local desactive (AUDIO_LOCAL_MIC=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sinks 2>/dev/null | grep -qw 'gsm_mic' || {
        echo -e "  ${YELLOW}[audio] sink gsm_mic absent - micro local ignore${NC}"; return 0; }

    # With the postmarketOS phone, the VM feeds gsm_mic.
    if pmos_vm_audio_present; then
        echo -e "  ${GREEN}[audio] telephone postmarketOS en place - le micro passe par la VM, pas de bouclage direct${NC}"
        remove_direct_loopbacks
        return 0
    fi

    # Input = the operator's microphone (echo canceller if present, otherwise
    # the hardware) - never a .monitor (see the warning above).
    local src
    src="$(audio_mic_source)"
    [ -n "$src" ] || {
        echo -e "  ${YELLOW}[audio] aucune entree materielle - micro local ignore${NC}"; return 0; }

    # Idempotent: a 2nd loopback would double the uplink voice...
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F "source=${src}" | grep -F 'sink=gsm_mic' | grep -qF 'sink_dont_move=true'; then
        echo -e "  ${GREEN}[audio] micro local deja en place : ${src} → gsm_mic${NC}"
        return 0
    fi
    # ...and not one from ANOTHER input.
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

# Post-condition: do the PCMs that `mobile` will actually open really open?
# Testing the sink with `pactl list sinks` is not enough - it is the ALSA
# mapping of /etc/asound.conf that breaks (gsm_in → gsm_mic.monitor). Each
# side is really opened for 1 s and a failure is reported loudly; otherwise
# the failure stays silent until the first mute call.
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

    # 0. ALSA mapping gsm_out/gsm_in → PulseAudio sink gsm_audio (REQUIRED on
    #    the host in native mode). Without /etc/asound.conf, the `mobile`
    #    (io-handler gapk, alsa-output-dev gsm_out) opens a non-existent ALSA
    #    PCM → "Unknown PCM gsm_out" → the TCH audio is never decoded to
    #    gsm_audio → silence in the browser. The sink alone is not enough.
    if [ -f "$HERE/configs/asound.conf" ] && ! cmp -s "$HERE/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        cp -f "$HERE/configs/asound.conf" /etc/asound.conf \
            && echo -e "  ${GREEN}[audio] /etc/asound.conf deploye (ALSA gsm_out/gsm_in → pulse gsm_audio)${NC}"
    fi

    export PULSE_SERVER="unix:${PULSE_SOCK}"
    if pactl info >/dev/null 2>&1; then
        # PulseAudio already running (osmo-pulse service at boot, or a previous
        # 'fake' solo). The gsm_audio sink is NOT necessarily loaded in THIS
        # daemon -> it is (re)loaded on the fly if missing.
        load_gsm_sinks
        # Deduplication: on a PipeWire/Pulse SHARED between containers, each
        # ensure_pulse loads its own module-null-sink gsm_audio → duplicates.
        # parec (the dashboard /audio stream) then reads the monitor of a sink
        # that gapk does NOT feed → mute audio for remote clients
        # (browser/Windows; locally the host hears through the module-loopback
        # to its speakers). ONE gsm_audio (the 1st module) is kept and the
        # others are unloaded.
        # (the deduplication applies to gsm_mic as much as to gsm_audio: with a
        #  duplicated gsm_mic, gapk captures the monitor of the wrong sink)
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
        alleger_audio
        ensure_local_loopback
        ensure_local_mic
        ensure_record_mix
        return 0
    fi

    # 1. Install pulseaudio if missing (the daemon binary, not only the clients)
    if ! command -v pulseaudio >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "  ${YELLOW}[audio] installation pulseaudio...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                pulseaudio pulseaudio-utils alsa-utils >/dev/null 2>&1 || true
        fi
    fi
    command -v pulseaudio >/dev/null 2>&1 || {
        echo -e "  ${YELLOW}[audio] pulseaudio indisponible - audio ignore${NC}"; return 0; }

    # 2. system.pa config: anonymous access + the null sinks (idempotent).
    #    Declaring them here rather than relying on a load-module at runtime is
    #    what makes the chain robust: they exist from the daemon start, even
    #    if the daemon restarts on its own later.
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

    # 3. (Re)start the system daemon - SERIALIZED
    mkdir -p /var/run/pulse "$LOG_DIR"
    # ensure_pulse is called in parallel (main flow + ensure_gapk through the
    # 'gapk' tmux session) → two 'pulseaudio --system' would start at the same
    # time and fight over /var/run/pulse/native → "bind(): Address already in
    # use" → the socket module fails → dead daemon → unreachable.
    # flock guarantees ONE SINGLE (re)start at a time; a leftover daemon
    # holding a stale socket (sometimes under another uid) is killed and the
    # socket removed by root before the bind.
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

# ── Audio bridge: osmo-gapk auto (network path MGW RTP → sink gsm_audio) ─────
# gapk auto polls the OsmoMGW VTY (4243) and bridges the RTP of EACH call to
# alsa://gsm_out (= PulseAudio null sink gsm_audio). This is the link that
# makes the audio of "network" calls (e.g. 600 = Asterisk echo-test through
# the MGW) audible in the web dashboard: server.js captures gsm_audio.monitor
# → /audio (MP3).
# Started in a DETACHED tmux session 'gapk': survives the 'exec'
# (start-clean.sh / tmux attach) of the qemu/hybrid modes and polls until the
# MGW is up. Idempotent (restarts the session), non-fatal. AUDIO=0 → disabled.
# Container → host voice bridge: parec(gsm_audio.monitor) | paplay(--server=relay).
# run.sh (no-process) attempts this bridge BEFORE PulseAudio is ready (race →
# "PulseAudio injoignable apres 30s" → bridge never started → MUTE VOICE in
# docker). It is (re)started HERE, after ensure_pulse (gsm_audio sink
# guaranteed up). Idempotent, gated on HOST_AUDIO_RELAY (set by
# start-docker.sh = tcp:<gw>:4713).
ensure_host_audio() {
    local relay="${HOST_AUDIO_RELAY:-}"
    [ -n "$relay" ] || return 0
    if ! pactl --server="$relay" info >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[host-audio] relai ${relay} injoignable - pont voix non lance${NC}"; return 0
    fi
    # ── ONE SINGLE BRIDGE FOR THE WHOLE BENCH ──────────────────────────────
    # The `pkill` below runs INSIDE the container, which has its own PID
    # namespace: it never sees the neighbour's bridge. Each operator would
    # start its own, and as they all push to the SAME host PulseAudio, the
    # call would be heard twice with two operators, three times with three.
    # So the SHARED SERVER is queried, not the local process table: a client
    # already connected under this name means a bridge is running somewhere,
    # whatever the container.
    #
    # ⚠️ scripts/run.sh (audio_bridge) carries the SAME guard. Both copies
    # must keep THE SAME client name: it is through this name that they see
    # each other.
    local _bridge_name="osmo-gsm-bridge"
    if pactl --server="$relay" list clients 2>/dev/null \
         | grep -q "application.name = \"${_bridge_name}\""; then
        echo -e "  ${GREEN}[host-audio] pont deja actif sur l hote (${relay}) - on n en ajoute pas un second${NC}"
        return 0
    fi
    # ── NO DUPLICATE WITH THE HOST LOOPBACK EITHER ─────────────────────────
    # The host already loads its module-loopback gsm_audio.monitor -> sound
    # card (ensure_local_loopback, above in this file). This is the SAME job
    # as this bridge: same source, same output. Both together, everything is
    # heard TWICE - and the symptom survives stopping a container. The
    # loopback is kept: it is on the host side and much shorter (20 ms against
    # 250 ms for the TCP bridge).
    if pactl --server="$relay" list short modules 2>/dev/null \
         | grep -q 'source=gsm_audio.monitor'; then
        echo -e "  ${GREEN}[host-audio] loopback gsm_audio deja en place sur l hote - pont TCP inutile${NC}"
        return 0
    fi
    pkill -f "paplay --server=${relay}" 2>/dev/null || true          # idempotent (local)
    [ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
    # parec reads the LOCAL pulse (gsm_audio.monitor); paplay pushes to the host.
    # --latency-msec: short capture (30ms) + BUFFERED playback (250ms) to absorb
    # jitter (scheduling/TCP/2 pulse clocks) - otherwise CHOPPY voice.
    # --client-name: this is what makes this bridge visible to the guard above,
    # from any container. Without it, each one believes it is alone.
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
    ensure_pulse   # gapk writes into alsa://gsm_out = sink gsm_audio (idempotent)
    local gapk_sh="/etc/osmocom/gapk-start.sh"; [ -x "$gapk_sh" ] || gapk_sh="$HERE/scripts/gapk-start.sh"
    [ -x "$gapk_sh" ] || { echo -e "  ${YELLOW}[gapk] gapk-start.sh introuvable - bridge audio non lance${NC}"; return 0; }
    tmux kill-session -t gapk 2>/dev/null || true
    # The GSM FR format is named "gsm" in osmo-gapk ("gsmfr" does not exist:
    # both processes would die at argument parsing, "Unsupported format").
    # The 3rd argument is the CAPTURE device: it must stay gsm_in (monitor of
    # the gsm_mic null-sink). Pointing it at gsm_out creates a closed loop -
    # the mobiles write into gsm_out, they would be replayed into their own
    # uplink.
    tmux new-session -d -s gapk \
        "GAPK_ALSA_DEV=gsm_out GAPK_ALSA_DEV_IN=gsm_in PULSE_SERVER=unix:${PULSE_SOCK} bash '$gapk_sh' auto gsm gsm_out gsm_in 2>&1 | tee ${LOG_DIR}/gapk-auto.log"
    # `tmux new-session -d` returns 0 as soon as the server has taken the
    # command, not when it runs. If gapk-start.sh returns right away - format
    # refused, sink not there yet, binary missing - the window stays displayed
    # with "[exited]" across it while the green message below would still
    # announce a working audio bridge. So wait one second and check.
    # A dead session is removed: an "exited" window among the others makes one
    # look for a failure in the stack when only the audio bridge did not
    # start - and the log says why.
    sleep 1
    if tmux has-session -t gapk 2>/dev/null && \
       [ "$(tmux list-panes -t gapk -F '#{pane_dead}' 2>/dev/null | head -1)" != "1" ]; then
        echo -e "  ${GREEN}[gapk] auto lance (RTP MGW → sink gsm_audio) - tmux 'gapk', log ${LOG_DIR}/gapk-auto.log${NC}"
    else
        tmux kill-session -t gapk 2>/dev/null || true
        echo -e "  ${YELLOW}[gapk] mort au demarrage - pas de pont audio (fenetre retiree)${NC}"
        echo -e "         ${CYAN}tail -20 ${LOG_DIR}/gapk-auto.log${NC}"
    fi
    ensure_host_audio   # (re)start the voice bridge → host now that pulse+sink are up
}

# ══════════════════════════════════════════════════════════════════════════
# Single-operator modes (host loopback + enp0s3): noproc/faketrx/virtphy/qemu/combine
# ══════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════
# HYBRID mode faketrx-qemu (approach C): 2 osmo-bts-trx, 1 core
#   BTS#0 = UNTOUCHED QEMU pipeline (run.sh: osmo-trx-ipc 5700, ARFCN 514, Calypso)
#   BTS#1 = side-car: osmo-bts-trx (unit-id 6002, base-port 5820/5720) + fake_trx
#           (-P 5720 -p 6720) + trxcon + osmocom-bb mobile (ARFCN 516, IMSI ...0002)
#   Both MS register on the same osmo-bsc/MSC/HLR → intra-MSC call.
#   1 BTS = 1 clock (clk_s per osmo-bts-trx process) → no clock conflict:
#   a single 2-PHY osmo-bts-trx is IMPOSSIBLE (shared clk_s, reset ping-pong),
#   hence 2 distinct processes. Neither qosmo-grgsm/run.sh nor osmo-bts-trx.cfg
#   is touched.
# ══════════════════════════════════════════════════════════════════════════
