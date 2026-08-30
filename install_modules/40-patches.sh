# 40-patches - correctifs locaux. `git apply --check` d'abord : un correctif deja
# applique ne doit pas faire echouer l'installation.
INST_REGISTER patches "Application des correctifs"
INST_DEPS[patches]="sources"
INST_REQUIRED[patches]=0

_patch_target() {
    case "$(basename "$1")" in
        osmo-trx-*)   printf '%s\n' "$GSM_ROOT/osmo-trx" ;;
        osmocom-bb-*) printf '%s\n' "$GSM_ROOT/osmocom-bb" ;;
        grgsm-*)      printf '%s\n' "$GSM_ROOT/gr-gsm" ;;
        *)            printf '' ;;
    esac
}
inst_patches_run() {
    local p t n=0 skipped=0
    for p in "$INST_TREE"/patches/*.patch; do
        [ -f "$p" ] || continue
        t="$(_patch_target "$p")"
        [ -z "$t" ] || [ ! -d "$t" ] && { skipped=$((skipped+1)); continue; }
        if git -C "$t" apply --check "$p" 2>/dev/null; then
            git -C "$t" apply "$p" && { inst_say "applique : $(basename "$p")"; n=$((n+1)); }
        else
            inst_say "deja applique ou sans objet : $(basename "$p")"; skipped=$((skipped+1))
        fi
    done
    [ $n -eq 0 ] && return $INST_RC_DONE
    inst_ok
}
inst_patches_verify() { inst_ok; }
