# =============================================================================
#  40-qemu - l'emulateur Calypso (ARM7TDMI + DSP TMS320C54x)
# =============================================================================
# [2026-08-31] Ce module ne sourcait PAS _lib/radio.sh, contrairement a tous les
# autres modules radio (60-fake-trx, 64-trxcon, 66-mobile...). Il n'en avait pas
# besoin tant qu'il ne lisait que QEMU_BIN et FIRMWARE_ELF ; il en a besoin
# maintenant qu'il lit QEMU_DUMMY_SOCK et QEMU_GDB_PORT - et sous le `set -u` de
# run.sh, une variable non posee ne donne pas un defaut vide mais un module qui
# avorte. radio.sh n'utilise que des `: "${X:=...}"` : le sourcer est idempotent
# et n'ecrase rien de ce que paths.env a deja resolu.
. "$(dirname "${BASH_SOURCE[0]}")/_lib/radio.sh"

MOD_REGISTER qemu "Emulateur Calypso (QEMU)"
MOD_REQUIRED[qemu]=1
MOD_DEPS[qemu]="prereqs"
MOD_PROFILES[qemu]="calypso hybrid"
MOD_TIMEOUT[qemu]=30

# Plafond du journal, en octets. Le modele emet des sondes tres bavardes : quand
# rien ne repond en face (pas de TRX, pas de BTS), le DSP boucle a vide et
# `POST-BOOTSTUB-RET` seul produit ~2,8 Mo/s - 337 Mo en deux minutes, mesure.
# Un garde-fou tronque le fichier au-dela de cette taille, plutot que de remplir
# le disque de lignes sans valeur de diagnostic.
: "${QEMU_LOG_MAX:=$((64 * 1024 * 1024))}"

mod_qemu_check() {
    [ -x "${QEMU_BIN:-}" ] || { mod_fail "binaire QEMU absent : ${QEMU_BIN:-<non defini>}"
                                mod_hint "compilez-le : ./configure --target-list=arm-softmmu && ninja -C build qemu-system-arm"
                                return $MOD_RC_FAIL; }
    [ -r "${FIRMWARE_ELF:-}" ] || { mod_fail "firmware ARM introuvable : ${FIRMWARE_ELF:-<non defini>}"; return $MOD_RC_FAIL; }
    # [2026-08-30] Les ROM du DSP ne sont plus un PREREQUIS DUR. Le merge
    # `sans-dsp` de qosmo-grgsm a supprime tools/dsp_txt2bin.py, seul generateur
    # des calypso_dsp.*.bin : les exiger revenait a interdire tout demarrage de
    # QEMU. La machine `calypso` sait tourner sans (dsp-blob/shunt), et le mode
    # par defaut ici est le shunt (le pont fait le canal). On previent, on ne
    # bloque plus. [2026-08-31] Ne plus citer CALYPSO_SKIP_DSP : cette variable
    # etait un drapeau FANTOME, lue par personne, retiree de start-direct.sh.
    local r missing=0
    # `:-` obligatoire : sans l'arbre voisin qosmo-grgsm, son environnement/paths.env
    # n'est pas source (environment/paths.env l.103) et ces variables n'existent
    # pas — un `$DSP_PROM0` nu tuait le module sous le `set -u` de run.sh.
    for r in "${DSP_PROM0:-}" "${DSP_PROM1:-}" "${DSP_PROM2:-}" "${DSP_PROM3:-}" \
             "${DSP_DROM:-}" "${DSP_PDROM:-}"; do
        [ -n "$r" ] && [ -r "$r" ] || missing=$((missing + 1))
    done
    if [ "$missing" -gt 0 ]; then
        mod_hint "$missing ROM DSP absente(s) sous ${DSP_ROM_DIR:-\$GSM_ROOT} : QEMU demarre sans (machine calypso nue, shunt)"
    fi
    mod_ok
}

# [2026-08-31] Le motif "qemu-system-arm.*calypso" designe TOUS les QEMU Calypso
# de la machine, pas le notre : en multi-operateur, chaque module voyait le QEMU
# du voisin et se croyait deja demarre. Le discriminant sur la ligne de commande
# est le socket du moniteur, qui vit sous RUN_DIR - un RUN_DIR par instance.
_qemu_pattern() { printf 'qemu-system-arm.*%s/qemu-monitor.sock' "$RUN_DIR"; }

mod_qemu_status() { have_proc "$(_qemu_pattern)"; }

# Garde-fou de journal : tronque le fichier des qu'il depasse le plafond.
# Tourne en arriere-plan et meurt avec QEMU.
_qemu_log_guard() {
    local f="$1" max="$2" qpid="$3"
    while kill -0 "$qpid" 2>/dev/null; do
        if [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt "$max" ]; then
            printf '\n--- journal tronque : plafond de %s octets atteint (QEMU_LOG_MAX) ---\n' "$max" > "$f"
        fi
        sleep 5
    done
}

