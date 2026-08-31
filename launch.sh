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
# Le tutoriel s ouvre en DEUXIEME ONGLET, a cote du tableau de bord. Servi par
# le dashboard (et non en file://) : Firefox est un snap, son bac a sable ne lui
# donne acces ni a /root ni aux repertoires caches - un file:// rendrait
# "L acces au fichier a ete refuse". Voir /usr/local/bin/osmo-tutorial.
TUTO_URL="${OSMO_TUTORIAL_URL:-${DASH_URL%/}/tutorial.html}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

[ -x "$TARGET" ] || { echo -e "${RED}start-direct.sh introuvable ou non executable dans $DIR${NC}" >&2; exit 1; }

# ── 1. Un terminal, si on n en a pas — OU s il n est pas a nous ─────────────
# On teste la presence d un TTY, pas $DISPLAY : c est la difference reelle entre
# « lance a la main » et « lance par une icone ». OSMO_LAUNCH_TERM marque le
# tour de relance pour ne pas boucler.
#
# [2026-08-31] DEUX DEFAUTS, LE MEME MALENTENDU : la garde demandait « y a-t-il
# UN terminal ? », jamais « est-ce LE MIEN ? ».
#   1. stdin SEUL. `./launch.sh < fichier` depuis un vrai terminal se croyait
#      lance par une icone et ouvrait une fenetre en trop, dont la sortie
#      n allait pas a l appelant. On teste donc stdin ET stdout.
#   2. UN TTY HERITE N EST PAS LE NOTRE. start-direct.sh TIENT le terminal
#      jusqu a la fin (cf. l en-tete de ce fichier). Appele par un autre
#      lanceur — start-multi.sh, qui monte le natif AVANT ses conteneurs — il
#      heritait du terminal de celui-ci, ecrivait par-dessus sa sortie et ne
#      lui rendait la main qu a la fin du natif. OSMO_TERM_TAKEN=1 dit « ce
#      terminal est deja occupe » : on ouvre alors LA NOTRE, tty ou pas.
_lt_besoin=0
{ [ ! -t 0 ] || [ ! -t 1 ]; } && _lt_besoin=1
[ "${OSMO_TERM_TAKEN:-0}" = "1" ] && _lt_besoin=1
if [ "$_lt_besoin" = "1" ] && [ "${OSMO_LAUNCH_TERM:-0}" != "1" ]; then
    export OSMO_LAUNCH_TERM=1
    unset OSMO_TERM_TAKEN            # la fenetre qu on ouvre ici EST la notre
    for _t in gnome-terminal xfce4-terminal konsole xterm; do
        command -v "$_t" >/dev/null 2>&1 || continue
        case "$_t" in
            gnome-terminal) exec "$_t" -- "$0" "$@" ;;
            *)              exec "$_t" -e "$0" "$@" ;;
        esac
    done
    # AUCUN emulateur installe. On ne reprend pas le terminal de l appelant -
    # ce serait refaire exactement la panne que cette garde empeche. On se
    # detache, et la sortie va dans un journal plutot que dans le vide.
    _lt_log="${OSMO_LAUNCH_LOG:-/var/log/osmo-launch.log}"
    echo -e "${YELLOW}Aucun emulateur de terminal - lancement detache, journal : ${_lt_log}${NC}" >&2
    exec setsid "$0" "$@" </dev/null >>"$_lt_log" 2>&1
fi

# Le drapeau a joue son role. On le RETIRE de l environnement : exporte, il
# descendait dans start-direct.sh et tout ce qui suit, ou il ferait croire a
# n importe quel descendant rappelant ce script qu il est deja dans sa fenetre
# - et plus aucune ne s ouvrirait. La valeur reste ici, dans une variable de
# shell, la ou on en a besoin (retenir la fenetre a la fin).
_own_window=0
[ "${OSMO_LAUNCH_TERM:-0}" = "1" ] && _own_window=1
unset OSMO_LAUNCH_TERM

# ── 2. Les privileges ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        # pkexec lave l environnement : DISPLAY et XAUTHORITY sont repasses a la
        # main, sinon rien de graphique ne peut s ouvrir ensuite.
        exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
             OSMO_LAUNCH_TERM="$_own_window" "$0" "$@"
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

# ── TOUT ARRETER AVANT DE RELANCER ──────────────────────────────────────────
# [2026-08-31] Un clic = un banc NEUF. Sans ca, un lancement par-dessus un banc
# deja debout ne relance presque rien : les demons Osmocom ne relisent PAS leur
# configuration a chaud. On l a paye plusieurs fois - un osmo-stp realigne sur
# le bon point code gardait l ancien en memoire, et `kill -HUP` n y change rien
# (verifie : config a jour sur le disque, ASP toujours ASP_DOWN sur l ancienne
# adresse). Le seul geste qui compte est l arret complet.
#
# On arrete le NATIF (il delegue a run.sh --stop, qui demonte proprement radio
# et coeur). Rien ici ne doit faire echouer le lancement : ce qui est deja
# arrete l est tres bien, d ou les || true.
tout_arreter() {
    echo -e "  ${CYAN}→${NC} arret du banc en place (un clic = un banc neuf)"
    if [ -x "$DIR/start-direct.sh" ]; then
        timeout 120 "$DIR/start-direct.sh" --stop >/dev/null 2>&1 || true
        echo -e "    ${GREEN}✓${NC} pile native arretee"
    fi
    # Les conteneurs ne sont PAS touches ici : start.sh fait deja
    # `docker rm -f $(docker ps -aq --filter name=osmo-)` en tete de course.
    # Le refaire serait redondant, et surtout destructeur depuis launch.sh -
    # un clic sur le telephone rouge, qui ne monte que le natif, balayerait
    # les conteneurs multi-operateur d a cote.
    # Les ponts audio survivent aux conteneurs (setsid) : sans ca on empile un
    # relais de plus a chaque relance, et le son se dedouble.
    pkill -f 'paplay --server=tcp:' 2>/dev/null || true
}

