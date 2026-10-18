#!/bin/bash
# =============================================================================
# osmo-sim.sh - LA SIM DU BANC DANS UN LECTEUR PC/SC (HID Omnikey).
#
# La carte (sysmoISIM-SJA5 de sysmocom, dans un OMNIKEY 6121) est lue et
# programmee avec pySim (Osmocom, venv /opt/GSM/pysim-venv), puis SERVIE au
# mobile osmocom-bb par le serveur SAP de softSIM en mode pcsc : c est ce que
# fait start-native.sh --sap quand une carte est dans le lecteur.
#
#   tools/osmo-sim.sh lecteur                 les lecteurs PC/SC, l ATR, le type de carte
#   tools/osmo-sim.sh lire                    tout ce que la carte dit (pySim-read)
#   tools/osmo-sim.sh programmer [options]    ecrit l identite du banc sur la carte
#   tools/osmo-sim.sh verifier  [options]     la carte porte-t-elle l identite du banc,
#                                             le HLR la connait-il : prete pour --sap ?
#   tools/osmo-sim.sh hlr [--creer] [options] l abonne de la carte dans le HLR
#   tools/osmo-sim.sh sap [--socket S]        sert la carte par SAP (premier plan),
#                                             ce que start-native.sh --sap fait tout seul
#   tools/osmo-sim.sh shell                   pySim-shell sur la carte (ADM1 si connue)
#
# L IDENTITE DU BANC (meme plan que qosmo/run_modules/21-abonnes-hlr.sh et
# start-native.sh, section "ms_imsi / ms_ki") :
#   IMSI   = MCC MNC <operateur sur 4> <MS sur 6>        001 01 0001 000001
#   Ki     = 00112233445566778899aabbccdd <MS> <operateur>   ...dd 01 01
#   MSISDN = noeud*100000 + operateur*100 + MS                 100101
#   algo   = COMP128v1 (osmo-hlr : aud2g comp128v1)
# Options : --ms N  --op N  --mcc 001  --mnc 01  --imsi I  --ki K  --msisdn M
#           --lecteur N (index PC/SC, defaut 0)  --dry-run  --oui (pas de question)
#
# L ECRITURE passe par l outil de sysmocom, sysmo-usim-tool (sysmo-isim-tool.sja5.py,
# SYSMO_TOOL=/opt/GSM/sysmo-usim-tool) : IMSI, Ki, algorithme COMP128v1, OPc. Sans
# lui (ou OSMO_SIM_PYSIM_PROG=1) : pySim-prog puis pySim-shell pour l algorithme.
#
# LA CLE ADM1 : ecrire sur une sysmoISIM demande la cle ADM1 de LA carte (8
# chiffres, fournie par sysmocom avec la carte : fichier CSV / courriel de la
# commande). Trois essais faux BLOQUENT la carte pour de bon : le script ne
# devine jamais. Sources, dans l ordre : --adm1 K, OSMO_SIM_ADM1, le fichier
# /etc/osmocom/sim-adm1 (une ligne, ou "ICCID clé" par ligne pour plusieurs
# cartes), ~/.config/osmo/sim-adm1.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYSIM_VENV="${PYSIM_VENV:-/opt/GSM/pysim-venv}"
SOFTSIM_DIR="${SOFTSIM_DIR:-/opt/GSM/softsim}"
SAP_SOCK="${SAP_SOCK:-/tmp/osmocom_sap}"
HLR_VTY_PORT="${HLR_VTY_PORT:-4258}"
HLR_DB="${HLR_DB:-/var/lib/osmocom/hlr.db}"
OSMOCOM_CFG="${OSMOCOM_CFG:-/etc/osmocom}"
# Le python qui a pyscard : celui du venv pySim (le profil de root met /root/.env,
# le venv du pont, en tete du PATH, et il n a pas pyscard), sinon celui du systeme.
PY="$PYSIM_VENV/bin/python3"; [ -x "$PY" ] || PY=/usr/bin/python3

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_W=$'\033[33m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_Z=$'\033[0m'
else
    C_OK=; C_KO=; C_W=; C_B=; C_D=; C_Z=
fi
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_Z" "$*"; }
ko()   { printf '  %s✗%s %s\n' "$C_KO" "$C_Z" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_W" "$C_Z" "$*" >&2; }
die()  { ko "$*"; exit 1; }

usage() { sed -n '2,/^# ====*$/p' "$0" | sed -n '2,$p' | sed 's/^# \{0,1\}//' | sed '$d'; }

# ── le plan d identite ───────────────────────────────────────────────────────
MS=1 OP=1 MCC="" MNC="" IMSI="" KI="" MSISDN="" READER="${OSMO_SIM_READER:-0}"
DRY=0 OUI=0 ADM1="${OSMO_SIM_ADM1:-}" CREER=0 SOCK="$SAP_SOCK" VERB="${SAP_VERBOSITY:-3}"

plan_mcc() {
    [ -n "$MCC" ] && { printf '%s' "$MCC"; return; }
    sed -n 's/^[[:space:]]*network country code[[:space:]]\{1,\}\([0-9]*\).*/\1/p' \
        "$OSMOCOM_CFG/osmo-msc.cfg" 2>/dev/null | head -1 | grep . || printf '001'
}
plan_mnc() {
    [ -n "$MNC" ] && { printf '%s' "$MNC"; return; }
    sed -n 's/^[[:space:]]*mobile network code[[:space:]]\{1,\}\([0-9]*\).*/\1/p' \
        "$OSMOCOM_CFG/osmo-msc.cfg" 2>/dev/null | head -1 | grep . || printf '01'
}
plan_node() {
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' "$OSMOCOM_CFG/radio-plan.env" 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
plan_imsi()   { [ -n "$IMSI" ] && printf '%s' "$IMSI" || printf '%s%s%04d%06d' "$(plan_mcc)" "$(plan_mnc)" "$OP" "$MS"; }
plan_ki()     { [ -n "$KI" ] && printf '%s' "$KI" || printf '00112233445566778899aabbccdd%02x%02x' "$MS" "$OP"; }
plan_msisdn() { [ -n "$MSISDN" ] && printf '%s' "$MSISDN" || printf '%d' $(( $(plan_node) * 100000 + OP * 100 + MS )); }

# ── les outils ───────────────────────────────────────────────────────────────
pysim() {  # pysim read|prog|shell args...
    local t="$1"; shift
    local bin="$PYSIM_VENV/bin/pySim-$t.py"
    [ -x "$bin" ] || die "pySim absent ($bin) : sudo $HERE/tools/osmo-sim-install.sh"
    "$bin" -p "$READER" "$@"
}
pcscd_pret() {
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet pcscd pcscd.socket 2>/dev/null; then
        systemctl start pcscd.socket >/dev/null 2>&1 || true
    fi
}
# Les lecteurs, et s ils portent une carte : "N Yes|No nom"
lecteurs() {
    "$PY" - <<'PYSC' 2>/dev/null
from smartcard.System import readers
for i, r in enumerate(readers()):
    try:
        c = r.createConnection(); c.connect(); atr = bytes(c.getATR()).hex(); c.disconnect()
        print(i, "Yes", atr, str(r))
    except Exception:
        print(i, "No", "-", str(r))
PYSC
}
carte_presente() { lecteurs | awk -v r="$READER" '$1==r && $2=="Yes"{f=1} END{exit !f}'; }
exiger_carte() {
    pcscd_pret
    "$PY" -c 'import smartcard' 2>/dev/null \
        || die "pyscard absent ($PY) : sudo $HERE/tools/osmo-sim-install.sh"
    [ -n "$(lecteurs)" ] || die "aucun lecteur PC/SC (pcscd actif ? Omnikey branche ? libccid ?)"
    carte_presente || die "pas de carte dans le lecteur $READER :$(lecteurs | sed 's/^/\n    /')"
}
# L ICCID et l IMSI de la carte (pySim-read), "iccid imsi"
carte_identite() {
    local out
    out="$(timeout 90 "$PYSIM_VENV/bin/pySim-read.py" -p "$READER" 2>/dev/null)" || return 1
    printf '%s %s %s' \
        "$(printf '%s\n' "$out" | sed -n 's/^ICCID: *//p' | head -1)" \
        "$(printf '%s\n' "$out" | sed -n 's/^IMSI: *//p' | head -1)" \
        "$(printf '%s\n' "$out" | sed -n 's/^Autodetected card type: *//p' | head -1 | tr ' ' '_')"
}

# La cle ADM1 : --adm1, OSMO_SIM_ADM1, /etc/osmocom/sim-adm1, ~/.config/osmo/sim-adm1
adm1_trouver() {  # $1 = ICCID de la carte
    local f k
    [ -n "$ADM1" ] && { printf '%s' "$ADM1"; return 0; }
    for f in "$OSMOCOM_CFG/sim-adm1" "$HOME/.config/osmo/sim-adm1"; do
        [ -r "$f" ] || continue
        k="$(awk -v ic="$1" 'NF==2 && $1==ic {print $2; exit} NF==1 && $1 !~ /^#/ {one=$1} END{if(!k && one) print one}' "$f")"
        [ -n "$k" ] && { printf '%s' "$k"; return 0; }
    done
    return 1
}

vty() {  # vty cmd... -> sortie du VTY HLR
    local c; { echo enable; for c in "$@"; do echo "$c"; done; echo exit; } \
        | timeout 10 socat -T 5 - "TCP:127.0.0.1:$HLR_VTY_PORT,crlf" 2>/dev/null
}
hlr_connait() {  # $1 = IMSI
    if [ -r "$HLR_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        [ "$(sqlite3 -readonly "$HLR_DB" "select count(*) from subscriber where imsi='$1';" 2>/dev/null)" -ge 1 ] 2>/dev/null && return 0
    fi
    command -v socat >/dev/null 2>&1 && vty "subscriber imsi $1 show" | grep -q "IMSI: $1"
}

# ── les commandes ────────────────────────────────────────────────────────────
cmd_lecteur() {
    pcscd_pret
    local l; l="$(lecteurs)"
    [ -n "$l" ] || die "aucun lecteur PC/SC (pcscd actif ? Omnikey branche ? libccid ?)"
    printf '%slecteurs PC/SC :%s\n' "$C_B" "$C_Z"
    printf '%s\n' "$l" | while read -r i yes atr name; do
        if [ "$yes" = Yes ]; then
            printf '  %s%s%s  %s\n      carte : ATR %s\n' "$C_B" "$i" "$C_Z" "$name" "$atr"
        else
            printf '  %s%s%s  %s\n      %spas de carte%s\n' "$C_B" "$i" "$C_Z" "$name" "$C_D" "$C_Z"
        fi
    done
    if carte_presente && [ -x "$PYSIM_VENV/bin/pySim-read.py" ]; then
        read -r iccid imsi type <<<"$(carte_identite)"
        printf '  lecteur %s : %s  ICCID %s  IMSI %s\n' "$READER" "${type:-type_inconnu}" "${iccid:-?}" "${imsi:-?}"
    fi
}

cmd_lire() { exiger_carte; pysim read; }

cmd_shell() {
    exiger_carte
    local k; k="$(adm1_trouver "$(carte_identite | cut -d' ' -f1)")" || true
    if [ -n "$k" ]; then pysim shell -a "$k" "$@"; else pysim shell "$@"; fi
}

# pySim-prog (identite, PLMN, SMSP, Ki) puis pySim-shell : l algorithme 2G de la
# sysmoISIM. pySim-prog n ecrit que le Ki (octet 1..16 de EF.SIM_AUTH_KEY), pas
# l octet de configuration : la carte resterait en Milenage et le HLR (COMP128v1)
# repondrait « authentication failed ». Octet 0 : bits 7-6 libres, bit 5 SRES
# derivation 1, bit 4 OPc, bits 3-0 algorithme (1 = COMP128v1, 4 = Milenage) :
# 0x11. Ecrit dans DF.SYSTEM/EF.SIM_AUTH_KEY (6f20) et ADF.USIM/EF.USIM_AUTH_KEY_2G
# (af22), les deux fichiers 2G de la carte. OP/OPc : 16 octets a zero.
cmd_programmer() {
    exiger_carte
    local imsi ki msisdn mcc mnc iccid cur_imsi type
    imsi="$(plan_imsi)"; ki="$(plan_ki)"; msisdn="$(plan_msisdn)"; mcc="$(plan_mcc)"; mnc="$(plan_mnc)"
    case "$imsi" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) die "IMSI a 15 chiffres attendu : $imsi" ;; esac
    case "$ki" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;; *) die "Ki : 32 caracteres hexa attendus : $ki" ;; esac
    read -r iccid cur_imsi type <<<"$(carte_identite)"
    [ -n "$iccid" ] || die "la carte ne repond pas a pySim-read (lecteur $READER)"
    printf '%sla carte%s   : %s  ICCID %s  IMSI actuel %s\n' "$C_B" "$C_Z" "${type:-?}" "$iccid" "${cur_imsi:-?}"
    printf '%sle banc%s    : IMSI %s  PLMN %s-%s  Ki %s  MSISDN %s  COMP128v1\n' "$C_B" "$C_Z" "$imsi" "$mcc" "$mnc" "$ki" "$msisdn"
    local adm=""
    if [ "$DRY" = 0 ]; then
        adm="$(adm1_trouver "$iccid")" || die "cle ADM1 inconnue pour l ICCID $iccid : --adm1 K, OSMO_SIM_ADM1, ou $OSMOCOM_CFG/sim-adm1 (voir l en-tete). Elle vient de sysmocom avec la carte. --dry-run montre sans ecrire."
        case "$adm" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) die "ADM1 : 8 chiffres attendus (une sysmoISIM), lu « ${#adm} caracteres »" ;; esac
        if [ "$OUI" = 0 ]; then
            printf '%sEcrire ces valeurs sur la carte %s ? Trois ADM1 faux bloquent la carte. [o/N] %s' "$C_W" "$iccid" "$C_Z"
            read -r rep; case "$rep" in o|O|oui|y|Y) ;; *) echo "abandon"; exit 1 ;; esac
        fi
    fi
    local sysmo="${SYSMO_TOOL:-/opt/GSM/sysmo-usim-tool}/sysmo-isim-tool.sja5.py"
    if [ "$type" = sysmoISIM-SJA5 ] && [ -f "$sysmo" ] && [ "${OSMO_SIM_PYSIM_PROG:-0}" != 1 ]; then
        # 1. L outil de sysmocom (sysmo-usim-tool, sysmo-isim-tool.sja5.py) : IMSI,
        # longueur du MNC, Ki (2G/3G/4G5G), algorithme 2G COMP128v1 (3G Milenage),
        # OPc. C est lui qui sait poser l algorithme ; pySim-prog ne le fait pas.
        # [2026-10-14] Verifie sur la carte : « 2g: 1=COMP128v1 », Ki relu.
        printf '%s1. sysmo-isim-tool.sja5 (sysmocom)%s\n' "$C_B" "$C_Z"
        if [ "$DRY" = 1 ]; then
            printf '    %s -a <ADM1> -J %s -N %s -K %s -T COMP128v1:MILENAGE -C %s\n' "$(basename "$sysmo")" "$imsi" "${#mnc}" "$ki" "00000000000000000000000000000000"
            ok "dry-run : rien n a ete ecrit"; return 0
        fi
        local out
        if ! out="$("$PY" "$sysmo" -a "$adm" -J "$imsi" -N "${#mnc}" -K "$ki" -T COMP128v1:MILENAGE \
                    -C 00000000000000000000000000000000 2>&1)"; then
            printf '%s\n' "$out" | tail -12 | sed 's/^/    /' >&2
            die "sysmo-isim-tool a echoue (ADM1 refusee ? carte retiree ?)"
        fi
        printf '%s\n' "$out" | grep -E 'programmed|algorithm|2g:|3g:|IMSI|Error|rror' | sed 's/^/    /'
        # 2. relire l algorithme et le Ki avec le meme outil
        printf '%s2. relecture (algorithme, Ki)%s\n' "$C_B" "$C_Z"
        out="$("$PY" "$sysmo" -a "$adm" -t -k 2>&1)"
        printf '%s\n' "$out" | grep -q '2g: 1=COMP128v1' || { printf '%s\n' "$out" | tail -8 | sed 's/^/    /' >&2; die "COMP128v1 non relu sur la carte"; }
        printf '%s\n' "$out" | grep -q "2g: Key: $ki" || { printf '%s\n' "$out" | tail -8 | sed 's/^/    /' >&2; die "Ki non relu sur la carte"; }
        ok "COMP128v1 et Ki relus sur la carte (2g)"
    else
        # Sans l outil sysmocom (ou OSMO_SIM_PYSIM_PROG=1) : pySim-prog puis pySim-shell.
        # 1. pySim-prog : ICCID conserve, IMSI, PLMN (HPLMN, PLMNsel), SPN, SMSP, MSISDN, Ki
        local args=(-t sysmoISIM-SJA5 -s "$iccid" -i "$imsi" -k "$ki" -o 00000000000000000000000000000000
                    -x "$mcc" -y "$mnc" --mnclen "${#mnc}" -n "Osmo $OP" --msisdn "$msisdn" --acc 0001)
        [ "$type" = sysmoISIM-SJA5 ] || args=("${args[@]:2}")   # autre carte : laisser pySim la reconnaitre
        [ "$DRY" = 1 ] && args+=(--dry-run)
        [ -n "$adm" ] && args+=(-a "$adm")
        printf '%s1. pySim-prog%s\n' "$C_B" "$C_Z"
        local out
        if ! out="$(pysim prog "${args[@]}" 2>&1)"; then
            printf '%s\n' "$out" | tail -15 >&2
            die "pySim-prog a echoue (ADM1 refusee ? carte retiree ?)"
        fi
        printf '%s\n' "$out" | grep -E '^( > |Programming|Dry Run|Autodetected)' | sed 's/^/    /'
        [ "$DRY" = 1 ] && { ok "dry-run : rien n a ete ecrit"; return 0; }
        # 2. pySim-shell : l algorithme 2G = COMP128v1 dans les deux fichiers d authentification.
        # verify_adm recoit la cle : sans argument il la cherche dans un CSV par ICCID
        # (« Unable to find card key data »), -a ne suffit pas.
        printf '%s2. pySim-shell : algorithme COMP128v1%s\n' "$C_B" "$C_Z"
        local script; script="$(mktemp)"
        cat >"$script" <<EOF
