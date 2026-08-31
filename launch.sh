#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# launch.sh - Point d entree DOUBLE-CLIC du banc osmo-operator.
#
# Monte le poste de travail complet en un geste :
#     1. wireshark    sur udp/4729 (GSMTAP)        - root
#     2. linphone     le softphone SIP             - utilisateur de la session
#     3. firefox      sur http://127.0.0.1:8080    - des que le dashboard repond
#     4. start-direct.sh                           - le banc, au PREMIER PLAN
#
# Les trois premiers partent en arriere-plan et ne peuvent pas faire echouer le
# lancement : un outil absent se signale et on continue. start-direct.sh, lui,
# tient le terminal - c est sa sortie qu on veut lire.
#
# Trois choses separent un script qui marche au terminal d un script qui marche
# au double-clic, et elles sont traitees en tete :
#   1. PAS DE TERMINAL. Un .desktop lance sans tty : start-direct.sh ecrirait
#      dans le vide. On se relance dans un emulateur de terminal.
#   2. PAS DE ROOT. Le banc a besoin des privileges (netns, systemd, captures).
#      Depuis une icone : pkexec (fenetre graphique), repli sudo.
#   3. LA FENETRE SE FERME AVANT QU ON LISE L ERREUR. On la retient a la fin.
#
# Usage au terminal (aucun de ces detours ne s applique) :
#     sudo ./launch.sh [arguments passes a start-direct.sh]
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TARGET="$DIR/start-direct.sh"
GSMTAP_PORT="${GSMTAP_PORT:-4729}"
DASH_URL="${OSMO_DASH_URL:-http://127.0.0.1:8080}"
DASH_PORT="${DASH_URL##*:}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

[ -x "$TARGET" ] || { echo -e "${RED}start-direct.sh introuvable ou non executable dans $DIR${NC}" >&2; exit 1; }

# ── 1. Un terminal, si on n en a pas ────────────────────────────────────────
# On teste la presence d un TTY, pas $DISPLAY : c est la difference reelle entre
# « lance a la main » et « lance par une icone ». OSMO_LAUNCH_TERM marque le
# tour de relance pour ne pas boucler.
if [ ! -t 0 ] && [ "${OSMO_LAUNCH_TERM:-0}" != "1" ]; then
    export OSMO_LAUNCH_TERM=1
    for _t in gnome-terminal xfce4-terminal konsole xterm; do
        command -v "$_t" >/dev/null 2>&1 || continue
        case "$_t" in
            gnome-terminal) exec "$_t" -- "$0" "$@" ;;
            *)              exec "$_t" -e "$0" "$@" ;;
        esac
    done
fi

# ── 2. Les privileges ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        # pkexec lave l environnement : DISPLAY et XAUTHORITY sont repasses a la
        # main, sinon rien de graphique ne peut s ouvrir ensuite.
        exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
             OSMO_LAUNCH_TERM="${OSMO_LAUNCH_TERM:-0}" "$0" "$@"
    fi
    command -v sudo >/dev/null 2>&1 && exec sudo -E "$0" "$@"
    echo -e "${RED}Root requis et ni pkexec ni sudo disponibles.${NC}" >&2
    exit 1
fi

# ── L UTILISATEUR DE LA SESSION GRAPHIQUE ───────────────────────────────────
# Meme critere que helpers/prepare_host.sh et start.sh : le NOM du compte ne
# dit rien, la presence de son socket pulse si. Sur l ISO --desktop la session
# est ouverte sous root (gdm3 AutomaticLogin=root) - « root » est donc ici une
# reponse valide, pas une erreur.
session_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)"; do
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
    echo "${SUDO_USER:-$(id -un)}"
}
GUI_USER="$(session_user)"
GUI_UID="$(id -u "$GUI_USER" 2>/dev/null || echo 0)"
GUI_HOME="$(getent passwd "$GUI_USER" 2>/dev/null | cut -d: -f6)"
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${GUI_HOME:-/root}/.Xauthority}"

