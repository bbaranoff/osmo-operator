# =============================================================================
#  45-calypso - le telephone emule : firmware, qosmo, c54x_exe, grgsm_exe
# =============================================================================
#  [2026-10-03] Chaque depot porte son installeur, au meme contrat que ce
#  dossier (check / done / run / verify) :
#     qosmo/install.sh       venv, configure --enable-l1-grgsm, make, make install, PATH
#     c54x_exe/install.sh    make (sources de qosmo, libosmocoding), ROM DSP, controle
#     grgsm_exe/install.sh   make (sources de qosmo), controle a l abri du banc
#  Ce module ne fait que cloner ce qui manque et les appeler, dans l ordre ou
#  ils dependent les uns des autres : c54x_exe et grgsm_exe compilent les
#  SOURCES de qosmo. Le Dockerfile (stages qemu et l1), Dockerfile.run,
#  start.sh et l ISO appellent les MEMES scripts : une liste de commandes par
#  composant, pas quatre.
#
#  Le firmware osmocom-bb (layer1.highram.{elf,bin}) est PREBUILT : un clone,
#  rien a compiler (Dockerfile:585-588 ; « le seul endroit consulte »,
#  Dockerfile:590-598).
#
#  Un depot deja clone est laisse tel quel (comme 30-sources) ; --reinstall le
#  met a jour (git pull --ff-only) et rejoue son installeur. Le detail de chaque
#  installeur est dans ses journaux ($LOG_DIR/<depot>/, un par etape), la fin
#  s affiche ici en cas d echec.
#
#  Les quatre etapes forment le groupe « calypso » : sudo ./install.sh --only calypso
#  Variables : GSM_ROOT (/opt/GSM) ; QOSMO (defaut $GSM_ROOT/qosmo) ;
#  CALYPSO_GIT=<base> pour cloner ailleurs que github.com/bbaranoff.
# -----------------------------------------------------------------------------
: "${CALYPSO_GIT:=https://github.com/bbaranoff}"
_CAL_QOSMO="${QOSMO:-$GSM_ROOT/qosmo}"
_CAL_C54X="$GSM_ROOT/c54x_exe"
_CAL_GRGSM="$GSM_ROOT/grgsm_exe"
_CAL_FW="$GSM_ROOT/firmware"
_CAL_FW_ELF="$_CAL_FW/board/compal_e88/layer1.highram.elf"

# _cal_depot DOSSIER URL [options de git clone] : clone s il manque ; sous
# --reinstall, avance rapide seulement (on ne reecrit pas un travail local).
_cal_depot() {
    local dir="$1" url="$2"; shift 2
    if have_repo "$dir"; then
        if [ "${REINSTALL:-0}" = 1 ]; then
            inst_say "$(basename "$dir") : deja present, mise a jour (git pull --ff-only)"
            GIT_TERMINAL_PROMPT=0 git -C "$dir" pull --ff-only \
                || inst_say "$(basename "$dir") : mise a jour impossible (modifications locales ?), laisse tel quel"
        else
            inst_say "$(basename "$dir") : deja present, laisse tel quel"
        fi
        return 0
    fi
    [ -e "$dir" ] && { inst_fail "$dir existe mais n est pas un depot git"; return 1; }
    inst_say "clonage $url -> $dir"
    GIT_TERMINAL_PROMPT=0 git clone "$@" "$url" "$dir" || { inst_fail "echec du clonage de $url"; return 1; }
}
# _cal_installeur DEPOT ARGS... : appelle <depot>/install.sh. Un depot clone
# avant le 2026-10-03 n a pas d installeur : on le dit au lieu d echouer en
# « No such file or directory ».
_cal_installeur() {
    local dir="$1"; shift
    if [ ! -f "$dir/install.sh" ]; then
        inst_hint "git -C $dir pull --ff-only, puis relancer (ou sudo ./install.sh --reinstall --only calypso)"
        inst_fail "$dir/install.sh absent : depot anterieur a l installeur"
        return 1
    fi
    local rc journal="$LOGDIR/$(basename "$dir")"
    GSM_ROOT="$GSM_ROOT" QOSMO="$_CAL_QOSMO" LOG_DIR="$journal" bash "$dir/install.sh" --with-deps \
        $([ "${REINSTALL:-0}" = 1 ] && echo --reinstall) "$@"
    rc=$?
    [ $rc -eq 0 ] && return 0
    inst_hint "journaux de l installeur : $journal/"
    inst_fail "$(basename "$dir")/install.sh a echoue (code $rc)"
    return 1
}
_cal_check_git() { have_repo "$1" || have_cmd git || { inst_fail "git absent (il faut cloner $1)"; return $INST_RC_FAIL; }; inst_ok; }

