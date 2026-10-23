# osmo-banc-aliases.sh - les alias du banc Calypso (a sourcer : /etc/profile.d/98-osmo-banc-aliases.sh)
# [2026-10-19] Deux chaines, quatre processus chacune, par c54x_exe/run.sh (MODE=dsp) :
#   banc-trx     c54x_exe + qosmo (trx.highram.elf) + osmocon + transceiver  : le Calypso est le
#                TRX de la BTS#0 (TRXD 5700-5702) ; pas de pont, il tiendrait les memes ports
#   banc-mobile  INSTANCE 2 : c54x_exe + qosmo (layer1) + osmocon + mobile, et l'AIR vers l'instance 1
#                (banc-mobile-stop/-status/-logs pour cette instance ; c123-1 pour son ecran)
#   banc-mobile-seul  l'ancien montage : mobile + pont vers osmo-bts-trx, instance 1
#   banc-rssi    c54x_exe + qosmo (rssi.highram.elf) + osmocon : l'appli RSSI seule, ecran et
#                clavier emules ; la fenetre : c123
#   banc-stop / banc-status / banc-logs   le meme run.sh, --stop / --status / --logs
# Le reseau (coeur, BSC, BTS, side-car) reste a ./start-native.sh ; ces alias ne montent que
# la chaine Calypso, le reseau etant deja debout.
# [2026-10-20] Tout d'un coup, reseau compris : ./start-native.sh --bts (la radio seule, = --osmo-trx)
#   ou ./start-native.sh --bts --ms (la radio puis le mobile par l'air, = banc-trx puis banc-mobile).
alias banc-trx='MODE=dsp OSMO_TRX=1 bash /opt/GSM/c54x_exe/run.sh'
# [2026-10-19] banc-mobile = INSTANCE 2 (run.sh INSTANCE=2) : deuxieme c54x_exe, QEMU, osmocon, mobile,
# et l'air (pont/air.py) qui relie ses bursts a ceux de l'instance 1 (banc-trx). Journaux : /tmp/c54x-pont2.
alias banc-mobile='INSTANCE=2 MODE=dsp AIR=1 bash /opt/GSM/c54x_exe/run.sh'
alias banc-mobile-stop='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --stop'
alias banc-mobile-status='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --status'
alias banc-mobile-logs='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --logs'
# l'ancien montage a un seul Calypso (mobile + pont vers osmo-bts-trx), instance 1
alias banc-mobile-seul='MODE=dsp PONT=1 bash /opt/GSM/c54x_exe/run.sh'
# [2026-10-21] rssi sur l'INSTANCE 4, SEPAREE du reste du banc : ni environnement copie de l'instance 1
# (le TRX), ni arret par banc-stop / start-native --stop (banc_dsp_arreter_instances l'epargne).
# banc-rssi-stop pour l'arreter seul ; c123-3 pour son ecran.
unalias banc-rssi 2>/dev/null   # l'ancien alias (meme nom) s'expanserait a la definition de la fonction
# [2026-10-23] En BTS CLASSIQUE (--bts-classic : pont_dsp.py vivant), pas d'air : il relaierait l'anneau TX de
# l'instance 1, qui est alors le MOBILE (rien en veille, d'ou « Sync error ») et renverrait les bursts de rssi
# vers son BSP. Le descendant arrive par la copie du pont (PONT_DSP_COPIES, udp 6762). Sinon (--bts), l'air.
# Air realiste (calypso_bsp.c, CALYPSO_AIR_NIVEAUX) : la cellule n'est entendue que sur son ARFCN (plan
# radio), le descendant a CALYPSO_AIR_DL_DBM, le montant du mobile a CALYPSO_AIR_UL_DBM, ailleurs du bruit.
# CALYPSO_AIR_NIVEAUX=0 banc-rssi : l'ancien comportement (tout au maximum, sur toutes les frequences).
function banc-rssi {
    local air=1 arfcn
    pgrep -f 'pont/pont_dsp\.py' >/dev/null && air=0
    arfcn="$( . /etc/osmocom/radio-plan.env 2>/dev/null; echo "${PLAN_ARFCN:-}")"
    INSTANCE=4 MODE=dsp FIRMWARE_APP=rssi AIR="${AIR:-$air}" \
        CALYPSO_AIR_NIVEAUX="${CALYPSO_AIR_NIVEAUX:-1}" CALYPSO_FAUX_AIR="${CALYPSO_FAUX_AIR:-$arfcn}" \
        bash /opt/GSM/c54x_exe/run.sh "$@"
}
# [2026-10-23] banc-rssi --stop (ou banc-rssi-stop) arrete TOUTE l'instance 4, restes compris (run.sh arreter). Une
# fonction et plus un alias : un alias n'existe pas dans un shell non interactif (bash -lc), l'arret n'y faisait rien.
unalias banc-rssi-stop 2>/dev/null
function banc-rssi-stop { banc-rssi --stop; }
alias banc-stop='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --stop'
alias banc-status='MODE=dsp OSMO_TRX=1 bash /opt/GSM/c54x_exe/run.sh --status'
alias banc-logs='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --logs'
# [2026-10-21] numerotation demandee par le banc : c123 = TRX (instance 1, TS0), c123-1 = layer1 (le mobile,
# instance 2), c123-2 = trx2 (telephone 2 du TRX, TS1, instance 3), c123-3 = rssi (instance 4, banc-rssi).
alias c123='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 1'
alias c123-1='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 2'
alias c123-2='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 3'
alias c123-3='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 4'
alias c123-mobile='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py'   # la premiere instance vivante qui n'est pas un TRX
alias c123-tous='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --toutes 1,2,3,4'   # + celles qui apparaissent ensuite
