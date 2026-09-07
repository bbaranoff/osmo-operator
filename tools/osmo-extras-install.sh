#!/bin/bash
# =============================================================================
# osmo-extras-install.sh - JEUX + MEDIA, poses une seule fois pour DEUX chemins.
#
# Meme logique que le reste du depot : ce qui doit exister a la fois dans le
# SUPPLEMENT (addition.sh, sur une machine deja installee) et dans le NATIF
# (l ISO, iso_modules/80-chroot.sh) est ecrit UNE fois ici, et les deux chemins
# sourcent ce script et appellent osmo_extras_install. Rien n est fatal : un
# paquet absent du miroir apt ne doit pas arreter le reste.
#
# Ce qu il pose :
#   - les MOTEURS LIBRES de jeu : gzdoom + freedoom (Doom), quakespasm (Quake),
#     openra (a la place d Unreal : pas d Unreal libre, OpenRA est le plus
#     proche jouable sans donnees proprietaires) ;
#   - kodi (mediacenter) ;
#   - wmctrl : l encart (osmo-panel.py) en a besoin pour CALER la fenetre lancee
#     sur le cadre FFT ;
#   - le DINO jouable (osmo-dino-play, plein ecran ou cale) a partir du meme
#     configs/conky/dino.html que l animation du bureau ;
#   - YOUTUBE dans un vrai Firefox (connexion Google possible) avec uBlock
#     Origin force par POLITIQUE d entreprise (policies.json) - pas un client
#     tiers, pour garder le login Google ;
#   - les .desktop qui manquent (youtube, dino) et deux DOSSIERS d applications
#     GNOME : « Jeux » et « Media ».
#
# Idempotent : relancable sans degat. Utilisable en session (gsettings dispo) ET
# en chroot ISO (pas de session : on passe alors par le gschema override, lu par
# la session live au boot).
# =============================================================================

# Ces couleurs peuvent deja exister (addition.sh les definit) : on ne rale pas.
: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${BOLD:=}"; : "${NC:=}"

# Le depot, pour retrouver dino.html. addition.sh pose DIR ; l ISO pose REPO ou
# rien (le depot est copie dans l image a un chemin fixe).
OSMO_EXTRAS_REPO="${DIR:-${REPO:-/opt/GSM/osmo-operator}}"

_ex_say()  { echo -e "  ${CYAN}\xe2\x86\x92${NC} $*"; }
_ex_ok()   { echo -e "      ${GREEN}\xe2\x9c\x93${NC} $*"; }
_ex_warn() { echo -e "      ${YELLOW}!${NC} $*"; }

# ── LES PAQUETS ──────────────────────────────────────────────────────────────
# Non fatal paquet par paquet : sur un miroir ou l un manque (universe pas
# active, version), les autres passent quand meme.
_osmo_extras_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    # wireshark demande en debconf s il faut autoriser la capture sans root : on
    # tranche NON (l encart le lance en root de toute facon, cf. osmo-wireshark-
    # root) pour que l install passe sans question.
    echo "wireshark-common wireshark-common/install-setuid boolean false" \
        | debconf-set-selections 2>/dev/null || true
    local p
    for p in wmctrl xdotool \
             gzdoom freedoom \
             quakespasm \
             openra \
             kodi \
             wireshark \
             gir1.2-webkit2-4.1; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            _ex_ok "$p deja present"
        elif apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
            _ex_ok "$p installe"
        else
            _ex_warn "$p indisponible (apt) - ignore"
        fi
    done
    # linphone : le paquet a change de nom selon la version (linphone-desktop
    # recent, linphone ancien). On prend le premier qui s installe.
    if dpkg -s linphone-desktop >/dev/null 2>&1 || dpkg -s linphone >/dev/null 2>&1; then
        _ex_ok "linphone deja present"
    elif apt-get install -y --no-install-recommends linphone-desktop >/dev/null 2>&1 \
      || apt-get install -y --no-install-recommends linphone >/dev/null 2>&1; then
        _ex_ok "linphone installe"
    else
        _ex_warn "linphone indisponible (apt) - ignore"
    fi
    # ofono : pile telephonie (daemon + outils de test)
    if dpkg -s ofono >/dev/null 2>&1; then
        _ex_ok "ofono deja present"
    elif apt-get install -y --no-install-recommends ofono >/dev/null 2>&1; then
        _ex_ok "ofono installe"
    else
        _ex_warn "ofono indisponible (apt) - ignore"
    fi
}

