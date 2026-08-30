# 00-prereqs - verifie que l'installation est utilisable, sans rien lancer.
# MOD_PURE=1 : aucun effet de bord, donc execute meme en --dry-run pour que le
# plan affiche soit exact.
MOD_REGISTER prereqs "Verification des prerequis"
MOD_REQUIRED[prereqs]=1
MOD_PURE[prereqs]=1
MOD_PROFILES[prereqs]="calypso faketrx hybrid core"

mod_prereqs_check() {
    local missing=""
    # [2026-08-30] Plus de DSP_PROM0 ici : ce module est `MOD_REQUIRED=1` sur
    # les quatre profils, donc une ROM DSP absente bloquait meme `faketrx` et
    # `core`. Les ROM ne sont plus generees depuis le merge `sans-dsp` de
    # qosmo-grgsm ; seul le mode qemu s'en sert, et 40-qemu.sh en juge lui-meme.
    for v in QEMU_BIN FIRMWARE_ELF; do
        local p="${!v:-}"
        [ -n "$p" ] && [ -e "$p" ] || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        mod_hint "reglez les chemins dans environment/paths.env, puis ./run.sh --check-paths"
        mod_fail "dependances introuvables :$missing"
        return $MOD_RC_FAIL
    fi
    mod_ok
}
mod_prereqs_start()  { mod_ok; }
mod_prereqs_status() { return $MOD_RC_FAIL; }   # module pur : jamais "deja demarre"
