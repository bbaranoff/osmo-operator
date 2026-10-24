#!/bin/bash
# osmo-banc-cmd.sh - les alias et fonctions du banc (scripts/osmo-banc-aliases.sh) en VRAIES commandes.
#
# [2026-10-24] banc-rssi, banc-trx, banc-mobile... n existaient que dans un shell de connexion qui
# source /etc/profile.d/98-osmo-banc-aliases.sh : rien depuis Alt+F2, sudo, un script ou un shell
# qui ne lit pas profile.d. Ce script est lie sous chacun de ces noms dans /usr/local/bin ; il
# source le fichier d alias et rejoue son propre nom avec ses arguments. La definition reste UNE :
# scripts/osmo-banc-aliases.sh.
#
#   tools/osmo-banc-cmd.sh --install [DIR]   pose les liens (defaut /usr/local/bin ; DIR peut etre
#                                            un $ROOTFS/usr/local/bin) pour chaque banc-* et c123-*
#                                            du fichier (c123 lui-meme est un lien direct vers
#                                            tools/osmo-c123-gtk.py, sans --instance). Les liens
#                                            visent $OSMO_BANC_TREE/tools (defaut /opt/GSM/osmo-operator)
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
# eval : l alias n est developpe qu a la lecture d une NOUVELLE ligne, apres le source
eval "$nom \"\$@\""
