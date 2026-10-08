#!/bin/bash
# iso_modules/51-softsim.sh - etape 5a ter : softSIM (SIM via SAP, Osmocom)
# Source par build-iso.sh, dans l ordre des numeros. `return` en tete = rien a faire.
#
# softSIM (Ruby) : clone depuis gitea.osmocom.org dans /opt/GSM/softsim, avec son .git.
# Ruby 3.2+ : File.exists? et Fixnum n existent plus ; le shim tools/softsim/ruby_compat.rb
# est pose dans /usr/local/share/softsim/ (usage : ruby -r<shim> demo_server.rb ...).
# Ruby et ruby-libxml sont dans PKGS de 80-chroot.sh.
#
# Desactivable : --no-softsim (OSMO_ISO_SOFTSIM=0).
if [ "${OSMO_ISO_SOFTSIM:-1}" != "1" ]; then
    echo -e "${YELLOW}[5a/9] softSIM desactive (--no-softsim)${NC}"
    return 0
fi

SOFTSIM_REPO="${OSMO_SOFTSIM_REPO:-https://gitea.osmocom.org/sim-card/softsim.git}"
SOFTSIM_LOCAL="${OSMO_SOFTSIM_LOCAL:-/opt/GSM/softsim}"
SOFTSIM_TREE="$ROOTFS/opt/GSM/softsim"
SOFTSIM_TMP="$WORK/softsim-clone"
echo -e "${GREEN}[5a/9] softSIM (SIM via SAP)...${NC}"
rm -rf "$SOFTSIM_TMP"
if [ "$OSMO_ISO_INHERITED" = "1" ] && [ -d "$SOFTSIM_TREE/.git" ]; then
    echo -e "  ${GREEN}✓${NC} softSIM : arbre du rootfs herite conserve"
elif GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$SOFTSIM_REPO" "$SOFTSIM_TMP" >/dev/null 2>&1; then
    rm -rf "$SOFTSIM_TREE"
    mkdir -p "$ROOTFS/opt/GSM"
    mv "$SOFTSIM_TMP" "$SOFTSIM_TREE"
    echo -e "  ${GREEN}✓${NC} softSIM clone ($(git -C "$SOFTSIM_TREE" log -1 --format='%h %s'))"
else
    rm -rf "$SOFTSIM_TMP"
    echo -e "  ${YELLOW}⚠${NC} softSIM : clone impossible (reseau ?)" >&2
fi
# Copie locale de reference, si l hote en a une (comme 51-shannon.sh)
if [ -d "$SOFTSIM_LOCAL" ] && [ "$SOFTSIM_LOCAL" != "$SOFTSIM_TREE" ]; then
    mkdir -p "$SOFTSIM_TREE"
    cp -a "$SOFTSIM_LOCAL/." "$SOFTSIM_TREE/" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} softSIM : copie locale de $SOFTSIM_LOCAL posee" \
        || echo -e "  ${YELLOW}⚠${NC} softSIM : copie locale incomplete" >&2
fi

# Shim Ruby 3.2+ : depuis le depot de construction
if [ -f "$DIR/tools/softsim/ruby_compat.rb" ]; then
    install -Dm644 "$DIR/tools/softsim/ruby_compat.rb" "$ROOTFS/usr/local/share/softsim/ruby_compat.rb"
    echo -e "  ${GREEN}✓${NC} shim Ruby : /usr/local/share/softsim/ruby_compat.rb"
fi

true