verify_adm $adm
select MF
select DF.SYSTEM
select EF.SIM_AUTH_KEY
update_binary 11${ki}00000000000000000000000000000000
read_binary_decoded
select MF
select ADF.USIM
select EF.USIM_AUTH_KEY_2G
update_binary 11${ki}00000000000000000000000000000000
read_binary_decoded
EOF
        out="$(pysim shell -a "$adm" --noprompt --script "$script" 2>&1)"; rm -f "$script"
        if printf '%s\n' "$out" | grep -q -i -e 'SW Match Error' -e 'Exception' -e 'EXCEPTION' -e 'Error'; then
            printf '%s\n' "$out" | grep -i -e error -e exception | head -5 | sed 's/^/    /' >&2
            die "l ecriture de l algorithme a echoue (voir ci-dessus) ; l identite (etape 1) est ecrite"
        fi
        local n; n="$(printf '%s\n' "$out" | grep -c '"algorithm": "comp128v1"')"
        [ "$n" -ge 1 ] || { printf '%s\n' "$out" | tail -8 | sed 's/^/    /' >&2; die "COMP128v1 non relu sur la carte"; }
        ok "COMP128v1 relu dans $n fichier(s) d authentification"
    fi
    # 3. relire
    read -r iccid cur_imsi type <<<"$(carte_identite)"
    [ "$cur_imsi" = "$imsi" ] || die "relecture : IMSI $cur_imsi au lieu de $imsi"
    ok "carte programmee : IMSI $imsi, Ki ${ki:0:8}..., COMP128v1, MSISDN $msisdn"
    cmd_hlr
}

