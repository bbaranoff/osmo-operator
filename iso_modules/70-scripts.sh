#!/bin/bash
# iso_modules/70-scripts.sh - etape 7/7b : scripts projet, WAN, firefox-snap
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 7 : Injection des scripts projet et installation du lanceur start-direct.sh ──
echo -e "${GREEN}[7/9] Scripts projet et adaptation ISO...${NC}"
# ── UN SEUL ARBRE DU DEPOT : /opt/GSM/osmo-operator ────────────────────────────
# Ici vivait la fabrication d'un SECOND arbre, /opt/GSM/osmo-operator : une copie
# PARTIELLE du depot (une liste de fichiers nommes un a un, plus sept
# repertoires), sans .git, figee a la construction. L'ISO partait donc avec
# deux osmo-operator :
#
#   /opt/GSM/osmo-operator   l'arbre COMPLET, avec son .git, mis a jour a
#                         l'etape [5a/9] et par "osmo-update" ensuite ;
#   /opt/GSM/osmo-operator       une copie partielle que plus rien ne mettait a jour.
#
# Et c'est le second que visaient les liens osmo-start-direct / osmo-start-lab,
# le message de login, l'alias osmo-lab et l'unite du hub SS7. Autrement dit :
# on mettait a jour un arbre, on en executait un autre. Tout ce qui a ete ajoute
# au depot depuis la derniere construction - un module, un script network/, une
# option - existait sur la machine et restait sans effet, parce que le lanceur
# lance n'etait pas celui qu'on venait de corriger.
#
# Le filet que la copie apportait - "un lanceur present meme sans reseau" - est
# conserve, mais AU MEME ENDROIT : si l'arbre complet n'a pas pu etre recupere,
# on le remplit depuis le depot de construction, et il n'y a toujours qu'un
# seul chemin.
P="$ROOTFS/opt/GSM/osmo-operator"
if [ ! -x "$P/start-direct.sh" ]; then
    echo -e "  ${YELLOW}!${NC} /opt/GSM/osmo-operator sans lanceur (image perimee, clone impossible)"
    echo -e "    -> remplissage depuis le depot de construction ${CYAN}${DIR}${NC}"
    mkdir -p "$P"
    # --exclude .git : on ne fabrique pas un faux depot. S'il en manquait un,
    # c'est que le reseau a manque ; osmo-update le reconstituera.
    tar -C "$DIR" --exclude=.git --exclude='*.iso' -cf - . | tar -C "$P" -xf -
    find "$P" -name "*.sh" -exec chmod +x {} \;
fi
if [ ! -x "$P/start-direct.sh" ]; then
    echo -e "  ${RED}✗${NC} start-direct.sh introuvable - l'ISO n'aura pas de lanceur" >&2
    exit 1
fi
ln -sf /opt/GSM/osmo-operator/start-direct.sh "$ROOTFS/usr/local/bin/osmo-start-direct" 2>/dev/null || true
# (osmo-start-lab -> start.sh retire le 2026-09-02 : start.sh est le lanceur
#  Docker, et cette image n a pas Docker.)
if [ -f "$DIR/launch/osmo-launch.sh" ]; then
    cp "$DIR/launch/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
    ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"
fi
echo -e "  ${GREEN}✓${NC} lanceurs -> ${CYAN}/opt/GSM/osmo-operator${NC} (arbre unique, avec .git)"

# ── WAN : table des noeuds figee dans l'image ────────────────────────────────
if [ "$ISO_WAN" = "1" ]; then
    echo -e "${GREEN}[7b/9] WAN - table des noeuds embarquee...${NC}"
    # shellcheck source=network/wan-nodes.sh
    . "$DIR/network/wan-nodes.sh"
    WAN_OPS="$ISO_WAN_OPS"
    if [ -n "$ISO_WAN_NODES" ]; then
        wan_nodes_parse "$ISO_WAN_NODES" || exit 1
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
    else
        # Construction interactive : memes questions que ./start.sh --wan.
        # Le numero du noeud demande ici n'est qu'un defaut : chaque machine
        # qui demarre l'ISO se re-reconnait a son IP.
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
        wan_nodes_prompt || exit 1
    fi
    wan_nodes_validate || exit 1
    WAN_AUTO=1 WAN_CONF_FILE="$ROOTFS/etc/osmo-wan.conf" wan_nodes_save
    wan_nodes_summary
    echo -e "  ${GREEN}✓${NC} /etc/osmo-wan.conf fige dans l'ISO (WAN_AUTO=1)"
    echo -e "  ${CYAN}Au boot :${NC} start-direct.sh applique le WAN tout seul ;"
    echo -e "  ${CYAN}sans --wan a la construction, l'ISO n'a AUCUN WAN.${NC}"
