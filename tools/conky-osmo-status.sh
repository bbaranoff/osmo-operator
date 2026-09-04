#!/bin/bash
# conky-osmo-status.sh - les lignes du Conky du banc (configs/conky/osmo-conky.conf)
#   role | net | core | radio | subs | services
# Chaque sortie est du texte conky (execpi) : ${color2} vert, ${color3} rouge,
# ${color4} jaune. Rapide et sans dependance dure : ce qui manque s affiche "-".
set -u
OK='${color2}●${color}'; KO='${color3}○${color}'; WARN='${color4}●${color}'
C1='${color1}'; C='${color}'; C2='${color2}'; AR='${alignr}'
have() { command -v "$1" >/dev/null 2>&1; }
# ── pgrep -x COMPARE AU NOM TRONQUE A 15 CARACTERES ─────────────────────────
# [2026-09-04] « pgrep -x osmo-sip-connector » ne matche JAMAIS : le noyau ne
# garde que 15 caracteres de nom (comm), soit « osmo-sip-connec ». Idem pour
# proto-smsc-daemon (« proto-smsc-daem »). SIP et SMSC restaient rouges avec les
# deux demons en marche. On tronque donc le motif comme le noyau tronque le nom.
# ── L OPERATEUR CHOISI DANS L ENCART ────────────────────────────────────────
# [2026-09-04] tools/osmo-panel.py (fleches < >) ecrit /run/osmo-fft/operator :
# OP=, MODE=native|docker, IP=, NAME=osmo-operator-N. Sur un conteneur, chaque
# sonde (pgrep, port, sqlite) s execute DEDANS (docker exec) : le Conky suit
# l encart. Sans fichier ou en natif : la machine, comme avant.
OP_FILE="${OSMO_FFT_DIR:-/run/osmo-fft}/operator"
OP_ID=1; OP_MODE=native; OP_NAME=""
if [ -r "$OP_FILE" ]; then
    OP_ID="$(sed -n 's/^OP=//p' "$OP_FILE" | head -1)"; OP_ID="${OP_ID:-1}"
    OP_MODE="$(sed -n 's/^MODE=//p' "$OP_FILE" | head -1)"; OP_MODE="${OP_MODE:-native}"
    OP_NAME="$(sed -n 's/^NAME=//p' "$OP_FILE" | head -1)"
fi
# in_op CMD... : execute la commande ici, ou dans le conteneur de l operateur.
if [ "$OP_MODE" = docker ] && [ -n "$OP_NAME" ]; then
    in_op() { docker exec "$OP_NAME" "$@" 2>/dev/null; }
else
    in_op() { "$@"; }
fi
port_open() {
    if [ "$OP_MODE" = docker ]; then in_op timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$1" 2>/dev/null
    else timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$1" 2>/dev/null; fi
}
alive_x() { in_op pgrep -x "${1:0:15}" >/dev/null 2>&1; }
# ── LE BANC EST-IL DEBOUT ? ─────────────────────────────────────────────────
# [2026-09-04] Sans banc, les sections « Coeur GSM », « Radio / MS », « Abonnes »
# et « Services » affichaient TRENTE pastilles rouges - un mur d alarmes pour
# dire une seule chose : rien ne tourne. On ne lit plus rien la-dedans, et
# surtout on ne voit plus ce qui, LUI, compte quand le banc est a l arret : le
# reseau, l espace disque, la machine.
#
# Quand la pile est a terre, ces sections ne rendent donc RIEN : le Conky se
# replie sur la machine, et les titres restent comme reperes. La section Reseau
# est la seule qui parle TOUJOURS - elle ne depend d aucun operateur, et c est
# precisement ce qu on regarde quand on cherche pourquoi le banc ne monte pas.
#
# Le critere : le STP ou le BSC de l operateur affiche. Ce sont les deux
# processus qui existent des que le coeur est monte, dans les deux mondes
# (natif et conteneur) - et in_op les cherche au bon endroit.
banc_debout() { alive_x osmo-stp || alive_x osmo-bsc || alive_x osmo-msc; }
# Motif sur la ligne de commande complete (scripts python, chemins).
alive_f() { in_op pgrep -f "$1" >/dev/null 2>&1; }

# ── LA MATRICE : AFFICHAGE (instantane) ET MESURE (en tache de fond) ────────
MATRIX_FILE="${OSMO_FFT_DIR:-/run/osmo-fft}/ss7-matrix"
MATRIX_LOCK="${OSMO_FFT_DIR:-/run/osmo-fft}/.ss7-matrix.lock"
MATRIX_TTL="${OSMO_MATRIX_TTL:-300}"

