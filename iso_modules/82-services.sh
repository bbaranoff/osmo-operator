#!/bin/bash
# iso_modules/82-services.sh - role marker, os-release, asterisk, dashboard, audio, PulseAudio
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not meant to run on its own. A top-level `return` means "nothing to do here"
# (this is how --arm skips a step).

# ── Role marker: what this image is ────────────────────────────────────────
# Read by start-native.sh and the login banner, so images built from the same
# pipeline can be told apart once booted.
{
    printf '# /etc/osmo-role - genere par build-iso.sh\n'
    printf 'OSMO_ROLE=%s\n' "$ISO_ROLE"
    [ -n "$ISO_NODE" ] && printf 'OSMO_WAN_NODE=%s\n' "$ISO_NODE"
    # Lite images lack the /opt/GSM build trees; record it so the machine can
    # report it itself.
    printf 'OSMO_LITE=%s\n' "$ISO_LITE"
    printf 'OSMO_HUB_IP=%s\n' "$ISO_HUB_IP"
} > "$ROOTFS/etc/osmo-role"

# ── /etc/os-release: the image names itself ────────────────────────────────
# The login banner, `hostnamectl`, bug reports and the dashboard read
# os-release, so it must distinguish hub, node and lite variant.
#
# Only display fields are changed. ID, VERSION_ID, VERSION_CODENAME and
# UBUNTU_CODENAME stay Ubuntu's: apt, add-apt-repository and many package
# scripts use them to pick repositories.
# VARIANT / VARIANT_ID are the os-release(5) fields meant for this distinction;
# IMAGE_ID / IMAGE_VERSION are meant for built images.
case "$ISO_ROLE" in
    interstp) OS_NAME="osmo-operator interstp"; OS_VARIANT_ID="interstp" ;;
    *)        if [ "$ISO_LITE" = "1" ]; then
                  OS_NAME="osmo-operator-lite"; OS_VARIANT_ID="operator-lite"
              else
                  OS_NAME="osmo-operator";      OS_VARIANT_ID="operator"
              fi ;;
esac
# When the node number is baked into the image it is part of the identity:
# it is the only difference between osmo-operator-1.iso and osmo-operator-2.iso.
OS_PRETTY="$OS_NAME"
[ -n "$ISO_NODE" ] && OS_PRETTY="$OS_NAME (noeud $ISO_NODE)"

# /etc/os-release is a symlink to ../usr/lib/os-release: write the target and
# keep the link, otherwise the two paths (both read by various tools) diverge.
_osrel="$ROOTFS/usr/lib/os-release"
sed -i -e '/^NAME=/d' -e '/^PRETTY_NAME=/d' \
       -e '/^VARIANT=/d' -e '/^VARIANT_ID=/d' \
       -e '/^IMAGE_ID=/d' -e '/^IMAGE_VERSION=/d' \
       -e '/^HOME_URL=/d' -e '/^SUPPORT_URL=/d' -e '/^BUG_REPORT_URL=/d' \
       "$_osrel"
{
    printf 'NAME="%s"\n'          "$OS_NAME"
    printf 'PRETTY_NAME="%s"\n'   "$OS_PRETTY"
    printf 'VARIANT="%s"\n'       "$OS_PRETTY"
    printf 'VARIANT_ID="%s"\n'    "$OS_VARIANT_ID"
    printf 'IMAGE_ID="%s"\n'      "$OS_NAME"
    printf 'IMAGE_VERSION="%s"\n' "$LABEL"
    printf 'HOME_URL="https://github.com/bbaranoff/osmo-operator"\n'
    printf 'SUPPORT_URL="https://github.com/bbaranoff/osmo-operator"\n'
    printf 'BUG_REPORT_URL="https://github.com/bbaranoff/osmo-operator/issues"\n'
} >> "$_osrel"
echo -e "  ${GREEN}✓${NC} os-release : ${CYAN}${OS_PRETTY}${NC}"

