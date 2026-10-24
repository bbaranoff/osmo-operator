#!/bin/bash
# osmo-supplements-firstboot.sh - les supplements choisis dans l installeur, au premier demarrage.
#
# [2026-10-24] La page « Supplements » de Calamares (installer/calamares/modules/
# packagechooser-supplements.conf) ne fait qu ecrire /etc/osmo-supplements :
#   OSMO_SUPPLEMENTS="--multi --opencl ..."   les drapeaux d addition.sh
#   HUB_IMAGE="..."                           l origine de l image operateur (multi)
# osmo-supplements.service lance ce script une fois le reseau monte. Reussi : le fichier
# devient /etc/osmo-supplements.fait et l unite se desactive. En echec, on reessaie au
# demarrage suivant, trois fois au plus (/etc/osmo-supplements.essais), puis
# /etc/osmo-supplements.echec : « sudo addition.sh » reste la, a la main.
# Journal : /var/log/osmo-supplements.log (et journalctl -u osmo-supplements).
set -u
CONF=/etc/osmo-supplements
ESSAIS=/etc/osmo-supplements.essais
LOG=/var/log/osmo-supplements.log
REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
MAX="${OSMO_SUPPLEMENTS_ESSAIS:-3}"

_fin() {  # _fin <suffixe> : range la config et desactive l unite
    mv -f "$CONF" "$CONF.$1"
    rm -f "$ESSAIS"
    systemctl disable osmo-supplements.service >/dev/null 2>&1 || true
}

[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
[ -n "${OSMO_SUPPLEMENTS:-}" ] || { _fin fait; exit 0; }

n=$(( $(cat "$ESSAIS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ESSAIS"

# network-online.target ne garantit pas Internet (DHCP lent, Wi-Fi pas encore associe) :
# on attend que GitHub reponde, cinq minutes au plus.
for _ in $(seq 1 60); do
    curl -fsS -m 5 -o /dev/null https://github.com && break
    sleep 5
done

echo "=== $(date '+%F %T') essai $n/$MAX : addition.sh $OSMO_SUPPLEMENTS ===" >>"$LOG"
# shellcheck disable=SC2086
env HUB_IMAGE="${HUB_IMAGE:-}" bash "$REPO/addition.sh" $OSMO_SUPPLEMENTS >>"$LOG" 2>&1 </dev/null
rc=$?
echo "=== $(date '+%F %T') fin : statut $rc ===" >>"$LOG"

if [ "$rc" -eq 0 ]; then
    _fin fait
elif [ "$n" -ge "$MAX" ]; then
    _fin echec
fi
exit "$rc"
