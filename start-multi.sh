#!/bin/bash
# =============================================================================
# start-multi.sh - LE BANC MULTI-OPERATEUR : natif + docker, relies en SS7
#
#   op 1  NATIF   deja en place (start-direct.sh)   PC 1.1.2
#   op 2  DOCKER  conteneur                          PC 1.2.2   172.20.0.12
#   op 3  DOCKER  conteneur                          PC 1.3.2   172.20.0.13
#   hub   DOCKER  inter-STP                          PC 0.0.0   172.20.0.10
#                                                    M3UA/SCTP 2908
#
# CE SCRIPT NE REIMPLEMENTE RIEN. start.sh sait deja lancer des operateurs en
# conteneur, poser le hub (--hub-ip) et DECLARER un operateur sans lui lancer de
# conteneur (--operator IP:PREFIXE) - ce dernier point est exactement le cas du
# natif, qui tourne deja et qu on veut seulement raccorder. Refaire ce travail
# ici donnerait une seconde formule a maintenir, et le depot montre deja ou cela
# mene : start.sh et lib/gabarits.sh portent les MEMES fonctions en double.
# start-multi.sh se contente donc de trois choses : verifier, traduire la
# topologie en options, et deleguer.
#
# LA TOPOLOGIE VIENT DE addition.sh, pas d ici : /etc/osmocom/osmo-multi.conf.
# Un seul endroit la calcule.
#
# Usage :
#   sudo ./start-multi.sh              monte le banc multi-operateur
#   sudo ./start-multi.sh --status     etat des conteneurs et du hub
#   sudo ./start-multi.sh --stop       arrete les conteneurs (le natif reste)
#   sudo ./start-multi.sh --dry-run    affiche la commande sans la lancer
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
ACTION="start"
for a in "$@"; do
    case "$a" in
        --status)  ACTION="status" ;;
        --stop)    ACTION="stop" ;;
        --dry-run) ACTION="dry" ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    esac
done

# ── LANCE PAR UNE ICONE : TERMINAL ET PRIVILEGES ────────────────────────────
# [2026-08-31] Sans ce preambule, l antenne bleue du bureau ne faisait RIEN de
# visible. Le .desktop est en Terminal=false ; le script exigeait root et
# ecrivait son refus sur stdout, c est-a-dire nulle part. Un double-clic
# lancait donc bien le script, qui sortait aussitot sur "Root requis" sans une
# fenetre ni un message : l icone paraissait morte, alors qu elle marchait.
# launch.sh avait deja ce traitement ; celui-ci ne l avait pas.
#
# On teste la presence d un TTY, pas $DISPLAY : c est la difference reelle
# entre "lance a la main" et "lance par une icone".
# ⚠️ SEULEMENT pour le LANCEMENT. --status, --dry-run et --help sont des
# lectures : les rejouer dans un terminal graphique ouvrirait une fenetre a
# chaque appel depuis un script ou un pipe - et leur sortie n irait pas a
# l appelant, qui n obtiendrait RIEN. Constate en les testant d ici.
_multi_readonly=0
case " $* " in
    *" --status "*|*" --dry-run "*|*" -h "*|*" --help "*) _multi_readonly=1 ;;
esac

# [2026-08-31] stdin ET stdout : `[ ! -t 0 ]` seul prenait un
# `./start-multi.sh < fichier` lance depuis un vrai terminal pour un
# double-clic, et ouvrait une fenetre dont la sortie n allait pas a l appelant.
_multi_besoin=0
if [ "$_multi_readonly" = "0" ]; then
    { [ ! -t 0 ] || [ ! -t 1 ]; } && _multi_besoin=1
fi
if [ "$_multi_besoin" = "1" ] && [ "${OSMO_MULTI_TERM:-0}" != "1" ]; then
    export OSMO_MULTI_TERM=1
    for _t in gnome-terminal xfce4-terminal konsole xterm; do
        command -v "$_t" >/dev/null 2>&1 || continue
        case "$_t" in
            gnome-terminal) exec "$_t" --title="osmo-operator multi-operateur" -- "$0" "$@" ;;
            *)              exec "$_t" -T "osmo-operator multi-operateur" -e "$0" "$@" ;;
        esac
    done
fi

# Le drapeau ne sert qu a ne pas boucler sur la relance. On le RETIRE de
# l environnement : exporte, il descendait dans start.sh, dans le raccourci du
# natif et jusqu a launch.sh, ou il n a aucun sens. La valeur reste ici, dans
# une variable de shell : c est elle qui decide de retenir la fenetre a la fin.
_multi_own_window=0
[ "${OSMO_MULTI_TERM:-0}" = "1" ] && _multi_own_window=1
unset OSMO_MULTI_TERM

