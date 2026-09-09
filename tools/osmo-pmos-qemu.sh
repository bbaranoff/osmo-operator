#!/bin/bash
# osmo-pmos-qemu - postmarketOS en QEMU, avec le modem du banc et sa voix.
#
# [2026-09-07] ON NE RECONSTRUIT PLUS LA LIGNE DE COMMANDE QEMU. Ce script
# refaisait a la main ce que fait « pmbootstrap qemu », et c est de la que
# venait le bug graphique : la carte et l affichage choisis ici - virtio-vga
# avec SDL force en rendu logiciel - couvraient l ecran de paves de couleur.
# « pmbootstrap qemu » ne les a pas : il prend virtio-vga-gl et « gtk,gl=on ».
# Repasser par le rendu OpenGL de SDL ne servait a rien non plus, le chroot
# musl n a pas les pilotes de la NVIDIA de l hote (« libEGL warning: egl:
# failed to create dri2 screen » en boucle). On appelle donc pmbootstrap.
#
# Ce que pmbootstrap ne savait pas faire est desormais DEDANS, dans
# pmb/commands/qemu.py, fonction osmo_bench_args() :
#   - le modem du banc sur un port serie PCI (ni ISA, ni USB : le firmware
#     UEFI prend les reponses d un port ISA pour des touches et n amorce
#     jamais, et ce noyau n a pas ftdi_sio pour l USB). 8250_pci est integre :
#     le port apparait tout seul en /dev/ttyS1, ce que ModemManager sonde ;
#   - la carte son cablee sur le pont voix du banc plutot que sur les
#     peripheriques par defaut : gsm_audio porte le descendant (le RTP
#     d osmo-mgw), son monitor alimente donc la CAPTURE de la VM ; gsm_mic
#     porte le montant, il recoit donc ce que la VM JOUE.
#
# QEMU ne fait qu ECOUTER sur le port du modem : c est osmo-phonesim-banc.py
# qui vient s y brancher, et seulement une fois le firmware passe - sinon il
# n amorce pas. C est le role d osmo-pmos-setup, a relancer apres chaque
# redemarrage du banc : start-direct.sh tue le modem de la VM au passage.
#
# L affichage reste SDL, mais celui que pmbootstrap monte : virtio-vga-gl et
# « sdl,gl=on ». Ce n est pas SDL qui donnait les paves, c est le virtio-vga
# sans GL pousse dans un rendu logiciel force. OSMO_PMOS_DISPLAY=gtk pour
# passer a GTK, =none pour une VM sans fenetre.
#
# Reglages : OSMO_PMOS_AT_PORT (12346), OSMO_PMOS_SINK (gsm_mic),
# OSMO_PMOS_SOURCE (gsm_audio.monitor), OSMO_PMOS_MEM (4096),
# OSMO_PMOS_DISPLAY (sdl), OSMO_PMOS_DISK (16G), OSMO_PMOS_MODEM (1 : le modem et la voix sont
# branches tout seuls des que la VM repond ; 0 : VM nue).
# [2026-09-07] LE MOT DE PASSE, DEMANDE D ABORD. pmbootstrap a besoin de root
# la ou l ancien script n en avait aucun besoin : il detache les boucles
# (« sudo losetup --json --list »), monte le chroot, y installe OVMF. Lance
# depuis l icone, personne n est la pour repondre a sudo : la commande echoue
# aussitot et il ne se passe RIEN. On demande donc le mot de passe en premier,
# avec un vrai terminal (d ou « Terminal=true » dans osmo-pmos.desktop), et on
# garde la fenetre ouverte si ca casse - sinon l erreur disparait avec elle.
# [2026-09-07] LE FORMAT, AU CHOIX ET AU LANCEMENT. Phosh se met en page
# d apres l ecran : haut et etroit, c est un smartphone ; large, une
# tablette. C est la carte virtio de QEMU qui porte cette taille (xres/yres,
# poses par le patch pmbootstrap depuis OSMO_PMOS_RES), et le systeme demarre
# dedans - on ne change pas de format sous une session ouverte. Le format
# se dit en premier argument (les icones du bureau passent par la variable) :
#   osmo-pmos-qemu smartphone      720x1440   (le defaut)
#   osmo-pmos-qemu tablette        1280x800
#   osmo-pmos-qemu 1024x768        n importe quelle taille <largeur>x<hauteur>
# [2026-09-08] STOP, ET UNE SEULE VM A LA FOIS. Il n y avait pas de moyen
# d arreter le telephone autrement qu en fermant sa fenetre, et relancer
# l icone pendant qu il tourne finissait en « pmbootstrap a echoue (1) » :
# QEMU refuse l image deja ouverte et les ports 2222 / 12346 deja pris, et
# son message part sur la console, pas dans le journal. Donc :
#   osmo-pmos-qemu stop     eteint proprement (poweroff par SSH, 30 s), sinon
#                           SIGTERM puis SIGKILL sur QEMU ; debranche le modem
#                           du banc (osmo-phonesim-banc.py --connect), que
#                           osmo-pmos-setup rebranche au prochain demarrage.
#   osmo-pmos-qemu status   dit si la VM tourne (pid) et si son SSH repond.
# Et au lancement, si une VM tourne deja, on le dit et on s arrete la.
PMOS_SSH_PORT="${OSMO_PMOS_SSH_PORT:-2222}"
PMOS_SSH="sshpass -p ${OSMO_PMOS_PASS:-147147} ssh -p $PMOS_SSH_PORT -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o PreferredAuthentications=password ${OSMO_PMOS_USER:-user}@127.0.0.1"
# Le vrai QEMU (pas le « sh -c » qui l enveloppe) : celui qui tient l image.
pmos_qemu_pids() {
    pgrep -f '^[^ ]*ld-musl[^ ]* .*qemu-system-x86_64 .*rootfs/qemu-amd64\.img' 2>/dev/null
    pgrep -f '^[^ ]*qemu-system-x86_64 .*rootfs/qemu-amd64\.img' 2>/dev/null
}
pmos_ssh_ok() { $PMOS_SSH 'echo ok' 2>/dev/null | grep -q ok; }
pmos_status() {
    local pids; pids="$(pmos_qemu_pids | sort -u | tr '\n' ' ')"
    if [ -z "$pids" ]; then echo "osmo-pmos-qemu: aucune VM postmarketOS ne tourne"; return 1; fi
    echo "osmo-pmos-qemu: VM postmarketOS en marche (QEMU pid $pids)"
    pmos_ssh_ok && echo "osmo-pmos-qemu: SSH repond sur le port $PMOS_SSH_PORT" \
                || echo "osmo-pmos-qemu: SSH ne repond pas encore (port $PMOS_SSH_PORT)"
    pgrep -f '[o]smo-phonesim-banc.py --connect' >/dev/null && echo "osmo-pmos-qemu: modem du banc branche" \
                                                             || echo "osmo-pmos-qemu: modem du banc NON branche"
    return 0
}
pmos_stop() {
    local pids i
    pids="$(pmos_qemu_pids | sort -u | tr '\n' ' ')"
    if [ -z "$pids" ]; then
        echo "osmo-pmos-qemu: aucune VM postmarketOS a arreter"
    else
        if pmos_ssh_ok; then
            echo "osmo-pmos-qemu: extinction propre par SSH (poweroff)..."
            $PMOS_SSH "echo ${OSMO_PMOS_PASS:-147147} | sudo -S poweroff" >/dev/null 2>&1
            for i in $(seq 1 30); do
                sleep 1
                [ -z "$(pmos_qemu_pids)" ] && break
            done
        fi
        if [ -n "$(pmos_qemu_pids)" ]; then
            echo "osmo-pmos-qemu: QEMU encore la, SIGTERM (pid $pids)"
            # shellcheck disable=SC2086
            kill -TERM $pids 2>/dev/null
            for i in $(seq 1 5); do sleep 1; [ -z "$(pmos_qemu_pids)" ] && break; done
        fi
        if [ -n "$(pmos_qemu_pids)" ]; then
            echo "osmo-pmos-qemu: QEMU ne meurt pas, SIGKILL"
            # shellcheck disable=SC2086
            kill -KILL $(pmos_qemu_pids) 2>/dev/null
            sleep 1
        fi
        [ -z "$(pmos_qemu_pids)" ] && echo "osmo-pmos-qemu: VM arretee" \
                                   || { echo "osmo-pmos-qemu: la VM tourne toujours (droits ? relancer en root)"; return 1; }
    fi
    # Le modem du banc etait branche sur le port serie de CETTE VM : on le
    # debranche, osmo-pmos-setup le rebranchera au prochain demarrage.
    # Le banc tourne en root depuis osmo-pmos-setup (le tun PPP l exige) :
    # sous le compte de session, pkill ne peut pas, sudo -n si le mot de
    # passe est encore en cache.
    if pkill -f '[o]smo-phonesim-banc.py --connect' 2>/dev/null \
       || sudo -n pkill -f '[o]smo-phonesim-banc.py --connect' 2>/dev/null; then
        echo "osmo-pmos-qemu: modem du banc debranche"
    fi
    # Un « pmbootstrap qemu » orphelin (VM tuee sous lui) ne sert plus a rien.
    # Motif ancre sur l interpreteur : un « pkill -f » large tuerait aussi le
    # terminal de quiconque a ces mots dans sa ligne de commande.
    pkill -f '^[^ ]*python[0-9.]* [^ ]*pmbootstrap qemu' 2>/dev/null || true
    return 0
}
# Depuis une icone (Terminal=true), la fenetre se fermerait avant qu on ait
# lu : on la garde quelques secondes quand on est sur un vrai terminal.
pmos_fin() { local rc=$1; [ -t 0 ] && read -r -t 8 -p "Entree pour fermer (8 s) " _; exit "$rc"; }
# [2026-09-08] BASCULE : un seul geste sur l icone. VM en marche -> on l eteint
# (pmos_stop) ; VM arretee -> on la lance, exactement comme sans argument.
# C est ce que fait l icone (osmo-pmos toggle -> ici) : plus besoin du clic
# droit, peu visible sous Phosh, pour arreter le telephone.
case "${1:-}" in
    stop|arret|arreter|off|down) pmos_stop; pmos_fin $? ;;
    status|etat)                 pmos_status; pmos_fin $? ;;
    toggle|bascule)
        if [ -n "$(pmos_qemu_pids)" ]; then
            echo "osmo-pmos-qemu: le telephone tourne - on l eteint"
            pmos_stop; pmos_fin $?
        fi
        echo "osmo-pmos-qemu: le telephone est arrete - on le lance"
        shift ;;
