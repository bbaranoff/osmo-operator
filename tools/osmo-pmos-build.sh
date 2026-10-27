#!/bin/bash
# =============================================================================
# osmo-pmos-build.sh - THE postmarketOS KERNEL WITH PPP, THE IMAGE, AND THE VM
# THAT GOES WITH IT.
#
# WHY. The phone 4G data (ATD*99 -> CONNECT) needs PPP: the stock
# linux-postmarketos-stable kernel has no PPP ("# CONFIG_PPP is not set") and
# refuses unsigned modules (lockdown). Modules built WITH the kernel are
# signed by the build key, so the kernel is rebuilt with
# CONFIG_PPP/CONFIG_PPP_ASYNC, then the image.
#
# TWO PATHS TO THIS KERNEL:
#   1. THE SHORTCUT: /opt/user_interface/kernel/pmos/ (installed by the
#      osmo-build-pmos-kernel .deb, in the ISO and in /var/cache/osmo-debs)
#      carries the already built apk, its index, its public key and the
#      pmaports commit. They are copied into the pmbootstrap work directory and
#      "pmbootstrap install" takes that kernel: ZERO compilation.
#   2. THE SOURCES: no apk, or --rebuild -> pmbootstrap build of the kernel
#      (15 to 40 min).
#
# Run under the SESSION ACCOUNT (pmbootstrap refuses root; it asks for sudo
# itself), in a terminal:
#   osmo-pmos-build                  kernel + image + smartphone VM (720x1440)
#   osmo-pmos-build tablette         same, VM in tablet format (1280x800)
#   osmo-pmos-build --no-install     the kernel only
#   osmo-pmos-build --no-launch      kernel + image, without starting the VM
#   osmo-pmos-build --rebuild        recompile even if the apk with PPP is already there
#   osmo-pmos-build --init           only prepare pmbootstrap (config, pmaports, kernel)
#   JOBS=8 osmo-pmos-build           fewer cores (srsRAN runs alongside)
#
# PMBOOTSTRAP AND ITS WORK DIRECTORY. pmbootstrap is the one of
# /opt/user_interface/pmos/pmbootstrap (patched: patches/pmbootstrap-osmo-
# bench-qemu.patch - the modem on a PCI serial port, the bench sound card, the
# screen size, and port 5038 which is not an adb). The work directory is the
# one of the account's pmbootstrap_v3.cfg, else ~/.local/var/pmbootstrap
# (OSMO_PMB_WORK for another). Without config, one is written from the
# template /opt/user_interface/pmos/pmbootstrap_v3.cfg: Phosh, fr_FR,
# hostname pmos-gsm, and the modem packages (ppp, networkmanager-ppp...).
# pmaports is cloned at the kernel commit (pmaports.commit) and receives the
# PPP patch: same pkgver/pkgrel as the apk, otherwise pmbootstrap does not prefer it.
# =============================================================================
set -u

UI="${OSMO_UI_ROOT:-/opt/user_interface}"
PM="$UI/pmos"
KD="$UI/kernel/pmos"
PMB="${PMB:-}"
for _p in "$PMB" "$PM/pmbootstrap/pmbootstrap.py" "$(command -v pmbootstrap 2>/dev/null)" "$HOME/.local/bin/pmbootstrap"; do
    [ -n "$_p" ] && [ -x "$_p" ] && { PMB="$_p"; break; }
done
CFG="$HOME/.config/pmbootstrap_v3.cfg"
WORK="${OSMO_PMB_WORK:-}"
[ -z "$WORK" ] && [ -f "$CFG" ] && WORK="$(sed -n 's/^work *= *//p' "$CFG" | head -1)"
[ -z "$WORK" ] && WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$(sed -n 's/^aports *= *//p' "$CFG" 2>/dev/null | head -1)"
[ -n "$PMAPORTS" ] || PMAPORTS="$WORK/cache_git/pmaports"
KCFG="$PMAPORTS/device/main/linux-postmarketos-stable/config-stable.x86_64"
IMG="$WORK/chroot_native/home/pmos/rootfs/qemu-amd64.img"
JOBS="${JOBS:-$(nproc)}"
PASS="${OSMO_PMOS_PASSWORD:-147147}"
FORMAT=smartphone
INSTALL=1
LAUNCH=1
REBUILD=0
INIT_ONLY=0

