#!/bin/bash
# osmo-wallpaper.sh - set the bench wallpaper with its two comic strips of
# the day embedded (Calvin & Hobbes at the bottom, a random geek comic at
# the top). Called by osmo-wallpaper.service (daily timer + boot), by the
# GNOME autostart, and by hand:
#     sudo /usr/local/sbin/osmo-wallpaper
#
# 1. The strip of the day comes from gocomics.com, as the "hellogist" gist does
#    (curl of the day's page, og:image tag, curl of the image). Without network,
#    the last cached strip is reused; without cache, the wallpaper goes without strip.
# 2. tools/wallpaper-render.py composes photo + LAB GSM map + strip.
# 3. The PNG is written under TWO names: the fixed file the GNOME schema
#    designates by default (gsm-lab-wallpaper.png, what a session sees when it
#    opens), and a DATED file pushed into every open session via gsettings -
#    a different URI forces GNOME Shell to reload, which rewriting the same
#    file does not guarantee.
set -u
# Overridable from the environment (tests off the machine: OSMO_WP_OUT=... etc.).
REPO="${OSMO_WP_REPO:-/opt/GSM/osmo-operator}"
RENDER="$REPO/tools/wallpaper-render.py"
# The file format is not fixed. The tower photo is shipped AS IS (a full
# definition PNG): forcing .jpg would re-encode and degrade it to satisfy a
# name. The first configs/wallpaper/tower.* that exists is used.
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

# ── 1. THE IMAGE OF THE DAY ─────────────────────────────────────────────────
# SEVERAL SOURCES. gocomics.com has an anti-robot check (Bunny Shield) in
# front of its pages: curl often only receives "Establishing a secure
# connection", never the og:image tag. So a source is drawn among SEVERAL,
# and the first one that answers is used. All were checked with bare curl,
# without key or account:
#   calvin   gocomics.com     - kept at the head of the list: still works
#                               from the networks the shield lets through
#   xkcd     xkcd.com         - official JSON (info.0.json), the most reliable
#   apod     apod.nasa.gov    - the astronomy picture of the day, simple HTML
#   bing     bing.com         - the photo of the day, JSON HPImageArchive
#   turnoff  turnoff.us       - programmer comics (Daniel Stori)
#
# A different source at each launch: the wallpaper changes even when the strip
# of the day did not. OSMO_WP_SOURCE=xkcd forces one; OSMO_WP_SOURCES
# restricts the list.
# TWO IMAGES, TWO FRAMES. The wallpaper inset is split in two
# (tools/wallpaper-render.py): the BOTTOM is Calvin & Hobbes, the frame of the
# 2G bench; the TOP, the frame of the 4G bench, carries a GEEK comic drawn at
# random at each launch - an xkcd picked at random in the whole collection, or
# the latest turnoff.us. Each frame has its own source list and its own draw;
# without network, each reuses its last cached image.
#   OSMO_WP_SOURCES_BAS   (calvin)                    OSMO_WP_SOURCE_BAS  forces one
#   OSMO_WP_SOURCES_HAUT  (xkcd_alea turnoff xkcd)    OSMO_WP_SOURCE_HAUT forces one
# OSMO_WP_SOURCES / OSMO_WP_SOURCE (the single-image setting) apply to the TOP.
SOURCES_BAS="${OSMO_WP_SOURCES_BAS:-calvin}"
SOURCES_HAUT="${OSMO_WP_SOURCES_HAUT:-${OSMO_WP_SOURCES:-xkcd_alea turnoff xkcd}}"
[ -n "${OSMO_WP_SOURCE_BAS:-}" ] && SOURCES_BAS="$OSMO_WP_SOURCE_BAS"
[ -n "${OSMO_WP_SOURCE_HAUT:-${OSMO_WP_SOURCE:-}}" ] && SOURCES_HAUT="${OSMO_WP_SOURCE_HAUT:-$OSMO_WP_SOURCE}"

_get() { curl -sL --max-time 30 -A "$UA" "$@" 2>/dev/null; }
# An image, and not a disguised error page: `file` looks at the content.
_pose_image() {   # url fichier referer
    _get -H "Referer: ${3:-}" -o "$2.tmp" "$1" || { rm -f "$2.tmp"; return 1; }
    if [ -s "$2.tmp" ] && file -b "$2.tmp" | grep -qiE 'image|GIF|PNG|JPEG'; then
        mv -f "$2.tmp" "$2"; return 0
    fi
    rm -f "$2.tmp"; return 1
}

# Each source writes the image in $1 and its credit line in $2. A source that
# draws at random puts in NOM_RETENU a name carrying the draw ("xkcd-1234"):
# the cache file and the wallpaper URI inherit it, so the screen changes.
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
    # The direct featureassets URL first (robust to HTML), og:image next -
    # the tag the "hellogist" gist reads.
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
# A RANDOM xkcd in the whole collection: the latest number says how many there
# are, and one is drawn. 404 does not exist (it is a joke of the author).
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

