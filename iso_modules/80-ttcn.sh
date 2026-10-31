#!/bin/bash
# iso_modules/80-ttcn.sh - step 8b: Osmocom TTCN-3 suites + Eclipse TITAN in the image
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not runnable on its own. Runs after 80-chroot.sh, while /proc, /dev and the
# build resolv.conf are still in the rootfs (released by 86-finitions.sh).
# Everything is in scripts/ttcn.sh; this module only calls it.
# OSMO_ISO_TTCN=0: no TTCN-3 in the image. Lite images have no /opt/GSM trees.

[ "${OSMO_ISO_TTCN:-1}" = 1 ] || { echo -e "  ${CYAN}[8b/9] TTCN-3 non embarque (OSMO_ISO_TTCN=0)${NC}"; return 0; }
[ "$ISO_LITE" = 1 ] && { echo -e "  ${CYAN}[8b/9] TTCN-3 absent de l image lite${NC}"; return 0; }

echo -e "${GREEN}[8b/9] TTCN-3 : eclipse-titan + osmo-ttcn3-hacks...${NC}"
if bash "$DIR/scripts/ttcn.sh" --root "$ROOTFS" titan sources; then
    echo -e "  ${GREEN}✓${NC} TTCN-3 pret : ${CYAN}sudo /opt/GSM/osmo-operator/scripts/ttcn.sh run hlr${NC}"
else
    echo -e "  ${YELLOW}!${NC} TTCN-3 incomplet dans l image (voir ci-dessus), construction poursuivie"
fi
true