# ── Asterisk: single owner, run_modules/19-asterisk.sh ──────────────────────
# The asterisk package ships its unit enabled; a systemd-started Asterisk
# would compete with the one started by 19-asterisk.sh for /etc/asterisk and
# the asterisk.ctl socket. The module also disables it at each start; doing
# it here keeps the first boot of a fresh ISO clean.
chroot "$ROOTFS" systemctl disable asterisk >/dev/null 2>&1 || true
echo -e "  ${GREEN}✓${NC} asterisk.service desactive - le PBX est lance par ${CYAN}19-asterisk.sh${NC}"

if [ "$ISO_ROLE" = "interstp" ]; then
    # The hub must start on its own: nodes attach to it at boot, so a hub that
    # has to be started by hand breaks simultaneous startup.
    cat > "$ROOTFS/etc/systemd/system/osmo-interstp.service" <<EOF
[Unit]
Description=osmo-operator inter-STP - hub SS7 du WAN (PC 0.0.0)
# network.target is enough: the default route may come later, which the
# service tolerates. No network-online.target (boot delay).
After=network.target
[Service]
Type=forking
PIDFile=/run/osmo-interstp.pid
ExecStart=/opt/GSM/osmo-operator/launch/start-interstp.sh --ip ${ISO_HUB_IP}
ExecStop=/opt/GSM/osmo-operator/launch/start-interstp.sh --stop
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    chroot "$ROOTFS" systemctl enable osmo-interstp 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} osmo-interstp.service - hub lance au demarrage sur ${CYAN}${ISO_HUB_IP}${NC}"
fi


# Root autologin is configured later (8d, getty@tty1.service.d/10-autologin-root.conf).

# ── Web dashboard service ──────────────────────────────────────────────────
# The unit file is services/osmo-egprs-web.service, copied at step 6 (single
# source of truth, with TLS_CERT/TLS_KEY, PULSE_SERVER and CAP_IFACE). Only
# enable it here; never rewrite it.
# The hub has no operator VTY or radio to show: the dashboard is not enabled there.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# ── 4G subscriber console (Open5GS WebUI, :9999) ───────────────────────────
# Installed and enabled by default, like the 2G dashboard. On images without a
# built WebUI its ConditionPathExists (services/open5gs-webui.service) skips
# it cleanly. The hub has no 4G core: not enabled there.
if [ "$ISO_ROLE" != "interstp" ]; then
    if [ -f "$DIR/services/open5gs-webui.service" ]; then
        install -m644 "$DIR/services/open5gs-webui.service" \
                "$ROOTFS/etc/systemd/system/open5gs-webui.service"
        mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
        chroot "$ROOTFS" systemctl enable open5gs-webui 2>/dev/null || \
            ln -sf /etc/systemd/system/open5gs-webui.service \
                   "$ROOTFS/etc/systemd/system/multi-user.target.wants/open5gs-webui.service"
        echo -e "  ${GREEN}✓${NC} ${CYAN}open5gs-webui.service${NC} pose et active au boot (console abonnes 4G, :9999)"
    else
        echo -e "  ${RED}✗ services/open5gs-webui.service introuvable${NC}" >&2; exit 1
    fi
fi

