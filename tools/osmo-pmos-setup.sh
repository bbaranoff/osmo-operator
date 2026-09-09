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
ssh_vm() { sshpass -p "$PASS" ssh -p "$PORT" -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=8 -o PreferredAuthentications=password "$USER_VM@127.0.0.1" "$@"; }
# [2026-09-09] lib/audio.sh : l affectation des haut-parleurs et du micro de
# l hote (annuleur d echo, bouclages directs) - une seule source de verite,
# partagee avec audio-chain.sh (boot), start-direct et osmo-pmos-qemu.
AUDIO_LIB="${OSMO_REPO:-/opt/GSM/osmo-operator}/lib/audio.sh"
if [ -f "$AUDIO_LIB" ]; then
    # shellcheck source=../lib/audio.sh
    . "$AUDIO_LIB"
else
    AUDIO_LIB=""
fi
# [2026-09-09] LA VOIX EN FONCTION, ET SEULE SI ON VEUT (osmo-pmos-setup --voix).
# Sans modem (OSMO_PMOS_MODEM=0) rien ne basculait la VM sur sa carte
# « combine » : la sortie par defaut restait le PONT (0x12), dont la lecture
# part dans gsm_mic - le telephone semblait muet. osmo-pmos-qemu appelle
# --voix des que le SSH repond quand il ne branche pas le modem.
voix() {
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
    # [2026-09-09] L AFFECTATION DES HP ET DU MICRO VIENT DE lib/audio.sh, seule
    # source de verite (voir « L AFFECTATION DES HAUT-PARLEURS » la-bas) : les
    # bouclages directs de l hote sont retires, l annuleur d echo pose (ou deja
    # la, osmo-pmos-qemu le charge avant QEMU) et devient le defaut, et les flux
    # QEMU « combine » vont sur lui - audio_hp_sink / audio_mic_source.
    HP_SINK=""; MIC_SRC=""
    if [ -n "$AUDIO_LIB" ]; then
        remove_direct_loopbacks
        ensure_echo_cancel
        ensure_record_mix
        HP_SINK="$(audio_hp_sink)"; MIC_SRC="$(audio_mic_source)"
        echo "  haut-parleurs de l operateur : ${HP_SINK:-aucun} ; micro : ${MIC_SRC:-aucun}"
    else
        echo "  ATTENTION : lib/audio.sh introuvable (OSMO_REPO ?) - l audio de l hote n est pas regle"
    fi

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
    # Les flux QEMU de la carte « combine » (media.name=combine) sur les HP et
    # le micro de l operateur - ils y sont deja quand osmo-pmos-qemu les a
    # nommes au lancement (OSMO_PMOS_HP / OSMO_PMOS_MIC), sinon on les y met.
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
    # [2026-09-09] speech-dispatcher (module dummy) joue un message factice grave
    # et fort dans les haut-parleurs quand une appli demande une synthese vocale :
    # on l envoie dans le sink poubelle osmo_tts_off (cf. lib/audio.sh) ; stream-
    # restore s en souviendra pour les flux suivants.
    pactl list short sinks 2>/dev/null | grep -qw osmo_tts_off \
        || pactl load-module module-null-sink sink_name=osmo_tts_off format=s16le rate=8000 channels=1 sink_properties=device.description=TTS_off >/dev/null 2>&1
    for si in $(pactl list sink-inputs 2>/dev/null | awk '/Sink Input #/{id=$3} /application.name = "speech-dispatcher/{print id}' | tr -d '#'); do
        pactl move-sink-input "$si" osmo_tts_off 2>/dev/null && echo "  flux speech-dispatcher detourne des haut-parleurs (osmo_tts_off)"
    done
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
        # [2026-09-09] IDEMPOTENT POUR DE VRAI. On rechargeait les deux
        # bouclages a chaque passage : relancer osmo-pmos-setup pendant un
        # appel coupait la voix une demi-seconde. Si les deux sont deja la,
        # epingles, avec les bons bouts, on n y touche pas.
        deja=$(pactl list short modules 2>/dev/null | grep -c "module-loopback.*sink_dont_move=true")
        if [ "$deja" = "2" ] \
           && pactl list short modules 2>/dev/null | grep -q "source=$PONT_IN.*sink=$COMB_OUT" \
           && pactl list short modules 2>/dev/null | grep -q "source=$COMB_IN.*sink=$PONT_OUT"; then
            echo "  bouclages deja en place et epingles - inchanges"
            exit 0
        fi
        # [2026-09-09] LE PULSE DE LA VM NE DOIT PLUS SUSPENDRE SES CARTES.
        # module-suspend-on-idle endort un sink des que plus personne ne joue :
        # QEMU FERME alors ses flux cote hote. Deux degats. Un, l hote ne voit
        # plus le telephone (il le reconnait desormais a son processus, cf.
        # lib/audio.sh) ; deux, chaque reveil renegocie la latence des deux
        # cartes emulees, et c est la que la voix casse - « ca marche les deux
        # premieres fois et apres non ». Nos bouclages tiennent les cartes
        # eveillees, mais pas avant qu ils soient poses : on retire le module.
        for m in $(pactl list modules short 2>/dev/null | grep module-suspend-on-idle | cut -f1); do
            pactl unload-module "$m" 2>/dev/null && echo "  mise en veille des cartes desactivee (module-suspend-on-idle)"
        done
        # Idempotent : on retire les bouclages precedents avant de reposer.
        # [2026-09-08] 200 ms et pas 40 : a 40 ms PulseAudio, dans la VM,
        # notait « Too many underruns, increasing latency » et la voix
        # craquait (echo du 600 brouille). Une VM n a pas la regularite d une
        # carte son ; 200 ms restent imperceptibles sur un appel.
        # [2026-09-09] adjust_time=0 ET 400 ms. Le mobile ecrit son audio par
        # trames de 20 ms au rythme du L1 : avec l ajustement de cadence par
        # defaut (adjust_time=10), module-loopback re-echantillonnait sans
        # cesse pour tenir ses 200 ms - mesure sur l hote : sauts de retard de
        # 46 ms en pleine parole, correlation de forme d onde 0,29 en appel
        # contre 0,87 en injection directe ; a l oreille « deux flux qui se
        # superposent », voix pourrie. Cadence fixe + 400 ms de tampon :
        # correlation 1,00 sur tout l appel, retard stable a 497 ms.
        for m in $(pactl list modules short 2>/dev/null | grep module-loopback | cut -f1); do
            pactl unload-module "$m" 2>/dev/null
        done
        # [2026-09-09] EPINGLES (dont_move) : callaudiod / Phosh changent le
        # peripherique par defaut A CHAQUE APPEL (journal : « card has no voice
        # profile and no usable sink ») et PulseAudio deplace alors tout flux
        # non epingle - les deux bouclages partaient ailleurs des le decroche.
        pactl load-module module-loopback source="$PONT_IN" sink="$COMB_OUT" latency_msec=400 adjust_time=0 sink_dont_move=true source_dont_move=true >/dev/null \
            && echo "  descendant : pont -> combine (on entend)"
        pactl load-module module-loopback source="$COMB_IN" sink="$PONT_OUT" latency_msec=400 adjust_time=0 sink_dont_move=true source_dont_move=true >/dev/null \
            && echo "  montant    : combine -> pont (on parle)"
    ' 2>&1 | tail -n 6
fi
}

