#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-wan-interop.sh - Interconnexion WAN entre deux instances osmo_egprs
#
# Permet aux MS d'un serveur d'appeler les MS de l'autre serveur via le
# prefixe +66. Exemple : composer 6610001 depuis le serveur A appelle
# le MS 10001 sur le serveur B.
#
# Architecture :
#
#   Serveur A (82.66.231.141)              Serveur B (37.59.111.84)
#   ┌─────────────────────────┐            ┌─────────────────────────┐
#   │ Op1 Asterisk :5060      │            │ Op1 Asterisk :5060      │
#   │   172.20.0.11           │            │   172.20.0.11           │
#   │ Op2 Asterisk :5060      │            │ Op2 Asterisk :5060      │
#   │   172.20.0.12           │            │   172.20.0.12           │
#   └──────────┬──────────────┘            └──────────┬──────────────┘
#              │                                      │
#   Host iptables DNAT                     Host iptables DNAT
#   Op1: :5080 → 172.20.0.11:5060         Op1: :5080 → 172.20.0.11:5060
#   Op2: :5082 → 172.20.0.12:5060         Op2: :5082 → 172.20.0.12:5060
#              │                                      │
#              └──────── SIP/RTP over WAN ────────────┘
#                   82.66.231.141 ↔ 37.59.111.84
#
# Ports WAN par operateur :
#   OpN SIP  : 5080 + (N-1)*2
#   OpN RTP  : 20000 + (N-1)*500  →  20000 + N*500 - 1
#
# Prefixe d'appel :
#   66 + numero_normal  →  route vers le serveur distant
#   Ex: 6610001 = appeler MS 10001 sur le serveur distant
#   Ex: 6620001 = appeler MS 20001 (op2) sur le serveur distant
#
# Usage :
#   sudo ./network/setup-wan-interop.sh <local_public_ip> <remote_public_ip> [n_operators]
#
# Executer sur CHAQUE serveur avec les IPs inversees :
#   Serveur A : sudo ./network/setup-wan-interop.sh 82.66.231.141 37.59.111.84 2
#   Serveur B : sudo ./network/setup-wan-interop.sh 37.59.111.84 82.66.231.141 2
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Parametres ────────────────────────────────────────────────────────────────
LOCAL_IP="${1:-}"
REMOTE_IP="${2:-}"
N_OPS="${3:-2}"
WAN_PREFIX="66"                    # Prefixe pour les appels inter-serveur
SIP_WAN_BASE=5080                  # Port SIP WAN de base
RTP_WAN_BASE=20000                 # Port RTP WAN de base
RTP_PER_OP=500                     # Ports RTP par operateur
CONTAINER_PREFIX="osmo-operator-"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # pour appeler network/firewall-wan.sh

if [ -z "$LOCAL_IP" ] || [ -z "$REMOTE_IP" ]; then
    echo -e "${RED}Usage: sudo $0 <local_public_ip> <remote_public_ip> [n_operators]${NC}"
    echo ""
    echo "  Serveur A : sudo $0 82.66.231.142 37.59.111.84 2"
    echo "  Serveur B : sudo $0 37.59.111.84 82.66.231.142 2"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Doit etre lance en root (sudo).${NC}"; exit 1
fi

# ── Fonctions helper ──────────────────────────────────────────────────────────
op_backbone_ip() { echo "172.20.0.$((10 + $1))"; }
op_sip_port()    { echo $(( SIP_WAN_BASE + ($1 - 1) * 2 )); }
op_rtp_start()   { echo $(( RTP_WAN_BASE + ($1 - 1) * RTP_PER_OP )); }
op_rtp_end()     { echo $(( RTP_WAN_BASE + $1 * RTP_PER_OP - 1 )); }
op_container()   { echo "${CONTAINER_PREFIX}$1"; }

# NOTE : sed -i echoue sur les bind mounts Docker (rename() impossible).
# Toutes les editions sed utilisent le pattern : cp file /tmp → sed -i /tmp → cp back

# ══════════════════════════════════════════════════════════════════════════════
# Banner
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        WAN Interop - Interconnexion osmo_egprs distante         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Local       : ${CYAN}${LOCAL_IP}${NC}"
echo -e "  Remote      : ${CYAN}${REMOTE_IP}${NC}"
echo -e "  Operateurs  : ${CYAN}${N_OPS}${NC}"
echo -e "  Prefixe WAN : ${CYAN}${WAN_PREFIX}${NC}"
echo ""

