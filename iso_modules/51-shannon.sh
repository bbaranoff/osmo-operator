#!/bin/bash
# iso_modules/51-shannon.sh - etape 5a bis : FirmWire et shannon_ghidra_proj
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).
#
# Deux depots de bbaranoff, poses a leur chemin habituel de /opt/GSM, AVEC
# leur .git - meme schema que 51-depot.sh : clone a cote, puis bascule, pour
# qu un reseau absent laisse l arbre de l image en place.
#   - FirmWire            -> /opt/GSM/FirmWire           (download_shannon.sh)
#   - shannon_ghidra_proj -> /opt/GSM/shannon_ghidra_proj (analyse Ghidra Shannon)
#
# shannon_main.bin EST versionne dans le fork FirmWire : le clone le ramene.
# Ce qui n est PAS dans les depots, et que l ISO ne peut donc pas fournir :
#   - FirmWire/.v1/ (run_shannon_pmos.sh, modem.tar.md5.lz4) : local, perdu ;
#   - shannon_ghidra_proj/.../db.*.gbf (base Ghidra, ~1,1 Go, nom variable) : local, perdu.
# Le module le DIT au build (avertissement), il n echoue pas pour autant.

SHANNON_BRANCH="${OSMO_SHANNON_BRANCH:-main}"

# Cible shannon desactivable (--no-shannon) : rien a faire, aucune erreur.
if [ "${OSMO_ISO_SHANNON:-1}" != "1" ]; then
    echo -e "${YELLOW}[5a/9] Cible shannon desactivee (--no-shannon)${NC}"
    return 0
fi

# [2026-10-09] Le hub inter-STP ne route que du M3UA : ni modem Shannon, ni
# analyse Ghidra. 50-injection-image.sh saute deja tout /opt/GSM pour lui ; sans
# ce garde-fou on clonait quand meme FirmWire + shannon_ghidra_proj et on
# TELECHARGEAIT la base Ghidra (~1,1 Go) dans une image qui n en lit jamais une
# ligne - le gros du "en double inutilement" de la construction du hub.
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${CYAN}[5a/9] Role inter-STP : pas de Shannon/Ghidra (hub M3UA)${NC}"
    return 0
fi

# ── FirmWire (fork bbaranoff) ────────────────────────────────────────────────
FIRMWIRE_REPO="${OSMO_FIRMWIRE_REPO:-https://github.com/bbaranoff/firmwire}"
FIRMWIRE_TREE="$ROOTFS/opt/GSM/FirmWire"
FIRMWIRE_TMP="$WORK/firmwire-clone"
echo -e "${GREEN}[5a/9] Clone de FirmWire (branche ${SHANNON_BRANCH})...${NC}"
rm -rf "$FIRMWIRE_TMP"
if [ "$OSMO_ISO_INHERITED" = "1" ] && [ -d "$FIRMWIRE_TREE/.git" ]; then
    echo -e "  ${GREEN}✓${NC} FirmWire : arbre du rootfs herite conserve"
elif GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$SHANNON_BRANCH" "$FIRMWIRE_REPO" "$FIRMWIRE_TMP" >/dev/null 2>&1; then
    # Le shannon_main.bin de l arbre herite (non suivi par git) est repris s il existe,
    # sinon le clone efface le firmware pose a la main.
    if [ -f "$FIRMWIRE_TREE/shannon_main.bin" ]; then
        cp -a "$FIRMWIRE_TREE/shannon_main.bin" "$FIRMWIRE_TMP/shannon_main.bin"
    fi
    rm -rf "$FIRMWIRE_TREE"
    mkdir -p "$ROOTFS/opt/GSM"
    mv "$FIRMWIRE_TMP" "$FIRMWIRE_TREE"
    echo -e "  ${GREEN}✓${NC} FirmWire clone (${SHANNON_BRANCH}, .git conserve) - $(git -C "$FIRMWIRE_TREE" log -1 --format='%h %s')"
else
    rm -rf "$FIRMWIRE_TMP"
    if [ -d "$FIRMWIRE_TREE" ]; then
        echo -e "  ${YELLOW}⚠${NC} FirmWire : clone impossible (reseau ?) - arbre de l'image conserve" >&2
    else
        echo -e "  ${YELLOW}⚠${NC} FirmWire : clone impossible ET absent de l'image" >&2
    fi
fi

# ── shannon_ghidra_proj (bbaranoff) ──────────────────────────────────────────
SHANNON_GHIDRA_REPO="${OSMO_SHANNON_GHIDRA_REPO:-https://github.com/bbaranoff/shannon_ghidra_proj}"
SHANNON_GHIDRA_TREE="$ROOTFS/opt/GSM/shannon_ghidra_proj"
SHANNON_GHIDRA_TMP="$WORK/shannon_ghidra_proj-clone"
echo -e "${GREEN}[5a/9] Clone de shannon_ghidra_proj (branche ${SHANNON_BRANCH})...${NC}"
rm -rf "$SHANNON_GHIDRA_TMP"
if [ "$OSMO_ISO_INHERITED" = "1" ] && [ -d "$SHANNON_GHIDRA_TREE/.git" ]; then
    echo -e "  ${GREEN}✓${NC} shannon_ghidra_proj : arbre du rootfs herite conserve"
elif GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$SHANNON_BRANCH" "$SHANNON_GHIDRA_REPO" "$SHANNON_GHIDRA_TMP" >/dev/null 2>&1; then
    rm -rf "$SHANNON_GHIDRA_TREE"
    mkdir -p "$ROOTFS/opt/GSM"
    mv "$SHANNON_GHIDRA_TMP" "$SHANNON_GHIDRA_TREE"
    echo -e "  ${GREEN}✓${NC} shannon_ghidra_proj clone (${SHANNON_BRANCH}, .git conserve) - $(git -C "$SHANNON_GHIDRA_TREE" log -1 --format='%h %s')"