# Meme raison pour root : une lecture n a pas a demander de mot de passe.
if [ "$_multi_readonly" = "0" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
                exec pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
                     OSMO_MULTI_TERM="$_multi_own_window" "$0" "$@"
            fi
            command -v sudo >/dev/null 2>&1 && exec sudo -E "$0" "$@"
        fi
fi

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - banc MULTI-OPERATEUR (SS7)         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── PREFLIGHT ───────────────────────────────────────────────────────────────
# Docker N EST PAS dans l ISO (voir addition.sh) : son absence est le cas
# NORMAL au premier lancement, pas une panne. On le dit comme tel, et on
# renvoie vers le supplement plutot que de laisser docker repondre
# "command not found" - message qui n indique nulle part quoi faire.
manque() {
    echo -e "  ${RED}✗ $1${NC}"
    echo -e "    ${CYAN}→ sudo ${DIR}/addition.sh${NC}  (ou l icone ${BOLD}Supplements${NC} du bureau)"
    exit 1
}
command -v docker >/dev/null 2>&1 || manque "docker n est pas installe"
docker info >/dev/null 2>&1        || manque "le demon docker ne repond pas"

if [ ! -f "$MULTI_CONF" ]; then
    manque "topologie absente : $MULTI_CONF"
fi
# shellcheck disable=SC1090
. "$MULTI_CONF"

: "${MULTI_HUB_IP:=172.20.0.10}"
: "${MULTI_M3UA_PORT:=2908}"
: "${MULTI_OPS:=}"
: "${MULTI_IMAGE:=osmocom-run}"

# ── LIRE LE NATIF PLUTOT QUE LE SUPPOSER ────────────────────────────────────
# [2026-08-31] La topologie ecrite par addition.sh dit ce qu on ATTEND du
# natif ; ces deux fonctions disent ce qu il EST. Les confondre a coute cher :
# on affichait "op natif actif" sur la seule presence d un processus, sans voir
# qu il portait le point code d un conteneur.
#
# Le point code depend du plan choisi, et les deux existent :
#   plan LOCAL (set-node-id.sh --local) : 1.<op>.<role>        - une machine
#   plan WAN   (defaut)                 : 1.<noeud><op>.<role> - plusieurs
# Sur un banc a une machine c est le plan local qui vaut, mais rien n empeche
# la config d avoir ete posee autrement : on LIT, on ne recalcule pas.
natif_pc() {
    awk '/^[[:space:]]*point-code[[:space:]]/{print $2; exit}' \
        /etc/osmocom/osmo-stp.cfg 2>/dev/null
}

# L adresse par laquelle le natif sort vers le hub : le local-ip de son ASP
# asp-to-inter. C est elle qui doit exister sur l hote - un local-ip inbindable
# est un ASP qui ne monte jamais, sans message clair (cf. le 172.20.0.11 des
# gabarits, corrige dans generate_configs.sh).
natif_asp_ip() {
    local ip
    ip="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{a=1; next}
               a && /^[[:space:]]*local-ip[[:space:]]/{print $2; exit}' \
          /etc/osmocom/osmo-stp.cfg 2>/dev/null)"
    [ -n "$ip" ] || return 0
    # [2026-08-31] ON VERIFIE QUE L ADRESSE EXISTE ICI.
    # Cette colonne affichait bêtement ce que disait la config, et la config
    # portait 172.20.0.11 - l adresse du PREMIER CONTENEUR, remise par les
    # gabarits a chaque demarrage du natif. On lisait donc "op 1 native
    # 172.20.0.11", ce qui est impossible : le natif tourne sur l hote.
    # Une adresse absente de la machine est un ASP qui ne montera jamais ; on le
    # DIT dans la colonne plutot que de laisser croire a une topologie saine.
    if ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
         | grep -qx "$ip"; then
        printf '%s\n' "$ip"
    else
        printf '%s(absente!)\n' "$ip"
    fi
}

# ── UN PROCESSUS DE L HOTE, PAS CELUI D UN CONTENEUR ────────────────────────
# [2026-08-31] `pgrep -x osmo-bsc` et `pgrep -f 'osmo-bsc|asterisk'` repondaient
# OUI des qu un CONTENEUR tournait : l hote voit TOUS les processus, y compris
# les leurs (mesure : osmo-bsc pid 140689 et asterisk pid 140878, enfants du
# systemd de osmo-operator-2, listes par le `ps` de l hote). Le natif etait donc
# confondu avec n importe quelle pile du banc. Deux consequences, vues toutes
# les deux :
#   - etat() affichait « op 1 native actif » sans rien de natif en marche ;
#   - lancer_natif_si_absent() sortait aussitot et NE LANCAIT JAMAIS le natif
#     des qu un conteneur tournait deja - precisement le cas d un start-multi
#     relance, celui ou on en a le plus besoin.
# Le discriminant est le NAMESPACE PID : un conteneur a le sien, l hote garde
# celui de son init. Plus sur que le cgroup, qui depend de --cgroupns.
#
# `pgrep -x` ET NON `pgrep -f` : on compare le NOM du processus, pas sa ligne de
# commande. `-f 'osmo-bsc|asterisk'` repondait OUI sur n importe quelle ligne
# CITANT ces mots - le `tail -F /var/log/osmocom/osmo-bsc.log` que le natif
# ouvre lui-meme, un editeur, ou le shell appelant. Un nom exact ne peut pas
# mentir de cette facon, et rend inutile l exclusion de notre propre PID.
_ns_hote="$(readlink /proc/1/ns/pid 2>/dev/null)"
_est_natif() {          # $@ = noms EXACTS ; vrai si l un tourne hors conteneur
    local n p
    for n in "$@"; do
        for p in $(pgrep -x "$n" 2>/dev/null); do
            [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$_ns_hote" ] && return 0
        done
    done
    return 1
}

# ── ETAT ────────────────────────────────────────────────────────────────────
etat() {
    local spec idx mode ip pc _r
    echo -e "  ${BOLD}Topologie${NC} ($MULTI_CONF)"
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip pc _rctx <<< "$spec"
        if [ "$mode" = "native" ]; then ip="$(natif_asp_ip)"; fi
        printf '    op %-2s %-7s %-13s PC %-8s ' "$idx" "$mode" "${ip:-(hote)}" "$pc"
        if [ "$mode" = "native" ]; then
            if _est_natif osmo-bsc asterisk \
               || systemctl is-active --quiet asterisk 2>/dev/null; then
                _r="$(natif_pc)"
                if [ -n "$_r" ] && [ "$_r" != "$pc" ]; then
                    echo -e "${GREEN}actif${NC} ${YELLOW}(PC reel ${_r})${NC}"
                else
                    echo -e "${GREEN}actif${NC}"
                fi
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        else
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "osmo-operator-${idx}"; then
                echo -e "${GREEN}actif${NC}"
            else
                echo -e "${YELLOW}arrete${NC}"
            fi
        fi
    done
    printf '    hub  %-7s %-13s PC %-8s ' "docker" "$MULTI_HUB_IP" "${MULTI_HUB_PC:-0.0.0}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${MULTI_HUB_NAME:-osmo-inter-stp}"; then
        echo -e "${GREEN}actif${NC}"
    else
        echo -e "${YELLOW}arrete${NC}"
    fi
}

case "$ACTION" in
  status) etat; exit 0 ;;
  stop)
        for spec in $MULTI_OPS; do
            IFS=: read -r idx mode _ <<< "$spec"
            [ "$mode" = "docker" ] || continue
            docker rm -f "osmo-operator-${idx}" >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓${NC} osmo-operator-${idx} arrete"
        done
        docker rm -f "${MULTI_HUB_NAME:-osmo-inter-stp}" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} hub arrete"
        echo -e "  ${CYAN}i${NC} l operateur NATIF n est pas touche - ${BOLD}sudo ${DIR}/start-direct.sh stop${NC} pour lui."
        exit 0 ;;
