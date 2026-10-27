#!/bin/bash
# wslg-audio-bridge.sh - sends the audio of the Osmocom containers to the host
# speakers, from inside Docker. Works in two cases:
#
#   • WSL2 + WSLg  : the audio host = WSLg PulseServer (/mnt/wslg/PulseServer),
#                    which itself relays to Windows.
#   • native Linux : the audio host = the PulseAudio/PipeWire of the graphical
#                    session (/run/user/<uid>/pulse/native).
#
# Principle:
#   host-relay  → exposes the host pulse over TCP (module-native-protocol-tcp)
#   container   → direct audio bridge inside the container:
#                     parec(gsm_audio.monitor) | paplay(--server=tcp:<gw>:4713)
#
# module-tunnel-sink is not used: over TCP/WSL its clock drifts (latency
# climbs above 1 s → choppy sound). parec|paplay = a single clock server (the
# host's) + a plain byte pipe → clean audio.
#
# The container keeps its own PulseAudio; gsm_audio is untouched (the dashboard
# keeps reading gsm_audio.monitor).
#
# Usage:
#   wslg-audio-bridge.sh host-relay              # host: open pulse over TCP
#   wslg-audio-bridge.sh container <name> [gw]   # container: start the bridge
#   wslg-audio-bridge.sh test <name>             # 880Hz beep through gsm_audio
#   wslg-audio-bridge.sh down <name>             # stop the bridge
#   wslg-audio-bridge.sh all <name> [gw]         # host-relay + container + test
set -euo pipefail

TCP_PORT="${WSLG_TCP_PORT:-4713}"
# ACL: the whole private block 172.16/12 (covers the docker subnets gsm-inter/op)
TCP_ACL="${WSLG_TCP_ACL:-127.0.0.1;172.16.0.0/12}"

log()  { echo -e "  [host-audio] $*"; }
die()  { echo -e "  [host-audio][FAIL] $*" >&2; exit 1; }

# Host IP as seen from the container = gateway of its default route.
detect_gw() {
    docker exec "$1" sh -c "ip route 2>/dev/null | awk '/default/{print \$3; exit}'" 2>/dev/null || true
}

# User of the graphical session (owner of the native pulse).
# The criterion is not the name but the presence of the pulse socket: under
# `sudo -i` SUDO_USER is lost and `id -un` returns root, whose
# /run/user/0/pulse/native almost never exists. /run/user/* is scanned as a
# last resort. Same logic as session_pulse_user() in start-docker.sh.
session_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)" "$(id -un)"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    echo "${HOST_PULSE_USER:-${SUDO_USER:-$(id -un)}}"   # nothing found: fallback
}

# Runs `pactl ...` on the native host pulse, as the session user.
pactl_native() {
    local u uid rt
    u="$(session_user)"; uid="$(id -u "$u")"; rt="/run/user/${uid}"
    if [ "$(id -un)" = "$u" ]; then
        XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    else
        sudo -u "$u" XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    fi
}

# Runs any pulse tool (pactl, parec, timeout parec...) against the host pulse,
# under WSLg as well as native. Generalises pactl_native.
host_pa() {
    local bin="$1"; shift
    if [ -S /mnt/wslg/PulseServer ]; then
        PULSE_SERVER="unix:/mnt/wslg/PulseServer" "$bin" "$@"
    else
        local u uid rt
        u="$(session_user)"; uid="$(id -u "$u")"; rt="/run/user/${uid}"
        if [ "$(id -un)" = "$u" ]; then
            XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" "$bin" "$@"
        else
            sudo -u "$u" XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" "$bin" "$@"
        fi
    fi
}

# ── Host: pick a microphone source that really carries signal ────────────────
#
# The browser captures the system default source; a default input that is
# present, unmuted, at a good volume can still deliver pure digital silence.
# `pactl` cannot tell the two apart: the source has to be listened to.
#
# No device name is hard-coded (they change from one machine to the next): the
# signal is measured. Deliberately binary criterion - a live microphone always
# has a noise floor, hence non-zero bytes; a misrouted input only outputs
# zeros. `tr -d '\0' | wc -c` is enough: no python/sox dependency, it runs
# wherever parec exists.
# Beware of the false negative: a suspended source takes ~2 s to deliver its
# first bytes. Judging on a short window would declare every idle device mute.
# Two distinct cases are therefore never confused:
#   - nothing captured          -> the device did not start (undetermined)
#   - captured but all zeros    -> digital silence (the real fault)
# Up to MIC_PROBE_BYTES are read, then the pipe is cut (head closes it, parec
# gets SIGPIPE): fast on a live device, only a dead one costs the timeout.
MIC_PROBE_SECS="${MIC_PROBE_SECS:-4}"
# Second chance for a device that returned nothing (verdict 2). A suspended
# source wakes up in ~2 s; a USB card behind a hub, or a bluetooth device that
# has to negotiate its profile, needs more.
MIC_PROBE_SECS_SLOW="${MIC_PROBE_SECS_SLOW:-12}"
MIC_PROBE_BYTES="${MIC_PROBE_BYTES:-16000}"   # 1 s @ 8 kHz s16le mono
MIC_MIN_BYTES="${MIC_MIN_BYTES:-4000}"        # below this: no verdict possible
MIC_MIN_NONZERO="${MIC_MIN_NONZERO:-100}"
MIC_MAX_PROBES="${MIC_MAX_PROBES:-8}"
# 1 = never touch the host system default (only report what was measured).
# Useful on a workstation: the selection below is permanent, it survives the
# stop of osmo-operator.
MIC_KEEP_DEFAULT="${MIC_KEEP_DEFAULT:-0}"

