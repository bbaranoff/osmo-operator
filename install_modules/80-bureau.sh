# =============================================================================
#  80-bureau - icones et raccourcis du bureau (install native)
# =============================================================================
#  Pose EXACTEMENT ce que l ISO pose (build-iso.sh, etape 8d) a partir des
#  memes fichiers du depot :
#     data/desktop/osmo-launch.desktop   "Lancer le banc GSM"  -> launch.sh
#     data/desktop/osmo-multi.desktop    "multi-operator"      -> start-multi.sh
#     data/*.svg                         les icones
#  et le lien /usr/local/bin/osmo-start-direct -> start-direct.sh.
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
#  Ni osmo-tutorial, ni osmo-addition, ni osmo-update : leurs lanceurs sont
#  des enrobages ecrits par build-iso.sh pour l image (terminal + pkexec) et
#  dependent du bureau GNOME de l ISO. Sur une machine deja installee, launch.sh
#  et start-multi.sh se suffisent.
# -----------------------------------------------------------------------------
INST_REGISTER bureau "Bureau : icones et raccourcis"
INST_DEPS[bureau]="configs"
INST_REQUIRED[bureau]=0

_BUREAU_ICONS=/usr/share/osmo-operator/icons
_BUREAU_ENTRIES="osmo-launch osmo-multi"

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
    ln -sf "$INST_TREE/start-direct.sh" /usr/local/bin/osmo-start-direct

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