esac

case "${1:-}" in
    smartphone|telephone|phone) export OSMO_PMOS_RES=720x1440; shift ;;
    tablette|tablet)            export OSMO_PMOS_RES=1280x800; shift ;;
    [0-9]*x[0-9]*)              export OSMO_PMOS_RES="$1"; shift ;;
esac
export OSMO_PMOS_RES="${OSMO_PMOS_RES:-720x1440}"
echo "osmo-pmos-qemu: format ${OSMO_PMOS_RES} ($([ "$OSMO_PMOS_RES" = 1280x800 ] && echo tablette || echo smartphone))"
if [ -n "$(pmos_qemu_pids)" ]; then
    pmos_status
    echo "osmo-pmos-qemu: une seule VM a la fois - « osmo-pmos-qemu stop » pour l arreter, puis relancer"
    read -r -p "Entree pour fermer " _
    exit 1
fi

PMB="$(command -v pmbootstrap || echo "$HOME/.local/bin/pmbootstrap")"
if ! sudo -v; then
    echo "osmo-pmos-qemu: sudo refuse - pmbootstrap ne peut pas preparer l image" >&2
    read -r -p "Entree pour fermer " _
    exit 1
fi
# [2026-09-09] EN ROOT AUSSI. La session de l ISO s ouvre sur root (gdm3,
# iso_modules/84-comptes.sh) : l icone lancait « pmbootstrap qemu » en root,
# qui repond « Do not run pmbootstrap as root! » et s arrete - l ISO avait le
# telephone (pmbootstrap patche, noyau PPP, image de reference) et ne pouvait
# pas l allumer. pmbootstrap accepte --as-root : on le passe quand on est
# root, et le dossier de travail est alors celui de root.
PMB_OPTS=(); [ "$(id -u)" -eq 0 ] && PMB_OPTS=(--as-root)
# [2026-09-09] LE DOSSIER DE TRAVAIL EST CELUI DE LA CONFIG, plus ~/test en
# dur (celui de la machine de reference) : sur l ISO c est
# ~/.local/var/pmbootstrap (gabarit pose par 88-lte-pmos.sh dans /root et
# /home/osmocom, instancie par osmo-pmos-build). ~/test reste accepte.
PMB_WORK="${OSMO_PMB_WORK:-$(sed -n 's/^work *= *//p' "$HOME/.config/pmbootstrap_v3.cfg" 2>/dev/null | head -1)}"
[ -n "$PMB_WORK" ] || PMB_WORK="$HOME/.local/var/pmbootstrap"
[ -d "$PMB_WORK/chroot_native" ] || [ ! -d "$HOME/test/chroot_native" ] || PMB_WORK="$HOME/test"
IMG_PMB="$(ls -1 "$PMB_WORK"/chroot_native/home/pmos/rootfs/*.img 2>/dev/null | head -1)"
# [2026-09-09] PAS D IMAGE : ON LA FABRIQUE, ICI. Le premier clic sur l icone
# de l ISO tombait sur « pmbootstrap qemu » sans config, sans dossier de
# travail, avec l image de reference encore en .zst dans /opt/user_interface/
# pmos/image : echec, fenetre fermee. osmo-pmos-build fait tout cela (config
# depuis le gabarit, pmaports, noyau PPP, image decompressee) puis REVIENT ici
# (exec osmo-pmos-qemu, OSMO_PMOS_FROM_BUILD=1 pour ne pas boucler).
if [ -z "$IMG_PMB" ] && [ "${OSMO_PMOS_FROM_BUILD:-0}" != 1 ]; then
    BUILD="$(command -v osmo-pmos-build 2>/dev/null || echo /opt/user_interface/pmos/bin/osmo-pmos-build.sh)"
    if [ -x "$BUILD" ]; then
        echo "osmo-pmos-qemu: pas d image postmarketOS dans $PMB_WORK - premiere fois : osmo-pmos-build (long, reseau)"
        exec "$BUILD" "$([ "$OSMO_PMOS_RES" = 1280x800 ] && echo tablette || echo smartphone)"
    fi
    echo "osmo-pmos-qemu: pas d image postmarketOS dans $PMB_WORK, et pas d osmo-pmos-build : « pmbootstrap install » a la main" >&2
