# iso_modules/80-chroot.d/40-sim.sh - lecteur PC/SC, pySim (tools/osmo-sim-install.sh).
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# ── SIM: PC/SC reader (HID Omnikey), softSIM as a reader, pySim ───────────
# Same code as addition.sh --sim: tools/osmo-sim-install.sh (placed in the
# rootfs by 50-injection). Installs pcscd, libccid, pcsc-tools, opensc, pyscard,
# ruby/ruby-libxml (apt), the smartcard gem (softSIM in pcsc mode: the reader
# card served over SAP) and pySim (from git) in /opt/GSM/pysim-venv. softSIM
# itself is already installed (51-softsim.sh, host side): OSMO_SIM_SOFTSIM=0.
# Non-fatal. Skipped on the inter-STP hub (no mobile) and with --no-softsim
# (OSMO_ISO_SOFTSIM=0).
if [ "$ISO_ROLE" != "interstp" ] && [ "${OSMO_ISO_SOFTSIM:-1}" = "1" ]; then
    _SIMI=/opt/GSM/osmo-operator/tools/osmo-sim-install.sh
    if [ -f "$_SIMI" ]; then
        ( . "$_SIMI" && OSMO_SIM_SOFTSIM=0 REPO=/opt/GSM/osmo-operator osmo_sim_install ) \
            || echo "  WARN: osmo_sim_install a echoue (SIM par lecteur / pySim non poses, non fatal)"
    else
        echo "  WARN: $_SIMI absent -- pas de pcscd/pySim dans l image"
    fi
fi

true