esac

# ── L IMAGE ─────────────────────────────────────────────────────────────────
# NOM DE L IMAGE : osmocom-run, PAS "osmo-operator".
# build.sh produit osmocom-nitb (Dockerfile, ~11 Go) puis Dockerfile.run en
# derive osmocom-run, et c est CELLE-LA que start.sh lance - verifie sur le
# banc : `docker inspect osmo-operator-1 --format {{.Config.Image}}` rend
# osmocom-run. Chercher "osmo-operator" (le nom du DEPOT, pas de l image)
# rendait la sonde toujours negative : "image absente" en permanence, et une
# recompilation Osmocom de 40 minutes relancee pour rien a chaque passage.
# [2026-09-02] SI SEULE LA BASE EST LA, ON DERIVE ICI. addition.sh peut
# desormais TELECHARGER osmocom-nitb (docker pull bastienbaranoff/norf_gsm)
# au lieu de la compiler ; osmocom-run en decoule par Dockerfile.run en
# quelques secondes. Refuser de demarrer pour ca et renvoyer vers addition.sh
# - qui aurait repondu "image deja presente" - etait une boucle sans issue.
if ! docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
    if docker image inspect osmocom-nitb >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} image '$MULTI_IMAGE' absente, base osmocom-nitb presente : derivation (Dockerfile.run)"
        ( cd "$DIR" && docker build --build-arg QEMU_CACHE_BUST=$(date +%s) \
                           -f Dockerfile.run -t "$MULTI_IMAGE" . ) \
            || manque "derivation de l image '$MULTI_IMAGE' echouee"
    else
        manque "image '$MULTI_IMAGE' absente"
    fi
fi

# ── LE RACCORD DU NATIF AU HUB ──────────────────────────────────────────────
# [2026-08-31] RESOLU, dans start.sh, au lancement du hub.
# /etc/osmocom/osmo-stp.cfg (natif) declare
#       asp asp-to-inter 2908 2910 m3ua
#        remote-ip 127.0.0.1
# et rien n ecoutait sur 127.0.0.1:2908 : le hub vit dans le conteneur et ne
# publiait aucun port. Le hub publie desormais 2908 en SCTP sur la boucle
# locale (docker run -p 127.0.0.1:2908:2908/sctp), ce qui rend le remote-ip du
# natif exact sans toucher a une seule config regeneree.
# Verifie sur le banc : docker port -> "2908/sctp -> 127.0.0.1:2908",
# ss -an -> "sctp LISTEN 127.0.0.1:2908", docker-proxy -proto sctp actif.
#
# L autre voie - repointer l ASP natif sur 172.20.0.10 / local-ip 172.20.0.1 -
# a ete ecartee : ces deux adresses n existent que tant que le bridge docker
# est monte, et disparaissent avec les conteneurs.
#
# Le second defaut du meme bloc, lui, etait dans la config : local-ip valait
# 172.20.0.11, l adresse du PREMIER CONTENEUR, inbindable sur l hote. Corrige
# dans generate_configs.sh (apply_native_post_patches), qui ne couvrait pas
# osmo-stp.cfg.

