# 40-patches - local fixes (patches/*.patch) applied to the trees under $GSM_ROOT
# by tools/osmo-patches-apply.sh (idempotent: an already applied patch is not an error).
INST_REGISTER patches "Application des correctifs"
INST_DEPS[patches]="sources"
INST_REQUIRED[patches]=0

inst_patches_run() {
    local out l n
    out="$(GSM_ROOT="$GSM_ROOT" REPO="$INST_TREE" bash "$INST_TREE/tools/osmo-patches-apply.sh" "$GSM_ROOT" 2>&1)"
    while IFS= read -r l; do [ -n "$l" ] && inst_say "${l#  }"; done <<< "$out"
    n="$(printf '%s\n' "$out" | grep -c ' -> ')"
    [ "$n" -eq 0 ] && return $INST_RC_DONE
    inst_ok
}
inst_patches_verify() { inst_ok; }
