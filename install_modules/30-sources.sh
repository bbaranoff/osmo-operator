# 30-sources - recuperation des depots. Idempotent : un depot deja clone est laisse tel quel
# (on ne tire pas : ce serait modifier le travail en cours de l'utilisateur sans le lui demander).
INST_REGISTER sources "Recuperation des sources Osmocom"
INST_DEPS[sources]="prereqs"

_SRC_REPOS="osmocom-bb|https://gitea.osmocom.org/phone-side/osmocom-bb|
osmo-gapk|https://gitea.osmocom.org/osmocom/gapk|
gsup-smsc-proto|https://gitea.osmocom.org/themwi/gsup-smsc-proto|
libosmo-dsp|https://gitea.osmocom.org/sdr/libosmo-dsp.git|"

inst_sources_done() {
    local l; while IFS='|' read -r dir url br; do
        [ -z "$dir" ] && continue
        have_repo "$GSM_ROOT/$dir" || return 1
    done <<< "$_SRC_REPOS"
    return 0
}
inst_sources_run() {
    mkdir -p "$GSM_ROOT" || { inst_fail "impossible de creer $GSM_ROOT"; return $INST_RC_FAIL; }
    local dir url br n=0
    while IFS='|' read -r dir url br; do
        [ -z "$dir" ] && continue
        have_repo "$GSM_ROOT/$dir" && { inst_say "$dir : deja present, laisse tel quel"; continue; }
        inst_say "clonage $dir"
        git clone ${br:+--branch "$br"} "$url" "$GSM_ROOT/$dir" || { inst_fail "echec du clonage de $dir ($url)"; return $INST_RC_FAIL; }
        n=$((n+1))
    done <<< "$_SRC_REPOS"
    [ $n -eq 0 ] && return $INST_RC_DONE
    inst_ok
}
inst_sources_verify() {
    local missing="" dir url br
    while IFS='|' read -r dir url br; do
        [ -z "$dir" ] && continue
        have_repo "$GSM_ROOT/$dir" || missing="$missing $dir"
    done <<< "$_SRC_REPOS"
    [ -n "$missing" ] && { inst_fail "depots absents :$missing"; return $INST_RC_FAIL; }
    inst_ok
}
