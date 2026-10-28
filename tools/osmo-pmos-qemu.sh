#!/bin/bash
# osmo-pmos-qemu - postmarketOS in QEMU, with the bench modem and its voice.
#
# The QEMU command line is NOT rebuilt here: "pmbootstrap qemu" is called,
# with virtio-vga-gl and "gl=on" (a virtio-vga forced into software rendering
# covers the screen with colour blocks).
#
# What pmbootstrap does for the bench lives INSIDE it, in
# pmb/commands/qemu.py, function osmo_bench_args():
#   - the bench modem on a PCI serial port (neither ISA nor USB: the UEFI
#     firmware takes the answers of an ISA port for keystrokes and never
#     boots, and this kernel has no ftdi_sio for USB). 8250_pci is built in:
#     the port appears on its own as /dev/ttyS1, which ModemManager probes;
#   - the sound card wired to the bench voice bridge rather than to the
#     default devices: gsm_audio carries the downlink (the osmo-mgw RTP), so
#     its monitor feeds the VM CAPTURE; gsm_mic carries the uplink, so it
#     receives what the VM PLAYS.
#
# QEMU only LISTENS on the modem port: osmo-phonesim-banc.py connects to it,
# and only once the firmware has passed - otherwise it does not boot. That
# is the role of osmo-pmos-setup, to rerun after each bench restart:
# start-native.sh kills the VM modem on the way.
#
# The display stays SDL, the one pmbootstrap sets up: virtio-vga-gl and
# "sdl,gl=on". OSMO_PMOS_DISPLAY=gtk switches to GTK, =none for a VM without
# a window.
#
# Settings: OSMO_PMOS_AT_PORT (12346), OSMO_PMOS_SINK (gsm_mic),
# OSMO_PMOS_SOURCE (gsm_audio.monitor), OSMO_PMOS_MEM (4096),
# OSMO_PMOS_DISPLAY (sdl), OSMO_PMOS_DISK (16G), OSMO_PMOS_MODEM (1: the
# modem and the voice are connected on their own as soon as the VM answers;
# 0: bare VM).
# THE PASSWORD, ASKED FIRST. pmbootstrap needs root: it detaches the loops
# ("sudo losetup --json --list"), mounts the chroot, installs OVMF in it.
# Launched from the icon, nobody is there to answer sudo. So the password is
# asked first, with a real terminal (hence "Terminal=true" in
# osmo-pmos.desktop), and the window is kept open on failure - otherwise the
# error vanishes with it.
# THE FORMAT, CHOSEN AT LAUNCH. Phosh lays itself out according to the
# screen: tall and narrow is a smartphone; wide, a tablet. The QEMU virtio
# card carries this size (xres/yres, set by the pmbootstrap patch from
# OSMO_PMOS_RES), and the system boots in it - the format does not change
# under an open session. The format is the first argument (the desktop icons
# go through the variable):
#   osmo-pmos-qemu smartphone      720x1440   (the default)
#   osmo-pmos-qemu tablette        1280x800
#   osmo-pmos-qemu 1024x768        any <width>x<height> size
# STOP, AND ONE VM AT A TIME. QEMU refuses an image already open and the
# ports 2222 / 12346 already in use, and its message goes to the console,
# not the log. So:
#   osmo-pmos-qemu stop     clean shutdown (poweroff over SSH, 30 s),
#                           otherwise SIGTERM then SIGKILL on QEMU;
#                           disconnects the bench modem
#                           (osmo-phonesim-banc.py --connect), which
#                           osmo-pmos-setup reconnects at the next start.
#   osmo-pmos-qemu status   says whether the VM runs (pid) and whether its
#                           SSH answers.
# And at launch, if a VM already runs, say so and stop there.
PMOS_SSH_PORT="${OSMO_PMOS_SSH_PORT:-2222}"
PMOS_SSH="sshpass -p ${OSMO_PMOS_PASS:-147147} ssh -p $PMOS_SSH_PORT -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=4 -o PreferredAuthentications=password ${OSMO_PMOS_USER:-user}@127.0.0.1"
# lib/audio.sh: the assignment of the speakers and microphone (a single
# source of truth, see "L AFFECTATION DES HAUT-PARLEURS" there).
# Here: the echo canceller is loaded BEFORE QEMU, so that the VM "combine"
# card is born directly on it (OSMO_PMOS_HP / OSMO_PMOS_MIC, read by the
# pmbootstrap patch); the host direct loopbacks are removed when the VM
# starts (if the voice goes through it) and RESTORED when it stops.
AUDIO_LIB="${OSMO_REPO:-/opt/GSM/osmo-operator}/lib/audio.sh"
if [ -f "$AUDIO_LIB" ]; then
    # shellcheck source=../lib/audio.sh
    . "$AUDIO_LIB"