# ── YOUTUBE : uBLOCK ORIGIN FORCE PAR POLITIQUE FIREFOX ──────────────────────
# On ne veut PAS d un client tiers (il perdrait la connexion Google) : c est le
# vrai Firefox, avec uBlock Origin installe d office pour TOUS les profils via la
# politique d entreprise. `Install` pointe l XPI signe d AMO ; `installation_mode
# force_installed` l impose sans clic. Le login Google reste celui de Firefox.
#
# Firefox du .deb Mozilla lit /etc/firefox/policies/policies.json ET
# <install>/distribution/policies.json - on pose les deux pour ne pas dependre du
# chemin d installation.
_osmo_extras_firefox_ublock() {
    local pol
    read -r -d '' pol <<'POLICIES'
{
  "policies": {
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "force_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    },
    "DisableAppUpdate": false
  }
}
POLICIES
    local d
    for d in /etc/firefox/policies \
             /usr/lib/firefox/distribution \
             /opt/firefox/distribution \
             /usr/lib/firefox-esr/distribution; do
        # /etc/firefox : toujours ; les <install>/distribution : seulement si
        # le repertoire parent (donc Firefox) existe.
        case "$d" in
            /etc/firefox/policies) mkdir -p "$d" ;;
            *) [ -d "$(dirname "$d")" ] || continue; mkdir -p "$d" ;;
        esac
        printf '%s\n' "$pol" > "$d/policies.json"
    done
    _ex_ok "uBlock Origin force par politique Firefox (login Google conserve)"
}