for a in "$@"; do
    case "$a" in
        smartphone|tablette) FORMAT="$a" ;;
        --no-install) INSTALL=0 ;;
        --no-launch)  LAUNCH=0 ;;
        --rebuild)    REBUILD=1 ;;
        --init)       INIT_ONLY=1 ;;
        *) echo "argument inconnu : $a (smartphone|tablette|--no-install|--no-launch|--rebuild|--init)" >&2; exit 2 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYAN}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ROOT ACCEPTED. The ISO session IS root (see osmo-pmos-qemu): pmbootstrap
# accepts --as-root; under a regular account, nothing changes.
PMB_OPTS=(); [ "$(id -u)" -eq 0 ] && { PMB_OPTS=(--as-root); warn "en root : pmbootstrap --as-root (dossier de travail de root)"; }
pmb() { "$PMB" "${PMB_OPTS[@]}" "$@"; }
[ -n "$PMB" ] && [ -x "$PMB" ] || die "pmbootstrap introuvable ($PM/pmbootstrap manquant : osmo-pmos-install)"

# ── 0. THE ACCOUNT'S pmbootstrap CONFIG ─────────────────────────────────────
if [ ! -f "$CFG" ]; then
    [ -f "$PM/pmbootstrap_v3.cfg" ] || die "pas de $CFG ni de gabarit $PM/pmbootstrap_v3.cfg"
    mkdir -p "$(dirname "$CFG")" "$WORK"
    sed "s#@WORK@#$WORK#g; s#@APORTS@#$PMAPORTS#g" "$PM/pmbootstrap_v3.cfg" > "$CFG"
    ok "config pmbootstrap ecrite : $CFG (work = $WORK)"
fi
mkdir -p "$WORK"
# The work directory version number: without it, pmbootstrap asks for
# "init". It is the one of pmb/config/__init__.py (work_version).
if [ ! -f "$WORK/version" ]; then
    _wv="$(grep -m1 -oE '^work_version *= *[0-9]+' "$(dirname "$PMB")/pmb/config/__init__.py" 2>/dev/null | grep -oE '[0-9]+$')"
    echo "${_wv:-8}" > "$WORK/version"
fi

# ── 1. pmaports, AT THE KERNEL COMMIT, with the PPP patch ───────────────────
_commit="$(cat "$KD/pmaports.commit" 2>/dev/null || true)"
# ONE osmo-pmos-build AT A TIME. Two launches (the icon clicked while a first
# clone is running) would step on each other: the second would see a .git
# without commit - the one of the clone IN PROGRESS - and erase it. Lock on
# the work directory, and never touch a clone that still has its git.
exec 9>"$WORK/.osmo-pmos-build.lock"
flock -n 9 || die "un autre osmo-pmos-build tourne deja (verrou $WORK/.osmo-pmos-build.lock) : attends-le, ou ferme-le"
# An interrupted clone (network cut, window closed) leaves a .git WITHOUT
# commit, and the build would die further down on "kernel config not found".
# A repository without HEAD, and without git running on it, is a missing one.
if [ -d "$PMAPORTS/.git" ] && ! git -C "$PMAPORTS" rev-parse --verify HEAD >/dev/null 2>&1 \
   && ! pgrep -f "git(-remote-https)? .*$PMAPORTS" >/dev/null 2>&1; then
    warn "pmaports : clone vide ou interrompu, on le refait ($PMAPORTS)"
    rm -rf "$PMAPORTS"
