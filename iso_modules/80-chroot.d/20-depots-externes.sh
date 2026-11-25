# iso_modules/80-chroot.d/20-depots-externes.sh - depots tiers ajoutes AVANT l apt-get update unique : NodeSource, MongoDB.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# ── NodeSource: before the single apt-get update, nodejs in PKGS ───────────
# The dashboard needs node 22, which the distribution does not ship. The
# repository is added by hand (ASCII key in /etc/apt/keyrings, read as-is by
# apt >= 2.4) so nodejs joins the single install list. If the key download
# fails, the official setup script is used as a fallback further down.
NODE_VIA_APT=0
if ! command -v node >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    _depot_nodesource() {
        osmo_cle nodesource.asc https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            > /etc/apt/keyrings/nodesource.asc || return 1
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
    }
    composant depot-nodesource _depot_nodesource
    if [ "$COMPOSANT_RC" = 0 ]; then
        NODE_VIA_APT=1
    else
        echo "  repli sur setup_22.x apres l install"
        rm -f /etc/apt/keyrings/nodesource.asc /etc/apt/sources.list.d/nodesource.list
    fi
fi

# ── MongoDB (Open5GS HSS/PCRF subscriber store): before the apt update ─────
# mongodb-org is not in Ubuntu: repo.mongodb.org (noble/8.0), dearmored key in
# /usr/share/keyrings, same file as tools/osmo-lte-install.sh. Without the key
# (no network to mongodb.org) the repository is skipped and osmo-epc reports it
# on first start.
MONGO_VIA_APT=0
if [ "${ISO_ROLE:-operator}" != "interstp" ]; then
    _depot_mongodb() {
        osmo_cle mongodb-server-8.0.asc https://www.mongodb.org/static/pgp/server-8.0.asc \
            | gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg 2>/dev/null || return 1
        echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
            > /etc/apt/sources.list.d/mongodb-org-8.0.list
    }
    composant depot-mongodb _depot_mongodb
    if [ "$COMPOSANT_RC" = 0 ]; then
        MONGO_VIA_APT=1
    else
        echo "  Open5GS sans base d abonnes (osmo-lte-install --deps plus tard)"
        rm -f /usr/share/keyrings/mongodb-server-8.0.gpg /etc/apt/sources.list.d/mongodb-org-8.0.list
    fi
fi

true