fi

# [2026-09-08] LE MODEM, PAR DEFAUT. Le telephone sans modem n est qu une VM :
# pas d appel, pas de SMS, pas de data - et le noyau a ete rebati EXPRES pour
# porter PPP sur ce modem (voir osmo-pmos-setup). On ne demande donc plus a
# l utilisateur de penser a « Brancher le modem et la voix » apres coup : un
# guetteur attend que le SSH de la VM reponde (donc que le firmware soit
# passe, cf. l entete : brancher plus tot bloque l amorcage) et lance
# osmo-pmos-setup - le modem du banc sur le port serie, puis la voix. Sa
# trace complete va dans un fichier ; seules les lignes utiles remontent
# ici, prefixees, au milieu de la console serie de la VM.
# OSMO_PMOS_MODEM=0 pour une VM nue (l ancien comportement).
SETUP="${OSMO_PMOS_SETUP:-/usr/local/bin/osmo-pmos-setup}"
[ -x "$SETUP" ] || SETUP="${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-pmos-setup.sh"
SETUP_LOG="${XDG_RUNTIME_DIR:-/tmp}/osmo-pmos-setup.log"
# [2026-09-08] LA PLACE, VERIFIEE A CHAQUE LANCEMENT. Le guetteur tourne
# toujours (modem ou pas) : une fois la VM levee il regarde si la racine
# occupe bien tout le disque. Normalement l initramfs pmOS l a deja fait au
# boot (pmos.force-partition-resize sur la ligne du noyau) ; sinon - image
# refaite sans ce parametre - il etend lui-meme la partition 2 puis l ext4,
# a chaud, par SSH. Puis le modem si OSMO_PMOS_MODEM=1.
pmos_place() {
    # Le script cote VM voyage en base64 : trois niveaux de guillemets sinon.
    local b64; b64="$(base64 -w0 <<'PLACE'
set -e
d=$(blockdev --getsize64 /dev/vda); p=$(blockdev --getsize64 /dev/vda2)
s=$(sfdisk -d /dev/vda 2>/dev/null | sed -n 's/^.*vda2 : start= *\([0-9]*\).*/\1/p')
# de la place derriere la partition 2 (> 64 Mio) ? on l etend, a chaud
if [ $((d - s*512 - p)) -gt 67108864 ]; then
    echo "partition 2 : $((p/1048576)) Mio sur un disque de $((d/1048576)) Mio - extension"
    parted -f -s /dev/vda resizepart 2 100% >/dev/null 2>&1 \
        || echo ", +" | sfdisk --no-reread -N2 /dev/vda >/dev/null 2>&1 || true
    partprobe /dev/vda 2>/dev/null || true
fi
resize2fs /dev/vda2 2>&1 | grep -v '^resize2fs [0-9]' || true
df -h / | tail -1 | awk '{print "place : racine " $2 ", libre " $4 " (" $5 " pris)"}'
PLACE
)"
    $PMOS_SSH "echo ${OSMO_PMOS_PASS:-147147} | sudo -S sh -c \"\$(echo $b64 | base64 -d)\"" 2>/dev/null
}
GUETTEUR=""
(
    for _ in $(seq 1 120); do          # 10 min : l image peut etre a refaire
        sleep 5
        pmos_ssh_ok || continue
        echo "osmo-pmos-qemu: VM levee - verification de la place sur le disque"
        pmos_place | sed 's/^/osmo-pmos-qemu: /'
        if [ "${OSMO_PMOS_MODEM:-1}" = "1" ] && [ -x "$SETUP" ]; then
            echo "osmo-pmos-qemu: branchement du modem et de la voix ($SETUP)"
            "$SETUP" >"$SETUP_LOG" 2>&1
            grep -E 'modem|ATTENTION|descendant|montant|Modem|DNS' "$SETUP_LOG" \
                | sed 's/^/osmo-pmos-qemu: /'
            echo "osmo-pmos-qemu: trace complete dans $SETUP_LOG"
        elif [ -x "$SETUP" ]; then
            # [2026-09-09] SANS MODEM, LE SON QUAND MEME. La VM nue sortait
            # son audio sur la carte PONT (0x12 -> gsm_mic) : muette pour
            # l operateur. --voix ne fait que la partie son (combine par
            # defaut, bouclages, sourdines).
            echo "osmo-pmos-qemu: VM sans modem - le son seul ($SETUP --voix)"
            "$SETUP" --voix >"$SETUP_LOG" 2>&1
            grep -E 'ATTENTION|descendant|montant|sourdines' "$SETUP_LOG" | sed 's/^/osmo-pmos-qemu: /'
        fi
        exit 0
    done
    echo "osmo-pmos-qemu: la VM n a pas repondu en SSH en 10 min - place non verifiee, modem NON branche" \
         "(relancer osmo-pmos-setup a la main)"
) &
GUETTEUR=$!
if [ "${OSMO_PMOS_MODEM:-1}" = "1" ] && [ -x "$SETUP" ]; then
    echo "osmo-pmos-qemu: le modem du banc sera branche des que la VM repond (OSMO_PMOS_MODEM=0 pour l eviter)"
