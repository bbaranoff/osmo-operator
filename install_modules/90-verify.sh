# 90-verify - controle d'ensemble. Distinct des `verify` de chaque etape :
# ici on regarde si la machine est utilisable, pas si une etape a reussi.
INST_REGISTER verify "Verification de l'installation"
INST_DEPS[verify]="binaires configs"
INST_ROOT[verify]=0

inst_verify_run() {
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
