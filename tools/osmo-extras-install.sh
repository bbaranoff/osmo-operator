#!/bin/bash
# =============================================================================
# osmo-extras-install.sh - GAMES + MEDIA, installed once for TWO paths.
#
# Same logic as the rest of the repo: what must exist both in the SUPPLEMENT
# (addition.sh, on an already installed machine) and in the NATIVE image (the
# ISO, iso_modules/80-chroot.sh) is written ONCE here, and both paths source
# this script and call osmo_extras_install. Nothing is fatal: a package
# missing from the apt mirror must not stop the rest.
#
# What it installs:
#   - [addition.sh only, not the ISO: OSMO_EXTRAS_JEUX=0 skips them, ~470 MB]
#     two FREE games, data included, available on Ubuntu noble:
#       Doom  : freedoom (free WADs) + chocolate-doom (the engine the
#               freedoom2 launcher knows how to find; dsda-doom is not
#               recognised);
#       Quake : openarena (ioquake3 engine, Quake III, ~410 MB of data).
#     Not installed: gzdoom and openra (absent from noble), quakespasm
#     (stops at startup without the proprietary pak0.pak), Unreal (no free
#     version);
#   - kodi (mediacenter);
#   - wmctrl: the panel (osmo-panel.py) needs it to DOCK the launched window
#     onto the FFT frame;
#   - the playable DINO (osmo-dino-play, fullscreen or docked) from the same
#     configs/conky/dino.html as the desktop animation;
#   - YOUTUBE in a real Firefox (Google login possible) with uBlock Origin
#     forced by enterprise POLICY (policies.json) - not a third-party client,
#     so the Google login is kept;
#   - the missing .desktop files (youtube, dino) and two GNOME application
#     FOLDERS: « Jeux » and « Media ».
#
# Idempotent: can be rerun without damage. Usable in a session (gsettings
# available) AND in the ISO chroot (no session: the gschema override is used
# instead, read by the live session at boot).
# =============================================================================

# These colours may already exist (addition.sh defines them): no complaint.
: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${BOLD:=}"; : "${NC:=}"

# The repo, to find dino.html. addition.sh sets DIR; the ISO sets REPO or
# nothing (the repo is copied into the image at a fixed path).
OSMO_EXTRAS_REPO="${DIR:-${REPO:-/opt/GSM/osmo-operator}}"

_ex_say()  { echo -e "  ${CYAN}\xe2\x86\x92${NC} $*"; }
_ex_ok()   { echo -e "      ${GREEN}\xe2\x9c\x93${NC} $*"; }
_ex_warn() { echo -e "      ${YELLOW}!${NC} $*"; }

# ── THE PACKAGES ─────────────────────────────────────────────────────────────
# Non-fatal package by package: on a mirror where one is missing (universe
# not enabled, version), the others still go through.
_osmo_extras_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    # wireshark asks through debconf whether to allow capture without root:
    # answer NO (the panel launches it as root anyway, see osmo-wireshark-root)
    # so the install goes through without a question.
    echo "wireshark-common wireshark-common/install-setuid boolean false" \
        | debconf-set-selections 2>/dev/null || true
    local p
    for p in wmctrl xdotool \
             qemu-system-x86 qemu-system-gui qemu-system-modules-opengl ovmf sshpass kpartx \
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
    # linphone: the package name depends on the version (linphone-desktop
    # recent, linphone older). Take the first one that installs.
    if dpkg -s linphone-desktop >/dev/null 2>&1 || dpkg -s linphone >/dev/null 2>&1; then
        _ex_ok "linphone deja present"
    elif apt-get install -y --no-install-recommends linphone-desktop >/dev/null 2>&1 \
      || apt-get install -y --no-install-recommends linphone >/dev/null 2>&1; then
        _ex_ok "linphone installe"
    else
        _ex_warn "linphone indisponible (apt) - ignore"
    fi
    # ofono: telephony stack (daemon + test tools)
    if dpkg -s ofono >/dev/null 2>&1; then
        _ex_ok "ofono deja present"
    elif apt-get install -y --no-install-recommends ofono >/dev/null 2>&1; then
        _ex_ok "ofono installe"
    else
        _ex_warn "ofono indisponible (apt) - ignore"
    fi
}

# ── THE GAMES: SUPPLEMENT ONLY ───────────────────────────────────────────────
# Kept out of the ISO: ~470 MB for two games. addition.sh --extras installs
# them (OSMO_EXTRAS_JEUX=1, the default); iso_modules/80-chroot.sh passes 0.
_osmo_extras_jeux() {
    export DEBIAN_FRONTEND=noninteractive
    local p
    for p in freedoom chocolate-doom openarena; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            _ex_ok "$p deja present"
        elif apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
            _ex_ok "$p installe"
        else
            _ex_warn "$p indisponible (apt) - ignore"
        fi
    done
}

