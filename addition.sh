#!/bin/bash
# =============================================================================
# addition.sh - LES SUPPLEMENTS QUI NE SONT PAS DANS L ISO
#
# Jumelle d update.sh, et lancee comme elle : une icone GTK sur le bureau
# (osmo-addition-anim), ou a la main.
#
# POURQUOI DOCKER N EST PAS DANS L IMAGE
# L ISO est un noeud NATIF : elle porte le banc complet sans conteneur, et
# n a donc besoin de docker pour rien. L y embarquer couterait ~500 Mo et le
# demon tournerait en permanence sur un banc qui ne s en sert pas - avec son
# bridge, ses regles iptables et sa MASQUERADE, au milieu d une machine dont
# tout l interet est de router du GSM a la main.
# Docker ne sert qu a UN scenario : le multi-operateur (start-multi.sh), ou les
# operateurs 2 et 3 et l inter-STP tournent en conteneurs a cote du natif.
# C est un supplement, il s installe comme tel - ici.
#
# Usage :
#   sudo ./addition.sh            fenetre GTK : "Docker container and SS7
#                                 multioperator", puis une seconde fenetre en
#                                 boutons radio : image TELECHARGEE ou COMPILEE
#                                 (exclusif). osmocom-run est derivee dans la
#                                 foulee : start-multi.sh demarre juste apres.
#   sudo ./addition.sh --multi    le meme, sans la fenetre : image TELECHARGEE
#                                 (docker pull bastienbaranoff/norf_gsm, taguee
#                                 osmocom-nitb)
#   sudo ./addition.sh --multi-build
#                                 le meme, image COMPILEE sur place (build.sh,
#                                 plusieurs dizaines de minutes)
#   sudo ./addition.sh --docker   le moteur de conteneurs seul   (depannage)
#   sudo ./addition.sh --image    l image operateur seule, telechargee (depannage)
#   sudo ./addition.sh --build    l image operateur seule, compilee  (depannage)
#   sudo ./addition.sh --opencl   la pile OpenCL seule (calcul GPU)
#   sudo ./addition.sh --claude   Claude Code (CLI de l assistant) seul
#   sudo ./addition.sh --status   dit seulement ce qui est present
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
# NOM DE L IMAGE : osmocom-run, PAS "osmo-operator".
# build.sh produit osmocom-nitb (Dockerfile, ~11 Go) puis Dockerfile.run en
# derive osmocom-run, et c est CELLE-LA que start.sh lance - verifie sur le
# banc : `docker inspect osmo-operator-1 --format {{.Config.Image}}` rend
# osmocom-run. Chercher "osmo-operator" (le nom du DEPOT, pas de l image)
# rendait la sonde toujours negative : "image absente" en permanence, et une
# recompilation Osmocom de 40 minutes relancee pour rien a chaque passage.
MULTI_IMAGE="${MULTI_IMAGE:-osmocom-run}"
# IMAGE DE BASE ET SON ORIGINE. osmocom-nitb est ce que build.sh COMPILE
# (~40 min) ; la meme pile est publiee sur le hub sous bastienbaranoff/norf_gsm.
# Par defaut on la TIRE et on la tague osmocom-nitb : start.sh en derive ensuite
# osmocom-run via Dockerfile.run exactement comme apres un build local.
# Les deux chemins sont EXCLUSIFS et choisis explicitement (fenetre ou
# drapeau) : pas de repli silencieux de l un vers l autre.
BASE_IMAGE="${BASE_IMAGE:-osmocom-nitb}"
HUB_IMAGE="${HUB_IMAGE:-bastienbaranoff/norf_gsm}"

# ── _trust_desktop : rendre un raccourci du bureau VISIBLE par DING ──────────
# DING n affiche un .desktop avec son nom et son icone que s il est executable,
# possede par l utilisateur du bureau, ET porteur de metadata::trusted. Cet
# attribut ne vit PAS dans le fichier : il est ecrit dans les metadonnees gvfs
# de la SESSION, donc gio doit parler au bus de CET utilisateur.
#
# LE PIEGE QUI RENDAIT L ICONE INVISIBLE. addition.sh est lance par
# `pkexec env DISPLAY=... XAUTHORITY=... ` (osmo-addition-anim) : pkexec NETTOIE
# l environnement et ne transmet ni XDG_RUNTIME_DIR ni DBUS_SESSION_BUS_ADDRESS.
# `gio set metadata::trusted` n avait alors aucun bus a joindre, echouait en
# silence (2>/dev/null), et le fichier restait pose mais jamais approuve - donc
# absent du bureau. On reconstruit l env a partir de l UID proprietaire du
# bureau et on lance gio SOUS cet utilisateur.
_trust_desktop() {
    local f="$1" home="$2" pos="${3:-}" owner uid bus
    [ -f "$f" ] || return 1
    owner="$(stat -c '%U' "$home" 2>/dev/null)"; [ -n "$owner" ] || owner=root
    uid="$(id -u "$owner" 2>/dev/null)" || return 1
    chown "$owner" "$f" 2>/dev/null || true
    chmod +x "$f" 2>/dev/null || true
    bus="/run/user/$uid/bus"
    # Session active pour ce proprietaire : on pose les attributs TOUT DE SUITE.
    # Sinon (pas de bus), osmo-trust-desktop (autostart) posera trusted au
    # prochain login - l icone apparait alors sans intervention.
    # pos "x,y" (optionnel) : place l icone sur le bureau via DING.
    if [ -S "$bus" ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            gio set -t string "$f" metadata::trusted true 2>/dev/null || true
        [ -n "$pos" ] && runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            gio set -t string "$f" metadata::nautilus-icon-position "$pos" 2>/dev/null || true
    fi
    return 0
}

DO_DOCKER=0; DO_IMAGE=0; DO_MULTI=0; DO_OPENCL=0; DO_CLAUDE=0; STATUS_ONLY=0; ANY_FLAG=0
DO_BUILD=0
for a in "$@"; do
    case "$a" in
        --docker) DO_DOCKER=1; ANY_FLAG=1 ;;
        --image)  DO_IMAGE=1;  ANY_FLAG=1 ;;
        --build)  DO_IMAGE=1;  DO_BUILD=1; ANY_FLAG=1 ;;
        --multi)  DO_MULTI=1;  ANY_FLAG=1 ;;
        --multi-build) DO_MULTI=1; DO_BUILD=1; ANY_FLAG=1 ;;
        --opencl) DO_OPENCL=1; ANY_FLAG=1 ;;
        --claude) DO_CLAUDE=1; ANY_FLAG=1 ;;
        --all)    DO_DOCKER=1; DO_IMAGE=1; DO_MULTI=1; DO_OPENCL=1; DO_CLAUDE=1; ANY_FLAG=1 ;;
        --status) STATUS_ONLY=1; ANY_FLAG=1 ;;
        -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    esac
