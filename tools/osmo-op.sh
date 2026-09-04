#!/bin/bash
# =============================================================================
#  osmo-op - QUEL OPERATEUR L ECRAN REGARDE
# =============================================================================
#  Le bureau du banc a UN seul encart (tools/osmo-panel.py) et UN seul Conky
#  (tools/conky-osmo-status.sh), mais un banc multi en porte trois plus le hub.
#  Le choix vit dans un unique fichier, /run/osmo-fft/operator, que les deux
#  lisent a chaque rafraichissement :
#
#      OP=2  MODE=docker  IP=172.20.0.12  NAME=osmo-operator-2
#      DASH=http://172.20.0.12:8080
#
#  Ce script est ce qui l ECRIT, et la seule definition de "la liste des
#  operateurs" - l encart et le Conky s y referent, ils ne la recalculent pas.
#
#      osmo-op                 l operateur courant
#      osmo-op --list          les operateurs et leur etat
#      osmo-op --next / --prev l operateur suivant / precedent  (les fleches)
#      osmo-op --set N         l operateur N
#
#  [2026-09-04] LES OPERATEURS ARRETES COMPTENT AUSSI. L encart ne montrait ses
#  fleches que si au moins deux operateurs etaient EN MARCHE (docker ps) : sur
#  un banc ou op2 et op3 n avaient pas encore demarre, il n y avait aucune
#  fleche - donc aucun moyen d aller voir POURQUOI ils n avaient pas demarre.
#  L ecran doit pouvoir regarder un operateur eteint : c est meme la le seul
#  moment ou on en a besoin. L etat (actif / arrete) est affiche, pas filtre.
#
#  EN REVANCHE, PAS D OPERATEURS INVENTES. Sans /etc/osmocom/osmo-multi.conf -
#  donc sur un banc a un seul operateur - la liste rend le seul natif, et
#  l encart cache ses fleches : il n y a nulle part ou aller. Les fleches
#  n apparaissent que quand la topologie declare vraiment plusieurs operateurs.
# =============================================================================
set -u
RUN="${OSMO_FFT_DIR:-/run/osmo-fft}"
OP_FILE="$RUN/operator"
MULTI_CONF="${MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
DASH_PORT="${DASH_PORT:-8080}"
HUB_NAME="${MULTI_HUB_NAME:-osmo-inter-stp}"
M3UA_PORT="${MULTI_M3UA_PORT:-2908}"

