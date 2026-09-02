# 50-build - compilation. L'etape longue : d'ou le timeout large et le journal detaille.
INST_REGISTER build "Compilation des sources"
INST_DEPS[build]="deps sources"
INST_TIMEOUT[build]=5400

_BUILD_ORDER="libosmo-dsp osmocom-bb osmo-gapk"

inst_build_done() { have_file "$GSM_ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile"; }
inst_build_run() {
    local d
    for d in $_BUILD_ORDER; do
        [ -d "$GSM_ROOT/$d" ] || { inst_say "$d absent, ignore"; continue; }
        inst_say "=== $d ==="
        ( cd "$GSM_ROOT/$d" || exit 1
          [ -x ./configure ] || [ -f ./configure.ac ] && { autoreconf -fi || true; }
          [ -x ./configure ] && ./configure
          make -j"$(nproc)" ) || { inst_hint "detail dans le journal de cette etape"
                                   inst_fail "echec de compilation : $d"; return $INST_RC_FAIL; }
    done

    # toast : codec GSM 06.10 (quut.com). libgsm1 fournit la lib, pas le binaire.
    # Sources sous $GSM_ROOT, binaire dans /usr/local/bin. Optionnel : un echec
    # (reseau, quut.com injoignable) n arrete pas l installation.
    inst_say "=== toast (codec GSM 06.10) ==="
    if command -v toast >/dev/null 2>&1; then
        inst_say "toast deja present ($(command -v toast))"
    else
        local gver=gsm-1.0.24
        local gdir=gsm-1.0-pl24   # le tarball se decompresse SOUS ce nom
        local gurl="https://www.quut.com/gsm/${gver}.tar.gz"
        if ( cd "$GSM_ROOT" \
             && wget -qO "${gver}.tar.gz" "$gurl" \
             && tar xzf "${gver}.tar.gz" \
             && cd "$gdir" \
             && { make >/dev/null 2>&1 || true; } \
             && { [ -x bin/toast ] || make toast >/dev/null 2>&1 || true; } \
             && [ -x bin/toast ] ); then
            for b in toast untoast tcat; do
                [ -e "$GSM_ROOT/$gdir/bin/$b" ] \
                    && install -m755 "$GSM_ROOT/$gdir/bin/$b" "/usr/local/bin/$b"
            done
            inst_say "toast installe dans /usr/local/bin (sources : $GSM_ROOT/$gdir)"
        else
            inst_hint "toast non compile (reseau ou quut.com injoignable) - suite sans lui"
        fi
    fi
    inst_ok
}
inst_build_verify() {
    have_file "$GSM_ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" \
        || { inst_fail "le binaire mobile n'a pas ete produit"; return $INST_RC_FAIL; }
    inst_ok
}
