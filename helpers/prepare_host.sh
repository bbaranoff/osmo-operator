#!/usr/bin/env bash
# prepare_host.sh - reset the host-side desktop tools of the GSM bench.
# Usage: sudo ./helpers/prepare_host.sh
# Steps:
#  - kill and relaunch Linphone as the session user
#  - kill xterm and Wireshark (root)
#  - check the UDP/GSMTAP listeners
# Env: GSMTAP_PORT (default 4729), HOST_PULSE_USER (session user override).
# Display: "[....] step" is rewritten in place as "[ OK ] step".

set -euo pipefail

GSMTAP_PORT="${GSMTAP_PORT:-4729}"

# ---------- helpers ----------
step()    { printf "[....] %s" "$1"; }
step_ok() { printf "\r[ OK ] %s\n" "$1"; }
fail()    { printf "\r[FAIL] %s\n" "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "Commande manquante: $1"; }

kill_name_as_user() {
  local user="$1" name="$2"
  pkill -u "$user" -x "$name" 2>/dev/null || true
}

kill_name_root() {
  local name="$1"
  pkill -x "$name" 2>/dev/null || true
}

# ---------- preflight ----------
[[ "${EUID}" -eq 0 ]] || fail "Lance en root: sudo $0"

need sudo
need docker
need ss
need systemctl

# ---------- session user ----------
# The session user is identified by the PRESENCE of its pulse socket, not by
# the account name: SUDO_USER is empty after `sudo -i`, and on the --desktop
# ISO the graphical session is root itself. Same logic as session_pulse_user()
# in launch/start-docker.sh.
resolve_session_user() {
  local u uid sock
  for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)"; do
    [[ -n "$u" ]] || continue
    uid="$(id -u "$u" 2>/dev/null)" || continue
    [[ -S "/run/user/${uid}/pulse/native" ]] && { echo "$u"; return 0; }
  done
  # Owner of the first pulse socket found: covers `sudo -i` and sessions
  # without logname (cron, service, detached terminal).
  for sock in /run/user/*/pulse/native; do
    [[ -S "$sock" ]] || continue
    uid="${sock#/run/user/}"; uid="${uid%%/*}"
    u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
    [[ -n "$u" ]] && { echo "$u"; return 0; }
  done
  # No live pulse session: fall back to the invoker, root included.
  echo "${SUDO_USER:-$(id -un)}"
}
TARGET_USER="$(resolve_session_user)"

id -u "${TARGET_USER}" >/dev/null 2>&1 || fail "User invalide: ${TARGET_USER}"

# ---------- Linphone: kill + relaunch as the session user ----------
step "Linphone: kill (user=${TARGET_USER})"
kill_name_as_user "${TARGET_USER}" "linphone"
sleep 0.2
step_ok "Linphone: kill (user=${TARGET_USER})"

step "Linphone: relance (user=${TARGET_USER})"
    # TARGET_USER is resolved once, at the top of the script; do not
    # re-resolve it here.
    TARGET_UID=$(id -u "$TARGET_USER")
    # HOME via getent, not a hard-coded /home/$TARGET_USER: root lives in /root.
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-${TARGET_HOME:-/home/$TARGET_USER}/.Xauthority}"

    setsid sudo -u "$TARGET_USER" \
        env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        linphone </dev/null >/dev/null 2>&1 &

step_ok "Linphone: relance (user=${TARGET_USER})"

# ---------- Xterm: kill ----------
step "Xterm kill"
kill_name_root "xterm"
sleep 0.2
step_ok "Xterm: kill (root)"

# ---------- Wireshark: kill (root) ----------
step "Wireshark: kill (root)"
kill_name_root "wireshark"
sleep 0.2
step_ok "Wireshark: kill (root)"

# ---------- Listener check (optional) ----------
step "Check: listeners UDP/${GSMTAP_PORT}"
ss -lunp | awk -v p=":${GSMTAP_PORT}" '$0 ~ p {print}' >/dev/null 2>&1 || true
step_ok "Check: listeners UDP/${GSMTAP_PORT}"

step "Stack forcee"
step_ok "Stack forcee"
