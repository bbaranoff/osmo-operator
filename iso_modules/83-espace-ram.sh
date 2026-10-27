#!/bin/bash
# iso_modules/83-espace-ram.sh - fstab, /tmp, journal, logrotate, tcpdump wrapper, purge, ssh, keyboard
# Sourced by build-iso.sh in numeric order (same shell, variables and functions);
# not meant to run on its own. A top-level `return` means "nothing to do here"
# (this is how --arm skips a step).

# ── Live writable space: /dev/shm and /tmp, as a percentage of RAM ─────────
# The live system boots 'toram': the root is a tmpfs overlay (RAM). The big
# writers are the I/Q cfiles in /dev/shm (FFT/record, hundreds of MB) and /tmp.
#
# Percentages, not fixed sizes: the squashfs already takes ~2.5 GB of RAM and
# the root is itself a tmpfs; 20 % + 15 % always leave two thirds of RAM to
# the squashfs, root and processes, whatever the machine size.
#
# Idempotent: first remove any existing tmpfs /tmp or /dev/shm entry
# (including the 'nosuid,nodev' variant without size=) and the old block
# comment, then write the canonical block, so the squashfs fstab has exactly
# one /dev/shm entry.
touch "$ROOTFS/etc/fstab"
sed -i -E \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]/d' \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/dev\/shm[[:space:]]/d' \
    -e '/^# osmo-operator live - espace writable/d' \
    "$ROOTFS/etc/fstab"
# /dev/shm: sized via fstab (no generator duplicate risk).
cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
# osmo-operator live - espace writable (cfiles I/Q FFT)
tmpfs   /dev/shm   tmpfs   defaults,nosuid,nodev,size=20%   0 0
FSTAB
# --arm: root and firmware are real SD card partitions (named by
# 92-rpi-image). The live image has none: live-boot provides its root.
# Labels, not UUIDs: the image is built without mounting.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    # Armbian labels (armbi_root, RPICFG): what armbian-resize-filesystem and its
    # docs expect.
    sed -i -E -e '/^LABEL=armbi_root[[:space:]]/d' -e '/^LABEL=RPICFG[[:space:]]/d' "$ROOTFS/etc/fstab"
    cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
LABEL=armbi_root    /               ext4    defaults,noatime,commit=120,errors=remount-ro   0 1
LABEL=RPICFG        /boot/firmware  vfat    defaults                                        0 2
FSTAB
    install -d "$ROOTFS/boot/firmware"
fi
# /tmp: not in fstab. An fstab /tmp entry collides with systemd's tmp.mount
# (systemd-fstab-generator: "Duplicate entry in /etc/fstab"). /tmp is managed
# natively via a tmp.mount drop-in with size=15%.
mkdir -p "$ROOTFS/etc/systemd/system/tmp.mount.d"
cat > "$ROOTFS/etc/systemd/system/tmp.mount.d/size.conf" <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=15%
EOF
chroot "$ROOTFS" systemctl enable tmp.mount 2>/dev/null || true

# ── Bounding the stack's writes ────────────────────────────────────────────
# With 'toram' the root is a tmpfs overlay: everything written at runtime stays
# in RAM. Three unbounded writers would fill it after hours ("No space left on
# device" with no full disk):
#   1. the systemd journal;
#   2. /var/log/osmocom/*.log - the stack logs with 'filter all 1', and mobile
#      runs with about twenty debug categories;
#   3. GSMTAP pcap captures, written continuously.
# They are bounded here, in the image, so the caps apply to every machine.

# 1. Journal: volatile (lost on reboot of a live system anyway) and capped.
#    Without RuntimeMaxUse journald allows itself 10 % of RAM.
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
# --arm: the root is persistent, so is the journal (Storage=persistent,
# capped); volatile would drop the logs on every SD card reboot.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then
    cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=256M
RuntimeMaxUse=64M
EOF
else
cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
# osmo-operator live: the root is in RAM, the journal must not eat it.
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeKeepFree=256M
EOF
fi

