#!/bin/bash
# iso_modules/85-installeur-bureau.sh - calamares, osmo-install, bureau (icones, lanceurs)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# --arm : calamares, osmo-install et le bureau : pas de --desktop en arm64, rien a poser.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ── L INSTALLEUR ────────────────────────────────────────────────────────────
# La configuration vit dans le depot (installer/calamares/) plutot qu en
# heredocs ici : elle est relisible, versionnee, et validable hors build
# (c est du YAML, "python3 -c import yaml" suffit a la verifier).
_CAL_SRC="$DIR/installer/calamares"
if [ "${ISO_DESKTOP:-0}" = "1" ] && [ -d "$_CAL_SRC" ]; then
    install -d "$ROOTFS/etc/calamares"
    cp -a "$_CAL_SRC/settings.conf" "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/modules"       "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/branding"      "$ROOTFS/etc/calamares/"

    # Les images de l habillage : on reprend le fond d ecran deja fige au build
    # plutot que d ajouter des binaires au depot. Calamares les met a l echelle.
    _WPI="$DIR/configs/gsm-lab-wallpaper.png"
    if [ -f "$_WPI" ]; then
        cp "$_WPI" "$ROOTFS/etc/calamares/branding/osmo/welcome.png"
        cp "$_WPI" "$ROOTFS/etc/calamares/branding/osmo/logo.png"
    else
        # Sans image, Calamares journalise une erreur par ecran. On retire les
        # trois cles plutot que de laisser pointer vers des fichiers absents.
        sed -i '/^images:/,/^slideshow:/{/productLogo\|productIcon\|productWelcome/d}' \
            "$ROOTFS/etc/calamares/branding/osmo/branding.desc"
    fi

    # ── LE LANCEUR ──────────────────────────────────────────────────────────
    # pkexec et non sudo : l installeur est lance depuis le bureau, ou il n y a
    # pas de terminal pour taper un mot de passe. La session tourne deja en
    # root, mais osmocom doit pouvoir lancer l installeur aussi - et c est la
    # que pkexec sert vraiment.
    cat > "$ROOTFS/usr/local/bin/osmo-install" <<'INSTALLER'
#!/bin/bash
# Lance l installeur du systeme. Sur la cle live uniquement.
set -u
if [ ! -r /etc/calamares/settings.conf ]; then
    echo "Calamares n est pas installe sur cette image (ISO_DESKTOP=0 ?)." >&2
    exit 1
fi

# On repasse root TOUT DE SUITE, et sur ce script - pas sur calamares. Ce qui
# suit (monter le medium, demonter une cible restee ouverte) demande root ;
# le faire apres pkexec, c etait le faire en simple utilisateur, donc pas du
# tout. pkexec transmet DISPLAY et XAUTHORITY, l interface s ouvre quand meme.
if [ "$(id -u)" -ne 0 ]; then
    exec pkexec --disable-internal-agent "$0" "$@"
fi

# ── Retrouver le squashfs, sans jamais supposer OU il est ───────────────────
# LE SYMPTOME QUI A AMENE CE BLOC A SA FORME ACTUELLE. L entree "en RAM" du
# menu demarre parfaitement, et depuis elle - et depuis elle seule -
# l installeur repondait "Medium live introuvable ... Rien a installer".
#
# POURQUOI. En mode normal, live-boot monte le medium sur /run/live/medium et
# le squashfs y est a sa place d origine : live/filesystem.squashfs. En
# "toram=filesystem.squashfs", live-boot ne recopie PAS l arborescence du
# medium : il copie LE FICHIER, seul, a la racine d un tmpfs, puis deplace ce
# tmpfs sur /run/live/medium (cp -a "${MODULETORAMFILE}" "${copyto}", puis
# mount -r -o move). Le squashfs se retrouve donc en
#     /run/live/medium/filesystem.squashfs
# et non plus en
#     /run/live/medium/live/filesystem.squashfs
# Le sous-repertoire "live/" a disparu au passage. live-boot s en moque - il
# sait ou il l a mis - mais tout ce qui ecrit ce chemin en dur le rate.
#
# Et la version precedente de ce bloc le ratait DEUX FOIS : son repli prenait
# le fichier de backing du loop (donc le bon chemin), puis lui appliquait deux
# dirname pour "remonter a la racine du medium". Deux dirname sur
# /run/live/medium/filesystem.squashfs donnent /run/live - qui n a pas plus de
# sous-repertoire "live/". Le bind reussissait, le test suivant echouait, et le
# message accusait le medium d etre absent alors qu il etait en RAM, monte, et
# parfaitement lisible.
#
# CE QU ON FAIT A LA PLACE. On ne reconstitue plus une arborescence supposee :
# on trouve LE FICHIER, par trois voies de plus en plus larges, et on le
# presente a Calamares a un chemin qui, lui, ne depend d aucun mode de
# demarrage. C est ce chemin que nomme unpackfs.conf.
SQ=""

# 1. Le chemin canonique du demarrage normal. S il est la, rien a faire.
[ -e /run/live/medium/live/filesystem.squashfs ] \
    && SQ=/run/live/medium/live/filesystem.squashfs

# 2. Le loop qui porte la racine en cours d execution. C est la source la plus
#    sure qui soit : ce n est pas "un" squashfs trouve quelque part, c est
#    CELUI sur lequel ce systeme tourne. Vrai en normal, en toram et en
#    persistant.
if [ -z "$SQ" ]; then
    _loop=$(findmnt -no SOURCE /run/live/rootfs/filesystem.squashfs 2>/dev/null || true)
    if [ -n "$_loop" ]; then
        _bf=$(losetup -nO BACK-FILE "$_loop" 2>/dev/null || true)
        [ -n "$_bf" ] && [ -e "$_bf" ] && SQ="$_bf"
    fi
fi

