#!/bin/bash
# =============================================================================
# osmo-pmos-build.sh - LE NOYAU postmarketOS AVEC PPP, L IMAGE, ET LA VM QUI
# VA AVEC. (ex ~nirvana/build-pm.sh, entre dans le depot le 2026-09-08.)
#
# [2026-09-07] POURQUOI. La data 4G du telephone (ATD*99 -> CONNECT) meurt en
# NO CARRIER : le noyau linux-postmarketos-stable n a pas PPP (« # CONFIG_PPP
# is not set ») et refuse les modules non signes (lockdown). Les modules
# construits AVEC le noyau sont signes par la cle du build : il suffit donc de
# reconstruire le noyau avec CONFIG_PPP/CONFIG_PPP_ASYNC, puis l image.
#
# [2026-09-08] DEUX CHEMINS VERS CE NOYAU :
#   1. LE RACCOURCI : /opt/user_interface/kernel/pmos/ (pose par le .deb
#      osmo-build-pmos-kernel, dans l ISO et dans /var/cache/osmo-debs) porte
#      l apk deja construit, son index, sa cle publique et le commit pmaports.
#      On les copie dans le dossier de travail pmbootstrap et « pmbootstrap
#      install » prend ce noyau-la : ZERO compilation.
#   2. LES SOURCES : pas d apk, ou --rebuild -> pmbootstrap build du noyau
#      (15 a 40 min), comme avant.
#
# A lancer sous le COMPTE DE SESSION (pmbootstrap refuse root ; il demande
# sudo lui-meme), dans un terminal :
#   osmo-pmos-build                  noyau + image + VM smartphone (720x1440)
#   osmo-pmos-build tablette         idem, VM au format tablette (1280x800)
#   osmo-pmos-build --no-install     le noyau seulement
#   osmo-pmos-build --no-launch      noyau + image, sans allumer la VM
#   osmo-pmos-build --rebuild        recompiler meme si l apk avec PPP est deja la
#   osmo-pmos-build --init           seulement preparer pmbootstrap (config, pmaports, noyau)
#   JOBS=8 osmo-pmos-build           moins de coeurs (srsRAN tourne a cote)
#
# PMBOOTSTRAP ET SON DOSSIER DE TRAVAIL. pmbootstrap est celui de
# /opt/user_interface/pmos/pmbootstrap (patche : patches/pmbootstrap-osmo-
# bench-qemu.patch - le modem sur un port serie PCI, la carte son du banc, la
# taille d ecran, et le port 5038 qui n est pas un adb). Le dossier de travail
# est celui du pmbootstrap_v3.cfg du compte, sinon ~/.local/var/pmbootstrap
# (OSMO_PMB_WORK pour un autre). Sans config, on en ecrit une depuis le
# gabarit /opt/user_interface/pmos/pmbootstrap_v3.cfg : Phosh, fr_FR,
# hostname pmos-gsm, et les paquets du modem (ppp, networkmanager-ppp...).
# pmaports est clone au commit du noyau (pmaports.commit) et recoit le patch
# PPP : meme pkgver/pkgrel que l apk, sinon pmbootstrap ne le prefere pas.
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

# [2026-09-09] ROOT ACCEPTE. La session de l ISO EST root (voir osmo-pmos-
# qemu) : refuser root, c etait refuser l icone. pmbootstrap accepte
# --as-root ; sous un compte, rien ne change.
PMB_OPTS=(); [ "$(id -u)" -eq 0 ] && { PMB_OPTS=(--as-root); warn "en root : pmbootstrap --as-root (dossier de travail de root)"; }
pmb() { "$PMB" "${PMB_OPTS[@]}" "$@"; }
[ -n "$PMB" ] && [ -x "$PMB" ] || die "pmbootstrap introuvable ($PM/pmbootstrap manquant : osmo-pmos-install)"

# ── 0. LA CONFIG pmbootstrap DU COMPTE ──────────────────────────────────────
if [ ! -f "$CFG" ]; then
    [ -f "$PM/pmbootstrap_v3.cfg" ] || die "pas de $CFG ni de gabarit $PM/pmbootstrap_v3.cfg"
    mkdir -p "$(dirname "$CFG")" "$WORK"
    sed "s#@WORK@#$WORK#g; s#@APORTS@#$PMAPORTS#g" "$PM/pmbootstrap_v3.cfg" > "$CFG"
    ok "config pmbootstrap ecrite : $CFG (work = $WORK)"
fi
mkdir -p "$WORK"
# Le numero de version du dossier de travail : sans lui, pmbootstrap demande
# « init ». C est celui de pmb/config/__init__.py (work_version).
if [ ! -f "$WORK/version" ]; then
    _wv="$(grep -m1 -oE '^work_version *= *[0-9]+' "$(dirname "$PMB")/pmb/config/__init__.py" 2>/dev/null | grep -oE '[0-9]+$')"
    echo "${_wv:-8}" > "$WORK/version"
fi

