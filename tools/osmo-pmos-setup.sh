#!/bin/bash
# osmo-pmos-setup - prepare la VM postmarketOS pour le modem du banc.
#
# A lancer depuis l hote, la VM demarree (SSH sur 2222). Il applique, de facon
# PERSISTANTE :
#   - le DNS : postmarketOS passe par systemd-resolved, qui n a aucun serveur
#     en QEMU (d ou « pas de reseau » alors que l IP et la route sont bonnes) ;
#   - le pilote ftdi_sio : le modem du banc arrive en USB serie (QEMU emule un
#     FTDI 0403:6001) et sans ce module il n y a pas de /dev/ttyUSB0 ;
#   - la regle udev qui dit a ModemManager de sonder ce port, sinon il l ignore.
set -u
PORT="${OSMO_PMOS_SSH_PORT:-2222}"
PASS="${OSMO_PMOS_PASS:-147147}"
USER_VM="${OSMO_PMOS_USER:-user}"
ssh_vm() { sshpass -p "$PASS" ssh -p "$PORT" -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 -o PreferredAuthentications=password "$USER_VM@127.0.0.1" "$@"; }

ssh_vm "echo $PASS | sudo -S sh -c '
    mkdir -p /etc/systemd/resolved.conf.d
    # DNSSEC=no : le DNS interne de QEMU (10.0.2.3) ne signe pas ses reponses,
    # et resolved refusait tout - « DNSSEC validation failed: no-signature ».
    printf \"[Resolve]\nDNS=10.0.2.3 1.1.1.1\nFallbackDNS=8.8.8.8\nDNSSEC=no\nDNSOverTLS=no\n\" \
        > /etc/systemd/resolved.conf.d/osmo.conf
    systemctl restart systemd-resolved 2>/dev/null

    # Le modem arrive sur un port serie PCI : 8250_pci est integre a ce noyau,
    # il n y a donc aucun module a charger (ftdi_sio, lui, n existe pas ici).

    mkdir -p /etc/udev/rules.d
    printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"ttyS[1-9]\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_TTY_BAUDRATE}=\\\"115200\\\"\n\" \
        > /etc/udev/rules.d/99-osmo-modem.rules
    udevadm control --reload 2>/dev/null
    udevadm trigger --subsystem-match=tty 2>/dev/null

    # [2026-09-07] LA DATA : pppd et le greffon PPP de NetworkManager. Sans
    # eux, ATD*99 aboutit a CONNECT puis NO CARRIER une seconde plus tard
    # (« PPP failed to start: libnm-ppp-plugin.so is not installed »). Le
    # noyau doit avoir PPP (build-pm.sh) ; les modules se chargent au boot.
    apk info -e ppp networkmanager-ppp >/dev/null 2>&1 \
        || apk add ppp networkmanager-ppp 2>&1 | tail -n 1
    printf \"ppp_generic\nppp_async\n\" > /etc/modules-load.d/osmo-ppp.conf
    modprobe ppp_async 2>/dev/null

    systemctl restart ModemManager 2>/dev/null
    sleep 3
    mmcli --scan-modems 2>/dev/null | tail -n 1
'" 2>&1 | tail -n 4

# Le modem du banc vient maintenant se brancher sur le port que QEMU tient
# ouvert. On ne le fait qu ICI, systeme demarre : branche des le debut, le
# firmware UEFI prend ses reponses pour des touches et n amorce jamais (voir
# l entete de osmo-pmos-qemu).
PORT_AT="${OSMO_PMOS_AT_PORT:-12346}"
REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
if pgrep -f "[o]smo-phonesim-banc.py --connect" >/dev/null 2>&1; then
    echo "  modem deja branche sur la VM"
else
    setsid nohup "$REPO/tools/osmo-phonesim-banc.py" --connect "127.0.0.1:$PORT_AT" \
        >>"/tmp/osmo-phonesim-vm-$(id -un).log" 2>&1 </dev/null &
    sleep 3
    pgrep -f "[o]smo-phonesim-banc.py --connect" >/dev/null 2>&1 \
        && echo "  modem du banc branche sur la VM (port $PORT_AT)" \
        || echo "  ATTENTION : le modem ne s est pas branche (cf. /tmp/osmo-phonesim-vm-$(id -un).log)"
fi

