#!/bin/bash
# =============================================================================
# start.sh - native launcher: prepares the Calypso environment, then runs run.sh
# (start-native.sh is a symlink to this file)
# =============================================================================
#
# Usage:
#   ./start.sh [options]            native launcher (startup_scripts/*.sh)
#   ./start.sh --docker [options]   hands over to launch/start-docker.sh
#   ./start.sh --lora 1|2 [options] la VOIX de l'appel inter-nœuds en RF sur le
#                                   LoRa (trames GSM-HR brutes dans les trames du
#                                   RNode, --hr implicite), signalisation sur wg0
#                                   LORA_MODE=ip : l'ancien plan, RTP + SMS en IP
#                                   sur tnc0 (sans numéro : déduit de tnc0)
#   ./start.sh --lora 1 --lora-port=/dev/ttyUSB1   port série du RNode (Heltec V3)
#   ./start.sh --hr [options]       voix half-rate (TCH/H) ; sans --hr : full-rate
#   ./start.sh --no-sidecar         pas de BTS#1 fake_trx ni de MS#2 (implicite avec --lora)
#   VAR=x ./start.sh                environment overrides always win
#
# This script starts no daemon itself. It:
#   1. loads the environment (environment/load.env);
#   2. detects the hardware / binaries;
#   3. chooses the mode (profile);
#   4. generates the mobile_*.cfg files;
#   5. exports the required variables;
#   6. executes run.sh (RUN_SH, resolved in startup_scripts/05-run-sh.sh).
#
# All GSM logic then lives in run.sh (and run_modules/).
#
# Configuration chain (do not break it):
#     VAR=x ./start.sh              <- the command line always wins
#       -> environment/load.env
#          -> paths / modes / domains
#     then exec run.sh with the chosen profile.
#
# Known limitation: there is no "must run inside Docker" guard, because the ISO
# has no Docker. Run by mistake on a host with Docker, it dies with "run.sh not
# found": the launchers there are ./launch/start-docker.sh or
# ./launch/start-nitb.sh, not this one.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ── --docker: the bench in containers, through launch/start-docker.sh ────────
# `./start.sh --docker [args]` hands over to start-docker.sh with the other
# arguments untouched; the rest of this script (startup_scripts/) is the
# NATIVE launcher and is not read.
_args=(); _docker=0; _lora=0; _lora_node=""; _lora_port=""; _hr=0; _hrx_extra=(); _no_sidecar=0
while [ $# -gt 0 ]; do
    case "$1" in
        --docker) _docker=1 ;;
        --hr)     _hr=1 ;;                      # voix half-rate (TCH/H), voir plus bas
        --no-sidecar) _no_sidecar=1 ;;          # pas de BTS#1 / MS#2 (startup_scripts/05-run-sh.sh)
        --lora=*) _lora=1; _lora_node="${1#*=}" ;;
        --lora-port=*) _lora_port="${1#*=}" ;;      # port serie du RNode (sinon auto)
        --lora)   _lora=1                       # --lora [1|2]
                  case "${2:-}" in ""|-*) ;; *) _lora_node="$2"; shift ;; esac ;;
        *)        _args+=("$1") ;;
    esac
    shift
done
# startup_scripts/01-defauts-options.sh relit "$@" et refuse les options
# inconnues : on ne lui passe que ce qui ne nous est pas destiné.
set -- "${_args[@]+"${_args[@]}"}"

# ── --lora [1|2]: aiguilleur payload LoRa ───────────────────────────────────
# Nœud 1 : local 10.99.0.1 / 10.200.0.1, pair .2 ; nœud 2 : l'inverse.
# Payload (RTP appel, relais SMS) -> tnc0 vers le pair LoRa, signalisation
# (SS7/SIP) -> wg0, avec --wan --node N --hub-ip 10.99.0.1 ajoutés au lanceur
# (LORA_HUB_IP pour un autre hub). Sans numéro, nœud déduit de tnc0.
# Le LIEN lui-même (tnc0 depuis le RNode Heltec V3, tncattach) est monté ici
# s'il ne l'est pas déjà : network/setup-lora-link.sh. Sans --lora, on retire
# l'aiguilleur si un --lora précédent l'a laissé ; tnc0 reste (lien radio).
_sudo=""; [ "$(id -u)" = 0 ] || _sudo="sudo"
# --lora : pas de side-car (BTS#1 fake_trx, MS#2, modem GPRS). Le second jeu
# radio ne sert à rien sur un banc LoRa et coûte du CPU : avec lui le pont DSP
# notait « horloge lente (x1.6) » et le MS#1 perdait la cellule.
[ "$_lora" = 1 ] && _no_sidecar=1
if [ "$_no_sidecar" = 1 ]; then
    export NO_SIDECAR=1
    echo "[start.sh] --no-sidecar : sans BTS#1 fake_trx, MS#2 ni modem GPRS (modules side-car sautés)"
