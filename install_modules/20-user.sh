# 20-user - compte de service, tel que le Dockerfile le cree.
INST_REGISTER user "Utilisateur et groupe osmocom"
INST_DEPS[user]="prereqs"

inst_user_done() { getent passwd osmocom >/dev/null && getent group osmocom >/dev/null; }
inst_user_run() {
    getent group  osmocom >/dev/null || groupadd osmocom || return $INST_RC_FAIL
    getent passwd osmocom >/dev/null || useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom || return $INST_RC_FAIL
    inst_ok
}
inst_user_verify() { inst_user_done && inst_ok || { inst_fail "le compte osmocom n'existe pas"; return $INST_RC_FAIL; }; }
