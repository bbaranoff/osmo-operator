# iso_modules/80-chroot.d/55-node-web.sh - node (repli NodeSource), dashboard osmo-egprs-web.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# Docker is NOT installed in the ISO: the lab runs via start-native.sh and the
# web dashboard via native node. The host build uses the host docker only to
# extract binaries and configs.

# NodeSource fallback: only if the key could not be added before the update
# (see NODE_VIA_APT above). The official script runs its own update.
if ! command -v node >/dev/null 2>&1; then
    net_retry curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
    bash /tmp/nodesource_setup.sh
    net_retry apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/GSM/osmo-egprs-web/package.json ]; then
    # cd in THIS shell, as before: the next fragments start from there.
    _web_npm() { cd /opt/GSM/osmo-egprs-web && net_retry npm install --production 2>/dev/null; }
    composant web-npm _web_npm
fi

# ── Dashboard installed at build time ───────────────────────────────────────
# install-web-service.sh (osmo-egprs-web repository) installs the node runtime,
# JS dependencies, the systemd unit, the TLS certificate and the Firefox
# policy. Running it here makes failures visible during the build;
# osmo-egprs-web-install.service at first boot is an idempotent catch-up.
#
#   WEB_NO_TLS=1   no certificate at build time: a private key generated here
#                  would be identical in every ISO. The certificate and the
#                  Firefox policy (which names the same addresses) are created
#                  on the machine at first boot with its real addresses.
#   WEB_NO_START=1 systemd does not run in a chroot; systemctl restart would
#                  fail and the script is set -eu.
if [ -x /opt/GSM/osmo-egprs-web/install-web-service.sh ]; then
    echo "  [web] install-web-service.sh (sans TLS ni demarrage : chroot)"
    composant dashboard env WEB_NO_TLS=1 WEB_NO_START=1 bash /opt/GSM/osmo-egprs-web/install-web-service.sh
else
    composant_absent dashboard "install-web-service.sh absent de /opt/GSM/osmo-egprs-web"
fi

true