# ── firmware ──────────────────────────────────────────────────────────────────
INST_REGISTER firmware "Firmware Calypso prebuilt (layer1)"
INST_DEPS[firmware]="prereqs"
INST_GROUP[firmware]=calypso
inst_firmware_check()  { _cal_check_git "$_CAL_FW"; }
inst_firmware_done()   { have_file "$_CAL_FW_ELF" && have_file "${_CAL_FW_ELF%.elf}.bin"; }
inst_firmware_run() {
    # Dockerfile:586-587 : git clone --depth 1 https://github.com/bbaranoff/firmware /opt/GSM/firmware
    mkdir -p "$GSM_ROOT" || { inst_fail "impossible de creer $GSM_ROOT"; return $INST_RC_FAIL; }
    _cal_depot "$_CAL_FW" "$CALYPSO_GIT/firmware" --depth 1 || return $INST_RC_FAIL
    inst_ok
}
inst_firmware_verify() {
    inst_firmware_done && inst_ok || inst_fail "layer1.highram.{elf,bin} absents de $_CAL_FW/board/compal_e88"
}

# ── qosmo ─────────────────────────────────────────────────────────────────────
INST_REGISTER qosmo "QEMU Calypso (qosmo/install.sh)"
INST_DEPS[qosmo]="prereqs deps"
INST_GROUP[qosmo]=calypso
INST_TIMEOUT[qosmo]=5400
inst_qosmo_check() { _cal_check_git "$_CAL_QOSMO"; }
inst_qosmo_done()  { [ -x "$_CAL_QOSMO/build/qemu-system-arm" ]; }
inst_qosmo_run() {
    mkdir -p "$GSM_ROOT" || { inst_fail "impossible de creer $GSM_ROOT"; return $INST_RC_FAIL; }
    _cal_depot "$_CAL_QOSMO" "$CALYPSO_GIT/qosmO" || return $INST_RC_FAIL
    _cal_installeur "$_CAL_QOSMO" || return $INST_RC_FAIL
    inst_ok
}
inst_qosmo_verify() {
    "$_CAL_QOSMO/build/qemu-system-arm" -M help 2>/dev/null | grep -q '^calypso' \
        && inst_ok || inst_fail "$_CAL_QOSMO/build/qemu-system-arm ne connait pas la machine calypso"
}

# ── c54x_exe ──────────────────────────────────────────────────────────────────
# Il compile les SOURCES de qosmo : on les clone s il le faut, sans construire
# (sous --only c54x, l etape qosmo n est pas jouee).
INST_REGISTER c54x "DSP C54x + ROM (c54x_exe/install.sh)"
INST_DEPS[c54x]="qosmo"
INST_GROUP[c54x]=calypso
inst_c54x_check() { _cal_check_git "$_CAL_C54X"; }
inst_c54x_done()  { [ -x "$_CAL_C54X/c54x_exe" ] && have_file "$GSM_ROOT/calypso_dsp.PROM0.bin"; }
inst_c54x_run() {
    mkdir -p "$GSM_ROOT" || { inst_fail "impossible de creer $GSM_ROOT"; return $INST_RC_FAIL; }
    _cal_depot "$_CAL_QOSMO" "$CALYPSO_GIT/qosmO" || return $INST_RC_FAIL
    _cal_depot "$_CAL_C54X" "$CALYPSO_GIT/c54x_exe" || return $INST_RC_FAIL
    _cal_installeur "$_CAL_C54X" --rom-dir "$GSM_ROOT" --rom-dir "$_CAL_C54X/rom" || return $INST_RC_FAIL
    inst_ok
}
inst_c54x_verify() { inst_c54x_done && inst_ok || inst_fail "c54x_exe ou la ROM DSP ($GSM_ROOT/calypso_dsp.*.bin) absents"; }

# ── grgsm_exe (optionnel : outil de banc, ne fait pas camper le mobile) ───────
# Pas de « deja fait » : son binaire est SUIVI par git, un clone frais le porte
# deja sans qu il ait ete compile ici. La compilation prend une seconde.
INST_REGISTER grgsm-exe "L1 gr-gsm (grgsm_exe/install.sh)"
INST_DEPS[grgsm-exe]="qosmo"
INST_GROUP[grgsm-exe]=calypso
INST_REQUIRED[grgsm-exe]=0
inst_grgsm_exe_check() { _cal_check_git "$_CAL_GRGSM"; }
inst_grgsm_exe_run() {
    mkdir -p "$GSM_ROOT" || { inst_fail "impossible de creer $GSM_ROOT"; return $INST_RC_FAIL; }
    _cal_depot "$_CAL_QOSMO" "$CALYPSO_GIT/qosmO" || return $INST_RC_FAIL
    _cal_depot "$_CAL_GRGSM" "$CALYPSO_GIT/grgsm_exE" || return $INST_RC_FAIL
    _cal_installeur "$_CAL_GRGSM" || return $INST_RC_FAIL
    inst_ok
}
inst_grgsm_exe_verify() { [ -x "$_CAL_GRGSM/grgsm_exe" ] && inst_ok || inst_fail "$_CAL_GRGSM/grgsm_exe absent"; }