fi
# PMAPORTS WITHOUT GITLAB WHEN POSSIBLE. The full clone (hundreds of MB, slow
# GitLab) is unreliable from the live system, and git then erases everything.
# In order: the copy installed by the ISO (88-lte-pmos.sh: $PM/pmaports, at
# the kernel commit, no network); else A SINGLE commit fetched with
# --depth 1 (a few tens of MB); the full clone only if the commit is unknown.
if [ ! -d "$PMAPORTS/.git" ]; then
    mkdir -p "$(dirname "$PMAPORTS")"
    if [ -d "$PM/pmaports/.git" ] && git -C "$PM/pmaports" rev-parse --verify HEAD >/dev/null 2>&1; then
        say "pmaports : copie de celui de l ISO ($PM/pmaports -> $PMAPORTS)..."
        cp -a "$PM/pmaports" "$PMAPORTS" || die "copie de pmaports"
        # pmbootstrap reads channels.cfg in origin/main: the ref must exist.
        git -C "$PMAPORTS" rev-parse -q --verify origin/main >/dev/null 2>&1 \
            || git -C "$PMAPORTS" update-ref refs/remotes/origin/main HEAD
        ok "pmaports au commit $(git -C "$PMAPORTS" rev-parse --short HEAD) (celui de l ISO)"
    elif [ -n "$_commit" ] && [ "$_commit" != inconnu ]; then
        say "pmaports : le commit $_commit du noyau, seul (fetch --depth 1)..."
        ( git init -q "$PMAPORTS" && cd "$PMAPORTS" \
          && git remote add origin https://gitlab.postmarketos.org/postmarketOS/pmaports.git \
          && git fetch -q --depth 1 origin "$_commit" && git checkout -q -B main FETCH_HEAD \
          && git update-ref refs/remotes/origin/main FETCH_HEAD ) \
          || { rm -rf "$PMAPORTS"; die "pmaports : fetch du commit $_commit impossible (reseau ?) - relance quand GitLab repond"; }
        ok "pmaports au commit $_commit (celui du noyau)"
    else
        say "clone de pmaports ($PMAPORTS)..."
        git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS" || die "clone pmaports"
    fi
fi
[ -f "$KCFG" ] || die "config noyau introuvable : $KCFG"
if grep -q '^CONFIG_PPP_ASYNC=m' "$KCFG"; then
    ok "config noyau : PPP deja active ($(grep -c '^CONFIG_PPP' "$KCFG") symboles)"
else
    say "config noyau : ajout de PPP"
    cp -a "$KCFG" "$KCFG.avant-ppp"
    _patch=""
    for _p in "$KD/pmaports-linux-postmarketos-stable-ppp.patch" "$PM/patches/pmaports-linux-postmarketos-stable-ppp.patch"; do
        [ -f "$_p" ] && { _patch="$_p"; break; }
    done
    if [ -n "$_patch" ] && git -C "$PMAPORTS" apply --check "$_patch" 2>/dev/null; then
        git -C "$PMAPORTS" apply "$_patch" && ok "patch pmaports applique ($_patch)"
    else
        python3 - "$KCFG" <<'PY' || die "patch de la config impossible"
import sys
p = sys.argv[1]; s = open(p).read()
old = "# CONFIG_PPP is not set\n"
new = ("CONFIG_PPP=m\nCONFIG_PPP_BSDCOMP=m\nCONFIG_PPP_DEFLATE=m\nCONFIG_PPP_FILTER=y\n"
       "CONFIG_PPP_MULTILINK=y\nCONFIG_PPP_ASYNC=m\nCONFIG_PPP_SYNC_TTY=m\n")
if old not in s:
    sys.exit("pas de « # CONFIG_PPP is not set » dans la config : a regarder a la main")
open(p, "w").write(s.replace(old, new, 1))
PY
        ok "config noyau : PPP=m, PPP_ASYNC=m (sauvegarde : $KCFG.avant-ppp)"
    fi
fi
# The checksum: abuild checks the sha512 of each source file, and the modified
# config no longer has the one of the APKBUILD ("FAILED, Use 'abuild
# checksum'"). It is always updated, it costs nothing.
APKB="$(dirname "$KCFG")/APKBUILD"
somme="$(sha512sum "$KCFG" | cut -d' ' -f1)"
if grep -q "^$somme  $(basename "$KCFG")\$" "$APKB"; then
    ok "APKBUILD : sha512 de la config a jour"
