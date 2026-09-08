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
# OSMO_PMOS_DISPLAY (sdl), OSMO_PMOS_MODEM (1 : le modem et la voix sont
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
case "${1:-}" in
    smartphone|telephone|phone) export OSMO_PMOS_RES=720x1440; shift ;;
    tablette|tablet)            export OSMO_PMOS_RES=1280x800; shift ;;
    [0-9]*x[0-9]*)              export OSMO_PMOS_RES="$1"; shift ;;
esac
export OSMO_PMOS_RES="${OSMO_PMOS_RES:-720x1440}"
echo "osmo-pmos-qemu: format ${OSMO_PMOS_RES} ($([ "$OSMO_PMOS_RES" = 1280x800 ] && echo tablette || echo smartphone))"

PMB="$(command -v pmbootstrap || echo "$HOME/.local/bin/pmbootstrap")"
if ! sudo -v; then
    echo "osmo-pmos-qemu: sudo refuse - pmbootstrap ne peut pas preparer l image" >&2
    read -r -p "Entree pour fermer " _
    exit 1
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
GUETTEUR=""
if [ "${OSMO_PMOS_MODEM:-1}" = "1" ] && [ -x "$SETUP" ]; then
    (
        SSH_PORT="${OSMO_PMOS_SSH_PORT:-2222}"
        for _ in $(seq 1 120); do          # 10 min : l image peut etre a refaire
            sleep 5
            sshpass -p "${OSMO_PMOS_PASS:-147147}" ssh -p "$SSH_PORT" -T \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=4 -o PreferredAuthentications=password \
                "${OSMO_PMOS_USER:-user}@127.0.0.1" 'echo ok' 2>/dev/null | grep -q ok || continue
            echo "osmo-pmos-qemu: VM levee, branchement du modem et de la voix ($SETUP)"
            "$SETUP" >"$SETUP_LOG" 2>&1
            grep -E 'modem|ATTENTION|descendant|montant|Modem|DNS' "$SETUP_LOG" \
                | sed 's/^/osmo-pmos-qemu: /'
            echo "osmo-pmos-qemu: trace complete dans $SETUP_LOG"
            exit 0
        done
        echo "osmo-pmos-qemu: la VM n a pas repondu en SSH en 10 min - modem NON branche" \
             "(relancer osmo-pmos-setup a la main)"
    ) &
    GUETTEUR=$!
    echo "osmo-pmos-qemu: le modem du banc sera branche des que la VM repond (OSMO_PMOS_MODEM=0 pour l eviter)"
else
    echo "osmo-pmos-qemu: VM sans modem (OSMO_PMOS_MODEM=0 ou osmo-pmos-setup absent)"
fi
# La VM partie, le guetteur n a plus rien a attendre.
trap '[ -n "$GUETTEUR" ] && kill "$GUETTEUR" 2>/dev/null' EXIT

"$PMB" qemu \
    --memory "${OSMO_PMOS_MEM:-4096}" \
    --display "${OSMO_PMOS_DISPLAY:-sdl}" \
    "$@"
rc=$?
[ "$rc" -eq 0 ] || read -r -p "pmbootstrap a echoue ($rc). Entree pour fermer " _
exit "$rc"