# [2026-09-07] LA VOIX, ET POURQUOI IL FAUT DEUX CARTES SON. QEMU ne sait pas
# pousser du son dans le haut-parleur d un invite : d une carte emulee, la
# LECTURE part vers un sink de l hote et la CAPTURE vient d une source de
# l hote. Le descendant de l appel (gsm_audio) vit cote hote : il ne peut donc
# entrer dans la VM que par sa capture, jamais par son haut-parleur. Avec une
# seule carte la VM a le point de vue du RESEAU - elle entend le correspondant
# dans son micro - et Calls reste muet.
#
# La VM a donc deux cartes, posees par pmbootstrap (osmo_bench_args) :
#   0000:00:12.0  le PONT    : capture = gsm_audio.monitor (le descendant),
#                              lecture = gsm_mic (le montant) ;
#   0000:00:13.0  le COMBINE : les peripheriques par defaut de l hote, tes
#                              vrais haut-parleurs et ton vrai micro.
# On les croise DANS la VM : pont -> combine pour entendre, combine -> pont
# pour parler. La VM est alors reellement dans le trajet de la voix.
#
# Et on coupe les deux bouclages DIRECTS de l hote (gsm_audio.monitor vers les
# haut-parleurs, micro vers gsm_mic) : sans ca la voix arrive DEUX fois, une
# fois en direct et une fois par la VM avec sa latence en plus - un echo franc.
# OSMO_PMOS_RELAI=0 pour ne pas toucher a l audio.
if [ "${OSMO_PMOS_RELAI:-1}" = "1" ]; then
    echo "--- voix"
    for m in $(pactl list modules short 2>/dev/null \
               | grep -E 'source=gsm_audio\.monitor|sink=gsm_mic' | cut -f1); do
        pactl unload-module "$m" 2>/dev/null && echo "  bouclage direct $m retire"
    done

    # [2026-09-07] LES SOURDINES QUI REVIENNENT. Le descendant traverse quatre
    # potentiometres, et il suffit d UN sur muet pour que la voix disparaisse
    # sans qu aucun bouclage ne manque. Deux sont cote hote : le flux QEMU
    # « combine » (la sortie de la VM vers tes haut-parleurs) et le sink des
    # haut-parleurs. PulseAudio les MEMORISE par nom d application
    # (module-stream-restore) : une fois coupe, le flux revient coupe a chaque
    # lancement. On les rouvre donc a chaque mise en service.
    for i in $(pactl list sink-inputs short 2>/dev/null | cut -f1); do
        pactl set-sink-input-mute "$i" 0 2>/dev/null
        pactl set-sink-input-volume "$i" 100% 2>/dev/null
    done
    for o in $(pactl list source-outputs short 2>/dev/null | cut -f1); do
        pactl set-source-output-mute "$o" 0 2>/dev/null
    done
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null && echo "  sourdines de l hote levees"

    ssh_vm '
        pci() { pactl list "$1" short 2>/dev/null | grep "pci-0000_00_$2\.0" | grep -v monitor | head -n1 | cut -f2; }
        PONT_OUT=$(pci sinks 12);  PONT_IN=$(pci sources 12)
        COMB_OUT=$(pci sinks 13);  COMB_IN=$(pci sources 13)
        if [ -z "$PONT_IN" ] || [ -z "$COMB_OUT" ]; then
            echo "  ATTENTION : les deux cartes son ne sont pas la - VM lancee avant le patch ?"
            pactl list sinks short 2>/dev/null
            exit 0
        fi
        # Le combine devient le peripherique par defaut : sinon la sonnerie et
        # les notifications de Phosh partiraient dans le montant de l appel.
        pactl set-default-sink "$COMB_OUT"
        pactl set-default-source "$COMB_IN"
        # Les deux autres potentiometres du descendant sont ici : Phosh coupe
        # volontiers le combine (touche volume, mode silencieux) et la voix
        # meurt la, bouclages en place. On les rouvre.
        for c in "$PONT_OUT" "$COMB_OUT"; do
            pactl set-sink-mute "$c" 0 2>/dev/null
            pactl set-sink-volume "$c" 100% 2>/dev/null
        done
        for c in "$PONT_IN" "$COMB_IN"; do
            pactl set-source-mute "$c" 0 2>/dev/null
        done
        # Idempotent : on retire les bouclages precedents avant de reposer.
        for m in $(pactl list modules short 2>/dev/null | grep module-loopback | cut -f1); do
            pactl unload-module "$m" 2>/dev/null
        done
        pactl load-module module-loopback source="$PONT_IN" sink="$COMB_OUT" latency_msec=40 >/dev/null \
            && echo "  descendant : pont -> combine (on entend)"
        pactl load-module module-loopback source="$COMB_IN" sink="$PONT_OUT" latency_msec=40 >/dev/null \
            && echo "  montant    : combine -> pont (on parle)"
    ' 2>&1 | tail -n 6
fi

echo "--- etat"
ssh_vm 'ls /dev/ttyS[1-9] 2>/dev/null | head -n 3; getent hosts alpinelinux.org >/dev/null 2>&1 && echo "DNS OK" || echo "DNS KO"; mmcli -L 2>/dev/null | tail -n 2' 2>&1 | tail -n 5
