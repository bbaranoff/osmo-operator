#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# update.sh - l'animation SMS de l'ouverture de session. Rien d'autre.
#
# [2026-08-27] Ce fichier ne faisait pas ce que son nom dit : il posait un
# osmo-sync.sh qui, a CHAQUE demarrage, effacait puis reclonait osmo-operator et
# osmo-egprs-web depuis GitHub, resynchronisait qosmo-grgsm, installait socat a
# coups d'apt, et rearmait un declencheur sur la console. Trois consequences :
#
#   - ce qui tournait sur la machine n'etait plus ce que l'ISO portait, mais ce
#     que GitHub avait ce matin-la ;
#   - sans reseau au demarrage, les arbres effaces ne revenaient pas ;
#   - un paquet reinstalle a chaque boot, c'est un boot qui depend du reseau.
#
# Tout cela appartient a la CONSTRUCTION, pas au demarrage : c'est build-iso.sh
# qui embarque desormais les trois depots AVEC leur .git (et qosmo-grgsm avec son
# build/ compile), installe socat/nc/tcpdump/git dans le rootfs, et pose le
# service du dashboard. Une machine qui demarre n'a plus rien a aller chercher.
#
# Ce qu'il reste ici est ce qui ne peut pas etre fait a la construction, ou
# qui doit rattraper les machines DEJA installees :
#
#   - l'animation, qui a besoin d'un terminal et de quelqu'un devant ;
#   - la repose des ICONES DU BUREAU (voir le bloc dedie plus bas) : les
#     raccourcis dessines tombaient en page blanche generique, et le
#     correctif de build-iso.sh ne touche que les ISO a venir. Idempotent.
#
# Usage :
#   sudo ./update.sh            repose les icones, puis joue l'animation
#   sudo ./update.sh --quiet    repose les icones, sans l'animation (code 0)
#
# Sur l'ISO, /etc/profile.d/99-osmo-sms.sh l'appelle une fois par demarrage,
# apres le choix du clavier (ordre alphabetique de /etc/profile.d).
# ══════════════════════════════════════════════════════════════════════════════
set -u

# Meme raison que dans build.sh : ce script est appele depuis
# /etc/profile.d et depuis les lanceurs du bureau, ou le repertoire courant
# n'est pas le sien. On se place chez soi avant de toucher a quoi que ce soit.
cd "$(dirname "$(readlink -f "$0")")" || true

