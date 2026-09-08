#!/bin/bash
# osmo-wallpaper.sh - pose le fond d ecran du banc avec ses deux bandes dessinees
# (Calvin & Hobbes en bas, une BD geek au hasard en haut)
# du jour incruste. Appele par osmo-wallpaper.service (timer quotidien + boot),
# par l autostart GNOME, et a la main :
#     sudo /usr/local/sbin/osmo-wallpaper
#
# 1. Le strip du jour vient de gocomics.com, comme le fait le gist "hellogist"
#    (curl de la page du jour, balise og:image, curl de l image). Sans reseau,
#    on reprend le dernier strip en cache ; sans cache, le fond part sans strip.
# 2. tools/wallpaper-render.py compose photo + carte LAB GSM + strip.
# 3. Le PNG est ecrit sous DEUX noms : le fichier fixe que le schema GNOME
#    designe par defaut (gsm-lab-wallpaper.png, ce que voit une session qui
#    s ouvre), et un fichier DATE que l on pousse dans chaque session ouverte
#    via gsettings - une URI differente force GNOME Shell a recharger, ce
#    qu une reecriture du meme fichier ne garantit pas.
set -u
# Surchargeables par l environnement (tests hors machine : OSMO_WP_OUT=... etc.).
REPO="${OSMO_WP_REPO:-/opt/GSM/osmo-operator}"
RENDER="$REPO/tools/wallpaper-render.py"
# [2026-09-04] Le format du fichier n est plus fige. La photo du pylone est
# livree TELLE QUELLE (aujourd hui un PNG en pleine definition) : imposer
# .jpg obligerait a la re-encoder, donc a la degrader, pour satisfaire un nom.
# On prend le premier configs/wallpaper/tower.* qui existe.
TOWER="$(ls "$REPO"/configs/wallpaper/tower.* 2>/dev/null | head -1)"
OUT="${OSMO_WP_OUT:-/usr/share/backgrounds/gsm-lab-wallpaper.png}"
DATED_DIR="${OSMO_WP_DATED_DIR:-/usr/share/backgrounds/osmo-lab}"
CACHE="${OSMO_WP_CACHE:-/var/cache/osmo-wallpaper}"
NO_SESSION="${OSMO_WP_NO_SESSION:-0}"
DAY="$(date +%F)"
STRIP="$CACHE/calvin_${DAY}.gif"
UA="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
H=(-H "Accept: text/html,*/*;q=0.8" -H "Accept-Language: fr,en;q=0.7" -H "Referer: https://www.gocomics.com/")

[ "$(id -u)" -eq 0 ] || { echo "root requis : sudo $0" >&2; exit 1; }
[ -f "$RENDER" ] && [ -f "$TOWER" ] || { echo "[wallpaper] $RENDER ou $TOWER absent" >&2; exit 1; }
mkdir -p "$CACHE" "$DATED_DIR"

# ── 1. L IMAGE DU JOUR ───────────────────────────────────────────────────────
# [2026-09-04] UNE SEULE SOURCE, ET PLUS D IMAGE DU TOUT. gocomics.com a mis un
# controle anti-robot (Bunny Shield) devant ses pages : curl ne recoit plus que
# 2 ko de « Establishing a secure connection », jamais la balise og:image. La
# methode du gist (curl + grep og:image) ne marche donc plus - ni ici, ni a la
# main. Le fond partait sans rien, tous les jours.
#
# On tire donc au sort parmi PLUSIEURS sources, et on prend la premiere qui
# repond. Toutes ont ete verifiees au curl nu, sans cle ni compte :
#   calvin   gocomics.com     - garde en tete de liste : elle marche encore
#                               depuis les reseaux que le bouclier laisse passer
#   xkcd     xkcd.com         - JSON officiel (info.0.json), le plus fiable
#   apod     apod.nasa.gov    - l astronomie du jour, HTML simple
#   bing     bing.com         - la photo du jour, JSON HPImageArchive
#   turnoff  turnoff.us       - bandes dessinees d informaticien (Daniel Stori)
#
# Une source differente a chaque lancement : le fond change meme quand le strip
# du jour n a pas bouge. OSMO_WP_SOURCE=xkcd en force une ; OSMO_WP_SOURCES
# restreint la liste.
# [2026-09-08] DEUX IMAGES, DEUX CADRES. L encart du fond s est coupe en deux
# (tools/wallpaper-render.py) : le BAS reste a Calvin & Hobbes, c est le cadre
# du banc 2G ; le HAUT, celui du banc 4G, porte une bande dessinee GEEK tiree
# au sort a chaque lancement - un xkcd pris au hasard dans toute la
# collection, ou le dernier turnoff.us. Chaque cadre a sa liste de sources et
# son tirage ; a defaut de reseau, chacun reprend sa derniere image en cache.
#   OSMO_WP_SOURCES_BAS   (calvin)                    OSMO_WP_SOURCE_BAS  en force une
#   OSMO_WP_SOURCES_HAUT  (xkcd_alea turnoff xkcd)    OSMO_WP_SOURCE_HAUT en force une
# OSMO_WP_SOURCES / OSMO_WP_SOURCE (l ancien reglage, une seule image) valent
# desormais pour le HAUT.
SOURCES_BAS="${OSMO_WP_SOURCES_BAS:-calvin}"
SOURCES_HAUT="${OSMO_WP_SOURCES_HAUT:-${OSMO_WP_SOURCES:-xkcd_alea turnoff xkcd}}"
[ -n "${OSMO_WP_SOURCE_BAS:-}" ] && SOURCES_BAS="$OSMO_WP_SOURCE_BAS"
[ -n "${OSMO_WP_SOURCE_HAUT:-${OSMO_WP_SOURCE:-}}" ] && SOURCES_HAUT="${OSMO_WP_SOURCE_HAUT:-$OSMO_WP_SOURCE}"

