# osmo-banc-aliases.sh - the Calypso bench aliases (sourced: /etc/profile.d/98-osmo-banc-aliases.sh)
# Two chains, four processes each, through c54x_exe/run.sh (MODE=dsp):
#   banc-trx     c54x_exe + qosmo (trx.highram.elf) + osmocon + transceiver: the Calypso is the
#                TRX of BTS#0 (TRXD 5700-5702); no bridge, it would hold the same ports
#   banc-mobile  INSTANCE 2: c54x_exe + qosmo (layer1) + osmocon + mobile, and the AIR towards
#                instance 1 (banc-mobile-stop/-status/-logs for this instance; c123-1 for its
#                screen)
#   banc-mobile-seul  single-Calypso setup: mobile + bridge towards osmo-bts-trx, instance 1
#   banc-rssi    c54x_exe + qosmo (rssi.highram.elf) + osmocon: the RSSI application alone,
#                emulated screen and keypad; the window: c123
#   banc-stop / banc-status / banc-logs   the same run.sh, --stop / --status / --logs
# The network (core, BSC, BTS, side-car) stays with ./start-native.sh; these aliases only bring
# up the Calypso chain, the network being already up.
# Everything at once, network included: ./start-native.sh --bts (the radio alone, = --osmo-trx)
#   or ./start-native.sh --bts --ms (the radio then the mobile over the air, = banc-trx then
#   banc-mobile).
alias banc-trx='MODE=dsp OSMO_TRX=1 bash /opt/GSM/c54x_exe/run.sh'
# banc-mobile = INSTANCE 2 (run.sh INSTANCE=2): second c54x_exe, QEMU, osmocon, mobile, and the
# air (pont/air.py) linking its bursts to those of instance 1 (banc-trx). Logs: /tmp/c54x-pont2.
alias banc-mobile='INSTANCE=2 MODE=dsp AIR=1 bash /opt/GSM/c54x_exe/run.sh'
alias banc-mobile-stop='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --stop'
alias banc-mobile-status='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --status'
alias banc-mobile-logs='INSTANCE=2 MODE=dsp bash /opt/GSM/c54x_exe/run.sh --logs'
# single-Calypso setup (mobile + bridge towards osmo-bts-trx), instance 1
alias banc-mobile-seul='MODE=dsp PONT=1 bash /opt/GSM/c54x_exe/run.sh'
# rssi on INSTANCE 4, separate from the rest of the bench: no environment copied from instance 1
# (the TRX), and not stopped by banc-stop / start-native --stop (banc_dsp_arreter_instances
# spares it). banc-rssi-stop stops it alone; c123-3 for its screen.
unalias banc-rssi 2>/dev/null   # an alias of the same name would expand in the function definition
# With a classic BTS (--bts-classic: pont_dsp.py alive), no air: it would relay the TX ring of
# instance 1, which is then the MOBILE (nothing idle, hence « Sync error ») and send the rssi
# bursts back to its BSP. The downlink comes through the bridge copy (PONT_DSP_COPIES, udp 6762).
# Otherwise (--bts), the air.
# Realistic air (calypso_bsp.c, CALYPSO_AIR_NIVEAUX): the cell is only heard on its ARFCN (radio
# plan), the downlink at CALYPSO_AIR_DL_DBM, the mobile uplink at CALYPSO_AIR_UL_DBM, noise
# elsewhere. CALYPSO_AIR_NIVEAUX=0 banc-rssi: everything at maximum, on every frequency.
function banc-rssi {
    local air=1 arfcn
    pgrep -f 'pont/pont_dsp\.py' >/dev/null && air=0
    arfcn="$( . /etc/osmocom/radio-plan.env 2>/dev/null; echo "${PLAN_ARFCN:-}")"
    INSTANCE=4 MODE=dsp FIRMWARE_APP=rssi AIR="${AIR:-$air}" \
        CALYPSO_AIR_NIVEAUX="${CALYPSO_AIR_NIVEAUX:-1}" CALYPSO_FAUX_AIR="${CALYPSO_FAUX_AIR:-$arfcn}" \
        bash /opt/GSM/c54x_exe/run.sh "$@"
}
# banc-rssi --stop (or banc-rssi-stop) stops the whole instance 4, leftovers included (run.sh
# arreter). A function, not an alias: an alias does not exist in a non-interactive shell
# (bash -lc).
unalias banc-rssi-stop 2>/dev/null
function banc-rssi-stop { banc-rssi --stop; }
alias banc-stop='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --stop'
alias banc-status='MODE=dsp OSMO_TRX=1 bash /opt/GSM/c54x_exe/run.sh --status'
alias banc-logs='MODE=dsp bash /opt/GSM/c54x_exe/run.sh --logs'
# Bench numbering: c123 = TRX (instance 1, TS0), c123-1 = layer1 (the mobile, instance 2),
# c123-2 = trx2 (phone 2 of the TRX, TS1, instance 3), c123-3 = rssi (instance 4, banc-rssi).
alias c123='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 1'
alias c123-1='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 2'
alias c123-2='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 3'
alias c123-3='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --instance 4'
alias c123-mobile='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py'   # the first live instance that is not a TRX
alias c123-tous='/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py --toutes 1,2,3,4'   # + those appearing later