matrice() {
    local age=999999
    [ -f "$MATRIX_FILE" ] && age=$(( $(date +%s) - $(stat -c %Y "$MATRIX_FILE" 2>/dev/null || echo 0) ))
    # Perime (ou jamais mesure) : on lance la mesure DETACHEE et on rend la
    # main tout de suite. Le verrou est un mkdir : atomique, et il disparait
    # avec le repertoire meme si la mesure est tuee (trap).
    if [ "$age" -gt "$MATRIX_TTL" ]; then
        ( setsid "$0" --refresh-matrix >/dev/null 2>&1 & ) 2>/dev/null
    fi
    if [ -s "$MATRIX_FILE" ]; then
        cat "$MATRIX_FILE"
    else
        echo "  ${C1}matrice SS7${C} : premiere mesure en cours..."
    fi
}

refresh_matrice() {
    mkdir "$MATRIX_LOCK" 2>/dev/null || return 0     # une mesure suffit
    trap 'rmdir "$MATRIX_LOCK" 2>/dev/null' EXIT
    local dir out
    dir="$(cd "$(dirname "$0")/.." && pwd)"
    [ -x "$dir/checks/ss7_check.sh" ] || return 0
    # NO_COLOR + suppression des sequences ANSI : on repeint aux couleurs du
    # Conky (${color1..4}), qui ne comprend pas les codes d un terminal.
    out="$(cd "$dir" && NO_COLOR=1 timeout 240 ./checks/ss7_check.sh 2>/dev/null \
           | sed -e 's/\x1b\[[0-9;]*m//g')"
    [ -n "$out" ] || return 0
    {
        # Le tableau : la ligne d en-tete (les colonnes OpN) puis une ligne par
        # operateur, jusqu a la ligne vide qui clot le bloc.
        printf '%s\n' "$out" \
        | awk '/MATRICE DE CONNECTIVITE/{f=1; next}
               f && /^[[:space:]]*$/ && seen {exit}
               f && /Op/ {seen=1; print}' \
        | sed -e 's/[[:space:]]*$//' \
              -e 's/\bself\b/${color1}self${color}/g' \
              -e 's/\bvia\b/${color2}via${color}/g' \
              -e 's/\bFAIL\b/${color3}FAIL${color}/g'
        # Le bilan, tel que ss7_check le formule.
        printf '%s\n' "$out" | awk '/SS7 (OK|DEGRADE|KO)/{sub(/^[[:space:]]+/,""); print; exit}' \
        | sed -e 's/^SS7 OK/${color2}SS7 OK${color}/' \
              -e 's/^SS7 DEGRADE/${color4}SS7 DEGRADE${color}/' \
              -e 's/^SS7 KO/${color3}SS7 KO${color}/' \
              -e 's/\([0-9]\+\) pass/${color2}\1 pass${color}/' \
              -e 's/\([0-9]\+\) fail/${color3}\1 fail${color}/' \
              -e 's/\([0-9]\+\) warn/${color4}\1 warn${color}/'
    } > "$MATRIX_FILE.tmp" 2>/dev/null && mv -f "$MATRIX_FILE.tmp" "$MATRIX_FILE"
}

case "${1:-}" in
--refresh-matrix) refresh_matrice; exit 0 ;;
role)
    r="$(awk -F= '/^OSMO_ROLE=/{print $2}' /etc/osmo-role 2>/dev/null)"
    n="$(awk -F= '/^OSMO_NODE=|^NODE_ID=/{print $2}' /etc/osmo-role 2>/dev/null | head -1)"
    h="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role 2>/dev/null)"
    live=""; [ -e /run/live/rootfs/filesystem.squashfs ] && live=" \${color4}LIVE${C}"
    opl=""; [ "$OP_MODE" = docker ] && opl=" \${color2}op $OP_ID${C} ($OP_NAME)"
    echo "${r:-operateur}${n:+ noeud $n}${h:+ · hub $h}$live$opl" ;;
net)
    ip -o -4 addr show up 2>/dev/null | awk '$2!="lo" && $2!~/^(veth|br-|docker|apn)/ {print $2, $4}' | sort -u | head -5 \
    | while read -r ifc addr; do
        printf '%s ${alignr}${downspeedf %s} K/s ↓  ${upspeedf %s} K/s ↑\n%-8s ${color1}%s${color}\n' "$ifc" "$ifc" "$ifc" "" "$addr"
      done
    # Cette section ne se replie JAMAIS (voir banc_debout) : quand le banc est a
    # l arret, c est elle qu on lit. Si le filtre ci-dessus n a rien laisse
    # passer - que des veth/docker, ou aucune adresse - on le dit, plutot que
    # de rendre une section vide qu on prendrait pour une panne du Conky.
    if [ -z "$(ip -o -4 addr show up 2>/dev/null | awk '$2!="lo" && $2!~/^(veth|br-|docker|apn)/')" ]; then
        if [ -n "$(ip -o -4 addr show up 2>/dev/null | awk '$2!="lo"')" ]; then
            echo "${WARN} aucune carte physique - seulement les interfaces du banc"
        else
            echo "${WARN} aucune interface avec adresse"
        fi
    fi ;;
