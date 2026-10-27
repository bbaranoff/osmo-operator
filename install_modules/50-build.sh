# 50-build - compilation. The long step: hence the large timeout and the detailed log.
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

    # toast: GSM 06.10 codec (quut.com). libgsm1 ships the library, not the
    # binary. Sources under $GSM_ROOT, binary in /usr/local/bin. Optional: a
    # failure (network, quut.com unreachable) does not stop the installation.
    inst_say "=== toast (codec GSM 06.10) ==="
    if command -v toast >/dev/null 2>&1; then
        inst_say "toast deja present ($(command -v toast))"
    else
        local gver=gsm-1.0.24
        local gdir=gsm-1.0-pl24   # the tarball extracts UNDER this name
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
    # ── 4G: srsRAN (ZeroMQ) and Open5GS in /opt/LTE ──────────────────────
    # Same script as the Dockerfile and addition.sh (tools/osmo-lte-install.sh):
    # cached .deb packages if present, compilation otherwise. Non-fatal: 2G
    # does not depend on it.
    inst_say "=== la 4G (srsRAN ZeroMQ + Open5GS) ==="
    if [ -f "$INST_TREE/tools/osmo-lte-install.sh" ]; then
        OSMO_REPO="$INST_TREE" bash "$INST_TREE/tools/osmo-lte-install.sh" --all \
            || inst_hint "4G non installee (voir ci-dessus) - « osmo-lte-install --build » plus tard"
    fi
    inst_ok
}
inst_build_verify() {
    have_file "$GSM_ROOT/osmocom-bb/src/host/layer23/src/mobile/mobile" \
        || { inst_fail "le binaire mobile n'a pas ete produit"; return $INST_RC_FAIL; }
    inst_ok
}
