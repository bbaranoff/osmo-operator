# =============================================================================
#  80-bureau - desktop icons and shortcuts (native install)
# =============================================================================
#  Installs the same files the ISO installs (build-iso.sh), from the same
#  repository files:
#     data/desktop/osmo-launch.desktop   "Lancer le banc GSM"  -> launch.sh
#     data/desktop/osmo-dino.desktop     the Dino game
#     data/*.svg                         the icons
#  plus: /usr/local/bin/osmo-start-native and osmo-start-direct -> start-native.sh,
#  c123 / osmo-c123 -> tools/osmo-c123-gtk.py, osmo-wg -> tools/osmo-wg.sh,
#  the bench commands (tools/osmo-banc-cmd.sh), the profile.d snippets (gnuarm
#  PATH, bench aliases, WireGuard), the gcc-9/gcc-11 alternatives and the
#  GNOME default background (gschema override).
#
#  osmo-multi (antenna, multi-operator) is NOT installed here: its launcher
#  launch/start-multi.sh needs the SS7 supplement (docker + image + topology),
#  which only exists after addition.sh; addition.sh installs that icon itself
#  at the end of a successful SS7 install.
#
#  Icon= is rewritten as an ABSOLUTE PATH (/usr/share/osmo-operator/icons/*.svg):
#  a theme name goes through icon-theme.cache, which does not know an icon
#  added after it, and GNOME then silently shows a blank page. The cache is
#  still rebuilt for the applications menu.
#
#  Shortcuts are copied to the desktop of root and of the user who ran sudo
#  (SUDO_USER), in Bureau/ and Desktop/. The metadata::trusted attribute
#  cannot be set here (it lives in the session's gvfs metadata): update.sh
#  sets it at login; otherwise double-click + "Allow" is enough.
#
#  The background is a schema DEFAULT (99-osmo-fond.gschema.override), not a
#  user setting: a user who chose another background keeps it.
#
#  Neither osmo-tutorial, osmo-addition nor osmo-update: their launchers are
#  wrappers written by build-iso.sh for the image (terminal + pkexec) and
#  depend on the ISO's GNOME desktop. On an installed machine, launch.sh and
#  launch/start-multi.sh are enough.
# -----------------------------------------------------------------------------
INST_REGISTER bureau "Bureau : icones et raccourcis"
INST_DEPS[bureau]="configs"
INST_REQUIRED[bureau]=0

_BUREAU_ICONS=/usr/share/osmo-operator/icons
_BUREAU_ENTRIES="osmo-launch osmo-dino"
# The idle background is the city WITHOUT antenna (gsm-lab-ville.jpg);
# gsm-lab-antenne.jpg (same city, mast raised) is faded in by tools/osmo-fond.py
# while a 2G/4G network runs. Both are copied, plus the low-poly landscape
# (gsm-lab-fond.jpg), which is not the default.
_BUREAU_FOND=/usr/share/backgrounds/gsm-lab-ville.jpg
_BUREAU_FONDS="gsm-lab-antenne.jpg gsm-lab-fond.jpg"
_BUREAU_SCHEMA=/usr/share/glib-2.0/schemas/99-osmo-fond.gschema.override

