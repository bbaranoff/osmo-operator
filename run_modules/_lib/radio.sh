# =============================================================================
#  run_modules/_lib/radio.sh - fonds commun aux modules du bloc "radio"
# =============================================================================
#
#  POURQUOI CE FICHIER. Les sept modules radio (fake-trx, osmo-trx, osmo-bts-trx,
#  osmo-bts-virtual, trxcon, virtphy, mobile) partagent exactement trois choses :
#  un plan d'adressage (ports TRXD, sockets L1CTL), une facon de retenir un PID,
#  et trois sondes observables (port UDP ouvert, processus vivant, fenetre de
#  stabilite sans motif fatal). Les dupliquer sept fois, c'est sept occasions de
#  diverger. Elles vivent donc ici, a cote du contrat (_lib/mod.sh) qu'elles
#  prolongent - sans jamais s'y substituer : un module reste un fichier
#  NN-<slug>.sh conforme, ce fichier n'est PAS un module et ne s'enregistre pas.
#
#  Chargement : chaque module fait, au source,
#      . "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"
#  L'inclusion est idempotente (garde ci-dessous), l'ordre des modules importe
#  donc pas.
#
#  RIEN ICI N'A D'EFFET DE BORD : que des definitions et des valeurs par defaut
#  posees avec l'idiome `:=`, donc la ligne de commande gagne toujours.
# -----------------------------------------------------------------------------
[ -n "${_RADIO_LIB_LOADED:-}" ] && return 0
_RADIO_LIB_LOADED=1

# --- PERIMETRE : a qui appartient quoi ---------------------------------------
# Deux chaines radio coexistent dans ce depot, et elles ne doivent JAMAIS etre
# jouees ensemble : elles se disputeraient la VTY 4241 (BTS), la VTY 4247
# (mobile) et la socket L1CTL.
#
#   profils calypso / hybrid  ->  la chaine de l'emulateur, deja couverte par
#       55-ipc-device, 56-trx-ipc, 60-bts, 70-l2. Le bloc radio N'Y ENTRE PAS.
#   profil  faketrx           ->  la chaine RAN sur hote, c'est CE bloc :
#       fake-trx | osmo-trx, osmo-bts-trx | osmo-bts-virtual, trxcon | virtphy,
#       mobile.
#
# Tous les modules du bloc declarent donc MOD_PROFILES=faketrx. On peut toujours
# en jouer un isolement avec --only <slug>.
# -----------------------------------------------------------------------------

# --- quelle chaine radio ? ----------------------------------------------------
# faketrx : osmo-bts-trx <-> fake_trx <-> trxcon <-> mobile      (defaut)
# virtphy : osmo-bts-virtual <-> (multicast) <-> virtphy <-> mobile
# Les deux sont EXCLUSIVES : meme port VTY de BTS (4241), meme socket L1CTL.
# C'est PHY_MODE qui tranche, via MOD_ENABLED_IF dans chaque module.
: "${PHY_MODE:=faketrx}"

# --- quel transceiver ? -------------------------------------------------------
# fake     : fake_trx.py, commutateur de bursts (defaut, aucune RF)
# osmo-trx : le vrai modem GMSK (variante IPC ou SDR)
# Exclusifs eux aussi : meme plage de ports TRXD. Un seul des deux modules est
# active, l'autre est affiche SKIP - jamais un echec.
: "${RADIO_TRANSCEIVER:=fake}"

# Nombre de mobiles simules (une instance trxcon ou virtphy par mobile).
: "${N_MS:=1}"

# --- plan d'adressage TRXD ----------------------------------------------------
# Convention osmocom : un "base port" par cote, +1 = CTRL, +2 = DATA.
#   cote BTS          $TRX_BASE_PORT   (osmo-bts-trx `osmotrx base-port remote`)
#   cote bande de base $BB_BASE_PORT   (trxcon -p), +3 par mobile supplementaire
# Le mode hybride (deuxieme BTS a cote de QEMU) decale tout : 5720 / 6720.
: "${TRX_BIND_IP:=127.0.0.1}"
: "${TRX_BTS_IP:=127.0.0.1}"
: "${TRX_BB_IP:=127.0.0.1}"
: "${TRX_BASE_PORT:=5700}"
: "${BB_BASE_PORT:=6700}"
: "${BB_PORT_STEP:=3}"

# --- sockets L1CTL ------------------------------------------------------------
# osmocon expose /tmp/osmocom_l2 (SANS suffixe) ; trxcon et virtphy exposent
# /tmp/osmocom_l2_<n>. Le mobile prend ce que dit SON fichier de conf : les
# modules lisent `layer2-socket` plutot que de le supposer.
: "${L2_SOCK_BASE:=/tmp/osmocom_l2}"
: "${SAP_SOCK_BASE:=/tmp/osmocom_sap}"

# --- ports VTY (criteres observables "pret") --------------------------------
: "${BTS_VTY_PORT:=4241}"        # osmo-bts-trx ET osmo-bts-virtual
: "${OSMO_TRX_VTY_PORT:=4237}"   # osmo-trx / osmo-trx-ipc
: "${MOBILE_VTY_PORT:=4247}"     # mobile (surcharge par la conf si elle le dit)

# --- repertoires --------------------------------------------------------------
: "${RUN_DIR:=/tmp/calypso}"
: "${LOG_DIR:=$RUN_DIR/logs}"