else
    echo -e "  ${CYAN}[7b/9] WAN non embarque (--wan absent) - ISO autonome${NC}"
fi

# ── Etape 8 : (SUPPRIME) - ISO NATIF, plus de Docker au runtime ───────────
# L'ancien load-osmocom-image.service chargeait osmocom-run.tar.gz via 'docker
# load' au boot ; son ExecStartPre 'while ! docker info' bloquait indefiniment la
# file systemd en natif (docker jamais up) → boot fige. Le lab tourne desormais
# en natif (start-direct.sh) : pas d'image Docker a charger, pas de ce service.

# ── Etape 9 : Configuration chroot (paquets) ───────────────────────────────
# ── Ce que le chroot ne peut pas ecrire lui-meme ────────────────────────────
# Le script du chroot est passe a "bash -c" en QUOTES SIMPLES : rien n'y est
# substitue a l'ecriture, ce qui est voulu, mais une seule apostrophe dans le
# corps referme la chaine et tout ce qui suit change de sens. Les fichiers qui
# en contiennent - un heredoc quote, une commande shell imbriquee - s'ecrivent
# donc ICI, dans le rootfs, ou le quoting est normal. Le chroot ne fait plus que
# les activer.

# NetworkManager pilote le bureau ; ce qui appartient au coeur paquet ne lui
# appartient pas. Sans cette regle, NM reprend apn0 ou un tun du GGSN et coupe
# la session de donnees d'un abonne parce qu'il l'a jugee "non configuree".
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-osmo-networkd.conf" <<'NMCONF'
# Ecrit par build-iso.sh. NetworkManager gere les cartes physiques et le
# bureau ; les interfaces du coeur paquet restent a systemd-networkd et aux
# scripts du banc.
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:apn*;interface-name:tun*;interface-name:veth*;interface-name:docker*;interface-name:br-*;interface-name:osmo*
NMCONF

