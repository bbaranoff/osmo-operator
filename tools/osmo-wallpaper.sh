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

# ── 1. le strip du jour ──────────────────────────────────────────────────────
if [ ! -s "$STRIP" ]; then
    page="$(curl -sL --max-time 30 -A "$UA" "${H[@]}" \
            "https://www.gocomics.com/calvinandhobbes/$(date +%Y/%m/%d)" 2>/dev/null || true)"
    # Deux formes : l URL directe de featureassets (robuste au HTML de la page)
    # puis la balise og:image telle que le gist la lit.
    url="$(printf '%s' "$page" | grep -oE 'https://featureassets\.gocomics\.com/assets/[0-9a-f]+' | head -1)"
    [ -n "$url" ] || url="$(printf '%s' "$page" | grep -oP '<meta property="og:image" content="\K[^"]+' | head -1)"
    if [ -n "$url" ] && curl -sL --max-time 30 -A "$UA" "${H[@]}" -o "$STRIP.tmp" "$url" \
       && [ -s "$STRIP.tmp" ] && file -b "$STRIP.tmp" | grep -qiE 'image|GIF|PNG|JPEG'; then
        mv -f "$STRIP.tmp" "$STRIP"
        echo "[wallpaper] strip du $DAY : $url"
    else
        rm -f "$STRIP.tmp"
        echo "[wallpaper] strip du $DAY indisponible (reseau ?)"
    fi
fi
# Repli : le dernier strip en cache, quelle que soit sa date.
if [ ! -s "$STRIP" ]; then
    STRIP="$(ls -1t "$CACHE"/calvin_*.gif 2>/dev/null | head -1 || true)"
fi
args=()
if [ -n "$STRIP" ] && [ -s "$STRIP" ]; then
    d="${STRIP##*/calvin_}"; d="${d%.gif}"
    args=(--strip "$STRIP" --date "$d")
fi
# Le cache ne garde que les 14 derniers strips.
ls -1t "$CACHE"/calvin_*.gif 2>/dev/null | tail -n +15 | xargs -r rm -f

# ── 2. le rendu ──────────────────────────────────────────────────────────────
DATED="$DATED_DIR/gsm-lab-${DAY}.png"
python3 "$RENDER" --tower "$TOWER" "${args[@]}" --out "$DATED" || exit 1
cp -f "$DATED" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
chmod 644 "$OUT" "$DATED"
ls -1t "$DATED_DIR"/gsm-lab-*.png 2>/dev/null | tail -n +4 | xargs -r rm -f

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
