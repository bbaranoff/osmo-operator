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

# ── LE TELEPHONE postmarketOS SUR LES MACHINES DEJA INSTALLEES ──────────────
# [2026-09-07] Le telephone du banc n est plus Android (Waydroid, abandonne)
# mais une VM postmarketOS/Phosh : tools/osmo-pmos.sh. L ISO et le supplement
# (addition.sh, par tools/osmo-extras-install.sh) posent son lanceur et son
# icone ; une machine deja installee, elle, ne repasse ni par l un ni par
# l autre - d ou ce rattrapage. On enleve au passage l ancien lanceur Waydroid,
# qui pointerait sur un script disparu du depot. Idempotent.
osmo_poser_pmos() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    [ -f "$d/tools/osmo-pmos.sh" ] || return 0
    chmod 755 "$d/tools/osmo-pmos.sh" 2>/dev/null || true
    cat > /usr/local/bin/osmo-pmos <<'PM'
#!/bin/bash
# osmo-pmos - le telephone postmarketOS du banc (voir tools/osmo-pmos.sh).
exec "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-pmos.sh" "$@"
PM
    chmod 755 /usr/local/bin/osmo-pmos 2>/dev/null || true
    cat > /usr/share/applications/osmo-pmos.desktop <<'PMD'
[Desktop Entry]
Type=Application
Name=Telephone (postmarketOS)
Comment=Le telephone du banc - Phosh, ModemManager, appels et SMS reels
Exec=/usr/local/bin/osmo-pmos up
Icon=phone
Terminal=true
Categories=Network;Telephony;
Keywords=postmarketos;phosh;telephone;sms;appel;modem;
Actions=Etat;Arreter;

[Desktop Action Etat]
Name=Etat du telephone
Exec=/usr/local/bin/osmo-pmos status

[Desktop Action Arreter]
Name=Arreter le telephone
Exec=/usr/local/bin/osmo-pmos stop
PMD
    chmod 644 /usr/share/applications/osmo-pmos.desktop 2>/dev/null || true
    # [2026-09-07] LES DEUX LANCEURS PAR pmbootstrap vivent dans le depot :
    # tools/osmo-pmos-qemu.sh (la VM, format smartphone|tablette en argument)
    # et tools/osmo-pmos-setup.sh (le modem et la voix, VM demarree). Le
    # patch pmbootstrap qui va avec (port serie du modem, cartes son, taille
    # d ecran) est patches/pmbootstrap-osmo-bench-qemu.patch - il s applique
    # dans le pmbootstrap de l utilisateur, pas ici.
    local s
    for s in qemu setup; do
        [ -f "$d/tools/osmo-pmos-$s.sh" ] \
            && install -m 755 "$d/tools/osmo-pmos-$s.sh" "/usr/local/bin/osmo-pmos-$s" 2>/dev/null
    done
    # [2026-09-07] DEUX FORMATS, DEUX ICONES. Phosh se met en page d apres
    # l ecran qu on lui donne : haut et etroit, c est un telephone ; large,
    # c est une tablette - meme image, meme session. C est la carte graphique
    # de QEMU qui porte cette taille (OSMO_PMOS_RES, lu par le patch
    # pmbootstrap), et le systeme demarre dedans : le format se choisit donc
    # AU LANCEMENT et ne change pas sous une session deja ouverte. D ou deux
    # entrees plutot qu un reglage.
    local f n r
    for f in smartphone:720x1440 tablette:1280x800; do
        n="${f%%:*}"; r="${f#*:}"
        cat > "/usr/share/applications/osmo-pmos-$n.desktop" <<PMD
[Desktop Entry]
Type=Application
Name=postmarketOS - $n (banc)
Comment=Le telephone du banc, modem et voix branches tout seuls, en format $n ($r) - modem branche sur le banc GSM
Exec=env OSMO_PMOS_RES=$r /usr/local/bin/osmo-pmos-qemu
Icon=$([ "$n" = tablette ] && echo video-display || echo phone)
Terminal=true
Categories=Network;Telephony;System;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;$n;
Actions=Arreter;Setup;SansModem;

[Desktop Action Arreter]
Name=Arreter le telephone (osmo-pmos-qemu stop)
Exec=/usr/local/bin/osmo-pmos-qemu stop

[Desktop Action Setup]
Name=Rebrancher le modem et la voix (osmo-pmos-setup)
Exec=/usr/local/bin/osmo-pmos-setup

[Desktop Action SansModem]
Name=Demarrer sans modem (VM nue)
Exec=env OSMO_PMOS_RES=$r OSMO_PMOS_MODEM=0 /usr/local/bin/osmo-pmos-qemu
PMD
        chmod 644 "/usr/share/applications/osmo-pmos-$n.desktop" 2>/dev/null || true
    done
    rm -f /usr/local/bin/osmo-waydroid /usr/share/applications/osmo-waydroid.desktop 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    echo "  [telephone] osmo-pmos pose (VM postmarketOS ; « osmo-pmos install » la premiere fois)"
    echo "  [telephone] deux formats au lancement : smartphone (720x1440) et tablette (1280x800)"
    echo "  [telephone] « osmo-pmos-qemu stop » (ou le clic droit de l icone) arrete la VM et debranche le modem"
    return 0
}
osmo_poser_pmos

