#!/bin/bash
# =============================================================================
# start-direct.sh - Prepare l'environnement Calypso puis lance run.sh
# =============================================================================
#
# Ce script ne demarre aucun demon.
#
# Il :
#   1. charge l'environnement ;
#   2. detecte le materiel / les binaires ;
#   3. choisit le mode (profil) ;
#   4. genere les fichiers mobile_*.cfg ;
#   5. exporte les variables necessaires ;
#   6. execute run.sh.
#
# Toute la logique GSM vit ensuite dans run.sh (et run_modules/).
#
# CHAINE DE CONFIGURATION - NE PAS LA CASSER
#     VAR=x ./start-direct.sh   ← la ligne de commande gagne toujours
#       -> environment/load.env
#          -> paths / modes / domaines
#     puis exec run.sh avec le profil choisi.
# -----------------------------------------------------------------------------
set -uo pipefail

# ── [2026-08-14] GARDE "on doit etre dans Docker" RETIREE ───────────────────
# Elle exigeait /.dockerenv ET /etc/docker-entrypoint-cmd, et sortait en exit 1
# quand l'un manquait. Sur l'ISO il n'y a pas de Docker : les deux fichiers sont
# absents, la garde bloquait donc le seul lanceur utilisable la-bas. Retiree sur
# demande explicite - c'est le cas d'usage ISO qui prime.
#
# CE QU'ON PERD, et c'etait sa raison d'etre (constat du 12/08) : lance par
# erreur sur un HOTE qui a Docker, ce script repart sur un environnement a
# moitie construit - /opt/GSM/qemu-src n'y existe pas, mais /tmp/osmo-nitb/logs,
# lui, se cree tout seul - et meurt sur un "run.sh introuvable" qui ne designe
# pas la vraie cause. Si ce symptome reapparait sur une machine avec Docker,
# c'est ca : la-bas le lanceur est ./start.sh (ou ./start-nitb.sh), pas celui-ci.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# --- options ------------------------------------------------------------------
DRY=0 VERBOSE=0 ACTION=start PROFILE="${CALYPSO_PROFILE:-faketrx-qemu}" FORCE=0
# WAN : jamais par defaut. --wan (ou WAN_AUTO=1 dans /etc/osmo-wan.conf, ce que
# pose une ISO construite avec --wan) le monte avant de passer la main a run.sh.
WAN_MESH=0
# --virtualbox : monte le segment et les VM avant le WAN. Refuse si l'on tourne
# DANS une VM - c'est l'hote qui pilote VirtualBox (le script le verifie).
VBOX_INTERCO=0
VBOX_NODES=""
VBOX_HOST_NODE=1
# --node : le numero de CE noeud, choisi au lancement et pas a la construction.
# C'est ce qui permet une ISO unique pour les neuf noeuds.
NODE_ID=""
NODE_OP=1
HUB_IP=""
# Les gabarits ne sont PAS regeneres par defaut : run.sh le ferait au demarrage
# et effacerait l'identite SS7 posee juste avant. --regen retablit l'ancien
# comportement pour qui veut repartir des gabarits.
REGEN_GABARITS=0
# --dsp : la chaine d'INSPECTION du Calypso. Eteinte par defaut - voir le bloc
# « Outillage DSP » plus bas.
DSP_MODE=0
# --menu : demande les choix au lieu de les deviner. Voir le bloc « Menu » plus bas.
MENU_MODE=0
usage() {
    cat <<'USAGE'
Usage : ./start-direct.sh [options] [mode]
  Modes (profils) :
    faketrx-qemu   coeur + BTS#0 QEMU + BTS#1 faketrx (defaut)
    faketrx        coeur + fake_trx + trxcon + mobile
    qemu           pipeline Calypso QEMU seul
    virtphy        coeur + osmo-bts-virtual + virtphy
    noproc         coeur seul (no-process)
    core           alias noproc
    hybrid         alias faketrx-qemu
    hw             SDR physique
  Options :
    --list              affiche le plan (delegue a run.sh --list)
    --dry-run           deroule sans effet de bord
    --profile <nom>     force le profil
    --stop              arrete la pile (delegue a run.sh --stop)
    --status            interroge l'etat (delegue a run.sh --status)
    --force             relance meme les modules deja demarres
    --verbose           montre la sortie des modules
    --check-paths       verifie les dependances declarees
    --wan               monte le WAN a N noeuds (1 a 9) AVANT run.sh et demande :
                          nombre de noeuds, IP de chaque noeud, indicatif de
                          chaque noeud, numero du noeud construit par ce lancement
    --wan-nodes "1:IP:IND ..."   meme chose sans question (scriptable)
    --wan-id N          numero du noeud local (sinon deduit des IP locales)
    --wan-conf FICHIER  table a lire/ecrire (defaut /etc/osmo-wan.conf)
    --node N            numero de CE noeud, 1 a 9. DEDUIT AUTOMATIQUEMENT s'il
    --menu              demande les choix au lieu de les deviner : profil,
                        noeud, operateur, inter-STP, WAN, regeneration des
                        configs, outillage DSP. Les valeurs proposees sont
                        celles que le lanceur aurait prises tout seul, donc
                        valider sans rien changer equivaut a ne pas passer
                        l'option. Sans terminal, l'option est ignoree.
    --dsp               outillage d'inspection du Calypso : pont I/Q
                        calypso-ipc-device + osmo-trx-ipc, trace asm de QEMU et
                        croisement mailbox x desassemblage DSP. ETEINT par
                        defaut : ces trois-la servent a debugger le modele, pas
                        a faire tourner un banc, et ils coutent un processus,
                        deux fenetres et un journal qui grossit sans fin.
    --regen             regenere les configs depuis les gabarits (par defaut on
                        CONSERVE celles deja en place : run.sh les ecraserait)
                        est omis : environnement, puis /etc/osmo-role, puis la
                        table WAN comparee aux adresses locales. Cette option
                        ne sert qu'a forcer. Reecrit son identite SS7
                        (point codes 1.<noeud><op>.<role>, routing contexts) et
                        pointe son ASP sur l'inter-STP. Une seule ISO suffit
                        alors pour les neuf noeuds - le numero se choisit ici.
    --op N              operateur porte par ce noeud (defaut 1)
    --hub-ip ADRESSE    inter-STP a joindre (defaut : selon docker ou VM)
    --air-mesh[=PORT]   maillage de BURSTS entre noeuds : le milieu radio
                        devient commun et un mobile peut entendre - et choisir -
                        la BTS d'un autre noeud. Les pairs viennent de la table
                        WAN, la portee de data/air-mesh.txt. Declare deux
                        mobiles de plus pour s'y brancher (voir pont/airmesh.py).
    --virtualbox[=N]    WAN entre CETTE machine et N-1 VM VirtualBox (implique
                        --wan). A lancer depuis l'hote, pas depuis une VM.
    --vbox-node N       numero de noeud porte par cette machine (defaut 1)
    --mobile            client de couche 2 = mobile (defaut) -- pile L2/L3
                        complete derriere le firmware QEMU
    --ccch_scan         client de couche 2 = ccch_scan -- ecoute le CCCH
    --bcch_scan         client de couche 2 = bcch_scan -- releve les BCCH
    --cell_log          client de couche 2 = cell_log -- journal de cellules
                        Ces quatre-la sont EXCLUSIFS et ECRASENT le mobile de
                        QEMU : ils prennent sa socket L1CTL et sa VTY.
    -h, --help          cette aide

  Sans --wan : aucun WAN. Avec --wan le profil reste faketrx-qemu (hybride,
  1 faketrx + 1 QEMU Calypso), qui est deja le defaut de ce script.
  Composer <indicatif><numero> joint ce numero sur le noeud correspondant.
Toute variable CALYPSO_* passee en prefixe est transmise a run.sh / QEMU :
  CALYPSO_MODE=native ./start-direct.sh
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION=list ;;
        --dry-run)     DRY=1 ;;
        --profile)     if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                           printf '%s\n\n' "--profile attend un nom de profil" >&2
                           usage >&2; exit 2
                       fi
                       PROFILE="$2"; shift ;;
        --stop)        ACTION=stop ;;
        --status)      ACTION=status ;;
        --force)       FORCE=1 ;;
        --verbose)     VERBOSE=1 ;;
        --check-paths) ACTION=checkpaths ;;
        --wan)         WAN_MESH=1 ;;
        --wan=*)       WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-nodes)   WAN_MESH=1; WAN_NODES="${2:-}"; shift ;;
        --wan-nodes=*) WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-id)      WAN_MESH=1; WAN_NODE_ID="${2:-}"; shift ;;
        --wan-id=*)    WAN_MESH=1; WAN_NODE_ID="${1#*=}" ;;
        --wan-conf)    WAN_CONF_FILE="${2:-}"; shift ;;
        --wan-conf=*)  WAN_CONF_FILE="${1#*=}" ;;
        --virtualbox)   WAN_MESH=1; VBOX_INTERCO=1 ;;
        --virtualbox=*) WAN_MESH=1; VBOX_INTERCO=1; VBOX_NODES="${1#*=}" ;;
        --vbox-node)    VBOX_HOST_NODE="${2:-1}"; shift ;;
        --vbox-node=*)  VBOX_HOST_NODE="${1#*=}" ;;
        --node)         NODE_ID="${2:-}"; shift ;;
        --node=*)       NODE_ID="${1#*=}" ;;
        --air-mesh)     AIR_MESH=1 ;;
        --air-mesh=*)   AIR_MESH=1; AIRMESH_PORT="${1#*=}" ;;
        --regen)        REGEN_GABARITS=1 ;;
        --dsp)          DSP_MODE=1 ;;
        --menu)         MENU_MODE=1 ;;
        --op)           NODE_OP="${2:-1}"; shift ;;
        --op=*)         NODE_OP="${1#*=}" ;;
        --hub-ip)       HUB_IP="${2:-}"; shift ;;
        --hub-ip=*)     HUB_IP="${1#*=}" ;;
        --mobile|--ccch_scan|--bcch_scan|--cell_log)
                       # run_modules/70-l2.sh gere deja les quatre clients via
                       # CALYPSO_L2_CLIENT ; il manquait de quoi les choisir.
                       # Un seul a la fois : ils se disputeraient la socket
                       # L1CTL (/tmp/osmocom_l2) et la VTY 4247, et le second
                       # lance resterait muet pour toujours.
                       _l2c="${1#--}"
                       if [ -n "${L2_CLIENT_CHOISI:-}" ] && \
                          [ "$L2_CLIENT_CHOISI" != "$_l2c" ]; then
                           printf '%s\n\n' \
                             "--$_l2c et --$L2_CLIENT_CHOISI sont exclusifs : un seul client de couche 2" >&2
                           usage >&2; exit 2
                       fi
                       L2_CLIENT_CHOISI="$_l2c" ;;
        -h|--help)     usage; exit 0 ;;
        faketrx-qemu|faketrx|qemu|virtphy|noproc|core|hybrid|hw)
            PROFILE="$1"
            [ "$PROFILE" = "hybrid" ] && PROFILE=faketrx-qemu
            [ "$PROFILE" = "core" ]   && PROFILE=noproc
            ;;
        *) printf 'option inconnue : %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
# --- ou tourne-t-on ? ---------------------------------------------------------
# La question n'est pas cosmetique : le plan d'adressage EN DEPEND.
#   docker  → l'inter-STP est le conteneur osmo-inter-stp (172.20.0.10), le
#             noeud a deja son IP quand les demons demarrent.
#   VM/ISO  → l'inter-STP est une machine a part (192.168.1.49 sur le banc,
#             ou une host-only 192.168.56.x selon le montage), et l'adresse
#             du noeud vient du DHCP : elle peut manquer au lancement.
# Prendre l'un pour l'autre donne un ASP qui ne s'attache jamais, avec pour
# seule trace un "connection refused" vers une adresse inexistante ici.
#
# /.dockerenv seul ne suffit pas - il est vrai dans n'importe quel conteneur.
# On exige aussi /etc/docker-entrypoint-cmd, que scripts/entrypoint.sh depose :
# c'est ce couple qui identifie un conteneur DE CE DEPOT.
detect_runtime_env() {
    if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then
        echo docker; return
    fi
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        echo docker; return
    fi
    # systemd-detect-virt SORT EN CODE 1 quand il ne trouve rien. Un
    # "$(cmd || echo none)" produit alors DEUX lignes - la sortie "none" du
    # programme, plus celle du repli - et aucun motif ne correspond : une
    # machine physique se retrouvait classee "vm". On ignore le code de
    # sortie et on ne garde que la premiere ligne.
    local v
    v="$(systemd-detect-virt 2>/dev/null | head -1)" || true
    v="${v:-none}"
    case "$v" in
        oracle|kvm|qemu|vmware|microsoft|xen|bochs|parallels) echo vm ;;
        none|"") echo bare ;;
        *) echo vm ;;
    esac
}
RUNTIME_ENV="${RUNTIME_ENV:-$(detect_runtime_env)}"

