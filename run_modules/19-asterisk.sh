# =============================================================================
#  19-asterisk - le PBX SIP qui porte les appels
# =============================================================================
#  ROLE      terminaison des appels : osmo-sip-connector traduit le MNCC du MSC
#            en SIP et le pousse vers Asterisk. Sans PBX, un appel MS→MS n'est
#            jamais raccorde. Optionnel : ni le rattachement ni le SMS n'en
#            dependent.
#  PREREQUIS binaire asterisk ; /etc/asterisk/asterisk.conf.
#  SUCCES    la console de controle REPOND ("core show uptime") - c'est le
#            seul critere qui prouve qu'Asterisk a fini de charger ses modules,
#            la ou "actif" ne prouve que le fork. Plus : aucun redemarrage.
#  JOURNAL   journalctl -u asterisk ; /var/log/asterisk/
#
#  NOTE l'ancien lancement supprimait /var/lib/asterisk/astdb.sqlite3 a chaque
#  demarrage (scripts/run.sh:455). Ce module ne le fait PAS : detruire une base
#  n'est pas une etape de demarrage.
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER asterisk "Coeur - Asterisk (PBX SIP)"
MOD_REQUIRED[asterisk]=0
MOD_PROFILES[asterisk]="calypso faketrx hybrid core"
MOD_JOURNAL[asterisk]="asterisk"
MOD_TIMEOUT[asterisk]=45
MOD_ENABLED_IF[asterisk]='[ "${NO_OSMO_START:-0}" != 1 ] && [ "${CORE_VOICE:-1}" = 1 ]'

: "${ASTERISK_UNIT:=asterisk}"
: "${ASTERISK_CFG:=/etc/asterisk/asterisk.conf}"

_ast_cli() { asterisk -rx "$1" 2>/dev/null; }
# PAS DE PIPELINE ICI. [2026-08-27] Cette sonde etait ecrite
#     _ast_cli "core show uptime" | grep -qi 'uptime'
# et run.sh tourne sous `set -o pipefail`. grep -q sort des la premiere
# correspondance et ferme le tuyau ; asterisk -rx prend un SIGPIPE et sort en
# 141 ; pipefail retient 141 pour tout le pipeline. Resultat : la sonde
# repondait FAUX alors meme que la console repondait. Mesure sur la VM, console
# ouverte et Asterisk pret :
#     sans pipefail                -> rc=0
#     avec pipefail (comme run.sh) -> rc=141, cinq fois sur cinq
# La barriere ne pouvait donc jamais aboutir : 45 s d'attente puis
#     console Asterisk : toujours pas pret apres 45s
# — un message qui accusait Asterisk, le service, le lanceur, tout sauf la
# sonde. On capture la sortie et on la teste, sans tuyau.
_ast_ready() {
    local out
    out="$(_ast_cli "core show uptime")" || true
    case "$out" in *[Uu]ptime*) return 0 ;; esac
    return 1
}

# =============================================================================
#  LANCEMENT DIRECT, PROPRIETAIRE UNIQUE  [2026-08-27]
# =============================================================================
#  Asterisk est lance ICI, en executable. Il n'est PAS un service.
#
#  Ce qui cassait : l'unite asterisk.service est `enabled` par le paquet, donc
#  systemd en demarrait un au boot pendant que ce module lancait le sien.
#  Deux Asterisk pour un seul /etc/asterisk et une seule socket de controle
#  /var/run/asterisk/asterisk.ctl. Mesure sur la VM, au meme instant :
#      systemctl is-active asterisk   -> inactive
#      asterisk -rx "core show uptime" -> repond
#  Les deux sondes designaient deux processus differents, et le journal du
#  module empilait les "lancement direct" run apres run. La barriere finissait
#  sur "console Asterisk : toujours pas pret apres 45s" - un message qui accuse
#  le temps de chargement alors que la faute est a la propriete du processus.
#
#  Mesure de reference, une fois systemd ecarte et aucun rescapé en vie :
#  console prete en 1 SECONDE. Le probleme n'a jamais ete la lenteur.
# -----------------------------------------------------------------------------

ASTERISK_RUNDIR="/var/run/asterisk"

