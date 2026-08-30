#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-wan-sms.sh - Routage SMS inter-serveur
#
# Ajoute le routage SMS pour le prefixe 66 dans la table sms-routing.conf
# de chaque operateur. Les SMS a destination de 66XXXXX sont relayes
# via TCP vers le sms-interop-relay.py du serveur distant.
#
# Usage :
#   sudo ./network/setup-wan-sms.sh <remote_public_ip> [n_operators]
#
# Executer sur CHAQUE serveur.
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

    # Ajouter les routes WAN dans sms-routing.conf
    docker exec "$cname" bash -c "
        CONF='/etc/osmocom/sms-routing.conf'
        
        # Retirer l'ancien bloc WAN s'il existe
        sed -i '/# ── WAN ROUTES/,/# ── FIN WAN/d' \"\$CONF\" 2>/dev/null || true
        
        # Ajouter les operateurs distants dans [operators]
        # On utilise des IDs 100+N pour les operateurs distants
        cat >> \"\$CONF\" << SMSEOF

# ── WAN ROUTES - Serveur distant ${REMOTE_IP} ─────────────────────────────
# Les IDs 100+ designent les operateurs sur le serveur distant.
# Le relay utilise l'IP du serveur distant pour la connexion TCP.

SMSEOF

        # Ajouter dans la section [operators] si pas deja present
        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            if ! grep -q \"^\${wan_op_id} =\" \"\$CONF\"; then
                # Inserer apres la derniere ligne de [operators]
                sed -i \"/^\\[operators\\]/,/^\\[/ {
                    /^\\[routes\\]/i \${wan_op_id} = ${REMOTE_IP}
                }\" \"\$CONF\" 2>/dev/null || true
            fi
        done

        # Ajouter les routes pour le prefixe WAN
        cat >> \"\$CONF\" << SMSEOF2
# Routes WAN : prefixe ${WAN_PREFIX}NXXXX → operateur distant N
SMSEOF2

        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            # Route prefixe : 66 + operateur + numero
            echo \"${WAN_PREFIX}\${j}0000 = \${wan_op_id}\" >> \"\$CONF\"
            for ms in \$(seq 1 8); do
                # <noeud>00<op><ms> : ici j numerote le pair distant, donc il
                # est a la fois son noeud et son operateur (un operateur par
                # noeud sur ce chemin). Fige a 600, le numero construit ne
                # correspondait a aucun abonne du pair.
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
