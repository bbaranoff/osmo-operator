#!/bin/bash
# =============================================================================
# scripts/dsp-rom-max.sh - workflow « the DSP does as much as possible in ROM ».
# =============================================================================
#
# The DSP bench (c54x_exe, TI mask-ROM) can replace some ROM processing with
# host reconstructions (pont.py, montant.c, qosmo): canned SB/TOA, RACH coded
# by the bridge, uplink xCCH coding by the bridge, A5 deciphering by the
# bridge... Each deviation is an environment switch (hacks_actifs() in
# c54x_exe/src/pont.c prints them at startup). This workflow:
#
#   1. profil     writes the « ROM max » profile to /etc/default/osmo-banc:
#                 every switch that has a ROM path is on ROM, no canned SB/TOA.
#                 Persistent: every boot of the bench reads it.
#   2. banc       restarts osmo-banc (--dsp) with this profile and waits for
#                 camping (mobile VTY 4247).
#   3. echelle    runs the ladder of /opt/GSM/tests/banc-max.sh --dsp on the
#                 running stack: LU, SMS MO/MT, voice call, then the
#                 « couverture » rung (tests/modules/99-couverture.sh), which
#                 decides, processing by processing, ROM or HOST from the logs.
#   4. bilan      reads couverture.txt back: what the ROM did, what stayed on
#                 the host despite the profile (to fix), and what has no ROM
#                 path wired (remaining work: uplink FACCH/SACCH-TCH/speech,
#                 uplink A5 at the air fn, vocoding).
#
# Usage: dsp-rom-max.sh [run|profile|report|status] [--no-restart] [--only=camp,attache]
#   run (default)  1 -> 4            profile  write the profile only (1)
#   report         read the latest /root/banc-max-*/couverture.txt (4)
#   --no-restart   do not restart osmo-banc (the running stack already has the profile?)
#   --only=...     passed to banc-max.sh (e.g. --only=camp,attache,couverture)
#   --parole-rom   uplink TCH (speech, FACCH, SACCH/T) sent by the ROM:
#                  CALYPSO_NORM_TC=0 + CALYPSO_C54X_BCTC_NORM=1 (emulator: speech frame
#                  marker of PROM0 0x90a0) + PONT_UL_RAW_TCH=1.
#                  Default; --parole-hote reverts (and turns off --vocodeur-rom).
#   --vocodeur-rom the ROM FR codec does the vocoding (modelled SP0 voice port,
#                  calypso_vsp.c): BANC_VOCODEUR=rom (mobile in l1phy, without GAPK) +
#                  CALYPSO_VSP=1 (pont/vsp_audio.py <-> PulseAudio). Implies --parole-rom.
#                  + emulator: CALYPSO_C54X_BCD_CARRY=1 (BCD on C/NC, FR unpacking PDROM 0xe458)
#                  and CALYPSO_C54X_OVM_LOGIQUE=1 (SFTL/AND/OR/XOR/ROL do not saturate, PDROM
#                  header 0xe4c4) and CALYPSO_MAC=1 (MACR/MASR/MACA/MASA/MPYA per SPRU172C):
#                  without it the ROM FR decoder outputs a mirrored spectrum (1 kHz rendered
#                  at ~3 kHz); with it, its replay output has the libgsm spectrum.
#                  + CALYPSO_C54X_BCD_TC=1 (true TC on the 12 BCD tc/ntc: sign of the coder
#                  reflection coefficients, Schur PDROM 0xe763/0xedc5) and
#                  CALYPSO_C54X_BCTC_COMBO=1 (BC tc,nc,bio: ANDed conditions, isa 28). With
#                  these flags and the ASM shift of ADD/SUB src,ASM, the ROM FR coder is
#                  bit-exact with libgsm on ~99 % of the frames at replay.
#                  Default; --vocodeur-hote goes back to GAPK.
#   --fw-gprs      layer1 firmware with PDCH (layer1.highram.gprs.elf): the default;
#   --fw-stock     the stock firmware (without GPRS)
#
# Unit: services/osmo-dsp-rom-max.service (oneshot, started on demand: a test
# campaign has no business at boot; the profile, however, persists).
# Journal: journalctl -u osmo-dsp-rom-max; reports: /root/banc-max-<date>/
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS=/etc/default/osmo-banc
TESTS=/opt/GSM/tests
FW_GPRS=/opt/GSM/firmware/board/compal_e88/layer1.highram.gprs.elf
# --vocodeur-rom (hence --parole-rom) by default: a machine without
# /etc/default/osmo-banc would otherwise run the ROM FR codec without its
# emulator fixes (uplink silence frames, silent echo test).
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

# ── 1. the ROM max profile ───────────────────────────────────────────────────
# Each line: VARIABLE=value   # what it puts in the ROM (and the other value)
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
# MONTANT_EFFACE_TASK_RA=0  RACH: the ROM keeps the task and codes the access burst (1: the bridge codes it)
# MONTANT_ROM_UL=1          uplink SDCCH/SACCH: bursts coded by the ROM (0: host coding)
# MONTANT_ROM_TX=1          final ROM bursts published to the bridge (calypso_tx_rom)
# UL_RAW=1                  the bridge sends those bursts as is (0: recoding + A5 on the host)
# PONT_DSP_DECHIFFRE=0      downlink A5: the ROM deciphers, not the bridge
# CALYPSO_A5=1              A5 coprocessor of the silicon, modelled in c54x_exe (0: off)
# MONTANT_REQREF=0          IMMEDIATE ASSIGNMENT: BTS reference left as is (1: qosmo realigns it on last_rach)
# CALYPSO_C54X_BCTC_ETENDU=1  emulator: BC tc/ntc on the true TC after cmpr/bit/bitt and after cmpm/bitf + ST (0xb2c7, double I/Q buffer) (0: ACC heuristic)
# PONT_CAN_TOA= / PONT_CAN_SB_TOA= / PONT_CAN_SB=   nothing canned: FB/SB/TOA by the ROM
P
}
etape_profil() {
    titre "1. profil ROM max dans $DEFAULTS"
    # Without layer1.highram.gprs.elf the profile must not require it, otherwise
    # the bench refuses to start: fall back to the stock firmware.
    if [ "$FWGPRS" = 1 ] && { [ ! -r "$FW_GPRS" ] || [ ! -r "${FW_GPRS%.elf}.bin" ]; }; then
        warn "$FW_GPRS absent : firmware d origine (compiler le layer1 GPRS pour --fw-gprs)"
        FWGPRS=0
    fi
    touch "$DEFAULTS"
    # remove a previous version of the block, then write it again
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
    # No OSMO_BANC_ARGS="--dsp" here: in the unit, EnvironmentFile= takes
    # precedence over `systemctl set-environment` (launch.sh --grgsm) and the
    # bench would start in DSP whatever is asked. DSP is the start-native.sh
    # default.
    sed -i '/^OSMO_BANC_ARGS=/d' "$DEFAULTS"
    ok "profil pose ($(profil_lignes | grep -c .) commutateurs)"; grep -E '^[A-Z_]+=' "$DEFAULTS" | sed 's/^/      /'
}

# ── 2. the bench ─────────────────────────────────────────────────────────────
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

# ── 3. the ladder ────────────────────────────────────────────────────────────
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

# ── 4. the ROM / host report ────────────────────────────────────────────────
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
