#!/bin/bash
# =============================================================================
# osmo-lte-install.sh - LA 4G DU BANC, POSEE UNE FOIS POUR LES TROIS CHEMINS.
#
# [2026-09-08] srsRAN (ZeroMQ) et Open5GS vivaient HORS du depot : /opt/LTE
# compile a la main, Open5GS dans /root/open5gs, les configs dans
# ~/.config/srsran de root, open5gs-epc.sh dans /usr/local/bin. Rien de tout
# cela n arrivait dans l ISO, ni sur une machine passee par addition.sh. Ce
# script est l endroit UNIQUE ou la 4G est posee ; les trois chemins l appellent :
#   - addition.sh            (une machine deja installee)      : --all
#   - update.sh              (le rattrapage)                    : --configs --launchers
#   - iso_modules/72-lte-pmos.sh (le build ISO, dans le chroot) : --deps --configs --launchers
#     (les binaires y viennent des .deb du build docker : osmo-build-srsran,
#      osmo-build-open5gs, poses par 50-injection-image.sh)
#
# OU VIVENT LES CHOSES :
#   /opt/LTE/srsRAN_4G          les sources et le build srsRAN (ZeroMQ), binaires
#                               dans /usr/local/bin (srsenb, srsue, srsepc)
#   /opt/LTE/open5gs            les sources Open5GS ; prefixe d installation
#                               /opt/LTE/open5gs/install (bin, etc/open5gs, var/log)
#   /root/.config/srsran        enb.conf ue.conf sib.conf rr.conf rb.conf user_db.csv
#                               = configs/srsran du depot (srs* lisent le HOME de root)
#   /usr/local/bin/osmo-lte     le lanceur (tools/osmo-lte.sh)
#   /usr/local/bin/osmo-epc     le coeur (tools/osmo-epc.sh), alias open5gs-epc.sh
#
#   osmo-lte-install                 = --deps --debs --configs --launchers
#   osmo-lte-install --all           idem, plus --build si les binaires manquent
#   osmo-lte-install --build         compile srsRAN et Open5GS dans /opt/LTE
#   osmo-lte-install --deps          les paquets apt (runtime + build), mongodb-org
#   osmo-lte-install --debs          pose les .deb du cache (/var/cache/osmo-debs)
#   osmo-lte-install --configs       pose les configs du depot
#   osmo-lte-install --launchers     osmo-lte, osmo-epc dans /usr/local/bin
#   osmo-lte-install --force         (avec --configs) ecrase les configs existantes
#
# Idempotent, non fatal paquet par paquet. Utilisable en session ET dans le
# chroot de l ISO (pas de systemd : les systemctl y echouent sans arreter).
# =============================================================================
set -u

REPO="${OSMO_REPO:-${DIR:-/opt/GSM/osmo-operator}}"
LTE="${OSMO_LTE_ROOT:-/opt/LTE}"
O5GS="$LTE/open5gs"
O5GS_PREFIX="${OPEN5GS_PREFIX:-$O5GS/install}"
SRS="$LTE/srsRAN_4G"
SRS_DIR="${OSMO_SRSRAN_DIR:-/root/.config/srsran}"
DEB_CACHE="${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"
SRS_REF="${OSMO_SRSRAN_REF:-release_25_10}"
O5GS_REF="${OSMO_OPEN5GS_REF:-v2.8.0}"
JOBS="${JOBS:-$(nproc)}"

: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${RED:=}"; : "${BOLD:=}"; : "${NC:=}"
_l_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_l_ok()   { echo -e "      ${GREEN}✓${NC} $*"; }
_l_warn() { echo -e "      ${YELLOW}!${NC} $*"; }
_l_err()  { echo -e "      ${RED}✗${NC} $*" >&2; }

# ── LES PAQUETS ──────────────────────────────────────────────────────────────
# Runtime (ce que ldd de srsenb et d open5gs-mmed reclame) ET build : l ISO
# est un atelier, on doit pouvoir refaire « make » dans /opt/LTE. mongodb-org
# vient du depot de MongoDB (noble/8.0) : la cle et la source sont posees si
# elles manquent. Non fatal paquet par paquet.
_lte_apt_mongo_source() {
    local k=/usr/share/keyrings/mongodb-server-8.0.gpg
    local s=/etc/apt/sources.list.d/mongodb-org-8.0.list
    [ -s "$s" ] && [ -s "$k" ] && return 0
    command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 || { _l_warn "curl/gpg absents : pas de depot MongoDB"; return 1; }
    if curl -fsSL --retry 3 https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor --yes -o "$k" 2>/dev/null; then
        echo "deb [ arch=amd64,arm64 signed-by=$k ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > "$s"
        _l_ok "depot MongoDB 8.0 pose ($s)"
    else
        _l_warn "cle MongoDB injoignable : mongodb-org ne s installera pas (HSS/PCRF sans base)"
        return 1
    fi
}

