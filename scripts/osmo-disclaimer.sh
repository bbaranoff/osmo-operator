# osmo-disclaimer.sh — reminder shown when a shell opens in the container.
#
# Sourced, not executed: /root/.bashrc does `. /etc/osmo-disclaimer.sh` (symlink
# installed by Dockerfile.run to this file). The ISO counterpart is
# /etc/profile.d/01-osmo-disclaimer.sh, written by build-iso.sh.
#
# A repository file copied by `COPY scripts/* /etc/osmocom/` rather than a
# heredoc in Dockerfile.run: the classic docker builder (Step N/M, without
# BuildKit) does not support heredocs in RUN.
export OSMO_DISCLAIMER_SHOWN=1
printf "\n  \033[1;33mDisclaimer\033[0m - banc d'essai GSM/SS7 Osmocom (conteneur %s).\n" "$(hostname)"
printf "  A n'utiliser que sur un reseau radio \033[1mISOLE\033[0m (cage/attenuateur) ou\n"
printf "  sur une bande sous licence : emettre sur le spectre public est illegal.\n"
printf "  \033[1;33mDemarrer la pile radio :\033[0m cd /opt/GSM/osmo-operator && ./start-native.sh --force\n"
printf "  \033[0;36mSuivre :\033[0m tmux attach -t calypso   \033[0;36m(Ctrl-b puis d pour se detacher)\033[0m\n\n"
