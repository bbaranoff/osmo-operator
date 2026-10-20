# osmo-banc-aliases.sh - les alias du banc Calypso (a sourcer : /etc/profile.d/98-osmo-banc-aliases.sh)
# [2026-10-19] Deux chaines, quatre processus chacune, par c54x_exe/run.sh (MODE=dsp) :
#   banc-trx     c54x_exe + qosmo (trx.highram.elf) + osmocon + transceiver  : le Calypso est le
#                TRX de la BTS#0 (TRXD 5700-5702) ; pas de pont, il tiendrait les memes ports
#   banc-mobile  INSTANCE 2 : c54x_exe + qosmo (layer1) + osmocon + mobile, et l'AIR vers l'instance 1
#                (banc-mobile-stop/-status/-logs pour cette instance ; c123-2 pour son ecran)
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
alias banc-rssi='MODE=dsp FIRMWARE_APP=rssi bash /opt/GSM/c54x_exe/run.sh'
alias banc-stop='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --stop'
alias banc-status='MODE=dsp OSMO_TRX=1 bash /opt/GSM/c54x_exe/run.sh --status'
alias banc-logs='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --logs'
alias c123='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py'
alias c123-2='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --lcd /dev/shm/calypso2/calypso_lcd --keys /tmp/calypso_keys2.sock'