# ── Bench services are installed but not started at boot ──────────────────
# services/osmo-banc.service (standalone: start-native.sh) and
# services/osmo-multi.service (multi-operator: start-multi.sh) keep their
# stack in tmux: `tmux attach -t calypso` from any root terminal takes over.
# launch.sh and start-multi.sh detect the unit and go through it.
#
# Starting a bench is an operator action (node, --dsp and topology are chosen
# first), not a boot side effect:
#   systemctl start osmo-banc          one session (or the desktop icon)
#   systemctl enable --now osmo-banc   restart it at every boot
# At build time OSMO_ISO_BANC=1 (or --banc) and OSMO_ISO_MULTI=1 (or --multi)
# enable them at boot, per image.
# osmo-lte (services/osmo-lte.service: Open5GS + srsENB + srsUE, the "4G du
# banc" icon) follows the same rule: OSMO_ISO_LTE=1 enables it at boot.
# Without srsenb (interstp, arm64) its Condition skips it.
if [ "$ISO_ROLE" != "interstp" ]; then
    # osmo-supplements: installed, not enabled; the Calamares osmosupplements job
    # enables it in the target when a box on the "Supplements" page is ticked.
    for _u in osmo-banc osmo-multi osmo-lte osmo-supplements; do
        if [ -f "$DIR/services/$_u.service" ]; then
            install -m644 "$DIR/services/$_u.service" "$ROOTFS/etc/systemd/system/$_u.service"
        else
            echo -e "  ${RED}✗ services/$_u.service introuvable${NC}" >&2; exit 1
        fi
    done
    # `systemctl disable` alone is not enough: the base image may already carry
    # the multi-user.target.wants/ link, and `disable` in the chroot fails
    # silently when systemd is not running. Remove the link directly (what
    # `disable` does anyway, the mirror of the `ln -sf` fallback for `enable`).
    mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    for _u in osmo-banc osmo-multi osmo-lte; do
        # osmo-banc -> OSMO_ISO_BANC, osmo-multi -> OSMO_ISO_MULTI; ${!_var} is
        # bash indirect expansion (value of the variable named by $_var), not eval.
        _var="OSMO_ISO_${_u#osmo-}"; _var="${_var^^}"
        if [ "${!_var:-0}" = "1" ]; then
            chroot "$ROOTFS" systemctl enable "$_u" 2>/dev/null || \
                ln -sf "/etc/systemd/system/$_u.service" \
                       "$ROOTFS/etc/systemd/system/multi-user.target.wants/$_u.service"
            echo -e "  ${GREEN}✓${NC} ${CYAN}$_u.service${NC} pose ET active au boot (${_var}=1)"
        else
            chroot "$ROOTFS" systemctl disable "$_u" 2>/dev/null || true
            rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/$_u.service"
            echo -e "  ${GREEN}✓${NC} ${CYAN}$_u.service${NC} pose, ${BOLD}non active${NC} au boot · ${CYAN}systemctl start $_u${NC} pour le lancer, ${CYAN}${_var}=1${NC} au build pour l'activer"
        fi
    done
fi

# ── Audio: system PulseAudio (gsm_audio sink) at boot ──────────────────────
# Chain: osmo-gapk → ALSA gsm_out → null sink gsm_audio → monitor → loopback
# → sound card. system.pa allows anonymous access and declares the sinks; the
# service starts the daemon at boot (ensure_pulse in start-native.sh is then a no-op).
if [ -f "$ROOTFS/etc/pulse/system.pa" ]; then
    sed -i 's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' \
        "$ROOTFS/etc/pulse/system.pa"
    # Both gsm_audio and gsm_mic must be declared: lib/audio.sh treats them as a
    # pair (GSM_SINKS) and configs/asound.conf maps pcm.gsm_in to gsm_mic.monitor.
    # Without gsm_mic, gapk_io fails to open 'gsm_in' and drops both directions
    # (call established but silent).
    for _s in "gsm_audio:GSM_Audio" "gsm_mic:GSM_Mic"; do
        _n="${_s%%:*}"; _d="${_s##*:}"
        grep -q "sink_name=${_n}\b" "$ROOTFS/etc/pulse/system.pa" || \
            echo "load-module module-null-sink sink_name=${_n} format=s16le rate=8000 channels=1 sink_properties=device.description=${_d}" \
            >> "$ROOTFS/etc/pulse/system.pa"
    done
fi
# /etc/asound.conf defines the gsm_out/gsm_in PCMs opened by `mobile`;
# without it TCH voice never reaches gsm_audio.
if [ -f "$DIR/configs/asound.conf" ]; then
    cp -f "$DIR/configs/asound.conf" "$ROOTFS/etc/asound.conf"
    echo -e "  ${GREEN}✓${NC} /etc/asound.conf (PCM gsm_out/gsm_in → sinks PulseAudio)"
