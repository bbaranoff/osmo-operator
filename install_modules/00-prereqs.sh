# 00-prereqs - la machine peut-elle accueillir cette installation ?
INST_REGISTER prereqs "Prerequis du systeme"
INST_ROOT[prereqs]=0

inst_prereqs_run() {
    have_cmd apt-get || { inst_hint "cette installation vise Debian/Ubuntu ; sur une autre distribution, utilisez Docker : ./tools/make-docker-image.sh"
                          inst_fail "apt-get introuvable"; return $INST_RC_FAIL; }
    have_cmd git || { inst_fail "git absent"; return $INST_RC_FAIL; }
    local free; free=$(df -Pm "${GSM_ROOT%/*}" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$free" ] && [ "$free" -lt 4096 ]; then
        inst_hint "les sources et les objets de compilation occupent ~4 Go"
        inst_fail "espace disque insuffisant : ${free} Mo libres sur $(dirname "$GSM_ROOT")"
        return $INST_RC_FAIL
    fi
    inst_ok
}
inst_prereqs_verify() { inst_ok; }