# [2026-09-08] ON ATTEND LE SSH. Lance a la main pendant que la VM demarre
# encore, tout echouait (« n a pas acces ») : on patiente jusqu a 90 s.
for _ in $(seq 1 45); do
    ssh_vm 'echo ok' 2>/dev/null | grep -q ok && break
    [ "$_" -eq 1 ] && echo "  la VM ne repond pas encore en SSH (port $PORT), on attend..."
    sleep 2
done
ssh_vm 'echo ok' 2>/dev/null | grep -q ok || { echo "  ATTENTION : pas de SSH sur le port $PORT - la VM est-elle lancee ?"; exit 1; }
if [ "${1:-}" = "--voix" ] || [ "${1:-}" = "voix" ]; then voix; exit 0; fi

ssh_vm "echo $PASS | sudo -S -p '' sh -c '
    mkdir -p /etc/systemd/resolved.conf.d
    # DNSSEC=no : le DNS interne de QEMU (10.0.2.3) ne signe pas ses reponses,
    # et resolved refusait tout - « DNSSEC validation failed: no-signature ».
    printf \"[Resolve]\nDNS=10.0.2.3 1.1.1.1\nFallbackDNS=8.8.8.8\nDNSSEC=no\nDNSOverTLS=no\n\" \
        > /etc/systemd/resolved.conf.d/osmo.conf
    systemctl restart systemd-resolved 2>/dev/null

    # Le modem arrive sur un port serie PCI : 8250_pci est integre a ce noyau,
    # il n y a donc aucun module a charger (ftdi_sio, lui, n existe pas ici).

    mkdir -p /etc/udev/rules.d
    # [2026-09-08] DEUX PORTS, UN SEUL MODEM. hvc0 = commande, hvc1 = donnees
    # (ID_MM_PORT_TYPE_AT_PPP : c est la que ModemManager compose ATD*99), et
    # le meme ID_MM_PHYSDEV_UID pour que MM les regroupe en un modem au lieu
    # d en voir deux. ttyS[1-9] : le 16550 de OSMO_PMOS_SERIAL=pci.
    {
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"hvc0\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_PHYSDEV_UID}=\\\"osmo-banc\\\", ENV{ID_MM_PORT_TYPE_AT_PRIMARY}=\\\"1\\\"\n\"
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"hvc1\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_PHYSDEV_UID}=\\\"osmo-banc\\\", ENV{ID_MM_PORT_TYPE_AT_PPP}=\\\"1\\\"\n\"
      printf \"ACTION==\\\"add|change\\\", SUBSYSTEM==\\\"tty\\\", KERNEL==\\\"ttyS[1-9]\\\", ENV{ID_MM_DEVICE_PROCESS}=\\\"1\\\", ENV{ID_MM_TTY_BAUDRATE}=\\\"115200\\\"\n\"
    } > /etc/udev/rules.d/99-osmo-modem.rules
    udevadm control --reload 2>/dev/null
    udevadm trigger --subsystem-match=tty 2>/dev/null
    # [2026-09-08] Le port modem est un virtconsole (/dev/hvc0) : le
    # generateur getty de systemd ouvre une invite de login sur la premiere
    # console de virtualisation, et c est elle qui repondait au modem
    # (« pmos-gsm login: ATE0 »). On la masque, le port est au modem seul.
    systemctl mask --now serial-getty@hvc0.service getty@hvc0.service serial-getty@hvc1.service getty@hvc1.service >/dev/null 2>&1

    # [2026-09-07] LA DATA : pppd et le greffon PPP de NetworkManager. Sans
    # eux, ATD*99 aboutit a CONNECT puis NO CARRIER une seconde plus tard
    # (« PPP failed to start: libnm-ppp-plugin.so is not installed »). Le
    # noyau doit avoir PPP (build-pm.sh) ; les modules se chargent au boot.
    # [2026-09-08] Le filaire n a plus de route par defaut (voir le bloc
    # suivant) : pour apk, on la lui rend le temps de ce bloc, avec le DNS
    # de QEMU, et le service osmo-filaire la retire juste apres.
    ip route replace default via 10.0.2.2 dev eth0 2>/dev/null
    resolvectl dns eth0 10.0.2.3 2>/dev/null; resolvectl default-route eth0 yes 2>/dev/null
    apk info -e ppp networkmanager-ppp >/dev/null 2>&1 \
        || apk add ppp networkmanager-ppp 2>&1 | tail -n 1
    # networkmanager et networkmanager-ppp DOIVENT etre de la meme version :
    # NM cherche le greffon dans /usr/lib/NetworkManager/<sa version>/. apk add
    # du greffon avait pris 1.58 sur le depot alors que l image portait NM
    # 1.56 : « libnm-ppp-plugin.so is not installed », et pas de PPP.
    NMV=\$(apk info -v 2>/dev/null | grep -oE \"^networkmanager-[0-9.]+\" | head -n1 | sed \"s/^networkmanager-//\")
    NMP=\$(apk info -v 2>/dev/null | grep -oE \"^networkmanager-ppp-[0-9.]+\" | head -n1 | sed \"s/^networkmanager-ppp-//\")
    # TOUS les sous-paquets networkmanager-* (wwan, ppp, ...) : chacun pose son
    # greffon dans le repertoire de SA version ; un seul en retard, et NM ne
    # voit plus le modem (wwan) ou ne lance plus pppd (ppp).
    [ \"\$NMV\" = \"\$NMP\" ] || apk upgrade \$(apk info 2>/dev/null | grep -E \"^networkmanager\") ppp 2>&1 | tail -n 1
    # Le journal bornait a rien : 168 Mo sur un disque de 2 Go, plein.
    mkdir -p /etc/systemd/journald.conf.d
    printf \"[Journal]\nSystemMaxUse=48M\n\" > /etc/systemd/journald.conf.d/osmo.conf
    journalctl --vacuum-size=40M >/dev/null 2>&1; rm -rf /var/cache/apk/*
    printf \"ppp_generic\nppp_async\n\" > /etc/modules-load.d/osmo-ppp.conf
    modprobe ppp_async 2>/dev/null

    systemctl restart ModemManager 2>/dev/null
    sleep 3
    mmcli --scan-modems 2>/dev/null | tail -n 1
'" 2>&1 | tail -n 4

# [2026-09-08] LA DATA PAR NOTRE 4G SEULEMENT. La carte virtio de QEMU (le
# « filaire ») donnait au telephone une route par defaut et un DNS par le
# NAT de QEMU : Phosh affichait une prise reseau et tout passait par la, la
# 4G ne servait a rien. On ne peut pas retirer la carte de QEMU : c est par
# elle (hostfwd 2222) que ce script parle a la VM. On la rend donc INVISIBLE
# au telephone : NetworkManager ne la gere plus (driver virtio_net non gere),
# un petit service lui laisse juste son adresse de gestion 10.0.2.15 sans
# route par defaut ni DNS, resolved ne pointe plus sur le DNS de QEMU. Le
# telephone n a plus qu une sortie : la connexion mobile (APN srsapn, creee
# ici si elle manque, automatique), donc le PPP du banc, donc la radio.
# OSMO_PMOS_FILAIRE=1 remet le filaire (gere par NM, DNS de QEMU).
# Le basculement coupe une seconde l adresse par laquelle on est connecte :
# il tourne detache dans la VM, et on attend le retour du SSH.
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
# osmo-filaire - la carte virtio de QEMU garde son adresse de gestion (SSH
# depuis l hote par hostfwd), sans route par defaut ni DNS : la data du
# telephone passe par la connexion mobile, donc par le PPP du banc.
for d in /sys/class/net/*; do
    n=${d##*/}
    drv=$(basename "$(readlink "$d/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$drv" = virtio_net ] || continue
    ip link set "$n" up
    ip addr replace 10.0.2.15/24 dev "$n"
    ip route del default dev "$n" 2>/dev/null
    resolvectl revert "$n" 2>/dev/null     # plus de DNS de QEMU par ce lien
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
    # Un seul profil mobile : celui que l utilisateur a deja cree (srsapn)
    # sert tel quel, sinon on en cree un.
    GSM=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2 == "gsm" {print $1; exit}')
    if [ -z "$GSM" ]; then
        nmcli con add type gsm ifname '*' con-name 'Osmocom 4G' apn srsapn \
            connection.autoconnect yes ipv4.route-metric 50 >/dev/null 2>&1 && GSM='Osmocom 4G'
    fi
    # NetworkManager est REDEMARRE : apk vient parfois de le mettre a jour avec
    # le greffon PPP, et le daemon encore en memoire cherche le greffon de SON
    # numero de version (« libnm-ppp-plugin.so is not installed » alors qu il
    # est la, dans le repertoire de la version neuve). Le fichier de
    # configuration etant pose, il repart avec le filaire non gere.
    # Detache par systemd-run : un simple « setsid ... & » meurt avec la
    # session SSH (logind de la VM tue les processus de l utilisateur a la
    # deconnexion), et rien ne se passait.
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

# Le modem du banc vient maintenant se brancher sur le port que QEMU tient
# ouvert. On ne le fait qu ICI, systeme demarre : branche des le debut, le
# firmware UEFI prend ses reponses pour des touches et n amorce jamais (voir
# l entete de osmo-pmos-qemu).
PORT_AT="${OSMO_PMOS_AT_PORT:-12346}"
REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
# [2026-09-08] LE MODEM EN ROOT : la data du telephone est un lien PPP dont le
# banc fait un tun (/dev/net/tun + TUNSETIFF), qu il pose dans l espace reseau
# de srsUE avec un NAT vers tun_srsue. Tout cela exige root ; lance sous le
# compte de session, le banc repondait CONNECT mais « la data n a pas de
# sortie radio ». osmo-pmos-qemu a deja fait sudo -v dans ce terminal ; sinon
# on demande si on a un terminal, et on se rabat sur l utilisateur en le disant.
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
    # La trace AT de CE modem dans son propre fichier : en root, les deux
    # instances du banc ecrivaient dans /var/log/osmo-at-ofono.log et leurs
    # dialogues se melangeaient (le sondage +CLCC de l hote au milieu des RING
    # de la VM).
    # sudo AVANT setsid : le cache du mot de passe est attache au terminal,
    # et setsid s en detache - « sudo » lance sous setsid redemandait le mot
    # de passe (« a terminal is required ») et le modem ne partait pas.
    # --data : le port de donnees (hvc1, chardev QEMU sur PORT_AT+1), voir le
    # modem a deux ports dans osmo-phonesim-banc.py.
    $BANC_SUDO setsid nohup env OSMO_AT_LOG_OFONO=/tmp/osmo-at-vm.log \
        "$REPO/tools/osmo-phonesim-banc.py" --connect "127.0.0.1:$PORT_AT" --data "127.0.0.1:$((PORT_AT + 1))" \
        >>"$BANC_LOG" 2>&1 </dev/null &
    sleep 3
    pgrep -f "[o]smo-phonesim-banc.py --connect" >/dev/null 2>&1 \
        && echo "  modem du banc branche sur la VM (port $PORT_AT)" \
        || echo "  ATTENTION : le modem ne s est pas branche (cf. $BANC_LOG)"
fi
# [2026-09-08] MODEMMANAGER SONDE APRES LE BRANCHEMENT. Le redemarrage de MM
# plus haut a lieu AVANT que le banc soit sur le port : la sonde de hvc0 tombe
# dans le vide, MM raye le port et ne le ressonde plus (« No modems were
# found » pour de bon). Un second redemarrage, le modem branche, et il le voit.
# Et NetworkManager APRES ModemManager : relance (par la bascule reseau plus
# haut) pendant que MM etait absent, NM notait « error creating ModemManager
# client » et ne voyait jamais le modem ensuite - pas de device gsm, pas de
# PPP, modem « disabled ». Detache par systemd-run : la relance de NM coupe
# la session SSH qui la demande.
ssh_vm "echo $PASS | sudo -S -p '' systemd-run --quiet --collect --unit osmo-mm-puis-nm sh -c 'systemctl restart ModemManager; sleep 6; systemctl restart NetworkManager'" >/dev/null 2>&1
for _ in $(seq 1 20); do
    sleep 1
    ssh_vm 'echo ok' 2>/dev/null | grep -q ok && break
done
sleep 8

voix

echo "--- etat"
# ModemManager vient d etre relance : il sonde le port pendant quelques
# secondes, et « No modems were found » lu trop tot faisait croire a une
# panne. On lui laisse jusqu a 40 s.
ssh_vm 'for i in $(seq 1 20); do mmcli -L 2>/dev/null | grep -q Modem/ && break; sleep 2; done
ls /dev/hvc0 /dev/hvc1 /dev/ttyS[1-9] 2>/dev/null | head -n 4
getent hosts alpinelinux.org >/dev/null 2>&1 && echo "DNS OK" || echo "DNS KO"
mmcli -L 2>/dev/null | tail -n 1
mmcli -m any 2>/dev/null | grep -E "state:|access tech|primary port|ports" | sed "s/^ *|//"' 2>&1 | tail -n 8
