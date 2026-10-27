#!/bin/bash
# iso_modules/85-installeur-bureau.sh - Calamares installer, osmo-install, desktop (icons, launchers)
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# --arm: no Calamares, osmo-install or desktop on arm64 (no --desktop there).
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ── INSTALLER ───────────────────────────────────────────────────────────────
# The configuration lives in the repository (installer/calamares/) rather than
# in heredocs here: versioned, and checkable outside a build (plain YAML).
_CAL_SRC="$DIR/installer/calamares"
if [ "${ISO_DESKTOP:-0}" = "1" ] && [ -d "$_CAL_SRC" ]; then
    install -d "$ROOTFS/etc/calamares"
    cp -a "$_CAL_SRC/settings.conf" "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/modules"       "$ROOTFS/etc/calamares/"
    cp -a "$_CAL_SRC/branding"      "$ROOTFS/etc/calamares/"
    # The osmosupplements python job ("Supplements" page) goes in the SYSTEM
    # modules directory, the one Calamares' modules-search always scans.
    _CAL_MODS="$ROOTFS/usr/lib/$(chroot "$ROOTFS" dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)/calamares/modules"
    install -d "$_CAL_MODS/osmosupplements"
    install -m644 "$_CAL_SRC/jobs/osmosupplements/module.desc" "$_CAL_SRC/jobs/osmosupplements/main.py" \
        "$_CAL_MODS/osmosupplements/"

    # Branding images: reuse the wallpaper frozen at build time instead of
    # adding binaries to the repository. Calamares scales them.
    _WPI="$DIR/configs/gsm-lab-wallpaper.png"
    if [ -f "$_WPI" ]; then
        cp "$_WPI" "$ROOTFS/etc/calamares/branding/osmo/logo.png"
    else
        # Without an image Calamares logs an error per screen: drop the keys
        # rather than leave them pointing at missing files.
        sed -i '/^images:/,/^slideshow:/{/productLogo\|productIcon/d}' \
            "$ROOTFS/etc/calamares/branding/osmo/branding.desc"
    fi
    # Welcome screen and first slide: the "Telecom Operator / No RF"
    # background (gsm-lab-ville.jpg), the same as the live desktop.
    _VILLE="$DIR/configs/gsm-lab-ville.jpg"
    if [ -f "$_VILLE" ]; then
        cp "$_VILLE" "$ROOTFS/etc/calamares/branding/osmo/welcome.jpg"
    else
        sed -i '/^images:/,/^slideshow:/{/productWelcome/d}' \
            "$ROOTFS/etc/calamares/branding/osmo/branding.desc"
    fi

    # ── LAUNCHER ────────────────────────────────────────────────────────────
    # pkexec rather than sudo: the installer is started from the desktop, where
    # there is no terminal to type a password. The live session runs as root,
    # but the osmocom user must be able to start the installer too.
    cat > "$ROOTFS/usr/local/bin/osmo-install" <<'INSTALLER'
#!/bin/bash
# Starts the system installer. Live medium only.
set -u
if [ ! -r /etc/calamares/settings.conf ]; then
    echo "Calamares n est pas installe sur cette image (ISO_DESKTOP=0 ?)." >&2
    exit 1
fi

# Become root RIGHT AWAY, for this script - not just for calamares: what
# follows (mounting the medium, unmounting a target left open) needs root.
# pkexec passes DISPLAY and XAUTHORITY along, so the GUI still opens.
if [ "$(id -u)" -ne 0 ]; then
    exec pkexec --disable-internal-agent "$0" "$@"
fi

# ── Locate the squashfs without assuming WHERE it is ────────────────────────
# In normal mode live-boot mounts the medium on /run/live/medium and the
# squashfs sits at live/filesystem.squashfs. With "toram=filesystem.squashfs"
# live-boot copies only THE FILE to the root of a tmpfs, then moves that tmpfs
# onto /run/live/medium: the squashfs ends up at
#     /run/live/medium/filesystem.squashfs
# and the "live/" subdirectory is gone, so anything that hardcodes the path
# misses it. Instead of rebuilding an assumed tree, the file is located by
# three increasingly broad means and presented to Calamares at a path that
# does not depend on the boot mode: the one named in unpackfs.conf.
SQ=""

# 1. Canonical path of a normal boot. If present, nothing to do.
[ -e /run/live/medium/live/filesystem.squashfs ] \
    && SQ=/run/live/medium/live/filesystem.squashfs

# 2. The loop device backing the running root. The most reliable source: not
#    "a" squashfs found somewhere, but THE one this system runs on. Holds in
#    normal, toram and persistent modes.
if [ -z "$SQ" ]; then
    _loop=$(findmnt -no SOURCE /run/live/rootfs/filesystem.squashfs 2>/dev/null || true)
    if [ -n "$_loop" ]; then
        _bf=$(losetup -nO BACK-FILE "$_loop" 2>/dev/null || true)
        [ -n "$_bf" ] && [ -e "$_bf" ] && SQ="$_bf"
    fi
fi

# 3. Last resort: any loop device whose backing file is a squashfs. Covers a
#    live-boot that named the mount point differently (persistence:
#    /run/live/persistence/sdX).
if [ -z "$SQ" ]; then
    SQ=$(losetup -anO BACK-FILE 2>/dev/null | grep -m1 '\.squashfs$' || true)
    [ -n "$SQ" ] && [ -e "$SQ" ] || SQ=""
fi

if [ -z "$SQ" ]; then
    echo "Squashfs introuvable - ce systeme ne tourne pas depuis une cle live," >&2
    echo "ou l image n est plus lisible. Rien a installer." >&2
    exit 1
fi

# ── THE STABLE PATH, THE ONE CALAMARES READS ────────────────────────────────
# Bind-mount the FILE, not its directory: the origin directory changes shape
# from one boot mode to the next, the file does not. /run is a tmpfs on a live
# system, hence writable - unlike /run/live/medium in toram mode, which
# live-boot moves read-only, so the missing "live/" could not be created there.
SRC=/run/osmo-install-src
mkdir -p "$SRC/live"
if ! mountpoint -q "$SRC/live/filesystem.squashfs"; then
    : > "$SRC/live/filesystem.squashfs"
    mount --bind "$SQ" "$SRC/live/filesystem.squashfs" || {
        echo "Impossible de presenter $SQ a l installeur." >&2
        exit 1
    }
fi
echo "Image source : $SQ  ->  $SRC/live/filesystem.squashfs"

# Test the FILE, not the directory: the directory exists even when empty, and
# a failure would then only show up later in Calamares, with the disk already
# repartitioned.
if [ ! -s "$SRC/live/filesystem.squashfs" ]; then
    echo "Le squashfs presente a l installeur est vide - rien a installer." >&2
    exit 1
fi