else
    echo "osmo-pmos-qemu: VM sans modem (OSMO_PMOS_MODEM=0 ou osmo-pmos-setup absent)"
fi
# La VM partie, le guetteur n a plus rien a attendre.
trap '[ -n "$GUETTEUR" ] && kill "$GUETTEUR" 2>/dev/null' EXIT

# [2026-09-08] LE DISQUE : 16 Go, pas 2. L image pmbootstrap fait 2 Go par
# defaut et etait PLEINE (2,2 Go a 100 %) apres apk add/upgrade : plus rien
# n ecrivait, ni dconf, ni NetworkManager, ni le journal. Un premier correctif
# a 4 Go n avait jamais ete deploye (le lanceur de /usr/local/bin datait
# d avant) : la VM tournait toujours sur 2,8 Go pleins. --image-size est
# passe A CHAQUE LANCEMENT : pmbootstrap ne fait qu un truncate (fichier
# creux, ne coute que ce qui est ecrit ; il refuse seulement de RETRECIR,
# d ou le calcul ci-dessous qui garde la taille courante si elle est plus
# grande), l initramfs pmOS etend la partition et l ext4 au demarrage, et le
# guetteur ci-dessus verifie le resultat. OSMO_PMOS_DISK pour une autre taille.
DISK="${OSMO_PMOS_DISK:-16G}"
# IMG_PMB : resolu plus haut, depuis le dossier de travail de la config.
if [ -n "$IMG_PMB" ]; then
    cur_m=$(( ($(stat -c %s "$IMG_PMB") + 1048575) / 1048576 ))
    case "$DISK" in *G) want_m=$(( ${DISK%G} * 1024 )) ;; *M) want_m=${DISK%M} ;; *) want_m=$cur_m ;; esac
    [ "$want_m" -lt "$cur_m" ] && DISK="${cur_m}M"
    echo "osmo-pmos-qemu: disque de la VM $DISK ($IMG_PMB, ${cur_m} Mio avant)"