# ── LES LANCEURS /usr/local/bin ──────────────────────────────────────────────
# Chaque lanceur accepte --fullscreen. Sans lui : fenetre normale (l encart la
# calera sur le cadre via wmctrl). Avec lui : plein ecran direct.
_osmo_extras_lanceurs() {
    # YOUTUBE : Firefox, profil dedie, sur youtube.com. Login Google OK, uBlock
    # deja force par la politique ci-dessus.
    cat > /usr/local/bin/osmo-youtube <<'YT'
#!/bin/bash
# osmo-youtube - Firefox (login Google possible) + uBlock Origin (politique),
# sur YouTube. --fullscreen => kiosque plein ecran.
set -u
URL="https://www.youtube.com"
PROFDIR="${HOME:-/root}/.mozilla/osmo-youtube"
mkdir -p "$PROFDIR"
FF="$(command -v firefox || command -v firefox-esr || true)"
[ -n "$FF" ] || { command -v zenity >/dev/null 2>&1 && \
    zenity --error --text="Firefox introuvable" 2>/dev/null; exit 1; }
if [ "${1:-}" = "--fullscreen" ]; then
    exec "$FF" --profile "$PROFDIR" --no-remote --kiosk "$URL"
else
    exec "$FF" --profile "$PROFDIR" --no-remote --new-window "$URL"
fi
YT
    chmod 755 /usr/local/bin/osmo-youtube

    # DINO jouable : le meme dino.html, mais en fenetre WebKit interactive (et
    # non l animation "attract" de osmo-dino.py). --fullscreen => plein ecran.
    cat > /usr/local/bin/osmo-dino-play <<'DINO'
#!/usr/bin/env python3
# osmo-dino-play - le jeu du dino (configs/conky/dino.html) jouable.
# Sans argument : fenetre 900x560. Avec --fullscreen : plein ecran.
import os, sys, gi
gi.require_version("Gtk", "3.0"); gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, GLib, WebKit2
REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
HTML = os.environ.get("OSMO_DINO_HTML", os.path.join(REPO, "configs/conky/dino.html"))
full = "--fullscreen" in sys.argv
class W(Gtk.Window):
    def __init__(self):
        super().__init__(title="Cavalier d'ombres")
        self.set_default_size(900, 560)
        self.connect("destroy", Gtk.main_quit)
        self.view = WebKit2.WebView()
        self.add(self.view)
        if os.path.exists(HTML):
            self.view.load_uri(GLib.filename_to_uri(HTML, None))
        else:
            self.view.load_html("<h2 style='font-family:sans-serif'>dino.html introuvable</h2>", None)
        self.show_all()
        if full:
            self.fullscreen()
W(); Gtk.main()
DINO
    chmod 755 /usr/local/bin/osmo-dino-play

    # WIRESHARK EN ROOT : la capture demande les privileges (l install a mis
    # setuid a false). pkexec garde l affichage ; sudo -E en repli.
    cat > /usr/local/bin/osmo-wireshark-root <<'WS'
#!/bin/bash
# osmo-wireshark-root - Wireshark lance en root (capture sur toutes les ifaces).
set -u
WSBIN="$(command -v wireshark || true)"
[ -n "$WSBIN" ] || { command -v zenity >/dev/null 2>&1 && \
    zenity --error --text="Wireshark introuvable" 2>/dev/null; exit 1; }
if [ "$(id -u)" -eq 0 ]; then
    exec "$WSBIN" "$@"
elif command -v pkexec >/dev/null 2>&1; then
    exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" "$WSBIN" "$@"
else
    exec sudo -E "$WSBIN" "$@"
fi
WS
    chmod 755 /usr/local/bin/osmo-wireshark-root

    # OFONO : pile telephonie. Pas d IHM native ; on ouvre un terminal qui
    # s assure que le daemon tourne (root) et liste les modems.
    cat > /usr/local/bin/osmo-ofono <<'OF'
#!/bin/bash
# osmo-ofono - demarre ofonod si besoin et liste les modems (terminal).
set -u
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -E"
$SUDO systemctl start ofono 2>/dev/null || $SUDO ofonod 2>/dev/null &
sleep 1
if [ -x /usr/share/ofono/scripts/list-modems ]; then
    /usr/share/ofono/scripts/list-modems
else
    command -v ofonoctl >/dev/null 2>&1 && ofonoctl list || \
        echo "ofono demarre (aucun outil de liste trouve)"
fi
echo; read -n1 -rsp 'ofono - une touche pour fermer...'
OF
    chmod 755 /usr/local/bin/osmo-ofono

    # LE RACCORD MOBILE : Android (Waydroid) branche sur la telephonie du banc.
    # tools/osmo-waydroid.sh fait le gros du travail (installation, session,
    # pont) ; ces trois lanceurs sont les gestes d une seance.
    cat > /usr/local/bin/osmo-waydroid <<'WD'
#!/bin/bash
# osmo-waydroid - le telephone Android du banc (voir tools/osmo-waydroid.sh).
exec "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-waydroid.sh" "${1:-up}"
WD
    chmod 755 /usr/local/bin/osmo-waydroid

    cat > /usr/local/bin/osmo-sms-send <<'SM'
#!/bin/bash
# osmo-sms-send <numero> <texte...> - envoie un SMS par oFono via le pont.
set -u
[ $# -ge 2 ] || { echo "usage: osmo-sms-send <numero> <texte...>"; exit 2; }
NUM="$1"; shift
exec "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-ofono-bridge.py" --once "sms $NUM $*"
SM
    chmod 755 /usr/local/bin/osmo-sms-send

    cat > /usr/local/bin/osmo-call <<'CA'
#!/bin/bash
# osmo-call <numero> | answer | hangup - les appels par oFono via le pont.
set -u
B="${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-ofono-bridge.py"
case "${1:-}" in
    answer) exec "$B" --once "answer" ;;
    hangup) exec "$B" --once "hangup" ;;
    "")     echo "usage: osmo-call <numero> | answer | hangup"; exit 2 ;;
    *)      exec "$B" --once "call $1" ;;
esac
CA
    chmod 755 /usr/local/bin/osmo-call

    _ex_ok "lanceurs poses : osmo-youtube, osmo-dino-play, osmo-wireshark-root, osmo-ofono,"
    _ex_ok "                osmo-waydroid, osmo-sms-send, osmo-call"
}