# ── Verification des containers ───────────────────────────────────────────────
echo -e "${GREEN}[1/5] Verification des containers...${NC}"
for i in $(seq 1 "$N_OPS"); do
    cname=$(op_container "$i")
    if ! docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
        echo -e "  ${RED}✗ ${cname} non trouve${NC}"
        echo -e "  ${YELLOW}Lancez start.sh d'abord.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} ${cname} actif"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2/5] iptables - DNAT pour le trafic entrant depuis le serveur distant
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[2/5] Configuration iptables (DNAT entrant)...${NC}"

# Activer le forwarding IP
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

# Nettoyer les anciennes regles WAN interop (chaine personnalisee)
iptables -t nat -D PREROUTING -j OSMO_WAN_INTEROP 2>/dev/null || true
iptables -t nat -F OSMO_WAN_INTEROP 2>/dev/null || true
iptables -t nat -X OSMO_WAN_INTEROP 2>/dev/null || true

# Creer la chaine
iptables -t nat -N OSMO_WAN_INTEROP

for i in $(seq 1 "$N_OPS"); do
    bb_ip=$(op_backbone_ip "$i")
    sip_port=$(op_sip_port "$i")
    rtp_start=$(op_rtp_start "$i")
    rtp_end=$(op_rtp_end "$i")

    # SIP signaling : port externe → container:5060
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p udp --dport "$sip_port" \
        -j DNAT --to-destination "${bb_ip}:5060"

    # SIP TCP (au cas ou)
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p tcp --dport "$sip_port" \
        -j DNAT --to-destination "${bb_ip}:5060"

    # RTP : plage de ports → container (meme ports en interne)
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p udp --dport "${rtp_start}:${rtp_end}" \
        -j DNAT --to-destination "${bb_ip}"

    echo -e "  ${CYAN}Op${i}${NC} SIP :${sip_port} → ${bb_ip}:5060  RTP ${rtp_start}-${rtp_end} → ${bb_ip}"
done

# Inserer la chaine dans PREROUTING
iptables -t nat -I PREROUTING -j OSMO_WAN_INTEROP

# MASQUERADE pour le retour (le container voit le trafic comme venant du host)
# --ctstate DNAT : sans restriction, ce masquage prenait AUSSI les flux du LAN
# simplement routes vers un conteneur ; celui-ci repondait alors a l'hote et non
# au client, qui n'a jamais vu la reponse. On ne masque que ce que le DNAT
# ci-dessus a redirige. Restreindre plutot sur l'adresse de l'hote ne matcherait
# rien : apres DNAT la source est celle du serveur distant, pas la notre.
# L'ancienne regle large est retiree d'abord - le garde -C teste la spec exacte,
# sans cela les deux resteraient en place et la large gagnerait.
iptables -t nat -D POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null || true
if ! iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null; then
    # Repli si le module conntrack d'iptables manque : sans lui le -A echoue et
    # le script s'arretait la, la regle large ayant deja ete retiree - plus
    # aucun masquage, donc plus aucun retour vers les conteneurs.
    iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null || {
        echo -e "  ${YELLOW}! -m conntrack indisponible : masquage large 172.20.0.0/24 (moins precis)${NC}"
        iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -j MASQUERADE || true
    }
fi

echo -e "  ${GREEN}✓ iptables configure${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2bis/5] Firewall - ouverture automatique des ports entrants depuis le distant
# Le DNAT ci-dessus redirige le trafic, mais si un firewall (ufw/firewalld/
# iptables INPUT) filtre l'INPUT, SIP/RTP WAN sont droppes -> pas d'audio WAN.
# On applique donc les regles a CHAQUE lancement du WAN (network/firewall-wan.sh est
# idempotent : pas de doublon si relance).
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[2bis/5] Firewall - ouverture des ports WAN (entrant ${REMOTE_IP})...${NC}"
if [ -x "$SCRIPT_DIR/firewall-wan.sh" ] || [ -f "$SCRIPT_DIR/firewall-wan.sh" ]; then
    if bash "$SCRIPT_DIR/firewall-wan.sh" "$REMOTE_IP" "$N_OPS"; then
        echo -e "  ${GREEN}✓ Firewall ouvert pour ${REMOTE_IP}${NC}"
    else
        echo -e "  ${YELLOW}⚠ network/firewall-wan.sh a echoue - ouvre les ports a la main (voir resume).${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠ network/firewall-wan.sh introuvable dans ${SCRIPT_DIR} - ports a ouvrir a la main.${NC}"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [3/5] Configuration RTP - plage de ports WAN par operateur
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[3/5] Configuration RTP WAN dans chaque container...${NC}"

