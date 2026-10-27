#!/bin/bash
# iso_modules/87-lite.sh - step 8c: lite pruning of the rootfs
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── Step 8c: LITE = the normal image MINUS the build workshops, on the rootfs ─
# Removes from the rootfs what Dockerfile.lite removes from the image, with the
# same rules (see its header for each exception). What remains in /opt/GSM:
#   qosmo/                the whole tree, build/ reduced to qemu-system-arm and
#                         qemu-bundle (QEMU relocates itself through it)
#   osmocom-bb/           osmocon (the loader) and trx_toolkit (fake_trx.py)
#   firmware/ qemu-install/ osmo-operator/ pont/ osmo-egprs-web/ qemu/
#   c54x_exe/ grgsm_exe/   the two layer-1 stacks outside QEMU (+ c54x_exe/rom)
#   *.bin *.py *.txt      DSP ROM, bridge scripts, calypso_dsp.txt
if [ "$ISO_LITE" = "1" ]; then
    echo -e "${GREEN}[8c/9] Elagage lite : les ateliers de compilation quittent le rootfs...${NC}"
    _G="$ROOTFS/opt/GSM"
    _before=$(du -sh "$_G" 2>/dev/null | cut -f1)
    for _d in libosmocore libosmo-netif libosmo-abis libosmo-sigtran libsmpp34 libgtpnl \
              libosmo-gprs osmo-hlr osmo-mgw osmo-ggsn osmo-sgsn osmo-msc osmo-bsc osmo-trx \
              osmo-bts osmo-pcu osmo-sip-connector osmo-gapk gsup-smsc-proto libosmo-dsp \
              gnuradio gr-osmosdr gr-gsm osmocom-bb-transceiver osmocom-bb-burst_ind; do
        rm -rf "$_G/$_d"
    done
    rm -rf "$_G"/sms-coding-utils* "$_G"/*.tar.bz2 "$_G"/*.tar.gz
    if [ -d "$_G/osmocom-bb" ]; then
        _k="$WORK/keep-bb"; rm -rf "$_k"
        mkdir -p "$_k/src/host/osmocon" "$_k/src/target"
        cp -a "$_G/osmocom-bb/src/host/osmocon/osmocon" "$_k/src/host/osmocon/" 2>/dev/null || true
        cp -a "$_G/osmocom-bb/src/target/trx_toolkit"   "$_k/src/target/"      2>/dev/null || true
        rm -rf "$_G/osmocom-bb"; mv "$_k" "$_G/osmocom-bb"
    fi
    for _q in qosmo; do
        [ -d "$_G/$_q/build" ] || continue
        _k="$WORK/keep-qbuild"; rm -rf "$_k"; mkdir -p "$_k"
        cp -a "$_G/$_q/build/qemu-system-arm" "$_k/" 2>/dev/null || true
        cp -a "$_G/$_q/build/qemu-bundle"     "$_k/" 2>/dev/null || true
        rm -rf "$_G/$_q/build"; mv "$_k" "$_G/$_q/build"
    done
    rm -rf "$ROOTFS/usr/local/include" "$ROOTFS/var/cache/osmo-debs" "$ROOTFS/root/.cache" \
           "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/man"
    find "$ROOTFS/usr/local/lib" -name '*.a' -delete 2>/dev/null || true
    find "$ROOTFS" -xdev -path "$_G" -prune -o -name '*.o' -exec rm -f {} + 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} /opt/GSM : ${_before:-?} -> $(du -sh "$_G" | cut -f1)"
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would stop everything silently. Always 0 here.
true
