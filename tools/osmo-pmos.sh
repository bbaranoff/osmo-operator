#!/bin/bash
# =============================================================================
# osmo-pmos.sh - THE BENCH PHONE: A postmarketOS / Phosh VM.
#
# postmarketOS comes with ModemManager, Calls and Chatty: a real Linux phone,
# and a real phone connects to a MODEM. The bench has one -
# tools/osmo-phonesim-banc.py, which speaks 27.007 on one side and drives the
# bench on the other (osmo-bsc VTY, osmo-msc SMPP, Asterisk AMI). This script
# lays the wire between the two.
#
#   Phosh / Calls / Chatty
#        ↕  D-Bus
#   ModemManager (in the VM)
#        ↕  /dev/ttyS1  (serial port of the VM)
#   QEMU  -serial tcp:127.0.0.1:12346,server=on,wait=off
#        ↕  TCP
#   osmo-phonesim-banc.py --connect 127.0.0.1:12346   (the bench modem)
#        ↕  VTY / SMPP / AMI
#   osmo-bsc · osmo-msc · Asterisk · the osmocom-bb mobile
#
# WHY WE GO TOWARDS QEMU, and not the reverse: the VM's UEFI firmware reads
# any serial port as a console. A modem already chatty during boot makes it
# believe the boot is being interrupted, and it stops on its menu. So QEMU
# LISTENS (server=on,wait=off) and the modem connects once the system is up -
# the modem's --connect mode, which waits for the VM's SSH port to answer
# before connecting.
#
#   osmo-pmos up         the icon's gesture: the pmbootstrap VM (osmo-pmos-qemu),
#                        smartphone|tablette form factor as argument; stop and status go there too
#   osmo-pmos install    qemu packages + the postmarketOS image + the preparation
#   osmo-pmos fetch      downloads (or resumes) the image and checks its sha256
#   osmo-pmos provision  password, sshd, and the ModemManager rule for the AT port
#   osmo-pmos start      starts the VM AND the bench modem that goes with it
#   osmo-pmos toggle     switch: shuts the VM down if running, starts it otherwise (the icon)
#   osmo-pmos stop       stops both
#   osmo-pmos status     where each piece stands
#   osmo-pmos shell      a shell in the VM (ssh)
#   osmo-pmos mm         what ModemManager sees of the modem, INSIDE the VM
#   osmo-pmos at         talk to the bench modem by hand (tools/at-cmd.py)
#   osmo-pmos log        the VM's AT trace, live
#
# THE PASSWORD IS 147147. It is the one of the official postmarketOS images,
# and it is SET AGAIN at each provision so that the live key, the installed
# system and a re-downloaded image all answer the same. It opens the Phosh
# session (the lock screen), the "user" account and ssh. It is not a secret:
# this is a demonstration bench.
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
VAR="${OSMO_PMOS_DIR:-/var/lib/osmo-pmos}"
IMG="$VAR/pmos.img"
RUNDIR="${OSMO_PMOS_RUN:-/run/osmo-pmos}"
PIDF="$RUNDIR/qemu.pid"
MDMPID="$RUNDIR/modem.pid"

# The phone password. 147147 everywhere: lock screen, "user" account, ssh.
# Changeable for a particular demonstration, but that is not the use case -
# see the header.
PMOS_PASS="${OSMO_PMOS_PASSWORD:-147147}"
PMOS_USER="${OSMO_PMOS_USER:-user}"

# The VM serial port (the modem), and the SSH port. The second ALSO serves
# as a witness: the modem only connects once it answers (see the header).
AT_PORT="${OSMO_PMOS_AT_PORT:-12346}"
SSH_PORT="${OSMO_PMOS_SSH_PORT:-2222}"

# The image. The official images live in dated directories; "the most
# recent" is resolved on the fly, and everything is overridable:
#   OSMO_PMOS_IMG_URL   the exact URL of a .img.xz image
#   OSMO_PMOS_IMG_FILE  an image ALREADY downloaded (nothing is downloaded)
PMOS_BRANCHE="${OSMO_PMOS_BRANCHE:-v25.12}"
PMOS_APPAREIL="${OSMO_PMOS_APPAREIL:-generic-x86_64}"
PMOS_IHM="${OSMO_PMOS_IHM:-phosh}"
PMOS_BASE="https://images.postmarketos.org/bpo/$PMOS_BRANCHE/$PMOS_APPAREIL/$PMOS_IHM/"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    _err "cette commande demande root : sudo osmo-pmos $*"
    return 1
}

