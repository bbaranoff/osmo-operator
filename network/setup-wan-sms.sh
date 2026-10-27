#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-wan-sms.sh - inter-server SMS routing
#
# Adds the SMS routing for prefix 66 to the sms-routing.conf table of each
# operator. SMS to 66XXXXX are relayed over TCP to the remote server's
# sms-interop-relay.py.
#
# Usage:
#   sudo ./network/setup-wan-sms.sh <remote_public_ip> [n_operators]
#
# Run on EACH server.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

REMOTE_IP="${1:-}"
N_OPS="${2:-2}"
WAN_PREFIX="66"
RELAY_PORT=7890
CONTAINER_PREFIX="osmo-operator-"

if [ -z "$REMOTE_IP" ]; then
    echo "Usage: sudo $0 <remote_public_ip> [n_operators]"
    exit 1
fi

echo -e "${GREEN}Configuration SMS WAN → ${REMOTE_IP}${NC}"
echo ""

for i in $(seq 1 "$N_OPS"); do
    cname="${CONTAINER_PREFIX}${i}"

    echo -e "  ${CYAN}Op${i}${NC} - Mise a jour sms-routing.conf..."

    # Add the WAN routes to sms-routing.conf
    docker exec "$cname" bash -c "
        CONF='/etc/osmocom/sms-routing.conf'
        
        # Remove the old WAN block if present
        sed -i '/# ── WAN ROUTES/,/# ── FIN WAN/d' \"\$CONF\" 2>/dev/null || true
        
        # Add the remote operators to [operators]
        # IDs 100+N are used for the remote operators
        cat >> \"\$CONF\" << SMSEOF

# ── WAN ROUTES - remote server ${REMOTE_IP} ───────────────────────────────
# IDs 100+ designate the operators on the remote server.
# The relay uses the remote server's IP for the TCP connection.

SMSEOF

        # Add to the [operators] section if not already present
        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            if ! grep -q \"^\${wan_op_id} =\" \"\$CONF\"; then
                # Insert after the last line of [operators]
                sed -i \"/^\\[operators\\]/,/^\\[/ {
                    /^\\[routes\\]/i \${wan_op_id} = ${REMOTE_IP}
                }\" \"\$CONF\" 2>/dev/null || true
            fi
        done

        # Add the routes for the WAN prefix
        cat >> \"\$CONF\" << SMSEOF2
# WAN routes: prefix ${WAN_PREFIX}NXXXX → remote operator N
SMSEOF2

        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            # Prefix route: 66 + operator + number
            echo \"${WAN_PREFIX}\${j}0000 = \${wan_op_id}\" >> \"\$CONF\"
            for ms in \$(seq 1 8); do
                # <node>00<op><ms>: here j numbers the remote peer, so it is
                # both its node and its operator (one operator per node on
                # this path).

                msisdn=\$(( j * 100000 + j * 100 + ms ))
                echo \"${WAN_PREFIX}\${msisdn} = \${wan_op_id}\" >> \"\$CONF\"
            done
        done
        
        echo '# ── FIN WAN ─────────────────────────────────────────────────────' >> \"\$CONF\"
    "

    echo -e "  ${GREEN}✓${NC} Op${i} SMS WAN routes ajoutees"
done

echo ""
echo -e "${GREEN}SMS WAN routing configure.${NC}"
echo -e "  SMS vers ${CYAN}${WAN_PREFIX}10001${NC} → serveur distant Op1 MS1"
echo -e "  SMS vers ${CYAN}${WAN_PREFIX}20001${NC} → serveur distant Op2 MS1"
echo ""
echo -e "  ${CYAN}Note :${NC} Le sms-interop-relay.py doit etre accessible"
echo -e "  depuis l'exterieur sur le port TCP ${RELAY_PORT}."
echo -e "  Firewall : ufw allow from ${REMOTE_IP} to any port ${RELAY_PORT} proto tcp"
