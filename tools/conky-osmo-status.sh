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
# Motif sur la ligne de commande complete (scripts python, chemins).
alive_f() { in_op pgrep -f "$1" >/dev/null 2>&1; }

case "${1:-}" in
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
    [ -n "$(ip -o -4 addr show up 2>/dev/null | awk '$2!="lo"')" ] || echo "${WARN} aucune interface avec adresse" ;;
core)
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
services)
    s=""
    port_open 8080 || port_open 8443 && s="$s$OK web " || s="$s$KO web "
    pgrep -x pulseaudio >/dev/null 2>&1 && s="$s$OK pulse " || s="$s$KO pulse "
    # run.sh (qosmo-grgsm) ouvre ses sessions sur le socket PAR DEFAUT de root ;
    # /tmp/osmocom_tmux est celui de l'ancien start.sh. On compte les deux.
    n=$(( $(tmux list-sessions 2>/dev/null | wc -l) + $(tmux -S /tmp/osmocom_tmux list-sessions 2>/dev/null | wc -l) ))
    [ "$n" -gt 0 ] && s="$s$OK tmux($n) " || s="$s$KO tmux "
    if have docker; then c="$(docker ps -q 2>/dev/null | wc -l)"; [ "$c" -gt 0 ] && s="$s$OK docker($c) " || s="$s$KO docker "; fi
    have nvidia-smi && s="$s$OK nvidia "
    echo "$s"
    f="$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    [ "$f" -gt 0 ] && echo "${WARN} ${f} service(s) systemd en echec" || echo "${OK} systemd sans echec"
    ;;
*) echo "usage: $0 role|net|core|radio|subs|services" >&2; exit 2 ;;
esac