cmd_hlr() {
    local imsi ki iccid type
    if [ -n "$IMSI" ]; then imsi="$IMSI"; else
        exiger_carte; read -r iccid imsi type <<<"$(carte_identite)"
        [ -n "$imsi" ] || die "IMSI illisible sur la carte"
    fi
    if hlr_connait "$imsi"; then
        ok "HLR : l abonne $imsi existe ($HLR_DB / VTY $HLR_VTY_PORT)"
        return 0
    fi
    if [ "$CREER" = 1 ]; then
        ki="$(plan_ki)"
        command -v socat >/dev/null 2>&1 || die "socat absent : impossible d ecrire dans le VTY HLR"
        vty "subscriber imsi $imsi create" "subscriber imsi $imsi update msisdn $(plan_msisdn)" \
            "subscriber imsi $imsi update aud2g comp128v1 ki $ki" >/dev/null
        hlr_connait "$imsi" && ok "HLR : abonne $imsi cree (COMP128v1, Ki ${ki:0:8}..., MSISDN $(plan_msisdn))" \
                           || die "HLR : creation de $imsi echouee (osmo-hlr lance ? VTY $HLR_VTY_PORT ?)"
        return 0
    fi
    if [ "$imsi" = "$(plan_imsi)" ]; then
        warn "HLR : $imsi inconnu pour l instant - c est l IMSI du MS#$MS, start-native.sh le cree au lancement (21-abonnes-hlr)"
    else
        warn "HLR : $imsi inconnu - tools/osmo-sim.sh hlr --creer --ki <Ki de la carte> (ou programmer la carte au plan du banc)"
    fi
    return 1
}