for i in $(seq 1 "$N_OPS"); do
    cname=$(op_container "$i")
    rtp_start=$(op_rtp_start "$i")
    rtp_end=$(op_rtp_end "$i")

    # Creer/modifier rtp.conf dans Asterisk pour utiliser la plage WAN
    # On garde la plage originale pour les appels locaux, mais on ajoute
    # la config dans le transport PJSIP (external_media_address)
    docker exec "$cname" bash -c "cat > /etc/asterisk/rtp.conf << 'RTPEOF'
[general]
rtpstart=${rtp_start}
rtpend=${rtp_end}
strictrtp=no
icesupport=no
RTPEOF"

    echo -e "  ${CYAN}Op${i}${NC} RTP range: ${rtp_start}-${rtp_end}"
done

echo -e "  ${GREEN}✓ RTP configure${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [4/5] PJSIP + Dialplan - Trunks WAN et contexte interop distant
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[4/5] Injection PJSIP trunks + dialplan WAN...${NC}"

for i in $(seq 1 "$N_OPS"); do
    cname=$(op_container "$i")
    local_sip_port=$(op_sip_port "$i")
    rtp_start=$(op_rtp_start "$i")
    rtp_end=$(op_rtp_end "$i")

    # ── PJSIP : patch transport-udp + trunks vers chaque operateur distant ──

    # Generer les blocs PJSIP pour les trunks WAN
    pjsip_wan=""

    # Pas de transport-wan separe - on patche transport-udp existant
    # pour ajouter external_media_address (necessaire pour SDP corrects)
    docker exec "$cname" bash -c "
        if ! grep -q 'external_media_address' /etc/asterisk/pjsip.conf; then
            cp /etc/asterisk/pjsip.conf /tmp/_pj.work
            sed -i '/^\[transport-udp\]/,/^\$/ {
                /^\$/i\\
external_media_address=${LOCAL_IP}\\
external_signaling_address=${LOCAL_IP}\\
local_net=172.20.0.0/24\\
local_net=127.0.0.0/8
            }' /tmp/_pj.work
            cp /tmp/_pj.work /etc/asterisk/pjsip.conf
            rm -f /tmp/_pj.work
        fi
    "

    pjsip_wan+="
; ══════════════════════════════════════════════════════════════════════════════
; WAN INTEROP - Trunks vers serveur distant ${REMOTE_IP}
; Genere par network/setup-wan-interop.sh le $(date '+%Y-%m-%d %H:%M:%S')
; ══════════════════════════════════════════════════════════════════════════════
"

    # Un identify par ADRESSE, hors de la boucle : identify ne regarde que
    # l'adresse source, jamais le port. Un bloc par operateur distant en posait
    # autant pour la meme adresse, et l'appel entrant etait attribue a l'un
    # d'eux au hasard. Deux adresses seulement : la passerelle du bridge, par
    # laquelle arrive le trafic WAN masque par l'hote, et le serveur distant
    # lui-meme quand il n'est pas masque.
    pjsip_wan+="
; ── Identification des appels entrants du WAN ─────────────────────────────────
[wan-identify-remote]
type=identify
endpoint=wan_trunk_op1
match=${REMOTE_IP}

[wan-identify-gw]
type=identify
endpoint=wan_trunk_op1
match=172.20.0.1
"

    # Un trunk par operateur distant
    for j in $(seq 1 "$N_OPS"); do
        remote_sip_port=$(op_sip_port "$j")

        pjsip_wan+="
; ── Trunk WAN → Serveur distant Op${j} (${REMOTE_IP}:${remote_sip_port}) ─────
[wan_trunk_op${j}]
type=endpoint
transport=transport-udp
context=wan_in
disallow=all
allow=gsm
allow=ulaw
aors=wan_trunk_op${j}
media_encryption=no
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
ice_support=no

[wan_trunk_op${j}]
type=aor
contact=sip:${REMOTE_IP}:${remote_sip_port}
qualify_frequency=30
qualify_timeout=5.0
"
    done

    # Injecter dans pjsip.conf
    # D'abord retirer l'ancien bloc WAN s'il existe
    docker exec "$cname" bash -c "
        cp /etc/asterisk/pjsip.conf /tmp/_pj.work
        sed -i '/; ══.*WAN INTEROP/,\$d' /tmp/_pj.work 2>/dev/null || true
        cp /tmp/_pj.work /etc/asterisk/pjsip.conf
        rm -f /tmp/_pj.work
    "

    # Ajouter le nouveau bloc
    docker exec "$cname" bash -c "cat >> /etc/asterisk/pjsip.conf << 'PJSIPEOF'