# --- quel noeud sommes-nous ? --------------------------------------------------
# Le numero de noeud decide des point codes, du routing context et de l'indicatif.
# Le taper a chaque lancement est une occasion de se tromper - et une erreur ici
# ne se voit pas : la pile demarre, elle presente simplement au hub l'adresse SS7
# d'un autre noeud. On le deduit donc, et on DIT d'ou vient la reponse.
#
# Ordre, du plus explicite au plus deduit. Le premier qui repond gagne :
#   1. --node passe en ligne de commande
#   2. l'environnement - c'est ainsi que start.sh le transmet au conteneur
#   3. /etc/osmo-role, fige dans l'image par build-iso.sh --node N
#   4. la table WAN : l'adresse de ce noeud y figure, et nous l'avons
#   5. rien - on ne touche alors PAS a l'identite SS7, plutot que d'en inventer une
# Renvoie "numero|origine". Pas deux variables : la fonction est appelee dans
# une substitution de commande, donc dans un SOUS-SHELL - toute variable qu'elle
# poserait y resterait, et l'appelant n'afficherait "?" qu'apres coup.
detect_node_id() {
    local n

    n="${WAN_NODE_ID:-${OSMO_WAN_NODE:-}}"
    if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|environnement"; return 0; fi

    if [ -r /etc/osmo-role ]; then
        n="$(awk -F= '/^OSMO_WAN_NODE=/{print $2}' /etc/osmo-role 2>/dev/null | tr -d ' \r')"
        if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|/etc/osmo-role"; return 0; fi
    fi

    # La table WAN et nos propres adresses : c'est la source la plus fiable en VM,
    # ou une seule ISO sert les neuf noeuds et ou seule l'IP les distingue.
    local conf="${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    if [ -r "$conf" ] && [ -r "$HERE/network/wan-nodes.sh" ]; then
        n="$(
            # Sous-shell : wan-nodes.sh pose des variables et des tableaux qu'on
            # ne veut pas voir deborder dans le lanceur.
            set +u
            . "$HERE/network/wan-nodes.sh" 2>/dev/null || exit 0
            WAN_NODE_ID=0
            wan_nodes_load "$conf" 2>/dev/null || exit 0
            wan_nodes_detect_self 2>/dev/null || exit 0
            printf '%s' "$WAN_NODE_ID"
        )"
        if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|table WAN (IP locale)"; return 0; fi
    fi

    return 1
}

NODE_ID_SRC=""
if [ -n "$NODE_ID" ]; then
    NODE_ID_SRC="option --node"
else
    _detected="$(detect_node_id || true)"
    NODE_ID="${_detected%%|*}"
    [ -n "$NODE_ID" ] && NODE_ID_SRC="${_detected#*|}"
    unset _detected
fi
# L'adresse du hub arrive par le MEME chemin que le noeud : start.sh la pose
# dans l'environnement du conteneur (OSMO_HUB_IP, et INTER_STP_IP pour les
# scripts plus anciens). Sans ce repli, HUB_IP restait vide alors que la
# reponse etait deja la : un conteneur lance par docker exec -d n'a pas de
# terminal, la question du hub est donc sautee et l'adresse restait nulle
# jusqu'aux configs. Le repli est pose ici, apres la boucle d'options, pour
# que --hub-ip garde le dernier mot.
[ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-${INTER_STP_IP:-}}"
# Pour les scripts qui ne connaissent que deux mondes : docker, ou tout le reste.
case "$RUNTIME_ENV" in docker) NODE_MODE=docker ;; *) NODE_MODE=native ;; esac

# --- affichage (identique a run.sh) -------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_Z=$'\033[0m'
else
    TTY=0
    C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_CYAN=""; C_BOLD=""; C_Z=""
fi
say_begin() {
    if [ $TTY -eq 1 ]; then
        printf '[ %s.. %s] %s' "$C_DIM" "$C_Z" "$1"
    else
        printf '[ .. ] %s\n' "$1"
    fi
}
say_end() { # $1=tag $2=couleur $3=libelle $4=detail
    if [ $TTY -eq 1 ]; then printf '\r\033[K'; fi
    printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
    [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"
    printf '\n'
}
banner() {
    echo -e "${C_CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Calypso GSM - bootstrap → run.sh                   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${C_Z}"
}
# --- 1. configuration ---------------------------------------------------------
# [2026-08-03] globals.conf - les reglages reseau (MCC/MNC/ARFCN/KI/IMSI/A5...).
# Genere par ./generate_configs.sh cote hote ; ici on se contente de le lire.
# L'idiome ":=" qu'il utilise laisse gagner toute variable deja posee, donc
#     ARFCN=520 ./start-direct.sh
# surcharge sans toucher au fichier.
[ -r "$HERE/globals.conf" ] && { set -a; . "$HERE/globals.conf"; set +a; }

say_begin "Chargement de l'environnement"
if [ -f "$HERE/environment/load.env" ]; then
    set -a; . "$HERE/environment/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "environment/load.env"
elif [ -f "$HERE/env/load.env" ]; then
    set -a; . "$HERE/env/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "env/load.env"
else
    # Fallback minimal (chemins typiques du depot)
    : "${GSM_ROOT:=/opt/GSM}"
    : "${NITB_TREE:=$HERE}"
    if [ -x "$HERE/run.sh" ]; then
        : "${OQC_ROOT:=$HERE}"
    elif [ -x "$HERE/../qemu-src/run.sh" ]; then
        : "${OQC_ROOT:=$(cd "$HERE/../qemu-src" && pwd)}"
    else
        : "${OQC_ROOT:=$GSM_ROOT/qemu-src}"
    fi
    say_end " OK " "$C_OK" "Chargement de l'environnement" "fallback minimal"
fi
: "${RUN_DIR:=/run/osmo-direct}"
# Repli si load.env est absent. Les journaux restent sous RUN_DIR (tmpfs) :
# le defilement tmux en depend - cf. environment/paths.env.
: "${LOG_DIR:=$RUN_DIR/logs}"
# A5/1 par defaut : c'est le chiffrement que la maquette valide de bout en bout
# (Calypso ↔ BTS), et ce que start.sh impose deja dans son hand-off vers ce
# script. Un defaut a "a5 0" faisait diverger le lancement direct du lancement
# par start.sh - meme stack, deux chiffrements, selon la porte d'entree.
#
# ATTENTION : globals.conf est lu AVANT et fait autorite sur cette variable (son
# en-tete le dit). Ce ":=" n'est donc qu'un repli quand globals.conf est absent
# - l'ISO, un conteneur nu. La valeur qui s'applique en pratique vient de la-bas,
# et c'est pourquoi elle y a ete changee aussi.
: "${ENCRYPTION:=a5 1}"
# Le pont TRX par defaut : il REMPLACE la chaine IQ (osmo-trx-ipc,
# calypso-ipc-device, si_bridge, demod-bridge) par un transceiver unique qui
# decode le DL et encode l'UL. C'est le mode que start.sh passe deja en
# hand-off ; le lancement direct s'aligne.
# CALYPSO_BRIDGE n'est pas declare dans globals.conf (les CALYPSO_* "passent au
# travers, intact" d'apres son en-tete) : l'environnement gagne donc vraiment.
#   CALYPSO_BRIDGE=ipc  ./start-direct.sh   -> le pont IPC-MS a la place
#   CALYPSO_BRIDGE=none ./start-direct.sh   -> ni l'un ni l'autre, chaine IQ
: "${CALYPSO_BRIDGE:=pont}"

# ── LES DEFAUTS DU PONT LEGIT, EN := (SURCHARGEABLES), PAS EN export FORCE ────
# Ces quatre variables gouvernent le shunt DSP « legit » du Calypso. On les pose
# ICI, APRES le sourcing de environment/load.env (donc de modes.env) : si un mode
# les a deja fixees, son choix gagne ; sinon ce sont les defauts. Le ":=" laisse
# l'environnement l'emporter (VAR=... ./start-direct.sh), ce qu'un "export VAR=0"
# interdirait. Le set -a les exporte vers QEMU/le shunt sans ligne "export VAR=".
#   CALYPSO_SHUNT_NO_CANNED=0  le SCH reste REEL (le pont le decode/publie)
#   CALYPSO_CANNED=1           SI bakes cote shunt (pas de dependance grgsm)
#   CALYPSO_SKIP_DSP=1         on court-circuite le DSP TI (le pont fait le canal)
#   CALYPSO_DSP_SHUNT_LEGIT=1  chemin « legit » du shunt (celui qui campe et LU)
set -a
: "${CALYPSO_SHUNT_NO_CANNED:=0}"
: "${CALYPSO_CANNED:=1}"
: "${CALYPSO_SKIP_DSP:=1}"
: "${CALYPSO_DSP_SHUNT_LEGIT:=1}"
set +a

: "${MS_COUNT:=2}"
: "${HOST_IP:=127.0.0.1}"
mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb 2>/dev/null || true
# --- 2. detection des chemins / binaires --------------------------------------
say_begin "Resolution de run.sh"
# [2026-08-08] Le chemin etait cable en dur ICI, ce qui rendait MORTE toute la
# resolution de OQC_ROOT faite plus haut (trois candidats testes pour rien) et
# contredisait le contrat annonce en tete de fichier ("la ligne de commande
# gagne toujours") : RUN_SH etait la seule variable non surchargeable.
# Ordre : RUN_SH explicite > OQC_ROOT resolu > chemin historique.
: "${RUN_SH:=${OQC_ROOT:+$OQC_ROOT/run.sh}}"
: "${RUN_SH:=/opt/GSM/qemu-src/run.sh}"
if [ ! -x "$RUN_SH" ]; then
    say_end "FAIL" "$C_KO" "Resolution de run.sh" "$RUN_SH introuvable ou non executable"
    printf '       %s→ Verifiez que /opt/GSM/qemu-src/run.sh existe et est executable%s\n' "$C_DIM" "$C_Z"
    exit 1
fi
say_end " OK " "$C_OK" "Resolution de run.sh" "$RUN_SH"
RUN_ROOT="$(dirname "$RUN_SH")"
# ══ --menu : on DEMANDE, au lieu de deviner ════════════════════════════════
# Le lanceur resout tout seul le profil, le noeud, l'inter-STP, le WAN. C'est ce
# qu'il faut pour une ISO qui demarre sans personne devant. Mais devant un banc,
# la meme resolution silencieuse oblige a relire le script pour savoir ce qui a
# ete choisi - et a relancer avec les bonnes options quand ce n'etait pas ca.
#
# Ce menu ne CHANGE aucune regle : il PRE-REMPLIT chaque question avec la valeur
# que le lanceur aurait prise seul, et n'ecrit que ce que l'operateur modifie.
# Valider tout sans rien toucher donne donc exactement le lancement par defaut.
#
# Il s'efface de lui-meme quand personne ne peut repondre (pas de terminal,
# --dry-run, NO_MENU=1 que start.sh pose devant un conteneur) : une question
# sans lecteur, c'est un lancement qui se fige sans le dire.
menu_interactif() {
    [ "${MENU_MODE:-0}" -eq 1 ] || return 0
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ "$DRY" -eq 1 ] && return 0
    [ -t 0 ] || { printf "  %smenu%s       ignore : pas de terminal\n" "${C_DIM:-}" "${C_Z:-}"; return 0; }

    local has_wt=0
    command -v whiptail >/dev/null 2>&1 && has_wt=1

    # Une question, une valeur par defaut, une reponse. Sans whiptail on
    # retombe sur read : une ISO minimale n'a pas toujours newt.
    _ask() {   # $1 = titre  $2 = question  $3 = defaut
        local rep
        if [ "$has_wt" -eq 1 ]; then
            rep="$(whiptail --title "$1" --inputbox "$2" 11 70 "$3" 3>&1 1>&2 2>&3)" || rep="$3"
        else
            printf "  %s [%s] : " "$2" "$3" >&2
            read -r rep </dev/tty || rep=""
        fi
        printf "%s" "${rep:-$3}"
    }
    _yesno() { # $1 = titre  $2 = question  $3 = defaut (0=oui 1=non)
        if [ "$has_wt" -eq 1 ]; then
            if [ "$3" -eq 0 ]; then whiptail --title "$1" --yesno "$2" 10 70; else
                whiptail --title "$1" --defaultno --yesno "$2" 10 70; fi
            return $?
        fi
        local d="o" rep
        [ "$3" -eq 0 ] || d="n"
        printf "  %s [%s] : " "$2" "$d" >&2
        read -r rep </dev/tty || rep=""
        case "${rep:-$d}" in [oOyY]*) return 0 ;; *) return 1 ;; esac
    }

    printf "  %smenu%s       --menu : les defauts proposes sont ceux du lancement automatique\n" \
        "${C_DIM:-}" "${C_Z:-}"

    PROFILE="$(_ask "Profil" \
        "Profil de pile :\n  faketrx-qemu  coeur + BTS QEMU + BTS faketrx (defaut)\n  faketrx  qemu  virtphy  noproc  hw" \
        "$PROFILE")"

    # Le noeud est deja resolu plus haut (--node, environnement, /etc/osmo-role,
    # table WAN) : on propose CE resultat, pas un 1 arbitraire.
    NODE_ID="$(_ask "Noeud SS7" \
        "Numero de ce noeud (1-9). Il fixe le point code 1.<noeud><op>.<role>,\nle routing context et les MSISDN <noeud>00<op><rang>." \
        "${NODE_ID:-1}")"
    NODE_OP="$(_ask "Operateur" "Operateur porte par ce noeud (1-9) :" "${NODE_OP:-1}")"
    HUB_IP="$(_ask "Inter-STP" \
        "Adresse du hub SS7 (vide = ne pas toucher au remote-ip en place) :" \
        "${HUB_IP:-$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)}")"

    _yesno "WAN" "Monter le maillage WAN entre noeuds ?" "$([ "${WAN_MESH:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && WAN_MESH=1 || WAN_MESH=0

    _yesno "Configurations" \
        "Regenerer /etc/osmocom et /etc/asterisk depuis les gabarits ?\n\nLa pile sera ARRETEE, les fichiers sauvegardes, puis reecrits\navec l'identite du noeud ci-dessus." \
        "$([ "${REGEN_GABARITS:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && REGEN_GABARITS=1 || REGEN_GABARITS=0

    _yesno "Outillage DSP" \
        "Activer l'inspection du Calypso ?\n\ncalypso-ipc-device + osmo-trx-ipc, trace asm, fenetre mailbox.\nUtile pour debugger le modele, inutile pour faire tourner un banc." \
        "$([ "${DSP_MODE:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && DSP_MODE=1 || DSP_MODE=0

    printf "  %smenu%s       profil=%s  noeud=%s  op=%s  hub=%s  wan=%s  regen=%s  dsp=%s\n" \
        "${C_DIM:-}" "${C_Z:-}" "$PROFILE" "${NODE_ID:-?}" "$NODE_OP" \
        "${HUB_IP:-inchange}" "$WAN_MESH" "$REGEN_GABARITS" "$DSP_MODE"
}
menu_interactif

# Profil → mapping vers les profils attendus par run.sh
case "$PROFILE" in
    faketrx-qemu|hybrid) CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu ;;
    faketrx)             CALYPSO_PROFILE=faketrx;  MODE=faketrx ;;
    qemu)                CALYPSO_PROFILE=calypso;  MODE=qemu ;;
    virtphy)             CALYPSO_PROFILE=faketrx;  MODE=virtphy; PHY_MODE=virtphy ;;
    noproc|core)         CALYPSO_PROFILE=core;     MODE=noproc; RUN_NO_PROCESS=1 ;;
    hw)                  CALYPSO_PROFILE=faketrx;  MODE=hw; PHY_MODE=trx ;;
    *)                   CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu; PROFILE=faketrx-qemu ;;
