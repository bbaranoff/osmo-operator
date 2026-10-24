#!/bin/bash
# =============================================================================
# osmo-firmwares-install.sh - LES FIRMWARES TELEPHONE HORS ISO (supplements)
#
# [2026-10-23] Source par addition.sh (--gnuarm, --magnetite, --trx, --fernvale,
# --simcom). Chaque fonction est IDEMPOTENTE (un arbre deja clone n est pas
# reclone, un binaire deja sorti n est pas refait sans OSMO_FW_REFAIRE=1) et
# rien n est fatal : un miroir absent ne doit pas arreter les autres supplements.
#
#   osmo_gnuarm_install     la chaine historique d osmocom-bb : arm-elf-gcc 4.5.2,
#                           TIREE de l image Docker osmocom-bb-trx (pas recompilee)
#                           dans /root/gnuarm, et le lien libmpfr.so.4 -> libmpfr.so.6
#                           que son cc1 reclame
#   osmo_magnetite_install  FreeCalypso Magnetite pour le Motorola C139 (le vrai
#                           firmware TI) : Wine + environnement TI TMS470, sources
#                           git figees, patchs du banc, image flash de 4 MiB
#   osmo_calypso_fw_install le firmware Calypso du banc (layer1 GPRS, rssi...)
#                           recompile avec gnuarm depuis osmocom-bb eac4eed1 + patchs
#   osmo_trx_install        osmocom-bb-trx : l image Docker publiee (cote hote,
#                           ubuntu 16.04) et le firmware trx (TX actif) compile
#                           avec gnuarm
#   osmo_fernvale_install   MediaTek MT6260 (Fernvale) : fernly, fernvale-nuttx,
#                           osmocom-bb-mtk-layer1, avec arm-none-eabi
#   osmo_simcom_install     la documentation et les SDK SIMCom (~3,4 Go)
# =============================================================================

: "${GREEN:=}"; : "${YELLOW:=}"; : "${RED:=}"; : "${CYAN:=}"; : "${BOLD:=}"; : "${NC:=}"
: "${GSM_ROOT:=/opt/GSM}"
: "${REPO:=${DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
: "${OSMO_FW_JOBS:=$(nproc 2>/dev/null || echo 4)}"
OSMO_FW_LOG="${OSMO_FW_LOG:-/var/log/osmo-firmwares}"

_fw_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_fw_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_fw_err()  { echo -e "  ${RED}✗${NC} $*"; }
_fw_log()  { mkdir -p "$OSMO_FW_LOG" 2>/dev/null; echo "$OSMO_FW_LOG/$1.log"; }

# apt sans question, une seule fois par execution du supplement
_fw_apt() {
    if [ -z "${_FW_APT_UPDATE:-}" ]; then apt-get update -qq >/dev/null 2>&1 || true; _FW_APT_UPDATE=1; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >>"$(_fw_log apt)" 2>&1
}

# git clone si absent ; rien sinon (on ne touche pas a un arbre de travail existant)
_fw_clone() {   # url dest [branche]
    local url="$1" dest="$2" br="${3:-}"
    if [ -d "$dest/.git" ]; then _fw_ok "$(basename "$dest") deja present ($dest)"; return 0; fi
    git clone -q ${br:+-b "$br"} "$url" "$dest" >>"$(_fw_log git)" 2>&1 \
        && _fw_ok "$(basename "$dest") clone ($url${br:+ $br})" \
        || { _fw_err "clone de $url impossible (voir $(_fw_log git))"; return 1; }
}

