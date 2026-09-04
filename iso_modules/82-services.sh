#!/bin/bash
# iso_modules/82-services.sh - role, os-release, asterisk, dashboard, audio, pulse
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Marqueur de role : ce que CETTE image est ───────────────────────────────
# Lu par start-direct.sh et par la banniere. Sans lui, deux ISO issues de la
# meme chaine sont indiscernables une fois demarrees - et on lance le mauvais
# script sur la mauvaise machine.
{
    printf '# /etc/osmo-role - genere par build-iso.sh\n'
    printf 'OSMO_ROLE=%s\n' "$ISO_ROLE"
    [ -n "$ISO_NODE" ] && printf 'OSMO_WAN_NODE=%s\n' "$ISO_NODE"
    # Pour la meme raison que le role : deux ISO issues de la meme chaine sont
    # indiscernables une fois demarrees. Celle-ci n'a pas les arbres de
    # compilation de /opt/GSM - autant que la machine puisse le dire elle-meme
    # quand quelque chose y sera cherche en vain.
    printf 'OSMO_LITE=%s\n' "$ISO_LITE"
    printf 'OSMO_HUB_IP=%s\n' "$ISO_HUB_IP"
} > "$ROOTFS/etc/osmo-role"

# ── /etc/os-release : l'image se nomme elle-meme ────────────────────────────
# [2026-08-27] Les trois ISO se presentaient toutes comme "Ubuntu 22.04 LTS".
# /etc/osmo-role dit deja ce que l'image est, mais lui ne s'affiche nulle part :
# la banniere de login, `hostnamectl`, les rapports de bug et le tableau de bord
# lisent os-release. Sur trois machines demarrees cote a cote, rien ne
# distinguait le hub d'un noeud, ni le noeud complet de sa variante elaguee.
#
# ON NE TOUCHE QU'AUX CHAMPS D'AFFICHAGE. ID, VERSION_ID, VERSION_CODENAME et
# UBUNTU_CODENAME restent ceux d'Ubuntu : apt, add-apt-repository et la moitie
# des scripts de paquets s'en servent pour choisir leurs depots. Renommer ID
# casserait l'image bien au-dela de sa banniere.
# VARIANT / VARIANT_ID sont les champs prevus par os-release(5) pour exactement
# cette distinction ; IMAGE_ID / IMAGE_VERSION, ceux prevus pour une image
# construite. On les remplit plutot que d'inventer des noms a nous.
case "$ISO_ROLE" in
    interstp) OS_NAME="osmo-operator interstp"; OS_VARIANT_ID="interstp" ;;
    *)        if [ "$ISO_LITE" = "1" ]; then
                  OS_NAME="osmo-operator-lite"; OS_VARIANT_ID="operator-lite"
              else
                  OS_NAME="osmo-operator";      OS_VARIANT_ID="operator"
              fi ;;
esac
# Le numero de noeud fait partie de l'identite quand il est fige dans l'image :
# c'est la seule chose qui distingue osmo-operator-1.iso de osmo-operator-2.iso.
OS_PRETTY="$OS_NAME"
[ -n "$ISO_NODE" ] && OS_PRETTY="$OS_NAME (noeud $ISO_NODE)"

# /etc/os-release est un lien vers ../usr/lib/os-release : on ecrit la cible et
# on laisse le lien tranquille - le remplacer par un fichier ferait diverger les
# deux chemins, que differents outils lisent indifferemment.
_osrel="$ROOTFS/usr/lib/os-release"
sed -i -e '/^NAME=/d' -e '/^PRETTY_NAME=/d' \
       -e '/^VARIANT=/d' -e '/^VARIANT_ID=/d' \
       -e '/^IMAGE_ID=/d' -e '/^IMAGE_VERSION=/d' \
       -e '/^HOME_URL=/d' -e '/^SUPPORT_URL=/d' -e '/^BUG_REPORT_URL=/d' \
       "$_osrel"
{
    printf 'NAME="%s"\n'          "$OS_NAME"
    printf 'PRETTY_NAME="%s"\n'   "$OS_PRETTY"
    printf 'VARIANT="%s"\n'       "$OS_PRETTY"
    printf 'VARIANT_ID="%s"\n'    "$OS_VARIANT_ID"
    printf 'IMAGE_ID="%s"\n'      "$OS_NAME"
    printf 'IMAGE_VERSION="%s"\n' "$LABEL"
    printf 'HOME_URL="https://github.com/bbaranoff/osmo-operator"\n'
    printf 'SUPPORT_URL="https://github.com/bbaranoff/osmo-operator"\n'
    printf 'BUG_REPORT_URL="https://github.com/bbaranoff/osmo-operator/issues"\n'
} >> "$_osrel"
echo -e "  ${GREEN}✓${NC} os-release : ${CYAN}${OS_PRETTY}${NC}"