# ── YOUTUBE: uBLOCK ORIGIN FORCED BY FIREFOX POLICY ──────────────────────────
# NOT a third-party client (it would lose the Google login): the real Firefox,
# with uBlock Origin installed by default for ALL profiles through the
# enterprise policy. `install_url` points at the AMO-signed XPI;
# `installation_mode force_installed` imposes it without a click. The Google
# login stays Firefox's own.
#
# The Mozilla .deb Firefox reads /etc/firefox/policies/policies.json AND
# <install>/distribution/policies.json - both are written so as not to depend
# on the install path.
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
        # /etc/firefox: always; the <install>/distribution ones: only if the
        # parent directory (hence Firefox) exists.
        case "$d" in
            /etc/firefox/policies) mkdir -p "$d" ;;
            *) [ -d "$(dirname "$d")" ] || continue; mkdir -p "$d" ;;
        esac
        printf '%s\n' "$pol" > "$d/policies.json"
    done
    _ex_ok "uBlock Origin force par politique Firefox (login Google conserve)"
}

# ── THE /usr/local/bin LAUNCHERS ─────────────────────────────────────────────
# Each launcher accepts --fullscreen. Without it: normal window (the panel
# docks it onto the frame via wmctrl). With it: straight to fullscreen.
_osmo_extras_lanceurs() {
    # YOUTUBE: Firefox, dedicated profile, on youtube.com. Google login OK,
    # uBlock already forced by the policy above.
    cat > /usr/local/bin/osmo-youtube <<'YT'
#!/bin/bash
# osmo-youtube - Firefox (Google login possible) + uBlock Origin (policy),
# on YouTube. --fullscreen => fullscreen kiosk.
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

    # Playable DINO: the same dino.html, but in an interactive WebKit window
    # (not the "attract" animation of osmo-dino.py). --fullscreen => fullscreen.
    cat > /usr/local/bin/osmo-dino-play <<'DINO'
#!/usr/bin/env python3
# osmo-dino-play - the dino game (configs/conky/dino.html), playable.
# Without argument: 900x560 window. With --fullscreen: fullscreen.
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
        # The page's fullscreen button talks to us through a WebKit message
        # ({full:true|false}): WE enlarge or restore the window - a page
        # cannot do it on its own.
        ucm = WebKit2.UserContentManager()
        ucm.connect("script-message-received::osmo", self.on_message)
        ucm.register_script_message_handler("osmo")
        self.view = WebKit2.WebView.new_with_user_content_manager(ucm)
        self.add(self.view)
        if os.path.exists(HTML):
            # #full: the page starts fullscreen (its button brings it back
            # into the window). Without --fullscreen it stays in the window.
            self.view.load_uri(GLib.filename_to_uri(HTML, None) + ("#full" if full else ""))
        else:
            self.view.load_html("<h2 style='font-family:sans-serif'>dino.html introuvable</h2>", None)
        self.show_all()
        if full:
            self.fullscreen()
    def on_message(self, _ucm, result):
        try:
            on = result.get_js_value().to_string().find("true") >= 0 \
                 if not hasattr(result.get_js_value(), "object_get_property") \
                 else result.get_js_value().object_get_property("full").to_boolean()
        except Exception:
            on = True
        (self.fullscreen if on else self.unfullscreen)()
W(); Gtk.main()
DINO
    chmod 755 /usr/local/bin/osmo-dino-play

    # WIRESHARK AS ROOT: capture needs privileges (the install set setuid to
    # false). The launcher is a repo file, tools/osmo-wireshark-root.sh: root
    # via pkexec (graphical prompt), immediate capture with the bench
    # LTE + SCTP + GSM filter, 2G + 4G + phone (call, SMS, data) display
    # filter and filter buttons. /usr/local/bin/wireshark points at it:
    # « wireshark » at the keyboard is this one (the binary stays
    # /usr/bin/wireshark, which it calls).
    [ -f "$OSMO_EXTRAS_REPO/tools/osmo-wireshark-root.sh" ] \
        && install -m 755 "$OSMO_EXTRAS_REPO/tools/osmo-wireshark-root.sh" /usr/local/bin/osmo-wireshark-root
    ln -sfn /usr/local/bin/osmo-wireshark-root /usr/local/bin/wireshark

    # OFONO: telephony stack. No native GUI; open a terminal that makes sure
    # the daemon runs (root) and lists the modems.
    cat > /usr/local/bin/osmo-ofono <<'OF'
#!/bin/bash
# osmo-ofono - starts ofonod if needed and lists the modems (terminal).
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

    # THE BENCH PHONE: the postmarketOS / Phosh VM. postmarketOS comes with
    # ModemManager, Calls and Chatty, and plugs onto the REAL bench modem
    # (tools/osmo-phonesim-banc.py). tools/osmo-pmos.sh does the rest.
    cat > /usr/local/bin/osmo-pmos <<'PM'
#!/bin/bash
# osmo-pmos - the bench postmarketOS phone (see tools/osmo-pmos.sh).
exec "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-pmos.sh" "$@"
PM
    chmod 755 /usr/local/bin/osmo-pmos

    cat > /usr/local/bin/osmo-sms-send <<'SM'
#!/bin/bash
# osmo-sms-send <number> <text...> - sends an SMS through oFono via the bridge.
set -u
[ $# -ge 2 ] || { echo "usage: osmo-sms-send <numero> <texte...>"; exit 2; }
NUM="$1"; shift
# /usr/bin/python3 hard-coded: under the bench PATH, « env python3 » lands on
# the venv, which has no GObject bindings (see start-native.sh).
exec /usr/bin/python3 "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-ofono-bridge.py" --once "sms $NUM $*"
SM
    chmod 755 /usr/local/bin/osmo-sms-send

    cat > /usr/local/bin/osmo-call <<'CA'
#!/bin/bash
# osmo-call <number> | answer | hangup - calls through oFono via the bridge.
set -u
B="${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-ofono-bridge.py"
P=/usr/bin/python3        # not the venv: it has no GObject bindings
case "${1:-}" in
    answer) exec "$P" "$B" --once "answer" ;;
    hangup) exec "$P" "$B" --once "hangup" ;;
    "")     echo "usage: osmo-call <numero> | answer | hangup"; exit 2 ;;
    *)      exec "$P" "$B" --once "call $1" ;;
