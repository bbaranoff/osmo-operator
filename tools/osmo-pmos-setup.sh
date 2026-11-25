#!/bin/bash
# osmo-pmos-setup - prepares the postmarketOS VM for the bench modem.
#
# Run from the host, with the VM started (SSH on 2222). It applies,
# PERSISTENTLY:
#   - the DNS: postmarketOS goes through systemd-resolved, which has no server
#     under QEMU (hence "no network" while the IP and route are fine);
#   - the udev rule that tells ModemManager to probe the modem port (a PCI
#     serial port), otherwise it ignores it;
#   - the wired link hidden from the phone, so that data goes through the
#     mobile connection (PPP of the bench);
#   - the voice wiring (--voix): host audio and the sound card of the VM.
set -u
PORT="${OSMO_PMOS_SSH_PORT:-2222}"
PASS="${OSMO_PMOS_PASS:-147147}"
USER_VM="${OSMO_PMOS_USER:-user}"
ssh_vm() { sshpass -p "$PASS" ssh -p "$PORT" -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=8 -o PreferredAuthentications=password "$USER_VM@127.0.0.1" "$@"; }
# lib/audio.sh: the assignment of the host speakers and microphone (echo
# canceller, direct loopbacks) - a single source of truth, shared with
# audio-chain.sh (boot), start-native and osmo-pmos-qemu.
AUDIO_LIB="${OSMO_REPO:-/opt/GSM/osmo-operator}/lib/audio.sh"
if [ -f "$AUDIO_LIB" ]; then
    # shellcheck source=../lib/audio.sh
    . "$AUDIO_LIB"
else
    AUDIO_LIB=""
