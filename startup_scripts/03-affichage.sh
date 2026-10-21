# 03-affichage.sh - partie de start.sh (lignes 629-683 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
say_begin() {
    if [ $TTY -eq 1 ]; then
        printf '[ %s.. %s] %s' "$C_DIM" "$C_Z" "$1"
    else
        printf '[ .. ] %s\n' "$1"
    fi
}
say_end() { # $1=tag $2=couleur $3=libelle $4=detail
    if [ $TTY -eq 1 ]; then printf '\r\033[K'; fi
    printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
    [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"
    printf '\n'
}
banner() {
    echo -e "${C_CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Calypso GSM - bootstrap → run.sh                   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${C_Z}"
}
# --- 1. configuration ---------------------------------------------------------
# [2026-08-03] globals.conf - les reglages reseau (MCC/MNC/ARFCN/KI/IMSI/A5...).
# Genere par ./generate_configs.sh cote hote ; ici on se contente de le lire.
# [2026-09-22] « ARFCN=520 ./start-native.sh surcharge sans toucher au
# fichier » : c'etait ecrit ici, et c'etait FAUX. globals.conf n'utilise pas
# l'idiome ":=" mais l'affectation simple (`ENCRYPTION="a5 1"`), et il est
# source avec `set -a` : il ECRASE l'environnement. Son propre en-tete
# l'annonce d'ailleurs (« il est lu en dernier, les 26 reglages ci-dessous
# ecrasent leur homonyme dans l'environnement »), en contradiction avec ce
# commentaire-ci. Constate sur le banc :
#     ENCRYPTION="a5 0" ./start-native.sh --dsp   ->   chiffrement a5 1
# Deux contrats opposes dans le meme depot, et c'est le silencieux qui gagnait.
#
# On tranche du cote de la ligne de commande, qui est la regle partout ailleurs
# dans ce script : on releve les variables de globals.conf que l'appelant a
# DEJA posees et non vides, on lit le fichier, puis on les repose. globals.conf
# reste la reference pour tout ce qui n'a pas ete dit ; un vide continue de
# signifier « valeur calculee », donc ne surcharge rien.
if [ -r "$HERE/globals.conf" ]; then
    _gc_forcees=()
    while IFS= read -r _gc_v; do
        [ -n "${!_gc_v:-}" ] && _gc_forcees+=("$_gc_v=${!_gc_v}")
    done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$HERE/globals.conf")
    set -a
    . "$HERE/globals.conf"
    for _gc_kv in "${_gc_forcees[@]}"; do
        eval "${_gc_kv%%=*}=\${_gc_kv#*=}"
    done
    set +a
    [ ${#_gc_forcees[@]} -gt 0 ] && \
        printf '  %sglobals.conf%s surcharge par l environnement : %s\n' \
            "${C_DIM:-}" "${C_Z:-}" "${_gc_forcees[*]}"
    unset _gc_v _gc_kv
fi