cmd_verifier() {
    exiger_carte
    local iccid imsi type rc=0
    read -r iccid imsi type <<<"$(carte_identite)"
    [ -n "$imsi" ] || die "IMSI illisible sur la carte (lecteur $READER)"
    ok "carte : ${type:-?}  ICCID $iccid  IMSI $imsi"
    if [ "$imsi" = "$(plan_imsi)" ]; then ok "IMSI = celui du MS#$MS de l operateur $OP (plan du banc)"
    else warn "IMSI $imsi ≠ plan du banc $(plan_imsi) : tools/osmo-sim.sh programmer, ou hlr --creer"; rc=1; fi
    cmd_hlr || rc=1
    if [ -f "$SOFTSIM_DIR/src/demo_server.rb" ] && ruby -e 'require "smartcard"' >/dev/null 2>&1; then
        ok "softSIM pcsc : $SOFTSIM_DIR, gem smartcard present"
    else warn "softSIM pcsc indisponible : sudo $HERE/tools/osmo-sim-install.sh"; rc=1; fi
    if [ $rc -eq 0 ]; then ok "prete : ./start-native.sh --sap (la carte est servie par SAP au mobile)"
    else warn "pas encore prete pour --sap"; fi
    return $rc
}

cmd_sap() {
    exiger_carte
    [ -f "$SOFTSIM_DIR/src/demo_server.rb" ] || die "softSIM absent ($SOFTSIM_DIR) : sudo $HERE/tools/osmo-sim-install.sh"
    ruby -e 'require "smartcard"' >/dev/null 2>&1 || die "gem smartcard absent : sudo $HERE/tools/osmo-sim-install.sh"
    local shim=/usr/local/share/softsim/ruby_compat.rb
    [ -f "$shim" ] || shim="$HERE/tools/softsim/ruby_compat.rb"
    for p in $(ps -eo pid,args | awk '/[d]emo_server\.rb/ {print $1}'); do kill "$p" 2>/dev/null; done
    rm -f "$SOCK"
    ok "serveur SAP (softSIM, type pcsc) sur $SOCK - Ctrl-C pour arreter ; le mobile : sim sap + sap-socket $SOCK"
    cd "$SOFTSIM_DIR/src" && exec ruby -r"$shim" demo_server.rb --type pcsc --socket unix --unix "$SOCK" --verbosity "$VERB"
}

