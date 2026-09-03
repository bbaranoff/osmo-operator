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
    local f b d
    for d in /usr/share/applications /root/Bureau /root/Desktop \
             /home/osmocom/Bureau /home/osmocom/Desktop; do
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
    for d in "$HOME/Bureau" "$HOME/Desktop" /root/Bureau /root/Desktop; do
        [ -d "$d" ] || continue
        for f in "$d"/*.desktop; do
            [ -f "$f" ] || continue
            chmod +x "$f" 2>/dev/null || true
            gio set -t string "$f" metadata::trusted true 2>/dev/null || true
        done
        # DING ne relit pas les metadonnees a chaud : toucher le repertoire le
        # force a rebalayer, sinon la page blanche reste jusqu au login suivant.
        touch "$d" 2>/dev/null || true
    done
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_reposer_icones

# ── FIREFOX ─────────────────────────────────────────────────────────────────
# Le dashboard et fft-web s'ouvrent dans un navigateur ; l'ISO n'en embarque
# pas toujours un. On le pose une seule fois : si le snap est deja la, on ne
# touche a rien - un boot ne doit pas dependre du reseau (cf. l'entete).
# Le vrai travail est dans /usr/local/sbin/osmo-firefox-snap, pose par
# build-iso.sh : .snap embarques d abord, magasin ensuite, interfaces de
# contenu reconnectees. On ne le redouble pas ici, on l appelle - et on garde
# un repli direct pour les machines assez anciennes pour ne pas l avoir.
osmo_installer_firefox() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v snap >/dev/null 2>&1 || return 0
    snap list firefox >/dev/null 2>&1 && return 0
    echo "[*] Installation de Firefox (snap)..."
    if [ -x /usr/local/sbin/osmo-firefox-snap ]; then
        /usr/local/sbin/osmo-firefox-snap >/dev/null 2>&1
    else
        snap install firefox >/dev/null 2>&1
    fi
    if snap list firefox >/dev/null 2>&1; then
        echo "[OK] Firefox installe."
    else
        echo "[WARN] Firefox non installe (reseau ?) - voir /var/log/osmo-firefox-snap.log"
    fi
    return 0
}
osmo_installer_firefox

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