_get() { curl -sL --max-time 30 -A "$UA" "$@" 2>/dev/null; }
# Une image, et pas une page d erreur deguisee : `file` regarde le contenu.
_pose_image() {   # url fichier referer
    _get -H "Referer: ${3:-}" -o "$2.tmp" "$1" || { rm -f "$2.tmp"; return 1; }
    if [ -s "$2.tmp" ] && file -b "$2.tmp" | grep -qiE 'image|GIF|PNG|JPEG'; then
        mv -f "$2.tmp" "$2"; return 0
    fi
    rm -f "$2.tmp"; return 1
}

# Chaque source ecrit l image dans $1 et sa ligne de credit dans $2. Une source
# qui tire au sort pose dans NOM_RETENU un nom qui porte le tirage (« xkcd-1234 »)
# : le fichier de cache et l URI du fond en heritent, donc l ecran change.
NOM_RETENU=""
src_calvin() {
    local page url
    page="$(_get "${H[@]}" "https://www.gocomics.com/calvinandhobbes/$(date +%Y/%m/%d)")"
    if [ -z "$page" ]; then
        echo "[wallpaper] calvin : gocomics.com injoignable (reseau, DNS, proxy ?)"; return 1
    fi
    if printf '%s' "$page" | grep -qiE 'bunny-shield|Establishing a secure connection|challenge-platform|cf-browser-verification'; then
        echo "[wallpaper] calvin : gocomics.com rend une page anti-robot ($(printf '%s' "$page" | wc -c) octets)"
        return 1
    fi
    # L URL directe de featureassets d abord (robuste au HTML), og:image ensuite
    # - c est la balise que lit le gist « hellogist ».
    url="$(printf '%s' "$page" | grep -oE 'https://featureassets\.gocomics\.com/assets/[0-9a-f]+' | head -1)"
    [ -n "$url" ] || url="$(printf '%s' "$page" | grep -oP '<meta property="og:image" content="\K[^"]+' | head -1)"
    [ -n "$url" ] || { echo "[wallpaper] calvin : page recue, aucune image dedans (le site a change ?)"; return 1; }
    _pose_image "$url" "$1" "https://www.gocomics.com/" || return 1
    printf 'Calvin & Hobbes  ·  Bill Watterson  ·  %s  ·  gocomics.com\n' "$DAY" > "$2"
}
_xkcd_json() {   # json -> image + credit ($1 json, $2 fichier, $3 credit)
    local url num titre
    url="$(printf '%s' "$1" | grep -oP '"img":\s*"\K[^"]+')"
    [ -n "$url" ] || return 1
    num="$(printf '%s' "$1" | grep -oP '"num":\s*\K[0-9]+')"
    titre="$(printf '%s' "$1" | grep -oP '"safe_title":\s*"\K[^"]+')"
    _pose_image "$url" "$2" "https://xkcd.com/" || return 1
    printf 'xkcd #%s  ·  %s  ·  Randall Munroe  ·  xkcd.com\n' "$num" "$titre" > "$3"
    NOM_RETENU="xkcd-$num"
}
src_xkcd() { _xkcd_json "$(_get https://xkcd.com/info.0.json)" "$1" "$2"; }
# Un xkcd AU HASARD dans toute la collection : le dernier numero dit combien il
# y en a, et on en tire un. Le 404 n existe pas (c est une blague de l auteur).
src_xkcd_alea() {
    local dernier num
    dernier="$(_get https://xkcd.com/info.0.json | grep -oP '"num":\s*\K[0-9]+')"
    [ -n "$dernier" ] && [ "$dernier" -gt 1 ] || return 1
    num=$(( (RANDOM * 32768 + RANDOM) % dernier + 1 ))
    [ "$num" -eq 404 ] && num=405
    _xkcd_json "$(_get "https://xkcd.com/$num/info.0.json")" "$1" "$2"
}
src_apod() {
    local page src
    page="$(_get https://apod.nasa.gov/apod/astropix.html)"
    src="$(printf '%s' "$page" | grep -oiP '<img[^>]+src="\K[^"]+' | head -1)"
    [ -n "$src" ] || return 1
    case "$src" in http*) ;; *) src="https://apod.nasa.gov/apod/${src#/}" ;; esac
    _pose_image "$src" "$1" "https://apod.nasa.gov/apod/" || return 1
    printf 'NASA · Astronomy Picture of the Day  ·  %s  ·  apod.nasa.gov\n' "$DAY" > "$2"
}
src_bing() {
    local j url cr
    j="$(_get "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=fr-FR")"
    url="$(printf '%s' "$j" | grep -oP '"url":"\K[^"]+')"
    [ -n "$url" ] || return 1
    case "$url" in http*) ;; *) url="https://www.bing.com${url}" ;; esac
    cr="$(printf '%s' "$j" | grep -oP '"copyright":"\K[^"]+')"
    _pose_image "$url" "$1" "https://www.bing.com/" || return 1
    printf 'Bing · image du jour  ·  %s\n' "${cr:-bing.com}" > "$2"
}
src_turnoff() {
    local url
    url="$(_get https://turnoff.us/feed.xml | grep -oP '<img[^>]+src=.\K[^"'"'"' ]+' | head -1)"
    [ -n "$url" ] || return 1
    _pose_image "$url" "$1" "https://turnoff.us/" || return 1
    printf 'turnoff.us  ·  Daniel Stori  ·  turnoff.us\n' > "$2"
}

# Ordre aleatoire : `shuf` s il est la, un melange maison sinon (busybox, image
# elaguee). Sans cela on interrogerait toujours la meme source en premier, et
# « une source differente a chaque lancement » n aurait aucun sens.
# La source du coup precedent ($2) passe en DERNIER : sans cela, un tirage sur
# cinq retombait sur elle et le fond ne changeait pas - alors que c est
# justement a ca qu on voit qu un nouveau banc a demarre. Si elle est la seule
# disponible, elle ressort quand meme (elle est en queue, pas exclue).
_melange() {   # "sources" derniere -> l ordre, sur une ligne
    local cand="" s ordre=""
    for s in $1; do [ "$s" = "$2" ] || cand="$cand $s"; done
    [ -n "$cand" ] || cand="$1"
    if command -v shuf >/dev/null 2>&1; then
        ordre="$(printf '%s\n' $cand | shuf | tr '\n' ' ')"
    else
        for s in $cand; do
            if [ $((RANDOM % 2)) -eq 0 ]; then ordre="$s $ordre"; else ordre="$ordre $s"; fi
        done
    fi
    [ -n "$2" ] && ordre="$ordre $2"
    printf '%s' "$ordre"
}

# Le tirage d un cadre : la premiere source de la liste ($1) qui repond, en
# evitant celle du coup precedent ($2). Resultat dans R_STRIP / R_CREDIT /
# R_SRC ; 1 si aucune ne repond.
tirer() {
    local s f c
    R_STRIP=""; R_CREDIT=""; R_SRC=""
    for s in $(_melange "$1" "$2"); do
        f="$CACHE/strip_${DAY}_${s}.img"; c="$CACHE/strip_${DAY}_${s}.credit"
        # Deja telecharge aujourd hui : on ne redemande pas au site. Pas pour
        # un tirage au sort (xkcd_alea) : la, c est un nouveau numero a chaque fois.
        case "$s" in
            *_alea) ;;
            *) if [ -s "$f" ]; then
                   R_STRIP="$f"; R_CREDIT="$(cat "$c" 2>/dev/null || true)"; R_SRC="$s"
                   echo "[wallpaper] image du $DAY : source ${s} (deja en cache)"; return 0
               fi ;;
        esac
        NOM_RETENU=""
        if declare -F "src_$s" >/dev/null && "src_$s" "$f" "$c"; then
            if [ -n "$NOM_RETENU" ] && [ "$NOM_RETENU" != "$s" ]; then
                mv -f "$f" "$CACHE/strip_${DAY}_${NOM_RETENU}.img"
                mv -f "$c" "$CACHE/strip_${DAY}_${NOM_RETENU}.credit" 2>/dev/null
                f="$CACHE/strip_${DAY}_${NOM_RETENU}.img"; c="$CACHE/strip_${DAY}_${NOM_RETENU}.credit"
                s="$NOM_RETENU"
            fi
            R_STRIP="$f"; R_CREDIT="$(cat "$c" 2>/dev/null || true)"; R_SRC="$s"
            echo "[wallpaper] image du $DAY : source ${s}"; return 0
        fi
    done
    return 1
}
# Repli : la derniere image en cache dont le nom repond au motif ($1), en
# ecartant un fichier ($2, l image de l autre cadre). Vide s il n y en a pas.
_dernier_cache() {
    local f
    for f in $(ls -1t $CACHE/$1 2>/dev/null); do
        [ -s "$f" ] && [ "$f" != "$2" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

DERNIERE_BAS="$(awk -F= '/^SOURCE=/{print $2}' "$CACHE/strip.state" 2>/dev/null)"
DERNIERE_HAUT="$(awk -F= '/^SOURCE_HAUT=/{print $2}' "$CACHE/strip.state" 2>/dev/null)"

# ── LE BAS : Calvin & Hobbes ────────────────────────────────────────────────
STRIP_BAS=""; CREDIT_BAS=""; SRC_BAS=""
if tirer "$SOURCES_BAS" "$DERNIERE_BAS"; then
    STRIP_BAS="$R_STRIP"; CREDIT_BAS="$R_CREDIT"; SRC_BAS="$R_SRC"
else
    # gocomics derriere son bouclier : le dernier Calvin en cache, quelle que
    # soit sa date (calvin_*.gif : le nom d avant le tirage au sort).
    STRIP_BAS="$(_dernier_cache 'strip_*_calvin.img' '' || _dernier_cache 'calvin_*.gif' '' || true)"
    if [ -n "$STRIP_BAS" ]; then
        CREDIT_BAS="$(cat "${STRIP_BAS%.img}.credit" 2>/dev/null || true)"; SRC_BAS="calvin"
        echo "[wallpaper] bas : calvin ne repond pas - dernier Calvin en cache : ${STRIP_BAS##*/}"
    elif tirer "apod bing" ""; then
        STRIP_BAS="$R_STRIP"; CREDIT_BAS="$R_CREDIT"; SRC_BAS="$R_SRC"
        echo "[wallpaper] bas : aucun Calvin, ni en ligne ni en cache - image du jour a la place"
    else
        STRIP_BAS="$(_dernier_cache 'strip_*.img' '' || true)"
        [ -n "$STRIP_BAS" ] && CREDIT_BAS="$(cat "${STRIP_BAS%.img}.credit" 2>/dev/null || true)"
    fi
fi

# ── LE HAUT : la BD geek, au hasard ─────────────────────────────────────────
STRIP_HAUT=""; CREDIT_HAUT=""; SRC_HAUT=""
if tirer "$SOURCES_HAUT" "$DERNIERE_HAUT"; then
    STRIP_HAUT="$R_STRIP"; CREDIT_HAUT="$R_CREDIT"; SRC_HAUT="$R_SRC"
else
    STRIP_HAUT="$(_dernier_cache 'strip_*_xkcd*.img' "$STRIP_BAS" || _dernier_cache 'strip_*_turnoff.img' "$STRIP_BAS" \
                  || _dernier_cache 'strip_*.img' "$STRIP_BAS" || true)"
    if [ -n "$STRIP_HAUT" ]; then
        CREDIT_HAUT="$(cat "${STRIP_HAUT%.img}.credit" 2>/dev/null || true)"
        SRC_HAUT="$(basename "$STRIP_HAUT" .img | sed 's/^strip_[0-9-]*_//')"
        echo "[wallpaper] haut : aucune source ne repond - derniere BD en cache : ${STRIP_HAUT##*/}"
    else
        echo "[wallpaper] haut : aucune source ne repond et le cache est vide - cadre sans image."
        echo "[wallpaper] Deposez n importe quelle image dans $CACHE/strip_${DAY}_local.img et relancez."
    fi
fi
STRIP="$STRIP_BAS"; SRC_RETENUE="$SRC_BAS"

args=()
if [ -n "$STRIP_BAS" ] && [ -s "$STRIP_BAS" ]; then
    args+=(--strip "$STRIP_BAS")
    [ -n "$CREDIT_BAS" ] && args+=(--credit "$CREDIT_BAS")
fi
if [ -n "$STRIP_HAUT" ] && [ -s "$STRIP_HAUT" ]; then
    args+=(--strip-haut "$STRIP_HAUT")
    [ -n "$CREDIT_HAUT" ] && args+=(--credit-haut "$CREDIT_HAUT")
fi
args+=(--date "$DAY")
# ── CE QUE L ENCART DOIT SAVOIR ─────────────────────────────────────────────
# [2026-09-04] Sans image, le fond n a rien a montrer a cet endroit : le cadre
# est vide. L encart (tools/osmo-fft-snap.py) compose le banc EN TRANSPARENCE
# par-dessus ce cadre - il laissait donc transparaitre du vide, et le spectre
# comme le mobile.log y perdaient en lisibilite pour rien. On lui dit ce qu il
# y a derriere lui ; sans image, il passe en opacite pleine.
# STRIP/SOURCE = le bas (le nom historique), STRIP_HAUT/SOURCE_HAUT = le haut.
printf 'STRIP=%s\nDATE=%s\nSOURCE=%s\nSTRIP_HAUT=%s\nSOURCE_HAUT=%s\n' \
    "$([ -n "$STRIP_BAS" ] && [ -s "$STRIP_BAS" ] && echo oui || echo non)" "$DAY" "${SRC_BAS:-}" \
    "$([ -n "$STRIP_HAUT" ] && [ -s "$STRIP_HAUT" ] && echo oui || echo non)" "${SRC_HAUT:-}" \
    > "$CACHE/strip.state"
# Le cache ne garde que les 14 dernieres images (deux par lancement).
ls -1t "$CACHE"/strip_*.img 2>/dev/null | tail -n +15 | while read -r _old; do
    rm -f "$_old" "${_old%.img}.credit"
done
ls -1t "$CACHE"/calvin_*.gif 2>/dev/null | tail -n +15 | xargs -r rm -f

# ── 2. le rendu ──────────────────────────────────────────────────────────────
# LE NOM PORTE LA SOURCE, ET C EST CE QUI FAIT CHANGER L ECRAN.
# [2026-09-04] Le fichier date s appelait gsm-lab-<jour>.png. Deux rendus le
# meme jour ecrivaient donc le MEME chemin - et l URI poussee aux sessions
# (etape 3) ne changeait pas d un poil. Or GNOME Shell ne recharge que sur
# changement d URI : reecrire le fichier sous son ancien nom ne repeint rien.
# Le banc pouvait tirer une nouvelle source a chaque relance, l ecran gardait
# l image du premier demarrage jusqu au lendemain.
# Le nom porte donc la source retenue : elle change a chaque relance (voir le
# tirage plus haut, qui evite celle du coup precedent), donc l URI change, donc
# l ecran suit.
DATED="$DATED_DIR/gsm-lab-${DAY}${SRC_BAS:+-$SRC_BAS}${SRC_HAUT:+-$SRC_HAUT}.png"
python3 "$RENDER" --tower "$TOWER" "${args[@]}" --out "$DATED" || exit 1
cp -f "$DATED" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
chmod 644 "$OUT" "$DATED"
# On garde les trois derniers rendus. Le fichier en cours n est JAMAIS efface :
# une session qui vient de recevoir son URI le lit encore.
ls -1t "$DATED_DIR"/gsm-lab-*.png 2>/dev/null | tail -n +4 | grep -vxF "$DATED" | xargs -r rm -f

# ── 3. les sessions ouvertes ─────────────────────────────────────────────────
# Une session GNOME lit le schema a l ouverture ; une session deja ouverte ne
# suit que dconf. On pousse l URI datee dans chacune (root sur la cle live,
# l utilisateur Calamares sur le disque).
[ "$NO_SESSION" = "1" ] && exit 0
for bus in /run/user/*/bus; do
    [ -S "$bus" ] || continue
    uid="${bus#/run/user/}"; uid="${uid%/bus}"
    user="$(id -nu "$uid" 2>/dev/null)" || continue
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="/run/user/$uid" \
        sh -c "gsettings set org.gnome.desktop.background picture-uri 'file://$DATED' ; \
               gsettings set org.gnome.desktop.background picture-uri-dark 'file://$DATED'" \
        2>/dev/null && echo "[wallpaper] session de $user : $DATED" && _pushed=1
done
# DING (icones du bureau) garde parfois l image precedente par-dessus le fond :
# relance (l extension GNOME le redemarre aussitot).
[ "${_pushed:-0}" = "1" ] && pkill -f "extensions/ding@rastersoft.com/app/ding.js" 2>/dev/null
exit 0
