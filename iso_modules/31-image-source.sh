#!/bin/bash
# iso_modules/31-image-source.sh - ISO source image, suite check, run image
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── The source image ─────────────────────────────────────────────────────────
# osmocom-nitb for everyone (a single build), except the hub requested ALONE:
# osmocom-stp, built at step 1. In an --all pass the hub also takes
# osmocom-nitb (which carries osmo-stp): an osmocom-stp image left over from
# another base must not sneak in. OSMO_ISO_SRC_IMAGE forces an image.
if [ -n "${OSMO_ISO_SRC_IMAGE:-}" ]; then
    ISO_SRC_IMAGE="$OSMO_ISO_SRC_IMAGE"
elif [ "$ISO_ROLE" = "interstp" ] && [ "${OSMO_ISO_ALL_RUN:-0}" != "1" ] \
     && docker image inspect "osmocom-stp${ISO_IMG_TAG}" >/dev/null 2>&1; then
    ISO_SRC_IMAGE="osmocom-stp${ISO_IMG_TAG}"
else
    ISO_SRC_IMAGE="${IMAGE_NITB:-osmocom-nitb}${ISO_IMG_TAG}"
fi
case "$ISO_ROLE:$ISO_LITE" in
    interstp:*) ISO_RUN_IMAGE="osmocom-stp-iso${ISO_IMG_TAG}" ;;
    *:1)        ISO_RUN_IMAGE="osmocom-run-lite-iso${ISO_IMG_TAG}" ;;
    *)          ISO_RUN_IMAGE="osmocom-run-iso-net-host${ISO_IMG_TAG}" ;;
esac
docker image inspect "$ISO_SRC_IMAGE" >/dev/null 2>&1 \
    || { echo -e "${RED}Image source ${ISO_SRC_IMAGE} introuvable${NC}" >&2; exit 1; }

# ── The image and the rootfs must be the SAME Ubuntu suite ───────────────────
# /usr/local, /root/.env and /root/.venv-qemu are copied as-is: a noble venv
# (python 3.12) on a jammy rootfs (python 3.10) has no interpreter, and the
# image's .so files need a glibc the rootfs does not have. The image's
# os-release is read and a mismatch is refused; --version=<suite> aligns them.
# OSMO_ISO_SUITE_MISMATCH_OK=1 continues anyway.
_img_suite="$(docker run --rm --entrypoint sh "$ISO_SRC_IMAGE" -c '. /etc/os-release; echo "$VERSION_CODENAME"' 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$_img_suite" ] && [ "$_img_suite" != "$ISO_SUITE" ]; then
    if [ "${OSMO_ISO_SUITE_MISMATCH_OK:-0}" = "1" ]; then
        echo -e "  ${YELLOW}⚠ image ${ISO_SRC_IMAGE} en ${_img_suite}, rootfs en ${ISO_SUITE} (OSMO_ISO_SUITE_MISMATCH_OK=1 : on continue)${NC}"
    else
        echo -e "${RED}L image ${ISO_SRC_IMAGE} est construite sur ${_img_suite}, le rootfs demande est ${ISO_SUITE}.${NC}" >&2
        echo -e "${RED}Relancez avec --version=${_img_suite}, ou reconstruisez l image (./build.sh) sur la base voulue.${NC}" >&2
        exit 1
    fi
fi
echo -e "  ${GREEN}✓${NC} image source ${CYAN}${ISO_SRC_IMAGE}${NC} (${_img_suite:-suite inconnue}) -> rootfs ${CYAN}${ISO_SUITE}${NC}"
TMP_CID="$(docker create "$ISO_SRC_IMAGE" /bin/sh)"

# The hub carries NO operator: only the hub config is pushed, and the
# operator's osmo-stp.cfg (point code 1.1.2, docker local-ip) is removed so
# that two STP configurations never coexist in /etc/osmocom (start-interstp.sh
# discriminates by the NAME of the config file passed to osmo-stp). The rest of
# /etc/osmocom (run.sh, status.sh, check.sh, entrypoint.sh) is still needed:
# the osmocom-stp image starts from a bare ubuntu:22.04.
if [ "$ISO_ROLE" = "interstp" ]; then
    rm -f "$TEMP_CONFIG/osmocom/osmo-stp.cfg"
fi
docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
# The hub has no Asterisk: no SIP configs for it (the image has no /etc/asterisk).
[ "$ISO_ROLE" = "interstp" ] || \
    docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prete"

# ── Step 3: none - NATIVE ISO, the Docker image is NOT embedded ──────────────
# The osmocom-run image is only a build SOURCE (docker cp of binaries and
# configs into the rootfs at step 5). No docker at runtime, no multi-GB tarball.


# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true
