#!/bin/bash
# iso_modules/81-cloture-systeme.sh - step 8b: ldd closure from the run image, network, osmo-update
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not meant to run on its own. A top-level `return` means "nothing to do here"
# (this is how --arm skips a step).

# ── Step 8b: ldd dependency closure copied from the run image ────────────────
# The osmocom-run image (build.sh + Dockerfile) is the reference environment.
# Instead of relying on the rootfs apt versions (version skew breaks libosmocore
# logging), copy the exact .so closure of all osmo binaries and
# calypso-ipc-device from the container, overwriting the apt libs. The
# glibc/loader family is excluded (never clobber ld.so).
echo -e "${GREEN}[8b/9] Cloture de dependances COMPLETE depuis ${CYAN}${ISO_RUN_IMAGE}${NC}${GREEN} (toute l'install)...${NC}"
# ldd every ELF (executables and .so) of the custom install: /usr/local/bin
# (osmo), /opt/GSM (qemu, ipc-device, gr-gsm), /root/.env (Python venv:
# gnuradio/gr-gsm bindings and their boost/log4cpp/volk/fftw deps).
docker run --rm --entrypoint bash \
    -e OSMO_LDD_ROOTS="$([ "$ISO_ROLE" = "interstp" ] && echo "/usr/local/bin /usr/local/lib" || echo "/usr/local/bin /opt/GSM /root/.env")" \
    "$ISO_RUN_IMAGE" -c '
    set -e
    find ${OSMO_LDD_ROOTS:-/usr/local/bin /opt/GSM /root/.env} -type f \( -executable -o -name "*.so*" \) 2>/dev/null \
      | while read -r b; do ldd "$b" 2>/dev/null; done \
      | grep -oE "/[^ ]+\.so[^ ]*" | sort -u \
      | grep -vE "/(ld-linux[^/]*|ld|libc|libm|libpthread|libdl|librt|libresolv)\.so" \
      | while read -r f; do realpath "$f" 2>/dev/null; done | sort -u \
      | tar -czf - -T - 2>/dev/null
' > "$WORK/closure.tar.gz" || true
if [ -s "$WORK/closure.tar.gz" ]; then
    tar -xzf "$WORK/closure.tar.gz" -C "$ROOTFS" 2>/dev/null || true
    # List of the overwritten libs, for 90-iso.sh: they intentionally replace
    # apt's, so their dpkg md5 no longer matches; the squashfs verification
    # uses this list to not report them as altered. Relative paths, as in .md5sums.
    tar -tzf "$WORK/closure.tar.gz" 2>/dev/null \
        | sed 's#^\./##; s#^/##' | sort -u > "$WORK/closure.list" || true
    echo -e "  ${GREEN}✓${NC} $(wc -l < "$WORK/closure.list") libs injectees (Docker)"
else
    echo -e "  ${YELLOW}cloture vide - on garde les libs apt${NC}"
fi

# /usr/local/lib (custom libosmo*) takes priority; system duplicates are purged.
# No `| grep` here: under set -euo pipefail a grep with no match (the normal
# case: no duplicate) would return 1 and abort the build.
echo "/usr/local/lib" > "$ROOTFS/etc/ld.so.conf.d/00-osmocom-local.conf"
find "$ROOTFS/usr/lib" "$ROOTFS/lib" -maxdepth 4 -name 'libosmo*.so*' -delete 2>/dev/null || true
chroot "$ROOTFS" ldconfig 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} /usr/local/lib prioritaire + ldconfig"

# ── Configuration systeme ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
# ── Legacy docker-plan addresses, as /32 ───────────────────────────────────
# Image configs still reference 172.20.x (backbone gateway, gsmtap target...);
# daemons binding to them need the addresses to exist locally.
#
# /32 rather than /24: a /24 makes the machine ARP the whole 172.20.0.0/24 on
# the LAN instead of routing it, which breaks reaching host containers on a
# mixed VM + docker bench ("ip route add ... via <host>" fails with "File exists").
#
# 172.20.0.11 is intentionally absent: it is the first operator container's
# address; a VM holding it would answer itself. No /16 route for the same reason.
#
# The private node addresses are set at runtime by osmo-ip-plan.service on the
# interface that holds the default route (see network/osmo-ip-plan.sh).
EOF
# Units are enabled one by one: 'systemctl enable' validates all listed units
# first, so one missing unit would prevent enabling the others.
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null||true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>/dev/null||true

