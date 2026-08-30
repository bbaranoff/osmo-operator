#!/bin/bash
# gapk-start.sh - Gestionnaire audio GSM (osmo-gapk ↔ ALSA/RTP)
#
# ══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE AUDIO DOUBLE CHEMIN (osmo-nitb-for-calypso v2)
# ══════════════════════════════════════════════════════════════════════════════
#
# CHEMIN 1 - Baseband (mobile l1phy) :
#   mobile process ← TCH frames → trxcon → fake_trx → osmo-bts-trx
#                  ↓ io-handler l1phy
#                  ALSA device (decodage GSM-FR direct, zero latence reseau)
#
#   → Active par tch-voice { io-handler l1phy } dans mobile.cfg
#   → Pas besoin de gapk pour ce chemin
#   → Simule un combine GSM physique
#
# CHEMIN 2 - Reseau (MGW RTP) :
#   BTS → BSC → MSC → MNCC → Asterisk → SIP → Linphone
#                           → MGCP → OsmoMGW → RTP
#                                                ↓
#                                           osmo-gapk (monitor/record/bridge)
#
#   → osmo-gapk se greffe sur les ports RTP du MGW
#   → Utile pour : monitoring, enregistrement, injection audio, tests
#   → Linphone recoit l'audio directement via SIP (pas besoin de gapk)
#
# RESUME :
#   • Appel MS → MS (meme operateur) : audio via l1phy ALSA (chemin 1)
#   • Appel MS → Linphone            : audio via Asterisk SIP (chemin 2)
#   • Monitoring reseau              : gapk mode auto/monitor (chemin 2)
#   • Enregistrement appel           : gapk mode record (chemin 2)
#
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# CONTRAT CLI D'osmo-gapk - RELIRE AVANT DE TOUCHER UNE INVOCATION
# ══════════════════════════════════════════════════════════════════════════════
# [2026-08-10] Tout ce fichier parlait a un osmo-gapk QUI N'EXISTE PAS : un
# format nomme "gsmfr" et une syntaxe d'URL "-i rtp://host:port/20".
# Consequence mesuree : gapk-rx.log et gapk-tx.log ne contenaient QUE
# "Unsupported format: gsmfr", en boucle depuis le demarrage - les deux
# process mouraient a l'analyse des arguments, le superviseur les relancait,
# et le pont RTP<->ALSA n'a JAMAIS transporte un seul echantillon. Le
# superviseur, lui, restait vivant : la sonde `_audio_gapk_vivant` le voyait
# et declarait le pont "en place". Sonde mensongere de bout en bout.
#
# Le contrat REEL (osmo-gapk --help, et src/app_osmo_gapk.c l.206-295) :
#
#   -i FICHIER        entree FICHIER          -o FICHIER   sortie FICHIER
#   -I HOTE/PORT      entree RTP              -O HOTE/PORT sortie RTP
#   -a PERIPH         entree ALSA             -A PERIPH    sortie ALSA
#   -f FORMAT         format d'ENTREE         -g FORMAT    format de SORTIE
#   -p PT             payload type RTP in     -P PT        payload type RTP out
#   -t                throttle (une trame codec / 20 ms)
#
# Pieges :
#   • `-i` n'est PAS `-I`. Une URL passee a `-i` devient un NOM DE FICHIER.
#   • `-f` seul ne suffit pas : sans `-g`, aucun format de sortie n'est defini.
#   • Le nom du format FR est "gsm" (fichier .gsm ET payload RTP RFC3551),
#     PAS "gsmfr". `osmo-gapk --help` fait foi ; la liste complete est
#     gsm | rawpcm-s16le | rtp-efr | rtp-hr-etsi | rtp-hr-ietf | amr-* | ti-* |
#     racal-* | hr-ref-*.
#   • Un seul codec est enc+dec dans ce build : `fr`. hr/efr/amr/pcm sont
#     format-only (colonne "enc dec" vide dans --help). Le reseau est en
#     payload type 3 = GSM FR (verifie : osmo-mgw "payload-types:3=GSM").
#   • `-t` UNIQUEMENT sur une entree FICHIER. Sur RTP c'est le reseau qui
#     cadence, sur ALSA c'est la carte : throttler en plus desynchronise.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GAPK_DEFAULT_FORMAT="${GAPK_FORMAT:-gsm}"
GAPK_DEFAULT_DEVICE="${GAPK_ALSA_DEV:-${ALSA_CARD:-default}}"
# [2026-08-10] Peripherique de CAPTURE distinct de celui de LECTURE. Les deux
# pattes utilisaient `$dev` (gsm_out) : cote TX cela demandait a ALSA de
# CAPTURER sur un peripherique de lecture. Et surtout, capturer la ou les
# mobiles ecrivent, c'est exactement la boucle fermee que le commentaire
# d'/etc/asound.conf documente pour le 08/08 (RMS x11 en 10 s). La capture doit
# viser gsm_in (= moniteur du null-sink gsm_mic, que personne n'alimente).
# Ne JAMAIS faire retomber ce defaut sur $GAPK_DEFAULT_DEVICE.
GAPK_DEFAULT_DEVICE_IN="${GAPK_ALSA_DEV_IN:-gsm_in}"
# Payload type RTP du GSM FR (RFC3551). OsmoMGW negocie "3=GSM".
GAPK_RTP_PT="${GAPK_RTP_PT:-3}"
GAPK_LOG_DIR="${GAPK_LOG_DIR:-/var/log/osmocom}"
GAPK_REC_DIR="${GAPK_REC_DIR:-/var/lib/gapk}"
# Periode de trame GSM. osmo-gapk la porte en dur (option -t) : cette variable
# ne sert plus qu'a documenter la cadence dans les messages.
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