else
    sed -i "s/^[0-9a-f]\{128\}  $(basename "$KCFG")\$/$somme  $(basename "$KCFG")/" "$APKB" \
        && ok "APKBUILD : sha512 de la config mis a jour" \
        || die "sha512 de la config non remplace dans $APKB"
fi

# ── 2. THE pmbootstrap SETTINGS: Phosh, not the console ─────────────────────
ui="$(pmb config ui 2>/dev/null | tail -1)"
if [ "$ui" != "phosh" ]; then
    warn "pmbootstrap config ui = « $ui » : un install ferait une VM sans bureau"
    pmb config ui phosh || die "impossible de poser ui=phosh"
fi
ok "ui = phosh, device = $(pmb config device 2>/dev/null | tail -1), jobs = $JOBS, work = $WORK"

# ── 3. THE KERNEL: THE SHORTCUT FIRST ───────────────────────────────────────
# The apk of the osmo-build-pmos-kernel .deb, copied into the local pmbootstrap
# repository with its index and its key: "pmbootstrap install" prefers it to
# the online repository (same version, local package). Else an apk already
# built here, newer than the config, which has ppp_async.ko. Else compile.
# --rebuild forces the compilation.
_a_ppp() { grep -q 'ppp_async\.ko' < <(tar tzf "$1" 2>/dev/null); }
if [ "$REBUILD" = 0 ] && [ -f "$KD"/linux-postmarketos-stable-*.apk ]; then
    read -r _chan _parch _ver < "$KD/apk.info" 2>/dev/null || { _chan=edge; _parch=x86_64; }
    _dst="$WORK/packages/$_chan/$_parch"
    mkdir -p "$_dst" "$WORK/config_apk_keys"
    for f in "$KD"/linux-postmarketos-stable-*.apk "$KD"/APKINDEX.tar.gz; do
        [ -f "$f" ] && [ ! -f "$_dst/$(basename "$f")" ] && cp -f "$f" "$_dst/"
    done
    cp -n "$KD"/*.rsa.pub "$WORK/config_apk_keys/" 2>/dev/null || true
    touch "$_dst"/linux-postmarketos-stable-*.apk 2>/dev/null || true   # plus recent que la config (fichier du chroot, uid 12345 : pas grave)
    ok "noyau PPP pris dans $KD (raccourci : pas de compilation) -> $_dst"
fi
apk="$(find "$WORK/packages" -name 'linux-postmarketos-stable-[0-9]*.apk' -newer "$KCFG" 2>/dev/null | head -1)"
if [ "$REBUILD" = 0 ] && [ -n "$apk" ] && _a_ppp "$apk"; then
    ok "noyau deja construit avec PPP : $apk (--rebuild pour recompiler)"
else
    [ "$INIT_ONLY" = 1 ] && { warn "pas d apk PPP ; --init ne compile pas (relancer sans --init)"; exit 0; }
    sudo -v || die "sudo refuse"
    say "build du noyau (long : compter 15 a 40 min)..."
    pmb -y -j "$JOBS" build --force linux-postmarketos-stable \
        || die "build echoue - voir $WORK/log.txt (pmbootstrap log)"
    apk="$(find "$WORK/packages" -name 'linux-postmarketos-stable-[0-9]*.apk' -newer "$KCFG" 2>/dev/null | head -1)"
    [ -n "$apk" ] || die "aucun .apk du noyau dans $WORK/packages"
fi
_a_ppp "$apk" && ok "noyau : $apk contient ppp_async.ko" || die "le paquet $apk n a PAS ppp_async.ko - la config n a pas ete prise"
[ "$INIT_ONLY" = 1 ] && { ok "pmbootstrap pret (--init)"; exit 0; }
[ "$INSTALL" = 1 ] || { ok "fini (--no-install)"; exit 0; }

# ── 4. THE IMAGE ────────────────────────────────────────────────────────────
# The image the VM uses is written: the VM must not be running on it.
# An image already provided (/opt/user_interface/pmos/image/qemu-amd64.img.zst,
# the reference VM) is decompressed instead of an install: that is shortcut
# no. 2 - OSMO_PMOS_FRESH=1 to install anyway.
if pgrep -f "qemu-system-x86_64.*$(basename "$IMG")" >/dev/null 2>&1; then
    die "la VM tourne encore sur $IMG : arrete-la (osmo-pmos-qemu stop) puis relance"
fi
sudo -v || die "sudo refuse"
# ── THE REFERENCE IMAGE: PRESENT, OR DOWNLOADED ─────────────────────────────
# If the .zst is missing (ISO built without it) or CORRUPT (zstd -t says so:
# a truncated copy, a 404 saved as is, a key removed too early), it is taken
# from the GitHub release "pmos-image" - the one the workflow embeds in the
# ISO. 1.7 GB, resumable (curl -C -), tested before being put in place.
# OSMO_PMOS_IMAGE_URL for another address, empty to download nothing (falls
# back to pmbootstrap install).
ZST="$PM/image/qemu-amd64.img.zst"
: "${OSMO_PMOS_IMAGE_URL=https://github.com/bbaranoff/osmo-operator/releases/download/pmos-image/qemu-amd64.img.zst}"
pmos_zst_ok() { [ -f "$ZST" ] && zstd -t "$ZST" >/dev/null 2>&1; }
if [ "${OSMO_PMOS_FRESH:-0}" != 1 ] && [ ! -f "$IMG" ] && command -v zstd >/dev/null 2>&1 \
   && ! pmos_zst_ok && [ -n "$OSMO_PMOS_IMAGE_URL" ] && command -v curl >/dev/null 2>&1; then
    [ -f "$ZST" ] && warn "image de reference illisible ($ZST) - retelechargee"
    say "telechargement de l image de reference (1,7 Go, reprise possible) : $OSMO_PMOS_IMAGE_URL"
    sudo install -d "$(dirname "$ZST")"
    if sudo curl -fL -C - --retry 3 --retry-delay 5 -o "$ZST.part" "$OSMO_PMOS_IMAGE_URL" \
       && zstd -t "$ZST.part" >/dev/null 2>&1; then
        sudo mv -f "$ZST.part" "$ZST" && sudo chmod a+r "$ZST"
        ok "image de reference recuperee : $ZST ($(du -h "$ZST" | cut -f1))"
    else
        sudo rm -f "$ZST.part" "$ZST"
        warn "telechargement impossible ou archive invalide - install classique (pmbootstrap install)"
    fi
fi
if [ "${OSMO_PMOS_FRESH:-0}" != 1 ] && [ ! -f "$IMG" ] && pmos_zst_ok; then
    say "image de reference decompressee ($PM/image/qemu-amd64.img.zst -> $IMG)..."
    mkdir -p "$(dirname "$IMG")"
    zstd -d --sparse -o "$IMG" "$PM/image/qemu-amd64.img.zst" && ok "image prete : $IMG (VM de reference)" \
        || { rm -f "$IMG"; warn "decompression echouee - install classique"; }
fi
if [ ! -f "$IMG" ] || [ "${OSMO_PMOS_FRESH:-0}" = 1 ]; then
    say "installation de l image (nouvelle VM, mot de passe $PASS)..."
    pmb -y install --password "$PASS" || die "install echoue - voir $WORK/log.txt"
    ok "image prete : $IMG"
fi
[ "$LAUNCH" = 1 ] || { ok "fini (--no-launch) - « osmo-pmos-qemu $FORMAT » branche VM, modem et voix"; exit 0; }

# ── 5. THE VM, AND THE MODEM AS SOON AS IT ANSWERS ──────────────────────────
# osmo-pmos-qemu keeps control (SDL window) and its watcher plugs the modem
# and the voice by itself (osmo-pmos-setup) as soon as the VM SSH answers.
QEMU="$(command -v osmo-pmos-qemu 2>/dev/null || echo "$PM/bin/osmo-pmos-qemu.sh")"
export OSMO_PMOS_FROM_BUILD=1     # osmo-pmos-qemu ne doit pas nous rappeler
exec "$QEMU" "$FORMAT"