# ── DNS: do not ship the build host's resolv.conf ───────────────────────────
# 80-chroot.sh copies the host's /etc/resolv.conf so apt in the chroot has DNS;
# on Ubuntu hosts it is the systemd-resolved stub (127.0.0.53). Restore the
# standard Ubuntu symlink to the stub file that systemd-resolved writes in /run
# at each boot (systemd-resolved is installed and enabled above).
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
# Fallback: if systemd-resolved does not start, the symlink dangles and there
# is no DNS. Leave a backup copy that NetworkManager or an operator can restore.
printf '# Repli hors systemd-resolved : cp %s /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
' \
    /etc/resolv.conf.secours > "$ROOTFS/etc/resolv.conf.secours"
echo -e "  ${GREEN}✓${NC} DNS : /etc/resolv.conf -> stub systemd-resolved (repli /etc/resolv.conf.secours)"

# ── No waiting for the network, at boot or shutdown ────────────────────────
# The *-wait-online units can delay boot by up to 2 minutes; the bench
# interfaces (apn0, packet-core tun/veth) are never "online" in their sense
# and the WAN cable is not always plugged in. Nothing started here needs a
# default route first: bench units retry, osmo-update exits 0 offline, and
# osmo-ip-plan is replayed by the dispatchers when a link comes up.
#
# Masked, not just disabled: network-online.target is pulled in by third-party
# units (apt-daily, snapd, cloud-init); with the wait-online units masked the
# target is reached immediately. Applies to all variants (operator, inter-STP,
# lite), not only --desktop.
install -d "$ROOTFS/etc/systemd/system"
for _wo in systemd-networkd-wait-online.service NetworkManager-wait-online.service \
           systemd-networkd-wait-online@.service; do
    ln -sfn /dev/null "$ROOTFS/etc/systemd/system/$_wo"
done
unset _wo

# ── Bounded shutdown ───────────────────────────────────────────────────────
# systemd defaults to 90 s per stuck unit. 30 s is enough for a clean stop;
# beyond that SIGKILL is the right answer. DefaultTimeoutStartSec likewise
# at boot. Services that need more declare it themselves.
install -d "$ROOTFS/etc/systemd/system.conf.d"
cat > "$ROOTFS/etc/systemd/system.conf.d/10-osmo-timeouts.conf" <<'SDTO'
# Installed by build-iso.sh (iso_modules/81-cloture-systeme.sh).
# Neither boot nor shutdown should wait for the network or a stuck service.
# The wait-online units are masked next to this file.
[Manager]
DefaultTimeoutStartSec=45s
DefaultTimeoutStopSec=30s
SDTO
echo -e "  ${GREEN}✓${NC} aucune attente reseau : ${CYAN}*-wait-online${NC} masquees · arret plafonne a ${CYAN}30 s${NC}"

# ── Private node addresses, set at runtime ─────────────────────────────────
# network/osmo-ip-plan.sh picks the interface that actually provides Internet,
# assigns 192.168.<node+1>.1 and .10 to it, and falls back to 127.0.0.66 on lo
# when no interface leads anywhere, so configs that name a private address
# always find something local to bind to.
install -Dm755 "$DIR/network/osmo-ip-plan.sh" "$ROOTFS/usr/local/sbin/osmo-ip-plan.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-ip-plan.service" <<'IPPLAN'
[Unit]
Description=Adresses privees du noeud sur la carte qui fournit Internet
# Not ordered after network-online.target (see above): the first run may
# fall back to 127.0.0.66; both dispatchers below replay the plan as soon as
# an interface becomes routable (networkd-dispatcher for systemd-networkd
# interfaces, NetworkManager-dispatcher for physical NICs).
After=network.target systemd-networkd.service
Before=osmo-egprs-web.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-ip-plan.sh --apply

[Install]
WantedBy=multi-user.target
IPPLAN
# Replayed on every link change (cable replugged, Wi-Fi taking over), since
# the interface providing Internet may change.
mkdir -p "$ROOTFS/etc/networkd-dispatcher/routable.d"
cat > "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan" <<'IPHOOK'
#!/bin/sh
exec /usr/local/sbin/osmo-ip-plan.sh --apply
IPHOOK
chmod +x "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan"
# Same hook for NetworkManager: networkd-dispatcher only sees systemd-networkd
# interfaces, while NetworkManager manages the physical NICs
# (iso_modules/80-chroot.sh).
mkdir -p "$ROOTFS/etc/NetworkManager/dispatcher.d"
cat > "$ROOTFS/etc/NetworkManager/dispatcher.d/50-osmo-ip-plan" <<'NMHOOK'
#!/bin/sh
# $1 = interface, $2 = action. Only link-up events matter.
case "$2" in
    up|dhcp4-change|dhcp6-change|connectivity-change) ;;
    *) exit 0 ;;
