#!/bin/bash
# =============================================================================
# osmo-pmos.sh - LE TELEPHONE DU BANC : UNE VM postmarketOS / Phosh.
#
# CE QUI A CHANGE, ET POURQUOI. Le telephone du banc etait un Android en
# conteneur (Waydroid). Android n a pas de pile radio dans ce cadre-la : il
# aurait fallu un rild et un RIL proprietaire pour esperer une VRAIE telephonie,
# et sans eux tout passait par un pont qui posait des NOTIFICATIONS - une
# imitation d appel, pas un appel. postmarketOS, lui, arrive avec ModemManager,
# Calls et Chatty : c est un vrai telephone Linux, et un vrai telephone se
# branche sur un MODEM. Le banc en a un - tools/osmo-phonesim-banc.py, qui parle
# 27.007 d un cote et pilote le banc de l autre (VTY d osmo-bsc, SMPP d osmo-msc,
# AMI d Asterisk). Il ne restait donc qu a poser le fil entre les deux.
#
#   Phosh / Calls / Chatty
#        ↕  D-Bus
#   ModemManager (dans la VM)
#        ↕  /dev/ttyS1  (port serie de la VM)
#   QEMU  -serial tcp:127.0.0.1:12346,server=on,wait=off
#        ↕  TCP
#   osmo-phonesim-banc.py --connect 127.0.0.1:12346   (le modem du banc)
#        ↕  VTY / SMPP / AMI
#   osmo-bsc · osmo-msc · Asterisk · le mobile osmocom-bb
#
# POURQUOI C EST NOUS QUI ALLONS VERS QEMU, et pas l inverse : le firmware UEFI
# de la VM lit tout port serie comme une console. Un modem deja bavard pendant
# le demarrage lui fait croire qu on interrompt le boot, et il s arrete sur son
# menu. QEMU ECOUTE donc (server=on,wait=off) et le modem vient s y connecter
# une fois le systeme leve - c est le mode --connect du modem, qui attend que le
# port SSH de la VM reponde avant de se brancher.
#
#   osmo-pmos up         le geste de l icone : la VM pmbootstrap (osmo-pmos-qemu),
#                        format smartphone|tablette en argument ; stop et status y vont aussi
#   osmo-pmos install    paquets qemu + l image postmarketOS + la preparation
#   osmo-pmos fetch      telecharge (ou reprend) l image et verifie son sha256
#   osmo-pmos provision  mot de passe, sshd, et la regle ModemManager du port AT
#   osmo-pmos start      demarre la VM ET le modem du banc qui va avec
#   osmo-pmos stop       arrete les deux
#   osmo-pmos status     ou en est chaque morceau
#   osmo-pmos shell      un shell dans la VM (ssh)
#   osmo-pmos mm         ce que ModemManager voit du modem, DANS la VM
#   osmo-pmos at         parler a la main au modem du banc (tools/at-cmd.py)
#   osmo-pmos log        la trace AT de la VM, en direct
#
# LE MOT DE PASSE EST 147147. C est celui des images officielles
# postmarketOS, et on le REPOSE a chaque provision pour que la cle live, le
# systeme installe et une image re-telechargee repondent tous pareil - un banc
# ou le mot de passe depend de l historique de la machine n est pas un banc.
# Il ouvre la session Phosh (l ecran de verrouillage), le compte « user » et
# le ssh. Ce n est pas un secret : c est un banc de demonstration.
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
VAR="${OSMO_PMOS_DIR:-/var/lib/osmo-pmos}"
IMG="$VAR/pmos.img"
RUNDIR="${OSMO_PMOS_RUN:-/run/osmo-pmos}"
PIDF="$RUNDIR/qemu.pid"
MDMPID="$RUNDIR/modem.pid"

# Le mot de passe du telephone. 147147 partout : ecran de verrouillage, compte
# « user », ssh. Modifiable pour une demonstration particuliere, mais ce n est
# pas le cas d usage - voir l entete.
PMOS_PASS="${OSMO_PMOS_PASSWORD:-147147}"
PMOS_USER="${OSMO_PMOS_USER:-user}"

# Le port serie de la VM (le modem), et le port SSH. Le second sert AUSSI de
# temoin : le modem ne se branche qu une fois qu il repond (cf. l entete).
AT_PORT="${OSMO_PMOS_AT_PORT:-12346}"
SSH_PORT="${OSMO_PMOS_SSH_PORT:-2222}"

# L image. Les images officielles vivent dans des repertoires dates ; on
# resout donc « le plus recent » a la volee, et tout est surchargeable :
#   OSMO_PMOS_IMG_URL   l URL exacte d une image .img.xz
#   OSMO_PMOS_IMG_FILE  une image DEJA telechargee (rien n est telecharge)
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