${pjsip_wan}
PJSIPEOF"

    echo -e "  ${CYAN}Op${i}${NC} PJSIP: ${N_OPS} trunk(s) WAN ajoutes"

    # ── Dialplan : contextes [wan_out] et [wan_in] ────────────────────────

    # ── Softphones SIP : numero → endpoint, extraits DYNAMIQUEMENT de pjsip.conf ──
    # Tout endpoint portant un "callerid=... <NNN>" (ex: linphone_A <100>) devient
    # routable SIP→SIP over WAN dans les deux sens, sans hardcoder les numeros.
    softphones=$(docker exec "$cname" cat /etc/asterisk/pjsip.conf | awk '
        /^\[/                 { s=$0; gsub(/[][]/,"",s); ep=s }
        /callerid=.*<[0-9]+>/ { n=$0; sub(/.*</,"",n); sub(/>.*/,"",n); print n":"ep }
    ')
    echo -e "  ${CYAN}Op${i}${NC} Softphones SIP detectes: $(echo "$softphones" | tr '\n' ' ')"

    # Generer le contexte wan_out (appels sortants vers le distant)
    wan_dialplan="
; ══════════════════════════════════════════════════════════════════════════════
; WAN INTEROP - Routage appels inter-serveur (prefixe ${WAN_PREFIX})
; Genere par network/setup-wan-interop.sh le $(date '+%Y-%m-%d %H:%M:%S')
;
; Composer ${WAN_PREFIX}NXXXX = appeler NXXXX sur le serveur distant
; Composer ${WAN_PREFIX}NXXXXX = appeler NXXXXX sur le serveur distant
; Ex: ${WAN_PREFIX}10001 → MS 10001 op1 distant
;     ${WAN_PREFIX}20001 → MS 20001 op2 distant
; ══════════════════════════════════════════════════════════════════════════════

[wan_out]
"
    for j in $(seq 1 "$N_OPS"); do
        # Pattern pour prefixe 1 chiffre operateur (1-9)
        if [ "$j" -lt 10 ]; then
            wan_dialplan+="
; → Operateur distant ${j} (4 chiffres)
exten => _${j}XXXX,1,NoOp(=== WAN OUT Op${j}: \${EXTEN} → ${REMOTE_IP} ===)
 same => n,Dial(PJSIP/\${EXTEN}@wan_trunk_op${j},,rT)
 same => n,NoOp(WAN: \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()

; → Operateur distant ${j} (5 chiffres)
exten => _${j}XXXXX,1,NoOp(=== WAN OUT Op${j}: \${EXTEN} → ${REMOTE_IP} ===)
 same => n,Dial(PJSIP/\${EXTEN}@wan_trunk_op${j},,rT)
 same => n,NoOp(WAN: \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()
"
        else
            wan_dialplan+="
; → Operateur distant ${j} (prefixe 2 chiffres)
exten => _${j}XXXX,1,NoOp(=== WAN OUT Op${j}: \${EXTEN} → ${REMOTE_IP} ===)
 same => n,Dial(PJSIP/\${EXTEN}@wan_trunk_op${j},,rT)
 same => n,Congestion()
 same => n,Hangup()
"
        fi
    done

    # → Softphones SIP distants (SIP→SIP over WAN) - generes dynamiquement.
    #   Un Linphone local compose ${WAN_PREFIX}<num> ; le ${WAN_PREFIX} est strippe
    #   en amont (Goto wan_out,\${EXTEN:2}), on route donc <num> vers le softphone
    #   homologue du meme operateur sur le serveur distant.
    for sp in $softphones; do
        sp_num="${sp%%:*}"
        wan_dialplan+="
; → Softphone SIP distant ${sp_num} (Op${i})
exten => ${sp_num},1,NoOp(=== WAN OUT SIP Op${i}: ${sp_num} → ${REMOTE_IP} ===)
 same => n,Dial(PJSIP/${sp_num}@wan_trunk_op${i},,rT)
 same => n,NoOp(WAN: \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()
"
    done

    wan_dialplan+="
; Fallback WAN
exten => _X.,1,NoOp(=== WAN OUT: destination inconnue \${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()

; ══════════════════════════════════════════════════════════════════════════════
; [wan_in] - Appels entrants DEPUIS le serveur distant
; ══════════════════════════════════════════════════════════════════════════════
[wan_in]

; Appel distant → MS local (meme operateur)
exten => _${i}XXXX,1,NoOp(=== WAN IN → GSM local Op${i}: \${EXTEN} ===)
 same => n,Set(CALLERID(all)=<\${CALLERID(num)}>)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Dial(PJSIP/\${EXTEN}@gsm_msc,,rT)
 same => n,Congestion()
 same => n,Hangup()

exten => _${i}XXXXX,1,NoOp(=== WAN IN → GSM local Op${i}: \${EXTEN} ===)
 same => n,Set(CALLERID(all)=<\${CALLERID(num)}>)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Dial(PJSIP/\${EXTEN}@gsm_msc,,rT)
 same => n,Congestion()
 same => n,Hangup()
"

    # Softphones SIP locaux (appels entrants depuis le serveur distant) - dynamiques
    for sp in $softphones; do
        sp_num="${sp%%:*}"
        sp_ep="${sp#*:}"
        wan_dialplan+="
; Softphone SIP local ${sp_num} → ${sp_ep}
exten => ${sp_num},1,NoOp(=== WAN IN → ${sp_ep} local (${sp_num}) ===)
 same => n,Gosub(sub-record,s,1(${sp_num}))
 same => n,Dial(PJSIP/${sp_ep},,rT)
 same => n,Congestion()
 same => n,Hangup()
"
    done

    wan_dialplan+="
; Appel distant → autre operateur local (re-route via interop_out)
exten => _X.,1,NoOp(=== WAN IN → routage local: \${EXTEN} ===)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Goto(interop_out,\${EXTEN},1)

; Echo test depuis le distant
exten => 600,1,NoOp(=== WAN ECHO TEST ===)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Playback(demo-echodone)
 same => n,Hangup()
"

    # Retirer l'ancien bloc WAN du dialplan
    docker exec "$cname" bash -c '
        cp /etc/asterisk/extensions.conf /tmp/_ext.work
        sed -i "/; ══.*WAN INTEROP.*Routage/,\$d" /tmp/_ext.work 2>/dev/null || true
        cp /tmp/_ext.work /etc/asterisk/extensions.conf
        rm -f /tmp/_ext.work
    '

    # Ajouter au dialplan
    docker exec "$cname" bash -c "cat >> /etc/asterisk/extensions.conf << 'EXTEOF'
${wan_dialplan}
EXTEOF"

    # ── Injecter le pattern _66. directement dans [gsm_in] et [internal] ──
    docker exec "$cname" bash -c '
        EXT="/etc/asterisk/extensions.conf"
        if ! grep -q "_'"${WAN_PREFIX}"'\." "$EXT"; then
            cp "$EXT" /tmp/_ext.work

            sed -i "/^\[gsm_in\]$/a\\
\\
; -- WAN : prefixe '"${WAN_PREFIX}"' -> serveur distant --\\
exten => _'"${WAN_PREFIX}"'.,1,NoOp(=== GSM -> WAN: strip '"${WAN_PREFIX}"' ===)\\
 same => n,Gosub(sub-record,s,1(\${EXTEN:2}))\\
 same => n,Goto(wan_out,\${EXTEN:2},1)" /tmp/_ext.work

            sed -i "/^\[internal\]$/a\\
\\
; -- WAN : prefixe '"${WAN_PREFIX}"' -> serveur distant --\\
exten => _'"${WAN_PREFIX}"'.,1,NoOp(=== SIP -> WAN: strip '"${WAN_PREFIX}"' ===)\\
 same => n,Gosub(sub-record,s,1(\${EXTEN:2}))\\
 same => n,Goto(wan_out,\${EXTEN:2},1)" /tmp/_ext.work

            cp /tmp/_ext.work "$EXT"
            rm -f /tmp/_ext.work
        fi
    '

    echo -e "  ${CYAN}Op${i}${NC} Dialplan: wan_out + wan_in + routage ${WAN_PREFIX}"
done

echo -e "  ${GREEN}✓ PJSIP + Dialplan configures${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [5/5] Restart Asterisk (transport modifie → restart complet requis)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[5/5] Restart Asterisk...${NC}"

for i in $(seq 1 "$N_OPS"); do
    cname=$(op_container "$i")

    docker exec "$cname" bash -c "
        asterisk -rx 'core stop now' 2>/dev/null || pkill asterisk 2>/dev/null || true
        sleep 2
        pkill -9 asterisk 2>/dev/null || true
        sleep 1
        rm -f /var/lib/asterisk/astdb.sqlite3
        asterisk -f &
        disown
    " 2>/dev/null || true

    echo -e "  ${CYAN}Op${i}${NC} Asterisk redemarre"
done

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Resume
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              WAN Interop configure avec succes !                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Serveur local  :${NC} ${CYAN}${LOCAL_IP}${NC}"
echo -e "  ${BOLD}Serveur distant:${NC} ${CYAN}${REMOTE_IP}${NC}"
echo ""

echo -e "  ${BOLD}Ports WAN par operateur :${NC}"
for i in $(seq 1 "$N_OPS"); do
    sip_port=$(op_sip_port "$i")
    rtp_start=$(op_rtp_start "$i")
    rtp_end=$(op_rtp_end "$i")
    echo -e "    Op${i}: SIP ${CYAN}:${sip_port}${NC}  RTP ${CYAN}${rtp_start}-${rtp_end}${NC}"
done

echo ""
echo -e "  ${BOLD}Comment appeler :${NC}"
echo -e "    Depuis un MS local, composer ${CYAN}${WAN_PREFIX}${NC} + numero distant"
echo -e "    Ex: ${CYAN}${WAN_PREFIX}10001${NC} = appeler MS 10001 op1 sur ${REMOTE_IP}"
echo -e "    Ex: ${CYAN}${WAN_PREFIX}20001${NC} = appeler MS 20001 op2 sur ${REMOTE_IP}"
echo ""

echo -e "  ${BOLD}Firewall :${NC} ${GREEN}deja applique automatiquement sur CE serveur${NC} (etape 2bis)."
echo -e "    Pense a lancer le WAN aussi sur ${CYAN}${REMOTE_IP}${NC} (il ouvrira son propre INPUT)."
echo -e "    Pour re-ouvrir manuellement : ${CYAN}sudo ${SCRIPT_DIR}/network/firewall-wan.sh ${REMOTE_IP} ${N_OPS}${NC}"
echo -e "    Equivalent ufw :"
echo ""
for i in $(seq 1 "$N_OPS"); do
    sip_port=$(op_sip_port "$i")
    rtp_start=$(op_rtp_start "$i")
    rtp_end=$(op_rtp_end "$i")
    echo -e "    ${YELLOW}# Op${i}${NC}"
    echo -e "    ufw allow from ${REMOTE_IP} to any port ${sip_port} proto udp"
    echo -e "    ufw allow from ${REMOTE_IP} to any port ${rtp_start}:${rtp_end} proto udp"
done

echo ""
echo -e "  ${BOLD}Test rapide :${NC}"
echo -e "    # Depuis le container op1 sur ce serveur :"
echo -e "    docker exec -it osmo-operator-1 bash"
echo -e "    # Dans le VTY mobile (Ctrl-b → fenetre ue_g1) :"
echo -e "    call 1 ${WAN_PREFIX}10001"
echo ""
echo -e "  ${BOLD}Diagnostic :${NC}"
echo -e "    # Verifier la connectivite SIP :"
echo -e "    docker exec osmo-operator-1 asterisk -rx 'pjsip show endpoints'"
echo -e "    docker exec osmo-operator-1 asterisk -rx 'pjsip show aors'"
echo -e "    # Logs Asterisk :"
echo -e "    docker exec osmo-operator-1 asterisk -rx 'core set verbose 5'"
echo ""

# ── Sauvegarder la config pour persistence ────────────────────────────────────
CONFIG_SAVE="/etc/osmo-wan-interop.conf"
cat > "$CONFIG_SAVE" << EOF
# osmo-wan-interop.conf - sauvegarde config WAN
# Genere le $(date)
LOCAL_IP=${LOCAL_IP}
REMOTE_IP=${REMOTE_IP}
N_OPS=${N_OPS}
WAN_PREFIX=${WAN_PREFIX}
SIP_WAN_BASE=${SIP_WAN_BASE}
RTP_WAN_BASE=${RTP_WAN_BASE}
RTP_PER_OP=${RTP_PER_OP}
EOF

echo -e "  Config sauvegardee dans ${CYAN}${CONFIG_SAVE}${NC}"
echo -e "  Relancer apres reboot : ${CYAN}sudo $0 ${LOCAL_IP} ${REMOTE_IP} ${N_OPS}${NC}"
echo ""
