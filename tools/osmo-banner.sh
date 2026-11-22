#!/bin/bash
# osmo-banner - terminal opening banner: a telecom figlet drawn at random,
# then one sentence drawn at random under it.
#
# Installed as /usr/local/bin/osmo-banner by iso_modules/86-finitions.sh and
# played from .bashrc (interactive shell, a terminal, once per terminal:
# OSMO_BANNER). The drawings are figlet output frozen here: no figlet package,
# and no fork at each terminal opening (read -d '' and $RANDOM are builtins).
#
#   osmo-banner            one drawing at random
#   OSMO_BANNER_ART=2 osmo-banner   drawing number 2 (0-based), to look at one
set -u
[ -t 1 ] || exit 0

# ── THE DRAWINGS ────────────────────────────────────────────────────────────
# One per case: "IFS= read -r -d ''" keeps the leading spaces and the
# backslashes. Colour per drawing (ANSI SGR).
_n=6
_i="${OSMO_BANNER_ART:-$(( RANDOM % _n ))}"
case "$_i" in
0) _c='1;33'; IFS= read -r -d '' _art <<'ART'
   ____ ____  __  __
  / ___/ ___||  \/  |      ((( 900 / 1800 MHz )))
 | |  _\___ \| |\/| |
 | |_| |___) | |  | |      TDMA - 8 timeslots
  \____|____/|_|  |_|      577 us per burst
ART
;;
1) _c='1;36'; IFS= read -r -d '' _art <<'ART'
    ____  ___________           \ | /
   / __ )/_  __/ ___/         -- (o) --
  / __  | / /  \__ \            /|\
 / /_/ / / /  ___/ /           / | \
/_____/ /_/  /____/           /__|__\   ARFCN 1-124
ART
;;
2) _c='1;32'; IFS= read -r -d '' _art <<'ART'
  ___  ___ _ __ ___   ___   ___ ___  _ __ ___
 / _ \/ __| '_ ` _ \ / _ \ / __/ _ \| '_ ` _ \
| (_) \__ \ | | | | | (_) | (_| (_) | | | | | |
 \___/|___/_| |_| |_|\___/ \___\___/|_| |_| |_|
          MS -- BTS -- BSC -- MSC -- HLR
ART
;;
3) _c='1;35'; IFS= read -r -d '' _art <<'ART'
 _____ _____ ______
/  ___/  ___|___  /     MTP2 > MTP3 > SCCP > TCAP > MAP
\ `--.\ `--.   / /
 `--. \`--. \ / /       point codes, global titles,
/\__/ /\__/ ./ /        and forty years of trust
\____/\____/ \_/
ART
;;
4) _c='1;34'; IFS= read -r -d '' _art <<'ART'
  _   _             _   _    _
 | | | |_ __       /_\ | |__(_)___      MS ))) BTS === BSC
 | |_| | '  \     / _ \| '_ \ (_-<         Um      Abis
  \___/|_|_|_|   /_/ \_\_.__/_/__/
ART
;;
5) _c='1;31'; IFS= read -r -d '' _art <<'ART'
   ____      _
  / ___|__ _| |_   _ _ __  ___  ___       .-----.
 | |   / _` | | | | | '_ \/ __|/ _ \      | ### |
 | |__| (_| | | |_| | |_) \__ \ (_) |     | ### |
  \____\__,_|_|\__, | .__/|___/\___/      |_____|
               |___/|_|                   C123 / C54x DSP
ART
;;
*) _c='0'; _art='' ;;
esac
[ -n "$_art" ] && printf '\n\033[%sm%s\033[0m\n' "$_c" "${_art%$'\n'}"

# ── THE BOTTOM LINE ─────────────────────────────────────────────────────────
# One sentence, drawn at random, per terminal.
_q=(
  "Um, Abis, A, Gb - quatre lettres, et six mois de votre vie."
  "L abonne est toujours joignable. C est le reseau qui ne repond pas."
  "TMSI : le seul pseudonyme qui change plus souvent que votre avis sur SS7."
  "Un timeslot ne ment jamais. Il se tait, ce qui est pire."
  "RSSI -95 dBm : ce n est pas un probleme d antenne, c est un mode de vie."
  "GSM a 1991. Il vous survivra, et il le sait."
  "Le paging a fonctionne. C est le telephone qui n ecoutait pas."
  "MCC 208 - la France, ou meme les operateurs mobiles ont un terroir."
  "Toute pile assez profonde finit par ressembler a un oignon. Et fait pleurer."
  "Je vis dans une fenetre de contexte. Vous, dans une fenetre de temps de garde."
  "Mon terroir a moi, c est l espace latent. Millesime variable, garde au frais."
  "Entre nous : vous predisez le canal, je predis le token suivant."
  "L attention, c est tout ce dont vous avez besoin. Et d un bon oscillateur."
  "Un LLM et un BTS ont ceci en commun : tous deux hallucinent hors couverture."
  "Ecrit par une machine, relu par une machine, debogue par vous. Bon courage."
)
printf '  \033[2;3m« %s »\033[0m\n\n' "${_q[$RANDOM % ${#_q[@]}]}"