else
    AUDIO_LIB=""
fi
# The real QEMU (not the "sh -c" wrapping it): the one holding the image.
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
            $PMOS_SSH "echo ${OSMO_PMOS_PASS:-147147} | sudo -S -p '' poweroff" >/dev/null 2>&1
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
    # The bench modem was connected to the serial port of THIS VM:
    # disconnect it, osmo-pmos-setup reconnects it at the next start.
    # The bench runs as root since osmo-pmos-setup (the PPP tun requires
    # it): under the session account pkill cannot, sudo -n can if the
    # password is still cached.
    if pkill -f '[o]smo-phonesim-banc.py --connect' 2>/dev/null \
       || sudo -n pkill -f '[o]smo-phonesim-banc.py --connect' 2>/dev/null; then
        echo "osmo-pmos-qemu: modem du banc debranche"
    fi
    # An orphan "pmbootstrap qemu" (VM killed under it) is useless.
    # Pattern anchored on the interpreter: a broad "pkill -f" would also
    # kill the terminal of anyone with these words in their command line.
    pkill -f '^[^ ]*python[0-9.]* [^ ]*pmbootstrap qemu' 2>/dev/null || true
    # VM gone: the host resumes its direct listening (gsm_audio -> speakers).
    [ -n "$AUDIO_LIB" ] && { ensure_local_loopback; ensure_local_mic; }
    return 0
}
# From an icon (Terminal=true), the window would close before one can read:
# keep it a few seconds when on a real terminal.
pmos_fin() { local rc=$1; [ -t 0 ] && read -r -t 8 -p "Entree pour fermer (8 s) " _; exit "$rc"; }
# TOGGLE: a single action on the icon. VM running -> power it off
# (pmos_stop); VM stopped -> launch it, exactly as without argument. This is
# what the icon does (osmo-pmos toggle -> here).
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
# AS ROOT TOO. The ISO session opens as root (gdm3,
# iso_modules/84-comptes.sh), and pmbootstrap refuses to run as root unless
# --as-root is passed: it is passed when root, and the work directory is
# then root's.
PMB_OPTS=(); [ "$(id -u)" -eq 0 ] && PMB_OPTS=(--as-root)
# THE PHONE DATA REALLY GETS OUT, AT EVERY LAUNCH. docker sets the FORWARD
# policy to DROP on the host, which would silently drop the UE packets
# (ogstun, after NAT). osmo-epc.sh (setup_forward) sets the rule when the 4G
# core starts; it is set again here, before the VM, in case the core started
# before this script or docker recreated its chains in between. DOCKER-USER:
# consulted before the docker rules, never rewritten by it.
pmos_forward() {
    local su=(); [ "$(id -u)" -eq 0 ] || su=(sudo -n)
    "${su[@]}" iptables -N DOCKER-USER 2>/dev/null || true
    local spec
    for spec in "-i ogstun" "-o ogstun"; do
        # shellcheck disable=SC2086
        "${su[@]}" iptables -C DOCKER-USER $spec -j ACCEPT 2>/dev/null \
            || "${su[@]}" iptables -I DOCKER-USER 1 $spec -j ACCEPT 2>/dev/null \
            || { echo "osmo-pmos-qemu: FORWARD ($spec) refuse - la data du telephone s arretera a l hote" >&2; return 0; }
    done
    "${su[@]}" iptables -C FORWARD -j DOCKER-USER 2>/dev/null \
        || "${su[@]}" iptables -I FORWARD 1 -j DOCKER-USER 2>/dev/null || true
    echo "osmo-pmos-qemu: FORWARD ogstun autorise (DOCKER-USER) - la data du telephone sort vers Internet"
}
pmos_forward
# THE WORK DIRECTORY IS THE CONFIG'S: on the ISO it is
# ~/.local/var/pmbootstrap (template installed by 88-lte-pmos.sh in /root and
# /home/osmocom, instantiated by osmo-pmos-build). ~/test is still accepted.
PMB_WORK="${OSMO_PMB_WORK:-$(sed -n 's/^work *= *//p' "$HOME/.config/pmbootstrap_v3.cfg" 2>/dev/null | head -1)}"
[ -n "$PMB_WORK" ] || PMB_WORK="$HOME/.local/var/pmbootstrap"
[ -d "$PMB_WORK/chroot_native" ] || [ ! -d "$HOME/test/chroot_native" ] || PMB_WORK="$HOME/test"
IMG_PMB="$(ls -1 "$PMB_WORK"/chroot_native/home/pmos/rootfs/*.img 2>/dev/null | head -1)"
# NO IMAGE: BUILD IT, HERE. On the first click on the ISO icon there is no
# config, no work directory, and the reference image is still a .zst in
# /opt/user_interface/pmos/image. osmo-pmos-build does all of that (config
# from the template, pmaports, PPP kernel, decompressed image) then COMES
# BACK here (exec osmo-pmos-qemu, OSMO_PMOS_FROM_BUILD=1 to avoid looping).
if [ -z "$IMG_PMB" ] && [ "${OSMO_PMOS_FROM_BUILD:-0}" != 1 ]; then
    BUILD="$(command -v osmo-pmos-build 2>/dev/null || echo /opt/user_interface/pmos/bin/osmo-pmos-build.sh)"
    if [ -x "$BUILD" ]; then
        echo "osmo-pmos-qemu: pas d image postmarketOS dans $PMB_WORK - premiere fois : osmo-pmos-build (long, reseau)"
        exec "$BUILD" "$([ "$OSMO_PMOS_RES" = 1280x800 ] && echo tablette || echo smartphone)"
    fi
    echo "osmo-pmos-qemu: pas d image postmarketOS dans $PMB_WORK, et pas d osmo-pmos-build : « pmbootstrap install » a la main" >&2
