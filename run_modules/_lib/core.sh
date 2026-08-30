# =============================================================================
#  run_modules/_lib/core.sh - sondes et lancement communs au bloc "coeur"
# =============================================================================
#
#  Ce fichier n'enregistre AUCUN module : il ne contient que des fonctions,
#  sourcees par les modules 10..22 (STP, HLR, MGW, MSC, BSC, GGSN, SGSN, PCU,
#  Asterisk, SIP-connector, abonnes, SMSC).
#
#  POURQUOI. Le coeur Osmocom est un ensemble de services systemd qui se
#  cherchent les uns les autres (SS7, GSUP, MGCP, MNCC). L'ancien demarrage se
#  contentait de `systemctl start` : une unite en boucle de redemarrage
#  (Restart=always sur TOUTES les unites osmo-*) restait invisible, et un
#  service "actif" sans lien M3UA etabli passait pour pret. Les sondes
#  ci-dessous rendent ces etats OBSERVABLES, passivement (ss, systemctl show,
#  sqlite en lecture seule) - donc sans perturber ce qui tourne.
#
#  Toutes les sondes rendent 0 = vrai, non-0 = faux ; aucune n'ecrit sur la
#  console (le protocole de message est celui de mod.sh).
# -----------------------------------------------------------------------------

[ -n "${CORE_LIB_LOADED:-}" ] && return 0
CORE_LIB_LOADED=1

: "${OSMOCOM_CFG:=/etc/osmocom}"
: "${RUN_DIR:=/tmp/calypso}"
: "${LOG_DIR:=$RUN_DIR/logs}"
: "${CORE_VTY_HOST:=127.0.0.1}"