case "${1:-}" in
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ── LES ICONES DU BUREAU, REPOSEES A CHAQUE DEMARRAGE ───────────────────────
# [2026-08-31] Les trois raccourcis dessines - "Lancer le banc GSM",
# "multi-operator", "Tutoriel" - s affichaient en PAGE BLANCHE generique sur le
# bureau. Les SVG etaient pourtant valides et bien poses dans
# /usr/share/icons/hicolor/scalable/apps/.
#
# La cause n est pas le fichier, c est la RESOLUTION DU NOM. "Icon=osmo-launch"
# n est pas un chemin : c est un nom que GTK va chercher dans le thème, via
# /usr/share/icons/hicolor/icon-theme.cache. Ce cache datait d AVANT l arrivee
# des icones - releve sur le banc :
#     strings /usr/share/icons/hicolor/icon-theme.cache | grep -c osmo  ->  0
#     cache 17:22:12   ·   icones 17:28:07
# Zero entree sur trois. Et un nom d icone qui ne resout pas ne provoque aucune
# erreur : GNOME/DING le remplace EN SILENCE par la page blanche. "Supplements"
# gardait la sienne parce que "system-software-install" vient de Yaru, deja
# dans le cache depuis l installation du systeme.
#
# build-iso.sh pose desormais le correctif dans l image. Le meme correctif est
# REJOUE ICI parce qu une machine deja installee ne repasse pas par la
# construction : sans ce bloc, elle garderait ses pages blanches jusqu a la
# prochaine ISO. Tout y est idempotent - on peut le rejouer a chaque session.
osmo_reposer_icones() {
    [ "$(id -u)" -eq 0 ] || return 0        # sans droits : on ne casse rien
    local src=/opt/GSM/osmo-operator/data
    local dst=/usr/share/osmo-operator/icons
    [ -d "$src" ] || return 0

    install -d "$dst" 2>/dev/null || return 0
    local ic
    for ic in osmo-launch osmo-multi osmo-tutorial; do
        [ -f "$src/$ic.svg" ] || continue
        cp -f "$src/$ic.svg" "$dst/$ic.svg" 2>/dev/null || continue
        chmod 644 "$dst/$ic.svg" 2>/dev/null || true
        # La copie du thème sert au MENU des applications, qui lui resout
        # encore par nom ; le bureau, lui, passe par le chemin absolu.
        install -d /usr/share/icons/hicolor/scalable/apps 2>/dev/null || true
        cp -f "$src/$ic.svg" \
              "/usr/share/icons/hicolor/scalable/apps/$ic.svg" 2>/dev/null || true
    done
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true

    # Icon= EN CHEMIN ABSOLU : plus de thème, plus de cache, plus de silence.
    # Les raccourcis vivent en trois endroits (le menu, et les deux noms du
    # bureau - Bureau en francais, Desktop en anglais, DING lit celui que la
    # locale designe) ; les trois doivent porter la meme ligne.
    # [2026-09-05] TOUS LES COMPTES, PAS « osmocom » EN DUR. La liste nommait
    # /home/osmocom, le compte de la cle ; l installeur, lui, cree le compte que
    # l utilisateur a choisi. Sur une machine installee, aucune de ces lignes ne
    # designait donc son bureau, et les icones y gardaient l ancien Icon= (ou
    # n etaient jamais reparees). Meme confusion racine/session que les blocs
    # d addition.sh corriges le meme jour.
    local f b d
    for d in /usr/share/applications /root/Bureau /root/Desktop \
             /home/*/Bureau /home/*/Desktop; do
        [ -d "$d" ] || continue
        for b in osmo-launch osmo-multi osmo-tutorial; do
            f="$d/$b.desktop"
            [ -f "$f" ] || continue
            grep -q "^Icon=$dst/$b.svg\$" "$f" && continue
            sed -i "s|^Icon=.*|Icon=$dst/$b.svg|" "$f" 2>/dev/null || true
        done
    done

    # Un .desktop du bureau ne s affiche avec son nom et son icone que s il est
    # executable ET porteur de metadata::trusted. Cet attribut vit dans les
    # metadonnees gvfs de la SESSION, jamais dans le fichier : il se repose
    # donc ici, sous la session, et pas a la construction.
    # metadata::trusted vit dans les metadonnees gvfs DU PROPRIETAIRE : un `gio
    # set` lance par root le pose pour root, jamais pour la session de
    # l utilisateur. On repasse donc par son compte et son bus (runuser), comme
    # _trust_desktop() d addition.sh - sans quoi les icones du compte installe
    # restaient en pastille « fichier non fiable ».
    local _own _uid _bus
    for d in "$HOME/Bureau" "$HOME/Desktop" /root/Bureau /root/Desktop \
             /home/*/Bureau /home/*/Desktop; do
        [ -d "$d" ] || continue
        _own="$(stat -c '%U' "$d" 2>/dev/null)"; [ -n "$_own" ] || _own=root
        _uid="$(id -u "$_own" 2>/dev/null)" || continue
        _bus="/run/user/$_uid/bus"
        for f in "$d"/*.desktop; do
            [ -f "$f" ] || continue
            chown "$_own" "$f" 2>/dev/null || true
            chmod +x "$f" 2>/dev/null || true
            if [ -S "$_bus" ] && command -v runuser >/dev/null 2>&1; then
                runuser -u "$_own" -- env XDG_RUNTIME_DIR="/run/user/$_uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$_bus" \
                    gio set -t string "$f" metadata::trusted true 2>/dev/null || true
            else
                gio set -t string "$f" metadata::trusted true 2>/dev/null || true
            fi
        done
        # DING ne relit pas les metadonnees a chaud : toucher le repertoire le
        # force a rebalayer, sinon la page blanche reste jusqu au login suivant.
        touch "$d" 2>/dev/null || true
    done
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_reposer_icones

# ── LE MULTI NE DOIT PAS SE TUER EN RECYCLANT LE NATIF ──────────────────────
# [2026-09-05] osmo-multi.service portait `Requires=osmo-banc.service`. Or
# start-multi.sh applique « un clic = un banc neuf » : il ARRETE osmo-banc a
# chaque lancement, puis le relance. Requires= propage l arret explicite d une
# dependance a l unite qui en depend -- ce stop du natif arretait osmo-multi
# LUI-MEME en plein ExecStart (code=killed, status=15/TERM). Le correctif est
# `Wants=` : meme ordre au boot (After=), mais plus de propagation de l arret.
osmo_corriger_multi_natif() {
    [ "$(id -u)" -eq 0 ] || return 0
    local unit=/etc/systemd/system/osmo-multi.service
    [ -f "$unit" ] || return 0
    grep -q '^Requires=osmo-banc\.service$' "$unit" || return 0
    sed -i 's/^Requires=osmo-banc\.service$/Wants=osmo-banc.service/' "$unit"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    echo "[OK] osmo-multi.service : Requires=osmo-banc -> Wants (plus de suicide au recyclage du natif)."
    return 0
}
osmo_corriger_multi_natif

# ── L OUTIL DE PEINTURE (overlay) SUR LES MACHINES DEJA INSTALLEES ──────────
# [2026-09-05] tools/overlay-draw.py + son lanceur. build-iso l embarque ; ici
# on rattrape les machines deja posees : symlink, icone, chemin absolu. Idempotent.
osmo_poser_peinture() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    local py="$d/tools/overlay-draw.py"
    [ -f "$py" ] || return 0
    chmod 755 "$py" 2>/dev/null || true
    ln -sf "$py" /usr/local/bin/overlay-draw 2>/dev/null || true
    if [ -f "$d/data/osmo-paint.svg" ]; then
        install -d /usr/share/osmo-operator/icons \
                   /usr/share/icons/hicolor/scalable/apps 2>/dev/null || true
        cp -f "$d/data/osmo-paint.svg" /usr/share/osmo-operator/icons/osmo-paint.svg 2>/dev/null || true
        cp -f "$d/data/osmo-paint.svg" /usr/share/icons/hicolor/scalable/apps/osmo-paint.svg 2>/dev/null || true
        chmod 644 /usr/share/osmo-operator/icons/osmo-paint.svg 2>/dev/null || true
    fi
    if [ -f "$d/data/desktop/osmo-paint.desktop" ]; then
        install -m644 "$d/data/desktop/osmo-paint.desktop" \
                /usr/share/applications/osmo-paint.desktop 2>/dev/null || true
        sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/osmo-paint.svg|" \
            /usr/share/applications/osmo-paint.desktop 2>/dev/null || true
    fi
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_poser_peinture


# ── DEKA TOY : RATTRAPAGE DES MACHINES DEJA A JOUR AVEC DEKA ────────────────
# [2026-09-05] deka toy (banc de test COMP128v1, RAND=0, voir /root/deka/
# crack_toy.py) est arrive apres que des machines aient deja installe le
# supplement deka via addition.sh. Ces machines ont /root/deka a jour (meme
# depot git : crack_toy.py, delta_toy_client.py, deka-toy-start.sh y sont
# deja) mais pas encore l icone/le lanceur deka-toy, et ne repassent pas par
# addition.sh toutes seules. Simple pose de fichiers - PAS de compilation ici
# (voir l en-tete de ce script) : rien a construire, tout est deja clone.
#
# deka-toy-start.sh est un clone de deka-start.sh (seul le dernier worker
# change : delta_client -> toy-delta-client, et crack_toy.py build tourne
# avant les workers) : meme flux que deka, icone -> pkexec -> le script.
osmo_reposer_deka_toy() {
    [ "$(id -u)" -eq 0 ] || return 0
    local dir=/root/deka
    [ -f "$dir/crack_toy.py" ] && [ -f "$dir/delta_toy_client.py" ] \
        && [ -f "$dir/deka-toy-start.sh" ] || return 0
    # grep, pas juste -x : une machine qui a deja l ANCIEN lanceur (sans
    # pkexec, sans deka-toy-start.sh) doit se faire rattraper elle aussi.
    [ -f /usr/share/applications/deka-toy.desktop ] \
        && grep -q 'deka-toy-start.sh' /usr/local/bin/osmo-deka-toy 2>/dev/null \
        && return 0

    cat > /usr/local/bin/osmo-deka-toy <<'DEKATOYGUI'
#!/bin/bash
set -u
SCRIPT=/root/deka/deka-toy-start.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="deka-toy-start.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
RUNNER="$SCRIPT"
if [ "$(id -u)" -ne 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then
        RUNNER="pkexec env DISPLAY=${DISPLAY:-} XAUTHORITY=${XAUTHORITY:-} $SCRIPT"
    else
        RUNNER="sudo -E $SCRIPT"
    fi
fi
CMD="$RUNNER; echo; read -n1 -rsp 'deka toy lance - une touche pour fermer...'"
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="deka toy" -- bash -c "$CMD" ;;
        *)              exec "$term" -T "deka toy" -e bash -c "$CMD" ;;
    esac
done
exec bash -c "$RUNNER"
DEKATOYGUI
    chmod 755 /usr/local/bin/osmo-deka-toy

    install -d /usr/share/osmo-operator/icons /usr/share/icons/hicolor/scalable/apps
    if [ -f /opt/GSM/osmo-operator/data/deka-toy.svg ]; then
        install -m644 /opt/GSM/osmo-operator/data/deka-toy.svg /usr/share/osmo-operator/icons/deka-toy.svg
        install -m644 /opt/GSM/osmo-operator/data/deka-toy.svg /usr/share/icons/hicolor/scalable/apps/deka-toy.svg
    fi
    cat > /usr/share/applications/deka-toy.desktop <<'DEKATOYDSK'
[Desktop Entry]
Type=Application
Name=deka toy
Name[fr]=deka toy
Comment=Lance deka en mode toy (banc de test, sans les tables de 4 To)
Comment[fr]=Lance deka en mode toy (banc de test, sans les tables de 4 To)
Exec=/usr/local/bin/osmo-deka-toy
Icon=/usr/share/osmo-operator/icons/deka-toy.svg
Terminal=false
Categories=System;Utility;
Keywords=deka;toy;comp128;banc;test;
DEKATOYDSK
    chmod 644 /usr/share/applications/deka-toy.desktop
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_reposer_deka_toy

# ── FIREFOX ─────────────────────────────────────────────────────────────────
# Le dashboard et fft-web s ouvrent dans un navigateur. Les images du
# 2026-09-04 et apres embarquent le .deb de Mozilla : il est deja la, apt le
# tient a jour, et cette fonction ne fait rien.
#
# Elle ne sert donc qu aux machines plus anciennes, ou aux images ou le depot
# Mozilla etait injoignable au build. Elle repose ce depot puis installe le
# paquet - le "firefox" des depots Ubuntu n est PAS une solution de repli : il
# rappelle snapd, et c est ce montage-la qui laissait des bancs sans navigateur.
osmo_installer_firefox() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v firefox >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    echo "[*] Installation de Firefox (deb Mozilla)..."
    if [ ! -s /etc/apt/keyrings/packages.mozilla.org.asc ]; then
        install -d -m0755 /etc/apt/keyrings
        curl -fsSL --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
             -o /etc/apt/keyrings/packages.mozilla.org.asc || {
            echo "[WARN] packages.mozilla.org injoignable - Firefox non installe."
            return 0
        }
    fi
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" \
        > /etc/apt/preferences.d/mozilla
    apt-get update -qq 2>/dev/null || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y firefox >/dev/null 2>&1; then
        echo "[OK] Firefox installe (deb Mozilla)."
    else
        echo "[WARN] Firefox non installe (reseau ?)."
    fi
    return 0
}
osmo_installer_firefox

# ── LE COMPTE DE LA SESSION DOIT VOIR DOCKER ────────────────────────────────
# [2026-09-05] RATTRAPAGE : le Conky (tools/conky-osmo-status.sh) et l'encart
# (tools/osmo-panel.py) tournent sous le compte de la SESSION et sondent chaque
# operateur en conteneur par "docker exec". Sans le groupe docker, la sonde rend
# "permission denied while trying to connect to the docker API", que le code lit
# comme "operateur arrete" : Conky annoncant « banc a l arret » et sections
# Coeur GSM / Radio / Abonnes VIDES, avec les trois operateurs bien vivants.
# Le groupe est desormais pose a l'installation (users.conf, defaultGroups) et
# par addition.sh (_docker_groupe_session) ; ici on rattrape les machines deja
# installees, qui ne repassent par aucun des deux.
# Meme detection qu'addition.sh : SUDO_USER, puis PKEXEC_UID, puis le
# proprietaire d'un bus de session actif - update.sh est lance par une icone
# (pkexec) autant que par sudo.
osmo_docker_groupe_session() {
    [ "$(id -u)" -eq 0 ] || return 0
    getent group docker >/dev/null 2>&1 || return 0
    local u uid bus vus=""
    for u in "${SUDO_USER:-}" \
             "$([ -n "${PKEXEC_UID:-}" ] && getent passwd "$PKEXEC_UID" | cut -d: -f1)"; do
        [ -n "$u" ] && [ "$u" != root ] && getent passwd "$u" >/dev/null 2>&1 && { vus="$u"; break; }
    done
    if [ -z "$vus" ]; then
        for bus in /run/user/*/bus; do
            [ -S "$bus" ] || continue
            uid="${bus#/run/user/}"; uid="${uid%/bus}"
            [ "$uid" = 0 ] && continue
            u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
            [ -n "$u" ] && vus="$vus $u"
        done
    fi
    for u in $vus; do
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker && continue
        usermod -aG docker "$u" 2>/dev/null || continue
        echo "[OK] $u ajoute au groupe docker (le Conky et l encart voient les conteneurs)."
        echo "     Effectif au prochain login de $u."
    done
}
osmo_docker_groupe_session