fi
cat > "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh" <<'ACHAIN'
#!/bin/bash
# osmo-audio-chain.sh - complete the local audio chain once PulseAudio is up.
# Called as ExecStartPost by osmo-pulse.service. Ensures:
#   1. /etc/asound.conf is present (PCM gsm_out/gsm_in)
#   2. both null sinks gsm_audio + gsm_mic are loaded
#   3. module-loopback gsm_audio.monitor → sound card
# Without (2) gapk_io drops both directions; without (3) downlink voice is
# discarded by the null sink. Always exits 0: audio must never block the
# stack. AUDIO=0 or AUDIO_LOCAL_LOOPBACK=0 disable it.
set -u
for r in /opt/GSM/osmo-operator /etc/osmocom/osmo-operator; do
    [ -x "$r/scripts/audio-chain.sh" ] && exec "$r/scripts/audio-chain.sh" "${1:-30}"
done
exit 0
ACHAIN
chmod +x "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh"

cat > "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh" <<'PLINK'
#!/bin/sh
# osmo-pulse-link.sh [uid] - make the system PulseAudio visible to clients
# that look for a per-user socket.
#
# In system mode PulseAudio only listens on /run/pulse/native, while clients
# look at $XDG_RUNTIME_DIR/pulse/native (/run/user/<uid>/pulse). Without that
# path a browser sees no device ("NotFoundError" on the microphone).
#
# Always exits 0: audio must never block the stack.
#
# ── Called twice, both matter ─────────────────────────────────────────────
#   1. without argument, by osmo-pulse.service (ExecStartPost): sessions
#      already open when the daemon (re)starts.
#   2. with a uid, by the user@.service drop-in (ExecStartPre=+, i.e. as
#      root): every session opened afterwards. At boot osmo-pulse.service
#      starts before the first login, so /run/user/<uid> of an installed
#      system's user (uid >= 1000) does not exist yet.
#
# ── Socket owner, not only the path ───────────────────────────────────────
# An AppArmor-confined client may be allowed the path only with the `owner`
# qualifier (file owner == process fsuid). The socket belongs to `pulse`, so
# the connection would be refused. Such rules apply to the real path: the
# symlink below does not hide /run/pulse/native.
#
# The socket is therefore given to the graphical session's uid. A socket has
# a single owner: the last human session opened gets it. Service accounts
# (gdm, uid < 1000) are excluded, otherwise gdm, whose user@.service starts
# first, would keep it. OSMO_PULSE_UID forces the value.
# The daemon still runs as `pulse`: accept() needs no ownership, and mode
# srwxrwxrwx lets everyone connect.
set -u