# ── LES PAQUETS ──────────────────────────────────────────────────────────────
# qemu-system-x86 (la VM), ovmf (le firmware UEFI : l image postmarketOS
# generic-x86_64 ne demarre pas en BIOS), xz-utils (l image est compressee),
# et sshpass pour « osmo-pmos shell » sans taper le mot de passe a chaque fois.
_pmos_paquets() {
    export DEBIAN_FRONTEND=noninteractive
    local p manque=()
    for p in qemu-system-x86 ovmf xz-utils curl sshpass; do
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

# ── L IMAGE ──────────────────────────────────────────────────────────────────
# On resout le repertoire date le plus recent, on telecharge en reprenant
# (curl -C -), et on VERIFIE le sha256 publie a cote. Une image tronquee par
# une coupure de reseau donne une VM qui ne demarre pas, sans dire pourquoi.
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
    # L image sort a la taille juste ; un telephone a besoin d un peu de place
    # pour ses journaux et ses messages. Le fichier est creux : ces 8 Gio ne
    # coutent rien tant qu ils ne servent pas.
    qemu-img resize -f raw "$IMG" 8G >/dev/null 2>&1 || true
    _ok "image prete : $IMG"
    [ "${OSMO_PMOS_GARDER_XZ:-0}" = "1" ] || rm -f "$xzf" "$xzf.sha256"
}

# ── LA PREPARATION DE L IMAGE ────────────────────────────────────────────────
# On monte la partition racine de l image sur l hote (losetup -P) et on y pose
# trois choses. C est plus sur qu un premier demarrage interactif : la VM est
# prete AVANT d etre allumee, et une image re-telechargee repasse par ici.
pmos_provision() {
    _root provision || return 1
    [ -f "$IMG" ] || { _err "pas d image : osmo-pmos fetch d abord"; return 1; }
    local loop mnt="$VAR/mnt" part
    loop="$(losetup -f --show -P "$IMG")" || { _err "losetup impossible"; return 1; }
    # La racine est la plus grosse partition de l image (la premiere est l ESP).
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
        # 1. LE MOT DE PASSE, pose dans /etc/shadow. On ne chroote pas : l image
        #    est en musl/Alpine et son /bin/sh n a pas les memes bibliotheques
        #    que l hote. openssl fabrique le condensat SHA-512 que attend shadow.
        local hash
        hash="$(openssl passwd -6 "$PMOS_PASS" 2>/dev/null)"
        if [ -n "$hash" ] && [ -f "$mnt/etc/shadow" ]; then
            local u
            for u in root "$PMOS_USER"; do
                grep -q "^$u:" "$mnt/etc/shadow" || continue
                # Le champ 2 est le condensat ; « | » comme separateur de sed
                # parce qu un hash contient des « / ».
                awk -F: -v u="$u" -v h="$hash" 'BEGIN{OFS=":"} $1==u{$2=h} {print}' \
                    "$mnt/etc/shadow" > "$mnt/etc/shadow.osmo" \
                    && mv "$mnt/etc/shadow.osmo" "$mnt/etc/shadow"
            done
            chmod 640 "$mnt/etc/shadow" 2>/dev/null || true
            _ok "mot de passe ${BOLD}$PMOS_PASS${NC} pose pour root et $PMOS_USER"
        else
            _warn "mot de passe non pose (openssl absent ou /etc/shadow introuvable)"
        fi

        # 2. LE PORT AT VU PAR ModemManager. Sans cette regle, rien ne se
        #    passe et c est SILENCIEUX : ModemManager ne sonde pas un ttyS au
        #    hasard (sa politique par defaut est « strict » - il lui faut un
        #    marqueur udev), et l ecran de Phosh reste sur « pas de modem ».
        #    Le port serie qu ajoute QEMU est un pci-serial (vendeur 0x1b36,
        #    « Red Hat, Inc. ») : les ttyS0-3 de la carte mere, eux, n ont pas
        #    de parent PCI et ne sont donc pas touches par cette regle.
        install -d "$mnt/etc/udev/rules.d"
        cat > "$mnt/etc/udev/rules.d/77-osmo-modem-at.rules" <<'UDEV'
# Le modem du banc, presente a la VM comme un port serie PCI par QEMU.
# ID_MM_DEVICE_PROCESS : « sonde ce port » (ModemManager ignore sinon).
# ID_MM_PORT_TYPE_AT   : « c est un port de commandes », pas un port de donnees.
SUBSYSTEM=="tty", KERNEL=="ttyS*", ATTRS{vendor}=="0x1b36", \
    ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_PORT_TYPE_AT}="1", \
    ENV{ID_MM_TTY_BAUDRATE}="115200"