# ── COMBIEN DE CONTENEURS ───────────────────────────────────────────────────
# Ceux marques "docker" dans la table, pas un compte fige : la topologie est
# la seule source.
N_DOCKER=0
for spec in $MULTI_OPS; do
    IFS=: read -r idx mode _ <<< "$spec"
    [ "$mode" = "docker" ] && N_DOCKER=$((N_DOCKER + 1))
done
[ "$N_DOCKER" -ge 1 ] || { echo -e "  ${RED}✗ aucun operateur docker dans la topologie${NC}"; exit 1; }

# OPERATOR_COUNT_HINT : start.sh l utilise pour NE PAS reposer la question du
# nombre de conteneurs (voir start_bridge_mode). Sans elle, le script s arrete
# sur une boite de dialogue - fatal pour un lancement par icone.
# [2026-08-31] PAS DE --wan ICI, ET C EST LE POINT IMPORTANT.
# La premiere version passait --wan --wan-id --hub-ip --operator. Resultat
# mesure : le check de fin cherchait le hub en 192.168.1.49 et l operateur
# portait le point code 1.23.2, alors que la topologie dit 172.20.0.10 et
# 1.2.2. --wan est la machinerie MULTI-MACHINE : il lit/ecrit
# /etc/osmo-wan.conf (qui n existe meme pas ici), renumerote les point codes en
# 1.<noeud><op>.<role> et attend un hub a une adresse routable entre machines.
# Sur UNE machine, c est l inverse qu on veut - et c est deja le defaut :
# checks/wan_ss7_check.sh le dit noir sur blanc, "sans WAN l ASP de chaque
# operateur pointe sur 172.20.0.10", le hub local, avec un catch-all
# "route 0.0.0 0.0.0 → as-inter". Il n y a donc rien a demander a start.sh
# au-dela du nombre de conteneurs.
#
# OPERATOR_COUNT_HINT : start.sh l utilise pour NE PAS reposer la question du
# nombre de conteneurs (voir start_bridge_mode). Sans elle, le script s arrete
# sur une boite de dialogue - fatal pour un lancement par icone.
# OSMO_QUICK=1 : reutiliser le cache docker. Sans elle start.sh partait en
# "Build : normal (--no-cache)", soit une recompilation Osmocom complete de ~40
# minutes A CHAQUE lancement du multi-operateur - alors que l image est deja la
# (addition.sh s en charge, et le prealable plus haut le verifie).
# OSMO_NONINTERACTIVE=1 : les boites whiptail de start.sh rendent leur valeur
# par defaut au lieu d attendre. Sans elle, le lancement s arretait sur
# « Nombre d'operateurs (1-36) » - un dialogue que personne ne voit quand on a
# clique sur une icone, et le banc paraissait mort.
# --operators : le drapeau EXPLICITE de start.sh (l.2552), et non la seule
# variable d environnement. start.sh remettait OPERATOR_COUNT_HINT a vide des
# sa ligne 70 - corrige depuis, mais l argument reste la voie sure : il est
# analyse apres, il prime, et il documente l intention dans la ligne de
# commande qu on affiche.
# HANDOFF_MODE=faketrx-qemu : la radio MIXTE, un faketrx + un QEMU Calypso par
# operateur - le meme montage que le natif. start.sh ne la choisissait seul
# qu en mode WAN ; impose ici, elle vaut aussi pour ce banc a une machine.
# OSMO_SKIP_CHECKS=1 : start.sh joue desormais ss7_check et operator_summary en
# fin de lancement. Ici on enchaine verifier(), qui rejoue ss7_check avec en
# plus la lecture de la topologie - inutile de le passer deux fois de suite.
# OP_ID_BASE=2 : les conteneurs prennent les rangs 2 et 3, le 1 reste au natif.
# OSMO_NO_ATTACH=1 : ne pas finir bloque dans le tmux d un conteneur - le script
# doit rendre la main pour enchainer verifier().
CMD=(env "OSMO_QUICK=1" "OSMO_NONINTERACTIVE=1" "HANDOFF_MODE=faketrx-qemu" "OSMO_SKIP_CHECKS=1"
     "OP_ID_BASE=2" "OSMO_NO_ATTACH=1"
     "$DIR/start.sh" virtual --operators "$N_DOCKER")

echo -e "  ${BOLD}Topologie${NC} : ${N_DOCKER} conteneur(s) + 1 natif + hub ${MULTI_HUB_IP}"
echo -e "  ${CYAN}→${NC} ${CMD[*]}"
echo

if [ "$ACTION" = "dry" ]; then
    echo -e "  ${YELLOW}--dry-run : rien n a ete lance.${NC}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── SE PLACER DANS LE DEPOT AVANT D APPELER start.sh ────────────────────────
