#!/bin/bash
# =============================================================================
# download_shannon.sh - BASEBAND SHANNON (Samsung) : FirmWire + son firmware.
#
# Supplement de addition.sh (case « shannon »), ou a la main :
#   bash download_shannon.sh            clone/met a jour FirmWire, verifie le firmware
#   sudo ./addition.sh --shannon        le meme, via le supplement
#
# Ce qu il fait :
#   1. clone FirmWire (github.com/bbaranoff/firmwire, fork de FirmWire/FirmWire) dans $FIRMWIRE_DIR
#      (defaut /opt/GSM/FirmWire), ou le met a jour en fast-forward ;
#   2. verifie le firmware Shannon : $FIRMWIRE_DIR/shannon_main.bin ;
#      s il est absent et que SHANNON_FIRMWARE_URL est donnee, le telecharge
#      (et le controle avec SHANNON_FIRMWARE_SHA256 si elle est donnee) ;
#   3. dit ce qui manque, sans rien inventer : aucune URL de firmware n est
#      codee ici.
#
# Variables :
#   FIRMWIRE_DIR           dossier de FirmWire          (/opt/GSM/FirmWire)
#   FIRMWIRE_REPO          depot git                    (https://github.com/bbaranoff/firmwire)
#   FIRMWIRE_REF           branche, tag ou commit a poser (vide = branche par defaut)
#   SHANNON_FIRMWARE_URL   URL directe du shannon_main.bin (optionnel)
#   SHANNON_FIRMWARE_SHA256  somme attendue du firmware (optionnel, conseille)
#   SHANNON_SKIP_PIP=1     ne pas afficher la commande pip des dependances
#   SHANNON_GHIDRA_DB_URL  URL de la base Ghidra db.1.gbf (defaut : Google Drive, ~1,1 Go)
#   SHANNON_GHIDRA_DB_SHA256  somme attendue de la base (optionnel, conseille)
#   SHANNON_GHIDRA_DIR     projet Ghidra (/opt/GSM/shannon_ghidra_proj)
#
# La base Ghidra n est PAS dans le depot shannon_ghidra_proj (gitignoree) :
# elle ne vient que de SHANNON_GHIDRA_DB_URL. Sans elle, rien n est pose et
# le projet reste sans analyse (il faut la refaire).
#
# Ne demande pas root : tout est ecrit sous FIRMWIRE_DIR. Rien n est fatal :
# un depot injoignable ne doit pas arreter le reste de addition.sh.
# =============================================================================

_sh_say()  { echo -e "  \033[0;36m→\033[0m $*"; }
_sh_ok()   { echo -e "      \033[0;32m✓\033[0m $*"; }
_sh_warn() { echo -e "      \033[1;33m!\033[0m $*"; }

# Base Ghidra : n est telechargee que si SHANNON_GHIDRA_DB_URL est donnee et
# que le fichier manque. Retourne 0 aussi quand il n y a rien a faire.
_shannon_ghidra_db_fetch() {
    local gdir="${SHANNON_GHIDRA_DIR:-/opt/GSM/shannon_ghidra_proj}"
    local dest="$gdir/shannon.rep/idata/00/~00000001.db/db.1.gbf"
    _sh_say "base Ghidra -> $dest"
    if [ -s "$dest" ]; then
        _sh_ok "base Ghidra deja presente ($(du -h "$dest" | cut -f1))"
        return 0
    fi
    # Source par defaut : db.1.gbf deposee sur Google Drive (lien public).
    # Verifiee : taille et sha256 identiques a la copie locale de reference.
    local url="${SHANNON_GHIDRA_DB_URL:-https://drive.usercontent.google.com/download?id=1LLvq4ppHuVitUiF1cJNBhX1Gz2yHGTFk&export=download&confirm=t}"
    local sha="${SHANNON_GHIDRA_DB_SHA256:-1ecbb1fcc9de4dc0e4defcada54d401760f60ffdb4ea908f56e7815da83f8750}"
    if ! command -v curl >/dev/null 2>&1; then
        _sh_warn "curl absent : impossible de telecharger la base Ghidra"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    if curl -fL --progress-bar -o "$dest.part" "$url"; then
        if [ -n "$sha" ]; then
            local got; got=$(sha256sum "$dest.part" | cut -d' ' -f1)
            if [ "$got" != "$sha" ]; then
                rm -f "$dest.part"
                _sh_warn "base Ghidra : sha256 different (attendu $sha, obtenu $got) - rejetee"
                return 1
            fi
            _sh_ok "base Ghidra : sha256 conforme"
        else
            _sh_warn "base Ghidra : sha256 non verifie (SHANNON_GHIDRA_DB_SHA256 vide)"
        fi
        mv "$dest.part" "$dest"
        _sh_ok "base Ghidra telechargee ($(du -h "$dest" | cut -f1))"
    else
        rm -f "$dest.part"
        _sh_warn "telechargement de la base Ghidra echoue : $url"
        return 1
    fi
}