# ── Verifications ──────────────────────────────────────────────────────────────
check_gapk() {
    command -v osmo-gapk >/dev/null 2>&1 || {
        log_error "osmo-gapk introuvable."
        log_error "Verifier que le Dockerfile inclut l'etape osmo-gapk --enable-alsa."
        exit 1
    }
}

# [2026-08-12] Cette fonction jugeait sur la PRESENCE DE /dev/snd. Or aucun PCM
# de cette chaine n'est une carte : gsm_out et gsm_in sont `type pulse`
# (/etc/asound.conf) et sortent dans des null-sinks. Sur une machine sans carte
# son - un serveur, exactement la cible du projet - start.sh ne passe pas
# `--device /dev/snd` (start.sh:191), check_alsa echouait, et mode_loopback
# faisait `exit 1 : ALSA requis` alors que toute la chaine pulse etait
# fonctionnelle. On teste donc CE QU'ON VA UTILISER : le PCM s'ouvre-t-il ?
# Meme geste que assert_audio_devices() de lib/audio.sh - une seconde de
# silence, et un verdict qui porte sur le peripherique reel.
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

# ── Detection du mode audio mobile ────────────────────────────────────────────
detect_audio_mode() {
    # Verifie si le mobile.cfg utilise l1phy
    local cfg="/root/.osmocom/bb/mobile.cfg"
    if [ -f "$cfg" ] && grep -q "io-handler l1phy" "$cfg" 2>/dev/null; then
        echo "l1phy"
    else
        echo "gapk"
    fi
}