# 3. Dernier recours : n importe quel loop dont le fichier de backing est un
#    squashfs. Couvre le cas ou live-boot aurait nomme le point de montage
#    autrement (persistance : /run/live/persistence/sdX).
if [ -z "$SQ" ]; then
    SQ=$(losetup -anO BACK-FILE 2>/dev/null | grep -m1 '\.squashfs$' || true)
    [ -n "$SQ" ] && [ -e "$SQ" ] || SQ=""
fi

if [ -z "$SQ" ]; then
    echo "Squashfs introuvable - ce systeme ne tourne pas depuis une cle live," >&2
    echo "ou l image n est plus lisible. Rien a installer." >&2
    exit 1
fi

# ── LE CHEMIN STABLE, CELUI QUE CALAMARES LIT ───────────────────────────────
# Un bind sur le FICHIER, pas sur son repertoire : le repertoire d origine
# change de forme d un mode de demarrage a l autre (c est tout le probleme
# ci-dessus), le fichier non. /run est un tmpfs sur un systeme live, donc
# inscriptible - contrairement a /run/live/medium en toram, que live-boot
# deplace en lecture seule et dans lequel on ne pourrait pas creer le "live/"
# qui manque.
SRC=/run/osmo-install-src
mkdir -p "$SRC/live"
if ! mountpoint -q "$SRC/live/filesystem.squashfs"; then
    : > "$SRC/live/filesystem.squashfs"
    mount --bind "$SQ" "$SRC/live/filesystem.squashfs" || {
        echo "Impossible de presenter $SQ a l installeur." >&2
        exit 1
    }
fi
echo "Image source : $SQ  ->  $SRC/live/filesystem.squashfs"

# Le FICHIER, pas le repertoire. Tester "-d" ne prouvait rien : le repertoire
# existe meme vide, le test passait, et l echec tombait plus loin dans
# Calamares - au pire endroit, le disque deja repartitionne.
if [ ! -s "$SRC/live/filesystem.squashfs" ]; then
    echo "Le squashfs presente a l installeur est vide - rien a installer." >&2
    exit 1
fi

# ── Nettoyer la cible d un essai precedent ──────────────────────────────────
# Quand une etape echoue, Calamares saute tous les jobs suivants, "umount"
# compris : la cible reste montee sous /tmp/calamares-root-*. Au lancement
# d apres il voit un disque monte, retire "Effacer le disque" de la liste et ne
# laisse que le partitionnement manuel. Chaque echec degradait l essai suivant.
for _t in /tmp/calamares-root-*; do
    [ -d "$_t" ] || continue
    if mountpoint -q "$_t"; then
        umount -R "$_t" 2>/dev/null || {
            echo "Cible $_t encore montee et non demontable - fermez ce qui l occupe" >&2
            echo "(un terminal, un gestionnaire de fichiers) ou redemarrez." >&2
            exit 1
        }
    fi
    rmdir "$_t" 2>/dev/null || true
done

# ── MIROIR : la page "Miroir Ubuntu" de l installeur suit le reseau ─────────
# packaging/apt-mirror.sh --list mesure les miroirs d ici (5 s max chacun) ;
# la page propose ceux qui repondent, du plus rapide au plus lent, le premier
# pre-selectionne, plus "celui de la cle" (aucun changement). Le module
# contextualprocess@mirror ecrit le choix dans la cible, apres unpackfs.
# Aucun guillemet dans les commandes : elles sont entre apostrophes (bash -c)
# dans une chaine YAML entre guillemets. L espace du remplacement sed est
# echappe par une barre oblique inverse, lue par le bash de la cible.
_pm=/etc/calamares/modules/packagechooser-mirror.conf
_cm=/etc/calamares/modules/contextualprocess-mirror.conf
_am=/opt/GSM/osmo-operator/packaging/apt-mirror.sh
if [ -f "$_pm" ] && [ -f "$_cm" ] && [ -f "$_am" ]; then
    _cur="$(sed -nE 's|^deb (http[^ ]+) .*|\1|p' /etc/apt/sources.list 2>/dev/null | head -1)"
    _suite="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")"
    _mlist="$(bash "$_am" --list "$_suite" 2>/dev/null || true)"
    _n=0
    {
        echo "---"
        echo "mode: required"
        echo "method: legacy"
        echo "labels:"
        echo "    step: \"Miroir Ubuntu\""
        if [ -n "$_mlist" ]; then echo "default: m1"; else echo "default: keep"; fi
        echo "items:"
        echo "    - id: keep"
        echo "      name: \"Celui de la cle live\""
        echo "      description: \"Le systeme installe garde le miroir de la cle : ${_cur:-archive.ubuntu.com}.\""
        printf '%s\n' "$_mlist" | while IFS="$(printf '\t')" read -r _ms _url; do
            [ -n "$_url" ] || continue
            _n=$((_n + 1))
            _tag=""; [ "$_n" = 1 ] && _tag=" - le plus rapide d ici"
            echo "    - id: m${_n}"
            echo "      name: \"${_url#http://}\""
            echo "      description: \"${_url} - InRelease en ${_ms} ms${_tag}.\""
        done
    } > "$_pm"
    {
        echo "---"
        echo "dontChroot: false"
        echo "timeout: 60"
        echo "packagechooser_mirror:"
        echo "    \"keep\":"
        echo "        - \"-/bin/true\""
        _n=0
        printf '%s\n' "$_mlist" | while IFS="$(printf '\t')" read -r _ms _url; do
            [ -n "$_url" ] || continue
            _n=$((_n + 1))
            echo "    \"m${_n}\":"
            echo "        - \"-/bin/bash -c 'sed -i -E s,^deb\\shttps?://\\S+,deb\\ ${_url}, /etc/apt/sources.list; [ -f /etc/apt/sources.list.d/ubuntu.sources ] && sed -i -E s,^URIs:\\shttps?://\\S+,URIs:\\ ${_url}, /etc/apt/sources.list.d/ubuntu.sources; echo [mirror] ${_url}'\""
        done
    } > "$_cm"
    if [ -n "$_mlist" ]; then
        echo "Miroir Ubuntu : $(printf '%s\n' "$_mlist" | wc -l) miroirs mesures, le plus rapide : $(printf '%s\n' "$_mlist" | head -1 | cut -f2)"
    else
        echo "Miroir Ubuntu : aucune mesure (pas de reseau ?) - la cible garde ${_cur:-archive.ubuntu.com}"
    fi