fi
# THE VOICE AS A FUNCTION, callable alone (osmo-pmos-setup --voix).
#
# ONE MICROPHONE, ONE SPEAKER. The call voice stays on the host, 40 ms:
#   downlink  gsm_audio -> speakers (through the echo canceller osmo_hp_ec)
#   uplink    microphone (osmo_mic_ec) -> gsm_mic
# The VM has ONE sound card (0000:00:13.0, pmbootstrap osmo_bench_args) on
# those same speakers and microphone, for the ringtone, the notifications
# and Calls. [2026-11-25] The second "bridge" card and the option of routing
# the voice through the VM (OSMO_PMOS_VOIX_VM, ~800 ms) are gone.
# OSMO_PMOS_RELAI=0 to leave the audio alone.
voix() {
if [ "${OSMO_PMOS_RELAI:-1}" = "1" ]; then
    echo "--- voix"
    HP_SINK=""; MIC_SRC=""
    if [ -n "$AUDIO_LIB" ]; then
        ensure_echo_cancel
        ensure_record_mix
        ensure_local_loopback
        ensure_local_mic
        echo "  la voix reste sur l hote (40 ms)"
        HP_SINK="$(audio_hp_sink)"; MIC_SRC="$(audio_mic_source)"
        echo "  haut-parleurs de l operateur : ${HP_SINK:-aucun} ; micro : ${MIC_SRC:-aucun}"
    else
        echo "  ATTENTION : lib/audio.sh introuvable (OSMO_REPO ?) - l audio de l hote n est pas regle"
    fi

    # THE MUTES THAT COME BACK. The downlink crosses four volume controls,
    # and ONE on mute is enough for the voice to vanish with no loopback
    # missing. Two are host side: the QEMU "combine" stream (the VM output to
    # the speakers) and the speaker sink. PulseAudio REMEMBERS them by
    # application name (module-stream-restore): once muted, the stream comes
    # back muted at every launch. So they are unmuted at every setup.
    for i in $(pactl list sink-inputs short 2>/dev/null | cut -f1); do
        pactl set-sink-input-mute "$i" 0 2>/dev/null
        pactl set-sink-input-volume "$i" 100% 2>/dev/null
    done
    for o in $(pactl list source-outputs short 2>/dev/null | cut -f1); do
        pactl set-source-output-mute "$o" 0 2>/dev/null
    done
    # The QEMU streams of the "combine" card (media.name=combine) on the
    # operator's speakers and microphone - already there when osmo-pmos-qemu
    # named them at launch (OSMO_PMOS_HP / OSMO_PMOS_MIC), otherwise moved.
    if [ -n "$MIC_SRC" ]; then
        for so in $(pactl list source-outputs 2>/dev/null | awk '/Source Output #/{id=$3} /media.name = "combine"/{print id}' | tr -d '#'); do
            pactl move-source-output "$so" "$MIC_SRC" 2>/dev/null
        done
    fi
    if [ -n "$HP_SINK" ]; then
        for si in $(pactl list sink-inputs 2>/dev/null | awk '/Sink Input #/{id=$3} /media.name = "combine"/{print id}' | tr -d '#'); do
            pactl move-sink-input "$si" "$HP_SINK" 2>/dev/null
        done
    fi
    pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null && echo "  sourdines de l hote levees (haut-parleur et micro)"
    # speech-dispatcher (dummy module) plays a loud, low dummy message in the
    # speakers when an application requests speech synthesis: it is sent to
    # the osmo_tts_off trash sink (see lib/audio.sh); stream-restore remembers
    # it for the following streams.
    pactl list short sinks 2>/dev/null | grep -qw osmo_tts_off \
        || pactl load-module module-null-sink sink_name=osmo_tts_off format=s16le rate=8000 channels=1 sink_properties=device.description=TTS_off >/dev/null 2>&1
    for si in $(pactl list sink-inputs 2>/dev/null | awk '/Sink Input #/{id=$3} /application.name = "speech-dispatcher/{print id}' | tr -d '#'); do
        pactl move-sink-input "$si" osmo_tts_off 2>/dev/null && echo "  flux speech-dispatcher detourne des haut-parleurs (osmo_tts_off)"
    done
    ssh_vm '
        CARTE_OUT=$(pactl list sinks short 2>/dev/null | grep "pci-0000_00_13\.0" | head -n1 | cut -f2)
        CARTE_IN=$(pactl list sources short 2>/dev/null | grep "pci-0000_00_13\.0" | grep -v monitor | head -n1 | cut -f2)
        if [ -z "$CARTE_OUT" ]; then
            echo "  ATTENTION : la VM ne voit pas sa carte son (0000:00:13.0)"
            pactl list sinks short 2>/dev/null
            exit 0
        fi
        # La carte unique est le peripherique par defaut, sans sourdine.
        pactl set-default-sink "$CARTE_OUT"
        pactl set-sink-mute "$CARTE_OUT" 0; pactl set-sink-volume "$CARTE_OUT" 100%
        if [ -n "$CARTE_IN" ]; then
            pactl set-default-source "$CARTE_IN"; pactl set-source-mute "$CARTE_IN" 0
        fi
        # Plus de croisement de cartes : les bouclages d une ancienne
        # installation sont retires.
        for m in $(pactl list modules short 2>/dev/null | grep module-loopback | cut -f1); do
            pactl unload-module "$m" 2>/dev/null
        done
        echo "  VM : un haut-parleur ($CARTE_OUT), un micro (${CARTE_IN:-aucun})"
    ' 2>&1 | tail -n 6
fi
}

# WAIT FOR SSH. Launched by hand while the VM is still booting, everything
# would fail: wait up to 90 s.
for _ in $(seq 1 45); do
    ssh_vm 'echo ok' 2>/dev/null | grep -q ok && break
    [ "$_" -eq 1 ] && echo "  la VM ne repond pas encore en SSH (port $PORT), on attend..."
    sleep 2
done
ssh_vm 'echo ok' 2>/dev/null | grep -q ok || { echo "  ATTENTION : pas de SSH sur le port $PORT - la VM est-elle lancee ?"; exit 1; }
if [ "${1:-}" = "--voix" ] || [ "${1:-}" = "voix" ]; then voix; exit 0; fi

