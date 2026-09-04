#!/bin/bash
# iso_modules/87-lite.sh - etape 8c : elagage lite du rootfs
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 8c : LITE = la normale MOINS les ateliers, sur le rootfs ──────────
# [2026-09-03] Plus de Dockerfile.lite ici : on retire du rootfs ce que
# Dockerfile.lite retirait de l image, avec les memes regles (voir son en-tete
# pour le pourquoi de chaque exception). Ce qui reste dans /opt/GSM :
#   qosmo-grgsm/          l arbre entier, build/ reduit a qemu-system-arm et
#                         qemu-bundle (QEMU se relocalise par lui)
#   osmocom-bb/           osmocon (le chargeur) et trx_toolkit (fake_trx.py)
#   firmware/ qemu-install/ osmo-operator/ pont/ osmo-egprs-web/ qemu/ qosmo-dsp/
#   *.bin *.py *.txt      ROM DSP, scripts de pont, calypso_dsp.txt
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
    for _q in qosmo-grgsm qosmo-dsp; do
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


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