core)
    banc_debout || exit 0
    # nom:processus:port VTY
    for e in HLR:osmo-hlr:4258 MSC:osmo-msc:4254 BSC:osmo-bsc:4242 STP:osmo-stp:4239 \
             MGW:osmo-mgw:4243 SGSN:osmo-sgsn:4245 GGSN:osmo-ggsn:4260 PCU:osmo-pcu:4240 \
             BTS:osmo-bts-trx:4241 SIP:osmo-sip-connector:4256 SMSC:proto-smsc-daemon:0 PBX:asterisk:0; do
        IFS=: read -r name proc port <<< "$e"
        if alive_x "$proc"; then
            if [ "$port" != 0 ] && ! port_open "$port"; then s="$WARN"; else s="$OK"; fi
        else s="$KO"; fi
        printf '%s %-5s' "$s" "$name"
        i=$((${i:-0}+1)); [ $((i % 4)) -eq 0 ] && echo
    done; echo ;;
radio)
    banc_debout || exit 0
    phy="-"
    pgrep -f 'qemu-system-arm' >/dev/null 2>&1 && phy="qemu (Calypso emule)"
    pgrep -f 'fake_trx.py' >/dev/null 2>&1 && phy="faketrx"
    pgrep -x virtphy >/dev/null 2>&1 && phy="virtphy"
    pgrep -f 'pont.py' >/dev/null 2>&1 && phy="$phy + pont"
    echo "PHY ${C1}${phy}${C}"
    # ── CE QUE CHAQUE PASTILLE CHERCHE VRAIMENT ──────────────────────────
    # [2026-09-04] Le banc de l'ISO tourne en faketrx + pont : il n'y a AUCUN
    # binaire osmo-trx, le transceiver de la BTS est pont/pont.py et celui du
    # MS#2 fake_trx.py. gapk n'existe que sous le nom osmo-gapk, lance par
    # gapk-start.sh le temps d'un appel ; hors appel, le veilleur
    # (gapk-start.sh auto) EST l'etat nominal. gr-gsm est remplace par
    # qosmo-grgsm (gsm_sniff.py) : grgsm_decode n'est pas installe. Les trois
    # restaient rouges sur un banc en parfait etat.
    s=""
    { alive_f 'osmo-trx' || alive_f 'pont/pont\.py' || alive_f 'fake_trx\.py'; } && s="$s$OK TRX     " || s="$s$KO TRX     "
    alive_x mobile                  && s="$s$OK MOBILE  " || s="$s$KO MOBILE  "
    alive_x trxcon                  && s="$s$OK TRXCON  " || s="$s$KO TRXCON  "
    alive_f 'qemu-system-arm'       && s="$s$OK QEMU    " || s="$s$KO QEMU    "
    if alive_x osmo-gapk; then s="$s$OK GAPK    "
    elif alive_f 'gapk-start\.sh'; then s="$s$OK GAPK    "
    else s="$s$KO GAPK    "; fi
    { alive_f 'grgsm_(decode|livemon)' || alive_f 'gsm_sniff\.py' || alive_x qosmo-grgsm; } \
        && s="$s$OK GRGSM  " || s="$s$KO GRGSM  "
    echo "$s"
    arfcn="$(in_op cat /etc/osmocom/osmo-bsc.cfg 2>/dev/null | awk '/^ *arfcn /{print $2; exit}')"
    plmn="$(in_op cat /etc/osmocom/osmo-msc.cfg 2>/dev/null | awk '/network country code/{c=$4} /mobile network code/{n=$4} END{if(c) print c"-"n}')"
    a5="$(in_op cat /etc/osmocom/osmo-msc.cfg 2>/dev/null | awk '/encryption a5/{$1="";$2="";print; exit}' | sed 's/^ *//')"
    echo "PLMN ${C1}${plmn:--}${C}  ARFCN ${C1}${arfcn:--}${C}  A5 ${C1}${a5:--}${C}" ;;