# ── Asterisk : UN SEUL proprietaire, et c'est run_modules/19-asterisk.sh ────
# [2026-08-27] Le paquet asterisk installe son unite `enabled` : systemd
# demarrait donc un Asterisk au boot, pendant que 19-asterisk.sh lancait le sien
# en direct. Deux proprietaires pour un seul /etc/asterisk et une seule socket
# /var/run/asterisk/asterisk.ctl - la console finissait par ne plus repondre a
# personne et la pile s'arretait sur "console Asterisk : toujours pas pret".
# Le module ecarte deja systemd a chaque demarrage ; on le fait AUSSI ici pour
# que le premier boot d'une ISO neuve parte propre, sans le coup de balai.
chroot "$ROOTFS" systemctl disable asterisk >/dev/null 2>&1 || true
echo -e "  ${GREEN}✓${NC} asterisk.service desactive - le PBX est lance par ${CYAN}19-asterisk.sh${NC}"

if [ "$ISO_ROLE" = "interstp" ]; then
    # Le hub, lui, DOIT demarrer seul : les noeuds s'attachent a lui au boot, et
    # un hub qu'il faut lancer a la main transforme un demarrage simultane en
    # course perdue d'avance.
    cat > "$ROOTFS/etc/systemd/system/osmo-interstp.service" <<EOF
[Unit]
Description=osmo-operator inter-STP - hub SS7 du WAN (PC 0.0.0)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=forking
PIDFile=/run/osmo-interstp.pid
ExecStart=/opt/GSM/osmo-operator/start-interstp.sh --ip ${ISO_HUB_IP}
ExecStop=/opt/GSM/osmo-operator/start-interstp.sh --stop
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    chroot "$ROOTFS" systemctl enable osmo-interstp 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} osmo-interstp.service - hub lance au demarrage sur ${CYAN}${ISO_HUB_IP}${NC}"
fi


# Autologin root : pose plus bas (8d, getty@tty1.service.d/10-autologin-root.conf).

# ── Service web dashboard : DEJA POSE, NE PAS LE REECRIRE ───────────────────
# [2026-08-31] Ici vivait un SECOND heredoc qui reecrivait
# osmo-egprs-web.service par-dessus celui que l'etape 6 venait de copier depuis
# services/ - et il en etait une version APPAUVRIE : ni TLS_CERT/TLS_KEY (donc
# pas de listener HTTPS, donc pas de contexte securise, donc pas de micro), ni
# PULSE_SERVER (donc pas de pont audio vers gsm_mic), ni CAP_IFACE=any (donc
# l'onglet trafic muet). L'ISO partait avec cette version-la ; ce n'est qu'au
# premier boot que install-web-service.sh recopiait la bonne par-dessus, et
# seulement s'il allait au bout - ce qu'il ne faisait pas, puisqu'il echouait
# justement sur le service qui refusait de demarrer.
#
# Deux fichiers pour une seule unite, c'est un de trop : la source unique est
# services/osmo-egprs-web.service, copiee a l'etape 6. On ne garde ici que
# l'activation.
# Le hub n'a ni VTY d'operateur a afficher ni radio a tracer : le tableau de
# bord n'aurait rien a montrer. On ne l'active pas.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# ── Audio : PulseAudio systeme (sink gsm_audio) au boot ────────────────────
# Chaine : osmo-gapk → ALSA gsm_out → sink null gsm_audio → monitor → loopback
# → carte. system.pa autorise l'acces anonyme + prepare le sink ; le service
# lance le demon au boot (ensure_pulse de start-direct.sh devient un no-op).
if [ -f "$ROOTFS/etc/pulse/system.pa" ]; then
    sed -i 's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' \
        "$ROOTFS/etc/pulse/system.pa"
    # [2026-08-14] gsm_mic MANQUAIT ICI. Seul gsm_audio etait declare, alors que
    # lib/audio.sh traite les deux sinks comme SOLIDAIRES (GSM_SINKS) et que
    # configs/asound.conf fait pointer `pcm.gsm_in` sur `gsm_mic.monitor`.
    # Consequence mesuree dans la VM : `pactl list short sources` sans gsm_mic
    # → gapk_io n'initialise pas la capture et ABANDONNE LES DEUX SENS
    #   (pq_alsa.c:168 "Couldn't init ALSA device 'gsm_in'" puis
    #    gapk_io.c:468 "Failed to initialize GAPK I/O")
    # → appel parfaitement etabli et TOTALEMENT MUET. Les deux sinks doivent
    # etre declares ensemble, ici, comme le dit deja lib/audio.sh.
    for _s in "gsm_audio:GSM_Audio" "gsm_mic:GSM_Mic"; do
        _n="${_s%%:*}"; _d="${_s##*:}"
        grep -q "sink_name=${_n}\b" "$ROOTFS/etc/pulse/system.pa" || \
            echo "load-module module-null-sink sink_name=${_n} format=s16le rate=8000 channels=1 sink_properties=device.description=${_d}" \
            >> "$ROOTFS/etc/pulse/system.pa"
    done