# ── Clean up the target of a previous attempt ───────────────────────────────
# When a step fails, Calamares skips all following jobs, "umount" included: the
# target stays mounted under /tmp/calamares-root-*. On the next run it sees a
# mounted disk, removes "Erase disk" from the list and only offers manual
# partitioning.
for _t in /tmp/calamares-root-*; do
    [ -d "$_t" ] || continue
    if mountpoint -q "$_t"; then
        umount -R "$_t" 2>/dev/null || {
            echo "Cible $_t encore montee et non demontable - fermez ce qui l occupe" >&2
            echo "(un terminal, un gestionnaire de fichiers) ou redemarrez." >&2
            exit 1
        }
    fi
    rmdir "$_t" 2>/dev/null || true
done

# ── GUARD: an invalid generated page must not block the installation ────────
# The two pages below are WRITTEN at every launch, hence checked at every
# launch: if the YAML does not parse, the minimal version (the one that does
# nothing) is put back and the operator can still install. yaml.safe_load
# reads what yaml-cpp reads. Without python3-yaml the check is skipped.
_yamlok() {
    python3 -c "import yaml" 2>/dev/null || return 0
    python3 - "$1" <<'YAMLCHECK'
import io, sys, yaml
lines = io.open(sys.argv[1], encoding="utf-8").read().splitlines()
i = next((n for n, l in enumerate(lines) if l.strip() == "---"), -1)
d = yaml.safe_load("\n".join(lines[i + 1:]))
if not isinstance(d, dict):
    raise SystemExit("pas une table YAML")
YAMLCHECK
}

# ── MIRROR: the installer's "Miroir Ubuntu" page follows the network ────────
# packaging/apt-mirror.sh --list measures the mirrors from here (5 s max each);
# the page offers those that answer, fastest first, the first one preselected,
# plus "the live key's one" (no change). The contextualprocess@mirror module
# writes the choice into the target, after unpackfs.
# NO BACKSLASH IN THESE COMMANDS: they sit in a double-quoted YAML string,
# where only a handful of escapes exist. \s and \S (sed classes) are not among
# them and yaml-cpp would reject the WHOLE file. Hence the POSIX classes
# ([[:space:]], [^[:space:]]) and the sed expression in escaped quotes (\" is
# a valid YAML escape), which also avoids escaping the space in the replacement.
_pm=/etc/calamares/modules/packagechooser-mirror.conf
_cm=/etc/calamares/modules/contextualprocess-mirror.conf
_am=/opt/GSM/osmo-operator/packaging/apt-mirror.sh
if [ -f "$_pm" ] && [ -f "$_cm" ] && [ -f "$_am" ]; then
    _cur="$(sed -nE 's|^deb (http[^ ]+) .*|\1|p' /etc/apt/sources.list 2>/dev/null | head -1)"
    _suite="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")"
    _mlist="$(bash "$_am" --list "$_suite" 2>/dev/null || true)"
    _n=0
    {
        echo "---"
        echo "mode: required"
        echo "method: legacy"
        echo "labels:"
        echo "    step: \"Miroir Ubuntu\""
        if [ -n "$_mlist" ]; then echo "default: m1"; else echo "default: keep"; fi
        echo "items:"
        echo "    - id: keep"
        echo "      name: \"Celui de la cle live\""
        echo "      description: \"Le systeme installe garde le miroir de la cle : ${_cur:-archive.ubuntu.com}.\""
        printf '%s\n' "$_mlist" | while IFS="$(printf '\t')" read -r _ms _url; do
            [ -n "$_url" ] || continue
            _n=$((_n + 1))
            _tag=""; [ "$_n" = 1 ] && _tag=" - le plus rapide d ici"
            echo "    - id: m${_n}"
            echo "      name: \"${_url#http://}\""
            echo "      description: \"${_url} - InRelease en ${_ms} ms${_tag}.\""
        done
    } > "$_pm"
    {
        echo "---"
        echo "dontChroot: false"
        echo "timeout: 60"
        echo "packagechooser_mirror:"
        echo "    \"keep\":"
        echo "        - \"-/bin/true\""
        _n=0
        printf '%s\n' "$_mlist" | while IFS="$(printf '\t')" read -r _ms _url; do
            [ -n "$_url" ] || continue
            _n=$((_n + 1))
            echo "    \"m${_n}\":"
            echo "        - \"-/bin/bash -c 'sed -i -E \\\"s,^deb[[:space:]]+https?://[^[:space:]]+,deb ${_url},\\\" /etc/apt/sources.list; [ -f /etc/apt/sources.list.d/ubuntu.sources ] && sed -i -E \\\"s,^URIs:[[:space:]]+https?://[^[:space:]]+,URIs: ${_url},\\\" /etc/apt/sources.list.d/ubuntu.sources; echo [mirror] ${_url}'\""
        done
    } > "$_cm"
    if ! _yamlok "$_pm" || ! _yamlok "$_cm"; then
        echo "Miroir Ubuntu : page generee ILLISIBLE - retour au choix minimal" >&2
        printf '%s\n' "---" "mode: required" "method: legacy" "labels:" \
            "    step: \"Miroir Ubuntu\"" "default: keep" "items:" \
            "    - id: keep" "      name: \"Celui de la cle live\"" \
            "      description: \"Le systeme installe garde le miroir de la cle.\"" > "$_pm"
        printf '%s\n' "---" "dontChroot: false" "timeout: 60" \
            "packagechooser_mirror:" "    \"keep\":" "        - \"-/bin/true\"" > "$_cm"
    elif [ -n "$_mlist" ]; then
        echo "Miroir Ubuntu : $(printf '%s\n' "$_mlist" | wc -l) miroirs mesures, le plus rapide : $(printf '%s\n' "$_mlist" | head -1 | cut -f2)"
    else
        echo "Miroir Ubuntu : aucune mesure (pas de reseau ?) - la cible garde ${_cur:-archive.ubuntu.com}"
    fi
fi