lte_deps() {
    export DEBIAN_FRONTEND=noninteractive
    _l_say "paquets de la 4G (srsRAN ZeroMQ + Open5GS + MongoDB)"
    _lte_apt_mongo_source || true
    apt-get update -y >/dev/null 2>&1 || true
    local p
    for p in libzmq5 libzmq3-dev libboost-program-options-dev libmbedtls-dev libconfig++-dev libfftw3-dev libsctp-dev lksctp-tools cmake \
             meson ninja-build flex bison libgnutls28-dev libgcrypt20-dev libssl-dev libidn-dev libmongoc-dev libbson-dev \
             libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev libtins-dev libtalloc-dev libc-ares-dev \
             mongodb-org mongodb-mongosh mongodb-database-tools; do
        dpkg -s "$p" >/dev/null 2>&1 && continue
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
            && _l_ok "$p" || _l_warn "$p indisponible (apt) - ignore"
    done
    # mongod : ACTIVE au boot (osmo-epc le lance de toute facon s il dort).
    # Dans un chroot sans systemd, enable pose le lien tout de meme.
    systemctl enable mongod >/dev/null 2>&1 && _l_ok "mongod active au demarrage" || true
}

# ── LES .deb DU BUILD DOCKER ─────────────────────────────────────────────────
# osmo-build-libzmq, osmo-build-srsran, osmo-build-open5gs : produits par le
# Dockerfile (osmo-deb pack) ou par un snapshot de la machine de reference
# (packaging/snapshot-lte-debs.sh). Poses seulement si les binaires manquent.
lte_debs() {
    local n deb suite
    suite="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")"
    for n in libzmq srsran open5gs; do
        case "$n" in
            libzmq)  [ -e /usr/local/lib/libzmq.so.5 ] || [ -e /usr/lib/x86_64-linux-gnu/libzmq.so.5 ] && continue ;;
            srsran)  command -v srsenb >/dev/null 2>&1 && continue ;;
            open5gs) [ -x "$O5GS_PREFIX/bin/open5gs-mmed" ] && continue ;;
        esac
        deb="$(ls -1 "$DEB_CACHE"/osmo-build-${n}_*"~${suite}_$(dpkg --print-architecture).deb" 2>/dev/null | tail -1)"
        [ -n "$deb" ] || { _l_warn "$n : pas de binaire ni de .deb dans $DEB_CACHE (osmo-lte-install --build)"; continue; }
        dpkg -i --force-overwrite "$deb" >/dev/null 2>&1 && _l_ok "$n pose depuis $(basename "$deb")" || _l_warn "dpkg -i $(basename "$deb") a echoue"
    done
    ldconfig 2>/dev/null || true
}