esac
exec /usr/local/sbin/osmo-ip-plan.sh --apply
NMHOOK
chmod +x "$ROOTFS/etc/NetworkManager/dispatcher.d/50-osmo-ip-plan"
chroot "$ROOTFS" systemctl enable osmo-ip-plan 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-ip-plan : ${CYAN}192.168.$(( ${ISO_NODE:-1} + 1 )).1/.10${NC} sur la carte Internet, repli ${CYAN}127.0.0.66${NC}"

# live-boot writes /root/etc/network/interfaces in the root mounted at boot;
# without ifupdown /etc/network/ does not exist and /init fails with
# "nonexistent directory". Create the directory and a minimal (loopback)
# interfaces file. systemd-networkd manages the network; nobody reads this
# file, it only satisfies the live-boot hook.
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# ── SMS animation at login ─────────────────────────────────────────────────
# The repositories, packages and dashboard service are all provisioned at
# build time; the only interactive part of update.sh left is the SMS animation.
#
# It is played by the login profile, not a service (a systemd oneshot runs
# before any terminal exists). /etc/profile.d is sourced alphabetically:
# 01-osmo-disclaimer.sh first, then 99-osmo-sms.sh.
install -Dm755 "$DIR/update.sh" "$ROOTFS/usr/local/sbin/osmo-sms.sh"
cat > "$ROOTFS/etc/profile.d/99-osmo-sms.sh" <<'EOF'
# 99-osmo-sms.sh - installed by build-iso.sh. Plays an incoming SMS once per
# boot. Sourced after 01-keyboard-setup.sh (alphabetical order).
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac      # session interactive seulement
[ -x /usr/local/sbin/osmo-sms.sh ] || return 0
# /run is a tmpfs recreated at each boot: the animation plays once per boot,
# not on every tty or "su -".
[ -e /run/osmo-sms.done ] && return 0
: > /run/osmo-sms.done
/usr/local/sbin/osmo-sms.sh
EOF
chmod +x "$ROOTFS/etc/profile.d/99-osmo-sms.sh"
echo -e "  ${GREEN}✓${NC} animation SMS a l'ouverture de session (99-osmo-sms.sh)"

# ── /usr/local/bin/osmo-update: in-place update via git ────────────────────
# The repositories ship in the image with their .git, so the update is a
# fetch plus fast-forward. Nothing is deleted or recloned, and an offline
# machine keeps exactly what it was built with.
cat > "$ROOTFS/usr/local/bin/osmo-update" <<'OSMOUPD'
#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# osmo-update - update the repositories embedded in the image, in place.
#
#   osmo-update              all repositories
#   osmo-update qosmo        a single one (osmo-operator | osmo-egprs-web | qosmo | c54x_exe | grgsm_exe)
#   osmo-update --check      report what is behind, write nothing
#   osmo-update --quiet      no colours or decoration (journal, cron)
#   osmo-update --boot       boot mode: --quiet, logged, always exits 0
#
# Never deletes a tree, reclones a repository or installs a package.
#
# ══════════════════════════════════════════════════════════════════════════════
set -u

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
CHECK=0; QUIET=0; BOOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1 ;;
        --quiet)   QUIET=1 ;;
        --boot)    BOOT=1; QUIET=1 ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "option inconnue : $1" >&2; exit 2 ;;
        *)         break ;;
    esac
    shift
done
[ "$QUIET" = "1" ] && { G=''; Y=''; R=''; C=''; B=''; N=''; }

# At boot nobody reads the screen: output goes to the log, and the exit code
# must never delay or block multi-user.target.
if [ "$BOOT" = "1" ]; then
    exec >>/var/log/osmo-update.log 2>&1
    echo "===== osmo-update (boot) $(date '+%F %T') ====="
fi

[ "$(id -u)" -eq 0 ] || { echo "Root requis." >&2; exit 1; }

# name|path - the paths start-native.sh, the dashboard and
# environnement/paths.env already use. Changing one here does not move theirs.
REPOS="osmo-operator|/opt/GSM/osmo-operator
osmo-egprs-web|/opt/GSM/osmo-egprs-web
qosmo|/opt/GSM/qosmo
c54x_exe|/opt/GSM/c54x_exe
grgsm_exe|/opt/GSM/grgsm_exe"

WANT="${1:-}"
rc=0; web_moved=0; forks_moved=""