ssh_vm "echo $PASS | sudo -S -p '' sh -c '
    mkdir -p /etc/systemd/resolved.conf.d
    # DNSSEC=no: the internal QEMU DNS (10.0.2.3) does not sign its answers,
    # and resolved would refuse everything (DNSSEC validation failed).
    printf \"[Resolve]\nDNS=10.0.2.3 1.1.1.1\nFallbackDNS=8.8.8.8\nDNSSEC=no\nDNSOverTLS=no\n\" \
        > /etc/systemd/resolved.conf.d/osmo.conf
    systemctl restart systemd-resolved 2>/dev/null

    # The modem arrives on a PCI serial port: 8250_pci is built into this
    # kernel, so there is no module to load (ftdi_sio does not exist here).

    mkdir -p /etc/udev/rules.d
    # TWO PORTS, ONE MODEM. hvc0 = command, hvc1 = data
    # (ID_MM_PORT_TYPE_AT_PPP: where ModemManager dials ATD*99), and the same
    # ID_MM_PHYSDEV_UID so that MM groups them into one modem instead of
    # seeing two. ttyS[1-9]: the 16550 of OSMO_PMOS_SERIAL=pci.
    {
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"hvc0\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_PHYSDEV_UID}=\\\"osmo-banc\\\", ENV{ID_MM_PORT_TYPE_AT_PRIMARY}=\\\"1\\\"\n\"
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"hvc1\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_PHYSDEV_UID}=\\\"osmo-banc\\\", ENV{ID_MM_PORT_TYPE_AT_PPP}=\\\"1\\\"\n\"
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"ttyS[1-9]\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_TTY_BAUDRATE}=\\\"115200\\\"\n\"
    } > /etc/udev/rules.d/99-osmo-modem.rules
    udevadm control --reload 2>/dev/null
    udevadm trigger --subsystem-match=tty 2>/dev/null
    # The modem port is a virtconsole (/dev/hvc0): the systemd getty
    # generator opens a login prompt on the first virtualisation console,
    # which would answer the modem. It is masked, the port is the modem only.
    systemctl mask --now serial-getty@hvc0.service getty@hvc0.service serial-getty@hvc1.service getty@hvc1.service >/dev/null 2>&1

    # DATA: pppd and the NetworkManager PPP plugin. Without them, ATD*99
    # ends in CONNECT then NO CARRIER one second later (PPP failed to start:
    # libnm-ppp-plugin.so is not installed). The kernel must have PPP
    # (build-pm.sh); the modules load at boot.
    # The wired link has no default route (see the next block): for apk it
    # is restored for the duration of this block, with the QEMU DNS, and the
    # osmo-filaire service removes it right after.
    ip route replace default via 10.0.2.2 dev eth0 2>/dev/null
    resolvectl dns eth0 10.0.2.3 2>/dev/null; resolvectl default-route eth0 yes 2>/dev/null
    apk info -e ppp networkmanager-ppp >/dev/null 2>&1 \
        || apk add ppp networkmanager-ppp 2>&1 | tail -n 1
    # networkmanager and networkmanager-ppp MUST be the same version: NM
    # looks for the plugin in /usr/lib/NetworkManager/<its version>/.
    NMV=\$(apk info -v 2>/dev/null | grep -oE \"^networkmanager-[0-9.]+\" | head -n1 | sed \"s/^networkmanager-//\")
    NMP=\$(apk info -v 2>/dev/null | grep -oE \"^networkmanager-ppp-[0-9.]+\" | head -n1 | sed \"s/^networkmanager-ppp-//\")
    # ALL the networkmanager-* sub-packages (wwan, ppp, ...): each installs
    # its plugin in the directory of ITS version; a single one lagging, and
    # NM no longer sees the modem (wwan) or no longer starts pppd (ppp).
    [ \"\$NMV\" = \"\$NMP\" ] || apk upgrade \$(apk info 2>/dev/null | grep -E \"^networkmanager\") ppp 2>&1 | tail -n 1
    # The journal is bounded: unbounded it fills the 2 GB disk.
    mkdir -p /etc/systemd/journald.conf.d
    printf \"[Journal]\nSystemMaxUse=48M\n\" > /etc/systemd/journald.conf.d/osmo.conf
    journalctl --vacuum-size=40M >/dev/null 2>&1; rm -rf /var/cache/apk/*
    printf \"ppp_generic\nppp_async\n\" > /etc/modules-load.d/osmo-ppp.conf
    modprobe ppp_async 2>/dev/null

    systemctl restart ModemManager 2>/dev/null
    sleep 3
    mmcli --scan-modems 2>/dev/null | tail -n 1
'" 2>&1 | tail -n 4

# DATA THROUGH OUR 4G ONLY. The QEMU virtio card (the "wired" link) would
# give the phone a default route and a DNS through the QEMU NAT, and
# everything would go through it. The card cannot be removed from QEMU: it is
# through it (hostfwd 2222) that this script talks to the VM. So it is made
# INVISIBLE to the phone: NetworkManager no longer manages it (virtio_net
# driver unmanaged), a small service leaves it only its management address
# 10.0.2.15 without default route or DNS, resolved no longer points to the
# QEMU DNS. The phone has only one way out: the mobile connection (APN
# srsapn, created here if missing, automatic), hence the bench PPP, hence the
# radio. OSMO_PMOS_FILAIRE=1 restores the wired link (managed by NM, QEMU
# DNS). The switch cuts for a second the address we are connected through:
# it runs detached in the VM, and we wait for SSH to come back.
FILAIRE="${OSMO_PMOS_FILAIRE:-0}"
{ echo "$PASS"; echo "FILAIRE=$FILAIRE"; cat <<'GUEST'
set -u
CONF=/etc/NetworkManager/conf.d/90-osmo-filaire.conf
SVC=/etc/systemd/system/osmo-filaire.service
BIN=/usr/local/bin/osmo-filaire
mkdir -p /etc/NetworkManager/conf.d /etc/systemd/resolved.conf.d
if [ "$FILAIRE" = 0 ]; then
    printf '[keyfile]\nunmanaged-devices=driver:virtio_net\n' > "$CONF"
    cat > "$BIN" <<'EOB'
#!/bin/sh
# osmo-filaire - the QEMU virtio card keeps its management address (SSH from
# the host through hostfwd), without default route or DNS: the phone data
# goes through the mobile connection, hence through the bench PPP.
for d in /sys/class/net/*; do
    n=${d##*/}
    drv=$(basename "$(readlink "$d/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$drv" = virtio_net ] || continue
    ip link set "$n" up
    ip addr replace 10.0.2.15/24 dev "$n"
    ip route del default dev "$n" 2>/dev/null
    resolvectl revert "$n" 2>/dev/null     # no QEMU DNS through this link
done
exit 0
EOB
    chmod 755 "$BIN"
    cat > "$SVC" <<'EOS'
[Unit]
Description=osmo-filaire - carte virtio en adresse de gestion seule (data par la 4G)
After=NetworkManager.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/osmo-filaire
[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload; systemctl enable osmo-filaire >/dev/null 2>&1
    printf '[Resolve]\nDNSSEC=no\nDNSOverTLS=no\n' > /etc/systemd/resolved.conf.d/osmo.conf
    # A single mobile profile: the one the user already created (srsapn) is
    # used as is, otherwise one is created.
    GSM=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2 == "gsm" {print $1; exit}')
    if [ -z "$GSM" ]; then
        nmcli con add type gsm ifname '*' con-name 'Osmocom 4G' apn srsapn \
            connection.autoconnect yes ipv4.route-metric 50 >/dev/null 2>&1 && GSM='Osmocom 4G'
    fi
    # NetworkManager is RESTARTED: apk may have just updated it with the PPP
    # plugin, and the daemon still in memory looks for the plugin of ITS
    # version number. The configuration file being in place, it restarts
    # with the wired link unmanaged.
    # Detached through systemd-run: a plain "setsid ... &" dies with the SSH
    # session (the VM logind kills the user processes at disconnection).
    systemd-run --quiet --collect --unit "osmo-filaire-bascule-$$" sh -c "
        sleep 1
        systemctl restart NetworkManager
        sleep 2
        /usr/local/bin/osmo-filaire
        systemctl restart systemd-resolved
        [ -n '$GSM' ] && nmcli con up '$GSM' >/dev/null 2>&1
        exit 0
    "
    echo "  filaire cache au telephone : adresse de gestion seule, data par la connexion mobile (APN srsapn)"
else
    rm -f "$CONF" "$BIN" "$SVC"; systemctl daemon-reload
    printf '[Resolve]\nDNS=10.0.2.3 1.1.1.1\nFallbackDNS=8.8.8.8\nDNSSEC=no\nDNSOverTLS=no\n' > /etc/systemd/resolved.conf.d/osmo.conf
    systemd-run --quiet --collect --unit "osmo-filaire-bascule-$$" sh -c '
        sleep 1
        systemctl restart NetworkManager
        systemctl restart systemd-resolved
    '
    echo "  filaire rendu au telephone (OSMO_PMOS_FILAIRE=1)"
fi
GUEST
} | ssh_vm "sudo -S -p '' sh -s" 2>/dev/null | tail -n 2
for _ in $(seq 1 20); do
    sleep 1
    ssh_vm 'echo ok' 2>/dev/null | grep -q ok && break
done
ssh_vm 'echo ok' 2>/dev/null | grep -q ok || echo "  ATTENTION : la VM ne repond plus en SSH apres le basculement reseau"

# The bench modem now connects to the port QEMU keeps open. Only HERE, with
# the system booted: connected from the start, the UEFI firmware takes its
# answers for keystrokes and never boots (see the osmo-pmos-qemu header).
PORT_AT="${OSMO_PMOS_AT_PORT:-12346}"
REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
# THE MODEM AS ROOT: the phone data is a PPP link the bench turns into a tun
# (/dev/net/tun + TUNSETIFF), placed in the srsUE network namespace with a
# NAT towards tun_srsue. All of that requires root. osmo-pmos-qemu has
# already done sudo -v in this terminal; otherwise ask if there is a
# terminal, and fall back to the user, saying so.
BANC_LOG="/tmp/osmo-phonesim-vm-$(id -un).log"
BANC_SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null || { [ -t 0 ] && sudo -v; }; then
        BANC_SUDO="sudo -n"
    else
        echo "  ATTENTION : pas de root pour le modem - la data PPP n aura pas de sortie radio"
    fi
fi
if pgrep -f "[o]smo-phonesim-banc.py --connect" >/dev/null 2>&1; then
    echo "  modem deja branche sur la VM"
else
    # The AT trace of THIS modem in its own file: as root, the two bench
    # instances would otherwise both write to /var/log/osmo-at-ofono.log and
    # their dialogues would mix.
    # sudo BEFORE setsid: the password cache is attached to the terminal,
    # and setsid detaches from it - sudo launched under setsid would ask for
    # the password again ("a terminal is required").
    # --data: the data port (hvc1, QEMU chardev on PORT_AT+1), see the
    # two-port modem in osmo-phonesim-banc.py.
    # THE RADIO EGRESS IS CHOSEN BY THE BENCH (_radio_choix in
    # osmo-phonesim-banc.py): 4G first (tun_srsue in the ue1 netns),
    # otherwise the GPRS PDP of the osmocom-bb modem (tun_modem in msgprs).
    # Nothing is forced here.
    $BANC_SUDO setsid nohup env OSMO_AT_LOG_OFONO=/tmp/osmo-at-vm.log \
        OSMO_PPP_DNS="${OSMO_PPP_DNS:-192.168.1.254,1.1.1.1}" \
        "$REPO/tools/osmo-phonesim-banc.py" --connect "127.0.0.1:$PORT_AT" --data "127.0.0.1:$((PORT_AT + 1))" \
        >>"$BANC_LOG" 2>&1 </dev/null &
    sleep 3
    pgrep -f "[o]smo-phonesim-banc.py --connect" >/dev/null 2>&1 \
        && echo "  modem du banc branche sur la VM (port $PORT_AT)" \
        || echo "  ATTENTION : le modem ne s est pas branche (cf. $BANC_LOG)"
fi
# MODEMMANAGER PROBES AFTER THE CONNECTION. The MM restart above happens
# BEFORE the bench is on the port: the hvc0 probe finds nothing, MM drops
# the port and never probes it again. A second restart, with the modem
# connected, and it sees it.
# And NetworkManager AFTER ModemManager: restarted while MM is absent, NM
# would log "error creating ModemManager client" and never see the modem
# afterwards - no gsm device, no PPP. Detached through systemd-run: the NM
# restart cuts the SSH session that requests it.
ssh_vm "echo $PASS | sudo -S -p '' systemd-run --quiet --collect --unit osmo-mm-puis-nm sh -c 'systemctl restart ModemManager; sleep 6; systemctl restart NetworkManager'" >/dev/null 2>&1
for _ in $(seq 1 20); do
    sleep 1
    ssh_vm 'echo ok' 2>/dev/null | grep -q ok && break
done
sleep 8

voix

echo "--- etat"
# ModemManager has just been restarted: it probes the port for a few
# seconds, and "No modems were found" read too early is misleading. Give it
# up to 40 s.
ssh_vm 'for i in $(seq 1 20); do mmcli -L 2>/dev/null | grep -q Modem/ && break; sleep 2; done
ls /dev/hvc0 /dev/hvc1 /dev/ttyS[1-9] 2>/dev/null | head -n 4
getent hosts alpinelinux.org >/dev/null 2>&1 && echo "DNS OK" || echo "DNS KO"
mmcli -L 2>/dev/null | tail -n 1
mmcli -m any 2>/dev/null | grep -E "state:|access tech|primary port|ports" | sed "s/^ *|//"' 2>&1 | tail -n 8