# [2026-08-31] start.sh appelle ses aides en chemin RELATIF - ligne 2595 :
#     ./helpers/prepare_host.sh
# Lance depuis ailleurs (une icone du bureau demarre dans $HOME), il sortait
# donc sur
#     start.sh: line 2595: ./helpers/prepare_host.sh: No such file or directory
# et abandonnait AVANT de creer le moindre conteneur. Le bilan affichait
# ensuite "conteneur absent" trois fois, ce qui faisait chercher un probleme
# de docker alors que le script n avait jamais atteint le docker run.
cd "$DIR" || { echo -e "${RED}Impossible d entrer dans $DIR${NC}"; exit 1; }

# ── ALIGNER L IDENTITE SS7 DU NATIF, AVANT DE LANCER ────────────────────────
# start.sh numerote SES conteneurs 1..N sans decalage possible : avec 2
# conteneurs il produit les point codes 1.1.2 et 1.2.2. Un natif laisse a son
# defaut porte 1.1.2 lui aussi - deux equipements a la meme adresse SS7, ce que
# ce depot decrit comme "pas un conflit de nom, du routage faux".
#
# On repointe donc le natif sur le rang que la topologie lui donne, AVANT de
# lancer les conteneurs. Deux drapeaux comptent :
#   --local   plan d une seule machine, MID=<op> -> 1.<op>.<role>. SANS lui,
#             set-node-id.sh prend le plan WAN (MID=<noeud><op>) et rend
#             1.13.2 au lieu de 1.3.2 - verifie en dry-run.
#   --hub-ip  sinon l ASP est repointe sur 192.168.1.49, le hub WAN par defaut,
#             qui n existe pas ici : c est de la que venait le "Aucune
#             association SCTP vers 192.168.1.49:2908" des premiers essais.
# ── L IDENTITE DU NATIF NE TIENT PAS QU AU POINT CODE ───────────────────────
# [2026-08-31] set-node-id.sh repointe les point codes, et rien d autre. Or
# start-direct.sh derive TOUT le reste de son operateur depuis OPERATOR_ID
# (/etc/osmocom/coeur.env) :
#     MS_OP_ID  = OPERATOR_ID
#     ms_imsi() = MCC MNC <op sur 4> <ms sur 6>      -> l IMSI
#     MSISDN    = 100<op><ms>
#     MS_ARFCN1 = 512 + MS_OP_ID * 2                 -> la FREQUENCE
# Un natif realigne en operateur 3 mais laisse a OPERATOR_ID=1 gardait donc les
# abonnes de l operateur 1 - MSISDN 100101, IMSI 001010001000001 - exactement
# ceux que start.sh donne a son conteneur osmo-operator-1. Deux abonnes avec le
# meme MSISDN dans deux HLR, et deux cellules sur le MEME ARFCN : rien ne
# proteste au demarrage, et c est a l appel que ca part de travers.
_aligner_coeur_env() {
    local idx="$1" f="/etc/osmocom/coeur.env"
    [ -f "$f" ] || return 0
    if grep -qE '^[[:space:]]*:[[:space:]]*"\$\{OPERATOR_ID:=' "$f"; then
        sed -i -E "s|^([[:space:]]*:[[:space:]]*\"\\\$\\{OPERATOR_ID:=)[0-9]+(\\}\")|\\1${idx}\\2|" "$f"
        grep -qE "OPERATOR_ID:=${idx}\\}" "$f" \
            || echo -e "  ${GREEN}✓${NC} coeur.env : OPERATOR_ID=${idx} (IMSI, MSISDN et ARFCN du natif suivent)"
    else
        echo ": \"\${OPERATOR_ID:=${idx}}\"" >> "$f"
        echo -e "  ${GREEN}✓${NC} coeur.env : OPERATOR_ID=${idx} ajoute"
    fi
}

aligner_natif() {
    local idx pc spec reel
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode _ip pc _rctx <<< "$spec"
        [ "$mode" = "native" ] || continue
        # [2026-08-31] coeur.env est aligne D ABORD, et INCONDITIONNELLEMENT.
        # Il etait traite dans la branche "point code different" plus bas : une
        # fois les point codes deja bons, aligner_natif sortait par le
        # raccourci "deja en PC 1.3.2" et OPERATOR_ID restait a 1 pour
        # toujours. Le natif gardait alors les IMSI/MSISDN de l operateur 1 -
        # 001010001000001, 100101 - exactement ceux du conteneur op1, et
        # l ARFCN avec. Les deux reglages sont INDEPENDANTS : point codes
        # (set-node-id.sh) et plan d abonnes (OPERATOR_ID) ; les lier faisait
        # que le second ne se rattrapait jamais.
        _aligner_coeur_env "$idx"
        reel="$(natif_pc)"
        [ -n "$reel" ] || return 0
        [ "$reel" = "$pc" ] && { echo -e "  ${GREEN}✓${NC} natif deja en PC ${pc} (op ${idx})"; return 0; }
        echo -e "  ${CYAN}→${NC} natif en PC ${reel}, attendu ${pc} : realignement sur l operateur ${idx}"
        if [ -x "$DIR/network/set-node-id.sh" ] || [ -r "$DIR/network/set-node-id.sh" ]; then
            if bash "$DIR/network/set-node-id.sh" --node "${MULTI_NODE:-1}" --op "$idx" \
                    --local --hub-ip 127.0.0.1 >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} natif realigne : PC $(natif_pc)"
                echo -e "  ${YELLOW}!${NC} les demons natifs gardent l ancienne identite en memoire :"
                echo -e "    ${CYAN}sudo ${DIR}/start-direct.sh${NC} pour qu ils la relisent."
            else
                echo -e "  ${RED}✗${NC} realignement du natif echoue - voir network/set-node-id.sh"
            fi
        fi
        return 0
    done
}
aligner_natif