# Default background: same file and same three sections as the ISO
# (org.gnome.desktop.background, :ubuntu, :GNOME-Greeter - an ubuntu:GNOME
# session reads the latter). Without glib-compile-schemas (no GNOME here),
# the file is installed and nothing more.
_bureau_fond() {
    local src="$INST_TREE/configs/gsm-lab-ville.jpg" sec f
    for f in $_BUREAU_FONDS; do
        [ -f "$INST_TREE/configs/$f" ] && install -Dm644 "$INST_TREE/configs/$f" "/usr/share/backgrounds/$f"
    done
    ln -sf "$INST_TREE/tools/osmo-fond.py" /usr/local/bin/osmo-fond
    [ -f "$src" ] || { inst_hint "configs/gsm-lab-ville.jpg absent : fond GNOME inchange"; return 0; }
    install -Dm644 "$src" "$_BUREAU_FOND" || { inst_hint "fond non pose : $_BUREAU_FOND"; return 0; }
    [ -d /usr/share/glib-2.0/schemas ] || { inst_say "fond : $_BUREAU_FOND (pas de schemas GNOME ici)"; return 0; }
    : > "$_BUREAU_SCHEMA"
    for sec in "org.gnome.desktop.background" "org.gnome.desktop.background:ubuntu" "org.gnome.desktop.background:GNOME-Greeter"; do
        printf "\n[%s]\npicture-uri='file://%s'\npicture-uri-dark='file://%s'\npicture-options='zoom'\nprimary-color='#0d1b2a'\n" \
            "$sec" "$_BUREAU_FOND" "$_BUREAU_FOND" >> "$_BUREAU_SCHEMA"
    done
    # Light mode by default, as on the ISO (iso_modules/80-chroot.sh):
    # Yaru-blue, color-scheme default. A 99-osmo-live override left by the ISO
    # on a machine installed from it is switched back to light as well.
    for sec in "org.gnome.desktop.interface" "org.gnome.desktop.interface:ubuntu" "org.gnome.desktop.interface:GNOME-Greeter"; do
        printf "\n[%s]\ncolor-scheme='default'\ngtk-theme='Yaru-blue'\nicon-theme='Yaru-blue'\ncursor-theme='Yaru'\n" \
            "$sec" >> "$_BUREAU_SCHEMA"
    done
    [ -f /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override ] \
        && sed -i -e "s/^color-scheme='prefer-dark'/color-scheme='default'/" -e "s/^gtk-theme='Yaru-blue-dark'/gtk-theme='Yaru-blue'/" \
            /usr/share/glib-2.0/schemas/99-osmo-live.gschema.override
    if command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null \
            && inst_say "fond GNOME par defaut : $_BUREAU_FOND" \
            || inst_hint "glib-compile-schemas a echoue : fond pose, defaut non compile"
    else
        inst_say "fond : $_BUREAU_FOND (glib-compile-schemas absent, defaut non compile)"
    fi
}

_bureau_homes() {
    local h
    printf '%s\n' /root
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        [ -n "$h" ] && [ -d "$h" ] && printf '%s\n' "$h"
    fi
}

inst_bureau_check() {
    [ -d "$INST_TREE/data/desktop" ] || { inst_fail "data/desktop/ absent du depot"; return $INST_RC_FAIL; }
    [ -x "$INST_TREE/launch.sh" ] || inst_hint "launch.sh n est pas executable : chmod +x $INST_TREE/launch.sh"
    inst_ok
}

inst_bureau_done() {
    local e
    for e in $_BUREAU_ENTRIES; do
        have_file "/usr/share/applications/$e.desktop" || return 1
        have_file "$_BUREAU_ICONS/$e.svg" || return 1
    done
    [ -L /usr/local/bin/osmo-start-direct ] || return 1
    [ -L /usr/local/bin/c123 ] || return 1
    [ -L /usr/local/bin/banc-rssi ] || return 1
    return 0
}

