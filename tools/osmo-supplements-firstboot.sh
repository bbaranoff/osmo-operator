#!/bin/bash
# osmo-supplements-firstboot.sh - the supplements chosen in the installer, at first boot.
#
# The Calamares "Supplements" page (installer/calamares/modules/
# packagechooser-supplements.conf) only writes /etc/osmo-supplements:
#   OSMO_SUPPLEMENTS="--multi --opencl ..."   the addition.sh flags
#   HUB_IMAGE="..."                           the origin of the operator image (multi)
# osmo-supplements.service runs this script once the network is up. On success the
# file becomes /etc/osmo-supplements.fait and the unit disables itself. On failure it
# is retried at the next boot, three times at most (/etc/osmo-supplements.essais), then
# /etc/osmo-supplements.echec: "sudo addition.sh" remains available by hand.
# Log: /var/log/osmo-supplements.log (and journalctl -u osmo-supplements).
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

# network-online.target does not guarantee Internet (slow DHCP, Wi-Fi not yet associated):
# wait until GitHub answers, five minutes at most.
for _ in $(seq 1 60); do
    curl -fsS -m 5 -o /dev/null https://github.com && break
    sleep 5
done

echo "=== $(date '+%F %T') essai $n/$MAX : addition.sh $OSMO_SUPPLEMENTS ===" >>"$LOG"
# shellcheck disable=SC2086
# OSMO_COMPTE: the installer account (docker group, icons), nobody being logged in
# yet; otherwise the first human account (uid 1000 and above).
[ -n "${OSMO_COMPTE:-}" ] || OSMO_COMPTE="$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1; exit}')"
env HUB_IMAGE="${HUB_IMAGE:-}" OSMO_COMPTE="${OSMO_COMPTE:-}" bash "$REPO/addition.sh" $OSMO_SUPPLEMENTS >>"$LOG" 2>&1 </dev/null
rc=$?
echo "=== $(date '+%F %T') fin : statut $rc ===" >>"$LOG"

if [ "$rc" -eq 0 ]; then
    _fin fait
elif [ "$n" -ge "$MAX" ]; then
    _fin echec
fi
exit "$rc"
