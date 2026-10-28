#!/bin/bash
# gapk-start.sh - GSM audio manager (osmo-gapk ↔ ALSA/RTP)
#
# ══════════════════════════════════════════════════════════════════════════════
# DUAL-PATH AUDIO ARCHITECTURE (osmo-nitb-for-calypso v2)
# ══════════════════════════════════════════════════════════════════════════════
#
# PATH 1 - Baseband (mobile l1phy):
#   mobile process ← TCH frames → trxcon → fake_trx → osmo-bts-trx
#                  ↓ io-handler l1phy
#                  ALSA device (direct GSM-FR decoding, zero network latency)
#
#   → Enabled by tch-voice { io-handler l1phy } in mobile.cfg
#   → No gapk needed for this path
#   → Simulates a physical GSM handset
#
# PATH 2 - Network (MGW RTP):
#   BTS → BSC → MSC → MNCC → Asterisk → SIP → Linphone
#                           → MGCP → OsmoMGW → RTP
#                                                ↓
#                                           osmo-gapk (monitor/record/bridge)
#
#   → osmo-gapk hooks onto the MGW RTP ports
#   → Useful for: monitoring, recording, audio injection, tests
#   → Linphone receives the audio directly over SIP (no gapk needed)
#
# SUMMARY:
#   • MS → MS call (same operator)   : audio via l1phy ALSA (path 1)
#   • MS → Linphone call             : audio via Asterisk SIP (path 2)
#   • Network monitoring             : gapk auto/monitor mode (path 2)
#   • Call recording                 : gapk record mode (path 2)
#
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# osmo-gapk CLI CONTRACT - REREAD BEFORE TOUCHING AN INVOCATION
# ══════════════════════════════════════════════════════════════════════════════
# The contract (osmo-gapk --help, and src/app_osmo_gapk.c l.206-295):
#
#   -i FILE           FILE input              -o FILE      FILE output
#   -I HOST/PORT      RTP input               -O HOST/PORT RTP output
#   -a DEVICE         ALSA input              -A DEVICE    ALSA output
#   -f FORMAT         INPUT format            -g FORMAT    OUTPUT format
#   -p PT             RTP payload type in     -P PT        RTP payload type out
#   -t                throttle (one codec frame / 20 ms)
#
# Traps:
#   • `-i` is NOT `-I`. A URL passed to `-i` becomes a FILE NAME.
#   • `-f` alone is not enough: without `-g`, no output format is defined.
#   • The FR format name is "gsm" (.gsm file AND RFC3551 RTP payload), NOT
#     "gsmfr". `osmo-gapk --help` is authoritative; the full list is
#     gsm | rawpcm-s16le | rtp-efr | rtp-hr-etsi | rtp-hr-ietf | amr-* | ti-* |
#     racal-* | hr-ref-*.
#   • Only one codec is enc+dec in this build: `fr`. hr/efr/amr/pcm are
#     format-only (empty "enc dec" column in --help). The network uses
#     payload type 3 = GSM FR (osmo-mgw "payload-types:3=GSM").
#   • `-t` ONLY on a FILE input. On RTP the network paces, on ALSA the card
#     does: throttling on top desynchronises.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GAPK_DEFAULT_FORMAT="${GAPK_FORMAT:-gsm}"
GAPK_DEFAULT_DEVICE="${GAPK_ALSA_DEV:-${ALSA_CARD:-default}}"
# CAPTURE device distinct from the PLAYBACK device. Capturing where the
# mobiles write (gsm_out) is the closed loop documented in /etc/asound.conf.
# The capture must target gsm_in (= monitor of the gsm_mic null-sink, which
# nobody feeds). NEVER let this default fall back to $GAPK_DEFAULT_DEVICE.
GAPK_DEFAULT_DEVICE_IN="${GAPK_ALSA_DEV_IN:-gsm_in}"
# RTP payload type of GSM FR (RFC3551). OsmoMGW negotiates "3=GSM".
GAPK_RTP_PT="${GAPK_RTP_PT:-3}"
GAPK_LOG_DIR="${GAPK_LOG_DIR:-/var/log/osmocom}"
GAPK_REC_DIR="${GAPK_REC_DIR:-/var/lib/gapk}"
# GSM frame period. osmo-gapk hardcodes it (option -t): this variable only
# documents the cadence in messages.
GAPK_FRAME_MS=20
MGW_VTY_HOST="127.0.0.1"
MGW_VTY_PORT="4243"
AUTO_POLL_INTERVAL="${GAPK_POLL_INTERVAL:-2}"

