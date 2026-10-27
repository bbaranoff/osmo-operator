#!/bin/bash
# =============================================================================
# scripts/egprs-dsp.sh - EGPRS workflow of the bench, on the DSP chain (TI ROM).
# =============================================================================
#
# What this workflow brings up, in order, checking each step:
#
#   1. preflight    binaries, DSP ROM (7 files), c54x_exe, osmocom-bb modem;
#                   and the DSP gate: does the Calypso layer1 firmware handle
#                   PDCH (L1CTL_GPRS_*)? If not, the GPRS modem runs on a
#                   virtual layer 1 (virtphy), in the same PLMN/LAC/RA as the
#                   DSP mobile, which camps on BTS 0.
#   2. configs      /etc/osmocom: the virtual EGPRS BTS 2 in osmo-bsc.cfg
#                   (fragment configs/gprs/osmo-bsc-bts2-egprs.frag, reapplied
#                   after each --regen), osmo-bts-virtual-gprs.cfg,
#                   osmo-pcu-gprs.cfg, modem-gprs.cfg.
#   3. banc         osmo-banc.service (start-native.sh --dsp: core, BTS 0 on
#                   the C54x + TI ROM, SGSN/GGSN/PCU of BTS 0).
#   4. abonne       the modem IMSI in the HLR (comp128v1), idempotent.
#   5. cellule      osmo-bts-virtual (BTS 2, Um multicast on lo) + osmo-pcu
#                   (socket /tmp/pcu_bts3) as transient systemd units; waits
#                   for the OML of BTS 2 at the BSC and the NS-VC of the PCU.
#   6. modem        virtphy (-> /tmp/modem_l2) then osmocom-bb `modem`: GPRS
#                   attach (GMM) + PDP context (SM), tun in the msgprs netns;
#                   checked at the SGSN (mm-context, pdp-context) and with a
#                   ping to apn0 from the netns.
#
#   EGPRS_L1=dsp: no virtphy; the modem is started by c54x_exe/run.sh instead
#   of `mobile` (MOBILE= / MOBILE_CFG= in /etc/default/osmo-banc) on
#   /tmp/osmocom_l2. The script sets these two variables and says so; it does
#   not force a path the firmware does not have.
#
# Usage: egprs-dsp.sh [start|stop|status|check] [--l1 auto|virtphy|dsp]
#                     [--no-banc] [--regen-gprs] [--all]
#   start        bring everything up (default)  stop   tear down cell + modem
#   status       state + SGSN                   check  preflight only, starts nothing
#   --no-banc    leave osmo-banc alone          --all  (stop) also stop osmo-banc
#   --regen-gprs rewrite the 4 GPRS configs from configs/gprs even if present
#
# Persistent: services/osmo-egprs-dsp.service (Requires=osmo-banc) triggers this
# script at boot; OSMO_BANC_ARGS="--dsp" in /etc/default/osmo-banc.
# Journal: journalctl -u osmo-egprs-dsp, -u osmo-modem-gprs, -u osmo-pcu-gprs,
#          -u osmo-bts-virtual-gprs, -u osmo-virtphy-gprs.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_SRC="$HERE/configs/gprs"
ETC="${OSMOCOM_CFG:-/etc/osmocom}"
BB="${OSMOCOM_BB:-/opt/GSM/osmocom-bb}"
C54X="${C54X_DIR:-/opt/GSM/c54x_exe}"
ROM_DIR="${OSMO_DSP_ROM_DIR:-/opt/GSM}"
L1="${EGPRS_L1:-auto}"              # auto | virtphy | dsp
WITH_BANC="${EGPRS_BANC:-1}"
NETNS="${EGPRS_NETNS:-msgprs}"
REGEN_GPRS=0
STOP_ALL=0

# The modem subscriber: the 3rd of the plan (01-abonnes-hlr: byte 15 = n, 16 = op).
IMSI="${EGPRS_IMSI:-001010001000001}"
KI="${EGPRS_KI:-00 11 22 33 44 55 66 77 88 99 aa bb cc dd 01 01}"
MSISDN="${EGPRS_MSISDN:-100101}"

