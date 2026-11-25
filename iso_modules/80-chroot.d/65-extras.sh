# iso_modules/80-chroot.d/65-extras.sh - extras media (tools/osmo-extras-install.sh), schemas compiles.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

    # ── Extras (media, tools) in the native image ───────────────────────
    # Same set and code as addition.sh (tools/osmo-extras-install.sh): Kodi,
    # YouTube + uBlock, Wireshark (root), Linphone, grouped in Games / Media /
    # Phone / Tools folders. Non-fatal. Runs as root in the chroot with the
    # repository at /opt/GSM/osmo-operator.
    _EXTRAS=/opt/GSM/osmo-operator/tools/osmo-extras-install.sh
    if [ -f "$_EXTRAS" ]; then
        echo "  [desktop] jeux + media (natif) : $_EXTRAS"
        # Games (Doom/Quake III, ~470 MB) are excluded: they are installed only by
        # addition.sh --extras on an installed machine.
        OSMO_EXTRAS_JEUX=0 REPO=/opt/GSM/osmo-operator . "$_EXTRAS" && OSMO_EXTRAS_JEUX=0 osmo_extras_install || \
            echo "  [desktop] WARN: osmo_extras_install a echoue (non fatal)"
    else
        echo "  [desktop] WARN: $_EXTRAS absent -- pas de jeux/media dans l image"
    fi

    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true

    echo "  [desktop] GNOME pret : autologin root, X11, NetworkManager actif, Firefox deb Mozilla"

true