fi
# [2026-08-14] /etc/asound.conf N'ETAIT DEPLOYE NULLE PART sur l'ISO. Il l'est
# par ensure_pulse() de lib/audio.sh - mais lib/audio.sh n'est source par
# personne (son appelant annonce, run_modules/25-audio.sh, n'existe pas). Sans
# ce fichier les PCM `gsm_out`/`gsm_in` que `mobile` ouvre n'existent pas, donc
# la voix TCH n'atteint jamais gsm_audio. Verifie absent dans la VM au boot.
if [ -f "$DIR/configs/asound.conf" ]; then
    cp -f "$DIR/configs/asound.conf" "$ROOTFS/etc/asound.conf"
    echo -e "  ${GREEN}✓${NC} /etc/asound.conf (PCM gsm_out/gsm_in → sinks PulseAudio)"
fi
cat > "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh" <<'ACHAIN'
#!/bin/bash
# osmo-audio-chain.sh - ferme la chaine audio locale apres le demarrage de
# PulseAudio. Appele en ExecStartPost par osmo-pulse.service.
#   1. /etc/asound.conf present (PCM gsm_out/gsm_in)
#   2. les DEUX null-sinks gsm_audio + gsm_mic charges
#   3. le module-loopback gsm_audio.monitor → carte son
# Sans (2), gapk_io abandonne LES DEUX SENS ; sans (3), la voix descendante est
# jetee par le null-sink. Toujours exit 0 : l'audio ne doit jamais empecher la
# pile de monter. AUDIO=0 ou AUDIO_LOCAL_LOOPBACK=0 neutralisent.
set -u
for r in /opt/GSM/osmo-operator /etc/osmocom/osmo-operator; do
    [ -x "$r/scripts/audio-chain.sh" ] && exec "$r/scripts/audio-chain.sh" "${1:-30}"
done
exit 0
ACHAIN
chmod +x "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh"