# ── THE PACKAGES ─────────────────────────────────────────────────────────────
# qemu-system-x86 (the VM), ovmf (the UEFI firmware: the postmarketOS
# generic-x86_64 image does not boot in BIOS), xz-utils (the image is
# compressed), and sshpass for "osmo-pmos shell" without typing the password
# every time.
_pmos_paquets() {
    export DEBIAN_FRONTEND=noninteractive
    local p manque=()
    for p in qemu-system-x86 qemu-system-gui qemu-system-modules-opengl ovmf xz-utils curl sshpass; do
        dpkg -s "$p" >/dev/null 2>&1 || manque+=("$p")
    done
    [ "${#manque[@]}" -eq 0 ] && { _ok "paquets deja la (qemu, ovmf, xz, curl, sshpass)"; return 0; }
    _say "installation : ${manque[*]}"
    apt-get update -y >/dev/null 2>&1 || true
    for p in "${manque[@]}"; do
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
            && _ok "$p installe" || _warn "$p indisponible (apt) - ignore"
    done
}

_ovmf() {
    local f
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# ── THE IMAGE ────────────────────────────────────────────────────────────────
# Resolve the most recent dated directory, download with resume (curl -C -),
# and VERIFY the sha256 published next to it. An image truncated by a network
# cut gives a VM that does not boot, without saying why.
_pmos_url() {
    [ -n "${OSMO_PMOS_IMG_URL:-}" ] && { echo "$OSMO_PMOS_IMG_URL"; return 0; }
    local index date fichier
    index="$(curl -fsSL "$PMOS_BASE" 2>/dev/null)" || return 1
    date="$(printf '%s' "$index" | grep -o 'href="[0-9]\{8\}-[0-9]\{4\}/"' \
            | sed 's/href="//; s|/"||' | sort -r | head -1)"
    [ -n "$date" ] || return 1
    index="$(curl -fsSL "$PMOS_BASE$date/" 2>/dev/null)" || return 1
    fichier="$(printf '%s' "$index" | grep -o 'href="[^"]*\.img\.xz"' \
               | sed 's/href="//; s/"//' | head -1)"
    [ -n "$fichier" ] || return 1
    echo "$PMOS_BASE$date/$fichier"
}

pmos_fetch() {
    _root fetch || return 1
    install -d "$VAR" || return 1
    if [ -n "${OSMO_PMOS_IMG_FILE:-}" ]; then
        [ -f "$OSMO_PMOS_IMG_FILE" ] || { _err "OSMO_PMOS_IMG_FILE : $OSMO_PMOS_IMG_FILE introuvable"; return 1; }
        _say "image fournie : $OSMO_PMOS_IMG_FILE"
        case "$OSMO_PMOS_IMG_FILE" in
            *.xz) xz -dc "$OSMO_PMOS_IMG_FILE" > "$IMG" ;;
            *)    cp -f "$OSMO_PMOS_IMG_FILE" "$IMG" ;;
        esac
        _ok "image posee : $IMG"
        return 0
    fi
    if [ -f "$IMG" ] && [ "${OSMO_PMOS_REFETCH:-0}" != "1" ]; then
        _ok "image deja la : $IMG ($(du -h "$IMG" | cut -f1)) - OSMO_PMOS_REFETCH=1 pour la reprendre"
        return 0
    fi
    local url; url="$(_pmos_url)" || { _err "index postmarketOS injoignable ($PMOS_BASE) - donnez OSMO_PMOS_IMG_URL ou OSMO_PMOS_IMG_FILE"; return 1; }
    local xzf="$VAR/$(basename "$url")"
    _say "telechargement : $url"
    _say "1,5 Go environ - la reprise est possible (relancez la commande)"
    curl -fL -C - -o "$xzf" "$url" || { _err "telechargement interrompu - relancez, il reprend"; return 1; }
    if curl -fsSL -o "$xzf.sha256" "$url.sha256" 2>/dev/null; then
        _say "verification sha256..."
        ( cd "$VAR" && sha256sum -c "$(basename "$xzf").sha256" >/dev/null 2>&1 ) \
            && _ok "sha256 conforme" \
            || { _err "sha256 NON conforme : image corrompue, on ne la deballe pas"; return 1; }
    else
        _warn "pas de sha256 publie - on continue sans verifier"
    fi
    _say "decompression (compter quelques minutes)..."
    xz -dc "$xzf" > "$IMG" || { _err "decompression impossible"; return 1; }
    # The image comes out at the exact size; a phone needs some room for its
    # logs and messages. The file is sparse: these 8 GiB cost nothing until
    # used.
    qemu-img resize -f raw "$IMG" 8G >/dev/null 2>&1 || true
    _ok "image prete : $IMG"
    [ "${OSMO_PMOS_GARDER_XZ:-0}" = "1" ] || rm -f "$xzf" "$xzf.sha256"
}

