# osmo-disclaimer.sh — rappel affiche a l'ouverture d'un shell dans le conteneur.
#
# SOURCE, pas execute : /root/.bashrc fait `. /etc/osmo-disclaimer.sh` (symlink
# pose par Dockerfile.run vers ce fichier). Le pendant ISO est
# /etc/profile.d/01-osmo-disclaimer.sh, ecrit par build-iso.sh.
#
# Ce texte vivait dans un heredoc de Dockerfile.run. Le builder docker classique
# (Step N/M, sans BuildKit) ne connait pas les heredocs : il joignait les lignes
# de continuation et lancait le RUN sans le corps, d'ou
#   « here-document at line 1 delimited by end-of-file (wanted `DISC') »
# et un /etc/osmo-disclaimer.sh vide. Un fichier du depot copie par
# `COPY scripts/* /etc/osmocom/` marche avec les deux builders.
export OSMO_DISCLAIMER_SHOWN=1
printf "\n  \033[1;33mDisclaimer\033[0m - banc d'essai GSM/SS7 Osmocom (conteneur %s).\n" "$(hostname)"
printf "  A n'utiliser que sur un reseau radio \033[1mISOLE\033[0m (cage/attenuateur) ou\n"
printf "  sur une bande sous licence : emettre sur le spectre public est illegal.\n"
printf "  \033[1;33mDemarrer la pile radio :\033[0m cd /opt/GSM/osmo_egprs && ./start-direct.sh --force\n"
printf "  \033[0;36mSuivre :\033[0m tmux attach -t calypso   \033[0;36m(Ctrl-b puis d pour se detacher)\033[0m\n\n"