# ── TOUT ARRETER AVANT DE RELANCER ──────────────────────────────────────────
# [2026-08-31] Un clic = un banc NEUF. Sans ca, un lancement par-dessus un banc
# deja debout ne relance presque rien : les demons Osmocom ne relisent PAS leur
# configuration a chaud. On l a paye plusieurs fois - un osmo-stp realigne sur
# le bon point code gardait l ancien en memoire, et `kill -HUP` n y change rien
# (verifie : config a jour sur le disque, ASP toujours ASP_DOWN sur l ancienne
# adresse). Le seul geste qui compte est l arret complet.
#
# On arrete le NATIF (il delegue a run.sh --stop, qui demonte proprement radio
# et coeur). Rien ici ne doit faire echouer le lancement : ce qui est deja
# arrete l est tres bien, d ou les || true.
tout_arreter() {
    echo -e "  ${CYAN}→${NC} arret du banc en place (un clic = un banc neuf)"
    if [ -x "$DIR/start-direct.sh" ]; then
        timeout 120 "$DIR/start-direct.sh" --stop >/dev/null 2>&1 || true
        echo -e "    ${GREEN}✓${NC} pile native arretee"
    fi
    # Les conteneurs ne sont PAS touches ici : start.sh fait deja
    # `docker rm -f $(docker ps -aq --filter name=osmo-)` en tete de course.
    # Le refaire serait redondant, et surtout destructeur depuis launch.sh -
    # un clic sur le telephone rouge, qui ne monte que le natif, balayerait
    # les conteneurs multi-operateur d a cote.
    # Les ponts audio survivent aux conteneurs (setsid) : sans ca on empile un
    # relais de plus a chaque relance, et le son se dedouble.
    pkill -f 'paplay --server=tcp:' 2>/dev/null || true
}

tout_arreter

# ── SI LE NATIF EST A TERRE, ON LANCE SON RACCOURCI ─────────────────────────
# Le natif n est PAS lance par ce script : il a le sien (le telephone rouge du
# bureau -> launch.sh -> start-direct.sh). Mais monter les conteneurs sans lui,
# c est monter un banc a trois operateurs dont le premier manque : le hub
# n aura qu un ASP sur les trois attendus, et le bilan de fin sortira en
# DEGRADE pour une raison qui n a rien a voir avec ce qu on vient de lancer.
#
# On declenche donc son raccourci, et AVANT les conteneurs : l ordre compte,
# start-direct.sh a besoin de poser ses configs et son coeur pendant que le
# plan d adressage est encore libre.
#
# Pourquoi le .desktop et pas launch.sh en direct : c est le meme chemin que le
# double-clic, donc le meme terminal, la meme elevation pkexec et le meme
# comportement. Passer a cote reviendrait a tester une autre facon de demarrer
# que celle des utilisateurs.
NATIF_DESKTOP="${NATIF_DESKTOP:-/root/Desktop/osmo-launch.desktop}"

