# 60-binaires - depot des executables dans /usr/local/bin, comme le fait le Dockerfile.
INST_REGISTER binaires "Installation des binaires"
INST_DEPS[binaires]="build"

_BINS="trxcon:src/host/trxcon/src/trxcon
mobile:src/host/layer23/src/mobile/mobile
virtphy:src/host/virt_phy/src/virtphy
ccch_scan:src/host/layer23/src/misc/ccch_scan"

inst_binaires_done() { have_cmd mobile && have_cmd trxcon; }
inst_binaires_run() {
    local line name path n=0
    while IFS=: read -r name path; do
        [ -z "$name" ] && continue
        if [ -x "$GSM_ROOT/osmocom-bb/$path" ]; then
            install -m755 "$GSM_ROOT/osmocom-bb/$path" "/usr/local/bin/$name" && n=$((n+1))
        else
            inst_say "absent, ignore : $path"
        fi
    done <<< "$_BINS"
    [ $n -eq 0 ] && { inst_fail "aucun binaire trouve a installer - la compilation a-t-elle abouti ?"; return $INST_RC_FAIL; }
    inst_say "$n binaires installes"
    inst_ok
}
inst_binaires_verify() {
    local missing="" b
    for b in mobile trxcon; do have_cmd "$b" || missing="$missing $b"; done
    [ -n "$missing" ] && { inst_fail "binaires absents du PATH :$missing"; return $INST_RC_FAIL; }
    inst_ok
}