fi
# [2026-09-08] ROBUSTE AUX HOTES RECALCITRANTS (AMD en tete). Le patch
# pmbootstrap coupe deja l OpenGL sur un GPU AMD et le KVM sans SVM ; mais
# une VM qui MEURT AUSSITOT (moins de 25 s, code non nul) sur un hote qu on
# n avait pas prevu, on ne la laisse pas mourir : on relance sans OpenGL,
# puis sans KVM, puis en fenetre GTK (SDL + Wayland pur). Chaque essai est
# annonce ; le dernier code d erreur est celui qu on garde. Une VM qui a
# tourne plus de 25 s puis s est arretee n est pas relancee : c est un arret.
_lance() {
    "$PMB" "${PMB_OPTS[@]}" qemu \
        --memory "${OSMO_PMOS_MEM:-4096}" \
        --image-size "$DISK" \
        --display "${OSMO_PMOS_DISPLAY:-sdl}" \
        "$@"
}
_mort_tot() { [ "$1" -ne 0 ] && [ $(( $(date +%s) - t0 )) -lt 25 ]; }
t0=$(date +%s); _lance "$@"; rc=$?
if _mort_tot "$rc" && [ "${OSMO_PMOS_GL:-}" != 0 ]; then
    echo "osmo-pmos-qemu: QEMU est mort aussitot ($rc) - relance SANS OpenGL (OSMO_PMOS_GL=0)"
    export OSMO_PMOS_GL=0; t0=$(date +%s); _lance "$@"; rc=$?
fi
if _mort_tot "$rc" && [ "${OSMO_PMOS_KVM:-}" != 0 ]; then
    echo "osmo-pmos-qemu: encore mort ($rc) - relance SANS KVM (OSMO_PMOS_KVM=0, emulation : lent mais il demarre)"
    export OSMO_PMOS_KVM=0; t0=$(date +%s); _lance "$@"; rc=$?
fi
if _mort_tot "$rc" && [ "${OSMO_PMOS_DISPLAY:-sdl}" = sdl ]; then
    echo "osmo-pmos-qemu: encore mort ($rc) - relance en fenetre GTK (OSMO_PMOS_DISPLAY=gtk)"
    export OSMO_PMOS_DISPLAY=gtk; t0=$(date +%s); _lance "$@"; rc=$?
fi
[ "$rc" -eq 0 ] || read -r -p "pmbootstrap a echoue ($rc). Entree pour fermer " _
exit "$rc"
