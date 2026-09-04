#!/bin/bash
# osmo-wallpaper.sh - pose le fond d ecran du banc avec le strip Calvin & Hobbes
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
TOWER="$REPO/configs/wallpaper/tower.jpg"
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
SOURCES="${OSMO_WP_SOURCES:-calvin xkcd apod bing turnoff}"
[ -n "${OSMO_WP_SOURCE:-}" ] && SOURCES="$OSMO_WP_SOURCE"

_get() { curl -sL --max-time 30 -A "$UA" "$@" 2>/dev/null; }
# Une image, et pas une page d erreur deguisee : `file` regarde le contenu.
_pose_image() {   # url fichier referer
    _get -H "Referer: ${3:-}" -o "$2.tmp" "$1" || { rm -f "$2.tmp"; return 1; }
    if [ -s "$2.tmp" ] && file -b "$2.tmp" | grep -qiE 'image|GIF|PNG|JPEG'; then
        mv -f "$2.tmp" "$2"; return 0
    fi
    rm -f "$2.tmp"; return 1
}

# Chaque source ecrit l image dans $1 et sa ligne de credit dans $2.
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
src_xkcd() {
    local j url num titre
    j="$(_get https://xkcd.com/info.0.json)"
    url="$(printf '%s' "$j" | grep -oP '"img":\s*"\K[^"]+')"
    [ -n "$url" ] || return 1
    num="$(printf '%s' "$j" | grep -oP '"num":\s*\K[0-9]+')"
    titre="$(printf '%s' "$j" | grep -oP '"safe_title":\s*"\K[^"]+')"
    _pose_image "$url" "$1" "https://xkcd.com/" || return 1
    printf 'xkcd #%s  ·  %s  ·  Randall Munroe  ·  xkcd.com\n' "$num" "$titre" > "$2"
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
# La source du coup precedent passe en DERNIER : sans cela, un tirage sur cinq
# retombait sur elle et le fond ne changeait pas - alors que c est justement a
# ca qu on voit qu un nouveau banc a demarre. Si elle est la seule disponible,
# elle ressort quand meme (elle est en queue, pas exclue).
DERNIERE="$(awk -F= '/^SOURCE=/{print $2}' "$CACHE/strip.state" 2>/dev/null)"
_CANDIDATES=""
for _s in $SOURCES; do [ "$_s" = "$DERNIERE" ] || _CANDIDATES="$_CANDIDATES $_s"; done
[ -n "$_CANDIDATES" ] || _CANDIDATES="$SOURCES"

if command -v shuf >/dev/null 2>&1; then
    ORDRE="$(printf '%s\n' $_CANDIDATES | shuf | tr '\n' ' ')"
    [ -n "$DERNIERE" ] && ORDRE="$ORDRE $DERNIERE"
else
    ORDRE=""
    for _s in $_CANDIDATES; do
        if [ $((RANDOM % 2)) -eq 0 ]; then ORDRE="$_s $ORDRE"; else ORDRE="$ORDRE $_s"; fi
    done
    [ -n "$DERNIERE" ] && ORDRE="$ORDRE $DERNIERE"
fi

STRIP=""; CREDIT=""; SRC_RETENUE=""
for _s in $ORDRE; do
    _f="$CACHE/strip_${DAY}_${_s}.img"; _c="$CACHE/strip_${DAY}_${_s}.credit"
    # Deja telechargee aujourd hui : on ne redemande pas au site.
    if [ -s "$_f" ]; then
        STRIP="$_f"; CREDIT="$(cat "$_c" 2>/dev/null || true)"; SRC_RETENUE="$_s"
        echo "[wallpaper] image du $DAY : source ${_s} (deja en cache)"
        break
    fi
    if declare -F "src_$_s" >/dev/null && "src_$_s" "$_f" "$_c"; then
        STRIP="$_f"; CREDIT="$(cat "$_c" 2>/dev/null || true)"; SRC_RETENUE="$_s"
        echo "[wallpaper] image du $DAY : source ${_s}"
        break
    fi
done

# Repli : la derniere image en cache, quelle que soit sa date ou sa source.
# (calvin_*.gif : le nom d avant le tirage au sort, garde pour les caches deja
# poses sur les machines en service.)
if [ -z "$STRIP" ]; then
    STRIP="$(ls -1t "$CACHE"/strip_*.img "$CACHE"/calvin_*.gif 2>/dev/null | head -1 || true)"
    if [ -n "$STRIP" ]; then
        CREDIT="$(cat "${STRIP%.img}.credit" 2>/dev/null || true)"
        echo "[wallpaper] aucune source ne repond - derniere image en cache : ${STRIP##*/}"
    else
        echo "[wallpaper] aucune source ne repond et le cache est vide - fond sans image."
        echo "[wallpaper] Deposez n importe quelle image dans $CACHE/strip_${DAY}_local.img et relancez."
    fi
fi

args=()
if [ -n "$STRIP" ] && [ -s "$STRIP" ]; then
    args=(--strip "$STRIP" --date "$DAY")
    [ -n "$CREDIT" ] && args+=(--credit "$CREDIT")
fi
# ── CE QUE L ENCART DOIT SAVOIR ─────────────────────────────────────────────
# [2026-09-04] Sans image, le fond n a rien a montrer a cet endroit : le cadre
# est vide. L encart (tools/osmo-fft-snap.py) compose le banc EN TRANSPARENCE
# par-dessus ce cadre - il laissait donc transparaitre du vide, et le spectre
# comme le mobile.log y perdaient en lisibilite pour rien. On lui dit ce qu il
# y a derriere lui ; sans image, il passe en opacite pleine.
printf 'STRIP=%s\nDATE=%s\nSOURCE=%s\n' \
    "$([ -n "$STRIP" ] && [ -s "$STRIP" ] && echo oui || echo non)" "$DAY" "${SRC_RETENUE:-}" \
    > "$CACHE/strip.state"
# Le cache ne garde que les 14 dernieres images.
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
DATED="$DATED_DIR/gsm-lab-${DAY}${SRC_RETENUE:+-$SRC_RETENUE}.png"
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