# ── Adressage RTP ─────────────────────────────────────────────────────────────
# osmo-gapk decoupe HOTE/PORT au SLASH (app_osmo_gapk.c:190, strtok(dup, "/")).
# Un "127.0.0.1:16386" lui donne host="127.0.0.1:16386" puis strtok NULL ->
# -EINVAL -> "Invalid port". Or tout ce script, sa CLI publique et la sortie
# de mode_mgw_ports parlent en IP:PORT. On normalise ICI, une seule fois, pour
# ne pas avoir a changer le contrat visible du script.
rtp_hostport() {
    local hp="$1"
    # deja en HOTE/PORT : on ne touche pas. Sinon dernier ':' -> '/'.
    case "$hp" in
        */*) echo "$hp" ;;
        *)   echo "${hp%:*}/${hp##*:}" ;;
    esac
}

# ── Cycle de vie background ────────────────────────────────────────────────────
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
# info - affiche l'architecture audio actuelle
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

    # Format reel OsmoMGW :
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
        # [2026-08-10] has_conn etait affecte DANS le sous-shell du pipeline
            # (`echo | while`) : perdu a la sortie -> "aucune connexion active"
            # s'imprimait en listant 4 connexions. Sonde mensongere.
            if ! echo "$mgw_out" | grep -q "CONN:.*r="; then
            echo "  (aucune connexion active)"
        fi
    else
        # Mode machine : "LOCAL_PORT REMOTE_IP:REMOTE_PORT" par connexion active
        echo "$mgw_out" | grep "CONN:.*r=" | while IFS= read -r line; do
            local remote local_p
            remote=$(echo "$line" | grep -oP 'r=\K[0-9.]+:[0-9]+')
            # [2026-08-10] LE MOTIF EXIGEAIT 'l=PORT', OsmoMGW ecrit 'l=IP:PORT'. Sans le
            # point dans la classe, grep bute sur le premier '.' et rend VIDE -> le test
            # ci-dessous echoue -> le mode machine ne sort AUCUNE ligne -> mode_auto ne
            # lance JAMAIS gapk, en silence, endpoints actifs ou non. La branche
            # d'AFFICHAGE portait deja [0-9.]+ : seule celle qui pilote l'automate etait
            # restee en arriere. ATTENTION : la SOURCE est ici (scripts/), /etc/osmocom en
            # est une COPIE regeneree au demarrage - patcher la copie seule ne survit pas.
            local_p=$(echo "$line" | grep -oP 'l=\K[0-9.]+:[0-9]+' | cut -d: -f2)
            [ -n "$local_p" ] && [ -n "$remote" ] && echo "$local_p $remote"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# call - appel bidirectionnel ALSA ↔ RTP (chemin 2 uniquement)
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

    # RX : RTP (FR) → decodage codec fr → PCM → ALSA lecture
    log_info "RX : rtp/${rx_port} → alsa:${dev}  [${fmt} → rawpcm-s16le]"
    run_bg "$GAPK_PID_RX" "$log_rx" \
        -I "0.0.0.0/${rx_port}" -f "$fmt" -p "$GAPK_RTP_PT" \
        -A "$dev"               -g rawpcm-s16le

    sleep 0.3

    # TX : ALSA capture → PCM → encodage codec fr → RTP (FR)
    log_info "TX : alsa:${dev_in} → rtp/${tx_dest}  [rawpcm-s16le → ${fmt}]"
    run_bg "$GAPK_PID_TX" "$log_tx" \
        -a "$dev_in"                     -f rawpcm-s16le \
        -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"

    echo ""
    log_info "Bridge actif. Arreter : gapk-start.sh stop"
}

# ══════════════════════════════════════════════════════════════════════════════
# auto - surveille MGW, bridge gapk auto
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

                local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
                local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

                # ── PATTE RX : ARCHITECTURALEMENT IMPOSSIBLE, ON NE LA LANCE PLUS ──
                # [2026-08-10] `-I 0.0.0.0/$rx_port` echoue en
                # "unable to bind socket:0.0.0.0:4006: Address already in use".
                # Ce n'est pas un reglage a trouver : $rx_port est le port LOCAL
                # d'OsmoMGW, il le detient deja. Deux process ne peuvent pas
                # ecouter le meme port UDP, et surtout le MGW n'ENVOIE pas vers
                # ce port - il envoie vers son pair distant. Recevoir la copie
                # d'un flux MGW demande que le MGW nous l'adresse, donc une
                # connexion MGCP supplementaire sur l'endpoint : ca se regle
                # cote MGCP, jamais cote gapk.
                # Avant ce correctif, la patte RX mourait a chaque tour et le
                # superviseur la relancait indefiniment - une boucle muette qui
                # donnait l'illusion d'un pont en place.
                # POUR ECOUTER l'audio reseau : Asterisk enregistre deja chaque
                # appel (MixMonitor, cf. sub-record dans extensions.conf), avec
                # depuis le 10/08 un fichier par sens : *-ul.wav / *-dl.wav.
                log_auto "RX non lancee : ${rx_port} appartient a OsmoMGW (voir le commentaire)"
                log_auto "  ecoute reseau -> enregistrements MixMonitor (*-ul.wav / *-dl.wav)"
                # TX : ALSA capture → PCM → codec fr (encode) → RTP (FR)
                run_bg "$GAPK_PID_TX" "$log_tx" \
                    -a "$dev_in"                     -f rawpcm-s16le \
                    -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"

                prev_rx_port="$rx_port"
                log_auto "Audio actif (PID RX=$(cat $GAPK_PID_RX 2>/dev/null) TX=$(cat $GAPK_PID_TX 2>/dev/null))"
            fi

            # On ne surveille QUE la patte TX : la RX n'est plus lancee (cf.
            # ci-dessus). L'exiger relancait le couple sans fin.
            if ! is_running "$GAPK_PID_TX"; then
                log_warn "Processus gapk mort - restart"
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        else
            if [ -n "$prev_rx_port" ]; then
                log_auto "Endpoint disparu - arret gapk"
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        fi
        sleep "$AUTO_POLL_INTERVAL"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# monitor - ecoute passive RTP → ALSA
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
# record - RTP → fichier .gsm
# ══════════════════════════════════════════════════════════════════════════════
mode_record() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local outfile="${2:-${GAPK_REC_DIR}/record_$(date '+%Y%m%d_%H%M%S').gsm}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk; stop_pid "$GAPK_PID_RX"

    # Sortie fichier au MEME format que l'entree : on archive les trames FR
    # telles quelles (.gsm lisible par gapk playback et par grgsm_decode -d FR).
    log_info "Record : rtp/${rx_port} → ${outfile}  [${fmt}]"
    exec osmo-gapk \
        -I "0.0.0.0/${rx_port}" -f "$fmt" -p "$GAPK_RTP_PT" \
        -o "$outfile"           -g "$fmt"
}

# ══════════════════════════════════════════════════════════════════════════════
# playback - fichier .gsm → RTP
# ══════════════════════════════════════════════════════════════════════════════
mode_playback() {
    local infile="${1:?INPUT_FILE requis}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    [ -f "$infile" ] || { log_error "Fichier introuvable : $infile"; exit 1; }

    # -t OBLIGATOIRE ici : l'entree est un FICHIER, rien ne cadence la lecture.
    # Sans throttle gapk vide le fichier a pleine vitesse et noie le jitter
    # buffer d'en face (des minutes d'audio expediees en quelques secondes).
    log_info "Playback : ${infile} → rtp/${tx_dest}  [${fmt}]"
    exec osmo-gapk -t \
        -i "$infile"                     -f "$fmt" \
        -O "$(rtp_hostport "$tx_dest")"  -g "$fmt" -P "$GAPK_RTP_PT"
}

# ══════════════════════════════════════════════════════════════════════════════
# loopback - ALSA micro → codec → ALSA HP
# ══════════════════════════════════════════════════════════════════════════════
mode_loopback() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"
    local dev_in="${3:-$GAPK_DEFAULT_DEVICE_IN}"

    check_gapk
    check_alsa "$dev" || { log_error "ALSA requis."; exit 1; }

    echo -e "${YELLOW}${BOLD}⚠  UTILISEZ DES ECOUTEURS - risque de larsen !${NC}"
    # CE QUE CE MODE PROUVE, ET CE QU'IL NE PROUVE PAS.
    # osmo-gapk construit UNE chaine "format d'entree -> canon -> format de
    # sortie" : le codec n'apparait que du cote ou le format EST un format
    # codec. PCM -> fr -> PCM n'est donc PAS exprimable en une invocation, et
    # $fmt n'est volontairement pas utilise ici. Ce loopback valide le chemin
    # ALSA (capture, cadence, peripheriques), PAS le vocodeur FR.
    # Pour eprouver le vocodeur : `record` puis `playback` du .gsm obtenu.
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
    # `--list-codecs` n'existe pas dans osmo-gapk : l'option echouait, et seul
    # le `||` de repli produisait la liste - en imprimant d'abord une erreur
    # d'usage qui donnait l'air casse un mode qui marchait. On interroge
    # directement --help, qui est la source de verite des noms.
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