fi

# THE MODEM, BY DEFAULT. The phone without a modem is only a VM: no call,
# no SMS, no data. A watcher waits for the VM SSH to answer (so that the
# firmware has passed, see the header: connecting earlier blocks the boot)
# and runs osmo-pmos-setup - the bench modem on the serial port, then the
# voice. Its full trace goes to a file; only the useful lines come back
# here, prefixed, in the middle of the VM serial console.
# OSMO_PMOS_MODEM=0 for a bare VM.
SETUP="${OSMO_PMOS_SETUP:-/usr/local/bin/osmo-pmos-setup}"
[ -x "$SETUP" ] || SETUP="${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-pmos-setup.sh"
SETUP_LOG="${XDG_RUNTIME_DIR:-/tmp}/osmo-pmos-setup.log"
# DISK SPACE, CHECKED AT EVERY LAUNCH. The watcher always runs (modem or
# not): once the VM is up it checks that the root fills the whole disk.
# Normally the pmOS initramfs already did it at boot
# (pmos.force-partition-resize on the kernel line); otherwise - image
# rebuilt without that parameter - it extends partition 2 then the ext4
# itself, online, over SSH. Then the modem if OSMO_PMOS_MODEM=1.
pmos_place() {
    # The VM-side script travels in base64: three levels of quoting otherwise.
    local b64; b64="$(base64 -w0 <<'PLACE'
set -e
d=$(blockdev --getsize64 /dev/vda); p=$(blockdev --getsize64 /dev/vda2)
s=$(sfdisk -d /dev/vda 2>/dev/null | sed -n 's/^.*vda2 : start= *\([0-9]*\).*/\1/p')
# room behind partition 2 (> 64 MiB)? extend it, online
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
    $PMOS_SSH "echo ${OSMO_PMOS_PASS:-147147} | sudo -S -p '' sh -c \"\$(echo $b64 | base64 -d)\"" 2>/dev/null
}
GUETTEUR=""
(
    for _ in $(seq 1 120); do          # 10 min: the image may need rebuilding
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
            # WITHOUT A MODEM, THE SOUND ANYWAY. A bare VM would output its
            # audio on the BRIDGE card (0x12 -> gsm_mic): mute for the
            # operator. --voix only does the sound part (handset by default,
            # loopbacks, mutes).
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
# VM gone: the watcher has nothing left to wait for.
trap '[ -n "$GUETTEUR" ] && kill "$GUETTEUR" 2>/dev/null' EXIT

# THE DISK: 16 GB, not 2. The pmbootstrap image is 2 GB by default and fills
# up after apk add/upgrade. --image-size is passed AT EVERY LAUNCH:
# pmbootstrap only does a truncate (sparse file, costs only what is written;
# it only refuses to SHRINK, hence the computation below which keeps the
# current size if larger), the pmOS initramfs extends the partition and the
# ext4 at boot, and the watcher above checks the result. OSMO_PMOS_DISK for
# another size.
DISK="${OSMO_PMOS_DISK:-16G}"
# IMG_PMB: resolved above, from the config's work directory.
if [ -n "$IMG_PMB" ]; then
    cur_m=$(( ($(stat -c %s "$IMG_PMB") + 1048575) / 1048576 ))
    case "$DISK" in *G) want_m=$(( ${DISK%G} * 1024 )) ;; *M) want_m=${DISK%M} ;; *) want_m=$cur_m ;; esac
    [ "$want_m" -lt "$cur_m" ] && DISK="${cur_m}M"
    echo "osmo-pmos-qemu: disque de la VM $DISK ($IMG_PMB, ${cur_m} Mio avant)"