# ── PREPARING THE IMAGE ──────────────────────────────────────────────────────
# Mount the image's root partition on the host (losetup -P) and install three
# things. Safer than an interactive first boot: the VM is ready BEFORE being
# powered on, and a re-downloaded image goes through here again.
pmos_provision() {
    _root provision || return 1
    [ -f "$IMG" ] || { _err "pas d image : osmo-pmos fetch d abord"; return 1; }
    local loop mnt="$VAR/mnt" part
    loop="$(losetup -f --show -P "$IMG")" || { _err "losetup impossible"; return 1; }
    # The root is the largest partition of the image (the first is the ESP).
    part="$(lsblk -brno NAME,SIZE "$loop" | tail -n +2 | sort -k2 -n | tail -1 | cut -d' ' -f1)"
    [ -n "$part" ] || { losetup -d "$loop"; _err "aucune partition dans l image"; return 1; }
    install -d "$mnt"
    if ! mount "/dev/$part" "$mnt" 2>/dev/null; then
        losetup -d "$loop"
        _err "/dev/$part non montable (image chiffree ? partition inattendue)"
        return 1
    fi
    local rc=0
    if [ ! -d "$mnt/etc" ]; then
        _err "/dev/$part ne ressemble pas a la racine du systeme"
        rc=1
    else
        # 1. THE PASSWORD, written in /etc/shadow. No chroot: the image is
        #    musl/Alpine and its /bin/sh does not have the same libraries as
        #    the host. openssl builds the SHA-512 digest that shadow expects.
        local hash
        hash="$(openssl passwd -6 "$PMOS_PASS" 2>/dev/null)"
        if [ -n "$hash" ] && [ -f "$mnt/etc/shadow" ]; then
            local u
            for u in root "$PMOS_USER"; do
                grep -q "^$u:" "$mnt/etc/shadow" || continue
                # Field 2 is the digest; awk rather than sed because a hash
                # contains "/".
                awk -F: -v u="$u" -v h="$hash" 'BEGIN{OFS=":"} $1==u{$2=h} {print}' \
                    "$mnt/etc/shadow" > "$mnt/etc/shadow.osmo" \
                    && mv "$mnt/etc/shadow.osmo" "$mnt/etc/shadow"
            done
            chmod 640 "$mnt/etc/shadow" 2>/dev/null || true
            _ok "mot de passe ${BOLD}$PMOS_PASS${NC} pose pour root et $PMOS_USER"
        else
            _warn "mot de passe non pose (openssl absent ou /etc/shadow introuvable)"
        fi

        # 2. THE AT PORT AS SEEN BY ModemManager. Without this rule nothing
        #    happens, SILENTLY: ModemManager does not probe a random ttyS (its
        #    default policy is "strict" - it needs a udev marker), and the
        #    Phosh screen stays on "no modem".
        #    The serial port QEMU adds is a pci-serial (vendor 0x1b36, "Red
        #    Hat, Inc."): the motherboard's ttyS0-3 have no PCI parent and
        #    are therefore not touched by this rule.
        install -d "$mnt/etc/udev/rules.d"
        cat > "$mnt/etc/udev/rules.d/77-osmo-modem-at.rules" <<'UDEV'
# The bench modem, presented to the VM as a PCI serial port by QEMU.
# ID_MM_DEVICE_PROCESS : "probe this port" (ModemManager ignores it otherwise).
# ID_MM_PORT_TYPE_AT   : "this is a command port", not a data port.
SUBSYSTEM=="tty", KERNEL=="ttyS*", ATTRS{vendor}=="0x1b36", \
    ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_PORT_TYPE_AT}="1", \
    ENV{ID_MM_TTY_BAUDRATE}="115200"
UDEV
        _ok "regle udev posee : ModemManager sondera le port AT du banc"

        # 3. SSH. It serves as a witness ("the VM is up"), as a debugging
        #    shell, and it is how the modem knows when to connect.
        if [ -d "$mnt/etc/init.d" ] && [ -x "$mnt/etc/init.d/sshd" ]; then
            install -d "$mnt/etc/runlevels/default"
            ln -sf /etc/init.d/sshd "$mnt/etc/runlevels/default/sshd" 2>/dev/null || true
            _ok "sshd active au demarrage de la VM"
        else
            _warn "sshd absent de l image - « osmo-pmos shell » ne marchera pas"
        fi
    fi
    umount "$mnt" 2>/dev/null || true
    losetup -d "$loop" 2>/dev/null || true
    return $rc
}