fi

# ── NVIDIA : la page "Pilotes graphiques" de l installeur suit la machine ────
# Calamares ne sait pas griser une entree selon le materiel, et ne connait pas
# la liste des pilotes disponibles : on ECRIT sa page de choix et le module
# qui installe a CHAQUE lancement, d apres lspci et ubuntu-drivers :
#   - une entree par pilote que ubuntu-drivers propose (nvidia-driver-5xx,
#     -open, -server...), avec son etat : "recommande", "deja installe" ;
#   - une entree "recommande par ubuntu-drivers" pre-selectionnee quand une
#     carte est vue, "aucun" sinon ;
#   - sans carte NVIDIA, la page le dit et tout choix reste sans effet
#     (contextualprocess refait le test lspci dans la cible).
# Sur le systeme installe, tools/osmo-drivers.sh (icone "Pilotes graphiques")
# montre le meme etat et laisse installer ou mettre a jour plus tard.
_pc=/etc/calamares/modules/packagechooser-nvidia.conf
_cp=/etc/calamares/modules/contextualprocess-nvidia.conf
if [ -f "$_pc" ] && [ -f "$_cp" ]; then
    _nv="$(lspci -d 10de: 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ //; s/ (rev.*//')"
    _drivers=""; _reco=""
    if [ -n "$_nv" ] && command -v ubuntu-drivers >/dev/null 2>&1; then
        _drivers="$(ubuntu-drivers list 2>/dev/null | awk '/^nvidia-driver-/{print $1}' | sed 's/,.*//' | sort -u)"
        _reco="$(ubuntu-drivers devices 2>/dev/null | awk '/^driver *:/ && /recommended/{print $3; exit}')"
    fi
    # Aucun guillemet dans cette commande : elle est posee entre apostrophes
    # (bash -c) dans une chaine YAML entre guillemets - l un comme l autre y
    # seraient une fin de chaine. /run de la cible est un tmpfs vide (mount.conf)
    # et /etc/resolv.conf y pointe : on y ecrit des resolveurs le temps de l apt.
    _apt_cmd='mkdir -p /run/systemd/resolve; [ -s /run/systemd/resolve/stub-resolv.conf ] || { echo nameserver 1.1.1.1 > /run/systemd/resolve/stub-resolv.conf; echo nameserver 8.8.8.8 >> /run/systemd/resolve/stub-resolv.conf; }; export DEBIAN_FRONTEND=noninteractive; lspci -n 2>/dev/null | grep -qi 10de: || { echo [nvidia] aucune carte NVIDIA : rien a installer; exit 0; }; apt-get update -qq || { echo [nvidia] pas de reseau : pilote non installe; exit 0; }'
    {
        echo "---"
        echo "mode: optional"
        echo "method: legacy"
        echo "labels:"
        echo "    step: \"Pilotes graphiques\""
        if [ -n "$_nv" ]; then echo "default: recommended"; else echo "default: none"; fi
        echo "items:"
        echo "    - id: none"
        echo "      name: \"Aucun pilote supplementaire\""
        if [ -n "$_nv" ]; then
            echo "      description: \"Carte detectee : ${_nv}. Le pilote libre (nouveau) du noyau, comme sur la cle live.\""
            echo "    - id: recommended"
            echo "      name: \"Pilote NVIDIA recommande (ubuntu-drivers)\""
            echo "      description: \"Installe ${_reco:-le pilote recommande par ubuntu-drivers} depuis les depots Ubuntu (reseau requis).\""
            for _drv in $_drivers; do
                _state=""
                [ "$_drv" = "$_reco" ] && _state=" - recommande"
                dpkg -s "$_drv" >/dev/null 2>&1 && _state="$_state - deja installe sur ce systeme"
                echo "    - id: ${_drv}"
                echo "      name: \"${_drv}\""
                echo "      description: \"Pilote proprietaire NVIDIA ${_drv#nvidia-driver-}${_state}. Installe depuis les depots Ubuntu (reseau requis).\""
            done
        else
            echo "      description: \"AUCUNE carte NVIDIA detectee (lspci) : rien a installer sur cette machine.\""
        fi
    } > "$_pc"
    {
        echo "---"
        echo "dontChroot: false"
        echo "timeout: 1800"
        echo "packagechooser_nvidia:"
        echo "    \"none\":"
        echo "        - \"-/bin/true\""
        echo "    \"recommended\":"
        echo "        - \"-/bin/bash -c '${_apt_cmd}; apt-get install -y --no-install-recommends ubuntu-drivers-common >/dev/null 2>&1; ubuntu-drivers install || apt-get install -y ${_reco:-nvidia-driver-550}; update-initramfs -u >/dev/null 2>&1 || true'\""
        for _drv in $_drivers; do
            echo "    \"${_drv}\":"
            echo "        - \"-/bin/bash -c '${_apt_cmd}; apt-get install -y ${_drv}; update-initramfs -u >/dev/null 2>&1 || true'\""
        done
    } > "$_cp"
    if [ -n "$_nv" ]; then
        echo "NVIDIA : $_nv - pilotes proposes : $(echo ${_drivers:-(liste ubuntu-drivers vide)})${_reco:+ ; recommande : $_reco}"
    else
        echo "NVIDIA : aucune carte detectee - la page le dira, sans effet"
    fi
