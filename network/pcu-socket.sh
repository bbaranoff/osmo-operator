#!/bin/bash
# =============================================================================
# network/pcu-socket.sh - PCU socket harness (BTS <-> osmo-pcu)
#
# The PCU (GPRS/EGPRS) connects to ONE unix socket per BTS:
#   - the main BTS (osmo-bts-trx.cfg): default socket /tmp/pcu_bts, the one
#     run.sh gives the PCU (PCU_SOCKET);
#   - the side-car BTS (osmo-bts-trx-bts1.cfg): pcu-socket /tmp/pcu_bts2, which
#     no PCU serves. A socket with no process behind it stays on disk and
#     suggests a link that does not exist.
#
# This script changes NO config. It says who listens to what, and removes the
# orphan sockets (file present, no listening process) so the next start begins
# from a clean slate.
#
#   network/pcu-socket.sh          status (default)
#   network/pcu-socket.sh --fix    removes the orphan sockets /tmp/pcu_bts*
#
# Called by start-native.sh just before run.sh is started (--fix).
# =============================================================================
set -u

PCU_SOCKET="${PCU_SOCKET:-/tmp/pcu_bts}"
PCU_LOG="${PCU_LOG:-/var/log/osmocom/osmo-pcu.log}"
MODE=check
[ "${1:-}" = "--fix" ] && MODE=fix

# A socket is "in service" when a process listens on it (ss -xlp shows it).
listener_of() {
    ss -xlp 2>/dev/null | grep -F " $1 " | sed -n 's/.*users:((\"\([^\"]*\)\",pid=\([0-9]*\).*/\1 pid \2/p' | head -1
}

rc=0
echo "pcu-socket : socket attendu par le PCU = $PCU_SOCKET"

for s in /tmp/pcu_bts /tmp/pcu_bts2; do
    if [ ! -e "$s" ]; then
        printf '  %-16s absent\n' "$s"
        continue
    fi
    who="$(listener_of "$s")"
    if [ -n "$who" ]; then
        printf '  %-16s en service (%s)\n' "$s" "$who"
    elif [ "$MODE" = fix ]; then
        if rm -f "$s"; then
            printf '  %-16s orphelin supprime\n' "$s"
        else
            printf '  %-16s orphelin, suppression impossible\n' "$s"; rc=1
        fi
    else
        printf '  %-16s orphelin (aucun processus) - lancer avec --fix\n' "$s"
    fi
done

# Who serves the PCU: the last logged connection to the expected socket.
if [ -r "$PCU_LOG" ]; then
    last="$(sed 's/\x1b\[[0-9;]*m//g' "$PCU_LOG" | grep -a "PCU socket $PCU_SOCKET has been connected" | tail -1)"
    if [ -n "$last" ]; then
        echo "  PCU          connecte a $PCU_SOCKET  ($(echo "$last" | awk '{print $4, $5, $6}'))"
    else
        echo "  PCU          pas de connexion journalisee a $PCU_SOCKET"
    fi
fi

# Config: which BTSs declare a PCU socket, and which one.

for c in /etc/osmocom/osmo-bts*.cfg; do
    [ -r "$c" ] || continue
    line="$(grep -E '^[[:space:]]*pcu-socket[[:space:]]' "$c" | head -1 | sed 's/^[[:space:]]*//')"
    printf '  %-28s %s\n' "$(basename "$c")" "${line:-(defaut : /tmp/pcu_bts)}"
done

exit $rc