# --- resolution des binaires et des configurations ---------------------------
# On cherche d'abord dans /usr/bin : c'est ce que lancent les unites systemd
# (ExecStart=/usr/bin/osmo-*). Une copie plus recente dans /usr/local/bin ne
# doit pas donner l'illusion que le service demarrera avec celle-la.
core_bin() {
    local n="$1" p
    for p in "/usr/bin/$n" "/usr/local/bin/$n"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    p="$(command -v "$n" 2>/dev/null)" || return 1
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

core_cfg() { printf '%s/%s.cfg\n' "$OSMOCOM_CFG" "$1"; }

# core_cfg_field <fichier> <regexp etendue> <n° de champ> [valeur par defaut]
# Lit une valeur DANS la configuration reelle plutot que de la coder en dur :
# si l'operateur change un port dans le .cfg, la barriere suit.
core_cfg_field() {
    local f="$1" re="$2" n="$3" def="${4:-}" v=""
    if [ -r "$f" ]; then
        v="$(grep -aE "$re" "$f" 2>/dev/null | head -n1 | awk -v k="$n" '{print $k}')"
    fi
    printf '%s\n' "${v:-$def}"
}

# --- cycle de vie des services ------------------------------------------------
core_has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
core_unit_exists() { core_has_systemd && systemctl cat "$1" >/dev/null 2>&1; }
core_unit_active() { core_has_systemd && systemctl is-active --quiet "$1"; }
core_nrestarts()   { core_has_systemd && systemctl show -p NRestarts --value "$1" 2>/dev/null || echo 0; }
core_pidfile()     { printf '%s/%s.pid\n' "$RUN_DIR" "$1"; }

# core_svc_start <unite> <binaire> [args...]
# Passe par systemd quand l'unite existe (c'est le chemin qui tourne
# aujourd'hui) ; sinon lance le binaire detache et note son PID, pour que la
# pile reste demarrable dans un conteneur sans systemd.
# Memorise le compteur NRestarts AVANT le lancement : c'est la reference qui
# permettra a la barriere de detecter une boucle de redemarrage.
core_svc_start() {
    local unit="$1" bin="$2"; shift 2
    mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
    core_nrestarts "$unit" > "$RUN_DIR/$unit.nrestarts" 2>/dev/null || true
    if core_unit_exists "$unit"; then
        mod_say "systemctl start $unit"
        systemctl start "$unit" || return 1
        return 0
    fi
    mod_say "systemd indisponible - lancement direct : $bin $*"
    setsid "$bin" "$@" >>"$LOG_DIR/$unit.log" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$(core_pidfile "$unit")"
    return 0
}

# core_svc_stop <unite> [motif pgrep cible]
# Idempotent, et cible : on ne tue que ce service (pas de pkill generique).
core_svc_stop() {
    local unit="$1" pat="${2:-}" pf
    core_unit_exists "$unit" && systemctl stop "$unit" 2>/dev/null
    pf="$(core_pidfile "$unit")"
    if [ -f "$pf" ]; then
        kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
        rm -f "$pf"
    fi
    [ -n "$pat" ] && pkill -f "$pat" 2>/dev/null
    rm -f "$RUN_DIR/$unit.nrestarts" 2>/dev/null
    return 0
}

# Le service est-il encore la ? (unite active, ou PID vivant hors systemd)
core_alive() {
    local unit="$1" pf
    if core_unit_exists "$unit"; then core_unit_active "$unit"; return $?; fi
    pf="$(core_pidfile "$unit")"
    [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null
}

# 0 = le service a redemarre depuis notre `start`.
# Toutes les unites osmo-* portent Restart=always : sans cette sonde, un
# service qui meurt et renait toutes les 2 s se presente comme "actif".
core_restarted_since() {
    # NB : declarations separees - sous `set -u`, bash rend indisponible une
    # variable referencee dans le MEME `local` que sa propre declaration.
    local unit="$1"
    local f="$RUN_DIR/$unit.nrestarts"
    local before now
    [ -f "$f" ] || return 1
    before="$(cat "$f" 2>/dev/null || echo 0)"
    now="$(core_nrestarts "$unit")"
    [ "${now:-0}" -gt "${before:-0}" ] 2>/dev/null
}

# core_healthy <unite> : vivant ET pas en boucle de redemarrage.
core_healthy() { core_alive "$1" && ! core_restarted_since "$1"; }

# --- sondes d'ecoute (passives : elles n'ouvrent aucune connexion) ------------
# ss -H : pas d'en-tete. Le 4e champ est "adresse:port" local pour tcp, udp
# et sctp (verifie sur la pile en marche).
_core_listen() {
    local opts="$1" port="$2" ip="${3:-}"
    # shellcheck disable=SC2086
    ss -H $opts 2>/dev/null | awk -v want="$port" -v wip="$ip" '
        { a = $4
          if (a == "") next
          if (match(a, /:[0-9]+$/) == 0) next
          p = substr(a, RSTART + 1); h = substr(a, 1, RSTART - 1)
          if (p != want) next
          if (wip == "" || h == wip || h == "0.0.0.0" || h == "*" || h == "[::]" || h == "::") { f = 1; exit }
        }
        END { exit !f }'
}
core_tcp_listen()  { _core_listen "-ltn"      "$@"; }
core_udp_listen()  { _core_listen "-lun"      "$@"; }
core_sctp_listen() { _core_listen "-ln --sctp" "$@"; }
core_vty_listen()  { core_tcp_listen "$1" "$CORE_VTY_HOST"; }

# Association SCTP ETABLIE depuis un port local donne : c'est la preuve que le
# lien M3UA d'un ASP (MSC, BSC) vers le STP est monte, sans interroger de VTY.
core_sctp_estab() {
    ss -nH --sctp 2>/dev/null | awk -v want="$1" '
        $1 == "ESTAB" { a = $4
            if (match(a, /:[0-9]+$/)) { p = substr(a, RSTART + 1); if (p == want) { f = 1; exit } } }
        END { exit !f }'
}

# Socket UNIX en ecoute. On interroge ss AVANT le test de fichier : certains
# services tournent avec un /tmp prive (PrivateTmp), leur socket est alors
# invisible dans notre /tmp alors qu'elle existe bel et bien (cas de
# /tmp/msc_mncc, constate).
core_unix_listen() {
    local p="$1"
    ss -xlH 2>/dev/null | awk -v w="$p" '{ for (i = 1; i <= NF; i++) if ($i == w) { f = 1; exit } } END { exit !f }' \
        || [ -S "$p" ]
}

# L'adresse est-elle utilisable en bind local ? (127.0.0.0/8 est couvert en
# entier par le 127.0.0.1/8 de lo - c'est ainsi que le HLR ecoute en 127.0.0.2.)
core_ip_local() {
    local w="$1"
    case "$w" in ""|0.0.0.0|127.*) return 0 ;; esac
    ip -o -4 addr show 2>/dev/null | awk -v w="$w" '{ split($4, a, "/"); if (a[1] == w) { f = 1; exit } } END { exit !f }'
}

# --- dialogue VTY -------------------------------------------------------------
# core_vty_ask <port> <commande>... → sortie du VTY sur stdout.
#
# ATTENTION : le VTY Osmocom ignore ce qui arrive avant la fin de sa
# negociation telnet, et exige des fins de ligne CRLF. Les deux `sleep` ci-
# dessous cadencent ce DIALOGUE ; ce ne sont pas des barrieres d'attente - la
# disponibilite, elle, se sonde avec core_vty_listen + wait_until.
core_vty_ask() {
    local port="$1"; shift
    local body="" c t="${CORE_VTY_TIMEOUT:-10}"
    for c in "$@"; do body+="$c"$'\n'; done
    if command -v socat >/dev/null 2>&1; then
        { sleep "${CORE_VTY_OPEN:-1}"; printf '%s' "$body"; sleep "${CORE_VTY_READ:-2}"; } \
            | timeout "$t" socat -T"$t" STDIO "TCP:${CORE_VTY_HOST}:${port},crlf" 2>/dev/null
    elif command -v telnet >/dev/null 2>&1; then
        { sleep "${CORE_VTY_OPEN:-1}"; printf '%s' "$body"; sleep "${CORE_VTY_READ:-2}"; } \
            | timeout "$t" telnet "$CORE_VTY_HOST" "$port" 2>/dev/null
    else
        return 1
    fi
}
