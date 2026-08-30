# 70-configs - configuration Osmocom. `cp -n` : on n'ecrase JAMAIS une configuration
# existante, elle a pu etre adaptee a la machine.
INST_REGISTER configs "Configuration (/etc/osmocom)"
INST_DEPS[configs]="prereqs"

inst_configs_done() { have_file /etc/osmocom/osmo-bsc.cfg; }
inst_configs_run() {
    mkdir -p /etc/osmocom /var/log/osmocom /var/run/smsc "${OSMOCOM_HOME:-$HOME/.osmocom}/bb" \
        || { inst_fail "impossible de creer les repertoires de configuration"; return $INST_RC_FAIL; }
    cp -n "$INST_TREE"/configs/*.cfg /etc/osmocom/ 2>/dev/null
    [ -f "$INST_TREE/configs/mobile.cfg" ] && cp -n "$INST_TREE/configs/mobile.cfg" "${OSMOCOM_HOME:-$HOME/.osmocom}/bb/mobile.cfg"
    inst_say "configurations deposees (les fichiers existants ont ete conserves)"
    inst_ok
}
inst_configs_verify() {
    have_dir /etc/osmocom || { inst_fail "/etc/osmocom absent"; return $INST_RC_FAIL; }
    inst_ok
}