else
    rm -rf "$SHANNON_GHIDRA_TMP"
    if [ -d "$SHANNON_GHIDRA_TREE" ]; then
        echo -e "  ${YELLOW}⚠${NC} shannon_ghidra_proj : clone impossible (reseau ?) - arbre de l'image conserve" >&2
    else
        echo -e "  ${YELLOW}⚠${NC} shannon_ghidra_proj : clone impossible ET absent de l'image" >&2
    fi
fi

# ── Verification : ce qui manque, dit clairement, sans arreter le build ──────
if [ -f "$FIRMWIRE_TREE/shannon_main.bin" ]; then
    echo -e "  ${GREEN}✓${NC} firmware Shannon : shannon_main.bin present"
else
    echo -e "  ${YELLOW}⚠${NC} firmware Shannon : shannon_main.bin absent de l'image" >&2
fi
if [ ! -x "$FIRMWIRE_TREE/.v1/run_shannon_pmos.sh" ]; then
    echo -e "  ${YELLOW}⚠${NC} lanceur Shannon : FirmWire/.v1/run_shannon_pmos.sh absent - start-direct.sh --shannon s arretera (KO)" >&2
fi
# La base Ghidra (gitignoree dans shannon_ghidra_proj) vient de download_shannon.sh
# (SHANNON_GHIDRA_DB_URL). Si l arbre de l image ne l a pas et que l URL est
# donnee, on la telecharge ici, dans le rootfs, par la meme fonction que
# addition.sh --shannon.
if [ -f "$DIR/download_shannon.sh" ] && \
   ! find "$SHANNON_GHIDRA_TREE/shannon.rep/idata" -name 'db.*.gbf' -size +0 2>/dev/null | grep -q .; then
    # shellcheck source=download_shannon.sh
    . "$DIR/download_shannon.sh"
    SHANNON_GHIDRA_DIR="$SHANNON_GHIDRA_TREE" _shannon_ghidra_db_fetch || true
fi
# La base Ghidra change de nom a chaque reimport (~00000000.db/db.10.gbf,
# puis ~00000001.db/db.1.gbf...) : on cherche db.*.gbf non vide, n importe ou.
if ! find "$SHANNON_GHIDRA_TREE/shannon.rep/idata" -name 'db.*.gbf' -size +0 2>/dev/null | grep -q .; then
    echo -e "  ${YELLOW}⚠${NC} Ghidra : aucune base db.*.gbf dans le projet - le projet n a pas son analyse, a refaire" >&2
else
    echo -e "  ${GREEN}✓${NC} Ghidra : base d analyse presente ($(find "$SHANNON_GHIDRA_TREE/shannon.rep/idata" -name 'db.*.gbf' -size +0 | head -1 | sed "s#$ROOTFS##"))"
fi

# ── Copies locales de reference (hote -> rootfs) ─────────────────────────────
# Le clone GitHub ne porte ni FirmWire/.v1/ (image modem, scripts v1) ni le
# projet Ghidra local. Si les arbres de l hote existent, on les pose par-dessus
# l arbre clone/herite (.git compris) : la copie locale est la reference.
# cp -a sur le contenu, idempotent ; un echec n arrete pas le build.
_shannon_overlay_local() {
    local src="$1" dst="$2" label="$3"
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        if cp -a "$src/." "$dst/" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $label : copie locale de $src posee dans l image"
        else
            echo -e "  ${YELLOW}⚠${NC} $label : copie locale de $src incomplete" >&2
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} $label : pas de copie locale sur l hote ($src), arbre clone conserve" >&2
    fi
}
_shannon_overlay_local "${OSMO_FIRMWIRE_LOCAL:-/opt/GSM/FirmWire}" "$FIRMWIRE_TREE" "FirmWire"
_shannon_overlay_local "${OSMO_SHANNON_GHIDRA_LOCAL:-/opt/GSM/shannon_ghidra_proj}" "$SHANNON_GHIDRA_TREE" "shannon_ghidra_proj"

# ── c54x_exe (DSP TI C54x, cote traduction) : runtime seul ───────────────────
# Sans lui, DSP_XLATE=1 ne trouve pas /dev/shm/calypso_api_ram ni le socket du
# pont. On exclut les sources et les builds de toolchain (binutils, build-tic54x,
# tarball) : ~290 Mo bruts, le runtime tient dans une fraction de ca.
C54X_LOCAL="${OSMO_C54X_LOCAL:-/opt/GSM/c54x_exe}"
C54X_TREE="$ROOTFS/opt/GSM/c54x_exe"
if [ -d "$C54X_LOCAL" ]; then
    mkdir -p "$C54X_TREE"
    if tar -C "$C54X_LOCAL" --exclude=./binutils-2.21.1 --exclude=./binutils-2.21.1.tar.bz2 \
            --exclude=./build-tic54x -cf - . | tar -C "$C54X_TREE" -xf - 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} c54x_exe : runtime copie depuis $C54X_LOCAL"
    else
        echo -e "  ${YELLOW}⚠${NC} c54x_exe : copie incomplete depuis $C54X_LOCAL" >&2
    fi
else
    echo -e "  ${YELLOW}⚠${NC} c54x_exe : pas sur l hote ($C54X_LOCAL), DSP_XLATE restera sans C54x" >&2
fi

# Fin de module : voir la note de 51-depot.sh (build-iso.sh tourne sous set -e).
true
