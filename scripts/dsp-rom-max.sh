#!/bin/bash
# =============================================================================
# scripts/dsp-rom-max.sh - workflow « le DSP en fait un maximum par la ROM ».
# =============================================================================
#
# Le banc DSP (c54x_exe, mask-ROM TI) peut remplacer certains traitements de
# la ROM par des reconstructions sur l hote (pont.py, montant.c, qosmo) :
# SB/TOA « en conserve », RACH code par le pont, codage xCCH montant par le
# pont, dechiffrement A5 par le pont... Chaque ecart est un commutateur
# d environnement (hacks_actifs() dans c54x_exe/src/pont.c les affiche au
# demarrage). Ce workflow :
#
#   1. profil     pose dans /etc/default/osmo-banc le profil « ROM max » : tous
#                 les commutateurs qui ont un chemin ROM sont sur ROM, aucun
#                 SB/TOA en conserve. Persistant : chaque boot du banc le lit.
#   2. banc       redemarre osmo-banc (--dsp) avec ce profil et attend le camp
#                 (VTY du mobile 4247).
#   3. echelle    joue l echelle de /opt/GSM/tests/banc-max.sh --dsp sur la
#                 pile en cours : LU, SMS MO/MT, appel voix, puis le barreau
#                 « couverture » (tests/modules/99-couverture.sh) qui tranche,
#                 traitement par traitement, ROM ou HOTE d apres les journaux.
#   4. bilan      relit couverture.txt : ce que la ROM a fait, ce qui est reste
#                 a l hote MALGRE le profil (a corriger), et ce qui n a pas de
#                 chemin ROM branche (le reste a faire : FACCH/SACCH-TCH/parole
#                 montants, A5 montant au fn de l air, vocodage).
#
# Usage : dsp-rom-max.sh [run|profile|report|status] [--no-restart] [--only=camp,attache]
#   run (defaut)   1 -> 4            profile  pose le profil seulement (1)
#   report         relit le dernier /root/banc-max-*/couverture.txt (4)
#   --no-restart   ne redemarre pas osmo-banc (la pile en cours a deja le profil ?)
#   --only=...     passe a banc-max.sh (ex. --only=camp,attache,couverture)
#   --parole-rom   [2026-10-15] TCH montant (parole, FACCH, SACCH/T) emis par la ROM :
#                  CALYPSO_NORM_TC=0 + CALYPSO_C54X_BCTC_NORM=1 (emulateur : le marqueur
#                  de trame de parole de PROM0 0x90a0 n'etait jamais pose) + PONT_UL_RAW_TCH=1.
#                  DEFAUT depuis le 18/10 ; --parole-hote revient en arriere (et coupe --vocodeur-rom).
#   --vocodeur-rom [2026-10-15] le codec FR de la ROM vocode (port voix SP0 modelise,
#                  calypso_vsp.c) : BANC_VOCODEUR=rom (mobile en l1phy, sans GAPK) +
#                  CALYPSO_VSP=1 (pont/vsp_audio.py <-> PulseAudio). Implique --parole-rom.
#                  + emulateur : CALYPSO_C54X_BCD_CARRY=1 (BCD sur C/NC, depaquetage FR PDROM 0xe458)
#                  et CALYPSO_C54X_OVM_LOGIQUE=1 (SFTL/AND/OR/XOR/ROL ne saturent pas, en-tete PDROM 0xe4c4)
#                  et CALYPSO_MAC=1 (MACR/MASR/MACA/MASA/MPYA conformes SPRU172C) : sans lui le decodeur
#                  FR de la ROM sort un spectre retourne (1 kHz rendu a ~3 kHz, 74 % de l'energie
#                  au-dessus de 3 kHz) ; avec, sa sortie au rejeu a le spectre de libgsm (16/10).
#                  + CALYPSO_C54X_BCD_TC=1 (vrai TC sur les 12 BCD tc/ntc : signe des coefficients
#                  de reflexion du codeur, Schur PDROM 0xe763/0xedc5, faux 47 % du temps sans lui)
#                  et CALYPSO_C54X_BCTC_COMBO=1 (BC tc,nc,bio : conditions ET-ees, isa 28). Avec ces
#                  drapeaux et le decalage ASM de ADD/SUB src,ASM (corrige par defaut le 16/10), le
#                  codeur FR de la ROM est bit-exact avec libgsm sur ~99 % des trames au rejeu.
#                  DEFAUT depuis le 18/10 (valide banc 16/10) ; --vocodeur-hote revient a GAPK.
#   --fw-gprs      firmware layer1 avec PDCH (layer1.highram.gprs.elf) : le DEFAUT depuis le 15/10 ;
#   --fw-stock     le firmware d origine (sans GPRS)
#
# Unite : services/osmo-dsp-rom-max.service (oneshot, lancee a la demande :
# une campagne de tests n a rien a faire au boot ; le PROFIL, lui, persiste).
# Journal : journalctl -u osmo-dsp-rom-max ; rapports : /root/banc-max-<date>/
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS=/etc/default/osmo-banc
TESTS=/opt/GSM/tests
FW_GPRS=/opt/GSM/firmware/board/compal_e88/layer1.highram.gprs.elf
# [2026-10-18] --vocodeur-rom (donc --parole-rom) PAR DEFAUT. Valide au banc le
# 16/10 (27/27, voix 1 kHz 100 %, tout ROM). Sans lui, une machine sans
# /etc/default/osmo-banc (acer, 10.99.0.2) tournait le codec FR de la ROM sans
# ses correctifs d emulateur : trames de silence au montant, echo test muet.
RESTART=1; ONLY=""; FWGPRS=1; PAROLE_ROM=1; VOCODEUR_ROM=1; ACTION=run
MOB_VTY=4247

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_WA=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_Z=$'\033[0m'
else C_OK=; C_KO=; C_WA=; C_DIM=; C_B=; C_Z=; fi
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_Z" "$*"; }
ko()   { printf '  %s[ KO ]%s %s\n' "$C_KO" "$C_Z" "$*"; }
warn() { printf '  %s[ !! ]%s %s\n' "$C_WA" "$C_Z" "$*"; }
titre(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_Z"; }
port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# ── 1. le profil ROM max ─────────────────────────────────────────────────────
# Chaque ligne : VARIABLE=valeur   # ce qu elle met dans la ROM (et l autre valeur)
profil_lignes() { cat <<'P'
MONTANT_EFFACE_TASK_RA=0
MONTANT_ROM_UL=1
MONTANT_ROM_TX=1
UL_RAW=1
PONT_DSP_DECHIFFRE=0
CALYPSO_A5=1
MONTANT_REQREF=0
CALYPSO_C54X_BCTC_ETENDU=1
PONT_CAN_TOA=
PONT_CAN_SB_TOA=
PONT_CAN_SB=
P
}
profil_doc() { cat <<'P'
# ── profil « la ROM fait le maximum » (scripts/dsp-rom-max.sh) ──────────────
# MONTANT_EFFACE_TASK_RA=0  RACH : la ROM garde la tache et code l access-burst (1 : le pont le code)
# MONTANT_ROM_UL=1          SDCCH/SACCH montants : bursts codes par la ROM (0 : codage hote)
# MONTANT_ROM_TX=1          bursts finaux de la ROM publies au pont (calypso_tx_rom)
# UL_RAW=1                  le pont emet ces bursts tels quels (0 : recodage + A5 cote hote)
# PONT_DSP_DECHIFFRE=0      A5 descendant : la ROM dechiffre, pas le pont
# CALYPSO_A5=1              coprocesseur A5 du silicium, modelise dans c54x_exe (0 : coupe)
# MONTANT_REQREF=0          IMMEDIATE ASSIGNMENT : reference de la BTS laissee telle quelle (1 : qosmo la recale sur last_rach)
# CALYPSO_C54X_BCTC_ETENDU=1  emulateur : BC tc/ntc au vrai TC apres cmpr/bit/bitt et apres cmpm/bitf + ST (0xb2c7, double tampon I/Q) (0 : heuristique ACC)
# PONT_CAN_TOA= / PONT_CAN_SB_TOA= / PONT_CAN_SB=   rien « en conserve » : FB/SB/TOA par la ROM
P
}
etape_profil() {
    titre "1. profil ROM max dans $DEFAULTS"
    touch "$DEFAULTS"
    # retirer une ancienne version du bloc, puis le reposer
    sed -i '/profil « la ROM fait le maximum »/,/^# ── fin profil ROM max/d' "$DEFAULTS"
    while IFS= read -r l; do [ -n "$l" ] && sed -i "/^${l%%=*}=/d" "$DEFAULTS"; done < <(profil_lignes)
    sed -i '/^FIRMWARE_ELF=/d;/^FIRMWARE_BIN=/d;/^CALYPSO_NORM_TC=/d;/^CALYPSO_C54X_BCTC_NORM=/d;/^PONT_UL_RAW_TCH=/d;/^# parole montante ROM/d;/^BANC_VOCODEUR=/d;/^CALYPSO_VSP=/d;/^CALYPSO_C54X_BCD_CARRY=/d;/^CALYPSO_C54X_OVM_LOGIQUE=/d;/^CALYPSO_MAC=/d;/^CALYPSO_C54X_BCD_TC=/d;/^CALYPSO_C54X_BCTC_COMBO=/d;/^# vocodeur ROM/d' "$DEFAULTS"
    { profil_doc; profil_lignes
      if [ "$PAROLE_ROM" = 1 ]; then printf '# parole montante ROM (--parole-rom, defaut)\nCALYPSO_NORM_TC=0\nCALYPSO_C54X_BCTC_NORM=1\nPONT_UL_RAW_TCH=1\n'
      else printf '# parole montante hote (--parole-hote)\n'; fi
      if [ "$VOCODEUR_ROM" = 1 ]; then printf '# vocodeur ROM (--vocodeur-rom, defaut)\nBANC_VOCODEUR=rom\nCALYPSO_VSP=1\nCALYPSO_C54X_BCD_CARRY=1\nCALYPSO_C54X_OVM_LOGIQUE=1\nCALYPSO_MAC=1\nCALYPSO_C54X_BCD_TC=1\nCALYPSO_C54X_BCTC_COMBO=1\n'
      else printf '# vocodeur hote, GAPK (--vocodeur-hote)\n'; fi
      if [ "$FWGPRS" = 1 ]; then printf 'FIRMWARE_ELF=%s\nFIRMWARE_BIN=%s\n' "$FW_GPRS" "${FW_GPRS%.elf}.bin"
      else printf '# FIRMWARE_ELF=%s   # --fw-gprs : layer1 avec PDCH (L1CTL_GPRS_*)\n' "$FW_GPRS"; fi
      printf '# ── fin profil ROM max ──\n'; } >> "$DEFAULTS"
    # [2026-10-15] PAS de OSMO_BANC_ARGS="--dsp" ici : dans l unite, EnvironmentFile=
    # l emporte sur `systemctl set-environment` (launch.sh --grgsm) et le banc
    # partait en DSP quoi qu on demande. Le DSP est le defaut de start-native.sh.
    sed -i '/^OSMO_BANC_ARGS=/d' "$DEFAULTS"
    ok "profil pose ($(profil_lignes | grep -c .) commutateurs)"; grep -E '^[A-Z_]+=' "$DEFAULTS" | sed 's/^/      /'
}

# ── 2. le banc ───────────────────────────────────────────────────────────────
etape_banc() {
    titre "2. banc DSP (osmo-banc.service)"
    if [ "$RESTART" = 1 ]; then
        say "systemctl restart osmo-banc (plusieurs minutes : QEMU, C54x, camp)"
        systemctl reset-failed osmo-banc 2>/dev/null; systemctl restart osmo-banc || { ko "osmo-banc : journalctl -u osmo-banc -n 50"; return 1; }
    else say "--no-restart : pile en cours"; fi
    local t=0; while ! port_open $MOB_VTY; do [ $t -ge 180 ] && { ko "VTY du mobile DSP :$MOB_VTY absente apres 180s"; return 1; }; sleep 3; t=$((t+3)); done
    ok "mobile DSP (VTY :$MOB_VTY) en ${t}s"
    local dsplog=/tmp/c54x-pont/dsp.log
    if [ -r "$dsplog" ]; then
        local h; h="$(grep -ao 'hacks[^)]*' "$dsplog" | head -1)"
        grep -aq 'laisse a la ROM : elle code l.access-burst' "$dsplog" && ok "RACH : tache laissee a la ROM" || warn "RACH : pas de trace « laisse a la ROM » dans $dsplog"
        grep -aq 'rom-ul.*actif' "$dsplog" && ok "xCCH montant : bursts de la ROM publies" || warn "rom-ul : non actif dans $dsplog"
        grep -aq 'tx-rom.*actif\|calypso_tx_rom.*actif' "$dsplog" && ok "bursts finaux de la ROM : publies" || say "${C_DIM}(pas de ligne tx-rom actif lue)${C_Z}"
        [ -n "$h" ] && say "${C_DIM}$h${C_Z}"
    fi
    return 0
}

# ── 3. l echelle ─────────────────────────────────────────────────────────────
etape_echelle() {
    titre "3. echelle banc-max.sh --dsp --continue${ONLY:+ --only=$ONLY}"
    [ -x "$TESTS/banc-max.sh" ] || { ko "$TESTS/banc-max.sh absent"; return 1; }
    local log=/var/log/osmocom/dsp-rom-max-echelle.log
    mkdir -p /var/log/osmocom
    ( cd "$TESTS" && CALYPSO_NO_ATTACH=1 OSMO_NO_ATTACH=1 bash ./banc-max.sh --dsp --continue ${ONLY:+--only=$ONLY} ) > "$log" 2>&1
    local rc=$?
    grep -a 'ELEMENT MAX' "$log" | tail -1 | sed 's/^/  /'
    grep -aE '^\s+[a-z0-9-]+\s+(OK|ECHEC|SAUTE)' "$log" | sed 's/^/  /' | head -20
    [ "$rc" -eq 0 ] && ok "echelle : aucun barreau en echec" || warn "echelle : $rc barreau(x) en echec - $log"
    return 0
}

# ── 4. le bilan ROM / hote ──────────────────────────────────────────────────
etape_bilan() {
    titre "4. bilan ROM / hote"
    local rap; rap="$(ls -t /root/banc-max-*/couverture.txt 2>/dev/null | head -1)"
    [ -n "$rap" ] || { ko "aucun /root/banc-max-*/couverture.txt (le barreau couverture n a pas joue)"; return 1; }
    say "rapport : $rap"
    python3 -I - "$rap" <<'PY'
import re, sys
txt = open(sys.argv[1], errors='replace').read()
m = re.search(r'chemin ROM / hote du traitement du signal.*?\n(.*?)\nchemin : (\d+) ROM, (\d+) hote, (\d+) mixte, (\d+) non observe', txt, re.S)
if not m:
    print("  [KO] section « chemin ROM / hote » absente du rapport"); sys.exit(1)
rom, hote, mixte, nobs = map(int, m.group(2, 3, 4, 5))
rows = []
for l in m.group(1).splitlines():
    r = re.match(r'^  (.{44}) (ROM|HOTE|MIXTE|NON OBSERVE)\s+(\d+)\s+(\d+)\s+(.*)$', l)
    if r: rows.append((r.group(1).strip(), r.group(2), int(r.group(3)), int(r.group(4)), r.group(5)))
attendu_rom = [r for r in rows if r[4].startswith('ROM')]
hote_constr = [r for r in rows if r[4].startswith('hote')]
print("  %-46s %-12s %s" % ("TRAITEMENT", "VERDICT", "rom/hote"))
for t, v, nr, nh, ch in rows:
    tag = {"ROM": "[ OK ]", "HOTE": "[ KO ]", "MIXTE": "[ !! ]", "NON OBSERVE": "[ -- ]"}[v]
    if v == "HOTE" and ch.startswith('hote'): tag = "[hote]"
    print("  %s %-39s %-12s %d/%d" % (tag, t[:39], v, nr, nh))
print()
print("  ROM %d, hote %d, mixte %d, non observe %d" % (rom, hote, mixte, nobs))
bad = [r for r in attendu_rom if r[1] in ("HOTE", "MIXTE")]
if bad:
    print("  A CORRIGER (chemin ROM attendu, l hote a pris la main) :")
    for t, v, nr, nh, ch in bad: print("    - %s : %s (rom=%d hote=%d) — %s" % (t, v, nr, nh, ch))
else:
    print("  [ OK ] tout ce qui a un chemin ROM est passe par la ROM")
print("  RESTE A BRANCHER SUR LA ROM (hote par construction) :")
for t, v, nr, nh, ch in hote_constr: print("    - %s — %s" % (t, ch))
PY
}

while [ $# -gt 0 ]; do
    case "$1" in
        run|profile|report|status) ACTION="$1" ;;
        --no-restart) RESTART=0 ;;
        --only=*) ONLY="${1#*=}" ;;
        --fw-gprs) FWGPRS=1 ;;
        --fw-stock) FWGPRS=0 ;;
        --parole-rom) PAROLE_ROM=1 ;;
        --parole-hote) PAROLE_ROM=0; VOCODEUR_ROM=0 ;;
        --vocodeur-rom) VOCODEUR_ROM=1; PAROLE_ROM=1 ;;
        --vocodeur-hote) VOCODEUR_ROM=0 ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "a lancer en root" >&2; exit 1; }
case "$ACTION" in
    profile) etape_profil ;;
    report)  etape_bilan ;;
    status)  systemctl is-active osmo-banc; grep -E '^[A-Z_]+=' "$DEFAULTS" 2>/dev/null | sed 's/^/  /'; port_open $MOB_VTY && echo "  mobile DSP : VTY :$MOB_VTY ouverte" ;;
    run)     etape_profil; etape_banc || exit 1; etape_echelle; etape_bilan ;;
esac