case "${1:-}" in
    --quiet) exit 0 ;;
esac

# [2026-09-03] Le "git config --global http.version HTTP/1.1" qui etait ici est
# retire (voir Dockerfile) : on defait meme le reglage s il traine encore.
git config --global --unset http.version 2>/dev/null || true


# ── SANS TERMINAL : UNE FENETRE GTK ─────────────────────────────────────────
# [2026-09-03] Ici, le script sortait en silence des qu il n avait pas de tty.
# C etait juste pour l animation -- mais lance depuis l ICONE DU BUREAU, il n a
# jamais de tty : la repose des icones se faisait, et l utilisateur ne voyait
# RIEN. Aucun retour, aucune erreur, rien : le double-clic ne repondait pas.
#
# On garde la regle qui a motive la sortie (pas de sequences de curseur hors
# terminal, elles rendent un journal illisible) et on repond en GTK quand il y a
# un serveur graphique. Sans terminal NI graphique -- cron, ssh sans X,
# /etc/profile.d en console -- on sort comme avant, en silence et en code 0.
#
# zenity vient de la variante desktop (build-iso.sh l installe) ; l absence du
# binaire n est donc pas une erreur, c est une image sans bureau.
if [ ! -t 1 ]; then
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
        # --pulsate et non un pourcentage : les etapes ci-dessus sont deja
        # faites quand on arrive ici, il n y a pas de progression a mesurer --
        # une barre chiffree mentirait. --auto-close pour que la fenetre parte
        # avec le flux, sans bouton a cliquer.
        {
            echo "# Recherche de la cellule (ARFCN)..." ; sleep 0.6
            echo "# Raccourcis du bureau reposes."      ; sleep 0.6
            echo "# Envoi du SMS de test..."            ; sleep 0.6
        } | zenity --progress --pulsate --auto-close --no-cancel \
                   --title="osmo-operator - mise a jour" \
                   --width=420 --text="Mise a jour en cours..." 2>/dev/null
        zenity --info --title="osmo-operator" --width=420 \
               --text="<b>SMS delivered</b> - MT end-to-end\n\nMessage : Bastien phone home\n\nLes raccourcis du bureau ont ete reposes." \
               2>/dev/null
    fi
    exit 0
fi

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
    printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
    sleep 0.12
done
for ((p=0; p<=20; p++)); do
    printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
    sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"