# Firefox : installe au PREMIER DEMARRAGE, depuis les .snap embarques quand ils
# sont la, depuis le magasin sinon. Voir la variante desktop du chroot.
#
# FIREFOX. [2026-08-30] Ce bloc disait "CHROMIUM ET PAS FIREFOX, et ce n'est pas
# une preference", au motif que "Firefox ne capte pas le micro et Chrome oui".
# Le motif etait REEL mais mal attribue : Firefox ne captait rien parce que le
# snap ne pouvait pas se CONNECTER a PulseAudio du tout, ni en entree ni en
# sortie. Le journal du noyau le dit :
#     apparmor="DENIED" operation="connect" profile="snap.firefox.firefox"
#     name="/run/pulse/native" fsuid=0 ouid=107
# Le profil autorise pourtant ce chemin -- mais avec le qualificateur `owner`,
# qui exige proprietaire == fsuid. Le socket appartenait a `pulse` (107), la
# session tourne en root (0). Le commentaire d'origine creditait deja
# osmo-pulse-link.sh d'avoir corrige "la cause de fond" : il n'en avait corrige
# que la moitie (le CHEMIN, par un lien symbolique -- alors qu'AppArmor resout
# le chemin reel et que le vrai manque etait le PROPRIETAIRE).
# Le chown est pose la-bas ; le son et le micro marchent dans Firefox, et la
# raison de preferer Chromium tombe avec.
#
# Les deux ne sont de toute facon disponibles qu'en snap sur jammy : les .deb
# "firefox" et "chromium-browser" sont des paquets de TRANSITION qui appellent
# snapd. Firefox declare la MEME base (core24) et les MEMES fournisseurs de
# contenu (mesa-2404, gtk-common-themes, gnome-46-2404) que chromium : la
# mecanique ci-dessous ne change pas, seul le nom du snap change.
# [2026-09-02] TROIS DEFAUTS QUI FAISAIENT QU IL FALLAIT INSTALLER FIREFOX A LA
# MAIN, A CHAQUE IMAGE :
#
#   1. TOUTE LA LOGIQUE VIVAIT DANS LE ExecStart= de l unite - vingt lignes de
#      shell continuees par des "\" dans un fichier .ini. Rien n etait
#      testable : pas moyen de la lancer a la main pour voir ce qui cloche,
#      pas moyen de la relancer apres coup, et la moindre retouche se faisait
#      a l aveugle sur du shell echappe deux fois. Elle vit desormais dans un
#      VRAI script, /usr/local/sbin/osmo-firefox-snap, que l unite se contente
#      d appeler et que l on peut lancer soi-meme :
#          sudo osmo-firefox-snap
#
#   2. "After=network-online.target" SANS "Wants=" NE FAIT RIEN. network-online
#      n est pas tiree par defaut : personne ne la demandait, donc elle n etait
#      jamais atteinte, donc le After= n ordonnait rien. Le repli magasin
#      partait DNS mort - exactement le "Temporary failure in name resolution"
#      releve au boot precedent. Le Wants= manquant est ajoute.
#
#   3. "cd /var/lib/osmo-snaps || exit 0" ABANDONNAIT EN SILENCE. Sur une image
#      ou les .snap n ont pas pu etre pre-telecharges (pas de reseau au build,
#      ou build non-desktop), le repertoire n existe pas : l unite sortait
#      avec un beau code 0 sans avoir rien tente, pas meme l installation
#      depuis le magasin. Le repertoire manquant n interdit plus le repli.
#
# Le script est pose MEME hors ISO_DESKTOP : update.sh s en sert pour rattraper
# les machines deja installees, ou l unite n a jamais existe.
install -d "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/osmo-firefox-snap" <<'FFSNAP'
#!/bin/bash
# osmo-firefox-snap - pose Firefox par snap. Ecrit par build-iso.sh.
#
# Hors ligne d abord (les .snap embarques dans /var/lib/osmo-snaps par le
# build), le magasin ensuite : un banc sans Internet doit quand meme avoir son
# navigateur, et un banc sans .snap embarques doit quand meme pouvoir aller les
# chercher.
#
# Appele par osmo-firefox-snap.service au demarrage, par update.sh, et a la
# main. Idempotent : si firefox est deja la, il ne fait que reconnecter les
# interfaces et sort.
set -u
SNAPDIR=/var/lib/osmo-snaps
LOG=/var/log/osmo-firefox-snap.log

[ "$(id -u)" -eq 0 ] || { echo "root requis : sudo $0" >&2; exit 1; }

