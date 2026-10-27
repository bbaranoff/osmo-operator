#!/bin/bash
# send-mt-sms.sh - send a local MT SMS through proto-smsc-sendmt
# Usage: ./send-mt-sms.sh <imsi> <message> [from_number]
set -euo pipefail

OPERATOR_ID="${OPERATOR_ID:-1}"
SC_ADDRESS="1999001${OPERATOR_ID}444"
SENDMT_SOCKET="/tmp/sendmt_socket"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <imsi> <message> [from_number]"
    echo "  Ex: $0 001010000000001 'Bonjour!'"
    exit 1
fi

DEST_IMSI="$1"; MESSAGE="$2"; FROM="${3:-${SC_ADDRESS}}"

[ ! -S "$SENDMT_SOCKET" ] && { echo "ERREUR: $SENDMT_SOCKET absent"; exit 1; }

sms-encode-text "$MESSAGE" \
    | gen-sms-deliver-pdu "$FROM" \
    | proto-smsc-sendmt "$SC_ADDRESS" "$DEST_IMSI" "$SENDMT_SOCKET"

# This MT goes out over GSUP towards the radio: the software modems of the bench
# would never see it (« sms-over-gsup » bypasses the osmo-msc SMPP). They are
# notified here, otherwise a manual test only reaches the mobile.
"$(dirname "$0")/sms_notify.py" "$DEST_IMSI" "$FROM" "$MESSAGE" || true

echo "MT SMS envoye → IMSI=$DEST_IMSI"
