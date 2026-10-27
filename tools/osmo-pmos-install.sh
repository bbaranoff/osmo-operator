#!/bin/bash
# =============================================================================
# osmo-pmos-install.sh - THE BENCH SMARTPHONE UI, INSTALLED IN /opt/user_interface
# ONCE FOR THE THREE PATHS (addition.sh, update.sh, the ISO build).
#
# The bench phone (the postmarketOS/Phosh VM, its modem, its PPP kernel) lives
# in ONE place:
#
#   /opt/user_interface/
#     pmos/                       THE SMARTPHONE UI
#       bin/                      osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh
#                                 osmo-pmos-build.sh osmo-phonesim-banc.py at-cmd.py
#                                 (copies from the repository; /usr/local/bin/osmo-pmos*
#                                 point there)
#       pmbootstrap/              pmbootstrap, PATCHED (patches/pmbootstrap-osmo-bench-qemu.patch)
#                                 -> /usr/local/bin/pmbootstrap
#       patches/                  the two patches (pmbootstrap, pmaports PPP)
#       pmbootstrap_v3.cfg        the config template (Phosh, fr, modem packages)
#       image/qemu-amd64.img.zst  (optional) the reference VM, compressed
#       README
#     kernel/                     THE pmOS PPP KERNEL .deb
#       osmo-build-pmos-kernel_*.deb
#       pmos/                     what the .deb installs: apk, APKINDEX, .pub key,
#                                 pmaports.commit, patch (read by osmo-pmos-build)
#
#   osmo-pmos-install                = --layout --launchers --kernel
#   osmo-pmos-install --layout       bin/, patches/, template, pmbootstrap (clone + patch if missing)
#   osmo-pmos-install --launchers    /usr/local/bin/osmo-pmos*, pmbootstrap, .desktop
#   osmo-pmos-install --kernel       dpkg -i of the kernel .deb (kernel/ or /var/cache/osmo-debs)
#   osmo-pmos-install --image <img>  stores a VM image (zstd compressed) in pmos/image/
#   osmo-pmos-install --image telecharger   takes it from the GitHub release pmos-image (also
#                                    the automatic fallback if <img> is missing or corrupt)
#
# Idempotent; usable in session AND in the ISO chroot (no systemctl, no
# network required if pmbootstrap is already there).
# =============================================================================
set -u

REPO="${OSMO_REPO:-${DIR:-/opt/GSM/osmo-operator}}"
UI="${OSMO_UI_ROOT:-/opt/user_interface}"
PM="$UI/pmos"
KDIR="$UI/kernel"
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
PMB_GIT="${OSMO_PMB_GIT:-https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git}"
# The PPP kernel .deb is also published on GitHub (Git LFS):
# https://github.com/bbaranoff/pmos_ppp_kernel - the fallback when neither
# /opt/user_interface/kernel nor /var/cache/osmo-debs has it (a machine other
# than the reference one, an ISO build on another machine).
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
    # pmbootstrap: the one already there (the osmo-build-pmbootstrap .deb of the
    # Dockerfile, or a previous install), else a clone. Then the bench patch,
    # if not already in (osmo_bench_args in pmb/commands/qemu.py).
    if [ ! -f "$PM/pmbootstrap/pmbootstrap.py" ]; then
        if git clone -q "$PMB_GIT" "$PM/pmbootstrap" 2>/dev/null; then
            _p_ok "pmbootstrap clone ($PMB_GIT)"
        else
            _p_warn "pmbootstrap : pas de clone possible (hors ligne ?) - osmo-pmos-build le redemandera"
        fi
    fi
    if [ -f "$PM/pmbootstrap/pmbootstrap.py" ]; then
        # "already patched" does not mean "up to date": the osmo-build-pmbootstrap
        # .deb carries the patch of one date, the repository the current one.
        # On a git clone, start again from the original files and apply THE
        # current patch - idempotent; without git, rely on the markers.
        # Marker of the most recent patch: OSMO_PMOS_HP (the named "combine"
        # card); the older one is bootindex=0.
        if [ -d "$PM/pmbootstrap/.git" ] && ! grep -q 'OSMO_PMOS_HP' "$PM/pmbootstrap/pmb/commands/qemu.py" 2>/dev/null \
           && git -C "$PM/pmbootstrap" checkout -q -- pmb 2>/dev/null \
           && git -C "$PM/pmbootstrap" apply "$PM/patches/pmbootstrap-osmo-bench-qemu.patch" 2>/dev/null; then
            _p_ok "pmbootstrap : patch du banc remis a jour (carte combine nommee, bootindex du disque, modem serie PCI, son du banc)"
        elif grep -q 'osmo_bench_args' "$PM/pmbootstrap/pmb/commands/qemu.py" 2>/dev/null; then
            _p_ok "pmbootstrap deja patche (osmo_bench_args$(grep -q 'OSMO_PMOS_HP' "$PM/pmbootstrap/pmb/commands/qemu.py" 2>/dev/null && echo ', carte combine nommee'))"
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

Premiere fois (l icone le fait toute seule ; root accepte : --as-root est passe) :
  osmo-pmos-build            noyau (raccourci : l apk de ../kernel/pmos), image, VM
  osmo-pmos-qemu smartphone  ensuite : la VM, le modem et la voix
Mot de passe de la VM : 147147.
EOF
    # Readable and executable by the session account: pmbootstrap is run under
    # it, not under root.
    chmod -R a+rX "$PM" "$KDIR" 2>/dev/null || true
    _p_ok "$PM : bin/ ($(ls "$PM/bin" | wc -l) scripts), patches/, gabarit, pmbootstrap$( [ -f "$PM/pmbootstrap/pmbootstrap.py" ] && echo '' || echo ' (absent)')"
}

