#!/bin/bash
# iso_modules/51-network-monitoring.sh - step 5c: network_monitoring in /opt/GSM
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here".
#
# network_monitoring is the bench's PHONE application (« Network Monitor »:
# postmarketOS / GTK, and Android): radio, calls and SMS through the bench,
# association with a node by invitation or QR code (tools/osmo-inscription.py,
# tab « Telephones » of osmo-gtk). The image carries:
#   /opt/GSM/network_monitoring              the tree, WITH its .git
#   /opt/user_interface/pmos/apk/            its Alpine package (dist/*.apk)
#                                            and the key that signs it:
#                                            osmo-pmos-setup installs it in the
#                                            postmarketOS VM at its first start
#   /usr/local/bin/network-monitor           the application itself
#
# Environment:
#   OSMO_NETMON_REPO / OSMO_NETMON_BRANCH   repository and branch to clone
#   OSMO_NETMON_LOCAL                       a local tree used instead of the
#                                           clone (default: the host's
#                                           /opt/GSM/network_monitoring when the
#                                           clone fails)

if [ "$ISO_ROLE" = "interstp" ]; then return 0; fi

NETMON_REPO="${OSMO_NETMON_REPO:-https://github.com/bbaranoff/network_monitoring}"
NETMON_BRANCH="${OSMO_NETMON_BRANCH:-main}"
NETMON_TREE="$ROOTFS/opt/GSM/network_monitoring"
NETMON_TMP="$WORK/network_monitoring-clone"
NETMON_LOCAL="${OSMO_NETMON_LOCAL:-}"
echo -e "${GREEN}[5c/9] network_monitoring (appli telephone du banc)...${NC}"
rm -rf "$NETMON_TMP"
if [ -n "$NETMON_LOCAL" ] && [ -d "$NETMON_LOCAL" ]; then
    rm -rf "$NETMON_TREE"; mkdir -p "$ROOTFS/opt/GSM"
    cp -a "$NETMON_LOCAL" "$NETMON_TREE"
    echo -e "  ${GREEN}✓${NC} network_monitoring : arbre local ${CYAN}$NETMON_LOCAL${NC}"
elif [ "${OSMO_ISO_INHERITED:-0}" = "1" ] && [ -d "$NETMON_TREE/.git" ]; then
    echo -e "  ${GREEN}✓${NC} network_monitoring : arbre du rootfs herite conserve"
elif GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$NETMON_BRANCH" "$NETMON_REPO" "$NETMON_TMP" >/dev/null 2>&1; then
    rm -rf "$NETMON_TREE"; mkdir -p "$ROOTFS/opt/GSM"
    mv "$NETMON_TMP" "$NETMON_TREE"
    echo -e "  ${GREEN}✓${NC} network_monitoring clone (${NETMON_BRANCH}) - $(git -C "$NETMON_TREE" log -1 --format='%h %s')"
elif [ -d /opt/GSM/network_monitoring ]; then
    rm -rf "$NETMON_TMP" "$NETMON_TREE"; mkdir -p "$ROOTFS/opt/GSM"
    cp -a /opt/GSM/network_monitoring "$NETMON_TREE"
    echo -e "  ${YELLOW}⚠${NC} network_monitoring : clone impossible - arbre de l hote copie"
else
    rm -rf "$NETMON_TMP"
    echo -e "  ${YELLOW}⚠${NC} network_monitoring : clone impossible (reseau ?) et pas d arbre local - absent de l image" >&2
fi

if [ -d "$NETMON_TREE" ]; then
    rm -rf "$NETMON_TREE/__pycache__"
    chmod -R a+rX "$NETMON_TREE"
    install -d "$ROOTFS/usr/local/bin"
    ln -sfn /opt/GSM/network_monitoring/network-monitor.py "$ROOTFS/usr/local/bin/network-monitor"
    # The Alpine package and its key, where osmo-pmos-setup looks for them:
    # THE LATEST RELEASE of the application (GitHub: the asset
    # network-monitor-<version>-r<N>-postmarketos.apk and the .rsa.pub that
    # signs it); without network, or with OSMO_NETMON_APK=local, the one of the
    # tree (dist/). On the installed bench osmo-pmos-setup asks the release
    # again at each start of the VM and takes a newer one.
    _nm_dst="$ROOTFS/opt/user_interface/pmos/apk"
    _nm_gh="${OSMO_NETMON_GH:-bbaranoff/network_monitoring}"
    _nm_apk=""; _nm_src="dist/ de l arbre"
    install -d "$_nm_dst"
    if [ "${OSMO_NETMON_APK:-publie}" != local ]; then
        _nm_json="$(curl -fsSL -m 15 "https://api.github.com/repos/$_nm_gh/releases/latest" 2>/dev/null || true)"
        _nm_url="$(printf '%s' "$_nm_json" | grep -oE '"browser_download_url": *"[^"]+/network-monitor-[0-9][^"/]*-r[0-9]+(-postmarketos)?\.apk"' \
                    | head -n1 | sed -E 's/.*"(https?:[^"]+)"/\1/')"
        if [ -n "$_nm_url" ]; then
            _nm_nom="$(basename "$_nm_url" | sed 's/-postmarketos\.apk$/.apk/')"
            if curl -fsSL -m 120 -o "$WORK/$_nm_nom" "$_nm_url" 2>/dev/null && [ -s "$WORK/$_nm_nom" ]; then
                rm -f "$_nm_dst"/network-monitor-*.apk "$_nm_dst"/*.rsa.pub
                install -m 0644 "$WORK/$_nm_nom" "$_nm_dst/$_nm_nom"
                for _k in $(printf '%s' "$_nm_json" | grep -oE '"browser_download_url": *"[^"]+\.rsa\.pub"' | sed -E 's/.*"(https?:[^"]+)"/\1/'); do
                    curl -fsSL -m 30 -o "$_nm_dst/$(basename "$_k")" "$_k" 2>/dev/null || true
                done
                _nm_apk="$_nm_dst/$_nm_nom"; _nm_src="derniere release de $_nm_gh"
            fi
        fi
    fi
    if [ -z "$_nm_apk" ]; then
        _nm_apk="$(ls -t "$NETMON_TREE"/dist/network-monitor-*.apk 2>/dev/null | head -n1)"
        if [ -n "$_nm_apk" ]; then
            rm -f "$_nm_dst"/network-monitor-*.apk
            install -m 0644 "$_nm_apk" "$_nm_dst/"
            for _k in "$NETMON_TREE"/dist/*.rsa.pub; do
                [ -f "$_k" ] && install -m 0644 "$_k" "$_nm_dst/"
            done
        fi
    fi
    if [ -n "$_nm_apk" ]; then
        echo -e "  ${GREEN}✓${NC} paquet postmarketOS : ${CYAN}$(basename "$_nm_apk")${NC} (${_nm_src}) - installe dans la VM a son premier demarrage (osmo-pmos-setup)"
    else
        echo -e "  ${YELLOW}!${NC} pas de dist/network-monitor-*.apk : rien a installer dans postmarketOS (build-apk.sh)"
    fi
fi

# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. Always 0 here.
true
