#!/bin/bash
# osmo-banc-cmd.sh - the bench aliases and functions (scripts/osmo-banc-aliases.sh) as commands.
#
# banc-rssi, banc-trx, banc-mobile... are defined in /etc/profile.d/98-osmo-banc-aliases.sh,
# which only login shells source: nothing from Alt+F2, sudo, a script or a shell that does
# not read profile.d. This script is linked under each of these names in /usr/local/bin; it
# sources the alias file and replays its own name with its arguments. The definition stays
# in ONE place: scripts/osmo-banc-aliases.sh.
#
#   tools/osmo-banc-cmd.sh --install [DIR]   install the links (default /usr/local/bin; DIR
#                                            may be a $ROOTFS/usr/local/bin) for each banc-*
#                                            and c123-* of the file (c123 itself is a direct
#                                            link to tools/osmo-c123-gtk.py, without
#                                            --instance). The links point to
#                                            $OSMO_BANC_TREE/tools (default: /opt/GSM/osmo-operator)
REPO=/opt/GSM/osmo-operator
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ALIASES="$(dirname "$SELF")/../scripts/osmo-banc-aliases.sh"
[ -f "$ALIASES" ] || ALIASES="$REPO/scripts/osmo-banc-aliases.sh"

noms() {
    sed -n -e 's/^alias \([a-z0-9-]*\)=.*/\1/p' -e 's/^function \([a-z0-9-]*\) .*/\1/p' "$ALIASES" \
        | grep -E '^(banc-|c123-)' | sort -u
}

if [ "${1:-}" = "--install" ]; then
    dest="${2:-/usr/local/bin}"
    install -d "$dest"
    for n in $(noms); do ln -sf "${OSMO_BANC_TREE:-$REPO}/tools/osmo-banc-cmd.sh" "$dest/$n"; done
    echo "commandes du banc -> $dest : $(noms | tr '\n' ' ')"
    exit 0
fi

nom="$(basename "$0")"
shopt -s expand_aliases
# shellcheck source=../scripts/osmo-banc-aliases.sh
. "$ALIASES"
type "$nom" >/dev/null 2>&1 || { echo "$nom : inconnu de $ALIASES" >&2; exit 127; }
# eval: an alias is only expanded when a NEW line is read, after the source
eval "$nom \"\$@\""
