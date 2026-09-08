#!/bin/bash
# =============================================================================
# osmo-pmos-install.sh - L UI SMARTPHONE DU BANC, POSEE DANS /opt/user_interface
# UNE FOIS POUR LES TROIS CHEMINS (addition.sh, update.sh, le build ISO).
#
# [2026-09-08] Le telephone du banc (la VM postmarketOS/Phosh, son modem, son
# noyau PPP) vivait eparpille : les scripts dans le depot, pmbootstrap dans le
# home de nirvana (patche a la main), le noyau dans ~nirvana/test, le script
# de build dans ~nirvana. Tout cela vit maintenant a UN endroit :
#
#   /opt/user_interface/
#     pmos/                       L UI SMARTPHONE
#       bin/                      osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh
#                                 osmo-pmos-build.sh osmo-phonesim-banc.py at-cmd.py
#                                 (copies du depot ; /usr/local/bin/osmo-pmos* y pointent)
#       pmbootstrap/              pmbootstrap, PATCHE (patches/pmbootstrap-osmo-bench-qemu.patch)
#                                 -> /usr/local/bin/pmbootstrap
#       patches/                  les deux patches (pmbootstrap, pmaports PPP)
#       pmbootstrap_v3.cfg        le gabarit de config (Phosh, fr, paquets du modem)
#       image/qemu-amd64.img.zst  (optionnel) la VM de reference, compressee
#       README
#     kernel/                     LES .deb DU NOYAU pmOS PPP
#       osmo-build-pmos-kernel_*.deb
#       pmos/                     ce que le .deb pose : apk, APKINDEX, cle .pub,
#                                 pmaports.commit, patch (lu par osmo-pmos-build)
#
#   osmo-pmos-install                = --layout --launchers --kernel
#   osmo-pmos-install --layout       bin/, patches/, gabarit, pmbootstrap (clone + patch si absent)
#   osmo-pmos-install --launchers    /usr/local/bin/osmo-pmos*, pmbootstrap, .desktop
#   osmo-pmos-install --kernel       dpkg -i du .deb du noyau (kernel/ ou /var/cache/osmo-debs)
#   osmo-pmos-install --image <img>  range une image de VM (compressee en zstd) dans pmos/image/
#
# Idempotent ; utilisable en session ET dans le chroot de l ISO (aucun
# systemctl, aucun reseau requis si pmbootstrap est deja la).
# =============================================================================
set -u

REPO="${OSMO_REPO:-${DIR:-/opt/GSM/osmo-operator}}"
UI="${OSMO_UI_ROOT:-/opt/user_interface}"
PM="$UI/pmos"
KDIR="$UI/kernel"
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
PMB_GIT="${OSMO_PMB_GIT:-https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git}"
# [2026-09-08] Le .deb du noyau PPP est aussi publie sur GitHub (Git LFS) :
# https://github.com/bbaranoff/pmos_ppp_kernel - c est le repli quand ni
# /opt/user_interface/kernel ni /var/cache/osmo-debs ne l ont (une machine
# qui n est pas celle de reference, un build ISO sur une autre machine).
KERNEL_URL="${OSMO_PMOS_KERNEL_URL:-https://media.githubusercontent.com/media/bbaranoff/pmos_ppp_kernel/main/osmo-build-pmos-kernel_7.2.3.0+ppp~noble_amd64.deb}"

: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${RED:=}"; : "${NC:=}"
_p_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_p_ok()   { echo -e "      ${GREEN}✓${NC} $*"; }
_p_warn() { echo -e "      ${YELLOW}!${NC} $*"; }

