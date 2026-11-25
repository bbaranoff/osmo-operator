#!/bin/bash
# iso_modules/41-socle.sh - the shared base of --all: manifest and checks.
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# --all builds the normal image, then lite (a COPY of its rootfs) and desktop
# (the rootfs itself, moved). The normal squashfs is written before the hand
# over, so a later pass cannot alter the normal ISO; what can go wrong is the
# hand over itself (a copy cut short) and a later pass silently REMOVING part
# of the shared base. 90-iso.sh already checks every packaged file against its
# dpkg md5sums, but it skips /usr/local, where the osmo-build-* packages put
# the whole stack (osmo-msc, srsenb, libosmocore...). This module adds:
#   1. the MANIFEST of the base, written by 90-iso.sh in the normal pass,
#      OUTSIDE the rootfs ($OSMO_ISO_ROOTFS_KEEP.socle): installed packages
#      with their version, sha256 of the osmo-build-* programs and libraries
#      (/usr/local/bin, /usr/local/sbin, /usr/local/lib/*.so*);
#   2. right after a pass takes the rootfs over (below): STRICT check, nothing
#      may differ - nothing has run on it yet;
#   3. before each mksquashfs of a lite or desktop pass (90-iso.sh): no
#      package of the base may have disappeared (except the expected removals
#      listed here) and no osmo-build-* file may have changed. A changed
#      version is only reported (apt may update a dependency in between).
#
# Environment:
#   OSMO_ISO_SOCLE_RETRAITS="p1 p2"  packages whose removal is expected too
#   OSMO_ISO_SOCLE_TOLERANT=1        report a divergence without failing

# Packages the desktop pass removes on purpose (60-bureau, 62-firefox,
# 63-session in 80-chroot): avahi (mDNS on the bench interfaces), the Ubuntu
# firefox/chromium transition packages, pipewire-pulse.
_SOCLE_RETRAITS_BUREAU="avahi-daemon avahi-utils avahi-autoipd libnss-mdns firefox chromium-browser pipewire-pulse pipewire-media-session"
_SOCLE_CRITIQUES='^/usr/local/(s?bin/[^/]+|lib/[^/]+\.so[^/]*)$'

# Manifest of a root, on stdout. Two kinds of lines, tab separated:
#   paquet  <name>:<arch>  <version>
#   fichier <sha256>       <path>
socle_manifeste() {   # $1 = root
    local r="$1" f
    dpkg-query --admindir="$r/var/lib/dpkg" -W \
        -f='${db:Status-Abbrev}\t${Package}:${Architecture}\t${Version}\n' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^ii/ { print "paquet\t" $2 "\t" $3 }' | LC_ALL=C sort
    cat "$r"/var/lib/dpkg/info/osmo-build-*.list 2>/dev/null \
        | grep -E "$_SOCLE_CRITIQUES" | LC_ALL=C sort -u \
        | while IFS= read -r f; do
              if [ -f "$r$f" ] && [ ! -L "$r$f" ]; then
                  printf 'fichier\t%s\t%s\n' "$(sha256sum < "$r$f" | cut -c1-64)" "$f"
              fi
          done
    return 0
}