osmo_shannon_download() {
    local dir="${FIRMWIRE_DIR:-/opt/GSM/FirmWire}"
    local repo="${FIRMWIRE_REPO:-https://github.com/bbaranoff/firmwire}"
    local ref="${FIRMWIRE_REF:-}"
    local fw="$dir/shannon_main.bin"
    local rc=0

    command -v git >/dev/null 2>&1 || { _sh_warn "git absent : sudo apt install git"; return 1; }

    # ── 1. FirmWire ─────────────────────────────────────────────────────────
    _sh_say "FirmWire -> $dir"
    if [ -d "$dir/.git" ]; then
        if git -C "$dir" -c safe.directory="$dir" fetch --quiet origin 2>/dev/null; then
            if [ -n "$ref" ]; then
                git -C "$dir" -c safe.directory="$dir" checkout --quiet "$ref" 2>/dev/null \
                    && _sh_ok "version $ref" || { _sh_warn "ref $ref introuvable"; rc=1; }
            else
                git -C "$dir" -c safe.directory="$dir" pull --quiet --ff-only 2>/dev/null \
                    && _sh_ok "a jour" || _sh_warn "mise a jour impossible (modifications locales ?) : on garde la copie actuelle"
            fi
        else
            _sh_warn "fetch impossible (reseau ?) : copie actuelle conservee"
        fi
    elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        _sh_warn "$dir existe, non vide, sans .git : je n y touche pas"
        rc=1
    else
        mkdir -p "$(dirname "$dir")"
        if git clone --quiet ${ref:+--no-checkout} "$repo" "$dir" 2>/dev/null; then
            if [ -n "$ref" ]; then
                git -C "$dir" -c safe.directory="$dir" checkout --quiet "$ref" 2>/dev/null \
                    || { _sh_warn "ref $ref introuvable"; rc=1; }
            else
                git -C "$dir" -c safe.directory="$dir" checkout --quiet 2>/dev/null
            fi
            _sh_ok "clone de $repo"
        else
            _sh_warn "clone impossible : $repo (reseau ?)"
            return 1
        fi
    fi

    # ── 2. Firmware Shannon ─────────────────────────────────────────────────
    _sh_say "firmware Shannon -> $fw"
    if [ ! -s "$fw" ] && [ -n "${SHANNON_FIRMWARE_URL:-}" ]; then
        if command -v curl >/dev/null 2>&1 && curl -fL --progress-bar -o "$fw.part" "$SHANNON_FIRMWARE_URL"; then
            mv "$fw.part" "$fw"
            _sh_ok "telecharge depuis SHANNON_FIRMWARE_URL"
        else
            rm -f "$fw.part"
            _sh_warn "telechargement echoue : $SHANNON_FIRMWARE_URL"
            rc=1
        fi
    fi
    if [ -s "$fw" ]; then
        if [ -n "${SHANNON_FIRMWARE_SHA256:-}" ]; then
            local got; got=$(sha256sum "$fw" | cut -d' ' -f1)
            if [ "$got" = "$SHANNON_FIRMWARE_SHA256" ]; then
                _sh_ok "shannon_main.bin present, sha256 conforme"
            else
                _sh_warn "sha256 different (attendu $SHANNON_FIRMWARE_SHA256, obtenu $got)"
                rc=1
            fi
        else
            _sh_ok "shannon_main.bin present ($(du -h "$fw" | cut -f1)) - sha256 non verifie"
        fi
    else
        _sh_warn "shannon_main.bin absent. Deposez-le dans $dir, ou donnez SHANNON_FIRMWARE_URL=..."
        rc=1
    fi

    # ── 2 bis. Base Ghidra du projet shannon_ghidra_proj ────────────────────
    _shannon_ghidra_db_fetch || rc=1

    # ── 3. Dependances Python (dites, pas installees ici) ───────────────────
    if [ "${SHANNON_SKIP_PIP:-0}" != "1" ] && [ -f "$dir/requirements.txt" ]; then
        _sh_say "dependances Python de FirmWire (a lancer si besoin) :"
        echo "      pip install -r $dir/requirements.txt"
    fi

    return $rc
}

# Lancement direct : bash download_shannon.sh
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    osmo_shannon_download
    exit $?
fi