# [2026-10-23] LE BUG .map D OSMOCOM-BB. Le fichier .map est demande a l edition
# de liens sous deux formes, cassees toutes deux des que le lien passe par le
# pilote gcc ($(CC)) :
#   « -Map board/... »       (jolly/testing, MTK) : gcc lit -Map comme -M -ap ;
#   « -Wl,-Map board/... »   (osmocom-bb amont, eac4eed1) : -Map part a ld mais le
#                            NOM part a gcc, comme fichier d entree : « board/
#                            compal_e88/hello_world.highram.map : No such file ».
# Les deux deviennent -Wl,-Map,<fichier> (virgule). Par $(LD) directement (gnuarm
# sur jolly/testing) « -Map fichier » est juste : on n y touche pas. Le script
# solve_envs.py, lui, est en Python 2 (print sans parentheses) : sans python2 sur
# l hote, aucun environnement n est resolu et le firmware sort sans .bin, en silence.
_fw_bb_corriger() {   # racine/src/target/firmware
    local fw="$1" mk="$1/Makefile.inc"
    if [ -f "$mk" ] && grep -q '^\s*-Wl,-Map board' "$mk"; then
        sed -i 's|^\(\s*\)-Wl,-Map board/|\1-Wl,-Map,board/|' "$mk"
        _fw_ok "Makefile.inc : -Wl,-Map <fichier> -> -Wl,-Map,<fichier>"
    fi
    if [ -f "$mk" ] && grep -q '^\s*-Map board' "$mk" \
       && grep -B2 '^\s*-Map board' "$mk" | grep -q '\$(CC)'; then
        sed -i 's|^\(\s*\)-Map board/\$(2)/\$(1)\.\$(3)\.map |\1-Wl,-Map,board/$(2)/$(1).$(3).map |' "$mk"
        _fw_ok "Makefile.inc : -Map -> -Wl,-Map,<fichier> (lien par gcc)"
    fi
    if [ -f "$fw/solve_envs.py" ] && grep -q "^\s*print ' '" "$fw/solve_envs.py"; then
        sed -i "1s|python\$|python3|; s|^\(\s*\)print ' '.join(envs)|\1print(' '.join(envs))|" "$fw/solve_envs.py"
        _fw_ok "solve_envs.py passe en Python 3"
    fi
}

# ── gnuarm ───────────────────────────────────────────────────────────────────
# [2026-10-24] LA CHAINE N EST PLUS RECONSTRUITE. gnu-arm-installer (binutils,
# gcc 4.5.2, newlib 1.19 depuis les sources) prenait de longues minutes et
# dependait de miroirs qui disparaissent (newlib a deja quitte sources.redhat.com).
# L image osmocom-bb-trx, deja tiree pour --trx, porte la meme chaine, construite
# une fois pour toutes : /root/gnuarm/install. On la copie hors de l image
# (docker create + docker cp, sans lancer de conteneur) vers $GNUARM_DIR/install.
# Ses binaires viennent d Ubuntu 16.04 : sur noble il ne leur manque que
# libmpfr.so.4, le lien pose plus bas. Teste : compilation et lien d un .c
# avec newlib (-mcpu=arm7tdmi) par arm-elf-gcc 4.5.2.
GNUARM_DIR="${GNUARM_DIR:-/root/gnuarm}"
OSMOCOM_BB_TRX_IMAGE="${OSMOCOM_BB_TRX_IMAGE:-ghcr.io/bbaranoff/osmocom-bb-trx:main}"
osmo_gnuarm_install() {
    echo -e "${BOLD}== gnuarm (arm-elf-gcc 4.5.2, image $OSMOCOM_BB_TRX_IMAGE) ==${NC}"
    if [ ! -x "$GNUARM_DIR/install/bin/arm-elf-gcc" ]; then
        if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
            _fw_err "docker absent ou arrete : gnuarm vient de l image $OSMOCOM_BB_TRX_IMAGE (addition.sh --docker)"
            return 1
        fi
        local log c; log="$(_fw_log gnuarm)"
        docker pull "$OSMOCOM_BB_TRX_IMAGE" >>"$log" 2>&1 \
            || { _fw_err "docker pull $OSMOCOM_BB_TRX_IMAGE en echec (voir $log)"; return 1; }
        c="$(docker create "$OSMOCOM_BB_TRX_IMAGE" 2>>"$log")" \
            || { _fw_err "docker create en echec (voir $log)"; return 1; }
        mkdir -p "$GNUARM_DIR"
        rm -rf "$GNUARM_DIR/install"
        docker cp -q "$c:/root/gnuarm/install" "$GNUARM_DIR/install" >>"$log" 2>&1
        local rc=$?
        docker rm -f "$c" >/dev/null 2>&1
        [ "$rc" = 0 ] || { _fw_err "docker cp de /root/gnuarm/install en echec (voir $log)"; return 1; }
        _fw_ok "gnuarm copie depuis l image ($GNUARM_DIR/install, $(du -sh "$GNUARM_DIR/install" | cut -f1))"
    fi
    # [2026-10-23] cc1 de gcc 4.5.2 est lie a libmpfr.so.4, que noble ne fournit plus
    # (libmpfr.so.6, meme ABI pour ce qu il en fait) : sans ce lien, « cc1: error while
    # loading shared libraries: libmpfr.so.4 ».
    if [ ! -e /usr/local/lib/libmpfr.so.4 ]; then
        local m6; m6="$(ls /usr/lib/*-linux-gnu/libmpfr.so.6 2>/dev/null | head -1)"
        if [ -n "$m6" ]; then ln -sf "$m6" /usr/local/lib/libmpfr.so.4 && ldconfig && _fw_ok "lien libmpfr.so.4 -> $m6"
        else _fw_warn "libmpfr.so.6 introuvable : apt install libmpfr6"; fi
    fi
    if echo 'int main(void){return 0;}' | "$GNUARM_DIR/install/bin/arm-elf-gcc" -x c -c -o /dev/null - 2>/dev/null; then
        _fw_ok "arm-elf-gcc $("$GNUARM_DIR/install/bin/arm-elf-gcc" -dumpversion) operationnel ($GNUARM_DIR/install/bin)"
    else
        _fw_err "arm-elf-gcc ne compile pas (cc1, libmpfr ?)"; return 1
    fi
    # [2026-10-24] $GNUARM_DIR/install/bin dans le PATH de tout shell de connexion
    # (scripts/osmo-gnuarm-profile.sh -> /etc/profile.d/97-osmo-gnuarm.sh)
    if [ -f "${REPO:-/opt/GSM/osmo-operator}/scripts/osmo-gnuarm-profile.sh" ]; then
        install -m644 "${REPO:-/opt/GSM/osmo-operator}/scripts/osmo-gnuarm-profile.sh" /etc/profile.d/97-osmo-gnuarm.sh \
            && _fw_ok "PATH : $GNUARM_DIR/install/bin (/etc/profile.d/97-osmo-gnuarm.sh, nouveaux shells)"
    fi
}