# Lance a la main, on veut voir ce qui se passe ; lance par systemd, tout va
# dans le journal du fichier. Dans les deux cas le log garde une trace.
if [ -t 1 ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
echo "=== $(date -Is) osmo-firefox-snap ==="

# [2026-09-04] Firefox est le .deb de Mozilla (packages.mozilla.org) depuis
# cette date : l ISO ne l installe plus par snap. Ce script ne sert plus qu aux
# machines installees avant, et il se retire si le deb est la.
if dpkg-query -W -f='${Maintainer}' firefox 2>/dev/null | grep -qi mozilla; then
    echo "firefox est le deb Mozilla ($(dpkg-query -W -f='${Version}' firefox)) - rien a faire"
    exit 0
fi
command -v snap >/dev/null 2>&1 || { echo "snapd absent - rien a faire"; exit 1; }

# snapd refuse tout tant qu un changement est en cours :
#     error: snap "core24" has "install-snap" change in progress
# C est ce qui perdait les six installations d affilee au premier boot. On
# attend que la file se vide avant chaque tentative.
settle() {
    local i
    for i in $(seq 1 180); do
        snap changes 2>/dev/null | grep -qE '^[0-9]+ +(Do|Doing|Undoing) ' || return 0
        sleep 5
    done
    echo "ATTENTION: file de changements snapd encore pleine"
    return 1
}

connecter() {
    # Les interfaces de contenu decident si le navigateur DEMARRE, pas
    # seulement s il est joli : firefox passe par gpu-2404 et gnome-46-2404 via
    # sa command-chain. audio-record n est jamais connectee d office : sans
    # elle, getUserMedia rend NotFoundError sans qu une ligne ne parle de
    # confinement.
    local i
    for i in gpu-2404 gnome-46-2404 gtk-3-themes icon-themes sound-themes \
             audio-record audio-playback camera removable-media; do
        snap connect "firefox:$i" 2>/dev/null || true
    done
}

if snap list firefox >/dev/null 2>&1; then
    echo "firefox deja installe"
    connecter
    touch "$SNAPDIR/.installe" 2>/dev/null || true
    exit 0
fi

snap wait system seed.loaded || true
settle

# ── 1. Hors ligne : les .snap embarques ─────────────────────────────────────
# L ORDRE COMPTE. Un snap ne s installe pas avant sa base : "snap install
# firefox.snap" sans core24 sort sur
#     cannot install snap "firefox": snap "core24" is required
# Le fichier "ordre", ecrit au build, porte la sequence exacte.
if [ -d "$SNAPDIR" ]; then
    cd "$SNAPDIR" || exit 1
    for a in *.assert; do [ -e "$a" ] && snap ack "$a"; done
    if [ -s ordre ]; then
        while read -r sn; do
            [ -n "$sn" ] || continue
            [ -s "$sn.snap" ] || { echo "absent: $sn.snap"; continue; }
            snap list "$sn" >/dev/null 2>&1 && { echo "deja installe: $sn"; continue; }
            for t in 1 2 3; do
                snap install "$sn.snap" && break
                echo "tentative $t echouee: $sn"; settle; sleep 5
            done
        done < ordre
    else
        echo "pas de fichier ordre dans $SNAPDIR"
    fi
else
    echo "$SNAPDIR absent - rien d embarque, on passe au magasin"
fi

# ── 2. Le magasin, si le hors-ligne n a pas suffi ───────────────────────────
if ! snap list firefox >/dev/null 2>&1; then
    settle
    echo "installation depuis le magasin..."
    snap install firefox || true
fi

connecter
snap list

# LE DRAPEAU NE SE POSE QU EN CAS DE SUCCES. Il etait pose inconditionnellement
# en fin de ligne, meme apres six echecs : combine au ConditionPathExists de
# l unite, il interdisait DEFINITIVEMENT toute nouvelle tentative, et l image
# restait sans Firefox pour toujours.
if snap list firefox >/dev/null 2>&1; then
    install -d "$SNAPDIR"; touch "$SNAPDIR/.installe"
    echo "OK: firefox installe, drapeau pose"
    exit 0
fi
echo "ECHEC: firefox absent - drapeau NON pose, nouvelle tentative au prochain boot"
exit 1
FFSNAP
chmod 755 "$ROOTFS/usr/local/sbin/osmo-firefox-snap"
echo -e "  ${GREEN}✓${NC} /usr/local/sbin/osmo-firefox-snap (installable a la main)"

if [ "$ISO_DESKTOP" = "1" ]; then
cat > "$ROOTFS/etc/systemd/system/osmo-firefox-snap.service" <<'CRSNAP'
[Unit]
Description=Installation de Firefox (snap) au premier demarrage
# snapd.seeded : snapd a fini de deballer ce que l'image portait deja. Partir
# avant, c'est installer par-dessus une graine encore en cours de montage.
# network-online : le Wants= est INDISPENSABLE - sans lui la cible n'est jamais
# tiree, le After= n'ordonne rien, et le repli magasin part DNS mort.
After=snapd.seeded.service network-online.target
Wants=snapd.seeded.service network-online.target
ConditionPathExists=!/var/lib/osmo-snaps/.installe

[Service]
Type=oneshot
RemainAfterExit=yes
# Poser ~1 Go de snaps prend des MINUTES sur un medium optique ou une cle lente.
# Le delai par defaut de systemd (90 s) tuait l'unite en pleine installation, et
# ne laissait derriere lui qu'un "firefox introuvable" sans rapport apparent.
TimeoutStartSec=infinity
# Toute la logique est dans le script : lancable a la main pour voir ce qui
# cloche (sudo osmo-firefox-snap), journalisee dans
# /var/log/osmo-firefox-snap.log.
ExecStart=/usr/local/sbin/osmo-firefox-snap

[Install]
WantedBy=multi-user.target
CRSNAP
echo -e "  ${GREEN}✓${NC} osmo-firefox-snap.service (Firefox par snap, au premier boot)"
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