done

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   osmo-operator - supplements (hors ISO)             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

etat() {
    local ok_d=0 ok_r=0 ok_i=0 ok_m=0
    command -v docker >/dev/null 2>&1 && ok_d=1
    [ "$ok_d" = "1" ] && docker info >/dev/null 2>&1 && ok_r=1
    [ "$ok_r" = "1" ] && docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1 && ok_i=1
    [ -f "$MULTI_CONF" ] && ok_m=1
    local ok_cl=0
    # clinfo qui rend au moins une plateforme : c est la seule preuve qu une
    # pile OpenCL est UTILISABLE. Les paquets poses ne prouvent rien - un ICD
    # sans pilote derriere laisse "Number of platforms 0".
    command -v clinfo >/dev/null 2>&1 \
        && [ "$(clinfo -l 2>/dev/null | grep -c Platform)" -gt 0 ] && ok_cl=1
    local ok_cc=0
    # claude qui repond --version : la seule preuve qu il est UTILISABLE. Le
    # binaire pose sans node derriere (installation npm cassee) sort en erreur.
    command -v claude >/dev/null 2>&1 \
        && claude --version >/dev/null 2>&1 && ok_cc=1
    [ "$ok_d" = "1" ] && echo -e "  docker installe      : ${GREEN}oui${NC}"      || echo -e "  docker installe      : ${YELLOW}non${NC}"
    [ "$ok_r" = "1" ] && echo -e "  demon actif          : ${GREEN}oui${NC}"      || echo -e "  demon actif          : ${YELLOW}non${NC}"
    [ "$ok_i" = "1" ] && echo -e "  image operateur      : ${GREEN}presente${NC}" || echo -e "  image operateur      : ${YELLOW}absente${NC}"
    [ "$ok_m" = "1" ] && echo -e "  topologie SS7        : ${GREEN}posee${NC}"    || echo -e "  topologie SS7        : ${YELLOW}absente${NC}"
    [ "$ok_cl" = "1" ] && echo -e "  OpenCL               : ${GREEN}operationnel${NC}" || echo -e "  OpenCL               : ${YELLOW}absent${NC}"
    [ "$ok_cc" = "1" ] && echo -e "  Claude Code          : ${GREEN}operationnel${NC}" || echo -e "  Claude Code          : ${YELLOW}absent${NC}"
}

[ "$STATUS_ONLY" = "1" ] && { etat; exit 0; }

# ── LE CHOIX ────────────────────────────────────────────────────────────────
# Lancee par l icone, cette fenetre est la SEULE interface : sans elle, un
# double-clic partait droit sur un apt-get de plusieurs centaines de Mo et une
# compilation Osmocom, sans rien demander.
#
# [2026-08-31] UN SEUL CHOIX, ET C EST VOULU.
# La liste a cocher en offrait trois - "multi-operateur SS7", "docker", "image
# operateur" - alors qu il n y a jamais eu qu un scenario : le multi-operateur,
# qui ENTRAINE les deux autres (l implication, juste en dessous, remettait
# DO_DOCKER=1 et DO_IMAGE=1 des que la premiere ligne etait cochee). Les deux
# dernieres cases n etaient donc decochables qu en apparence : les decocher ne
# changeait rien tant que la premiere restait cochee, et les cocher seules
# donnait un demi-supplement dont rien ne se sert - docker sans image, ou une
# image de 11 Go sans la topologie qui l emploie.
# Une fenetre qui propose des choix sans effet ment sur ce que fait le script.
#
# [2026-09-02] DEUX CHOIX MAINTENANT - ET LA REGLE N A PAS CHANGE.
# Ce qui etait reproche aux trois cases d avant, ce n est pas leur nombre :
# c est qu elles etaient FAUSSES (cocher "docker" seul ne donnait rien
# d utilisable, et le decocher ne l empechait pas d etre installe). OpenCL,
# lui, est un supplement REELLEMENT independant : il n entraine rien, rien ne
# l entraine, on peut le vouloir sans le multi-operateur et l inverse. Une case
# qui commande quelque chose a le droit d exister ; une case decorative, non.
# Les drapeaux --docker / --image / --opencl restent pour le depannage console.
if [ "$ANY_FLAG" = "0" ]; then
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        # --print-column=2 N EST PAS FACULTATIF : le defaut de zenity est la
        # colonne 1, qui pour un --checklist est la CASE A COCHER - on
        # recupererait une liste de "TRUE" au lieu des choix. On imprime donc
        # la colonne 2, cachee, qui porte la CLE ("multi", "opencl") : le
        # libelle affiche peut alors changer sans casser les tests.
        # --separator : le defaut "|" traverse mal les tests ci-dessous ; on
        # prend un caractere qui n apparait dans aucun libelle.
        _choix=$(zenity --list --checklist --width=680 --height=340 \
            --title="osmo-operator - supplements" \
            --text="Supplements qui ne sont PAS dans l ISO.\nUne connexion Internet est necessaire." \
            --ok-label="Installer" --cancel-label="Fermer" \
            --separator="~" \
            --column="" --column="cle" --column="Supplement" \
            --hide-column=2 --print-column=2 \
            TRUE  multi  "Docker container and SS7 multioperator - docker.io, l image operateur (telechargee du hub OU compilee sur place : le choix vient ensuite), et la topologie op1 natif + op2/op3 docker + inter-STP" \
            FALSE opencl "OpenCL (calcul GPU) - runtime ICD, clinfo, le pilote de la carte detectee (Intel / Mesa-AMD, pocl en repli), et les outils deka / a51_tools / dst80_reversing / tea1-cracker clones dans /root" \
            FALSE claude "Claude Code (CLI de l assistant IA) - installeur natif claude.ai/install.sh (binaire autonome, sans npm) ; lance ensuite avec la commande claude" \
            2>/dev/null) || { echo "Annule."; exit 0; }
        [ -n "$_choix" ] || { echo "Rien de selectionne."; exit 0; }
        case "$_choix" in *multi*)  DO_MULTI=1  ;; esac
        # L ORIGINE DE L IMAGE : une seconde fenetre, en BOUTONS RADIO.
        # Telecharger et compiler sont exclusifs par construction - un radiolist
        # ne rend qu une valeur, il n y a pas de "les deux" a rattraper apres
        # coup comme avec des cases a cocher.
        if [ "$DO_MULTI" = "1" ]; then
            _orig=$(zenity --list --radiolist --width=680 --height=260 \
                --title="osmo-operator - image operateur" \
                --text="D ou vient l image operateur (osmocom-nitb, ~11 Go) ?" \
                --ok-label="Continuer" --cancel-label="Fermer" \
                --column="" --column="cle" --column="Origine" \
                --hide-column=2 --print-column=2 \
                TRUE  dl    "TELECHARGER - docker pull ${HUB_IMAGE} (quelques minutes selon le debit)" \
                FALSE build "COMPILER sur place - build.sh, compilation Osmocom (plusieurs dizaines de minutes)" \
                2>/dev/null) || { echo "Annule."; exit 0; }
            case "$_orig" in
                build) DO_BUILD=1 ;;
                dl)    DO_BUILD=0 ;;
                *)     echo "Aucune origine choisie."; exit 0 ;;
            esac
        fi
        case "$_choix" in *opencl*) DO_OPENCL=1 ;; esac
        case "$_choix" in *claude*) DO_CLAUDE=1 ;; esac
    else
        # Console sans zenity : le supplement historique, celui de l icone.
        DO_MULTI=1
    fi
