#!/bin/bash
# run.sh - Orchestrateur intra-container Osmocom
#
# PHY_MODE=faketrx (defaut) : fake_trx → trxcon → mobile
# PHY_MODE=virtphy           : osmo-bts-virtual → virtphy → mobile
#
set -euo pipefail

LOG_FILE="/var/log/osmocom/run.sh.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

[[ -n "${DEBUG:-}" ]] && set -x

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Ce fichier est DEPLOYE HORS DEPOT (/etc/osmocom/run.sh, /root/run.sh) et lance
# par des scripts qui n'exportent pas forcement le manifeste : sous `set -u`, un
# ${GSM_ROOT} nu tuerait le script ici. D'ou les valeurs de repli explicites.
FAKETRX_PY="${FAKETRX_PY:-${FAKE_TRX:-${OSMOCOM_BB:-${GSM_ROOT:-/opt/GSM}/osmocom-bb}/src/target/trx_toolkit/fake_trx.py}}"
OPERATOR_ID="${OPERATOR_ID:-1}"; N_MS="${N_MS:-1}"; MOBILE_MODE="${MOBILE_MODE:-combined}"
PHY_MODE="${PHY_MODE:-faketrx}"   # faketrx | virtphy
# RUN_NO_PROCESS=1 : prepare/genere uniquement les configs (MS, TRX, handover)
# et sort SANS lancer aucun process (ni osmo-start, ni fake_trx/trxcon, ni
# mobile/asterisk/smsc). Utilise par le mode QEMU de start.sh qui veut juste
# les configs en place avant de lancer ${OQC_ROOT}/run.sh.
RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
MAX_MS=64; MAX_MS_PER_MOBILE=8; MS_PER_TRX=16
BB_PORT_BASE=6700; BB_PORT_STEP=3; BTS_PORT_BASE=5700
L2_SOCK_BASE="/tmp/osmocom_l2"; SAP_SOCK_BASE="/tmp/osmocom_sap"

[[ ! "$N_MS" =~ ^[0-9]+$ ]] || [ "$N_MS" -lt 1 ] || [ "$N_MS" -gt $MAX_MS ] && N_MS=1
[[ ! "$OPERATOR_ID" =~ ^[0-9]+$ ]] || [ "$OPERATOR_ID" -lt 1 ] || [ "$OPERATOR_ID" -gt 24 ] && exit 1
[[ "$MOBILE_MODE" != "combined" && "$MOBILE_MODE" != "split" ]] && MOBILE_MODE="combined"
[[ "$PHY_MODE" != "faketrx" && "$PHY_MODE" != "virtphy" ]] && PHY_MODE="faketrx"

N_TRX=$(( (N_MS + MS_PER_TRX - 1) / MS_PER_TRX ))
[ "$MOBILE_MODE" = "combined" ] && N_GROUPS=$(( (N_MS + MAX_MS_PER_MOBILE - 1) / MAX_MS_PER_MOBILE )) || N_GROUPS=$N_MS

echo -e "  ${CYAN}Op${OPERATOR_ID}${NC}  N_MS=${N_MS}  mode=${MOBILE_MODE}  phy=${PHY_MODE}  TRX=${N_TRX}  groups=${N_GROUPS}"

# ── Helpers ───────────────────────────────────────────────────────────────────
bb_port()  { echo $(( BB_PORT_BASE + ($1 - 1) * BB_PORT_STEP )); }
l2_sock()  { echo "${L2_SOCK_BASE}_${1}"; }
sap_sock() { echo "${SAP_SOCK_BASE}_${1}"; }
ms_imsi()  { printf '%s%s%04d%06d' "$_MCC" "$_MNC" "$OPERATOR_ID" "$1"; }
ms_imei()  { printf '3589250059%02d%02d0' "$OPERATOR_ID" "$1"; }
ms_ki()    { printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x %02x' "$1" "$OPERATOR_ID"; }

wait_port() {
    local host=$1 port=$2 label=$3 timeout=${4:-60} elapsed=0
    echo -ne "  Attente ${label} (${host}:${port})"
    while ! bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed+1)); echo -n "."
        [ "$elapsed" -ge "$timeout" ] && echo -e " ${RED}TIMEOUT${NC}" && return 1
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

