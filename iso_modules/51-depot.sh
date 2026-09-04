#!/bin/bash
# iso_modules/51-depot.sh - etape 5a : osmo-operator a jour, coeur.env
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── osmo-operator : ARBRE a jour depuis GitHub, AVEC son .git ─────────────────
# La copie docker cp ci-dessus peut etre perimee ; on avance la branche main du
# depot (start-direct.sh, run.sh, scripts/, configs/, build-iso.sh...) dans l'ISO.
EGPRS_BRANCH="${OSMO_EGPRS_BRANCH:-main}"
EGPRS_REPO="${OSMO_EGPRS_REPO:-https://github.com/bbaranoff/osmo-operator}"
echo -e "${GREEN}[5a/9] Clone de osmo-operator (branche ${EGPRS_BRANCH})...${NC}"
# [2026-08-31] CLONE, PAS "fetch + merge --ff-only" SUR L ARBRE DE L IMAGE.
# L ancienne version avancait en place le depot venu du docker cp. Elle avait
# deux defauts qui se voyaient au moment ou l on veut justement graver :
#   - --ff-only echoue des que l arbre de l image porte le moindre commit local
#     ou diverge, et la branche d echec se contentait d un ⚠ jaune : l ISO se
#     construisait alors avec l arbre de l IMAGE, c est-a-dire avec du code
#     vieux de la derniere reconstruction docker, sans que rien n arrete le
#     build. On croyait graver son travail, on gravait celui d avant.
#   - trois chemins (arbre avec .git / arbre sans .git / rien) pour un seul
#     besoin : avoir le depot a jour dans l ISO.
# Un clone rend le resultat previsible : ce qui est sur la branche est ce qui
# est grave, point. Le .git est conserve - c est un clone, pas un tarball - donc
# update.sh peut toujours faire son fetch au demarrage plutot que d effacer et
# recloner a chaque boot (wipe=1), et l on sait sur quel commit on tourne.
#
# On clone A COTE puis on bascule : si le reseau manque, l arbre de l image
# reste en place. Effacer d abord donnerait une ISO sans depot du tout.
EGPRS_TREE="$ROOTFS/opt/GSM/osmo-operator"
EGPRS_TMP="$WORK/osmo-operator-clone"
rm -rf "$EGPRS_TMP"
if [ "$OSMO_ISO_INHERITED" = "1" ] && [ -d "$EGPRS_TREE/.git" ]; then
    echo -e "  ${GREEN}✓${NC} osmo-operator : arbre du rootfs herite conserve"
elif GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$EGPRS_BRANCH" "$EGPRS_REPO" "$EGPRS_TMP" >/dev/null 2>&1; then
    rm -rf "$EGPRS_TREE"
    mkdir -p "$ROOTFS/opt/GSM"
    mv "$EGPRS_TMP" "$EGPRS_TREE"
    echo -e "  ${GREEN}✓${NC} osmo-operator clone (${EGPRS_BRANCH}, .git conserve) - $(git -C "$EGPRS_TREE" log -1 --format='%h %s')"
else
    rm -rf "$EGPRS_TMP"
    if [ -d "$EGPRS_TREE" ]; then
        echo -e "  ${YELLOW}⚠${NC} osmo-operator : clone impossible (reseau ?) - arbre de l'image conserve" >&2
    else
        echo -e "  ${RED}✗${NC} osmo-operator : clone impossible ET absent de l'image" >&2
    fi
fi

# ── Feed HLR : aligner N_MS sur le nombre de MS embarques ────────────────────
# run_modules/21-abonnes-hlr.sh retombe sur ": "${N_MS:=1}"" : sans ce fichier
# un SEUL abonne etait provisionne alors que l'ISO en declare ISO_N_MS, et les
# MS suivants se voyaient refuser le rattachement ("IMSI unknown in HLR") -
# panne lue a tort comme un defaut radio.
#
# PAS dans /opt/GSM/osmo-operator/environment : ce fichier n'est pas dans git. Il y
# a survecu au demarrage tant que personne ne mettait le depot a jour, et pas une
# minute de plus - a l'epoque osmo-update.service effacait et reclonait l'arbre
# a chaque boot (wipe=1), aujourd'hui "osmo-update" fait un git fetch, dont le
# reset --hard emporte de la meme facon ce qui n'est pas suivi. N_MS retombait
# a 1, MS#2 restait inconnu du HLR, et start-direct.sh le lancait quand meme.
# /opt/GSM/qosmo-grgsm/environment, lui, n'a jamais existe : ce depot-la nomme son
# repertoire "environnement".
# /etc/osmocom n'appartient a aucun depot : ce qui y est ecrit reste.
mkdir -p "$ROOTFS/etc/osmocom"
cat > "$ROOTFS/etc/osmocom/coeur.env" <<COEUR
# coeur.env - genere par build-iso.sh. Aligne le nombre d'abonnes provisionnes
# dans le HLR sur le nombre de MS embarques par l'ISO (ISO_N_MS).
: "\${N_MS:=$ISO_N_MS}"
: "\${OPERATOR_ID:=1}"
COEUR
echo -e "  ${GREEN}✓${NC} coeur.env : ${CYAN}N_MS=${ISO_N_MS}${NC} (/etc/osmocom)"