fi

# Le multi-operateur ENTRAINE ses dependances : sans moteur ni image, la
# topologie posee ne servirait a rien et start-multi.sh renverrait ici.
if [ "$DO_MULTI" = "1" ]; then DO_DOCKER=1; DO_IMAGE=1; fi

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis : sudo $0${NC}"; exit 1; }

# ── OPENCL ──────────────────────────────────────────────────────────────────
# Supplement independant : rien ici n entraine docker, et docker n entraine pas
# ceci. Il sert au calcul GPU - les traitements lourds du cote SDR (correlation,
# FFT larges) et tout ce qu un utilisateur voudra faire tourner a cote.
#
# UNE PILE OPENCL, C EST DEUX MOITIES, ET L ERREUR CLASSIQUE EST DE N EN POSER
# QU UNE. Le "runtime" (ocl-icd) n est qu un aiguilleur : il lit
# /etc/OpenCL/vendors/*.icd et charge la bibliotheque du VENDEUR qui y est
# nommee. Sans ICD de vendeur, tout s installe sans une erreur et clinfo rend
#     Number of platforms   0
# ce qui ressemble a un materiel non supporte alors qu il ne manque qu un
# paquet. On pose donc l aiguilleur ET le pilote de la carte reellement
# presente, lue dans lspci.
#
# pocl est pose dans tous les cas : c est une implementation PROCESSEUR. Elle
# ne remplace pas un GPU, mais elle garantit qu un programme OpenCL trouve
# toujours une plateforme - y compris en machine virtuelle, ou dans un banc
# sans carte graphique dediee, ou l absence totale de plateforme fait echouer
# le code avec un CL_PLATFORM_NOT_FOUND_KHR que personne ne sait lire.
#
# NVIDIA est le cas a part : son ICD OpenCL n est pas un paquet separe
# installable seul, il voyage avec le pilote proprietaire (le paquet
# libnvidia-compute-xxx, tire par nvidia-driver-xxx). On l installe donc via
# ubuntu-drivers, qui choisit le pilote recommande pour la carte. C est un
# pilote graphique proprietaire, sur une machine dont l ecran depend : il faut
# le plus souvent REDEMARRER pour qu il prenne - on le dit clairement.
if [ "$DO_OPENCL" = "1" ]; then
    echo -e "  ${CYAN}→${NC} installation de la pile OpenCL ..."
    export DEBIAN_FRONTEND=noninteractive

    # lvm2 : PAS de l OpenCL, mais deka (installe avec ce supplement) monte ses
    # tables sur des volumes LVM - sans vgchange, deka-start.sh ne monte rien.
    # On le pose donc ici, avec deka.
    # swig + python3-dev : compilation des modules natifs de deka (_delta.so,
    # _libvankus.so) plus bas. build-essential est deja tire ailleurs.
    _cl_pkgs="ocl-icd-libopencl1 ocl-icd-opencl-dev opencl-headers clinfo pocl-opencl-icd lvm2 swig python3-dev"
    _vga="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' || true)"
    _nvidia=0
    case "$_vga" in
        *[Ii]ntel*)   _cl_pkgs="$_cl_pkgs intel-opencl-icd" ;;
    esac
    case "$_vga" in
        *AMD*|*ATI*|*[Rr]adeon*) _cl_pkgs="$_cl_pkgs mesa-opencl-icd" ;;
    esac
    case "$_vga" in
        *NVIDIA*|*nVidia*) _nvidia=1 ;;
    esac
    echo -e "      paquets : ${BOLD}${_cl_pkgs}${NC}"

    apt-get update || { echo -e "  ${RED}✗ apt-get update a echoue - pas de reseau ?${NC}"
                        echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
                        exit 1; }
    # Paquet par paquet, et non fatal : un ICD de vendeur absent du miroir
    # (cela arrive) ne doit pas emporter le runtime avec lui - la pile
    # processeur reste utilisable, et c est mieux que rien du tout.
    for _p in $_cl_pkgs; do
        apt-get install -y "$_p" >/dev/null 2>&1 \
            && echo -e "      ${GREEN}✓${NC} $_p" \
            || echo -e "      ${YELLOW}!${NC} $_p non installe (absent du miroir ?)"
    done

    # pyopencl : le binding Python d OpenCL, POSE DANS LE VENV /root/.env - le
    # meme que start-clean.sh (qosmo-grgsm) et le profil de root activent, et ou
    # vit deja gr-gsm. On l installe avec le pip DU VENV (/root/.env/bin/python3)
    # et pas le pip systeme : sinon le module ne serait pas visible du code qui
    # tourne sous ce venv. opencl-headers + ocl-icd-opencl-dev (poses au-dessus)
    # fournissent les en-tetes et libOpenCL.so dont pyopencl a besoin. Non fatal.
    if [ -x /root/.env/bin/python3 ]; then
        echo -e "  ${CYAN}→${NC} pyopencl dans le venv ${BOLD}/root/.env${NC} ..."
        if /root/.env/bin/python3 -m pip install --no-cache-dir --disable-pip-version-check pyopencl >/dev/null 2>&1; then
            echo -e "      ${GREEN}✓${NC} pyopencl"
        else
            echo -e "      ${YELLOW}!${NC} pyopencl non installe (voir : /root/.env/bin/python3 -m pip install pyopencl)"
        fi
    else
        echo -e "  ${YELLOW}!${NC} venv /root/.env absent - pyopencl non pose (attendu sur l ISO)"
    fi

    # LA SEULE VERIFICATION QUI VAUT : est-ce qu une plateforme repond ?
    if command -v clinfo >/dev/null 2>&1; then
        _np="$(clinfo -l 2>/dev/null | grep -c Platform || true)"
        if [ "${_np:-0}" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} OpenCL operationnel - ${BOLD}${_np}${NC} plateforme(s) :"
            clinfo -l 2>/dev/null | sed 's/^/      /'
        else
            echo -e "  ${YELLOW}!${NC} paquets poses, mais aucune plateforme OpenCL ne repond."
            echo -e "      Voir : ${BOLD}ls /etc/OpenCL/vendors/${NC} puis ${BOLD}clinfo${NC}"
        fi
    fi

    if [ "$_nvidia" = "1" ]; then
        echo -e "  ${CYAN}→${NC} carte ${BOLD}NVIDIA${NC} detectee : installation du pilote (ICD OpenCL inclus) ..."
        # LES HEADERS DU NOYAU D ABORD. Le pilote NVIDIA compile son module par
        # DKMS contre le noyau EN COURS : sans linux-headers-$(uname -r), dkms
        # et build-essential, le build du module echoue et l installation part
        # en erreur (souvent muette : le paquet s installe, mais nvidia.ko
        # n existe pas, et OpenCL reste absent). On les pose avant.
        _kver="$(uname -r)"
        echo -e "      ${CYAN}→${NC} pre-requis DKMS : linux-headers-${_kver}, dkms, build-essential"
        apt-get install -y "linux-headers-${_kver}" dkms build-essential >/dev/null 2>&1 \
            || echo -e "      ${YELLOW}!${NC} headers/dkms : installation partielle (headers absents du miroir ?)"
        # linux-headers-generic en filet : garde les headers alignes sur le
        # meta-noyau pour les mises a jour de noyau suivantes.
        apt-get install -y linux-headers-generic >/dev/null 2>&1 || true
        apt-get install -y ubuntu-drivers-common >/dev/null 2>&1 || true
        if command -v ubuntu-drivers >/dev/null 2>&1; then
            if ubuntu-drivers install; then
                echo -e "  ${GREEN}✓${NC} pilote NVIDIA installe"
            else
                echo -e "  ${YELLOW}!${NC} ubuntu-drivers install a echoue - repli : ${BOLD}nvidia-driver + nvidia-opencl-icd${NC}"
                apt-get install -y  nvidia-driver-610 nvidia-opencl-icd >/dev/null 2>&1 \
                    || echo -e "  ${YELLOW}!${NC} pilote NVIDIA non installe (voir : ubuntu-drivers devices)"
            fi
        else
            echo -e "  ${YELLOW}!${NC} ubuntu-drivers absent - installez a la main : ${BOLD}sudo ubuntu-drivers install${NC}"
        fi
        echo -e "  ${YELLOW}!${NC} un ${BOLD}redemarrage${NC} est generalement necessaire pour que le pilote"
        echo -e "      NVIDIA (et donc son OpenCL) soit actif - ${BOLD}clinfo${NC} le confirmera ensuite."
    fi

    # ── LES OUTILS QUI TOURNENT SUR OPENCL ───────────────────────────────────
    # deka, a51_tools, dst80_reversing, tea1-cracker : quatre depots de calcul
    # qui se servent du GPU. Ils VONT AVEC OpenCL - c est pour eux qu on le
    # pose - donc ils s installent ici, avec lui, et pas dans l ISO : l image
    # reste un noeud GSM, ces outils sont un supplement de calcul.
    # Clones dans /root. Idempotent : si le depot est deja la, on met a jour
    # (git pull) au lieu de recloner. Non fatal - un depot injoignable (prive,
    # reseau) n arrete pas le reste.
    echo -e "  ${CYAN}→${NC} outils OpenCL (deka, a51_tools, dst80_reversing, tea1-cracker) dans /root ..."
    # NON-INTERACTIF, SINON LA FENETRE FIGE. Sur un depot prive ou absent, git
    # reclame un identifiant sur le terminal et attend INDEFINIMENT - lance par
    # l icone, il n y a personne pour repondre. GIT_TERMINAL_PROMPT=0 le fait
    # echouer net (pas de prompt), et le message plus bas dit quoi faire.
    export GIT_TERMINAL_PROMPT=0
    for _rt in "deka=https://github.com/bbaranoff/deka" \
               "a51_tools=https://github.com/bbaranoff/a51_tools" \
               "dst80_reversing=https://github.com/bbaranoff/dst80_reversing" \
               "tea1-cracker=https://github.com/bbaranoff/tea1-cracker"; do
        _name="${_rt%%=*}"; _url="${_rt#*=}"; _dst="/root/$_name"
        # http.version=HTTP/1.1 : "expected flush after ref listing" vient d un
        # flux git corrompu par HTTP/2 (proxy/antivirus qui s intercale) - le
        # symptome depend de la taille, d ou certains depots qui passent et
        # d autres non. Forcer HTTP/1.1 est le remede de cette erreur exacte.
        # On CAPTURE la sortie de git et on la MONTRE en cas d echec.
        GIT="git -c http.version=HTTP/1.1"
        if [ -d "$_dst/.git" ]; then
            if _err=$($GIT -C "$_dst" pull --ff-only 2>&1); then
                echo -e "      ${GREEN}✓${NC} $_name a jour ($(git -C "$_dst" log -1 --format='%h'))"
            else
                echo -e "      ${YELLOW}!${NC} $_name : git pull a echoue - $(echo "$_err" | tail -1)"
            fi
        elif _err=$($GIT clone --depth 1 "$_url" "$_dst" 2>&1); then
            echo -e "      ${GREEN}✓${NC} $_name clone ($(git -C "$_dst" log -1 --format='%h'))"
        else
            echo -e "      ${YELLOW}!${NC} $_name : clone impossible - $_url"
            echo -e "        ${YELLOW}git:${NC} $(echo "$_err" | tail -1)"
        fi
    done

    # ── deka : compilation des modules natifs (make) ─────────────────────────
    # deka importe _delta.so et _libvankus.so, produits par SWIG + gcc depuis
    # delta.c / libvankus.c (voir son Makefile). Sans ce make, les workers
    # importent des modules absents et deka ne calcule rien. Pre-requis : swig
    # et les entetes python3. Non fatal : un echec le dit, sans stopper le reste.
    if [ -f /root/deka/Makefile ]; then
        echo -e "  ${CYAN}→${NC} deka : compilation des modules natifs (make) ..."
        apt-get install -y --no-install-recommends swig python3-dev build-essential >/dev/null 2>&1 || true
        if ( cd /root/deka && make >/dev/null 2>&1 ) \
           && [ -e /root/deka/_delta.so ] && [ -e /root/deka/_libvankus.so ]; then
            echo -e "      ${GREEN}✓${NC} _delta.so + _libvankus.so construits"
        else
            echo -e "      ${YELLOW}!${NC} make deka a echoue (swig / python3-dev ?) - voir : cd /root/deka && make"
        fi
    fi

    # ── deka : une ICONE d appli (pas un service) ────────────────────────────
    # deka monte des tables et lance des workers - ca ne doit PAS partir a
    # chaque boot dans le dos de l utilisateur (le montage suppose le groupe de
    # volumes present). On pose donc une icone : l utilisateur la clique quand
    # il veut demarrer deka. deka-start.sh reste le moteur ; l icone l appelle
    # avec les droits root (pkexec) dans un terminal, pour voir la sortie.
    if [ -d /root/deka ]; then
        echo -e "  ${CYAN}→${NC} deka : pose de l icone d application ..."
        # deka-start.sh vit dans le depot : s il est la (clone a jour), on n y
        # touche pas. On ne l ecrit qu en SECOURS, pour un clone qui ne l aurait
        # pas encore.
        if [ ! -f /root/deka/deka-start.sh ]; then
        cat > /root/deka/deka-start.sh <<'DEKASTART'
