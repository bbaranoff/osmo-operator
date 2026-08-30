#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/firewall-wan.sh - Ouvre les ports necessaires pour l'interop WAN
#
# Usage : sudo ./network/firewall-wan.sh <remote_ip> [n_operators]
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

REMOTE_IP="${1:?Usage: $0 <remote_ip> [n_operators]}"
N_OPS="${2:-2}"
SIP_WAN_BASE=5080
RTP_WAN_BASE=20000
RTP_PER_OP=500
SMS_RELAY_PORT=7890

echo "=== Firewall WAN Interop - Autorisation ${REMOTE_IP} ==="
echo ""

# Detection du firewall
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    FW="ufw"
elif command -v firewall-cmd &>/dev/null; then
    FW="firewalld"
else
    FW="iptables"
fi

echo "Firewall detecte : ${FW}"
echo ""

for i in $(seq 1 "$N_OPS"); do
    sip_port=$(( SIP_WAN_BASE + (i - 1) * 2 ))
    rtp_start=$(( RTP_WAN_BASE + (i - 1) * RTP_PER_OP ))
    rtp_end=$(( RTP_WAN_BASE + i * RTP_PER_OP - 1 ))

    echo "Op${i}: SIP ${sip_port}/udp  RTP ${rtp_start}:${rtp_end}/udp"

    case "$FW" in
        ufw)
            ufw allow from "$REMOTE_IP" to any port "$sip_port" proto udp
            ufw allow from "$REMOTE_IP" to any port "${rtp_start}:${rtp_end}" proto udp
            ;;
        firewalld)
            firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${REMOTE_IP} port port=${sip_port} protocol=udp accept"
            firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${REMOTE_IP} port port=${rtp_start}-${rtp_end} protocol=udp accept"
            ;;
        iptables)
            # -C ... || -A : idempotent, pas de doublon si relance a chaque WAN.
            iptables -C INPUT -s "$REMOTE_IP" -p udp --dport "$sip_port" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -s "$REMOTE_IP" -p udp --dport "$sip_port" -j ACCEPT
            iptables -C INPUT -s "$REMOTE_IP" -p udp --dport "${rtp_start}:${rtp_end}" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -s "$REMOTE_IP" -p udp --dport "${rtp_start}:${rtp_end}" -j ACCEPT
            ;;
    esac
done

# SMS relay port
echo ""
echo "SMS Relay: ${SMS_RELAY_PORT}/tcp"
case "$FW" in
    ufw)
        ufw allow from "$REMOTE_IP" to any port "$SMS_RELAY_PORT" proto tcp
        ;;
    firewalld)
        firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${REMOTE_IP} port port=${SMS_RELAY_PORT} protocol=tcp accept"
        firewall-cmd --reload
        ;;
    iptables)
        iptables -C INPUT -s "$REMOTE_IP" -p tcp --dport "$SMS_RELAY_PORT" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -s "$REMOTE_IP" -p tcp --dport "$SMS_RELAY_PORT" -j ACCEPT
        ;;
esac

echo ""
echo "✓ Ports ouverts pour ${REMOTE_IP}"