# Prints "<captured_bytes> <nonzero_bytes>" on stdout.
# $2 = window duration (default MIC_PROBE_SECS).
probe_source() {
    local src="$1" secs="${2:-$MIC_PROBE_SECS}" tmp raw nz
    tmp="$(mktemp)"
    # `|| true`: timeout exits 124, head causes a SIGPIPE - under
    # `set -o pipefail` either would kill the script.
    { host_pa timeout "$secs" parec -d "$src" \
        --format=s16le --rate=8000 --channels=1 2>/dev/null || true; } \
      | head -c "$MIC_PROBE_BYTES" > "$tmp" 2>/dev/null || true
    raw="$(wc -c < "$tmp")"; nz="$(tr -d '\000' < "$tmp" | wc -c)"
    rm -f "$tmp"
    echo "${raw:-0} ${nz:-0}"
}

# 0 = signal, 1 = digital silence, 2 = undetermined (nothing captured)
source_verdict() {
    local r raw nz secs="${2:-$MIC_PROBE_SECS}"
    r="$(probe_source "$1" "$secs")"; raw="${r%% *}"; nz="${r##* }"
    [ "$raw" -ge "$MIC_MIN_BYTES" ] || return 2
    [ "$nz"  -ge "$MIC_MIN_NONZERO" ] || return 1
    return 0
}

# Verdict 2 (nothing captured) is undetermined, not a fault: a device that is
# merely slow to start gets a longer look before another input is preferred.
verdict_retry() {
    local src="$1" rc=0
    source_verdict "$src" || rc=$?
    [ "$rc" = "2" ] || return "$rc"
    log "[mic]   ${src} : rien en ${MIC_PROBE_SECS}s - seconde chance sur ${MIC_PROBE_SECS_SLOW}s"
    rc=0; source_verdict "$src" "$MIC_PROBE_SECS_SLOW" || rc=$?
    return "$rc"
}

host_mic() {
    command -v parec >/dev/null 2>&1 \
        || { log "[mic] parec absent - selection micro ignoree"; return 0; }
    host_pa pactl info >/dev/null 2>&1 \
        || { log "[mic] pulse hote injoignable - selection micro ignoree"; return 0; }

    # Scope: this function sets the default of the host pulse. The dashboard
    # microphone is the one of the workstation displaying the page
    # (getUserMedia -> WebSocket -> pacat -> gsm_mic). The two only coincide
    # when browsing from the host machine. From another workstation, the page
    # selector (web/index.html, #mic-dev) decides, nothing else.
    log "[mic] selection de l'entree du PULSE DE L'HOTE (le navigateur, lui,"
    log "[mic]   utilise le micro de SON poste - selecteur dans le tableau de bord)."

    local cur rc; cur="$(host_pa pactl get-default-source 2>/dev/null || true)"
    if [ -n "$cur" ]; then
        # `|| rc=$?` is mandatory: under `set -e` a bare call of source_verdict
        # returning 1 (silence) or 2 (nothing captured) would kill the script
        # on the spot, without a log line.
        rc=0; verdict_retry "$cur" || rc=$?
        case "$rc" in
            0) log "[mic] source par defaut deja valide : ${cur}"; return 0 ;;
            1) log "[mic] defaut '${cur}' : SILENCE NUMERIQUE - recherche d'une autre entree..." ;;
            2) log "[mic] defaut '${cur}' : aucune donnee meme en ${MIC_PROBE_SECS_SLOW}s - recherche..." ;;
        esac
    fi

    if [ "$MIC_KEEP_DEFAULT" = "1" ]; then
        log "[mic] MIC_KEEP_DEFAULT=1 - defaut systeme laisse tel quel, pas de bascule."
        return 0
    fi

    local src i=0
    for src in $(host_pa pactl list short sources 2>/dev/null | awk '{print $2}' | grep -v '\.monitor$'); do
        [ "$src" = "$cur" ] && continue
        i=$((i + 1)); [ "$i" -gt "$MIC_MAX_PROBES" ] && break
        rc=0; verdict_retry "$src" || rc=$?        # see the set -e remark above
        if [ "$rc" = "0" ]; then
            if host_pa pactl set-default-source "$src" >/dev/null 2>&1; then
                log "[mic] source par defaut -> ${src} (signal detecte)"
                # The switch is permanent: pulse keeps it after osmo-operator
                # stops. The previous value is logged so that going back is a
                # command, not an investigation.
                [ -n "$cur" ] && log "[mic]   ancien defaut : ${cur}"
                [ -n "$cur" ] && log "[mic]   restaurer : pactl set-default-source ${cur}"
                log "[mic]   (MIC_KEEP_DEFAULT=1 desactive cette bascule)"
                log "[mic]   un onglet qui tient deja le micro reste epingle sur"
                log "[mic]   l'ancien peripherique : recouper/relancer le bouton micro."
                return 0
            fi
        else
            log "[mic]   ${src} : $([ "$rc" = 1 ] && echo 'silence numerique' || echo 'aucune donnee')"
        fi
    done

    log "[mic][!] AUCUNE source micro ne produit de signal (${i} testee(s))."
    log "[mic][!]   -> micro coupe materiellement (touche/interrupteur) ?"
    log "[mic][!]   -> mauvais profil UCM : verifier 'pactl list cards' / alsamixer."
    log "[mic][!]   Sans ca l'echo-test rendra le HP mais jamais la voix."
    return 0
}

