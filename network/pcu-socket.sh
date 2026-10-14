#!/bin/bash
# =============================================================================
# network/pcu-socket.sh - harnais du socket PCU (BTS <-> osmo-pcu)
#
# Le PCU (GPRS/EGPRS) se branche sur UN socket unix par BTS :
#   - le BTS principal (osmo-bts-trx.cfg) : socket par defaut /tmp/pcu_bts,
#     c'est celui que run.sh donne au PCU (PCU_SOCKET) ;
#   - le BTS side-car (osmo-bts-trx-bts1.cfg) : pcu-socket /tmp/pcu_bts2, qu'aucun
#     PCU ne sert. Un socket sans processus derriere reste sur le disque et
#     fait croire a une liaison qui n'existe pas.
#
# Ce script ne change AUCUNE config. Il dit qui ecoute quoi, et supprime les
# sockets orphelins (fichier present, aucun processus en ecoute) pour que le
# lancement suivant parte d'une ardoise propre.
#
#   network/pcu-socket.sh          etat (defaut)
#   network/pcu-socket.sh --fix    supprime les sockets orphelins /tmp/pcu_bts*
#
# Appele par start-direct.sh juste avant le lancement de run.sh (--fix).
# =============================================================================
set -u

PCU_SOCKET="${PCU_SOCKET:-/tmp/pcu_bts}"
PCU_LOG="${PCU_LOG:-/var/log/osmocom/osmo-pcu.log}"
MODE=check
[ "${1:-}" = "--fix" ] && MODE=fix

# Un socket est "en service" si un processus l'ecoute (ss -xlp le montre).
listener_of() {
    ss -xlp 2>/dev/null | grep -F " $1 " | sed -n 's/.*users:((\"\([^\"]*\)\",pid=\([0-9]*\).*/\1 pid \2/p' | head -1
}

rc=0
echo "pcu-socket : socket attendu par le PCU = $PCU_SOCKET"

for s in /tmp/pcu_bts /tmp/pcu_bts2; do
    if [ ! -e "$s" ]; then
        printf '  %-16s absent\n' "$s"
        continue
    fi
    who="$(listener_of "$s")"
    if [ -n "$who" ]; then
        printf '  %-16s en service (%s)\n' "$s" "$who"
    elif [ "$MODE" = fix ]; then
        if rm -f "$s"; then
            printf '  %-16s orphelin supprime\n' "$s"
        else
            printf '  %-16s orphelin, suppression impossible\n' "$s"; rc=1
        fi
    else
        printf '  %-16s orphelin (aucun processus) - lancer avec --fix\n' "$s"
    fi
done

# Qui sert le PCU : la derniere connexion journalisee vers le socket attendu.
if [ -r "$PCU_LOG" ]; then
    last="$(sed 's/\x1b\[[0-9;]*m//g' "$PCU_LOG" | grep -a "PCU socket $PCU_SOCKET has been connected" | tail -1)"
    if [ -n "$last" ]; then
        echo "  PCU          connecte a $PCU_SOCKET  ($(echo "$last" | awk '{print $4, $5, $6}'))"
    else
        echo "  PCU          pas de connexion journalisee a $PCU_SOCKET"
    fi
fi

# Config : quels BTS declarent un socket PCU, et lequel.
for c in /etc/osmocom/osmo-bts*.cfg; do
    [ -r "$c" ] || continue
    line="$(grep -E '^[[:space:]]*pcu-socket[[:space:]]' "$c" | head -1 | sed 's/^[[:space:]]*//')"
    printf '  %-28s %s\n' "$(basename "$c")" "${line:-(defaut : /tmp/pcu_bts)}"
done

exit $rc