# ── Magnetite (C139) ─────────────────────────────────────────────────────────
# [2026-10-24] PLUS RIEN DE freecalypso.org : son FTP plafonne a ~18 Ko/s (52 Mo
# d environnement TI = 45 min). github.com/bbaranoff/fc-magnetite porte l historique
# hg converti (pointe 9394305d4ff5, l amont sous les patchs du banc) et, dans
# freecalypso-env/, l environnement Wine, le bootloader Compal et freecalypso-tools.
FC_MAGNETITE_GIT="${FC_MAGNETITE_GIT:-https://github.com/bbaranoff/fc-magnetite}"
FC_ENV_URL="${FC_ENV_URL:-https://raw.githubusercontent.com/bbaranoff/fc-magnetite/main/freecalypso-env}"
osmo_magnetite_install() {
    echo -e "${BOLD}== FreeCalypso Magnetite (C139) : Wine + TI TMS470 ==${NC}"
    local fcm="$GSM_ROOT/fc-magnetite" fht="$GSM_ROOT/fc-host-tools" wdl="$GSM_ROOT/fc-wine-dl" \
          bdl="$GSM_ROOT/fc-dl" out="$GSM_ROOT/firmware/magnetite" log; log="$(_fw_log magnetite)"
    # Wine 32 bits : le TMS470 (cl470, asm470, lnk470) est un binaire Windows 32 bits
    dpkg --print-foreign-architectures | grep -qx i386 || dpkg --add-architecture i386
    _FW_APT_UPDATE=""
    _fw_apt git wine wine64 wine32:i386 xz-utils wget build-essential \
        || { _fw_err "installation de Wine en echec (voir $(_fw_log apt))"; return 1; }
    _fw_ok "wine $(wine --version 2>/dev/null)"
    # les sources : Magnetite (le depot git, freecalypso-env/ compris) et les outils
    # hote FreeCalypso (rvinterf, fc-shell, fc-fsio : run.sh en a besoin). Un ancien
    # clone hg reste tel quel : l environnement se prend alors par FC_ENV_URL.
    if [ ! -d "$fcm/.hg" ] && [ ! -d "$fcm/.git" ]; then
        git clone -q "$FC_MAGNETITE_GIT" "$fcm" >>"$log" 2>&1 \
            || { _fw_err "git clone fc-magnetite en echec (voir $log)"; return 1; }
        _fw_ok "fc-magnetite clone ($FC_MAGNETITE_GIT)"
    fi
    # _fc_env <fichier> <destination> : la copie du clone, sinon le depot sur GitHub
    _fc_env() {
        [ -s "$2" ] && return 0
        if [ -s "$fcm/freecalypso-env/$1" ]; then cp "$fcm/freecalypso-env/$1" "$2"
        else wget -q -O "$2" "$FC_ENV_URL/$1" >>"$log" 2>&1 || { rm -f "$2"; return 1; }; fi
    }
    if [ ! -f "$fht/Makefile" ]; then
        mkdir -p "$fht" "$wdl"
        _fc_env freecalypso-tools.tar.xz "$wdl/freecalypso-tools.tar.xz" \
            && tar xJf "$wdl/freecalypso-tools.tar.xz" -C "$fht" --strip-components=1 >>"$log" 2>&1 \
            || _fw_warn "freecalypso-tools : extraction en echec"
    fi
    [ -x "$fht/rvinterf/lowlevel/rvinterf" ] || make -C "$fht" -j"$OSMO_FW_JOBS" >>"$log" 2>&1 \
        || _fw_warn "outils hote FreeCalypso : make en echec (voir $log)"
    # les patchs du banc (ARFCN force, enregistrement auto, SMS, MMI) : un seul fichier,
    # regenere par `hg diff` dans fc-magnetite (patches/fc-magnetite-banc.patch)
    local p="$REPO/patches/fc-magnetite-banc.patch"
    if [ -f "$p" ]; then
        if (cd "$fcm" && patch -p1 -R --dry-run -s -f <"$p" >/dev/null 2>&1); then _fw_ok "patchs du banc deja appliques"
        elif (cd "$fcm" && patch -p1 -s -f <"$p" >>"$log" 2>&1); then _fw_ok "patchs du banc appliques ($(basename "$p"))"
        else _fw_warn "$(basename "$p") ne s applique pas sur cet arbre (voir $log)"; fi
    fi
    # l environnement TI installe (compilateur, cygwin, perl, java) dans ~/.wine/drive_c
    mkdir -p "$wdl" "$bdl" "$out"
    local f
    for f in installed-env.tar.xz nowhine.c winebuild.sh README; do
        _fc_env "$f" "$wdl/$f" || _fw_warn "telechargement $f en echec"
    done
    if [ ! -d "$HOME/.wine/drive_c/Dvpt_tools" ]; then
        WINEDEBUG=-all wineboot -i >>"$log" 2>&1
        tar xJf "$wdl/installed-env.tar.xz" -C "$HOME/.wine/drive_c" >>"$log" 2>&1 \
            && _fw_ok "environnement TI pose dans $HOME/.wine/drive_c" \
            || { _fw_err "environnement TI : extraction en echec"; return 1; }
        WINEDEBUG=-all wineboot -u >>"$log" 2>&1
    fi
    [ -x /usr/local/bin/nowhine ] || gcc -O2 -o /usr/local/bin/nowhine "$wdl/nowhine.c" >>"$log" 2>&1 \
        || _fw_warn "nowhine : compilation en echec"
    # la compilation : c139, hybrid-ui-vo. SANS -j : le TMS470 sous Wine ecrit des
    # fichiers temporaires a noms fixes, deux cl470 en parallele se marchent dessus.
    # [2026-10-23] LA VARIANTE DU BANC : DWNLD 0 (FC_MAGNETITE_DWNLD), dossier -nopatch. Le
    # patch DSP telecharge par la L1 TI (DWNLD 1) echouait sous l emulation (LA_LoadPage :
    # course sur LA_TIMEOUT) ; le banc tourne depuis le 21/10 sur ce build-la, verifie
    # octet pour octet contre c139-flash.img. L1_DYN_DSP_DWNLD reste a 1 (a 0,
    # l1audio_async.c ne compile pas). FC_MAGNETITE_DWNLD=1 : le build d origine.
    local dwnld="${FC_MAGNETITE_DWNLD:-0}" suf="" b
    [ "$dwnld" = 0 ] && suf="-nopatch"
    b="$fcm/build-c139-hybrid-ui-vo$suf"
    if [ ! -s "$b/fwimage.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
        ( cd "$fcm" && (cd helpers && make) && ./configure.sh --clean c139 hybrid-ui-vo ${suf:+SUFFIX=$suf} \
            && sed -i "s/^#define DWNLD [01]\$/#define DWNLD $dwnld/" "$b/config/swconfig.cfg" \
            && cd "$b" && WINEDEBUG=-all make ) \
            >>"$log" 2>&1 || { _fw_err "compilation Magnetite en echec (voir $log)"; return 1; }
    fi
    _fw_ok "fwimage.bin (DWNLD $dwnld) : $(stat -c %s "$b/fwimage.bin") octets, $b"
    # l image flash de 4 MiB : bootloader Compal FreeCalypso a 0, fwimage.bin a 0x10000,
    # FFS a 0x3C0000 (IMEI, afcparams, rfcap ecrits par fc-fsio). Une image EXISTANTE ne
    # change que sa zone firmware : bootloader et FFS du banc restent tels quels (la zone
    # du bootloader de l image du banc differe de 4 octets du fichier FreeCalypso, au
    # vecteur 0x10, depuis le 22/10, d origine inconnue ; le banc demarre avec). Copie
    # de l ancienne image en .avant-supplement.
    _fc_env compal-flash-boot-for-fc.bin "$bdl/compal-flash-boot-for-fc.bin" \
        || _fw_warn "bootloader Compal : telechargement en echec"
    [ -f "$out/c139-flash.img" ] && cp -p "$out/c139-flash.img" "$out/c139-flash.img.avant-supplement"
    python3 - "$bdl/compal-flash-boot-for-fc.bin" "$b/fwimage.bin" "$out/c139-flash.img" <<'EOF' \
        && _fw_ok "image flash $out/c139-flash.img" || _fw_err "assemblage de l image flash en echec"
import os, sys
boot, fw, img_path = sys.argv[1:4]
f = open(fw, "rb").read()
if os.path.exists(img_path) and os.path.getsize(img_path) == 4 << 20:
    img = bytearray(open(img_path, "rb").read())              # bootloader + FFS du banc gardes
    img[0x10000:0x3C0000] = b"\xff" * (0x3C0000 - 0x10000)
else:
    img = bytearray(b"\xff" * (4 << 20))
    b = open(boot, "rb").read(); img[0:len(b)] = b
img[0x10000:0x10000 + len(f)] = f
open(img_path, "wb").write(img)
EOF
    echo -e "  ${CYAN}→${NC} lancer : ${BOLD}./start.sh --bts-classique --ms-magnetite --gapk${NC} (appels : ENCRYPTION=\"a5 0\" et --regen)"
}

# ── osmocom-bb-trx ───────────────────────────────────────────────────────────
osmo_trx_install() {
    echo -e "${BOLD}== osmocom-bb-trx (jolly/testing, TX) ==${NC}"
    # cote hote (layer23 --enable-transceiver, libosmocore 1.1.0) : l image publiee
    # (github.com/bbaranoff/osmocom-bb-trx, ubuntu 16.04 + gcc 4.9/5 + gnuarm)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker pull "$OSMOCOM_BB_TRX_IMAGE" >>"$(_fw_log trx)" 2>&1; then _fw_ok "image $OSMOCOM_BB_TRX_IMAGE"
        else _fw_warn "docker pull $OSMOCOM_BB_TRX_IMAGE en echec (voir $(_fw_log trx))"; fi
    else
        _fw_warn "docker absent ou arrete : l image osmocom-bb-trx n est pas tiree (addition.sh --docker)"
    fi
    # le firmware trx, avec la chaine gnuarm, dans un arbre a part (celui du banc,
    # osmocom-bb-transceiver, garde ses patchs et n est pas touche)
    osmo_gnuarm_install || return 1
    local t="$GSM_ROOT/osmocom-bb-trx" log; log="$(_fw_log trx)"
    _fw_apt autoconf automake libtool pkg-config python3 git   # libosmocore cote cible
    _fw_clone https://gitea.osmocom.org/phone-side/osmocom-bb "$t" jolly/testing || return 1
    sed -i 's/^#CFLAGS += -DCONFIG_TX_ENABLE/CFLAGS += -DCONFIG_TX_ENABLE/' "$t/src/target/firmware/Makefile"
    _fw_bb_corriger "$t/src/target/firmware"
    if [ ! -s "$t/src/target/firmware/board/compal_e88/trx.highram.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
        ( cd "$t/src" && PATH="$GNUARM_DIR/install/bin:$PATH" make -j"$OSMO_FW_JOBS" firmware ) >>"$log" 2>&1 \
            || { _fw_err "firmware trx en echec (voir $log)"; return 1; }
    fi
    if [ -s "$t/src/target/firmware/board/compal_e88/trx.highram.bin" ]; then
        _fw_ok "firmware trx (TX) : $t/src/target/firmware/board/compal_e88/trx.{highram,e88loader,e88flash}.bin"
    else
        _fw_err "trx.highram.bin absent apres make (voir $log)"; return 1
    fi
}

# ── firmware Calypso du banc (layer1, rssi...) avec gnuarm ──────────────────
# Le firmware livre est celui du depot bbaranoff/firmware (/opt/GSM/firmware,
# board/compal_e88/{layer1,rssi,trx}.highram). Celui-ci le RECOMPILE depuis l arbre
# osmocom-bb du banc : eac4eed1 + les patchs de patches/ (dont
# osmocom-bb-firmware-gprs.patch, le layer1 GPRS), avec arm-elf-gcc 4.5.2.
# layer1.compalram deborde de LRAM (3448 octets) avec le GPRS et gcc 4.5 : il n est
# pas utilise par le banc (highram), d ou make -k. OSMO_FW_INSTALLER=1 recopie les
# .highram.{elf,bin} dans /opt/GSM/firmware (anciens en .avant-<date>).
OSMOCOM_BB_REF="${OSMOCOM_BB_REF:-eac4eed1}"
osmo_calypso_fw_install() {
    echo -e "${BOLD}== firmware Calypso du banc (osmocom-bb, gnuarm) ==${NC}"
    osmo_gnuarm_install || return 1
    local t="$GSM_ROOT/osmocom-bb" fw log p; log="$(_fw_log calypso-fw)"
    _fw_apt autoconf automake libtool pkg-config python3 git
    if [ ! -d "$t/.git" ]; then
        _fw_clone https://gitea.osmocom.org/phone-side/osmocom-bb "$t" || return 1
        git -C "$t" checkout -q "$OSMOCOM_BB_REF" && _fw_ok "osmocom-bb epingle sur $OSMOCOM_BB_REF"
    fi
    for p in "$REPO"/patches/osmocom-bb-*.patch; do
        case "$p" in *transceiver*) continue ;; esac     # ceux-la visent osmocom-bb-transceiver
        if git -C "$t" apply -R --check "$p" 2>/dev/null; then :
        elif git -C "$t" apply --check "$p" 2>/dev/null; then git -C "$t" apply "$p" && _fw_ok "patch $(basename "$p")"
        else _fw_warn "$(basename "$p") ne s applique pas sur cet arbre"; fi
    done
    fw="$t/src/target/firmware"
    _fw_bb_corriger "$fw"
    ( cd "$t/src" && PATH="$GNUARM_DIR/install/bin:$PATH" make libosmocore-target \
        && PATH="$GNUARM_DIR/install/bin:$PATH" make -k -j"$OSMO_FW_JOBS" -C target/firmware \
           CROSS_COMPILE=arm-elf- BOARDS=compal_e88 ) >>"$log" 2>&1
    local b="$fw/board/compal_e88" ok=1 a
    for a in layer1 rssi; do
        if [ -s "$b/$a.highram.bin" ]; then _fw_ok "$a.highram.bin ($b)"; else _fw_err "$a.highram.bin absent (voir $log)"; ok=0; fi
    done
    if [ "$ok" = 1 ] && [ "${OSMO_FW_INSTALLER:-0}" = 1 ]; then
        local dst="$GSM_ROOT/firmware/board/compal_e88" d; d="$(date +%Y%m%d-%H%M)"
        mkdir -p "$dst"
        for a in layer1 rssi; do
            for x in elf bin; do
                [ -f "$dst/$a.highram.$x" ] && cp -p "$dst/$a.highram.$x" "$dst/$a.highram.$x.avant-$d"
                cp -f "$b/$a.highram.$x" "$dst/"
            done
        done
        _fw_ok "pose dans $dst (anciens en .avant-$d)"
    elif [ "$ok" = 1 ]; then
        echo -e "  ${CYAN}→${NC} le banc garde le firmware livre ; OSMO_FW_INSTALLER=1 pour poser celui-ci dans $GSM_ROOT/firmware"
    fi
    [ "$ok" = 1 ]
}

# ── Fernvale (MT6260) ────────────────────────────────────────────────────────
osmo_fernvale_install() {
    echo -e "${BOLD}== Fernvale (MediaTek MT6260) ==${NC}"
    local log; log="$(_fw_log fernvale)"
    _fw_apt gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi build-essential \
            libusb-1.0-0-dev genromfs python3 autoconf automake libtool pkg-config git \
        || _fw_warn "paquets arm-none-eabi : installation incomplete (voir $(_fw_log apt))"
    local fl="$GSM_ROOT/fernly" nx="$GSM_ROOT/fernvale-nuttx" mtk="$GSM_ROOT/osmocom-bb-mtk-layer1"
    _fw_clone https://github.com/bbaranoff/fernly "$fl"
    _fw_clone https://github.com/bbaranoff/fernvale-nuttx "$nx"
    _fw_clone https://github.com/bbaranoff/osmocom-bb-mtk-layer1 "$mtk" mtk-layer1
    # fernly : l OS de rétro-ingenierie et son chargeur USB (fernly-usb-loader, natif)
    if [ -d "$fl" ]; then
        if ( cd "$fl" && make CROSS_COMPILE=arm-none-eabi- ) >>"$log" 2>&1; then
            _fw_ok "fernly : $fl/build/firmware.bin + fernly-usb-loader"
        else _fw_err "fernly : make en echec (voir $log)"; fi
        [ -f "$fl/95-fernvale-test.rules" ] && install -D -m644 "$fl/95-fernvale-test.rules" /etc/udev/rules.d/95-fernvale-test.rules \
            && udevadm control --reload 2>/dev/null; true
    fi
    # NuttX (kosagi-fernvale/nsh) : les correctifs de compilation sont deja dans le depot
    if [ -d "$nx/nuttx" ]; then
        if [ ! -s "$nx/nuttx/nuttx.bin" ] || [ "${OSMO_FW_REFAIRE:-0}" = 1 ]; then
            ( cd "$nx/nuttx/tools" && ./configure.sh kosagi-fernvale/nsh && cd .. \
                && make CROSSDEV=arm-none-eabi- ARCROSSDEV=arm-none-eabi- ) >>"$log" 2>&1 \
                || _fw_err "NuttX : make en echec (voir $log)"
        fi
        [ -s "$nx/nuttx/nuttx.bin" ] && _fw_ok "NuttX : $nx/nuttx/nuttx.bin"
    fi
    # osmocom-bb layer1 MTK (bringup + layer1 MT6260)
    if [ -d "$mtk/src" ]; then
        _fw_bb_corriger "$mtk/src/target/firmware"
        if ( cd "$mtk/src" && make mtk-firmware CROSS_HOST=arm-none-eabi ) >>"$log" 2>&1 \
           && [ -s "$mtk/src/target/firmware/board/fernvale/layer1.mt6260.bin" ]; then
            _fw_ok "layer1 MTK : $mtk/src/target/firmware/board/fernvale/{bringup,layer1}.mt6260.bin"
        else _fw_err "layer1 MTK : make mtk-firmware en echec (voir $log)"; fi
    fi
    echo -e "  ${CYAN}→${NC} charger : ${BOLD}$fl/build/fernly-usb-loader -s /dev/fernvale $fl/build/usb-loader.bin <payload.bin>${NC}"
}

# ── SIMCom ───────────────────────────────────────────────────────────────────
osmo_simcom_install() {
    echo -e "${BOLD}== SIMCom : documentation et SDK ==${NC}"
    # ~3,4 Go (archives rar des SDK, rapports) : un clone sans historique
    local d="$GSM_ROOT/simcom"
    if [ -d "$d/.git" ]; then _fw_ok "simcom deja present ($d)"; return 0; fi
    git clone -q --depth 1 https://github.com/bbaranoff/simcom "$d" >>"$(_fw_log git)" 2>&1 \
        && _fw_ok "simcom clone dans $d ($(du -sh "$d" 2>/dev/null | cut -f1))" \
        || _fw_err "clone de bbaranoff/simcom en echec"
    _fw_apt p7zip-full unrar 2>/dev/null || true   # les SDK sont en .rar / .7z
}
