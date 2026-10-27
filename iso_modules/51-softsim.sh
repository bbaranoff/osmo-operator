#!/bin/bash
# iso_modules/51-softsim.sh - step 5a ter: softSIM (SIM over SAP, Osmocom)
# Sourced by build-iso.sh in numeric order. A `return` at the top = nothing to do.
#
# softSIM (Ruby): cloned from gitea.osmocom.org into /opt/GSM/softsim, with its .git.
# Ruby 3.2+: File.exists? and Fixnum no longer exist; the shim tools/softsim/ruby_compat.rb
# is installed in /usr/local/share/softsim/ (usage: ruby -r<shim> demo_server.rb ...).
# Ruby and ruby-libxml are in PKGS of 80-chroot.sh.
#
# Environment:
#   OSMO_ISO_SOFTSIM=0     disable (--no-softsim)
#   OSMO_SOFTSIM_REPO      git URL to clone
#   OSMO_SOFTSIM_LOCAL     local reference copy on the host (default /opt/GSM/softsim)
#   OSMO_SIM_IMSI          IMSI of the generated sim-op1.xml (default 001010001000001)
if [ "${OSMO_ISO_SOFTSIM:-1}" != "1" ]; then
    echo -e "${YELLOW}[5a/9] softSIM desactive (--no-softsim)${NC}"
    return 0
fi

# The inter-STP hub has no SIM to emulate (no MS): 50-injection already skips
# its /opt/GSM, so softsim is not cloned for it.
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${CYAN}[5a/9] Role inter-STP : pas de softSIM (hub M3UA)${NC}"
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
# Local reference copy, if the host has one (same as 51-shannon.sh)
if [ -d "$SOFTSIM_LOCAL" ] && [ "$SOFTSIM_LOCAL" != "$SOFTSIM_TREE" ]; then
    mkdir -p "$SOFTSIM_TREE"
    cp -a "$SOFTSIM_LOCAL/." "$SOFTSIM_TREE/" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} softSIM : copie locale de $SOFTSIM_LOCAL posee" \
        || echo -e "  ${YELLOW}⚠${NC} softSIM : copie locale incomplete" >&2
fi

# COMP128v1 for the SIM (HLR Ki): lib/comp128.rb + patches of simos_server.rb.
# Each patch is applied only once (an already patched local tree keeps it).
if [ -d "$SOFTSIM_TREE/src" ] && [ -f "$DIR/tools/softsim/comp128.rb" ]; then
    install -Dm644 "$DIR/tools/softsim/comp128.rb" "$SOFTSIM_TREE/src/lib/comp128.rb"
    # ALL patches of tools/softsim (0001 COMP128v1, 0002 next client, 0003
    # timestamped log, 0004 idempotent pcsc disconnect), as tools/osmo-sim-install.sh does.
    for _sp in "$DIR"/tools/softsim/*.patch; do
        [ -f "$_sp" ] || continue
        if git -C "$SOFTSIM_TREE" apply --check -R "$_sp" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} softSIM : $(basename "$_sp") deja present"
        elif git -C "$SOFTSIM_TREE" apply "$_sp" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} softSIM : $(basename "$_sp") applique"
        else
            echo -e "  ${YELLOW}⚠${NC} softSIM : $(basename "$_sp") ne s applique pas" >&2
        fi
    done
    unset _sp
    # SIM of the HLR subscriber (IMSI 001010001000001): the Ki comes from SOFTSIM_KI
    if python3 "$DIR/tools/softsim/make_sim_op1.py" "$SOFTSIM_TREE/src/sim.xml" \
            "$SOFTSIM_TREE/src/sim-op1.xml" --imsi "${OSMO_SIM_IMSI:-001010001000001}" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} softSIM : sim-op1.xml (IMSI ${OSMO_SIM_IMSI:-001010001000001})"
    else
        echo -e "  ${YELLOW}⚠${NC} softSIM : sim-op1.xml non genere" >&2
    fi
fi

# Ruby 3.2+ shim: from the build repo
if [ -f "$DIR/tools/softsim/ruby_compat.rb" ]; then
    install -Dm644 "$DIR/tools/softsim/ruby_compat.rb" "$ROOTFS/usr/local/share/softsim/ruby_compat.rb"
    echo -e "  ${GREEN}✓${NC} shim Ruby : /usr/local/share/softsim/ruby_compat.rb"
fi

true