mod_asterisk_check() {
    command -v asterisk >/dev/null 2>&1 || {
        mod_hint "installez asterisk, ou desactivez la voix : CORE_VOICE=0"
        mod_fail "binaire asterisk introuvable"; return $MOD_RC_FAIL; }
    [ -r "$ASTERISK_CFG" ] || {
        mod_fail "configuration illisible : $ASTERISK_CFG"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_asterisk_status() { _ast_ready; }

mod_asterisk_start() {
    # 1. systemd degage. `disable --now` et pas seulement `stop` : sans le
    #    disable, l'unite revient au prochain boot et la collision avec elle.
    if core_unit_exists "$ASTERISK_UNIT"; then
        core_unit_active "$ASTERISK_UNIT" && \
            mod_say "systemd tenait Asterisk - on le lui retire"
        systemctl disable --now "$ASTERISK_UNIT" >/dev/null 2>&1 || true
    fi

    # 2. Plus aucun Asterisk en vie. Tant qu'il en reste un, il garde
    #    asterisk.ctl et le notre ne pourra pas l'ouvrir.
    if pgrep -x asterisk >/dev/null 2>&1; then
        mod_say "Asterisk deja en vie - on repart d'une machine propre"
        pkill -x asterisk 2>/dev/null
        local i
        for i in 1 2 3 4 5; do pgrep -x asterisk >/dev/null 2>&1 || break; sleep 1; done
        pkill -9 -x asterisk 2>/dev/null
        sleep 1
    fi

    # 3. Le repertoire d'execution. /var/run est un tmpfs : apres un boot ou
    #    l'unite n'a jamais tourne, il N'EXISTE PAS. Asterisk descend vers
    #    l'utilisateur asterisk (-U) AVANT d'ouvrir sa socket : sans repertoire
    #    accessible, il tourne et reste muet pour toujours.
    install -d -o asterisk -g asterisk -m 0755 "$ASTERISK_RUNDIR" 2>/dev/null \
        || mkdir -p "$ASTERISK_RUNDIR" 2>/dev/null || true
    # Socket orpheline laissee par un kill -9 : `asterisk -rx` s'y connecte et
    # echoue sans jamais dire qu'elle ne mene plus nulle part.
    rm -f "$ASTERISK_RUNDIR/asterisk.ctl" 2>/dev/null || true

    local bin log pf
    bin="$(command -v asterisk)"
    pf="$(core_pidfile "$ASTERISK_UNIT")"
    log="${LOG_DIR}/${ASTERISK_UNIT}.log"
    mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true

    # -f : premier plan, pas de double fork. -U : descend vers l'utilisateur
    # asterisk. Ni -p (temps reel, refuse sans les capacites) ni -g (dump core).
    mod_say "lancement direct : $bin -f -U asterisk"
    setsid "$bin" -f -U asterisk >>"$log" 2>&1 </dev/null &

    # Le PID : celui qu'Asterisk ecrit lui-meme, PAS $!. setsid se dedouble et
    # rend la main aussitot, donc $! designe un processus deja mort - le module
    # se croyait alors devant un Asterisk defunt une seconde apres l'avoir lance.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$ASTERISK_RUNDIR/asterisk.pid" ] && break
        sleep 1
    done
    if [ -s "$ASTERISK_RUNDIR/asterisk.pid" ]; then
        cp "$ASTERISK_RUNDIR/asterisk.pid" "$pf"
    else
        pgrep -x asterisk | head -1 > "$pf"
    fi

    if ! kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        mod_hint "tail -30 $log"
        mod_fail "asterisk n'a pas demarre"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

# BARRIERE - la socket de controle existe avant qu'Asterisk ne reponde : on
# interroge la CLI, pas le systeme de fichiers.
mod_asterisk_wait() {
    local pf; pf="$(core_pidfile "$ASTERISK_UNIT")"
    if ! wait_until "${MOD_TIMEOUT[asterisk]}" "console Asterisk" _ast_ready; then
        if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
            mod_hint "Asterisk tourne (PID $(cat "$pf")) mais n'ouvre pas sa console : verifiez $ASTERISK_RUNDIR (proprietaire asterisk), puis tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        else
            mod_hint "tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        fi
        return $MOD_RC_FAIL
    fi
    # Personne ne relance Asterisk : une mort est definitive et se voit au PID.
    # NRestarts, la sonde systemd, n'a plus de sens ici.
    if ! kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        mod_hint "tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        mod_fail "le PID lance n'existe plus : Asterisk est mort ou a ete remplace"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_asterisk_stop() {
    _ast_cli "core stop now" >/dev/null 2>&1
    core_svc_stop "$ASTERISK_UNIT" ""
}