#!/bin/bash
# deka-start.sh - montage des tables deka et lancement des workers.
# Pose par addition.sh (supplement OpenCL). Lance par l icone deka (pkexec), ou
# a la main : sudo /root/deka/deka-start.sh
#   1. vgchange -ay : active le groupe de volumes (sinon /dev/tables/* absent).
#   2. les 4 points de montage, puis les 4 volumes (1_10..31_40).
#   3. les 3 workers python, depuis /root/deka (delta.pyc y vit).
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOG=/var/log/deka.log
# Sortie a l ECRAN + copie dans le log (tee) : on veut VOIR les montages et les
# PID des workers, pas les chercher dans un fichier.
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) deka-start ==="
[ "$(id -u)" -eq 0 ] || { echo "root requis : sudo $0"; exit 1; }
PY="$(command -v python3.7 || command -v python3)"
[ -n "$PY" ] || { echo "aucun python3 trouve"; exit 1; }
vgchange -ay || echo "ATTENTION: vgchange -ay a echoue (groupe absent ?)"
mkdir -p /mnt1 /mnt2 /mnt3
monter() {
    local dev="$1" pt="$2"
    if mountpoint -q "$pt"; then echo "deja monte: $pt"; return 0; fi
    if [ ! -e "$dev" ]; then echo "ABSENT: $dev - non monte sur $pt"; return 1; fi
    mount "$dev" "$pt" && echo "monte: $dev -> $pt" || echo "ECHEC montage: $dev -> $pt"
}
monter /dev/tables/1_10  /mnt
monter /dev/tables/11_20 /mnt1
monter /dev/tables/21_30 /mnt2
monter /dev/tables/31_40 /mnt3
cd "$DIR" || exit 1
for w in paplon.py oclvankus.py delta_client.py; do
    [ -f "$w" ] || { echo "worker absent: $w"; continue; }
    echo "lancement: $PY $DIR/$w"
    "$PY" "$DIR/$w" >>"/var/log/deka-${w%.py}.log" 2>&1 &
    echo "  pid $!"