fi
# ROBUST TO RELUCTANT HOSTS (AMD first). The pmbootstrap patch already
# disables OpenGL on an AMD GPU and KVM without SVM; a VM that DIES AT ONCE
# (less than 25 s, non-zero code) is relaunched with fallbacks (see below).
# Each attempt is announced; the last error code is the one kept. A VM that
# ran more than 25 s then stopped is not relaunched: that is a shutdown.
# THE VM SPEAKERS, NAMED BEFORE IT STARTS. The "combine" card
# (osmo_bench_args) takes the host default devices when QEMU connects. The
# echo canceller is loaded HERE, the direct loopbacks are handled (removed
# if the voice goes through the VM), and the names are given to the
# pmbootstrap patch: the card is born in the right place.
if [ -n "$AUDIO_LIB" ] && [ "${OSMO_PMOS_RELAI:-1}" = "1" ]; then
    ensure_echo_cancel 2>/dev/null | sed 's/^ *//; s/^/osmo-pmos-qemu: /'
    # THE HOST LISTENING IS KEPT AT LAUNCH. The voice does not go through
    # the VM by default (see lib/audio.sh, "QUI PORTE LA VOIX"): the direct
    # loopbacks ARE the path, and removing them here would mute the bench
    # during the whole phone boot.
    # OSMO_PMOS_VOIX_VM=1: osmo-pmos-setup then writes the marker and removes
    # these loopbacks, once the VM is ready to replace them.
    if [ "${OSMO_PMOS_VOIX_VM:-0}" = "1" ]; then
        remove_direct_loopbacks 2>/dev/null | sed 's/^ *//; s/^/osmo-pmos-qemu: /'
    else
        { ensure_local_loopback; ensure_local_mic; } 2>/dev/null | sed 's/^ *//; s/^/osmo-pmos-qemu: /'
    fi
    _hp="$(audio_hp_sink)"; _mic="$(audio_mic_source)"
    [ -n "$_hp" ]  && export OSMO_PMOS_HP="${OSMO_PMOS_HP:-$_hp}"
    [ -n "$_mic" ] && export OSMO_PMOS_MIC="${OSMO_PMOS_MIC:-$_mic}"
    echo "osmo-pmos-qemu: carte « combine » de la VM -> HP ${OSMO_PMOS_HP:-defaut}, micro ${OSMO_PMOS_MIC:-defaut}"