# ── LA LISTE : "idx mode ip" par ligne ──────────────────────────────────────
# La topologie d abord (MULTI_OPS de osmo-multi.conf, ecrit par addition.sh) ;
# a defaut, op 1 natif + les suivants en docker, sur le plan d adressage du
# hub (172.20.0.1<idx>, cf. start-multi.sh).
liste() {
    local specs="" idx mode ip
    if [ -r "$MULTI_CONF" ]; then
        specs="$(sed -nE 's/^MULTI_OPS="?([^"]*)"?.*/\1/p' "$MULTI_CONF" | head -1)"
    fi
    if [ -n "$specs" ]; then
        for s in $specs; do
            IFS=: read -r idx mode ip _ <<< "$s"
            [ -n "$idx" ] || continue
            echo "$idx ${mode:-docker} ${ip:-}"
        done
        # ── ET LE HUB, EN DERNIERE POSITION ─────────────────────────────────
        # [2026-09-04] L inter-STP ne figurait nulle part dans le cycle des
        # fleches : on pouvait regarder les trois operateurs, jamais le noeud
        # qui les relie - alors que c est LUI qu on interroge quand le SS7 va
        # mal. Il devient donc le quatriemme arret, apres op3, avant de revenir
        # a op1. Son "index" est son nom (hub) et non un chiffre : il ne
        # numerote pas un operateur, et l encart le rend par une vue SS7 (la
        # matrice, les ASP, son journal) au lieu du spectre I/Q - un hub M3UA
        # n a pas de radio, une FFT n y voudrait rien dire.
        _hub_ip="$(sed -nE 's/^MULTI_HUB_IP=([^ #]*).*/\1/p' "$MULTI_CONF" | head -1)"
        echo "hub interstp ${_hub_ip:-172.20.0.10}"
    else
        # Pas de topologie : un seul operateur, le natif. Rien a parcourir.
        echo "1 native "
    fi
}

# actif IDX MODE [IP] : l operateur tourne-t-il ?
#
# [2026-09-04] « ARRETE » VOULAIT PARFOIS DIRE « JE N AI PAS LE DROIT DE VOIR ».
# Le Conky et l encart tournent sous le compte de la SESSION, pas sous root, et
# ce compte n est pas forcement dans le groupe `docker` :
#     $ docker ps
#     permission denied while trying to connect to the docker API at
#     unix:///var/run/docker.sock
# `docker ps 2>/dev/null | grep -qx` rendait alors faux, et l ecran annoncait
# op2 et op3 ARRETES pendant que `docker ps` en root les montrait « Up ». Une
# sonde qui confond « absent » et « invisible » est une sonde qui ment - le
# depot appelle ca ailleurs une sonde mensongere, et c en est une.
#
# On distingue donc les deux cas : si docker ne repond pas A NOUS, on retombe
# sur une sonde qui ne demande aucun privilege - le tableau de bord de
# l operateur, sur son IP du reseau du hub. Le compte est ajoute au groupe
# `docker` par ailleurs (installer/calamares/modules/users.conf, addition.sh) ;
# ce repli couvre la session deja ouverte, ou le groupe n a pas encore pris.
actif() {
    if [ "$2" = interstp ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${HUB_NAME}"
        else
            # Sans acces docker : le port M3UA du hub, en SCTP - une sonde TCP
            # y serait muette, d ou `ss` plutot qu un /dev/tcp.
            ss -an 2>/dev/null | awk -v p=":${M3UA_PORT}" \
               '$1=="sctp" && index($5,p) {f=1} END{exit !f}'
        fi
    elif [ "$2" = native ]; then
        pgrep -x osmo-bsc >/dev/null 2>&1 || pgrep -x osmo-stp >/dev/null 2>&1
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "osmo-operator-$1"
    elif [ -n "${3:-}" ]; then
        timeout 1 bash -c "echo >/dev/tcp/$3/${DASH_PORT}" 2>/dev/null
    else
        return 1
    fi
}

courant() { sed -n 's/^OP=//p' "$OP_FILE" 2>/dev/null | head -1; }

ecrire() {
    local idx="$1" mode="$2" ip="$3"
    mkdir -p "$RUN" 2>/dev/null || true
    local nom="osmo-operator-$idx"
    [ "$mode" = interstp ] && nom="$HUB_NAME"
    printf 'OP=%s\nMODE=%s\nIP=%s\nNAME=%s\nDASH=http://%s:%s\n' \
        "$idx" "$mode" "$ip" "$nom" "${ip:-127.0.0.1}" "$DASH_PORT" > "$OP_FILE.tmp" \
        && mv -f "$OP_FILE.tmp" "$OP_FILE"
}

# decale +1 / -1 dans la liste, en boucle.
decale() {
    local pas="$1" cur n i=0 sel=0
    cur="$(courant)"; cur="${cur:-1}"
    mapfile -t L < <(liste)
    n="${#L[@]}"; [ "$n" -gt 0 ] || return 1
    for i in "${!L[@]}"; do
        [ "${L[$i]%% *}" = "$cur" ] && sel="$i"
    done
    sel=$(( (sel + pas + n) % n ))
    # shellcheck disable=SC2086
    set -- ${L[$sel]}
    ecrire "$1" "$2" "${3:-}"
    echo "op $1 (${2})"
}

case "${1:-}" in
    --list|-l)
        while read -r idx mode ip; do
            if actif "$idx" "$mode" "$ip"; then e="actif"; else e="arrete"; fi
            [ "$idx" = "$(courant)" ] && e="$e  <- ecran"
            printf '  op %-2s %-7s %-13s %s\n' "$idx" "$mode" "${ip:-(hote)}" "$e"
        done < <(liste) ;;
    --next|-n) decale 1 ;;
    --prev|-p) decale -1 ;;
    --set|-s)
        [ $# -ge 2 ] || { echo "usage: $0 --set N" >&2; exit 2; }
        while read -r idx mode ip; do
            if [ "$idx" = "$2" ]; then ecrire "$idx" "$mode" "$ip"; echo "op $idx ($mode)"; exit 0; fi
        done < <(liste)
        echo "op $2 : absent de la topologie ($MULTI_CONF)" >&2; exit 1 ;;
    ""|--current|-c)
        [ -r "$OP_FILE" ] && cat "$OP_FILE" || echo "OP=1"$'\n'"MODE=native" ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