done
echo "deka-start termine."
DEKASTART
        chmod 755 /root/deka/deka-start.sh
        fi

        # LE LANCEUR : deka-start.sh a besoin de root (vgchange, mount). Depuis
        # une icone on n est pas root : pkexec eleve, et un terminal reste
        # ouvert pour lire la sortie (montages, PID des workers). Meme facture
        # que osmo-addition-anim.
        cat > /usr/local/bin/osmo-deka-anim <<'DEKAGUI'
#!/bin/bash
set -u
SCRIPT=/root/deka/deka-start.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="deka-start.sh introuvable : $SCRIPT" 2>/dev/null
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
CMD="$RUNNER; echo; read -n1 -rsp 'deka lance - une touche pour fermer...'"
for term in x-terminal-emulator gnome-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
        gnome-terminal) exec "$term" --title="deka" -- bash -c "$CMD" ;;
        *)              exec "$term" -T "deka" -e bash -c "$CMD" ;;
    esac
done
exec bash -c "$RUNNER"
DEKAGUI
        chmod 755 /usr/local/bin/osmo-deka-anim

        # ICONE DEDIEE : la mandala de connecteurs (data/deka.svg, facon BRMLAB),
        # posee en CHEMIN ABSOLU dans Icon= - un nom de theme arrive apres
        # icon-theme.cache s afficherait en page blanche (cf. update.sh).
        install -d /usr/share/osmo-operator/icons /usr/share/icons/hicolor/scalable/apps
        if [ -f "$DIR/data/deka.svg" ]; then
            install -m644 "$DIR/data/deka.svg" /usr/share/osmo-operator/icons/deka.svg
            install -m644 "$DIR/data/deka.svg" /usr/share/icons/hicolor/scalable/apps/deka.svg
        fi
        _deka_desktop=/usr/share/applications/deka.desktop
        cat > "$_deka_desktop" <<'DEKADSK'