# Random order: `shuf` if present, a home-made shuffle otherwise (busybox,
# pruned image). Without it the same source would always be queried first, and
# "a different source at each launch" would mean nothing.
# The source of the previous draw ($2) goes LAST: otherwise one draw in five
# lands on it and the wallpaper does not change - while that is precisely how
# one sees that a new bench has started. If it is the only one available, it
# still comes out (it is at the tail, not excluded).
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

# The draw of a frame: the first source of the list ($1) that answers,
# avoiding the one of the previous draw ($2). Result in R_STRIP / R_CREDIT /
# R_SRC; 1 if none answers.
tirer() {
    local s f c
    R_STRIP=""; R_CREDIT=""; R_SRC=""
    for s in $(_melange "$1" "$2"); do
        f="$CACHE/strip_${DAY}_${s}.img"; c="$CACHE/strip_${DAY}_${s}.credit"
        # Already downloaded today: do not ask the site again. Not for a random
        # draw (xkcd_alea): there, it is a new number every time.
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
# Fallback: the last cached image whose name matches the pattern ($1),
# excluding one file ($2, the image of the other frame). Empty if none.
_dernier_cache() {
    local f
    for f in $(ls -1t $CACHE/$1 2>/dev/null); do
        [ -s "$f" ] && [ "$f" != "$2" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

DERNIERE_BAS="$(awk -F= '/^SOURCE=/{print $2}' "$CACHE/strip.state" 2>/dev/null)"
DERNIERE_HAUT="$(awk -F= '/^SOURCE_HAUT=/{print $2}' "$CACHE/strip.state" 2>/dev/null)"

# ── THE BOTTOM: Calvin & Hobbes ─────────────────────────────────────────────
STRIP_BAS=""; CREDIT_BAS=""; SRC_BAS=""
if tirer "$SOURCES_BAS" "$DERNIERE_BAS"; then
    STRIP_BAS="$R_STRIP"; CREDIT_BAS="$R_CREDIT"; SRC_BAS="$R_SRC"
else
    # gocomics behind its shield: the last cached Calvin, whatever its date
    # (calvin_*.gif: the name used before the random draw).
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

# ── THE TOP: the geek comic, at random ──────────────────────────────────────
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
# ── WHAT THE PANEL MUST KNOW ────────────────────────────────────────────────
# Without image, the wallpaper has nothing to show at that place: the frame is
# empty. The panel (tools/osmo-fft-snap.py) composes the bench IN TRANSPARENCY
# over this frame; it is told what is behind it, and without image it switches
# to full opacity.
# STRIP/SOURCE = the bottom, STRIP_HAUT/SOURCE_HAUT = the top.
# FOND = the composed render: it is what the panel crops when it exists;
# without this line (raw wallpaper, inactive timer) the panel shows the whole
# bench illustration.
printf 'STRIP=%s\nDATE=%s\nSOURCE=%s\nSTRIP_HAUT=%s\nSOURCE_HAUT=%s\nFOND=%s\n' \
    "$([ -n "$STRIP_BAS" ] && [ -s "$STRIP_BAS" ] && echo oui || echo non)" "$DAY" "${SRC_BAS:-}" \
    "$([ -n "$STRIP_HAUT" ] && [ -s "$STRIP_HAUT" ] && echo oui || echo non)" "${SRC_HAUT:-}" \
    "$OUT" \
    > "$CACHE/strip.state"
# The cache only keeps the last 14 images (two per launch).
ls -1t "$CACHE"/strip_*.img 2>/dev/null | tail -n +15 | while read -r _old; do
    rm -f "$_old" "${_old%.img}.credit"
done
ls -1t "$CACHE"/calvin_*.gif 2>/dev/null | tail -n +15 | xargs -r rm -f

# ── 2. the render ───────────────────────────────────────────────────────────
# THE NAME CARRIES THE SOURCE, AND THAT IS WHAT MAKES THE SCREEN CHANGE.
# GNOME Shell only reloads on a URI change: rewriting the file under its old
# name repaints nothing. A name with only the day would give the SAME path
# for two renders on the same day. So the name carries the retained source:
# it changes at each launch (see the draw above, which avoids the previous
# one), so the URI changes, so the screen follows.
DATED="$DATED_DIR/gsm-lab-${DAY}${SRC_BAS:+-$SRC_BAS}${SRC_HAUT:+-$SRC_HAUT}.png"
python3 "$RENDER" --tower "$TOWER" "${args[@]}" --out "$DATED" || exit 1
cp -f "$DATED" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
chmod 644 "$OUT" "$DATED"
# The last three renders are kept. The current file is NEVER deleted: a
# session that just received its URI is still reading it.
ls -1t "$DATED_DIR"/gsm-lab-*.png 2>/dev/null | tail -n +4 | grep -vxF "$DATED" | xargs -r rm -f

# ── 3. the open sessions ────────────────────────────────────────────────────
# A GNOME session reads the schema when it opens; an already open session only
# follows dconf. The dated URI is pushed into each one (root on the live key,
# the Calamares user on disk).
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
# DING (desktop icons) sometimes keeps the previous image over the wallpaper:
# restart it (the GNOME extension restarts it at once).
[ "${_pushed:-0}" = "1" ] && pkill -f "extensions/ding@rastersoft.com/app/ding.js" 2>/dev/null
exit 0