GAPK_PID_RX="/var/run/gapk-rx.pid"
GAPK_PID_TX="/var/run/gapk-tx.pid"
GAPK_AUTO_LOCK="/var/run/gapk-auto.lock"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

mkdir -p "$GAPK_LOG_DIR" "$GAPK_REC_DIR"

log_info()  { echo -e "${GREEN}[gapk]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[gapk]${NC} $*"; }
log_error() { echo -e "${RED}[gapk ERROR]${NC} $*" >&2; }
log_auto()  { echo -e "${CYAN}[gapk-auto]${NC} $(date '+%H:%M:%S') $*"; }
# The host's heavy audio chain (echo canceller, loops, recording) only runs
# during a call: set up on « Endpoint actif », torn down on « Endpoint
# disparu ». In the background, so as not to delay the polling. See
# scripts/audio-chain.sh --appel.
_audio_appel() {
    [ "${AUDIO_PENDANT_APPEL:-0}" = "1" ] || return 0
    local chaine="${OSMO_OPERATOR_DIR:-/opt/GSM/osmo-operator}/scripts/audio-chain.sh"
    [ -f "$chaine" ] || return 0
    bash "$chaine" --appel "$1" 3 >>"${GAPK_LOG_DIR:-/tmp}/audio-appel.log" 2>&1 &
}

# ── Checks ─────────────────────────────────────────────────────────────────────
check_gapk() {
    command -v osmo-gapk >/dev/null 2>&1 || {
        log_error "osmo-gapk introuvable."
        log_error "Verifier que le Dockerfile inclut l'etape osmo-gapk --enable-alsa."
        exit 1
    }
}

# No PCM of this chain is a sound card: gsm_out and gsm_in are `type pulse`
# (/etc/asound.conf) and end up in null-sinks, so the presence of /dev/snd
# says nothing (a server without a sound card is the project's target, and
# start-docker.sh does not pass `--device /dev/snd`). What WILL BE USED is
# tested instead: does the PCM open? Same gesture as assert_audio_devices()
# in lib/audio.sh - one second of silence, and a verdict on the real device.
check_alsa() {
    local dev="${1:-default}"
    command -v aplay >/dev/null 2>&1 || {
        log_warn "aplay absent - impossible de verifier le PCM '${dev}'"
        return 1
    }
    if timeout 5 aplay -D "$dev" -f S16_LE -r 8000 -c 1 -d 1 /dev/zero >/dev/null 2>&1; then
        return 0
    fi
    log_warn "PCM ALSA '${dev}' ne s'ouvre pas."
    [ -d /dev/snd ] || log_warn "  (/dev/snd absent - sans importance si le PCM est 'type pulse')"
    pactl info >/dev/null 2>&1 \
        || log_warn "  PulseAudio injoignable (PULSE_SERVER=${PULSE_SERVER:-non defini})"
    log_warn "  verifier /etc/asound.conf et 'pactl list short sinks' (gsm_audio + gsm_mic)"
    return 1
}

# ── Mobile audio mode detection ───────────────────────────────────────────────
detect_audio_mode() {
    # The mobile carries ITS OWN audio chain as soon as an io-handler (gapk or
    # l1phy) is declared in one of its cfg files: it is the one reading gsm_in
    # and writing gsm_out. Every mobile*.cfg is inspected (mobile_group1.cfg,
    # mobile_faketrx_bts1.cfg...).
    #   mobile  : the mobile process does the audio (io-handler gapk|l1phy)
    #   l1phy   : same, kept for existing callers
    #   gapk    : no mobile has audio -> path 2 (RTP<->ALSA bridge)
    local cfg
    for cfg in "${OSMOCOM_HOME:-/root/.osmocom}"/bb/mobile*.cfg /root/.osmocom/bb/mobile*.cfg; do
        [ -f "$cfg" ] || continue
        grep -q "io-handler l1phy" "$cfg" 2>/dev/null && { echo "l1phy"; return 0; }
        grep -q "io-handler gapk"  "$cfg" 2>/dev/null && { echo "mobile"; return 0; }
    done
    echo "gapk"
}