fi
if [ "$_lora" = 1 ]; then
    _tnc_ip="$(ip -4 -o addr show tnc0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    if [ -z "$_lora_node" ]; then
        case "$_tnc_ip" in 10.200.0.1) _lora_node=1 ;; 10.200.0.2) _lora_node=2 ;; esac
    fi
    case "$_lora_node" in
        1) _peer=2 ;;
        2) _peer=1 ;;
        *) echo "[start.sh] --lora : nœud inconnu '${_lora_node}' (tnc0=${_tnc_ip:-absente}) — utilise --lora 1 ou --lora 2" >&2
           exit 2 ;;
    esac
    if [ -n "$_tnc_ip" ] && [ "$_tnc_ip" != "10.200.0.$_lora_node" ]; then
        echo "[start.sh] attention : --lora $_lora_node mais tnc0 = $_tnc_ip (attendu 10.200.0.$_lora_node)" >&2
    fi
    _lora_mode="${LORA_MODE:-voice}"
    if [ "$_lora_mode" = ip ]; then
        # Lien radio : tnc0 depuis le RNode s'il n'est pas là. Sans lien, inutile
        # d'aller plus loin : l'aiguilleur n'aurait pas d'interface où router.
        if [ -z "$_tnc_ip" ]; then
            $_sudo env LORA_PORT="$_lora_port" bash "$HERE/network/setup-lora-link.sh" up --node "$_lora_node" || {
                echo "[start.sh] --lora : pas de lien radio (tnc0). Module branché ? network/setup-lora-link.sh --info" >&2
                exit 2; }
        fi
    else
        # Voix en RF : le transcodeur HR (--hr implicite) met les trames HR brutes
        # du MGW, codées par le vocodeur ROM du téléphone, dans les trames KISS du
        # RNode (tools/osmo-lora-voice.py) ; il tient le port série, tnc0 n'a pas
        # sa place (même port). Rien n'est aiguillé en IP : la signalisation reste
        # sur wg0, la jambe trunk d'Asterisk ne porte pas de média.
        if [ -n "$_tnc_ip" ] || pgrep -x tncattach >/dev/null; then
            echo "[start.sh] --lora (voix en RF) : tnc0 retirée, le transcodeur prend le port série (LORA_MODE=ip pour l'ancien plan)"
            $_sudo bash "$HERE/network/setup-lora-link.sh" --off >/dev/null || true
        fi
        _lv_port="$_lora_port"
        [ -n "$_lv_port" ] || _lv_port="$(ls /dev/serial/by-id/*CP210* /dev/serial/by-id/*CH9102* /dev/serial/by-id/*CH340* /dev/ttyUSB0 2>/dev/null | head -1)"
        [ -n "$_lv_port" ] && _lv_port="$(readlink -f "$_lv_port")"
        if [ -c "${_lv_port:-/nonexistent}" ]; then
            # Full-rate par défaut (TCH/F, le mode éprouvé du banc) : seules les
            # trames qui portent de la parole partent (VAD), et un sémaphore
            # fait parler un seul côté à la fois, le nœud 1 prioritaire. --hr :
            # trames HR, les deux côtés tiennent ensemble dans le lien.
            _hrx_extra=(--lora "$_lv_port")
            [ "$_lora_node" = 1 ] && _hrx_extra+=(--priority)
            echo "[start.sh] --lora $_lora_node : voix inter-nœuds en RF, RNode $_lv_port ($([ "$_hr" = 1 ] && echo "GSM-HR" || echo "GSM-FR + VAD, talkie a semaphore$([ "$_lora_node" = 1 ] && echo ', prioritaire')") du vocodeur ROM) ; signalisation -> 10.99.0.$_peer (wg0)"
        else
            echo "[start.sh] --lora : aucun port série de RNode (--lora-port=/dev/ttyUSBn) : l'appel inter-nœuds sera muet" >&2
        fi
        unset _lv_port
    fi
    # Identité SS7/WAN toujours sur wg0, jamais sur le lien radio : plan WAN
    # (PC 1.<nœud><op>.x), nœud imposé, hub inter-STP sur le nœud 1 (wg0).
    # Une option donnée explicitement sur la ligne de commande garde la main.
    _has_wan=0; _has_node=0; _has_hub=0; _has_table=0
    for _a in "$@"; do
        case "$_a" in
            --wan|--wan=*|--wan-nodes|--wan-nodes=*) _has_wan=1 ;;
            --node|--node=*)             _has_node=1 ;;
            --hub-ip|--hub-ip=*)         _has_hub=1 ;;
        esac
        case "$_a" in --wan=*|--wan-nodes|--wan-nodes=*) _has_table=1 ;; esac
    done
    # La table WAN du plan LoRa est connue d'avance (nœud 1 = 10.99.0.1, nœud 2
    # = 10.99.0.2) : on la donne, au lieu de laisser wan_self_refresh ne
    # réécrire que notre ligne dans /etc/osmo-wan.conf. Une table périmée sur
    # la machine (un run précédent comme autre nœud) y laissait l'autre nœud à
    # NOTRE adresse : « noeuds 1 et 2 partagent l'IP 10.99.0.2 ».
    # LORA_WAN_NODES pour un autre plan ; --wan FICHIER / --wan-nodes gardent la main.
    [ "$_has_table" = 1 ] || set -- "$@" --wan-nodes "${LORA_WAN_NODES:-1:10.99.0.1:11 2:10.99.0.2:22}"
    [ "$_has_wan" = 1 ]  || set -- "$@" --wan
    [ "$_has_node" = 1 ] || set -- "$@" --node "$_lora_node"
    [ "$_has_hub" = 1 ]  || set -- "$@" --hub-ip "${LORA_HUB_IP:-10.99.0.1}"
    unset _has_wan _has_node _has_hub _has_table _a
    echo "[start.sh]   options lanceur : $*"
    if [ "$_lora_mode" = ip ]; then
        echo "[start.sh] --lora $_lora_node : payload -> 10.200.0.$_peer (tnc0), signalisation -> 10.99.0.$_peer (wg0)"
        $_sudo env WAN_PEER="10.99.0.$_peer" LORA_PEER="10.200.0.$_peer" \
            bash "$HERE/network/setup-lora-payload.sh" up || echo "[start.sh] aiguilleur LoRa: echec (voir ci-dessus)"
    elif ip rule show 2>/dev/null | grep -q 'fwmark 0x10'; then
        $_sudo bash "$HERE/network/setup-lora-payload.sh" --off
    fi
    unset _tnc_ip _peer