subs)
    banc_debout || exit 0
    db=/var/lib/osmocom/hlr.db
    # Le conteneur n a pas forcement sqlite3 : on lit sa base par une copie.
    if [ "$OP_MODE" = docker ]; then
        dbl="/tmp/.conky-hlr-${OP_NAME}.db"
        docker cp "$OP_NAME:$db" "$dbl" >/dev/null 2>&1 && db="$dbl"
    fi
    # ── L ETAT DU HLR NE SE LIT PAS DANS SA BASE ─────────────────────────
    # [2026-09-04] Ce bloc ouvrait hlr.db et affichait « N abonnes · M
    # rattaches » sans jamais regarder si osmo-hlr tournait. La base survit au
    # demon : le tableau de bord montrait donc un HLR allume, et des abonnes
    # « rattaches » a un VLR disparu, des heures apres l arret du banc. On
    # regarde le demon d abord ; la base ne dit que ce qui est PROVISIONNE.
    if ! alive_x osmo-hlr; then
        _n=""
        have sqlite3 && [ -r "$db" ] && \
            _n="$(sqlite3 "$db" 'select count(*) from subscriber;' 2>/dev/null)"
        echo "HLR ${KO} arrete${_n:+ ${AR}${_n} abonnes en base}"
    elif have sqlite3 && [ -r "$db" ]; then
        tot="$(sqlite3 "$db" 'select count(*) from subscriber;' 2>/dev/null)"
        att="$(sqlite3 "$db" "select count(*) from subscriber where vlr_number is not null and vlr_number != '';" 2>/dev/null)"
        last="$(sqlite3 "$db" 'select max(last_lu_seen) from subscriber;' 2>/dev/null)"
        echo "HLR ${C1}${tot:-0}${C} abonnes · ${C2}${att:-0}${C} rattaches ${AR}LU ${last:--}"
        sqlite3 "$db" "select imsi, coalesce(msisdn,'-'), case when vlr_number is not null and vlr_number != '' then 1 else 0 end from subscriber order by imsi limit 6;" 2>/dev/null \
        | awk -F'|' -v ok="$OK" -v ko="$KO" '{printf "%s %s ${alignr}%s\n", ($3==1?ok:ko), $1, $2}'
    else
        echo "HLR ${KO} base introuvable (${db})"
    fi ;;
ops)
    # ── LES OPERATEURS DU BANC, ET CELUI QUE L ECRAN REGARDE ────────────────
    # [2026-09-04] Le Conky ne parlait que de l operateur SELECTIONNE : sur un
    # banc multi, les deux autres et le hub inter-STP n existaient nulle part a
    # l ecran - il fallait taper `docker ps` pour savoir s ils tournaient.
    #
    # Les fleches ◀ ▶ marquent l operateur courant. Conky ne recoit PAS les
    # clics (c est toute la raison d etre de tools/osmo-panel.py, une fenetre
    # GTK posee sur l encart) : elles se poussent avec les fleches de l encart,
    # avec Ctrl+Alt+Gauche/Droite (raccourci pose par l ISO), ou en ligne de
    # commande - `osmo-op --next` / `--prev`. Cette ligne dit ou on en est.
    #
    # Rien de tout ca sur un banc a un seul operateur : sans
    # /etc/osmocom/osmo-multi.conf, osmo-op ne rend que le natif et on n affiche
    # que le hub s il tourne.
    _op="${DIR:-/opt/GSM/osmo-operator}/tools/osmo-op.sh"
    [ -x "$_op" ] || _op="/opt/GSM/osmo-operator/tools/osmo-op.sh"
    if [ -x "$_op" ]; then
        n=0; line=""
        while read -r idx mode ip etat _; do
            n=$((n+1))
            if [ "$etat" = actif ]; then p="$OK"; else p="$KO"; fi
            if [ "$idx" = "$OP_ID" ]; then line="$line \${color4}◀\${color}$p${C2}op$idx${C}\${color4}▶\${color}"
            else line="$line $p op$idx"; fi
        done < <("$_op" --list 2>/dev/null | awk '{print $2, $3, $4, $5}')
        [ "$n" -gt 1 ] && echo "${line# }"
    fi
    # Le hub inter-STP : present seulement s il tourne (banc multi uniquement).
    if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx osmo-inter-stp; then
        _pc="$(awk -F= '/^MULTI_HUB_PC=/{print $2}' /etc/osmocom/osmo-multi.conf 2>/dev/null)"
        _hi="$(awk -F= '/^MULTI_HUB_IP=/{print $2}' /etc/osmocom/osmo-multi.conf 2>/dev/null)"
        echo "$OK inter-STP ${C1}${_hi:-172.20.0.10}${C} PC ${C1}${_pc:-0.0.0}${C}"
        # ── LA MATRICE DE CONNECTIVITE, EN CACHE ────────────────────────────
        # Elle vient de checks/ss7_check.sh - LA source, celle qui interroge
        # vraiment les VTY et compte les routes. On ne la recalcule pas ici :
        # deux implementations de la meme question finissent toujours par ne
        # plus dire la meme chose, et c est la copie que l on croit.
        #
        # MAIS ss7_check.sh met une bonne minute (31 tests, plusieurs telnet
        # VTY par operateur, chacun avec ses temporisations). Un `execpi` qui
        # l appellerait FIGERAIT LE CONKY entier a chaque rafraichissement -
        # l horloge, le CPU, le reseau, tout s arreterait pendant la mesure.
        # D ou le cache : on AFFICHE le dernier resultat, et on declenche la
        # mesure suivante EN TACHE DE FOND quand il a vieilli. Le conky ne
        # bloque jamais ; au pire la matrice a une minute de retard, ce qui est
        # sans importance pour une topologie qui ne bouge pas.
        matrice
    fi ;;