# The symlink, for the given uid or for all open sessions.
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    _dirs="/run/user/$1"
else
    _dirs=$(echo /run/user/*)
fi
for d in $_dirs; do
    [ -d "$d" ] || continue
    mkdir -p "$d/pulse" 2>/dev/null || continue
    # -f: a leftover pipewire-pulse socket must be replaced; without -f ln
    # fails silently and the session stays mute.
    ln -sfn /run/pulse/native "$d/pulse/native" 2>/dev/null || true
done

# The owner. With an argument: that session, if it is a human one.
# Otherwise the active graphical session, and root as a last resort
# (the live USB account).
PUID="${OSMO_PULSE_UID:-}"
if [ -z "$PUID" ] && [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    [ "$1" -ge 1000 ] 2>/dev/null && PUID="$1"
    [ "$1" = "0" ] && PUID=0
fi
if [ -z "$PUID" ]; then
    PUID=$(loginctl list-sessions --no-legend 2>/dev/null \
           | awk '$2 == 0 || $2 >= 1000 {print $2; exit}')
fi
[ -n "$PUID" ] || PUID=0
[ -S /run/pulse/native ] && chown "$PUID" /run/pulse/native 2>/dev/null || true
exit 0
PLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh"

# ── The link is created at every session start ────────────────────────────
# See the osmo-pulse-link.sh header: at boot osmo-pulse.service cannot link a
# session that does not exist yet. systemd-logind creates /run/user/<uid>
# then starts user@<uid>.service; this drop-in hooks the script there, once
# per session.
#
# `ExecStartPre=+`: `+` runs the command as root despite user@.service's
# User=; otherwise chown of the socket (owned by `pulse`) would fail.
install -d "$ROOTFS/etc/systemd/system/user@.service.d"
cat > "$ROOTFS/etc/systemd/system/user@.service.d/10-osmo-pulse-link.conf" <<'UAT'
[Service]
ExecStartPre=+/usr/local/sbin/osmo-pulse-link.sh %i
UAT

# ── Default server, for clients that ignore the link ───────────────────────
# libpulse reads /etc/pulse/client.conf and its .d directory before deriving
# a path from XDG_RUNTIME_DIR. `default-server` therefore works regardless of
# races, uid or start order: GNOME, Firefox, VLC and gapk reach the system
# daemon even if the link is missing.
#
# `autospawn = no` too: otherwise a client that finds no server spawns its own
# pulseaudio, which cannot grab the cards (held by the system daemon) and
# leaves the session with an empty server.
install -d "$ROOTFS/etc/pulse/client.conf.d"
cat > "$ROOTFS/etc/pulse/client.conf.d/50-osmo-system-server.conf" <<'PCLIENT'
# Installed by build-iso.sh (iso_modules/82-services.sh).
# The bench runs a system PulseAudio (osmo-pulse.service): all clients,
# whatever their uid, connect to it. Without this line each session looks
# for a server in its own /run/user/<uid> and finds none.
default-server = unix:/run/pulse/native
autospawn = no
PCLIENT
echo -e "  ${GREEN}✓${NC} audio session : ${CYAN}client.conf.d/50-osmo-system-server.conf${NC} + lien pose a chaque ouverture (user@.service)"

cat > "$ROOTFS/etc/systemd/system/osmo-pulse.service" <<'EOF'
[Unit]
Description=osmo-operator PulseAudio system daemon (GSM audio)
# sound.target is passive: it is reached once systemd has processed the known
# udev rules, not when the cards are present. module-udev-detect picks up
# late cards, but the loopback to the card is set up only once; the wait
# lives in scripts/audio-chain.sh (delay argument) instead of pulling the
# obsolete systemd-udev-settle, which would delay the whole boot.
After=sound.target
Wants=sound.target
[Service]
# ── Type=notify and --daemonize=no go together ────────────────────────────
# With Type=forking + --daemonize=yes, systemd guesses the main PID among the
# cgroup survivors and may pick a dead worker, then kill the real daemon
# (KillMode=control-group): /run/pulse/native never appears. With
# --daemonize=no the started process is the daemon, and pulseaudio (linked
# to libsystemd) sends sd_notify(READY=1) once its modules are loaded, as the
# packaged unit does ("notify will only work if --daemonize=no").
# Type=notify also delays ExecStartPost until READY=1, so the scripts below
# never race the socket creation.
Type=notify
ExecStart=/usr/bin/pulseaudio --system --daemonize=no --disallow-exit --exit-idle-time=-1 --log-target=journal
ExecStartPre=/bin/mkdir -p /var/log/osmocom /var/run/pulse
# ── The socket where applications look for it ─────────────────────────────
# In system mode PulseAudio only listens on /run/pulse/native, while
# applications look for /run/user/<uid>/pulse/native; without it
# getUserMedia returns "NotFoundError". Set up by the daemon unit itself, so
# it survives a service restart.
ExecStartPost=/usr/local/sbin/osmo-pulse-link.sh
# gsm_audio (module-null-sink) needs a consumer, otherwise downlink voice is
# discarded and the call is silent: the loopback to the card is set up here,
# by the daemon unit, so it survives a restart. Non-fatal (always exits 0).
# AUDIO_LOCAL_LOOPBACK=0 disables it.
# Goes through a /usr/local/sbin wrapper: an ExecStartPost=/bin/sh -c with
# nested quotes is rejected by the unit parser and silently ignored.
ExecStartPost=/usr/local/sbin/osmo-audio-chain.sh 30
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# Same for audio: the hub carries no calls, it only routes signalling.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-pulse 2>/dev/null||true

# Kernel modules
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Environment variables
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# root bashrc
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
# Activate by default the Python environment (gr-gsm + bridges) used by
# /opt/GSM/osmo-operator/start-native.sh. VIRTUAL_ENV_DISABLE_PROMPT keeps PS1.
export VIRTUAL_ENV_DISABLE_PROMPT=1
[ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
# /etc/osmocom/coeur.env is loaded here because environment/load.env only
# looks in its own directory. set -a exports the values to start-native.sh;
# the file's ":=" idiom lets e.g. N_MS=3 ./start-native.sh override them.
if [ -f /etc/osmocom/coeur.env ]; then set -a; . /etc/osmocom/coeur.env; set +a; fi
# Shortcuts for the bench.
alias osmo-lab='cd /opt/GSM/osmo-operator; ./start-native.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/etc/osmocom/status.sh status'
export PATH="$HOME/.local/bin:$PATH"

### calypso-prompt ###
export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️ # '
### end calypso-prompt ###
BASH

# Message of the day: colour banner and aligned box. Box content is ASCII
# (no multi-byte characters) with printf padding so the borders align.
# Generated at build time to embed ANSI colours in /etc/motd.
{
  B=$'\033[1;36m'; T=$'\033[1;37m'; G=$'\033[1;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
  W=58
  printf '\n%b' "$B"
  cat <<'LOGO'
    ___  ___ _ __ ___   ___    ___  __ _ _ __  _ __ ___
   / _ \/ __| '_ ` _ \ / _ \  / _ \/ _` | '_ \| '__/ __|
  | (_) \__ \ | | | | | (_) ||  __/ (_| | |_) | |  \__ \
   \___/|___/_| |_| |_|\___/  \___|\__, | .__/|_|  |___/
                                   |___/|_|
LOGO
  printf '%b' "$N"
  printf "${B}  ╔"; printf '═%.0s' $(seq 1 $W); printf "╗${N}\n"
  printf "${B}  ║${N} ${T}%-*s${N} ${B}║${N}\n" $((W-2)) "GSM / EGPRS  Multi-PLMN  Live System"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "SS7/SIGTRAN  -  Osmocom  -  Calypso/QEMU"
  printf "${B}  ╠"; printf '═%.0s' $(seq 1 $W); printf "╣${N}\n"
  # Path of the bench launcher (same as the login message and the
  # osmo-start-direct link).
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "/opt/GSM/osmo-operator/start-native.sh"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "    -> lance le lab Calypso/QEMU (A5/1)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "Dashboard web  ->  http://<vm-ip>:8080"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "FFT spectres   ->  http://<vm-ip>:8081"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "Wiki / docs        ->  pl4y.store"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "ssh root@<vm-ip>   -> mot de passe : osmo"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "loadkeys fr   -> changer le clavier (apres boot)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "osmo-update   -> met a jour les depots (git en place)"
  printf "${B}  ╚"; printf '═%.0s' $(seq 1 $W); printf "╝${N}\n\n"
} > "$ROOTFS/etc/motd"

# Root password = "osmo" (console autologin + SSH login). The password is
# not emptied (sshd would refuse root login).
echo 'root:osmo' | chroot "$ROOTFS" chpasswd 2>/dev/null || true

# ── Default policy: no telecom service at boot ────────────────────────────
# The services/80-osmo-operator.preset preset is installed in the rootfs and
# any telecom unit already enabled (asterisk/ofono packages enabling
# themselves, upstream osmo-* units, base image) is disabled. Only explicit
# build requests stay enabled: OSMO_ISO_BANC / _MULTI / _LTE=1, and the
# osmo-interstp hub for the interstp role.
_garder=()
[ "$ISO_ROLE" = "interstp" ] && _garder+=(osmo-interstp)
[ "${OSMO_ISO_BANC:-0}" = 1 ]  && _garder+=(osmo-banc)
[ "${OSMO_ISO_MULTI:-0}" = 1 ] && _garder+=(osmo-multi)
[ "${OSMO_ISO_LTE:-0}" = 1 ]   && _garder+=(osmo-lte)
bash "$DIR/tools/osmo-telecom-boot.sh" --root "$ROOTFS" ${_garder[@]+--garder "${_garder[@]}"} || true

# End of module: `. file` returns the status of its last command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