# ── Host: expose the host pulse over TCP (idempotent) ────────────────────────
host_relay() {
    if [ -S /mnt/wslg/PulseServer ]; then
        # WSL2 + WSLg: world-accessible socket (root OK)
        export PULSE_SERVER="unix:/mnt/wslg/PulseServer"
        if pactl list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP deja actif (WSLg) :${TCP_PORT}"; return 0
        fi
        pactl load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (WSLg)"
        log "relai TCP WSLg → Windows active :${TCP_PORT}"
    else
        # native Linux: pulse of the graphical session
        local u uid; u="$(session_user)"; uid="$(id -u "$u")"
        [ -S "/run/user/${uid}/pulse/native" ] \
            || die "pulse de session introuvable (/run/user/${uid}/pulse/native) - session audio demarree ? user=$u"
        if pactl_native list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP deja actif (natif, user=$u) :${TCP_PORT}"; return 0
        fi
        pactl_native load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (natif)"
        log "relai TCP natif active (user=$u) :${TCP_PORT}"
    fi
}

# ── Container: supervised parec|paplay bridge to the host pulse ──────────────
container_bridge() {
    local name="$1" gw="${2:-}"
    [ -n "$name" ] || die "nom de conteneur requis"
    [ -z "$gw" ] && gw="$(detect_gw "$name")"
    [ -n "$gw" ] || die "gateway introuvable pour $name"
    docker exec -i "$name" sh -s -- "tcp:${gw}:${TCP_PORT}" <<'EOSH'
set -eu
RELAY="$1"
pactl info >/dev/null 2>&1 || { echo "  [host-audio][FAIL] pas de daemon pulse dans le conteneur" >&2; exit 1; }
# The host relay must be reachable
if ! pactl --server="$RELAY" info >/dev/null 2>&1; then
    echo "  [host-audio][FAIL] relai hote injoignable ($RELAY) - lancer 'host-relay' d'abord" >&2; exit 1
fi
# Stop a previous bridge (idempotent)
pkill -f "paplay --server=${RELAY}" 2>/dev/null || true
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
mkdir -p /var/log/osmocom
# Supervised bridge: restarts if parec/paplay dies. setsid = new group → clean kill.
setsid sh -c '
  while true; do
    parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
      | paplay --server='"${RELAY}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
    sleep 1
  done' >/var/log/osmocom/host-audio.log 2>&1 &
echo $! > /run/host-audio.pid
echo "  [host-audio] pont parec|paplay gsm_audio.monitor -> ${RELAY} (pgid $!)"
EOSH
}

# ── Container: test beep through gsm_audio (end-to-end proof) ────────────────
container_test() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=880:duration=1" -ar 8000 -ac 1 /tmp/host_test.wav
paplay -d gsm_audio /tmp/host_test.wav
echo "  [host-audio] bip 880Hz injecte dans gsm_audio -> hote"
EOSH
}

container_down() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
pkill -f 'parec -d gsm_audio.monitor' 2>/dev/null || true
rm -f /run/host-audio.pid
echo "  [host-audio] pont arrete"
EOSH
}

cmd="${1:-}"; shift || true
case "$cmd" in
    host-relay) host_relay ;;
    host-mic)   host_mic ;;
    container)  container_bridge "${1:-}" "${2:-}" ;;
    test)       container_test "${1:-}" ;;
    down)       container_down "${1:-}" ;;
    all)        host_relay; host_mic; container_bridge "${1:-}" "${2:-}"; container_test "${1:-}" ;;
    *) echo "usage: $0 {host-relay|host-mic|container <name> [gw]|test <name>|down <name>|all <name> [gw]}" >&2; exit 2 ;;
esac