UDEV
        _ok "regle udev posee : ModemManager sondera le port AT du banc"

        # 3. LE SSH. Il sert de temoin (« la VM est levee »), de shell de
        #    depannage, et c est par lui que le modem sait quand se brancher.
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

# ── DEMARRER ─────────────────────────────────────────────────────────────────
pmos_start() {
    _root start || return 1
    [ -f "$IMG" ] || { _err "pas d image : osmo-pmos install d abord"; return 1; }
    install -d "$RUNDIR"
    if pmos_tourne; then _ok "la VM tourne deja (pid $(cat "$PIDF"))"; else
        local bios; bios="$(_ovmf)" || { _err "firmware UEFI introuvable (paquet ovmf) - l image generic-x86_64 ne demarre qu en UEFI"; return 1; }
        local accel=tcg
        [ -w /dev/kvm ] && accel=kvm
        [ "$accel" = tcg ] && _warn "pas de /dev/kvm : la VM tournera en emulation (lent mais fonctionnel)"
        # -serial tcp:...,server=on,wait=off : QEMU ECOUTE et n attend
        # personne. C est le modem qui viendra, une fois le systeme leve (voir
        # l entete). wait=on bloquerait le demarrage de la VM elle-meme.
        # Le format telephone (720x1440) n existe pas sur tous les QEMU : on
        # retombe sur la definition par defaut si le reglage est refuse.
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

# Le modem du banc, cote hote. Mode --connect : il attend que le SSH de la VM
# reponde, puis se branche sur le port serie que QEMU tient ouvert.
pmos_modem_start() {
    if pgrep -f "osmo-phonesim-banc.py --connect 127.0.0.1:$AT_PORT" >/dev/null 2>&1; then
        _ok "le modem du banc est deja branche sur le port $AT_PORT"
        return 0
    fi
    # /usr/bin/python3 et non le shebang : lance depuis le banc, le PATH place
    # le venv en tete et l interprete qu on y trouve n a pas les liaisons dont
    # ces outils ont besoin (meme piege que dans start-direct.sh).
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

# Ce que ModemManager voit, vu de la VM : le seul endroit ou l on sait si le
# modem du banc a ete reconnu, et sous quel numero.
pmos_mm() {
    pmos_shell "sudo mmcli -L; echo; sudo mmcli -m 0 2>/dev/null || true"
}

pmos_install() {
    _root install || return 1
    _pmos_paquets
    pmos_fetch     || return 1
    pmos_provision || return 1
    echo
    _ok "${BOLD}pret${NC} - « osmo-pmos start » allume le telephone"
    _say "mot de passe : ${BOLD}$PMOS_PASS${NC}"
}

# [2026-09-08] LE GESTE DE L ICONE VA A pmbootstrap. L icone du dock
# (osmo-pmos.desktop) et osmo-launcher.py appellent « osmo-pmos up » ; or la
# VM du banc est desormais celle de pmbootstrap (tools/osmo-pmos-qemu.sh :
# modem sur port serie PCI, cartes son du pont voix, format d ecran), pas
# l image telechargee ici dans /var/lib/osmo-pmos. « up » finissait donc sur
# « il faut d abord poser l image... cette commande demande root », fenetre
# fermee aussitot. up/start, stop/down et status vont au lanceur pmbootstrap
# des qu il est la ; le reste (fetch, provision, shell, mm, at, log) garde
# son sens ici.
QEMU_LANCEUR="${OSMO_PMOS_QEMU:-/usr/local/bin/osmo-pmos-qemu}"
[ -x "$QEMU_LANCEUR" ] || QEMU_LANCEUR="$REPO/tools/osmo-pmos-qemu.sh"
if [ -x "$QEMU_LANCEUR" ]; then
    case "${1:-status}" in
        up|start)  shift; exec "$QEMU_LANCEUR" "$@" ;;
        stop|down) exec "$QEMU_LANCEUR" stop ;;
        status)    exec "$QEMU_LANCEUR" status ;;
    esac
fi
case "${1:-status}" in
    install)   pmos_install ;;
    # « up » = le geste de l icone : on installe si l image manque, puis on
    # allume. L image (1,5 Go a telecharger) n est PAS dans l ISO - elle
    # tiendrait mal dans un squashfs qui doit vivre en RAM - et le premier
    # lancement est donc long, une fois. Les paquets, eux, sont deja dans
    # l image (tools/osmo-extras-install.sh les pose au build).
    up)
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