lancer_natif_si_absent() {
    _est_natif osmo-bsc asterisk && return 0

    echo -e "  ${YELLOW}!${NC} operateur natif a l arret - lancement de son raccourci"
    local d="$NATIF_DESKTOP"
    # Repli sur les autres emplacements : Bureau (locale fr) puis le menu.
    for _c in "$d" "${d%/Desktop/*}/Bureau/${d##*/}" "/usr/share/applications/${d##*/}"; do
        [ -f "$_c" ] && { d="$_c"; break; }
    done
    if [ ! -f "$d" ]; then
        echo -e "  ${RED}✗${NC} raccourci introuvable ($NATIF_DESKTOP)"
        echo -e "    ${CYAN}sudo ${DIR}/start-direct.sh${NC}"
        return 1
    fi

    # gio launch est LA facon d executer un .desktop : il lit Exec, applique
    # Terminal= et passe par le bus de session. gtk-launch en repli (il veut un
    # ID d application, pas un chemin - d ou le basename sans .desktop).
    # En dernier recours on extrait Exec a la main : mieux vaut demarrer le banc
    # que d echouer sur l outillage du bureau.
    # Le natif nous sert de PILE, pas de poste de travail : wireshark, linphone
    # et firefox sont deja ouverts par ailleurs (ou le seront par nos soins pour
    # les dashboards). Sans ce drapeau, launch.sh les rouvrait une seconde fois.
    export OSMO_LAUNCH_APPS=0
    # (a) LE NATIF PREND SA PROPRE FENETRE. Sans ce marqueur, launch.sh voyait
    # un tty - LE NOTRE - le prenait pour le sien, et start-direct.sh le tenait
    # jusqu au bout : notre sortie ecrasee, et la main rendue seulement a la fin
    # du natif. Voir launch.sh, garde « 1. Un terminal ».
    export OSMO_TERM_TAKEN=1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
    if command -v gio >/dev/null 2>&1 && gio launch "$d" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} raccourci lance : ${CYAN}${d}${NC}"
    elif command -v gtk-launch >/dev/null 2>&1 \
         && gtk-launch "$(basename "$d" .desktop)" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} raccourci lance (gtk-launch) : ${CYAN}${d}${NC}"
    else
        local _exec
        _exec="$(sed -n 's/^Exec=//p' "$d" | head -1 | sed 's/ *%[fFuUdDnNickvm]//g')"
        [ -n "$_exec" ] || { echo -e "  ${RED}✗${NC} pas de ligne Exec dans $d"; return 1; }
        echo -e "  ${YELLOW}○${NC} gio/gtk-launch indisponibles - execution directe : ${CYAN}${_exec}${NC}"
        setsid bash -c "$_exec" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi

    # On attend qu il soit reellement debout : enchainer les conteneurs pendant
    # que le natif se monte, c est se disputer les memes ressources.
    echo -ne "  ${CYAN}→${NC} attente du natif"
    local i
    for i in $(seq 1 120); do
        _est_natif osmo-bsc asterisk && { echo -e " ${GREEN}✓${NC}"; return 0; }
        sleep 1; echo -n "."
    done
    echo -e " ${YELLOW}toujours absent apres 120 s - on continue quand meme${NC}"
    return 0
}
lancer_natif_si_absent



"${CMD[@]}"
rc=$?

# ── LE CHECK DE FIN ─────────────────────────────────────────────────────────
# start.sh peut rendre 0 alors que le SS7 n est pas monte : son code de retour
# dit que les conteneurs ont DEMARRE, pas que les ASP se sont associes. C est
# la distinction que le depot documente ailleurs sous le nom de sonde
# mensongere - un superviseur vivant au-dessus d un pont qui n a jamais
# transporte un echantillon. On verifie donc l etat REEL, apres coup.
verifier() {
    local ko=0 spec idx mode nom _ip pc _rctx _pc_reel
    echo
    echo -e "  ${BOLD}── Verification ──${NC}"

    # 1. Les quatre elements sont-ils la ?
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode _ip pc _rctx <<< "$spec"
        if [ "$mode" = "docker" ]; then
            nom="osmo-operator-${idx}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
                echo -e "    ${GREEN}✓${NC} conteneur ${nom}"
            else
                echo -e "    ${RED}✗${NC} conteneur ${nom} absent"; ko=1
            fi
        else
            if ! _est_natif osmo-bsc asterisk; then
                echo -e "    ${RED}✗${NC} operateur natif arrete - ${CYAN}sudo ${DIR}/start-direct.sh --op ${idx}${NC}"; ko=1
            else
                # ── LE POINT CODE DU NATIF DOIT CORRESPONDRE A SON RANG ──
                # Un natif lance sans --op tourne en operateur 1, donc en
                # PC 1.1.2 - le meme que le PREMIER CONTENEUR, que start.sh
                # numerote toujours a partir de 1. La pile demarre des deux
                # cotes, tout parait vert, et c est le ROUTAGE SS7 qui est faux :
                # deux equipements a la meme adresse. On le verifie donc au lieu
                # de se contenter de "le processus tourne".
                _pc_reel="$(natif_pc)"
                if [ -z "$_pc_reel" ]; then
                    echo -e "    ${YELLOW}?${NC} operateur natif actif, point code illisible (/etc/osmocom/osmo-stp.cfg)"
                elif [ "$_pc_reel" = "$pc" ]; then
                    echo -e "    ${GREEN}✓${NC} operateur natif (op ${idx}, PC ${_pc_reel})"
                else
                    echo -e "    ${RED}✗${NC} operateur natif en PC ${_pc_reel}, attendu ${pc}"
                    echo -e "      il tourne en operateur $(echo "$_pc_reel" | cut -d. -f2), rang deja pris par un CONTENEUR"
                    echo -e "      ${CYAN}sudo ${DIR}/start-direct.sh --op ${idx}${NC}  (puis relancer ce script)"
                    ko=1
                fi
            fi
        fi
    done
    nom="${MULTI_HUB_NAME:-osmo-inter-stp}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$nom"; then
        echo -e "    ${GREEN}✓${NC} inter-STP ${nom}"
    else
        echo -e "    ${RED}✗${NC} inter-STP ${nom} absent"; ko=1
    fi

    # 2. Le point d entree M3UA du natif. On interroge `ss`, PAS /dev/tcp :
    #    M3UA roule sur SCTP, et une sonde TCP y est muette - la version
    #    precedente de ce check l avouait ("non concluant"), ce qui en faisait
    #    une ligne inutile. `ss -an` voit les sockets SCTP nommement.
    # awk par CHAMPS et pas un regex : `ss -an` aligne ses colonnes avec un
    # nombre d espaces VARIABLE selon la longueur des adresses, et un
    # "^sctp[[:space:]]+LISTEN.*" s y casse sans prevenir - teste, il ne
    # trouvait pas une ligne pourtant bien presente. $1/$2/$5 sont stables.
    if ss -an 2>/dev/null | awk -v p=":${MULTI_M3UA_PORT}" \
         '$1=="sctp" && $2=="LISTEN" && index($5,p)==length($5)-length(p)+1 {f=1} END{exit !f}'; then
        echo -e "    ${GREEN}✓${NC} M3UA en SCTP sur 127.0.0.1:${MULTI_M3UA_PORT} (l operateur natif peut s attacher)"
    else
        echo -e "    ${RED}✗${NC} rien n ecoute en SCTP sur le port ${MULTI_M3UA_PORT}"
        echo -e "      l ASP du natif (osmo-stp.cfg, remote-ip 127.0.0.1) ne trouvera personne"
        ko=1
    fi

    # 3. Le verificateur SS7 du depot, qui sait lire les ASP et les routes.
    if [ -x "$DIR/checks/ss7_check.sh" ]; then
        echo -e "    ${CYAN}→${NC} checks/ss7_check.sh"
        "$DIR/checks/ss7_check.sh" || ko=1
    else
        echo -e "    ${YELLOW}○${NC} checks/ss7_check.sh absent - verification SS7 sautee"
    fi

    echo
    if [ "$ko" = "0" ]; then
        echo -e "  ${GREEN}${BOLD}Banc multi-operateur OPERATIONNEL.${NC}"
    else
        echo -e "  ${RED}${BOLD}Le banc n est PAS complet${NC} - voir les lignes ✗ ci-dessus."
        echo -e "  ${CYAN}→${NC} etat detaille : ${BOLD}sudo $0 --status${NC}"
    fi
    return "$ko"
}