# ── NVIDIA: the installer's "Pilotes graphiques" page follows the machine ───
# Calamares cannot grey out an entry based on hardware: its chooser page and
# the module that installs are WRITTEN at EVERY launch, from lspci:
#   - NVIDIA card seen -> the "nvidia-driver-610" entry is named after the card
#     and preselected;
#   - no NVIDIA card: the page says so and any choice has no effect
#     (contextualprocess re-runs the lspci test in the target).
# On the installed system, tools/osmo-drivers.sh ("Pilotes graphiques" icon)
# shows the same state and allows installing or updating later.
#
# ONE FIXED VERSION: nvidia-driver-610 (noble-updates/multiverse), installed
# like any package: sudo apt install nvidia-driver-610.
# OSMO_NVIDIA_DRIVER selects another one at build time.
_pc=/etc/calamares/modules/packagechooser-nvidia.conf
_cp=/etc/calamares/modules/contextualprocess-nvidia.conf
_nvdrv="${OSMO_NVIDIA_DRIVER:-nvidia-driver-610}"
if [ -f "$_pc" ] && [ -f "$_cp" ]; then
    _nv="$(lspci -d 10de: 2>/dev/null | head -1 | cut -d: -f3- | sed 's/^ //; s/ (rev.*//')"
    # No double quote in this command: it sits between single quotes (bash -c)
    # inside a double-quoted YAML string - either would end the string. The
    # target's /run is an empty tmpfs (mount.conf) and /etc/resolv.conf points
    # there: resolvers are written there for the duration of apt.
    _apt_cmd='mkdir -p /run/systemd/resolve; [ -s /run/systemd/resolve/stub-resolv.conf ] || { echo nameserver 1.1.1.1 > /run/systemd/resolve/stub-resolv.conf; echo nameserver 8.8.8.8 >> /run/systemd/resolve/stub-resolv.conf; }; export DEBIAN_FRONTEND=noninteractive; lspci -n 2>/dev/null | grep -qi 10de: || { echo [nvidia] aucune carte NVIDIA : rien a installer; exit 0; }; apt-get update -qq || { echo [nvidia] pas de reseau : pilote non installe; exit 0; }'
    {
        echo "---"
        echo "mode: optional"
        echo "method: legacy"
        echo "labels:"
        echo "    step: \"Pilotes graphiques\""
        if [ -n "$_nv" ]; then echo "default: nvidia"; else echo "default: none"; fi
        echo "items:"
        echo "    - id: none"
        echo "      name: \"Aucun pilote supplementaire\""
        if [ -n "$_nv" ]; then
            _state=""
            dpkg -s "$_nvdrv" >/dev/null 2>&1 && _state=" (deja installe sur la cle)"
            echo "      description: \"Carte detectee : ${_nv}. Le pilote libre (nouveau) du noyau, comme sur la cle live.\""
            echo "    - id: nvidia"
            echo "      name: \"${_nvdrv} (proprietaire)\""
            echo "      description: \"Carte ${_nv} : installe ${_nvdrv}${_state} depuis les depots Ubuntu (reseau requis).\""
        else
            echo "      description: \"AUCUNE carte NVIDIA detectee (lspci) : rien a installer sur cette machine.\""
        fi
    } > "$_pc"
    {
        echo "---"
        echo "dontChroot: false"
        echo "timeout: 1800"
        echo "packagechooser_nvidia:"
        echo "    \"none\":"
        echo "        - \"-/bin/true\""
        echo "    \"nvidia\":"
        echo "        - \"-/bin/bash -c '${_apt_cmd}; apt-get install -y ${_nvdrv} || echo [nvidia] ${_nvdrv} non installable - le pilote libre nouveau reste en place; update-initramfs -u >/dev/null 2>&1 || true'\""
    } > "$_cp"
    if ! _yamlok "$_pc" || ! _yamlok "$_cp"; then
        echo "NVIDIA : page generee ILLISIBLE - retour au choix minimal" >&2
        printf '%s\n' "---" "mode: optional" "method: legacy" "labels:" \
            "    step: \"Pilotes graphiques\"" "default: none" "items:" \
            "    - id: none" "      name: \"Aucun pilote supplementaire\"" \
            "      description: \"Le pilote libre (nouveau) du noyau.\"" > "$_pc"
        printf '%s\n' "---" "dontChroot: false" "timeout: 1800" \
            "packagechooser_nvidia:" "    \"none\":" "        - \"-/bin/true\"" > "$_cp"
    elif [ -n "$_nv" ]; then
        echo "NVIDIA : $_nv - pilote propose : $_nvdrv"
    else
        echo "NVIDIA : aucune carte detectee - la page le dira, sans effet"
    fi
fi
exec /usr/bin/calamares -d "$@"
INSTALLER
    chmod +x "$ROOTFS/usr/local/bin/osmo-install"

    # ── CONKY: the bench dashboard, in EVERY GNOME session ───────────────────
    # /etc/xdg/autostart applies to all accounts: root on the live key, the
    # user created by Calamares on disk (the file travels in the squashfs).
    # The config and the status script live in the repository
    # (/opt/GSM/osmo-operator, present on both): configs/conky/osmo-conky.conf,
    # tools/conky-osmo-status.sh.
    # ── A WATCHER, NOT A ONE-SHOT LAUNCH ─────────────────────────────────────
    # osmo-panel.py is the window that DISPLAYS /run/osmo-fft/panel.png: without
    # it the inset does not exist on screen, whatever osmo-fft-snap renders. A
    # crash, an OOM kill or a manual kill would remove it for the rest of the
    # session, so this script restarts whatever is missing every five seconds,
    # never doubling an instance.
    cat > "$ROOTFS/usr/local/bin/osmo-desktop-panel" <<'PANEL'
#!/bin/sh
# osmo-desktop-panel - keeps the inset and Conky alive for the whole session.
# Started by /etc/xdg/autostart/osmo-conky.desktop. See iso_modules/85-installeur-bureau.sh.
REPO=/opt/GSM/osmo-operator
export OSMO_REPO="$REPO"
# The LAB GSM banner is not baked into the wallpaper: osmo-topzone.py renders
# it live. Tell the wallpaper renderer.
export OSMO_LIVE_BANNER=1

# ── A WIDGET LEFT OVER FROM THE PREVIOUS SESSION IS NOT A WIDGET ────────────
# A conky or python widget from a previous X session may still be running with
# an old DISPLAY (e.g. :0 while GNOME restarted on :1): it cannot paint
# anything, but "pgrep -x conky" would count it as alive and nothing would be
# restarted. Only processes looking at OUR display count; the others are
# killed, they can no longer serve anyone.
osmo_vivant() {
    _trouve=1
    for _p in $(pgrep "$@" 2>/dev/null); do
        _d="$(tr '\0' '\n' < "/proc/$_p/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
        # Kill ONLY what was read and looks elsewhere. An unreadable environ,
        # or one without DISPLAY, proves nothing: that process counts as
        # alive - confusing "absent" with "invisible" would spawn a duplicate
        # of each widget on every pass.
        if [ -n "$_d" ] && [ "$_d" != "$DISPLAY" ]; then kill "$_p" 2>/dev/null
        else _trouve=0
        fi
    done
    return $_trouve
}
# The watcher must not outlive its own X server: otherwise the old one keeps
# running next to the new one and restarts into the void forever.
osmo_display_vivant() {
    [ -n "$DISPLAY" ] || return 0          # no named display: cannot judge
    _n="${DISPLAY#*:}"; _n="${_n%%.*}"
    [ -S "/tmp/.X11-unix/X$_n" ]
}