wait_udp() {
    local port=$1 label=$2 timeout=${3:-30} elapsed=0
    echo -ne "  Attente ${label} (UDP ${port})"
    while ! ss -unlp | grep -q ":${port} "; do
        sleep 1; elapsed=$((elapsed+1)); echo -n "."
        [ "$elapsed" -ge "$timeout" ] && echo -e " ${RED}TIMEOUT${NC}" && return 1
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ── TMUX ──────────────────────────────────────────────────────────────────────
SESSION="osmocom"; TMUX_SOCKET="/tmp/osmocom_tmux"; TMUX_OK=false

init_tmux() {
    echo -e "  ${CYAN}Init tmux...${NC}"
    rm -f "$TMUX_SOCKET"

    tmux -S "$TMUX_SOCKET" start-server 2>/dev/null || true
    sleep 0.5
    tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION" -n main 2>/dev/null || true
    sleep 0.5

    local i=0
    while [ ! -S "$TMUX_SOCKET" ] && [ $i -lt 30 ]; do sleep 0.3; i=$((i+1)); done

    if [ -S "$TMUX_SOCKET" ] && tmux -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null; then
        TMUX_OK=true
        echo -e "  ${GREEN}✓ tmux OK${NC}"
    else
        TMUX_OK=false
        echo -e "  ${RED}✗ tmux echec - mode background${NC}"
    fi
}

run_in_tmux() {
    local win=$1; shift; local cmd="$*"
    if [ "$TMUX_OK" = true ]; then
        tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n "$win" 2>/dev/null || true
        sleep 0.2
        tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${win}" "$cmd" C-m 2>/dev/null || true
    else
        echo -e "  ${YELLOW}[bg]${NC} ${win}"
        bash -c "$cmd" >"/var/log/osmocom/${win}.log" 2>&1 &
    fi
}

# ── Config MS ─────────────────────────────────────────────────────────────────
generate_ms_configs() {
    local base_cfg="/root/.osmocom/bb/mobile.cfg"
    [ -f "$base_cfg" ] || { echo -e "${RED}mobile.cfg introuvable${NC}"; return 1; }

    local ref_imsi ref_imei ref_ki ref_l2 ref_sap
    ref_imsi=$(grep -oP '^\s+imsi\s+\K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_imei=$(grep -oP '^\s+imei \K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_ki=$(grep -oP '^\s+ki comp128 \K[0-9a-f ]+' "$base_cfg" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//' || true)
    ref_l2=$(grep -oP 'layer2-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || echo "/tmp/osmocom_l2")
    ref_sap=$(grep -oP 'sap-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || true)

    if [ -z "$ref_imsi" ]; then
        ref_imsi=$(grep -E 'imsi [0-9]+' "$base_cfg" | head -1 | awk '{print $NF}')
        ref_imei=$(grep -E 'imei [0-9]+' "$base_cfg" | head -1 | awk '{print $2}')
        ref_ki=$(grep -E 'ki comp128' "$base_cfg" | head -1 | sed 's/.*ki comp128 //' | sed 's/[[:space:]]*$//')
    fi
    [ -z "$ref_imsi" ] || [ -z "$ref_imei" ] || [ -z "$ref_ki" ] && return 1

    _MCC=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $2}' | head -1); _MCC=${_MCC:-001}
    _MNC=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $3}' | head -1); _MNC=${_MNC:-01}
    echo -e "  ${CYAN}[ref]${NC} IMSI=${ref_imsi} MCC/MNC=${_MCC}/${_MNC}"

    local global_line; global_line=$(grep -n '^ms [0-9]' "$base_cfg" | head -1 | cut -d: -f1)
    [ -z "$global_line" ] && return 1
    local global_header; global_header=$(head -n $((global_line - 1)) "$base_cfg")
    local ms_template; ms_template=$(awk '/^ms [0-9]/{if(f)exit;f=1;p=1} p{print} /^(exit|end)$/&&p&&f{p=0;exit}' "$base_cfg")
    [ -z "$ms_template" ] && return 1

    _write_ms_block() {
        local outfile=$1 lnum=$2 gidx=$3
        local ni=$(ms_imsi "$gidx") ne=$(ms_imei "$gidx") nk=$(ms_ki "$gidx") nl=$(l2_sock "$gidx") ns=$(sap_sock "$gidx")
        local block; block=$(echo "$ms_template" | sed \
            -e "s|^ms [0-9]\+|ms ${lnum}|" \
            -e "s|layer2-socket ${ref_l2}|layer2-socket ${nl}|" \
            -e "s|imsi ${ref_imsi}|imsi ${ni}|" \
            -e "s|imei ${ref_imei}[[:space:]]*[0-9]*|imei ${ne}|" \
            -e "s|ki comp128 ${ref_ki}|ki comp128 ${nk}|")
        [ -n "$ref_sap" ] && block=$(echo "$block" | sed "s|sap-socket ${ref_sap}|sap-socket ${ns}|") \
            || block=$(echo "$block" | sed "/layer2-socket/a\\ sap-socket ${ns}")
        echo "$block" >> "$outfile"; echo "" >> "$outfile"
    }

    # Si le fichier est bind-monte (docker -v file:file), rm renvoie EBUSY.
    # Dans ce cas on ne peut pas le supprimer mais on peut le truncate puis
    # re-ecrire dedans, ce qui est equivalent pour notre besoin.
    for f in /root/.osmocom/bb/mobile_ms*.cfg /root/.osmocom/bb/mobile_group*.cfg; do
        [ -e "$f" ] || continue
        if ! rm -f "$f" 2>/dev/null; then
            : > "$f" 2>/dev/null || \
                echo -e "  ${YELLOW}[warn] $f ni rm ni truncate (bind-mount RO ?)${NC}"
        fi
    done

    if [ "$MOBILE_MODE" = "split" ]; then
        for ms in $(seq 1 "$N_MS"); do
            echo "$global_header" > "/root/.osmocom/bb/mobile_ms${ms}.cfg"
            _write_ms_block "/root/.osmocom/bb/mobile_ms${ms}.cfg" 1 "$ms"
        done
    else
        local grp=1 gs=1
        while [ "$gs" -le "$N_MS" ]; do
            local ge=$((gs + MAX_MS_PER_MOBILE - 1)); [ "$ge" -gt "$N_MS" ] && ge=$N_MS
            local cfg="/root/.osmocom/bb/mobile_group${grp}.cfg"
            echo "$global_header" | sed "s|127\.0\.0\.1|127.0.0.${grp}|g" > "$cfg"
            local li=1; for ms in $(seq "$gs" "$ge"); do _write_ms_block "$cfg" "$li" "$ms"; li=$((li+1)); done
            echo -e "  ${CYAN}[Grp${grp}]${NC} IP=127.0.0.${grp} MS ${gs}-${ge}"
            grp=$((grp+1)); gs=$((ge+1))
        done
    fi
    echo -e "  ${GREEN}✓ Configs MS OK${NC}"
}

# ── TRX injection (fake_trx mode) ────────────────────────────────────────────
inject_extra_trx() {
    [ "$1" -le 1 ] && return 0
    local bts="/etc/osmocom/osmo-bts-trx.cfg" bsc="/etc/osmocom/osmo-bsc.cfg"
    [ -f "$bts" ] || return 0
    local arfcn0; arfcn0=$(grep -E '^\s+arfcn [0-9]+' "$bsc" | head -1 | awk '{print $2}')
    local tmp; tmp=$(mktemp)
    awk -v n="$1" '/^ osmotrx ip local/&&!d{for(i=1;i<n;i++)printf" instance %d\n  osmotrx rx-gain 40\n  osmotrx tx-attenuation 50\n",i;d=1}{print}' "$bts" > "$tmp"; cp "$tmp" "$bts"; rm -f "$tmp"
    for t in $(seq 1 $(($1-1))); do
        local a=$((arfcn0 + t*2))
        printf ' trx %d\n  power-ramp max-initial 23000 mdBm\n  power-ramp step-size 2000 mdB\n  power-ramp step-interval 1\n  ms-power-control osmo\n  phy 0 instance %d\n' "$t" "$t" >> "$bts"
    done
    echo -e "  ${GREEN}✓ ${1} TRX injectes (osmo-bts-trx)${NC}"
}

# ── TRX injection (virtphy mode) ─────────────────────────────────────────────
inject_extra_trx_virtual() {
    [ "$1" -le 1 ] && return 0
    local bts="/etc/osmocom/osmo-bts-virtual.cfg"
    [ -f "$bts" ] || return 0

    # Ajouter des instances phy supplementaires apres "instance 0"
    local tmp; tmp=$(mktemp)
    local insert_done=0
    while IFS= read -r line; do
        echo "$line" >> "$tmp"
        if [ $insert_done -eq 0 ] && echo "$line" | grep -q '^ instance 0'; then
            for t in $(seq 1 $(($1-1))); do
                echo " instance ${t}" >> "$tmp"
            done
            insert_done=1
        fi
    done < "$bts"
    cp "$tmp" "$bts"; rm -f "$tmp"

    # Ajouter les TRX supplementaires en fin de fichier
    for t in $(seq 1 $(($1-1))); do
        printf ' trx %d\n  power-ramp max-initial 23000 mdBm\n  power-ramp step-size 2000 mdB\n  power-ramp step-interval 1\n  ms-power-control osmo\n  phy 0 instance %d\n' "$t" "$t" >> "$bts"
    done
    echo -e "  ${GREEN}✓ ${1} TRX injectes (osmo-bts-virtual)${NC}"
}

# ── Handover ──────────────────────────────────────────────────────────────────
inject_handover() {
    local cfg="/etc/osmocom/osmo-bsc.cfg"; [ -f "$cfg" ] || return 0
    local tmp; tmp=$(mktemp)
    sed -e 's/^ handover 0/ handover 1/' -e 's/^ handover algorithm 1/ handover algorithm 2/' "$cfg" > "$tmp"
    awk '/^ handover algorithm 2/&&!d{print;print" handover2 window rxlev averaging 10\n handover2 window rxqual averaging 1\n handover2 window rxlev neighbor averaging 10\n handover2 power budget interval 6\n handover2 power budget hysteresis 3\n handover2 maximum distance 9999\n handover2 assignment 1\n handover2 tdma-measurement full";d=1;next}/^ handover1 /{next}{print}' "$tmp" > "${tmp}.2"
    cp "${tmp}.2" "$cfg"; rm -f "$tmp" "${tmp}.2"
    echo -e "  ${GREEN}✓ Handover algo 2${NC}"
}

# ── Sinks PulseAudio (gsm_audio + gsm_mic) ───────────────────────────────────
# Docker : /scripts/  |  natif : /etc/osmocom/  (meme script, chemin different)
# Idempotent et NON FATAL : sans PulseAudio l'audio gapk est indispo, mais on ne
# doit jamais tuer run.sh (set -e) pour ca.
# $1 = timeout d'attente de PulseAudio (defaut 30 s). Le demon n'est pas demarre
# par ce script mais par lib/audio.sh (pipeline qemu) : sur l'appel PRECOCE [2d]
# il peut ne pas etre encore la, d'ou un timeout court pour ne pas staller.
setup_pulse_sinks() {
    local PULSE_SETUP=/scripts/pulse-gsm-setup.sh
    [ -f "$PULSE_SETUP" ] || PULSE_SETUP=/etc/osmocom/pulse-gsm-setup.sh
    [ -f "$PULSE_SETUP" ] || { echo -e "  ${YELLOW}pulse-gsm-setup.sh introuvable - audio indispo${NC}"; return 0; }
    PULSE_TIMEOUT="${1:-30}" "$PULSE_SETUP" \
        || echo -e "  ${YELLOW}[warn] pulse-gsm-setup.sh echoue (audio indispo) - on continue${NC}"
}

# ── Bridge audio UNIVERSEL ───────────────────────────────────────────────────
# gapk (RTP reseau → sink gsm_audio) + sortie son. Appele en mode faketrx/virtphy
# ET en mode no-process (qemu) - c'est CE bridge qui manquait en qemu (run.sh
# sortait avant [6c] → gsm_audio muet → "pas d'audio en qemu").
#
# Sortie : si le pulse de l'HOTE est joignable en TCP (relai ouvert par start.sh,
# = WSLg→Windows en WSL, = pulse de session en Linux natif), on fait un pont
# direct parec|paplay (1 seule horloge, pas de derive → pas de son "pete").
# Sinon, fallback loopback local vers le sink par defaut du conteneur (carte).
audio_bridge() {
    pactl info >/dev/null 2>&1 || { echo -e "  ${YELLOW}PulseAudio indisponible - bridge audio non lance${NC}"; return 0; }

    # gapk : RTP reseau → sink gsm_audio
    local GAPK=/scripts/gapk-start.sh; [ -f "$GAPK" ] || GAPK=/etc/osmocom/gapk-start.sh
    if [ -f "$GAPK" ]; then
        run_in_tmux "gapk" "GAPK_ALSA_DEV=gsm_out bash '$GAPK' auto gsm gsm_out"
        echo -e "  ${GREEN}✓ gapk auto (RTP reseau → gsm_audio)${NC}"
    else
        echo -e "  ${YELLOW}gapk-start.sh absent - pas de bridge RTP${NC}"
    fi

    # Sortie vers le pulse de l'hote si le relai TCP est ouvert (HOST_AUDIO_RELAY
    # est positionne par start.sh quand le relai a ete active : tcp:<gw>:4713).
    local relay="${HOST_AUDIO_RELAY:-}"
    if [ -n "$relay" ] && pactl --server="$relay" info >/dev/null 2>&1; then
        pkill -f "paplay --server=${relay}" 2>/dev/null || true
        [ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
        setsid sh -c '
          while true; do
            parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
              | paplay --server='"${relay}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
            sleep 1
          done' >/var/log/osmocom/host-audio.log 2>&1 &
        echo $! > /run/host-audio.pid
        echo -e "  ${GREEN}✓ pont audio parec|paplay → hote (${relay})${NC}"
    else
        # Fallback natif sans relai : loopback vers le sink par defaut (carte).
        if ! pactl list short modules 2>/dev/null | grep -q 'source=gsm_audio.monitor'; then
            pactl load-module module-loopback source=gsm_audio.monitor latency_msec=20 >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓ loopback gsm_audio → sink par defaut (carte)${NC}" \
                || echo -e "  ${YELLOW}loopback non charge (pas de sortie son ?)${NC}"
        else
            echo -e "  ${GREEN}✓ loopback gsm_audio deja actif${NC}"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

# RUN_NO_PROCESS=1 : on prepare tmux + configs + core Osmocom (osmo-start :
# STP/HLR/MGW/MSC/BSC... → le HLR est up et peut etre alimente par start.sh),
# mais on NE lance PAS les process radio/mobile/asterisk/smsc dans le tmux.
[ "$RUN_NO_PROCESS" = "1" ] && echo -e "${YELLOW}=== RUN_NO_PROCESS=1 : core seul, PHY/mobile/asterisk/smsc NON lances ===${NC}"

echo -e "${GREEN}=== [1/10] tmux ===${NC}"
init_tmux
echo ""

echo -e "${GREEN}=== [2/10] Config MS ===${NC}"
generate_ms_configs
echo ""

echo -e "${GREEN}=== [2b] TRX ===${NC}"
if [ "$PHY_MODE" = "virtphy" ]; then
    inject_extra_trx_virtual "$N_TRX"
else
    inject_extra_trx "$N_TRX"
fi

echo -e "${GREEN}=== [2c] Handover ===${NC}"
inject_handover
echo ""

# ── [2d] Audio PulseAudio - AVANT le coeur, volontairement ────────────────────
# [2026-08-12] Ce bloc n'existait qu'en [6b], donc APRES osmo-start.sh. Or
# osmo-start.sh fait `exit 1` si le HLR ne monte pas, et avec `set -euo pipefail`
# (ligne 7) run.sh meurt la : pulse-gsm-setup.sh - le seul endroit qui cree le
# null-sink gsm_mic - n'est alors JAMAIS execute. La capture gsm_in
# (= gsm_mic.monitor) ne s'ouvre plus, gapk_io abandonne les DEUX sens, et tout
# appel est muet, echo-test 600 compris. C'est exactement le "ca marche sur un
# PC et pas sur l'autre" : ca depend de si le HLR est monte du premier coup.
# L'audio n'a AUCUNE dependance sur le coeur - on le monte donc en premier.
# L'appel en [6b] reste en place (idempotent) pour les relances partielles.
echo -e "${GREEN}=== [2d] Audio PulseAudio (sinks) ===${NC}"
setup_pulse_sinks 3
echo ""

echo -e "${GREEN}=== [3/10] Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh

# Mode no-process : le core tourne (HLR alimentable par start.sh), on
# s'arrete ici sans lancer PHY/mobile/asterisk/smsc dans le tmux. On
# configure tout de meme PulseAudio (sink gsm_audio) car le pipeline lance
# ensuite (ex. ${OQC_ROOT}/run.sh) en a besoin pour l'audio gapk.
if [ "$RUN_NO_PROCESS" = "1" ]; then
    echo ""
    echo -e "${GREEN}=== Audio PulseAudio (no-process) ===${NC}"
    setup_pulse_sinks
    # Bridge audio AUSSI en no-process : sans ca, gapk n'est jamais lance et le
    # pipeline qemu n'a aucun audio (bug "pas de son en qemu").
    echo -e "${GREEN}=== Bridge audio (no-process / qemu) ===${NC}"
    audio_bridge
    echo ""
    echo -e "${GREEN}Core Osmocom pret (no-process). PHY/mobile/asterisk/smsc NON lances.${NC}"
    echo -e "  tmux : ${CYAN}tmux -S ${TMUX_SOCKET} attach -t ${SESSION}${NC}"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHY : fake_trx (TRXD) OU virtphy (multicast)
# ══════════════════════════════════════════════════════════════════════════════

if [ "$PHY_MODE" = "virtphy" ]; then
    # ─────────────────────────────────────────────────────────────────────────
    # MODE VIRTPHY : osmo-bts-virtual → virtphy → mobile
    #
    #   mobile ↔ virtphy ↔ (multicast UDP) ↔ osmo-bts-virtual ↔ BSC
    #
    # Pas de fake_trx, pas de trxcon.
    # ─────────────────────────────────────────────────────────────────────────

    echo -e "${GREEN}=== [4/10] BTS Virtual ===${NC}"
    # Arreter osmo-bts-trx s'il a ete demarre par systemd
    systemctl stop osmo-bts-trx 2>/dev/null || true
    systemctl disable osmo-bts-trx 2>/dev/null || true

    run_in_tmux "bts" "osmo-bts-virtual -c /etc/osmocom/osmo-bts-virtual.cfg"
    wait_port 127.0.0.1 4241 "BTS-virtual" 30 || true

    echo -e "${GREEN}=== [5/10] virtphy (${N_MS} instances) ===${NC}"
    for ms in $(seq 1 "$N_MS"); do
        local_l2=$(l2_sock "$ms")
        cmd="virtphy -s ${local_l2}"
        pw=$(( (ms-1)/8 )); pl=$(( (ms-1)%8 ))
        win="virtphy${pw}"
        if [ "$pl" -eq 0 ]; then
            run_in_tmux "$win" "$cmd"
        elif [ "$TMUX_OK" = true ]; then
            tmux -S "$TMUX_SOCKET" split-window -v -t "${SESSION}:${win}" 2>/dev/null || true
            tmux -S "$TMUX_SOCKET" select-layout -t "${SESSION}:${win}" even-vertical 2>/dev/null || true
            tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${win}.${pl}" "$cmd" C-m 2>/dev/null || true
        else
            bash -c "$cmd" >"/var/log/osmocom/virtphy_ms${ms}.log" 2>&1 &
        fi
        [ $((ms % 8)) -eq 1 ] || [ "$ms" -eq "$N_MS" ] && echo -e "  ${CYAN}[ue${ms}]${NC} l2=${local_l2}"
    done
    # Laisser virtphy creer les sockets avant de lancer mobile
    sleep 2

    # Pas de step 6 (trxcon) en mode virtphy

else
    # ─────────────────────────────────────────────────────────────────────────
    # MODE FAKETRX : fake_trx → trxcon → mobile
    #
    #   mobile ↔ trxcon ↔ (TRXD UDP) ↔ fake_trx ↔ osmo-bts-trx ↔ BSC
    # ─────────────────────────────────────────────────────────────────────────

    echo -e "${GREEN}=== [3b/10] osmo-bts-trx ===${NC}"
    # BTS lance AVANT fake_trx : il poll le transceiver (POWERON) et se connecte
    # des que fake_trx repond. On stoppe une eventuelle instance systemd pour
    # eviter un double-BTS.
    systemctl stop osmo-bts-trx 2>/dev/null || true
    run_in_tmux "bts" "osmo-bts-trx -c /etc/osmocom/osmo-bts-trx.cfg"

    echo -e "${GREEN}=== [4/10] FakeTRX ===${NC}"
    FAKETRX_CMD="python3 ${FAKETRX_PY} -b 127.0.0.1 -R 127.0.0.1 -r 127.0.0.1 -P ${BTS_PORT_BASE} -p ${BB_PORT_BASE}"
    for t in $(seq 1 $((N_TRX-1))); do
        FAKETRX_CMD+=" --trx bts${t}@127.0.0.1:${BTS_PORT_BASE}/${t}"
    done
    for ms in $(seq 2 "$N_MS"); do
        local_g=$(( (ms-1)/8 + 1 ))
        FAKETRX_CMD+=" --trx ue${ms}@127.0.0.${local_g}:$(bb_port $ms)"
    done
    run_in_tmux "faketrx" "$FAKETRX_CMD"
    wait_udp "$BTS_PORT_BASE" "fake_trx" 30 || true

    echo -e "${GREEN}=== [6/10] trxcon ===${NC}"
    for ms in $(seq 1 "$N_MS"); do
        local_l2=$(l2_sock "$ms"); local_port=$(bb_port "$ms")
        pw=$(( (ms-1)/8 )); pl=$(( (ms-1)%8 )); ug=$((pw+1)); gip="127.0.0.${ug}"
        cmd="trxcon ue${ms} -C 1 -i 127.0.0.1 -b ${gip} -p ${local_port} -s ${local_l2} -F 100"
        win="trxcon${pw}"
        if [ "$pl" -eq 0 ]; then
            run_in_tmux "$win" "$cmd"
        elif [ "$TMUX_OK" = true ]; then
            tmux -S "$TMUX_SOCKET" split-window -v -t "${SESSION}:${win}" 2>/dev/null || true
            tmux -S "$TMUX_SOCKET" select-layout -t "${SESSION}:${win}" even-vertical 2>/dev/null || true
            tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${win}.${pl}" "$cmd" C-m 2>/dev/null || true
        else
            bash -c "$cmd" >"/var/log/osmocom/trxcon_ue${ms}.log" 2>&1 &
        fi
        [ $((ms % 8)) -eq 1 ] || [ "$ms" -eq "$N_MS" ] && echo -e "  ${CYAN}[ue${ms}]${NC} ${gip}:${local_port}"
    done
fi

echo -e "${GREEN}=== [6b/10] Audio PulseAudio ===${NC}"
setup_pulse_sinks   # deja fait en [2d] - idempotent, filet pour relance partielle
echo ""

# ── [6c] Bridge audio : gapk (RTP → gsm_audio) + sortie vers l'hote ───────────
echo -e "${GREEN}=== [6c/10] Bridge audio (gapk + sortie hote) ===${NC}"
audio_bridge
echo ""

echo -e "${GREEN}=== [7/10] Mobile ===${NC}"
if [ "$MOBILE_MODE" = "split" ]; then
    for ms in $(seq 1 "$N_MS"); do
        run_in_tmux "ue${ms}" "mobile -c /root/.osmocom/bb/mobile_ms${ms}.cfg"
    done
else
    for g in $(seq 1 "$N_GROUPS"); do
        if [ "$g" -gt 1 ]; then
            prev_ip="127.0.0.$((g-1))"
            echo -ne "  ${CYAN}Attente Grp$((g-1)) (${prev_ip}:4247)${NC}"
            r=0
            while ! bash -c "echo >/dev/tcp/${prev_ip}/4247" 2>/dev/null; do
                sleep 2; echo -n "."; r=$((r+1)); [ $r -ge 30 ] && break
            done
            echo -e " ${GREEN}OK${NC}"; sleep 3
        fi
        run_in_tmux "ue_g${g}" "mobile -c /root/.osmocom/bb/mobile_group${g}.cfg"
        echo -e "  ${GREEN}Groupe ${g} demarre${NC}"
    done
fi

echo -e "${GREEN}=== [9/10] Asterisk ===${NC}"
run_in_tmux "asterisk" "pkill asterisk 2>/dev/null; sleep 2; pkill -9 asterisk 2>/dev/null; sleep 1; rm -f /var/lib/asterisk/astdb.sqlite3; asterisk -cvvv"

echo -e "${GREEN}=== [10/10] SMSC ===${NC}"
if [ -f /etc/osmocom/smsc-start.sh ]; then
    run_in_tmux "smsc" "/etc/osmocom/smsc-start.sh"
else
    run_in_tmux "smsc" "echo 'SMSC non disponible'"
fi

# ── Nettoyage : supprimer la fenetre main inutile ─────────────────────────────
if [ "$TMUX_OK" = true ]; then
    sleep 1
    tmux -S "$TMUX_SOCKET" kill-window -t "${SESSION}:main" 2>/dev/null || true
fi

# ── Resume ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Op${OPERATOR_ID} - ${N_MS} MS - ${MOBILE_MODE} - ${PHY_MODE} - ${N_TRX} TRX     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
if [ "$PHY_MODE" = "virtphy" ]; then
    echo -e "  ${CYAN}PHY       :${NC} virtphy (osmo-bts-virtual, multicast)"
    echo -e "  ${CYAN}tmux      :${NC} bts  virtphy*  ue*  asterisk  smsc"
else
    echo -e "  ${CYAN}PHY       :${NC} faketrx (osmo-bts-trx, TRXD)"
    echo -e "  ${CYAN}BB ports  :${NC} $(bb_port 1) .. $(bb_port $N_MS)"
    echo -e "  ${CYAN}tmux      :${NC} faketrx  trxcon*  ue*  asterisk  smsc"
fi
if [ "$TMUX_OK" = true ]; then
    echo -e "  ${CYAN}Attach    :${NC} tmux -S ${TMUX_SOCKET} attach -t ${SESSION}"
    tmux -S "$TMUX_SOCKET" select-window -t "${SESSION}:ue_g1" 2>/dev/null \
        || tmux -S "$TMUX_SOCKET" select-window -t "${SESSION}:ue1" 2>/dev/null || true
fi
echo ""
echo -e "${GREEN}run.sh termine${NC}"
