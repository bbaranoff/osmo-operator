#!/bin/bash
# iso_modules/70-scripts.sh - etape 7/7b : scripts projet, WAN, NetworkManager
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
# osmo-op : quel operateur l encart et le Conky regardent (les fleches, en
# ligne de commande). C est aussi ce qu appelle le raccourci clavier pose par
# iso_modules/80-chroot.sh - Ctrl+Alt+O / Ctrl+Alt+Maj+O.
ln -sf /opt/GSM/osmo-operator/tools/osmo-op.sh "$ROOTFS/usr/local/bin/osmo-op" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/tools/osmo-drivers.sh "$ROOTFS/usr/local/bin/osmo-drivers" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/tools/overlay-draw.py "$ROOTFS/usr/local/bin/overlay-draw" 2>/dev/null || true
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

# ── FIREFOX : PLUS RIEN A FAIRE ICI ────────────────────────────────────────
# [2026-09-04] Ce module posait /usr/local/sbin/osmo-firefox-snap et son unite
# de premier demarrage : une centaine de lignes pour installer Firefox par snap,
# hors ligne depuis /var/lib/osmo-snaps puis depuis le magasin. Le navigateur
# vient desormais du .deb de Mozilla, installe dans le chroot par
# 80-chroot.sh - donc PRESENT DANS L IMAGE, et tenu a jour par apt sur le
# systeme installe.
#
# Ce que le snap coutait, et pourquoi on ne le regrette pas : l unite restait en
# "activating" des minutes au premier boot (1,5 Go a deballer, snapd qui refuse
# tant qu un changement est en cours), et quand elle echouait - medium lent, pas
# de reseau - le banc demarrait SANS navigateur, donc sans tableau de bord. Le
# bac a sable, lui, refusait le socket PulseAudio et les file:// hors /home, ce
# qui a coute deux enquetes entieres (micro muet, tutoriel "introuvable").
# Le .deb n a ni bac a sable, ni service d installation, ni delai au boot.


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