# ── WIRESHARK : UNE ICONE QUI ECOUTE DEJA LE BANC ───────────────────────────
# [2026-09-08] tools/osmo-wireshark-root.sh : root par pkexec (invite de mot de
# passe graphique), capture immediate LTE + SCTP + GSM. « wireshark » au
# clavier est un lien dessus. Le favori du dock (org.wireshark.Wireshark, le
# Wireshark nu qui refuse de capturer) est remplace par le notre, pour chaque
# session ouverte - les favoris sont dans le dconf de l utilisateur, pas de
# root (voir la famille root / session). L ISO fait pareil dans 80-chroot.
osmo_poser_wireshark() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    [ -f "$d/tools/osmo-wireshark-root.sh" ] || return 0
    install -m 755 "$d/tools/osmo-wireshark-root.sh" /usr/local/bin/osmo-wireshark-root
    ln -sfn /usr/local/bin/osmo-wireshark-root /usr/local/bin/wireshark
    cat > /usr/share/applications/osmo-wireshark-root.desktop <<'WSD'
[Desktop Entry]
Type=Application
Name=Wireshark (banc)
GenericName=Analyseur reseau
Comment=Wireshark en root, capture immediate du banc : LTE (S1AP, GTP, PFCP, Diameter), SCTP, GSM (GSMTAP, Abis, Gb, MGCP, SIP, RTP)
Exec=/usr/local/bin/osmo-wireshark-root %f
Icon=org.wireshark.Wireshark
Terminal=false
StartupNotify=true
Categories=Network;Monitor;
Keywords=wireshark;capture;pcap;reseau;lte;sctp;gsm;gsmtap;
WSD
    chmod 644 /usr/share/applications/osmo-wireshark-root.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
    # Le favori, dans chaque session GNOME ouverte.
    local u uid bus
    for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
        uid="$(id -u "$u" 2>/dev/null)" || continue
        bus="/run/user/$uid/bus"; [ -S "$bus" ] || continue
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" python3 - <<'PY' 2>/dev/null || true
import subprocess, ast
g = ["gsettings", "get", "org.gnome.shell", "favorite-apps"]
cur = ast.literal_eval(subprocess.run(g, capture_output=True, text=True).stdout.strip() or "[]")
neu = [a for a in cur if a not in ("org.wireshark.Wireshark.desktop", "wireshark.desktop", "wireshark-root.desktop")]
if "osmo-wireshark-root.desktop" not in neu:
    i = next((k for k, a in enumerate(cur) if a in ("org.wireshark.Wireshark.desktop", "wireshark.desktop")), len(neu))
    neu.insert(min(i, len(neu)), "osmo-wireshark-root.desktop")
if neu != cur:
    subprocess.run(["gsettings", "set", "org.gnome.shell", "favorite-apps", repr(neu)], check=False)
PY
    done
    echo "  [wireshark] osmo-wireshark-root pose (LTE + SCTP + GSM, root par pkexec) ; « wireshark » y mene ; favori du dock remplace"
    return 0
}
osmo_poser_wireshark

# ── LES LANCEURS /usr/local/bin (osmo-dino-play, osmo-youtube...) ───────────
# [2026-09-07] osmo-dino-play est CUIT dans /usr/local/bin par
# tools/osmo-extras-install.sh (addition.sh et l ISO) ; quand il change dans
# le depot - le plein ecran pilote par la page, ce jour-la - une machine deja
# installee garde l ancien. On rejoue la seule fonction qui pose les lanceurs :
# idempotente, sans apt, sans reseau.
osmo_reposer_lanceurs() {
    [ "$(id -u)" -eq 0 ] || return 0
    local ex=/opt/GSM/osmo-operator/tools/osmo-extras-install.sh
    [ -f "$ex" ] || return 0
    # shellcheck source=tools/osmo-extras-install.sh
    ( . "$ex" && _osmo_extras_lanceurs ) >/dev/null 2>&1 \
        && echo "  [bureau] lanceurs /usr/local/bin reposes (osmo-dino-play, osmo-pmos...)" \
        || true
    return 0
}
osmo_reposer_lanceurs