# ── RTP addressing ────────────────────────────────────────────────────────────
# osmo-gapk splits HOST/PORT at the SLASH (app_osmo_gapk.c:190, strtok(dup, "/")).
# A "127.0.0.1:16386" gives it host="127.0.0.1:16386" then strtok NULL ->
# -EINVAL -> "Invalid port". This whole script, its public CLI and the output
# of mode_mgw_ports speak IP:PORT. Normalised HERE, once, so that the visible
# contract of the script stays unchanged.
rtp_hostport() {
    local hp="$1"
    # already HOST/PORT: left alone. Otherwise last ':' -> '/'.
    case "$hp" in
        */*) echo "$hp" ;;
        *)   echo "${hp%:*}/${hp##*:}" ;;
    esac
}

# ── Background lifecycle ───────────────────────────────────────────────────────
run_bg() {
    local pid_file="$1"; shift
    local log_file="$1"; shift
    osmo-gapk "$@" >> "$log_file" 2>&1 &
    echo $! > "$pid_file"
    log_info "PID $(cat "$pid_file") → $(basename "$log_file")"
}

stop_pid() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 0
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && log_info "Arrete PID $pid" || true
    fi
    rm -f "$pid_file"
}

is_running() {
    local pid_file="$1"
    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# info - shows the current audio architecture
# ══════════════════════════════════════════════════════════════════════════════
mode_info() {
    local audio_mode
    audio_mode=$(detect_audio_mode)

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        Architecture audio osmo-nitb-for-calypso                 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "  Mode mobile.cfg : ${BOLD}${audio_mode}${NC}"
    echo ""

    if [ "$audio_mode" = "l1phy" ]; then
        echo -e "  ${YELLOW}● Chemin 1 - Baseband (l1phy)${NC}"
        echo -e "    mobile.cfg a tch-voice l1phy mais fake_trx ne transporte"
        echo -e "    PAS le payload audio TCH (bursts downlink = zeros)."
        echo -e "    → Pas de son direct sur les MS virtuels."
        echo ""
        echo -e "  ${GREEN}● Chemin 2 - Reseau (SIP/RTP) - SEUL CHEMIN AUDIO${NC}"
        echo -e "    MS appelle → Asterisk → SIP → Linphone (audio natif)"
        echo -e "    Linphone appelle → Asterisk → MNCC → MSC → MS (signalisation)"
        echo -e "    → L'audio du lab passe par Linphone."
    else
        echo -e "  ${GREEN}● Mode gapk classique${NC}"
        echo -e "    osmo-gapk bridge RTP ↔ ALSA"
        echo -e "    → Requis pour l'audio des appels MS"
    fi

    echo ""
    echo -e "  ${BOLD}Linphone :${NC}"
    local inter_ip
    inter_ip=$(ip -4 addr show | grep '172\.20\.0\.' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "172.20.0.X")
    echo -e "    SIP server : ${CYAN}${inter_ip}:5060${NC}"
    echo -e "    linphone_A : user=${CYAN}linphone_A${NC}  pass=${CYAN}tester${NC}   → 100"
    echo -e "    linphone_B : user=${CYAN}linphone_B${NC}  pass=${CYAN}testerB${NC}  → 200"
    echo ""

    # MGW ports
    mode_mgw_ports "" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# mgw-ports
# ══════════════════════════════════════════════════════════════════════════════
mode_mgw_ports() {
    local quiet="${1:-}"
    local mgw_out

    mgw_out=$( (echo "show mgcp"; sleep 1; echo "exit") | telnet "$MGW_VTY_HOST" "$MGW_VTY_PORT" 2>/dev/null \
        | grep -v "^Trying\|^Connected\|^Escape\|Welcome\|OsmoMGW[>#]\|Copyright\|License\|Contributions\|free software\|NO WARRANTY\|Based on") || true

    if [ -z "$mgw_out" ]; then
        [ -z "$quiet" ] && echo "(MGW non disponible ou aucun endpoint)"
        return 1
    fi

    # Actual OsmoMGW format:
    #   Virtual trunk 0 endpoint rtpbridge/1@mgw:
    #      CONN: (9/rtp C:51E1AF8F r=127.0.0.1:4072<->l=127.0.0.1:4068)
    #      CONN: (9/rtp C:96FA1465 r=127.0.0.1:30004<->l=127.0.0.1:4066)

    if [ -z "$quiet" ]; then
        echo -e "${CYAN}── Endpoints OsmoMGW actifs ──${NC}"
        local has_conn=false
        echo "$mgw_out" | while IFS= read -r line; do
            if echo "$line" | grep -q "endpoint.*@mgw"; then
                local ep; ep=$(echo "$line" | grep -oP 'rtpbridge/\S+')
                # Peek if next lines have CONN
                continue
            fi
            if echo "$line" | grep -q "CONN:.*r="; then
                has_conn=true
                local remote local_p
                remote=$(echo "$line" | grep -oP 'r=\K[0-9.]+:[0-9]+')
                local_p=$(echo "$line" | grep -oP 'l=\K[0-9.]+:[0-9]+')
                echo -e "  ${GREEN}●${NC} local=${CYAN}${local_p}${NC}  remote=${CYAN}${remote}${NC}"
            fi
        done
        # has_conn is assigned INSIDE the pipeline subshell (`echo | while`)
            # and lost on exit: the verdict is taken from mgw_out directly.
            if ! echo "$mgw_out" | grep -q "CONN:.*r="; then
            echo "  (aucune connexion active)"
        fi
    else
        # Machine mode: "LOCAL_PORT REMOTE_IP:REMOTE_PORT" per active connection
        echo "$mgw_out" | grep "CONN:.*r=" | while IFS= read -r line; do
            local remote local_p
            remote=$(echo "$line" | grep -oP 'r=\K[0-9.]+:[0-9]+')
            # OsmoMGW writes 'l=IP:PORT': the character class must include the
            # dot, otherwise grep stops at the first '.' and returns EMPTY, the
            # machine mode outputs NO line and mode_auto never launches gapk.
            # CAUTION: the SOURCE is here (scripts/), /etc/osmocom holds a COPY
            # regenerated at startup - patching the copy alone does not survive.
            local_p=$(echo "$line" | grep -oP 'l=\K[0-9.]+:[0-9]+' | cut -d: -f2)
            [ -n "$local_p" ] && [ -n "$remote" ] && echo "$local_p $remote"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# call - bidirectional ALSA ↔ RTP call (path 2 only)
# ══════════════════════════════════════════════════════════════════════════════
mode_call() {
    local rx_port="${1:?RTP_RX_PORT requis (port MGW downlink)}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis (dest MGW uplink)}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"
    local dev="${4:-$GAPK_DEFAULT_DEVICE}"
    local dev_in="${5:-$GAPK_DEFAULT_DEVICE_IN}"

    check_gapk
    check_alsa "$dev" || true

    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"

    local audio_mode; audio_mode=$(detect_audio_mode)
    if [ "$audio_mode" = "l1phy" ]; then
        echo -e "${YELLOW}${BOLD}NOTE: mobile.cfg utilise io-handler l1phy${NC}"
        echo -e "${YELLOW}L'audio MS passe directement via ALSA (pas via gapk).${NC}"
        echo -e "${YELLOW}Ce mode gapk bridge le RTP reseau (MGW) ↔ ALSA.${NC}"
        echo -e "${YELLOW}Pour les appels MS↔MS, l'audio est deja gere par mobile.${NC}"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   gapk - Bridge RTP reseau ↔ ALSA       ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    printf "  Codec     : ${CYAN}%s${NC}\n" "$fmt"
    printf "  Periph HP : ${CYAN}%s${NC}\n" "$dev"
    printf "  Periph mic: ${CYAN}%s${NC}\n" "$dev_in"
    printf "  RX ecoute : ${CYAN}0.0.0.0:%s${NC}  (MGW downlink → HP)\n" "$rx_port"
    printf "  TX envoi  : ${CYAN}%s${NC}  (micro → MGW uplink)\n" "$tx_dest"
    echo ""

    local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
    local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

    # RX: RTP (FR) → fr codec decoding → PCM → ALSA playback
    log_info "RX : rtp/${rx_port} → alsa:${dev}  [${fmt} → rawpcm-s16le]"
    run_bg "$GAPK_PID_RX" "$log_rx" \
        -I "0.0.0.0/${rx_port}" -f "$fmt" -p "$GAPK_RTP_PT" \
        -A "$dev"               -g rawpcm-s16le

    sleep 0.3

    # TX: ALSA capture → PCM → fr codec encoding → RTP (FR)
    log_info "TX : alsa:${dev_in} → rtp/${tx_dest}  [rawpcm-s16le → ${fmt}]"
    run_bg "$GAPK_PID_TX" "$log_tx" \
        -a "$dev_in"                     -f rawpcm-s16le \
        -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"

    echo ""
    log_info "Bridge actif. Arreter : gapk-start.sh stop"
}

# ══════════════════════════════════════════════════════════════════════════════
# auto - watches the MGW, automatic gapk bridge
# ══════════════════════════════════════════════════════════════════════════════
mode_auto() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"
    local dev_in="${3:-$GAPK_DEFAULT_DEVICE_IN}"

    check_gapk
    check_alsa "$dev" || log_warn "ALSA absent - mode RTP-only"

    local audio_mode; audio_mode=$(detect_audio_mode)

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   gapk-auto - Integration OsmoMGW (chemin reseau)   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "$audio_mode" = "l1phy" ]; then
        log_auto "Mode l1phy detecte → audio MS via mobile process"
        log_auto "gapk surveille le chemin reseau (MGW RTP) uniquement"
        log_auto "Pour les appels MS↔MS, l'audio est gere nativement"
        echo ""
    fi

    log_auto "Codec=${fmt}  HP=${dev}  Mic=${dev_in}  Poll=${AUTO_POLL_INTERVAL}s"
    log_auto "Ctrl+C pour arreter"
    echo ""

    touch "$GAPK_AUTO_LOCK"
    local prev_rx_port=""

    cleanup_auto() {
        log_auto "Arret..."
        stop_pid "$GAPK_PID_RX"
        stop_pid "$GAPK_PID_TX"
        rm -f "$GAPK_AUTO_LOCK"
        exit 0
    }
    trap cleanup_auto SIGINT SIGTERM

    while [ -f "$GAPK_AUTO_LOCK" ]; do
        local first_active
        first_active=$(mode_mgw_ports "quiet" 2>/dev/null | head -1) || first_active=""

        if [ -n "$first_active" ]; then
            local rx_port tx_dest
            rx_port=$(echo "$first_active" | awk '{print $1}')
            tx_dest=$(echo "$first_active" | awk '{print $2}')

            if [ "$rx_port" != "$prev_rx_port" ]; then
                if [ -n "$prev_rx_port" ]; then
                    log_auto "Changement endpoint (${prev_rx_port} → ${rx_port})"
                    stop_pid "$GAPK_PID_RX"
                    stop_pid "$GAPK_PID_TX"
                fi

                log_auto "Endpoint actif : RX=${rx_port}  TX=${tx_dest}"
                [ -z "$prev_rx_port" ] && _audio_appel debut

                local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
                local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

                # ── RX LEG: ARCHITECTURALLY IMPOSSIBLE, NOT LAUNCHED ──
                # `-I 0.0.0.0/$rx_port` fails with "Address already in use":
                # $rx_port is OsmoMGW's LOCAL port, it already holds it. Two
                # processes cannot listen on the same UDP port, and above all
                # the MGW does not SEND to that port - it sends to its remote
                # peer. Receiving a copy of an MGW stream requires the MGW to
                # address it to us, i.e. an extra MGCP connection on the
                # endpoint: that is settled on the MGCP side, never on gapk's.
                # TO LISTEN to the network audio: Asterisk already records
                # every call (MixMonitor, cf. sub-record in extensions.conf),
                # one file per direction: *-ul.wav / *-dl.wav.
                log_auto "RX non lancee : ${rx_port} appartient a OsmoMGW (voir le commentaire)"
                log_auto "  ecoute reseau -> enregistrements MixMonitor (*-ul.wav / *-dl.wav)"

                # ── TX LEG: SAME VERDICT AS THE RX, NOT LAUNCHED BY DEFAULT ──
                # $tx_dest is the REMOTE PEER of the first MGW connection - in
                # practice the RTP port of osmo-bts (127.0.0.1:16384, cf.
                # osmo-mgw.log « Got media info via SDP: port:16384 ... 3=GSM »
                # on rtpbridge/2). This leg would encode the mic (gsm_in) in
                # GSM-FR and SEND it TO THE BTS, on the same port as the MGW's
                # legitimate stream (the voice coming back from Asterisk): TWO
                # interleaved RTP streams - two SSRC, two clocks - in a single
                # 100 ms jitter buffer, with the mic fed straight into the
                # mobile's ear.
                # The mobile (io-handler gapk, alsa gsm_in/gsm_out) already
                # does the mic <-> TCH round trip over the radio: this leg is a
                # DUPLICATE by construction.
                # GAPK_AUTO_TX=1 re-enables it for path 2 only (no mobile with
                # audio); by default the supervisor only observes.
                if [ "${GAPK_AUTO_TX:-0}" = "1" ] && [ "$audio_mode" = "gapk" ]; then
                    # TX: ALSA capture → PCM → fr codec (encode) → RTP (FR)
                    run_bg "$GAPK_PID_TX" "$log_tx" \
                        -a "$dev_in"                     -f rawpcm-s16le \
                        -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"
                    log_auto "Audio actif (PID RX=$(cat $GAPK_PID_RX 2>/dev/null) TX=$(cat $GAPK_PID_TX 2>/dev/null))"
                else
                    log_auto "TX non lancee : ${tx_dest} est le pair du MGW (BTS/Asterisk), pas une entree libre"
                    log_auto "  le montant est porte par le mobile (mode ${audio_mode}) - GAPK_AUTO_TX=1 pour forcer"
                fi

                prev_rx_port="$rx_port"
            fi

            # Only the TX leg is watched, and only if it was launched: the RX
            # is not launched (see above), requiring it would restart the pair
            # endlessly.
            if [ -f "$GAPK_PID_TX" ] && ! is_running "$GAPK_PID_TX"; then
                log_warn "Processus gapk mort - restart"
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        else
            if [ -n "$prev_rx_port" ]; then
                log_auto "Endpoint disparu - arret gapk"
                _audio_appel fin
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        fi
        sleep "$AUTO_POLL_INTERVAL"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# monitor - passive RTP → ALSA listening
# ══════════════════════════════════════════════════════════════════════════════
mode_monitor() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local fmt="${2:-$GAPK_DEFAULT_FORMAT}"
    local dev="${3:-$GAPK_DEFAULT_DEVICE}"

    check_gapk; check_alsa "$dev" || true
    stop_pid "$GAPK_PID_RX"

    log_info "Monitor : rtp/${rx_port} → alsa:${dev}  [${fmt} → rawpcm-s16le]"
    exec osmo-gapk \
        -I "0.0.0.0/${rx_port}" -f "$fmt" -p "$GAPK_RTP_PT" \
        -A "$dev"               -g rawpcm-s16le
}

# ══════════════════════════════════════════════════════════════════════════════
# record - RTP → .gsm file
# ══════════════════════════════════════════════════════════════════════════════
mode_record() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local outfile="${2:-${GAPK_REC_DIR}/record_$(date '+%Y%m%d_%H%M%S').gsm}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk; stop_pid "$GAPK_PID_RX"

    # File output in the SAME format as the input: the FR frames are archived
    # as is (.gsm readable by gapk playback and by grgsm_decode -d FR).
    log_info "Record : rtp/${rx_port} → ${outfile}  [${fmt}]"
    exec osmo-gapk \
        -I "0.0.0.0/${rx_port}" -f "$fmt" -p "$GAPK_RTP_PT" \
        -o "$outfile"           -g "$fmt"
}

# ══════════════════════════════════════════════════════════════════════════════
# playback - .gsm file → RTP
# ══════════════════════════════════════════════════════════════════════════════
mode_playback() {
    local infile="${1:?INPUT_FILE requis}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    [ -f "$infile" ] || { log_error "Fichier introuvable : $infile"; exit 1; }

    # -t MANDATORY here: the input is a FILE, nothing paces the reading.
    # Without throttle gapk drains the file at full speed and floods the
    # jitter buffer on the other side (minutes of audio sent in seconds).
    log_info "Playback : ${infile} → rtp/${tx_dest}  [${fmt}]"
    exec osmo-gapk -t \
        -i "$infile"                     -f "$fmt" \
        -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"
}

# ══════════════════════════════════════════════════════════════════════════════
# loopback - ALSA mic → codec → ALSA speaker
# ══════════════════════════════════════════════════════════════════════════════
mode_loopback() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"
    local dev_in="${3:-$GAPK_DEFAULT_DEVICE_IN}"

    check_gapk
    check_alsa "$dev" || { log_error "ALSA requis."; exit 1; }

    echo -e "${YELLOW}${BOLD}⚠  UTILISEZ DES ECOUTEURS - risque de larsen !${NC}"
    # WHAT THIS MODE PROVES, AND WHAT IT DOES NOT.
    # osmo-gapk builds ONE chain "input format -> canonical -> output format":
    # the codec only appears on the side where the format IS a codec format.
    # PCM -> fr -> PCM is therefore NOT expressible in one invocation, and
    # $fmt is deliberately not used here. This loopback validates the ALSA
    # path (capture, cadence, devices), NOT the FR vocoder.
    # To test the vocoder: `record` then `playback` of the resulting .gsm.
    log_info "Loopback ALSA (sans vocodeur) : alsa:${dev_in} → alsa:${dev}"
    exec osmo-gapk \
        -a "$dev_in" -f rawpcm-s16le \
        -A "$dev"    -g rawpcm-s16le
}

# ══════════════════════════════════════════════════════════════════════════════
# stop / status
# ══════════════════════════════════════════════════════════════════════════════
mode_stop() {
    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"
    rm -f "$GAPK_AUTO_LOCK"
    pkill -x osmo-gapk 2>/dev/null && log_info "Toutes instances arretees" \
        || log_info "Aucune instance active"
}

mode_status() {
    local audio_mode; audio_mode=$(detect_audio_mode)
    echo -e "${CYAN}── Etat audio ──${NC}"
    echo -e "  Mode mobile.cfg : ${BOLD}${audio_mode}${NC}"
    echo ""

    local any=0
    for f in "$GAPK_PID_RX" "$GAPK_PID_TX"; do
        [ -f "$f" ] || continue
        local pid; pid=$(cat "$f")
        if kill -0 "$pid" 2>/dev/null; then
            local cmdline; cmdline=$(cat "/proc/${pid}/cmdline" 2>/dev/null \
                | tr '\0' ' ' | cut -c1-80 || echo "?")
            echo -e "  ${GREEN}●${NC} PID ${pid}  [$(basename "$f")]  ${cmdline}"
            any=1
        else
            echo -e "  ${RED}✗${NC} PID ${pid} mort"; rm -f "$f"
        fi
    done
    [ -f "$GAPK_AUTO_LOCK" ] && echo -e "  ${CYAN}●${NC} mode AUTO actif" && any=1
    [ $any -eq 0 ] && echo -e "  ${YELLOW}Aucune instance gapk active${NC}"

    if [ "$audio_mode" = "l1phy" ]; then
        echo ""
        echo -e "  ${GREEN}●${NC} Audio MS via l1phy (natif dans mobile process)"
        if pgrep -f "mobile.*mobile" >/dev/null 2>&1; then
            echo -e "  ${GREEN}●${NC} Processus mobile actif"
        else
            echo -e "  ${YELLOW}○${NC} Processus mobile non detecte"
        fi
    fi

    if pgrep -x osmo-gapk >/dev/null 2>&1; then
        echo ""; echo -e "${CYAN}Processus gapk :${NC}"
        ps -o pid,args --no-headers -C osmo-gapk 2>/dev/null | sed 's/^/  /' || true
    fi
}

mode_list_codecs() {
    check_gapk
    # `--list-codecs` does not exist in osmo-gapk: --help is queried directly,
    # it is the source of truth for the names.
    echo -e "${CYAN}Codecs et formats supportes (osmo-gapk --help) :${NC}"
    osmo-gapk --help 2>&1 | sed -n '/Supported codecs:/,$p'
}

mode_list_devices() {
    echo -e "${CYAN}── Peripheriques ALSA ──${NC}"
    echo "Lecture (HP) :"
    aplay -L 2>/dev/null | head -20 || echo "  (aplay indisponible)"
    echo ""; echo "Capture (micro) :"
    arecord -L 2>/dev/null | head -20 || echo "  (arecord indisponible)"
    echo ""; echo "Cartes son :"
    cat /proc/asound/cards 2>/dev/null || echo "  (relancer avec --device /dev/snd)"

    local audio_mode; audio_mode=$(detect_audio_mode)
    if [ "$audio_mode" = "l1phy" ]; then
        echo ""
        echo -e "${CYAN}── Config l1phy (mobile.cfg) ──${NC}"
        grep -A3 "tch-voice" /root/.osmocom/bb/mobile.cfg 2>/dev/null | sed 's/^/  /' || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Usage
# ══════════════════════════════════════════════════════════════════════════════
usage() {
    local audio_mode; audio_mode=$(detect_audio_mode)
    cat <<EOF
Usage: gapk-start.sh <mode> [options]

  Mode audio mobile.cfg : ${audio_mode}
  $([ "$audio_mode" = "l1phy" ] && echo "  → Audio MS natif via l1phy. gapk = monitoring reseau uniquement." || echo "  → Audio MS via gapk (mode classique).")

  info                    Affiche l'architecture audio et les IPs Linphone

  auto     [FORMAT] [ALSA_HP] [ALSA_MIC]
               Surveille MGW, bridge RTP↔ALSA auto (chemin reseau).

  call     <RX_PORT> <TX_DEST:PORT> [FORMAT] [ALSA_HP] [ALSA_MIC]
               Bridge bidirectionnel RTP reseau ↔ ALSA.

  monitor  <RX_PORT> [FORMAT] [ALSA_HP]
               Ecoute passive RTP → ALSA.

  record   <RX_PORT> [FICHIER] [FORMAT]
               Enregistre flux RTP → fichier .gsm.

  playback <FICHIER> <TX_DEST:PORT> [FORMAT]
               Injecte fichier .gsm → RTP.

  loopback [FORMAT] [ALSA_HP] [ALSA_MIC]
               Loopback ALSA mic→HP (ECOUTEURS OBLIGATOIRES).
               Ne traverse PAS le vocodeur - voir mode_loopback.

  mgw-ports     Endpoints RTP OsmoMGW actifs.
  stop          Arrete les instances gapk.
  status        Etat audio complet (l1phy + gapk).
  list-codecs   Codecs disponibles.
  list-devices  Peripheriques ALSA + config l1phy.

Formats : gsm (defaut, = GSM FR / RFC3551) | rawpcm-s16le | rtp-efr
          | rtp-hr-etsi | rtp-hr-ietf | amr-* | ti-* | racal-*
          "gsmfr", "gsmefr", "gsmhr", "pcm8", "pcm16" N'EXISTENT PAS :
          ces noms ont fait mourir gapk au demarrage jusqu'au 10/08/2026.
          Liste faisant foi : gapk-start.sh list-codecs
Codecs  : seul "fr" est encodeur ET decodeur dans ce build.

Variables : GAPK_FORMAT, GAPK_ALSA_DEV (HP), GAPK_ALSA_DEV_IN (micro),
            GAPK_RTP_PT, ALSA_CARD, GAPK_POLL_INTERVAL
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
MODE="${1:-help}"; shift 2>/dev/null || true
case "$MODE" in
    info)          mode_info ;;
    auto)          mode_auto "$@" ;;
    call)          mode_call "$@" ;;
    monitor)       mode_monitor "$@" ;;
    record)        mode_record "$@" ;;
    playback)      mode_playback "$@" ;;
    loopback)      mode_loopback "$@" ;;
    mgw-ports)     mode_mgw_ports "" ;;
    stop)          mode_stop ;;
    status)        mode_status ;;
    list-codecs)   mode_list_codecs ;;
    list-devices)  mode_list_devices ;;
    help|-h|--help) usage ;;
    *) log_error "Mode inconnu : $MODE"; echo ""; usage; exit 1 ;;
esac