services)
    # Banc a terre : une seule ligne, celle qui sert - les unites en echec.
    # Le reste (web, pulse, tmux, docker) ne dit rien d autre que « rien ne
    # tourne », ce que l absence des sections ci-dessus a deja dit.
    if ! banc_debout; then
        f="$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
        [ "$f" -gt 0 ] && echo "${WARN} ${f} service(s) systemd en echec" \
                       || echo "${C1}banc a l arret${C} - ${C2}./start-direct.sh${C}"
        exit 0
    fi
    s=""
    port_open 8080 || port_open 8443 && s="$s$OK web " || s="$s$KO web "
    pgrep -x pulseaudio >/dev/null 2>&1 && s="$s$OK pulse " || s="$s$KO pulse "
    # ── PLUS DE PASTILLES tmux NI docker ────────────────────────────────────
    # [2026-09-04] Elles etaient rouges sur un banc en parfait etat, et pour la
    # meme raison toutes les deux : le Conky tourne sous le compte de la
    # SESSION, et ces deux sondes repondaient a la question « qu est-ce que MOI
    # je vois », pas « qu est-ce qui tourne sur cette machine ».
    #   tmux   : le banc ouvre ses sessions sous ROOT, sur /tmp/tmux-0/default.
    #            `tmux list-sessions` sous l utilisateur regarde
    #            /tmp/tmux-1001/default, qui n existe pas :
    #              error connecting to /tmp/tmux-1001/default
    #            Zero session, pastille rouge - avec `calypso` et `gapk`
    #            bien ouvertes a cote.
    #   docker : « permission denied ... /var/run/docker.sock » tant que le
    #            compte n est pas dans le groupe docker, donc zero conteneur -
    #            avec trois qui tournent.
    # On pourrait corriger chaque sonde ; on les RETIRE. Ni l une ni l autre ne
    # dit quoi que ce soit d utile sur l etat du banc : les sections Coeur GSM
    # et Radio disent deja si la pile est debout, et la ligne des operateurs
    # (sous-commande `ops`) dit quels conteneurs tournent - celle-la sait
    # distinguer « arrete » de « invisible ». Deux voyants de moins qui
    # clignotent pour rien.
    have nvidia-smi && s="$s$OK nvidia "
    echo "$s"
    # ── ET ON NOMME CE QUI ECHOUE ───────────────────────────────────────────
    # « 1 service(s) systemd en echec » envoyait chercher lequel a la main.
    # C etait systemd-networkd-wait-online.service : masque par l image (il
    # coutait deux minutes de boot) mais reste `failed` de son echec d avant le
    # masquage - masquer n efface pas l etat, il faut `systemctl reset-failed`.
    # Un nom, et le diagnostic prend trois secondes au lieu de dix minutes.
    # `systemctl --failed --no-legend` commence par une PUCE (●), pas par le nom :
    # un `awk '{print $1}'` rendait « ● ». On prend le champ qui ressemble a une
    # unite, quelle que soit sa position.
    f="$(systemctl --failed --no-legend 2>/dev/null \
         | awk '{for(i=1;i<=NF;i++) if($i ~ /\.(service|socket|target|timer|mount|path)$/) {print $i; break}}' \
         | sed 's/\.service$//' | paste -sd' ' -)"
    [ -n "$f" ] && echo "${WARN} en echec : ${C1}${f}${C}" || echo "${OK} systemd sans echec"
    ;;
*) echo "usage: $0 role|ops|net|core|radio|subs|services" >&2; exit 2 ;;
esac