# ── CONKY ARROWS ON THE KEYBOARD: Ctrl+AltGr+Left / Right ───────────────────
# A gschema.override does NOT apply to a RELOCATABLE schema, so the shortcut
# is written here, in the session, once per boot: the only place that runs
# UNDER the user's account, where gsettings writes into their dconf.
# <Mod5> is ISO_Level3_Shift, i.e. AltGr (xmodmap -pm confirms it).
osmo_raccourci() {
    command -v gsettings >/dev/null 2>&1 || return 0
    _k=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
    _p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "['$_p/osmo-op-next/','$_p/osmo-op-prev/']" 2>/dev/null || return 0
    gsettings set "$_k:$_p/osmo-op-next/" name 'osmo-operator : arret suivant (Conky)' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-next/" command '/usr/local/bin/osmo-op --next' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-next/" binding '<Control><Mod5>Right' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" name 'osmo-operator : arret precedent (Conky)' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" command '/usr/local/bin/osmo-op --prev' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" binding '<Control><Mod5>Left' 2>/dev/null
}
osmo_raccourci

# Conky must find the GNOME desktop already painted (own_window_type
# desktop), otherwise it ends up behind the wallpaper.
sleep 6
while osmo_display_vivant; do
    osmo_vivant -f "$REPO/tools/osmo-panel.py" || \
        "$REPO/tools/osmo-panel.py" >>/tmp/osmo-panel.log 2>&1 &
    # The dino is not on the desktop: it is an APPLICATION
    # (data/desktop/osmo-dino.desktop, osmo-dino.py --app).
    # Timeslot activity probe (osmo-bsc conf + VTY) for the banner
    osmo_vivant -f "$REPO/tools/osmo-ts-probe.py" || \
        "$REPO/tools/osmo-ts-probe.py" >>/tmp/osmo-ts-probe.log 2>&1 &
    # Live LAB GSM top zone (blinking timeslots + app welcome)
    osmo_vivant -f "$REPO/tools/osmo-topzone.py" || \
        "$REPO/tools/osmo-topzone.py" >>/tmp/osmo-topzone.log 2>&1 &
    # The bottom launcher bar is off the desktop by default: 2G/4G start from
    # the icons and launch.sh; OSMO_LAUNCHER=1 in the session environment
    # restores it.
    if [ "${OSMO_LAUNCHER:-0}" = 1 ]; then
        osmo_vivant -f "$REPO/tools/osmo-launcher.py" || \
            "$REPO/tools/osmo-launcher.py" >>/tmp/osmo-launcher.log 2>&1 &
    fi
    osmo_vivant -x conky || \
        conky --daemonize -c "$REPO/configs/conky/osmo-conky.conf" >>/tmp/osmo-conky.log 2>&1
    sleep 5
done
PANEL
    chmod 755 "$ROOTFS/usr/local/bin/osmo-desktop-panel"

    cat > "$ROOTFS/etc/xdg/autostart/osmo-conky.desktop" <<'CONKY'
