# 08-mobile-ms1.sh - part of start.sh (mobile.cfg of MS#1)
# Sourced by start.sh in the main shell: same order, same variables.
say_begin "Generation mobile MS#1"
MS1_CFG="${MOBILE_CFG_MS1_PATH:-$BB_DIR/mobile.cfg}"
generate_mobile_cfg "$MS1_CFG" \
    4247 \
    /tmp/osmocom_l2 \
    "${SAP_SOCK:-/tmp/osmocom_sap}" \
    "$MS_ARFCN1" \
    "$(ms_imsi 1)" \
    "$(ms_ki 1)"
# The copy the launcher really opens. It is REGENERATED rather than copied:
# generate_mobile_cfg also sets the VTY port, the sockets and the ARFCN, and a
# plain cp would propagate the static qosmo file.
# ── AND IT IS PROTECTED FROM BEING OVERWRITTEN ──────────────────────────
# Writing this file is not enough: run.sh REWRITES it right after. Its module
# 20-mobile-cfg.sh copies MOBILE_CFG_SRC over it, and that path defaults to
# $QEMU_TREE/cfgs/mobile_group1.cfg - the static qosmo file, frozen on
# operator 1 (imsi=001010001000001 arfcn=514), which the mobile would open.
# So OUR file is designated as the source: the module then copies the right
# content, and its idempotence check (cmp -s src dest) passes since both are
# identical. No change to qosmo.
export MOBILE_CFG_SRC="$MS1_CFG"

