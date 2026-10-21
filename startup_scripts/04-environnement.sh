# 04-environnement.sh - partie de start.sh (lignes 684-763 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
say_begin "Chargement de l'environnement"
if [ -f "$HERE/environment/load.env" ]; then
    set -a; . "$HERE/environment/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "environment/load.env"
elif [ -f "$HERE/env/load.env" ]; then
    set -a; . "$HERE/env/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "env/load.env"
else
    # Fallback minimal (chemins typiques du depot)
    : "${GSM_ROOT:=/opt/GSM}"
    : "${NITB_TREE:=$HERE}"
    # Meme selection d'arbre qu'environment/paths.env, repliquee pour le cas ou
    # load.env est absent (ISO, conteneur nu). Un seul arbre QEMU : qosmo ; --dsp
    # ne change pas d'arbre, il passe la couche 1 a c54x_exe.
    : "${CALYPSO_FORK:=qosmo}"
    if [ -x "$HERE/../$CALYPSO_FORK/run.sh" ]; then
        : "${OQC_ROOT:=$(cd "$HERE/../$CALYPSO_FORK" && pwd)}"
    else
        : "${OQC_ROOT:=$GSM_ROOT/$CALYPSO_FORK}"
    fi
    say_end " OK " "$C_OK" "Chargement de l'environnement" "fallback minimal"
fi
: "${RUN_DIR:=/run/osmo-direct}"
# Repli si load.env est absent. Les journaux restent sous RUN_DIR (tmpfs) :
# le defilement tmux en depend - cf. environment/paths.env.
: "${LOG_DIR:=$RUN_DIR/logs}"
# A5/1 par defaut : c'est le chiffrement que la maquette valide de bout en bout
# (Calypso ↔ BTS), et ce que start-docker.sh impose deja dans son hand-off vers ce
# script. Un defaut a "a5 0" faisait diverger le lancement direct du lancement
# par start-docker.sh - meme stack, deux chiffrements, selon la porte d'entree.
#
# ATTENTION : globals.conf est lu AVANT et fait autorite sur cette variable (son
# en-tete le dit). Ce ":=" n'est donc qu'un repli quand globals.conf est absent
# - l'ISO, un conteneur nu. La valeur qui s'applique en pratique vient de la-bas,
# et c'est pourquoi elle y a ete changee aussi.
: "${ENCRYPTION:=a5 1}"
# Le pont TRX par defaut : un transceiver unique (pont/pont.py) qui se presente
# a osmo-bts-trx en TRX-UDP, decode le DL vers GSMTAP 4730/4731 et encode l'UL.
# CALYPSO_BRIDGE n'est pas declare dans globals.conf (les CALYPSO_* "passent au
# travers, intact" d'apres son en-tete) : l'environnement gagne donc vraiment.
#   CALYPSO_BRIDGE=none ./start-native.sh   -> pas de pont (QEMU + BTS seuls)
#
# [2026-09-22] DEUX CHAINES, SELECTIONNEES PAR --dsp / --grgsm. [2026-10-01]
# LE DEFAUT EST LE DSP (DSP_MODE=1 en tete de fichier). gr-gsm (qosmo +
# grgsm_exe) reste a un --grgsm : la couche 1 est alors un decodeur gr-gsm
# dans QEMU, et c'est la pile qui va de bout en bout jusqu'a l'appel voix.
#
# `--dsp` ne designe PLUS un fork de QEMU. Le C54x tourne maintenant HORS de
# QEMU, dans /opt/GSM/c54x_exe (mask-ROM TI, coeur emule par l1-dsp), et QEMU
# n'est plus que l'ARM, lance avec CALYPSO_DSP_EXTERN=1 depuis l'arbre
# /opt/GSM/qosmo. Les cinq etapes sont dans c54x_exe/run.sh :
#   1. c54x_exe --arm        le DSP, socket /tmp/calypso_dsp.sock + API RAM
#                            partagee, bursts DL en UDP 6702
#   2. qemu-system-arm       l'ARM + layer1 osmocom-bb, couche 1 gr-gsm coupee
#   3. osmocon               romload sur le pty serie, relais L1CTL
#   4. mobile                couches 2/3 osmocom-bb
#   5. pont.py               TRXD 5700-5702 face a osmo-bts-trx, bursts vers
#                            le DSP, montant par les side-bands /dev/shm
# Ce qu'il fait : le mobile acquiert FB et SB, decode SI1-4 (lai=001-01-1),
# campe, et mene sa mise a jour de localisation. L'ancienne note « le decodage
# SCH ne passe pas, le mobile ne campe pas » datait de l'ancien fork qosmo-dsp
# et n'est plus vraie de cette chaine-la.
#
# [2026-09-25] Les anciens forks qosmo-dsp et qosmo-grgsm ne sont plus
# references : run.sh, run_modules, cfgs et environnement ont ete repris dans
# /opt/GSM/qosmo, la ROM DSP est dans /opt/GSM/c54x_exe/rom (et en
# /opt/GSM/calypso_dsp.*.bin, ou c54x_exe la lit par defaut).
#
# --dsp : PAS DE PONT LANCE PAR CE SCRIPT. c54x_exe/run.sh lance le sien
# (etape 5) sur 5700-5702 ; un second pont sur les memes ports mourrait sur
# « Address already in use » et laisserait un cadavre a chaque demarrage.
# `none` = rien a lancer ici. Ne PAS mettre `ipc` : dans l'ancien qosmo-dsp
# cette valeur voulait dire « MS#1 via osmo-trx-ms-ipc, firmware QEMU non lance ».
# Une valeur posee par l'operateur reste respectee.
#
# [2026-10-01] Le DSP etant le defaut, `none` ne vaut que si le banc DSP est
# VRAIMENT lance (DSP_BANC=1, decide juste en dessous) : un c54x_exe absent
# fait retomber sur gr-gsm, qui a besoin de son pont. Sinon la chaine gr-gsm
# montait sans pont, et personne ne campait.