tout_arreter

# ── LES OUTILS D EXPLOITATION SONT-ILS DEMANDES ? ───────────────────────────
# [2026-08-31] OSMO_LAUNCH_APPS=0 : ni wireshark, ni linphone. C est ce que
# demande start-multi.sh quand il declenche ce lanceur pour remonter le natif -
# il veut la PILE, pas une seconde instance des outils.
#
# ⚠️ FIREFOX N EST PAS CONCERNE, et c est deliberé : le navigateur porte le
# dashboard du natif et le tutoriel, et start-multi.sh y AJOUTE les onglets des
# dashboards conteneurs. Le couper ici priverait un clic sur l antenne bleue de
# la base sur laquelle ces onglets viennent se greffer - on n aurait plus que
# les deux consoles conteneurs, sans celle du natif ni le tutoriel.
# Firefox, lui, sait ne pas se dedoubler : une seconde invocation ajoute des
# onglets a la fenetre existante.
# Par defaut a 1 : le double-clic sur le telephone rouge ne change pas.
OSMO_LAUNCH_APPS="${OSMO_LAUNCH_APPS:-1}"
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}i${NC} mode banc seul : wireshark et linphone non lances (firefox garde ses onglets)"
fi

# ── 1. WIRESHARK sur udp/4729 ───────────────────────────────────────────────
# En ROOT, et pas sous $GUI_USER : la capture sur `any` demande CAP_NET_RAW.
# -k demarre la capture tout de suite (sinon on ouvre sur un ecran de choix
# d interface, et rien n est capture tant qu on n a pas clique).
# [2026-08-31] LES DEUX RAISONS DE NE PAS LANCER SONT DISTINGUEES.
# Le test cumulait "demande ?" et "installe ?" dans un seul if, et le else
# annoncait toujours "absent". En mode banc seul (OSMO_LAUNCH_APPS=0, pose par
# start-multi.sh), on lisait donc "wireshark absent" pour un wireshark
# parfaitement installe - un message qui envoie verifier un paquet present.
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}○${NC} wireshark : non demande (mode banc seul)"
elif command -v wireshark >/dev/null 2>&1; then
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
if [ "$OSMO_LAUNCH_APPS" != "1" ]; then
    echo -e "  ${CYAN}○${NC} linphone : non demande (mode banc seul)"
elif command -v linphone >/dev/null 2>&1; then
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
                # Deux URL sur la meme ligne de commande = deux ONGLETS, dans
                # la meme fenetre. Un second `firefox <url>` marcherait aussi
                # (le premier processus recupere l argument), mais il faudrait
                # le cadencer : lance trop tot, il fait la course avec le
                # demarrage du navigateur et ouvre parfois une 2e fenetre.
                gui_run firefox "$DASH_URL" "$TUTO_URL"
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

# ── AUCUNE SAISIE ───────────────────────────────────────────────────────────
# [2026-08-31] start-direct.sh ouvre menu_interactif() : Profil, Noeud SS7,
# Operateur, Inter-STP - quatre questions whiptail avant que quoi que ce soit
# ne demarre. Il les saute quand PERSONNE ne peut repondre, et il teste ca sur
# la presence d un terminal ([ -t 0 ]) - or launch.sh vient justement d en
# ouvrir un pour afficher la sortie. La garde ne se declenchait donc jamais
# ici, et un double-clic sur le telephone rouge s arretait sur un formulaire
# au lieu de lancer le banc.
#
# NO_MENU=1 est le drapeau prevu pour ca (start-direct.sh l.460 et l.1263) :
# les menus rendent la main sans rien demander et les valeurs par defaut
# s appliquent - noeud 1, operateur 1, hub local. C est exactement ce que
# start.sh pose deja devant ses conteneurs.
#
# OSMO_LAUNCH_MENU=1 ./launch.sh redonne les questions quand on les veut.
if [ "${OSMO_LAUNCH_MENU:-0}" = "1" ]; then
    "$TARGET" "$@"
else
    NO_MENU=1 "$TARGET" "$@"
fi
rc=$?

echo
if [ "$rc" -eq 0 ]; then
    echo -e "${GREEN}=== start-direct.sh termine (code 0) ===${NC}"
else
    echo -e "${RED}=== start-direct.sh a ECHOUE (code $rc) ===${NC}"
fi
# Uniquement dans une fenetre ouverte par nos soins : au terminal, rendre la
# main tout de suite est le comportement attendu.
if [ "$_own_window" = "1" ]; then
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
