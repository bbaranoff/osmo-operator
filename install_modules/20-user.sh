# 20-user - the bench account.
#   native install, Docker, live key : the service account osmocom, as the
#                                      Dockerfile creates it;
#   system INSTALLED from the ISO    : Calamares removes the live key's osmocom
#                                      account and group - the bench belongs to
#                                      the account chosen at installation
#                                      (written to /etc/osmo-operator/compte by
#                                      shellprocess-osmo.conf, and to
#                                      CRYPTHOME_OWNER). osmocom is then neither
#                                      expected nor recreated.
INST_REGISTER user "Compte du banc"
INST_DEPS[user]="prereqs"

# the account the bench belongs to on this machine
inst_user_compte() {
    local c=""
    [ -r /etc/osmo-operator/compte ] && c="$(head -n1 /etc/osmo-operator/compte 2>/dev/null | tr -d '[:space:]')"
    [ -z "$c" ] && [ -r /etc/default/crypthome ] \
        && c="$(. /etc/default/crypthome 2>/dev/null; printf '%s' "${CRYPTHOME_OWNER:-}")"
    if [ -n "$c" ] && [ "$c" != osmocom ] && getent passwd "$c" >/dev/null; then printf '%s' "$c"
    else printf 'osmocom'; fi
}
inst_user_done() {
    local c; c="$(inst_user_compte)"
    getent passwd "$c" >/dev/null || return 1
    [ "$c" != osmocom ] || getent group osmocom >/dev/null
}
inst_user_run() {
    local c; c="$(inst_user_compte)"
    if [ "$c" != osmocom ]; then
        inst_say "compte du banc : $c (celui de l installation ; pas de compte osmocom)"
        inst_ok; return
    fi
    getent group  osmocom >/dev/null || groupadd osmocom || return $INST_RC_FAIL
    getent passwd osmocom >/dev/null || useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom || return $INST_RC_FAIL
    inst_ok
}
inst_user_verify() { inst_user_done && inst_ok || { inst_fail "le compte du banc ($(inst_user_compte)) n'existe pas"; return $INST_RC_FAIL; }; }