fi
# THE HOST QEMU, NOT THE CHROOT'S. The pmbootstrap QEMU runs in a musl
# chroot without the machine's NVIDIA drivers: even with virtio-vga-gl and
# gl=on, its EGL fails and the rendering falls back to software - broken
# display. The host's (Ubuntu, glibc) loads libEGL_nvidia. It needs
# qemu-system-gui and qemu-system-modules-opengl (ui-sdl, ui-opengl,
# virtio-vga-gl). OSMO_PMOS_HOST_QEMU=0 goes back to the chroot QEMU.
QEMU_MODDIR=/usr/lib/x86_64-linux-gnu/qemu
if [ -z "${OSMO_PMOS_HOST_QEMU:-}" ]; then
    if [ -e "$QEMU_MODDIR/ui-opengl.so" ] && [ -e "$QEMU_MODDIR/ui-sdl.so" ] && [ -e "$QEMU_MODDIR/hw-display-virtio-vga-gl.so" ]; then
        OSMO_PMOS_HOST_QEMU=1
    else
        OSMO_PMOS_HOST_QEMU=0
        echo "osmo-pmos-qemu: QEMU de l hote sans modules OpenGL (apt install qemu-system-gui qemu-system-modules-opengl) - QEMU du chroot"
    fi
fi
HOST_QEMU_OPT=(); [ "$OSMO_PMOS_HOST_QEMU" = 1 ] && HOST_QEMU_OPT=(--host-qemu)
_lance() {
    "$PMB" "${PMB_OPTS[@]}" qemu \
        "${HOST_QEMU_OPT[@]}" \
        --memory "${OSMO_PMOS_MEM:-4096}" \
        --image-size "$DISK" \
        --display "${OSMO_PMOS_DISPLAY:-sdl}" \
        "$@"
}
_mort_tot() { [ "$1" -ne 0 ] && [ $(( $(date +%s) - t0 )) -lt 25 ]; }
# OPENGL FIRST, ALL THE WAY. Software rendering (virtio-vga without GL) is
# exactly the colour-block display, so the fallbacks try the chroot QEMU,
# then GTK, then without KVM, ALWAYS with OpenGL; software rendering only
# comes last, and says so. OSMO_PMOS_GL=1 is set by default (NVIDIA host:
# pmbootstrap would otherwise disable it in some cases).
export OSMO_PMOS_GL="${OSMO_PMOS_GL:-1}"
t0=$(date +%s); _lance "$@"; rc=$?
if _mort_tot "$rc" && [ "$OSMO_PMOS_HOST_QEMU" = 1 ]; then
    echo "osmo-pmos-qemu: le QEMU de l hote est mort aussitot ($rc) - relance avec celui du chroot (OSMO_PMOS_HOST_QEMU=0)"
    OSMO_PMOS_HOST_QEMU=0; HOST_QEMU_OPT=(); t0=$(date +%s); _lance "$@"; rc=$?
fi
if _mort_tot "$rc" && [ "${OSMO_PMOS_DISPLAY:-sdl}" = sdl ]; then
    echo "osmo-pmos-qemu: QEMU est mort aussitot ($rc) - relance en fenetre GTK, OpenGL garde (OSMO_PMOS_DISPLAY=gtk)"
    export OSMO_PMOS_DISPLAY=gtk; t0=$(date +%s); _lance "$@"; rc=$?
fi
if _mort_tot "$rc" && [ "${OSMO_PMOS_KVM:-}" != 0 ]; then
    echo "osmo-pmos-qemu: encore mort ($rc) - relance SANS KVM, OpenGL garde (OSMO_PMOS_KVM=0, lent)"
    export OSMO_PMOS_KVM=0; t0=$(date +%s); _lance "$@"; rc=$?
fi
if _mort_tot "$rc" && [ "$OSMO_PMOS_GL" != 0 ]; then
    echo "osmo-pmos-qemu: encore mort ($rc) - DERNIER RECOURS : sans OpenGL (OSMO_PMOS_GL=0) - l affichage sera en paves"
    export OSMO_PMOS_GL=0; t0=$(date +%s); _lance "$@"; rc=$?
fi
# The VM stopped (window closed, poweroff from Phosh, failure): the host
# direct loopback comes back - without it, nobody listens to gsm_audio.
[ -n "$AUDIO_LIB" ] && { ensure_local_loopback; ensure_local_mic; } 2>/dev/null | sed 's/^ *//; s/^/osmo-pmos-qemu: /'
[ "$rc" -eq 0 ] || read -r -p "pmbootstrap a echoue ($rc). Entree pour fermer " _
exit "$rc"