esac
CA
    chmod 755 /usr/local/bin/osmo-call

    _ex_ok "lanceurs poses : osmo-youtube, osmo-dino-play, osmo-wireshark-root, osmo-ofono,"
    _ex_ok "                osmo-pmos, osmo-sms-send, osmo-call"
}

# ── THE MISSING .desktop FILES + THE « Jeux » / « Media » FOLDERS ────────────
# The games and kodi ALREADY ship their .desktop (io.github.freedoom.Phase1/2,
# openarena.desktop, kodi.desktop). Only the missing ones are added (youtube,
# dino-jeu), then everything is SORTED into GNOME folders.
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
Name=Wireshark (banc)
GenericName=Analyseur reseau
Comment=Wireshark en root, capture immediate du banc, filtre 2G + 4G + telephone (signalisation, appel, SMS, data) sans les battements de coeur ; boutons Banc / 2G / 4G / Appel / SMS / Data / Attach
Exec=/usr/local/bin/osmo-wireshark-root %f
Icon=org.wireshark.Wireshark
Terminal=false
StartupNotify=true
Categories=Network;Monitor;
Keywords=wireshark;capture;pcap;reseau;lte;sctp;gsm;gsmtap;2g;4g;sms;appel;
WSD

    cat > /usr/share/applications/osmo-ofono.desktop <<'OFD'
[Desktop Entry]
Type=Application
Name=oFono
Comment=Pile telephonie oFono - demarre le daemon et liste les modems
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "oFono" -- /usr/local/bin/osmo-ofono
Icon=phone
Terminal=false
Categories=Network;Telephony;
Keywords=ofono;telephonie;modem;
OFD

    cat > /usr/share/applications/osmo-pmos.desktop <<'PMD'
[Desktop Entry]
Type=Application
Name=Telephone (postmarketOS)
Comment=Le telephone du banc - Phosh, ModemManager, appels et SMS reels
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --root --title "Telephone (postmarketOS)" -- /usr/local/bin/osmo-pmos up
Icon=phone
Terminal=false
Categories=Network;Telephony;
Keywords=postmarketos;phosh;telephone;sms;appel;modem;
Actions=Etat;Arreter;

[Desktop Action Etat]
Name=Etat du telephone
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --keep-open --title "Etat du telephone" -- /usr/local/bin/osmo-pmos status