# ── ligne de commande ────────────────────────────────────────────────────────
CMD="${1:-}"; [ $# -gt 0 ] && shift
REST=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ms)       MS="${2:?}"; shift ;;
        --op)       OP="${2:?}"; shift ;;
        --mcc)      MCC="${2:?}"; shift ;;
        --mnc)      MNC="${2:?}"; shift ;;
        --imsi)     IMSI="${2:?}"; shift ;;
        --ki)       KI="${2:?}"; shift ;;
        --msisdn)   MSISDN="${2:?}"; shift ;;
        --adm1)     ADM1="${2:?}"; shift ;;
        --lecteur|-p) READER="${2:?}"; shift ;;
        --socket)   SOCK="${2:?}"; shift ;;
        --verbosity) VERB="${2:?}"; shift ;;
        --dry-run)  DRY=1 ;;
        --oui|-y)   OUI=1 ;;
        --creer)    CREER=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          REST+=("$1") ;;
    esac
    shift
done
case "$CMD" in
    lecteur|lecteurs) cmd_lecteur ;;
    lire)             cmd_lire ;;
    programmer)       cmd_programmer ;;
    verifier)         cmd_verifier ;;
    hlr)              cmd_hlr ;;
    sap)              cmd_sap ;;
    shell)            cmd_shell "${REST[@]}" ;;
    ''|-h|--help)     usage; exit 0 ;;
    *)                die "commande inconnue : $CMD (lecteur, lire, programmer, verifier, hlr, sap, shell)" ;;
esac