inst_bureau_run() {
    local e h d f
    install -d "$_BUREAU_ICONS" /usr/share/icons/hicolor/scalable/apps /usr/share/applications \
        || { inst_fail "impossible de creer les repertoires du bureau"; return $INST_RC_FAIL; }
    for e in $_BUREAU_ENTRIES; do
        [ -f "$INST_TREE/data/$e.svg" ] && {
            install -m644 "$INST_TREE/data/$e.svg" "$_BUREAU_ICONS/$e.svg"
            install -m644 "$INST_TREE/data/$e.svg" "/usr/share/icons/hicolor/scalable/apps/$e.svg"
        }
        install -m644 "$INST_TREE/data/desktop/$e.desktop" "/usr/share/applications/$e.desktop" \
            || { inst_fail "copie impossible : $e.desktop"; return $INST_RC_FAIL; }
        # Exec= and Icon= follow the INSTALLED tree, not a hard-coded /opt/GSM:
        # this repository may live elsewhere (GSM_ROOT).
        sed -i -e "s|^Exec=/opt/GSM/osmo-operator/|Exec=$INST_TREE/|" \
               -e "s|^Icon=.*|Icon=$_BUREAU_ICONS/$e.svg|" "/usr/share/applications/$e.desktop"
        inst_say "menu : /usr/share/applications/$e.desktop"
    done
    # osmo-start-native is the launcher name; osmo-start-direct is kept as an
    # alias for existing habits and scripts.
    ln -sf "$INST_TREE/start-native.sh" /usr/local/bin/osmo-start-native
    ln -sf "$INST_TREE/start-native.sh" /usr/local/bin/osmo-start-direct
    # c123: the emulated C123 window (tools/osmo-c123-gtk.py) in the PATH, not
    # only as a login-shell alias. It runs under the SYSTEM python3: PyGObject
    # + GTK3 + cairo (python3-gi-cairo for Gdk.cairo_set_source_pixbuf) come
    # from apt, not from pip.
    ln -sf "$INST_TREE/tools/osmo-c123-gtk.py" /usr/local/bin/c123
    ln -sf "$INST_TREE/tools/osmo-c123-gtk.py" /usr/local/bin/osmo-c123
    # banc-rssi, banc-trx, c123-1...: profile.d aliases AND real commands (tools/osmo-banc-cmd.sh)
    install -m644 "$INST_TREE/scripts/osmo-banc-aliases.sh" /etc/profile.d/98-osmo-banc-aliases.sh
    OSMO_BANC_TREE="$INST_TREE" bash "$INST_TREE/tools/osmo-banc-cmd.sh" --install /usr/local/bin >/dev/null
    install -m644 "$INST_TREE/scripts/osmo-gnuarm-profile.sh" /etc/profile.d/97-osmo-gnuarm.sh   # gnuarm in the PATH, if installed
    # gcc-9 and gcc-11 next to gcc-13, with their alternatives, as on the ISO
    # (iso_modules/80-chroot.sh): jolly/testing and burst_ind of osmocom-bb need gcc-9.
    apt-get install -y --no-install-recommends gcc-9 g++-9 gcc-11 g++-11 >/dev/null \
        || inst_hint "gcc-9 / gcc-11 non installes : alternatives limitees aux compilateurs presents"
    bash "$INST_TREE/tools/osmo-gcc-alternatives.sh"
    # WireGuard for the WAN: "wg 1" / "wg N ..." (tools/osmo-wg.sh), as on the ISO
    install -m644 "$INST_TREE/scripts/osmo-wg-profile.sh" /etc/profile.d/97-osmo-wg.sh
    ln -sf "$INST_TREE/tools/osmo-wg.sh" /usr/local/bin/osmo-wg
    command -v wg-quick >/dev/null 2>&1 \
        || apt-get install -y --no-install-recommends wireguard-tools >/dev/null \
        || inst_hint "wireguard-tools non installe : « wg N » ne montera pas de tunnel"
    /usr/bin/python3 -c 'import gi, cairo; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
        || apt-get install -y --no-install-recommends python3-gi python3-gi-cairo python3-cairo \
               gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 >/dev/null \
        || inst_hint "c123 : paquets GTK non installes (python3-gi python3-gi-cairo gir1.2-gtk-3.0)"

    while read -r h; do
        for d in Bureau Desktop; do
            [ -d "$h/$d" ] || continue
            for e in $_BUREAU_ENTRIES; do
                f="$h/$d/$e.desktop"
                cp -f "/usr/share/applications/$e.desktop" "$f" && chmod +x "$f"
                inst_say "bureau : $f"
            done
            [ "$h" != /root ] && chown "$SUDO_USER" "$h/$d"/osmo-*.desktop 2>/dev/null
        done
    done < <(_bureau_homes)

    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null
    _bureau_fond
    inst_ok
}

inst_bureau_verify() {
    local e
    for e in $_BUREAU_ENTRIES; do
        grep -q "^Exec=$INST_TREE/" "/usr/share/applications/$e.desktop" \
            || { inst_fail "$e.desktop ne pointe pas sur $INST_TREE"; return $INST_RC_FAIL; }
    done
    inst_ok
}
