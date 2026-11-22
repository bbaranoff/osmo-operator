#!/bin/bash
# iso_modules/89-apt-release.sh - the GitHub release as an apt source
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to be run on its own. A `return` at the top of a module
# means "nothing to do here".
#
# `make release` publishes the bench .debs and those of the optional groups
# (gr-gsm, 4G...) as a flat apt repository on a rolling GitHub release. This
# module declares it in the image, so what the build left out (a module or a
# docker group unchecked in the menu) stays one `apt install` away:
#     /etc/apt/sources.list.d/osmo-operator-release.list
#     /usr/share/osmo-operator/paquets-release.txt   what is NOT installed here
#
# Env: OSMO_APT_RELEASE (tag, default debs-banc), OSMO_APT_REPO (owner/name,
# default: the origin remote of this repository).
# [trusted=yes]: the index is not signed; it comes over HTTPS from GitHub and
# carries the SHA-256 of each package.

if [ "$ISO_ROLE" = "interstp" ]; then return 0; fi

_APT_TAG="${OSMO_APT_RELEASE:-debs-banc}"
_APT_REPO="${OSMO_APT_REPO:-$(git -C "$DIR" remote get-url origin 2>/dev/null \
    | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
if [ -z "$_APT_REPO" ]; then
    echo -e "  ${YELLOW}!${NC} depot apt de la release : depot GitHub inconnu (OSMO_APT_REPO) - saute"
    return 0
fi
_APT_URL="https://github.com/${_APT_REPO}/releases/download/${_APT_TAG}"

install -d "$ROOTFS/etc/apt/sources.list.d" "$ROOTFS/usr/share/osmo-operator"
echo "deb [trusted=yes] ${_APT_URL} ./" > "$ROOTFS/etc/apt/sources.list.d/osmo-operator-release.list"

# What the release offers and this image does not have (best effort: needs
# the network at build time).
_APT_IDX="$(curl -fsSL --retry 2 "${_APT_URL}/Packages" 2>/dev/null || true)"
{
    echo "# Paquets de la release ${_APT_TAG} (${_APT_URL})"
    echo "# absents de cette image : sudo apt update && sudo apt install <paquet>"
    if [ -n "$_APT_IDX" ]; then
        _inst="$(awk '/^Package:/{p=$2} /^Status:.*installed/{print p}' "$ROOTFS/var/lib/dpkg/status" 2>/dev/null | sort -u)"
        printf '%s\n' "$_APT_IDX" | awk '/^Package:/{print $2}' | sort -u | while read -r _p; do
            grep -qx "$_p" <<<"$_inst" || echo "$_p"
        done
    else
        echo "# (index injoignable au moment du build : apt update le lira)"
    fi
} > "$ROOTFS/usr/share/osmo-operator/paquets-release.txt"
_n="$(grep -vc '^#' "$ROOTFS/usr/share/osmo-operator/paquets-release.txt" || true)"
echo -e "  ${GREEN}✓${NC} depot apt ${CYAN}${_APT_URL}${NC} : ${_n} paquet(s) disponibles hors image"

# End of module: always 0 (build-iso.sh runs under set -e).
true