# ── BUREAU INTERACTIF : RATTRAPAGE DU WRAPPER osmo-desktop-panel ─────────────
# Le lanceur des widgets (/usr/local/bin/osmo-desktop-panel) est CUIT dans
# l image par iso_modules/85-installeur-bureau.sh. Les widgets eux-memes
# (osmo-topzone.py, osmo-launcher.py, osmo-ts-probe.py) vivent dans le depot et
# arrivent par git pull - mais une machine deja installee garde son ANCIEN
# wrapper, qui ne les lance pas. On re-pose donc le wrapper quand il ignore
# encore la zone haute vivante. Miroir exact de 85 (voir ce fichier).
osmo_reposer_bureau_interactif() {
    [ "$(id -u)" -eq 0 ] || return 0
    local w=/usr/local/bin/osmo-desktop-panel
    [ -f "$w" ] || return 0
    grep -q 'osmo-topzone.py' "$w" 2>/dev/null && return 0
    cat > "$w" <<'PANEL'
#!/bin/sh
# osmo-desktop-panel - tient l encart et Conky en vie pour toute la session.
REPO=/opt/GSM/osmo-operator
export OSMO_REPO="$REPO"
export OSMO_LIVE_BANNER=1
sleep 6
while :; do
    pgrep -f "$REPO/tools/osmo-panel.py" >/dev/null 2>&1 || \
        "$REPO/tools/osmo-panel.py" >>/tmp/osmo-panel.log 2>&1 &
    pgrep -f "$REPO/tools/osmo-dino.py" >/dev/null 2>&1 || \
        "$REPO/tools/osmo-dino.py" >>/tmp/osmo-dino.log 2>&1 &
    pgrep -f "$REPO/tools/osmo-ts-probe.py" >/dev/null 2>&1 || \
        "$REPO/tools/osmo-ts-probe.py" >>/tmp/osmo-ts-probe.log 2>&1 &
    pgrep -f "$REPO/tools/osmo-topzone.py" >/dev/null 2>&1 || \
        "$REPO/tools/osmo-topzone.py" >>/tmp/osmo-topzone.log 2>&1 &
    pgrep -f "$REPO/tools/osmo-launcher.py" >/dev/null 2>&1 || \
        "$REPO/tools/osmo-launcher.py" >>/tmp/osmo-launcher.log 2>&1 &
    pgrep -x conky >/dev/null 2>&1 || \
        conky --daemonize -c "$REPO/configs/conky/osmo-conky.conf" >>/tmp/osmo-conky.log 2>&1
    sleep 5
done
PANEL
    chmod 755 "$w"
    # relancer : tuer l ancien wrapper, l autostart (ou la boucle) reprend le neuf
    pkill -f /usr/local/bin/osmo-desktop-panel 2>/dev/null || true
    echo "  [bureau] wrapper osmo-desktop-panel remis a jour (zone LAB GSM vivante + barre de lancement)"
    return 0
}
osmo_reposer_bureau_interactif

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

# ── UNITES osmo-* : User=osmocom -> compte de la SESSION (rattrapage) ────────
# Miroir d'addition.sh (_osmo_unites_user_session) pour les machines DEJA
# installees qui ne repassent pas par addition.sh. Meme cause : les .service
# amont (osmo-bsc/bts-trx/bts-virtual/msc) posent User=osmocom / Group=osmocom,
# et le compte osmocom n'existe pas en natif (l'image le supprime, cf
# iso_modules/52-qemu.sh) -> 217/USER, crash-loop Restart=always MUET, run.sh
# abandonne ("OsmoMSC started but never ready"). On rend les unites au compte de
# session via un drop-in /etc/systemd/system/<unit>.d/ (le .service amont reste
# intact). Meme detection d'user qu'osmo_docker_groupe_session.
osmo_unites_user_session() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local u uid bus grp unit base d n=0 vus=""
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
            [ -n "$u" ] && { vus="$u"; break; }
        done
    fi
    [ -n "$vus" ] && getent passwd "$vus" >/dev/null 2>&1 || vus=root
    grp="$(id -gn "$vus" 2>/dev/null || echo "$vus")"
    for unit in /lib/systemd/system/osmo-*.service /etc/systemd/system/osmo-*.service; do
        [ -f "$unit" ] || continue
        grep -qE '^(User|Group)=osmocom$' "$unit" || continue
        base="$(basename "$unit")"; d="/etc/systemd/system/$base.d"
        mkdir -p "$d"
        printf '[Service]\nUser=%s\nGroup=%s\n' "$vus" "$grp" > "$d/00-session-user.conf"
        n=$((n+1))
    done
    [ "$n" -gt 0 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    # repertoires d'etat/log osmocom -> compte de session, sinon "Unable to
    # create file /var/log/osmocom/*.log" -> parse .cfg en echec -> status=1.
    for _d in /var/log/osmocom /var/lib/osmocom /run/osmocom; do
        [ -e "$_d" ] && chown -R "$vus:$grp" "$_d" 2>/dev/null || true
    done
    for base in osmo-msc osmo-bsc osmo-bts-trx osmo-bts-virtual; do
        systemctl cat "$base" >/dev/null 2>&1 || continue
        systemctl reset-failed "$base" 2>/dev/null || true
        systemctl try-restart "$base" 2>/dev/null || true
    done
    echo "[OK] unites osmo-* rendues au compte de session ($vus) - sinon User=osmocom -> 217/USER."
    return 0
}
osmo_unites_user_session

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