SOCK_VIRT=/tmp/modem_l2
SOCK_DSP=/tmp/osmocom_l2
PCU_SOCK=/tmp/pcu_bts3

VTY_BSC=4242; VTY_HLR=4258; VTY_SGSN=4245
PCU_VTY_IP=127.0.0.2; VTY_PCU=4240

U_BTS=osmo-bts-virtual-gprs; U_PCU=osmo-pcu-gprs; U_VPHY=osmo-virtphy-gprs; U_MODEM=osmo-modem-gprs
UNITS=("$U_MODEM" "$U_VPHY" "$U_PCU" "$U_BTS")

# ── display ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_WA=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_Z=$'\033[0m'
else C_OK=; C_KO=; C_WA=; C_DIM=; C_B=; C_Z=; fi
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_Z" "$*"; }
ko()   { printf '  %s[ KO ]%s %s\n' "$C_KO" "$C_Z" "$*"; }
warn() { printf '  %s[ !! ]%s %s\n' "$C_WA" "$C_Z" "$*"; }
titre(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_Z"; }
declare -A BILAN=()
bilan() { BILAN["$1"]="$2"; }

# ── tools ────────────────────────────────────────────────────────────────────
# The Osmocom VTY reads line by line: a pause between commands, otherwise it
# skips some (same as start-interstp.sh --status).
vty() {   # vty HOST PORT cmd...
    local host="$1" port="$2"; shift 2
    { sleep 0.4; printf 'enable\n'; local c; for c in "$@"; do sleep 0.3; printf '%s\n' "$c"; done
      sleep 0.8; printf 'exit\n'; sleep 0.2; } | timeout 10 nc -q1 "$host" "$port" 2>/dev/null | tr -d '\r'
}
port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/${2:-127.0.0.1}/$1" 2>/dev/null; }
wait_until() {   # wait_until SECONDS "label" cmd...
    local to="$1" what="$2"; shift 2; local t=0
    while ! "$@" >/dev/null 2>&1; do
        [ "$t" -ge "$to" ] && { ko "$what : toujours rien apres ${to}s"; return 1; }
        sleep 2; t=$((t+2))
    done
    ok "$what (${t}s)"
}
unit_active() { systemctl is-active --quiet "$1"; }
unit_run() {   # unit_run NAME cmd...: transient unit, visible to systemctl/journalctl
    local u="$1"; shift
    if unit_active "$u"; then say "$u deja actif"; return 0; fi
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    systemd-run --quiet --unit="$u" --collect -p KillMode=control-group \
        -p SyslogIdentifier="$u" "$@" || { ko "systemd-run $u a echoue"; return 1; }
    say "$u lance : $*"
}
unit_stop() { unit_active "$1" && systemctl stop "$1" 2>/dev/null; systemctl reset-failed "$1" >/dev/null 2>&1 || true; }

# ── 1. preflight ─────────────────────────────────────────────────────────────
DSP_GPRS=0
MODEM_BIN=""
etape_preflight() {
    titre "1. preflight"
    local rc=0 b
    for b in osmo-bts-virtual osmo-pcu virtphy nc systemd-run; do
        command -v "$b" >/dev/null 2>&1 && ok "$b : $(command -v "$b")" || { ko "$b introuvable"; rc=1; }
    done
    # osmocom-bb modem: from the PATH, otherwise the one of the tree; installed
    # (persistently) if it is only in the tree.
    MODEM_BIN="$(command -v modem 2>/dev/null || true)"
    if [ -z "$MODEM_BIN" ] && [ -x "$BB/src/host/layer23/src/modem/modem" ]; then
        install -m755 "$BB/src/host/layer23/src/modem/modem" /usr/local/bin/modem 2>/dev/null \
            && MODEM_BIN=/usr/local/bin/modem && say "modem installe dans /usr/local/bin (depuis $BB)"
    fi
    [ -n "$MODEM_BIN" ] && ok "modem : $MODEM_BIN" || { ko "modem (osmocom-bb layer23) absent : make -C $BB/src/host/layer23"; rc=1; }

    # The DSP chain: TI ROM + c54x_exe (the default bench of start-native.sh)
    local n=0 r
    for r in PROM0 PROM1 PROM2 PROM3 DROM PDROM Registers; do [ -f "$ROM_DIR/calypso_dsp.$r.bin" ] && n=$((n+1)); done
    [ "$n" -eq 7 ] && ok "ROM DSP TI : $n/7 dans $ROM_DIR" || warn "ROM DSP : $n/7 dans $ROM_DIR - --dsp ne demarrera pas (c54x_exe/rom/fetch-rom.sh)"
    [ -x "$C54X/c54x_exe" ] && ok "c54x_exe : $C54X/c54x_exe" || warn "c54x_exe non compile : make -C $C54X"

    # The DSP gate: does the layer1 firmware (the one running on the emulated
    # ARM, in front of the ROM) handle the L1CTL GPRS primitives? Without them
    # no PDCH can be opened on this chain, whatever the ROM can do.
    if grep -q 'L1CTL_GPRS' "$BB/src/target/firmware/layer1/l23_api.c" 2>/dev/null; then
        DSP_GPRS=1; ok "porte DSP : le firmware layer1 traite L1CTL_GPRS_* -> PDCH possible sur le C54x"
    else
        DSP_GPRS=0; warn "porte DSP fermee : pas de L1CTL_GPRS_* dans firmware/layer1/l23_api.c -> le modem ira sur virtphy"
    fi
    grep -qi 'gprs' "$C54X"/src/*.c 2>/dev/null && ok "c54x_exe : du code GPRS present" \
        || say "${C_DIM}c54x_exe : aucune tache GPRS cote pont (src/*.c) - a faire quand la porte s ouvrira${C_Z}"
    say "${C_DIM}rappel : la ROM Calypso module en GMSK seulement (GPRS CS-1..4) ; la cellule annonce EGPRS,"
    say "le 8-PSK (MCS-5..9) restera au modem virtphy, jamais au C54x.${C_Z}"

    case "$L1" in
        auto) [ "$DSP_GPRS" = 1 ] && L1=dsp || L1=virtphy ;;
        dsp|virtphy) ;;
        *) ko "--l1 $L1 inconnu (auto|virtphy|dsp)"; rc=1 ;;
    esac
    say "couche 1 du modem : $C_B$L1$C_Z"
    [ "$rc" -eq 0 ] && bilan preflight OK || bilan preflight KO
    return $rc
}

# ── 2. configs ───────────────────────────────────────────────────────────────
BSC_CHANGE=0
pose_cfg() {   # pose_cfg SRC DST [sed-expr]
    local src="$CFG_SRC/$1" dst="$ETC/$2"
    [ -r "$src" ] || { ko "gabarit absent : $src"; return 1; }
    if [ -f "$dst" ] && [ "$REGEN_GPRS" = 0 ]; then say "$dst present (--regen-gprs pour le reposer)"; return 0; fi
    sed -e "${3:-}" "$src" > "$dst" && ok "$dst pose"
}
etape_configs() {
    titre "2. configs dans $ETC"
    local rc=0 sgsn_ip gsmtap_ip
    sgsn_ip="$(awk '$1=="listen"{print $2; exit}' "$ETC/osmo-sgsn.cfg" 2>/dev/null)"
    [ -n "$sgsn_ip" ] || { warn "pas de « listen » NS dans osmo-sgsn.cfg - 127.0.0.1"; sgsn_ip=127.0.0.1; }
    gsmtap_ip="$(awk '$1=="log" && $2=="gsmtap"{print $3; exit}' "$ETC/osmo-pcu.cfg" 2>/dev/null)"
    [ -n "$gsmtap_ip" ] || gsmtap_ip=127.0.0.1
    pose_cfg osmo-bts-virtual-gprs.cfg osmo-bts-virtual-gprs.cfg || rc=1
    pose_cfg osmo-pcu-gprs.cfg        osmo-pcu-gprs.cfg "s|__GSMTAP_IP__|$gsmtap_ip|g" || rc=1
    pose_cfg modem-gprs.cfg           modem-gprs.cfg || rc=1
    # DSP variant of the modem: same subscriber, L1CTL socket of the C54x
    # (MOBILE_CFG= in /etc/default/osmo-banc).
    pose_cfg modem-gprs.cfg modem-gprs-dsp.cfg "s|layer2-socket .*|layer2-socket $SOCK_DSP|" || rc=1

    # BTS 2 in osmo-bsc.cfg: a « bts 2 » block inserted before « msc 0 ».
    # --regen regenerates this file from configs/osmo-bsc.cfg (2 BTS): checked
    # at each start, re-inserted when needed.
    local bsc="$ETC/osmo-bsc.cfg"
    if [ ! -f "$bsc" ]; then ko "$bsc absent (start-native.sh --regen)"; rc=1
    elif grep -q '^ bts 2$' "$bsc"; then ok "BTS 2 EGPRS deja dans osmo-bsc.cfg"
    elif ! grep -q '^msc 0$' "$bsc"; then ko "pas de « msc 0 » dans $bsc : je ne sais pas ou inserer la BTS 2"; rc=1
    else
        cp -a "$bsc" "$bsc.avant-bts2-egprs"
        sed "s|__SGSN_IP__|$sgsn_ip|g" "$CFG_SRC/osmo-bsc-bts2-egprs.frag" > "$bsc.frag.$$"
        # Insert before « msc 0 », without touching the rest of the file.
        awk -v frag="$bsc.frag.$$" '
            /^msc 0$/ && !done { while ((getline l < frag) > 0) print l; done=1 }
            { print }' "$bsc.avant-bts2-egprs" > "$bsc"
        rm -f "$bsc.frag.$$"
        grep -q '^ bts 2$' "$bsc" && { ok "BTS 2 EGPRS inseree dans osmo-bsc.cfg (sauvegarde : $bsc.avant-bts2-egprs)"; BSC_CHANGE=1; } \
            || { ko "insertion de la BTS 2 ratee"; cp -a "$bsc.avant-bts2-egprs" "$bsc"; rc=1; }
    fi
    [ "$rc" -eq 0 ] && bilan configs OK || bilan configs KO
    return $rc
}

# ── 3. bench (osmo-banc.service, DSP chain) ──────────────────────────────────
etape_banc() {
    titre "3. banc DSP (osmo-banc.service)"
    if [ "$WITH_BANC" != 1 ]; then say "--no-banc : on suppose le banc deja monte"
    elif unit_active osmo-banc; then
        ok "osmo-banc actif"
        if [ "$BSC_CHANGE" = 1 ] && unit_active osmo-bsc; then
            warn "la BTS 2 vient d etre ajoutee : osmo-bsc relit sa config -> restart (le mobile DSP recampera)"
            systemctl restart osmo-bsc
        fi
    else
        say "systemctl start osmo-banc (start-native.sh --no-attach, DSP par defaut) - plusieurs minutes"
        systemctl start osmo-banc || { ko "osmo-banc : journalctl -u osmo-banc -n 50"; bilan banc KO; return 1; }
    fi
    wait_until 120 "VTY OsmoBSC :$VTY_BSC"  port_open "$VTY_BSC"  || { bilan banc KO; return 1; }
    wait_until 60  "VTY OsmoHLR :$VTY_HLR"  port_open "$VTY_HLR"  || { bilan banc KO; return 1; }
    wait_until 60  "VTY OsmoSGSN :$VTY_SGSN" port_open "$VTY_SGSN" || { bilan banc KO; return 1; }
    local mode; mode="$(vty 127.0.0.1 $VTY_BSC "show running-config" | awk '/^ bts 0$/{b=1} b && /gprs mode/{print $3; exit}')"
    [ "$mode" = egprs ] && ok "BTS 0 (C54x) : gprs mode egprs" || warn "BTS 0 : gprs mode ${mode:-?}"
    bilan banc OK
}

# ── 4. the modem subscriber in the HLR ───────────────────────────────────────
etape_abonne() {
    titre "4. abonne $IMSI (HLR :$VTY_HLR)"
    if vty 127.0.0.1 $VTY_HLR "subscriber imsi $IMSI show" | grep -q "IMSI: *$IMSI"; then
        ok "deja present"
    else
        vty 127.0.0.1 $VTY_HLR "subscriber imsi $IMSI create" \
            "subscriber imsi $IMSI update msisdn $MSISDN" \
            "subscriber imsi $IMSI update aud2g comp128v1 ki $(echo "$KI" | tr -d ' ')" >/dev/null
        vty 127.0.0.1 $VTY_HLR "subscriber imsi $IMSI show" | grep -q "IMSI: *$IMSI" \
            && ok "cree (MSISDN $MSISDN, comp128v1)" || { ko "creation ratee : telnet 127.0.0.1 $VTY_HLR"; bilan abonne KO; return 1; }
    fi
    bilan abonne OK
}

# ── 5. the packet cell: virtual BTS 2 + its PCU ──────────────────────────────
etape_cellule() {
    titre "5. cellule EGPRS virtuelle (BTS 2, PCU $PCU_SOCK)"
    rm -f "$PCU_SOCK" 2>/dev/null
    unit_run "$U_BTS" osmo-bts-virtual -c "$ETC/osmo-bts-virtual-gprs.cfg" || { bilan cellule KO; return 1; }
    bts2_oml() { vty 127.0.0.1 $VTY_BSC "show bts 2" | grep -i 'OML' | grep -viE 'disconnected|not connected' | grep -qi 'connected'; }
    wait_until 60 "OML de la BTS 2 au BSC" bts2_oml || { warn "journalctl -u $U_BTS -n 30 ; show bts 2 sur :$VTY_BSC"; }
    unit_run "$U_PCU" osmo-pcu -c "$ETC/osmo-pcu-gprs.cfg" || { bilan cellule KO; return 1; }
    wait_until 30 "socket PCU $PCU_SOCK" test -S "$PCU_SOCK" || warn "la BTS 2 n a pas ouvert $PCU_SOCK"
    pcu_ns() { vty $PCU_VTY_IP $VTY_PCU "show ns" | grep -qiE 'ALIVE|UNBLOCKED'; }
    wait_until 60 "NS-VC PCU <-> SGSN (nsei 11)" pcu_ns || warn "NS : show ns sur $PCU_VTY_IP:$VTY_PCU ; journalctl -u $U_PCU"
    bilan cellule OK
}

# ── 6. the GPRS modem ────────────────────────────────────────────────────────
etape_modem() {
    titre "6. modem GPRS (couche 1 : $L1)"
    ip netns list 2>/dev/null | grep -qw "$NETNS" || { ip netns add "$NETNS" && say "netns $NETNS cree"; }
    if [ "$L1" = dsp ]; then
        # QEMU + TI ROM: the modem takes the place of `mobile` on the same L1CTL
        # socket (/tmp/osmocom_l2, osmocon of the DSP bench). MOBILE=/MOBILE_CFG=
        # in /etc/default/osmo-banc is not used: start-native.sh rewrites the
        # file named by MOBILE_CFG with its `mobile` template (gps device...),
        # which `modem` rejects. The DSP bench mobile is therefore stopped and
        # modem started here, as a transient unit.
        local cfg="$ETC/modem-gprs-dsp.cfg"
        sed "s|layer2-socket .*|layer2-socket $SOCK_DSP|" "$CFG_SRC/modem-gprs.cfg" > "$cfg"
        # The layer1 firmware with PDCH (L1CTL_GPRS_*) and the final ROM bursts
        # (UL_RAW=1, pont/dsp/uplink.py): set for the next start of the bench.
        local fw=/opt/GSM/firmware/board/compal_e88/layer1.highram.gprs.elf df=/etc/default/osmo-banc
        if [ -r "$fw" ]; then
            touch "$df"
            grep -q "^FIRMWARE_ELF=$fw" "$df" || { sed -i '/^FIRMWARE_ELF=/d;/^FIRMWARE_BIN=/d' "$df"; printf 'FIRMWARE_ELF=%s\nFIRMWARE_BIN=%s\n' "$fw" "${fw%.elf}.bin" >> "$df"; warn "firmware GPRS pose dans $df : « systemctl restart osmo-banc » pour le charger"; }
            grep -q '^UL_RAW=1' "$df" || { sed -i '/^UL_RAW=/d' "$df"; printf 'UL_RAW=1\n' >> "$df"; }
            tr -d '\0' < "/proc/$(pgrep -f 'qemu-system-arm.*calypso' | head -1)/cmdline" 2>/dev/null | grep -q "$fw" \
                && ok "QEMU tourne avec le firmware GPRS" || warn "QEMU ne tourne pas (encore) avec le firmware GPRS : restart osmo-banc"
        else
            warn "firmware GPRS absent : $fw (make board/compal_e88/layer1.highram.elf dans osmocom-bb/src/target/firmware)"
        fi
        [ -S "$SOCK_DSP" ] || { ko "socket L1CTL $SOCK_DSP absente : le banc DSP (osmocon) ne tourne pas"; bilan modem KO; return 1; }
        # The bench must be in DSP mode: without c54x_exe the layer 1 is gr-gsm
        # (OSMO_BANC_ARGS=--grgsm set by the desktop launcher until reboot) and
        # there is no PDCH there.
        if ! pgrep -f 'c54x_exe --arm' >/dev/null; then
            ko "le banc tourne en gr-gsm (pas de c54x_exe) : $(systemctl show-environment 2>/dev/null | grep OSMO_BANC_ARGS || echo 'OSMO_BANC_ARGS non pose')"
            say "pour le DSP : systemctl set-environment OSMO_BANC_ARGS=--dsp && systemctl restart osmo-banc"
            bilan modem KO; return 1
        fi
        # Any `mobile` connected to the same L1CTL socket (mobile_pont of the DSP
        # bench, mobile_group1 of the fork...) would fight with the modem: each
        # resets the layer 1 (RESET FULL + PM_REQ versus RESET FULL + FBSB_REQ).
        local p c n=0
        for p in $(pgrep -x mobile); do
            c="$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | sed -n 's/.* -c \([^ ]*\).*/\1/p')"
            [ -n "$c" ] && grep -q "layer2-socket $SOCK_DSP\$" "$c" 2>/dev/null && kill "$p" 2>/dev/null && n=$((n+1)) && say "mobile $p ($c) arrete : il occupait $SOCK_DSP"
        done
        [ "$n" -gt 0 ] && sleep 1
        unit_run "$U_MODEM" "$MODEM_BIN" -c "$cfg" || { bilan modem KO; return 1; }
        [ "$DSP_GPRS" = 1 ] || warn "porte DSP fermee : le modem campera, mais l attach echouera tant que le firmware layer1 ne traite pas L1CTL_GPRS_* (voir preflight)"
    else
        rm -f "$SOCK_VIRT"
        unit_run "$U_VPHY" virtphy -s "$SOCK_VIRT" -D lo || { bilan modem KO; return 1; }
        wait_until 20 "socket L1CTL $SOCK_VIRT" test -S "$SOCK_VIRT" || { bilan modem KO; return 1; }
        unit_run "$U_MODEM" "$MODEM_BIN" -c "$ETC/modem-gprs.cfg" || { bilan modem KO; return 1; }
    fi
    # Attach and PDP are read from the modem: « show mm-context » of the SGSN
    # does not show « GMM_REGISTERED ». Attach = « Attach success » from the
    # modem; PDP = tun_modem addressed in the netns, set by the modem at the
    # Activate PDP Context Accept.
    local t_debut; t_debut="$(date '+%Y-%m-%d %H:%M:%S')"
    attache() { journalctl -u "$U_MODEM" --since "$t_debut" -o cat 2>/dev/null | grep -q 'Attach success'; }
    wait_until 180 "GPRS attach de $IMSI (Attach success, P-TMSI attribue)" attache || {
        warn "journalctl -u $U_MODEM -n 40 ; show mm-context imsi $IMSI sur :$VTY_SGSN"; bilan modem KO; return 1; }
    pdp() { ip netns exec "$NETNS" ip -4 -o addr show dev tun_modem 2>/dev/null | grep -q 'inet '; }
    wait_until 90 "contexte PDP : adresse sur tun_modem (netns $NETNS)" pdp || { warn "pas de PDP : show pdp-context all ; journalctl -u $U_MODEM"; bilan modem KO; return 1; }
    ok "adresse du modem : $(ip netns exec "$NETNS" ip -4 -o addr show dev tun_modem | awk '{print $4}')"
    local apn_ip; apn_ip="$(ip -4 -o addr show apn0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    if [ -n "$apn_ip" ]; then
        ip netns exec "$NETNS" ip route replace default dev tun_modem 2>/dev/null
        if ip netns exec "$NETNS" ping -c4 -W8 "$apn_ip" >/dev/null 2>&1; then ok "ping $apn_ip (apn0) depuis le netns $NETNS : la donnee passe"
        else warn "ping $apn_ip depuis le netns $NETNS rate (ip netns exec $NETNS ip route)"; fi
    fi
    bilan modem OK
}

# ── actions ──────────────────────────────────────────────────────────────────
do_stop() {
    titre "arret"
    local u; for u in "${UNITS[@]}"; do unit_stop "$u" && say "$u arrete"; done
    rm -f "$SOCK_VIRT" "$PCU_SOCK"
    [ "$STOP_ALL" = 1 ] && { systemctl stop osmo-banc; say "osmo-banc arrete"; }
    return 0
}
do_status() {
    titre "etat"
    local u; for u in osmo-banc "${UNITS[@]}"; do printf '  %-24s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
    port_open "$VTY_SGSN" && { say "SGSN mm-context :"; vty 127.0.0.1 $VTY_SGSN "show mm-context all" | grep -E 'IMSI|MM state|Routing|PDP' | sed 's/^/    /'
        say "SGSN pdp-context :"; vty 127.0.0.1 $VTY_SGSN "show pdp-context all" | grep -E 'IMSI|APN|Address|PDP' | sed 's/^/    /'; }
    port_open "$VTY_PCU" "$PCU_VTY_IP" && { say "PCU gprs (tbf) :"; vty $PCU_VTY_IP $VTY_PCU "show tbf all" | grep -vE '^(OsmoPCU|enable|exit|$)' | sed 's/^/    /' | head -12; }
    return 0
}
do_start() {
    etape_preflight || return 1
    etape_configs   || return 1
    etape_banc      || return 1
    etape_abonne    || true
    # The virtual cell only makes sense for a modem on virtphy: in dsp mode
    # (QEMU + TI ROM) the modem camps on BTS 0 of the C54x, like `mobile`.
    if [ "$L1" = virtphy ] || [ "${EGPRS_VIRTUAL_CELL:-0}" = 1 ]; then etape_cellule || true
    else say "cellule virtuelle (BTS 2) non montee : mode $L1 (EGPRS_VIRTUAL_CELL=1 pour l avoir quand meme)"; bilan cellule "--"; fi
    etape_modem     || true
    titre "bilan"
    local k; for k in preflight configs banc abonne cellule modem; do printf '  %-10s %s\n' "$k" "${BILAN[$k]:-??}"; done
    say "${C_DIM}status : $0 status - arret : $0 stop - journaux : journalctl -u $U_MODEM -u $U_PCU -u $U_BTS -u $U_VPHY${C_Z}"
    return 0
}

ACTION=start
while [ $# -gt 0 ]; do
    case "$1" in
        start|stop|status|check) ACTION="$1" ;;
        --l1)        L1="${2:-auto}"; shift ;;
        --l1=*)      L1="${1#*=}" ;;
        --no-banc)   WITH_BANC=0 ;;
        --regen-gprs) REGEN_GPRS=1 ;;
        --all)       STOP_ALL=1 ;;
        -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "a lancer en root (systemd-run, ip netns)" >&2; exit 1; }
case "$ACTION" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    check)  etape_preflight; etape_configs ;;
esac
