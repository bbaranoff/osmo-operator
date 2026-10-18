#!/bin/bash
# =============================================================================
# scripts/egprs-dsp.sh - workflow EGPRS du banc, sur la chaine DSP (ROM TI).
# =============================================================================
#
# Ce que ce workflow monte, dans l ordre, et verifie a chaque etape :
#
#   1. preflight    binaires, ROM DSP (7 fichiers), c54x_exe, modem osmocom-bb ;
#                   et la PORTE DSP : le firmware layer1 Calypso sait-il faire
#                   du PDCH (L1CTL_GPRS_*) ? Aujourd hui NON -> le modem GPRS
#                   tourne sur une couche 1 virtuelle (virtphy), dans la MEME
#                   PLMN/LAC/RA que le mobile DSP, qui lui campe sur la BTS 0.
#   2. configs      /etc/osmocom : la BTS 2 virtuelle EGPRS dans osmo-bsc.cfg
#                   (fragment configs/gprs/osmo-bsc-bts2-egprs.frag, re-pose
#                   apres chaque --regen), osmo-bts-virtual-gprs.cfg,
#                   osmo-pcu-gprs.cfg, modem-gprs.cfg.
#   3. banc         osmo-banc.service (start-native.sh --dsp : coeur, BTS 0 sur
#                   le C54x + ROM TI, SGSN/GGSN/PCU de la BTS 0).
#   4. abonne       l IMSI du modem dans le HLR (comp128v1), idempotent.
#   5. cellule      osmo-bts-virtual (BTS 2, Um multicast sur lo) + osmo-pcu
#                   (socket /tmp/pcu_bts3) en unites systemd transitoires ;
#                   attend l OML de la BTS 2 au BSC et le NS-VC du PCU.
#   6. modem        virtphy (-> /tmp/modem_l2) puis osmocom-bb `modem` :
#                   GPRS attach (GMM) + contexte PDP (SM), tun dans le netns
#                   msgprs ; verifie au SGSN (mm-context, pdp-context) et par
#                   un ping vers apn0 depuis le netns.
#
#   EGPRS_L1=dsp : (quand la porte DSP passera) pas de virtphy ; le modem est
#   lance par c54x_exe/run.sh a la place de `mobile` (MOBILE= / MOBILE_CFG= dans
#   /etc/default/osmo-banc) sur /tmp/osmocom_l2. Le script pose ces deux
#   variables et le dit ; il ne force pas un chemin que le firmware n a pas.
#
# Usage : egprs-dsp.sh [start|stop|status|check] [--l1 auto|virtphy|dsp]
#                      [--no-banc] [--regen-gprs] [--all]
#   start        tout monter (defaut)            stop   demonter la cellule + modem
#   status       etat + SGSN                     check  preflight seul, ne lance rien
#   --no-banc    ne pas toucher a osmo-banc      --all  (stop) arreter aussi osmo-banc
#   --regen-gprs reposer les 4 configs GPRS depuis configs/gprs meme si presentes
#
# Persistant : services/osmo-egprs-dsp.service (Requires=osmo-banc) enclenche ce
# script au boot ; OSMO_BANC_ARGS="--dsp" dans /etc/default/osmo-banc.
# Journal : journalctl -u osmo-egprs-dsp, -u osmo-modem-gprs, -u osmo-pcu-gprs,
#           -u osmo-bts-virtual-gprs, -u osmo-virtphy-gprs.
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

# L abonne du modem : le 3e du plan (01-abonnes-hlr : octet 15 = n, 16 = op).
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

# ── affichage ────────────────────────────────────────────────────────────────
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