while IFS='|' read -r name dir; do
    [ -n "$name" ] || continue
    [ -z "$WANT" ] || [ "$WANT" = "$name" ] || continue
    found=1
    printf "  ${B}%-16s${N} ${C}%s${N}\n" "$name" "$dir"

    if [ ! -d "$dir" ]; then
        printf "    ${R}✗${N} absent - l'image ne le portait pas\n"; rc=1; continue
    fi
    if [ ! -d "$dir/.git" ]; then
        # Never reclone over it: that would erase a tree of unknown content.
        # Report and skip.
        printf "    ${Y}⚠${N} pas de depot (.git absent) - laisse tel quel\n"; rc=1; continue
    fi

    br="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" || br=""
    [ -n "$br" ] || br=main

    # A --depth 1 repository is grafted: its single commit has no parent, so
    # nothing fetched shares an ancestor with it. Refetch shallow repos with
    # --depth 1 (keeps them light) and full repos fully (keeps ancestry for
    # fast-forward).
    if git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        fetch_ok=$(git -C "$dir" fetch --depth 1 --quiet origin "$br" 2>/dev/null && echo 1)
    else
        fetch_ok=$(git -C "$dir" fetch --quiet origin "$br" 2>/dev/null && echo 1)
    fi
    if [ -z "${fetch_ok:-}" ]; then
        printf "    ${Y}⚠${N} fetch impossible (reseau ?) - copie locale conservee\n"; rc=1; continue
    fi

    local_h="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    remote_h="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null)"
    if [ "$local_h" = "$remote_h" ]; then
        printf "    ${G}✓${N} deja a jour - %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        continue
    fi
    if [ "$CHECK" = "1" ]; then
        printf "    ${Y}→${N} en retard : %s -> %s\n" "${local_h:0:7}" "${remote_h:0:7}"
        continue
    fi

    # Three cases; only local changes block the update, never history.
    if git -C "$dir" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null \
       && git -C "$dir" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
        # 1. Fast-forward: behind on the same branch.
        printf "    ${G}✓${N} %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        [ "$name" = "osmo-egprs-web" ] && web_moved=1
        case "$name" in qosmo) forks_moved="$forks_moved $name" ;; esac
    elif [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        # 2. No common ancestor (grafted --depth 1 repo) but clean tree:
        #    nothing to lose, align with the server.
        if git -C "$dir" reset --hard FETCH_HEAD >/dev/null 2>&1; then
            printf "    ${G}✓${N} aligne sur origin/%s - %s\n" "$br" "$(git -C "$dir" log -1 --format='%h %s')"
            [ "$name" = "osmo-egprs-web" ] && web_moved=1
            case "$name" in qosmo) forks_moved="$forks_moved $name" ;; esac
        else
            printf "    ${Y}⚠${N} alignement impossible - arbre inchange\n"; rc=1
        fi
    else
        # 3. Local modifications: touch nothing, report it.
        printf "    ${Y}⚠${N} modifications locales - rien n'a ete ecrase\n"
        printf "       a la main : ${C}git -C %s status${N}\n" "$dir"
        rc=1
    fi
done <<REPOEOF
$REPOS
REPOEOF

if [ -z "${found:-}" ]; then
    echo "depot inconnu : $WANT  (osmo-operator | osmo-egprs-web | qosmo | c54x_exe | grgsm_exe)" >&2
    exit 2
fi

# A fork update may change tools/qosmo-launch: the installed launcher
# (/usr/local/bin/<fork>, called by 40-qemu.sh) is rebuilt in place (plain C,
# libc only). Without gcc the old binary is kept (40-qemu.sh otherwise falls
# back to QEMU_BIN).
# scripts/voix-forks.sh reapplies the fork voice settings that
# "git reset --hard FETCH_HEAD" wipes ("io-tch-format rtp" in
# cfgs/mobile_group1.cfg and CALYPSO_PULSE_LATENCY_MSEC); see that script.
[ -x /opt/GSM/osmo-operator/scripts/voix-forks.sh ] \
    && /opt/GSM/osmo-operator/scripts/voix-forks.sh

for f in $forks_moved; do
    src="/opt/GSM/$f/tools/qosmo-launch"
    [ -f "$src/qosmo-launch.c" ] || continue
    if command -v gcc >/dev/null 2>&1 && make -s -C "$src" ALIAS="$f" install >/dev/null 2>&1; then
        printf "  ${G}✓${N} lanceur %s recompile (/usr/local/bin/%s)\n" "$f" "$f"
    else
        printf "  ${Y}⚠${N} lanceur %s non recompile (gcc/make ?) - l'ancien reste en place\n" "$f"
    fi
done

# The dashboard runs as a service: it must be restarted to pick up a new
# server.js.
if [ "$web_moved" = "1" ]; then
    [ -f /opt/GSM/osmo-egprs-web/package.json ] && \
        (cd /opt/GSM/osmo-egprs-web && npm install --production >/dev/null 2>&1 || true)
    systemctl try-restart osmo-egprs-web >/dev/null 2>&1 || true
    printf "  ${G}✓${N} dashboard relance\n"