fi

exec /usr/bin/calamares -d "$@"
INSTALLER
    chmod +x "$ROOTFS/usr/local/bin/osmo-install"

    # ── CONKY : le tableau de bord du banc, dans TOUTE session GNOME ─────────
    # [2026-09-03] /etc/xdg/autostart vaut pour tous les comptes : root sur la
    # cle live, l utilisateur cree par Calamares sur le disque (le fichier
    # voyage dans le squashfs, donc dans la copie installee). La config et le
    # script d etat vivent dans le depot (/opt/GSM/osmo-operator, present sur
    # les deux) : configs/conky/osmo-conky.conf, tools/conky-osmo-status.sh.
    # sleep 6 : conky doit trouver le bureau GNOME deja peint (own_window_type
    # desktop), sinon il reste derriere le fond d ecran. --daemonize : la
    # session n attend pas. Une seule instance : pkill avant.
    cat > "$ROOTFS/etc/xdg/autostart/osmo-conky.desktop" <<'CONKY'
[Desktop Entry]
Type=Application
Name=Conky osmo-operator
Comment=Tableau de bord du banc GSM (coeur, radio, abonnes, services)
Exec=sh -c 'sleep 6; pkill -x conky 2>/dev/null; /opt/GSM/osmo-operator/tools/osmo-panel.py >/tmp/osmo-panel.log 2>&1 & exec conky --daemonize -c /opt/GSM/osmo-operator/configs/conky/osmo-conky.conf'
Icon=utilities-system-monitor
Terminal=false
NoDisplay=true
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=6
CONKY
    chmod 644 "$ROOTFS/etc/xdg/autostart/osmo-conky.desktop"
    chmod +x "$ROOTFS/opt/GSM/osmo-operator/tools/conky-osmo-status.sh" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-drivers.sh" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-fft-snap.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-panel.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/wallpaper-render.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-wallpaper.sh" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Conky du banc : autostart GNOME (live et disque), config ${CYAN}configs/conky/osmo-conky.conf${NC}"

    # Le fichier vit dans le depot (data/desktop/), pas en heredoc ici :
    # l install native (install_modules/80-bureau.sh) et le paquet .deb posent
    # le MEME.
    # [2026-09-03] TOUS les raccourcis du depot, pas seulement osmo-install.
    # Ils etaient poses par l install native (install_modules/80-bureau.sh) et
    # par le .deb, mais PAS dans l ISO : la cle live n avait qu une icone sur
    # neuf, et les huit autres n existaient meme pas dans le menu des
    # applications — donc le dock ne pouvait pas les afficher non plus.
    for _d in "$DIR"/data/desktop/*.desktop; do
        [ -f "$_d" ] || continue
        install -m644 "$_d" "$ROOTFS/usr/share/applications/$(basename "$_d")"
    done

    # ── PLUS D ICONES SUR LE BUREAU : LE DOCK SUFFIT ─────────────────────
    # [2026-09-04] Les raccourcis ne sont plus copies dans ~/Desktop ni
    # ~/Bureau : ils vivent dans /usr/share/applications (ci-dessus) et dans
    # les favoris du dock (favorite-apps, iso_modules/80-chroot.sh). Cela
    # retire aussi tout le mecanisme d approbation (metadata::trusted,
    # osmo-trust-desktop au login) qui n existait que pour DING.
    # Le bureau reste vide ; le fond d ecran du jour s y voit en entier.
    rm -f "$ROOTFS/root/Desktop"/*.desktop "$ROOTFS/root/Bureau"/*.desktop \
          "$ROOTFS/home/osmocom/Desktop"/*.desktop "$ROOTFS/home/osmocom/Bureau"/*.desktop \
          "$ROOTFS/usr/local/bin/osmo-trust-desktop" \
          "$ROOTFS/etc/xdg/autostart/osmo-trust-desktop.desktop" 2>/dev/null || true
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true

    # ── LANCEUR ET TUTORIEL : ICONES DU BUREAU ────────────────────────────
    # Icones du depot (data/*.svg) et pas des noms du theme : "call-start" est
    # VERT dans Adwaita et n a pas de variante rouge, et un nom d icone absent
    # se remplace EN SILENCE par un rectangle gris - le lanceur devient alors
    # introuvable sur le bureau qu il est cense ouvrir.
    install -d "$ROOTFS/usr/share/icons/hicolor/scalable/apps" \
              "$ROOTFS/usr/share/osmo-operator/icons" \
              "$ROOTFS/usr/share/osmo-operator"
    for _ic in osmo-launch osmo-multi osmo-tutorial claude; do
        [ -f "$DIR/data/$_ic.svg" ] || continue
        cp -f "$DIR/data/$_ic.svg" \
              "$ROOTFS/usr/share/icons/hicolor/scalable/apps/$_ic.svg"
        # LA COPIE QUI COMPTE POUR LE BUREAU. Voir le bloc juste dessous.
        cp -f "$DIR/data/$_ic.svg" \
              "$ROOTFS/usr/share/osmo-operator/icons/$_ic.svg"
        chmod 644 "$ROOTFS/usr/share/osmo-operator/icons/$_ic.svg"
    done

    # ⚠️ LES .desktop POINTENT LE FICHIER, PAS LE NOM DE L ICONE.
    # [2026-08-31] Les trois raccourcis s affichaient en PAGE BLANCHE generique
    # sur le bureau, SVG valides et bien installes. Cause : "Icon=osmo-launch"
    # n est pas un chemin, c est un nom a resoudre dans le thème, et cette
    # resolution passe par /usr/share/icons/hicolor/icon-theme.cache. Le cache
    # etait construit AVANT que les icones n arrivent - constate sur le banc :
    #     strings .../icon-theme.cache | grep -c osmo   ->  0
    #     cache 17:22:12   ·   icones 17:28:07
    # Zero entree sur trois, et rien ne le signale : un nom d icone qui ne
    # resout pas se remplace EN SILENCE par la page blanche. "Supplements" s en
    # sortait seul parce que son "system-software-install" vient de Yaru, deja
    # dans le cache depuis l installation du systeme.
    # D ou les deux mesures, et pas une seule :
    #   - Icon= en CHEMIN ABSOLU (plus bas) : court-circuite thème et cache,
    #     c est ce qui garantit l icone sur le bureau ;
    #   - le cache reconstruit quand meme, pour le menu des applications, qui
    #     lui continue de resoudre par nom.
    if chroot "$ROOTFS" sh -c 'command -v gtk-update-icon-cache' >/dev/null 2>&1; then
        chroot "$ROOTFS" gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    fi
    [ -f "$DIR/data/tutorial.html" ] && \
        cp -f "$DIR/data/tutorial.html" "$ROOTFS/usr/share/osmo-operator/tutorial.html"

    # Le tutoriel passe par le HOME, et ce detour n est pas cosmetique :
    # FIREFOX EST UN SNAP. Son bac a sable lui donne l interface "home", pas
    # /opt ni /usr/share : un file:///opt/GSM/... s ouvre sur "Fichier
    # introuvable" - message qui ne parle ni de snap ni de confinement, et qui
    # envoie chercher la panne du cote du fichier, qui est pourtant bien la.
    cat > "$ROOTFS/usr/local/bin/osmo-tutorial" <<'TUTO'
#!/bin/bash
# osmo-tutorial - ouvre le quick-start.
#
# PAR HTTP, PAS PAR file://. Firefox est un SNAP, et son bac a sable refuse le
# fichier pour TROIS raisons cumulees, constatees le 31/08 :
#   - firefox:home n est meme pas connecte (snap connections firefox -> "-") ;
#   - l interface home, meme branchee, ne couvre QUE /home/* - jamais /root,
#     qui est pourtant le compte de la session (gdm3 AutomaticLogin=root) ;
#   - elle exclut les repertoires caches, donc ~/.local/share/... aussi.
# Resultat a l ecran : "L acces au fichier a ete refuse" - message qui accuse
# le fichier alors qu il est bien la et lisible. C est le confinement.
# Le dashboard sert deja du statique sur 8080 : on passe par lui, et la
# question du bac a sable ne se pose plus.
set -u
URL="${OSMO_TUTORIAL_URL:-http://127.0.0.1:8080/tutorial.html}"
PORT="${URL##*:}"; PORT="${PORT%%/*}"
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    exec xdg-open "$URL"
fi
echo "Dashboard injoignable sur $PORT - repli file:// (echouera sous Firefox snap)" >&2
exec xdg-open "file:///usr/share/osmo-operator/tutorial.html"
TUTO
    chmod +x "$ROOTFS/usr/local/bin/osmo-tutorial"

    # Le fichier vit dans le depot (data/desktop/), pas en heredoc ici :
    # l install native (install_modules/80-bureau.sh) et le paquet .deb posent
    # le MEME.
    install -m644 "$DIR/data/desktop/osmo-launch.desktop" "$ROOTFS/usr/share/applications/osmo-launch.desktop"
    # [2026-09-04] Plus d'icone DSP a part : le clic droit du telephone
    # (osmo-launch.desktop, action « Lancer en mode DSP ») suffit.
    rm -f "$ROOTFS/usr/share/applications/osmo-dsp.desktop"

    # osmo-multi (antenne, multi-operator) N EST PLUS POSEE ICI. Son lanceur
    # start-multi.sh suppose docker + l image + la topologie SS7, qui n existent
    # qu apres le supplement (addition.sh). L icone apparaissait donc au premier
    # boot pour ne rien faire au clic ; addition.sh la pose desormais LUI-MEME,
    # a la fin d une install SS7 reussie. Son SVG reste installe (bloc icones
    # ci-dessus) pour que cette pose differee y trouve l image.

    # ── SUPPLEMENTS : LA FENETRE A COCHER ─────────────────────────────────
    # Meme facture que osmo-update-anim : un terminal, et la main rendue
    # seulement quand on a lu la fin. addition.sh ouvre lui-meme sa liste a
    # cocher (zenity) quand DISPLAY est la ; le terminal reste utile pour la
    # suite, qui est longue et bavarde (apt, puis compilation Osmocom).
    cat > "$ROOTFS/usr/local/bin/osmo-addition-anim" <<'ADDGUI'
#!/bin/bash
set -u
SCRIPT=/opt/GSM/osmo-operator/addition.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="addition.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
# pkexec : les supplements installent des paquets et demarrent un demon. Sans
# elevation, apt-get echoue a la premiere ligne et la fenetre se ferme sur un
# "Permission denied" qui ne dit pas qu il fallait etre root.
RUNNER="$SCRIPT"
if [ "$(id -u)" -ne 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then
        # pkexec NETTOIE l environnement : sans ce report, root perd le proxy
        # HTTP de la session, et les git clone du supplement (deka, a51_tools,
        # dst80_reversing, tea1-cracker) echouent alors qu ils marchent en
        # shell. On transmet DISPLAY/XAUTHORITY et les variables de proxy qui
        # SONT definies (indirection ${!v} - le lanceur est en bash).
        _fwd="DISPLAY=${DISPLAY:-} XAUTHORITY=${XAUTHORITY:-}"
        for _v in http_proxy https_proxy ftp_proxy no_proxy \
                  HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
            _val="${!_v-}"
            [ -n "$_val" ] && _fwd="$_fwd $_v=$_val"
        done
        RUNNER="pkexec env $_fwd $SCRIPT"
    else
        RUNNER="sudo -E $SCRIPT"
    fi
fi
CMD="$RUNNER; echo; read -n1 -rsp 'Termine - une touche pour fermer...'"
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="osmo-operator supplements" -- bash -c "$CMD" ;;
        *)              exec "$term" -T "osmo-operator supplements" -e bash -c "$CMD" ;;
    esac
done
exec bash -c "$RUNNER"
ADDGUI
    chmod +x "$ROOTFS/usr/local/bin/osmo-addition-anim"

    # Le fichier vit dans le depot (data/desktop/), pas en heredoc ici :
    # l install native (install_modules/80-bureau.sh) et le paquet .deb posent
    # le MEME.
    install -m644 "$DIR/data/desktop/osmo-addition.desktop" "$ROOTFS/usr/share/applications/osmo-addition.desktop"

    # Le fichier vit dans le depot (data/desktop/), pas en heredoc ici :
    # l install native (install_modules/80-bureau.sh) et le paquet .deb posent
    # le MEME.
    install -m644 "$DIR/data/desktop/osmo-tutorial.desktop" "$ROOTFS/usr/share/applications/osmo-tutorial.desktop"

    # ── CLAUDE : lanceur + entree de menu ─────────────────────────────────
    # Claude Code n est PAS dans l ISO (il s installe via le supplement) : le
    # lanceur enchaine donc l installation (addition.sh --claude) au premier
    # clic si claude manque, puis l ouvre. L icone est la des le boot, mais elle
    # ne ment pas - elle sait s installer elle-meme.
    cat > "$ROOTFS/usr/local/bin/osmo-claude-anim" <<'CLA'
#!/bin/bash
set -u
if ! command -v claude >/dev/null 2>&1; then
    ADD=/opt/GSM/osmo-operator/addition.sh
    if [ -x "$ADD" ]; then
        if [ "$(id -u)" -ne 0 ] && command -v pkexec >/dev/null 2>&1; then
            pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" "$ADD" --claude
        else
            "$ADD" --claude
        fi
    fi
fi
CMD='if command -v claude >/dev/null 2>&1; then claude; else echo "Claude non installe - lancez le supplement (--claude)."; fi; echo; read -n1 -rsp "Une touche pour fermer..."'
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="Claude" -- bash -lc "$CMD" ;;
        *)              exec "$term" -T "Claude" -e bash -lc "$CMD" ;;
    esac
done
exec bash -lc "$CMD"
CLA
    chmod +x "$ROOTFS/usr/local/bin/osmo-claude-anim"
    # Le fichier vit dans le depot (data/desktop/) ; Icon= en chemin absolu.
    install -m644 "$DIR/data/desktop/claude.desktop" "$ROOTFS/usr/share/applications/claude.desktop"
    sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/claude.svg|" \
        "$ROOTFS/usr/share/applications/claude.desktop"

    # Terminal=false : launch.sh ouvre LUI-MEME son terminal et demande les
    # privileges (pkexec). [2026-09-04] Plus de copie sur le bureau : les
    # raccourcis sont dans le menu et les favoris du dock.
    echo -e "  ${GREEN}✓${NC} menu/dock : ${CYAN}telephone${NC} (lancer) · ${CYAN}livre${NC} (tutoriel) · ${CYAN}supplements${NC} · ${CYAN}Claude${NC}"

    # Le paquet calamares pose SA propre entree de menu, qui lance
    # /usr/bin/calamares directement. Elle court-circuite osmo-install : ni le
    # medium remis a sa place, ni la cible d un essai precedent demontee - donc
    # exactement la panne qu on vient de corriger, a un clic de la bonne icone.
    # NoDisplay la retire des menus sans toucher au paquet.
    if [ -f "$ROOTFS/usr/share/applications/calamares.desktop" ]; then
        grep -q '^NoDisplay=' "$ROOTFS/usr/share/applications/calamares.desktop" \
            || echo 'NoDisplay=true' >> "$ROOTFS/usr/share/applications/calamares.desktop"
    fi

    echo -e "  ${GREEN}✓${NC} installeur ${CYAN}Calamares${NC} : /usr/local/bin/osmo-install (+ icone sur le bureau)"
elif [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo -e "  ${YELLOW}!${NC} $_CAL_SRC absent - pas d installeur dans cette image"
fi

# ── LE LANCEUR GTK "UPDATE" -> update.sh DU DEPOT ───────────────────────────
# Independant de Calamares : c'est une icone de bureau qui rejoue update.sh, le
# fichier SUIVI dans le depot osmo-operator (/opt/GSM/osmo-operator/update.sh).
# update.sh est une animation de TERMINAL : sa premiere ligne utile est
# "[ -t 1 ] || exit 0", donc lance sans tty (depuis une icone GTK) il sort
# aussitot sans rien montrer. Le lanceur l'ouvre DONC dans un emulateur de
# terminal - gnome-terminal est tire par ubuntu-desktop-minimal - et laisse la
# fenetre ouverte a la fin pour qu'on lise le resultat.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    cat > "$ROOTFS/usr/local/bin/osmo-update-anim" <<'UPDGUI'
#!/bin/bash
# Rejoue l animation update.sh du depot osmo-operator, dans une fenetre terminal.
set -u
SCRIPT=/opt/GSM/osmo-operator/update.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="update.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
# read a la fin : sans lui, la fenetre se fermerait avant qu on lise la ligne
# "SMS delivered". -e pour la plupart des emulateurs, "--" pour gnome-terminal.
CMD="\"$SCRIPT\"; echo; read -n1 -rsp 'Termine - une touche pour fermer...'"
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="osmo-operator update" -- bash -c "$CMD" ;;
        *)              exec "$term" -T "osmo-operator update" -e bash -c "$CMD" ;;
    esac
done
# Aucun emulateur : dernier recours, on joue directement (utile en tty).
exec "$SCRIPT"
UPDGUI
    chmod +x "$ROOTFS/usr/local/bin/osmo-update-anim"

    # Le fichier vit dans le depot (data/desktop/), pas en heredoc ici :
    # l install native (install_modules/80-bureau.sh) et le paquet .deb posent
    # le MEME.
    install -m644 "$DIR/data/desktop/osmo-update.desktop" "$ROOTFS/usr/share/applications/osmo-update.desktop"

    # [2026-09-04] Pas de copie sur le bureau (menu + favoris du dock).

    echo -e "  ${GREEN}✓${NC} lanceur GTK ${CYAN}update${NC} : /usr/local/bin/osmo-update-anim (+ icone sur le bureau)"
fi


# ── LE BUREAU, SUITE : FOND DU JOUR, SPECTRES, TERMINAL, DING ───────────────
# [2026-09-04] Tout ce bloc est HORS du chroot de 80-chroot.sh (quotes simples
# la-bas) : ici les heredocs et les apostrophes sont libres.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    # ── 1. Le fond d ecran du jour : strip Calvin & Hobbes incruste ──────────
    # tools/osmo-wallpaper.sh va chercher le strip du jour (gocomics, comme le
    # gist hellogist), recompose la photo + carte LAB GRGSM + strip
    # (tools/wallpaper-render.py) et pousse le resultat dans les sessions
    # ouvertes. Au boot (40 s, le reseau est la), chaque jour a 6h30, et
    # toutes les 4 h en rattrapage (banc hors ligne au boot).
    install -m755 "$DIR/tools/osmo-wallpaper.sh" "$ROOTFS/usr/local/sbin/osmo-wallpaper"
    # L arbre /opt/GSM/osmo-operator de l image vient du clone GitHub fait dans
    # Docker : on y pose aussi, depuis CE depot, ce que le fond et les spectres
    # utilisent - le build ne depend pas d un push pour ces fichiers-la.
    _rt="$ROOTFS/opt/GSM/osmo-operator"
    install -d "$_rt/tools" "$_rt/configs/wallpaper" "$_rt/configs/conky"
    install -m755 "$DIR/tools/wallpaper-render.py" "$DIR/tools/osmo-fft-snap.py" "$DIR/tools/osmo-panel.py" "$DIR/tools/osmo-wallpaper.sh" "$_rt/tools/"
    install -m644 "$DIR/configs/wallpaper/tower.jpg" "$_rt/configs/wallpaper/"
    install -m644 "$DIR/configs/conky/osmo-conky.conf" "$_rt/configs/conky/"
    install -m644 "$DIR/configs/gsm-lab-wallpaper.png" "$_rt/configs/gsm-lab-wallpaper.png"
    # 80-chroot.sh a copie le fond depuis le clone GitHub (avant ce module) :
    # on repose ici celui de CE depot, le rendu du jour de tools/wallpaper-render.py.
    install -m644 "$DIR/configs/gsm-lab-wallpaper.png" "$ROOTFS/usr/share/backgrounds/gsm-lab-wallpaper.png"
    unset _rt
    cat > "$ROOTFS/etc/systemd/system/osmo-wallpaper.service" <<'EOF'
[Unit]
Description=Fond d ecran du banc (strip Calvin & Hobbes du jour)
Wants=network-online.target
After=network-online.target
ConditionPathExists=/opt/GSM/osmo-operator/tools/wallpaper-render.py

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/osmo-wallpaper
TimeoutStartSec=180
EOF
    cat > "$ROOTFS/etc/systemd/system/osmo-wallpaper.timer" <<'EOF'
[Unit]
Description=Fond d ecran du banc : strip du jour (boot + quotidien)

[Timer]
OnBootSec=40s
OnCalendar=*-*-* 06:30:00
OnUnitActiveSec=4h
Persistent=true
Unit=osmo-wallpaper.service

[Install]
WantedBy=timers.target
EOF
    chroot "$ROOTFS" systemctl enable osmo-wallpaper.timer 2>/dev/null || true

    # ── 2. Les spectres I/Q dans le Conky du bas a droite ────────────────────
    # [2026-09-04] tools/osmo-fft-snap.py trace /run/osmo-fft/panel.png : le
    # cadre Calvin & Hobbes du fond (decoupe dans le PNG du jour) qui fond vers
    # « FFT du mobile + mobile.log » quand /psd a un flux ; osmo-panel.py (GTK,
    # fenetre de type bureau, cliquable : Dashboard, tmux, fleches operateur)
    # l affiche sur le cadre, a l echelle de l ecran. Il vit avec le dashboard et
    # affiche. Le service vit avec le dashboard et se relance sans lui : sans
    # flux, l image dit "pas de flux" au lieu de figer.
    cat > "$ROOTFS/etc/systemd/system/osmo-fft-snap.service" <<'EOF'
[Unit]
Description=Encart vivant du bureau : strip du jour qui fond vers FFT du mobile + mobile.log
After=osmo-egprs-web.service osmo-wallpaper.service
ConditionPathExists=/opt/GSM/osmo-operator/tools/osmo-fft-snap.py

[Service]
ExecStart=/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-fft-snap.py
RuntimeDirectory=osmo-fft
RuntimeDirectoryMode=0755
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    [ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-fft-snap 2>/dev/null || true

    # ── 3. Le terminal : legerement transparent, noir sur gris clair ─────────
    # Un profil gnome-terminal est un schema RELOCALISABLE : impossible par
    # gschema.override. C est donc une base dconf SYSTEME (/etc/dconf/db/local)
    # lue par toute session, root sur la cle comme l utilisateur Calamares sur
    # le disque, et que l utilisateur peut encore changer (base "user" devant).
    # Theme "Debian" : fond noir, texte gris clair, palette Tango (celle de
    # gnome-terminal), au lieu de l aubergine Ubuntu ; 18 % de transparence.
    install -d "$ROOTFS/etc/dconf/profile" "$ROOTFS/etc/dconf/db/local.d"
    printf 'user-db:user\nsystem-db:local\n' > "$ROOTFS/etc/dconf/profile/user"
    cat > "$ROOTFS/etc/dconf/db/local.d/10-osmo-terminal" <<'EOF'
[org/gnome/terminal/legacy/profiles:]
list=['b1dcc9dd-5262-4d8d-a863-c897e6d979b9']
default='b1dcc9dd-5262-4d8d-a863-c897e6d979b9'

[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
visible-name='osmo-operator'
use-theme-colors=false
use-theme-transparency=false
use-transparent-background=true
background-transparency-percent=18
background-color='#000000'
foreground-color='#D3D7CF'
bold-color-same-as-fg=true
palette=['#000000', '#CC0000', '#4E9A06', '#C4A000', '#3465A4', '#75507B', '#06989A', '#D3D7CF', '#555753', '#EF2929', '#8AE234', '#FCE94F', '#729FCF', '#AD7FA8', '#34E2E2', '#EEEEEC']
scrollback-unlimited=true
audible-bell=false
EOF
    chroot "$ROOTFS" dconf update 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} gnome-terminal : profil ${CYAN}osmo-operator${NC} (noir, 18 % transparent) via dconf systeme" \
        || echo -e "  ${YELLOW}!${NC} dconf update a echoue - profil terminal non compile"

    # ── 4. DING relance apres l ouverture de session ─────────────────────────
    # [2026-09-04] Mesure sur la cle : l extension "Desktop Icons NG" ouvre sa
    # fenetre plein ecran avant que GNOME Shell ait peint le fond, et garde
    # jusqu au bout l image du greeter (le numbat sombre d Ubuntu) par-dessus
    # notre fond - sans DING, le fond GSM apparait. La tuer une fois la session
    # ouverte suffit : l extension la relance en une seconde, proprement.
    cat > "$ROOTFS/etc/xdg/autostart/osmo-ding-refresh.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=osmo-operator : rafraichit les icones du bureau
Comment=Relance Desktop Icons NG une fois le fond d ecran peint
Exec=sh -c 'sleep 12; pkill -f "extensions/ding@rastersoft.com/app/ding.js" 2>/dev/null; exit 0'
Terminal=false
NoDisplay=true
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=12
EOF
    chmod 644 "$ROOTFS/etc/xdg/autostart/osmo-ding-refresh.desktop"
    echo -e "  ${GREEN}✓${NC} bureau : fond du jour (osmo-wallpaper.timer), spectres (osmo-fft-snap), DING relance a l ouverture"

    # ── 5. VLC DEPUIS UNE SESSION ROOT ───────────────────────────────────────
    # [2026-09-04] La session de la cle s ouvre sous root, et VLC refuse de
    # demarrer en root ("VLC is not supposed to be run as root") : l icone ne
    # faisait rien. On ne touche pas au binaire : le wrapper /usr/local/bin/vlc
    # (devant /usr/bin dans le PATH, vise par le .desktop local) relance VLC
    # sous le compte osmocom quand on est root - acces X par xhost (local
    # seulement), son par le demon PulseAudio systeme du banc (osmo-pulse,
    # groupe pulse-access). Un utilisateur normal passe tout droit.
    if [ -x "$ROOTFS/usr/bin/vlc" ]; then
        chroot "$ROOTFS" getent passwd osmocom >/dev/null 2>&1 \
            || chroot "$ROOTFS" useradd -m -s /bin/bash osmocom 2>/dev/null || true
        chroot "$ROOTFS" getent group pulse-access >/dev/null 2>&1 \
            && chroot "$ROOTFS" usermod -aG pulse-access,audio,video osmocom 2>/dev/null || true
        cat > "$ROOTFS/usr/local/bin/vlc" <<'VLCW'
#!/bin/bash
# vlc - wrapper osmo-operator : VLC refuse root, la session de la cle EST root.
# Root : on relance sous osmocom (X local par xhost, son par osmo-pulse).
VLC_USER="${OSMO_VLC_USER:-osmocom}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/var/run/pulse/native}"
if [ "$(id -u)" -eq 0 ] && id "$VLC_USER" >/dev/null 2>&1; then
    export DISPLAY="${DISPLAY:-:0}"
    xhost "+SI:localuser:$VLC_USER" >/dev/null 2>&1 || true
    exec runuser -u "$VLC_USER" -- env DISPLAY="$DISPLAY" PULSE_SERVER="$PULSE_SERVER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$VLC_USER")" HOME="$(getent passwd "$VLC_USER" | cut -d: -f6)" \
        /usr/bin/vlc "$@"
fi
exec /usr/bin/vlc "$@"
VLCW
        chmod 755 "$ROOTFS/usr/local/bin/vlc"
        # Le .desktop du paquet appelle /usr/bin/vlc en chemin absolu : copie
        # locale (prioritaire, apt ne l ecrase pas) qui passe par le wrapper.
        if [ -f "$ROOTFS/usr/share/applications/vlc.desktop" ]; then
            install -d "$ROOTFS/usr/local/share/applications"
            sed 's|^Exec=/usr/bin/vlc|Exec=/usr/local/bin/vlc|; s|^Exec=vlc |Exec=/usr/local/bin/vlc |' \
                "$ROOTFS/usr/share/applications/vlc.desktop" > "$ROOTFS/usr/local/share/applications/vlc.desktop"
        fi
        echo -e "  ${GREEN}✓${NC} vlc : wrapper ${CYAN}/usr/local/bin/vlc${NC} (root -> osmocom, .desktop redirige)"
    else
        echo -e "  ${YELLOW}!${NC} vlc absent du rootfs - pas de wrapper"
    fi
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