esac
export CALYPSO_PROFILE MODE
export PHY_MODE="${PHY_MODE:-faketrx}"
export RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
export ENCRYPTION MS_COUNT HOST_IP
# Client de couche 2 : l'option de ligne de commande ECRASE tout, et elle est
# EXPORTEE -- une valeur posee sans export ne traverse pas jusqu'a run.sh,
# defaut deja paye sur ENCRYPTION (cf. generate_configs.sh).
if [ -n "${L2_CLIENT_CHOISI:-}" ]; then
    CALYPSO_L2_CLIENT="$L2_CLIENT_CHOISI"
fi
export CALYPSO_L2_CLIENT="${CALYPSO_L2_CLIENT:-mobile}"
export LOG_DIR RUN_DIR
# --- 3. validation des chemins critiques --------------------------------------
say_begin "Validation des chemins"
path_ok=1
_check() {
    local name="$1" val="${!1:-}"
    if [ -z "$val" ]; then
        printf '\n       %s%s non defini%s\n' "$C_DIM" "$name" "$C_Z"
        path_ok=0
    elif [ -e "$val" ]; then
        :
    else
        printf '\n       %s%s introuvable : %s%s\n' "$C_DIM" "$name" "$val" "$C_Z"
        path_ok=0
    fi
}
# Variables optionnelles selon le profil ; on ne bloque que si presentes et cassees
for v in QEMU_BIN FIRMWARE_ELF DSP_PROM0 OSMOCON; do
    # `[ -n x ] && _check || true` avalait le verdict : _check pouvait poser
    # path_ok=0 sans que la boucle ne le laisse remonter. Forme explicite.
    if [ -n "${!v:-}" ]; then _check "$v"; fi
done
if [ $path_ok -eq 1 ]; then
    say_end " OK " "$C_OK" "Validation des chemins"
else
    say_end "WARN" "$C_SK" "Validation des chemins" "certains chemins manquent (run.sh verifiera)"
fi
# --- 4. generation des configs mobile -----------------------------------------
# MS#1 (QEMU / mobile principal) et MS#2 (faketrx side-car) pour le profil hybrid.
BB_DIR="/root/.osmocom/bb"
mkdir -p "$BB_DIR"
# Sources possibles pour le template mobile
MS_TEMPLATE=""
for t in \
    "${OQC_ROOT:-}/cfgs/mobile_group1.cfg" \
    "$RUN_ROOT/cfgs/mobile_group1.cfg" \
    "$HERE/configs/mobile.cfg.template" \
    "$HERE/configs/mobile.cfg" \
    "$BB_DIR/mobile_group1.cfg" \
    "$BB_DIR/mobile.cfg"
do
    if [ -f "$t" ]; then MS_TEMPLATE="$t"; break; fi
done
generate_mobile_cfg() {
    local dest="$1" vty_port="$2" l2sock="$3" sapsock="$4" arfcn="$5" imsi="$6" ki="$7"
    # [2026-08-08] Peripheriques ALSA PAR MOBILE. Le template porte
    # gsm_out/gsm_in pour tout le monde ; laisser ca remettrait les deux
    # mobiles sur le meme sink et la meme source, c'est-a-dire la boucle
    # audio qu'on vient d'ouvrir (cf /etc/asound.conf).
    local aout="${8:-gsm_out}" ain="${9:-gsm_in}"
    # [2026-08-08] GARDE-FOU : la liste de templates contient $BB_DIR/mobile.cfg,
    # qui est aussi une DESTINATION. Si c'est lui qui est retenu, `sed "$tpl" >
    # "$dest"` avec tpl == dest fait tronquer le fichier par le shell AVANT que
    # sed ne le lise : on produit un mobile.cfg VIDE et le mobile ne demarre plus.
    # On bascule alors sur le template de secours plutot que de se detruire.
    local tpl="$MS_TEMPLATE"
    if [ -n "$tpl" ] && [ "$tpl" -ef "$dest" ] 2>/dev/null; then
        printf '\n       %sMS_TEMPLATE == destination (%s) : template de secours%s\n' \
            "$C_DIM" "$dest" "$C_Z"
        tpl=""
    fi
    if [ -n "$tpl" ]; then
        sed \
            -e "s|bind 127.0.0.1 424[0-9]|bind 127.0.0.1 ${vty_port}|" \
            -e "s|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket ${l2sock}|" \
            -e "s|sap-socket /tmp/osmocom_sap[_0-9]*|sap-socket ${sapsock}|" \
            -e "s|stick [0-9]*|stick ${arfcn}|" \
            -e "s|^\([[:space:]]*\)imsi .*|\1imsi ${imsi}|" \
            -e "s|^\([[:space:]]*\)imei .*|\1imei $(rand_imei) 0|" \
            -e "s|^\([[:space:]]*\)ki .*|\1ki comp128 ${ki}|" \
            -e "s|alsa-output-dev .*|alsa-output-dev ${aout}|" \
            -e "s|alsa-input-dev .*|alsa-input-dev ${ain}|" \
            "$tpl" > "$dest"
    else
        # Template minimal de secours
        cat > "$dest" <<EOF
!
! mobile.cfg genere par start-direct.sh (secours)
!
log stderr
 logging color 1
 logging print category 1
 logging timestamp 0
!
line vty
 no login
 bind 127.0.0.1 ${vty_port}
!
ms 1
 layer2-socket ${l2sock}
 sap-socket ${sapsock}
 sim reader
 imsi ${imsi}
 ki comp128 ${ki}
 network-selection-mode auto
 stick ${arfcn}
!
EOF
    fi
}
# ⚠️ [2026-08-08, resolu le 26/08] LE RUN N'UTILISE PAS mobile.cfg POUR MS#1.
# Le mobile Calypso tourne avec
#     mobile -c /root/.osmocom/bb/mobile_group1.cfg
# alors qu'on ne generait ici que mobile.cfg. mobile_group1.cfg, lui, est COPIE
# tel quel par qemu-src (run_modules/20-mobile-cfg.sh, depuis $QEMU_TREE/cfgs) :
# un fichier statique, jamais derive de l'operateur. Il porte donc l'identite de
# l'operateur 1 - IMSI 001010001000001, ARFCN 514 - quel que soit l'operateur.
#
# Constate sur le banc, operateur 2 : le HLR attend 002010002000001, la BTS
# emet sur 516, et le mobile se presentait avec 001010001000001 sur 514.
#     Mobile Subscriber of MS '1':
#      IMSI: 001010001000001
#      Status: U2_NOT_UPDATED  IMSI detached  LAI: invalid
#      Registered PLMN: MCC-MNC 001-01
# Tout le reste etait juste - clefs, MSISDN, point codes, ARFCN des BTS - et
# l'abonne restait detache, parce que la seule carte SIM qui compte n'etait
# generee nulle part.
#
# On ecrit donc MS#1 dans LES DEUX fichiers. mobile.cfg reste la reference
# (d'autres modules la lisent), mobile_group1.cfg est celui que le lanceur
# ouvre. Verifier lequel tourne, avant de croire un reglage pose ici :
#     pgrep -a mobile
# ── IMSI et Ki des MS : le plan du HLR, pas celui de l'operateur 1 ──────────
# Ces valeurs etaient ecrites EN DUR sur le PLMN de l'operateur 1 (001-01) et
# sur son numero d'abonne. Sur l'operateur 2, dont le reseau diffuse un autre
# MCC, le mobile presentait donc l'IMSI d'un abonne d'un autre pays : ni le MSC
# ni le HLR n'ont de fiche a ce numero, le Location Updating reste sans reponse,
# et l'on cherche la panne dans la BTS alors que la pile entiere est debout.
# Le plan est celui de start.sh (section "HLR subscribers") :
#     IMSI = MCC MNC <operateur sur 4 chiffres> <index du MS sur 6 chiffres>
#     Ki   = 00112233445566778899aabbccdd <index du MS> <operateur>
# MCC et MNC sont relus dans la configuration REELLEMENT deployee - c'est elle
# que la BTS diffuse - et non redevines a partir d'une convention.
MS_OP_ID="${OPERATOR_ID:-1}"
MS_MCC="$(awk '$1=="network" && $2=="country" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
MS_MNC="$(awk '$1=="mobile" && $2=="network" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
[ -n "$MS_MCC" ] || MS_MCC="$(printf '%03d' "$MS_OP_ID")"
[ -n "$MS_MNC" ] || MS_MNC="01"
ms_imsi() { printf '%s%s%04d%06d' "$MS_MCC" "$MS_MNC" "$MS_OP_ID" "$1"; }

# ── LE QUATRIEME PROVISIONNEUR ──────────────────────────────────────────────
# run.sh embarque son propre module d'abonnes (run_modules/21-abonnes-hlr.sh,
# dans qemu-src). Il calcule son IMSI comme MCC+MNC+operateur+rang - la meme
# formule que nous - mais lit MCC et MNC dans /etc/osmocom/osmo-msc.cfg via un
# chemin qui n'aboutit pas toujours ; il retombe alors sur ses defauts, 001 et
# 01. Sur l'operateur 2 il fabriquait donc 001010002000001 : un abonne que
# personne ne presente, avec en prime un MSISDN de l'ancien plan (20001), qui
# RETIENT ce numero et empeche le bon abonne de le recuperer.
#
# Il honore MCC et MNC depuis l'environnement. En les posant, son IMSI devient
# exactement celui que start.sh a deja provisionne - et son propre controle
# d'etat (mod_abonnes_hlr_status) le trouve present, donc il ne fait rien.
# On neutralise ainsi un doublon par son idempotence, sans toucher a qemu-src.
export MCC="${MCC:-$MS_MCC}"
export MNC="${MNC:-$MS_MNC}"

# ── Le plan radio : on le LIT, on ne le recalcule pas ───────────────────────
# generate_configs.sh l'ecrit dans /etc/osmocom/radio-plan.env en meme temps
# que les configurations. Le relire ici garantit que le mobile s'accorde sur
# ce que la BTS diffuse VRAIMENT - et non sur une formule recopiee qui finira
# par diverger, comme l'ont fait l'unit-id, l'ARFCN et l'IMSI avant elle.
# Les replis restent, pour un banc monte sans ce fichier.
if [ -r /etc/osmocom/radio-plan.env ]; then
    # shellcheck disable=SC1091
    . /etc/osmocom/radio-plan.env
    printf '  %splan radio%s  lu dans /etc/osmocom/radio-plan.env\n' "${C_DIM:-}" "${C_Z:-}"
fi

# ── Les deux canaux radio, et a qui chaque MS s'accroche ────────────────────
# MS#1 et MS#2 avaient leur ARFCN ecrit EN DUR, 514 et 516 : les valeurs de
# l'operateur 1, et de lui seul. Sur l'operateur 2 la BTS principale passe a
# 516 et le side-car y restait aussi : deux cellules sur la meme frequence,
# leurs bursts melanges dans un milieu ou fake_trx apparie par frequence.
# Le mobile envoyait ses RACH, aucune Immediate Assignment ne revenait, et
# MS#1 restait accroche a 514 ou plus rien n'emettait.
#
# MS#1 suit la BTS principale, dont l'ARFCN est lu dans la configuration
# REELLEMENT deployee - c'est le BSC qui en decide et qui l'impose a la BTS
# par OML, donc c'est la qu'est la verite.
MS_ARFCN1="${PLAN_ARFCN:-}"
[ -n "$MS_ARFCN1" ] || MS_ARFCN1="$(awk '/^ bts 0$/{b=1} b && /^ *arfcn /{print $2; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
[ -n "$MS_ARFCN1" ] || MS_ARFCN1=$(( 512 + MS_OP_ID * 2 ))

