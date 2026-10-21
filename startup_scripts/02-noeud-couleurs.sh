# 02-noeud-couleurs.sh - partie de start.sh (lignes 543-628 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
NODE_ID_SRC=""
if [ -n "$NODE_ID" ]; then
    NODE_ID_SRC="option --node"
else
    _detected="$(detect_node_id || true)"
    NODE_ID="${_detected%%|*}"
    [ -n "$NODE_ID" ] && NODE_ID_SRC="${_detected#*|}"
    unset _detected
fi
# L'adresse du hub arrive par le MEME chemin que le noeud : start-docker.sh la pose
# dans l'environnement du conteneur (OSMO_HUB_IP, et INTER_STP_IP pour les
# scripts plus anciens). Sans ce repli, HUB_IP restait vide alors que la
# reponse etait deja la : un conteneur lance par docker exec -d n'a pas de
# terminal, la question du hub est donc sautee et l'adresse restait nulle
# jusqu'aux configs. Le repli est pose ici, apres la boucle d'options, pour
# que --hub-ip garde le dernier mot.
[ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-${INTER_STP_IP:-}}"
# ── DERNIER REPLI : L ADRESSE QUE L ASP COMPOSE DEJA ─────────────────────────
# [2026-08-31] Sans HUB_IP, network/set-node-id.sh retombe sur le hub WAN par
# defaut, 192.168.1.49, calcule la source qui y route (192.168.1.31 ici) et
# l ecrit en local-ip de l ASP. Or sur un banc a une machine le hub vit dans un
# conteneur et l ASP compose 127.0.0.1:2908 - le port SCTP que le hub publie
# sur la boucle. La source calculee pour 192.168.1.49 ne mene donc pas au hub,
# et l ASP reste ASP_DOWN. Vu le 31/08 :
#     asp-to-inter  as-inter  ASP_DOWN  client
#                   Local 172.20.0.11:2910  Remote 127.0.0.1:2908
# (172.20.0.11 etant, lui, la valeur du gabarit jamais corrigee - l adresse du
# PREMIER CONTENEUR, qui n existe meme pas sur l hote.)
# Rien de tout cela ne se signale : le journal ne dit qu un timeout.
#
# La config SAIT ou est le hub - c est son remote-ip. On le lit plutot que de
# laisser deviner : la source et la destination viennent alors du meme
# endroit, et `ip route get` rend la bonne patte locale.
# --hub-ip et OSMO_HUB_IP gardent la priorite, ce repli ne sert qu au silence.
if [ -z "$HUB_IP" ] && [ -r "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" ]; then
    HUB_IP="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{a=1; next}
                   a && /^[[:space:]]*remote-ip[[:space:]]/{print $2; exit}' \
              "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
    # [2026-10-18] Une config jamais regeneree (installation fraiche : gabarit
    # copie tel quel) porte le MARQUEUR __INTER_STP_IP__, pas une adresse. Le
    # prendre pour le hub le passait a set-node-id.sh --hub-ip, qui le refusait,
    # et --regen echouait des le premier lancement. Seule une IPv4 compte.
    [[ "$HUB_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || HUB_IP=""
    [ -n "$HUB_IP" ] && echo "  hub        deduit du remote-ip de l ASP : $HUB_IP" >&2
fi
# Pour les scripts qui ne connaissent que deux mondes : docker, ou tout le reste.
case "$RUNTIME_ENV" in docker) NODE_MODE=docker ;; *) NODE_MODE=native ;; esac

# --- affichage (identique a run.sh) -------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_Z=$'\033[0m'
else
    TTY=0
    C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_CYAN=""; C_BOLD=""; C_Z=""
fi
# ── TUER LES PYTHON DU BANC, ET SEULEMENT EUX ───────────────────────────────
# [2026-09-04] Le demontage faisait `killall -9 python3` : TOUS les python3 de
# la machine, encart du bureau compris. On a d abord EPARGNE une liste de
# python du bureau (osmo-fft-snap, osmo-panel...) - liste toujours en retard
# d un outil : le 2026-10-12, le fondu du fond d ecran (tools/osmo-fond.py), la
# zone haute et la sonde des timeslots mouraient encore a chaque --stop.
# [2026-10-12] ON INVERSE : plus de killall, plus de liste d epargnes. On ne
# tue que les python3 DU BANC, nommes un par un par leur ligne de commande :
#   - fake_trx.py et le reste du trx_toolkit d osmocom-bb (radio virtuelle) ;
#   - pont/pont.py (le pont TRX-UDP) et pont/airmesh.py ;
#   - le relais SMS inter-operateurs (scripts/smsc-start.sh) ;
#   - tools/osmo-ril-atmodem.py (le modem AT du telephone).
# Tout autre python3 (bureau, pmbootstrap, un build a cote) n est pas concerne.
# CALYPSO_PY_BANC_EXTRA='motif|motif' ajoute des motifs (regex ERE) sans
# toucher au script.
# [2026-10-20 22:35] + l'air, le pont DSP, le pont audio VSP et les passerelles gdb des instances Calypso :
# un air.py de 22:12 survivait a deux relances et lisait un anneau supprime (plus de LU).
PY_BANC='fake_trx\.py|trx_toolkit/|pont/pont\.py|pont/airmesh\.py|sms-interop|osmo-ril-atmodem\.py|pont/air\.py|pont/pont_dsp\.py|pont\.vsp_audio|gdb-telnet\.py'
[ -n "${CALYPSO_PY_BANC_EXTRA:-}" ] && PY_BANC="$PY_BANC|$CALYPSO_PY_BANC_EXTRA"
killall_python() {
    local sig="${1:--TERM}" pid tue=0
    for pid in $(pgrep -x python3 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Eq "$PY_BANC" || continue
        kill "$sig" "$pid" 2>/dev/null && tue=1
    done
    [ "$tue" = 1 ]
}

