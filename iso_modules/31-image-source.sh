#!/bin/bash
# iso_modules/31-image-source.sh - image source de l ISO, controle de suite, image run
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── L image source ──────────────────────────────────────────────────────────
# osmocom-nitb pour tout le monde (un seul build), sauf le hub demande SEUL :
# osmocom-stp, construite a l etape 1. Dans une passe --all, le hub prend aussi
# osmocom-nitb (qui porte osmo-stp) : une image osmocom-stp restee d une autre
# base sur la machine ne doit pas s inviter. OSMO_ISO_SRC_IMAGE force une image.
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

# ── L image et le rootfs doivent etre de la MEME suite Ubuntu ───────────────
# /usr/local, /root/.env et /root/.venv-qemu sont copies tels quels : un venv
# noble (python 3.12) sur un rootfs jammy (python 3.10) n a pas d interpreteur,
# et les .so de l image cherchent une glibc que le rootfs n a pas. On lit
# l os-release de l image et on refuse le melange - --version=<suite> aligne.
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

# Le hub ne porte AUCUN operateur : lui pousser le jeu complet, c'est embarquer
# un osmo-stp.cfg de point-code 1.1.2 avec local-ip 172.20.0.11 a cote du
# osmo-stp-interop.cfg qui, lui, fait autorite. Deux configurations STP dans le
# meme /etc/osmocom, l'une morte mais plausible : on relance la mauvaise, le hub
# se presente au WAN avec le point-code d'un operateur, et le routage M3UA part
# sur une adresse du plan docker que la VM n'a jamais eue.
# On ne copie donc que la config du hub - et pas par lien symbolique : le pgrep
# de start-interstp.sh discrimine sur le NOM du fichier de conf passe a osmo-stp.
# On retire donc la config STP d'operateur - et elle seule. Ne pousser que
# osmo-stp-interop.cfg privait aussi le hub de run.sh, status.sh, check.sh et
# entrypoint.sh, que /etc/osmocom est le seul a fournir (l'image osmocom-stp
# part d'ubuntu:22.04 nu) : le chmod de l'etape 5 s'arretait alors sur un
# fichier absent et la construction du hub - donc ./build-iso.sh sans
# argument, qui commence par lui - echouait apres une heure de travail.
if [ "$ISO_ROLE" = "interstp" ]; then
    rm -f "$TEMP_CONFIG/osmocom/osmo-stp.cfg"
fi
docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
# Le hub n'a pas d'Asterisk : lui pousser des configs SIP n'aurait pas de sens,
# et l'image n'a meme pas /etc/asterisk.
[ "$ISO_ROLE" = "interstp" ] || \
    docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prete"

# ── Etape 3 : (SUPPRIME) - ISO NATIF : on n'embarque PAS l'image Docker ────
# L'image osmocom-run ne sert plus que de SOURCE de build (docker cp des binaires
# et configs vers le rootfs a l'etape 6). On ne la save plus dans l'ISO : pas de
# docker au runtime, pas de tar.gz de plusieurs Go embarque.

