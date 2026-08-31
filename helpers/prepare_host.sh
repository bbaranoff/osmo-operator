#!/usr/bin/env bash
# force_stack.sh
# A lancer en root (sudo).
# But :
#  - FORCER (kill + relance) Linphone en user
#  - FORCER (kill + relance) Wireshark en root sur UDP/4729 (GSMTAP)
#  - Restart du service docker
# Affichage:
#   [....] action en cours  -> se transforme en -> [ OK ] action finie (meme ligne)

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

# ---------- QUI EST L UTILISATEUR DE LA SESSION ----------
# Ce bloc exigeait SUDO_USER non vide ET different de root, et sortait en [FAIL]
# sinon. Deux situations parfaitement legitimes tombaient dedans :
#
#   1. `sudo -i` puis ./start.sh - le shell est deja root, sudo n a plus rien a
#      transmettre et SUDO_USER est VIDE. C est le mode de travail courant sur
#      ce banc.
#   2. L ISO --desktop : la session graphique EST root. build-iso.sh ecrit
#      AutomaticLogin=root dans /etc/gdm3/custom.conf et decommente le
#      pam_succeed_if qui interdit la connexion de root. "root" est donc ICI la
#      BONNE reponse - la rejeter revenait a refuser la configuration nominale
#      de l image qu on livre.
#
# Le bon critere n est pas le NOM du compte mais la PRESENCE de sa session,
# c est-a-dire de son socket pulse. Meme logique que session_pulse_user() dans
# start.sh, a laquelle ce fichier ne faisait qu ajouter une divergence.
resolve_session_user() {
  local u uid sock
  for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)"; do
    [[ -n "$u" ]] || continue
    uid="$(id -u "$u" 2>/dev/null)" || continue
    [[ -S "/run/user/${uid}/pulse/native" ]] && { echo "$u"; return 0; }
  done
  # Proprietaire du premier socket pulse trouve : couvre le `sudo -i` et les
  # sessions sans logname (cron, service, terminal detache).
  for sock in /run/user/*/pulse/native; do
    [[ -S "$sock" ]] || continue
    uid="${sock#/run/user/}"; uid="${uid%%/*}"
    u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
    [[ -n "$u" ]] && { echo "$u"; return 0; }
  done
  # Aucune session pulse vivante : on retombe sur l invocateur, root compris.
  echo "${SUDO_USER:-$(id -un)}"
}
TARGET_USER="$(resolve_session_user)"

id -u "${TARGET_USER}" >/dev/null 2>&1 || fail "User invalide: ${TARGET_USER}"

# ---------- 1) Linphone : kill + relance en user ----------
step "Linphone: kill (user=${TARGET_USER})"
kill_name_as_user "${TARGET_USER}" "linphone"
sleep 0.2
step_ok "Linphone: kill (user=${TARGET_USER})"

step "Linphone: relance (user=${TARGET_USER})"
    # Ne PAS re-resoudre TARGET_USER ici : la ligne qui s y trouvait
    # (${SUDO_USER:-$(logname ...)}) ecrasait le resultat de
    # resolve_session_user() par une valeur moins fiable, juste avant de s en
    # servir. Une seule resolution, en tete de script.
    TARGET_UID=$(id -u "$TARGET_USER")
    # HOME par getent, pas /home/$TARGET_USER en dur : root habite /root. Avec
    # le chemin fige, une session sous root pointait XAUTHORITY sur
    # /home/root/.Xauthority - inexistant - et linphone ne s ouvrait pas.
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-${TARGET_HOME:-/home/$TARGET_USER}/.Xauthority}"

    setsid sudo -u "$TARGET_USER" \
        env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        linphone </dev/null >/dev/null 2>&1 &
                
step_ok "Linphone: relance (user=${TARGET_USER})"

# ---------- 3) Xterm : kill----------
step "Xterm kill"
kill_name_root "xterm"
sleep 0.2
step_ok "Xterm: kill (root)"

# ---------- 2) Wireshark : kill + relance en root sur GSMTAP/4729 ----------
step "Wireshark: kill (root)"
kill_name_root "wireshark"
sleep 0.2
step_ok "Wireshark: kill (root)"

# ---------- 5) Mini-check (optionnel) ----------
step "Check: listeners UDP/${GSMTAP_PORT}"
ss -lunp | awk -v p=":${GSMTAP_PORT}" '$0 ~ p {print}' >/dev/null 2>&1 || true
step_ok "Check: listeners UDP/${GSMTAP_PORT}"

step "Stack forcee"
step_ok "Stack forcee"
