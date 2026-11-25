# iso_modules/80-chroot.d/62-firefox.sh - Firefox (deb Mozilla), snapd.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

[ "${ISO_DESKTOP:-0}" = "1" ] || return 0

    # ── Firefox: the Mozilla .deb, not the snap ────────────────────────────
    # The Ubuntu "firefox" package is a snap transition package, unusable in a
    # chroot. Mozilla publishes .deb packages (packages.mozilla.org), pinned above
    # the Ubuntu one and kept up to date by apt. The desktop file is
    # firefox.desktop and /etc/firefox/policies/policies.json is read directly.
    apt-fast purge -y firefox chromium-browser 2>/dev/null || true
    install -d -m0755 /etc/apt/keyrings
    _ff_ok=0
    # The whole chain is ONE optional component: before, a failing
    # « apt-get update » here stopped the build although Firefox is optional.
    _firefox_deb() {
        osmo_cle packages.mozilla.org.asc https://packages.mozilla.org/apt/repo-signing-key.gpg \
             > /etc/apt/keyrings/packages.mozilla.org.asc || return 1
        echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
            > /etc/apt/sources.list.d/mozilla.list
        printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" \
            > /etc/apt/preferences.d/mozilla
        net_retry apt-get update -qq || return 1
        net_retry apt-fast install -y $APT_OPTS firefox
    }
    composant firefox _firefox_deb
    if [ "$COMPOSANT_RC" = 0 ]; then
        _ff_ok=1
        # The UI language follows the keyboard chosen at build time (--kb).
        composant firefox-l10n net_retry apt-fast install -y $APT_OPTS "firefox-l10n-${OSMO_ISO_KB:-fr}"
        [ "$COMPOSANT_RC" = 0 ] || echo "  [desktop] firefox-l10n-${OSMO_ISO_KB:-fr} indisponible - interface en anglais"
    fi
    # ── Start page ──────────────────────────────────────────────────────────
    # Set as a DEFAULT preference (defaults/pref/), not a policy: policies.json
    # belongs to install-web-service.sh and Firefox reads only one. The operator
    # can still change it. OSMO_FF_HOME selects it at build time.
    if [ "$_ff_ok" = "1" ] && [ -d /usr/lib/firefox/defaults/pref ]; then
        cat > /usr/lib/firefox/defaults/pref/osmo-homepage.js <<FFPREF
// Pose par build-iso.sh (iso_modules/80-chroot.sh). Preference PAR DEFAUT :
// modifiable dans Firefox, remise a cette valeur sur un profil neuf.
pref("browser.startup.homepage", "${OSMO_FF_HOME:-https://pl4y.store}");
pref("browser.startup.page", 1);
FFPREF
        echo "  [desktop] Firefox : page de demarrage ${OSMO_FF_HOME:-https://pl4y.store}"
    fi
    if [ "$_ff_ok" = "1" ]; then
        echo "  [desktop] Firefox : $(dpkg-query -W -f=\${Version} firefox 2>/dev/null) (deb Mozilla, packages.mozilla.org)"
    else
        echo "  [desktop] WARN: Firefox (deb Mozilla) NON installe - packages.mozilla.org injoignable ?"
    fi
    # No snaps in the image: disable snap seeding and remove the snap install unit
    # that older images installed (it would fail at boot on a cached rootfs).
    rm -rf /var/lib/osmo-snaps
    rm -f /etc/systemd/system/osmo-firefox-snap.service \
          /etc/systemd/system/multi-user.target.wants/osmo-firefox-snap.service \
          /usr/local/sbin/osmo-firefox-snap
    # ── snapd stays usable ──────────────────────────────────────────────────
    # The image ships no snaps, but snapd remains available through SOCKET
    # activation: it starts only when someone talks to it. snapd.seeded returns
    # immediately without a seed.
    systemctl unmask snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service 2>/dev/null || true
    systemctl enable snapd.socket snapd.apparmor.service 2>/dev/null || true
    # snapd.service is not enabled: the socket starts it on demand.
    systemctl disable snapd.service 2>/dev/null || true

true
