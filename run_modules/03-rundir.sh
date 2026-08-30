# =============================================================================
#  03-rundir - repertoire d'execution (PID, sockets, verrous)
# =============================================================================
#
#  ROLE
#      Garantir l'existence et l'utilisabilite de RUN_DIR, le seul endroit ou la
#      pile ecrit son ETAT VOLATIL : fichiers PID, sockets de rendez-vous
#      (qemu-monitor.sock), verrous. C'est le point d'appui de tout le reste -
#      40-qemu y ecrit qemu.pid et y ouvre le socket de son moniteur, et sa
#      barriere relit ce PID pour distinguer "QEMU s'est arrete" de "QEMU
#      tourne mais le DSP est fige". Un RUN_DIR absent ou non inscriptible fait
#      donc echouer les modules suivants sur un symptome sans rapport avec la
#      cause.
#
#      PERIMETRE. Ce module ne s'occupe PAS des journaux ni des captures :
#      09-logs en est proprietaire (arborescence, archivage, horodatage, liens).
#      Ici, et uniquement ici, l'etat volatil.
#
#      paths.env place RUN_DIR sous ${XDG_RUNTIME_DIR:-/tmp}/calypso. L'ancien
#      lancement ecrivait en dur dans /root : un tiers n'a aucune raison d'y
#      ecrire, et deux piles ne pouvaient pas cohabiter.
#
#  PREREQUIS
#      profil (RUN_DIR est resolu par environment/paths.env).
#
#  CRITERE DE SUCCES
#      BARRIERE - une ecriture REELLE aboutit dans RUN_DIR (creation puis
#      suppression d'un temoin). Tester les droits ne suffit pas : un montage
#      passe en lecture seule, ou un volume plein, satisfait `-w` et echoue a
#      l'ecriture.
#
#  JOURNAL
#      $LOG_DIR/mod/rundir.log : chemin retenu et restes constates.
# -----------------------------------------------------------------------------
MOD_REGISTER rundir "Repertoire d'execution"
MOD_REQUIRED[rundir]=1
MOD_DEPS[rundir]="profil"
MOD_PROFILES[rundir]="calypso faketrx hybrid core"
MOD_TIMEOUT[rundir]=15

mod_rundir_check() {
    local d="${RUN_DIR:-}" parent
    [ -n "$d" ] || { mod_hint "RUN_DIR est pose par environment/paths.env"
                     mod_fail "RUN_DIR non defini"
                     return $MOD_RC_FAIL; }
    if [ -e "$d" ] && [ ! -d "$d" ]; then
        mod_hint "rm -f $d   (ou choisissez un autre RUN_DIR)"
        mod_fail "$d existe et n'est pas un repertoire"
        return $MOD_RC_FAIL
    fi
    if [ ! -d "$d" ]; then
        parent="$(dirname "$d")"
        while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do parent="$(dirname "$parent")"; done
        if [ ! -w "$parent" ]; then
            mod_hint "choisissez un emplacement inscriptible :  RUN_DIR=\$HOME/calypso ./launch/start-oqc.sh"
            mod_fail "impossible de creer $d : $parent n'est pas inscriptible"
            return $MOD_RC_FAIL
        fi
    fi
    mod_ok
}

# "Deja fait" = le repertoire est la et utilisable. Ce module ne laisse
# derriere lui aucun processus, seulement un etat constate.
mod_rundir_status() { [ -d "${RUN_DIR:-}" ] && [ -w "${RUN_DIR:-}" ]; }

mod_rundir_start() {
    mkdir -p "${RUN_DIR}" 2>/dev/null || { mod_fail "creation impossible : ${RUN_DIR}"; return $MOD_RC_FAIL; }
    chmod 0755 "${RUN_DIR}" 2>/dev/null
    mod_say "repertoire d'execution : ${RUN_DIR}"
    local f n=0
    for f in "${RUN_DIR}"/*.pid "${RUN_DIR}"/*.sock; do
        [ -e "$f" ] && { mod_say "reste du run precedent : $f"; n=$((n+1)); }
    done
    [ "$n" -gt 0 ] && mod_say "$n reste(s) - 04-restes puis 10-teardown s'en chargent"
    mod_ok
}

_rundir_ecriture_ok() {
    local t="${RUN_DIR}/.temoin.$$"
    : > "$t" 2>/dev/null || return 1
    rm -f "$t" 2>/dev/null
    return 0
}

mod_rundir_wait() {
    if ! wait_until "${MOD_TIMEOUT[rundir]}" "ecriture dans ${RUN_DIR}" _rundir_ecriture_ok; then
        mod_hint "montage en lecture seule ou volume plein :  df -h ${RUN_DIR}"
        mod_fail "${RUN_DIR} existe mais l'ecriture y echoue"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

# On ne supprime pas le repertoire : il peut porter des traces utiles au
# diagnostic. Seuls partent les fichiers PID dont le processus est mort.
mod_rundir_stop() {
    local f pid
    for f in "${RUN_DIR:-/nonexistent}"/*.pid; do
        [ -f "$f" ] || continue
        pid="$(cat "$f" 2>/dev/null || echo 0)"
        kill -0 "$pid" 2>/dev/null || rm -f "$f"
    done
    return 0
}