pmos_launchers() {
    local f n
    for f in osmo-pmos osmo-pmos-qemu osmo-pmos-setup osmo-pmos-build; do
        [ -f "$PM/bin/$f.sh" ] && ln -sfn "$PM/bin/$f.sh" "/usr/local/bin/$f"
    done
    [ -f "$PM/pmbootstrap/pmbootstrap.py" ] && ln -sfn "$PM/pmbootstrap/pmbootstrap.py" /usr/local/bin/pmbootstrap
    # Terminal=false everywhere: each Exec goes through tools/osmo-gtk-run.py
    # (bench GTK window, with a VTE terminal inside when the command talks or
    # asks questions) - no favourite opens a terminal.
    # The icons: the VM in both formats, the stop, the modem re-plug (same
    # .desktop files as update.sh / osmo-extras-install.sh, one source here).
    install -d /usr/share/applications
    cat > /usr/share/applications/osmo-pmos.desktop <<'PMD'
[Desktop Entry]
Type=Application
Name=Le telephone du banc (postmarketOS)
Comment=Une VM postmarketOS/Phosh branchee sur le modem du banc - osmo-pmos up
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --root --title "Telephone (postmarketOS)" -- /usr/local/bin/osmo-pmos up
Icon=phone
Terminal=false
Categories=Network;Telephony;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;
Actions=status;stop;build;
[Desktop Action status]
Name=Etat du telephone (osmo-pmos status)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --keep-open --title "Etat du telephone" -- /usr/local/bin/osmo-pmos status
[Desktop Action stop]
Name=Arreter le telephone (osmo-pmos stop)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --close-on-exit --title "Arret du telephone" -- /usr/local/bin/osmo-pmos stop
[Desktop Action build]
Name=Construire l image (noyau PPP + pmbootstrap install)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Image postmarketOS (build)" -- /usr/local/bin/osmo-pmos-build --no-launch
PMD
    for n in smartphone tablette; do
        local r=720x1440 ic=phone; [ "$n" = tablette ] && { r=1280x800; ic=tablet; }
        cat > "/usr/share/applications/osmo-pmos-$n.desktop" <<PMD
[Desktop Entry]
Type=Application
Name=Telephone du banc - $n
Comment=La VM postmarketOS au format $n ($r), le modem et la voix branches tout seuls
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$r /usr/local/bin/osmo-pmos-qemu
Icon=$ic
Terminal=false
Categories=Network;Telephony;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;$n;
Actions=stop;setup;nomodem;
[Desktop Action stop]
Name=Arreter le telephone (osmo-pmos-qemu stop)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --close-on-exit --title "Arret du telephone" -- /usr/local/bin/osmo-pmos-qemu stop
[Desktop Action setup]
Name=Rebrancher le modem et la voix (osmo-pmos-setup)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Modem et voix du telephone" -- /usr/local/bin/osmo-pmos-setup
[Desktop Action nomodem]
Name=VM seule, sans modem
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$r OSMO_PMOS_MODEM=0 /usr/local/bin/osmo-pmos-qemu
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

# THE IMAGE MAY COME FROM THE NETWORK. --image without a file behind it
# (missing), or a corrupt .zst (zstd -t), or --image telecharger: take the
# GitHub release "pmos-image", the same one the ISO embeds. Resumable, archive
# tested before being put in place.
PMOS_IMAGE_URL="${OSMO_PMOS_IMAGE_URL-https://github.com/bbaranoff/osmo-operator/releases/download/pmos-image/qemu-amd64.img.zst}"
pmos_image_telecharger() {
    local dst="$1"
    [ -n "$PMOS_IMAGE_URL" ] || { _p_warn "pas d URL d image (OSMO_PMOS_IMAGE_URL vide)"; return 1; }
    command -v curl >/dev/null 2>&1 || { _p_warn "curl absent - image non telechargee"; return 1; }
    command -v zstd >/dev/null 2>&1 || { _p_warn "zstd absent - image non verifiee, non telechargee"; return 1; }
    install -d "$(dirname "$dst")"
    _p_say "telechargement de l image de reference (1,7 Go, reprise possible) : $PMOS_IMAGE_URL"
    if curl -fL -C - --retry 3 --retry-delay 5 -o "$dst.part" "$PMOS_IMAGE_URL" \
       && zstd -t "$dst.part" >/dev/null 2>&1; then
        mv -f "$dst.part" "$dst"
        return 0
    fi
    rm -f "$dst.part"
    _p_warn "telechargement impossible ou archive invalide ($PMOS_IMAGE_URL)"
    return 1
}

pmos_image() {
    local src="$1" dst="$PM/image/qemu-amd64.img.zst"
    install -d "$PM/image"
    if [ "$src" = telecharger ] || [ ! -f "$src" ]; then
        [ "$src" = telecharger ] || _p_warn "image introuvable : $src - telechargement a la place"
        pmos_image_telecharger "$dst" || return 1
        chmod a+r "$dst"
        _p_ok "image de reference : $dst ($(du -h "$dst" | cut -f1))"
        return 0
    fi
    case "$src" in
        *.zst) if command -v zstd >/dev/null 2>&1 && ! zstd -t "$src" >/dev/null 2>&1; then
                   _p_warn "image corrompue : $src (zstd -t) - telechargement a la place"
                   pmos_image_telecharger "$dst" || return 1
               elif [ "$(readlink -f "$src")" != "$(readlink -f "$dst")" ]; then
                   cp -f "$src" "$dst"
               fi ;;
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
