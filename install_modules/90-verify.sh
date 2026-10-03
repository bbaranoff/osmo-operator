# 90-verify - controle d'ensemble. Distinct des `verify` de chaque etape :
# ici on regarde si la machine est utilisable, pas si une etape a reussi.
INST_REGISTER verify "Verification de l'installation"
INST_DEPS[verify]="binaires configs"
INST_ROOT[verify]=0

# [2026-10-03] OSMO_CORE=externe (pose par --telephone) : le coeur Osmocom est
# celui de l utilisateur, installe a sa facon, peut-etre ailleurs que dans le
# PATH. On n exige plus ses demons : seulement l osmo-bts-trx sur lequel le
# telephone se branche (UDP 5700-5702), et la chaine Calypso elle-meme.
# Sans la variable, rien ne change.
_verify_telephone() {
    local missing="" q="${QOSMO:-$GSM_ROOT/qosmo}"
    have_cmd osmo-bts-trx || systemctl cat osmo-bts-trx.service >/dev/null 2>&1 || missing="$missing osmo-bts-trx"
    [ -x "$q/build/qemu-system-arm" ]                               || missing="$missing $q/build/qemu-system-arm"
    [ -x "$GSM_ROOT/c54x_exe/c54x_exe" ]                            || missing="$missing c54x_exe"
    have_file "$GSM_ROOT/calypso_dsp.PROM0.bin"                     || missing="$missing ROM-DSP($GSM_ROOT)"
    have_file "$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf" || missing="$missing firmware"
    [ -x "$GSM_ROOT/osmocom-bb/src/host/osmocon/osmocon" ]         || missing="$missing osmocon"
    have_cmd mobile                                                 || missing="$missing mobile"
    if [ -n "$missing" ]; then
        inst_hint "osmo-bts-trx vient de VOTRE pile (teste : osmo-bts 1.10.0) ; le reste : sudo ./install.sh --telephone"
        inst_fail "absents :$missing"
        return $INST_RC_FAIL
    fi
    inst_ok
}

inst_verify_run() {
    [ "${OSMO_CORE:-}" = externe ] && { _verify_telephone; return $?; }
    local missing="" b
    for b in osmo-stp osmo-hlr osmo-msc osmo-mgw osmo-bsc; do have_cmd "$b" || missing="$missing $b"; done
    if [ -n "$missing" ]; then
        inst_hint "les demons Osmocom ne sont pas dans les depots Ubuntu par defaut : ajoutez le depot Osmocom, ou utilisez Docker (./tools/make-docker-image.sh)"
        inst_fail "demons absents :$missing"
        return $INST_RC_FAIL
    fi
    inst_ok
}
inst_verify_verify() { inst_ok; }