fi

[ "$BOOT" = "1" ] && exit 0
exit $rc
OSMOUPD
chmod +x "$ROOTFS/usr/local/bin/osmo-update"

# At boot: after the network, without blocking it. Type=oneshot and an
# ExecStart that always exits 0 in --boot mode, so an offline machine boots
# the same.
cat > "$ROOTFS/etc/systemd/system/osmo-update.service" <<'EOF'
[Unit]
Description=osmo-operator - mise a jour des depots embarques (git, en place)
# network.target is enough: the default route may come later, which
# osmo-update --boot tolerates. No network-online.target (boot delay).
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/osmo-update --boot
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-update 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-update (/usr/local/bin, + service au demarrage : git fetch, jamais de reclone)"

# ── QEMU_BIN in the qosmo tree: build/qemu-system-arm ──────────────────────
# The qosmo tree ships with .git and build/, so QEMU_BIN normally resolves
# already. This service covers a tree that lost its build/ (manual reclone or
# fresh checkout): environnement/paths.env would then resolve QEMU_BIN to a
# missing path and the stack would stop at the prerequisite check.
#
# Recreate the only path paths.env looks for, as a symlink to the installed
# binary (~30 MB, the ISO lives in RAM). build/ is in qemu's .gitignore, so
# "git clean -fd" does not remove it; the service runs at every boot.
cat > "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh" <<'QLINK'
#!/bin/bash
# osmo-qemu-link.sh - make QEMU_BIN resolvable in the qosmo tree.
# Installed by build-iso.sh (iso_modules/81-cloture-systeme.sh).
set -u
SRC="${OSMO_QEMU_BIN:-/usr/local/bin/qemu-system-arm}"
TREE="${OSMO_QEMU_SRC:-/opt/GSM/qosmo}"
LNK="$TREE/build/qemu-system-arm"

# No binary (inter-STP image) or no tree: nothing to link.
[ -x "$SRC" ] || { echo "osmo-qemu-link: $SRC absent - rien a faire"; exit 0; }
[ -d "$TREE" ] || { echo "osmo-qemu-link: $TREE absent - rien a faire"; exit 0; }

# A real build compiled in place always wins: only replace our own
# symlink or an empty path.
if [ -e "$LNK" ] && [ ! -L "$LNK" ]; then
    echo "osmo-qemu-link: $LNK est un vrai fichier - laisse tel quel"
    exit 0
fi

mkdir -p "$TREE/build"
ln -sfn "$SRC" "$LNK"
echo "osmo-qemu-link: $LNK -> $SRC"

# ── C launchers (tools/qosmo-launch), called by 40-qemu.sh ──────────────────
# /usr/local/bin/<fork> is rebuilt if missing or older than the tree source.
# Only one tree, qosmo; the DSP (--dsp) is c54x_exe, outside QEMU: report if
# it is missing.
for fork in qosmo; do
    src="/opt/GSM/$fork/tools/qosmo-launch"
    [ -f "$src/qosmo-launch.c" ] || continue
    if [ ! -x "/usr/local/bin/$fork" ] || [ "$src/qosmo-launch.c" -nt "/usr/local/bin/$fork" ]; then
        if command -v gcc >/dev/null 2>&1 && make -s -C "$src" ALIAS="$fork" install >/dev/null 2>&1; then
            echo "osmo-qemu-link: lanceur /usr/local/bin/$fork (re)compile"
        else
            echo "osmo-qemu-link: lanceur $fork non compile (gcc/make absents ?) - 40-qemu.sh retombe sur QEMU_BIN"
        fi
    fi
done
if [ -d /opt/GSM/c54x_exe ] && [ ! -x /opt/GSM/c54x_exe/c54x_exe ]; then
    echo "osmo-qemu-link: c54x_exe non compile - --dsp indisponible (make -C /opt/GSM/c54x_exe)"
fi
if [ ! -f /opt/GSM/calypso_dsp.PROM0.bin ]; then
    echo "osmo-qemu-link: ROM DSP absente de /opt/GSM - --dsp indisponible (copie dans /opt/GSM/c54x_exe/rom)"
fi
QLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-qemu-link.service" <<'EOF'
[Unit]
Description=osmo-operator - QEMU_BIN dans l'arbre qosmo + lanceur qosmo
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-qemu-link.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-qemu-link 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-qemu-link (QEMU_BIN relie apres le reclone de qosmo ; lanceur qosmo recompile si besoin)"



# End of module: `. file` returns the status of its last command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