# ── LA COMPILATION, DANS /opt/LTE ────────────────────────────────────────────
# srsRAN_4G avec ZeroMQ (libzmq3-dev d Ubuntu suffit : plus besoin de compiler
# libzmq et czmq a la main), Open5GS par meson avec le prefixe /opt/LTE/open5gs/
# install. Sous OSMO_DEB=1 (le Dockerfile), chaque etape sort en .deb via
# osmo-deb pack ; sinon make/ninja install direct.
lte_build() {
    mkdir -p "$LTE"
    local pack=""
    [ "${OSMO_DEB:-0}" = "1" ] && command -v osmo-deb >/dev/null 2>&1 && pack=1
    # ── LES VERSIONS DES .deb : UNE SEULE ECRITURE, POUR TOUT LE MONDE ───────
    # [2026-09-09] Elles etaient calculees a l arrache dans les deux appels a
    # `osmo-deb pack` ci-dessous, et les deux etaient FAUSSES :
    #   srsran  : "${SRS_REF#release_}+zmq" donnait 25_10+zmq - un souligne,
    #             que osmo-deb refuse (^[0-9][A-Za-z0-9.+~-]*$) : « version
    #             invalide : '25_10+zmq' ». Et comme `pack` meurt AVANT de
    #             lancer la commande qu on lui confie, le `make install`
    #             n avait jamais lieu : srsRAN compilait 3 minutes pour rien.
    #   open5gs : "${O5GS_REF#v}" donnait 2.8.0, sans le +git - le .deb sortait
    #             sous un nom que le `osmo-deb install open5gs 2.8.0+git` du
    #             Dockerfile ne retrouvait jamais : recompilation a chaque build.
    # Les noms qui font foi sont ceux du Dockerfile et de packaging/
    # snapshot-lte-debs.sh : osmo-build-srsran_25.10+zmq, osmo-build-open5gs_
    # 2.8.0+git. On les derive ici des memes refs git, en points.
    local srs_ver o5gs_ver
    srs_ver="${SRS_REF#release_}"; srs_ver="${srs_ver//_/.}+zmq"   # release_25_10 -> 25.10+zmq
    o5gs_ver="${O5GS_REF#v}+git"                                    # v2.8.0       -> 2.8.0+git
    if ! command -v srsenb >/dev/null 2>&1; then
        _l_say "srsRAN_4G $SRS_REF (ZeroMQ) -> $SRS"
        if [ ! -d "$SRS/.git" ]; then
            git clone --depth 1 -b "$SRS_REF" https://github.com/srsran/srsRAN_4G "$SRS" || { _l_err "clone srsRAN_4G"; return 1; }
        fi
        ( cd "$SRS" && mkdir -p build && cd build \
          && cmake -DENABLE_ZEROMQ=ON -DENABLE_GUI=OFF -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SOAPYSDR=OFF \
                   -DCMAKE_BUILD_TYPE=Release .. >/dev/null \
          && make -j"$JOBS" >/dev/null \
          && if [ -n "$pack" ]; then OSMO_DEB_SRC_ROOT="$LTE" OSMO_DEB_SRC="$SRS" osmo-deb pack srsran "$srs_ver" make install
             else make install >/dev/null; fi ) \
          && { ldconfig; _l_ok "srsRAN : $(command -v srsenb)"; } || { _l_err "srsRAN : compilation echouee"; return 1; }
    else
        _l_ok "srsRAN deja la ($(command -v srsenb))"
    fi
    if [ ! -x "$O5GS_PREFIX/bin/open5gs-mmed" ]; then
        _l_say "Open5GS $O5GS_REF -> $O5GS (prefixe $O5GS_PREFIX)"
        if [ ! -d "$O5GS/.git" ]; then
            git clone --depth 1 -b "$O5GS_REF" https://github.com/open5gs/open5gs "$O5GS" || { _l_err "clone open5gs"; return 1; }
        fi
        ( cd "$O5GS" \
          && { [ -f build/build.ninja ] || meson setup build --prefix="$O5GS_PREFIX" >/dev/null; } \
          && ninja -C build -j"$JOBS" >/dev/null \
          && if [ -n "$pack" ]; then OSMO_DEB_SRC_ROOT="$LTE" OSMO_DEB_SRC="$O5GS" osmo-deb pack open5gs "$o5gs_ver" ninja -C build install
             else ninja -C build install >/dev/null; fi ) \
          && { ldconfig; _l_ok "Open5GS : $O5GS_PREFIX/bin"; } || { _l_err "Open5GS : compilation echouee"; return 1; }
    else
        _l_ok "Open5GS deja la ($O5GS_PREFIX/bin/open5gs-mmed)"
    fi
}