# 2. Osmocom logs: rotate by size, not date - a verbose stack fills in an hour
#    what a daily rotation would never see.
#    copytruncate: daemons keep their descriptor open; otherwise rotation
#    leaves them a deleted file and the space is not released.
mkdir -p "$ROOTFS/etc/logrotate.d"
cat > "$ROOTFS/etc/logrotate.d/osmocom" <<'EOF'
/var/log/osmocom/*.log {
    size 32M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
# logrotate.timer runs only once a day: too late for a tmpfs.
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.service" <<'EOF'
[Unit]
Description=osmo-operator - rotation des journaux Osmocom (racine en RAM)
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/osmocom --state /run/osmo-logrotate.state
EOF
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.timer" <<'EOF'
[Unit]
Description=osmo-operator - rotation des journaux Osmocom toutes les 15 min
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
chroot "$ROOTFS" systemctl enable osmo-logrotate.timer 2>/dev/null || true

# 3. pcap captures: delete those older than one hour. The GSMTAP capture runs
#    continuously; it is for looking at what just happened, not for history.
mkdir -p "$ROOTFS/etc/tmpfiles.d"
cat > "$ROOTFS/etc/tmpfiles.d/osmo-captures.conf" <<'EOF'
# osmo-operator: captures live in RAM, keep them at most one hour.
d /run/user/0/osmo-nitb/captures 0755 root root 1h
EOF

# 3b. Ring buffer instead of an ever-growing file
# An hourly purge does not protect against one continuous capture filling RAM
# between two passes. A single -w file grows without limit; -C <MB> -W <n>
# turns it into a ring of n recycled files: the capture never stops and its
# footprint stays bounded.
#
# A wrapper rather than fixing callers: GSMTAP capture is started from the
# web dashboard (another repository) and from tools outside this repository.
# /usr/local/bin precedes /usr/bin in PATH, so plain "tcpdump" goes through it.
#
# It forces nothing if the caller already chose (-C or -W given), and without
# -w there is nothing to bound.
cat > "$ROOTFS/usr/local/bin/tcpdump" <<'TCPDUMPEOF'
#!/bin/sh
# tcpdump - osmo-operator wrapper: forces a ring buffer on file captures.
#
# The live root is a tmpfs: an unbounded capture eventually fills RAM.
#
# Two pitfalls handled:
#  -Z root : with -C/-W, tcpdump creates the next ring members after dropping
#            privileges (user "tcpdump"); without -Z it fails with
#            "Permission denied".
#  symlink : with -C/-W, tcpdump numbers the members (capture.pcap0, .pcap1...)
#            and the exact requested name never exists. <exact name> ->
#            current member is maintained so callers expecting it keep working.
#
# Tunables: OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
mkdir -p "$ROOTFS/usr/bin"
# Known limitation / TODO: the mkdir/find lines below are build-time commands
# (copy /usr/local/bin to /usr/bin without overwriting dpkg binaries, -n, and
# never the tcpdump wrapper) that ended up inside this heredoc; the generated
# wrapper also lacks REAL=/usr/bin/tcpdump and has_w=0 initialisation.
find "$ROOTFS/usr/local/bin" -mindepth 1 -maxdepth 1 ! -name tcpdump \
    -exec cp -an {} "$ROOTFS/usr/bin/" \; 2>/dev/null || true
 has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Nothing to bound, or the caller already chose its ring: step aside.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Symlink watcher. Started before exec: afterwards this process is tcpdump.
# $$ is unchanged across exec, so it follows tcpdump's lifetime exactly and
# stops with it - no orphan to clean up.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
TCPDUMPEOF
chmod +x "$ROOTFS/usr/local/bin/tcpdump"
# The real binary must still be an ELF: if a module replaced it with a script,
# the wrapper would loop. Stop the build rather than ship that.
if [ "$(head -c 2 "$ROOTFS/usr/bin/tcpdump" 2>/dev/null)" = "#!" ]; then
    echo -e "  ${RED}✗ /usr/bin/tcpdump du rootfs est un script, pas le binaire dpkg${NC}" >&2
    exit 1
fi
echo -e "  ${GREEN}✓${NC} wrapper tcpdump (anneau pcap) dans /usr/local/bin, binaire dpkg intact dans /usr/bin"

# ── Full purge at every boot ───────────────────────────────────────────────
# The caps above prevent drift during a session; this starts each boot from
# a clean root. On a live system nothing is lost; with persistence these
# files would otherwise accumulate until the medium is full.
#
# Before the stack (Before=osmo-*.service): purging after start would erase
# the logs of the current session.
cat > "$ROOTFS/usr/local/sbin/osmo-purge.sh" <<'PURGEEOF'
#!/bin/bash
# osmo-purge.sh - start from a clean root. Called at boot by osmo-purge.service.
# Never touches configs (/etc/osmocom) or databases (HLR): only regenerated
# data - logs, captures, work files.
set -u

purge_dir() {   # $1=repertoire  $2=motif
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f -name "$2" -delete 2>/dev/null || true
}

# Stack logs
purge_dir /var/log/osmocom '*.log'
purge_dir /var/log/osmocom '*.log.*'
purge_dir /var/log/osmocom '*.gz'

# pcap captures (GSMTAP and others)
rm -rf /run/user/0/osmo-nitb/captures/* 2>/dev/null || true
purge_dir /var/log/osmocom '*.pcap'
find /tmp /var/tmp -maxdepth 2 -type f -name '*.pcap*' -delete 2>/dev/null || true

# Work files: FFT I/Q (hundreds of MB each)
find /dev/shm -maxdepth 1 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true
# The same files outside /dev/shm: bridge mode writes /root/record.cfile and
# /root/record_ul.cfile continuously and stacks /root/osmo-rec/*.cfile up to
# its own 64 GB cap, which is meaningless when the root is a tmpfs.
find /root /tmp /var/tmp -maxdepth 2 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true

# Live runtime directory, recreated by the stack at start
rm -rf /run/user/0/osmo-nitb/logs/* 2>/dev/null || true

# Volatile systemd journal
command -v journalctl >/dev/null 2>&1 && journalctl --rotate --vacuum-time=1s >/dev/null 2>&1

exit 0
PURGEEOF
chmod +x "$ROOTFS/usr/local/sbin/osmo-purge.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-purge.service" <<'EOF'
[Unit]
Description=osmo-operator - purge des journaux, captures et fichiers de travail
DefaultDependencies=no
After=local-fs.target
Before=osmo-stp.service osmo-interstp.service osmo-msc.service osmo-bsc.service
Before=osmo-egprs-web.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-purge.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-purge.service 2>/dev/null || true

# SSH: allow root password login and enable the service at boot.
if [ -f "$ROOTFS/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
        "$ROOTFS/etc/ssh/sshd_config"
    grep -q '^PermitRootLogin yes' "$ROOTFS/etc/ssh/sshd_config" || \
        echo 'PermitRootLogin yes' >> "$ROOTFS/etc/ssh/sshd_config"
fi
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# ── Keyboard: fixed in the image, not asked at first boot ──────────────────
# The layout is chosen at the start of the build (see "LES QUESTIONS");
# it is only written here, so no machine blocks on a menu at login.
cat > "$ROOTFS/etc/default/keyboard" <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${OSMO_ISO_KB}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
chroot "$ROOTFS" setupcon --force 2>/dev/null || true
chroot "$ROOTFS" dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

# What remains at login: a reminder that waits for nothing.
# The command depends on the role: the hub has no GSM core, and
# start-native.sh would look for a BSC, MSC and BTS that do not exist there.
if [ "$ISO_ROLE" = "interstp" ]; then
    OSMO_START_HINT='Pour demarrer le hub SS7 : /opt/GSM/osmo-operator/launch/start-interstp.sh'
    OSMO_START_HINT2='  (etat des noeuds attaches : ./launch/start-interstp.sh --status)'
else
    OSMO_START_HINT='Pour demarrer la stack : /opt/GSM/osmo-operator/start-native.sh --node N'
    OSMO_START_HINT2='  (N de 1 a 9 : il fixe les point codes 1.<N>1.x du noeud)'
fi
cat > "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh" <<KBSCRIPT
#!/bin/bash
[ "\$(id -u)" -ne 0 ] && return 0
[ -n "\${OSMO_DISCLAIMER_SHOWN:-}" ] && return 0
export OSMO_DISCLAIMER_SHOWN=1
echo ""
echo -e "  \033[1;33mDisclaimer\033[0m - banc d'essai GSM/SS7 Osmocom."
echo -e "  A n'utiliser que sur un reseau radio \033[1mISOLE\033[0m (cage/attenuateur) ou"
echo -e "  sur une bande sous licence : emettre sur le spectre public est illegal."
echo -e "  Aucun service Osmocom n'est lance automatiquement sur cette ISO."
echo -e "  \033[1;33m${OSMO_START_HINT}\033[0m"
echo -e "  \033[0;36m${OSMO_START_HINT2}\033[0m"
echo -e "  clavier : \033[1;32m\$(awk -F\\" '/^XKBLAYOUT/{print \$2}' /etc/default/keyboard 2>/dev/null)\033[0m  \033[0;36m(changer : osmo-keyboard)\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh"
rm -f "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"

# Keyboard selection on demand only (osmo-keyboard), never between login
# and shell.
cat > "$ROOTFS/usr/local/bin/osmo-keyboard" <<'KBCMD'
#!/bin/bash
# osmo-keyboard - change the system keyboard layout, on demand.
[ "$(id -u)" -ne 0 ] && { echo "Root requis."; exit 1; }

if [ -n "$1" ]; then
    KB_LAYOUT="$1"
else
    echo ""
    echo -e "\033[1;36m== Configuration clavier ==\033[0m"
    echo "  1) fr    2) us    3) de    4) es    5) it"
    echo "  6) pt    7) gb    8) be    9) ch    0) autre"
    echo ""
    read -rp "  Choix [1] : " KB_CHOICE
    case "${KB_CHOICE:-1}" in
        1|"") KB_LAYOUT="fr" ;;
        2) KB_LAYOUT="us" ;;  3) KB_LAYOUT="de" ;;
        4) KB_LAYOUT="es" ;;  5) KB_LAYOUT="it" ;;
        6) KB_LAYOUT="pt" ;;  7) KB_LAYOUT="gb" ;;
        8) KB_LAYOUT="be" ;;  9) KB_LAYOUT="ch" ;;
        0) read -rp "  Layout (fr, us, ru, ar...) : " KB_LAYOUT
           KB_LAYOUT="${KB_LAYOUT:-us}" ;;
        *) KB_LAYOUT="fr" ;;
    esac
fi

loadkeys "$KB_LAYOUT" 2>/dev/null || true
cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true
echo -e "  \033[1;32mClavier : ${KB_LAYOUT}\033[0m   (sans persistance, revient au reboot)"
KBCMD
chmod +x "$ROOTFS/usr/local/bin/osmo-keyboard"

# End of module: `. file` returns the status of its last command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true