# Lance une application graphique sous le compte de la session. `setsid` la
# detache : elle survit a la fermeture de ce terminal, et son code de retour ne
# peut pas faire tomber launch.sh (set -e n est pas arme ici, mais on garde le
# || true pour l intention).
gui_run() {
    setsid sudo -u "$GUI_USER" \
        env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${GUI_UID}/bus" \
        "$@" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# ── LE PAVAGE 2x2 ───────────────────────────────────────────────────────────
# Chaque action prend UN QUART de l ecran :
#
#        +---------------------+---------------------+
#        |  terminal du banc   |  firefox / dashboard|
#        |  (start-direct.sh)  |  127.0.0.1:8080     |
#        +---------------------+---------------------+
#        |  wireshark          |  linphone           |
#        |  udp/4729 GSMTAP    |  postes 100 / 200   |
#        +---------------------+---------------------+
#
# Pourquoi wmctrl et pas les raccourcis GNOME : le pavage au clavier est une
# action d utilisateur, il n existe pas en ligne de commande. wmctrl parle a
# l EWMH, ce que Mutter expose EN X11 - et l ISO force X11 (build-iso.sh ecrit
# WaylandEnable=false dans gdm3/custom.conf, la session Wayland tombant sur
# llvmpipe en machine virtuelle). Sous Wayland, rien de tout ceci ne repondrait
# et le pavage serait simplement ignore, sans casser le lancement.
#
# ⚠️ Retirer les etats maximise AVANT de poser la geometrie : une fenetre
# maximisee accepte l ordre et n en tient aucun compte - elle reste plein ecran
# et l on croit wmctrl casse.
tile_windows() {
    command -v wmctrl  >/dev/null 2>&1 || { echo -e "  ${YELLOW}○${NC} wmctrl absent - fenetres non pavees"; return 0; }
    command -v xdpyinfo >/dev/null 2>&1 || { echo -e "  ${YELLOW}○${NC} xdpyinfo absent - fenetres non pavees"; return 0; }

    local sw sh qw qh
    sw="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[1]; exit}')"
    sh="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[2]; exit}')"
    [ -n "$sw" ] && [ -n "$sh" ] || return 0
    qw=$(( sw / 2 )); qh=$(( sh / 2 ))

    # $1 = motif WM_CLASS (insensible a la casse), $2 = x, $3 = y
    place() {
        local pat="$1" x="$2" y="$3" i id
        for i in $(seq 1 90); do
            id="$(wmctrl -l -x 2>/dev/null | grep -iE "$pat" | awk '{print $1; exit}')"
            [ -n "$id" ] && break
            sleep 1
        done
        [ -n "$id" ] || return 0
        wmctrl -i -r "$id" -b remove,maximized_vert,maximized_horz 2>/dev/null || true
        wmctrl -i -r "$id" -e "0,${x},${y},${qw},${qh}" 2>/dev/null || true
    }

    place 'gnome-terminal|xfce4-terminal|konsole|xterm'  0    0
    place 'firefox|navigator'                          "$qw" 0
    place 'wireshark'                                   0   "$qh"
    place 'linphone'                                   "$qw" "$qh"
}

# ── 1. WIRESHARK sur udp/4729 ───────────────────────────────────────────────
# En ROOT, et pas sous $GUI_USER : la capture sur `any` demande CAP_NET_RAW.
# -k demarre la capture tout de suite (sinon on ouvre sur un ecran de choix
# d interface, et rien n est capture tant qu on n a pas clique).
if command -v wireshark >/dev/null 2>&1; then
    setsid wireshark -k -i any -f "udp port ${GSMTAP_PORT}" \
        </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} wireshark : capture GSMTAP sur ${CYAN}udp/${GSMTAP_PORT}${NC}"
else
    echo -e "  ${YELLOW}○${NC} wireshark absent - capture GSMTAP ignoree"
fi

# ── 2. LINPHONE ─────────────────────────────────────────────────────────────
# Le compte SIP est pre-provisionne (configs/linphonerc, pose par build-iso.sh).
# ⚠️ Linphone ne relit PAS sa config a chaud : s il tourne deja, il garde son
# etat en memoire. On ne le relance donc pas de force ici - on le laisse tel
# quel plutot que de couper un appel en cours.
if command -v linphone >/dev/null 2>&1; then
    if pgrep -x linphone >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} linphone : deja lance (laisse en place)"
    else
        gui_run linphone
        echo -e "  ${GREEN}✓${NC} linphone : lance (user=${CYAN}${GUI_USER}${NC})"
    fi
else
    echo -e "  ${YELLOW}○${NC} linphone absent"
fi

# ── 3. FIREFOX sur le dashboard, QUAND IL REPOND ────────────────────────────
# Ouvrir l URL tout de suite donnerait une page d erreur : le dashboard n est
# pas encore la, et une fois l onglet en echec l utilisateur doit recharger a la
# main. On attend donc que le port reponde, en tache de fond, jusqu a 180 s.
if command -v firefox >/dev/null 2>&1; then
    (
        for _i in $(seq 1 180); do
            if (exec 3<>"/dev/tcp/127.0.0.1/${DASH_PORT}") 2>/dev/null; then
                exec 3>&- 2>/dev/null
                gui_run firefox "$DASH_URL"
                exit 0
            fi
            sleep 1
        done
    ) &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} firefox : ouvrira ${CYAN}${DASH_URL}${NC} des que le dashboard repond"
else
    echo -e "  ${YELLOW}○${NC} firefox absent - dashboard a ouvrir a la main sur ${DASH_URL}"
fi

# Le pavage part en tache de fond : chaque fenetre est placee des qu elle
# apparait, sans retarder le demarrage du banc.
tile_windows &
disown 2>/dev/null || true

# ── 4. LE BANC, AU PREMIER PLAN ─────────────────────────────────────────────
echo
cd "$DIR" || exit 1
"$TARGET" "$@"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
    echo -e "${GREEN}=== start-direct.sh termine (code 0) ===${NC}"
else
    echo -e "${RED}=== start-direct.sh a ECHOUE (code $rc) ===${NC}"
fi
# Uniquement dans une fenetre ouverte par nos soins : au terminal, rendre la
# main tout de suite est le comportement attendu.
if [ "${OSMO_LAUNCH_TERM:-0}" = "1" ]; then
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