elif ip rule show 2>/dev/null | grep -q 'fwmark 0x10'; then
    $_sudo bash "$HERE/network/setup-lora-payload.sh" --off
fi


# ── --hr: voix half-rate (TCH/H, GSM-HR) ─────────────────────────────────────
# Canaux voix du BSC en TCH/H + codec-support fr hr, mobiles en half-speed
# prefer (network/setup-lora-codec.sh). Sans --hr : full-rate d'origine,
# réimposé à chaque lancement (idempotent) : ni un --hr précédent, ni un
# gabarit tiré en TCH/H par un git pull ne doivent survivre.
#
# Asterisk ne connaît pas le GSM-HR : en --hr la jambe SIP passe par le
# transcodeur HR <-> FR (tools/osmo-hr-transcodeur.py, 127.0.0.1:5062, osmo-gapk
# compilé avec --enable-gsmhr), que setup-lora-codec.sh --on intercale entre
# osmo-sip-connector et Asterisk. Il est relancé à chaque start.sh --hr et
# arrêté sans --hr (jambe directe).
_hrx_pid=/run/osmo-hr-transcodeur.pid
if [ -s "$_hrx_pid" ] && grep -qs osmo-hr-transcodeur "/proc/$(cat "$_hrx_pid")/cmdline"; then
    $_sudo kill "$(cat "$_hrx_pid")" 2>/dev/null || true
fi
$_sudo rm -f "$_hrx_pid"
if [ "$_hr" = 1 ] || [ "${#_hrx_extra[@]}" -gt 0 ]; then
    if [ "$_hr" = 1 ]; then
        echo "[start.sh] --hr : voix half-rate (TCH/H), transcodeur HR <-> FR vers Asterisk"
        $_sudo bash "$HERE/network/setup-lora-codec.sh" --on || echo "[start.sh] half-rate: echec (voir ci-dessus)"
    else
        # --lora sans --hr : full-rate, mais la jambe SIP DOIT passer par le
        # transcodeur (5062), sinon l'INVITE va droit d'Asterisk a osmo-sip-connector
        # et la voix part en RTP sur wg0, pas sur l'air. En 5062 il ne transcode
        # rien : les appels locaux sont intacts, les appels inter-noeuds vont au LoRa.
        $_sudo bash "$HERE/network/setup-lora-codec.sh" --fr-via-transcodeur || echo "[start.sh] jambe SIP via transcodeur: echec (voir ci-dessus)"
    fi
    _hrx_extra+=(--codec "$([ "$_hr" = 1 ] && echo hr || echo fr)")
    $_sudo mkdir -p /var/log/osmocom
    # ${_hrx_extra[@]} : --lora PORT avec start.sh --lora (voix inter-nœuds en RF).
    # /root/.env : le python qui a pyserial (rns) ; sinon le python du système.
    _py=/root/.env/bin/python3; [ -x "$_py" ] || _py=python3
    $_sudo sh -c 'p="$1"; s="$2"; pid="$3"; shift 3; nohup "$p" "$s" "$@" >> /var/log/osmocom/hr-transcodeur.log 2>&1 < /dev/null & echo $! > "$pid"' \
        sh "$_py" "$HERE/tools/osmo-hr-transcodeur.py" "$_hrx_pid" "${_hrx_extra[@]+"${_hrx_extra[@]}"}"
    unset _py
else
    $_sudo bash "$HERE/network/setup-lora-codec.sh" --off || echo "[start.sh] full-rate: echec (voir ci-dessus)"
fi
unset _sudo _hrx_pid

if [ "$_docker" = 1 ]; then
    exec bash "$HERE/launch/start-docker.sh" "${_args[@]+"${_args[@]}"}"
fi
unset _args _docker _lora _lora_node _hr

# ── Native launcher: startup_scripts/*.sh, sourced in order (same shell, same variables) ──
for _f in "$HERE"/startup_scripts/*.sh; do
    . "$_f"
done
unset _f