cat > "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh" <<'PLINK'
#!/bin/sh
# osmo-pulse-link.sh - rend le PulseAudio SYSTEME visible des applications qui
# cherchent un socket par utilisateur, snaps compris.
#
# En mode systeme, PulseAudio n'ecoute que sur /run/pulse/native. Les clients,
# eux, regardent $XDG_RUNTIME_DIR/pulse/native (soit /run/user/<uid>/pulse) -
# et c'est ce chemin que snapd monte dans le bac a sable. Sans lui, un snap ne
# voit AUCUN peripherique : Firefox rendait « NotFoundError » sur le micro,
# pendant que pactl listait deux entrees en RUNNING.
#
# Toujours exit 0 : l'audio ne doit jamais empecher la pile de monter.
#
# [2026-08-30] LE LIEN NE SUFFISAIT PAS : IL FAUT AUSSI LE PROPRIETAIRE.
# Le lien ci-dessous est necessaire mais pas suffisant, et le symptome etait
# tenace : les haut-parleurs marchaient, pactl listait la carte en RUNNING, et
# le navigateur restait MUET. La raison est dans le profil AppArmor du snap
# (/var/lib/snapd/apparmor/profiles/snap.firefox.firefox) :
#
#     owner /{,var/}run/pulse/native rwk,
#
# Le chemin EST autorise. C'est le qualificateur `owner` qui refuse : AppArmor
# exige que le proprietaire du fichier soit egal au fsuid du processus. Le
# journal du noyau le dit mot pour mot :
#
#     apparmor="DENIED" operation="connect" profile="snap.firefox.firefox"
#     name="/run/pulse/native" fsuid=0 ouid=107
#
# fsuid=0 (la session tourne en root) contre ouid=107 (le socket appartient a
# l'utilisateur `pulse`, puisque c'est lui qui fait tourner le demon systeme).
# Deux nombres differents, et tout le reste marche : c'est exactement le genre
# d'ecart qu'on cherche pendant des heures cote « permission micro » ou
# « pilote son », alors que la carte joue deja.
#
# ⚠️ AppArmor resout le CHEMIN REEL : le lien symbolique ci-dessous ne masque
# rien, la regle appliquee est bien celle de /run/pulse/native, pas celle de
# /run/user/<uid>/pulse/native.
#
# On donne donc le socket a l'uid de la session graphique. Sur cette ISO c'est
# root (autologin root, cf. gdm3/custom.conf) ; OSMO_PULSE_UID permet d'en
# choisir un autre. Le demon, lui, continue de tourner en `pulse` : accept()
# ne demande pas d'etre proprietaire, et le mode srwxrwxrwx laisse tout le
# monde se connecter. Un seul socket ne peut avoir qu'un proprietaire : un
# navigateur SNAP lance sous un AUTRE compte que celui-ci resterait muet.
set -u
PUID="${OSMO_PULSE_UID:-0}"
for d in /run/user/*; do
    [ -d "$d" ] || continue
    mkdir -p "$d/pulse" 2>/dev/null || continue
    ln -sfn /run/pulse/native "$d/pulse/native" 2>/dev/null || true
done
[ -S /run/pulse/native ] && chown "$PUID" /run/pulse/native 2>/dev/null || true
exit 0
PLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-pulse-link.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-pulse.service" <<'EOF'
[Unit]
Description=osmo-operator PulseAudio system daemon (GSM audio)
# sound.target seul ne garantit RIEN : c'est une cible passive, atteinte des que
# systemd a fini de traiter les regles udev deja connues - pas quand les cartes
# sont la. Au premier demarrage d'un disque fraichement installe, les modules
# snd_hda_* sont encore en cours de chargement quand cette unite part, et
# osmo-audio-chain.sh concluait "aucune sortie materielle - loopback local
# ignore" : l'appel montait, et il etait muet. module-udev-detect rattrape les
# cartes qui arrivent APRES le demarrage du demon (les sources et sinks ALSA
# apparaissent tout seuls), mais le loopback vers la carte, lui, n'est pose
# qu'une fois. On ne tire donc PAS systemd-udev-settle ici - il est obsolete et
# retarderait tout le boot pour un seul service : l'attente est dans
# scripts/audio-chain.sh, qui a deja un delai en parametre et ne fait patienter
# que lui-meme.
After=sound.target
Wants=sound.target
[Service]
# ── Type=notify ET --daemonize=no, ENSEMBLE OU PAS DU TOUT ──────────────────
# [2026-08-31] Ce couple valait "Type=forking" + "--daemonize=yes", et c'est ce
# qui rendait le son INDISPONIBLE sur le systeme installe alors qu'un
# "systemctl start osmo-pulse" a la main marchait a tous les coups.
#
# En Type=forking, systemd attend la mort du processus lance, puis DEVINE lequel
# des survivants du cgroup est le demon (GuessMainPID). pulseaudio --daemonize
# fait deux forks et laisse, le temps de la mise en place, ses fils de travail
# dans le cgroup : la devinette tombe sur un PID deja mort, systemd conclut que
# le service s'est termine, et son KillMode=control-group emporte le vrai demon
# qui venait juste de finir de charger ses modules. Le journal en garde la
# trace, et elle se lit a l'envers :
#     osmo-pulse.service: Deactivated successfully.
#     Started osmo-operator PulseAudio system daemon (GSM audio).
# "Deactivated" AVANT "Started" - le service est annonce demarre alors qu'il est
# deja mort. Rien n'echoue, rien n'est reessaye (Restart=on-failure ne voit
# qu'une sortie 0), et /run/pulse/native n'existe simplement jamais : pactl rend
# "Connection refused", et Firefox, qui cherche ce socket, enumere ZERO micro.
# Au demarrage manuel la course se joue autrement et la devinette tombe juste -
# d'ou un bug qui ne se reproduit qu'au boot, le seul moment ou personne ne
# regarde.
#
# La devinette disparait si le demon ne se detache pas : en --daemonize=no le
# processus lance EST le demon, son PID n'est plus a deviner. Et pulseaudio 15.x
# de jammy est lie a libsystemd : il appelle sd_notify(READY=1) une fois ses
# modules charges, ce que Type=notify attend. C'est aussi ce que fait l'unite
# fournie par le paquet (/usr/lib/systemd/user/pulseaudio.service), qui le dit
# dans son propre commentaire : "notify will only work if --daemonize=no".
#
# BENEFICE COLLATERAL, et il compte : en Type=notify, ExecStartPost ne part
# qu'apres READY=1. Avant, osmo-pulse-link.sh et osmo-audio-chain.sh couraient
# contre un demon qui n'avait pas fini d'ouvrir son socket.
Type=notify
ExecStart=/usr/bin/pulseaudio --system --daemonize=no --disallow-exit --exit-idle-time=-1 --log-target=journal
ExecStartPre=/bin/mkdir -p /var/log/osmocom /var/run/pulse
# ── LE SOCKET LA OU LES APPLICATIONS LE CHERCHENT ───────────────────────────
# PulseAudio tourne ici en mode SYSTEME : il n'ecoute que sur /run/pulse/native.
# Or une application cherche $XDG_RUNTIME_DIR/pulse/native, et c'est ce
# chemin-la - et lui seul - que snapd monte dans le bac a sable d'un snap.
# Firefox etant un snap (voir osmo-firefox-snap.service), il ne trouverait aucun
# serveur audio, enumerait ZERO entree, et getUserMedia rendait
# « NotFoundError — The object can not be found here ». Le diagnostic partait
# invariablement sur une permission micro refusee, alors que la machine a deux
# entrees bien reelles et que Chrome, non confine, capturait au meme instant.
# Un lien suffit ; il est pose par le demon lui-meme, donc il survit a un
# restart du service.
ExecStartPost=/usr/local/sbin/osmo-pulse-link.sh
# [2026-08-14] Sans ceci, gsm_audio (module-null-sink) n'a AUCUN consommateur :
# la voix descendante y est jetee par construction, la sortie ALSA reste
# SUSPENDED et l'appel est muet. Le loopback est le maillon qui manquait - il
# est pose ici, par le demon lui-meme, donc il survit a un restart du service.
# Non fatal (le script sort 0 quoi qu'il arrive) : l'audio ne doit jamais
# empecher la pile de monter. AUDIO_LOCAL_LOOPBACK=0 le neutralise.
# Passe par un wrapper /usr/local/sbin (meme patron que osmo-sms.sh) : une
# directive `ExecStartPost=/bin/sh -c "... \" ... \" ..."` avec guillemets
# imbriques est ACCEPTEE par `systemctl cat` mais rejetee par le parseur -
# `systemctl show -p ExecStartPost` revient alors VIDE et rien ne s'execute.
ExecStartPost=/usr/local/sbin/osmo-audio-chain.sh 30
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# Idem pour l'audio : le hub ne porte aucun appel, il route de la signalisation.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-pulse 2>/dev/null||true

# Modules noyau
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Variables d'environnement
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# bashrc pour root
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
# Active par defaut l'environnement python (gr-gsm + bridges) utilise par
# /opt/GSM/osmo-operator/start-direct.sh. VIRTUAL_ENV_DISABLE_PROMPT pour garder le PS1.
export VIRTUAL_ENV_DISABLE_PROMPT=1
[ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
# coeur.env est pose dans /etc/osmocom pour survivre au reclone de boot, mais
# environment/load.env ne va le chercher QUE dans son propre repertoire : sorti
# de l'arbre, personne ne le lit. On le charge donc ici, ou les deux arbres en
# heritent - l'arbre fige /opt/GSM/osmo-operator, qui n'embarque pas environment/, et
# l'arbre reclone /opt/GSM/osmo-operator, ou il ne survivrait pas. set -a : sans
# export, la valeur ne franchirait pas le fork vers start-direct.sh. L'idiome
# ":=" du fichier laisse gagner N_MS=3 ./start-direct.sh.
if [ -f /etc/osmocom/coeur.env ]; then set -a; . /etc/osmocom/coeur.env; set +a; fi
# Trois annonces designaient trois arbres differents. Le MOTD et le message de
# login pointent /opt/GSM/osmo-operator (l'arbre fige, present meme sans reseau) ;
# l'alias visait /opt/GSM/osmo-operator (l'arbre reclone au demarrage). Les deux
# fonctionnent, mais un utilisateur qui suit l'un puis l'autre ne travaille pas
# au meme endroit. On prend le premier chemin qui existe, dans l'ordre ou ils
# sont les plus complets.
alias osmo-lab='cd /opt/GSM/osmo-operator; ./start-direct.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/etc/osmocom/status.sh status'
export PATH="$HOME/.local/bin:$PATH"

### calypso-prompt ###
export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️ # '
### end calypso-prompt ###
BASH

# Message du jour - banniere couleur + boite alignee. Contenu de la boite en
# ASCII (pas de ←/e/• multi-octets) + padding printf => bords parfaitement
# alignes. Genere a chaud pour injecter les couleurs ANSI dans /etc/motd.
{
  B=$'\033[1;36m'; T=$'\033[1;37m'; G=$'\033[1;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
  W=58
  printf '\n%b' "$B"
  cat <<'LOGO'
    ___  ___ _ __ ___   ___    ___  __ _ _ __  _ __ ___
   / _ \/ __| '_ ` _ \ / _ \  / _ \/ _` | '_ \| '__/ __|
  | (_) \__ \ | | | | | (_) ||  __/ (_| | |_) | |  \__ \
   \___/|___/_| |_| |_|\___/  \___|\__, | .__/|_|  |___/
                                   |___/|_|
LOGO
  printf '%b' "$N"
  printf "${B}  ╔"; printf '═%.0s' $(seq 1 $W); printf "╗${N}\n"
  printf "${B}  ║${N} ${T}%-*s${N} ${B}║${N}\n" $((W-2)) "GSM / EGPRS  Multi-PLMN  Live System"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "SS7/SIGTRAN  -  Osmocom  -  Calypso/QEMU"
  printf "${B}  ╠"; printf '═%.0s' $(seq 1 $W); printf "╣${N}\n"
  # Le chemin annonce ici est celui de l'arbre FIGE, comme le message de login
  # et comme le lien osmo-start-direct. Il nommait /opt/GSM/osmo-operator, que
  # osmo-update.service effacait et reclonait au demarrage : sans reseau au boot,
  # la premiere chose que lisait l'utilisateur designait un arbre qui pouvait ne
  # pas etre la. Le reclone a disparu, l'arbre fige reste - il ne depend de rien.
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "/opt/GSM/osmo-operator/start-direct.sh"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "    -> lance le lab Calypso/QEMU (A5/1)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "Dashboard web  ->  http://<vm-ip>:8080"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "FFT spectres   ->  http://<vm-ip>:8081"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "Wiki / docs        ->  pl4y.store"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "ssh root@<vm-ip>   -> mot de passe : osmo"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "loadkeys fr   -> changer le clavier (apres boot)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "osmo-update   -> met a jour les depots (git en place)"
  printf "${B}  ╚"; printf '═%.0s' $(seq 1 $W); printf "╝${N}\n\n"
} > "$ROOTFS/etc/motd"

# Mot de passe root = "osmo" (autologin console + login SSH). On NE vide PAS le
# mot de passe (sinon sshd refuse le login root).
echo 'root:osmo' | chroot "$ROOTFS" chpasswd 2>/dev/null || true


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true
