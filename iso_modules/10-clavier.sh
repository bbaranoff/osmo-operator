#!/bin/bash
# iso_modules/10-clavier.sh - clavier de l image (question ou --kb)
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ══════════════════════════════════════════════════════════════════════════════
# LES QUESTIONS : toutes ici, une seule fois, avant que quoi que ce soit ne parte
# ══════════════════════════════════════════════════════════════════════════════
# Une question posee au milieu d'une construction d'une heure attend un humain
# qui, lui, est parti. Et posee dans l'IMAGE - au premier boot - elle bloque
# chaque machine qui demarre, alors que la reponse est la meme pour toutes.
#
# Tout ce qui se demande se demande donc ICI :
#   - avant la construction, pour ne jamais interrompre une passe en cours ;
#   - une seule fois, meme quand on produit les DEUX images : la reponse part
#     dans l'environnement (export), et les passes filles en heritent ;
#   - jamais en CI : sans terminal, on prend le defaut au lieu d'attendre un
#     EOF qui, sous set -e, ferait echouer la construction.
#
# --kb=XX ou OSMO_ISO_KB=XX court-circuitent la question.
ISO_KB_DEFAULT="fr"
if [ -z "${OSMO_ISO_KB:-}" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}══ Clavier de l'image ══${NC}"
        echo "  1) fr   2) us   3) de   4) es   5) it"
        echo "  6) pt   7) gb   8) be   9) ch   0) autre"
        read -rp "  Choix [1] : " _kb_choice || _kb_choice=""
        case "${_kb_choice:-1}" in
            1|"") OSMO_ISO_KB="fr" ;;
            2) OSMO_ISO_KB="us" ;;  3) OSMO_ISO_KB="de" ;;
            4) OSMO_ISO_KB="es" ;;  5) OSMO_ISO_KB="it" ;;
            6) OSMO_ISO_KB="pt" ;;  7) OSMO_ISO_KB="gb" ;;
            8) OSMO_ISO_KB="be" ;;  9) OSMO_ISO_KB="ch" ;;
            0) read -rp "  Layout (fr, us, ru, ar...) : " OSMO_ISO_KB || OSMO_ISO_KB=""
               OSMO_ISO_KB="${OSMO_ISO_KB:-$ISO_KB_DEFAULT}" ;;
            *) OSMO_ISO_KB="$ISO_KB_DEFAULT" ;;
        esac
    else
        OSMO_ISO_KB="$ISO_KB_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : clavier ${OSMO_ISO_KB} (--kb=XX pour changer)${NC}"
    fi
fi
export OSMO_ISO_KB
echo -e "  ${GREEN}✓${NC} clavier de l'image : ${CYAN}${OSMO_ISO_KB}${NC}"

# ── Sans argument : LES DEUX images ─────────────────────────────────────────
# Un WAN a besoin de deux choses differentes - un hub SS7 et des noeuds - et
# rien ne dit laquelle on veut quand on ne precise rien. On produit donc les
# deux, par deux passes completes.
#
# UNE SEULE image d'operateur suffit pour les neuf noeuds : le numero se choisit
# au demarrage (`start-direct.sh --node N`), qui reecrit les point codes. C'est
# la raison pour laquelle on ne fabrique pas osmo-operator-1..9.
#
# ══════════════════════════════════════════════════════════════════════════════
# CE QUI NE SE FAIT QU UNE FOIS : les paquets de l hote, le build docker
# ══════════════════════════════════════════════════════════════════════════════
# [2026-09-03] Chaque passe fille refaisait son apt sur l hote et SON build
# docker (build.sh, puis Dockerfile.run, puis Dockerfile.lite) : quatre images
# = quatre fois le meme travail. Les deux fonctions ci-dessous sont appelees
# par la passe parente (--all) une seule fois, et les filles les sautent sur
# OSMO_ISO_HOST_READY / OSMO_ISO_IMAGE_READY. Une passe lancee seule les
# appelle elle-meme, une fois.


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