[Desktop Entry]
Type=Application
Name=deka
Name[fr]=deka
Comment=Monte les tables et lance les workers deka
Comment[fr]=Monte les tables et lance les workers deka
Exec=/usr/local/bin/osmo-deka-anim
Icon=/usr/share/osmo-operator/icons/deka.svg
Terminal=false
Categories=System;Utility;
Keywords=deka;tables;workers;opencl;
DEKADSK
        chmod 644 "$_deka_desktop"
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        update-desktop-database /usr/share/applications 2>/dev/null || true

        # Sur les bureaux : DING n affiche un .desktop avec son nom et son icone
        # que s il est executable ET porteur de metadata::trusted (voir la meme
        # mecanique dans update.sh). On le pose sous chaque bureau existant.
        _posee=0
        for _h in /root /home/*; do
            for _dir in Bureau Desktop; do
                [ -d "$_h/$_dir" ] || continue
                cp -f "$_deka_desktop" "$_h/$_dir/deka.desktop" 2>/dev/null || continue
                _trust_desktop "$_h/$_dir/deka.desktop" "$_h" "0,0"
                touch "$_h/$_dir" 2>/dev/null || true
                _posee=1
            done
        done
        [ "$_posee" = "1" ] \
            && echo -e "  ${GREEN}✓${NC} icone ${BOLD}deka${NC} posee sur le bureau (clic pour monter + lancer)" \
            || echo -e "  ${GREEN}✓${NC} icone ${BOLD}deka${NC} dans le menu des applications"
    fi
fi

# ── CLAUDE CODE ──────────────────────────────────────────────────────────────
# Supplement independant : Claude Code, la CLI de l assistant. Rien ici
# n entraine docker ni OpenCL, et rien ne l entraine - on peut le vouloir seul.
#
# ON PREND L INSTALLEUR NATIF (claude.ai/install.sh), PAS npm, ET C EST VOULU.
# @anthropic-ai/claude-code par npm exige node >= 18 ; or le node des depots
# Ubuntu 22.04 est une v12, trop vieille - l installation npm casserait, ou
# reclamerait un depot tiers (NodeSource) qu on evite ici comme on evite
# get.docker.com plus bas. L installeur natif pose un binaire autonome (node
# embarque), sans toucher au systeme : c est le chemin le plus sur.
#
# Il pose dans ~/.local/bin (donc /root/.local/bin, lance en sudo). On lie ce
# binaire dans /usr/local/bin pour qu il soit sur le PATH de tout le monde et
# que la sonde `command -v claude` le voie.
if [ "$DO_CLAUDE" = "1" ]; then
    echo -e "  ${CYAN}→${NC} installation de Claude Code ..."
    export DEBIAN_FRONTEND=noninteractive

    # curl + certificats : l installeur les exige. Non fatal en soi, mais on
    # previent tot si le reseau manque - rien n est pre-telecharge dans l ISO.
    command -v curl >/dev/null 2>&1 || apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "  ${RED}✗ curl absent et non installable - pas de reseau ?${NC}"
        echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
        exit 1
    fi

    # HOME explicite : lance par pkexec/sudo, $HOME peut manquer ou pointer
    # ailleurs ; l installeur pose dans $HOME/.local/bin, on veut savoir ou.
    _cc_home="${HOME:-/root}"
    if _out=$(HOME="$_cc_home" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1); then
        echo -e "      ${GREEN}✓${NC} installeur natif termine"
    else
        echo -e "      ${YELLOW}!${NC} installeur natif en echec - $(echo "$_out" | tail -1)"
    fi

    # Trouver le binaire pose et le lier sur le PATH global. On regarde les
    # emplacements connus de l installeur (~/.local/bin, puis repli /root).
    _cc_bin=""
    for _c in "$_cc_home/.local/bin/claude" /root/.local/bin/claude "$_cc_home/.claude/bin/claude"; do
        [ -x "$_c" ] && { _cc_bin="$_c"; break; }
    done
    if [ -n "$_cc_bin" ] && [ ! -e /usr/local/bin/claude ]; then
        ln -sf "$_cc_bin" /usr/local/bin/claude
        echo -e "      ${GREEN}✓${NC} lien /usr/local/bin/claude -> $_cc_bin"
    fi

    # LA SEULE VERIFICATION QUI VAUT : est-ce que claude repond ?
    if command -v claude >/dev/null 2>&1 && _ver=$(claude --version 2>/dev/null); then
        echo -e "  ${GREEN}✓${NC} Claude Code operationnel - ${BOLD}${_ver}${NC}"
        echo -e "      lancez-le avec la commande ${BOLD}claude${NC}"
    else
        echo -e "  ${YELLOW}!${NC} Claude Code pose, mais ne repond pas encore."
        echo -e "      Ouvrez un nouveau terminal (PATH), ou lancez ${BOLD}$_cc_home/.local/bin/claude${NC}"
    fi

    # ── ICONE CLAUDE : tuile clay + sunburst Anthropic (data/claude.svg) ──────
    # Lanceur osmo-claude-anim : ouvre un terminal qui lance claude ; s il n est
    # pas installe, il enchaine ce meme supplement (--claude) puis le lance.
    install -d /usr/share/osmo-operator/icons /usr/share/icons/hicolor/scalable/apps
    if [ -f "$DIR/data/claude.svg" ]; then
        install -m644 "$DIR/data/claude.svg" /usr/share/osmo-operator/icons/claude.svg
        install -m644 "$DIR/data/claude.svg" /usr/share/icons/hicolor/scalable/apps/claude.svg
    fi
    cat > /usr/local/bin/osmo-claude-anim <<'CLA'
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
    chmod 755 /usr/local/bin/osmo-claude-anim
    if [ -f "$DIR/data/desktop/claude.desktop" ]; then
        install -m644 "$DIR/data/desktop/claude.desktop" /usr/share/applications/claude.desktop
        sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/claude.svg|" /usr/share/applications/claude.desktop
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        update-desktop-database /usr/share/applications 2>/dev/null || true
        _homes=(/root)
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            _uh="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
            [ -n "$_uh" ] && [ -d "$_uh" ] && _homes+=("$_uh")
        fi
        _cposee=0
        for _h in "${_homes[@]}"; do
            for _dir in Bureau Desktop; do
                [ -d "$_h/$_dir" ] || continue
                cp -f /usr/share/applications/claude.desktop "$_h/$_dir/claude.desktop" 2>/dev/null || continue
                _trust_desktop "$_h/$_dir/claude.desktop" "$_h" "110,0"
                touch "$_h/$_dir" 2>/dev/null || true
                _cposee=1
            done
        done
        [ "$_cposee" = "1" ] \
            && echo -e "  ${GREEN}✓${NC} icone ${BOLD}Claude${NC} posee sur le bureau (en haut a gauche)" \
            || echo -e "  ${GREEN}✓${NC} icone ${BOLD}Claude${NC} dans le menu des applications"
    fi
fi

# ── DOCKER ──────────────────────────────────────────────────────────────────
# docker.io des depots Ubuntu, PAS le script get.docker.com : celui-ci ajoute un
# depot tiers et remplace containerd, ce qui sur une image figee se paie au
# premier apt-get upgrade. La version des depots suffit : on ne fait tourner
# que nos propres conteneurs.
if [ "$DO_DOCKER" = "1" ]; then
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker deja installe ($(docker --version 2>/dev/null | head -1))"
    else
        echo -e "  ${CYAN}→${NC} installation de docker.io ..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || { echo -e "  ${RED}✗ apt-get update a echoue - pas de reseau ?${NC}"
                            echo -e "    Ce supplement a BESOIN d Internet : rien n est pre-telecharge dans l ISO."
                            exit 1; }
        apt-get install -y docker.io || { echo -e "  ${RED}✗ installation de docker.io echouee${NC}"; exit 1; }
        echo -e "  ${GREEN}✓${NC} docker.io installe"
    fi
    systemctl enable --now docker 2>/dev/null || true
    # Le socket met un instant a repondre apres un premier demarrage : sans
    # cette attente, le `docker info` suivant echoue et l on croit
    # l installation ratee.
    for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} demon docker actif" \
        || { echo -e "  ${RED}✗ le demon docker ne repond pas${NC} - voir : systemctl status docker"; exit 1; }
fi

# ── IMAGE OPERATEUR ─────────────────────────────────────────────────────────
# Deux chemins pour obtenir osmocom-nitb :
#   1. docker pull ${HUB_IMAGE} && docker tag ... osmocom-nitb  (defaut)
#      La pile Osmocom deja compilee, publiee sur le hub : le telechargement
#      remplace 40 minutes de compilation. Le tag donne au resultat le nom que
#      start.sh (Dockerfile.run : FROM osmocom-nitb) et start-nitb.sh attendent.
#   2. build.sh --no-cache  (--build / --multi-build / case "compiler")
#      --no-cache : le supplement rebatit l image PROPRE. Le cache docker
#      gardait des couches d une pile Osmocom a moitie compilee (ex. le clone
#      github casse de libosmocore) et les rejouait a l identique - un build
#      deja casse restait casse a chaque passage. On force la reconstruction.
_build_image() {
    [ -x "$DIR/build.sh" ] || { echo -e "  ${RED}✗ build.sh introuvable dans $DIR${NC}"; return 1; }
    echo -e "  ${CYAN}→${NC} construction de l image : ${BOLD}${DIR}/build.sh --no-cache${NC}"
    echo -e "      compilation Osmocom - comptez plusieurs dizaines de minutes."
    "$DIR/build.sh" --no-cache || { echo -e "  ${RED}✗ ${DIR}/build.sh a echoue${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image operateur construite (${BASE_IMAGE})"
}
_pull_image() {
    echo -e "  ${CYAN}→${NC} telechargement de l image : ${BOLD}docker pull ${HUB_IMAGE}${NC}"
    echo -e "      ~11 Go depuis le hub - selon le debit, quelques minutes a une heure."
    docker pull "$HUB_IMAGE" || { echo -e "  ${RED}✗ docker pull ${HUB_IMAGE} a echoue${NC} - reseau, ou image absente du hub"
                                  echo -e "    Alternative : compiler sur place avec ${BOLD}$0 --multi-build${NC}"; return 1; }
    docker tag "$HUB_IMAGE" "$BASE_IMAGE" || { echo -e "  ${RED}✗ docker tag ${HUB_IMAGE} ${BASE_IMAGE} a echoue${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image operateur tiree du hub et taguee ${BASE_IMAGE}"
}
# L IMAGE QUE LE MULTI-OPERATEUR LANCE EST osmocom-run, PAS osmocom-nitb.
# Ni le pull ni build.sh ne la produisent : c est Dockerfile.run (FROM
# osmocom-nitb) qui la derive, en quelques secondes. start-multi.sh sonde
# osmocom-run et renvoie ici si elle manque : sans cette derivation, un
# supplement "reussi" laissait le multi-operateur incapable de demarrer.
# Meme commande que start.sh (build_run_image, mode quick).
_derive_run_image() {
    echo -e "  ${CYAN}→${NC} derivation de l image d execution : ${BOLD}docker build -f Dockerfile.run -t ${MULTI_IMAGE}${NC}"
    ( cd "$DIR" && docker build --build-arg QEMU_CACHE_BUST=$(date +%s) \
                       -f Dockerfile.run -t "$MULTI_IMAGE" . ) \
        || { echo -e "  ${RED}✗ derivation de ${MULTI_IMAGE} echouee${NC}"; return 1; }
    echo -e "  ${GREEN}✓${NC} image d execution prete (${MULTI_IMAGE})"
}
if [ "$DO_IMAGE" = "1" ]; then
    if [ "$DO_BUILD" = "1" ]; then
        _build_image || exit 1
        _derive_run_image || exit 1
    elif docker image inspect "$MULTI_IMAGE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} image operateur deja presente (${MULTI_IMAGE})"
    elif docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} image de base deja presente (${BASE_IMAGE})"
        _derive_run_image || exit 1
    else
        _pull_image || exit 1
        _derive_run_image || exit 1
    fi
fi

# ── TOPOLOGIE MULTI-OPERATEUR ───────────────────────────────────────────────
# Ecrite ICI, une fois, et relue par start-multi.sh. Elle n est pas recalculee
# des deux cotes : deux formules jumelles finissent toujours par diverger, et le
# depot en porte deja la trace (start.sh et lib/gabarits.sh tiennent les MEMES
# fonctions en double).
#
# LE PLAN SS7, tel que start-interstp.sh le definit :
#     PC   = 1.<noeud><op>.<role>      role 1=MSC 2=STP 3=BSC
#     RCTX = noeud*1000 + op*100 + 50
# Sur une seule machine le noeud vaut 1, donc PC = 1.<op>.<role>.
#
#   op 1  NATIF   - PC 1.1.2, celui de start-direct.sh, laisse tel quel
#   op 2  DOCKER  - PC 1.2.2, backbone 172.20.0.12
#   op 3  DOCKER  - PC 1.3.2, backbone 172.20.0.13
#
# ⚠️ LES CONTENEURS COMMENCENT A 2, ET CELA SE PILOTE.
# start.sh numerotait ses conteneurs 1..N en dur : avec --operators 2 il creait
# osmo-operator-1 en point code 1.1.2, celui du natif. Deux equipements a la
# meme adresse SS7 - "pas un conflit de nom, du routage faux"
# (checks/wan_ss7_check.sh). OP_ID_BASE=2 (start.sh) fait demarrer les
# conteneurs au rang 2 et laisse le 1 au natif ; nom, backbone, point code,
# RCTX, segment prive et ports publies en decoulent tous.
# Le natif joint le hub par la passerelle du bridge : l hote atteint
# 172.20.0.10 directement, sans NAT ni route a ajouter.
if [ "$DO_MULTI" = "1" ]; then
    install -d "$(dirname "$MULTI_CONF")"
    cat > "$MULTI_CONF" <<CONF
# osmo-multi.conf - topologie multi-operateur, ecrite par addition.sh.
# Relue par start-multi.sh. Ne pas editer a la main sans relire les deux.
MULTI_NODE=1
MULTI_HUB_NAME=osmo-inter-stp
MULTI_HUB_IP=172.20.0.10
MULTI_HUB_PC=0.0.0
MULTI_M3UA_PORT=2908
MULTI_NET_NAME=osmo-ss7
MULTI_NET_SUBNET=172.20.0.0/24
MULTI_NET_GW=172.20.0.1
MULTI_IMAGE=osmocom-run
# operateurs : "index:mode:backbone_ip:point_code:rctx"
MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:1.2.2:250 3:docker:172.20.0.13:1.3.2:350"
CONF
    echo -e "  ${GREEN}✓${NC} topologie SS7 ecrite : ${CYAN}${MULTI_CONF}${NC}"
    echo -e "      op1 ${BOLD}natif${NC} (1.1.2) + op2/op3 ${BOLD}docker${NC} (1.2.2 / 1.3.2) → hub 172.20.0.10"

    # ── L ICONE MULTI-OPERATOR : POSEE ICI, A LA FIN, ET PAS AVANT ────────────
    # L antenne bleue lance start-multi.sh, qui suppose docker, l image et la
    # topologie ci-dessus. La poser au build ISO (comme le telephone ou le
    # tutoriel) la faisait apparaitre sur le bureau des le premier boot, AVANT
    # que ce supplement n existe : un clic ne donnait rien. On la pose donc
    # seulement maintenant, une fois l install SS7 reellement faite - build-iso
    # et install_modules/80-bureau.sh ne la posent plus.
    _ico_dir=/usr/share/osmo-operator/icons
    _svg="$DIR/data/osmo-multi.svg"
    _dsk="$DIR/data/desktop/osmo-multi.desktop"
    if [ -f "$_dsk" ]; then
        install -d "$_ico_dir" /usr/share/icons/hicolor/scalable/apps /usr/share/applications
        # SVG en CHEMIN ABSOLU dans Icon= (voir build-iso.sh) : un nom de theme
        # arrive apres icon-theme.cache s affiche en page blanche.
        if [ -f "$_svg" ]; then
            install -m644 "$_svg" "$_ico_dir/osmo-multi.svg"
            install -m644 "$_svg" /usr/share/icons/hicolor/scalable/apps/osmo-multi.svg
        fi
        install -m644 "$_dsk" /usr/share/applications/osmo-multi.desktop
        # Exec= et Icon= suivent l arbre reel ($DIR), pas /opt/GSM en dur.
        sed -i -e "s|^Exec=/opt/GSM/osmo-operator/|Exec=$DIR/|" \
               -e "s|^Icon=.*|Icon=$_ico_dir/osmo-multi.svg|" \
               /usr/share/applications/osmo-multi.desktop

        # Sur les bureaux de root et de l utilisateur sudo, en Bureau/ et
        # Desktop/. metadata::trusted pour que DING l affiche sans pastille ;
        # osmo-trust-desktop (au login) la repositionne et la trust aussi.
        _homes=(/root)
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            _uh="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
            [ -n "$_uh" ] && [ -d "$_uh" ] && _homes+=("$_uh")
        fi
        _posee=0
        for _h in "${_homes[@]}"; do
            for _dir in Bureau Desktop; do
                [ -d "$_h/$_dir" ] || continue
                cp -f /usr/share/applications/osmo-multi.desktop "$_h/$_dir/osmo-multi.desktop" 2>/dev/null || continue
                _trust_desktop "$_h/$_dir/osmo-multi.desktop" "$_h"
                touch "$_h/$_dir" 2>/dev/null || true
                _posee=1
            done
        done
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
        [ "$_posee" = "1" ] \
            && echo -e "  ${GREEN}✓${NC} icone ${BOLD}multi-operator${NC} (antenne) posee sur le bureau" \
            || echo -e "  ${GREEN}✓${NC} icone ${BOLD}multi-operator${NC} dans le menu des applications"
    fi
fi

echo
etat
echo
[ "$DO_MULTI" = "1" ] && \
    echo -e "  ${CYAN}→${NC} lancer : ${BOLD}sudo $DIR/start-multi.sh${NC}  (ou l antenne bleue du bureau)"
[ "$DO_OPENCL" = "1" ] && \
    echo -e "  ${CYAN}→${NC} verifier OpenCL : ${BOLD}clinfo${NC}"
exit 0