# ── LES .desktop QUI MANQUENT + LES DOSSIERS « Jeux » / « Media » ────────────
# Les moteurs de jeu et kodi posent DEJA leur .desktop (freedoom.desktop,
# org.quakespasm..., openra.desktop, kodi.desktop). On n ajoute que ceux qui
# manquent (youtube, dino-jeu), puis on RANGE tout dans deux dossiers GNOME.
_osmo_extras_desktops() {
    install -d /usr/share/applications

    cat > /usr/share/applications/osmo-youtube.desktop <<'YTD'
[Desktop Entry]
Type=Application
Name=YouTube
Comment=YouTube dans Firefox (login Google) avec uBlock Origin
Exec=/usr/local/bin/osmo-youtube
Icon=firefox
Terminal=false
Categories=AudioVideo;Video;Network;
Keywords=youtube;video;media;
YTD

    cat > /usr/share/applications/osmo-dino-jeu.desktop <<'DIND'
[Desktop Entry]
Type=Application
Name=Cavalier d'ombres
Comment=Le jeu du dino, jouable
Exec=/usr/local/bin/osmo-dino-play
Icon=applications-games
Terminal=false
Categories=Game;ArcadeGame;
Keywords=dino;jeu;game;
DIND

    cat > /usr/share/applications/osmo-wireshark-root.desktop <<'WSD'
[Desktop Entry]
Type=Application
Name=Wireshark (root)
Comment=Wireshark lance en root (capture toutes interfaces)
Exec=/usr/local/bin/osmo-wireshark-root
Icon=wireshark
Terminal=false
Categories=Network;Monitor;
Keywords=wireshark;capture;pcap;reseau;
WSD

    cat > /usr/share/applications/osmo-ofono.desktop <<'OFD'
[Desktop Entry]
Type=Application
Name=oFono
Comment=Pile telephonie oFono - demarre le daemon et liste les modems
Exec=/usr/local/bin/osmo-ofono
Icon=phone
Terminal=true
Categories=Network;Telephony;
Keywords=ofono;telephonie;modem;
OFD

    cat > /usr/share/applications/osmo-waydroid.desktop <<'WDD'
[Desktop Entry]
Type=Application
Name=Android (Waydroid)
Comment=Le telephone Android du banc - SMS et appels portes depuis oFono
Exec=/usr/local/bin/osmo-waydroid up
Icon=phone
Terminal=true
Categories=Network;Telephony;
Keywords=android;waydroid;sms;appel;telephone;
WDD

    chmod 644 /usr/share/applications/osmo-youtube.desktop \
              /usr/share/applications/osmo-dino-jeu.desktop \
              /usr/share/applications/osmo-wireshark-root.desktop \
              /usr/share/applications/osmo-ofono.desktop \
              /usr/share/applications/osmo-waydroid.desktop

    # ── DOSSIERS D APPLICATIONS GNOME : « Jeux » et « Media » ─────────────────
    # Un gschema override est lu a la fois par la session live (ISO) et par une
    # session installee ; c est le seul moyen qui marche AUSSI en chroot (pas de
    # dbus). On liste les .desktop attendus - un absent est ignore par GNOME,
    # comme pour les favoris du dock.
    local ov=/usr/share/glib-2.0/schemas/99-osmo-extras.gschema.override
    cat > "$ov" <<'OVR'
[org.gnome.desktop.app-folders]
folder-children=['Jeux', 'Media', 'Telephone', 'Outils']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Jeux/]
name='Jeux'
apps=['freedoom.desktop', 'org.zdoom.gzdoom.desktop', 'gzdoom.desktop', 'quakespasm.desktop', 'org.quakespasm.QuakeSpasm.desktop', 'openra.desktop', 'net.openra.OpenRA.desktop', 'osmo-dino-jeu.desktop']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Media/]
name='Media'
apps=['kodi.desktop', 'osmo-youtube.desktop']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Telephone/]
name='Telephone'
apps=['linphone.desktop', 'org.linphone.desktop', 'osmo-ofono.desktop', 'osmo-waydroid.desktop']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Outils/]
name='Outils'
apps=['osmo-wireshark-root.desktop', 'org.wireshark.Wireshark.desktop', 'wireshark.desktop']
OVR
    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true

    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    _ex_ok "menus poses ; dossiers d applications « Jeux » et « Media »"
}

# ── L ENTREE ──────────────────────────────────────────────────────────────────
osmo_extras_install() {
    [ "$(id -u)" -eq 0 ] || { _ex_warn "osmo_extras_install demande root"; return 0; }
    _ex_say "jeux + media (Doom, Quake, OpenRA, Kodi, YouTube, dino) ..."
    _osmo_extras_apt
    _osmo_extras_firefox_ublock
    _osmo_extras_lanceurs
    _osmo_extras_desktops
    echo -e "  ${GREEN}\xe2\x9c\x93${NC} jeux + media poses (dossiers ${BOLD}Jeux${NC} / ${BOLD}Media${NC}, et dans l encart du bureau)"
    return 0
}

# Lance directement (hors source) : ./osmo-extras-install.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    osmo_extras_install
fi
