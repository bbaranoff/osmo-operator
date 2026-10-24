# =============================================================================
#  80-bureau - icones et raccourcis du bureau (install native)
# =============================================================================
#  Pose EXACTEMENT ce que l ISO pose (build-iso.sh, etape 8d) a partir des
#  memes fichiers du depot :
#     data/desktop/osmo-launch.desktop   "Lancer le banc GSM"  -> launch.sh
#     data/*.svg                         les icones
#
#  osmo-multi (antenne, multi-operator) N EST PLUS POSEE ICI : son lanceur
#  start-multi.sh suppose le supplement SS7 (docker + image + topologie), qui
#  n existe qu apres addition.sh. C est addition.sh qui pose l antenne, a la fin
#  d une install SS7 reussie - pas avant, ou elle ne ferait rien au clic.
#  et le lien /usr/local/bin/osmo-start-direct -> start-native.sh.
#
#  Icon= est reecrit en CHEMIN ABSOLU (/usr/share/osmo-operator/icons/*.svg) :
#  un nom de theme passe par icon-theme.cache, qui ne connait pas une icone
#  arrivee apres lui, et GNOME affiche alors une page blanche sans rien dire
#  (voir update.sh, osmo_reposer_icones). Le cache est quand meme reconstruit
#  pour le menu des applications.
#
#  Les raccourcis sont copies sur le bureau de root et de l utilisateur qui a
#  lance sudo (SUDO_USER), en Bureau/ et Desktop/. L attribut metadata::trusted
#  ne peut pas etre pose ici (il vit dans les metadonnees gvfs de la session) :
#  update.sh le pose au login, et un double-clic + "Autoriser" suffit sinon.
#
#  [2026-10-12] LE FOND D ECRAN AUSSI. L ISO pose configs/gsm-lab-fond.jpg
#  comme fond GNOME par defaut (iso_modules/80-chroot.sh, override de schema) ;
#  l install native ne le faisait pas, et le bureau restait sur le numbat
#  d Ubuntu. On pose le meme fichier (/usr/share/backgrounds/gsm-lab-fond.jpg)
#  et le meme override (99-osmo-fond.gschema.override) : un DEFAUT de schema,
#  pas un reglage d utilisateur - qui a choisi un autre fond le garde.
#
#  Ni osmo-tutorial, ni osmo-addition, ni osmo-update : leurs lanceurs sont
#  des enrobages ecrits par build-iso.sh pour l image (terminal + pkexec) et
#  dependent du bureau GNOME de l ISO. Sur une machine deja installee, launch.sh
#  et start-multi.sh se suffisent.
# -----------------------------------------------------------------------------
INST_REGISTER bureau "Bureau : icones et raccourcis"
INST_DEPS[bureau]="configs"
INST_REQUIRED[bureau]=0

_BUREAU_ICONS=/usr/share/osmo-operator/icons
_BUREAU_ENTRIES="osmo-launch osmo-dino"
# [2026-10-12] Le fond au repos est la ville SANS antenne (gsm-lab-ville.jpg) ;
# gsm-lab-antenne.jpg (la meme ville, le pylone dresse) est posee en fondu par
# tools/osmo-fond.py quand une 2G/4G tourne. Les deux sont copiees ; le
# paysage low-poly (gsm-lab-fond.jpg) aussi, sans etre le defaut.
_BUREAU_FOND=/usr/share/backgrounds/gsm-lab-ville.jpg
_BUREAU_FONDS="gsm-lab-antenne.jpg gsm-lab-fond.jpg"
_BUREAU_SCHEMA=/usr/share/glib-2.0/schemas/99-osmo-fond.gschema.override

# Le fond par defaut : meme fichier et memes trois sections que l ISO
# (org.gnome.desktop.background, :ubuntu, :GNOME-Greeter - une session
# ubuntu:GNOME lit les secondes de preference). Sans glib-compile-schemas
# (pas de GNOME ici), on pose le fichier et on s arrete la.
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
        # Exec= et Icon= suivent l arbre INSTALLE, pas /opt/GSM en dur : ce
        # depot peut vivre ailleurs (GSM_ROOT).
        sed -i -e "s|^Exec=/opt/GSM/osmo-operator/|Exec=$INST_TREE/|" \
               -e "s|^Icon=.*|Icon=$_BUREAU_ICONS/$e.svg|" "/usr/share/applications/$e.desktop"
        inst_say "menu : /usr/share/applications/$e.desktop"
    done
    # osmo-start-native : le nom du lanceur depuis le 2026-10-18 ; osmo-start-direct
    # garde l ancien nom pour les habitudes et les scripts deja ecrits.
    ln -sf "$INST_TREE/start-native.sh" /usr/local/bin/osmo-start-native
    ln -sf "$INST_TREE/start-native.sh" /usr/local/bin/osmo-start-direct
    # [2026-10-24] c123 : la fenetre du C123 emule (tools/osmo-c123-gtk.py) dans le
    # PATH, pas seulement en alias de shell de connexion. Elle tourne sous le
    # python3 SYSTEME : PyGObject + GTK3 + cairo (Gdk.cairo_set_source_pixbuf
    # veut python3-gi-cairo) viennent d apt, pas de pip.
    ln -sf "$INST_TREE/tools/osmo-c123-gtk.py" /usr/local/bin/c123
    ln -sf "$INST_TREE/tools/osmo-c123-gtk.py" /usr/local/bin/osmo-c123
    # [2026-10-24] banc-rssi, banc-trx, c123-1... : profile.d ET vraies commandes (tools/osmo-banc-cmd.sh)
    install -m644 "$INST_TREE/scripts/osmo-banc-aliases.sh" /etc/profile.d/98-osmo-banc-aliases.sh
    OSMO_BANC_TREE="$INST_TREE" bash "$INST_TREE/tools/osmo-banc-cmd.sh" --install /usr/local/bin >/dev/null
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