# ── outils ───────────────────────────────────────────────────────────────────
# Le VTY Osmocom lit ligne a ligne : une pause entre chaque commande, sinon il
# en saute (meme constat que start-interstp.sh --status).
vty() {   # vty HOST PORT cmd...
    local host="$1" port="$2"; shift 2
    { sleep 0.4; printf 'enable\n'; local c; for c in "$@"; do sleep 0.3; printf '%s\n' "$c"; done
      sleep 0.8; printf 'exit\n'; sleep 0.2; } | timeout 10 nc -q1 "$host" "$port" 2>/dev/null | tr -d '\r'
}
port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/${2:-127.0.0.1}/$1" 2>/dev/null; }
wait_until() {   # wait_until SECONDES "libelle" cmd...
    local to="$1" what="$2"; shift 2; local t=0
    while ! "$@" >/dev/null 2>&1; do
        [ "$t" -ge "$to" ] && { ko "$what : toujours rien apres ${to}s"; return 1; }
        sleep 2; t=$((t+2))
    done
    ok "$what (${t}s)"
}
unit_active() { systemctl is-active --quiet "$1"; }
unit_run() {   # unit_run NOM cmd... : unite transitoire, vue par systemctl/journalctl
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
    # modem osmocom-bb : dans le PATH, sinon celui de l arbre ; on l installe
    # (persistant) s il n est que dans l arbre.
    MODEM_BIN="$(command -v modem 2>/dev/null || true)"
    if [ -z "$MODEM_BIN" ] && [ -x "$BB/src/host/layer23/src/modem/modem" ]; then
        install -m755 "$BB/src/host/layer23/src/modem/modem" /usr/local/bin/modem 2>/dev/null \
            && MODEM_BIN=/usr/local/bin/modem && say "modem installe dans /usr/local/bin (depuis $BB)"
    fi
    [ -n "$MODEM_BIN" ] && ok "modem : $MODEM_BIN" || { ko "modem (osmocom-bb layer23) absent : make -C $BB/src/host/layer23"; rc=1; }

    # La chaine DSP : ROM TI + c54x_exe (le banc par defaut de start-native.sh)
    local n=0 r
    for r in PROM0 PROM1 PROM2 PROM3 DROM PDROM Registers; do [ -f "$ROM_DIR/calypso_dsp.$r.bin" ] && n=$((n+1)); done
    [ "$n" -eq 7 ] && ok "ROM DSP TI : $n/7 dans $ROM_DIR" || warn "ROM DSP : $n/7 dans $ROM_DIR - --dsp ne demarrera pas (c54x_exe/rom/fetch-rom.sh)"
    [ -x "$C54X/c54x_exe" ] && ok "c54x_exe : $C54X/c54x_exe" || warn "c54x_exe non compile : make -C $C54X"

    # LA PORTE DSP : le firmware layer1 (celui qui tourne sur l ARM emule, devant
    # la ROM) traite-t-il les primitives GPRS de L1CTL ? Sans elles, aucun PDCH
    # ne peut etre ouvert sur cette chaine, quoi que sache la ROM.
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
    # Variante DSP du modem : meme abonne, socket L1CTL du C54x. Posee pour le
    # jour ou la porte s ouvre (MOBILE_CFG= dans /etc/default/osmo-banc).
    pose_cfg modem-gprs.cfg modem-gprs-dsp.cfg "s|layer2-socket .*|layer2-socket $SOCK_DSP|" || rc=1

    # La BTS 2 dans osmo-bsc.cfg : un bloc « bts 2 » insere avant « msc 0 ».
    # --regen regenere ce fichier depuis configs/osmo-bsc.cfg (2 BTS) : on
    # verifie a chaque start, on re-insere si besoin.
    local bsc="$ETC/osmo-bsc.cfg"
    if [ ! -f "$bsc" ]; then ko "$bsc absent (start-native.sh --regen)"; rc=1
    elif grep -q '^ bts 2$' "$bsc"; then ok "BTS 2 EGPRS deja dans osmo-bsc.cfg"
    elif ! grep -q '^msc 0$' "$bsc"; then ko "pas de « msc 0 » dans $bsc : je ne sais pas ou inserer la BTS 2"; rc=1
    else
        cp -a "$bsc" "$bsc.avant-bts2-egprs"
        sed "s|__SGSN_IP__|$sgsn_ip|g" "$CFG_SRC/osmo-bsc-bts2-egprs.frag" > "$bsc.frag.$$"
        # Insertion avant « msc 0 », sans toucher au reste du fichier.
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

# ── 3. banc (osmo-banc.service, chaine DSP) ──────────────────────────────────
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

# ── 4. l abonne du modem dans le HLR ─────────────────────────────────────────
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

# ── 5. la cellule paquet : BTS 2 virtuelle + son PCU ─────────────────────────
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

# ── 6. le modem GPRS ─────────────────────────────────────────────────────────
etape_modem() {
    titre "6. modem GPRS (couche 1 : $L1)"
    ip netns list 2>/dev/null | grep -qw "$NETNS" || { ip netns add "$NETNS" && say "netns $NETNS cree"; }
    if [ "$L1" = dsp ]; then
        # QEMU + ROM TI : le modem prend la place de `mobile` SUR LA MEME socket
        # L1CTL (/tmp/osmocom_l2, osmocon du banc DSP). On ne passe pas par
        # MOBILE=/MOBILE_CFG= dans /etc/default/osmo-banc : start-native.sh
        # reecrit le fichier designe par MOBILE_CFG avec son gabarit `mobile`
        # (gps device...), que `modem` refuse. On arrete donc le mobile du banc
        # DSP et on lance modem nous-memes, en unite transitoire.
        local cfg="$ETC/modem-gprs-dsp.cfg"
        sed "s|layer2-socket .*|layer2-socket $SOCK_DSP|" "$CFG_SRC/modem-gprs.cfg" > "$cfg"
        # Le firmware layer1 avec PDCH (L1CTL_GPRS_*) et les bursts finaux de la ROM
        # (UL_RAW=1, pont/dsp/uplink.py) : poses pour le prochain demarrage du banc.
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
        # [2026-10-15] Le banc doit etre EN DSP : sans c54x_exe, la couche 1 est gr-gsm
        # (OSMO_BANC_ARGS=--grgsm pose par le lanceur du bureau jusqu au reboot) et
        # le PDCH n y existe pas.
        if ! pgrep -f 'c54x_exe --arm' >/dev/null; then
            ko "le banc tourne en gr-gsm (pas de c54x_exe) : $(systemctl show-environment 2>/dev/null | grep OSMO_BANC_ARGS || echo 'OSMO_BANC_ARGS non pose')"
            say "pour le DSP : systemctl set-environment OSMO_BANC_ARGS=--dsp && systemctl restart osmo-banc"
            bilan modem KO; return 1
        fi
        # Tout `mobile` branche sur la meme socket L1CTL (mobile_pont du banc DSP,
        # mobile_group1 du fork...) se battrait avec le modem : chacun remet la
        # couche 1 a zero (RESET FULL + PM_REQ contre RESET FULL + FBSB_REQ).
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
    # [2026-10-15] L attach et le PDP se lisent chez le modem : « show mm-context »
    # du SGSN n affiche pas « GMM_REGISTERED » (le test echouait sur un attach
    # reussi). Attach = « Attach success » du modem ; PDP = tun_modem adresse
    # dans le netns, posee par le modem a l Activate PDP Context Accept.
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
    # La cellule virtuelle n a de sens que pour un modem sur virtphy : en mode
    # dsp (QEMU + ROM TI) le modem campe sur la BTS 0 du C54x, comme `mobile`.
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