# MS#2 suit le side-car. Celui-la, c'est NOUS qui le decidons : le module
# 13-sidecar-cfg.sh de qemu-src lit SC_ARFCN et SC_UNIT_ID dans
# l'environnement (run_modules/_lib/radio.sh : « : "${SC_ARFCN:=516}" »).
# Les poser ici evite de modifier qemu-src, et garde une seule source par
# valeur - les memes formules que generate_configs.sh.
export SC_ARFCN="${SC_ARFCN:-${PLAN_ARFCN_BTS1:-$(( 612 + MS_OP_ID * 2 ))}}"
export SC_UNIT_ID="${SC_UNIT_ID:-${PLAN_UNIT_ID_BTS1:-$(( 6000 + MS_OP_ID * 10 + 2 ))}}"
MS_ARFCN2="$SC_ARFCN"
ms_ki()   { printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x %02x' "$1" "$MS_OP_ID"; }

# IMEI tire au hasard, cle de Luhn calculee - un par MS, jamais deux identiques
# dans une meme trace.
rand_imei() {
    local body d i sum=0 dbl parity
    body="35892500$(printf '%06d' "$(( (RANDOM << 15 | RANDOM) % 1000000 ))")"
    for (( i = ${#body} - 1; i >= 0; i-- )); do
        d=${body:i:1}
        parity=$(( (${#body} - 1 - i) % 2 ))
        if [ "$parity" -eq 0 ]; then
            dbl=$(( d * 2 )); [ "$dbl" -gt 9 ] && dbl=$(( dbl - 9 ))
            sum=$(( sum + dbl ))
        else
            sum=$(( sum + d ))
        fi
    done
    printf '%s%d' "$body" "$(( (10 - sum % 10) % 10 ))"
}

printf '  %sPLMN MS%s    MCC %s  MNC %s  operateur %s  ->  IMSI %s / %s\n' \
    "${C_DIM:-}" "${C_Z:-}" "$MS_MCC" "$MS_MNC" "$MS_OP_ID" "$(ms_imsi 1)" "$(ms_imsi 2)"
printf '  %sradio%s      MS#1 sur ARFCN %s (BTS principale)   MS#2 sur ARFCN %s (side-car, unit-id %s)\n' \
    "${C_DIM:-}" "${C_Z:-}" "$MS_ARFCN1" "$MS_ARFCN2" "$SC_UNIT_ID"

say_begin "Generation mobile MS#1"
MS1_CFG="${MOBILE_CFG_MS1_PATH:-$BB_DIR/mobile.cfg}"
generate_mobile_cfg "$MS1_CFG" \
    4247 \
    /tmp/osmocom_l2 \
    /tmp/osmocom_sap_1 \
    "$MS_ARFCN1" \
    "$(ms_imsi 1)" \
    "$(ms_ki 1)"
# La copie que le lanceur ouvre reellement. On la REGENERE plutot que de la
# copier : generate_mobile_cfg fixe aussi le port VTY, les sockets et l'ARFCN,
# et un simple cp propagerait le fichier statique de qemu-src.
# ── ET ON EMPECHE QU'IL SOIT ECRASE ─────────────────────────────────────
# Ecrire ce fichier ne suffit pas : run.sh le REECRIT juste apres. Son module
# 20-mobile-cfg.sh copie MOBILE_CFG_SRC par-dessus, et ce chemin vaut par
# defaut $QEMU_TREE/cfgs/mobile_group1.cfg - le fichier statique de qemu-src,
# fige sur l'operateur 1. Mesure sur le banc :
#     mobile.cfg          18:22:22  imsi=002010002000001 arfcn=516
#     mobile_group1.cfg   18:22:27  imsi=001010001000001 arfcn=514
# Cinq secondes d'ecart, et c'est le second que le mobile ouvre.
# On designe donc NOTRE fichier comme source : le module recopie alors le bon
# contenu, et son controle d'idempotence (cmp -s src dest) passe puisque les
# deux sont identiques. Aucune modification de qemu-src.
export MOBILE_CFG_SRC="$MS1_CFG"

MS1_GROUP_CFG="$BB_DIR/mobile_group1.cfg"
if [ "$MS1_GROUP_CFG" != "$MS1_CFG" ]; then
    generate_mobile_cfg "$MS1_GROUP_CFG" \
        4247 \
        /tmp/osmocom_l2 \
        /tmp/osmocom_sap_1 \
        "$MS_ARFCN1" \
        "$(ms_imsi 1)" \
        "$(ms_ki 1)"
    printf '  %sMS#1%s       aussi ecrit dans %s (le fichier que run.sh ouvre)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$MS1_GROUP_CFG"
fi
say_end " OK " "$C_OK" "Generation mobile MS#1" "$MS1_CFG"
say_begin "Generation mobile MS#2 (faketrx)"
MS2_CFG="$BB_DIR/mobile_faketrx_bts1.cfg"
generate_mobile_cfg "$MS2_CFG" \
    4248 \
    /tmp/ms2_l2 \
    /tmp/ms2_sap \
    "$MS_ARFCN2" \
    "$(ms_imsi 2)" \
    "$(ms_ki 2)" \
    gsm_out gsm_in
say_end " OK " "$C_OK" "Generation mobile MS#2 (faketrx)" "$MS2_CFG"
# Export pour que les modules run.sh / hybrid puissent les retrouver
export MOBILE_CFG_MS1="$MS1_CFG"
export MOBILE_CFG_MS2="$MS2_CFG"
export CALYPSO_MS2_CFG="$MS2_CFG"

# --- Outillage DSP (--dsp) : ETEINT par defaut --------------------------------
# Trois choses n'ont rien a faire dans un lancement ordinaire. Elles servent a
# regarder DEDANS le modele Calypso, pas a faire fonctionner un banc :
#
#   calypso-ipc-device + osmo-trx-ipc   le pont I/Q entre QEMU et le
#       transceiver. Un processus de plus, une memoire partagee, un socket
#       maitre - et quand il manque, osmo-trx-ipc sort en boucle sur
#       « socket maitre IPC absent », ce qui se lit comme une panne radio.
#   la trace asm de QEMU (CALYPSO_ASM)  un journal qui grossit sans fin, dans
#       un anneau qu'il faut faire tourner. `in_asm` ne dit meme pas ce qui a
#       ete EXECUTE, seulement ce qui a ete traduit.
#   le croisement mailbox x desassemblage (CALYPSO_MAILBOX)  une fenetre de
#       plus, alimentee par un python relance toutes les deux secondes.
#
# On les eteint donc explicitement, plutot que de compter sur leurs defauts :
# ces variables sont EXPORTEES et survivent a un run precedent dans le meme
# shell - un banc « propre » heritait ainsi d'une trace asm allumee la veille.
#
# ⚠ EN COUPANT LE PONT I/Q on coupe la chaine IQ du profil hybride. C'est le
# meme choix que fait CALYPSO_BRIDGE=pont juste en dessous, qui remplace cette
# chaine par le pont maison. Si le banc a besoin de la chaine d'origine,
# c'est --dsp qu'il faut passer.
if [ "${DSP_MODE:-0}" -eq 1 ]; then
    printf '  %sDSP%s        outillage d inspection ACTIF (--dsp) : ipc-device, trx-ipc, asm, mailbox\n' \
        "${C_DIM:-}" "${C_Z:-}"
    # On n'IMPOSE rien : --dsp rend la main aux reglages de l'appelant et aux
    # defauts des modules. Poser CALYPSO_ASM ici figerait une taille d'anneau
    # que personne n'a demandee.
    : "${CALYPSO_ASM:=8}"
    export CALYPSO_ASM
    export CALYPSO_MAILBOX="${CALYPSO_MAILBOX:-1}"
else
    export CALYPSO_SKIP_IPC_DEVICE=1
    export CALYPSO_SKIP_TRX_IPC=1
    export CALYPSO_ASM=0
    export CALYPSO_MAILBOX=0
    printf '  %sDSP%s        outillage d inspection eteint (--dsp pour ipc-device, asm, mailbox)\n' \
        "${C_DIM:-}" "${C_Z:-}"
fi

# --- Mode PONT TRX (CALYPSO_BRIDGE=pont) : le pont maison REMPLACE la chaine IQ --
# Le pont (/opt/GSM/pont/pont.py) se presente comme transceiver TRX-UDP a osmo-bts-trx
# (5700/5701/5702), decode les bursts DL en L2 -> GSMTAP 4730/4731 (shunt in-QEMU ->
# a_cd), et encode l'UL depuis les sidebands /dev/shm/calypso_* -> TRXD -> BTS.
# Il REND REDONDANTS et on ETEINT : osmo-trx-ipc (transceiver), calypso-ipc-device
# (pont IQ), si_bridge (decode DL), demod-bridge. On GARDE QEMU (Calypso+shunt) et
# osmo-bts-trx. Reversible : ne pas passer CALYPSO_BRIDGE=pont.
if [ "${CALYPSO_BRIDGE:-}" = pont ]; then
    export CALYPSO_BRIDGE
    export CALYPSO_SKIP_TRX_IPC=1        # plus d'osmo-trx-ipc (le pont est le transceiver)
    export CALYPSO_SKIP_IPC_DEVICE=1     # plus de calypso-ipc-device (plus d'IQ)
    export CALYPSO_SKIP_BRIDGE_PY=1      # plus de si_bridge (le pont decode)
    export CALYPSO_SKIP_DEMOD_BRIDGE=1   # plus de demod-bridge
    # Le pont a BESOIN d'osmo-bts-trx en face (c'est son interlocuteur TRX-UDP).
    # On l'impose explicitement : un SKIP_BTS herite d'un run precedent (env
    # fossilise) laisserait le pont sans personne au bout du fil.
    export CALYPSO_SKIP_BTS=0
    # FB (FCCH) : en mode pont il n'y a plus de chaine gr-gsm/IQ, donc plus de
    # detection FB REELLE (calypso_dsp_shunt_real_fb_read). Sans FB, la FBSB de
    # l'ARM echoue -> "Channel sync error" -> le mobile ne campe jamais, meme
    # avec des SI. On laisse donc le shunt FABRIQUER le FB (canned), tandis que
    # le SCH, lui, reste REEL : le pont le decode et le publie sur 4731.
    export CALYPSO_SHUNT_REAL_FB=0
    # CALYPSO_SHUNT_NO_CANNED est desormais un defaut := plus haut (bloc « defauts
    # du pont legit ») : surchargeable, et deja exporte. Ne pas le re-forcer ici
    # par un "export ...=0" - ca ecraserait une surcharge voulue de l'operateur.
    # 65-record-drain / 66-grgsm-decode sont rallumes par ce forceur meme hors
    # full-grgsm : on le neutralise (aucune IQ a drainer ni a decoder ici).
    export CALYPSO_FORCE_DEMOD_BRIDGE=0
    # Preset EXISTANT "bridge" = pont Python a la place d'ipc/trx-ipc : c'est
    # exactement notre cas. Il pose SKIP_IPC_DEVICE=1 / SKIP_TRX_IPC=1, et
    # comme il n'est pas full-grgsm il DESACTIVE aussi 65-record-drain et
    # 66-grgsm-decode (MOD_ENABLED_IF) - le pont fournit lui-meme le GSMTAP.
    export CALYPSO_PIPELINE=bridge
    # ── LE PONT VIENT DU DEPOT, POINT ──────────────────────────────────────
    # Le defaut etait /opt/GSM/pont/pont.py, un chemin HORS DEPOT alimente par un
    # `COPY pont/pont.py` de Dockerfile.run et fige par un `ENV PONT_PY=`. Rien
    # ne le gardait en phase avec pont/pont.py, et rien ne signalait sa derive.
    #
    # CE QUE CA A COUTE, le 2026-08-27 : la copie executee etait restee a une
    # version anterieure de 198 lignes, SANS AUCUN plan SDCCH/8 (ni PLAN_SD8, ni
    # _dcch_plan, ni sacch_dl102). Elle raisonnait sur le SDCCH/4 combine du TS0
    # pendant que le mobile parlait sur SDCCH/8 SS0 du TS1. Pendant deux heures,
    # sans un seul message d erreur : 79 % de CRC fail, montant emis dans la
    # fenetre du /4 (donc hors de celle que la BTS ecoute, avec hors_fenetre=0
    # puisque coherent avec sa propre table), SABM sans reponse, T200 x6, LU en
    # echec, SMS rejete, appel impossible. Restaurer la copie du depot a suffi a
    # retablir le LU complet, chiffrement A5/1 compris, des le premier essai.
    #
    # La copie libre et son COPY sont supprimes ; PONT_PY reste disponible pour
    # qui veut essayer une variante, mais c est alors un choix explicite.
    _PONT="${PONT_PY:-${NITB_ROOT:-/opt/GSM/osmo_egprs}/pont/pont.py}"

    # ── LE PONT DOIT SAVOIR SUR QUELLE CELLULE IL TRAVAILLE ─────────────────
    # pont.py fait le codage/decodage de canal entre le Calypso de QEMU et la
    # BTS. Il lisait PONT_ARFCN et PONT_BSIC dans son environnement, avec pour
    # defauts 514 et 7 - les valeurs de l'operateur 1. Personne ne les posait.
    #
    # Le BSIC n'est pas decoratif : sa partie basse (BCC) EST la sequence
    # d'apprentissage des canaux dedies. Avec un BSIC faux, la correlation
    # echoue et les blocs ne se decodent pas. Constate sur l'operateur 2, dont
    # la cellule est en ARFCN 516 / BSIC 14 :
    #     dl_bursts=20660 dl_dec=1180 crc_fail=3984
    #     TS0/22 : 0/295        <- la voie ou arrive l'Immediate Assignment
    #     ul_sent=23 rach=23    <- le RACH partait bien
    # Le mobile emettait son RACH, le reseau repondait, et la reponse n'etait
    # jamais rendue au Calypso : "radio resource layer state: connection
    # pending", indefiniment. L'operateur 1 s'en sortait parce que ses valeurs
    # sont justement celles des defauts.
    #
    # On les prend dans le plan radio publie par generate_configs.sh, avec les
    # memes replis que les mobiles.
    export PONT_ARFCN="${PONT_ARFCN:-${PLAN_ARFCN:-$MS_ARFCN1}}"
    export PONT_BSIC="${PONT_BSIC:-${PLAN_BSIC:-$(( MS_OP_ID * 7 % 64 ))}}"
    printf '  %spont TRX%s : cellule ARFCN %s BSIC %s\n' \
        "${C_DIM:-}" "${C_Z:-}" "$PONT_ARFCN" "$PONT_BSIC"
    # [2026-08-16] N'ARMER LE LANCEUR QUE SUR UN VRAI DEMARRAGE.
    # Ce bloc s'execute AVANT le `case "$ACTION"` plus bas. Sur `--stop` (comme
    # sur --list/--status/--check-paths) on armait donc quand meme le lanceur
    # differe, que `run.sh --stop` tuait aussitot - d'ou le "line 450: Killed"
    # crache par bash en plein arret propre. Un arret qui programme un demarrage
    # n'a aucun sens, et le message faisait croire a une panne.
    # Le pont DEJA VIVANT, lui, est bien arrete : le teardown le connait
    # desormais (`f:pont/pont.py` dans _td_patterns) et mod_teardown_stop
    # l'applique aussi.
    if [ "$ACTION" != start ]; then
        printf '  %spont TRX%s : non arme (action=%s, pas un demarrage)\n' \
               "${C_DIM:-}" "${C_Z:-}" "$ACTION"
    elif [ -r "$_PONT" ]; then
        # SINGLETON : tuer un pont precedent, sinon il tient 5700-5702 et le
        # teardown de run.sh echoue ("restes du run precedent : port:5700...").
        pkill -f "$_PONT" 2>/dev/null || true
        # [2026-08-16] KILLALL DEMANDE PAR L'OPERATEUR, et assume.
        # Le motif nominatif ci-dessus rate tout pont lance sous un autre chemin
        # (PONT_PY surcharge, une sauvegarde .bak), et c'est ce qui faisait
        # echouer le teardown sur "port:5700 port:5701 port:5702".
        # ⚠️ CE QUE CA EMPORTE, en plus du pont : fake_trx.py (le transceiver de
        # MS#2), sms-interop-relay.py (routage SMS inter-operateurs, HORS pile
        # run.sh donc non relance automatiquement), gsm_sniff.py et les scripts
        # des panes tmux. C'est acceptable ICI parce qu'on est sur le chemin d'un
        # DEMARRAGE (ACTION=start) : le teardown de run.sh va de toute facon tout
        # arreter deux secondes plus tard. Ne PAS reprendre ce geste dans un
        # module de run.sh, ou il tuerait le filtre d'horodatage du run en cours.
        # CALYPSO_NO_KILLALL=1 pour s'en passer.
        if [ "${CALYPSO_NO_KILLALL:-0}" != "1" ]; then
            printf '  %spont TRX%s : killall -9 python3 (demande ; emporte aussi fake_trx / sms-interop-relay)\n' "${C_DIM:-}" "${C_Z:-}"
            killall -9 python3 2>/dev/null || true
        fi
        sleep 1
        printf '  %spont TRX%s : REMPLACE osmo-trx-ipc + calypso-ipc-device + si_bridge (SHUNT_LEGIT burst-direct)\n' "${C_DIM:-}" "${C_Z:-}"
        # LANCEMENT DIFFERE : run.sh fait d'abord son teardown (qui verifie que
        # 5700-5702 sont LIBRES). On ne binde donc qu'apres, sinon on se
        # bloque nous-memes. 25 s = teardown + demarrage des modules.
        # LOG HORS LOG_DIR : run.sh archive/efface LOG_DIR pendant son teardown ;
        # un pont.log ouvert avant se retrouve sur un inode SUPPRIME (sortie
        # invisible, "(deleted)" dans /proc/<pid>/fd/1). /dev/shm survit.
        # setsid : le pont doit survivre a la fin du shell de start-direct.
        # [2026-08-16] LE `sleep 25` ETAIT UNE COURSE, PAS UNE BARRIERE.
        # 25 s etait un pari sur la duree du teardown de run.sh. Des que
        # celui-ci archive de gros journaux (mesure : 62 Mo -> ~40 s), le pont
        # se rebindait sur 5700-5702 EN PLEIN teardown, qui echouait alors sur
        # "restes du run precedent : port:5700 port:5701 port:5702" et
        # abandonnait toute la sequence. Le symptome se deplacait avec la
        # taille des journaux, ce qui le faisait passer pour intermittent.
        # On attend maintenant un EVENEMENT et non une duree : osmo-bts-trx,
        # qui est l'interlocuteur TRX-UDP du pont et ne demarre qu'APRES le
        # teardown. Sa presence prouve donc que les ports sont a nous.
        # [2026-08-27] LA BARRIERE ATTEND D'ABORD QU'IL DISPARAISSE.
        # Elle n'attendait que sa PRESENCE, en se fiant a « osmo-bts-trx ne
        # demarre qu'APRES le teardown ». Vrai seulement si l'on a fait --stop
        # avant. Sans --stop, l'osmo-bts-trx du run PRECEDENT est encore la :
        # pgrep reussit immediatement (_n=0), le pont binde 5700-5702 en plein
        # teardown, run.sh le tue derriere (f:pont/pont.py est dans
        # _td_patterns) et rien ne le relance -- « le pont n'a pas de bursts ».
        # On attend donc les DEUX fronts : la disparition (le teardown a bien
        # eu lieu), puis l'apparition (la pile est remontee). Avec --stop le
        # premier front est deja franchi et rien ne change.
        ( _n=0
          while [ "$_n" -lt 180 ] && pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          _dispar=$_n
          while [ "$_n" -lt 180 ] && ! pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[pont] osmo-bts-trx jamais (re)vu apres 180 s - demarrage quand meme"
          else
              echo "[pont] osmo-bts-trx parti a ${_dispar}s puis revu a ${_n}s - la pile est debout, on binde"
          fi
          sleep 1
          pkill -f "$_PONT" 2>/dev/null; sleep 1
          exec setsid python3 -u "$_PONT" ) >/dev/shm/pont.log 2>&1 &
        printf '  %spont: journal%s /dev/shm/pont.log (hors LOG_DIR, efface par le teardown)\n' "${C_DIM:-}" "${C_Z:-}"
    else
        printf '  pont introuvable (%s)\n' "$_PONT"
    fi
fi

# --- MAILLAGE DE BURSTS (--air-mesh) : le milieu radio devient commun ---------
# Jusqu'ici deux noeuds se parlaient tout en haut de la pile - un trunk SIP,
# un relais SMS, du M3UA vers un hub - et chacun gardait sa radio hermetique :
# le mobile de l'operateur 1 ne POUVAIT PAS entendre la BTS de l'operateur 2.
# Ici c'est le burst qui traverse : pont/airmesh.py prend ce qui passe sur le
# fake_trx local et l'echange avec les pairs. Voir l'en-tete d'airmesh.py pour
# le detail - notamment pourquoi il faut DEUX emplacements de transceiver, et
# comment on les obtient sans modifier une ligne de qemu-src.
if [ "${AIR_MESH:-0}" = "1" ]; then
    _AIRMESH="${AIRMESH_PY:-${HERE}/pont/airmesh.py}"
    [ -f "$_AIRMESH" ] || _AIRMESH=/opt/GSM/osmo_egprs/pont/airmesh.py
    if [ ! -f "$_AIRMESH" ]; then
        printf '  %sair-mesh%s : airmesh.py introuvable - maillage de bursts non lance\n' "${C_KO:-}" "${C_Z:-}"
    else
        # DEUX MOBILES DE PLUS QUE LE BANC N'EN A. fake_trx cree un transceiver
        # par mobile declare ; airmesh prend les deux derniers et les accorde
        # autrement (l'un comme un mobile, l'autre comme une BTS). Sans ce +2,
        # il n'y a aucun emplacement libre et airmesh se tait sans rien dire.
        _NMS_REEL="${N_MS:-2}"
        N_MS=$(( _NMS_REEL + 2 )); export N_MS
        _BBP="${BB_BASE_PORT:-6700}"; _BBS="${BB_PORT_STEP:-3}"
        _TRX_MS=$((  _BBP + (_NMS_REEL + 1 - 1) * _BBS ))   # emplacement N+1
        _TRX_BTS=$(( _BBP + (_NMS_REEL + 2 - 1) * _BBS ))   # emplacement N+2

        # Les pairs viennent de la table WAN : tout noeud qui n'est pas nous.
        _PAIRS=""
        for _tok in ${WAN_NODES:-}; do
            _pid="${_tok%%:*}"; _rest="${_tok#*:}"; _pip="${_rest%%:*}"
            [ -n "$_pid" ] && [ -n "$_pip" ] || continue
            [ "$_pid" = "${NODE_ID:-1}" ] && continue
            _PAIRS="$_PAIRS --pair ${_pid}:${_pip}:${AIRMESH_PORT:-4739}"
        done

        printf '  %sair-mesh%s   noeud %s  arfcn %s  emplacements TRXD %s et %s  pairs:%s\n' \
            "${C_DIM:-}" "${C_Z:-}" "${NODE_ID:-1}" "${ARFCN:-514}" \
            "$_TRX_MS" "$_TRX_BTS" "${_PAIRS:- aucun}"

        # On attend que fake_trx ait BINDE l'emplacement, pas une duree : il ne
        # demarre qu'apres le teardown de run.sh, dont la duree depend de la
        # taille des journaux archives. Une temporisation ferait de ce lancement
        # une course - c'est la lecon du pont, juste au-dessus.
        ( _n=0
          while [ "$_n" -lt 180 ] && ! ss -uln 2>/dev/null | grep -q ":$(( _TRX_MS + 1 ))\b"; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[airmesh] emplacement $(( _TRX_MS + 1 )) jamais ouvert par fake_trx apres 180 s"
              echo "[airmesh] verifiez que le banc tourne bien avec N_MS=${N_MS} (deux de plus que ${_NMS_REEL})"
              exit 1
          fi
          echo "[airmesh] fake_trx a ouvert nos emplacements apres ${_n} s"
          sleep 1
          # shellcheck disable=SC2086
          exec setsid python3 -u "$_AIRMESH" \
              --node "${NODE_ID:-1}" --arfcn "${ARFCN:-514}" \
              --port "${AIRMESH_PORT:-4739}" \
              --trx-ms "$_TRX_MS" --trx-bts "$_TRX_BTS" \
              --topologie "${HERE}/data/air-mesh.txt" \
              $_PAIRS ) >/dev/shm/airmesh.log 2>&1 &
        printf '  %sair-mesh: journal%s /dev/shm/airmesh.log\n' "${C_DIM:-}" "${C_Z:-}"
    fi
fi

# --- Mode BRIDGE IPC-MS (CALYPSO_BRIDGE=ipc) : MS#1 servi par osmo-trx-ms-ipc ----
# Le firmware qemu/osmocon de MS#1 est SKIP (gates dans 40-qemu.sh/50-osmocon.sh).
# osmo-trx-ms-ipc lit le DL fc32 relaye par l'IPC (UDP CALYPSO_TRX_IQ_RX_PORT=5810),
# emet l'UL fc32 sur 5811 (relay_init le lit deja), et sert L1CTL sur /tmp/osmocom_l2.
if [ "${CALYPSO_BRIDGE:-}" = ipc ]; then
    export CALYPSO_BRIDGE
    export CALYPSO_IPC_RELAY=1
    : "${CALYPSO_TRX_IQ_HOST:=127.0.0.1}";   export CALYPSO_TRX_IQ_HOST
    : "${CALYPSO_TRX_IQ_RX_PORT:=5810}";     export CALYPSO_TRX_IQ_RX_PORT
    : "${CALYPSO_TRX_IQ_TX_PORT:=5811}";     export CALYPSO_TRX_IQ_TX_PORT
    _MSIPC="$(command -v osmo-trx-ms-ipc || echo /opt/GSM/osmo-trx/Transceiver52M/osmo-trx-ms-ipc)"
    if [ -x "$_MSIPC" ]; then
        printf '  %sMS#1 = osmo-trx-ms-ipc%s  (DL<-udp %s:%s, UL->%s, L1CTL /tmp/osmocom_l2)\n' \
            "${C_DIM:-}" "${C_Z:-}" "$CALYPSO_TRX_IQ_HOST" "$CALYPSO_TRX_IQ_RX_PORT" "$CALYPSO_TRX_IQ_TX_PORT"
        ( sleep 6; "$_MSIPC" >"${LOG_DIR:-/tmp/osmo-nitb/logs}/osmo-trx-ms-ipc.log" 2>&1 ) &
    else
        printf '  osmo-trx-ms-ipc PAS COMPILE (%s) - build requis\n' "$_MSIPC"
    fi
fi


# --- 5. exports supplementaires pour le profil hybrid -------------------------
if [ "$MODE" = "faketrx-qemu" ] || [ "$CALYPSO_PROFILE" = "hybrid" ]; then
    export QEMU_ATTACH_TRX="${QEMU_ATTACH_TRX:-0}"
    export NO_LOCAL_BTS="${NO_LOCAL_BTS:-0}"
    export NO_LOCAL_TRX="${NO_LOCAL_TRX:-0}"
    export TRX_BASE_PORT="${TRX_BASE_PORT:-6700}"
    export TRX_BIND="${TRX_BIND:-127.0.0.1}"
    export BTS1_UNIT_ID=6002
    export BTS1_ARFCN=516
    export BTS0_ARFCN=514
fi
# --- 6. resume ----------------------------------------------------------------
banner
printf '  %sprofil%s     %s (%s)\n' "$C_DIM" "$C_Z" "$CALYPSO_PROFILE" "$MODE"
printf '  %senviron.%s   %s\n' "$C_DIM" "$C_Z" \
    "$(case "$RUNTIME_ENV" in docker) echo "conteneur docker" ;; vm) echo "machine virtuelle" ;; *) echo "machine physique" ;; esac)"
if [ -n "$NODE_ID" ]; then
    printf '  %snoeud%s      %s  %s(%s)%s\n' "$C_DIM" "$C_Z" "$NODE_ID" "$C_DIM" "${NODE_ID_SRC:-?}" "$C_Z"
else
    printf '  %snoeud%s      %s\n' "$C_DIM" "$C_Z" "aucun - identite SS7 inchangee"
fi
printf '  %srun.sh%s     %s\n' "$C_DIM" "$C_Z" "$RUN_SH"
printf '  %sMS#1%s       %s  IMSI %s  ARFCN %s  VTY 4247\n' "$C_DIM" "$C_Z" "$MS1_CFG" "$(ms_imsi 1)" "$MS_ARFCN1"
printf '  %sMS#2%s       %s  IMSI %s  ARFCN %s  VTY 4248\n' "$C_DIM" "$C_Z" "$MS2_CFG" "$(ms_imsi 2)" "$MS_ARFCN2"
printf '  %sjournaux%s   %s\n' "$C_DIM" "$C_Z" "$LOG_DIR"
printf '  %schiffrement%s %s\n' "$C_DIM" "$C_Z" "$ENCRYPTION"
printf '\n'
# --- 7. actions deleguees a run.sh --------------------------------------------
RUN_ARGS=()
[ "$DRY" -eq 1 ]     && RUN_ARGS+=(--dry-run)
[ "$FORCE" -eq 1 ]   && RUN_ARGS+=(--force)
[ "$VERBOSE" -eq 1 ] && RUN_ARGS+=(--verbose)
RUN_ARGS+=(--profile "$CALYPSO_PROFILE")
# [2026-08-08] --restart etait ajoute DIRECTEMENT sur la ligne exec, hors de
# RUN_ARGS. Consequence : `--dry-run` affichait une commande SANS --restart puis
# le vrai lancement en ajoutait un. Une simulation qui ne decrit pas ce qui va
# se passer est pire qu'absente. Il entre donc dans RUN_ARGS, ou il est visible.
# CALYPSO_NO_RESTART=1 pour demarrer sans reinitialiser (l'ancien comportement
# n'etait pas atteignable du tout).
[ "${CALYPSO_NO_RESTART:-0}" = "1" ] || RUN_ARGS+=(--restart)
# ── Les sessions tmux d'un run precedent ────────────────────────────────────
# Le teardown de run.sh arrete les processus mais laisse la session tmux
# debout. Au demarrage suivant, son module de panes RECREE ses fenetres dans la
# session survivante : il y a alors DEUX fenetres nommees « all ».
#
# Et deux fenetres de meme nom ne sont pas seulement inesthetiques : tmux ne
# sait plus resoudre la cible. Verifie sur le banc, tmux 3.2a :
#     $ tmux split-window -t calypso:all
#     can't find window: all
# Les trois splits echouent, le module les compte comme "pane refuse par tmux
# (place insuffisante)" - un diagnostic FAUX qui envoie chercher un probleme de
# taille de terminal - et la barriere conclut « la fenetre "all" n'a pas garde
# ses panes ». La cause etait deux fenetres plus haut.
#
# On efface donc les sessions du run precedent avec lui. Trois conventions
# cohabitent selon le lanceur, on les couvre toutes ; aucune n'a besoin
# d'exister.
purge_sessions_tmux() {
    local n=0 s
    for s in calypso gapk osmo; do
        if tmux has-session -t "$s" 2>/dev/null; then
            tmux kill-session -t "$s" 2>/dev/null && n=$((n + 1))
        fi
    done
    if tmux -S /tmp/osmocom_tmux has-session -t osmocom 2>/dev/null; then
        tmux -S /tmp/osmocom_tmux kill-session -t osmocom 2>/dev/null && n=$((n + 1))
    fi
    [ "$n" -gt 0 ] && printf '  %ssessions tmux%s   %s session(s) du run precedent effacee(s)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$n"
    return 0
}

case "$ACTION" in
    list)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --list "${RUN_ARGS[@]}"
        ;;
    stop)
        say_begin "Arret de la pile via run.sh"
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE"
        say_end " OK " "$C_OK" "Arret de la pile via run.sh"
        purge_sessions_tmux
        # Filet identique a celui de run.sh, pose ici aussi : on peut arreter par
        # ce script sans passer par l'autre, et un fake_trx.py orphelin suffit a
        # faire echouer le run suivant sur « port UDP 5720 deja pris ».
        # run.sh le fait deja de son cote ; le repeter ne coute rien et couvre le
        # cas ou RUN_SH est introuvable ou sort en erreur.
        # PORTEE : tue TOUS les python3 de la machine. CALYPSO_STOP_KILL_PYTHON=0
        # le desactive.
        if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
            if killall -9 python3 2>/dev/null; then
                say_end " OK " "$C_OK" "python3 restants termines (killall)"
            fi
        fi
        exit 0
        ;;
    status)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --status --profile "$CALYPSO_PROFILE"
        ;;
    checkpaths)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --check-paths
        ;;
esac
# --- 7bis-menu. Ce qui manque, demande UNE fois, avec le cache en defaut ------
# Les trois valeurs qui decident de l'identite SS7 - numero de noeud, operateur,
# adresse du hub - se deduisent la plupart du temps : environnement transmis par
# start.sh, /etc/osmo-role fige dans l'image, table WAN. Quand la deduction ne
# donne rien, la pile demarrait quand meme et gardait les point codes du
# gabarit : 1.1.2 partout, ASP vers 127.0.0.1, interco morte sans un mot.
#
# On demande donc - mais seulement ce qui manque, et en proposant ce que le
# cache sait deja. Sans terminal, rien n'est demande : les defauts s'appliquent,
# une ISO qui demarre seule ne peut pas rester bloquee sur une question.
ask_node_identity() {
    # NO_MENU=1 est ce que start.sh pose devant le lanceur quand les choix ont
    # deja ete faits sur l'hote. Aujourd'hui la garde tty juste en dessous
    # suffit (start.sh lance par docker exec -d, sans terminal) : ce test ne
    # repare donc aucune panne observable, il aligne l'identite SS7 sur la
    # meme convention que les menus de pile de start.sh, pour le jour ou le
    # lanceur automatique aura un terminal.
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ -t 0 ] || return 0
    [ "$DRY" -eq 1 ] && return 0

    local cached_node cached_src cached_hub
    IFS='|' read -r cached_node cached_src <<< "$(detect_node_id)"

    # L'ENVIRONNEMENT NE SE DEMANDE PAS. C'est ainsi que start.sh transmet le
    # noeud a un conteneur : la reponse est deja connue, et la question n'a pas
    # de sens - pire, dans un conteneur ou personne ne lit le terminal, elle
    # repart vide. L'identite n'etait alors PAS appliquee, la pile regenerait
    # ses configs par defaut (point-code 1.1.2, ASP vers le hub docker, en
    # shutdown) et ecrasait celle que start.sh venait d'ecrire. Le fichier
    # portait les bonnes valeurs juste avant, les mauvaises juste apres.
    # Le rattrapage qui se trouvait ici ne servait plus a rien : il exigeait un
    # NODE_ID vide, alors que la resolution du noeud, bien plus haut, l'a deja
    # rempli depuis cette meme source. NODE_ID et HUB_IP sont donc repris de
    # l'environnement la-bas, une fois, et pas ici.
    cached_hub="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"
    [ -n "$cached_hub" ] || cached_hub="192.168.1.49"

    if command -v whiptail >/dev/null 2>&1; then
        [ -n "$NODE_ID" ] || NODE_ID="$(whiptail --title "Identite du noeud" \
            --inputbox "Numero de ce noeud (1-9)${cached_src:+   [$cached_src]}\nVide = ne pas toucher a l'identite SS7." \
            11 66 "${cached_node:-}" 3>&1 1>&2 2>&3)" || NODE_ID=""
        if [ -n "$NODE_ID" ] && [ -z "$HUB_IP" ]; then
            HUB_IP="$(whiptail --title "Inter-STP" \
                --inputbox "Adresse du hub SS7 (PC 0.0.0)\nVide = laisser le remote-ip deja present." \
                11 66 "$cached_hub" 3>&1 1>&2 2>&3)" || HUB_IP=""
        fi
    else
        if [ -z "$NODE_ID" ]; then
            printf '  Numero de ce noeud (1-9)%s [%s] : ' \
                "${cached_src:+ - $cached_src}" "${cached_node:-aucun}"
            read -r NODE_ID || NODE_ID=""
            [ -n "$NODE_ID" ] || NODE_ID="${cached_node:-}"
        fi
        if [ -n "$NODE_ID" ] && [ -z "$HUB_IP" ]; then
            printf '  Adresse de l inter-STP [%s] : ' "$cached_hub"
            read -r HUB_IP || HUB_IP=""
            [ -n "$HUB_IP" ] || HUB_IP="$cached_hub"
        fi
    fi
}
ask_node_identity

# ══ La regeneration des configurations, POUR DE VRAI ═══════════════════════
# CE QUE --regen FAISAIT JUSQU'ICI : RIEN.
# Il levait OSMO_NO_REGEN et comptait sur run_modules/08-gabarits.sh pour
# rejouer apply_config_templates au demarrage. Ce module N'EXISTE PAS - il n'a
# jamais existe dans run_modules/ - et run.sh ne genere aucune configuration.
# Le message « regeneration demandee » s'affichait, la pile s'arretait, et pas
# un octet de /etc/osmocom ne changeait. Le seul effet reel de l'option etait
# d'arreter le banc.
#
# CE QU'IL FAIT MAINTENANT : la meme chose que start.sh cote docker, et que
# build-iso.sh a la construction - c'est-a-dire la sequence complete :
#
#   1. apply_config_templates      substitue configs/*.cfg et *.conf dans un
#                                  repertoire NEUF (jamais en place : une
#                                  substitution a moitie faite sur /etc/osmocom
#                                  laisse un banc qui ne demarre plus) ;
#   2. apply_native_post_patches   la recette NATIVE de l'ISO - sms-routing par
#                                  MS reel, SGSN/MSC sur l'adresse locale du
#                                  coeur, run.sh degraisse ;
#   3. install_configs_native      pose le resultat dans /etc/osmocom et
#                                  /etc/asterisk.
#
# EN SOUS-SHELL. lib/gabarits.sh charge globals.conf et pose une trentaine de
# variables - MCC, ARFCN, HOST_IP, N_OPERATORS, KI... - qui portent ici un tout
# autre sens (HOST_IP est l'adresse du banc pour le lanceur, l'adresse interne
# du coeur pour les gabarits). Les laisser fuir, c'est changer le plan radio
# d'un run parce qu'on a demande une regeneration.
#
#   $1 numero de noeud   $2 numero d'operateur   $3 inter-STP (peut etre vide)
regen_configs_natif() {
    local node="$1" op="$2" hub="$3"
    local tmp rc=0

    # ── Le plan NATIF, celui de build-iso.sh, et non celui de docker ────────
    # 127.0.0.2 (__CONTAINER_IP__) porte le coeur : GGSN, SGSN, UPF, la nsvc du
    # BSC. Une adresse de boucle locale existe TOUJOURS et est prete avant tout
    # service ; une adresse de carte peut manquer au moment ou osmo-ggsn se lie,
    # et le bind echoue sans rapport visible avec le reseau.
    # 127.0.0.1 (__GATEWAY_IP__) recoit le gsmtap, la ou tshark capte deja.
    local core_ip="${OSMO_NATIVE_CORE_IP:-127.0.0.2}"
    local gw_ip="${OSMO_NATIVE_GW_IP:-127.0.0.1}"

    # ── L'identite SUIT LE NOEUD ────────────────────────────────────────────
    # 1.<noeud><op>.<role>, le plan de network/set-node-id.sh et de build-iso.sh
    # --node. Sans le noeud dans le point code, trois machines attachees au meme
    # hub y presentent trois fois 1.11.2 : un point code est une ADRESSE, et
    # deux equipements qui partagent la leur donnent du routage faux, silencieux.
    # Le routing context suit la meme regle : c'est lui que le hub lit pour
    # distinguer les AS, et la formule locale (op*100+50) rend la meme valeur
    # sur tous les noeuds.
    local mid="${node}${op}"
    local pc_msc="1.${mid}.1" pc_stp="1.${mid}.2" pc_bsc="1.${mid}.3"
    local shut="shutdown"
    [ -n "$hub" ] && shut="no shutdown"

    # ── Le PLMN : celui de la machine, pas celui de la table ────────────────
    # Relu dans osmo-msc.cfg installe. Reprendre les defauts de globals.conf
    # renommerait le reseau a chaque regeneration - OsmoDirect redevenait
    # OsmoQEMU - et un mobile deja provisionne ne reconnait plus sa cellule.
    local cfgdir="${OSMOCOM_CFG:-/etc/osmocom}"
    local mcc mnc opname
    mcc="$(awk '/^ *network country code /{print $4; exit}' "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    mnc="$(awk '/^ *mobile network code /{print $4; exit}'  "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    opname="$(awk '/^ *short name /{print $3; exit}'        "$cfgdir/osmo-msc.cfg" 2>/dev/null)"
    [ -n "$mcc" ]    || mcc="${MCC:-001}"
    [ -n "$mnc" ]    || mnc="${MNC:-01}"
    [ -n "$opname" ] || opname="${OP_NAME:-OsmoGSM}"

    # Le nombre de MS vient de coeur.env, ecrit par build-iso.sh : c'est lui qui
    # dit combien d'abonnes le HLR provisionne, donc combien de routes SMS il
    # faut. Au-dela, le relais rend "No route for destination".
    local n_ms="${N_MS:-}"
    if [ -z "$n_ms" ] && [ -r "$cfgdir/coeur.env" ]; then
        n_ms="$(awk -F'[:=}]' '/N_MS:=/{print $3; exit}' "$cfgdir/coeur.env" 2>/dev/null)"
    fi
    [ -n "$n_ms" ] || n_ms=2

    printf '  %splan natif%s coeur %s  gsmtap %s  PC %s  rctx %s  PLMN %s-%s (%s)  %s MS\n' \
        "${C_DIM:-}" "${C_Z:-}" "$core_ip" "$gw_ip" "$pc_stp" \
        "$(( node * 1000 + op * 100 + 50 ))" "$mcc" "$mnc" "$opname" "$n_ms"

    tmp="$(mktemp -d)" || return 1

    # ── La sauvegarde, AVANT d'ecrire ───────────────────────────────────────
    # Une regeneration ecrase des fichiers que quelqu'un a pu retoucher a la
    # main sur le banc. Qu'elle soit demandee ne veut pas dire qu'on accepte de
    # perdre l'etat d'avant sans trace.
    local sav="${LOG_DIR:-/tmp}/osmocom-avant-regen-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$sav" -C / etc/osmocom etc/asterisk 2>/dev/null && \
        printf '  %ssauvegarde%s %s\n' "${C_DIM:-}" "${C_Z:-}" "$sav"

    (
        cd "$HERE" || exit 1
        # AVANT de sourcer. lib/gabarits.sh fige ENCRYPTION a "a5 0" et HOST_IP
        # a 127.0.0.1 par ":=" des qu'ils sont vides, et gc_load tient ensuite
        # ces valeurs pour un choix de l'appelant : le banc repartait en clair
        # apres un --regen, sans un mot.
        : "${ENCRYPTION:=a5 1}"
        HOST_IP="$core_ip"
        # Le routing context et l'adresse source de l'ASP : les deux surcharges
        # que build-iso.sh pose pour un noeud de WAN. 0.0.0.0 parce que
        # l'adresse du noeud vient du DHCP et n'est pas forcement montee quand
        # osmo-stp demarre - se lier a une adresse absente echoue au lancement.
        export RCTX_INTER_OVERRIDE=$(( node * 1000 + op * 100 + 50 ))
        export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
        # _apply_node_ss7_addressing (appele en fin de apply_config_templates)
        # ne rejoue set-node-id.sh que s'il sait QUI il sert, et il ne le lit
        # que la.
        export OSMO_ROLE=operator OSMO_WAN_NODE="$node"
        [ -n "$hub" ] && export OSMO_HUB_IP="$hub"
        unset OSMO_NO_REGEN

        # shellcheck source=lib/gabarits.sh
        . "$HERE/lib/gabarits.sh" || exit 1

        apply_config_templates "$tmp" \
            "$core_ip" "$gw_ip" \
            "$op" "$pc_msc" "$pc_stp" "$pc_bsc" \
            "$mcc" "$mnc" "$opname" \
            "${hub:-127.0.0.1}" "$shut" "1" || exit 1

        # Le noeud et la table WAN : c'est de la table que sms-routing.conf
        # tire l'adresse de chaque noeud, et du noeud qu'il tire les MSISDN
        # (<noeud>00<operateur><rang>).
        apply_native_post_patches "$tmp" "$op" "$n_ms" "$core_ip" \
            "$node" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1

        # ── bb/ RETIRE, et ce n'est pas un oubli ───────────────────────────
        # install_configs_native poserait $tmp/bb/mobile.cfg par-dessus
        # /root/.osmocom/bb/mobile.cfg. Or ce fichier a deja ete ECRIT plus haut
        # par generate_mobile_cfg, qui seul fixe le port VTY, les sockets L1CTL
        # et l'ARFCN de CHAQUE mobile. Le gabarit, lui, est fige sur l'operateur
        # 1 : le remettre ici rendait les deux mobiles au meme ARFCN et a la
        # meme VTY, et le second restait muet pour toujours.
        rm -rf "$tmp/bb"

        install_configs_native "$tmp" "" || exit 1
    ) || rc=1

    rm -rf "$tmp"
    return "$rc"
}

# ── Les gabarits : conserves, sauf --regen ──────────────────────────────────
# Par defaut on ne touche a rien : dans un conteneur, ce que start.sh vient
# d'ecrire - point codes du noeud, inter-STP, ASP actif - ne doit pas etre
# remplace par les valeurs des gabarits, sans quoi l'identite SS7 est juste
# puis fausse 80 secondes plus tard, sans que rien ne l'annonce.
if [ "${REGEN_GABARITS:-0}" -eq 1 ]; then
    unset OSMO_NO_REGEN
    printf '  %sgabarits%s   regeneration demandee (--regen)\n' "${C_DIM:-}" "${C_Z:-}"

    # ── REGEN : ON ARRETE D ABORD ───────────────────────────────────────────
    # Regenerer /etc/osmocom sous une pile VIVANTE ne sert a rien et trompe :
    # les demons ont deja lu leur configuration, ils gardent l'ancienne en
    # memoire, et les fichiers neufs ne prennent effet qu'au demarrage suivant.
    # On lisait donc une conf juste sur le disque pendant que la pile tournait
    # sur la precedente -- le genre d'ecart qui se paie dix minutes plus tard.
    # Un --regen arrete donc la pile, puis regenere : l'etat est sans ambiguite.
    if [ -x "$RUN_SH" ] || [ -r "$RUN_SH" ]; then
        say_begin "Arret de la pile avant regeneration"
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
        say_end " OK " "$C_OK" "Arret de la pile avant regeneration"
        declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
        # Meme filet qu'au --stop : un python3 orphelin (pont, fake_trx, trxcon)
        # garde son port et fait echouer le demarrage suivant sur « port UDP
        # 5720 deja pris ». PORTEE : tue TOUS les python3 de la machine.
        if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
            killall python3 2>/dev/null && \
                say_end " OK " "$C_OK" "python3 restants termines (killall)"
        fi
    fi

    # ── LE NOEUD, PAR DEFAUT 1 ──────────────────────────────────────────────
    # Une regeneration produit une identite COMPLETE, jamais un plan « sans
    # noeud ». Sans numero, apply_config_templates rendait le plan du gabarit -
    # point-code 1.1.2 pour toute machine - et deux noeuds du meme banc se
    # retrouvaient a la meme adresse SS7. On numerote donc toujours : le noeud
    # resolu plus haut (--node, l'environnement, /etc/osmo-role, la table WAN),
    # et 1 quand il n'y en a aucun. Les configurations s'incrementent alors
    # avec lui : PC 1.<noeud><op>.<role>, routing context <noeud>*1000+..., et
    # le segment prive 192.168.<noeud+1>.x.
    REGEN_NODE="${NODE_ID:-1}"
    if ! [[ "$REGEN_NODE" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--regen" "numero de noeud invalide : $REGEN_NODE (1 a 9)"
        exit 2
    fi
    REGEN_OP="${NODE_OP:-1}"
    if ! [[ "$REGEN_OP" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--regen" "numero d'operateur invalide : $REGEN_OP (1 a 9)"
        exit 2
    fi
    # cached_hub est LOCAL a ask_node_identity : le lire ici rendait le vide et,
    # sans inter-STP, l'ASP repartait en shutdown apres chaque regeneration.
    REGEN_HUB="${HUB_IP:-${OSMO_HUB_IP:-}}"
    [ -n "$REGEN_HUB" ] || REGEN_HUB="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
        "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"

    say_begin "Regeneration des configurations (noeud $REGEN_NODE, operateur $REGEN_OP)"
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Regeneration des configurations" "dry-run"
    elif regen_configs_natif "$REGEN_NODE" "$REGEN_OP" "$REGEN_HUB"; then
        say_end " OK " "$C_OK" "Regeneration des configurations" \
            "/etc/osmocom + /etc/asterisk  ·  PC 1.${REGEN_NODE}${REGEN_OP}.x"
    else
        say_end " KO " "$C_KO" "Regeneration des configurations" \
            "echec - les fichiers d'avant sont dans ${LOG_DIR:-/tmp}"
        exit 1
    fi

    # ── LE HLR SUIT LA NUMEROTATION ─────────────────────────────────────────
    # Une regeneration change les MSISDN (<noeud>00<operateur><rang>) : ceux du
    # HLR datent du plan precedent. L'IMSI, lui, ne bouge pas - il ne porte pas
    # le noeud, precisement pour que le Ki et l'authentification restent
    # valables. L'etape d'abonnes ne peut donc pas se contenter de constater
    # que l'IMSI existe : elle relit desormais AUSSI le MSISDN
    # (run_modules/21-abonnes-hlr.sh, mod_abonnes_hlr_status) et rejoue
    # "subscriber ... update msisdn" quand il a change.
    #
    # On la force en plus ici : la pile vient d'etre arretee, le HLR repartira
    # avec run.sh, et l'etape doit s'executer meme si un cache d'etat la croit
    # deja faite. Sans ca, l'abonne s'attachait (IMSI connu) mais restait
    # injoignable, sans qu'une ligne ne dise que son numero avait change.
    FORCE=1
    printf '  %sHLR%s        abonnes a reapprovisionner : MSISDN %s..%s\n' \
        "${C_DIM:-}" "${C_Z:-}" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + 1 ))" \
        "$(( REGEN_NODE * 100000 + REGEN_OP * 100 + ${N_MS:-2} ))"

    # Le noeud retenu vaut pour la suite du lancement : c'est celui qui vient
    # d'etre ecrit dans les fichiers. Le laisser vide ici, c'est laisser la
    # section « Identite SS7 » plus bas repartir sur une autre resolution et
    # reecrire par-dessus une identite differente de celle qu'on vient de poser.
    NODE_ID="$REGEN_NODE"
    NODE_OP="$REGEN_OP"
    [ -n "$REGEN_HUB" ] && HUB_IP="${HUB_IP:-$REGEN_HUB}"
    export OSMO_ROLE=operator
    export OSMO_WAN_NODE="$NODE_ID"
    [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
elif [ "${RUNTIME_ENV:-native}" = "docker" ]; then
    # DANS UN CONTENEUR seulement. Les configs y sont deja ecrites par start.sh,
    # avec l'identite du noeud : les regenerer les remplace par les valeurs des
    # gabarits, et l'interco meurt.
    export OSMO_NO_REGEN=1
else
    # SUR UNE VM sans --regen : on CONSERVE ce qui est en place. C'est l'ISO qui
    # a genere ces fichiers a la construction, avec la meme recette que
    # regen_configs_natif ; les refaire a chaque demarrage ne changerait rien et
    # ecraserait toute retouche faite sur le banc. --regen est la pour ca, et il
    # le dit.
    if [ -n "$NODE_ID" ]; then
        export OSMO_ROLE=operator
        export OSMO_WAN_NODE="$NODE_ID"
        [ -n "$HUB_IP" ] && export OSMO_HUB_IP="$HUB_IP"
    fi
fi

# --- 7ter. Identite de noeud (--node) -------------------------------------------
# AVANT le WAN et avant run.sh : les point codes sont lus par osmo-stp, osmo-msc
# et osmo-bsc a leur demarrage. Les changer apres ne servirait a rien.
#
# UNE SEULE SOURCE DE VERITE. start.sh calcule deja l'identite d'un conteneur et
# la lui passe par l'environnement ; la recalculer ici en donnerait deux, et
# c'est la mauvaise qui gagnait. On reprend donc la sienne quand elle existe.
if [ -z "$NODE_ID" ] && [ -n "${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}" ]; then
    NODE_ID="${OSMO_WAN_NODE:-$WAN_NODE_ID}"
    [ -n "$HUB_IP" ] || HUB_IP="${OSMO_HUB_IP:-}"
fi

# Sans identite alors que le WAN est demande, on ne part PAS en silence : la
# pile demarrerait avec les point codes du gabarit (1.1.2 pour tout le monde),
# deux noeuds porteraient la meme adresse SS7, et aucun ASP ne s'attacherait -
# sans qu'une seule ligne ne le signale.
if [ -z "$NODE_ID" ] && [ "${WAN_MESH:-0}" -eq 1 ]; then
    say_end " KO " "$C_KO" "Identite SS7" "WAN demande mais aucun noeud : --node N, ou WAN_NODE_ID"
    exit 1
fi

if [ -n "$NODE_ID" ]; then
    if ! [[ "$NODE_ID" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--node" "un chiffre de 1 a 9"; exit 2
    fi
    SETID="$HERE/network/set-node-id.sh"
    if [ ! -r "$SETID" ]; then
        say_end " KO " "$C_KO" "--node" "network/set-node-id.sh absent"; exit 1
    fi
    say_begin "Identite SS7 du noeud $NODE_ID"
    setid_args=(--node "$NODE_ID" --op "$NODE_OP" --mode "$NODE_MODE")
    [ -n "$HUB_IP" ] && setid_args+=(--hub-ip "$HUB_IP")
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Identite SS7 du noeud $NODE_ID" "dry-run"
        bash "$SETID" "${setid_args[@]}" --dry-run 2>&1 | sed 's/^/  /'
    elif bash "$SETID" "${setid_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-node-id.log" 2>&1; then
        say_end " OK " "$C_OK" "Identite SS7" "noeud $NODE_ID · PC 1.${NODE_ID}${NODE_OP}.x · mode $NODE_MODE"
        # Ce qui a REELLEMENT ete ecrit, relu dans le fichier. Jusqu'ici il
        # fallait deduire l'identite d'un routing-key pour savoir si elle avait
        # pris - et une regeneration ulterieure pouvait l'effacer sans bruit.
        _pc_now="$(awk "/^cs7 instance/{c=1} c && /^ *point-code /{print \$2; exit}" \
                   "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
        _hub_now="$(awk "/asp asp-to-inter/{f=1} f&&/remote-ip/{print \$2; exit}" \
                   "${OSMOCOM_CFG:-/etc/osmocom}/osmo-stp.cfg" 2>/dev/null)"
        printf "  %sSS7%s        point-code %s   inter-STP %s\n" \
            "${C_DIM:-}" "${C_Z:-}" "${_pc_now:-?}" "${_hub_now:-?}"
    else
        say_end " KO " "$C_KO" "Identite SS7" "voir ${LOG_DIR:-/tmp}/set-node-id.log"
        exit 1
    fi
    # Le numero de noeud vaut aussi pour la voix et les SMS : c'est le meme noeud.
    WAN_NODE_ID="$NODE_ID"
fi

# --- 7bis. WAN a N noeuds ------------------------------------------------------
# ICI et pas apres : ce processus va devenir run.sh (exec), il n'y a pas d'apres.
# Asterisk n'est pas encore lance - setup-wan-mesh.sh le voit, ecrit la conf et
# ne redemarre rien ; run.sh demarrera Asterisk avec le WAN deja en place.
#
# Sur vis-a-vis des gabarits : en natif rien ne reinstalle /etc/asterisk au
# demarrage (install_configs_native n'a aucun appelant, run_modules/08-gabarits.sh
# n'existe pas), donc le bloc WAN ecrit ici survit a run.sh. Si un module de
# gabarits revient un jour, il faudra rejouer le WAN APRES lui.
if [ -r "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" ] && [ "$WAN_MESH" -eq 0 ]; then
    # Table figee dans l'image (ISO construite avec --wan) : WAN_AUTO=1 dit
    # "ce systeme EST un noeud", on n'oblige pas a retaper l'option.
    if grep -q '^WAN_AUTO=1' "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null; then
        WAN_MESH=1
        printf '  %sWAN%s        table figee dans %s (WAN_AUTO=1)\n' \
            "$C_DIM" "$C_Z" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    fi
fi

if [ "$WAN_MESH" -eq 1 ] && [ "$ACTION" = "start" ]; then
    WAN_LIB="$HERE/network/wan-nodes.sh"
    WAN_MESH_SH="$HERE/network/setup-wan-mesh.sh"
    if [ ! -r "$WAN_LIB" ] || [ ! -r "$WAN_MESH_SH" ]; then
        say_end " KO " "$C_KO" "WAN" "network/wan-nodes.sh ou setup-wan-mesh.sh absent"
        exit 1
    fi
    # shellcheck source=network/wan-nodes.sh
    . "$WAN_LIB"
    # --virtualbox : segment host-only + VM + table, avant tout le reste.
    if [ "$VBOX_INTERCO" -eq 1 ] && [ -z "${WAN_NODES:-}" ]; then
        VB="$HERE/network/setup-vbox-interco.sh"
        [ -r "$VB" ] || { say_end " KO " "$C_KO" "WAN" "network/setup-vbox-interco.sh absent"; exit 1; }
        vb_args=(--host-node "$VBOX_HOST_NODE" --conf "${WAN_CONF_FILE:-/etc/osmo-wan.conf}")
        [ -n "$VBOX_NODES" ] && vb_args+=(--nodes "$VBOX_NODES")
        bash "$VB" "${vb_args[@]}" || exit 1
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        WAN_NODE_ID="$VBOX_HOST_NODE"
    fi

    if [ -n "${WAN_NODES:-}" ]; then
        wan_nodes_parse "$WAN_NODES" || exit 1
        # --node DIT DEJA quel noeud est cette machine : c'est la meme notion
        # que --wan-id, vue depuis le SS7. S'en servir evite d'echouer sur une
        # detection par IP quand la table embarquee est plus ancienne que la
        # machine - le cas d'une ISO gravee avant le dernier plan d'adressage.
        if [ "${WAN_NODE_ID:-0}" = "0" ] && [ -n "$NODE_ID" ]; then
            WAN_NODE_ID="$NODE_ID"
            printf '  %sWAN%s        noeud %s (repris de --node)\n' "$C_DIM" "$C_Z" "$WAN_NODE_ID"
        fi
        [ "${WAN_NODE_ID:-0}" != "0" ] || wan_nodes_detect_self || {
            printf '  %sWAN%s : aucune IP locale dans la table - passez --wan-id N\n' "$C_KO" "$C_Z"
            printf '  %s      (ou --node N : le numero de noeud vaut pour les deux)%s\n' "$C_DIM" "$C_Z"
            exit 1; }
    else
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
        # Une ISO diffusee sur N machines porte la MEME table : chaque machine
        # se reconnait a son IP plutot que d'exiger une image par noeud.
        wan_nodes_detect_self 2>/dev/null || true
        if [ "${WAN_NODE_COUNT:-0}" -lt 1 ] || [ "${WAN_NODE_ID:-0}" = "0" ]; then
            wan_nodes_prompt || exit 1
        fi
    fi
    wan_nodes_validate || exit 1
    printf '\n'
    wan_nodes_summary
    printf '\n'
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] %s --native --id %s\n' "$WAN_MESH_SH" "$WAN_NODE_ID"
    else
        say_begin "WAN - application de la table"
        # --native / --docker : meme distinction que pour les point codes.
        if WAN_AUTO=1 bash "$WAN_MESH_SH" "--$NODE_MODE" --id "$WAN_NODE_ID" \
                --nodes "$(wan_nodes_spec)" --ops 1 \
                --config "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" > "${LOG_DIR:-/tmp}/wan-mesh.log" 2>&1; then
            say_end " OK " "$C_OK" "WAN - noeud $WAN_NODE_ID, indicatif $(wan_local_ind)"
        else
            say_end " KO " "$C_KO" "WAN" "voir ${LOG_DIR:-/tmp}/wan-mesh.log"
        fi
    fi

    # --- 7quater. Adressage SS7 du noeud (set_stp_ip.sh) ----------------------
    # setup-wan-mesh.sh monte la VOIX et les SMS entre noeuds ; il ne touche pas
    # au SS7. Sans ce qui suit, --wan donnait un WAN ou les appels passaient mais
    # ou l'ASP inter-STP visait encore 127.0.0.1, en shutdown : l'interco SS7 ne
    # montait jamais, et rien dans la sortie ne disait pourquoi.
    #
    # set_stp_ip.sh est le seul a ecrire d'un coup les trois configs, la table
    # WAN et /etc/osmo-role. On lui passe --no-ip : l'adresse locale est deja
    # posee (DHCP ou bloc WAN ci-dessus), et --restart serait absurde ici
    # puisque run.sh va demarrer la pile juste apres, avec les fichiers corriges.
    STP_IP_SH="$HERE/set_stp_ip.sh"
    if [ -r "$STP_IP_SH" ] && [ "${WAN_NODE_ID:-0}" != "0" ]; then
        self_ip="${WAN_IP[$WAN_NODE_ID]:-}"
        hub_ip="$HUB_IP"
        [ -n "$hub_ip" ] || hub_ip="$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' /etc/osmo-role 2>/dev/null)"

        stp_args=(--operator --node "$WAN_NODE_ID" --no-ip --conf-dir "${OSMOCOM_CFG:-/etc/osmocom}")
        [ -n "$self_ip" ] && stp_args+=(--ip "$self_ip")
        [ -n "$hub_ip" ]  && stp_args+=(--hub-ip "$hub_ip")

        if [ "$DRY" -eq 1 ]; then
            printf '  [dry-run] %s %s\n' "$STP_IP_SH" "${stp_args[*]}"
        else
            say_begin "Adressage SS7 - inter-STP ${hub_ip:-?}"
            # </dev/null : appel automatique, jamais interactif (set_stp_ip.sh
            # demande l'adresse du hub quand elle manque - ici, personne ne
            # repondrait et le lancement resterait fige).
            if bash "$STP_IP_SH" "${stp_args[@]}" </dev/null > "${LOG_DIR:-/tmp}/set-stp-ip.log" 2>&1; then
                say_end " OK " "$C_OK" "Adressage SS7" "noeud $WAN_NODE_ID -> inter-STP ${hub_ip:-?}"
            else
                # Non fatal : la pile locale tourne tres bien sans interco. On le
                # DIT, plutot que de laisser croire a un WAN complet.
                say_end " ~~ " "$C_SK" "Adressage SS7" "echec - voir ${LOG_DIR:-/tmp}/set-stp-ip.log"
            fi
        fi
    fi
fi

# --- 7quinquies. Le wrapper tcpdump ------------------------------------------
# La capture GSMTAP est lancee par run_modules/75-gsmtap.sh, dans qemu-src : un
# autre depot, qu'on ne modifie pas. Elle ecrit un pcap NON BORNE, et la racine
# du live etant un tmpfs, une capture un peu chargee finit par remplir la RAM.
#
# Le wrapper y substitue un anneau. Il est aussi pose par build-iso.sh, mais une
# ISO deja gravee ne le connait pas, et un live sans persistance le perd a chaque
# reboot : le reposer ICI, a chaque demarrage de la pile, est ce qui le rend
# effectif sans reconstruire ni toucher a qemu-src.
#
# DEUX PIEGES, DEUX PARADES - c'est tout l'objet de ce script :
#   -Z root : avec -C/-W, tcpdump cree les membres suivants de l'anneau APRES
#             avoir lache ses privileges. Sans lui : "Permission denied", et
#             AUCUNE capture - alors que sans -C il ouvrait le fichier avant.
#   le lien : avec -C/-W, tcpdump numerote (capture.pcap0, .pcap1...) ; le nom
#             exact demande n'existe jamais, et la barriere du module - un
#             "test -s <nom exact>" - conclut a un echec sur une capture qui
#             tourne. On maintient <nom exact> -> membre courant.
#
# OSMO_NO_PCAP_RING=1 saute l'installation.
install_pcap_wrapper() {
    local dst=/usr/local/bin/tcpdump tmp
    [ "${OSMO_NO_PCAP_RING:-0}" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ] || return 0
    command -v tcpdump >/dev/null 2>&1 || return 0

    tmp="$(mktemp)" || return 0
    cat > "$tmp" <<'PCAPWRAP'
#!/bin/sh
# tcpdump - wrapper osmo_egprs : impose un anneau aux captures sur fichier.
# Pose par start-direct.sh et par build-iso.sh. Voir leurs commentaires.
# Reglable : OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump

has_w=0; has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Rien a borner, ou l'appelant a deja choisi son anneau : on s'efface.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Le veilleur du lien. Lance AVANT l'exec : apres, ce processus EST tcpdump.
# $$ survit a l'exec, donc il suit exactement sa vie et s'arrete avec lui.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
PCAPWRAP

    # Le wrapper s'appelle "tcpdump" et vit dans /usr/local/bin, qui precede
    # /usr/bin : il ne doit donc JAMAIS s'installer par-dessus le vrai binaire,
    # sous peine de recursion infinie. On verifie ou pointe le vrai.
    case "$(command -v tcpdump)" in
        "$dst") ;;                       # deja le wrapper, on remplace
        /usr/bin/tcpdump|/usr/sbin/tcpdump|/bin/tcpdump) ;;
        *) rm -f "$tmp"; return 0 ;;     # emplacement inattendu : on s'abstient
    esac

    if cmp -s "$tmp" "$dst" 2>/dev/null; then
        rm -f "$tmp"                     # deja a jour, rien a dire
    else
        install -m 0755 "$tmp" "$dst" 2>/dev/null \
            && printf '  %spcap%s       anneau de capture arme (%s)\n' \
                 "$C_DIM" "$C_Z" "$dst"
        rm -f "$tmp"
    fi
}
[ "$DRY" -eq 1 ] || install_pcap_wrapper

# --- 7ter. ARRET SYSTEMATIQUE AVANT DEMARRAGE ---------------------------------
# Tout demarrage arrete d'abord la pile. Ce n'est pas de la prudence : sans cela
# le lanceur differe du pont part sur un etat ambigu.
#
# CE QUE CA CORRIGE. La barriere du pont attend osmo-bts-trx pour savoir que les
# ports 5700-5702 sont a lui. Si un run precedent tourne encore, son osmo-bts-trx
# est deja la : la barriere est franchie a l'instant meme, le pont binde EN PLEIN
# teardown de run.sh, qui le tue derriere (f:pont/pont.py est dans _td_patterns)
# -- et rien ne le relance. Symptome : « le pont n'a pas de bursts », sans un
# message pour le dire. La barriere attend desormais les deux fronts (disparition
# puis apparition), mais partir d'une pile arretee rend la question sans objet.
#
# Et cela libere les ports : un fake_trx ou un trxcon orphelin suffit a faire
# echouer le demarrage suivant sur « port UDP 5720 deja pris » -- constate le
# 27/08. Le killall couvre les processus Python que le registre ne connait pas.
#
# CALYPSO_NO_AUTOSTOP=1 desactive ce comportement.
if [ "$DRY" -eq 0 ] && [ "${CALYPSO_NO_AUTOSTOP:-0}" != 1 ]; then
    say_begin "Arret de la pile avant demarrage"
    bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
    declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
    if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
        killall python3 2>/dev/null || true
    fi
    say_end " OK " "$C_OK" "Arret de la pile avant demarrage"
fi

# --- 8. lancement : exec run.sh -----------------------------------------------
# ── LES ADRESSES QUE LES CONFIGS RECLAMENT DOIVENT EXISTER ──────────────────
# Un demon qui se lie a une adresse absente ne demarre pas, et il le dit dans
# SON journal, pas dans le notre :
#     osmo-ggsn : « gtp bind-ip 192.168.2.10 » -> adresse introuvable localement
#     osmo-sgsn : « listen 192.168.2.10 23000 » -> idem
# Ces adresses viennent du generateur de gabarits (op_private_ip), pas du
# reseau : rien ne les pose. Elles etaient figees dans 20-dhcp.network cote ISO,
# donc absentes de toute machine montee autrement - et la panne se lisait comme
# un defaut de coeur paquet.
#
# osmo-ip-plan.sh les EXTRAIT des configs plutot que de les recalculer (le plan
# peut venir d'un autre generateur que le notre), choisit la carte qui fournit
# reellement Internet, et retombe sur la boucle locale quand aucune ne mene
# nulle part. Il ne fait rien dans un conteneur : la, c'est docker qui adresse.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    IPPLAN="$HERE/network/osmo-ip-plan.sh"
    if [ -r "$IPPLAN" ]; then
        say_begin "Adresses privees du noeud"
        _ipout="$(OSMOCOM_CFG="${OSMOCOM_CFG:-/etc/osmocom}" \
                  OSMO_WAN_NODE="${NODE_ID:-${OSMO_WAN_NODE:-}}" \
                  bash "$IPPLAN" --apply 2>&1)" || true
        say_end " OK " "$C_OK" "Adresses privees du noeud" \
            "$(printf '%s' "$_ipout" | tail -1 | sed 's/^osmo-ip-plan : //')"
    fi
fi

say_begin "Transmission a run.sh"
if [ $DRY -eq 1 ]; then
    say_end " -- " "$C_DIM" "Transmission a run.sh" "dry-run"
    printf '  commande : CALYPSO_PROFILE=%s bash %s %s\n' \
        "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
    exit 0
fi
say_end " OK " "$C_OK" "Transmission a run.sh" "profil=$CALYPSO_PROFILE"
# Hand-off total : ce processus devient run.sh
exec bash "$RUN_SH" "${RUN_ARGS[@]}"