# ── LES CONFIGS ──────────────────────────────────────────────────────────────
# Celles du depot, telles qu elles tournent sur le banc de reference :
#   configs/srsran/*   -> /root/.config/srsran   (eNB 0x19B, TAC 7, EARFCN 3350,
#                         MME 127.0.0.2, ZeroMQ 2000/2001 a 11.52e6, SIB3+SIB7,
#                         UE 001010001000001, APN srsapn, netns ue1)
#   configs/open5gs/*.yaml -> $PREFIX/etc/open5gs (MME 127.0.0.2, SGs vers
#                         OsmoMSC 127.0.0.1, TAC 7 / LAC 1, UE 10.45.0.0/16)
# Une config existante n est pas ecrasee (les reglages vivants du banc), sauf
# --force : on la garde en .bak-osmo a cote.
lte_configs() {
    local force="${1:-0}" f dst
    mkdir -p "$SRS_DIR"
    for f in "$REPO"/configs/srsran/*; do
        [ -f "$f" ] || continue
        dst="$SRS_DIR/$(basename "$f")"
        if [ -f "$dst" ] && [ "$force" != "1" ]; then continue; fi
        [ -f "$dst" ] && ! cmp -s "$f" "$dst" && cp -a "$dst" "$dst.bak-osmo"
        install -m644 "$f" "$dst"
    done
    _l_ok "srsRAN : configs dans $SRS_DIR ($(ls "$SRS_DIR" | grep -c '\.conf$') .conf, user_db.csv)"
    if [ -d "$O5GS_PREFIX/etc/open5gs" ] || [ "$force" = "1" ]; then
        mkdir -p "$O5GS_PREFIX/etc/open5gs" "$O5GS_PREFIX/var/log/open5gs"
        for f in "$REPO"/configs/open5gs/*.yaml; do
            [ -f "$f" ] || continue
            dst="$O5GS_PREFIX/etc/open5gs/$(basename "$f")"
            # Les yaml portent le prefixe /opt/LTE/open5gs/install : un autre
            # prefixe (OPEN5GS_PREFIX) est substitue a la volee.
            if [ -f "$dst" ] && [ "$force" != "1" ] && grep -q 'osmo-operator' "$dst" 2>/dev/null; then continue; fi
            [ -f "$dst" ] && ! cmp -s "$f" "$dst" && cp -a "$dst" "$dst.bak-osmo"
            sed "s#/opt/LTE/open5gs/install#$O5GS_PREFIX#g" "$f" > "$dst"
        done
        _l_ok "Open5GS : configs dans $O5GS_PREFIX/etc/open5gs"
    else
        _l_warn "Open5GS pas installe ($O5GS_PREFIX) : ses configs seront posees apres --build / --debs"
    fi
}

# ── LES LANCEURS ─────────────────────────────────────────────────────────────
lte_launchers() {
    local t
    for t in osmo-lte osmo-epc; do
        [ -f "$REPO/tools/$t.sh" ] || { _l_warn "$REPO/tools/$t.sh absent"; continue; }
        chmod 755 "$REPO/tools/$t.sh"
        ln -sfn "$REPO/tools/$t.sh" "/usr/local/bin/$t"
    done
    # L ancien nom du coeur, garde : les habitudes et les notes du banc.
    ln -sfn "$REPO/tools/osmo-epc.sh" /usr/local/bin/open5gs-epc.sh
    _l_ok "lanceurs : /usr/local/bin/osmo-lte, osmo-epc (alias open5gs-epc.sh)"
}

osmo_lte_install() {
    local deps=0 debs=0 configs=0 launchers=0 build=0 all=0 force=0 a rc=0
    for a in "$@"; do case "$a" in
        --deps) deps=1 ;; --debs) debs=1 ;; --configs) configs=1 ;; --launchers) launchers=1 ;;
        --build) build=1 ;; --all) all=1 ;; --force) force=1 ;;
        *) echo "osmo-lte-install : option inconnue $a" >&2; return 2 ;;
    esac; done
    if [ $((deps + debs + configs + launchers + build + all)) -eq 0 ]; then deps=1; debs=1; configs=1; launchers=1; fi
    if [ "$all" = 1 ]; then deps=1; debs=1; configs=1; launchers=1; fi
    [ "$deps" = 1 ] && lte_deps
    [ "$debs" = 1 ] && lte_debs
    if [ "$build" = 1 ] || { [ "$all" = 1 ] && { ! command -v srsenb >/dev/null 2>&1 || [ ! -x "$O5GS_PREFIX/bin/open5gs-mmed" ]; }; }; then
        # [2026-09-09] Le `|| true` d ici MENTAIT au Dockerfile : la compilation
        # tombait (MbedTLS absent), osmo-lte-install sortait 0, le « ECHEC build
        # srsRAN » n etait jamais imprime et l image n echouait que 200 lignes
        # plus bas sur le `test -x`. On garde la suite (configs, lanceurs : le
        # banc doit rester utilisable sans la 4G) mais le code de retour dit
        # desormais la verite. Les appelants encadrent deja (`|| true`,
        # `|| inst_hint`) : addition.sh, update.sh, install_modules/50-build.sh.
        lte_build || rc=1
    fi
    [ "$configs" = 1 ] && lte_configs "$force"
    [ "$launchers" = 1 ] && lte_launchers
    return $rc
}

# Source (addition.sh, update.sh) ou execute (ISO, ligne de commande).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "osmo-lte-install : root requis" >&2; exit 1; }
    osmo_lte_install "$@"
fi