# ── START ────────────────────────────────────────────────────────────────────
pmos_start() {
    echo "[2/3] machine virtuelle"
    _root start || return 1
    [ -f "$IMG" ] || { _err "pas d image : osmo-pmos install d abord"; return 1; }
    install -d "$RUNDIR"
    if pmos_tourne; then _ok "la VM tourne deja (pid $(cat "$PIDF"))"; else
        local bios; bios="$(_ovmf)" || { _err "firmware UEFI introuvable (paquet ovmf) - l image generic-x86_64 ne demarre qu en UEFI"; return 1; }
        local accel=tcg
        [ -w /dev/kvm ] && accel=kvm
        [ "$accel" = tcg ] && _warn "pas de /dev/kvm : la VM tournera en emulation (lent mais fonctionnel)"
        # -serial tcp:...,server=on,wait=off: QEMU LISTENS and waits for
        # nobody. The modem comes once the system is up (see the header).
        # wait=on would block the boot of the VM itself.
        # The phone format (720x1440) does not exist on every QEMU: fall back
        # to the default resolution if the setting is refused.
        local gpu="virtio-vga"
        local res="${OSMO_PMOS_RES:-720x1440}"
        local xr="${res%x*}" yr="${res#*x}"
        local base=(
            qemu-system-x86_64
            -name osmo-pmos
            -machine q35 -accel "$accel" -m "${OSMO_PMOS_RAM:-2048}" -smp "${OSMO_PMOS_CPU:-2}"
            -bios "$bios"
            -drive "if=virtio,format=raw,file=$IMG"
            -device virtio-tablet-pci -device virtio-keyboard-pci
            -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
            -device virtio-net-pci,netdev=n0
            -device pci-serial,chardev=at
            -chardev "socket,id=at,host=127.0.0.1,port=$AT_PORT,server=on,wait=off"
            -display "${OSMO_PMOS_DISPLAY:-gtk}"
            -pidfile "$PIDF"
            -daemonize
        )
        if ! "${base[@]}" -device "$gpu,xres=$xr,yres=$yr" 2>"$RUNDIR/qemu.err"; then
            _warn "definition $res refusee par ce QEMU - on garde la sienne"
            "${base[@]}" -device "$gpu" 2>"$RUNDIR/qemu.err" || {
                _err "QEMU n a pas demarre :"; sed 's/^/      /' "$RUNDIR/qemu.err" >&2; return 1; }
        fi
        _ok "VM postmarketOS demarree (ssh 127.0.0.1:$SSH_PORT, modem 127.0.0.1:$AT_PORT)"
        _say "mot de passe : ${BOLD}$PMOS_PASS${NC} (ecran de verrouillage, compte $PMOS_USER, ssh)"
    fi
    pmos_modem_start
}

# The bench modem, host side. --connect mode: it waits for the VM's SSH to
# answer, then connects to the serial port QEMU keeps open.
pmos_modem_start() {
    echo "[3/3] modem du banc"
    if pgrep -f "osmo-phonesim-banc.py --connect 127.0.0.1:$AT_PORT" >/dev/null 2>&1; then
        _ok "le modem du banc est deja branche sur le port $AT_PORT"
        return 0
    fi
    # /usr/bin/python3 and not the shebang: launched from the bench, the PATH
    # puts the venv first and the interpreter found there lacks the bindings
    # these tools need (same trap as in start-native.sh).
    OSMO_VM_READY_PORT="$SSH_PORT" setsid /usr/bin/python3 \
        "$REPO/tools/osmo-phonesim-banc.py" --connect "127.0.0.1:$AT_PORT" \
        >>/tmp/osmo-phonesim-vm.log 2>&1 &
    echo $! > "$MDMPID"
    _ok "modem du banc lance (il se branchera des que la VM repondra en ssh)"
    _say "journal : /tmp/osmo-phonesim-vm.log ; trace AT : /var/log/osmo-at-ofono.log"
}

pmos_tourne() {
    [ -f "$PIDF" ] || return 1
    kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
}

pmos_stop() {
    _root stop || return 1
    pkill -f "osmo-phonesim-banc.py --connect 127.0.0.1:$AT_PORT" 2>/dev/null \
        && _ok "modem du banc arrete" || true
    if pmos_tourne; then
        kill "$(cat "$PIDF")" 2>/dev/null
        sleep 2
        pmos_tourne && kill -9 "$(cat "$PIDF")" 2>/dev/null
        _ok "VM arretee"
    else
        _say "la VM ne tournait pas"
    fi
    rm -f "$PIDF" "$MDMPID"
}