[Desktop Action Arreter]
Name=Arreter le telephone
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --close-on-exit --title "Arret du telephone" -- /usr/local/bin/osmo-pmos stop
PMD

    # The two pmbootstrap launchers (see update.sh, osmo_poser_pmos): the VM
    # and its format, then the modem and the voice.
    local ps
    for ps in qemu setup; do
        [ -f "$OSMO_EXTRAS_REPO/tools/osmo-pmos-$ps.sh" ] \
            && install -m 755 "$OSMO_EXTRAS_REPO/tools/osmo-pmos-$ps.sh" "/usr/local/bin/osmo-pmos-$ps"
    done
    # TWO FORMATS, TWO ICONS. Phosh lays itself out after the screen it is
    # given: tall and narrow is a phone; wide is a tablet - same image, same
    # session. The QEMU graphics card carries that size (OSMO_PMOS_RES, read
    # by the pmbootstrap patch) and the system boots inside it: the format
    # is chosen AT LAUNCH and does not change under an open session. Hence
    # two entries rather than a setting.
    local pf pn pr
    for pf in smartphone:720x1440 tablette:1280x800; do
        pn="${pf%%:*}"; pr="${pf#*:}"
        cat > "/usr/share/applications/osmo-pmos-$pn.desktop" <<PMD
[Desktop Entry]
Type=Application
Name=postmarketOS - $pn (banc)
Comment=Le telephone du banc, modem et voix branches tout seuls, en format $pn ($pr) - modem branche sur le banc GSM
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$pr /usr/local/bin/osmo-pmos-qemu
Icon=$([ "$pn" = tablette ] && echo video-display || echo phone)
Terminal=false
Categories=Network;Telephony;System;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;$pn;
Actions=Setup;SansModem;

[Desktop Action Setup]
Name=Rebrancher le modem et la voix (osmo-pmos-setup)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --title "Modem et voix du telephone" -- /usr/local/bin/osmo-pmos-setup

[Desktop Action SansModem]
Name=Demarrer sans modem (VM nue)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$pr OSMO_PMOS_MODEM=0 /usr/local/bin/osmo-pmos-qemu
PMD
        chmod 644 "/usr/share/applications/osmo-pmos-$pn.desktop"
    done

    chmod 644 /usr/share/applications/osmo-youtube.desktop \
              /usr/share/applications/osmo-dino-jeu.desktop \
              /usr/share/applications/osmo-wireshark-root.desktop \
              /usr/share/applications/osmo-ofono.desktop \
              /usr/share/applications/osmo-pmos.desktop

    # ── GNOME APPLICATION FOLDERS: « Jeux » and « Media » ─────────────────────
    # A gschema override is read both by the live session (ISO) and by an
    # installed session; it is the only way that ALSO works in a chroot (no
    # dbus). The expected .desktop files are listed - a missing one is ignored
    # by GNOME, as for the dock favourites.
    local ov=/usr/share/glib-2.0/schemas/99-osmo-extras.gschema.override
    cat > "$ov" <<'OVR'
[org.gnome.desktop.app-folders]
folder-children=['Jeux', 'Media', 'Telephone', 'Outils']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Jeux/]
name='Jeux'
apps=['io.github.freedoom.Phase2.desktop', 'io.github.freedoom.Phase1.desktop', 'openarena.desktop', 'osmo-dino-jeu.desktop']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Media/]
name='Media'
apps=['kodi.desktop', 'osmo-youtube.desktop']

[org.gnome.desktop.app-folders.folders:/org/gnome/desktop/app-folders/folders/Telephone/]
name='Telephone'
apps=['linphone.desktop', 'org.linphone.desktop', 'osmo-ofono.desktop', 'osmo-pmos.desktop']

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

# ── ENTRY POINT ───────────────────────────────────────────────────────────────
osmo_extras_install() {
    [ "$(id -u)" -eq 0 ] || { _ex_warn "osmo_extras_install demande root"; return 0; }
    if [ "${OSMO_EXTRAS_JEUX:-1}" = "1" ]; then
        _ex_say "jeux + media (Doom, Quake III, Kodi, YouTube, dino) ..."
    else
        _ex_say "media (Kodi, YouTube, dino) - jeux Doom/Quake sautes (OSMO_EXTRAS_JEUX=0) ..."
    fi
    _osmo_extras_apt
    [ "${OSMO_EXTRAS_JEUX:-1}" = "1" ] && _osmo_extras_jeux
    _osmo_extras_firefox_ublock
    _osmo_extras_lanceurs
    _osmo_extras_desktops
    echo -e "  ${GREEN}\xe2\x9c\x93${NC} jeux + media poses (dossiers ${BOLD}Jeux${NC} / ${BOLD}Media${NC}, et dans l encart du bureau)"
    return 0
}

# Run directly (not sourced): ./osmo-extras-install.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    osmo_extras_install
fi