[Desktop Entry]
Type=Application
Name=Conky osmo-operator
Comment=Tableau de bord du banc GSM (coeur, radio, abonnes, services)
Exec=/usr/local/bin/osmo-desktop-panel
Icon=utilities-system-monitor
Terminal=false
NoDisplay=true
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=6
CONKY
    chmod 644 "$ROOTFS/etc/xdg/autostart/osmo-conky.desktop"
    chmod +x "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-dino.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/conky-osmo-status.sh" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-drivers.sh" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-fft-snap.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-panel.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/wallpaper-render.py" \
             "$ROOTFS/opt/GSM/osmo-operator/tools/osmo-wallpaper.sh" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Conky du banc : autostart GNOME (live et disque), config ${CYAN}configs/conky/osmo-conky.conf${NC}"

    # The file lives in the repository (data/desktop/), not in a heredoc here:
    # the native install (install_modules/80-bureau.sh) and the .deb install
    # the SAME one.
    # ALL the repository's shortcuts, EXCEPT osmo-multi.desktop: it only makes sense once the Supplements are
    # installed (docker, the operator image, osmo-multi.conf), and
    # addition.sh --multi installs it at that point. The dock shows it when it
    # exists (favorite-apps already names it, iso_modules/80-chroot.sh).
    for _d in "$DIR"/data/desktop/*.desktop; do
        [ -f "$_d" ] || continue
        [ "$(basename "$_d")" = osmo-multi.desktop ] && continue
        install -m644 "$_d" "$ROOTFS/usr/share/applications/$(basename "$_d")"
    done

    # ── NO ICONS ON THE DESKTOP: THE DOCK IS ENOUGH ──────────────────────────
    # Shortcuts are not copied to ~/Desktop or ~/Bureau: they live in
    # /usr/share/applications (above) and in the dock favorites (favorite-apps,
    # iso_modules/80-chroot.sh). Leftovers from older images are removed,
    # including the DING trust mechanism (osmo-trust-desktop).
    rm -f "$ROOTFS/root/Desktop"/*.desktop "$ROOTFS/root/Bureau"/*.desktop \
          "$ROOTFS/home/osmocom/Desktop"/*.desktop "$ROOTFS/home/osmocom/Bureau"/*.desktop \
          "$ROOTFS/usr/local/bin/osmo-trust-desktop" \
          "$ROOTFS/etc/xdg/autostart/osmo-trust-desktop.desktop" 2>/dev/null || true
    chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true

    # ── LAUNCHER AND TUTORIAL: DESKTOP ICONS ─────────────────────────────────
    # Repository icons (data/*.svg), not theme names: "call-start" is GREEN in
    # Adwaita with no red variant, and a missing icon name is SILENTLY replaced
    # by a grey rectangle.
    install -d "$ROOTFS/usr/share/icons/hicolor/scalable/apps" \
              "$ROOTFS/usr/share/osmo-operator/icons" \
              "$ROOTFS/usr/share/osmo-operator"
    for _ic in osmo-launch osmo-multi osmo-tutorial claude osmo-paint osmo-lte osmo-dino; do
        [ -f "$DIR/data/$_ic.svg" ] || continue
        cp -f "$DIR/data/$_ic.svg" \
              "$ROOTFS/usr/share/icons/hicolor/scalable/apps/$_ic.svg"
        # THE COPY THAT MATTERS FOR THE DESKTOP. See the block right below.
        cp -f "$DIR/data/$_ic.svg" \
              "$ROOTFS/usr/share/osmo-operator/icons/$_ic.svg"
        chmod 644 "$ROOTFS/usr/share/osmo-operator/icons/$_ic.svg"
    done

    # The .desktop files POINT TO THE FILE, NOT TO THE ICON NAME.
    # "Icon=osmo-launch" is a name resolved through the theme and
    # /usr/share/icons/hicolor/icon-theme.cache; a name that does not resolve
    # is SILENTLY replaced by a blank page. Two measures:
    #   - Icon= as an ABSOLUTE PATH (below): bypasses theme and cache;
    #   - the cache is rebuilt anyway, for the applications menu, which still
    #     resolves by name.
    if chroot "$ROOTFS" sh -c 'command -v gtk-update-icon-cache' >/dev/null 2>&1; then
        chroot "$ROOTFS" gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    fi
    [ -f "$DIR/data/tutorial.html" ] && \
        cp -f "$DIR/data/tutorial.html" "$ROOTFS/usr/share/osmo-operator/tutorial.html"

    # A copy in /usr/share is the offline fallback: the only path that stays
    # readable when the dashboard does not answer.
    cat > "$ROOTFS/usr/local/bin/osmo-tutorial" <<'TUTO'
#!/bin/bash
# osmo-tutorial - opens the quick-start.
#
# OVER HTTP, NOT file://. The dashboard already serves this file on 8080: the
# page shown is the authoritative one (the repository's, copied at each build),
# the same as from another machine of the bench, and relative links to the
# dashboard work. file:// remains as a fallback when the dashboard is down.
set -u
URL="${OSMO_TUTORIAL_URL:-http://127.0.0.1:8080/tutorial.html}"
PORT="${URL##*:}"; PORT="${PORT%%/*}"
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    exec xdg-open "$URL"
fi
echo "Dashboard injoignable sur $PORT - repli file:// sur la copie de /usr/share" >&2
exec xdg-open "file:///usr/share/osmo-operator/tutorial.html"
TUTO
    chmod +x "$ROOTFS/usr/local/bin/osmo-tutorial"
    # Same launcher for the help page (the "?"), served by the dashboard
    install -m755 "$DIR/tools/osmo-info" "$ROOTFS/usr/local/bin/osmo-info"

    # The file lives in the repository (data/desktop/), not in a heredoc here:
    # the native install (install_modules/80-bureau.sh) and the .deb install
    # the SAME one.
    install -m644 "$DIR/data/desktop/osmo-launch.desktop" "$ROOTFS/usr/share/applications/osmo-launch.desktop"
    # No separate DSP icon: DSP is the bench default; the phone icon's right
    # click offers the other chain ("Lancer en mode gr-gsm").
    rm -f "$ROOTFS/usr/share/applications/osmo-dsp.desktop"

    # osmo-multi (antenna, multi-operator) is NOT installed here: its launcher
    # start-multi.sh needs docker + the image + the SS7 topology, which only
    # exist after the supplement; addition.sh installs it at the end of a
    # successful SS7 install. Its SVG stays installed (icons block above) so
    # that deferred install finds the image.

    # ── SUPPLEMENTS: THE CHECKLIST WINDOW ────────────────────────────────────
    # Same shape as osmo-update-anim: a bench GTK window with a VTE terminal
    # inside (tools/osmo-gtk-run.py), control given back only once the end has
    # been read. addition.sh opens its own checklist (zenity) when DISPLAY is
    # set; the terminal remains useful for the long, verbose rest (apt, then
    # the Osmocom build). No dock favorite opens gnome-terminal.
    cat > "$ROOTFS/usr/local/bin/osmo-addition-anim" <<'ADDGUI'
#!/bin/bash
# osmo-addition-anim - the supplements (addition.sh) in a bench GTK window: a
# VTE terminal inside, for the checklist and then the long, verbose rest (apt,
# build); the window stays open at the end with the status. Root through
# pkexec, DISPLAY/XAUTHORITY and the session proxy carried over
# (osmo-gtk-run --root).
set -u
REPO=/opt/GSM/osmo-operator
SCRIPT=$REPO/addition.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="addition.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
# --progress: progress bar + step, the console (VTE) folded behind "console"
exec python3 "$REPO/tools/osmo-gtk-run.py" --progress --root --title "osmo-operator - supplements" -- "$SCRIPT" "$@"

ADDGUI
    chmod +x "$ROOTFS/usr/local/bin/osmo-addition-anim"

    # The file lives in the repository (data/desktop/), not in a heredoc here:
    # the native install (install_modules/80-bureau.sh) and the .deb install
    # the SAME one.
    install -m644 "$DIR/data/desktop/osmo-addition.desktop" "$ROOTFS/usr/share/applications/osmo-addition.desktop"

    # The file lives in the repository (data/desktop/), not in a heredoc here:
    # the native install (install_modules/80-bureau.sh) and the .deb install
    # the SAME one.
    install -m644 "$DIR/data/desktop/osmo-tutorial.desktop" "$ROOTFS/usr/share/applications/osmo-tutorial.desktop"
    # The Info page (English): every bench module, by icon, launch bar or CLI,
    # with the code behind it. Icon in the favorites.
    install -d "$ROOTFS/usr/share/osmo-operator"
    install -m644 "$DIR/configs/info.html" "$ROOTFS/usr/share/osmo-operator/info.html"
    install -d "$ROOTFS/usr/share/osmo-operator/icons"
    install -m644 "$DIR/data/osmo-info.svg" "$ROOTFS/usr/share/osmo-operator/icons/osmo-info.svg"
    install -m644 "$DIR/data/desktop/osmo-info.desktop" "$ROOTFS/usr/share/applications/osmo-info.desktop"

    # ── CLAUDE: launcher + menu entry ────────────────────────────────────────
    # Claude Code is NOT in the ISO (it is installed by the supplement): the
    # launcher runs the install (addition.sh --claude) on the first click if
    # claude is missing, then opens it.
    cat > "$ROOTFS/usr/local/bin/osmo-claude-anim" <<'CLA'
#!/bin/bash
# osmo-claude-anim - Claude Code in a bench GTK window (VTE terminal: claude is
# interactive end to end). Not in the ISO: the first click installs it
# (addition.sh --claude, as root) then opens it, in the same window.
set -u
exec python3 /opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Claude" -- bash -lc '
if ! command -v claude >/dev/null 2>&1; then
    ADD=/opt/GSM/osmo-operator/addition.sh
    if [ -x "$ADD" ]; then
        if [ "$(id -u)" -ne 0 ] && command -v pkexec >/dev/null 2>&1; then
            pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" "$ADD" --claude
        else
            "$ADD" --claude
        fi
    fi
fi
if command -v claude >/dev/null 2>&1; then exec claude; fi
echo "Claude non installe - lancez le supplement (addition.sh --claude)."
exit 1'

CLA
    chmod +x "$ROOTFS/usr/local/bin/osmo-claude-anim"
    # The file lives in the repository (data/desktop/); Icon= as an absolute path.
    install -m644 "$DIR/data/desktop/claude.desktop" "$ROOTFS/usr/share/applications/claude.desktop"
    sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/claude.svg|" \
        "$ROOTFS/usr/share/applications/claude.desktop"

    # Terminal=false: launch.sh opens ITS OWN terminal and asks for privileges
    # (pkexec). No copy on the desktop: shortcuts are in the menu and dock.
    echo -e "  ${GREEN}✓${NC} menu/dock : ${CYAN}telephone${NC} (lancer) · ${CYAN}livre${NC} (tutoriel) · ${CYAN}supplements${NC} · ${CYAN}Claude${NC}"

    # The calamares package installs ITS OWN menu entry, which runs
    # /usr/bin/calamares directly and bypasses osmo-install (no medium put back
    # in place, no previous target unmounted). NoDisplay removes it from the
    # menus without touching the package.
    if [ -f "$ROOTFS/usr/share/applications/calamares.desktop" ]; then
        grep -q '^NoDisplay=' "$ROOTFS/usr/share/applications/calamares.desktop" \
            || echo 'NoDisplay=true' >> "$ROOTFS/usr/share/applications/calamares.desktop"
    fi

    echo -e "  ${GREEN}✓${NC} installeur ${CYAN}Calamares${NC} : /usr/local/bin/osmo-install (+ icone sur le bureau)"
elif [ "${ISO_DESKTOP:-0}" = "1" ]; then
    echo -e "  ${YELLOW}!${NC} $_CAL_SRC absent - pas d installeur dans cette image"
fi

# ── WITHOUT --desktop: THE SHORTCUTS AND THEIR ICONS ANYWAY ─────────────────
# The 4G check of 88-lte-pmos.sh requires osmo-lte.desktop on EVERY operator
# image, including the base ISO (no GNOME), and the block above only runs with
# --desktop. Install here what the native install (install_modules/80-bureau.sh)
# installs anyway: the repository's .desktop files and their SVGs. A few KB,
# and a desktop installed afterwards (apt install ubuntu-desktop) finds its
# menu entries ready.
if [ "${ISO_DESKTOP:-0}" != "1" ]; then
    install -d "$ROOTFS/usr/share/applications" \
              "$ROOTFS/usr/share/icons/hicolor/scalable/apps" \
              "$ROOTFS/usr/share/osmo-operator/icons"
    for _ic in osmo-launch osmo-multi osmo-tutorial claude osmo-paint osmo-lte osmo-dino osmo-info; do
        [ -f "$DIR/data/$_ic.svg" ] || continue
        install -m644 "$DIR/data/$_ic.svg" "$ROOTFS/usr/share/icons/hicolor/scalable/apps/$_ic.svg"
        install -m644 "$DIR/data/$_ic.svg" "$ROOTFS/usr/share/osmo-operator/icons/$_ic.svg"
    done
    # EXCEPT osmo-multi.desktop: it only makes sense once the Supplements are
    # installed (docker, the operator image, osmo-multi.conf), and
    # addition.sh --multi installs it at that point. The dock shows it when it
    # exists (favorite-apps already names it, iso_modules/80-chroot.sh).
    for _d in "$DIR"/data/desktop/*.desktop; do
        [ -f "$_d" ] || continue
        [ "$(basename "$_d")" = osmo-multi.desktop ] && continue
        install -m644 "$_d" "$ROOTFS/usr/share/applications/$(basename "$_d")"
    done
    echo -e "  ${GREEN}✓${NC} raccourcis du depot (data/desktop/) + icones poses, sans bureau"
fi

# ── THE "UPDATE" GTK LAUNCHER -> the repository's update.sh ─────────────────
# Independent of Calamares: a desktop icon that replays update.sh, the TRACKED
# file of the osmo-operator repository (/opt/GSM/osmo-operator/update.sh).
# update.sh is a TERMINAL animation: its first useful line is
# "[ -t 1 ] || exit 0", so without a tty (from a GTK icon) it exits at once.
# The launcher therefore opens it in a VTE terminal inside a bench GTK window
# (tools/osmo-gtk-run.py), which stays open at the end to read the result.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    cat > "$ROOTFS/usr/local/bin/osmo-update-anim" <<'UPDGUI'
#!/bin/bash
# osmo-update-anim - replays the repository's update.sh in a bench GTK window.
# update.sh is a TERMINAL animation ([ -t 1 ] || exit 0): a VTE terminal in
# the window, which stays open on the last line ("SMS delivered") with the
# status.
set -u
SCRIPT=/opt/GSM/osmo-operator/update.sh
if [ ! -x "$SCRIPT" ]; then
    command -v zenity >/dev/null 2>&1 && \
        zenity --error --text="update.sh introuvable : $SCRIPT" 2>/dev/null
    exit 1
fi
# --progress: progress bar + step, the console (VTE) folded behind "console"
exec python3 /opt/GSM/osmo-operator/tools/osmo-gtk-run.py --progress --title "osmo-operator - update" -- "$SCRIPT" "$@"

UPDGUI
    chmod +x "$ROOTFS/usr/local/bin/osmo-update-anim"

    # The file lives in the repository (data/desktop/), not in a heredoc here:
    # the native install (install_modules/80-bureau.sh) and the .deb install
    # the SAME one.
    install -m644 "$DIR/data/desktop/osmo-update.desktop" "$ROOTFS/usr/share/applications/osmo-update.desktop"

    echo -e "  ${GREEN}✓${NC} lanceur GTK ${CYAN}update${NC} : /usr/local/bin/osmo-update-anim (+ icone sur le bureau)"
fi


# ── DESKTOP, CONTINUED: WALLPAPER OF THE DAY, SPECTRA, TERMINAL, DING ───────
# This whole block is OUTSIDE the chroot of 80-chroot.sh: heredocs and single
# quotes are free here.
if [ "${ISO_DESKTOP:-0}" = "1" ]; then
    # ── 1. Wallpaper of the day: Calvin & Hobbes strip inset ─────────────────
    # tools/osmo-wallpaper.sh fetches the strip of the day (gocomics), composes
    # photo + LAB GSM map + strip (tools/wallpaper-render.py) and pushes the
    # result into the open sessions. At boot (40 s, network up), daily at 6:30,
    # and every 4 h as a catch-up (bench offline at boot).
    install -m755 "$DIR/tools/osmo-wallpaper.sh" "$ROOTFS/usr/local/sbin/osmo-wallpaper"
    # The image's /opt/GSM/osmo-operator tree comes from the GitHub clone made
    # in Docker: what the wallpaper and spectra use is also installed from THIS
    # repository, so the build does not depend on a push for those files.
    _rt="$ROOTFS/opt/GSM/osmo-operator"
    install -d "$_rt/tools" "$_rt/configs/wallpaper" "$_rt/configs/conky"
    # conky-osmo-status.sh is in the list: it reports whether the HLR runs.
    # Same rule for all: the local repository is authoritative.
    install -m755 "$DIR/tools/wallpaper-render.py" "$DIR/tools/osmo-fft-snap.py" "$DIR/tools/osmo-panel.py" "$DIR/tools/osmo-wallpaper.sh" "$DIR/tools/conky-osmo-status.sh" "$_rt/tools/"
    # The interactive desktop (live LAB GSM banner + launch bar) and the dino:
    # local files, installed from THIS repository like the five above.
    # osmo-extras-install.sh serves the native install (80).
    for _f in osmo-launcher.py osmo-topzone.py osmo-ts-probe.py osmo-dino.py osmo-extras-install.sh osmo-fond.py \
             osmo-pmos.sh osmo-pmos-qemu.sh osmo-pmos-setup.sh osmo-wireshark-root.sh \
             osmo-ofono-bridge.py osmo-phonesim-banc.py \
             osmo-ril-atmodem.py at-cmd.py; do
        [ -f "$DIR/tools/$_f" ] && install -m755 "$DIR/tools/$_f" "$_rt/tools/"
    done
    unset _f
    # tower.* and not tower.jpg: the photo travels in its original format
    # (full-definition PNG), without re-encoding.
    for _tw in "$DIR"/configs/wallpaper/tower.*; do
        [ -f "$_tw" ] && install -m644 "$_tw" "$_rt/configs/wallpaper/"
    done
    unset _tw
    install -m644 "$DIR/configs/conky/osmo-conky.conf" "$_rt/configs/conky/"
    # The conky plate (Cairo), loaded by osmo-conky.conf
    [ -f "$DIR/configs/conky/osmo-conky.lua" ] && install -m644 "$DIR/configs/conky/osmo-conky.lua" "$_rt/configs/conky/"
    # The live LAB GSM banner and the dino html (rendered by WebKit)
    for _h in labgsm.html dino.html; do
        [ -f "$DIR/configs/conky/$_h" ] && install -m644 "$DIR/configs/conky/$_h" "$_rt/configs/conky/"
    done
    unset _h
    install -m644 "$DIR/configs/gsm-lab-wallpaper.png" "$_rt/configs/gsm-lab-wallpaper.png"
    # 80-chroot.sh copied the wallpaper from the GitHub clone (before this
    # module): put THIS repository's one back, the render of tools/wallpaper-render.py.
    install -m644 "$DIR/configs/gsm-lab-wallpaper.png" "$ROOTFS/usr/share/backgrounds/gsm-lab-wallpaper.png"
    # The DEFAULT wallpaper is the raw illustration (80-chroot.sh); the composed
    # render above stays installed for osmo-wallpaper run by hand.
    install -m644 "$DIR/configs/gsm-lab-wallpaper.jpg" "$_rt/configs/gsm-lab-wallpaper.jpg"
    install -m644 "$DIR/configs/gsm-lab-wallpaper.jpg" "$ROOTFS/usr/share/backgrounds/gsm-lab-wallpaper.jpg"
    # The default GNOME wallpaper is configs/gsm-lab-fond.jpg (named by the
    # 80-chroot.sh schema); the illustration above remains for the inset, which
    # shows it whole in the middle. Both are rendered together by
    # tools/paysage-render.py (same scene: bare background, inset with the
    # pylons), then retouched by hand: the repository holds the chosen version.
    if [ -f "$DIR/configs/gsm-lab-fond.jpg" ]; then
        install -m644 "$DIR/configs/gsm-lab-fond.jpg" "$_rt/configs/gsm-lab-fond.jpg"
        install -m644 "$DIR/configs/gsm-lab-fond.jpg" "$ROOTFS/usr/share/backgrounds/gsm-lab-fond.jpg"
    else
        echo -e "  ${YELLOW}!${NC} configs/gsm-lab-fond.jpg absent - le fond GNOME retombe sur l illustration"
        install -m644 "$DIR/configs/gsm-lab-wallpaper.jpg" "$ROOTFS/usr/share/backgrounds/gsm-lab-fond.jpg"
    fi
    unset _rt
    cat > "$ROOTFS/etc/systemd/system/osmo-wallpaper.service" <<'EOF'
[Unit]
Description=Fond d ecran du banc (image du jour : Calvin, xkcd, APOD, Bing, turnoff.us)
# NO NETWORK WAIT: without network the script installs the frozen wallpaper
# and exits 0; with network the daily timer (osmo-wallpaper.timer) replaces it
# on its next pass.
After=network.target
ConditionPathExists=/opt/GSM/osmo-operator/tools/wallpaper-render.py

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/osmo-wallpaper
# A slow download must hold neither boot nor shutdown: the service is killed
# after 45 s, the frozen wallpaper stays.
TimeoutStartSec=45
TimeoutStopSec=10
EOF
    cat > "$ROOTFS/etc/systemd/system/osmo-wallpaper.timer" <<'EOF'
[Unit]
Description=Fond d ecran du banc : strip du jour (boot + quotidien)

[Timer]
OnBootSec=40s
OnCalendar=*-*-* 06:30:00
OnUnitActiveSec=4h
Persistent=true
Unit=osmo-wallpaper.service

[Install]
WantedBy=timers.target
EOF
    # Timer NOT enabled: it would replace the raw wallpaper with the composed
    # render 40 s after boot. The unit stays installed:
    #     systemctl enable --now osmo-wallpaper.timer   to get the wallpaper of the day back
    chroot "$ROOTFS" systemctl disable osmo-wallpaper.timer 2>/dev/null || true

    # ── 2. I/Q spectra in the bottom-right Conky ─────────────────────────────
    # tools/osmo-fft-snap.py draws /run/osmo-fft/panel.png: the Calvin & Hobbes
    # frame of the wallpaper (cut from the PNG of the day) fading to "mobile
    # FFT + mobile.log" when /psd has a stream; osmo-panel.py (GTK desktop-type
    # window, clickable: Dashboard, tmux, operator arrows) displays it over the
    # frame, scaled to the screen. The service lives with the dashboard and
    # restarts without it: without a stream the image says "no stream" instead
    # of freezing.
    cat > "$ROOTFS/etc/systemd/system/osmo-fft-snap.service" <<'EOF'
[Unit]
Description=Encart vivant du bureau : strip du jour qui fond vers FFT du mobile + mobile.log
After=osmo-egprs-web.service osmo-wallpaper.service
ConditionPathExists=/opt/GSM/osmo-operator/tools/osmo-fft-snap.py

[Service]
ExecStart=/usr/bin/python3 /opt/GSM/osmo-operator/tools/osmo-fft-snap.py
RuntimeDirectory=osmo-fft
# 0775 AND the sudo group, NOT 0755 root:root: osmo-panel.py runs in the
# DESKTOP SESSION (root on the key, the installer-created account on disk) and
# WRITES /run/osmo-fft/operator when the operator is changed with the arrows.
# The installer's account is a sudoer by construction (users.conf), and so is
# root: the sudo group is exactly "who drives this bench". ExecStartPost rather
# than Group=: the unit must stay root to read the containers and /psd.
RuntimeDirectoryMode=0775
ExecStartPost=-/bin/chgrp sudo /run/osmo-fft
# systemd removes the RuntimeDirectory when the unit stops: keeping it avoids
# /run/osmo-fft/panel.png disappearing (and the inset blinking) across a
# restart. The file is rewritten every second.
RuntimeDirectoryPreserve=yes
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    [ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-fft-snap 2>/dev/null || true

    # ── 3. The terminal: slightly transparent, amber on near-black ───────────
    # A gnome-terminal profile is a RELOCATABLE schema: impossible through
    # gschema.override. Hence a SYSTEM dconf database (/etc/dconf/db/local) read
    # by every session, root on the key as well as the Calamares user on disk,
    # which the user can still override ("user" database in front).
    # AMBER TERMINAL: amber text (#FFB000) on a warm near-black background,
    # blinking amber block cursor, light-yellow bold, palette in ambers/golds
    # (red and green stay distinct for errors and checkmarks), Ubuntu Mono 12,
    # 18 % transparency. Default on the ISO as on native (the same file is
    # loaded into the user database by update.sh / by hand: dconf load).
    install -d "$ROOTFS/etc/dconf/profile" "$ROOTFS/etc/dconf/db/local.d"
    printf 'user-db:user\nsystem-db:local\n' > "$ROOTFS/etc/dconf/profile/user"
    cat > "$ROOTFS/etc/dconf/db/local.d/10-osmo-terminal" <<'EOF'
[org/gnome/terminal/legacy/profiles:]
list=['b1dcc9dd-5262-4d8d-a863-c897e6d979b9']
default='b1dcc9dd-5262-4d8d-a863-c897e6d979b9'

[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
visible-name='osmo-operator'
use-theme-colors=false
use-theme-transparency=false
use-transparent-background=true
background-transparency-percent=18
background-color='#0B0A05'
foreground-color='#FFB000'
bold-color-same-as-fg=false
bold-color='#FFD75F'
cursor-colors-set=true
cursor-background-color='#FFB000'
cursor-foreground-color='#0B0A05'
cursor-shape='block'
cursor-blink-mode='on'
highlight-colors-set=true
highlight-background-color='#FFB000'
highlight-foreground-color='#0B0A05'
palette=['#1C1A10', '#FF5555', '#50FA7B', '#FFD75F', '#57A6FF', '#FF79C6', '#4FE0D4', '#FFD98A', '#5C5230', '#FF6E6E', '#69FF94', '#FFE28A', '#7CC0FF', '#FF92DF', '#7FF2E6', '#FFF3C8']
use-system-font=false
font='Ubuntu Mono 12'
scrollback-unlimited=false
scrollback-lines=50000
audible-bell=false
EOF
    # ── SCROLLBACK IS BOUNDED: IT LIVES IN /tmp ──────────────────────────────
    # VTE keeps the scrollback in DELETED files under /tmp (held by
    # gnome-terminal-server): invisible to du, visible to df. An unlimited
    # scrollback on a tab following the bench logs can fill /tmp ("No space
    # left on device"). 50 000 lines = ~10 MB per tab, plenty to scroll back.
    chroot "$ROOTFS" dconf update 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} gnome-terminal : profil ${CYAN}osmo-operator${NC} (noir, 18 % transparent) via dconf systeme" \
        || echo -e "  ${YELLOW}!${NC} dconf update a echoue - profil terminal non compile"

    # ── 4. DING restarted after login ────────────────────────────────────────
    # The "Desktop Icons NG" extension opens its full-screen window before GNOME
    # Shell has painted the wallpaper and keeps the greeter image on top of
    # ours. Killing it once the session is open is enough: the extension
    # restarts it within a second, cleanly.
    cat > "$ROOTFS/etc/xdg/autostart/osmo-ding-refresh.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=osmo-operator : rafraichit les icones du bureau
Comment=Relance Desktop Icons NG une fois le fond d ecran peint
Exec=sh -c 'sleep 12; pkill -f "extensions/ding@rastersoft.com/app/ding.js" 2>/dev/null; exit 0'
Terminal=false
NoDisplay=true
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=12
EOF
    chmod 644 "$ROOTFS/etc/xdg/autostart/osmo-ding-refresh.desktop"
    echo -e "  ${GREEN}✓${NC} bureau : fond brut (gsm-lab-wallpaper.jpg), spectres (osmo-fft-snap), DING relance a l ouverture"

    # ── 5. VLC FROM A ROOT SESSION ───────────────────────────────────────────
    # The live session runs as root and VLC refuses to start as root ("VLC is
    # not supposed to be run as root"). The binary is untouched: the wrapper
    # /usr/local/bin/vlc (ahead of /usr/bin in PATH, targeted by the local
    # .desktop) re-runs VLC under the osmocom account when root - X access via
    # xhost (local only), sound via the bench's system PulseAudio daemon
    # (osmo-pulse, pulse-access group). A normal user goes straight through.
    if [ -x "$ROOTFS/usr/bin/vlc" ]; then
        chroot "$ROOTFS" getent passwd osmocom >/dev/null 2>&1 \
            || chroot "$ROOTFS" useradd -m -s /bin/bash osmocom 2>/dev/null || true
        chroot "$ROOTFS" getent group pulse-access >/dev/null 2>&1 \
            && chroot "$ROOTFS" usermod -aG pulse-access,audio,video osmocom 2>/dev/null || true
        cat > "$ROOTFS/usr/local/bin/vlc" <<'VLCW'
#!/bin/bash
# vlc - osmo-operator wrapper: VLC refuses root, the live session IS root.
# Root: re-run under osmocom (local X via xhost, sound via osmo-pulse).
VLC_USER="${OSMO_VLC_USER:-osmocom}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/var/run/pulse/native}"
if [ "$(id -u)" -eq 0 ] && id "$VLC_USER" >/dev/null 2>&1; then
    export DISPLAY="${DISPLAY:-:0}"
    xhost "+SI:localuser:$VLC_USER" >/dev/null 2>&1 || true
    exec runuser -u "$VLC_USER" -- env DISPLAY="$DISPLAY" PULSE_SERVER="$PULSE_SERVER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$VLC_USER")" HOME="$(getent passwd "$VLC_USER" | cut -d: -f6)" \
        /usr/bin/vlc "$@"
fi
exec /usr/bin/vlc "$@"
VLCW
        chmod 755 "$ROOTFS/usr/local/bin/vlc"
        # The package's .desktop calls /usr/bin/vlc by absolute path: local copy
        # (higher priority, not overwritten by apt) that goes through the wrapper.
        if [ -f "$ROOTFS/usr/share/applications/vlc.desktop" ]; then
            install -d "$ROOTFS/usr/local/share/applications"
            sed 's|^Exec=/usr/bin/vlc|Exec=/usr/local/bin/vlc|; s|^Exec=vlc |Exec=/usr/local/bin/vlc |' \
                "$ROOTFS/usr/share/applications/vlc.desktop" > "$ROOTFS/usr/local/share/applications/vlc.desktop"
        fi
        echo -e "  ${GREEN}✓${NC} vlc : wrapper ${CYAN}/usr/local/bin/vlc${NC} (root -> osmocom, .desktop redirige)"
    else
        echo -e "  ${YELLOW}!${NC} vlc absent du rootfs - pas de wrapper"
    fi
fi


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would stop everything silently. Always 0 here.
true