# Compare a root with a manifest. $3 = strict (right after the hand over) or
# variante (before the squashfs of lite/desktop). Exits 1 on an unexpected
# divergence, unless OSMO_ISO_SOCLE_TOLERANT=1.
socle_verifier() {   # $1 = root, $2 = manifest, $3 = strict|variante
    local r="$1" m="$2" mode="$3" now erreurs=0 p
    now="$(mktemp)"
    socle_manifeste "$r" > "$now"
    _socle_cles() { awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3 }' "$2" | LC_ALL=C sort; }
    local paq_m paq_n fic_m fic_n
    paq_m="$(mktemp)"; paq_n="$(mktemp)"; fic_m="$(mktemp)"; fic_n="$(mktemp)"
    _socle_cles paquet "$m"   > "$paq_m"; _socle_cles paquet "$now" > "$paq_n"
    awk -F'\t' '$1 == "fichier" { print $3 "\t" $2 }' "$m"   | LC_ALL=C sort > "$fic_m"
    awk -F'\t' '$1 == "fichier" { print $3 "\t" $2 }' "$now" | LC_ALL=C sort > "$fic_n"

    # Packages of the base no longer installed (expected removals put aside).
    local retraits="${OSMO_ISO_SOCLE_RETRAITS:-}"
    [ "$mode" = variante ] && [ "${ISO_DESKTOP:-0}" = "1" ] && retraits="$retraits $_SOCLE_RETRAITS_BUREAU"
    local manquants=() attendus=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [[ " $retraits " == *" ${p%%:*} "* ]]; then attendus+=("$p"); else manquants+=("$p"); fi
    done < <(LC_ALL=C comm -23 <(cut -f1 "$paq_m") <(cut -f1 "$paq_n"))
    # Changed versions, and packages added (strict only: nothing ran yet).
    local versions ajoutes=""
    versions="$(LC_ALL=C join -t $'\t' "$paq_m" "$paq_n" | awk -F'\t' '$2 != $3 { print $1 " " $2 " -> " $3 }')"
    [ "$mode" = strict ] && ajoutes="$(LC_ALL=C comm -13 <(cut -f1 "$paq_m") <(cut -f1 "$paq_n"))"
    # osmo-build-* files missing or changed.
    local fichiers
    fichiers="$(LC_ALL=C join -t $'\t' -a1 -e ABSENT -o 0,1.2,2.2 "$fic_m" "$fic_n" \
                | awk -F'\t' '$2 != $3 { print $1 ($3 == "ABSENT" ? " (absent)" : " (modifie)") }')"
    rm -f "$now" "$paq_m" "$paq_n" "$fic_m" "$fic_n"

    _socle_liste() {   # $1 = title, then the lines
        local t="$1"; shift
        echo -e "  ${RED}✗ socle ($mode) : $t${NC}"
        printf '%s\n' "$@" | head -20 | sed 's/^/      /'
        [ "$#" -gt 20 ] && echo "      ... ($# en tout)"
        return 0
    }
    if [ "${#manquants[@]}" -gt 0 ]; then
        _socle_liste "${#manquants[@]} paquet(s) du socle ont disparu" "${manquants[@]}"; erreurs=1
    fi
    if [ -n "$fichiers" ]; then
        mapfile -t _l <<< "$fichiers"; _socle_liste "${#_l[@]} fichier(s) osmo-build-* absents ou modifies" "${_l[@]}"; erreurs=1
    fi
    if [ -n "$versions" ]; then
        mapfile -t _l <<< "$versions"
        if [ "$mode" = strict ]; then _socle_liste "${#_l[@]} version(s) changee(s)" "${_l[@]}"; erreurs=1
        else echo -e "  ${YELLOW}!${NC} socle : ${#_l[@]} version(s) changee(s) depuis la passe normale (mise a jour apt, signale seulement) :"
             printf '%s\n' "${_l[@]}" | head -10 | sed 's/^/      /'; fi
    fi
    if [ -n "$ajoutes" ]; then
        mapfile -t _l <<< "$ajoutes"; _socle_liste "${#_l[@]} paquet(s) en plus" "${_l[@]}"; erreurs=1
    fi
    [ "${#attendus[@]}" -gt 0 ] && echo -e "  ${CYAN}socle : retraits attendus :${NC} ${attendus[*]}"

    if [ "$erreurs" = 0 ]; then
        echo -e "  ${GREEN}✓${NC} socle conforme ($mode) : $(grep -c '^paquet' "$m") paquets, $(grep -c '^fichier' "$m") fichiers osmo-build-*"
        return 0
    fi
    if [ "${OSMO_ISO_SOCLE_TOLERANT:-0}" = "1" ]; then
        echo -e "  ${YELLOW}OSMO_ISO_SOCLE_TOLERANT=1 : divergence signalee, le build continue.${NC}"
        return 0
    fi
    echo -e "  ${YELLOW}Le socle commun aux ISO --all a diverge. Un retrait voulu : l ajouter a${NC}"
    echo -e "  ${YELLOW}OSMO_ISO_SOCLE_RETRAITS (ou a _SOCLE_RETRAITS_BUREAU, 41-socle.sh).${NC}"
    echo -e "  ${YELLOW}OSMO_ISO_SOCLE_TOLERANT=1 pour livrer quand meme.${NC}"
    exit 1
}

# ── Check right after the hand over (lite: copy, desktop: move) ─────────────
OSMO_ISO_SOCLE=""
if [ "${OSMO_ISO_INHERITED:-0}" = "1" ] && [ -n "${OSMO_ISO_ROOTFS_FROM:-}" ]; then
    OSMO_ISO_SOCLE="${OSMO_ISO_ROOTFS_FROM}.socle"
    if [ -s "$OSMO_ISO_SOCLE" ]; then
        echo -e "${GREEN}[4b/9] Socle commun : controle du rootfs repris...${NC}"
        socle_verifier "$ROOTFS" "$OSMO_ISO_SOCLE" strict
    else
        echo -e "  ${YELLOW}!${NC} pas de manifeste du socle ($OSMO_ISO_SOCLE) : rootfs repris sans controle"
        OSMO_ISO_SOCLE=""
    fi
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. Always return 0 here.
true