pmos_layout() {
    _p_say "l UI smartphone dans $PM"
    install -d "$PM/bin" "$PM/patches" "$KDIR"
    local f
    for f in osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh osmo-pmos-build.sh osmo-phonesim-banc.py at-cmd.py; do
        [ -f "$REPO/tools/$f" ] && install -m755 "$REPO/tools/$f" "$PM/bin/$f"
    done
    for f in pmbootstrap-osmo-bench-qemu.patch pmaports-linux-postmarketos-stable-ppp.patch; do
        [ -f "$REPO/patches/$f" ] && install -m644 "$REPO/patches/$f" "$PM/patches/$f"
    done
    [ -f "$REPO/configs/pmos/pmbootstrap_v3.cfg" ] && install -m644 "$REPO/configs/pmos/pmbootstrap_v3.cfg" "$PM/pmbootstrap_v3.cfg"
    # pmbootstrap : celui deja la (le .deb osmo-build-pmbootstrap du Dockerfile,
    # ou une pose precedente), sinon un clone. Puis le patch du banc, s il
    # n est pas deja dedans (osmo_bench_args dans pmb/commands/qemu.py).
    if [ ! -f "$PM/pmbootstrap/pmbootstrap.py" ]; then
        if git clone -q "$PMB_GIT" "$PM/pmbootstrap" 2>/dev/null; then
            _p_ok "pmbootstrap clone ($PMB_GIT)"
        else
            _p_warn "pmbootstrap : pas de clone possible (hors ligne ?) - osmo-pmos-build le redemandera"
        fi
    fi
    if [ -f "$PM/pmbootstrap/pmbootstrap.py" ]; then
        if grep -q 'osmo_bench_args' "$PM/pmbootstrap/pmb/commands/qemu.py" 2>/dev/null; then
            _p_ok "pmbootstrap deja patche (osmo_bench_args)"
        elif git -C "$PM/pmbootstrap" apply --check "$PM/patches/pmbootstrap-osmo-bench-qemu.patch" 2>/dev/null; then
            git -C "$PM/pmbootstrap" apply "$PM/patches/pmbootstrap-osmo-bench-qemu.patch" && _p_ok "pmbootstrap patche (modem serie PCI, son du banc, ecran, port 5038)"
        else
            _p_warn "le patch pmbootstrap ne s applique pas sur cette version - a regarder (git -C $PM/pmbootstrap apply --check)"
        fi
        find "$PM/pmbootstrap" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
        find "$PM/pmbootstrap" -name '*.bak-*' -delete 2>/dev/null || true
    fi
    cat > "$PM/README" <<EOF
L UI SMARTPHONE DU BANC - une VM postmarketOS/Phosh branchee sur le modem
du banc (tools/osmo-phonesim-banc.py). Pose par osmo-pmos-install
(depot : $REPO, tools/osmo-pmos-install.sh).

  bin/                  les scripts (osmo-pmos, osmo-pmos-qemu, osmo-pmos-setup,
                        osmo-pmos-build) - /usr/local/bin/* y pointent
  pmbootstrap/          pmbootstrap patche pour le banc (patches/)
  pmbootstrap_v3.cfg    gabarit : ~/.config/pmbootstrap_v3.cfg du compte de session
  image/                (optionnel) qemu-amd64.img.zst, la VM de reference
  ../kernel/            le .deb du noyau PPP, et kernel/pmos/ son contenu

Premiere fois, SOUS LE COMPTE DE SESSION (pas root) :
  osmo-pmos-build            noyau (raccourci : l apk de ../kernel/pmos), image, VM
  osmo-pmos-qemu smartphone  ensuite : la VM, le modem et la voix
Mot de passe de la VM : 147147.
EOF
    # Lisible et executable par le compte de session : pmbootstrap y est lance
    # sous lui, pas sous root.
    chmod -R a+rX "$PM" "$KDIR" 2>/dev/null || true
    _p_ok "$PM : bin/ ($(ls "$PM/bin" | wc -l) scripts), patches/, gabarit, pmbootstrap$( [ -f "$PM/pmbootstrap/pmbootstrap.py" ] && echo '' || echo ' (absent)')"
}

pmos_launchers() {
    local f n
    for f in osmo-pmos osmo-pmos-qemu osmo-pmos-setup osmo-pmos-build; do
        [ -f "$PM/bin/$f.sh" ] && ln -sfn "$PM/bin/$f.sh" "/usr/local/bin/$f"
    done
    [ -f "$PM/pmbootstrap/pmbootstrap.py" ] && ln -sfn "$PM/pmbootstrap/pmbootstrap.py" /usr/local/bin/pmbootstrap
    # Les icones : la VM aux deux formats, l arret, le rebranchement du modem
    # (memes .desktop que update.sh / osmo-extras-install.sh, une source ici).
    install -d /usr/share/applications
    cat > /usr/share/applications/osmo-pmos.desktop <<'PMD'
[Desktop Entry]
Type=Application
Name=Le telephone du banc (postmarketOS)
Comment=Une VM postmarketOS/Phosh branchee sur le modem du banc - osmo-pmos up
Exec=/usr/local/bin/osmo-pmos up
Icon=phone
Terminal=true
Categories=Network;Telephony;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;
Actions=status;stop;build;
[Desktop Action status]
Name=Etat du telephone (osmo-pmos status)
Exec=/usr/local/bin/osmo-pmos status
[Desktop Action stop]
Name=Arreter le telephone (osmo-pmos stop)
Exec=/usr/local/bin/osmo-pmos stop
[Desktop Action build]
Name=Construire l image (noyau PPP + pmbootstrap install)
Exec=/usr/local/bin/osmo-pmos-build --no-launch
PMD
    for n in smartphone tablette; do
        local r=720x1440 ic=phone; [ "$n" = tablette ] && { r=1280x800; ic=tablet; }
        cat > "/usr/share/applications/osmo-pmos-$n.desktop" <<PMD
[Desktop Entry]
Type=Application
Name=Telephone du banc - $n
Comment=La VM postmarketOS au format $n ($r), le modem et la voix branches tout seuls
Exec=env OSMO_PMOS_RES=$r /usr/local/bin/osmo-pmos-qemu
Icon=$ic
Terminal=true
Categories=Network;Telephony;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;$n;
Actions=stop;setup;nomodem;
[Desktop Action stop]
Name=Arreter le telephone (osmo-pmos-qemu stop)
Exec=/usr/local/bin/osmo-pmos-qemu stop
[Desktop Action setup]
Name=Rebrancher le modem et la voix (osmo-pmos-setup)
Exec=/usr/local/bin/osmo-pmos-setup
[Desktop Action nomodem]
Name=VM seule, sans modem
Exec=env OSMO_PMOS_RES=$r OSMO_PMOS_MODEM=0 /usr/local/bin/osmo-pmos-qemu
PMD
    done
    chmod 644 /usr/share/applications/osmo-pmos*.desktop
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    _p_ok "lanceurs : /usr/local/bin/osmo-pmos, osmo-pmos-qemu, osmo-pmos-setup, osmo-pmos-build, pmbootstrap ; 3 .desktop"
}

pmos_kernel() {
    local deb
    if [ -f "$KDIR"/pmos/linux-postmarketos-stable-*.apk ]; then
        _p_ok "noyau PPP deja pose : $KDIR/pmos/$(basename "$(ls "$KDIR"/pmos/linux-postmarketos-stable-*.apk | head -1)")"
        return 0
    fi
    deb="$(ls -1 "$KDIR"/osmo-build-pmos-kernel_*.deb "$DEB_CACHE"/osmo-build-pmos-kernel_*.deb 2>/dev/null | head -1)"
    if [ -z "$deb" ] && [ -n "$KERNEL_URL" ] && command -v curl >/dev/null 2>&1; then
        install -d "$KDIR"
        deb="$KDIR/$(basename "$KERNEL_URL")"
        _p_say "telechargement du noyau PPP ($KERNEL_URL)..."
        if curl -fsSL --retry 3 -o "$deb.part" "$KERNEL_URL" && dpkg-deb --info "$deb.part" >/dev/null 2>&1; then
            mv -f "$deb.part" "$deb"; cp -f "$deb" "$DEB_CACHE/" 2>/dev/null || true
        else
            rm -f "$deb.part"; deb=""
        fi
    fi
    if [ -z "$deb" ]; then
        _p_warn "pas de .deb du noyau pmOS ($KDIR, $DEB_CACHE, GitHub) : osmo-pmos-build compilera le noyau (long)"
        return 0
    fi
    dpkg -i --force-overwrite "$deb" >/dev/null 2>&1 && _p_ok "noyau PPP pose depuis $(basename "$deb")" || _p_warn "dpkg -i $(basename "$deb") a echoue"
    [ -f "$KDIR/$(basename "$deb")" ] || cp -f "$deb" "$KDIR/"
}

pmos_image() {
    local src="$1" dst="$PM/image/qemu-amd64.img.zst"
    [ -f "$src" ] || { _p_warn "image introuvable : $src"; return 1; }
    install -d "$PM/image"
    case "$src" in
        *.zst) cp -f "$src" "$dst" ;;
        *) command -v zstd >/dev/null 2>&1 || { _p_warn "zstd absent"; return 1; }
           _p_say "compression de $src (fichier creux : seuls les blocs ecrits comptent)..."
           zstd -T0 -3 --sparse -f -o "$dst" "$src" || return 1 ;;
    esac
    chmod a+r "$dst"
    _p_ok "image de reference : $dst ($(du -h "$dst" | cut -f1))"
}

osmo_pmos_install() {
    local layout=0 launchers=0 kernel=0 image="" a prev=""
    for a in "$@"; do
        if [ "$prev" = "--image" ]; then image="$a"; prev=""; continue; fi
        case "$a" in
            --layout) layout=1 ;; --launchers) launchers=1 ;; --kernel) kernel=1 ;; --image) prev="--image" ;;
            *) echo "osmo-pmos-install : option inconnue $a" >&2; return 2 ;;
        esac
    done
    if [ $((layout + launchers + kernel)) -eq 0 ] && [ -z "$image" ]; then layout=1; launchers=1; kernel=1; fi
    [ "$layout" = 1 ] && pmos_layout
    [ "$kernel" = 1 ] && pmos_kernel
    [ "$launchers" = 1 ] && pmos_launchers
    [ -n "$image" ] && pmos_image "$image"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "osmo-pmos-install : root requis" >&2; exit 1; }
    osmo_pmos_install "$@"
fi