# ── LES DASHBOARDS DES CONTENEURS, EN ONGLETS SUPPLEMENTAIRES ───────────────
# launch.sh a deja ouvert Firefox sur le dashboard du NATIF et le tutoriel, et
# lance Linphone et Wireshark avec lui : on ne redouble rien de tout ca. Il
# manque seulement les consoles des conteneurs, une par operateur docker.
#
# Les adresses viennent de la topologie, pas d une liste en dur : ajouter un
# operateur a osmo-multi.conf suffit a lui ouvrir son onglet.
#
# On attend que chaque port reponde avant d ouvrir : un onglet lance trop tot
# affiche une page d erreur, et il faut alors recharger a la main - le
# dashboard d un conteneur met plusieurs secondes a monter apres le demarrage.
ouvrir_dashboards() {
    command -v firefox >/dev/null 2>&1 || return 0

    local spec idx mode ip urls="" i
    for spec in $MULTI_OPS; do
        IFS=: read -r idx mode ip _pc _rctx <<< "$spec"
        [ "$mode" = "docker" ] && [ -n "$ip" ] || continue
        for i in $(seq 1 60); do
            (exec 3<>"/dev/tcp/${ip}/8080") 2>/dev/null && { exec 3>&- 2>/dev/null; break; }
            sleep 1
        done
        if (exec 3<>"/dev/tcp/${ip}/8080") 2>/dev/null; then
            exec 3>&- 2>/dev/null
            urls="$urls http://${ip}:8080"
        else
            echo -e "  ${YELLOW}○${NC} dashboard op ${idx} (${ip}:8080) ne repond pas - onglet non ouvert"
        fi
    done
    [ -n "$urls" ] || return 0

    # Sous le compte de la session : Firefox y tourne deja, il ajoutera les URL
    # comme ONGLETS a la fenetre existante plutot que d en ouvrir une seconde.
    local u uid home
    u="$(natif_session_user)"; uid="$(id -u "$u" 2>/dev/null || echo 0)"
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    # shellcheck disable=SC2086
    setsid sudo -u "$u" \
        env DISPLAY="${DISPLAY:-:0}" \
            XAUTHORITY="${XAUTHORITY:-${home:-/root}/.Xauthority}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        firefox $urls </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} onglets dashboards :${CYAN}${urls}${NC}"
}

# Le compte de la session graphique, meme critere qu ailleurs : la presence de
# son socket pulse, et non son nom (l ISO ouvre la session sous root).
natif_session_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    echo "${SUDO_USER:-$(id -un)}"
}

# EN TACHE DE FOND, et c est essentiel : cette fonction attend jusqu a 60 s par
# conteneur que le port 8080 reponde. En avant-plan, ca fige le script jusqu a
# deux minutes AVANT les verifications - et le silence ressemble a un blocage.
# Pire quand le dashboard ne monte pas du tout : on attendait le maximum pour
# n ouvrir aucun onglet. Les onglets s ouvriront quand ils pourront ; les tests,
# eux, partent tout de suite.
ouvrir_dashboards &
disown 2>/dev/null || true

echo
etat
verifier || rc=1
# Ouverte par nos soins : on la retient, sinon le bilan disparait avec elle.
if [ "$_multi_own_window" = "1" ]; then
    echo
    echo "Fenetre maintenue ouverte - Entree pour fermer."
    read -r _ || true
fi
exit "$rc"