# =============================================================================
#  Helpers - aucun n'affiche quoi que ce soit sur la console.
# =============================================================================

# radio_dirs - cree RUN_DIR/LOG_DIR. Appele en tete de chaque mod_*_start.
radio_dirs() { mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true; }

# radio_log <slug> - journal du demon (le module y ecrit aussi via MOD_LOG).
radio_log() { printf '%s/%s.log\n' "$LOG_DIR" "$1"; }

# --- PID : un fichier par instance -------------------------------------------
radio_pidfile() { printf '%s/%s.pid\n' "$RUN_DIR" "$1"; }
radio_save_pid() { radio_dirs; printf '%s\n' "$2" > "$(radio_pidfile "$1")"; }
radio_pid()   { cat "$(radio_pidfile "$1")" 2>/dev/null || echo 0; }
radio_alive() { local p; p="$(radio_pid "$1")"; [ "$p" != 0 ] && kill -0 "$p" 2>/dev/null; }

# radio_kill <slug> [motif_pkill]
# Arret cible et idempotent : d'abord le PID retenu, ensuite le motif en
# rattrapage (les demons lances en arriere-plan essaiment parfois), puis on
# verifie la mort avant de rendre la main - un `kill` sans `wait` laisse
# croire que c'est arrete alors que le port est encore tenu.
radio_kill() {
    local slug="$1" pattern="${2:-}" p i
    p="$(radio_pid "$slug")"
    [ "$p" != 0 ] && kill "$p" 2>/dev/null
    [ -n "$pattern" ] && pkill -f "$pattern" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ "$p" = 0 ] || ! kill -0 "$p" 2>/dev/null; then break; fi
        sleep 0.2
    done
    if [ "$p" != 0 ] && kill -0 "$p" 2>/dev/null; then
        kill -9 "$p" 2>/dev/null
        [ -n "$pattern" ] && pkill -9 -f "$pattern" 2>/dev/null
    fi
    rm -f "$(radio_pidfile "$slug")"
    return 0
}

# --- sondes observables -------------------------------------------------------

# radio_udp_bound <port> - un socket UDP local est-il ouvert sur ce port ?
# C'est la seule preuve qu'un transceiver ecoute vraiment ; le PID ne dit rien
# d'un processus qui a demarre puis echoue a bind.
radio_udp_bound() {
    ss -uan 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
}

# radio_udp_range <base> - l'un des trois ports (base, +1 CTRL, +2 DATA) est-il
# ouvert ? On ne fige pas la repartition exacte, qui differe entre fake_trx et
# osmo-trx : ce qui compte est qu'un socket TRXD existe sur la plage.
radio_udp_range() {
    local b="$1"
    radio_udp_bound "$b" || radio_udp_bound "$((b+1))" || radio_udp_bound "$((b+2))"
}

# radio_bb_port <n> - port bande de base du mobile n (1-indexe).
radio_bb_port() { printf '%d\n' "$(( BB_BASE_PORT + ($1 - 1) * BB_PORT_STEP ))"; }

# radio_l2_sock <n> - socket L1CTL du mobile n.
radio_l2_sock() { printf '%s_%d\n' "$L2_SOCK_BASE" "$1"; }

# radio_cfg_val <fichier> <directive> - premiere valeur d'une directive de conf
# Osmocom : radio_cfg_val cfg "osmotrx base-port remote" -> "5700".
# Comparaison mot a mot (pas d'expression reguliere), donc insensible a
# l'indentation et au nombre d'espaces - ce que les fichiers Osmocom, ecrits
# tantot a la main tantot par "write file", ne garantissent pas.
radio_cfg_val() {
    local f="$1"; shift
    [ -r "$f" ] || return 1
    awk -v k="$*" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            n = split(k, kk, /[[:space:]]+/)
            split(line, ff, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (ff[i] != kk[i]) next
            if (ff[n+1] != "") { print ff[n+1]; exit }
        }' "$f"
}

# radio_stable <slug> <log> <secondes> <motif_fatal_ERE>
# BARRIERE NEGATIVE - c'est la lecon d'osmo-bts-trx : le processus demarre, le
# port VTY s'ouvre, et trente secondes plus tard il meurt sur "No clock since
# TRX". Un critere instantane le declarerait OK. On exige donc qu'il tienne une
# fenetre, sans jamais avoir imprime de motif fatal.
radio_stable() {
    local slug="$1" log="$2" secs="$3" fatal="$4" i hit
    for ((i=0; i<secs; i++)); do
        if ! radio_alive "$slug"; then
            mod_fail "$slug s'est arrete ${i}s apres le demarrage - voir $log"
            return 1
        fi
        if [ -f "$log" ] && hit="$(grep -aoEm1 "$fatal" "$log" 2>/dev/null)" && [ -n "$hit" ]; then
            mod_fail "$slug signale "$hit""
            return 1
        fi
        sleep 1
    done
    return 0
}

# radio_foreign_holder <port> <motif_process>
# Le port est tenu, mais par qui ? Distingue "notre demon tourne deja" (le
# moteur le verra via mod_*_status) de "un intrus squatte le port" - deux
# situations qui appellent des gestes opposes.
radio_foreign_holder() {
    radio_udp_bound "$1" && ! pgrep -f "$2" >/dev/null 2>&1
}