mod_qemu_start() {
    local mach="calypso"
    # Une propriete `dsp-*=` pointant sur un fichier absent fait avorter QEMU au
    # demarrage : on ne passe que les sections REELLEMENT presentes. Aucune ->
    # machine `calypso` nue, ce que le shunt attend.
    local _p _v
    for _p in prom0:DSP_PROM0 prom1:DSP_PROM1 prom2:DSP_PROM2 prom3:DSP_PROM3 \
              drom:DSP_DROM pdrom:DSP_PDROM registers:DSP_REGISTERS; do
        _v="${_p#*:}"; _v="${!_v:-}"
        [ -n "$_v" ] && [ -r "$_v" ] && mach="$mach,dsp-${_p%%:*}=$_v"
    done
    local qlog="${LOG_DIR}/qemu.log"
    mod_say "machine  : $mach"
    mod_say "journal  : $qlog (plafond ${QEMU_LOG_MAX} o)"
    mod_say "L1CTL    : $QEMU_DUMMY_SOCK (poubelle - le vrai socket est celui d'osmocon)"
    mod_say "gdb      : tcp::${QEMU_GDB_PORT}"

    # L1CTL_SOCK EN PREFIXE, PAS EN EXPORT. La variable ne doit atteindre QUE ce
    # child : exportee, elle repointerait aussi les sondes et les modules qui
    # cherchent le vrai socket. Sans elle, le serveur L1CTL interne de QEMU
    # (l1ctl_sock.c) se rabat sur son defaut /tmp/osmocom_l2, unlink() le socket
    # d'osmocon et ejecte le mobile en place - voir le bloc QEMU_DUMMY_SOCK de
    # _lib/radio.sh pour la chaine complete jusqu'a "Layer2 socket failed".
    L1CTL_SOCK="$QEMU_DUMMY_SOCK" \
    "$QEMU_BIN" -M "$mach" -cpu arm946 \
        -gdb "tcp::${QEMU_GDB_PORT}" -serial pty -serial pty \
        -monitor "unix:${RUN_DIR}/qemu-monitor.sock,server,nowait" \
        -kernel "$FIRMWARE_ELF" >>"$qlog" 2>&1 &
    local qpid=$!
    printf '%s\n' "$qpid" > "${RUN_DIR}/qemu.pid"
    _qemu_log_guard "$qlog" "$QEMU_LOG_MAX" "$qpid" &
    mod_ok
}

# BARRIERE - demarre n'est pas pret.
# Le socket du moniteur seul est un critere trop faible : il existe des que QEMU
# a ouvert son ecoute, meme si le DSP boucle a vide. On exige donc deux choses :
#   1. le moniteur REPOND (QEMU est vivant et sert son protocole) ;
#   2. le DSP a reellement PROGRESSE (le compteur d'instructions avance entre
#      deux releves) - sinon le modele est plante et rien ne le signalerait.
mod_qemu_wait() {
    local sock="${RUN_DIR}/qemu-monitor.sock" qlog="${LOG_DIR}/qemu.log"

    wait_until "${MOD_TIMEOUT[qemu]}" "socket du moniteur QEMU" have_unix "$sock" || return $MOD_RC_FAIL

    # Le processus est-il toujours la ? Un QEMU qui meurt a l'init laisse sa socket.
    local qpid; qpid="$(cat "${RUN_DIR}/qemu.pid" 2>/dev/null || echo 0)"
    if ! kill -0 "$qpid" 2>/dev/null; then
        mod_hint "regardez la fin de $qlog : QEMU s'est arrete pendant l'initialisation"
        mod_fail "QEMU a demarre puis s'est arrete"
        return $MOD_RC_FAIL
    fi

    # Le DSP progresse-t-il ? On compare la taille du journal a 1,5 s d'intervalle.
    # C'est grossier mais suffisant pour distinguer "vivant" de "fige", et ca
    # ne depend d'aucune sonde particuliere.
    local a b
    a="$(stat -c %s "$qlog" 2>/dev/null || echo 0)"
    sleep 1.5
    b="$(stat -c %s "$qlog" 2>/dev/null || echo 0)"
    if [ "$a" = "$b" ]; then
        mod_hint "le modele ne produit aucune trace : verifiez les ROM du DSP et le firmware"
        mod_fail "QEMU tourne mais le DSP semble fige"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_qemu_stop() {
    local qpid; qpid="$(cat "${RUN_DIR}/qemu.pid" 2>/dev/null || echo 0)"
    [ "$qpid" != 0 ] && kill "$qpid" 2>/dev/null
    # Rattrapage CIBLE. Le motif large "qemu-system-arm.*calypso" tuait le QEMU
    # de TOUS les operateurs - un arret d'operateur 2 emportait le 1 et le 3,
    # dont les mobiles sortaient aussitot en "Layer2 socket failed".
    pkill -f "$(_qemu_pattern)" 2>/dev/null
    rm -f "${RUN_DIR}/qemu.pid" "${RUN_DIR}/qemu-monitor.sock" "$QEMU_DUMMY_SOCK"
    return 0
}