pmos_status() {
    echo -e "${BOLD}postmarketOS / Phosh - le telephone du banc${NC}"
    if pmos_tourne; then _ok "VM : en marche (pid $(cat "$PIDF"))"
    else _warn "VM : arretee"; fi
    [ -f "$IMG" ] && _ok "image : $IMG ($(du -h "$IMG" 2>/dev/null | cut -f1))" \
                  || _warn "image : absente (osmo-pmos install)"
    if pgrep -f "osmo-phonesim-banc.py --connect 127.0.0.1:$AT_PORT" >/dev/null 2>&1; then
        _ok "modem du banc : lance"
    else
        _warn "modem du banc : arrete"
    fi
    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null; then
        _ok "ssh de la VM : ouvert sur 127.0.0.1:$SSH_PORT (mot de passe $PMOS_PASS)"
    else
        _warn "ssh de la VM : ferme (la VM demarre encore ?)"
    fi
    if grep -q . /var/log/osmo-at-ofono.log 2>/dev/null; then
        echo -e "  ${CYAN}dernieres lignes du dialogue AT :${NC}"
        tail -6 /var/log/osmo-at-ofono.log | sed 's/^/      /'
    fi
}

pmos_shell() {
    command -v sshpass >/dev/null 2>&1 \
        && exec sshpass -p "$PMOS_PASS" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$PMOS_USER@127.0.0.1" "$@"
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -p "$SSH_PORT" "$PMOS_USER@127.0.0.1" "$@"
}

# What ModemManager sees, from the VM: the only place that tells whether the
# bench modem was recognised, and under which number.
pmos_mm() {
    pmos_shell "sudo mmcli -L; echo; sudo mmcli -m 0 2>/dev/null || true"
}

pmos_install() {
    echo "[1/3] image postmarketOS"
    _root install || return 1
    _pmos_paquets
    pmos_fetch     || return 1
    pmos_provision || return 1
    echo
    _ok "${BOLD}pret${NC} - « osmo-pmos start » allume le telephone"
    _say "mot de passe : ${BOLD}$PMOS_PASS${NC}"
}

# THE ICON ACTION GOES TO pmbootstrap. The dock icon (osmo-pmos.desktop) and
# osmo-launcher.py call "osmo-pmos up"; the bench VM is the pmbootstrap one
# (tools/osmo-pmos-qemu.sh: modem on a PCI serial port, voice bridge sound
# cards, screen format), not the image downloaded here into
# /var/lib/osmo-pmos. up/start, stop/down and status go to the pmbootstrap
# launcher as soon as it is present; the rest (fetch, provision, shell, mm,
# at, log) keeps its meaning here.
QEMU_LANCEUR="${OSMO_PMOS_QEMU:-/usr/local/bin/osmo-pmos-qemu}"
[ -x "$QEMU_LANCEUR" ] || QEMU_LANCEUR="$REPO/tools/osmo-pmos-qemu.sh"
if [ -x "$QEMU_LANCEUR" ]; then
    case "${1:-status}" in
        up|start)  shift; exec "$QEMU_LANCEUR" "$@" ;;
        toggle|bascule) shift; exec "$QEMU_LANCEUR" toggle "$@" ;;
        stop|down) exec "$QEMU_LANCEUR" stop ;;
        status)    exec "$QEMU_LANCEUR" status ;;
    esac
fi
case "${1:-status}" in
    install)   pmos_install ;;
    # "up" = the icon action: install if the image is missing, then power on.
    # The image (1.5 GB to download) is NOT in the ISO - it would fit poorly
    # in a squashfs that must live in RAM - so the first launch is long,
    # once. The packages are already in the image
    # (tools/osmo-extras-install.sh installs them at build).
    up)
        # The "[n/3]" markers printed by the functions make the progress bar
        # of the launch window (osmo-gtk-run.py --progress).
        if [ ! -f "$IMG" ]; then
            _say "premier lancement : il faut d abord poser l image postmarketOS"
            pmos_install || exit 1
        fi
        pmos_start
        ;;
    fetch)     pmos_fetch ;;
    provision) pmos_provision ;;
    start)     pmos_start ;;
    stop|down) pmos_stop ;;
    status)    pmos_status ;;
    shell)     shift; pmos_shell "$@" ;;
    mm)        pmos_mm ;;
    at)        shift; exec /usr/bin/python3 "$REPO/tools/at-cmd.py" "$@" ;;
    log)       exec tail -f /var/log/osmo-at-ofono.log ;;
    *)
        sed -n '/^#   osmo-pmos/,/^#   osmo-pmos log/p' "$0" | sed 's/^# \{0,2\}//'
        exit 2
        ;;
esac