# ── 1. pmaports, AU COMMIT DU NOYAU, avec le patch PPP ──────────────────────
_commit="$(cat "$KD/pmaports.commit" 2>/dev/null || true)"
# [2026-09-09] UN SEUL osmo-pmos-build A LA FOIS. Deux lancements (l icone
# cliquee pendant qu un premier clone tourne) se marchaient dessus : le second
# voyait un .git sans commit - celui du clone EN COURS - et l effacait
# (« fatal: could not open .../tmp_pack_... » chez le premier). Verrou sur le
# dossier de travail, et on ne touche jamais a un clone qui a encore son git.
exec 9>"$WORK/.osmo-pmos-build.lock"
flock -n 9 || die "un autre osmo-pmos-build tourne deja (verrou $WORK/.osmo-pmos-build.lock) : attends-le, ou ferme-le"
# Un clone interrompu (reseau coupe, fenetre fermee) laisse un .git SANS
# commit : on passait le clone, et on mourait plus bas sur « config noyau
# introuvable ». Un depot sans HEAD, et sans git dessus, est un depot absent.
if [ -d "$PMAPORTS/.git" ] && ! git -C "$PMAPORTS" rev-parse --verify HEAD >/dev/null 2>&1 \
   && ! pgrep -f "git(-remote-https)? .*$PMAPORTS" >/dev/null 2>&1; then
    warn "pmaports : clone vide ou interrompu, on le refait ($PMAPORTS)"
    rm -rf "$PMAPORTS"
fi
# [2026-09-09] PMAPORTS SANS GITLAB QUAND C EST POSSIBLE. Le clone complet
# (des centaines de Mo, GitLab lent) a echoue deux fois sur trois depuis le
# live : git efface alors tout et le telephone ne s allume jamais. Dans
# l ordre : la copie posee par l ISO (88-lte-pmos.sh : $PM/pmaports, au commit
# du noyau, sans reseau) ; sinon UN SEUL commit recupere par fetch --depth 1
# (quelques dizaines de Mo) ; le clone complet seulement si le commit est
# inconnu.
if [ ! -d "$PMAPORTS/.git" ]; then
    mkdir -p "$(dirname "$PMAPORTS")"
    if [ -d "$PM/pmaports/.git" ] && git -C "$PM/pmaports" rev-parse --verify HEAD >/dev/null 2>&1; then
        say "pmaports : copie de celui de l ISO ($PM/pmaports -> $PMAPORTS)..."
        cp -a "$PM/pmaports" "$PMAPORTS" || die "copie de pmaports"
        ok "pmaports au commit $(git -C "$PMAPORTS" rev-parse --short HEAD) (celui de l ISO)"
    elif [ -n "$_commit" ] && [ "$_commit" != inconnu ]; then
        say "pmaports : le commit $_commit du noyau, seul (fetch --depth 1)..."
        ( git init -q "$PMAPORTS" && cd "$PMAPORTS" \
          && git remote add origin https://gitlab.postmarketos.org/postmarketOS/pmaports.git \
          && git fetch -q --depth 1 origin "$_commit" && git checkout -q FETCH_HEAD ) \
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
# La somme de controle : abuild verifie le sha512 de chaque fichier source, et
# la config modifiee n a plus celui de l APKBUILD (« FAILED, Use 'abuild
# checksum' »). On le remet a jour, toujours, ca ne coute rien.
APKB="$(dirname "$KCFG")/APKBUILD"
somme="$(sha512sum "$KCFG" | cut -d' ' -f1)"
if grep -q "^$somme  $(basename "$KCFG")\$" "$APKB"; then
    ok "APKBUILD : sha512 de la config a jour"
else
    sed -i "s/^[0-9a-f]\{128\}  $(basename "$KCFG")\$/$somme  $(basename "$KCFG")/" "$APKB" \
        && ok "APKBUILD : sha512 de la config mis a jour" \
        || die "sha512 de la config non remplace dans $APKB"
fi

# ── 2. LES REGLAGES pmbootstrap : Phosh, pas la console ─────────────────────
ui="$(pmb config ui 2>/dev/null | tail -1)"
if [ "$ui" != "phosh" ]; then
    warn "pmbootstrap config ui = « $ui » : un install ferait une VM sans bureau"
    pmb config ui phosh || die "impossible de poser ui=phosh"
fi
ok "ui = phosh, device = $(pmb config device 2>/dev/null | tail -1), jobs = $JOBS, work = $WORK"

# ── 3. LE NOYAU : LE RACCOURCI D ABORD ──────────────────────────────────────
# L apk du .deb osmo-build-pmos-kernel, copie dans le depot local de
# pmbootstrap avec son index et sa cle : « pmbootstrap install » le prefere
# au depot en ligne (meme version, paquet local). Sinon, un apk deja
# construit ici, plus recent que la config, qui a ppp_async.ko. Sinon on
# compile. --rebuild force la compilation.
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

# ── 4. L IMAGE ──────────────────────────────────────────────────────────────
# On ecrit l image que la VM utilise : elle ne doit pas tourner dessus.
# Une image deja fournie (/opt/user_interface/pmos/image/qemu-amd64.img.zst,
# la VM de reference) est decompressee a la place d un install : c est le
# raccourci n° 2 - OSMO_PMOS_FRESH=1 pour installer quand meme.
if pgrep -f "qemu-system-x86_64.*$(basename "$IMG")" >/dev/null 2>&1; then
    die "la VM tourne encore sur $IMG : arrete-la (osmo-pmos-qemu stop) puis relance"
fi
sudo -v || die "sudo refuse"
if [ "${OSMO_PMOS_FRESH:-0}" != 1 ] && [ ! -f "$IMG" ] && [ -f "$PM/image/qemu-amd64.img.zst" ] && command -v zstd >/dev/null 2>&1; then
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

# ── 5. LA VM, ET LE MODEM DES QU ELLE REPOND ────────────────────────────────
# osmo-pmos-qemu garde la main (fenetre SDL) et son guetteur branche le modem
# et la voix tout seul (osmo-pmos-setup) des que le SSH de la VM repond.
QEMU="$(command -v osmo-pmos-qemu 2>/dev/null || echo "$PM/bin/osmo-pmos-qemu.sh")"
export OSMO_PMOS_FROM_BUILD=1     # osmo-pmos-qemu ne doit pas nous rappeler
exec "$QEMU" "$FORMAT"
